# RONDO chip wrapper: fix plan (from docs/CHIP_VERIFY_REPORT.md)

Plan date 2026-11-03. Input: CHIP_VERIFY_REPORT.md (B1–B7, F1, robustness notes, §7 deviations), spec v2.1,
CHIP_IMPL_LOG.md. The implementer follows the tasks in order. Each task gives the finding, the files and lines,
the exact change, the spec edits, the test to add (it must FAIL before the change and PASS after) and the
acceptance criteria. Line numbers are as of 2026-11-03.

Ground rules
* Core changes (rtl/core) must be additive and parameter-gated; default parameters must stay bit- and cycle-identical
  to the as-built core (checked by the T-EQ bench, task 0.3).
* Author decisions stay fixed (bf16+fp32 run-time FORMAT, fp32 TBITS 8 / NR_ITERS 2, ACCSIG_BF16 8, NXBUF 4, one
  FPGA bitstream per format, accumulator tap on, Pi 5 SPI mode 0, IRQ_EN reset 0x7F, TILE_B 8).
* Never use sudo. Do not touch utils_CoFrNet.py, Customized_Linear_Classes.py or CoFrNet_continuants.py.
* Python: `PY=/home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI-main/.venv-rtl/bin/python` (the venv lives in the
  project root; "../.venv-rtl" only works when the current directory is host/).
* The project is not a git repository. Before editing a file, copy it to `<file>.pre_fix` (the same convention as
  `.pre_chip` / `.pre_tile`). Log every task in docs/CHIP_IMPL_LOG.md under a new "## Fix round (CHIP_FIX_PLAN)" section.
* "Fails before" means: run the new test on the unmodified tree first, record the failure in the impl log, then
  apply the fix.

---------------------------------------------------------------------------------------------------------------------

## Task 0 — preparation

