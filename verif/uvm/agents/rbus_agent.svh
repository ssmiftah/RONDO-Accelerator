// rbus agent: active master (DEV top) and passive monitor on the device's external port (both tops).
class rbus_item extends uvm_sequence_item;
  rand bit we; rand bit [23:0] addr; rand bit [31:0] wdata;
  rand int unsigned gap;            // idle cycles before the request
  rand int unsigned rsp_hold;       // cycles rsp_ready is held low after rsp_valid
  bit [31:0] rdata; bit err; longint unsigned t_req, t_rsp; bit [31:0] tag;
  constraint c_gap { gap inside {[0:3]}; rsp_hold inside {[0:2]}; }
  `uvm_object_utils(rbus_item)
  function new(string name = "rbus_item"); super.new(name); endfunction
  function string convert2string(); return $sformatf("%s a=%h w=%h r=%h err=%0d", we ? "WR" : "RD", addr, wdata, rdata, err); endfunction
endclass

class rbus_driver extends uvm_driver#(rbus_item);
  `uvm_component_utils(rbus_driver)
  virtual rbus_if vif; bit random_timing = 1'b1;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual rbus_if)::get(this, "", "rbus_vif", vif)) `uvm_fatal("NOVIF", "rbus_vif")
  endfunction
  task run_phase(uvm_phase phase);
    vif.cb.req_valid <= 1'b0; vif.cb.rsp_ready <= 1'b1;
    forever begin
      seq_item_port.get_next_item(req);
      drive(req);
      seq_item_port.item_done();
    end
  endtask
  task drive(rbus_item it);
    int unsigned g = random_timing ? it.gap : 0;
    int unsigned h = random_timing ? it.rsp_hold : 0; int unsigned seen = 0; bit rdy_cur;
    repeat (g) @(vif.cb);
    rdy_cur = (h == 0);
    vif.cb.req_valid <= 1'b1; vif.cb.req_we <= it.we; vif.cb.req_addr <= it.addr; vif.cb.req_wdata <= it.wdata; vif.cb.rsp_ready <= rdy_cur;
    @(vif.cb);
    while (!vif.cb.req_ready) @(vif.cb);
    vif.cb.req_valid <= 1'b0;
    forever begin
      if (vif.cb.rsp_valid && rdy_cur) begin it.rdata = vif.cb.rsp_rdata; it.err = vif.cb.rsp_err; break; end
      if (vif.cb.rsp_valid) seen++;
      rdy_cur = (seen >= h); vif.cb.rsp_ready <= rdy_cur;
      @(vif.cb);
    end
    vif.cb.rsp_ready <= 1'b1;
  endtask
endclass

class rbus_monitor extends uvm_monitor;
  `uvm_component_utils(rbus_monitor)
  virtual rbus_if vif; virtual probe_if pv; uvm_analysis_port#(rbus_item) ap; longint unsigned cyc = 0; int unsigned n_acc = 0;
  function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual rbus_if)::get(this, "", "rbus_vif", vif)) `uvm_fatal("NOVIF", "rbus_vif")
    void'(uvm_config_db#(virtual probe_if)::get(this, "", "probe_vif", pv));
  endfunction
  task run_phase(uvm_phase phase);
    rbus_item cur; bit have = 0;
    forever begin
      @(vif.mcb);
      cyc++;
      if (!vif.rst_n) begin have = 0; continue; end
      if (vif.mcb.req_valid && vif.mcb.req_ready) begin
        cur = rbus_item::type_id::create("mon_item"); cur.we = vif.mcb.req_we; cur.addr = vif.mcb.req_addr; cur.wdata = vif.mcb.req_wdata; cur.t_req = cyc; have = 1; n_acc++;
        if (pv != null) cur.tag = {28'd0, pv.fmt_applied, (pv.kat_active | pv.mbist_active), pv.tile_open, pv.active};
      end
      if (vif.mcb.rsp_valid && vif.mcb.rsp_ready) begin
        if (!have) `uvm_error("RBUS_MON", "response without request")
        else begin cur.rdata = vif.mcb.rsp_rdata; cur.err = vif.mcb.rsp_err; cur.t_rsp = cyc; ap.write(cur); have = 0; end
      end
    end
  endtask
endclass

typedef uvm_sequencer#(rbus_item) rbus_sequencer;

class rbus_agent extends uvm_agent;
  `uvm_component_utils(rbus_agent)
  rbus_driver drv; rbus_sequencer seqr; rbus_monitor mon;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase);
    mon = rbus_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin drv = rbus_driver::type_id::create("drv", this); seqr = rbus_sequencer::type_id::create("seqr", this); end
  endfunction
  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction
endclass

class rbus_one_seq extends uvm_sequence#(rbus_item);
  `uvm_object_utils(rbus_one_seq)
  rbus_item it;
  function new(string n = "rbus_one_seq"); super.new(n); endfunction
  task body(); start_item(it); finish_item(it); endtask
endclass
