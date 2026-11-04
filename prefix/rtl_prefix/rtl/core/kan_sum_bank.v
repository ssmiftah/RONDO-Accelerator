// kan_sum_bank: the KAN weighted sum y_o = sum_i sum_n c[o,i,n] T_n(x_i) for a
// batch of NOB outputs, on NPAR parallel pipelined FMAs with coefficients in
// on-chip memory.
//
// This is affine_bank_pipe's schedule applied to a Chebyshev KAN. The sum is a
// matrix-vector product C * B with C in R^{O x p(D+1)} and B the basis vector,
// the same shape of work as CoFrNet's coefficient stage W * x.
//
// Why the accumulation is split by degree. affine_bank_pipe works because a
// batch holds NBATCH*DEPTH = 56 independent accumulations, far more than the
// FMA_LAT+1 = 6 re-issue interval times NPAR. A KAN output has only one natural
// accumulation, so a lane owning 8 outputs would hold 8 serial chains and could
// feed only one FMA. Splitting every output into its DEPTH+1 degree partials
//
//     S[o,n] = sum_i c[o,i,n] T_n(x_i),      y_o = sum_n S[o,n]
//
// gives NOB*(DEPTH+1) independent accumulations per batch (64 at NOB=8, D=7),
// each still accumulated in input order i = 0..PIN-1, exactly like a CoFrNet
// coefficient. With NPAR = DEPTH+1 the FMA index IS the degree, so FMA f always
// multiplies by column f of the basis and the operand select is a PIN:1 mux on
// the step counter only.
//
//   phase MAC:  cycle t -> group g = t % NGROUP, input i = t / NGROUP
//               FMA f in group g: acc[g*NPAR+f] += w[f] * T_{n(ch)}(x_i)
//               re-issue interval NGROUP >= FMA_LAT+1
//   phase CMB:  y_o = sum_n S[o,n] by a balanced tree of ceil(log2(D+1))
//               levels, one rotation over the NOB outputs per level. Output o
//               issues level l+1 exactly NOB cycles after level l, so NOB >=
//               FMA_LAT+1 is the same rule again. Each add is an FMA with b=1,
//               which is the exactly rounded sum.
//
// Accumulation order is fixed by (i order within a partial, tree across
// partials) and does not depend on NPAR, NOB grouping or lane count, so results
// are bit-identical across all of them.
//
// Memory layout (one word per (batch, group, input), NPAR coefficients wide):
//   w_mem[(b*NGROUP + g)*PIN + i][f*W +: W] = c[o, i, n]
//   with ch = g*NPAR + f, o = b*NOB + ch/(DEPTH+1), n = ch % (DEPTH+1).

