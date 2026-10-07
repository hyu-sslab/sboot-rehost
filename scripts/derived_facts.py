#!/usr/bin/env python3
"""derived_facts.py - measure what the analyst actually added, instead of asking it.

The loop needs to know whether a re-derivation produced anything new. Asking the
analyst ("how many new facts did you find?") makes the stop condition depend on a
self-reported number that nothing can contradict, so the same address gets
"newly derived" every round and the loop never ends.

The analyst appends its findings to one record per firmware - the `## 도출된 정지점`
table in STATIC.md. This script parses that table, remembers
every signature it has already seen in derived_facts.jsonl, and reports how many
are new. Re-deriving the same stop point adds no row, so `new` is 0 and the
exhaustion condition becomes a fact rather than a claim.

Usage:
  derived_facts.py <workdir> [--peek]

  --peek   report without recording, so a caller can look without consuming

Output: JSON on stdout
"""
import argparse
import json
import os
import re
import sys

SECTION = "도출된 정지점"
ROW = re.compile(r"^\|\s*`?([A-Za-z0-9_]+)`?\s*\|(.*)$")
# A markdown heading starts at column 0 and is followed by a space. Matching a
# bare leading '#' also matched wrapped prose ("#179→#180 증가...") and code
# comments, and each false heading silently closed the section.
HEADING = re.compile(r"^(#{1,6})(?:\s|$)")
FENCE = re.compile(r"^(```|~~~)")
# A derived stop point names the fixer that owns it - that is what the table is
# for. Tables of derived VALUES (carve, bss_start, entry PC ...) live in the same
# document and must not be handed to the classifier as stop points.
OWNER = re.compile(r"^(fixer-[a-z0-9-]+|build|rebuild)$")


def parse_table(path):
    """Rows of the derived-stop-point table, in file order.

    Only a top-level (`#`/`##`) heading opens or closes the section. The analyst
    writes one `### round N 재도출` subsection per escalation INSIDE the section
    and appends its row there, so treating a subsection heading as a section
    boundary closed the table after the first escalation: every row written from
    then on was invisible to the classifier and the fixers. On the S921N run that
    hid 17 of 20 derived stop points - the derivation was recorded exactly as
    asked and still reached nobody.
    """
    if not os.path.exists(path):
        return []
    rows, inside, fenced = [], False, False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if FENCE.match(line):
                fenced = not fenced
                continue
            if fenced:
                continue
            heading = HEADING.match(line)
            if heading:
                if len(heading.group(1)) <= 2:
                    inside = SECTION in line
                continue
            stripped = line.strip()
            if not inside or not stripped.startswith("|"):
                continue
            match = ROW.match(stripped)
            if not match:
                continue
            signature = match.group(1)
            # skip the header and its |---|---| separator
            if signature.lower() in ("시그니처", "signature", "name"):
                continue
            # Columns cannot be taken positionally. A derived mechanism quotes
            # instruction bytes (`4ac10011|280140b9|...`) and unescaped pipes in
            # those cells shifted every column right, so the owner landed in the
            # middle of a sentence and the row was dropped. Anchor on the owner
            # cell instead: it is the one cell with a closed vocabulary.
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            owner_at = next((i for i, c in enumerate(cells)
                             if i > 0 and OWNER.match(c.strip("` "))), -1)
            if owner_at < 0:
                continue
            rows.append({
                "signature": signature,
                "observation": cells[1] if len(cells) > 1 else "",
                "mechanism": "|".join(cells[2:owner_at]),
                "fixer": cells[owner_at].strip("` "),
                "treatment": "|".join(cells[owner_at + 1:]),
            })

    # One row per signature. Re-derivation of the same stop point corrects the
    # earlier row rather than adding a second one, so the newest wins while the
    # position stays where the signature first appeared.
    merged = {}
    for row in rows:
        merged[row["signature"]] = row
    return list(merged.values())


def read_seen(path):
    if not os.path.exists(path):
        return []
    seen = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                seen.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return seen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workdir")
    parser.add_argument("--peek", action="store_true",
                        help="report without recording")
    args = parser.parse_args()

    static = os.path.join(
        args.workdir, "STATIC.md")
    ledger = os.path.join(args.workdir, "derived_facts.jsonl")

    rows = parse_table(static)
    seen = {r.get("signature") for r in read_seen(ledger)}
    fresh = [r for r in rows if r["signature"] not in seen]

    if fresh and not args.peek:
        with open(ledger, "a", encoding="utf-8") as fh:
            for row in fresh:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    json.dump({
        "source": static,
        "source_exists": os.path.exists(static),
        "total": len(rows),
        "new": len(fresh),
        "new_signatures": [r["signature"] for r in fresh],
        # Everything derived so far, so the classifier and the fixers can match
        # against it without re-reading the markdown themselves.
        "stop_points": rows,
    }, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
