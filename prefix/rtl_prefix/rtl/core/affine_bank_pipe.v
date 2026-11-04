// affine_bank_pipe: coefficient generation that actually clocks.
//
// Replaces affine_bank, which closed at 7.2 MHz (I-38). Two independent defects
// in that design, both fixed here:
//
//   1. It used combinational fp_fma. One is ~32 MHz and 5,730 LUT, against
//      fp_fma_pipe's ~104 MHz and 1,993 LUT.
//   2. Its NMAC MACs were *chained*, so NMAC multiplied that already-long path:
//      four chained measured 7.2 MHz. NMAC bought cycles and lost more clock,
//      making throughput ~1.5x worse from NMAC 1 to 8.
//
// The fix is not to pipeline the chain -- a pipelined chain still carries the
// accumulation dependency and would stall FMA_LAT cycles in every step, exactly
// as the ladder scan did (I-32). The fix is to notice that **every coefficient
// is an independent accumulation**: a[j][k] = sum_c W[j][k][c] * x[c] for each
// (ladder j, level k). A batch of NBATCH ladders at depth DEPTH therefore has
// NBATCH*DEPTH independent chains -- 56 at the usual 8x7 -- which is far more
// than the 6 needed to keep a 5-stage FMA busy.
//
// So: NPAR parallel FMAs, never chained, each fed round-robin from its own group
// of accumulators. The combinational path is one FMA regardless of NPAR, so NPAR
// now buys throughput without costing clock -- the opposite of NMAC.
//
//   cycle t:  group g = t % NGROUP,  input element c = t / NGROUP
//             all NPAR lanes in group g issue against the same x[c]
//   re-issue interval for any accumulator = NGROUP cycles, which must be
//   >= FMA_LAT+1 for the same reason NSLOT must be in ladder_scan_inter: a
//   non-blocking write is only readable the cycle after.
//
// Accumulation order per coefficient is unchanged -- still sequential over c --
// so results are bit-identical to affine_bank at any NPAR.

