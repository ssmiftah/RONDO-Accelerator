import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_ALL_SOURCES, require_env
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma.v", "fp_fma_pipe.v", "affine_bank.v", "ladder_scan_inter.v",
            "recip_nr_pipe.v", "ladder_engine_inter.v", "fused_coproc.v")]
if __name__ == "__main__":
    require_env('WL_NPZ')
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
    p = dict(DEPTH=int(os.environ.get("WL_DEPTH", "7")),
             WIDTH=int(os.environ.get("WL_WIDTH", "16")),
             PDIM=int(os.environ.get("WL_PDIM", "40")),
             N_LANES=int(os.environ.get("WL_LANES", "2")),
             NSLOT=int(os.environ.get("WL_NSLOT", "8")),
             NMAC=int(os.environ.get("WL_NMAC", "4")))
    build = Path("sim_build") / ("fused_" + "_".join(f"{k}{v}" for k, v in p.items()))
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
    p["SEED_FILE"] = f'"{mem.name}"'
    run(dut_sources=SOURCES, hdl_toplevel="fused_coproc",
        test_module="test_fused_coproc", parameters=p,
        build_dir=str(build), hf_sources=HF_ALL_SOURCES)
