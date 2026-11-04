"""T-C7: NR_ITERS (spec 2.8): standalone reciprocal accuracy; full fp32 layer with the
Waveform coefficients (Verilator, full geometry) with the C7 option (TBITS=8, NR_ITERS=2)."""
import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES, HF_ALL_SOURCES

CORE = ROOT / "rtl" / "core"
SRC = ["fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
       "ladder_engine_inter.v", "fused_coproc_pipe.v"]
SEEDS = ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem", "recip_seed_e8s24_t8.mem")

if __name__ == "__main__":
    for tag, p in (("fp32_t8_n2", dict(EXP=8, SIG=24, TBITS=8, NR_ITERS=2, SEEDSEL=2, EPSV=0x3C23D70A)),
                   ("fp32_t12_n1", dict(EXP=8, SIG=24, TBITS=12, NR_ITERS=1, SEEDSEL=1, EPSV=0x3C23D70A)),
                   ("bf16_t6_n1", dict(EXP=8, SIG=8, TBITS=6, NR_ITERS=1, SEEDSEL=0, EPSV=0x3C24))):
        build = Path("sim_build_chip") / f"core_c7_recip_{tag}"
        build.mkdir(parents=True, exist_ok=True)
        for m in SEEDS:
            shutil.copy(CORE / m, build / m); shutil.copy(CORE / m, Path.cwd() / m)
        run(dut_sources=[CORE / n for n in SRC] + [ROOT / "sim" / "tb_recip.v"],
            hdl_toplevel="tb_recip", test_module="test_core_c7", parameters=p,
            build_dir=str(build), hf_sources=HF_FMA_SOURCES)
    # full fp32 layer with the C7 option on the Waveform coefficients (Verilator)
    if os.environ.get("C7_SKIP_LAYER") != "1":
        os.environ["SIM"] = "verilator"
        os.environ["WL_NPZ"] = str(ROOT / "workloads/results/waveform_coeffs.npz")
        os.environ["WL_MAXSAMP"] = os.environ.get("C7_NSAMP", "6")
        os.environ["WL_OUT"] = str(ROOT / "build" / "chip_regress")
        build = Path("sim_build_chip") / "core_c7_layer_full"
        build.mkdir(parents=True, exist_ok=True)
        for m in SEEDS:
            shutil.copy(CORE / m, build / m); shutil.copy(CORE / m, Path.cwd() / m)
        run(dut_sources=[CORE / n for n in SRC] + [ROOT / "sim" / "tb_core_c7.v"],
            hdl_toplevel="tb_core_c7", test_module="test_fused_bf16",
            parameters=dict(EXP=8, SIG=24, TBITS=8, NR_ITERS=2, SEEDSEL=2),
            build_dir=str(build), hf_sources=HF_FMA_SOURCES)
