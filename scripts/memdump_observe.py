#!/usr/bin/env python3
"""memdump_observe.py - read the guest kernel log out of RAM (the `memdump` channel).

Some firmware never lets the kernel speak on the UART: the log goes to a RAM ring
(pstore / ramoops) and the console stays silent. Silence is then not evidence of
failure, and the UART alone cannot say whether the kernel ran. The host can read
that ring while the guest runs - QEMU's monitor `pmemsave` writes any physical
range to a file - so the kernel log becomes a second observation channel next to
the UART. It is evidence because the HOST reads RAM the machine never writes to
(the gates in verify.py check the machine source for that); nothing here adds text.

Where the ring is, and how big, is NEVER written in this file. It comes from
`memdump_plan.json` (static-analyzer derives it; `derive` below reads it out of
the bootloader's own log or the kernel command line, and returns the evidence line).

    {"channel": "memdump", "region_base": "0x..", "region_size": N,
     "console_size": N, "source": "lk_log|cmdline|dtb", "evidence": "..."}

A plan MAY also carry "reset_patterns" (list) and "reset_window_s" for the
guest-reset signal; no device value lives in this script either.

Subcommands
-----------
  watch         drive the monitor socket: pmemsave at an adaptive interval, then merge
  merge         snapshot directory -> merged kernel log (+ gap report)
  derive        region out of a bootloader UART log and/or kernel command line text
  check-plan    exit 0 when memdump_plan.json is usable
  region        the plan's region as <base>:<size> (hex), the form the machine's
                write guard reads from REHOST_MEMDUMP_REGION; exit 1 when unusable
  task-regex    the kernel-task line shape: first non-empty line of a file (or a
                value), checked to compile and to be specific enough to name a task
                (min_literals, TASK_PROBES); prints it. Exit 0 usable, 1 absent or
                invalid, 3 compiles but too loose (refused: the scan uses the default)
  scan          memdump-channel milestone tokens against the merged kernel log
  metrics       last kernel time / distinct lines of a merged kernel log
  reset-signal  did the guest reset right after kernel_entry (host-line patterns)
  split-host    move QEMU host diagnostic lines out of a console file

The merged log is one "<kernel_seconds> <text>" line per entry, sorted by time.
Transformations are deletion-only: lines that are hex dumps are dropped, a line
torn by the ring wrap is dropped when a complete copy exists. Nothing is added or
rewritten, and the raw snapshots are kept.

Known limits (measured, not hidden)
-----------------------------------
* The ring is read as raw memory and its internal layout is NOT interpreted (nothing
  about it is derived from the target). The one entry that straddles the point where
  the ring wraps is cut in two: its second half sits at the start of the buffer and is
  not joined, its first half survives as a truncated entry (on the measured firmware it
  ends where the next buffer's header begins). The same entry straddles in every
  snapshot that holds it, so it is never recovered, and about one line per wrap is
  cut without any gap showing. Gaps (> 1.5 s between neighbours) catch what the ring
  overwrote between two dumps; they do not catch this. Truncated entries are kept
  as they parsed, not repaired and not removed.
* Only a line that runs to the very end of a dump is treated as "torn" (dropped when a
  complete copy exists).
* Region sources: a DTB reserved-memory node is not parsed (source "dtb" is accepted
  in a plan, nothing here produces it).
"""
import argparse
import collections
import glob
import json
import os
import re
import signal
import socket
import sys
import threading
import time

# ---------------------------------------------------------------------------
# constants - formats and tunables, never device values
# ---------------------------------------------------------------------------

# One kernel log entry as the ring stores it: "[  12.345678] text\n".
LINE = re.compile(rb"\[\s*(\d+\.\d+)\] ([\x20-\x7e]+)")
# Hex dump continuation lines; the only text this tool is allowed to delete.
HEXDUMP = re.compile(r": \[0x[0-9a-f]+\] = ")
# The task a kernel line was printed from, as "[<pid>:<comm>]" near the start of the text.
# This is the one shape confirmed on one kernel only; another kernel's ring may print its
# task differently, and then the analyst writes the shape for THIS target into
# <workdir>/kernel_task_regex.txt (run_full.sh hands its first non-empty line to this
# process as KERNEL_TASK_REGEX; an explicit KERNEL_TASK_REGEX in the environment wins).
# The text is an extended regular expression, searched in the first TASK_WINDOW characters
# of a line. Its first group, when it has one, is the task name; without a group the whole
# match is. A shape that is too loose to name a task is refused (see assess_task_regex), and
# one that is accepted is reported with the lines it alone recognised (scan_memdump).
DEFAULT_TASK_REGEX = r"\[\s*\d+:([^\]\s]+)[^\]]*\]"
TASK_WINDOW = 64
# A kernel running prints more than one line; one stray line is not continuity.
ALIVE_MIN_LINES = int(os.environ.get("KERNEL_ALIVE_MIN_LINES", "2"))
BANNER = "Linux version"

GAP_THRESHOLD_S = 1.5
PROMPT = b"(qemu) "

# QEMU's own diagnostics: "qemu-system-aarch64: info: ...", possibly after an epoch.
HOST_LINE = re.compile(rb"^(?:\d+(?:\.\d+)?\s+)?qemu-system-[\w-]+: ")

RESET_PATTERNS_ENV = "REHOST_RESET_PATTERNS"
RESET_WINDOW_ENV = "REHOST_RESET_WINDOW_S"
DEFAULT_RESET_WINDOW_S = 10.0


def log(msg):
    print(msg, file=sys.stderr)


# POSIX bracket classes, which an extended regular expression has and Python's `re` does
# not: `[[:digit:]]` would silently read as the set `[:digit` followed by a literal `]`.
_POSIX_CLASSES = {
    "alpha": "a-zA-Z", "digit": "0-9", "alnum": "a-zA-Z0-9", "upper": "A-Z",
    "lower": "a-z", "xdigit": "0-9A-Fa-f", "space": " \\t\\n\\r\\f\\v", "blank": " \\t",
    "punct": "!-/:-@\\[-`{-~", "cntrl": "\\x00-\\x1f\\x7f", "print": "\\x20-\\x7e",
    "graph": "\\x21-\\x7e",
}


