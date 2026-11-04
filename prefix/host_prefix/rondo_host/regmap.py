"""Register map, bit fields and region bases (spec sections 6, 7, 18.5): the single source
for the host library, the mock model and the tests. Word addresses (byte address = 4 * word)."""

CHIP_ID_VALUE = 0x524F4E44
VERSION_VALUE = 0x00020100

# name -> (word address, access, reset)
# access: RO, RW, W1C, WO (self-clearing command bits, reads 0)
REGS = {
    "CHIP_ID": (0x00, "RO", CHIP_ID_VALUE),
    "VERSION": (0x01, "RO", VERSION_VALUE),
    "CAPS": (0x02, "RO", None),          # build dependent
    "GEOM0": (0x03, "RO", None),
    "GEOM1": (0x04, "RO", None),
    "GEOM2": (0x05, "RO", None),
    "GEOM3": (0x06, "RO", None),
    "EPS_BF16": (0x07, "RO", 0x00003C24),
    "EPS_FP32": (0x08, "RO", 0x3C23D70A),
    "SCRATCH": (0x09, "RW", 0),
    "CTRL": (0x0A, "WO", 0),
    "STATUS": (0x0B, "RO", None),
    "IRQ_STATUS": (0x0C, "W1C", 0),
    "IRQ_EN": (0x0D, "RW", 0x7F),
    "ERR_STATUS": (0x0E, "W1C", 0),
    "ERR_MASK": (0x0F, "RW", 0xFFFFFDFF),
    "FORMAT": (0x10, "RW", 0),
    "XSEL": (0x11, "RW", 0),
    "SR_N": (0x12, "RW", 1),
    "SR_COUNT": (0x13, "RW", 0),
    "WDOG_LIMIT": (0x14, "RW", 0),
    "LANE_EN": (0x15, "RW", None),       # all ones [N_LANES-1:0]
    "CLK_CFG": (0x16, "RW", 0),
    "CLKOUT_CFG": (0x17, "RW", 0),
    "PWR_CTRL": (0x18, "RW", 0),
    "SPI_CFG": (0x19, "RW", 0),
    "LAST_CYCLES": (0x20, "RO", 0),
    "INFER_CNT_LO": (0x21, "RO", 0), "INFER_CNT_HI": (0x22, "RO", 0),
    "BUSY_CYC_LO": (0x23, "RO", 0), "BUSY_CYC_HI": (0x24, "RO", 0),
    "TOTAL_CYC_LO": (0x25, "RO", 0), "TOTAL_CYC_HI": (0x26, "RO", 0),
    "SR_CYC_LO": (0x27, "RO", 0), "SR_CYC_HI": (0x28, "RO", 0),
    "SR_DONE_CNT": (0x29, "RO", 0),
    "CHECKSUM": (0x2A, "RO", 0),
    "SR_PASS_CKSUM": (0x2B, "RO", 0),
    "LOAD_CRC": (0x2C, "RO", 0),
    "GUARD_HITS": (0x2D, "RO", 0),
    "NANINF_CNT": (0x2E, "RO", 0),
    "DBG_SEL": (0x30, "RW", 0),
    "DBG_DATA": (0x31, "RO", 0),
    "TRC_CFG": (0x38, "RW", 0),
    "TRC_TRIG_CYC": (0x39, "RW", 0),
    "TRC_STATUS": (0x3A, "RO", 0),
    "ST_STATUS": (0x40, "RO", 0),
    "KAT_SIG_BF16": (0x41, "RO", None),
    "KAT_SIG_FP32": (0x42, "RO", None),
    "KAT_GOT_BF16": (0x43, "RO", 0),
    "KAT_GOT_FP32": (0x44, "RO", 0),
    "MBIST_STATUS": (0x48, "RO", 0),
    "MBIST_FAIL_ADDR": (0x49, "RO", 0),
    "MBIST_FAIL_XOR": (0x4A, "RO", 0),
    "TILE_CFG": (0x50, "RW", 0),
    "TILE_STATUS": (0x51, "RO", 0),
    "TILE_SEQ_CRC": (0x52, "RO", 0),
    "TILE_GEOM": (0x53, "RO", None),
    "TILE_SLICE": (0x54, "RW", 0),
}
ADDR = {k: v[0] for k, v in REGS.items()}
NAME = {v[0]: k for k, v in REGS.items()}

CAPS_BITS = {"HAS_BF16": 0, "HAS_FP32": 1, "LAYER0": 2, "LAYER1": 3, "HAS_BIAS": 4, "GUARD": 5,
             "CKSUM_PAR": 6, "READBACK": 7, "DBG": 8, "TRACE": 9, "KAT": 10, "MBIST": 11,
             "SCAN": 12, "LANE_MASK": 13, "SPI_CRC": 14, "CLK_ALT": 15, "PG": 16, "TILE": 17}