0.1 Record md5sums of utils_CoFrNet.py, Customized_Linear_Classes.py and CoFrNet_continuants.py (wherever they are:
    `find .. -name ...`) and of every rtl/core/*.pre_chip / *.pre_c8 file into build/fix/md5_before.txt. Recheck them
    at the end.

0.2 Baseline: run the full regression checklist (end of this document) once on the unmodified tree and save the logs
    in build/fix/baseline/. Known: chip_regress_old verilator may show run_train_coproc / run_train_ladder rc=250
    flakes (the report says they pass alone). Treat those as flakes only if they pass when re-run alone.

0.3 T-EQ: make the verifier's default-parameter equivalence bench permanent. It is needed again because B7 edits
    the core.
    * New sim/tb_core_eq.v (from build/verify/eq/tb_eq.v; tb_eqb.v / tb_eq32.v differ only in parameters: merge
      them into one tb with parameters SIG/ACCSIG/TBITS/WIDTH/PDIM/NINF/SEED).
    * New sim/run_core_eq.py. At run time it generates the `*_old` modules into its build dir
      (sim_build_chip/core_eq/) from rtl/core/{fused_coproc_pipe,affine_bank_pipe,ladder_engine_inter,recip_nr_pipe}.v.pre_chip
      by renaming every module and every instantiation of those four modules to `<name>_old` (a regex on
      `\bmodule\s+NAME\b` and `\bNAME\s*#?\s*\(`).
      Three configs: bf16 SIG8/ACCSIG8/TBITS6 WIDTH16 PDIM8 (60 inferences), fp32 SIG24 TBITS12 NR1 (60),
      bf16 WIDTH32 PDIM5 (NBATCHES=2, 30). The tb prints `EQ RESULT ... mismatches=N`; the runner fails if N≠0.
      It must report ≥1 passing cocotb-style test or a summary line the regress scripts accept: give it a trivial
      cocotb test that runs the Verilog bench and checks the result, as the other run_core_* runners do.
    * Add "core_eq" to scripts/chip_regress_old.py (after run_core_c8), for both simulators.
    * Accept: 150 inferences, 0 mismatches, under Icarus and Verilator.

0.4 Turn the verifier's scenario tests into permanent tests (these are the B1 and B2 tests; they must fail now):
    * Move keep_corehold into sim/test_chip_tile.py as `tile_pwr_ctrl_while_open` (details in task 1).
    * Move kat_with_clk_off into sim/test_chip_kat.py as `kat_refused_when_core_off` (details in task 2).

---------------------------------------------------------------------------------------------------------------------

## Task 1 — B1: KEEP partial sums lost across PWR_CTRL.CORE_HOLD

Finding: PWR_CTRL writes are accepted while a tile sequence is OPEN (rondo_regs.v:374-377). CORE_HOLD drops `want`
(rondo_seq.v:127-128), so core_rst_n falls (:161) and the core `acc` is asynchronously cleared
(affine_bank_pipe.v:250). The KEEP valid flag (rondo_tile.v:157) is not cleared, so the next slice silently starts
from 0.

Decision: reject PWR_CTRL writes with TILE_SEQ while OPEN. This is consistent with FORMAT and LANE_EN (rondo_regs.v
:356, :366). With srst already invalidating (rondo_tile.v:152-154) and FORMAT, KAT and MBIST blocked while OPEN,
nothing else can reset the active layer during an open sequence. No change in rondo_tile is needed.

Change
* rtl/chip/rondo_regs.v, case 8'h18 (:374-377):
      8'h18: begin
          if (active) err_new[E_BUSY_WR] = 1'b1;
          else if ((TILE != 0) && tile_open) err_new[E_TILE_SEQ] = 1'b1;
          else begin pwr_core_hold <= w[0]; pwr_clk_off <= w[1]; pwr_pg_inactive <= w[2]; end
      end
  (Any write is rejected, including one that does not change the value, for the same reason as FORMAT.)
* host/rondo_host/model.py: the PWR_CTRL write path (near :545): add the same `elif self.tile_open(): TILE_SEQ`
  branch.
* host/rondo_host/device.py power_hold() (:158): if "TILE" is in caps and TILE_STATUS.OPEN, raise
  RondoError("tile sequence open: TILE_ABORT or finish it before power_hold"). Otherwise write the register, then
  check that ERR_STATUS gained no BUSY_WR or TILE_SEQ, and raise if it did.

Spec edits
* §6.1 PWR_CTRL row: "RW, blocked while ACTIVE (BUSY_WR) and while a tile sequence is OPEN (TILE_SEQ)".
* §18.6 bullet "Rejected with TILE_SEQ while OPEN": add PWR_CTRL. Add a sentence: "CORE_HOLD would reset the
  in-place accumulators of a KEEP sequence."
* §9.9: "Not allowed while a tile sequence is OPEN (finish it or TILE_ABORT first)."
* §6.5 TILE_SEQ row: no change (it already says "illegal command for the tile state").

Tests
* sim/test_chip_tile.py new `tile_pwr_ctrl_while_open` (tb_chip_tile, run_chip_tile.py), from
  build/verify/tree/sim/test_verify.py::keep_corehold, in three variants:
  (a) KEEP, fp32: between slices 0 and 1 write PWR_CTRL=1, then 0;
  (b) KEEP, bf16, PWR_CTRL=0b10;
  (c) non-KEEP TBATCH=2, fp32, PWR_CTRL=1.
  Asserts for each: the PWR_CTRL write sets TILE_SEQ; PWR_CTRL reads back 0; STATUS shows no BUSY_WR; the run
  completes with FINAL_DONE; no TILE_STALE; TZ == the untiled bare-core reference.
  Before the fix, (a) fails with tz != untiled and no error. After the fix it passes.
* host/tests/test_tile.py new `test_power_hold_refused_while_open` on the mock: open a sequence; power_hold(True)
  raises RondoError; the model's PWR_CTRL stays 0.

Accept: both new tests pass; T-TILE and the other tile tests stay green under Icarus and Verilator; chip_formal tile
and regs PASS.

---------------------------------------------------------------------------------------------------------------------

## Task 2 — B2: KAT hangs ACTIVE when its launch is refused (and the MBIST_START check)

Finding: rondo_kat.v:168-169 pulses seq_run and waits for seq_done forever. rondo_seq.v:264-265 refuses (START_BUSY)
when `!(cur_ready_q && clk_ok)` and never tells the KAT. rondo_regs.v:322-343 does not refuse KAT_START while the
cores are held or clock-off.

Decision (both parts):
(a) Refuse KAT_START (START_BUSY) in rondo_regs when PWR_CTRL.CORE_HOLD or CORE_CLK_OFF is set. This is the
    host-visible rule; with MBIST=1 the refusal also happens before MBIST would run.
(b) Defensive path closing the liveness hole: rondo_seq returns a fail pulse to the KAT (the same pattern as
    tile_fail_p) and the KAT ends with KAT_FAIL instead of hanging.
MBIST_START stays ALLOWED under CORE_HOLD/CORE_CLK_OFF. rondo_mbist drives the rondo_wmem wrapper port, which is
clocked by clk_core, not by the layer ICGs; it never uses the sequencer or the layers (rondo_dev.v:509 `start` goes
straight to u_mb). A test proves it completes.

Change
* rtl/chip/rondo_regs.v, inside the start-class block (after the tile_open check at :335-337, before :338):
      if (honor_kat && (pwr_core_hold || pwr_clk_off)) begin err_new[E_START_BUSY] = 1'b1; honor_kat = 1'b0; end
* rtl/chip/rondo_seq.v:
  - new output `output reg kat_fail` (1-cycle pulse); reset 0; default-cleared each cycle next to kat_done (:219).
  - ST_IDLE refusal (:265):
        if (!(cur_ready_q && clk_ok)) begin ev_start_busy <= 1'b1; tile_fail_p <= tile_launch; kat_fail <= kat_run; end
  - ST_LAUNCH refusal (:286): add `kat_fail <= (kind == K_KAT);`.
* rtl/chip/rondo_kat.v:
  - new input `seq_fail`.
  - E_SIG (:169):
        E_SIG: if (seq_fail) begin eng_sig <= 32'd0; fail_rb <= 1'b1; es <= E_FIN; end
               else if (seq_done) begin eng_sig <= seq_sig; es <= E_FIN; end
    (eng_pass becomes false, so the controller raises ev_kat_fail and ST_STATUS records the failure; the KAT ends.)
* rtl/chip/rondo_dev.v: wire `kat_fail_w` from u_seq `.kat_fail(...)` to u_kat `.seq_fail(...)` (g_kat). In g_nokat
  nothing is needed.
* host: model.py refuses KAT_START with START_BUSY when PWR_CTRL[1:0] != 0. device.py kat() (:297): read PWR_CTRL
  first; if bits [1:0] are not 0, raise RondoError("KAT needs PWR_CTRL.CORE_HOLD = CORE_CLK_OFF = 0").

Spec edits
* §6.3 KAT_START row: "...; refused with START_BUSY while PWR_CTRL.CORE_HOLD or CORE_CLK_OFF = 1".
  MBIST_START row: "allowed with CORE_HOLD/CORE_CLK_OFF (MBIST does not use the layers)".
* §6.5 START_BUSY row: add "or KAT_START while CORE_HOLD/CORE_CLK_OFF".
* §9.8 and §9.9: one sentence each, the same rule.
* §10.2 or §10.1: "A refused KAT launch returns a fail to rondo_kat, which finishes with KAT_FAIL."

Tests
* sim/test_chip_kat.py new `kat_refused_when_core_off` (tb_chip_vs_core, KAT=1), from test_verify.py::kat_with_clk_off.
  For PWR_CTRL ∈ {0b01, 0b10, 0b11}: KAT_START → within 200 cycles ACTIVE=0, ERR has START_BUSY, ST_STATUS.RUNNING=0,
  WSTALE/LOAD_CRC unchanged (no load happened); then PWR_CTRL=0, KAT_START passes as usual.
  Before the fix: ACTIVE stays 1 after 60k cycles, so the test fails.
* sim/test_chip_mbist.py new `mbist_with_core_off` (MBIST=1 build): PWR_CTRL=0b11; MBIST_START completes
  (MBIST_STATUS.DONE, no FAIL, ACTIVE drops). Then KAT_START with PWR_CTRL=0b01 is refused and MBIST_STATUS is
  unchanged (MBIST did not start). Passes before for the first half; the second half fails before (MBIST runs and
  then the KAT hangs).
* formal/seq_f.v (seq path (b), not reachable from the pins after (a)): add
      reg kr_q, ref_q; always @(posedge clk) begin kr_q <= kat_run; ref_q <= !( (fmt_applied?core_rst_n[1]:core_rst_n[0]) ... ) end
  More simply, assert: "if kat_run is high in IDLE and no layer_start follows in the next cycle, then kat_fail pulses
  in the next cycle". Implement it with a one-cycle history register in the harness. Connect the new kat_fail output.
  The seq BMC must PASS; a mutant without the kat_fail assignment must FAIL (run once by hand; record it in the log).
* host/tests/test_model.py new `test_kat_refused_with_power_ctrl` (mock): kat() raises; the raw KAT_START sets
  START_BUSY.

Accept: new tests pass in both simulators; T-KAT (SMALL), and T-KAT FULL under --slow, unchanged (signatures
unchanged: rondo_kat_sigs.vh is not regenerated); seq BMC PASS.

---------------------------------------------------------------------------------------------------------------------

## Task 3 — B4: Rondo.set_clock sends a frame at the old SCLK; make the transports model the link rate

Finding: device.py:111-116 writes CLK_CFG (applied at the end of that frame, rondo_regs.v:280-282) and then reads
CHIP_ID before _set_sclk(), at R = f_core_new/f_SCLK_old (down to 1.25). The transports ignore the rate
(cocotb_transport.py:34-36; the MockTransport/model does not check R).

Change (host/rondo_host/device.py)
* set_clock(div, src):
      want = (div & 3) | ((src == "clk_alt") << 4)
      f_new = f_src_of(src) / (1 << div)
      hz_safe = spi_grid_floor(min(self.f_core, f_new) / 8.0, ...) capped by max_hz   # valid under the old AND new clock
      self.set_reg("CLK_CFG", want)               # frame at the current SCLK (old clock): legal
      self.sclk_hz = self.t.set_speed(hz_safe)    # BEFORE any further frame
      v = self.reg("CLK_CFG")                     # read the applied value at the safe rate
      div_a, src_a = (v >> 16) & 3, (v >> 20) & 1
      if (div_a, src_a) != (div & 3, src == "clk_alt") and not self._fpga_no_div(v): raise RondoError(...)
      self.div = div_a; self.f_core = f_src_of(src_a) / (1 << div_a); self._set_sclk()
  - `f_src_of`: new constructor argument `f_clk_alt=None` (defaults to f_clk).
  - FPGA: genesys2_pi_top has no rondo_clkdiv, so DIV_APPLIED reads 0 (see task 13). Do not raise in that case:
    f_core then follows the applied value (DIV has no effect), which is correct.
  - Call _wait_idle() at the top of set_clock: a CLK_CFG write while ACTIVE is rejected.
* set_format(): unchanged apart from the call (set_clock now does the right thing).

Change (transports)
* host/rondo_host/cocotb_transport.py CocotbTransport.__init__(bfm, hz=None, f_src_hz=None, dut=None, min_r=8.0):
  - set_speed(hz): if f_src_hz is set, call bfm.set_ratio(f_src_hz / hz) (the ratio is in testbench source-clock
    periods, sim/rondo_spi_bfm.py:31) and return hz. Otherwise keep today's behavior (fixed ratio).
  - xfer(): if dut is given and f_src_hz is set, read the applied divider from the RTL (the rondo_chip_top clkdiv
    div_applied net, e.g. dut.u_clkdiv.div_applied or the existing DIV_APPLIED source; find the hierarchical name in
    rondo_chip_top.v). Compute R_core = bfm.ratio / 2**div. If R_core < min_r, raise
    AssertionError(f"SPI frame at R={R_core:.2f} < {min_r}").
* host/rondo_host/transport.py MockTransport / model.py RondoModel.xfer(tx, hz): add `strict_rate=True` (a model
  constructor argument). If hz > f_core_applied/8, raise LinkRateError (a new RondoError subclass in transport.py).
  f_core_applied is the model's f_core after _finish_frame. Tests that need the R=6 corner exist only on RTL, so
  strict_rate=True as the default is fine. If an existing pytest breaks, fix the test, not the check.

Spec edits
* §14.3: "After writing CLK_CFG the host lowers SCLK to ≤ min(f_old, f_new)/8 before the next frame, reads
  CLK_CFG.DIV_APPLIED/SRC_APPLIED, then sets SCLK from the applied value."
* §14.5 set_clock line: same, one line.

Tests
* host/tests/test_model.py new `test_set_clock_rate` (mock, f_clk 50 MHz, max_hz 5 MHz): set_clock(div=3), then
  set_clock(div=1), then set_clock(0); set_format("fp32") with fp32_div=1. No LinkRateError, and r.sclk_hz ≤
  f_core/8 after each call. Before the fix, set_clock(div=3) raises LinkRateError on the CHIP_ID read.
* sim/test_chip_host.py new `host_set_clock_rate`: CocotbTransport(bfm, f_src_hz=50e6, dut=dut, min_r=8);
  Rondo(..., f_clk=50e6, max_hz=50e6/8); reset_check; set_clock(3); reg("SCRATCH") write/read; set_clock(0);
  infer() bit-exact as in the existing host test. Before the fix: an AssertionError from the transport (R=1.25).
  The other host tests keep their explicit ratios (construct CocotbTransport without f_src_hz) so their run time
  does not change.

Accept: the new tests pass; T-HOST, T-SUITE (sim) and pytest stay green.

---------------------------------------------------------------------------------------------------------------------

## Task 4 — B3 + elaboration checks (§7.1, §10.1, §18.5) + lint variants

B3 decision: REJECT TILE with ACCSIG_BF16 ≠ 8 by an elaboration check. Reasons:
(1) The author fixed ACCSIG_BF16 = 8 (Q5), and §18.7 says wide layers run in fp32. The combination is not on the
    chip, so making it work adds RTL and verification for a build nobody tapes out.
(2) Making it work touches rondo_ps (L half in bf16 when AW_BF16 > 16), rondo_layers (pack AW_BF16 bits into {H,L}),
    rondo_dev (wd_masked must use AW for PS writes, not W), the host PS swap, the model and the fpmodel tile vectors,
    plus a new T-TILE variant: about 60–80 lines of RTL plus tests, and a new path in the PS store mux.
(3) The bug class is "silently wrong". A loud elaboration error removes it completely.
The alternative is listed as author decision D3.

Change
* rtl/chip/rondo_dev.v: pass `.AW_BF16(8 + ACCSIG_BF16)` to rondo_regs (TILE_GEOM is then honest in every build).
* rtl/chip/rondo_dev.v: add a generate block of elaboration checks, using SystemVerilog elaboration system tasks
  (bare `$fatal` inside a generate-if, not inside `initial`, so that `verilator --lint-only`, iverilog and yosys all
  reject at elaboration):
      generate
        if ((NPAR & (NPAR - 1)) != 0)            begin : e_npar  $fatal(1, "rondo_dev: NPAR must be a power of two (spec 7.1)"); end
        if (LNW + WAW + FW > 23)                 begin : e_wmap  $fatal(1, "rondo_dev: LNW+WAW+FW > 23 (spec 7.1)"); end
        if ((LAYER == 0) && (LNW + BAW + FW > 16)) begin : e_bmap  $fatal(1, "rondo_dev: LNW+BAW+FW > 16 (spec 7.1)"); end
        if (XPW + XW > 16)                       begin : e_xmap  $fatal(1, "rondo_dev: clog2(NXBUF)+XW > 16 (spec 7.1)"); end
        if ((TRACE != 0) && (2 * TRACE_DEPTH > 65536)) begin : e_trc $fatal(1, "rondo_dev: 2*TRACE_DEPTH > 65536 (spec 7.1)"); end
        if ((LAYER == 0) && (CKSUM_PAR == 0) && !(NGROUP * PDIM > WIDTH + 8))
                                                 begin : e_ck    $fatal(1, "rondo_dev: NGROUP*PDIM <= WIDTH+8 needs CKSUM_PAR=1 (spec 10.1)"); end
        if ((TILE_P != 0) && (TILE_B > 0) && (FW + BAW + LNW + TBW > 16)) begin : e_ps $fatal(1, "rondo_dev: PS region offset > 16 bits (spec 18.5)"); end
        if ((TILE_P != 0) && (TBW + XW > 16 || TBW + ZJW > 16)) begin : e_txz $fatal(1, "rondo_dev: TX/TZ region offset > 16 bits (spec 18.5)"); end
        if ((TILE_P != 0) && (HAS_BF16 != 0) && (ACCSIG_BF16 != 8)) begin : e_b3 $fatal(1, "rondo_dev: TILE=1 needs ACCSIG_BF16=8 (bf16 PS store is 16 bits); build with TILE=0 (spec 18.3)"); end
        if ((HAS_FP32 != 0) && (LAYER == 0) && (TBITS_FP32 != 8) && (TBITS_FP32 != 12)) begin : e_tb $fatal(1, "rondo_dev: TBITS_FP32 must be 8 or 12 (seed files)"); end
        if ((HAS_FP32 != 0) && (LAYER == 0) && (NR_ITERS_FP32 < 1 || NR_ITERS_FP32 > 2)) begin : e_nr $fatal(1, "rondo_dev: NR_ITERS_FP32 must be 1 or 2"); end
      endgenerate
  The TBITS check matters: rondo_layers.v:150 silently picks the t8 seed file for any TBITS other than 12.
  - Convert rondo_trace.v:122 (`initial if ... $fatal`) to the same generate form.
  - Tool check: confirm each tool rejects a bad build (the negative variants below). If a tool ignores elaboration
    tasks, also add the `initial` form inside the same generate-if and note it in the log. Expect: Verilator 5.052,
    Icarus 13 and recent Yosys support elaboration system tasks.
  - TILE with NBATCHES ≠ 1 keeps today's behavior (TILE_P = 0, CAPS.TILE = 0); this is documented, not fatal (see
    the spec edits).
* scripts/chip_lint.sh:
  - New clean variants: `accsig24 -GACCSIG_BF16=24 -GTILE=0`, `tile_b0 -GTILE_B=0`.
  - New EXPECTED-FAIL variants (a function `run_expect_fail name msg params...`: pass only if verilator exits
    non-zero AND the log contains msg): `accsig24_tile -GACCSIG_BF16=24` → "TILE=1 needs ACCSIG_BF16=8";
    `npar6 -GNPAR=6` → "NPAR must be a power of two"; `tbits10 -GTBITS_FP32=10` → "TBITS_FP32 must be 8 or 12".
  - Fix any real warnings the two new clean variants show (TILE_B=0 has not been linted before).
* scripts/chip_synth.sh: no change. Add an iverilog negative check to chip_lint.sh as well: compile rondo_dev with
  -P...NPAR=6; it must fail. One yosys negative check: `yosys -p "read_verilog -sv ...; chparam -set NPAR 6 rondo_dev; hierarchy -top rondo_dev"`
  must fail.

Spec edits
* §7.1 elaboration checks: list the full set above. Change the §18.5 elaboration line to "the PS/TX/TZ region offsets
  fit in 16 bits (FW+BAW+LNW+clog2(TILE_B) ≤ 16, clog2(TILE_B)+XW ≤ 16, clog2(TILE_B)+clog2(WIDTH) ≤ 16)". The
  implementation decodes addr[15:0] under bases 0x04/05/06; the old "≤ 17" was wrong.
* §10.1: "elaboration error (set CKSUM_PAR=1)" instead of "force CKSUM_PAR=1".
* §18.3: "TILE requires ACCSIG_BF16 = 8 (elaboration error otherwise)". §18.1 constraint: "TILE is ignored
  (CAPS.TILE = 0) when NBATCHES ≠ 1."
* §13.13 table: ACCSIG_BF16 default 24 → 8 (stale since Q5).
* §15.4 T-LINT: list the new variants and the expected-fail variants.

Tests: the expected-fail lint variants are the B3 test. Before the change `accsig24_tile` lints with 2 WIDTHEXPAND
warnings instead of the fatal message, so it fails as an expected-fail variant. `accsig24` (TILE=0) and `tile_b0`
must be clean.

Accept: chip_lint.sh all variants as specified; all chip runners unchanged; TILE_GEOM reads 0x00201008 at FULL
default (AW_FP32 32, AW_BF16 16, TILE_B 8) — unchanged.

---------------------------------------------------------------------------------------------------------------------

## Task 5 — F1: make the spi_ctrl formal job non-vacuous and label BMC honestly

Finding: formal/spi_ctrl.sby "prove" is `mode bmc depth 64` at GAPN 8 (one byte per 9 cycles). The write path,
second read word, DCRC error and frame end after byte 7 are unreachable within 64 steps, so the write assertions
in spi_ctrl_f.v:93-107 are vacuous. The cover task uses a different harness (-DGAPN=6), and cover mode does not
check assertions.

Soundness note for the abstraction: in spi_ctrl_f.v:17-25, rx_valid is allowed only when `gap == GAPN`, i.e. bytes
are at least GAPN+1 cycles apart. The real PHY delivers one byte per 8 SCLK periods = 8·R ≥ 48 core cycles (R ≥ 6
verified corner). Any GAPN ≤ 47 is therefore an over-approximation of the real PHY: a smaller GAPN admits strictly
more behaviors, so a property that holds at GAPN=g holds for every real spacing ≥ g+1. Lowering GAPN is sound and
shortens the depth needed.

Change, stage A (mandatory)
* formal/spi_ctrl.sby: tasks `bmc`, `cover`, `mutant`. All use the SAME define set, -DGAPN=4 (or the smallest GAPN
  ≥ 2 at which the assertions still hold; record the value and the reason in the file header).
      bmc:    mode bmc,   depth 160
      cover:  mode cover, depth 160
      mutant: mode bmc,   depth 160, adds -DSPI_F_MUTANT, expected FAIL
  Depth 160 at GAPN 4 (5 cycles/byte) covers a CRC-on header (7 bytes) + 3 data words with CRC (15 bytes) + response
  latency, about 120 cycles. Raise it if covers report a step > 150.
* formal/spi_ctrl_f.v:
  - Covers (all must be reached at step ≤ the bmc depth):
    second AND third write word issued with CRC on and off; DCRC reject (`err_crc` after a data word);
    HCRC reject; N+1-th read request; frame end after ≥ 2 data words; mid-word abort with err_frame.
    The cover for `crc_mode` must be split per value; use an (* anyconst *) value with cover terms per mode.
  - `ifdef SPI_F_MUTANT`: `always @* if (!init && issue) assert (!(rb_req_we && reqs == 17'd1));`. This deliberately
    false assertion proves the write path is checked: the mutant task must FAIL.
* scripts/chip_formal.sh:
  - Read `mode` per task from the .sby (`awk` on "<task>: mode X" or a plain "mode X" line). Print
    "FORMAL spi_ctrl/bmc (BMC depth 160, bounded): PASS" or "FORMAL regs/prove (k-induction): PASS". Never print
    "prove" for a bmc task.
  - Default task lists per job are read from the .sby [tasks] section, not hard-coded (regs: prove cover;
    spi_ctrl: bmc cover mutant; others: bmc cover).
  - A task named `mutant` (or any task listed in an `# expect-fail: <task>` header line) passes only if sby reports
    FAIL.
  - For cover tasks, parse "Reached cover statement ... in step N" and fail if any N > that job's bmc depth (proves
    the bmc horizon covers the behaviors).

Change, stage B (attempt, timebox 1 day): real k-induction for spi_ctrl
* Add formal-only observation outputs to rondo_spi_ctrl under `ifdef RONDO_FORMAL_OBS` (ports appended at the end,
  absent in synthesis/simulation builds): mode, bi, wpos, rem, ntot, the read-pipeline state, the outstanding flag.
  rondo_spi_slave is unchanged (the define is off).
* In spi_ctrl_f.v (with -DRONDO_FORMAL_OBS), add helper invariants linking the reference parse (bi, wb, reqs,
  words_done, hdr_ok) to the DUT state (bi == dut bi while in frame; wpos == wb; reqs + rem == ntot; outstanding
  consistent).
* Reduce state for induction: in the prove task, `assume (nn < 4)` (burst ≤ 4 words) and narrow reqs/words_done to
  3 bits. The address-increment and N+1 properties are per-word and do not depend on N. State this restriction in
  the .sby header.
* If `mode prove` (depth ≤ 48) passes: add task `prove` and keep `bmc` as well. If not: drop stage B, record why in
  CHIP_IMPL_LOG, and keep the honest BMC labels.

Spec edits
* §15.3 table: spi_ctrl "bmc depth 160 at a sound byte-spacing abstraction (GAPN ≤ 47) + cover + vacuity mutant"
  (or "prove (k-induction, bursts ≤ 4)" if stage B succeeds). seq / dev_bus / tile: "bmc" with their depths as built.
  Add the rule: "chip_formal.sh labels each task by its sby mode; every bmc job has a cover task in the same
  configuration whose covers are reached within the bmc depth, and the write-path assertions have a mutant task that
  must fail."

Test (fails before / passes after): the `mutant` task. On the current harness (depth 64, GAPN 8) the false
assertion PASSES; that is the vacuity, confirmed by the verifier's fcov run, so the mutant check "fails" before.
After the change the mutant FAILS as required, and chip_formal.sh reports it as PASS (expected fail).

Accept: chip_formal.sh all jobs PASS with honest labels; every cover reached within the bmc depth; the mutant
detected; run time of the spi_ctrl job recorded (target < 30 min).

---------------------------------------------------------------------------------------------------------------------

## Task 6 — B6: layer core_rst_n driven by a flop (spec §3.4)

Finding: rondo_seq.v:161 `assign core_rst_n[f] = test_mode ? rst_n : (ls[f] == L_RUN);` is a combinational decode
on an asynchronous reset net. The SYNCASYNCNET waiver on rondo_seq.v hides it.

Change (rtl/chip/rondo_seq.v)
* Add `reg [1:0] run_q;` (one flop per layer, async-reset to 0 by rst_n) in the g_ly always block. It is set in
  exactly the transitions that enter L_RUN and cleared in the transitions that leave it:
      L_CLK: ... else if (lt[f] == 2'd0) begin ls[f] <= L_RUN; lrdy[f] <= 2'd2; run_q[f] <= 1'b1; end
      L_RUN: if (!want[f]) begin ls[f] <= L_RST; ...; run_q[f] <= 1'b0; end
      default: begin ls[f] <= L_OFF; run_q[f] <= 1'b0; end
  run_q[f] == (ls[f] == L_RUN) in every cycle (identical timing, no extra latency). Write it as `run_q[f]` inside
  the per-f generate block with a per-f always, or as a separate `reg run_q_f` in g_ly[f].
* `assign core_rst_n[f] = test_mode ? rst_n : run_q[f];` (the test-mode mux is the §11.7 DFT bypass and stays.)
* The synchronous consumers of core_rst_n inside rondo_seq (:250 `!core_rst_n[fmt_applied]`) use the state
  instead: `(ls[fmt_applied] != L_RUN)` (equal in functional mode; in test_mode the old code used rst_n, which is 1
  during operation). This keeps the async net out of synchronous logic.
* Add `assert (run_q[f] == (ls[f] == L_RUN))` to rtl/chip/sva/rondo_sva_seq.v (or the seq harness) as an invariant.
* sim/chip_waivers.vlt: remove `lint_off -rule SYNCASYNCNET -file "*rondo_seq.v"`. If Verilator still flags
  run_q→mux→core, re-add the waiver with -match on that signal only and the justification "flop output feeding the
  layers' async reset through the §11.7 test-mode mux".

Spec edits: none (the RTL now matches §3.4). Optionally mention the test-mode mux in §3.4.

Test (fails before / passes after): new scripts/chip_struct.sh, called from chip_lint.sh. Yosys on rondo_seq alone:
    read_verilog -sv rtl/chip/rondo_seq.v rtl/chip/rondo_cksum.v; hierarchy -top rondo_seq; proc; opt; wreduce; opt_clean
    select -assert-none w:core_rst_n %ci*:-$adff,$dff,$adffe,$dffe t:$eq t:$ne t:$logic_not t:$logic_and t:$logic_or t:$and t:$or t:$not t:$reduce_and t:$reduce_or %u %i
(the input cone of core_rst_n back to the flops may contain only the $mux of the test-mode bypass). Before the change
the cone contains the $eq of the ls decode, so the check fails. Adjust the select expression until it fails on the
.pre_fix copy and passes on the new one, and record both runs.

Accept: chip_struct.sh passes; T-SEQ, T-FMT, T-SCAN and T-CLK unchanged; seq/dev_bus formal PASS; KAT signatures
unchanged.

---------------------------------------------------------------------------------------------------------------------

## Task 7 — B5: CAPS LAYER field and HAS_BIAS

Decision: the RTL follows the spec. §6.2 defines [3:2] as a 2-bit LAYER value (0 CoFrNet, 1 KAN), which extends
naturally; the RTL's "bit 3 = KAN" is the anomaly. KAN is not on the first chip, so the change costs nothing.

Change
* rtl/chip/rondo_regs.v:88-90: replace the `1'b1, b1(LAYER != 0), 1'b0` portion (bits 4,3,2) with
  `b1(LAYER == 0), 2'(LAYER)`, i.e. bit 4 HAS_BIAS = (LAYER==0), bits [3:2] = LAYER[1:0]. Default build: unchanged
  (CAPS bits 4:2 = 3'b100).
* host/rondo_host/regmap.py:69: remove "LAYER0"/"LAYER1" from CAPS_BITS; add `CAPS_LAYER_SHIFT = 2, CAPS_LAYER_MASK = 3`
  and a helper `caps_layer(v)`. device.reset_check stores `self.layer = R.caps_layer(caps)`. model.py builds CAPS the
  same way (LAYER field; HAS_BIAS only for LAYER 0). grep host/ and sim/ for LAYER0/LAYER1 and update every user.

Spec: none (§6.2 already says this).

Tests
* sim/test_chip_kan.py:83: replace `"LAYER1" in caps` with `caps_layer(v) == 1 and "HAS_BIAS" not in caps`. This
  fails before (field reads 2, HAS_BIAS 1) and passes after.
* sim/test_chip_regs.py:23: the default CAPS expectation is unchanged; add `caps_layer == 0`.
* host/tests: a mock test with a KAN model (layer=1): CAPS field = 1, no HAS_BIAS.

Accept: T-KAN, T-REG and pytest pass; regs formal PASS (CAPS is an RO constant there).

---------------------------------------------------------------------------------------------------------------------

## Task 8 — B7: disabled lane keeps stale z when a start arrives in the done cycle (core, LANE_MASK only)

Finding: rtl/core/fused_coproc_pipe.v:284-286 (L_FIN arm). On `start && !busy_r` with the lane disabled, the lane
goes to L_IDLE without writing qNaN (the qNaN write is only in L_IDLE, :253-259).

Change (backup fused_coproc_pipe.v.pre_fix; additive and gated):
      L_FIN: if (start && !busy_r && (!LANE_MASK || lane_en[l])) begin
                 bat <= '0; rcnt <= '0; lstate <= L_GEN;
             end else if (LANE_MASK && start && !busy_r) begin       // C6+C1: disabled lane started from L_FIN
                 for (qi = 0; qi < NBATCHES*NSLOT; qi = qi + 1) zl[qi] <= QNAN;
                 lstate <= L_IDLE;
             end else if (!busy_r) lstate <= L_IDLE;
With LANE_MASK = 0 (core default) the new branch is constant-false and the logic is identical. In L_FIN rcnt is at
its final value, so the zl write cannot collide with the ln_ovalid write at :248-250.

Spec edit: §2.7 add "this also holds for a start taken in the done cycle (C1) while the lane is in L_FIN".

Tests
* sim/test_core_c6.py (tb_core_c6.v, LANE_MASK=1) new `c6_start_in_done_disabled`: inference 1 with the lane
  enabled, then `start` in the done cycle (C1 path) with lane_en[l]=0. Assert: that lane's z == qNaN for all its
  ladders; the enabled lanes equal the model. Both formats. Fails before (stale z), passes after.
* T-EQ (task 0.3) and chip_regress_old (T-OLD) under both simulators: the default-parameter core is unchanged.

Accept: T-C6 (old and new cases), T-C1, T-EQ 0 mismatches, T-OLD both simulators.

---------------------------------------------------------------------------------------------------------------------

## Task 9 — robustness: rbus arbiter and soft reset, soft-reset clears (§9.6)

9.1 Arbiter and slave across soft reset (rondo_rbus_arb.v, rondo_dev.v, rondo_wpack.v)
Rule enforced: every request the slave accepted gets exactly one response, also across srst (§8.2 rule 4).
Internal-master requests not yet accepted are cancelled by srst.
* rondo_rbus_arb.v: new input `srst`.
  - A_IDLE: do not grant k_/m_ masters while srst (the external master can still win; the slave holds it with
    o_req_ready = 0).
  - A_REQ: `if ((own != OWN_E) && (srst || !cur_valid)) st <= A_IDLE; else if (o_req_ready) st <= A_RSP;` where
    cur_valid = (own==OWN_K) ? k_req_valid : m_req_valid.
  - `assign o_req_valid = req_phase && ((own == OWN_E) ? e_req_valid : cur_valid);`
* rondo_dev.v:566 `if (srst) begin ds <= D_IDLE; o_rsp_valid <= 1'b0; end` becomes:
  - D_IDLE stays idle (o_req_ready already includes !srst);
  - D_WAITRD → D_FIN with r_data = 0, r_err = 1 (the wpack read is aborted, see below);
  - D_EXEC, D_WAITM, D_WAITPS, D_FIN and D_RSP proceed normally; each is bounded to ≤ 4 cycles.
  The `if (srst)` therefore becomes a guard only on D_WAITRD, inside the case.
* rondo_wpack.v (flush_staging = srst, :108): also `c_valid <= 1'b0; rs <= R_IDLE;`. This implements §9.6 "cache"
  and makes the D_WAITRD abort safe: no late rd_valid reaches a later access.
* Wire `.srst(srst)` into u_arb (rondo_dev.v:533).
* rondo_kat keeps dropping valid on srst (rondo_kat.v:113-114); with the arbiter change that is now safe.
* SVA: if rtl/chip/sva/rondo_sva_rbus.v checks the arbiter→slave (o_*) side for "valid held until transfer", exempt
  srst cycles for internal owners. Otherwise no change.

9.2 Soft reset clears the 64-bit read shadows (rondo_regs.v:401-403)
* Add `shd[0] <= 0; shd[1] <= 0; shd[2] <= 0; shd[3] <= 0;` to the `if (srst)` block.

Spec edits: §8.2 add rule 6: "an accepted request is always answered, also across soft reset; a soft reset cancels
internal-master requests not yet accepted; an internal read cut by soft reset answers 0 with rsp_err". §8.3 note the
measured latency (task 14). §9.6: no change (the RTL now matches: staging/cache, shadows).

Tests
* sim/test_chip_regs.py new `soft_reset_clears_shadows` (CNT_INIT = 2^32−50, as T-REG): wait until INFER/TOTAL_CYC HI
  is ≠ 0, read TOTAL_CYC_LO (shadow = HI ≠ 0), SOFT_RST, wait idle, read TOTAL_CYC_HI alone: expect 0 (no LO read
  since the reset). Fails before (stale HI).
* sim/test_chip_pack.py new `soft_reset_invalidates_read_cache`: read a weight element (cache filled), SOFT_RST,
  check `dut.u_dev.u_pk.c_valid == 0` (a hierarchical read; it works under both simulators). Fails before.
* sim/test_chip_seq.py (tb_chip_vs_core, rbus BFM) new `soft_reset_backpressure`: write CTRL.SOFT_RST with
  rb_rsp_ready held 0 for 8 cycles after the request is accepted. Expect exactly one response, then 20 random
  register reads complete. Fails before: the response is dropped and the arbiter sticks in A_RSP, so the next access
  times out.
* sim/test_chip_kat.py new `soft_reset_during_kat`: 30 trials with KAT_START, then SOFT_RST after a random 50..5000
  cycles, with random rsp_ready backpressure on the external port. A cocotb monitor on `u_dev.u_arb` asserts that no
  internal request (o_req_int = 1) is accepted after the first srst cycle until the next KAT_START. After each trial
  a register read/write sequence works. Before the fix this is expected to show the stray internal access in at
  least one trial; if it does not reproduce, keep it as a regression test and note in the log that it passed before.

Accept: the new tests pass in both simulators; T-SVA negative tests still fire; dev_bus formal PASS (check that the
abstract harness still meets its 10/24-cycle bounds).

---------------------------------------------------------------------------------------------------------------------

## Task 10 — dead code and narrow UNUSEDSIGNAL/UNUSEDPARAM waivers (§15.4)

* Delete the dead declarations the verifier listed (after tasks 1–9, so line numbers have settled):
  rondo_dev: the wp_* nets that are only declared (wp_en, wp_we, wp_bias, wp_lane, wp_addr, wp_half, wp_wd_h, wp_wd_l),
    dummy4, ps_b_w, ev_trc_done_r, mem_rd_val. Connect the unused u_mem outputs `.wp_denied()`/`.ce_l_any()` as
    explicit empty pins if nothing reads them (PINCONNECTEMPTY is already waived for rondo_dev) or keep them for the
    SVA if a checker uses them: grep sim/ and sva/ first.
  rondo_seq: xcur, accept_ok. rondo_regs: `integer ci`, any_start_bit. rondo_trace: trig_stored.
  rondo_tile / rondo_spi_ctrl: srst_d (and `pb` wherever it is). rondo_chip_top: miso_r, miso_oe_r.
* sim/chip_waivers.vlt: delete `lint_off -rule UNUSEDSIGNAL -file "*rtl/chip/*.v"` and the same UNUSEDPARAM line.
  Re-run every chip_lint.sh variant. For each remaining warning, either delete the code or add an inline
  `/* verilator lint_off UNUSEDSIGNAL */ ... /* verilator lint_on UNUSEDSIGNAL */` around that one declaration with
  a one-line justification (e.g. "address bits above the geometry", "port used only when TILE=1"). Alternatively use a
  waiver-file entry `lint_off -rule UNUSEDSIGNAL -file "*rondo_dev.v" -match "*'q_addr'*"`. No file-wide UNUSED*
  waiver may remain for rtl/chip. The core-file waivers stay as they are (core edits are restricted to §2).
* Test: chip_lint.sh is clean for all variants with the narrowed waivers. Add a grep check to chip_lint.sh that
  fails if chip_waivers.vlt contains `UNUSED.*rtl/chip/\*`.

Accept: lint clean; full new-chip regression green (no functional change).

---------------------------------------------------------------------------------------------------------------------

## Task 11 — run_chip_suite vector generation does not depend on sys.executable

* sim/run_chip_suite.py:10-12: choose the interpreter in this order: env RONDO_PY, then
  ROOT/.venv-rtl/bin/python if it exists, then sys.executable. Before calling, check
  `subprocess.run([py, "-c", "import numpy"])` and fail with a clear message ("gen_vectors.py needs numpy: set
  RONDO_PY or create .venv-rtl"). Remove the no-op `.replace("python", "python")`. Also regenerate when
  scripts/gen_vectors.py or host/rondo_host/suite/cases.py is newer than the npz.
* scripts/chip_regress_new.py: before the runners, run `PY scripts/gen_vectors.py small` once (and `full` with
  --slow), so the suite never relies on lazy generation; report "gen_vectors: PASS/FAIL".
* Test: copy the tree to build/fix/clean_tree (rsync excluding build/vectors and sim_build*; the copy has no
  .venv-rtl), run `RONDO_PY=$PY $PY sim/run_chip_suite.py` from it: it must PASS. Before: FAIL (numpy missing or no
  vectors). Also run once without RONDO_PY to see the clear error message.

---------------------------------------------------------------------------------------------------------------------

## Task 12 — run_wide_layer re-reads TZ TBATCH times per sub-batch

* host/rondo_host/device.py:488-489:
      zz = tz(len(idx))
      for b, i in enumerate(idx):
          Z[i, lo:hi] = np.array(zz[b][:n], dtype=np.uint64)
* Test: host/tests/test_tile.py new `test_wide_layer_tz_reads_once`: wrap MockTransport to count READ frames whose
  address lies in the TZ region (0x050000..0x05FFFF). For G groups, ceil(N/TILE_B) sub-batches and nb inputs each,
  expect exactly sum(nb) TZ read bursts (one per input; more if split_burst splits them, so compute the expected
  number with protocol.split_burst). Fails before (TBATCH× too many).
* Accept: pytest; T-WIDE (run_chip_host host_wide) bit-exact and faster.

---------------------------------------------------------------------------------------------------------------------

## Task 13 — undocumented deviations: decide spec vs RTL

| deviation | decision | change |
|---|---|---|
| KAT_START with MBIST=1 runs MBIST first (rondo_kat.v:209) | spec follows RTL: MBIST=0 by default, KAT overwrites the weights anyway, and running MBIST first gives a stronger register-triggered self-test; ST_STATUS.MBIST_PASS is meaningful | §9.8 bullet 1: "with MBIST=1, MBIST runs first"; §6.3 KAT_START row |
| trace SRC 1 "SPI frame start" bit tied 0 (rondo_dev.v:444) | spec follows RTL: the event word already carries frame_end and every rbus accept; adding frame_start needs a new rondo_dev port through every testbench, the formal harness and the FPGA top, for a debug nicety | §11.3 SRC 1: list the actual bit layout {[25] SPI frame end, [21:18] xptr, [17] busy, [16] done, … [15:0] addr}; frame start reserved 0 |
| FPGA top without rondo_clkdiv (DIV no effect, DIV_APPLIED = 0) | spec follows RTL: one bitstream per format (Q8) at a closed 100 MHz, so no per-format division is needed on the FPGA; a BUFGCE divider would need generated-clock constraints for no benefit. The host now derives f_core from DIV_APPLIED (task 3), so this is safe | §13.25: "rondo_clkdiv is not instantiated; CLK_CFG.DIV is accepted and ignored, DIV_APPLIED reads 0" |
| MBIST covers neither the PS store nor TX/TZ (≈ 164 kbit) | AUTHOR DECISION D1 (below); interim: document the gap and add the zero-area host march (13.1) | §11.6 coverage paragraph |

13.1 (recommended, part of D1, zero silicon cost) Host-side memory test over SPI: `Rondo.mem_test(regions=("PS", "TX"))`
runs March C− (the same element order as §11.6, backgrounds 0/1 and 5/A) over every mapped PS element and TX word
through the memory map (both are RW when not ACTIVE). It checks the format width (bf16 16-bit / fp32 32-bit PS
elements) and returns failures as (region, b, lane, group, field, xor). TZ is RO from the host: it is covered
functionally by the T-SUITE tiled case and T-TILE. Cost: FULL ≈ 10 × (3,584 PS + 320 TX) word accesses ≈ 39k words
≈ 0.3 s at 5 MHz. Unmapped PS rows (g = 7 of 8) are never used and stay untested (state this).
Test: run_chip_tile / tb_chip_tile with RONDO_FAULT_INJECT: a stuck bit in one rondo_ps H macro and in the TX SRAM
must be reported with the right lane/address; a clean run reports none; also a mock test.

---------------------------------------------------------------------------------------------------------------------

## Task 14 — spec updates from the verifier's §7 judgment (S items)

Edit docs/CHIP_INTERFACE_SPEC.md and change the header to v2.1.1 (2026-11-xx: "fix round, CHIP_FIX_PLAN"):
* §5.2 / §13.6-13.7: LOOPBACK and STATUS byte paths live in rondo_spi_phy; in a STATUS frame MISO byte 0 = 0x00 and
  STATUS8 is returned from byte 1 on.
* §8.3: slave response ≤ 4 cycles for registers/XBUF; uncached WEIGHT/BIAS reads up to 8 cycles (SVA bound 10); the
  24-cycle external bound is unchanged (measured max 11 for registers). Include the soft-reset rule from task 9.
* §11.5: LFSR "advance then use": each element uses the state after one Galois step. Measured KAT duration ≈ 9k
  cycles/format at SMALL. The relaxed f_ref cross-check in gen_kat_sig.py (ill-conditioned ladders excluded) →
  author decision D4.
* §11.6: lanes are tested serially (≈ 8× the parallel time); coverage per task 13.
* §13.25: RONDO_FPGA / RONDO_FPGA_BUFGCE ICG variants; four observation outputs on rondo_dev; FORMATS=3 does not
  fit the XC7K325T; no clkdiv.
* §18.3/§13.26: the PS store is module rondo_ps (not inside rondo_wmem); the tile FSM is rondo_tile (not inside
  rondo_seq); region offsets addr[15:0] (with the §18.5 elaboration fix).
* §18.5: TILE_SEQ_CRC restarts at every slice-0 TILE_RUN in HOST_SLICE mode (it covers the last slice-0 run
  onwards); a host PS write is tagged TILE_SLICE−1 at write time, so the host sets TILE_SLICE before writing PS.
* §18.6: TILE_SLICE is cleared when a sequence closes or aborts. A TILE_RUN refused by the sequencer (layer not
  ready) sets START_BUSY and, as the sequence is invalidated, TILE_STALE (keep; documented). PWR_CTRL rule (task 1).
* §15.3, §15.4, §7.1, §10.1, §6.3, §6.5, §9.8, §9.9, §2.7, §14.3, §14.5: as listed in tasks 1–8.
* §16.4: add D1–D4 as open questions if the author has not answered them yet.

---------------------------------------------------------------------------------------------------------------------

## Task 15 — VERSION (author decision D2; recommended: bump to 0x00020101)

The fixes change host-visible behavior: PWR_CTRL and KAT_START refusals, soft-reset shadow clears, KAN CAPS, and
the rbus response across soft reset. Bitstreams and simulations before and after must be distinguishable.
* rtl/chip/rondo_regs.v:174 → `localparam [31:0] VERSION_V = 32'h00020101;` used at :174.
* host/rondo_host/regmap.py:5 VERSION_VALUE = 0x00020101. sim/test_chip_regs.py:21 and host/tests/test_model.py:43
  compare against R.VERSION_VALUE instead of the literal. device.reset_check warns (does not fail) if VERSION <
  0x00020101 ("pre-fix wrapper: PWR_CTRL/KAT refusal rules absent").
