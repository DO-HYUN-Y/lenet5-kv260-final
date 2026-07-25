#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def find_metric(text: str, name: str):
    patterns = [
        rf"\b{name}\b\s*\|\s*([-+]?\d+(?:\.\d+)?)",
        rf"\b{name}\b\s*[:=]\s*([-+]?\d+(?:\.\d+)?)",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return float(match.group(1))
    return None


def find_summary_metrics(text: str):
    header = re.search(
        r"WNS\(ns\)\s+TNS\(ns\).*?TPWS Total Endpoints\s*\n\s*-+.*?\n\s*"
        r"([-+]?\d+(?:\.\d+)?)\s+([-+]?\d+(?:\.\d+)?)\s+\d+\s+\d+\s+"
        r"([-+]?\d+(?:\.\d+)?)\s+([-+]?\d+(?:\.\d+)?)\s+\d+\s+\d+\s+"
        r"([-+]?\d+(?:\.\d+)?)\s+([-+]?\d+(?:\.\d+)?)",
        text,
        re.IGNORECASE | re.DOTALL,
    )
    if not header:
        return {}
    keys = ["WNS", "TNS", "WHS", "THS", "WPWS", "TPWS"]
    return {key: float(value) for key, value in zip(keys, header.groups())}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_vivado_timing.py <timing_report>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    text = path.read_text(errors="replace")
    lower = text.lower()

    success_msg = "all user specified timing constraints are met" in lower
    failure_msg = "timing constraints are not met" in lower
    metrics = find_summary_metrics(text)
    wns = metrics.get("WNS", find_metric(text, "WNS"))
    tns = metrics.get("TNS", find_metric(text, "TNS"))
    whs = metrics.get("WHS", find_metric(text, "WHS"))
    ths = metrics.get("THS", find_metric(text, "THS"))
    wpws = metrics.get("WPWS", find_metric(text, "WPWS"))
    tpws = metrics.get("TPWS", find_metric(text, "TPWS"))

    problems = []
    if failure_msg:
        problems.append("Vivado reports timing constraints are not met")
    if not success_msg:
        problems.append("Vivado timing success message is missing")
    if wns is not None and wns < 0:
        problems.append(f"WNS is negative ({wns})")
    if tns is not None and tns < 0:
        problems.append(f"TNS is negative ({tns})")
    if whs is not None and whs < 0:
        problems.append(f"WHS is negative ({whs})")
    if ths is not None and ths < 0:
        problems.append(f"THS is negative ({ths})")
    if wpws is not None and wpws < 0:
        problems.append(f"WPWS is negative ({wpws})")
    if tpws is not None and tpws < 0:
        problems.append(f"TPWS is negative ({tpws})")

    if problems:
        print("FAIL: timing report did not pass")
        for problem in problems:
            print(f"- {problem}")
        for key, value in [("WNS", wns), ("TNS", tns), ("WHS", whs), ("THS", ths),
                           ("WPWS", wpws), ("TPWS", tpws)]:
            if value is not None:
                print(f"{key}={value}")
        return 1

    print("PASS: timing met")
    for key, value in [("WNS", wns), ("TNS", tns), ("WHS", whs), ("THS", ths),
                       ("WPWS", wpws), ("TPWS", tpws)]:
        if value is not None:
            print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
