"""T-KAT (SMALL): the known-answer test runs through the real load path and its signature equals the
independent model; faults make it fail; the bist_en strap runs both formats."""
import cocotb
from cocotb.triggers import FallingEdge, Timer
from chip_tb import ChipTB, R, A, ERR, STAT
import chip_common as cc
import fpmodel as fm
from rondo_host import packing as K, regmap

import os
GEO = cc.FULL if os.environ.get("CHIP_GEOM") == "full" else cc.Geo(16, 8, 2)


def kat_signature(fmt):
    w = 16 if fmt == "bf16" else 32
    g = regmap.Geometry(width=GEO.width, pdim=GEO.pdim, lanes=GEO.lanes, nslot=GEO.nslot, npar=GEO.npar,
                        depth=GEO.depth, nxbuf=GEO.nxbuf)
    Wd, Bd, X = K.kat_stream(g, w, GEO.nxbuf)
    Wl, Bl = K.unpack_weights(Wd, Bd, g)
    Wl = [[[int(v) for v in row] for row in lad] for lad in Wl]
    Bl = [[int(v) for v in lad] for lad in Bl]
    X = [[int(v) for v in e] for e in X]
    zs = []
    for e in X:
        if fmt == "bf16":
            zs.append(cc.model_layer(GEO, "bf16", Wl, Bl, e)[0])
        else:
            zs.append(cc.model_layer(GEO, "fp32", Wl, Bl, e, nr_iters=2, tbits=8, seed=fm.load_seed(24, 8))[0])
    sig = 0
    for i in range(2 * GEO.nxbuf):
        sig = K.update(sig, zs[i % GEO.nxbuf], w)
    return sig, zs


