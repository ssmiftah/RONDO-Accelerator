// rondo_trace: logic-analyzer style circular trace buffer (spec 11.3).
// DEPTH entries of {data[31:0], meta[31:0]}; meta = {timestamp[15:0], flags[7:0], tag[7:0]}.
// TRC_CFG: [2:0] SRC, [3] MODE, [7:4] TRIG, [15:8] POST, [16] STOP_ON_FULL.
module rondo_trace #(
    parameter DEPTH = 64,
    parameter IW    = (DEPTH < 2) ? 1 : $clog2(DEPTH)
) (
    input              clk,
    input              rst_n,
    input              srst,
    input  [31:0]      cfg,
    input  [31:0]      trig_cyc,
    input              arm,
    input              force_trig,
    // sources
    input              live_v, input [31:0] live_d, input [7:0] live_f,        // SRC 0 (core live stream)
    input  [31:0]      ev_data, input ev_valid,                                  // SRC 1 (wrapper events)
    input  [31:0]      rb_data, input rb_valid, input [7:0] rb_flags, input [7:0] rb_tag, // SRC 2
    input  [31:0]      gd_data, input gd_valid, input [7:0] gd_flags, input [7:0] gd_tag, // SRC 3
    // trigger inputs
    input              t_start, t_done, t_guard, t_err,
    output reg         armed,
    output reg         trigd,
    output reg         done,                // 1-cycle pulse at completion (IRQ TRC_DONE)
    output reg         done_lvl,
    output reg [7:0]   nvalid,
    output reg [7:0]   trig_idx,
    // read port: entry k chronological, sel = 0 data, 1 meta
    input  [IW:0]      rd_k,
    input              rd_meta,
    output [31:0]      rd_data
);
    wire [2:0] src   = cfg[2:0];
    wire       mode  = cfg[3];
    wire [3:0] trig  = cfg[7:4];
    wire [7:0] post  = cfg[15:8];
    wire       sof   = cfg[16];

    reg [31:0] mem_d [0:DEPTH-1];
    reg [31:0] mem_m [0:DEPTH-1];
    reg [IW:0] wptr;                    // next physical slot (mod DEPTH, kept in IW+1 bits)
    reg [15:0] ts;
    reg [31:0] total;                   // entries stored since ARM
    reg [31:0] total_at_trig;
    reg [7:0]  post_left;
    reg        trig_pend;               // trigger event seen, waiting for the trigger entry to be stored
    reg [31:0] since_start;
    reg        err_prev;

    reg        s_v; reg [31:0] s_d; reg [7:0] s_f, s_t;
    always @* begin
        case (src)
            3'd0: begin s_v = live_v;  s_d = live_d; s_f = live_f;   s_t = 8'd0; end
            3'd1: begin s_v = ev_valid; s_d = ev_data; s_f = 8'd0;    s_t = 8'd1; end
            3'd2: begin s_v = rb_valid; s_d = rb_data; s_f = rb_flags; s_t = rb_tag; end
            default: begin s_v = gd_valid; s_d = gd_data; s_f = gd_flags; s_t = gd_tag; end
        endcase
    end
    wire store = armed && !done_lvl && (mode ? 1'b1 : s_v);

    // trigger condition this cycle
    reg trg;
    always @* begin
        case (trig)
            4'd0: trg = 1'b1;
            4'd1: trg = t_start;
            4'd2: trg = t_done;
            4'd3: trg = t_guard;
            4'd4: trg = (since_start == trig_cyc);
            4'd5: trg = live_f[6];
            4'd6: trg = t_err & ~err_prev;
            default: trg = 1'b0;
        endcase
        if (force_trig) trg = 1'b1;
    end
    wire fire = armed && !trigd && !trig_pend && !sof && trg;

    wire [IW:0] depth_c = DEPTH[IW:0];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed <= 1'b0; trigd <= 1'b0; done <= 1'b0; done_lvl <= 1'b0; nvalid <= 8'd0; trig_idx <= 8'd0;
            wptr <= '0; ts <= 16'd0; total <= 32'd0; total_at_trig <= 32'd0; post_left <= 8'd0;
            trig_pend <= 1'b0; since_start <= 32'd0; err_prev <= 1'b0;
        end else begin
            done <= 1'b0; err_prev <= t_err;
            if (srst) begin
                armed <= 1'b0; trigd <= 1'b0; done_lvl <= 1'b0; nvalid <= 8'd0; trig_idx <= 8'd0; wptr <= '0;
                total <= 32'd0; trig_pend <= 1'b0;
            end else if (arm) begin
                armed <= 1'b1; trigd <= 1'b0; done_lvl <= 1'b0; nvalid <= 8'd0; trig_idx <= 8'd0; wptr <= '0;
                ts <= 16'd0; total <= 32'd0; trig_pend <= 1'b0; since_start <= 32'd0;
            end else if (armed && !done_lvl) begin
                ts <= ts + 16'd1;
                if (t_start) since_start <= 32'd0; else since_start <= since_start + 32'd1;
                if (fire) trig_pend <= 1'b1;
                if (store) begin
                    mem_d[wptr[IW-1:0]] <= s_d;
                    mem_m[wptr[IW-1:0]] <= {ts, s_f, s_t};
                    wptr <= (wptr == depth_c - 1'b1) ? '0 : wptr + 1'b1;
                    total <= total + 32'd1;
                    nvalid <= (total + 32'd1 >= DEPTH) ? DEPTH[7:0] : (total[7:0] + 8'd1);
                    // trigger entry = first entry stored at/after the trigger event
                    if ((trig_pend || fire) && !trigd) begin
                        trigd <= 1'b1; trig_pend <= 1'b0; total_at_trig <= total;
                        post_left <= post;
                        if (post == 8'd0) begin done_lvl <= 1'b1; done <= 1'b1; armed <= 1'b0; end
                    end else if (trigd) begin
                        post_left <= post_left - 8'd1;
                        if (post_left == 8'd1) begin done_lvl <= 1'b1; done <= 1'b1; armed <= 1'b0; end
                    end
                    if (sof && (total + 32'd1 == DEPTH)) begin done_lvl <= 1'b1; done <= 1'b1; armed <= 1'b0; end
                end
            end
            // trigger index in read order
            if (done) begin
                trig_idx <= (total_at_trig < (DEPTH - 1 - 32'(post))) ? total_at_trig[7:0] : 8'(DEPTH - 1 - 32'(post));
            end
        end
    end

    // chronological read (DEPTH must be a power of two): the oldest stored entry is at (wptr - nvalid) mod DEPTH
    generate if ((DEPTH & (DEPTH - 1)) != 0) begin : e_depth $fatal(1, "rondo_trace: DEPTH must be a power of two"); end endgenerate
    wire [IW:0]   oldest = wptr - (IW+1)'(nvalid);
    wire [IW:0]   phys   = oldest + rd_k;
    wire          rd_ok  = (32'(rd_k) < 32'(nvalid));
    assign rd_data = rd_ok ? (rd_meta ? mem_m[phys[IW-1:0]] : mem_d[phys[IW-1:0]]) : 32'd0;
endmodule
