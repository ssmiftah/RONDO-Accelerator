# IP Provenance & Verification Log

Where every reused design comes from, **why** that source was chosen over the
alternatives, its license, and **how we verified** it actually works in our flow.

Principle: build custom RTL only for the differentiator; clone verified IP for
everything commodity (`docs/METHODOLOGY.md` §3, `docs/ACCELERATOR_DESIGN.md` §11). Nothing
is trusted because it's popular — each reused block is proven against a golden
model in our own simulator before we build on it.

Environment snapshot (2026): Verilator 5.050, Icarus Verilog 13.0, cocotb 2.0.1,
Python 3.13.14 (`.venv-rtl`) / 3.14.6 (`.venv`), uv 0.11.28.

---

## 1. Berkeley HardFloat — fp32 arithmetic (ADOPTED)

| | |
|---|---|
| **What** | IEEE-754 floating-point primitives: FMA (`mulAddRecFN`), add, mul, div/sqrt (`divSqrtRecFN`), recoding (`fNToRecFN`/`recFNToFN`). |
| **Source** | John R. Hauser's original **Verilog release**: <http://www.jhauser.us/arithmetic/HardFloat-1.zip> (Release 1, 2019-07-29). Vendored at `rtl/third_party/HardFloat/`. |
| **License** | BSD 3-clause (Regents of the University of California). Permissive; redistribution OK with notice. |
| **Used by** | `smoke_fma.v`, `mat2x2_mul.v` (the 2×2 combine = 8× `mulAddRecFN`); later `recip_wrap` (`divSqrtRecFN`). |

**Why this source (three candidates evaluated):**
- ❌ `ucb-bar/berkeley-hardfloat` — **now Chisel/Scala**; would need an SBT/JDK generate step to emit Verilog. Rejected: heavyweight, off our SV/Verilator flow.
- ❌ `bsg-external/HardFloat` — Verilog, but **depends on external BaseJump STL** primitives (`bsg_counting_leading_zeros`, `bsg_dff_chain`, `bsg_mul_add_unsigned`, `bsg_mux_one_hot`) not included in the repo. Rejected: drags in a whole external library.
- ✅ **Hauser's original release** — **self-contained** (own `countLeadingZeros` in `HardFloat_primitives.v`), canonical, BSD. Chosen.

**How verified:**
- `smoke_fma` (fp32 FMA `a*b+c`): **500 random cases, worst abs error 0.000e+00** vs a numpy fp64→fp32 reference. Proves recode → FMA → decode is IEEE-correct end-to-end.
- `mat2x2_mul` (built from 8 FMAs): directed (identity/zero/transfer-matrix) + **400 random cases at 0 ULP** vs a golden mirroring the RTL rounding. Confirms the primitives compose correctly.

**Local patch (documented):** `divSqrtRecFN_small.v` had a redundant `wire sqrtOpOut;` that
re-declared its ANSI `output sqrtOpOut` port. **Both** Icarus and Verilator (correctly) reject
this as a duplicate declaration; only lenient commercial tools accept it. We removed that one
line (marked `LOCAL PATCH (CoFrNet accel)` in the file); upstream is otherwise byte-for-byte
unchanged. After the patch the divider compiles clean on Icarus and lints on Verilator (only
benign HardFloat width warnings), and `recip_wrap` verifies at **0 ULP**.

---

## 2. cvfpu / FPnew — multi-format FPU (REFERENCED, not yet adopted)

| | |
|---|---|
| **What** | Parametric transprecision FPU (SystemVerilog), valid/ready handshake, arbitrary IEEE-style formats incl. bf16/fp16. |
| **Source** | OpenHW Group: <https://github.com/openhwgroup/cvfpu> |
| **License** | SolderPad Hardware License 0.51 (Apache-2.0-based), permissive. |

**Why referenced but not adopted now:** it's the natural path **when we parameterize beyond fp32 to bf16** (the format abstraction in `cofr_pkg.sv`). For the fp32 M0/M1 prototype it's heavier than needed (RISC-V-oriented, more integration surface) than HardFloat. Revisit at the precision-sweep milestone.

**Verification:** none yet (not in the build).

---

## 3. cocotb + Verilator/Icarus — verification flow (ADOPTED)

