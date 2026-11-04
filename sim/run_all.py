"""CI: run every run_*.py and report a pass/fail summary. Exits non-zero on any
failure (build error, exception, or a cocotb test with FAIL>0).

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_all.py
    # or just:  ../.venv-rtl/bin/python run_all.py    (it sets PYTHONPATH itself)

Optionally pass SIM=verilator to run under Verilator instead of Icarus.
"""

import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Spawn subprocesses with the SAME interpreter we're running under (the .venv-rtl
# venv). Do NOT realpath it: that resolves the venv symlink to the base uv
# interpreter, which lacks the venv's packages (numpy/cocotb). The cocotb
# sys.executable warning is handled inside cocotb_common (PYGPI_PYTHON_BIN only).
PY = sys.executable

SUMMARY = re.compile(r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)")


def run_one(script):
    env = dict(os.environ, PYTHONPATH=str(HERE))
    t0 = time.time()
    proc = subprocess.run([PY, str(script)], cwd=str(HERE), env=env,
                          capture_output=True, text=True)
    dt = time.time() - t0
    out = proc.stdout + proc.stderr

    tests = passed = failed = 0
    for m in SUMMARY.finditer(out):
        tests += int(m.group(1)); passed += int(m.group(2)); failed += int(m.group(3))

    ok = (proc.returncode == 0) and (tests > 0) and (failed == 0)
    return ok, tests, passed, failed, proc.returncode, dt, out


def main():
    scripts = sorted(p for p in HERE.glob("run_*.py") if p.name != "run_all.py")
    if not scripts:
        print("no run_*.py found"); sys.exit(2)

    print(f"Running {len(scripts)} test runners with {PY}\n")
    results = []
    for s in scripts:
        ok, tests, passed, failed, rc, dt, out = run_one(s)
        results.append((s.name, ok))
        tag = "PASS" if ok else "FAIL"
        print(f"[{tag}] {s.name:24s} tests={tests:2d} pass={passed:2d} "
              f"fail={failed:2d} rc={rc} ({dt:5.1f}s)")
        if not ok:  # show the tail so failures are diagnosable in CI logs
            tail = "\n".join(out.strip().splitlines()[-15:])
            print("    ----- last output -----\n    " + tail.replace("\n", "\n    "))

    n_fail = sum(1 for _, ok in results if not ok)
    print(f"\n{len(results) - n_fail}/{len(results)} runners passed")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
