// mat2x2_mul: fp32 product of two 2x2 matrices  P = L @ R
//
// This is THE differentiator kernel (docs/ACCELERATOR_DESIGN.md sec 3, sec 11): the
// associative operator of the continuant scan. The depth recurrence
//     K[k] = a_k*K[k+1] + nb_{k+1}*K[k+2]
// is a product of 2x2 transfer matrices M_k = [[a_k, nb_{k+1}],[1,0]], and this
// module is the combine step used to reduce M_0 @ M_1 @ ... @ M_{d-1}.
//
// Layout (row-major):  L = [[l00 l01],[l10 l11]],  R = [[r00 r01],[r10 r11]]
//   P[i][j] = L[i][0]*R[0][j] + L[i][1]*R[1][j]
//
// Built from 8 Berkeley HardFloat fused multiply-adds (see sec 11 BOM). We
// recode IEEE->HardFloat once at the inputs and decode once at the outputs, and
// keep the 8 FMAs in the recoded domain. Each P[i][j] is two dependent FMAs:
//   t = L[i][1]*R[1][j] + 0      (fused, single-rounded)
//   P = L[i][0]*R[0][j] + t      (fused, single-rounded)
//
// Combinational. fp32 (EXP=8, SIG=24). Round-to-nearest-even.

`include "cofr_defs.vh"
`include "HardFloat_consts.vi"
`include "HardFloat_specialize.vi"

module mat2x2_mul #(
    parameter EXP = `COFR_EXP,
    parameter SIG = `COFR_SIG
) (
    input  [(EXP+SIG-1):0] l00, l01, l10, l11,
    input  [(EXP+SIG-1):0] r00, r01, r10, r11,
    output [(EXP+SIG-1):0] p00, p01, p10, p11
);
    localparam RW = EXP + SIG;  // recoded width (33 for fp32)

    // --- recode IEEE -> HardFloat, once ---
    wire [RW:0] L00, L01, L10, L11, R00, R01, R10, R11, ZERO;
    fNToRecFN #(EXP, SIG) e_l00 (.in(l00), .out(L00));
    fNToRecFN #(EXP, SIG) e_l01 (.in(l01), .out(L01));
    fNToRecFN #(EXP, SIG) e_l10 (.in(l10), .out(L10));
    fNToRecFN #(EXP, SIG) e_l11 (.in(l11), .out(L11));
    fNToRecFN #(EXP, SIG) e_r00 (.in(r00), .out(R00));
    fNToRecFN #(EXP, SIG) e_r01 (.in(r01), .out(R01));
    fNToRecFN #(EXP, SIG) e_r10 (.in(r10), .out(R10));
    fNToRecFN #(EXP, SIG) e_r11 (.in(r11), .out(R11));
    fNToRecFN #(EXP, SIG) e_zero (.in({(EXP+SIG){1'b0}}), .out(ZERO));

    wire [RW:0] T00, T01, T10, T11;   // partial products L[i][1]*R[1][j]
    wire [RW:0] P00, P01, P10, P11;   // results (recoded)
    wire [4:0]  f0, f1, f2, f3, f4, f5, f6, f7;  // exception flags (unused)

    // helper macro-like instantiation via a small local task is not synth-clean;
    // instantiate the 8 FMAs explicitly for clarity.

    // P[0][0] = L00*R00 + L01*R10
    mulAddRecFN #(EXP, SIG) m_t00 (.control(`flControl_default), .op(2'b00),
        .a(L01), .b(R10), .c(ZERO), .roundingMode(`round_near_even), .out(T00), .exceptionFlags(f0));
    mulAddRecFN #(EXP, SIG) m_p00 (.control(`flControl_default), .op(2'b00),
        .a(L00), .b(R00), .c(T00),  .roundingMode(`round_near_even), .out(P00), .exceptionFlags(f1));

    // P[0][1] = L00*R01 + L01*R11
    mulAddRecFN #(EXP, SIG) m_t01 (.control(`flControl_default), .op(2'b00),
        .a(L01), .b(R11), .c(ZERO), .roundingMode(`round_near_even), .out(T01), .exceptionFlags(f2));
    mulAddRecFN #(EXP, SIG) m_p01 (.control(`flControl_default), .op(2'b00),
        .a(L00), .b(R01), .c(T01),  .roundingMode(`round_near_even), .out(P01), .exceptionFlags(f3));

    // P[1][0] = L10*R00 + L11*R10
    mulAddRecFN #(EXP, SIG) m_t10 (.control(`flControl_default), .op(2'b00),
        .a(L11), .b(R10), .c(ZERO), .roundingMode(`round_near_even), .out(T10), .exceptionFlags(f4));
    mulAddRecFN #(EXP, SIG) m_p10 (.control(`flControl_default), .op(2'b00),
        .a(L10), .b(R00), .c(T10),  .roundingMode(`round_near_even), .out(P10), .exceptionFlags(f5));

    // P[1][1] = L10*R01 + L11*R11
    mulAddRecFN #(EXP, SIG) m_t11 (.control(`flControl_default), .op(2'b00),
        .a(L11), .b(R11), .c(ZERO), .roundingMode(`round_near_even), .out(T11), .exceptionFlags(f6));
    mulAddRecFN #(EXP, SIG) m_p11 (.control(`flControl_default), .op(2'b00),
        .a(L10), .b(R01), .c(T11),  .roundingMode(`round_near_even), .out(P11), .exceptionFlags(f7));

    // --- decode HardFloat -> IEEE, once ---
    recFNToFN #(EXP, SIG) d_p00 (.in(P00), .out(p00));
    recFNToFN #(EXP, SIG) d_p01 (.in(P01), .out(p01));
    recFNToFN #(EXP, SIG) d_p10 (.in(P10), .out(p10));
    recFNToFN #(EXP, SIG) d_p11 (.in(P11), .out(p11));
endmodule
