# RONDO chip interface specification

Status: design specification for the implementer and verifier, **version 2.1.1**
(2026-11-03, fix round CHIP_FIX_PLAN: PWR_CTRL/KAT refusal rules, soft-reset rules, CAPS LAYER field, elaboration checks, VERSION register 0x00020101;
v2.1 (2026-11-02) added input tiling, §18, change C8, VERSION register 0x00020100). v2 supersedes v1: it adds additive, parameter-gated core changes
(§2), run-time selectable bf16/fp32 (§12), the full debug/test feature set (§11),
and Raspberry Pi 5 host specifics (§14).

Scope: everything that wraps the existing CoFrNet layer (`fused_coproc_pipe`, used at
bf16 and at fp32) into a tape-out-ready chip top driven by a Raspberry Pi 5 over SPI,
plus an FPGA prototype top that the Pi drives identically.

Normative words: **must** / **must not** are requirements the verifier checks;
**should** is a recommendation; **may** is an implementer choice. Numbers marked
*(est.)* are rough estimates to be replaced by synthesis results (task T-SYN).

Every number about the existing core is cited as `file:line` (paths relative to the
project root `CoFrNet-RPI-main/`). Changes to existing files are allowed **only** as
listed in §2 (core-change policy). Nothing else in `rtl/core/`, `rtl/board/`, existing
`sim/run_*.py` / `sim/test_*.py`, `vivado/genesys2.xdc` or
`vivado/genesys2_build.tcl` may be modified.

## Author defaults (each may be overridden by the author)

| # | default | where |
|---|---|---|
| A1 | **Both bf16 and fp32 datapaths on the chip, selected at run time** by the FORMAT register (reset value: bf16) | §12 |
| A2 | Shuttle-agnostic: no pads, no PLL; core clock frequency is a parameter `F_CLK_HZ` (default 50 MHz for the chip, 100 MHz on the FPGA) | §3, §4 |
| A3 | bf16 accumulator width `ACCSIG_BF16` selectable; **default 8 (as built, `fused_coproc_bf16.v:251-253`)**, so chip bf16 results match the paper's FPGA numbers. 24 (wide) is available by parameter: it raises agreement at CoFrGeNet size but costs about +360 kGE and most of bf16's energy advantage (§16.1). Decided by the author: keep 8 (Q5) | §2, §12 |
| A9 | fp32 reciprocal `TBITS_FP32`/`NR_ITERS_FP32`: **chip default TBITS=8, NR_ITERS=2 (C7, §2.8), decided by the author (Q4 accepted)**: 47,104-bit seed ROM instead of 753,664, 1 ULP instead of 2. Chip fp32 results therefore differ slightly from the paper's FPGA numbers; the as-built TBITS=12, NR_ITERS=1 remains available by parameter | §2.8 |
| A4 | NXBUF = 4 self-run input buffers | §7 |
| A5 | MISO is tri-stated (`spi_miso_oe` = 0) whenever CS is deselected | §4, §5 |
| A6 | Host is a **Raspberry Pi 5**: libgpiod v2 (`gpiod`) for GPIO, `spidev` on `/dev/spidev0.0`, `smbus2` on I²C bus 1; 3.3 V header | §14 |
| A7 | Chip clock from an on-board oscillator (Pi 5 GPCLK only as an option) | §14.5 |
| A8 | Manufacturing features (scan, MBIST, JTAG) parameter-gated, **default OFF**; all other debug features default ON | §11 |

### Author decisions (recorded after v2.0)

| # | decision |
|---|---|
| Q4 | Accepted: fp32 reciprocal TBITS=8, NR_ITERS=2 is the chip default (A9). |
| Q5 | Keep the bf16 accumulator at 8 bits as built (A3); 24 stays a parameter. |
| Q6 | NXBUF = 4 self-run buffers (A4). |
| Q8 | One FPGA bitstream per format is acceptable for the Genesys 2 prototype; format switching is verified in simulation. |
| Q9 | Keep the accumulator debug tap, parameter-gated and enabled by default; revisit at area closure. |
| UVM | UVM-based verification will run on Vivado's xsim (Vivado 2025.2). |
| Tiling | Input-tiling mode for layers wider than PDIM (C8, §18); on-chip batch depth TILE_B = 8 plus host-swapped partial sums; wide layers run in fp32. |
| Open | Q1 process and core clock, Q2 power gating, Q7 memory self-test choice: decided with the shuttle. |

---------------------------------------------------------------------------------------

## 0. Terms

| term | meaning |
|---|---|
| core / layer | the existing complete layer module `fused_coproc_pipe` (instantiated once with bf16 parameters, once with fp32 parameters). `fused_coproc_bf16` is a pure parameter wrapper of it (`fused_coproc_bf16.v:285-297`). The Chebyshev KAN layer (`kan_layer_pipe`) is a build-time alternative (§13.24). |
| FORMAT | run-time register selecting the active datapath: 0 = bf16, 1 = fp32. |
| active core | the layer instance selected by FORMAT; the other is the inactive core (clock-gated, held in reset). |
| W | element width of the active format: 16 (bf16: EXP=8, SIG=8) or 32 (fp32: EXP=8, SIG=24). |
| element | one W-bit floating-point value (weight, bias, input or output). |
| word | one 32-bit unit of the internal bus. Every element occupies exactly one bus word: bits [W-1:0]; upper bits ignored on write, zero on read. |
| core word | one NPAR-element entry of a weight or bias memory (NPAR×W bits). |
| `clk_src` | the selected source clock (pin `clk` or `clk_alt`). |
| `clk_core` | `clk_src` after the run-time divider (§3.3). **Everything on chip runs on `clk_core`**: SPI slave, wrapper, both layers (each behind its own clock gate). f_core = its frequency. |
| R | f_core / f_SCLK. |
| inference | one `start` → `done` evaluation of the active layer on one input vector x. |
| launch | the wrapper asserting the active layer's `start` for one cycle. |
| ACTIVE | wrapper status: an inference, self-run, KAT, MBIST or soft reset is in progress (§7.2). |
| rbus | the bus-agnostic internal request/response interface (§8). |
| KAT | known-answer self-test (§11.5). MBIST: memory built-in self-test (§11.6). |

---------------------------------------------------------------------------------------

## 1. The existing core: facts this spec depends on

### 1.1 Configurations

**bf16 instance** = `fused_coproc_pipe` with the overrides of `fused_coproc_bf16`
(`fused_coproc_bf16.v:285-291`): EXP=8, SIG=8, TBITS=6, EPS=0x3C24 (0.01 in bf16),
SEED_FILE `recip_seed_e8s8_t6.mem`; ACCSIG = `ACCSIG_BF16` (as built: 8,
`fused_coproc_bf16.v:253`; chip default 8 as built, 24 by parameter, A3).

**fp32 instance** = `fused_coproc_pipe` with EXP=8, SIG=24 (`cofr_defs.vh:13-14`),
ACCSIG=SIG (`fused_coproc_pipe.v:49`), EPS=0x3C23D70A (`cofr_defs.vh:22`); as built
TBITS=12 with `recip_seed_e8s24_t12.mem` (`fused_coproc_pipe.v:56,60`); chip default as
built TBITS=12, NR_ITERS=1 by parameter; chip default TBITS=8 with two Newton-Raphson iterations (change C7, §2.8; A9).

Common geometry (`fused_coproc_bf16.v:254-259`): DEPTH=7, WIDTH=64, PDIM=40, N_LANES=8,
NSLOT=8, NPAR=8, GATE=1; FMA_LAT=5 (`fused_coproc_pipe.v:57`).

Derived (formulas `fused_coproc_pipe.v:62-69`, `affine_bank_pipe.v:53-59`), identical
for both formats:

| symbol | formula | value |
|---|---|---|
| NLAD | WIDTH / N_LANES | 8 ladders per lane |
| NCH | NSLOT × DEPTH | 56 |
| NGROUP | NCH / NPAR | 7 |
| NBATCHES | NLAD / NSLOT | 1 |
| NWORDS (per lane) | NBATCHES × NGROUP × PDIM | 280 core words |
| NBWORDS (per lane) | NBATCHES × NGROUP | 7 core words |
| WAW | clog2(NWORDS) | 9 |
| BAW | clog2(NBWORDS) | 3 |
| LNW | clog2(N_LANES) | 3 |
| FW (this spec) | log2(NPAR) | 3 |

### 1.2 Port contract (today)

`fused_coproc_pipe.v:70-85`: `clock, nReset` (active-low asynchronous, e.g. `:117`),
`w_we, w_lane[LNW], w_addr[WAW], w_din[NPAR*W]`, `b_we, b_addr[BAW], b_din[NPAR*W]`,
`start, busy, done`, `x[PDIM*W]` (element i at `[i*W +: W]`), `z[WIDTH*W]` (ladder j at
`[j*W +: W]`). At bf16: w_din 128 b, x 640 b, z 1,024 b; at fp32 double.

### 1.3 Behavior the wrapper must respect

1. **Load port registered once** (`fused_coproc_pipe.v:112-127`); `w_lane` must be in
   lockstep with `w_we` (`genesys2_fused_top.v:113-118`). (Unused when EXT_MEM=1, §2.4.)
2. **Weight/bias memories**: one write and one unconditional synchronous read per cycle,
   no reset, no read-back path (`affine_bank_pipe.v:112-113`, `:153-158`). The read
   data `w_word`/`b_word` is consumed only outside `S_IDLE`: the first bias word used is
   read at the edge ending the first `S_BIAS` cycle (`:151`, `:213-216`) and the first
   weight word at the edge ending the last `S_BIAS` cycle (`:145-147`). Reads issued
   while the bank is in `S_IDLE` are never used. (This makes C3 safe.)
3. **x must be stable from launch until `done`**: latched into `x_reg` at each batch
   start (`affine_bank_pipe.v:206-207`; batches `fused_coproc_pipe.v:188-206`).
4. **z valid when `done` = 1**, unchanged until the next inference writes `zl`
   (`fused_coproc_pipe.v:180-183`, `:213-220`).
5. **`start` hazard (bug).** `busy_r` is set by `start && !busy_r`
   (`fused_coproc_pipe.v:228`); lanes leave `L_FIN` for `L_IDLE` only on the edge after
   `busy_r` falls (`:207`), and only `L_IDLE` reacts to `start` (`:185`). If `start` is
   sampled on the edge where lanes are still in `L_FIN` with `busy_r` = 0 (i.e. `start`
   high in the same cycle as `done`), `busy_r` is set but the lanes miss the pulse: the
   start is lost and `busy` stays 1 **until another `start`** arrives (lanes in `L_IDLE`
   then accept it although `busy_r` is already 1). A sequencer that waits for `done`
   after each start therefore hangs. `kan_layer_pipe.v` has the identical structure
   (`:132`, `:151`, `:167`). `fused_coproc_bf16.v` and `kan_layer_bf16.v` contain no
   logic (pure parameter wrappers: `fused_coproc_bf16.v:285-297`,
   `kan_layer_bf16.v:35-42`) and need no fix. Fixed by C1.
6. **Pole guard is internal**: `s_mag < EPS[W-2:0]` at `recip_nr_pipe.v:51`, one
   instance per lane (`ladder_engine_inter.v:53-60`), no port. Exported by C2.
7. **ε is a parameter** (`fused_coproc_pipe.v:59`, `fused_coproc_bf16.v:289`).
8. **Seed ROM**: one per lane, 2^TBITS × (SIG−1) bits, `$readmemh` (`recip_nr_pipe.v:40`,
   `:61-62`).
9. **Scan continuants**: `ladder_scan_inter` already has ports `k0_all`, `k1_all`
   (NSLOT×W each, the registers `lo[]`/`hi[]`, `ladder_scan_inter.v:51-52`, `:85-91`)
   and the streaming `res_valid/res_k0/res_k1` (`:58-60`); `ladder_engine_inter`
   leaves `k0_all`/`k1_all` unconnected (`ladder_engine_inter.v:49`). After a batch,
   `lo[s]` = K0 and `hi[s]` = K1 of slot s (writeback `hi<=lo, lo<=mac`,
   `ladder_scan_inter.v` writeback block).
10. **Recurrence** (golden, `sim/test_fused_bf16.py:43-50`): `K[d]=1, K[d-1]=a[d-1]`,
    `K[k]=a[k]K[k+1]+K[k+2]`, `f = sign(K1)sign(K0)|K1|/max(|K0|,ε)`.

### 1.4 Weight and bias packing (derived from the code)

Model tensors (`workloads/results/waveform_coeffs.npz`, reshaped in
`workloads/gen_genesys2_rom.py:52-53`): `Wl[j,k,c]` (ladder j < WIDTH, level k < DEPTH,
input c < PDIM) and `Bl[j,k]`. Inside a lane, chain `ch = s*DEPTH + k`
(`fused_coproc_pipe.v:152-153`); accumulator `acc[g*NPAR+m]` is fed from field m of the
weight word (`affine_bank_pipe.v:169-172`); weight word for group g, input c, batch b
at `(b*NGROUP+g)*PDIM + c` (`:138`, `:147`); bias word at `b*NGROUP+g` (`:151`,
`:216`). The existing loaders build exactly this (`gen_genesys2_rom.py:63-74`,
`sim/test_fused_bf16.py:84-111`):

```
l = j // NLAD;  r = j % NLAD;  b = r // NSLOT;  s = r % NSLOT
ch = s*DEPTH + k;  g = ch // NPAR;  f = ch % NPAR      # field f = bits [f*W +: W]
w_addr = (b*NGROUP + g)*PDIM + c;   b_addr = b*NGROUP + g
```

Field f=0 is the least-significant W bits (`gen_genesys2_rom.py:68-70`). Output
`z[j]` is ladder j (`fused_coproc_pipe.v:216`). The packing is format-independent
(only W changes).

---------------------------------------------------------------------------------------

## 2. Core changes (additive, parameter-gated)

### 2.1 Policy

* Every change adds parameters and/or ports. With every new parameter at its default
  and new inputs unconnected, each modified module must be **bit- and cycle-identical**
  to today. New **inputs** are ignored internally (replaced by constants) unless their
  gating parameter is set, so leaving them unconnected in existing instantiations is
  harmless. New **outputs** do not affect behavior.
* Only C1 is unconditional (bug fix, argued below).
* Regression proof for every change: (1) `sim/run_all.py` passes unchanged under the
  default simulator and `SIM=verilator`; (2) the targeted equivalence test named in each
  subsection passes; (3) `verilator --lint-only -Wall` on the modified module produces no
  new warnings except `PINMISSING` on existing instantiations, which are waived in the
  new `sim/chip_waivers.vlt`, not by editing old files.
* Files touched: `rtl/core/fused_coproc_pipe.v`, `affine_bank_pipe.v`,
  `ladder_engine_inter.v`, `recip_nr_pipe.v`, `kan_layer_pipe.v` (C1 only). New file:
  `rtl/core/recip_seed_e8s24_t8.mem` (generated by the existing
  `rtl/core/gen_recip_table.py --exp 8 --sig 24 --tbits 8`).

New parameters of `fused_coproc_pipe` (all forwarded as needed):

| parameter | default | change |
|---|---|---|
| `EXT_MEM` | 0 | C3: weight/bias memories outside the core |
| `DBG` | 0 | C4: debug taps |
| `LANE_MASK` | 0 | C6: lane-enable mask |
| `NR_ITERS` | 1 | C7: Newton-Raphson iterations in `recip_nr_pipe` |
| `TILE` | 0 | C8: input tiling, partial sums kept/saved across starts (§18.2) |

### 2.2 C1 — start-during-done fix (unconditional)

`fused_coproc_pipe.v:207`, replace the `L_FIN` arm by:

```verilog
L_FIN: if (start && !busy_r) begin       // same condition the top uses (:228)
           bat <= '0; rcnt <= '0; lstate <= L_GEN;
       end else if (!busy_r) lstate <= L_IDLE;
```

`kan_layer_pipe.v:151` likewise: `L_FIN: if (start && !busy_r) begin bat <= '0; lstate
<= L_BGO; end else if (!busy_r) lstate <= L_IDLE;`.

Why it changes no measured cycle count: the new arm differs from the old only in the
state (lane in `L_FIN`, `start`=1, `busy_r`=0). In the old design that state loses the
start and leaves `busy`=1 until a second start (§1.3.5); every existing testbench and
board top waits for `done` after each start and has passed, so none of them ever
produces that state (`sim/test_fused_bf16.py:117-131` issues the next start one edge
after observing `done`; `genesys2_fused_top.v:235-242` two edges after). On every trace
that does not contain the state, old and new are identical. With the fix, a start in
the done cycle behaves exactly as a start one cycle later would have, minus one cycle.
The wrapper keeps the post-done gap (§10.2) and the watchdog as defense in depth.
Proof: `run_all.py`; new directed test T-C1 (start held in the done cycle, then
waits for done: must complete with z bit-identical to a normal launch; the same test
against an unmodified copy of the core is expected to time out, demonstrating the bug).

### 2.3 C2 — pole-guard-hit export

* `recip_nr_pipe.v`: new output `guard_hit`. Add a flop `small_1 <= inValid &&
  (s_mag < EPS[W-2:0])` beside `v_1` (`:55-58`); `assign guard_hit = small_1`. One pulse
  per ladder whose |K0| was clamped, one cycle after the reciprocal accepted it.
* `ladder_engine_inter.v`: new output `guard_hit` connected to `u_recip.guard_hit`.
* `fused_coproc_pipe.v`: new output `guard_hit[N_LANES-1:0]`, bit l from lane l.
* Wrapper: GUARD_HITS += popcount(guard_hit) per cycle (§10.3). Proof: run_all; T-C2
  (bias-injection vectors with chosen |b| below and above ε, §2.6: count equals the
  number of clamped ladders).

### 2.4 C3 — weight/bias read-back via external memories (`EXT_MEM`)

The author asked for a read-back port. Because both formats must share one weight store
(§12) and the SRAM macros must sit behind a clean boundary, C3 is realized by moving the
memories **out** of the core when `EXT_MEM=1`; read-back, write, MBIST and macro
substitution then all happen in the wrapper module `rondo_wmem` with no further core
change.

`affine_bank_pipe.v`, parameter `EXT_MEM=0`; new ports:
`output [WAW-1:0] wm_addr`, `output [BAW-1:0] bm_addr`, `output mem_act`,
`input [NPAR*W-1:0] wm_q`, `input [NPAR*W-1:0] bm_q`.
* `wm_addr = wrd[WAW-1:0]`, `bm_addr = brd[BAW-1:0]` (the existing read addresses,
  `:147`, `:151`) — always driven.
* `mem_act = (state != S_IDLE) || in_valid` — the bank needs memory data.
* EXT_MEM=0: unchanged (`w_mem`/`b_mem` inferred, `wm_q`/`bm_q` ignored).
* EXT_MEM=1: `w_mem`/`b_mem` and the write logic are not generated; `w_word` and
  `b_word` are replaced by `wm_q` and `bm_q`. The external memory must return
  `q <= mem[addr]` registered, on every edge where `mem_act` was 1 in the preceding
  cycle (same 1-cycle latency as `:156-157`). When `mem_act` = 0 the data is unused
  (§1.3.2) so the external port may serve other clients.

`fused_coproc_pipe.v` forwards per lane: `wm_addr[N_LANES*WAW]`, `bm_addr[N_LANES*BAW]`,
`mem_act[N_LANES]`, `wm_q[N_LANES*NPAR*W]`, `bm_q[N_LANES*NPAR*W]`; with EXT_MEM=1 the
`w_*`/`b_*` load ports are ignored.

Proof: run_all (EXT_MEM=0); T-C3: the same weights and 50 inputs on (EXT_MEM=0 core)
vs (EXT_MEM=1 core + a behavioral registered memory) — z bit-identical and `done` in
the same cycle, both formats.

### 2.5 C4 — debug taps (`DBG`)

`fused_coproc_pipe.v`, parameter `DBG=0`; new ports:

| port | dir | meaning |
|---|---|---|
| `dbg_lane[LNW]` | in | lane to observe |
| `dbg_sig[3]` | in | static signal select (table below) |
| `dbg_idx[8]` | in | element index |
| `dbg_data[32]` | out | selected value, zero-extended, registered; valid 2 cycles after the selects change |
| `dbg_live_sel[2]` | in | live stream select |
| `dbg_live_v` | out | live stream valid (registered) |
| `dbg_live_d[32]` | out | live stream data (registered) |
| `dbg_live_f[8]` | out | live flags (registered): {guard_hit, NaN/Inf on recip output, lstate[2:0], affine `state`[1:0], ln_ovalid} of the selected lane |

Static `dbg_sig` (values are stable after an inference; captured live while running):

| dbg_sig | value (lane `dbg_lane`, index `dbg_idx`) | source |
|---|---|---|
| 0 | coefficient a, chain idx < NCH | `a_hold[idx*W +: W]` (`fused_coproc_pipe.v:154`) |
| 1 | coefficient accumulator, idx < NCH (EXP+ACCSIG bits) | `acc[idx]` (`affine_bank_pipe.v:121`), new output `acc_all` of `affine_bank_pipe` |
| 2 | K0 of slot idx < NSLOT (= reciprocal input before the guard) | `k0_all` via new `ladder_engine_inter` output |
| 3 | K1 of slot idx (= reciprocal numerator) | `k1_all` via new output |
| 4 | lane output zl[idx] (= reciprocal output f), idx < NLAD | `zl` (`fused_coproc_pipe.v:166`) |
| 5 | lane status {rcnt, bat, lstate} | `fused_coproc_pipe.v:134,165,170` |
| 6, 7 | reserved, read 0 | — |

