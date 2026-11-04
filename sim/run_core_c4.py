"""T-C4 / T-C5: debug taps (spec 2.5) and stage-isolation injection (spec 2.6)."""
import os, shutil, sys
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

CORE = ROOT / "rtl" / "core"
SRC = ["fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
       "ladder_engine_inter.v", "fused_coproc_pipe.v"]
CFGS = (("bf16", dict(EXP=8, SIG=8, ACCSIG=8, TBITS=6, EPSV=0x3C24, SEEDSEL=0)),
        ("bf16acc24", dict(EXP=8, SIG=8, ACCSIG=24, TBITS=6, EPSV=0x3C24, SEEDSEL=0)),
        ("fp32", dict(EXP=8, SIG=24, ACCSIG=24, TBITS=12, EPSV=0x3C23D70A, SEEDSEL=1)))

if __name__ == "__main__":
    mod = os.environ.get("CORE_DBG_MODULE", Path(sys.argv[0]).stem.replace("run_", "test_"))
    for tag, p in CFGS:
        build = Path("sim_build_chip") / f"{mod}_{tag}"
        build.mkdir(parents=True, exist_ok=True)
        for m in ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem", "recip_seed_e8s24_t8.mem"):
            shutil.copy(CORE / m, build / m); shutil.copy(CORE / m, Path.cwd() / m)
        run(dut_sources=[CORE / n for n in SRC] + [ROOT / "sim" / "tb_core.v"],
            hdl_toplevel="tb_core", test_module=mod, parameters=dict(p, DBG=1),
            build_dir=str(build), hf_sources=HF_FMA_SOURCES)
