import random
import cocotb
from cocotb.triggers import FallingEdge
import chip_common as cc


async def go(dut, xv, timeout=20000):
    dut.x.value = xv
    await FallingEdge(dut.clock); dut.start.value = 1
    await FallingEdge(dut.clock); dut.start.value = 0
    n = 0; act = 0
    dm = du = None
    while dm is None or du is None:
        act |= int(dut.mem_act_m.value)
        if dm is None and int(dut.done_m.value): dm = n; zm = int(dut.z_m.value)
        if du is None and int(dut.done_u.value): du = n; zu = int(dut.z_u.value)
        await FallingEdge(dut.clock); n += 1
        assert n < timeout
    for _ in range(3):
        await FallingEdge(dut.clock)
    return dm, du, zm, zu, act


@cocotb.test()
async def c6_lane_mask(dut):
    W = int(dut.W.value)
    fmt = "bf16" if W == 16 else "fp32"
    cfgf = cc.FORMATS[fmt]["f"]
    geo = cc.Geo(16, 8, 2)
    rng = random.Random(66)
    await cc.start_clock(dut)
    dut.lane_en.value = 3
    await cc.core_reset(dut, geo, W)
    Wl, Bl = cc.rand_weights(rng, geo, cfgf)
    await cc.core_load(dut, geo, W, Wl, Bl)
    qnan = cfgf.qnan
    masks = [3, 0, 1, 2, 3] + [rng.randrange(4) for _ in range(8)]
    for it, m in enumerate(masks):
        dut.lane_en.value = m
        x = cc.rand_x(rng, geo, cfgf)
        dm, du, zm, zu, act = await go(dut, cc.pack_x(x, W))
        zml, zul = cc.unpack_z(zm, geo, W), cc.unpack_z(zu, geo, W)
        for l in range(geo.lanes):
            sl = slice(l * geo.nlad, (l + 1) * geo.nlad)
            if (m >> l) & 1:
                assert zml[sl] == zul[sl], f"mask {m:02b}: enabled lane {l} differs"
            else:
                assert all(v == qnan for v in zml[sl]), f"mask {m:02b}: disabled lane {l} not qNaN"
            assert ((act >> l) & 1) == ((m >> l) & 1), f"mask {m:02b}: mem_act lane {l} = {(act >> l) & 1}"
        assert dm <= du, f"mask {m:02b}: done later than unmasked ({dm} > {du})"
        if m == 0:
            assert dm <= 3, f"all-disabled done after {dm} cycles"
    dut._log.info(f"C6 {fmt}: {len(masks)} masks incl. 0 and all-ones OK")


@cocotb.test()
async def c6_start_in_done_disabled(dut):
    """B7 (CHIP_FIX_PLAN task 8): a start taken in the done cycle (C1 path, lane in L_FIN) while a lane is disabled (C6) must leave
    that lane's z at qNaN, not at the previous inference's values."""
    W = int(dut.W.value)
    fmt = "bf16" if W == 16 else "fp32"
    cfgf = cc.FORMATS[fmt]["f"]
    geo = cc.Geo(16, 8, 2)
    rng = random.Random(88)
    await cc.start_clock(dut)
    dut.lane_en.value = 3
    await cc.core_reset(dut, geo, W)
    Wl, Bl = cc.rand_weights(rng, geo, cfgf)
    await cc.core_load(dut, geo, W, Wl, Bl)
    qnan = cfgf.qnan
    for mask in (1, 2, 0, 1, 2):
        x = cc.rand_x(rng, geo, cfgf)
        dut.x.value = cc.pack_x(x, W)
        dut.lane_en.value = 3
        await FallingEdge(dut.clock); dut.start.value = 1
        await FallingEdge(dut.clock); dut.start.value = 0
        n = 0
        while not int(dut.done_m.value):
            await FallingEdge(dut.clock); n += 1
            assert n < 20000, "first inference did not finish"
        # the done cycle of inference 1: start (C1) with the lane mask changed
        z_first = cc.unpack_z(int(dut.z_m.value), geo, W)
        dut.lane_en.value = mask
        dut.start.value = 1
        await FallingEdge(dut.clock)
        dut.start.value = 0
        n = 0
        while not int(dut.done_m.value):
            await FallingEdge(dut.clock); n += 1
            assert n < 20000, f"mask {mask:02b}: start in the done cycle was lost"
        zm = cc.unpack_z(int(dut.z_m.value), geo, W)
        n = 0
        while not int(dut.done_u.value):
            await FallingEdge(dut.clock); n += 1
            assert n < 20000
        zu = cc.unpack_z(int(dut.z_u.value), geo, W)
        for l in range(geo.lanes):
            sl = slice(l * geo.nlad, (l + 1) * geo.nlad)
            if (mask >> l) & 1:
                assert zm[sl] == zu[sl], f"mask {mask:02b}: enabled lane {l} differs from the reference"
            else:
                assert all(v == qnan for v in zm[sl]), f"mask {mask:02b}: disabled lane {l} keeps stale z (not qNaN): {[hex(v) for v in zm[sl][:3]]}"
        for _ in range(4):
            await FallingEdge(dut.clock)
    dut._log.info(f"C6 {fmt}: start in the done cycle with a disabled lane -> qNaN")
