#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# make_export.sh — 완성된 워크스페이스 → "빌드 없이 바로 실행" 키트로 조립.
# /sboot-rehost:export 스킬이 호출. 기계적 복사 + turnkey run/setup/build/.gitignore 생성.
# 문서(docs/*.md narrative)와 완료 확인·통지는 스킬이 담당.
#
# 사용법 (env 로 파라미터):
#   WS=<workspace> DEST=<dest dir> QEMU=<prebuilt qemu> MACHINE=<machine name> \
#   [CPU=<cpu 형>] [SMP=8] [MEM=2G] [KCMDLINE="..."] [INPUT_CMD=help] \
#   [RUN_TIMEOUT_S=<초>] \
#   [EUFS_LU_IMAGE=~/rehost/<id>/disk.img] [EUFS_LBS=4096] \
#   [SURFACE=shell|none] [FAMILY=exynos|mediatek|generic] \
#   [CONTAINER=<부트로더 컨테이너 경로>] [BUNDLE_FIRMWARE=1|0] \
#   bash make_export.sh
#
#   MEM        run_full.sh 의 기본값(2G)과 같다. 회차에서 돈 것과 같은 조건으로 키트가 돌아야 한다
#   CPU        비우면 -cpu 를 넘기지 않는다. 회차(run_full.sh)도 넘기지 않고 머신의 기본 CPU 를 쓴다.
#              머신이 허용하지 않는 형을 주면 QEMU 가 거부한다. 06_machine 에 handoff_tick 이 있는
#              혼합 아키텍처 머신은 두 CPU 를 스스로 만들므로 값을 줘도 넘기지 않는다
#              (기본값은 없다. 예전의 cortex-a76 은 한 기기의 값이라 다른 기기에서 QEMU 가 거부했다.)
#   memdump_plan.json 이 있으면 run.sh 는 회차(run_full.sh)처럼 REHOST_MEMDUMP_REGION=<base>:<size> 를
#              QEMU 환경에 내보내고(머신의 쓰기 보호), 작업 폴더에 kernel_task_regex.txt 가 있으면 키트에
#              넣어 KERNEL_TASK_REGEX 로 넘긴다 (명시한 환경변수가 우선)
#   RUN_TIMEOUT_S  run.sh 의 시간 한도(초)이고 메모리 덤프 관측기의 마감도 같다. 비우면 워크스페이스
#              input_summary.json 의 timeout_s (마지막 회차에서 하니스가 쓴 값), 그것도 없으면
#              run_full.sh 의 기본값 200. run.sh 를 돌릴 때 같은 이름으로 덮을 수 있다. 20 초 같은
#              짧은 한도는 체인이 커널까지 가기 전에 키트를 끝내 kernel_alive 를 관측할 수 없다
#   SURFACE    none 이면 run.sh 는 명령을 치지 않는다 (표면 없는 부트로더). 기본 shell
#   FAMILY     scripts/build.sh 가 patch_qemu_core.py 에 넘길 계열 (mediatek 이면 cpu.c 패치)
#   BUNDLE_FIRMWARE=0  펌웨어를 키트에 넣지 않는다 (저작권, 용량). firmware/ 에는 README.txt 와
#              SHA256SUMS 만 두고, run.sh 는 사용자가 두는 파일이 기록된 해시와 같은지 확인한다.
#              기본 1 (이전 동작)
set -e
: "${WS:?WS 워크스페이스 필요}"; : "${DEST:?DEST 필요}"
: "${MACHINE:?MACHINE 필요}"
CPU="${CPU:-}"; SMP="${SMP:-8}"; MEM="${MEM:-2G}"; INPUT_CMD="${INPUT_CMD:-help}"
SURFACE="${SURFACE:-shell}"; FAMILY="${FAMILY:-}"; BUNDLE_FIRMWARE="${BUNDLE_FIRMWARE:-1}"

mkdir -p "$DEST"/{bin,firmware,machine,scripts,evidence,docs}

