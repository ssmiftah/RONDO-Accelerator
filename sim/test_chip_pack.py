"""T-PACK: packing through the rbus, read-back, LOAD_CRC, PARTIAL, bit-exact vs the bare cores."""
import random, zlib
import cocotb
from chip_tb import ChipTB, R, A, ERR, STAT
import chip_common as cc

GEO = cc.Geo(16, 8, 2)


@cocotb.test()
async def pack_both_formats(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = random.Random(21)
    g = t.g
    for fmt in ("bf16", "fp32"):
        w = 16 if fmt == "bf16" else 32
        f = cc.FORMATS[fmt]["f"]
        await t.set_format(fmt)
        await t.clear_errors()
        await t.ctrl("CRC_CLR")
        Wl, Bl = cc.rand_weights(rng, GEO, f)
        ww, bw = cc.core_pack(GEO, Wl, Bl)
        # shuffled core-word order, ascending fields inside a word
        order = [("w", l, a) for l in range(GEO.lanes) for a in range(GEO.nwords)] + \
                [("b", l, a) for l in range(GEO.lanes) for a in range(GEO.nbwords)]
        rng.shuffle(order)
        vals = []
        for (kind, l, a) in order:
            els = ww[l][a] if kind == "w" else bw[l][a]
            base = g.weight_word_addr(l, a, 0) if kind == "w" else g.bias_word_addr(l, a, 0)
            for fld in range(8):
                await t.rb.write(base + fld, els[fld] | (rng.getrandbits(16) << w if w == 16 else 0))  # upper bits ignored
                vals.append(els[fld])
        assert await t.rd("LOAD_CRC") == zlib.crc32(b"".join(v.to_bytes(w // 8, "little") for v in vals)), fmt
        assert not await t.errors(), await t.errors()
        # read-back through the cache equals what was written (zero-extended elements)
        for (kind, l, a) in rng.sample(order, 40):
            els = ww[l][a] if kind == "w" else bw[l][a]
            base = g.weight_word_addr(l, a, 0) if kind == "w" else g.bias_word_addr(l, a, 0)
            got = await t.rb.read_burst(base, 8)
            assert got == els, (fmt, kind, l, a)
        # a full-word burst of weights is a no-PARTIAL case; incomplete words flag PARTIAL
        await t.clear_errors()
        base = g.weight_word_addr(0, 5, 0)
        await t.rb.write(base + 0, 1); await t.rb.write(base + 7, 2)
        assert "PARTIAL" in await t.errors()
        got = await t.rb.read_burst(base, 8)
        assert got[0] == 1 and got[7] == 2 and all(v == 0 for v in got[1:7]), "missing fields commit as 0"
        await t.clear_errors()
        await t.rb.write(base + 0, 7)                      # pending field 0 ...
        await t.rb.write(g.weight_word_addr(0, 6, 0), 8)   # ... tag changes
        assert "PARTIAL" in await t.errors()
        # restore the real weights for the word touched above and run inputs against the bare core
        for (kind, l, a) in ((("w", 0, 5)), ("w", 0, 6)):
            await t.rb.write_burst(g.weight_word_addr(l, a, 0), ww[l][a])
        await t.bare_load(fmt, Wl, Bl)
        for it in range(20):
            x = cc.rand_x(rng, GEO, f)
            await t.write_x(it % 4, x)
            zc = await t.infer(it % 4)
            zb, cyc = await t.bare_infer(fmt, x)
            assert zc == zb, f"{fmt} input {it}: chip ZBUF != bare core z"
            assert await t.rd("LAST_CYCLES") == cyc, f"{fmt}: LAST_CYCLES {await t.rd('LAST_CYCLES')} vs bare core {cyc}"
            if it < 3:
                assert zb == t.model_z(fmt, Wl, Bl, x)
        dut._log.info(f"T-PACK {fmt}: packing, read-back, LOAD_CRC, PARTIAL, 20 inputs bit-exact + cycle-exact")


@cocotb.test()
async def soft_reset_invalidates_read_cache(dut):
    """CHIP_FIX_PLAN task 9.1 (spec 9.6): a soft reset invalidates the weight read cache and resets the read FSM."""
    t = ChipTB(dut, GEO)
    await t.boot()
    pk = dut.u_dev.u_pk
    Wl, Bl = cc.rand_weights(random.Random(5), GEO, cc.FORMATS["bf16"]["f"])
    await t.load_weights("bf16", Wl, Bl)                  # the SRAM is X before the first load
    await t.rb.read(R.WEIGHT_BASE + 3)
    assert int(pk.c_valid.value) == 1, "precondition: the read filled the cache"
    await t.ctrl("SOFT_RST")
    await t.wait_idle()
    assert int(pk.c_valid.value) == 0, "read cache still valid after SOFT_RST"
    assert int(pk.rs.value) == 0
    # and the read still works afterwards (re-fetches)
    await t.rb.read(R.WEIGHT_BASE + 3)
    assert int(pk.c_valid.value) == 1
