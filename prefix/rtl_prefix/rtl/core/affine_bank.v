// affine_bank: the coefficient generator for a bank of ladders.
//
// a[j][k] = W[j][k] . x + bias[j][k]  for ladder j, level k.
//
// This is `affine_unit` widened from one ladder to NLAD of them. The MAC chain,
// the accumulation order and the bias handling are copied unchanged, so the
// 0-ULP result recorded for affine_unit in docs/FUSION.md still describes the
// arithmetic here; only the addressing is new.
//
// Why it matters. Until now the RTL was fed coefficients `a` directly, which
// skipped the affine stage entirely -- and that stage is ~98% of a CoFrNet
// layer's arithmetic (2*d*p FLOP against the ladder's 12). A design that takes
// `a` as an input is a ladder engine, not an accelerator. This is the piece that
// makes the whole layer run from x.
//
// Weights and biases live in BRAM-shaped memories, loaded once through the
// w_*/b_* ports. They are stationary, which is the entire reason fusion saves
// traffic: x is shared across the bank while W is not.
//
// Biases are read into a small register file in a DEPTH-cycle prologue rather
// than looked up in the MAC loop. The loop needs bias[k+1] on the same cycle it
// retires level k, which a synchronous memory read cannot supply in time; a
// prologue of DEPTH cycles against DEPTH*CHUNKS of MAC work is negligible and
// keeps the inner loop identical to affine_unit's.

`include "cofr_defs.vh"

module affine_bank #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter PDIM  = 8,                       // input dimensionality p
    parameter NMAC  = 1,                       // MACs per cycle
    parameter NLAD  = 8,                       // ladders whose weights are resident
    parameter CHUNKS = (PDIM + NMAC - 1) / NMAC,
    parameter NWORDS = NLAD * DEPTH * CHUNKS,
    parameter WAW    = (NWORDS < 2) ? 1 : $clog2(NWORDS),
    parameter NBIAS  = NLAD * DEPTH,
    parameter BAW    = (NBIAS < 2) ? 1 : $clog2(NBIAS),
    parameter LADW   = (NLAD < 2) ? 1 : $clog2(NLAD)
) (
    input                          clock,
    input                          nReset,
    // weight / bias load
    input                          w_we,
    input  [WAW-1:0]               w_addr,
    input  [NMAC*(EXP+SIG)-1:0]    w_din,
    input                          b_we,
    input  [BAW-1:0]               b_addr,
    input  [(EXP+SIG)-1:0]         b_din,
    // compute
    input                          in_valid,
    output                         in_ready,
    input  [LADW-1:0]              lad,        // which resident ladder
    input  [PDIM*(EXP+SIG)-1:0]    x,
    output                         out_valid,
    output [DEPTH*(EXP+SIG)-1:0]   a
);
    localparam integer W    = EXP + SIG;
    localparam integer XPAD = CHUNKS * NMAC;
    localparam integer KW   = (DEPTH  < 2) ? 1 : $clog2(DEPTH);
    localparam integer CW   = (CHUNKS < 2) ? 1 : $clog2(CHUNKS);
    localparam [2:0] S_IDLE = 3'd0, S_BLOAD = 3'd1, S_BSTART = 3'd2,
                     S_MAC = 3'd3, S_DONE = 3'd4;

    reg [NMAC*W-1:0] w_mem [0:NWORDS-1];
    reg [W-1:0]      b_mem [0:NBIAS-1];
    reg [NMAC*W-1:0] w_word;
    reg [W-1:0]      b_word;

    reg [2:0]         state;
    reg [KW-1:0]      k;
    reg [CW-1:0]      c;
    reg [W-1:0]       acc;
    reg [DEPTH*W-1:0] a_reg;
    reg [XPAD*W-1:0]  x_reg;
    reg [DEPTH*W-1:0] bias_reg;
    reg [LADW-1:0]    lad_reg;
    reg [KW:0]        bk;                       // bias prologue counter
    reg               ovalid_r;

    assign in_ready  = (state == S_IDLE);
    assign out_valid = ovalid_r;
    assign a         = a_reg;

    wire [31:0] k32   = 32'(k);
    wire [31:0] c32   = 32'(c);
    wire [31:0] lad32 = 32'(lad_reg);
    wire [31:0] base  = lad32 * DEPTH * CHUNKS;

    wire        lastc_w = (c == CW'(CHUNKS - 1));
    wire        lastk_w = (k == KW'(DEPTH - 1));
    wire [31:0] nc = lastc_w ? 32'd0 : (c32 + 32'd1);
    wire [31:0] nk = lastc_w ? (lastk_w ? 32'd0 : (k32 + 32'd1)) : k32;
    // During the prologue hold the read at this ladder's first word, so it is
    // registered before S_MAC begins; the lookahead only applies inside S_MAC.
    wire [31:0] rd = (state == S_MAC) ? (base + (nk * CHUNKS) + nc) : base;

    // bias read address: the prologue walks k = 0..DEPTH-1 for this ladder
    wire [31:0] brd = (lad32 * DEPTH) + 32'(bk);

    always @(posedge clock) begin
        if (w_we) w_mem[w_addr] <= w_din;
        if (b_we) b_mem[b_addr] <= b_din;
        w_word <= w_mem[rd[WAW-1:0]];
        b_word <= b_mem[brd[BAW-1:0]];
    end

    wire [W-1:0] chain [0:NMAC];
    assign chain[0] = acc;
    genvar m;
    generate
        for (m = 0; m < NMAC; m = m + 1) begin : g_mac
            wire [W-1:0] xm = x_reg[((c32 * NMAC) + m) * W +: W];
            fp_fma #(.EXP(EXP), .SIG(SIG)) u_mac (
                .a(w_word[m * W +: W]), .b(xm), .c(chain[m]), .p(chain[m + 1])
            );
        end
    endgenerate
    wire [W-1:0] mac = chain[NMAC];

    integer q;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; k <= '0; c <= '0; acc <= '0; bk <= '0;
            a_reg <= '0; ovalid_r <= 1'b0; lad_reg <= '0; bias_reg <= '0;
        end else begin
            ovalid_r <= 1'b0;
            case (state)
                S_IDLE: if (in_valid) begin
                    x_reg <= '0;
                    for (q = 0; q < PDIM; q = q + 1)
                        x_reg[q * W +: W] <= x[q * W +: W];   // tail stays zero
                    lad_reg <= lad;
                    bk      <= '0;
                    state   <= S_BLOAD;
                end
                // Prologue: pull this ladder's DEPTH biases into registers. The
                // memory read is one cycle behind brd, so bias[i] lands while
                // bk = i+1, hence the guard.
                S_BLOAD: begin
                    if (bk > 0)
                        bias_reg[(32'(bk) - 32'd1) * W +: W] <= b_word;
                    if (32'(bk) == DEPTH) state <= S_BSTART;
                    else                  bk    <= bk + 1'b1;
                end
                // Separate cycle so every bias is latched before acc reads
                // bias_reg[0]; folding it into S_BLOAD breaks at DEPTH = 1.
                S_BSTART: begin
                    k <= '0; c <= '0;
                    acc   <= bias_reg[0 +: W];
                    state <= S_MAC;
                end
                S_MAC: begin
                    if (lastc_w) begin
                        a_reg[k32 * W +: W] <= mac;
                        c <= '0;
                        if (lastk_w) begin
                            state <= S_DONE;
                        end else begin
                            k   <= k + KW'(1);
                            acc <= bias_reg[(k32 + 32'd1) * W +: W];
                        end
                    end else begin
                        acc <= mac;
                        c   <= c + CW'(1);
                    end
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
