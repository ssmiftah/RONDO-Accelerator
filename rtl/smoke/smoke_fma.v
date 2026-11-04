// M0 smoke DUT: fp32 fused multiply-add via Berkeley HardFloat.
//
// Purpose: prove the toolchain (Icarus/Verilator + cocotb) and the vendored
// HardFloat IP compile and produce IEEE-correct arithmetic end-to-end, BEFORE
// we build any CoFrNet-specific logic. This exercises exactly the primitives the
// 2x2 transfer-matrix combine (mat2x2_mul) will be built from: recode -> FMA ->
// decode.
//
// y = a*b + c   (single-rounded fused, round-to-nearest-even)

`include "HardFloat_consts.vi"
`include "HardFloat_specialize.vi"

module smoke_fma #(
    parameter EXP = 8,   // fp32 exponent width
    parameter SIG = 24   // fp32 significand width (incl. hidden bit)
) (
    input  [(EXP + SIG - 1):0] a_ieee,
    input  [(EXP + SIG - 1):0] b_ieee,
    input  [(EXP + SIG - 1):0] c_ieee,
    output [(EXP + SIG - 1):0] y_ieee,
    output [4:0]               flags
);
    // IEEE-754 -> HardFloat recoded format
    wire [(EXP + SIG):0] a_rec, b_rec, c_rec, y_rec;
    fNToRecFN #(EXP, SIG) u_ra (.in(a_ieee), .out(a_rec));
    fNToRecFN #(EXP, SIG) u_rb (.in(b_ieee), .out(b_rec));
    fNToRecFN #(EXP, SIG) u_rc (.in(c_ieee), .out(c_rec));

    // Fused multiply-add: op = 2'b00 -> (a*b) + c
    mulAddRecFN #(EXP, SIG) u_fma (
        .control       (`flControl_default),
        .op            (2'b00),
        .a             (a_rec),
        .b             (b_rec),
        .c             (c_rec),
        .roundingMode  (`round_near_even),
        .out           (y_rec),
        .exceptionFlags(flags)
    );

    // recoded -> IEEE-754
    recFNToFN #(EXP, SIG) u_ro (.in(y_rec), .out(y_ieee));
endmodule
