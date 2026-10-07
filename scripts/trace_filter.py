#!/usr/bin/env python3
"""trace_filter.py - keep the part of a QEMU trace we actually read.

`-d int,in_asm,nochain` writes 10-12 GB per round on a firmware that faults in a
loop. Fifteen rounds filled a 281 GB disk and took WSL down with it. None of that
volume is consumed: the pipeline reads four things out of a trace.

  1. how many exceptions happened          (a count, not the lines)
  2. the FIRST exception block             (the origin - what needs fixing)
  3. the LAST FAR/ELR                      (kept for the record, not diagnosis)
  4. whether each stage entry PC appears, in order   (the chain-trace metric)

So this filter sits between QEMU and the log file and keeps exactly that, in
bounded space. It streams: memory stays flat however long the run goes.

Usage (QEMU writes into a FIFO, this reads it):
  mkfifo $F
  trace_filter.py --out run_3.log --stats st.json --watch 0xc9000000,0x2100000 < $F &
  trace_filter.py --out run_3.log --stats st.json --stage-map stage_map.json < $F &
  qemu ... -D $F

--stage-map reads the entry PC of every runnable stage out of stage_map.json (v2:
`entry_pc`; v1: `base.load_base` + entry offset - the same value verify.py item 4
searches for), so the watch list and the check cannot drift apart.

A PC can show up in a trace without having been executed: an exception block prints FAR
and ELR, and a data abort whose address equals a stage's entry says nothing about that
stage running. `stage_entries_executed` therefore lists only the PCs seen as the first
instruction of a translated block (`0x<pc>:  <insn>`, what -d in_asm prints) - the
sightings that can stand for "the stage was entered". `stage_entries_seen` keeps the
older, looser meaning for verify.py.

Output is a normal text log, so everything downstream keeps working: the head
carries the first exception blocks, the tail carries the last matching lines, and
the middle is replaced by one line saying what was dropped.
"""
import argparse
import collections
import json
import os
import re
import sys

EXC = re.compile(r"Taking exception")
# The lines the summary greps for. Anything matching is worth keeping in the tail.
KEEP = re.compile(r"Taking exception|FAR |ELR |ESR |UPLOAD|E_SYNC|panic|abort|smc",
                  re.I)


def _hex_int(value):
    """int from an entry PC: a JSON number, "0x48c03000" or bare hex "48c03000"."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    text = str(value).strip().lower()
    if not text:
        return None
    try:
        return int(text, 16)
    except ValueError:
        return None


def stage_watch(path):
    """[{name, pc, from}] - the entry PC of every runnable stage in a stage map.

    v2 stages carry `entry_pc` (absolute, filled for AArch64 stages too) and that is the
    only thing read for them. A v1 stage has only a dict `base` and a file offset, so the
    entry is load_base + (entry_pc_file_offset - file_range[0]). The old code kept
    stages whose `base` was an int - but `base` is a dict, so the list was always empty
    and the chain-PC measurement could never pass on any SoC.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    out = []
    for st in data.get("stages") or []:
        if st.get("state") != "exec":
            continue
        pc, how = _hex_int(st.get("entry_pc")), "entry_pc"
        if pc is None:
            base = st.get("base")
            load = base.get("load_base") if isinstance(base, dict) else base
            load = _hex_int(load) if load is not None else None
            off = st.get("entry_pc_file_offset")
            rng = st.get("file_range") or [None, None]
            if load is not None and off is not None and rng and rng[0] is not None:
                pc, how = load + (off - rng[0]), "base+entry_offset"
        if pc is None:
            continue
        out.append({"name": st.get("name") or "stage%s" % st.get("index"),
                    "pc": hex(pc), "from": how})
    return out


def pc_pattern(pc):
    """Regex for a PC as the trace prints it: any zero padding, never a longer number."""
    value = _hex_int(pc)
    if value is None:
        return None, None
    digits = format(value, "x")
    return digits, re.compile(r"0x0*%s(?![0-9a-f])" % digits)


