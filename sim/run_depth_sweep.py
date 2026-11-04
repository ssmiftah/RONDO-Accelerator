import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES, require_env
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("mat2x2_mul.v", "fp_mul.v", "ladder_scan_iter.v",
            "recip_wrap.v", "ladder_engine.v", "cofr_coproc.v")]
if __name__ == "__main__":
    require_env('WL_DEPTH', 'WL_OUT')
    d = int(os.environ["WL_DEPTH"])
    run(dut_sources=SOURCES, hdl_toplevel="cofr_coproc", test_module="test_depth_sweep",
        parameters={"DEPTH": d, "WIDTH": 1, "N_LANES": 1, "GEN": 0},
        build_dir=f"sim_build/depth_{d}", hf_sources=HF_ALL_SOURCES)
