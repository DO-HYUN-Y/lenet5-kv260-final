#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path


DEFAULT_LIMITS = {
    "CLB LUTs": 5.0,
    "CLB Registers": 5.0,
    "Block RAM Tile": 10.0,
    "URAM": 0.0,
    "DSPs": 10.0,
}


def parse_rows(text: str):
    rows = {}
    for line in text.splitlines():
        if "|" not in line:
            continue
        parts = [part.strip() for part in line.split("|")]
        if len(parts) < 6:
            continue
        name = parts[1].rstrip("*").strip()
        used = parts[2]
        pct = parts[-2] if parts[-1] == "" else parts[-1]
        if name in DEFAULT_LIMITS:
            try:
                rows[name] = (float(used), float(pct))
            except ValueError:
                continue
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("utilization_report")
    parser.add_argument("--lut-pct", type=float, default=DEFAULT_LIMITS["CLB LUTs"])
    parser.add_argument("--ff-pct", type=float, default=DEFAULT_LIMITS["CLB Registers"])
    parser.add_argument("--bram-pct", type=float, default=DEFAULT_LIMITS["Block RAM Tile"])
    parser.add_argument("--uram-pct", type=float, default=DEFAULT_LIMITS["URAM"])
    parser.add_argument("--dsp-pct", type=float, default=DEFAULT_LIMITS["DSPs"])
    args = parser.parse_args()

    limits = {
        "CLB LUTs": args.lut_pct,
        "CLB Registers": args.ff_pct,
        "Block RAM Tile": args.bram_pct,
        "URAM": args.uram_pct,
        "DSPs": args.dsp_pct,
    }
    text = Path(args.utilization_report).read_text(errors="replace")
    rows = parse_rows(text)

    problems = []
    for name, limit in limits.items():
        if name not in rows:
            problems.append(f"missing utilization row: {name}")
            continue
        used, pct = rows[name]
        over_limit = pct > limit or (name == "URAM" and limit == 0.0 and used > 0)
        if over_limit:
            problems.append(f"{name} over budget: used={used:g}, pct={pct:g}, limit={limit:g}")

    if problems:
        print("FAIL: utilization budget exceeded")
        for problem in problems:
            print(f"- {problem}")
        return 1

    print("PASS: utilization within budget")
    for name in limits:
        used, pct = rows[name]
        print(f"{name}: used={used:g}, pct={pct:g}, limit={limits[name]:g}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
