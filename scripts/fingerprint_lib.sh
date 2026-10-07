#!/usr/bin/env bash
# fingerprint_lib.sh - fingerprint extraction shared by run_full.sh and run_full.sh.
# Sourced, never executed.
#
# Why this file exists
# --------------------
# Both run scripts used to answer "where did it stop?" with `grep FAR | tail -1`.
# In a nested-abort storm that address is the LAST recursion victim, not the
# fault that started it: the exception handler faults on its own context save,
# so FAR walks down 0x20 per iteration for millions of iterations and stops
# wherever the wall clock happened to cut the run. The consequences were both
# analytic and mechanical:
#
#   - the classifier was handed the least informative end of the trace, so it
#     answered "unknown" or blamed the address the recursion had reached;
#   - the fingerprint moved every round even when nothing changed, so stall,
#     oscillation, exhaustion and layer review could never fire.
#
# The originating exception - the FIRST `Taking exception` block - is stable and
# is the actual stop point. Everything here exists to extract it.

# Where the helper scripts live, whoever sourced this file.
FP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fp_origin <trace_log> <block_out>
#   Writes the first exception block to <block_out> and sets:
#     FP_ORIGIN_TYPE  exception name, e.g. "Data Abort"
#     FP_ORIGIN_ESR / FP_ORIGIN_FAR / FP_ORIGIN_ELR
#   All default to "none" when the trace has no exception at all (a hang).
fp_origin() {
    local log="$1" block="$2"
    FP_ORIGIN_TYPE="none"; FP_ORIGIN_ESR="none"
    FP_ORIGIN_FAR="none";  FP_ORIGIN_ELR="none"
    : > "$block"
    [ -s "$log" ] || return 0

    # The block is the first "Taking exception" line plus its continuation lines,
    # cut at the second one. QEMU prints ESR/FAR/ELR as `...with X 0x...` right
    # after, so a 12-line window covers it with room for format drift.
    awk '
        /Taking exception/ { if (seen) exit; seen = 1 }
        seen { print; if (++n >= 12) exit }
    ' "$log" > "$block" 2>/dev/null || true
    [ -s "$block" ] || return 0

    FP_ORIGIN_TYPE=$(sed -n 's/.*Taking exception [0-9]* \[\([^]]*\)\].*/\1/p' "$block" | head -1)
    [ -n "$FP_ORIGIN_TYPE" ] || FP_ORIGIN_TYPE="none"
    # ESR prints as `ESR 0x25/0x96000046` - both halves are part of the identity.
    FP_ORIGIN_ESR=$(grep -ohE "ESR 0x[0-9a-fA-Fx/]+" "$block" 2>/dev/null | head -1 | awk '{print $2}')
    FP_ORIGIN_FAR=$(grep -ohE "FAR 0x[0-9a-fA-F]+"   "$block" 2>/dev/null | head -1 | awk '{print $2}')
    FP_ORIGIN_ELR=$(grep -ohE "ELR 0x[0-9a-fA-F]+"   "$block" 2>/dev/null | head -1 | awk '{print $2}')
    FP_ORIGIN_ESR="${FP_ORIGIN_ESR:-none}"
    FP_ORIGIN_FAR="${FP_ORIGIN_FAR:-none}"
    FP_ORIGIN_ELR="${FP_ORIGIN_ELR:-none}"
    return 0
}

