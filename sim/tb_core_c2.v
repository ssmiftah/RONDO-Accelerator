`include "cofr_defs.vh"
module tb_core_c2 #(
    parameter EXP = 8, SIG = 8, ACCSIG = SIG, TBITS = 6, SEEDSEL = 0,
    parameter WIDTH = 16, PDIM = 8, N_LANES = 2, NSLOT = 8, NPAR = 8, DEPTH = 7,
    parameter EPSV = 32'h3C24,
    parameter SEED_FILE = (SEEDSEL == 0) ? "recip_seed_e8s8_t6.mem" : "recip_seed_e8s24_t12.mem",
    parameter NLAD = WIDTH / N_LANES,
    parameter NCH = NSLOT * DEPTH, parameter NGROUP = NCH / NPAR,
    parameter NBATCHES = NLAD / NSLOT,
    parameter WAW = $clog2(NBATCHES*NGROUP*PDIM), BAW = $clog2(NBATCHES*NGROUP),
    parameter LNW = $clog2(N_LANES), W = EXP + SIG
) (
    input clock, nReset,
    input w_we, input [LNW-1:0] w_lane, input [WAW-1:0] w_addr, input [NPAR*W-1:0] w_din,
    input b_we, input [BAW-1:0] b_addr, input [NPAR*W-1:0] b_din,
    input start, output busy, output done,
    input [PDIM*W-1:0] x, output [WIDTH*W-1:0] z,
    output [N_LANES-1:0] guard_hit
);
    fused_coproc_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH),
        .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS),
        .EPS(EPSV), .SEED_FILE(SEED_FILE)) u (
        .clock(clock), .nReset(nReset), .w_we(w_we), .w_lane(w_lane), .w_addr(w_addr),
        .w_din(w_din), .b_we(b_we), .b_addr(b_addr), .b_din(b_din), .start(start),
        .busy(busy), .done(done), .x(x), .z(z), .guard_hit(guard_hit), .lane_en({N_LANES{1'b1}}),
        .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*W{1'b0}}), .bm_q({N_LANES*NPAR*W{1'b0}}),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0), .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());
endmodule