def ere_to_python(pattern):
    """An extended regular expression as a Python pattern.

    Only the bracket classes are rewritten; everything else is already the same
    language (a backslash keeps its Python meaning, also inside a set).
    """
    out, i, n, inside = [], 0, len(pattern), False
    while i < n:
        c = pattern[i]
        if c == "\\" and i + 1 < n:
            out.append(pattern[i:i + 2])
            i += 2
            continue
        if not inside:
            out.append(c)
            i += 1
            if c == "[":
                inside = True
                if i < n and pattern[i] == "^":
                    out.append("^")
                    i += 1
                if i < n and pattern[i] == "]":      # a ] first in the set is a literal
                    out.append("\\]")
                    i += 1
            continue
        if c == "[" and pattern.startswith("[:", i):
            end = pattern.find(":]", i + 2)
            if end > 0 and pattern[i + 2:end] in _POSIX_CLASSES:
                out.append(_POSIX_CLASSES[pattern[i + 2:end]])
                i = end + 2
                continue
        if c == "]":
            inside = False
        elif c == "[":
            out.append("\\[")                         # a literal [ in a set
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def compile_task_regex(text):
    """(compiled, "") or (None, why) for a task-line shape written as an ERE."""
    try:
        return re.compile(ere_to_python(text)), ""
    except re.error as exc:
        return None, "정규식이 올바르지 않음: %s" % exc


# The shape decides what counts as "a line the kernel printed" (kernel_alive on this channel
# needs a kernel time AND a task, on more than one line), and the analyst may choose it for
# this target. A shape so loose that the bootloader's own lines in the shared ring satisfy it
# would credit a kernel that never ran, so a shape is checked when it is READ, before it can
# judge anything, on two things that need no knowledge of any device:
#   * it must pin down at least MIN_TASK_LITERALS fixed characters - every match, by its
#     cheapest branch, has to carry them. `\w+`, `.`, `[a-z]+ [a-z]+` pin down none; the
#     default shape pins down three (`[`, `:`, `]`).
#   * it must not match lines that plainly carry no task (TASK_PROBES: plain words, an
#     address, numbers - text a bootloader prints, with none of the brackets or markers a
#     task prefix is made of).
# A shape that fails is NOT used (the default applies, as for one that does not compile) and
# the report says which shape was refused and why. A shape that passes is still reported as
# custom, with how well it separated the lines of THIS ring (see scan_memdump).
MIN_TASK_LITERALS = 3
TASK_PROBES = ("", "boot start", "jump to 0x40080000", "ready 12 34 ok")


def min_literals(pattern):
    """Fewest fixed (non-blank) characters any match of a Python-syntax pattern carries.

    Escapes that stand for a class (\\d \\w \\s ...), `.`, sets, anchors and look-arounds
    count none; a quantifier that allows zero repeats removes its atom; an alternation takes
    its poorest branch. Under-counting is the safe side: it can only refuse a shape.
    """
    n = len(pattern)
    pos = [0]

    def skip_set():
        pos[0] += 1                                   # the [
        if pos[0] < n and pattern[pos[0]] == "^":
            pos[0] += 1
        if pos[0] < n and pattern[pos[0]] == "]":
            pos[0] += 1
        while pos[0] < n and pattern[pos[0]] != "]":
            pos[0] += 2 if pattern[pos[0]] == "\\" else 1
        pos[0] += 1                                   # the ]

    def skip_to_close():
        while pos[0] < n and pattern[pos[0]] != ")":
            pos[0] += 2 if pattern[pos[0]] == "\\" else 1
        pos[0] += 1

    def group():
        """After `(`: the group's own prefix, then its body. 0 for a zero-width one."""
        if pos[0] < n and pattern[pos[0]] == "?":
            rest = pattern[pos[0] + 1:]
            if rest.startswith(":"):
                pos[0] += 2
            elif rest.startswith("P<"):
                pos[0] = pattern.find(">", pos[0]) + 1 or n
            elif rest.startswith(("=", "!", "<=", "<!")):
                pos[0] += 2 if rest[0] in "=!" else 3
                alt()
                pos[0] += 1
                return 0                              # a look-around matches no text
            else:
                m = re.match(r"\?[aiLmsux-]+(:)?", pattern[pos[0]:])
                if m and m.group(1):
                    pos[0] += m.end()
                else:
                    skip_to_close()
                    return 0                          # flags, a comment, a back-reference
        found = alt()
        if pos[0] < n and pattern[pos[0]] == ")":
            pos[0] += 1
        return found

    def atom():
        c = pattern[pos[0]]
        if c == "(":
            pos[0] += 1
            return group()
        if c == "[":
            skip_set()
            return 0
        if c == "\\":
            e = pattern[pos[0] + 1] if pos[0] + 1 < n else ""
            pos[0] += 2
            if e in "dDwWsSbBAZ" or e.isdigit() or e in "nrtfv":
                return 0
            if e == "x":
                pos[0] += 2
            elif e in "uU":
                pos[0] += 4 if e == "u" else 8
            return 1
        pos[0] += 1
        return 0 if c in ".^$" or c.isspace() else 1

    def quantified():
        count = atom()
        if pos[0] >= n:
            return count
        c, rep = pattern[pos[0]], None
        if c in "*?":
            rep, pos[0] = 0, pos[0] + 1
        elif c == "+":
            rep, pos[0] = 1, pos[0] + 1
        elif c == "{":
            m = re.match(r"\{(\d*)(,(\d*))?\}", pattern[pos[0]:])
            if m and (m.group(1) or m.group(2)):
                rep, pos[0] = int(m.group(1) or 0), pos[0] + m.end()
        if rep is None:
            return count
        if pos[0] < n and pattern[pos[0]] in "?+":
            pos[0] += 1                               # lazy / possessive
        return count * rep

    def seq():
        total = 0
        while pos[0] < n and pattern[pos[0]] not in "|)":
            total += quantified()
        return total

    def alt():
        best = seq()
        while pos[0] < n and pattern[pos[0]] == "|":
            pos[0] += 1
            best = min(best, seq())
        return best

    return alt()


def assess_task_regex(text, rx):
    """[why, ...] a compiled task-line shape cannot be trusted to name a kernel task;
    empty when it can be read as one."""
    problems = []
    fixed = min_literals(ere_to_python(text))
    if fixed < MIN_TASK_LITERALS:
        problems.append("모든 일치가 담는 고정 글자가 %d 개뿐 (최소 %d) — 태스크 접두를 가리키지 못함"
                        % (fixed, MIN_TASK_LITERALS))
    for probe in TASK_PROBES:
        if rx.search(probe[:TASK_WINDOW]):
            problems.append("태스크가 없는 줄에도 맞음: %r" % probe)
            break
    return problems


def judge_task_regex(text):
    """(compiled, why_not_compiled, problems) for a task-line shape written as an ERE."""
    rx, why = compile_task_regex(text)
    return rx, why, (assess_task_regex(text, rx) if rx else [])


