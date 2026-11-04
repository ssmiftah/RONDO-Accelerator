"""T-CFG runner (Verilator): rondo_dev WIDTH 16, PDIM 40, 2 lanes, TILE_B 8 vs an untiled PDIM-800 core."""
import os
os.environ["SIM"] = "verilator"
from run_chip_regs import build_and_run

if __name__ == "__main__":
    build_and_run("cofrgenet", "tb_chip_tile", "test_chip_cofrgenet",
                  dict(WIDTH=16, PDIM=40, N_LANES=2, PW=800, TILE_B=8, KAT=0), tb="tb_chip_tile.v")
