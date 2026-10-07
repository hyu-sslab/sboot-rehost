#!/usr/bin/env python3
"""uart_harness.py - drive the guest's UART from OUTSIDE the machine.

Why this exists
---------------
A bootloader's autoboot gate is one-shot: it polls the console for a specific
input pattern - typically several carriage returns in a row - and if it does not
see it, it stops listening and boots on. Reaching the surface therefore depends
on input arriving WHILE the gate is polling, and on it being the pattern the gate
checks for. Input comes from here, a process outside QEMU, because a machine that
seeds its own RX buffer types its own commands and a surface reached that way is
verifying itself (honesty rule 7).

Three states, and no fourth
---------------------------
The previous version ran one loop that mixed supplying the pattern, watching for
the prompt and sending the command, and tied all three to one wall-clock fraction
of the budget (65%). Past that point it fired the command blind and stopped
offering the pattern entirely. The S921N logs show what that costs: run 7, 8 and 9
ALL ended with "command (prompt not observed)" - including the two runs that did
reach the shell. The designed branch (see the prompt -> send the command) never
executed once, and the last 35% of every round had nothing to give a gate that
opened late.

So the work is split into states with no give-up:

  SUPPLY    keep the pattern in front of the gate. Runs until the prompt appears
            or the budget ends - never until a guessed fraction of it.
  DISPATCH  prompt seen: stop supplying, send the command exactly once.
  COLLECT   read console only.

If the prompt never appears the command is NOT sent and the summary says so. A
run that could not reach the surface has to look like one.

Knowing when to refill
----------------------
The machine can report RX consumption on stderr (see machine_full.c.tmpl,
REHOST_RX_REPORT). When those lines are present the harness refills only once the
buffer has actually drained, so the gate gets its run of bytes without burying
the later command under a hundred empty command lines. When they are absent -
an older machine, or one built before the counters existed - it falls back to
"the console went quiet, so the firmware is probably blocked on a poll".

Observation side channels (all optional; without them nothing here changes):
  --host-log FILE    copy QEMU's own diagnostic lines ("qemu-system-*: ...") from stderr
                     into FILE with a wall-clock epoch in front. They are the host
                     speaking, never guest evidence - kept apart so they can be timed.
  --mark NAME=TOKEN  record the wall-clock at which TOKEN first appears on the console
                     (repeatable); lands in the summary as marks.NAME.epoch. This is how
                     "N seconds after kernel_entry" gets a clock without a second reader.
  --stop-file FILE   end the run as soon as FILE exists (trace_filter.py creates it when
                     the exception count passes its limit). A normal end, rc 124.

A bootloader with NO interactive surface (--surface none) gets no input at all: there is
no gate pattern derived for it, so offering one would be a guess, and "autoboot was
observed" must not rest on bytes we invented. The harness then only reads the console;
input_offered and input_starved are both false. Whether the firmware nevertheless sits
parked on its console input is reported as waiting_for_input (see below).

The same holds when the surface is a shell but nobody derived its gate: with no usable
input_plan.json (missing, unreadable, or an autoboot_interrupt without both `bytes` and
`count`) the harness sends NO interrupt pattern - there used to be a default of three
carriage returns, which was one bootloader's gate offered to every other, and a surface
reached by a guessed pattern says nothing about the firmware. The summary then reads
source: "absent" (plan_note says why) and bytes_sent counts only what we typed later: the
command, once the prompt really appeared. A surface that stays shut for want of a derived
gate looks like one - the fix is for static-analyzer to derive the gate (input_plan.json).

Usage:
  uart_harness.py --console <file> --input-log <file> [--plan <json>]
                  [--summary <json>] [--timeout N] [--cmd help]
                  [--prompt-token STR] [--surface shell|fastboot|none]
                  [--host-log FILE] [--mark NAME=TOKEN ...] [--stop-file FILE]
                  -- <qemu> <args...>

The QEMU command must NOT carry -serial: this attaches the guest console to the
process pipes instead.

Exit code: QEMU's, or 124 when the timeout expired (the normal end of a round).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time

DEFAULT_INTERVAL = 0.05     # polling step; small so the prompt is noticed quickly
MIN_RESEND = 0.3            # gap between two refills; polling is faster than typing
QUIET_RESEND = 0.4          # fallback: console silent this long -> firmware is waiting
MAX_REFILLS = 40            # bound on how much we may pour in; reported when hit
QUIET_WINDOW_S = 10.0       # waiting_for_input: the longest final stretch that is judged

# The machine's out-of-band consumption report (machine_full.c.tmpl rehost_rx_report).
# It goes to stderr, never to the console, so it cannot contaminate the guest
# output that verification reads. Single-letter fields: s served, e empty,
# p status polls, q still queued - short enough that no console token can
# collide with them in verify.py item 3.
RX_REPORT = re.compile(
    r"REHOST-RX\s+s=(\d+)\s+e=(\d+)\s+p=(\d+)\s+q=(\d+)")
# QEMU's own diagnostics ("qemu-system-aarch64: info: ..."). Anything the machine
# explains about itself arrives like this, on stderr, and none of it is guest output.
HOST_LINE = re.compile(r"^qemu-system-[\w-]+: ")
MARK_WINDOW = 4096          # console tail searched for a mark token on each newline


def load_plan(path):
    """The derived input plan, or an honest "none".

    The pattern is a property of the firmware - the gate counts a specific number
    of a specific byte, and some gates fail on a single empty poll - so
    static-analyzer derives it and writes it here. Hardcoding one vendor's gate
    would strand every other bootloader, and so would a "default" one: with no usable
    plan the pattern is EMPTY and `source` is "absent" (`note` says which way the plan
    was unusable). Nothing is offered on a guess.

    A plan is usable only with BOTH `bytes` and `count` (static-analyzer is told to write
    no file when it cannot derive either); a gate that names a count but no byte, or the
    reverse, is not completed from a default.

    `contiguous` and `empty_poll_budget` used to live only in the human-readable
    `evidence` prose. On S921N that prose said, correctly, "w21=0, so one empty
    poll fails it" - and nothing in the code could read it. Undeclared now means
    the strictest reading: a generous guess fails silently, a strict one costs a
    few extra carriage returns.
    """
    plan = {
        "byte": "",
        "count": 0,
        "contiguous": True,
        "empty_poll_budget": 0,
        "one_shot": True,
        "gate_addr": None,
        "source": "absent",
        "evidence": "",
        "note": "",
    }
    if not path or not os.path.exists(path):
        plan["note"] = "no input_plan.json"
        return plan
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        plan["note"] = "input_plan.json could not be read"
        return plan
    gate = data.get("autoboot_interrupt") if isinstance(data, dict) else None
    if not isinstance(gate, dict) or not gate:
        plan["note"] = "input_plan.json has no autoboot_interrupt"
        return plan
    raw = gate.get("bytes")
    count = gate.get("count")
    if not (isinstance(raw, str) and raw and isinstance(count, int)
            and not isinstance(count, bool) and count > 0):
        plan["note"] = "autoboot_interrupt needs both bytes and count"
        return plan
    try:
        plan["byte"] = raw.encode().decode("unicode_escape")
    except UnicodeError:
        plan["note"] = "autoboot_interrupt bytes could not be decoded"
        return plan
    plan["count"] = count
    if isinstance(gate.get("contiguous"), bool):
        plan["contiguous"] = gate["contiguous"]
    if isinstance(gate.get("empty_poll_budget"), int) and gate["empty_poll_budget"] >= 0:
        plan["empty_poll_budget"] = gate["empty_poll_budget"]
    if isinstance(gate.get("one_shot"), bool):
        plan["one_shot"] = gate["one_shot"]
    plan["gate_addr"] = gate.get("gate_addr")
    plan["evidence"] = gate.get("evidence", "")
    plan["source"] = "derived"
    return plan


class Guest:
    """QEMU plus the two things we learn from it: console text and RX reports."""

    def __init__(self, argv):
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        self.lock = threading.Lock()
        self.seen = bytearray()          # console tail, for prompt matching
        self.console_len = 0             # total, not just the retained tail
        # None until the machine reports; that distinction matters, because
        # "the machine never told us" and "the firmware never read" are
        # different facts and only one of them is about the firmware.
        self.rx_served = None
        self.rx_empty = None
        self.rx_polls = None
        self.rx_pending = None
        self.rx_reports = 0
        self.poll_samples = []           # (wall clock, polls) for every report
        # Optional observation side channels, set by main() before the readers start.
        self.t0 = time.time()
        self.host_log = None             # open file or None
        self.host_lines = 0
        self.marks = {}                  # name -> {"token": bytes, "epoch": float|None}

    def check_marks(self):
        """Stamp the first time each mark token shows on the console (lock held)."""
        for spec in self.marks.values():
            if spec["epoch"] is None:
                at = self.seen.find(spec["token"],
                                    max(0, len(self.seen) - MARK_WINDOW - len(spec["token"])))
                if at >= 0:
                    spec["epoch"] = time.time()

    def start_readers(self, console_file):
        threading.Thread(target=self._pump_stdout, args=(console_file,),
                         daemon=True).start()
        threading.Thread(target=self._pump_stderr, daemon=True).start()

    def _pump_stdout(self, console_file):
        while True:
            chunk = self.proc.stdout.read(1)
            if not chunk:
                return
            console_file.write(chunk)
            with self.lock:
                self.seen.extend(chunk)
                self.console_len += 1
                if len(self.seen) > 65536:      # only the tail is ever matched
                    del self.seen[:32768]
                if chunk == b"\n" and self.marks:
                    self.check_marks()

    def _pump_stderr(self):
        """Parse the RX report, then pass every line through untouched.

        run_full.sh redirects this process's stderr into qemu_<n>.stderr.txt and
        the machine's diagnostics are read from there, so consuming the pipe
        without forwarding would delete them. QEMU's own startup errors are also
        how a run that never began gets diagnosed.
        """
        for raw in self.proc.stderr:
            text = raw.decode("utf-8", errors="replace")
            if self.host_log is not None and HOST_LINE.match(text):
                self.host_log.write(f"{time.time():.6f} {text.rstrip(chr(10))}\n")
                self.host_log.flush()
                self.host_lines += 1
            match = RX_REPORT.search(text)
            if match:
                with self.lock:
                    (self.rx_served, self.rx_empty,
                     self.rx_polls, self.rx_pending) = (int(g) for g in match.groups())
                    self.rx_reports += 1
                    self.poll_samples.append((time.time(), self.rx_polls))
            try:
                sys.stderr.buffer.write(raw)
                sys.stderr.buffer.flush()
            except (BrokenPipeError, ValueError):
                pass

    def snapshot(self):
        with self.lock:
            return {
                "console_len": self.console_len,
                "served": self.rx_served,
                "pending": self.rx_pending,
                "polls": self.rx_polls,
                "reports": self.rx_reports,
                "have_reports": self.rx_reports > 0,
            }

    def prompt_seen(self, token):
        if not token:
            return False
        with self.lock:
            return token.encode() in self.seen


def parked_on_input(samples, ended, quiet_since, started):
    """True/False/None: was the firmware found waiting on its console input?

    True needs BOTH of these in the final stretch of the run: the console said nothing
    new, and the machine's RX status-poll counter kept growing. A firmware that has
    nothing left to print and keeps asking "is there a byte for me?" is parked on its
    input; one that is silent because it died, or hung somewhere that does not poll,
    shows no growth. None when the machine reports nothing (an older machine, or one
    built without the counters) - "never told us" is not "not waiting".

    The machine reports sparsely (the first poll, then every ~1M polls), so growth is
    judged between reports: a report inside the window that exceeds the last count
    from before the window means that many polls happened in it."""
    elapsed = ended - started
    if not samples or elapsed < 1.0:
        return None
    window = min(QUIET_WINDOW_S, elapsed / 4.0)
    since = ended - window
    if quiet_since > since:
        return False                       # the console was still moving: not parked
    before = 0
    for t, polls in samples:
        if t <= since:
            before = polls
    grew = any(t > since and polls > before for t, polls in samples)
    return bool(grew)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--console", required=True)
    parser.add_argument("--input-log", required=True)
    parser.add_argument("--plan", default=None)
    parser.add_argument("--summary", default=None,
                        help="where to write the machine-readable run summary; "
                             "defaults to input_summary.json beside the input log")
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--cmd", default="help")
    parser.add_argument("--prompt-token", default=None,
                        help="console text meaning the surface is up; when seen, "
                             "the harness stops interrupting and sends the command")
    parser.add_argument("--surface", default="shell")
    parser.add_argument("--host-log", default=None,
                        help="copy QEMU's diagnostic lines here, each with a wall-clock epoch")
    parser.add_argument("--mark", action="append", default=[], metavar="NAME=TOKEN",
                        help="record when TOKEN first appears on the console")
    parser.add_argument("--stop-file", default=None,
                        help="end the run as soon as this file exists")
    parser.add_argument("qemu", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    qemu = [a for a in args.qemu if a != "--"]
    if not qemu:
        print("uart_harness: QEMU 명령이 필요합니다", file=sys.stderr)
        return 2

    plan = load_plan(args.plan)
    pattern = (plan["byte"] * plan["count"]).encode()          # empty without a derived gate
    summary_path = args.summary or os.path.join(
        os.path.dirname(os.path.abspath(args.input_log)), "input_summary.json")

    console = open(args.console, "wb", buffering=0)
    inlog = open(args.input_log, "w", encoding="utf-8")
    inlog.write("# 하니스가 보낸 입력 (머신이 만든 것이 아님)\n")
    if pattern:
        inlog.write(f"# 인터럽트 패턴: {plan['byte']!r} x{plan['count']} ({plan['source']}, "
                    f"contiguous={plan['contiguous']}, "
                    f"empty_poll_budget={plan['empty_poll_budget']})\n")
    else:
        inlog.write(f"# 인터럽트 패턴: 없음 ({plan['source']}: {plan['note']}) — 도출된 게이트가 "
                    "없으므로 인터럽트를 보내지 않습니다\n")
    inlog.flush()

    guest = Guest(qemu)
    if args.host_log:
        guest.host_log = open(args.host_log, "w", encoding="utf-8")
    for spec in args.mark:
        name, _, token = spec.partition("=")
        if name and token:
            guest.marks.setdefault(name, {"token": token.encode(), "epoch": None})
    guest.start_readers(console)

    sent_bytes = 0
    refills = 0
    # Bytes written since the last report we saw. The machine reports what is
    # queued at the moment it drains, so without this the harness would keep
    # reading a stale "queue is empty" and pour a refill in every cycle.
    sent_since_report = 0

    def send(data, note):
        nonlocal sent_bytes, sent_since_report
        try:
            # One write for the whole pattern: a gate with empty_poll_budget 0
            # fails if the run of bytes is broken by a single empty poll, so the
            # burst must not be split across writes.
            guest.proc.stdin.write(data)
            guest.proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            return False
        sent_bytes += len(data)
        sent_since_report += len(data)
        inlog.write(f"{time.time():.3f} {note}: {data!r}\n")
        inlog.flush()
        return True

    started = time.time()
    deadline = started + args.timeout
    state = "SUPPLY"
    prompt_at = None
    command_sent = False
    supply_capped = False
    last_send = 0.0
    last_console_len = 0
    last_console_change = started
    last_reports_seen = 0
    rc = None
    early_exit = None

    # No surface, no input: there is no derived gate to feed, and a pattern we made up
    # would turn "autoboot was observed" into "autoboot was observed after we typed".
    offer_input = args.surface != "none"
    if not offer_input:
        state = "COLLECT"
        inlog.write("# 표면 없음(--surface none) — 입력을 주지 않고 콘솔만 읽습니다\n")
        inlog.flush()
    # A shell surface with no derived gate: nothing to supply, but the prompt is still
    # watched for, and the command still goes out once it has really appeared.
    offer_pattern = offer_input and bool(pattern)
    if offer_input and not pattern:
        inlog.write("# 도출된 게이트 없음 — 인터럽트를 보내지 않고 프롬프트가 나타나기를 기다립니다 "
                    "(나타나면 명령만 한 번 보냅니다)\n")
        inlog.flush()
        print(f"uart_harness: 도출된 입력 게이트가 없어({plan['note']}) 인터럽트 패턴을 보내지 "
              "않습니다 — 표면이 닫혀 있으면 static-analyzer 가 input_plan.json 을 도출해야 합니다",
              file=sys.stderr)

    # Prime immediately: a gate that opens early is the case a first shot at t=0
    # is for, and the buffer holds the bytes until something reads them.
    if offer_pattern and send(pattern, "autoboot 중단 시도 (최초 공급)"):
        last_send = started
        refills = 1

    while time.time() < deadline:
        rc = guest.proc.poll()
        if rc is not None:
            break
        if args.stop_file and os.path.exists(args.stop_file):
            early_exit = "stop_file"
            break

        now = time.time()
        if guest.marks:
            with guest.lock:
                guest.check_marks()
        snap = guest.snapshot()
        if snap["console_len"] != last_console_len:
            last_console_len = snap["console_len"]
            last_console_change = now
        if snap["reports"] != last_reports_seen:
            last_reports_seen = snap["reports"]
            sent_since_report = 0

        if state == "SUPPLY":
            if guest.prompt_seen(args.prompt_token):
                prompt_at = now - started
                state = "DISPATCH"
                continue
            if not offer_pattern:
                pass                         # no derived gate: wait for the prompt, send nothing
            elif refills < MAX_REFILLS and now - last_send >= MIN_RESEND:
                if snap["have_reports"]:
                    # The machine tells us what is left. Top up when the gate
                    # could be starved, and stop pouring once it cannot be.
                    queued = (snap["pending"] or 0) + sent_since_report
                    due = queued < plan["count"]
                else:
                    # No report channel: a console that has stopped growing is
                    # the firmware sitting in a poll, which is when a refill can
                    # actually be taken.
                    due = now - last_console_change >= QUIET_RESEND
                if due and send(pattern, "autoboot 중단 시도"):
                    last_send = now
                    refills += 1
            elif refills >= MAX_REFILLS and not supply_capped:
                supply_capped = True
                inlog.write(f"# 공급 상한 {MAX_REFILLS} 회 도달 — 더 붓지 않고 "
                            f"프롬프트만 기다립니다\n")
                inlog.flush()

        elif state == "DISPATCH":
            if args.surface == "shell" and not command_sent:
                command_sent = send(args.cmd.encode() + b"\r", "명령 (프롬프트 관측 후)")
            state = "COLLECT"

        time.sleep(DEFAULT_INTERVAL)

    # The prompt can land in the last polling interval; check once more so a run
    # that did reach the surface is not reported as one that did not.
    if prompt_at is None and guest.prompt_seen(args.prompt_token):
        prompt_at = time.time() - started
    ended = time.time()

    if rc is None:
        guest.proc.terminate()
        try:
            guest.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            guest.proc.kill()
        rc = 124                      # the normal end of a round

    time.sleep(0.2)                   # let the reader threads drain the pipes
    with guest.lock:
        if guest.marks:
            guest.check_marks()
        if guest.console_len != last_console_len:
            last_console_change = time.time()
    console.close()
    if guest.host_log is not None:
        guest.host_log.close()

    snap = guest.snapshot()
    summary = {
        "pattern": plan["byte"],
        "count": plan["count"],
        "source": plan["source"],
        "contiguous": plan["contiguous"],
        "empty_poll_budget": plan["empty_poll_budget"],
        "gate_addr": plan["gate_addr"],
        "surface": args.surface,
        "prompt_token": args.prompt_token or "",
        "timeout_s": args.timeout,
        "elapsed_s": round(time.time() - started, 3),
        "bytes_sent": sent_bytes,
        "supply_attempts": refills,
        "supply_capped": supply_capped,
        "prompt_seen": prompt_at is not None,
        "prompt_seen_at_s": round(prompt_at, 3) if prompt_at is not None else None,
        "command_sent": command_sent,
        # The old harness fired the command without ever seeing the prompt and
        # called it a round. It is kept as an explicit field so a run can never
        # again claim the surface on the strength of a blind write.
        "command_blind": False,
        "rx_reported": snap["have_reports"],
        "rx_served": snap["served"],
        "rx_pending": snap["pending"],
        "rx_polls": snap["polls"],
        "exit_code": rc,
    }
    # The gate was looking and we had nothing to give it. That is a harness
    # failure, not a decision the firmware made, and the two must not be
    # recorded as the same observation.
    # Without a surface nothing was offered, so "the firmware never read what we gave
    # it" cannot be said - the only honest value is false.
    summary["input_starved"] = bool(
        offer_pattern and snap["have_reports"] and (snap["polls"] or 0) > 0
        and (snap["served"] or 0) == 0)
    summary["input_offered"] = sent_bytes > 0
    if plan["note"]:
        summary["plan_note"] = plan["note"]            # why there was no derived gate
    # Parked on the console input: silent, and still polling it (None = not reported).
    with guest.lock:
        poll_samples = list(guest.poll_samples)
    summary["waiting_for_input"] = parked_on_input(poll_samples, ended, last_console_change, started)
    # Side-channel fields appear only when asked for, so a run without them writes
    # the same summary it always did.
    if guest.marks:
        summary["marks"] = {
            name: {"token": spec["token"].decode("utf-8", "replace"),
                   "epoch": spec["epoch"],
                   "elapsed_s": (round(spec["epoch"] - started, 3)
                                 if spec["epoch"] is not None else None)}
            for name, spec in guest.marks.items()}
    if args.host_log:
        summary["host_lines"] = guest.host_lines
    if args.stop_file:
        summary["early_exit"] = early_exit

    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=2)

    inlog.write(f"# 종료 rc={rc}, 프롬프트 관측={summary['prompt_seen']}, "
                f"명령 전송={command_sent}, 공급 {refills}회/{sent_bytes}B")
    if snap["have_reports"]:
        inlog.write(f", 펌웨어가 읽은 바이트={snap['served']} "
                    f"(폴링 {snap['polls']}, 남은 {snap['pending']})")
    if early_exit:
        inlog.write(f", 조기 종료: {early_exit}")
    inlog.write("\n")
    inlog.close()

    if not summary["prompt_seen"]:
        print("uart_harness: 프롬프트를 관측하지 못해 명령을 보내지 않았습니다 "
              f"(표면 미도달, {summary_path})", file=sys.stderr)
    if summary["input_starved"]:
        print("uart_harness: ★ 펌웨어가 콘솔을 폴링했으나 우리 바이트를 한 번도 "
              "읽지 않았습니다 — 하니스 문제이지 펌웨어 판정이 아닙니다", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
