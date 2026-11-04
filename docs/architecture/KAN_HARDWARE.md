# A Chebyshev KAN layer on the RONDO datapath

Status: RTL complete and verified; fidelity, timing and area measured; power
measured for all eight built configurations.

This document describes `kan_layer_pipe` (fp32) and `kan_layer_bf16`, a full
Chebyshev Kolmogorov-Arnold network (KAN) layer built from the same pipelined
fused multiply-add (FMA) and the same interleaving rules as the CoFrNet layer
(`fused_coproc_pipe`). It then repeats the two CoFrNet hardware experiments on
it: decision fidelity on three trained models (the analogue of the paper's
Table 2) and lane scaling with energy (the analogue of Table 4). Every number
below is read from a result file named next to it. Nothing here is estimated;
where a quantity was not measured, the text says so.

Terms used throughout:

- **FMA**: `fp_fma_pipe`, the five-stage pipelined HardFloat fused
  multiply-add `p = a*b + c`, rounded once. Its latency is `L_fma = 5` cycles.
- **Dependency-safe rotation**: a set of `N` independent recurrences issued
  round-robin through one FMA, one per cycle. A result issued at cycle `t` is
  readable from `t + L_fma + 1`, so each recurrence can be re-issued safely only
  if `N >= L_fma + 1 = 6` (principle P4 in `ICLR/Sections/architecture.tex`;
  `rtl/core/ladder_scan_inter.v`).
- **Lane**: one complete copy of the datapath. Lanes share no state.
- **Output**: one of the layer's `N_OUT` output units `y_o`. It is the KAN
  analogue of one CoFrNet ladder and the unit for per-unit metrics.
- **Layer evaluation**: all `N_OUT` outputs for one input vector.

## 1. What the hardware computes

For inputs `x` in R^p the layer computes

    xt_i = tanh(x_i)                                   (host)
    T_0 = 1,  T_1 = xt_i,  T_{n+1} = 2 xt_i T_n - T_{n-1}     (chip, n < D)
    y_o  = sum_{i<p} sum_{n<=D} c[o,i,n] T_n(xt_i)     (chip)

with degree `D = 7`, so eight basis terms per input. The coefficients
`c[o,i,n]` are resident in on-chip block RAM.

**tanh is host-side on every platform.** The RTL takes `xt = tanh(x)` as its
input. In the two-layer replay the host computes `tanh` in fp64 on the RTL's
own layer-1 outputs and quantises the result to the DUT format before loading
it. The GPU and Ara baselines apply `tanh` on their host side in the same way
(`workloads/kan_golden.py` treats it as a host stage), so no platform is
charged for it.

## 2. How the RONDO principles map onto a KAN layer

The layer has two stages, and they have opposite shapes. The basis recurrence is
per input (p recurrences, shared by every output). The weighted sum is per
output (a matrix-vector product with `N_OUT x p(D+1)` coefficients). A CoFrNet
layer has the same two shapes in the other order: a matrix-vector product
(`W x`) feeding per-ladder recurrences.

### 2.1 Basis: `rtl/core/kan_basis_inter.v`

The p Chebyshev recurrences are independent, so they are interleaved through
one pipelined FMA exactly as `kscan_inter` interleaves ladders: `RB = p` slots,
one FMA issued per cycle, each slot re-issued every `RB` cycles. The recurrence
is the `NUMER_NEG = 1` form of the continuant step (the sign of the `K_{k+2}`
term flipped), with every coefficient equal to `2 xt_i`, which is the
"One Recurrence, Two Bases" construction of the paper
(`ICLR/Sections/architecture.tex`, subsection "One Recurrence, Two Bases").

The module is `kscan_inter` specialised to that case rather than `kscan_inter`
itself. `kscan_inter` stores a general coefficient array of `NSLOT*DEPTH` words;
for a basis every entry is `2 xt_i`, so the coefficient store collapses to one
`xt` and one `2 xt` register per input (40x7x32 = 8,960 flip-flops become
40x2x32 = 2,560). `2 xt` is formed once at capture by an exponent increment,
which is exact. The retained array is indexed by degree:
`B_all[i][n] = T_n(xt_i)`.

