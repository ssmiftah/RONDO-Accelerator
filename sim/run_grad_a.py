"""Runner for grad_a_unit (M3 backward gradient core). Sweeps depths.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_grad_a.py
"""

from cocotb_common import ROOT, run

SOURCES = [
    ROOT / "rtl" / "core" / "fp_mul.v",
    ROOT / "rtl" / "core" / "grad_a_unit.v",
]

if __name__ == "__main__":
    for depth in (2, 3, 7):
        run(
            dut_sources=SOURCES,
            hdl_toplevel="grad_a_unit",
            test_module="test_grad_a_unit",
            parameters={"DEPTH": depth},
            build_dir=f"sim_build/grada_d{depth}",
        )
