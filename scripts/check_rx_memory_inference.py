#!/usr/bin/env python3
"""Check that Yosys retained the expected word-wide payload memory."""
import json
import sys

if len(sys.argv) != 4:
    raise SystemExit("usage: check_rx_memory_inference.py JSON WIDTH DEPTH")

path = sys.argv[1]
expected_width = int(sys.argv[2])
expected_depth = int(sys.argv[3])

with open(path, encoding="utf-8") as stream:
    design = json.load(stream)

memories = []
for module_name, module in design.get("modules", {}).items():
    for cell_name, cell in module.get("cells", {}).items():
        if cell.get("type") != "$mem_v2":
            continue
        params = cell.get("parameters", {})
        width = int(params["WIDTH"], 2)
        depth = int(params["SIZE"], 2)
        memories.append((module_name, cell_name, width, depth))

for module_name, cell_name, width, depth in memories:
    print(f"{module_name}.{cell_name}: width={width} depth={depth}")

if not any(width == expected_width and depth == expected_depth
           for _, _, width, depth in memories):
    raise SystemExit(
        f"Expected inferred memory width={expected_width}, depth={expected_depth}; "
        f"found {memories}"
    )

print(f"PASS: inferred {expected_width}-bit x {expected_depth}-word memory")
