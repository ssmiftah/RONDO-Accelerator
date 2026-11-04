"""Runner for the pipelined NR reciprocal. The seed table is read by $readmemh,
so the build directory needs it alongside the sources."""
import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

SOURCES = [ROOT / "rtl" / "core" / n for n in ("fp_fma.v", "fp_mul.v", "recip_nr.v")]

if __name__ == "__main__":
    tbits = int(os.environ.get("WL_TBITS", "12"))
    mem = ROOT / "rtl" / "core" / f"recip_seed_e8s24_t{tbits}.mem"
    build = Path("sim_build") / f"recip_nr_t{tbits}"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name)          # $readmemh resolves from the sim cwd
    shutil.copy(mem, Path.cwd() / mem.name)
    run(dut_sources=SOURCES, hdl_toplevel="recip_nr", test_module="test_recip_nr",
        parameters={"TBITS": tbits, "SEED_FILE": f'"{mem.name}"'},
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
