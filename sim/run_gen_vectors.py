"""Helper for scripts/gen_vectors.py (not a regression test unless GV_OUT is set: then it writes the vector file)."""
import os, sys
from pathlib import Path
from run_chip_regs import build_and_run

if __name__ == "__main__":
    geom = os.environ.get("GV_GEOM", "small")
    os.environ["CHIP_GEOM"] = geom
    if "GV_OUT" not in os.environ:
        os.environ["GV_OUT"] = str(Path(__file__).resolve().parents[1] / "build" / "vectors" / f"rondo_vectors_{geom}.npz")
    if geom == "full":
        os.environ["SIM"] = "verilator"
    p = dict(HB_BIT=6) if geom == "small" else dict(WIDTH=64, PDIM=40, N_LANES=8, HB_BIT=6)
    build_and_run(f"genvec_{geom}", "tb_chip_vs_core", "gen_vectors_sim", p)
