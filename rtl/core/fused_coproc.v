// fused_coproc: a complete CoFrNet layer. x in, z out.
//
// This is the accelerator. Everything before it was a ladder engine: the earlier
// coprocessors take the coefficients `a` as an input, which skips the affine
// stage -- roughly 98% of the layer's arithmetic (2*d*p FLOP per ladder against
// the ladder's 12). This module computes the coefficients on chip from x and
// resident weights, then runs the continued fraction, so the whole layer runs
// from the input vector.
//
//   x --> affine_bank (per lane) --> ladder_engine_inter --> z
//
// Two consequences of generating coefficients on chip, and the second is the
// bigger one:
//
//   1. The wide `a_all` port disappears. In cofr_coproc_inter that port and its
//      crossbar were 63% of the area (docs/BUILD_QUEUE.md A4) while doing no
//      arithmetic. Here each lane owns a contiguous range of ladders, so the
//      z mapping is static wiring and there is no crossbar at all.
//   2. Weights become resident instead of streamed: L*d*p words in BRAM. That is
//      the trade fusion makes, and it is why fusion saves traffic -- x is shared
//      across the whole bank while W is not.
//
// Lane l owns ladders [l*NLAD, (l+1)*NLAD) and walks them NSLOT at a time. Each
// wave generates NSLOT ladders' coefficients into a buffer, then hands the batch
// to the lane. Affine and scan run sequentially per wave: the affine stage is
// several times longer than the scan at any reasonable NMAC, so overlapping them
// buys little, and the simple order is easier to trust. NMAC is the knob that
// balances the two.

