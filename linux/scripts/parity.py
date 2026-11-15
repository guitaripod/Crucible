#!/usr/bin/env python3
"""Keeps linux/PARITY.md honest: `parity.py done <id>...` checks rows off (dropping their partial mark and gap),
`parity.py open` lists the open rows by size, and every change recounts the summary table."""

import collections
import pathlib
import re
import sys

PATH = pathlib.Path(__file__).resolve().parents[1] / "PARITY.md"
ROW = re.compile(r"^- \[(?P<box>[ x])\] `(?P<id>[^`]+)` \((?P<size>[SML])\) (?P<rest>.*)$")


def mark_done(line: str) -> str:
    """The row checked off, without its partial mark or gap; its Apple TV reference stays."""
    match = ROW.match(line)
    rest = match["rest"].replace("**partial** ", "", 1)
    reference = ""
    if " _Apple TV: " in rest:
        rest, reference = rest.split(" _Apple TV: ", 1)
        reference = " _Apple TV: " + reference
    rest = rest.split(" Gap: ", 1)[0]
    return f"- [x] `{match['id']}` ({match['size']}) {rest}{reference}"


def recount(lines: list[str]) -> list[str]:
    """Rewrites the summary table from the rows under each area heading."""
    counts: dict[str, collections.Counter] = {}
    area = None
    for line in lines:
        if line.startswith("## "):
            area = line[3:].strip()
            counts[area] = collections.Counter()
        elif area and (match := ROW.match(line)):
            rest = match["rest"]
            state = "n/a" if rest.startswith("n/a: ") else "done" if match["box"] == "x" else "partial" if rest.startswith("**partial**") else "missing"
            counts[area][state] += 1
    total = collections.Counter()
    table = []
    for line in lines:
        cells = [cell.strip() for cell in line.strip("|").split("|")] if line.startswith("| ") else []
        if cells and cells[0] in counts:
            c = counts[cells[0]]
            total.update(c)
            line = f"| {cells[0]} | {c['done']} | {c['partial']} | {c['missing']} | {c['n/a']} |"
        elif cells and cells[0] == "**All**":
            line = f"| **All** | {total['done']} | {total['partial']} | {total['missing']} | {total['n/a']} |"
        table.append(line)
    return table


def main() -> None:
    lines = PATH.read_text().split("\n")
    command, ids = sys.argv[1], set(sys.argv[2:])
    if command == "open":
        rows = [ROW.match(line) for line in lines]
        for size in "SML":
            for row in rows:
                if row and row["box"] == " " and row["size"] == size:
                    print(f"{size} {row['id']}: {row['rest'][:110]}")
        return
    found = set()
    for index, line in enumerate(lines):
        match = ROW.match(line)
        if match and match["id"] in ids:
            lines[index] = mark_done(line)
            found.add(match["id"])
    if missing := ids - found:
        sys.exit(f"no such rows: {', '.join(sorted(missing))}")
    PATH.write_text("\n".join(recount(lines)))
    print(f"checked off {len(found)}")


if __name__ == "__main__":
    main()
