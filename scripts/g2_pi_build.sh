#!/usr/bin/env bash
# Genesys 2 prototype of the RONDO chip: rtl/chip/*.v (genesys2_pi_top) + core + HardFloat -> bitstream (spec 13.25).
#
#   scripts/g2_pi_build.sh [--program]                 both formats (FORMATS=3)
#   FORMATS=1 scripts/g2_pi_build.sh                   bf16-only bitstream  (FORMATS=2: fp32 only)
#   CLOCK_GATE=bufgce scripts/g2_pi_build.sh           use BUFGCE clock gates (default: no gating on the FPGA)
#   SYNTH_ONLY=1 scripts/g2_pi_build.sh                synthesis + utilization only
#
# Modeled on scripts/g2_build.sh. The run directory holds the reciprocal seed tables ($readmemh is relative to it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMATS="${FORMATS:-3}"
TOP=genesys2_pi_top
OUT="$ROOT/build/genesys2_pi_f$FORMATS"
mkdir -p "$OUT"
cp -f "$ROOT"/rtl/core/recip_seed_*.mem "$OUT"/

HF=rtl/third_party/HardFloat/source
{
  for f in fp_fma_pipe affine_bank_pipe ladder_scan_inter recip_nr_pipe ladder_engine_inter fused_coproc_pipe kan_basis_inter kan_sum_bank kan_layer_pipe; do
    echo "$ROOT/rtl/core/$f.v"
  done
  for f in HardFloat_primitives HardFloat_rawFN isSigNaNRecFN fNToRecFN recFNToFN RISCV/HardFloat_specialize mulAddRecFN; do
    echo "$ROOT/$HF/$f.v"
  done
  ls "$ROOT"/rtl/chip/*.v
} > "$OUT/${TOP}_srcs.f"

DEF="RONDO_FPGA"; [ "${CLOCK_GATE:-none}" = bufgce ] && DEF="RONDO_FPGA_BUFGCE"
echo "[1/2] synth + impl  (FORMATS=$FORMATS, define $DEF)"
cd "$OUT"
vivado -mode batch -nolog -nojournal -notrace -source "$ROOT/vivado/genesys2_pi_build.tcl" \
       -tclargs "$TOP" "$OUT" "$OUT/${TOP}_srcs.f" "$FORMATS" "$DEF" "${SYNTH_ONLY:-0}" 2>&1 | tee "$OUT/build.log" \
  | grep -E "^RESULT|^FATAL|ERROR:" || true
if [ "${SYNTH_ONLY:-0}" = 1 ]; then exit 0; fi
[ -f "$OUT/$TOP.bit" ] || { echo "no bitstream produced; see $OUT/build.log"; exit 1; }
grep -E "Slice LUTs |Slice Registers |Block RAM Tile |DSPs " "$OUT/util_route.rpt" | head -4 || true
if [ "${1:-}" = "--program" ]; then
  vivado -mode batch -nolog -nojournal -notrace -source "$ROOT/vivado/genesys2_program.tcl" -tclargs "$OUT/$TOP.bit" 2>&1 \
    | grep -E "^RESULT|^FATAL|ERROR:" || true
fi
