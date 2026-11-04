// Abstract stand-in for rondo_layers (same ports): handshake model with bounded latency + embedded launch-rule checker.
module rondo_layers #(
    parameter DEPTH = 7, WIDTH = 64, PDIM = 40, N_LANES = 8, NSLOT = 8, NPAR = 8, ACCSIG_BF16 = 8, TBITS_FP32 = 8,
    parameter NR_ITERS_FP32 = 2, HAS_BF16 = 1, HAS_FP32 = 1, LAYER = 0, DBG = 1, PG = 0, TILE = 0,
    parameter NLAD = WIDTH / N_LANES, NCH = NSLOT * DEPTH, NGROUP = NCH / NPAR, NBATCHES = NLAD / NSLOT,
    parameter NWORDS = NBATCHES * NGROUP * PDIM, NBWORDS = NBATCHES * NGROUP,
    parameter WAW = (NWORDS < 2) ? 1 : $clog2(NWORDS), BAW = (NBWORDS < 2) ? 1 : $clog2(NBWORDS),
    parameter LNW = (N_LANES < 2) ? 1 : $clog2(N_LANES),
    parameter KNW = ((NBATCHES*(NSLOT*(DEPTH+1)/NPAR)*PDIM) < 2) ? 1 : $clog2(NBATCHES*(NSLOT*(DEPTH+1)/NPAR)*PDIM)
) (
    input clk, input [1:0] core_rst_n, input [1:0] clk_en, input test_mode, input fmt, input dbg_fmt,
    input start, output busy, output done, input [PDIM*32-1:0] x, output [WIDTH*32-1:0] z,
    input [N_LANES-1:0] lane_en, output [N_LANES-1:0] guard_hit,
    output [N_LANES*WAW-1:0] wm_addr, output [N_LANES*BAW-1:0] bm_addr, output [N_LANES-1:0] mem_act,
    input [N_LANES*NPAR*16-1:0] wm_q_h, wm_q_l, bm_q_h, bm_q_l,
    input [1:0] tile_seed, input tile_save, input tile_last, input [N_LANES*NPAR*16-1:0] ps_q_h, ps_q_l,
    output [N_LANES-1:0] ps_we, output [N_LANES*BAW-1:0] ps_waddr, output [N_LANES*NPAR*16-1:0] ps_wd_h, ps_wd_l,
    input kw_we, input [LNW-1:0] kw_lane, input [KNW-1:0] kw_addr, input [NPAR*16-1:0] kw_din,
    input [LNW-1:0] dbg_lane, input [2:0] dbg_sig, input [7:0] dbg_idx, output [31:0] dbg_data,
    input [1:0] dbg_live_sel, output dbg_live_v, output [31:0] dbg_live_d, output [7:0] dbg_live_f,
    output [1:0] lclk_obs, input [1:0] pg_iso, output [1:0] pg_req
);
    (* anyseq *) wire go;
    (* anyseq *) wire [WIDTH*32-1:0] zfree;
    reg lbusy, ldone; reg [3:0] lcnt;
    wire layer_rst = fmt ? core_rst_n[1] : core_rst_n[0];
    always @(posedge clk) begin
        if (!layer_rst) begin lbusy <= 1'b0; ldone <= 1'b0; lcnt <= 4'd0; end
        else begin
            ldone <= 1'b0;
            if (start && !lbusy) begin lbusy <= 1'b1; lcnt <= 4'd0; end
            else if (lbusy) begin
                lcnt <= lcnt + 4'd1;
                if (lcnt >= 4'd3 && (go || lcnt >= 4'd8)) begin lbusy <= 1'b0; ldone <= 1'b1; end
            end
        end
    end
    assign busy = lbusy; assign done = ldone; assign z = zfree; assign guard_hit = {N_LANES{1'b0}};
    assign wm_addr = {N_LANES*WAW{1'b0}}; assign bm_addr = {N_LANES*BAW{1'b0}}; assign mem_act = {N_LANES{1'b0}};
    assign dbg_data = 32'd0; assign dbg_live_v = 1'b0; assign dbg_live_d = 32'd0; assign dbg_live_f = 8'd0;
    assign lclk_obs = clk_en; assign pg_req = pg_iso;
    // embedded launch-rule / format-switch checker
    wire [7:0] viol;
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    rondo_sva_seq #(.XW(PDIM*32), .ZW(8)) chk (.clk(clk), .rst_n(!init), .start(start), .busy(lbusy), .done(ldone),
        .layer_rst_n(layer_rst), .x(x), .zbuf_sig(8'd0), .zcap(1'b0), .zclr(1'b0), .mem_wr_ext(1'b0), .active(1'b0),
        .inactive_clk_en(fmt ? clk_en[0] : clk_en[1]), .inactive_rst_n(fmt ? core_rst_n[0] : core_rst_n[1]), .viol(viol));
    always @* if (!init) assert (!viol[0] && !viol[1] && !viol[2] && !viol[3] && !viol[4] && !viol[7]);
    assign ps_we = {N_LANES{1'b0}}; assign ps_waddr = {N_LANES*BAW{1'b0}};
    assign ps_wd_h = {N_LANES*NPAR*16{1'b0}}; assign ps_wd_l = {N_LANES*NPAR*16{1'b0}};
endmodule
