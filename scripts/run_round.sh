#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# run_round.sh - execute one round and emit a SINGLE observation document.
#
# Why this exists:
#   The pipeline used to hand the agent two separate outputs - the run script's
#   key=value lines and the stop_conditions JSON - and ask it to merge them.
#   Transcribing `stop` wrongly there would weaken the stop backstop, which is
#   the one thing an LLM must not be able to soften. So the merge happens here,
#   deterministically, and the agent only relays one document it did not build.
#
# Usage:
#   run_round.sh <workdir> <machine> <run_n> <goal> <ladder> [container] [cmd] [surface]
#
# Output:
#   <workdir>/observation.json   (also printed to stdout)
#
# The keys that point at this round's channel logs (workflows/pipeline.js RUN_SCHEMA and the
# agent prompts name them; every path is absolute and belongs to THIS round):
#   console          07_logs/console_<N>.txt   the guest's UART, guest lines only
#   kernel_log       07_logs/kernel_<N>.log    the kernel log the host read out of RAM, one
#                                              "<kernel_s> <text>" line per entry (GUEST
#                                              evidence). A path only when memdump_plan.json was
#                                              valid and the observer produced the file; null
#                                              otherwise - null means "no such channel this
#                                              round", never "the kernel said nothing".
#   host_log         07_logs/host_<N>.txt      QEMU's and the machine's own lines ("qemu-system-*:
#                                              ...": ACCESSED / UNMODELLED / POLL / ...), never
#                                              guest evidence. A path whenever the round produced
#                                              such a line (no plan needed) or a channel was on;
#                                              null when the machine said nothing.
#   channels         {uart_bytes, kernel_lines, host_lines}   the line counts behind the paths
#   task_regex       the task-line shape that judged the memory-dump channel ({pattern, custom,
#                    rejected, ...}); null when no memory-dump scan ran. A custom shape that
#                    decided kernel_alive is also named in kernel_alive_evidence.task_shape.
#
# Steps: journal try-start -> change snapshot -> run -> stop conditions -> merge.

set -u

WD="${1:?workdir required}"
MACHINE="${2:?machine required}"
RUN_N="${3:?run number required}"
GOAL="${4:-}"
LADDER="${5:-}"
CONTAINER="${6:-}"      # bootloader container, loaded whole
CMD="${7:-help}"
SURFACE="${8:-shell}"   # the bootloader's interactive surface

HERE="$(cd "$(dirname "$0")" && pwd)"

bash "$HERE/journal.sh" "$WD" try-start "$RUN_N" "목표 $GOAL" >/dev/null 2>&1 || true
# The round number keeps the snapshot: a change proved wrong three rounds later
# can then actually be taken back out (revert_change.sh).
bash "$HERE/check_change.sh" "$WD" snapshot "$RUN_N" >/dev/null 2>&1 || true

# One chain, one run script. The bootloader loads what comes after it, so there
# is nothing to branch on here any more.
RUN_RC=0
bash "$HERE/run_full.sh" "$WD" "$MACHINE" "$CONTAINER" "$CMD" "$RUN_N" "$SURFACE" "$LADDER" >/dev/null || RUN_RC=$?

STOP_TMP="$(mktemp)"
python3 "$HERE/stop_conditions.py" "$WD" --ladder "$LADDER" > "$STOP_TMP" 2>/dev/null || echo '{}' > "$STOP_TMP"

python3 - "$WD" "$GOAL" "$STOP_TMP" "$RUN_N" "$RUN_RC" <<'PY'
import json, os, sys

wd, goal, stop_path, run_n, run_rc = sys.argv[1:6]

