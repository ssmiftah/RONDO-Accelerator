"""Verify the on-board power harness computes the right thing before it is
programmed onto hardware.

The harness free-runs from on-chip ROM with no host, so on the board there is no
way to see what it produced except the LED checksum. This test establishes what
that checksum must be: it replays the same rotation in Python against the fp64
reference and compares. A mismatch on hardware then means the board or the
constraints, not the design.
"""
import os
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01
NBATCH = int(os.environ.get("WL_NBATCH", "7"))   # odd: a cancelling checksum would hide a bug


def f_ref(a):
    d = len(a)
    K = np.ones(d + 2)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS)


@cocotb.test()
async def power_top(dut):
    width = len(dut.z) // 32 if hasattr(dut, "z") else 48
    width = int(dut.WIDTH.value) if hasattr(dut, "WIDTH") else width
    depth = int(dut.DEPTH.value) if hasattr(dut, "DEPTH") else 7

    stim = [int(x, 16) for x in
            Path(os.environ["WL_STIM"]).read_text().split()][:width * depth]
    A = np.array([bits_to_f32(w) for w in stim], dtype=np.float32).reshape(width, depth)

    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.run.value = 0
    dut.nReset.value = 0
    await Timer(35, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)
    dut.run.value = 1

    # Two separate jobs here, and conflating them is what made the first version
    # of this test wrong. (1) Is the arithmetic right? Check each output against
    # the fp64 reference with the usual tolerance -- the NR reciprocal is ~2 ULP,
    # so it is not bit-exact and never will be. (2) What will the LEDs read on the
    # board? That must come from the RTL's own bits, because the checksum is an
    # exact XOR of exactly what the hardware produces.
    exp_cs, flat, seen, guard, worst = 0, A.reshape(-1).copy(), 0, 0, 0.0
    while seen < NBATCH:
        await RisingEdge(dut.clock)
        guard += 1
        assert guard < 200000, "harness never completed a batch"
        if dut.u_coproc.done.value != 1:
            continue
        zbits = int(dut.z.value)
        cur = flat.reshape(width, depth)
        fold = 0
        for j in range(width):
            w = (zbits >> (j * 32)) & 0xFFFFFFFF
            fold ^= w
            got = bits_to_f32(w)
            exp = f_ref(cur[j].astype(np.float64))
            worst = max(worst, abs(got - exp) / (abs(exp) + 1e-30))
        exp_cs ^= fold
        flat = np.roll(flat, 1)    # RTL shifts words up: new[i] = old[i-1]
        seen += 1
    await RisingEdge(dut.clock)

    got_cs = int(dut.checksum.value)
    dut._log.info(f"POWER_TOP {NBATCH} batches: checksum={got_cs:08x} "
                  f"folded={exp_cs:08x} max_rel={worst:.2e}")
    assert worst < 1e-3, f"arithmetic wrong: max_rel {worst:.2e}"
    assert got_cs == exp_cs, f"checksum accumulator {got_cs:08x} != folded {exp_cs:08x}"

    Path(os.environ.get("WL_OUT", ".")).mkdir(parents=True, exist_ok=True)
    (Path(os.environ.get("WL_OUT", ".")) / "power_top_golden.json").write_text(
        f'{{"batches": {NBATCH}, "checksum": "{got_cs:08x}", '
        f'"led_pattern": "{got_cs & 0xFF:08b}", "max_rel": {worst:.3e}}}\n')
    dut._log.info(f"LED pattern on hardware should read {got_cs & 0xFF:08b}")
