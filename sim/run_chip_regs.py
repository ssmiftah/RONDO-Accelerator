"""T-REG: every register of rondo_dev (SMALL)."""
import shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

CHIP = ROOT / "rtl" / "chip"
CORE = ["fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
        "ladder_engine_inter.v", "fused_coproc_pipe.v", "kan_basis_inter.v", "kan_sum_bank.v", "kan_layer_pipe.v"]
SEEDS = ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem", "recip_seed_e8s24_t8.mem")


def chip_sources(top=False):
    return [CHIP / f for f in sorted(p.name for p in CHIP.glob("*.v")) if f != "genesys2_pi_top.v"
            and (top or f != "rondo_chip_top.v")] + sorted((CHIP / "sva").glob("*.v"))


def build_and_run(name, top, test_module, params=None, tb="tb_chip_vs_core.v", extra_src=(), with_top=False, defines=None):
    build = Path("sim_build_chip") / name
    build.mkdir(parents=True, exist_ok=True)
    for m in SEEDS:
        shutil.copy(ROOT / "rtl" / "core" / m, build / m); shutil.copy(ROOT / "rtl" / "core" / m, Path.cwd() / m)
    run(dut_sources=[ROOT / "rtl" / "core" / n for n in CORE] + chip_sources(with_top) + ([ROOT / "sim" / tb] if tb else []) + list(extra_src),
        hdl_toplevel=top, test_module=test_module, parameters=params or {}, build_dir=str(build),
        hf_sources=HF_FMA_SOURCES, defines=defines)


if __name__ == "__main__":
    build_and_run("regs", "tb_chip_vs_core", "test_chip_regs", dict(CNT_INIT=(1 << 32) - 50))
