"""Runner for ladder_scan_iter (iterative/folded scan). Sweeps depths.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_ladder_scan_iter.py
"""

from cocotb_common import ROOT, run

SOURCES = [
    ROOT / "rtl" / "core" / "mat2x2_mul.v",
    ROOT / "rtl" / "core" / "ladder_scan_iter.v",
]

if __name__ == "__main__":
    for depth in (1, 2, 3, 7):
        run(
            dut_sources=SOURCES,
            hdl_toplevel="ladder_scan_iter",
            test_module="test_ladder_scan_iter",
            parameters={"DEPTH": depth},
            build_dir=f"sim_build/scaniter_d{depth}",
        )
