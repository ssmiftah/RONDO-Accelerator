import os
import cocotb
from cocotb.triggers import RisingEdge, Timer


@cocotb.test()
async def core_eq(dut):
    """Wait for the Verilog bench to finish, then check inferences and mismatches."""
    for _ in range(2_000_000):
        if int(dut.fin.value):
            break
        await Timer(1000, "ns")
    assert int(dut.fin.value), "bench did not finish"
    nerr, nd = int(dut.nerr.value), int(dut.ndone.value)
    exp = int(os.environ.get("EQ_EXPECT", "0"))
    dut._log.info(f"EQ RESULT inferences={nd} mismatches={nerr}")
    assert nerr == 0, f"{nerr} mismatches between as-built and current core"
    assert nd >= exp, f"only {nd} inferences completed (expected {exp})"
