// One bf16 multiply-accumulate PE, the unit a systolic array is built from.
// Synthesised only to get an area figure so a continuant lane can be priced in
// MAC-equivalents rather than assumed to cost one MAC.
module bf16_mac(input clock, input nReset, input [15:0] a, input [15:0] b,
                input [15:0] c, output [15:0] p);
    fp_fma_pipe #(.EXP(8), .SIG(8), .GATE(1)) u (
        .clock(clock), .nReset(nReset), .in_valid(1'b1),
        .a(a), .b(b), .c(c), .out_valid(), .p(p));
endmodule
