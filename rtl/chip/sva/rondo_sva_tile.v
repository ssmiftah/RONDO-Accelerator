// input-tiling rules (spec 18.8 assertions); viol bits:
// 0 a restore launch (tile_seed = 2 / keep = 1) without a valid PS entry carrying tag s-1
// 1 a partial slice wrote ZBUF (zcap) or TZ (tz_we)
// 2 PS written by the layer outside a tile run, or by the host while the chip is ACTIVE
// 3 a launch started while a command rejected with TILE_SEQ is pending (start-class command honoured while OPEN or TILE_EN=1)
module rondo_sva_tile (
    input clk, input rst_n,
    input layer_start, input tl_busy, input [1:0] tl_seed, input tl_last, input tl_keep,
    input entry_valid, input [7:0] entry_tag, input [7:0] s_cur,
    input zcap, input tl_tz_we, input ps_layer_we, input ps_host_wr, input active,
    input cmd_start_class, input tile_blocked,
    output reg [7:0] viol
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) viol <= 8'd0;
        else begin
            if (layer_start && tl_busy && tl_seed != 2'd0 && !(entry_valid && entry_tag == s_cur - 8'd1)) viol[0] <= 1'b1;
            if (tl_busy && !tl_last && (zcap || tl_tz_we)) viol[1] <= 1'b1;
            if ((ps_layer_we && !tl_busy) || (ps_host_wr && active)) viol[2] <= 1'b1;
            if (cmd_start_class && tile_blocked) viol[3] <= 1'b1;
        end
    end
endmodule
