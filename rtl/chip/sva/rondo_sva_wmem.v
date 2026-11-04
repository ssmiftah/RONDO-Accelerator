// rondo_wmem rules (spec 15.2): viol bits: 0 L half enabled by the layer in bf16 mode (ce_l without a wrapper half[1] access),
// 1 two owners in one cycle (wrapper access collides with a layer access: wp_denied)
module rondo_sva_wmem (
    input clk, input rst_n,
    input fmt, input ce_l_any, input wp_en, input [1:0] wp_half, input wp_denied,
    output reg [7:0] viol
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) viol <= 8'd0;
        else begin
            if (!fmt && ce_l_any && !(wp_en && wp_half[1])) viol[0] <= 1'b1;
            if (wp_denied) viol[1] <= 1'b1;
        end
    end
endmodule
