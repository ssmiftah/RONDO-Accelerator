from run_chip_regs import build_and_run
if __name__ == "__main__":
    build_and_run("top", "rondo_chip_top", "test_chip_top", dict(HB_BIT=7, WIDTH=16, PDIM=8, N_LANES=2), tb=None, with_top=True)