def _pick_task_regex():
    """(compiled, text, custom, rejected). An unusable KERNEL_TASK_REGEX is said so and not
    used: the shape decides what counts as a running kernel, so a broken one must not crash
    every subcommand, and must not pass for a decision either. `rejected` is None, or
    {"pattern", "problems"} for a shape that compiled but was refused (too loose)."""
    raw = os.environ.get("KERNEL_TASK_REGEX")
    rejected = None
    if raw:
        rx, why, problems = judge_task_regex(raw)
        if rx and not problems:
            return rx, raw, True, None
        if rx:
            rejected = {"pattern": raw, "problems": problems}
            log("memdump: KERNEL_TASK_REGEX 를 쓰지 않습니다 — %s — 기본 형식을 씁니다" % "; ".join(problems))
        else:
            log("memdump: KERNEL_TASK_REGEX %s — 기본 형식을 씁니다" % why)
    return re.compile(DEFAULT_TASK_REGEX), DEFAULT_TASK_REGEX, False, rejected


TASK_RE, TASK_REGEX_TEXT, TASK_REGEX_CUSTOM, TASK_REGEX_REJECTED = _pick_task_regex()


# ---------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------

def memparse(value):
    """int from 12, "0xe0000", "917504", "256K", "1M" (the kernel's memparse)."""
    if isinstance(value, bool):
        raise ValueError("bool")
    if isinstance(value, int):
        return value
    text = str(value).strip()
    mult = 1
    if text and text[-1] in "kKmMgG":
        mult = {"k": 1 << 10, "m": 1 << 20, "g": 1 << 30}[text[-1].lower()]
        text = text[:-1]
    return int(text, 0) * mult


def load_plan(path):
    """The memdump plan normalised, or None when the channel is off.

    Absent, unreadable or incomplete means OFF - the round then runs exactly as it
    did before the channel existed. A guessed region would be worse than none.
    """
    plan, why = read_plan(path)
    return plan


def read_plan(path):
    if not path or not os.path.exists(path):
        return None, "memdump_plan.json 없음"
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError) as exc:
        return None, f"memdump_plan.json 을 읽지 못함: {exc}"
    if not isinstance(raw, dict):
        return None, "memdump_plan.json 이 객체가 아님"
    if raw.get("channel", "memdump") != "memdump":
        return None, f"channel={raw.get('channel')!r} (memdump 가 아님)"
    try:
        base = memparse(raw["region_base"])
        size = memparse(raw["region_size"])
    except (KeyError, ValueError, TypeError):
        return None, "region_base / region_size 가 없거나 숫자가 아님"
    if size <= 0 or base < 0:
        return None, "region_size 가 0 이하"
    try:
        console = memparse(raw.get("console_size") or 0)
    except (ValueError, TypeError):
        console = 0
    assumed = console <= 0 or console > size
    patterns = raw.get("reset_patterns") or []
    if not isinstance(patterns, list):
        patterns = []
    window = raw.get("reset_window_s")
    try:
        window = float(window) if window is not None else None
    except (TypeError, ValueError):
        window = None
    return {
        "base": base,
        "size": size,
        "console_size": console,
        # Ring capacity drives the sampling interval. Without console_size the whole
        # region is the upper bound - recorded, because it makes the interval too long.
        "capacity": size if assumed else console,
        "capacity_assumed": assumed,
        "source": raw.get("source", ""),
        "evidence": raw.get("evidence", ""),
        "reset_patterns": [str(p) for p in patterns if str(p)],
        "reset_window_s": window,
    }, ""


# ---------------------------------------------------------------------------
# snapshots -> merged log
# ---------------------------------------------------------------------------

def parse_snapshot(data):
    """[(kernel_time, text, torn, raw_bytes)] for every log entry in one dump.

    The ring is dumped as raw memory, so a wrapped ring has one entry cut where the
    end of the region meets the start. `torn` marks an entry that runs to the very end
    of the dump with no terminator; merge() drops it when a complete copy exists.
    Read as BYTES: a text-mode read silently loses lines that begin with "\\r".
    """
    out = []
    for m in LINE.finditer(data):
        out.append((float(m.group(1)), m.group(2).decode("latin1"),
                    m.end() == len(data), m.end() - m.start() + 1))
    return out


def merge_parsed(parsed_snaps):
    """Union of snapshots as a time-sorted [(t, text)] list, deletion-only."""
    state = {}                              # (t, text) -> only ever seen torn?
    for snap in parsed_snaps:
        for t, text, torn, _ in snap:
            key = (t, text)
            state[key] = state.get(key, True) and torn
    by_time = collections.defaultdict(list)
    for (t, text) in state:
        by_time[t].append(text)
    kept = []
    for (t, text), torn_only in state.items():
        if HEXDUMP.search(text):
            continue                        # R4: hex dump lines
        if torn_only and any(o != text and o.startswith(text) for o in by_time[t]):
            continue                        # the wrap cut this line; a whole copy exists
        kept.append((t, text))
    kept.sort()
    return kept


def find_gaps(entries, threshold=GAP_THRESHOLD_S):
    """Consecutive entries further apart than `threshold` seconds = suspected loss."""
    gaps = []
    for (a, _), (b, _) in zip(entries, entries[1:]):
        if b - a > threshold:
            gaps.append((a, b, round(b - a, 6)))
    return gaps


def gap_report(entries, threshold=GAP_THRESHOLD_S):
    gaps = find_gaps(entries, threshold)
    span = (entries[-1][0] - entries[0][0]) if entries else 0.0
    return {
        "threshold_s": threshold,
        "count": len(gaps),
        "total_s": round(sum(g[2] for g in gaps), 6),
        "span_s": round(span, 6),
        "list": [list(g) for g in gaps[:50]],
    }


def write_log(entries, path):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="latin1") as fh:
        for t, text in entries:
            fh.write("%.6f %s\n" % (t, text))
    os.replace(tmp, path)


def read_log(path):
    """[(t, text)] from a merged kernel log; malformed lines are skipped."""
    entries = []
    try:
        with open(path, encoding="latin1") as fh:
            for line in fh:
                head, _, text = line.rstrip("\n").partition(" ")
                try:
                    entries.append((float(head), text))
                except ValueError:
                    continue
    except OSError:
        pass
    return entries


