#!/usr/bin/env python3
"""Regression of the chip runners (T-REG ... T-CFG, spec 15/18) under Icarus and Verilator.

usage: scripts/chip_regress_new.py [icarus|verilator|both] [--slow] [name ...]
Runners that fix their own simulator (full-geometry ones: *_full, cofrgenet, gls, suite-full) run once, under Verilator.
--slow also runs the multi-minute ones (kat_full, full, cofrgenet, gls)."""
import os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "sim"
PY = str(ROOT / ".venv-rtl" / "bin" / "python")
SUMMARY = re.compile(r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)")
BOTH = ["units", "spi", "regs", "pack", "seq", "fmt", "top", "clk", "dbg", "trace", "kat", "mbist", "scanmode", "sva",
        "kan", "host", "tile", "suite"]
VERILATOR_ONLY = ["full", "kat_full", "cofrgenet", "gls"]


def run(name, sim):
    env = dict(os.environ, PYTHONPATH=str(SIM))
    if sim:
        env["SIM"] = sim
    p = subprocess.run([PY, f"run_chip_{name}.py"], cwd=SIM, env=env, capture_output=True, text=True, timeout=7200)
    out = p.stdout + p.stderr
    ms = SUMMARY.findall(out)
    ok = p.returncode == 0 and ms and all(f == "0" for _, _, f in ms) and sum(int(t) for t, _, _ in ms) > 0
    return ok, ms, out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    sims = ["icarus", "verilator"] if (not args or args[0] == "both") else [args[0]] if args[0] in ("icarus", "verilator") else ["icarus"]
    names = [a for a in args if a not in ("icarus", "verilator", "both")]
    slow = "--slow" in sys.argv
    bad = []
    # vectors are generated up front (the suite must not rely on lazy generation / a stale file)
    for geom in (["small"] + (["full"] if slow and not names else [])):
        p = subprocess.run([PY, str(ROOT / "scripts" / "gen_vectors.py"), geom], cwd=ROOT, capture_output=True, text=True, timeout=7200)
        print(f"gen_vectors {geom}: {'PASS' if p.returncode == 0 else 'FAIL'}", flush=True)
        if p.returncode != 0:
            bad.append(f"gen_vectors/{geom}"); print((p.stdout + p.stderr)[-1500:])
    for sim in sims:
        for n in (names or BOTH):
            ok, ms, out = run(n, sim)
            print(f"[{sim}] run_chip_{n}: {'PASS' if ok else 'FAIL'} {ms}", flush=True)
            if not ok:
                bad.append(f"{sim}/{n}"); print(out[-1500:])
    if slow and not names:
        for n in VERILATOR_ONLY:
            ok, ms, out = run(n, "verilator")
            print(f"[verilator] run_chip_{n}: {'PASS' if ok else 'FAIL'} {ms}", flush=True)
            if not ok:
                bad.append(f"verilator/{n}"); print(out[-1500:])
    print("CHIP REGRESSION", "FAIL: " + ", ".join(bad) if bad else "OK")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
