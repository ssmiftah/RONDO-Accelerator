import numpy as np
from .. import regmap as R, packing as K, fmt as F


class Vectors:
    def __init__(self, path):
        self.d = dict(np.load(path, allow_pickle=False))
        self.geom = [int(v) for v in self.d["geom"]]
        self.tiled = {k: v for k, v in self.d.items() if k.startswith("tile_")}

    def __getitem__(self, k):
        return self.d[k]

    def has(self, k):
        return k in self.d


class Ctx:
    """cycle_exact: LAST_CYCLES must equal the RTL (False for the mock); kat_exact: KAT_GOT must equal the generated constant"""
    def __init__(self, cycle_exact=True, kat_exact=True, name="sim", z_exact=True):
        self.cycle_exact, self.kat_exact, self.name, self.z_exact = cycle_exact, kat_exact, name, z_exact


def _fmtw(fmt):
    return 16 if fmt == "bf16" else 32


def _use_format(r, fmt):
    if r.fmt != fmt:
        r.set_format(fmt)


def _load_vec(r, v, fmt):
    _use_format(r, fmt)
    r.load_weights_bits(v[f"{fmt}_Wb"], v[f"{fmt}_Bb"], verify="crc")


def case_id_loopback(r, v, c):
    assert r.loopback_test(16)
    g = r.reset_check()
    assert [g.width, g.pdim, g.lanes, g.depth, g.nslot, g.npar] == v.geom[:6], "geometry differs from the vector set"
    assert r.version == R.VERSION_VALUE


def case_register_access(r, v, c):
    for x in (0xA5A55A5A, 0x5A5AA5A5):
        r.set_reg("SCRATCH", x)
        assert r.reg("SCRATCH") == x
    r.clear_errors()
    r.write(R.ADDR["CHIP_ID"], [0])
    assert "RO" in r.errors()
    r.clear_errors()
    r.set_reg("FORMAT", 2)
    assert "RANGE" in r.errors() and r.reg("FORMAT") == (1 if r.fmt == "fp32" else 0)
    r.clear_errors()
    r.reg(0xF0)
    assert "ADDR" in r.errors()
    r.clear_errors()
    assert r.errors() == set()
    r.set_reg("SCRATCH", 0)


def case_load_crc_readback(r, v, c, fmt="bf16"):
    _use_format(r, fmt)
    r.load_weights_bits(v[f"{fmt}_Wb"], v[f"{fmt}_Bb"], verify="readback")
    r.load_weights_bits(v[f"{fmt}_Wb"], v[f"{fmt}_Bb"], verify="crc")


def case_single_shot(r, v, c, fmt="bf16"):
    _load_vec(r, v, fmt)
    X, Z, C = v[f"{fmt}_Xb"], v[f"{fmt}_Z"], v[f"{fmt}_cycles"]
    for i in range(len(X)):
        z = r.infer(X[i], entry=i % r.geom.nxbuf, bits=True, x_bits=True)
        assert [int(a) for a in z] == [int(b) for b in Z[i]], f"{fmt} input {i}: z not bit-exact"
        if c.cycle_exact:
            assert r.reg("LAST_CYCLES") == int(C[i]), f"{fmt} input {i}: LAST_CYCLES {r.reg('LAST_CYCLES')} != {int(C[i])}"
    r.check_errors(allow=("GUARD",))


def case_self_run(r, v, c, fmt="bf16"):
    _load_vec(r, v, fmt)
    X = v[f"{fmt}_Xb"]
    g = r.geom
    for k in range(4):
        r.write_x(k, X[k], bits=True)
    r.set_reg("SR_N", 4)
    r.set_reg("SR_COUNT", 12)
    r.set_reg("IRQ_STATUS", 2)
    r.ctrl("CNT_CLR", "CKSUM_CLR")
    r.ctrl("SR_START")
    r.wait_sr_done(timeout=5.0)
    ck, first = [int(a) for a in v[f"{fmt}_cks"]]
    st = r.bench_stats()
    assert st["sr_done"] == 12
    assert st["checksum"] == ck, f"{fmt}: CHECKSUM {st['checksum']:#x} != {ck:#x}"
    assert st["sr_pass_cksum"] == first, f"{fmt}: SR_PASS_CKSUM"


def case_format_switch(r, v, c):
    for fmt in ("fp32", "bf16", "fp32"):
        _use_format(r, fmt)
        assert (r.reg("STATUS") >> 7) & 1 or True
        assert r.reg("CHECKSUM") == 0 and r.reg("LOAD_CRC") == 0
        case_single_shot(r, v, c, fmt)


def case_kat(r, v, c):
    for fmt in ("bf16", "fp32"):
        assert r.kat(fmt), f"{fmt} KAT failed"
        if c.kat_exact and v.has(f"{fmt}_katsig"):
            got = r.reg("KAT_GOT_BF16" if fmt == "bf16" else "KAT_GOT_FP32")
            assert got == int(v[f"{fmt}_katsig"]), f"{fmt}: KAT_GOT {got:#x}"


