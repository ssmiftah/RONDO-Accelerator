"""Runner for the recip_wrap unit test (uses the HardFloat divider).

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_recip.py
"""

from cocotb_common import ROOT, run, HF_DIV_SOURCES

if __name__ == "__main__":
    run(
        dut_sources=[ROOT / "rtl" / "core" / "recip_wrap.v"],
        hdl_toplevel="recip_wrap",
        test_module="test_recip_wrap",
        hf_sources=HF_DIV_SOURCES,
    )
