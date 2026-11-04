#!/usr/bin/env bash
# T-STRUCT (spec 3.4): the asynchronous reset nets of the two layers (rondo_seq.core_rst_n) must be driven by a flop, not by a decode.
# Yosys on rondo_seq alone: the input cone of core_rst_n, back to the first flops, may contain only $mux cells (the test-mode bypass)
# (spec 11.7). Any comparison / logic cell in the cone fails the check.
# usage: scripts/chip_struct.sh [rondo_seq.v]   (the optional argument lets the check be run on a backup copy)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SEQ="${1:-rtl/chip/rondo_seq.v}"
OUT=build/chip/lint; mkdir -p "$OUT"
yosys -q -l "$OUT/struct.log" -p "
read_verilog -sv $SEQ rtl/chip/rondo_cksum.v
hierarchy -top rondo_seq
proc; opt; wreduce; opt_clean
select -list-mod
select -assert-none w:core_rst_n %ci*:-\$adff,\$adffe,\$dff,\$dffe,\$sdff t:* %i t:\$mux %d t:\$adff %d t:\$adffe %d t:\$dff %d t:\$dffe %d t:\$sdff %d
" > "$OUT/struct.out" 2>&1
rc=$?
if [ $rc -eq 0 ]; then echo "STRUCT core_rst_n driven by flop (+ test-mode mux only): PASS";
else echo "STRUCT core_rst_n cone contains logic besides the test-mode mux: FAIL (see $OUT/struct.log, $OUT/struct.out)"; fi
exit $rc