| | |
|---|---|
| **What** | Python-based cosimulation testbench framework; testbenches drive the DUT and check against our Python golden. |
| **Source** | cocotb 2.0.1 (<https://github.com/cocotb/cocotb>, BSD); Verilator 5.050 & Icarus Verilog 13.0 (system installs). |
| **License** | cocotb BSD; Verilator LGPL/Artistic; Icarus GPL (tools, not linked into our IP). |

**Why chosen:** cocotb lets the testbench **call our already-validated Python golden model** (`continuant_scan.py`, numpy) directly, instead of re-deriving expected values in HDL — maximum reuse of prior verification work. Verilator for speed, Icarus as an easy fallback (default for the smoke/unit tests today).

**How verified:** the flow itself is exercised by every passing test above (`smoke_fma`, `mat2x2_mul`). Icarus is the current default; Verilator selectable via `SIM=verilator`.

---

## 4. Gemmini — GEMM core (PLANNED, not adopted)

| | |
|---|---|
| **What** | Berkeley systolic-array generator for the affine-map matmuls (`W`, `U`, `V`). |
| **Source** | <https://github.com/ucb-bar/gemmini> (UCB) |
| **License** | BSD. |

**Why planned but deferred:** the affine maps are commodity matmul, so we'll adopt a proven GEMM rather than build one — but only at the **integration milestone (M5)**. Caveat: it's Chisel/RoCC-SoC, a language/scope mismatch with our SV flow, so the integration approach is an open decision.

**Verification:** none yet.

---

## 5. uv + standalone Python 3.13 — toolchain provisioning (ADOPTED)

| | |
|---|---|
| **What** | `uv` package/Python manager; provisions a local CPython 3.13 for the RTL venv. |
| **Source** | Astral `uv` 0.11.28 (installed into `.venv`); CPython 3.13.14 (uv-managed, `~/.local/share/uv/python/`). |

**Why:** cocotb 2.0.1 supports **Python ≤ 3.13**, but the project's main `.venv` is Python **3.14** (needed for the current torch). Rather than touch the system Python or downgrade `.venv`, `uv` provisions a **project-local** 3.13 into `.venv-rtl` — no sudo, no system changes. See `rtl/README.md`.

**How verified:** `.venv-rtl` runs cocotb 2.0.1 + numpy; all tests above execute under it.

---

## 6. Custom RTL — the differentiator (OURS)

Not reused — built and verified in-house because no drop-in IP exists.

| Module | Status | Verification |
|---|---|---|
| `mat2x2_mul.v` (2×2 transfer-matrix combine — the continuant scan operator) | **built** | directed + 400 random fp32 cases, **0 ULP** vs mirrored golden |
| `ladder_scan.v` (continuant K0,K1 via chained `mat2x2_mul`) | **built** | depths 1–7: **0 ULP** vs fp32 fold, ≤1.9e-6 vs fp64 |
| `ladder_scan_iter.v` (folded/iterative scan — FPGA-timing path) | **built** | depths 1–7: **0 ULP**, back-to-back handshake OK |
| `recip_wrap.v` (pole-guard clamp around HardFloat `divSqrtRecFN`) | **built** | directed + near-pole + 150 random, **0 ULP** |
| `ladder_top.v` (full single-ladder forward `f = K1/K0`) | **built (M1 ✅)** | depths 1/3/7, 120 cases, rel ≤ **2.1e-6** vs reference math |
| `ladder_engine.v` (iterative single-ladder lane) | **built** | depths 1/3/7 vs reference math |
| `cofr_coproc.v` (WIDTH ladders × N_LANES engines — **M2**) | **built (M2 ✅)** | full/partial/single-lane + partial last wave, all correct |
| `fp_mul.v` / `fp_fma.v` (combinational fp32 multiply / FMA helpers) | **built** | via engine/kscan tests |
| Generalized numerators (`GEN` param + `b`) in scan/engine/coproc | **built** | GEN=0/1, depths 1/3/7, multi-lane/wave, rel ≤ 2.2e-6 |
| `kscan.v` (full K[0..DEPTH] array, scalar recurrence — M3) | **built** | depths 1–7, **0 ULP** vs fused fp32 |
| `grad_a_unit.v` (closed-form backward gradient — M3) | **built** | vs analytic + finite-diff, depths 2/3/7 |
| `train_ladder.v` (integrated forward+backward — **M3 ✅**) | **built (M3 ✅)** | f ≤1.1e-6, grad ≤2.4e-6, depths 2/3/7 |
| `grad_gen_unit.v` (generalized backward: grad_a + grad_b — I-11) | **built** | vs analytic + finite-diff, depths 2/3/7 |
| `kscan.v` GEN (generalized K recurrence) | **built** | GEN=0/1, 0 ULP vs fused fp32 |
| `train_coproc.v` (WIDTH-batched fwd+bwd — I-12) | **built** | z + grad_a, full/partial/single-lane |

---

## Verification methodology (applies to all reused IP)

1. **Golden source of truth:** the Python model — `continuant_scan.py` for CoFrNet logic, numpy for raw arithmetic. Reused, not re-derived in HDL.
2. **Mirror the RTL rounding** in the golden where exactness matters (e.g. `mat2x2_mul`: round the partial product to fp32, then fused-accumulate) so we can assert **≤ 1 ULP** rather than a loose tolerance.
3. **ULP-based comparison** (`cocotb_common.ulp_diff`), robust across magnitudes incl. near-zero/cancellation.
4. **Directed + constrained-random**, with edge cases called out (identity/zero matrices now; near-pole `K0≈0` and `depth=1` as we add the ladder).
5. **Reproducible**: each module has a `run_*.py`; see `rtl/README.md`.

Nothing graduates from "cloned" to "trusted" until it passes in our simulator against the golden.
