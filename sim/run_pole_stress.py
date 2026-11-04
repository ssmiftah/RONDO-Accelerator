import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES, require_env
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("mat2x2_mul.v", "fp_mul.v", "ladder_scan_iter.v",
            "recip_wrap.v", "ladder_engine.v", "cofr_coproc.v")]
if __name__ == "__main__":
    require_env('WL_EPSBITS', 'WL_OUT')
    run(dut_sources=SOURCES, hdl_toplevel="cofr_coproc", test_module="test_pole_stress",
        parameters={"DEPTH": int(os.environ.get("WL_DEPTH", "7")), "WIDTH": 8,
                    "N_LANES": 4, "GEN": 0, "EPS": int(os.environ["WL_EPSBITS"])},
        build_dir=f"sim_build/pole_{os.environ.get('WL_TAG','p')}", hf_sources=HF_ALL_SOURCES)
