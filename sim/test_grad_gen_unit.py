"""Unit test for grad_gen_unit: generalized-numerator backward (grad_a and grad_b).

Checks RTL vs the analytic closed form (tight), and the closed form vs finite
differences of the generalized forward f=(K1/K0)*b0 (formula sanity, low depth).
"""

import cocotb
from cocotb.triggers import Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01


def kgen(a, b, dt):
    """Generalized continuants K[0..DEPTH]: K[k]=a[k]K[k+1]+b[k+1]K[k+2]."""
    d = len(a)
    a = np.asarray(a, dt); b = np.asarray(b, dt)
    K = np.ones(d + 2, dt); K[d] = 1; K[d + 1] = 0; K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        if dt == np.float32:   # match RTL: t=fp32(b*K), then fused a*K+t
            t = np.float32(np.float64(b[k + 1]) * np.float64(K[k + 2]))
            K[k] = np.float32(np.float64(a[k]) * np.float64(K[k + 1]) + np.float64(t))
        else:
            K[k] = a[k] * K[k + 1] + b[k + 1] * K[k + 2]
    return K[:d + 1]


def clamp_signed(x):
    return np.copysign(max(abs(x), EPS), x if x != 0 else 1.0)


def f_gen(a, b):
    K = kgen(a, b, np.float64)
    return (K[1] / clamp_signed(K[0])) * b[0]


def grad_analytic(a, b, K_dut, G):
    """Closed form using the SAME K that is fed to the DUT (cast to fp64)."""
    d = len(a)
    K = np.asarray(K_dut, np.float64)
    b = np.asarray(b, np.float64)
    rk0 = 1.0 / clamp_signed(K[0])
    ratio = K * rk0
    pc = np.cumprod(-b)                 # pc[k] = prod_{0..k}(-b)
    pL = np.ones(d); pL[1:] = pc[:-1]   # pL[0]=1, pL[m]=pc[m-1]
    ga = np.array([ratio[k + 1] ** 2 * pc[k] * G for k in range(d)])
    gb = np.array([ratio[m] * ratio[m + 1] * pL[m] * G for m in range(d)])
    return ga, gb


def grad_fd(a, b, G, h=1e-4):
    d = len(a)
    ga = np.zeros(d); gb = np.zeros(d)
    for k in range(d):
        ap = a.astype(np.float64).copy(); ap[k] += h
        am = a.astype(np.float64).copy(); am[k] -= h
        ga[k] = G * (f_gen(ap, b) - f_gen(am, b)) / (2 * h)
        bp = b.astype(np.float64).copy(); bp[k] += h
        bm = b.astype(np.float64).copy(); bm[k] -= h
        gb[k] = G * (f_gen(a, bp) - f_gen(a, bm)) / (2 * h)
    return ga, gb


@cocotb.test()
async def grad_gen_random(dut):
    depth = len(dut.grad_a) // 32
    rng = np.random.default_rng(12)
    wr, wf = 0.0, 0.0
    n = 0
    while n < 200:
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 2.0).astype(np.float32)
        b = (1.0 + rng.uniform(-0.3, 0.3, depth)).astype(np.float32)
        Kd = kgen(a, b, np.float32)
        if abs(np.float64(Kd[0])) < 0.5:
            continue
        n += 1
        G = np.float32(rng.uniform(-2, 2))
        rk0 = np.float32(1.0 / clamp_signed(np.float64(Kd[0])))

        Kv = 0
        for i in range(depth + 1):
            Kv |= (f32_to_bits(Kd[i]) & 0xFFFFFFFF) << (32 * i)
        bb = 0
        for j in range(depth):
            bb |= (f32_to_bits(b[j]) & 0xFFFFFFFF) << (32 * j)
        dut.Kv.value = Kv
        dut.b.value = bb
        dut.rK0.value = f32_to_bits(rk0)
        dut.grad_out.value = f32_to_bits(G)
        await Timer(1, unit="ns")

        ga = np.array([bits_to_f32((int(dut.grad_a.value) >> (32 * k)) & 0xFFFFFFFF) for k in range(depth)])
        gb = np.array([bits_to_f32((int(dut.grad_b.value) >> (32 * k)) & 0xFFFFFFFF) for k in range(depth)])

        ana_a, ana_b = grad_analytic(a, b, Kd, float(G))
        for k in range(depth):
            sa = abs(ana_a[k]) + 1e-6; sb = abs(ana_b[k]) + 1e-6
            wr = max(wr, abs(ga[k] - ana_a[k]) / sa, abs(gb[k] - ana_b[k]) / sb)
            assert abs(ga[k] - ana_a[k]) / sa <= 3e-3, f"grad_a[{k}] {ga[k]} vs {ana_a[k]}"
            assert abs(gb[k] - ana_b[k]) / sb <= 3e-3, f"grad_b[{k}] {gb[k]} vs {ana_b[k]}"

        if depth <= 3:   # finite-diff formula sanity
            fd_a, fd_b = grad_fd(a, b, float(G))
            for k in range(depth):
                sa = abs(ana_a[k]) + 1e-6; sb = abs(ana_b[k]) + 1e-6
                wf = max(wf, abs(ana_a[k] - fd_a[k]) / sa, abs(ana_b[k] - fd_b[k]) / sb)
                assert abs(ana_a[k] - fd_a[k]) / sa <= 8e-3, f"grad_a[{k}] vs FD"
                assert abs(ana_b[k] - fd_b[k]) / sb <= 8e-3, f"grad_b[{k}] vs FD"
    dut._log.info(f"grad_gen_unit DEPTH={depth}: 200 cases  RTL_vs_analytic={wr:.2e}  analytic_vs_fd={wf:.2e}")
