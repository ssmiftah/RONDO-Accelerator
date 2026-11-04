// ladder_scan: compute the continuant K0, K1 of one depth-DEPTH ladder.
//
// Reduces the transfer-matrix product P = M_0 @ M_1 @ ... @ M_{DEPTH-1}, where
//   M_k = [[a_k, 1], [1, 0]]        (unit numerators; nb_{k+1}=1)
// and returns the first column of P:  K0 = P[0][0], K1 = P[1][0].
// This matches CoFrContinuant / continuant_scan.py (unit-numerator case), where
// f = K1 / K0 is applied downstream (see recip_wrap / ladder_top).
//
// Left-associated combinational fold of mat2x2_mul (the associative scan
// operator). Chain length DEPTH-1; combinational (see ladder_scan_pipe for the
// registered/FPGA-timing variant). The top-right of the LAST matrix does not
// affect the first column of P, so all top-rights are 1.0.
//
// Parameterized in numeric format (EXP,SIG) and DEPTH; no fp32 literals.

`include "cofr_defs.vh"

module ladder_scan #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH
) (
    input  [DEPTH*(EXP+SIG)-1:0] a,
    output [(EXP+SIG)-1:0]       k0,
    output [(EXP+SIG)-1:0]       k1
);
    localparam integer W    = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;    // IEEE exponent bias
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};   // 1.0 in this format
    localparam [W-1:0] F_ZERO = {W{1'b0}};                       // 0.0

    // Running product P (2x2) after folding matrices 0..stage. The chain is
    // strictly feed-forward per element (stage k reads [k-1], writes [k]); the
    // linter's whole-array node analysis reports a *false* UNOPTFLAT loop for it,
    // waived by file in sim/cofr_waivers.vlt (see note there).
    wire [W-1:0] P00 [0:DEPTH-1];
    wire [W-1:0] P01 [0:DEPTH-1];
    wire [W-1:0] P10 [0:DEPTH-1];
    wire [W-1:0] P11 [0:DEPTH-1];

    // Stage 0: P = M_0 = [[a_0, 1], [1, 0]]
    assign P00[0] = a[0 +: W];
    assign P01[0] = F_ONE;
    assign P10[0] = F_ONE;
    assign P11[0] = F_ZERO;

    genvar k;
    generate
        for (k = 1; k < DEPTH; k = k + 1) begin : chain
            // P[k] = P[k-1] @ M_k,   M_k = [[a_k, 1], [1, 0]]
            mat2x2_mul #(.EXP(EXP), .SIG(SIG)) u_mm (
                .l00(P00[k-1]), .l01(P01[k-1]), .l10(P10[k-1]), .l11(P11[k-1]),
                .r00(a[k*W +: W]), .r01(F_ONE), .r10(F_ONE), .r11(F_ZERO),
                .p00(P00[k]), .p01(P01[k]), .p10(P10[k]), .p11(P11[k])
            );
        end
    endgenerate

    assign k0 = P00[DEPTH-1];
    assign k1 = P10[DEPTH-1];
endmodule
