# RONDO chip: verification handoff

This package holds everything needed to verify the RONDO tapeout chip:
- the design source;
- the existing tests;
- a formal and UVM verification environment;
- the specification of the chip's architecture, registers and SPI protocol;
- the review history.

The chip is a hardware accelerator for the second-order recurrences in CoFrNets and Chebyshev KANs. A Raspberry Pi 5 hosts it as an SPI mode-0 slave.

Package date: 2026-11-03. Specification v2.1.1; the VERSION register reads `0x00020101`.

## 1. Status in one paragraph

The RTL is implemented, independently reviewed, and patched for the seven bugs that review found (B1–B7). A formal and UVM environment was then built and independently checked.

That environment is a working foundation, not a sign-off environment:
- Formal: three blocks have unbounded proofs (register file, rbus arbiter, KAT engine); five have bounded model checks (BMC).
- UVM on Vivado xsim: 305 of 305 sign-off runs pass. BUG-1, found by this environment, is fixed (2026-11-04).
- Functional coverage: 6 of the 19 planned covergroups exist.
- Code coverage is below the plan's targets.

The Cadence flows (JasperGold, Xcelium) are written but have **never been run**.

`verif/reports/CHECK_REPORT.md` §"Remaining work" is the prioritized to-do list.

## 2. What to read, in order

| Document | What it is |
|---|---|
| `docs/CHIP_INTERFACE_SPEC.md` | **The specification.** Architecture, clocks and resets, SPI framing/CRC/status byte, register and memory map, error codes, IRQ, FORMAT switch, self-run, KAT, MBIST, trace and debug, scan, input tiling (§18), task list, author decisions (§16). The reference for every check. |
| `docs/architecture/` | Background on the datapath the chip wraps. `FUSED_COPROC.md` covers the CoFrNet layer pipeline; `KAN_HARDWARE.md` covers the Chebyshev KAN layer; `IP_PROVENANCE.md` covers the reused IP (Berkeley HardFloat) and its license. Some parts predate the chip work; the spec wins where they differ. |
| `verif/README.md` | **How to run** every flow, with expected results. Also lists behaviors introduced by the fix round. |
| `verif/TOOLS.md` | Commands per tool: SymbiYosys, JasperGold, xsim, Xcelium. Includes the JasperGold-only full-strength properties and first-use risks. |
| `docs/CHIP_VERIF_PLAN.md` | The verification plan: strategy, feature-to-check matrix, formal properties, UVM architecture, coverage model, sign-off criteria. |
| `verif/reports/SIGNOFF.md` | Measured status against the plan's sign-off criteria. |
| `verif/reports/CHECK_REPORT.md` | Independent check of the verification environment: verdict, weak spots, prioritized remaining work. |
| `verif/reports/BUGS.md` | RTL bugs found by the verification: BUG-1 (fixed 2026-11-04, see §6) and NOTE-2 (judged a harness artifact). |
| `verif/WAIVERS.md` | Waivers; all are pending the author's approval. |
| `docs/CHIP_VERIFY_REPORT.md` | First independent review of the RTL (B1–B7, F1). |
| `docs/CHIP_FIX_PLAN.md` | How B1–B7 and F1 were fixed. |
| `docs/CHIP_IMPL_LOG.md` | Implementation log: every task, test and deviation, including the fix round. |

The host software in `host/rondo_host/` is a second, executable description of the protocol. `transport.py`, `device.py` and `regmap.py` implement the SPI frames and the register-level sequences the Pi uses.

## 3. Layout

```
rtl/chip/          chip wrapper RTL (top: rondo_chip_top.v; FPGA prototype top: genesys2_pi_top.v)
rtl/chip/sva/      SystemVerilog assertion checkers
rtl/core/          accelerator core (CoFrNet and KAN layers) and reciprocal seed ROMs (*.mem)
rtl/third_party/HardFloat/   Berkeley HardFloat (BSD license)
rtl/cofr_defs.vh   central parameter defaults
sim/               cocotb tests and testbenches (run_*.py runners, test_*.py tests), fpmodel.py bit-exact model
formal/            SymbiYosys jobs from the implementation round (scripts/chip_formal.sh)
verif/             formal + UVM environment (see verif/README.md)
  uvm/             UVM 1.2 testbench (tb, env, agents, seq, tests, cov, sva) + scripts/run_xcelium.sh
  model/           C port of the bit-exact model for DPI-C, with its cross-check against sim/fpmodel.py
  formal/          job generator (gen_jobs.py), run_formal.sh, JasperGold Tcl (jg/), mutation (mutate.py)
  scripts/         regress.py, xsim build/run, coverage, elaboration negatives, prefix check
  reports/         results of the runs described in this README
scripts/           lint, synthesis, gate-level sim, formal, regression and vector-generation scripts
host/              Pi 5 host library (rondo_host) and its tests
vivado/            Genesys 2 FPGA prototype build (one bitstream per format)
workloads/results/ two data files used by the CoFrGeNet-shape and C7 tests
prefix/            pre-fix RTL and host snapshot for the "red on pre-fix" bug tests (see §5)
env/requirements-rtl.txt   Python packages
```

## 4. Setup

Tools used here:
- Vivado 2025.2: xsim with its precompiled UVM 1.2, and xsc.
- gcc.
- Verilator 5.054. The earlier runs used 5.052.
- Icarus Verilog 13.
- Yosys 0.66, SymbiYosys 0.70, yices 2.7 and z3 4.16.
- Berkeley ABC: `verif/scripts/abc_wrap.sh` expects it at `/usr/bin/abc`; edit the path if it lives elsewhere.
- Python 3.13.

