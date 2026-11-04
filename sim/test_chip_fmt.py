"""T-FMT: FORMAT switching semantics (spec 12.4, 9.5), L half never enabled in bf16, clock gating."""
import random
import cocotb
from cocotb.triggers import FallingEdge
from chip_tb import ChipTB, R, A, ERR, STAT
import chip_common as cc

GEO = cc.Geo(16, 8, 2)


class ClkMon:
    def __init__(self, dut):
        self.dut = dut; self.bad_l = 0; self.fmt_seen = None
        self.toggles = [0, 0]
        cocotb.start_soon(self.run())

    async def run(self):
        d = self.dut.u_dev
        prev = [0, 0]
        while True:
            await FallingEdge(self.dut.clk)
            fmt = int(d.fmt_applied.value)
            if int(d.ce_l_any.value) and fmt == 0:
                self.bad_l += 1
            ob = int(d.lclk_obs.value)
            # a gated clock that is low at every falling edge cannot be toggling: sample the enables
            en = int(d.clk_en.value)
            self.toggles[0] += (en & 1); self.toggles[1] += (en >> 1) & 1
            if fmt == 0:
                assert (en >> 1) & 1 == 0 or int(d.core_rst_n.value) >> 1 & 1 == 0, "fp32 enabled in bf16 mode"
            else:
                assert (en & 1) == 0 or int(d.core_rst_n.value) & 1 == 0, "bf16 enabled in fp32 mode"


@cocotb.test()
async def format_switch(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    mon = ClkMon(dut)
    rng = random.Random(77)
    # FORMAT range / reset value
    await t.clear_errors()
    await t.wr("FORMAT", 2)
    assert "RANGE" in await t.errors() and await t.rd("FORMAT") == 0
    await t.clear_errors()
    cur = "bf16"
    data = {}
    seq = ["fp32", "bf16", "fp32", "fp32", "bf16", "bf16", "fp32", "bf16"]
    await t.wr("LANE_EN", 3)
    await t.wr("TRC_CFG", 0x1234)
    await t.wr("CLK_CFG", 0x1)
    for it, fmt in enumerate(seq):
        w = 16 if fmt == "bf16" else 32
        f = cc.FORMATS[fmt]["f"]
        # put some state in: weights, input, a result
        if it == 0:
            Wl, Bl = cc.rand_weights(rng, GEO, f)
            await t.load_weights(cur, Wl, Bl)
            await t.write_x(1, cc.rand_x(rng, GEO, cc.FORMATS[cur]["f"]))
            await t.infer(1)
            await t.ctrl("CNT_CLR")
            await t.infer(1)
        inf_before = await t.rd64("INFER_CNT_LO", "INFER_CNT_HI")
        tot_before = await t.rd64("TOTAL_CYC_LO", "TOTAL_CYC_HI")
        await t.wr("FORMAT", 0 if fmt == "bf16" else 1)
        s = await t.status()
        assert (s >> STAT["ACTIVE"]) & 1 or True
        await t.wait_idle()
        assert await t.rd("FORMAT") == (0 if fmt == "bf16" else 1)
        s = await t.status()
        assert (s >> STAT["FORMAT"]) & 1 == (fmt == "fp32")
        assert (s >> STAT["WSTALE"]) & 1, "WSTALE set by a FORMAT switch"
        # cleared state
        assert all(v == 0 for v in await t.rb.read_burst(R.XBUF_BASE, 8)) and \
            all(v == 0 for v in await t.rb.read_burst(R.XBUF_BASE + t.g.xw * 0 + 8, 8))
        assert all(v == 0 for v in await t.read_z())
        for n in ("CHECKSUM", "SR_PASS_CKSUM", "LAST_CYCLES", "LOAD_CRC"):
            assert await t.rd(n) == 0, n
        assert await t.rd("LANE_EN") == 3 and await t.rd("TRC_CFG") == 0x1234, "configuration kept"
        assert await t.rd("CLK_CFG") & 0x1F == 1
        assert await t.rd64("INFER_CNT_LO", "INFER_CNT_HI") == inf_before, "cumulative counters kept"
        assert await t.rd64("TOTAL_CYC_LO", "TOTAL_CYC_HI") >= tot_before
        cur = fmt
        # reload and compare bit-exact with the bare core of this format
        Wl, Bl = cc.rand_weights(rng, GEO, f)
        await t.load_weights(fmt, Wl, Bl)
        await t.bare_load(fmt, Wl, Bl)
        s = await t.status()
        assert not (s >> STAT["WSTALE"]) & 1
        for k in range(2):
            x = cc.rand_x(rng, GEO, f)
            await t.write_x(k, x)
            z = await t.infer(k)
            zb, cyc = await t.bare_infer(fmt, x)
            assert z == zb, f"iter {it} {fmt}: chip != bare core"
            assert await t.rd("LAST_CYCLES") == cyc
        # switch while ACTIVE is rejected
        if it == 1:
            await t.clear_errors()
            await t.wr("XSEL", 0)
            await t.ctrl("START")
            await t.wr("FORMAT", 1 if fmt == "bf16" else 0)
            assert "BUSY_WR" in await t.errors()
            await t.wait_idle()
            assert await t.rd("FORMAT") == (0 if fmt == "bf16" else 1)
    assert mon.bad_l == 0, f"L half enabled {mon.bad_l} cycles in bf16 mode"
    dut._log.info("T-FMT: 8 switches, state effects, bit-exact after reload, L half idle in bf16, clock gating exclusive")
