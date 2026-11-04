// ladder_scan_inter: NSLOT ladders interleaved through ONE pipelined FMA.
//
// Why this exists. fp_fma_pipe clocks 3.3x faster than the combinational FMA
// (31.9 -> 104.5 MHz, docs/TIMING_CORRECTION.md) but a sequential recurrence
// cannot use it: K[k] = a[k]*K[k+1] + K[k+2] must wait for its own previous
// result, so a 5-stage FMA would stall four cycles in five and the scan would get
// *slower* in cycles while gaining clock.
//
// The fix is to keep NSLOT independent ladders in flight and issue one FMA every
// cycle, round-robin. Slot s is re-issued exactly NSLOT cycles later, so as long
// as the result is back by then, the rotation IS the interlock -- no stalls, no
// forwarding, no hazard checks.
//
// The margin is one cycle wider than it first looks. A result issued at cycle t
// is written by the non-blocking assignment at the end of t+FMA_LAT, so it is
// only readable from t+FMA_LAT+1. Hence NSLOT must be at least FMA_LAT+1; at
// NSLOT == FMA_LAT the re-issue reads the value from two steps back and the
// answer is silently wrong (caught in test_scan_inter).
//
// All slots advance in lockstep on a shared step index k, which matches the
// existing wave model in cofr_coproc.
//
//   cycles = (DEPTH-1)*NSLOT + drain   ->  ~(DEPTH-1) cycles per ladder
//
// Unit numerators only, with one exception worth having. The general form needs
// b[k+1]*K[k+2], which puts a second pipelined multiply in the dependency chain;
// ladder_scan_scalar still covers GEN=1. But the case b = -1 is a sign flip
// rather than a multiply, costs nothing in the chain, and is not a special case
// of academic interest: K[k] = a[k]*K[k+1] - K[k+2] with a[k] = 2x is the
// Chebyshev recurrence. Seeded from a[DEPTH-1] = 2x it yields U_n, and from
// a[DEPTH-1] = x it yields T_n, both exactly. Those are the bases a Chebyshev
// KAN evaluates, so NUMER_NEG lets the same datapath serve a second
// interpretable architecture for one XOR on the sign bit.

