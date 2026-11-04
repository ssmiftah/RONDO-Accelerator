"""T-SPI: rondo_spi_slave against the SPI master BFM and an rbus responder."""
from pathlib import Path
from cocotb_common import ROOT, run

CHIP = ROOT / "rtl" / "chip"
RTL = ["rondo_sync.v", "rondo_spi_phy.v", "rondo_spi_ctrl.v", "rondo_spi_slave.v", "sva/rondo_sva_spi.v"]

if __name__ == "__main__":
    build = Path("sim_build_chip") / "spi"
    build.mkdir(parents=True, exist_ok=True)
    run(dut_sources=[CHIP / f for f in RTL] + [ROOT / "sim" / "tb_chip_spi.v"],
        hdl_toplevel="tb_chip_spi", test_module="test_chip_spi", build_dir=str(build),
        hf_sources=[])
