// kscan_inter: NSLOT ladders interleaved through ONE pipelined FMA, retaining
// the FULL continuant array K[0..DEPTH] for every slot.
//
// Why this exists. The backward pass needs every continuant, not just the final
// pair: grad_a[k] = grad_out * s_k * (K[k+1]/clamp(K0))^2 reads K[1..DEPTH].
// kscan.v produces that array but evaluates the recurrence on a COMBINATIONAL
// fp_fma, one step per cycle, which caps the backward path at roughly 18-32 MHz
// while the forward path runs at 100. The paper's own remedy is to apply the
// interleaving construction a third time, and this module is that.
//
// It is ladder_scan_inter with one addition. That module keeps a rolling
// (lo, hi) = (K[k], K[k+1]) pair per slot, which is all the forward output
// needs; here each writeback is also recorded into a per-slot array, so the
// whole of K survives the scan at no arithmetic cost. The recurrence, the
// rotation and the NSLOT >= FMA_LAT+1 rule are unchanged, because they are
// properties of the dependence, not of what is kept.
//
// Storage is NSLOT*(DEPTH+1) words against the forward path's 2*NSLOT. At
// NSLOT=8, DEPTH=7, bf16 that is 1024 bits, which is why keeping everything is
// preferable to recomputing it during the backward sweep.
//
//   cycles = (DEPTH-1)*NSLOT + drain   ->  ~(DEPTH-1) cycles per ladder
//
// Unit numerators only, matching ladder_scan_inter. GEN=1 needs b[k+1]*K[k+2]
// ahead of the FMA, which puts a second pipelined multiply in the dependence
// chain; kscan.v still covers that case.

`include "cofr_defs.vh"

module kscan_inter #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter NSLOT = 8,          // must be >= FMA_LAT+1
    parameter FMA_LAT = 5,        // fp_fma_pipe latency
    parameter GATE  = 1,
    parameter NUMER_NEG = 0   // 1: K[k]=a[k]K[k+1]-K[k+2], the Chebyshev
                              // recurrence. One XOR on the addend; see
                              // ladder_scan_inter for why b=-1 is free
                              // and general b is not.
) (
    input                                  clock,
    input                                  nReset,
    input                                  in_valid,
    output                                 in_ready,
    input  [NSLOT*DEPTH*(EXP+SIG)-1:0]     a_all,
    output                                 out_valid,
    // K[0..DEPTH] for every slot, slot-major: Kv_all[s][i] at (s*(DEPTH+1)+i)
    output [NSLOT*(DEPTH+1)*(EXP+SIG)-1:0] Kv_all
);
    localparam integer W      = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam integer SW     = (NSLOT < 2) ? 1 : $clog2(NSLOT);
    localparam integer KW     = (DEPTH < 3) ? 1 : $clog2(DEPTH);
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2, S_DONE = 2'd3;

    initial if (NSLOT < FMA_LAT + 1)
        $fatal(1, "kscan_inter: NSLOT (%0d) must be >= FMA_LAT+1 (%0d)",
               NSLOT, FMA_LAT + 1);

    reg [1:0]               state;
    reg [SW-1:0]            rr;
    reg [KW-1:0]            k;
    reg [NSLOT*DEPTH*W-1:0] a_reg;
    reg [W-1:0]             lo [0:NSLOT-1];
    reg [W-1:0]             hi [0:NSLOT-1];
    reg [W-1:0]             Karr [0:NSLOT*(DEPTH+1)-1];
    reg [$clog2(FMA_LAT+2)-1:0] drain;

    assign in_ready  = (state == S_IDLE);
    assign out_valid = (state == S_DONE);

    genvar g;
    generate
        for (g = 0; g < NSLOT*(DEPTH+1); g = g + 1) begin : g_out
            assign Kv_all[g*W +: W] = Karr[g];
        end
    endgenerate

    wire [31:0] rr32 = 32'(rr);
    wire [31:0] k32  = 32'(k);
    wire issue = (state == S_RUN);
    wire [W-1:0] a_sel = a_reg[((rr32 * DEPTH) + k32) * W +: W];

    wire [W-1:0] mac_w;
    wire         mac_valid;
    fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_fma (
        .clock(clock), .nReset(nReset), .in_valid(issue),
        .a(a_sel), .b(lo[rr]),
        .c(NUMER_NEG ? {~hi[rr][W-1], hi[rr][W-2:0]} : hi[rr]),
        .out_valid(mac_valid), .p(mac_w)
    );

    // Which slot AND which step each in-flight FMA belongs to. The forward scan
    // needs only the slot, since it overwrites a rolling pair; retaining the
    // whole array means the writeback also has to know where to put the result,
    // so the step index rides the same shift register.
    reg [SW-1:0] slot_pipe [0:FMA_LAT-1];
    reg [KW-1:0] k_pipe    [0:FMA_LAT-1];
    integer q;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) for (q = 0; q < FMA_LAT; q = q + 1) begin
            slot_pipe[q] <= '0; k_pipe[q] <= '0;
        end else begin
            slot_pipe[0] <= rr;
            k_pipe[0]    <= k;
            for (q = 1; q < FMA_LAT; q = q + 1) begin
                slot_pipe[q] <= slot_pipe[q-1];
                k_pipe[q]    <= k_pipe[q-1];
            end
        end
    end
    wire [SW-1:0] wb_slot = slot_pipe[FMA_LAT-1];
    wire [KW-1:0] wb_k    = k_pipe[FMA_LAT-1];
    wire [31:0]   wb_idx  = (32'(wb_slot) * (DEPTH+1)) + 32'(wb_k);

    wire last_slot = (rr == SW'(NSLOT - 1));
    wire last_step = (k == '0);

    integer i;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; rr <= '0; k <= '0; drain <= '0; a_reg <= '0;
            for (i = 0; i < NSLOT; i = i + 1) begin lo[i] <= '0; hi[i] <= '0; end
            for (i = 0; i < NSLOT*(DEPTH+1); i = i + 1) Karr[i] <= '0;
        end else begin
            // Writeback. hi takes the pre-update lo, which is still intact
            // because the rotation has not re-issued this slot yet.
            if (mac_valid) begin
                hi[wb_slot]   <= lo[wb_slot];
                lo[wb_slot]   <= mac_w;
                Karr[wb_idx]  <= mac_w;          // K[wb_k] for this slot
            end

            case (state)
                S_IDLE: if (in_valid) begin
                    a_reg <= a_all;
                    for (i = 0; i < NSLOT; i = i + 1) begin
                        lo[i] <= a_all[((i * DEPTH) + (DEPTH-1)) * W +: W];
                        hi[i] <= F_ONE;
                        // Boundary values are known before any arithmetic runs:
                        // K[DEPTH] = 1 and K[DEPTH-1] = a[DEPTH-1].
                        Karr[i*(DEPTH+1) + DEPTH]     <= F_ONE;
                        Karr[i*(DEPTH+1) + (DEPTH-1)] <=
                            a_all[((i * DEPTH) + (DEPTH-1)) * W +: W];
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
                S_DRAIN: begin
                    if (drain == FMA_LAT[$bits(drain)-1:0]) state <= S_DONE;
                    else drain <= drain + 1'b1;
                end
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
