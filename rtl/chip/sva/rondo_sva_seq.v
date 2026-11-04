// Start / done rules (spec 10.2) and related invariants. viol bits:
//  0 start not a single-cycle pulse, 1 start while done or busy, 2 start within 2 cycles after done (t+2 minimum),
//  3 start while the layer reset is low or within 2 cycles after it rose, 4 x changed while busy,
//  5 ZBUF changed outside a capture cycle, 6 external memory write while ACTIVE, 7 inactive layer: clock enabled or reset released
//     for more than 4 cycles
module rondo_sva_seq #(
    parameter XW = 640,
    parameter ZW = 1024
) (
    input clk, input rst_n,
    input start, input busy, input done, input layer_rst_n, input [XW-1:0] x,
    input [ZW-1:0] zbuf_sig, input zcap, input zclr,
    input mem_wr_ext, input active,
    input inactive_clk_en, input inactive_rst_n,
    output reg [7:0] viol
);
    reg start_q, done_q, done_qq, rst_q, rst_qq, rst_qqq; reg [XW-1:0] x_q; reg busy_q; reg [ZW-1:0] z_q; reg zcap_q, zclr_q;
    reg [2:0] inact_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            viol <= 8'd0; start_q <= 1'b0; done_q <= 1'b0; done_qq <= 1'b0; rst_q <= 1'b0; rst_qq <= 1'b0; rst_qqq <= 1'b0;
            x_q <= {XW{1'b0}}; busy_q <= 1'b0; z_q <= {ZW{1'b0}}; zcap_q <= 1'b0; zclr_q <= 1'b0; inact_cnt <= 3'd0;
        end else begin
            start_q <= start; done_q <= done; done_qq <= done_q; rst_q <= layer_rst_n; rst_qq <= rst_q; rst_qqq <= rst_qq;
            x_q <= x; busy_q <= busy; z_q <= zbuf_sig; zcap_q <= zcap; zclr_q <= zclr;
            if (start && start_q) viol[0] <= 1'b1;
            if (start && (done || busy)) viol[1] <= 1'b1;
            if (start && (done_q)) viol[2] <= 1'b1;
            if (start && !(layer_rst_n && rst_q && rst_qq)) viol[3] <= 1'b1;
            if (busy && busy_q && x !== x_q) viol[4] <= 1'b1;
            if (zbuf_sig !== z_q && !zcap_q && !zclr_q) viol[5] <= 1'b1;
            if (mem_wr_ext && active) viol[6] <= 1'b1;
            if (inactive_clk_en || inactive_rst_n) begin
                if (inact_cnt == 3'd5) viol[7] <= 1'b1; else inact_cnt <= inact_cnt + 3'd1;
            end else inact_cnt <= 3'd0;
        end
    end
endmodule
