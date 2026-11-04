// train_ladder_inter: forward + backward for NSLOT ladders on pipelined units.
//
// This is train_ladder.v rebuilt on the interleaving construction. The original
// composes three combinational blocks -- kscan, recip_wrap, grad_a_unit -- and
// measures 13.8 MHz out of context on a Kintex-7, against 138.7 MHz for the
// forward scan. Composing them is worse than any one alone, which is why the
// backward path was never integrated with the forward datapath.
//
//   kscan_inter    142.0 MHz    the recurrence, interleaved
//   grad_a_inter   137.5 MHz    the gradient, pipelined
//   recip_nr_pipe            already pipelined, II=1
//
// Structure. The engine runs four phases over a batch of NSLOT ladders:
//
//   SCAN   kscan_inter produces the full K[0..DEPTH] for every slot
//   RECIP  2*NSLOT issues through ONE reciprocal at II=1
//   GRAD   grad_a_inter streams NSLOT*DEPTH gradients at one per cycle
//
// The reciprocal is used twice per slot rather than duplicated. recip_nr_pipe
// computes k1/clamp_signed(k0), so (K0, K1) yields the forward output f and
// (K0, 1.0) yields rK0 = 1/clamp_signed(K0) for the gradient. At II=1 that is
// 2*NSLOT = 16 issues, which is cheaper than a second reciprocal and needs no
// new arithmetic verified.
//
// What makes the backward cheap is unchanged from train_ladder: the forward
// continuants are RETAINED by kscan_inter and reused, and one reciprocal serves
// both directions. Nothing is recomputed and no per-step state is stored beyond
// K itself.
//
// Results come back in issue order because the reciprocal is II=1 and never
// reorders, so an output counter is sufficient and no tag pipeline is needed.
//
// SCOPE. This engine computes df/da, the gradient with respect to the ladder
// COEFFICIENTS. Training also needs df/dW and df/dx, which are an outer product
// and a transposed GEMV over the p inputs, and by the same arithmetic accounting
// the paper applies to the forward path those dominate: grad_a is about 2% of a
// backward pass. They are not built here. Treating this engine as "the backward
// pass" would repeat exactly the error the paper already retracted once.

