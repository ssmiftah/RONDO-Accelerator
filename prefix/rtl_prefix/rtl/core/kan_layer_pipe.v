// kan_layer_pipe: one Chebyshev KAN layer on pipelined arithmetic.
//
//   y_o = sum_{i<P_IN} sum_{n<=DEPTH} c[o,i,n] T_n(xt_i),   xt = tanh(x) (host)
//
// Contract mirrors fused_coproc_pipe: coefficients resident in on-chip memory,
// loaded once through w_we/w_lane/w_addr/w_din; the input vector in, all N_OUT
// outputs out; start/busy/done.
//
//   xt --> kan_basis_inter (P_IN recurrences, NBAS FMAs, interleaved)
//      --> kan_sum_bank    (NMAC parallel FMAs, per-degree partials + tree)
//      --> y
//
// Lanes partition the OUTPUTS. Lane l owns outputs [l*NOUTL, (l+1)*NOUTL) and
// holds its own basis evaluator, sum bank and coefficient memory, so no state is
// shared between lanes and mapping results onto y is static wiring, exactly as
// in fused_coproc_pipe. The basis is therefore evaluated once per lane rather
// than once per layer: the only duplicated arithmetic, P_IN*(DEPTH-1) FMAs per
// lane against N_OUT/N_LANES*P_IN*(DEPTH+1) for the sum. Partitioning the
// inputs instead would halve nothing that matters -- every output still needs
// every input's basis -- and would reintroduce a cross-lane merge of partial
// sums; see docs/KAN_HARDWARE.md.
//
// Lane sequencing: basis once, then NBATCHES batches of NOB outputs.
//
// Memory addressing per lane (see kan_sum_bank):
//   addr = (b*NGROUP + g)*P_IN + i, word[f] = c[o,i,n],
//   ch = g*NMAC + f, o = l*NOUTL + b*NOB + ch/(DEPTH+1), n = ch % (DEPTH+1)

