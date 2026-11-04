// rondo_cksum: output checksum (spec 10.5) and NaN/Inf scan over ZBUF.
//
// Serial walk over the WIDTH output words (one per cycle, WIDTH+1 cycles), or one cycle
// with PAR=1. At the end: acc' = rotl(acc,1) + sum_j rotl(z_j & mask, j mod 32) into either
// the main checksum or the private KAT signature, and the number of NaN/Inf elements of
// enabled lanes is reported with `done`.
module rondo_cksum #(
    parameter WIDTH   = 64,
    parameter N_LANES = 8,
    parameter PAR     = 0
) (
    input                    clk,
    input                    rst_n,
    input                    srst,             // synchronous clear (soft reset)
    input                    clr_main,         // clear CHECKSUM
    input                    clr_kat,          // clear the KAT signature
    input                    go,               // start a walk (ignored while busy)
    input                    upd_en,           // 1: update an accumulator, 0: scan only
    input                    kat_mode,         // update the KAT signature instead of CHECKSUM
    input  [WIDTH*32-1:0]    zbuf,
    input                    w16,              // 1: bf16 (16-bit elements)
    input  [N_LANES-1:0]     lane_en,
    output reg [31:0]        checksum,
    output reg [31:0]        ksig,
    output reg               busy,
    output reg               done,             // 1-cycle pulse
    output reg [15:0]        naninf_n          // NaN/Inf elements found (valid with done)
);
    localparam integer NLAD = WIDTH / N_LANES;
    localparam integer JW   = (WIDTH < 2) ? 1 : $clog2(WIDTH);

    function [31:0] rotl(input [31:0] v, input [4:0] r);
        reg [63:0] t;
        begin t = {v, v} << r; rotl = t[63:32]; end
    endfunction
    function is_ni(input [31:0] v, input w);
        is_ni = w ? (&v[14:7]) : (&v[30:23]);
    endfunction

    reg [JW-1:0] j;
    reg [31:0]   acc;
    reg [15:0]   nn;
    reg          upd_q, kat_q, w16_q;
    reg [N_LANES-1:0] en_q;

    wire [31:0] zj   = zbuf[j*32 +: 32];
    wire [31:0] zjm  = w16_q ? {16'd0, zj[15:0]} : zj;
    wire [31:0] term = rotl(zjm, 5'(j));
    wire [31:0] acc_nx = acc + term;
    wire        ni = is_ni(zj, w16_q) && en_q[32'(j) / NLAD];

    // parallel version
    reg [31:0] pacc;
    reg [15:0] pnn;
    integer pi;
    always @* begin
        pacc = 32'd0; pnn = 16'd0;
        for (pi = 0; pi < WIDTH; pi = pi + 1) begin
            pacc = pacc + rotl(w16 ? {16'd0, zbuf[pi*32 +: 16]} : zbuf[pi*32 +: 32], 5'(pi));
            if (is_ni(zbuf[pi*32 +: 32], w16) && lane_en[pi / NLAD]) pnn = pnn + 16'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            checksum <= 32'd0; ksig <= 32'd0; busy <= 1'b0; done <= 1'b0; naninf_n <= 16'd0;
            j <= {JW{1'b0}}; acc <= 32'd0; nn <= 16'd0; upd_q <= 1'b0; kat_q <= 1'b0; w16_q <= 1'b0;
            en_q <= {N_LANES{1'b1}};
        end else begin
            done <= 1'b0;
            if (srst || clr_main) checksum <= 32'd0;
            if (srst || clr_kat)  ksig <= 32'd0;
            if (srst) begin busy <= 1'b0; end
            else if (PAR != 0) begin
                if (go) begin
                    if (upd_en) begin
                        if (kat_mode) ksig <= rotl(ksig, 5'd1) + pacc;
                        else          checksum <= rotl(checksum, 5'd1) + pacc;
                    end
                    naninf_n <= pnn; done <= 1'b1;
                end
            end else begin
                if (go && !busy) begin
                    busy <= 1'b1; j <= {JW{1'b0}}; acc <= 32'd0; nn <= 16'd0;
                    upd_q <= upd_en; kat_q <= kat_mode; w16_q <= w16; en_q <= lane_en;
                end else if (busy) begin
                    acc <= acc_nx;
                    if (ni) nn <= nn + 16'd1;
                    if (j == JW'(WIDTH - 1)) begin
                        busy <= 1'b0; done <= 1'b1;
                        naninf_n <= nn + (ni ? 16'd1 : 16'd0);
                        if (upd_q) begin
                            if (kat_q) ksig <= rotl(ksig, 5'd1) + acc_nx;
                            else       checksum <= rotl(checksum, 5'd1) + acc_nx;
                        end
                    end else j <= j + 1'b1;
                end
            end
        end
    end
endmodule