Parameter `NBAS` (default 1) spreads the p slots over NBAS FMAs: the rotation
becomes `RB = max(ceil(p/NBAS), L_fma+1)` groups, and groups beyond p are idle
padding, which also keeps `p < 6` legal. `NBAS = 1` is exactly the
single-FMA `kscan_inter` schedule and is the configuration in every headline
table (Section 6 explains why a second value is also reported).

### 2.2 Weighted sum: `rtl/core/kan_sum_bank.v`

This is `affine_bank_pipe`'s structure: NMAC parallel FMAs, never chained,
coefficients read from block RAM one word per cycle, one group of accumulators
issued per cycle, and every accumulator re-issued once per rotation of
`NGROUP >= L_fma + 1` cycles.

**Why the accumulation is split by degree.** The affine bank works because a
CoFrNet batch of 8 ladders at depth 7 holds 56 independent accumulations, far
more than the `6 x NMAC` needed to keep NMAC FMAs busy. A KAN output has one
natural accumulation. A lane that owns 8 outputs would therefore hold 8 serial
chains and could keep only one FMA busy (8 / 6 rounds down to 1), so adding
lanes would take FMAs away from each output instead of adding throughput. The
bank therefore splits every output into its `D+1` degree partials

    S[o,n] = sum_i c[o,i,n] T_n(xt_i)          y_o = sum_n S[o,n]

which gives `NOB x (D+1)` independent accumulations per batch of `NOB` outputs:
64 at `NOB = 8`, against CoFrNet's 56. Each partial still accumulates over its
inputs in order `i = 0..p-1`, exactly like a CoFrNet coefficient. With
`NMAC = D+1` the FMA index is the degree, so FMA `n` always multiplies by basis
column `n` and its operand select is a p:1 multiplexer on the step counter.

The partials are then combined by a balanced tree of `ceil(log2(D+1)) = 3`
levels on the same FMAs (`b = 1`, which is an exactly rounded sum), one rotation
over the `NOB` outputs per level. Output `o` issues level `l+1` exactly `NOB`
cycles after level `l`, so the combine obeys the same rule, `NOB >= L_fma + 1`.
The module checks all four constraints at elaboration (`NMAC | NOB(D+1)`,
`NGROUP >= 6`, `NOB >= 6`, `NMAC >= (D+1)/2`).

The operation order (inputs in order within a partial, then the tree) does not
depend on NMAC, NOB grouping, NBAS or the lane count, so outputs are
bit-identical across all of them (verified, Section 4).

### 2.3 Lanes: `rtl/core/kan_layer_pipe.v`

**Lanes partition the outputs.** Lane `l` owns outputs
`[l*N_OUT/N_LANES, (l+1)*N_OUT/N_LANES)` and holds its own basis evaluator,
sum bank and coefficient memory. Nothing is shared, and the result mapping onto
`y` is static wiring, exactly as in `fused_coproc_pipe`. A lane evaluates the
basis once per layer evaluation, then its `N_OUT/(N_LANES*NOB)` batches.

The alternative, partitioning the inputs, was rejected. Every output needs every
input's basis, so an input partition does not remove the need for each lane to
see all of `y_o`'s terms: each lane would accumulate a partial sum over its
inputs for all 64 outputs, and a cross-lane merge of `N_OUT x (N_LANES-1)` adds
would have to follow, sharing state between lanes. An output partition keeps
lanes fully independent. Its cost is that the basis, `p(D-1) = 240` FMAs per
evaluation, is computed once per lane instead of once per layer, which is
1.1% of the layer's arithmetic (Section 3) but, with a single-FMA basis, a
fixed cycle floor per lane (Section 6).

The load port, start/busy/done handshake and the registered load fan-out are
copied from `fused_coproc_pipe`. `kan_layer_bf16.v` pins `EXP = 8, SIG = 8`. A
KAN layer has no reciprocal, so there is no seed table and no EPS.

Parameters: `P_IN, N_OUT, DEPTH, N_LANES, NOB, NMAC, NBAS` (plus `EXP, SIG, GATE`).
Requirements: `N_LANES*NOB | N_OUT`.

## 3. Cost model and where the cost is

### 3.1 Arithmetic per layer evaluation (Waveform layer 1: p=40, N_OUT=64, D=7)

| stage | FMAs per evaluation | share |
|---|---|---|
| basis, `p(D-1)` | 240 | 1.1% |
| weighted sum, `N_OUT * p * (D+1)` | 20,480 | 96.8% |
| partial combine, `N_OUT * D` | 448 | 2.1% |
| total | 21,168 | 100% |

