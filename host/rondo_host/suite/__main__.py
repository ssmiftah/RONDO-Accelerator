"""python -m rondo_host.suite --target mock|fpga|chip [--vectors rondo_vectors_small.npz] [--only case,case]

`sim` runs through the cocotb testbench instead: sim/run_chip_suite.py (same functions, same vectors)."""
import argparse
import sys
from .cases import Vectors, run_suite
from . import targets


def main(argv=None):
    ap = argparse.ArgumentParser(prog="rondo_host.suite")
    ap.add_argument("--target", choices=("mock", "fpga", "chip"), default="mock")
    ap.add_argument("--vectors", required=True)
    ap.add_argument("--only")
    a = ap.parse_args(argv)
    v = Vectors(a.vectors)
    r, ctx = targets.mock_target(v) if a.target == "mock" else targets.hw_target(v, a.target)
    res = run_suite(r, v, ctx, only=a.only.split(",") if a.only else None)
    bad = [n for n, ok, _ in res if not ok]
    print(f"{len(res) - len(bad)}/{len(res)} cases passed" + (f"; FAILED: {bad}" if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
