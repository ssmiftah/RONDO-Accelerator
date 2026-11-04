"""T-EQ: the as-built core (rtl/core/*.pre_chip, renamed *_old at run time) against the current core, default
parameters, cycle by cycle (busy/done every cycle, z at every done). Spec: CHIP_FIX_PLAN task 0.3."""
import os
import re
import shutil
from pathlib import Path
from cocotb_common import ROOT, run

CORE = ROOT / "rtl" / "core"
MODS = ("fused_coproc_pipe", "affine_bank_pipe", "ladder_engine_inter", "recip_nr_pipe")
# unchanged modules shared by both
SHARED = ["fp_fma_pipe.v", "ladder_scan_inter.v"]
CONFIGS = {   # name: (parameters, expected inferences)
    "bf16":    (dict(SIG=8, ACCSIG=8, TBITS=6, WIDTH=16, PDIM=8, SEED=1, NINF=60), 60),
    "fp32":    (dict(SIG=24, ACCSIG=24, TBITS=12, WIDTH=16, PDIM=8, SEED=2, NINF=60), 60),
    "bf16_nb2": (dict(SIG=8, ACCSIG=8, TBITS=6, WIDTH=32, PDIM=5, SEED=7, NINF=30), 30),
}


def make_old(build: Path):
    """Write <mod>_old.v for every module of MODS: rename definitions and instantiations."""
    out = []
    for m in MODS:
        txt = (CORE / f"{m}.v.pre_chip").read_text()
        for n in MODS:
            txt = re.sub(rf"\bmodule\s+{n}\b", f"module {n}_old", txt)
            txt = re.sub(rf"\b{n}(\s*#?\s*\()", rf"{n}_old\1", txt)
        p = build / f"{m}_old.v"
        p.write_text(txt)
        out.append(p)
    return out


if __name__ == "__main__":
    for name, (params, n) in CONFIGS.items():
        build = Path("sim_build_chip") / "core_eq" / name
        build.mkdir(parents=True, exist_ok=True)
        for m in ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem"):
            shutil.copy(CORE / m, build / m); shutil.copy(CORE / m, Path.cwd() / m)
        srcs = [CORE / f"{m}.v" for m in MODS] + [CORE / s for s in SHARED] + make_old(build) + [ROOT / "sim" / "tb_core_eq.v"]
        os.environ["EQ_EXPECT"] = str(n)
        run(dut_sources=srcs, hdl_toplevel="tb_core_eq", test_module="test_core_eq", parameters=params,
            build_dir=str(build),
            extra_build_args=["--timing"] if os.environ.get("SIM") == "verilator" else None)  # the bench has its own delays
