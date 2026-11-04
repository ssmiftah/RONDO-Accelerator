# Waivers (all pending author approval)

| id | what | reason | status |
|---|---|---|---|
| W-CLK-1 | FV-CLK glitch properties would exclude the asynchronous-reset step | FV-CLK was not implemented in this round, so no waiver is in use; the clock glitch check is the time-based UVM checker in tb_top (u_clk_div, u_clk_src) | not used |
| W-COV-1 | functional-coverage cross bins that no legal stimulus can hit are marked `ignore_bins` only where listed in rondo_cov.svh | each ignore is justified in the code comment next to the bin | pending author approval (see SIGNOFF.md for the final list) |
| W-CC-1 | code coverage is measured on the S build only; S_MB, S_SCAN_PG, KAN and FAULT_INJECT branches are not included in the percentages | one config per top was instrumented; other configs run functionally | pending author approval |
