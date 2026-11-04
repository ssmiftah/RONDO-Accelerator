# Mutation sanity summary (yosys `mutate -list N -seed 1`, kill = SymbiYosys FAIL on the job's proof/bmc task)

| job | task / depth | mutants | killed | rate | plan target 80% |
|---|---|---|---|---|---|
| arb | prove (PDR) | 30 | 26 | 87% | met |
| regs | prove (induction/PDR) | 30 | 8 | 27% | NOT met |
| seq | bmc 50 | 30 | 7 | 23% | NOT met |
| tile | bmc 60 | 30 | 4 | 13% | NOT met |
| spi_ctrl | bmc_nocrc 33 | 20 | 6 | 30% | NOT met |
Survivors were not individually argued (no time): a first look at regs/seq/tile/spi_ctrl shows that the harnesses do not observe most of the logic (counter outputs, status words, tile PS/TZ addressing, the data path of the rbus words, CRC-on path)
because those blocks are checked by the UVM reference model, not by the formal properties, and that the bounded depth stops before the logic of later words is reached. The formal harnesses are therefore safety/bookkeeping nets, not functional proofs.
Per-mutant tables: mutation_<job>.md.
