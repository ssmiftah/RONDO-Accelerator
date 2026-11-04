"""ladder_scan_scalar against the same checks ladder_scan_iter passes."""
import os
from cocotb_common import ROOT, run, HF_FMA_SOURCES
SOURCES = [ROOT / "rtl" / "core" / n for n in ("fp_mul.v", "fp_fma.v", "ladder_scan_scalar.v")]
if __name__ == "__main__":
    d = int(os.environ.get("WL_DEPTH", "7"))
    g = int(os.environ.get("COFR_GEN", "0"))
    run(dut_sources=SOURCES, hdl_toplevel="ladder_scan_scalar",
        test_module="test_scan_scalar",
        parameters={"DEPTH": d, "GEN": g},
        build_dir=f"sim_build/scan_scalar_d{d}_g{g}", hf_sources=HF_FMA_SOURCES)
