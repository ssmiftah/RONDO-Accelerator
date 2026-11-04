# RONDO chip verification: sign-off report (R2)

Date: 2026-11-03. RTL: fixed tree (rtl/, spec v2.1.1, VERSION 0x00020101). Pre-fix comparison tree: build/verif/rtl_prefix. Tools run: Vivado xsim 2025.2 (UVM 1.2), SymbiYosys/yosys 0.66, Verilator/Icarus (existing cocotb).
JasperGold and Xcelium flows exist (verif/TOOLS.md) but were NOT run here (no Cadence tools): untested.
**Verdict: the plan's sign-off criteria are not all met** (see the table); one RTL bug found (BUG-1), one open candidate (NOTE-2).

## Sign-off criteria (plan section 4)

| # | criterion | result | evidence |
|---|---|---|---|
| 1 | every row of the matrix PASS | NOT assessed: matrix_status.md was not generated; rows without any test are listed under "not done" below | |
| 2 | UVM: all tests pass on all seeds, zero errors | 300/305 runs PASS (61 tests-config pairs x 5 seeds); the 5 failures are `u_spi_abort` (BUG-1), kept failing and listed; 0 other UVM_ERROR/UVM_FATAL, 0 SVA `viol`, 0 hang reports | reports/summary_signoff.md |
| 3 | functional coverage 100% of defined bins (waived <= 2%) | 100% of the bins of the 6 covergroups that exist (reg, err, ctrl, dp, load, fmt), merged over all 304 DBs, no waivers; the plan's other covergroups (spi, seq, srst, pwr, clk, rst, dbg, trc, selftest, tile, pins, status, irq) were NOT implemented | reports/cov/functional_merged.txt |
| 4 | code coverage rtl/chip: stmt >= 98, branch >= 95, cond >= 90, toggle >= 90 | NOT met. DEV top (S): statement 92.5%, branch 80.7%, condition 75.4%, toggle 67.8%; CHIP top (S): 92.2 / 77.6 / 75.1 / 64.6 (rtl/chip minus sva; statement weighted, others unweighted means of per-file scores). FSM state/transition coverage was not extracted. Not covered: trace, MBIST (S_MB faults), debug taps, scan/PG, KAN, fault injection | reports/cov/code_DEV_S.md, code_CHIP_S.md |
| 5 | formal statuses per 2.5, covers reached, canaries FAIL, mutation >= 80% | see formal table: covers 100% reached where run, all canaries FAIL as required; spi_ctrl is BMC only (34/28), seq/tile/dev_bus BMC only; mutation kill: arb 87%, regs 27%, seq 23%, tile 13%, spi_ctrl 30% (NOT met) | reports/formal_summary.md, mutation_summary.md |
| 6 | B1-B7 tests red on pre-fix, green on fixed | MET for B1, B2, B3, B4, B6, B7 and the robustness items; B5 green on fixed (CAPS formula on six builds), not applicable on pre-fix | reports/prefix_check.md |
| 7 | C-model 100% bit-exact; mode A/B agree on F | model vs sim/fpmodel.py bit-exact: 3 x 10^6 fma, 2 x 10^5 recip_stage, 600 SMALL + 8 FULL layers, 49 tiled, CRC/LFSR/checksum, 0 mismatches. Mode B (vector files) NOT implemented | build/verif/fpmodel_xcheck.log |
| 8 | existing regressions still green | NOT re-run by this work (no existing file was edited; the legacy flows were not touched) | |

## UVM results
* Tests (ids): u_bringup, u_caps, u_reg_access, u_load_crc, u_infer_bf16/fp32/rand, u_lane_mask, u_selfrun, u_counters, u_fmt_switch, u_soft_reset, u_kat_reg, u_kat_strap, u_mbist_clean, u_b1_keep_corehold, u_b2_kat_pwr, u_b4_host_replay, u_tile_basic, u_tile_keep,
  u_err_all, u_ctrl_combos, u_spi_proto, u_spi_abort, u_spi_r6, u_clk_div, u_clk_src, u_clkout, u_reset_async, u_chip_rand, u_neg_ref (scoreboard negative check). Configs: S (DEV, CHIP), S_MIN, S_KAN (u_caps), S_MB, S_SCAN_PG (u_caps), S_ACC24, S_TB2, S_CNT, F (DEV).
* signoff tier: seeds 1-5 on every test/config pair in testlist.json: 305 runs, 300 PASS, 5 known FAIL (u_spi_abort CHIP S seeds 1-5, BUG-1). Wall time 190 s (10 parallel runs; xsim ~50k cycles/s at F).
* The datapath oracle is the C model (never the RTL); KAT signature (KAT_GOT_* and the KAT_SIG constants) matches an independently computed signature for S and F in both formats.
* Pre-fix runs (reports/prefix_red_green_runs.md): u_b1_keep_corehold, u_b2_kat_pwr, u_b4_host_replay, u_soft_reset (DEV: dropped rbus response, SVA violation, hang) FAIL on the pre-fix RTL.

