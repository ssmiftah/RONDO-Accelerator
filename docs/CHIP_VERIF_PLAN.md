# RONDO chip verification plan (formal + UVM on xsim)

Status: plan, 2026-11-03. Target: the RTL in `rtl/chip/` + `rtl/core/` **after** the fixes in `docs/CHIP_FIX_PLAN.md` (B1–B7, F1, robustness items in `docs/CHIP_VERIFY_REPORT.md` §2/§8).
Spec: `docs/CHIP_INTERFACE_SPEC.md` v2.1. Existing assets reused: `sim/fpmodel.py`, `sim/chip_common.py`, `host/rondo_host/{regmap,packing,protocol,model}.py`, `rtl/chip/sva/*.v`, `formal/*.sby`, cocotb runners.
Executors: a Sonnet agent implements this plan (tasks in §5) and an Opus agent verifies it. The plan assumes no other context.

## 0. Tools actually installed (checked on this machine)

| tool | path / version | notes for this plan |
|---|---|---|
| Vivado xsim | `/home/CAD/2025.2/Vivado/bin/{xvlog,xelab,xsim,xsc,xcrg}` (2025.2) | **UVM 1.2 only**, precompiled: `xvlog -sv -L uvm`, `xelab -L uvm` (`--uvm_version` default 1.2). Macros: `/home/CAD/2025.2/Vivado/data/xsim/system_verilog/uvm_include/uvm_macros.svh`. DPI-C: `xsc` compiles C to a shared library; then `xelab --sv_lib/--sv_root`; `svdpi.h` in `data/xsim/include`. Functional coverage on by default; DB written with `--cov_db_dir/--cov_db_name`; merged and reported with `xcrg` (html/text). Code coverage: `xelab --cc_type sbct --cc_db … --cc_dir …` (statement, branch, condition, toggle). Seeds: `xsim --sv_seed N`. Plusargs: `--testplusarg`. Simulation is single-threaded (`--mt` only speeds up compilation), so speed comes from running tests in parallel. The machine has 32 cores and 60 GB RAM. |
| SymbiYosys | `/usr/bin/sby`, engines in `/usr/share/yosys/python3` | `smtbmc` with `yices`/`z3` works. **`abc` engines need `yosys-abc`, which is missing**, but Berkeley ABC is at `/usr/bin/abc` (ABC 1.01). Run sby with `ABC=/usr/bin/abc` (sby reads the `ABC` env var, `sby_core.py` `exe_paths`). This makes `abc pdr` available: an IC3 unbounded prover that finds inductive invariants itself. It is the main way to get unbounded proofs without hand-written invariants. Not installed: suprove, avy, pono, btormc, boolector, bitwuzla, eqy, mcy. |
| Yosys | 0.66 | `read_verilog -sv -formal` accepts immediate `assert/assume/cover` in `always` blocks, `$past/$stable/$rose/$fell/$changed`, `(* anyconst *)`, `(* anyseq *)`, `(* gclk *)`, `initial assume`. It does **not** accept concurrent SVA sequences (`|->`, `##`, `[*]`, `s_eventually`) or reliable `bind`, and hierarchical references are unreliable (`CHIP_IMPL_LOG.md` T35). Formal properties are therefore written as clocked immediate assertions with explicit history registers. The `mutate` command exists (used for mutation sanity, §2.7). |
| Verilator / Icarus | 5.052 / 13.0 | existing cocotb flow, unchanged |
| cocotb | 2.0.1 in `ROOT/.venv-rtl` (numpy 2.5.1; no pyuvm, no pip) | existing tests stay |
| gcc | system `/usr/bin/gcc` (plus Vivado's bundled gcc used by `xsc`) | the C model is built twice: by `xsc` for xsim and by system gcc as a `.so` for the Python cross-check |

---

## 1. Verification strategy

### 1.1 Division of labour

| method | what it owns | why |
|---|---|---|
| **Formal (SBY)** | Control blocks with small state and a protocol: SPI PHY/controller framing and CRC, register file access, reset values and error codes, IRQ logic, rbus arbiter, sequencer and tile FSMs (safety plus bounded progress, i.e. deadlock freedom), KAT and MBIST control engines at tiny geometry, wpack/CRC-32/checksum update functions, clock mux/divider/ICG glitch freedom, reset synchronizer | These are where corner-case interleavings hide (B1 and B2 were both "command in an unusual state"). Exhaustive at small parameters and cheap. |
| **UVM on xsim** | Chip-level behaviour through the real pins (SPI mode 0, irq/busy/st_pass/bist_en/clkout), end to end: register semantics, weight load/read-back/CRC, inference bit-exact in both formats, format switch, self-run/checksum/counters, KAT/MBIST/strap, debug mux/trace, lane mask, clock config, tiling (KEEP, padding, host swap), error injection, the B1–B7 scenarios, constrained-random interleavings, functional and code coverage. Two further UVM tops run the same sequences faster: DEV (rondo_dev over rbus) and SPI (spi_slave only). | The datapath (HardFloat) and chip integration are beyond formal. Constrained random plus coverage finds interaction bugs that directed cocotb tests miss. The author chose xsim for UVM. |
| **Existing cocotb** (kept, not rewritten) | Core changes C1–C8 (`run_core_c*.py`), T-OLD regression, FULL-geometry Verilator runs (T-FULL, T-KAT FULL, T-CFG), GLS, host API (T-HOST, T-WIDE), suite, lint, synthesis | Already passing and fast under Verilator. UVM does not duplicate them; the matrix (§1.3) cites them where they remain the owner. Two cocotb additions are required: B4 (host) and B7 (core). |

Principles:
1. Every spec **must** maps to at least one check in the matrix (§1.3).
2. Every bug test must be **red on pre-fix RTL and green on fixed RTL**. The pre-fix tree is archived once (task V0.2) and the bug tests are run against it.
3. Every formal job reports PROVEN or BOUNDED(k, with completeness argument). Every assertion has a reachability cover in the **same** configuration. Every job has a "canary" task that must FAIL.
4. UVM scoreboards are independent of the RTL. Datapath results come from the C port of `sim/fpmodel.py` (cross-checked against the Python model). Register semantics come from an SV reference model written from the spec. Packing, CRC, checksum and the KAT LFSR come from C/SV ports of `host/rondo_host/packing.py`, cross-checked the same way.

### 1.2 Configurations (DUT parameter sets)

| id | geometry / parameters | top(s) | use |
|---|---|---|---|
| **S** (SMALL, default) | WIDTH 16, PDIM 8, N_LANES 2, NSLOT 8, NPAR 8, DEPTH 7, NXBUF 4, TILE 1, TILE_B 8, HB_BIT 7, all spec defaults otherwise (ACCSIG_BF16 8, TBITS_FP32 8, NR_ITERS_FP32 2, DBG/TRACE/KAT/SPI_CRC/CLK_ALT 1, MBIST/SCAN/PG 0) | CHIP, DEV | bulk of regression |
| S-TB2 | S with TILE_B 2 | CHIP, DEV | host-swap (O3) tiling with short runs |
| S-MB | S with MBIST 1 | CHIP, DEV | MBIST, strap with MBIST, fault injection (`+define+RONDO_FAULT_INJECT`) |
| S-SCAN-PG | S with SCAN 1, PG 1 | CHIP | test_mode bypasses, pg_req, isolation |
| S-MIN | S with DBG 0, TRACE 0, KAT 0, SPI_CRC 0, CLK_ALT 0, TILE 0 | CHIP | feature-off behaviour: CAPS bits 0, registers read 0, commands give ADDR |
| S-ACC24 | S with ACCSIG_BF16 24 (TILE 1) | DEV | B3: either bit-exact tiling with AW_BF16 = 32 or an elaboration `$fatal` (whichever the fix plan chose) |
| S-KAN | S with LAYER 1 | DEV | B5 CAPS check only (KAN datapath stays in cocotb T-KAN) |
| S-CNT | S with CNT_INIT = 2^32 − 50 | DEV | 64-bit shadow carry |
| **F** (FULL) | spec §1.1 (WIDTH 64, PDIM 40, N_LANES 8), defaults | DEV (backdoor and frontdoor), CHIP (one frontdoor test) | sign-off tier only |
| SPI | `rondo_spi_slave` + reactive rbus slave | SPI | framing/CRC/R sweeps, 65,536-word burst |

KAT signatures: `rtl/chip/rondo_kat_sigs.vh` has per-geometry constants for S and F. For other variants the UVM KAT scoreboard computes the expected signature itself (§3.6). Tests compare KAT_GOT against the scoreboard; they compare KAT_SIG only where the constant is valid for that build.

### 1.3 Verification matrix (spec section → method → check → coverage)

Legend. **FV:** formal job/property (ids in §2). **U:** UVM test (ids in §3.7). **C:** existing cocotb runner. **Cov:** covergroup/bin (§3.8).

| spec § | requirement (summary) | FV | U | C | Cov |
|---|---|---|---|---|---|
| 1.3.5 / 2.2 C1 | start in done cycle completes | — | — (wrapper keeps the gap) | run_core_c1 | — |
| 2.3 C2 | guard_hit count = clamped ladders | — | u_dbg_inject, u_infer_rand (GUARD_HITS vs model) | run_core_c2 | dp_cg.guard |
| 2.4 C3 | EXT_MEM equivalence | — | implied by bit-exact u_infer_* | run_core_c3 | — |
| 2.5 C4 | debug taps = model | — | u_dbg_taps (C-model taps) | run_core_c4 | dbg_cg |
| 2.6 C5 | injection procedures | — | u_dbg_inject, u_fault_localize | run_core_c5 | dbg_cg.inject |
| 2.7 C6 | lane mask: qNaN, timing | — | u_lane_mask | run_core_c6 (+ **B7 addition**) | lane_cg |
| 2.8 C7 | fp32 recip TBITS 8 / NR 2 | — | u_infer_* fp32 bit-exact | run_core_c7 | — |
| 3.3 | glitch-free source mux; reset forces clk; test_mode bypass | FV-CLK.mux1–5 | u_clk_src, u_clk_dead_alt | T-UNITS, T-CLK | clk_cg.src |
| 3.3 | divider ÷1/2/4/8 applied at wrap; ICG glitch-free | FV-CLK.div1–4, FV-CLK.icg1–2 | u_clk_div | T-UNITS | clk_cg.div |
| 3.3 | CLK_CFG applied at CS rise and only if !ACTIVE; blocked while ACTIVE (BUSY_WR) | FV-REGS.clk1–3 | u_clk_div, u_err_busy_wr | T-CLK | clk_cg.apply |
| 3.3 | layer ICG enable = active && !CLK_OFF; test_mode transparent | FV-SEQ.lc1–3 | sva_chip.inactive_clk | T-FMT | fmt_cg |
| 3.3 | CLKOUT f_core/2^K, 0 = off, reset 0 | — | u_clkout | T-CLK | clk_cg.clkout |
| 3.4 | reset sync: async assert, sync deassert after 2 edges; test_mode bypass | FV-RST.1–4 | u_reset_async | T-UNITS | rst_cg |
| 3.4 | core_rst_n is a **flop** (B6), ordering on FORMAT switch | FV-STRUCT.1, FV-SEQ.lc1–3 | sva_chip.core_rst_glitch | — | — |
| 4 | pin behaviour: outputs 0 in reset, registered; miso_oe = 0 when CS high | FV-PHY.oe | sva_chip.pins, u_bringup | T-TOP | pins_cg |
| 5.1–5.2 | opcodes WRITE/READ/STATUS/LOOPBACK/NOP/other | FV-PHY.lb, FV-PHY.st, FV-CTRL.* | u_spi_opcodes | T-SPI | spi_cg.opcode |
| 5.2 | STATUS8 bits; [1:0] = 10 | FV-REGS.s8, FV-PHY.st | u_bringup, u_status8_rand | T-TOP | spi_cg.status8 |
| 5.3.1–2 | write issued after last bit/DCRC; exactly N+1 reads; beyond-burst bytes 0 | FV-CTRL.n1–n6 | u_spi_burst_lengths, u_spi_max_burst (SPI top) | T-SPI | spi_cg.len |
| 5.3.3 | CS rise on word boundary OK; mid-header/word → SPI_FRAME, partial discarded | FV-CTRL.ab1–ab3 | u_spi_abort | T-SPI | spi_cg.abort_pos |
| 5.3.4 | PHY idle, oe = 0 while CS high | FV-PHY.oe | sva_chip.miso_oe | T-SPI | — |
| 5.3.5 | overrun → SPI_FRAME, DEADBEEF | FV-CTRL.ov1–2 | u_spi_overrun (SPI top, slow responder) | T-SPI | spi_cg.overrun |
| 5.4 | CRC-8 0x07; HCRC reject; DCRC drop rest; read DCRC; takes effect next frame | FV-CTRL.crc1–crc5 | u_spi_crc, u_err_crc_inject | T-SPI | spi_cg.crc |
| 5.6 | R ≥ 8 normative, R = 6 verified, random phase | FV-PHY.rx/tx (R 6..10) | all CHIP tests randomize R ∈ {6,7,8,13,16,33}; host-replay R monitor (B4) | T-SPI | spi_cg.R |
| 6.1 | every register: address, access, reset value | FV-REGS.rv*, FV-REGS.acc* | u_reg_reset, u_reg_access (RAL) | T-REG | reg_cg |
| 6.1 | holes → read 0 + ADDR; RO write → RO; RANGE values | FV-REGS.e1–e4 | u_reg_access, u_err_addr | T-REG | reg_cg.outcome |
| 6.2 | CAPS per build (B5: [3:2] encoding, HAS_BIAS) | FV-REGS.caps (per variant) | u_reg_reset in S, S-MIN, S-KAN, S-MB, S-SCAN-PG | — | — |
| 6.3 | CTRL priority, SC, START_BUSY on multiple start bits | FV-REGS.ctrl1–4 | u_ctrl_combos | T-REG | ctrl_cg |
| 6.4 | STATUS fields (ZVALID, WSTALE, XPTR, LANE_EN_APPLIED, HEARTBEAT) | FV-REGS.st* | u_status_fields, u_heartbeat | T-REG/T-SEQ | status_cg |
| 6.5 | each ERR bit set by its cause, W1C, mask → ERR_ANY / IRQ.ERR | FV-REGS.err* | u_err_* (one per bit) | T-REG | err_cg |
| 6.6 | LO read latches HI; CTRL effect next cycle | FV-REGS.shd1–2 | u_reg_shadow (S-CNT) | T-REG | — |
| 7.1 | region decode, holes → ADDR | FV-DEV.dec | u_mem_map_walk | T-REG/T-PACK | mem_cg |
| 7.2 | ACTIVE blocks external memory writes/reads (BUSY_WR); internal masters exempt | FV-DEV.act1–2, FV-ARB.int | u_err_busy_wr, u_kat_* | T-SEQ | err_cg.busy_wr × region |
| 7.3–7.4 | XBUF/ZBUF semantics, cleared on FORMAT switch / soft reset | FV-SEQ.z1 | u_fmt_switch, u_soft_reset | T-FMT | fmt_cg |
| 7.5 | read-back, read cache, latency | — | u_load_readback | T-PACK | load_cg |
| 7.6 | packing, PARTIAL, LOAD_CRC = zlib | FV-PACK.1–6 | u_load_*, u_err_partial | T-PACK | load_cg |
| 7.7 | L half never enabled in bf16; one owner; no write while ACTIVE except KAT/MBIST | FV-DEV.mem1–2 | sva_chip.wmem (bound) | T-UNITS | — |
| 8.2–8.3 | rbus rules 1–5; response ≤ bound; external ≤ 24 cycles | FV-ARB.*, FV-DEV.rb* | sva_chip.rbus (ext + int ports) | T-SVA | — |
| 8.1/robust | arbiter cleared by soft reset; internal master holds valid until handshake | FV-ARB.srst, FV-KAT.rb1 | u_srst_during_kat | — | selftest_cg.srst |
| 9.1 | bring-up ladder | — | u_bringup | T-TOP | — |
| 9.2 | weight load + CRC + read-back | — | u_load_crc, u_load_readback | T-PACK | load_cg |
| 9.3 | single inference | — | u_infer_bf16, u_infer_fp32, u_infer_rand | T-PACK | dp_cg |
| 9.4 / 10.4 | self-run SR_N, SR_COUNT, SR_STOP, SR_DONE irq, latching | FV-SEQ.sr1–5 | u_selfrun_* | T-SEQ | seq_cg |
| 9.5 / 12.4 | FORMAT switch effects, blocked while ACTIVE, RANGE | FV-SEQ.fsw*, FV-REGS.fmt | u_fmt_switch, u_fmt_while_active | T-FMT | fmt_cg |
| 9.6 | soft reset: what is reset and what is kept | FV-REGS.srst, FV-SEQ.srst | u_soft_reset, u_soft_reset_mid_* | T-SEQ | srst_cg (state at SOFT_RST) |
| 9.7 | WDOG flag; recovery | FV-SEQ.wd | u_wdog | T-SEQ | err_cg.wdog |
| 9.8 / 11.5 | KAT register-triggered and strap; st_pass; signature | FV-KAT.* | u_kat_reg, u_kat_strap, u_kat_fault | T-KAT | selftest_cg |
| 9.9 / 11.9 | PWR_CTRL hold / clock-off / pg | FV-SEQ.pwr | u_pwr_ctrl, **u_b2_***, **u_b1_*** | T-SCAN | pwr_cg |
| 9.10 | fault localisation flow | — | u_fault_localize (S-MB) | T-DBG | dbg_cg |
| 10.1–10.2 | launch rule 1–5; POST overlap; t+2 | FV-SEQ.lr1–5 | sva_chip.launch (bound) | T-SEQ | seq_cg.gap |
| 10.3 | counters and clear sources | FV-SEQ.c1–6 | u_counters | T-SEQ | cnt_cg |
| 10.5 | checksum algorithm | FV-CKS.1 | u_selfrun_cksum (scoreboard) | T-SEQ | — |
| 11.2 | DBG_SEL/DBG_DATA, latch timing, fmt_override | — | u_dbg_taps | T-DBG | dbg_cg |
| 11.3 | trace SRC × TRIG × MODE, POST, wrap, STOP_ON_FULL, blocked while armed | FV-TRC (optional) | u_trace_rand | T-TRC | trc_cg |
| 11.6 | MBIST March C−, detection, localisation | FV-MB.* | u_mbist_faults (S-MB) | T-MBIST | mbist_cg |
| 11.7 | scan pin muxing and bypasses | FV-CLK.tm, FV-RST.4 | u_scan_mode (S-SCAN-PG) | T-SCAN | — |
| 12 | dual format, shared store, L half gating | FV-DEV.mem1 | u_fmt_switch, u_infer_* | T-FMT | fmt_cg |
| 18.1–18.2 | tiled == untiled bit-exact, −0 padding | — | u_tile_basic, u_tile_pad, u_tile_rand | run_core_c8, T-TILE, T-CFG | tile_cg |
| 18.5 | TILE_* registers, IRQ/ERR bits, TX/TZ/PS map | FV-REGS.tile | u_tile_regs | T-TILE | tile_cg.regs |
| 18.6 | rules: refusals (TILE_SEQ), STALE, invalidation, KEEP, HOST_SLICE, lane mask; **PWR_CTRL while OPEN (B1)** | FV-TILE.* | u_tile_illegal, u_tile_inval, **u_b1_keep_corehold** | T-TILE | tile_cg |
| 18.7 | host swap O3, TILE_SEQ_CRC | FV-TILE.crc | u_tile_hostswap (S-TB2) | T-WIDE | tile_cg.hs |
| B3 | ACCSIG_BF16 = 24 with TILE | elaboration check | u_tile_basic in S-ACC24 (or expected-fatal compile) | lint variant | — |
| B4 | host sends frames at a legal R after CLK_CFG | — | u_host_replay (R monitor) | **cocotb addition** (transport enforces R) | — |
| B7 | disabled lane in L_FIN + start → qNaN | — | — (unreachable via wrapper) | **cocotb addition** to core C1/C6 test | — |
| elab | §7.1, §10.1, §18.5 parameter checks | — | negative compile tests (`verif/scripts/elab_neg.sh`) | — | — |

### 1.4 Behaviours that depend on the fix plan

`docs/CHIP_FIX_PLAN.md` did not exist when this plan was written. Before writing V16, the Sonnet agent **must** read it and set each row's expected behaviour in `verif/uvm/env/rondo_fix_cfg.svh` (and in the formal properties). The defaults below are the verifier's recommended fixes. The **invariant** column holds whatever the fix chooses and is always checked.

| bug | default expected behaviour (verify report §8) | invariant always asserted |
|---|---|---|
| B1 | PWR_CTRL write while tile OPEN → rejected, ERR.TILE_SEQ, register unchanged | a tiled run never completes with FINAL_DONE and wrong TZ without TILE_STALE/TILE_SEQ being raised |
| B2 | KAT_START / MBIST_START while CORE_HOLD or CORE_CLK_OFF → refused with START_BUSY (alternatively: KAT runs and ends with KAT_FAIL) | ACTIVE always returns to 0 within T_PROGRESS cycles after any command (no hang); `busy` pin follows |
| B3 | TILE && ACCSIG_BF16 ≠ 8 → elaboration `$fatal`, or bf16 PS uses the L half and TILE_GEOM.AW_BF16 = 8 + ACCSIG | S-ACC24 either fails to elaborate with the documented message or is bit-exact |
| B4 | host `set_clock` lowers SCLK before the next frame | no frame on the pins with R < 6 (monitor error), R < 8 is a warning |
| B5 | CAPS[3:2] = 1 for KAN, HAS_BIAS = (LAYER == 0) | CAPS equals the spec formula per build |
| B6 | `core_rst_n` from a flop with async clear by sys_rst_n | structural check plus no glitch on core_rst_n |
| B7 | qNaN written in the L_FIN disabled-lane branch | disabled lane z = qNaN after every start |
| robust | arbiter cleared by soft reset; KAT holds valid until ready; soft reset clears shadows and the read cache (or the spec is changed) | rbus rule 2 on every master port; no internal write after srst |

---

## 2. Formal plan

### 2.1 Infrastructure

* Directory `verif/formal/`; existing `formal/` stays as legacy until each job is superseded (then `scripts/chip_formal.sh` calls `verif/formal/run_formal.sh`).
* Every job `.sby` has tasks **`prove`** (engine list `abc pdr`, then `smtbmc yices` with `mode prove`, depth k), **`bmc`** (backstop, depth given below), **`cover`** (same defines as `prove`: never a relaxed harness), and **`canary`** (`-DCANARY` adds `assert(0)` guarded by a reachable condition such as the first rbus issue; must report FAIL). `run_formal.sh` exports `ABC=/usr/bin/abc`, runs all tasks in parallel (`xargs -P`), and writes `verif/reports/formal_summary.md` with one row per job: PROVEN / BOUNDED(k) / FAIL, covers reached/total, canary OK.
* Property style (Yosys-compatible): harness module `<blk>_f.v` instantiates the DUT. Properties are `always @(posedge clk) if (!init) assert(...)` with history registers or `$past`, and environment `assume`s sit in the same harness. Internal invariants for induction go **inside the RTL** under `` `ifdef RONDO_FORMAL `` (never synthesized, invisible to simulators unless the define is given). This is the only RTL edit this plan asks for, and it needs coordination with the fix-plan owner. If RTL edits are vetoed, use the precedent from `rondo_tile` (`ent_valid`/`ent_tag` observation ports under `` `ifdef RONDO_FORMAL ``).
* `async2sync` for single-clock jobs; `multiclock on` with a `(* gclk *)` global clock for the clock/reset jobs.
* Assume–guarantee: each assumption on a block's inputs names the job/property that proves it as a guarantee of the driving block (contract table §2.6). An assumption with no proof owner must name a UVM assertion that checks it in simulation.
* Completeness for BMC-only jobs: state the bound k and why it covers all behaviours, e.g. "the FSM returns to IDLE within d cycles from any state; k ≥ d + longest command sequence considered".

