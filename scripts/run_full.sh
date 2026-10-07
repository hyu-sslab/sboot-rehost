#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
. "$(dirname "$0")/fingerprint_lib.sh"

# Extracts the raw fingerprint and enforces the provenance gate.
# Called by workflows/pipeline.js once per round.
#
# Usage:
#   run_qemu.sh <workdir> <machine_name> <bootloader_path> <cmd> <run_n> [surface]
#
# Output files:
#   <workdir>/07_logs/console_<run_n>.txt      UART output, guest lines only (local)
#   <workdir>/07_logs/run_<run_n>.summary.txt  key stop points  (local)
#   <workdir>/07_logs/origin_<run_n>.txt       originating exception block
#   <workdir>/fingerprint.json                 this round's fingerprint
#   ~/rehost/_traces/run_<run_n>.log           full trace       (WSL ext4)
#
# Whenever the round produced host lines ("qemu-system-*: ..." - the machine and QEMU
# speaking, never guest evidence), with or without a plan:
#   <workdir>/07_logs/host_<run_n>.txt         those lines (stderr ones with a wall-clock epoch in
#                                              front), the leaked ones moved off the console. It
#                                              exists when there was at least one such line, or
#                                              when the plan / reset patterns turned a channel on
#                                              (then an empty file means "on, and silent").
#                                              The same lines are also in qemu_<run_n>.stderr.txt.
# Only when <workdir>/memdump_plan.json is valid (the kernel log lives in RAM, the UART is
# silent); without it none of these appear:
#   <workdir>/07_logs/kernel_<run_n>.log       merged memory-dump kernel log, "<kernel_s> <text>"
#   <workdir>/07_logs/memdump_<run_n>.json     snapshot count, gaps, kernel depth
#   ~/rehost/_traces/memdump_<run_n>/          the raw snapshots
# With the plan the QEMU process also gets REHOST_MEMDUMP_REGION=<base>:<size> (hex), the
# range the machine must never write because the host reads it. Without a valid plan the
# variable is NOT set - whatever the caller's environment held.
#
# Workspace files read (all optional):
#   memdump_plan.json       where the kernel log lives in RAM (static-analyzer derives it)
#   kernel_task_regex.txt   the first non-empty line is the shape of a kernel line's task
#                           prefix, an ERE (memdump_observe.py: used when the default
#                           "[pid:comm]" shape is not what this target's kernel prints). It is
#                           handed to the memdump scan as KERNEL_TASK_REGEX; a KERNEL_TASK_REGEX
#                           already in the environment wins. A shape too loose to name a task
#                           (fewer than 3 fixed characters, or one that matches plain task-less
#                           text) is refused and the default applies; the scan report and
#                           observation.json (task_regex) say which shape judged and which was
#                           refused, and a custom shape that decided kernel_alive is named in
#                           kernel_alive_evidence.task_shape.
#
# Environment (all optional; unset = the behaviour before they existed):
#   MAX_EXCEPTIONS          end the round once the trace holds this many exceptions (0 = never)
#   MEMDUMP_FLOOR/CEILING   shortest/longest seconds between memory dumps (default 2 / 12)
#   REHOST_RESET_PATTERNS   host-line patterns (JSON list or one per line) that mean the guest
#                           touched its reset/watchdog block; REHOST_RESET_WINDOW_S bounds
#                           "right after kernel_entry" (default 10 s). The plan may carry both.
#   KERNEL_TASK_REGEX       overrides kernel_task_regex.txt (see above)
#
# stdout: console= summary= trace= exceptions= console_size= far= elr= milestone=
#         injected= origin_far= origin_elr= console_uniq= run_failed= run_fault= ... host_lines=
#         (and memdump_region= kernel_log= kernel_lines= ... when a channel is on)
#
# run_full.sh - one round of the unified chain, from the first stage onward.
#
# Derived from run_qemu.sh and deliberately keeps its honesty machinery intact:
# the external input harness, the provenance gate, the origin-exception
# fingerprint and the run-failure verdict. What changes is what the machine is
# given - the whole container instead of a carved stage, and a boot medium the
# firmware reads the next stage from rather than a kernel handed to it by QEMU.
#
# There is no -kernel/-dtb/-initrd for the Linux image on purpose. The bootloader
# loads it itself; handing it over would make this run indistinguishable from
# loading a kernel directly, which is the thing this flow exists not to do.
#
# Provenance gate (honesty rule 7 - no self-injection, enforced every round):
#   Even if a goal string appears on the console, if that same string exists in the
#   machine source (.c) then WE printed it, not the firmware. Such a milestone is
#   dropped and injected=true is reported.

set -u

WORKDIR="$1"
MACHINE="$2"
CONTAINER="$3"        # the bootloader container, loaded whole
CMD="${4:-help}"
RUN_N="${5:-1}"
SURFACE="${6:-shell}"      # shell (UART console) | fastboot (USB dispatch)
# The goal ladder, comma-separated, lowest rung first. Without it the "highest
# rung reached" pick could only see the bootloader-side rungs, so a run that
# reached scsi_attach or kernel_alive still reported milestone=none.
LADDER="${7:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"
# Wall-clock budget for one round. The S921N shell prompt appeared between 5.2s
# and 8.0s of wall time under full tracing, so the old default of 8 left no
# margin at all: a slightly slower host turned the same firmware into "did not
# reach". The pipeline can override this (INPUT.md run_timeout_s).
# A round here can walk the whole chain, so the budget is the kernel-boot scale
# rather than the seconds it takes to reach a shell prompt. Too small a budget
# reports "did not reach" for a boot that was still progressing.
TIMEOUT="${TIMEOUT:-200}"
# One extra run, only when the round looks like a hang that has not moved. See
# the probe block below for why a fixed wall-clock budget needs a second look.
TIMEOUT_PROBE="${TIMEOUT_PROBE:-1}"
PROBE_MULT="${PROBE_MULT:-4}"

if [[ -z "$WORKDIR" || -z "$MACHINE" || -z "$CONTAINER" ]]; then
    echo "Usage: $0 <workdir> <machine_name> <container_path> <cmd> <run_n> [surface]" >&2
    exit 1
fi

# The synthesised boot medium. Absent is not fatal: the first rungs are reached
# before anything reads it, and saying so beats refusing to run at all.
MEDIUM="${MEDIUM:-$WORKDIR/fw/lu0.img}"
MEDIUM_ARGS=()
if [ -s "$MEDIUM" ]; then
    # snapshot=on by default: the bootloader really writes to PARAM and the DDI
    # area, so without it a round inherits whatever the previous round left on
    # disk. The round loop compares fingerprints assuming the machine source is
    # the only variable; accumulated disk state breaks that, and reverting a
    # change no longer reverts the run. Set MEDIUM_WRITABLE=1 for the rare round
    # that needs to observe those writes - and record that it was set.
    if [ "${MEDIUM_WRITABLE:-0}" = "1" ]; then
        MEDIUM_ARGS=(-drive "file=$MEDIUM,if=none,format=raw,id=lu0")
        echo "run_full: 매체를 쓰기 가능으로 엽니다 — 이 회차는 멱등하지 않습니다" >&2
    else
        MEDIUM_ARGS=(-drive "file=$MEDIUM,if=none,format=raw,id=lu0,snapshot=on")
    fi
