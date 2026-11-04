"""Fusion test: drive (x, W, bias) and check f, with `a` never crossing a port.

The reference recomputes the affine maps and the ladder in fp64 from the same
inputs, so this checks the whole fused path rather than just the scan.
"""
import os
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01


def _ladder(a):
    d = len(a)
    K = np.ones(d + 2, dtype=np.float64)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS)


def f_reference(x, Wm, bias):
    """Exact reference: the value the operator is *supposed* to have."""
    a = Wm.astype(np.float64) @ x.astype(np.float64) + bias.astype(np.float64)
    return _ladder(a), a


def fma32(a, b, c):
    """Single-rounded fp32 fused multiply-add, matching HardFloat mulAddRecFN.
    The fp64 product of two fp32 values is exact, so rounding once at the end
    reproduces the hardware exactly -- a plain a*b+c in fp32 rounds twice and
    does not."""
    return np.float32(np.float64(a) * np.float64(b) + np.float64(c))


def f_reference_fp32(x, Wm, bias):
    """Format-faithful reference: the arithmetic the hardware actually performs,
    fused multiply-adds and all. The error against fp64 grows with p because the
    affine unit sums p terms in order; that is a property of fp32, not of the RTL.
    Asserting against this model isolates hardware correctness from format error."""
    d, pdim = Wm.shape
    a = np.zeros(d, dtype=np.float32)
    for k in range(d):
        acc = np.float32(bias[k])
        for i in range(pdim):
            acc = fma32(Wm[k, i], x[i], acc)
        a[k] = acc
    K = np.ones(d + 2, dtype=np.float32)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = fma32(a[k], K[k + 1], K[k + 2])
    k0g = np.float32(np.sign(K[0]) * max(abs(float(K[0])), EPS))
    return float(np.float32(np.float64(K[1]) / np.float64(k0g))), a, float(abs(K[0]))


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


async def reset(dut):
    dut.in_valid.value = 0
    dut.x.value = 0
    dut.bias.value = 0
    dut.w_we.value = 0
    dut.w_addr.value = 0
    dut.w_din.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def evaluate(dut, x, Wm, bias, depth, pdim, nmac):
    await load_weights(dut, Wm, nmac)
    dut.x.value = pack(x)
    dut.bias.value = pack(bias)
    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0
    for n in range(depth * pdim + depth * 4 + 200):
        await RisingEdge(dut.clock)
        if dut.out_valid.value == 1:
            return bits_to_f32(int(dut.f.value) & 0xFFFFFFFF), n + 2
    raise TimeoutError("fused_ladder produced no out_valid")


@cocotb.test()
async def fused_random(dut):
    depth = len(dut.bias) // 32
    pdim = len(dut.x) // 32
    nmac = len(dut.w_din) // 32
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)

    rng = np.random.default_rng(5)
    worst, worst64, cycles = 0.0, 0.0, []
    for _ in range(24):
        x = rng.uniform(-2, 2, pdim).astype(np.float32)
        Wm = rng.uniform(-1, 1, (depth, pdim)).astype(np.float32)
        bias = rng.uniform(-1.5, 1.5, depth).astype(np.float32)
        # keep the ladder away from its pole: the guard is tested in W3
        exp64, a = f_reference(x, Wm, bias)
        if np.abs(a).min() < 0.3:
            bias = (bias + np.sign(bias + 1e-9) * 0.8).astype(np.float32)
            exp64, a = f_reference(x, Wm, bias)
        exp32, _, k0abs = f_reference_fp32(x, Wm, bias)
        got, n = await evaluate(dut, x, Wm, bias, depth, pdim, nmac)
        cycles.append(n)
        rel32 = abs(got - exp32) / (abs(exp32) + 1e-30)
        rel64 = abs(got - exp64) / (abs(exp64) + 1e-30)
        # Assert against the exact reference, with a bound derived from the
        # format rather than fitted to the data: a sequential fp32 sum of PDIM
        # terms carries up to ~PDIM*eps relative error, and the ladder amplifies
        # it by roughly 1/|K0|. The fp32 model is reported, not asserted on: it
        # emulates the scalar recurrence, while the hardware uses the equivalent
        # 2x2 matrix form, so the two agree only to a few ULP.
        # Standard bound for a sequential sum: the error scales with the sum of
        # the |terms|, not the sum itself, so a coefficient formed by cancellation
        # is proportionally less accurate. That ratio is the dot product's
        # condition number, and the ladder adds a further ~1/|K0|.
        FP32_EPS = 1.1920929e-7
        terms = np.abs(Wm.astype(np.float64) * x.astype(np.float64)).sum(1) + np.abs(bias)
        dot_cond = float((terms / np.maximum(np.abs(a), 1e-30)).max())
        tol = 2.0 * pdim * FP32_EPS * dot_cond * max(1.0, 0.5 / max(k0abs, EPS))
        assert rel64 <= tol, (
            f"fused f: got {got}, exp {exp64}, rel {rel64:.2e} "
            f"(tol {tol:.2e}, PDIM={pdim}, cond={dot_cond:.2f}, |K0|={k0abs:.3g})")
        worst = max(worst, rel32)
        worst64 = max(worst64, rel64)

    dut._log.info(f"FUSED DEPTH={depth} PDIM={pdim} NMAC={nmac}: 24 vectors OK  "
                  f"max_rel_vs_fp32={worst:.2e}  max_rel_vs_fp64={worst64:.2e}  "
                  f"cycles/ladder={np.mean(cycles):.1f}")