**The output sum dominates the arithmetic, at 96.8%.** This is the KAN version of
the finding that a CoFrNet layer is affine-bound (`docs/FUSED_COPROC.md`): the
recurrence that RONDO was built around is about 1% of the work.

### 3.2 Cycles, measured

From `workloads/results/kan/cycle_sweep_fp32.json` (trained Waveform layer 1,
Verilator; cycle counts are data-independent and identical at bf16,
`cycle_sweep_bf16.json`):

    cycles per evaluation = 10 + (D-1)*RB + (N_OUT/(N_LANES*NOB)) * 361
    batch of NOB=8 outputs: 361 = p*NGROUP (320, MAC phase) + 3*NOB (24, combine) + 17 (drains, handshake)

| NBAS | lanes | cycles / evaluation | basis cycles | cycles / output | basis share |
|---|---|---|---|---|---|
| 1 | 1 | 3,138 | 250 | 49.03 | 8.0% |
| 1 | 2 | 1,694 | 250 | 26.47 | 14.8% |
| 1 | 4 | 972 | 250 | 15.19 | 25.7% |
| 1 | 8 | 611 | 250 | 9.55 | 40.9% |
| 5 | 1 | 2,946 | 58 | 46.03 | 2.0% |
| 5 | 2 | 1,502 | 58 | 23.47 | 3.9% |
| 5 | 4 | 780 | 58 | 12.19 | 7.4% |
| 5 | 8 | 419 | 58 | 6.55 | 13.8% |

At one lane the sum's MAC phase is 81.6% of all cycles (2,560 of 3,138). The
basis is a fixed 250 cycles per lane at NBAS=1, because one FMA must issue all
240 basis steps, and it does not shrink as lanes are added.

For reference, the CoFrNet layer at the same geometry is 46.28 cycles per ladder
at one lane and 5.81 at eight (paper Table 4); KAN at NBAS=1 is 49.03 and 9.55
cycles per output.

NMAC=4 (not in the tables): 5,698 cycles at one lane, 931 at eight lanes,
bit-identical to NMAC=8.

### 3.3 Area by block

Hierarchical synthesis of one fp32 lane (`xc7k325tffg900-2`, out-of-context,
same generics; Vivado synthesis, not post-route, report kept in
`workloads/results/kan/util_hier_kan_layer_pipe_l1.rpt`):

| block | LUTs | FFs | DSP | BRAM |
|---|---|---|---|---|
| lane total | 24,872 | 21,058 | 18 | 28.5 |
| basis evaluator (`u_bas`) | 7,767 (31%) | 13,273 | 2 | 0 |
| of which its FMA incl. absorbed operand selects | 4,076 | 449 | 2 | 0 |
| sum bank (`u_sum`) | 17,100 (69%) | 5,437 | 16 | 28.5 |

The basis is 1.1% of the arithmetic but 31% of a lane's LUTs: its cost is the
per-slot state (x, 2x, two rolling values, 6 retained degrees for each of 40
inputs = 12,824 FFs) and the 40:1 operand selects, not arithmetic. A post-route
fp32 lane is 25,057 LUTs against 19,157 for a CoFrNet lane at the same target.

## 4. Verification

**Exact model.** `sim/kan_rtl_model.py` models every FMA with one exact rounding
(rational arithmetic, round-to-nearest-even, subnormals and signed zeros) at any
`(EXP, SIG)`, in the RTL's operation order. `sim/test_kan_layer.py` loads the
coefficients through the real load port, runs start to done, and compares every
output of the first `KAN_CHECK` samples bit for bit.

**Configuration matrix** (`sim/run_kan_layer.py`, Verilator, synthetic
coefficients, logs in `build/kan_logs/matrix2_*.log`), all bit-exact:

