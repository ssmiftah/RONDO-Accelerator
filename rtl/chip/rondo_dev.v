// rondo_dev: the device behind the rbus: decode (spec 7.1), registers, XBUF/ZBUF, weight
// store, sequencer, both datapaths and the debug/test blocks (spec 3.2, 13.21).
`include "rondo_kat_sigs.vh"
module rondo_dev #(
    parameter DEPTH = 7, WIDTH = 64, PDIM = 40, N_LANES = 8, NSLOT = 8, NPAR = 8,
    parameter NXBUF = 4, CKSUM_PAR = 0,
    parameter ACCSIG_BF16 = 8, TBITS_FP32 = 8, NR_ITERS_FP32 = 2,
    parameter HAS_BF16 = 1, HAS_FP32 = 1, LAYER = 0,
    parameter DBG = 1, TRACE = 1, TRACE_DEPTH = 64, KAT = 1, MBIST = 0, SCAN = 0, PG = 0,
    parameter SPI_CRC = 1, CLK_ALT = 1, HB_BIT = 24, TILE = 1, TILE_B = 8,
    parameter CNT_INIT = 0,
    parameter [31:0] KAT_SIG_BF16 = 32'hFFFFFFFF, KAT_SIG_FP32 = 32'hFFFFFFFF,   // all ones = per-geometry default
    parameter KATG = (WIDTH == 16 && PDIM == 8 && N_LANES == 2) ? 1 : (WIDTH == 64 && PDIM == 40 && N_LANES == 8) ? 2 : 0,
    // derived
    parameter NLAD = WIDTH / N_LANES, NCH = NSLOT * DEPTH, NGROUP = NCH / NPAR,
    parameter NBATCHES = NLAD / NSLOT,
    // KAN option (LAYER=1): NCH = NSLOT*(DEPTH+1) chains per batch, no bias store (spec 13.24)
    parameter NGROUPK = NSLOT * (DEPTH + 1) / NPAR,
    // input tiling (spec 18): only for the supported datapath, one ladder batch per lane (C8 needs NBATCHES == 1)
    parameter TILE_P = ((TILE != 0) && (LAYER == 0) && (NBATCHES == 1)) ? 1 : 0,
    parameter TB  = (TILE_B < 1) ? 1 : TILE_B,
    parameter TBW = (TB < 2) ? 1 : $clog2(TB),
    parameter NWORDS = (LAYER == 0) ? NBATCHES * NGROUP * PDIM : NBATCHES * NGROUPK * PDIM,
    parameter NBWORDS = (LAYER == 0) ? NBATCHES * NGROUP : 1,
    parameter WAW = (NWORDS < 2) ? 1 : $clog2(NWORDS), BAW = (NBWORDS < 2) ? 1 : $clog2(NBWORDS),
    parameter LNW = (N_LANES < 2) ? 1 : $clog2(N_LANES), FW = (NPAR < 2) ? 1 : $clog2(NPAR),
    parameter XW = (PDIM < 2) ? 1 : $clog2(PDIM),
    parameter XPW = (NXBUF < 2) ? 1 : $clog2(NXBUF),
    parameter ZJW = (WIDTH < 2) ? 1 : $clog2(WIDTH),
    parameter TIW = (TRACE_DEPTH < 2) ? 1 : $clog2(TRACE_DEPTH),
    parameter KNW = ((NBATCHES*(NSLOT*(DEPTH+1)/NPAR)*PDIM) < 2) ? 1 : $clog2(NBATCHES*(NSLOT*(DEPTH+1)/NPAR)*PDIM)
) (
    input         clk,                 // clk_core
    input         rst_n,               // sys_rst_n
    input         test_mode,
    // external rbus slave
    input         rb_req_valid,
    output        rb_req_ready,
    input         rb_req_we,
    input  [23:0] rb_req_addr,
    input  [31:0] rb_req_wdata,
    output reg    rb_rsp_valid,
    input         rb_rsp_ready,
    output reg [31:0] rb_rsp_rdata,
    output reg    rb_rsp_err,
    // pins / config
    output        irq,
    output        busy_pin,
    output        st_pass,
    output [7:0]  status8,
    output        clkout,
    output [1:0]  clk_div,
    output        clk_src,
    output        crc_en,
    input  [1:0]  div_applied,
    input         src_applied,
    input         spi_err_frame,
    input         spi_err_crc,
    input         spi_frame_end,
    input         bist_strap,
    output [1:0]  pg_req,
    output [1:0]  lclk_obs,
    // observation (FPGA LEDs): running output checksum, format, heartbeat, sticky-error summary
    output [31:0] checksum_o,
    output        fmt_o,
    output        heartbeat_o,
    output        err_any_o
);
    localparam [31:0] SIG_B = (KAT_SIG_BF16 != 32'hFFFFFFFF) ? KAT_SIG_BF16 :
                              (KATG == 1) ? `RONDO_KATSIG_SMALL_BF16 : (KATG == 2) ? `RONDO_KATSIG_FULL_BF16 : 32'd0;
    localparam [31:0] SIG_F = (KAT_SIG_FP32 != 32'hFFFFFFFF) ? KAT_SIG_FP32 :
                              (KATG == 1) ? `RONDO_KATSIG_SMALL_FP32 : (KATG == 2) ? `RONDO_KATSIG_FULL_FP32 : 32'd0;
    // ============================ elaboration checks (spec 7.1, 10.1, 18.3, 18.5) =================
    // Elaboration system tasks inside generate-if: rejected by verilator --lint-only, Icarus and Yosys alike.
    generate
        if ((NPAR & (NPAR - 1)) != 0)            begin : e_npar  $fatal(1, "rondo_dev: NPAR must be a power of two (spec 7.1)"); end
        if (LNW + WAW + FW > 23)                 begin : e_wmap  $fatal(1, "rondo_dev: LNW+WAW+FW > 23 (spec 7.1)"); end
        if ((LAYER == 0) && (LNW + BAW + FW > 16)) begin : e_bmap  $fatal(1, "rondo_dev: LNW+BAW+FW > 16 (spec 7.1)"); end
        if (XPW + XW > 16)                       begin : e_xmap  $fatal(1, "rondo_dev: clog2(NXBUF)+XW > 16 (spec 7.1)"); end
        if ((TRACE != 0) && (2 * TRACE_DEPTH > 65536)) begin : e_trc $fatal(1, "rondo_dev: 2*TRACE_DEPTH > 65536 (spec 7.1)"); end
        if ((LAYER == 0) && (CKSUM_PAR == 0) && !(NGROUP * PDIM > WIDTH + 8))
                                                 begin : e_ck    $fatal(1, "rondo_dev: NGROUP*PDIM <= WIDTH+8 needs CKSUM_PAR=1 (spec 10.1)"); end
        if ((TILE_P != 0) && (TILE_B > 0) && (FW + BAW + LNW + TBW > 16)) begin : e_ps $fatal(1, "rondo_dev: PS region offset > 16 bits (spec 18.5)"); end
        if ((TILE_P != 0) && (TBW + XW > 16 || TBW + ZJW > 16)) begin : e_txz $fatal(1, "rondo_dev: TX/TZ region offset > 16 bits (spec 18.5)"); end
        if ((TILE_P != 0) && (HAS_BF16 != 0) && (ACCSIG_BF16 != 8)) begin : e_b3 $fatal(1, "rondo_dev: TILE=1 needs ACCSIG_BF16=8 (bf16 PS store is 16 bits); build with TILE=0 (spec 18.3)"); end
        if ((HAS_FP32 != 0) && (LAYER == 0) && (TBITS_FP32 != 8) && (TBITS_FP32 != 12)) begin : e_tb $fatal(1, "rondo_dev: TBITS_FP32 must be 8 or 12 (seed files)"); end
        if ((HAS_FP32 != 0) && (LAYER == 0) && (NR_ITERS_FP32 < 1 || NR_ITERS_FP32 > 2)) begin : e_nr $fatal(1, "rondo_dev: NR_ITERS_FP32 must be 1 or 2"); end
    endgenerate
    // ============================ rbus slave (behind the arbiter) ================================
    // External port -> rondo_rbus_arb (with the KAT / MBIST masters) -> this slave FSM.
    localparam [2:0] D_IDLE = 3'd0, D_EXEC = 3'd1, D_FIN = 3'd2, D_RSP = 3'd3, D_WAITRD = 3'd4, D_WAITM = 3'd5,
                     D_WAITPS = 3'd6;
    reg [2:0]  ds;
    reg        q_we, q_int, mem_sel_tz;
    reg [23:0] q_addr;
    reg [31:0] q_wdata;
    wire       srst;
    wire        o_req_valid, o_req_we, o_req_int;
    wire [23:0] o_req_addr;
    wire [31:0] o_req_wdata;
    wire        o_rsp_ready;
    reg         o_rsp_valid, o_rsp_err;
    reg  [31:0] o_rsp_rdata;
    wire        o_req_ready = (ds == D_IDLE) && !srst;
    wire        accept = o_req_valid && o_req_ready;

    // ============================ state shared across blocks ====================================
    wire        fmt_applied;
    wire [1:0]  pg_req_w;
    wire        kat_fmt_set, kat_fmt_val;
    wire        mb_done, mb_pass, mbist_ev_fail, mbist_ev_ws, mbist_ev_crc, mbist_ev_inv;
    reg         wstale_q;
    wire        seq_active, sr_running, sr_stopping, zvalid, zcap, fsw_pulse;
    wire [3:0]  xptr_status;
    wire [XPW-1:0] xptr;
    wire        layer_start, layer_busy, layer_done;
    wire [N_LANES-1:0] guard_hit, lane_en_applied;
    wire [1:0]  core_rst_n, clk_en;
    wire        kat_active, kat_running, mbist_active, mbist_running, trc_armed;

    // ----- registers --------------------------------------------------------------------------
    wire        reg_re_s = (ds == D_EXEC) && !q_we && (q_addr[23:8] == 16'd0);
    wire        reg_we_s = (ds == D_EXEC) &&  q_we && (q_addr[23:8] == 16'd0);
    wire [31:0] reg_rdata;
    wire [15:0] err_in;
    wire        fmt_set, fmt_val;
    wire [XPW-1:0] xsel;
    wire [7:0]  sr_n;
    wire [31:0] sr_count, wdog_limit;
    wire [N_LANES-1:0] lane_en;
    wire        pwr_core_hold, pwr_clk_off, pwr_pg_inactive;
    wire [25:0] dbg_sel;
    wire        dbg_latch;
    wire [31:0] trc_cfg, trc_trig_cyc, tile_cfg, tile_slice;
    wire        tile_slice_wr;
    wire        cmd_start, cmd_soft_rst, cmd_sr_start, cmd_sr_stop, cmd_cnt_clr, cmd_cksum_clr, cmd_crc_clr,
                cmd_kat_start, cmd_mbist_start, cmd_trc_arm, cmd_trc_force, cmd_guard_clr, cmd_tile_run,
                cmd_tile_abort;
    wire [3:0]  clkout_k;
    wire        wstale_clr_w, wstale_set_w;
    wire        ev_done, ev_sr_done, ev_trc_done, ev_selftest_done;
    wire [31:0] last_cycles, sr_done_cnt, checksum, sr_pass_cksum, guard_hits, naninf_cnt, load_crc, dbg_data_r;
    wire [63:0] infer_cnt, busy_cyc, total_cyc, sr_cyc;
    wire [31:0] trc_status_w, st_status_w, kat_got_bf16, kat_got_fp32, mbist_status_w, mbist_fail_addr_w, mbist_fail_xor_w;
    wire        reg_irq, reg_err_any, reg_acc_err;
    // tile sequencer wires (spec 18)
    wire        tl_busy, tl_open, tl_ev_slice, tl_ev_final, tl_ev_seq, tl_ev_stale, tl_slice_clr;
    wire        tl_launch, tl_save, tl_last, tl_done_p, tl_fail_p;
    wire [1:0]  tl_seed;
    wire [31:0] tl_status, tl_crc;
    wire        tl_ent_valid;
    wire [7:0]  tl_ent_tag, tl_s_cur;
    wire        active_cond = seq_active | kat_active | mbist_active | tl_busy;
    wire        active = active_cond;
    wire [TBW-1:0]        tl_b;
    wire                  tl_tx_en, tl_xt_we, tl_tz_we, ps_host_wr_w;
    wire [TBW+XW-1:0]     tl_tx_addr;
    wire [XW-1:0]         tl_xt_idx;
    wire [TBW+ZJW-1:0]    tl_tz_addr;
    wire [31:0]           tl_tz_d, tx_q_w, tz_q_w;
    wire [N_LANES*NPAR*16-1:0] ps_q_h, ps_q_l, ps_wd_h, ps_wd_l;
    wire [N_LANES-1:0]    ps_we_w;
    wire [N_LANES*BAW-1:0] ps_waddr_w;
    wire        ps_h_rd, ps_h_wr, ps_h_done, ps_h_busy;
    wire [31:0] ps_h_rdata;
    wire        h_tx_en, h_tx_we, h_tz_en;
    wire [TBW+XW-1:0]  h_tx_addr;
    wire [TBW+ZJW-1:0] h_tz_addr;
    wire [TBW-1:0] ps_hb;
    wire [LNW-1:0] ps_hl;
    wire [BAW-1:0] ps_hg;
    wire [FW-1:0]  ps_hf;
    wire [31:0] reg_status_o, reg_err_o, reg_irq_o;

    rondo_regs #(.WIDTH(WIDTH), .PDIM(PDIM), .DEPTH(DEPTH), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR),
        .NXBUF(NXBUF), .WAW(WAW), .BAW(BAW), .LNW(LNW), .ACCSIG_BF16(ACCSIG_BF16), .TBITS_FP32(TBITS_FP32),
        .NR_ITERS_FP32(NR_ITERS_FP32), .HAS_BF16(HAS_BF16), .HAS_FP32((LAYER == 0) ? HAS_FP32 : 0), .LAYER(LAYER),
        .CKSUM_PAR(CKSUM_PAR), .DBG(DBG), .TRACE(TRACE), .KAT(KAT), .MBIST(MBIST), .SCAN(SCAN),
        .SPI_CRC(SPI_CRC), .CLK_ALT(CLK_ALT), .PG(PG), .TILE(TILE_P), .TILE_B(TILE_B),
        .AW_BF16(8 + ACCSIG_BF16), .HB_BIT(HB_BIT)) u_regs (
        .clk(clk), .rst_n(rst_n), .srst(srst), .reg_re(reg_re_s), .reg_we(reg_we_s),
        .reg_idx(q_addr[7:0]), .reg_wdata(q_wdata), .reg_rdata(reg_rdata), .err_in(err_in),
        .active(active), .busy(layer_busy), .sr_running(sr_running), .sr_stopping(sr_stopping),
        .zvalid(zvalid), .fmt_applied(fmt_applied), .xptr_status(xptr_status),
        .lane_en_applied(lane_en_applied), .kat_running(kat_running), .mbist_running(mbist_running),
        .trc_armed(trc_armed), .wstale_clr(wstale_clr_w), .wstale_set(wstale_set_w),
        .ev_done(ev_done), .ev_sr_done(ev_sr_done), .ev_trc_done(ev_trc_done),
        .ev_selftest_done(ev_selftest_done), .ev_tile_slice(tl_ev_slice), .ev_tile_final(tl_ev_final),
        .last_cycles(last_cycles), .infer_cnt(infer_cnt), .busy_cyc(busy_cyc), .total_cyc(total_cyc),
        .sr_cyc(sr_cyc), .sr_done_cnt(sr_done_cnt), .checksum(checksum), .sr_pass_cksum(sr_pass_cksum),
        .load_crc(load_crc), .guard_hits(guard_hits), .naninf_cnt(naninf_cnt), .dbg_data(dbg_data_r),
        .trc_status(trc_status_w), .st_status(st_status_w), .kat_sig_bf16(SIG_B),
        .kat_sig_fp32(SIG_F), .kat_got_bf16(kat_got_bf16), .kat_got_fp32(kat_got_fp32),
        .mbist_status(mbist_status_w), .mbist_fail_addr(mbist_fail_addr_w), .mbist_fail_xor(mbist_fail_xor_w),
        .tile_status(tl_status), .tile_seq_crc(tl_crc), .div_applied(div_applied), .src_applied_in(src_applied),
        .frame_end(spi_frame_end), .tile_open(tl_open), .tile_slice_clr(tl_slice_clr),
        .fmt_set(fmt_set), .fmt_val(fmt_val), .xsel(xsel), .sr_n(sr_n), .sr_count(sr_count),
        .wdog_limit(wdog_limit), .lane_en(lane_en), .clk_div(clk_div), .clk_src(clk_src), .clkout_k(clkout_k),
        .pwr_core_hold(pwr_core_hold), .pwr_clk_off(pwr_clk_off), .pwr_pg_inactive(pwr_pg_inactive),
        .spi_crc_en(crc_en), .dbg_sel(dbg_sel), .dbg_latch(dbg_latch), .trc_cfg(trc_cfg),
        .trc_trig_cyc(trc_trig_cyc), .tile_cfg(tile_cfg), .tile_slice(tile_slice), .tile_slice_wr(tile_slice_wr),
        .cmd_start(cmd_start), .cmd_soft_rst(cmd_soft_rst), .cmd_sr_start(cmd_sr_start),
        .cmd_sr_stop(cmd_sr_stop), .cmd_cnt_clr(cmd_cnt_clr), .cmd_cksum_clr(cmd_cksum_clr),
        .cmd_crc_clr(cmd_crc_clr), .cmd_kat_start(cmd_kat_start), .cmd_mbist_start(cmd_mbist_start),
        .cmd_trc_arm(cmd_trc_arm), .cmd_trc_force(cmd_trc_force), .cmd_guard_clr(cmd_guard_clr),
        .cmd_tile_run(cmd_tile_run), .cmd_tile_abort(cmd_tile_abort),
        .irq(reg_irq), .status8(status8), .acc_err(reg_acc_err), .err_any(reg_err_any), .status_o(reg_status_o),
        .err_status_o(reg_err_o), .irq_status_o(reg_irq_o), .irq_en_o(), .shd0_o());
    assign irq = reg_irq;

    // ----- sequencer -----------------------------------------------------------------------------
    wire        kat_run_w, kat_done_w, kat_fail_w, kat_sig_clr;
    wire [31:0] kat_sig_w;
    wire [7:0]  kat_n_w;
    wire [31:0] kat_count_w;
    wire [WIDTH*32-1:0] zbuf_v;
    wire [WIDTH*32-1:0] layer_z;
    wire ev_wdog, ev_naninf, ev_guard, ev_wstale_run, ev_start_busy;
    rondo_seq #(.WIDTH(WIDTH), .N_LANES(N_LANES), .NXBUF(NXBUF), .HAS_BF16(HAS_BF16), .HAS_FP32((LAYER == 0) ? HAS_FP32 : 0),
        .CKSUM_PAR(CKSUM_PAR), .PG(PG), .CNT_INIT(CNT_INIT)) u_seq (
        .clk(clk), .rst_n(rst_n), .test_mode(test_mode),
        .cmd_start(cmd_start), .cmd_soft_rst(cmd_soft_rst), .cmd_sr_start(cmd_sr_start),
        .cmd_sr_stop(cmd_sr_stop), .cmd_cnt_clr(cmd_cnt_clr), .cmd_cksum_clr(cmd_cksum_clr),
        .cmd_guard_clr(cmd_guard_clr), .tile_launch(tl_launch), .tile_last(tl_last), .tile_done_p(tl_done_p),
        .tile_fail_p(tl_fail_p), .fmt_set(fmt_set | kat_fmt_set), .fmt_val(kat_fmt_set ? kat_fmt_val : fmt_val),
        .xsel(xsel), .sr_n(sr_n), .sr_count(sr_count), .wdog_limit(wdog_limit), .lane_en(lane_en),
        .pwr_core_hold(pwr_core_hold), .pwr_clk_off(pwr_clk_off), .pwr_pg_inactive(pwr_pg_inactive), .pg_req(pg_req_w),
        .wstale(wstale_q),
        .kat_run(kat_run_w), .kat_n(kat_n_w), .kat_count(kat_count_w), .kat_done(kat_done_w), .kat_fail(kat_fail_w),
        .kat_sig(kat_sig_w), .kat_clr(kat_sig_clr),
        .layer_start(layer_start), .layer_busy(layer_busy), .layer_done(layer_done), .guard_hit(guard_hit),
        .core_rst_n(core_rst_n), .clk_en(clk_en), .fmt_applied(fmt_applied), .xptr(xptr), .zcap(zcap),
        .zbuf(zbuf_v), .lane_en_applied(lane_en_applied), .seq_active(seq_active), .sr_running(sr_running),
        .sr_stopping(sr_stopping), .zvalid(zvalid), .srst(srst), .fsw_pulse(fsw_pulse),
        .xptr_status(xptr_status), .last_cycles(last_cycles), .infer_cnt(infer_cnt), .busy_cyc(busy_cyc),
        .total_cyc(total_cyc), .sr_cyc(sr_cyc), .sr_done_cnt(sr_done_cnt), .checksum(checksum),
        .sr_pass_cksum(sr_pass_cksum), .guard_hits(guard_hits), .naninf_cnt(naninf_cnt),
        .ev_done(ev_done), .ev_sr_done(ev_sr_done), .ev_wdog(ev_wdog), .ev_naninf(ev_naninf),
        .ev_guard(ev_guard), .ev_wstale_run(ev_wstale_run), .ev_start_busy(ev_start_busy));

    // WSTALE shadow for the WSTALE_RUN check (the visible bit lives in rondo_regs)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wstale_q <= 1'b1;
        else begin
            if (wstale_set_w) wstale_q <= 1'b1;
            if (wstale_clr_w) wstale_q <= 1'b0;
        end
    end

    // ----- XBUF / ZBUF -------------------------------------------------------------------------------
    reg [PDIM*32-1:0] xbuf [0:NXBUF-1];
    reg [WIDTH*32-1:0] zbuf_r;
    assign zbuf_v = zbuf_r;
    wire [PDIM*32-1:0] x_xbuf = xbuf[xptr];
    wire [PDIM*32-1:0] x_live;
    integer xi;
    reg  x_wr;
    reg [XPW-1:0] x_we_e;
    reg [XW-1:0]  x_we_i;
    reg [31:0]    x_we_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (xi = 0; xi < NXBUF; xi = xi + 1) xbuf[xi] <= {PDIM*32{1'b0}};
            zbuf_r <= {WIDTH*32{1'b0}};
        end else begin
            if (fsw_pulse) begin
                for (xi = 0; xi < NXBUF; xi = xi + 1) xbuf[xi] <= {PDIM*32{1'b0}};
            end else if (x_wr) xbuf[x_we_e][x_we_i*32 +: 32] <= x_we_d;
            if (srst || fsw_pulse) zbuf_r <= {WIDTH*32{1'b0}};
            else if (zcap) zbuf_r <= layer_z;
        end
    end

    // ----- input tiling: tile sequencer, TX/TZ buffers, x_live (spec 18) -----------------------------------------
    // ----- weight store -------------------------------------------------------------------------------
    wire [N_LANES*WAW-1:0] wm_addr;
    wire [N_LANES*BAW-1:0] bm_addr;
    wire [N_LANES-1:0]     mem_act;
    wire [N_LANES*NPAR*16-1:0] wm_q_h, wm_q_l, bm_q_h, bm_q_l;
    wire        wp_denied, ce_l_any;                // observed by tb_chip_vs_core.v's rondo_sva_wmem through hierarchical references
    wire [NPAR*16-1:0] wp_rd_h, wp_rd_l;
    // KAT / MBIST may own the wrapper port in future (MBIST drives it directly below)
    wire        mb_en, mb_we, mb_bias;
    wire [LNW-1:0] mb_lane;
    wire [WAW-1:0] mb_addr;
    wire [1:0]  mb_half;
    wire [NPAR*16-1:0] mb_wd_h, mb_wd_l;
    wire        mb_own;
    wire [NPAR*16-1:0] pk_wd_h, pk_wd_l;
    wire        pk_en, pk_we, pk_bias;
    wire [LNW-1:0] pk_lane;
    wire [WAW-1:0] pk_addr;
    wire [1:0]  pk_half;
    rondo_wmem #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS)) u_mem (
        .clk(clk), .fmt(fmt_applied), .wm_addr(wm_addr), .bm_addr(bm_addr), .mem_act(mem_act),
        .wm_q_h(wm_q_h), .wm_q_l(wm_q_l), .bm_q_h(bm_q_h), .bm_q_l(bm_q_l),
        .wp_en(mb_own ? mb_en : pk_en), .wp_we(mb_own ? mb_we : pk_we), .wp_bias(mb_own ? mb_bias : pk_bias),
        .wp_lane(mb_own ? mb_lane : pk_lane), .wp_addr(mb_own ? mb_addr : pk_addr),
        .wp_half(mb_own ? mb_half : pk_half), .wp_wd_h(mb_own ? mb_wd_h : pk_wd_h),
        .wp_wd_l(mb_own ? mb_wd_l : pk_wd_l), .wp_rd_h(wp_rd_h), .wp_rd_l(wp_rd_l),
        .wp_denied(wp_denied), .ce_l_any(ce_l_any));

    // decoded weight/bias access
    wire        is_reg   = (q_addr[23:8] == 16'd0);
    wire        is_xbuf  = (q_addr[23:16] == 8'h01);
    wire        is_zbuf  = (q_addr[23:16] == 8'h02);
    wire        is_trc   = (q_addr[23:16] == 8'h03);
    wire        is_bias  = (q_addr[23:16] == 8'h10);
    wire        is_wgt   = (q_addr[23] == 1'b1);
    wire [FW-1:0]  d_f   = q_addr[FW-1:0];
    wire [BAW-1:0] b_g   = q_addr[FW +: BAW];
    wire [LNW-1:0] b_l   = q_addr[BAW+FW +: LNW];
    wire [WAW-1:0] w_a   = q_addr[FW +: WAW];
    wire [LNW-1:0] w_l   = q_addr[WAW+FW +: LNW];
    localparam integer BHI = BAW + FW + LNW;       // bits used below bit 16 for the bias region
    localparam integer WHI = WAW + FW + LNW;
    wire b_hi_zero = (BHI >= 16) ? 1'b1 : (q_addr[15:BHI] == 0);
    wire w_hi_zero = (WHI >= 23) ? 1'b1 : (q_addr[22:WHI] == 0);
    wire bias_ok = (LAYER == 0) && is_bias && b_hi_zero && (32'(b_l) < N_LANES) && (32'(b_g) < NBWORDS);
    wire wgt_ok  = is_wgt && w_hi_zero && (32'(w_l) < N_LANES) && (32'(w_a) < NWORDS);
    wire [XPW-1:0] x_e = q_addr[XW +: XPW];
    wire x_hi_zero = (XW + XPW >= 16) ? 1'b1 : (q_addr[15:XW+XPW] == 0);
    wire [XW-1:0] x_i = q_addr[XW-1:0];
    wire xbuf_ok = is_xbuf && x_hi_zero && (32'(x_e) < NXBUF) && (32'(x_i) < PDIM);
    wire zbuf_ok = is_zbuf && (32'(q_addr[15:0]) < WIDTH);
    wire trc_ok  = is_trc && (TRACE != 0) && (32'(q_addr[15:1]) < TRACE_DEPTH);
    // tiling regions (spec 18.5): TX 0x04, TZ 0x05 (RO), PS 0x06
    wire        is_tx = (q_addr[23:16] == 8'h04), is_tz = (q_addr[23:16] == 8'h05), is_ps = (q_addr[23:16] == 8'h06);
    wire [TBW-1:0] tx_b = q_addr[XW +: TBW];
    wire [XW-1:0]  tx_i = q_addr[XW-1:0];
    wire tx_hi_zero = (XW + TBW >= 16) ? 1'b1 : (q_addr[15:XW+TBW] == 0);
    wire tx_ok = (TILE_P != 0) && is_tx && tx_hi_zero && (32'(tx_b) < TB) && (32'(tx_i) < PDIM);
    wire [TBW-1:0] tz_b = q_addr[ZJW +: TBW];
    wire tz_hi_zero = (ZJW + TBW >= 16) ? 1'b1 : (q_addr[15:ZJW+TBW] == 0);
    wire tz_ok = (TILE_P != 0) && is_tz && tz_hi_zero && (32'(tz_b) < TB) && (32'(q_addr[ZJW-1:0]) < WIDTH);
    assign ps_hf = q_addr[FW-1:0];
    assign ps_hg = q_addr[FW +: BAW];
    assign ps_hl = q_addr[FW+BAW +: LNW];
    assign ps_hb = q_addr[FW+BAW+LNW +: TBW];
    localparam integer PHI = FW + BAW + LNW + TBW;
    wire ps_hi_zero = (PHI >= 16) ? 1'b1 : (q_addr[15:PHI] == 0);
    wire ps_ok = (TILE_P != 0) && (TILE_B > 0) && is_ps && ps_hi_zero && (32'(ps_hb) < TILE_B) &&
                 (32'(ps_hl) < N_LANES) && (32'(ps_hg) < NBWORDS);
    wire t_blocked_w = active && !q_int;
    assign h_tx_en   = (ds == D_EXEC) && tx_ok && !t_blocked_w;
    assign h_tx_we   = q_we;
    assign h_tx_addr = {tx_b, tx_i};
    assign h_tz_en   = (ds == D_EXEC) && tz_ok && !q_we && !t_blocked_w;
    assign h_tz_addr = {tz_b, q_addr[ZJW-1:0]};
    assign ps_h_rd   = (ds == D_EXEC) && ps_ok && !q_we && !t_blocked_w;
    assign ps_h_wr   = (ds == D_EXEC) && ps_ok &&  q_we && !t_blocked_w;
    assign ps_host_wr_w = ps_h_wr;
    wire fmt16   = ~fmt_applied;
    wire [31:0] wd_masked = fmt16 ? {16'd0, q_wdata[15:0]} : q_wdata;

    wire        pk_wr_stb = (ds == D_EXEC) && q_we && (wgt_ok || bias_ok) && (!active || q_int);
    wire        pk_rd_stb = (ds == D_EXEC) && !q_we && (wgt_ok || bias_ok) && (!active || q_int);
    wire        pk_rd_valid, pk_err_partial, pk_busy, pk_wr_done;
    wire [31:0] pk_rd_data;
    wire        kat_ev_inval, kat_ev_crc_clr;
    rondo_wpack #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS)) u_pk (
        .clk(clk), .rst_n(rst_n), .fmt(fmt_applied), .wr_stb(pk_wr_stb), .rd_stb(pk_rd_stb),
        .region_bias(bias_ok), .lane(bias_ok ? b_l : w_l), .caddr(bias_ok ? {{(WAW-BAW){1'b0}}, b_g} : w_a),
        .field(d_f), .wdata(q_wdata), .rd_valid(pk_rd_valid), .rd_data(pk_rd_data),
        .err_partial(pk_err_partial), .busy(pk_busy), .wp_en(pk_en), .wp_we(pk_we), .wp_bias(pk_bias),
        .wp_lane(pk_lane), .wp_addr(pk_addr), .wp_half(pk_half), .wp_wd_h(pk_wd_h), .wp_wd_l(pk_wd_l),
        .wp_rd_h(wp_rd_h), .wp_rd_l(wp_rd_l), .crc_clr(cmd_crc_clr | fsw_pulse | kat_ev_crc_clr | mbist_ev_crc),
        .load_crc(load_crc), .wr_done(pk_wr_done), .cache_inval(kat_ev_inval | fsw_pulse | mbist_ev_inv),
        .flush_staging(srst));
    assign wstale_clr_w = pk_wr_done & ~q_int;       // only external writes make the weights valid again

    // ----- layers -----------------------------------------------------------------------------------------
    wire [LNW-1:0] dbg_lane_w;
    wire [2:0]  dbg_sig_w;
    wire [7:0]  dbg_idx_w;
    wire [1:0]  dbg_live_sel_w;
    wire        dbg_fmt_w, dbg_live_v;
    wire [31:0] layer_dbg_data, dbg_live_d;
    wire [7:0]  dbg_live_f;
    rondo_layers #(.DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR),
        .ACCSIG_BF16(ACCSIG_BF16), .TBITS_FP32(TBITS_FP32), .NR_ITERS_FP32(NR_ITERS_FP32),
        .HAS_BF16(HAS_BF16), .HAS_FP32(HAS_FP32), .LAYER(LAYER), .DBG(DBG), .PG(PG), .TILE(TILE_P)) u_ly (
        .clk(clk), .core_rst_n(core_rst_n), .clk_en(clk_en), .test_mode(test_mode), .fmt(fmt_applied),
        .dbg_fmt(dbg_fmt_w), .start(layer_start), .busy(layer_busy), .done(layer_done), .x(x_live),
        .z(layer_z), .lane_en(lane_en_applied), .guard_hit(guard_hit), .wm_addr(wm_addr), .bm_addr(bm_addr),
        .mem_act(mem_act), .wm_q_h(wm_q_h), .wm_q_l(wm_q_l), .bm_q_h(bm_q_h), .bm_q_l(bm_q_l),
        .tile_seed(tl_seed), .tile_save(tl_save), .tile_last(tl_last), .ps_q_h(ps_q_h), .ps_q_l(ps_q_l),
        .ps_we(ps_we_w), .ps_waddr(ps_waddr_w), .ps_wd_h(ps_wd_h), .ps_wd_l(ps_wd_l),
        .kw_we(pk_en & pk_we & ~pk_bias), .kw_lane(pk_lane), .kw_addr(pk_addr[KNW-1:0]), .kw_din(pk_wd_h),
        .dbg_lane(dbg_lane_w), .dbg_sig(dbg_sig_w), .dbg_idx(dbg_idx_w), .dbg_data(layer_dbg_data),
        .dbg_live_sel(dbg_live_sel_w), .dbg_live_v(dbg_live_v), .dbg_live_d(dbg_live_d),
        .dbg_live_f(dbg_live_f), .lclk_obs(lclk_obs), .pg_iso(pg_req_w), .pg_req());
    assign pg_req = pg_req_w;

    // ----- input tiling -------------------------------------------------------------------------------
    generate
        if (TILE_P != 0) begin : g_tile
            reg [PDIM*32-1:0] xt_r;
            always @(posedge clk) if (tl_xt_we) xt_r[tl_xt_idx*32 +: 32] <= tx_q_w;
            assign x_live = tl_busy ? xt_r : x_xbuf;
            rondo_tile #(.TB(TB), .PDIM(PDIM), .WIDTH(WIDTH), .TBW(TBW), .XW(XW), .ZJW(ZJW)) u_tile (
                .clk(clk), .rst_n(rst_n), .srst(srst), .cmd_run(cmd_tile_run), .cmd_abort(cmd_tile_abort),
                .cfg(tile_cfg), .slice_reg(tile_slice), .load_crc(load_crc),
                .inval_ext(fsw_pulse | kat_ev_inval | mbist_ev_inv), .other_start(layer_start & ~tl_busy),
                .ps_host_wr(ps_host_wr_w), .ps_host_b(ps_hb),
                .launch(tl_launch), .seed(tl_seed), .save(tl_save), .last(tl_last),
                .seq_done(tl_done_p), .seq_fail(tl_fail_p),
                .tx_en(tl_tx_en), .tx_addr(tl_tx_addr), .tx_q(tx_q_w), .xt_we(tl_xt_we), .xt_idx(tl_xt_idx),
                .tz_we(tl_tz_we), .tz_addr(tl_tz_addr), .tz_d(tl_tz_d), .zbuf(zbuf_r), .b_cur(tl_b),
                .busy(tl_busy), .open_o(tl_open), .status(tl_status), .seq_crc(tl_crc),
                .ent_valid(tl_ent_valid), .ent_tag(tl_ent_tag), .s_cur_o(tl_s_cur),
                .ev_slice(tl_ev_slice), .ev_final(tl_ev_final), .ev_seq(tl_ev_seq), .ev_stale(tl_ev_stale),
                .slice_clr(tl_slice_clr));
            rondo_tbuf #(.TBW(TBW), .XW(XW), .ZJW(ZJW)) u_tbuf (
                .clk(clk), .t_own(tl_busy),
                .t_tx_en(tl_tx_en), .t_tx_addr(tl_tx_addr), .h_tx_en(h_tx_en), .h_tx_we(h_tx_we),
                .h_tx_addr(h_tx_addr), .h_tx_d(wd_masked), .tx_q(tx_q_w),
                .t_tz_we(tl_tz_we), .t_tz_addr(tl_tz_addr), .t_tz_d(tl_tz_d), .h_tz_en(h_tz_en),
                .h_tz_addr(h_tz_addr), .tz_q(tz_q_w));
            if (TILE_B > 0) begin : g_ps
                rondo_ps #(.N_LANES(N_LANES), .NPAR(NPAR), .BAW(BAW), .TBW(TBW)) u_ps (
                    .clk(clk), .rst_n(rst_n), .fmt(fmt_applied), .b_cur(tl_b), .bm_addr(bm_addr), .mem_act(mem_act),
                    .rd_en(tl_busy & (tl_seed == 2'd2)), .q_h(ps_q_h), .q_l(ps_q_l),
                    .ps_we(ps_we_w), .ps_waddr(ps_waddr_w), .wd_h(ps_wd_h), .wd_l(ps_wd_l),
                    .h_rd(ps_h_rd), .h_wr(ps_h_wr), .h_b(ps_hb), .h_l(ps_hl), .h_g(ps_hg), .h_f(ps_hf),
                    .h_wdata(wd_masked), .h_done(ps_h_done), .h_rdata(ps_h_rdata), .h_busy(ps_h_busy));
            end else begin : g_nops
                assign ps_q_h = {N_LANES*NPAR*16{1'b0}}; assign ps_q_l = {N_LANES*NPAR*16{1'b0}};
                assign ps_h_done = 1'b0; assign ps_h_rdata = 32'd0; assign ps_h_busy = 1'b0;
            end
        end else begin : g_notile
            assign x_live = x_xbuf;
            assign tl_busy = 1'b0; assign tl_open = 1'b0; assign tl_status = 32'd0; assign tl_crc = 32'd0; assign tl_ent_valid = 1'b0; assign tl_ent_tag = 8'd0; assign tl_s_cur = 8'd0;
            assign tl_ev_slice = 1'b0; assign tl_ev_final = 1'b0; assign tl_ev_seq = 1'b0; assign tl_ev_stale = 1'b0;
            assign tl_slice_clr = 1'b0; assign tl_launch = 1'b0; assign tl_seed = 2'd0; assign tl_save = 1'b0;
            assign tl_last = 1'b1; assign tx_q_w = 32'd0; assign tz_q_w = 32'd0;
            assign ps_q_h = {N_LANES*NPAR*16{1'b0}}; assign ps_q_l = {N_LANES*NPAR*16{1'b0}};
            assign ps_h_done = 1'b0; assign ps_h_rdata = 32'd0; assign ps_h_busy = 1'b0;
        end
    endgenerate

    // ----- debug mux ---------------------------------------------------------------------------------------
    rondo_dbgmux #(.LNW(LNW)) u_dbg (
        .clk(clk), .rst_n(rst_n), .dbg_sel(dbg_sel), .dbg_latch(dbg_latch), .fmt_applied(fmt_applied),
        .layer_dbg_data(layer_dbg_data), .dbg_lane(dbg_lane_w), .dbg_sig(dbg_sig_w), .dbg_idx(dbg_idx_w),
        .dbg_live_sel(dbg_live_sel_w), .dbg_fmt(dbg_fmt_w), .dbg_data_r(dbg_data_r));

    // ----- trace ------------------------------------------------------------------------------------------------
    wire [31:0] trc_rd_data;
    wire        trc_trigd, trc_done_lvl;
    wire [7:0]  trc_nvalid, trc_tidx;
    generate
        if (TRACE != 0) begin : g_trc
            wire [31:0] ev_data = {6'd0, 1'b0, spi_frame_end, 1'b0, xptr_status[3:0] , layer_busy, layer_done, layer_start, q_addr[15:0]};
            wire        ev_valid = layer_start | layer_done | spi_frame_end | accept;
            wire [31:0] rb_data = rb_rsp_rdata;
            wire        rb_valid = rb_rsp_valid;
            wire [31:0] gd_data = 32'(guard_hit);
            wire        gd_valid = |guard_hit;
            wire        t_err = |reg_err_o;
            rondo_trace #(.DEPTH(TRACE_DEPTH)) u_trc (
                .clk(clk), .rst_n(rst_n), .srst(srst), .cfg(trc_cfg), .trig_cyc(trc_trig_cyc),
                .arm(cmd_trc_arm), .force_trig(cmd_trc_force),
                .live_v(dbg_live_v), .live_d(dbg_live_d), .live_f(dbg_live_f),
                .ev_data(ev_data), .ev_valid(ev_valid),
                .rb_data(rb_data), .rb_valid(rb_valid), .rb_flags({6'd0, rb_rsp_err, q_we}), .rb_tag(q_addr[7:0]),
                .gd_data(gd_data), .gd_valid(gd_valid), .gd_flags({6'd0, 1'b0, 1'b1}), .gd_tag(8'd0),
                .t_start(layer_start), .t_done(layer_done), .t_guard(|guard_hit), .t_err(t_err),
                .armed(trc_armed), .trigd(trc_trigd), .done(ev_trc_done), .done_lvl(trc_done_lvl),
                .nvalid(trc_nvalid), .trig_idx(trc_tidx), .rd_k({1'b0, q_addr[TIW:1]}), .rd_meta(q_addr[0]),
                .rd_data(trc_rd_data));
            assign trc_status_w = {8'd0, trc_tidx, trc_nvalid, 5'd0, trc_done_lvl, trc_trigd, trc_armed};
        end else begin : g_notrc
            assign trc_armed = 1'b0; assign ev_trc_done = 1'b0; assign trc_rd_data = 32'd0;
            assign trc_status_w = 32'd0; assign trc_trigd = 1'b0; assign trc_done_lvl = 1'b0;
            assign trc_nvalid = 8'd0; assign trc_tidx = 8'd0;
        end
    endgenerate

    // ----- KAT / self test ----------------------------------------------------------------------------------------
    wire        k_req_valid, k_req_we, k_rsp_valid;
    wire [23:0] k_req_addr;
    wire [31:0] k_req_wdata, k_rsp_rdata;
    wire        kat_mb_start, kat_ev_fail, kat_ev_wstale;
    wire        kat_running_w;
    wire        arb_k_req_ready;
    generate
        if (KAT != 0) begin : g_kat
            rondo_kat #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS), .PDIM(PDIM),
                .NXBUF(NXBUF), .WAW(WAW), .BAW(BAW), .XW(XW), .FW(FW), .HAS_BF16(HAS_BF16),
                .HAS_FP32(HAS_FP32), .MBIST(MBIST), .SIG_BF16(SIG_B), .SIG_FP32(SIG_F)) u_kat (
                .clk(clk), .rst_n(rst_n), .srst(srst), .cmd_start(cmd_kat_start), .strap(bist_strap),
                .fmt_applied(fmt_applied), .seq_idle(!seq_active),
                .rb_req_valid(k_req_valid), .rb_req_ready(arb_k_req_ready), .rb_req_we(k_req_we),
                .rb_req_addr(k_req_addr), .rb_req_wdata(k_req_wdata), .rb_rsp_valid(k_rsp_valid),
                .rb_rsp_rdata(k_rsp_rdata), .seq_run(kat_run_w), .seq_n(kat_n_w), .seq_count(kat_count_w),
                .seq_done(kat_done_w), .seq_fail(kat_fail_w), .seq_sig(kat_sig_w), .sig_clr(kat_sig_clr),
                .fmt_set_o(kat_fmt_set), .fmt_val_o(kat_fmt_val), .mbist_start_o(kat_mb_start),
                .mbist_done(mb_done), .mbist_pass(mb_pass), .kat_active(kat_active), .running_kat(kat_running_w),
                .st_status(st_status_w), .got_bf16(kat_got_bf16), .got_fp32(kat_got_fp32), .st_pass(st_pass),
                .ev_selftest_done(ev_selftest_done), .ev_kat_fail(kat_ev_fail), .ev_wstale_set(kat_ev_wstale),
                .ev_crc_clr(kat_ev_crc_clr), .ev_inval(kat_ev_inval), .mbist_running_in(mbist_running));
            assign kat_running = kat_running_w;
        end else begin : g_nokat
            assign kat_active = 1'b0; assign kat_running = 1'b0; assign st_status_w = 32'd0;
            assign kat_got_bf16 = 32'd0; assign kat_got_fp32 = 32'd0; assign st_pass = 1'b0;
            assign ev_selftest_done = 1'b0; assign kat_ev_fail = 1'b0; assign kat_ev_wstale = 1'b0;
            assign kat_ev_crc_clr = 1'b0; assign kat_ev_inval = 1'b0; assign kat_fmt_set = 1'b0;
            assign kat_fmt_val = 1'b0; assign kat_mb_start = 1'b0; assign kat_run_w = 1'b0;
            assign kat_n_w = 8'd0; assign kat_count_w = 32'd0; assign kat_sig_clr = 1'b0;
            assign k_req_valid = 1'b0; assign k_req_we = 1'b0; assign k_req_addr = 24'd0;
            assign k_req_wdata = 32'd0;
        end
        if (MBIST != 0) begin : g_mbist
            wire [31:0] mb_status, mb_faddr, mb_fxor;
            wire        mb_ev_fail, mb_ev_ws, mb_ev_crc, mb_ev_inv, mb_run;
            rondo_mbist #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS), .WAW(WAW),
                          .BAW(BAW), .LNW(LNW)) u_mb (
                .clk(clk), .rst_n(rst_n), .srst(srst), .start(cmd_mbist_start | kat_mb_start),
                .wp_en(mb_en), .wp_we(mb_we), .wp_bias(mb_bias), .wp_lane(mb_lane), .wp_addr(mb_addr),
                .wp_half(mb_half), .wp_wd_h(mb_wd_h), .wp_wd_l(mb_wd_l), .wp_rd_h(wp_rd_h), .wp_rd_l(wp_rd_l),
                .running(mb_run), .done(mb_done), .pass_lvl(mb_pass), .ev_fail(mb_ev_fail),
                .ev_wstale_set(mb_ev_ws), .ev_crc_clr(mb_ev_crc), .ev_inval(mb_ev_inv),
                .status(mb_status), .fail_addr(mb_faddr), .fail_xor(mb_fxor));
            assign mbist_active = mb_run; assign mbist_running = mb_run; assign mb_own = mb_run;
            assign mbist_status_w = mb_status; assign mbist_fail_addr_w = mb_faddr; assign mbist_fail_xor_w = mb_fxor;
            assign mbist_ev_fail = mb_ev_fail; assign mbist_ev_ws = mb_ev_ws; assign mbist_ev_crc = mb_ev_crc;
            assign mbist_ev_inv = mb_ev_inv;
        end else begin : g_nomb
            assign mbist_active = 1'b0; assign mbist_running = 1'b0; assign mb_en = 1'b0; assign mb_we = 1'b0;
            assign mb_bias = 1'b0; assign mb_lane = {LNW{1'b0}}; assign mb_addr = {WAW{1'b0}};
            assign mb_half = 2'b0; assign mb_wd_h = {NPAR*16{1'b0}}; assign mb_wd_l = {NPAR*16{1'b0}};
            assign mb_own = 1'b0; assign mb_done = 1'b0; assign mb_pass = 1'b1;
            assign mbist_status_w = 32'd0; assign mbist_fail_addr_w = 32'd0; assign mbist_fail_xor_w = 32'd0;
            assign mbist_ev_fail = 1'b0; assign mbist_ev_ws = 1'b0; assign mbist_ev_crc = 1'b0; assign mbist_ev_inv = 1'b0;
        end
    endgenerate
    // ----- arbiter ------------------------------------------------------------------------------------
    wire        e_req_ready_a, e_rsp_valid_a, e_rsp_err_a;
    wire [31:0] e_rsp_rdata_a;
    wire        k_rsp_err_w, m_req_ready_w, m_rsp_valid_w, m_rsp_err_w;
    wire [31:0] m_rsp_rdata_w;
    rondo_rbus_arb u_arb (
        .clk(clk), .rst_n(rst_n), .srst(srst),
        .e_req_valid(rb_req_valid), .e_req_ready(e_req_ready_a), .e_req_we(rb_req_we), .e_req_addr(rb_req_addr),
        .e_req_wdata(rb_req_wdata), .e_rsp_valid(e_rsp_valid_a), .e_rsp_ready(rb_rsp_ready),
        .e_rsp_rdata(e_rsp_rdata_a), .e_rsp_err(e_rsp_err_a),
        .k_req_valid(k_req_valid), .k_req_ready(arb_k_req_ready), .k_req_we(k_req_we), .k_req_addr(k_req_addr),
        .k_req_wdata(k_req_wdata), .k_rsp_valid(k_rsp_valid), .k_rsp_rdata(k_rsp_rdata), .k_rsp_err(k_rsp_err_w),
        .m_req_valid(1'b0), .m_req_ready(m_req_ready_w), .m_req_we(1'b0), .m_req_addr(24'd0), .m_req_wdata(32'd0),
        .m_rsp_valid(m_rsp_valid_w), .m_rsp_rdata(m_rsp_rdata_w), .m_rsp_err(m_rsp_err_w),
        .o_req_valid(o_req_valid), .o_req_ready(o_req_ready), .o_req_we(o_req_we), .o_req_addr(o_req_addr),
        .o_req_wdata(o_req_wdata), .o_req_int(o_req_int),
        .o_rsp_valid(o_rsp_valid), .o_rsp_ready(o_rsp_ready), .o_rsp_rdata(o_rsp_rdata), .o_rsp_err(o_rsp_err));
    assign rb_req_ready = e_req_ready_a;
    always @* begin
        rb_rsp_valid = e_rsp_valid_a;
        rb_rsp_rdata = e_rsp_rdata_a;
        rb_rsp_err   = e_rsp_err_a;
    end

    // ----- slave FSM: decode / execute / respond -------------------------------------------------------------
    reg [2:0]  dev_err;                  // BUSY_WR, ADDR, RO (one-cycle pulses merged into err_in)
    reg [31:0] r_data;
    reg        r_err;
    wire        blocked = active && !q_int;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ds <= D_IDLE; q_we <= 1'b0; q_int <= 1'b0; mem_sel_tz <= 1'b0; q_addr <= 24'd0; q_wdata <= 32'd0;
            o_rsp_valid <= 1'b0; o_rsp_rdata <= 32'd0; o_rsp_err <= 1'b0; dev_err <= 3'd0;
            r_data <= 32'd0; r_err <= 1'b0; x_wr <= 1'b0; x_we_e <= {XPW{1'b0}}; x_we_i <= {XW{1'b0}};
            x_we_d <= 32'd0;
        end else begin
            dev_err <= 3'd0; x_wr <= 1'b0;
            // soft reset (spec 8.2 rule 6): an accepted request is always answered. D_IDLE stays idle (o_req_ready includes !srst);
            // only an in-flight weight read-back is aborted (D_WAITRD, answered with 0 and rsp_err); the other states are bounded and proceed.
            case (ds)
                D_IDLE: if (accept) begin
                    q_we <= o_req_we; q_addr <= o_req_addr; q_wdata <= o_req_wdata; q_int <= o_req_int;
                    ds <= D_EXEC;
                end
                D_EXEC: begin
                    r_err <= 1'b0;
                    if (is_reg) begin
                        r_data <= q_we ? 32'd0 : reg_rdata;
                        ds <= D_FIN;
                    end else if (wgt_ok || bias_ok) begin
                        if (blocked) begin
                            dev_err[0] <= 1'b1; r_err <= 1'b1; r_data <= 32'd0; ds <= D_FIN;
                        end else if (q_we) begin
                            r_data <= 32'd0; ds <= D_FIN;           // wpack strobe issued this cycle
                        end else ds <= D_WAITRD;                      // read-back through wpack
                    end else if (xbuf_ok) begin
                        if (q_we) begin
                            if (blocked) begin dev_err[0] <= 1'b1; r_err <= 1'b1; end
                            else begin x_wr <= 1'b1; x_we_e <= x_e; x_we_i <= x_i; x_we_d <= wd_masked; end
                            r_data <= 32'd0;
                        end else r_data <= xbuf[x_e][x_i*32 +: 32];
                        ds <= D_FIN;
                    end else if (tx_ok || tz_ok || ps_ok) begin
                        if (t_blocked_w) begin
                            dev_err[0] <= 1'b1; r_err <= 1'b1; r_data <= 32'd0; ds <= D_FIN;
                        end else if (tz_ok && q_we) begin
                            dev_err[2] <= 1'b1; r_err <= 1'b1; r_data <= 32'd0; ds <= D_FIN;
                        end else if (ps_ok) begin
                            r_data <= 32'd0; ds <= D_WAITPS;
                        end else if (q_we) begin
                            r_data <= 32'd0; ds <= D_FIN;                // TX write issued this cycle
                        end else begin
                            mem_sel_tz <= tz_ok; ds <= D_WAITM;
                        end
                    end else if (zbuf_ok) begin
                        if (q_we) begin dev_err[2] <= 1'b1; r_err <= 1'b1; r_data <= 32'd0; end
                        else r_data <= zbuf_r[q_addr[ZJW-1:0]*32 +: 32];
                        ds <= D_FIN;
                    end else if (trc_ok) begin
                        if (q_we) begin dev_err[2] <= 1'b1; r_err <= 1'b1; r_data <= 32'd0; end
                        else r_data <= trc_rd_data;
                        ds <= D_FIN;
                    end else begin
                        dev_err[1] <= 1'b1; r_err <= 1'b1; r_data <= 32'd0; ds <= D_FIN;      // hole
                    end
                end
                D_WAITM: begin r_data <= mem_sel_tz ? tz_q_w : tx_q_w; ds <= D_FIN; end
                D_WAITPS: if (ps_h_done) begin r_data <= q_we ? 32'd0 : ps_h_rdata; ds <= D_FIN; end
                D_WAITRD: if (srst) begin r_data <= 32'd0; r_err <= 1'b1; ds <= D_FIN; end
                          else if (pk_rd_valid) begin r_data <= pk_rd_data; ds <= D_FIN; end
                D_FIN: begin
                    o_rsp_valid <= 1'b1; o_rsp_rdata <= r_data;
                    o_rsp_err <= r_err | (is_reg & reg_acc_err);
                    ds <= D_RSP;
                end
                D_RSP: if (o_rsp_ready) begin o_rsp_valid <= 1'b0; ds <= D_IDLE; end
                default: ds <= D_IDLE;
            endcase
        end
    end

    // ----- merged error pulses into rondo_regs ---------------------------------------------------------------------
    assign err_in = {tl_ev_stale, tl_ev_seq, ev_wstale_run, mbist_ev_fail, kat_ev_fail, spi_err_crc, ev_guard, ev_naninf, ev_wdog,
                     spi_err_frame, 1'b0, pk_err_partial, ev_start_busy, dev_err[2], dev_err[1] , dev_err[0]};

    // ----- misc outputs ----------------------------------------------------------------------------------------------
    assign wstale_set_w = fsw_pulse | kat_ev_wstale | mbist_ev_ws;
    reg busy_r, clkout_r;
    reg [14:0] clkdiv_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin busy_r <= 1'b0; clkout_r <= 1'b0; clkdiv_cnt <= 15'd0; end
        else begin
            busy_r <= active;
            clkdiv_cnt <= clkdiv_cnt + 15'd1;
            clkout_r <= (clkout_k == 4'd0) ? 1'b0 : clkdiv_cnt[clkout_k - 4'd1];
        end
    end
    assign checksum_o  = checksum;
    assign fmt_o       = fmt_applied;
    assign heartbeat_o = reg_status_o[6];
    assign err_any_o   = reg_err_any;
    assign busy_pin = busy_r;
    assign clkout   = clkout_r;
endmodule
