"""T-UNITS layers: format switch ordering (clock/reset), both datapaths through rondo_wmem."""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer
import chip_common as cc
import fpmodel as fm

NL, NP = 2, 8


async def cyc(dut, n=1):
    for _ in range(n):
        await FallingEdge(dut.clk)


async def load(dut, geo, fmt, Wl, Bl):
    W = 32 if fmt else 16
    dut.fmt.value = fmt
    ww, bw = cc.core_pack(geo, Wl, Bl)
    for bias, tab in ((0, ww), (1, bw)):
        for l in range(geo.lanes):
            for a, els in enumerate(tab[l]):
                for f in range(NP):
                    dut.wr_stb.value = 1; dut.region_bias.value = bias; dut.lane.value = l
                    dut.caddr.value = a; dut.field.value = f; dut.wdata.value = els[f]
                    await cyc(dut)
                    dut.wr_stb.value = 0
                    await cyc(dut)
    await cyc(dut, 4)


async def switch_to(dut, new):
    """spec 3.4: old layer into reset first, its clock gated 2 cycles later; new layer's clock
    enabled, reset released 2 cycles after that."""
    old = 1 - new
    rst = int(dut.core_rst_n.value) & ~(1 << old)
    dut.core_rst_n.value = rst
    await cyc(dut, 2)
    en = int(dut.clk_en.value) & ~(1 << old)
    dut.clk_en.value = en
    await cyc(dut, 2)
    dut.fmt.value = new
    dut.clk_en.value = en | (1 << new)
    await cyc(dut, 2)
    dut.core_rst_n.value = rst | (1 << new)
    await cyc(dut, 3)


async def infer(dut, geo, fmt, x):
    W = 32 if fmt else 16
    xv = 0
    for i, e in enumerate(x):
        xv |= e << (32 * i)
    dut.x.value = xv
    await FallingEdge(dut.clk); dut.start.value = 1
    await FallingEdge(dut.clk); dut.start.value = 0
    n = 0
    while not int(dut.done.value):
        await FallingEdge(dut.clk); n += 1
        assert n < 20000
    zv = int(dut.z.value)
    await cyc(dut, 3)
    return [(zv >> (32 * j)) & 0xFFFFFFFF for j in range(geo.width)]


@cocotb.test()
async def format_switch(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    geo = cc.Geo(16, 8, 2)
    for s in ("fmt", "dbg_fmt", "wr_stb", "rd_stb", "region_bias", "lane", "caddr", "field", "wdata",
              "crc_clr", "start", "x", "dbg_lane", "dbg_sig", "dbg_idx"):
        getattr(dut, s).value = 0
    dut.lane_en.value = 3
    dut.core_rst_n.value = 0; dut.clk_en.value = 0
    dut.rst_n.value = 0
    await Timer(32, unit="ns"); dut.rst_n.value = 1
    await cyc(dut, 2)
    rng = random.Random(12)
    seed_t8 = fm.load_seed(24, 8)
    cb0 = cf0 = 0
    cur = None
    sequence = [0, 1, 0, 1, 1, 0]
    for it, fmt in enumerate(sequence):
        if cur != fmt:
            if cur is None:
                dut.clk_en.value = 1 << fmt; dut.fmt.value = fmt
                await cyc(dut, 2)
                dut.core_rst_n.value = 1 << fmt
                await cyc(dut, 3)
            else:
                await switch_to(dut, fmt)
            cur = fmt
            f = cc.FORMATS["bf16" if fmt == 0 else "fp32"]["f"]
            Wl, Bl = cc.rand_weights(rng, geo, f)
            await load(dut, geo, fmt, Wl, Bl)
        f = cc.FORMATS["bf16" if fmt == 0 else "fp32"]["f"]
        b0, f0 = int(dut.cnt_b.value), int(dut.cnt_f.value)
        x = cc.rand_x(rng, geo, f)
        z = await infer(dut, geo, fmt, x)
        if fmt == 0:
            zm = cc.model_layer(geo, "bf16", Wl, Bl, x)[0]
            assert z == zm, f"iteration {it}: bf16 z mismatch"
            assert int(dut.cnt_f.value) == f0, "inactive fp32 layer clock toggled in bf16 mode"
            assert int(dut.cnt_b.value) > b0
        else:
            zm = cc.model_layer(geo, "fp32", Wl, Bl, x, nr_iters=2, tbits=8, seed=seed_t8)[0]
            assert z == zm, f"iteration {it}: fp32 z mismatch (TBITS 8, NR_ITERS 2 chip default)"
            assert int(dut.cnt_b.value) == b0, "inactive bf16 layer clock toggled in fp32 mode"
    dut._log.info("format switch bf16<->fp32 x6: bit-exact vs model, inactive clock never toggles")
