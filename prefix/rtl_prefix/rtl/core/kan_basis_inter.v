// kan_basis_inter: the Chebyshev basis T_0..T_DEPTH of PIN inputs, the PIN
// independent recurrences interleaved through pipelined FMAs.
//
// This is kscan_inter with NUMER_NEG=1 specialised to the case a Chebyshev KAN
// actually presents. kscan_inter takes a general coefficient array a_all and
// keeps the whole continuant array; for the basis every coefficient is 2*x, so
// the NSLOT*DEPTH coefficient register collapses to one register per input (x
// and 2x), and the retained array is indexed by degree rather than by step.
// The schedule is unchanged:
//
//   T_0 = 1,  T_1 = x,  T_{n+1} = 2x * T_n - T_{n-1}    (one FMA per step)
//
//   rotation of RB slot groups, one group issued per cycle; each group holds
//   NBAS slots (one per FMA). Slot s is re-issued exactly RB cycles after its
//   previous issue, so RB >= FMA_LAT+1 makes the rotation the interlock: the
//   result a non-blocking write stores at the end of cycle t+FMA_LAT is readable
//   from t+FMA_LAT+1 (the rule ladder_scan_inter documents). Groups beyond
//   PIN are idle padding, which is how PIN < FMA_LAT+1 stays legal.
//
// NBAS=1 is exactly the kscan_inter schedule: PIN slots, one FMA, one issue
// per cycle. NBAS>1 splits the slots over NBAS independent FMAs, which shortens
// the rotation but not below FMA_LAT+1 (the dependency floor).
//
//   cycles = 1 + (DEPTH-1)*RB + (FMA_LAT+1) + 1,  RB = max(ceil(PIN/NBAS), FMA_LAT+1)
//
// 2x is formed by exponent increment, which is exact; zero and subnormal inputs
// double by a left shift of {exponent, fraction}, also exact. It is computed
// once at capture into its own register, off the FMA operand path.
//
// B_all is degree-major per input: B_all[(i*(DEPTH+1) + n)*W +: W] = T_n(x_i).
// Values are held until the next in_valid.

