`include "cofr_defs.vh"
// T-C8: a tiled core (TILE=1, PDIM=PT) next to two untiled references (PDIM=P1 exactly, PDIM=P2 = S*PT padded), and a behavioural
// partial-sum memory (width NPAR*AW, depth NGROUP) per lane for the tiled core.
module tb_core_c8 #(
    parameter EXP = 8, SIG = 8, ACCSIG = SIG, TBITS = 6, SEEDSEL = 0,
    parameter WIDTH = 16, N_LANES = 2, NSLOT = 8, NPAR = 8, DEPTH = 7, PT = 8, P1 = 20, P2 = 24,
    parameter EPSV = 32'h3C24,
    parameter SEED_FILE = (SEEDSEL == 0) ? "recip_seed_e8s8_t6.mem" : (SEEDSEL == 1) ? "recip_seed_e8s24_t12.mem" : "recip_seed_e8s24_t8.mem",
    parameter NR_ITERS = (SEEDSEL == 2) ? 2 : 1,
    parameter NLAD = WIDTH / N_LANES, NGROUP = NSLOT * DEPTH / NPAR, NBATCHES = NLAD / NSLOT,
    parameter AW = EXP + ACCSIG, W = EXP + SIG, LNW = $clog2(N_LANES), BAW = $clog2(NBATCHES*NGROUP),
    parameter WT = $clog2(NBATCHES*NGROUP*PT), W1 = $clog2(NBATCHES*NGROUP*P1), W2 = $clog2(NBATCHES*NGROUP*P2)
) (
    input clock, nReset,
    // tiled core
    input t_w_we, input [LNW-1:0] t_w_lane, input [WT-1:0] t_w_addr, input [NPAR*W-1:0] t_w_din,
    input t_b_we, input [BAW-1:0] t_b_addr, input [NPAR*W-1:0] t_b_din,
    input t_start, input [PT*W-1:0] t_x, input [1:0] t_seed, input t_save, input t_last, input [N_LANES-1:0] t_lane_en,
    output t_busy, t_done, t_done_final, output [WIDTH*W-1:0] t_z, output [N_LANES-1:0] t_ps_we,
    // untiled references
    input a_w_we, input [LNW-1:0] a_w_lane, input [W1-1:0] a_w_addr, input [NPAR*W-1:0] a_w_din,
    input a_b_we, input [BAW-1:0] a_b_addr, input [NPAR*W-1:0] a_b_din, input a_start, input [P1*W-1:0] a_x,
    output a_busy, a_done, output [WIDTH*W-1:0] a_z,
    input b_w_we, input [LNW-1:0] b_w_lane, input [W2-1:0] b_w_addr, input [NPAR*W-1:0] b_w_din,
    input b_b_we, input [BAW-1:0] b_b_addr, input [NPAR*W-1:0] b_b_din, input b_start, input [P2*W-1:0] b_x,
    output b_busy, b_done, output [WIDTH*W-1:0] b_z
);
    wire [N_LANES*NPAR*AW-1:0] ps_q, ps_wdata;
    wire [N_LANES*BAW-1:0] ps_waddr, t_bm_addr;
    wire [N_LANES-1:0] ps_we;
    assign t_ps_we = ps_we;
    fused_coproc_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PT), .N_LANES(N_LANES),
        .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS), .EPS(EPSV), .SEED_FILE(SEED_FILE), .NR_ITERS(NR_ITERS), .LANE_MASK(1),
        .TILE(1)) u_t (
        .clock(clock), .nReset(nReset), .w_we(t_w_we), .w_lane(t_w_lane), .w_addr(t_w_addr), .w_din(t_w_din),
        .b_we(t_b_we), .b_addr(t_b_addr), .b_din(t_b_din), .start(t_start), .busy(t_busy), .done(t_done), .x(t_x), .z(t_z),
        .guard_hit(), .lane_en(t_lane_en), .wm_addr(), .bm_addr(t_bm_addr), .mem_act(),
        .wm_q({N_LANES*NPAR*W{1'b0}}), .bm_q({N_LANES*NPAR*W{1'b0}}),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0), .dbg_live_v(), .dbg_live_d(),
        .dbg_live_f(), .tile_seed(t_seed), .tile_save(t_save), .tile_last(t_last), .ps_q(ps_q), .ps_we(ps_we),
        .ps_waddr(ps_waddr), .ps_wdata(ps_wdata), .done_final(t_done_final));
    genvar l;
    generate for (l = 0; l < N_LANES; l = l + 1) begin : lane
        reg [NPAR*AW-1:0] psmem [0:NGROUP-1];
        reg [NPAR*AW-1:0] q;
        always @(posedge clock) begin
            if (ps_we[l]) psmem[ps_waddr[l*BAW +: BAW]] <= ps_wdata[l*NPAR*AW +: NPAR*AW];
            q <= psmem[t_bm_addr[l*BAW +: BAW]];
        end
        assign ps_q[l*NPAR*AW +: NPAR*AW] = q;
    end endgenerate
    fused_coproc_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(P1), .N_LANES(N_LANES),
        .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS), .EPS(EPSV), .SEED_FILE(SEED_FILE), .NR_ITERS(NR_ITERS)) u_a (
        .clock(clock), .nReset(nReset), .w_we(a_w_we), .w_lane(a_w_lane), .w_addr(a_w_addr), .w_din(a_w_din),
        .b_we(a_b_we), .b_addr(a_b_addr), .b_din(a_b_din), .start(a_start), .busy(a_busy), .done(a_done), .x(a_x), .z(a_z),
        .guard_hit(), .lane_en({N_LANES{1'b1}}), .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*W{1'b0}}),
        .bm_q({N_LANES*NPAR*W{1'b0}}), .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(),
        .dbg_live_sel(2'd0), .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1),
        .ps_q({N_LANES*NPAR*AW{1'b0}}), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());
    fused_coproc_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(P2), .N_LANES(N_LANES),
        .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS), .EPS(EPSV), .SEED_FILE(SEED_FILE), .NR_ITERS(NR_ITERS)) u_b (
        .clock(clock), .nReset(nReset), .w_we(b_w_we), .w_lane(b_w_lane), .w_addr(b_w_addr), .w_din(b_w_din),
        .b_we(b_b_we), .b_addr(b_b_addr), .b_din(b_b_din), .start(b_start), .busy(b_busy), .done(b_done), .x(b_x), .z(b_z),
        .guard_hit(), .lane_en({N_LANES{1'b1}}), .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*W{1'b0}}),
        .bm_q({N_LANES*NPAR*W{1'b0}}), .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(),
        .dbg_live_sel(2'd0), .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1),
        .ps_q({N_LANES*NPAR*AW{1'b0}}), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());
endmodule
