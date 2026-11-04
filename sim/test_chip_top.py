"""T-TOP: bring-up ladder and operation through the SPI pins of rondo_chip_top (SMALL)."""
import random
import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from chip_tb import TopTB, R, STAT
import chip_common as cc
from rondo_host import packing as K

GEO = cc.Geo(16, 8, 2)


@cocotb.test()
async def bring_up_ladder(dut):
    t = TopTB(dut, GEO, ratio=8.0)
    await t.boot()
    assert int(dut.spi_miso_oe.value) == 0
    assert int(dut.clkout.value) == 0 and int(dut.irq.value) == 0 and int(dut.busy.value) == 0
    # 3. loopback
    rng = random.Random(1)
    tx = bytes([0x0E] + [rng.getrandbits(8) for _ in range(16)])
    rx = await t.bfm.xfer(tx)
    assert rx[0] == 0 and rx[1:] == tx[:-1]
    # 4. STATUS signature, bits 7..3 clear
    s8 = await t.status8()
    assert s8 & 3 == 2 and s8 >> 3 == 0, hex(s8)
    # 5. identification
    assert await t.rd("CHIP_ID") == 0x524F4E44 and await t.rd("VERSION") == R.VERSION_VALUE
    caps = await t.rd("CAPS")
    assert caps & 3 == 3
    # 6. scratch
    for v in (0xA5A55A5A, 0x5A5AA5A5):
        await t.wr("SCRATCH", v)
        assert await t.rd("SCRATCH") == v
    # 7. heartbeat toggles
    seen = set()
    for _ in range(60):
        seen.add((await t.rd("STATUS") >> 6) & 1)
    assert seen == {0, 1}
    # 8. clkout = f_core / 2^K
    await t.wr("CLKOUT_CFG", 3)
    await RisingEdge(dut.clkout)
    t0 = cocotb.utils.get_sim_time("ns")
    await RisingEdge(dut.clkout)
    t1 = cocotb.utils.get_sim_time("ns")
    assert abs((t1 - t0) - 10 * 8) < 1.0, f"clkout period {t1 - t0} ns"
    await t.wr("CLKOUT_CFG", 0)
    await Timer(500, unit="ns")
    assert int(dut.clkout.value) == 0
    # 10. clear errors
    await t.wr("ERR_STATUS", 0xFFFFFFFF)
    assert await t.rd("ERR_STATUS") == 0


@cocotb.test()
async def load_infer_selfrun(dut):
    for ratio, crc in ((8.0, False), (6.0, True)):
        t = TopTB(dut, GEO, ratio=ratio, seed=int(ratio))
        if ratio == 8.0:
            await t.boot()
        else:
            dut.rst_n.value = 0
            await Timer(60, unit="ns"); dut.rst_n.value = 1
            await Timer(200, unit="ns")
        t.rb.crc = False
        if crc:
            await t.wr("SPI_CFG", 1)          # takes effect from the next frame
            t.rb.crc = True
            assert await t.rd("SPI_CFG") == 1
        rng = random.Random(10 + int(ratio))
        f = cc.FORMATS["bf16"]["f"]
        Wl, Bl = cc.rand_weights(rng, GEO, f)
        await t.ctrl("CRC_CLR")
        await t.load_weights("bf16", Wl, Bl)
        # LOAD_CRC
        import zlib
        ww, bw = cc.core_pack(GEO, Wl, Bl)
        vals = []
        for l in range(GEO.lanes):
            vals += [e for w in ww[l] for e in w]
            vals += [e for w in bw[l] for e in w]
        # order of writes in load_weights: per lane weights then biases
        order = []
        for l in range(GEO.lanes):
            order += [e for w in ww[l] for e in w]
            order += [e for w in bw[l] for e in w]
        assert await t.rd("LOAD_CRC") == K.load_crc(order, 16)
        assert not await t.rd("ERR_STATUS")
        xs = [cc.rand_x(rng, GEO, f) for _ in range(4)]
        for e, x in enumerate(xs):
            await t.write_x(e, x)
        zs = [t.model_z("bf16", Wl, Bl, x) for x in xs]
        # single shot, wait for the irq pin
        await t.wr("IRQ_STATUS", 0xFFFFFFFF)
        await t.wr("XSEL", 1)
        await t.ctrl("START")
        busy_seen = 0
        for _ in range(4000):
            await FallingEdge(dut.clk)
            busy_seen |= int(dut.busy.value)
            if int(dut.irq.value):
                break
        assert busy_seen and int(dut.irq.value) == 1, "busy pin high during the inference and irq at done"
        # reading ZBUF and STATUS right after, then clear irq
        z = await t.read_z()
        assert [v & 0xFFFF for v in z] == zs[1]
        await t.wr("IRQ_STATUS", 1)
        await Timer(300, unit="ns")
        assert int(dut.irq.value) == 0
        # self-run: busy stays high; STATUS/ZBUF reads while busy
        await t.wr("SR_N", 4); await t.wr("SR_COUNT", 8)
        await t.ctrl("CNT_CLR", "CKSUM_CLR")
        await t.ctrl("SR_START")
        await Timer(100, unit="ns")
        assert int(dut.busy.value) == 1
        st = await t.status()
        assert (st >> STAT["SR_RUNNING"]) & 1
        _ = await t.rb.read_burst(R.ZBUF_BASE, 4)
        await t.wait_idle()
        for _ in range(4):
            await FallingEdge(dut.clk)
        assert int(dut.busy.value) == 0 and int(dut.irq.value) == 1
        seq = [zs[i % 4] for i in range(8)]
        c = 0
        for z in seq:
            c = K.update(c, z, 16)
        assert await t.rd("CHECKSUM") == c
        assert await t.rd("SR_DONE_CNT") == 8
        await t.wr("SPI_CFG", 0) if crc else None
        t.rb.crc = False
        dut._log.info(f"T-TOP R={ratio} crc={crc}: load, LOAD_CRC, single-shot, irq/busy pins, self-run checksum OK")
