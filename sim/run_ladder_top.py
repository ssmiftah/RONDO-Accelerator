"""Runner for ladder_top (M1 full single-ladder forward). Sweeps a few depths.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_ladder_top.py
"""

from cocotb_common import ROOT, run, HF_ALL_SOURCES

SOURCES = [
    ROOT / "rtl" / "core" / "mat2x2_mul.v",
    ROOT / "rtl" / "core" / "ladder_scan.v",
    ROOT / "rtl" / "core" / "recip_wrap.v",
    ROOT / "rtl" / "core" / "ladder_top.v",
]

if __name__ == "__main__":
    for depth in (1, 3, 7):
        run(
            dut_sources=SOURCES,
            hdl_toplevel="ladder_top",
            test_module="test_ladder_top",
            parameters={"DEPTH": depth},
            build_dir=f"sim_build/ladtop_d{depth}",
            hf_sources=HF_ALL_SOURCES,
        )
