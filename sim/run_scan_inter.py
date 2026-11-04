import os
from cocotb_common import ROOT, run, HF_FMA_SOURCES
SOURCES = [ROOT / "rtl" / "core" / n for n in ("fp_fma_pipe.v", "ladder_scan_inter.v")]
if __name__ == "__main__":
    d = int(os.environ.get("WL_DEPTH", "7"))
    n = int(os.environ.get("WL_NSLOT", "8"))
    run(dut_sources=SOURCES, hdl_toplevel="ladder_scan_inter",
        test_module="test_scan_inter",
        parameters={"DEPTH": d, "NSLOT": n},
        build_dir=f"sim_build/scan_inter_d{d}_n{n}", hf_sources=HF_FMA_SOURCES)
