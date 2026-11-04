// grad_a_unit: closed-form gradient of one ladder w.r.t. its denominators a.
//
// Backward pass (training). From CoFrContinuant.backward / continuant_scan.py:
//   grad_a[k] = grad_out * s_k * (K[k+1] / clamp_signed(K0))^2 ,  k = 0..DEPTH-1
// where s_k = -1 for even k, +1 for odd k, and rK0 = 1/clamp_signed(K0) is the
// (already-computed) reciprocal of the pole-guarded denominator K0 = K[0].
//
// Reuses the forward continuants K[0..DEPTH] (the scan output) and a single
// reciprocal -- exactly the cheap, train-capable backward the design predicts
// (docs/ACCELERATOR_DESIGN.md sec 9). Combinational; DEPTH parallel lanes of two
// multiplies. Negation is a sign-bit flip. Parameterized in format and DEPTH.

`include "cofr_defs.vh"

module grad_a_unit #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH
) (
    input  [((DEPTH+1)*(EXP+SIG))-1:0] Kv,        // K[0..DEPTH], Kv[i] = K[i]
    input  [(EXP+SIG)-1:0]             rK0,       // 1 / clamp_signed(K0)
    input  [(EXP+SIG)-1:0]             grad_out,  // upstream gradient
    output [(DEPTH*(EXP+SIG))-1:0]     grad_a     // grad_a[0..DEPTH-1]
);
    localparam integer W = EXP + SIG;

    genvar k;
    generate
        for (k = 0; k < DEPTH; k = k + 1) begin : gk
            wire [W-1:0] Kk1 = Kv[(k+1)*W +: W];   // K[k+1]
            wire [W-1:0] ratio, ratio2, g;
            fp_mul #(.EXP(EXP), .SIG(SIG)) m_ratio  (.x(Kk1),      .y(rK0),    .p(ratio));
            fp_mul #(.EXP(EXP), .SIG(SIG)) m_square (.x(ratio),    .y(ratio),  .p(ratio2));
            fp_mul #(.EXP(EXP), .SIG(SIG)) m_scale  (.x(grad_out), .y(ratio2), .p(g));

            if (k % 2 == 0)
                assign grad_a[k*W +: W] = {~g[W-1], g[W-2:0]};  // even k: negate
            else
                assign grad_a[k*W +: W] = g;                    // odd  k: as-is
        end
    endgenerate
endmodule
