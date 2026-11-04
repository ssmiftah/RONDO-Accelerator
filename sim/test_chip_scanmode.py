"""T-SCAN: SCAN=1 pin sharing and bypasses (functional, pre-insertion) and the PG=1 power-gating hooks."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, FallingEdge
from chip_tb import TopTB, R, STAT
import chip_common as cc

GEO = cc.Geo(16, 8, 2)


async def count_edges(sig, ns):
    n = 0
    async def c():
        nonlocal n
        while True:
            await RisingEdge(sig); n += 1
    t = cocotb.start_soon(c()); await Timer(ns, unit="ns"); t.cancel()
    return n


@cocotb.test()
async def scan_mode_and_pg(dut):
    t = TopTB(dut, GEO, ratio=8.0)
    await t.boot(alt_period=14)
    # normal mode: configure DIV = 3 (/8) and PG_INACTIVE
    await t.wr("CLK_CFG", 3)
    t.set_core_period(80.0)
    await Timer(5000, unit="ns")
    assert int(dut.u_div.div_applied.value) == 3
    n_core = await count_edges(dut.clk_core, 4000)
    assert abs(n_core - 4000 // 80) <= 1
    # ---- test mode: divider and source mux bypassed, ICGs transparent, reset direct, MISO = scan_out ----
    dut.test_mode_pin.value = 1
    await Timer(100, unit="ns")
    n_core = await count_edges(dut.clk_core, 1000)
    assert abs(n_core - 100) <= 1, f"test_mode: clk_core must follow clk, saw {n_core} edges"
    assert int(dut.spi_miso_oe.value) == 1, "oe forced on in test mode (scan_out)"
    # scan_in / scan_en pins: spi_mosi & bist_en -> spi_miso (stand-in chain tail)
    dut.spi_mosi.value = 1; dut.bist_en.value = 1
    await Timer(50, unit="ns")
    assert int(dut.spi_miso.value) == 1
    dut.bist_en.value = 0
    await Timer(50, unit="ns")
    assert int(dut.spi_miso.value) == 0
    # all layer clock gates transparent: both layer clocks toggle although only one is enabled
    L = dut.u_dev.u_ly.g_cofr
    nb = await count_edges(L.g_b.u_icg.gclk, 1000)
    nf = await count_edges(L.g_f.u_icg.gclk, 1000)
    assert nb >= 90 and nf >= 90, (nb, nf)
    # reset is the pin directly: sys_rst_n follows rst_n with no synchronizer delay
    dut.rst_n.value = 0
    await Timer(1, unit="ns")
    assert int(dut.sys_rst_n.value) == 0 if hasattr(dut, "sys_rst_n") else True
    dut.rst_n.value = 1
    await Timer(1, unit="ns")
    assert int(dut.sys_rst_n.value) == 1, "test_mode: sys_rst_n = rst_n (no synchronizer)"
    dut.test_mode_pin.value = 0
    await Timer(500, unit="ns")


@cocotb.test()
async def power_gating_hooks(dut):
    t = TopTB(dut, GEO, ratio=8.0)
    await t.boot()
    assert int(dut.pg_req.value) == 0
    await t.wr("PWR_CTRL", 4)                       # PG_INACTIVE
    await Timer(2000, unit="ns")
    assert int(dut.pg_req.value) == 2, "bf16 active: the fp32 layer's supply is requested off"
    # isolation: the powered-down layer's outputs read zero
    ly = dut.u_dev.u_ly.g_cofr
    assert int(dut.u_dev.u_ly.pg_iso.value) == 2
    # format switch: fp32 supply returns first, reset is held >= 16 cycles after, then bf16 is requested off
    ev = {}
    async def mon():
        cyc = 0
        while True:
            await FallingEdge(dut.clk)
            cyc += 1
            if "fell" not in ev and (int(dut.pg_req.value) & 2) == 0:
                ev["fell"] = cyc
            if "fell" in ev and "rel" not in ev and (int(dut.u_dev.core_rst_n.value) >> 1) & 1:
                ev["rel"] = cyc
    mt = cocotb.start_soon(mon())
    await t.wr("FORMAT", 1)
    await Timer(3000, unit="ns")
    mt.cancel()
    assert "fell" in ev and "rel" in ev, ev
    assert ev["rel"] - ev["fell"] >= 16, f"reset held only {ev['rel'] - ev['fell']} cycles after the supply returned"
    await t.wait_idle()
    await Timer(2000, unit="ns")
    assert int(dut.pg_req.value) == 1, "fp32 active: bf16 layer powered down"
    await t.wr("PWR_CTRL", 0)
    await Timer(500, unit="ns")
    assert int(dut.pg_req.value) == 0
