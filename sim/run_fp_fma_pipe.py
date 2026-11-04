from cocotb_common import ROOT, run, HF_FMA_SOURCES
if __name__ == "__main__":
    run(dut_sources=[ROOT / "rtl" / "core" / "fp_fma_pipe.v"],
        hdl_toplevel="fp_fma_pipe", test_module="test_fp_fma_pipe",
        build_dir="sim_build/fp_fma_pipe", hf_sources=HF_FMA_SOURCES)
