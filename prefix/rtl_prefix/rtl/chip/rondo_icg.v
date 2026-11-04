// rondo_icg: latch-based integrated clock gate (behavioral model).
// Substitute the library ICG cell here. The enable is captured while clk is low, so
// gclk never glitches; test_en forces the gate open (scan / test_mode).
module rondo_icg (
    input  clk,
    input  en,
    input  test_en,
    output gclk
);
`ifdef RONDO_FPGA_BUFGCE
    // FPGA prototype: the 7-series global clock buffer with clock enable is the glitch-free gate
    BUFGCE u_bufgce (.I(clk), .CE(en | test_en), .O(gclk));
`elsif RONDO_FPGA
    // FPGA prototype default: no clock gating (the inactive layer is simply held in reset); keeps one clock tree
    wire unused_en = en | test_en;
    assign gclk = clk;
`else
    reg en_l;
    always @(clk or en or test_en)
        if (!clk) en_l = en | test_en;
    assign gclk = clk & en_l;
`endif
endmodule
