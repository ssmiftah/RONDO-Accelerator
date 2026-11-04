import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES
if __name__ == "__main__":
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
    build = Path("sim_build") / "recip_nr_pipe"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
    run(dut_sources=[ROOT/"rtl"/"core"/n for n in ("fp_fma_pipe.v", "recip_nr_pipe.v")],
        hdl_toplevel="recip_nr_pipe", test_module="test_recip_nr",
        parameters={"TBITS": 12, "SEED_FILE": f'"{mem.name}"'},
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
