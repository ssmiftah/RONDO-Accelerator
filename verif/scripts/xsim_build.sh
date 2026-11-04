#!/bin/bash
# usage: xsim_build.sh <top> <cfg_id> [RTL_ROOT] [extra xvlog defines...]
#   builds build/verif/xsim/<top>_<cfg>[_prefix] once (snapshot reused). cfg_id: S, F, S_TB2, S_MB, S_SCAN_PG, S_MIN, S_ACC24, S_KAN, S_CNT
#   RTL_ROOT default = main tree; pass build/verif/rtl_prefix for the pre-fix configuration.
set -e
export PATH=${VIVADO_BIN:-/home/CAD/2025.2/Vivado/bin}:$PATH
ROOT=$(cd "$(dirname "$0")/../.." && pwd); V=$ROOT/verif
TOP=$1; CFG=$2; RR=${3:-$ROOT}; RR=$(cd "$RR" && pwd); shift; shift; [ $# -gt 0 ] && shift
TOPDEF=""; TAG=${TOP}_${CFG}
if [ "$TOP" = tb_top ]; then TOPSEL=${TOPSEL:-DEV}; TOPDEF="-d TOP_$TOPSEL"; TAG=${TOP}_${TOPSEL}_${CFG}; fi
[ "$RR" != "$ROOT" ] && TAG=${TAG}_prefix
TAG=${TAG}${TAGSUFFIX}
OUT=$ROOT/build/verif/xsim/$TAG; mkdir -p $OUT; cd $OUT
FL=$OUT/fl; $V/scripts/gen_filelists.sh "$RR" $FL
make -s -C $V/model >/dev/null
HF=$ROOT/rtl/third_party/HardFloat/source
INC="-i $HF -i $HF/RISCV -i $RR/rtl -i $RR/rtl/chip -i $V/common/cfg -i $V/model -i $V/uvm -i $V/uvm/env -i $V/uvm/agents -i $V/uvm/tb"
SVA=$(ls $RR/rtl/chip/sva/*.v | tr '\n' ' ')
# UVM sources: filelist entries are relative to the repository root
UVMSRC=""; [ -f $V/uvm/filelist_$TOP.f ] && { sed "s|^|$ROOT/|" $V/uvm/filelist_$TOP.f > $OUT/uvm_src.f; UVMSRC="-f $OUT/uvm_src.f"; }
TOPF=$FL/chip.f; EXTRA=""; if [ "$TOP" = tb_top ] && [ "$TOPSEL" = CHIP ]; then EXTRA="$FL/chip_top.f"; fi
set +e
COREF="-f $FL/hardfloat.f -f $FL/core.f"; DPLIB=""
if [ -n "$CC_SPLIT" ]; then   # code-coverage builds: datapath/HardFloat in library dp (not instrumented), chip RTL + TB in work
  xvlog -sv --relax --work dp $INC $XVLOG_EXTRA $COREF > xvlog_dp.log 2>&1 || { echo xvlog dp failed; exit 1; }
  COREF=""; DPLIB="-L dp"
fi
xvlog -sv -L uvm --relax $INC -d CFG_$CFG $TOPDEF $XVLOG_EXTRA "$@" $COREF -f $FL/chip.f $( [ -n "$EXTRA" ] && echo -f $EXTRA ) $SVA $UVMSRC > xvlog.log 2>&1
rc=$?; grep -E "^ERROR" xvlog.log | head -20
[ $rc -ne 0 ] && { echo "xvlog failed (see $OUT/xvlog.log)"; exit 1; }
xelab -L uvm $DPLIB --relax --timescale 1ns/1ps -s snap --sv_root $ROOT/build/verif/model --sv_lib dpi --debug off $ELAB_ARGS work.$TOP > xelab.log 2>&1
rc=$?; grep -E "^ERROR" xelab.log | head -20
[ $rc -ne 0 ] && { echo "xelab failed (see $OUT/xelab.log)"; exit 1; }
# seeds for $readmemh
cp $RR/rtl/core/recip_seed_*.mem $OUT/ 2>/dev/null || cp $ROOT/rtl/core/recip_seed_*.mem $OUT/
echo "built $OUT"