CTRL_BITS = {"START": 0, "SOFT_RST": 1, "SR_START": 2, "SR_STOP": 3, "CNT_CLR": 4, "CKSUM_CLR": 5,
             "CRC_CLR": 6, "KAT_START": 7, "MBIST_START": 8, "TRC_ARM": 9, "TRC_FORCE": 10,
             "DBG_LATCH": 11, "GUARD_CLR": 12, "TILE_RUN": 13, "TILE_ABORT": 14}

STATUS_BITS = {"BUSY": 0, "ACTIVE": 1, "SR_RUNNING": 2, "SR_STOPPING": 3, "ZVALID": 4,
               "SOFT_RST": 5, "HEARTBEAT": 6, "WSTALE": 7, "FORMAT": 8, "KAT_RUNNING": 9,
               "MBIST_RUNNING": 10, "TRC_ARMED": 11, "ERR_ANY": 31}

IRQ_BITS = {"DONE": 0, "SR_DONE": 1, "ERR": 2, "TRC_DONE": 3, "SELFTEST_DONE": 4,
            "TILE_SLICE_DONE": 5, "TILE_FINAL_DONE": 6}

ERR_BITS = {"BUSY_WR": 0, "ADDR": 1, "RO": 2, "START_BUSY": 3, "PARTIAL": 4, "RANGE": 5,
            "SPI_FRAME": 6, "WDOG": 7, "NAN_INF": 8, "GUARD": 9, "SPI_CRC": 10, "KAT_FAIL": 11,
            "MBIST_FAIL": 12, "WSTALE_RUN": 13, "TILE_SEQ": 14, "TILE_STALE": 15}

# regions (word addresses)
XBUF_BASE = 0x010000
ZBUF_BASE = 0x020000
TRACE_BASE = 0x030000
TX_BASE = 0x040000
TZ_BASE = 0x050000
PS_BASE = 0x060000
BIAS_BASE = 0x100000
WEIGHT_BASE = 0x800000

STATUS8_BITS = {"ERR_ANY": 7, "IRQ": 6, "SR_RUNNING": 5, "ACTIVE": 4, "BUSY": 3, "FORMAT": 2}


def bits(table, value):
    """set of names of the bits set in value"""
    return {n for n, b in table.items() if (value >> b) & 1}


def mask(table, *names):
    m = 0
    for n in names:
        m |= 1 << table[n]
    return m


class Geometry:
    """Chip geometry as read from CAPS/GEOM*/TILE_GEOM (defaults: the built chip)."""

    def __init__(self, width=64, pdim=40, depth=7, lanes=8, nslot=8, npar=8, nxbuf=4,
                 accsig_bf16=8, fma_lat=5, tile_b=8):
        self.width, self.pdim, self.depth, self.lanes = width, pdim, depth, lanes
        self.nslot, self.npar, self.nxbuf = nslot, npar, nxbuf
        self.accsig_bf16, self.fma_lat, self.tile_b = accsig_bf16, fma_lat, tile_b
        self.nlad = width // lanes
        self.nch = nslot * depth
        self.ngroup = self.nch // npar
        self.nbatches = self.nlad // nslot
        self.nwords = self.nbatches * self.ngroup * pdim
        self.nbwords = self.nbatches * self.ngroup
        clog = lambda n: max(1, (n - 1).bit_length()) if n > 1 else 1
        self.waw, self.baw, self.lnw = clog(self.nwords), clog(self.nbwords), clog(lanes)
        self.fw = (npar - 1).bit_length() if npar > 1 else 0
        self.xw = clog(pdim)

    @classmethod
    def from_regs(cls, geom0, geom1, geom2, geom3=0, tile_geom=0):
        return cls(width=geom0 & 0xFFFF, pdim=geom0 >> 16, depth=geom1 & 255,
                   lanes=(geom1 >> 8) & 255, nslot=(geom1 >> 16) & 255, npar=geom1 >> 24,
                   nxbuf=geom2 & 255, accsig_bf16=geom3 & 255, fma_lat=(geom3 >> 8) & 255,
                   tile_b=(tile_geom & 255) if tile_geom else 8)

    # word address helpers (spec 7.1)
    def weight_word_addr(self, lane, core_addr, field):
        return WEIGHT_BASE + (lane << (self.waw + self.fw)) + (core_addr << self.fw) + field

    def bias_word_addr(self, lane, core_addr, field):
        return BIAS_BASE + (lane << (self.baw + self.fw)) + (core_addr << self.fw) + field

    def xbuf_addr(self, entry, i):
        return XBUF_BASE + (entry << self.xw) + i

    def tx_addr(self, b, i):
        return TX_BASE + (b << self.xw) + i

    def tz_addr(self, b, j):
        return TZ_BASE + (b << max(1, (self.width - 1).bit_length())) + j

    def ps_addr(self, b, lane, g, f):
        return PS_BASE + (b << (self.lnw + self.baw + self.fw)) + (lane << (self.baw + self.fw)) \
            + (g << self.fw) + f
