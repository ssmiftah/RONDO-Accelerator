"""Hand-written SPI master bus-functional model (mode 0, MSB first) for cocotb.

SCLK period is any rational multiple R of the core clock period, with a random phase
relative to the core clock. MISO is sampled at the instant of the SCLK rising edge, the worst
case of spec 5.6. Also provides frame builders with optional CRC-8.
"""
import random
from cocotb.triggers import Timer


def crc8(data, crc=0):
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


class SpiBfm:
    def __init__(self, sclk, cs_n, mosi, miso, core_period_ns=10.0, ratio=8.0, seed=1,
                 cs_setup_half=1.0, oe=None):
        self.sclk, self.cs_n, self.mosi, self.miso = sclk, cs_n, mosi, miso
        self.oe = oe
        self.cp_ps = int(core_period_ns * 1000)
        self.set_ratio(ratio)
        self.rng = random.Random(seed)
        self.cs_gap_half = cs_setup_half
        self.oe_violations = 0
        sclk.value = 0; cs_n.value = 1; mosi.value = 0

    def set_ratio(self, ratio):
        self.ratio = ratio
        self.period_ps = max(2, int(round(ratio * self.cp_ps)))
        self.half_ps = self.period_ps // 2

    async def idle(self, cycles=4):
        await Timer(int(cycles * self.cp_ps), unit="ps")

    async def xfer(self, tx, phase=True):
        """One CS frame: returns the bytes seen on MISO (same length as tx)."""
        if phase:
            await Timer(self.rng.randint(1, self.cp_ps), unit="ps")
        self.cs_n.value = 0
        await Timer(int(self.half_ps * self.cs_gap_half), unit="ps")
        rx = bytearray()
        for byte in tx:
            r = 0
            for i in range(7, -1, -1):
                self.mosi.value = (byte >> i) & 1
                await Timer(self.half_ps, unit="ps")
                bit = self.miso.value
                bit = int(bit) if bit.is_resolvable else 0
                r = (r << 1) | bit
                self.sclk.value = 1
                await Timer(self.half_ps, unit="ps")
                self.sclk.value = 0
            rx.append(r)
        await Timer(self.half_ps, unit="ps")
        self.cs_n.value = 1
        await Timer(self.period_ps, unit="ps")
        return bytes(rx)

    async def abort(self, tx, nbits):
        """Clock nbits of tx then raise CS (mid-byte / mid-word abort)."""
        await Timer(self.rng.randint(1, self.cp_ps), unit="ps")
        self.cs_n.value = 0
        await Timer(self.half_ps, unit="ps")
        for k in range(nbits):
            byte = tx[k // 8]
            self.mosi.value = (byte >> (7 - k % 8)) & 1
            await Timer(self.half_ps, unit="ps")
            self.sclk.value = 1
            await Timer(self.half_ps, unit="ps")
            self.sclk.value = 0
        await Timer(self.half_ps, unit="ps")
        self.cs_n.value = 1
        await Timer(self.period_ps, unit="ps")

    # ---- frame builders (independent of rondo_host) --------------------------
    @staticmethod
    def build_write(addr, words, crc=False):
        hdr = bytes([0x02, (addr >> 16) & 255, (addr >> 8) & 255, addr & 255,
                     ((len(words) - 1) >> 8) & 255, (len(words) - 1) & 255])
        out = bytearray(hdr)
        if crc:
            out.append(crc8(hdr))
        for w in words:
            wb = int(w).to_bytes(4, "big")
            out += wb
            if crc:
                out.append(crc8(wb))
        return bytes(out)

    @staticmethod
    def build_read(addr, n, crc=False, extra=0):
        hdr = bytes([0x03, (addr >> 16) & 255, (addr >> 8) & 255, addr & 255,
                     ((n - 1) >> 8) & 255, (n - 1) & 255])
        out = bytearray(hdr)
        if crc:
            out.append(crc8(hdr))
        out.append(0)                                   # dummy
        out += bytes((5 if crc else 4) * n + extra)
        return bytes(out), len(hdr) + (1 if crc else 0) + 1

    @staticmethod
    def parse_read(rx, skip, n, crc=False):
        words, ok = [], True
        p = skip
        for _ in range(n):
            wb = bytes(rx[p:p + 4]); p += 4
            if crc:
                ok &= (rx[p] == crc8(wb)); p += 1
            words.append(int.from_bytes(wb, "big"))
        return words, ok

    async def write(self, addr, words, crc=False):
        return await self.xfer(self.build_write(addr, words, crc))

    async def read(self, addr, n, crc=False):
        tx, skip = self.build_read(addr, n, crc)
        rx = await self.xfer(tx)
        return self.parse_read(rx, skip, n, crc)
