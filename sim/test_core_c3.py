import random
import cocotb
from cocotb.triggers import FallingEdge
import chip_common as cc


@cocotb.test()
async def c3_ext_mem(dut):
    W = int(dut.W.value)
    fmt = "bf16" if W == 16 else "fp32"
    f = cc.FORMATS[fmt]["f"]
    geo = cc.Geo(16, 8, 2)
    rng = random.Random(33)
    await cc.start_clock(dut)
    await cc.core_reset(dut, geo, W)
    Wl, Bl = cc.rand_weights(rng, geo, f)
    await cc.core_load(dut, geo, W, Wl, Bl)
    mism_cycles = 0
    for it in range(50):
        x = cc.rand_x(rng, geo, f)
        dut.x.value = cc.pack_x(x, W)
        await FallingEdge(dut.clock); dut.start.value = 1
        await FallingEdge(dut.clock); dut.start.value = 0
        n = 0
        seen_act = 0
        while True:
            seen_act |= int(dut.mem_act_o.value)
            di, de = int(dut.done_i.value), int(dut.done_e.value)
            assert di == de, f"input {it}: done differs at cycle {n} (int {di}, ext {de})"
            assert int(dut.busy_i.value) == int(dut.busy_e.value)
            if di:
                break
            await FallingEdge(dut.clock); n += 1
            assert n < 20000
        zi, ze = int(dut.z_i.value), int(dut.z_e.value)
        assert zi == ze, f"input {it}: z differs between EXT_MEM=0 and 1"
        if it < 3:
            assert cc.unpack_z(ze, geo, W) == cc.model_layer(geo, fmt, Wl, Bl, x)[0]
        assert seen_act == (1 << geo.lanes) - 1, "mem_act never asserted on some lane"
        for _ in range(3):
            await FallingEdge(dut.clock)
    assert int(dut.mem_act_o.value) == 0, "mem_act stuck high while idle"
    dut._log.info(f"C3 {fmt}: EXT_MEM=1 matches EXT_MEM=0 on 50 inputs (z, done cycle, busy)")