# fp_console_uniq <console_file>  -> echoes the count of distinct non-blank lines
#
# Console BYTES cannot tell "the boot got further" from "a retry loop printed the
# same line 200,000 times" - one run in the S921N log spent 394 KB on a single
# repeated I2C error. Distinct lines can, so this is the progress measure the
# loop reports and the stop report quotes when no milestone was ever reached.
fp_console_uniq() {
    local out="$1"
    if [ -s "$out" ]; then
        LC_ALL=C sort -u "$out" 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# fp_run_verdict <rc> <trace_log> <console_bytes> <stderr_file>
#   Sets FP_RUN_FAILED (0|1), FP_RUN_FAULT (0|1) and FP_RUN_ERROR.
#
#   FP_RUN_FAILED = the harness never ran the firmware (BLOCKED_ENV).
#   FP_RUN_FAULT  = QEMU died, but the guest had already produced output,
#                   so this is a machine-source defect a fixer can repair.
#
# A QEMU that never started used to look exactly like a clean round: the pipe to
# `tail` swallowed its exit code, and the fingerprint was written as all zeros.
# All-zero fingerprints are perfectly stable, so the stop conditions read them as
# a stall and declared EXHAUSTED - "structurally unreachable" - after eight
# rounds that had never run anything. A harness failure must never be reported as
# a verdict about the firmware.
fp_run_verdict() {
    local rc="$1" log="$2" csz="$3" errf="${4:-}"
    FP_RUN_FAILED=0; FP_RUN_ERROR=""; FP_RUN_FAULT=0; FP_RUN_FAULT_LINE=""
    # 124/137 are `timeout` killing the guest, which is how every round ends.
    case "$rc" in
        0|124|137) ;;
        *)
            FP_RUN_ERROR="QEMU 종료코드 ${rc}"
            if [ -n "$errf" ] && [ -s "$errf" ]; then
                FP_RUN_ERROR="$FP_RUN_ERROR: $(tr '\n' ' ' < "$errf" | tail -c 200)"
                # The assert line names the file and function that tripped, which
                # is what a fixer needs to find the place.
                FP_RUN_FAULT_LINE="$(grep -m1 -E 'Assertion|assert|abort|SIGSEGV' "$errf" 2>/dev/null | tail -c 300)"
            fi
            # A guest that printed before dying DID run. Calling that an
            # environment failure sends it to BLOCKED_ENV, where no fixer is
            # assigned - a machine bug then has to be repaired by hand. The
            # blk_set_perm() assert (exit 250, 596 KB of console already out)
            # was exactly this case.
            if [ "${csz:-0}" -gt 0 ] || [ -s "$log" ]; then
                FP_RUN_FAULT=1
                FP_RUN_ERROR="$FP_RUN_ERROR — 콘솔이 ${csz:-0} 바이트 나온 뒤 죽었으므로 환경이 아니라 머신 결함입니다"
            else
                FP_RUN_FAILED=1
            fi
            return 0
            ;;
    esac
    if [ ! -s "$log" ] && [ "${csz:-0}" -eq 0 ]; then
        FP_RUN_FAILED=1
        FP_RUN_ERROR="트레이스와 콘솔이 모두 0바이트 — QEMU 가 실제로 실행되지 않았습니다 (경로·인자 확인)"
    fi
    return 0
}

# fp_kernel_metrics <kernel_log>
#   Sets FP_KLINES / FP_KUNIQ / FP_KLAST: how deep the kernel channel got.
#   Lines, DISTINCT texts (a poll that repeats one message for every timestamp is not
#   depth - the same reason the UART counts distinct lines, not bytes) and the last
#   kernel time. All "null" when there is no log to measure.
fp_kernel_metrics() {
    local klog="$1"
    FP_KLINES=null; FP_KUNIQ=null; FP_KLAST=null
    [ -f "$klog" ] || return 0
    eval "$(python3 "$FP_LIB_DIR/memdump_observe.py" metrics --log "$klog" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def n(v):
    return "null" if v is None else str(v)
print("FP_KLINES=%s FP_KUNIQ=%s FP_KLAST=%s" % (n(d.get("lines")), n(d.get("uniq")), n(d.get("last_time"))))
' 2>/dev/null || true)"
    return 0
}

# fp_prev_stuck <prev_fingerprint_json> <console_bytes> [kernel_uniq]  -> echoes yes|no
#
# "The previous round ended at exactly this console size." That is the signature
# of a boot that has not moved, and the only case where spending one longer run
# to separate a firmware wall from the wall-clock budget is worth it.
#
# It also demanded zero exceptions once. A firmware can sit at the same console
# size for rounds while its trace still carries a handful of exceptions - the
# S921N run did exactly that for five rounds at 82,639 bytes with 8/8/8/5/2 - and
# that extra condition skipped the probe on precisely the rounds it was for.
#
# With a kernel channel the UART can stand still while the kernel moves, so the
# console size alone says nothing: when the kernel's distinct-line count grew by
# more than a tenth since the previous round the boot is not stuck.
fp_prev_stuck() {
    local prev="$1" csz="$2" kuniq="${3:-}"
    [ -f "$prev" ] || { echo no; return 0; }
    python3 - "$prev" "$csz" "$kuniq" <<'PY' 2>/dev/null || echo no
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("no"); raise SystemExit
same = int(d.get("console_bytes", -1)) == int(sys.argv[2])
try:
    before = (d.get("kernel") or {}).get("uniq")
    now = int(sys.argv[3]) if sys.argv[3] not in ("", "null") else None
    if same and before is not None and now is not None and now > int(before) * 1.1:
        same = False
except (TypeError, ValueError):
    pass
print("yes" if same else "no")
PY
}

