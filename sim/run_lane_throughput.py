import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_ALL_SOURCES, require_env

FAST = os.environ.get("WL_FAST", "0") == "1"
if FAST:
    NAMES = ("fp_mul.v", "fp_fma.v", "ladder_scan_scalar.v", "recip_nr.v", "ladder_engine_fast.v")
    TOP = "ladder_engine_fast"
else:
    NAMES = ("mat2x2_mul.v", "fp_mul.v", "ladder_scan_iter.v", "recip_wrap.v", "ladder_engine.v")
    TOP = "ladder_engine"

if __name__ == "__main__":
    require_env('WL_OUT')
    d = int(os.environ.get("WL_DEPTH", "7"))
    params = {"DEPTH": d, "GEN": 0}
    build = Path("sim_build") / f"lane_tp_{TOP}_d{d}"
    build.mkdir(parents=True, exist_ok=True)
    if FAST:
        mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
        shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
        params["SEED_FILE"] = f'"{mem.name}"'
    run(dut_sources=[ROOT / "rtl" / "core" / n for n in NAMES], hdl_toplevel=TOP,
        test_module="test_lane_throughput", parameters=params,
        build_dir=str(build), hf_sources=HF_ALL_SOURCES)
