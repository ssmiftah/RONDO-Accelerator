"""Generate the Newton-Raphson seed table for recip_nr.

The seed approximates 1/m for m in [1,2), indexed by the top TBITS fraction bits.
Values are taken at each interval's midpoint so neither endpoint is a special
case. Stored as the *mantissa field* of the seed: the exponent is computed
arithmetically in hardware, so only the fraction needs a table.

    python3 rtl/core/gen_recip_table.py --exp 8 --sig 24 --tbits 12

One iteration of x <- x(2 - b*x) then reaches 2 ULP at fp32 (validated in
sim/test_recip_nr.py against the same model).
"""
import argparse
from pathlib import Path


def build(sig: int, tbits: int):
    frac_bits = sig - 1
    out = []
    for i in range(1 << tbits):
        m_mid = 1.0 + (i + 0.5) / (1 << tbits)
        r = 2.0 / m_mid                       # in (1,2]: the leading 1 is implicit
        mant = int(round((r - 1.0) * (1 << frac_bits)))
        out.append(min(max(mant, 0), (1 << frac_bits) - 1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exp", type=int, default=8)
    ap.add_argument("--sig", type=int, default=24)
    ap.add_argument("--tbits", type=int, default=12)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    tab = build(a.sig, a.tbits)
    nib = (a.sig - 1 + 3) // 4
    path = Path(a.out or Path(__file__).parent /
                f"recip_seed_e{a.exp}s{a.sig}_t{a.tbits}.mem")
    path.write_text("\n".join(f"{v:0{nib}x}" for v in tab) + "\n")
    print(f"{len(tab)} entries, {a.sig-1} bits each -> {path.name} "
          f"({len(tab)*(a.sig-1)/8/1024:.1f} KB)")


if __name__ == "__main__":
    main()
