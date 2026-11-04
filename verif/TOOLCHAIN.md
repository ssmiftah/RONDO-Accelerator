# Toolchain probes (V0.1)

Probe sources: build/verif/probe/{uvm1,feat,sby}. Machine: Vivado 2025.2 xsim, Yosys 0.66, SymbiYosys, /usr/bin/abc (ABC 1.01).

| feature | result | chosen path / fallback |
|---|---|---|
| UVM 1.2 (`xvlog -sv -L uvm`, `xelab -L uvm`) | OK | `UVM_NO_DPI` is defined in the Xilinx build: names/test name via plusarg, no DPI regex |
| `uvm_reg` / RAL classes | OK (block/reg/field build and configure) | RAL package generated from regmap.py (V3, reduced) |
| `uvm_hdl_read/write` | **FAIL**: `UVM_FATAL [UVM_HDL_READ] uvm_hdl DPI routines are compiled off` | backdoor through hierarchical references in an SV module/class bound into the testbench (rondo_hdl_paths.svh) |
| constraints: dynamic array + foreach + size | OK | `unique {}` constraint is **not supported** ("unique constraints is not supported yet for simulation"): not used |
| covergroups (bins, illegal_bins, `with function sample`) | OK; xcrg text report written | `xcrg -cov_db_dir <d> -report_format text` |
| concurrent SVA `|->`, `|=>`, `##[1:3]`, `$rose` (assert) | OK, failing assertion reported | `cover property` is **not supported** (ignored with a warning); use immediate-assertion counters / covergroups |
| `bind` into a module (generic module `dut`) | OK | |
| DPI-C scalar ints/longints | OK **only with a gcc-built shared object**. `xsc` fails at link time (Vivado's bundled ld 2.37 rejects the host's /usr/lib/libmvec.so.1: "skipping incompatible ... ld returned 1") | `gcc -shared -fPIC -I$XSIM/data/xsim/include -o dpi.so rondo_fpmodel.c`; `xelab --sv_root <dir> --sv_lib dpi` (the file must be named dpi.so). See verif/model/Makefile |
| code coverage `xelab --cc_type sbct --cc_db --cc_dir` | OK (xsim.codeCov written) | used on the DEV/CHIP tops (see reports) |
| timescale | RTL has none: `xelab --timescale 1ns/1ps` | |
| RTL parse: S, F and all S-* variants of rondo_dev (HardFloat, `$clog2` params, `$fatal` in generate) | OK, no relax needed beyond `--relax`; no RTL edit | verif/scripts/xsim_build.sh |
| sby `abc pdr` | works only through a wrapper: sby appends `-l` to `pdr`, which /usr/bin/abc (ABC 1.01) rejects ("pdr: unknown option l", result UNKNOWN) | `ABC=verif/scripts/abc_wrap.sh` strips the `-l` and execs /usr/bin/abc. Toy counter proof: PASS |
| sby `multiclock on` with a latch | OK (BMC PASS) | |
| yosys `mutate -list` | OK on RTL without immediate asserts in the same read (`read_verilog` without `-formal`/asserts) | mutate.sh reads the DUT file only |
| `xsc` | not used (see DPI) | |
