# The complete accelerator: x in, z out

**`rtl/core/fused_coproc.v` runs a whole CoFrNet layer.** Everything before it was
a ladder engine.

## Why this is the difference between an engine and an accelerator

Every earlier design — `cofr_coproc`, `cofr_coproc_inter` — takes the ladder
coefficients `a` as an **input**. That skips the affine stage, which is roughly
**98% of a CoFrNet layer's arithmetic**: `2*d*p` FLOP per ladder against the
ladder's 12. Every throughput, area and energy number we produced for those
designs describes 2% of the problem.

`fused_coproc` computes `a[j][k] = W[j][k] . x + bias[j][k]` on chip from resident
weights, then runs the continued fraction. The input is the feature vector.

    x --> affine_bank (per lane) --> ladder_engine_inter --> z

Two consequences, and the second is the larger one:

1. **The wide `a_all` port disappears.** In `cofr_coproc_inter` that port and its
   crossbar were **63% of the area** while doing no arithmetic (I-35). Here each
   lane owns a contiguous range of ladders, so mapping results onto `z` is static
   wiring — there is no crossbar at all.
2. **Weights become resident**: `L*d*p` words in BRAM rather than streamed. That
   is the trade fusion makes, and it is exactly why it saves traffic — `x` is
   shared across the whole bank while `W` is not.

## Verification

`affine_bank` is `affine_unit` widened from one ladder to `NLAD`, with the MAC
chain, accumulation order and bias handling copied unchanged. It matches a
single-rounded fp32 FMA model at **0 ULP** across every configuration tried,
including all three real datasets' dimensions:

| DEPTH | PDIM | NMAC | NLAD | result |
|---|---|---|---|---|
| 7 | 40 | 1 / 4 / 8 | 8 | 0 ULP |
| 7 | 23 | 2 | 4 | 0 ULP |
| 7 | 10 | 4 | 8 | 0 ULP |
| 3 | 8 | 2 | 2 | 0 ULP |
| 12 | 40 | 8 | 4 | 0 ULP |

The full layer is then checked two ways at once: per-ladder `z` against an fp64
reference computed from the same `x` and `W`, **and** end-to-end classification
accuracy computed from the RTL's own outputs through the trained `V` and direct
path.

To make that possible, `workloads/train_dump.py` now also dumps the raw inputs
`X` and the affine map `W_den`/`b_den`. Previously only the derived coefficients
`A` were saved, which is why no earlier test could exercise the affine stage.
`W_den @ x + b_den` reproduces the dumped `A` to 1.3e-06, and the dumped model
accuracies are unchanged.

## Cost, and where it goes

Measured on waveform (p=40), WIDTH=16, 2 lanes, NSLOT=8:

| NMAC | cycles/ladder | max_rel |
|---|---|---|
| 1 | 151.19 | 3.70e-06 |
| 2 | 81.19 | 3.70e-06 |
| 4 | 46.19 | 3.70e-06 |
| 8 | **28.69** | 3.70e-06 |

**cycles/ladder = 140/NMAC + 11.2**, an exact fit. Results are **bit-identical
across NMAC** — the MACs are chained rather than reduced in a tree, so the
accumulation order does not change with width, as `docs/FUSION.md` predicted.

The 11.2-cycle floor is the scan plus the affine prologue. The `140/NMAC` term is
the affine work, `d*p/NMAC` per ladder. **At NMAC=8 the affine stage is still 61%
of the cycles**, and it only falls below a quarter at NMAC ≈ p. This is the same
conclusion `docs/FUSION.md` reached from the other direction and the same one the
GEMM-pairing study reached: the affine maps dominate, and a production design
needs a wide affine engine or a real GEMM core, not a folded MAC.

**That is the honest framing of this module.** It makes the accelerator complete
and correct, and it makes the cost of the affine stage concrete and measurable
inside our own RTL rather than inferred from a simulator.

## The full model, end to end

WIDTH=64 (the trained model), 4 lanes, NSLOT=8, NMAC=8, 100 test samples, driven
from raw `x` with the trained weights resident:

| dataset | p | cycles/sample | cycles/ladder | max_rel | acc (RTL) | acc (ref) | delta |
|---|---|---|---|---|---|---|---|
| waveform | 40 | 916 | 14.31 | 9.16e-04 | 0.8900 | 0.8900 | **0.0000** |
| creditcard | 23 | 692 | 10.81 | 2.11e-04 | 0.8200 | 0.8200 | **0.0000** |
| magic | 10 | 580 | 9.06 | 5.25e-04 | 0.7600 | 0.7600 | **0.0000** |

**Every classification decision preserved on all three datasets**, computed by the
RTL from the input vector rather than from precomputed coefficients. Cycles per
ladder tracks `p` exactly as the affine term predicts.

> **Run these under Verilator.** I-15 kept the project on Icarus because of a
> cocotb teardown double-free, but that only ever aborted multi-config sweeps
> inside one process, and every runner now launches one config per process.
> Verilator gives **318,727 ns/s against Icarus's 1,216 — a 262x simulation
> rate** with identical results. This sweep takes ~20 seconds under Verilator and
> did not finish one dataset in 40 minutes under Icarus.

## What is still missing

- **The output affine** `y = Ux + Vz` is done in the testbench, not in RTL. `V`
  and the direct path are commodity GEMV; folding them in is straightforward but
  not yet built.
- **Weight load is one word per cycle** through a single port, which is fine for
  a test and wrong for a system. Real deployment needs the weights in place.
- **No area or timing numbers yet** for `fused_coproc` — next.
- Affine and scan run **sequentially** per wave. Overlapping them is worth at
  most the scan's share (~39% at NMAC=8, less at higher NMAC), so it is a real
  but bounded optimisation.