def load(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default

def path_or_none(value):
    """A log path the fingerprint named, only while the file is there: a path to a file
    that does not exist would send the reader to nothing and read as "the channel was silent"."""
    return value if isinstance(value, str) and value and os.path.isfile(value) else None

fp = load(os.path.join(wd, "fingerprint.json"), {})
stop = load(stop_path, {})

gate = fp.get("source_gate") or {}
origin = fp.get("origin") or {}
inp = fp.get("input") or {}
chan = fp.get("channels") or {}
kern = fp.get("kernel") or {}

# What kernel_alive rests on. A memory-dump hit carries its own evidence (kernel time,
# the task that printed it, whether the banner was seen). A UART-only rung is the
# older string match and says so: nothing about it was held to a kernel timestamp.
alive_evidence = kern.get("alive_evidence")
if alive_evidence is None and "kernel_alive" in (fp.get("milestones_reached") or []):
    alive_evidence = {"channel": "uart",
                      "note": "UART 콘솔 토큰 일치 — 커널 시각·태스크 접두는 검증하지 않음"}
observation = {
    "round": int(run_n),
    "goal": goal,
    "run_exit_code": int(run_rc),
    # A run that produced no fingerprint, or one the run script judged failed,
    # is not a round about the firmware. Reporting it as ok let eight rounds of
    # a QEMU that never started read as a stall and then as EXHAUSTED.
    "run_ok": bool(fp) and not fp.get("run_failed", False),
    "run_error": fp.get("run_error", ""),
    # QEMU died AFTER the guest had produced output. That is a machine-source
    # defect, not a harness problem, and the assert names the file and function -
    # so it carries an owner and a location, unlike run_failed.
    "run_fault": bool(fp.get("run_fault", False)),
    "run_fault_line": fp.get("run_fault_line", ""),

    # raw observation from the run script
    "milestone": fp.get("milestone", "none"),
    # every rung cleared, so a ladder that skips rungs still advances correctly
    "milestones_reached": fp.get("milestones_reached", []),
    "injected": bool(gate.get("injected", False)),
    "injected_token": gate.get("token", ""),
    "exceptions": fp.get("exceptions", 0),
    "console_bytes": fp.get("console_bytes", 0),
    # Distinct console lines: depth of boot, which console bytes cannot show
    # because a retry loop prints the same line hundreds of thousands of times.
    "console_uniq": fp.get("console_uniq", 0),
    # The ORIGINATING exception - the stop point that actually needs a fix.
    # far/elr below are the last ones in the trace and under a nested abort they
    # are only where the recursion ran out of time.
    "origin_type": origin.get("type", "none"),
    "origin_esr": origin.get("esr", "none"),
    "origin_far": origin.get("far", "none"),
    "origin_elr": origin.get("elr", "none"),
    "origin_block": origin.get("block", ""),
    "far": fp.get("far", "none"),
    "elr": fp.get("elr", "none"),
    # What the input path did. Without these a round cannot separate "the gate
    # was never offered our bytes" from "the gate read them and the firmware
    # booted on", and the first one is not an observation about the firmware.
    "input_offered": bool(inp.get("offered", False)),
    "prompt_seen": bool(inp.get("prompt_seen", False)),
    "command_sent": bool(inp.get("command_sent", False)),
    "input_starved": bool(inp.get("starved", False)),
    "rx_reported": bool(inp.get("rx_reported", False)),
    "rx_served": inp.get("rx_served"),
    "rx_polls": inp.get("rx_polls"),
    # The firmware sat parked on its console input: nothing new on the console in the
    # final stretch while the machine's RX poll counter kept growing. null = the machine
    # does not report RX polls, which is not the same as "not waiting".
    "waiting_for_input": inp.get("waiting_for_input"),
    "input_summary": inp.get("summary", ""),
    "input_log": inp.get("log", ""),
    # Could this run read the boot medium's partition table? "unknown" means the
    # boot never got that far, which is not the same as "missing" and must not
    # block anything.
    "storage_partition_table": (fp.get("storage") or {}).get("partition_table", "unknown"),
    "storage_token": (fp.get("storage") or {}).get("token", ""),
    # True when a longer run produced more console: the wall is our time budget,
    # not the firmware. null means the probe did not run, which is NOT the same
    # as false - reporting an unmeasured value as measured is what let a stalled
    # run look like a firmware wall for five rounds.
    "timeout_bound": fp.get("timeout_bound"),
    "probe_console_bytes": fp.get("probe_console_bytes", -1),
    "console": fp.get("console", ""),
    "summary": fp.get("summary", ""),
    "trace": fp.get("trace", ""),

    # Observation channels. The UART is not the only voice a guest has: with a memory
    # dump the kernel log arrives on its own channel, and QEMU's own diagnostics are
    # kept apart from both. A channel that is off reads 0, not "unknown".
    "channels": {
        "uart_bytes": chan.get("uart_bytes", fp.get("console_bytes", 0)),
        "kernel_lines": chan.get("kernel_lines", 0),
        "host_lines": chan.get("host_lines", 0),
    },
    # null: no evidence. An object: which line, from which channel, at which kernel time, and
    # (memory dump) `task_shape`: the task-line shape that decided it - a custom one chosen for
    # this target is named there and in `note`.
    "kernel_alive_evidence": alive_evidence,
    # The task-line shape that judged the memory-dump channel this round, whether or not it
    # credited kernel_alive: {pattern, custom, rejected} and, for a custom shape, how it behaved
    # on this ring (total_lines, task_lines, default_task_lines, discriminates,
    # only_custom_examples). `rejected` = {pattern, problems} when the shape written for this
    # target was too loose to use and the default judged instead. null = no memory-dump scan.
    "task_regex": kern.get("task_regex"),
    # Where this round's kernel and host logs are (null = the file does not exist).
    "kernel_log": path_or_none(fp.get("kernel_log")),
    "host_log": path_or_none(fp.get("host_log")),
    # The guest touched its reset/watchdog block right after the jump (host-line
    # patterns, see memdump_observe.py reset-signal). False also when nothing was configured.
    "guest_reset_signal": bool(fp.get("guest_reset_signal", False)),
    "guest_reset": fp.get("guest_reset"),
    # Depth of the kernel channel; null when the channel is off or the log is empty.
    "kernel_last_time": kern.get("last_time"),
    "kernel_uniq": kern.get("uniq"),
    "kernel": kern or None,
    # The run was cut short by the exception threshold (MAX_EXCEPTIONS), not by its timeout.
    "early_exit": fp.get("early_exit"),

    # deterministic stop conditions - copied verbatim, never re-derived
    "stop": bool(stop.get("stop", False)),
    "stop_reason": stop.get("stop_reason"),
    "stall_count": stop.get("stall_count", 0),
    "oscillating": bool(stop.get("oscillating", False)),
    "moves_exhausted": bool(stop.get("moves_exhausted", False)),
    "escalate_to_analyst": bool(stop.get("escalate_to_analyst", False)),
    "suspect_prior_bypass": bool(stop.get("suspect_prior_bypass", False)),
    "best_milestone": stop.get("best_milestone"),
    "best_progress": stop.get("best_progress", {}),
    # The kernel log went deeper than it ever had: the boot is moving even when the
    # UART fingerprint is constant, so this is not a stall.
    "kernel_moving": bool(stop.get("kernel_moving", False)),
    "tried_changes": stop.get("tried_changes", []),
    # changes applied that moved nothing - the signal that the diagnosis is at
    # the wrong layer, which is the supervisor's judgement to make
    "futile_changes": stop.get("futile_changes", 0),
    "needs_layer_review": bool(stop.get("needs_layer_review", False)),
    "blockers": stop.get("blockers", []),
}

# A run that produced no fingerprint must not look like a clean round.
if not fp:
    observation["note"] = ("fingerprint.json 이 생성되지 않았습니다 — "
                           "QEMU 실행 자체가 실패했습니다")
elif fp.get("run_failed"):
    observation["note"] = ("실행이 실패했습니다 — " + str(fp.get("run_error", "")) +
                           " · 이것은 펌웨어 정지점이 아니라 하네스/환경 문제입니다")
elif fp.get("run_fault"):
    observation["note"] = ("QEMU 가 비정상 종료했으나 게스트가 이미 출력을 냈습니다 — "
                           "환경이 아니라 머신 소스 결함입니다 (qemu_abort). "
                           + str(fp.get("run_fault_line", "")))

out = os.path.join(wd, "observation.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump(observation, fh, ensure_ascii=False, indent=2)
print(json.dumps(observation, ensure_ascii=False, indent=2))
PY

rm -f "$STOP_TMP"