Live `dbg_live_sel`: 0 reciprocal input stream `{res_valid, res_k0}`; 1 reciprocal
output `{ln_ovalid, ln_f}`; 2 scan numerator `{res_valid, res_k1}`; 3 affine writeback
`{mac_v[0], mac_p[0]}` (EXP+ACCSIG bits). `ladder_engine_inter` gets matching new
outputs (`k0_all, k1_all, res_valid, res_k0, res_k1`); `affine_bank_pipe` gets
`acc_all[NCH*(EXP+ACCSIG)]`, `mac0_v`, `mac0_p`, `state_o[2]`. With DBG=0 the mux logic
is not generated and outputs are 0. Proof: run_all; T-C4 (after an inference with known
weights, every static tap equals the Python model of the scan/affine/reciprocal for
lane/index sweeps; z unchanged vs DBG=0).

### 2.6 C5 — stage isolation: decision (no new datapath)

Options compared:

| option | area *(est.)* | what it tests | intrusiveness |
|---|---|---|---|
| (i) separate small test copies (a `cofr_coproc_inter` scan + `recip_nr_pipe`) in the wrapper | +1 lane scan + reciprocal per format ≈ +25–60 kGE | only the copies, **not** the lane silicon that failed | none in the core |
| (ii) injection muxes inside each lane (a_hold source, recip input) | NCH×W 2:1 muxes per lane ≈ +8–16 kGE total | the real lanes | edits the critical datapath |
| **(iii) injection through existing paths + C4 taps (chosen)** | **0** | the real lanes | none beyond C4 |

(iii) works because the coefficient stage computes `a = Σ_c W·x + b` with the
accumulator seeded by the bias (`affine_bank_pipe.v:213-216`):
* **(a) Scan stage**: load W = 0 and B = the desired coefficients, x = 0. Then
  every FMA is `0·0 + acc` = acc exactly, so `a_hold` = B bit-exactly (the round from
  ACCSIG to W is exact because the low bits are zero; a coefficient of −0 becomes +0,
  harmless). Read K0/K1 per slot through `dbg_sig` 2/3 and z through ZBUF.
* **(b) Reciprocal**: inject a = (0,…,0, β) for one ladder (a_{d-1} = β). By §1.3.10,
  K6=β, K5=1, K4=β, K3=1, K2=β, K1=1, K0=β exactly (all products by 0, sums with 1), so
  z = 1/β for |β| ≥ ε and sign(β)/ε (guard hit) otherwise — the real reciprocal of that
  lane on a chosen divisor, with K1 = 1.
* **(c) Coefficient stage alone**: run an inference and read `a_hold` and `acc` through
  `dbg_sig` 0/1; compare with Σ W·x + b computed on the Pi.
Test copies were rejected because they cannot localize a manufacturing defect in a
lane (they test themselves) and cost area; muxes were rejected because (iii) reaches
the same observability at zero datapath cost. The weights are overwritten by injection;
the host saves/restores them (read-back, C3). The procedure is §9.10; T-C5 tests it.

### 2.7 C6 — lane-enable mask (`LANE_MASK`)

`fused_coproc_pipe.v`, parameter `LANE_MASK=0`, new input `lane_en[N_LANES]`.
* `lane_en_q` register: loaded from `lane_en` when `start && !busy_r`; reset all ones.
  With LANE_MASK=0 it is the constant all-ones.
* Lane l starts only if `lane_en_q`/`lane_en` bit l = 1 (the lane's `L_IDLE`/`L_FIN`
  start condition is ANDed with `lane_en[l]`).
* Completion: `busy_r && &(lane_fin | ~lane_en_q)` replaces `busy_r && (&lane_fin)`
  (`:229`). If all lanes are disabled, `done` follows one cycle after `busy`.
* z of a disabled lane reads the canonical quiet NaN (bf16 `0x7FC0`, fp32 `0x7FC00000`)
  for all its NLAD ladders.
* With EXT_MEM=1, `mem_act` of a disabled lane stays 0, so its memories are not read.
* This also holds for a start taken in the done cycle (C1) while the lane is in `L_FIN`: the disabled lane writes qNaN and returns to `L_IDLE`.
Proof: run_all; T-C6 (random masks incl. all-zero and all-one: enabled lanes'
outputs bit-identical to the unmasked run; disabled lanes qNaN; done timing ≤ unmasked).

### 2.8 C7 — fp32 reciprocal seed reduction (`NR_ITERS`)

`recip_nr_pipe.v`, parameter `NR_ITERS=1` (allowed 1, 2). With 2, the Newton-Raphson
step `t = fma(−b, x, 2); x = fma(x, t, 0)` (`recip_nr_pipe.v:12-13`) is applied twice
before the output multiply; the sign/k1 delay lines are lengthened by 2·FMA_LAT.
Latency becomes 2 + (1 + 2·NR_ITERS)·FMA_LAT (today 2 + 3·FMA_LAT, `:16`); II stays 1.
`fused_coproc_pipe` counts outputs, not cycles (`:180-183`), so it is latency-agnostic.
Forwarded through `ladder_engine_inter` and `fused_coproc_pipe` (`NR_ITERS`).

Accuracy basis, `docs/DIVIDER.md:36-40` (validated numerically before the RTL): TBITS 8
+ 2 iterations → max 1 ULP (1.16e-07 rel.); TBITS 12 + 1 iteration (as built) → max
2 ULP. One NR step squares the seed error (≈ 2^-(TBITS+1) → 2^-(2·TBITS+2)), so one step
needs TBITS ≥ 11–12 for 24-bit precision; two steps need only TBITS ≥ 6–7.

| fp32 option | seed ROM, 8 lanes | extra logic | accuracy | latency |
|---|---|---|---|---|
| TBITS 12, 1 iter (as built) | 8 × 4096 × 23 = **753,664 b** | — | 2 ULP | base |
| TBITS 12, store 14 b/entry | 458,752 b | — | ≈2 ULP | base |
| TBITS 11, 1 iter | 376,832 b | — | ≈4 ULP *(est.)* | base |
| **TBITS 8, 2 iter (recommended)** | 8 × 256 × 23 = **47,104 b** | +2 fp32 FMAs per lane (+16 total, ≈ +160 kGE *(est.)*) | **1 ULP** | +10 cycles per batch |

Decision (author accepted Q4; A9): **TBITS=8, NR_ITERS=2 for the fp32 instance** (better accuracy, −94% ROM,
no ROM macro needed: 5,888 b per lane synthesizes to small logic). The 754 kbit table as
synthesized logic or 8 ROM macros costs on the order of the two extra FMAs or more and
is the larger risk for an open-PDK flow. bf16 stays TBITS=6, NR_ITERS=1 (table 448 b per
lane). The fp32 results change from today's fp32 RTL (not bit-identical; defaults keep
the old behavior). Proof: run_all (NR_ITERS=1 default); T-C7: standalone
`recip_nr_pipe` fp32 TBITS=8 NR_ITERS=2 on ≥ 100,000 random operands plus edge cases
(mantissa sweeps at interval ends, guard band, powers of two): ≤ 1 ULP vs exact
reciprocal of the clamped divisor (Python `fractions`); full fp32 layer with Waveform
coefficients: max_rel < 1e-3 and accuracy delta ≤ 0.02 (`sim/test_fused_bf16.py:171-174`).

### 2.9 Not changed: ε stays a build parameter

A run-time ε (W-bit register + comparator per lane, ≈ 0.3 kGE *(est.)*) is cheap, but it
was **not** added: ε is part of the trained model (the npz stores `eps`), so changing it
changes the function being computed rather than working around a defect; the guard path
is fully testable with injected divisors (§2.6 b); and it would add a port into the
reciprocal's first stage. Exposed read-only as `EPS_BF16`/`EPS_FP32` registers.

---------------------------------------------------------------------------------------

## 3. Overview

### 3.1 Decisions

| # | decision | default | alternative / parameter |
|---|---|---|---|
| D1 | Host link | SPI slave, mode 0, Pi 5 is master, 3.3 V I/O | any rbus master replaces `rondo_spi_slave` |
| D2 | CDC | single clock domain; SPI pins oversampled in `clk_core`; **R ≥ 8 normative**, R = 6 verified corner | §5.6 |
| D3 | Internal interface | `rbus`, 24-bit word address, 32-bit data, valid/ready request and response | §8 |
| D4 | Formats | **both** bf16 and fp32 layers, run-time FORMAT register; shared split-half weight store; inactive layer clock-gated + held in reset | §12 (option c) |
| D5 | Layer type | CoFrNet; KAN as build-time alternative (`LAYER=1`, single format, internal memories) | §13.24 |
| D6 | Readout | all 64 outputs; classification on the Pi | — |
| D7 | Self-run buffer | NXBUF = 4 | 1..16 |
| D8 | Checksum | genesys2 algorithm (`genesys2_fused_top.v:142-177`, `:236`), serial | `CKSUM_PAR=1` |
| D9 | Pads/PLL | none; glitch-free source mux + ICG divider in RTL with cell substitution points | §3.3 |
| D10 | Memories | wrapper-owned (`EXT_MEM=1`) in `rondo_wmem`: the SRAM macro boundary | §7.7 |
| D11 | Stage isolation | injection via existing paths + taps, no new datapath | §2.6 |
| D12 | JTAG | omitted (SPI provides the same access); interface reserved | §11.8 |
| D13 | Wide layers (p > PDIM) | input tiling with full-precision partial sums, bit-identical to an untiled wide build; batch depth TILE_B = 8 | §18 |

### 3.2 Block diagram

```
                                  rondo_chip_top
 clk ──┐  ┌──────────────┐ clk_src ┌───────────┐ clk_core (whole chip)
 clk_alt┴─►│rondo_clk_mux │────────►│rondo_clkdiv│──────────────┬───────────────────────┐
           │ (glitch-free)│         │ (ICG ÷1..8)│              │                       │
           └──────▲───────┘         └─────▲──────┘              │                       │
                  └── CLK_CFG (applied at SPI frame end) ───────┘                       │
 rst_n ─► rondo_reset_sync ─► sys_rst_n                                                 │
                                                                                        │
 spi_sclk/cs_n/mosi ─► ┌──────────────────┐  rbus  ┌──────────────── rondo_dev ───────┐ │
 spi_miso/miso_oe ◄─── │ rondo_spi_slave  │◄──────►│ rondo_rbus_arb ◄── rondo_kat     │ │
                       │ sync, PHY, frames│        │   │              ◄── rondo_mbist │ │
                       │ loopback, CRC-8  │        │ decode                            │ │
                       └──────────────────┘        │  ├ rondo_regs (CSR, irq, status) │ │
                                                   │  ├ XBUF[NXBUF] (32-bit elements) │ │
                                                   │  ├ ZBUF (RO)                     │ │
                                                   │  ├ rondo_trace (64×64 b)         │ │
                                                   │  ├ rondo_dbgmux                  │ │
                                                   │  ├ rondo_wpack ─► rondo_wmem ◄───┼─┤ SRAM macro
                                                   │  │   (H half: bf16 / fp32 hi,    │ │ boundary
                                                   │  │    L half: fp32 lo)           │ │
                                                   │  ├ rondo_seq (launch, self-run,  │ │
                                                   │  │   counters, cksum, wdog)      │ │
                                                   │  └ rondo_layers                  │ │
                                                   │      ICG─ fused_coproc_pipe bf16 │ │
                                                   │      ICG─ fused_coproc_pipe fp32 │ │
                                                   └──────────────────────────────────┘ │
 irq, busy, st_pass, clkout ◄── registered outputs                                      │
 bist_en (strap), test_mode (SCAN=1 only) ──────────────────────────────────────────────┘
```

### 3.3 Clocks

* **Source mux** `rondo_clk_mux`: selects `clk` (SRC=0) or `clk_alt` (SRC=1). Standard
  glitch-free structure: per input, a 2-flop synchronizer clocked on the falling edge of
  that input enabling an AND gate; each enable is qualified by the other's disable
  (cross-coupled), outputs ORed. Switching requires both clocks running. `sys_rst_n` = 0
  asynchronously forces SRC=0 (the `clk` enable flops set, `clk_alt` flops cleared), so
  a dead `clk_alt` is recoverable by `rst_n`. In `test_mode` the mux is bypassed to
  `clk`. Cell substitution: the implementer writes it behaviorally in one module so the
  flow can swap in a library clock-mux cell.
* **Divider** `rondo_clkdiv`: `clk_core = ICG(clk_src, en)`, where `en` is 1 every N-th
  cycle of `clk_src`, N ∈ {1, 2, 4, 8} (CLK_CFG.DIV). The ICG (latch-based clock gate,
  behavioral model `rondo_icg`, substituted by the library ICG cell) makes the output
  glitch-free; the duty cycle of `clk_core` at N>1 is one `clk_src` high phase per N
  periods, which is fine for an all-posedge design. Divider changes take effect at a
  counter wrap. In `test_mode` the divider is forced to N=1.
* **CLK_CFG application**: a write to CLK_CFG is held pending and applied when the SPI
  frame that carried it ends (CS_N rises) and the chip is not ACTIVE; writes while
  ACTIVE are rejected (`ERR_STATUS.BUSY_WR`). After the change the host must use
  f_SCLK ≤ f_core_new / 8 (§14.3).
* **Layer clock gates**: each layer instance has its own ICG on `clk_core`:
  enabled = (instance is active per FORMAT) && !PWR_CTRL.CORE_CLK_OFF. In `test_mode`
  all ICGs are transparent (enable forced 1).
* **CLKOUT**: `clkout` = a toggle flop chain on `clk_core`: f_core / 2^k for
  CLKOUT_CFG.K = k ∈ 1..15, constant 0 for k = 0 (reset default: off, so it adds no
  switching noise during power measurement). It is a data output, not a clock net.
* **STA modes**: bf16 mode at f_core; fp32 mode at the fp32 datapath's achievable
  frequency. If F_CLK_HZ exceeds the fp32 datapath's limit, the host selects DIV=2 for
  fp32 (the project's ASAP7 lane synthesis gave ≈ 1.19 GHz bf16 vs ≈ 767 MHz fp32, a
  ratio of ≈ 1.55, below 2). Sign-off uses case analysis on FORMAT (inactive layer's clock off).

### 3.4 Resets

* `rst_n` pin → `rondo_reset_sync` (async assert, sync deassert after SYNC_STAGES=2
  edges of `clk_core`) → `sys_rst_n`. In `test_mode`, `sys_rst_n` = `rst_n` directly
  (reset controllable by the tester).
* Per layer `core_rst_n[f]` (f = bf16, fp32): flop output in `rondo_seq`,
  asynchronously cleared by `sys_rst_n`, low while any of: soft reset (8 cycles), the
  layer is inactive per FORMAT, PWR_CTRL.CORE_HOLD = 1. On a FORMAT switch the newly
  active layer's reset is released 2 cycles after its clock gate is enabled (so the
  async-reset release is seen with a running clock); the newly inactive layer is put
  into reset first and its clock gated 2 cycles later.
* Clock-source/divider changes do not reset anything.

---------------------------------------------------------------------------------------

## 4. Pin list of `rondo_chip_top`

| # | pin | dir | function |
|---|---|---|---|
| 1 | `clk` | in | primary clock (oscillator), default 50 MHz (`F_CLK_HZ`) |
| 2 | `clk_alt` | in | alternate clock (harness PLL or Pi 5 GPCLK); tie low if unused |
| 3 | `rst_n` | in | asynchronous active-low hard reset |
| 4 | `spi_sclk` | in | SPI clock (mode 0, idle low) |
| 5 | `spi_cs_n` | in | SPI chip select, active low; harness pull-up |
| 6 | `spi_mosi` | in | SPI data in; scan_in in test_mode |
| 7 | `spi_miso` | out | SPI data out; tri-stated via `spi_miso_oe` when CS deselected (A5); scan_out in test_mode |
| 8 | `irq` | out | level, active high: `|(IRQ_STATUS & IRQ_EN)` — the DONE pin |
| 9 | `busy` | out | `STATUS.ACTIVE`; energy-measurement window; also high while KAT/MBIST run |
| 10 | `st_pass` | out | self-test result: 1 = last KAT (and MBIST if built) passed; valid when `busy` = 0 after a self-test; 0 after reset until a self-test passes |
| 11 | `bist_en` | in | strap: if 1 when `sys_rst_n` releases, run MBIST (if built) then KAT for both formats automatically; scan_en in test_mode; pull-down |
| 12 | `clkout` | out | divided `clk_core` (CLKOUT_CFG), default off |
| 13 | `test_mode` | in | only if `SCAN=1`: scan test mode (§11.7); pull-down |
| — | `spi_miso_oe` | out | pad enable for `spi_miso` (not a package pin; harness pad control) |
| — | `pg_req[1:0]` | out | only if `PG=1`: power-switch request per layer (harness) |

**12 signal pins** in the default build (13 with SCAN=1), plus supplies:
`VDD_CORE` (logic), `VDD_SRAM` (memory macros, separate if the PDK's macros allow, else
tied to VDD_CORE in the harness), `VDDIO` 3.3 V, `VSS`. All outputs come from flops.
`clkout`, `irq`, `busy`, `st_pass` drive 0 during reset.

---------------------------------------------------------------------------------------

## 5. SPI protocol

### 5.1 Electrical / mode

SPI mode 0 (CPOL=0, CPHA=0); MSB first; 8-bit bytes; CS_N active low, frames delimited
by CS_N. The chip changes MISO after it detects a rising SCLK edge (bit n+1 presented
once bit n was sampled), giving almost a full SCLK period of setup. Byte order
**big-endian** for address, length and data.

### 5.2 Frames

A = 24-bit word address; N = 16-bit length; the burst moves N+1 words.

| opcode | name | MOSI after opcode | MISO |
|---|---|---|---|
| `0x02` | WRITE | A[23:16], A[15:8], A[7:0], N[15:8], N[7:0], [HCRC], then (N+1) × {D[31:24], D[23:16], D[15:8], D[7:0], [DCRC]} | 0x00 |
| `0x03` | READ | A (3 B), N (2 B), [HCRC], 1 dummy byte, then (N+1) × (4 [+1]) don't-care bytes | 0x00 for header/dummy; then each word big-endian [followed by its DCRC] |
| `0x05` | STATUS | any number of bytes | MISO byte 0 = 0x00 (the opcode byte), then each following byte = STATUS8 (sampled at the start of the byte); also handled in `rondo_spi_phy` |
| `0x0E` | LOOPBACK | any number of bytes | byte k+1 on MISO = byte k received on MOSI (first byte 0x00). Handled in the byte paths of `rondo_spi_phy` (the only place that meets the byte timing); works before any register or rbus logic. |
| `0x00`, `0xFF` | NOP | ignored | 0x00 |
| other | — | ignored until CS_N rises; `ERR_STATUS.SPI_FRAME` | 0x00 |

[HCRC]/[DCRC] are present only when SPI_CFG.CRC_EN = 1 (§5.4).

STATUS8: [7] ERR_ANY (`ERR_STATUS & ERR_MASK != 0`), [6] IRQ pin level, [5] SR_RUNNING,
[4] ACTIVE, [3] BUSY (active layer `busy`), [2] FORMAT, [1:0] constant `2'b10`
(stuck-MISO detection).

### 5.3 Rules

1. A WRITE word is issued on rbus when its last data bit (or, with CRC, its DCRC byte
   after a successful check) has been sampled.
2. A READ issues the rbus read for word 0 when the header (and HCRC) is complete; the
   dummy byte (≥ 64 `clk_core` cycles at R=8) covers the latency. Word n+1 is requested
   only after word n was loaded into the shift register; **exactly N+1 reads** are
   issued. Bytes clocked beyond the burst return 0 and cause no access.
3. CS_N rising on a word boundary shortens the burst without error; mid-header or
   mid-word: the partial header/word is discarded, `ERR_STATUS.SPI_FRAME`.
4. While CS_N is high the PHY is idle and `spi_miso_oe` = 0 (A5).
5. Overrun (a write response or read word not available in time) sets
   `ERR_STATUS.SPI_FRAME`; a read shifts 0xDEADBEEF for that word. Impossible at R ≥ 6
   with the rbus bound of §8.3; it exists so a timing violation is visible.
6. rbus error responses do not alter the frame; they appear in ERR_STATUS/STATUS8.
7. A CLK_CFG change is applied after CS_N rises (§3.3).

### 5.4 Optional CRC-8 (SPI_CFG.CRC_EN, reset 0)

CRC-8, polynomial x⁸+x²+x+1 (0x07), init 0x00, no reflection, no final XOR
(check value: `crc8(b"123456789") == 0xF4`). Takes effect from the next frame.
* HCRC: one byte after the length field, over the 6 bytes opcode..N[7:0]. If wrong: the
  rest of the frame is ignored, `ERR_STATUS.SPI_CRC`.
