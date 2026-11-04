#!/usr/bin/env python3
"""Regression for the existing (T-OLD) test-suite after each core change.

1. sim/run_all.py. At baseline (before any chip change) 12 of 45 runners "fail" only because
   they are parameterised (need WL_* environment, run_all counts 0 tests as a failure); those
   12 are the KNOWN_ENV_SKIPS below. Any other failure is a regression.
2. Those parameterised runners that exercise the modified modules are then run explicitly
   with a small configuration so they really execute.
Usage: python3 scripts/chip_regress_old.py [icarus|verilator] [--quick]
"""
import os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim"
PY = str(ROOT / ".venv-rtl" / "bin" / "python")
KNOWN_ENV_SKIPS = {"run_depth_sweep.py", "run_engine_steady.py", "run_fused_bf16.py",
                   "run_fused_coproc.py", "run_fused_pipe.py", "run_lane_sweep.py",
                   "run_lane_sweep_inter.py", "run_lane_throughput.py", "run_pole_stress.py",
                   "run_workload.py", "run_workload_inter.py", "run_workload_lane.py"}
# fail under Verilator at the pristine baseline too (their sources are untouched: Verilator width lint in grad_a_inter.v /
# train_ladder_inter.v, and a stimulus.mem bound error in run_power_top); known, not caused by the chip changes
VERILATOR_BASELINE_FAILS = {"run_grad_a_inter.py", "run_power_top.py", "run_train_ladder_inter.py"}
SUMMARY = re.compile(r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)")
NPZ = str(ROOT / "workloads" / "results" / "waveform_coeffs.npz")


def sh(args, env_extra, timeout=3600):
    env = dict(os.environ, PYTHONPATH=str(SIM), **env_extra)
    p = subprocess.run(args, cwd=SIM, env=env, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def main():
    simname = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "icarus"
    quick = "--quick" in sys.argv
    env = {"SIM": simname}
    bad = []
    if not quick:
        # run_all.py globs every run_*.py, which now also includes the (slow) chip runners. The
        # core-change regression therefore runs the original runners plus the core-change tests
        # (run_core_c*.py) through run_all's own run_one(); the full run_all is the T35 job.
        sys.path.insert(0, str(SIM))
        os.environ["SIM"] = simname
        import importlib; ra = importlib.import_module("run_all"); ra.PY = PY
        new_re = re.compile(r"run_(chip_|kat_gen|gen_vectors|all)")
        names = sorted(p for p in SIM.glob("run_*.py") if not new_re.match(p.name))
        out = ""; npass = 0
        for p in names:
            ok, t_, p_, f_, rc_, dt_, o_ = ra.run_one(p)
            out += f"[{'PASS' if ok else 'FAIL'}] {p.name} tests={t_} pass={p_} fail={f_} rc={rc_}\n"
            npass += ok
            print(out.splitlines()[-1], flush=True)
        out += f"{npass}/{len(names)} runners passed\n"
        fails = set(re.findall(r"\[FAIL\] (\S+)", out))
        m = re.search(r"(\d+)/(\d+) runners passed", out)
        print(f"[{simname}] run_all (original runners + run_core_c*): {m.group(0) if m else 'no summary'}")
        unexpected = fails - KNOWN_ENV_SKIPS - (VERILATOR_BASELINE_FAILS if simname == "verilator" else set())
        missing = KNOWN_ENV_SKIPS - fails
        if unexpected:
            print("  UNEXPECTED FAILURES:", sorted(unexpected)); bad += sorted(unexpected)
            print(out[-3000:])
        if missing:
            print("  (note: previously env-skipped runners now pass:", sorted(missing), ")")
    # runners that build into the default sim_build/ itself leave verilated objects there; a parameterised runner built in a
    # sub-directory then crashes at start-up under Verilator (pre-existing; also with the original RTL). Remove the loose files.
    for p in (SIM / "sim_build").glob("*"):
        if p.is_file():
            p.unlink()
    outdir = ROOT / "build" / "chip_regress"
    outdir.mkdir(parents=True, exist_ok=True)
    jobs = [
        ("run_fused_pipe.py", dict(WL_NPZ=NPZ, WL_OUT=str(outdir), WL_MAXSAMP="2", WL_WIDTH="16",
                                    WL_PDIM="40", WL_LANES="2")),
        ("run_fused_bf16.py", dict(WL_NPZ=NPZ, WL_OUT=str(outdir), WL_MAXSAMP="2", WL_WIDTH="16",
                                    WL_PDIM="40", WL_LANES="2")),
        ("run_workload_inter.py", dict(WL_NPZ=NPZ, WL_OUT=str(outdir), WL_MAXSAMP="4",
                                        WL_WIDTH="16", WL_LANES="2")),
    ]
    for name, e in jobs:
        rc, out = sh([PY, name], dict(env, **e))
        ms = SUMMARY.findall(out)
        ok = rc == 0 and ms and all(int(f) == 0 for _, _, f in ms) and sum(int(t) for t, _, _ in ms) > 0
        print(f"[{simname}] {name}: {'PASS' if ok else 'FAIL'} {ms}")
        if not ok:
            bad.append(name); print(out[-2500:])
    print("REGRESSION", "FAIL: " + ", ".join(bad) if bad else "OK")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
