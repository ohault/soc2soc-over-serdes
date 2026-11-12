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

    candidates = sorted(args.build_dir.rglob("top.v"))
    if len(candidates) != 1:
        raise SystemExit(
            f"expected exactly one generated top.v under {args.build_dir}, "
            f"found {len(candidates)}"
        )

    top = candidates[0]
    verilog = top.read_text(encoding="utf-8")

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
    print(f"Generated top: {top}")
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
