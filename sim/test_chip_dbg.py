"""T-DBG: DBG_SEL/DBG_DATA taps vs the model and the fault localization flow of spec 9.10."""
import random
import cocotb
from chip_tb import ChipTB, R, A
import chip_common as cc
import fpmodel as fm

GEO = cc.Geo(16, 8, 2)


def sel(lane, sig, idx, live=0, ovr=None):
    v = lane | (sig << 4) | (idx << 8) | (live << 16)
    if ovr is not None:
        v |= (1 << 24) | (ovr << 25)
    return v


async def tap(t, lane, sig, idx):
    await t.wr("DBG_SEL", sel(lane, sig, idx))
    await t.rd("CHIP_ID"); await t.rd("CHIP_ID")          # DBG_DATA is latched 4 cycles after the write
    return await t.rd("DBG_DATA")


@cocotb.test()
async def taps_vs_model(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = random.Random(31)
    for fmt in ("bf16", "fp32"):
        await t.set_format(fmt)
        w = 16 if fmt == "bf16" else 32
        f = cc.FORMATS[fmt]["f"]
        Wl, Bl = cc.rand_weights(rng, GEO, f)
        await t.load_weights(fmt, Wl, Bl)
        x = cc.rand_x(rng, GEO, f)
        await t.write_x(0, x)
        z = await t.infer(0)
        if fmt == "bf16":
            zm, hm, A_, K0, K1 = cc.model_layer(GEO, "bf16", Wl, Bl, x)
        else:
            zm, hm, A_, K0, K1 = cc.model_layer(GEO, "fp32", Wl, Bl, x, nr_iters=2, tbits=8, seed=fm.load_seed(24, 8))
        nl = GEO.nlad
        for lane in range(GEO.lanes):
            for s in range(GEO.nslot):
                j = lane * nl + s
                for k in range(GEO.depth):
                    assert await tap(t, lane, 0, s * GEO.depth + k) == A_[j][k], (fmt, "sig0", lane, s, k)
                assert await tap(t, lane, 2, s) == K0[j] and await tap(t, lane, 3, s) == K1[j]
                assert await tap(t, lane, 4, s) == zm[j]
            assert await tap(t, lane, 5, 0) == (GEO.nbatches * GEO.nslot) << 4
            assert await tap(t, lane, 6, 0) == 0
        # fmt override observes the other (frozen/reset) layer without disturbing the active one
        await t.wr("DBG_SEL", sel(0, 4, 0, ovr=0 if fmt == "fp32" else 1))
        await t.rd("CHIP_ID"); await t.rd("CHIP_ID")
        _ = await t.rd("DBG_DATA")
        assert [v for v in await t.read_z()] == z
    dut._log.info("T-DBG taps: all signals/lanes match the model in both formats")


@cocotb.test()
async def localization_flow(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = random.Random(32)
    f = cc.FORMATS["bf16"]["f"]
    Wl, Bl = cc.rand_weights(rng, GEO, f)
    await t.load_weights("bf16", Wl, Bl)
    x = cc.rand_x(rng, GEO, f)
    await t.write_x(0, x)
    zgood = t.model_z("bf16", Wl, Bl, x)
    assert [v & 0xFFFF for v in await t.infer(0)] == zgood
    # fault: stuck-at-1 on a bit of one field in lane 1's weight H macro, address 10
    bad_lane, bad_addr, bad_field, bad_bit = 1, 10, 2, 14
    mem = getattr(dut.u_dev.u_mem, f"lane[{bad_lane}]")
    mem.u_wh.f_addr.value = bad_addr
    mem.u_wh.f_sa1.value = 1 << (bad_field * 16 + bad_bit)
    mem.u_wh.f_en.value = 1
    z = [v & 0xFFFF for v in await t.infer(0)]
    wrong = [j for j in range(GEO.width) if z[j] != zgood[j]]
    assert wrong, "the injected fault must change the output"
    assert all(j // GEO.nlad == bad_lane for j in wrong), "only lane 1 ladders affected"
    # 1. read back the weights and compare: memory fault localized to lane / address / field
    ww, bw = cc.core_pack(GEO, Wl, Bl)
    found = []
    for l in range(GEO.lanes):
        got = await t.rb.read_burst(t.g.weight_word_addr(l, 0, 0), GEO.nwords * 8)
        exp = [e for w in ww[l] for e in w]
        found += [(l, i // 8, i % 8) for i, (a, b) in enumerate(zip(got, exp)) if a != b]
    assert found == [(bad_lane, bad_addr, bad_field)], found
    # 1b. MBIST (MBIST=1 build) confirms the memory fault: lane, address, weight store, H half
    t.poll_gap = 30
    await t.ctrl("MBIST_START")
    await t.wait_idle(timeout=800000)
    t.poll_gap = 0
    mst = await t.rd("MBIST_STATUS")
    assert (mst >> 2) & 1 and (mst >> 4) & 7 == bad_lane and not (mst >> 8) & 1 and not (mst >> 7) & 1
    assert await t.rd("MBIST_FAIL_ADDR") == bad_addr
    # the march overwrote the weights: reload them (fault still present) for the coefficient-stage check
    await t.load_weights("bf16", Wl, Bl)
    await t.write_x(0, x)
    await t.infer(0)
    # 2. coefficient stage: DBG taps vs sum(W*x)+b show which chains are wrong
    fa = fm.Fmt(8, 8)
    bad_chains = []
    for lane in range(GEO.lanes):
        for s in range(GEO.nslot):
            j = lane * GEO.nlad + s
            for k in range(GEO.depth):
                want = fm.affine(f, fa, Wl[j][k], x, Bl[j][k])
                if await tap(t, lane, 0, s * GEO.depth + k) != want:
                    bad_chains.append((lane, s, k))
    assert bad_chains and all(l == bad_lane for l, _, _ in bad_chains)
    # 3./4. scan and reciprocal injection on the faulty lane still behave (the fault is in the weights only)
    zero = [[[0] * GEO.pdim for _ in range(GEO.depth)] for _ in range(GEO.width)]
    mem.u_wh.f_en.value = 0
    betas = [0x3F80, 0x4000, 0x0010, 0xBF80] * 4
    Bb = [[0] * 6 + [betas[j]] for j in range(GEO.width)]
    await t.load_weights("bf16", zero, Bb)
    await t.write_x(0, [0] * GEO.pdim)
    await t.ctrl("GUARD_CLR")
    zz = await t.infer(0)
    nclamp = sum(1 for b in betas if (b & 0x7FFF) < 0x3C24)
    assert await t.rd("GUARD_HITS") == nclamp
    for j in range(GEO.width):
        assert await tap(t, j // GEO.nlad, 2, j % GEO.nlad) == betas[j]
    # 6. work-around: disable lane 1, its outputs read quiet NaN
    await t.load_weights("bf16", Wl, Bl)
    await t.write_x(0, x)
    await t.wr("LANE_EN", 1)
    z = [v & 0xFFFF for v in await t.infer(0)]
    assert z[:GEO.nlad] == zgood[:GEO.nlad] and all(v == 0x7FC0 for v in z[GEO.nlad:])
    await t.wr("LANE_EN", 3)
    # 7. restored weights -> good again
    assert [v & 0xFFFF for v in await t.infer(0)] == zgood
    dut._log.info("T-DBG localization: stuck bit found by read-back (lane/addr/field), coefficient taps, injection, lane mask")
