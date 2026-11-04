#!/bin/bash
# Expected-fatal elaboration cases (spec 7.1/10.1/18.5; fix plan task 4). Each case builds rondo_dev with illegal parameters under xsim and
# expects the documented $fatal text. usage: elab_neg.sh [RTL_ROOT]
export PATH=${VIVADO_BIN:-/home/CAD/2025.2/Vivado/bin}:$PATH
ROOT=$(cd "$(dirname "$0")/../.." && pwd); RR=${1:-$ROOT}; W=$ROOT/build/verif/elab_neg; mkdir -p $W; cd $W
$ROOT/verif/scripts/gen_filelists.sh "$RR" $W/fl
HF=$ROOT/rtl/third_party/HardFloat/source; pass=0; fail=0
run() { # name params-generic-string expected-text
  rm -rf xsim.dir; cat > top_neg.sv <<EOT
module top_neg; rondo_dev #($2) d(.clk(1'b0), .rst_n(1'b0), .test_mode(1'b0), .rb_req_valid(1'b0), .rb_req_ready(), .rb_req_we(1'b0), .rb_req_addr(24'd0), .rb_req_wdata(32'd0), .rb_rsp_valid(), .rb_rsp_ready(1'b1), .rb_rsp_rdata(), .rb_rsp_err(), .irq(), .busy_pin(), .st_pass(), .status8(), .clkout(), .clk_div(), .clk_src(), .crc_en(), .div_applied(2'b0), .src_applied(1'b0), .spi_err_frame(1'b0), .spi_err_crc(1'b0), .spi_frame_end(1'b0), .bist_strap(1'b0), .pg_req(), .lclk_obs(), .checksum_o(), .fmt_o(), .heartbeat_o(), .err_any_o()); endmodule
EOT
  xvlog -sv --relax -i $HF -i $HF/RISCV -i $RR/rtl -i $RR/rtl/chip -f $W/fl/hardfloat.f -f $W/fl/core.f -f $W/fl/chip.f top_neg.sv > xv_$1.log 2>&1
  xelab --relax --timescale 1ns/1ps top_neg -s n_$1 > xe_$1.log 2>&1
  if grep -q "$3" xe_$1.log; then echo "PASS  $1 (fatal: $3)"; pass=$((pass+1)); else echo "FAIL  $1 (expected '$3')"; tail -3 xe_$1.log; fail=$((fail+1)); fi
}
S=".WIDTH(16),.PDIM(8),.N_LANES(2),.DEPTH(7)"
run accsig24_tile "$S,.TILE(1),.ACCSIG_BF16(24)" "TILE=1 needs ACCSIG_BF16=8"
run npar6 "$S,.NPAR(6)" "NPAR must be a power of two"
run tbits10 "$S,.TBITS_FP32(10)" "TBITS_FP32 must be 8 or 12"
run nr3 "$S,.NR_ITERS_FP32(3)" "NR_ITERS_FP32 must be 1 or 2"
run trace_depth "$S,.TRACE_DEPTH(40000)" "2\*TRACE_DEPTH > 65536"
run nxbuf_big "$S,.NXBUF(65536)" "NXBUF"
# positive control: legal build elaborates
rm -rf xsim.dir; run legal "$S" "ZZZ_never_matches" 2>/dev/null | sed 's/FAIL/(positive control builds: see below)/' >/dev/null
if grep -q "FATAL\|ERROR" xe_legal.log; then echo "FAIL  legal build has errors"; fail=$((fail+1)); else echo "PASS  legal build elaborates"; pass=$((pass+1)); fi
echo "elab_neg: pass=$pass fail=$fail"; [ $fail -eq 0 ]
