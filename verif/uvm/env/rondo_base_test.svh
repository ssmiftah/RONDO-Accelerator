// Demotes expected UVM_ERRORs (negative checks of the scoreboards).
class expect_err_catcher extends uvm_report_catcher;
  string id_match; int unsigned n = 0; bit active = 0;
  function new(string name = "expect_err_catcher"); super.new(name); endfunction
  function action_e catch();
    if (active && get_severity() == UVM_ERROR && get_id() == id_match) begin n++; set_severity(UVM_INFO); set_message({"[expected, demoted] ", get_message()}); end
    return THROW;
  endfunction
endclass

class rondo_base_test extends uvm_test;
  `uvm_component_utils(rondo_base_test)
  rondo_env env; virtual pins_if pins; virtual probe_if pv; virtual clk_if clkv; rondo_bus bus; rondo_geo g; expect_err_catcher catcher;
  int unsigned poll_gap = 12; int unsigned errors_seen = 0; string tname;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase);
    env = rondo_env::type_id::create("env", this);
    catcher = new(); uvm_report_cb::add(null, catcher);
  endfunction
  function void start_of_simulation_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual pins_if)::get(this, "", "pins_vif", pins)) `uvm_fatal("NOVIF", "pins")
    if (!uvm_config_db#(virtual probe_if)::get(this, "", "probe_vif", pv)) `uvm_fatal("NOVIF", "probe")
    if (!uvm_config_db#(virtual clk_if)::get(this, "", "clk_vif", clkv)) `uvm_fatal("NOVIF", "clk")
    bus = env.bus; g = env.g;
  endfunction
  // ---- timing helpers (cycle counts on the probe clock; for the CHIP top this is the undivided source clock) -----------------
  task cycles(int n); repeat (n) @(posedge pv.clk); endtask
  task do_reset(bit strap = 0, int n = 8);
    pins.bist_en = strap; pins.rst_n = 1'b0; cycles(n); pins.rst_n = 1'b1; cycles(12);
`ifdef TOP_CHIP
    cycles(8);
`endif
  endtask
  // ---- register helpers -------------------------------------------------------------------------------------------------
  task wr(bit [7:0] idx, bit [31:0] d); bus.write({16'd0, idx}, d); endtask
  task rd(bit [7:0] idx, output bit [31:0] d); bus.read({16'd0, idx}, d); endtask
  function bit [31:0] ctlbits(int b0, int b1 = -1, int b2 = -1);
    bit [31:0] v = 0; v[b0] = 1; if (b1 >= 0) v[b1] = 1; if (b2 >= 0) v[b2] = 1; return v;
  endfunction
  task ctrl(int b0, int b1 = -1, int b2 = -1); wr(R_CTRL, ctlbits(b0, b1, b2)); endtask
  task wait_idle(int max = 4000);
    bit [31:0] s; int n = 0;
    forever begin
      rd(R_STATUS, s);
      if (!s[1]) return;
      if (++n > max) begin `uvm_error("WAIT", $sformatf("chip stays ACTIVE (STATUS=%h)", s)) return; end
      cycles(poll_gap);
    end
  endtask
  task rd64(bit [7:0] lo, bit [7:0] hi, output bit [63:0] v); bit [31:0] l, h; rd(lo, l); rd(hi, h); v = {h, l}; endtask
  // ---- data helpers ------------------------------------------------------------------------------------------------------
  function bit [31:0] rnd_el(bit fmt, int lo, int hi);
    bit s = $urandom; int e = 127 + lo + $urandom_range(hi - lo); bit [31:0] m = $urandom;
    return fmt ? {s, e[7:0], m[22:0]} : {16'd0, s, e[7:0], m[6:0]};
  endfunction
  bit [31:0] last_w_el;
  task load_weights(bit fmt, int wlo = -4, int whi = -1, int blo = -2, int bhi = 1);
    for (int l = 0; l < g.L; l++) begin
      bit [31:0] ws[$], bs[$];
      for (int i = 0; i < g.NWORDS * g.NP; i++) ws.push_back(rnd_el(fmt, wlo, whi));
      for (int i = 0; i < g.NBWORDS * g.NP; i++) bs.push_back(rnd_el(fmt, blo, bhi));
      bus.write_burst(g.w_addr(l, 0, 0), ws); bus.write_burst(g.b_addr(l, 0, 0), bs);
    end
  endtask
  task write_x(int entry, bit fmt, int lo = -3, int hi = 0);
    bit [31:0] xs[$]; for (int i = 0; i < g.P; i++) xs.push_back(rnd_el(fmt, lo, hi)); bus.write_burst(g.x_addr(entry, 0), xs);
  endtask
  task set_format(bit f); wr(R_FORMAT, f); wait_idle(); endtask
  task read_z(output bit [31:0] z[$]); bus.read_burst(ZBUF_BASE, g.W, z); endtask
  task infer(int entry); wr(R_XSEL, entry); wr(R_IRQ_STATUS, 32'h7F); ctrl(CT_START); wait_idle(); endtask
  // ---- test body -----------------------------------------------------------------------------------------------------------
  virtual task body(); endtask
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    do_reset();
    body();
    cycles(50);
    phase.drop_objection(this);
  endtask
  function void check_phase(uvm_phase phase);
    if (env.ref_m.n_checked == 0 && env.ref_m.enabled) `uvm_warning("REF", "scoreboard performed no checks")
  endfunction
endclass