### 2.2 Per-block jobs, properties, assumptions, proof type

#### FV-PHY — `rondo_spi_phy` (master model, SCLK half period H ∈ [3..5] anyconst, i.e. R 6..10)
Properties:
- **rx:** rx_byte equals the byte the master shifted, at rx_valid.
- **tx:** at every master rising edge, the MISO bit equals bit (7−n) of the byte moved into the shift register.
- **oe:** miso_oe = registered cs_active, and 0 whenever CS is high.
- **edge:** MISO changes only within 4 cycles after a detected SCLK rise or a CS change.
- **ab:** CS rise with bitn ≠ 0 gives mid_byte_abort together with frame_end.
- **lb (new):** opcode 0x0E: MISO byte k+1 = MOSI byte k, and byte 0 = 0x00.
- **st (new):** opcode 0x05: MISO bytes ≥ 1 equal status8 sampled at the byte start, and byte 0 = 0x00.

Remove today's assumption that the opcode is never 0x0E/0x05. Use separate tasks `-DMODE_LB`, `-DMODE_ST` and `-DMODE_HOLD` (today's hold-register path).

Assumption: the controller loads the hold byte between the 1st and 6th SCLK of a byte. Owner: FV-CTRL.tx1.

Proof: `prove` with abc pdr (small state); backstop BMC 400 (≥ 8 bytes at R = 10). Covers: 3 bytes received in each mode, abort mid-byte, R = 6 and R = 10.

