"""T-UNITS clock/reset primitives (spec 15.4): sync, reset sync, ICG, clock mux, divider."""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, FallingEdge, First
from cocotb.utils import get_sim_time


_clk_tasks = []


async def setup(dut, p0=10, p1=14):
    for t in _clk_tasks:
        t.cancel()
    _clk_tasks[:] = [cocotb.start_soon(Clock(dut.clk0, p0, unit="ns").start()),
                     cocotb.start_soon(Clock(dut.clk1, p1, unit="ns").start())]
    for s, v in (("sel", 0), ("test_mode", 0), ("div", 0), ("en_async", 1), ("sd", 0),
                 ("arst_n", 1), ("meas_en", 0)):
        getattr(dut, s).value = v
    dut.rst_n.value = 0
    await Timer(33, unit="ns")
    dut.rst_n.value = 1
    await Timer(50, unit="ns")


@cocotb.test()
async def sync_and_reset_sync(dut):
    await setup(dut)
    # synchronizer: 2-cycle latency
    dut.sd.value = 0
    await FallingEdge(dut.clk0)
    dut.sd.value = 0xA
    await FallingEdge(dut.clk0)
    assert int(dut.sq.value) == 0
    await FallingEdge(dut.clk0)
    assert int(dut.sq.value) == 0xA, "2-stage synchronizer: output after 2 edges"
    # reset sync: async assert, sync deassert after 2 edges
    assert int(dut.rs_out.value) == 1
    await Timer(3, unit="ns")
    dut.arst_n.value = 0
    await Timer(1, unit="ns")
    assert int(dut.rs_out.value) == 0, "async assert"
    await Timer(40, unit="ns")
    await FallingEdge(dut.clk0)
    dut.arst_n.value = 1
    await RisingEdge(dut.clk0); await Timer(1, unit="ns")
    assert int(dut.rs_out.value) == 0
    await RisingEdge(dut.clk0); await Timer(1, unit="ns")
    assert int(dut.rs_out.value) == 1, "deassert after 2 edges"
    # test_mode bypass
    dut.test_mode.value = 1
    dut.arst_n.value = 0
    await Timer(1, unit="ns")
    assert int(dut.rs_out.value) == 0
    dut.arst_n.value = 1
    await Timer(1, unit="ns")
    assert int(dut.rs_out.value) == 1, "test_mode: direct"
    dut.test_mode.value = 0


@cocotb.test()
async def divider_and_icg(dut):
    await setup(dut)
    dut.meas_en.value = 1
    for d in range(4):
        n = 1 << d
        dut.div.value = d
        for _ in range(40):                     # let the change apply at a wrap
            await RisingEdge(dut.clk0)
        assert int(dut.div_applied.value) == d
        cnt = 0
        async def counter():
            nonlocal cnt
            while True:
                await RisingEdge(dut.div_out)
                cnt += 1
        t = cocotb.start_soon(counter())
        for _ in range(800):
            await RisingEdge(dut.clk0)
        t.cancel()
        assert abs(cnt - 800 // n) <= 1, f"div {n}: {cnt} edges in 800 cycles"
    # ICG: toggle the enable at random times (also while clk is high)
    rng = random.Random(3)
    for _ in range(400):
        dut.en_async.value = rng.getrandbits(1)
        await Timer(rng.randint(1, 13), unit="ns")
    assert int(dut.div_min_hi.value) >= 4900, f"divider output narrow pulse {int(dut.div_min_hi.value)} ps"
    assert int(dut.icg_min_hi.value) >= 4900, f"ICG output narrow pulse {int(dut.icg_min_hi.value)} ps"
    dut.meas_en.value = 0


@cocotb.test()
async def clk_mux_glitch_free(dut):
    for (p0, p1) in ((10, 14), (10, 10), (10, 23), (14, 10)):
        await setup(dut, p0, p1)
        rng = random.Random(p0 * 100 + p1)
        dut.meas_en.value = 1
        sel_prev = 0
        seen = {0: 0, 1: 0}
        for it in range(120):
            s = rng.getrandbits(1)
            dut.sel.value = s
            await Timer(rng.randint(1, 160), unit="ns")
        dut.sel.value = 1
        await Timer(300, unit="ns")
        # now selected clk1: edges follow clk1
        e = 0
        async def cnt():
            nonlocal e
            while True:
                await RisingEdge(dut.mux_out); e += 1
        t = cocotb.start_soon(cnt()); await Timer(1000, unit="ns"); t.cancel()
        assert abs(e - 1000 // p1) <= 1, f"mux not following clk1: {e} edges"
        hi, lo = int(dut.mux_min_hi.value), int(dut.mux_min_lo.value)
        lim = int(min(p0, p1) / 2 * 1000) - 100
        assert hi >= lim and lo >= lim, f"glitch: min high {hi} ps, min low {lo} ps (limit {lim}) for {p0}/{p1}"
        dut.meas_en.value = 0
        # reset forces clk0 (dead clk1 recovery): hold rst_n low and check selection
        dut.sel.value = 1
        await Timer(100, unit="ns")
        dut.rst_n.value = 0
        await Timer(60, unit="ns")
        e = 0
        t = cocotb.start_soon(cnt()); await Timer(500, unit="ns"); t.cancel()
        assert abs(e - 500 // p0) <= 1, "reset must select clk0 regardless of sel"
        dut.rst_n.value = 1
    dut._log.info("clk_mux: glitch-free in random switching, reset selects clk0")
    # test_mode bypass: output follows clk0 whatever sel is
    dut.test_mode.value = 1
    dut.sel.value = 1
    await Timer(50, unit="ns")
    e = 0
    t = cocotb.start_soon(cnt()); await Timer(500, unit="ns"); t.cancel()
    assert abs(e - 500 // 14) <= 1, f"test_mode bypass: {e} edges"
