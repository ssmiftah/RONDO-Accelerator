"""T-CLK: divider, source mux, dead clk_alt recovery, clkout, SPI at R=8 of the divided clock."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from chip_tb import TopTB
import chip_common as cc

GEO = cc.Geo(16, 8, 2)


async def clkout_period(dut, k=2):
    await RisingEdge(dut.clkout)
    t0 = cocotb.utils.get_sim_time("ns")
    await RisingEdge(dut.clkout)
    return cocotb.utils.get_sim_time("ns") - t0


@cocotb.test()
async def divider_source_recovery(dut):
    t = TopTB(dut, GEO, ratio=8.0)
    await t.boot(alt_period=14)
    base = 10.0
    for code, n in ((1, 2), (2, 4), (3, 8), (0, 1)):
        await t.wr("CLK_CFG", code)
        # applied when the frame ends; the chip keeps answering, now on the divided clock
        t.set_core_period(base * n)
        await Timer(int(200 * base * n), unit="ns")
        assert (await t.rd("CLK_CFG") >> 16) & 3 == code, "DIV_APPLIED"
        await t.wr("CLKOUT_CFG", 2)
        p = await clkout_period(dut)
        assert abs(p - 4 * base * n) < 1.0, f"div {n}: clkout period {p} ns, expected {4 * base * n}"
        await t.wr("CLKOUT_CFG", 0)
        assert await t.rd("CHIP_ID") == 0x524F4E44
        rx = await t.bfm.xfer(bytes([0x0E, 0x12, 0x34, 0x56]))
        assert rx[1:] == bytes([0x0E, 0x12, 0x34]), "loopback at R=8 of the divided clock"
    # source switch to clk_alt (14 ns)
    await t.wr("CLK_CFG", 0x10)
    t.set_core_period(14.0)
    await Timer(8000, unit="ns")
    assert (await t.rd("CLK_CFG") >> 20) & 1 == 1
    await t.wr("CLKOUT_CFG", 2)
    p = await clkout_period(dut)
    assert abs(p - 4 * 14.0) < 1.0, f"clk_alt: clkout period {p}"
    await t.wr("CLKOUT_CFG", 0)
    assert await t.rd("CHIP_ID") == 0x524F4E44
    # back to clk, then kill clk_alt while selected: the chip stops; rst_n recovers it
    await t.wr("CLK_CFG", 0)
    t.set_core_period(10.0)
    await Timer(4000, unit="ns")
    assert await t.rd("CHIP_ID") == 0x524F4E44
    await t.wr("CLK_CFG", 0x10)
    t.set_core_period(14.0)
    await Timer(4000, unit="ns")
    assert await t.rd("CHIP_ID") == 0x524F4E44
    t.alt_task.cancel()
    dut.clk_alt.value = 0
    await Timer(500, unit="ns")
    await t.wr("CLK_CFG", 0)                    # frame may or may not complete: the clock dies at its end
    await Timer(5000, unit="ns")
    # hard reset forces SRC = 0
    dut.rst_n.value = 0
    await Timer(100, unit="ns")
    dut.rst_n.value = 1
    await Timer(500, unit="ns")
    t.set_core_period(10.0)
    assert await t.rd("CHIP_ID") == 0x524F4E44, "recovered by rst_n"
    assert (await t.rd("CLK_CFG")) & 0x1F == 0
    dut._log.info("T-CLK: DIV 1/2/4/8, SRC switch, clkout frequencies, dead clk_alt recovered by rst_n")
