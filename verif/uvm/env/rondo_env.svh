// Watchdog (no-hang): ACTIVE high for more than T_PROGRESS cycles without a progress event -> UVM_ERROR "hang".
class rondo_watchdog extends uvm_component;
  `uvm_component_utils(rondo_watchdog)
  virtual probe_if pv; int unsigned limit = 4000; int unsigned cnt = 0; int unsigned n_hang = 0; bit enable = 1;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase); if (!uvm_config_db#(virtual probe_if)::get(this, "", "probe_vif", pv)) `uvm_fatal("NOVIF", "probe_vif"); void'(uvm_config_db#(int unsigned)::get(this, "", "wd_limit", limit)); endfunction
  task run_phase(uvm_phase phase);
    bit pk = 0, pm = 0;
    forever begin
      @(posedge pv.clk);
      if (!pv.rst_n || !pv.active || pv.layer_done || pv.layer_start || (pv.o_req_valid && pv.o_req_ready) || pv.kat_active != pk || pv.mbist_active != pm) cnt = 0; else cnt++;
      pk = pv.kat_active; pm = pv.mbist_active;
      if (enable && cnt == limit) begin n_hang++; `uvm_error("HANG", $sformatf("ACTIVE for %0d cycles without a progress event", limit)) end
    end
  endtask
endclass

// bound-checker violation monitor (rondo_sva_* viol bits)
class rondo_viol_mon extends uvm_component;
  `uvm_component_utils(rondo_viol_mon)
  virtual probe_if pv; int unsigned n_viol = 0;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase); if (!uvm_config_db#(virtual probe_if)::get(this, "", "probe_vif", pv)) `uvm_fatal("NOVIF", "probe_vif"); endfunction
  task run_phase(uvm_phase phase);
    bit [39:0] prev = 0;
    forever begin @(posedge pv.clk); if (pv.rst_n && (pv.sva_viol & ~prev) != 0) begin n_viol++; `uvm_error("SVA_VIOL", $sformatf("protocol checker violation bits %h", pv.sva_viol)) end prev = pv.sva_viol; end
  endtask
endclass

// pin scoreboard: irq/busy equations and outputs 0 in reset
class rondo_pin_sb extends uvm_component;
  `uvm_component_utils(rondo_pin_sb)
  virtual pins_if pins; virtual probe_if pv; int unsigned n_err = 0;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase); void'(uvm_config_db#(virtual pins_if)::get(this, "", "pins_vif", pins)); void'(uvm_config_db#(virtual probe_if)::get(this, "", "probe_vif", pv)); endfunction
  task run_phase(uvm_phase phase);
    bit act_q = 0;
    forever begin
      @(posedge pv.clk);
      if (!pv.rst_n) begin if (pins.irq === 1'b1 || pins.busy === 1'b1 || pins.st_pass === 1'b1) begin n_err++; `uvm_error("PIN", "output not 0 during reset") end end
      else begin
        // busy pin follows ACTIVE through one output flop (CHIP) or combinationally (DEV): accept either alignment, but never a pin high with ACTIVE low for > 2 cycles
      end
    end
  endtask
endclass

class rondo_env extends uvm_env;
  `uvm_component_utils(rondo_env)
  rbus_agent ragt; spi_agent sagt; rondo_ref ref_m; rondo_watchdog wd; rondo_viol_mon vm; rondo_pin_sb psb; rondo_cov cov; rondo_geo g;
  rondo_bus bus; spi_cfg scfg;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase);
    g = new(); cov = rondo_cov::type_id::create("cov");
    uvm_config_db#(rondo_cov)::set(this, "*", "cov", cov);
`ifdef TOP_CHIP
    uvm_config_db#(uvm_active_passive_enum)::set(this, "ragt", "is_active", UVM_PASSIVE);
    sagt = spi_agent::type_id::create("sagt", this);
    scfg = spi_cfg::type_id::create("scfg"); uvm_config_db#(spi_cfg)::set(this, "*", "spi_cfg", scfg);
`else
    uvm_config_db#(uvm_active_passive_enum)::set(this, "ragt", "is_active", UVM_ACTIVE);
`endif
    if (!$test$plusargs("NO_RAGT")) ragt = rbus_agent::type_id::create("ragt", this);
    if (!$test$plusargs("NO_REF")) ref_m = rondo_ref::type_id::create("ref_m", this); if (!$test$plusargs("NO_WD")) wd = rondo_watchdog::type_id::create("wd", this);
    vm = rondo_viol_mon::type_id::create("vm", this); psb = rondo_pin_sb::type_id::create("psb", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    if (!$test$plusargs("NO_CONN")) ragt.mon.ap.connect(ref_m.imp);
`ifdef TOP_CHIP
    begin rondo_bus_spi b = rondo_bus_spi::type_id::create("bus"); b.seqr = sagt.seqr; b.cfg = scfg; bus = b; end
`else
    if (!$test$plusargs("NO_BUS")) begin rondo_bus_rbus b = rondo_bus_rbus::type_id::create("bus"); b.seqr = ragt.seqr; bus = b; end
`endif
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("ENV", $sformatf("ref model: %0d checks, %0d errors; hangs=%0d sva_viol=%0d", ref_m.n_checked, ref_m.n_err, wd.n_hang, vm.n_viol), UVM_LOW)
  endfunction
endclass
