"""T-SEQ: single-shot, self-run, counters, checksum, watchdog, soft reset, lane mask."""
import random
import cocotb
from cocotb.triggers import FallingEdge
from chip_tb import ChipTB, R, A, ERR, STAT
import chip_common as cc
import fpmodel as fm
from rondo_host import packing as K

GEO = cc.Geo(16, 8, 2)


class Mon:
    """records the cycle numbers of layer_start / layer_done pulses"""
    def __init__(self, dut):
        self.dut = dut; self.starts = []; self.dones = []; self.cyc = 0
        cocotb.start_soon(self.run())

    async def run(self):
        d = self.dut.u_dev
        while True:
            await FallingEdge(self.dut.clk)
            self.cyc += 1
            if int(d.layer_start.value):
                self.starts.append(self.cyc)
            if int(d.layer_done.value):
                self.dones.append(self.cyc)


async def setup(dut, fmt="bf16", seed=1, nx=4):
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = random.Random(seed)
    f = cc.FORMATS[fmt]["f"]
    if fmt == "fp32":
        await t.set_format("fp32")
    Wl, Bl = cc.rand_weights(rng, GEO, f)
    await t.load_weights(fmt, Wl, Bl)
    xs = [cc.rand_x(rng, GEO, f) for _ in range(nx)]
    for e, x in enumerate(xs):
        await t.write_x(e, x)
    zs = [t.model_z(fmt, Wl, Bl, x) for x in xs]
    return t, rng, f, Wl, Bl, xs, zs


def cks(zs_seq, w):
    c = 0
    for z in zs_seq:
        c = K.update(c, z, w)
    return c


@cocotb.test()
async def self_run_and_counters(dut):
    t, rng, f, Wl, Bl, xs, zs = await setup(dut)
    mon = Mon(dut)
    # single shot, bit exact; CHECKSUM updates once
    z = await t.infer(2)
    assert [v & 0xFFFF for v in z] == zs[2]
    assert await t.rd("CHECKSUM") == K.update(0, zs[2], 16)
    await t.ctrl("CKSUM_CLR", "CNT_CLR")
    assert await t.rd("CHECKSUM") == 0
    # self-run: K = 1, SR_N, 3*SR_N+1
    for n, k in ((1, 1), (4, 4), (3, 10), (2, 7)):
        mon.starts.clear(); mon.dones.clear()
        await t.wr("SR_N", n); await t.wr("SR_COUNT", k)
        await t.wr("IRQ_STATUS", 0xFFFFFFFF)
        await t.ctrl("CNT_CLR")
        await t.ctrl("SR_START")
        s = await t.status()
        assert (s >> STAT["SR_RUNNING"]) & 1 and (s >> STAT["ACTIVE"]) & 1
        await t.wait_idle()
        assert await t.rd("SR_DONE_CNT") == k
        seq = [zs[i % n] for i in range(k)]
        assert await t.rd("CHECKSUM") == cks(seq, 16), f"n={n} k={k} CHECKSUM"
        assert await t.rd("SR_PASS_CKSUM") == cks(seq[:n], 16) if k >= n else True
        irq = await t.rd("IRQ_STATUS")
        assert irq & 2 and not irq & 1, "SR_DONE set, DONE not set by self-run"
        assert len(mon.starts) == k and len(mon.dones) == k
        for i in range(1, k):
            assert mon.starts[i] - mon.dones[i - 1] == 2, "self-run launch spacing t+2"
        total = mon.dones[-1] - mon.starts[0]
        srcyc = await t.rd64("SR_CYC_LO", "SR_CYC_HI")
        assert srcyc >= total and srcyc <= total + 400, f"SR_CYC {srcyc} vs measured {total}"
        assert await t.rd64("INFER_CNT_LO", "INFER_CNT_HI") == k
        last = await t.rd("LAST_CYCLES")
        assert last == mon.dones[0] - mon.starts[0] - 0 or abs(last - (mon.dones[0] - mon.starts[0])) <= 1
        busy = await t.rd64("BUSY_CYC_LO", "BUSY_CYC_HI")
        assert busy >= k * (last - 2)
        tot = await t.rd64("TOTAL_CYC_LO", "TOTAL_CYC_HI")
        assert tot >= srcyc
    # SR_STOP with SR_COUNT = 0
    await t.wr("SR_N", 4); await t.wr("SR_COUNT", 0)
    await t.ctrl("CNT_CLR")
    await t.ctrl("SR_START")
    for _ in range(25):
        await t.status()
    await t.ctrl("SR_STOP")
    s = await t.status()
    await t.wait_idle()
    n_done = await t.rd("SR_DONE_CNT")
    assert n_done >= 1 and await t.rd64("INFER_CNT_LO", "INFER_CNT_HI") == n_done, "in-flight inference completes and counts"
    assert await t.rd("IRQ_STATUS") & 2
    assert await t.rd("CHECKSUM") == cks([zs[i % 4] for i in range(n_done)], 16)
    # SR_STOP without a self-run: no effect
    await t.clear_errors()
    await t.ctrl("SR_STOP")
    assert not await t.errors()
    # reads during busy, writes blocked
    await t.wr("SR_COUNT", 0)
    await t.ctrl("SR_START")
    for _ in range(5):
        assert await t.rd("CHIP_ID") == 0x524F4E44
        await t.rd("STATUS")
    await t.clear_errors()
    e = await t.rb.write(t.g.weight_word_addr(0, 0, 0), 5)
    assert e == 1 and "BUSY_WR" in await t.errors()
    z_during = await t.rb.read_burst(R.ZBUF_BASE, 4)      # torn reads allowed, must not fail
    await t.ctrl("SR_STOP")
    await t.wait_idle()
    # soft reset during a self-run: weights kept, next inference bit-exact, counters cleared
    await t.wr("SR_COUNT", 0)
    await t.ctrl("SR_START")
    for _ in range(30):
        await t.status()
    await t.ctrl("SOFT_RST")
    await t.wait_idle()
    s = await t.status()
    assert not (s >> STAT["SR_RUNNING"]) & 1 and await t.rd("SR_DONE_CNT") == 0
    assert await t.rd64("INFER_CNT_LO", "INFER_CNT_HI") == 0
    z = await t.infer(1)
    assert [v & 0xFFFF for v in z] == zs[1], "weights kept across the soft reset"


