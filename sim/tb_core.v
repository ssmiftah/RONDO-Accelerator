// Generic bare-core testbench wrapper: fused_coproc_pipe with every chip-change
// parameter exposed. With EXT_MEM=1 it also contains the behavioural registered
// memories (the contract of spec 2.4), loaded from the same load port.
`include "cofr_defs.vh"
module tb_core #(
    parameter EXP = 8, SIG = 8, ACCSIG = SIG, TBITS = 6, SEEDSEL = 0,
    parameter WIDTH = 16, PDIM = 8, N_LANES = 2, NSLOT = 8, NPAR = 8, DEPTH = 7,
    parameter EPSV = 32'h3C24,
    parameter EXT_MEM = 0, DBG = 0, LANE_MASK = 0, NR_ITERS = 1,
    parameter SEED_FILE = (SEEDSEL == 0) ? "recip_seed_e8s8_t6.mem" :
                          (SEEDSEL == 1) ? "recip_seed_e8s24_t12.mem" : "recip_seed_e8s24_t8.mem",
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
    input start, output busy, output done,
    input [PDIM*W-1:0] x, output [WIDTH*W-1:0] z,
    output [N_LANES-1:0] guard_hit,
    input [N_LANES-1:0] lane_en,
    input [LNW-1:0] dbg_lane, input [2:0] dbg_sig, input [7:0] dbg_idx,
    output [31:0] dbg_data,
    input [1:0] dbg_live_sel, output dbg_live_v, output [31:0] dbg_live_d, output [7:0] dbg_live_f
);
    wire [N_LANES*WAW-1:0] wm_addr;
    wire [N_LANES*BAW-1:0] bm_addr;
    wire [N_LANES-1:0]     mem_act;
    wire [N_LANES*NPAR*W-1:0] wm_q, bm_q;

    fused_coproc_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG), .DEPTH(DEPTH), .WIDTH(WIDTH),
        .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS),
        .EPS(EPSV), .SEED_FILE(SEED_FILE), .EXT_MEM(EXT_MEM), .DBG(DBG),
        .LANE_MASK(LANE_MASK), .NR_ITERS(NR_ITERS)) u (
        .clock(clock), .nReset(nReset), .w_we(w_we), .w_lane(w_lane), .w_addr(w_addr),
        .w_din(w_din), .b_we(b_we), .b_addr(b_addr), .b_din(b_din), .start(start),
        .busy(busy), .done(done), .x(x), .z(z), .guard_hit(guard_hit), .lane_en(lane_en),
        .wm_addr(wm_addr), .bm_addr(bm_addr), .mem_act(mem_act), .wm_q(wm_q), .bm_q(bm_q),
        .dbg_lane(dbg_lane), .dbg_sig(dbg_sig), .dbg_idx(dbg_idx), .dbg_data(dbg_data),
        .dbg_live_sel(dbg_live_sel), .dbg_live_v(dbg_live_v), .dbg_live_d(dbg_live_d),
        .dbg_live_f(dbg_live_f), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());

    genvar l;
    generate
        if (EXT_MEM) begin : g_mem
            for (l = 0; l < N_LANES; l = l + 1) begin : lane
                reg [NPAR*W-1:0] wmem [0:NWORDS-1];
                reg [NPAR*W-1:0] bmem [0:NBWORDS-1];
                reg [NPAR*W-1:0] wq, bq;
                always @(posedge clock) begin
                    if (w_we && (N_LANES == 1 || w_lane == l)) wmem[w_addr] <= w_din;
                    if (b_we && (N_LANES == 1 || w_lane == l)) bmem[b_addr] <= b_din;
                    wq <= wmem[wm_addr[l*WAW +: WAW]];
                    bq <= bmem[bm_addr[l*BAW +: BAW]];
                end
                assign wm_q[l*NPAR*W +: NPAR*W] = wq;
                assign bm_q[l*NPAR*W +: NPAR*W] = bq;
            end
        end else begin : g_nomem
            assign wm_q = '0;
            assign bm_q = '0;
        end
    endgenerate
endmodule
