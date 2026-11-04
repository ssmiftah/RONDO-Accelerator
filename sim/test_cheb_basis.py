"""A Chebyshev basis on kscan_inter: every degree, not just the final pair.

A Chebyshev KAN weights the whole basis, y_j = sum_{i,n} c_{jin} T_n(x_i), so an
evaluator has to emit T_0..T_d rather than the last two degrees. kscan_inter
already retains the full array -- it was built that way for the backward pass,
which needs every continuant -- so the same module with NUMER_NEG=1 is a
Chebyshev basis evaluator at no extra arithmetic.

This checks all NSLOT*(DEPTH+1) retained values against the recurrence, so a
wrong value in the middle of the array cannot pass.
"""
import os
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

W = 32


def to_bits(x):
    return int(np.float32(x).view(np.uint32))


def from_bits(b):
    return float(np.uint32(b & 0xFFFFFFFF).view(np.float32))


@cocotb.test()
async def cheb_basis(dut):
    depth = int(dut.DEPTH.value)
    nslot = int(dut.NSLOT.value)

    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    dut.nReset.value = 0
    dut.in_valid.value = 0
    dut.a_all.value = 0
    for _ in range(5):
        await RisingEdge(dut.clock)
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    xs = np.linspace(-0.95, 0.95, nslot).astype(np.float32)
    # a[k] = 2x for every level; the seed a[DEPTH-1] = x selects the first kind
    a = 0
    for s in range(nslot):
        for k in range(depth):
            v = np.float32(xs[s]) if k == depth - 1 else np.float32(2 * xs[s])
            a |= to_bits(v) << ((s * depth + k) * W)
    dut.a_all.value = a

    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0

    cycles = 0
    while dut.out_valid.value != 1:
        await RisingEdge(dut.clock)
        cycles += 1
        assert cycles < 10000, "scan did not complete"

    Kv = int(dut.Kv_all.value)
    worst, checked = 0.0, 0
    for s in range(nslot):
        x = float(xs[s])
        T = [1.0, x]
        while len(T) <= depth:
            T.append(2 * x * T[-1] - T[-2])
        # Karr[s][DEPTH] is the seed 1.0, and index k holds the value produced
        # at step k, running downward, so index (DEPTH-j) holds degree j.
        for j in range(depth + 1):
            idx = s * (depth + 1) + (depth - j)
            got = from_bits(Kv >> (idx * W))
            ref = T[j]
            rel = abs(got - ref) / (abs(ref) + 1e-30)
            worst = max(worst, rel)
            checked += 1

    dut._log.info(f"CHEBBASIS depth={depth} slots={nslot} cycles={cycles} "
                  f"values={checked} max_rel={worst:.3e}")
    assert worst < 1e-5, f"basis mismatch, max_rel {worst:.3e}"
