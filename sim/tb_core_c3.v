// T-C3: EXT_MEM=0 core vs EXT_MEM=1 core + behavioural registered memories,
// loaded from the same port and started together.
`include "cofr_defs.vh"
module tb_core_c3 #(
    parameter EXP = 8, SIG = 8, ACCSIG = SIG, TBITS = 6, SEEDSEL = 0,
    parameter WIDTH = 16, PDIM = 8, N_LANES = 2, NSLOT = 8, NPAR = 8, DEPTH = 7,
    parameter EPSV = 32'h3C24,
    parameter SEED_FILE = (SEEDSEL == 0) ? "recip_seed_e8s8_t6.mem" : "recip_seed_e8s24_t12.mem",
    parameter NLAD = WIDTH / N_LANES,
    parameter NCH = NSLOT * DEPTH, parameter NGROUP = NCH / NPAR,
    parameter NBATCHES = NLAD / NSLOT,
    parameter NWORDS = NBATCHES*NGROUP*PDIM, NBWORDS = NBATCHES*NGROUP,
    parameter WAW = $clog2(NWORDS), BAW = $clog2(NBWORDS),
    parameter LNW = $clog2(N_LANES), W = EXP + SIG
) (
    input clock, nReset,
    input w_we, input [LNW-1:0] w_lane, input [WAW-1:0] w_addr, input [NPAR*W-1:0] w_din,
    input b_we, input [BAW-1:0] b_addr, input [NPAR*W-1:0] b_din,
    input start, input [PDIM*W-1:0] x,
    output busy_i, done_i, busy_e, done_e,
    output [WIDTH*W-1:0] z_i, z_e,
    output [N_LANES-1:0] mem_act_o
);
    fused_coproc_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH),
        .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS),
        .EPS(EPSV), .SEED_FILE(SEED_FILE)) u_int (
        .clock(clock), .nReset(nReset), .w_we(w_we), .w_lane(w_lane), .w_addr(w_addr),
        .w_din(w_din), .b_we(b_we), .b_addr(b_addr), .b_din(b_din), .start(start),
        .busy(busy_i), .done(done_i), .x(x), .z(z_i), .guard_hit(), .lane_en({N_LANES{1'b1}}),
        .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*W{1'b0}}), .bm_q({N_LANES*NPAR*W{1'b0}}),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0), .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());

    wire [N_LANES*WAW-1:0] wm_addr;
    wire [N_LANES*BAW-1:0] bm_addr;
    wire [N_LANES-1:0]     mem_act;
    wire [N_LANES*NPAR*W-1:0] wm_q, bm_q;
    assign mem_act_o = mem_act;
    fused_coproc_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH),
        .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS),
        .EPS(EPSV), .SEED_FILE(SEED_FILE), .EXT_MEM(1)) u_ext (
        .clock(clock), .nReset(nReset), .w_we(1'b0), .w_lane({LNW{1'b0}}), .w_addr({WAW{1'b0}}),
        .w_din({NPAR*W{1'b0}}), .b_we(1'b0), .b_addr({BAW{1'b0}}), .b_din({NPAR*W{1'b0}}),
        .start(start), .busy(busy_e), .done(done_e), .x(x), .z(z_e), .guard_hit(), .lane_en({N_LANES{1'b1}}),
        .wm_addr(wm_addr), .bm_addr(bm_addr), .mem_act(mem_act), .wm_q(wm_q), .bm_q(bm_q),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0), .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());

    genvar l;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            reg [NPAR*W-1:0] wmem [0:NWORDS-1];
            reg [NPAR*W-1:0] bmem [0:NBWORDS-1];
            reg [NPAR*W-1:0] wq, bq;
            always @(posedge clock) begin
                if (w_we && w_lane == l) wmem[w_addr] <= w_din;
                if (b_we && w_lane == l) bmem[b_addr] <= b_din;
                wq <= wmem[wm_addr[l*WAW +: WAW]];
                bq <= bmem[bm_addr[l*BAW +: BAW]];
            end
            assign wm_q[l*NPAR*W +: NPAR*W] = wq;
            assign bm_q[l*NPAR*W +: NPAR*W] = bq;
        end
    endgenerate
endmodule
