// rondo_seq: sequencer, instrumentation, layer power/clock/reset control (spec 3.4, 9.4-9.6, 10, 12).
//
// Launch FSM:  IDLE -> LAUNCH -> WAIT -> (POST | GAP -> LAUNCH),  plus SRST (soft reset).
//   LAUNCH   layer start for one cycle (combinational from the state flop), xptr set, latency counter 0
//   WAIT     counts cycles until the layer's done; in the done cycle ZBUF is captured (zcap),
//            LAST_CYCLES latched, counters updated, checksum walk started
//   GAP      self-run: next start exactly t+2 after done at t (spec 10.2 rule 4)
//   POST     waits for the checksum walk, then raises the completion event
// Two layer-control FSMs (one per format) implement the clock/reset ordering of spec 3.4:
// a newly active layer gets its clock first and its reset released 2 cycles later; a
// newly inactive layer is put into reset first and its clock gated 2 cycles later.
module rondo_seq #(
    parameter WIDTH    = 64,
    parameter N_LANES  = 8,
    parameter NXBUF    = 4,
    parameter HAS_BF16 = 1,
    parameter HAS_FP32 = 1,
    parameter CKSUM_PAR = 0,
    parameter PG       = 0,
    parameter CNT_INIT = 0,         // simulation-only TOTAL_CYC preset; must be 0 in silicon
    parameter XPW      = (NXBUF < 2) ? 1 : $clog2(NXBUF)
) (
    input                  clk,
    input                  rst_n,               // sys_rst_n
    input                  test_mode,
    // commands (1-cycle pulses; priority resolved by rondo_regs)
    input                  cmd_start,
    input                  cmd_soft_rst,
    input                  cmd_sr_start,
    input                  cmd_sr_stop,
    input                  cmd_cnt_clr,
    input                  cmd_cksum_clr,
    input                  cmd_guard_clr,
    input                  tile_launch,         // tile sequencer: launch one (partial or final) input
    input                  tile_last,           // held stable by the tile sequencer: 1 = final slice
    output reg             tile_done_p,         // 1-cycle pulse: the tile launch finished
    output reg             tile_fail_p,         // 1-cycle pulse: the tile launch was refused
    input                  fmt_set,             // FORMAT written (value in fmt_val)
    input                  fmt_val,
    // configuration
    input  [XPW-1:0]       xsel,
    input  [7:0]           sr_n,
    input  [31:0]          sr_count,
    input  [31:0]          wdog_limit,
    input  [N_LANES-1:0]   lane_en,
    input                  pwr_core_hold,
    input                  pwr_clk_off,
    input                  pwr_pg_inactive,
    output reg [1:0]       pg_req,            // power-switch request per layer (PG=1 builds)
    input                  wstale,
    // KAT internal self-run (private signature)
    input                  kat_run,
    input  [7:0]           kat_n,
    input  [31:0]          kat_count,
    output reg             kat_done,
    output reg             kat_fail,            // 1-cycle pulse: the KAT launch was refused (layer not ready / clock off)
    output [31:0]          kat_sig,
    input                  kat_clr,
    // layer interface
    output                 layer_start,
    input                  layer_busy,
    input                  layer_done,
    input  [N_LANES-1:0]   guard_hit,
    output [1:0]           core_rst_n,
    output [1:0]           clk_en,
    output reg             fmt_applied,
    output [XPW-1:0]       xptr,
    output                 zcap,
    input  [WIDTH*32-1:0]  zbuf,
    output reg [N_LANES-1:0] lane_en_applied,
    // status
    output                 seq_active,          // sequencer/soft reset/format switch/layer settling
    output                 sr_running,
    output                 sr_stopping,
    output reg             zvalid,
    output                 srst,                // soft reset in progress (8 cycles)
    output reg             fsw_pulse,           // 1 cycle at the start of a format switch
    output reg [3:0]       xptr_status,
    // counters
    output reg [31:0]      last_cycles,
    output reg [63:0]      infer_cnt, busy_cyc, total_cyc, sr_cyc,
    output reg [31:0]      sr_done_cnt,
    output [31:0]          checksum,
    output reg [31:0]      sr_pass_cksum,
    output reg [31:0]      guard_hits,
    output reg [31:0]      naninf_cnt,
    // event pulses
    output reg             ev_done,             // single-shot finished (IRQ DONE)
    output reg             ev_sr_done,
    output reg             ev_wdog,
    output reg             ev_naninf,
    output reg             ev_guard,
    output reg             ev_wstale_run,
    output reg             ev_start_busy
);
    localparam [2:0] ST_IDLE = 3'd0, ST_LAUNCH = 3'd1, ST_WAIT = 3'd2, ST_GAP = 3'd3,
                     ST_POST = 3'd4, ST_SRST = 3'd5;
    localparam [1:0] K_SINGLE = 2'd0, K_SR = 2'd1, K_KAT = 2'd2, K_TILE = 2'd3;

    reg [2:0]  st;
    reg [1:0]  kind;
    reg [XPW-1:0] xp;
    reg [7:0]  n_q;
    reg [31:0] cnt_q;
    reg        stopping_q, sr_run_q, last_inf;
    reg [3:0]  srst_cnt;
    reg [31:0] lat;
    reg        done_seen;

    wire cur_ready_q;
    assign srst        = (st == ST_SRST);
    assign layer_start = (st == ST_LAUNCH) && cur_ready_q;
    assign xptr        = xp;
    assign sr_running  = sr_run_q;
    assign sr_stopping = stopping_q;

    // ---- layer control FSMs (clock / reset ordering) --------------------------------------
    localparam [1:0] L_OFF = 2'd0, L_CLK = 2'd1, L_RUN = 2'd2, L_RST = 2'd3;
    reg [1:0] ls [0:1];
    reg [1:0] lt [0:1];        // 2-cycle timers
    reg [1:0] lrdy [0:1];      // post-release settle counter (launch rule 5)
    wire [1:0] want;
    reg fmt_want;                       // target format; fmt_applied follows once the old layer is in reset
    reg [4:0] pgc [0:1];                // power-up reset hold (16 cycles) after a layer's supply returns
    wire [1:0] pgblk;
    assign pgblk[0] = (pg_req[0] || pgc[0] != 5'd0);
    assign pgblk[1] = (pg_req[1] || pgc[1] != 5'd0);
    assign want[0] = (HAS_BF16 != 0) && !fmt_want && !pwr_core_hold && !(srst && !fmt_applied) && !pgblk[0];
    assign want[1] = (HAS_FP32 != 0) &&  fmt_want && !pwr_core_hold && !(srst &&  fmt_applied) && !pgblk[1];
    // spec 11.9: the inactive layer's supply is requested off once it is clock-gated and in reset
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pg_req <= 2'b00; pgc[0] <= 5'd0; pgc[1] <= 5'd0; end
        else begin
            pg_req[0] <= (PG != 0) && pwr_pg_inactive && fmt_want  && (ls[0] == 2'd0);
            pg_req[1] <= (PG != 0) && pwr_pg_inactive && !fmt_want && (ls[1] == 2'd0);
            if (pg_req[0] && !((PG != 0) && pwr_pg_inactive && fmt_want  && (ls[0] == 2'd0))) pgc[0] <= 5'd16;
            else if (pgc[0] != 5'd0) pgc[0] <= pgc[0] - 5'd1;
            if (pg_req[1] && !((PG != 0) && pwr_pg_inactive && !fmt_want && (ls[1] == 2'd0))) pgc[1] <= 5'd16;
            else if (pgc[1] != 5'd0) pgc[1] <= pgc[1] - 5'd1;
        end
    end
    wire [1:0] ready;
    wire [1:0] run_q;                   // one flop per layer: == (ls == L_RUN) in every cycle; drives the layer's asynchronous reset (spec 3.4)
    genvar f;
    generate
        for (f = 0; f < 2; f = f + 1) begin : g_ly
            reg run_f;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin ls[f] <= L_OFF; lt[f] <= 2'd0; lrdy[f] <= 2'd0; run_f <= 1'b0; end
                else begin
                    case (ls[f])
                        L_OFF: if (want[f]) begin ls[f] <= L_CLK; lt[f] <= 2'd2; end
                        L_CLK: if (!want[f]) begin ls[f] <= L_RST; lt[f] <= 2'd2; end
                               else if (lt[f] == 2'd0) begin ls[f] <= L_RUN; lrdy[f] <= 2'd2; run_f <= 1'b1; end
                               else lt[f] <= lt[f] - 2'd1;
                        L_RUN: if (!want[f]) begin ls[f] <= L_RST; lt[f] <= 2'd2; lrdy[f] <= 2'd0; run_f <= 1'b0; end
                               else if (lrdy[f] != 2'd0) lrdy[f] <= lrdy[f] - 2'd1;
                        L_RST: if (lt[f] == 2'd0) ls[f] <= L_OFF; else lt[f] <= lt[f] - 2'd1;
                        default: begin ls[f] <= L_OFF; run_f <= 1'b0; end
                    endcase
                end
            end
            assign run_q[f] = run_f;
`ifdef FORMAL
            // B6 invariant (spec 3.4): the reset flop equals the RUN state in every cycle (checked by formal/seq.sby)
            always @* assert (run_f == (ls[f] == L_RUN));
`endif
            // reset is held low except in RUN (a flop output, not a decode); the clock runs in CLK/RUN/RST (+ test_mode / not clk_off).
            // The test-mode mux is the spec 11.7 DFT bypass.
            assign core_rst_n[f] = test_mode ? rst_n : run_q[f];
            assign clk_en[f]     = (ls[f] != L_OFF) && !pwr_clk_off;
            assign ready[f]      = (ls[f] == L_RUN) && (lrdy[f] == 2'd0);
        end
    endgenerate
    wire cur_ready = fmt_applied ? ready[1] : ready[0];
    assign cur_ready_q = cur_ready && !pwr_core_hold;
    wire settling  = (fmt_applied != fmt_want) || ((fmt_applied ? want[1] : want[0]) && !cur_ready);
    wire clk_ok    = !pwr_clk_off;

    assign seq_active = (st != ST_IDLE) || settling;

    // ---- checksum ---------------------------------------------------------------------------
    reg  ck_go, ck_upd, ck_kat;
    wire ck_busy, ck_done;
    wire [31:0] ksig;
    wire [15:0] ck_nn;
    wire [31:0] cks_w;
    assign checksum = cks_w;
    assign kat_sig  = ksig;
    rondo_cksum #(.WIDTH(WIDTH), .N_LANES(N_LANES), .PAR(CKSUM_PAR)) u_ck (
        .clk(clk), .rst_n(rst_n), .srst(srst), .clr_main(cmd_cksum_clr | fsw_pulse | (cmd_sr_start & (st == ST_IDLE) & cur_ready & clk_ok)),
        .clr_kat(kat_clr), .go(ck_go), .upd_en(ck_upd), .kat_mode(ck_kat), .zbuf(zbuf),
        .w16(~fmt_applied), .lane_en(lane_en_applied), .checksum(cks_w), .ksig(ksig), .busy(ck_busy),
        .done(ck_done), .naninf_n(ck_nn));

    // ---- main FSM -----------------------------------------------------------------------------
    assign zcap = (st == ST_WAIT) && layer_done && !((kind == K_TILE) && !tile_last);   // partial slices never write ZBUF

    wire [7:0] sr_n_eff = (sr_n == 8'd0) ? 8'd1 : sr_n;
    reg        walk_pend, pass_pend, ck_done_q;
    reg [31:0] icnt;                       // inferences completed in the current self-run / KAT run
    wire [31:0] icnt_n = icnt + 32'd1;
    wire        wd_hit = (wdog_limit != 32'd0) && (lat > wdog_limit);
    wire        stop_req = stopping_q | (cmd_sr_stop & sr_run_q);
    // number of guard pulses this cycle
    reg [3:0] gh_pop;
    integer gi;
    always @* begin
        gh_pop = 4'd0;
        for (gi = 0; gi < N_LANES; gi = gi + 1) gh_pop = gh_pop + {3'd0, guard_hit[gi]};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; kind <= K_SINGLE; xp <= '0; n_q <= 8'd1; cnt_q <= 32'd0;
            stopping_q <= 1'b0; sr_run_q <= 1'b0; last_inf <= 1'b0; srst_cnt <= 4'd0; lat <= 32'd0;
            fmt_applied <= 1'b0; fmt_want <= 1'b0; zvalid <= 1'b0; fsw_pulse <= 1'b0; xptr_status <= '0;
            last_cycles <= 32'd0; infer_cnt <= 64'd0; busy_cyc <= 64'd0; total_cyc <= {32'd0, CNT_INIT[31:0]};   // zero-extended (64'(CNT_INIT) sign-extended the 32-bit int parameter under Verilator)
            sr_cyc <= 64'd0; sr_done_cnt <= 32'd0; sr_pass_cksum <= 32'd0; guard_hits <= 32'd0;
            naninf_cnt <= 32'd0; ev_done <= 1'b0; ev_sr_done <= 1'b0; ev_wdog <= 1'b0; ev_naninf <= 1'b0;
            ev_guard <= 1'b0; ev_wstale_run <= 1'b0; ev_start_busy <= 1'b0; kat_done <= 1'b0; kat_fail <= 1'b0;
            tile_done_p <= 1'b0; tile_fail_p <= 1'b0;
            ck_go <= 1'b0; ck_upd <= 1'b0; ck_kat <= 1'b0; lane_en_applied <= {N_LANES{1'b1}};
            done_seen <= 1'b0; walk_pend <= 1'b0; pass_pend <= 1'b0; ck_done_q <= 1'b0; icnt <= 32'd0;
        end else begin
            ev_done <= 1'b0; ev_sr_done <= 1'b0; ev_wdog <= 1'b0; ev_naninf <= 1'b0; ev_guard <= 1'b0;
            ev_wstale_run <= 1'b0; ev_start_busy <= 1'b0; kat_done <= 1'b0; kat_fail <= 1'b0; ck_go <= 1'b0;
            tile_done_p <= 1'b0; tile_fail_p <= 1'b0;
            fsw_pulse <= 1'b0; ck_done_q <= ck_done;

            // ---- counters ----------------------------------------------------------------------
            if (cmd_cnt_clr) begin
                infer_cnt <= 64'd0; busy_cyc <= 64'd0; total_cyc <= 64'd0; last_cycles <= 32'd0;
            end else begin
                total_cyc <= total_cyc + 64'd1;
                if (layer_busy) busy_cyc <= busy_cyc + 64'd1;
            end
            if (cmd_guard_clr) begin guard_hits <= 32'd0; naninf_cnt <= 32'd0; end
            else begin
                if (gh_pop != 4'd0) begin
                    guard_hits <= (guard_hits > 32'hFFFFFFFF - {28'd0, gh_pop}) ? 32'hFFFFFFFF
                                                                               : guard_hits + {28'd0, gh_pop};
                    ev_guard <= 1'b1;
                end
                if (ck_done && ck_nn != 16'd0) begin
                    ev_naninf <= 1'b1;
                    naninf_cnt <= (naninf_cnt > 32'hFFFFFFFF - {16'd0, ck_nn}) ? 32'hFFFFFFFF
                                                                               : naninf_cnt + {16'd0, ck_nn};
                end
            end
            if (cmd_cksum_clr || fsw_pulse) sr_pass_cksum <= 32'd0;
            if (sr_run_q || ev_sr_done) sr_cyc <= sr_cyc + 64'd1;
            if (ck_done) walk_pend <= 1'b0;
            // SR_PASS_CKSUM: CHECKSUM after the SR_N-th inference (first pass only)
            if (pass_pend && ck_done_q) begin sr_pass_cksum <= checksum; pass_pend <= 1'b0; end

            // the layer mux follows the target format once the old layer is held in reset
            if (fmt_applied != fmt_want && (ls[fmt_applied] != L_RUN)) begin   // old layer is in reset (state, not the async net)
                fmt_applied <= fmt_want; fsw_pulse <= 1'b1; zvalid <= 1'b0; last_cycles <= 32'd0;
                sr_pass_cksum <= 32'd0;
            end
            if (cmd_soft_rst && st != ST_SRST) begin
                st <= ST_SRST; srst_cnt <= 4'd8;
            end else begin
            case (st)
                ST_IDLE: begin
                    if (fmt_set) begin
                        fmt_want <= fmt_val;
                        if (fmt_val == fmt_applied) begin      // same format: state is still cleared (spec 12.4)
                            fsw_pulse <= 1'b1; zvalid <= 1'b0; last_cycles <= 32'd0; sr_pass_cksum <= 32'd0;
                        end
                    end else if (cmd_start | cmd_sr_start | kat_run | tile_launch) begin
                        if (!(cur_ready_q && clk_ok)) begin ev_start_busy <= 1'b1; tile_fail_p <= tile_launch; kat_fail <= kat_run; end
                        else begin
                            if ((cmd_start | cmd_sr_start | tile_launch) && wstale) ev_wstale_run <= 1'b1;
                            lane_en_applied <= lane_en;
                            st <= ST_LAUNCH; lat <= 32'd0; icnt <= 32'd0;
                            if (cmd_start) begin
                                kind <= K_SINGLE; xp <= xsel; stopping_q <= 1'b0;
                            end else if (cmd_sr_start) begin
                                kind <= K_SR; xp <= '0; n_q <= sr_n_eff; cnt_q <= sr_count;
                                stopping_q <= 1'b0; sr_run_q <= 1'b1; sr_done_cnt <= 32'd0;
                                sr_pass_cksum <= 32'd0; sr_cyc <= 64'd0; pass_pend <= 1'b0;
                            end else if (tile_launch) begin
                                kind <= K_TILE; stopping_q <= 1'b0;
                            end else begin
                                kind <= K_KAT; xp <= '0; n_q <= kat_n; cnt_q <= kat_count; stopping_q <= 1'b0;
                            end
                        end
                    end
                end
                ST_LAUNCH: begin
                    xptr_status <= 4'(xp);
                    if (!cur_ready_q) begin st <= ST_IDLE; ev_start_busy <= 1'b1; sr_run_q <= 1'b0; tile_fail_p <= (kind == K_TILE); kat_fail <= (kind == K_KAT); end   // layer went into reset
                    else begin st <= ST_WAIT; lat <= 32'd0; done_seen <= 1'b0; end
                end
                ST_WAIT: begin
                    lat <= lat + 32'd1;
                    if (wd_hit && !done_seen) begin ev_wdog <= 1'b1; done_seen <= 1'b1; end
                    if (cmd_sr_stop && sr_run_q) stopping_q <= 1'b1;
                    if (layer_done) begin
                        last_cycles <= lat;
                        infer_cnt   <= infer_cnt + 64'd1;
                        if (kind == K_TILE && !tile_last) st <= ST_POST;     // partial slice: no ZBUF, checksum or NaN update
                        else begin
                        zvalid      <= 1'b1;
                        ck_go <= 1'b1; ck_upd <= 1'b1; ck_kat <= (kind == K_KAT); walk_pend <= 1'b1;
                        if (kind == K_SINGLE || kind == K_TILE) st <= ST_POST;
                        else begin
                            icnt <= icnt_n;
                            if (kind == K_SR) begin
                                sr_done_cnt <= sr_done_cnt + 32'd1;
                                if (icnt_n == {24'd0, n_q}) pass_pend <= 1'b1;
                            end
                            last_inf <= stop_req || (cnt_q != 32'd0 && icnt_n == cnt_q);
                            st <= ST_GAP;
                        end
                        end
                    end
                end
                ST_GAP: begin
                    if (cmd_sr_stop && sr_run_q) stopping_q <= 1'b1;
                    if (last_inf || stop_req) st <= ST_POST;
                    else begin
                        xp <= (xp == XPW'(n_q - 8'd1)) ? '0 : xp + 1'b1;
                        st <= ST_LAUNCH; lat <= 32'd0;
                    end
                end
                ST_POST: begin
                    if (!walk_pend && !ck_go) begin
                        st <= ST_IDLE;
                        if (kind == K_SINGLE) ev_done <= 1'b1;
                        else if (kind == K_SR) begin
                            ev_sr_done <= 1'b1; sr_run_q <= 1'b0; stopping_q <= 1'b0;
                        end else if (kind == K_TILE) tile_done_p <= 1'b1;
                        else kat_done <= 1'b1;
                    end
                end
                ST_SRST: begin
                    // all state of spec 9.6 is cleared here; configuration lives in rondo_regs
                    stopping_q <= 1'b0; sr_run_q <= 1'b0; zvalid <= 1'b0; walk_pend <= 1'b0; pass_pend <= 1'b0;
                    infer_cnt <= 64'd0; busy_cyc <= 64'd0; total_cyc <= 64'd0; sr_cyc <= 64'd0;
                    sr_done_cnt <= 32'd0; sr_pass_cksum <= 32'd0; guard_hits <= 32'd0; naninf_cnt <= 32'd0;
                    last_cycles <= 32'd0; kind <= K_SINGLE;
                    if (srst_cnt == 4'd0) st <= ST_IDLE; else srst_cnt <= srst_cnt - 4'd1;
                end
                default: st <= ST_IDLE;
            endcase
            end
        end
    end
endmodule