Cadence: JasperGold and Xcelium (with IMC) are supported by scripts but untested; see `verif/TOOLS.md` §2 and §4.

```bash
tar xzf RONDO_chip_verif_handoff.tar.gz && cd RONDO_chip_verif_handoff
python3.13 -m venv .venv-rtl && .venv-rtl/bin/pip install -r env/requirements-rtl.txt
export VIVADO_BIN=/path/to/Vivado/2025.2/bin        # if not at /home/CAD/2025.2/Vivado/bin
make -C verif/model XSIM_INC=$VIVADO_BIN/../data/xsim/include
bash prefix/setup_prefix.sh                          # only for the pre-fix bug tests (§5)
.venv-rtl/bin/python scripts/gen_vectors.py          # test vectors used by run_chip_suite
```

Run every command from the package root. Build outputs go to `build/` and the old cocotb runners write to `sim/sim_build*`. Neither ships in the package; both are created on first run.

## 5. Running

The full list is in `verif/README.md` "How to run". The main entry points:

| Flow | Command | Expected |
|---|---|---|
| UVM smoke (xsim) | `.venv-rtl/bin/python verif/scripts/regress.py --tier smoke` | 4/4 |
| UVM sign-off (xsim) | `.venv-rtl/bin/python verif/scripts/regress.py --tier signoff -j 16` | 305/305 |
| UVM on Xcelium | `regress.py --sim xcelium ...`, `verif/uvm/scripts/run_xcelium.sh` | untested |
| Formal (SymbiYosys) | `verif/formal/run_formal.sh -j 14` | every row `(OK)`; spi_ctrl `pdr` is informational (about 12 min) |
| Formal (JasperGold) | `verif/formal/run_jg.sh` | untested |
| C model vs Python model | `.venv-rtl/bin/python -I verif/model/test_fpmodel_c.py --quick` | `TOTAL MISMATCHES: 0` |
| Bug tests, pre-fix vs fixed | `verif/scripts/prefix_check.sh` (needs `prefix/setup_prefix.sh`) | B1–B7 red on pre-fix, green on fixed |
| Existing cocotb chip tests | `.venv-rtl/bin/python scripts/chip_regress_new.py icarus` | CHIP REGRESSION OK (about 36 min) |
| Host library tests | `cd host && ../.venv-rtl/bin/python -m pytest -q tests` | 40 passed |
| Lint / synthesis / old formal | `scripts/chip_lint.sh`, `scripts/chip_synth.sh small`, `scripts/chip_formal.sh` | clean / `check -assert` passes / all PASS |

`scripts/chip_regress_old.py` also runs the older core tests. Twelve of them (`WL_*`) need trained-workload settings that are not part of this package, and they fail when run bare, as they always have. Under Verilator, `grad_a_inter`, `train_ladder_inter` and `power_top` also fail; they failed before any chip work started. None of these tests touches the chip wrapper.

## 6. Open items for the verification engineer

**RTL bugs and author decisions:**
1. **BUG-1 (fixed 2026-11-04).** A CS abort inside the first byte of an opcode or data word raised no `SPI_FRAME` error. Fix: `rondo_spi_phy.v` drives `mid_byte_abort` combinationally with `frame_end`, and `rondo_spi_ctrl.v` also flags an abort inside the opcode byte. After the fix: UVM sign-off 305/305 (u_spi_abort passes), both formal suites pass, the prefix check is unchanged, and lint is clean. The cocotb chip regression (`scripts/chip_regress_new.py icarus`) and the host pytest were **not re-run after this fix** (interrupted by a power shutdown); run them first. `verif/reports/BUGS.md` and `SIGNOFF.md` still describe BUG-1 as open; this README supersedes them.
2. **Open design questions:**
   - Q1: process and core clock.
   - Q2: power gating of the inactive layer.
   - Q7: our MBIST or the macros' own BIST.
   - Q10: tiling batch depth.

   The memory self-test does not cover the tiling buffers (decision D1). A host-side March test covers them in the interim (spec §11.6).

**Verification still to do** (detailed in `verif/reports/CHECK_REPORT.md`):

3. **Checks:** the pin scoreboard, the IRQ_STATUS/STATUS compare and every ERR bit. Connect the `rondo_sva_spi` and `rondo_sva_tile` checkers.
4. **Coverage:** add the 13 missing covergroups, then close code coverage. The main holes are in `rondo_regs`, `rondo_tile`, `rondo_seq`, `rondo_dev` and `rondo_cksum`.
5. **Untested features:**
   - debug taps and trace;
   - MBIST and KAT with injected faults;
   - scan;
   - tiling host-swap, padding, illegal commands and random tests;
   - the SPI maximum burst and overrun.
6. **Formal:**
   - Raise mutation kill rates to at least 80%; they are 13–30% today, except the arbiter.
   - Add the missing jobs: pack/checksum, clock/reset, MBIST, trace.
   - Try JasperGold on the blocks that are only bounded here.
7. **Hardware:** nothing has run on a real Pi 5 or Genesys 2. No FPGA bitstream or gate-level timing has been produced.

## 7. Notes

- The project is not under git. Some files in `verif/` were edited during the check round; their originals are not shipped.
- Not included:
  - build outputs;
  - the trained-workload data for the legacy `WL_*` runners;
  - the ASIC (ASAP7) flow;
  - material unrelated to the chip.
