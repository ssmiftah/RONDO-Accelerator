// rondo_wmem: physical weight/bias store, the SRAM-macro boundary (spec 7.7).
//
// Per lane: weight store H and L (NWORDS x NPAR*16) and bias store H and L (NBWORDS x
// NPAR*16), each an rondo_sram_sp. The bf16 layer reads H only; the fp32 layer reads
// {H[f], L[f]} per element. Single port per macro:
//   address  = active layer's address when its mem_act[l] = 1, else the wrapper port;
//   enable   = H: layer access or wrapper access; L: only when fmt = fp32 (layer access)
//              or a wrapper access with half_mask[1] (so in bf16 mode the L macros are
//              never enabled by the layer);
//   write    = wrapper port only;
//   q        = registered read data.
// The layer has priority; a wrapper access that collides is dropped and flagged on
// wp_denied (the sequencer blocks external accesses while ACTIVE, so this never happens
// in a legal run; an assertion checks it).
module rondo_wmem #(
    parameter N_LANES = 8,
    parameter NPAR    = 8,
    parameter NWORDS  = 280,
    parameter NBWORDS = 7,
    parameter WAW     = (NWORDS  < 2) ? 1 : $clog2(NWORDS),
    parameter BAW     = (NBWORDS < 2) ? 1 : $clog2(NBWORDS),
    parameter LNW     = (N_LANES < 2) ? 1 : $clog2(N_LANES)
) (
    input                              clk,
    input                              fmt,            // 0 bf16, 1 fp32
    // active layer side (per lane)
    input  [N_LANES*WAW-1:0]           wm_addr,
    input  [N_LANES*BAW-1:0]           bm_addr,
    input  [N_LANES-1:0]               mem_act,
    output [N_LANES*NPAR*16-1:0]       wm_q_h,
    output [N_LANES*NPAR*16-1:0]       wm_q_l,
    output [N_LANES*NPAR*16-1:0]       bm_q_h,
    output [N_LANES*NPAR*16-1:0]       bm_q_l,
    // wrapper port
    input                              wp_en,
    input                              wp_we,
    input                              wp_bias,
    input  [LNW-1:0]                   wp_lane,
    input  [WAW-1:0]                   wp_addr,        // bias: low BAW bits
    input  [1:0]                       wp_half,        // [0] H, [1] L
    input  [NPAR*16-1:0]               wp_wd_h,
    input  [NPAR*16-1:0]               wp_wd_l,
    output [NPAR*16-1:0]               wp_rd_h,
    output [NPAR*16-1:0]               wp_rd_l,
    output                             wp_denied,
    output                             ce_l_any        // any L macro enabled this cycle
);
    wire [N_LANES-1:0] lane_hit = wp_en ? ({{(N_LANES-1){1'b0}}, 1'b1} << wp_lane) : {N_LANES{1'b0}};
    wire [N_LANES-1:0] wp_w_sel = lane_hit & {N_LANES{~wp_bias}};
    wire [N_LANES-1:0] wp_b_sel = lane_hit & {N_LANES{wp_bias}};

    wire [N_LANES-1:0] denied_l = lane_hit & mem_act;
    assign wp_denied = |denied_l;

    wire [N_LANES-1:0] ce_l_v;
    assign ce_l_any = |ce_l_v;

    wire [N_LANES*NPAR*16-1:0] wq_h_i, wq_l_i, bq_h_i, bq_l_i;
    assign wm_q_h = wq_h_i; assign wm_q_l = wq_l_i;
    assign bm_q_h = bq_h_i; assign bm_q_l = bq_l_i;

    genvar l;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            wire own   = mem_act[l];                     // layer owns the macros this cycle
            wire w_wrap = wp_w_sel[l] & ~own;
            wire b_wrap = wp_b_sel[l] & ~own;
            // layer reads: H always, L only in fp32
            wire w_en_h = own | (w_wrap & wp_half[0]);
            wire w_en_l = (own & fmt) | (w_wrap & wp_half[1]);
            wire b_en_h = own | (b_wrap & wp_half[0]);
            wire b_en_l = (own & fmt) | (b_wrap & wp_half[1]);
            wire [WAW-1:0] w_a = own ? wm_addr[l*WAW +: WAW] : wp_addr;
            wire [BAW-1:0] b_a = own ? bm_addr[l*BAW +: BAW] : wp_addr[BAW-1:0];
            wire w_we = w_wrap & wp_we;
            wire b_we = b_wrap & wp_we;
            assign ce_l_v[l] = w_en_l | b_en_l;

            rondo_sram_sp #(.DEPTH(NWORDS),  .WIDTH(NPAR*16)) u_wh (.clk(clk), .en(w_en_h),
                .we(w_we & wp_half[0]), .addr(w_a), .d(wp_wd_h), .q(wq_h_i[l*NPAR*16 +: NPAR*16]));
            rondo_sram_sp #(.DEPTH(NWORDS),  .WIDTH(NPAR*16)) u_wl (.clk(clk), .en(w_en_l),
                .we(w_we & wp_half[1]), .addr(w_a), .d(wp_wd_l), .q(wq_l_i[l*NPAR*16 +: NPAR*16]));
            rondo_sram_sp #(.DEPTH(NBWORDS), .WIDTH(NPAR*16)) u_bh (.clk(clk), .en(b_en_h),
                .we(b_we & wp_half[0]), .addr(b_a), .d(wp_wd_h), .q(bq_h_i[l*NPAR*16 +: NPAR*16]));
            rondo_sram_sp #(.DEPTH(NBWORDS), .WIDTH(NPAR*16)) u_bl (.clk(clk), .en(b_en_l),
                .we(b_we & wp_half[1]), .addr(b_a), .d(wp_wd_l), .q(bq_l_i[l*NPAR*16 +: NPAR*16]));
        end
    endgenerate

    // wrapper read data: lane / bias select registered with the access
    reg [LNW-1:0] rl_q;
    reg           rb_q;
    always @(posedge clk) begin
        if (wp_en) begin rl_q <= wp_lane; rb_q <= wp_bias; end
    end
    assign wp_rd_h = rb_q ? bq_h_i[rl_q*NPAR*16 +: NPAR*16] : wq_h_i[rl_q*NPAR*16 +: NPAR*16];
    assign wp_rd_l = rb_q ? bq_l_i[rl_q*NPAR*16 +: NPAR*16] : wq_l_i[rl_q*NPAR*16 +: NPAR*16];
endmodule