* WRITE: a DCRC byte follows each 4-byte data word, over those 4 bytes. If wrong: that
  word and all following words of the frame are dropped, `ERR_STATUS.SPI_CRC`.
* READ: the chip appends a DCRC byte (over the 4 bytes just sent) after each word.
* STATUS, LOOPBACK, NOP: no CRC bytes.

### 5.5 Examples (CRC off)

Register write SCRATCH (0x000009) ← 0xA5A55A5A:
```
MOSI: 02 00 00 09 00 00 A5 A5 5A 5A
```
Burst weight load of lane 0 (2,240 words at 0x800000, N = 0x08BF; one element per word,
in order addr 0 f 0..7, addr 1 f 0..7, …; bf16 `00 00 hi lo`, fp32 `b3 b2 b1 b0`):
```
MOSI: 02 80 00 00 08 BF  <2,240 × 4 bytes>
```
Lanes 1..7 at 0x801000, 0x802000, … (stride 4096). Biases: 56 words per lane at
0x100000 + lane·64. Burst read of z (64 words at 0x020000):
```
MOSI: 03 02 00 00 00 3F 00 | 00 × 256
MISO: 00 00 00 00 00 00 00 | z0 (4 B) z1 (4 B) ...
```
spidev's default transfer limit is 4,096 bytes per ioctl (`bufsiz` module parameter);
the host splits bursts at word boundaries into separate frames (rule 3) or raises
`bufsiz`.

### 5.6 Maximum SCLK and the oversampling ratio

Worst case from a real rising SCLK edge to the next MISO bit: 2 synchronizer flops (up
to 2 cycles + up to 1 cycle phase) + 1 edge detect + 1 output flop = **≤ 4 cycles of
`clk_core`**; it must precede the master's next rising edge (one SCLK period) minus pad,
board and Pi input setup. Inputs alone need R ≥ 4 (each SCLK phase ≥ 2 cycles); MISO
needs R > 4 plus margin, which is zero at R = 4 — hence the author's 4× preference is
tightened to:

* **Normative: f_SCLK ≤ f_core / 8**, where f_core is the divided clock. Verified also at
  R = 6 with random phase.
* CS_N falling to first SCLK edge ≥ one SCLK half-period (Pi spidev satisfies this).

The alternative (SCLK-clocked shift register + handshake CDC) allows f_SCLK ≈ f_core/2
but adds a second clock domain; rejected because link speed is not a concern. A full
weight load (18,368 words ≈ 0.6 Mbit) takes ≈ 0.12 s at 5 MHz.

---------------------------------------------------------------------------------------

## 6. Register map

Word addresses on rbus (byte address = word address × 4 for byte-addressed adapters).
All registers 32 bits. Unlisted addresses in 0x000000–0x0000FF read 0 and set
`ERR_STATUS.ADDR`; writes are ignored and set `ERR_STATUS.ADDR`.
Access: RW; RO (write ignored, sets `ERR_STATUS.RO`); W1C; WO/SC (self-clearing command
bits, read 0). "Blocked while ACTIVE" means the write is dropped with
`ERR_STATUS.BUSY_WR`.

### 6.1 Summary

| addr | name | access | reset | description |
|---|---|---|---|---|
| 0x00 | CHIP_ID | RO | `0x524F4E44` | ASCII "ROND" |
| 0x01 | VERSION | RO | `0x00020101` | [31:16] major, [15:8] minor, [7:0] patch → v2.1.1 (the pre-fix wrapper reads `0x00020100`) |
| 0x02 | CAPS | RO | build | features (§6.2) |
| 0x03 | GEOM0 | RO | build | [15:0] WIDTH (64), [31:16] PDIM (40) |
| 0x04 | GEOM1 | RO | build | [7:0] DEPTH (7), [15:8] N_LANES (8), [23:16] NSLOT (8), [31:24] NPAR (8) |
| 0x05 | GEOM2 | RO | build | [7:0] NXBUF (4), [15:8] WAW (9), [23:16] BAW (3), [31:24] LNW (3) |
| 0x06 | GEOM3 | RO | build | [7:0] ACCSIG_BF16, [15:8] FMA_LAT, [19:16] TBITS_BF16, [23:20] TBITS_FP32, [27:24] NR_ITERS_BF16, [31:28] NR_ITERS_FP32 |
| 0x07 | EPS_BF16 | RO | `0x00003C24` | ε of the bf16 layer |
| 0x08 | EPS_FP32 | RO | `0x3C23D70A` | ε of the fp32 layer |
| 0x09 | SCRATCH | RW | 0 | free |
| 0x0A | CTRL | WO/SC | 0 | commands (§6.3) |
| 0x0B | STATUS | RO | see §6.4 | live status |
| 0x0C | IRQ_STATUS | W1C | 0 | [0] DONE, [1] SR_DONE, [2] ERR (RO mirror of `ERR_STATUS & ERR_MASK != 0`), [3] TRC_DONE, [4] SELFTEST_DONE, [5] TILE_SLICE_DONE, [6] TILE_FINAL_DONE (§18.5) |
| 0x0D | IRQ_EN | RW | `0x7F` | enables for IRQ_STATUS[6:0] |
| 0x0E | ERR_STATUS | W1C | 0 | sticky errors (§6.5) |
| 0x0F | ERR_MASK | RW | `0xFFFFFDFF` | which ERR bits count for ERR_ANY/IRQ.ERR (GUARD bit 9 masked by default) |
| 0x10 | FORMAT | RW, blocked while ACTIVE | 0 | [0] 0 = bf16, 1 = fp32. Values > 1: `RANGE`. Switch effects §12.4 |
| 0x11 | XSEL | RW | 0 | XBUF entry for START; ≥ NXBUF → `RANGE` |
| 0x12 | SR_N | RW | 1 | self-run loop entries 1..NXBUF, else `RANGE` |
| 0x13 | SR_COUNT | RW | 0 | self-run inference count; 0 = until SR_STOP |
| 0x14 | WDOG_LIMIT | RW | 0 | watchdog cycles per inference; 0 = off |
| 0x15 | LANE_EN | RW, blocked while ACTIVE | all ones `[N_LANES-1:0]` | lane-enable mask (C6) for both layers |
| 0x16 | CLK_CFG | RW, blocked while ACTIVE, applied at frame end | 0 | [1:0] DIV (0 ÷1, 1 ÷2, 2 ÷4, 3 ÷8), [4] SRC (0 `clk`, 1 `clk_alt`); RO readback of the applied value in [17:16] DIV_APPLIED, [20] SRC_APPLIED |
| 0x17 | CLKOUT_CFG | RW | 0 | [3:0] K: `clkout` = f_core / 2^K, 0 = off |
| 0x18 | PWR_CTRL | RW, blocked while ACTIVE (`BUSY_WR`) and while a tile sequence is OPEN (`TILE_SEQ`) | 0 | [0] CORE_HOLD (both layers in reset), [1] CORE_CLK_OFF (both layer clocks gated), [2] PG_INACTIVE (assert `pg_req` for the inactive layer; PG=1 builds only) |
| 0x19 | SPI_CFG | RW | 0 | [0] CRC_EN (from next frame) |
| 0x20 | LAST_CYCLES | RO | 0 | §10.3 |
| 0x21/0x22 | INFER_CNT_LO/HI | RO | 0 | 64-bit; LO read latches HI |
| 0x23/0x24 | BUSY_CYC_LO/HI | RO | 0 | 64-bit |
| 0x25/0x26 | TOTAL_CYC_LO/HI | RO | 0 | 64-bit |
| 0x27/0x28 | SR_CYC_LO/HI | RO | 0 | 64-bit |
| 0x29 | SR_DONE_CNT | RO | 0 | |
| 0x2A | CHECKSUM | RO | 0 | §10.5 |
| 0x2B | SR_PASS_CKSUM | RO | 0 | |
| 0x2C | LOAD_CRC | RO | 0 | §7.6 |
| 0x2D | GUARD_HITS | RO | 0 | pole-guard hits (C2) |
| 0x2E | NANINF_CNT | RO | 0 | NaN/Inf output elements in enabled lanes |
| 0x30 | DBG_SEL | RW | 0 | [3:0] lane, [6:4] sig, [15:8] idx, [17:16] live_sel, [24] fmt_override_en, [25] fmt_override (observe the inactive layer's frozen state) |
| 0x31 | DBG_DATA | RO | 0 | value latched 4 cycles after a DBG_SEL write or CTRL.DBG_LATCH |
| 0x38 | TRC_CFG | RW, blocked while trace armed | 0 | §11.3 |
| 0x39 | TRC_TRIG_CYC | RW | 0 | cycle-count trigger value |
| 0x3A | TRC_STATUS | RO | 0 | [0] ARMED, [1] TRIGGERED, [2] DONE, [15:8] NVALID, [23:16] TRIG_IDX |
| 0x40 | ST_STATUS | RO | 0 | self-test: [0] RUNNING, [1] DONE, [2] PASS (= `st_pass`), [3] KAT_BF16_PASS, [4] KAT_FP32_PASS, [5] MBIST_PASS (1 if MBIST not built), [6] AT_RESET (started by `bist_en`), [7] KAT_BF16_RAN, [8] KAT_FP32_RAN |
| 0x41 | KAT_SIG_BF16 | RO | build | expected bf16 KAT signature |
| 0x42 | KAT_SIG_FP32 | RO | build | expected fp32 KAT signature |
| 0x43 | KAT_GOT_BF16 | RO | 0 | measured |
| 0x44 | KAT_GOT_FP32 | RO | 0 | measured |
| 0x48 | MBIST_STATUS | RO | 0 | [0] RUNNING, [1] DONE, [2] FAIL, [6:4] fail lane, [7] fail half (0 H, 1 L), [8] fail is bias, [12:9] march element, [31:16] fail count (saturating) |
| 0x49 | MBIST_FAIL_ADDR | RO | 0 | first failing core address |
| 0x4A | MBIST_FAIL_XOR | RO | 0 | first failing word XOR expected, folded to 32 b |
| 0x50–0x54 | TILE_CFG, TILE_STATUS, TILE_SEQ_CRC, TILE_GEOM, TILE_SLICE | see §18.5 | | input tiling |

### 6.2 CAPS (0x02)

| bit | field | default build |
|---|---|---|
| 0 | HAS_BF16 | 1 |
| 1 | HAS_FP32 | 1 |
| [3:2] | LAYER (0 CoFrNet, 1 KAN) | 0 |
| 4 | HAS_BIAS | 1 |
| 5 | GUARD (C2) | 1 |
| 6 | CKSUM_PAR | 0 |
| 7 | READBACK (C3) | 1 |
| 8 | DBG (C4) | 1 |
| 9 | TRACE | 1 |
| 10 | KAT | 1 |
| 11 | MBIST | 0 |
| 12 | SCAN | 0 |
| 13 | LANE_MASK (C6) | 1 |
| 14 | SPI_CRC | 1 |
| 15 | CLK_ALT (source mux) | 1 |
| 16 | PG | 0 |
| 17 | TILE (C8) | 1 |
| [31:18] | reserved, 0 | |

### 6.3 CTRL (0x0A), self-clearing, reads 0

Priority within one write: SOFT_RST (others ignored) > clears (4, 5, 6, 12) > SR_STOP >
other starts (at most one of START, SR_START, KAT_START, MBIST_START is honored, in that
order of precedence; the rest set `START_BUSY`).

| bit | name | effect |
|---|---|---|
| 0 | START | single-shot inference on XBUF[XSEL]; if ACTIVE: ignored, `START_BUSY` |
| 1 | SOFT_RST | soft reset (§9.6) |
| 2 | SR_START | start self-run (§9.4); if ACTIVE: `START_BUSY` |
| 3 | SR_STOP | stop self-run after the in-flight inference |
| 4 | CNT_CLR | clear INFER_CNT, BUSY_CYC, TOTAL_CYC, LAST_CYCLES |
| 5 | CKSUM_CLR | clear CHECKSUM, SR_PASS_CKSUM |
| 6 | CRC_CLR | clear LOAD_CRC |
| 7 | KAT_START | run the KAT for the current FORMAT (§11.5); overwrites weights and XBUF; refused with `START_BUSY` while PWR_CTRL.CORE_HOLD or CORE_CLK_OFF = 1 (with MBIST=1, MBIST runs first, §9.8) |
| 8 | MBIST_START | run MBIST (§11.6; MBIST=1 builds); overwrites weights; allowed with CORE_HOLD/CORE_CLK_OFF (MBIST does not use the layers) |
| 9 | TRC_ARM | arm the trace buffer |
| 10 | TRC_FORCE | force the trace trigger now |
| 11 | DBG_LATCH | re-latch DBG_DATA |
| 12 | GUARD_CLR | clear GUARD_HITS and NANINF_CNT |
| 13 | TILE_RUN | run the current input slice for TBATCH inputs (§18.6) |
| 14 | TILE_ABORT | close the tile sequence, invalidate partial sums (§18.6) |

### 6.4 STATUS (0x0B), RO

| bit | name | meaning |
|---|---|---|
| 0 | BUSY | active layer `busy` |
| 1 | ACTIVE | §7.2 |
| 2 | SR_RUNNING | self-run in progress |
| 3 | SR_STOPPING | SR_STOP accepted |
| 4 | ZVALID | ZBUF holds a result produced in the current FORMAT |
| 5 | SOFT_RST | soft reset in progress |
| 6 | HEARTBEAT | bit `HB_BIT` (default 24) of a free-running counter that no clear affects; toggles every 2^24 cycles (0.34 s at 50 MHz) |
| 7 | WSTALE | weights invalid for the current FORMAT: set by reset, FORMAT switch, KAT, MBIST; cleared by the first accepted WEIGHT write after that |
| 8 | FORMAT | applied format |
| 9 | KAT_RUNNING | |
| 10 | MBIST_RUNNING | |
| 11 | TRC_ARMED | |
| [15:12] | XPTR | XBUF entry of the in-flight / last inference |
| [23:16] | LANE_EN_APPLIED | lane mask in use |
| 31 | ERR_ANY | `ERR_STATUS & ERR_MASK != 0` |

### 6.5 ERR_STATUS (0x0E), W1C, sticky

| bit | name | set when |
|---|---|---|
| 0 | BUSY_WR | external write to WEIGHT/BIAS/XBUF/FORMAT/LANE_EN/CLK_CFG/PWR_CTRL while ACTIVE, or external WEIGHT/BIAS read while ACTIVE (returns 0) |
| 1 | ADDR | unmapped address or out-of-range element (§7.1) |
| 2 | RO | write to an RO register, ZBUF or TRACE |
| 3 | START_BUSY | a start command while ACTIVE, or more than one start bit in one write, or KAT_START while PWR_CTRL.CORE_HOLD/CORE_CLK_OFF = 1 |
| 4 | PARTIAL | core word committed with missing fields, or staging tag changed with fields pending (§7.6) |
| 5 | RANGE | illegal value to XSEL, SR_N, FORMAT (register unchanged) |
| 6 | SPI_FRAME | unknown opcode, CS abort mid-header/word, overrun |
| 7 | WDOG | an inference exceeded WDOG_LIMIT cycles (flag only) |
| 8 | NAN_INF | a captured output element of an enabled lane is NaN or ±Inf |
| 9 | GUARD | at least one pole-guard hit (masked in ERR_MASK by default: guard hits are normal near poles) |
| 10 | SPI_CRC | HCRC/DCRC mismatch |
| 11 | KAT_FAIL | a KAT signature mismatched |
| 12 | MBIST_FAIL | MBIST found a failure |
| 13 | WSTALE_RUN | START/SR_START while STATUS.WSTALE = 1 (the inference still runs) |
| 14 | TILE_SEQ | illegal command for the tile state (§18.6) |
| 15 | TILE_STALE | partial sums missing/wrong slice tag, or an open tile sequence was invalidated (§18.6) |

### 6.6 Read side effects and atomicity

Reading a `*_LO` register copies its pair's [63:32] into that pair's shadow in the same
cycle; `*_HI` returns the shadow (read LO then HI; a 2-word READ burst does this). No
other read has side effects. CTRL writes take effect the cycle after the rbus handshake.
XSEL, SR_N, SR_COUNT, LANE_EN are sampled at launch / SR_START.

---------------------------------------------------------------------------------------

## 7. Memory map

### 7.1 Regions (24-bit word address; identical for both formats)

FW = log2(NPAR) (NPAR must be a power of two, elaboration check); XW = clog2(PDIM).

Elaboration checks (`rondo_dev`, generate-if with `$fatal`, so that `verilator --lint-only`, Icarus and Yosys reject the build):
NPAR a power of two; LNW+WAW+FW ≤ 23; LNW+BAW+FW ≤ 16 (LAYER 0); clog2(NXBUF)+XW ≤ 16; 2·TRACE_DEPTH ≤ 65536 (TRACE=1);
NGROUP·PDIM > WIDTH+8 or CKSUM_PAR=1 (§10.1); with TILE active: FW+BAW+LNW+clog2(TILE_B) ≤ 16, clog2(TILE_B)+XW ≤ 16,
clog2(TILE_B)+clog2(WIDTH) ≤ 16 (§18.5) and ACCSIG_BF16 = 8 when HAS_BF16 (§18.3); TBITS_FP32 ∈ {8, 12} (the seed files) and
NR_ITERS_FP32 ∈ {1, 2} when HAS_FP32.

| base | end (default) | name | access | layout |
|---|---|---|---|---|
| 0x000000 | 0x0000FF | registers | §6 | — |
| 0x010000 | 0x0100FF | XBUF | RW; external writes blocked while ACTIVE | `0x010000 + (e << XW) + i`, e < NXBUF, i < PDIM (XW = 6) |
| 0x020000 | 0x02003F | ZBUF | RO | `0x020000 + j`, j < WIDTH |
| 0x030000 | 0x03007F | TRACE | RO | entry k (0 = oldest) at `0x030000 + 2k` (data) and `+ 2k + 1` (meta) (§11.3) |
| 0x040000 / 0x050000 / 0x060000 | — | TX / TZ / PS | RW / RO / RW | input tiling buffers (§18.5) |
| 0x100000 | 0x1001FF | BIAS | RW (read-back C3); blocked while ACTIVE | `0x100000 + (l << (BAW+FW)) + (b_addr << FW) + f` |
| 0x800000 | 0x807FFF | WEIGHT | RW (read-back C3); blocked while ACTIVE | `0x800000 + (l << (WAW+FW)) + (w_addr << FW) + f` |

Elaboration checks: `LNW+WAW+FW ≤ 23`, `LNW+BAW+FW ≤ 16`, `clog2(NXBUF)+XW ≤ 16`,
`2·TRACE_DEPTH ≤ 65536`. Holes (w_addr ≥ NWORDS, b_addr ≥ NBWORDS, i ≥ PDIM,
e ≥ NXBUF, trace k ≥ TRACE_DEPTH): write dropped / read 0, `ERR_STATUS.ADDR`.
Each element is in bits [W-1:0] of its word, W per the **current** FORMAT; reads return
the element zero-extended.

### 7.2 ACTIVE

ACTIVE = the sequencer (including a TILE_RUN), KAT or MBIST is not idle, or soft reset or a FORMAT switch is in
progress: from the cycle a start command is accepted until the last capture/checksum of
that operation completes. ACTIVE blocks external writes (and weight/bias reads) to the
memories, guaranteeing §1.3.2/1.3.3; internal masters (KAT, MBIST) are exempt.

### 7.3 Input buffers (XBUF)

NXBUF × PDIM elements of **32-bit** flops (fp32 width; bf16 uses [15:0]) = 4 × 40 × 32 =
5,120 flops. Active layer `x` = XBUF[xptr] (bf16: low halves), `xptr` updated only in the
launch cycle. Entry 0 is the conventional single-shot input. Cleared to 0 on a FORMAT
switch and at hard reset.

### 7.4 Output buffer (ZBUF)

WIDTH × 32-bit flops (2,048), loaded from the active layer's `z` in the `done` cycle.
Changes only at a capture; torn reads are possible during a self-run. Cleared by soft
reset and FORMAT switch.

### 7.5 Read-back

WEIGHT/BIAS reads (not ACTIVE) return the stored element: `rondo_wmem` reads the core
word and `rondo_wpack` keeps a one-entry read cache (tag = {region, lane, addr}) so a
burst over the NPAR fields reads the memory once. Latency ≤ 4 cycles (§8.3). In bf16
mode the H half is returned; in fp32 mode {H, L}.

### 7.6 Weight/bias packing in `rondo_wpack` and LOAD_CRC

* Decode by bit slicing (§7.1) to region, lane l, core address a, field f.
* State: staging `stg[NPAR × 32]`, mask `msk[NPAR]`, tag {region, l, a}.
* Accepted write: (1) if `msk ≠ 0` and tag differs: `PARTIAL`, clear `msk`/`stg`;
  (2) `stg[f] ← wdata[W-1:0]`, `msk[f] ← 1`; (3) if f = NPAR−1: commit the core word to
  `rondo_wmem` (lane l, address a) — bf16: H half ← the 16-bit fields; fp32: H ← bits
  [31:16] of each field, L ← bits [15:0] — set `PARTIAL` if any of fields 0..NPAR−2 was
  missing (the commit still happens, missing fields 0), clear `msk`, invalidate the read
  cache.
* The natural ascending burst (§5.5) reproduces `gen_genesys2_rom.py:63-74` /
  `genesys2_fused_top.v:197-222` bit for bit.
* LOAD_CRC: CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320, init 0xFFFFFFFF, final XOR
  0xFFFFFFFF) over the W/8 bytes of every accepted WEIGHT/BIAS write data, LSB first, in
  acceptance order: equals `zlib.crc32(b"".join(v.to_bytes(W//8, "little") for v in
  values))`, 0 when empty. Cleared by CTRL.CRC_CLR, hard reset, FORMAT switch, KAT,
  MBIST. Not cleared by soft reset.

