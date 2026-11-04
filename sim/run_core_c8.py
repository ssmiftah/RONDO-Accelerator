"""T-C8: input tiling in the core (spec 18.2). Tiled == untiled bit for bit, both formats, p in {16, 20, 24}."""
import shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

CORE = ROOT / "rtl" / "core"
SRC = ["fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v", "ladder_engine_inter.v",
       "fused_coproc_pipe.v"]
CFGS = []
for fmt, base in (("bf16", dict(EXP=8, SIG=8, ACCSIG=8, TBITS=6, SEEDSEL=0, EPSV=0x3C24)),
                  ("fp32", dict(EXP=8, SIG=24, ACCSIG=24, TBITS=8, SEEDSEL=2, EPSV=0x3C23D70A))):
    for p, p2 in ((16, 16), (24, 24), (20, 24)):
        CFGS.append((f"{fmt}_p{p}", dict(base, P1=p, P2=p2)))

if __name__ == "__main__":
    for tag, p in CFGS:
        build = Path("sim_build_chip") / f"core_c8_{tag}"
        build.mkdir(parents=True, exist_ok=True)
        for m in ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem", "recip_seed_e8s24_t8.mem"):
            shutil.copy(CORE / m, build / m); shutil.copy(CORE / m, Path.cwd() / m)
        run(dut_sources=[CORE / n for n in SRC] + [ROOT / "sim" / "tb_core_c8.v"], hdl_toplevel="tb_core_c8",
            test_module="test_core_c8", parameters=p, build_dir=str(build), hf_sources=HF_FMA_SOURCES)