def kernel_metrics(entries):
    """The kernel-channel part of a fingerprint."""
    if not entries:
        return {"lines": 0, "uniq": 0, "first_time": None, "last_time": None,
                "task_lines": 0}
    return {
        "lines": len(entries),
        # Distinct TEXTS: a poll that prints the same line a hundred thousand times,
        # each with its own timestamp, is not depth - same reason the UART counts
        # distinct lines instead of bytes.
        "uniq": len({text for _, text in entries}),
        "first_time": entries[0][0],
        "last_time": entries[-1][0],
        "task_lines": sum(1 for _, text in entries if task_of(text)),
    }


def task_of(text):
    m = TASK_RE.search(text[:TASK_WINDOW])
    if not m:
        return None
    return m.group(1) if m.groups() else m.group(0)


# ---------------------------------------------------------------------------
# adaptive sampling interval
# ---------------------------------------------------------------------------

class IntervalPlanner:
    """How long until the next dump so the ring cannot wrap unseen.

    A fixed interval was right for the first seconds and wrong later: the same kernel
    printed 110 lines/s early and several times that in a polling loop, and a ring that
    holds ~15 s of the first fills in a few seconds of the second. Anything that wraps
    between two dumps is gone. So: interval <= safety * capacity / (recent fill rate),
    clamped to [floor, ceiling]. The rate is the MAXIMUM of the last few windows - a
    burst must shorten the next interval, not be averaged away.
    """

    def __init__(self, capacity, floor=2.0, ceiling=12.0, initial=5.0,
                 safety=0.5, window=3):
        self.capacity = max(1, int(capacity))
        self.floor = float(floor)
        self.ceiling = max(float(ceiling), self.floor)
        self.initial = min(max(float(initial), self.floor), self.ceiling)
        self.safety = float(safety)
        self.rates = collections.deque(maxlen=window)
        self.seen_data = False
        self.interval = self.initial

    def update(self, new_bytes, dt, overrun=False):
        if new_bytes > 0:
            self.seen_data = True
        if overrun:
            # Some of what was written is already gone, so new_bytes undercounts.
            # The ring was full, which is the least it can have been.
            new_bytes = max(new_bytes, self.capacity)
        if dt > 0:
            self.rates.append(new_bytes / dt)
        rate = max(self.rates) if self.rates else 0.0
        if rate <= 0:
            # Nothing yet: the kernel may not have registered its ring (it replays
            # what came before once it does). Keep looking soon until data shows up;
            # a quiet kernel that HAS logged can be sampled slowly.
            self.interval = self.ceiling if self.seen_data else self.initial
        else:
            want = self.safety * self.capacity / rate
            self.interval = min(max(want, self.floor), self.ceiling)
        return self.interval


# ---------------------------------------------------------------------------
# QEMU monitor
# ---------------------------------------------------------------------------

class MonitorGone(Exception):
    """The monitor socket is not there (QEMU exited or never started)."""


def _read_until_prompt(sock, timeout):
    """Bytes up to and including the monitor prompt, or what arrived by `timeout`."""
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            raise MonitorGone("monitor closed")
        buf += chunk
        at = buf.rfind(PROMPT)
        # readline may print a few control bytes after the prompt; allow for them
        if at >= 0 and len(buf) - (at + len(PROMPT)) <= 16:
            return buf
    return buf


def hmp(sock_path, command, banner_wait=5.0, reply_wait=15.0):
    """Run one HMP command on a fresh connection; returns the reply text.

    A connection per command: the unix monitor accepts one client at a time and a
    long-lived connection that wedges would take the channel with it.
    """
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5.0)
    try:
        try:
            s.connect(sock_path)
        except (OSError, socket.timeout) as exc:
            raise MonitorGone(str(exc))
        # The banner is soft: a monitor that prints none must still get the command.
        _read_until_prompt(s, banner_wait)
        s.sendall(command.encode() + b"\n")
        reply = _read_until_prompt(s, reply_wait)
    finally:
        s.close()
    return reply.decode("latin1", "replace")


def take_snapshot(sock_path, plan, path, file_wait=3.0):
    """pmemsave the region into `path`. True only when the whole region landed."""
    part = path + ".part"
    try:
        os.unlink(part)
    except OSError:
        pass
    reply = hmp(sock_path, 'pmemsave %#x %d "%s"' % (plan["base"], plan["size"], part))
    # pmemsave is synchronous, so the file is whole when the prompt returns. A prompt
    # we mistook (a late banner) must not turn a good dump into a failure: give the
    # file a moment to reach its size before judging it.
    ok = False
    for _ in range(int(file_wait / 0.05) + 1):
        try:
            ok = os.path.getsize(part) == plan["size"]
        except OSError:
            ok = False
        if ok:
            break
        time.sleep(0.05)
    if not ok:
        tail = reply.strip().splitlines()[-1] if reply.strip() else "응답 없음"
        log("memdump: pmemsave 실패 — %s" % tail)
        return False
    os.replace(part, path)
    return True


class FileTail:
    """Follow a file another process appends to, keeping a bounded tail."""

    def __init__(self, path, keep=4096):
        self.path, self.keep, self.pos, self.tail = path, keep, 0, b""

    def has(self, token):
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return False
        if size < self.pos:
            self.pos = 0
        data = b""
        if size > self.pos:
            with open(self.path, "rb") as fh:
                fh.seek(self.pos)
                data = fh.read(1 << 20)
            self.pos += len(data)
        buf = self.tail + data
        self.tail = buf[-max(self.keep, len(token) * 2):]
        return token in buf


def snapshot_files(snap_dir):
    def num(p):
        return int(re.search(r"ps_(\d+)\.bin$", p).group(1))
    return sorted(glob.glob(os.path.join(snap_dir, "ps_*.bin")), key=num)


# ---------------------------------------------------------------------------
# watch
# ---------------------------------------------------------------------------

