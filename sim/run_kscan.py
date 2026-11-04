"""Runner for kscan (full continuant array producer). Sweeps depths.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_kscan.py
"""

import os
from cocotb_common import ROOT, run

SOURCES = [
    ROOT / "rtl" / "core" / "fp_fma.v",
    ROOT / "rtl" / "core" / "fp_mul.v",
    ROOT / "rtl" / "core" / "kscan.v",
]

if __name__ == "__main__":
    for depth in (1, 2, 3, 7):
        for gen in (0, 1):
            os.environ["COFR_GEN"] = str(gen)
            run(
                dut_sources=SOURCES,
                hdl_toplevel="kscan",
                test_module="test_kscan",
                parameters={"DEPTH": depth, "GEN": gen},
                build_dir=f"sim_build/kscan_d{depth}_g{gen}",
            )
