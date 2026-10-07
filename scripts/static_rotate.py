#!/usr/bin/env python3
"""static_rotate.py - keep the derivation record usable as it grows.

Every escalation appends a `### round N 재도출` subsection with its evidence to
STATIC.md. That is the right thing to write - the evidence is
what makes a row trustworthy - but the file is read again by the analyst on every
later round, so on a long run it grows past 300 KB and each round costs more than
the one before. On the S921N run rounds went from six minutes to twenty while the
firmware stood still.

Rotation moves the OLD evidence prose out to an archive and keeps the things the
loop and the verification actually read. Nothing derived is lost - archiving
without carrying would silently delete facts:

  stop-point rows       promoted into the main table (derived_facts.py reads them)
  hash_engine rows      moved as they are, table form or one-line form (verify_gates.py
                        reads them: hash_engine_state)
  address-window tables moved as whole tables under a label line (verify_gates.py reads
                        them: address_windows_report)

The last two are not stop points (no owner column), so a rotation that only promoted
stop-point rows turned a `hardware` hash_engine state into `absent` and made the next
labelled hash bypass fail check_change.sh. They are found with verify_gates.py's own
parsers, so what rotation carries and what verification reads cannot drift apart, and
they keep their file order (the last hash_engine row wins there). Code-fenced examples
are not facts for either parser and stay in the archive.

Usage:
  static_rotate.py <workdir> [--max-bytes N] [--keep N]

Output: JSON on stdout. A no-op is reported as rotated=false, never as an error.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from derived_facts import FENCE, HEADING, OWNER, ROW, SECTION  # noqa: E402
import verify_gates as vg  # noqa: E402

ARCHIVE_NAME = "static_archive.md"


def sections(lines):
    """(start, end) of the derived-stop-point section, or None."""
    start = None
    fenced = False
    for i, line in enumerate(lines):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        head = HEADING.match(line)
        if not head:
            continue
        level = len(head.group(1))
        if start is None:
            if level <= 2 and SECTION in line:
                start = i
        elif level <= 2:
            return start, i
    return (start, len(lines)) if start is not None else None


def subsection_bounds(lines, start, end):
    """Index ranges of each `###`+ subsection inside the section."""
    bounds, fenced, opened = [], False, None
    for i in range(start + 1, end):
        if FENCE.match(lines[i]):
            fenced = not fenced
            continue
        if fenced:
            continue
        head = HEADING.match(lines[i])
        if head and len(head.group(1)) >= 3:
            if opened is not None:
                bounds.append((opened, i))
            opened = i
    if opened is not None:
        bounds.append((opened, end))
    return bounds


def is_row(line):
    stripped = line.strip()
    if not stripped.startswith("|"):
        return None
    match = ROW.match(stripped)
    if not match:
        return None
    if match.group(1).lower() in ("시그니처", "signature", "name"):
        return None
    cells = [c.strip() for c in stripped.strip("|").split("|")]
    if not any(OWNER.match(c.strip("` ")) for c in cells[1:]):
        return None
    return match.group(1)


HEADER_NAMES = ("시그니처", "signature", "name")
# A short line (80 characters at most) that names the table: verify_gates.py reads a table under
# such a line as an address-window table even when its header lacks the template's columns.
WINDOWS_LABEL = "주소 창 표 (address windows) - 옛 하위 절에서 옮김"


def is_table_line(line):
    return line.strip().startswith("|")


def table_run_end(lines, first, stop):
    """Index of the last line of the run of table lines that starts at `first`."""
    last = first
    while last + 1 < stop and is_table_line(lines[last + 1]):
        last += 1
    return last


def stop_table_end(lines, start, stop):
    """Last line of the stop-point table in lines[start+1:stop], or None.

    The stop-point table is the first run of table lines that holds its header
    (시그니처 / signature / name) or a row with an owner cell. Taking the LAST table line
    instead would land inside a carried address-window table after the first rotation and push
    the main table apart on the second."""
    fenced = False
    i = start + 1
    while i < stop:
        if FENCE.match(lines[i]):
            fenced = not fenced
            i += 1
            continue
        if fenced or not is_table_line(lines[i]):
            i += 1
            continue
        last = table_run_end(lines, i, stop)
        for k in range(i, last + 1):
            head = ROW.match(lines[k].strip())
            if is_row(lines[k]) or (head and head.group(1).lower() in HEADER_NAMES):
                return last
        i = last + 1
    return None


def carried_facts(lines, lo, hi):
    """What verify_gates.py reads from lines[lo:hi] and that is not a stop-point row.

    Returns (blocks, counts) or None when the lines cannot be mapped one to one onto what the
    parsers saw (then the caller does not rotate). `blocks` are lists of raw lines in file order:
    each hash_engine row on its own, each address-window table under a label line. `counts` is
    {"hash_engine": n, "address_windows": m}."""
    chunk = lines[lo:hi]
    text = "".join(chunk)
    if len(text.splitlines()) != len(chunk):
        return None
    found, spans = [], []
    for table in vg.address_window_tables(text):
        first = table["line"] - 1
        last = first + 1                      # the header, then its separator, then the rows
        while last + 1 < len(chunk) and is_table_line(chunk[last + 1]):
            last += 1
        spans.append((first, last))
        found.append((first, "address_windows", [WINDOWS_LABEL + "\n"] + chunk[first:last + 1]))
    for row in vg.parse_hash_engine_rows(text):
        at = row["line"] - 1
        # A hash_engine row written directly under a window table is a line of that table
        # (the parsers cannot tell them apart): the table already carries it, once.
        if not any(first <= at <= last for first, last in spans):
            found.append((at, "hash_engine", [chunk[at]]))
    found.sort(key=lambda item: item[0])
    blocks, counts = [], {"hash_engine": 0, "address_windows": 0}
    for _, kind, block in found:
        counts[kind] += 1
        block = [ln if ln.endswith("\n") else ln + "\n" for ln in block]
        blocks.append(block)
    return blocks, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workdir")
    parser.add_argument("--max-bytes", type=int, default=120000,
                        help="rotate only once the record is larger than this")
    parser.add_argument("--keep", type=int, default=3,
                        help="how many recent escalation subsections stay inline")
    args = parser.parse_args()

    path = os.path.join(
        args.workdir, "STATIC.md")
    result = {"source": path, "rotated": False, "promoted": 0, "archived": 0}

    if not os.path.exists(path):
        result["reason"] = "기록 파일이 아직 없습니다"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    size = os.path.getsize(path)
    result["bytes_before"] = size
    if size <= args.max_bytes:
        result["reason"] = f"{size}B — 아직 회전 기준({args.max_bytes}B) 이하"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines(keepends=True)

    found = sections(lines)
    if not found:
        result["reason"] = "도출 표 섹션을 찾지 못했습니다"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    start, end = found
    subs = subsection_bounds(lines, start, end)
    older = subs[:-args.keep] if args.keep > 0 else subs
    if not older:
        result["reason"] = f"보관 대상 하위 절 없음 (최근 {args.keep}개만 존재)"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    # Rows written inside the subsections we are about to archive. They must land
    # in the main table before the prose leaves, or the archive would take facts
    # with it.
    promoted = {}
    for lo, hi in older:
        for i in range(lo, hi):
            signature = is_row(lines[i])
            if signature:
                promoted[signature] = lines[i] if lines[i].endswith("\n") else lines[i] + "\n"

    # The facts verification reads from the same subsections (hash_engine rows, address-window
    # tables): they travel with the promoted rows, or the archive would take them along.
    older_lo, older_hi = older[0][0], older[-1][1]
    carried = carried_facts(lines, older_lo, older_hi)
    if carried is None:
        result["reason"] = "하위 절의 줄을 파서의 줄과 맞추지 못해 회전하지 않았습니다 (안전 정지)"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    carried_blocks, carried_counts = carried

    # The main table is the first run of table lines that holds the stop-point header or an owner
    # row (see stop_table_end); a record without such a run keeps the old reading: the last table
    # line before the first subsection.
    preamble_end = older[0][0]
    table_last = stop_table_end(lines, start, preamble_end)
    if table_last is None:
        for i in range(start + 1, preamble_end):
            if is_table_line(lines[i]):
                table_last = i
    if table_last is None:
        result["reason"] = "본문 표를 찾지 못해 회전하지 않았습니다 (안전 정지)"
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    # A promoted signature that already has a row supersedes it: re-derivation
    # corrects the earlier record rather than sitting next to it.
    existing = {}
    for i in range(start + 1, preamble_end):
        signature = is_row(lines[i])
        if signature:
            existing[signature] = i
    for signature, row in list(promoted.items()):
        if signature in existing:
            lines[existing[signature]] = row
            del promoted[signature]

    archive_path = os.path.join(args.workdir, "08_docs", ARCHIVE_NAME)
    os.makedirs(os.path.dirname(archive_path), exist_ok=True)
    archived_text = "".join("".join(lines[lo:hi]) for lo, hi in older)
    with open(archive_path, "a", encoding="utf-8") as fh:
        fh.write(f"\n<!-- {os.path.basename(path)} 에서 이관 -->\n")
        fh.write(archived_text)

    pointer = (f"\n> 오래된 재도출 근거 {len(older)}건은 "
               f"`08_docs/{ARCHIVE_NAME}` 로 옮겼습니다. "
               f"표의 행은 모두 위 본문 표에 남아 있습니다.")
    if carried_blocks:
        pointer += (" 검증이 읽는 hash_engine 행과 주소 창 표는 정지점 행이 아니라서 "
                    "아래에 그대로 옮겼습니다.")
    pointer += "\n\n"

    out = []
    out.extend(lines[:table_last + 1])
    out.extend(promoted.values())
    out.extend(lines[table_last + 1:older[0][0]])
    out.append(pointer)
    for block in carried_blocks:            # file order; one blank line keeps tables apart
        out.extend(block)
        out.append("\n")
    out.extend(lines[older[-1][1]:])

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(out))

    result.update({
        "rotated": True,
        "promoted": len(promoted),
        "carried": carried_counts,
        "archived": len(older),
        "archive": archive_path,
        "bytes_after": os.path.getsize(path),
    })
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
