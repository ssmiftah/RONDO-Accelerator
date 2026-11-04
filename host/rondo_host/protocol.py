"""SPI frame encoding/decoding (spec 5), CRC-8 framing, burst splitting."""
from . import regmap

OP_WRITE, OP_READ, OP_STATUS, OP_LOOPBACK, OP_NOP0, OP_NOP1 = 0x02, 0x03, 0x05, 0x0E, 0x00, 0xFF
SPIDEV_CHUNK = 4096


def crc8(data, crc=0):
    """CRC-8 poly 0x07, init 0, no reflection, no final XOR; crc8(b'123456789') == 0xF4."""
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def _hdr(op, addr, n):
    if not 1 <= n <= 65536:
        raise ValueError("burst length 1..65536 words")
    if not 0 <= addr < (1 << 24):
        raise ValueError("24-bit word address")
    return bytes([op, (addr >> 16) & 255, (addr >> 8) & 255, addr & 255, ((n - 1) >> 8) & 255, (n - 1) & 255])


def encode_write(addr, words, crc=False):
    hdr = _hdr(OP_WRITE, addr, len(words))
    out = bytearray(hdr)
    if crc:
        out.append(crc8(hdr))
    for w in words:
        wb = (int(w) & 0xFFFFFFFF).to_bytes(4, "big")
        out += wb
        if crc:
            out.append(crc8(wb))
    return bytes(out)


def encode_read(addr, n, crc=False):
    """-> (tx bytes, offset of the first data byte in the rx bytes)"""
    hdr = _hdr(OP_READ, addr, n)
    out = bytearray(hdr)
    if crc:
        out.append(crc8(hdr))
    out.append(0)                                   # dummy byte
    skip = len(out)
    out += bytes(n * (5 if crc else 4))
    return bytes(out), skip


def decode_read(rx, skip, n, crc=False):
    """-> (words, crc_ok)"""
    words, ok, p = [], True, skip
    for _ in range(n):
        wb = bytes(rx[p:p + 4]); p += 4
        if crc:
            ok &= rx[p] == crc8(wb); p += 1
        words.append(int.from_bytes(wb, "big"))
    return words, ok


def encode_loopback(data):
    return bytes([OP_LOOPBACK]) + bytes(data)


def decode_loopback(tx, rx):
    """MISO byte k+1 == MOSI byte k, first byte 0x00"""
    return rx[0] == 0 and bytes(rx[1:]) == bytes(tx[:-1])


def encode_status(nbytes=1):
    return bytes([OP_STATUS]) + bytes(nbytes)


def decode_status8(b):
    return {"signature_ok": (b & 3) == 2, "ERR_ANY": bool(b >> 7 & 1), "IRQ": bool(b >> 6 & 1),
            "SR_RUNNING": bool(b >> 5 & 1), "ACTIVE": bool(b >> 4 & 1), "BUSY": bool(b >> 3 & 1),
            "FORMAT": b >> 2 & 1, "raw": b}


def frame_bytes(op, n, crc):
    """bytes of a WRITE or READ frame carrying n words"""
    if op == OP_WRITE:
        return 6 + (1 if crc else 0) + n * (5 if crc else 4)
    return 6 + (1 if crc else 0) + 1 + n * (5 if crc else 4)


def split_burst(addr, n, op=OP_WRITE, crc=False, max_bytes=SPIDEV_CHUNK):
    """split n words at `addr` into frames of at most max_bytes: [(addr, count), ...]"""
    per = 5 if crc else 4
    fixed = 6 + (1 if crc else 0) + (1 if op == OP_READ else 0)
    cap = (max_bytes - fixed) // per
    if cap < 1:
        raise ValueError("max_bytes too small")
    out, done = [], 0
    while done < n:
        c = min(cap, n - done, 65536)
        out.append(((addr + done) & 0xFFFFFF, c))
        done += c
    return out