## Formal results (SymbiYosys; reports/formal_summary.md)
| block | job | proof type / depth | result | covers | canary |
|---|---|---|---|---|---|
| rondo_regs | regs prove | PROVEN (k-induction/PDR), incl. B1, B2, e4, reset values, RW read-back, shadow | PASS | 11/11 | FAIL ok |
| rondo_rbus_arb | arb prove | PROVEN (PDR), incl. payload/response routing, srst, bounded wait | PASS | 6/6 | FAIL ok |
| rondo_kat | kat prove | PROVEN (PDR): progress within 100 cycles incl. refused launch (B2), rb1, address order, no pass after refusal | PASS | 6/6 (cover, depth 80) | FAIL ok |
| rondo_kat | kat bmc_data / bmc_srst | BMC 60 (LFSR data/exponent; srst) | PASS | | |
| rondo_seq | seq bmc | BMC 70 (launch rule, counters, lc, KAT answered, prog1 <= 40) | PASS | 7/7 | FAIL ok |
| rondo_tile | tile bmc | BMC 60 | PASS | 6/6 | FAIL ok |
| rondo_spi_phy | spi_phy bmc | BMC 200 | PASS | 3/3 | FAIL ok |
| rondo_spi_ctrl | bmc_nocrc / bmc_crc | BMC 34 / 28 (solver limit; abstraction as in formal/spi_ctrl.sby) | PASS | cover depth 160: 14/14 | canary and mutant FAIL ok |
| rondo_spi_ctrl | pdr (unbounded attempt) | PDR | FAIL (info): trace at depth 38, see BUGS.md NOTE-2 | | |
| rondo_dev (abstract layers) | dev_bus bmc | BMC 60 (TILE=1) | PASS | 4/4 | FAIL ok |
| structure | struct_checks.sh | STRUCT.1 core_rst_n from a flop: PASS (FAILS on pre-fix); STRUCT.2 3 latches = 3 rondo_icg: PASS | | | |
Not done: FV-PACK/CKS, FV-CLK/RST, FV-MB, FV-TRC, FV-TILE t3 (B1) property, k-induction for spi_ctrl (stage B), the tile and spi_phy unbounded proofs, SBY unbounded proofs of seq/tile/dev_bus (JG-only tasks exist, untested).
Pre-fix formal (reports/formal_summary_prefix.md): seq BMC FAILS at step 2 (dropped KAT launch), regs FAILS (shadow, B1, B2 assertions in that order), kat prove FAILS (hang beyond 100 cycles). arb is not comparable (port `srst` is new); tile passes on both (no PWR event modelled).

## RTL bugs found
BUG-1 (spi_phy/spi_ctrl): a CS abort inside a byte is not flagged SPI_FRAME when no byte of the current header/word completed (`mid_byte_abort` is one cycle late). Test: u_spi_abort. NOTE-2: open candidate. Details: reports/BUGS.md.

## Waivers
verif/WAIVERS.md: none in use (all marked pending author approval). Known failing test: u_spi_abort (BUG-1), not waived.

## Deviations from the plan
No RAL generator (hand-written transaction-level reference model); one UVM package and one top for DEV/CHIP (no separate SPI-only top, no u_spi_max_burst/u_spi_overrun); DPI built with gcc (xsc fails to link on this host); backdoor not used (frontdoor only; uvm_hdl unavailable);
formal harnesses converted to tool-neutral input ports; formal jobs for PHY/CTRL reuse the legacy harness bodies; mutation kill rates below target; code coverage only for the S build; the Xcelium/JasperGold flows are untested.

## Not run / not done
UVM: u_trace_rand, u_dbg_taps/inject/fault_localize, u_mbist_faults, u_kat_fault (fault injection), u_scan_mode, u_tile_hostswap/pad/illegal/inval/rand, u_wdog (covered inside u_err_all), SPI-only top tests, F CHIP frontdoor test, u_chip_rand at 20k accesses (runs 60 operations per seed), mode-B vectors,
all covergroups beyond the six listed, matrix_status.md, report.py. Existing regressions (chip_regress_*, host pytest) were not re-run.

## Disk
build/verif ~ 0.8 GB at the end (xsim snapshots 405 MB, formal 72 MB, code-coverage runs 167 MB, cocotb 84 MB); /home free 125 GB (started at 5.1 GB per the instruction; a later check showed 125 GB free); stale outputs of mutation runs and run dirs deleted; no existing file deleted.