`include "cofr_defs.vh"

module affine_bank_pipe #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    // Accumulator significand. Defaults to SIG, which is bit-for-bit the
    // original design. Setting it wider keeps the OPERANDS at SIG while the
    // running sum is carried at ACCSIG, which is how bf16 is used on hardware
    // that means it: a p-term sum in bf16 accumulates rounding faster than the
    // sum grows, and the error rises with p (about sqrt(p)). At p=768 that is a
    // 4.7e-2 median relative error against fp64; carrying the sum at fp32 and
    // rounding once at the output brings it to 2.8e-3.
    parameter ACCSIG  = SIG,
    parameter DEPTH   = `COFR_DEPTH,
    parameter PDIM    = 8,        // input dimensionality p
    parameter NBATCH  = 8,        // ladders produced per run (matches lane NSLOT)
    parameter NLAD    = 8,        // resident ladders (multiple of NBATCH)
    parameter NPAR    = 8,        // parallel FMAs -- NOT chained
    parameter FMA_LAT = 5,
    // C3: 1 = weight/bias memories live outside (read-back, macros); see ports wm_*/bm_*
    parameter EXT_MEM = 0,
    // C8: input tiling: partial sums kept / saved / restored across starts (spec 18.2); 0 = bit- and cycle-identical
    parameter TILE = 0,
    // derived
    parameter NCH     = NBATCH * DEPTH,          // independent accumulations
    parameter NGROUP  = NCH / NPAR,              // re-issue interval
    parameter NBATCHES = NLAD / NBATCH,
    parameter NWORDS  = NBATCHES * NGROUP * PDIM,
    parameter WAW     = (NWORDS < 2) ? 1 : $clog2(NWORDS),
    parameter NBWORDS = NBATCHES * NGROUP,
    parameter BAW     = (NBWORDS < 2) ? 1 : $clog2(NBWORDS),
    parameter BSW     = (NBATCHES < 2) ? 1 : $clog2(NBATCHES)
) (
    input                             clock,
    input                             nReset,
    input                             w_we,
    input  [WAW-1:0]                  w_addr,
    input  [NPAR*(EXP+SIG)-1:0]       w_din,
    input                             b_we,
    input  [BAW-1:0]                  b_addr,
    input  [NPAR*(EXP+SIG)-1:0]       b_din,
    input                             in_valid,
    output                            in_ready,
    input  [BSW-1:0]                  bsel,      // which batch of NBATCH ladders
    input  [PDIM*(EXP+SIG)-1:0]       x,
    output                            out_valid,
    output [NCH*(EXP+SIG)-1:0]        a,         // NBATCH ladders x DEPTH levels
    // C3: external memory interface (ignored / constant when EXT_MEM = 0)
    output [WAW-1:0]                  wm_addr,
    output [BAW-1:0]                  bm_addr,
    output                            mem_act,
    input  [NPAR*(EXP+SIG)-1:0]       wm_q,
    input  [NPAR*(EXP+SIG)-1:0]       bm_q,
    // C4 debug taps (plain wiring; no effect on behavior)
    output [NCH*(EXP+ACCSIG)-1:0]     acc_all,
    output                            mac0_v,
    output [EXP+ACCSIG-1:0]           mac0_p,
    output [1:0]                      state_o,
    // C8 tiling (ignored / constant when TILE = 0)
    input  [1:0]                      seed_mode,   // sampled at in_valid: 0 bias, 1 keep acc, 2 restore from ps_q
    input                             save_en,     // sampled at in_valid: stream acc out after the MAC phase
    input  [NPAR*(EXP+ACCSIG)-1:0]    ps_q,        // restore data, same timing as the bias memory
    output                            ps_we,
    output [BAW-1:0]                  ps_waddr,
    output [NPAR*(EXP+ACCSIG)-1:0]    ps_wdata
);
    localparam integer W  = EXP + SIG;
    localparam integer AW = EXP + ACCSIG;         // accumulator width
    localparam integer SH = ACCSIG - SIG;         // mantissa bits dropped on output

    // Round an AW-bit float down to W bits, round-to-nearest-even. With SH = 0
    // this is the identity, so the default build is unchanged.
    function automatic [W-1:0] narrow(input [AW-1:0] u);
        reg rbit, sticky, lsb, up;
        begin
            if (SH == 0) begin
                narrow = u[W-1:0];
            end else begin
                rbit   = u[SH-1];
                sticky = (SH > 1) ? |u[(SH > 1 ? SH-2 : 0):0] : 1'b0;
                lsb    = u[SH];
                up     = rbit & (sticky | lsb);
                narrow = u[AW-1:SH] + {{(W-1){1'b0}}, up};
            end
        end
    endfunction
    localparam integer GW = (NGROUP < 2) ? 1 : $clog2(NGROUP);
    localparam integer CW = (PDIM   < 2) ? 1 : $clog2(PDIM);
    localparam [2:0] S_IDLE = 3'd0, S_BIAS = 3'd1, S_MAC = 3'd2, S_DRAIN = 3'd3, S_SAVE = 3'd4;

    initial begin
        if (NCH % NPAR != 0)
            $fatal(1, "affine_bank_pipe: NPAR (%0d) must divide NBATCH*DEPTH (%0d)",
                   NPAR, NCH);
        if (NGROUP < FMA_LAT + 1)
            $fatal(1, "affine_bank_pipe: NGROUP (%0d) must be >= FMA_LAT+1 (%0d); reduce NPAR",
                   NGROUP, FMA_LAT + 1);
        if (NLAD % NBATCH != 0)
            $fatal(1, "affine_bank_pipe: NBATCH (%0d) must divide NLAD (%0d)", NBATCH, NLAD);
    end

    wire [NPAR*W-1:0] w_word_i, b_word_i;     // internal-memory read data
    wire [NPAR*W-1:0] w_word = EXT_MEM ? wm_q : w_word_i;
    wire [NPAR*W-1:0] b_word = EXT_MEM ? bm_q : b_word_i;

    reg [2:0]        state;
    reg [1:0]        seed_r;
    reg              save_r;
    reg [GW-1:0]     g;              // group index
    reg [CW:0]       c;              // input element index
    reg [BSW-1:0]    bsel_r;
    reg [PDIM*W-1:0] x_reg;
    reg [AW-1:0]     acc [0:NCH-1];
    reg [$clog2(FMA_LAT+2)-1:0] drain;
    reg [GW:0]       bg;             // bias prologue counter
    reg              ovalid_r;

    assign in_ready  = (state == S_IDLE);
    assign out_valid = ovalid_r;

    genvar q;
    generate
        for (q = 0; q < NCH; q = q + 1) begin : g_out
            assign a[q*W +: W] = narrow(acc[q]);
            assign acc_all[q*AW +: AW] = acc[q];
        end
    endgenerate

    wire [31:0] g32 = 32'(g);
    wire [31:0] c32 = 32'(c);
    wire [31:0] bb  = 32'(bsel_r) * NGROUP;

    wire last_g = (g == GW'(NGROUP - 1));
    wire last_c = (c32 == PDIM - 1);
    wire [31:0] ng = last_g ? 32'd0 : (g32 + 32'd1);
    wire [31:0] nc = last_g ? (last_c ? c32 : (c32 + 32'd1)) : c32;

    // Weight read one cycle ahead, as in affine_bank. During the bias prologue
    // hold the address at this batch's first word so it is ready for S_MAC.
    wire [31:0] wrd = (state == S_MAC) ? ((bb + ng) * PDIM + nc) : (bb * PDIM);
    // Bias read is one cycle ahead of its write, so the prologue runs NGROUP+1
    // cycles and only writes once bg > 0. Folding it into the group counter
    // instead reads the wrong word on the first and last group.
    wire [31:0] brd = bb + 32'(bg);

    assign wm_addr = wrd[WAW-1:0];
    assign bm_addr = brd[BAW-1:0];
    assign mem_act = ((state != S_IDLE) && (state != S_SAVE)) || in_valid;     // S_SAVE leaves the memory port to the PS store

    generate
        if (!EXT_MEM) begin : g_imem
            reg [NPAR*W-1:0] w_mem [0:NWORDS-1];
            reg [NPAR*W-1:0] b_mem [0:NBWORDS-1];
            reg [NPAR*W-1:0] w_q, b_q;
            always @(posedge clock) begin
                if (w_we) w_mem[w_addr] <= w_din;
                if (b_we) b_mem[b_addr] <= b_din;
                w_q <= w_mem[wrd[WAW-1:0]];
                b_q <= b_mem[brd[BAW-1:0]];
            end
            assign w_word_i = w_q;
            assign b_word_i = b_q;
        end else begin : g_xmem
            assign w_word_i = '0;
            assign b_word_i = '0;
        end
    endgenerate

    assign state_o = (state == S_SAVE) ? 2'd3 : state[1:0];
    wire issue = (state == S_MAC);
    wire [W-1:0] xc = x_reg[c32 * W +: W];

    // NPAR independent FMAs. No chaining: chain[m+1] never feeds chain[m].
    wire [AW-1:0] mac_p [0:NPAR-1];
    wire         mac_v [0:NPAR-1];
    genvar m;
    generate
        for (m = 0; m < NPAR; m = m + 1) begin : g_mac
            fp_fma_pipe #(.EXP(EXP), .SIG(ACCSIG)) u_mac (
                .clock(clock), .nReset(nReset), .in_valid(issue),
                .a({w_word[m*W +: W], {SH{1'b0}}}), .b({xc, {SH{1'b0}}}),
                .c(acc[g32 * NPAR + m]),
                .out_valid(mac_v[m]), .p(mac_p[m])
            );
        end
    endgenerate

    assign ps_we    = (state == S_SAVE);
    wire [31:0] ps_wa32 = bb + g32;
    assign ps_waddr = ps_wa32[BAW-1:0];
    genvar pm;
    generate
        for (pm = 0; pm < NPAR; pm = pm + 1) begin : g_ps
            assign ps_wdata[pm*AW +: AW] = acc[g32 * NPAR + pm];
        end
    endgenerate
    assign mac0_v = mac_v[0];
    assign mac0_p = mac_p[0];

    // Which group each in-flight issue belongs to: a plain shift register,
    // because the rotation guarantees results land FMA_LAT cycles after issue.
    reg [GW-1:0] gpipe [0:FMA_LAT-1];
    integer i;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) for (i = 0; i < FMA_LAT; i = i + 1) gpipe[i] <= '0;
        else begin
            gpipe[0] <= g;
            for (i = 1; i < FMA_LAT; i = i + 1) gpipe[i] <= gpipe[i-1];
        end
    end
    wire [31:0] wb_g = 32'(gpipe[FMA_LAT-1]);

    integer j;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; g <= '0; c <= '0; drain <= '0; bg <= '0; seed_r <= 2'd0; save_r <= 1'b0;
            ovalid_r <= 1'b0; bsel_r <= '0; x_reg <= '0;
            for (j = 0; j < NCH; j = j + 1) acc[j] <= '0;
        end else begin
            ovalid_r <= 1'b0;

            // writeback: one group's accumulators per cycle
            if (mac_v[0])
                for (j = 0; j < NPAR; j = j + 1)
                    acc[wb_g * NPAR + j] <= mac_p[j];

            case (state)
                S_IDLE: if (in_valid) begin
                    x_reg  <= x;
                    bsel_r <= bsel;
                    seed_r <= TILE ? seed_mode : 2'd0;
                    save_r <= TILE ? save_en : 1'b0;
                    g <= '0; c <= '0; drain <= '0; bg <= '0;
                    state <= S_BIAS;
                end
                // Prologue: seed every accumulator with its bias, NPAR per cycle.
                S_BIAS: begin
                    if (bg > 0)
                        for (j = 0; j < NPAR; j = j + 1) begin
                            if (seed_r == 2'd0)
                                acc[(32'(bg) - 32'd1) * NPAR + j] <= {b_word[j*W +: W], {SH{1'b0}}};
                            else if (seed_r == 2'd2)
                                acc[(32'(bg) - 32'd1) * NPAR + j] <= ps_q[j*AW +: AW];
                            // seed_r == 1: keep the accumulator as it is (no seeding)
                        end
                    if (32'(bg) == NGROUP) begin
                        g     <= '0;
                        state <= S_MAC;
                    end else begin
                        bg <= bg + 1'b1;
                    end
                end
                S_MAC: begin
                    if (last_g) begin
                        g <= '0;
                        if (last_c) state <= S_DRAIN;
                        else        c <= c + 1'b1;
                    end else begin
                        g <= g + GW'(1);
                    end
                end
                S_DRAIN: begin
                    if (drain == FMA_LAT[$bits(drain)-1:0]) begin
                        if (save_r) begin g <= '0; state <= S_SAVE; end
                        else begin ovalid_r <= 1'b1; state <= S_IDLE; end
                    end else drain <= drain + 1'b1;
                end
                S_SAVE: begin                         // stream the accumulators out, one group per cycle
                    if (g == GW'(NGROUP - 1)) begin g <= '0; ovalid_r <= 1'b1; state <= S_IDLE; end
                    else g <= g + GW'(1);
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
