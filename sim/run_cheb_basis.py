import os
from cocotb_common import ROOT, run, HF_FMA_SOURCES
SOURCES = [ROOT / "rtl" / "core" / n for n in ("fp_fma_pipe.v", "kscan_inter.v")]
if __name__ == "__main__":
    d = int(os.environ.get("WL_DEPTH", "8"))
    n = int(os.environ.get("WL_NSLOT", "8"))
    run(dut_sources=SOURCES, hdl_toplevel="kscan_inter",
        test_module="test_cheb_basis",
        parameters={"DEPTH": d, "NSLOT": n, "NUMER_NEG": 1},
        build_dir=f"sim_build/chebbasis_d{d}_n{n}", hf_sources=HF_FMA_SOURCES)
