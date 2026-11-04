import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES, require_env
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("mat2x2_mul.v", "fp_mul.v", "ladder_scan_iter.v",
            "recip_wrap.v", "ladder_engine.v", "cofr_coproc.v")]
if __name__ == "__main__":
    require_env('WL_LANES', 'WL_OUT')
    lanes = int(os.environ["WL_LANES"])
    width = int(os.environ.get("WL_WIDTH", "24"))
    run(dut_sources=SOURCES, hdl_toplevel="cofr_coproc", test_module="test_lane_sweep",
        parameters={"DEPTH": 7, "WIDTH": width, "N_LANES": lanes, "GEN": 0},
        build_dir=f"sim_build/lanes_{lanes}", hf_sources=HF_ALL_SOURCES)
