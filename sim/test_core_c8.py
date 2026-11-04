import random
import cocotb
from cocotb.triggers import FallingEdge
import chip_common as cc

PT, NL = 8, 2


def pack_words(geo, Wl, Bl, w, wtag):
    """-> list per lane of (addr, word)"""
    ww, bw = cc.core_pack(geo, Wl, Bl)
    return ww, bw


async def load_w(dut, pfx, geo, ww, w):
    for l in range(geo.lanes):
        for a, el in enumerate(ww[l]):
            getattr(dut, pfx + "w_lane").value = l
            getattr(dut, pfx + "w_addr").value = a
            getattr(dut, pfx + "w_din").value = cc.word_int(el, w)
            getattr(dut, pfx + "w_we").value = 1
            await FallingEdge(dut.clock)
    getattr(dut, pfx + "w_we").value = 0
    await FallingEdge(dut.clock)


async def load_b(dut, pfx, geo, bw, w):
    for l in range(geo.lanes):
        getattr(dut, pfx + "w_lane").value = l
        for a, el in enumerate(bw[l]):
            getattr(dut, pfx + "b_addr").value = a
            getattr(dut, pfx + "b_din").value = cc.word_int(el, w)
            getattr(dut, pfx + "b_we").value = 1
            await FallingEdge(dut.clock)
        getattr(dut, pfx + "b_we").value = 0
    await FallingEdge(dut.clock)


async def run_start(dut, pfx, limit=20000):
    await FallingEdge(dut.clock); getattr(dut, pfx + "start").value = 1
    await FallingEdge(dut.clock); getattr(dut, pfx + "start").value = 0
    n = 0
    while not int(getattr(dut, pfx + "done").value):
        await FallingEdge(dut.clock); n += 1
        assert n < limit, "hang"
    z = int(getattr(dut, pfx + "z").value)
    final = int(dut.t_done_final.value) if pfx == "t_" else None
    for _ in range(3):
        await FallingEdge(dut.clock)
    return z, final


def specials(f, w, rng):
    """(neg zero, subnormal, inf, nan) patterns of this format"""
    sig = f.sig
    return dict(nz=1 << (w - 1), sub=1 << (sig - 3), inf=f.inf, nan=f.qnan, pz=0)