`include "cofr_defs.vh"

module fused_coproc #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter DEPTH   = `COFR_DEPTH,
    parameter WIDTH   = 16,                  // ladders in the layer
    parameter PDIM    = 8,                   // input dimensionality
    parameter N_LANES = 2,
    parameter NSLOT   = 8,
    parameter NMAC    = 4,
    parameter TBITS   = 12,
    parameter FMA_LAT = 5,
    parameter GATE    = 1,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS,
    parameter SEED_FILE = "recip_seed_e8s24_t12.mem",
    // derived
    parameter NLAD    = WIDTH / N_LANES,     // ladders per lane (must divide)
    parameter CHUNKS  = (PDIM + NMAC - 1) / NMAC,
    parameter WAW     = ((NLAD*DEPTH*CHUNKS) < 2) ? 1 : $clog2(NLAD*DEPTH*CHUNKS),
    parameter BAW     = ((NLAD*DEPTH) < 2) ? 1 : $clog2(NLAD*DEPTH)
) (
    input                              clock,
    input                              nReset,
    // weight / bias load, per lane (lane index selects which bank)
    input                              w_we,
    input  [$clog2(N_LANES>1?N_LANES:2)-1:0] w_lane,
    input  [WAW-1:0]                   w_addr,
    input  [NMAC*(EXP+SIG)-1:0]        w_din,
    input                              b_we,
    input  [BAW-1:0]                   b_addr,
    input  [(EXP+SIG)-1:0]             b_din,
    // compute
    input                              start,
    output                             busy,
    output                             done,
    input  [PDIM*(EXP+SIG)-1:0]        x,
    output [WIDTH*(EXP+SIG)-1:0]       z
);
    localparam integer W      = EXP + SIG;
    localparam integer NWAVES = (NLAD + NSLOT - 1) / NSLOT;
    localparam integer LADW   = (NLAD  < 2) ? 1 : $clog2(NLAD);
    localparam integer SW     = (NSLOT < 2) ? 1 : $clog2(NSLOT);
    localparam integer RCW    = $clog2(NWAVES * NSLOT + 1);
    localparam integer ZAW    = ((NWAVES*NSLOT) < 2) ? 1 : $clog2(NWAVES*NSLOT);
    localparam integer WVW    = (NWAVES < 2) ? 1 : $clog2(NWAVES + 1);

    initial begin
        if (NLAD * N_LANES != WIDTH)
            $fatal(1, "fused_coproc: N_LANES (%0d) must divide WIDTH (%0d)", N_LANES, WIDTH);
        if (NLAD % NSLOT != 0)
            $fatal(1, "fused_coproc: NSLOT (%0d) must divide ladders-per-lane (%0d)",
                   NSLOT, NLAD);
    end

    reg  busy_r, done_r;
    assign busy = busy_r;
    assign done = done_r;

    wire [N_LANES-1:0] lane_fin;

    genvar l, s, wv;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            // ---- per-lane coefficient generation -------------------------
            reg  [SW-1:0]        slot;         // which slot we are filling
            reg  [LADW-1:0]      lad_i;        // ladder within this lane
            reg                  af_go;
            wire                 af_ready, af_done;
            wire [DEPTH*W-1:0]   af_a;

            affine_bank #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .PDIM(PDIM),
                          .NMAC(NMAC), .NLAD(NLAD)) u_aff (
                .clock(clock), .nReset(nReset),
                .w_we(w_we && (N_LANES == 1 || w_lane == l[$clog2(N_LANES>1?N_LANES:2)-1:0])),
                .w_addr(w_addr), .w_din(w_din),
                .b_we(b_we && (N_LANES == 1 || w_lane == l[$clog2(N_LANES>1?N_LANES:2)-1:0])),
                .b_addr(b_addr), .b_din(b_din),
                .in_valid(af_go), .in_ready(af_ready),
                .lad(lad_i), .x(x),
                .out_valid(af_done), .a(af_a)
            );

            // ---- batch buffer: NSLOT ladders of coefficients --------------
            reg [NSLOT*DEPTH*W-1:0] a_buf;

            // ---- the lane -------------------------------------------------
            reg                  ln_go;
            wire                 ln_ready, ln_ovalid;
            wire [W-1:0]         ln_f;
            ladder_engine_inter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .NSLOT(NSLOT),
                                  .TBITS(TBITS), .FMA_LAT(FMA_LAT), .EPS(EPS),
                                  .SEED_FILE(SEED_FILE), .GATE(GATE)) u_eng (
                .clock(clock), .nReset(nReset),
                .in_valid(ln_go), .in_ready(ln_ready),
                .a_all(a_buf),
                .out_valid(ln_ovalid), .f(ln_f)
            );

            // ---- result store: lane l owns a contiguous ladder range ------
            reg [RCW-1:0] rcnt;
            reg [W-1:0]   zl [0:NWAVES*NSLOT-1];

            // ---- control --------------------------------------------------
            localparam [2:0] L_IDLE = 3'd0, L_GEN = 3'd1, L_WAITA = 3'd2,
                             L_RUN  = 3'd3, L_WAITL = 3'd4, L_FIN = 3'd5;
            reg [2:0] lstate;
            reg [WVW-1:0] wave;

            assign lane_fin[l] = (lstate == L_FIN);

            always @(posedge clock or negedge nReset) begin
                if (!nReset) begin
                    lstate <= L_IDLE; slot <= '0; lad_i <= '0; wave <= '0;
                    af_go <= 1'b0; ln_go <= 1'b0; rcnt <= '0; a_buf <= '0;
                end else begin
                    af_go <= 1'b0;
                    ln_go <= 1'b0;

                    // collect results whenever the lane produces them
                    if (ln_ovalid && rcnt != RCW'(NWAVES*NSLOT)) begin
                        zl[rcnt[ZAW-1:0]] <= ln_f;
                        rcnt <= rcnt + RCW'(1);
                    end

                    case (lstate)
                        L_IDLE: if (start) begin
                            slot <= '0; lad_i <= '0; rcnt <= '0; wave <= '0;
                            lstate <= L_GEN;
                        end
                        L_GEN: if (af_ready) begin
                            af_go  <= 1'b1;
                            lstate <= L_WAITA;
                        end
                        L_WAITA: if (af_done) begin
                            a_buf[slot * DEPTH * W +: DEPTH*W] <= af_a;
                            lad_i <= lad_i + LADW'(1);     // always advance
                            if (slot == SW'(NSLOT - 1)) begin
                                slot   <= '0;
                                lstate <= L_RUN;
                            end else begin
                                slot   <= slot + SW'(1);
                                lstate <= L_GEN;
                            end
                        end
                        L_RUN: if (ln_ready) begin
                            ln_go  <= 1'b1;
                            lstate <= L_WAITL;
                        end
                        // Wait for exactly this wave's NSLOT results. Testing
                        // "rcnt is a multiple of NSLOT" instead would be true
                        // throughout the next wave's generation and skip ahead.
                        L_WAITL: if (rcnt == RCW'((32'(wave) + 32'd1) * NSLOT)) begin
                            if (wave == WVW'(NWAVES - 1)) begin
                                lstate <= L_FIN;
                            end else begin
                                wave   <= wave + WVW'(1);
                                lstate <= L_GEN;
                            end
                        end
                        L_FIN: if (!busy_r) lstate <= L_IDLE;
                        default: lstate <= L_IDLE;
                    endcase
                end
            end

            // ---- map this lane's store onto the flat z bus (static wiring) --
            for (wv = 0; wv < NWAVES; wv = wv + 1) begin : g_wave
                for (s = 0; s < NSLOT; s = s + 1) begin : g_slot
                    if ((l * NLAD + wv * NSLOT + s) < WIDTH) begin : g_map
                        assign z[(l * NLAD + wv * NSLOT + s) * W +: W] =
                            zl[wv * NSLOT + s];
                    end
                end
            end
        end
    endgenerate

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            busy_r <= 1'b0; done_r <= 1'b0;
        end else begin
            done_r <= 1'b0;
            if (start && !busy_r) busy_r <= 1'b1;
            else if (busy_r && (&lane_fin)) begin
                busy_r <= 1'b0;
                done_r <= 1'b1;
            end
        end
    end
endmodule
