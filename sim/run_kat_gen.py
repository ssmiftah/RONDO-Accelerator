"""Helper for scripts/gen_kat_sig.py (not a regression test: skipped by run_all unless KAT_GEN is set)."""
import os, sys
from run_chip_regs import build_and_run

if __name__ == "__main__":
    geom = os.environ.get("KAT_GEOM", "small")
    if "KAT_GEN" not in os.environ:
        # run_all picks this up: do a quick SMALL generation run that only checks agreement with the model
        geom = "small"
    p = dict(WIDTH=16, PDIM=8, N_LANES=2) if geom == "small" else dict(WIDTH=64, PDIM=40, N_LANES=8)
    os.environ["CHIP_GEOM"] = geom
    build_and_run(f"katgen_{geom}", "tb_chip_vs_core", "test_kat_gen", p)
