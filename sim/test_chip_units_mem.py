"""T-UNITS memories: rondo_wmem ownership, CE gating, L never enabled in bf16 mode."""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

NP = 8


@cocotb.test()
async def wmem(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for s in ("fmt", "wm_addr", "bm_addr", "mem_act", "wp_en", "wp_we", "wp_bias", "wp_lane",
              "wp_addr", "wp_half", "wp_wd_h", "wp_wd_l"):
        getattr(dut, s).value = 0
    await FallingEdge(dut.clk)
    rng = random.Random(4)
    NW, NB, NL = 56, 7, 2
    ref = {}
    # wrapper writes (both halves), then read back through the wrapper
    for bias in (0, 1):
        for lane in range(NL):
            for a in range(NB if bias else NW):
                h, l = rng.getrandbits(128), rng.getrandbits(128)
                dut.wp_en.value = 1; dut.wp_we.value = 1; dut.wp_bias.value = bias
                dut.wp_lane.value = lane; dut.wp_addr.value = a; dut.wp_half.value = 3
                dut.wp_wd_h.value = h; dut.wp_wd_l.value = l
                await FallingEdge(dut.clock if False else dut.clk)
                ref[(bias, lane, a)] = (h, l)
    dut.wp_we.value = 0
    for (bias, lane, a), (h, l) in ref.items():
        dut.wp_en.value = 1; dut.wp_bias.value = bias; dut.wp_lane.value = lane
        dut.wp_addr.value = a; dut.wp_half.value = 3
        await FallingEdge(dut.clk)
        dut.wp_en.value = 0
        assert int(dut.wp_rd_h.value) == h and int(dut.wp_rd_l.value) == l, (bias, lane, a)
    # half-masked write only touches the selected half
    (bias, lane, a) = (0, 1, 5)
    h0, l0 = ref[(0, 1, 5)]
    dut.wp_en.value = 1; dut.wp_we.value = 1; dut.wp_bias.value = 0; dut.wp_lane.value = 1
    dut.wp_addr.value = 5; dut.wp_half.value = 1; dut.wp_wd_h.value = 0x1111; dut.wp_wd_l.value = 0x2222
    await FallingEdge(dut.clk)
    dut.wp_we.value = 0; dut.wp_half.value = 3
    await FallingEdge(dut.clk); dut.wp_en.value = 0
    assert int(dut.wp_rd_h.value) == 0x1111 and int(dut.wp_rd_l.value) == l0
    ref[(0, 1, 5)] = (0x1111, l0)
    # layer reads, bf16: only H enabled
    for fmt in (0, 1):
        dut.fmt.value = fmt
        ce_l_seen = 0
        for lane in range(NL):
            for a in range(0, NW, 7):
                dut.mem_act.value = 1 << lane
                bits = 0
                dut.wm_addr.value = (a << (6 * lane))
                dut.bm_addr.value = ((a % NB) << (3 * lane))
                await FallingEdge(dut.clk)
                ce_l_seen |= int(dut.ce_l_any.value)
                dut.mem_act.value = 0
                await FallingEdge(dut.clk)
                wh = (int(dut.wm_q_h.value) >> (128 * lane)) & ((1 << 128) - 1)
                wl = (int(dut.wm_q_l.value) >> (128 * lane)) & ((1 << 128) - 1)
                bh = (int(dut.bm_q_h.value) >> (128 * lane)) & ((1 << 128) - 1)
                assert wh == ref[(0, lane, a)][0]
                assert bh == ref[(1, lane, a % NB)][0]
                if fmt:
                    assert wl == ref[(0, lane, a)][1]
        assert ce_l_seen == fmt, f"L macros enabled by the layer in fmt {fmt}: {ce_l_seen}"
    # ownership: a colliding wrapper write is dropped and flagged
    dut.fmt.value = 1
    before = ref[(0, 0, 3)]
    dut.mem_act.value = 1; dut.wm_addr.value = 9
    dut.wp_en.value = 1; dut.wp_we.value = 1; dut.wp_bias.value = 0; dut.wp_lane.value = 0
    dut.wp_addr.value = 3; dut.wp_half.value = 3; dut.wp_wd_h.value = 0xDEAD; dut.wp_wd_l.value = 0xBEEF
    await FallingEdge(dut.clk)
    assert int(dut.wp_denied.value) == 1
    dut.mem_act.value = 0; dut.wp_we.value = 0; dut.wp_en.value = 1; dut.wp_half.value = 3
    await FallingEdge(dut.clk); dut.wp_en.value = 0
    await FallingEdge(dut.clk)
    assert (int(dut.wp_rd_h.value), int(dut.wp_rd_l.value)) == before, "denied write must not modify memory"
