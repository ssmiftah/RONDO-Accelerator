"""B7: disabled lane + start in the done cycle must write qNaN (fused_coproc_pipe L_FIN arm). Reuses the existing bench sim/tb_core_c6.v and
the existing cocotb test sim/test_core_c6.py::c6_start_in_done_disabled unchanged; only the RTL root differs (fixed tree or build/verif/rtl_prefix).
usage: RTL_ROOT=<root> SIM=icarus|verilator .venv-rtl/bin/python -I verif/cocotb/run_b7.py   (cwd: build/verif/cocotb)"""
import os, sys, shutil
from pathlib import Path
MAIN = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(MAIN / "sim"))
from cocotb_common import run, HF_FMA_SOURCES
RR = Path(os.environ.get("RTL_ROOT", MAIN)); CORE = RR / "rtl" / "core"
SRC = ["fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v", "ladder_engine_inter.v", "fused_coproc_pipe.v"]
os.environ["COCOTB_TEST_FILTER"] = "c6_start_in_done_disabled"
for fmt, p in (("bf16", dict(EXP=8, SIG=8, TBITS=6, EPSV=0x3C24, SEEDSEL=0)), ("fp32", dict(EXP=8, SIG=24, TBITS=12, EPSV=0x3C23D70A, SEEDSEL=1))):
    build = Path("sim_build_b7") / f"{RR.name}_{fmt}"; build.mkdir(parents=True, exist_ok=True)
    for m in ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem"):
        shutil.copy(MAIN / "rtl" / "core" / m, build / m); shutil.copy(MAIN / "rtl" / "core" / m, Path.cwd() / m)
    run(dut_sources=[CORE / n for n in SRC] + [MAIN / "sim" / "tb_core_c6.v"], hdl_toplevel="tb_core_c6", test_module="test_core_c6", parameters=p,
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
