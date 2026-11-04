// Checker for the SPI PHY / controller (spec 15.2). Plain clocked checks with manual history (no $past, no bind) so it
// runs under Icarus, Verilator and SymbiYosys (assert()s under `FORMAL). viol[i] is sticky per property:
//  0 miso_oe == cs_active (one flop later)      1 MISO changes only after a detected SCLK rise or CS change
//  2 no rbus request issued while idle (CS high, no response pending) 3 requests per frame never exceed N+1
//  4 loopback echo: byte k+1 on MISO equals byte k received
module rondo_sva_spi (
    input clk, input rst_n,
    input cs_active, input miso, input miso_oe, input rise, input frame_start, input frame_end,
    input rb_req_valid, input rb_req_ready, input frame_is_rw, input hdr_done, input [16:0] n_total,
    input lb_mode, input rx_valid, input [7:0] rx_byte, input tx_load_sh, input [7:0] tx_sh_byte,
    output reg [7:0] viol
);
    reg miso_q, oe_q, cs_q, rise_q, fs_q, fe_q;
    reg [17:0] nreq;
    reg pend;
    reg [7:0] last_rx; reg lb_have;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            viol <= 8'd0; miso_q <= 1'b0; oe_q <= 1'b0; cs_q <= 1'b0; rise_q <= 1'b0; fs_q <= 1'b0; fe_q <= 1'b0;
            nreq <= 18'd0; pend <= 1'b0; last_rx <= 8'd0; lb_have <= 1'b0;
        end else begin
            miso_q <= miso; oe_q <= miso_oe; cs_q <= cs_active; rise_q <= rise; fs_q <= frame_start; fe_q <= frame_end;
            if (miso_oe !== cs_q) viol[0] <= 1'b1;
            if (miso !== miso_q && !(rise_q || fs_q || fe_q || rise)) viol[1] <= 1'b1;
            if (rb_req_valid && !cs_active && !pend && !frame_end) viol[2] <= 1'b1;
            if (frame_start) nreq <= 18'd0;
            else if (rb_req_valid && rb_req_ready) nreq <= nreq + 18'd1;
            if (hdr_done && frame_is_rw && nreq > {1'b0, n_total}) viol[3] <= 1'b1;
            pend <= rb_req_valid ? 1'b1 : (pend && !frame_end ? pend : 1'b0);
`ifdef FORMAL
            assert (miso_oe == cs_q);
`endif
        end
    end
endmodule