else
    echo "run_full: 부팅 매체가 없습니다 ($MEDIUM) — 매체를 읽는 칸은 이 회차에서 도달 불가" >&2
fi

# DRAM plus the bootloader's own load window has to fit, and that window sits far
# above the DRAM base on some SoCs. 512M was enough for a carved stage; it is not
# enough for a container placed at its real addresses.
MEM="${MEM:-2G}"
if [[ ! -x "$QEMU" ]]; then
    echo "ERROR: QEMU 실행 파일을 찾을 수 없습니다: $QEMU" >&2
    exit 2
fi

mkdir -p "$WORKDIR/07_logs"
TRACE_DIR="${TRACE_DIR:-$HOME/rehost/_traces}"; mkdir -p "$TRACE_DIR"
OUT="$WORKDIR/07_logs/console_${RUN_N}.txt"
SUM="$WORKDIR/07_logs/run_${RUN_N}.summary.txt"
ORIGIN="$WORKDIR/07_logs/origin_${RUN_N}.txt"
INLOG="$WORKDIR/07_logs/input_${RUN_N}.txt"
ERRF="$WORKDIR/07_logs/qemu_${RUN_N}.stderr.txt"
LOG="$TRACE_DIR/run_${RUN_N}.log"
TRACE_STATS="$WORKDIR/07_logs/trace_${RUN_N}.json"

# 디스크가 차면 회차가 아니라 기계가 죽는다. 15회차가 각 10~12 GB 를 남겨 281 GB 를
# 채우고 WSL 이 재시작된 적이 있으므로, 남은 공간을 회차 전에 확인한다.
FREE_MB=$(df -Pm "$TRACE_DIR" 2>/dev/null | awk 'NR==2{print $4}')
MIN_FREE_MB="${MIN_FREE_MB:-4096}"
if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
    echo "run_full: 디스크 여유가 ${FREE_MB} MB 뿐입니다 (최소 ${MIN_FREE_MB} MB) — 회차를 시작하지 않습니다" >&2
    echo "run_failed=1"
    exit 3
fi

# 지난 회차 트레이스는 최근 것만 남긴다. 필터를 거치므로 각각 수 MB 지만,
# 회차가 백 단위로 늘면 그것도 쌓인다.
TRACE_KEEP="${TRACE_KEEP:-10}"
ls -1t "$TRACE_DIR"/run_*.log 2>/dev/null | tail -n +$((TRACE_KEEP + 1)) | xargs -r rm -f 2>/dev/null || true
# The raw memory-dump snapshots are ~1 MB each and a round takes dozens; the merged
# kernel_<n>.log stays in the workspace. Read line by line, not through xargs: a path
# with a space must never turn into two removals.
ls -1dt "$TRACE_DIR"/memdump_* 2>/dev/null | tail -n +$((TRACE_KEEP + 1)) | while IFS= read -r _old; do
    case "$_old" in "$TRACE_DIR"/memdump_*) [ -d "$_old" ] && rm -rf -- "$_old" ;; esac
done
# What the harness did, machine-readable. Without it a round cannot say whether
# the interrupt pattern ever got in front of the gate, and a harness failure is
# recorded as a verdict about the firmware.
INSUM="$WORKDIR/input_summary.json"
rm -f "$OUT" "$SUM" "$LOG" "$ORIGIN" "$ERRF" "$INLOG" "$INSUM"

# --- Observation channels ------------------------------------------------------
# The guest's console is the UART. Firmware that sends the kernel's log to a RAM ring
# and keeps the UART silent is invisible to it, so memdump_plan.json (static-analyzer
# derives where, C4) switches on a second channel: the HOST reads that ring through
# the QEMU monitor while the guest runs. QEMU's own diagnostics are always kept out of
# the console file, so the console is the guest's voice and nothing else (C1), and they
# are always recorded in host_<n>.txt: the first stage's machine facts (ACCESSED,
# UNMODELLED, POLL) are read from there long before any plan can exist.
# Without the plan there is no monitor, no kernel log and no write guard.
MEMDUMP_PLAN="$WORKDIR/memdump_plan.json"
KLOG="$WORKDIR/07_logs/kernel_${RUN_N}.log"
HOSTF="$WORKDIR/07_logs/host_${RUN_N}.txt"
KSTAT="$WORKDIR/07_logs/memdump_${RUN_N}.json"
SNAP_DIR="$TRACE_DIR/memdump_${RUN_N}"
STOPF="$WORKDIR/07_logs/stop_${RUN_N}.flag"
rm -f "$KLOG" "$HOSTF" "$KSTAT" "$STOPF" "$WORKDIR/07_logs/memdump_scan_${RUN_N}.json"
rm -rf "$SNAP_DIR"
MEMDUMP=0
MEMDUMP_REGION=""
if [ -s "$MEMDUMP_PLAN" ]; then
    if MEMDUMP_REGION=$(python3 "$HERE/memdump_observe.py" region "$MEMDUMP_PLAN" 2>/dev/null) \
       && [ -n "$MEMDUMP_REGION" ]; then
        MEMDUMP=1
    else
        MEMDUMP_REGION=""
        echo "run_full: memdump_plan.json 을 쓸 수 없어 메모리 덤프 채널을 켜지 않습니다 — UART 만 관측합니다" >&2
    fi
fi
# The machine must never write the range the host reads, and only the plan knows it. The
# value comes from the plan alone: a stale one in the caller's environment would guard a
# range nobody reads (or, with no plan, guard one for a channel that is off).
if [ "$MEMDUMP" = "1" ]; then
    export REHOST_MEMDUMP_REGION="$MEMDUMP_REGION"
    echo "run_full: 머신의 쓰기 보호 영역 REHOST_MEMDUMP_REGION=$MEMDUMP_REGION (호스트가 읽는 영역)" >&2
else
    if [ -n "${REHOST_MEMDUMP_REGION:-}" ]; then
        echo "run_full: memdump_plan.json 이 없어 환경의 REHOST_MEMDUMP_REGION 을 무시합니다" >&2
    fi
    unset REHOST_MEMDUMP_REGION
