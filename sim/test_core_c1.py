import random
import cocotb
from cocotb.triggers import FallingEdge, Timer
import chip_common as cc
import fpmodel as fm


async def pulse(dut, name):
    await FallingEdge(dut.clock)
    getattr(dut, name).value = 1
    await FallingEdge(dut.clock)
    getattr(dut, name).value = 0


async def wait_done(dut, done, limit=20000):
    n = 0
    while int(getattr(dut, done).value) != 1:
        await FallingEdge(dut.clock)
        n += 1
        if n > limit:
            return None
    return n


@cocotb.test()
async def c1_fused(dut):
    W = len(dut.z_new) // 16
    geo = cc.Geo(16, 8, 2)
    W = int(dut.W.value)
    fmt = "bf16" if W == 16 else "fp32"
    f = cc.FORMATS[fmt]["f"]
    rng = random.Random(11)
    await cc.start_clock(dut)
    dut.k_w_we.value = 0; dut.k_start.value = 0; dut.k_x.value = 0
    dut.k_w_lane.value = 0; dut.k_w_addr.value = 0; dut.k_w_din.value = 0
    dut.start_new.value = 0; dut.start_old.value = 0
    await cc.core_reset(dut, geo, W)
    Wl, Bl = cc.rand_weights(rng, geo, f)
    await cc.core_load(dut, geo, W, Wl, Bl)
    x = cc.rand_x(rng, geo, f)
    dut.x.value = cc.pack_x(x, W)
    # (a) normal launch on the fixed core: reference z
    await pulse(dut, "start_new")
    assert await wait_done(dut, "done_new") is not None
    z_ref = int(dut.z_new.value)
    z_model, _, _, _, _ = cc.model_layer(geo, fmt, Wl, Bl, x)
    assert cc.unpack_z(z_ref, geo, W) == z_model, "fixed core z differs from bit-exact model"
    await FallingEdge(dut.clock); await FallingEdge(dut.clock)
    # (b) start asserted during the done cycle: complete, z identical (several x)
    for it in range(3):
        x2 = cc.rand_x(rng, geo, f) if it else x
        dut.x.value = cc.pack_x(x2, W)
        await pulse(dut, "start_new")
        assert await wait_done(dut, "done_new") is not None
        # now in the done cycle: assert start so it is sampled at the edge ending it
        await FallingEdge(dut.clock) if False else None
        dut.start_new.value = 1
        await FallingEdge(dut.clock)
        dut.start_new.value = 0
        n = await wait_done(dut, "done_new", limit=20000)
        assert n is not None, "start in the done cycle was lost (C1 not effective)"
        zz = int(dut.z_new.value)
        zm, _, _, _, _ = cc.model_layer(geo, fmt, Wl, Bl, x2)
        assert cc.unpack_z(zz, geo, W) == zm
        await FallingEdge(dut.clock); await FallingEdge(dut.clock)
    # (c) back-to-back at t+1 (start one cycle after the done cycle)
    await pulse(dut, "start_new")
    assert await wait_done(dut, "done_new") is not None
    await FallingEdge(dut.clock)
    dut.start_new.value = 1
    await FallingEdge(dut.clock)
    dut.start_new.value = 0
    assert await wait_done(dut, "done_new") is not None
    assert cc.unpack_z(int(dut.z_new.value), geo, W) == cc.model_layer(geo, fmt, Wl, Bl, x2)[0]
    await FallingEdge(dut.clock); await FallingEdge(dut.clock)
    # (d) the unmodified core, same stimulus, hangs (bug demonstration)
    dut.x.value = cc.pack_x(x, W)
    await pulse(dut, "start_old")
    assert await wait_done(dut, "done_old") is not None
    dut.start_old.value = 1
    await FallingEdge(dut.clock)
    dut.start_old.value = 0
    n = await wait_done(dut, "done_old", limit=5000)
    assert n is None, "unmodified core unexpectedly completed: bug not reproduced"
    assert int(dut.busy_old.value) == 1, "old core should be stuck busy"
    dut._log.info(f"C1 {fmt}: fixed core completes; unmodified core hangs busy=1")


@cocotb.test()
async def c1_kan(dut):
    try:
        await _kan(dut)
    except BaseException as e:
        import traceback; dut._log.error(traceback.format_exc()); raise


async def _kan(dut):
    rng = random.Random(5)
    if int(dut.W.value) != 16:
        return           # KAN instance is bf16 only; exercised in the bf16 run
    await cc.start_clock(dut)
    await Timer(1, unit='ns')
    dut.nReset.value = 0
    dut.k_w_we.value = 0; dut.k_start.value = 0
    await Timer(35, unit='ns')
    dut.nReset.value = 1
    await FallingEdge(dut.clock)
    f = fm.BF16
    nmac, p, nl = 8, 8, 2
    for l in range(nl):
        dut.k_w_lane.value = l
        for a in range(64):
            dut.k_w_addr.value = a
            dut.k_w_din.value = cc.word_int([cc.rand_elem(rng, f, -5, -2) for _ in range(nmac)], 16)
            dut.k_w_we.value = 1
            await FallingEdge(dut.clock)
    dut.k_w_we.value = 0
    for _ in range(4):
        await FallingEdge(dut.clock)
    x = [fm.to_bits(f, rng.uniform(-1, 1)) for _ in range(p)]
    dut.k_x.value = cc.word_int(x, 16)

    async def kpulse():
        await FallingEdge(dut.clock); dut.k_start.value = 1
        await FallingEdge(dut.clock); dut.k_start.value = 0

    await kpulse()
    assert await wait_done(dut, "k_done", 50000) is not None
    y_ref = int(dut.k_y.value)
    await FallingEdge(dut.clock); await FallingEdge(dut.clock)
    await kpulse()
    assert await wait_done(dut, "k_done", 50000) is not None
    dut.k_start.value = 1                  # start in the done cycle
    await FallingEdge(dut.clock)
    dut.k_start.value = 0
    assert await wait_done(dut, "k_done", 50000) is not None, "KAN start lost"
    assert int(dut.k_y.value) == y_ref
    dut._log.info("C1 KAN: start in done cycle completes, y identical")
