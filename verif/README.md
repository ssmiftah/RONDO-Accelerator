# RONDO chip verification (formal + UVM on xsim)

Plan: docs/CHIP_VERIF_PLAN.md. Fixed RTL = rtl/ (spec v2.1.1, VERSION 0x00020101). Pre-fix RTL = build/verif/rtl_prefix (symlinks to unchanged files, copies of the `*.pre_fix` backups for the 14 edited files; hashes in MD5_prefix.txt).
Status and evidence: IMPL_LOG.md, reports/SIGNOFF.md, reports/BUGS.md, WAIVERS.md, TOOLCHAIN.md. All outputs go to build/verif/.

## How to run (commands checked in the check round; run from the repository root)
Prerequisites (versions used here): Vivado 2025.2 xsim with its precompiled UVM 1.2 (set `VIVADO_BIN=<vivado>/bin` if it is not at
/home/CAD/2025.2/Vivado/bin; `make -C verif/model XSIM_INC=<vivado>/data/xsim/include` likewise), gcc, Yosys 0.66 + SymbiYosys 0.70 + yices 2.7 + z3 4.16,
Berkeley ABC at /usr/bin/abc (wrapped by verif/scripts/abc_wrap.sh), Icarus 13, and the repository's Python venv `.venv-rtl` (Python 3.13, cocotb 2.0.1,
pytest; used for the C-model cross-check, B4 frame recording and B7). Cadence flows: verif/TOOLS.md (untested).
* C model: `make -C verif/model` ; `.venv-rtl/bin/python -I verif/model/test_fpmodel_c.py [--quick]` (expect `TOTAL MISMATCHES: 0`).
* xsim build (normally done by regress.py): `TOPSEL=DEV|CHIP verif/scripts/xsim_build.sh tb_top <cfg> [RTL_ROOT]` (cfg = S F S_TB2 S_MB S_SCAN_PG S_MIN S_ACC24 S_KAN S_CNT)
  -> build/verif/xsim/tb_top_<TOPSEL>_<cfg>[_prefix]; one test: `verif/scripts/xsim_run.sh tb_top_DEV_S u_bringup 1 [+ARG=v ...]` (prints PASS/FAIL; log in build/verif/runs/).
* UVM regression: `.venv-rtl/bin/python verif/scripts/regress.py --tier smoke|nightly|signoff [-j N] [--seeds 1,2] [--tests a,b] [--prefix] [--cov]`
  -> verif/reports/summary_<tier>[_prefix].md (exit 1 on any unexpected failure; u_spi_abort is a listed known failure, BUG-1).
  Expected: smoke 4/4; signoff 300/305 (5 x u_spi_abort). Wall time ~2 min at -j 16.
* Functional coverage: `regress.py --tier signoff --cov`, then `verif/scripts/fcov_merge.sh` -> verif/reports/cov/functional_merged.txt.
* Code coverage (S build, seed 1): `verif/scripts/cc_regress.sh DEV S "<tests>"` and `verif/scripts/cc_regress.sh CHIP S "<tests>"`, then
  `python3 verif/scripts/cc_table.py DEV_S CHIP_S` -> verif/reports/cov/code_<top>_S.md. Test lists used for the reported numbers:
  DEV: u_bringup u_reg_access u_load_crc u_infer_bf16 u_infer_fp32 u_infer_rand u_lane_mask u_selfrun u_counters u_fmt_switch u_soft_reset u_kat_reg u_b2_kat_pwr u_tile_basic u_tile_keep u_b1_keep_corehold u_err_all u_chip_rand u_caps u_ctrl_combos u_neg_ref;
  CHIP: u_bringup u_reg_access u_load_crc u_infer_bf16 u_selfrun u_fmt_switch u_soft_reset u_b2_kat_pwr u_err_all u_spi_proto u_spi_abort u_spi_r6 u_clk_div u_clk_src u_clkout u_kat_strap u_reset_async u_chip_rand u_b4_host_replay u_ctrl_combos u_neg_ref.
  (u_b4_host_replay needs build/verif/b4_fixed.log, written by any regress.py run.)
* Formal: `verif/formal/run_formal.sh [--prefix] [--jobs "regs arb"] [--tasks "prove cover"] [-j N]` -> verif/reports/formal_summary[_prefix].md (~12 min at -j 14;
  every row must be `(OK)`; spi_ctrl `pdr` is informational, see reports/BUGS.md NOTE-2). Mutation: `python3 verif/formal/mutate.py ...` (see TOOLS.md). Structure: `verif/formal/struct_checks.sh [RTL_ROOT]`.
