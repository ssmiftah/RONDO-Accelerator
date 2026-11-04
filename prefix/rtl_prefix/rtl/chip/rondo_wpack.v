// rondo_wpack: element-wise weight/bias writes -> core-word commits, read cache, LOAD_CRC
// (spec 7.5, 7.6). One element per accepted write (bits [W-1:0] of the bus word, W by fmt).
// Staging: stg[NPAR], msk[NPAR], tag {region, lane, caddr}. The ascending burst of
// spec 5.5 fills a core word and commits it when field NPAR-1 arrives.
module rondo_wpack #(
    parameter N_LANES = 8,
    parameter NPAR    = 8,
    parameter NWORDS  = 280,
    parameter NBWORDS = 7,
    parameter WAW     = (NWORDS  < 2) ? 1 : $clog2(NWORDS),
    parameter BAW     = (NBWORDS < 2) ? 1 : $clog2(NBWORDS),
    parameter LNW     = (N_LANES < 2) ? 1 : $clog2(N_LANES),
    parameter FW      = (NPAR < 2) ? 1 : $clog2(NPAR)
) (
    input                    clk,
    input                    rst_n,
    input                    fmt,               // 0 bf16, 1 fp32
    // accepted accesses (decoded by rondo_dev; ranges already checked)
    input                    wr_stb,
    input                    rd_stb,
    input                    region_bias,
    input  [LNW-1:0]         lane,
    input  [WAW-1:0]         caddr,
    input  [FW-1:0]          field,
    input  [31:0]            wdata,
    output reg               rd_valid,          // 1-cycle pulse, rd_data valid
    output reg [31:0]        rd_data,
    output reg               err_partial,       // 1-cycle pulse
    output                   busy,              // a commit or read is in flight
    // rondo_wmem wrapper port
    output reg               wp_en,
    output reg               wp_we,
    output reg               wp_bias,
    output reg [LNW-1:0]     wp_lane,
    output reg [WAW-1:0]     wp_addr,
    output reg [1:0]         wp_half,
    output reg [NPAR*16-1:0] wp_wd_h,
    output reg [NPAR*16-1:0] wp_wd_l,
    input  [NPAR*16-1:0]     wp_rd_h,
    input  [NPAR*16-1:0]     wp_rd_l,
    // load CRC
    input                    crc_clr,
    output [31:0]            load_crc,
    output reg               wr_done,           // 1-cycle pulse per accepted write (WSTALE clear)
    input                    cache_inval,
    input                    flush_staging
);
    reg [31:0]     stg [0:NPAR-1];
    reg [NPAR-1:0] msk;
    reg            t_bias;
    reg [LNW-1:0]  t_lane;
    reg [WAW-1:0]  t_addr;
    reg            have_tag;

    // ---- LOAD_CRC: CRC-32 (reflected 0xEDB88320) over the W/8 LSB-first bytes ------------
    reg [31:0] crc_r;
    function [31:0] crc_byte(input [31:0] c, input [7:0] b);
        integer i;
        reg [31:0] r;
        begin
            r = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1) r = r[0] ? ((r >> 1) ^ 32'hEDB88320) : (r >> 1);
            crc_byte = r;
        end
    endfunction
    wire [31:0] crc_2 = crc_byte(crc_byte(crc_r, wdata[7:0]), wdata[15:8]);
    wire [31:0] crc_4 = crc_byte(crc_byte(crc_2, wdata[23:16]), wdata[31:24]);
    assign load_crc = crc_r ^ 32'hFFFFFFFF;

    // ---- read cache -----------------------------------------------------------------------
    reg                   c_valid, c_bias;
    reg [LNW-1:0]         c_lane;
    reg [WAW-1:0]         c_addr;
    reg [NPAR*16-1:0]     c_h, c_l;

    // ---- commit / read engine --------------------------------------------------------------
    localparam [2:0] R_IDLE = 3'd0, R_WAIT = 3'd2, R_CAP = 3'd4, R_OUT = 3'd3;
    reg [2:0]          rs;
    reg                commit_q;
    reg [FW-1:0]       r_field;
    reg                rd_pend;
    reg                rq_bias;
    reg [LNW-1:0]      rq_lane;
    reg [WAW-1:0]      rq_addr;
    assign busy = commit_q | (rs != R_IDLE) | rd_pend;

    wire tag_match = have_tag && (t_bias == region_bias) && (t_lane == lane) && (t_addr == caddr);

    integer i;
    reg [NPAR*16-1:0] nh, nl;
    reg [NPAR-1:0]    nmsk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msk <= {NPAR{1'b0}}; have_tag <= 1'b0; t_bias <= 1'b0; t_lane <= {LNW{1'b0}};
            t_addr <= {WAW{1'b0}}; crc_r <= 32'hFFFFFFFF; c_valid <= 1'b0; rs <= R_IDLE;
            commit_q <= 1'b0; wp_en <= 1'b0; wp_we <= 1'b0; wp_bias <= 1'b0; wp_lane <= {LNW{1'b0}};
            wp_addr <= {WAW{1'b0}}; wp_half <= 2'b00; wp_wd_h <= {NPAR*16{1'b0}}; wp_wd_l <= {NPAR*16{1'b0}};
            rd_valid <= 1'b0; rd_data <= 32'd0; err_partial <= 1'b0; wr_done <= 1'b0; rd_pend <= 1'b0;
            c_bias <= 1'b0; c_lane <= {LNW{1'b0}}; c_addr <= {WAW{1'b0}}; c_h <= {NPAR*16{1'b0}};
            c_l <= {NPAR*16{1'b0}}; r_field <= {FW{1'b0}}; rq_bias <= 1'b0; rq_lane <= {LNW{1'b0}};
            rq_addr <= {WAW{1'b0}};
            for (i = 0; i < NPAR; i = i + 1) stg[i] <= 32'd0;
        end else begin
            rd_valid <= 1'b0; err_partial <= 1'b0; wr_done <= 1'b0; wp_en <= 1'b0; wp_we <= 1'b0;
            commit_q <= 1'b0;
            if (crc_clr) crc_r <= 32'hFFFFFFFF;
            if (cache_inval) c_valid <= 1'b0;
            if (flush_staging) begin msk <= {NPAR{1'b0}}; have_tag <= 1'b0; end

            // ---- writes -------------------------------------------------------------------
            if (wr_stb) begin
                wr_done <= 1'b1;
                crc_r   <= fmt ? crc_4 : crc_2;
                c_valid <= 1'b0;
                nmsk = msk;
                if (msk != {NPAR{1'b0}} && !tag_match) begin
                    err_partial <= 1'b1;
                    nmsk = {NPAR{1'b0}};
                    for (i = 0; i < NPAR; i = i + 1) stg[i] <= 32'd0;
                end
                // note: nmsk cleared => stale stg words must read as 0 in the commit below
                stg[field] <= fmt ? wdata : {16'd0, wdata[15:0]};
                nmsk[field] = 1'b1;
                t_bias <= region_bias; t_lane <= lane; t_addr <= caddr; have_tag <= 1'b1;
                if (field == FW'(NPAR - 1)) begin
                    // commit the core word (missing fields 0)
                    for (i = 0; i < NPAR; i = i + 1) begin
                        if (i == NPAR - 1) begin
                            nh[i*16 +: 16] = fmt ? wdata[31:16] : wdata[15:0];
                            nl[i*16 +: 16] = fmt ? wdata[15:0] : 16'd0;
                        end else if (nmsk[i] && !(msk != {NPAR{1'b0}} && !tag_match)) begin
                            nh[i*16 +: 16] = fmt ? stg[i][31:16] : stg[i][15:0];
                            nl[i*16 +: 16] = fmt ? stg[i][15:0] : 16'd0;
                        end else begin
                            nh[i*16 +: 16] = 16'd0; nl[i*16 +: 16] = 16'd0;
                        end
                    end
                    if (nmsk != {NPAR{1'b1}}) err_partial <= 1'b1;
                    wp_wd_h <= nh; wp_wd_l <= nl;
                    wp_bias <= region_bias; wp_lane <= lane; wp_addr <= caddr;
                    wp_half <= fmt ? 2'b11 : 2'b01;
                    commit_q <= 1'b1;
                    nmsk = {NPAR{1'b0}};
                end
                msk <= nmsk;
            end
            if (commit_q) begin wp_en <= 1'b1; wp_we <= 1'b1; end

            // ---- reads ----------------------------------------------------------------------
            if (rd_stb && !rd_pend && rs == R_IDLE) begin
                rd_pend <= 1'b1; r_field <= field; rq_bias <= region_bias; rq_lane <= lane; rq_addr <= caddr;
            end
            case (rs)
                R_IDLE: if (rd_pend && !commit_q && !wr_stb) begin
                    if (c_valid && c_bias == rq_bias && c_lane == rq_lane && c_addr == rq_addr) rs <= R_OUT;
                    else begin
                        wp_en <= 1'b1; wp_we <= 1'b0; wp_bias <= rq_bias; wp_lane <= rq_lane;
                        wp_addr <= rq_addr; wp_half <= fmt ? 2'b11 : 2'b01;
                        rs <= R_WAIT;
                    end
                end
                R_WAIT: rs <= R_CAP;      // wp_en cycle: the SRAM samples the address
                R_CAP: begin              // wmem q is valid now
                    c_h <= wp_rd_h; c_l <= wp_rd_l; c_valid <= 1'b1;
                    c_bias <= rq_bias; c_lane <= rq_lane; c_addr <= rq_addr;
                    rs <= R_OUT;
                end
                R_OUT: begin
                    rd_valid <= 1'b1;
                    rd_data  <= fmt ? {c_h[r_field*16 +: 16], c_l[r_field*16 +: 16]}
                                    : {16'd0, c_h[r_field*16 +: 16]};
                    rd_pend  <= 1'b0; rs <= R_IDLE;
                end
                default: rs <= R_IDLE;
            endcase
        end
    end
endmodule
