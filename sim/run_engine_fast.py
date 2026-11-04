"""ladder_engine_fast against the existing ladder_engine testbench."""
import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_mul.v", "fp_fma.v", "ladder_scan_scalar.v", "recip_nr.v",
            "ladder_engine_fast.v")]

if __name__ == "__main__":
    d = int(os.environ.get("WL_DEPTH", "7"))
    g = int(os.environ.get("COFR_GEN", "0"))
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
    build = Path("sim_build") / f"engine_fast_d{d}_g{g}"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name)
    shutil.copy(mem, Path.cwd() / mem.name)
    run(dut_sources=SOURCES, hdl_toplevel="ladder_engine_fast",
        test_module="test_ladder_engine",
        parameters={"DEPTH": d, "GEN": g, "SEED_FILE": f'"{mem.name}"'},
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
