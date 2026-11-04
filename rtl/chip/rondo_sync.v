// rondo_sync: flop synchronizer (STAGES flops per bit, async reset to 0).
module rondo_sync #(
    parameter STAGES = 2,
    parameter WIDTH  = 1
) (
    input                  clk,
    input                  rst_n,
    input  [WIDTH-1:0]     d,
    output [WIDTH-1:0]     q
);
    (* async_reg = "true" *) reg [WIDTH-1:0] s [0:STAGES-1];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) s[i] <= {WIDTH{1'b0}};
        end else begin
            s[0] <= d;
            for (i = 1; i < STAGES; i = i + 1) s[i] <= s[i-1];
        end
    end
    assign q = s[STAGES-1];
endmodule
