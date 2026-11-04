"""Runner for ladder_engine (iterative single-ladder lane). Sweeps depths.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_ladder_engine.py
"""

import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES

SOURCES = [
    ROOT / "rtl" / "core" / "mat2x2_mul.v",
    ROOT / "rtl" / "core" / "fp_mul.v",
    ROOT / "rtl" / "core" / "ladder_scan_iter.v",
    ROOT / "rtl" / "core" / "recip_wrap.v",
    ROOT / "rtl" / "core" / "ladder_engine.v",
]

if __name__ == "__main__":
    for depth in (1, 3, 7):
        for gen in (0, 1):
            os.environ["COFR_GEN"] = str(gen)   # inherited by the sim subprocess
            run(
                dut_sources=SOURCES,
                hdl_toplevel="ladder_engine",
                test_module="test_ladder_engine",
                parameters={"DEPTH": depth, "GEN": gen},
                build_dir=f"sim_build/engine_d{depth}_g{gen}",
                hf_sources=HF_ALL_SOURCES,
            )
