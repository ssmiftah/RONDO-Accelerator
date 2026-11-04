"""Runner for kan_layer_pipe (fp32) / kan_layer_bf16.

    cd sim && SIM=verilator ../.venv-rtl/bin/python run_kan_layer.py \
        [--fmt fp32|bf16] [--p 40] [--nout 64] [--lanes 8] [--nob 8] [--nmac 8] \
        [--nbas 1] [--depth 7] [--in stim.npz | --synth NSAMP] [--check 2] [--out path.npz]

Synthetic stimulus (default): coefficients ~ N(0, 1/(p(D+1))) (the training
initialiser's scale, times 4), inputs uniform in (-1, 1) plus the edge values
+-1 and 0, so the recurrence is exercised at the ends of its interval.
With no arguments it runs the regression configuration used by run_all.py.
"""
import argparse, os, sys
from pathlib import Path
import numpy as np
from cocotb_common import ROOT, run, HF_FMA_SOURCES

SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma_pipe.v", "kan_basis_inter.v", "kan_sum_bank.v",
            "kan_layer_pipe.v", "kan_layer_bf16.v")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fmt", default="fp32", choices=("fp32", "bf16"))
    ap.add_argument("--p", type=int, default=10)
    ap.add_argument("--nout", type=int, default=16)
    ap.add_argument("--lanes", type=int, default=2)
    ap.add_argument("--nob", type=int, default=8)
    ap.add_argument("--nmac", type=int, default=8)
    ap.add_argument("--nbas", type=int, default=1)
    ap.add_argument("--depth", type=int, default=7)
    ap.add_argument("--in", dest="inp", default=None)
    ap.add_argument("--synth", type=int, default=4)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--check", type=int, default=None)
    ap.add_argument("--maxsamp", type=int, default=None)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    os.environ.setdefault("SIM", "verilator")

    top = "kan_layer_pipe" if a.fmt == "fp32" else "kan_layer_bf16"
    tag = (f"kan_{a.fmt}_p{a.p}_o{a.nout}_l{a.lanes}_b{a.nob}_m{a.nmac}"
           f"_s{a.nbas}_d{a.depth}")
    # Build root is sim_build_kan, not sim_build. Runners that build directly in
    # sim_build (run_smoke, run_mat2x2, run_recip use the default build_dir)
    # leave a sim_build/verilator.o there, and make then links THAT object --
    # cocotb's main compiled against another design's Vtop.h, or an older
    # Verilator's headers -- into every build under sim_build/<tag>. The model
    # class layout no longer matches and the simulation corrupts its own heap:
    # segfaults at the first eval or "corrupted size vs. prev_size" at exit,
    # depending on the design. Refuse to run if such an object is present.
    build = Path(__file__).resolve().parent / "sim_build_kan" / tag
    build.mkdir(parents=True, exist_ok=True)
    if (build.parent / "verilator.o").exists():
        sys.exit(f"stale {build.parent / 'verilator.o'} would be linked into this build; remove it")

    if a.inp is None:
        rng = np.random.default_rng(a.seed)
        dp1 = a.depth + 1
        c = rng.normal(0, 4.0 / (a.p * dp1), (a.nout, a.p, dp1))
        xt = rng.uniform(-1, 1, (a.synth, a.p))
        xt[0, :3] = [1.0, -1.0, 0.0]
        stim = build / "stim_synth.npz"
        np.savez(stim, xt=xt, c=c)
        check = a.synth if a.check is None else a.check
    else:
        stim = Path(a.inp).resolve()
        check = 2 if a.check is None else a.check
    out = Path(a.out).resolve() if a.out else build / "result.npz"
    os.environ["KAN_IN"] = str(stim)
    os.environ["KAN_OUT"] = str(out)
    os.environ["KAN_CHECK"] = str(check)
    if a.maxsamp:
        os.environ["KAN_MAXSAMP"] = str(a.maxsamp)

    params = dict(DEPTH=a.depth, P_IN=a.p, N_OUT=a.nout, N_LANES=a.lanes,
                  NOB=a.nob, NMAC=a.nmac, NBAS=a.nbas)
    out.with_suffix(".json").unlink(missing_ok=True)
    run(dut_sources=SOURCES, hdl_toplevel=top, test_module="test_kan_layer",
        parameters=params, build_dir=str(build), hf_sources=HF_FMA_SOURCES)
    # cocotb exits 0 on a failed test; make the runner's exit status honest
    res = out.with_suffix(".json")
    if not res.exists():
        sys.exit("no result written: the test did not complete")
    import json
    r = json.loads(res.read_text())
    if r["bitexact_mismatch"] != 0:
        sys.exit(f"bit-exact check failed: {r['bitexact_mismatch']} mismatches")


if __name__ == "__main__":
    main()
