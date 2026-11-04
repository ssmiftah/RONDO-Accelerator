import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES, require_env
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v",
            "recip_nr_pipe.v", "ladder_engine_inter.v", "fused_coproc_pipe.v",
            "fused_coproc_bf16.v")]
if __name__ == "__main__":
    require_env('WL_NPZ')
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s8_t6.mem"
    p = dict(DEPTH=7, WIDTH=int(os.environ.get("WL_WIDTH", "64")),
             PDIM=int(os.environ.get("WL_PDIM", "40")),
             N_LANES=int(os.environ.get("WL_LANES", "8")),
             ACCSIG=int(os.environ.get("WL_ACCSIG", "8")),
             NSLOT=8, NPAR=8)
    build = Path("sim_build") / ("fusedbf_" + "_".join(f"{k}{v}" for k, v in p.items()))
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
    run(dut_sources=SOURCES, hdl_toplevel="fused_coproc_bf16",
        test_module="test_fused_bf16", parameters=p,
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