#### FV-CTRL — `rondo_spi_ctrl` (fixes F1)
Why the current job is vacuous: byte spacing is fixed at 8 cycles with depth 64, so at most 7 bytes are reached and the write path is never exercised. On top of that, the cover task used a different harness and cover mode does not check assertions.

New harness `spi_ctrl_f.v`:
1. Byte spacing: `assume(gap ≥ GMIN)` with GMIN = 2. This is a **superset** of real behaviour, where the gap is ≥ 8·2·3 = 48 cycles. Properties are written to hold also under overrun (overrun is legal behaviour that raises err_frame). A separate task `-DGMIN=48`, BMC only, checks the "no overrun" property **ov2** with a responder whose latency ≤ 24 (§8.3).
2. rbus responder: ready within 3 cycles, response 1..24 cycles (anyseq), one outstanding. Owner: FV-ARB / FV-DEV.rb.
3. CRC mode anyconst per frame and changes only at frame_start (models SPI_CFG "from next frame"). Owner: FV-REGS.crc.
4. Reference parser in the harness (as today) extended with: assembled write word, per-word DCRC, expected read-byte stream.

Properties:
- **rb1–3:** master rules (valid held, payload stable, ≤ 1 outstanding).
- **n1:** requests only for READ/WRITE after a CRC-clean header.
- **n2:** reqs ≤ N+1.
- **n3:** address = A + reqs.
- **n4:** write data == reference-assembled word.
- **n5:** a write is issued only after a complete word, and its DCRC matched.
- **n6:** after a DCRC mismatch no more requests in the frame and err_crc pulses once.
- **crc1:** HCRC mismatch → no request and err_crc.
- **crc2:** read DCRC byte = crc8 of the 4 bytes sent.
- **tx1:** tx_load timing window, which is the guarantee FV-PHY assumes.
- **rd1:** the read bytes shifted equal the response data, big-endian; **rd2:** no read request beyond N+1; **rd3:** a late response after frame end is dropped (the formal bug from IMPL_LOG T23 #1 stays fixed).
- **ab1:** header abort → err_frame; **ab2:** word-boundary end → no err_frame; **ab3:** mid-word end → err_frame and no request for the partial word.
- **ov1:** a response missing its slot → DEADBEEF bytes and err_frame; **ov2** (GMIN = 48 task): no err_frame ever.
- **unk:** an unknown opcode gives err_frame and nothing else.

Proof: `prove` with abc pdr. If PDR does not converge in 2 h, add `RONDO_FORMAL` invariants in `rondo_spi_ctrl.v`:
- `rem + issued == ntot`
- `addr == A + issued`
- `wpos ≤ 4`
- `mode` legal
- `rd_pend → mode ∈ {RDATA} ∨ ign_rsp ∨ frame ended`
- `hv/spec` consistency
- `crc_q` constant within a frame
Then run smtbmc k-induction (target k ≤ 24 with GMIN = 2).

Backstop BMC depth 160 at GMIN = 2 (≥ 2 complete CRC-mode write words plus a second READ word).

**Covers in the prove configuration** (sanity check that the old vacuity is gone): second WRITE word issued; second READ word; DCRC error after one good word; HCRC error; mid-word abort; word-boundary abort; DEADBEEF; N = 0xFFFF header accepted.

Canary: `assert(!(issue && we && reqs == 1))` must FAIL.

#### FV-REGS — `rondo_regs` (extend the existing k-induction proof)
Keep the existing properties. Add:
- **rv\*:** each register reads its reset value in the first read after reset (`initial assume` for reset, a free read index).
- **acc\*:** RW registers read back the written value masked to implemented bits.
- **e1:** a hole read → 0 and ADDR; **e2:** an RO write → no change, RO error; **e3:** RANGE on XSEL ≥ NXBUF, SR_N ∉ 1..NXBUF, FORMAT > 1, TILE_CFG NSLICE/TBATCH (register unchanged); **e4:** BUSY_WR for FORMAT/LANE_EN/CLK_CFG/PWR_CTRL while active.
- **B1 fix:** PWR_CTRL (and FORMAT, LANE_EN, TILE_CFG) writes while tile_open → TILE_SEQ, unchanged.
- **B2 fix:** KAT_START/MBIST_START while hold/clkoff → per §1.4.
- **ctrl1–4:** full priority table §6.3 (SOFT_RST wins; clears; SR_STOP; at most one start-class pulse in START > SR_START > KAT > MBIST order; others → START_BUSY); TILE_RUN/TILE_ABORT included.
- **err\*:** each ERR bit sets only if its cause input was asserted in the previous cycle; W1C clears exactly the written ones; set-wins-over-clear in the same cycle (document the RTL choice and assert it).
- **irq:** `irq == $past(|(IRQ_STATUS_eff & IRQ_EN))`, and IRQ_STATUS[2] is a read-only mirror.
- **s8:** STATUS8 bit mapping §5.2.
- **clk1–3:** CLK_CFG pending → applied only at frame_end && !active; DIV/SRC_APPLIED read-back.
- **shd1–2:** shadow coherence (existing).
- **srst:** soft-reset effects on reg fields per §9.6 (kept list unchanged, reset list cleared).
- **caps:** CAPS = formula of the parameters. Run for parameter sets {S, S-MIN, S-KAN, S-MB+SCAN+PG} as separate tasks.

Proof: k-induction (already converges at depth 12) and abc pdr. Covers: each error bit, each command, irq rise.

#### FV-ARB — `rondo_rbus_arb` (new)
Environment: masters obey rule 2 (assumed for e/k/m; the k/m side is proven by FV-KAT.rb1 / FV-MB.rb1); the slave responds within 1..L (L anyconst ≤ 8).

Properties:
- **a1:** o_req_valid only in A_REQ, and the payload is stable while waiting.
- **a2:** exactly one response per accepted request, routed only to the owner.
- **a3:** o_req_int == (owner ≠ external).
- **a4:** when idle with e_req_valid, the external master wins.
- **a5:** bounded wait: e_req_valid → e_req_ready within 1 + (L + 2) cycles, i.e. at most one internal access ahead.
- **a6:** no response is lost when rsp_ready = 0 for the external port (future masters).
- **srst (robust fix):** after soft reset the arbiter is idle within 1 cycle and no internal request granted before srst executes after it.

Proof: abc pdr (tiny). Covers: each owner, external preempting a pending KAT request.

#### FV-SEQ — `rondo_seq` (upgrade from BMC 70)
Harness: abstract layer. busy/done after 6..10 cycles (anyconst bounds); C1-tolerant start; guard_hit free while busy. Tile ports become free inputs constrained by the FV-TILE guarantees, instead of tied off.

Assumptions:
- Commands obey the regs priority guarantees (FV-REGS.ctrl).
- FORMAT/LANE_EN/PWR writes not while active (FV-REGS.e4).
- PWR_CTRL changes are **free when not active**. This is new and needed to reach B1/B2.
- **kat_run may arrive while hold/clkoff = 1.** The old assumption that excluded this is removed: that exclusion is how B2 escaped.

Properties:
- **lr1–5:** launch rule §10.2 (single pulse; not while busy/done; ≥ t+2 after done, exactly t+2 in self-run; not while core_rst_n = 0 or within 2 cycles after it rises).
- **lc1–3:** §3.4 ordering: the newly active layer's clock enable comes 2 cycles before its reset release; the old layer goes into reset 2 cycles before its clock is gated; at most one layer out of reset; inactive clk_en = 0 except during the documented window.
- **fsw\*:** a FORMAT switch completes within ≤ 16 cycles, clears XBUF/ZBUF/CHECKSUM/LAST_CYCLES/LOAD_CRC (via the pulses it emits) and sets WSTALE.
- **z1:** zcap only in a done cycle of a non-partial launch.
- **c1–6:** counter semantics §10.3 (increment sources, clears, saturation of GUARD_HITS/NANINF, LAST_CYCLES = cycles start→done).
- **sr1–5:** self-run entry order 0..SR_N−1 cyclic; stops at SR_COUNT; SR_STOP finishes the in-flight inference; IRQ.DONE not set by self-run; SR_STOP with no self-run has no effect.
- **wd:** WDOG event when the latency exceeds a nonzero limit.
- **srst:** soft reset returns to IDLE within 8+1 cycles and holds the layer in reset 8 cycles.
- **pwr:** CORE_HOLD/CLK_OFF never let a launch happen into a held/gated layer.
- **prog1 (deadlock freedom, catches B2):** a "no progress" counter (cycles with seq_active = 1 and no done/kat_done/fail/zcap/srst event) never exceeds T = 10 (layer bound) + 70 (POST walk at WIDTH = 4) + 16 (FSW) + margin. Equivalently: seq_active implies an event within T.
- **prog2:** kat_run is always answered by kat_done or a fail pulse within T, including when the layer is held or gated (B2 fix variant per §1.4).
- **prog3:** a tile launch is always answered by tile_done_p or tile_fail_p within T.

Proof: abc pdr at WIDTH = 4, N_LANES = 2, NXBUF = 4, sr_count ≤ 3 (anyconst). Justification: the counters are compared only for equality with latched values, and the walk length scales with WIDTH. Then smtbmc k-induction. Backstop BMC 120 (> 2 complete self-run passes at the bounds).

Covers: each FSM state, FSW both directions, SR with SR_COUNT 3, SR_STOP mid-run, WDOG, KAT run complete, KAT refused.

#### FV-TILE — `rondo_tile` (upgrade to prove)
Keep TB = 2 and NSLICE ≤ 3. Add free inputs `core_hold_evt` (active layer reset) and `pwr_wr` as the chip can produce them.

Properties:
- **t1:** launch only inside an open sequence.
- **t2:** restore launches only with valid PS tag s−1.
- **t3:** KEEP-seeded launch only if the KEEP valid flag is set **and no layer reset happened since the previous slice (B1)**.
- **t4:** partial slices never write TZ/ZBUF.
- **t5:** refusals → TILE_SEQ, nothing launched.
- **t6:** invalidation causes (srst, abort, FORMAT, KAT/MBIST, WDOG+srst) clear all valid bits, OPEN ← 0, STALE + ERR if open.
- **t7:** SLICE increments only at the end of a non-HOST_SLICE run.
- **t8:** HOST_SLICE closes only by TILE_ABORT.
- **crc:** TILE_SEQ_CRC = crc32 chain over LOAD_CRC at each TILE_RUN since open; restart at slice-0 runs in HOST_SLICE mode, as documented.
- **prog:** TILE_RUN → tile done/fail within TBATCH·T_launch.

Proof: abc pdr. Backstop BMC 80. Covers: FINAL_DONE at NSLICE = 3, TBATCH = 2, KEEP; host-swap restore; each refusal; each invalidation.

#### FV-KAT — `rondo_kat` (new; tiny geometry N_LANES 1, NPAR 2, NWORDS 4, NBWORDS 1, PDIM 2, NXBUF 2; read-back stride parameter so a re-read happens)
Environment: an rbus slave with a 1-cycle-latency memory model (`(* anyconst *)` fault bit or address for fault detection); an abstract seq (kat_done after 1..8 cycles, **or refusal/fail** per the B2 fix).

Properties:
- **rb1:** master rule 2 (valid held until ready; robustness fix).
- **k1:** address sequence = all WEIGHT, then BIAS, then XBUF, in spec order (a harness counter predicts the next address).
- **k2:** written data = kat_element(LFSR) (the harness implements the Galois LFSR 0x80200003, seed 0x1D872B41, advance-then-use).
- **k3:** element exponent ∈ [BIAS−2, BIAS+1].
- **k4:** pass ⇔ signature == SIG and the read-back check passed. With an injected memory fault at a re-read address → fail.
- **k5 (strap):** sequence MBIST → KAT bf16 → FORMAT fp32 → KAT fp32 → FORMAT bf16, and busy throughout.
- **k6:** st_pass is 0 until a full pass.
- **prog:** KAT always ends (done or fail) within T_KAT (computed from the geometry), **including when the sequencer refuses (B2)**.
- **srst:** after soft reset no further request.

Proof: BMC to completion. The full KAT run at this geometry is < 400 cycles, so BMC at depth T_KAT + 20 explores every environment behaviour up to termination; together with **prog** this is a complete check of the terminating run. Also try abc pdr.

#### FV-MB — `rondo_mbist` (new; N_LANES 2, NWORDS 4, NBWORDS 1, NPAR 1)
The harness contains a formal SRAM model with one anyconst fault (stuck-at-0/1, transition, coupling aggressor/victim) or no fault.

Properties:
- **m1:** March C− element order and address direction.
- **m2:** every address of every store and half visited by every element.
- **m3:** no fault → PASS and FAIL = 0.
- **m4:** fault → FAIL, with fail lane/half/bias/address equal to the injected location (first failure) and XOR non-zero.
- **m5:** master rule 2 on its port.
- **m6:** terminates within T_MB.

Proof: BMC to completion (T_MB at this size ≈ 10·4·2·2·(1 + lanes) < 500), which is complete for the bounded run.

#### FV-PACK — `rondo_wpack` plus CRC-32 / checksum units
- **p1:** staging semantics §7.6 (tag change with fields pending → PARTIAL and clear; commit at f = NPAR−1; missing fields → PARTIAL, filled with 0).
- **p2:** committed H/L halves equal the bf16/fp32 split of the staged elements.
- **p3:** read cache returns the stored element and is invalidated on commit.
- **p4:** `load_crc_next == crc32_update(load_crc, wdata[W-1:0] LE bytes)` on every accepted write, unchanged otherwise, and 0 after a clear.
- **FV-CKS.1:** `rondo_cksum` result == `update(prev, ZBUF)` (harness function) at WIDTH = 4.

Proof: k-induction/PDR (one-step functional properties). Note: the CRC-32 functional property is a one-step equivalence; PDR handles the 32-bit XOR logic easily.

#### FV-CLK / FV-RST — clock and reset primitives (multiclock; `(* gclk *)` global step; clk0/clk1 free with each half period ≥ 2 global steps, assumed)
- **mux1:** never `a0 && b0`.
- **mux2:** every clk_out rising edge coincides with a rising edge of the source whose enable is 1, and every falling edge with that source's falling edge (no runt pulse). Precisely: `$rose(clk_out) → ($rose(clk0) && a0) || ($rose(clk1) && b0)`, and similarly for `$fell`.
- **mux3:** enables change only while their clock is low.
- **mux4:** rst_n low → selects clk0 (a0 = 1, b0 = 0). Glitch properties are excluded in the reset step, a documented exemption: an asynchronous reset may truncate a clk1 pulse. Waiver W-CLK-1.
- **mux5:** after sel changes with both clocks toggling, the switch completes within 6 edges of the slower clock (bounded response).
- **tm:** test_mode → clk_out == clk0.
- **icg1:** en_l changes only when clk is low; **icg2:** gclk high pulses are complete clk high phases.
- **div1:** exactly one gclk rising edge per N clk_in rising edges; **div2:** div changes take effect only at wrap; **div3:** test_mode → N = 1; **div4:** reset → N = 1.
- **RST.1:** arst_n low → rst_n_out low in the same global step; **RST.2:** rst_n_out rises only at a posedge clk with arst_n high for the previous STAGES posedges; **RST.3:** no rising glitch; **RST.4:** test_mode bypass.
- **sync:** `rondo_sync` latency = STAGES.

Proof: abc pdr / k-induction (tiny state).

#### FV-DEV — `rondo_dev` integration with abstract layers (upgrade of dev_bus)
Use TILE = 1 (today the TILE = 0 build is checked), KAT = 0/1 tasks, DBG = 0, TRACE = 0.

Properties:
- **rb\*:** external access ≤ 24 cycles; response ≤ MAX_RSP (bound per the fixed spec value).
- **act1:** no external memory write while ACTIVE (WEIGHT/BIAS/XBUF/TX/PS); **act2:** internal (int = 1) writes exempt.
- **dec:** decoded region and error per address class (abstract address generator over region bases ± holes).
- **mem1:** L half CE never set while fmt = bf16 (internal wmem ports exposed by RONDO_FORMAL); **mem2:** single owner.
- **prog:** ACTIVE clears within T after the last command with no new commands.
- B1/B2 end to end: the PWR_CTRL/KAT_START interleavings reachable from rbus.

Proof: BMC 120 plus induction attempt. Completeness argument: every command sequence of ≤ 6 rbus accesses at the abstract layer latency fits in 120 cycles. This job is not expected to become an unbounded proof; it stays the integration backstop.

#### FV-STRUCT — structural checks (yosys script `struct_checks.ys`, not SBY)
- **1:** the driver of each `core_rst_n[f]` net is a `$adff`/`$adffe` cell (B6), checked with `select` and `-assert-count`.
- **2:** only `rondo_icg` produces latches (`select t:$dlatch* -assert-count 3`).
- **3:** the only async-reset nets are sys_rst_n and core_rst_n.
- **4:** no combinational path from an input pin to an output pin. Run on rondo_chip_top SMALL.

#### FV-TRC (optional, if time allows) — `rondo_trace`
NVALID / TRIG_IDX consistency, chronological read order, POST count, STOP_ON_FULL, blocked config while armed. BMC 150 at DEPTH 8.

### 2.3 Not formal (simulation only), and why
HardFloat datapath, `rondo_layers`, `fused_coproc_pipe` (formal only in Verilog would be equivalence: no eqy installed), dbgmux/trace data, chip-level SPI end to end (≥ 600 cycles per frame at R ≥ 6, too deep), KAT signature values.

### 2.4 Vacuity and sanity per job
1. Every `assert` antecedent gets a `cover` in the same task configuration (generated: for each `if (C) assert(P)`, add `cover(C)`).
2. Canary task must FAIL.
3. Mutation: `verif/formal/mutate.sh <job> 30` uses yosys `mutate -list 30 -seed 1 -o mutants.ys` on the DUT module only. Each mutant is run with the `prove`/`bmc` task. Kill rate ≥ 80% for spi_ctrl, regs, seq, tile, arb; survivors are listed with a one-line equivalence/benign argument in `verif/reports/mutation_<job>.md`.
4. Assumption audit: each `assume` line carries the comment `// A: <justification>; proven by <job.prop> | checked in sim by <sva name>`.

### 2.5 Proof-status sign-off target

| job | target | minimum acceptable |
|---|---|---|
| FV-PHY | PROVEN (per mode) | BMC 400 + all covers |
| FV-CTRL | PROVEN | k-induction with RONDO_FORMAL invariants; BMC 160 not acceptable alone (F1) |
| FV-REGS | PROVEN | — |
| FV-ARB | PROVEN | — |
| FV-SEQ | PROVEN | BMC 120 + prog properties proven by induction |
| FV-TILE | PROVEN | BMC 80 + covers |
| FV-KAT, FV-MB | BMC to completion (complete) | — |
| FV-PACK, FV-CKS | PROVEN | — |
| FV-CLK, FV-RST | PROVEN | — |
| FV-DEV | BMC 120 + covers | BMC 60 |
| FV-STRUCT | PASS | — |

### 2.6 Assume–guarantee contract table (to be kept in `verif/formal/CONTRACTS.md`)

| consumer assumption | provider guarantee |
|---|---|
| seq: commands one-hot by priority | REGS.ctrl1–4 |
| seq: no FORMAT/LANE_EN/PWR change while active | REGS.e4 |
| seq: tile_launch only when OPEN and the layer is ready | TILE.t1 |
| ctrl: crc_en changes only between frames | REGS.crc + spi_slave wiring (sim SVA) |
| ctrl: rbus slave answers within 24 cycles | DEV.rb |
| phy: hold-byte load window | CTRL.tx1 |
| arb: internal masters hold valid | KAT.rb1, MB.m5 |
| kat: seq answers or refuses | SEQ.prog2 |
| clk jobs: clock periods ≥ 2 global steps | environment (oscillator); UVM clock generator respects it |

---

## 3. UVM on xsim

### 3.1 xsim capabilities and limitations (probe each in task V0.1; fall back as listed)

| feature | expectation | probe | fallback |
|---|---|---|---|
| UVM 1.2 library | precompiled `-L uvm` | compile/run hello test | none needed |
| `uvm_reg` / RAL | supported (UVM 1.2) | small reg block, frontdoor | — |
| `uvm_hdl_*` backdoor (needs UVM DPI) | **uncertain** in the xsim build | `uvm_hdl_read` on a tb signal | backdoor through a bound SV module with tasks (§3.4), no `uvm_hdl` |
| constraint solver | basic and moderate constraints fine; heavy `foreach`/`unique`/`solve before` can be slow or unsupported | constrained frame item with dynamic payload | keep constraints on scalars; fill large arrays in `post_randomize()` with `$urandom` |
| covergroups | bins, cross, illegal/ignore bins, `iff` | sample + xcrg report | avoid `with` filters and `binsof … intersect` with complex expressions; use explicit bins |
| concurrent SVA (`|->`, `##[m:n]`, `$past`, `$rose`) | supported | 3 properties incl. a failing one | immediate assertions in clocked always blocks |
| `bind` (into module instances incl. generate scopes) | expected supported | bind a checker into `u_dev.u_seq` and a generate-scope instance | instantiate checkers in tb_top with hierarchical refs |
| DPI-C imports (scalar int/bit vectors ≤ 64 b) | supported via `xsc` + `--sv_lib` | call `fpm_fma()` | precomputed vector files (§3.5 mode B) |
| open arrays in DPI | uncertain | — | not used (scalar API) |
| `$readmemh` of seed files | relative to the run directory | — | copy `rtl/core/recip_seed_*.mem` into each run dir |
| code coverage | `--cc_type sbct` | small run | — |
| RTL parsing | `` '0 ``, `$clog2` in parameters, `initial $fatal`, HardFloat | compile S and F tops | `--relax`; report anything needing an RTL edit, do not edit RTL |
| timescale | RTL files lack `` `timescale `` | — | `xelab --timescale 1ns/1ps` (or `--override_timeunit --override_timeprecision`) |

Results go into `verif/TOOLCHAIN.md` (command lines, versions, pass/fail, chosen fallbacks).

### 3.2 Testbench tops

1. **`tb_chip_top.sv` (CHIP).** DUT `rondo_chip_top` with config parameters from `` `include "cfg_<id>.svh" ``.
   - Clock generators: `clk` with period P0 and `clk_alt` with period P1 (independently randomizable, jitter-free, phase-random; clk_alt may be stopped for the "dead clk_alt" test).
   - Interfaces: `spi_if` (sclk, cs_n, mosi, miso, miso_oe); `pins_if` (rst_n, bist_en, test_mode_pin, irq, busy, st_pass, clkout, pg_req).
   - `probe_if` bound into `u_dev`: clk_core, sys_rst_n, ACTIVE, the external rbus port of `rondo_dev`, the arbiter output port with `rb_req_int`, the layer start/done/zcap/fmt_applied/lane_en_applied, frame_end, CLK_CFG applied, tile open.
   - Backdoor helper module bound into `u_dev`.
2. **`tb_dev_top.sv` (DEV).** DUT `rondo_dev` (as in `sim/tb_chip_vs_core.v` but without bare cores). An rbus **active** agent replaces SPI, so it is about 30× faster for datapath, tiling and self-run randomisation. The same sequences run through a swappable RAL adapter.
3. **`tb_spi_top.sv` (SPI).** `rondo_spi_slave` with a reactive rbus slave agent (random ready/latency, slow mode for overrun) and a memory model. Used for protocol sweeps and the 65,536-word burst.

### 3.3 Agents
* **spi_agent** (active/passive).
  - `spi_frame_item`: opcode, addr[24], len[16], data[$], crc_en, corrupt {none, hcrc, dcrc@word k, bitflip@byte b}, abort {none, after byte b, mid-bit}, R (core cycles per SCLK, real-valued via SCLK half period in ns), cs_setup, inter-frame gap, tail bytes beyond burst.
  - Driver: mode 0, MSB first; SCLK derived from a time base (not from clk_core) so R is exact relative to the **divided** clock; random phase.
  - Monitor: reconstructs frames from the pins independently of the driver (samples MOSI on the SCLK rise, MISO on the rise as the Pi does). Checks R ≥ 6 against `probe_if`'s current f_core (error), warns below 8. Publishes `spi_frame_txn` (incl. MISO bytes).
  - Built-in CRC-8 (poly 0x07; check value `crc8("123456789") == 0xF4` tested at build time).
* **rbus_agent.** Active master (DEV top), reactive slave (SPI top), passive monitors on the `rondo_dev` external port and the arbiter output (int flag). Transactions: we, addr, wdata, rdata, err, int, t_req, t_acc, t_rsp.
* **pins_agent.** Drives rst_n (sync/async pulses, glitch), bist_en strap, test_mode. Monitors irq/busy/st_pass edges with timestamps and measures clkout frequency (edge count over a window → K).
* **layer_mon** (passive, from `probe_if`): launch events {fmt, xptr, lane_en_q, tile seed/save/last}, done, done_final, zcap with z vector, guard pulses.

### 3.4 Register model (RAL) and backdoor
* `verif/uvm/ral/gen_ral.py` reads `host/rondo_host/regmap.py` (single source) and writes `rondo_ral_pkg.sv`: one `uvm_reg` per register with fields per spec §6 (access policies RO, RW, W1C, WO → `"WO"` with read-0 check in the predictor, CTRL bits `"W1"`-like command fields modelled as WO). Build-dependent resets (CAPS, GEOM*, LANE_EN, KAT_SIG*) are set from cfg parameters at build time. `uvm_mem` objects: XBUF, ZBUF (RO), TRACE (RO), BIAS, WEIGHT, TX, TZ (RO), PS. Address map: word addressing, `n_bytes = 4`, `addr_unit = word`.
* Adapters: `rondo_reg2spi_adapter` (single access → WRITE/READ frame N = 0; burst sequences bypass the adapter and use `spi_burst_seq`), `rondo_reg2rbus_adapter`.
* Predictor: **not** `uvm_reg_predictor` alone. `rondo_ref_model` (§3.6) predicts every access outcome (data, side effects, error bits) and updates the RAL mirror; the standard RAL `mirror(UVM_CHECK)` is used only for plain RW/RO registers.
* Backdoor: `rondo_backdoor` SV module bound into `rondo_dev`. Tasks `peek_weight(lane, caddr, half) → [NPAR*16]`, `poke_weight(...)`, the same for bias/PS/TX/TZ, plus `peek_xbuf/zbuf`, via hierarchical references to `u_mem.lane[l].u_wh.mem` etc. (paths centralised in `rondo_hdl_paths.svh`). It is exposed to UVM through an abstract class `rondo_bd_api` implemented inside the bound module (the "abstract class / concrete in module" pattern; no `uvm_hdl` dependency). Used for FULL-geometry fast loads (§3.9) and for fault injection (forcing the RONDO_FAULT_INJECT `f_*` registers).

### 3.5 Reference models and the bit-exact float model
**Decision: DPI-C port of `sim/fpmodel.py` (mode A, default) plus a precomputed-vector mode (mode B, fallback and cross-check).**

* `verif/model/rondo_fpmodel.c/.h`: integer-exact implementation.
  - `fma(fmt EXP, SIG, a, b, c)` with RNE, subnormals, overflow to Inf, zero-sign rule `sa & sc`. Exact via a 192-bit integer significand (three uint64 words or `__int128` plus a sticky bit) and exponent alignment with sticky.
  - `widen`/`narrow` (narrow uses the round/sticky/lsb rule of fpmodel).
  - `recip_stage` (seed tables loaded from the same `.mem` files, TBITS, NR_ITERS, EPS, guard).
  - `scan`, `affine`, and a full layer: `fpm_layer(geo, fmt, accsig, tbits, nr, lane_mask)` including qNaN for disabled lanes.
  - Tiling helpers: `affine` over a concatenated PDIM' = S·PDIM; `fpm_acc_after(c)` for PS read-back checks in host-swap mode.
  - Specials: fpmodel asserts no Inf/NaN operands. The C model implements HardFloat's RISC-V rules for Inf/NaN (canonical qNaN 0x7FC0/0x7FC00000, Inf·0 = NaN, Inf−Inf = NaN). This part is validated against RTL (cocotb harness on `fp_fma_pipe`), not fpmodel, and until validated NaN/Inf tests only check classes (NaN/Inf/finite) plus NANINF_CNT.
  - DPI API uses scalar ints only, with state inside C: `fpm_cfg(...)`, `fpm_set_w(lane, chain, c, bits)`, `fpm_set_b(lane, chain, bits)`, `fpm_set_x(i, bits)`, `fpm_run()`, `fpm_z(j)`, `fpm_hit(j)`, `fpm_a(j,k)`, `fpm_acc(j,k)`, `fpm_k0(j)`, `fpm_k1(j)`.
  - Also ported to C: `crc8`, `crc32`, checksum `fold/update`, the KAT LFSR and `kat_element`.
* Cross-check `verif/model/test_fpmodel_c.py` (run with `.venv-rtl/bin/python -I`, ctypes on the gcc-built `.so`):
  - ≥ 10^6 random fma per format (including accumulator formats AW 16 and 32, ACCSIG 24) with directed edges (±0, subnormals, max finite, carries, ties);
  - 10^5 recip_stage;
  - 300 SMALL layers per format, 4 FULL layers per format, 50 tiled cases vs `chip_common.model_layer`;
  - checksum/CRC/LFSR vs `host/rondo_host/packing.py`.
  - Must be 100% bit-identical. Runs in the regression `smoke` tier.
* Mode B: `verif/model/gen_vectors.py` writes `$readmemh` files (weights per lane/address/field, x, expected z, hits, LAST_CYCLES from bare-core-equivalent formulas only if needed) from fpmodel. The scoreboard switches with `+FPM_MODE=VEC`. FULL directed tests (Waveform coefficients from `workloads/results/waveform_coeffs.npz`) use mode B as a second, independent oracle.
* Embedding Python in xsim via DPI was rejected: it would link libpython into xsim's bundled runtime, which is fragile, slow and not portable.
* **`rondo_ref_model` (SV)** is a transaction-level model of the register/memory/sequencer semantics, written from the spec, with the host mock `host/rondo_host/model.py` as a readable reference:
  - Decode, access types, reset values; ERR/IRQ prediction; CTRL priority; WSTALE/ZVALID; FORMAT switch effects; soft reset kept/cleared lists; LOAD_CRC; staging/PARTIAL; tile state machine (OPEN, SLICE, valid/tags, STALE, refusal rules); self-run expectations (entries, counts, CHECKSUM/SR_PASS); trace configuration rules.
  - **Observe-then-predict for timing.** ACTIVE, done timing and frame_end come from `probe_if`, so outcomes that depend on timing (BUSY_WR, START_BUSY) are predicted from the state observed at the moment the rbus monitor sees the access accepted. Cycle-exact quantities (LAST_CYCLES, BUSY_CYC) are checked against `layer_mon` timestamps (LAST_CYCLES == cycles from start edge to done edge, §10.3), not predicted from first principles.

### 3.6 Scoreboards
* `reg_sb`: every rbus response (data and err) vs `rondo_ref_model`; every ERR/IRQ bit change explained by a predicted cause within the window (otherwise "unexplained ERR bit" error).
* `dp_sb`: on each zcap/done_final, the z vector vs `fpm_layer` evaluated on the **model's** shadow weights (built from accepted WEIGHT/BIAS writes through the packing model, never from a backdoor read), XBUF entry, fmt, lane mask, tile mode. Also checks GUARD_HITS and NANINF_CNT deltas, ZBUF reads, TZ reads, PS reads (host swap).
* `mem_sb`: read-back of WEIGHT/BIAS/XBUF/TX/PS vs the model; optional backdoor compare of the physical H/L words after each commit (checks the §7.6 split independently).
* `cksum_sb`: CHECKSUM, SR_PASS_CKSUM, LOAD_CRC, TILE_SEQ_CRC vs the C ports.
* `kat_sb`: expected signature from LFSR → `fpm_layer` per entry, 2·NXBUF inferences with the §10.5 update. Compares KAT_GOT_*, then KAT_SIG (where valid), ST_STATUS bits, the st_pass pin.
* `pin_sb`: irq == registered |(IRQ_STATUS & IRQ_EN); busy == ACTIVE delayed by the output flop; st_pass semantics; outputs 0 in reset; clkout frequency vs CLKOUT_CFG.
* **No-hang watchdog** (`env` level): ACTIVE high for more than T_PROGRESS cycles without a progress event (done, rbus internal access, kat/mbist status change) → UVM_ERROR "hang". This catches B2-class bugs in every test. T_PROGRESS is set from the geometry: max(LAST_CYCLES_max·2, POST walk, KAT gap) ≈ 2,000 at S, 5,000 at F.

### 3.7 Sequences and tests
Base sequences (virtual sequencer `rondo_vseqr` with handles to spi/rbus/pins sequencers and the RAL):
`reset_seq(async|sync, strap)`, `reg_wr/rd`, `burst_wr/rd(addr, data[], crc)`, `load_weights_seq(W, B, order = natural|shuffled|partial)`, `write_x_seq`, `start_seq`, `wait_irq_or_poll_seq`, `read_z_seq`, `selfrun_seq(n, count, stop_at)`, `fmt_switch_seq`, `kat_seq`, `mbist_seq`, `dbg_seq(lane, sig, idx)`, `trace_seq(cfg)`, `tile_seq(NSLICE, TBATCH, KEEP, HOST_SLICE, pad)`, `clk_cfg_seq(div, src)` (lowers SCLK **before** the next frame, §14.3), `err_inject_seq(kind)`.

Tests (all extend `rondo_base_test`; each randomizes R, clk/clk_alt periods, CRC mode and inter-frame gaps unless pinned; config `id` from §1.2):

| id | config(s) | content / checks |
|---|---|---|
| u_bringup | S, S-MIN, F(CHIP) | §9.1 ladder: LOOPBACK 16 random bytes, STATUS8, CHIP_ID/VERSION/CAPS/GEOM/EPS, SCRATCH patterns, CLKOUT K = 3 (fast) |
| u_heartbeat | S (HB_BIT 7) | STATUS[6] toggles every 2^7 cycles; not cleared by CNT_CLR/soft reset |
| u_reg_reset | S, S-MIN, S-KAN, S-MB, S-SCAN-PG, S-ACC24 | every register reset value incl. CAPS (B5), GEOM, TILE_GEOM (B3) |
| u_reg_access | S | RAL `uvm_reg_access_seq`-style walk with custom expectations: RW patterns, RO writes → RO err, holes → ADDR + 0, W1C, WO reads 0, RANGE values; random order, CRC on/off |
| u_reg_shadow | S-CNT | LO→HI shadow incl. carry; interleaved burst read |
| u_ctrl_combos | S | all 2^15 CTRL combinations sampled (random 2,000, plus each single bit, plus all start-bit pairs) in idle and ACTIVE states; priority and START_BUSY |
| u_status_fields | S | each STATUS bit in its producing state |
| u_spi_opcodes | SPI, S | every opcode incl. unknown, NOP 0x00/0xFF, STATUS any length, LOOPBACK long |
| u_spi_burst_lengths | SPI | N+1 ∈ {1, 2, 3, 17, 255, 256, 257, 4096}; extra tail bytes return 0 with no access; read N+1 exactly (rbus monitor count) |
| u_spi_max_burst | SPI (nightly) | N = 0xFFFF write + read (65,536 words) to the reactive slave memory |
| u_spi_abort | SPI, S | abort after each header byte index, mid-word at each byte and bit, on word boundary; partial word dropped; SPI_FRAME as specified |
| u_spi_crc | SPI, S | CRC on/off toggled mid-session (effect next frame); bad HCRC, bad DCRC at word k (later words dropped), read DCRC check |
| u_spi_overrun | SPI | slow responder → DEADBEEF + SPI_FRAME; normal responder at R = 6 → never |
| u_load_crc | S, S-TB2 | load bf16/fp32 random weights in natural order; LOAD_CRC = zlib; CRC_CLR; WSTALE clears |
| u_load_readback | S | shuffled-order element writes, read-back bursts, read-cache effects; reads during ACTIVE → 0 + BUSY_WR |
| u_err_partial | S | tag change with pending fields; commit with missing fields |
| u_infer_bf16 / u_infer_fp32 | S, F(DEV) | load, XSEL random, START, irq wait, ZBUF bit-exact vs C model, LAST_CYCLES vs layer_mon, GUARD/NANINF counts |
| u_infer_rand | S (DEV + CHIP) | 200 inferences with random weights/inputs incl. near-pole biases (guard hits), extreme exponents, ±0, subnormals; random XSEL; random reads of STATUS/ZBUF during busy |
| u_naninf | S | inputs producing Inf/NaN → NANINF_CNT, ERR.NAN_INF; class checks (§3.5) |
| u_lane_mask | S, F(DEV) | masks 0, all-ones, single, random; qNaN z; GUARD/NANINF only enabled lanes; LANE_EN_APPLIED; blocked while ACTIVE |
| u_selfrun_* | S | SR_N 1..4 × SR_COUNT {0 + SR_STOP at random time, 1, SR_N, 3·SR_N+1}; t+2 spacing (SVA); CHECKSUM / SR_PASS_CKSUM / SR_DONE_CNT / SR_CYC / INFER_CNT / BUSY_CYC; IRQ.DONE not set; SR_STOP without self-run no effect |
| u_counters | S | CNT_CLR / CKSUM_CLR / GUARD_CLR effects; TOTAL_CYC monotonic |
| u_wdog | S | WDOG_LIMIT below LAST_CYCLES → ERR.WDOG; inference still completes; recovery via SOFT_RST |
| u_fmt_switch | S, F(DEV) | bf16→fp32→bf16 repeated with reload; effects §12.4; kept state; inactive layer clock off (SVA); ZVALID/WSTALE; same-value write still clears |
| u_fmt_while_active | S | FORMAT/LANE_EN/CLK_CFG/PWR_CTRL writes during ACTIVE → BUSY_WR; FORMAT = 2 → RANGE |
| u_soft_reset | S | at random points: idle, mid-load, mid-inference, mid-self-run, mid-KAT, mid-MBIST, mid-trace, mid-tile (OPEN, running); check the §9.6 kept and cleared lists; next inference bit-exact |
| u_srst_during_kat | S | SOFT_RST while the KAT streams writes **and** SPI traffic is present; no stale internal write after srst (robustness item) |
| u_kat_reg | S, F(DEV) | KAT_START per format; KAT_GOT == kat_sb; ST_STATUS; SELFTEST_DONE irq; weights/XBUF overwritten, WSTALE, LOAD_CRC cleared |
| u_kat_strap | S, S-MB | bist_en = 1 at reset: order MBIST → bf16 → fp32 → FORMAT bf16, busy pin high throughout, st_pass, ST_STATUS.AT_RESET; no SPI needed |
| u_kat_fault | S (FAULT_INJECT) | stuck weight bit and stuck bias word → KAT_FAIL, st_pass 0 |
| u_mbist_faults | S-MB | stuck-at 0/1, transition, coupling on random lane/half/addr/bias → MBIST_STATUS fields, FAIL_ADDR, FAIL_XOR |
| u_pwr_ctrl | S | CORE_HOLD / CORE_CLK_OFF / both; START/SR_START refused as specified; leakage flow §9.9 restores without reload |
| u_dbg_taps | S | DBG_SEL sweep sig 0..7 × lane × idx (incl. out-of-range), 4-cycle latch and DBG_LATCH; fmt_override; values vs `fpm_a/acc/k0/k1/z` |
| u_dbg_inject / u_fault_localize | S, S-MB | §2.6 a/b/c procedures and §9.10 flow end to end with an injected stuck bit |
| u_trace_rand | S | random SRC × TRIG × MODE × POST × STOP_ON_FULL; check NVALID, TRIG_IDX, chronology, timestamps, TRC_DONE irq, TRC_CFG blocked while armed (ref model replays the source stream from monitors) |
| u_clk_div | S (CHIP) | DIV 0..3 via CLK_CFG, applied only at CS rise and only if !ACTIVE; SPI continues at R ≥ 8 of the new f_core (sequence lowers SCLK first); DIV_APPLIED read-back |
| u_clk_src | S (CHIP) | SRC switch with both clocks running (random period ratio 0.3–3); no glitch (sva_chip.clk_glitch measures min pulse widths on clk_core) |
| u_clk_dead_alt | S | SRC = 1, then stop clk_alt → chip dead; rst_n pulse recovers on clk |
| u_clkout | S | K 0..15 (K ≤ 6 measured, larger spot-checked) |
| u_reset_async | S | rst_n asserted at random phases incl. mid-frame, mid-inference, during clock switch; outputs 0; recovery |
| u_scan_mode | S-SCAN-PG | test_mode bypasses (§11.7), pg_req per format, isolation, reset hold ≥ 16 cycles |
| u_tile_regs | S | TILE_CFG/STATUS/GEOM/SLICE access rules, RANGE |
| u_tile_basic | S, S-ACC24, F(DEV) | NSLICE 1..4 × TBATCH 1..TILE_B, both formats; TZ and ZBUF vs untiled C model with PDIM' = S·PDIM (bit-exact) |
| u_tile_pad | S | p not a multiple of PDIM with −0 weight / +0 input padding; crafted −0 accumulators (a +0-padding negative control shows the difference) |
| u_tile_keep | S | KEEP mode slices |
| u_tile_hostswap | S-TB2 | HOST_SLICE O3, batch 3·TILE_B, PS save/restore via SPI, TILE_SEQ_CRC incl. slice-0 restart rule |
| u_tile_illegal | S | every refusal of §18.6 (START, SR_START, KAT, MBIST, TILE_CFG, FORMAT, LANE_EN, **PWR_CTRL (B1)**, TILE_RUN with EN = 0) |
| u_tile_inval | S | wrong PS tag, out-of-order slice → STALE + refusal; soft reset / WDOG / TILE_ABORT / FORMAT / KAT / MBIST invalidation |
| u_tile_rand | S, S-TB2 | random legal and illegal tile command streams; ref-model tile FSM; bit-exact results when FINAL_DONE |
| **u_b1_keep_corehold** | S | KEEP, slice 0, PWR_CTRL 1 then 0, remaining slices: expected per §1.4; invariant "no silent wrong TZ". Also non-KEEP variant (must stay bit-exact) |
| **u_b2_kat_pwr** | S, S-MB | PWR_CTRL ∈ {01, 10, 11} then KAT_START, MBIST_START, START, SR_START, TILE_RUN: behaviour per §1.4; ACTIVE never hangs (watchdog); SOFT_RST not needed |
| **u_b3_acc24** | S-ACC24 | bf16 tiled bit-exact and TILE_GEOM.AW_BF16 = 32, **or** `verif/scripts/elab_neg.sh` expects the `$fatal` text |
| **u_b4_host_replay** | S (CHIP) | `verif/scripts/host_frames.py` runs `Rondo.set_clock()/set_format()` against a recording MockTransport that logs (frame bytes, SCLK hz). The UVM test replays the log with SCLK as recorded and f_core from CLK_CFG; the spi monitor errors on R < 6. Red on the pre-fix host, green after |
| **u_b5_caps** | S-KAN, S | covered by u_reg_reset (CAPS formula) |
| **u_b6_core_rst** | S | sva_chip.core_rst_glitch over many FORMAT switches and PWR toggles; FV-STRUCT.1 is the primary check |
| u_err_* | S | one directed test per ERR bit 0..15 (cause → bit set, ERR_MASK effect on STATUS8[7]/IRQ.ERR/pin, W1C) |
| u_chip_rand | S (CHIP + DEV) | long constrained-random mix (weighted: loads 15%, inference 20%, self-run 10%, reg traffic 20%, fmt switch 5%, KAT 3%, tile 15%, dbg/trace 7%, soft reset 3%, errors 2%) with all scoreboards on; 20k rbus accesses |
| u_full_frontdoor | F (CHIP) | sign-off tier: full Waveform weight load via SPI at R = 8, both formats, 4 inferences each, self-run 4 × 3 (expected z also from mode-B vectors) |

### 3.8 Functional coverage model (`rondo_cov.sv`, sampled from monitors/model)

| covergroup | coverpoints and crosses (explicit bins) |
|---|---|
| spi_cg | opcode {WRITE, READ, STATUS, LB, NOP00, NOPFF, unknown}; crc_en; len {1, 2, 3–16, 17–255, 256, 257–4095, ≥4096}; abort_pos {none, hdr0..hdr6, word-byte0..3, dcrc, boundary}; corrupt {none, hcrc, dcrc}; R {6, 7, 8, 9–12, 13–16, 33}; overrun; cross opcode×crc×len, opcode×abort, R×opcode |
| reg_cg | register (all §6.1 + 0x50–0x54) × op {rd, wr} × outcome {ok, ADDR, RO, BUSY_WR, RANGE, TILE_SEQ}; illegal crosses excluded explicitly |
| ctrl_cg | each CTRL bit × state {idle, ACTIVE, OPEN}; start-pair combos; SOFT_RST combined with others |
| err_cg | each ERR bit {set, masked, cleared W1C}; ERR_ANY → irq pin |
| irq_cg | IRQ bit × IRQ_EN bit × pin level |
| status_cg | each STATUS bit observed 0 and 1 |
| load_cg | fmt × region {W, B, XBUF, TX, PS} × order {natural, shuffled} × PARTIAL kind × readback while {idle, ACTIVE} |
| dp_cg | fmt × lane_mask class {all, none, single, random} × output class per element {normal, subnormal, ±0, Inf, NaN, guard-clamped}; guard hits per inference {0, 1, many} |
| seq_cg | mode {single, self-run} × SR_N 1..4 × SR_COUNT {0, 1, =N, >N} × stop {none, during WAIT, during POST}; XSEL 0..3 |
| fmt_cg | transition {b→f, f→b, b→b, f→f} × weights reloaded {y, n} × attempted while ACTIVE |
| srst_cg | soft reset in state {idle, load, WAIT, POST, self-run, KAT, MBIST, trace armed, tile OPEN idle, tile running, FSW} |
| pwr_cg | PWR_CTRL value × attempted command {START, SR_START, KAT, MBIST, TILE_RUN, FORMAT} |
| clk_cg | DIV 0..3 × SRC × {applied, deferred-while-ACTIVE}; clkout K; clk ratio bins |
| rst_cg | rst_n assertion phase {idle, frame, inference, clock switch}; strap {0, 1} |
| dbg_cg | sig 0..7 × lane × idx {0, mid, max, out-of-range}; fmt_override; inject kind {a, b, c} |
| trc_cg | SRC 0..3 × TRIG 0..7 × MODE; POST {0, mid, DEPTH−1}; STOP_ON_FULL; wrap |
| selftest_cg | KAT fmt × trigger {reg, strap} × result {pass, fail-injected, refused}; MBIST fault type × lane × half × bias/weight |
| tile_cg | NSLICE {1, 2, 3, >3} × TBATCH {1, mid, TILE_B} × KEEP × HOST_SLICE × fmt; padding {none, partial-last}; illegal command kind; invalidation cause; STALE cause |
| pins_cg | irq/busy/st_pass rise/fall; miso_oe toggles |

Code coverage (xelab `--cc_type sbct`, scope `rondo_chip_top` minus `fused_coproc_pipe`/HardFloat subtrees, via exclusion file `verif/uvm/cov/cc_exclude.txt` with one justification per entry): collected in the nightly tier.

### 3.9 Embedded assertions bound into the DUT (`verif/uvm/sva/`)
* Reuse the existing `rtl/chip/sva/rondo_sva_{rbus,regs,seq,spi,tile,wmem}.v` via `bind` (their `viol` bits drive `uvm_error` in a small monitor).
* New `rondo_sva_chip.sv`, concurrent SVA, xsim only, bound into `rondo_dev`/`rondo_chip_top`:
  - launch rule §10.2 (1–5) with `##`;
  - rbus rules on the external port **and** each arbiter master port (rule 2, robustness);
  - response bound;
  - ZBUF changes only in zcap;
  - no external memory write while ACTIVE;
  - L half CE only in fp32/MBIST;
  - inactive layer clk_en = 0 and core_rst_n = 0 (outside FSW windows);
  - core_rst_n has no glitch (`$stable` between clk_core edges);
  - CLK_CFG applied only at frame_end && !ACTIVE;
  - irq/busy pin equations;
  - miso_oe == cs_active;
  - outputs 0 during reset;
  - **no-progress bound** (ACTIVE implies a progress event within T_PROGRESS);
  - tile: no seed = 2 without a valid tag; partial runs never write TZ/ZBUF; PS writes only in S_SAVE or host-not-ACTIVE; **no KEEP-seeded launch after a layer reset since the last slice (B1)**;
  - clk_core minimum high/low pulse ≥ min(source half periods) − ε (time-based glitch check).

### 3.10 Run-time estimates and tiers
Measure in task V1 (record cycles/s for S and F in CHIP and DEV, xsim). Planning numbers until measured:
- SPI word ≈ 32·R + 10 core cycles (≈ 270 at R = 8).
- S weight load ≈ 1,000 words ≈ 0.27 M cycles; S inference ≈ 300 cycles; S KAT ≈ 9 k cycles per format.
- F frontdoor load ≈ 18,800 words ≈ 5.1 M cycles per format; F KAT ≈ 25 k+ cycles.
- If xsim runs S at ≈ 50–150 k cycles/s: a typical S CHIP test takes 1–6 min; DEV S tests 0.5–2 min; F DEV with backdoor load 3–15 min; F CHIP frontdoor 30–120 min (sign-off tier only).

| tier | content | wall time (32 cores) |
|---|---|---|
| smoke (each change) | C-model cross-check (fast subset), u_bringup, u_reg_access, u_infer_bf16/fp32 (S DEV), FV-REGS/ARB/CLK/RST/PACK prove | ≤ 20 min |
| nightly | all S/S-* tests × 5 seeds (CHIP for SPI/clock/pin tests, DEV for the rest, u_chip_rand both), SPI top incl. max burst, all formal jobs incl. mutation, code coverage, coverage merge | ≈ 2–4 h |
| sign-off | nightly × 20 seeds + F tests (DEV backdoor + u_full_frontdoor) + pre-fix red/green bug check | ≈ 8–12 h |

---

## 4. Directory layout, files, scripts, sign-off

```
verif/
  README.md                      how to run; tiers; result locations
  TOOLCHAIN.md                   V0 probe results (xsim/UVM/DPI/SVA/bind/coverage; sby/abc)
  common/
    filelists/{hardfloat.f, core.f, chip.f, chip_top.f}   generated from sim/run_chip_regs.py lists
    cfg/cfg_{S,S-TB2,S-MB,S-SCAN-PG,S-MIN,S-ACC24,S-KAN,S-CNT,F}.svh  parameter sets (single source)
  model/
    rondo_fpmodel.c, rondo_fpmodel.h, rondo_dpi.svh (import decls), Makefile (gcc .so + xsc lib)
    test_fpmodel_c.py            ctypes cross-check vs sim/fpmodel.py, packing.py
    gen_vectors.py               mode-B vector files
  uvm/
    tb/{tb_chip_top.sv, tb_dev_top.sv, tb_spi_top.sv, rondo_ifs.sv, rondo_backdoor.sv, rondo_hdl_paths.svh, binds.sv}
    agents/spi/{spi_pkg.sv, spi_item.sv, spi_driver.sv, spi_monitor.sv, spi_agent.sv, spi_cfg.sv}
    agents/rbus/{rbus_pkg.sv, ... master driver, reactive slave, monitor}
    agents/pins/{pins_pkg.sv, ...}
    agents/layer/{layer_mon.sv}
    ral/{gen_ral.py, rondo_ral_pkg.sv (generated), rondo_reg_adapters.sv}
    env/{rondo_env_pkg.sv, rondo_env_cfg.sv, rondo_env.sv, rondo_vseqr.sv, rondo_ref_model.sv,
         rondo_reg_sb.sv, rondo_dp_sb.sv, rondo_mem_sb.sv, rondo_cksum_sb.sv, rondo_kat_sb.sv,
         rondo_pin_sb.sv, rondo_watchdog.sv, rondo_cov.sv, rondo_fix_cfg.svh}
    seq/{rondo_seq_pkg.sv, base and feature sequences per §3.7}
    tests/{rondo_test_pkg.sv, one file per test group}
    sva/{rondo_sva_chip.sv, sva_viol_mon.sv}
    cov/cc_exclude.txt
  formal/
    CONTRACTS.md, run_formal.sh, mutate.sh, struct_checks.ys
    jobs/{phy,ctrl,regs,arb,seq,tile,kat,mbist,pack,cksum,clkmux,clkdiv,icg,rstsync,dev,trace}/{<job>.sby, <job>_f.v}
    common/{rondo_layers_abs.v, rbus_resp_f.v, sram_fault_f.v}
  scripts/
    xsim_build.sh <top> <cfg>    xvlog/xelab once per (top, cfg) → snapshot in build/verif/xsim/<top>_<cfg>
    xsim_run.sh <snapshot> <test> <seed> [+args]   own run dir, copies .mem files, log, cov db
    regress.py --tier smoke|nightly|signoff [-j N]   testlist → parallel runs → results table, merge coverage (xcrg), formal summary
    testlist.yaml                test, cfg, top, seeds per tier, timeout
    elab_neg.sh                  expected-fatal elaboration cases (illegal params per §7.1/§10.1/§18.5; B3 if chosen)
    host_frames.py               B4 frame recorder (MockTransport subclass)
    prefix_check.sh              runs the bug tests against build/verif/rtl_prefix (expects FAIL) and current RTL (expects PASS)
    report.py                    verif/reports/{summary.md, coverage.md, formal_summary.md, matrix_status.md}
build/verif/                     all outputs (never in sim/sim_build*)
```

xsim command template (one build per top and config):
```
xvlog --sv -L uvm --relax -i <HF inc> -i rtl -i rtl/chip -d <defines> -f <filelists> <uvm srcs>
xsc verif/model/rondo_fpmodel.c        (→ xsim.dir/work/xsc/dpi.so)
xelab -L uvm --relax --timescale 1ns/1ps -s <snap> --sv_lib dpi tb_<top> [--cc_type sbct --cc_db <name> --cc_dir <dir>] -generic_top "..."
xsim <snap> -R --sv_seed <seed> --testplusarg UVM_TESTNAME=<test> --testplusarg UVM_VERBOSITY=UVM_LOW --cov_db_dir <dir> --cov_db_name <test>_<seed>
xcrg -cov_db_dir <dir> -merge_dir <m> -report_format text,html -report_dir verif/reports/cov
```

**Sign-off criteria**
1. Every row of the §1.3 matrix has status PASS in `matrix_status.md` (generated from test results plus formal summary).
2. UVM: all tests in the sign-off testlist pass on all seeds. Zero UVM_ERROR/UVM_FATAL, zero SVA failures, zero `viol` bits, zero "unexplained ERR bit" or "hang" reports. Any waiver is written in `verif/WAIVERS.md` with reason and approver (author).
3. Functional coverage: 100% of defined bins in §3.8 hit (merged), with ≤ 2% bins waived with justification.
4. Code coverage on `rtl/chip` (minus documented exclusions such as FPGA `ifdef`s and the scan stand-in): statement ≥ 98%, branch ≥ 95%, condition ≥ 90%, toggle ≥ 90%. FSM states and transitions of seq, tile, kat, mbist, spi_ctrl, arb are all hit.
5. Formal: statuses meet the §2.5 table; all covers reached in the proof configuration; all canaries FAIL; mutation kill ≥ 80% on spi_ctrl/regs/seq/tile/arb with survivors explained.
6. B1–B7 (+ robustness) tests: FAIL on `build/verif/rtl_prefix` (except B5/B6/B7, which are checked by CAPS/structural/cocotb) and PASS on fixed RTL.
7. C-model cross-check 100% bit-exact; mode-A and mode-B oracles agree on all F directed vectors.
8. Existing regressions still green: `scripts/chip_regress_new.py` under Icarus and Verilator, `scripts/chip_regress_old.py`, host pytest, `scripts/chip_formal.sh` (legacy jobs until superseded).

---

## 5. Ordered implementation tasks (for the Sonnet agent)

Rules: do not edit `rtl/`, `docs/CHIP_INTERFACE_SPEC.md`, `host/`, or existing `sim/` files, with two exceptions that need explicit approval: `ifdef RONDO_FORMAL` blocks (§2.1) and the cocotb additions for B4/B7 (new files only). Every task records commands and results in `verif/IMPL_LOG.md`. A task starts only after the previous one's acceptance holds.

**V0.1 Toolchain probes.** Tiny SV/UVM programs in `build/verif/probe/` for each §3.1 row; SBY probes: `abc pdr` via `ABC=/usr/bin/abc` on a toy counter proof, `multiclock on` with a latch, `mutate -list`. Accept: `verif/TOOLCHAIN.md` lists each feature as OK, or FAIL with the chosen fallback.

**V0.2 Pre-fix snapshot.** Copy the current `rtl/`, `host/`, `sim/fpmodel.py` to `build/verif/rtl_prefix/` **before** the fix agent's changes land (if they have already landed, reconstruct from `*.pre_*` backups or ask the coordinator). Accept: tree plus a hash list.

**V0.3 Fix alignment.** Read `docs/CHIP_FIX_PLAN.md`; fill `rondo_fix_cfg.svh` and the §1.4 table in `verif/README.md`. Accept: every B/F/robustness row has a concrete expected behaviour.

**V1 xsim RTL bring-up.** File lists, cfg files, `xsim_build.sh`; plain SV smoke tb (no UVM) for DEV S: one rbus write/read, one bf16 inference. Measure cycles/s for S and F, CHIP and DEV. Accept: S, F and every S-* variant elaborate (S-ACC24 per V0.3); smoke passes; speed recorded; estimates in §3.10 updated.

**V2 C model.** `rondo_fpmodel.c` plus cross-check. Accept: `test_fpmodel_c.py` 100% bit-exact on the §3.5 counts, both formats, ACCSIG 8/24, NR 1/2, TBITS 6/8/12; xsc build plus a DPI call from SV works.

**V3 RAL generator.** Accept: generated package compiles; reset values equal `regmap.py`; build-dependent resets come from cfg.

**V4 SPI agent.** Accept: on the SPI top, LOOPBACK, STATUS, WRITE/READ, CRC; the monitor decodes exactly what the driver sent (self-check); R sweep 6..33 with random phase; R < 6 detection unit test.

**V5 rbus and pins agents, layer monitor, probes, backdoor.** Accept: DEV top runs a read/write walk; backdoor peek equals a frontdoor read for weights (both halves); layer monitor sees start/done/zcap.

**V6 Env, ref model, scoreboards, watchdog, SVA binds.** Accept: u_bringup and u_reg_access pass on S CHIP and DEV; a deliberately wrong expectation produces UVM_ERROR (negative check); existing `rtl/chip/sva` checkers bound and silent.

**V7 Register tests.** u_reg_reset (all variants), u_reg_access, u_reg_shadow, u_ctrl_combos, u_status_fields, u_heartbeat, u_err_*. Accept: pass on 5 seeds; reg_cg/err_cg/ctrl_cg ≥ 95%.

**V8 Load path.** u_load_crc, u_load_readback, u_err_partial. Accept: pass; load_cg 100%.

**V9 Inference and lane mask.** u_infer_bf16/fp32/rand, u_naninf, u_lane_mask on S (CHIP and DEV) and F DEV (backdoor load). Accept: bit-exact; dp_cg ≥ 95%.

**V10 Self-run and counters.** u_selfrun_*, u_counters, u_wdog. Accept: pass; seq_cg 100%.

**V11 Format and soft reset.** u_fmt_switch, u_fmt_while_active, u_soft_reset, u_srst_during_kat. Accept: pass; fmt_cg/srst_cg 100%.

**V12 Self-test.** u_kat_reg, u_kat_strap, u_kat_fault, u_mbist_faults (S-MB, FAULT_INJECT), u_pwr_ctrl. Accept: kat_sb matches KAT_GOT and KAT_SIG for S and F; faults detected; selftest_cg 100%.

**V13 Debug and trace.** u_dbg_taps, u_dbg_inject, u_fault_localize, u_trace_rand. Accept: pass; dbg_cg/trc_cg 100%.

**V14 Clocks and reset.** u_clk_div, u_clk_src, u_clk_dead_alt, u_clkout, u_reset_async, u_scan_mode, SPI tests on the SPI top (u_spi_*). Accept: pass; clk_cg/rst_cg/spi_cg 100%; glitch SVA silent.

**V15 Tiling.** u_tile_regs/basic/pad/keep/hostswap/illegal/inval/rand on S, S-TB2, S-ACC24, F DEV. Accept: bit-exact vs untiled C model; tile_cg 100%.

**V16 Bug scenarios.** u_b1..u_b6 tests, `host_frames.py` + u_b4_host_replay, `elab_neg.sh`; new cocotb files `verif/cocotb/test_b7_core.py` + runner (L_FIN disabled lane + start-in-done → qNaN; uses the existing `sim/tb_core_c6.v`/c1 benches unchanged) and `verif/cocotb/test_b4_transport.py` (CocotbTransport subclass enforcing R, host `set_clock`). Accept: `prefix_check.sh` shows red-on-prefix / green-on-fixed for B1, B2, B3, B4, B7 and the robustness tests; B5/B6 pass on fixed RTL.

**V17 Random and coverage closure.** u_chip_rand, coverage merge, code coverage with exclusions, closure loop (add constraints or directed tests for holes). Accept: §4 criteria 3 and 4 met.

**F1 Formal infrastructure.** `run_formal.sh` (ABC env, tasks prove/bmc/cover/canary, parallel, summary), `CONTRACTS.md`, `mutate.sh`, `struct_checks.ys`. Accept: runs the legacy regs job in the new format; canary FAIL detected; summary written.

**F2 FV-CTRL** (F1 fix; highest formal priority). Accept: PROVEN (PDR, or k-induction with RONDO_FORMAL invariants); all §2.2 covers reached **in the prove configuration**; canary FAIL; mutation ≥ 80%.

**F3 FV-PHY** (incl. loopback/STATUS modes). Accept: §2.5.

**F4 FV-REGS extension** incl. B1/B2 fix properties and caps per variant. Accept: PROVEN.

**F5 FV-ARB** incl. srst robustness. Accept: PROVEN.

**F6 FV-SEQ** with prog1–3 and kat-while-held. Accept: PROVEN or §2.5 minimum. Must FAIL on the pre-fix RTL (demonstrates it would have caught B2).

**F7 FV-TILE** with t3 (B1). Accept: as F6 (FAIL on pre-fix for t3 when PWR events are modelled).

**F8 FV-KAT, FV-MB.** Accept: BMC to completion passes; fault covers reached; prog holds.

**F9 FV-PACK/CKS, FV-CLK/RST.** Accept: PROVEN.

**F10 FV-DEV upgrade (TILE = 1), FV-STRUCT, optional FV-TRC.** Accept: §2.5.

**R1 Regression scripts and reports.** `regress.py` tiers, `testlist.yaml`, `report.py`, matrix status generation. Accept: smoke ≤ 20 min; nightly completes unattended; reports generated.

**R2 Sign-off run.** Accept: all §4 criteria; `verif/reports/SIGNOFF.md` written with numbers, waivers and the pre-fix red/green table.

Suggested parallelism: F1–F10 are independent of V-tasks after F1; V2 and V3 are independent of V1.

---

## 6. Risks and mitigations

| risk | mitigation |
|---|---|
| xsim cannot parse some RTL construct, or UVM/DPI/bind feature missing | V0/V1 probes first; documented fallbacks (§3.1); report RTL issues to the coordinator instead of editing RTL |
| xsim speed, especially F geometry | DEV top plus backdoor loads for F; one F frontdoor test only in sign-off; parallel seeds; measure in V1 and re-budget |
| xsim constraint solver limits/performance | scalar constraints, procedural array fill, weighted `randcase` in virtual sequences |
| `uvm_hdl` backdoor unavailable | SV-module backdoor (§3.4) |
| C model drifts from fpmodel / RTL | 10^6-sample cross-check in every smoke run; mode-B vectors as a second oracle; NaN/Inf rules validated against RTL before strict checking |
| PDR / k-induction does not converge (24-bit addresses, 17-bit counters) | reduce widths through harness parameters where the property is width-uniform (justify), add RONDO_FORMAL invariants, keep BMC backstops with completeness arguments |
| RONDO_FORMAL blocks require touching RTL files | needs approval; fallback is observation ports under the same ifdef (precedent `rondo_tile`) or BMC-only with deeper bounds |
| formal multiclock/latch modelling in Yosys | FV-CLK proven on the behavioural models only; library cells are verified by STA/cell substitution (out of scope), as the spec states |
| fix plan changes interfaces (new error codes, new ports, removed parameter combos) | §1.4 single config file; V0.3 alignment gate; formal properties parameterized by `FIX_*` defines |
| KAT signatures only exist for S and F | kat_sb computes the expected signature for any build; KAT_SIG compared only where valid |
| ref-model complexity (≈ host model size) | observe-then-predict for timing; port semantics from `host/rondo_host/model.py` section by section with unit tests in DEV mode |
| coverage DB size and xcrg merge time | functional coverage always; code coverage nightly only |
| pre-fix snapshot unavailable | reconstruct from `*.pre_*` backups and the verify report's descriptions; otherwise mark "red-on-prefix" as not demonstrable and rely on formal FAIL evidence (F6/F7) |

### Critical files for implementation
- /home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI-main/docs/CHIP_INTERFACE_SPEC.md
- /home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI-main/docs/CHIP_VERIFY_REPORT.md (and docs/CHIP_FIX_PLAN.md once written)
- /home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI-main/sim/fpmodel.py (and sim/chip_common.py: model_layer, packing)
- /home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI-main/host/rondo_host/regmap.py, packing.py, model.py
- /home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI-main/rtl/chip/rondo_dev.v, rondo_spi_ctrl.v, rondo_seq.v, rondo_tile.v, rondo_kat.v
- /home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI-main/formal/spi_ctrl_f.v, seq_f.v (legacy harnesses to supersede)
