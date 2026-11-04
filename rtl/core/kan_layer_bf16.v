// kan_layer_bf16: kan_layer_pipe pinned to bf16 (EXP=8, SIG=8).
//
// Pure parameter override, like fused_coproc_bf16: it exists so the synthesis
// and power flows can select the format by top-level name. There is no
// reciprocal in a KAN layer, so no seed table and no EPS to re-encode.

module kan_layer_bf16 #(
    parameter DEPTH   = 7,
    parameter P_IN    = 40,
    parameter N_OUT   = 64,
    parameter N_LANES = 8,
    parameter NOB     = 8,
    parameter NMAC    = 8,
    parameter NBAS    = 1,
    parameter GATE    = 1,
    // derived, mirrored from kan_layer_pipe so the ports match
    parameter NOUTL    = N_OUT / N_LANES,
    parameter NGROUP   = NOB * (DEPTH + 1) / NMAC,
    parameter NBATCHES = NOUTL / NOB,
    parameter WAW      = ((NBATCHES*NGROUP*P_IN) < 2) ? 1 : $clog2(NBATCHES*NGROUP*P_IN),
    parameter LNW      = (N_LANES < 2) ? 1 : $clog2(N_LANES)
) (
    input                    clock,
    input                    nReset,
    input                    w_we,
    input  [LNW-1:0]         w_lane,
    input  [WAW-1:0]         w_addr,
    input  [NMAC*16-1:0]     w_din,
    input                    start,
    output                   busy,
    output                   done,
    input  [P_IN*16-1:0]     x,
    output [N_OUT*16-1:0]    y
);
    kan_layer_pipe #(
        .EXP(8), .SIG(8), .DEPTH(DEPTH), .P_IN(P_IN), .N_OUT(N_OUT),
        .N_LANES(N_LANES), .NOB(NOB), .NMAC(NMAC), .NBAS(NBAS), .GATE(GATE)
    ) u_kan (
        .clock(clock), .nReset(nReset),
        .w_we(w_we), .w_lane(w_lane), .w_addr(w_addr), .w_din(w_din),
        .start(start), .busy(busy), .done(done), .x(x), .y(y)
    );
endmodule