# ── 프리빌트 QEMU (빌드 없이 실행의 핵심) ──
if [ -n "${QEMU:-}" ] && [ -x "$QEMU" ]; then
  cp "$QEMU" "$DEST/bin/qemu-system-aarch64"; echo "  bin/qemu-system-aarch64 (prebuilt)"
else
  echo "  ★ 프리빌트 QEMU 없음 — 받는 사람이 scripts/build.sh 로 빌드해야 함"
fi

# ── 실행 분석 (시간·비용이 어디로 갔는지) ──
# 측정치를 그대로 넘기면 받는 사람이 jsonl 을 직접 읽어야 한다. 어느 정지점이 회차를
# 가장 많이 먹었고 어느 변경이 관측을 못 움직였는지는 기록에서 계산되는 값이므로,
# 내보내기 시점에 한 번 계산해 문서로 넣는다.
python3 "$(dirname "$0")/analyze_run.py" "$WS" >/dev/null 2>&1 \
  || echo "  ★ 실행 분석 생성 실패 — jsonl 기록을 확인하세요"

# ── evidence (기록·증거) ──
# 사람이 읽는 기록(JOURNAL/PROGRESS/VERIFICATION/ANALYSIS) + 기계가 읽는 측정치(*.jsonl) 둘 다.
for f in VERIFICATION.md ANALYSIS.md PROGRESS.md JOURNAL.md STATIC.md STUBS.md INPUT.md RESUME.md \
         metrics.jsonl rounds.jsonl blockers.jsonl verdict_script.json analysis.json \
         fingerprint.json observation.json; do
  [ -f "$WS/$f" ] && cp "$WS/$f" "$DEST/evidence/"
