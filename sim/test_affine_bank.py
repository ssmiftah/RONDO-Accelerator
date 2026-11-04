"""affine_bank: coefficients for a bank of ladders, from x and resident weights.

Checked against a single-rounded fp32 FMA model in the same accumulation order.
The fp64 product of two fp32 values is exact, so rounding once at the end
reproduces the hardware; a plain a*b+c in fp32 rounds twice and disagrees in the
last ULP (docs/FUSION.md).
"""
import os, json
from pathlib import Path
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_common import f32_to_bits, bits_to_f32

DEPTH = int(os.environ.get("WL_DEPTH", "7"))
PDIM  = int(os.environ.get("WL_PDIM", "8"))
NMAC  = int(os.environ.get("WL_NMAC", "1"))
NLAD  = int(os.environ.get("WL_NLAD", "4"))
CHUNKS = (PDIM + NMAC - 1) // NMAC


def model(W, x, b):
    """Same order the RTL accumulates in: acc = b[k], then chunk by chunk."""
    out = []
    for k in range(DEPTH):
        acc = np.float32(b[k])
        for c in range(CHUNKS):
            for m in range(NMAC):
                i = c * NMAC + m
                xi = np.float32(x[i]) if i < PDIM else np.float32(0.0)
                wi = np.float32(W[k, i]) if i < PDIM else np.float32(0.0)
                acc = np.float32(np.float64(wi) * np.float64(xi) + np.float64(acc))
        out.append(acc)
    return np.array(out, dtype=np.float32)


@cocotb.test()
async def bank(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.w_we.value = 0; dut.b_we.value = 0; dut.in_valid.value = 0
    dut.lad.value = 0; dut.x.value = 0; dut.w_addr.value = 0
    dut.w_din.value = 0; dut.b_addr.value = 0; dut.b_din.value = 0
    dut.nReset.value = 0
    await Timer(35, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(5)
    Wt = rng.uniform(-1, 1, (NLAD, DEPTH, PDIM)).astype(np.float32)
    Bt = rng.uniform(-1, 1, (NLAD, DEPTH)).astype(np.float32)

    # load weights: word (lad, k, c) holds NMAC consecutive x-lanes
    for l in range(NLAD):
        for k in range(DEPTH):
            for c in range(CHUNKS):
                word = 0
                for m in range(NMAC):
                    i = c * NMAC + m
                    val = Wt[l, k, i] if i < PDIM else np.float32(0.0)
                    word |= (f32_to_bits(val) & 0xFFFFFFFF) << (m * 32)
                dut.w_addr.value = (l * DEPTH + k) * CHUNKS + c
                dut.w_din.value = word
                dut.w_we.value = 1
                await RisingEdge(dut.clock)
            dut.w_we.value = 0
            dut.b_addr.value = l * DEPTH + k
            dut.b_din.value = f32_to_bits(Bt[l, k])
            dut.b_we.value = 1
            await RisingEdge(dut.clock)
            dut.b_we.value = 0
    await RisingEdge(dut.clock)

    worst_ulp = 0
    for trial in range(6):
        x = rng.uniform(-2, 2, PDIM).astype(np.float32)
        xv = 0
        for i in range(PDIM):
            xv |= (f32_to_bits(x[i]) & 0xFFFFFFFF) << (i * 32)
        for l in range(NLAD):
            while dut.in_ready.value != 1:
                await RisingEdge(dut.clock)
            dut.x.value = xv
            dut.lad.value = l
            dut.in_valid.value = 1
            await RisingEdge(dut.clock)
            dut.in_valid.value = 0
            n = 0
            while dut.out_valid.value != 1:
                await RisingEdge(dut.clock)
                n += 1
                assert n < 10000, "affine_bank hung"
            av = int(dut.a.value)
            got = np.array([bits_to_f32((av >> (k * 32)) & 0xFFFFFFFF)
                            for k in range(DEPTH)], dtype=np.float32)
            exp = model(Wt[l], x, Bt[l])
            ulp = max(abs(int(f32_to_bits(g)) - int(f32_to_bits(e)))
                      for g, e in zip(got, exp))
            worst_ulp = max(worst_ulp, ulp)

    dut._log.info(f"AFFINE_BANK NLAD={NLAD} DEPTH={DEPTH} PDIM={PDIM} "
                  f"NMAC={NMAC}: max {worst_ulp} ULP")
    assert worst_ulp == 0, f"affine_bank differs by {worst_ulp} ULP"
