"""Cross-check of verif/model/rondo_fpmodel.c (ctypes, gcc-built libfpm.so) against sim/fpmodel.py, sim/chip_common.py
and host/rondo_host/packing.py. Run: .venv-rtl/bin/python -I verif/model/test_fpmodel_c.py [--quick]"""
import sys, ctypes, random, os, zlib
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "sim"), str(ROOT / "host")]
import fpmodel as fm
import chip_common as cc
from rondo_host import packing as pk, protocol as pr

lib = ctypes.CDLL(str(ROOT / "build/verif/model/libfpm.so"))
u64, i32, u32 = ctypes.c_uint64, ctypes.c_int, ctypes.c_uint32
lib.fpm_fma.restype = u64; lib.fpm_fma.argtypes = [i32, i32, u64, u64, u64]
lib.fpm_z.restype = u64; lib.fpm_a.restype = u64; lib.fpm_k0.restype = u64; lib.fpm_k1.restype = u64; lib.fpm_acc.restype = u64
lib.fpm_a.argtypes = [i32, i32]; lib.fpm_acc.argtypes = [i32, i32]; lib.fpm_z.argtypes = [i32]; lib.fpm_hit.argtypes = [i32]
lib.fpm_set_w.argtypes = [i32, i32, i32, u64]; lib.fpm_set_b.argtypes = [i32, i32, i32, u64]; lib.fpm_set_x.argtypes = [i32, u64]
lib.fpm_cfg.argtypes = [i32] * 7; lib.fpm_run.argtypes = [i32] * 5; lib.fpm_tile_slice.argtypes = [i32] * 7
lib.fpm_load_seed.argtypes = [i32, i32, ctypes.c_char_p]
lib.fpm_crc8.restype = u32; lib.fpm_crc8.argtypes = [u32, u32]
lib.fpm_crc32_update.restype = u32; lib.fpm_crc32_update.argtypes = [u32, u32, i32]
lib.fpm_cksum_update.restype = u32; lib.fpm_cksum_update.argtypes = [u32, i32]
lib.fpm_rotl32.restype = u32; lib.fpm_rotl32.argtypes = [u32, i32]
lib.fpm_lfsr_next.restype = u32; lib.fpm_lfsr_next.argtypes = [u32]
lib.fpm_kat_element.restype = u64; lib.fpm_kat_element.argtypes = [u32, i32]
lib.fpm_recip.restype = u64; lib.fpm_recip.argtypes = [i32, i32, i32, u64, u64]
lib.fpm_k0.argtypes = [i32]; lib.fpm_k1.argtypes = [i32]
seeddir = str(ROOT / "rtl/core").encode()
for sig, tb in ((8, 6), (24, 8), (24, 12)):
    assert lib.fpm_load_seed(sig, tb, seeddir) == 0

QUICK = "--quick" in sys.argv
N_FMA = 20000 if QUICK else 1_000_000
N_REC = 2000 if QUICK else 100_000
N_LAYER = 20 if QUICK else 300
N_FULL = 1 if QUICK else 4
N_TILE = 8 if QUICK else 50
rng = random.Random(12345)
fails = 0


def fail(msg):
    global fails
    fails += 1
    if fails < 20:
        print("MISMATCH", msg)


def rnd_pat(f):
    s = rng.getrandbits(1)
    k = rng.random()
    if k < 0.1: e = 0
    elif k < 0.2: e = (1 << f.exp) - 2
    elif k < 0.5: e = f.bias + rng.randint(-8, 8)
    else: e = rng.randint(0, (1 << f.exp) - 2)
    k = rng.random()
    m = 0 if k < 0.15 else ((1 << f.fr) - 1 if k < 0.3 else rng.getrandbits(f.fr))
    return (s << (f.w - 1)) | (e << f.fr) | m


def edge_list(f):
    ex = [0, 1, 2, f.bias - 1, f.bias, f.bias + 1, (1 << f.exp) - 3, (1 << f.exp) - 2]
    ms = [0, 1, (1 << f.fr) - 1, 1 << (f.fr - 1)]
    return [(s << (f.w - 1)) | (e << f.fr) | m for s in (0, 1) for e in ex for m in ms]


