// train_coproc: WIDTH-batched forward+backward (I-12).
//
// Like cofr_coproc, but each lane is a train_ladder, so the batch emits both the
// ladder outputs z (all f) AND the per-ladder gradients grad_a. Same controller:
// N_LANES lanes process WIDTH ladders in waves, with per-lane result latching
// (train_ladder latency is data-dependent via the divider, so lanes are not
// lockstep). Batch interface: drive a_all/grad_out_all + pulse start; done pulses
// when z and grad_a_all are valid. Unit numerators; parameterized.

`include "cofr_defs.vh"

module train_coproc #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter DEPTH   = `COFR_DEPTH,
    parameter WIDTH   = `COFR_WIDTH,
    parameter N_LANES = 1,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS
) (
    input                              clock,
    input                              nReset,
    input                              start,
    output                             busy,
    output                             done,
    input  [WIDTH*DEPTH*(EXP+SIG)-1:0] a_all,        // a_all[j] = denominators of ladder j
    input  [WIDTH*(EXP+SIG)-1:0]       grad_out_all, // grad_out_all[j] = upstream grad of ladder j
    output [WIDTH*(EXP+SIG)-1:0]       z,            // z[j] = f of ladder j
    output [WIDTH*DEPTH*(EXP+SIG)-1:0] grad_a_all    // grad_a_all[j] = grad_a of ladder j
);
    localparam integer W      = EXP + SIG;
    localparam integer NWAVES = (WIDTH + N_LANES - 1) / N_LANES;
    localparam integer IDXW   = $clog2(WIDTH + N_LANES + 1);
    localparam integer WVW    = (NWAVES < 2) ? 1 : $clog2(NWAVES + 1);

    reg  [WVW-1:0]              wave;
    reg  [WIDTH*W-1:0]         z_reg;
    reg  [WIDTH*DEPTH*W-1:0]   ga_reg;
    reg                        lanes_start, busy_r, done_r;
    wire [N_LANES-1:0]         lane_ovalid;
    wire [N_LANES*W-1:0]       lane_f;
    wire [N_LANES*DEPTH*W-1:0] lane_ga;
    wire [N_LANES-1:0]         active_mask;

    reg  [N_LANES-1:0]         lane_got;
    reg  [N_LANES*W-1:0]       lane_fcap;
    reg  [N_LANES*DEPTH*W-1:0] lane_gcap;

    assign busy = busy_r;
    assign done = done_r;
    assign z    = z_reg;
    assign grad_a_all = ga_reg;

    genvar l;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            wire [IDXW-1:0] idx    = IDXW'(wave * N_LANES + l);
            wire            active = (idx < IDXW'(WIDTH));   // WIDTH fits IDXW (clog2(WIDTH+N_LANES+1))
            wire [IDXW-1:0] sidx   = active ? idx : {IDXW{1'b0}};
            wire [DEPTH*W-1:0] a_lane   = a_all[sidx*DEPTH*W +: DEPTH*W];
            wire [W-1:0]       go_lane  = grad_out_all[sidx*W +: W];
            assign active_mask[l] = active;

            train_ladder #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .EPS(EPS)) u_eng (
                .clock(clock), .nReset(nReset),
                .in_valid(lanes_start & active), .in_ready(),
                .a(a_lane), .grad_out(go_lane),
                .out_valid(lane_ovalid[l]),
                .f(lane_f[l*W +: W]),
                .grad_a(lane_ga[l*DEPTH*W +: DEPTH*W])
            );
        end
    endgenerate

    localparam [1:0] C_IDLE = 2'd0, C_WAIT = 2'd1, C_DONE = 2'd2;
    reg [1:0] cstate;
    integer   li;

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            cstate <= C_IDLE; wave <= {WVW{1'b0}};
            lanes_start <= 1'b0; busy_r <= 1'b0; done_r <= 1'b0;
            lane_got <= {N_LANES{1'b0}};
        end else begin
            lanes_start <= 1'b0;
            // per-lane completion latch
            for (li = 0; li < N_LANES; li = li + 1) begin
                if (lane_ovalid[li]) begin
                    lane_fcap[li*W +: W]           <= lane_f[li*W +: W];
                    lane_gcap[li*DEPTH*W +: DEPTH*W] <= lane_ga[li*DEPTH*W +: DEPTH*W];
                    lane_got[li]                   <= 1'b1;
                end
            end
            case (cstate)
                C_IDLE: begin
                    done_r <= 1'b0;
                    if (start) begin
                        wave <= {WVW{1'b0}}; busy_r <= 1'b1;
                        lane_got <= {N_LANES{1'b0}};
                        lanes_start <= 1'b1; cstate <= C_WAIT;
                    end
                end
                C_WAIT: if ((lane_got & active_mask) == active_mask) begin
                    for (li = 0; li < N_LANES; li = li + 1) begin
                        if (li < WIDTH - wave * N_LANES) begin
                            z_reg[(wave*N_LANES + li)*W +: W]           <= lane_fcap[li*W +: W];
                            ga_reg[(wave*N_LANES + li)*DEPTH*W +: DEPTH*W] <= lane_gcap[li*DEPTH*W +: DEPTH*W];
                        end
                    end
                    if (wave == WVW'(NWAVES - 1)) begin
                        cstate <= C_DONE;
                    end else begin
                        wave <= wave + WVW'(1); lane_got <= {N_LANES{1'b0}};
                        lanes_start <= 1'b1; cstate <= C_WAIT;
                    end
                end
                C_DONE: begin busy_r <= 1'b0; done_r <= 1'b1; cstate <= C_IDLE; end
                default: cstate <= C_IDLE;
            endcase
        end
    end
endmodule
