"""Unit test for grad_a_unit: closed-form ladder gradient df/da.

Two independent checks:
  * RTL vs the analytic formula (fp64)  -> validates the RTL (relative tol).
  * analytic formula vs finite differences of f (fp64) -> validates the FORMULA
    (and its sign convention) independently of the RTL.
Well-conditioned denominators (|K0| >> eps) keep f smooth so finite differences
are reliable and the pole clamp is inactive.
"""

import cocotb
from cocotb.triggers import Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01


def k_full(a, dt):
    """K[0..DEPTH] via the recurrence (K[d]=1, K[d+1]=0), in dtype dt.

    For fp32, the recurrence step uses a *fused* multiply-add (fp64 intermediate,
    single round to fp32) to match the RTL's HardFloat FMA -- a plain
    a*b + c in fp32 would round twice and drift ~1 ULP under cancellation.
    """
    d = len(a)
    a = np.asarray(a, dt)
    K = np.ones(d + 2, dt)
    K[d] = 1; K[d + 1] = 0; K[d - 1] = a[d - 1]
    fused = (dt == np.float32)
    for k in range(d - 2, -1, -1):
        if fused:
            K[k] = np.float32(np.float64(a[k]) * np.float64(K[k + 1]) + np.float64(K[k + 2]))
        else:
            K[k] = a[k] * K[k + 1] + K[k + 2]
    return K[:d + 1]


def clamp_signed(x):
    return np.copysign(max(abs(x), EPS), x if x != 0 else 1.0)


def f_forward(a):
    K = k_full(a, np.float64)
    return K[1] / clamp_signed(K[0])


def grad_analytic(a, grad_out):
    K = k_full(a, np.float64)
    rk0 = 1.0 / clamp_signed(K[0])
    g = np.zeros(len(a))
    for k in range(len(a)):
        ratio = K[k + 1] * rk0
        s = -1.0 if k % 2 == 0 else 1.0
        g[k] = grad_out * s * ratio ** 2
    return g


def grad_fd(a, grad_out, h=1e-4):
    g = np.zeros(len(a))
    for k in range(len(a)):
        ap = a.astype(np.float64).copy(); ap[k] += h
        am = a.astype(np.float64).copy(); am[k] -= h
        g[k] = grad_out * (f_forward(ap) - f_forward(am)) / (2 * h)
    return g


@cocotb.test()
async def grad_a_random(dut):
    depth = len(dut.grad_a) // 32
    rng = np.random.default_rng(8)
    worst_rtl, worst_fd = 0.0, 0.0
    n = 0
    while n < 200:
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 2.0).astype(np.float32)
        # Keep away from the pole (|K0| >> eps): there the clamp saturates and the
        # analytic formula (which the reference also uses) diverges from the true
        # gradient. This test validates the un-clamped closed form.
        K64 = k_full(a, np.float64)
        if abs(K64[0]) < 0.5:
            continue
        n += 1
        grad_out = np.float32(rng.uniform(-2, 2))

        K = k_full(a, np.float32)                       # fp32 continuants
        rk0 = np.float32(1.0 / clamp_signed(np.float64(K[0])))

        Kv = 0
        for i in range(depth + 1):
            Kv |= (f32_to_bits(K[i]) & 0xFFFFFFFF) << (32 * i)
        dut.Kv.value = Kv
        dut.rK0.value = f32_to_bits(rk0)
        dut.grad_out.value = f32_to_bits(grad_out)
        await Timer(1, unit="ns")

        got = np.array([bits_to_f32((int(dut.grad_a.value) >> (32 * k)) & 0xFFFFFFFF)
                        for k in range(depth)])

        ana = grad_analytic(a, float(grad_out))
        for k in range(depth):
            scale = abs(ana[k]) + 1e-6
            worst_rtl = max(worst_rtl, abs(got[k] - ana[k]) / scale)
            # RTL must reproduce the analytic closed form (the spec) at all depths.
            assert abs(got[k] - ana[k]) / scale <= 2e-3, \
                f"RTL vs analytic k={k}: got {got[k]}, ana {ana[k]}, a={a}"

        # Formula sanity vs finite differences -- reliable only at low depth
        # (FD truncation grows with gradient magnitude / higher derivatives).
        if depth <= 3:
            fd = grad_fd(a, float(grad_out))
            for k in range(depth):
                scale = abs(ana[k]) + 1e-6
                worst_fd = max(worst_fd, abs(ana[k] - fd[k]) / scale)
                assert abs(ana[k] - fd[k]) / scale <= 5e-3, \
                    f"analytic vs finite-diff k={k}: ana {ana[k]}, fd {fd[k]}, a={a}"
    dut._log.info(f"grad_a_unit DEPTH={depth}: 200 cases  RTL_vs_analytic={worst_rtl:.2e}  "
                  f"analytic_vs_fd={worst_fd:.2e}")
