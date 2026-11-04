"""The continuant scan, run as a Chebyshev basis evaluator.

The paper's datapath is motivated by continued fractions, but what the scan
hardware actually computes is a second-order linear recurrence with
data-dependent coefficients. Setting the addend's sign to negative and driving
every coefficient to 2x turns it into the Chebyshev recurrence

    T_{n+1} = 2x T_n - T_{n-1}        seeded from a[DEPTH-1] = x
    U_{n+1} = 2x U_n - U_{n-1}        seeded from a[DEPTH-1] = 2x

which is the basis a Chebyshev KAN evaluates. This test drives the unmodified
ladder_scan_inter with NUMER_NEG=1 and checks its outputs against numpy's
Chebyshev polynomials, so the claim rests on the RTL rather than on algebra.
"""
import os
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

W, EXP, SIG = 32, 8, 24


def to_bits(x):
    return int(np.float32(x).view(np.uint32))


def from_bits(b):
    return float(np.uint32(b & 0xFFFFFFFF).view(np.float32))


@cocotb.test()
async def chebyshev(dut):
    depth = int(dut.DEPTH.value)
    nslot = int(dut.NSLOT.value)
    kind = os.environ.get("WL_CHEB", "T")

    cocotb.start_soon(Clock(dut.clock, 10, units="ns").start())
    dut.nReset.value = 0
    for sig in ("in_valid", "a_all"):
        getattr(dut, sig).value = 0
    for _ in range(5):
        await RisingEdge(dut.clock)
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    # One x per slot. a[k] = 2x for every k, except a[DEPTH-1], which seeds the
    # recurrence: 2x gives U_n, x gives T_n.
    xs = np.linspace(-0.9, 0.9, nslot).astype(np.float32)
    a = 0
    for s in range(nslot):
        for k in range(depth):
            seed = (k == depth - 1)
            val = np.float32(xs[s]) if (seed and kind == "T") else np.float32(2 * xs[s])
            a |= to_bits(val) << ((s * depth + k) * W)
    dut.a_all.value = a

    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0

    guard = 0
    while dut.out_valid.value != 1:
        await RisingEdge(dut.clock)
        guard += 1
        assert guard < 10000, "scan did not complete"

    # After DEPTH-1 steps the pair (lo, hi) holds consecutive degrees.
    k0 = int(dut.k0_all.value)
    k1 = int(dut.k1_all.value)

    worst = 0.0
    for s in range(nslot):
        x = float(xs[s])
        got_lo = from_bits(k0 >> (s * W))
        got_hi = from_bits(k1 >> (s * W))
        # The scan runs DEPTH-1 steps from the seed (lo = degree 1, hi = degree 0),
        # so it ends on degree DEPTH in lo and DEPTH-1 in hi. Build the sequence
        # directly rather than indexing a library and getting the offset wrong.
        seq = [1.0, x if kind == "T" else 2 * x]
        while len(seq) <= depth:
            seq.append(2 * x * seq[-1] - seq[-2])
        ref_lo, ref_hi = seq[depth], seq[depth - 1]
        for got, ref, name in ((got_lo, ref_lo, "lo"), (got_hi, ref_hi, "hi")):
            rel = abs(got - ref) / (abs(ref) + 1e-30)
            worst = max(worst, rel)
            dut._log.info(f"  x={x:+.4f} {name}: rtl={got:+.8f} ref={ref:+.8f} rel={rel:.2e}")

    dut._log.info(f"CHEBYSHEV kind={kind} depth={depth} slots={nslot} max_rel={worst:.3e}")
    assert worst < 1e-5, f"Chebyshev mismatch, max_rel {worst:.3e}"
