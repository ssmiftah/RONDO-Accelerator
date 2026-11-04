// fp_mul: combinational IEEE fp32 multiply  p = x * y, via HardFloat.
// Used for the generalized-numerator output stage (f *= b0). Same recode ->
// mulAdd(c=0) -> decode pattern as mat2x2_mul. Parameterized format.

`include "cofr_defs.vh"
`include "HardFloat_consts.vi"
`include "HardFloat_specialize.vi"

module fp_mul #(
    parameter EXP = `COFR_EXP,
    parameter SIG = `COFR_SIG
) (
    input  [(EXP+SIG-1):0] x,
    input  [(EXP+SIG-1):0] y,
    output [(EXP+SIG-1):0] p
);
    localparam RW = EXP + SIG;
    wire [RW:0] xr, yr, zr, pr;
    wire [4:0]  fl;

    fNToRecFN #(EXP, SIG) ex (.in(x), .out(xr));
    fNToRecFN #(EXP, SIG) ey (.in(y), .out(yr));
    fNToRecFN #(EXP, SIG) ez (.in({(EXP+SIG){1'b0}}), .out(zr));

    mulAddRecFN #(EXP, SIG) mm (
        .control(`flControl_default), .op(2'b00),
        .a(xr), .b(yr), .c(zr),
        .roundingMode(`round_near_even), .out(pr), .exceptionFlags(fl)
    );
    recFNToFN #(EXP, SIG) po (.in(pr), .out(p));
endmodule
