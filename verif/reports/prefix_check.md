# Red on pre-fix, green on fixed (2026-11-04)

| scenario | check | pre-fix RTL (build/verif/rtl_prefix) | fixed RTL |
|---|---|---|---|
| B1 | UVM u_b1_keep_corehold | FAIL (expected FAIL) | PASS (expected PASS) |
| B2 | UVM u_b2_kat_pwr | FAIL (expected FAIL) | PASS (expected PASS) |
| B4 | UVM u_b4_host_replay | FAIL (expected FAIL) | PASS (expected PASS) |
| B3 | elab_neg.sh (TILE with ACCSIG_BF16=24 and 5 other illegal parameter sets must be fatal) | FAIL (expected FAIL) | PASS (expected PASS) |
| B7 | cocotb run_b7.py (sim/test_core_c6.py::c6_start_in_done_disabled, bf16+fp32) | FAIL (expected FAIL) | PASS (expected PASS) |
| B6 | formal/struct_checks.sh STRUCT.1 (core_rst_n from a flop) | FAIL (expected FAIL) | PASS (expected PASS) |
| B5 | u_caps (formula) on the pre-fix RTL is not meaningful: CAPS layout differs | n/a | PASS (S, S_MIN, S_KAN, S_MB, S_SCAN_PG, S_ACC24) |

Formal red-on-prefix: see formal_summary_prefix.md (seq, regs, kat).