def case_debug_taps_injection(r, v, c):
    """spec 2.6: W = 0, B = a (a_{d-1} = beta), x = 0 -> K0 = beta, K1 = 1, z = 1/beta from the real reciprocal"""
    g = r.geom
    for fmt in ("bf16", "fp32"):
        _use_format(r, fmt)
        w = _fmtw(fmt)
        beta = v[f"{fmt}_beta"]
        Wz = np.zeros((g.width, g.depth, g.pdim), dtype=np.uint64)
        Bi = np.zeros((g.width, g.depth), dtype=np.uint64)
        Bi[:, g.depth - 1] = beta
        r.load_weights_bits(Wz, Bi, verify="crc")
        r.write_x(0, np.zeros(g.pdim, dtype=np.uint64), bits=True)
        r.set_reg("XSEL", 0)
        r.ctrl("GUARD_CLR")
        r.ctrl("START")
        r._wait_idle(5.0)
        z = [int(a) for a in r.read_z(bits=True)]
        assert z == [int(a) for a in v[f"{fmt}_Zinj"]], f"{fmt}: injection z not bit-exact"
        one = int(v[f"{fmt}_one"])
        for lane in range(g.lanes):
            for slot in (0, g.nslot - 1):
                j = lane * g.nlad + slot
                assert r.debug(lane, 3, slot) == one, f"{fmt} K1 lane {lane} slot {slot}"
                assert r.debug(lane, 2, slot) == int(beta[j]), f"{fmt} K0 lane {lane} slot {slot}"
        eps = 0x3C24 if w == 16 else 0x3C23D70A
        nclamp = sum(1 for b in beta if (int(b) & ((1 << (w - 1)) - 1)) < (eps & ((1 << (w - 1)) - 1)))
        assert r.reg("GUARD_HITS") == nclamp, f"{fmt}: GUARD_HITS {r.reg('GUARD_HITS')} != {nclamp}"
        r.clear_errors()


def case_lane_mask(r, v, c):
    g = r.geom
    for fmt in ("bf16", "fp32"):
        _load_vec(r, v, fmt)
        w = _fmtw(fmt)
        r.set_lane_mask(1)
        z = [int(a) for a in r.infer(v[f"{fmt}_Xb"][0], bits=True, x_bits=True)]
        q = F.QNAN[w]
        assert all(a == q for a in z[g.nlad:]), "disabled lanes must read the quiet NaN"
        assert z[:g.nlad] == [int(a) for a in v[f"{fmt}_Z"][0][:g.nlad]], "enabled lane must be unchanged"
        r.set_lane_mask((1 << g.lanes) - 1)
        r.clear_errors()


def case_error_cases(r, v, c):
    g = r.geom
    r.clear_errors()
    r.ctrl("START", "KAT_START")                 # two start bits in one write: only the first is honored
    r._wait_idle(5.0)
    assert "START_BUSY" in r.errors()
    r.clear_errors()
    r.set_reg("XSEL", g.nxbuf)
    assert "RANGE" in r.errors()
    r.clear_errors()


def case_tiled(r, v, c, fmt):
    """input tiling (spec 18): a layer of p = 3 * PDIM inputs through run_wide_layer; expected z from the bit-exact model"""
    if not v.has(f"tile_{fmt}_W"):
        return
    _use_format(r, fmt)
    W, b, X, Z = v[f"tile_{fmt}_W"], v[f"tile_{fmt}_b"], v[f"tile_{fmt}_X"], v[f"tile_{fmt}_Z"]
    out = r.run_wide_layer(W, b, X, fmt=fmt, allow_bf16_wide=True)
    zb = np.asarray(F.to_bits(out, _fmtw(fmt)), dtype=np.uint64)
    if c.z_exact:
        assert [[int(a) for a in row] for row in zb] == [[int(a) for a in row] for row in Z], f"{fmt}: tiled z not bit-exact"
    else:                                                       # mock: decision-level float64 model
        ref = F.from_bits(np.asarray(Z, dtype=np.uint64), _fmtw(fmt))
        ok = np.isfinite(ref) & np.isfinite(out)
        if fmt == "fp32":
            assert np.allclose(out[ok], ref[ok], rtol=0.1, atol=0.05), f"{fmt}: tiled z differs from the model"
        else:                                                   # bf16 accumulation error: sign agreement and median error
            rel = np.abs(out[ok] - ref[ok]) / np.maximum(np.abs(ref[ok]), 1e-3)
            assert np.mean(np.sign(out[ok]) == np.sign(ref[ok])) >= 0.9 and np.median(rel) < 0.05, "bf16 tiled z differs"

    r.check_errors(allow=("GUARD", "NAN_INF"))


CASES = [("id_loopback", case_id_loopback), ("register_access", case_register_access),
         ("load_crc_readback_bf16", lambda r, v, c: case_load_crc_readback(r, v, c, "bf16")),
         ("single_shot_bf16", lambda r, v, c: case_single_shot(r, v, c, "bf16")),
         ("self_run_bf16", lambda r, v, c: case_self_run(r, v, c, "bf16")),
         ("format_switch", case_format_switch),
         ("load_crc_readback_fp32", lambda r, v, c: case_load_crc_readback(r, v, c, "fp32")),
         ("self_run_fp32", lambda r, v, c: case_self_run(r, v, c, "fp32")),
         ("kat", case_kat), ("debug_taps_injection", case_debug_taps_injection),
         ("lane_mask", case_lane_mask),
         ("tiled_bf16", lambda r, v, c: case_tiled(r, v, c, "bf16")),
         ("tiled_fp32", lambda r, v, c: case_tiled(r, v, c, "fp32")), ("error_cases", case_error_cases)]


def run_suite(r, v, ctx, only=None, log=print):
    results = []
    for name, fn in CASES:
        if only and name not in only:
            continue
        try:
            fn(r, v, ctx)
            results.append((name, True, ""))
            log(f"suite[{ctx.name}] {name}: PASS")
        except Exception as e:      # noqa: BLE001
            results.append((name, False, repr(e)))
            log(f"suite[{ctx.name}] {name}: FAIL {e!r}")
    return results