@cocotb.test()
async def kat_register_triggered(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    t.poll_gap = 40
    for fmt in ("bf16", "fp32"):
        await t.set_format(fmt)
        await t.clear_errors()
        exp, zs = kat_signature(fmt)
        await t.ctrl("KAT_START")
        s = await t.status()
        assert (s >> STAT["ACTIVE"]) & 1 and (s >> STAT["KAT_RUNNING"]) & 1
        await t.wait_idle(timeout=400000)
        got = await t.rd("KAT_GOT_BF16" if fmt == "bf16" else "KAT_GOT_FP32")
        assert got == exp, f"{fmt}: KAT signature {got:#x} != model {exp:#x}"
        st = await t.rd("ST_STATUS")
        assert (st >> 1) & 1, "DONE"
        s = await t.status()
        assert (s >> STAT["WSTALE"]) & 1, "KAT overwrites weights: WSTALE"
        assert "KAT_FAIL" not in await t.errors(), "generated signature must match"
        stt = await t.rd("ST_STATUS")
        assert (stt >> 2) & 1 and (stt >> (3 if fmt == "bf16" else 4)) & 1 and (stt >> (7 if fmt == "bf16" else 8)) & 1
        assert await t.rd("CHECKSUM") == 0, "KAT must not touch CHECKSUM"
        assert (await t.rd("IRQ_STATUS")) >> 4 & 1, "SELFTEST_DONE"
    dut._log.info("T-KAT: register-triggered KAT signature == independent model (bf16, fp32)")


@cocotb.test()
async def kat_faults_and_strap(dut):
    from cocotb.handle import Force, Release
    t = ChipTB(dut, GEO)
    await t.boot()
    t.poll_gap = 40
    # stuck weight bit (H macro of lane 1, address 3) -> KAT fails and flags KAT_FAIL, st_pass low
    mem = getattr(dut.u_dev.u_mem, "lane[1]")
    mem.u_wh.f_addr.value = 3
    mem.u_wh.f_sa1.value = (1 << len(mem.u_wh.f_sa1)) - 1     # whole word stuck high (a single bit may already be 1 in the KAT data)
    mem.u_wh.f_en.value = 1
    await t.clear_errors()
    await t.ctrl("KAT_START")
    await t.wait_idle(timeout=800000)
    assert "KAT_FAIL" in await t.errors()
    st = await t.rd("ST_STATUS")
    assert not (st >> 2) & 1 and not (st >> 3) & 1 and int(dut.st_pass.value) == 0
    mem.u_wh.f_en.value = 0
    # a stuck lane datapath value (forced scan numerator bus) also fails the signature
    import os
    if os.environ.get("SIM", "icarus") == "icarus":
        lane0 = getattr(dut.u_dev.u_ly.g_cofr.g_b.u_bf16, "lane[0]")
        lane0.u_eng.res_k1_w.value = Force(0)
        await t.clear_errors()
        await t.ctrl("KAT_START")
        await t.wait_idle(timeout=800000)
        lane0.u_eng.res_k1_w.value = Release()
    else:
        # Verilator cannot force an internal combinational wire: use a stuck bias word (lane 0, group 1) instead
        mem0 = getattr(dut.u_dev.u_mem, "lane[0]")
        mem0.u_bh.f_addr.value = 1
        mem0.u_bh.f_sa1.value = (1 << len(mem0.u_bh.f_sa1)) - 1
        mem0.u_bh.f_en.value = 1
        await t.clear_errors()
        await t.ctrl("KAT_START")
        await t.wait_idle(timeout=800000)
        mem0.u_bh.f_en.value = 0
    assert "KAT_FAIL" in await t.errors()
    # healthy again
    await t.clear_errors()
    await t.ctrl("KAT_START")
    await t.wait_idle(timeout=800000)
    assert "KAT_FAIL" not in await t.errors()
    st = await t.rd("ST_STATUS")
    assert (st >> 2) & 1
    for _ in range(4):
        await FallingEdge(dut.clk)
    assert int(dut.st_pass.value) == 1, "st_pass pin high after a passing self-test"

    # bist_en strap at reset: both formats, FORMAT restored to bf16, st_pass at the end, busy during
    t2 = ChipTB(dut, GEO)
    dut.rst_n.value = 0
    dut.bist_strap.value = 1
    await Timer(60, unit="ns")
    dut.rst_n.value = 1
    busy_seen = 0
    for _ in range(400000):
        await FallingEdge(dut.clk)
        busy_seen |= int(dut.busy_pin.value)
        if busy_seen and not int(dut.busy_pin.value):
            k = dut.u_dev.g_kat.u_kat
            dut._log.error('busy fell: cs=%s es=%s step=%s run=%s seqact=%s' % (k.cs.value, k.es.value, k.step.value, k.st_running.value, dut.u_dev.seq_active.value))
            break
    assert busy_seen and not int(dut.busy_pin.value), "busy high while the strap self-test runs"
    for _ in range(4):
        await FallingEdge(dut.clk)
    t2.poll_gap = 0
    dut._log.error('ST_STATUS=%#x ERR=%s FORMAT=%d' % (await t2.rd('ST_STATUS'), await t2.errors(), await t2.rd('FORMAT')))
    assert int(dut.st_pass.value) == 1

    st = await t2.rd("ST_STATUS")
    assert (st >> 6) & 1 and (st >> 7) & 1 and (st >> 8) & 1 and (st >> 3) & 1 and (st >> 4) & 1, hex(st)
    assert await t2.rd("FORMAT") == 0
    dut._log.info("T-KAT: faults fail the KAT, healthy passes, bist_en strap runs both formats and drives st_pass")


async def _cycles(dut, n):
    for _ in range(n):
        await FallingEdge(dut.clk)


@cocotb.test()
async def kat_refused_when_core_off(dut):
    """B2 (CHIP_FIX_PLAN task 2): KAT_START is refused (START_BUSY) while PWR_CTRL.CORE_HOLD or CORE_CLK_OFF is set.

    Before the fix the KAT loaded ~25k words and then waited for a launch that the sequencer had refused: ACTIVE stayed 1."""
    t = ChipTB(dut, GEO)
    await t.boot()
    t.poll_gap = 40
    await t.set_format("bf16")
    await t.clear_errors()
    for pwr in (0b01, 0b10, 0b11):
        await t.wr("PWR_CTRL", pwr)
        await t.wait_idle(timeout=2000)
        await t.clear_errors()
        crc0 = await t.rd("LOAD_CRC")
        ws0 = (await t.status() >> STAT["WSTALE"]) & 1
        await t.ctrl("KAT_START")
        await _cycles(dut, 200)
        problems = []
        s = await t.status()
        if (s >> STAT["ACTIVE"]) & 1:
            problems.append("ACTIVE still 1 after 200 cycles")
        errs = await t.errors()
        if "START_BUSY" not in errs:
            problems.append(f"no START_BUSY (errors={errs})")
        if await t.rd("ST_STATUS") & 1:
            problems.append("ST_STATUS.RUNNING = 1")
        if await t.rd("LOAD_CRC") != crc0 or ((s >> STAT["WSTALE"]) & 1) != ws0:
            problems.append("a load happened (LOAD_CRC / WSTALE changed)")
        dut._log.info(f"KAT_START with PWR_CTRL={pwr:#04b}: problems={problems}")
        if problems:
            if (s >> STAT["ACTIVE"]) & 1:                     # recover so that the failure is reported cleanly
                await t.ctrl("SOFT_RST"); await t.wait_idle()
            await t.wr("PWR_CTRL", 0)
        assert not problems, f"PWR_CTRL={pwr:#04b}: " + "; ".join(problems)
        await t.wr("PWR_CTRL", 0)
        await t.wait_idle(timeout=2000)
        await t.clear_errors()
        await t.ctrl("KAT_START")
        await t.wait_idle(timeout=400000)
        assert "KAT_FAIL" not in await t.errors() and (await t.rd("ST_STATUS") >> 2) & 1, "KAT passes once the cores run"
    dut._log.info("T-KAT: KAT_START refused with CORE_HOLD / CORE_CLK_OFF, then passes after PWR_CTRL = 0")


@cocotb.test()
async def soft_reset_during_kat(dut):
    """CHIP_FIX_PLAN task 9.1: SOFT_RST at a random point of a running KAT, with random rsp_ready backpressure on the external port.
    No internal (KAT/MBIST) request may be accepted after the first srst cycle until the next KAT_START, and the bus works after each trial."""
    import random
    rng = random.Random(909)
    t = ChipTB(dut, GEO)
    await t.boot()
    arb = dut.u_dev.u_arb
    state = dict(allow=True, seen_srst=False, stray=0, strays=[])

    async def monitor():
        while True:
            await FallingEdge(dut.clk)
            if int(dut.u_dev.srst.value):
                state["seen_srst"] = True
            if state["seen_srst"] and not state["allow"]:
                if int(arb.o_req_valid.value) and int(arb.o_req_ready.value) and int(arb.o_req_int.value):
                    state["stray"] += 1

    async def backpressure():
        while True:
            await FallingEdge(dut.clk)
            dut.rb_rsp_ready.value = 1 if rng.random() < 0.6 else 0

    mon = cocotb.start_soon(monitor())
    bp = cocotb.start_soon(backpressure())
    for trial in range(30):
        state["allow"] = True; state["seen_srst"] = False
        await t.ctrl("KAT_START")
        for _ in range(rng.randint(50, 5000)):
            await FallingEdge(dut.clk)
        state["allow"] = False
        await t.ctrl("SOFT_RST")
        for _ in range(60):
            await FallingEdge(dut.clk)
        await t.wait_idle(timeout=4000)
        for _ in range(30):                                # internal requests accepted late would show up here
            await FallingEdge(dut.clk)
        v = rng.randrange(1 << 32)
        await t.wr("SCRATCH", v)
        assert await t.rd("SCRATCH") == v, f"trial {trial}: bus broken after the soft reset"
        assert state["stray"] == 0, f"trial {trial}: {state['stray']} internal request(s) accepted after srst"
        await t.clear_errors()
    mon.kill(); bp.kill()
    dut.rb_rsp_ready.value = 1
    dut._log.info("T-KAT: 30 soft resets during a running KAT, no stray internal request, bus alive")
