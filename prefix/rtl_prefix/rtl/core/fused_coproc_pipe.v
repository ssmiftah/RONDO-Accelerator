// fused_coproc_pipe: the complete CoFrNet layer, on pipelined arithmetic.
//
// Same contract as fused_coproc -- x in, z out, weights resident -- but the
// coefficient generator is affine_bank_pipe rather than affine_bank. That single
// substitution is worth 13.8x of clock: 7.2 MHz -> 99.6 MHz (I-38).
//
// The composition also gets simpler. affine_bank_pipe produces a whole batch of
// NSLOT ladders' coefficients in one run, laid out chain-major as ch = j*DEPTH+k,
// which is exactly the a_all layout ladder_engine_inter expects. So the batch
// buffer and the per-ladder sequencing in fused_coproc both disappear: the
// generator's output wires straight into the lane.
//
//   x --> affine_bank_pipe (NPAR parallel FMAs) --> ladder_engine_inter --> z
//
// Lane l owns ladders [l*NLAD, (l+1)*NLAD) and walks them NSLOT at a time, so
// mapping results onto z is static wiring and there is no coefficient crossbar.

`include "cofr_defs.vh"

module fused_coproc_pipe #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    // Widen only the coefficient-stage accumulator; see affine_bank_pipe.
    // Declared after SIG so the default genuinely tracks it.
    parameter ACCSIG  = SIG,
    parameter DEPTH   = `COFR_DEPTH,
    parameter WIDTH   = 16,
    parameter PDIM    = 8,
    parameter N_LANES = 2,
    parameter NSLOT   = 8,
    parameter NPAR    = 8,
    parameter TBITS   = 12,
    parameter FMA_LAT = 5,
    parameter GATE    = 1,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS,
    parameter SEED_FILE = "recip_seed_e8s24_t12.mem",
    parameter TILE      = 0,      // C8: input tiling (spec 18.2)
    parameter DBG       = 0,      // C4: debug taps
    parameter LANE_MASK = 0,      // C6: lane-enable mask
    parameter EXT_MEM   = 0,      // C3: weight/bias memories outside the core
    parameter NR_ITERS  = 1,      // C7: Newton-Raphson iterations in the reciprocal
    // derived
    parameter NLAD    = WIDTH / N_LANES,
    parameter NCH     = NSLOT * DEPTH,
    parameter NGROUP  = NCH / NPAR,
    parameter NBATCHES = NLAD / NSLOT,
    parameter WAW     = ((NBATCHES*NGROUP*PDIM) < 2) ? 1 : $clog2(NBATCHES*NGROUP*PDIM),
    parameter BAW     = ((NBATCHES*NGROUP) < 2) ? 1 : $clog2(NBATCHES*NGROUP),
    parameter BSW     = (NBATCHES < 2) ? 1 : $clog2(NBATCHES),
    parameter LNW     = (N_LANES < 2) ? 1 : $clog2(N_LANES)
) (
    input                              clock,
    input                              nReset,
    input                              w_we,
    input  [LNW-1:0]                   w_lane,
    input  [WAW-1:0]                   w_addr,
    input  [NPAR*(EXP+SIG)-1:0]        w_din,
    input                              b_we,
    input  [BAW-1:0]                   b_addr,
    input  [NPAR*(EXP+SIG)-1:0]        b_din,
    input                              start,
    output                             busy,
    output                             done,
    input  [PDIM*(EXP+SIG)-1:0]        x,
    output [WIDTH*(EXP+SIG)-1:0]       z,
    // C2: per-lane pole-guard clamp pulses
    output [N_LANES-1:0]               guard_hit,
    // C6: lane enables (sampled at start; ignored when LANE_MASK=0)
    input  [N_LANES-1:0]               lane_en,
    // C3 external memory interface (EXT_MEM=1); lane l at [l*field +: field]
    output [N_LANES*WAW-1:0]           wm_addr,
    output [N_LANES*BAW-1:0]           bm_addr,
    output [N_LANES-1:0]               mem_act,
    input  [N_LANES*NPAR*(EXP+SIG)-1:0] wm_q,
    input  [N_LANES*NPAR*(EXP+SIG)-1:0] bm_q,
    // C4 debug taps (DBG=1; with DBG=0 the outputs are 0 and the inputs are ignored)
    input  [LNW-1:0]                   dbg_lane,
    input  [2:0]                       dbg_sig,
    input  [7:0]                       dbg_idx,
    output [31:0]                      dbg_data,
    input  [1:0]                       dbg_live_sel,
    output                             dbg_live_v,
    output [31:0]                      dbg_live_d,
    output [7:0]                       dbg_live_f,
    // C8 input tiling (TILE=1; with TILE=0 the inputs are ignored and done_final == done)
    input  [1:0]                       tile_seed,   // sampled with an accepted start: 0 bias, 1 keep acc, 2 restore from ps_q
    input                              tile_save,   // sampled with start: stream acc out on ps_* after the MAC phase
    input                              tile_last,   // sampled with start: 1 = run recurrence + reciprocal, 0 = partial slice
    input  [N_LANES*NPAR*(EXP+ACCSIG)-1:0] ps_q,
    output [N_LANES-1:0]               ps_we,
    output [N_LANES*BAW-1:0]           ps_waddr,
    output [N_LANES*NPAR*(EXP+ACCSIG)-1:0] ps_wdata,
    output reg                         done_final
);
    localparam integer W    = EXP + SIG;
    localparam integer RCW  = $clog2(NBATCHES * NSLOT + 1);
    localparam integer ZAW  = ((NBATCHES*NSLOT) < 2) ? 1 : $clog2(NBATCHES*NSLOT);
    localparam integer BSWI = (NBATCHES < 2) ? 1 : $clog2(NBATCHES + 1);
    localparam integer AWD  = EXP + ACCSIG;
    reg [31:0] dbg_data_r, dbg_live_d_r;
    reg        dbg_live_v_r;
    reg [7:0]  dbg_live_f_r;
    assign dbg_data = dbg_data_r; assign dbg_live_v = dbg_live_v_r;
    assign dbg_live_d = dbg_live_d_r; assign dbg_live_f = dbg_live_f_r;
    // per-lane tap buses collected for the selection logic
    wire [31:0]        tap_c  [0:N_LANES-1];
    wire               live_v [0:N_LANES-1];
    wire [31:0]        live_d [0:N_LANES-1];
    wire [7:0]         live_f [0:N_LANES-1];

    initial if (TILE != 0 && NBATCHES != 1)
        $fatal(1, "fused_coproc_pipe: TILE=1 requires NBATCHES = 1 (got %0d)", NBATCHES);

    initial if (NLAD * N_LANES != WIDTH)
        $fatal(1, "fused_coproc_pipe: N_LANES (%0d) must divide WIDTH (%0d)", N_LANES, WIDTH);

    reg  busy_r, done_r;
    assign busy = busy_r;
    assign done = done_r;
    wire [N_LANES-1:0] lane_fin;

    // C8: per-start tile controls, latched when a start is accepted (constants when TILE = 0)
    reg [1:0] tile_seed_q;
    reg       tile_save_q, tile_last_q;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin tile_seed_q <= 2'd0; tile_save_q <= 1'b0; tile_last_q <= 1'b1; end
        else if (TILE != 0 && start && !busy_r) begin
            tile_seed_q <= tile_seed; tile_save_q <= tile_save; tile_last_q <= tile_last;
        end
    end

    // C6: lane mask. lane_msk is the constant all-ones unless LANE_MASK=1, where it is
    // latched from lane_en when a start is accepted.
    wire [N_LANES-1:0] lane_msk;
    generate
        if (LANE_MASK) begin : g_lm
            reg [N_LANES-1:0] lane_en_q;
            always @(posedge clock or negedge nReset) begin
                if (!nReset) lane_en_q <= {N_LANES{1'b1}};
                else if (start && !busy_r) lane_en_q <= lane_en;
            end
            assign lane_msk = lane_en_q;
        end else begin : g_nolm
            assign lane_msk = {N_LANES{1'b1}};
        end
    endgenerate
    localparam [W-1:0] QNAN = {1'b0, {EXP{1'b1}}, 1'b1, {(SIG-2){1'b0}}};

    // ---- registered load fan-out -------------------------------------------
    // The weight load port drives every lane's weight and bias memory. On a
    // placed design that is one register reaching N_LANES block RAMs spread
    // across the die, and it was the critical path of every board build so far:
    // 9.19 ns with ZERO logic levels and 93% route, while the compute datapath
    // had 0.92 ns of slack. The clock was being set by a wire on a path that
    // runs once at reset.
    //
    // One register stage here breaks that wire in two and lets the placer put
    // the halves near their endpoints. It costs exactly one extra cycle of load
    // latency out of the ~2300 the load already takes, and nothing waits on the
    // load: the FSM walks addresses unconditionally and the first inference is
    // gated by `start`, not by write completion.
    reg             w_we_q, b_we_q;
    reg [LNW-1:0]   w_lane_q;
    reg [WAW-1:0]   w_addr_q;
    reg [BAW-1:0]   b_addr_q;
    reg [NPAR*W-1:0] w_din_q, b_din_q;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            w_we_q <= 1'b0;
            b_we_q <= 1'b0;
        end else begin
            w_we_q   <= w_we;    b_we_q   <= b_we;
            w_lane_q <= w_lane;  w_addr_q <= w_addr;
            b_addr_q <= b_addr;  w_din_q  <= w_din;
            b_din_q  <= b_din;
        end
    end

    genvar l, s, wv;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            wire lane_sel = (N_LANES == 1) || (w_lane_q == l[LNW-1:0]);

            reg  [BSWI-1:0] bat;              // which batch of NSLOT ladders
            reg             af_go, ln_go;
            wire            af_ready, af_done, ln_ready, ln_ovalid;
            wire [NCH*W-1:0] af_a;
            wire [W-1:0]    ln_f;
            wire            ln_ghit;
            wire [NSLOT*W-1:0]  e_k0, e_k1;
            wire                e_rv;
            wire [W-1:0]        e_rk0, e_rk1;
            wire [NCH*AWD-1:0]  af_acc;
            wire                af_m0v;
            wire [AWD-1:0]      af_m0p;
            wire [1:0]          af_st;

            affine_bank_pipe #(.EXP(EXP), .SIG(SIG), .ACCSIG(ACCSIG),
                               .DEPTH(DEPTH), .PDIM(PDIM),
                               .NBATCH(NSLOT), .NLAD(NLAD), .NPAR(NPAR),
                               .FMA_LAT(FMA_LAT), .EXT_MEM(EXT_MEM), .TILE(TILE)) u_aff (
                .clock(clock), .nReset(nReset),
                .w_we(w_we_q && lane_sel), .w_addr(w_addr_q), .w_din(w_din_q),
                .b_we(b_we_q && lane_sel), .b_addr(b_addr_q), .b_din(b_din_q),
                .in_valid(af_go), .in_ready(af_ready),
                .bsel(bat[BSW-1:0]), .x(x),
                .out_valid(af_done), .a(af_a),
                .wm_addr(wm_addr[l*WAW +: WAW]), .bm_addr(bm_addr[l*BAW +: BAW]),
                .mem_act(mem_act[l]),
                .acc_all(af_acc), .mac0_v(af_m0v), .mac0_p(af_m0p), .state_o(af_st),
                .seed_mode(tile_seed_q), .save_en(tile_save_q), .ps_q(ps_q[l*NPAR*AWD +: NPAR*AWD]),
                .ps_we(ps_we[l]), .ps_waddr(ps_waddr[l*BAW +: BAW]), .ps_wdata(ps_wdata[l*NPAR*AWD +: NPAR*AWD]),
                .wm_q(wm_q[l*NPAR*W +: NPAR*W]), .bm_q(bm_q[l*NPAR*W +: NPAR*W])
            );

            // The generator's chain order (ch = j*DEPTH + k) is already the
            // lane's a_all order, so this is wiring, not a buffer.
            reg [NCH*W-1:0] a_hold;

            ladder_engine_inter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .NSLOT(NSLOT),
                                  .TBITS(TBITS), .FMA_LAT(FMA_LAT), .EPS(EPS),
                                  .SEED_FILE(SEED_FILE), .GATE(GATE),
                                  .NR_ITERS(NR_ITERS)) u_eng (
                .clock(clock), .nReset(nReset),
                .in_valid(ln_go), .in_ready(ln_ready),
                .a_all(a_hold),
                .out_valid(ln_ovalid), .f(ln_f), .guard_hit(ln_ghit),
                .k0_all(e_k0), .k1_all(e_k1), .res_valid(e_rv), .res_k0(e_rk0), .res_k1(e_rk1)
            );
            assign guard_hit[l] = ln_ghit;

            reg [RCW-1:0] rcnt;
            reg [W-1:0]   zl [0:NBATCHES*NSLOT-1];

            localparam [2:0] L_IDLE = 3'd0, L_GEN = 3'd1, L_WAITA = 3'd2,
                             L_RUN  = 3'd3, L_WAITL = 3'd4, L_FIN = 3'd5;
            reg [2:0] lstate;
            integer qi;
            assign lane_fin[l] = (lstate == L_FIN);

            always @(posedge clock or negedge nReset) begin
                if (!nReset) begin
                    lstate <= L_IDLE; bat <= '0; af_go <= 1'b0; ln_go <= 1'b0;
                    rcnt <= '0; a_hold <= '0;
                end else begin
                    af_go <= 1'b0;
                    ln_go <= 1'b0;
                    if (ln_ovalid && rcnt != RCW'(NBATCHES*NSLOT)) begin
                        zl[rcnt[ZAW-1:0]] <= ln_f;
                        rcnt <= rcnt + RCW'(1);
                    end
                    case (lstate)
                        L_IDLE: if (start) begin
                            if (!LANE_MASK || lane_en[l]) begin
                                bat <= '0; rcnt <= '0; lstate <= L_GEN;
                            end else begin
                                // disabled lane: outputs read the canonical quiet NaN
                                for (qi = 0; qi < NBATCHES*NSLOT; qi = qi + 1) zl[qi] <= QNAN;
                            end
                        end
                        L_GEN: if (af_ready) begin
                            af_go  <= 1'b1;
                            lstate <= L_WAITA;
                        end
                        L_WAITA: if (af_done) begin
                            if (TILE == 0 || tile_last_q) begin
                                a_hold <= af_a;
                                lstate <= L_RUN;
                            end else lstate <= L_FIN;          // C8 partial slice: no recurrence, zl untouched
                        end
                        L_RUN: if (ln_ready) begin
                            ln_go  <= 1'b1;
                            lstate <= L_WAITL;
                        end
                        L_WAITL: if (rcnt == RCW'((32'(bat) + 32'd1) * NSLOT)) begin
                            if (32'(bat) == NBATCHES - 1) lstate <= L_FIN;
                            else begin
                                bat    <= bat + 1'b1;
                                lstate <= L_GEN;
                            end
                        end
                        // C1: a start sampled while the lane is still in L_FIN (start in the
                        // done cycle) is taken, not lost (spec CHIP_INTERFACE_SPEC 2.2).
                        L_FIN: if (start && !busy_r && (!LANE_MASK || lane_en[l])) begin
                            bat <= '0; rcnt <= '0; lstate <= L_GEN;
                        end else if (!busy_r) lstate <= L_IDLE;
                        default: lstate <= L_IDLE;
                    endcase
                end
            end


            // ---- C4 debug taps -------------------------------------------------
            if (DBG) begin : g_dbg
                reg [31:0] tc;
                wire [31:0] ix = {24'd0, dbg_idx};
                always @* begin
                    tc = 32'd0;
                    case (dbg_sig)
                        3'd0: if (ix < NCH)  tc = 32'(a_hold[ix * W +: W]);
                        3'd1: if (ix < NCH)  tc = 32'(af_acc[ix * AWD +: AWD]);
                        3'd2: if (ix < NSLOT) tc = 32'(e_k0[ix * W +: W]);
                        3'd3: if (ix < NSLOT) tc = 32'(e_k1[ix * W +: W]);
                        3'd4: if (ix < NBATCHES*NSLOT) tc = 32'(zl[ix[ZAW-1:0]]);
                        3'd5: tc = 32'({rcnt, bat, lstate});
                        default: tc = 32'd0;
                    endcase
                end
                assign tap_c[l] = tc;
                reg        lv;
                reg [31:0] ld;
                always @* begin
                    case (dbg_live_sel)
                        2'd0: begin lv = e_rv;      ld = 32'(e_rk0); end
                        2'd1: begin lv = ln_ovalid; ld = 32'(ln_f); end
                        2'd2: begin lv = e_rv;      ld = 32'(e_rk1); end
                        default: begin lv = af_m0v; ld = 32'(af_m0p); end
                    endcase
                end
                assign live_v[l] = lv;
                assign live_d[l] = ld;
                assign live_f[l] = {ln_ghit, (ln_f[W-2 -: EXP] == {EXP{1'b1}}) & ln_ovalid, lstate, af_st, ln_ovalid};
            end else begin : g_nodbg
                assign tap_c[l]  = 32'd0;
                assign live_v[l] = 1'b0;
                assign live_d[l] = 32'd0;
                assign live_f[l] = 8'd0;
            end

            for (wv = 0; wv < NBATCHES; wv = wv + 1) begin : g_wave
                for (s = 0; s < NSLOT; s = s + 1) begin : g_slot
                    if ((l * NLAD + wv * NSLOT + s) < WIDTH) begin : g_map
                        assign z[(l * NLAD + wv * NSLOT + s) * W +: W] =
                            zl[wv * NSLOT + s];
                    end
                end
            end
        end
    endgenerate


    // ---- C4: lane selection, two register stages (valid 2 cycles after the selects) ----
    generate
        if (DBG) begin : g_dbgsel
            reg [31:0] tap_q [0:N_LANES-1];
            reg        lv_q  [0:N_LANES-1];
            reg [31:0] ld_q  [0:N_LANES-1];
            reg [7:0]  lf_q  [0:N_LANES-1];
            integer di;
            always @(posedge clock or negedge nReset) begin
                if (!nReset) begin
                    for (di = 0; di < N_LANES; di = di + 1) begin
                        tap_q[di] <= 32'd0; lv_q[di] <= 1'b0; ld_q[di] <= 32'd0; lf_q[di] <= 8'd0;
                    end
                    dbg_data_r <= 32'd0; dbg_live_v_r <= 1'b0; dbg_live_d_r <= 32'd0; dbg_live_f_r <= 8'd0;
                end else begin
                    for (di = 0; di < N_LANES; di = di + 1) begin
                        tap_q[di] <= tap_c[di]; lv_q[di] <= live_v[di];
                        ld_q[di] <= live_d[di]; lf_q[di] <= live_f[di];
                    end
                    dbg_data_r   <= tap_q[dbg_lane];
                    dbg_live_v_r <= lv_q[dbg_lane];
                    dbg_live_d_r <= ld_q[dbg_lane];
                    dbg_live_f_r <= lf_q[dbg_lane];
                end
            end
        end else begin : g_nodbgsel
            always @(posedge clock or negedge nReset) begin
                if (!nReset) begin
                    dbg_data_r <= 32'd0; dbg_live_v_r <= 1'b0; dbg_live_d_r <= 32'd0; dbg_live_f_r <= 8'd0;
                end
            end
        end
    endgenerate

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin busy_r <= 1'b0; done_r <= 1'b0; done_final <= 1'b0; end
        else begin
            done_r <= 1'b0; done_final <= 1'b0;
            if (start && !busy_r) busy_r <= 1'b1;
            else if (busy_r && (&(lane_fin | ~lane_msk))) begin
                busy_r <= 1'b0;
                done_r <= 1'b1;
                done_final <= (TILE == 0) ? 1'b1 : tile_last_q;
            end
        end
    end
endmodule
