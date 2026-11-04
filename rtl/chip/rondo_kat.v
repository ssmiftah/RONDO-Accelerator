// rondo_kat: known-answer self-test and self-test controller (spec 9.8, 11.5).
//
// Engine: runs through the real load path (internal rbus master, rb_req_int = 1). A 32-bit Galois LFSR
// (taps 0x80200003, seed 0x1D872B41; each element uses the state after one more step) generates every
// weight element (lane, address, field), then every bias element, then the XBUF entries. They are written
// at their rbus addresses; every 37th core word of the weights is read back and compared. Then the sequencer
// runs 2*NXBUF inferences over the NXBUF entries with a private signature (rondo_cksum), which is compared
// with the build-time constant SIG_<fmt>.
// Controller: KAT_START runs the engine for the current FORMAT; the bist_en strap runs
// [MBIST], KAT bf16, FORMAT<-fp32, KAT fp32, FORMAT<-bf16 once after reset. ST_STATUS / st_pass.
module rondo_kat #(
    parameter N_LANES = 8, NPAR = 8, NWORDS = 280, NBWORDS = 7, PDIM = 40, NXBUF = 4,
    parameter WAW = 9, BAW = 3, XW = 6, FW = 3,
    parameter HAS_BF16 = 1, HAS_FP32 = 1, MBIST = 0,
    parameter [31:0] SIG_BF16 = 32'd0, SIG_FP32 = 32'd0,
    parameter LNW = (N_LANES < 2) ? 1 : $clog2(N_LANES)
) (
    input              clk,
    input              rst_n,
    input              srst,
    input              cmd_start,
    input              strap,
    input              fmt_applied,
    input              seq_idle,
    // internal rbus master
    output reg         rb_req_valid,
    input              rb_req_ready,
    output reg         rb_req_we,
    output reg [23:0]  rb_req_addr,
    output reg [31:0]  rb_req_wdata,
    input              rb_rsp_valid,
    input  [31:0]      rb_rsp_rdata,
    // sequencer KAT run
    output reg         seq_run,
    output [7:0]       seq_n,
    output [31:0]      seq_count,
    input              seq_done,
    input              seq_fail,       // the sequencer refused the KAT launch (spec 10.2)
    input  [31:0]      seq_sig,
    output reg         sig_clr,
    // format control (strap sequence)
    output reg         fmt_set_o,
    output reg         fmt_val_o,
    // MBIST hand-off
    output reg         mbist_start_o,
    input              mbist_done,
    input              mbist_pass,
    // status
    output             kat_active,
    output             running_kat,
    output [31:0]      st_status,
    output reg [31:0]  got_bf16, got_fp32,
    output             st_pass,
    output reg         ev_selftest_done,
    output reg         ev_kat_fail,
    output reg         ev_wstale_set,
    output reg         ev_crc_clr,
    output reg         ev_inval,
    input              mbist_running_in
);
    localparam integer XPW = (PDIM < 2) ? 1 : $clog2(PDIM);
    assign seq_n     = NXBUF[7:0];
    assign seq_count = 2 * NXBUF;

    // ---- element generator ---------------------------------------------------------------------------
    reg  [31:0] lfsr;
    wire [31:0] lfsr_n = (lfsr >> 1) ^ (lfsr[0] ? 32'h80200003 : 32'h0);
    wire [7:0]  elem_exp = 8'd125 + {6'd0, lfsr_n[30:29]};          // BIAS - 2 + r[30:29]
    wire [31:0] elem16 = {16'd0, lfsr_n[31], elem_exp, lfsr_n[28:22]};
    wire [31:0] elem32 = {lfsr_n[31], elem_exp, lfsr_n[28:6]};
    wire [31:0] elem   = fmt_applied ? elem32 : elem16;

    // ---- engine ---------------------------------------------------------------------------------------
    localparam [4:0] E_IDLE = 0, E_PREP = 1, E_WI = 2, E_WD = 3, E_RI = 4, E_RD = 5, E_WA = 6,
                     E_BI = 7, E_BD = 8, E_BA = 9, E_XI = 10, E_XD = 11, E_XA = 12, E_RUN = 13,
                     E_SIG = 14, E_FIN = 15, E_HOLD = 16;
    reg [4:0]  es;
    reg        bus_wait;
    reg [31:0] last_rdata;
    reg [LNW-1:0] cl;
    reg [15:0] ca;
    reg [FW-1:0] cf;
    reg [31:0] wcount;
    reg [31:0] fld [0:NPAR-1];
    reg [FW:0] rbi;
    reg [7:0]  xe;
    reg [15:0] xi;
    reg        fail_rb, eng_fmt;
    reg        eng_go, eng_done;
    reg [31:0] eng_sig;

    wire [23:0] waddr  = 24'h800000 + (24'(cl) << (WAW + FW)) + (24'(ca) << FW) + {21'd0, cf};
    wire [23:0] rbaddr = 24'h800000 + (24'(cl) << (WAW + FW)) + (24'(ca) << FW) + {20'd0, rbi[FW-1:0]};
    wire [23:0] baddr  = 24'h100000 + (24'(cl) << (BAW + FW)) + (24'(ca) << FW) + {21'd0, cf};
    wire [23:0] xaddr  = 24'h010000 + (24'(xe) << XW) + 24'(xi);
    wire        word_end = (cf == FW'(NPAR - 1));
    wire        rb_this  = word_end && ((wcount % 37) == 0);

    task automatic bus(input we, input [23:0] a, input [31:0] d);
        begin rb_req_valid <= 1'b1; rb_req_we <= we; rb_req_addr <= a; rb_req_wdata <= d; bus_wait <= 1'b1; end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            es <= E_IDLE; bus_wait <= 1'b0; last_rdata <= 32'd0; rb_req_valid <= 1'b0; rb_req_we <= 1'b0;
            rb_req_addr <= 24'd0; rb_req_wdata <= 32'd0; seq_run <= 1'b0; sig_clr <= 1'b0; cl <= '0; ca <= 16'd0;
            cf <= '0; wcount <= 32'd0; rbi <= '0; xe <= 8'd0; xi <= 16'd0; fail_rb <= 1'b0; eng_done <= 1'b0;
            eng_sig <= 32'd0; lfsr <= 32'h1D872B41; ev_wstale_set <= 1'b0; ev_crc_clr <= 1'b0; ev_inval <= 1'b0;
            eng_fmt <= 1'b0;
        end else begin
            seq_run <= 1'b0; sig_clr <= 1'b0; eng_done <= 1'b0;
            ev_wstale_set <= 1'b0; ev_crc_clr <= 1'b0; ev_inval <= 1'b0;
            if (rb_req_valid && rb_req_ready) rb_req_valid <= 1'b0;
            if (srst) begin
                es <= E_IDLE; bus_wait <= 1'b0; rb_req_valid <= 1'b0;
            end else if (bus_wait) begin
                if (rb_rsp_valid) begin bus_wait <= 1'b0; last_rdata <= rb_rsp_rdata; es <= es + 5'd1; end
            end else case (es)
                E_IDLE: if (eng_go) begin es <= E_PREP; eng_fmt <= fmt_applied; end
                E_PREP: begin
                    lfsr <= 32'h1D872B41; cl <= '0; ca <= 16'd0; cf <= '0; wcount <= 32'd0; fail_rb <= 1'b0;
                    ev_wstale_set <= 1'b1; ev_crc_clr <= 1'b1; ev_inval <= 1'b1; sig_clr <= 1'b1;
                    es <= E_WI;
                end
                // ---- weights: issue / (response) / done ------------------------------------------------
                E_WI: begin lfsr <= lfsr_n; fld[cf] <= elem; bus(1'b1, waddr, elem); end   // -> E_WD on response
                E_WD: begin
                    if (rb_this) begin rbi <= '0; es <= E_RI; end else es <= E_WA;
                end
                E_RI: bus(1'b0, rbaddr, 32'd0);                                           // -> E_RD on response
                E_RD: begin
                    if (last_rdata != fld[rbi[FW-1:0]]) fail_rb <= 1'b1;
                    if (rbi == (NPAR - 1)) es <= E_WA;
                    else begin rbi <= rbi + 1'b1; es <= E_RI; end
                end
                E_WA: begin
                    if (word_end) begin
                        cf <= '0; wcount <= wcount + 32'd1;
                        if (ca == 16'(NWORDS - 1)) begin
                            ca <= 16'd0;
                            if (cl == LNW'(N_LANES - 1)) begin cl <= '0; es <= E_BI; end
                            else begin cl <= cl + 1'b1; es <= E_WI; end
                        end else begin ca <= ca + 16'd1; es <= E_WI; end
                    end else begin cf <= cf + 1'b1; es <= E_WI; end
                end
                // ---- biases ------------------------------------------------------------------------------
                E_BI: begin lfsr <= lfsr_n; bus(1'b1, baddr, elem); end
                E_BD: es <= E_BA;
                E_BA: begin
                    if (word_end) begin
                        cf <= '0;
                        if (ca == 16'(NBWORDS - 1)) begin
                            ca <= 16'd0;
                            if (cl == LNW'(N_LANES - 1)) begin cl <= '0; xe <= 8'd0; xi <= 16'd0; es <= E_XI; end
                            else begin cl <= cl + 1'b1; es <= E_BI; end
                        end else begin ca <= ca + 16'd1; es <= E_BI; end
                    end else begin cf <= cf + 1'b1; es <= E_BI; end
                end
                // ---- XBUF ----------------------------------------------------------------------------------
                E_XI: begin lfsr <= lfsr_n; bus(1'b1, xaddr, elem); end
                E_XD: es <= E_XA;
                E_XA: begin
                    if (xi == 16'(PDIM - 1)) begin
                        xi <= 16'd0;
                        if (xe == 8'(NXBUF - 1)) es <= E_RUN;
                        else begin xe <= xe + 8'd1; es <= E_XI; end
                    end else begin xi <= xi + 16'd1; es <= E_XI; end
                end
                E_RUN: if (seq_idle) begin seq_run <= 1'b1; es <= E_SIG; end
                E_SIG: if (seq_fail) begin eng_sig <= 32'd0; fail_rb <= 1'b1; es <= E_FIN; end          // refused launch: end with KAT_FAIL
                       else if (seq_done) begin eng_sig <= seq_sig; es <= E_FIN; end
                E_FIN: begin eng_done <= 1'b1; es <= E_IDLE; end
                default: es <= E_IDLE;
            endcase
        end
    end

    // ---- controller ---------------------------------------------------------------------------------------
    localparam [3:0] C_IDLE = 0, C_MB = 1, C_MBW = 2, C_KAT = 3, C_FSW = 4, C_FSWW = 5, C_END = 6, C_KATW = 7;
    reg [3:0]  cs;
    reg [2:0]  step;                  // strap: 0 bf16, 1 fp32, 2 restore bf16
    reg        strap_run, at_reset, st_done, st_running, strap_done_once;
    reg        pass_b, pass_f, pass_mb, pass_all, ran_b, ran_f;
    reg [2:0]  fw;                    // format-switch settle delay
    wire       eng_run = (es != E_IDLE);
    assign kat_active  = st_running | (strap & ~strap_done_once);     // busy from reset release through the strap self-test
    assign running_kat = eng_run;
    assign st_pass     = pass_all & st_done & ~st_running;
    assign st_status   = {23'd0, ran_f, ran_b, at_reset, (MBIST != 0) ? mbist_pass : 1'b1, pass_f, pass_b,
                          st_pass, st_done, st_running};

    wire [31:0] sig_exp = eng_fmt ? SIG_FP32 : SIG_BF16;
    wire        eng_pass = (eng_sig == sig_exp) && !fail_rb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs <= C_IDLE; step <= 3'd0; strap_run <= 1'b0; at_reset <= 1'b0; st_done <= 1'b0; st_running <= 1'b0;
            strap_done_once <= 1'b0; pass_b <= 1'b0; pass_f <= 1'b0; pass_mb <= 1'b1; pass_all <= 1'b0;
            ran_b <= 1'b0; ran_f <= 1'b0; got_bf16 <= 32'd0; got_fp32 <= 32'd0; eng_go <= 1'b0;
            fmt_set_o <= 1'b0; fmt_val_o <= 1'b0; mbist_start_o <= 1'b0; ev_selftest_done <= 1'b0;
            ev_kat_fail <= 1'b0; fw <= 3'd0;
        end else begin
            eng_go <= 1'b0; fmt_set_o <= 1'b0; mbist_start_o <= 1'b0; ev_selftest_done <= 1'b0; ev_kat_fail <= 1'b0;
            if (srst) begin
                cs <= C_IDLE; st_running <= 1'b0; strap_run <= 1'b0;
            end else case (cs)
                C_IDLE: begin
                    if (cmd_start && seq_idle) begin
                        st_running <= 1'b1; st_done <= 1'b0; pass_all <= 1'b0; pass_mb <= 1'b1; strap_run <= 1'b0;
                        at_reset <= 1'b0; ran_b <= 1'b0; ran_f <= 1'b0;
                        if (MBIST != 0) begin mbist_start_o <= 1'b1; cs <= C_MBW; end
                        else begin eng_go <= 1'b1; cs <= C_KATW; end
                    end else if (strap && !strap_done_once && seq_idle) begin
                        strap_done_once <= 1'b1;
                        st_running <= 1'b1; st_done <= 1'b0; pass_all <= 1'b0; pass_mb <= 1'b1; strap_run <= 1'b1;
                        at_reset <= 1'b1; ran_b <= 1'b0; ran_f <= 1'b0; step <= 3'd0;
                        if (MBIST != 0) begin mbist_start_o <= 1'b1; cs <= C_MBW; end
                        else if (fmt_applied) begin fmt_set_o <= 1'b1; fmt_val_o <= 1'b0; fw <= 3'd3; cs <= C_FSWW; end
                        else begin eng_go <= 1'b1; cs <= C_KATW; end
                    end
                end
                C_MBW: if (mbist_done) begin
                    pass_mb <= mbist_pass;
                    if (strap_run && fmt_applied) begin fmt_set_o <= 1'b1; fmt_val_o <= 1'b0; fw <= 3'd3; cs <= C_FSWW; end
                    else begin eng_go <= 1'b1; cs <= C_KATW; end
                end
                C_FSWW: begin
                    if (fw != 3'd0) fw <= fw - 3'd1;
                    else if (seq_idle) begin
                        if (step == 3'd2) cs <= C_END;
                        else begin eng_go <= 1'b1; cs <= C_KATW; end
                    end
                end
                C_KATW: if (eng_done) begin
                    if (eng_fmt) begin got_fp32 <= eng_sig; ran_f <= 1'b1; pass_f <= eng_pass; end
                    else         begin got_bf16 <= eng_sig; ran_b <= 1'b1; pass_b <= eng_pass; end
                    if (!eng_pass) ev_kat_fail <= 1'b1;
                    if (strap_run && step == 3'd0 && HAS_FP32 != 0) begin
                        step <= 3'd1; fmt_set_o <= 1'b1; fmt_val_o <= 1'b1; fw <= 3'd3; cs <= C_FSWW;
                    end else if (strap_run && step == 3'd1) begin
                        step <= 3'd2; fmt_set_o <= 1'b1; fmt_val_o <= 1'b0; fw <= 3'd3; cs <= C_FSWW;
                    end else cs <= C_END;
                end
                C_END: begin
                    st_running <= 1'b0; st_done <= 1'b1; ev_selftest_done <= 1'b1; cs <= C_IDLE;
                    if (strap_run) pass_all <= pass_b && (HAS_FP32 == 0 || pass_f) && pass_mb;
                    else pass_all <= (eng_fmt ? pass_f : pass_b) && pass_mb;
                    strap_run <= 1'b0;
                end
                default: cs <= C_IDLE;
            endcase
        end
    end
endmodule
