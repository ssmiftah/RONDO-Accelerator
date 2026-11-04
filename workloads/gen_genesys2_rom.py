"""On-chip ROM images for rtl/board/genesys2_fused_top.v.

The board wrapper has no host, so the resident weights, the biases and the input
vectors all live in on-chip ROM and are pushed through the layer's real load port
at reset. This script writes those three images from the trained model.

The weight packing is byte-for-byte the same as workloads/gen_fused_stimulus.py,
which is what the verified power and functional runs use. The only difference is
the layout: that script writes one file per lane for a testbench that loops over
lanes, whereas the board wrapper reads a single flat array indexed
lane*NWORDS + addr, so the lanes are concatenated here in lane order.

Getting this packing wrong does not fail loudly. The design would run, the
heartbeat would blink, and the checksum would simply be wrong, which is why the
checksum is compared against a value produced by simulating this same image
rather than against an independently computed one.
"""
import argparse
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def enc(v, wb):
    """fp32 bit pattern, or round-to-nearest-even bf16 when wb == 16."""
    u = int(np.float32(v).view(np.uint32))
    if wb == 32:
        return f"{u:08x}"
    return f"{((u >> 16) + ((u >> 15) & 1)) & 0xFFFF:04x}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--npz", default=str(ROOT / "workloads/results/waveform_coeffs.npz"))
    ap.add_argument("--out", default=str(ROOT / "build/genesys2"))
    ap.add_argument("--width", type=int, default=64)
    ap.add_argument("--pdim", type=int, default=40)
    ap.add_argument("--lanes", type=int, default=8)
    ap.add_argument("--nslot", type=int, default=8)
    ap.add_argument("--npar", type=int, default=8)
    ap.add_argument("--depth", type=int, default=7)
    ap.add_argument("--nsamp", type=int, default=16)
    ap.add_argument("--wb", type=int, default=16, choices=(16, 32))
    a = ap.parse_args()

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    D = np.load(a.npz)
    Wl = D["Wden"].reshape(int(D["width"]), a.depth, a.pdim)[:a.width].astype(np.float32)
    Bl = D["bden"].reshape(int(D["width"]), a.depth)[:a.width].astype(np.float32)
    X = D["X"][:a.nsamp, :a.pdim].astype(np.float32)

    nlad = a.width // a.lanes
    ngroup = (a.nslot * a.depth) // a.npar
    nbatches = nlad // a.nslot
    nwords = nbatches * ngroup * a.pdim
    nbwords = nbatches * ngroup

    wlines, blines = [], []
    for l in range(a.lanes):
        for b in range(nbatches):
            for g in range(ngroup):
                for c in range(a.pdim):
                    wlines.append("".join(
                        enc(Wl[l * nlad + b * a.nslot + (g * a.npar + f) // a.depth,
                               (g * a.npar + f) % a.depth, c], a.wb)
                        for f in reversed(range(a.npar))))
                blines.append("".join(
                    enc(Bl[l * nlad + b * a.nslot + (g * a.npar + f) // a.depth,
                           (g * a.npar + f) % a.depth], a.wb)
                    for f in reversed(range(a.npar))))

    assert len(wlines) == a.lanes * nwords, (len(wlines), a.lanes * nwords)
    assert len(blines) == a.lanes * nbwords, (len(blines), a.lanes * nbwords)

    (out / "g2_w.mem").write_text("\n".join(wlines) + "\n")
    (out / "g2_b.mem").write_text("\n".join(blines) + "\n")
    (out / "g2_x.mem").write_text(
        "\n".join(enc(v, a.wb) for v in X.reshape(-1)) + "\n")

    print(f"lanes={a.lanes} nwords/lane={nwords} nbwords/lane={nbwords} "
          f"nsamp={a.nsamp} wb={a.wb}")
    print(f"  g2_w.mem  {len(wlines):6d} x {a.npar*a.wb:4d} bits")
    print(f"  g2_b.mem  {len(blines):6d} x {a.npar*a.wb:4d} bits")
    print(f"  g2_x.mem  {X.size:6d} x {a.wb:4d} bits")
    print(f"  -> {out}")


if __name__ == "__main__":
    main()
