"""T-TILE runner: rondo_dev SMALL with TILE_B=3 next to untiled PDIM=24 reference cores (tb_chip_tile.v)."""
from run_chip_regs import build_and_run

if __name__ == "__main__":
    build_and_run("tile", "tb_chip_tile", "test_chip_tile", dict(CNT_INIT=0), tb="tb_chip_tile.v", defines={"RONDO_FAULT_INJECT": "1"})   # fault hooks of the SRAM models for tile_mem_test_faults
