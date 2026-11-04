"""Weight/bias packing (spec 1.4, 7.6), checksum (10.5), LOAD_CRC, KAT LFSR (11.5)."""
import zlib
import numpy as np
from . import regmap

MASK32 = 0xFFFFFFFF


def weight_addr(geom, j, k, c):
    """-> (lane, core address, field) of Wl[j, k, c]"""
    l, r = divmod(j, geom.nlad)
    b, s = divmod(r, geom.nslot)
    ch = s * geom.depth + k
    g, f = divmod(ch, geom.npar)
    return l, (b * geom.ngroup + g) * geom.pdim + c, f


def bias_addr(geom, j, k):
    l, r = divmod(j, geom.nlad)
    b, s = divmod(r, geom.nslot)
    ch = s * geom.depth + k
    g, f = divmod(ch, geom.npar)
    return l, b * geom.ngroup + g, f


def pack_weights(Wl_bits, Bl_bits, geom):
    """Wl_bits[j][k][c], Bl_bits[j][k] (element patterns) ->
    (W[lane] = array(nwords, npar), B[lane] = array(nbwords, npar)) of patterns."""
    Wl = np.asarray(Wl_bits, dtype=np.uint64)
    Bl = np.asarray(Bl_bits, dtype=np.uint64)
    assert Wl.shape == (geom.width, geom.depth, geom.pdim), Wl.shape
    W = np.zeros((geom.lanes, geom.nwords, geom.npar), dtype=np.uint64)
    B = np.zeros((geom.lanes, geom.nbwords, geom.npar), dtype=np.uint64)
    for j in range(geom.width):
        for k in range(geom.depth):
            l, a, f = bias_addr(geom, j, k)
            B[l, a, f] = Bl[j, k]
            for c in range(geom.pdim):
                l, a, f = weight_addr(geom, j, k, c)
                W[l, a, f] = Wl[j, k, c]
    return W, B


def unpack_weights(W, B, geom):
    Wl = np.zeros((geom.width, geom.depth, geom.pdim), dtype=np.uint64)
    Bl = np.zeros((geom.width, geom.depth), dtype=np.uint64)
    for j in range(geom.width):
        for k in range(geom.depth):
            l, a, f = bias_addr(geom, j, k)
            Bl[j, k] = B[l, a, f]
            for c in range(geom.pdim):
                l, a, f = weight_addr(geom, j, k, c)
                Wl[j, k, c] = W[l, a, f]
    return Wl, Bl


def weight_stream(geom, W, lane):
    """flat element list of one lane in burst order (addr 0 f 0..7, addr 1 f 0..7, ...)"""
    return [int(v) for v in W[lane].reshape(-1)]


def rotl32(v, r):
    r %= 32
    v &= MASK32
    return v if r == 0 else ((v << r) | (v >> (32 - r))) & MASK32


def fold(z_words, W):
    return sum(rotl32(int(z) & ((1 << W) - 1), j % 32) for j, z in enumerate(z_words)) & MASK32


def update(checksum, z_words, W):
    return (rotl32(checksum, 1) + fold(z_words, W)) & MASK32


def load_crc(values, W):
    """CRC-32 (IEEE) over the W/8 little-endian bytes of every accepted weight/bias write"""
    return zlib.crc32(b"".join(int(v & ((1 << W) - 1)).to_bytes(W // 8, "little") for v in values)) & MASK32


def crc32_chain(crc_prev, load_crc_value):
    """TILE_SEQ_CRC step: CRC-32 chained over the 4 little-endian bytes of LOAD_CRC"""
    return zlib.crc32(int(load_crc_value & MASK32).to_bytes(4, "little"), crc_prev) & MASK32


# ---- KAT element stream (spec 11.5) ---------------------------------------------------
KAT_TAPS = 0x80200003
KAT_SEED = 0x1D872B41


class Lfsr:
    """32-bit Galois LFSR, polynomial x^32+x^22+x^2+x+1 (taps 0x80200003). Each call to
    next() advances the register once and returns the NEW 32-bit state r."""

    def __init__(self, seed=KAT_SEED):
        self.s = seed & MASK32

    def next(self):
        lsb = self.s & 1
        self.s >>= 1
        if lsb:
            self.s ^= KAT_TAPS
        return self.s


def kat_element(r, W):
    """sign = r[31]; exponent = BIAS-2 + r[30:29]; mantissa = r[28 -: SIG-1] (bf16 7, fp32 23)"""
    sig = 8 if W == 16 else 24
    bias = 127
    fr = sig - 1
    s = (r >> 31) & 1
    e = bias - 2 + ((r >> 29) & 3)
    m = (r >> (29 - fr)) & ((1 << fr) - 1)
    return (s << (W - 1)) | (e << fr) | m


def kat_stream(geom, W, nxbuf=None, seed=KAT_SEED):
    """-> (W array [lanes, nwords, npar], B array [lanes, nbwords, npar], X [nxbuf][pdim])
    in the order: all weight elements (lane, address, field), all bias elements, XBUF entries."""
    nx = geom.nxbuf if nxbuf is None else nxbuf
    L = Lfsr(seed)
    Wd = np.zeros((geom.lanes, geom.nwords, geom.npar), dtype=np.uint64)
    Bd = np.zeros((geom.lanes, geom.nbwords, geom.npar), dtype=np.uint64)
    for l in range(geom.lanes):
        for a in range(geom.nwords):
            for f in range(geom.npar):
                Wd[l, a, f] = kat_element(L.next(), W)
    for l in range(geom.lanes):
        for a in range(geom.nbwords):
            for f in range(geom.npar):
                Bd[l, a, f] = kat_element(L.next(), W)
    X = [[kat_element(L.next(), W) for _ in range(geom.pdim)] for _ in range(nx)]
    return Wd, Bd, X
