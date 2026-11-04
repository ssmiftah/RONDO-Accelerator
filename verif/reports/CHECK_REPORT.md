# Independent check of the RONDO verification environment (check round, 2026-11-03)

Scope: the formal and UVM environment under verif/, built by the implementing agent from docs/CHIP_VERIF_PLAN.md against the fixed RTL (spec v2.1.1).
Method: I re-ran the checks myself rather than reading the reports, wrote independent directed checks, injected faults into RTL and model copies,
and parsed the testbench with a strict SystemVerilog front end. All scratch work is in build/verif_check/.
No RTL, spec, existing test or host file was modified. Environment fixes are listed in section 6 and in IMPL_LOG.md ("Check round").

## 1. Verdict
**Fit to hand to a verification engineer, as a working foundation rather than a sign-off environment.** Everything the implementer reported as
run was reproduced: formal, UVM, B1–B7 red/green, the C-model cross-check and functional coverage. The checks are real: injected RTL and model
faults are caught. One RTL bug (BUG-1) is confirmed independently, and the open candidate (NOTE-2) is resolved as a harness artifact.

Caveats the engineer must know up front:
* The environment does not meet the plan's sign-off criteria (SIGNOFF.md says so honestly). 13 of the plan's 19 covergroups are missing. The six that
  exist are coarse, so their "100%" says little. Code coverage is below target, and the reported branch/condition/toggle figures are unweighted per-file means, which flatter the result.
* Formal is a safety net, not a set of functional proofs. Only regs, arb and kat are unbounded proofs (PDR). Mutation kill rates are 13–30% except arb (87%).
* The Cadence flows (Xcelium, JasperGold, IMC) have never been executed. I fixed four defects in them that would have failed on first use (section 6).
  Further first-use risks are listed in TOOLS.md.

## 2. BUG-1: confirmed, low severity, fix recommended before tapeout
**Evidence.** A new pin-level Icarus testbench (build/verif_check/spi_dir/tb_spi_dir.v; log run.log) drives `rondo_spi_slave`, the real PHY plus the
controller, with legal mode-0 timing (R = 8):
* WRITE, CRC off, N = 0. After the 6 header bytes, k data bits are sent and then CS rises:
  * k = 1..7: **no SPI_FRAME**.
  * k = 8..31: SPI_FRAME raised.
  * k = 32: the word is written.
  * The partial word is never written (0 writes for every k < 32).
* Opcode byte aborted after 1..7 bits: no SPI_FRAME.
* Header aborted inside byte 2: SPI_FRAME raised, because the M_HDR path flags any partial header.

**Root cause** (from the RTL):
* `rondo_spi_phy.v:85` registers `abort_q <= (bitcnt != 0)` at `frame_end`, so `mid_byte_abort` arrives one cycle after `frame_end`.
* `rondo_spi_ctrl.v:136/138/141` test `mid_byte_abort` only in the `frame_end` cycle, when it is still 0.
* The M_OPC branch (line 133) never flags an abort at all.

The bug is missed whenever no complete byte of the current word exists yet (`wpos`/`dpos` = 0). This matches BUGS.md exactly.
The formal harness misses it because `spi_ctrl_f.v:31` models `mid_abort = abort_i && frame_end`, i.e. simultaneous, unlike the real PHY.

**Severity.**
* Data integrity is not affected: partial words are always dropped and no rbus access is made.
* The impact is diagnostic only: the spec (5.3 rule 3) promises SPI_FRAME, and the chip does not raise it.
* The Pi host (spidev) only deasserts CS at transfer boundaries with whole bytes, so a healthy host never triggers this.
  It matters for detecting CS glitches, lost SCLK edges or a host crash in the middle of a transfer. Those are exactly the situations SPI_FRAME exists to report.
* The fix is small. Drive `mid_byte_abort` combinationally with `frame_end` (`frame_end & (bitcnt != 0)`) and add the M_OPC case.
  Then change the formal harness to model the real PHY timing, or better, prove PHY and controller composed.
  I do not recommend the alternative fix (delay `frame_end` by one cycle): it also moves `frame_end_o`, which applies CLK_CFG.

## 3. NOTE-2: not an RTL bug (harness over-approximation); a related robustness note
**Formal.**
* I reproduced the unbounded PDR counterexample at depth 38 in 8 s (assertions at spi_ctrl_f.v:120–121).
* I then added one assumption in a scratch copy (build/verif_check/note2): CS stays high for at least 3 clk_core cycles between frames.
  With it, ABC PDR found **no counterexample through frame 116 (CSGAP=3) and frame 140 (CSGAP=8)** before the 30-min timeout. Not proven, but a counterexample of length ≤ 116 is excluded.
