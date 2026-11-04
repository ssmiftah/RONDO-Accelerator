"""Runner for the W1/W2 coefficient replay. Config comes from the environment:
WL_NPZ, WL_TAG, WL_DEPTH, WL_WIDTH, WL_LANES, and optionally WL_EXP/WL_SIG/WL_EPSBITS.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_workload.py
"""
import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES, require_env

SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("mat2x2_mul.v", "fp_mul.v", "ladder_scan_iter.v",
            "recip_wrap.v", "ladder_engine.v", "cofr_coproc.v")]

if __name__ == "__main__":
    require_env('WL_NPZ')
    depth = int(os.environ.get("WL_DEPTH", "7"))
    width = int(os.environ.get("WL_WIDTH", "16"))
    lanes = int(os.environ.get("WL_LANES", "4"))
    params = {"DEPTH": depth, "WIDTH": width, "N_LANES": lanes, "GEN": 0}
    if os.environ.get("WL_EXP"):
        params |= {"EXP": int(os.environ["WL_EXP"]), "SIG": int(os.environ["WL_SIG"]),
                   "EPS": int(os.environ["WL_EPSBITS"])}
    tag = os.environ.get("WL_TAG", "wl")
    run(dut_sources=SOURCES, hdl_toplevel="cofr_coproc", test_module="test_workload",
        parameters=params, build_dir=f"sim_build/wl_{tag}", hf_sources=HF_ALL_SOURCES)
