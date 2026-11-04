"""T-C3: EXT_MEM equivalence (spec 2.4)."""
import shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

CORE = ROOT / "rtl" / "core"
SRC = ["fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
       "ladder_engine_inter.v", "fused_coproc_pipe.v"]

if __name__ == "__main__":
    for fmt, p in (("bf16", dict(EXP=8, SIG=8, TBITS=6, EPSV=0x3C24, SEEDSEL=0)),
                   ("fp32", dict(EXP=8, SIG=24, TBITS=12, EPSV=0x3C23D70A, SEEDSEL=1))):
        build = Path("sim_build_chip") / f"core_c3_{fmt}"
        build.mkdir(parents=True, exist_ok=True)
        for m in ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem"):
            shutil.copy(CORE / m, build / m); shutil.copy(CORE / m, Path.cwd() / m)
        run(dut_sources=[CORE / n for n in SRC] + [ROOT / "sim" / "tb_core_c3.v"],
            hdl_toplevel="tb_core_c3", test_module="test_core_c3", parameters=p,
            build_dir=str(build), hf_sources=HF_FMA_SOURCES)