`include "cofr_defs.vh"

module kan_layer_pipe #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter DEPTH   = 7,
    parameter P_IN    = 8,
    parameter N_OUT   = 16,
    parameter N_LANES = 2,
    parameter NOB     = 8,
    parameter NMAC    = 8,
    parameter NBAS    = 1,
    parameter FMA_LAT = 5,
    parameter GATE    = 1,
    // derived
    parameter NOUTL    = N_OUT / N_LANES,
    parameter DP1      = DEPTH + 1,
    parameter NCH      = NOB * DP1,
    parameter NGROUP   = NCH / NMAC,
    parameter NBATCHES = NOUTL / NOB,
    parameter WAW      = ((NBATCHES*NGROUP*P_IN) < 2) ? 1 : $clog2(NBATCHES*NGROUP*P_IN),
    parameter BSW      = (NBATCHES < 2) ? 1 : $clog2(NBATCHES),
    parameter LNW      = (N_LANES < 2) ? 1 : $clog2(N_LANES)
) (
    input                          clock,
    input                          nReset,
    input                          w_we,
    input  [LNW-1:0]               w_lane,
    input  [WAW-1:0]               w_addr,
    input  [NMAC*(EXP+SIG)-1:0]    w_din,
    input                          start,
    output                         busy,
    output                         done,
    input  [P_IN*(EXP+SIG)-1:0]    x,
    output [N_OUT*(EXP+SIG)-1:0]   y
);
    localparam integer W    = EXP + SIG;
    localparam integer BSWI = (NBATCHES < 2) ? 1 : $clog2(NBATCHES + 1);

    initial if (NOUTL * N_LANES != N_OUT)
        $fatal(1, "kan_layer_pipe: N_LANES (%0d) must divide N_OUT (%0d)", N_LANES, N_OUT);

    reg  busy_r, done_r;
    assign busy = busy_r;
    assign done = done_r;
    wire [N_LANES-1:0] lane_fin;

    // registered load fan-out, as in fused_coproc_pipe: breaks the one wire
    // that otherwise reaches every lane's memory across the die
    reg             w_we_q;
    reg [LNW-1:0]   w_lane_q;
    reg [WAW-1:0]   w_addr_q;
    reg [NMAC*W-1:0] w_din_q;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) w_we_q <= 1'b0;
        else begin
            w_we_q <= w_we; w_lane_q <= w_lane; w_addr_q <= w_addr; w_din_q <= w_din;
        end
    end

    genvar l, wv, s;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            wire lane_sel = (N_LANES == 1) || (w_lane_q == l[LNW-1:0]);

            reg  bs_go, sb_go;
            wire bs_ready, bs_done, sb_ready, sb_done;
            wire [P_IN*DP1*W-1:0] B_all;
            wire [NOB*W-1:0]      sb_y;
            reg  [BSWI-1:0]       bat;

            kan_basis_inter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .PIN(P_IN),
                              .NBAS(NBAS), .FMA_LAT(FMA_LAT), .GATE(GATE)) u_bas (
                .clock(clock), .nReset(nReset),
                .in_valid(bs_go), .in_ready(bs_ready), .x(x),
                .out_valid(bs_done), .B_all(B_all)
            );

            kan_sum_bank #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .PIN(P_IN),
                           .NOB(NOB), .NOUT(NOUTL), .NPAR(NMAC),
                           .FMA_LAT(FMA_LAT), .GATE(GATE)) u_sum (
                .clock(clock), .nReset(nReset),
                .w_we(w_we_q && lane_sel), .w_addr(w_addr_q), .w_din(w_din_q),
                .in_valid(sb_go), .in_ready(sb_ready),
                .bsel(bat[BSW-1:0]), .B_all(B_all),
                .out_valid(sb_done), .y(sb_y)
            );

            reg [W-1:0] yl [0:NOUTL-1];

            localparam [2:0] L_IDLE = 3'd0, L_BGO = 3'd1, L_BWAIT = 3'd2,
                             L_SGO  = 3'd3, L_SWAIT = 3'd4, L_FIN = 3'd5;
            reg [2:0] lstate;
            assign lane_fin[l] = (lstate == L_FIN);

            integer k;
            always @(posedge clock or negedge nReset) begin
                if (!nReset) begin
                    lstate <= L_IDLE; bat <= '0; bs_go <= 1'b0; sb_go <= 1'b0;
                end else begin
                    bs_go <= 1'b0;
                    sb_go <= 1'b0;
                    case (lstate)
                        L_IDLE: if (start) begin
                            bat <= '0; lstate <= L_BGO;
                        end
                        L_BGO: if (bs_ready) begin
                            bs_go <= 1'b1; lstate <= L_BWAIT;
                        end
                        L_BWAIT: if (bs_done) lstate <= L_SGO;
                        L_SGO: if (sb_ready) begin
                            sb_go <= 1'b1; lstate <= L_SWAIT;
                        end
                        L_SWAIT: if (sb_done) begin
                            for (k = 0; k < NOB; k = k + 1)
                                yl[32'(bat) * NOB + k] <= sb_y[k*W +: W];
                            if (32'(bat) == NBATCHES - 1) lstate <= L_FIN;
                            else begin
                                bat    <= bat + 1'b1;
                                lstate <= L_SGO;
                            end
                        end
                        // C1: see fused_coproc_pipe (start in the done cycle is taken).
                        L_FIN: if (start && !busy_r) begin
                            bat <= '0; lstate <= L_BGO;
                        end else if (!busy_r) lstate <= L_IDLE;
                        default: lstate <= L_IDLE;
                    endcase
                end
            end

            for (s = 0; s < NOUTL; s = s + 1) begin : g_map
                assign y[(l * NOUTL + s) * W +: W] = yl[s];
            end
        end
    endgenerate

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin busy_r <= 1'b0; done_r <= 1'b0; end
        else begin
            done_r <= 1'b0;
            if (start && !busy_r) busy_r <= 1'b1;
            else if (busy_r && (&lane_fin)) begin
                busy_r <= 1'b0;
                done_r <= 1'b1;
            end
        end
    end
endmodule
