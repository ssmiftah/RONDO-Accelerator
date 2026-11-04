// cofr_coproc: the continuant coprocessor (M2).
//
// Computes the WIDTH continued-fraction outputs z (the ladder outputs) from the
// per-ladder partial denominators, using N_LANES iterative ladder_engine lanes.
// This is the differentiator core; the surrounding affine maps (W^(j), U, V) are
// commodity GEMM, integrated later (see docs/ACCELERATOR_DESIGN.md sec 5, M5).
//
// Scaling knobs: WIDTH (number of ladders L), N_LANES (parallel engines),
// DEPTH, and numeric format (EXP,SIG). WIDTH ladders are processed in
// NWAVES = ceil(WIDTH/N_LANES) lockstep waves -- every lane runs an identical
// fixed-latency engine, so all active lanes in a wave finish on the same cycle
// (no out-of-order tracking). Set N_LANES=WIDTH for full parallelism, or
// N_LANES=1 for a minimal-area single engine.
//
// Batch interface: drive a_all + pulse `start`; `done` pulses when z is valid.

`include "cofr_defs.vh"

module cofr_coproc #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter DEPTH   = `COFR_DEPTH,
    parameter WIDTH   = `COFR_WIDTH,
    parameter N_LANES = 1,
    parameter GEN     = 0,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS
) (
    input                              clock,
    input                              nReset,
    input                              start,
    output                             busy,
    output                             done,
    input  [WIDTH*DEPTH*(EXP+SIG)-1:0] a_all,   // a_all[j] = denominators of ladder j
    input  [WIDTH*DEPTH*(EXP+SIG)-1:0] b_all,   // b_all[j] = numerators of ladder j (GEN=1)
    output [WIDTH*(EXP+SIG)-1:0]       z         // z[j]     = f of ladder j
);
    localparam integer W      = EXP + SIG;
    localparam integer NWAVES = (WIDTH + N_LANES - 1) / N_LANES;
    localparam integer IDXW   = $clog2(WIDTH + N_LANES + 1);
    localparam integer WVW    = (NWAVES < 2) ? 1 : $clog2(NWAVES + 1);

    reg  [WVW-1:0]       wave;
    reg  [WIDTH*W-1:0]   z_reg;
    reg                  lanes_start, busy_r, done_r;
    wire [N_LANES-1:0]   lane_ovalid;
    wire [N_LANES*W-1:0] lane_f;
    wire [N_LANES-1:0]   active_mask;

    // per-lane completion latch (robust to per-lane divider latency skew)
    reg  [N_LANES-1:0]   lane_got;
    reg  [N_LANES*W-1:0] lane_fcap;

    assign busy = busy_r;
    assign done = done_r;
    assign z    = z_reg;

    // --- N_LANES iterative ladder engines ---
    genvar l;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            wire [IDXW-1:0] idx    = IDXW'(wave * N_LANES + l);
            wire            active = (idx < IDXW'(WIDTH));   // WIDTH fits IDXW (clog2(WIDTH+N_LANES+1))
            wire [IDXW-1:0] sidx   = active ? idx : {IDXW{1'b0}};  // bound the select
            wire [DEPTH*W-1:0] a_lane = a_all[sidx*DEPTH*W +: DEPTH*W];
            wire [DEPTH*W-1:0] b_lane = b_all[sidx*DEPTH*W +: DEPTH*W];

            assign active_mask[l] = active;

            ladder_engine #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .GEN(GEN), .EPS(EPS)) u_eng (
                .clock   (clock),
                .nReset  (nReset),
                .in_valid(lanes_start & active),
                .in_ready(),
                .a       (a_lane),
                .b       (b_lane),
                .out_valid(lane_ovalid[l]),
                .f       (lane_f[l*W +: W])
            );
        end
    endgenerate

    // --- wave controller ---
    localparam [1:0] C_IDLE = 2'd0, C_WAIT = 2'd1, C_DONE = 2'd2;
    reg [1:0] cstate;
    integer   li;

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            cstate      <= C_IDLE;
            wave        <= {WVW{1'b0}};
            lanes_start <= 1'b0;
            busy_r      <= 1'b0;
            done_r      <= 1'b0;
            lane_got    <= {N_LANES{1'b0}};
        end else begin
            lanes_start <= 1'b0;   // one-cycle pulse

            // Accumulate per-lane completions: latch each lane's f on its own
            // out_valid. (Assignments here may be overridden below on wave start.)
            for (li = 0; li < N_LANES; li = li + 1) begin
                if (lane_ovalid[li]) begin
                    lane_fcap[li*W +: W] <= lane_f[li*W +: W];
                    lane_got[li]         <= 1'b1;
                end
            end

            case (cstate)
                C_IDLE: begin
                    done_r <= 1'b0;
                    if (start) begin
                        wave        <= {WVW{1'b0}};
                        busy_r      <= 1'b1;
                        lane_got    <= {N_LANES{1'b0}};
                        lanes_start <= 1'b1;      // launch wave 0
                        cstate      <= C_WAIT;
                    end
                end
                C_WAIT: if ((lane_got & active_mask) == active_mask) begin
                    // all active lanes of this wave done -> commit their f into z
                    for (li = 0; li < N_LANES; li = li + 1) begin
                        if (li < WIDTH - wave * N_LANES)
                            z_reg[(wave*N_LANES + li)*W +: W] <= lane_fcap[li*W +: W];
                    end
                    if (wave == WVW'(NWAVES - 1)) begin
                        cstate <= C_DONE;
                    end else begin
                        wave        <= wave + WVW'(1);
                        lane_got    <= {N_LANES{1'b0}};
                        lanes_start <= 1'b1;        // launch next wave
                        cstate      <= C_WAIT;
                    end
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