def cmd_watch(args):
    plan = load_plan(args.plan)
    if not plan:
        log("memdump: 계획을 쓸 수 없어 채널을 켜지 않습니다 (%s)" % read_plan(args.plan)[1])
        return 2
    stop = threading.Event()
    signalled = []

    def on_signal(*_):
        signalled.append(True)
        stop.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, on_signal)
    os.makedirs(args.snap_dir, exist_ok=True)

    t0 = time.time()
    deadline = t0 + args.deadline if args.deadline else None
    final_at = (deadline - args.final_margin) if deadline else None
    planner = IntervalPlanner(plan["capacity"], args.floor, args.ceiling,
                              args.initial, args.safety)

    ended = "deadline" if deadline else "signal"
    started = "immediate"
    # QEMU creates the socket at startup; wait for it, bounded.
    wait_until = t0 + args.socket_wait
    while not os.path.exists(args.socket) and time.time() < wait_until and not stop.is_set():
        stop.wait(0.1)
    if not os.path.exists(args.socket):
        ended = "no_monitor"
        stop.set()

    # Start when the bootloader announces the jump; the ring is empty before that and
    # the first seconds after it stay empty until the kernel registers its console.
    if args.start_token and args.console and not stop.is_set():
        tail, tok = FileTail(args.console), args.start_token.encode()
        started = "kernel_entry"
        while not tail.has(tok):
            if stop.is_set():
                break
            if final_at is not None and time.time() >= final_at:
                started = "deadline"      # never saw the jump; still look once at the end
                break
            stop.wait(0.2)

    parsed, seen = [], set()
    ok_n = fail_n = overruns = empties = 0
    prev_nonempty = False
    intervals = []
    last_wall = time.time()
    k = 0
    while not stop.is_set():
        k += 1
        path = os.path.join(args.snap_dir, "ps_%d.bin" % k)
        try:
            ok = take_snapshot(args.socket, plan, path)
        except MonitorGone:
            ended = "monitor_lost"
            break
        now = time.time()
        if not ok:
            fail_n += 1
            if fail_n >= 3 and ok_n == 0:
                ended = "snapshot_failed"
                break
        else:
            ok_n += 1
            with open(path[:-4] + ".time", "w") as fh:
                fh.write("%.6f\n" % now)
            with open(path, "rb") as fh:
                snap = parse_snapshot(fh.read())
            keys = [(t, text) for t, text, _, _ in snap]
            new_bytes = sum(b for t, text, _, b in snap if (t, text) not in seen)
            overrun = bool(prev_nonempty and keys and not any(key in seen for key in keys))
            if overrun:
                overruns += 1
            if not keys:
                empties += 1
            seen.update(keys)
            prev_nonempty = prev_nonempty or bool(keys)
            parsed.append(snap)
            planner.update(new_bytes, now - last_wall, overrun)
            last_wall = now
            intervals.append(planner.interval)
        if stop.is_set():
            break
        nxt = now + planner.interval
        if final_at is not None:
            if now >= final_at - 1e-6:
                break                       # that was the last one
            nxt = min(nxt, final_at)        # one more dump right before the run ends
        stop.wait(max(0.0, nxt - time.time()))

    if signalled and ended in ("deadline", "signal"):
        ended = "signal"                    # the run ended first and told us to stop
    entries = merge_parsed(parsed)
    write_log(entries, args.out)
    stats = {
        "enabled": True,
        "region": {"base": "%#x" % plan["base"], "size": plan["size"],
                   "console_size": plan["console_size"],
                   "capacity_assumed": plan["capacity_assumed"],
                   "source": plan["source"], "evidence": plan["evidence"]},
        "snapshots": ok_n,
        "snapshots_failed": fail_n,
        "snap_dir": args.snap_dir,
        "started": started,
        "start_token": args.start_token or "",
        "interval": {"floor": planner.floor, "ceiling": planner.ceiling,
                     "min_used": min(intervals) if intervals else None,
                     "max_used": max(intervals) if intervals else None},
        "overruns": overruns,
        "empty_snapshots": empties,
        "ended": ended,
        "log": args.out,
    }
    stats.update(kernel_metrics(entries))
    stats["gaps"] = gap_report(entries)
    if args.stats:
        with open(args.stats, "w", encoding="utf-8") as fh:
            json.dump(stats, fh, ensure_ascii=False, indent=2)
    g = stats["gaps"]
    log("memdump: 스냅샷 %d 개, 커널 로그 %d 줄 (마지막 %s s), 유실 의심 %d 구간 합 %.1f s / %.0f s"
        % (ok_n, stats["lines"], stats["last_time"], g["count"], g["total_s"], g["span_s"]))
    return 0


def cmd_merge(args):
    files = snapshot_files(args.snap_dir)
    parsed = []
    for p in files:
        with open(p, "rb") as fh:
            parsed.append(parse_snapshot(fh.read()))
    entries = merge_parsed(parsed)
    write_log(entries, args.out)
    report = {"snapshots": len(files)}
    report.update(kernel_metrics(entries))
    report["gaps"] = gap_report(entries, args.gap_threshold)
    if args.stats:
        with open(args.stats, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False))
    return 0


# ---------------------------------------------------------------------------
# region derivation (bootloader log, kernel command line)
# ---------------------------------------------------------------------------

HEXNUM = r"(0x[0-9a-fA-F]+|\d+)"
# No word boundary: init lines name it as a prefix of a field ("pstore_addr:"), and a
# table row names it as a value ("name:pstore").
RING_NAME = re.compile(r"pstore|ramoops", re.I)
# A table row or init line that NAMES the ring and carries a base and a size.
_ADDR = re.compile(r"(?:start|addr(?:ess)?|base)\w*\s*[:=]\s*" + HEXNUM, re.I)
_SIZE = re.compile(r"(?<![A-Za-z])(?:[A-Za-z]+_)?size\s*[:=]\s*" + HEXNUM, re.I)
_CONSOLE = re.compile(r"console_size\s*[:=]\s*" + HEXNUM, re.I)
_CMDLINE = {
    "base": re.compile(r"(?<![\w.])ramoops\.mem_address=(\S+)"),
    "size": re.compile(r"(?<![\w.])ramoops\.mem_size=(\S+)"),
    "console": re.compile(r"(?<![\w.])ramoops\.console_size=(\S+)"),
}


def _candidate(source, base, size, console, evidence):
    return {"source": source, "base": base, "size": size, "console": console,
            "evidence": evidence}


def derive_from_bootloader_log(text):
    """Candidates from lines of a bootloader UART log that name a pstore/ramoops ring.

    Two shapes are read: a reserved-memory table row ("... start: <a>, size: <n> ...
    name:pstore") and an init line ("pstore_addr:<a>, pstore_size:<n>,
    pstore_console_size:<n>"). The labels are matched loosely; the NUMBERS are only
    ever taken from the line, never from here.
    """
    out = []
    for raw in text.splitlines():
        # Our own host diagnostics may name a range (a machine reporting what it mapped);
        # that is the machine speaking, not the bootloader, and would produce a false or
        # conflicting candidate. Defence in depth: the pipeline filters them first too.
        if HOST_LINE.match(raw.strip().encode("utf-8", "replace")):
            continue
        line = re.sub(r"^\d+(?:\.\d+)?\s+", "", raw.strip())     # optional epoch stamp
        if not RING_NAME.search(line):
            continue
        a, s = _ADDR.search(line), _SIZE.search(line)
        if not (a and s):
            continue
        c = _CONSOLE.search(line)
        try:
            out.append(_candidate("lk_log", memparse(a.group(1)), memparse(s.group(1)),
                                  memparse(c.group(1)) if c else None, line[:300]))
        except ValueError:
            continue
    return out


