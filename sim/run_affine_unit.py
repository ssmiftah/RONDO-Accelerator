"""Runner for affine_unit. Config from WL_DEPTH / WL_PDIM / WL_NMAC."""
import os
from cocotb_common import ROOT, run, HF_FMA_SOURCES

SOURCES = [ROOT / "rtl" / "core" / "fp_fma.v", ROOT / "rtl" / "core" / "affine_unit.v"]

if __name__ == "__main__":
    d = int(os.environ.get("WL_DEPTH", "7"))
    p = int(os.environ.get("WL_PDIM", "8"))
    n = int(os.environ.get("WL_NMAC", "1"))
    run(dut_sources=SOURCES, hdl_toplevel="affine_unit", test_module="test_affine_unit",
        parameters={"DEPTH": d, "PDIM": p, "NMAC": n},
        build_dir=f"sim_build/affine_d{d}_p{p}_m{n}", hf_sources=HF_FMA_SOURCES)