| fmt | p | N_OUT | lanes | D | NMAC | NBAS | NOB | outputs checked | cycles/eval |
|---|---|---|---|---|---|---|---|---|---|
| fp32 | 10 | 16 | 2 | 7 | 8 | 1 | 8 | 64 | 191 |
| bf16 | 10 | 16 | 2 | 7 | 4 | 2 | 8 | 64 | 247 |
| fp32 | 10 | 16 | 1 | 7 | 4 | 1 | 8 | 64 | 472 |
| fp32 | 13 | 16 | 1 | 7 | 8 | 3 | 8 | 64 | 336 |
| fp32 | 3 | 8 | 1 | 7 | 8 | 1 | 8 | 32 | 111 |
| fp32 | 7 | 16 | 1 | 3 | 4 | 1 | 8 | 64 | 202 |
| bf16 | 7 | 16 | 2 | 4 | 5 | 1 | 8 | 64 | 128 |
| fp32 | 6 | 12 | 2 | 2 | 3 | 1 | 6 | 36 | 81 |
| fp32 | 40 | 64 | 8 | 7 | 8 | 1 | 8 | 128 | 611 |
| bf16 | 40 | 64 | 4 | 7 | 8 | 1 | 8 | 128 | 972 |
| fp32 | 40 | 64 | 1 | 7 | 8 | 1 | 8 | 64 | 3,138 |

This covers a basis with idle padding (p = 3 < 6), odd and non-power-of-two
degree counts (D = 2, 4), NMAC below, equal to and not dividing into D+1, and
NBAS > 1 with a ragged last group. Synthetic inputs include +1, -1 and 0.

**Bit identity across configurations.** On the trained Waveform layer, lanes
1/2/4/8 x NBAS 1/5 at NMAC=8, and NMAC=4 at 1 and 8 lanes, return identical
output bits (`bit_identical_to_first` in `cycle_sweep_{fp32,bf16}.json`).

**No regression.** No existing RTL file was modified; the KAN layer is four new
modules. The related existing runners pass under Verilator:
`run_cheb_basis`, `run_kscan_inter`, `run_affine_pipe`, `run_fp_fma_pipe`,
`run_scan_inter`, and the full CoFrNet layer `run_fused_pipe` and
`run_fused_bf16` on 20 real Waveform inputs at 64 ladders and 8 lanes
(5.81 cycles/ladder, accuracy delta 0.0000; logs in `build/kan_logs/regress/`).
The full `run_all.py` sweep under Verilator (`build/kan_logs/run_all_verilator.log`)
passes 28 of 45 runners. None of the 17 failures involves this work: 11 are
parameterised runners that skip without their `WL_*` environment;
`run_engine_steady` needs `WL_OUT`; `run_grad_a_inter` and
`run_train_ladder_inter` stop on Verilator 5.052 lint (WIDTHEXPAND in
`grad_a_inter.v`); `run_power_top` fails on a `stimulus.mem` longer than its
array; and `run_train_coproc` and `run_train_ladder` pass all their tests but
exit rc=250 because of the defect below, and exit 0 once it is removed.

**Simulator defect found and fixed (affects every Verilator run in `sim/`).**
Builds under `sim/sim_build/<tag>` link `sim/sim_build/verilator.o` if that file
exists. It is cocotb's `main`, and it is left there by the three runners that use
the default `build_dir` (`run_smoke`, `run_mat2x2`, `run_recip`). It is compiled
against another design's `Vtop.h`, and the one present at the start of this work
was compiled on 2026-09-05 against Verilator 5.050 headers (Verilator 5.052 was
installed on 2026-09-08; the package keeps older header mtimes, so make never
rebuilt it). The model class layout then disagrees between objects, and the
simulator corrupts its own heap: KAN builds segfaulted at the first eval in
some configurations and aborted with "corrupted size vs. prev_size" at exit in
the rest. After removing the object, `run_train_coproc` and `run_train_ladder`
exit 0, which suggests this is the mechanism behind I-15's teardown
double-free. KAN
builds now live in `sim/sim_build_kan/`, and the runner refuses to build if a
`verilator.o` sits in that directory's root. The stale objects are kept in
`build/kan_logs/stale_verilator_o/`. `cocotb_common.py` was not changed.

## 5. Decision fidelity (Table 2 analogue)

Trained two-layer ChebyKANs `[p, 64, k]`, D=7 (`workloads/train_kan.py`), 500
test inputs each. Both layers run in RTL: layer 1 at 8 lanes, then the host
computes `tanh` in fp64 on the RTL's outputs, then layer 2 at one lane with
`N_OUT = k` padded to 8 zero-coefficient outputs (the smallest legal batch,
`NOB >= 6`); the padded outputs are discarded. Errors are relative to the fp64
golden logits of `workloads/kan_golden.py`; agreement is against the fp64
golden's own decisions; accuracy is against the labels. The first 3 samples of
each layer were also checked bit for bit against the exact model (192/192
layer-1 and 24/24 layer-2 outputs in every run).

