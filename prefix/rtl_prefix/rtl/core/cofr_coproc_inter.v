// cofr_coproc_inter: the continuant coprocessor on the interleaved lane (A4).
//
// Same top-level contract as cofr_coproc -- drive a_all, pulse `start`, wait for
// `done`, read z -- but each lane is a ladder_engine_inter instead of the
// original ladder_engine. That changes the shape of a wave:
//
//   cofr_coproc:       1 ladder  per lane per wave, batch in / batch out
//   cofr_coproc_inter: NSLOT ladders per lane per wave, batch in / stream out
//
// So a wave now covers N_LANES*NSLOT ladders and NWAVES = ceil(WIDTH/(N_LANES*
// NSLOT)). The lane emits its NSLOT results one per cycle in slot order, so the
// collector is a per-lane counter rather than a completion mask: result number s
// belongs to ladder (wave*N_LANES + l)*NSLOT + s.
//
// Results are held in per-lane memories (zl) rather than one wide z register.
// Lane l owns a disjoint but non-contiguous set of ladder indices, and Verilog
// forbids two always blocks driving parts of the same reg; per-lane storage plus
// a constant-index generate remap avoids that without a variable-index write.
//
// A wave only launches when every lane has both delivered NSLOT results *and*
// deasserted busy (in_ready). The reciprocal's latency sits after the scan has
// already returned to idle, so those two conditions are not the same cycle, and
// starting on the first alone would drop the batch.
//
// Unit numerators only (GEN=0): ladder_scan_inter does not implement the
// generalized recurrence. b_all is kept in the port list for drop-in
// compatibility and is unused. Use cofr_coproc for GEN=1.