* Elaboration negatives (B3): `verif/scripts/elab_neg.sh [RTL_ROOT]`.
* Red-on-pre-fix / green-on-fixed table (B1-B7): `verif/scripts/prefix_check.sh` -> verif/reports/prefix_check.md (~3 min). Note: it judges "red" by exit status only;
  the B5 row is a fixed text (u_caps runs in the regression); see reports/CHECK_REPORT.md.
* Legacy regressions (unchanged, must stay green): `.venv-rtl/bin/python scripts/chip_regress_new.py icarus`; `cd host && ../.venv-rtl/bin/python -m pytest -q tests`.

## 1.4 Behaviours that depend on the fix plan (as implemented; checked in the RTL)
| bug | expected behaviour in the fixed RTL | RTL evidence | invariant checked |
|---|---|---|---|
| B1 | PWR_CTRL write while a tile sequence is OPEN (TILE build) is refused, ERR.TILE_SEQ set, register unchanged; PWR_CTRL otherwise still BUSY_WR while ACTIVE | rondo_regs.v:358 | no tiled run completes with wrong TZ without TILE_STALE/TILE_SEQ |
| B2 | KAT_START with PWR_CTRL[1:0] != 0 -> ERR.START_BUSY, nothing launched (after the tile_open check); MBIST_START is allowed with the core held/clock-off and completes; defensive path: seq refusal pulses kat_fail -> rondo_kat E_SIG ends with KAT_FAIL | rondo_regs.v:338, rondo_seq.v:273/294, rondo_kat.v:237 | ACTIVE returns to 0 within T_PROGRESS after any command |
| B3 | TILE with ACCSIG_BF16 != 8 (HAS_BF16) is an elaboration $fatal ("rondo_dev: TILE=1 needs ACCSIG_BF16=8 ..."); S-ACC24 positive build uses TILE=0; other elaboration errors: NPAR power of two, LNW+WAW+FW <= 23, TBITS_FP32 in {8,12}, NR_ITERS_FP32 in {1,2}, 2*TRACE_DEPTH <= 65536, PS/TX/TZ offsets <= 16 bits | rondo_dev.v:76-87 | scripts/elab_neg.sh |
| B4 | host `set_clock` writes CLK_CFG, then lowers SCLK (set_speed) before any further frame; transports enforce R >= 8 (LinkRateError) | host/rondo_host/device.py, cocotb_transport.py | monitor: R < 6 error, R < 8 warning |
| B5 | CAPS[3:2] = LAYER, CAPS[4] = HAS_BIAS = (LAYER == 0); default CAPS 0x0002e7b3 (S); KAN additionally clears FP32, GUARD, READBACK, DBG, LANE_MASK, TILE (S_KAN CAPS 0xc605) | rondo_dev.v:88 CAPS_V | CAPS equals the spec formula per build |
| B6 | core_rst_n[f] = test_mode ? rst_n : run_f[f]; run_f is a flop with async reset | rondo_seq.v, scripts/chip_struct.sh | structural check + no glitch |
| B7 | disabled lane writes qNaN when start arrives in the done cycle | fused_coproc_pipe.v L_FIN | disabled lane z = qNaN after every start |
| robust | soft reset: shadows cleared, wpack read cache and staging flushed (flush_staging also clears c_valid/rs/rd_pend), arbiter does not grant K/M during srst and cancels an unaccepted internal request; slave FSM no longer reset by srst (D_WAITRD aborts with err) | rondo_rbus_arb.v, rondo_wpack.v, rondo_regs.v, rondo_dev.v | rbus rule 2 on every master port; no internal write after srst |
| F1 | spi_ctrl formal = BMC depth 34 (CRC off) / 28 (CRC on) at GAPN 2 + cover depth 160 at GAPN 4 (no unbounded proof; payload-zero abstraction) | formal/spi_ctrl.sby | |
| misc | CNT_INIT zero-extended in rondo_seq (found after the fix regression) | rondo_seq.v | |

## Layout (what exists)
* `model/` C model + DPI + cross-check; `common/cfg/cfg_pkg.svh` parameter sets; `uvm/` standard UVM 1.2 testbench (tb_top for DEV and CHIP, agents, ref model, coverage, tests), `uvm/scripts/run_xcelium.sh`;
* `formal/` single-source job generator (`gen_jobs.py`), SBY runner, JasperGold scripts (`jg/`), harnesses (`jobs/*/`), structural checks, mutation script, CONTRACTS.md;
* `cocotb/` B4 frame recorder, B7 runner (reuses the existing bench); `scripts/` build/run/regress/prefix_check/elab_neg; `reports/` all generated results; TOOLS.md, IMPL_LOG.md, WAIVERS.md.
