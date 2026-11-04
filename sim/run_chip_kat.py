from run_chip_regs import build_and_run
if __name__ == "__main__":
    build_and_run("kat", "tb_chip_vs_core", "test_chip_kat", defines={"RONDO_FAULT_INJECT": "1"})
