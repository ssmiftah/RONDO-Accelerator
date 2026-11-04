`include "cofr_defs.vh"
`timescale 1ns/1ps
module tb_core_eq;
  parameter EXP=8, SIG=8, ACCSIG=8, TBITS=6, WIDTH=16, PDIM=8, N_LANES=2;
  parameter [15:0] EPSB = 16'h3C24;
  parameter SEED = 1, NINF = 60;   // all of SIG/ACCSIG/TBITS/WIDTH/PDIM/NINF/SEED are overridden per config by run_core_eq.py
  localparam W = EXP+SIG;
  localparam NLAD=WIDTH/N_LANES, NCH=8*7, NGROUP=NCH/8, NBATCHES=NLAD/8;
  localparam WAW = $clog2(NBATCHES*NGROUP*PDIM), BAW = (NBATCHES*NGROUP<2)?1:$clog2(NBATCHES*NGROUP);
  localparam LNW = (N_LANES<2)?1:$clog2(N_LANES);
  reg clk=0, rst_n=0; always #5 clk=~clk;
  reg w_we=0, b_we=0, start=0; reg [LNW-1:0] w_lane=0; reg [WAW-1:0] w_addr=0; reg [BAW-1:0] b_addr=0;
  reg [8*W-1:0] w_din=0, b_din=0; reg [PDIM*W-1:0] x=0;
  wire busy_n, done_n, busy_o, done_o; wire [WIDTH*W-1:0] z_n, z_o;
  localparam [(`COFR_EXP+`COFR_SIG)-1:0] EPS = (SIG==8) ? {16'd0,EPSB} : `COFR_EPS;
  localparam SF = (SIG==8) ? "recip_seed_e8s8_t6.mem" : "recip_seed_e8s24_t12.mem";
  fused_coproc_pipe #(.EXP(EXP),.SIG(SIG),.ACCSIG(ACCSIG),.WIDTH(WIDTH),.PDIM(PDIM),.N_LANES(N_LANES),.TBITS(TBITS),.EPS(EPS),.SEED_FILE(SF)) u_new (
    .clock(clk),.nReset(rst_n),.w_we(w_we),.w_lane(w_lane),.w_addr(w_addr),.w_din(w_din),.b_we(b_we),.b_addr(b_addr),.b_din(b_din),
    .start(start),.busy(busy_n),.done(done_n),.x(x),.z(z_n));
  fused_coproc_pipe_old #(.EXP(EXP),.SIG(SIG),.ACCSIG(ACCSIG),.WIDTH(WIDTH),.PDIM(PDIM),.N_LANES(N_LANES),.TBITS(TBITS),.EPS(EPS),.SEED_FILE(SF)) u_old (
    .clock(clk),.nReset(rst_n),.w_we(w_we),.w_lane(w_lane),.w_addr(w_addr),.w_din(w_din),.b_we(b_we),.b_addr(b_addr),.b_din(b_din),
    .start(start),.busy(busy_o),.done(done_o),.x(x),.z(z_o));
  integer seed, i, k, l, a, nerr=0, ndone=0, cyc=0, gap;
  reg fin = 1'b0;  // set at the end (read by test_core_eq.py)
  function [W-1:0] rnd_el(input integer dummy);
    reg [31:0] r; begin r=$random(seed);
      // mostly moderate magnitudes, sometimes specials
      case (r[3:0])
        0: rnd_el = {r[31], {(W-1){1'b0}}};            // +-0
        1: rnd_el = {r[31], {EXP{1'b0}}, r[SIG-2+4:4]}; // subnormal-ish
        default: rnd_el = {r[31], 8'd120 + {5'd0,r[6:4]}, r[SIG-2+8:8]};
      endcase end endfunction
  always @(posedge clk) begin cyc<=cyc+1;
    if (rst_n && (busy_n!==busy_o || done_n!==done_o || (done_n && z_n!==z_o))) begin
      nerr=nerr+1; if (nerr<5) $display("MISMATCH cyc %0d busy %b/%b done %b/%b", cyc, busy_n,busy_o,done_n,done_o); end
    if (done_n) ndone = ndone+1;
  end
  initial begin
    seed = SEED;
    repeat(3) @(posedge clk); rst_n=1; @(posedge clk);
    for (l=0;l<N_LANES;l=l+1) begin
      for (a=0;a<NBATCHES*NGROUP*PDIM;a=a+1) begin
        @(negedge clk); w_we=1; w_lane=l; w_addr=a; for(k=0;k<8;k=k+1) w_din[k*W+:W]=rnd_el(0);
      end
    end
    @(negedge clk); w_we=0;
    for (l=0;l<N_LANES;l=l+1) for (a=0;a<NBATCHES*NGROUP;a=a+1) begin
      @(negedge clk); b_we=1; w_lane=l; b_addr=a; for(k=0;k<8;k=k+1) b_din[k*W+:W]=rnd_el(0); end
    @(negedge clk); b_we=0;
    for (i=0;i<NINF;i=i+1) begin
      @(negedge clk); for(k=0;k<PDIM;k=k+1) x[k*W+:W]=rnd_el(0);
      gap = $random(seed) & 3;
      repeat(gap) @(negedge clk);
      start=1; @(negedge clk); start=0;
      // random extra start pulse while busy (both must ignore it identically)
      if (($random(seed) & 7)==0) begin repeat(5) @(negedge clk); start=1; @(negedge clk); start=0; end
      wait(done_n); @(negedge clk);   // next start >= 1 edge after done (no start in the done cycle)
    end
    repeat(20) @(negedge clk);
    $display("EQ RESULT SIG=%0d WIDTH=%0d PDIM=%0d: inferences=%0d mismatches=%0d", SIG, WIDTH, PDIM, ndone, nerr);
    fin = 1'b1;
  end
endmodule
