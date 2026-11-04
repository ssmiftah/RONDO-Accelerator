# RONDO chip wrapper: independent verification report

Verifier: separate agent, 2026-11-03. Scope: docs/CHIP_INTERFACE_SPEC.md v2.1 (v2.0 + §18 tiling + "Author
decisions") against rtl/core (C1–C8), rtl/chip, sim, formal, scripts, host, as claimed done in docs/CHIP_IMPL_LOG.md.
Nothing in RTL, spec, tests or host code was modified. Every run below was done in isolated copies
(build/verify/tree, tree_old, tree_ver) so the implementer's sim_build state was not touched. Throwaway tests are in
build/verify/ (eq/, fcov/, tree/sim/test_verify.py, run_verify.py).

## 1. Verdict

**Not ready for co-author verification yet, but close.** The core changes are clean (default parameters are
cycle- and bit-identical to the as-built core in my own equivalence runs), the regressions the log claims re-run green,
and I found no CDC, reset or clock-structure bug that would kill silicon. I did find two confirmed functional bugs
reachable through the normal register interface (B1, B2), one parameter-combination bug that silently breaks tiling
(B3), one host bug that will produce out-of-spec SPI frames on real hardware (B4), and a formal setup whose main SPI
"proof" is vacuous for the write path (F1). All are small fixes. After B1–B4 are fixed (and F1 is either strengthened
or explicitly accepted), I would consider it ready for co-author verification.

## 2. Confirmed bugs, ranked by severity

### B1 (medium-high): KEEP-mode partial sums silently lost across a PWR_CTRL.CORE_HOLD toggle
* Where: rtl/chip/rondo_regs.v:374-377 (PWR_CTRL accepted while a tile sequence is OPEN; only ACTIVE blocks it);
  rtl/chip/rondo_tile.v:157 (the KEEP valid flag is cleared only by `other_start`, srst or `inval_ext`);
  rtl/chip/rondo_seq.v:127-128 / :161 (CORE_HOLD drops `want`, so `core_rst_n` goes low and the core's `acc` registers
  are asynchronously reset, rtl/core/affine_bank_pipe.v:250).
* Scenario: TILE_CFG with KEEP=1, slice 0 runs, the host writes PWR_CTRL=1 then 0 (for example a leakage measurement
  per §9.9 between slices, or `Rondo.power_hold()`), then runs slices 1..S−1. The keep-seeded slice starts from
  acc = 0 instead of the slice-0 partial sum. The run completes with FINAL_DONE, no TILE_STALE, no error: wrong z.
* Evidence: build/verify/tree/sim/test_verify.py::keep_corehold (Verilator, fp32): `KEEP+CORE_HOLD: final=1 stale=0
  errors=set() tz==untiled: False`.
* Spec gap: §18.6 does not list PWR_CTRL among the writes rejected while OPEN, and the "invalidation" list does not
  include CORE_HOLD. Fix: reject PWR_CTRL writes with TILE_SEQ while OPEN (simplest, consistent with FORMAT/LANE_EN), or
  clear `valid[0]`/invalidate when the active layer's `core_rst_n` falls during an open KEEP sequence. Update §18.6.
  (Non-KEEP mode is not affected: the PS store is SRAM and survives the core reset.)

### B2 (medium): KAT_START while PWR_CTRL.CORE_CLK_OFF (or CORE_HOLD) = 1 hangs ACTIVE until SOFT_RST
* Where: rtl/chip/rondo_kat.v:168-169 (E_RUN pulses `seq_run` when `seq_idle`, then waits for `seq_done` forever);
  rtl/chip/rondo_seq.v:264-265 (the sequencer refuses the launch with START_BUSY because `cur_ready_q && clk_ok` is
  false, and never signals the KAT); rondo_regs.v:322-343 (KAT_START is not refused when the layer is held/clock-off).
* Scenario: host leaves PWR_CTRL=0b10 or 0b11 after §9.9 and calls `kat()`. The KAT loads ~25k words, then STATUS.ACTIVE
  and the `busy` pin stay 1 forever; the host's `_wait_idle(60 s)` times out. Recoverable only by SOFT_RST.
* Evidence: test_verify.py::kat_with_clk_off: after 60k cycles `ACTIVE=1 ST_STATUS=0x21 errors={'START_BUSY'}`;
  SOFT_RST recovers.
* Why formal missed it: formal/seq_f.v:13 assumes no `kat_run` while `seq_active`, and BMC cannot check liveness.
* Fix: refuse KAT_START (and MBIST_START) with START_BUSY/BUSY_WR when CORE_HOLD or CORE_CLK_OFF is set, or let the
  sequencer return a fail pulse to the KAT engine (as it already does for tiles, `tile_fail_p`) and have the KAT end
  with KAT_FAIL.

### B3 (medium, parameter variant): TILE=1 with ACCSIG_BF16=24 truncates bf16 partial sums
* Where: rtl/chip/rondo_layers.v:127-128 connect the bf16 instance's `ps_q`/`ps_wdata` (N_LANES·NPAR·(8+ACCSIG) bits)
  to 16-bit-per-element buses; rtl/chip/rondo_ps.v enables the L half only in fp32 (`en_l = ... & fmt`, :73-75);
  rondo_regs.v:14 hard-codes AW_BF16 = 16 in TILE_GEOM and rondo_dev does not pass it.
* Scenario: the A3 "wide accumulator" build (ACCSIG_BF16=24, an advertised parameter) with the default TILE=1: bf16
  tiled runs save/restore 16 of 32 accumulator bits and mis-slice the rest; results are wrong and TILE_GEOM reports
  AW_BF16=16.
* Evidence: `verilator --lint-only -Wall -GACCSIG_BF16=24` on rondo_chip_top gives two WIDTHEXPAND warnings at
  rondo_layers.v:127/128 (chip_lint.sh does not run this variant).
* Fix: size the bf16 PS path by AW_BF16 = 8+ACCSIG_BF16 (use the L half when AW_BF16 > 16), pass AW_BF16 to
  rondo_regs, or add an elaboration `$fatal` for TILE && ACCSIG_BF16 != 8; add the variant to chip_lint.sh.

### B4 (medium, host): `Rondo.set_clock()` sends a frame at the old SCLK after the core clock changed
* Where: host/rondo_host/device.py:111-116. CLK_CFG is applied when the frame carrying it ends (rondo_regs.v:280-282);
  the method then reads CHIP_ID ("a further frame") **before** `_set_sclk()` lowers SCLK.
* Scenario: f_clk 50 MHz, SCLK 5 MHz (R=10). `set_clock(div=1)` → the CHIP_ID read runs at R=5 (below the verified
  R=6 corner); `set_clock(div=3)` (÷8, also reachable via `set_format` with `fp32_div`) → R≈1.25: the PHY drops SCLK
  edges, bytes are misframed, and an arbitrary opcode/address can be decoded (including a WRITE). Spec §3.3 requires
  f_SCLK ≤ f_core_new/8 after the change.
* Not caught because CocotbTransport.set_speed ignores the rate (host/rondo_host/cocotb_transport.py:34-36) and the mock
  does not model R. Fix: call `_set_sclk()` before any further frame (the extra read is unnecessary: the write is
  applied at the end of its own frame), or when slowing down, lower SCLK first.

### B5 (low): CAPS LAYER field encodes KAN as 2, and HAS_BIAS is 1 in KAN builds
* rtl/chip/rondo_regs.v:88-90: bit 3 = (LAYER != 0), bit 2 = 0, so CAPS[3:2] = 2 for LAYER=1; spec §6.2 says
  [3:2] = 1 for KAN. host/rondo_host/regmap.py:69 names the bits "LAYER0"/"LAYER1", so host and RTL agree with each
  other but not with the spec. HAS_BIAS (bit 4) is hard-wired 1 although a KAN build has no bias region (§13.24).
  KAN is not on the first chip. Fix the encoding (or the spec) and make HAS_BIAS = (LAYER == 0).

### B6 (low): `core_rst_n` of each layer is a combinational decode, not a flop (spec §3.4)
* rtl/chip/rondo_seq.v:161 `assign core_rst_n[f] = test_mode ? rst_n : (ls[f] == L_RUN)`. With the present encoding
  (L_CLK=01 → L_RUN=10 → L_RST=11) the decode cannot glitch high, so this is not a functional bug today, but it is an
  asynchronous reset net driven by a 2-bit compare that synthesis may restructure, and the spec requires a flop output.
  The SYNCASYNCNET waiver in sim/chip_waivers.vlt hides it. Fix: register `core_rst_n` (one flop per layer, async-reset
  by sys_rst_n) or use a one-hot RUN state bit.

### B7 (low): C1 + C6 interaction in the core leaves stale outputs on a disabled lane
* rtl/core/fused_coproc_pipe.v:284-286: a lane in L_FIN that is disabled when a start arrives in the done cycle goes to
  L_IDLE without writing qNaN to `zl` (the qNaN write is only in the L_IDLE arm, :253-259), so its ladders keep the
  previous inference's values instead of qNaN (§2.7). Unreachable from the wrapper (launch rule keeps a t+2 gap), so
  chip behavior is correct; it only matters for other users of the core. Fix: also write qNaN in that branch.

### Robustness notes (not bugs under the present SPI adapter)
* rtl/chip/rondo_rbus_arb.v is not cleared by soft reset and its A_REQ phase does not re-check the master's `valid`;
  rondo_dev drops an in-flight response on srst (rondo_dev.v:563). With the SPI adapter (rsp_ready ≡ 1) the CTRL
  write that triggers SOFT_RST completes in the first srst cycle, and the KAT drops its request in that same cycle, so
  there is exactly one cycle of margin; a future master with rsp_ready=0 could deadlock the arbiter in A_RSP, and a KAT
  request granted during srst would execute after it as a stale internal write. Recommend: clear the arbiter on srst and
  let rondo_kat keep `valid` until the handshake (rbus rule 2).
* rtl/chip/rondo_tile.v:173-176: in HOST_SLICE (O3) mode every slice-0 TILE_RUN re-opens the sequence and restarts
  TILE_SEQ_CRC, so with several sub-batches the CRC covers only the last slice-0 run onwards. Host and model agree, but
  §18.5 ("every TILE_RUN since the sequence opened") should state it.
* host/rondo_host/device.py:472-474,478: `tz(len(idx))` is called inside the per-input loop, so TZ is re-read TBATCH
  times per sub-batch (8× redundant SPI reads at TILE_B=8). Performance only.
* No elaboration checks exist in rtl/chip apart from rondo_trace (only `$fatal` found): spec §7.1 (NPAR power of two,
  LNW+WAW+FW ≤ 23, LNW+BAW+FW ≤ 16, clog2(NXBUF)+XW ≤ 16, 2·TRACE_DEPTH ≤ 65536), §10.1 (NGROUP·PDIM > WIDTH+8
  else CKSUM_PAR=1) and §18.5 (clog2(TILE_B)+LNW+BAW+FW ≤ 17) are not enforced. B3 would have been caught by such checks.
* Soft reset does not clear the 64-bit read shadows (rondo_regs.v:401-403) or invalidate the wpack read cache; §9.6
  lists both among the reset items. Harmless (the cache stays coherent with memory), spec wording or RTL to align.
* Dead declarations (wp_* nets, dummy4, ps_b_w, ev_trc_done_r, mem_rd_val, xcur, accept_ok, pb, ci, any_start_bit,
  trig_stored, srst_d in rondo_dev/regs/seq/spi_ctrl/trace/tile; miso_r/miso_oe_r in rondo_chip_top) are hidden by the
  blanket `UNUSEDSIGNAL -file "*rtl/chip/*.v"` waiver. Nothing functional was hidden (I re-linted without it), but the
  waiver is broader than §15.4's "each waiver scoped and justified"; recommend deleting the dead code and narrowing it.

## 3. Core changes C1–C8

Diffed every edited core file against its .pre_chip (and .pre_c8) backup.

| change | file(s) | finding |
|---|---|---|
| C1 | fused_coproc_pipe.v:284-286, kan_layer_pipe.v:151-154 | as specified; KAN identical to the spec text. See B7 for the LANE_MASK corner. |
| C2 | recip_nr_pipe.v:58-66, ladder_engine_inter, fused_coproc_pipe | `small_1` registered beside `v_1` exactly as §2.3. |
| C3 | affine_bank_pipe.v:134-199 | memories in a generate branch; `mem_act` = state≠IDLE ∨ in_valid (S_SAVE excluded, unreachable at TILE=0). |
| C4 | fused_coproc_pipe.v:293-374, affine/ladder taps | tap table and live flag layout match §2.5; DBG=0 gives constant 0 outputs. |
| C6 | fused_coproc_pipe.v:132-146, :381 | lane_en_q latched on accepted start, completion `&(lane_fin|~msk)`, qNaN on disabled lanes. |
| C7 | recip_nr_pipe.v:105-174 | NR loop generated; for NR_ITERS=1 the delay lines are the original ones renamed; `-b` delayed only for further iterations. recip_seed_e8s24_t8.mem regenerated by me with gen_recip_table.py --tbits 8: byte-identical. |
| C8 | affine_bank_pipe.v:220-303, fused_coproc_pipe.v:122-130, :265-270, :384 | seed modes, S_SAVE after drain, partial slice skips the ladder engine, done_final; matches §18.2. |

Independent default-parameter equivalence (my own bench, build/verify/eq/tb_eq.v): the .pre_chip versions renamed
`*_old` and the current core side by side, same random weights/inputs (including ±0 and subnormals), random start
gaps and extra start pulses while busy, compared `busy`, `done` every cycle and `z` at every done:
bf16 (SIG 8, ACCSIG 8, TBITS 6) WIDTH 16/PDIM 8: 60 inferences, 0 mismatches; fp32 (TBITS 12, NR 1): 60, 0;
bf16 WIDTH 32/PDIM 5 (NBATCHES = 2, multi-batch path): 30, 0. Defaults are bit- and cycle-identical.

## 4. Spec conformance spot-checks

Register map (§6.1): addresses, access types and reset values in rondo_regs.v and host/rondo_host/regmap.py match the
table (CHIP_ID, VERSION 0x00020100, IRQ_EN 0x7F, ERR_MASK 0xFFFFFDFF, SR_N 1, LANE_EN all ones, STATUS8 reset 0x02,
WSTALE set at reset). CTRL priority, W1C (IRQ bit 2 read-only mirror), LO→HI shadows, ERR bit positions (rondo_dev.v
err_in), STATUS and STATUS8 layouts, CLK_CFG read-back layout, CAPS (except B5), GEOM0–3, TILE_* registers: as
specified. Memory map (§7.1, §18.5): XBUF/ZBUF/TRACE/BIAS/WEIGHT/TX/TZ/PS decode and hole→ADDR as specified.
SPI (§5): framing, CRC-8 (poly 0x07), HCRC/DCRC handling, N+1 reads, 0xDEADBEEF overrun, MISO tri-state, R-margin
(≤ 3 cycles edge→MISO) as specified. Clock mux/divider/ICG/reset synchronizer: standard structures, test-mode bypasses
as §3.3/§11.7. Sequencer launch rule (t+2 spacing, no launch into reset/settling layer) as §10.2. KAT LFSR/element
format, MBIST March C− element order and status fields, trace config fields: as specified.

Deviations found by reading (beyond the implementer's list): B5; B6; missing elaboration checks; soft reset vs shadows;
KAT_START with MBIST=1 also runs MBIST first (rondo_kat.v:209), whereas §9.8 runs MBIST only in the strap sequence;
trace SRC 1 data has the "SPI frame start" bit tied 0 (rondo_dev.v:446); FPGA top does not instantiate rondo_clkdiv
(CLK_CFG.DIV has no effect on the Genesys 2 and DIV_APPLIED reads 0), whereas §13.25 maps it to a BUFGCE; MBIST covers
neither the PS store nor the TX/TZ SRAMs (the log mentions PS only).

## 5. What I re-ran (results)

All in isolated copies under build/verify/ (logs: old_icarus.log, old_verilator.log, new_icarus.log,
new_verilator.log, slow_verilator.log, lint.log, formal.log, synth_small.log, verify_tests.log, eq/*.log).

| what | result |
|---|---|
| scripts/chip_regress_old.py icarus (original runners + run_core_c1..c8 + 3 explicit WL_* jobs) | **REGRESSION OK**: 41/53 runners pass; the 12 failures are exactly the known WL_*-parameterized runners (0 tests); explicit run_fused_pipe / run_fused_bf16 / run_workload_inter PASS |
| scripts/chip_regress_old.py verilator | 36/53; 17 failures = 12 known WL_* + run_grad_a_inter, run_power_top, run_train_ladder_inter (known Verilator baseline failures) + **run_train_coproc, run_train_ladder (rc=250 after the first passing test, flagged UNEXPECTED)**. Both use no modified RTL (fp_fma, kscan, recip_wrap, grad_a_unit, train_*) and both PASS when re-run alone (4/4 and 3/3 sub-runs). So they are flaky crashes of Verilator builds sharing sim/sim_build, the same class of problem the log describes, not a chip regression. The regression script is therefore not reliably green under Verilator. Explicit WL_* jobs PASS. |
| run_core_c1..c8 (both simulators) | all PASS (c1 4, c2 2, c3 2, c4 3, c5 3, c6 2, c7 4, c8 6 tests) |
| my default-parameter equivalence bench (eq/) | 150 inferences, 0 mismatches (§3) |
| scripts/chip_regress_new.py icarus | 17/18 PASS (units, spi, regs, pack, seq, fmt, top, clk, dbg, trace, kat, mbist, scanmode, sva, kan, host, tile). `suite` FAILED in my clean copy: run_chip_suite.py:12 calls gen_vectors.py through `sys.executable`, which here resolved to a Python without numpy, and the vectors file it needs is not generated by any other step (it exists in the implementer's tree only because it was generated earlier). After generating the vectors with the venv Python, run_chip_suite PASS (1/1). Minor robustness defect of the runner (use the venv path or `-m`). |
| scripts/chip_regress_new.py verilator | **18/18 PASS, CHIP REGRESSION OK** (suite with the pre-generated vectors) |
| Verilator-only slow runners | run_chip_full, run_chip_kat_full (2/2), run_chip_cofrgenet (T-CFG), run_chip_gls: all PASS |
| scripts/chip_lint.sh | 6/6 variants clean. Extra variant `-GACCSIG_BF16=24`: 2 warnings (B3). Without the blanket UNUSEDSIGNAL waiver: dead code only. |
| scripts/chip_formal.sh | 12/12 tasks PASS, covers reached (see §6 for what that means) |
| scripts/chip_synth.sh small | rc=0, `check -assert` passes, 632,622 cells, 3 `$_DLATCH_N_` (the three ICGs), matching the log |
| host pytest (.venv-rtl) | 34/34 PASS |
| my scenario tests (test_verify.py, Verilator) | 2/2 FAIL as intended, demonstrating B1 and B2 |

Not run: Vivado synthesis/place-and-route/bitstream, any hardware (Pi 5, Genesys 2), timing GLS (needs a PDK),
sim/run_all.py in its literal full form (covered by the two regress scripts plus the individual runners), the FULL-geometry
WL_* workload runners, the spec's 65,536-word SPI burst spot test (not checked whether T-SPI includes it).

## 6. Formal: judgment of the .sby files

scripts/chip_formal.sh re-run: all 12 tasks PASS, all covers reached (regs prove+cover, spi_ctrl "prove"+cover,
spi_phy bmc+cover, seq bmc+cover, dev_bus bmc+cover, tile bmc+cover). Judgment of what that proves:

| job | spec §15.3 | as built | judgment |
|---|---|---|---|
| regs | prove | k-induction depth 12 | genuine unbounded proof. Good. |
| spi_ctrl | prove (k-induction, depth 48) | task named "prove" but `mode bmc`, depth 64; cover task uses a different harness (`-DGAPN=6`) at depth 110 | **F1, material.** With the 8-cycle byte spacing the BMC reaches only ~7 bytes. My cover run of the prove configuration (build/verify/fcov/c.sby, GAPN 8, depth 64): no WRITE request, no second READ word, no CRC error and no frame end after byte 7 is reachable. So the write-path assertions (word complete and CRC-clean, ≤ N+1, address increment, DCRC reject) are vacuous in the "prove" job. The cover task does not rescue them: I added a deliberately false assertion (`!(issue && we && reqs == 1)`) to the GAPN=6 harness and sby cover mode reported PASS while reaching exactly that state, so assertions are not checked in cover mode. The properties are covered only by simulation (T-SPI, 6 ratios × 200 frames, which passes). chip_formal.sh prints "spi_ctrl/prove: PASS", which overstates it. |
| spi_phy | bmc 200 + cover | as spec | fine. The harness assumes the opcode is never 0x0E/0x05 (spi_phy_f.v:49), so loopback/STATUS paths are simulation-only; and the hold-byte timing is an assumption about the controller (stated). Acceptable. |
| seq | prove | BMC 70, abstract layer (6–10-cycle latency), sr_count ≤ 3, sr_n ≤ 4, tile ports tied off | weakened (bounded); assumptions are those the regs block enforces, plausible. Cannot check liveness, which is how B2 slipped through (seq_f.v:13 assumes away kat_run while active). Tile launch path not covered here. |
| dev_bus | prove/bmc depth 64 | BMC 60, layers abstracted, TILE=0 build | bounded, slightly shallower than spec; tile decode/x_live path not formally covered. Acceptable as BMC. |
| tile | (spec: add to seq.sby) | separate BMC 60, NSLICE ≤ 3, TBATCH ≤ 2, cfg constant, one event per cycle | reasonable bounded check of the tile FSM in isolation. PS-valid-cleared-by-reset moved to simulation (yosys hierarchy issue; documented). Note PWR_CTRL/core reset is not an input of the harness, so B1 is outside its model. |

Overall: one real proof (regs); everything else is bounded model checking with sensible environment assumptions; and
the spi_ctrl job is effectively vacuous for writes. This does not make the design wrong (simulation covers those
paths), but the log's "formal 6 jobs PASS" should be read as "1 proof + 5 BMC, spi_ctrl write path unchecked".
Recommendation: raise spi_ctrl depth (≈ 110 at GAPN 8 reaches the second word) or abstract byte spacing soundly,
rename the task to bmc, and either attempt induction with helper invariants or say BMC in the spec.

## 7. Implementer's deviations: judgment

A = acceptable as is; S = acceptable, spec should be updated; F = needs a fix.

| implementer deviation (CHIP_IMPL_LOG.md) | judgment |
|---|---|
| sim/cocotb_common.py edited (waiver file in the control list, `defines`, HF include for rtl/chip) | A (minimal, additive; §2.1 literal text violated only in letter) |
| LOOPBACK/STATUS byte paths in rondo_spi_phy, not rondo_spi_ctrl | S (it is the only way to meet the byte timing) |
| STATUS frame: MISO byte 0 = 0x00, STATUS8 from byte 1 | S (unavoidable; §5.2 says "each byte") |
| rbus response latency up to ~8 cycles for uncached weight reads (spec ≤ 4); SVA bound relaxed to 10 | S (24-cycle external bound holds; update §8.3) |
| DBG_DATA needs an extra access after DBG_SEL (4-cycle latch) | A (host does it) |
| no trace disarm command | A (spec has none) |
| KAT ≈ 9k cycles/format at SMALL vs. spec estimate | A |
| KAT LFSR "advance then use" convention | S (record in §11.5) |
| gen_kat_sig.py f_ref cross-check excludes ill-conditioned ladders (raw criterion gave 2.9e-3 > 1e-3) | S (reasonable for random data, but it is a relaxed acceptance criterion; the author should approve it explicitly) |
| MBIST tests lanes serially, not in parallel | A (time only, ≈ 8× longer) |
| MBIST does not cover the PS store (also: not TX/TZ — not mentioned) | S now, F before tapeout if those SRAMs become macros: 164 kbit of untested SRAM; extend rondo_mbist or rely on macro BIST and say so in §11.6 |
| read-back works in KAN builds though CAPS.READBACK=0 | A |
| broad UNUSEDSIGNAL waivers (rtl/chip/*.v, several core files) | F (minor): hides only dead code today, but narrow it |
| SVA mutants are stimulus mutants only | A |
| formal BMC instead of k-induction (spi_ctrl, seq, dev_bus, tile); spi_ctrl cover with GAPN=6 | F for spi_ctrl (F1, vacuous write path); S for the others |
| FPGA: RONDO_FPGA ICG variants, observation outputs on rondo_dev, FORMATS=3 does not fit | A (consistent with Q8); also rondo_clkdiv absent on FPGA (S) |
| tiling: PS store as rondo_ps (not in rondo_wmem), tile FSM in rondo_tile, region offsets addr[15:0] | S |
| host PS write tagged SLICE−1 at write time (host must set TILE_SLICE first) | S (matches spec text; document ordering) |
| TILE_SLICE cleared when a sequence closes | S |
| TILE_RUN while the layer is not ready → TILE_STALE | S (TILE_SEQ might be the better code; spec silent) |
| TILE_SEQ_CRC = zlib CRC-32 over LE LOAD_CRC words; restarts at each slice-0 run in HOST_SLICE mode | S (document the restart) |
| T-SUITE tiled vectors computed by fpmodel instead of a bare-core RTL run | A (T-TILE/T-CFG prove fpmodel == RTL) |
| T-C4: L_FIN state not observed on live flags | A |
| Verilator T-KAT second fault uses a stuck bias word | A |
| scripts/chip_regress_old.py deletes loose files in sim/sim_build | A (needed for the pre-existing Verilator crash; note it modifies the work tree) |
| 12 run_all runners "fail" at baseline (need WL_*), 3 more under Verilator | A, but note the consequence: the full-geometry workload runners never run in the regression; only 3 small explicit jobs (2–4 samples, WIDTH 16) exercise the fused layer at default parameters. My equivalence bench (§3) closes that gap for default parameters. |

## 8. Recommended fixes (in order)

1. B1: reject PWR_CTRL writes while a tile sequence is OPEN (TILE_SEQ), update §18.6; add the scenario to T-TILE.
2. B2: refuse KAT_START/MBIST_START while CORE_HOLD/CORE_CLK_OFF, or return a fail pulse from rondo_seq to rondo_kat;
   add a T-KAT case.
3. B4: in `Rondo.set_clock`, set the new SCLK before any further frame; make CocotbTransport model the SCLK ratio (or
   assert R ≥ 8 in the transport) so the host test can catch it.
4. B3 + elaboration checks: size the bf16 PS path by AW_BF16 (or `$fatal` on TILE with ACCSIG_BF16≠8); add the §7.1,
   §10.1, §18.5 checks; add `-GACCSIG_BF16=24` and `-GTILE_B=0` variants to chip_lint.sh.
5. F1: make the spi_ctrl prove job reach data words (larger depth, or a byte-spacing abstraction that keeps the
   PHY-gap assumption sound), or call it BMC in the logs and in chip_formal.sh's output.
6. B6: register core_rst_n. B5: fix CAPS[3:2]/HAS_BIAS. B7: qNaN in the L_FIN disabled-lane branch.
7. Clear rondo_rbus_arb on srst and keep KAT `valid` until the handshake; delete dead code and narrow the UNUSEDSIGNAL
   waiver; spec updates listed in §7 of this report.
