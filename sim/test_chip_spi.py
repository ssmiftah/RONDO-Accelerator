import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, FallingEdge
from rondo_spi_bfm import SpiBfm, crc8
from rondo_rbus_bfm import RbusResponder

PERIOD = 10.0


async def sva_watch(dut):
    while True:
        await FallingEdge(dut.clk)
        v = dut.sva_viol.value
        if v.is_resolvable and int(v):
            raise AssertionError(f"SPI protocol checker violation {int(v):#x}")


async def setup(dut, ratio=8.0, seed=1):
    cocotb.start_soon(Clock(dut.clk, PERIOD, unit="ns").start())
    dut.status8.value = 0x82
    cocotb.start_soon(sva_watch(dut))
    dut.crc_en.value = 0
    dut.rst_n.value = 0
    bfm = SpiBfm(dut.spi_sclk, dut.spi_cs_n, dut.spi_mosi, dut.spi_miso, PERIOD, ratio, seed)
    rsp = RbusResponder(dut, dut.clk, "rb_", max_ready_delay=3, max_rsp_delay=3, seed=seed + 7)
    cocotb.start_soon(rsp.run())
    await Timer(55, unit="ns")
    dut.rst_n.value = 1
    await Timer(100, unit="ns")
    return bfm, rsp


def rd_default(addr):
    return (addr * 0x01010101) & 0xFFFFFFFF


@cocotb.test()
async def basic_opcodes(dut):
    bfm, rsp = await setup(dut)
    assert int(dut.spi_miso_oe.value) == 0, "MISO must be tri-stated while CS is high"
    # loopback
    rng = random.Random(5)
    for n in (1, 2, 16, 40):
        tx = bytes([0x0E] + [rng.getrandbits(8) for _ in range(n)])
        rx = await bfm.xfer(tx)
        assert rx[0] == 0 and rx[1:] == tx[:-1], f"loopback {rx.hex()} vs {tx.hex()}"
    # status
    rx = await bfm.xfer(bytes([0x05, 0, 0, 0, 0]))
    assert rx[0] == 0 and all(b == 0x82 for b in rx[1:]), rx.hex()
    dut.status8.value = 0xA6
    rx = await bfm.xfer(bytes([0x05] + [0] * 6))
    assert rx[1:] == bytes([0xA6] * 6)
    # NOPs and unknown opcode
    e0 = int(dut.err_frame_cnt.value)
    assert await bfm.xfer(bytes([0x00, 0x11, 0x22])) == bytes(3)
    assert await bfm.xfer(bytes([0xFF, 0x11, 0x22])) == bytes(3)
    assert int(dut.err_frame_cnt.value) == e0
    assert await bfm.xfer(bytes([0x77, 0x11, 0x22, 0x33])) == bytes(4)
    assert int(dut.err_frame_cnt.value) == e0 + 1, "unknown opcode must flag SPI_FRAME"
    assert len(rsp.log) == 0, "no rbus access expected"
    assert crc8(b"123456789") == 0xF4


@cocotb.test()
async def write_read_bursts(dut):
    bfm, rsp = await setup(dut, ratio=8.0, seed=3)
    for crc in (0, 1):
        dut.crc_en.value = crc
        await Timer(100, unit="ns")
        rng = random.Random(9 + crc)
        for n in (1, 2, 3, 17, 255, 256):
            base = rng.getrandbits(20) << 2
            words = [rng.getrandbits(32) for _ in range(n)]
            rsp.log.clear()
            await bfm.write(base, words, crc=bool(crc))
            await Timer(2000, unit="ns")
            assert [(w[1], w[2]) for w in rsp.log if w[0]] == [(base + i, words[i]) for i in range(n)], \
                f"write burst {n} crc={crc}"
            assert len(rsp.log) == n
            rsp.log.clear()
            got, ok = await bfm.read(base, n, crc=bool(crc))
            assert ok, "read DCRC mismatch"
            assert got == [words[i] for i in range(n)], f"read burst {n} crc={crc}"
            assert len(rsp.log) == n and all(not e[0] for e in rsp.log), "exactly N+1 reads"
            assert [e[1] for e in rsp.log] == [base + i for i in range(n)]
        # extra bytes clocked beyond the burst return 0, no extra access
        rsp.log.clear()
        tx, skip = SpiBfm.build_read(0x1234, 2, crc=bool(crc), extra=9)
        rx = await bfm.xfer(tx)
        assert len(rsp.log) == 2
        assert rx[skip + (10 if crc else 8):] == bytes(9), "bytes beyond the burst must read 0"
        assert int(dut.err_frame_cnt.value) == 0, "no frame errors expected"