* So the reported trace needs a CS-high gap of 1–2 core cycles followed immediately by a new frame. That is far outside anything the Pi host does (CS gaps are microseconds).

**Pin-level simulation** (same testbench). A READ frame with only the header, ended on the word boundary:
* With legal timing and rbus ready delayed 0–3 cycles, the word-0 read request is always issued before (or together with) `frame_end`: 0 late requests.
* A late request appears only if CS rises ≤ 2 synchronized clk_core cycles after the last SCLK rising edge.
  * d = 2 (reachable only at R = 6 with zero CS lag and an unlucky synchronizer phase): the request comes 1 cycle after `frame_end`. This is benign.
    It is the word-0 read that spec 5.3 rule 2 requires once the header is complete. Its response is dropped (mode != M_RDATA) and no error is raised.
  * d = 1 (CS rises while SCLK is still high, a mode-0 violation): `rx_valid` and `frame_end` coincide.
    The `rx_valid` case in `rondo_spi_ctrl.v` assigns `mode` after the `frame_end` branch, so the later assignment wins.
    Result: a spurious SPI_FRAME for a complete header, `mode` re-entering M_RDATA after the frame ended, and a late read.

**Conclusion.**
* No change is needed for legal hosts.
* Optional hardening: give `frame_end` priority over the `rx_valid` mode update in `rondo_spi_ctrl`.
* Harness fix for the engineer: add a CS-high-gap assumption, or attribute a request to the frame whose header completed, so the PDR task can become a real unbounded proof.

## 4. Claims checked and what I re-ran
| claim | re-run / evidence | result |
|---|---|---|
| Formal: regs, arb, kat PROVEN; BMC depths; covers; canaries FAIL | `verif/formal/run_formal.sh -j 14` (11.5 min) | **Confirmed**: 28/28 rows OK plus pdr info, identical to the implementer's table. "PROVEN" is genuine: ABC PDR returned PASS. Note that k-induction alone fails at depth 12/20 for regs/arb, so the label should read "PDR", not "k-induction/PDR". |
| Canaries meaningful | harness read | Mostly yes: they hit reachable events. The spi_phy and dev_bus canaries are `assert(1'b0)` after init, which only shows the assumptions are satisfiable; non-vacuity of those jobs rests on the covers (all reached). |
| Assumptions justified | all `assume`s read | Justified for bounded safety nets. Limits: spi_phy excludes the LOOPBACK and STATUS opcodes entirely (spi_phy_f.v:54). tile is limited to NSLICE ≤ 3, TBATCH ≤ 2 with constant cfg. seq to SR_N ≤ 4, SR_COUNT ≤ 3. The spi_ctrl PHY abstraction differs from the PHY in two ways (simultaneous `mid_abort`; `rx_valid` dropped when it coincides with `frame_end`), which hid BUG-1. kat_f.v:32 is a no-op assume. |
| Mutation kill rates | reports read, not re-run | Plausible. Below target except arb; survivors are not argued. |
| UVM signoff 300/305 (u_spi_abort only) | regress.py signoff with seeds 1–5 (305 runs, `--cov`) and **new seeds 11–13** (183 runs) | **Confirmed**: 300/305 and 180/183; the only failures are u_spi_abort. Smoke 4/4. |
| Scoreboard actually compares | 4 RTL mutants in scratch trees (build/verif_check/mut) | **Confirmed**: all four killed by the right checker. (1) ZBUF LSB flip: u_infer_bf16/fp32/rand and u_selfrun fail with "ZBUF[0] vs C model" (1 ulp). (2) XSEL range off-by-one: u_reg_access and u_err_all fail (rsp_err mismatch). (3) SPI CRC polynomial 0x07→0x05: u_spi_proto fails. (4) IRQ_EN mask width: u_reg_access fails. u_neg_ref (deliberately wrong expectation) passes as designed. |
| Functional coverage 100% of six covergroups | `fcov_merge.sh` on the 305 fresh DBs | **Confirmed** at 100%, and the merge is genuine (one DB alone gives 6.4%). The coverage model is thin, though: err_cg bins 6 single-bit ERR values; SPI_FRAME, SPI_CRC, WDOG, PARTIAL and multi-bit values fall into a `default` bin, which is not counted. |
| Code coverage ~92/80/75/66 | `cc_regress.sh` + `cc_table.py` (README commands) | **Reproduced identically** with the README commands (DEV 92.5/80.7/75.4/67.8, CHIP 92.2/77.6/75.1/64.6). The numbers are statement-weighted for statements but unweighted per-file means for branch/condition/toggle. xcrg's own overall DEV scores were 92.7 / 70.8 / 78.2 / 56.5 (line/branch/cond/toggle). rondo_regs toggle is 26%, rondo_tile 31%, rondo_seq 42%. |
| B1–B7 red/green | `prefix_check.sh` (full); B1/B2 additionally on seeds 1 and 7, DEV and CHIP, failure messages read | **Confirmed**. B1 fails for the right reason ("PWR_CTRL write while a tile sequence is OPEN was accepted", ERR TILE_SEQ missing). B2: hang plus no START_BUSY. B4: SPI_MON R = 1.25 < 6. B7: "disabled lane keeps stale z". Caveat: prefix_check.sh judges "red" by exit status only, and every pre-fix UVM run also fails on the VERSION check, so a test could be "red" for the wrong reason; the B5 row is a hard-coded string. |
| C DPI model = sim/fpmodel.py | `test_fpmodel_c.py --quick`: 0 mismatches; a C mutant (round-to-nearest-even ties → round down) gives 1,324 mismatches | **Confirmed** and sensitive. The full 10^6-case run was not repeated. |
| BUG-1, NOTE-2 | sections 2–3 | BUG-1 confirmed; NOTE-2 is a harness artifact |
| Nothing outside verif/ changed | mtime scan of the tree against the earliest verif file (12:25), excluding build/ and .venv-rtl | **Confirmed** for sources. The only new files outside verif/ and build/ were stray tool outputs in the repo root (xcrg.log, xsim.covdb/, xelab.pb from the hand-run coverage merge), now moved to build/verif_check/stray_root. |
| Existing regressions green | `scripts/chip_regress_new.py icarus`; host pytest | Host pytest: 40 passed. chip_regress_new icarus: **CHIP REGRESSION OK** (all 19 runners PASS, 36 min). The xsim smoke and signoff runs are also green. |
| Cadence flows | read, plus a stub-xrun dry run; slang strict parse | See sections 5–6 |