| model | p | fp32 max rel. err | fp32 agreement | bf16 max rel. err | bf16 agreement |
|---|---|---|---|---|---|
| MAGIC | 10 | 2.08e-05 | 1.0000 | 2.30e+00 | 0.9960 (2 flips) |
| Credit Card | 23 | 2.18e-05 | 1.0000 | 2.62e+00 | 1.0000 |
| Waveform | 40 | 3.36e-05 | 1.0000 | 2.28e+00 | 0.9940 (3 flips) |

| model | fp32 acc RTL / ref | bf16 acc RTL / ref | fp32 median rel. err | bf16 median rel. err |
|---|---|---|---|---|
| MAGIC | 0.870 / 0.870 | 0.870 / 0.870 | 1.39e-07 | 8.70e-03 |
| Credit Card | 0.830 / 0.830 | 0.830 / 0.830 | 7.00e-08 | 5.21e-03 |
| Waveform | 0.830 / 0.830 | 0.832 / 0.830 | 8.45e-08 | 6.20e-03 |

Sources: `workloads/results/kan/rtl_{magic,creditcard,waveform}_{fp32,bf16}_replay.json`;
raw layer outputs in `workloads/results/kan/replay/`.

**fp32 preserves every decision on all three models**, with logits within
3.4e-05 of fp64, the same outcome as the CoFrNet layer (Table 2: fp32 max 9.16e-04,
agreement 1.0000). **bf16 loses 0 to 0.6% of decisions**, and task accuracy moves by
at most 0.2 points while individual decisions change, the effect
`docs/PAPER_CORRECTIONS.md` C-21 documents for CoFrNet. The bf16 maximum error
(2.3 to 2.6) comes from logits near zero; the median is 0.5 to 0.9%.

Two further notes. Layer-1 outputs near zero inflate the per-output relative
error (fp32 layer-1 maximum 1.24e-02 on MAGIC) without affecting any logit
beyond 2.1e-05. The bf16 RTL order (degree partials, then a tree) differs from
the single running sum that `kan_golden.py`'s bf16 emulation uses, so the two
bf16 results are different rounding experiments; they land close
(Waveform 497/500 agreement in both, MAGIC 498/500 RTL against 496/500
emulated, Credit Card 500/500 in both, `kan_emul_agree.json`).

## 6. Lane scaling and energy (Table 4 analogue)

Waveform first layer: p=40, N_OUT=64, D=7, NOB=8, NMAC=8. Cycles from
`cycle_sweep_*.json`. Fmax and area post-route out-of-context on
`xc7k325tffg900-2` at a uniform 5.5 ns target that every build misses
(WNS -0.35 to -2.01 ns), so `Fmax = 1000/(5.5 - WNS)` is an achieved maximum,
and area is from the same runs (`scripts/k7_kan_fmax.sh`,
`workloads/results/vivado/kan_p5p5_*`, part verified in each `results.json`).
Throughput = Fmax / cycles per output. Area efficiency = throughput per LUT
relative to the smallest build of the same format and NBAS. Energy = dynamic
power from SAIF-annotated `report_power` at `--period 8.0` (125 MHz) with
checksum-verified activity, divided by throughput at 125 MHz
(`scripts/k7_kan_power.sh`, `workloads/kan_power.py`,
`workloads/results/vivado/kan_power_*`). Assembled by `workloads/kan_tables.py`
into `workloads/results/kan/kan_tables.json`.

| fmt | NBAS | lanes | cycles/output | WNS (ns) | Fmax (MHz) | LUTs | DSP | BRAM | M outputs/s | area eff. | nJ/output |
|---|---|---|---|---|---|---|---|---|---|---|---|
| fp32 | 1 | 1 | 49.03 | -0.783 | 159.2 | 25,057 | 18 | 28.5 | 3.25 | 100% | 191.4 |
| fp32 | 1 | 2 | 26.47 | -0.881 | 156.7 | 47,265 | 36 | 29 | 5.92 | 96.7% | 181.5 |
| fp32 | 1 | 4 | 15.19 | -0.988 | 154.1 | 95,147 | 72 | 30 | 10.15 | 82.3% | 186.6 |
| fp32 | 1 | 8 |  9.55 | -2.013 | 133.1 | 185,142 | 144 | 32 | 13.94 | 58.1% | 219.3 |
| bf16 | 1 | 4 | 15.19 | -0.346 | 171.1 | 44,396 | 0 | 16 | 11.27 | 100% | 68.5 |
| bf16 | 1 | 8 |  9.55 | -0.466 | 167.6 | 86,868 | 0 | 16 | 17.56 | 79.6% | 77.9 |
| bf16 | 5 | 4 | 12.19 | -0.310 | 172.1 | 53,066 | 0 | 16 | 14.12 | 100% | 63.0 |
| bf16 | 5 | 8 |  6.55 | -0.454 | 168.0 | 104,111 | 0 | 16 | 25.66 | 92.6% | 69.4 |

