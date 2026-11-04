"""Runner for cofr_coproc (M2). Sweeps (WIDTH, N_LANES) configs at fixed DEPTH.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_cofr_coproc.py

Covers full-parallel, partial parallelism, single-lane, and a non-divisible
WIDTH/N_LANES (partial last wave).
"""

import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES

SOURCES = [
    ROOT / "rtl" / "core" / "mat2x2_mul.v",
    ROOT / "rtl" / "core" / "fp_mul.v",
    ROOT / "rtl" / "core" / "ladder_scan_iter.v",
    ROOT / "rtl" / "core" / "recip_wrap.v",
    ROOT / "rtl" / "core" / "ladder_engine.v",
    ROOT / "rtl" / "core" / "cofr_coproc.v",
]

CONFIGS = [
    # (DEPTH, WIDTH, N_LANES, GEN)
    (3, 4, 4, 0),   # full parallel, one wave, unit numerators
    (3, 4, 2, 0),   # two waves
    (3, 4, 1, 0),   # single lane, four waves
    (3, 5, 2, 0),   # partial last wave (5 not divisible by 2)
    (7, 3, 3, 0),   # deeper, full parallel
    (3, 4, 2, 1),   # generalized numerators, multi-wave
    (7, 3, 3, 1),   # generalized, deeper, full parallel
]

if __name__ == "__main__":
    for depth, width, lanes, gen in CONFIGS:
        os.environ["COFR_GEN"] = str(gen)
        run(
            dut_sources=SOURCES,
            hdl_toplevel="cofr_coproc",
            test_module="test_cofr_coproc",
            parameters={"DEPTH": depth, "WIDTH": width, "N_LANES": lanes, "GEN": gen},
            build_dir=f"sim_build/coproc_d{depth}_w{width}_l{lanes}_g{gen}",
            hf_sources=HF_ALL_SOURCES,
        )
