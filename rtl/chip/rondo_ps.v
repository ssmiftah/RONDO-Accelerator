// rondo_ps: partial-sum store for input tiling (spec 18.3, C8).
//
// Per lane an H and an L macro (rondo_sram_sp) of depth 2^TBW * 2^BAW and width NPAR*16, exactly
// like the weight store: entry {b, g} holds the NPAR partial sums of chain group g for tile
// input b. bf16 (AW 16) uses H only, fp32 (AW 32) uses element f = {H[f], L[f]}.
// Ports on each SRAM (single port): layer save (ps_we) > layer restore read (rd_en & mem_act)
// > host access. The host is blocked by rondo_dev while the chip is ACTIVE, so the three never
// collide in a legal run.
// Host element access (memory map 0x06xxxx): read = one SRAM read; write = read-modify-write of
// one 16-bit (bf16) or 32-bit (fp32) field.
module rondo_ps #(
    parameter N_LANES = 8,
    parameter NPAR    = 8,
    parameter BAW     = 6,
    parameter TBW     = 3,
    parameter LNW     = (N_LANES < 2) ? 1 : $clog2(N_LANES),
    parameter FW      = (NPAR < 2) ? 1 : $clog2(NPAR)
) (
    input                          clk,
    input                          rst_n,
    input                          fmt,                 // 0 bf16, 1 fp32
    input  [TBW-1:0]               b_cur,               // tile input being processed
    // layer side
    input  [N_LANES*BAW-1:0]       bm_addr,
    input  [N_LANES-1:0]           mem_act,
    input                          rd_en,               // seed mode 2 in progress
    output [N_LANES*NPAR*16-1:0]   q_h,
    output [N_LANES*NPAR*16-1:0]   q_l,
    input  [N_LANES-1:0]           ps_we,
    input  [N_LANES*BAW-1:0]       ps_waddr,
    input  [N_LANES*NPAR*16-1:0]   wd_h,
    input  [N_LANES*NPAR*16-1:0]   wd_l,
    // host element port
    input                          h_rd,
    input                          h_wr,
    input  [TBW-1:0]               h_b,
    input  [LNW-1:0]               h_l,
    input  [BAW-1:0]               h_g,
    input  [FW-1:0]                h_f,
    input  [31:0]                  h_wdata,
    output reg                     h_done,              // 1-cycle pulse: read data valid / write committed
    output reg [31:0]              h_rdata,
    output                         h_busy
);
    localparam integer DEPTH = (1 << TBW) * (1 << BAW);
    localparam [1:0] H_IDLE = 2'd0, H_RD = 2'd1, H_CAP = 2'd2, H_WR = 2'd3;
    reg [1:0]       hs;
    reg             hq_wr;
    reg [TBW-1:0]   hq_b;
    reg [LNW-1:0]   hq_l;
    reg [BAW-1:0]   hq_g;
    reg [FW-1:0]    hq_f;
    reg [31:0]      hq_d;
    reg [NPAR*16-1:0] nh, nl;
    assign h_busy = (hs != H_IDLE);

    wire [N_LANES*NPAR*16-1:0] qh_i, ql_i;
    assign q_h = qh_i;
    assign q_l = ql_i;

    wire host_acc = (hs == H_RD) || (hs == H_WR);
    genvar l;
    generate
        for (l = 0; l < N_LANES; l = l + 1) begin : lane
            wire lay_w = ps_we[l];
            wire lay_r = rd_en & mem_act[l] & ~ps_we[l];
            wire lay   = lay_w | lay_r;
            wire hsel  = host_acc & (hq_l == l);
            wire [TBW+BAW-1:0] a_lay = lay_w ? {b_cur, ps_waddr[l*BAW +: BAW]} : {b_cur, bm_addr[l*BAW +: BAW]};
            wire [TBW+BAW-1:0] a_hst = {hq_b, hq_g};
            wire [TBW+BAW-1:0] a     = lay ? a_lay : a_hst;
            wire en_h = lay | hsel;
            wire en_l = ((lay) & fmt) | (hsel & fmt);
            wire we_h = lay_w | (hsel & (hs == H_WR));
            wire we_l = (lay_w & fmt) | (hsel & (hs == H_WR) & fmt);
            wire [NPAR*16-1:0] d_h = lay_w ? wd_h[l*NPAR*16 +: NPAR*16] : nh;
            wire [NPAR*16-1:0] d_l = lay_w ? wd_l[l*NPAR*16 +: NPAR*16] : nl;
            rondo_sram_sp #(.DEPTH(DEPTH), .WIDTH(NPAR*16)) u_h (.clk(clk), .en(en_h), .we(we_h), .addr(a),
                .d(d_h), .q(qh_i[l*NPAR*16 +: NPAR*16]));
            rondo_sram_sp #(.DEPTH(DEPTH), .WIDTH(NPAR*16)) u_l (.clk(clk), .en(en_l), .we(we_l), .addr(a),
                .d(d_l), .q(ql_i[l*NPAR*16 +: NPAR*16]));
        end
    endgenerate

    wire [NPAR*16-1:0] sel_h = qh_i[hq_l*NPAR*16 +: NPAR*16];
    wire [NPAR*16-1:0] sel_l = ql_i[hq_l*NPAR*16 +: NPAR*16];
    wire [15:0] eh = sel_h[hq_f*16 +: 16];
    wire [15:0] el = sel_l[hq_f*16 +: 16];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs <= H_IDLE; hq_wr <= 1'b0; hq_b <= {TBW{1'b0}}; hq_l <= {LNW{1'b0}}; hq_g <= {BAW{1'b0}};
            hq_f <= {FW{1'b0}}; hq_d <= 32'd0; h_done <= 1'b0; h_rdata <= 32'd0;
            nh <= {NPAR*16{1'b0}}; nl <= {NPAR*16{1'b0}};
        end else begin
            h_done <= 1'b0;
            case (hs)
                H_IDLE: if (h_rd | h_wr) begin
                    hq_wr <= h_wr; hq_b <= h_b; hq_l <= h_l; hq_g <= h_g; hq_f <= h_f; hq_d <= h_wdata;
                    hs <= H_RD;
                end
                H_RD: hs <= H_CAP;                            // SRAM read issued this cycle
                H_CAP: begin                                  // read data valid
                    if (hq_wr) begin
                        nh <= sel_h; nl <= sel_l;
                        if (fmt) begin
                            nh[hq_f*16 +: 16] <= hq_d[31:16];
                            nl[hq_f*16 +: 16] <= hq_d[15:0];
                        end else begin
                            nh[hq_f*16 +: 16] <= hq_d[15:0];
                        end
                        hs <= H_WR;
                    end else begin
                        h_rdata <= fmt ? {eh, el} : {16'd0, eh};
                        h_done <= 1'b1; hs <= H_IDLE;
                    end
                end
                H_WR: begin h_done <= 1'b1; hs <= H_IDLE; end
                default: hs <= H_IDLE;
            endcase
        end
    end
endmodule
