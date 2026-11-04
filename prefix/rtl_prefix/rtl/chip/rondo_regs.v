// rondo_regs: control/status register file (spec 6, 18.5).
//
// Access interface: one strobe per access (reg_re / reg_we with reg_idx and reg_wdata);
// reg_rdata is combinational from the register state for the addressed idx. Read side
// effects: a *_LO read copies the pair's HI half into its shadow on the strobe.
// Commands written to CTRL appear as 1-cycle pulses one cycle later (priority resolved here).
module rondo_regs #(
    parameter WIDTH = 64, PDIM = 40, DEPTH = 7, N_LANES = 8, NSLOT = 8, NPAR = 8,
    parameter NXBUF = 4, WAW = 9, BAW = 3, LNW = 3,
    parameter ACCSIG_BF16 = 8, FMA_LAT = 5, TBITS_BF16 = 6, TBITS_FP32 = 8,
    parameter NR_ITERS_BF16 = 1, NR_ITERS_FP32 = 2,
    parameter HAS_BF16 = 1, HAS_FP32 = 1, LAYER = 0, CKSUM_PAR = 0,
    parameter DBG = 1, TRACE = 1, KAT = 1, MBIST = 0, SCAN = 0, SPI_CRC = 1, CLK_ALT = 1, PG = 0,
    parameter TILE = 1, TILE_B = 8, AW_BF16 = 16, AW_FP32 = 32,
    parameter HB_BIT = 24,
    parameter XPW = (NXBUF < 2) ? 1 : $clog2(NXBUF)
) (
    input                  clk,
    input                  rst_n,                 // sys_rst_n
    input                  srst,                  // soft reset in progress
    // access
    input                  reg_re,
    input                  reg_we,
    input  [7:0]           reg_idx,
    input  [31:0]          reg_wdata,
    output reg [31:0]      reg_rdata,
    // errors in (pulses)
    input  [15:0]          err_in,
    // status in
    input                  active,
    input                  busy,
    input                  sr_running, sr_stopping, zvalid,
    input                  fmt_applied,
    input  [3:0]           xptr_status,
    input  [N_LANES-1:0]   lane_en_applied,
    input                  kat_running, mbist_running, trc_armed,
    input                  wstale_clr,
    input                  wstale_set,
    // event pulses -> IRQ_STATUS
    input                  ev_done, ev_sr_done, ev_trc_done, ev_selftest_done, ev_tile_slice, ev_tile_final,
    // values in
    input  [31:0]          last_cycles,
    input  [63:0]          infer_cnt, busy_cyc, total_cyc, sr_cyc,
    input  [31:0]          sr_done_cnt, checksum, sr_pass_cksum, load_crc, guard_hits, naninf_cnt,
    input  [31:0]          dbg_data,
    input  [31:0]          trc_status,
    input  [31:0]          st_status, kat_sig_bf16, kat_sig_fp32, kat_got_bf16, kat_got_fp32,
    input  [31:0]          mbist_status, mbist_fail_addr, mbist_fail_xor,
    input  [31:0]          tile_status, tile_seq_crc,
    input  [1:0]           div_applied,
    input                  src_applied_in,
    input                  frame_end,
    input                  tile_open,
    input                  tile_slice_clr,     // the tile sequence closed: TILE_SLICE returns to 0
    // config out
    output reg             fmt_set,
    output reg             fmt_val,
    output reg [XPW-1:0]   xsel,
    output reg [7:0]       sr_n,
    output reg [31:0]      sr_count, wdog_limit,
    output reg [N_LANES-1:0] lane_en,
    output reg [1:0]       clk_div,
    output reg             clk_src,
    output reg [3:0]       clkout_k,
    output reg             pwr_core_hold, pwr_clk_off, pwr_pg_inactive,
    output reg             spi_crc_en,
    output reg [25:0]      dbg_sel,
    output reg             dbg_latch,
    output reg [31:0]      trc_cfg, trc_trig_cyc,
    output reg [31:0]      tile_cfg, tile_slice,
    output reg             tile_slice_wr,
    // commands out
    output reg             cmd_start, cmd_soft_rst, cmd_sr_start, cmd_sr_stop, cmd_cnt_clr, cmd_cksum_clr,
    output reg             cmd_crc_clr, cmd_kat_start, cmd_mbist_start, cmd_trc_arm, cmd_trc_force,
    output reg             cmd_guard_clr, cmd_tile_run, cmd_tile_abort,
    // pins / status
    output reg             irq,
    output reg [7:0]       status8,
    output reg             acc_err,
    output                 err_any,
    output [31:0]          status_o,
    output [31:0]          err_status_o,
    output [31:0]          irq_status_o,
    output [31:0]          irq_en_o,
    output [31:0]          shd0_o
);
    function b1(input v); b1 = v; endfunction
    localparam [31:0] CAPS_V = {14'd0, b1(TILE != 0), b1(PG != 0), b1(CLK_ALT != 0), b1(SPI_CRC != 0), b1(LAYER == 0), b1(SCAN != 0),
        b1(MBIST != 0), b1(KAT != 0), b1(TRACE != 0), b1(DBG != 0 && LAYER == 0), b1(LAYER == 0), b1(CKSUM_PAR != 0), b1(LAYER == 0),
        1'b1, b1(LAYER != 0), 1'b0, b1(HAS_FP32), b1(HAS_BF16)};
    localparam [31:0] GEOM0 = {PDIM[15:0], WIDTH[15:0]};
    localparam [31:0] GEOM1 = {NPAR[7:0], NSLOT[7:0], N_LANES[7:0], DEPTH[7:0]};
    localparam [31:0] GEOM2 = {LNW[7:0], BAW[7:0], WAW[7:0], NXBUF[7:0]};
    localparam [31:0] GEOM3 = {NR_ITERS_FP32[3:0], NR_ITERS_BF16[3:0], TBITS_FP32[3:0], TBITS_BF16[3:0],
                               FMA_LAT[7:0], ACCSIG_BF16[7:0]};
    localparam [31:0] TGEOM = {8'd0, AW_FP32[7:0], AW_BF16[7:0], TILE_B[7:0]};
    localparam [N_LANES-1:0] ALL_LANES = {N_LANES{1'b1}};
    localparam [31:0] ERR_MASK_RST = 32'hFFFFFDFF;
    localparam [31:0] TBMAX = (TILE_B < 1) ? 32'd1 : TILE_B;

    // error bit positions (spec 6.5)
    localparam E_BUSY_WR = 0, E_ADDR = 1, E_RO = 2, E_START_BUSY = 3, E_RANGE = 5, E_TILE_SEQ = 14;

    reg [31:0] scratch, irq_en, err_mask, err_status, irq_status;
    reg        clk_pend;
    reg [4:0]  clk_cfg_q;
    reg [31:0] shd [0:3];
    reg [31:0] hb_cnt;
    reg        wstale;

    assign err_any      = |(err_status & err_mask);
    assign err_status_o = err_status;
    assign irq_en_o = irq_en;
    assign shd0_o = shd[0];
    assign irq_status_o = {25'd0, irq_status[6:3], err_any, irq_status[1:0]};
    wire heartbeat = hb_cnt[HB_BIT];
    wire [7:0] lane_pad = 8'(lane_en_applied);
    // STATUS bit layout (spec 6.4), assembled explicitly
    wire [31:0] status_w;
    assign status_w[0]     = busy;
    assign status_w[1]     = active;
    assign status_w[2]     = sr_running;
    assign status_w[3]     = sr_stopping;
    assign status_w[4]     = zvalid;
    assign status_w[5]     = srst;
    assign status_w[6]     = heartbeat;
    assign status_w[7]     = wstale;
    assign status_w[8]     = fmt_applied;
    assign status_w[9]     = kat_running;
    assign status_w[10]    = mbist_running;
    assign status_w[11]    = trc_armed;
    assign status_w[15:12] = xptr_status;
    assign status_w[23:16] = lane_pad;
    assign status_w[30:24] = 7'd0;
    assign status_w[31]    = err_any;
    assign status_o        = status_w;

    // ---- which indices are implemented in this build ------------------------------------------
    reg mapped, ro;
    always @* begin
        mapped = 1'b0; ro = 1'b0;
        case (reg_idx)
            8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07, 8'h08: begin mapped = 1'b1; ro = 1'b1; end
            8'h09, 8'h0A, 8'h0C, 8'h0D, 8'h0E, 8'h0F, 8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16,
            8'h17, 8'h18, 8'h19: mapped = 1'b1;
            8'h0B: begin mapped = 1'b1; ro = 1'b1; end
            8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27, 8'h28, 8'h29, 8'h2A, 8'h2B, 8'h2C,
            8'h2D, 8'h2E: begin mapped = 1'b1; ro = 1'b1; end
            8'h30: mapped = (DBG != 0);
            8'h31: begin mapped = (DBG != 0); ro = 1'b1; end
            8'h38, 8'h39: mapped = (TRACE != 0);
            8'h3A: begin mapped = (TRACE != 0); ro = 1'b1; end
            8'h40, 8'h41, 8'h42, 8'h43, 8'h44: begin mapped = (KAT != 0 || MBIST != 0); ro = 1'b1; end
            8'h48, 8'h49, 8'h4A: begin mapped = (MBIST != 0); ro = 1'b1; end
            8'h50: mapped = (TILE != 0);
            8'h51, 8'h52, 8'h53: begin mapped = (TILE != 0); ro = 1'b1; end
            8'h54: mapped = (TILE != 0);
            default: mapped = 1'b0;
        endcase
    end
    // spec 11: a feature-off register reads 0 without an error; truly unlisted ones set ADDR
    wire listed_off = (reg_idx == 8'h30 || reg_idx == 8'h31) ? (DBG == 0)
                    : (reg_idx >= 8'h38 && reg_idx <= 8'h3A) ? (TRACE == 0)
                    : (reg_idx >= 8'h40 && reg_idx <= 8'h44) ? (KAT == 0 && MBIST == 0)
                    : (reg_idx >= 8'h48 && reg_idx <= 8'h4A) ? (MBIST == 0)
                    : (reg_idx >= 8'h50 && reg_idx <= 8'h54) ? (TILE == 0) : 1'b0;
    wire is_listed_idx = mapped | listed_off;

    // ---- read mux -----------------------------------------------------------------------------
    always @* begin
        reg_rdata = 32'd0;
        case (reg_idx)
            8'h00: reg_rdata = 32'h524F4E44;
            8'h01: reg_rdata = 32'h00020100;
            8'h02: reg_rdata = CAPS_V;
            8'h03: reg_rdata = GEOM0;
            8'h04: reg_rdata = GEOM1;
            8'h05: reg_rdata = GEOM2;
            8'h06: reg_rdata = GEOM3;
            8'h07: reg_rdata = 32'h00003C24;
            8'h08: reg_rdata = 32'h3C23D70A;
            8'h09: reg_rdata = scratch;
            8'h0A: reg_rdata = 32'd0;
            8'h0B: reg_rdata = status_w;
            8'h0C: reg_rdata = irq_status_o;
            8'h0D: reg_rdata = irq_en;
            8'h0E: reg_rdata = err_status;
            8'h0F: reg_rdata = err_mask;
            8'h10: reg_rdata = {31'd0, fmt_val};
            8'h11: reg_rdata = {{(32-XPW){1'b0}}, xsel};
            8'h12: reg_rdata = {24'd0, sr_n};
            8'h13: reg_rdata = sr_count;
            8'h14: reg_rdata = wdog_limit;
            8'h15: reg_rdata = {{(32-N_LANES){1'b0}}, lane_en};
            8'h16: reg_rdata = {11'd0, src_applied_in, 2'd0, div_applied, 11'd0, clk_cfg_q};
            8'h17: reg_rdata = {28'd0, clkout_k};
            8'h18: reg_rdata = {29'd0, pwr_pg_inactive, pwr_clk_off, pwr_core_hold};
            8'h19: reg_rdata = {31'd0, spi_crc_en};
            8'h20: reg_rdata = last_cycles;
            8'h21: reg_rdata = infer_cnt[31:0];
            8'h22: reg_rdata = shd[0];
            8'h23: reg_rdata = busy_cyc[31:0];
            8'h24: reg_rdata = shd[1];
            8'h25: reg_rdata = total_cyc[31:0];
            8'h26: reg_rdata = shd[2];
            8'h27: reg_rdata = sr_cyc[31:0];
            8'h28: reg_rdata = shd[3];
            8'h29: reg_rdata = sr_done_cnt;
            8'h2A: reg_rdata = checksum;
            8'h2B: reg_rdata = sr_pass_cksum;
            8'h2C: reg_rdata = load_crc;
            8'h2D: reg_rdata = guard_hits;
            8'h2E: reg_rdata = naninf_cnt;
            8'h30: reg_rdata = (DBG != 0) ? {6'd0, dbg_sel} : 32'd0;
            8'h31: reg_rdata = (DBG != 0) ? dbg_data : 32'd0;
            8'h38: reg_rdata = (TRACE != 0) ? trc_cfg : 32'd0;
            8'h39: reg_rdata = (TRACE != 0) ? trc_trig_cyc : 32'd0;
            8'h3A: reg_rdata = (TRACE != 0) ? trc_status : 32'd0;
            8'h40: reg_rdata = (KAT != 0 || MBIST != 0) ? st_status : 32'd0;
            8'h41: reg_rdata = (KAT != 0) ? kat_sig_bf16 : 32'd0;
            8'h42: reg_rdata = (KAT != 0) ? kat_sig_fp32 : 32'd0;
            8'h43: reg_rdata = (KAT != 0) ? kat_got_bf16 : 32'd0;
            8'h44: reg_rdata = (KAT != 0) ? kat_got_fp32 : 32'd0;
            8'h48: reg_rdata = (MBIST != 0) ? mbist_status : 32'd0;
            8'h49: reg_rdata = (MBIST != 0) ? mbist_fail_addr : 32'd0;
            8'h4A: reg_rdata = (MBIST != 0) ? mbist_fail_xor : 32'd0;
            8'h50: reg_rdata = (TILE != 0) ? tile_cfg : 32'd0;
            8'h51: reg_rdata = (TILE != 0) ? tile_status : 32'd0;
            8'h52: reg_rdata = (TILE != 0) ? tile_seq_crc : 32'd0;
            8'h53: reg_rdata = (TILE != 0) ? TGEOM : 32'd0;
            8'h54: reg_rdata = (TILE != 0) ? tile_slice : 32'd0;
            default: reg_rdata = 32'd0;
        endcase
    end

    // ---- write side ------------------------------------------------------------------------------
    reg [15:0] err_new;
    wire [31:0] w = reg_wdata;
    wire starts_blocked_tile = (TILE != 0) && (tile_cfg[0] || tile_open);
    integer ci;
    reg [4:0] nstart;
    reg       any_start_bit;
    reg       honor_start, honor_sr, honor_kat, honor_mbist, honor_tile;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scratch <= 32'd0; irq_en <= 32'h7F; err_mask <= ERR_MASK_RST; err_status <= 32'd0;
            irq_status <= 32'd0; fmt_set <= 1'b0; fmt_val <= 1'b0; xsel <= {XPW{1'b0}}; sr_n <= 8'd1;
            sr_count <= 32'd0; wdog_limit <= 32'd0; lane_en <= ALL_LANES; clk_div <= 2'd0; clk_src <= 1'b0;
            clkout_k <= 4'd0; pwr_core_hold <= 1'b0; pwr_clk_off <= 1'b0; pwr_pg_inactive <= 1'b0;
            spi_crc_en <= 1'b0; dbg_sel <= 26'd0; dbg_latch <= 1'b0; trc_cfg <= 32'd0; trc_trig_cyc <= 32'd0;
            tile_cfg <= 32'd0; tile_slice <= 32'd0; tile_slice_wr <= 1'b0;
            cmd_start <= 1'b0; cmd_soft_rst <= 1'b0; cmd_sr_start <= 1'b0; cmd_sr_stop <= 1'b0;
            cmd_cnt_clr <= 1'b0; cmd_cksum_clr <= 1'b0; cmd_crc_clr <= 1'b0; cmd_kat_start <= 1'b0;
            cmd_mbist_start <= 1'b0; cmd_trc_arm <= 1'b0; cmd_trc_force <= 1'b0; cmd_guard_clr <= 1'b0;
            cmd_tile_run <= 1'b0; cmd_tile_abort <= 1'b0;
            acc_err <= 1'b0; irq <= 1'b0; status8 <= 8'h02; hb_cnt <= 32'd0; wstale <= 1'b1; clk_pend <= 1'b0;
            clk_cfg_q <= 5'd0; shd[0] <= 32'd0; shd[1] <= 32'd0; shd[2] <= 32'd0; shd[3] <= 32'd0;
        end else begin
            hb_cnt <= hb_cnt + 32'd1;
            fmt_set <= 1'b0; dbg_latch <= 1'b0; tile_slice_wr <= 1'b0;
            cmd_start <= 1'b0; cmd_soft_rst <= 1'b0; cmd_sr_start <= 1'b0; cmd_sr_stop <= 1'b0;
            cmd_cnt_clr <= 1'b0; cmd_cksum_clr <= 1'b0; cmd_crc_clr <= 1'b0; cmd_kat_start <= 1'b0;
            cmd_mbist_start <= 1'b0; cmd_trc_arm <= 1'b0; cmd_trc_force <= 1'b0; cmd_guard_clr <= 1'b0;
            cmd_tile_run <= 1'b0; cmd_tile_abort <= 1'b0;
            err_new = err_in;

            // ---- event / status updates ------------------------------------------------------
            if (ev_done)          irq_status[0] <= 1'b1;
            if (ev_sr_done)       irq_status[1] <= 1'b1;
            if (ev_trc_done)      irq_status[3] <= 1'b1;
            if (ev_selftest_done) irq_status[4] <= 1'b1;
            if (ev_tile_slice)    irq_status[5] <= 1'b1;
            if (ev_tile_final)    irq_status[6] <= 1'b1;
            if (tile_slice_clr)   tile_slice <= 32'd0;
            if (wstale_set) wstale <= 1'b1;
            if (wstale_clr) wstale <= 1'b0;

            // ---- CLK_CFG applied at the end of the SPI frame that carried it ------------------
            if (clk_pend && frame_end && !active) begin
                clk_div <= clk_cfg_q[1:0]; clk_src <= clk_cfg_q[4]; clk_pend <= 1'b0;
            end

            // ---- reads: LO latches HI --------------------------------------------------------
            if (reg_re) begin
                case (reg_idx)
                    8'h21: shd[0] <= infer_cnt[63:32];
                    8'h23: shd[1] <= busy_cyc[63:32];
                    8'h25: shd[2] <= total_cyc[63:32];
                    8'h27: shd[3] <= sr_cyc[63:32];
                    default: ;
                endcase
                if (!is_listed_idx) err_new[E_ADDR] = 1'b1;
            end

            // ---- writes -----------------------------------------------------------------------
            if (reg_we) begin
                if (!is_listed_idx) err_new[E_ADDR] = 1'b1;
                else if (listed_off) err_new[E_ADDR] = 1'b1;     // feature not built
                else if (ro && reg_idx != 8'h0A) begin
                    err_new[E_RO] = 1'b1;
                end else begin
                    case (reg_idx)
                        8'h09: scratch <= w;
                        8'h0A: begin : ctrl
                            if (w[1]) cmd_soft_rst <= 1'b1;
                            else begin
                                if (w[4])  cmd_cnt_clr   <= 1'b1;
                                if (w[5])  cmd_cksum_clr <= 1'b1;
                                if (w[6])  cmd_crc_clr   <= 1'b1;
                                if (w[12]) cmd_guard_clr <= 1'b1;
                                if (w[14]) begin
                                    if (TILE != 0) cmd_tile_abort <= 1'b1; else err_new[E_ADDR] = 1'b1;
                                end
                                if (w[3]) cmd_sr_stop <= 1'b1;
                                if (w[9])  begin if (TRACE != 0) cmd_trc_arm <= 1'b1; else err_new[E_ADDR] = 1'b1; end
                                if (w[10]) begin if (TRACE != 0) cmd_trc_force <= 1'b1; else err_new[E_ADDR] = 1'b1; end
                                if (w[11]) begin if (DBG != 0) dbg_latch <= 1'b1; else err_new[E_ADDR] = 1'b1; end
                                // start-class commands: at most one honoured, order START, SR_START, KAT, MBIST, TILE_RUN
                                nstart = {4'd0, w[0]} + {4'd0, w[2]} + {4'd0, w[7]} + {4'd0, w[8]} + {4'd0, w[13]};
                                honor_start = 1'b0; honor_sr = 1'b0; honor_kat = 1'b0; honor_mbist = 1'b0; honor_tile = 1'b0;
                                if (nstart != 5'd0) begin
                                    if (active) err_new[E_START_BUSY] = 1'b1;
                                    else begin
                                        if (nstart > 5'd1) err_new[E_START_BUSY] = 1'b1;
                                        if (w[0]) honor_start = 1'b1;
                                        else if (w[2]) honor_sr = 1'b1;
                                        else if (w[7]) honor_kat = 1'b1;
                                        else if (w[8]) honor_mbist = 1'b1;
                                        else honor_tile = 1'b1;
                                        // feature / tile-state legality
                                        if ((honor_start || honor_sr) && starts_blocked_tile) begin
                                            err_new[E_TILE_SEQ] = 1'b1; honor_start = 1'b0; honor_sr = 1'b0;
                                        end
                                        if ((honor_kat || honor_mbist) && (TILE != 0) && tile_open) begin
                                            err_new[E_TILE_SEQ] = 1'b1; honor_kat = 1'b0; honor_mbist = 1'b0;
                                        end
                                        if (honor_kat && KAT == 0)    begin err_new[E_ADDR] = 1'b1; honor_kat = 1'b0; end
                                        if (honor_mbist && MBIST == 0) begin err_new[E_ADDR] = 1'b1; honor_mbist = 1'b0; end
                                        if (honor_tile && (TILE == 0)) begin err_new[E_ADDR] = 1'b1; honor_tile = 1'b0; end
                                        else if (honor_tile && !tile_cfg[0]) begin err_new[E_TILE_SEQ] = 1'b1; honor_tile = 1'b0; end
                                        cmd_start <= honor_start; cmd_sr_start <= honor_sr; cmd_kat_start <= honor_kat;
                                        cmd_mbist_start <= honor_mbist; cmd_tile_run <= honor_tile;
                                    end
                                end
                            end
                        end
                        8'h0C: begin   // W1C (bit 2 is a read-only mirror)
                            irq_status <= irq_status & ~(w & 32'h7B);
                        end
                        8'h0D: irq_en <= {25'd0, w[6:0]};
                        8'h0E: ;                                    // W1C handled with the error merge below
                        8'h0F: err_mask <= w;
                        8'h10: begin
                            if (active) err_new[E_BUSY_WR] = 1'b1;
                            else if ((TILE != 0) && tile_open) err_new[E_TILE_SEQ] = 1'b1;
                            else if (w > 32'd1 || (w[0] && HAS_FP32 == 0) || (!w[0] && HAS_BF16 == 0)) err_new[E_RANGE] = 1'b1;
                            else begin fmt_val <= w[0]; fmt_set <= 1'b1; end
                        end
                        8'h11: if (w >= NXBUF) err_new[E_RANGE] = 1'b1; else xsel <= w[XPW-1:0];
                        8'h12: if (w < 32'd1 || w > NXBUF) err_new[E_RANGE] = 1'b1; else sr_n <= w[7:0];
                        8'h13: sr_count <= w;
                        8'h14: wdog_limit <= w;
                        8'h15: begin
                            if (active) err_new[E_BUSY_WR] = 1'b1;
                            else if ((TILE != 0) && tile_open) err_new[E_TILE_SEQ] = 1'b1;
                            else lane_en <= w[N_LANES-1:0];
                        end
                        8'h16: begin
                            if (active) err_new[E_BUSY_WR] = 1'b1;
                            else begin clk_cfg_q <= {w[4], 2'b00, w[1:0]}; clk_pend <= 1'b1; end
                        end
                        8'h17: clkout_k <= w[3:0];
                        8'h18: begin
                            if (active) err_new[E_BUSY_WR] = 1'b1;
                            else begin pwr_core_hold <= w[0]; pwr_clk_off <= w[1]; pwr_pg_inactive <= w[2]; end
                        end
                        8'h19: spi_crc_en <= w[0];
                        8'h30: begin dbg_sel <= w[25:0]; dbg_latch <= 1'b1; end
                        8'h38: if (trc_armed) err_new[E_BUSY_WR] = 1'b1; else trc_cfg <= w;
                        8'h39: trc_trig_cyc <= w;
                        8'h50: begin
                            if (active || ((TILE != 0) && tile_open)) err_new[E_TILE_SEQ] = 1'b1;
                            else if (w[0] && (w[15:8] == 8'd0)) err_new[E_RANGE] = 1'b1;
                            else if (w[0] && (w[23:16] == 8'd0 || (w[24] == 1'b0 && w[23:16] > TBMAX[7:0]))) err_new[E_RANGE] = 1'b1;
                            else if (w[0] && TILE_B == 0 && !w[24]) err_new[E_RANGE] = 1'b1;
                            else tile_cfg <= {6'd0, w[25], w[24], (w[24] ? 8'd1 : w[23:16]), w[15:8], 7'd0, w[0]};
                        end
                        8'h54: begin
                            if (!(tile_cfg[25] && tile_open) || active) err_new[E_TILE_SEQ] = 1'b1;
                            else begin tile_slice <= {24'd0, w[7:0]}; tile_slice_wr <= 1'b1; end
                        end
                        default: ;
                    endcase
                end
            end
            // ERR_STATUS: new errors set after the clear
            err_status <= (reg_we && reg_idx == 8'h0E ? (err_status & ~w) : err_status) | {16'd0, err_new};

            // ---- soft reset: STATUS-type state, IRQ_STATUS, ERR_STATUS ---------------------------
            if (srst) begin
                irq_status <= 32'd0; err_status <= 32'd0;
            end

            acc_err <= (reg_re | reg_we) & (|(err_new & ~err_in));
            // ---- registered outputs --------------------------------------------------------------
            irq <= |(irq_status_o[6:0] & irq_en[6:0]);
            status8 <= {err_any, |(irq_status_o[6:0] & irq_en[6:0]), sr_running, active, busy, fmt_applied, 2'b10};
        end
    end
endmodule
