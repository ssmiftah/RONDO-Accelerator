#!/usr/bin/env python3
"""Make a legacy Yosys harness tool-neutral: (* anyseq *) / (* anyconst *) wires become module input ports (free every cycle) and
anyconst wires get a stability assumption. usage: convert_harness.py in.v out.v"""
import re, sys
src = open(sys.argv[1]).read()
ports, consts = [], []
def grab(kind):
    def rep(m):
        rng = (m.group(1) or "").strip(); names = [n.strip() for n in m.group(2).split(",")]
        for n in names:
            ports.append(f"input {rng} {n}".replace("  ", " "))
            if kind == "anyconst": consts.append((n, rng))
        return f"// [{kind}] -> input: {', '.join(names)}"
    return rep
src = re.sub(r"\(\*\s*anyseq\s*\*\)\s*wire\s*(\[[^\]]+\])?\s*([^;]+);", grab("anyseq"), src)
src = re.sub(r"\(\*\s*anyconst\s*\*\)\s*wire\s*(\[[^\]]+\])?\s*([^;]+);", grab("anyconst"), src)
m = re.search(r"module\s+(\w+)\s*\(\s*input\s+clk\s*\);", src)
hdr = f"module {m.group(1)} (input clk" + "".join(", " + p for p in ports) + ");"
src = src.replace(m.group(0), hdr)
if consts:
    ins = "\n    // anyconst inputs: constant after the first cycle (tool-neutral form of (* anyconst *))\n    reg kc_first = 1'b1; always @(posedge clk) kc_first <= 1'b0;\n"
    for n, rng in consts:
        ins += f"    reg {rng} {n}_kq; always @(posedge clk) {n}_kq <= {n};\n    always @* assume (kc_first || {n} == {n}_kq);\n"
    src = src.replace(hdr, hdr + ins, 1)
open(sys.argv[2], "w").write(src)