### 7.7 Physical weight store `rondo_wmem` (macro boundary)

Per lane: weight store H (NWORDS × NPAR·16 = 280 × 128 b) and L (280 × 128 b); bias
store H and L (7 × 128 b each, flops). The bf16 layer reads H only; the fp32 layer
reads {H, L} per element (`{H[f], L[f]}` = fp32 element f). Single port per macro:

* address = active layer's `wm_addr[l]` when that layer's `mem_act[l]` = 1, else the
  wrapper port (wpack, read-back, MBIST);
* chip enable: H when (mem_act or wrapper access); L only when FORMAT = fp32 (or
  MBIST/fp32 wrapper access) — so **in bf16 mode the L macros are never enabled** and
  bf16 SRAM energy equals a bf16-only design;
* write enable only from the wrapper port, never while ACTIVE (except MBIST/KAT);
* registered read data → `wm_q` (§2.4).

`rondo_wmem` instantiates `rondo_sram_sp #(DEPTH, WIDTH)` (behavioral: `q <= mem[a]`
on enabled cycles, write when `we`), the **only** place foundry macros are substituted
(280 → 512-deep macros waste 45%; 320 or 2×256 configurations if the compiler allows).
Lane-disabled memories (C6) are never enabled.

---------------------------------------------------------------------------------------

## 8. Internal bus-agnostic interface (`rbus`)

### 8.1 Signals (master = adapter/arbiter, slave = `rondo_dev` decode)

| signal | width | from master | meaning |
|---|---|---|---|
| `rb_req_valid` | 1 | out | request valid |
| `rb_req_ready` | 1 | in | accepted |
| `rb_req_we` | 1 | out | 1 write, 0 read |
| `rb_req_addr` | 24 | out | word address |
| `rb_req_wdata` | 32 | out | write data |
| `rb_req_int` | 1 | out | 1 = internal master (KAT/MBIST): exempt from ACTIVE blocking. Driven only by `rondo_rbus_arb`; the external port of `rondo_dev` ties it to 0 |
| `rb_rsp_valid` | 1 | in | response valid |
| `rb_rsp_ready` | 1 | out | response accepted |
| `rb_rsp_rdata` | 32 | in | read data (0 for writes) |
| `rb_rsp_err` | 1 | in | this access set an ERR_STATUS bit |

### 8.2 Handshake rules

1. Transfer on a rising edge with `valid && ready`.
2. `valid` must not depend combinationally on `ready`; once high, payload stable and
   `valid` held until the transfer.
