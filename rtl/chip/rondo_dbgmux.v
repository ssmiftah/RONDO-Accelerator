// rondo_dbgmux: DBG_SEL -> layer tap selects, DBG_DATA latch (spec 11.2).
// DBG_SEL: [3:0] lane, [6:4] sig, [15:8] idx, [17:16] live_sel, [24] fmt_override_en,
// [25] fmt_override. DBG_DATA <= dbg_data 4 cycles after a DBG_SEL write or DBG_LATCH.
module rondo_dbgmux #(
    parameter LNW = 3
) (
    input              clk,
    input              rst_n,
    input  [25:0]      dbg_sel,
    input              dbg_latch,
    input              fmt_applied,
    input  [31:0]      layer_dbg_data,
    output [LNW-1:0]   dbg_lane,
    output [2:0]       dbg_sig,
    output [7:0]       dbg_idx,
    output [1:0]       dbg_live_sel,
    output             dbg_fmt,
    output reg [31:0]  dbg_data_r
);
    assign dbg_lane     = dbg_sel[LNW-1:0];
    assign dbg_sig      = dbg_sel[6:4];
    assign dbg_idx      = dbg_sel[15:8];
    assign dbg_live_sel = dbg_sel[17:16];
    assign dbg_fmt      = dbg_sel[24] ? dbg_sel[25] : fmt_applied;
    reg [2:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cnt <= 3'd0; dbg_data_r <= 32'd0; end
        else begin
            if (dbg_latch) cnt <= 3'd4;
            else if (cnt != 3'd0) begin
                cnt <= cnt - 3'd1;
                if (cnt == 3'd1) dbg_data_r <= layer_dbg_data;
            end
        end
    end
endmodule
