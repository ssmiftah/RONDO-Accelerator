"""T-REG: reset value, access type and side effects of every register (rondo_dev SMALL)."""
import random
import cocotb
from cocotb.triggers import FallingEdge
from chip_tb import ChipTB, R, A, ERR, STAT, CTRL
import chip_common as cc

GEO = cc.Geo(16, 8, 2)


def has(e, name):
    return name in e


@cocotb.test()
async def reset_values_and_access(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    g = t.g
    assert await t.rd("CHIP_ID") == 0x524F4E44
    assert await t.rd("VERSION") == R.VERSION_VALUE
    caps = await t.rd("CAPS")
    want = {"HAS_BF16", "HAS_FP32", "HAS_BIAS", "GUARD", "READBACK", "DBG", "TRACE", "KAT", "LANE_MASK",
            "SPI_CRC", "CLK_ALT"}
    assert R.bits(R.CAPS_BITS, caps) == want, R.bits(R.CAPS_BITS, caps) ^ want
    assert R.caps_layer(caps) == 0 and (caps >> 2) & 7 == 0b100, f"CAPS[4:2] = {(caps >> 2) & 7:#05b}"   # LAYER 0, HAS_BIAS
    assert await t.rd("GEOM0") == (GEO.pdim << 16) | GEO.width
    assert await t.rd("GEOM1") == (8 << 24) | (8 << 16) | (GEO.lanes << 8) | GEO.depth
    g2 = await t.rd("GEOM2")
    assert g2 & 0xFF == 4 and (g2 >> 8) & 0xFF == 6 and (g2 >> 16) & 0xFF == 3 and (g2 >> 24) & 0xFF == 1
    g3 = await t.rd("GEOM3")
    assert g3 & 0xFF == 8 and (g3 >> 8) & 0xFF == 5 and (g3 >> 16) & 15 == 6 and (g3 >> 20) & 15 == 8
    assert (g3 >> 24) & 15 == 1 and (g3 >> 28) & 15 == 2
    assert await t.rd("EPS_BF16") == 0x3C24 and await t.rd("EPS_FP32") == 0x3C23D70A
    # reset values
    for name, (addr, acc, rst) in R.REGS.items():
        if rst is None or name in ("CHIP_ID", "VERSION", "EPS_BF16", "EPS_FP32") or name.startswith("TOTAL") \
                or name in ("DBG_DATA",):
            continue
        if name in ("TRC_STATUS", "ST_STATUS", "MBIST_STATUS", "MBIST_FAIL_ADDR", "MBIST_FAIL_XOR",
                    "TILE_CFG", "TILE_STATUS", "TILE_SEQ_CRC", "TILE_SLICE", "KAT_SIG_BF16", "KAT_SIG_FP32"):
            continue
        v = await t.rd(name)
        if name == "ERR_STATUS" or name == "IRQ_STATUS":
            continue                      # may hold power-up events
        assert v == rst, f"{name}: reset value {v:#x} != {rst:#x}"
    assert await t.rd("LANE_EN") == (1 << GEO.lanes) - 1
    # tile / mbist registers read 0 in this build
    for n in ("MBIST_STATUS", "TILE_CFG", "TILE_STATUS"):
        assert await t.rd(n) == 0
    s = await t.rd("STATUS")
    assert (s >> STAT["WSTALE"]) & 1, "WSTALE set after reset"
    assert not (s >> STAT["ACTIVE"]) & 1 and (s >> 16) & 0xFF == (1 << GEO.lanes) - 1


@cocotb.test()
async def rw_ro_w1c_errors(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    await t.clear_errors()
    rng = random.Random(3)
    # RW registers read back what was written (masked to their implemented bits)
    for name, mask in (("SCRATCH", 0xFFFFFFFF), ("ERR_MASK", 0xFFFFFFFF), ("SR_COUNT", 0xFFFFFFFF),
                       ("WDOG_LIMIT", 0xFFFFFFFF), ("CLKOUT_CFG", 0xF), ("SPI_CFG", 1), ("IRQ_EN", 0x7F),
                       ("TRC_TRIG_CYC", 0xFFFFFFFF), ("TRC_CFG", 0xFFFFFFFF), ("LANE_EN", (1 << GEO.lanes) - 1)):
        v = rng.getrandbits(32)
        await t.wr(name, v)
        got = await t.rd(name)
        assert got == v & mask, f"{name}: {got:#x} vs {v & mask:#x}"
    await t.wr("ERR_MASK", 0xFFFFFDFF); await t.wr("IRQ_EN", 0x7F); await t.wr("SPI_CFG", 0)
    await t.wr("CLKOUT_CFG", 0); await t.wr("LANE_EN", 3); await t.wr("TRC_CFG", 0)
    assert not await t.errors()
    await t.wr("DBG_SEL", 0x03000000 | (3 << 16) | (5 << 8) | (2 << 4) | 1)
    assert await t.rd("DBG_SEL") == 0x03000000 | (3 << 16) | (5 << 8) | (2 << 4) | 1
    await t.wr("DBG_SEL", 0)
    # RO registers: write ignored, RO error
    for name in ("CHIP_ID", "VERSION", "CAPS", "GEOM0", "STATUS", "LAST_CYCLES", "INFER_CNT_LO", "CHECKSUM",
                 "LOAD_CRC", "GUARD_HITS", "DBG_DATA", "TRC_STATUS", "ST_STATUS"):
        before = await t.rd(name)
        await t.clear_errors()
        e = await t.wr(name, 0xDEADBEEF)
        assert e == 1, f"{name}: rsp_err not set"
        assert "RO" in await t.errors(), name
        if name in ("CHIP_ID", "VERSION", "CAPS", "GEOM0"):
            assert await t.rd(name) == before
    # unmapped register addresses: 0 and ADDR; memory holes
    await t.clear_errors()
    assert await t.rd(0xF0) == 0
    assert "ADDR" in await t.errors()
    await t.clear_errors()
    await t.wr(0x7F, 5)
    assert "ADDR" in await t.errors()
    for addr in (R.XBUF_BASE + (4 << t.g.xw), R.ZBUF_BASE + GEO.width, 0x040000, 0x900000 - 1,
                 R.WEIGHT_BASE + (3 << 12), R.WEIGHT_BASE + 56 * 8, R.BIAS_BASE + 7 * 8, R.BIAS_BASE + (3 << 6)):
        await t.clear_errors()
        r = await t.rb.read(addr)
        assert r == 0 and "ADDR" in await t.errors(), hex(addr)
        await t.clear_errors()
        await t.rb.write(addr, 1)
        assert "ADDR" in await t.errors(), hex(addr)
    # RO regions
    await t.clear_errors()
    await t.rb.write(R.ZBUF_BASE, 1)
    assert "RO" in await t.errors()
    await t.clear_errors()
    await t.rb.write(R.TRACE_BASE, 1)
    assert "RO" in await t.errors()
    # RANGE
    await t.clear_errors()
    await t.wr("FORMAT", 2); assert "RANGE" in await t.errors(); assert await t.rd("FORMAT") == 0
    await t.clear_errors(); await t.wr("XSEL", 4); assert "RANGE" in await t.errors()
    await t.clear_errors(); await t.wr("SR_N", 0); assert "RANGE" in await t.errors()
    await t.clear_errors(); await t.wr("SR_N", 5); assert "RANGE" in await t.errors()
    assert await t.rd("SR_N") == 1 and await t.rd("XSEL") == 0
    # W1C: ERR_STATUS clears exactly the written bits
    await t.clear_errors()
    await t.wr(0xF0, 0)            # ADDR
    await t.wr("FORMAT", 2)        # RANGE
    assert await t.errors() == {"ADDR", "RANGE"}
    await t.wr("ERR_STATUS", 1 << ERR["ADDR"])
    assert await t.errors() == {"RANGE"}
    # ERR_MASK / ERR_ANY / IRQ ERR mirror
    await t.wr("ERR_MASK", 0xFFFFFFFF ^ (1 << ERR["RANGE"]))
    st = await t.rd("STATUS")
    assert not (st >> 31) & 1, "RANGE masked: ERR_ANY low"
    await t.wr("ERR_MASK", 0xFFFFFFFF)
    st = await t.rd("STATUS")
    assert (st >> 31) & 1
    assert (await t.rd("IRQ_STATUS")) >> 2 & 1, "IRQ_STATUS[2] mirrors ERR_ANY"
    await t.clear_errors()
    await t.wr("ERR_MASK", 0xFFFFFDFF)
    # CTRL reads 0
    assert await t.rd("CTRL") == 0


@cocotb.test()
async def counters_status_irq(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = random.Random(5)
    f = cc.FORMATS["bf16"]["f"]
    Wl, Bl = cc.rand_weights(rng, GEO, f)
    await t.load_weights("bf16", Wl, Bl)
    x = cc.rand_x(rng, GEO, f)
    await t.write_x(0, x)
    s = await t.rd("STATUS")
    assert (s >> STAT["WSTALE"]) & 1 == 0, "WSTALE cleared by the first accepted weight write"
    await t.clear_errors()
    await t.wr("IRQ_STATUS", 0xFFFFFFFF)
    assert int(dut.irq.value) == 0
    # shadow coherence of 64-bit counters across the 2^32 wrap (CNT_INIT = 2^32 - 50)
    lo = await t.rd("TOTAL_CYC_LO"); hi = await t.rd("TOTAL_CYC_HI")
    lo2 = await t.rd("TOTAL_CYC_LO"); hi2 = await t.rd("TOTAL_CYC_HI")
    v1, v2 = (hi << 32) | lo, (hi2 << 32) | lo2
    assert 0 < v2 - v1 < 200, (hex(v1), hex(v2))
    assert hi2 >= 1 or lo2 > 1000, "TOTAL_CYC crossed 2^32"
    # inference: DONE irq, counters, LAST_CYCLES vs bare core
    await t.wr("XSEL", 0)
    await t.ctrl("START")
    await t.wait_idle()
    assert int(dut.irq.value) == 1
    irqs = await t.rd("IRQ_STATUS")
    assert irqs & 1
    await t.wr("IRQ_STATUS", 1)
    assert await t.rd("IRQ_STATUS") & 1 == 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    assert int(dut.irq.value) == 0
    assert await t.rd("INFER_CNT_LO") == 1
    assert await t.rd("LAST_CYCLES") > 100
    assert await t.rd("BUSY_CYC_LO") >= await t.rd("LAST_CYCLES") - 2
    z = await t.read_z()
    assert [v & 0xFFFF for v in z] == t.model_z("bf16", Wl, Bl, x)
    # START while ACTIVE: START_BUSY
    await t.clear_errors()
    await t.ctrl("START")
    await t.ctrl("START")
    assert "START_BUSY" in await t.errors()
    await t.wait_idle()
    # writes while ACTIVE are blocked with BUSY_WR
    await t.clear_errors()
    await t.ctrl("START")
    e = await t.rb.write(R.XBUF_BASE + 1, 0x1234)
    assert e == 1 and "BUSY_WR" in await t.errors()
    await t.wr("FORMAT", 1)
    assert await t.rd("FORMAT") == 0, "FORMAT write blocked while ACTIVE"
    await t.wait_idle()
    # CTRL: clears, counter clear
    await t.ctrl("CNT_CLR")
    assert await t.rd("INFER_CNT_LO") == 0 and await t.rd("LAST_CYCLES") == 0
    # CTRL priority: SOFT_RST wins and ignores the other bits
    await t.wr("SCRATCH", 0x1234)
    await t.ctrl("SOFT_RST", "START")
    await t.wait_idle()
    assert await t.rd("INFER_CNT_LO") == 0, "START ignored in the same write as SOFT_RST"
    assert await t.rd("SCRATCH") == 0x1234, "SCRATCH kept across soft reset"
    # heartbeat toggles (HB_BIT = 6)
    seen = set()
    for _ in range(40):
        seen.add((await t.rd("STATUS") >> 6) & 1)
    assert seen == {0, 1}
    # STATUS8 mirrors
    s8 = int(dut.status8.value)
    assert s8 & 3 == 2 and not (s8 >> 4) & 1
    # CLK_CFG pending until the frame end, readback; blocked while active
    await t.wr("CLK_CFG", 0x12)
    assert (await t.rd("CLK_CFG")) & 0x1F == 0x12
    assert int(dut.clk_div.value) == 0
    dut.spi_frame_end.value = 1
    await FallingEdge(dut.clk)
    dut.spi_frame_end.value = 0
    await FallingEdge(dut.clk); await FallingEdge(dut.clk)
    assert int(dut.clk_div.value) == 2 and int(dut.clk_src.value) == 1
    await t.wr("CLK_CFG", 0)
    dut.spi_frame_end.value = 1
    await FallingEdge(dut.clk); dut.spi_frame_end.value = 0
    # access latency bound
    assert t.rb.max_total <= 24, f"external access took {t.rb.max_total} cycles"
    dut._log.info(f"max rbus response latency {t.rb.max_latency}, max request->response {t.rb.max_total}")


@cocotb.test()
async def soft_reset_clears_shadows(dut):
    """CHIP_FIX_PLAN task 9.2 (spec 9.6): a soft reset clears the 64-bit read shadows (CNT_INIT = 2^32 - 50, so TOTAL_CYC HI becomes 1)."""
    t = ChipTB(dut, GEO)
    await t.boot()
    for _ in range(120):                                  # TOTAL_CYC crosses 2^32 (50 cycles after reset release)
        await FallingEdge(dut.clk)
    lo = await t.rd("TOTAL_CYC_LO")
    shadow = await t.rd("TOTAL_CYC_HI")                   # shadow of the LO read: HI != 0
    assert shadow >= 1, "precondition: TOTAL_CYC HI != 0"
    lo = await t.rd("TOTAL_CYC_LO")                        # shadow loaded again
    await t.ctrl("SOFT_RST")
    await t.wait_idle()
    hi_alone = await t.rd("TOTAL_CYC_HI")                  # no LO read since the reset
    assert hi_alone == 0, f"stale shadow after SOFT_RST: TOTAL_CYC_HI = {hi_alone}"
    dut._log.info("T-REG: SOFT_RST clears the 64-bit read shadows")
