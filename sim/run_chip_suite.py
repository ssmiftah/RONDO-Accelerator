"""T-SUITE (sim target): the host suite (host/rondo_host/suite) through CocotbTransport on rondo_chip_top SMALL with the SMALL vectors
(scripts/gen_vectors.py); FULL under Verilator with CHIP_GEOM=full.

The vectors are generated with an interpreter that has numpy (and imports sim/chip_common): RONDO_PY, else ROOT/.venv-rtl/bin/python, else
sys.executable. (cocotb_common canonicalizes sys.executable with realpath, which for a venv python is the base interpreter without the
venv's packages, so sys.executable alone is not reliable.) They are regenerated when scripts/gen_vectors.py or
host/rondo_host/suite/cases.py is newer than the .npz."""
import os
import subprocess
import sys
from pathlib import Path
from run_chip_regs import build_and_run

ROOT = Path(__file__).resolve().parents[1]


def vector_python():
    env = os.environ.get("RONDO_PY")
    if env:
        return env
    venv = ROOT / ".venv-rtl" / "bin" / "python"
    return str(venv) if venv.exists() else sys.executable


def ensure_vectors(geom):
    vec = ROOT / "build" / "vectors" / f"rondo_vectors_{geom}.npz"
    srcs = [ROOT / "scripts" / "gen_vectors.py", ROOT / "host" / "rondo_host" / "suite" / "cases.py"]
    if vec.exists() and all(vec.stat().st_mtime >= s.stat().st_mtime for s in srcs):
        return vec
    py = vector_python()
    if subprocess.run([py, "-c", "import numpy"], capture_output=True).returncode != 0:
        sys.exit(f"run_chip_suite: gen_vectors.py needs numpy, but the interpreter {py} has none: set RONDO_PY or create .venv-rtl")
    subprocess.check_call([py, str(ROOT / "scripts" / "gen_vectors.py"), geom])
    return vec


if __name__ == "__main__":
    geom = os.environ.get("CHIP_GEOM", "small")
    vec = ensure_vectors(geom)
    os.environ["SUITE_VECTORS"] = str(vec)
    if geom == "full":
        os.environ["SIM"] = "verilator"
    p = dict(HB_BIT=7) if geom == "small" else dict(HB_BIT=7, WIDTH=64, PDIM=40, N_LANES=8)
    if geom == "small":
        p.update(WIDTH=16, PDIM=8, N_LANES=2)
    build_and_run(f"suite_{geom}", "rondo_chip_top", "test_chip_suite", p, tb=None, with_top=True)
