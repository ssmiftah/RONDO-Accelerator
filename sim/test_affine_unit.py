"""Bit-exactness test for affine_unit: a[k] = w[k].x + bias[k].

This is the new hardware in the fused datapath, so it gets the strict test: the
coefficients must match a single-rounded fp32 FMA model to 0 ULP. The end-to-end
fused test is necessarily looser, because the ladder amplifies any last-ULP
difference by its own conditioning.
"""
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32


def fma32(a, b, c):
    return np.float32(np.float64(a) * np.float64(b) + np.float64(c))


def a_model(x, Wm, bias):
    d, pdim = Wm.shape
    a = np.zeros(d, dtype=np.float32)
    for k in range(d):
        acc = np.float32(bias[k])
        for i in range(pdim):
            acc = fma32(Wm[k, i], x[i], acc)
        a[k] = acc
    return a


def pack(v):
    out = 0
    for i, val in enumerate(np.ravel(v)):
        out |= (f32_to_bits(np.float32(val)) & 0xFFFFFFFF) << (i * 32)
    return out


async def load_weights(dut, Wm, nmac):
    """Weights are stationary: write them once, NMAC per word, then evaluate."""
    d, pdim = Wm.shape
    chunks = (pdim + nmac - 1) // nmac
    padded = np.zeros((d, chunks * nmac), dtype=np.float32)
    padded[:, :pdim] = Wm                       # zero pad: fma(0,x,acc) is exact
    for k in range(d):
        for c in range(chunks):
            dut.w_addr.value = k * chunks + c
            dut.w_din.value = pack(padded[k, c * nmac:(c + 1) * nmac])
            dut.w_we.value = 1
            await RisingEdge(dut.clock)
    dut.w_we.value = 0
    await RisingEdge(dut.clock)


@cocotb.test()
async def affine_exact(dut):
    depth = len(dut.bias) // 32
    pdim = len(dut.x) // 32
    nmac = len(dut.w_din) // 32
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.w_we.value = 0
    dut.w_addr.value = 0
    dut.w_din.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(31)
    for t in range(30):
        x = rng.uniform(-4, 4, pdim).astype(np.float32)
        Wm = rng.uniform(-2, 2, (depth, pdim)).astype(np.float32)
        bias = rng.uniform(-3, 3, depth).astype(np.float32)
        await load_weights(dut, Wm, nmac)
        dut.x.value = pack(x)
        dut.bias.value = pack(bias)
        dut.in_valid.value = 1
        await RisingEdge(dut.clock)
        dut.in_valid.value = 0
        for _ in range(depth * pdim + 60):
            await RisingEdge(dut.clock)
            if dut.out_valid.value == 1:
                break
        else:
            raise TimeoutError("affine_unit produced no out_valid")

        raw = int(dut.a.value)
        got = np.array([bits_to_f32((raw >> (k * 32)) & 0xFFFFFFFF) for k in range(depth)],
                       dtype=np.float32)
        exp = a_model(x, Wm, bias)
        ulp = np.abs(got.view(np.int32) - exp.view(np.int32))
        assert ulp.max() == 0, (
            f"vector {t}: {int((ulp > 0).sum())}/{depth} coefficients differ, "
            f"max {int(ulp.max())} ULP\n  got {got}\n  exp {exp}")

    dut._log.info(f"AFFINE DEPTH={depth} PDIM={pdim} NMAC={nmac}: 30 vectors, all coefficients 0 ULP")