`include "cofr_defs.vh"

module kan_basis_inter #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter DEPTH   = `COFR_DEPTH,      // highest degree D; T_0..T_D
    parameter PIN     = 8,                // inputs (independent recurrences)
    parameter NBAS    = 1,                // pipelined FMAs used for the basis
    parameter FMA_LAT = 5,
    parameter GATE    = 1,
    // derived
    parameter NSPF    = (PIN + NBAS - 1) / NBAS,               // slots per FMA
    parameter RB      = (NSPF < FMA_LAT + 1) ? FMA_LAT + 1 : NSPF
) (
    input                                   clock,
    input                                   nReset,
    input                                   in_valid,
    output                                  in_ready,
    input  [PIN*(EXP+SIG)-1:0]              x,
    output                                  out_valid,
    output [PIN*(DEPTH+1)*(EXP+SIG)-1:0]    B_all
);
    localparam integer W   = EXP + SIG;
    localparam integer DP1 = DEPTH + 1;
    localparam [EXP-1:0] BIAS = EXP'((1 << (EXP - 1)) - 1);
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam integer GW = (RB < 2) ? 1 : $clog2(RB);
    localparam integer KW = (DEPTH < 2) ? 1 : $clog2(DEPTH);
    localparam integer SI = (PIN < 2) ? 1 : $clog2(PIN);
    localparam [2:0] S_IDLE = 3'd0, S_RUN = 3'd1, S_DRAIN = 3'd2, S_DONE = 3'd3;

    initial begin
        if (RB < FMA_LAT + 1)
            $fatal(1, "kan_basis_inter: rotation RB (%0d) must be >= FMA_LAT+1", RB);
        if (DEPTH < 1)
            $fatal(1, "kan_basis_inter: DEPTH must be >= 1");
    end

    // exact doubling of a binary float
    function automatic [W-1:0] dbl(input [W-1:0] v);
        reg [EXP-1:0] e;
        begin
            e = v[W-2 -: EXP];
            if (e == {EXP{1'b1}})                        dbl = v;                  // inf/nan
            else if (e == {{(EXP-1){1'b1}}, 1'b0})       dbl = {v[W-1], {EXP{1'b1}}, {(SIG-1){1'b0}}};
            else if (e == '0)                            dbl = {v[W-1], v[W-3:0], 1'b0};
            else                                         dbl = {v[W-1], e + EXP'(1), v[SIG-2:0]};
        end
    endfunction

    reg [2:0]   state;
    reg [GW-1:0] g;
    reg [KW-1:0] k;                       // producing T_{k+1}
    reg [$clog2(FMA_LAT+2)-1:0] drain;

    reg [W-1:0] xr  [0:PIN-1];
    reg [W-1:0] x2r [0:PIN-1];
    reg [W-1:0] lo  [0:PIN-1];            // T_k
    reg [W-1:0] hi  [0:PIN-1];            // T_{k-1}
    // T_2..T_D; index i*DP1 + n (n < 2 unused, left for simple indexing)
    reg [W-1:0] tarr [0:PIN*DP1-1];

    assign in_ready  = (state == S_IDLE);
    assign out_valid = (state == S_DONE);

    genvar gi, gn;
    generate
        for (gi = 0; gi < PIN; gi = gi + 1) begin : g_bi
            for (gn = 0; gn < DP1; gn = gn + 1) begin : g_bn
                if (gn == 0) begin : g0
                    assign B_all[(gi*DP1 + gn)*W +: W] = F_ONE;
                end else if (gn == 1) begin : g1
                    assign B_all[(gi*DP1 + gn)*W +: W] = xr[gi];
                end else begin : gk
                    assign B_all[(gi*DP1 + gn)*W +: W] = tarr[gi*DP1 + gn];
                end
            end
        end
    endgenerate

    wire issue = (state == S_RUN);

    // ---- NBAS interleaved FMAs --------------------------------------------
    wire [W-1:0] mac_p [0:NBAS-1];
    wire         mac_v [0:NBAS-1];
    genvar f;
    generate
        for (f = 0; f < NBAS; f = f + 1) begin : g_fma
            wire [31:0] s32  = 32'(g) * NBAS + f;
            wire        live = (s32 < PIN);
            wire [SI-1:0] s  = live ? s32[SI-1:0] : '0;
            fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_fma (
                .clock(clock), .nReset(nReset), .in_valid(issue && live),
                .a(x2r[s]), .b(lo[s]),
                .c({~hi[s][W-1], hi[s][W-2:0]}),       // -T_{k-1}: sign flip
                .out_valid(mac_v[f]), .p(mac_p[f])
            );
        end
    endgenerate

    // group and step of each in-flight issue
    reg [GW-1:0] gpipe [0:FMA_LAT-1];
    reg [KW-1:0] kpipe [0:FMA_LAT-1];
    integer q;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) for (q = 0; q < FMA_LAT; q = q + 1) begin
            gpipe[q] <= '0; kpipe[q] <= '0;
        end else begin
            gpipe[0] <= g; kpipe[0] <= k;
            for (q = 1; q < FMA_LAT; q = q + 1) begin
                gpipe[q] <= gpipe[q-1]; kpipe[q] <= kpipe[q-1];
            end
        end
    end
    wire [31:0] wb_g = 32'(gpipe[FMA_LAT-1]);
    wire [31:0] wb_k = 32'(kpipe[FMA_LAT-1]);

    wire last_g = (g == GW'(RB - 1));
    wire last_k = (32'(k) == DEPTH - 1);

    integer i, j;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; g <= '0; k <= '0; drain <= '0;
            for (i = 0; i < PIN; i = i + 1) begin
                xr[i] <= '0; x2r[i] <= '0; lo[i] <= '0; hi[i] <= '0;
            end
            for (i = 0; i < PIN*DP1; i = i + 1) tarr[i] <= '0;
        end else begin
            // writeback: slot s = wb_g*NBAS + j gets T_{wb_k+1}
            for (j = 0; j < NBAS; j = j + 1)
                if (mac_v[j] && (wb_g * NBAS + j < PIN)) begin
                    hi[wb_g * NBAS + j] <= lo[wb_g * NBAS + j];
                    lo[wb_g * NBAS + j] <= mac_p[j];
                    tarr[(wb_g * NBAS + j) * DP1 + wb_k + 1] <= mac_p[j];
                end

            case (state)
                S_IDLE: if (in_valid) begin
                    for (i = 0; i < PIN; i = i + 1) begin
                        xr[i]  <= x[i*W +: W];
                        x2r[i] <= dbl(x[i*W +: W]);
                        lo[i]  <= x[i*W +: W];        // T_1
                        hi[i]  <= F_ONE;              // T_0
                    end
                    g <= '0; k <= KW'(1); drain <= '0;
                    state <= (DEPTH < 2) ? S_DONE : S_RUN;
                end
                S_RUN: begin
                    if (last_g) begin
                        g <= '0;
                        if (last_k) state <= S_DRAIN;
                        else        k <= k + KW'(1);
                    end else g <= g + GW'(1);
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
