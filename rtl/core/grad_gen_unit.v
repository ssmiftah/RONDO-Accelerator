// grad_gen_unit: generalized-numerator backward for one ladder.
//
// Closed forms (grad_b_fix.py, verified vs autograd). With ratio[i]=K[i]*rK0,
// rK0 = 1/clamp_signed(K0), negb[j] = -b[j], and cumprod pc[k]=prod_{0..k} negb:
//
//   grad_a[k] = ratio[k+1]^2 * pc[k] * G              k = 0..DEPTH-1
//   grad_b[m] = ratio[m] * ratio[m+1] * pL[m] * G     pL[0]=1, pL[m]=pc[m-1]
//
// Reuses the (generalized) forward continuants K[0..DEPTH] and a single
// reciprocal. Combinational: DEPTH parallel lanes plus a prefix-product chain
// for pc. Reduces to grad_a_unit's even-negation when b=1 (pc = (-1)^{k+1}).
// Parameterized in format and DEPTH.

`include "cofr_defs.vh"

module grad_gen_unit #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH
) (
    input  [((DEPTH+1)*(EXP+SIG))-1:0] Kv,        // K[0..DEPTH]
    input  [(DEPTH*(EXP+SIG))-1:0]     b,         // b[0..DEPTH-1]
    input  [(EXP+SIG)-1:0]             rK0,       // 1 / clamp_signed(K0)
    input  [(EXP+SIG)-1:0]             grad_out,  // upstream gradient G
    output [(DEPTH*(EXP+SIG))-1:0]     grad_a,
    output [(DEPTH*(EXP+SIG))-1:0]     grad_b
);
    localparam integer W    = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};

    // ratio[i] = K[i] * rK0,  i = 0..DEPTH
    wire [W-1:0] ratio [0:DEPTH];
    genvar i;
    generate
        for (i = 0; i <= DEPTH; i = i + 1) begin : g_ratio
            fp_mul #(.EXP(EXP), .SIG(SIG)) m (.x(Kv[i*W +: W]), .y(rK0), .p(ratio[i]));
        end
    endgenerate

    // pc[k] = prod_{j=0..k} (-b[j])  (prefix product of negated numerators)
    wire [W-1:0] negb [0:DEPTH-1];
    wire [W-1:0] pc   [0:DEPTH-1];
    genvar j;
    generate
        for (j = 0; j < DEPTH; j = j + 1) begin : g_negb
            wire [W-1:0] bj = b[j*W +: W];
            assign negb[j] = {~bj[W-1], bj[W-2:0]};   // -b[j]
        end
        assign pc[0] = negb[0];
        for (j = 1; j < DEPTH; j = j + 1) begin : g_pc
            fp_mul #(.EXP(EXP), .SIG(SIG)) m (.x(pc[j-1]), .y(negb[j]), .p(pc[j]));
        end
    endgenerate

    // grad_a[k] = ratio[k+1]^2 * pc[k] * G ;  grad_b[m] = ratio[m]*ratio[m+1]*pL[m]*G
    genvar k;
    generate
        for (k = 0; k < DEPTH; k = k + 1) begin : g_out
            // grad_a
            wire [W-1:0] r2, ta, ga;
            fp_mul #(.EXP(EXP), .SIG(SIG)) ma1 (.x(ratio[k+1]), .y(ratio[k+1]), .p(r2));
            fp_mul #(.EXP(EXP), .SIG(SIG)) ma2 (.x(r2),        .y(pc[k]),      .p(ta));
            fp_mul #(.EXP(EXP), .SIG(SIG)) ma3 (.x(ta),        .y(grad_out),   .p(ga));
            assign grad_a[k*W +: W] = ga;

            // grad_b:  pL[k] = (k==0) ? 1 : pc[k-1]
            wire [W-1:0] pL = (k == 0) ? F_ONE : pc[(k == 0) ? 0 : k-1];
            wire [W-1:0] rr, tb, gb;
            fp_mul #(.EXP(EXP), .SIG(SIG)) mb1 (.x(ratio[k]),   .y(ratio[k+1]), .p(rr));
            fp_mul #(.EXP(EXP), .SIG(SIG)) mb2 (.x(rr),         .y(pL),         .p(tb));
            fp_mul #(.EXP(EXP), .SIG(SIG)) mb3 (.x(tb),         .y(grad_out),   .p(gb));
            assign grad_b[k*W +: W] = gb;
        end
    endgenerate
endmodule
