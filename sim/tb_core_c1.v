// T-C1 testbench: the fixed fused_coproc_pipe next to an unmodified copy (renamed
// fused_coproc_pipe_old by the runner), loaded identically, plus a bf16 kan_layer_pipe.
`include "cofr_defs.vh"
module tb_core_c1 #(
    parameter EXP = 8, SIG = 8, ACCSIG = SIG, TBITS = 6,
    parameter WIDTH = 16, PDIM = 8, N_LANES = 2, NSLOT = 8, NPAR = 8, DEPTH = 7,
    parameter EPSV = 32'h3C24,
    parameter SEED_FILE = (SIG == 8) ? "recip_seed_e8s8_t6.mem" : "recip_seed_e8s24_t12.mem",
    parameter NLAD = WIDTH / N_LANES,
    parameter NCH = NSLOT * DEPTH, parameter NGROUP = NCH / NPAR,
    parameter NBATCHES = NLAD / NSLOT,
    parameter WAW = $clog2(NBATCHES*NGROUP*PDIM), BAW = $clog2(NBATCHES*NGROUP),
    parameter LNW = $clog2(N_LANES), W = EXP + SIG
) (
    input clock, nReset,
    input w_we, input [LNW-1:0] w_lane, input [WAW-1:0] w_addr, input [NPAR*W-1:0] w_din,
    input b_we, input [BAW-1:0] b_addr, input [NPAR*W-1:0] b_din,
    input [PDIM*W-1:0] x,
    input start_new, start_old,
    output busy_new, done_new, busy_old, done_old,
    output [WIDTH*W-1:0] z_new, z_old,
    // KAN (bf16, defaults P_IN=8 N_OUT=16 LANES=2 NOB=8 NMAC=8)
    input k_w_we, input [0:0] k_w_lane, input [5:0] k_w_addr, input [127:0] k_w_din,
    input [127:0] k_x, input k_start,
    output k_busy, k_done, output [255:0] k_y
);
    fused_coproc_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH),
        .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS),
        .EPS(EPSV), .SEED_FILE(SEED_FILE)) u_new (
        .clock(clock), .nReset(nReset), .w_we(w_we), .w_lane(w_lane), .w_addr(w_addr),
        .w_din(w_din), .b_we(b_we), .b_addr(b_addr), .b_din(b_din), .start(start_new),
        .busy(busy_new), .done(done_new), .x(x), .z(z_new), .guard_hit(), .lane_en({N_LANES{1'b1}}),
        .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*W{1'b0}}), .bm_q({N_LANES*NPAR*W{1'b0}}),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0), .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());
    fused_coproc_pipe_old #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH),
        .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS),
        .EPS(EPSV), .SEED_FILE(SEED_FILE)) u_old (
        .clock(clock), .nReset(nReset), .w_we(w_we), .w_lane(w_lane), .w_addr(w_addr),
        .w_din(w_din), .b_we(b_we), .b_addr(b_addr), .b_din(b_din), .start(start_old),
        .busy(busy_old), .done(done_old), .x(x), .z(z_old));
    kan_layer_pipe #(.EXP(8), .SIG(8)) u_kan (
        .clock(clock), .nReset(nReset), .w_we(k_w_we), .w_lane(k_w_lane), .w_addr(k_w_addr),
        .w_din(k_w_din), .start(k_start), .busy(k_busy), .done(k_done), .x(k_x), .y(k_y));
endmodule
