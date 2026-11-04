# CoFrNet Accelerator — RTL

RTL for the continuant coprocessor (see `docs/ACCELERATOR_DESIGN.md`). Verified with
cocotb against the Python golden model (`../continuant_scan.py`).

## Layout

```
rtl/
  cofr_defs.vh                # central parameter defaults (EXP,SIG,DEPTH,WIDTH,EPS) — single source of truth
  core/mat2x2_mul.v            # 2x2 transfer-matrix combine (the scan operator) — 8x HardFloat FMA
  core/ladder_scan.v          # continuant K0,K1 via chained mat2x2_mul (combinational)
  core/ladder_scan_iter.v     # folded/iterative scan (FPGA-timing path: 1 mat2x2 reused, clocked)
  core/recip_wrap.v           # pole-guarded divide f=K1/K0 (clocked, HardFloat divSqrtRecFN)
  core/ladder_top.v           # M1: full single-ladder forward (ladder_scan + recip_wrap)
  core/ladder_engine.v        # iterative single-ladder lane (ladder_scan_iter + recip_wrap)
  core/cofr_coproc.v          # M2: WIDTH ladders over N_LANES engines (lockstep waves) -> z vector
  core/fp_mul.v               # combinational fp32 multiply (generalized output stage)
  core/fp_fma.v               # combinational fp32 fused multiply-add (used by kscan)
  core/kscan.v                # M3: full continuant array K[0..DEPTH] (scalar recurrence, 1 FMA/cycle)
  core/grad_a_unit.v          # M3: closed-form backward gradient df/da (reuses K + 1 reciprocal)
  core/grad_gen_unit.v        # generalized backward: grad_a + grad_b (cumprod(-b))
  core/train_ladder.v         # M3: forward + backward in one engine (kscan+recip+grad_a_unit)
  core/train_coproc.v         # WIDTH-batched forward+backward (train_ladder x N_LANES) -> z + grad_a
  # Generalized numerators (learned b): GEN=1 param on ladder_scan_iter/ladder_engine/cofr_coproc
  smoke/smoke_fma.v            # M0 smoke DUT: fp32 FMA via HardFloat
  third_party/HardFloat/       # Berkeley HardFloat (BSD), John Hauser's Verilog release (+1-line patch)
sim/
  cocotb_common.py             # shared runner + fp32/ULP helpers + HardFloat source sets
  test_smoke_fma.py  / run_smoke.py        # M0 FMA smoke (numpy golden)
  test_mat2x2_mul.py / run_mat2x2.py       # 2x2 combine (mirrored-rounding golden, 0 ULP)
  test_ladder_scan.py/ run_ladder_scan.py  # continuant K0,K1 (depth sweep)
  test_recip_wrap.py / run_recip.py        # pole-guarded divide (clocked, near-pole cases)
  test_ladder_top.py / run_ladder_top.py   # M1 full ladder vs reference math (depth sweep)
```

See `docs/IP_PROVENANCE.md` for where the IP comes from, why, and verification results.

## Two-venv setup (important)

cocotb 2.0.1 supports **Python ≤ 3.13**, but the project's main `.venv` is Python 3.14.
So RTL verification uses a **separate** `.venv-rtl` (Python 3.13, provisioned via `uv`):

```bash
# one-time (already done):
.venv/bin/pip install uv
.venv/bin/uv venv --python 3.13 .venv-rtl
.venv/bin/uv pip install --python .venv-rtl/bin/python cocotb numpy pytest
```

- Use **`.venv-rtl`** for anything importing cocotb.
- Use the main **`.venv`** (Python 3.14, has torch) for the golden model / `continuant_scan.py`.

## Tools

- **Icarus Verilog** (default sim) and **Verilator 5.050** both installed.
- HardFloat source: **John Hauser's original Verilog release** (self-contained). The
  `ucb-bar/berkeley-hardfloat` repo is now Chisel; the `bsg-external` mirror needs external
  BaseJump primitives — both avoided.

## Run

```bash
cd sim
../.venv-rtl/bin/python run_all.py                         # CI: all runners, non-zero exit on failure
PYTHONPATH=. ../.venv-rtl/bin/python run_smoke.py          # M0 FMA smoke (Icarus)
PYTHONPATH=. ../.venv-rtl/bin/python run_mat2x2.py         # mat2x2_mul unit test
SIM=verilator PYTHONPATH=. ../.venv-rtl/bin/python run_smoke.py
```

Expected: all `PASS`. `smoke_fma` worst abs err `0.000e+00`; `mat2x2_mul` max **0 ULP** (both
bit-exact vs the numpy golden).

## Notes / gotchas

- `divSqrtRecFN_small.v` had a redundant `wire` re-declaring an ANSI output port that **both**
  Icarus and Verilator reject. Fixed with a documented 1-line local patch (`LOCAL PATCH` marker in
  the file; see `docs/IP_PROVENANCE.md` §1). The divider is clocked/multi-cycle, used by `recip_wrap`.
- The runner sets `timescale=("1ns","1ps")` so cocotb `Timer(..., unit="ns")` works.
- Golden tolerance in the smoke test is intentionally loose (proves wiring/IP, not ULP rigor);
  real unit tests check against `continuant_scan.py` tightly.
