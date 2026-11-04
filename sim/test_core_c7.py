"""T-C7 (standalone part): recip_nr_pipe accuracy and bit-exactness against the model."""
import random
from fractions import Fraction
import cocotb
from cocotb.triggers import FallingEdge, Timer
import chip_common as cc
import fpmodel as fm

N_RAND = 100_000


def ulp_dist(f, a, b):
    def key(u):
        return (u ^ ((1 << f.w) - 1)) if (u >> (f.w - 1)) else (u | (1 << (f.w - 1)))
    return abs(key(a) - key(b))


def operands(rng, f, tbits, eps, n):
    ops = []
    epsm = eps & ((1 << (f.w - 1)) - 1)
    sgn = lambda: rng.getrandbits(1) << (f.w - 1)
    # interval ends and powers of two
    step = 1 << (f.fr - tbits)
    for i in range(1 << tbits):
        for off in (0, 1, step // 2, step - 1):
            e = f.bias + rng.randint(-10, 10)
            ops.append(sgn() | (e << f.fr) | (i * step + off))
    ops += [sgn() | ((f.bias + e) << f.fr) for e in range(-20, 21)]            # powers of two
    ops += [sgn() | ((f.bias + e) << f.fr) | ((1 << f.fr) - 1) for e in range(-20, 21)]
    # guard band
    for d in (-3, -2, -1, 0, 1, 2, 3):
        ops.append(sgn() | (epsm + d)); ops.append(epsm + d)
    ops += [0, 1 << (f.w - 1)]
    while len(ops) < n:
        e = f.bias + rng.randint(-6, 60)
        ops.append(sgn() | (e << f.fr) | rng.getrandbits(f.fr))
    return ops[:max(n, len(ops))]


@cocotb.test()
async def recip_accuracy(dut):
    W = int(dut.W.value)
    nr = int(dut.NR_ITERS.value)
    tbits = int(dut.TBITS.value)
    f = fm.BF16 if W == 16 else fm.FP32
    eps = int(dut.EPSV.value)
    seed = fm.load_seed(f.sig, tbits)
    bound = {(24, 8, 2): 1, (24, 12, 1): 2}.get((f.sig, tbits, nr), None)
    rng = random.Random(1234)
    n = N_RAND if f.sig == 24 else 20000
    ops = operands(rng, f, tbits, eps, n)
    one = f.bias << f.fr
    await cc.start_clock(dut)
    dut.inValid.value = 0; dut.k0.value = 0; dut.k1.value = 0
    dut.nReset.value = 0
    await Timer(35, unit="ns"); dut.nReset.value = 1
    await FallingEdge(dut.clock)
    lat = 2 + (1 + 2 * nr) * 5
    got, hits = [], []
    # feed one per cycle; collect with fixed latency via outValid
    idx = 0
    pending = len(ops)
    cyc = 0
    while len(got) < len(ops):
        if idx < len(ops):
            dut.inValid.value = 1; dut.k0.value = ops[idx]; dut.k1.value = one
            idx += 1
        else:
            dut.inValid.value = 0
        await FallingEdge(dut.clock)
        cyc += 1
        if int(dut.outValid.value):
            got.append(int(dut.f.value))
        hits.append(int(dut.guard_hit.value))
        assert cyc < len(ops) + 200
    assert cyc - len(ops) <= lat + 2, f"latency {cyc - len(ops)} (expected about {lat})"
    mism = worst = 0
    nclamp = 0
    for k0, g in zip(ops, got):
        h, ref = fm.recip_stage(f, k0, one, seed, tbits, eps, nr)
        nclamp += h
        if g != ref:
            mism += 1
        if f.sig == 24 and not fm.is_special(f, g):
            sgn = k0 >> (f.w - 1)
            mag = k0 & ((1 << (f.w - 1)) - 1)
            b = (sgn << (f.w - 1)) | max(mag, eps & ((1 << (f.w - 1)) - 1))
            exact = fm.round_frac(f, Fraction(1) / fm.to_frac(f, b))
            worst = max(worst, ulp_dist(f, g, exact))
    assert mism == 0, f"{mism} RTL results differ from the bit-exact model"
    assert sum(hits) == nclamp, f"guard_hit pulses {sum(hits)} != clamped {nclamp}"
    if bound is not None:
        assert worst <= bound, f"max {worst} ULP > bound {bound}"
    dut._log.info(f"C7 recip sig={f.sig} tbits={tbits} nr={nr}: {len(ops)} operands, "
                  f"bit-exact vs model, max ULP vs exact = {worst}, guard hits {nclamp}")