* Spec §6.1 (0x00020101 → v2.1.1), §9.1 step 5, header.
If the author declines, skip this task; nothing else depends on it.

---------------------------------------------------------------------------------------------------------------------

## Task 16 — documentation

* docs/CHIP_IMPL_LOG.md: a "Fix round" section with one entry per task: files, the before-fail evidence, after-pass
  evidence, decisions.
* docs/CHIP_VERIFY_REPORT.md: do not edit (the verifier's record). Optionally append "Response: see CHIP_FIX_PLAN.md"
  in the impl log instead.

---------------------------------------------------------------------------------------------------------------------

## Interface changes for the verification plan (docs/CHIP_VERIF_PLAN.md, the formal/UVM agent)

* rondo_seq: new output `kat_fail` (1-cycle pulse on a refused KAT launch, in IDLE or LAUNCH). core_rst_n is now
  `test_mode ? rst_n : run_q[f]` (a flop, same cycle timing as before). The fmt_applied follow-up uses ls, not
  core_rst_n.
* rondo_kat: new input `seq_fail`; E_SIG ends with KAT_FAIL on it.
* rondo_regs: PWR_CTRL write while tile_open → TILE_SEQ (no change); KAT_START with pwr_core_hold|pwr_clk_off →
  START_BUSY; srst clears shd[0..3]; AW_BF16 now passed (8+ACCSIG_BF16); CAPS[4]=HAS_BIAS=(LAYER==0) and
  CAPS[3:2]=LAYER; VERSION possibly 0x00020101.
  Suggested properties for regs.sby (already a real proof): no cmd_kat_start while pwr_core_hold|pwr_clk_off;
  PWR_CTRL unchanged by a write while tile_open; shadows 0 after srst.
* rondo_rbus_arb: new input `srst`. Internal (KAT/MBIST) requests are cancelled in A_REQ on srst or when the
  master's valid drops, so o_req_valid may fall without a handshake for internal owners. The external side is
  unchanged.
* rondo_dev: an accepted request is answered also across srst (rule 4 across soft reset); an internal weight read cut
  by srst answers 0 with rsp_err. Elaboration $fatal checks reject the parameter sets in task 4 (UVM/xsim builds must
  use legal parameters; TILE=1 requires ACCSIG_BF16=8).
* rondo_wpack: flush_staging (srst) also clears the read cache and resets the read FSM.
* fused_coproc_pipe (LANE_MASK=1 only): a disabled lane started from L_FIN (start in the done cycle) writes qNaN.
* rondo_spi_ctrl: optional formal-only observation ports under `ifdef RONDO_FORMAL_OBS` (only if F1 stage B is
  attempted); synthesis and simulation are unaffected.
* Liveness and safety properties now worth checking: "kat_run refused ⇒ kat_fail next cycle" (added to seq_f.v by
  task 2); "while a tile sequence is OPEN with KEEP, the active layer's core_rst_n stays 1 unless srst" (B1
  invariant, needs the tile + regs + seq composition).
* Host: CocotbTransport(bfm, hz=None, f_src_hz=None, dut=None, min_r=8.0) with a rate model and a strict R check;
  RondoModel(strict_rate=True) raises LinkRateError on R < 8; regmap CAPS layer field helper; Rondo.mem_test (if D1
  is accepted).
* Scripts: chip_formal.sh labels tasks by sby mode and supports expected-fail `mutant` tasks; chip_lint.sh has
  expected-fail variants and calls chip_struct.sh; chip_regress_old.py runs core_eq; chip_regress_new.py runs
  gen_vectors first.

---------------------------------------------------------------------------------------------------------------------

## Final regression checklist (run after the last task; save logs to build/fix/final/)

    cd /home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI-main
    PY=$PWD/.venv-rtl/bin/python
    $PY scripts/chip_regress_old.py icarus                      # T-OLD + run_core_c1..c8 + core_eq + explicit WL_* jobs
    $PY scripts/chip_regress_old.py verilator                   # known: 12 WL_* env skips + 3 Verilator baseline fails; re-run train_* alone if they flake
    $PY scripts/chip_regress_new.py icarus                      # 18 runners incl. the new tests in tile/kat/mbist/regs/pack/seq/host/core
    $PY scripts/chip_regress_new.py verilator --slow            # + full, kat_full (signatures unchanged), cofrgenet, gls
    scripts/chip_lint.sh                                        # all clean variants clean; expected-fail variants fail with their message; chip_struct.sh passes
    scripts/chip_formal.sh                                      # regs prove; spi_ctrl bmc/cover/mutant(expected FAIL) [+prove if stage B]; spi_phy, seq, dev_bus, tile bmc+cover; honest labels
    scripts/chip_synth.sh small                                 # rc 0, check -assert, exactly 3 $_DLATCH_N_ (ICGs); cell count within ±1% of 632,622 (report the delta)
    (cd host && ../.venv-rtl/bin/python -m pytest -q tests)     # 34 old + new host tests
    SIM=icarus $PY sim/run_core_eq.py; SIM=verilator $PY sim/run_core_eq.py   # 150 inferences, 0 mismatches
    md5sum -c build/fix/md5_before.txt                          # protected files and .pre_chip backups untouched

Pass criteria: everything above green (with the documented known exceptions only); every new test recorded as
FAIL-before / PASS-after in CHIP_IMPL_LOG; KAT signature constants unchanged; default-parameter core equivalence
0 mismatches.

---------------------------------------------------------------------------------------------------------------------

## Author decisions needed (with recommendations)

* D1 — MBIST coverage of PS/TX/TZ (≈ 164 kbit). Options:
  (a) document the gap and add the zero-area host-side March over SPI for PS and TX (task 13.1), with TZ covered
      functionally;
  (b) extend rondo_mbist to PS (16 macros 64×128 at FULL) and TX/TZ (2 × 16 kbit) through new wrapper-port muxes on
      rondo_ps / rondo_tbuf, gated by a new parameter MBIST_TILE. Cost (est.): ≈ 5 kGE (address/data muxes on 18
      SRAM ports + FSM states), ≈ +25k cycles (≈ 0.5 ms at 50 MHz), and a mux on the SRAM address timing paths;
  (c) fold PS into the unused rows of 512-deep weight macros (§18.9) and extend the existing weight MBIST address
      range (≈ free if the macros are 512 deep).
  Recommendation: (a) now. Choose between (b) and (c) only when Q7 (MBIST vs the foundry macro BIST) and the macro
  depth are known. MBIST is 0 by default, so (b) has no effect on the default chip anyway.
* D2 — VERSION bump. Recommendation: bump to 0x00020101 (v2.1.1), because the host-visible rules change (task 15).
* D3 — B3 alternative. Recommendation: keep the elaboration error (TILE requires ACCSIG_BF16 = 8). Make the
  wide-accumulator bf16 build tile only if the author wants ACCSIG_BF16 = 24 builds to tile in bf16 (≈ 60–80 RTL
  lines + a T-TILE variant; zero area at defaults).
* D4 — KAT f_ref acceptance: gen_kat_sig.py excludes ill-conditioned ladders (the raw criterion gave max_rel 2.9e-3 >
  1e-3 on random KAT data; RTL == bit-exact model is unaffected). Recommendation: approve the relaxed criterion and
  write it into §11.5. The KAT's purpose is silicon ≡ RTL; RTL ≡ math is established by T-FULL / T-C7 on real
  coefficients.