`include "cofr_defs.vh"

module kan_sum_bank #(
    parameter EXP      = `COFR_EXP,
    parameter SIG      = `COFR_SIG,
    parameter DEPTH    = `COFR_DEPTH,
    parameter PIN      = 8,
    parameter NOB      = 8,          // outputs per batch
    parameter NOUT     = 8,          // resident outputs (multiple of NOB)
    parameter NPAR     = 8,          // parallel FMAs, never chained
    parameter FMA_LAT  = 5,
    parameter GATE     = 1,
    // derived
    parameter DP1      = DEPTH + 1,
    parameter NCH      = NOB * DP1,
    parameter NGROUP   = NCH / NPAR,
    parameter NBATCHES = NOUT / NOB,
    parameter NWORDS   = NBATCHES * NGROUP * PIN,
    parameter WAW      = (NWORDS < 2) ? 1 : $clog2(NWORDS),
    parameter BSW      = (NBATCHES < 2) ? 1 : $clog2(NBATCHES),
    parameter NLEV     = (DP1 < 2) ? 0 : $clog2(DP1)
) (
    input                               clock,
    input                               nReset,
    input                               w_we,
    input  [WAW-1:0]                    w_addr,
    input  [NPAR*(EXP+SIG)-1:0]         w_din,
    input                               in_valid,
    output                              in_ready,
    input  [BSW-1:0]                    bsel,
    input  [PIN*(DEPTH+1)*(EXP+SIG)-1:0] B_all,
    output                              out_valid,
    output [NOB*(EXP+SIG)-1:0]          y
);
    localparam integer W  = EXP + SIG;
    localparam [EXP-1:0] BIAS = EXP'((1 << (EXP - 1)) - 1);
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam integer GW = (NGROUP < 2) ? 1 : $clog2(NGROUP);
    localparam integer CW = (PIN < 2) ? 1 : $clog2(PIN);
    localparam integer OW = (NOB < 2) ? 1 : $clog2(NOB);
    localparam integer LW = (NLEV < 2) ? 1 : $clog2(NLEV);
    localparam integer HW = (GW > OW) ? GW : OW;      // tag width for group/output
    localparam [2:0] S_IDLE = 3'd0, S_PRE = 3'd1, S_MAC = 3'd2, S_DR1 = 3'd3,
                     S_CMB  = 3'd4, S_DR2 = 3'd5, S_DONE = 3'd6;

    initial begin
        if (NCH % NPAR != 0)
            $fatal(1, "kan_sum_bank: NPAR (%0d) must divide NOB*(DEPTH+1) (%0d)", NPAR, NCH);
        if (NGROUP < FMA_LAT + 1)
            $fatal(1, "kan_sum_bank: NGROUP (%0d) must be >= FMA_LAT+1; reduce NPAR", NGROUP);
        if (NOB < FMA_LAT + 1)
            $fatal(1, "kan_sum_bank: NOB (%0d) must be >= FMA_LAT+1 for the combine rotation", NOB);
        if (NPAR < DP1 / 2)
            $fatal(1, "kan_sum_bank: NPAR (%0d) must be >= (DEPTH+1)/2 for the combine tree", NPAR);
        if (NOUT % NOB != 0)
            $fatal(1, "kan_sum_bank: NOB (%0d) must divide NOUT (%0d)", NOB, NOUT);
    end

    reg [NPAR*W-1:0] w_mem [0:NWORDS-1];
    reg [NPAR*W-1:0] w_word;

    reg [2:0]    state;
    reg [GW-1:0] g;
    reg [CW:0]   c;
    reg [OW-1:0] o;
    reg [LW-1:0] lv;
    reg [BSW-1:0] bsel_r;
    reg [W-1:0]  acc [0:NCH-1];
    reg [$clog2(FMA_LAT+2)-1:0] drain;
    reg          ovalid_r;

    assign in_ready  = (state == S_IDLE);
    assign out_valid = ovalid_r;

    genvar q;
    generate
        for (q = 0; q < NOB; q = q + 1) begin : g_y
            assign y[q*W +: W] = acc[q*DP1];
        end
    endgenerate

    wire [31:0] g32 = 32'(g);
    wire [31:0] c32 = 32'(c);
    wire [31:0] l32 = 32'(lv);
    wire [31:0] bb  = 32'(bsel_r) * NGROUP;

    wire last_g = (g == GW'(NGROUP - 1));
    wire last_c = (c32 == PIN - 1);
    wire last_o = (o == OW'(NOB - 1));
    wire last_l = (l32 == NLEV - 1);
    wire [31:0] ng = last_g ? 32'd0 : (g32 + 32'd1);
    wire [31:0] nc = last_g ? (last_c ? c32 : (c32 + 32'd1)) : c32;

    // coefficient read one cycle ahead (S_PRE holds the batch's first word)
    wire [31:0] wrd = (state == S_MAC) ? ((bb + ng) * PIN + nc) : (bb * PIN);
    always @(posedge clock) begin
        if (w_we) w_mem[w_addr] <= w_din;
        w_word <= w_mem[wrd[WAW-1:0]];
    end

    wire mac_issue = (state == S_MAC);
    wire cmb_issue = (state == S_CMB);

    wire [W-1:0] mac_p [0:NPAR-1];
    wire         mac_v [0:NPAR-1];
    genvar m;
    generate
        for (m = 0; m < NPAR; m = m + 1) begin : g_mac
            // ---- MAC operands: chain ch = g*NPAR + m, degree n = ch % DP1
            wire [W-1:0] b_mac;
            if (NPAR == DP1) begin : g_fixed
                // the FMA index is the degree: a PIN:1 select on c only
                assign b_mac = B_all[(c32 * DP1 + m) * W +: W];
            end else begin : g_gen
                wire [31:0] nd = (g32 * NPAR + m) % DP1;
                assign b_mac = B_all[(c32 * DP1 + nd) * W +: W];
            end
            wire [W-1:0] c_mac = acc[g32 * NPAR + m];

            // ---- combine operands: acc[o, 2*s*m] += acc[o, 2*s*m + s]
            // The partial offsets are constants per (m, level), so each output's
            // candidate is a <=NLEV:1 select on the level counter, and the output
            // is then an NOB:1 select on o. Written as one flat index this was a
            // 64:1 select behind an adder, and an earlier form, (s*2)*m, was
            // mapped by Vivado to two DSP48s on the path into the FMA's stage
            // enable, which set the clock.
            reg clive;
            integer lk;
            always @* begin
                clive = 1'b0;
                for (lk = 0; lk < NLEV; lk = lk + 1)
                    if (l32 == lk)
                        clive = (((m << (lk + 1)) + (1 << lk)) < DP1);
            end
            wire [NOB*W-1:0] a_flat, c_flat;
            genvar oq;
            for (oq = 0; oq < NOB; oq = oq + 1) begin : g_oq
                reg [W-1:0] aq, cq;
                integer lq;
                always @* begin
                    aq = '0; cq = '0;
                    for (lq = 0; lq < NLEV; lq = lq + 1)
                        if (l32 == lq && (((m << (lq + 1)) + (1 << lq)) < DP1)) begin
                            aq = acc[oq * DP1 + (m << (lq + 1)) + (1 << lq)];
                            cq = acc[oq * DP1 + (m << (lq + 1))];
                        end
                end
                assign a_flat[oq*W +: W] = aq;
                assign c_flat[oq*W +: W] = cq;
            end
            wire [W-1:0] a_cmb = a_flat[32'(o) * W +: W];
            wire [W-1:0] c_cmb = c_flat[32'(o) * W +: W];

            wire [W-1:0] a_in = cmb_issue ? a_cmb : w_word[m*W +: W];
            wire [W-1:0] b_in = cmb_issue ? F_ONE   : b_mac;
            wire [W-1:0] c_in = cmb_issue ? c_cmb : c_mac;
            fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_mac (
                .clock(clock), .nReset(nReset),
                .in_valid(mac_issue || (cmb_issue && clive)),
                .a(a_in), .b(b_in), .c(c_in),
                .out_valid(mac_v[m]), .p(mac_p[m])
            );
        end
    endgenerate

    // which phase / group-or-output / level each in-flight issue belongs to
    reg          ppipe [0:FMA_LAT-1];     // 1 = combine
    reg [HW-1:0] hpipe [0:FMA_LAT-1];
    reg [LW-1:0] lpipe [0:FMA_LAT-1];
    integer i;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) for (i = 0; i < FMA_LAT; i = i + 1) begin
            ppipe[i] <= 1'b0; hpipe[i] <= '0; lpipe[i] <= '0;
        end else begin
            ppipe[0] <= cmb_issue;
            hpipe[0] <= cmb_issue ? HW'(o) : HW'(g);
            lpipe[0] <= lv;
            for (i = 1; i < FMA_LAT; i = i + 1) begin
                ppipe[i] <= ppipe[i-1]; hpipe[i] <= hpipe[i-1]; lpipe[i] <= lpipe[i-1];
            end
        end
    end
    wire        wb_cmb = ppipe[FMA_LAT-1];
    wire [31:0] wb_h   = 32'(hpipe[FMA_LAT-1]);
    wire [31:0] wb_l1  = 32'(lpipe[FMA_LAT-1]) + 32'd1;

    integer j;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; g <= '0; c <= '0; o <= '0; lv <= '0; drain <= '0;
            ovalid_r <= 1'b0; bsel_r <= '0;
            for (j = 0; j < NCH; j = j + 1) acc[j] <= '0;
        end else begin
            ovalid_r <= 1'b0;

            for (j = 0; j < NPAR; j = j + 1)
                if (mac_v[j]) begin
                    if (wb_cmb) acc[wb_h * DP1 + (32'(j) << wb_l1)] <= mac_p[j];
                    else        acc[wb_h * NPAR + j] <= mac_p[j];
                end

            case (state)
                S_IDLE: if (in_valid) begin
                    bsel_r <= bsel;
                    g <= '0; c <= '0; o <= '0; lv <= '0; drain <= '0;
                    state <= S_PRE;
                end
                S_PRE: begin                       // zero the partials, fetch word 0
                    for (j = 0; j < NCH; j = j + 1) acc[j] <= '0;
                    state <= S_MAC;
                end
                S_MAC: begin
                    if (last_g) begin
                        g <= '0;
                        if (last_c) state <= S_DR1;
                        else        c <= c + 1'b1;
                    end else g <= g + GW'(1);
                end
                S_DR1: begin
                    if (drain == FMA_LAT[$bits(drain)-1:0]) begin
                        drain <= '0;
                        state <= (NLEV == 0) ? S_DONE : S_CMB;
                    end else drain <= drain + 1'b1;
                end
                S_CMB: begin
                    if (last_o) begin
                        o <= '0;
                        if (last_l) state <= S_DR2;
                        else        lv <= lv + LW'(1);
                    end else o <= o + OW'(1);
                end
                S_DR2: begin
                    if (drain == FMA_LAT[$bits(drain)-1:0]) state <= S_DONE;
                    else drain <= drain + 1'b1;
                end
                S_DONE: begin
                    ovalid_r <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