fi
# The shape of a kernel line's task prefix is a property of the target's kernel, so the
# analyst writes it into the workspace (kernel_task_regex.txt); only an explicit
# KERNEL_TASK_REGEX in the environment outranks that. The shape decides what counts as a
# running kernel, so it is checked when it is read (memdump_observe.py task-regex): one that
# does not compile is said so and dropped; one that compiles but is too loose to name a task
# (exit 3 - `\w+` and the like, which the bootloader's own lines in a shared ring satisfy)
# is still handed on, and the observer refuses it and says so in the scan report. Either way
# the default shape then applies, and the scan report names the pattern that judged the round
# (task_regex: pattern, custom, rejected).
if [ "$MEMDUMP" = "1" ]; then
    TASK_RX_FILE="$WORKDIR/kernel_task_regex.txt"
    TASK_RX_ERR="$(mktemp -u "${TMPDIR:-/tmp}/sboot_taskrx.XXXXXX")"
    if [ -n "${KERNEL_TASK_REGEX:-}" ]; then
        python3 "$HERE/memdump_observe.py" task-regex --value "$KERNEL_TASK_REGEX" >/dev/null 2>"$TASK_RX_ERR"
        case $? in
            0) echo "run_full: 커널 태스크 접두 형식: 환경의 KERNEL_TASK_REGEX" >&2 ;;
            3) echo "run_full: 환경의 KERNEL_TASK_REGEX 가 너무 느슨해 판정에 쓰지 않습니다 — 기본 형식(\"[pid:comm]\")으로 판정합니다: $(tr '\n' ' ' < "$TASK_RX_ERR")" >&2 ;;
            *) echo "run_full: 환경의 KERNEL_TASK_REGEX 가 올바른 정규식이 아니어서 쓰지 않습니다" >&2
               unset KERNEL_TASK_REGEX ;;
        esac
    fi
    if [ -z "${KERNEL_TASK_REGEX:-}" ] && [ -s "$TASK_RX_FILE" ]; then
        TASK_RX=$(python3 "$HERE/memdump_observe.py" task-regex --file "$TASK_RX_FILE" 2>"$TASK_RX_ERR")
        case $? in
            0) export KERNEL_TASK_REGEX="$TASK_RX"
               echo "run_full: 커널 태스크 접두 형식: kernel_task_regex.txt ($TASK_RX)" >&2 ;;
            3) export KERNEL_TASK_REGEX="$TASK_RX"
               echo "run_full: kernel_task_regex.txt 의 형식이 너무 느슨해 판정에 쓰지 않습니다 — 기본 형식(\"[pid:comm]\")으로 판정합니다: $(tr '\n' ' ' < "$TASK_RX_ERR")" >&2 ;;
            *) echo "run_full: kernel_task_regex.txt 에 올바른 정규식이 없어 기본 형식(\"[pid:comm]\")으로 판정합니다" >&2 ;;
        esac
    fi
    rm -f "$TASK_RX_ERR"
fi
# The host clock (marks, the guest-reset signal) is a statement about timing, so it is on
# only when the plan is, or when reset patterns were configured. The host LINES themselves
# are recorded every round.
HOST_CHANNEL=0
{ [ "$MEMDUMP" = "1" ] || [ -n "${REHOST_RESET_PATTERNS:-}" ]; } && HOST_CHANNEL=1
# Leave an exception storm early. Off by default: the old behaviour is a round that
# runs to its timeout. The filter counts, and raises the flag the harness watches.
MAX_EXC="${MAX_EXCEPTIONS:-0}"
EXC_ARGS=(); STOP_ARGS=()
if [ "$MAX_EXC" -gt 0 ] 2>/dev/null; then
    EXC_ARGS=(--max-exceptions "$MAX_EXC" --stop-file "$STOPF")
    STOP_ARGS=(--stop-file "$STOPF")
fi
MON_SOCK=""; MON_ARGS=()
if [ "$MEMDUMP" = "1" ]; then
    # Short path: a unix socket path is limited to ~100 bytes.
    MON_SOCK="$(mktemp -u "${TMPDIR:-/tmp}/sboot_mon.XXXXXX")"
    MON_ARGS=(-monitor "unix:$MON_SOCK,server,nowait")
fi

