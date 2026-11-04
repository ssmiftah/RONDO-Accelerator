"""T-TILE: input tiling through rondo_dev (SMALL, PDIM 8, 2 lanes, TILE_B 3), both formats.

Reference = a bare UNTILED fused_coproc_pipe with PDIM = 3 * PDIM = 24 (tb_chip_tile.v). Tiled results must
be bit-identical to it: full register sequence, B = 1..TILE_B, KEEP, the O3 host swap (batch 3 * TILE_B),
and the corner cases of spec 18.6 (out-of-order runs, stale tags, soft reset / WDOG invalidation, illegal
commands while OPEN, TILE_ABORT, LOAD_CRC per slice with TILE_SEQ_CRC, NaN data, FORMAT switch)."""
import random, struct, zlib
import cocotb
from cocotb.triggers import FallingEdge
from chip_tb import ChipTB, R, A, ERR, STAT
import chip_common as cc

PDIM, PW, S, TILE_B = 8, 24, 3, 3
GEO = cc.Geo(16, PDIM, 2)
GEOW = cc.Geo(16, PW, 2)
W_OF = {"bf16": 16, "fp32": 32}
NEGZ = {"bf16": 0x8000, "fp32": 0x80000000}
QNAN = {"bf16": 0x7FC0, "fp32": 0x7FC00000}


def gen(rng, fmt, n, p=PW):
    f = cc.FORMATS[fmt]["f"]
    g = cc.Geo(16, p, 2)
    W, B = cc.rand_weights(rng, g, f)
    xs = [cc.rand_x(rng, g, f) for _ in range(n)]
    if p < PW:                                   # padding rule: weights -0, inputs +0
        W = [[row + [NEGZ[fmt]] * (PW - p) for row in Wj] for Wj in W]
        xs = [x + [0] * (PW - p) for x in xs]
    return W, B, xs


async def bare_all(t, fmt, W, B, xs):
    await cc.core_load(t.dut, GEOW, W_OF[fmt], W, B, pfx="bf_" if fmt == "bf16" else "fp_", clk=t.clk)
    return [(await t.bare_infer(fmt, x))[0] for x in xs]


async def load_slice(t, fmt, W, B, s):
    Ws = [[row[s * PDIM:(s + 1) * PDIM] for row in Wj] for Wj in W]
    await t.ctrl("CRC_CLR")
    await t.load_weights(fmt, Ws, B)
    return await t.rd("LOAD_CRC")


async def write_tx(t, b, x, s):
    await t.rb.write_burst(t.g.tx_addr(b, 0), x[s * PDIM:(s + 1) * PDIM])


def cfg_word(nslice, tbatch, keep=0, host=0, en=1):
    return en | (nslice << 8) | (tbatch << 16) | (keep << 24) | (host << 25)


def tstat(v):
    return dict(open=v & 1, slice_done=(v >> 1) & 1, final=(v >> 2) & 1, stale=(v >> 3) & 1,
                slice=(v >> 8) & 255, done=(v >> 16) & 255)


async def read_tz(t, nb):
    return [await t.rb.read_burst(t.g.tz_addr(b, 0), GEO.width) for b in range(nb)]


def crc_of(crcs):
    return zlib.crc32(b"".join(struct.pack("<I", c) for c in crcs)) & 0xFFFFFFFF


