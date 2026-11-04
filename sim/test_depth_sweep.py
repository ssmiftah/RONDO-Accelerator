"""W4: depth scaling. One ladder, DEPTH from the build; measures the folded
scan's cycle cost and the error growth against the fp64 reference.

Matters because the original CoFrNets paper sweeps CoFrNet-D depth to 250,
while the accelerator is characterised at d=7.
"""
import os, json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01
OUTDIR = Path(os.environ["WL_OUT"])
TAG = os.environ.get("WL_TAG", "depth")


def f_ref(a):
    d = len(a)
    K = np.ones(d + 2, dtype=np.float64)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return (np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS),
            abs(K[0]), max(abs(K[0]), abs(K[1])))


@cocotb.test()
async def depth_scan(dut):
    W = len(dut.z) // 32
    d = (len(dut.a_all) // 32) // W
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.start.value = 0; dut.a_all.value = 0; dut.b_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(23)
    rels, cyc, guard_hits, kmax = [], [], 0, 0.0
    for _ in range(24):
        a = rng.uniform(-2.5, 2.5, d)
        a[np.abs(a) < 0.4] = 0.9
        A = a.astype(np.float32)
        v = 0
        for k in range(d):
            v |= (f32_to_bits(A[k]) & 0xFFFFFFFF) << (k * 32)
        dut.a_all.value = v
        dut.start.value = 1
        await RisingEdge(dut.clock)
        dut.start.value = 0
        n = 0
        while True:
            await RisingEdge(dut.clock)
            n += 1
            if dut.done.value == 1:
                break
            if n > d * 200 + 500:
                raise TimeoutError(f"no done at depth {d}")
        z = bits_to_f32(int(dut.z.value) & 0xFFFFFFFF)
        exp, k0abs, kbig = f_ref(A.astype(np.float64))
        guard_hits += int(k0abs < EPS)
        kmax = max(kmax, kbig)
        rels.append(abs(z - exp) / (abs(exp) + 1e-30))
        cyc.append(n)

    res = dict(tag=TAG, depth=int(d), trials=len(rels),
               cycles_per_ladder=float(np.mean(cyc)),
               cycles_min=int(min(cyc)), cycles_max=int(max(cyc)),
               max_rel=float(np.max(rels)), median_rel=float(np.median(rels)),
               guard_trips=int(guard_hits), max_continuant=float(kmax))
    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"{TAG}_depth{d}.json").write_text(json.dumps(res, indent=2))
    dut._log.info("DEPTH " + json.dumps(res))
    assert np.isfinite(res["max_rel"]), "non-finite error"
