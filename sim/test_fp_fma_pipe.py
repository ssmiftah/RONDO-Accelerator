"""fp_fma_pipe must be bit-identical to fp_fma, just later and pipelined.

Streams operands one per cycle and checks II=1 is actually sustained, because a
pipelined FMA that cannot accept every cycle would not solve the problem it
exists to solve.
"""
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32


def fma32(a, b, c):
    """Single-rounded: the fp64 product of two fp32 values is exact."""
    return np.float32(np.float64(a) * np.float64(b) + np.float64(c))


@cocotb.test()
async def pipe_matches_combinational(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.a.value = dut.b.value = dut.c.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(41)
    N = 600
    A = rng.uniform(-40, 40, N).astype(np.float32)
    B = rng.uniform(-40, 40, N).astype(np.float32)
    C = rng.uniform(-1e3, 1e3, N).astype(np.float32)
    # include the awkward magnitudes the ladder actually produces
    A[:20] = np.float32([0.0, 1.0, -1.0, 1e-30, 1e30, 0.01, -0.01, 2.0, -2.0, 1e-8,
                         3.4e38, -3.4e38, 1.5, -1.5, 7.0, -7.0, 1e-20, 1e20, 0.5, -0.5])

    got, sent, recvd, cycles, first = [], 0, 0, 0, None
    while recvd < N:
        if sent < N:
            dut.a.value = f32_to_bits(A[sent]); dut.b.value = f32_to_bits(B[sent])
            dut.c.value = f32_to_bits(C[sent]); dut.in_valid.value = 1
        else:
            dut.in_valid.value = 0
        await RisingEdge(dut.clock)
        await Timer(1, unit="ns")
        if sent < N:
            if first is None:
                first = cycles
            sent += 1
        if dut.out_valid.value == 1:
            got.append(bits_to_f32(int(dut.p.value)))
            recvd += 1
        cycles += 1
        assert cycles < N + 200, f"stalled at {recvd}/{N}"
    dut.in_valid.value = 0

    got = np.array(got, dtype=np.float32)
    exp = np.array([fma32(A[i], B[i], C[i]) for i in range(N)], dtype=np.float32)
    ulp = np.abs(got.view(np.int32) - exp.view(np.int32))
    assert ulp.max() == 0, f"{int((ulp>0).sum())}/{N} differ, max {ulp.max()} ULP"

    issued = cycles - first
    assert issued <= N + 12, f"II is not 1: {issued} cycles for {N} operands"
    dut._log.info(f"FMA_PIPE: {N} operands, 0 ULP vs fp32 FMA model, "
                  f"{issued} cycles for {N} = II {issued/N:.3f}")
