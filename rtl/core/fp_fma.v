// fp_fma: combinational IEEE fp32 fused multiply-add  p = a*b + c, via HardFloat.
// Single-rounded. Used by kscan (scalar continuant recurrence). Parameterized.

`include "cofr_defs.vh"
`include "HardFloat_consts.vi"
`include "HardFloat_specialize.vi"

module fp_fma #(
    parameter EXP = `COFR_EXP,
    parameter SIG = `COFR_SIG
) (
    input  [(EXP+SIG-1):0] a,
    input  [(EXP+SIG-1):0] b,
    input  [(EXP+SIG-1):0] c,
    output [(EXP+SIG-1):0] p
);
    localparam RW = EXP + SIG;
    wire [RW:0] ar, br, cr, pr;
    wire [4:0]  fl;

    fNToRecFN #(EXP, SIG) ea (.in(a), .out(ar));
    fNToRecFN #(EXP, SIG) eb (.in(b), .out(br));
    fNToRecFN #(EXP, SIG) ec (.in(c), .out(cr));
    mulAddRecFN #(EXP, SIG) mm (
        .control(`flControl_default), .op(2'b00),
        .a(ar), .b(br), .c(cr),
        .roundingMode(`round_near_even), .out(pr), .exceptionFlags(fl)
    );
    recFNToFN #(EXP, SIG) po (.in(pr), .out(p));
endmodule