done
cp "$WS"/07_logs/console_*.txt "$WS"/07_logs/*.summary.txt "$DEST/evidence/" 2>/dev/null || true
# 관측 채널의 나머지: 메모리 덤프로 복원한 커널 로그(게스트 증거), QEMU 호스트 줄(증거 아님),
# 덤프 통계, 게스트 리셋 신호, 음성 시험 콘솔. 커널 로그가 UART 가 아니라 여기로만 나오는
# 펌웨어는 이 파일이 없으면 kernel_alive 를 키트에서 확인할 수 없다.
cp "$WS"/07_logs/kernel_*.log "$WS"/07_logs/host_*.txt "$WS"/07_logs/memdump_*.json \
   "$WS"/07_logs/reset_*.json "$WS"/07_logs/avb_negative.txt "$DEST/evidence/" 2>/dev/null || true
# What the harness typed, and what the firmware did with it. Without these the
# kit shows the console but not whether the surface was reached by real input.
cp "$WS"/07_logs/input_*.txt "$WS"/input_summary.json "$DEST/evidence/" 2>/dev/null || true

# 부트로더 컨테이너 + 합성 매체. 커널은 부트로더가 매체에서 읽으므로 따로 넘기지 않는다.
# 컨테이너 이름은 펌웨어마다 다르다 (sboot.bin, preloader.img ...). run.sh 가 그 이름을 쓴다.
P="$(dirname "$0")"
CONTAINER_SRC="${CONTAINER:-}"
if [ -z "$CONTAINER_SRC" ]; then
  for c in "$WS"/03_bootloader/sboot.bin "$WS"/03_bootloader/*.bin "$WS"/03_bootloader/*.img \
           "$WS"/02_unpacked/sboot.bin; do
    [ -f "$c" ] && { CONTAINER_SRC="$c"; break; }
  done
fi
CONTAINER_NAME="sboot.bin"; [ -n "$CONTAINER_SRC" ] && CONTAINER_NAME="$(basename "$CONTAINER_SRC")"
MEDIUM_SRC="${EUFS_LU_IMAGE:-$WS/fw/lu0.img}"
[ -s "$MEDIUM_SRC" ] || MEDIUM_SRC=""

sha256_of() {   # 한 파일의 SHA-256 (Linux: sha256sum, macOS: shasum)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

if [ "$BUNDLE_FIRMWARE" = "0" ]; then
  # 펌웨어는 저작권과 용량 때문에 키트에 넣지 않는다. 대신 어떤 바이트로 돌렸는지는 남긴다 —
  # 받는 사람이 자기 펌웨어에서 만든 파일이 같은 입력인지 run.sh 가 해시로 확인한다.
  : > "$DEST/firmware/SHA256SUMS"
  [ -n "$CONTAINER_SRC" ] && echo "$(sha256_of "$CONTAINER_SRC")  $CONTAINER_NAME" >> "$DEST/firmware/SHA256SUMS" \
    || echo "  경고: 부트로더 컨테이너를 찾지 못했습니다 (SHA256SUMS 에 없음)"
  [ -n "$MEDIUM_SRC" ] && echo "$(sha256_of "$MEDIUM_SRC")  lu0.img" >> "$DEST/firmware/SHA256SUMS" \
    || echo "  경고: 합성 매체(lu0.img) 없음 (SHA256SUMS 에 없음)"
  cat > "$DEST/firmware/README.txt" <<README
이 키트는 펌웨어를 포함하지 않는다 (저작권, 용량). run.sh 를 돌리려면 이 폴더에 둘을 둔다.

  $CONTAINER_NAME   부트로더 컨테이너. 본인이 받은 펌웨어 패키지에서 같은 이미지를 꺼낸다.
  lu0.img           합성 부팅 매체. 만드는 방법은 아래.

SHA256SUMS 는 이 키트가 돌렸을 때의 두 파일 해시다. run.sh 는 시작 전에 그것과 대조하고,
다르면 멈춘다 (다른 입력으로 돌려 놓고 같은 결과를 재현했다고 말하지 않기 위해서다).
의도적으로 다른 파일을 쓰려면 SKIP_SUM_CHECK=1 bash run.sh — 그때 결과는 이 키트의 기록과
같다고 주장할 수 없다.

lu0.img 만드는 법
  1) 키트 루트의 lu_manifest.json 이 파티션 이름과 출처 종류(kind)를 적는다.
     'source' 경로는 작업 폴더 기준이므로, 본인 펌웨어에서 같은 파티션 이미지를 풀어
     그 경로에 둔다.
  2) python3 scripts/build_lu.py <그 작업 폴더>
     결과는 <작업 폴더>/fw/lu0.img 와 lu_provenance.json (이 키트 루트에도 사본이 있다).
  펌웨어 빌드가 다르면 파티션 내용이 달라 해시가 맞지 않는다.
README
  cp "$P/build_lu.py" "$DEST/scripts/" 2>/dev/null || true
else
  # 이전 동작: 컨테이너와 매체를 키트에 넣는다.
  cp "$WS"/03_bootloader/*.bin "$DEST/firmware/" 2>/dev/null \
    || cp "$WS"/02_unpacked/sboot.bin "$DEST/firmware/" 2>/dev/null \
    || { [ -n "$CONTAINER_SRC" ] && cp "$CONTAINER_SRC" "$DEST/firmware/" 2>/dev/null; } \
    || echo "  경고: 부트로더 컨테이너를 찾지 못했습니다"
  [ -n "$CONTAINER_SRC" ] && [ ! -f "$DEST/firmware/$CONTAINER_NAME" ] && { cp "$CONTAINER_SRC" "$DEST/firmware/" 2>/dev/null || true; }
  if [ -n "$MEDIUM_SRC" ]; then cp "$MEDIUM_SRC" "$DEST/firmware/lu0.img"
  else echo "  경고: 합성 매체(lu0.img) 없음"; fi
fi
cp "$WS"/stage_map.json "$WS"/lu_manifest.json "$DEST/" 2>/dev/null || true
cp "$WS"/fw/lu_provenance.json "$WS"/memdump_plan.json "$DEST/" 2>/dev/null || true
# 도출한 것들: 칸 → 스테이지 → 진입 PC, 펌웨어 보안 상태 문자열, 커널 패치 사이트.
# 받는 사람이 검증 보고와 칸 판정을 다시 낼 때 필요한 근거다 (없으면 없는 대로).
cp "$WS"/stage_rungs.json "$WS"/status_tokens.txt "$WS"/kernel_patch_sites.json "$DEST/" 2>/dev/null || true
cp "$WS"/06_machine/machine_full.c "$WS"/06_machine/*hci*.c "$WS"/06_machine/*hci*.h "$DEST/machine/" 2>/dev/null || true
cp "$WS"/06_machine/*.md "$DEST/machine/" 2>/dev/null || true   # bypasses.md 등
  # The kit must reach the surface the same way the run did: the autoboot gate
  # is one-shot and wants a run of a derived byte, so the harness and the derived
  # plan travel with it. A kit that only pipes the command in cannot pass that
  # gate, and then it does not reproduce what it claims to.
  cp "$P/uart_harness.py" "$DEST/scripts/" 2>/dev/null || true
  cp "$P/patch_qemu_core.py" "$DEST/scripts/" 2>/dev/null || true   # build.sh 가 쓴다
  cp "$WS/input_plan.json" "$WS/milestone_tokens.txt" "$DEST/scripts/" 2>/dev/null || true
  # 메모리 덤프 채널을 쓰는 펌웨어는 UART 만으로는 커널 로그가 안 보인다. 계획이 있으면
  # 같은 관측기를 키트에 넣고 run.sh 가 회차와 같은 방식으로 돌린다.
  MEMDUMP_KIT=0
  if [ -s "$WS/memdump_plan.json" ]; then
    MEMDUMP_KIT=1
    cp "$WS/memdump_plan.json" "$DEST/scripts/" 2>/dev/null || true
    cp "$P/memdump_observe.py" "$DEST/scripts/" 2>/dev/null || true
    # 커널 줄의 태스크 접두 형식은 대상 커널의 성질이라 분석가가 작업 폴더에 둔다
    # (kernel_task_regex.txt). 키트가 그 파일을 갖고 가야 회차와 같은 형식으로 커널 로그를 읽는다.
    cp "$WS/kernel_task_regex.txt" "$DEST/scripts/" 2>/dev/null || true
  fi
  PROMPT_TOKEN=""
  [ -s "$WS/milestone_tokens.txt" ] && PROMPT_TOKEN=$(awk -F'\t' -v s="$SURFACE" 'NF>1 && $1==s {print $2; exit}' "$WS/milestone_tokens.txt")
  KENTRY_TOKEN=""
  [ -s "$WS/milestone_tokens.txt" ] && KENTRY_TOKEN=$(awk -F'\t' '{ gsub(/\r/, "") } NF>1 && $1=="kernel_entry" && ($3=="" || $3=="uart") {print $2; exit}' "$WS/milestone_tokens.txt")
  CHECK_SUMS=0; [ "$BUNDLE_FIRMWARE" = "0" ] && CHECK_SUMS=1
  # 키트는 회차가 돈 조건으로 돌아야 한다. 조건이 다르면 같은 펌웨어가 다른 칸에서 멈춘다.
  #  - 시간 한도: 회차가 쓴 값 (input_summary.json 의 timeout_s), 없으면 run_full.sh 의 기본값 200.
  #    체인이 커널까지 가는 데 수십~백수십 초가 걸리므로 20 초로는 kernel_alive 를 못 본다.
  #  - 혼합 아키텍처 머신(handoff_tick)은 run_full.sh 가 -accel tcg,thread=single 로 돌린다.
  #    다중 스레드 TCG 에서 핸드오프 감시기가 안전한지는 알려지지 않아서다.
  #  - -cpu 는 run_full.sh 가 주지 않는다. 머신이 허용하는 형이 아니면 QEMU 가 거부하고, 혼합
  #    머신은 허용하는 형이 둘이다. CPU 를 명시하고 혼합 머신이 아닐 때만 넘긴다.
  KIT_TIMEOUT_S="${RUN_TIMEOUT_S:-}"
  if [ -z "$KIT_TIMEOUT_S" ] && [ -s "$WS/input_summary.json" ]; then
    KIT_TIMEOUT_S=$(python3 -c 'import json,sys
try: print(int(json.load(open(sys.argv[1])).get("timeout_s") or 0))
except Exception: print(0)' "$WS/input_summary.json" 2>/dev/null) || KIT_TIMEOUT_S=""
  fi
  case "$KIT_TIMEOUT_S" in ''|*[!0-9]*|0) KIT_TIMEOUT_S=200 ;; esac
  ACCEL_ARGS=""; CPU_ARGS=""
  if grep -qs 'handoff_tick' "$WS"/06_machine/*.c 2>/dev/null; then
    ACCEL_ARGS="-accel tcg,thread=single"
  elif [ -n "$CPU" ]; then
    CPU_ARGS="-cpu $CPU"
  fi
  if [ "$SURFACE" = "shell" ]; then
    RUN_TITLE="부트로더 표면 도달 + '$INPUT_CMD'"; RUN_CMD_ARGS="--cmd '$INPUT_CMD'"
  else
    RUN_TITLE="표면 없음 ($SURFACE) — 입력 없이 끝까지"; RUN_CMD_ARGS=""
  fi
  cat > "$DEST/run.sh" <<RUN
#!/usr/bin/env bash
# turnkey — 빌드 없이 실행 (WSL2/Linux x86_64). bash run.sh
set +e; DIR="\$(cd "\$(dirname "\$0")" && pwd)"
# 시간 한도(초). 기본은 회차가 쓴 값이고, RUN_TIMEOUT_S=<초> bash run.sh 로 덮을 수 있다.
RUN_TIMEOUT_S="\${RUN_TIMEOUT_S:-$KIT_TIMEOUT_S}"
QEMU="\$DIR/bin/qemu-system-aarch64"; SB="\$DIR/firmware/$CONTAINER_NAME"; MEDIUM="\$DIR/firmware/lu0.img"
[ -x "\$QEMU" ] || { echo "★ bin/qemu 없음 — bash scripts/build.sh 로 빌드"; exit 1; }
[ -f "\$SB" ]   || { echo "★ firmware/$CONTAINER_NAME 없음 (firmware/README.txt 참조)"; exit 1; }
"\$QEMU" --version >/dev/null 2>&1 || { echo "★ 공유 라이브러리 부족 — bash setup.sh 먼저"; exit 1; }
# 이 키트가 펌웨어를 포함하지 않으면, 사용자가 둔 파일이 기록된 입력과 같은지부터 확인한다.
if [ "$CHECK_SUMS" = "1" ] && [ -z "\${SKIP_SUM_CHECK:-}" ]; then
  [ -f "\$MEDIUM" ] || { echo "★ firmware/lu0.img 없음 (firmware/README.txt 참조)"; exit 1; }
  if command -v sha256sum >/dev/null 2>&1; then SUMCMD="sha256sum -c"; else SUMCMD="shasum -a 256 -c"; fi
  (cd "\$DIR/firmware" && \$SUMCMD SHA256SUMS >/dev/null 2>&1) || {
    echo "★ firmware/ 의 파일이 이 키트가 기록한 입력(SHA256SUMS)과 다릅니다 — 같은 재현이 아닙니다"
    echo "  의도한 것이면 SKIP_SUM_CHECK=1 bash run.sh (그 결과는 키트의 기록과 같다고 말할 수 없음)"; exit 1; }
fi
# 합성 매체. 통합 체인은 부트로더가 매체에서 다음 단계를 읽으므로 없으면 그 칸은 도달 불가다.
# snapshot=on: 부트로더가 PARAM 등에 실제로 쓰므로, 켜지 않으면 실행마다 디스크 상태가 쌓인다.
MEDIUM_ARGS=()
if [ -s "\$MEDIUM" ]; then MEDIUM_ARGS=(-drive "file=\$MEDIUM,if=none,format=raw,id=lu0,snapshot=on")
else echo "경고: firmware/lu0.img 없음 — 매체를 읽는 칸은 도달 불가"; fi
echo "== $MACHINE — $RUN_TITLE =="
# 입력은 QEMU 밖에서 넣는다. 머신이 자기 RX 를 채우면 스스로에게 명령을 준 것이라
# 도달로 인정되지 않는다(정직성 §7). 보낸 바이트는 전부 out/input.txt 에 남는다.
mkdir -p "\$DIR/out"
MON_ARGS=(-monitor none); OBS_PID=""
if [ "$MEMDUMP_KIT" = "1" ] && [ -f "\$DIR/scripts/memdump_observe.py" ]; then
  # 머신은 호스트가 읽는 영역에 쓰지 않아야 하고, 그 영역은 계획만 안다. run_full.sh 가 회차에서
  # 내보내는 것과 같은 값(REHOST_MEMDUMP_REGION=<base>:<size>)을 같은 도구로 만든다. 계획이 있는데
  # 값을 만들지 못하면 머신의 쓰기 보호가 꺼진 채 도는 것이므로 그 사실을 알린다.
  if REHOST_REGION="\$(python3 "\$DIR/scripts/memdump_observe.py" region "\$DIR/scripts/memdump_plan.json" 2>/dev/null)" \\
     && [ -n "\$REHOST_REGION" ]; then
    export REHOST_MEMDUMP_REGION="\$REHOST_REGION"
  else
    unset REHOST_MEMDUMP_REGION
    echo "경고: memdump_plan.json 에서 영역을 읽지 못해 머신의 쓰기 보호 없이 돕니다 (회차와 다름)"
  fi
  # 커널 태스크 접두 형식: 명시한 KERNEL_TASK_REGEX 가 우선이고, 없으면 kernel_task_regex.txt 의 첫 줄.
  # 올바른 정규식이 아니면 쓰지 않고 기본 형식으로 판정한다 (회차의 run_full.sh 와 같다).
  if [ -z "\${KERNEL_TASK_REGEX:-}" ] && [ -s "\$DIR/scripts/kernel_task_regex.txt" ]; then
    if TASK_RX="\$(python3 "\$DIR/scripts/memdump_observe.py" task-regex --file "\$DIR/scripts/kernel_task_regex.txt" 2>/dev/null)"; then
      export KERNEL_TASK_REGEX="\$TASK_RX"
    else
      echo "경고: kernel_task_regex.txt 에 올바른 정규식이 없어 기본 형식으로 판정합니다"
    fi
  fi
  # 커널 로그가 UART 가 아니라 게스트 RAM 의 링으로 나가는 펌웨어: 호스트가 모니터로 그 링을 읽는다.
  MON_SOCK="\$(mktemp -u "\${TMPDIR:-/tmp}/sboot_mon.XXXXXX")"
  MON_ARGS=(-monitor "unix:\$MON_SOCK,server,nowait")
  python3 "\$DIR/scripts/memdump_observe.py" watch --plan "\$DIR/scripts/memdump_plan.json" \\
      --socket "\$MON_SOCK" --snap-dir "\$DIR/out/memdump" --out "\$DIR/out/kernel.log" \\
      --stats "\$DIR/out/memdump.json" --console "\$DIR/out/console.txt" --deadline "\$RUN_TIMEOUT_S" \\
      ${KENTRY_TOKEN:+--start-token '$KENTRY_TOKEN'} &
  OBS_PID=\$!
else
  # 계획이 없으면 채널은 꺼져 있고, 호출자의 환경에 남은 값이 머신을 막지 않게 한다 (run_full.sh 와 같다).
  unset REHOST_MEMDUMP_REGION
fi
python3 "\$DIR/scripts/uart_harness.py" \\
  --console "\$DIR/out/console.txt" --input-log "\$DIR/out/input.txt" \\
  --summary "\$DIR/out/input_summary.json" \\
  --plan "\$DIR/scripts/input_plan.json" \\
  --timeout "\$RUN_TIMEOUT_S" $RUN_CMD_ARGS --surface $SURFACE \\
  ${PROMPT_TOKEN:+--prompt-token '$PROMPT_TOKEN'} \\
  -- "\$QEMU" -M $MACHINE $CPU_ARGS -m $MEM -kernel "\$SB" \\
     -display none -serial stdio $ACCEL_ARGS "\${MON_ARGS[@]}" \${MEDIUM_ARGS[@]+"\${MEDIUM_ARGS[@]}"}
[ -n "\$OBS_PID" ] && { kill -TERM "\$OBS_PID" 2>/dev/null; wait "\$OBS_PID" 2>/dev/null; }
echo
echo "-- 콘솔 --"; tail -40 "\$DIR/out/console.txt"
[ -s "\$DIR/out/kernel.log" ] && { echo "-- 커널 로그 (메모리 덤프) --"; tail -40 "\$DIR/out/kernel.log"; }
echo "-- 입력 경로 --"; cat "\$DIR/out/input_summary.json"
RUN

# ── 공용: setup.sh (공유 라이브러리) / build.sh (프리빌트 없을 때 재빌드) / .gitignore ──
cat > "$DEST/setup.sh" <<'SETUP'
#!/usr/bin/env bash
# 최초 1회 — 포함된 QEMU 실행에 필요한 공유 라이브러리만 (빌드 아님).
sudo apt-get update -qq || true
sudo apt-get install -y libglib2.0-0 libpixman-1-0 libslirp0 2>/dev/null || true
echo "setup: OK (누락 상세: ldd bin/qemu-system-aarch64 | grep 'not found')"
SETUP

# 계열별 코어 패치 세트 (patch_qemu_core.py --family). 기본은 이전 동작(exynos = SMC 훅)이다.
# mediatek 은 cpu.c 의 aarch64=false 거부 조건을 푸는 패치 하나이고, 이것 없이는 TCG 가
# AArch32 CPU 를 만들지 못한다.
case "$FAMILY" in
  mediatek) PATCH_FAMILY=mediatek ;;
  *)        PATCH_FAMILY=exynos ;;
esac
cat > "$DEST/scripts/build.sh" <<'BUILD'
#!/usr/bin/env bash
# 프리빌트 bin/ 이 없을 때(예: git 경로로 받음) QEMU 10.2.2 에 machine 통합 후 재빌드.
set -e; DIR="$(cd "$(dirname "$0")/.." && pwd)"; Q="$HOME/qemu-build/qemu-10.2.2"
[ -d "$Q" ] || { echo "QEMU 10.2.2 소스 필요: ~/qemu-build/qemu-10.2.2 (HOW-TO-RUN 참조)"; exit 1; }
cp "$DIR"/machine/*.c "$DIR"/machine/*.h "$Q/hw/arm/" 2>/dev/null || cp "$DIR"/machine/*.c "$Q/hw/arm/"
grep -q "$(ls "$DIR"/machine/*.c | head -1 | xargs basename)" "$Q/hw/arm/meson.build" || \
  printf "arm_ss.add(files(%s))\n" "$(cd "$DIR/machine" && ls *.c | sed "s/.*/'&'/" | paste -sd, -)" >> "$Q/hw/arm/meson.build"