`include "cofr_defs.vh"

module cofr_coproc_inter #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter DEPTH   = `COFR_DEPTH,
    parameter WIDTH   = `COFR_WIDTH,
    parameter N_LANES = 1,
    parameter NSLOT   = 8,
    parameter TBITS   = 12,
    parameter FMA_LAT = 5,
    parameter GEN     = 0,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS,
    parameter SEED_FILE = "recip_seed_e8s24_t12.mem",
    parameter GATE = 1
) (
    input                              clock,
    input                              nReset,
    input                              start,
    output                             busy,
    output                             done,
    input  [WIDTH*DEPTH*(EXP+SIG)-1:0] a_all,   // a_all[j] = denominators of ladder j
    input  [WIDTH*DEPTH*(EXP+SIG)-1:0] b_all,   // unused (GEN=0 only)
    output [WIDTH*(EXP+SIG)-1:0]       z        // z[j] = f of ladder j
);
    localparam integer W       = EXP + SIG;
    localparam integer PERWAVE = N_LANES * NSLOT;
    localparam integer NWAVES  = (WIDTH + PERWAVE - 1) / PERWAVE;
    localparam integer WVW     = (NWAVES < 2) ? 1 : $clog2(NWAVES + 1);
    localparam integer IDXW    = $clog2(WIDTH + PERWAVE + 1);
    localparam integer RCW     = $clog2(NWAVES * NSLOT + 1);
    localparam integer ZDEPTH  = NWAVES * NSLOT;
    localparam integer ZAW     = (ZDEPTH < 2) ? 1 : $clog2(ZDEPTH);

    initial if (GEN != 0)
        $fatal(1, "cofr_coproc_inter: GEN=1 unsupported (use cofr_coproc)");

    wire _unused_b = |{1'b0, b_all[0]};

    reg  [WVW-1:0]     wave;
    reg                lanes_start, busy_r, done_r;
    wire [N_LANES-1:0] lane_ovalid, lane_iready, lane_done;
    wire [N_LANES*W-1:0] lane_f;

    assign busy = busy_r;
    assign done = done_r;

    genvar l, s, wv;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            // --- gather this lane's NSLOT ladders for the current wave ---
            wire [31:0] lbase32 = (32'(wave) * N_LANES + l) * NSLOT;
            wire [IDXW-1:0] lbase = lbase32[IDXW-1:0];
            wire [NSLOT*DEPTH*W-1:0] a_lane;
            for (s = 0; s < NSLOT; s = s + 1) begin : g_sel
                wire [IDXW-1:0] gi   = lbase + IDXW'(s);
                wire [IDXW-1:0] gsel = (gi < IDXW'(WIDTH)) ? gi : {IDXW{1'b0}};
                assign a_lane[s*DEPTH*W +: DEPTH*W] =
                    a_all[gsel*DEPTH*W +: DEPTH*W];
            end

            ladder_engine_inter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH),
                                  .NSLOT(NSLOT), .TBITS(TBITS),
                                  .FMA_LAT(FMA_LAT), .EPS(EPS),
                                  .SEED_FILE(SEED_FILE), .GATE(GATE)) u_eng (
                .clock    (clock),
                .nReset   (nReset),
                .in_valid (lanes_start),
                .in_ready (lane_iready[l]),
                .a_all    (a_lane),
                .out_valid(lane_ovalid[l]),
                .f        (lane_f[l*W +: W])
            );

            // --- collect ---
            // The counter runs across the whole batch, not per wave. A lane
            // returns results strictly in issue order, so result number r is
            // always ladder (r/NSLOT)*N_LANES*NSLOT + l*NSLOT + r%NSLOT -- and
            // r is exactly the address in this lane's store. Decoupling the
            // collector from the issue-side `wave` is what lets the next wave
            // launch while the previous one is still draining the reciprocal.
            reg [RCW-1:0] rcnt;
            reg [W-1:0]   zl [0:ZDEPTH-1];

            assign lane_done[l] = (rcnt == RCW'(ZDEPTH));

            always @(posedge clock or negedge nReset) begin
                if (!nReset) begin
                    rcnt <= {RCW{1'b0}};
                end else if (start && !busy_r) begin
                    rcnt <= {RCW{1'b0}};
                end else if (lane_ovalid[l] && !lane_done[l]) begin
                    zl[rcnt[ZAW-1:0]] <= lane_f[l*W +: W];
                    rcnt              <= rcnt + RCW'(1);
                end
            end

            // --- remap per-lane storage onto the flat z bus (constant indices) ---
            for (wv = 0; wv < NWAVES; wv = wv + 1) begin : g_wave
                for (s = 0; s < NSLOT; s = s + 1) begin : g_slot
                    if (((wv * N_LANES + l) * NSLOT + s) < WIDTH) begin : g_map
                        assign z[(((wv * N_LANES + l) * NSLOT + s)) * W +: W] =
                            zl[wv * NSLOT + s];
                    end
                end
            end
        end
    endgenerate

    // --- wave controller ---
    localparam [1:0] C_IDLE = 2'd0, C_WAIT = 2'd1, C_DONE = 2'd2;
    reg [1:0] cstate;

    // `wave` counts waves *issued*, so it addresses the next one to launch.
    // A lane's in_ready rises as soon as its scan is free, which is well before
    // its reciprocal has drained -- issuing on that rather than on completion is
    // what overlaps the waves.
    wire can_issue = (wave != WVW'(NWAVES)) & (&lane_iready) & ~lanes_start;
    wire all_done  = &lane_done;

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            cstate      <= C_IDLE;
            wave        <= {WVW{1'b0}};
            lanes_start <= 1'b0;
            busy_r      <= 1'b0;
            done_r      <= 1'b0;
        end else begin
            lanes_start <= 1'b0;   // one-cycle pulse
            if (lanes_start) wave <= wave + WVW'(1);
            case (cstate)
                C_IDLE: begin
                    done_r <= 1'b0;
                    if (start) begin
                        wave        <= {WVW{1'b0}};
                        busy_r      <= 1'b1;
                        lanes_start <= 1'b1;      // launch wave 0
                        cstate      <= C_WAIT;
                    end
                end
                C_WAIT: begin
                    if (can_issue) lanes_start <= 1'b1;
                    if (all_done)  cstate      <= C_DONE;
                end
                C_DONE: begin
                    busy_r <= 1'b0;
                    done_r <= 1'b1;
                    cstate <= C_IDLE;
                end
                default: cstate <= C_IDLE;
            endcase
        end
    end
endmodule