`include "cofr_defs.vh"

module ladder_scan_inter #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter NSLOT = 8,          // must be >= FMA_LAT+1 (see header)
    parameter FMA_LAT = 5,        // fp_fma_pipe latency
    parameter GATE  = 1,          // stage data gating in fp_fma_pipe
    parameter NUMER_NEG = 0       // 0: K[k]=a[k]K[k+1]+K[k+2] (continued fraction)
                                  // 1: K[k]=a[k]K[k+1]-K[k+2] (Chebyshev)
) (
    input                              clock,
    input                              nReset,
    input                              in_valid,
    output                             in_ready,
    input  [NSLOT*DEPTH*(EXP+SIG)-1:0] a_all,
    output                             out_valid,
    output [NSLOT*(EXP+SIG)-1:0]       k0_all,
    output [NSLOT*(EXP+SIG)-1:0]       k1_all,
    // Streaming result port. Slots finish one per cycle across the final
    // rotation, which is exactly the rate an II=1 reciprocal consumes. Feeding
    // that directly costs nothing; batching instead would add NSLOT + reciprocal
    // latency per batch.
    output                             res_valid,
    output [(EXP+SIG)-1:0]             res_k0,
    output [(EXP+SIG)-1:0]             res_k1
);
    localparam integer W      = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam integer SW     = (NSLOT < 2) ? 1 : $clog2(NSLOT);
    localparam integer KW     = (DEPTH < 3) ? 1 : $clog2(DEPTH);
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2, S_DONE = 2'd3;

    // A slot must not be re-issued before its previous result is readable, which
    // is FMA_LAT+1 cycles after issue, not FMA_LAT.
    initial if (NSLOT < FMA_LAT + 1)
        $fatal(1, "ladder_scan_inter: NSLOT (%0d) must be >= FMA_LAT+1 (%0d)",
               NSLOT, FMA_LAT + 1);

    reg [1:0]              state;
    reg [SW-1:0]           rr;                 // round-robin slot pointer
    reg [KW-1:0]           k;                  // shared step index
    reg [NSLOT*DEPTH*W-1:0] a_reg;
    reg [W-1:0]            lo [0:NSLOT-1];
    reg [W-1:0]            hi [0:NSLOT-1];
    reg [$clog2(FMA_LAT+2)-1:0] drain;

    assign in_ready  = (state == S_IDLE);
    assign out_valid = (state == S_DONE);

    genvar g;
    generate
        for (g = 0; g < NSLOT; g = g + 1) begin : g_out
            assign k0_all[g*W +: W] = lo[g];
            assign k1_all[g*W +: W] = hi[g];
        end
    endgenerate

    wire [31:0] rr32 = 32'(rr);
    wire [31:0] k32  = 32'(k);
    wire issue = (state == S_RUN);
    wire [W-1:0] a_sel = a_reg[((rr32 * DEPTH) + k32) * W +: W];

    wire [W-1:0] mac_w;
    wire         mac_valid;
    // b = -1 by flipping the sign bit of the addend. Not on the critical path:
    // hi[rr] is already registered and this is one XOR, not an operation.
    wire [W-1:0] c_in = NUMER_NEG ? {~hi[rr][W-1], hi[rr][W-2:0]} : hi[rr];
    fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_fma (
        .clock(clock), .nReset(nReset), .in_valid(issue),
        .a(a_sel), .b(lo[rr]), .c(c_in),
        .out_valid(mac_valid), .p(mac_w)
    );

    // Which slot each in-flight FMA belongs to. The rotation guarantees the
    // result lands FMA_LAT cycles after issue, so this is a plain shift register.
    reg [SW-1:0] slot_pipe [0:FMA_LAT-1];
    reg          last_pipe [0:FMA_LAT-1];
    integer q;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) for (q = 0; q < FMA_LAT; q = q + 1) begin
            slot_pipe[q] <= '0; last_pipe[q] <= 1'b0;
        end else begin
            slot_pipe[0] <= rr;
            last_pipe[0] <= issue && (k == '0);      // final step for this slot
            for (q = 1; q < FMA_LAT; q = q + 1) begin
                slot_pipe[q] <= slot_pipe[q-1];
                last_pipe[q] <= last_pipe[q-1];
            end
        end
    end
    wire [SW-1:0] wb_slot = slot_pipe[FMA_LAT-1];

    // On the final step the new lo IS K0 and the outgoing lo becomes K1, both
    // available combinationally at writeback.
    assign res_valid = mac_valid & last_pipe[FMA_LAT-1];
    assign res_k0    = mac_w;
    assign res_k1    = lo[wb_slot];

    wire last_slot = (rr == SW'(NSLOT - 1));
    wire last_step = (k == '0);

    integer i;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; rr <= '0; k <= '0; drain <= '0; a_reg <= '0;
            for (i = 0; i < NSLOT; i = i + 1) begin lo[i] <= '0; hi[i] <= '0; end
        end else begin
            // writeback: hi takes the pre-update lo, which is still intact because
            // this slot has not been re-issued yet
            if (mac_valid) begin
                hi[wb_slot] <= lo[wb_slot];
                lo[wb_slot] <= mac_w;
            end

            case (state)
                S_IDLE: if (in_valid) begin
                    a_reg <= a_all;
                    for (i = 0; i < NSLOT; i = i + 1) begin
                        lo[i] <= a_all[((i * DEPTH) + (DEPTH-1)) * W +: W];  // K[DEPTH-1]
                        hi[i] <= F_ONE;                                     // K[DEPTH]
                    end
                    rr <= '0; drain <= '0;
                    if (DEPTH < 2) begin
                        state <= S_DONE;
                    end else begin
                        k     <= KW'(DEPTH - 2);
                        state <= S_RUN;
                    end
                end
                S_RUN: begin
                    if (last_slot) begin
                        rr <= '0;
                        if (last_step) state <= S_DRAIN;
                        else           k <= k - KW'(1);
                    end else begin
                        rr <= rr + SW'(1);
                    end
                end
                S_DRAIN: begin              // let the last issues retire
                    if (drain == FMA_LAT[$bits(drain)-1:0]) state <= S_DONE;
                    else drain <= drain + 1'b1;
                end
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
