#!/usr/bin/env bash
# check_env.sh - can this session actually do the work?
#
# Why this exists:
#   The pipeline runs QEMU, ninja and python3 through the agent's Bash tool. If
#   that shell cannot execute the work, every round fails for the same reason
#   and the loop burns its whole round budget without ever being able to make
#   progress. That is a precondition failure, not a goal judgement - so check it
#   once, before the loop, and stop with something actionable.
#
#   This is the one script that is bridge-aware rather than bridge-transparent.
#   The others source wsl_bridge.sh and simply wake up inside WSL; this one has
#   to report on the bridge itself, so it inspects the Windows side first and
#   only then hops over to probe the Linux toolchain.
#
#   환경 매니페스트 비교(C10): plugin 루트의 env_manifest.json 이 요구, ~/.sboot/env.json 이
#   현재다. 옛 QEMU 나 출처 불명의 트리로 진행하지 않게, 어긋나면 problems 에 올리고
#   /sboot-rehost:init 을 안내한다. 비교 자체는 clean_env.sh --status 가 한다 (init 도 같은
#   판정을 쓰므로 한 곳에 둔다). QEMU 를 환경변수로 직접 지정했으면 비교하지 않는다.
#
# Usage:  check_env.sh <workdir> [track]
# Output: JSON on stdout. ok=false means the run must not start.

set -u

# --- Windows side: is there a bridge to cross? -------------------------------
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        if ! command -v wsl.exe >/dev/null 2>&1; then
            printf '{"ok":false,"os":"%s","bridged":false,"problems":[%s],"hint":"%s"}\n' \
                "$(uname -s)" \
                '"이 세션의 셸은 Windows(Git Bash)인데 wsl.exe 가 없어 Linux 로 건너갈 수 없습니다"' \
                'wsl --install -d Ubuntu-22.04 로 WSL 을 설치한 뒤 다시 시도하세요.'
            exit 0
        fi
        ;;
esac

# Hops into WSL when the caller's shell is Windows; no-op on Linux and macOS.
. "$(dirname "$0")/wsl_bridge.sh"

# --- Everything below runs on the Linux side ---------------------------------
WD="${1:-}"
# The unified flow walks one chain, so the environment it needs is the union of
# what the whole chain needs. DTB tooling was a track-2-only requirement; here
# the bootloader assembles a DTB for the kernel it loads, so it is needed
# whenever the target goes past the bootloader.
TARGET="$(printf '%s' "${2:-F2}" | tr '[:lower:]' '[:upper:]')"
HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU_GIVEN="${QEMU:-}"
QEMU="${QEMU:-$HOME/qemu-build/qemu-10.2.2/build/qemu-system-aarch64}"

problems=""
add() { problems="${problems:+$problems|}$1"; }

KERNEL="$(uname -s 2>/dev/null || echo unknown)"
WSL=false
grep -qi microsoft /proc/version 2>/dev/null && WSL=true

case "$KERNEL" in
    Linux|Darwin) ;;
    *) add "알 수 없는 셸 환경($KERNEL)입니다" ;;
esac

if [ -n "$WD" ] && [ ! -d "$WD" ]; then
    add "워크스페이스 경로가 이 셸에서 보이지 않습니다: $WD"
fi

if [ ! -x "$QEMU" ] && ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    add "qemu-system-aarch64 를 찾을 수 없습니다 (QEMU=$QEMU)"
fi
command -v python3 >/dev/null 2>&1 || add "python3 가 없습니다"
command -v ninja   >/dev/null 2>&1 || add "ninja 가 없습니다 (머신 재빌드에 필요)"
python3 -c 'import capstone' >/dev/null 2>&1 || add "python capstone 모듈이 없습니다 (정적 도출에 필요)"
# 언팩 도구. lz4 가 없으면 sboot.bin 을 꺼내지 못하고, simg2img 가 없으면 sparse 이미지를
# raw 로 풀 수 없어 build_lu.py 가 매체 합성 단계에서 정지한다.
command -v lz4 >/dev/null 2>&1 || command -v unlz4 >/dev/null 2>&1 \
    || add "lz4 가 없습니다 (BL 패키지의 .lz4 해제에 필요)"
