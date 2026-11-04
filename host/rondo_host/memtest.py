"""Host-side memory test of the tiling stores over SPI (CHIP_FIX_PLAN task 13.1, decision D1(a)): March C- on every mapped PS element and TX word.

The march is a generator of bus operations so that the same algorithm drives the blocking SPI API (Rondo.mem_test) and the cocotb rbus bench:

    gen = march(geom, ("PS", "TX"), W)
    op = next(gen)                        # ("w", addr, [words]) or ("r", addr, n)
    ...  result = <perform op>            # None for a write, the list of words for a read
    op = gen.send(result)                 # ... until StopIteration; its value is the list of failures

March C- element order (as spec 11.6): up(w0); up(r0,w1); up(r1,w0); down(r0,w1); down(r1,w0); down(r0), for two data backgrounds
(0/1 and 5/A). The test works on bursts (one burst = the elements of one (input, lane) of the PS or of one input of the TX), so a "r,w"
element is "read the burst, write the burst": single-cell stuck-at and transition faults and coupling between bursts are covered in the march
order, coupling inside one burst only partly. A failure is (region, b, lane, group, field, xor): for TX lane and group are None and field is
the word index; xor is the OR over all patterns of expected ^ read-back at that location.

Not covered: TZ (read-only from the host: covered functionally by the tiled T-SUITE case and T-TILE), the unmapped PS rows (group >= NGROUP).
"""

BACKGROUNDS = ((0x00000000, 0xFFFFFFFF), (0x55555555, 0xAAAAAAAA))


def _chunks(geom, region):
    """[(base_addr, n, [location tuple per element])] for one region"""
    out = []
    if region == "PS":
        for b in range(geom.tile_b):
            for l in range(geom.lanes):
                locs = [("PS", b, l, gg, f) for gg in range(geom.nbwords) for f in range(geom.npar)]
                out.append((geom.ps_addr(b, l, 0, 0), len(locs), locs))
    elif region == "TX":
        for b in range(geom.tile_b):
            out.append((geom.tx_addr(b, 0), geom.pdim, [("TX", b, None, None, i) for i in range(geom.pdim)]))
    else:
        raise ValueError(f"mem_test region {region!r}: only 'PS' and 'TX' (TZ is read-only from the host)")
    return out


def march(geom, regions, W):
    """generator, see the module docstring; W = 16 (bf16) or 32 (fp32): the element width of PS and TX in the current format"""
    chunks = []
    for r in regions:
        wmask = (1 << W) - 1                 # host writes are masked to the format width (bf16 16 bits / fp32 32 bits) for PS and TX alike
        chunks += [(wmask,) + c for c in _chunks(geom, r)]
    xor = {}

    def fill(wmask, n, v):
        return [v & wmask] * n

    def rd_check(wmask, base, n, locs, v):
        got = yield ("r", base, n)
        exp = v & wmask
        for k, g in enumerate(got):
            d = (int(g) & wmask) ^ exp
            if d:
                xor[locs[k]] = xor.get(locs[k], 0) | d

    for bg0, bg1 in BACKGROUNDS:
        order_up = chunks
        order_dn = chunks[::-1]
        for wmask, base, n, locs in order_up:                       # up(w0)
            yield ("w", base, fill(wmask, n, bg0))
        for wmask, base, n, locs in order_up:                       # up(r0,w1)
            yield from rd_check(wmask, base, n, locs, bg0)
            yield ("w", base, fill(wmask, n, bg1))
        for wmask, base, n, locs in order_up:                       # up(r1,w0)
            yield from rd_check(wmask, base, n, locs, bg1)
            yield ("w", base, fill(wmask, n, bg0))
        for wmask, base, n, locs in order_dn:                       # down(r0,w1)
            yield from rd_check(wmask, base, n, locs, bg0)
            yield ("w", base, fill(wmask, n, bg1))
        for wmask, base, n, locs in order_dn:                       # down(r1,w0)
            yield from rd_check(wmask, base, n, locs, bg1)
            yield ("w", base, fill(wmask, n, bg0))
        for wmask, base, n, locs in order_dn:                       # down(r0)
            yield from rd_check(wmask, base, n, locs, bg0)
    return [loc + (x,) for loc, x in sorted(xor.items(), key=lambda kv: tuple(-1 if v is None else v for v in kv[0][1:]))]


def run_blocking(gen, read, write):
    """drive a march generator with blocking read(addr, n) / write(addr, words) callables"""
    try:
        op = next(gen)
        while True:
            if op[0] == "w":
                write(op[1], op[2]); res = None
            else:
                res = read(op[1], op[2])
            op = gen.send(res)
    except StopIteration as e:
        return e.value


async def run_async(gen, read, write):
    """drive a march generator with coroutine read(addr, n) / write(addr, words) callables (cocotb rbus bench)"""
    try:
        op = next(gen)
        while True:
            if op[0] == "w":
                await write(op[1], op[2]); res = None
            else:
                res = await read(op[1], op[2])
            op = gen.send(res)
    except StopIteration as e:
        return e.value
