"""Runner for train_ladder (M3 forward+backward engine). Sweeps depths.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_train_ladder.py
"""

from cocotb_common import ROOT, run, HF_ALL_SOURCES

SOURCES = [
    ROOT / "rtl" / "core" / "fp_fma.v",
    ROOT / "rtl" / "core" / "fp_mul.v",
    ROOT / "rtl" / "core" / "kscan.v",
    ROOT / "rtl" / "core" / "recip_wrap.v",
    ROOT / "rtl" / "core" / "grad_a_unit.v",
    ROOT / "rtl" / "core" / "train_ladder.v",
]

if __name__ == "__main__":
    for depth in (2, 3, 7):
        run(
            dut_sources=SOURCES,
            hdl_toplevel="train_ladder",
            test_module="test_train_ladder",
            parameters={"DEPTH": depth},
            build_dir=f"sim_build/train_d{depth}",
            hf_sources=HF_ALL_SOURCES,
        )