for (ex, sg) in ((8, 8), (8, 24), (8, 16)):
    f = fm.Fmt(ex, sg)
    n = 0
    E = edge_list(f)
    cases = [(a, b, c) for a in E for b in E[::5] for c in E[::3]]
    bad = 0
    while len(cases) < N_FMA:
        a, b = rnd_pat(f), rnd_pat(f)
        k = rng.random()
        if k < 0.25:            # near-cancellation: c ~ -(a*b)
            p = fm.fma(f, a, b, 0)
            c = p ^ (1 << (f.w - 1))
            if fm.is_special(f, c): c = rnd_pat(f)
            else: c = c + rng.choice((-1, 0, 0, 1)) if (c & ((1 << f.fr) - 1)) not in (0, (1 << f.fr) - 1) else c
        else:
            c = rnd_pat(f)
        cases.append((a, b, c))
    for a, b, c in cases:
        r = lib.fpm_fma(ex, sg, a, b, c)
        e = fm.fma(f, a, b, c)
        if r != e:
            bad += 1; fail(f"fma({ex},{sg}) {a:x} {b:x} {c:x}: C {r:x} py {e:x}")
    print(f"fma e{ex}s{sg}: {len(cases)} cases, {bad} mismatches")

# widen/narrow via affine in layers below. recip_stage
for (sg, tb, nr, eps) in ((8, 6, 1, 0x3C24), (8, 6, 2, 0x3C24), (24, 8, 2, 0x3C23D70A), (24, 12, 1, 0x3C23D70A), (24, 6, 1, 0x3C23D70A)):
    pass
