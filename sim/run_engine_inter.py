import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v", "ladder_engine_inter.v")]
if __name__ == "__main__":
    d = int(os.environ.get("WL_DEPTH", "7")); n = int(os.environ.get("WL_NSLOT", "8"))
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
    build = Path("sim_build") / f"engine_inter_d{d}_n{n}"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
    run(dut_sources=SOURCES, hdl_toplevel="ladder_engine_inter",
        test_module="test_engine_inter",
        parameters={"DEPTH": d, "NSLOT": n, "SEED_FILE": f'"{mem.name}"'},
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
