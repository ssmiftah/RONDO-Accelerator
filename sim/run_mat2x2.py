"""Runner for the mat2x2_mul unit test.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_mat2x2.py
"""

from cocotb_common import ROOT, run

if __name__ == "__main__":
    run(
        dut_sources=[ROOT / "rtl" / "core" / "mat2x2_mul.v"],
        hdl_toplevel="mat2x2_mul",
        test_module="test_mat2x2_mul",
    )
