// Abstract bus access API used by all sequences/tests; implemented over the rbus agent (DEV) and the SPI agent (CHIP).
virtual class rondo_bus extends uvm_object;
  function new(string name = "rondo_bus"); super.new(name); endfunction
  pure virtual task write(bit [23:0] a, bit [31:0] d);
  pure virtual task read(bit [23:0] a, output bit [31:0] d);
  pure virtual task write_burst(bit [23:0] a, ref bit [31:0] d[$]);
  pure virtual task read_burst(bit [23:0] a, int n, ref bit [31:0] d[$]);
  virtual function bit is_spi(); return 0; endfunction
endclass

class rondo_bus_rbus extends rondo_bus;
  `uvm_object_utils(rondo_bus_rbus)
  rbus_sequencer seqr; bit last_err;
  function new(string name = "rondo_bus_rbus"); super.new(name); endfunction
  task one(bit we, bit [23:0] a, bit [31:0] d, output bit [31:0] q);
    rbus_one_seq s = rbus_one_seq::type_id::create("s"); rbus_item it = rbus_item::type_id::create("it");
    it.we = we; it.addr = a; it.wdata = d; void'(it.randomize(gap, rsp_hold));
    s.it = it; s.start(seqr); q = it.rdata; last_err = it.err;
  endtask
  task write(bit [23:0] a, bit [31:0] d); bit [31:0] q; one(1, a, d, q); endtask
  task read(bit [23:0] a, output bit [31:0] d); one(0, a, 0, d); endtask
  task write_burst(bit [23:0] a, ref bit [31:0] d[$]); foreach (d[i]) write(a + i, d[i]); endtask
  task read_burst(bit [23:0] a, int n, ref bit [31:0] d[$]); bit [31:0] q; d.delete(); for (int i = 0; i < n; i++) begin read(a + i, q); d.push_back(q); end endtask
endclass