@cocotb.test()
async def c8_tiling(dut):
    W = int(dut.W.value); AW = int(dut.AW.value)
    fmt = "bf16" if W == 16 else "fp32"
    cfg = cc.FORMATS[fmt]; f = cfg["f"]
    p1, p2 = int(dut.P1.value), int(dut.P2.value)
    S = p2 // PT
    width = int(dut.WIDTH.value)
    gt, g1, g2 = cc.Geo(width, PT, NL), cc.Geo(width, p1, NL), cc.Geo(width, p2, NL)
    rng = random.Random(81 + p1)
    await cc.start_clock(dut)
    for s in ("t_w_we", "t_b_we", "t_start", "t_save", "t_last", "a_w_we", "a_b_we", "a_start", "b_w_we", "b_b_we", "b_start",
              "t_seed", "t_w_lane", "a_w_lane", "b_w_lane", "t_w_addr", "a_w_addr", "b_w_addr", "t_w_din", "a_w_din", "b_w_din",
              "t_b_addr", "a_b_addr", "b_b_addr", "t_b_din", "a_b_din", "b_b_din", "t_x", "a_x", "b_x"):
        getattr(dut, s).value = 0
    dut.t_lane_en.value = 3
    dut.nReset.value = 0
    await FallingEdge(dut.clock); await FallingEdge(dut.clock); await FallingEdge(dut.clock)
    dut.nReset.value = 1
    await FallingEdge(dut.clock)
    sp = specials(f, W, rng)
    # initialize zl of the tiled core (it is not reset): one complete single-slice run
    W0, B0 = cc.rand_weights(rng, gt, f)
    ww0, bw0 = cc.core_pack(gt, W0, B0)
    await load_w(dut, "t_", gt, ww0, W); await load_b(dut, "t_", gt, bw0, W)
    dut.t_x.value = 0; dut.t_seed.value = 0; dut.t_save.value = 0; dut.t_last.value = 1
    await run_start(dut, "t_")
    negz = 1 << (W - 1)
    for trial in range(3):
        Wl, Bl = cc.rand_weights(rng, g1, f)
        # crafted ladders: chains ending in -0, subnormal, Inf, NaN accumulators (trial 0 exercises the Inf/NaN, others -0/subnormal)
        if trial == 0:
            for c in range(p1):
                Wl[0][0][c] = negz                      # all products -0 ...
            Bl[0][0] = negz                             # ... and a -0 bias: the accumulator stays -0
            Wl[1][1][3] = sp["inf"]
            Wl[2][2][p1 - 1] = sp["nan"]
        elif trial == 1:
            Wl[3][0][0] = sp["sub"]
            for c in range(1, p1):
                Wl[3][0][c] = 0
            Bl[3][0] = 0
        x = cc.rand_x(rng, g1, f)
        if trial == 1:
            x[0] = sp["sub"]
        # references
        for pfx, geo, pw in (("a_", g1, p1), ("b_", g2, p2)):
            Wp = [[[Wl[j][k][c] if c < p1 else negz for c in range(pw)] for k in range(g1.depth)] for j in range(width)]
            ww, bw = cc.core_pack(geo, Wp, Bl)
            await load_w(dut, pfx, geo, ww, W)
            await load_b(dut, pfx, geo, bw, W)
        za, _ = await run_start(dut, "a_") if False else (None, None)
        dut.a_x.value = cc.word_int(x, W)
        za, _ = await run_start(dut, "a_")
        dut.b_x.value = cc.word_int(x + [0] * (p2 - p1), W)
        zb, _ = await run_start(dut, "b_")
        assert za == zb, f"trial {trial}: padded untiled reference differs from the exact one (padding rule -0 / +0)"
        # tiled: seed from PS (restore) and keep-in-place
        for mode in ("restore", "keep"):
            z_before = int(dut.t_z.value)
            for s in range(S):
                Wp = [[[Wl[j][k][s * PT + c] if s * PT + c < p1 else negz for c in range(PT)] for k in range(g1.depth)]
                      for j in range(width)]
                Bs = Bl if s == 0 else [[0] * g1.depth for _ in range(width)]
                ww, bw = cc.core_pack(gt, Wp, Bs)
                await load_w(dut, "t_", gt, ww, W)
                if s == 0:
                    await load_b(dut, "t_", gt, bw, W)
                xs = [x[s * PT + c] if s * PT + c < p1 else 0 for c in range(PT)]
                dut.t_x.value = cc.word_int(xs, W)
                dut.t_seed.value = 0 if s == 0 else (2 if mode == "restore" else 1)
                dut.t_save.value = 1 if (mode == "restore" and s < S - 1) else 0
                dut.t_last.value = 1 if s == S - 1 else 0
                zt, final = await run_start(dut, "t_")
                if s < S - 1:
                    assert final == 0, "done_final must stay low on partial slices"
                    assert zt == z_before, "zl must be untouched by partial slices"
                else:
                    assert final == 1, "done_final on the last slice"
            assert zt == za, f"trial {trial} mode {mode} p={p1}: tiled z != untiled z"
            assert zt == zb
        # lane mask during tiling: a disabled lane neither runs nor saves; the enabled lane is unchanged
        dut.t_lane_en.value = 1
        s = S - 1
        Wp = [[[Wl[j][k][s * PT + c] if s * PT + c < p1 else negz for c in range(PT)] for k in range(g1.depth)] for j in range(width)]
        ww, bw = cc.core_pack(gt, Wp, Bl)
        await load_w(dut, "t_", gt, ww, W)
        dut.t_seed.value = 0; dut.t_save.value = 0; dut.t_last.value = 1
        dut.t_x.value = cc.word_int([x[s * PT + c] if s * PT + c < p1 else 0 for c in range(PT)], W)
        zt, final = await run_start(dut, "t_")
        assert final == 1
        nl = width // NL
        assert (zt >> (W * nl)) & ((1 << (W * nl)) - 1) == int("".join(f"{f.qnan:0{W // 4}x}" for _ in range(nl)), 16)
        dut.t_lane_en.value = 3
    dut._log.info(f"C8 {fmt} p={p1} (padded {p2}): tiled == untiled for random + crafted -0/subnormal/Inf/NaN, restore and keep modes")
