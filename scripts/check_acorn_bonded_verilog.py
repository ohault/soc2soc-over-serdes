#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""Structural smoke check for the generated Acorn bonded-target Verilog."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, required=True)
    args = parser.parse_args()

    candidates = sorted(args.build_dir.rglob("*.v"))
    if not candidates:
        raise SystemExit(
            f"no generated Verilog files found under {args.build_dir}"
        )

    print("Generated Verilog files:")
    for path in candidates:
        print(f"  {path}")
    verilog = "\n".join(path.read_text(encoding="utf-8") for path in candidates)
    for line_number, line in enumerate(verilog.splitlines(), start=1):
        if "GTPE2_" in line:
            print(f"{line_number}: {line.strip()}")

    def count(primitive: str) -> int:
        return len(re.findall(rf"\b{re.escape(primitive)}\b", verilog))

    counts = {
        "GTPE2_COMMON": count("GTPE2_COMMON"),
        "GTPE2_CHANNEL": count("GTPE2_CHANNEL"),
        "TXDATA": count("TXDATA"),
        "RXDATA": count("RXDATA"),
        "TXCHARISK": count("TXCHARISK"),
        "RXCHARISK": count("RXCHARISK"),
        "TXOUTCLK": count("TXOUTCLK"),
        "RXOUTCLK": count("RXOUTCLK"),
    }
    expected = {
        "GTPE2_COMMON": 1,
        "GTPE2_CHANNEL": 2,
        "TXDATA": 2,
        "RXDATA": 2,
        "TXCHARISK": 2,
        "RXCHARISK": 2,
        "TXOUTCLK": 2,
        "RXOUTCLK": 2,
    }
    print(f"Inspected {len(candidates)} generated Verilog files under {args.build_dir}")
    for name, value in counts.items():
        print(f"{name}: {value}")
    failures = [
        f"{name}: expected {expected[name]}, found {counts[name]}"
        for name in expected
        if counts[name] != expected[name]
    ]
    if failures:
        raise SystemExit("Acorn bonded Verilog structural check failed:\n" + "\n".join(failures))
    print("PASS: one shared GTP QPLL and two independently clocked GTP channels")


if __name__ == "__main__":
    main()