`include "cofr_defs.vh"

module train_ladder_inter #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter DEPTH   = `COFR_DEPTH,
    parameter NSLOT   = 8,
    parameter FMA_LAT = 5,
    parameter TBITS   = 12,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS,
    parameter SEED_FILE = "recip_seed_e8s24_t12.mem",
    parameter GATE    = 1
) (
    input                              clock,
    input                              nReset,
    input                              in_valid,
    output                             in_ready,
    input  [NSLOT*DEPTH*(EXP+SIG)-1:0] a_all,
    input  [NSLOT*(EXP+SIG)-1:0]       gout_all,
    output                             out_valid,
    output [NSLOT*(EXP+SIG)-1:0]       f_all,       // forward K1/clamp(K0)
    output [NSLOT*DEPTH*(EXP+SIG)-1:0] grad_a_all   // backward df/da
);
    localparam integer W      = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam integer SW     = (NSLOT < 2) ? 1 : $clog2(NSLOT);
    localparam integer OW     = $clog2(2*NSLOT + 1);
    localparam [2:0] S_IDLE  = 3'd0, S_SCAN = 3'd1, S_RECIP = 3'd2,
                     S_GRAD  = 3'd3, S_DONE = 3'd4;

    reg [2:0]  state;
    reg        scan_go, grad_go;
    reg [OW-1:0] icnt, ocnt;
    reg [W-1:0]  f_reg   [0:NSLOT-1];
    reg [W-1:0]  rK0_reg [0:NSLOT-1];
    reg [NSLOT*(EXP+SIG)-1:0] gout_reg;

    assign in_ready  = (state == S_IDLE);
    assign out_valid = (state == S_DONE);

    // ---- forward: the interleaved scan, retaining every continuant ---------
    wire                              scan_ready, scan_ovalid;
    wire [NSLOT*(DEPTH+1)*W-1:0]      Kv_all;
    kscan_inter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .NSLOT(NSLOT),
                  .FMA_LAT(FMA_LAT), .GATE(GATE)) u_scan (
        .clock(clock), .nReset(nReset),
        .in_valid(scan_go), .in_ready(scan_ready),
        .a_all(a_all), .out_valid(scan_ovalid), .Kv_all(Kv_all));

    // ---- one reciprocal, used twice per slot -------------------------------
    // Issues 0..NSLOT-1   : (K0, K1) -> f
    // Issues NSLOT..2N-1  : (K0, 1)  -> rK0
    wire [SW-1:0] isl = icnt[SW-1:0];
    wire [SW-1:0] isl2 = (icnt >= OW'(NSLOT)) ? (icnt - OW'(NSLOT)) : icnt;
    wire [31:0]   kbase = 32'(isl2) * (DEPTH + 1);
    wire [W-1:0]  k0_sel = Kv_all[kbase*W +: W];
    wire [W-1:0]  k1_sel = (icnt < OW'(NSLOT))
                         ? Kv_all[(kbase + 1)*W +: W]   // K1 -> f
                         : F_ONE;                       // 1  -> rK0

    wire rec_issue = (state == S_RECIP) && (icnt < OW'(2*NSLOT));
    wire rec_ready, rec_ovalid;
    wire [W-1:0] rec_out;
    recip_nr_pipe #(.EXP(EXP), .SIG(SIG), .TBITS(TBITS), .FMA_LAT(FMA_LAT),
                    .EPS(EPS), .SEED_FILE(SEED_FILE), .GATE(GATE)) u_recip (
        .clock(clock), .nReset(nReset), .inValid(rec_issue), .inReady(rec_ready),
        .k0(k0_sel), .k1(k1_sel), .outValid(rec_ovalid), .f(rec_out));

    // ---- backward: the streamed gradient -----------------------------------
    wire [NSLOT*W-1:0] rK0_flat;
    genvar g;
    generate
        for (g = 0; g < NSLOT; g = g + 1) begin : g_pack
            assign rK0_flat[g*W +: W] = rK0_reg[g];
            assign f_all[g*W +: W]    = f_reg[g];
        end
    endgenerate

    wire grad_ready, grad_ovalid;
    grad_a_inter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .NSLOT(NSLOT),
                   .FMA_LAT(FMA_LAT), .GATE(GATE)) u_grad (
        .clock(clock), .nReset(nReset),
        .in_valid(grad_go), .in_ready(grad_ready),
        .Kv_all(Kv_all), .rK0_all(rK0_flat), .gout_all(gout_reg),
        .out_valid(grad_ovalid), .grad_a_all(grad_a_all));

    // Which slot the retiring reciprocal belongs to. This needs its own wire:
    // Verilog has no bit-select of an expression, so (ocnt - NSLOT)[SW-1:0]
    // cannot be written inline as an array index.
    wire [OW-1:0] onorm = (ocnt >= OW'(NSLOT)) ? (ocnt - OW'(NSLOT)) : ocnt;
    wire [SW-1:0] osl   = onorm[SW-1:0];

    integer i;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; scan_go <= 1'b0; grad_go <= 1'b0;
            icnt <= '0; ocnt <= '0; gout_reg <= '0;
            for (i = 0; i < NSLOT; i = i + 1) begin
                f_reg[i] <= '0; rK0_reg[i] <= '0;
            end
        end else begin
            scan_go <= 1'b0;
            grad_go <= 1'b0;

            // Reciprocal results return in issue order, so the output counter
            // alone says where each belongs.
            if (rec_ovalid) begin
                if (ocnt < OW'(NSLOT)) f_reg[osl] <= rec_out;
                else rK0_reg[osl] <= rec_out;
                ocnt <= ocnt + OW'(1);
            end

            case (state)
                S_IDLE: if (in_valid) begin
                    gout_reg <= gout_all;
                    scan_go  <= 1'b1;
                    icnt <= '0; ocnt <= '0;
                    state <= S_SCAN;
                end
                S_SCAN: if (scan_ovalid) state <= S_RECIP;
                S_RECIP: begin
                    if (rec_issue && rec_ready) icnt <= icnt + OW'(1);
                    // Wait for every reciprocal to retire, not just to issue:
                    // grad_a_inter samples rK0 on its start pulse.
                    if (ocnt == OW'(2*NSLOT)) begin
                        grad_go <= 1'b1;
                        state   <= S_GRAD;
                    end
                end
                S_GRAD: if (grad_ovalid) state <= S_DONE;
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