Area efficiency compares throughput per LUT with the smallest build of the same
format and NBAS. The NBAS=5 rows are a separate family and each has its own
100% reference; they are not comparable with the NBAS=1 rows on that column,
only on throughput and energy.

For orientation, the CoFrNet layer at the same geometry, target and part
(paper Table 4): fp32 one lane 46.28 cycles/ladder, 161.0 MHz, 19,157 LUTs,
3.48 M ladders/s, 175.1 nJ; fp32 eight lanes 5.81, 146.7 MHz, 150,488 LUTs,
25.25 M ladders/s, 149.1 nJ; bf16 eight lanes 5.81, 168.9 MHz, 63,523 LUTs,
29.07 M ladders/s, 52.2 nJ. A KAN output is a different unit of work from a
CoFrNet ladder (20,480 multiply-adds per 64 outputs against 17,920 coefficient
multiply-adds plus 64 ladders), so these are context, not a ratio to quote.

**Scaling efficiency** (cycle reduction divided by lane increase, 2 to 8 lanes,
the metric the paper reports as 99.7% for CoFrNet and 44.5% for Ara):

| NBAS | cycles/eval at 2 lanes | at 8 lanes | reduction | scaling efficiency |
|---|---|---|---|---|
| 1 | 1,694 | 611 | 2.77x | **69.3%** |
| 5 | 1,502 | 419 | 3.58x | **89.6%** |

(identical at fp32 and bf16). Area efficiency is the other metric and is in the
table above; the two must not be conflated.

**Why 69.3%, and what it is not.** Everything that scales per output scales
perfectly: the sum batch is 361 cycles at every lane count. The loss is entirely
the per-lane basis, a fixed 250 cycles because the specification puts the p
recurrences on one pipelined FMA, and one FMA needs `p(D-1) = 240` cycles
regardless of lane count. CoFrNet has no such term, because its recurrences are
per ladder and move into lanes with the ladders. In a KAN the recurrences are
per input and every lane needs all of them.

The fix is architectural and small. Spreading the basis over `NBAS = 5` FMAs
(`RB = 8` groups) cuts the floor to 58 cycles; it cannot go below
`1 + (D-1)(L_fma+1) + drains = 46` for any FMA count, which bounds scaling
efficiency at about 92% for this geometry (`(46 + 4*361)/(46 + 361)/4`, a
derived bound, not a measurement). NBAS=5 was built at bf16 (rows above).
At bf16 it is better on every
measured axis: at eight lanes 25.66 against 17.56 M outputs/s for 20% more
LUTs (104,111 against 86,868), which is 22% more throughput per LUT, and
69.4 against 77.9 nJ per output. The reason the extra arithmetic pays is that
the four added FMAs per lane replace a serial bottleneck rather than duplicating
work.

**The fp32 eight-lane build fits the device, barely**: 185,142 LUTs, 90.8% of
the XC7K325T, and routing pressure costs 13.6% of clock against four lanes
(154.1 to 133.1 MHz), against 5.5% for the CoFrNet layer at the same step
(155.3 to 146.7 MHz at 76,635 to 150,488 LUTs).

### Power, activity-based

SAIF-annotated `report_power` on the routed checkpoint, `--period 8.0`
(125 MHz), part verified in every report, 70 to 72% of design nets matched,
confidence High. **Every run is checksum-verified**: the gate-level testbench
XORs every output word of 24 back-to-back evaluations, and
`workloads/kan_power.py` refuses to report power unless that value equals the
XOR from a behavioural Verilator run of the same stimulus and configuration
(`873ef791` at fp32, `834f` at bf16, invariant in lane count as it must be).

