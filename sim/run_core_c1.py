"""T-C1: start-in-done-cycle fix (spec 2.2). The unmodified core (rtl/core/*.pre_chip,
renamed) is expected to hang on the same stimulus."""
import re, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

CORE = ROOT / "rtl" / "core"
SRC = ["fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
       "ladder_engine_inter.v", "fused_coproc_pipe.v", "kan_basis_inter.v",
       "kan_sum_bank.v", "kan_layer_pipe.v"]

if __name__ == "__main__":
    for fmt, p in (("bf16", dict(EXP=8, SIG=8, TBITS=6, EPSV=0x3C24)),
                   ("fp32", dict(EXP=8, SIG=24, TBITS=12, EPSV=0x3C23D70A))):
        build = Path("sim_build_chip") / f"core_c1_{fmt}"
        build.mkdir(parents=True, exist_ok=True)
        old = (CORE / "fused_coproc_pipe.v.pre_chip").read_text()
        old = old.replace("module fused_coproc_pipe", "module fused_coproc_pipe_old")
        (build / "fused_coproc_pipe_old.v").write_text(old)
        for m in ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem"):
            shutil.copy(CORE / m, build / m); shutil.copy(CORE / m, Path.cwd() / m)
        srcs = [CORE / n for n in SRC] + [build / "fused_coproc_pipe_old.v", ROOT / "sim" / "tb_core_c1.v"]
        run(dut_sources=srcs, hdl_toplevel="tb_core_c1", test_module="test_core_c1",
            parameters=p, build_dir=str(build), hf_sources=HF_FMA_SOURCES)
