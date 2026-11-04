import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
import pytest
from rondo_host import packing as K, fmt, regmap

ROOT = Path(__file__).resolve().parents[2]
NPZ = ROOT / "workloads" / "results" / "waveform_coeffs.npz"
G = regmap.Geometry()


def waveform():
    D = np.load(NPZ)
    Wl = D["Wden"].reshape(int(D["width"]), G.depth, G.pdim)[:G.width].astype(np.float32)
    Bl = D["bden"].reshape(int(D["width"]), G.depth)[:G.width].astype(np.float32)
    return Wl, Bl


@pytest.mark.parametrize("wb", [16, 32])
def test_pack_matches_gen_genesys2_rom(wb):
    Wl, Bl = waveform()
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, str(ROOT / "workloads" / "gen_genesys2_rom.py"), "--out", d,
                        "--wb", str(wb), "--nsamp", "1"], check=True, capture_output=True)
        wl = (Path(d) / "g2_w.mem").read_text().split()
        bl = (Path(d) / "g2_b.mem").read_text().split()
    W, B = K.pack_weights(fmt.to_bits(Wl, wb), fmt.to_bits(Bl, wb), G)
    assert len(wl) == G.lanes * G.nwords and len(bl) == G.lanes * G.nbwords
    for l in range(G.lanes):
        for a in range(G.nwords):
            word = 0
            for f in range(G.npar):
                word |= int(W[l, a, f]) << (f * wb)
            assert int(wl[l * G.nwords + a], 16) == word, (l, a)
        for a in range(G.nbwords):
            word = 0
            for f in range(G.npar):
                word |= int(B[l, a, f]) << (f * wb)
            assert int(bl[l * G.nbwords + a], 16) == word


def test_pack_roundtrip():
    rng = np.random.default_rng(0)
    g = regmap.Geometry(width=16, pdim=8, lanes=2)
    Wl = rng.integers(0, 1 << 16, (16, 7, 8)); Bl = rng.integers(0, 1 << 16, (16, 7))
    W, B = K.pack_weights(Wl, Bl, g)
    Wr, Br = K.unpack_weights(W, B, g)
    assert (Wr == Wl).all() and (Br == Bl).all()


def test_checksum_matches_board_algorithm():
    # genesys2_fused_top.v:159-177 / :236 -> rotl-per-term fold, rotl(cks,1)+fold
    z = [0x3F800000 + i for i in range(64)]
    cks = 0
    for _ in range(3):
        cks = K.update(cks, z, 32)
    exp = 0
    for _ in range(3):
        f = sum(K.rotl32(v, j % 32) for j, v in enumerate(z)) & 0xFFFFFFFF
        exp = (K.rotl32(exp, 1) + f) & 0xFFFFFFFF
    assert cks == exp


def test_load_crc_is_zlib():
    import zlib
    vals = [0x1234, 0xBEEF, 0x0]
    assert K.load_crc(vals, 16) == zlib.crc32(b"\x34\x12\xef\xbe\x00\x00")
    assert K.load_crc([], 16) == 0


def test_kat_lfsr_and_elements():
    L = K.Lfsr()
    seq = [L.next() for _ in range(4)]
    assert len(set(seq)) == 4 and K.Lfsr().next() == seq[0]
    # Galois step check against a manual implementation
    s = 0x1D872B41
    s = (s >> 1) ^ (K.KAT_TAPS if s & 1 else 0)
    assert seq[0] == s
    for r in seq + [0xFFFFFFFF, 0, 0x80000000]:
        for W in (16, 32):
            e = K.kat_element(r, W)
            v = fmt.from_bits(e, W)
            assert 0.25 <= abs(v) < 4.0 and np.isfinite(v)
    g = regmap.Geometry(width=16, pdim=8, lanes=2)
    W, B, X = K.kat_stream(g, 16)
    assert W.shape == (2, g.nwords, 8) and len(X) == 4 and len(X[0]) == 8


def test_fmt_bf16_rne():
    # same as sim/test_fused_bf16.py to_bits
    for v in (0.1, -3.14159, 1e-3, 65504.0, 1.0, 0.0):
        u = int(np.float32(v).view(np.uint32))
        want = ((u >> 16) + ((u >> 15) & 1)) & 0xFFFF
        assert fmt.to_bits(v, 16) == want
    assert fmt.to_bits(1.0, 32) == 0x3F800000
    assert fmt.from_bits(0x3F80, 16) == 1.0
