import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES, require_env

SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_mul.v", "fp_fma.v", "ladder_scan_scalar.v", "recip_nr.v", "ladder_engine_fast.v")]

if __name__ == "__main__":
    require_env('WL_NPZ', 'WL_OUT')
    d = int(os.environ.get("WL_DEPTH", "7"))
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
    build = Path("sim_build") / f"wl_lane_{os.environ.get('WL_TAG','x')}"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
    run(dut_sources=SOURCES, hdl_toplevel="ladder_engine_fast",
        test_module="test_workload_lane",
        parameters={"DEPTH": d, "GEN": 0, "SEED_FILE": f'"{mem.name}"'},
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
