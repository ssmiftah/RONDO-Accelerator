"""affine_bank_pipe: NPAR parallel pipelined FMAs, never chained.

Two things must hold:
  - results bit-identical to the sequential accumulation order (0 ULP), at every
    NPAR, because the per-coefficient order is unchanged
  - cycles ~ NGROUP*PDIM, i.e. NPAR actually buys throughput
"""
import os, json
from pathlib import Path
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_common import f32_to_bits, bits_to_f32

DEPTH  = int(os.environ.get("WL_DEPTH", "7"))
PDIM   = int(os.environ.get("WL_PDIM", "40"))
NBATCH = int(os.environ.get("WL_NBATCH", "8"))
NLAD   = int(os.environ.get("WL_NLAD", "8"))
NPAR   = int(os.environ.get("WL_NPAR", "8"))
NCH    = NBATCH * DEPTH
NGROUP = NCH // NPAR
NBATCHES = NLAD // NBATCH


def model(Wt, x, Bt, j, k):
    """Sequential over c, exactly as the hardware accumulates."""
    acc = np.float32(Bt[j, k])
    for c in range(PDIM):
        acc = np.float32(np.float64(Wt[j, k, c]) * np.float64(x[c]) + np.float64(acc))
    return acc


@cocotb.test()
async def pipe(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    for sig in ("w_we", "b_we", "in_valid", "w_addr", "w_din", "b_addr", "b_din",
                "x", "bsel"):
        getattr(dut, sig).value = 0
    dut.nReset.value = 0
    await Timer(35, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(3)
    Wt = rng.uniform(-1, 1, (NLAD, DEPTH, PDIM)).astype(np.float32)
    Bt = rng.uniform(-1, 1, (NLAD, DEPTH)).astype(np.float32)

    # chain ch = j*DEPTH + k within a batch; group g holds chains g*NPAR..+NPAR-1
    for b in range(NBATCHES):
        for g in range(NGROUP):
            for c in range(PDIM):
                word = 0
                for f in range(NPAR):
                    ch = g * NPAR + f
                    j, k = ch // DEPTH, ch % DEPTH
                    word |= (f32_to_bits(Wt[b * NBATCH + j, k, c]) & 0xFFFFFFFF) << (f * 32)
                dut.w_addr.value = (b * NGROUP + g) * PDIM + c
                dut.w_din.value = word
                dut.w_we.value = 1
                await RisingEdge(dut.clock)
            dut.w_we.value = 0
            word = 0
            for f in range(NPAR):
                ch = g * NPAR + f
                j, k = ch // DEPTH, ch % DEPTH
                word |= (f32_to_bits(Bt[b * NBATCH + j, k]) & 0xFFFFFFFF) << (f * 32)
            dut.b_addr.value = b * NGROUP + g
            dut.b_din.value = word
            dut.b_we.value = 1
            await RisingEdge(dut.clock)
            dut.b_we.value = 0
    await RisingEdge(dut.clock)

    worst_ulp, cycles = 0, 0
    for b in range(NBATCHES):
        x = rng.uniform(-2, 2, PDIM).astype(np.float32)
        xv = 0
        for i in range(PDIM):
            xv |= (f32_to_bits(x[i]) & 0xFFFFFFFF) << (i * 32)
        while dut.in_ready.value != 1:
            await RisingEdge(dut.clock)
        dut.x.value = xv
        dut.bsel.value = b
        dut.in_valid.value = 1
        await RisingEdge(dut.clock)
        dut.in_valid.value = 0
        n = 0
        while dut.out_valid.value != 1:
            await RisingEdge(dut.clock)
            n += 1
            assert n < 200000, "affine_bank_pipe hung"
        cycles += n
        av = int(dut.a.value)
        for ch in range(NCH):
            j, k = ch // DEPTH, ch % DEPTH
            got = bits_to_f32((av >> (ch * 32)) & 0xFFFFFFFF)
            exp = model(Wt, x, Bt, b * NBATCH + j, k)
            worst_ulp = max(worst_ulp,
                            abs(int(f32_to_bits(got)) - int(f32_to_bits(exp))))

    cpl = cycles / (NBATCHES * NBATCH)
    dut._log.info(f"AFFINE_PIPE NPAR={NPAR} NGROUP={NGROUP} PDIM={PDIM}: "
                  f"{cpl:.1f} cycles/ladder, max {worst_ulp} ULP")
    out = Path(os.environ.get("WL_OUT", "."))
    out.mkdir(parents=True, exist_ok=True)
    (out / f"affine_pipe_npar{NPAR}_p{PDIM}.json").write_text(json.dumps(
        dict(npar=NPAR, ngroup=NGROUP, pdim=PDIM, depth=DEPTH,
             cycles_per_ladder=cpl, max_ulp=worst_ulp), indent=2))
    assert worst_ulp == 0, f"differs by {worst_ulp} ULP"
