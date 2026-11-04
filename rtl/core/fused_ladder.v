// fused_ladder: affine_unit -> ladder_engine, with the coefficients kept inside.
//
// The point: `a` never appears at a port. The module is handed the shared input
// x and returns f; the weights are loaded once and stay resident. Compare with
// ladder_engine, whose `a` port is exactly the traffic fusion removes.
//
// Latency = DEPTH*ceil(PDIM/NMAC) (affine) + DEPTH-1 (scan) + divider.

`include "cofr_defs.vh"

module fused_ladder #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter PDIM  = 8,
    parameter NMAC  = 1,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS,
    // derived -- do not override
    parameter CHUNKS = (PDIM + NMAC - 1) / NMAC,
    parameter NWORDS = DEPTH * CHUNKS,
    parameter WAW    = (NWORDS < 2) ? 1 : $clog2(NWORDS)
) (
    input                         clock,
    input                         nReset,
    input                         w_we,
    input  [WAW-1:0]              w_addr,
    input  [NMAC*(EXP+SIG)-1:0]   w_din,
    input                         in_valid,
    output                        in_ready,
    input  [PDIM*(EXP+SIG)-1:0]   x,
    input  [DEPTH*(EXP+SIG)-1:0]  bias,
    output                        out_valid,
    output [(EXP+SIG)-1:0]        f
);
    localparam integer W = EXP + SIG;

    wire               aff_ready, aff_ovalid;
    wire [DEPTH*W-1:0] a_int;          // internal only -- this is the fusion
    affine_unit #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .PDIM(PDIM), .NMAC(NMAC)) u_aff (
        .clock(clock), .nReset(nReset),
        .w_we(w_we), .w_addr(w_addr), .w_din(w_din),
        .in_valid(in_valid), .in_ready(aff_ready),
        .x(x), .bias(bias),
        .out_valid(aff_ovalid), .a(a_int)
    );

    reg eng_start;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) eng_start <= 1'b0;
        else         eng_start <= aff_ovalid;
    end

    wire eng_ready;
    ladder_engine #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .GEN(0), .EPS(EPS)) u_eng (
        .clock(clock), .nReset(nReset),
        .in_valid(eng_start), .in_ready(eng_ready),
        .a(a_int), .b({DEPTH*W{1'b0}}),
        .out_valid(out_valid), .f(f)
    );

    assign in_ready = aff_ready & eng_ready;
endmodule