def exec_pattern(digits):
    """The same PC as the first thing on an in_asm instruction line: `0x<pc>:`."""
    return re.compile(r"^\s*0x0*%s\s*:" % digits)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="filtered log to write")
    ap.add_argument("--stats", default=None, help="JSON with the counts")
    ap.add_argument("--watch", default="",
                    help="comma-separated PCs to keep every first sighting of")
    ap.add_argument("--stage-map", default=None,
                    help="stage_map.json: also watch every runnable stage's entry PC")
    ap.add_argument("--max-exceptions", type=int, default=0,
                    help="touch --stop-file once this many exceptions were seen (0 = never)")
    ap.add_argument("--stop-file", default=None,
                    help="file to create when --max-exceptions is exceeded; the harness "
                         "ends the run when it appears")
    ap.add_argument("--head-blocks", type=int, default=40,
                    help="exception blocks kept verbatim from the start")
    ap.add_argument("--block-lines", type=int, default=12,
                    help="lines kept per exception block")
    ap.add_argument("--tail-lines", type=int, default=400,
                    help="matching lines kept from the end")
    args = ap.parse_args()

    watch = []
    for w in args.watch.split(","):
        w = w.strip().lower()
        if w:
            watch.append(w if w.startswith("0x") else "0x" + w)
    watch_stages = stage_watch(args.stage_map) if args.stage_map else []
    for st in watch_stages:
        if st["pc"] not in watch:
            watch.append(st["pc"])
    # digits is a cheap pre-test (plain substring); the pattern then confirms it, so a
    # zero-padded print of the PC counts and a longer number that merely starts with
    # the same digits does not.
    pending_watch = {}
    pending_exec = {}
    for pc in watch:
        digits, rx = pc_pattern(pc)
        if rx is not None:
            pending_watch[pc] = (digits, rx)
            pending_exec[pc] = (digits, exec_pattern(digits))

    early_exit = None
    pending_markers = []            # sightings made inside an exception block
    head = []                       # verbatim start of the trace
    tail = collections.deque(maxlen=args.tail_lines)
    seen_pc = {}                    # pc -> line number of first sighting
    exec_pc = {}                    # pc -> line number of first sighting AS EXECUTED code
    exc_total = 0
    lines_total = 0
    bytes_total = 0
    blocks_kept = 0
    in_block = 0

    for raw in sys.stdin:
        lines_total += 1
        bytes_total += len(raw)
        line = raw.rstrip("\n")

        if EXC.search(line):
            exc_total += 1
            if blocks_kept < args.head_blocks:
                blocks_kept += 1
                in_block = args.block_lines
            if args.max_exceptions and exc_total > args.max_exceptions and early_exit is None:
                # The filter cannot end QEMU; it tells the harness to. It keeps reading
                # afterwards so a writer blocked on the FIFO is never left hanging.
                early_exit = {"reason": "exception_threshold",
                              "limit": args.max_exceptions, "at_line": lines_total}
                if args.stop_file:
                    try:
                        open(args.stop_file, "w").close()
                    except OSError:
                        pass
        # A stage entry PC proves the chain walked. Only the FIRST sighting
        # matters, and order is what the metric checks, so record it once in the
        # order it happened. Checked before the block branch: an entry PC often
        # appears inside the exception block that faulted on it.
        if pending_watch:
            low = line.lower()
            found = None
            for pc, (digits, rx) in pending_watch.items():
                if digits in low and rx.search(low):
                    found = (found or []) + [pc]
            for pc in found or ():
                seen_pc[pc] = lines_total
                del pending_watch[pc]
                marker = f"[stage-entry {pc} @line {lines_total}] {line[:200]}"
                # Inside an exception block the marker waits: splicing it into the
                # block would shift the lines fp_origin reads as the origin.
                (pending_markers if in_block > 0 else head).append(marker)
        # A PC first met in a FAR/ELR line is not yet an entry; keep looking for the
        # instruction line, so a fault that merely names the address cannot stand in
        # for the stage having run.
        if pending_exec:
            low = line.lower()
            for pc in [p for p, (d, rx) in pending_exec.items() if d in low and rx.match(low)]:
                exec_pc[pc] = lines_total
                del pending_exec[pc]

        if in_block > 0:
            head.append(line)
            in_block -= 1
            if in_block == 0 and pending_markers:
                head.extend(pending_markers)
                pending_markers = []
            continue

        if KEEP.search(line):
            tail.append(line)

    head.extend(pending_markers)    # the trace ended inside a block

    # A run that produced NO trace must leave an empty file. "trace and console
    # both zero bytes" is how the harness tells a QEMU that never started from a
    # firmware that faulted; writing a summary line here would erase that signal
    # and an environment failure would be reported as a verdict about the firmware.
    if lines_total == 0:
        open(args.out, "w").close()
        if args.stats:
            with open(args.stats, "w", encoding="utf-8") as fh:
                json.dump({"exceptions": 0, "lines_in": 0, "bytes_in": 0,
                           "lines_kept": 0, "stage_entries_seen": [],
                           "stage_entries_executed": [],
                           "watch": watch, "watch_stages": watch_stages,
                           "early_exit": None},
                          fh, ensure_ascii=False, indent=2)
        return 0

    with open(args.out, "w", encoding="utf-8", errors="replace") as fh:
        for line in head:
            fh.write(line + "\n")
        fh.write(f"\n=== 중간 생략: 원본 {lines_total:,} 줄 / {bytes_total:,} B "
                 f"중 위 {len(head):,} 줄과 아래 {len(tail):,} 줄만 남겼습니다 "
                 f"(예외 {exc_total:,} 건) ===\n\n")
        for line in tail:
            fh.write(line + "\n")

    if args.stats:
        with open(args.stats, "w", encoding="utf-8") as fh:
            json.dump({
                "exceptions": exc_total,
                "lines_in": lines_total,
                "bytes_in": bytes_total,
                "lines_kept": len(head) + len(tail),
                "stage_entries_seen": [
                    {"pc": pc, "line": n}
                    for pc, n in sorted(seen_pc.items(), key=lambda kv: kv[1])
                ],
                "stage_entries_executed": [
                    {"pc": pc, "line": n}
                    for pc, n in sorted(exec_pc.items(), key=lambda kv: kv[1])
                ],
                "watch": watch,
                "watch_stages": watch_stages,
                "early_exit": early_exit,
            }, fh, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
