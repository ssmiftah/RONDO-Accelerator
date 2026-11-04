"""T-FULL: full geometry (WIDTH 64, PDIM 40, 8 lanes) with the Waveform coefficients, Verilator."""
import os
os.environ["SIM"] = "verilator"
from run_chip_regs import build_and_run

if __name__ == "__main__":
    build_and_run("full", "tb_chip_vs_core", "test_chip_full", dict(WIDTH=64, PDIM=40, N_LANES=8, HB_BIT=6))
