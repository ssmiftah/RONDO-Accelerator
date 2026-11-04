// rondo_clk_mux: glitch-free 2:1 clock multiplexer (spec 3.3).
// Per input a 2-flop synchronizer on the FALLING edge of that input enables an AND
// gate; each enable is qualified by the other side's final enable (cross-coupled), the
// gated clocks are ORed. Switching needs both clocks running. rst_n = 0 asynchronously
// selects clk0 (its enable flops set, clk1's cleared) so a dead clk1 is recoverable.
// test_mode bypasses the mux to clk0. Implemented behaviorally in this one module so the
// flow can substitute a library clock-mux cell.
module rondo_clk_mux (
    input  clk0,
    input  clk1,
    input  sel,          // 0: clk0, 1: clk1
    input  rst_n,
    input  test_mode,
    output clk_out
);
    reg a1, a0;          // clk0 domain
    reg b1, b0;          // clk1 domain
    always @(negedge clk0 or negedge rst_n) begin
        if (!rst_n) begin a1 <= 1'b1; a0 <= 1'b1; end
        else begin a1 <= ~sel & ~b0; a0 <= a1; end
    end
    always @(negedge clk1 or negedge rst_n) begin
        if (!rst_n) begin b1 <= 1'b0; b0 <= 1'b0; end
        else begin b1 <= sel & ~a0; b0 <= b1; end
    end
    wire gated = (clk0 & a0) | (clk1 & b0);
    assign clk_out = test_mode ? clk0 : gated;
endmodule
