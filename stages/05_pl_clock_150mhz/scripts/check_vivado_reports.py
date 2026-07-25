#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


def read(path):
    return Path(path).read_text(errors="replace") if path else ""


def route_value(text: str, label: str):
    patterns = [
        rf"{re.escape(label)}\s*[:=]\s*(\d+)",
        rf"{re.escape(label)}\.*\s*:\s*(\d+)\s*:",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return int(match.group(1))
    return None


def summary_count(line: str, label: str):
    patterns = [
        rf"\b(\d+)\s+{label}\b",
        rf"\b{label}\s*[:=]\s*(\d+)\b",
    ]
    for pattern in patterns:
        match = re.search(pattern, line, re.IGNORECASE)
        if match:
            return int(match.group(1))
    return None


def check_route(path):
    text = read(path)
    problems = []
    labels = [
        "Number of Failed Nets",
        "Number of Unrouted Nets",
        "Number of Partially Routed Nets",
        "Number of Node Overlaps",
        "# of nets with routing errors",
        "# of nets with some unrouted pins",
        "# of nets with resource conflicts",
    ]
    for label in labels:
        value = route_value(text, label)
        if value is not None and value != 0:
            problems.append(f"route status {label} is {value}")
    for lineno, line in enumerate(text.splitlines(), 1):
        if re.search(r"\b(Route\s+Status|Routing)\b.*\b(FAILED|ERROR)\b", line, re.IGNORECASE):
            problems.append(f"route status line {lineno}: {line[:180]}")
    return problems


def check_drc_or_methodology(path, kind):
    text = read(path)
    problems = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if re.search(r"\bNo Violations Found\b", line, re.IGNORECASE):
            continue
        for label in ("Errors?", "Critical Warnings?", "Violations?", "Failed Checks?"):
            count = summary_count(line, label)
            if count is not None and count > 0:
                problems.append(f"{kind} line {lineno}: {line[:180]}")
                break
        else:
            cells = [cell.strip() for cell in line.split("|")]
            table_has_blocker = (
                len(cells) > 2
                and any(re.fullmatch(r"ERROR|CRITICAL WARNING|VIOLATED|FAIL(?:ED)?", cell, re.IGNORECASE) for cell in cells)
            )
            explicit_status = re.search(r"\b(Status|Severity)\s*[:=]\s*(ERROR|CRITICAL WARNING|VIOLATED|FAIL(?:ED)?)\b", line, re.IGNORECASE)
            if table_has_blocker or explicit_status:
                problems.append(f"{kind} line {lineno}: {line[:180]}")
    return problems


def nonzero_count_for_word(line: str, word: str):
    patterns = [
        rf"\b(\d+)\s+{word}\b",
        rf"\b{word}\s*[:=]\s*(\d+)\b",
    ]
    for pattern in patterns:
        match = re.search(pattern, line, re.IGNORECASE)
        if match:
            return int(match.group(1)) != 0
    return False


def check_cdc(path):
    text = read(path)
    problems = []
    for lineno, line in enumerate(text.splitlines(), 1):
        cells = [cell.strip() for cell in line.split("|")]
        header_cells = {"count", "classification", "severity", "status", "critical", "unsafe", "unknown"}
        is_header = bool(set(cell.lower() for cell in cells if cell.strip()) & header_cells) and not any(
            re.fullmatch(r"\d+", cell) for cell in cells
        )
        if is_header:
            continue
        table_has_blocker = (
            len(cells) > 2
            and any(re.fullmatch(r"Critical|Unsafe|Unknown", cell, re.IGNORECASE) for cell in cells)
            and not any(re.fullmatch(r"0", cell) for cell in cells)
        )
        summary_has_blocker = any(nonzero_count_for_word(line, word) for word in ("Critical", "Unsafe", "Unknown"))
        if table_has_blocker or summary_has_blocker:
            problems.append(f"CDC line {lineno}: {line[:180]}")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--drc")
    parser.add_argument("--methodology")
    parser.add_argument("--cdc")
    parser.add_argument("--route-status")
    args = parser.parse_args()

    problems = []
    if args.route_status:
        problems.extend(check_route(args.route_status))
    if args.drc:
        problems.extend(check_drc_or_methodology(args.drc, "DRC"))
    if args.methodology:
        problems.extend(check_drc_or_methodology(args.methodology, "methodology"))
    if args.cdc:
        problems.extend(check_cdc(args.cdc))

    if problems:
        print("FAIL: Vivado report blockers found")
        for problem in problems:
            print(f"- {problem}")
        return 1

    print("PASS: Vivado reports have no detected blockers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