## 5. Cadence flows (read review; nothing can be executed here)
**Xcelium** (`verif/uvm/scripts/run_xcelium.sh`): the option set is sound: `-uvm -uvmhome CDNS-1.2`, `-define`, `-incdir`, the `.c` DPI file compiled by xrun,
`-svseed`, `+UVM_TESTNAME`, `-covworkdir/-covtest/-covfile`, and an IMC batch merge.
* Fixed: the prefix tag and the pass criterion (section 6).
* To verify on first use:
  * whether `-coverage/-covfile` are accepted at `-R` run time;
  * `deselect_coverage -betsoft` in xcelium_covfile.cf (not a recognizable flag combination; probably meant `-betf`);
  * the IMC `merge … -out` / `load -run` paths;
  * the per-config filelist directory shared between concurrent builds.

**SV portability**:
* slang 12.1 (strict IEEE 1800) with the Accellera UVM library reported **9 (DEV) / 13 (CHIP) errors** before the fixes:
  * a duplicate class property (`e_partial`);
  * an illegal cross select (`&& 1'b0`);
  * a bin named `start`;
  * forward references to class members.
* After the fixes: **0 errors** on S, F, S_MB, S_KAN and S_TB2.
* No xsim-only constructs remain: no `unique` constraints, `cover property`, uvm_hdl or cmdline processor. DPI is plain C.
* Hierarchical probes into the DUT are compile-time references, so no `-access` is needed for tests.

**JasperGold** (`verif/formal/jg/*.tcl`, `run_jg.sh`): the structure is right (analyze -sv12 / elaborate -top / clock / prove -all / report).
* Fixed: dev_bus could not resolve `` `include "rondo_kat_sigs.vh" ``; there was no incdir, and the .vh was analyzed as a unit.
* Remaining risks:
  * `reset -none` depends on JG honoring declaration initial values of the `init` register. This is the most likely first-use failure; compare canary and cover results with SBY.
  * `-define NAME=value` syntax.
  * The JG-only "full-strength" tasks are unbounded versions with no strengthening invariants; they may not converge.

## 6. Defects fixed in the environment (each file backed up as `<file>.pre_check`; logged in IMPL_LOG.md "Check round")
1. rondo_ref.svh: removed a duplicate declaration of `e_partial` and moved the staging declarations before their use.
2. rondo_cov.svh: removed the illegal no-op `ignore_bins … && 1'b0`; renamed bin `start` to `start_cmd`.
3. rondo_tests.svh: `d_64` and `lens` are now declared before use.

   Items 1–3 change no check. The xsim signoff re-run gives 300/305 and coverage stays at 100%.
