"""kscan_inter: the full continuant array via NSLOT interleaved ladders.

Checks the thing that distinguishes this module from ladder_scan_inter, namely
that every K[0..DEPTH] survives the scan and not just the final pair, and checks
it for every slot at once so a slot-indexing error cannot hide behind slot 0.

The reference is k_full from test_grad_a_unit, the same one kscan.v is checked
against, so a pass here means the interleaved scan agrees with the sequential one
rather than merely with itself.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32, ulp_diff
from test_grad_a_unit import k_full

DEPTH = int(os.environ.get("WL_DEPTH", "7"))
NSLOT = int(os.environ.get("WL_NSLOT", "8"))


async def reset(dut):
    dut.in_valid.value = 0
    dut.a_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def run_batch(dut, A):
    """A is (NSLOT, DEPTH). Returns (NSLOT, DEPTH+1) of K arrays."""
    packed = 0
    for s in range(NSLOT):
        for k in range(DEPTH):
            packed |= (f32_to_bits(A[s][k]) & 0xFFFFFFFF) << (32 * (s * DEPTH + k))
    while dut.in_ready.value != 1:
        await RisingEdge(dut.clock)
    dut.a_all.value = packed
    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0

    for _ in range(DEPTH * NSLOT + 8 * NSLOT + 64):
        await RisingEdge(dut.clock)
        if dut.out_valid.value == 1:
            break
    else:
        raise AssertionError("kscan_inter never raised out_valid")

    raw = int(dut.Kv_all.value)
    out = np.zeros((NSLOT, DEPTH + 1), np.float32)
    for s in range(NSLOT):
        for i in range(DEPTH + 1):
            w = (raw >> (32 * (s * (DEPTH + 1) + i))) & 0xFFFFFFFF
            out[s][i] = bits_to_f32(w)
    return out


@cocotb.test()
async def test_full_array_all_slots(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)

    rng = np.random.default_rng(20260908)
    # Every slot gets DIFFERENT coefficients: identical ones would pass even if
    # the writeback wrote every result to the same slot.
    for trial in range(4):
        A = rng.uniform(-2.0, 2.0, size=(NSLOT, DEPTH)).astype(np.float32)
        got = await run_batch(dut, A)
        for s in range(NSLOT):
            exp = k_full(A[s], np.float32)[: DEPTH + 1]
            for i in range(DEPTH + 1):
                d = ulp_diff(got[s][i], exp[i])
                assert d <= 1, (
                    f"trial {trial} slot {s} K[{i}]: got {got[s][i]!r} "
                    f"expected {exp[i]!r} ({d} ULP)"
                )


@cocotb.test()
async def test_boundary_values(dut):
    """K[DEPTH]=1 and K[DEPTH-1]=a[DEPTH-1] must hold without any arithmetic."""
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(7)
    A = rng.uniform(-2.0, 2.0, size=(NSLOT, DEPTH)).astype(np.float32)
    got = await run_batch(dut, A)
    for s in range(NSLOT):
        assert got[s][DEPTH] == np.float32(1.0), f"slot {s}: K[DEPTH] != 1"
        assert got[s][DEPTH - 1] == A[s][DEPTH - 1], f"slot {s}: K[DEPTH-1] wrong"
