"""T-KAN: LAYER=1 (KAN, bf16, SMALL): packing bit-exact vs the bare kan_layer_pipe; the bias region reports ADDR."""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer
from chip_tb import ChipTB, R, STAT
import chip_common as cc
import fpmodel as fm

P, NOUT, NL, NOB, NMAC, DEPTH = 8, 16, 2, 8, 8, 7
DP1 = DEPTH + 1
NOUTL = NOUT // NL
NGROUP = NOB * DP1 // NMAC
NBAT = NOUTL // NOB


class Kan(ChipTB):
    def __init__(self, dut):
        geo = cc.Geo(NOUT, P, NL)
        super().__init__(dut, geo, bare=False)
        self.g = R.Geometry(width=NOUT, pdim=P, lanes=NL, nslot=8, npar=8, depth=7, nxbuf=4)
        self.g.nwords = NBAT * NGROUP * P
        self.g.waw = 6


@cocotb.test()
async def kan_option(dut):
    t = Kan(dut)
    for n in ("k_w_we", "k_w_lane", "k_w_addr", "k_w_din", "k_x", "k_start"):
        getattr(dut, n).value = 0
    await t.boot()
    rng = random.Random(9)
    f = fm.BF16
    c = [[[fm.to_bits(f, rng.uniform(-0.5, 0.5) / 3) for n in range(DP1)] for i in range(P)] for o in range(NOUT)]
    # chip: element-wise writes in the spec 13.24 packing (word fields f = ch % NMAC)
    for l in range(NL):
        for b in range(NBAT):
            for g in range(NGROUP):
                for i in range(P):
                    base = t.g.weight_word_addr(l, (b * NGROUP + g) * P + i, 0)
                    for fld in range(NMAC):
                        ch = g * NMAC + fld
                        o = l * NOUTL + b * NOB + ch // DP1
                        await t.rb.write(base + fld, c[o][i][ch % DP1])
    # bare kan layer, same words through its port
    for l in range(NL):
        dut.k_w_lane.value = l
        for b in range(NBAT):
            for g in range(NGROUP):
                for i in range(P):
                    word = 0
                    for fld in range(NMAC):
                        ch = g * NMAC + fld
                        o = l * NOUTL + b * NOB + ch // DP1
                        word |= c[o][i][ch % DP1] << (16 * fld)
                    dut.k_w_addr.value = (b * NGROUP + g) * P + i
                    dut.k_w_din.value = word
                    dut.k_w_we.value = 1
                    await FallingEdge(dut.clk)
    dut.k_w_we.value = 0
    for _ in range(4):
        await FallingEdge(dut.clk)
    assert not await t.errors()
    for it in range(5):
        x = [fm.to_bits(f, rng.uniform(-1, 1)) for _ in range(P)]
        await t.write_x(0, x)
        dut.k_x.value = cc.word_int(x, 16)
        await FallingEdge(dut.clk); dut.k_start.value = 1
        await FallingEdge(dut.clk); dut.k_start.value = 0
        n = 0
        while not int(dut.k_done.value):
            await FallingEdge(dut.clk); n += 1
            assert n < 50000
        yb = int(dut.k_y.value)
        zc = await t.infer(0)
        for j in range(NOUT):
            assert zc[j] & 0xFFFF == (yb >> (16 * j)) & 0xFFFF, f"input {it} output {j}"
    # no bias region in the KAN option
    await t.clear_errors()
    await t.rb.write(R.BIAS_BASE, 1)
    assert "ADDR" in await t.errors()
    capv = await t.rd("CAPS")
    caps = R.bits(R.CAPS_BITS, capv)
    assert R.caps_layer(capv) == 1 and "HAS_BIAS" not in caps, f"CAPS {capv:#x}: LAYER field {R.caps_layer(capv)} (spec 6.2: 1 = KAN), HAS_BIAS must be 0"
    assert "HAS_FP32" not in caps and "READBACK" not in caps and "GUARD" not in caps
    await t.clear_errors()
    await t.wr("FORMAT", 1)
    assert "RANGE" in await t.errors()
    dut._log.info("T-KAN: KAN packing through the chip bit-exact vs the bare kan_layer_pipe; bias region -> ADDR")
