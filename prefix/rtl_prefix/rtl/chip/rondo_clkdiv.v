// rondo_clkdiv: ICG-based divider, clk_out = clk_in gated to one pulse every N cycles,
// N = 1, 2, 4, 8 (div = 0..3). A change of div is applied at a counter wrap. In
// test_mode N = 1 and the gate is transparent.
module rondo_clkdiv (
    input        clk_in,
    input        rst_n,
    input  [1:0] div,
    input        test_mode,
    output       clk_out,
    output [1:0] div_applied
);
    reg [2:0] cnt;
    reg [1:0] div_q;
    wire [1:0] div_e = test_mode ? 2'd0 : div_q;
    wire [2:0] last  = (3'd1 << div_e) - 3'd1;
    wire       wrap  = (cnt == last);
    always @(posedge clk_in or negedge rst_n) begin
        if (!rst_n) begin cnt <= 3'd0; div_q <= 2'd0; end
        else begin
            cnt <= wrap ? 3'd0 : cnt + 3'd1;
            if (wrap) div_q <= div;
        end
    end
    assign div_applied = div_q;
    rondo_icg u_icg (.clk(clk_in), .en(wrap), .test_en(test_mode), .gclk(clk_out));
endmodule
