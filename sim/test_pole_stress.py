"""W3: pole-guard stress. Walks K0 toward zero and checks the clamp holds.

For a random tail a1..a_{d-1} we can place K0 exactly: K0 = a0*K1 + K2, so
choosing a0 = (delta - K2)/K1 gives K0 = delta. Sweeping delta across decades
walks the ladder right up to its pole, which random inputs essentially never do.
"""
import os, json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

EPS = float(os.environ.get("WL_EPS", "0.01"))
TAG = os.environ.get("WL_TAG", "pole")
OUTDIR = Path(os.environ["WL_OUT"])


def k12(a):
    d = len(a)
    K = np.ones(d + 2, dtype=np.float64)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return K[0], K[1]


async def reset(dut):
    dut.start.value = 0; dut.a_all.value = 0; dut.b_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def one(dut, A):
    w, d = A.shape
    v = 0
    for j in range(w):
        for k in range(d):
            v |= (f32_to_bits(A[j, k]) & 0xFFFFFFFF) << ((j * d + k) * 32)
    dut.a_all.value = v; dut.b_all.value = 0
    dut.start.value = 1
    await RisingEdge(dut.clock)
    dut.start.value = 0
    for _ in range(w * (d + 60) + 80):
        await RisingEdge(dut.clock)
        if dut.done.value == 1:
            z = int(dut.z.value)
            return np.array([bits_to_f32((z >> (j * 32)) & 0xFFFFFFFF) for j in range(w)])
    raise TimeoutError("no done")


@cocotb.test()
async def pole_walk(dut):
    W = len(dut.z) // 32
    d = (len(dut.a_all) // 32) // W
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(11)

    deltas = np.array([10.0 ** e for e in range(0, -13, -1)])
    rows = []
    for delta in deltas:
        A = np.zeros((W, d), dtype=np.float32)
        want = np.zeros(W)
        for j in range(W):
            tail = rng.uniform(-2.5, 2.5, d).astype(np.float64)
            tail[np.abs(tail) < 0.3] = 0.7
            k0t, k1t = k12(np.concatenate(([0.0], tail[1:])))   # K0 with a0 = 0 => K2
            K2, K1 = k0t, k1t
            a0 = (delta - K2) / K1 if K1 != 0 else 0.0
            tail[0] = a0
            A[j] = tail.astype(np.float32)
            k0, k1 = k12(A[j].astype(np.float64))
            want[j] = np.sign(k1) * np.sign(k0) * abs(k1) / max(abs(k0), EPS)
        z = await one(dut, A)
        finite = bool(np.isfinite(z).all())
        rel = np.abs(z - want) / (np.abs(want) + 1e-30)
        rows.append(dict(delta=float(delta), finite=finite,
                         max_abs_z=float(np.abs(z).max()),
                         clamp_ceiling=float(1.0 / EPS),
                         max_rel=float(rel.max())))
        assert finite, f"non-finite output at delta={delta:g}"

    res = dict(tag=TAG, eps=EPS, depth=int(d), lanes_per_batch=int(W), sweep=rows,
               all_finite=all(r["finite"] for r in rows),
               worst_rel=max(r["max_rel"] for r in rows))
    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"{TAG}_pole.json").write_text(json.dumps(res, indent=2))
    dut._log.info("POLE " + json.dumps({k: v for k, v in res.items() if k != "sweep"}))
