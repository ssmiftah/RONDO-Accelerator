// fused_coproc_bf16: the complete layer pinned to bf16.
//
// Exists so synthesis and power flows can target bf16 without passing a string
// generic (SEED_FILE) through tcl. Pure parameter override on
// fused_coproc_pipe -- there is no bf16-specific logic, because the datapath was
// parameterised on (EXP, SIG) from the start.
//
// bf16 and not fp16: W2 measured both on real trained coefficients. fp16 produced
// non-finite outputs at depth 7 -- the continuants grow exponentially and
// overflow its 5-bit exponent. bf16 keeps fp32's 8-bit exponent and never
// overflows. Range binds, not mantissa precision.
//
// EPS is 0.01 re-encoded in bf16 (RNE on the top 16 bits of the fp32 pattern).

module fused_coproc_bf16 #(
    // 8 = bf16 accumulator, as built. 24 carries the running sum at fp32 while
    // the operands and the stored weights stay bf16.
    parameter ACCSIG  = 8,
    parameter DEPTH   = 7,
    parameter WIDTH   = 64,
    parameter PDIM    = 40,
    parameter N_LANES = 8,
    parameter NSLOT   = 8,
    parameter NPAR    = 8,
    parameter GATE    = 1,
    // derived, mirrored from fused_coproc_pipe so the ports match
    parameter NLAD    = WIDTH / N_LANES,
    parameter NCH     = NSLOT * DEPTH,
    parameter NGROUP  = NCH / NPAR,
    parameter NBATCHES = NLAD / NSLOT,
    parameter WAW     = ((NBATCHES*NGROUP*PDIM) < 2) ? 1 : $clog2(NBATCHES*NGROUP*PDIM),
    parameter BAW     = ((NBATCHES*NGROUP) < 2) ? 1 : $clog2(NBATCHES*NGROUP),
    parameter LNW     = (N_LANES < 2) ? 1 : $clog2(N_LANES)
) (
    input                    clock,
    input                    nReset,
    input                    w_we,
    input  [LNW-1:0]         w_lane,
    input  [WAW-1:0]         w_addr,
    input  [NPAR*16-1:0]     w_din,
    input                    b_we,
    input  [BAW-1:0]         b_addr,
    input  [NPAR*16-1:0]     b_din,
    input                    start,
    output                   busy,
    output                   done,
    input  [PDIM*16-1:0]     x,
    output [WIDTH*16-1:0]    z
);
    fused_coproc_pipe #(
        .EXP(8), .SIG(8), .ACCSIG(ACCSIG),    // bf16 operands, ACCSIG accumulator
        .DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM), .N_LANES(N_LANES),
        .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(6), .GATE(GATE),
        .EPS(32'h00003C24),   // EPS is declared 32 bits wide
                                              // regardless of format; only [W-1:0] is read                       // 0.01 in bf16
        .SEED_FILE("recip_seed_e8s8_t6.mem")
    ) u_fused (
        .clock(clock), .nReset(nReset),
        .w_we(w_we), .w_lane(w_lane), .w_addr(w_addr), .w_din(w_din),
        .b_we(b_we), .b_addr(b_addr), .b_din(b_din),
        .start(start), .busy(busy), .done(done), .x(x), .z(z)
    );
endmodule
