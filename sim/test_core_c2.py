import random
import cocotb
from cocotb.triggers import FallingEdge
import chip_common as cc
import fpmodel as fm


def beta_sets(rng, f, eps, geo):
    """lists of |beta| patterns per ladder, mixing clamped and unclamped values."""
    sets = []
    epsm = eps & ((1 << (f.w - 1)) - 1)
    for mode in range(6):
        row = []
        for j in range(geo.width):
            r = rng.random()
            if mode == 0:       # all large
                mag = cc.rand_elem(rng, f, 0, 2) & ((1 << (f.w - 1)) - 1)
            elif mode == 1:     # all tiny
                mag = cc.rand_elem(rng, f, -12, -8) & ((1 << (f.w - 1)) - 1)
            elif mode == 2:     # exactly eps, eps-1, eps+1 and 0
                mag = [epsm, epsm - 1, epsm + 1, 0][j % 4]
            else:               # random mixture around eps
                mag = epsm + rng.randint(-40, 40) if r < 0.5 else cc.rand_elem(rng, f, -3, 1) & ((1 << (f.w - 1)) - 1)
            row.append((rng.getrandbits(1) << (f.w - 1)) | mag)
        sets.append(row)
    return sets


@cocotb.test()
async def c2_guard(dut):
    W = int(dut.W.value)
    fmt = "bf16" if W == 16 else "fp32"
    cfg = cc.FORMATS[fmt]; f = cfg["f"]
    geo = cc.Geo(16, 8, 2)
    rng = random.Random(21)
    await cc.start_clock(dut)
    await cc.core_reset(dut, geo, W)
    zero = 0
    total_clamped = 0
    for bi, betas in enumerate(beta_sets(rng, f, cfg["eps"], geo)):
        Wl = [[[zero] * geo.pdim for _ in range(geo.depth)] for _ in range(geo.width)]
        Bl = [[zero] * (geo.depth - 1) + [betas[j]] for j in range(geo.width)]
        Bl = [[zero] * (geo.depth - 1) + [betas[j]] if False else
              [zero] * (geo.depth - 1) + [betas[j]] for j in range(geo.width)]
        await cc.core_load(dut, geo, W, Wl, Bl)
        x = [0] * geo.pdim
        dut.x.value = 0
        # run with a guard_hit monitor
        hits = 0
        await FallingEdge(dut.clock); dut.start.value = 1
        await FallingEdge(dut.clock); dut.start.value = 0
        n = 0
        while int(dut.done.value) != 1:
            hits += bin(int(dut.guard_hit.value)).count("1")
            await FallingEdge(dut.clock); n += 1
            assert n < 20000
        hits += bin(int(dut.guard_hit.value)).count("1")
        for _ in range(3):
            hits += bin(int(dut.guard_hit.value)).count("1")
            await FallingEdge(dut.clock)
        z = cc.unpack_z(int(dut.z.value), geo, W)
        zm, hm, A, K0, K1 = cc.model_layer(geo, fmt, Wl, Bl, x)
        epsm = cfg["eps"] & ((1 << (W - 1)) - 1)
        expected = sum(1 for j in range(geo.width) if (betas[j] & ((1 << (W - 1)) - 1)) < epsm)
        assert sum(hm) == expected, "model/hand count mismatch"
        assert hits == expected, f"set {bi}: guard_hit count {hits} != clamped ladders {expected}"
        assert z == zm, f"set {bi}: z differs from model"
        total_clamped += expected
    assert total_clamped > 0
    dut._log.info(f"C2 {fmt}: guard_hit counts match clamped ladders (total {total_clamped})")
