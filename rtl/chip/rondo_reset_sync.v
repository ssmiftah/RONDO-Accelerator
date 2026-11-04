// rondo_reset_sync: asynchronous assert, synchronous deassert after STAGES edges of
// clk. In test_mode the output follows the pin directly (reset controllable by the
// tester, spec 3.4).
module rondo_reset_sync #(
    parameter STAGES = 2
) (
    input  clk,
    input  arst_n,
    input  test_mode,
    output rst_n_out
);
    (* async_reg = "true" *) reg [STAGES-1:0] s;
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) s <= {STAGES{1'b0}};
        else         s <= {s[STAGES-2:0], 1'b1};
    end
    assign rst_n_out = test_mode ? arst_n : s[STAGES-1];
endmodule