4. New `verif/scripts/fcov_merge.sh`: the functional-coverage merge was not reproducible from the scripts.
5. VIVADO_BIN override in xsim_build.sh, xsim_run.sh, cc_regress.sh, elab_neg.sh, regress.py and cc_table.py. Previously the path was hard-coded to this machine.
6. gen_jobs.py and the regenerated jg/*.tcl: `+incdir+` added; the include-only .vh is no longer analyzed.
7. run_xcelium.sh: the `_prefix` tag for a non-main RTL_ROOT, and the TEST_DONE pass criterion.
8. README.md "How to run" rewritten. It had a wrong `run_formal.sh [job ...]` usage and a build command without TOPSEL, and it lacked prerequisites, regress, prefix_check, coverage and legacy-regression commands. TOOLS.md: corrected the mutate.py usage line and added first-use risks.

Every README command was executed as written in this round. The exception is mutate.py, which was not re-run.

## 7. Gaps against the plan's sign-off criteria, and the remaining work in priority order
1. **Fix BUG-1 in the RTL** (author decision), then make u_spi_abort a passing test. Fix the spi_ctrl harness PHY timing (or compose PHY and controller) so that formal would catch it. Add the CS-gap assumption to close the spi_ctrl proof (NOTE-2).
2. **Scoreboards the plan requires but which are missing or empty:**
   * `rondo_pin_sb` has an empty active-state branch, so irq/busy/st_pass equations and clkout frequency are not checked.
   * IRQ_STATUS and STATUS are never compared: `irq_pred` is computed but not used.
   * ERR_STATUS is compared on 6 bits only; there is no "unexplained ERR bit" check.
   * There is no kat_sb for ST_STATUS or the st_pass pin beyond u_kat_reg's constants.
   * Bind the existing `rondo_sva_spi` and `rondo_sva_tile` checkers, which exist in rtl/chip/sva but are not instantiated in tb_top.
   * Write `rondo_sva_chip` (plan 3.9).
3. **Missing covergroups** (13 of 19): spi_cg, irq_cg, status_cg, seq_cg, srst_cg, pwr_cg, clk_cg, rst_cg, dbg_cg, trc_cg, selftest_cg, tile_cg, pins_cg.
   Also deepen err_cg (every ERR bit set/masked/W1C), load_cg (order, PARTIAL kind, readback while ACTIVE) and dp_cg (output class, guard hits).
4. **Untested features**:
   * debug taps, inject and fault localization (u_dbg_*);
   * trace (u_trace_rand);
   * MBIST with faults and KAT fault (RONDO_FAULT_INJECT builds);
   * scan/test_mode (u_scan_mode);
   * tiling host-swap, padding, illegal commands, invalidation and random (u_tile_*);
   * PWR_CTRL beyond B2;
   * WDOG as its own test;
   * SPI-only top (u_spi_max_burst, u_spi_overrun);
   * F-config CHIP frontdoor test;
   * u_chip_rand at 20k accesses (it runs 60);
   * mode-B vector oracle;
   * RAL (V3).
5. **Formal to the 2.5 targets:**
   * not written: FV-PACK/CKS, FV-CLK/RST, FV-MB, FV-TRC;
   * the B1 tile property;
   * unbounded seq/tile/spi_phy/dev_bus proofs (they need invariants);
   * BMC depths below the minimums (spi_phy 200 vs 400, seq 70 vs 120, dev_bus 60 vs 120);
   * mutation kill ≥ 80% with survivors argued (regs 27%, seq 23%, tile 13%, spi_ctrl 30%).
6. **Code coverage to 98/95/90/90**:
   * report weighted (or tool-overall) figures, not per-file means;
   * run the whole signoff list on all seeds, not seed 1 with a hand-picked list;
   * add S_MB, S_SCAN_PG and fault-injection builds (W-CC-1 is pending approval);
   * extract FSM state/transition coverage;
   * main holes: rondo_regs (toggle 26%, condition 65%), rondo_tile (toggle 31%, branch 75%), rondo_seq (toggle 42%), rondo_dev (statement 83%), rondo_cksum (branch 71%).
7. **Process:**
   * generate matrix_status.md (criterion 1) and report.py;
   * make prefix_check.sh check bug-specific error IDs rather than exit status, and actually run u_caps for the B5 row;
   * run the remaining legacy regressions (chip_regress_new under Verilator, chip_regress_old, chip_formal.sh);
   * get waiver approvals;
   * first-use bring-up of the Xcelium and JasperGold flows on a Cadence host (TOOLS.md risks).

## 8. Not run in this round
* Cadence tools: none on this machine.
* The full 10^6-case C-model cross-check: --quick only, plus the mutant.
* Mutation scripts (reports read only).
* Pre-fix formal (formal_summary_prefix.md not regenerated).
* chip_regress_new under Verilator, chip_regress_old.py and chip_formal.sh.
* elab_neg.sh was run only inside prefix_check.sh.