def derive_from_cmdline(text):
    """Candidate from kernel command-line text: ramoops.mem_address / mem_size / console_size."""
    got = {}
    for key, rx in _CMDLINE.items():
        m = rx.search(text)
        if m:
            try:
                got[key] = memparse(m.group(1))
            except ValueError:
                pass
    if "base" not in got or "size" not in got:
        return []
    ev = " ".join(m.group(0) for m in (rx.search(text) for rx in _CMDLINE.values()) if m)
    return [_candidate("cmdline", got["base"], got["size"], got.get("console"), ev)]


def pick_region(candidates):
    """(plan_dict_or_None, reason). Agreeing candidates merge; conflicting ones do not."""
    if not candidates:
        return None, "pstore/ramoops 영역을 말하는 줄이 없음"
    regions = {(c["base"], c["size"]) for c in candidates}
    if len(regions) > 1:
        lines = "; ".join("%#x+%#x (%s)" % (c["base"], c["size"], c["source"])
                          for c in candidates)
        return None, "출처마다 영역이 다름 — 추측하지 않음: " + lines
    base, size = next(iter(regions))
    order = {"cmdline": 0, "lk_log": 1, "dtb": 2}
    cands = sorted(candidates, key=lambda c: order.get(c["source"], 9))
    console = next((c["console"] for c in cands if c["console"]), None)
    evidence = " | ".join(dict.fromkeys(c["evidence"] for c in cands))
    return {
        "channel": "memdump",
        "region_base": "%#x" % base,
        "region_size": size,
        "console_size": console if console else 0,
        "source": cands[0]["source"],
        "evidence": evidence,
    }, ""