| fmt | NBAS | lanes | LUTs (power build) | total (W) | dynamic (W) | LUT-as-logic uW/LUT | nJ/output |
|---|---|---|---|---|---|---|---|
| fp32 | 1 | 1 | 24,075 | 0.649 | 0.488 | 6.15 | 191.4 |
| fp32 | 1 | 2 | 45,906 | 1.020 | 0.857 | 6.13 | 181.5 |
| fp32 | 1 | 4 | 91,986 | 1.703 | 1.536 | 5.61 | 186.6 |
| fp32 | 1 | 8 | 184,500 | 3.048 | 2.871 | 4.94 | 219.3 |
| bf16 | 1 | 4 | 43,906 | 0.725 | 0.564 | 4.63 | 68.5 |
| bf16 | 1 | 8 | 85,943 | 1.183 | 1.020 | 4.12 | 77.9 |
| bf16 | 5 | 4 | 52,410 | 0.807 | 0.646 | 4.62 | 63.0 |
| bf16 | 5 | 8 | 102,840 | 1.490 | 1.325 | 4.62 | 69.4 |

Energy per output is dynamic power over throughput at 125 MHz, the basis the
CoFrNet table uses. The area column here is from the 8.0 ns power builds, not
the 5.5 ns builds in the scaling table: watts belong with the netlist that
produced them.

**Energy per output falls slightly and then worsens**: 191.4, 181.5, 186.6,
219.3 nJ at fp32, and 68.5 to 77.9 nJ at bf16 from four to eight lanes. The
cause is the basis floor again, and it is arithmetic: energy per output is
dynamic power times cycles per output, so it only improves while the cycle
reduction keeps up with the added power. From four to eight lanes at fp32 the
power rises 1.87x while cycles per output fall only 1.59x (972 to 611 cycles per
evaluation, not 972 to 486), so energy rises 17.5%. At NBAS=5, where the floor
is smaller, the same step costs 10% (63.0 to 69.4 nJ) instead of 14%
(68.5 to 77.9 nJ at bf16, NBAS=1). CoFrNet, whose cycles halve exactly, improves
slightly with lanes instead (175.1 to 149.1 nJ).

**Precision, at matched lane count and occupancy**: 186.6 to 68.5 nJ at four
lanes (2.72x) and 219.3 to 77.9 nJ at eight (2.82x), against 2.95x and 2.85x
for the CoFrNet layer. bf16 also needs 2.13x fewer LUTs.

**Where the power goes** (fp32, four lanes, `power_saif.rpt` section 3.1): each
lane draws 0.383 W, of which the sum bank is 0.323 W (84%) and the basis
evaluator 0.060 W (16%). The basis is 1.1% of the arithmetic, 31% of the LUTs
and 16% of the power: its LUTs are operand selects and retained state, which
switch once per rotation rather than once per cycle. That is also why per-LUT
power, on the LUT-as-logic basis the CoFrNet layer reports as a flat 7.5 uW,
is lower here and falls slightly with lane count: 6.15, 6.13, 5.61, 4.94 uW at
fp32 and 4.63, 4.12 uW at bf16.

### A method check: the SAIF stimulus clock understates power by 18%

Every power number in this project, CoFrNet's included, simulates the routed
netlist with a **10 ns** testbench clock and reports power against a design
constrained at **8.0 ns**, then divides that power by a throughput computed at
125 MHz. Whether that is consistent depends on how Vivado reads a SAIF, so it
was measured: same routed checkpoint, same coefficients, same 24 inputs, same
checksum `834f`, only the stimulus clock changed
(`workloads/kan_saif_clock_check.py`).

| bf16, 8 lanes | stimulus clock | dynamic (W) | total (W) | nets matched |
|---|---|---|---|---|
| `kan_power_bf16_l8` (the table above) | 10 ns | 1.020 | 1.183 | 70% |
| `kan_power_bf16_l8_tbclk8p0` | 8 ns | **1.206** | 1.370 | 70% |

**Vivado takes the SAIF activity as absolute transitions per second.** Driving
the netlist at the clock the design is constrained and rated at raises dynamic
power 18.2%, and the residual below the naive 25% is the clock tree, which
`report_power` derives from the constraint and which is therefore already at
125 MHz in both runs. Energy per output computed the established way is
consequently a **lower bound**: the KAN bf16 eight-lane figure is 77.9 nJ as
reported and 92.1 nJ when the activity is captured at the rated clock. The
tables above keep the established basis so they stay comparable with the CoFrNet
table, and this paragraph is the correction that applies equally to both.

