`timescale 1ns/1ps
// Clock / reset primitive unit testbench (T-UNITS clock part).
module tb_chip_units_clk (
    input clk0, clk1, rst_n, sel, test_mode,
    input [1:0] div, input en_async, input [3:0] sd, input arst_n,
    output mux_out, output div_out, output [1:0] div_applied, output icg_out,
    output [3:0] sq, output rs_out,
    output integer mux_min_hi, mux_min_lo, div_min_hi, icg_min_hi,
    input meas_en
);
    rondo_clk_mux u_mux (.clk0(clk0), .clk1(clk1), .sel(sel), .rst_n(rst_n),
                         .test_mode(test_mode), .clk_out(mux_out));
    rondo_clkdiv u_div (.clk_in(clk0), .rst_n(rst_n), .div(div), .test_mode(test_mode),
                        .clk_out(div_out), .div_applied(div_applied));
    rondo_icg u_icg (.clk(clk0), .en(en_async), .test_en(1'b0), .gclk(icg_out));
    rondo_sync #(.STAGES(2), .WIDTH(4)) u_sync (.clk(clk0), .rst_n(rst_n), .d(sd), .q(sq));
    rondo_reset_sync #(.STAGES(2)) u_rs (.clk(clk0), .arst_n(arst_n), .test_mode(test_mode),
                                         .rst_n_out(rs_out));

    // pulse-width trackers
    realtime t_mux_r, t_mux_f, t_div_r, t_icg_r;
    initial begin
        mux_min_hi = 100000; mux_min_lo = 100000; div_min_hi = 100000; icg_min_hi = 100000;
        t_mux_r = 0; t_mux_f = 0; t_div_r = 0; t_icg_r = 0;
    end
    function integer ps(input realtime d); ps = $rtoi(d * 1000.0); endfunction
    always @(posedge mux_out) begin
        if (meas_en && t_mux_f > 0 && ps($realtime - t_mux_f) < mux_min_lo) mux_min_lo = ps($realtime - t_mux_f);
        t_mux_r = $realtime;
    end
    always @(negedge mux_out) begin
        if (meas_en && t_mux_r > 0 && ps($realtime - t_mux_r) < mux_min_hi) mux_min_hi = ps($realtime - t_mux_r);
        t_mux_f = $realtime;
    end
    always @(posedge div_out) t_div_r = $realtime;
    always @(negedge div_out) if (meas_en && t_div_r > 0 && ps($realtime - t_div_r) < div_min_hi) div_min_hi = ps($realtime - t_div_r);
    always @(posedge icg_out) t_icg_r = $realtime;
    always @(negedge icg_out) if (meas_en && t_icg_r > 0 && ps($realtime - t_icg_r) < icg_min_hi) icg_min_hi = ps($realtime - t_icg_r);
endmodule
