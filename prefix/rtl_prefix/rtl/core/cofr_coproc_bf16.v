// cofr_coproc_bf16: the coprocessor pinned to bf16.
//
// Exists so the synthesis and power flows can target bf16 without passing a
// string generic (SEED_FILE) through tcl, which is fragile. Everything here is
// a parameter override on cofr_coproc_inter -- there is no bf16-specific logic,
// because the datapath was parameterised on (EXP, SIG) from the start.
//
// Why bf16 and not fp16: W2 measured both on real trained coefficients. fp16
// produced non-finite outputs at depth 7 because the continuants grow
// exponentially and overflow its 5-bit exponent. bf16 keeps fp32's 8-bit
// exponent and never overflows. Range is the binding constraint, not mantissa
// precision -- fp16 has *more* mantissa bits than bf16 and still loses.
//
// EPS is 0.01 re-encoded in bf16 (round-to-nearest-even on the top 16 bits of
// the fp32 pattern): 0x3C24.

module cofr_coproc_bf16 #(
    parameter DEPTH   = 7,
    parameter WIDTH   = 48,
    parameter N_LANES = 2,
    parameter NSLOT   = 8,
    parameter GATE    = 1
) (
    input                     clock,
    input                     nReset,
    input                     start,
    output                    busy,
    output                    done,
    input  [WIDTH*DEPTH*16-1:0] a_all,
    input  [WIDTH*DEPTH*16-1:0] b_all,
    output [WIDTH*16-1:0]       z
);
    cofr_coproc_inter #(
        .EXP(8), .SIG(8),                    // bf16
        .DEPTH(DEPTH), .WIDTH(WIDTH), .N_LANES(N_LANES), .NSLOT(NSLOT),
        .TBITS(6),                           // 6-bit index into a 7-bit fraction
        .GEN(0), .GATE(GATE),
        .EPS(32'h00003C24),   // EPS is declared 32 bits wide
                                              // regardless of format; only [W-1:0] is read                      // 0.01 in bf16
        .SEED_FILE("recip_seed_e8s8_t6.mem")
    ) u_coproc (
        .clock(clock), .nReset(nReset), .start(start),
        .busy(busy), .done(done),
        .a_all(a_all), .b_all(b_all), .z(z)
    );
endmodule
