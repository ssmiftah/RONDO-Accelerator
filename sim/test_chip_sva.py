"""T22 negative tests: each property of each checker fires on a deliberately broken stimulus and stays silent on legal traffic."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

INPUTS = ["cs_active", "miso", "miso_oe", "rise", "frame_start", "frame_end", "rb_req_valid_s", "rb_req_ready_s",
          "frame_is_rw", "hdr_done", "n_total", "req_valid", "req_ready", "req_we", "req_addr", "req_wdata", "rsp_valid",
          "rsp_ready", "reg_re", "reg_we", "reg_idx", "reg_wdata", "reg_rdata", "err_status", "err_in", "srst",
          "irq_status_eff", "irq_en", "irq", "pair0", "start", "busy", "done", "layer_rst_n", "x", "zbuf", "zcap", "zclr",
          "mem_wr_ext", "active", "inact_clk_en", "inact_rst_n", "fmt", "ce_l_any", "wp_en", "wp_half", "wp_denied"]


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for n in INPUTS:
        getattr(dut, n).value = 0
    dut.rst_n.value = 0
    await Timer(25, unit="ns")
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)


async def cyc(dut, n=1, **kw):
    for k, v in kw.items():
        getattr(dut, k).value = v
    for _ in range(n):
        await FallingEdge(dut.clk)


def bits(dut, name):
    return int(getattr(dut, name).value)


@cocotb.test()
async def spi_checker(dut):
    await reset(dut)
    # legal: oe follows cs one cycle later, miso changes after a rise
    await cyc(dut, 1, cs_active=1)
    await cyc(dut, 1, miso_oe=1)
    await cyc(dut, 1, rise=1)
    await cyc(dut, 1, rise=0, miso=1)
    await cyc(dut, 3)
    assert bits(dut, "v_spi") == 0
    await cyc(dut, 2, miso=0)                          # MISO toggles with no SCLK rise: property 1
    assert bits(dut, "v_spi") & 2
    await reset(dut)
    await cyc(dut, 3, cs_active=1)                     # oe stays low while CS active: property 0
    assert bits(dut, "v_spi") & 1
    await reset(dut)
    await cyc(dut, 3, rb_req_valid_s=1)                # request issued while idle: property 2
    assert bits(dut, "v_spi") & 4
    await reset(dut)
    await cyc(dut, 1, frame_start=1)
    await cyc(dut, 1, frame_start=0, frame_is_rw=1, hdr_done=1, n_total=1, rb_req_valid_s=1, rb_req_ready_s=1, cs_active=1, miso_oe=1)
    await cyc(dut, 6)                                  # three accepted requests with N+1 = 1: property 3
    assert bits(dut, "v_spi") & 8


@cocotb.test()
async def rbus_checker(dut):
    await reset(dut)
    # legal single access
    await cyc(dut, 1, req_valid=1, req_ready=1, req_we=1, req_addr=5, req_wdata=7)
    await cyc(dut, 1, req_valid=0, req_ready=0)
    await cyc(dut, 2)
    await cyc(dut, 1, rsp_valid=1, rsp_ready=1)
    await cyc(dut, 1, rsp_valid=0)
    assert bits(dut, "v_rbus") == 0
    await reset(dut)
    await cyc(dut, 1, req_valid=1, req_ready=0)        # valid then dropped before ready: 0
    await cyc(dut, 2, req_valid=0)
    assert bits(dut, "v_rbus") & 1
    await reset(dut)
    await cyc(dut, 1, req_valid=1, req_ready=0, req_addr=1)
    await cyc(dut, 2, req_addr=2)                      # payload changed while waiting: 1
    assert bits(dut, "v_rbus") & 2
    await reset(dut)
    await cyc(dut, 2, rsp_valid=1)                     # response without request: 2
    assert bits(dut, "v_rbus") & 4
    await reset(dut)
    await cyc(dut, 1, req_valid=1, req_ready=1)
    await cyc(dut, 1, req_valid=1, req_ready=1)        # second request with the first outstanding: 3
    assert bits(dut, "v_rbus") & 8
    await reset(dut)
    await cyc(dut, 1, req_valid=1, req_ready=1)
    await cyc(dut, 1, req_valid=0)
    await cyc(dut, 16)                                 # no response within MAX_RSP: 4 (and the total bound: 5)
    assert bits(dut, "v_rbus") & 0x10 and bits(dut, "v_rbus") & 0x20


@cocotb.test()
async def regs_checker(dut):
    await reset(dut)
    await cyc(dut, 1, reg_re=1, reg_idx=3, reg_rdata=0x55)
    await cyc(dut, 1, reg_re=1, reg_idx=3, reg_rdata=0x55)
    await cyc(dut, 2, reg_re=0)
    assert bits(dut, "v_regs") == 0
    await cyc(dut, 1, reg_re=1, reg_idx=3, reg_rdata=0x66)          # RO register changed: 0
    await cyc(dut, 2, reg_re=0)
    assert bits(dut, "v_regs") & 1
    await reset(dut)
    await cyc(dut, 1, err_status=0x8)
    await cyc(dut, 1, err_status=0x0)                               # cleared without a W1C write: 1
    await cyc(dut, 2)
    assert bits(dut, "v_regs") & 2
    await reset(dut)
    await cyc(dut, 1, reg_re=1, reg_idx=0x0A, reg_rdata=1)          # CTRL read not zero: 2
    assert bits(dut, "v_regs") & 4
    await reset(dut)
    await cyc(dut, 1, irq_status_eff=1, irq_en=1, irq=0)
    await cyc(dut, 3)                                               # irq pin disagrees with the enabled status: 3
    assert bits(dut, "v_regs") & 8
    await reset(dut)
    await cyc(dut, 1, reg_re=1, reg_idx=0x21, pair0=0x0000000500000001)
    await cyc(dut, 1, reg_re=1, reg_idx=0x22, reg_rdata=7, pair0=0x0000000700000001)   # HI differs from the latched one: 4
    await cyc(dut, 2, reg_re=0)
    assert bits(dut, "v_regs") & 0x10


@cocotb.test()
async def seq_checker(dut):
    await reset(dut)
    await cyc(dut, 4, layer_rst_n=1)
    await cyc(dut, 1, start=1)
    await cyc(dut, 1, start=0, busy=1)
    await cyc(dut, 3, busy=0, done=1)
    await cyc(dut, 1, done=0)
    await cyc(dut, 2)
    await cyc(dut, 1, start=1)
    await cyc(dut, 1, start=0)
    assert bits(dut, "v_seq") == 0
    await reset(dut)
    await cyc(dut, 4, layer_rst_n=1)
    await cyc(dut, 2, start=1)                                       # start held 2 cycles: 0
    assert bits(dut, "v_seq") & 1
    await reset(dut)
    await cyc(dut, 4, layer_rst_n=1)
    await cyc(dut, 1, busy=1)
    await cyc(dut, 1, start=1)                                       # start while busy: 1
    assert bits(dut, "v_seq") & 2
    await reset(dut)
    await cyc(dut, 4, layer_rst_n=1)
    await cyc(dut, 1, done=1)
    await cyc(dut, 1, done=0, start=1)                               # start at t+1: 2
    assert bits(dut, "v_seq") & 4
    await reset(dut)
    await cyc(dut, 1, layer_rst_n=0)
    await cyc(dut, 1, start=1)                                       # start with the layer in reset: 3
    assert bits(dut, "v_seq") & 8
    await reset(dut)
    await cyc(dut, 4, layer_rst_n=1)
    await cyc(dut, 2, busy=1, x=1)
    await cyc(dut, 1, x=2)                                           # x changed while busy: 4
    assert bits(dut, "v_seq") & 0x10
    await reset(dut)
    await cyc(dut, 2)
    await cyc(dut, 2, zbuf=5)                                        # ZBUF changed without a capture: 5
    assert bits(dut, "v_seq") & 0x20
    await reset(dut)
    await cyc(dut, 1, mem_wr_ext=1, active=1)                        # external memory write while ACTIVE: 6
    assert bits(dut, "v_seq") & 0x40
    await reset(dut)
    await cyc(dut, 8, inact_clk_en=1)                                # inactive layer clock left on: 7
    assert bits(dut, "v_seq") & 0x80


@cocotb.test()
async def wmem_checker(dut):
    await reset(dut)
    await cyc(dut, 3, fmt=1, ce_l_any=1)
    await cyc(dut, 3, fmt=0, ce_l_any=1, wp_en=1, wp_half=3)
    assert bits(dut, "v_wmem") == 0
    await cyc(dut, 2, fmt=0, ce_l_any=1, wp_en=0)                    # L enabled by the layer in bf16: 0
    assert bits(dut, "v_wmem") & 1
    await reset(dut)
    await cyc(dut, 2, wp_denied=1)                                   # two owners: 1
    assert bits(dut, "v_wmem") & 2
