#!/usr/bin/env python3
"""Generate the known-answer-test signatures (spec 11.5): runs the cocotb simulation of the configured
build for both formats, cross-checks the RTL against the bit-exact model and the golden f_ref, and writes
rtl/chip/rondo_kat_sigs.vh. usage: scripts/gen_kat_sig.py [small] [full]   (default: both)"""
import json, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PY = str(ROOT / ".venv-rtl" / "bin" / "python")
VH = ROOT / "rtl" / "chip" / "rondo_kat_sigs.vh"


def run(geom):
    env = dict(os.environ, PYTHONPATH=str(ROOT / "sim"), KAT_GEOM=geom, KAT_GEN="1",
               SIM="verilator" if geom == "full" else os.environ.get("SIM", "icarus"))
    p = subprocess.run([PY, "run_kat_gen.py"], cwd=ROOT / "sim", env=env, capture_output=True, text=True)
    out = p.stdout + p.stderr
    m = re.search(r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)", out)
    if p.returncode or not m or m.group(3) != "0":
        print(out[-3000:]); sys.exit(f"KAT generation failed for {geom}")
    for line in out.splitlines():
        if "KAT " in line and "signature" in line:
            print(line.split("INFO")[-1].strip())
    return json.loads((ROOT / "build" / "chip" / f"kat_sigs_{geom}.json").read_text())


def main():
    geoms = [a for a in sys.argv[1:] if a in ("small", "full")] or ["small", "full"]
    text = VH.read_text()
    for g in geoms:
        r = run(g)
        for f in ("bf16", "fp32"):
            name = f"RONDO_KATSIG_{g.upper()}_{f.upper()}"
            text = re.sub(rf"(`define {name}\s+)32'h[0-9a-fA-F]+", rf"\g<1>32'h{r[f]['sig']:08x}", text)
    VH.write_text(text)
    print(VH.read_text())


if __name__ == "__main__":
    main()
