// rondo_layers: the two datapaths of the chip (spec 12, 13.13).
//
// Two fused_coproc_pipe instances (bf16: EXP 8 SIG 8; fp32: EXP 8 SIG 24), both with
// EXT_MEM=1 (weights/biases live in rondo_wmem), LANE_MASK=1 and the debug taps, each behind
// its own clock gate and reset. Only the instance selected by `fmt` receives `start`; its
// busy/done/z/guard/memory ports are muxed onto the layer interface. The inactive instance is
// clock-gated and held in reset by rondo_seq, so its memory-request signals are 0.
//
// LAYER=1 builds one kan_layer_pipe (bf16, internal memories loaded through kw_*) instead:
// no read-back, guard, debug taps, lane mask or fp32 (spec 13.24).
module rondo_layers #(
    parameter DEPTH   = 7,
    parameter WIDTH   = 64,
    parameter PDIM    = 40,
    parameter N_LANES = 8,
    parameter NSLOT   = 8,
    parameter NPAR    = 8,
    parameter ACCSIG_BF16 = 8,
    parameter TBITS_FP32  = 8,
    parameter NR_ITERS_FP32 = 2,
    parameter HAS_BF16 = 1,
    parameter HAS_FP32 = 1,
    parameter LAYER    = 0,
    parameter DBG      = 1,
    parameter PG       = 0,
    parameter TILE     = 0,          // input tiling (C8): needs NBATCHES == 1
    parameter NLAD     = WIDTH / N_LANES,
    parameter NCH      = NSLOT * DEPTH,
    parameter NGROUP   = NCH / NPAR,
    parameter NBATCHES = NLAD / NSLOT,
    parameter NGROUPK  = NSLOT * (DEPTH + 1) / NPAR,
    parameter NWORDS   = (LAYER == 0) ? NBATCHES * NGROUP * PDIM : NBATCHES * NGROUPK * PDIM,
    parameter NBWORDS  = (LAYER == 0) ? NBATCHES * NGROUP : 1,
    parameter WAW      = (NWORDS  < 2) ? 1 : $clog2(NWORDS),
    parameter BAW      = (NBWORDS < 2) ? 1 : $clog2(NBWORDS),
    parameter LNW      = (N_LANES < 2) ? 1 : $clog2(N_LANES),
    parameter KNW      = ((NBATCHES*(NSLOT*(DEPTH+1)/NPAR)*PDIM) < 2) ? 1 : $clog2(NBATCHES*(NSLOT*(DEPTH+1)/NPAR)*PDIM)
) (
    input                        clk,            // clk_core
    input  [1:0]                 core_rst_n,     // [0] bf16, [1] fp32 (asynchronous, active low)
    input  [1:0]                 clk_en,         // layer clock enables
    input                        test_mode,
    input                        fmt,            // 0 bf16, 1 fp32 (selects the active layer)
    input                        dbg_fmt,        // layer whose debug taps are read
    // layer interface
    input                        start,
    output                       busy,
    output                       done,
    input  [PDIM*32-1:0]         x,
    output [WIDTH*32-1:0]        z,
    input  [N_LANES-1:0]         lane_en,
    output [N_LANES-1:0]         guard_hit,
    // weight / bias memory side (active layer), to rondo_wmem
    output [N_LANES*WAW-1:0]     wm_addr,
    output [N_LANES*BAW-1:0]     bm_addr,
    output [N_LANES-1:0]         mem_act,
    input  [N_LANES*NPAR*16-1:0] wm_q_h,
    input  [N_LANES*NPAR*16-1:0] wm_q_l,
    input  [N_LANES*NPAR*16-1:0] bm_q_h,
    input  [N_LANES*NPAR*16-1:0] bm_q_l,
    // input tiling (C8): launch parameters (held stable by rondo_tile) and the partial-sum store ports
    input  [1:0]                 tile_seed,
    input                        tile_save,
    input                        tile_last,
    input  [N_LANES*NPAR*16-1:0] ps_q_h,
    input  [N_LANES*NPAR*16-1:0] ps_q_l,
    output [N_LANES-1:0]         ps_we,
    output [N_LANES*BAW-1:0]     ps_waddr,
    output [N_LANES*NPAR*16-1:0] ps_wd_h,
    output [N_LANES*NPAR*16-1:0] ps_wd_l,
    // LAYER=1 load port (core word writes)
    input                        kw_we,
    input  [LNW-1:0]             kw_lane,
    input  [KNW-1:0]             kw_addr,
    input  [NPAR*16-1:0]         kw_din,
    // debug taps
    input  [LNW-1:0]             dbg_lane,
    input  [2:0]                 dbg_sig,
    input  [7:0]                 dbg_idx,
    output [31:0]                dbg_data,
    input  [1:0]                 dbg_live_sel,
    output                       dbg_live_v,
    output [31:0]                dbg_live_d,
    output [7:0]                 dbg_live_f,
    // clock gate observation (for the ordering/assertion checks)
    output [1:0]                 lclk_obs,
    input  [1:0]                 pg_iso,       // isolation of a powered-down layer (PG=1)
    output [1:0]                 pg_req
);
    generate
        if (LAYER == 0) begin : g_cofr
            // ---- bf16 instance -------------------------------------------------------
            wire clk_b, clk_f;
            wire b_busy, b_done, f_busy, f_done;
            wire [WIDTH*16-1:0] zb;
            wire [WIDTH*32-1:0] zf;
            wire [N_LANES-1:0]  gh_b, gh_f, ma_b, ma_f;
            wire [N_LANES*WAW-1:0] wa_b, wa_f;
            wire [N_LANES*BAW-1:0] ba_b, ba_f;
            wire [31:0] dd_b, dd_f, dld_b, dld_f;
            wire        dlv_b, dlv_f;
            wire [7:0]  dlf_b, dlf_f;
            wire [N_LANES-1:0] pw_b, pw_f;
            wire [N_LANES*BAW-1:0] pa_b, pa_f;
            localparam AWB = 8 + ACCSIG_BF16;               // bf16 accumulator width (spec 18.3: TILE needs AWB = 16, elaboration check in rondo_dev)
            wire [N_LANES*NPAR*AWB-1:0] pd_b;
            wire [N_LANES*NPAR*32-1:0] pd_f;

            if (HAS_BF16) begin : g_b
                rondo_icg u_icg (.clk(clk), .en(clk_en[0]), .test_en(test_mode), .gclk(clk_b));
                wire [PDIM*16-1:0] xb;
                wire [N_LANES*NPAR*AWB-1:0] pq_b;           // PS read data zero-extended to the accumulator width (identical to ps_q_h at AWB = 16)
                genvar pb;
                for (pb = 0; pb < N_LANES*NPAR; pb = pb + 1) begin : g_pq
                    assign pq_b[pb*AWB +: AWB] = AWB'(ps_q_h[pb*16 +: 16]);
                end
                genvar i;
                for (i = 0; i < PDIM; i = i + 1) begin : g_x
                    assign xb[i*16 +: 16] = x[i*32 +: 16];
                end
                fused_coproc_pipe #(.EXP(8), .SIG(8), .ACCSIG(ACCSIG_BF16), .DEPTH(DEPTH), .WIDTH(WIDTH),
                    .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(6),
                    .EPS(32'h00003C24), .SEED_FILE("recip_seed_e8s8_t6.mem"), .NR_ITERS(1),
                    .EXT_MEM(1), .LANE_MASK(1), .DBG(DBG), .TILE(TILE)) u_bf16 (
                    .clock(clk_b), .nReset(core_rst_n[0]),
                    .w_we(1'b0), .w_lane({LNW{1'b0}}), .w_addr({WAW{1'b0}}), .w_din({NPAR*16{1'b0}}),
                    .b_we(1'b0), .b_addr({BAW{1'b0}}), .b_din({NPAR*16{1'b0}}),
                    .start(start & ~fmt), .busy(b_busy), .done(b_done), .x(xb), .z(zb),
                    .guard_hit(gh_b), .lane_en(lane_en),
                    .wm_addr(wa_b), .bm_addr(ba_b), .mem_act(ma_b), .wm_q(wm_q_h), .bm_q(bm_q_h),
                    .dbg_lane(dbg_lane), .dbg_sig(dbg_sig), .dbg_idx(dbg_idx), .dbg_data(dd_b),
                    .dbg_live_sel(dbg_live_sel), .dbg_live_v(dlv_b), .dbg_live_d(dld_b),
                    .dbg_live_f(dlf_b), .tile_seed(tile_seed), .tile_save(tile_save), .tile_last(tile_last), .ps_q(pq_b),
                    .ps_we(pw_b), .ps_waddr(pa_b), .ps_wdata(pd_b), .done_final());
            end else begin : g_nob
                assign clk_b = 1'b0; assign b_busy = 1'b0; assign b_done = 1'b0; assign zb = {WIDTH*16{1'b0}};
                assign gh_b = {N_LANES{1'b0}}; assign ma_b = {N_LANES{1'b0}};
                assign wa_b = {N_LANES*WAW{1'b0}}; assign ba_b = {N_LANES*BAW{1'b0}};
                assign dd_b = 32'd0; assign dlv_b = 1'b0; assign dld_b = 32'd0; assign dlf_b = 8'd0;
                assign pw_b = {N_LANES{1'b0}}; assign pa_b = {N_LANES*BAW{1'b0}}; assign pd_b = {N_LANES*NPAR*AWB{1'b0}};
            end

            // ---- fp32 instance: element f = {H[f], L[f]} -----------------------------
            if (HAS_FP32) begin : g_f
                rondo_icg u_icg (.clk(clk), .en(clk_en[1]), .test_en(test_mode), .gclk(clk_f));
                wire [N_LANES*NPAR*32-1:0] wq32, bq32, pq32;
                genvar e;
                for (e = 0; e < N_LANES*NPAR; e = e + 1) begin : g_q
                    assign wq32[e*32 +: 32] = {wm_q_h[e*16 +: 16], wm_q_l[e*16 +: 16]};
                    assign bq32[e*32 +: 32] = {bm_q_h[e*16 +: 16], bm_q_l[e*16 +: 16]};
                    assign pq32[e*32 +: 32] = {ps_q_h[e*16 +: 16], ps_q_l[e*16 +: 16]};
                end
                fused_coproc_pipe #(.EXP(8), .SIG(24), .ACCSIG(24), .DEPTH(DEPTH), .WIDTH(WIDTH),
                    .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS_FP32),
                    .EPS(32'h3C23D70A),
                    .SEED_FILE(TBITS_FP32 == 12 ? "recip_seed_e8s24_t12.mem" : "recip_seed_e8s24_t8.mem"),
                    .NR_ITERS(NR_ITERS_FP32), .EXT_MEM(1), .LANE_MASK(1), .DBG(DBG), .TILE(TILE)) u_fp32 (
                    .clock(clk_f), .nReset(core_rst_n[1]),
                    .w_we(1'b0), .w_lane({LNW{1'b0}}), .w_addr({WAW{1'b0}}), .w_din({NPAR*32{1'b0}}),
                    .b_we(1'b0), .b_addr({BAW{1'b0}}), .b_din({NPAR*32{1'b0}}),
                    .start(start & fmt), .busy(f_busy), .done(f_done), .x(x), .z(zf),
                    .guard_hit(gh_f), .lane_en(lane_en),
                    .wm_addr(wa_f), .bm_addr(ba_f), .mem_act(ma_f), .wm_q(wq32), .bm_q(bq32),
                    .dbg_lane(dbg_lane), .dbg_sig(dbg_sig), .dbg_idx(dbg_idx), .dbg_data(dd_f),
                    .dbg_live_sel(dbg_live_sel), .dbg_live_v(dlv_f), .dbg_live_d(dld_f),
                    .dbg_live_f(dlf_f), .tile_seed(tile_seed), .tile_save(tile_save), .tile_last(tile_last), .ps_q(pq32),
                    .ps_we(pw_f), .ps_waddr(pa_f), .ps_wdata(pd_f), .done_final());
            end else begin : g_nof
                assign clk_f = 1'b0; assign f_busy = 1'b0; assign f_done = 1'b0; assign zf = {WIDTH*32{1'b0}};
                assign gh_f = {N_LANES{1'b0}}; assign ma_f = {N_LANES{1'b0}};
                assign wa_f = {N_LANES*WAW{1'b0}}; assign ba_f = {N_LANES*BAW{1'b0}};
                assign dd_f = 32'd0; assign dlv_f = 1'b0; assign dld_f = 32'd0; assign dlf_f = 8'd0;
                assign pw_f = {N_LANES{1'b0}}; assign pa_f = {N_LANES*BAW{1'b0}}; assign pd_f = {N_LANES*NPAR*32{1'b0}};
            end

            // isolation cells (PG=1): outputs of a powered-down layer are forced to 0
            wire isb = (PG != 0) && pg_iso[0], isf = (PG != 0) && pg_iso[1];
            assign busy      = fmt ? (f_busy & ~isf) : (b_busy & ~isb);
            assign done      = fmt ? (f_done & ~isf) : (b_done & ~isb);
            assign guard_hit = fmt ? (gh_f & {N_LANES{~isf}}) : (gh_b & {N_LANES{~isb}});
            assign mem_act   = fmt ? (ma_f & {N_LANES{~isf}}) : (ma_b & {N_LANES{~isb}});
            assign wm_addr   = fmt ? (wa_f & {N_LANES*WAW{~isf}}) : (wa_b & {N_LANES*WAW{~isb}});
            assign bm_addr   = fmt ? (ba_f & {N_LANES*BAW{~isf}}) : (ba_b & {N_LANES*BAW{~isb}});
            assign ps_we     = fmt ? (pw_f & {N_LANES{~isf}}) : (pw_b & {N_LANES{~isb}});
            assign ps_waddr  = fmt ? (pa_f & {N_LANES*BAW{~isf}}) : (pa_b & {N_LANES*BAW{~isb}});
            genvar pe;
            for (pe = 0; pe < N_LANES*NPAR; pe = pe + 1) begin : g_pd
                assign ps_wd_h[pe*16 +: 16] = fmt ? (pd_f[pe*32+16 +: 16] & {16{~isf}}) : (pd_b[pe*AWB +: 16] & {16{~isb}});
                assign ps_wd_l[pe*16 +: 16] = fmt ? (pd_f[pe*32 +: 16] & {16{~isf}}) : 16'd0;
            end
            genvar j;
            for (j = 0; j < WIDTH; j = j + 1) begin : g_z
                assign z[j*32 +: 32] = fmt ? (zf[j*32 +: 32] & {32{~isf}}) : ({16'd0, zb[j*16 +: 16]} & {32{~isb}});
            end
            assign dbg_data   = dbg_fmt ? (dd_f & {32{~isf}})  : (dd_b & {32{~isb}});
            assign dbg_live_v = dbg_fmt ? (dlv_f & ~isf) : (dlv_b & ~isb);
            assign dbg_live_d = dbg_fmt ? (dld_f & {32{~isf}}) : (dld_b & {32{~isb}});
            assign dbg_live_f = dbg_fmt ? (dlf_f & {8{~isf}}) : (dlf_b & {8{~isb}});
            assign lclk_obs   = {clk_f, clk_b};
            assign pg_req     = pg_iso;         // the sequencer owns the request; echoed for observation
        end else begin : g_kan
            // ---- single KAN layer (bf16), internal memories ---------------------------
            wire clk_k;
            wire k_busy, k_done;
            wire [WIDTH*16-1:0] yk;
            wire [PDIM*16-1:0]  xk;
            rondo_icg u_icg (.clk(clk), .en(clk_en[0]), .test_en(test_mode), .gclk(clk_k));
            genvar i, j;
            for (i = 0; i < PDIM; i = i + 1) begin : g_x
                assign xk[i*16 +: 16] = x[i*32 +: 16];
            end
            kan_layer_pipe #(.EXP(8), .SIG(8), .DEPTH(DEPTH), .P_IN(PDIM), .N_OUT(WIDTH),
                             .N_LANES(N_LANES), .NOB(NSLOT), .NMAC(NPAR)) u_kan (
                .clock(clk_k), .nReset(core_rst_n[0]), .w_we(kw_we), .w_lane(kw_lane),
                .w_addr(kw_addr), .w_din(kw_din), .start(start), .busy(k_busy), .done(k_done),
                .x(xk), .y(yk));
            assign busy = k_busy;
            assign done = k_done;
            for (j = 0; j < WIDTH; j = j + 1) begin : g_z
                assign z[j*32 +: 32] = {16'd0, yk[j*16 +: 16]};
            end
            assign guard_hit  = {N_LANES{1'b0}};
            assign mem_act    = {N_LANES{1'b0}};
            assign wm_addr    = {N_LANES*WAW{1'b0}};
            assign bm_addr    = {N_LANES*BAW{1'b0}};
            assign ps_we      = {N_LANES{1'b0}}; assign ps_waddr = {N_LANES*BAW{1'b0}};
            assign ps_wd_h    = {N_LANES*NPAR*16{1'b0}}; assign ps_wd_l = {N_LANES*NPAR*16{1'b0}};
            assign dbg_data   = 32'd0; assign dbg_live_v = 1'b0; assign dbg_live_d = 32'd0;
            assign dbg_live_f = 8'd0;
            assign lclk_obs   = {1'b0, clk_k};
            assign pg_req     = 2'b00;
        end
    endgenerate
endmodule
