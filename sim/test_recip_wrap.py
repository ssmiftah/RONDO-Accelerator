"""Unit test for recip_wrap: pole-guarded division f = K1 / clamp_signed(K0).

The HardFloat divider is iterative/clocked, so this drives a clock and the
inValid/inReady -> outValid handshake. Golden: clamp K0 in fp64, divide, cast to
fp32; checked in ULP (division is round-to-nearest, so <= 1 ULP after the
fp64->fp32 cast). Includes near-pole cases |K0| < eps.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32, ulp_diff

EPS = np.float32(0.01)


def golden_f(k0, k1):
    k0 = np.float32(k0); k1 = np.float32(k1)
    if abs(k0) < EPS:
        k0c = np.float32(np.copysign(float(EPS), float(k0)))
    else:
        k0c = k0
    return np.float32(np.float64(k1) / np.float64(k0c))


async def reset(dut):
    dut.inValid.value = 0
    dut.k0.value = 0
    dut.k1.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def divide(dut, k0, k1):
    # wait until the divider can accept
    while dut.inReady.value != 1:
        await RisingEdge(dut.clock)
    dut.k0.value = f32_to_bits(k0)
    dut.k1.value = f32_to_bits(k1)
    dut.inValid.value = 1
    await RisingEdge(dut.clock)
    dut.inValid.value = 0
    # wait for the result
    for _ in range(200):
        await RisingEdge(dut.clock)
        if dut.outValid.value == 1:
            return bits_to_f32(dut.f.value)
    raise TimeoutError("divider produced no outValid")


async def _check(dut, k0, k1, worst, tag):
    got = await divide(dut, k0, k1)
    exp = golden_f(k0, k1)
    d = ulp_diff(got, exp)
    assert d <= 1, f"[{tag}] K1/K0 = {k1}/{k0}: got {got}, exp {exp}, ulp {d}"
    worst[0] = max(worst[0], d)


@cocotb.test()
async def recip_directed(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    w = [0]
    await _check(dut, 2.0, 1.0, w, "1/2")        # K0=a0, K1=1 -> 0.5
    await _check(dut, -4.0, 3.0, w, "sign")       # -0.75
    await _check(dut, 408.0, 169.0, w, "d7")      # depth-7 continuant ratio
    await _check(dut, 0.001, 5.0, w, "pole+")     # |K0|<eps -> clamp to +eps
    await _check(dut, -0.002, 5.0, w, "pole-")    # clamp to -eps
    dut._log.info(f"recip directed passed (max ulp {w[0]})")


@cocotb.test()
async def recip_random(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(3)
    w = [0]
    n = 150
    for _ in range(n):
        k1 = np.float32(rng.uniform(-50, 50))
        # mix of normal and near-pole denominators
        k0 = np.float32(rng.uniform(-20, 20) if rng.random() < 0.85 else rng.uniform(-0.02, 0.02))
        await _check(dut, k0, k1, w, "rand")
    dut._log.info(f"recip random passed {n} cases (max ulp {w[0]})")
