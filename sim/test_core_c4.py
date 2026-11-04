"""T-C4: every static tap equals the model for all lanes/indices; live streams; z unchanged."""
import random
import cocotb
from cocotb.triggers import FallingEdge
import chip_common as cc
import fpmodel as fm


@cocotb.test()
async def c4_taps(dut):
    W = int(dut.W.value)
    accsig = int(dut.ACCSIG.value)
    fmt = "bf16" if W == 16 else "fp32"
    cfg = cc.FORMATS[fmt]; f = cfg["f"]
    fa = fm.Fmt(8, accsig)
    geo = cc.Geo(16, 8, 2)
    rng = random.Random(44)
    await cc.start_clock(dut)
    await cc.tb_core_reset(dut, geo, W)
    Wl, Bl = cc.rand_weights(rng, geo, f)
    await cc.core_load(dut, geo, W, Wl, Bl)
    x = cc.rand_x(rng, geo, f)
    zm, hm, A, K0, K1 = cc.model_layer(geo, fmt, Wl, Bl, x, accsig=accsig)
    ACC = [[cc.affine_acc(f, fa, Wl[j][k], x, Bl[j][k]) for k in range(geo.depth)] for j in range(geo.width)]
    dut.x.value = cc.pack_x(x, W)
    lives = {s: [] for s in range(4)}
    flags_seen = set()
    for sel in range(4):                       # one inference per live selection
        dut.dbg_live_sel.value = sel
        dut.dbg_lane.value = 1
        await FallingEdge(dut.clock); dut.start.value = 1
        await FallingEdge(dut.clock); dut.start.value = 0
        n = 0
        while True:
            if int(dut.dbg_live_v.value):
                lives[sel].append(int(dut.dbg_live_d.value))
            fl = int(dut.dbg_live_f.value)
            flags_seen.add((fl >> 3) & 7)
            if sel == 1:
                assert (fl & 1) == int(dut.dbg_live_v.value), "live flag[0] != live valid for sel 1"
            if int(dut.done.value):
                break
            await FallingEdge(dut.clock); n += 1
            assert n < 20000
        for _ in range(6):
            await FallingEdge(dut.clock)
        assert cc.unpack_z(int(dut.z.value), geo, W) == zm, "z differs from model with DBG=1"
    lane = 1
    nl = geo.nlad
    mask = (1 << W) - 1
    assert lives[0] == [K0[lane * nl + s] for s in range(nl)], "live 0 (recip input k0)"
    assert lives[1] == [zm[lane * nl + s] for s in range(nl)], "live 1 (recip output)"
    assert lives[2] == [K1[lane * nl + s] for s in range(nl)], "live 2 (scan numerator k1)"
    assert len(lives[3]) == geo.ngroup * geo.pdim, f"live 3 count {len(lives[3])}"
    assert lives[3][-geo.ngroup:] == [ACC[lane * nl + (g * geo.npar) // geo.depth][(g * geo.npar) % geo.depth]
                                      for g in range(geo.ngroup)], "live 3 final writebacks"
    assert {1, 2, 3, 4} <= flags_seen, f"lstate values seen {flags_seen}"
    # static taps: all lanes and indices, plus out-of-range -> 0
    nbad = 0
    for lane in range(geo.lanes):
        for s in range(geo.nslot):
            j = lane * nl + s
            for k in range(geo.depth):
                idx = s * geo.depth + k
                assert await cc.dbg_read(dut, lane, 0, idx) == A[j][k], f"sig0 lane{lane} idx{idx}"
                assert await cc.dbg_read(dut, lane, 1, idx) == ACC[j][k] & 0xFFFFFFFF, f"sig1 lane{lane} idx{idx}"
            assert await cc.dbg_read(dut, lane, 2, s) == K0[j], f"sig2 lane{lane} slot{s}"
            assert await cc.dbg_read(dut, lane, 3, s) == K1[j], f"sig3 lane{lane} slot{s}"
            assert await cc.dbg_read(dut, lane, 4, s) == zm[j], f"sig4 lane{lane} slot{s}"
        assert await cc.dbg_read(dut, lane, 5, 0) == (geo.nbatches * geo.nslot) << 4, "sig5 status"
        for sig in (6, 7):
            assert await cc.dbg_read(dut, lane, sig, 0) == 0
        assert await cc.dbg_read(dut, lane, 0, 200) == 0
    dut._log.info(f"C4 {fmt} accsig={accsig}: all static taps, 4 live streams and z match the model")
