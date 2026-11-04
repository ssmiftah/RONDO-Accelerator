// recip_wrap: pole-guarded fp32 division  f = K1 / K0  for one ladder.
//
// Implements the reciprocal/division stage of the continued fraction (see
// continuant_scan.py): f = sign(K1)*sign(K0)*|K1| / max(|K0|, eps). This equals
// K1 / clamp_signed(K0), where
//     clamp_signed(K0) = (|K0| >= eps) ? K0 : copysign(eps, K0)
// guards the pole (K0 -> 0). Matches the reference for all K0 != 0; the exact
// K0 == 0 case (reference yields 0 via sign(0)=0) is a documented divergence.
//
// The division algorithm itself is commodity: Berkeley HardFloat's iterative
// (multi-cycle, clocked) divSqrtRecFN. Only the clamp + placement are ours
// (docs/ACCELERATOR_DESIGN.md sec 11). Sequential: inValid/inReady in, outValid out.

`include "cofr_defs.vh"
`include "HardFloat_consts.vi"
`include "HardFloat_specialize.vi"

module recip_wrap #(
    parameter EXP = `COFR_EXP,
    parameter SIG = `COFR_SIG,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS   // stability epsilon, encoded in format
) (
    input                  clock,
    input                  nReset,
    input                  inValid,
    output                 inReady,
    input  [(EXP+SIG-1):0] k0,
    input  [(EXP+SIG-1):0] k1,
    output                 outValid,
    output [(EXP+SIG-1):0] f
);
    localparam integer W = EXP + SIG;   // total format width; sign = bit W-1, magnitude = [W-2:0]
    localparam RW = EXP + SIG;

    // Signed clamp of K0 away from zero. Compare magnitudes as unsigned bit
    // patterns (valid because positive floats are monotone in their bits).
    wire         is_small = (k0[W-2:0] < EPS[W-2:0]);
    wire [W-1:0] k0c = is_small ? {k0[W-1], EPS[W-2:0]} : k0;

    // Recode operands: divider computes a / b = K1 / K0c.
    wire [RW:0] a_rec, b_rec, out_rec;
    fNToRecFN #(EXP, SIG) e_a (.in(k1),  .out(a_rec));
    fNToRecFN #(EXP, SIG) e_b (.in(k0c), .out(b_rec));

    wire       sqrtOpOut;
    wire [4:0] flags;
    divSqrtRecFN_small #(EXP, SIG, 0) u_div (
        .nReset       (nReset),
        .clock        (clock),
        .control      (`flControl_default),
        .inReady      (inReady),
        .inValid      (inValid),
        .sqrtOp       (1'b0),          // divide (not sqrt)
        .a            (a_rec),
        .b            (b_rec),
        .roundingMode (`round_near_even),
        .outValid     (outValid),
        .sqrtOpOut    (sqrtOpOut),
        .out          (out_rec),
        .exceptionFlags(flags)
    );

    recFNToFN #(EXP, SIG) d_o (.in(out_rec), .out(f));
endmodule
