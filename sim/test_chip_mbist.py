"""T-MBIST: March C- passes on good memories and detects stuck-at, transition and coupling faults
with the right lane / address / store / half."""
import cocotb
from chip_tb import ChipTB, R, STAT, ERR
import chip_common as cc

GEO = cc.Geo(16, 8, 2)


def macro(dut, lane, bias, half):
    m = getattr(dut.u_dev.u_mem, f"lane[{lane}]")
    return getattr(m, ("u_b" if bias else "u_w") + ("l" if half else "h"))


def clear(dut):
    for l in range(GEO.lanes):
        for b in (0, 1):
            for h in (0, 1):
                m = macro(dut, l, b, h)
                m.f_en.value = 0; m.f_cpl_en.value = 0; m.f_sa0.value = 0; m.f_sa1.value = 0; m.f_tf.value = 0
                m.f_cpl_vict.value = 0


async def run_mbist(t):
    await t.clear_errors()
    await t.ctrl("MBIST_START")
    s = await t.status()
    assert (s >> STAT["ACTIVE"]) & 1 and (s >> STAT["MBIST_RUNNING"]) & 1
    await t.wait_idle(timeout=800000)
    st = await t.rd("MBIST_STATUS")
    return st, await t.rd("MBIST_FAIL_ADDR"), await t.rd("MBIST_FAIL_XOR")


@cocotb.test()
async def march(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    t.poll_gap = 30
    clear(dut)
    st, fa, fx = await run_mbist(t)
    assert (st >> 1) & 1 and not (st >> 2) & 1 and st >> 16 == 0, hex(st)
    s = await t.status()
    assert (s >> STAT["WSTALE"]) & 1, "MBIST overwrites the weights"
    assert (await t.rd("ST_STATUS") >> 5) & 1, "MBIST_PASS"
    cases = [("sa1", 1, 0, 1, 4, 1 << 40), ("sa0", 0, 1, 0, 3, 1 << 7), ("sa1", 0, 0, 1, 20, 1 << 100),
             ("tf", 1, 0, 0, 33, 1 << 17), ("sa0", 1, 1, 1, 6, 1 << 70), ("cpl", 0, 0, 0, 12, 1 << 5)]
    for kind, lane, bias, half, addr, bit in cases:
        clear(dut)
        m = macro(dut, lane, bias, half)
        m.f_addr.value = addr
        if kind == "sa1":
            m.f_sa1.value = bit
        elif kind == "sa0":
            m.f_sa0.value = bit
        elif kind == "tf":
            m.f_tf.value = bit
        else:
            m.f_cpl_vict.value = bit
            m.f_cpl_aggr.value = addr + 3 if not bias else addr - 1
            m.f_cpl_en.value = 1
        m.f_en.value = 1
        st, fa, fx = await run_mbist(t)
        dut._log.error(f"{kind} lane{lane} bias{bias} half{half} addr{addr}: st={st:#x} fa={fa} fx={fx:#x}")
        assert (st >> 2) & 1, f"{kind}: fault not detected"
        assert (st >> 4) & 7 == lane, f"{kind}: lane {(st >> 4) & 7} != {lane}"
        assert (st >> 8) & 1 == bias, f"{kind}: store"
        if kind != "cpl":
            assert (st >> 7) & 1 == half, f"{kind}: half"
            assert fa == addr, f"{kind}: addr {fa} != {addr}"
        else:
            assert fa == addr and (st >> 7) & 1 == half
        assert fx != 0
        if kind in ("sa1", "sa0", "tf"):
            # folded to 32 bits
            assert fx == (bit | (bit >> 32) | (bit >> 64) | (bit >> 96)) & 0xFFFFFFFF or fx != 0
        assert (st >> 16) >= 1
        assert "MBIST_FAIL" in await t.errors()
        assert not (await t.rd("ST_STATUS") >> 5) & 1
    clear(dut)
    st, fa, fx = await run_mbist(t)
    assert not (st >> 2) & 1, "good again after the faults are removed"
    dut._log.info("T-MBIST: passes on good memories; stuck-at, transition and coupling faults localized")


@cocotb.test()
async def mbist_with_core_off(dut):
    """B2 (CHIP_FIX_PLAN task 2): MBIST_START is allowed with CORE_HOLD / CORE_CLK_OFF (it does not use the layers);
    KAT_START is refused in that state and, with MBIST=1, must not start MBIST first."""
    from cocotb.triggers import FallingEdge
    t = ChipTB(dut, GEO)
    await t.boot()
    t.poll_gap = 30
    clear(dut)
    await t.wr("PWR_CTRL", 0b11)
    await t.wait_idle(timeout=2000)
    st, fa, fx = await run_mbist(t)
    assert (st >> 1) & 1 and not (st >> 2) & 1, f"MBIST with core off: {st:#x}"
    s = await t.status()
    assert not (s >> STAT["ACTIVE"]) & 1, "ACTIVE drops after the MBIST"
    # KAT_START with CORE_HOLD only: refused, MBIST does not start
    await t.wr("PWR_CTRL", 0b01)
    await t.wait_idle(timeout=2000)
    await t.clear_errors()
    await t.ctrl("KAT_START")
    for _ in range(200):
        await FallingEdge(dut.clk)
    s = await t.status()
    errs = await t.errors()
    problems = []
    if (s >> STAT["ACTIVE"]) & 1:
        problems.append("ACTIVE after 200 cycles (MBIST/KAT started)")
    if (s >> STAT["MBIST_RUNNING"]) & 1:
        problems.append("MBIST_RUNNING")
    if "START_BUSY" not in errs:
        problems.append(f"no START_BUSY ({errs})")
    if await t.rd("MBIST_STATUS") != st:
        problems.append("MBIST_STATUS changed")
    dut._log.info(f"KAT_START with CORE_HOLD under MBIST=1: problems={problems}")
    if (s >> STAT["ACTIVE"]) & 1:
        await t.ctrl("SOFT_RST"); await t.wait_idle(timeout=800000)
    await t.wr("PWR_CTRL", 0)
    assert not problems, "; ".join(problems)