@cocotb.test()
async def watchdog_lane_mask_guard(dut):
    t, rng, f, Wl, Bl, xs, zs = await setup(dut, seed=7)
    mon = Mon(dut)
    # watchdog: limit below the inference time flags WDOG but the inference completes
    await t.clear_errors()
    await t.wr("WDOG_LIMIT", 20)
    z = await t.infer(0)
    assert [v & 0xFFFF for v in z] == zs[0]
    assert "WDOG" in await t.errors()
    await t.clear_errors()
    await t.wr("WDOG_LIMIT", 100000)
    await t.infer(0)
    assert "WDOG" not in await t.errors()
    await t.wr("WDOG_LIMIT", 0)
    # lane mask through the wrapper: disabled lane reads qNaN, enabled lane unchanged, no NaN/Inf error
    await t.clear_errors()
    await t.ctrl("GUARD_CLR")
    await t.wr("LANE_EN", 1)
    z = await t.infer(1)
    nl = GEO.nlad
    assert [v & 0xFFFF for v in z[:nl]] == zs[1][:nl]
    assert all(v & 0xFFFF == 0x7FC0 for v in z[nl:])
    assert await t.rd("NANINF_CNT") == 0 and "NAN_INF" not in await t.errors()
    st = await t.status()
    assert (st >> 16) & 0xFF == 1, "LANE_EN_APPLIED"
    await t.ctrl("CKSUM_CLR")
    await t.wr("LANE_EN", 3)
    # guard hits: inject a divisor below eps on one ladder (W = 0, B = beta)
    zero = [[[0] * GEO.pdim for _ in range(GEO.depth)] for _ in range(GEO.width)]
    one = 0x3F80
    Bg = [[0] * 6 + [0x3F80 if j % 3 else 0x0010] for j in range(GEO.width)]
    nclamp = sum(1 for j in range(GEO.width) if (Bg[j][6] & 0x7FFF) < 0x3C24)
    await t.load_weights("bf16", zero, Bg)
    await t.write_x(0, [0] * GEO.pdim)
    await t.ctrl("GUARD_CLR")
    await t.clear_errors()
    await t.infer(0)
    assert await t.rd("GUARD_HITS") == nclamp and nclamp > 0
    assert "GUARD" in await t.errors()
    st = await t.rd("STATUS")
    assert not (st >> 31) & 1, "GUARD is masked in ERR_MASK by default"
    await t.ctrl("GUARD_CLR")
    assert await t.rd("GUARD_HITS") == 0
    # a NaN output of an enabled lane: ERR NAN_INF and NANINF_CNT
    Bn = [[0] * 6 + [0x7F80] for _ in range(GEO.width)]      # beta = +Inf -> K contains Inf/NaN
    await t.load_weights("bf16", zero, Bn)
    await t.clear_errors(); await t.ctrl("GUARD_CLR")
    await t.infer(0)
    assert await t.rd("NANINF_CNT") > 0 and "NAN_INF" in await t.errors()


@cocotb.test()
async def soft_reset_backpressure(dut):
    """CHIP_FIX_PLAN task 9.1 (spec 8.2 rule 6): the response to the CTRL write that triggers SOFT_RST is not dropped when the master
    holds rsp_ready low across the soft reset; exactly one response arrives, then the bus works."""
    t = ChipTB(dut, GEO)
    await t.boot()
    clk = t.clk
    await FallingEdge(clk)
    dut.rb_rsp_ready.value = 0
    dut.rb_req_valid.value = 1; dut.rb_req_we.value = 1
    dut.rb_req_addr.value = A["CTRL"]; dut.rb_req_wdata.value = 1 << R.CTRL_BITS["SOFT_RST"]
    n = 0
    while not int(dut.rb_req_ready.value):
        await FallingEdge(clk); n += 1
        assert n < 100, "request never accepted"
    await FallingEdge(clk)
    dut.rb_req_valid.value = 0
    for _ in range(8):                                     # response pending, not accepted: SOFT_RST runs through (8 cycles)
        await FallingEdge(clk)
    dut.rb_rsp_ready.value = 1
    seen = 0
    first = None
    for k in range(60):
        if int(dut.rb_rsp_valid.value):
            seen += 1
            first = k if first is None else first
        await FallingEdge(clk)
    dut.rb_rsp_ready.value = 1
    assert seen == 1, f"expected exactly one response after SOFT_RST under backpressure, saw {seen} valid cycles"
    await t.wait_idle()
    for i in range(20):
        v = (i * 37) & 0xFFFF
        await t.wr("SCRATCH", v)
        assert await t.rd("SCRATCH") == v, "bus works after the soft reset"
    dut._log.info("T-SEQ: SOFT_RST response survives rsp_ready backpressure; bus alive")
