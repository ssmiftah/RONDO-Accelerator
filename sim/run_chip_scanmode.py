from run_chip_regs import build_and_run
if __name__ == "__main__":
    build_and_run("scanmode", "rondo_chip_top", "test_chip_scanmode",
                  dict(HB_BIT=7, WIDTH=16, PDIM=8, N_LANES=2, SCAN=1, PG=1), tb=None, with_top=True)