# fp_add_channels <fingerprint.json> <memdump_stats.json> <memdump_scan.json> <host_lines> \
#                 <reset.json> <trace_stats.json> <input_summary.json> \
#                 [probe_kernel_uniq] [plan_on 0|1] [host_lines_moved_out_of_console]
#   Adds the channel facts to a fingerprint that was already written. Runs only when a
#   channel is on (a round with none leaves the fingerprint without these keys; see
#   fp_add_host for the one fact such a round can still carry).
#
#     channels            {uart_bytes, kernel_lines, host_lines}
#     kernel              depth of the kernel channel + the evidence kernel_alive rests on +
#                         the task-line shape that judged it (task_regex)
#     guest_reset_signal  the guest reset right after the jump (host-line patterns)
#     early_exit          the run was ended by the exception threshold
fp_add_channels() {
    python3 - "$@" <<'PY' 2>/dev/null || true
import json, sys

def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}

fp_path, kstat_p, scan_p, host_lines, reset_p, trace_p, insum_p = sys.argv[1:8]
probe_uniq = sys.argv[8] if len(sys.argv) > 8 else ""
plan_on = (sys.argv[9] if len(sys.argv) > 9 else "0") == "1"
host_moved = int(sys.argv[10]) if len(sys.argv) > 10 and sys.argv[10].isdigit() else 0
fp = load(fp_path)
if not fp:
    sys.exit(0)
kstat, scan, reset = load(kstat_p), load(scan_p), load(reset_p)
trace, insum = load(trace_p), load(insum_p)
fp["channels"] = {
    "uart_bytes": fp.get("console_bytes", 0),
    "kernel_lines": kstat.get("lines", 0) if kstat else 0,
    "host_lines": int(host_lines or 0),
    # host lines that had reached the console file and were moved out of it
    "host_lines_moved": host_moved,
}
fp["kernel"] = {
    "plan": plan_on,                      # a plan existed; enabled=false then means the observer produced nothing
    "enabled": bool(kstat),
    "lines": kstat.get("lines") if kstat else None,
    "uniq": kstat.get("uniq") if kstat else None,
    "first_time": kstat.get("first_time") if kstat else None,
    "last_time": kstat.get("last_time") if kstat else None,
    "snapshots": kstat.get("snapshots") if kstat else None,
    "overruns": kstat.get("overruns") if kstat else None,
    "gaps": kstat.get("gaps") if kstat else None,
    "started": kstat.get("started") if kstat else None,
    "ended": kstat.get("ended") if kstat else None,
    "region": kstat.get("region") if kstat else None,
    "banner_seen": scan.get("banner_seen") if scan else None,
    # Evidence is reported only for a rung that was actually credited: a round the
    # provenance gate voided (injected) keeps nothing, even if the log held the line.
    "alive_evidence": (scan.get("alive_evidence") if scan
                       and "kernel_alive" in (fp.get("milestones_reached") or []) else None),
    "alive_withheld": bool(scan and scan.get("alive_evidence")
                           and "kernel_alive" not in (fp.get("milestones_reached") or [])),
    "alive_rejected": (scan.get("hits") or {}).get("kernel_alive_rejected") if scan else None,
    # The task-line shape that judged the memory-dump channel: kept whether or not kernel_alive
    # was credited, so a shape that was refused (too loose) or one that credited it is on record.
    "task_regex": scan.get("task_regex") if scan else None,
    "probe_uniq": int(probe_uniq) if probe_uniq not in ("", "null") else None,
    "stats": kstat_p if kstat else "",
    "scan": scan_p if scan else "",
}
fp["guest_reset_signal"] = bool(reset.get("signal"))
fp["guest_reset"] = reset or None
fp["early_exit"] = trace.get("early_exit") or (
    {"reason": insum.get("early_exit")} if insum.get("early_exit") else None)
with open(fp_path, "w", encoding="utf-8") as fh:
    json.dump(fp, fh, ensure_ascii=False, indent=2)
PY
}

# fp_add_host <fingerprint.json> <host_lines> [host_lines_moved_out_of_console]
#   The round had no channel on but QEMU or the machine still spoke ("qemu-system-*: ..."
#   lines, kept in host_<n>.txt). Adds only the count, as channels.host_lines, so the
#   observation can say the file is worth opening; the kernel, reset and early-exit keys
#   stay absent because nothing measured them. fp_add_channels (channel on) writes the
#   same `channels` object with every field.
fp_add_host() {
    python3 - "$@" <<'PY' 2>/dev/null || true
import json, sys

fp_path = sys.argv[1]
host_lines = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 0
host_moved = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 0
try:
    with open(fp_path, encoding="utf-8") as fh:
        fp = json.load(fh)
except Exception:
    sys.exit(0)
fp["channels"] = {
    "uart_bytes": fp.get("console_bytes", 0),
    "kernel_lines": 0,
    "host_lines": host_lines,
    "host_lines_moved": host_moved,
}
with open(fp_path, "w", encoding="utf-8") as fh:
    json.dump(fp, fh, ensure_ascii=False, indent=2)
PY
}

# fp_json_escape <text>  -> stdout, safe to embed between JSON quotes
fp_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'
}
