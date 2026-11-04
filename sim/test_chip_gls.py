"""T-GLS: pin-level test used for the RTL-vs-netlist comparison (reduced geometry WIDTH 8, PDIM 4, 1 lane).
Everything is checked against the bit-exact model, so a passing netlist run proves netlist == RTL on this stimulus."""
import random
import cocotb
from chip_tb import TopTB, R
import chip_common as cc
import test_chip_kat as tk
import fpmodel as fm

GEO = cc.Geo(8, 4, 1)
tk.GEO = GEO


@cocotb.test()
async def gls_subset(dut):
    t = TopTB(dut, GEO, ratio=8.0)
    await t.boot()
    t.poll_gap = 20
    assert int(dut.spi_miso_oe.value) == 0
    tx = bytes([0x0E, 1, 2, 3, 0xA5, 0x5A])
    rx = await t.bfm.xfer(tx)
    assert rx[1:] == tx[:-1], "loopback"
    assert await t.rd("CHIP_ID") == 0x524F4E44 and await t.rd("VERSION") == R.VERSION_VALUE
    await t.wr("SCRATCH", 0xA5A55A5A)
    assert await t.rd("SCRATCH") == 0xA5A55A5A
    rng = random.Random(77)
    for fmt in ("bf16", "fp32"):
        if fmt == "fp32":
            await t.set_format("fp32")
        f = cc.FORMATS[fmt]["f"]
        Wl, Bl = cc.rand_weights(rng, GEO, f)
        await t.load_weights(fmt, Wl, Bl)
        x = cc.rand_x(rng, GEO, f)
        await t.write_x(0, x)
        z = await t.infer(0)
        want = t.model_z(fmt, Wl, Bl, x)
        w = 16 if fmt == "bf16" else 32
        assert [v & ((1 << w) - 1) for v in z] == want, f"{fmt}: netlist z != model"
        exp, _ = tk.kat_signature(fmt)
        await t.ctrl("KAT_START")
        await t.wait_idle()
        got = await t.rd("KAT_GOT_BF16" if fmt == "bf16" else "KAT_GOT_FP32")
        assert got == exp, f"{fmt}: KAT signature {got:#x} != model {exp:#x}"
        dut._log.info(f"GLS {fmt}: inference and KAT match the model")