# A machine that hands the boot between an AArch32 and an AArch64 CPU (the mixed-arch
# template; its handoff watcher is the marker) was only ever run on one TCG thread.
# Whether the watcher is safe against a second vCPU thread is not known, so those
# machines get the single-threaded mode and everything else runs as it always did.
ACCEL_ARGS=()
if grep -qs 'handoff_tick' "$WORKDIR"/06_machine/*.c 2>/dev/null; then
    ACCEL_ARGS=(-accel tcg,thread=single)
fi

# The console token that means the surface is up. static-analyzer derives it into
# milestone_tokens.txt; the harness stops trying to interrupt autoboot once it
# appears and sends the command instead.
PROMPT_TOKEN=""
if [ -s "$WORKDIR/milestone_tokens.txt" ]; then
    PROMPT_TOKEN=$(awk -F'\t' -v s="$SURFACE" 'NF>1 && $1==s {print $2; exit}' \
                   "$WORKDIR/milestone_tokens.txt")
fi
# An array, not ${VAR:+...}: a prompt token contains spaces (a shell prompt ends in one)
# and the unquoted form word-splits it, so the harness would look for the wrong string.
PROMPT_ARGS=()
[ -n "$PROMPT_TOKEN" ] && PROMPT_ARGS=(--prompt-token "$PROMPT_TOKEN")

# What the harness is asked to watch on the side. `kernel_entry` is the bootloader's
# own jump announcement (static-analyzer derives it): its wall-clock starts both the
# memory dump and the window for the guest-reset signal. A token on another channel
# (memdump) is not a console line and is not looked for here.
KENTRY_TOKEN=""
if [ -s "$WORKDIR/milestone_tokens.txt" ]; then
    KENTRY_TOKEN=$(awk -F'\t' '{ gsub(/\r/, "") } NF>1 && $1=="kernel_entry" && ($3=="" || $3=="uart") {print $2; exit}' \
                   "$WORKDIR/milestone_tokens.txt")
fi
CHAN_ARGS=(--host-log "$HOSTF")
if [ "$HOST_CHANNEL" = "1" ]; then
    [ -n "$KENTRY_TOKEN" ] && CHAN_ARGS+=(--mark "kernel_entry=$KENTRY_TOKEN")
fi
# Dump start and pacing for the memory-dump observer. Floor and ceiling bound the
# interval the observer derives from the ring size and the log rate.
KENTRY_ARGS=()
[ -n "$KENTRY_TOKEN" ] && KENTRY_ARGS=(--start-token "$KENTRY_TOKEN")
OBS_PID=""
start_observer() {   # $1 socket  $2 snapshot dir  $3 merged log  $4 stats  $5 console  $6 seconds
    OBS_PID=""
    python3 "$HERE/memdump_observe.py" watch --plan "$MEMDUMP_PLAN" --socket "$1" \
        --snap-dir "$2" --out "$3" --stats "$4" --console "$5" --deadline "$6" \
        --floor "${MEMDUMP_FLOOR:-2}" --ceiling "${MEMDUMP_CEILING:-12}" \
        ${KENTRY_ARGS[@]+"${KENTRY_ARGS[@]}"} &
    OBS_PID=$!
}
stop_observer() {    # the run is over; the observer merges what it has and exits
    [ -n "$OBS_PID" ] || return 0
    kill -TERM "$OBS_PID" 2>/dev/null || true
    wait "$OBS_PID" 2>/dev/null || true
    OBS_PID=""
}

# Keep the previous round's fingerprint: the timeout probe below needs to know
# whether the console has stopped growing across rounds.
PREV="$WORKDIR/fingerprint.prev.json"
[ -f "$WORKDIR/fingerprint.json" ] && cp "$WORKDIR/fingerprint.json" "$PREV" 2>/dev/null || true

python3 "$HERE/record.py" "$WORKDIR" start "run_${RUN_N}" >/dev/null 2>&1 || true

# Input comes from OUTSIDE the machine (honesty rule 7). uart_harness.py owns the
# guest console: it repeats the derived autoboot-interrupt pattern while the gate
# may be open, sends the command once the surface answers, and logs every byte it
# typed. `-serial stdio` hands the console to its pipes; the machine is not given
# a command line to seed itself from.
#
# The exit code matters: piping it into `tail` threw it away, so a QEMU that
# never started reported success and the round looked clean.
# The trace goes through a filter, not straight to disk. `-d int,in_asm,nochain`
# writes 10-12 GB on a firmware that faults in a loop, and none of that volume is
# read: the pipeline consumes the exception count, the FIRST exception block, the
# last FAR/ELR, and whether each stage entry PC appeared. trace_filter.py keeps
# exactly that in bounded space, so the log stays a few MB however long the run.
# The watch list is each runnable stage's ENTRY PC, read from stage_map.json by the
# filter itself (--stage-map): v2 `entry_pc`, or for a v1 map load_base plus the entry
# offset - the very value verify.py item 4 searches for. This used to be a list built
# here from `base`, which is a dict, so it was empty on every SoC and the chain-PC
# measurement could not pass anywhere.

FIFO="$(mktemp -u "${TMPDIR:-/tmp}/sboot_trace.XXXXXX")"
FILTER_PID=""
if mkfifo "$FIFO" 2>/dev/null; then
    python3 "$HERE/trace_filter.py" --out "$LOG" --stats "$TRACE_STATS" \
        --stage-map "$WORKDIR/stage_map.json" \
        ${EXC_ARGS[@]+"${EXC_ARGS[@]}"} < "$FIFO" &
    FILTER_PID=$!
    # 쓰기 쪽 FD 를 셸이 잡고 있어야 한다. QEMU 가 -D 를 아예 열지 않는 경우
    # (실행 실패, 인자 오류) 필터가 EOF 를 못 받아 wait 가 영원히 멈춘다.
    exec 9>"$FIFO"
    TRACE_TARGET="$FIFO"
else
    # 필터를 못 걸면 원본을 그대로 쓴다. 용량은 커지지만 회차를 잃지는 않는다.
    echo "run_full: FIFO 를 만들지 못해 트레이스를 그대로 씁니다 (용량 주의)" >&2
    TRACE_TARGET="$LOG"
fi

RUN_RC=0
# The observer starts first: it waits for the monitor socket QEMU creates, then for the
# bootloader's jump announcement on the console, and takes its last dump just before
# the harness ends the run.
[ "$MEMDUMP" = "1" ] && start_observer "$MON_SOCK" "$SNAP_DIR" "$KLOG" "$KSTAT" "$OUT" "$TIMEOUT"
python3 "$HERE/uart_harness.py" \
    --console "$OUT" --input-log "$INLOG" --summary "$INSUM" \
    --plan "$WORKDIR/input_plan.json" \
    --timeout "$TIMEOUT" --cmd "$CMD" --surface "$SURFACE" \
    ${PROMPT_ARGS[@]+"${PROMPT_ARGS[@]}"} \
    ${CHAN_ARGS[@]+"${CHAN_ARGS[@]}"} ${STOP_ARGS[@]+"${STOP_ARGS[@]}"} \
    -- "$QEMU" \
    -M "$MACHINE" -m "$MEM" -display none -serial stdio \
    ${ACCEL_ARGS[@]+"${ACCEL_ARGS[@]}"} \
    -kernel "$CONTAINER" ${MEDIUM_ARGS[@]+"${MEDIUM_ARGS[@]}"} \
    ${MON_ARGS[@]+"${MON_ARGS[@]}"} \
    -d int,in_asm,nochain -D "$TRACE_TARGET" \
    2> "$ERRF" || RUN_RC=$?

if [ -n "$FILTER_PID" ]; then
    exec 9>&-                       # 마지막 쓰기 쪽을 닫아 필터에 EOF 를 준다
    wait "$FILTER_PID" 2>/dev/null || true
    rm -f "$FIFO" 2>/dev/null || true
fi
tail -3 "$ERRF" 2>/dev/null || true

# --- Channels after the run -----------------------------------------------------
# QEMU is gone, so the observer has nothing left to read: let it merge its snapshots
# into kernel_<n>.log. Then the console is made guest-only: a host diagnostic line
# that reached it (a printf past the harness, a merged stream) moves to host_<n>.txt.
# This runs BEFORE any measurement below, so size, uniq lines and tokens are all
# computed on what the guest said.
stop_observer
rm -f "$MON_SOCK" "$STOPF" 2>/dev/null || true    # the flag's fact lives in the fingerprint
HOST_LINES=0; HOST_MOVED=0
HOST_MOVED=$(python3 "$HERE/memdump_observe.py" split-host --console "$OUT" --host "$HOSTF" 2>/dev/null) || HOST_MOVED=0
[ -f "$HOSTF" ] && HOST_LINES=$(wc -l < "$HOSTF" | tr -d ' ')
if [ "$HOST_CHANNEL" = "1" ]; then
    [ -f "$HOSTF" ] || : > "$HOSTF"             # on and silent: an empty file says so
elif [ "$HOST_LINES" -eq 0 ]; then
    rm -f "$HOSTF"                              # nothing was said and no channel asked: no file
fi
FP_KLINES=null; FP_KUNIQ=null; FP_KLAST=null
[ "$MEMDUMP" = "1" ] && fp_kernel_metrics "$KLOG"

# --- What the input path actually did ------------------------------------
# `milestone=none` has two very different causes and they used to be the same
# observation: the gate polled and our bytes were not there (a harness failure),
# or the gate read them and the firmware booted on (a firmware observation).
# Sending a fixer after the first one spends a round on a fault that does not
# exist, so the round has to be able to tell them apart.
eval "$(python3 - "$INSUM" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
def b(key):
    return "true" if d.get(key) else "false"
def n(key):
    v = d.get(key)
    return "null" if v is None else str(int(v))
def t(key):          # true / false / null: unknown is not false
    v = d.get(key)
    return "null" if v is None else ("true" if v else "false")
print(f'FP_WAITING={t("waiting_for_input")}')
print(f'FP_INPUT_OFFERED={b("input_offered")}')
print(f'FP_PROMPT_SEEN={b("prompt_seen")}')
print(f'FP_COMMAND_SENT={b("command_sent")}')
print(f'FP_COMMAND_BLIND={b("command_blind")}')
print(f'FP_INPUT_STARVED={b("input_starved")}')
print(f'FP_SUPPLY_CAPPED={b("supply_capped")}')
print(f'FP_RX_REPORTED={b("rx_reported")}')
print(f'FP_RX_SERVED={n("rx_served")}')
print(f'FP_RX_POLLS={n("rx_polls")}')
print(f'FP_BYTES_SENT={n("bytes_sent")}')
PY
)"
# An absent summary means the harness itself did not finish; report it as unknown
# rather than as "no input was offered", which would be a claim we cannot make.
: "${FP_INPUT_OFFERED:=false}" "${FP_PROMPT_SEEN:=false}" "${FP_COMMAND_SENT:=false}"
: "${FP_COMMAND_BLIND:=false}" "${FP_INPUT_STARVED:=false}" "${FP_SUPPLY_CAPPED:=false}"
: "${FP_RX_REPORTED:=false}" "${FP_RX_SERVED:=null}" "${FP_RX_POLLS:=null}"
: "${FP_BYTES_SENT:=null}" "${FP_WAITING:=null}"

# --- Fingerprint: raw observations only, never a classification ---
# NOTE: grep -c exits 1 when the count is zero while still printing "0".
# Using `|| echo 0` would emit TWO lines and corrupt the JSON below, so assign
# first and fall back only on a non-zero exit.
# 필터가 원본 전체를 세므로 잘린 로그를 grep 하지 않는다. 필터를 못 걸었을 때만
# 로그에서 직접 센다.
EXC=$(python3 -c "
import json,sys
try: print(json.load(open('$TRACE_STATS'))['exceptions'])
except Exception: sys.exit(1)" 2>/dev/null) \
  || EXC=$(grep -c "Taking exception" "$LOG" 2>/dev/null) || EXC=0
[ -n "$EXC" ] || EXC=0
if [ -f "$OUT" ]; then CSZ=$(wc -c < "$OUT" | tr -d ' '); else CSZ=0; fi
CUNIQ=$(fp_console_uniq "$OUT")

# The last FAR/ELR in the log. Kept for continuity of the record, NOT used as
# the identity of the stop point: under a nested abort it is wherever the
# recursion happened to be when the clock ran out.
FAR=$(grep -ohE "FAR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
ELR=$(grep -ohE "ELR 0x[0-9a-fA-F]+" "$LOG" 2>/dev/null | tail -1 | awk '{print $2}')
FAR="${FAR:-none}"; ELR="${ELR:-none}"

# The originating exception - the one that actually needs a fix.
fp_origin "$LOG" "$ORIGIN"

fp_run_verdict "$RUN_RC" "$LOG" "$CSZ" "$ERRF"

# The summary is what the classifier reads. It leads with the originating
# exception; the tail is kept below it because the end of the trace still shows
# how the run died.
{
    echo "=== 최초 예외 (첫 Taking exception 블록) ==="
    if [ -s "$ORIGIN" ]; then cat "$ORIGIN"; else echo "(예외 없음 — 폴링 hang 또는 정상 종료)"; fi
    echo
    echo "=== 마지막 60줄 (트레이스 마지막 — 근본 원인이 아닐 수 있음) ==="
    grep -E "Taking exception|FAR|ELR|ESR|UPLOAD|E_SYNC|panic|abort|smc" "$LOG" 2>/dev/null | tail -60
} > "$SUM" 2>/dev/null || true

# --- Milestone + provenance gate ---
# A goal is reached when the console shows text the FIRMWARE owns, on
# whichever interactive surface this firmware actually has.
#
# The tokens are data, not a constant: a UART shell prints a prompt and a command
# list, while a fastboot surface prints its own dispatch lines. Encoding one
# vendor's banner here would strand every other bootloader. static-analyzer
# derives the real strings and writes them to milestone_tokens.txt. Without that file a
# shell surface is NOT credited at all (no banner of ours decides it); see below.
#
# Injection is dominant: if ANY milestone token also lives in the machine source,
# the console is contaminated and nothing is credited, even when another token
# looks clean. Crediting the clean one would let a machine that fakes the prompt
# claim the surface. A false "not reached" costs extra rounds; a false "reached"
# produces a fake success, and this project always takes the former.
MILESTONE="none"; INJECTED="false"; INJECTED_TOKEN=""
SRC_DIR="$WORKDIR/06_machine"

# milestone_tokens.txt lines are "<milestone>\t<token>[\t<channel>]"; a line with no
# tab is a token for the surface rung. static-analyzer writes the strings it derived,
# so grades B/C (commands, autoboot) can be observed on any bootloader.
#
# The channel says where the string is looked for (C2): `uart` (the default - a
# two-column file means exactly what it always meant) is the guest console above;
# `memdump` is the kernel log the host read out of RAM (kernel_<n>.log). A token is
# only ever looked for on its own channel: a kernel line quoted on the UART by the
# bootloader is not the kernel running, and a UART string is not in a RAM dump.
REACHED=""
SURFACE_NOTE_FIELD=""     # set when the surface rung could not be judged (no derived token file)
TAB="$(printf '\t')"

scan_token() {   # $1 = milestone, $2 = console token
    grep -qF "$2" "$OUT" 2>/dev/null || return 0
    if grep -qF "$2" "$SRC_DIR"/*.c 2>/dev/null; then
        INJECTED="true"
        INJECTED_TOKEN="${INJECTED_TOKEN:+$INJECTED_TOKEN, }$2"
    else
        case " $REACHED " in *" $1 "*) ;; *) REACHED="$REACHED $1";; esac
    fi
}

TOKEN_FILE="$WORKDIR/milestone_tokens.txt"
MEM_TOKENS=0
if [ -s "$TOKEN_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *"$TAB"*)
                t_ms="${line%%$TAB*}"; t_tok="${line#*$TAB}"; t_ch=""
                case "$t_tok" in
                    *"$TAB"*) t_ch="${t_tok#*$TAB}"; t_tok="${t_tok%%$TAB*}" ;;
                esac
                t_ch="${t_ch%$'\r'}"
                case "$t_ch" in
                    ""|uart) scan_token "$t_ms" "$t_tok" ;;
                    memdump) MEM_TOKENS=$((MEM_TOKENS + 1)) ;;
                    *) echo "run_full: 알 수 없는 채널 '$t_ch' — 토큰을 건너뜁니다 ($t_ms)" >&2 ;;
                esac ;;
            *) scan_token "$SURFACE" "$line" ;;
        esac
    done < "$TOKEN_FILE"
elif [ "$SURFACE" = "fastboot" ]; then
    for t in "fastboot: processing commands" "fastboot_init(" "command buf"; do
        scan_token "$SURFACE" "$t"
    done
elif [ "$SURFACE" = "shell" ]; then
    # No derived token file, so nothing says what this bootloader's shell prints. A banner
    # written here would be one bootloader's string deciding every other one's surface rung
    # (and, found by accident, a "reached" that nobody derived). The rung is reported as
    # not credited, with the reason, instead of being guessed either way. The round still
    # runs and every other measurement stands; the fix is for static-analyzer to write
    # milestone_tokens.txt (STATIC.md says which strings and where they were found).
    SURFACE_NOTE_FIELD=$',\n  "surface_not_credited": "no derived token file"'
    echo "run_full: 표면 칸(${SURFACE})을 도달로 세지 않았습니다 — no derived token file (milestone_tokens.txt 가 없거나 비어 있음). 관측 문자열은 static-analyzer 가 도출해 그 파일에 쓰며, 이 스크립트는 벤더 배너를 두지 않습니다." >&2
fi

# memdump-channel tokens, judged against the merged kernel log in one pass. The
# provenance gate is the same one: text the machine source contains is text WE wrote.
# kernel_alive is held to more than a string hit - memdump_observe.py wants a
# kernel-timestamped line with the task that printed it, and says why when it refuses.
MEMSCAN=""
if [ "$MEM_TOKENS" -gt 0 ]; then
    if [ "$MEMDUMP" = "1" ] && [ -f "$KLOG" ]; then
        MEMSCAN="$WORKDIR/07_logs/memdump_scan_${RUN_N}.json"
        python3 "$HERE/memdump_observe.py" scan --tokens "$TOKEN_FILE" --log "$KLOG" \
            --src-dir "$SRC_DIR" > "$MEMSCAN" 2>/dev/null || { rm -f "$MEMSCAN"; MEMSCAN=""; }
    elif [ "$MEMDUMP" = "1" ]; then
        echo "run_full: memdump 관측기가 kernel_${RUN_N}.log 를 만들지 못했습니다 — memdump 토큰 ${MEM_TOKENS} 개는 이 회차에서 관측되지 않았습니다" >&2
    else
        echo "run_full: memdump 채널 토큰 ${MEM_TOKENS} 개가 있으나 memdump_plan.json 이 없어 이 칸들은 관측할 수 없습니다 — 도달 불가가 아니라 관측 채널이 없는 것입니다" >&2
    fi
fi
if [ -n "$MEMSCAN" ] && [ -s "$MEMSCAN" ]; then
    eval "$(python3 - "$MEMSCAN" <<'PYM' 2>/dev/null || true
import json, shlex, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
print("MEM_REACHED=" + shlex.quote(" ".join(d.get("reached") or [])))
print("MEM_INJECTED=" + ("true" if d.get("injected") else "false"))
print("MEM_INJECTED_TOKEN=" + shlex.quote(d.get("injected_token") or ""))
PYM
)"
    for m in ${MEM_REACHED:-}; do
        case " $REACHED " in *" $m "*) ;; *) REACHED="$REACHED $m";; esac
    done
    if [ "${MEM_INJECTED:-false}" = "true" ]; then
        INJECTED="true"
        INJECTED_TOKEN="${INJECTED_TOKEN:+$INJECTED_TOKEN, }${MEM_INJECTED_TOKEN:-}"
    fi
fi

# A stage that prints nothing has no string to look for, and the pipeline writes
# stage_rungs.json ({"rungs": [{rung, stage, index, entry_pc}]}) to say which rung stands for
# which stage. Such a rung - one with no token of its own, on any channel - is credited when
# the trace shows the stage's entry PC EXECUTED (the first instruction of a translated
# block; a PC named only in a FAR/ELR line is a fault, not an entry). The entry PC is read
# from stage_map.json, the same value the watch list and verify.py use. A stage NAME does
# not identify a stage: after `stage_map.py --merge` two images can both hold `stage0`
# and `stage1` (unlabeled stages are named per image), and a rung -> stage lookup by
# name alone would credit the rung of a stage that never ran because another stage of the
# same name did. The stage is therefore resolved by its name AND the entry_pc the rung
# file carries; when that still leaves two different PCs, by its place in the chain (rung
# index), which counts only while the watch list lines up one to one with the map's
# runnable stages. A stage that cannot be told apart is credited nothing. It is a
# measurement of the guest, so the same dominance below applies: a contaminated round
# credits nothing.
#
# The FIRST stage is the exception (rung index 0): its entry is where the machine itself
# put the CPU, so seeing that PC executed says nothing about the firmware. It needs a
# string of its own like every other claim about the first stage.
RUNGS_FILE="$WORKDIR/stage_rungs.json"
if [ -s "$RUNGS_FILE" ] && [ -s "$TRACE_STATS" ]; then
    PC_REACHED=$(python3 - "$HERE" "$RUNGS_FILE" "$WORKDIR/stage_map.json" "$TRACE_STATS" "$TOKEN_FILE" <<'PYR' 2>/dev/null || true
import json, sys
here, rungs_f, map_f, stats_f, tok_f = sys.argv[1:6]
sys.path.insert(0, here)
import trace_filter as tf
try:
    rungs = (json.load(open(rungs_f, encoding="utf-8")) or {}).get("rungs") or []
    stats = json.load(open(stats_f, encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(0)
have_token = set()
try:
    for ln in open(tok_f, encoding="utf-8", errors="replace"):
        parts = ln.rstrip("\r\n").split("\t")
        if len(parts) >= 2 and parts[0].strip():
            have_token.add(parts[0].strip())
except OSError:
    pass
watch = tf.stage_watch(map_f)
try:
    n_exec = sum(1 for st in (json.load(open(map_f, encoding="utf-8")).get("stages") or [])
                 if st.get("state") == "exec")
except (OSError, ValueError, AttributeError):
    n_exec = -1
aligned = len(watch) == n_exec
executed = {tf._hex_int(e.get("pc")) for e in stats.get("stage_entries_executed") or []}


def stage_pc(r):
    """The entry PC of the stage a rung stands for, or None when it cannot be told."""
    cands = [w for w in watch if w["name"] == r.get("stage")]
    want = tf._hex_int(r.get("entry_pc"))
    if want is not None:
        cands = [w for w in cands if tf._hex_int(w["pc"]) == want]
    pcs = {tf._hex_int(w["pc"]) for w in cands}
    if len(pcs) == 1:
        return pcs.pop()
    idx = r.get("index")
    if len(pcs) > 1 and aligned and isinstance(idx, int) and 0 <= idx < len(watch) \
            and watch[idx] in cands:
        return tf._hex_int(watch[idx]["pc"])
    return None


out = []
for r in rungs:
    name = r.get("rung")
    if not name or name in have_token or r.get("index") == 0:
        continue
    pc = stage_pc(r)
    if pc is not None and pc in executed:
        out.append(name)
print(" ".join(out))
PYR
)
    for m in $PC_REACHED; do
        case " $REACHED " in *" $m "*) ;; *) REACHED="$REACHED $m";; esac
    done
fi

# Injection is dominant: a contaminated console credits nothing at all.
[ "$INJECTED" = "true" ] && REACHED=""

# Highest rung wins, in ladder order. The ladder is derived per firmware, so it
# is passed in rather than hard-coded - the previous list named only the
# bootloader rungs, which meant a kernel-side milestone was matched into
# REACHED and then never selected as THE milestone.
RUNG_ORDER="${LADDER//,/ }"
[ -n "$RUNG_ORDER" ] || RUNG_ORDER="$SURFACE commands autoboot"
for m in $RUNG_ORDER; do
    case " $REACHED " in *" $m "*) MILESTONE="$m" ;; esac
done
MILESTONES_JSON=$(python3 -c 'import sys,json;print(json.dumps(sys.argv[1].split()))' "$REACHED")

# --- Storage readiness (partition table) -------------------------------------
# Grade C means the bootloader carries on into a normal boot, which requires
# reading the boot medium. The medium is modelled here, so
# an absent table means the synthesised image is wrong, not that the firmware
# failed. Recording which one it was keeps the loop from prescribing memory
# windows for a partition table that was never going to come.
#
# The strings are vendor-specific, so static-analyzer derives them into
# storage_tokens.txt as "<ok|missing><TAB><token>".
#
# ABSENCE IS NOT EVIDENCE. A round that died before storage init has printed
# neither token; calling that "missing" would block a grade on a boot that never
# got there. Unknown stays unknown, and unknown blocks nothing.
STORAGE="unknown"; STORAGE_TOKEN=""
SFILE="$WORKDIR/storage_tokens.txt"
if [ -s "$SFILE" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in *"$TAB"*) ;; *) continue ;; esac
        s_state="${line%%$TAB*}"; s_token="${line#*$TAB}"
        [ -n "$s_token" ] || continue
        grep -qF "$s_token" "$OUT" 2>/dev/null || continue
        case "$s_state" in
            # A failed integrity check is decisive: the firmware looked and said no.
            missing) STORAGE="missing"; STORAGE_TOKEN="$s_token"; break ;;
            ok)      if [ "$STORAGE" = "unknown" ]; then
                         STORAGE="ok"; STORAGE_TOKEN="$s_token"
                     fi ;;
        esac
    done < "$SFILE"
fi
STORAGE_TOKEN_JSON="$(fp_json_escape "$STORAGE_TOKEN")"

# --- Timeout probe -----------------------------------------------------------
# TIMEOUT is a fixed wall-clock budget, so "the firmware hung" and "we killed a
# boot that was still working" produce the same observation: the console stopped
# growing. When the previous round ended at exactly the same console size, one
# longer run answers which it was. The probe never touches the fingerprint - it
# only reports timeout_bound, so the supervisor can tell a harness wall from a
# firmware wall instead of spending rounds on it.
#
# It used to also require zero exceptions. On S921N rounds 12-16 the console was
# byte-identical at 82,639 for five rounds while the trace carried 8/8/8/5/2
# exceptions, so the probe was skipped every time - and `false` was written as
# though it had been measured. An unmeasured value that reads as a measurement
# is worse than no value, so a skipped probe now reports null.
#
# The kernel channel counts as console too: "a longer run printed more" is as true of
# the kernel log as of the UART, and a boot whose UART is silent would otherwise never
# be probed (or always look like a firmware wall).
TIMEOUT_BOUND="null"; PROBE_BYTES=-1; PROBE_KUNIQ=null
if [ "$TIMEOUT_PROBE" != "0" ] && [ "$MILESTONE" = "none" ] \
   && [ "$FP_RUN_FAILED" -eq 0 ] && [ -f "$PREV" ]; then
    if [ "$(fp_prev_stuck "$PREV" "$CSZ" "$FP_KUNIQ")" = "yes" ]; then
        PROBE_OUT="$WORKDIR/07_logs/probe_${RUN_N}.txt"
        PROBE_LOG="$TRACE_DIR/probe_${RUN_N}.log"
        rm -f "$PROBE_OUT" "$PROBE_LOG"
        PROBE_MON=(); PROBE_SOCK=""
        PROBE_KLOG="$WORKDIR/07_logs/kernel_probe_${RUN_N}.log"
        PROBE_SNAPS="$TRACE_DIR/memdump_probe_${RUN_N}"
        if [ "$MEMDUMP" = "1" ]; then
            rm -rf "$PROBE_SNAPS"; rm -f "$PROBE_KLOG"
            PROBE_SOCK="$(mktemp -u "${TMPDIR:-/tmp}/sboot_mon.XXXXXX")"
            PROBE_MON=(-monitor "unix:$PROBE_SOCK,server,nowait")
            start_observer "$PROBE_SOCK" "$PROBE_SNAPS" "$PROBE_KLOG" \
                "${KSTAT}.probe" "$PROBE_OUT" $((TIMEOUT * PROBE_MULT))
        fi
        python3 "$HERE/uart_harness.py" \
            --console "$PROBE_OUT" --input-log "${INLOG}.probe" \
            --summary "${INSUM}.probe" \
            --plan "$WORKDIR/input_plan.json" \
            --timeout $((TIMEOUT * PROBE_MULT)) --cmd "$CMD" --surface "$SURFACE" \
            ${PROMPT_ARGS[@]+"${PROMPT_ARGS[@]}"} \
            -- "$QEMU" \
            -M "$MACHINE" -m "$MEM" -display none -serial stdio \
            ${ACCEL_ARGS[@]+"${ACCEL_ARGS[@]}"} \
            -kernel "$CONTAINER" ${MEDIUM_ARGS[@]+"${MEDIUM_ARGS[@]}"} \
            ${PROBE_MON[@]+"${PROBE_MON[@]}"} \
            -d int,nochain -D "$PROBE_LOG" \
            >/dev/null 2>&1 || true
        if [ "$MEMDUMP" = "1" ]; then
            stop_observer
            rm -f "$PROBE_SOCK"; rm -rf "$PROBE_SNAPS"
            _SAVE_K="$FP_KLINES $FP_KUNIQ $FP_KLAST"
            fp_kernel_metrics "$PROBE_KLOG"; PROBE_KUNIQ="$FP_KUNIQ"
            read -r FP_KLINES FP_KUNIQ FP_KLAST <<< "$_SAVE_K"
        fi
        if [ -f "$PROBE_OUT" ]; then PROBE_BYTES=$(wc -c < "$PROBE_OUT" | tr -d ' '); else PROBE_BYTES=0; fi
        if [ "$PROBE_BYTES" -gt "$CSZ" ]; then TIMEOUT_BOUND="true"; else TIMEOUT_BOUND="false"; fi
        if [ "$PROBE_KUNIQ" != "null" ] && [ "$PROBE_KUNIQ" -gt "${FP_KUNIQ/null/0}" ]; then
            TIMEOUT_BOUND="true"
        fi
        rm -f "$PROBE_LOG"
    fi
fi

# --- Guest reset ---------------------------------------------------------------
# A guest that resets right after the jump leaves no kernel log (the ring is not
# registered yet) and no UART line: it looks like silence. The machine's own host
# lines can say otherwise - an access to a reset or watchdog block - and "within N s
# of kernel_entry" is a claim about timing, so only host lines with a clock count.
# Which lines mean a reset is data (the plan or REHOST_RESET_PATTERNS), never code.
RESET_JSON_F=""
if [ "$HOST_CHANNEL" = "1" ]; then
    RESET_JSON_F="$WORKDIR/07_logs/reset_${RUN_N}.json"
    python3 "$HERE/memdump_observe.py" reset-signal --host-log "$HOSTF" --summary "$INSUM" \
        --plan "$MEMDUMP_PLAN" > "$RESET_JSON_F" 2>/dev/null || { rm -f "$RESET_JSON_F"; RESET_JSON_F=""; }
fi

# Where this round's channel logs are, for observation.json (null = the file does not exist).
KLOG_JSON=null; HOST_JSON=null
[ "$MEMDUMP" = "1" ] && [ -f "$KLOG" ] && KLOG_JSON="\"$(fp_json_escape "$KLOG")\""
[ -f "$HOSTF" ] && HOST_JSON="\"$(fp_json_escape "$HOSTF")\""

INJECTED_TOKEN_JSON="$(fp_json_escape "$INJECTED_TOKEN")"
RUN_ERROR_JSON="$(fp_json_escape "$FP_RUN_ERROR")"
ORIGIN_TYPE_JSON="$(fp_json_escape "$FP_ORIGIN_TYPE")"

cat > "$WORKDIR/fingerprint.json" <<JSON
{
  "round": ${RUN_N},
  "track": 1,
  "exceptions": ${EXC},
  "far": "${FAR}",
  "elr": "${ELR}",
  "origin": {
    "type": "${ORIGIN_TYPE_JSON}",
    "esr": "${FP_ORIGIN_ESR}",
    "far": "${FP_ORIGIN_FAR}",
    "elr": "${FP_ORIGIN_ELR}",
    "block": "${ORIGIN}"
  },
  "console_bytes": ${CSZ},
  "console_uniq": ${CUNIQ},
  "milestone": "${MILESTONE}",
  "milestones_reached": ${MILESTONES_JSON},
  "source_gate": { "injected": ${INJECTED}, "token": "${INJECTED_TOKEN_JSON}" },
  "run_failed": $([ "$FP_RUN_FAILED" -eq 1 ] && echo true || echo false),
  "run_fault": $([ "${FP_RUN_FAULT:-0}" -eq 1 ] && echo true || echo false),
  "run_fault_line": $(printf '%s' "${FP_RUN_FAULT_LINE:-}" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'),
  "run_error": "${RUN_ERROR_JSON}",
  "input": {
    "offered": ${FP_INPUT_OFFERED},
    "prompt_seen": ${FP_PROMPT_SEEN},
    "command_sent": ${FP_COMMAND_SENT},
    "command_blind": ${FP_COMMAND_BLIND},
    "starved": ${FP_INPUT_STARVED},
    "supply_capped": ${FP_SUPPLY_CAPPED},
    "rx_reported": ${FP_RX_REPORTED},
    "rx_served": ${FP_RX_SERVED},
    "rx_polls": ${FP_RX_POLLS},
    "bytes_sent": ${FP_BYTES_SENT},
    "waiting_for_input": ${FP_WAITING},
    "summary": "${INSUM}",
    "log": "${INLOG}"
  },
  "storage": {
    "partition_table": "${STORAGE}",
    "token": "${STORAGE_TOKEN_JSON}"
  },
  "timeout_bound": ${TIMEOUT_BOUND},
  "probe_console_bytes": ${PROBE_BYTES},
  "console": "${OUT}",
  "summary": "${SUM}",
  "trace": "${LOG}",
  "kernel_log": ${KLOG_JSON},
  "host_log": ${HOST_JSON}${SURFACE_NOTE_FIELD}
}
JSON

# The channel facts go in afterwards and only when a channel is on, so a round without
# one writes the fingerprint as before. A round with no channel that still heard the
# machine (host lines) carries just that count.
if [ "$HOST_CHANNEL" = "1" ] || [ "$MAX_EXC" -gt 0 ] 2>/dev/null; then
    fp_add_channels "$WORKDIR/fingerprint.json" "$KSTAT" "${MEMSCAN:-}" "$HOST_LINES" \
        "${RESET_JSON_F:-}" "$TRACE_STATS" "$INSUM" "$PROBE_KUNIQ" "$MEMDUMP" "${HOST_MOVED:-0}"
elif [ "$HOST_LINES" -gt 0 ]; then
    fp_add_host "$WORKDIR/fingerprint.json" "$HOST_LINES" "${HOST_MOVED:-0}"
fi

python3 "$HERE/record.py" "$WORKDIR" metric \
    phase=Run round="${RUN_N}" event=run_end timer="run_${RUN_N}" \
    exceptions="${EXC}" console_bytes="${CSZ}" console_uniq="${CUNIQ}" \
    origin_far="${FP_ORIGIN_FAR}" origin_elr="${FP_ORIGIN_ELR}" \
    milestone="${MILESTONE}" injected="${INJECTED}" \
    run_failed="$([ "$FP_RUN_FAILED" -eq 1 ] && echo true || echo false)" \
    $([ "$MEMDUMP" = "1" ] && echo "kernel_lines=${FP_KLINES} kernel_uniq=${FP_KUNIQ} kernel_last=${FP_KLAST}") \
    >/dev/null 2>&1 || true

if [ "$INJECTED" = "true" ]; then
    echo "★ 출처 게이트: '${INJECTED_TOKEN}' 문자열이 머신 소스에 있습니다 — 우리가 찍은 것이므로 도달로 인정하지 않습니다." >&2
fi
if [ "$FP_RUN_FAILED" -eq 1 ]; then
    echo "★ 실행 실패: ${FP_RUN_ERROR}" >&2
fi
if [ "$TIMEOUT_BOUND" = "true" ]; then
    PROBE_DETAIL="${CSZ}B → ${PROBE_BYTES}B"
    [ "$PROBE_KUNIQ" != "null" ] && PROBE_DETAIL="$PROBE_DETAIL, 커널 로그 고유 줄 ${FP_KUNIQ} → ${PROBE_KUNIQ}"
    echo "★ 타임아웃 한계: ${TIMEOUT}s 로는 끊겼지만 $((TIMEOUT * PROBE_MULT))s 에서는 콘솔이 더 나왔습니다 (${PROBE_DETAIL}). 펌웨어 정지점이 아니라 실행 시간이 벽입니다." >&2
fi
if [ "$FP_INPUT_STARVED" = "true" ]; then
    echo "★ 입력 굶음: 펌웨어가 콘솔을 ${FP_RX_POLLS} 회 폴링했는데 우리 바이트를 한 번도 읽지 않았습니다 (${INSUM}). 하니스 문제이며 펌웨어 정지점이 아닙니다." >&2
fi
if [ "$MILESTONE" = "none" ] && [ "$FP_PROMPT_SEEN" = "false" ] && [ "$FP_RX_REPORTED" = "true" ] \
   && [ "$FP_RX_SERVED" != "null" ] && [ "$FP_RX_SERVED" -gt 0 ]; then
    echo "· 입력 경로 확인: 펌웨어가 우리 바이트 ${FP_RX_SERVED} 개를 읽었고 그래도 표면이 안 열렸습니다 — 이것은 펌웨어 관측입니다." >&2
fi

echo "console=$OUT"
echo "summary=$SUM"
echo "trace=$LOG"
echo "exceptions=$EXC"
echo "console_size=$CSZ"
echo "console_uniq=$CUNIQ"
echo "far=$FAR"
echo "elr=$ELR"
echo "origin_far=$FP_ORIGIN_FAR"
echo "origin_elr=$FP_ORIGIN_ELR"
echo "origin_esr=$FP_ORIGIN_ESR"
echo "milestone=$MILESTONE"
echo "injected=$INJECTED"
echo "run_failed=$FP_RUN_FAILED"
echo "run_fault=${FP_RUN_FAULT:-0}"
echo "timeout_bound=$TIMEOUT_BOUND"
echo "storage_partition_table=$STORAGE"
echo "input_offered=$FP_INPUT_OFFERED"
echo "prompt_seen=$FP_PROMPT_SEEN"
echo "command_sent=$FP_COMMAND_SENT"
echo "input_starved=$FP_INPUT_STARVED"
echo "rx_reported=$FP_RX_REPORTED"
echo "rx_served=$FP_RX_SERVED"
echo "rx_polls=$FP_RX_POLLS"
echo "waiting_for_input=$FP_WAITING"
echo "host_lines=$HOST_LINES"
[ -f "$HOSTF" ] && echo "host_log=$HOSTF"
[ "$MEMDUMP" = "1" ] && echo "memdump_region=$MEMDUMP_REGION"
if [ "$HOST_CHANNEL" = "1" ]; then
    echo "kernel_log=$KLOG"
    echo "kernel_lines=$FP_KLINES"
    echo "kernel_uniq=$FP_KUNIQ"
    echo "kernel_last_time=$FP_KLAST"
fi
