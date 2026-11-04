// Functional coverage (explicit bins; no `with` filters, no binsof..intersect expressions).
class rondo_cov extends uvm_object;
  `uvm_object_utils(rondo_cov)
  bit [7:0] s_idx; bit s_we; bit [2:0] s_out; bit s_act; bit [3:0] s_ctl; bit [3:0] s_ctlstate; bit [15:0] s_err; bit s_fmt; bit [2:0] s_lane; bit s_sr; bit [2:0] s_entry;
  bit [2:0] s_region; bit [1:0] s_fmt_tr; bit s_fmt_react;
  covergroup reg_cg;
    idx: coverpoint s_idx { bins ident[] = {8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07, 8'h08, 8'h09, 8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E, 8'h0F,
        8'h10, 8'h11, 8'h12, 8'h13, 8'h14, 8'h15, 8'h16, 8'h17, 8'h18, 8'h19, 8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27, 8'h28, 8'h29,
        8'h2A, 8'h2B, 8'h2C, 8'h2D, 8'h2E, 8'h30, 8'h31, 8'h38, 8'h39, 8'h3A, 8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h50, 8'h51, 8'h52, 8'h53, 8'h54};
        bins other = default; }
    op: coverpoint s_we { bins rd = {0}; bins wr = {1}; }
    out: coverpoint s_out { bins ok = {0}; bins addr = {1}; bins ro = {2}; bins busy_wr = {3}; bins range = {4}; bins tile_seq = {5}; bins start_busy = {6}; }
    op_out: cross op, out { ignore_bins rd_ro = binsof(op.rd) && binsof(out.ro); ignore_bins rd_busy = binsof(op.rd) && binsof(out.busy_wr); ignore_bins rd_range = binsof(op.rd) && binsof(out.range); ignore_bins rd_tile = binsof(op.rd) && binsof(out.tile_seq); ignore_bins rd_sb = binsof(op.rd) && binsof(out.start_busy); }
  endgroup
  covergroup err_cg;
    e: coverpoint s_err { bins busy_wr = {16'h0001}; bins addr = {16'h0002}; bins ro = {16'h0004}; bins start_busy = {16'h0008}; bins range = {16'h0020}; bins tile_seq = {16'h4000}; bins other = default; }
  endgroup
  covergroup ctrl_cg;
    bit_c: coverpoint s_ctl { bins start_cmd = {0}; bins soft_rst = {1}; bins sr_start = {2}; bins sr_stop = {3}; bins cnt_clr = {4}; bins cksum_clr = {5}; bins crc_clr = {6};
      bins kat = {7}; bins mbist = {8}; bins trc = {9}; bins dbg = {10}; bins guard = {11}; bins tile_run = {12}; bins tile_abort = {13}; bins multi = {14}; }
    st: coverpoint s_ctlstate { bins idle = {0}; bins active = {1}; bins open = {2}; }
    x: cross bit_c, st;
  endgroup
  covergroup dp_cg;
    f: coverpoint s_fmt { bins bf16 = {0}; bins fp32 = {1}; }
    ln: coverpoint s_lane { bins all = {0}; bins none = {1}; bins single = {2}; bins partial = {3}; }
    sr: coverpoint s_sr { bins single = {0}; bins selfrun = {1}; }
    en: coverpoint s_entry { bins e0 = {0}; bins e1 = {1}; bins e2 = {2}; bins e3 = {3}; }   // NXBUF = 4 in S and F
    fxl: cross f, ln;
    fxs: cross f, sr;
  endgroup
  covergroup load_cg;
    reg_: coverpoint s_region { bins w = {1}; bins b = {2}; bins x = {3}; bins tx = {4}; bins ps = {5}; bins z = {6}; }
    f: coverpoint s_fmt { bins bf16 = {0}; bins fp32 = {1}; }
    rx: cross reg_, f;
  endgroup
  covergroup fmt_cg;
    t: coverpoint s_fmt_tr { bins b2f = {1}; bins f2b = {2}; bins b2b = {0}; bins f2f = {3}; }
    r: coverpoint s_fmt_react { bins accepted = {0}; bins while_active = {1}; }
    x: cross t, r;
  endgroup
  function new(string name = "rondo_cov"); super.new(name); reg_cg = new(); err_cg = new(); ctrl_cg = new(); dp_cg = new(); load_cg = new(); fmt_cg = new(); endfunction
  function void sample_access(rbus_item it, bit act, bit topen, bit [31:0] e, bit fmt_old, bit fmt_new);
    bit [23:0] a = it.addr; s_we = it.we; s_act = act; s_fmt = fmt_new;
    if (a[23:8] == 0) begin
      s_idx = a[7:0];
      if (e[ER_ADDR]) s_out = 1; else if (e[ER_RO]) s_out = 2; else if (e[ER_BUSY_WR]) s_out = 3; else if (e[ER_RANGE]) s_out = 4; else if (e[ER_TILE_SEQ]) s_out = 5; else if (e[ER_START_BUSY]) s_out = 6; else s_out = 0;
      reg_cg.sample();
      if (e != 0) begin s_err = e[15:0]; err_cg.sample(); end
      if (it.we && a[7:0] == R_CTRL) begin
        int nb = 0; int which = 0;
        for (int i = 0; i < 15; i++) if (it.wdata[i]) begin nb++; which = i; end
        if (nb > 1) s_ctl = 14;
        else case (which) 9, 10: s_ctl = 9; 11: s_ctl = 10; 12: s_ctl = 11; 13: s_ctl = 12; 14: s_ctl = 13; default: s_ctl = which; endcase
        s_ctlstate = act ? 1 : (topen ? 2 : 0); if (nb > 0) ctrl_cg.sample();
      end
      if (it.we && a[7:0] == R_FORMAT && !e[ER_RANGE]) begin s_fmt_react = act; s_fmt_tr = {fmt_old, it.wdata[0]}; fmt_cg.sample(); end
    end else begin
      if (a[23:16] == 8'h01) s_region = 3; else if (a[23:16] == 8'h02) s_region = 6; else if (a[23:16] == 8'h04) s_region = 4; else if (a[23:16] == 8'h06) s_region = 5;
      else if (a[23]) s_region = 1; else if (a[23:20] == 4'h1) s_region = 2; else return;
      load_cg.sample();
    end
  endfunction
  function void sample_run(bit fmt, int lanes, bit sr, int entry, int cyc);
    int pc = $countones(lanes);
    s_fmt = fmt; s_sr = sr; s_entry = entry; s_lane = (pc == 0) ? 1 : (pc == `C_LANES) ? 0 : (pc == 1) ? 2 : 3; dp_cg.sample();
  endfunction
endclass