3. `ready` may depend on `valid`.
4. One response per request, in order; the slave accepts one outstanding request.
5. All `valid` = 0 during reset.
6. An accepted request is always answered, also across soft reset (§9.6): a soft reset cancels internal-master (KAT/MBIST) requests that are not yet
   accepted (`rondo_rbus_arb` drops them when `srst` is high or the master's `valid` falls); an internal weight read cut by the soft reset answers 0 with `rsp_err`.
   The external master's response is held (`rsp_valid` stays high) while `rsp_ready` = 0, also during the soft reset.

### 8.3 Timing guarantee

`rondo_rbus_arb` gives the external master priority; an internal master holds at most
one ≤ 4-cycle access. The slave responds ≤ 4 cycles after acceptance for registers and XBUF; an uncached WEIGHT/BIAS read-back takes up to 8 cycles
(the SVA bound is 10). It holds `req_ready` = 0 for ≤ 12 cycles during soft reset; a request accepted before the soft reset is still answered
(§8.2 rule 6). **Any external access completes within 24 cycles** of `rb_req_valid` rising when `rsp_ready` = 1 (measured maximum: 11 for registers). The SPI adapter's
budget is ≥ 48 cycles (dummy byte at R ≥ 6).

### 8.4 Mapping to other buses (informative)

AXI4-Lite: ADDR[25:2] → `rb_req_addr`, AW+W → one request, B/R from the response,
`rb_rsp_err` → SLVERR. Wishbone classic: CYC&STB → req_valid, ACK ← rsp_valid. An
AXI4-Stream weight ingest converts the stream into WRITE bursts at the WEIGHT base.

---------------------------------------------------------------------------------------

## 9. Operation sequences

`W(a,d)` register write, `R(a)` read, `BW(a,[..])` burst write, `BR(a,n)` burst read.

### 9.1 Power-up / bring-up ladder (each step needs less of the chip than the next)

1. Supplies up, `clk` running, `rst_n` low ≥ 1 µs, release (`bist_en` = 0).
2. `clkout` is off; `busy`/`irq` low.
3. **LOOPBACK** (0x0E): send 16 random bytes; MISO must return them shifted by one byte.
   Proves SCLK/MOSI/MISO/CS and the SPI PHY without any register logic.
4. **STATUS** (0x05): `STATUS8[1:0] == 2'b10`, bits 7..3 = 0.
5. `R(CHIP_ID) == 0x524F4E44`, `R(VERSION) == 0x00020101` (the host warns for a lower value: pre-fix wrapper without the PWR_CTRL/KAT refusal rules); read CAPS, GEOM0..3, EPS_*.
6. SCRATCH write/read 0xA5A55A5A and 0x5A5AA5A5.
7. Heartbeat: read STATUS twice ≥ 2^25 cycles apart; bit 6 toggles.
8. `W(CLKOUT_CFG, 10)`: `clkout` = f_core/1024 measurable on a scope / Pi GPIO; then 0.
9. Optional self-test: `W(CTRL, KAT_START)` per format (§9.8).
10. `W(ERR_STATUS, 0xFFFFFFFF)`.

### 9.2 Weight load (current FORMAT)

1. `W(CTRL, CRC_CLR)`.
2. Per lane: `BW(0x800000 + (l<<12), 2,240 words)`; `BW(0x100000 + (l<<6), 56 words)`.
3. `R(LOAD_CRC)` = host CRC; `R(ERR_STATUS)` = 0; STATUS.WSTALE = 0.
4. Optional: read back all weights (`BR`) and compare.

### 9.3 Single inference

1. `BW(0x010000 + (e<<6), PDIM words)`; `W(XSEL, e)`.
2. `W(IRQ_STATUS, 1)`; `W(CTRL, START)`.
3. Wait for `irq` (gpiod edge) or poll STATUS.ACTIVE = 0.
4. `BR(0x020000, 64)`; `R(LAST_CYCLES)`; `W(IRQ_STATUS, 1)`.

### 9.4 Self-run benchmark

1. Load n ≤ NXBUF inputs; `W(SR_N, n)`; `W(SR_COUNT, K)` (0 = until stopped);
   `W(CTRL, CNT_CLR)`.
2. `W(CTRL, SR_START)`: clears CHECKSUM, SR_PASS_CKSUM, SR_DONE_CNT, SR_CYC; launches
   XBUF[0..n−1] cyclically back to back (§10.1); `busy` high throughout. Runs in the
   current FORMAT.
3. Measure rails (§14.6); the link may idle.
4. End when SR_DONE_CNT = K (K ≠ 0) or after `W(CTRL, SR_STOP)` (in-flight inference
   completes and counts); SR_DONE set, `irq` rises.
5. Read SR_DONE_CNT, SR_CYC, CHECKSUM, SR_PASS_CKSUM, BUSY_CYC, INFER_CNT, GUARD_HITS,
   ZBUF. Throughput = SR_DONE_CNT · f_core / SR_CYC. Expected CHECKSUM from per-entry z
   via §10.5.

### 9.5 FORMAT switch

1. Wait until not ACTIVE. `W(FORMAT, f)`.
2. The chip (ACTIVE during the switch, ≤ 16 cycles): puts the old layer in reset and
   gates its clock, enables the new layer's clock then releases its reset (§3.4),
   clears XBUF, ZBUF, CHECKSUM, SR_PASS_CKSUM, LAST_CYCLES, LOAD_CRC, sets
   STATUS.WSTALE. Cumulative counters (INFER_CNT, BUSY_CYC, TOTAL_CYC), configuration
   registers, LANE_EN, CLK_CFG and the trace configuration are kept.
3. Host: adjust CLK_CFG.DIV if the format needs it (§3.3) and SCLK (§14.3); reload
   weights and inputs in the new format (§9.2). **Weights must be reloaded**: the H half
   holds bf16 or fp32-high bits and is not a valid encoding for the other format.

### 9.6 Soft reset

`W(CTRL, SOFT_RST)`. For 8 cycles: active layer reset; resets sequencer, self-run, KAT,
MBIST and trace state, STATUS, IRQ_STATUS, ERR_STATUS, all counters except LOAD_CRC,
CHECKSUM, SR_PASS_CKSUM, ZBUF, staging/cache, shadows. Keeps: SCRATCH, IRQ_EN,
ERR_MASK, FORMAT, XSEL, SR_N, SR_COUNT, WDOG_LIMIT, LANE_EN, CLK_CFG, CLKOUT_CFG,
PWR_CTRL, SPI_CFG, DBG_SEL, TRC_CFG, XBUF, weights, LOAD_CRC, the SPI adapter.

### 9.7 Error handling

Host library checks STATUS.ACTIVE before memory writes; reads are always allowed; after
each session `R(ERR_STATUS)` and W1C. Hang recovery: WDOG_LIMIT = 16 × LAST_CYCLES,
then SOFT_RST. A dead `clk_alt` after SRC=1 needs `rst_n`.

### 9.8 Self-test (KAT, MBIST)

* Register-triggered: `W(CTRL, KAT_START)` → ACTIVE, KAT for the current FORMAT
  (§11.5), then ST_STATUS, KAT_GOT_*, SELFTEST_DONE irq, `st_pass`. Weights and XBUF
  are overwritten (WSTALE set). Refused with `START_BUSY` while PWR_CTRL.CORE_HOLD or
  CORE_CLK_OFF = 1 (the layers cannot run the KAT; with MBIST=1 the refusal also happens
  before MBIST would run).
* Strap: `bist_en` = 1 at reset release → MBIST (if built), KAT bf16, FORMAT ← fp32,
  KAT fp32, FORMAT ← bf16; `busy` high throughout; then `st_pass` = all passed. Usable
  on a tester or with only power, clock and two pins (no SPI).

### 9.9 Leakage measurement

Not allowed while a tile sequence is OPEN (finish it or `TILE_ABORT` first; the write is
rejected with `TILE_SEQ`).
`W(PWR_CTRL, 0b11)` (both layers in reset and clock-gated); measure rails; optionally
stop `clk` externally for the full-chip leakage; restore `W(PWR_CTRL, 0)` and reload
nothing (weights in SRAM survive while VDD_SRAM is on).

### 9.10 Fault localization procedure (uses C3–C6)

1. KAT fails or z is wrong → read back weights (`BR` WEIGHT/BIAS) and compare: memory
   or load path fault (confirm with MBIST if built).
2. Coefficient stage: load known W, B, x; run; for each lane `DBG_SEL{lane, sig 0/1,
   idx}` → compare `a_hold`/`acc` with Σ W·x + b.
3. Scan stage: inject a via W = 0, B = a (§2.6 a); compare K0/K1 (sig 2/3) per slot.
4. Reciprocal: inject a = (0,…,0,β) for chosen β incl. |β| < ε (§2.6 b); z = 1/β,
   GUARD_HITS increments for the guarded ones.
5. Trace the failing lane's live stream (§11.3) for timing faults.
6. Work around: clear the lane's bit in LANE_EN; its 8 ladders read qNaN; the host
   maps those outputs out or retrains for 56 ladders.
7. Restore the saved weights.

---------------------------------------------------------------------------------------

## 10. Sequencer, instrumentation and checksum (`rondo_seq`)

### 10.1 States

`IDLE → LAUNCH → WAIT → POST → (IDLE | GAP → LAUNCH)`, plus `SRST`, `FSW` (format
switch). LAUNCH (1 cycle): `start` to the active layer, `xptr` updated, latency counter
reset. WAIT: until `done`; in the `done` cycle ZBUF ← z, LAST_CYCLES latched, counters,
NaN/Inf scan input captured, watchdog compare. POST: serial checksum over ZBUF (WIDTH+1
cycles) and NaN/Inf check (same walk), then DONE (single-shot) or continue/stop
(self-run). Self-run overlaps POST with the next inference: next `start` in cycle t+2
when `done` was in cycle t. Safe because the next capture is ≥ NGROUP·PDIM = 280 cycles
away (`affine_bank_pipe.v:224-232`) and the walk takes WIDTH+1 = 65; elaboration check
`NGROUP*PDIM > WIDTH + 8`, else elaboration error (set `CKSUM_PAR=1`).

### 10.2 Launch rule (normative, asserted in simulation)

1. `start` is a single-cycle pulse.
2. Never `start` while `done` = 1 or `busy` = 1.
3. If `done` = 1 in cycle t, no `start` before t+2 (one idle cycle; C1 makes t+1 legal,
   the gap is kept as defense in depth, as in `genesys2_fused_top.v:235-242`).
4. Self-run: exactly t+2.
5. No `start` while the layer's `core_rst_n` = 0 or within 2 cycles after it rises.

A refused KAT launch (layer not ready or clock off, in IDLE or in LAUNCH) returns a one-cycle `kat_fail` pulse from `rondo_seq` to
`rondo_kat`, which finishes with KAT_FAIL (defense in depth: KAT_START is already refused in `rondo_regs` while CORE_HOLD/CORE_CLK_OFF = 1).

### 10.3 Counters

| counter | counts | cleared by |
|---|---|---|
| LAST_CYCLES | edges after the edge sampling `start`=1, up to and including the first edge after which `done`=1; equals `c` of `sim/test_fused_bf16.py:117-131` | reset, soft reset, CNT_CLR, FORMAT switch |
| INFER_CNT (64) | `done` pulses of the active layer | reset, soft reset, CNT_CLR |
| BUSY_CYC (64) | cycles with active layer `busy` = 1 | reset, soft reset, CNT_CLR |
| TOTAL_CYC (64) | every `clk_core` cycle | reset, soft reset, CNT_CLR |
| SR_CYC (64) | SR_START launch cycle up to and including the cycle SR_DONE is set | reset, soft reset, SR_START |
| SR_DONE_CNT | `done` pulses in the current/last self-run | reset, soft reset, SR_START |
| CHECKSUM | §10.5, one update per inference (both modes; not KAT-internal runs) | reset, soft reset, CKSUM_CLR, SR_START, FORMAT switch |
| SR_PASS_CKSUM | CHECKSUM after the SR_N-th inference of a self-run (generalizes `cks_hold`, `genesys2_fused_top.v:237-240`) | as CHECKSUM |
| LOAD_CRC | §7.6 | reset, CRC_CLR, FORMAT switch, KAT, MBIST |
| GUARD_HITS | Σ popcount(`guard_hit`) of the active layer (C2), saturating at 2^32−1 | reset, soft reset, GUARD_CLR |
| NANINF_CNT | output elements of enabled lanes with exponent all ones, per capture, saturating | reset, soft reset, GUARD_CLR |
| heartbeat | free-running, never cleared except by reset | reset |

KAT-internal inferences are counted by INFER_CNT and BUSY_CYC (do not mix energy runs
with a KAT) but do not update CHECKSUM, SR_PASS_CKSUM or SR_DONE_CNT: the KAT
accumulates into its own signature register (§11.5).

### 10.4 Self-run loop control

Entries 0..SR_N−1 cyclically; SR_N, SR_COUNT, LANE_EN latched at SR_START; stop when
(SR_COUNT ≠ 0 and SR_DONE_CNT = SR_COUNT) or SR_STOP; SR_DONE after the final POST;
IRQ_STATUS.DONE is not set by self-run inferences; SR_STOP without self-run: no effect.

### 10.5 Checksum algorithm

Matches `genesys2_fused_top.v:159-177` and the update on done (`:236`), for any W:

```python
def rotl32(v, r):
    r %= 32; v &= 0xFFFFFFFF
    return v if r == 0 else ((v << r) | (v >> (32 - r))) & 0xFFFFFFFF
def fold(z_words, W):      # z_words[j]: W-bit pattern of ladder j
    return sum(rotl32(z & ((1 << W) - 1), j % 32) for j, z in enumerate(z_words)) & 0xFFFFFFFF
def update(checksum, z_words, W):
    return (rotl32(checksum, 1) + fold(z_words, W)) & 0xFFFFFFFF
```

Disabled lanes contribute their qNaN patterns (deterministic). With identical weights
and input sequence, the bf16 CHECKSUM equals `genesys2_fused_top`'s `checksum` after the
same number of inferences (both start at 0) when ACCSIG_BF16 = 8 (the board's build).
Rationale for addition and per-term rotation: `genesys2_fused_top.v:142-158`.

---------------------------------------------------------------------------------------

## 11. Debug and test features

Parameters of `rondo_dev`/`rondo_chip_top` (default in brackets): `DBG` [1], `TRACE` [1],
`TRACE_DEPTH` [64], `KAT` [1], `MBIST` [0], `SCAN` [0], `PG` [0], `SPI_CRC` [1],
`CLK_ALT` [1], `HB_BIT` [24]. With a feature off, its registers read 0, its CAPS bit is
0 and its commands set `ERR_STATUS.ADDR`.

### 11.1 Bring-up features (summary)

| feature | where | needs |
|---|---|---|
| LOOPBACK opcode 0x0E | §5.2 | clock, reset, SPI PHY only |
| STATUS8 signature `10` | §5.2 | PHY + status wiring |
| CHIP_ID, VERSION, SCRATCH | §6 | rbus + regs |
| heartbeat STATUS[6] | §6.4 | free-running counter |
| `clkout` divided clock | §3.3 | `clk_core` |
| `bist_en` → `st_pass` | §9.8 | no SPI at all |

### 11.2 Debug read multiplexer (`rondo_dbgmux`)

DBG_SEL selects {lane, sig, idx, live_sel} and drives the C4 select inputs of the active
layer (or, with `fmt_override_en`, of the layer `fmt_override`; the inactive layer is in
reset so it reads reset values — useful only to check its reset state). 4 cycles after
a DBG_SEL write or CTRL.DBG_LATCH, DBG_DATA ← `dbg_data` (zero-extended). Reads are
allowed at any time (snapshots while running are not coherent).

### 11.3 Trace buffer (`rondo_trace`)

Logic-analyzer style circular buffer: `TRACE_DEPTH` = 64 entries × 64 bits
(4,096 flops, or a 64×64 register-file macro).

Entry: data word = 32-bit sample; meta word = {[31:16] timestamp = low 16 bits of
cycles since TRC_ARM, [15:8] flags, [7:0] source tag}.

TRC_CFG (0x38):

| bits | field | values |
|---|---|---|
| [2:0] | SRC | 0 core live stream (`dbg_live_d`, selected by DBG_SEL.live_sel/lane; flags = `dbg_live_f`); 1 wrapper events (data = {[25] SPI frame end, [21:18] xptr, [17] busy, [16] done, [15:0] address low 16 b of the rbus accesses}; the "SPI frame start" bit is reserved 0, the event word already carries frame end and every rbus accept); 2 rbus traffic (data = wdata/rdata, meta flags = {we, err}, tag = addr[7:0]); 3 GUARD_HITS/NANINF increments with lane id |
| 3 | MODE | 0 store only when the source's valid qualifier is 1; 1 store every cycle |
| [7:4] | TRIG | 0 immediate (on ARM); 1 `start`; 2 `done`; 3 guard hit (any lane); 4 cycle count since the last `start` == TRC_TRIG_CYC; 5 NaN/Inf on the live stream; 6 ERR_STATUS becomes non-zero; 7 TRC_FORCE only |
| [15:8] | POST | entries stored after the trigger (0..TRACE_DEPTH−1); pre-trigger depth = TRACE_DEPTH − 1 − POST |
| 16 | STOP_ON_FULL | 1: no wrap; stop when full (ignores TRIG) |

Operation: CTRL.TRC_ARM clears the buffer and starts storing; on the trigger the
trigger entry index is recorded (TRC_STATUS.TRIG_IDX, in read order) and POST more
entries are stored, then DONE (IRQ_STATUS.TRC_DONE). The TRACE region presents entries
in chronological order (oldest first), NVALID entries valid. Re-arm clears.

### 11.4 Sticky error and event flags

All in ERR_STATUS (§6.5): NaN/Inf outputs (8), pole-guard hits (9), SPI protocol errors
(unknown opcode/CS abort/overrun 6, CRC 10, write while busy 0, address out of range 1,
RO 2), watchdog (7), KAT (11), MBIST (12), stale weights (13). ERR_MASK selects which
reach ERR_ANY and the ERR interrupt.

### 11.5 Known-answer self-test (`rondo_kat`, KAT=1)

Self-contained, no ROM of weights: an LFSR generates weights, biases and inputs, the
chip runs them through the real load path and datapath, and a signature is compared
with a build-time constant.

* LFSR: 32-bit Galois, polynomial x³²+x²²+x²+x+1 (taps 0x80200003), seed 0x1D872B41;
  one 32-bit value r per element ("advance then use": each element uses the state after one Galois step from the previous one), in the order: all WEIGHT elements (lane 0..7, address
  0..NWORDS−1, field 0..NPAR−1), all BIAS elements (same order), XBUF entries 0..NXBUF−1
  elements 0..PDIM−1.
* Element from r (keeps continuants finite in both formats): sign = r[31];
  exponent = BIAS−2 + r[30:29] (|v| ∈ [0.25, 4)); mantissa = r[28 −: SIG−1]
  (bf16 7 bits, fp32 23 bits).
* Sequence (as an internal rbus master through `rondo_rbus_arb`, `rb_req_int`=1):
  write all weights and biases via `rondo_wpack`, write XBUF, then run a self-run with
  SR_N = NXBUF, SR_COUNT = 2·NXBUF = 8 with a private signature accumulator using the
  §10.5 update starting at 0. After the last POST: KAT_GOT_<fmt> ← signature; pass iff
  equal to `KAT_SIG_<fmt>` (parameters). Read-back check: during the load the KAT also
  re-reads every 37th core word and compares (catches write-path faults with a direct
  syndrome) — a mismatch fails the KAT.
* Expected signatures are generated by `scripts/gen_kat_sig.py`, which runs the cocotb
  simulation of the configured build (both formats) and prints the parameter values;
  they are therefore RTL-derived (they prove silicon ≡ RTL; RTL ≡ math is proven by the
  rest of §15). The script also cross-checks the simulated z against the golden
  `f_ref` (decisions, and max_rel < 1e-3 at fp32). **Acceptance criterion (author decision D4, approved 2026-11-03):** ill-conditioned ladders are excluded from that
  comparison, namely those with |K0| < 0.05 (near a pole / guard-clamped), a coefficient that cancels to < 1% of the sum of its terms, or a continuant that cancels to
  < 1% of its absolute-value recurrence; on random KAT data the raw criterion gave max_rel 2.9e-3. The KAT's purpose is silicon ≡ RTL (the signature is derived from the
  RTL and checked against the bit-exact model); RTL ≡ math is established by T-FULL / T-C7 on real coefficients.
* Duration: ≈ 9k cycles per format at the SMALL geometry (measured); the FULL geometry ≈ 25,000 cycles (0.5 ms at 50 MHz) *(est.)*.
* Overwrites weights and XBUF; sets WSTALE.

### 11.6 Memory BIST (`rondo_mbist`, MBIST=0 default)

March C− on every H and L weight macro and bias store of every lane through the
`rondo_wmem` wrapper port: ⇕(w0); ⇑(r0,w1); ⇑(r1,w0); ⇓(r0,w1); ⇓(r1,w0); ⇕(r0), with
data backgrounds all-0/all-1 then 0x5555…/0xAAAA…. Lanes in parallel (each lane's
macros compared independently), H and L in parallel. As built, the lanes are tested serially (≈ 8× the parallel time, ≈ 90k cycles at FULL). ≈ 10 × 280 × 2 backgrounds × ~2
cycles ≈ 11,200 cycles for the parallel version. Result in MBIST_STATUS/FAIL_ADDR/FAIL_XOR; `st_pass` includes it.
If the foundry macros come with their own BIST, MBIST stays 0 and the compiler's BIST
pins are routed to the harness instead.

Coverage (author decision D1(a)): MBIST covers the weight and bias macros only. It does **not** cover the tiling PS store, nor the TX and TZ SRAMs
(≈ 164 kbit at TILE_B = 8). Interim zero-area mitigation: the host-side March C- `Rondo.mem_test(("PS", "TX"))` (host/rondo_host/memtest.py) runs the same element
order over every mapped PS element and TX word through the memory map (both are RW when not ACTIVE), at the format width, and returns failures as
(region, b, lane, group, field, xor) (≈ 39k word accesses ≈ 0.3 s at 5 MHz at FULL). TZ is read-only from the host and covered functionally (T-SUITE tiled case, T-TILE);
the unmapped PS rows (group ≥ NGROUP) are never used and stay untested. Extending `rondo_mbist` to PS/TX/TZ or folding PS into the weight macros (§18.9) is open (§16.4 D1).

### 11.7 Scan (SCAN=0 default)

Flow-based insertion (e.g. Fault for open PDKs, or the vendor DFT tool) on the
synthesized netlist; the RTL contains no scan muxes. RTL obligations when SCAN=1:
* pin `test_mode`; in test_mode: `scan_en` = `bist_en` pin, `scan_in` = `spi_mosi`,
  `scan_out` = `spi_miso` (oe forced 1), scan clock = `clk` (source mux and divider
  bypassed, all ICGs transparent), `sys_rst_n` = `rst_n` (synchronizer bypassed), layer
  `core_rst_n` = `rst_n`;
* one chain by default; a second chain option uses `spi_sclk` → `clkout`;
* memories (macros) bypassed/black-boxed per the flow; the seed ROM logic is scanned;
* no latches other than ICG cells.

### 11.8 JTAG: omitted (justification)

JTAG would add 4–5 pins (TCK, TMS, TDI, TDO, opt. TRST) and a TAP (≈ 1–2 kGE *(est.)*).
Its values do not apply here: SPI already gives full register and memory access (the
debug transport JTAG would provide), boundary scan needs a pad ring with BSR cells
(the harness's job, no pads in this design), and scan test uses `test_mode`. Reserved:
a future `rondo_jtag_rbus` adapter (TAP with one DR = {we, addr[24], data[32]}) would
be another rbus master behind `rondo_rbus_arb`.

### 11.9 Power

Rails `VDD_CORE`, `VDD_SRAM`, `VDDIO` (3.3 V) (§4). PWR_CTRL.CORE_HOLD / CORE_CLK_OFF
for leakage measurement (§9.9). The inactive layer is always clock-gated and in reset;
with PG=1 the chip outputs `pg_req[f]` = 1 for the inactive layer (and for both with
PWR_CTRL.PG_INACTIVE semantics) so a harness power switch can cut it; the wrapper then
keeps isolation (layer outputs forced 0 via AND gates on `busy`, `done`, `z`,
`guard_hit`, `wm_addr`, `mem_act`, debug outputs of the gated layer) and, after power-up,
holds reset for ≥ 16 cycles. Default PG=0.

---------------------------------------------------------------------------------------

## 12. Dual format (bf16 and fp32) at run time

### 12.1 Options compared *(all area/energy numbers are estimates)*

Units: L_b = bf16 layer logic as built with ACCSIG=8 (the measured design; the paper's
FPGA comparison measured ≈ 2.4× fewer LUTs and ≈ 2.85× less energy per ladder than fp32,
author-supplied figures). fp32 layer logic ≈ 2.4 L_b. Memory in bits (§16.1).

| option | logic | weight+bias store | seed ROM | bf16-mode energy vs bf16-only chip | keeps bf16 advantage? |
|---|---|---|---|---|---|
| (a) two complete layers, each with internal memories; inactive clock-gated (power-gated if harness allows) | 3.4 L_b | 293,888 + 587,776 = **881,664 b** | 3.6 k + 47 k (C7) | ≈ 1.0× dynamic + fp32 leakage (+5–15% *(est.)* without power gating, ≈ 0 with) | yes |
| (b) one fp32 datapath with a bf16 mode (operands rounded to bf16) | 2.4 L_b | 587,776 b | 47 k | ≈ 2.5–2.85× (fp32 datapath toggles; little saving) | **no** |
| **(c) two datapaths, one shared split-half store (recommended)** | 3.4 L_b + ≈ 1–2 kGE muxes | **587,776 b** | 3.6 k + 47 k | ≈ 1.0× dynamic (only H macros enabled) + fp32 leakage | **yes** |

(c) stores weights once: the H half holds bf16 weights (bf16 mode) or the high 16 bits
of fp32 weights; the L half holds the fp32 low 16 bits and is never enabled in bf16
mode, so bf16 SRAM read energy is that of a bf16-only chip. (a) wastes 293,888 b of SRAM
(bf16 store idle in fp32 mode and vice versa). (b) is smallest but defeats the reason
for bf16. Recommendation: **(c)**, implemented with C3 (`EXT_MEM=1`) on both instances,
per-layer ICG + reset hold, optional power gating (PG=1). Note on A3: with
ACCSIG_BF16 = 24, the 8 affine FMAs per lane run at EXP+24 width (`affine_bank_pipe.v:
169`), so the bf16 layer grows to ≈ 1.7–1.9 L_b and its energy advantage shrinks to
≈ 1.4–1.7× *(est.)*; this is open question Q5.

### 12.2 Per-format memory map

Identical addresses for both formats (geometry is format-independent, §1.1); each
element occupies bits [W-1:0] of its word for the current FORMAT. XBUF/ZBUF elements
are stored 32 bits wide.

### 12.3 Self-run, KAT, counters

Self-run uses the current FORMAT; switching is impossible while it runs (ACTIVE).
One KAT per format with its own signature (KAT_SIG_BF16, KAT_SIG_FP32). Counters per
§10.3 (format-independent ones are kept across a switch).

### 12.4 FORMAT register semantics

Written only while not ACTIVE (else BUSY_WR); value ∈ {0, 1} (else RANGE); takes effect
through the switch sequence §9.5 (ACTIVE ≤ 16 cycles). Effects: XBUF, ZBUF, CHECKSUM,
SR_PASS_CKSUM, LAST_CYCLES, LOAD_CRC cleared; WSTALE set (weights must be reloaded);
DBG/trace configuration, LANE_EN, CLK_CFG kept. Hard reset → bf16.

---------------------------------------------------------------------------------------

## 13. Module decomposition (new RTL under `rtl/chip/`)

Conventions: Verilog-2005 plus the SystemVerilog subset the core already uses (sized
casts, `'0`); integer parameters (strings only for SEED_FILE); async active-low reset
`always @(posedge clk or negedge rst_n)`; no `initial` except `$fatal` checks; every
clock-generating cell isolated in its own module (`rondo_icg`, `rondo_clk_mux`) for
library-cell substitution. Common parameters, written `GEOM` below: `DEPTH=7, WIDTH=64,
PDIM=40, N_LANES=8, NSLOT=8, NPAR=8`.

| # | file / module | parameters | ports (summary) | responsibility |
|---|---|---|---|---|
| 13.1 | `rondo_sync.v` | STAGES=2, WIDTH=1 | clk, rst_n, d, q | flop synchronizer (`async_reg`) |
| 13.2 | `rondo_reset_sync.v` | STAGES=2 | clk, arst_n, test_mode, rst_n_out | async assert / sync deassert; bypass in test_mode |
| 13.3 | `rondo_icg.v` | — | clk, en, test_en, gclk | latch-based clock gate (behavioral; library ICG substitution) |
| 13.4 | `rondo_clk_mux.v` | — | clk0, clk1, sel, rst_n, test_mode, clk_out | glitch-free 2:1 clock mux (§3.3) |
| 13.5 | `rondo_clkdiv.v` | — | clk_in, rst_n, div[2], test_mode, clk_out, div_applied[2] | ICG divider ÷1/2/4/8 |
| 13.6 | `rondo_spi_phy.v` | SYNC_STAGES=2 | clk, rst_n, sclk, cs_n, mosi; cs_active, frame_start, frame_end, rx_byte[8], rx_valid, tx_byte[8], tx_load, tx_need, mid_byte_abort, miso, miso_oe | oversampling, edge detect, shift registers, MISO timing, LOOPBACK and STATUS byte paths (MISO byte 0 = 0x00, STATUS8 from byte 1) |
| 13.7 | `rondo_spi_ctrl.v` | CRC=1 | PHY byte i/f; rbus master; status8[8]; crc_en; err_frame, err_crc (pulses); frame_end_o | frames §5.2–5.4, CRC-8, N+1 rule, overrun (LOOPBACK and STATUS byte paths live in `rondo_spi_phy`, 13.6) |
| 13.8 | `rondo_spi_slave.v` | SYNC_STAGES, CRC | pins + rbus master + status8, crc_en, errors | 13.6 + 13.7 |
| 13.9 | `rondo_rbus_arb.v` | — | external rbus slave side; KAT and MBIST master ports; one rbus master out with `rb_req_int` | priority to external; ≤ 1 outstanding |
| 13.10 | `rondo_sram_sp.v` | DEPTH, WIDTH | clk, en, we, addr, d, q | behavioral single-port SRAM, registered q — **macro substitution point** |
| 13.11 | `rondo_wmem.v` | GEOM, NWORDS, NBWORDS | per lane: active-layer wm_addr/bm_addr/mem_act, wm_q_h/wm_q_l/bm_q_h/bm_q_l; wrapper port {en, we, sel_bias, lane, addr, half_mask[2], wdata_h, wdata_l, rdata_h, rdata_l}; fmt | H/L stores per lane (§7.7), port arbitration, CE gating, lane-disable gating |
| 13.12 | `rondo_wpack.v` | GEOM | write/read strobes {region, lane, caddr, field, wdata}, fmt; wmem wrapper port; rdata; err_partial; crc_clr, load_crc[32] | packing, read cache, CRC-32 (§7.5–7.6) |
| 13.13 | `rondo_layers.v` | GEOM, ACCSIG_BF16=8, TBITS_FP32=8, NR_ITERS_FP32=2, HAS_BF16=1, HAS_FP32=1, LAYER=0, DBG=1, PG=0 | clk_core, core_rst_n[2], clk_en[2], test_mode, fmt; start, busy, done, x[PDIM*32], z[WIDTH*32]; lane_en; guard_hit[N_LANES]; memory ports to rondo_wmem; debug selects/outputs; pg_req | two `fused_coproc_pipe` instances (bf16: EXP 8, SIG 8, TBITS 6, EPS 0x3C24, seed e8s8_t6; fp32: EXP 8, SIG 24, TBITS_FP32, NR_ITERS_FP32, EPS 0x3C23D70A, seed e8s24_t8) with EXT_MEM=1, DBG, LANE_MASK=1; per-layer ICG; output muxing by fmt; isolation (PG=1). LAYER=1: one `kan_layer_pipe` (internal memories, single format) |
| 13.14 | `rondo_cksum.v` | WIDTH, PAR=0 | clk, rst_n, clr, go, zbuf[WIDTH*32], w16, lane_en; checksum[32], naninf_cnt_inc, busy, done | §10.5 checksum and NaN/Inf scan over ZBUF |
| 13.15 | `rondo_seq.v` | GEOM, NXBUF | commands, config, layer handshake, core_rst_n[2], clk_en[2], fmt switch control, xptr, zcap, counters, status, irq/err pulses, active | §9.4–9.6, §10, format switch §9.5, launch rule |
| 13.16 | `rondo_dbgmux.v` | — | DBG_SEL fields, latch; layer debug selects; dbg_data in; DBG_DATA out | §11.2 |
| 13.17 | `rondo_trace.v` | DEPTH=64 | clk, rst_n, cfg, arm, force, sources (core live, events, rbus, guard), read port; status | §11.3 |
| 13.18 | `rondo_kat.v` | GEOM, NXBUF, KAT_SIG_BF16, KAT_SIG_FP32 | rbus master (internal), seq control (start self-run with private signature), fmt control, status | §11.5 |
| 13.19 | `rondo_mbist.v` | GEOM | rondo_wmem wrapper port (via arbitration), status | §11.6 (generated only if MBIST=1) |
| 13.20 | `rondo_regs.v` | all feature params | decoded access {re, we, idx[8], wdata, rdata}, error outputs, all fields | §6 incl. W1C, SC, shadows, irq, STATUS8, ERR_MASK |
| 13.21 | `rondo_dev.v` | GEOM, NXBUF=4, CKSUM_PAR=0, feature params, CNT_INIT=0 (sim-only TOTAL_CYC preset for T-REG; must be 0 in silicon) | clk, rst_n, test_mode, rbus slave (external), irq, busy, st_pass, status8, clkout, clk_cfg outputs (div, src), err_frame/err_crc in, frame_end in, bist_en_at_reset, pg_req | decode (§7.1), XBUF, ZBUF, instantiates 13.9, 13.11–13.20 |
| 13.22 | `rondo_chip_top.v` | rondo_dev params + SYNC_STAGES=2, SCAN=0, F_CLK_HZ=50_000_000 (documentation only) | §4 pins | 13.2, 13.4, 13.5, 13.8, 13.21, output flops, test-mode pin sharing |
| 13.23 | `genesys2_pi_top.v` | rondo_dev params + `real CLK_DIV = 10.0`, FORMATS=3 (1 bf16, 2 fp32, 3 both) | sysclk_p/n, cpu_resetn, sw[1:0], led[7:0], JA/JB Pmod signals | FPGA prototype (§13.25) |
| 13.26 | `rondo_tbuf.v` | GEOM, TILE_B=8 | TX/TZ SRAM ports, wrapper port, x_live out | input tiling buffers and x_live (§18.3); TILE=1 also adds the PS store (module `rondo_ps`, not part of `rondo_wmem`), the tile FSM (module `rondo_tile`, not part of `rondo_seq`), and TILE=1 on both layers in `rondo_layers`; the PS/TX/TZ region offsets are decoded from addr[15:0] |

### 13.24 KAN option

`LAYER=1` builds one `kan_layer_pipe` (with C1) using internal memories (no EXT_MEM for
KAN: read-back, MBIST, dual format and C2/C4/C6 are not available — CAPS reports it).
P_IN=PDIM, N_OUT=WIDTH, NOB=NSLOT, NMAC=NPAR; packing `kan_layer_pipe.v:24-27`; no bias
region (ADDR error); the host supplies tanh(x) (`kan_layer_pipe.v:3`). Not on the first
chip; verified at SMALL geometry only.

### 13.25 FPGA prototype `genesys2_pi_top`

Clocking as `genesys2_fused_top.v:60-86` (IBUFDS → MMCME2_BASE VCO 1000 MHz → BUFG,
100 MHz at CLK_DIV 10.0); `rondo_icg` has two FPGA variants selected by defines (`RONDO_FPGA`: no clock gating, the enable is a clock enable; `RONDO_FPGA_BUFGCE`: BUFGCE), `rondo_clk_mux` is not used
(CLK_ALT=0 on the FPGA: Pmod pins are not clock-capable); `rondo_clkdiv` is not instantiated: CLK_CFG.DIV is accepted and ignored and DIV_APPLIED reads 0 (one bitstream per
format at a closed 100 MHz, so no per-format division is needed; the host derives f_core from DIV_APPLIED, §14.3). `rondo_dev` has four observation outputs (checksum, format, heartbeat, sticky-error summary) for the LEDs.
Synthesized with FORMATS=3 (both datapaths) the design does not fit the XC7K325T (261,652 LUT before tiling): one bitstream per format (Q8). Reset = cpu_resetn & locked & pmod_rst_n (synchronized).
`spi_miso` via OBUFT with `spi_miso_oe`. LEDs: sw[1]=0 → CHECKSUM byte-fold (as
`genesys2_fused_top.v:266-267`); sw[1]=1 → {heartbeat, locked, rst, busy, irq,
st_pass, FORMAT, ERR_ANY}. `rondo_sram_sp` infers BRAM.

Pmod JA (SPI, Pmod Type 2A order) and JB:

| Pmod pin | FPGA pin (**verify**) | signal | Pi 5 header pin (BCM) |
|---|---|---|---|
| JA1 | U27 | cs_n (PULLUP) | 24 (GPIO8, SPI0 CE0) |
| JA2 | U28 | mosi | 19 (GPIO10) |
| JA3 | T26 | miso | 21 (GPIO9) |
| JA4 | T27 | sclk | 23 (GPIO11) |
| JA7 | T22 | irq | 22 (GPIO25) |
| JA8 | T23 | busy | 18 (GPIO24) |
| JA9 | T20 | rst_n (PULLUP) | 16 (GPIO23) |
| JA10 | T21 | clkout | 11 (GPIO17) |
| JB1 | from master XDC | st_pass | 15 (GPIO22) |
| JB2 | from master XDC | bist_en (PULLDOWN) | 13 (GPIO27) |
| JA5/11, JB5/11 | — | GND | 6, 9, 14, 20 … (GND) |
| JA6/12 | — | 3.3 V: **do not connect** to the Pi | — |

**Flag**: `vivado/genesys2.xdc` has no Pmod pins (it constrains only sysclk,
cpu_resetn, led, sw; lines 15-39). JA pins above are from memory of Digilent's
`Genesys-2-Master.xdc`; JB pins must be taken from it. The implementer must verify both
against the master XDC before building. New file `vivado/genesys2_pi_top.xdc` (picked
up by `vivado/genesys2_build.tcl:35-37`): LVCMOS33, pull-ups/downs as listed,
`set_false_path` from all Pmod inputs and to all Pmod outputs. New script
`scripts/g2_pi_build.sh` modeled on `scripts/g2_build.sh` (source list = core +
HardFloat + `rtl/chip/*.v`; copies `rtl/core/recip_seed_*.mem` into the run dir).
**Fit risk**: both layers at full geometry may exceed the XC7K325T (the fp32 layer is
≈ 2.4× the bf16 layer's LUTs); then build FORMATS=1 and FORMATS=2 bitstreams
separately (the host reads CAPS[1:0]). Recorded as open question Q8.

---------------------------------------------------------------------------------------

## 14. Pi 5 host software

### 14.1 Platform (A6)

Raspberry Pi 5; GPIO and SPI go through the RP1 I/O controller. Header is **3.3 V**
(matches the chip's VDDIO and the Genesys 2 Pmods; no level shifters). Libraries:
`spidev` (SPI0 → `/dev/spidev0.0`, enable `dtparam=spi=on`), `gpiod` v2 Python bindings
(libgpiod 2.x; RPi.GPIO does not work on the Pi 5), `smbus2` on I²C bus 1
(`dtparam=i2c_arm=on`, GPIO2/3). The RP1 header GPIOs are the gpiochip labeled
`pinctrl-rp1` (`/dev/gpiochip0` on current kernels, `/dev/gpiochip4` on early Pi 5
kernels): the host locates it by label, not number.

### 14.2 Wiring

| signal | Pi 5 pin (BCM) | gpiod direction |
|---|---|---|
| SCLK / MOSI / MISO / CE0 | 23 (GPIO11) / 19 (GPIO10) / 21 (GPIO9) / 24 (GPIO8) | spidev |
| irq | 22 (GPIO25) | input, rising-edge events |
| busy | 18 (GPIO24) | input, both edges (timestamps bracket energy windows) |
| rst_n | 16 (GPIO23) | output, open-drain or push-pull, default high |
| st_pass | 15 (GPIO22) | input |
| bist_en | 13 (GPIO27) | output, default low |
| clkout | 11 (GPIO17) | input (frequency check by edge counting; use K ≥ 12 so edges ≤ ~12 kHz at 50 MHz) |
| clk_alt (optional) | 7 (GPIO4, GPCLK0) | GPCLK (§14.5) |
| INA226 SDA / SCL | 3 (GPIO2) / 5 (GPIO3) | I²C1 |

### 14.3 SPI clock

RP1 SPI clock = 200 MHz / even divider (verify against the RP1 peripheral datasheet;
spidev rounds the requested `max_speed_hz` down): available rates include 50, 25,
12.5, 10, 6.25, 5, 3.125 MHz …; practical with jumper wires ≈ ≤ 10–15 MHz. The host
picks the largest rate ≤ f_core / 8 (and ≤ 10 MHz):

| target | f_core | max SCLK (R=8) | default SCLK |
|---|---|---|---|
| chip, bf16, DIV=1, `F_CLK_HZ` 50 MHz | 50 MHz | 6.25 MHz | **5 MHz** (200/40) |
| chip, fp32 with DIV=2 | 25 MHz | 3.125 MHz | 3.125 MHz (200/64) |
| Genesys 2 prototype | 100 MHz | 12.5 MHz | **10 MHz** (200/20) |

The host knows f_core from a config value (`F_CLK_HZ`) and CLK_CFG, and can verify it
via `clkout` or TOTAL_CYC over a timed interval.

After writing CLK_CFG the host lowers SCLK to <= min(f_old, f_new)/8 before the next frame,
reads CLK_CFG.DIV_APPLIED/SRC_APPLIED, then sets SCLK from the applied value. (The CLK_CFG
write itself is a frame at the old SCLK, legal for the old clock; it is applied when that
frame ends, §3.3.) The test transports model the SCLK ratio and fail a frame with R < 8.

### 14.4 Package `host/rondo_host/` (pure Python ≥ 3.11; optional imports so it loads on a PC)

| file | contents |
|---|---|
| `protocol.py` | opcodes; `encode_write/encode_read/decode_read`; CRC-8 framing; loopback; STATUS8 decode; burst splitting at word boundaries and at 4,096-byte spidev chunks |
| `regmap.py` | §6/§7 addresses, fields, reset values (single source for host, mock and tests) |
| `fmt.py` | bf16 RNE (`sim/test_fused_bf16.py:26-30`), fp32 encode/decode |
| `packing.py` | `pack_weights(Wl, Bl, geom)` (§1.4), `weight_addr(j,k,c)`, `fold/update` checksum (§10.5), `load_crc` (§7.6), `kat_stream()` (§11.5 LFSR model), KAN variant |
| `transport.py` | `Transport.xfer(tx) -> rx` (one CS frame); `SpidevTransport(bus=0, dev=0, hz)`; `MockTransport(model)` |
| `gpio.py` | `Pins` on gpiod v2: `request_lines` by chip label `pinctrl-rp1`; `wait_irq(timeout)` via edge events; `pulse_reset()`, `run_bist()` (bist_en + reset, wait busy low, read st_pass); `NullPins` for PCs |
| `model.py` | `RondoModel`: byte-accurate chip model (frames, CRC, loopback, registers, W1C/RO, packing, read-back, LOAD_CRC, sequencer, format switch, lane mask, counters, trace stub) with pluggable `compute(fmt, x_bits) -> z_bits` (default golden `f_ref` in float64 rounded to the format; or a replay table of RTL z) |
| `device.py` | `Rondo` API (§14.5) |
| `power.py` | `INA226(bus=1, addr, r_shunt, i_max)`: config, `CAL = 0.00512/(I_LSB·R_shunt)`, bus V 1.25 mV/LSB, shunt V 2.5 µV/LSB, current, power 25·I_LSB/LSB; `RailSet` threaded sampler |
| `bench.py` | CLI benchmark (§14.6) |
| `suite/` | three-target test suite (§15.5) |
| `cocotb_transport.py` | `CocotbTransport(bfm)`: wraps the async SPI BFM with `cocotb.resume` so the blocking `Rondo` API runs in a `cocotb.bridge` thread against RTL; `CocotbPins` drives/samples irq/busy/rst_n/bist_en/st_pass |

### 14.5 `Rondo` API

```python
r = Rondo(SpidevTransport(hz=5_000_000), pins=Pins(), f_clk=50e6)
r.loopback_test(n=16); r.reset_check() -> Geometry     # §9.1
r.read(addr, n); r.write(addr, words); r.reg(name); r.set_reg(name, v)
r.set_format("bf16" | "fp32")      # §9.5: waits idle, writes FORMAT, adjusts DIV/SCLK
r.set_clock(div=1, src="clk")      # CLK_CFG, lower SCLK to <= min(f_old,f_new)/8, read DIV_APPLIED, final SCLK
r.soft_reset(); r.hard_reset()     # rst_n pin
r.load_weights(Wl, Bl, verify="crc" | "readback")
r.read_weights() -> (Wl, Bl)
r.write_x(entry, x); r.infer(x, entry=0, timeout=1.0) -> np.ndarray
r.self_run(xs, count=0); r.stop(); r.wait_sr_done(timeout)
r.bench_stats() -> dict            # counters, checksum, throughput
r.expected_checksum(z_per_entry, n)
r.kat(fmt) -> bool; r.bist_at_reset() -> bool; r.mbist() -> dict
r.debug(lane, sig, idx) -> int; r.trace(cfg) -> list[(ts, flags, tag, data)]
r.inject_coeffs(lane, slot, a_vec); r.recip_probe(beta_list) -> list   # §2.6
r.set_lane_mask(mask); r.clkout(k); r.power_hold(on)
r.errors() -> set[str]; r.clear_errors(); r.enable_crc(on)
r.run_wide_layer(Wden, bden, X, fmt="fp32", batch=None) -> np.ndarray   # §18.7; refuses bf16 above bf16_max_p
r.tile_plan(L, p, N) -> dict
```
Waiting uses the irq GPIO edge (gpiod event with timeout), falling back to STATUS polls.

GPCLK option (A7): GPIO4 (pin 7) can output GPCLK0 from RP1 clock sources via integer
/fractional dividers. Fractional division adds jitter; use integer divisions of a
clean source and keep it ≤ ~25 MHz over jumper wires *(verify on the RP1 datasheet;
configuration needs a device-tree overlay or direct register access)*. Default stays an
on-board oscillator on `clk`; GPCLK feeds `clk_alt` only for experiments.

### 14.6 Energy measurement (`bench.py`)

Load weights for the format; P_idle = mean rail power over T s with the chip idle
(clock running); self-run with count 0; P_run over T s (window bracketed by `busy`
edges); stop; read SR_DONE_CNT, SR_CYC. Energy/inference = (P_run − P_idle) ·
SR_CYC / (f_core · SR_DONE_CNT); also report total-power energy. Repeat per format.
Rails (name, I²C address, shunt) from a config file; the FPGA uses `docs/POWER.md`.
Leakage: §9.9.

---------------------------------------------------------------------------------------

## 15. Verification plan

### 15.1 Infrastructure

* Runners `sim/run_chip_*.py` + `sim/test_chip_*.py` via `cocotb_common.run`, each with
  its **own build directory** `sim/sim_build_chip/<name>` (never `sim/sim_build`, which
  holds a stale `verilator.o`). Seed `.mem` files copied into the build dir and cwd as
  in `sim/run_fused_bf16.py:17-18` (including the new `recip_seed_e8s24_t8.mem`).
* No `require_env` in new runners: `sim/run_all.py:39` counts a runner with 0 tests as a
  failure. Each new runner reports ≥ 1 passing test in the default invocation.
* Geometries: **SMALL** = WIDTH 16, PDIM 8, N_LANES 2, NSLOT 8, NPAR 8, DEPTH 7
  (NGROUP 7 ≥ FMA_LAT+1, NBATCHES 1; `fused_coproc_pipe.v:51-55` defaults); **FULL** =
  §1.1. FULL runners force `SIM=verilator` (≈ 262× faster than Icarus,
  `docs/FUSED_COPROC.md`).
* SPI master BFM `sim/rondo_spi_bfm.py`, **hand-written** (`cocotbext-spi` cannot be
  installed: `.venv-rtl` has no pip, `python -m pip` → "No module named pip"): mode 0,
  SCLK period any rational multiple of the `clk_core` period (R ∈ {6, 7, 8, 13, 16,
  33}), random phase, CS setup, CRC framing, `async xfer(tx) -> rx`, samples MISO at its
  rising edge (worst case §5.6). rbus BFM `sim/rondo_rbus_bfm.py` (master and responder,
  random delays/backpressure).
* Reference outputs: (a) **bare core** instances in the same testbench
  (`sim/tb_chip_vs_core.v`: `rondo_chip_top` or `rondo_dev` + an unmodified-parameter
  `fused_coproc_pipe` per format, EXT_MEM=0, loaded directly as in
  `sim/test_fused_bf16.py:84-111`) for **bit-exact** z and cycle-exact LAST_CYCLES;
  (b) golden `f_ref` (`sim/test_fused_bf16.py:43-50`) at decision level (accuracy delta
  ≤ 0.02, `:173`; fp32 max_rel < 1e-3, `:171-172`).
* Python reference models: `rondo_host.packing` (packing, checksum, CRC, KAT LFSR) and
  `rondo_host.model.RondoModel` (register semantics) are used as scoreboards.

### 15.2 Assertions (SVA-style checkers)

`rtl/chip/sva/` (new): checker modules using immediate assertions in clocked `always`
blocks with `$past` (SymbiYosys- and Verilator-compatible; no `bind`), instantiated by
`sim/tb_chip_*.v` and by the formal harnesses under `ifdef RONDO_SVA`; enabled in every
Verilator chip run (`--assert`). Properties:
* SPI framing: MISO changes only after a detected SCLK rise or CS change; `miso_oe` =
  cs_active; exactly N+1 rbus requests per READ/WRITE frame; none after a mid-word
  abort; loopback echo.
* rbus: §8.2 rules 1–5; response ≤ 4 cycles after acceptance; external access ≤ 24.
* Register file: RO registers unchanged by writes; W1C clears exactly the written ones;
  CTRL reads 0 and self-clears; shadow coherence; ERR bit set ⇒ its cause occurred in
  the previous cycle (per-bit cause signals).
* Start/done: §10.2 rules 1–5; `x` stable while `busy`; no external memory write while
  ACTIVE; ZBUF changes only in a `done` cycle; inactive layer clock enable = 0 and
  reset asserted; no `start` to the inactive layer.
* Memory: `rondo_wmem` L half never enabled in bf16 mode; single owner per cycle.

### 15.3 Formal (SymbiYosys — available: `/usr/bin/sby`, `yosys-smtbmc`, `z3`, `yices-smt2`)

| job (`formal/*.sby`) | DUT | mode | properties |
|---|---|---|---|
| `spi_ctrl.sby` | `rondo_spi_ctrl` with free byte-level PHY inputs (assumed protocol-legal PHY, byte spacing GAPN ≤ 47 cycles: a sound over-approximation of the real ≥ 48) | bmc depth 34 (CRC off, reaches the first write word) and 28 (CRC on, header) at GAPN 2 + cover depth 160 (GAPN 4, all covers incl. 2nd/3rd write words, DCRC/HCRC reject, N+1-th read, mid-word abort) + vacuity mutant (must fail) | N+1 rule, address increment, abort handling, CRC accept/reject, rbus master rules; later write words and the CRC-on write path are covered by simulation (T-SPI) and cover only. A k-induction proof was not obtained (stage B not attempted) |
| `spi_phy.sby` | `rondo_spi_phy` with an SCLK/CS model at R ≥ 6 (assumption) | bmc depth 200 + cover | received byte = sent byte; MISO bit valid at each master sampling edge |
| `regs.sby` | `rondo_regs` | prove | RO/W1C/SC semantics, shadow, irq = |(status & en) registered |
| `dev_bus.sby` | `rondo_dev` with `rondo_layers` black-boxed (abstract busy/done model satisfying the core's handshake) | bmc depth 60 (+ cover) | rbus timing bound, ACTIVE blocking, launch rule, format-switch ordering |
| `seq.sby` | `rondo_seq` with abstract layer (tile ports tied off) | bmc depth 70 (+ cover) | launch rule, counters monotonic, self-run stop, a refused KAT launch returns `kat_fail`, the reset flop equals the RUN state |
| `tile.sby` | `rondo_tile` alone | bmc depth 60 (+ cover) | launch only in an open sequence, restore only with a valid PS entry tagged s−1, idle defaults |

Each job must pass (`PASS`) and every `cover` must be reached. Run by
`scripts/chip_formal.sh`, which labels every task by its sby mode (a `mode bmc` task is printed as BMC with its depth, never as a proof; only `regs.sby` is `mode prove`, k-induction). Rules: every bmc job
has a cover task in the same configuration whose covers are reached within the bmc depth (documented exception: `spi_ctrl`), and the write-path assertions have a `mutant` task
(or `# expect-fail:` task) that must FAIL.

### 15.4 Tests

| id | runner | DUT / geometry | checks |
|---|---|---|---|
| T-C1 | run_core_c1.py | fused_coproc_pipe SMALL bf16+fp32, kan_layer_pipe SMALL | start in the done cycle completes, z bit-identical to a normal launch; back-to-back starts at t+1 |
| T-C2 | run_core_c2.py | fused_coproc_pipe SMALL | guard_hit count = number of clamped ladders (injected β) |
| T-C3 | run_core_c3.py | EXT_MEM 0 vs 1 (+ behavioral registered memory), both formats | z bit-identical, `done` same cycle, 50 random inputs |
| T-C4 | run_core_c4.py | DBG=1 vs 0 | taps = Python model; z unchanged |
| T-C5 | run_core_c5.py | DBG=1, injection | a_hold = B exactly with W=0; K0/K1 per §2.6; z = 1/β |
| T-C6 | run_core_c6.py | LANE_MASK=1 | masks incl. 0 and all-ones; enabled lanes identical; disabled qNaN; done timing |
| T-C7 | run_core_c7.py | recip_nr_pipe fp32 TBITS 8 NR 2; full fp32 layer FULL (Verilator) | ≤ 1 ULP on ≥ 100k operands + edge cases; Waveform max_rel < 1e-3, delta ≤ 0.02 |
| T-OLD | sim/run_all.py | existing | all pass after each core change, Icarus and Verilator |
| T-UNITS | run_chip_units.py | sync, reset sync, icg, clk_mux, clkdiv, cksum, wpack | latencies; glitch-free (no pulse < half the faster period on clk_out in random switching, both clocks running); divider ratios; cksum = model; packing/CRC/read cache |
| T-SPI | run_chip_spi.py | rondo_spi_slave + rbus responder | all opcodes incl. LOOPBACK; CRC on/off incl. corrupted bytes; burst lengths 1, 2, 255, 256, 65,536 (spot); aborts; R ∈ {6,7,8,13,16,33} random phase, ≥ 200 frames each; overrun |
| T-REG | run_chip_regs.py | rondo_dev SMALL, rbus | every register: reset value, access type, side effects; ERR bits; shadows with CNT_INIT = 2^32 − 50; CTRL priority |
| T-PACK | run_chip_pack.py | tb_chip_vs_core SMALL, both formats, rbus level | random weights in shuffled order; read-back equals written; LOAD_CRC = zlib; PARTIAL cases; ≥ 20 inputs: ZBUF bit-identical to bare core; LAST_CYCLES = bare core cycles |
| T-SEQ | run_chip_seq.py | rondo_dev SMALL | single-shot; START while ACTIVE; blocked writes; reads during busy; self-run K = 1, SR_N, 3·SR_N+1, 0 + SR_STOP; launch spacing t+2; CHECKSUM/SR_PASS_CKSUM = model over bare-core z; counters; WDOG; soft reset during self-run (weights kept, next inference bit-exact); lane mask through the wrapper |
| T-FMT | run_chip_fmt.py | rondo_dev SMALL | switch bf16↔fp32 repeatedly: state effects §12.4; reload and bit-exact results in each format vs bare cores; switch while ACTIVE rejected; FORMAT=2 → RANGE; L half never enabled in bf16 (assertion); inactive layer clock off |
| T-DBG | run_chip_dbg.py | rondo_dev SMALL | DBG_SEL/DBG_DATA for all sigs/lanes vs model; §9.10 localization flow end to end; fault injection: force a stuck bit in one lane's H memory (testbench `force`) → localized to that lane/address by read-back and MBIST (MBIST=1 build) |
| T-TRC | run_chip_trace.py | rondo_dev SMALL | every SRC × TRIG × MODE combination at least once; POST/pre-trigger positions; chronological readout; timestamps |
| T-KAT | run_chip_kat.py | rondo_dev SMALL and FULL (Verilator), both formats | KAT passes with generated signatures; a forced fault (stuck weight bit, stuck FMA output bit) makes it fail; `bist_en` strap at reset runs both formats and drives `st_pass` |
| T-MBIST | run_chip_mbist.py | rondo_dev SMALL, MBIST=1 | passes on good memories; detects injected stuck-at, transition and coupling faults (behavioral fault injection in `rondo_sram_sp` under a sim define) with correct lane/addr |
| T-CLK | run_chip_clk.py | rondo_chip_top SMALL | DIV 1/2/4/8 applied at frame end; SRC switch with both clocks; clk_alt dead → recovery by rst_n; clkout frequencies; SPI at R=8 of the divided clock |
| T-TOP | run_chip_top.py | rondo_chip_top SMALL via SPI BFM | §9.1–9.9 sequences; back-to-back operations; STATUS/ZBUF reads during busy; R = 6 and 8; irq/busy/st_pass pins; CRC mode |
| T-HOST | run_chip_host.py | rondo_chip_top SMALL via CocotbTransport | unmodified `Rondo` API: loopback, reset_check, set_format, load/read weights, infer, self_run, kat, debug, trace |
| T-FULL | run_chip_full.py | tb_chip_vs_core FULL, SPI R=8, Verilator | Waveform coefficients, both formats (switching in one run): 8 samples bit-exact vs bare cores, decisions vs golden; self-run 4 × 3 passes CHECKSUM = model; ≤ 15 min |
| T-KAN | run_chip_kan.py | rondo_dev LAYER=1 SMALL bf16 | KAN packing bit-exact vs bare `kan_layer_pipe`; bias region → ADDR |
| T-SCAN | run_chip_scanmode.py | rondo_chip_top SCAN=1 SMALL | test_mode pin muxing and bypasses (functional, pre-insertion) |
| T-LINT | scripts/chip_lint.sh | rondo_chip_top FULL, parameter variants (default; MBIST=1 SCAN=1 PG=1; HAS_FP32=0; LAYER=1) | `verilator --lint-only -Wall` with `sim/hardfloat.vlt`, `sim/cofr_waivers.vlt`, new `sim/chip_waivers.vlt` (each waiver scoped and justified): zero warnings. Variants also include `accsig24` (-GACCSIG_BF16=24 -GTILE=0) and `tile_b0` (-GTILE_B=0), which must be clean, and the expected-fail variants `accsig24_tile` ("TILE=1 needs ACCSIG_BF16=8"), `npar6` ("NPAR must be a power of two") and `tbits10` ("TBITS_FP32 must be 8 or 12"), which must be rejected at elaboration (the same NPAR=6 build is also rejected by Icarus and Yosys). `scripts/chip_struct.sh` (§3.4 structural check) is called from chip_lint.sh |
| T-SYN | scripts/chip_synth.sh | rondo_chip_top SMALL and FULL | `yosys -p "read_verilog -sv <srcs>; synth -top rondo_chip_top; stat; check"`: no errors, no latches other than `rondo_icg`/`rondo_clk_mux` cells, no multiple-driver/undriven warnings in `rondo_*`; `stat` to `build/chip/yosys_<cfg>.txt`; area table §16 regenerated from it |
| T-FORMAL | scripts/chip_formal.sh | §15.3 | all PASS, covers reached |
| T-GLS | scripts/chip_gls.sh | Yosys netlist of rondo_chip_top SMALL | zero-delay gate-level simulation (Icarus with Yosys `simcells.v`/`simlib.v`) of a T-TOP subset + KAT both formats: same results as RTL. Timing GLS: with the shuttle flow's netlist + SDF (OpenROAD/OpenLane `write_sdf`), Icarus `-gspecify` + `$sdf_annotate` (or a commercial simulator), same subset at f_core and at R=8 — specified now, executed once a PDK is chosen |
| T-SUITE | run_chip_suite.py + `python -m rondo_host.suite` | §15.5 | identical vectors on sim / FPGA / chip |
| T-FPGA | scripts/g2_pi_build.sh | genesys2_pi_top | timing met at 100 MHz; bitstream(s); hardware suite run by the author |
| T-C8, T-TILE, T-CFG, T-WIDE | see §18.8 | | input tiling: tiled == untiled bit-exact, both formats, corner cases, CoFrGeNet shape |

### 15.5 One suite, three targets

`scripts/gen_vectors.py` writes `build/vectors/rondo_vectors_<geom>.npz` for FULL
(Waveform weights) and SMALL (seeded random weights): per format, the packed weights,
16 inputs, expected z bits (from the bare-core RTL
simulation), expected self-run CHECKSUM/SR_PASS_CKSUM for 4 entries × 3 passes, KAT
signatures, injection vectors for §2.6 with expected z, and the expected LAST_CYCLES.
`python -m rondo_host.suite --target sim|fpga|chip [--vectors …]` runs the same test
functions (ID/loopback, register access, load + CRC + read-back, single-shot bit-exact,
self-run checksum, format switch, KAT, debug taps, lane mask, error cases) through
`CocotbTransport` (sim, invoked by `sim/run_chip_suite.py`: SMALL vectors by default,
FULL under Verilator),
or `SpidevTransport` + gpiod pins (FPGA, chip). Pass criteria are identical for all
targets (bit-exact).

### 15.6 Pass criteria for handoff

All tests except T-FPGA hardware and timing GLS pass; SMALL runners under Icarus and
Verilator, FULL under Verilator; `sim/run_all.py` passes in full under both simulators.

---------------------------------------------------------------------------------------

## 16. Area, power and risk notes

All logic figures are **estimates** in NAND2-equivalent gates (GE), assuming a flop ≈
5.5 GE, a bf16 FMA (SIG 8) ≈ 3 kGE and an fp32 FMA ≈ 10 kGE *(est.)*, calibrated only to
the measured ≈ 2.4× LUT ratio between the fp32 and bf16 layers. T-SYN replaces them.

### 16.1 Storage bits (FULL geometry)

| storage | bf16 only | fp32 only | chip (option c) | location |
|---|---|---|---|---|
| weights | 286,720 | 573,440 | **573,440** (H 286,720 + L 286,720) in 16 macros of 280 × 128 | `rondo_wmem` (was `affine_bank_pipe.v:112`) |
| biases | 7,168 | 14,336 | **14,336** (flops or latch RF; ≈ 79 kGE as flops) | `rondo_wmem` (was `:113`) |
| seed ROM | 3,584 (TBITS 6) | 753,664 (TBITS 12) / **47,104** (TBITS 8, C7) | **50,688** | `recip_nr_pipe.v:61` |
| XBUF | 2,560 | 5,120 | 5,120 flops | `rondo_dev` |
| ZBUF | 1,024 | 2,048 | 2,048 flops | `rondo_dev` |
| trace | — | — | 4,096 flops (or 64×64 RF) | `rondo_trace` |
| KAN option (instead) | 327,680 | 655,360 | — | `kan_sum_bank.v:98` |
| tiling PS + TX + TZ (TILE_B = 8) | — | — | 163,840 (or PS in unused rows of 512-deep weight macros) | §18.3 |

Die sizing: ≈ 574 kbit SRAM (16 macros) + ≈ 15 kbit bias + ≈ 51 kbit seed logic +
≈ 12 kbit wrapper flops.

### 16.2 Logic by block *(est.)*

| block | kGE | note |
|---|---|---|
| bf16 layer, ACCSIG 8 (as measured) | ≈ 440 | 8 lanes × (12 bf16 FMAs + ≈ 3k flops) |
| bf16 layer, ACCSIG 24 (A3 default) | ≈ 800 | 8 affine FMAs per lane at EXP+24 width |
| fp32 layer, NR_ITERS 1, TBITS 12 | ≈ 1,060 + seed ROM as logic (≈ 200–300) | |
| fp32 layer, NR_ITERS 2, TBITS 8 (C7) | ≈ 1,220 + ≈ 10 | +16 fp32 FMAs, −707 kbit ROM |
| C2 guard export + counter | ≈ 1 | |
| C4 debug taps (both layers) | ≈ 100–130 | wide static muxes (≈ 35 kbit of tap inputs per format); dropping the accumulator tap (sig 1) saves ≈ 40% |
| C6 lane mask | ≈ 1 | |
| SPI slave incl. loopback, CRC-8 | ≈ 2 | |
| regs, counters, irq | ≈ 8 | ≈ 1,100 flops |
| XBUF + x mux, ZBUF | ≈ 50 | |
| wpack (staging, read cache, CRC-32) | ≈ 4 | |
| seq + serial checksum | ≈ 3 | |
| trace buffer | ≈ 25 | as flops |
| KAT | ≈ 2 | |
| MBIST (MBIST=1) | ≈ 4 | |
| clock mux, divider, ICGs, clkout | ≈ 0.5 | |
| PG isolation (PG=1) | ≈ 3 | |
| input tiling (C8 core + x_live + control) | ≈ 35 | §18.9 |
| **wrapper total (default build)** | **≈ 95 + taps ≈ 200–225** | ≈ 10% of the two layers |

Power: in bf16 mode the fp32 layer is clock-gated (dynamic ≈ 0) but leaks; on a
leakage-heavy process this costs ≈ 5–15% of bf16 energy per inference *(est.)* without
power gating. The debug taps and trace are static when not selected (DBG_SEL idle
inputs held constant). `clkout` off by default.

### 16.3 Risks

| risk | mitigation |
|---|---|
| start hazard (§1.3.5) | C1 + launch gap + assertion + WDOG |
| SCLK too fast for oversampling, esp. after DIV changes | R ≥ 8 normative, R = 6 verified, host recomputes SCLK; STATUS8 signature; LOOPBACK |
| C3 external memory timing differs from the internal array | T-C3 cycle-exact equivalence; `mem_act` contract |
| C7 changes fp32 numerics | T-C7 (≤ 1 ULP, layer accuracy bar); NR_ITERS=1 remains available |
| A3 (ACCSIG 24) erodes the bf16 advantage and changes results vs the paper | Q5; parameter |
| dead `clk_alt` after switching | hard reset forces `clk` |
| glitch on clock mux/divider in silicon | library clock-mux/ICG cells substituted; STA case analysis |
| both layers may not fit the XC7K325T | FORMATS parameter, two bitstreams (Q8) |
| Pmod pins unverified | must be checked against the Digilent master XDC |
| Pi 5 RP1 SPI rates and GPCLK details from memory | verify on the RP1 datasheet; host measures actual SCLK with the LOOPBACK timing |
| long jumpers ringing on SCLK | ≤ 10 MHz, short wires, common ground; optional 3-sample majority filter on SCLK (`SCLK_FILTER`, default 0) |
| KAT signature is RTL-derived | other tests establish RTL ≡ math; KAT detects silicon ≠ RTL |
| full-geometry sim time | SMALL for most tests, Verilator for FULL |
| debug-tap mux area | DBG parameter, drop sig 1 if area is tight |

### 16.4 Open questions for the author

* **Q1** Shuttle/process and target f_core (sets SCLK, macro availability, F_CLK_HZ).
* **Q2** Power gating of the inactive layer (PG=1) — does the harness offer switched
  domains?
* **Q3** (resolved: C2 accepted.)
* **Q4** Accept C7 (fp32 TBITS 8 + 2 NR iterations, numerics change, +16 FMAs, −707
  kbit ROM)? Recommended.
* **Q5** ACCSIG_BF16: author default 24, but it costs ≈ +360 kGE and most of bf16's
  energy advantage *(est.)*, and fp32 mode now exists for accuracy-critical workloads;
  consider 8 (as measured) or 16.
* **Q6** NXBUF = 4 enough? (each entry 1,280 flops)
* **Q7** Is MBIST needed or will the macros' own BIST be used?
* **Q8** If both layers do not fit the Genesys 2, are separate per-format bitstreams
  acceptable?
* **Q9** Keep the accumulator debug tap (sig 1, ≈ 40% of tap area)?
* **D1** MBIST coverage of PS/TX/TZ (≈ 164 kbit): decided (a) for now, document the gap and the zero-area host March (§11.6); (b) extend `rondo_mbist` (≈ 5 kGE, +25k cycles) or (c) fold PS into the unused rows of 512-deep weight macros stay open until Q7 (MBIST vs the foundry macro BIST) and the macro depth are known.
* **D2** VERSION bump to 0x00020101: decided yes (single isolated change, revertible).
* **D3** B3: TILE requires ACCSIG_BF16 = 8, elaboration error otherwise: decided yes; making the wide-accumulator bf16 build tile (≈ 60–80 RTL lines + a T-TILE variant) is open.
* **D4** KAT f_ref acceptance criterion: relaxed criterion (ill-conditioned ladders excluded) approved, §11.5.
* **Q10** Tiling batch depth TILE_B: 8 (≈ 164 kbit) by default; 16–32 if the die allows, or fold the PS store into unused rows of 512-deep weight macros (§18.9).

---------------------------------------------------------------------------------------

## 17. Implementation task list (ordered)

Each task lists files, acceptance criteria and the proving test. A task starts only when
the previous one is accepted. Core-change tasks (T1–T7) each require: `sim/run_all.py`
passing under Icarus and Verilator **after** the change, plus their own test.

### Core changes

1. **T1 C1 start fix.** Edit `rtl/core/fused_coproc_pipe.v:207`, `rtl/core/kan_layer_pipe.v:151`
   (§2.2). New `sim/run_core_c1.py`, `sim/test_core_c1.py`. Accept: T-C1 + T-OLD.
2. **T2 C2 guard export.** Edit `recip_nr_pipe.v`, `ladder_engine_inter.v`,
   `fused_coproc_pipe.v` (§2.3). New `sim/run_core_c2.py`, `test_core_c2.py`. Accept:
   T-C2 + T-OLD.
3. **T3 C7 NR_ITERS.** Edit `recip_nr_pipe.v` (+ forwarding); generate
   `rtl/core/recip_seed_e8s24_t8.mem` with `gen_recip_table.py`. New
   `sim/run_core_c7.py`, `test_core_c7.py`. Accept: T-C7 + T-OLD.
4. **T4 C3 EXT_MEM.** Edit `affine_bank_pipe.v`, `fused_coproc_pipe.v` (§2.4). New
   `sim/run_core_c3.py`, `test_core_c3.py`. Accept: T-C3 + T-OLD.
5. **T5 C6 LANE_MASK.** Edit `fused_coproc_pipe.v` (§2.7). New `run_core_c6.py`,
   `test_core_c6.py`. Accept: T-C6 + T-OLD.
6. **T6 C4 DBG taps.** Edit `affine_bank_pipe.v`, `ladder_engine_inter.v`,
   `fused_coproc_pipe.v` (§2.5). New `run_core_c4.py`, `test_core_c4.py`,
   `run_core_c5.py`, `test_core_c5.py`. Accept: T-C4, T-C5 + T-OLD.
7. **T7 Core checkpoint.** New `sim/chip_waivers.vlt` (PINMISSING on old
   instantiations only). Accept: T-OLD under both simulators; lint of each modified
   module shows no new warnings; diff review that every change is gated (§2.1).

### Wrapper

8. **T8 Clock/reset primitives.** `rtl/chip/rondo_sync.v`, `rondo_reset_sync.v`,
   `rondo_icg.v`, `rondo_clk_mux.v`, `rondo_clkdiv.v`; `sim/run_chip_units.py`,
   `test_chip_units.py`. Accept: T-UNITS (clock parts).
9. **T9 SPI slave.** `rondo_spi_phy.v`, `rondo_spi_ctrl.v`, `rondo_spi_slave.v`;
   `sim/rondo_spi_bfm.py`, `sim/rondo_rbus_bfm.py`, `run_chip_spi.py`, `test_chip_spi.py`.
   Accept: T-SPI.
10. **T10 Host core (no RTL).** `host/rondo_host/{__init__,protocol,regmap,fmt,packing}.py`,
    `host/tests/test_protocol.py`, `test_packing.py`. Accept: pytest; `pack_weights`
    for Waveform equals `gen_genesys2_rom.py` output word for word (bf16 and `--wb 32`);
    CRC-8 check value 0xF4; KAT LFSR model.
11. **T11 Memories.** `rondo_sram_sp.v`, `rondo_wmem.v`. Accept: unit tests in
    `test_chip_units.py` (ownership, CE gating, L never enabled in bf16).
12. **T12 Packer.** `rondo_wpack.v`. Accept: T-UNITS (packing, read cache, CRC-32).
13. **T13 Layers.** `rondo_layers.v`. Accept: lint for LAYER 0/1, HAS_* variants;
    format switch unit test (clock/reset ordering).
14. **T14 Sequencer.** `rondo_cksum.v`, `rondo_seq.v`. Accept: T-UNITS (cksum) and a
    sequencer unit test against an abstract core handshake.
15. **T15 Registers and device.** `rondo_regs.v`, `rondo_rbus_arb.v`, `rondo_dev.v`,
    `sim/tb_chip_vs_core.v`, `run_chip_regs.py`, `test_chip_regs.py`,
    `run_chip_pack.py`, `test_chip_pack.py`, `run_chip_seq.py`, `test_chip_seq.py`,
    `run_chip_fmt.py`, `test_chip_fmt.py`. Accept: T-REG, T-PACK, T-SEQ, T-FMT.
16. **T16 Chip top.** `rondo_chip_top.v`, `run_chip_top.py`, `test_chip_top.py`,
    `run_chip_clk.py`, `test_chip_clk.py`. Accept: T-TOP, T-CLK.

### Debug features

17. **T17 Debug mux.** `rondo_dbgmux.v`; `run_chip_dbg.py`, `test_chip_dbg.py`.
    Accept: T-DBG (without the MBIST part).
18. **T18 Trace.** `rondo_trace.v`; `run_chip_trace.py`, `test_chip_trace.py`.
    Accept: T-TRC.
19. **T19 KAT.** `rondo_kat.v`, `scripts/gen_kat_sig.py`; `run_chip_kat.py`,
    `test_chip_kat.py`. Accept: T-KAT (SMALL; FULL in T24).
20. **T20 MBIST.** `rondo_mbist.v`; `run_chip_mbist.py`, `test_chip_mbist.py`.
    Accept: T-MBIST; T-DBG MBIST part.
21. **T21 Manufacturing hooks.** SCAN/test_mode and PG isolation in `rondo_chip_top.v`,
    `rondo_layers.v`; `run_chip_scanmode.py`, `test_chip_scanmode.py`. Accept: T-SCAN,
    lint of SCAN=1 PG=1 variant.

### Tests and sign-off checks

22. **T22 Assertions.** `rtl/chip/sva/rondo_sva_spi.v`, `rondo_sva_rbus.v`,
    `rondo_sva_regs.v`, `rondo_sva_seq.v`, `rondo_sva_wmem.v`; instantiated in all chip
    testbenches. Accept: all chip tests pass with assertions on (Verilator `--assert`);
    each property fires in a deliberately broken mutant run (negative test).
23. **T23 Formal.** `formal/spi_ctrl.sby`, `spi_phy.sby`, `regs.sby`, `dev_bus.sby`,
    `seq.sby`, `scripts/chip_formal.sh`. Accept: T-FORMAL.
24. **T24 Full geometry.** `run_chip_full.py`, `test_chip_full.py`; KAT signatures for
    the FULL build via `gen_kat_sig.py`. Accept: T-FULL, T-KAT FULL.
25. **T25 KAN option.** `run_chip_kan.py`, `test_chip_kan.py`. Accept: T-KAN.
26. **T26 Lint and synthesis.** `scripts/chip_lint.sh`, `scripts/chip_synth.sh`.
    Accept: T-LINT, T-SYN; report the measured area per block replacing §16.2
    estimates (in the task report, not by editing the spec).
27. **T27 Gate-level simulation.** `scripts/chip_gls.sh`. Accept: T-GLS zero-delay part.

### FPGA prototype

28. **T28 Genesys 2.** `rtl/chip/genesys2_pi_top.v`, `vivado/genesys2_pi_top.xdc`,
    `scripts/g2_pi_build.sh`. Accept: Pmod pins verified against the Digilent master
    XDC (source cited in the XDC header); bitstream(s) meeting timing at 100 MHz
    (FORMATS=3, or 1 and 2 if 3 does not fit — report utilization).

### Host software

29. **T29 Host device layer.** `host/rondo_host/{transport,gpio,model,device,power,
    bench,cocotb_transport}.py`, `host/tests/test_model.py`; `sim/run_chip_host.py`,
    `test_chip_host.py`. Accept: pytest on MockTransport for all §9 sequences; T-HOST.
30. **T30 Three-target suite and final regression.** `scripts/gen_vectors.py`,
    `host/rondo_host/suite/*`, `sim/run_chip_suite.py`. Accept: T-SUITE (sim target);
    `sim/run_all.py` passes in full under Icarus and Verilator; §15.6 satisfied.

**Total: 30 tasks** (7 core, 9 wrapper, 5 debug, 6 test/sign-off, 1 FPGA, 2 host),
plus **T31–T35 for input tiling in §18.10 → 35 tasks.**

---------------------------------------------------------------------------------------

## 18. Input tiling (layers wider than PDIM)

Added after v2.0 (author decision). Lets a layer with p > PDIM = 40 inputs (e.g.
CoFrGeNet, p = 768, 768 ladders: `workloads/results/cofrgenet_shape.npz` holds
`Wden` 5376×768 = 768 ladders × 7 levels, `bden`, 64 samples `X` 64×768) run on the
chip by splitting the inputs into S = ⌈p / PDIM⌉ slices (S = 20 for p = 768; the last
slice has 8 real inputs) and the ladders into G = ⌈L / WIDTH⌉ ladder groups (G = 12).

### 18.1 Why tiled == untiled, bit for bit (from the RTL)

* Each coefficient a[j][k] is an independent accumulation held in `acc[ch]`, which is
  EXP+ACCSIG = AW bits wide (`affine_bank_pipe.v:78`, `:121`): 16 bits for bf16 with
  ACCSIG 8, 32 for fp32.
* `acc` is written in exactly three places: reset (`:196`), the bias prologue, which
  seeds `acc[(bg-1)*NPAR+j] <= {b_word[j], SH zeros}` (`:213-216`), and the MAC
  writeback `acc[wb_g*NPAR+j] <= mac_p[j]` (`:200-203`).
* MAC order: in `S_MAC` the group index g advances every cycle and the input index c
  advances when g wraps (`:224-231`, address `:147`), so every chain sees
  `acc ← fma(w[c], x[c], acc)` for c = 0, 1, …, PDIM−1 in ascending order (header
  `:24-31`: "Accumulation order per coefficient is unchanged -- still sequential over
  c"). Operands are `{w, SH zeros}`, `{x_c, SH zeros}` and the full-width `acc`
  (`:169-172`): one rounding to AW bits per step.
* The result is narrowed to W bits only at the output `a` (`:132`, `narrow` `:83-96`);
  `a` is consumed by the ladder engine only after the batch (`fused_coproc_pipe.v:192-198`).

Therefore, if after slice s the AW-bit `acc` state is kept or saved **unrounded** and is
the seed of slice s+1 (instead of the bias), the chain performs exactly the same
sequence of FMAs with the same operands as an untiled build with PDIM' = S·PDIM, so the
final `acc`, `a`, K0/K1 and z are bit-identical.

Padding: inputs c ≥ p in the last slice use **weight −0 and x +0**. Then
`fma(−0, +0, acc) = (−0) + acc = acc` exactly for every acc under round-to-nearest-even,
including acc = ±0 (−0 + −0 = −0, −0 + +0 = +0), subnormals, ±Inf; a NaN acc stays the
(canonical, RISCV specialization) NaN. So a padded tiled run is also bit-identical to an
untiled build with PDIM' = p exactly. Padding with +0 weights would **not** be: an acc
of exactly −0 would become +0, which can flip the sign of a guarded ladder output
(sign(K0) in §1.3.10).

What breaks bit-exactness (all excluded by this spec): narrowing partial sums to W
between slices; different ACCSIG between the tiled run and the reference; slices out of
order or x/W slices mismatched; +0 padding. A different NPAR/NGROUP split does not
break it (per-chain order is unchanged).

Constraint: partial sums are per batch of NSLOT ladders; C8 requires NBATCHES = 1
(true for the chip: NLAD = NSLOT = 8, §1.1). TILE is ignored (CAPS.TILE = 0) when NBATCHES ≠ 1.

### 18.2 C8 — core change (`TILE`, default 0)

Files: `rtl/core/affine_bank_pipe.v`, `rtl/core/fused_coproc_pipe.v`. With TILE = 0 the
new inputs are ignored, `done_final` = `done`, and behavior is bit- and cycle-identical.

`fused_coproc_pipe` new ports (forwarded per lane to `affine_bank_pipe`):

| port | dir | meaning |
|---|---|---|
| `tile_seed[2]` | in | sampled with an accepted `start` (`start && !busy_r`): 0 = seed from bias (today), 1 = keep `acc` unchanged (no seeding), 2 = seed from `ps_q` (restore) |
| `tile_save` | in | sampled with `start`: after the MAC phase, stream `acc` out on the `ps_w*` port |
| `tile_last` | in | sampled with `start`: 1 = run the recurrence and reciprocal (normal); 0 = partial slice: the lane skips the ladder engine and `zl` is not written |
| `ps_q[N_LANES*NPAR*AW]` | in | restore data, per lane, registered memory output for address `bm_addr` (same timing as the bias memory, C3) |
| `ps_we[N_LANES]`, `ps_waddr[N_LANES*BAW]`, `ps_wdata[N_LANES*NPAR*AW]` | out | save stream: one group (NPAR accumulators, field j = `acc[g*NPAR+j]`, full AW bits) per cycle |
| `done_final` | out | pulses together with `done` when the finished start had `tile_last` = 1 |

`affine_bank_pipe` (TILE = 1): inputs `seed_mode[2]`, `save_en` sampled at `in_valid`
in `S_IDLE` (`:206-211`); `ps_q[NPAR*AW]`; outputs `ps_we`, `ps_waddr[BAW]`,
`ps_wdata[NPAR*AW]`.
* `S_BIAS` runs its NGROUP+1 cycles in every mode (keeps the weight prefetch at
  `:147` identical); the acc write at `:214-216` uses `{b_word[j], SH zeros}`
  (seed_mode 0), `ps_q[j*AW +: AW]` (seed_mode 2) or is suppressed (seed_mode 1).
* After `S_DRAIN` reaches FMA_LAT (`:233-237`; all writebacks have landed), if
  `save_en`: new state `S_SAVE` for NGROUP cycles: `ps_we` = 1, `ps_waddr` =
  bsel_r·NGROUP + sg, `ps_wdata` = acc group sg; then `ovalid_r`. The state register
  may widen to 3 bits (S_SAVE unreachable with TILE = 0).

`fused_coproc_pipe` lane FSM: in `L_WAITA` (`:192-195`), if the latched `tile_last` is
0 go to `L_FIN` instead of `L_RUN` (no `a_hold` load, no ladder run, `zl` untouched).
Top: `done` is asserted at the end of every start exactly as today (`:224-233`);
`done_final` is a registered copy of `done & last_q`. **Partial vs final** is therefore
`done && !done_final` vs `done_final`. C1 (start fix), C2 (guard, only on final slices
since the reciprocal runs only then), C4 taps (sig 1 shows partial sums) and C6 (lane
mask; disabled lanes neither save nor restore) apply unchanged. The bf16 and fp32
instances both get TILE = 1 in the chip.

Cycle cost per start *(est., from the FSM)*: partial = launch + (NGROUP+1) + NGROUP·PDIM
+ FMA_LAT+1 + NGROUP ≈ 8 + 280 + 6 + 7 ≈ 301 cycles; final = today's LAST_CYCLES.

Proof: `sim/run_all.py` (TILE = 0) under both simulators; T-C8 (§18.8).

### 18.3 Wrapper storage (`rondo_tbuf`, `rondo_wmem` PS store)

Parameter `TILE_B` (inputs processed per loaded slice), **default 8**; 0 = no on-chip
batch store (keep-in-place mode only, B = 1). **TILE requires ACCSIG_BF16 = 8** (the bf16 PS store is 16 bits wide): elaboration error otherwise; a wide-accumulator bf16 build is built with TILE=0, and wide layers run in fp32 (§18.7).

| store | per entry | organization | default (TILE_B = 8), physical bits |
|---|---|---|---|
| PS (partial sums) | N_LANES × NGROUP × NPAR × AW = 448 × AW = 7,168 b (bf16, AW 16) / 14,336 b (fp32, AW 32) | in module `rondo_ps` (not in `rondo_wmem`), per lane, H/L halves like the weights: depth TILE_B·2^BAW = 64, width NPAR·16 = 128; bf16 (AW 16) uses H only, fp32 uses H+L | 8 lanes × 2 × 64 × 128 = **131,072** |
| TX (input slices) | PDIM × 32 b = 1,280 b | `rondo_tbuf` SRAM, 32-bit words, stride 2^XW = 64 | 8 × 64 × 32 = **16,384** |
| TZ (final outputs) | WIDTH × 32 b = 2,048 b | `rondo_tbuf` SRAM, 32-bit words | 8 × 64 × 32 = **16,384** |
| x_live | — | PDIM × 32 flops, drives the layer's `x` in tile mode (copied from TX[b] in PDIM cycles before each launch) | 1,280 flops |

PS restore: during `S_BIAS` the layer presents `bm_addr` (group); `rondo_wmem` returns
PS entry {b, group} instead of the bias word when seed_mode = 2. PS save writes
entry {b, ps_waddr}. Single port: restore (S_BIAS) and save (S_SAVE) never coincide.

### 18.4 Batch mechanism: options and choice

Per loaded (ladder group, slice), the weight stream is 17,920 words (≈ 0.115 s at
5 MHz SCLK) and each input needs only 40 x words (≈ 0.26 ms), so batching many inputs
per loaded slice is what makes wide layers practical.

| option | on-chip memory | SPI traffic per input per (group, slice) | per-input time, CoFrGeNet fp32 (G·S = 240 loads, 5 MHz) *(est.)* |
|---|---|---|---|
| O1 no batch (keep-in-place, B = 1) | 0 | 17,920 + 40 words | ≈ 27.6 s |
| O2 on-chip PS+TX+TZ, depth B | 17,664·B b valid (fp32-sized; ≈ 20,480·B physical) | 17,920/B + 40 | B = 8: ≈ 3.5 s; 16: ≈ 1.8 s; 64: ≈ 0.5 s |
| O3 host-swapped PS (PS window over SPI) on top of O2 | O2's store | 17,920/B_host + 40 + 896 (save+restore 448 words each) | B_host = 64 with TILE_B = 8: ≈ 1.9 s |
| O4 bigger XBUF only | — | — | rejected: partial sums still need per-input storage |

O2 memory per depth (physical, PS+TX+TZ): B = 8: 163,840 b; 16: 327,680 b; 32:
655,360 b (vs. 573,440 b weight store).

**Chosen: O2 with `TILE_B` = 8 (≈ 164 kbit, ≈ 29% of the weight store), plus O3** (the
PS store is memory-mapped, so the host can batch beyond TILE_B by saving/restoring
partial sums over SPI). Raise TILE_B to 16–32 if the die allows (open question Q10).
Compute time is negligible: ≈ 301 cycles per input per partial slice ≈ 6 µs at 50 MHz.

### 18.5 Registers, memory map, flags (additions to §6/§7)

| addr | name | access | reset | fields |
|---|---|---|---|---|
| 0x50 | TILE_CFG | RW; blocked (TILE_SEQ) while OPEN or ACTIVE | 0 | [0] TILE_EN, [15:8] NSLICE (1..255, else RANGE), [23:16] TBATCH (1..max(TILE_B,1), else RANGE), [24] KEEP (keep-in-place; forces TBATCH = 1; required if TILE_B = 0), [25] HOST_SLICE (slice index set by the host, for O3) |
| 0x51 | TILE_STATUS | RO | 0 | [0] OPEN, [1] SLICE_DONE, [2] FINAL_DONE, [3] STALE, [15:8] SLICE (next slice to run), [23:16] INPUTS_DONE in the current run |
| 0x52 | TILE_SEQ_CRC | RO | 0 | CRC-32 chained over the LOAD_CRC value (4 bytes, LE) at every TILE_RUN since the sequence opened; host verifies the whole weight sequence. In HOST_SLICE mode every slice-0 TILE_RUN re-opens the sequence and restarts the CRC, so it covers the last slice-0 run onwards |
| 0x53 | TILE_GEOM | RO | build | [7:0] TILE_B, [15:8] AW_BF16, [23:16] AW_FP32 |
| 0x54 | TILE_SLICE | RW only if HOST_SLICE = 1, OPEN and not ACTIVE (else TILE_SEQ) | 0 | [7:0] slice index for the next TILE_RUN |

CTRL: bit 13 **TILE_RUN**, bit 14 **TILE_ABORT** (close the sequence, invalidate all
PS entries, clear STALE). IRQ_STATUS: [5] TILE_SLICE_DONE, [6] TILE_FINAL_DONE (IRQ_EN
reset becomes 0x7F). ERR_STATUS: [14] **TILE_SEQ** (illegal command in the tile state,
see 18.6), [15] **TILE_STALE** (a TILE_RUN found a PS entry invalid or with the wrong
slice tag, or an open sequence was invalidated). CAPS[17] = TILE. STATUS[1] ACTIVE
includes a TILE_RUN.

Memory map (RW when not ACTIVE; ADDR error for holes):

| base | name | layout |
|---|---|---|
| 0x040000 | TX | `0x040000 + (b << XW) + i`, b < TILE_B, i < PDIM (element, 32-bit word) |
| 0x050000 | TZ (RO) | `0x050000 + (b << clog2(WIDTH)) + j` (final z of input b, ladder j of the group) |
| 0x060000 | PS | `0x060000 + (b << (LNW+BAW+FW)) + (l << (BAW+FW)) + (g << FW) + f`: partial sum of chain g·NPAR+f of lane l for input b, AW bits in [AW-1:0]. A host write marks entry b valid with tag = TILE_SLICE−1 **at write time** (O3 restore): the host sets TILE_SLICE before writing PS |

Elaboration: the PS/TX/TZ region offsets fit in 16 bits (FW+BAW+LNW+clog2(TILE_B) ≤ 16, clog2(TILE_B)+XW ≤ 16, clog2(TILE_B)+clog2(WIDTH) ≤ 16): the implementation decodes addr[15:0] under bases 0x04/05/06 (an earlier draft said ≤ 17).

### 18.6 Rules and state (`rondo_seq` tile FSM)

* Sequence opens at a TILE_RUN with SLICE = 0 and TILE_EN = 1 (TILE_CFG and LANE_EN
  latched); OPEN = 1.
* TILE_RUN runs slice s = SLICE for inputs b = 0..TBATCH−1: copy TX[b] → x_live; launch
  with seed = bias if s = 0, else keep (KEEP) or PS[b]; save = (s < NSLICE−1) && !KEEP;
  last = (s = NSLICE−1). On a partial done: PS[b] tag ← s, valid. On `done_final`:
  TZ[b] ← z, ZBUF ← z, CHECKSUM/NaN update. Launch rule §10.2 applies between inputs.
  After the last input: SLICE ← s+1 (unless HOST_SLICE) and TILE_SLICE_DONE, or, for the
  final slice, TILE_FINAL_DONE and OPEN ← 0 (unless HOST_SLICE: the host closes with
  TILE_ABORT).
* Before launching a slice s > 0 the chip checks all TBATCH entries are valid with tag
  s−1 (KEEP: a single valid flag for the in-place acc, set by the previous slice and
  cleared by anything else that starts the layer); otherwise the whole run is refused
  with TILE_STALE. Nothing ever mixes partial sums of different sequences or slices.
* Rejected with TILE_SEQ while OPEN: START, SR_START, KAT_START, MBIST_START, writes to
  TILE_CFG, FORMAT, LANE_EN, PWR_CTRL (CORE_HOLD would reset the in-place accumulators of a
  KEEP sequence); TILE_RUN with TILE_EN = 0. START and SR_START are also
  rejected (TILE_SEQ) whenever TILE_EN = 1: tiled layers have no single-shot or
  self-run mode (the weights change per slice).
* Weight, bias, TX and PS writes between runs are allowed (not ACTIVE). Biases are read
  only by slice 0. The host clears LOAD_CRC before each slice load and checks it;
  TILE_SEQ_CRC covers the whole sequence.
* TILE_SLICE is cleared when a sequence closes or aborts. A TILE_RUN that the sequencer refuses (the layer is not ready) sets START_BUSY and, as the sequence is invalidated, TILE_STALE (documented behavior; keep).
* **Invalidation** (all PS valid bits cleared, OPEN ← 0, SLICE ← 0, STALE and
  ERR.TILE_STALE set if a sequence was open): hard reset, soft reset, TILE_ABORT
  (without the error), a watchdog expiry during a tile run (after the host's soft reset),
  a FORMAT switch (only possible when not OPEN; it clears PS because AW changes).
* Lane mask: latched at open; disabled lanes are not launched, save nothing and give
  qNaN in TZ.
* KAT/MBIST: only when not OPEN; they overwrite weights (MBIST does not cover the PS store, §11.6) and
  clear all PS valid bits.
* Errors such as NAN_INF or GUARD do not abort a sequence (partial sums may legitimately
  be large; NaN is data).
* LAST_CYCLES, INFER_CNT, BUSY_CYC count every launch (partial and final);
  GUARD_HITS only final slices.

### 18.7 Host sequence and precision

For each ladder group G_i (WIDTH ladders; pad the last group with ladders whose weights
are −0 and disable whole unused lanes with LANE_EN): load G_i's biases; `W(TILE_CFG,
EN, NSLICE = S, TBATCH = B)`; for s in 0..S−1: CRC_CLR, load G_i's weight slice
`W[:, :, s·PDIM : (s+1)·PDIM]` (padding −0) in the §9.2 order, check LOAD_CRC; write
TX[b] = x_b[s·PDIM : (s+1)·PDIM] (padding +0) for b < B; `W(CTRL, TILE_RUN)`; wait for
the irq. After the final slice read TZ[0..B−1]. For batches larger than TILE_B (O3):
HOST_SLICE = 1; per slice, per sub-batch: write PS (restore, skipped at s = 0), TX,
TILE_SLICE = s, TILE_RUN, read PS (save, skipped at s = S−1) or TZ.

**Precision: tiling fixes width, not accuracy.** At p = 768 the bf16 datapath with the
8-bit accumulator (A3) agrees with the reference on only about 45% of decisions
(author-measured); bf16 accumulation error grows with p (`affine_bank_pipe.v:39-44`:
4.7e-2 median relative error at p = 768). **Wide layers should run in fp32 mode.** The
host warns for bf16 when p > PDIM and refuses bf16 when p > `bf16_max_p` (default 80 =
2·PDIM, configurable) unless `allow_bf16_wide=True`.

Host API (§14.5 addition):

```python
Z = r.run_wide_layer(Wden, bden, X, fmt="fp32", batch=None, depth=7,
                     bf16_max_p=80, allow_bf16_wide=False, verify="crc",
                     progress=None) -> np.ndarray       # (N, L) float32
# Wden: (L*depth, p) as in the npz; bden: (L*depth,); X: (N, p)
# order: for group in ladder groups: biases(group);
#          for sub-batch (≤ TILE_B, or host-swapped with HOST_SLICE when batch > TILE_B):
#            for slice: weights(group, slice) [reloaded per sub-batch only if not swapping],
#                       TX, TILE_RUN, wait; read TZ
r.tile_plan(L, p, N) -> dict    # groups, slices, loads, estimated SPI time
```
With swapping (batch > TILE_B) the loop order is group → slice → sub-batch so each
weight slice is streamed once per group.

### 18.8 Verification

| id | runner | DUT / geometry | checks |
|---|---|---|---|
| T-C8 | run_core_c8.py | `fused_coproc_pipe` TILE = 1, SMALL (WIDTH 16, N_LANES 2, PDIM 8), bf16 and fp32, behavioral PS memory | p ∈ {16, 24, 20}: z bit-identical to an untiled `fused_coproc_pipe` build with PDIM = p (no padding) and with PDIM = S·PDIM; random weights plus crafted cases producing −0, subnormal, Inf and NaN accumulators; seed modes bias/keep/restore; `done_final` only on the last slice; `zl` untouched on partial slices; C6 mask during tiling |
| T-OLD | sim/run_all.py | existing | unchanged pass (TILE = 0) |
| T-TILE | run_chip_tile.py | rondo_dev SMALL, both formats | full register sequence; B = 1..TILE_B; KEEP; O3 host swap with batch 3·TILE_B; results bit-identical to the untiled wide-PDIM bare core; corner cases: TILE_RUN out of order, wrong PS tag → STALE and refusal, soft reset/WDOG mid-sequence invalidates, START/SR_START/KAT/FORMAT/LANE_EN/TILE_CFG while OPEN → TILE_SEQ, TILE_ABORT, LOAD_CRC per slice and TILE_SEQ_CRC, NaN not aborting, FORMAT switch clears PS |
| T-CFG | run_chip_cofrgenet.py | rondo_dev, WIDTH 16, N_LANES 2, PDIM 40, Verilator, fp32 and bf16 | first 16 ladders and 8 samples of `cofrgenet_shape.npz` (p = 768, S = 20): bit-identical to a bare untiled `fused_coproc_pipe` with WIDTH 16, PDIM 768; fp32 vs golden `f_ref`: max_rel < 1e-3 on unguarded ladders; bf16 agreement reported, not asserted |
| T-WIDE | run_chip_host.py (added case) | rondo_chip_top SMALL via CocotbTransport | `run_wide_layer` on 32 ladders × p = 96 × N = 2·TILE_B+1 (two groups, host swap) equals a Python run of the bare-core reference; bf16 refusal above `bf16_max_p` |
| T-SUITE | (vectors) | — | `gen_vectors.py` adds a tiled case (p = 3·PDIM) to the three-target suite |

Assertions (§15.2 additions): no `tile_seed` = 2 without a valid PS entry of tag s−1;
partial runs never write ZBUF/TZ; PS writes only in S_SAVE or by the host when not
ACTIVE. Formal: `seq.sby` gains the tile FSM properties (refusal on stale tags, no
launch while a rejected command is pending).

### 18.9 Area and time *(estimates)*

| item | cost |
|---|---|
| C8 in the core (seed mux NPAR×AW 3:1, S_SAVE, lane FSM, ps ports) | ≈ 1.5 kGE per lane per format ≈ 25 kGE |
| PS store (TILE_B = 8) | 131,072 b (SRAM, 16 macros of 64 × 128 or folded into the weight macros' unused depth: 280 → 512-deep macros leave 232 rows per half, enough for TILE_B ≤ 29 at stride 8) |
| TX + TZ (TILE_B = 8) | 32,768 b SRAM |
| x_live + tile control | ≈ 10 kGE |
| time, CoFrGeNet layer (768 × 768), fp32, 5 MHz SCLK | ≈ 27.5 s of weight streaming per pass; ≈ 3.5 s/input at B = 8, ≈ 0.5 s/input at B = 64; on-chip compute ≈ 1.4 ms/input |

Note: if the foundry weight macros are 512 deep (§7.7), placing the PS store in their
unused rows (addresses ≥ 280) costs no extra macro area; this is the recommended
physical mapping when available.

### 18.10 Tasks (appended to §17)

31. **T31 C8 core.** Edit `rtl/core/affine_bank_pipe.v`, `rtl/core/fused_coproc_pipe.v`
    (§18.2). New `sim/run_core_c8.py`, `sim/test_core_c8.py`. Accept: T-C8 + T-OLD
    under Icarus and Verilator.
32. **T32 Wrapper tiling.** `rtl/chip/rondo_tbuf.v` (new), additions to `rondo_wmem.v`
    (PS store), `rondo_seq.v` (tile FSM), `rondo_regs.v` (§18.5), `rondo_dev.v`
    (decode, x_live), `rondo_layers.v` (TILE = 1, ps ports). New
    `sim/run_chip_tile.py`, `sim/test_chip_tile.py`. Accept: T-TILE; all earlier chip
    tests still pass.
33. **T33 CoFrGeNet-shape test.** `sim/run_chip_cofrgenet.py`,
    `sim/test_chip_cofrgenet.py`. Accept: T-CFG.
34. **T34 Host wide-layer API.** `host/rondo_host/device.py` (`run_wide_layer`,
    `tile_plan`, bf16 guard), `model.py` (tile FSM), `host/tests/test_tile.py`; T-WIDE
    case in `sim/test_chip_host.py`; tiled vectors in `scripts/gen_vectors.py`.
    Accept: pytest, T-WIDE, T-SUITE tiled case.
35. **T35 Regression.** Accept: `sim/run_all.py` passes in full under both simulators;
    T-LINT and T-SYN re-run with TILE = 1; formal additions pass.

**Updated total: 35 tasks.**