One trap for anyone repeating it: `glbl` releases the global set/reset at a
fixed 100 ns, so a faster stimulus clock starts the coefficient load before the
flip-flops are released. The first attempt did exactly that, loaded partial
coefficients and returned a different checksum (`82a2` against `834f`); holding
reset to 200 ns fixes it. The checksum guard is what caught it.

## 7. Deviations and caveats

1. **Single-FMA basis sets the scaling efficiency.** The specification's
   one-FMA basis is the table configuration. It gives 69.3% scaling efficiency;
   `NBAS = 5` gives 89.6%. Both are measured; neither should be presented
   without the other.
2. **The output sum dominates cost**: 96.8% of the FMAs, 81.6% of the cycles
   at one lane, 69% of a lane's LUTs. RONDO's recurrence machinery is a small
   part of a KAN layer, as it is of a CoFrNet layer.
3. **Accumulation order.** Per-degree partials combined by a tree, not the
   single running sum of `kan_golden.py`. Exact in fp64, different rounding in
   reduced precision. Fidelity is measured against fp64 only.
4. **The degree-0 term is computed on chip.** `T_0 = 1`, so
   `sum_i c[o,i,0]` is an input-independent constant per output. The design
   spends `N_OUT*p = 2,560` MACs per evaluation (12.5%) recomputing it, as the
   specification asks. Folding it into a per-output constant would remove them.
5. **Small layers are padded.** `NOB >= 6` means layer 2 (`N_OUT = k = 2 or 3`)
   runs as 8 outputs with zero coefficients. That costs cycles, not accuracy,
   and the replay's layer-2 cycles (947 per evaluation) are not a tuned figure.
6. **Area per lane is larger than CoFrNet's** (25,057 vs 19,157 LUTs at fp32,
   one lane), mostly basis state and operand selects (Section 3.3). The basis
   evaluator is duplicated per lane by the output partition.
7. **bf16 accumulators are bf16.** The `ACCSIG` widening that
   `docs/PAPER_CORRECTIONS.md` C-20 describes for the CoFrNet coefficient stage is
   not implemented here. The partials sum 40 terms each at p=40; at larger p
   the same degradation should be expected but has not been measured for KAN.
8. **The "per-step layer clock gain" analogue was not built.** For CoFrNet it
   compares chained against parallel accumulators (11.6 to 158.9 MHz). The KAN
   sum bank reuses the parallel structure, but no chained KAN build exists, so
   no KAN-specific number is reported.
9. **Power stimulus clock.** The testbench clock is 10 ns while the
   design is constrained and rated at 8.0 ns, which the measurement in
   Section 6 shows understates dynamic power by 18.2%. Kept for comparability
   with the CoFrNet table; the corrected figure is given alongside.

## 8. Files

RTL (new): `rtl/core/kan_basis_inter.v`, `rtl/core/kan_sum_bank.v`,
`rtl/core/kan_layer_pipe.v`, `rtl/core/kan_layer_bf16.v`.

Simulation: `sim/run_kan_layer.py` (runner; no arguments runs the regression
configuration used by `run_all.py`), `sim/test_kan_layer.py`,
`sim/kan_rtl_model.py`, `sim/tb_kan_power.v`, `sim/tb_kan_power_bf16.v`.

Workloads: `workloads/kan_rtl_replay.py` (Section 5),
`workloads/kan_cycle_sweep.py` (Sections 3.2, 4), `workloads/kan_power.py`,
`workloads/kan_saif_clock_check.py` (the method check in Section 6),
`workloads/kan_tables.py`.

Flows: `scripts/k7_kan_fmax.sh` (5.5 ns timing and area; `KAN_NBAS` selects the
variant), `scripts/k7_kan_power.sh` (8.0 ns SAIF power).

Results: `workloads/results/kan/` (replays, sweeps, `kan_tables.json`),
`workloads/results/vivado/kan_p5p5_*` (timing/area),
`workloads/results/vivado/kan_power_*` (power). Superseded Vivado runs of two
earlier RTL revisions (a DSP-mapped index multiply in the combine, then a flat
64:1 select) are archived under `build/genesys2/kan_superseded/` and are not
quoted.
