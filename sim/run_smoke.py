"""M0 smoke-test runner: build the HardFloat FMA DUT and run the cocotb test.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_smoke.py

Run with the RTL venv (.venv-rtl, Python 3.13) that has cocotb; the main .venv is
Python 3.14 which cocotb does not support (see rtl/README.md).
"""

from cocotb_common import ROOT, run

if __name__ == "__main__":
    run(
        dut_sources=[ROOT / "rtl" / "smoke" / "smoke_fma.v"],
        hdl_toplevel="smoke_fma",
        test_module="test_smoke_fma",
    )
