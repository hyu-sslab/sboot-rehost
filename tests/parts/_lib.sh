#!/usr/bin/env bash
# tests/parts/_lib.sh - 영역별 시험 파일의 공용 도우미.
#
# smoke.sh 가 이 폴더의 *.sh 를 source 하면 ok/bad/chk/hdr/new_ws 가 이미 정의되어 있어
# 그대로 쓴다. 단독으로 실행하면(bash tests/parts/<이름>.sh) 여기서 같은 함수를 정의하고
# 끝에 자기 요약을 출력한다. 병렬로 작업하는 사람이 서로의 미완성 수정에 영향받지 않고
# 자기 영역만 시험할 수 있게 하려는 장치다.
#
# 각 부분 파일의 형식:
#     #!/usr/bin/env bash
#     . "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
#     hdr "영역 이름"
#     ... chk "설명" "$실제" "$기대" ...
#     parts_finish
if ! declare -F chk >/dev/null 2>&1; then
  REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  S="$REPO/scripts"; export REPO
  ROOT="${ROOT:-$(mktemp -d)}"
  PASS=0; FAIL=0; PARTS_STANDALONE=1
  ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
  chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대=$3  실제=$2"; fi; }
  hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
  new_ws() {   # $1 = name -> echoes workdir
    local wd="$ROOT/$1"; mkdir -p "$wd/06_machine" "$wd/07_logs" "$wd/fw"
    printf '### 우회1\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$wd/06_machine/bypasses.md"
    echo "$wd"
  }
  BIN="$ROOT/bin"; mkdir -p "$BIN"
  if ! command -v timeout >/dev/null 2>&1; then
    printf '#!/usr/bin/env bash\nshift; exec "$@"\n' > "$BIN/timeout"; chmod +x "$BIN/timeout"
  fi
  export PATH="$BIN:$PATH"
  # run_full.sh 는 TRACE_DIR 이 없으면 ~/rehost/_traces 에 쓰고, 최근 TRACE_KEEP 개를 넘는 옛
  # run_*.log · memdump_* 를 지운다. 단독 실행은 smoke.sh 가 export 하던 값이 없으므로 여기서
  # 시험 폴더로 돌린다. 호출자의 환경에서 받은 값은 쓰지 않는다 (smoke.sh 가 하는 것과 같다).
  export TRACE_DIR="$ROOT/_traces"
fi

# 어떤 경로로 로드되든(단독 실행 · smoke.sh 의 source) 시험이 사용자의 실제 트레이스 폴더에
# 쓰게 되면 시작 전에 거절한다. 값이 없으면 run_full.sh 가 ~/rehost/_traces 로 가므로, 부모가
# ROOT 를 정해 두었다면 그 안으로 돌리고 아니면 같은 이유로 거절한다.
parts_trace_guard() {
  [ -n "${HOME:-}" ] || return 0
  if [ -z "${TRACE_DIR:-}" ] && [ -n "${ROOT:-}" ]; then export TRACE_DIR="$ROOT/_traces"; fi
  local td="${TRACE_DIR:-$HOME/rehost/_traces}" real_td real_home
  real_td=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$td" 2>/dev/null) || real_td="$td"
  real_home=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$HOME/rehost" 2>/dev/null) || real_home="$HOME/rehost"
  case "$real_td" in
    "$real_home"|"$real_home"/*)
      printf '\033[31m거절\033[0m 시험의 TRACE_DIR(%s)이 실제 작업 폴더(%s) 안이다 - 옛 트레이스가 지워진다.\n' "$td" "$HOME/rehost" >&2
      printf '       TRACE_DIR 을 시험용 임시 폴더로 지정하거나 비워서 다시 실행한다.\n' >&2
      exit 2 ;;
  esac
}
parts_trace_guard

parts_finish() {   # 단독 실행일 때만 요약과 종료코드를 낸다
  [ -n "${PARTS_STANDALONE:-}" ] || return 0
  printf '\n\033[1m── 결과: %d 통과 / %d 실패 ──\033[0m\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
