// grad_a_inter: the closed-form gradient for NSLOT ladders, streamed through
// three pipelined units at one result per cycle.
//
//   grad_a[s][k] = grad_out[s] * s_k * (K[s][k+1] * rK0[s])^2 ,  s_k = -1 even k
//
// Why this exists. grad_a_unit.v computes the same thing combinationally, with
// DEPTH parallel lanes of three chained fp_mul. That is a long combinational
// chain of three multiplies, and it is one of the two reasons the backward path
// clocks at 18-32 MHz while the forward path runs above 100.
//
// The fix is NOT the interleaving construction, and it is worth being precise
// about why. Interleaving exists to give a pipelined unit independent work when
// a RECURRENCE would otherwise stall it. There is no recurrence here: every
// (slot, k) is independent of every other, and even the three multiplies within
// one are a plain feed-forward chain. So this needs only pipelining, arranged so
// the chain's stages are separate units rather than one combinational cone:
//
//   A: ratio  = K[s][k+1] * rK0[s]
//   B: ratio2 = ratio * ratio
//   C: g      = grad_out[s] * ratio2
//
// Each stage is an fp_fma_pipe with c tied to +0. That is not an approximation:
// fp_mul is itself mulAddRecFN(x, y, +0) on the same HardFloat primitive
// fp_fma_pipe uses, so a*b+0 here is bit-identical to fp_mul's a*b, including
// the signed-zero behaviour, and nothing new needed verifying.
//
// Issue is one (slot, k) per cycle, so NSLOT*DEPTH results emerge at II=1 after
// 3*FMA_LAT of fill. Against grad_a_unit's DEPTH*3 = 21 combinational multipliers
// this uses 3, and it is the throughput the scan in kscan_inter feeds.
//
// The (slot, k) pair travels with the data rather than being recomputed from a
// flat counter: recovering k = idx % DEPTH would put a divide by 7 in the
// writeback path for no reason.

