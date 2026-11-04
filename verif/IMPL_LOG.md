# Verification implementation log (newest at the bottom)
Agent run started 2026-11-03. Python: PY=.venv-rtl/bin/python. xsim: PATH=/home/CAD/2025.2/Vivado/bin.
Disk: /home had ~5 GB free at start (126 GB at later check); build/verif/ only; no RTL/sim/host file edited.

## V0.1 toolchain probes: DONE
See TOOLCHAIN.md. Key results: UVM OK; uvm_hdl FAIL (compiled off) -> SV hierarchical backdoor; DPI works only with a gcc-built dpi.so (xsc link fails on libmvec);
`unique` constraint and `cover property` unsupported; SVA assert/bind/covergroup/xcrg/code coverage OK; abc pdr needs verif/scripts/abc_wrap.sh (sby appends unsupported `-l`).

## V0.2 pre-fix snapshot: DONE (reconstructed)
build/verif/rtl_prefix/{rtl,formal}: 14 RTL files and 4 formal files copied from *.pre_fix, all others symlinked to the live files (unchanged by the fix round); MD5_prefix.txt (90 entries).
Caveat: only the fix round's own backups are used; rondo_seq.v.pre_fix does not contain the later CNT_INIT correction (that is correct for "pre-fix").
Host files (device.py, model.py, ...) pre-fix copies are *.pre_fix in host/rondo_host (used by host_frames.py for B4).

## V0.3 fix alignment: DONE
README.md section 1.4 (every row with RTL evidence) and uvm/env/rondo_fix_cfg.svh. Checked rondo_regs.v 322-393, rondo_seq.v, rondo_kat.v, rondo_dev.v 76-87.

## V1 xsim bring-up: DONE
verif/common/cfg/cfg_pkg.svh (cfg macros), verif/scripts/gen_filelists.sh, xsim_build.sh, uvm/tb/smoke_dev.sv (plain SV, rondo_dev, frontdoor load, START, ZBUF compare vs C model through DPI).
Elaborate + smoke: S, F, S_TB2, S_MB, S_SCAN_PG, S_MIN, S_ACC24 (TILE=0), S_CNT PASS bit-exact (bf16 and fp32); S_KAN elaborates (smoke not meaningful: KAN datapath not in the C model);
S-ACC24 with TILE=1 is the B3 elaboration $fatal (scripts/elab_neg.sh 7/7 PASS on the fixed RTL).
Speed (xsim, no waves): F DEV ~185k cycles (92.8k per format, load+run) in 3.4 s wall = ~55k cycles/s incl. DPI model; S DEV 10.7k cycles in ~1.3 s (startup dominated).

