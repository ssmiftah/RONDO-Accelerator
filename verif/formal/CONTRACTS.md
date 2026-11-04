# Assume-guarantee contracts (plan 2.6): who proves what each harness assumes

Every assumption in a harness carries `// A: <justification>` (arb, kat, regs) or a header comment (legacy harnesses). Status = what exists in this repository.

| consumer assumption | provider guarantee | status |
|---|---|---|
| seq: commands one-hot by priority (`!(c_start && c_sr)`, `!(kat_run && (c_start || c_sr))`) | regs: at most one start-class command per write (regs_f: `!(cmd_start && cmd_sr_start)` etc.) | PROVEN (regs prove) |
| seq: no FORMAT/LANE_EN/PWR change while ACTIVE | regs: BUSY_WR + unchanged (regs_f e4: PWR_CTRL while ACTIVE) | PROVEN for PWR_CTRL; FORMAT/LANE_EN covered by UVM u_err_all / u_fmt_switch |
| seq: `!(kat_run && fmt_set)` | regs: FORMAT writes blocked while the KAT is ACTIVE | UVM (u_fmt_switch, u_err_all), not formal |
| seq: PWR_CTRL changes free when not ACTIVE, kat_run may arrive while held | none needed (this is the B2 reachability) | assumption removed from the old harness on purpose |
| tile: no event while busy | regs/dev: external commands are blocked while ACTIVE | UVM |
| arb: internal masters hold valid until ready (except srst) | kat: rb1 (kat_f.v) | PROVEN (kat prove) |
| arb: external master holds valid; accepts responses within 3 cycles | spi_ctrl: master rules rb1-3 (spi_ctrl_f.v) | BMC 34/28 + cover; JG-only unbounded file |
| arb: slave ready within 3, response within 5 cycles | dev: external access bound (spec 8.3, 24 cycles) | UVM rbus monitor + SVA rondo_sva_rbus (MAX_RSP) |
| kat: seq answers (done) or refuses (kat_fail) within 3 cycles | seq: kr_q -> seq_active or kat_fail (seq_f.v) | BMC 70 (fixed RTL passes, pre-fix fails at step 2) |
| spi_ctrl: PHY byte spacing >= GAPN+1 cycles (GAPN 2 here, real >= 48) | spi_phy: one byte per 8 SCLK periods | argued in formal/spi_ctrl.sby header (sound over-approximation); real PHY timing not formally linked |
| spi_ctrl: `mid_abort` simultaneous with `frame_end` | spi_phy: abort_q is registered one cycle AFTER frame_end | **VIOLATED by the RTL: BUG-1** (reports/BUGS.md); the harness assumption hid it |
| phy: hold-byte load window | spi_ctrl tx1 | not proven (no tx1 property in this round) |
| clk jobs: clock periods >= 2 global steps | oscillator | not run (FV-CLK not done) |
