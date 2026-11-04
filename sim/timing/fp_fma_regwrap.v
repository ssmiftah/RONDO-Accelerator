// Registered wrapper around the combinational fp_fma, for timing only.
//
// fp_fma has no clock, so vivado/ooc_timing.tcl cannot constrain it directly:
// create_clock finds no `clock` port and the run dies after synthesis. Placing
// the combinational block between input and output registers measures exactly
// what "one combinational FMA closes at F MHz" is meant to mean -- the longest
// register-to-register path through it -- and is what the pipelined variant is
// being compared against.
`include "cofr_defs.vh"

module fp_fma_regwrap #(
    parameter EXP = `COFR_EXP,
    parameter SIG = `COFR_SIG
) (
    input                      clock,
    input                      nReset,
    input  [(EXP+SIG-1):0]     a,
    input  [(EXP+SIG-1):0]     b,
    input  [(EXP+SIG-1):0]     c,
    output reg [(EXP+SIG-1):0] p
);
    reg [(EXP+SIG-1):0] a_q, b_q, c_q;
    wire [(EXP+SIG-1):0] p_w;

    fp_fma #(.EXP(EXP), .SIG(SIG)) u (.a(a_q), .b(b_q), .c(c_q), .p(p_w));

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            a_q <= 0; b_q <= 0; c_q <= 0; p <= 0;
        end else begin
            a_q <= a; b_q <= b; c_q <= c; p <= p_w;
        end
    end
endmodule