if [ "$TARGET" != "F1" ]; then
    command -v simg2img >/dev/null 2>&1 \
        || add "simg2img 가 없습니다 (AP 의 sparse 이미지를 raw 로 푸는 데 필요 — 목표 $TARGET 은 매체를 읽습니다)"
fi
if [ "$TARGET" != "F1" ]; then
    command -v fdtdump >/dev/null 2>&1 || command -v dtc >/dev/null 2>&1 \
        || add "dtc/fdtdump 가 없습니다 (DTB 파싱에 필요 — 목표 $TARGET 은 커널 구간을 포함합니다)"
fi

# --- 환경 매니페스트 비교 (C10) ----------------------------------------------
ENV_STATUS=""
if [ -n "$QEMU_GIVEN" ]; then
    ENV_STATUS='{"status":"skipped","reasons":["QEMU 환경변수로 바이너리를 직접 지정해 환경 매니페스트 비교를 건너뜁니다"]}'
elif [ -f "$HERE/clean_env.sh" ]; then
    ENV_STATUS="$(bash "$HERE/clean_env.sh" --status 2>/dev/null)" || ENV_STATUS=""
fi

emit_with_python() {
    python3 - "$KERNEL" "$problems" "$WSL" "$ENV_STATUS" <<'PY'
import json, sys
kernel, raw, wsl, env_raw = sys.argv[1], sys.argv[2], sys.argv[3] == "true", sys.argv[4]
problems = [p for p in raw.split("|") if p]
manifest_problem = False
try:
    env = json.loads(env_raw) if env_raw else None
except ValueError:
    env = None
if env is not None and env.get("status") not in ("ok", "skipped"):
    manifest_problem = True
    status = env.get("status")
    why = "; ".join(env.get("reasons") or []) or "환경 매니페스트와 어긋납니다"
    label = {"missing": "이 플러그인이 만든 QEMU 환경이 없습니다",
             "unmarked": "QEMU 트리가 이 플러그인이 만든 것이 아닙니다(표지 없음)",
             "stale": "QEMU 환경이 요구보다 낡았습니다",
             "incomplete": "QEMU 빌드가 끝나지 않았습니다"}.get(status, "환경 매니페스트를 확인하지 못했습니다")
    problems.append("%s — %s" % (label, why))
if env is not None:
    for o in env.get("pip_outdated") or []:
        manifest_problem = True
        if o.get("installed"):
            problems.append("python 모듈 %s %s 가 최소 버전 %s 에 못 미칩니다" % (o["name"], o["installed"], o["min"]))
        elif not any(o["name"] in p for p in problems):   # capstone 은 위에서 이미 점검했다
            problems.append("python 모듈 %s 가 없습니다 (필요 >= %s)" % (o["name"], o["min"]))
hint = ""
if problems:
    hint = ("필요한 도구는 /sboot-rehost:init 이 설치합니다. "
            "직접 설치하려면 scripts/setup_env.sh 를 참고하세요.")
if manifest_problem:
    hint += (" 환경 매니페스트 불일치는 /sboot-rehost:init 을 실행하세요"
             " (QEMU 를 다시 만들면 약 18 분).")
out = {
    "ok": not problems,
    "os": kernel,
    "wsl": wsl,
    "problems": problems,
    "hint": hint,
}
if env is not None:
    out["env_manifest"] = {k: env.get(k) for k in
                           ("status", "reasons", "required", "current", "pip_outdated") if k in env}
print(json.dumps(out, ensure_ascii=False))
PY
}

if ! emit_with_python 2>/dev/null; then
    printf '{"ok":false,"os":"%s","wsl":%s,"problems":["python3 가 없어 환경 점검조차 불가"],"hint":"WSL 에 python3 를 설치하세요"}\n' \
        "$KERNEL" "$WSL"
fi
