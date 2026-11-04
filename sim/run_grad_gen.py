"""Runner for grad_gen_unit (I-11 generalized backward). Sweeps depths.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_grad_gen.py
"""

from cocotb_common import ROOT, run

SOURCES = [
    ROOT / "rtl" / "core" / "fp_mul.v",
    ROOT / "rtl" / "core" / "grad_gen_unit.v",
]

if __name__ == "__main__":
    for depth in (2, 3, 7):
        run(
            dut_sources=SOURCES,
            hdl_toplevel="grad_gen_unit",
            test_module="test_grad_gen_unit",
            parameters={"DEPTH": depth},
            build_dir=f"sim_build/gradgen_d{depth}",
        )