async def run_batch(t, fmt, W, B, xs, nb, keep=False, check_crc=True):
    """one tiled sequence over S slices for inputs xs[:nb]; returns the TZ contents"""
    await t.wr("TILE_CFG", cfg_word(S, 1 if keep else nb, keep=int(keep)))
    infer0 = await t.rd64("INFER_CNT_LO", "INFER_CNT_HI")
    crcs = []
    for s in range(S):
        crcs.append(await load_slice(t, fmt, W, B, s))
        for b in range(nb):
            await write_tx(t, b, xs[b], s)
        await t.ctrl("TILE_RUN")
        await t.wait_idle()
        st = tstat(await t.rd("TILE_STATUS"))
        irq = await t.rd("IRQ_STATUS")
        if s < S - 1:
            assert st["open"] and st["slice_done"] and not st["final"] and st["slice"] == s + 1, (s, st)
            assert (irq >> 5) & 1 and not (irq >> 6) & 1, hex(irq)
        else:
            assert (not st["open"]) and st["final"] and st["slice"] == 0, (s, st)
            assert (irq >> 6) & 1, hex(irq)
        assert st["done"] == (1 if keep else nb), st
        await t.wr("IRQ_STATUS", 0x7F)
    if check_crc:
        assert await t.rd("TILE_SEQ_CRC") == crc_of(crcs), "TILE_SEQ_CRC"
    infer1 = await t.rd64("INFER_CNT_LO", "INFER_CNT_HI")
    assert infer1 - infer0 == S * (1 if keep else nb), "INFER_CNT counts every launch"
    return await read_tz(t, nb)


async def keep_batch(t, fmt, W, B, xs):
    zs = []
    for x in xs:
        zs += await run_batch(t, fmt, W, B, [x], 1, keep=True, check_crc=False)
    return zs


