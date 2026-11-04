"""T-UNITS packer: packing, read cache, CRC-32, PARTIAL (rondo_wpack + rondo_wmem)."""
import random, zlib
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

NL, NP, NW, NB = 2, 8, 56, 7


def si(v):
    return int(str(v).lower().replace('x', '0').replace('z', '0'), 2)



async def init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for s in ("fmt", "wr_stb", "rd_stb", "region_bias", "lane", "caddr", "field", "wdata", "crc_clr",
              "cache_inval", "flush_staging", "wm_addr", "bm_addr", "mem_act"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await Timer(32, unit="ns"); dut.rst_n.value = 1
    await FallingEdge(dut.clk)


async def wr(dut, bias, lane, caddr, field, val, gap=1):
    dut.wr_stb.value = 1; dut.region_bias.value = bias; dut.lane.value = lane
    dut.caddr.value = caddr; dut.field.value = field; dut.wdata.value = val
    await FallingEdge(dut.clk)
    dut.wr_stb.value = 0
    for _ in range(gap):
        await FallingEdge(dut.clk)


async def rd(dut, bias, lane, caddr, field):
    dut.rd_stb.value = 1; dut.region_bias.value = bias; dut.lane.value = lane
    dut.caddr.value = caddr; dut.field.value = field
    await FallingEdge(dut.clk)
    dut.rd_stb.value = 0
    n = 1
    while not int(dut.rd_valid.value):
        await FallingEdge(dut.clk); n += 1
        assert n < 12, "read latency exceeds the 4-cycle budget by far"
    return si(dut.rd_data.value), n


async def layer_read(dut, bias, lane, addr):
    dut.mem_act.value = 1 << lane
    if bias:
        dut.bm_addr.value = addr << (3 * lane)
    else:
        dut.wm_addr.value = addr << (6 * lane)
    await FallingEdge(dut.clk)
    dut.mem_act.value = 0
    await FallingEdge(dut.clk)
    sh = 128 * lane
    m = (1 << 128) - 1
    if bias:
        return (si(dut.bm_q_h.value) >> sh) & m, (si(dut.bm_q_l.value) >> sh) & m
    return (si(dut.wm_q_h.value) >> sh) & m, (si(dut.wm_q_l.value) >> sh) & m


@cocotb.test()
async def packing_crc_cache(dut):
    await init(dut)
    rng = random.Random(8)
    for fmt in (0, 1):
        W = 32 if fmt else 16
        dut.fmt.value = fmt
        dut.crc_clr.value = 1
        await FallingEdge(dut.clk); dut.crc_clr.value = 0
        assert int(dut.load_crc.value) == 0
        # write all core words (elements in shuffled core-word order, ascending field order inside)
        order = [(b, l, a) for b in (0, 1) for l in range(NL) for a in range(NB if b else NW)]
        rng.shuffle(order)
        ref, vals = {}, []
        for (b, l, a) in order:
            els = [rng.getrandbits(W) for _ in range(NP)]
            ref[(b, l, a)] = els
            for f in range(NP):
                await wr(dut, b, l, a, f, els[f])
                vals.append(els[f])
        await Timer(1, unit="ns")
        for _ in range(4):
            await FallingEdge(dut.clk)
        assert int(dut.load_crc.value) == zlib.crc32(b"".join(v.to_bytes(W // 8, "little") for v in vals))
        assert int(dut.err_partial.value) == 0
        # contents as seen by the layer
        for (b, l, a), els in list(ref.items())[::5]:
            h, lo = await layer_read(dut, b, l, a)
            for f in range(NP):
                eh = (els[f] >> 16) if fmt else els[f]
                assert (h >> (16 * f)) & 0xFFFF == eh
                if fmt:
                    assert (lo >> (16 * f)) & 0xFFFF == els[f] & 0xFFFF
        # read-back through the cache: one memory read per core word
        r0 = int(dut.wmem_reads.value)
        (b, l, a), els = next(iter(ref.items()))
        for f in range(NP):
            v, n = await rd(dut, b, l, a, f)
            assert v == els[f], (fmt, f)
            if f:
                assert n <= 3, "cache hit latency"
        assert int(dut.wmem_reads.value) - r0 == 1, "burst over the fields must read the memory once"
        # a write invalidates the cache
        await wr(dut, b, l, a, 0, 0x1234 if not fmt else 0x12345678)
        for f in range(1, NP):
            await wr(dut, b, l, a, f, els[f])
        v, n = await rd(dut, b, l, a, 0)
        assert v == (0x1234 if not fmt else 0x12345678)
        # cache_inval
        dut.cache_inval.value = 1; await FallingEdge(dut.clk); dut.cache_inval.value = 0
        r0 = int(dut.wmem_reads.value)
        await rd(dut, b, l, a, 2)
        assert int(dut.wmem_reads.value) - r0 == 1
        # latency bound
        _, n = await rd(dut, 1, 0, 3, 5)
        assert n <= 5


@cocotb.test()
async def partial_cases(dut):
    await init(dut)
    dut.fmt.value = 1
    perr = 0
    async def watch():
        nonlocal perr
        while True:
            await FallingEdge(dut.clk)
            perr += int(dut.err_partial.value)
    cocotb.start_soon(watch())
    # (a) full ascending word: no PARTIAL
    for f in range(8):
        await wr(dut, 0, 0, 10, f, 0x01010101 * (f + 1))
    await FallingEdge(dut.clk)
    assert perr == 0
    # (b) commit with a missing field: PARTIAL, missing field reads 0
    await wr(dut, 0, 0, 11, 0, 0xAAAA5555)
    await wr(dut, 0, 0, 11, 7, 0xBBBB6666)
    await FallingEdge(dut.clk)
    assert perr == 1
    v, _ = await rd(dut, 0, 0, 11, 3)
    assert v == 0
    v, _ = await rd(dut, 0, 0, 11, 7)
    assert v == 0xBBBB6666
    old12, _ = await rd(dut, 0, 0, 12, 0)
    # (c) tag changes with fields pending: PARTIAL and the stale fields are discarded
    await wr(dut, 0, 0, 12, 0, 0x11112222)
    await wr(dut, 0, 0, 13, 0, 0x33334444)
    await FallingEdge(dut.clk)
    assert perr == 2
    for f in range(1, 8):
        await wr(dut, 0, 0, 13, f, 0x0F0F0F0F)       # completes word 13 (field 0 present, no PARTIAL)
    await FallingEdge(dut.clk)
    assert perr == 2
    v, _ = await rd(dut, 0, 0, 13, 0)
    assert v == 0x33334444
    v, _ = await rd(dut, 0, 0, 12, 0)
    assert v == old12, "word 12 was never committed (content unchanged)"