# recip_stage is exercised through the layers (K0,K1 compared) and directly through a 1-lane config below
bad = 0
lib.fpm_cfg(8, 1, 1, 1, 8, 8, 1)
for (sg, tb, nr) in ((8, 6, 1), (8, 6, 2), (24, 8, 2), (24, 12, 1), (24, 8, 1)):
    if (sg, tb) not in ((8, 6), (24, 8), (24, 12)):
        continue
    f = fm.Fmt(8, sg); eps = 0x3C24 if sg == 8 else 0x3C23D70A
    seed = fm.load_seed(sg, tb)
    for _ in range(N_REC // 5):
        k0, k1 = rnd_pat(f), rnd_pat(f)
        if fm.is_special(f, k0) or fm.is_special(f, k1): continue
        if rng.random() < 0.2: k0 &= ~(((1 << (f.exp)) - 1) << f.fr) | (rng.randint(0, 130) << f.fr)   # small magnitudes, guard region
        if fm.is_special(f, k0): continue
        h, z = fm.recip_stage(f, k0, k1, seed, tb, eps, nr)
        # C: use single-lane 1-chain layer? simpler: depth 1 => a[0] = k0 and z = recip(k0, 1)? not general; call through k1-less path:
        break
# direct recip test through a tiny layer: depth 2 gives K0 = a0*a1+1, K1 = a1; instead use depth-1 layer with chain value a: K0=a, K1=1
bad = 0; n = 0
for (sg, tb, nr) in ((8, 6, 1), (8, 6, 2), (24, 8, 2), (24, 12, 1), (24, 8, 1)):
    f = fm.Fmt(8, sg); eps = 0x3C24 if sg == 8 else 0x3C23D70A; seed = fm.load_seed(sg, tb)
    lib.fpm_cfg(8, 1, 1, 1, 8, 8, 1)
    for _ in range(N_REC // 5):
        k0 = rnd_pat(f)
        if fm.is_special(f, k0): continue
        if rng.random() < 0.3:
            k0 = (k0 & (1 << (f.w - 1))) | (rng.randint(0, 0x200) if rng.random() < .5 else rng.getrandbits(f.w - 1) & ((1 << (f.fr + 3)) - 1))
        one = f.bias << f.fr
        r = lib.fpm_recip(1 if sg == 24 else 0, tb, nr, k0, one); zc, hc = r & ((1 << 63) - 1), r >> 63
        h, z = fm.recip_stage(f, k0, one, seed, tb, eps, nr)
        # also random k1
        k1 = rnd_pat(f)
        if not fm.is_special(f, k1):
            r2 = lib.fpm_recip(1 if sg == 24 else 0, tb, nr, k0, k1); h2, z2 = fm.recip_stage(f, k0, k1, seed, tb, eps, nr); n += 1
            if (r2 & ((1 << 63) - 1)) != z2 or (r2 >> 63) != h2: bad += 1; fail(f"recip k1 sg{sg} k0={k0:x} k1={k1:x}")
        n += 1
        if zc != z or hc != h: bad += 1; fail(f"recip sg{sg} tb{tb} nr{nr} k0={k0:x}: C {zc:x}/{hc} py {z:x}/{h}")
print(f"recip_stage: {n} cases, {bad} mismatches")


def layer_case(geo, fmtn, accsig, tb, nr, x_rng_lo=-3):
    cfg = cc.FORMATS[fmtn]; f = cfg["f"]
    Wl, Bl = cc.rand_weights(rng, geo, f)
    if rng.random() < 0.3:     # a few near-pole biases / extremes
        for _ in range(3):
            j, k = rng.randrange(geo.width), rng.randrange(geo.depth)
            Bl[j][k] = rnd_pat(f) if rng.random() < .5 else (rng.getrandbits(1) << (f.w - 1)) | rng.getrandbits(f.fr)
    x = cc.rand_x(rng, geo, f)
    for j in range(geo.width):
        for k in range(geo.depth):
            for c in range(geo.pdim):
                if fm.is_special(f, Wl[j][k][c]): Wl[j][k][c] = 0
            if fm.is_special(f, Bl[j][k]): Bl[j][k] = 0
    return Wl, Bl, x


def load_c(geo, Wl, Bl, x, fa):
    lib.fpm_cfg(geo.width, geo.pdim, geo.depth, geo.lanes, geo.nslot, geo.npar, geo.nxbuf)
    ww, bw = cc.core_pack(geo, Wl, Bl)
    for l in range(geo.lanes):
        for a, el in enumerate(ww[l]):
            for fl, v in enumerate(el): lib.fpm_set_w(l, a, fl, v)
        for a, el in enumerate(bw[l]):
            for fl, v in enumerate(el): lib.fpm_set_b(l, a, fl, v)
    for i, v in enumerate(x): lib.fpm_set_x(i, v)


def check_layer(geo, fmtn, accsig, tb, nr, tag):
    Wl, Bl, x = layer_case(geo, fmtn, accsig, tb, nr)
    sd = fm.load_seed(cc.FORMATS[fmtn]["f"].sig, tb)
    try:
        z, hits, A, K0, K1 = cc.model_layer(geo, fmtn, Wl, Bl, x, accsig=accsig, nr_iters=nr, tbits=tb, seed=sd)
    except AssertionError:
        return True      # python model has no Inf/NaN support: case not comparable
    load_c(geo, Wl, Bl, x, accsig)
    mask = (1 << geo.lanes) - 1
    lib.fpm_run(1 if fmtn == "fp32" else 0, accsig or 0, tb, nr, mask)
    ok = True
    for j in range(geo.width):
        if lib.fpm_z(j) != z[j] or lib.fpm_hit(j) != hits[j] or lib.fpm_k0(j) != K0[j] or lib.fpm_k1(j) != K1[j] or any(lib.fpm_a(j, k) != A[j][k] for k in range(geo.depth)):
            ok = False; fail(f"{tag} j={j} z C {lib.fpm_z(j):x} py {z[j]:x}"); break
    return ok


S = cc.SMALL
cnt = 0; bad = 0
for fmtn, tbs in (("bf16", (6,)), ("fp32", (8, 12))):
    for acc in ((None, 24) if fmtn == "bf16" else (None,)):
        for tb in tbs:
            for nr in (1, 2):
                for i in range(max(1, N_LAYER // (len(tbs) * 2 * (2 if fmtn == "bf16" else 1)))):
                    cnt += 1
                    if not check_layer(S, fmtn, acc, tb, nr, f"S {fmtn} acc{acc} tb{tb} nr{nr}"): bad += 1
print(f"SMALL layers: {cnt} cases, {bad} mismatches")
cnt = 0; bad = 0
for fmtn, tb, nr in (("bf16", 6, 1), ("fp32", 8, 2)):
    for i in range(N_FULL):
        cnt += 1
        if not check_layer(cc.FULL, fmtn, None, tb, nr, f"F {fmtn}"): bad += 1
print(f"FULL layers: {cnt} cases, {bad} mismatches")

# tiled == untiled bit-exact (wide layer PDIM' = S*PDIM, slices in C carry partial sums)
cnt = 0; bad = 0
for i in range(N_TILE):
    fmtn = ("bf16", "fp32")[i % 2]; ns = rng.randint(2, 4)
    big = cc.Geo(16, 8 * ns, 2); tb, nr = (6, 1) if fmtn == "bf16" else (8, 2)
    Wl, Bl, x = layer_case(big, fmtn, None, tb, nr)
    sd = fm.load_seed(cc.FORMATS[fmtn]["f"].sig, tb)
    try:
        z, hits, A, K0, K1 = cc.model_layer(big, fmtn, Wl, Bl, x, nr_iters=nr, tbits=tb, seed=sd)
    except AssertionError:
        continue
    ok = True
    for s in range(ns):
        sl = cc.Geo(16, 8, 2)
        Ws = [[w[8 * s:8 * s + 8] for w in row] for row in Wl]
        load_c(sl, Ws, Bl, x[8 * s:8 * s + 8], None)
        lib.fpm_tile_slice(1 if fmtn == "fp32" else 0, 0, tb, nr, 3, 1 if s == 0 else 0, 1 if s == ns - 1 else 0)
    for j in range(16):
        if lib.fpm_z(j) != z[j]: ok = False; fail(f"tile {fmtn} ns{ns} j{j}"); break
    cnt += 1; bad += (not ok)
print(f"tiled layers: {cnt} cases, {bad} mismatches")

# lane mask qNaN
lib.fpm_cfg(16, 8, 7, 2, 8, 8, 4); lib.fpm_run(0, 0, 6, 1, 1)
okm = all(lib.fpm_z(j) == 0x7FC0 for j in range(8, 16)) and all(lib.fpm_hit(j) == 0 for j in range(8, 16))
print("lane mask qNaN:", okm); fails += (not okm)

# CRC / checksum / LFSR / KAT
bad = 0
for _ in range(2000):
    d = bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 20)))
    c = 0
    for b in d: c = lib.fpm_crc8(c, b)
    if c != pr.crc8(d): bad += 1; print('crc8 mismatch')
if lib.fpm_crc8(0, 0) != 0: bad += 1
c = 0
for b in b"123456789": c = lib.fpm_crc8(c, b)
if c != 0xF4: bad += 1; print("crc8 check value", hex(c))
for _ in range(500):
    W = rng.choice((16, 32)); vals = [rng.getrandbits(W) for _ in range(rng.randint(1, 30))]
    crc = 0
    for v in vals: crc = lib.fpm_crc32_update(crc, v, W // 8)
    if crc != pk.load_crc(vals, W): bad += 1; print('crc32 mismatch', W)
    # checksum
    zs = [rng.getrandbits(W) for _ in range(16)]
    lib.fpm_cfg(16, 8, 7, 2, 8, 8, 4)
    # set Z via a run is not possible; compare rotl/fold math using a direct python mirror of the C expression:
    s = rng.getrandbits(32)
    if lib.fpm_rotl32(s, 5) != pk.rotl32(s, 5): bad += 1
l = pk.Lfsr(); s = pk.KAT_SEED
for _ in range(5000):
    s = lib.fpm_lfsr_next(s); r = l.next()
    if s != r: bad += 1; print('lfsr', hex(s), hex(r)); break
    for W in (16, 32):
        if lib.fpm_kat_element(r, W) != pk.kat_element(r, W): bad += 1; print('kat', W, hex(r))
print(f"crc/lfsr/kat: {bad} mismatches"); fails += bad
# checksum through a real run
for W, fmtn, tb, nr in ((16, "bf16", 6, 1), (32, "fp32", 8, 2)):
    Wl, Bl, x = layer_case(S, fmtn, None, tb, nr)
    load_c(S, Wl, Bl, x, None); lib.fpm_run(1 if W == 32 else 0, 0, tb, nr, 3)
    zs = [lib.fpm_z(j) for j in range(16)]
    cks = rng.getrandbits(32)
    if lib.fpm_cksum_update(cks, W) != pk.update(cks, zs, W): fail("cksum update"); 
print("cksum update checked")
print("TOTAL MISMATCHES:", fails)
sys.exit(1 if fails else 0)
