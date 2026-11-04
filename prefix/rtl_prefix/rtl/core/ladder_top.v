// ladder_top: full single-ladder forward,  f = K1 / K0  with pole guard.
//
// Combines the combinational continuant scan (ladder_scan) with the clocked
// pole-guarded divider (recip_wrap). This is the M1 datapath: partial
// denominators a[0..DEPTH-1] -> continued-fraction output f, matching
// continuant_scan.py / CoFrContinuant (unit numerators).
//
//   a --> ladder_scan --> (K0, K1) --> recip_wrap --> f
//
// Sequential (the divide is multi-cycle): present a with inValid when inReady;
// f is valid when outValid. a must be held stable through the accepting cycle.

`include "cofr_defs.vh"

module ladder_top #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS
) (
    input                        clock,
    input                        nReset,
    input                        inValid,
    output                       inReady,
    input  [DEPTH*(EXP+SIG)-1:0] a,
    output                       outValid,
    output [(EXP+SIG)-1:0]       f
);
    localparam integer W = EXP + SIG;
    wire [W-1:0] k0, k1;

    ladder_scan #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH)) u_scan (
        .a (a),
        .k0(k0),
        .k1(k1)
    );

    recip_wrap #(.EXP(EXP), .SIG(SIG), .EPS(EPS)) u_recip (
        .clock   (clock),
        .nReset  (nReset),
        .inValid (inValid),
        .inReady (inReady),
        .k0      (k0),
        .k1      (k1),
        .outValid(outValid),
        .f       (f)
    );
endmodule