`include "cofr_defs.vh"

module grad_a_inter #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter NSLOT = 8,
    parameter FMA_LAT = 5,
    parameter GATE  = 1
) (
    input                                  clock,
    input                                  nReset,
    input                                  in_valid,     // start a batch
    output                                 in_ready,
    input  [NSLOT*(DEPTH+1)*(EXP+SIG)-1:0] Kv_all,       // from kscan_inter
    input  [NSLOT*(EXP+SIG)-1:0]           rK0_all,      // 1/clamp_signed(K0)
    input  [NSLOT*(EXP+SIG)-1:0]           gout_all,     // upstream gradient
    output                                 out_valid,
    output [NSLOT*DEPTH*(EXP+SIG)-1:0]     grad_a_all
);
    localparam integer W   = EXP + SIG;
    localparam integer SW  = (NSLOT < 2) ? 1 : $clog2(NSLOT);
    localparam integer KW  = (DEPTH < 2) ? 1 : $clog2(DEPTH);
    localparam integer NOP = NSLOT * DEPTH;
    localparam integer CW  = (NOP < 2) ? 1 : $clog2(NOP);
    localparam [W-1:0] F_ZERO = {W{1'b0}};
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2, S_DONE = 2'd3;

    reg [1:0]      state;
    reg [SW-1:0]   s_i;                 // slot being issued
    reg [KW-1:0]   k_i;                 // step being issued
    reg [CW:0]     issued, retired;
    reg [W-1:0]    Kreg   [0:NSLOT*(DEPTH+1)-1];
    reg [W-1:0]    rK0reg [0:NSLOT-1];
    reg [W-1:0]    goutreg[0:NSLOT-1];
    reg [W-1:0]    gres   [0:NOP-1];

    assign in_ready  = (state == S_IDLE);
    assign out_valid = (state == S_DONE);

    genvar g;
    generate
        for (g = 0; g < NOP; g = g + 1) begin : g_out
            assign grad_a_all[g*W +: W] = gres[g];
        end
    endgenerate

    wire issue = (state == S_RUN);
    wire [31:0] kidx = (32'(s_i) * (DEPTH + 1)) + 32'(k_i) + 32'd1;   // K[s][k+1]

    // ---- stage A: ratio = K[k+1] * rK0 ------------------------------------
    wire [W-1:0] ratio;  wire vA;
    fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_a (
        .clock(clock), .nReset(nReset), .in_valid(issue),
        .a(Kreg[kidx[$clog2(NSLOT*(DEPTH+1))-1:0]]), .b(rK0reg[s_i]), .c(F_ZERO),
        .out_valid(vA), .p(ratio));

    // The (slot, k) pair rides alongside, one shift register per stage.
    reg [SW-1:0] sA [0:FMA_LAT-1];  reg [KW-1:0] kA [0:FMA_LAT-1];
    reg [SW-1:0] sB [0:FMA_LAT-1];  reg [KW-1:0] kB [0:FMA_LAT-1];
    reg [SW-1:0] sC [0:FMA_LAT-1];  reg [KW-1:0] kC [0:FMA_LAT-1];

    // ---- stage B: ratio2 = ratio * ratio ----------------------------------
    wire [W-1:0] ratio2; wire vB;
    fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_b (
        .clock(clock), .nReset(nReset), .in_valid(vA),
        .a(ratio), .b(ratio), .c(F_ZERO),
        .out_valid(vB), .p(ratio2));

    // ---- stage C: g = grad_out * ratio2 -----------------------------------
    wire [W-1:0] gval;  wire vC;
    fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_c (
        .clock(clock), .nReset(nReset), .in_valid(vB),
        .a(goutreg[sB[FMA_LAT-1]]), .b(ratio2), .c(F_ZERO),
        .out_valid(vC), .p(gval));

    wire [SW-1:0] wb_s = sC[FMA_LAT-1];
    wire [KW-1:0] wb_k = kC[FMA_LAT-1];
    wire [31:0]   wb_i = (32'(wb_s) * DEPTH) + 32'(wb_k);
    // s_k = -1 for even k, +1 for odd: a sign-bit flip, not a multiply.
    wire [W-1:0]  wb_v = (wb_k[0] == 1'b0) ? {~gval[W-1], gval[W-2:0]} : gval;

    integer q, i;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; s_i <= '0; k_i <= '0; issued <= '0; retired <= '0;
            for (q = 0; q < FMA_LAT; q = q + 1) begin
                sA[q] <= '0; kA[q] <= '0; sB[q] <= '0; kB[q] <= '0;
                sC[q] <= '0; kC[q] <= '0;
            end
            for (i = 0; i < NOP; i = i + 1) gres[i] <= '0;
        end else begin
            sA[0] <= s_i;               kA[0] <= k_i;
            sB[0] <= sA[FMA_LAT-1];     kB[0] <= kA[FMA_LAT-1];
            sC[0] <= sB[FMA_LAT-1];     kC[0] <= kB[FMA_LAT-1];
            for (q = 1; q < FMA_LAT; q = q + 1) begin
                sA[q] <= sA[q-1]; kA[q] <= kA[q-1];
                sB[q] <= sB[q-1]; kB[q] <= kB[q-1];
                sC[q] <= sC[q-1]; kC[q] <= kC[q-1];
            end

            if (vC) begin
                gres[wb_i[CW-1:0]] <= wb_v;
                retired <= retired + 1'b1;
            end

            case (state)
                S_IDLE: if (in_valid) begin
                    for (i = 0; i < NSLOT*(DEPTH+1); i = i + 1)
                        Kreg[i] <= Kv_all[i*W +: W];
                    for (i = 0; i < NSLOT; i = i + 1) begin
                        rK0reg[i]  <= rK0_all[i*W +: W];
                        goutreg[i] <= gout_all[i*W +: W];
                    end
                    s_i <= '0; k_i <= '0; issued <= '0; retired <= '0;
                    state <= S_RUN;
                end
                S_RUN: begin
                    issued <= issued + 1'b1;
                    if (k_i == KW'(DEPTH-1)) begin
                        k_i <= '0;
                        s_i <= s_i + SW'(1);
                    end else k_i <= k_i + KW'(1);
                    if (issued == CW'(NOP-1)) state <= S_DRAIN;
                end
                // Drain on the retire count rather than a fixed delay: the three
                // stages are chained, so the fill is 3*FMA_LAT and hard-coding it
                // would silently break if a stage's latency ever changed.
                S_DRAIN: if (retired == NOP[CW:0]) state <= S_DONE;
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
