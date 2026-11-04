// rondo_mbist: March C- memory BIST over every H and L weight macro and bias store of every lane,
// through the rondo_wmem wrapper port (spec 11.6).
//   ⇕(w0); ⇑(r0,w1); ⇑(r1,w0); ⇓(r0,w1); ⇓(r1,w0); ⇕(r0)
// with data backgrounds all-0 / all-1, then 0x5555.. / 0xAAAA..  H and L halves are tested together (both
// compared on every read). Deviation from the spec text: lanes are tested one after another (one wrapper port),
// not in parallel.
module rondo_mbist #(
    parameter N_LANES = 8, NPAR = 8, NWORDS = 280, NBWORDS = 7,
    parameter WAW = 9, BAW = 3, LNW = 3
) (
    input                    clk,
    input                    rst_n,
    input                    srst,
    input                    start,
    // wrapper port of rondo_wmem
    output                   wp_en,
    output                   wp_we,
    output                   wp_bias,
    output [LNW-1:0]         wp_lane,
    output [WAW-1:0]         wp_addr,
    output [1:0]             wp_half,
    output [NPAR*16-1:0]     wp_wd_h,
    output [NPAR*16-1:0]     wp_wd_l,
    input  [NPAR*16-1:0]     wp_rd_h,
    input  [NPAR*16-1:0]     wp_rd_l,
    // status
    output                   running,
    output reg               done,              // 1-cycle pulse
    output                   pass_lvl,          // 1 until a run fails (MBIST_PASS)
    output reg               ev_fail,
    output reg               ev_wstale_set,
    output reg               ev_crc_clr,
    output reg               ev_inval,
    output [31:0]            status,
    output reg [31:0]        fail_addr,
    output reg [31:0]        fail_xor
);
    localparam integer DW = NPAR * 16;
    localparam [DW-1:0] BG0 = {DW{1'b0}}, BG1 = {(DW/16){16'h5555}};
    localparam [2:0] S_IDLE = 0, S_RD = 1, S_CMP = 2, S_WR = 3, S_NEXT = 4, S_END = 5;
    reg [2:0]  st;
    reg        bgi, kind;                   // kind 1 = bias store
    reg [LNW-1:0] lane;
    reg [2:0]  e;                           // march element
    reg [WAW-1:0] addr;
    reg        done_lvl;
    reg [31:0] fcount;
    reg        failed;
    reg [LNW-1:0] f_lane; reg f_half, f_kind; reg [3:0] f_elem;
    reg        run_ok;                      // pass of the last completed run

    wire [DW-1:0] bg   = bgi ? BG1 : BG0;
    wire [DW-1:0] nbg  = ~bg;
    wire [WAW-1:0] last = kind ? WAW'(NBWORDS - 1) : WAW'(NWORDS - 1);
    wire down = (e == 3'd3) || (e == 3'd4);
    wire do_rd = (e != 3'd0);
    wire do_wr = (e != 3'd5);
    wire [DW-1:0] exp_d = (e == 3'd1 || e == 3'd3 || e == 3'd5) ? bg : nbg;
    wire [DW-1:0] wr_d  = (e == 3'd0 || e == 3'd2 || e == 3'd4) ? bg : nbg;

    assign running  = (st != S_IDLE);
    assign pass_lvl = run_ok;
    assign wp_en    = (st == S_RD) || (st == S_WR);
    assign wp_we    = (st == S_WR);
    assign wp_bias  = kind;
    assign wp_lane  = lane;
    assign wp_addr  = addr;
    assign wp_half  = 2'b11;
    assign wp_wd_h  = wr_d;
    assign wp_wd_l  = wr_d;
    assign status   = {fcount[15:0], 3'd0, f_elem, f_kind, f_half, 3'(f_lane), 1'b0, failed, done_lvl, running};

    wire [DW-1:0] xh = wp_rd_h ^ exp_d;
    wire [DW-1:0] xl = wp_rd_l ^ exp_d;
    function [31:0] fold(input [DW-1:0] v);
        integer i; reg [31:0] r;
        begin r = 32'd0; for (i = 0; i < DW; i = i + 32) r = r ^ v[i +: 32]; fold = r; end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; bgi <= 1'b0; kind <= 1'b0; lane <= '0; e <= 3'd0; addr <= '0; done <= 1'b0;
            fcount <= 32'd0; failed <= 1'b0; done_lvl <= 1'b0; run_ok <= 1'b1; fail_addr <= 32'd0; fail_xor <= 32'd0;
            f_lane <= '0; f_half <= 1'b0; f_kind <= 1'b0; f_elem <= 4'd0; ev_fail <= 1'b0; ev_wstale_set <= 1'b0;
            ev_crc_clr <= 1'b0; ev_inval <= 1'b0;
        end else begin
            done <= 1'b0; ev_fail <= 1'b0; ev_wstale_set <= 1'b0; ev_crc_clr <= 1'b0; ev_inval <= 1'b0;
            if (srst) begin st <= S_IDLE; end
            else case (st)
                S_IDLE: if (start) begin
                    st <= S_WR; bgi <= 1'b0; kind <= 1'b0; lane <= '0; e <= 3'd0; addr <= '0;
                    fcount <= 32'd0; failed <= 1'b0; done_lvl <= 1'b0; fail_addr <= 32'd0; fail_xor <= 32'd0;
                    ev_wstale_set <= 1'b1; ev_crc_clr <= 1'b1; ev_inval <= 1'b1;
                end
                S_RD: st <= S_CMP;
                S_CMP: begin
                    if (xh != 0 || xl != 0) begin
                        if (fcount != 32'hFFFF) fcount <= fcount + 32'd1;
                        if (!failed) begin
                            failed <= 1'b1; f_lane <= lane; f_kind <= kind; f_half <= (xh == 0);
                            f_elem <= {1'b0, e} + (bgi ? 4'd6 : 4'd0); fail_addr <= {16'd0, 16'(addr)};
                            fail_xor <= fold(xh != 0 ? xh : xl); ev_fail <= 1'b1;
                        end
                    end
                    st <= do_wr ? S_WR : S_NEXT;
                end
                S_WR: st <= S_NEXT;
                S_NEXT: begin
                    // advance the address / element / memory / lane / background
                    if ((!down && addr == last) || (down && addr == '0)) begin
                        if (e == 3'd5) begin
                            e <= 3'd0;
                            if (kind == 1'b0) begin kind <= 1'b1; addr <= '0; st <= S_WR; end
                            else begin
                                kind <= 1'b0;
                                if (lane == LNW'(N_LANES - 1)) begin
                                    lane <= '0;
                                    if (bgi) st <= S_END; else begin bgi <= 1'b1; addr <= '0; st <= S_WR; end
                                end else begin lane <= lane + 1'b1; addr <= '0; st <= S_WR; end
                            end
                        end else begin
                            e <= e + 3'd1;
                            if (e + 3'd1 == 3'd3 || e + 3'd1 == 3'd4) addr <= last;      // down elements start at the top
                            else addr <= '0;
                            st <= (e + 3'd1 != 3'd0) ? S_RD : S_WR;
                        end
                    end else begin
                        addr <= down ? addr - 1'b1 : addr + 1'b1;
                        st <= do_rd ? S_RD : S_WR;
                    end
                end
                S_END: begin
                    st <= S_IDLE; done <= 1'b1; done_lvl <= 1'b1; run_ok <= !failed;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
