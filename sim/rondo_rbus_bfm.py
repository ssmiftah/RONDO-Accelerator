"""rbus BFMs for cocotb: a responder (slave, random ready/response delays, dict memory)
and a master (sequential reads/writes). Both sample/drive on the falling edge of `clk`."""
import random
from cocotb.triggers import FallingEdge


class RbusResponder:
    def __init__(self, dut, clk, prefix="rb_", mem=None, max_ready_delay=3, max_rsp_delay=3,
                 seed=2, default=None):
        self.dut, self.clk, self.p = dut, clk, prefix
        self.mem = {} if mem is None else mem
        self.rng = random.Random(seed)
        self.max_rd, self.max_sd = max_ready_delay, max_rsp_delay
        self.default = default
        self.log = []                  # (we, addr, data)
        self.sig = lambda n: getattr(dut, prefix + n)
        self.rsp_extra = 0             # forced additional response delay (overrun tests)

    async def run(self):
        s = self.sig
        s("req_ready").value = 0
        s("rsp_valid").value = 0
        s("rsp_rdata").value = 0
        s("rsp_err").value = 0
        wait = 0
        while True:
            await FallingEdge(self.clk)
            if wait > 0:
                wait -= 1
                continue
            s("req_ready").value = 1
            v = int(s("req_valid").value)
            await FallingEdge(self.clk)
            s("req_ready").value = 0
            if not v:
                continue
            we, addr, wd = int(s("req_we").value), int(s("req_addr").value), int(s("req_wdata").value)
            # (payload is held until the transfer; re-read at the transfer edge)
            self.log.append((we, addr, wd))
            if we:
                self.mem[addr] = wd
                rd = 0
            else:
                rd = self.mem.get(addr, self.default if self.default is not None else (addr * 0x01010101) & 0xFFFFFFFF)
            for _ in range(self.rng.randint(0, self.max_sd) + self.rsp_extra):
                await FallingEdge(self.clk)
            s("rsp_rdata").value = rd
            s("rsp_valid").value = 1
            await FallingEdge(self.clk)
            s("rsp_valid").value = 0
            wait = self.rng.randint(0, self.max_rd)


class RbusMaster:
    """Sequential rbus master (one outstanding access), drives/samples on falling clk edges."""

    def __init__(self, dut, clk, prefix="rb_"):
        self.dut, self.clk, self.p = dut, clk, prefix
        self.s = lambda n: getattr(dut, prefix + n)
        self.last_latency = 0
        self.last_err = 0
        self.max_latency = 0
        self.max_total = 0
        for n, v in (("req_valid", 0), ("req_we", 0), ("req_addr", 0), ("req_wdata", 0), ("rsp_ready", 1)):
            self.s(n).value = v
        if hasattr(dut, prefix + "req_int"):
            self.s("req_int").value = 0

    async def _xfer(self, we, addr, data, timeout=500):
        s = self.s
        await FallingEdge(self.clk)
        s("req_valid").value = 1; s("req_we").value = we; s("req_addr").value = addr
        s("req_wdata").value = data
        n_wait = 0
        while True:
            ready = int(s("req_ready").value)
            if ready:
                break
            await FallingEdge(self.clk)
            n_wait += 1
            assert n_wait < timeout, "rbus request never accepted"
        await FallingEdge(self.clk)            # the transfer happened at the rising edge in between
        s("req_valid").value = 0
        lat = 1
        while not int(s("rsp_valid").value):
            await FallingEdge(self.clk)
            lat += 1
            assert lat < timeout, "rbus response timeout"
        rd = int(s("rsp_rdata").value)
        err = int(s("rsp_err").value)
        self.last_latency, self.last_err = lat, err
        self.max_latency = max(self.max_latency, lat)
        self.max_total = max(self.max_total, lat + n_wait)
        return rd, err

    async def write(self, addr, data):
        _, err = await self._xfer(1, addr, data & 0xFFFFFFFF)
        return err

    async def read(self, addr):
        rd, err = await self._xfer(0, addr, 0)
        return rd

    async def write_burst(self, addr, words):
        for i, w in enumerate(words):
            await self.write(addr + i, w)

    async def read_burst(self, addr, n):
        return [await self.read(addr + i) for i in range(n)]
