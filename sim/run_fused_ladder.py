"""Runner for the fused datapath (affine + scan + reciprocal in one module).

One config per process: Verilator's teardown occasionally aborts after a passing
run, which would kill an in-process sweep. Drive the sweep from the shell.

    WL_DEPTH=7 WL_PDIM=40 SIM=verilator ../.venv-rtl/bin/python run_fused_ladder.py
"""
import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES

SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("mat2x2_mul.v", "fp_mul.v", "fp_fma.v", "ladder_scan_iter.v",
            "recip_wrap.v", "ladder_engine.v", "affine_unit.v", "fused_ladder.v")]

if __name__ == "__main__":
    depth = int(os.environ.get("WL_DEPTH", "7"))
    pdim = int(os.environ.get("WL_PDIM", "8"))
    nmac = int(os.environ.get("WL_NMAC", "1"))
    run(dut_sources=SOURCES, hdl_toplevel="fused_ladder",
        test_module="test_fused_ladder",
        parameters={"DEPTH": depth, "PDIM": pdim, "NMAC": nmac},
        build_dir=f"sim_build/fused_d{depth}_p{pdim}_m{nmac}", hf_sources=HF_ALL_SOURCES)
