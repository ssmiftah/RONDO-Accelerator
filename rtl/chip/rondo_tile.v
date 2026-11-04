// rondo_tile: input-tiling sequence FSM (spec 18.6).
//
// A TILE_RUN executes one slice s for the inputs b = 0..TBATCH-1 of the batch:
//   T_CP      copy TX[b] (PDIM words) into the x_live registers (rondo_dev),
//   T_LAUNCH  one-cycle launch request to rondo_seq (K_TILE launch, seed/save/last held stable),
//   T_WAIT    until rondo_seq reports the launch finished (done + checksum walk for final launches),
//   T_TZ      final slice only: stream ZBUF into TZ[b] (WIDTH words),
//   T_NEXT    next input or end of the run (SLICE_DONE / FINAL_DONE).
// PS valid bits and slice tags live here; the PS data is in rondo_ps. TILE_SEQ_CRC is a CRC-32
// (same polynomial and framing as LOAD_CRC) chained over the 4 bytes (LE) of LOAD_CRC at every
// accepted TILE_RUN since the sequence opened; it reads 0 before the first run.
module rondo_tile #(
    parameter TB    = 8,                 // tile inputs held on chip (>= 1)
    parameter PDIM  = 40,
    parameter WIDTH = 64,
    parameter TBW   = 3,
    parameter XW    = 6,
    parameter ZJW   = 6
) (
    input                    clk,
    input                    rst_n,
    input                    srst,              // soft reset in progress
    input                    cmd_run,
    input                    cmd_abort,
    input  [31:0]            cfg,               // TILE_CFG
    input  [31:0]            slice_reg,         // TILE_SLICE (HOST_SLICE mode)
    input  [31:0]            load_crc,
    input                    inval_ext,         // FORMAT switch / KAT / MBIST: weights or AW change
    input                    other_start,       // any layer start that is not a tile launch
    input                    ps_host_wr,        // host wrote PS entry ps_host_b
    input  [TBW-1:0]         ps_host_b,
    // rondo_seq
    output                   launch,
    output [1:0]             seed,
    output                   save,
    output                   last,
    input                    seq_done,
    input                    seq_fail,
    // TX read / x_live write
    output                   tx_en,
    output [TBW+XW-1:0]      tx_addr,
    input  [31:0]            tx_q,
    output                   xt_we,
    output [XW-1:0]          xt_idx,
    // TZ write
    output                   tz_we,
    output [TBW+ZJW-1:0]     tz_addr,
    output [31:0]            tz_d,
    input  [WIDTH*32-1:0]    zbuf,
    output [TBW-1:0]         b_cur,
    // status
    output                   busy,
    output                   open_o,
    output [31:0]            status,
    output [31:0]            seq_crc,
    output                   ent_valid,         // PS entry of the current input (observation for SVA / formal)
    output [7:0]             ent_tag,
    output [7:0]             s_cur_o,
    output reg               ev_slice,
    output reg               ev_final,
    output reg               ev_seq,            // ERR TILE_SEQ
    output reg               ev_stale,          // ERR TILE_STALE
    output reg               slice_clr          // clear TILE_SLICE when the sequence closes
);
    localparam [2:0] T_IDLE = 3'd0, T_CP = 3'd1, T_LAUNCH = 3'd2, T_WAIT = 3'd3, T_TZ = 3'd4, T_NEXT = 3'd5;
    localparam integer CW = (PDIM > WIDTH) ? PDIM : WIDTH;
    localparam integer CNTW = $clog2(CW + 2);

    wire [7:0] nslice = cfg[15:8];
    wire [7:0] tbatch = cfg[23:16];
    wire       keep   = cfg[24];
    wire       host   = cfg[25];

    reg [2:0]  st;
    reg        open_q, st_slice_done, st_final_done, st_stale;
    reg [7:0]  slice_q, s_cur, inputs_done;
    reg [7:0]  b_q;
    reg [CNTW-1:0] i_q;
    reg        rd_v;
    reg [XW-1:0] rd_idx;
    reg [TB-1:0] valid;
    reg [7:0]  tag [0:TB-1];
    reg [31:0] crc_r;
    reg        err_pend;

    function [31:0] crc_byte(input [31:0] c, input [7:0] b);
        integer i;
        reg [31:0] r;
        begin
            r = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1) r = r[0] ? ((r >> 1) ^ 32'hEDB88320) : (r >> 1);
            crc_byte = r;
        end
    endfunction
    function [31:0] crc_word(input [31:0] c, input [31:0] w);
        crc_word = crc_byte(crc_byte(crc_byte(crc_byte(c, w[7:0]), w[15:8]), w[23:16]), w[31:24]);
    endfunction
    assign seq_crc = crc_r ^ 32'hFFFFFFFF;

    wire [7:0] s_req = host ? slice_reg[7:0] : slice_q;
    assign seed = !busy ? 2'd0 : (s_cur == 8'd0) ? 2'd0 : (keep ? 2'd1 : 2'd2);   // defaults outside a tile run: a normal single-shot start
    assign save = busy && (s_cur != nslice - 8'd1) && !keep;
    assign last = !busy || (s_cur == nslice - 8'd1);
    wire [TBW-1:0] vidx = keep ? {TBW{1'b0}} : b_q[TBW-1:0];
    assign launch = (st == T_LAUNCH);
    assign busy   = (st != T_IDLE);
    assign open_o = open_q;
    assign b_cur  = b_q[TBW-1:0];
    assign ent_valid = valid[vidx];
    assign ent_tag   = tag[vidx];
    assign s_cur_o   = s_cur;
    assign tx_en   = (st == T_CP) && (32'(i_q) < PDIM);
    assign tx_addr = {b_q[TBW-1:0], i_q[XW-1:0]};
    assign xt_we   = rd_v;
    assign xt_idx  = rd_idx;
    assign tz_we   = (st == T_TZ);
    assign tz_addr = {b_q[TBW-1:0], i_q[ZJW-1:0]};
    assign tz_d    = zbuf[i_q[ZJW-1:0]*32 +: 32];
    assign status  = {8'd0, inputs_done, (host ? slice_reg[7:0] : slice_q), 4'd0, st_stale, st_final_done,
                      st_slice_done, open_q};

    // validity of the PS entries a slice s > 0 needs: all tbatch entries valid with tag s-1
    wire [TB-1:0] bad_b;
    genvar gi;
    generate
        for (gi = 0; gi < TB; gi = gi + 1) begin : g_chk
            assign bad_b[gi] = (gi < tbatch) && (!valid[gi] || (tag[gi] != (s_req - 8'd1)));
        end
    endgenerate
    wire stale_chk = |bad_b;

    // a host PS write is tagged SLICE-1 (the slice the entry is the input of)
    wire [7:0] host_tag = (host ? slice_reg[7:0] : slice_q) - 8'd1;


    integer ti;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= T_IDLE; open_q <= 1'b0; st_slice_done <= 1'b0; st_final_done <= 1'b0; st_stale <= 1'b0;
            slice_q <= 8'd0; s_cur <= 8'd0; inputs_done <= 8'd0; b_q <= 8'd0; i_q <= {CNTW{1'b0}};
            rd_v <= 1'b0; rd_idx <= {XW{1'b0}}; valid <= {TB{1'b0}}; crc_r <= 32'hFFFFFFFF;
            err_pend <= 1'b0; ev_slice <= 1'b0; ev_final <= 1'b0; ev_seq <= 1'b0;
            ev_stale <= 1'b0; slice_clr <= 1'b0;
            for (ti = 0; ti < TB; ti = ti + 1) tag[ti] <= 8'd0;
        end else begin
            ev_slice <= 1'b0; ev_final <= 1'b0; ev_seq <= 1'b0; ev_stale <= 1'b0; slice_clr <= 1'b0;
            rd_v <= 1'b0;
            // the deferred TILE_STALE error is raised once a soft reset has finished (it clears ERR_STATUS)
            if (err_pend && !srst) begin ev_stale <= 1'b1; err_pend <= 1'b0; end

            if (srst) begin
                st <= T_IDLE;
                begin valid <= {TB{1'b0}}; if (open_q) begin err_pend <= 1'b1; st_stale <= 1'b1; open_q <= 1'b0; slice_q <= 8'd0; slice_clr <= 1'b1; end end
            end else begin
                if (inval_ext) begin valid <= {TB{1'b0}}; if (open_q) begin err_pend <= 1'b1; st_stale <= 1'b1; open_q <= 1'b0; slice_q <= 8'd0; slice_clr <= 1'b1; end end
                if (other_start && keep) valid[0] <= 1'b0;
                if (ps_host_wr && !busy) begin valid[ps_host_b] <= 1'b1; tag[ps_host_b] <= host_tag; end

                case (st)
                    T_IDLE: begin
                        if (cmd_abort) begin
                            valid <= {TB{1'b0}}; open_q <= 1'b0; slice_q <= 8'd0; st_stale <= 1'b0;
                            slice_clr <= 1'b1; err_pend <= 1'b0;
                        end else if (cmd_run && !inval_ext) begin       // an invalidation in the same cycle wins (cannot happen on the chip: separate rbus accesses)
                            if (s_req >= nslice) ev_seq <= 1'b1;
                            else if (s_req == 8'd0 || open_q) begin
                                if (s_req != 8'd0 && stale_chk) begin ev_stale <= 1'b1; st_stale <= 1'b1; end
                                else begin
                                    // accepted
                                    s_cur <= s_req; b_q <= 8'd0; i_q <= {CNTW{1'b0}}; inputs_done <= 8'd0;
                                    st_slice_done <= 1'b0; st <= T_CP;
                                    if (s_req == 8'd0) begin
                                        open_q <= 1'b1; st_final_done <= 1'b0; st_stale <= 1'b0;
                                        valid <= {TB{1'b0}};
                                        crc_r <= crc_word(32'hFFFFFFFF, load_crc);
                                    end else crc_r <= crc_word(crc_r, load_crc);
                                end
                            end else begin
                                ev_stale <= 1'b1; st_stale <= 1'b1;     // not open and not slice 0: no partial sums
                            end
                        end
                    end
                    T_CP: begin
                        if (32'(i_q) < PDIM) begin
                            rd_v <= 1'b1; rd_idx <= i_q[XW-1:0]; i_q <= i_q + 1'b1;
                        end else if (!rd_v) st <= T_LAUNCH;
                    end
                    T_LAUNCH: st <= T_WAIT;
                    T_WAIT: begin
                        if (seq_fail) begin
                            st <= T_IDLE; begin valid <= {TB{1'b0}}; if (open_q) begin err_pend <= 1'b1; st_stale <= 1'b1; open_q <= 1'b0; slice_q <= 8'd0; slice_clr <= 1'b1; end end
                        end else if (seq_done) begin
                            if (!last) begin
                                valid[vidx] <= 1'b1; tag[vidx] <= s_cur;
                                st <= T_NEXT;
                            end else begin
                                i_q <= {CNTW{1'b0}}; st <= T_TZ;
                            end
                        end
                    end
                    T_TZ: begin
                        i_q <= i_q + 1'b1;
                        if (32'(i_q) == WIDTH - 1) st <= T_NEXT;
                    end
                    T_NEXT: begin
                        inputs_done <= inputs_done + 8'd1;
                        if ((b_q + 8'd1) < tbatch) begin
                            b_q <= b_q + 8'd1; i_q <= {CNTW{1'b0}}; st <= T_CP;
                        end else begin
                            st <= T_IDLE;
                            if (last) begin
                                ev_final <= 1'b1; st_final_done <= 1'b1; valid <= {TB{1'b0}};
                                if (!host) begin open_q <= 1'b0; slice_q <= 8'd0; slice_clr <= 1'b1; end
                            end else begin
                                ev_slice <= 1'b1; st_slice_done <= 1'b1;
                                if (!host) slice_q <= s_cur + 8'd1;
                            end
                        end
                    end
                    default: st <= T_IDLE;
                endcase
                if (cmd_abort && st != T_IDLE) ev_seq <= 1'b1;      // abort during a run is refused
            end
        end
    end
endmodule
