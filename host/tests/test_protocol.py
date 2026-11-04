import random
from rondo_host import protocol as P


def test_crc8_check_value():
    assert P.crc8(b"123456789") == 0xF4


def test_write_example_from_spec():
    # spec 5.5: register write SCRATCH (0x000009) <- 0xA5A55A5A
    assert P.encode_write(9, [0xA5A55A5A]).hex() == "020000090000a5a55a5a"


def test_read_example_from_spec():
    tx, skip = P.encode_read(0x020000, 64)
    assert tx[:6].hex() == "03020000003f" and tx[6] == 0 and len(tx) == 7 + 256 and skip == 7


def test_crc_framing_roundtrip():
    rng = random.Random(1)
    words = [rng.getrandbits(32) for _ in range(5)]
    f = P.encode_write(0x100, words, crc=True)
    assert f[6] == P.crc8(f[:6])
    for i, w in enumerate(words):
        wb = f[7 + 5 * i: 11 + 5 * i]
        assert int.from_bytes(wb, "big") == w and f[11 + 5 * i] == P.crc8(wb)
    tx, skip = P.encode_read(0x100, 3, crc=True)
    rx = bytearray(len(tx))
    ws = [1, 2, 0xFFFFFFFF]
    p = skip
    for w in ws:
        b = w.to_bytes(4, "big"); rx[p:p + 4] = b; rx[p + 4] = P.crc8(b); p += 5
    assert P.decode_read(rx, skip, 3, crc=True) == (ws, True)
    rx[skip + 4] ^= 1
    assert P.decode_read(rx, skip, 3, crc=True)[1] is False


def test_loopback_and_status():
    tx = P.encode_loopback(bytes(range(10)))
    rx = bytes([0]) + tx[:-1]
    assert P.decode_loopback(tx, rx)
    assert not P.decode_loopback(tx, bytes(len(tx)))
    s = P.decode_status8(0x82)
    assert s["signature_ok"] and s["ERR_ANY"] and not s["ACTIVE"]
    assert not P.decode_status8(0x83)["signature_ok"]


def test_split_burst():
    parts = P.split_burst(0x800000, 2240, P.OP_WRITE)
    assert sum(c for _, c in parts) == 2240 and all(P.frame_bytes(P.OP_WRITE, c, False) <= 4096 for _, c in parts)
    assert parts[0] == (0x800000, 1022) and parts[1][0] == 0x800000 + 1022
    parts = P.split_burst(0, 3000, P.OP_READ, crc=True)
    assert all(P.frame_bytes(P.OP_READ, c, True) <= 4096 for _, c in parts) and sum(c for _, c in parts) == 3000