def cmd_derive(args):
    cands = []
    for path in args.bootloader_log or []:
        with open(path, encoding="utf-8", errors="replace") as fh:
            cands += derive_from_bootloader_log(fh.read())
    cmdline = args.cmdline or ""
    if args.cmdline_file:
        with open(args.cmdline_file, encoding="utf-8", errors="replace") as fh:
            cmdline += " " + fh.read()
    if cmdline.strip():
        cands += derive_from_cmdline(cmdline)
    plan, why = pick_region(cands)
    if not plan:
        log("memdump: 영역을 도출하지 못했습니다 — " + why)
        return 1
    if plan["console_size"] == 0:
        log("memdump: console_size 를 도출하지 못했습니다 — 링 용량을 영역 전체로 가정합니다 (간격이 길어짐)")
    text = json.dumps(plan, ensure_ascii=False, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    print(text)
    return 0


def cmd_check_plan(args):
    plan, why = read_plan(args.plan)
    if not plan:
        log("memdump: " + why)
        return 1
    return 0


def cmd_region(args):
    """The plan's region as the machine's guard wants it: <base>:<size>, 0x-prefixed hex.

    The same plan the observer reads, so the range the machine refuses to write is the
    range the host reads. A range the machine's 64-bit parser would refuse is refused here
    first (the machine stops on a malformed value, and a stop there is a round lost).
    """
    plan, why = read_plan(args.plan)
    if not plan:
        log("memdump: " + why)
        return 1
    if plan["base"] + plan["size"] >= 1 << 64:
        log("memdump: 영역이 64비트 주소 공간을 넘습니다")
        return 1
    print("0x%x:0x%x" % (plan["base"], plan["size"]))
    return 0


def read_task_regex_file(path):
    """(text, why): the first non-empty line, as written (only the line end is removed)."""
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as fh:
            body = fh.read()
    except OSError as exc:
        return None, "%s 를 읽지 못함: %s" % (path, exc)
    for line in body.split("\n"):
        line = line.rstrip("\r")
        if line.strip():
            return line, ""
    return None, "%s 에 정규식이 없음 (비어 있음)" % path


def cmd_task_regex(args):
    if args.file is not None:
        text, why = read_task_regex_file(args.file)
        if text is None:
            log("memdump: " + why)
            return 1
    else:
        text = args.value or ""
        if not text.strip():
            log("memdump: 정규식이 비어 있음")
            return 1
    rx, why, problems = judge_task_regex(text)
    if rx is None:
        log("memdump: " + why)
        return 1
    sys.stdout.write(text)
    if problems:
        # Compiles, but too loose to name a kernel task: still printed (a caller that
        # hands it on lets the scan report the refusal), and the exit code says "refused".
        log("memdump: 태스크 형식 %s 은 판정에 쓰지 않습니다 — %s" % (text, "; ".join(problems)))
        return 3
    return 0


# ---------------------------------------------------------------------------
# milestone tokens on the memdump channel
# ---------------------------------------------------------------------------

def read_tokens(path):
    """[(milestone, token, channel)] from milestone_tokens.txt (C2: channel optional)."""
    rows = []
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return rows
    with fh:
        for raw in fh:
            line = raw.rstrip("\n").rstrip("\r")
            if not line or "\t" not in line:
                continue
            parts = line.split("\t")
            ms, tok = parts[0], parts[1]
            ch = parts[2].strip() if len(parts) > 2 else ""
            rows.append((ms, tok, ch or "uart"))
    return rows


def _match_text(token, text):
    """The matched substring, or None. A token with a backslash is a regular expression."""
    if "\\" in token:
        try:
            m = re.search(token, text)
            return m.group(0) if m else None
        except re.error:
            pass
    return token if token in text else None


def task_shape_report(entries):
    """How the task-line shape that judged this ring behaved on it.

    The default shape is the one confirmed on a measured kernel and needs no more than its
    name. A shape the analyst chose for this target decides what counts as "the kernel printed
    this", so the report carries what a reviewer needs to check it: which pattern, how many
    ring lines it recognised against how many the default shape does, whether it left any line
    unrecognised at all (`discriminates`: a ring that mixes the bootloader's lines with the
    kernel's has lines with no task, so a shape that matches every line has not been shown to
    tell them apart - it may be right on a ring that holds only kernel lines, or loose), and a
    few of the lines only it recognised.
    """
    shape = {"pattern": TASK_REGEX_TEXT, "custom": TASK_REGEX_CUSTOM,
             "rejected": TASK_REGEX_REJECTED}
    if not TASK_REGEX_CUSTOM:
        return shape
    total = len(entries)
    seen = [(text, task_of(text)) for _, text in entries]
    own = [text for text, task in seen if task]
    default_rx = re.compile(DEFAULT_TASK_REGEX)
    only_custom = [text for text in own if not default_rx.search(text[:TASK_WINDOW])]
    shape.update({
        "total_lines": total,
        "task_lines": len(own),
        "default_task_lines": len(own) - len(only_custom),
        "discriminates": 0 < len(own) < total,
        "only_custom_examples": [text[:120] for text in only_custom[:3]],
    })
    return shape


def shape_note(shape):
    """The sentence kernel_alive's evidence carries when a custom shape decided it."""
    if shape.get("rejected"):
        return "지정한 태스크 형식 %s 은 너무 느슨해 쓰지 않음 — 기본 [pid:comm] 형식으로 판정" % \
               shape["rejected"]["pattern"]
    if not shape.get("custom"):
        return ""
    note = "커스텀 태스크 형식 %s 로 판정 (기본 [pid:comm] 형식 아님)" % shape["pattern"]
    if not shape.get("discriminates"):
        note += " — 링의 모든 줄에 맞아 부트로더 줄과 커널 줄을 가르는지 확인되지 않음 (형식 미검증)"
    return note


def scan_memdump(tokens, entries, src_texts=()):
    """Judge every memdump-channel token against the merged kernel log.

    `kernel_alive` is held to a stricter bar than a regex hit: the line must carry a
    kernel time (every log entry does) AND the task it was printed from, and the log
    must hold more than one such line. A token that merely appears in a string table
    or a stray line is not a running kernel.
    """
    shape = task_shape_report(entries)
    result = {"tokens": sum(1 for _, _, ch in tokens if ch == "memdump"),
              "reached": [], "injected": False, "injected_token": "",
              "hits": {}, "alive_evidence": None, "banner_seen": False,
              "task_lines": sum(1 for _, x in entries if task_of(x)),
              # which task-line shape judged the entries: a non-default one was chosen for
              # this target (kernel_task_regex.txt) and one that was refused (too loose)
              # fell back to the default; the report says both, and how the shape behaved
              "task_regex": shape}
    for t, text in entries:
        if BANNER in text and task_of(text):
            result["banner_seen"] = True
            break
    alive = []
    for ms, tok, ch in tokens:
        if ch != "memdump":
            continue
        hit = None
        for t, text in entries:
            matched = _match_text(tok, text)
            if matched is None:
                continue
            task = task_of(text)
            if ms == "kernel_alive" and not task:
                continue                      # a timestamp alone is not a running kernel
            hit = {"milestone": ms, "token": tok, "kernel_time": t, "task": task,
                   "text": text[:300], "matched": matched}
            break
        if not hit:
            continue
        if ms == "kernel_alive":
            if result["task_lines"] < ALIVE_MIN_LINES:
                hit["rejected"] = "커널 태스크 줄이 %d 개뿐 (최소 %d)" % (
                    result["task_lines"], ALIVE_MIN_LINES)
                result["hits"].setdefault("kernel_alive_rejected", []).append(hit)
                continue
            alive.append(hit)
        # Provenance: if the matched text is in the machine source, WE wrote it.
        if any(hit["matched"] in src for src in src_texts) or any(tok in src for src in src_texts):
            result["injected"] = True
            result["injected_token"] = (result["injected_token"] + ", " if
                                        result["injected_token"] else "") + tok
        if ms not in result["reached"]:
            result["reached"].append(ms)
        result["hits"].setdefault(ms, hit)
    if alive:
        best = next((h for h in alive if BANNER in h["text"]), alive[0])
        via_banner = result["banner_seen"] and BANNER in best["text"]
        notes = [] if via_banner else [
            "배너(%s) 미관측 — 대체 토큰으로 판정 (링이 한 바퀴 돌았을 수 있음)" % BANNER]
        if shape_note(shape):
            notes.append(shape_note(shape))
        result["alive_evidence"] = {
            "channel": "memdump",
            "token": best["token"],
            "kernel_time": best["kernel_time"],
            "task": best["task"],
            "line": best["text"],
            "banner": result["banner_seen"],
            "via": "banner" if via_banner else "alternate",
            # which task-line shape decided it: the one fact a custom shape must not hide
            "task_shape": {k: shape.get(k) for k in
                           ("pattern", "custom", "rejected", "discriminates", "task_lines", "total_lines")
                           if k in shape},
            "note": " · ".join(notes),
        }
    return result


def cmd_scan(args):
    entries = read_log(args.log)
    srcs = []
    if args.src_dir:
        for p in sorted(glob.glob(os.path.join(args.src_dir, "*.c"))):
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    srcs.append(fh.read())
            except OSError:
                continue
    result = scan_memdump(read_tokens(args.tokens), entries, srcs)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def cmd_metrics(args):
    print(json.dumps(kernel_metrics(read_log(args.log)), ensure_ascii=False))
    return 0


# ---------------------------------------------------------------------------
# guest reset signal
# ---------------------------------------------------------------------------

def reset_patterns(plan_path=None, env=None):
    """Patterns for host lines that mean 'the guest touched its reset/watchdog block'.

    They are data, not code: the same instruction on another SoC reads another block.
    Sources are the plan and the environment; there is no built-in list.
    """
    env = os.environ if env is None else env
    pats = []
    plan = load_plan(plan_path) if plan_path else None
    if plan:
        pats += plan["reset_patterns"]
    raw = (env.get(RESET_PATTERNS_ENV) or "").strip()
    if raw:
        try:
            val = json.loads(raw)
            pats += [str(p) for p in val] if isinstance(val, list) else [raw]
        except ValueError:
            pats += [p for p in raw.splitlines() if p.strip()]
    return list(dict.fromkeys(p for p in pats if p))


def reset_window(plan_path=None, env=None):
    env = os.environ if env is None else env
    try:
        if env.get(RESET_WINDOW_ENV):
            return float(env[RESET_WINDOW_ENV])
    except ValueError:
        pass
    plan = load_plan(plan_path) if plan_path else None
    if plan and plan["reset_window_s"] is not None:
        return plan["reset_window_s"]
    return DEFAULT_RESET_WINDOW_S


def _pattern_hits(pattern, text):
    try:
        return re.search(pattern, text) is not None
    except re.error:
        return pattern in text


def guest_reset(host_lines, kernel_entry_epoch, patterns, window_s):
    """Did a reset/watchdog host line appear within `window_s` of kernel_entry?

    host_lines are (epoch, text). A line with no epoch cannot be placed in time and is
    never counted: "within N seconds" is a claim about timing, and a line we cannot
    time would turn it into "at some point".
    """
    out = {"signal": False, "patterns": len(patterns), "window_s": window_s,
           "kernel_entry_epoch": kernel_entry_epoch, "pattern": "", "line": "",
           "delta_s": None, "basis": ""}
    if not patterns:
        out["basis"] = "패턴이 설정되지 않음"
        return out
    if kernel_entry_epoch is None:
        out["basis"] = "kernel_entry 시각을 관측하지 못함 — 판정 불가"
        return out
    for epoch, text in host_lines:
        if epoch is None:
            continue
        delta = epoch - kernel_entry_epoch
        if delta < 0 or delta > window_s:
            continue
        for pat in patterns:
            if _pattern_hits(pat, text):
                out.update(signal=True, pattern=pat, line=text[:300],
                           delta_s=round(delta, 3),
                           basis="kernel_entry 후 %.2f s 에 호스트 줄 일치" % delta)
                return out
    out["basis"] = "창 안에 일치하는 호스트 줄 없음"
    return out


def read_host_log(path):
    """[(epoch|None, text)] from a host log; '<epoch> <line>' or a bare line."""
    out = []
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with fh:
        for raw in fh:
            line = raw.rstrip("\n")
            m = re.match(r"^(\d+(?:\.\d+)?)\s+(.*)$", line)
            if m and "qemu-system" in m.group(2)[:40]:
                out.append((float(m.group(1)), m.group(2)))
            else:
                out.append((None, line))
    return out


def cmd_reset_signal(args):
    pats = reset_patterns(args.plan)
    window = args.window if args.window is not None else reset_window(args.plan)
    epoch = None
    if args.summary:
        try:
            with open(args.summary, encoding="utf-8") as fh:
                mark = (json.load(fh).get("marks") or {}).get(args.mark) or {}
            epoch = mark.get("epoch")
        except (OSError, ValueError):
            pass
    res = guest_reset(read_host_log(args.host_log), epoch, pats, window)
    print(json.dumps(res, ensure_ascii=False))
    return 0


# ---------------------------------------------------------------------------
# host / guest split
# ---------------------------------------------------------------------------

def split_host_lines(console_path, host_path):
    """Move QEMU host diagnostic lines out of the console file. Returns how many moved.

    The console is the guest's voice. A host line in it is OUR output - the machine
    explaining itself - and a console that carries it lets an explanation string
    match machine source literals, which is how the source-negative gate raised 65
    false alarms. Guest lines keep their exact bytes; the file is rewritten only when
    something was moved.
    """
    try:
        with open(console_path, "rb") as fh:
            data = fh.read()
    except OSError:
        return 0
    guest, host = [], []
    for line in data.splitlines(keepends=True):
        (host if HOST_LINE.match(line) else guest).append(line)
    if host:
        with open(host_path, "ab") as fh:
            for line in host:
                fh.write(line if line.endswith(b"\n") else line + b"\n")
        with open(console_path, "wb") as fh:
            fh.write(b"".join(guest))
    return len(host)


def cmd_split_host(args):
    print(split_host_lines(args.console, args.host))
    return 0


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("watch", help="dump the region through the monitor, then merge")
    w.add_argument("--plan", required=True)
    w.add_argument("--socket", required=True, help="QEMU monitor unix socket")
    w.add_argument("--snap-dir", required=True, help="where the raw snapshots are kept")
    w.add_argument("--out", required=True, help="merged kernel log")
    w.add_argument("--stats", default=None)
    w.add_argument("--console", default=None, help="console file to follow for --start-token")
    w.add_argument("--start-token", default=None,
                   help="begin dumping once the console shows this (the jump to the kernel)")
    w.add_argument("--deadline", type=float, default=0.0,
                   help="seconds after start at which the run ends; a last dump is taken "
                        "--final-margin before it")
    w.add_argument("--final-margin", type=float, default=1.5)
    w.add_argument("--floor", type=float, default=2.0, help="shortest interval (s)")
    w.add_argument("--ceiling", type=float, default=12.0, help="longest interval (s)")
    w.add_argument("--initial", type=float, default=5.0, help="interval before any data is seen")
    w.add_argument("--safety", type=float, default=0.5,
                   help="fraction of the ring's fill time allowed between dumps")
    w.add_argument("--socket-wait", type=float, default=30.0)
    w.set_defaults(fn=cmd_watch)

    m = sub.add_parser("merge", help="snapshot directory -> merged kernel log")
    m.add_argument("--snap-dir", required=True)
    m.add_argument("--out", required=True)
    m.add_argument("--stats", default=None)
    m.add_argument("--gap-threshold", type=float, default=GAP_THRESHOLD_S)
    m.set_defaults(fn=cmd_merge)

    d = sub.add_parser("derive", help="region from a bootloader log / kernel command line")
    d.add_argument("--bootloader-log", action="append")
    d.add_argument("--cmdline", default=None)
    d.add_argument("--cmdline-file", default=None)
    d.add_argument("--out", default=None, help="write memdump_plan.json here")
    d.set_defaults(fn=cmd_derive)

    c = sub.add_parser("check-plan")
    c.add_argument("plan")
    c.set_defaults(fn=cmd_check_plan)

    r = sub.add_parser("region", help="the plan's region as <base>:<size> for the machine's guard")
    r.add_argument("plan")
    r.set_defaults(fn=cmd_region)

    t = sub.add_parser("task-regex", help="check the kernel-task line shape and print it")
    tg = t.add_mutually_exclusive_group(required=True)
    tg.add_argument("--file", default=None, help="its first non-empty line is the regex")
    tg.add_argument("--value", default=None, help="the regex itself")
    t.set_defaults(fn=cmd_task_regex)

    s = sub.add_parser("scan", help="memdump-channel tokens against the kernel log")
    s.add_argument("--tokens", required=True)
    s.add_argument("--log", required=True)
    s.add_argument("--src-dir", default=None)
    s.set_defaults(fn=cmd_scan)

    k = sub.add_parser("metrics")
    k.add_argument("--log", required=True)
    k.set_defaults(fn=cmd_metrics)

    r = sub.add_parser("reset-signal")
    r.add_argument("--host-log", required=True)
    r.add_argument("--summary", default=None, help="input_summary.json carrying the marks")
    r.add_argument("--mark", default="kernel_entry")
    r.add_argument("--plan", default=None)
    r.add_argument("--window", type=float, default=None)
    r.set_defaults(fn=cmd_reset_signal)

    h = sub.add_parser("split-host")
    h.add_argument("--console", required=True)
    h.add_argument("--host", required=True)
    h.set_defaults(fn=cmd_split_host)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
