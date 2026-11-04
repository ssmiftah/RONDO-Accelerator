import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma.v", "recip_wrap.v", "ladder_engine_naive.v")]
if __name__ == "__main__":
    d = int(os.environ.get("WL_DEPTH", "7"))
    run(dut_sources=SOURCES, hdl_toplevel="ladder_engine_naive",
        test_module="test_naive", parameters={"DEPTH": d},
        build_dir=f"sim_build/naive_d{d}", hf_sources=HF_ALL_SOURCES)
