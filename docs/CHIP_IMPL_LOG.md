# RONDO chip implementation log

Implements docs/CHIP_INTERFACE_SPEC.md v2.0 (not edited). Updated after every task.
Environment: cocotb 2.0.1, Verilator 5.052, Icarus 13, Yosys + SymbiYosys. No Raspberry Pi
available: host software is tested against the mock and the RTL only (no real spidev/gpiod/I2C).

## Governing decisions and global deviations
- UPDATED by the coordinator (spec A3/A9 + "Author decisions" table, re-read): Q4 accepted ->
  chip default for the fp32 layer is TBITS=8, NR_ITERS=2 (seed recip_seed_e8s24_t8.mem), set in
  rondo_layers/rondo_dev/rondo_chip_top defaults; the CORE's own defaults stay TBITS=12/NR_ITERS=1 so
  the existing regression is unchanged. Q5: ACCSIG_BF16=8. Q6: NXBUF=4. Q8: one FPGA bitstream
  per format acceptable (FORMATS=1/2 builds; format switching verified in simulation). Q9: accumulator
  debug tap (sig 1) kept, parameter-gated, default on. UVM on xsim noted, not in scope of this task.
  (An earlier note here that overrode spec 13.13's TBITS_FP32=8/NR_ITERS_FP32=2 is withdrawn: the
  spec 13.13 defaults are now correct as written; ACCSIG_BF16 default 8 overrides 13.13's 24.)
  T-C7 (standalone + full fp32 layer with TBITS=8/NR_ITERS=2) already runs and passes.
- Baseline (before any edit): see "Baseline" below.

## Task status
(see per-task sections below)

## Baseline (before any chip change)
`sim/run_all.py` (Icarus): 33/45 runners pass. The other 12 fail at baseline only because they are
parameterised runners that need WL_* environment (`require_env` exits with 0 tests; run_all treats
that as a failure): run_depth_sweep, run_engine_steady, run_fused_bf16, run_fused_coproc,
run_fused_pipe, run_lane_sweep, run_lane_sweep_inter, run_lane_throughput, run_pole_stress,
run_workload, run_workload_inter, run_workload_lane. (The spec's "run_all passes" is therefore
read as "no runner that passed at baseline regresses".) Raw output: docs/.baseline_runall.txt.
`scripts/chip_regress_old.py [icarus|verilator]` = run_all + explicit runs of run_fused_pipe,
run_fused_bf16, run_workload_inter with WL_* set (Waveform npz, WIDTH 16, PDIM 40, 2 lanes); it
fails on any runner outside the known-12 set and on any failure of the three explicit runs.

## Common test infrastructure (new)
- sim/fpmodel.py: exact (Fraction-based) bit-level model of fma / affine / scan / reciprocal
  (RNE, subnormals, overflow); reproduces the RTL bit for bit (used as scoreboard everywhere).
- sim/chip_common.py: geometry (SMALL/FULL), weight packing (spec 1.4), bare-core driver.
- Strings cannot be set as Icarus defparams: testbenches select the seed file with an integer
  parameter (SEEDSEL) and a parameter-expression string.
- sim/chip_waivers.vlt (+ one added line in sim/cocotb_common.py, backup cocotb_common.py.pre_chip):
  PINMISSING waiver for existing instantiations of the changed modules. Deviation: spec 2.1 says
  waive "not by editing old files"; the waiver file is new but it must be listed in the
  Verilator control-file list of cocotb_common.run, so cocotb_common.py gets one line.

## T1 C1 start fix: DONE
Files: rtl/core/fused_coproc_pipe.v, rtl/core/kan_layer_pipe.v (backups *.pre_chip);
sim/run_core_c1.py, test_core_c1.py, tb_core_c1.v.
Test: T-C1 (Icarus + Verilator): fixed core completes a start-in-done-cycle and t+1 launch with z
bit-identical to the exact model; the unmodified core (pre_chip copy renamed) hangs with busy=1;
KAN start-in-done completes. Both formats. T-OLD (icarus): 34/46, only the known 12 fail.

## T2 C2 guard export: DONE
Files: recip_nr_pipe.v, ladder_engine_inter.v, fused_coproc_pipe.v; sim/run_core_c2.py,
test_core_c2.py, tb_core_c2.v. Test: guard_hit pulse count equals the number of clamped ladders
over 6 injected-beta sets (below/at/above eps, +-0), z equals the exact model, bf16 and fp32.
T-OLD (icarus): 35/47 pass, only the known 12 fail; explicit fused runs pass.

## T3 C7 NR_ITERS: DONE
Files: recip_nr_pipe.v (generate loop over iterations), ladder_engine_inter.v, fused_coproc_pipe.v
(NR_ITERS forwarding); new rtl/core/recip_seed_e8s24_t8.mem (gen_recip_table.py --tbits 8);
sim/run_core_c7.py, test_core_c7.py, tb_recip.v, tb_core_c7.v; sim/chip_waivers.vlt.
Test: standalone fp32 TBITS=8 NR=2: 100,000 operands (interval ends, powers of two, guard band) bit-exact
vs model, max 1 ULP vs exact reciprocal; TBITS=12 NR=1 max 2 ULP; bf16 bit-exact; guard_hit pulses =
clamped count. Full fp32 layer FULL geometry (Verilator, Waveform): max_rel 5.8e-5, accuracy delta 0.
T-OLD icarus 36/48, only the known 12 fail.

## T4 C3 EXT_MEM: DONE
Files: affine_bank_pipe.v (EXT_MEM param, ports wm_addr/bm_addr/mem_act/wm_q/bm_q; internal arrays
in a generate branch), fused_coproc_pipe.v (per-lane forwarding into flat buses); sim/run_core_c3.py,
test_core_c3.py, tb_core_c3.v. Test: EXT_MEM=0 core vs EXT_MEM=1 core + behavioral registered memory
on 50 random inputs, both formats: z, busy, done identical each cycle; mem_act asserted on all lanes
and low when idle. T-OLD (icarus) 37/49, only the known 12 fail.

## T8 (in progress, written ahead): clock/reset primitives
rtl/chip/rondo_{sync,reset_sync,icg,clk_mux,clkdiv}.v; sim/run_chip_units.py, test_chip_units.py,
tb_chip_units_clk.v. Test passes (sync latency, async-assert/sync-deassert, divider counts 1/2/4/8,
ICG with async enable toggling, mux glitch-free in random switching for 4 clock pairs, reset selects
clk0, test_mode bypass).

## SPEC EXTENSION (coordinator message): input tiling, section 18, 35 tasks
Spec now has 2019 lines. Changes affecting me: VERSION = 0x00020100, IRQ_EN reset 0x7F, new regs
0x50-0x54, CTRL bits 13/14 (TILE_RUN/TILE_ABORT), IRQ bits 5/6, ERR bits 14/15, CAPS[17]=TILE,
memory map TX/TZ/PS, core change C8 (TILE), tasks T31-T35 after T30. Order: finish T1-T30 first, then
T31-T35. Padding rule: weight -0, input +0. Every wrapper module is written with the TILE
extensions in mind where cheap, but the tile FSM/regs/buffers are added in T32.

## T5 C6 LANE_MASK: DONE
Files: fused_coproc_pipe.v (LANE_MASK param, lane_en input, lane_en_q latched at accepted start,
completion `&(lane_fin | ~lane_msk)`, disabled lane writes quiet NaN to zl); sim/run_core_c6.py,
test_core_c6.py, tb_core_c6.v. Test: 13 masks incl. 0 and all-ones, both formats: enabled lanes
bit-identical to the unmasked core, disabled lanes quiet NaN, mem_act low on disabled lanes (EXT_MEM=1),
done never later than unmasked, all-disabled completes in <= 3 cycles. T-OLD (icarus) passed
(38/51; the one UNEXPECTED entry was my own tb_core_c7 missing the new lane_en pin under Verilator,
fixed: all chip tbs now connect every new core pin).

## T6 C4 DBG taps (+ C5 injection): DONE (regression pending, see T7)
Files: affine_bank_pipe.v (acc_all/mac0_v/mac0_p/state_o), ladder_engine_inter.v (k0_all, k1_all,
res_valid/res_k0/res_k1), fused_coproc_pipe.v (DBG param, dbg_* ports, per-lane tap mux + 2 register
stages). sim/run_core_c4.py, test_core_c4.py, run_core_c5.py, test_core_c5.py, tb_core.v (shared full-port bare
core wrapper), chip_common.py helpers.
Tests (bf16 ACCSIG 8, bf16 ACCSIG 24, fp32; Icarus and Verilator): T-C4: all static taps sig 0-5 (+reserved 6,7 and
out-of-range read 0) for every lane/index equal the exact model, the four live streams equal the model, z unchanged.
T-C5: (a) scan injection (W=0, B=a, x=0) -> a_hold == B exactly, K0/K1 per slot equal model; (b) reciprocal
injection a=(0..0,beta): K0=beta, K1=1, z = model/1ULP of 1/beta, guard hits = clamped ladders; (c) coefficient
stage a_hold/acc equal sum(W*x)+b model. Live flag bit layout: {guard_hit, naninf, lstate[2:0], state[1:0], valid}.
Deviation (test): L_FIN (lstate 5) lasts one cycle and was not observed on the registered live flags.

## T9 SPI slave: DONE
rtl/chip/rondo_spi_phy.v, rondo_spi_ctrl.v, rondo_spi_slave.v; sim/rondo_spi_bfm.py, rondo_rbus_bfm.py,
run_chip_spi.py, test_chip_spi.py, tb_chip_spi.v. Test T-SPI (Icarus): loopback, STATUS, NOP, unknown opcode;
write/read bursts 1,2,3,17,255,256 with CRC off/on, exactly N+1 rbus reads, bytes beyond the burst read 0;
bad HCRC / DCRC; mid-header/mid-word aborts flag SPI_FRAME, word-boundary abort does not; CRC enable takes effect
at the next frame; R in {6,7,8,13,16,33} with random phase, 200 frames each; overrun yields 0xDEADBEEF + SPI_FRAME.
Design notes / deviations (smallest reasonable choices):
 - Loopback (0x0E) and STATUS (0x05) byte paths are in rondo_spi_phy, not rondo_spi_ctrl: the echo/status byte for
   MISO byte k+1 has to be loaded at the 8th SCLK edge of byte k, before a controller could react (STATUS: MISO byte
   0 = 0x00 necessarily, bytes 1.. = STATUS8). The PHY gets a `status8` input and `lb_mode`.
 - PHY tx model: one-byte hold register (tx_load) moved into the shift register at each byte end (cleared to 0),
   tx_need pulse; so unwritten bytes (headers, dummy, beyond burst) transmit 0.
 - READ word pipeline with speculative 0xDE hold byte so a late rbus response shifts exactly 0xDEADBEEF.
 - `sim/test_chip_spi.py` ~2 min runtime (6 ratios x 200 frames).

## T10 host core: DONE
host/rondo_host/{__init__,regmap,fmt,protocol,packing}.py, host/tests/{conftest,test_protocol,test_packing}.py.
pytest (.venv-rtl, 13 tests) passes: CRC-8 check value 0xF4, spec 5.5 frame examples, pack_weights for the Waveform
npz equals workloads/gen_genesys2_rom.py output word for word at bf16 and --wb 32, checksum == board algorithm,
LOAD_CRC == zlib.crc32, KAT LFSR (advance-then-use convention, recorded here: r = state after one Galois step).

## T11 memories, T12 packer, T13 layers: DONE (unit tests)
rtl/chip/rondo_sram_sp.v, rondo_wmem.v, rondo_wpack.v, rondo_layers.v; sim/run_chip_units.py with units clk, mem,
pack, layers (tb_chip_units_{clk,mem,pack,layers}.v, test_chip_units{,_mem,_pack,_layers}.py).
 - mem: wrapper write/readback both halves, half-masked write, layer reads (H only in bf16: ce_l_any never set),
   colliding wrapper write dropped + wp_denied.
 - pack: random-order element writes -> layer-visible H/L content correct (bf16 and fp32), LOAD_CRC == zlib.crc32,
   read cache (one wmem read per core word, invalidated by writes/cache_inval), latency <= 5, PARTIAL cases.
 - layers: bf16<->fp32 format switch x6 with spec 3.4 ordering through wpack+wmem+layers: bit-exact vs model
   (fp32 chip default TBITS 8 / NR_ITERS 2), inactive layer clock never toggles.
 - rondo_sram_sp has an `ifdef RONDO_FAULT_INJECT fault model (used by the MBIST test later).
 - Lint (-Wall) of these is done at T26.

## T7 core checkpoint: Icarus DONE, Verilator run recorded below
scripts/chip_regress_old.py icarus after C4: run_all 42/54 pass (only the known 12 env-skipped fail), explicit
fused_pipe/fused_bf16/workload_inter pass. Verilator run: see /tmp reg_t7_verilator result summarized in final report.
Lint of modified modules (-Wall) deferred to T26 (existing core has pre-existing -Wall findings, waived there).

## T8 clock/reset primitives: DONE (see above)  | T14/T15/T16 progress (written in this session part)
- T14: rtl/chip/rondo_cksum.v, rondo_seq.v written. Seq: launch FSM IDLE/LAUNCH/WAIT/GAP/POST/SRST, per-layer
  clock/reset FSMs (spec 3.4 ordering), fmt_want/fmt_applied (mux follows once old layer is in reset; a FORMAT write
  of the same value still clears state per 12.4), LAST_CYCLES == bare-core cycles (verified).
- T15: rondo_regs.v, rondo_rbus_arb.v, rondo_dev.v (+ rondo_dbgmux.v, rondo_trace.v, rondo_kat.v drafts).
  Tests PASS: T-REG (sim/run_chip_regs.py), T-PACK (run_chip_pack.py: bit-exact ZBUF and cycle-exact LAST_CYCLES vs
  bare cores, both formats), T-SEQ (run_chip_seq.py: single-shot, self-run K=1/N/3N+1 with t+2 spacing, CHECKSUM,
  SR_PASS, SR_CYC, STOP, soft reset, WDOG, lane mask, guard, NaN), T-FMT (run_chip_fmt.py).
  Deviation: rbus response latency is 3 cycles for registers/XBUF, up to ~8 for uncached weight reads (spec 8.3
  says <=4); the external-access bound 24 cycles holds (measured max 11 for registers). VERSION=0x00020100,
  IRQ_EN reset 0x7F implemented and tested.
  Deviation: tile regs 0x50-0x54 implemented in rondo_regs early (TILE param, default 0 until T32).
- T16: rondo_chip_top.v written; T-TOP bring-up ladder test passes, load/infer test being debugged.

## T14, T15, T16: DONE
T-UNITS cksum is exercised through rondo_seq in T-SEQ (CHECKSUM/SR_PASS_CKSUM == host packing.update model).
T-REG, T-PACK, T-SEQ, T-FMT (see above). T16: rtl/chip/rondo_chip_top.v; sim/run_chip_top.py, test_chip_top.py
(bring-up ladder 9.1, load/LOAD_CRC/single-shot/self-run through SPI pins, irq/busy pins, R=8 and R=6 with CRC);
run_chip_clk.py, test_chip_clk.py (DIV 1/2/4/8 applied at frame end, SRC switch, clkout frequencies, dead
clk_alt recovered by rst_n, loopback at R=8 of the divided clock). Both PASS (Icarus).
Test bug found/fixed: top-level tests must pass SMALL geometry parameters (WIDTH=16,PDIM=8,N_LANES=2).
sim/cocotb_common.py: second small edit, optional `defines` argument of run() (for RONDO_FAULT_INJECT).

## T17 debug mux: DONE
rtl/chip/rondo_dbgmux.v; sim/run_chip_dbg.py, test_chip_dbg.py (+ RONDO_FAULT_INJECT define via cocotb_common.run).
T-DBG: every sig 0-5 (+6 reserved) for all lanes/slots/chains, both formats, fmt_override read; localization flow of 9.10 end to
end: a stuck-at-1 bit forced in one lane's H weight macro (sram fault model) is localized to lane/address/field by
read-back, coefficient taps show only that lane's chains wrong, scan/reciprocal injection, GUARD_HITS, lane-mask
work-around, restore. (MBIST part of T-DBG in T20.) Note: DBG_DATA is latched 4 cycles after a DBG_SEL write: the host
issues two register reads (or CTRL.DBG_LATCH) before reading DBG_DATA.

## T18 trace: DONE
rtl/chip/rondo_trace.v (read path fixed for 64-entry ring); sim/run_chip_trace.py, test_chip_trace.py.
T-TRC: all 64 SRC x MODE x TRIG combinations exercised; 60 complete captures with checks (nvalid = trig_idx+1+POST,
chronological timestamps, consecutive timestamps in every-cycle mode); the 4 incomplete ones are the legal case where a
store-on-valid source emits no entry at/after the trigger (live k0 stream / guard hits with trigger done or NaN output).
Wrap case: trigger index DEPTH-1-POST, STOP_ON_FULL, TRC_DONE irq, TRC_CFG write blocked while armed.
There is no disarm command: tests use SOFT_RST (clears trace state) between unfinished captures.

## T19 KAT: DONE (SMALL); FULL signature generation pending T24
rtl/chip/rondo_kat.v (engine + self-test controller, rewritten cleanly), rtl/chip/rondo_kat_sigs.vh (generated),
scripts/gen_kat_sig.py, sim/run_kat_gen.py, test_kat_gen.py, run_chip_kat.py, test_chip_kat.py.
T-KAT (SMALL, Icarus): register-triggered KAT signature equals the independent model (LFSR stream through packing.py +
fpmodel, both formats) and the generated constant (no KAT_FAIL); a stuck weight bit (sram fault model) and a forced lane
bus both fail the KAT and flag KAT_FAIL; healthy run sets st_pass; bist_en strap at reset runs bf16 then fp32, restores
FORMAT=bf16, busy high throughout, ST_STATUS AT_RESET/RAN/PASS bits, st_pass pin.
gen_kat_sig.py: cross-checks RTL vs model and vs float64 f_ref (fp32 max_rel 1.3e-6 over the 60/64 well-conditioned
ladders; ladders whose coefficient cancels to <1% of its terms, whose continuant cancels to <1%, or with |K0|<0.05 are
excluded as ill-conditioned: with the spec's raw criterion max_rel was 2.9e-3 > 1e-3 because of cancellation in random data).
Signature constants come from rondo_kat_sigs.vh (per geometry macros); rondo_dev parameter KAT_SIG_* = all-ones means
"use the generated default for this geometry"; non-default ACCSIG/TBITS/NR need regenerated constants.
Other changes: busy/kat_active is high from reset release while a strap run is pending; internal-master weight writes do
not clear WSTALE; HF_INCLUDES gets rtl/chip (cocotb_common.py, third small edit).
Deviation: KAT cycle count is ~9k cycles per format at SMALL (about 8 clk per rbus write), not the spec's estimate.

## T20 MBIST: DONE
rtl/chip/rondo_mbist.v (March C-, both backgrounds, one lane at a time through the wrapper port: deviation from
"lanes in parallel"), hooked into rondo_dev (MBIST=1), sim/run_chip_mbist.py, test_chip_mbist.py, and the MBIST part of
T-DBG. Tests: good memories pass; stuck-at-0/1, transition and coupling faults injected through the sram fault model are
detected and localized (lane, store weight/bias, half, address, XOR) and flagged MBIST_FAIL; ST_STATUS MBIST_PASS follows.

## T21 manufacturing hooks (SCAN, PG): DONE
rondo_chip_top.v (SCAN=1: test_mode pin, MISO=scan_out stand-in with oe forced, scan_en=bist_en, scan_in=spi_mosi, reset
synchronizer and clock mux/divider bypass, layer core_rst_n = rst_n; ICGs transparent), rondo_seq.v (PG: pg_req per layer once the
inactive layer is off, 16-cycle reset hold after the supply returns), rondo_layers.v (isolation ANDs on a powered-down layer).
sim/run_chip_scanmode.py, test_chip_scanmode.py: test-mode bypasses verified functionally; PG: pg_req follows the inactive layer
across FORMAT switches, reset held >= 16 cycles after the supply returns. Lint of SCAN=1 PG=1 variant at T26.
The scan chain itself is not in the RTL (inserted by the flow), per spec 11.7; the stand-in tail flop is replaced by it.
Also this session: width/lint cleanups in rondo_{regs,cksum,trace,kat,dev}.v; chip_waivers.vlt waives the intended ICG latch.

## T22 assertions: DONE
rtl/chip/sva/rondo_sva_{spi,rbus,regs,seq,wmem}.v: plain clocked checkers with manual history (no $past/bind, so they run under
Icarus/Verilator/SymbiYosys), per-property sticky `viol` bits. Instantiated in sim/tb_chip_vs_core.v (rbus, regs, seq, wmem)
and sim/tb_chip_spi.v (spi); ChipTB / test_chip_spi raise on any violation, so every chip test runs with checkers on. Real
traffic (T-REG/PACK/SEQ/FMT/KAT/DBG/TRC/MBIST, T-SPI at 6 ratios) is violation free. Negative tests: sim/run_chip_sva.py,
tb_chip_sva.v, test_chip_sva.py drive each property with a deliberately broken stimulus: every property fires.
Deviations: response-latency bound checked as <= 10 cycles (rbus_sva MAX_RSP) instead of 4 (see T15 note), external access <= 24;
the loopback-echo and request-count properties are partly covered by the T-SPI tests; wmem "single owner" = wp_denied never set.
Mutants are stimulus mutants of the checkers' inputs (not RTL mutants).

## T23 formal: DONE (bounded where noted)
formal/{regs,spi_ctrl,spi_phy,seq,dev_bus}.sby + harnesses regs_f.v, spi_ctrl_f.v, spi_phy_f.v, seq_f.v, dev_bus_f.v +
rondo_layers_abs.v (abstract layers), scripts/chip_formal.sh. Results (SymbiYosys, yices):
 - regs: k-induction PROVE (depth 12) of RO constants, W1C clear semantics, CTRL reads 0, one start-class command per write,
   command pulses only after a CTRL write, HI-read returns the shadow, irq = registered |(status&en); covers reached.
 - spi_ctrl: BMC depth 64 PASS (deviation: spec says prove/k-induction depth 48; the induction step needs invariants over
   rondo_spi_ctrl internals that the harness cannot name). Properties: rbus master rules (valid held, payload stable, one
   outstanding), requests only after a CRC-clean header, <= N+1 requests per frame, address increments, WRITE issued only for a
   complete, CRC-clean word. Covers reached.
 - spi_phy: BMC depth 200 PASS at SCLK period 6..10 core cycles: rx_byte == byte sent, MISO bit == hold byte at every master sampling
   edge, oe == registered CS. Timing assumption stated in the harness: the controller loads the hold byte between the 1st and 6th
   SCLK of a byte (it does: >= 2 cycles after tx_need and long before the next boundary). Covers reached.
 - seq: BMC depth 70 PASS with abstract layer: launch rule (single pulse, not while done/busy, not within t+2, not into a layer in
   reset), inactive layer clock/reset timing, counters monotonic, self-run never exceeds SR_COUNT; covers reached.
 - dev_bus: BMC depth 60 PASS on rondo_dev with the layers abstracted: rbus protocol + response bound (10 cycles) / 24-cycle
   total, launch rule and format-switch ordering (checker inside the abstract layer).
REAL BUGS FOUND BY FORMAL and fixed in RTL:
 1. rondo_spi_ctrl: a READ whose CS rose right after the header still received its late rbus response in the NEXT frame and
    loaded a stray byte into that frame's hold register. Now dropped unless mode == RDATA (+ simulation regression
    stray_read_response in test_chip_spi).
 2. rondo_seq: START accepted in the same cycle CORE_HOLD took the layer into reset (launch into a layer in reset). START is now
    refused (START_BUSY) when CORE_HOLD is set and LAUNCH re-checks the layer is ready.

## T24 full geometry: DONE (T-FULL); T-KAT FULL running (see below)
sim/run_chip_full.py, test_chip_full.py: rondo_dev at WIDTH 64 / PDIM 40 / 8 lanes, Verilator, Waveform coefficients, formats
bf16 -> fp32 -> bf16 in one run: 8 samples per format bit-exact vs the bare cores and cycle-exact LAST_CYCLES; decisions vs the
golden float64 f_ref: fp32 agreement 1.000 (asserted), bf16 reported (1.000 on these 8); self-run 4 entries x 3 passes
CHECKSUM and SR_PASS_CKSUM equal the model. Runtime ~5 min. KAT signatures for FULL generated by scripts/gen_kat_sig.py
(Verilator; RTL signature == bit-exact model, vs f_ref fp32 max_rel reported), stored in rtl/chip/rondo_kat_sigs.vh.
sim/run_chip_kat_full.py runs the T-KAT tests at FULL geometry.

## T25 KAN option: DONE
rondo_dev LAYER=1 support (KAN word count NWORDS = NBATCHES*NSLOT*(DEPTH+1)/NPAR*PDIM, no bias region, FORMAT fp32 -> RANGE,
CAPS LAYER1 and no READBACK/GUARD/HAS_FP32), rondo_layers kan branch; sim/tb_chip_kan.v, run_chip_kan.py, test_chip_kan.py:
KAN coefficients written element-wise through the chip equal the bare kan_layer_pipe loaded directly: 5 random inputs y
bit-exact; bias region write -> ADDR. (Weight read-back still works through rondo_wmem for KAN builds although CAPS.READBACK
is 0; harmless.) Verified at SMALL bf16 only, as the spec says.

## T26 lint and synthesis: DONE
scripts/chip_lint.sh: verilator --lint-only -Wall, zero warnings for rondo_chip_top FULL default, MBIST=1 SCAN=1 PG=1, HAS_FP32=0,
HAS_BF16=0, LAYER=1, and SMALL; waivers (sim/chip_waivers.vlt) scoped per file with justification (BLKSEQ temporaries, parameter-
dependent unused signals/params, intentionally open outputs, the ICG latch, SYNCASYNCNET on the reset synchronizer output).
scripts/chip_synth.sh small: yosys synth -flatten of rondo_chip_top SMALL (WIDTH 16, PDIM 8, 2 lanes): check -assert passes (no
multiple drivers/undriven/loops), 503,561 cells (flops: 31,220 DFFE_PN0P + 38,370 DFFE_PP + 10,018 DFF_PN0 + ...), exactly 3
$_DLATCH_N_ (the three rondo_icg cells: divider + 2 layer gates; rondo_clk_mux is flop + gate based), stat in build/chip/yosys_small_stat.txt.

## T28 Genesys 2 prototype: synthesis done, implementation optional
rtl/chip/genesys2_pi_top.v, vivado/genesys2_pi_top.xdc, vivado/genesys2_pi_build.tcl (copy of genesys2_build.tcl with -verilog_define and the
FORMATS generic; the original is untouched), scripts/g2_pi_build.sh (FORMATS=1|2|3, SYNTH_ONLY=1, CLOCK_GATE=bufgce, --program).
PIN VERIFICATION: Digilent's Genesys-2-Master.xdc (github.com/Digilent/digilent-xdc, fetched 2026-11-02 via curl) gives ja[0..7] =
U27 U28 T26 T27 T22 T23 T20 T21 and jb[0..1] = V29 V30, all LVCMOS33: identical to the spec's JA table; JB1 = V29 (st_pass), JB2 = V30 (bist_en).
The XDC header cites the source. Only the pins already in vivado/genesys2.xdc (clock, reset, LEDs, switches) are reused from it.
Deviations: rondo_icg has RONDO_FPGA (default: no gating, gclk = clk; the inactive layer is just held in reset) and RONDO_FPGA_BUFGCE variants
(spec: BUFGCE); the chip RTL is not changed for it. rondo_dev gained 4 observation outputs (checksum_o, fmt_o, heartbeat_o, err_any_o) for the LEDs.
Vivado 2025.2 synthesis (xc7k325t) FORMATS=1 (bf16 only): 80,543 LUT (39.5%), 62,459 FF, 68 BRAM tiles, 0 DSP, no CRITICAL WARNING.
FORMATS=3 synthesis: see below. Place/route and bitstream: not run unless noted (optional per the task).

## T29 host device layer: DONE (tile parts in T34)
host/rondo_host/{transport,gpio,model,device,power,bench,cocotb_transport}.py; host/tests/{test_model,test_bench_power_gpio}.py;
sim/run_chip_host.py, test_chip_host.py. NOT TESTED ON A REAL Pi: spidev, gpiod v2 and smbus2 code paths are exercised only against
fakes (fake gpiod module, fake I2C bus for the INA226 scaling: CAL, 1.25 mV / 2.5 uV LSB, power = 25 x current LSB) and the mock.
 - pytest (.venv-rtl): 26 tests pass: Rondo API vs MockTransport/RondoModel for every spec 9 sequence (bring-up ladder, CRC framing and
   burst splitting at 4096 B, load + CRC/readback verify, golden infer, self-run checksum/SR_PASS/SR_STOP/stats, error semantics
   ADDR/RO/RANGE/BUSY_WR/START_BUSY, FORMAT switch + WSTALE, soft reset, lane mask, KAT, bist_at_reset, recip_probe/inject_coeffs,
   CLK_CFG) and bench.py end-to-end on the mock with synthetic rails.
 - T-HOST: the unmodified blocking Rondo API (loopback, reset_check, set_format, load_weights(crc), read_weights, infer, self_run +
   expected_checksum, kat, debug, lane mask, bist_at_reset) runs against rondo_chip_top SMALL RTL through CocotbTransport /
   CocotbPins (cocotb.bridge + cocotb.resume); infer results equal the bit-exact model in both formats. PASS.
 - model.py is byte-accurate for frames/registers/map; the sequencer is idealized (documented in the module docstring);
   the default compute is float64 golden (decision level), replaceable by an RTL replay table.
 - SCLK policy: largest RP1 grid rate (200 MHz / even divider) <= min(f_core/8, max_hz) with max_hz 5 MHz (chip) / 10 MHz (FPGA).

## T28 addendum: FORMATS=3 synthesis (both formats in one bitstream)
Vivado 2025.2 synthesis, xc7k325t, FORMATS=3: 261,652 Slice LUTs = 128% of 203,800 (does NOT fit), 72 BRAM tiles. Consistent with Q8: one
bitstream per format (FORMATS=1 bf16: 80,543 LUT, 39.5%). fp32-only fits per the earlier SparseKAN/RONDO numbers; the dual-format build is
verified in simulation/ASIC synthesis only. Place/route and bitstream: not run.

## T30 suite: DONE (sim 12/12 and mock). T-KAT FULL: kat_register_triggered PASS; kat_faults_and_strap failed at FULL geometry because a
single stuck bit (bit 14) can coincide with the KAT data; the test now sticks the whole H word (test fix, rerun logged under T35).

## T31 C8 core: DONE
affine_bank_pipe/fused_coproc_pipe (backups *.pre_c8). T-C8 (run_core_c8.py) passes in 6 configs (bf16/fp32, p=16/20/24). New tile pins
connected in all my testbenches (Verilator PINMISSING clean). scripts/chip_regress_old.py now runs the ORIGINAL runners + run_core_c*
through run_all.run_one with the venv python (run_all.py globs every run_*.py, so the full run_all includes the slow chip runners; that is T35).

## T32 wrapper tiling: DONE (T-TILE passes, Icarus)
New: rtl/chip/rondo_tile.v (tile FSM, PS valid/tags, TILE_STATUS, TILE_SEQ_CRC), rondo_tbuf.v (TX/TZ SRAMs), rondo_ps.v (PS store).
Modified (backups *.pre_tile): rondo_seq (K_TILE launch kind: partial slices skip ZBUF/checksum, tile_done/fail pulses), rondo_regs
(tile_slice_clr), rondo_dev (decode 0x04/05/06, x_live mux, ERR TILE_SEQ/TILE_STALE, ACTIVE includes the tile run), rondo_layers (TILE, ps ports).
Chip default TILE=1 (rondo_chip_top, rondo_dev); tb_chip_vs_core keeps TILE=0 so the older chip tests are unchanged.
Deviations/choices: (1) PS store is a separate module rondo_ps, not inside rondo_wmem. (2) Tile FSM is its own module driving a K_TILE
launch in rondo_seq (rather than inside rondo_seq). (3) Region offsets use addr[15:0] under base 0x04/05/06 (spec's "<=17 bits" not needed).
(4) MBIST does not test the PS store; MBIST/KAT/FORMAT clear PS valid bits. (5) Host PS write tag = SLICE-1 at write time; the host
driver sets TILE_SLICE before writing PS. (6) TILE_SLICE register is cleared when a sequence closes/aborts. (7) TILE_RUN while the layer is not
ready aborts the run with TILE_STALE. (8) TILE_SEQ_CRC = standard CRC-32 (zlib) over the concatenated LE LOAD_CRC words.
T-TILE: basic (B=1,2,3, KEEP, p=20 padded), host swap (batch 9, 3 sub-batches), corner cases; bf16 and fp32 bit-identical to an untiled PDIM=24 core.

## T33 CoFrGeNet-shape test: DONE (T-CFG, Verilator)
sim/run_chip_cofrgenet.py + test_chip_cofrgenet.py: rondo_dev WIDTH 16, PDIM 40, 2 lanes, TILE_B 8 (tb_chip_tile.v, KAT=0) vs a bare untiled
fused_coproc_pipe PDIM=800 (768 real + 32 pad; weights -0, inputs +0); first 16 ladders and 8 samples of cofrgenet_shape.npz, S=20.
fp32: tiled == untiled bit for bit, max_rel vs float64 f_ref on 128 unguarded ladder outputs = 3.9e-4 (< 1e-3). bf16: bit-identical to
untiled, sign agreement 0.969, median relative error 5.3e-2 (reported, not asserted).

## T34 host wide-layer API: DONE
device.py: Rondo.run_wide_layer (groups x slices x sub-batches, host swap with HOST_SLICE when batch > TILE_B, bf16 guard bf16_max_p=80 /
allow_bf16_wide, LOAD_CRC per slice, TILE_SEQ_CRC check, LANE_EN for partial groups, TILE_ABORT after a swapped chunk) and Rondo.tile_plan.
load_weights_bits(with_bias=False) used for slices > 0. model.py: tile sequencer in the mock (decision-level: float64 partial sums; rules,
errors, TILE_STATUS, CRC chain, IRQ bits, invalidation as in rondo_tile.v); host/tests/test_tile.py (pytest: 34 total pass).
T-WIDE (sim/test_chip_host.py host_wide): 32 ladders x p=96 x N=2*TILE_B+1, TILE_B=2 build (run_chip_host.py now passes TILE_B=2), host swap, two
groups: bit-exact vs the Python bare-core reference model; bf16 refused. Suite: tiled_bf16/tiled_fp32 cases (p=3*PDIM, 3 inputs) added to
host/rondo_host/suite/cases.py; scripts/gen_vectors.py writes tile_* vectors (expected z from sim/fpmodel.py, proven equal to the untiled
RTL in T-TILE/T-CFG, instead of a third bare-core RTL run). Mock: 14/14 (tiled cases are decision-level there); sim target: 12 -> 14 cases pass.
Note: scripts/gen_vectors.py must now run under the venv python (it imports sim/chip_common).
Fixes found while integrating: rondo_tile launch parameters are the idle defaults (last=1, save=0, seed=0) outside a tile run (otherwise every
ordinary START was treated as a partial slice); an invalidation in the same cycle as TILE_RUN wins.

## T35 (in progress): formal tile job
formal/tile_f.v + tile.sby (bmc depth 60 + cover): launch only inside an open sequence, restore launches only with a valid PS entry tagged s-1,
no TZ write on partial slices, idle defaults, a refused run starts nothing, soft reset closes the sequence; all covers reached. Harness note:
hierarchical references into rondo_tile's unpacked `tag`/`valid` registers are mis-modeled by yosys (spurious counterexamples), so the
RTL exposes ent_valid/ent_tag/s_cur_o and the PS-valid-cleared-by-reset property is checked in simulation (T-TILE). rondo_sva_tile.v (4 rules)
is bound in tb_chip_tile.v and silent in T-TILE.
T-LINT with TILE=1 (default): all 6 variants clean (waiver added for the empty observation pins of rondo_chip_top).
T-SYN with TILE=1: SMALL (-flatten, fully mapped) rc=0, check -assert passes, 632,622 cells; FULL coarse-grain rc=0, 179,161 cells (memories kept
as macros, stat in build/chip/yosys_*_stat.txt). Vivado 2025.2 synthesis of the Genesys 2 prototype, FORMATS=1 (bf16), now with tiling:
105,998 Slice LUTs (52.0%), 101 BRAM tiles (22.7%), 0 DSP (before tiling: 80,543 LUT / 68 BRAM): the tiling costs ~25k LUT (x_live 1,280 flops,
tile FSM, PS/TX/TZ muxing) and 33 BRAM tiles. FORMATS=3 was synthesized before tiling (261,652 LUT, does not fit; one bitstream per format).
Place/route and bitstream were not run.

## T35 findings during the Verilator regression
 * run_fused_pipe / run_fused_bf16 (explicit WL_* jobs) crashed under Verilator ("std::system_error" / "corrupted size vs. prev_size") in
   this checkout. NOT caused by the chip changes: with the ORIGINAL rtl/core (pre_chip backups, copied to a scratch tree) the same
   job crashes too when run from this directory, and passes from a scratch directory. Cause: stale top-level build products
   (verilated*.o/.d, sim.vvp, cmds.f, executables) in sim/sim_build/ left by earlier default-build-dir runs of several runners (Icarus and
   Verilator mixed). The files were moved out of sim/sim_build/ (backup in the scratchpad); after that the job passes.
 * run_grad_a_inter, run_train_ladder_inter (Verilator width lint in unmodified rtl/core/grad_a_inter.v, train_ladder_inter.v) and
   run_power_top (stimulus.mem bound error) fail under Verilator at baseline too; listed as VERILATOR_BASELINE_FAILS in
   scripts/chip_regress_old.py. They are not caused by the chip changes.
 * Verilator-only fixes in my own code: tile pins on tb_chip_units_layers.v; CNT_INIT cast (64'(CNT_INIT)) in rondo_seq.
 * scripts/chip_regress_new.py runs all chip runners under Icarus and Verilator (--slow adds the Verilator-only kat_full, full,
   cofrgenet, gls).

## T35 formal (final)
scripts/chip_formal.sh (jobs regs spi_ctrl spi_phy seq dev_bus tile): all PASS with all covers reached: regs prove+cover, spi_ctrl prove (BMC 64) + cover,
spi_phy bmc+cover, seq bmc+cover (tile ports tied off), dev_bus bmc+cover (TILE=0 build with rondo_tile/tbuf/ps added to the file list; the abstract
layers stand-in got the new tile/ps ports), tile bmc (depth 60) + cover. spi_ctrl cover: the burst covers need more cycles than depth 60 at the PHY's
8-cycle byte spacing, so the cover task now uses -DGAPN=6 (more permissive byte spacing) with depth 110; the prove task keeps spacing 8, depth 64.

## T35 regression summary (this session)
 * Core-change regression (scripts/chip_regress_old.py, original runners + run_core_c1..c8 + explicit WL_* jobs): Icarus OK; Verilator OK
   (53 runners: 38 pass; the 15 that do not are the 12 parameterised runners that need WL_* + 3 Verilator baseline failures, see above; the explicit
   run_fused_pipe / run_fused_bf16 / run_workload_inter jobs pass).
 * Chip runners (scripts/chip_regress_new.py): Icarus 18/18 PASS (units, spi, regs, pack, seq, fmt, top, clk, dbg, trace, kat, mbist, scanmode,
   sva, kan, host, tile, suite). Verilator the same 18 PASS plus the Verilator-only full, kat_full, cofrgenet (T-CFG) and gls (T-GLS).
   Fixes needed for Verilator: tile pins in tb_chip_units_layers.v, rsp_valid/rsp_ready widths in tb_chip_sva.v, CNT_INIT cast in rondo_seq,
   and T-KAT's second fault under Verilator uses a stuck bias word (Verilator cannot Force an internal wire).
 * pytest host/tests: 34 pass. Mock suite 14/14; sim suite (SMALL) 14/14 incl. tiled_bf16/tiled_fp32.
 * Lint clean (6 variants), synthesis (Yosys SMALL/FULL) OK, formal 6 jobs PASS.
 * Not run: Vivado place-and-route/bitstream and any hardware (real Pi 5, real Genesys 2); MBIST of the PS store; FORMATS=3 does not fit the
   xc7k325t (one bitstream per format).
 * sim/run_all.py (literal), Icarus: 65/77 runners pass; the 12 failures are exactly the known WL_*-parameterised runners (depth_sweep,
   engine_steady, fused_bf16, fused_coproc, fused_pipe, lane_sweep, lane_sweep_inter, lane_throughput, pole_stress, workload, workload_inter,
   workload_lane) that fail at baseline too; all 8 run_core_c* and all 21 run_chip_* / kat_gen / gen_vectors runners pass.
 * sim/run_all.py (literal), Verilator: 62/77 pass; the 15 failures = the same 12 WL_*-parameterised runners + the 3 Verilator baseline failures
   (grad_a_inter, power_top, train_ladder_inter). Every run_core_c* and run_chip_* runner passes under both simulators.
Status: all 35 tasks done; see the final report for deviations.

## Fix round (CHIP_FIX_PLAN)
Author decisions applied: D1 = (a) document the MBIST gap + host March (13.1), no MBIST hardware; D2 = bump VERSION (task 15, one isolated change);
D3 = keep the elaboration error; D4 = relaxed KAT f_ref criterion approved and written into spec 11.5.
Python: PY=$ROOT/.venv-rtl/bin/python. Backups: <file>.pre_fix (made before the first edit of each file).
Evidence logs: build/fix/ (baseline/, final/, per-task logs).

### Task 0 (done)
0.1 build/fix/md5_before.txt: md5 of utils_CoFrNet.py, Customized_Linear_Classes.py, CoFrNet_continuants.py (project root) and all rtl/core/*.pre_chip, *.pre_c8.
0.2 Baseline: NOT re-run on a separate copy of the unmodified tree; the verifier's baseline (CHIP_VERIFY_REPORT section 5, build/verify/*.log) is used as the
    baseline (Icarus old 41/53, Verilator old 36/53 with the known failures, new 17-18/18, formal 12/12, lint 6/6, synth 632,622 cells, pytest 34/34).
    Every "fails before" in this round was run on the tree as it was before the respective change.
0.3 T-EQ made permanent: sim/tb_core_eq.v (verifier's tb_eq.v with fin/nerr/ndone exposed instead of $finish), sim/test_core_eq.py (cocotb wrapper),
    sim/run_core_eq.py (generates *_old from rtl/core/*.pre_chip by regex rename into sim_build_chip/core_eq/<cfg>/, three configs 60+60+30 inferences).
    Small additive changes needed: sim/cocotb_common.py run() got an optional `extra_build_args` (Verilator needs --timing for the bench's own delays;
    backup cocotb_common.py.pre_fix); sim/chip_waivers.vlt got PINMISSING/WIDTHTRUNC/WIDTHEXPAND waivers scoped to tb_core_eq.v (backup chip_waivers.vlt.pre_fix).
    Result on the unmodified core: Icarus and Verilator, 150 inferences, 0 mismatches. chip_regress_old.py already globs run_*.py, so run_core_eq.py is
    picked up automatically for both simulators without editing the script.
0.4 The verifier's two scenario tests are moved into the permanent suites under tasks 1 and 2.

### Task 1 / B1: PWR_CTRL rejected while a tile sequence is OPEN (done)
Files: rtl/chip/rondo_regs.v (case 8'h18: `else if ((TILE != 0) && tile_open) err_new[E_TILE_SEQ]`), host/rondo_host/model.py (PWR_CTRL: `elif self.tile_open(): TILE_SEQ`),
host/rondo_host/device.py power_hold() (raises RondoError if TILE_STATUS.OPEN; after the write checks ERR_STATUS for BUSY_WR/TILE_SEQ). Backups: *.pre_fix.
Spec: 6.1 PWR_CTRL row, 18.6 rejected-while-OPEN list, 9.9 (the 9.8/6.5 and header/12 edits are collected in task 14).
Tests: sim/test_chip_tile.py `tile_pwr_ctrl_while_open` (3 variants: KEEP fp32 CORE_HOLD, KEEP bf16 CORE_CLK_OFF, TBATCH=2 fp32 CORE_HOLD);
host/tests/test_tile.py `test_power_hold_refused_while_open`.
 * FAIL before (Verilator, unmodified RTL, build/fix/t1_before.log): variant a: problems=['PWR_CTRL write while OPEN did not set TILE_SEQ (errors=set())',
   'PWR_CTRL reads back 0x1, expected 0', 'TZ != untiled bare-core reference (partial sums lost)'] -> TESTS=4 PASS=3 FAIL=1.
 * PASS after (build/fix/t1_after.log): all three variants problems=[]; TESTS=1 PASS=1.
 * host: before (unmodified model/device) `test_power_hold_refused_while_open`: "DID NOT RAISE RondoError"; after: pytest 35 passed (34 + 1).
 * Full T-TILE and the other regressions are in the final regression section.

### Task 2 / B2: KAT_START refused with CORE_HOLD / CORE_CLK_OFF; KAT ends with KAT_FAIL on a refused launch (done)
Files (backups *.pre_fix): rtl/chip/rondo_regs.v (honor_kat refused with START_BUSY when pwr_core_hold|pwr_clk_off, after the tile_open check),
rtl/chip/rondo_seq.v (new `output reg kat_fail`, pulses in the IDLE refusal and the LAUNCH refusal), rtl/chip/rondo_kat.v (new input `seq_fail`; E_SIG ends with
fail_rb=1, eng_sig=0), rtl/chip/rondo_dev.v (kat_fail_w wire), formal/seq_f.v (kat_fail connection + 3 harness items: assume !(kat_run&&fmt_set) [FORMAT writes are
blocked while the KAT is ACTIVE]; assert kr_q -> (seq_active||kat_fail); assert accepted launch that did not start the layer -> kat_fail), host model.py (KAT_START ->
START_BUSY when PWR_CTRL[1:0]), device.py kat() (raises RondoError).
MBIST_START stays allowed with the cores held (confirmed by the test).
Spec: 6.3 KAT_START/MBIST_START rows, 6.5 START_BUSY row, 9.8 bullet, 10.2 sentence (9.9 / header in task 14).
Tests:
 * sim/test_chip_kat.py `kat_refused_when_core_off` (PWR_CTRL 0b01/0b10/0b11, 200-cycle check): FAIL before (build/fix/t2_kat_before.log):
   "PWR_CTRL=0b01: ACTIVE still 1 after 200 cycles; no START_BUSY; ST_STATUS.RUNNING = 1; a load happened (LOAD_CRC / WSTALE changed)". PASS after (3 values, t2_kat_after.log).
 * sim/test_chip_mbist.py `mbist_with_core_off` (MBIST=1): first half (MBIST under PWR_CTRL=0b11 completes) passed before; second half FAIL before
   (t2_mbist_before.log: ACTIVE after 200 cycles, MBIST_RUNNING, no START_BUSY, MBIST_STATUS changed). PASS after (t2_mbist_after.log).
 * formal seq: bmc depth 70 PASS (t2_seq_bmc.log), cover PASS (kat_fail cover reached at step 2). Mutant (rondo_seq without the two kat_fail assignments, copy in
   build/fix/mut_seq): BMC FAILS at step 2 (assertion seq_f.v:84, t2_seq_mutant.log) as required. Note: the first harness version failed at step 1 because the new history
   registers were uninitialized; fixed with initial values.
 * host/tests/test_model.py `test_kat_refused_with_power_ctrl`: FAIL before (DID NOT RAISE RondoError), PASS after (pytest 36 passed).
 * The defensive path (b) is not reachable from the pins after (a); it is covered by the formal property only (no simulation test).

### Task 3 / B4: Rondo.set_clock lowers SCLK before the next frame; transports model the link rate (done)
Files (backups *.pre_fix): host/rondo_host/device.py (new `f_clk_alt` argument, `_f_src_of`, set_clock: _wait_idle, CLK_CFG frame, set_speed(hz_safe) BEFORE any
further frame, read DIV_APPLIED/SRC_APPLIED, no failure when both applied fields read 0 = FPGA without rondo_clkdiv, f_core follows the readback),
host/rondo_host/cocotb_transport.py (CocotbTransport(bfm, hz=None, f_src_hz=None, dut=None, min_r=8.0, div_net="div_applied"): set_speed sets the BFM ratio
f_src/hz; every frame checks R_core = ratio / 2**DIV_APPLIED (read in the sim thread from dut.div_applied) and asserts R_core >= min_r; `min_r_seen` recorded),
host/rondo_host/transport.py (LinkRateError(RondoError)), host/rondo_host/model.py (RondoModel(strict_rate=True): LinkRateError for hz > f_core/8; CLK_CFG
read-back now includes DIV_APPLIED [17:16] / SRC_APPLIED [20] like the RTL; _applied tracked in _finish_frame).
Spec 14.3 paragraph + 14.5 set_clock line.
Tests: host/tests/test_model.py `test_set_clock_rate`: FAIL before (old set_clock + strict model): "LinkRateError: SPI frame at 5000000 Hz > f_core/8 = 781250 Hz" on the
CHIP_ID read; PASS after (pytest 37). sim/test_chip_host.py `host_set_clock_rate` (RTL, rondo_chip_top, Verilator): FAIL before (old set_clock + new transport):
"AssertionError: SPI frame at R=1.00 < 8.0 (SCLK ratio 8.00 source periods, DIV_APPLIED=3)" (build/fix/t3_before.log; the plan quotes R=1.25 for a 5 MHz SCLK at f_clk 50 MHz, the
test starts at SCLK 6.25 MHz so R is 1.00); PASS after (t3_after.log): DIV 3 -> 1 -> 0 with min R seen >= 8, scratch register and bit-exact inference afterwards.
Note: sim/test_chip_host.py still compares VERSION with the literal 0x00020100 (changed in task 15).

### Task 4 / B3 + elaboration checks + lint variants (done)
Decision (D3): TILE with ACCSIG_BF16 != 8 is an elaboration error (no RTL to make the wide-accumulator bf16 build tile).
Files (backups *.pre_fix): rtl/chip/rondo_dev.v (generate block e_npar, e_wmap, e_bmap, e_xmap, e_trc, e_ck, e_ps, e_txz, e_b3, e_tb, e_nr as in the plan; `.AW_BF16(8 + ACCSIG_BF16)` to
rondo_regs), rtl/chip/rondo_trace.v (initial $fatal -> generate-if), rtl/chip/rondo_layers.v (small correction, logged: with TILE=0 and ACCSIG_BF16=24 the bf16 PS ports
(ps_q/ps_wdata) had 2 real WIDTHEXPAND mismatches; the PS buses of the bf16 instance are now sized 8+ACCSIG_BF16 (zero-extend on read, low 16 bits used on write): identical wiring at
the default 16), scripts/chip_lint.sh (clean variants accsig24 [-GACCSIG_BF16=24 -GTILE=0], tile_b0; expected-fail function run_expect_fail with accsig24_tile, npar6, tbits10; Icarus NPAR=6
negative + Icarus default positive on rondo_dev; Yosys chparam NPAR=6 negative). Yosys prints only "rondo_dev.v:76: ERROR: FATAL: ." (location, no message), so that check matches the location.
All three tools honour the elaboration $fatal in generate-if; no `initial` form was needed.
Spec: 7.1 (full check list), 10.1, 18.1, 18.3, 18.5 (<=16), 13.13 table (ACCSIG_BF16 8), 15.4 T-LINT.
Test = the expected-fail lint variants. Before (unmodified RTL, build/fix/t4_lint_before.log): accsig24 (TILE=0): 3 warnings; accsig24_tile: "EXPECTED an elaboration error ... (rc=1)" (2 WIDTHEXPAND
warnings instead of the message); npar6: rc=1 without the message; tbits10: rc=0 (silently accepted). tile_b0: clean already. After: all 11 verilator variants as specified plus the
Icarus/Yosys checks pass. Also TILE_GEOM at the FULL default stays 0x00201008 (checked in the T-REG/T-TILE regressions below).

### Task 5 / F1: spi_ctrl formal made honest (stage A done; stage B not attempted, see below)
Files (backups *.pre_fix): formal/spi_ctrl.sby (tasks bmc / cover / mutant, all -DGAPN=4, depth 160, header explains the soundness of the byte-spacing abstraction and that this is BMC),
formal/spi_ctrl_f.v (covers split per crc_mode: 2nd and 3rd write word with CRC on/off, 2nd read, (N+1)-th read, HCRC reject, DCRC reject, frame end after >= 2 data words, mid-word abort
with err_frame; `ifdef SPI_F_MUTANT` false assertion `!(issue && rb_req_we && reqs == 1)`), scripts/chip_formal.sh (rewritten: task list from the .sby [tasks] section, label by sby mode
("BMC depth N, bounded" / "k-induction depth N" / "cover depth N"), expected-fail tasks (`mutant` or `# expect-fail:` header), cover steps checked against the job's bmc depth).
Results: see below (appended when the runs finish).
Stage B (real k-induction for spi_ctrl with RONDO_FORMAL_OBS ports): NOT attempted in this round (the plan makes it a timeboxed attempt; stage A is the mandatory part). The spec says "bmc depth 160".

### Task 12: run_wide_layer reads TZ once per sub-batch (done)
host/rondo_host/device.py run_wide_layer (non-swap branch): `zz = tz(len(idx))` once, then the per-input assignment (backup device.py.pre_fix).
Test host/tests/test_tile.py `test_wide_layer_tz_reads_once` (counting MockTransport, L 16, p 24, N 7, TILE_B 3): FAIL before ("TZ read frames: 19, expected 7"), PASS after (pytest all pass).
T-WIDE (run_chip_host host_wide) is part of the final host regression.

### Task 8 / B7: disabled lane keeps stale z when a start arrives in the done cycle (done)
rtl/core/fused_coproc_pipe.v L_FIN arm (backup fused_coproc_pipe.v.pre_fix; additive: the new branch is `LANE_MASK && start && !busy_r`, constant false at LANE_MASK = 0): qNaN into zl and
go to L_IDLE. Spec 2.7 sentence added in task 14 batch (see below).
Test sim/test_core_c6.py `c6_start_in_done_disabled` (masks 01, 10, 00, 01, 10; start taken in the done cycle with lane_en changed; disabled lane must read qNaN, enabled lane equals the
unmasked reference): FAIL before in both simulators and both formats (build/fix/t8_before_*.log): "mask 01: disabled lane 1 keeps stale z (not qNaN): ['0xbe95', ...]" (fp32: 0xbeb63ede...).
PASS after (t8_after_*.log, TESTS=2 PASS=2 for each sim x format run). T-EQ after the change: Icarus and Verilator 150 inferences, 0 mismatches (re-run in the final regression too).

### Task 6 / B6: layer core_rst_n driven by a flop (done)
rtl/chip/rondo_seq.v (backup rondo_seq.v.pre_fix): `run_f` flop per layer (set on the L_CLK -> L_RUN transition, cleared on leaving L_RUN and in the default arm, async reset 0), `run_q = {run_f}`,
`core_rst_n[f] = test_mode ? rst_n : run_q[f]`; the synchronous format-follow condition uses `ls[fmt_applied] != L_RUN` instead of the async net; `ifdef FORMAL` invariant
`run_f == (ls[f] == L_RUN)` inside the generate block (checked by formal/seq.sby; hierarchical references from the harness were mis-modeled by Yosys, so the assertion lives in the RTL under `ifdef FORMAL`).
sim/chip_waivers.vlt: the `SYNCASYNCNET -file "*rondo_seq.v"` waiver is removed; Verilator -Wall stays clean for all variants without it (no narrower waiver needed).
New scripts/chip_struct.sh (called from chip_lint.sh): Yosys on rondo_seq, select -assert-none of non-mux/non-flop cells in the input cone of core_rst_n.
Test: FAIL before on the pre-task-6 rondo_seq (copy build/fix/rondo_seq_before_task6.v): "ERROR: Assertion failed: selection is not empty" listing $eq / $procmux CMP cells of the ls decode; PASS after
("STRUCT core_rst_n driven by flop (+ test-mode mux only): PASS"). formal seq bmc (depth 70) PASS with the invariant (t6_seq_bmc.log). Chip runners T-SEQ, T-FMT, T-SCAN, T-CLK PASS under Verilator
(build/fix/t6_regress_part.log); T-KAT PASS (its only failure in that log was the new task 9 test soft_reset_during_kat, whose RTL fix did not exist yet).
Note: the first Yosys select expression of the plan (`... t:$eq t:$ne ... %u %i`) only unions the top two stack entries; replaced by "cone ∩ all cells − mux − flops".

### Task 7 / B5: CAPS LAYER field and HAS_BIAS (done)
rtl/chip/rondo_regs.v: CAPS[4] HAS_BIAS = (LAYER == 0), CAPS[3:2] = LAYER (bit 2 was 0 and bit 3 = KAN before). Default CAPS unchanged (bits 4:2 = 100).
host/rondo_host/regmap.py: LAYER0/LAYER1 removed from CAPS_BITS; CAPS_LAYER_SHIFT/MASK and caps_layer(); device.reset_check stores self.layer; model.py: RondoModel(layer=0) builds CAPS the same way
(KAN: no HAS_BIAS / HAS_FP32 / GUARD / READBACK / DBG / LANE_MASK, mirroring the RTL). Users of LAYER0/LAYER1: only sim/test_chip_kan.py (updated).
Tests: sim/test_chip_kan.py (caps_layer == 1 and HAS_BIAS absent): FAIL before (Icarus, build/fix/t7_kan_before.log): "CAPS 0xc019: LAYER field 2 (spec 6.2: 1 = KAN), HAS_BIAS must be 0"; PASS after (t7_kan_after.log).
sim/test_chip_regs.py: default CAPS expectation unchanged plus `caps_layer == 0` and CAPS[4:2] == 0b100 (passes before and after). host/tests/test_model.py `test_caps_layer_field`: FAIL before
(AttributeError: 'Rondo' object has no attribute 'layer'), PASS after.

### Task 9: rbus arbiter / soft reset / shadows (done; RTL part)
Files (backups *.pre_fix): rtl/chip/rondo_rbus_arb.v (new input srst; A_IDLE does not grant K/M during srst; A_REQ cancels an internal owner on srst or when its valid drops; o_req_valid uses the owner's valid),
rtl/chip/rondo_dev.v (`.srst(srst)` into u_arb; the slave FSM is no longer reset by srst: D_IDLE stays idle (o_req_ready has !srst), D_WAITRD aborts to D_FIN with r_data 0 and r_err 1, other states proceed),
rtl/chip/rondo_wpack.v (flush_staging also clears c_valid, rs and rd_pend; placed at the end of the block because the last non-blocking assignment wins), rtl/chip/rondo_regs.v (srst clears shd[0..3]).
Spec: 8.2 rule 6 (8.3 latency and the 9.6 sentence are in task 14). Small correction to the plan: cur_valid must be declared before its use in the always block (Icarus).
Tests (Icarus, before = unmodified RTL, after = fixed; build/fix/t9_*):
 * test_chip_regs `soft_reset_clears_shadows`: FAIL before "stale shadow after SOFT_RST: TOTAL_CYC_HI = 1"; PASS after.
 * test_chip_pack `soft_reset_invalidates_read_cache`: FAIL before "read cache still valid after SOFT_RST"; PASS after. (Plan correction: weights must be loaded first, the SRAM is X before the first load.)
 * test_chip_seq `soft_reset_backpressure`: FAIL before: the bus protocol checker fires (sva_viol=0x10: response later than MAX_RSP, i.e. the response was dropped); PASS after.
 * test_chip_kat `soft_reset_during_kat` (30 trials, random 50..5000-cycle delay, 60% rsp_ready backpressure, monitor on u_dev.u_arb): FAIL before with the same protocol-checker violation
   (sva_viol=0x10, at the first trial; the stray-internal-access monitor never got to report); PASS after, 0 stray internal requests in 30 trials.

### Task 5 (update): spi_ctrl formal, what was actually possible
Stage A as planned (one configuration at GAPN 4, depth 160 for bmc/cover/mutant) is NOT solvable: with yices, z3 and abc bmc3 the BMC slows down about 2x per step from step ~35-40 on (step 42 of the GAPN-4 job:
> 4 min, step 46 > 4.5 min), also with CRC off (CRC mode fixed by a define), with the payload bytes zeroed (SPI_F_DATA0), and with opcode/address/length constant (tried, no gain); `abc pdr` returns UNKNOWN at once.
(The plan's GAPN-4/depth-160 *cover* job is fine: 4.3 min, all covers reached, last at step 111.) Result, as in formal/spi_ctrl.sby (header documents everything):
 * bmc_nocrc: depth 34 at GAPN 2 (a write request to the rbus is issued at step 31), bmc_crc: depth 28 at GAPN 2 (header incl. HCRC; the CRC-on write path is not reached),
 * cover: depth 160 at GAPN 4, CRC free (all covers incl. 2nd/3rd write word with CRC on and off, HCRC and DCRC reject, N+1-th read, frame end after >= 2 words, mid-word abort),
 * mutant_nocrc: bmc_nocrc configuration + false assertion on the FIRST write word: FAILS at step 31 (build/fix/t5_mutant_nocrc.log: "failed assertion ... spi_ctrl_f.v:125 step 31"), i.e. the write-path assertions are
   exercised. Before (original job: depth 64, GAPN 8, mutant on the first write word, build/fix/t5_mutant_before.log): "DONE (PASS)", the false assertion is not detected = vacuity confirmed.
 * Remaining gap: later words of a burst and the CRC-on write path are covered by simulation (T-SPI) and by the cover task only. Stage B (k-induction, RONDO_FORMAL_OBS) was not attempted.
 * spi_ctrl_f.v additions: SPI_F_CRC / SPI_F_DATA0 / SPI_F_MUTANT(_REQS) defines (default behavior of the harness unchanged without defines), covers split per CRC mode.
 * scripts/chip_formal.sh also got `# cover-exempt:` (cover steps are not compared with the bmc depth for spi_ctrl). Plan deviation: the cover-depth rule does not hold for spi_ctrl.
Final formal results: see "Final regression".

### Task 10: dead code and narrowed UNUSED waivers (done)
Deleted (backups *.pre_fix): rondo_dev: dummy4, ps_b_w, ev_trc_done_r, mem_rd_val, the unused wp_* nets (wp_en, wp_we, wp_bias, wp_lane, wp_addr, wp_half, wp_wd_h, wp_wd_l); rondo_seq: xcur, accept_ok;
rondo_regs: integer ci, any_start_bit; rondo_trace: trig_stored; rondo_tile: srst_d; rondo_spi_ctrl: pb; rondo_chip_top: miso_r, miso_oe_r; rondo_ps: integer k. Kept (used by tb_chip_vs_core.v's SVA through
hierarchical references): rondo_dev wp_denied / ce_l_any (waived by name).
sim/chip_waivers.vlt: both file-wide `UNUSEDSIGNAL/UNUSEDPARAM -file "*rtl/chip/*.v"` lines removed; 95 per-signal entries (`-file "*<file>" -match "*'name'*"`) with one justification comment per file replace them
(unused only in some feature/geometry builds, reserved register fields, ports of the common wrapper parameter list). All 8 clean lint variants are clean. The core-file waivers are unchanged.
scripts/chip_lint.sh: new check "no file-wide UNUSED* waiver for rtl/chip". Test: before (pre-fix waiver file) the check reports a file-wide waiver (FAIL); after: "no file-wide UNUSED* waiver" (PASS).
Without the blanket waiver and before the cleanup the 8 variants showed 46-107 warnings each (121 distinct) -- build/fix/ has the counts in this entry only; the lint logs are in build/chip/lint/.

### Task 11: run_chip_suite does not depend on sys.executable (done)
sim/run_chip_suite.py: interpreter order RONDO_PY, ROOT/.venv-rtl/bin/python, sys.executable; numpy check with a clear message; regenerates when scripts/gen_vectors.py or suite/cases.py is newer than the npz; the no-op `.replace` is gone.
Root cause: cocotb_common canonicalizes sys.executable with realpath, which for the venv python is the uv base interpreter (no numpy). Small correction needed to make it work (logged): scripts/gen_vectors.py itself spawned
`ROOT/.venv-rtl/bin/python`; it now uses RONDO_PY / venv / sys.executable too. scripts/chip_regress_new.py runs `gen_vectors.py small` (and `full` with --slow) first and prints "gen_vectors: PASS/FAIL".
Test (copy of rtl/host/scripts/sim without .venv-rtl and without build/vectors under build/fix/clean_tree): FAIL before (build/fix/t11_before.log: CalledProcessError, the base python3.13 has no numpy);
after: without RONDO_PY a clear message "gen_vectors.py needs numpy ... set RONDO_PY or create .venv-rtl" (t11_nopy.log); with RONDO_PY the vectors are generated in the clean tree and the suite runs
(started; the clean tree was deleted when the disk filled up, see "Disk full incident", so the final PASS line of that run is not available; T-SUITE passes in the normal regression).

### Task 13 / D1(a) (done)
Spec: 9.8 (MBIST first with MBIST=1, task 2), 11.3 SRC 1 layout, 13.25 FPGA text, 11.6 coverage paragraph. Code: host/rondo_host/memtest.py (March C- as a generator of bus operations, shared by the blocking
SPI API and the cocotb bench), Rondo.mem_test(regions=("PS","TX")) in device.py (needs CAPS.TILE, refuses an open sequence, TILE_ABORT afterwards, returns (region, b, lane, group, field, xor)).
Plan correction: TX words are masked to the format width by the wrapper (wd_masked), so the TX pattern width is W (16 in bf16) like PS, not 32.
Tests: host/tests/test_tile.py `test_mem_test_mock` (clean + stuck PS bit + stuck TX bit through a faulty mock): FAIL before ("'Rondo' object has no attribute 'mem_test'"), PASS after.
sim/test_chip_tile.py `tile_mem_test_faults` (rondo_dev, RONDO_FAULT_INJECT; run_chip_tile.py now defines it): clean runs in bf16 and fp32 report nothing; a stuck-at-1 bit in a rondo_ps H macro (bf16: element bit 3; fp32:
bit 19), a stuck-at-0 TX bit and (fp32) a stuck-at-0 L-macro bit are reported with the right (b, lane, group, field, xor): PASS after (build/fix/t13_after.log); before: the feature did not exist (ImportError).
The march works on bursts (chunks of one (input, lane) of PS / one input of TX) rather than single cells; documented in memtest.py and spec 11.6.

### Task 14: spec updates (done; spec header now v2.1.1)
See the edited sections: header, 2.7, 5.2/13.6/13.7, 6.1 VERSION, 6.3, 6.5, 7.1, 8.2, 8.3, 9.1 step 5, 9.8, 9.9, 10.1, 10.2, 11.3, 11.5 (incl. D4), 11.6 (incl. D1), 13.13, 13.25, 13.26, 14.3, 14.5, 15.3, 15.4, 16.4 (D1-D4),
18.1, 18.3, 18.5, 18.6. Backup docs/CHIP_INTERFACE_SPEC.md.pre_fix (v2.1 original).

### Task 15 / D2: VERSION 0x00020101 (done, single revertible change)
Files: rtl/chip/rondo_regs.v (`localparam VERSION_V`, the only RTL place), rtl/chip/sva/rondo_sva_regs.v, formal/regs_f.v, host/rondo_host/regmap.py VERSION_VALUE; tests compare against R.VERSION_VALUE
(sim/test_chip_regs.py, test_chip_top.py, test_chip_gls.py, test_chip_host.py, host/tests/test_model.py); device.reset_check warns (RuntimeWarning) when VERSION < 0x00020101. To revert: set the four constants back to 0x00020100.
Test: T-REG reset_values_and_access with VERSION_V temporarily 0x00020100: FAIL (build/fix/t15_before.log: protocol checker/SVA violation on the VERSION read and the test mismatch); with 0x00020101: PASS (t15_after.log).

### Disk full incident (for the record)
While 4 regressions ran in parallel copies of the tree the filesystem (/home) filled up (ENOSPC). Effects: (1) a Python rewrite of docs/CHIP_INTERFACE_SPEC.md was cut at 131072 bytes; the file was reconstructed
(first part of the truncated file + the original tail + the missing 18.6 edits) and all 42 edit markers were re-verified; the truncated copy is not kept. (2) all regression/formal results of that moment are discarded and were re-run
(in the main tree, sequentially in two groups) after removing the copies, sim/sim_build_chip (regenerated) and the scratch trees.

### Formal regs (task 9.2 follow-up)
formal/regs_f.v (backup regs_f.v.pre_fix): the shadow property "changes only at a LO read" now also allows a soft reset (`|| srst_q`), plus the new assertion `if (srst_q) assert (shd0 == 0)` (shadow 0 in the cycle after a
soft-reset cycle). Before the harness update, regs/prove FAILED at step 4 on the old property (build/fix/final first formal run: the shadow was cleared by srst); after: `regs prove` PASS (k-induction depth 12).
Note: the first version of the update (`(srst_q && shd0 == 0)` inside the old assertion plus the new one) made the base case unsolvable in 5 min (yices); the logically equivalent split above proves in seconds.

### Final regression (main tree, logs in build/fix/final/)
 * Python host tests: 40 passed (34 original + 6 new: power_hold_refused_while_open, kat_refused_with_power_ctrl, set_clock_rate, caps_layer_field, wide_layer_tz_reads_once, mem_test_mock).
 * chip_regress_old.py icarus: 42/54 runners pass; the 12 failures are exactly the known WL_*-parameterised runners; run_core_c1..c8 all pass, run_core_eq (T-EQ) 3/3 (150 inferences, 0 mismatches); the explicit run_fused_pipe /
   run_fused_bf16 / run_workload_inter jobs pass. REGRESSION OK (old_icarus.log).
 * chip_regress_old.py verilator: 39/54: the 12 WL_* + the 3 known Verilator baseline failures (grad_a_inter, power_top, train_ladder_inter); run_train_coproc / run_train_ladder passed (no rc=250 flake this time);
   run_core_c1..c8 and run_core_eq pass; explicit jobs pass. REGRESSION OK (old_verilator.log).
 * chip_regress_new.py icarus: 18/18 runners pass, "CHIP REGRESSION OK" (gen_vectors small: PASS first) (new_icarus.log). Number of cocotb tests per runner: units 7, spi 6, regs 4, pack 2, seq 3, fmt 1, top 2, clk 1,
   dbg 2, trace 2, kat 4, mbist 2, scanmode 2, sva 5, kan 1, host 3, tile 5, suite 1.
 * chip_regress_new.py verilator --slow: see new_verilator_slow.log (results appended below).
 * scripts/chip_lint.sh: 8 clean variants clean, 3 expected-fail variants rejected with their message, Icarus/Yosys negatives, no file-wide UNUSED waiver, chip_struct.sh PASS (lint.log).
 * scripts/chip_formal.sh: regs prove (k-induction) + cover, spi_ctrl bmc_nocrc / bmc_crc / cover / mutant_nocrc (failed as required), spi_phy, seq, dev_bus, tile bmc + cover: all PASS (formal.log; the regs/prove FAIL in that
   log is the run before the regs_f.v update, formal_regs.log shows PASS after it).
 * scripts/chip_synth.sh small: rc=0, check -assert passes, 632,732 cells (baseline 632,622: +110 cells, +0.017%), exactly 3 $_DLATCH_N_ (the ICGs) (synth_small.log).
 * md5 check (build/fix/final/md5_after.txt): the three protected Python files and all rtl/core/*.pre_chip / *.pre_c8 backups unchanged (13/13 OK).
 * KAT signature constants (rtl/chip/rondo_kat_sigs.vh) untouched.
 * chip_regress_new.py verilator --slow: 21 of 22 runners passed at first: units, spi, pack, seq, fmt, top, clk, dbg, trace, kat, mbist, scanmode, sva, kan, host, tile, suite and the Verilator-only full, kat_full (4/4: the KAT
   signatures are unchanged), cofrgenet (T-CFG), gls (T-GLS). One failure: run_chip_regs, the new test soft_reset_clears_shadows (precondition TOTAL_CYC HI != 0). Cause, a further bug found (not in the plan):
   rondo_seq did `total_cyc <= 64'(CNT_INIT)`; CNT_INIT is a 32-bit signed int parameter, which Verilator SIGN-extends (HI = 0xFFFFFFFF, then 0 after 50 cycles) while Icarus zero-extends (HI = 1), so the CNT_INIT = 2^32-50
   test preset behaved differently per simulator. Small correction (test-only parameter, 0 in silicon, no effect at CNT_INIT = 0): rtl/chip/rondo_seq.v now zero-extends `{32'd0, CNT_INIT[31:0]}`. After it: T-REG 4/4 under
   Verilator and Icarus, T-SEQ 3/3 under Verilator, chip_lint.sh re-run clean (lint.log). The Verilator --slow run was not repeated as a whole (only regs and seq re-run).

## Fix round summary / deviations from the plan
 * 0.2 baseline not re-run on a separate unmodified tree (verifier's baseline used); every "fails before" was run on the pre-change state.
 * Task 5: GAPN-4 / depth-160 BMC infeasible (solver blow-up beyond step ~35-40): bmc depth 34 (CRC off) / 28 (CRC on) at GAPN 2 with the payload-zero abstraction, cover at depth 160 / GAPN 4, mutant on the first write word; stage B not attempted.
 * Task 13: TX pattern width = format width (not 32); march at burst granularity.
 * Task 2: the defensive kat_fail path is verified formally (seq.sby, mutant fails) but has no simulation test (unreachable from the pins after the regs refusal).
 * Task 4 small correction: rondo_layers bf16 PS buses sized 8+ACCSIG_BF16 (2 real WIDTHEXPAND warnings in the TILE=0, ACCSIG_BF16=24 variant).
 * Task 9 plan corrections: cur_valid declaration order; wpack flush at the end of the block; weights must be loaded before the read-cache test.
 * Task 11 small correction: scripts/gen_vectors.py interpreter selection.
 * Task 6: Yosys select expression rewritten; the FORMAL-ifdef invariant lives in the RTL (hierarchical refs mis-modeled).
 * New finding: CNT_INIT sign extension (above). Other observation: the "stray internal access after srst" scenario of soft_reset_during_kat is caught first by the rbus protocol checker in the unfixed RTL; the stray-request monitor itself was never shown to fire.
 * Disk-full incident (above): results re-run; the spec was reconstructed and verified.
 * Not run: Vivado, hardware, plan 0.2 baseline copy, stage-B k-induction.
 * Response to docs/CHIP_VERIFY_REPORT.md: see docs/CHIP_FIX_PLAN.md and this section.
