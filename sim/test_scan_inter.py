"""ladder_scan_inter: NSLOT ladders interleaved through one pipelined FMA.

Two things to establish: the results are identical to the sequential scalar scan
(same arithmetic, same order per ladder), and the cost really is ~(DEPTH-1)
cycles per ladder rather than (DEPTH-1)*FMA_LAT.
"""
import os, json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

OUTDIR = Path(os.environ.get("WL_OUT", "."))
TAG = os.environ.get("WL_TAG", "inter")


def fma32(a, b, c):
    return np.float32(np.float64(a) * np.float64(b) + np.float64(c))


def scalar_model(a):
    """Identical to ladder_scan_scalar: two rolling registers, one FMA per step."""
    d = len(a)
    lo, hi = np.float32(a[d - 1]), np.float32(1.0)
    for k in range(d - 2, -1, -1):
        lo, hi = fma32(a[k], lo, hi), lo
    return lo, hi


@cocotb.test()
async def interleaved(dut):
    W = 32
    nslot = len(dut.k0_all) // W
    depth = (len(dut.a_all) // W) // nslot
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.a_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(53)
    batches, worst, total = 12, 0, 0
    for _ in range(batches):
        A = (rng.uniform(-3, 3, (nslot, depth)) +
             np.sign(rng.uniform(-1, 1, (nslot, depth))) * 1.2).astype(np.float32)
        packed = 0
        for s in range(nslot):
            for k in range(depth):
                packed |= (f32_to_bits(A[s, k]) & 0xFFFFFFFF) << ((s * depth + k) * W)
        # honour in_ready: the module only accepts a batch from IDLE, and it is
        # still in DONE for one cycle after the previous result
        dut.a_all.value = packed
        while True:
            await RisingEdge(dut.clock)
            await Timer(1, unit="ns")
            if dut.in_ready.value == 1:
                break
        dut.in_valid.value = 1
        await RisingEdge(dut.clock)
        dut.in_valid.value = 0
        n = 0
        while True:
            await RisingEdge(dut.clock)
            await Timer(1, unit="ns")
            n += 1
            if dut.out_valid.value == 1:
                break
            assert n < nslot * depth * 4 + 200, "no out_valid"
        total += n
        k0v, k1v = int(dut.k0_all.value), int(dut.k1_all.value)
        for s in range(nslot):
            got = (bits_to_f32((k0v >> (s * W)) & 0xFFFFFFFF),
                   bits_to_f32((k1v >> (s * W)) & 0xFFFFFFFF))
            exp = scalar_model(A[s])
            for g, e in zip(got, exp):
                u = abs(int(np.float32(g).view(np.int32)) - int(np.float32(e).view(np.int32)))
                worst = max(worst, u)

    assert worst == 0, f"differs from the sequential scan by {worst} ULP"
    cpl = total / (batches * nslot)
    res = dict(tag=TAG, nslot=nslot, depth=depth, cycles_per_batch=total / batches,
               cycles_per_ladder=cpl, ideal=depth - 1)
    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"{TAG}_inter.json").write_text(json.dumps(res, indent=2))
    dut._log.info(f"SCAN_INTER NSLOT={nslot} DEPTH={depth}: 0 ULP vs sequential scan, "
                  f"{cpl:.2f} cycles/ladder (ideal {depth-1})")
