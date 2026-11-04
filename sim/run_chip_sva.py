from pathlib import Path
from cocotb_common import ROOT, run
CHIP = ROOT / "rtl" / "chip" / "sva"
if __name__ == "__main__":
    build = Path("sim_build_chip") / "sva"
    build.mkdir(parents=True, exist_ok=True)
    run(dut_sources=sorted(CHIP.glob("*.v")) + [ROOT / "sim" / "tb_chip_sva.v"], hdl_toplevel="tb_chip_sva",
        test_module="test_chip_sva", build_dir=str(build), hf_sources=[])