## V2 C model: DONE
verif/model/rondo_fpmodel.{c,h}, rondo_dpi.svh, Makefile (gcc), test_fpmodel_c.py. Result (build/verif/fpmodel_xcheck.log): fma e8s8/e8s24/e8s16 1,000,000 cases each (edges + near-cancel), 0 mismatches;
recip_stage 200,000 (bf16 t6 NR1/2, fp32 t8 NR1/2, t12 NR1/2), 0; SMALL layers 600 (bf16 acc8 and acc24, fp32; tbits 6/8/12; NR 1/2), 0; FULL layers 8 (4 per format), 0; tiled (PDIM'=S*8, 2-4 slices) 49, 0;
lane mask qNaN OK; crc8 (check 0xF4), crc32 chain, LFSR, kat_element, rotl32, checksum update vs packing.py/protocol.py: 0 mismatches.
Cases containing Inf/NaN are skipped (python model asserts); Inf/NaN rules in C are RISC-V class rules, NOT validated against the RTL (class-level checks only).
DPI call from SV verified (smoke_dev).

## F1 formal infrastructure: DONE
verif/formal/gen_jobs.py is the single source of all jobs (JOBS dict + jobs_extra.py): it emits SymbiYosys files (build/verif/formal/<tag>/<job>/<job>.sby) and JasperGold Tcl (verif/formal/jg/<job>_<task>.tcl, UNTESTED).
run_formal.sh runs all tasks in parallel (xargs -P), retries a task once if sby left no status, writes verif/reports/formal_summary[_prefix].md (proof type, depth, expected, result, covers reached, seconds).
Harnesses are tool-neutral: all (* anyseq *)/(* anyconst *) wires were converted to module input ports (verif/formal/convert_harness.py; anyconst = input plus stability assumption); canary assertions (`ifdef CANARY) are appended to each harness.
ABC=verif/scripts/abc_wrap.sh (strips the `-l` that sby appends to pdr). Legacy formal/ is untouched.
Results so far (fixed RTL): regs prove PROVEN (PDR/induction), cover 9/9, canary FAIL; arb prove PROVEN (PDR), cover 6/6, canary FAIL; spi_phy bmc 200 + cover 3/3 + canary; tile bmc 60 + cover 6/6 + canary;
seq bmc 70 (now with prog1: no-progress counter <= 40) + cover 7/7 + canary.

## Formal findings on the pre-fix RTL (red-on-prefix for formal)
seq (harness -DPREFIX, rtl_prefix): BMC FAILS at step 2 on `kr_q -> seq_active || kat_fail` (a KAT launch refused by the pre-fix sequencer is silently dropped) = B2 hole.
regs (rtl_prefix): fails in the order  shadow-cleared-by-srst (regs_f.v:72, robustness fix), B1 (regs_f.v:98: PWR_CTRL write while OPEN accepted), B2 (regs_f.v:104: KAT_START with CORE_HOLD accepted); the later assertions were checked by masking the earlier ones in a scratch copy.

## V3..V6 UVM environment (reduced scope), V7-V9, V10, V11, V12 (part), V15 (part): see below
verif/uvm: rondo_pkg.sv (one package), tb/tb_top.sv (one top, -d TOP_DEV rondo_dev + rbus agent, -d TOP_CHIP rondo_chip_top + SPI agent), agents/{rbus,spi}_agent.svh, env/ (geo, bus API, ref model, cov, watchdog, viol monitor, env),
tests in env/rondo_tests.svh. The RAL generator (V3) was NOT done: the register model is the hand-written transaction-level reference model in env/rondo_ref.svh (documented deviation).
Observe-then-predict: rbus_monitor stamps ACTIVE/tile OPEN/KAT in item.tag at request accept; layer events come from probe_if (layer_start/done, sr_running, fmt_applied, lane_en_applied).
The datapath oracle is the C model through DPI (never the RTL). Existing rondo_sva_{rbus,regs,seq,wmem} checkers are instantiated in tb_top and their viol bits raise UVM_ERROR (rondo_viol_mon).
xsim facts: uvm_cmdline_processor get_arg_value crashes the kernel under UVM_NO_DPI (not used); `soft` is a keyword (cov bin renamed); a gcc-built dpi.so is used for DPI.
First results (DEV, S, seed 1): u_bringup, u_reg_access (290 checks), u_load_crc, u_infer_bf16, u_infer_fp32, u_infer_rand, u_lane_mask, u_selfrun, u_counters, u_fmt_switch, u_soft_reset, u_kat_reg (KAT_GOT and KAT_SIG constants == independent
C-model signature for bf16 and fp32), u_b2_kat_pwr, u_tile_basic/u_tile_keep/u_b1_keep_corehold (TZ bit-exact vs C model with PDIM' = 3*PDIM, TILE_SEQ_CRC chain) PASS.
Red on pre-fix (rtl_prefix, tb_top_DEV_S_prefix): u_b2_kat_pwr FAILS (hang, no START_BUSY, KAT ran), u_b1_keep_corehold FAILS (PWR_CTRL accepted while OPEN, TZ mismatch); u_tile_basic passes on both (no PWR event).

## Later UVM work: CHIP top, SPI agent, more tests (V4, V10-V15 partial), BUG-1
CHIP top (tb_top -d TOP_CHIP): rondo_chip_top driven through SPI pins (mode 0, SCLK from a time base, R random per frame from {8,9,12,13,16,33}; monitor measures R in core cycles: R<6 UVM_ERROR, R<8 warning),
rbus monitor and probe clocked by the divided core clock (dev_clk), SVA checkers bound through the DEVP macro. Tests added: u_spi_proto (opcodes, 1..256-word bursts, tails, CRC mode, HCRC/DCRC corruption with rbus access counts), u_spi_abort,
u_spi_r6, u_clk_div, u_clk_src (random clk/clk_alt ratio, time-based glitch checker on clk_core), u_clkout, u_kat_strap, u_reset_async, u_err_all (every ERR cause incl. PARTIAL, WDOG, WSTALE_RUN, TILE_SEQ, SPI_FRAME, SPI_CRC),
u_chip_rand, u_caps, u_mbist_clean, u_b4_host_replay. Fixed TB mistakes found on the way (documented in the code): wr() of a 24-bit address through an 8-bit register helper; LOOPBACK index; ACTIVE windows that an SPI frame cannot hit.
RESULT: BUG-1 (reports/BUGS.md): u_spi_abort FAILS (SPI_FRAME missing for an abort inside the first byte of a header/word); kept failing and listed as known.
Not done: RAL generator (V3), u_trace_rand, u_dbg_*, u_mbist_faults / u_kat_fault (RONDO_FAULT_INJECT), u_scan_mode, u_tile_hostswap/pad/illegal/inval/rand, u_spi_max_burst/u_spi_overrun (SPI-only top), u_pwr_ctrl beyond B2, u_wdog (covered in u_err_all), 20k-access u_chip_rand.

## Bug scenarios (V16)
B1: u_b1_keep_corehold (UVM, DEV): red on pre-fix, green on fixed. B2: u_b2_kat_pwr: red/green; formal seq (kat_fail) red/green; formal kat (progress) red on pre-fix.
B3: scripts/elab_neg.sh: accsig24_tile etc. (7/7 PASS fixed; on the pre-fix tree accsig24_tile does not fatal). B4: verif/cocotb/b4_frames.py (host-level recorder: fixed min R 8.00, pre-fix min R 1.25 with 2 frames R<6) + u_b4_host_replay (UVM CHIP, replays the log: fixed PASS, pre-fix FAIL, SPI monitor R 1.25).
B5: u_caps on S, S_MIN, S_KAN, S_MB, S_SCAN_PG, S_ACC24 (formula incl. KAN bits). B6: formal/struct_checks.sh STRUCT.1 (PASS fixed, FAIL pre-fix) + u_reset_async. B7: verif/cocotb/run_b7.py reuses sim/test_core_c6.py::c6_start_in_done_disabled (both formats, Icarus):
PASS on fixed RTL, FAIL on rtl_prefix ("disabled lane keeps stale z"). Robustness: formal regs shadow property red on pre-fix; arbiter srst cancel covered by formal arb (cover) and rondo_sva_rbus in every UVM run.

## Additions requested by the author (Cadence flows), all UNTESTED HERE
verif/TOOLS.md; verif/uvm/scripts/run_xcelium.sh (+ verif/uvm/cov/xcelium_covfile.cf; regress.py --sim xcelium); verif/formal/jg/*.tcl (generated by gen_jobs.py from the same tables as the SBY jobs) + run_jg.sh;
JG-only full-strength tasks (spi_ctrl_jg_prove_full/gap1/cover_full, seq/tile/dev_bus/spi_phy jg_prove_unbounded) are listed in TOOLS.md. SV kept standard UVM 1.2: no xsim-only constructs in the SV (checked: no `unique` constraints, no `cover property`,
no uvm_hdl, no uvm_cmdline_processor; DPI is plain C + svdpi.h; plusargs are standard $value$plusargs).

## R1/R2 and closure (final)
regress.py (tiers smoke/nightly/signoff, --sim xsim|xcelium, --prefix, --cov), testlist.json, prefix_check.sh, cc_regress.sh + cc_table.py (code coverage), formal run/mutation scripts. Coverage closure loop: first merged functional coverage 77%, holes were a coverage-model bug (FORMAT transition
and format of memory accesses never sampled, ctrl bit mapping) plus missing stimulus (CTRL bits in ACTIVE/OPEN states, TRC and TILE_SLICE registers, PS region, FORMAT writes while ACTIVE): fixed in rondo_cov.svh / u_ctrl_combos / u_fmt_switch -> 100% of the defined bins.
Final signoff tier: 305 runs, 300 PASS, 5 known FAIL (u_spi_abort, BUG-1). Code coverage S build: DEV 92.5/80.7/75.4/67.8 (stmt/branch/cond/toggle), CHIP 92.2/77.6/75.1/64.6. Mutation: arb 87%, regs 27%, seq 23%, tile 13%, spi_ctrl 30%.
Formal: all jobs OK in reports/formal_summary.md (spi_ctrl pdr = info, NOTE-2). SIGNOFF.md written with the criteria table (not all met). No existing file was modified (no *.pre_verif backups were needed).

## Check round (independent checker, 2026-11-03)
Scratch work: build/verif_check/. Report: reports/CHECK_REPORT.md. No RTL, spec, existing test or host file was edited. Every edited verif file has a `<file>.pre_check` backup.
Changes to the verification environment (no check or coverage target weakened):
1. uvm/env/rondo_ref.svh: `e_partial` was declared twice (xsim accepted it; strict tools such as slang reject it, as Xcelium will). The duplicate was removed, and the staging declarations were moved above their first use.
2. uvm/env/rondo_cov.svh: `ignore_bins wr_addr_ok = binsof(op.wr) && binsof(out.ok) && 1'b0` is not a legal cross select expression and selected nothing, so it was removed.
   Bin `start` (it clashes with the covergroup built-in `start()`) was renamed to `start_cmd`.
3. uvm/env/rondo_tests.svh: class members `d_64` (u_infer) and `lens` (u_spi_proto) are now declared before use (strict-LRM issue).
   After 1-3, slang 12.1 (strict IEEE 1800, Accellera UVM library) reports 0 errors for the DEV and CHIP tops on S, F, S_MB, S_KAN and S_TB2. Before, it reported 9 errors (DEV) and 13 (CHIP).
   xsim signoff tier re-run after the edits: 300/305 (5 x u_spi_abort, BUG-1), functional coverage 100% on 305 merged DBs.
4. scripts/fcov_merge.sh (new): the functional-coverage merge had been done by hand, and its xcrg.log, xsim.covdb and xelab.pb were left in the repo root
   (now moved to build/verif_check/stray_root). The merge is now reproducible.
5. scripts/{xsim_build.sh,xsim_run.sh,cc_regress.sh,elab_neg.sh,regress.py,cc_table.py}: the Vivado bin directory can be overridden with VIVADO_BIN. The default is unchanged.
6. formal/gen_jobs.py -> jg/*.tcl: JG `analyze` now gets `+incdir+$RTL_ROOT/rtl/chip`, and the include-only rondo_kat_sigs.vh is no longer analyzed as a unit.
   Before, dev_bus_* failed to resolve the `include in rondo_dev.v. SBY files are unchanged.
7. uvm/scripts/run_xcelium.sh: `build` appends `_prefix` to the tag for a non-main RTL_ROOT, as xsim_build.sh does. Before, `regress.py --sim xcelium --prefix` overwrote the fixed snapshot
   and then ran a tag that did not exist. PASS now also requires TEST_DONE (same as xsim). Dry-run with a stub xrun: arguments and tags are as intended.
8. README.md "How to run": prerequisites and versions are listed, and every command was run as written (the old text had `run_formal.sh [job ...]`, a wrong usage, and a build command without TOPSEL).
   TOOLS.md: corrected the mutate.py usage line, added the JG/Xcelium first-use risks, and listed the fixes above.
