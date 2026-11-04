// recip_nr_pipe: recip_nr rebuilt on the pipelined FMA.
//
// Identical algebra to recip_nr -- table seed, one Newton-Raphson step, then the
// output multiply -- but every floating-point operation now uses fp_fma_pipe
// instead of the combinational fp_fma / fp_mul. Those measured 31.9 MHz and
// would otherwise cap the whole lane there, even though ladder_scan_inter closes
// at 108.4 MHz (docs/TIMING_CORRECTION.md).
//
// fp_mul is exactly mulAdd(x, y, +0.0), so all three operations map onto the same
// pipelined FMA and no separate multiplier is needed:
//
//   t  = fma(-b, x0, 2.0)      Newton-Raphson step
//   x1 = fma(x0,  t,  0.0)
//   f  = fma(k1, x1,  0.0)     output scaling
//
// Latency 2 + (1 + 2*NR_ITERS)*FMA_LAT cycles (NR_ITERS=1: 2 + 3*FMA_LAT), initiation interval 1. Latency matters little
// here: the lane interleaves ladders, so the pipeline is kept full.

`include "cofr_defs.vh"

module recip_nr_pipe #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter TBITS   = 12,
    parameter FMA_LAT = 5,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS,
    parameter SEED_FILE = "recip_seed_e8s24_t12.mem",
    parameter GATE = 1,
    // C7: Newton-Raphson iterations (1 as built; 2 allows a 256-entry fp32 seed)
    parameter NR_ITERS = 1
) (
    input                    clock,
    input                    nReset,
    input                    inValid,
    output                   inReady,
    input  [(EXP+SIG)-1:0]   k0,
    input  [(EXP+SIG)-1:0]   k1,
    output                   outValid,
    output [(EXP+SIG)-1:0]   f,
    // C2: one pulse per divisor clamped by the pole guard, one cycle after it was accepted
    output                   guard_hit
);
    localparam integer W      = EXP + SIG;
    localparam integer FR     = SIG - 1;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [EXP+1:0] ESUM = (2 * BIAS) - 1;
    localparam [W-1:0] F_TWO  = {1'b0, BIAS + 1'b1, {FR{1'b0}}};
    localparam [W-1:0] F_ZERO = {W{1'b0}};

    assign inReady = 1'b1;

    // ---- S0: pole guard --------------------------------------------------
    wire         s_sign  = k0[W-1];
    wire [W-2:0] s_mag   = k0[W-2:0];
    wire [W-1:0] s_b     = {s_sign, (s_mag < EPS[W-2:0]) ? EPS[W-2:0] : s_mag};

    reg [W-1:0] b_1, k1_1;
    reg         v_1, small_1;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin v_1 <= 1'b0; small_1 <= 1'b0; b_1 <= '0; k1_1 <= '0; end
        else begin
            v_1 <= inValid; b_1 <= s_b; k1_1 <= k1;
            small_1 <= inValid && (s_mag < EPS[W-2:0]);
        end
    end
    assign guard_hit = small_1;

    // ---- S1: seed --------------------------------------------------------
    (* rom_style = "block" *) reg [FR-1:0] seed_rom [0:(1<<TBITS)-1];
    initial $readmemh(SEED_FILE, seed_rom);

    wire [EXP-1:0]   b1_exp  = b_1[W-2 -: EXP];
    wire [FR-1:0]    b1_frac = b_1[FR-1:0];
    wire [TBITS-1:0] tidx    = b1_frac[FR-1 -: TBITS];
    wire [EXP+1:0]   e0_full = ESUM - {2'b00, b1_exp};
    wire [EXP-1:0]   e0 = (e0_full[EXP+1] || e0_full == '0) ? {{(EXP-1){1'b0}}, 1'b1}
                        : (e0_full > {2'b00, {EXP{1'b1}}} - 1) ? {EXP{1'b1}} - 1'b1
                        : e0_full[EXP-1:0];

    // The ROM output register must be free of the asynchronous reset. With the
    // reset on it, Vivado cannot use a block-RAM output register and drops the
    // whole 4096x23 table into logic (seen as "seed_rom ... LUT" in the synth
    // report), costing several kLUT per lane. v_2 already gates the datapath, so
    // an undefined seed out of reset never reaches a result.
    reg [FR-1:0] seed_q;
    always @(posedge clock) seed_q <= seed_rom[tidx];

    // Sign and exponent move to the same stage so they arrive with the seed.
    reg [EXP-1:0] e0_2;
    reg           sgn_2;
    reg [W-1:0]   b_2, k1_2;
    reg           v_2;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            v_2 <= 1'b0; e0_2 <= '0; sgn_2 <= 1'b0; b_2 <= '0; k1_2 <= '0;
        end else begin
            v_2   <= v_1;
            e0_2  <= e0;
            sgn_2 <= b_1[W-1];
            b_2   <= b_1;
            k1_2  <= k1_1;
        end
    end
    wire [W-1:0] x0_2 = {sgn_2, e0_2, seed_q};

    wire [W-1:0] nb_2 = {~b_2[W-1], b_2[W-2:0]};

    // ---- Newton-Raphson iterations (C7: NR_ITERS, default 1 = as built) ------
    // Per iteration:  t = fma(-b, x, 2);  x' = x * t.  x, k1 and (for further
    // iterations) -b are delayed alongside the FMAs so everything lines up.
    wire [W-1:0] xs  [0:NR_ITERS];
    wire         vs  [0:NR_ITERS];
    wire [W-1:0] ks  [0:NR_ITERS];
    wire [W-1:0] nbs [0:NR_ITERS];
    assign xs[0] = x0_2;  assign vs[0] = v_2;  assign ks[0] = k1_2;  assign nbs[0] = nb_2;

    genvar it;
    generate
        for (it = 0; it < NR_ITERS; it = it + 1) begin : g_nr
            // ---- A: t = 2 - b*x --------------------------------------------
            wire [W-1:0] t_w;
            wire         t_v;
            fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_nr (
                .clock(clock), .nReset(nReset), .in_valid(vs[it]),
                .a(nbs[it]), .b(xs[it]), .c(F_TWO), .out_valid(t_v), .p(t_w));

            // x and k1 must arrive with t, so shift them alongside the FMA
            reg [W-1:0] x_d [0:FMA_LAT-1];
            reg [W-1:0] k_d [0:FMA_LAT-1];
            reg [W-1:0] k_e [0:FMA_LAT-1];
            integer i;
            always @(posedge clock or negedge nReset) begin
                if (!nReset) for (i = 0; i < FMA_LAT; i = i + 1) begin
                    x_d[i] <= '0; k_d[i] <= '0; k_e[i] <= '0;
                end else begin
                    x_d[0] <= xs[it]; k_d[0] <= ks[it]; k_e[0] <= k_d[FMA_LAT-1];
                    for (i = 1; i < FMA_LAT; i = i + 1) begin
                        x_d[i] <= x_d[i-1]; k_d[i] <= k_d[i-1]; k_e[i] <= k_e[i-1];
                    end
                end
            end

            // ---- B: x' = x * t  (mulAdd with c = +0) -----------------------
            fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_mul_nr (
                .clock(clock), .nReset(nReset), .in_valid(t_v),
                .a(x_d[FMA_LAT-1]), .b(t_w), .c(F_ZERO), .out_valid(vs[it+1]), .p(xs[it+1]));
            assign ks[it+1] = k_e[FMA_LAT-1];

            // -b is only needed again by a following iteration
            if (it < NR_ITERS - 1) begin : g_nb
                reg [W-1:0] n_d [0:FMA_LAT-1];
                reg [W-1:0] n_e [0:FMA_LAT-1];
                integer q;
                always @(posedge clock or negedge nReset) begin
                    if (!nReset) for (q = 0; q < FMA_LAT; q = q + 1) begin
                        n_d[q] <= '0; n_e[q] <= '0;
                    end else begin
                        n_d[0] <= nbs[it]; n_e[0] <= n_d[FMA_LAT-1];
                        for (q = 1; q < FMA_LAT; q = q + 1) begin
                            n_d[q] <= n_d[q-1]; n_e[q] <= n_e[q-1];
                        end
                    end
                end
                assign nbs[it+1] = n_e[FMA_LAT-1];
            end else begin : g_nonb
                assign nbs[it+1] = '0;
            end
        end
    endgenerate

    // ---- C: f = k1 * x ---------------------------------------------------
    fp_fma_pipe #(.EXP(EXP), .SIG(SIG), .GATE(GATE)) u_mul_out (
        .clock(clock), .nReset(nReset), .in_valid(vs[NR_ITERS]),
        .a(ks[NR_ITERS]), .b(xs[NR_ITERS]), .c(F_ZERO), .out_valid(outValid), .p(f));
endmodule
