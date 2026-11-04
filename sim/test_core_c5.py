"""T-C5: stage isolation by injection through the existing paths (spec 2.6)."""
import random
import cocotb
from cocotb.triggers import FallingEdge
import chip_common as cc
import fpmodel as fm


async def run_inf(dut, geo, W, x, guard_count=False):
    dut.x.value = cc.pack_x(x, W)
    await FallingEdge(dut.clock); dut.start.value = 1
    await FallingEdge(dut.clock); dut.start.value = 0
    n = 0; hits = 0
    while not int(dut.done.value):
        hits += bin(int(dut.guard_hit.value)).count("1")
        await FallingEdge(dut.clock); n += 1
        assert n < 20000
    for _ in range(5):
        hits += bin(int(dut.guard_hit.value)).count("1")
        await FallingEdge(dut.clock)
    return hits


@cocotb.test()
async def c5_injection(dut):
    W = int(dut.W.value)
    accsig = int(dut.ACCSIG.value)
    fmt = "bf16" if W == 16 else "fp32"
    cfg = cc.FORMATS[fmt]; f = cfg["f"]
    fa = fm.Fmt(8, accsig)
    geo = cc.Geo(16, 8, 2)
    rng = random.Random(55)
    await cc.start_clock(dut)
    await cc.tb_core_reset(dut, geo, W)
    nl = geo.nlad
    zero = [[[0] * geo.pdim for _ in range(geo.depth)] for _ in range(geo.width)]
    # (a) scan stage: W=0, B=a, x=0 -> a_hold == B bit-exactly (-0 becomes +0)
    a_inj = [[cc.rand_elem(rng, f, -2, 1) for _ in range(geo.depth)] for _ in range(geo.width)]
    await cc.core_load(dut, geo, W, zero, a_inj)
    x0 = [0] * geo.pdim
    await run_inf(dut, geo, W, x0)
    zm, hm, A, K0, K1 = cc.model_layer(geo, fmt, zero, a_inj, x0, accsig=accsig)
    for lane in range(geo.lanes):
        for s in range(geo.nslot):
            j = lane * nl + s
            for k in range(geo.depth):
                assert await cc.dbg_read(dut, lane, 0, s * geo.depth + k) == a_inj[j][k], "a_hold != B"
            assert await cc.dbg_read(dut, lane, 2, s) == K0[j]
            assert await cc.dbg_read(dut, lane, 3, s) == K1[j]
    assert cc.unpack_z(int(dut.z.value), geo, W) == zm
    # (b) reciprocal: a = (0,...,0,beta); K0 = beta, K1 = 1, z = 1/beta or sign/eps with a guard hit
    epsm = cfg["eps"] & ((1 << (W - 1)) - 1)
    one = f.bias << f.fr
    betas = []
    for j in range(geo.width):
        mag = [epsm - 1, epsm, epsm + 1, 0][j % 4] if j < 8 else cc.rand_elem(rng, f, -3, 3) & ((1 << (W - 1)) - 1)
        betas.append(((rng.getrandbits(1) << (W - 1)) if mag else 0) | mag)
    Bb = [[0] * (geo.depth - 1) + [betas[j]] for j in range(geo.width)]
    await cc.core_load(dut, geo, W, zero, Bb)
    hits = await run_inf(dut, geo, W, x0)
    zv = cc.unpack_z(int(dut.z.value), geo, W)
    seed = fm.load_seed(f.sig, cfg["tbits"])
    nclamp = 0
    for j in range(geo.width):
        lane, s = j // nl, j % nl
        assert await cc.dbg_read(dut, lane, 2, s) == betas[j], "K0 != beta"
        assert await cc.dbg_read(dut, lane, 3, s) == one, "K1 != 1"
        h, z = fm.recip_stage(f, betas[j], one, seed, cfg["tbits"], cfg["eps"])
        nclamp += h
        assert zv[j] == z, f"ladder {j}: z {zv[j]:x} != {z:x}"
        if not h:
            ex = fm.round_frac(f, 1 / fm.to_frac(f, betas[j]))
            assert cc.ulp_key(f, zv[j], ex) <= (2 if f.sig == 24 else 1)
    assert hits == nclamp and nclamp > 0
    # (c) coefficient stage alone: real W, x, B
    Wl, Bl = cc.rand_weights(rng, geo, f)
    x = cc.rand_x(rng, geo, f)
    await cc.core_load(dut, geo, W, Wl, Bl)
    await run_inf(dut, geo, W, x)
    for lane in range(geo.lanes):
        for s in range(geo.nslot):
            j = lane * nl + s
            for k in range(geo.depth):
                want = fm.affine(f, fa, Wl[j][k], x, Bl[j][k])
                assert await cc.dbg_read(dut, lane, 0, s * geo.depth + k) == want
                accw = cc.affine_acc(f, fa, Wl[j][k], x, Bl[j][k])
                assert await cc.dbg_read(dut, lane, 1, s * geo.depth + k) == accw & 0xFFFFFFFF
    dut._log.info(f"C5 {fmt} accsig={accsig}: scan / reciprocal / coefficient injection OK ({nclamp} guard hits)")