# 이 키트의 계열 패치 세트. 실패하면 멈춘다 (패치 없는 QEMU 로 빌드하면 머신이 만들어지지 않는다).
if [ -f "$DIR"/scripts/patch_qemu_core.py ]; then
  QEMU_SRC="$Q" python3 "$DIR"/scripts/patch_qemu_core.py --family __PATCH_FAMILY__
fi
cd "$Q/build" && ninja qemu-system-aarch64
cp "$Q/build/qemu-system-aarch64" "$DIR/bin/"; echo "build: bin/qemu-system-aarch64 갱신"
BUILD
# 계열은 내보낼 때 정해진다. 표식을 치환한다 (sed -i 는 GNU/BSD 가 달라 임시 파일을 거친다).
sed "s/__PATCH_FAMILY__/$PATCH_FAMILY/" "$DEST/scripts/build.sh" > "$DEST/scripts/build.sh.tmp" \
  && mv "$DEST/scripts/build.sh.tmp" "$DEST/scripts/build.sh"

cat > "$DEST/.gitignore" <<'GI'
# 이 키트의 대용량/저작권 파일 — git 커밋 금지. 폴더 직접 공유(zip/복사) 시엔 그대로 실행됨.
bin/
firmware/
*.log
*.img
GI

chmod +x "$DEST/run.sh" "$DEST/setup.sh" "$DEST/scripts/build.sh" 2>/dev/null || true
echo "make_export: DONE -> $DEST"