@cocotb.test()
async def crc_and_aborts(dut):
    bfm, rsp = await setup(dut, seed=11)
    dut.crc_en.value = 1
    await Timer(100, unit="ns")
    base = 0x000100
    # corrupted header crc: ignored, SPI_CRC
    f = bytearray(SpiBfm.build_write(base, [1, 2], crc=True))
    f[6] ^= 0x10
    c0 = int(dut.err_crc_cnt.value)
    await bfm.xfer(bytes(f)); await Timer(500, unit="ns")
    assert int(dut.err_crc_cnt.value) == c0 + 1 and not rsp.log
    # corrupted DCRC on the 2nd word: the 1st is written, 2nd and later are dropped
    f = bytearray(SpiBfm.build_write(base, [10, 20, 30], crc=True))
    f[7 + 5 + 4] ^= 0x01            # second word's DCRC byte
    await bfm.xfer(bytes(f)); await Timer(500, unit="ns")
    assert [(w[1], w[2]) for w in rsp.log] == [(base, 10)]
    assert int(dut.err_crc_cnt.value) == c0 + 2
    rsp.log.clear()
    # abort mid-header and mid-word: SPI_FRAME, nothing issued
    e0 = int(dut.err_frame_cnt.value)
    f = SpiBfm.build_write(base, [1, 2, 3], crc=True)
    await bfm.abort(f, 8 * 4)                  # mid header
    await bfm.abort(f, 8 * 7 + 8 * 2)          # mid word 0
    await bfm.abort(f, 8 * 7 + 8 * 5 + 8 * 2)  # mid word 1 (word 0 issued)
    await Timer(500, unit="ns")
    assert int(dut.err_frame_cnt.value) == e0 + 3, "three aborts must flag SPI_FRAME"
    assert [(w[1], w[2]) for w in rsp.log] == [(base, 1)]
    rsp.log.clear()
    # abort on a word boundary shortens the burst without error
    e0 = int(dut.err_frame_cnt.value)
    await bfm.abort(f, 8 * 7 + 8 * 5)
    await Timer(500, unit="ns")
    assert int(dut.err_frame_cnt.value) == e0 and len(rsp.log) == 1
    # a CRC-off frame after turning CRC off (takes effect from the next frame)
    dut.crc_en.value = 0
    await Timer(100, unit="ns")
    rsp.log.clear()
    await bfm.write(0x40, [0xCAFEBABE])
    await Timer(500, unit="ns")
    assert [(w[1], w[2]) for w in rsp.log] == [(0x40, 0xCAFEBABE)]


@cocotb.test()
async def ratios_random_phase(dut):
    bfm, rsp = await setup(dut, ratio=6.0, seed=60)
    for ratio in (6.0, 7.0, 8.0, 13.0, 16.0, 33.0):
        bfm.set_ratio(ratio)
        rng = random.Random(int(ratio))
        for crc in (0, 1):
            dut.crc_en.value = crc
            await Timer(100, unit="ns")
            nfr = 100
            e0 = int(dut.err_frame_cnt.value)
            for i in range(nfr):
                n = rng.choice((1, 2, 3))
                base = rng.getrandbits(16) << 2
                words = [rng.getrandbits(32) for _ in range(n)]
                rsp.log.clear()
                await bfm.write(base, words, crc=bool(crc))
                await Timer(rng.randint(1, 700), unit="ns")
                assert [(w[1], w[2]) for w in rsp.log] == [(base + k, words[k]) for k in range(n)], \
                    f"R={ratio} write frame {i}"
                got, ok = await bfm.read(base, n, crc=bool(crc))
                if not (ok and got == words):
                    dut._log.error(f"log={[(e[0], hex(e[1]), hex(e[2])) for e in rsp.log]} got={[hex(g) for g in got]} want={[hex(w) for w in words]}")
                assert ok and got == words, f"R={ratio} read frame {i}: {got} vs {words}"
                if i % 10 == 0:
                    tx = bytes([0x0E] + [rng.getrandbits(8) for _ in range(5)])
                    rx = await bfm.xfer(tx)
                    assert rx[1:] == tx[:-1]
            assert int(dut.err_frame_cnt.value) == e0, f"R={ratio}: unexpected frame errors"
        dut._log.info(f"SPI ratio R={ratio}: {2*nfr} frames OK")


@cocotb.test()
async def overrun_is_visible(dut):
    bfm, rsp = await setup(dut, ratio=8.0, seed=21)
    dut.crc_en.value = 0
    rsp.max_rsp_delay = 0
    rsp.rsp_extra = 120            # rbus response slower than a byte time
    e0 = int(dut.err_frame_cnt.value)
    got, ok = await bfm.read(0x10, 2)
    assert int(dut.err_frame_cnt.value) > e0, "overrun must set SPI_FRAME"
    assert 0xDEADBEEF in got, f"late word must read 0xDEADBEEF, got {[hex(g) for g in got]}"
    rsp.rsp_extra = 0
    await Timer(3000, unit="ns")
    got, ok = await bfm.read(0x10, 2)
    assert got == [rd_default(0x10), rd_default(0x11)]


@cocotb.test()
async def stray_read_response(dut):
    """A READ whose CS rises right after the header must not leak its late response into the next frame (found by
    the spi_ctrl formal harness)."""
    bfm, rsp = await setup(dut, ratio=8.0, seed=33)
    dut.crc_en.value = 0
    rsp.max_rsp_delay = 0
    rsp.rsp_extra = 25
    tx, skip = SpiBfm.build_read(0x20, 4)
    e0 = int(dut.err_frame_cnt.value)
    await bfm.abort(tx, 8 * 6)                     # exactly the header, then CS rises
    rx = await bfm.xfer(bytes(24))                 # a NOP frame while the old response arrives
    assert rx == bytes(24), f"stray byte leaked into the next frame: {rx.hex()}"
    assert int(dut.err_frame_cnt.value) == e0
    rsp.rsp_extra = 0
    await Timer(2000, unit="ns")
    got, ok = await bfm.read(0x20, 2)
    assert got == [rd_default(0x20), rd_default(0x21)]