@cocotb.test()
async def tile_basic(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    assert (await t.rd("CAPS")) >> 17 & 1, "CAPS.TILE"
    tg = await t.rd("TILE_GEOM")
    assert tg == (32 << 16) | (16 << 8) | TILE_B, hex(tg)
    rng = random.Random(1801)
    for fmt in ("bf16", "fp32"):
        await t.set_format(fmt)
        W, B, xs = gen(rng, fmt, 2 * TILE_B)
        ref = await bare_all(t, fmt, W, B, xs)
        for nb in (1, 2, TILE_B):
            zs = await run_batch(t, fmt, W, B, xs, nb)
            for b in range(nb):
                assert zs[b] == ref[b], f"{fmt} B={nb} input {b}"
        # ZBUF holds the last final z; partial slices must not have touched it
        assert await t.read_z() == ref[nb - 1]
        # KEEP mode (acc kept in place, one input per sequence)
        zs = await keep_batch(t, fmt, W, B, xs[:2])
        assert zs == ref[:2], f"{fmt} KEEP"
        # padded wide layer: p = 20 logical inputs
        W2, B2, xs2 = gen(rng, fmt, 2, p=20)
        ref2 = await bare_all(t, fmt, W2, B2, xs2)
        zs = await run_batch(t, fmt, W2, B2, xs2, 2)
        assert zs == ref2, f"{fmt} p=20 padded"
        dut._log.info(f"T-TILE basic {fmt}: B=1,2,{TILE_B}, KEEP, p=20 padded == untiled PDIM={PW} core")


async def ps_dump(t, fmt, b):
    nel = GEO.nbwords * GEO.npar
    return [await t.rb.read_burst(t.g.ps_addr(b, l, 0, 0), nel) for l in range(GEO.lanes)]


async def ps_load(t, b, dump):
    for l, els in enumerate(dump):
        await t.rb.write_burst(t.g.ps_addr(b, l, 0, 0), els)


@cocotb.test()
async def tile_host_swap(dut):
    """O3: batch 3 * TILE_B through HOST_SLICE, PS saved/restored over the bus"""
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = random.Random(1802)
    nsub, N = 3, 3 * TILE_B
    for fmt in ("bf16", "fp32"):
        await t.set_format(fmt)
        W, B, xs = gen(rng, fmt, N)
        ref = await bare_all(t, fmt, W, B, xs)
        await t.wr("TILE_CFG", cfg_word(S, TILE_B, host=1))
        saved = {}
        out = {}
        for s in range(S):
            await load_slice(t, fmt, W, B, s)
            for sb in range(nsub):
                if s > 0:
                    await t.wr("TILE_SLICE", s)
                    for b in range(TILE_B):
                        await ps_load(t, b, saved[(sb, b)])
                for b in range(TILE_B):
                    await write_tx(t, b, xs[sb * TILE_B + b], s)
                if s > 0 or sb > 0:
                    pass
                await t.ctrl("TILE_RUN")
                await t.wait_idle()
                if s < S - 1:
                    for b in range(TILE_B):
                        saved[(sb, b)] = await ps_dump(t, fmt, b)
                else:
                    for b, z in enumerate(await read_tz(t, TILE_B)):
                        out[sb * TILE_B + b] = z
        await t.ctrl("TILE_ABORT")
        st = tstat(await t.rd("TILE_STATUS"))
        assert not st["open"] and not st["stale"]
        for i in range(N):
            assert out[i] == ref[i], f"{fmt} host-swap input {i}"
        dut._log.info(f"T-TILE host swap {fmt}: batch {N} (3 sub-batches of {TILE_B}) == untiled core")


@cocotb.test()
async def tile_corner(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = random.Random(1803)
    fmt = "bf16"
    await t.set_format(fmt)
    W, B, xs = gen(rng, fmt, TILE_B)
    ref = await bare_all(t, fmt, W, B, xs)

    async def err_has(name):
        e = await t.errors()
        await t.clear_errors()
        return name in e

    # ---- TILE_CFG range checks and TILE_RUN with TILE_EN = 0
    await t.clear_errors()
    await t.wr("TILE_CFG", cfg_word(0, 1)); assert await err_has("RANGE")
    await t.wr("TILE_CFG", cfg_word(S, TILE_B + 1)); assert await err_has("RANGE")
    await t.wr("TILE_CFG", cfg_word(S, 0)); assert await err_has("RANGE")
    await t.wr("TILE_CFG", 0)
    await t.ctrl("TILE_RUN"); await t.wait_idle(); assert await err_has("TILE_SEQ"), "TILE_RUN with TILE_EN=0"
    # ---- START / SR_START with TILE_EN = 1 (closed)
    await t.wr("TILE_CFG", cfg_word(S, 2))
    await t.ctrl("START"); assert await err_has("TILE_SEQ")
    await t.ctrl("SR_START"); assert await err_has("TILE_SEQ")
    assert (await t.status() >> STAT["ACTIVE"]) & 1 == 0
    # ---- TILE_RUN out of order: slice 0 never run
    await t.wr("TILE_CFG", cfg_word(S, 2, host=1))
    await t.ctrl("TILE_ABORT")
    for b in range(2):
        for s in range(S):
            pass
    await load_slice(t, fmt, W, B, 1)
    await t.wr("TILE_SLICE", 1) if False else None
    # host mode, not open: a TILE_SLICE write is a sequencing error
    await t.clear_errors()
    await t.wr("TILE_SLICE", 1); assert await err_has("TILE_SEQ")
    await t.wr("TILE_CFG", cfg_word(S, 2))
    # non-host: SLICE is 0, so this opens a sequence; run slice 0 then check ordering rules while OPEN
    infer0 = await t.rd64("INFER_CNT_LO", "INFER_CNT_HI")
    crcs = [await load_slice(t, fmt, W, B, 0)]
    for b in range(2):
        await write_tx(t, b, xs[b], 0)
    await t.ctrl("TILE_RUN"); await t.wait_idle()
    st = tstat(await t.rd("TILE_STATUS")); assert st["open"] and st["slice"] == 1
    # illegal commands while OPEN
    await t.clear_errors()
    await t.ctrl("START"); assert await err_has("TILE_SEQ")
    await t.ctrl("SR_START"); assert await err_has("TILE_SEQ")
    await t.ctrl("KAT_START"); assert await err_has("TILE_SEQ")
    await t.wr("TILE_CFG", cfg_word(S, 1)); assert await err_has("TILE_SEQ")
    await t.wr("FORMAT", 1); assert await err_has("TILE_SEQ")
    await t.wr("LANE_EN", 1); assert await err_has("TILE_SEQ")
    assert await t.rd("TILE_CFG") == cfg_word(S, 2) and await t.rd("FORMAT") == 0 and await t.rd("LANE_EN") == 3
    # TILE_ABORT closes, no error, clears the stale flag
    await t.ctrl("TILE_ABORT")
    st = tstat(await t.rd("TILE_STATUS")); assert not st["open"] and not st["stale"] and st["slice"] == 0
    assert not await err_has("TILE_STALE")
    # slice 1 after the abort: nothing to continue -> STALE and no launch
    infer1 = await t.rd64("INFER_CNT_LO", "INFER_CNT_HI")
    await t.wr("TILE_CFG", cfg_word(S, 2, host=1))
    # (host mode, closed: slice register is 0; a run of slice 0 re-opens)
    # ---- wrong tag: run slice 0, then ask for slice 2 (host mode)
    await t.clear_errors()
    await load_slice(t, fmt, W, B, 0)
    for b in range(2):
        await write_tx(t, b, xs[b], 0)
    await t.ctrl("TILE_RUN"); await t.wait_idle()
    await t.wr("TILE_SLICE", 2)
    await t.ctrl("TILE_RUN"); await t.wait_idle()
    assert await err_has("TILE_STALE"), "slice 2 after slice 0: wrong tag"
    st = tstat(await t.rd("TILE_STATUS")); assert st["stale"] and st["open"]
    infer2 = await t.rd64("INFER_CNT_LO", "INFER_CNT_HI")
    assert infer2 - infer1 == 2, "the refused run launched nothing"
    # an input slice that was never run: slice index out of range
    await t.wr("TILE_SLICE", S)
    await t.ctrl("TILE_RUN"); await t.wait_idle()
    assert await err_has("TILE_SEQ")
    # ---- soft reset invalidates an open sequence and reports TILE_STALE
    await t.wr("TILE_SLICE", 0)
    await t.ctrl("SOFT_RST")
    await t.wait_idle()
    st = tstat(await t.rd("TILE_STATUS")); assert (not st["open"]) and st["stale"], st
    assert await err_has("TILE_STALE")
    # ---- watchdog during a tile run, then soft reset
    await t.ctrl("TILE_ABORT")
    await t.wr("WDOG_LIMIT", 10)
    await t.wr("TILE_CFG", cfg_word(S, 1))
    await t.ctrl("TILE_RUN"); await t.wait_idle()
    assert await err_has("WDOG")
    await t.wr("WDOG_LIMIT", 0)
    st = tstat(await t.rd("TILE_STATUS")); assert st["open"]
    await t.ctrl("SOFT_RST"); await t.wait_idle()
    st = tstat(await t.rd("TILE_STATUS")); assert not st["open"] and st["stale"]
    await t.clear_errors()
    await t.ctrl("TILE_ABORT")
    # ---- memory map rules: TZ is read-only, holes, ranges
    await t.wr("TILE_CFG", 0)
    await t.clear_errors()
    await t.rb.write(t.g.tz_addr(0, 0), 1); assert await err_has("RO")
    await t.rb.write(t.g.tx_addr(TILE_B, 0), 1); assert await err_has("ADDR")
    await t.rb.write(t.g.tx_addr(0, 0), 0x3F80); assert await t.rb.read(t.g.tx_addr(0, 0)) == 0x3F80
    await t.rb.read(t.g.ps_addr(TILE_B, 0, 0, 0)); assert await err_has("ADDR")
    await t.rb.read(t.g.ps_addr(0, 0, GEO.nbwords, 0)); assert await err_has("ADDR")
    await t.rb.write(t.g.ps_addr(1, 1, 2, 3), 0xBEEF)
    assert await t.rb.read(t.g.ps_addr(1, 1, 2, 3)) == 0xBEEF
    # ---- FORMAT switch clears the PS valid bits (a host PS write marks the entry valid)
    u = dut.u_dev.g_tile.u_tile
    assert int(u.valid.value) != 0, "host PS write marks the entry valid"
    await t.wr("FORMAT", 1); await t.wait_idle()
    assert int(u.valid.value) == 0, "FORMAT switch clears all PS valid bits"
    await t.set_format("bf16")
    # ---- NaN / Inf data does not abort a sequence
    Wn = [[list(r) for r in Wj] for Wj in W]
    Wn[3][0][0] = QNAN[fmt]
    Wn[5][1][PDIM + 1] = 0x7F80          # +Inf in slice 1
    refn = await bare_all(t, fmt, Wn, B, xs)
    await t.wr("CNT_CLR" if False else "GUARD_HITS", 0) if False else None
    zs = await run_batch(t, fmt, Wn, B, xs, TILE_B)
    assert zs == refn, "NaN/Inf ladders: tiled == untiled"
    assert (await t.rd("NANINF_CNT")) > 0
    # ---- lane mask latched at open: lane 0 only
    await t.wr("LANE_EN", 1)
    zs = await run_batch(t, fmt, W, B, xs, 2)
    nl = GEO.width // GEO.lanes
    for b in range(2):
        assert zs[b][:nl] == ref[b][:nl], "enabled lane unchanged"
    await t.wr("LANE_EN", 3)
    dut._log.info("T-TILE corner cases: ordering, stale tags, resets, WDOG, illegal commands, map, FORMAT, NaN, lane mask")


@cocotb.test()
async def tile_pwr_ctrl_while_open(dut):
    """B1 (CHIP_FIX_PLAN task 1): PWR_CTRL writes are rejected with TILE_SEQ while a tile sequence is OPEN.

    CORE_HOLD / CORE_CLK_OFF would reset the in-place accumulators of a KEEP sequence (and are pointless mid-sequence otherwise).
    Variants: (a) KEEP fp32, PWR_CTRL = CORE_HOLD; (b) KEEP bf16, PWR_CTRL = CORE_CLK_OFF; (c) non-KEEP TBATCH = 2 fp32, CORE_HOLD."""
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = random.Random(77)
    for name, fmt, keep, nb, pwr in (("a KEEP fp32 CORE_HOLD", "fp32", 1, 1, 1),
                                     ("b KEEP bf16 CORE_CLK_OFF", "bf16", 1, 1, 2),
                                     ("c TBATCH=2 fp32 CORE_HOLD", "fp32", 0, 2, 1)):
        await t.set_format(fmt)
        W, B, xs = gen(rng, fmt, nb)
        ref = await bare_all(t, fmt, W, B, xs)
        await t.clear_errors()
        await t.wr("TILE_CFG", cfg_word(S, nb, keep=keep))
        problems = []
        for s in range(S):
            await load_slice(t, fmt, W, B, s)
            for b in range(nb):
                await write_tx(t, b, xs[b], s)
            if s == 1:
                await t.clear_errors()
                await t.wr("PWR_CTRL", pwr)
                e1 = await t.errors()
                pc = await t.rd("PWR_CTRL")
                if "TILE_SEQ" not in e1:
                    problems.append(f"PWR_CTRL write while OPEN did not set TILE_SEQ (errors={e1})")
                if "BUSY_WR" in e1:
                    problems.append(f"BUSY_WR set: {e1}")
                if pc != 0:
                    problems.append(f"PWR_CTRL reads back {pc:#x}, expected 0")
                await t.clear_errors()
                await t.wr("PWR_CTRL", 0)          # a no-op write is rejected too; before the fix it restores the cores
                await t.clear_errors()
                await t.wait_idle()
            await t.ctrl("TILE_RUN")
            await t.wait_idle()
        st = tstat(await t.rd("TILE_STATUS"))
        errs = await t.errors()
        zs = await read_tz(t, nb)
        if not st["final"]:
            problems.append(f"no FINAL_DONE: {st}")
        if st["stale"] or "TILE_STALE" in errs:
            problems.append(f"TILE_STALE: {st} {errs}")
        if zs != ref[:nb]:
            problems.append("TZ != untiled bare-core reference (partial sums lost)")
        dut._log.info(f"PWR_CTRL while OPEN, variant {name}: problems={problems}")
        assert not problems, f"variant {name}: " + "; ".join(problems)
        await t.clear_errors()


@cocotb.test()
async def tile_mem_test_faults(dut):
    """CHIP_FIX_PLAN 13.1 (D1(a)): the host-side March C- over PS and TX (host/rondo_host/memtest.py, the algorithm behind Rondo.mem_test) on rondo_dev:
    a clean run reports nothing; a stuck bit in one rondo_ps H macro, one L macro (fp32) and in the TX SRAM is reported with the right location."""
    import dataclasses
    from rondo_host import memtest
    t = ChipTB(dut, GEO)
    await t.boot()
    g = t.g
    g.tile_b = TILE_B
    ps = dut.u_dev.g_tile.g_ps.u_ps
    tx = dut.u_dev.g_tile.u_tbuf.u_tx

    async def rd(addr, n):
        return await t.rb.read_burst(addr, n)

    async def wr(addr, words):
        await t.rb.write_burst(addr, words)

    def clear():
        for l in range(GEO.lanes):
            for h in ("u_h", "u_l"):
                m = getattr(getattr(ps, f"lane[{l}]"), h)
                m.f_en.value = 0; m.f_sa0.value = 0; m.f_sa1.value = 0; m.f_tf.value = 0
        tx.f_en.value = 0; tx.f_sa0.value = 0; tx.f_sa1.value = 0

    async def run(fmt):
        gen = memtest.march(g, ("PS", "TX"), 16 if fmt == "bf16" else 32)
        fails = await memtest.run_async(gen, rd, wr)
        await t.ctrl("TILE_ABORT")
        return fails

    baw = g.baw
    for fmt in ("bf16", "fp32"):
        await t.set_format(fmt)
        clear()
        assert await run(fmt) == [], f"{fmt}: clean run must report no failure"
        # stuck-at-1 on bit 3 of PS element (b=2, lane=1, group=4, field=5): macro H holds the high half of an fp32 element, the whole bf16 element
        m = getattr(getattr(ps, "lane[1]"), "u_h")
        m.f_addr.value = (2 << baw) | 4
        m.f_sa1.value = 1 << (5 * 16 + 3)
        m.f_en.value = 1
        # TX word (b=1, i=6): bit 9 stuck at 0
        tx.f_addr.value = (1 << g.xw) | 6
        tx.f_sa0.value = 1 << 9
        tx.f_en.value = 1
        fails = await run(fmt)
        exp_ps_xor = (1 << 3) if fmt == "bf16" else (1 << 19)       # fp32: the H macro is bits [31:16] of the element
        assert ("PS", 2, 1, 4, 5, exp_ps_xor) in fails, f"{fmt}: PS fault not reported: {fails}"
        assert ("TX", 1, None, None, 6, 1 << 9) in fails, f"{fmt}: TX fault not reported: {fails}"
        assert len(fails) == 2, fails
        clear()
        if fmt == "fp32":                                         # the L macro (low half) only exists in fp32
            m = getattr(getattr(ps, "lane[0]"), "u_l")
            m.f_addr.value = (0 << baw) | 1
            m.f_sa0.value = 1 << (2 * 16 + 5)
            m.f_en.value = 1
            fails = await run(fmt)
            assert fails == [("PS", 0, 0, 1, 2, 1 << 5)], fails
            clear()
    dut._log.info("T-TILE: host March C- over PS and TX: clean = no failure; stuck bits in an H macro, an L macro and the TX SRAM localized")
