#!/usr/bin/env bash
# End-to-end smoke test of the sboot-rehost deterministic layer.
# Substitutes a fake QEMU so the whole run/fingerprint/gate/stop/verify chain
# can be exercised without real firmware.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO/scripts"
export REPO
ROOT="$(mktemp -d)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n'  "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대=$3  실제=$2"; fi; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# --- shims: fake qemu + timeout (macOS lacks GNU timeout) --------------------
BIN="$ROOT/bin"; mkdir -p "$BIN"
if ! command -v timeout >/dev/null 2>&1; then
  cat > "$BIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
  chmod +x "$BIN/timeout"
fi
export PATH="$BIN:$PATH"

make_qemu() {   # $1 = console payload file, $2 = trace payload file
  cat > "$BIN/fake-qemu" <<EOF
#!/usr/bin/env bash
OUT=""; LOG=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -serial) case "\$2" in file:*) OUT="\${2#file:}";; esac; shift 2;;
    -D) LOG="\$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "\$LOG" ] && cat "$2" > "\$LOG"
# -serial stdio (track 1, harness-driven) puts the console on stdout;
# -serial file: (track 2) still writes the file directly.
if [ -n "\$OUT" ]; then cat "$1" > "\$OUT"; else cat "$1"; fi
EOF
  chmod +x "$BIN/fake-qemu"
}

new_ws() {      # $1 = name -> echoes workdir
  local wd="$ROOT/$1"; mkdir -p "$wd/06_machine" "$wd/07_logs" "$wd/fw"
  printf '### 우회1\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$wd/06_machine/bypasses.md"
  echo "$wd"
}

export TRACE_DIR="$ROOT/_traces"

# =============================================================================
hdr "1. 트랙 1 — 정상 도달 (셸)"
WD=$(new_ws t1ok)
printf 'static void w(void){ qemu_chr_fe_write_all(s->chr,b,1); }\n' > "$WD/06_machine/machine.c"
printf 'S-BOOT # help\nFollowing commands are supported\n' > "$ROOT/con1.txt"
printf 'no exceptions here\n0x9021f3dc: stp x29,x30\n' > "$ROOT/trc1.txt"
make_qemu "$ROOT/con1.txt" "$ROOT/trc1.txt"
printf 'S-BOOT # \x00Following commands are supported\x00help\x00' > "$WD/bl3.bin"
printf '| shell_func | 0x9021f3dc | prompt xref |\n' > "$WD/STATIC.md"
# 표면 칸의 관측 문자열은 도출값이다 (static-analyzer 가 쓴 파일). run_full.sh 에 내장 배너는 없다.
printf 'shell\tS-BOOT # \n' > "$WD/milestone_tokens.txt"

QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD" sboot-test 1 shell "shell" "$WD/bl3.bin" help > "$ROOT/obs1.json" 2>/dev/null
python3 -c "import json;json.load(open('$ROOT/obs1.json'))" 2>/dev/null && ok "observation.json 이 유효한 JSON" || bad "observation.json 파싱"
M=$(python3 -c "import json;print(json.load(open('$ROOT/obs1.json'))['milestone'])" 2>/dev/null)
chk "마일스톤 shell 도달" "$M" "shell"
I=$(python3 -c "import json;print(json.load(open('$ROOT/obs1.json'))['injected'])" 2>/dev/null)
chk "자가주입 아님" "$I" "False"
ST=$(python3 -c "import json;print(json.load(open('$ROOT/obs1.json'))['stop'])" 2>/dev/null)
chk "정지 아님" "$ST" "False"
RO=$(python3 -c "import json;print(json.load(open('$ROOT/obs1.json'))['run_ok'])" 2>/dev/null)
chk "run_ok 참" "$RO" "True"

# 도출된 토큰 파일이 없으면 어떤 배너도 표면 칸을 정하지 않는다 (같은 콘솔, 파일만 없음)
WD1B=$(new_ws t1notok)
cp "$WD/06_machine/machine.c" "$WD1B/06_machine/machine.c"
cp "$WD/bl3.bin" "$WD1B/bl3.bin"
cp "$WD/STATIC.md" "$WD1B/STATIC.md"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD1B" sboot-test 1 shell "shell" "$WD1B/bl3.bin" help > "$ROOT/obs1b.json" 2>/dev/null
chk "토큰 파일이 없으면 셸 칸을 도달로 세지 않음" \
    "$(python3 -c "import json;d=json.load(open('$WD1B/fingerprint.json'));print(d['milestone'], d['surface_not_credited'])" 2>/dev/null)" \
    "none no derived token file"

# =============================================================================
hdr "2. 트랙 1 — 자가주입 차단 (머신이 문자열을 갖고 있음)"
WD2=$(new_ws t1inj)
printf 'static const char*p="S-BOOT # ";\nqemu_chr_fe_write_all(c,b,1);\n' > "$WD2/06_machine/machine.c"
cp "$WD/bl3.bin" "$WD2/bl3.bin"
printf 'shell\tS-BOOT # \n' > "$WD2/milestone_tokens.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD2" sboot-test 1 shell "shell" "$WD2/bl3.bin" help > "$ROOT/obs2.json" 2>/dev/null
M2=$(python3 -c "import json;print(json.load(open('$ROOT/obs2.json'))['milestone'])" 2>/dev/null)
I2=$(python3 -c "import json;print(json.load(open('$ROOT/obs2.json'))['injected'])" 2>/dev/null)
chk "도달로 인정 안 함" "$M2" "none"
chk "자가주입 감지됨" "$I2" "True"

# =============================================================================
hdr "3. 트랙 1 — Data Abort 지문 추출"
WD3=$(new_ws t1fault)
printf 'int x;\n' > "$WD3/06_machine/machine.c"
printf '' > "$ROOT/con3.txt"
printf 'Taking exception 4 [Data Abort]\nFAR 0x12860010\nELR 0xf48343a4\nTaking exception 4 [Data Abort]\n' > "$ROOT/trc3.txt"
make_qemu "$ROOT/con3.txt" "$ROOT/trc3.txt"
cp "$WD/bl3.bin" "$WD3/bl3.bin"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD3" sboot-test 1 shell "shell" "$WD3/bl3.bin" help > "$ROOT/obs3.json" 2>/dev/null
F=$(python3 -c "import json;d=json.load(open('$ROOT/obs3.json'));print(d['far'])" 2>/dev/null)
E=$(python3 -c "import json;d=json.load(open('$ROOT/obs3.json'));print(d['exceptions'])" 2>/dev/null)
chk "FAR 를 16진 문자열로 보존" "$F" "0x12860010"
chk "예외 2 건 계수" "$E" "2"

# =============================================================================
hdr "4. 커널측 마일스톤 사다리 (가장 높은 것 채택)"
# 통합 설계에서 관측 문자열은 도출값이다 — static-analyzer 가 milestone_tokens.txt 에
# 쓰고, run_full.sh 는 그 파일만 스캔한다. 벤더 문자열을 코드에 박지 않기 때문이다.
kernel_tokens() {   # $1 = workdir
  printf 'userspace\tRun /init\nlink_up\tufshcd\npower_mode\tPower mode change\nscsi_attach\tAttached SCSI disk\nrootfs\terofs\npartitions_up\tsda: sda\n' \
    > "$1/milestone_tokens.txt"
}
WD4=$(new_ws t2)
kernel_tokens "$WD4"
# 통합 플로우에 커널 단독 실행은 없다 — 부트로더 컨테이너가 항상 리셋 진입점이다
printf 'Run /init\x00ufshcd\x00Power mode change\x00Attached SCSI disk\x00erofs\x00' > "$WD4/fw.bin"
printf 'int y;\n' > "$WD4/06_machine/machine_kernel.c"
touch "$WD4/fw/Image.patched"
printf 'Run /init\nscsi host0: ufshcd\nPower mode change(0): M(1)G(3)\n[sda] Attached SCSI disk\n' > "$ROOT/con4.txt"
printf 'kernel trace\n' > "$ROOT/trc4.txt"
make_qemu "$ROOT/con4.txt" "$ROOT/trc4.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD4" test-kernel 1 link_up "userspace,link_up,power_mode,scsi_attach,partitions_up" "$WD4/fw.bin" > "$ROOT/obs4.json" 2>/dev/null
M4=$(python3 -c "import json;print(json.load(open('$ROOT/obs4.json'))['milestone'])" 2>/dev/null)
chk "최고 마일스톤 scsi_attach" "$M4" "scsi_attach"

# 4b. 트랙 2 자가주입 — 낮은 단이 오염되면 높은 단도 인정 금지
WD4B=$(new_ws t2inj)
kernel_tokens "$WD4B"
# 통합 플로우에 커널 단독 실행은 없다 — 부트로더 컨테이너가 항상 리셋 진입점이다
printf 'Run /init\x00ufshcd\x00Power mode change\x00Attached SCSI disk\x00erofs\x00' > "$WD4B/fw.bin"
printf 'qemu_log("Run /init");\n' > "$WD4B/06_machine/machine_kernel.c"
touch "$WD4B/fw/Image.patched"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD4B" test-kernel 1 link_up "userspace,link_up,power_mode,scsi_attach" "$WD4B/fw.bin" > "$ROOT/obs4b.json" 2>/dev/null
M4B=$(python3 -c "import json;print(json.load(open('$ROOT/obs4b.json'))['milestone'])" 2>/dev/null)
I4B=$(python3 -c "import json;print(json.load(open('$ROOT/obs4b.json'))['injected'])" 2>/dev/null)
chk "오염 시 상위 단도 불인정" "$M4B" "none"
chk "커널측 자가주입 감지"    "$I4B" "True"

# 4c. 사다리에 없는 단에 도달해도 하위 도달이 가려지지 않아야 한다.
#     milestone 은 "이 사다리에서 어디까지"이고, milestones_reached 는 "무엇을 봤나"다.
#     둘을 하나로 합치면, 사다리 밖 단에 도달한 회차가 목표 판정을 흐린다.
WD4C=$(new_ws t2skip)
kernel_tokens "$WD4C"
# 통합 플로우에 커널 단독 실행은 없다 — 부트로더 컨테이너가 항상 리셋 진입점이다
printf 'Run /init\x00ufshcd\x00Power mode change\x00Attached SCSI disk\x00erofs\x00' > "$WD4C/fw.bin"
printf 'int q;\n' > "$WD4C/06_machine/machine_kernel.c"
touch "$WD4C/fw/Image.patched"
printf 'Run /init\nerofs: (device dm-0): mounted\n' > "$ROOT/con4c.txt"
printf 'trace\n' > "$ROOT/trc4c.txt"
make_qemu "$ROOT/con4c.txt" "$ROOT/trc4c.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$WD4C" test-kernel 1 userspace "userspace,link_up,power_mode" "$WD4C/fw.bin" > "$ROOT/obs4c.json" 2>/dev/null
TOP=$(python3 -c "import json;print(json.load(open('$ROOT/obs4c.json'))['milestone'])" 2>/dev/null)
LIST=$(python3 -c "import json;print(','.join(json.load(open('$ROOT/obs4c.json'))['milestones_reached']))" 2>/dev/null)
chk "사다리 안 최고 단은 userspace" "$TOP" "userspace"
chk "도달 목록에 userspace 포함" "$LIST" "userspace,rootfs"
# 파이프라인의 사다리 인덱스 계산을 그대로 재현
IDX=$(node -e '
const goals=["userspace","link_up","power_mode"];
const reached=process.argv[1].split(",");
console.log(reached.reduce((b,n)=>Math.max(b,goals.indexOf(n)),-1));
' "$LIST" 2>/dev/null)
chk "사다리 인덱스 0 (userspace 도달 인식)" "$IDX" "0"

# =============================================================================
hdr "5. 한 변경 검문 (check_change)"
WD5=$(new_ws gate)
printf 'int a;\nint b;\n' > "$WD5/06_machine/machine.c"
printf 'int x;\n' > "$WD5/06_machine/other.c"
bash "$S/check_change.sh" "$WD5" snapshot >/dev/null
printf 'int a;\nint b2;\n' > "$WD5/06_machine/machine.c"
if bash "$S/check_change.sh" "$WD5" verify >/dev/null 2>&1; then ok "한 파일 1 hunk + 우회 4항목 통과"; else bad "정상 변경이 거부됨"; fi
printf 'int x2;\n' > "$WD5/06_machine/other.c"
if bash "$S/check_change.sh" "$WD5" verify >/dev/null 2>&1; then bad "두 파일 동시 수정이 통과됨"; else ok "두 파일 동시 수정 거부"; fi
bash "$S/check_change.sh" "$WD5" restore >/dev/null 2>&1
R=$(cat "$WD5/06_machine/other.c")
chk "restore 로 원본 복구" "$R" "int x;"
rm -f "$WD5/06_machine/bypasses.md"
printf 'int a;\nint bX;\n' > "$WD5/06_machine/machine.c"
if bash "$S/check_change.sh" "$WD5" verify >/dev/null 2>&1; then bad "우회 기록 없는데 통과됨"; else ok "우회 기록 누락 거부"; fi

# =============================================================================
hdr "6. 정지 조건 (stop_conditions)"
W6="$ROOT/stopA"; mkdir -p "$W6"
for i in 1 2; do
  python3 "$S/record.py" "$W6" round round=$i goal=link_up fp_exc=1 fp_far=0xA$i fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=3 fixer_no_new_change=false >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W6")
chk "진전 중엔 정지 안 함" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

W7="$ROOT/stopB"; mkdir -p "$W7"
for i in 1 2 3; do
  python3 "$S/record.py" "$W7" round round=$i goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=2 fixer_no_new_change=false >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "정체 2 → 에스컬레이션 발화" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["escalate_to_analyst"])')" "True"
chk "정체 2 → 아직 정지 아님"   "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

# Dryness is judged over a window, so two dry rounds are not yet exhaustion.
for i in 4 5; do
  python3 "$S/record.py" "$W7" round round=$i goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "dry 2회차는 아직 소진 아님" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

python3 "$S/record.py" "$W7" round round=6 goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "무브 소진 → EXHAUSTED" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

# 회귀 가드: 마지막 한 회차의 반짝임이 창 전체를 지우면 안 된다 (66회차 런어웨이)
python3 "$S/record.py" "$W7" round round=7 goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=1 fixer_no_new_change=false >/dev/null
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "마지막 회차 새 사실 1 → 소진 해제" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"
for i in 8 9 10; do
  python3 "$S/record.py" "$W7" round round=$i goal=link_up fp_exc=1 fp_far=0xSAME fp_elr=0xB fp_milestone=none fp_bytes=5 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W7")
chk "다시 창이 차면 EXHAUSTED" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

W8="$ROOT/stopC"; mkdir -p "$W8"
for i in 1 2 3 4; do
  if [ $((i % 2)) -eq 1 ]; then FF=0xAAA; else FF=0xBBB; fi
  python3 "$S/record.py" "$W8" round round=$i goal=link_up fp_exc=1 fp_far=$FF fp_elr=0x1 fp_milestone=none fp_bytes=9 analyst_new_facts=0 fixer_no_new_change=true >/dev/null
done
J=$(python3 "$S/stop_conditions.py" "$W8")
chk "진동 A↔B 감지" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["oscillating"])')" "True"

W9="$ROOT/stopD"; mkdir -p "$W9"
python3 "$S/record.py" "$W9" blocker code=BLOCKED_KO detail="벤더 .ko 없음" >/dev/null
J=$(python3 "$S/stop_conditions.py" "$W9")
chk "사실 블로커 → 즉시 정지" "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "BLOCKED_KO"

# =============================================================================
hdr "7. 검증 게이트 (verify.py, 통합 흐름)"
# 옛 --track 1/2 흐름은 없다. 자가주입(머신이 콘솔 문자열을 가짐 → UNVERIFIED)은
# tests/parts/verify_gates.sh 의 "게이트가 실패하면 UNVERIFIED" 와 렉서 사례 A~C 가 덮는다.
VW=$(new_ws verify)
printf 'Following commands are supported\x00' > "$VW/bl3.bin"
printf 'Following commands are supported\n'   > "$VW/07_logs/console_1.txt"
printf 'qemu_chr_fe_write_all(s->chr,b,1);\n' > "$VW/06_machine/machine.c"
printf '| shell_func | 0x9021f3dc |\n' > "$VW/STATIC.md"
printf '0x9021f3dc: stp\n' > "$VW/07_logs/run_1.log"
V=$(python3 "$S/verify.py" "$VW" --target F2 --container "$VW/bl3.bin" --trace "$VW/07_logs/run_1.log" 2>/dev/null)
chk "정상 → 게이트 3 항 통과 VERIFIED" "$(echo "$V" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["verdict"], d["gates_passed"], d["gates_total"])')" "VERIFIED 3 3"

# =============================================================================
hdr "8. 측정 기록 (record.py 타입 보존)"
RW="$ROOT/rec"; mkdir -p "$RW"
python3 "$S/record.py" "$RW" start t1 >/dev/null
python3 "$S/record.py" "$RW" metric phase=Run timer=t1 tokens_total=12345 milestone=none far=0x1234ABCD ok=true >/dev/null
L=$(tail -1 "$RW/metrics.jsonl")
chk "16진은 문자열 유지" "$(echo "$L" | python3 -c 'import json,sys;print(json.load(sys.stdin)["far"])')" "0x1234ABCD"
chk "none 은 문자열 유지"  "$(echo "$L" | python3 -c 'import json,sys;print(json.load(sys.stdin)["milestone"])')" "none"
chk "정수는 정수"          "$(echo "$L" | python3 -c 'import json,sys;print(type(json.load(sys.stdin)["tokens_total"]).__name__)')" "int"
chk "불리언은 불리언"      "$(echo "$L" | python3 -c 'import json,sys;print(type(json.load(sys.stdin)["ok"]).__name__)')" "bool"
chk "elapsed_s 기록됨"     "$(echo "$L" | python3 -c 'import json,sys;print("elapsed_s" in json.load(sys.stdin))')" "True"

# =============================================================================
hdr "9. 기록 파일 생성 확인 (JOURNAL / rounds / observation)"
[ -s "$WD/JOURNAL.md" ]        && ok "JOURNAL.md 생성"        || bad "JOURNAL.md 없음"
[ -s "$WD/observation.json" ]  && ok "observation.json 생성"  || bad "observation.json 없음"
[ -s "$WD/fingerprint.json" ]  && ok "fingerprint.json 생성"  || bad "fingerprint.json 없음"
[ -s "$WD/metrics.jsonl" ]     && ok "metrics.jsonl 생성"     || bad "metrics.jsonl 없음"
grep -q "try #1" "$WD/JOURNAL.md" && ok "JOURNAL 에 회차 시작 기록" || bad "JOURNAL 회차 기록 없음"

# =============================================================================
hdr "10. QEMU 실행 실패 시 정직한 보고"
FW=$(new_ws qfail)
printf 'int z;\n' > "$FW/06_machine/machine.c"
QEMU="/nonexistent/qemu" bash "$S/run_round.sh" "$FW" m 1 shell "shell" "$FW/bl3.bin" help > "$ROOT/obsf.json" 2>/dev/null
RF=$(python3 -c "import json;print(json.load(open('$ROOT/obsf.json'))['run_ok'])" 2>/dev/null)
chk "run_ok=false 로 정직 보고" "$RF" "False"

# =============================================================================
hdr "11. 펌웨어 형상 다양성 (9820 사례 회귀)"

# 11a. (삭제) ext4 rootfs 를 K2 증거로 인정하는가 — 그 판정은 옛 트랙 2 흐름에만 있었다.
#      통합 흐름의 rootfs 칸은 도출한 milestone_tokens.txt 로 보며 4c 가 그 칸을 시험한다.

# 11b. 저장소 사다리: 커널측 파티션 열거가 없으면 이중 구동(참고 항목 6)이 서지 않고, 미완으로 보고한다.
#      (옛 트랙 2 의 "K3 는 partitions_up 필수" 항목을 통합 흐름의 참고 항목 6 으로 옮긴 것이다.)
#      컨테이너에는 콘솔의 낱말을 넣어 게이트 2 가 통과하게 한다 — 보고하는 것은 저장소 사다리뿐이다.
KW=$(new_ws k3mid); printf 'int y;\n' > "$KW/06_machine/machine_kernel.c"
printf '### b\n- **대상**: t\n- **이유**: r\n- **방법**: m\n- **알려진 부작용**: s\n' > "$KW/06_machine/bypasses.md"
printf 'Run /init\nscsi host0: ufshcd\nPower mode change(0)\nEFI PART\n' > "$KW/07_logs/console_1.txt"
printf 'Run /init\x00scsi host0: ufshcd\x00Power mode change\x00EFI PART\x00[sda] Attached SCSI disk\x00sda: sda1\x00' > "$KW/fw.bin"
V=$(python3 "$S/verify.py" "$KW" --target F2 --container "$KW/fw.bin" 2>/dev/null)
chk "커널측 열거가 없으면 이중 구동(항목 6) 불통과 (부트로더측 접근은 있음)" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][5]["pass"])')" "False"
chk "UFS 단계를 미완으로 보고"        "$(echo "$V" | python3 -c 'import json,sys;print("미완" in json.load(sys.stdin)["ufs_controller"]["stage"])')" "True"
chk "마크다운 강조 우회 4항목 인식"    "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][6]["pass"])')" "True"

# 11c. partitions_up 도달 시 "최소 완료", 그리고 이중 구동이 선다
printf 'Run /init\nscsi host0: ufshcd\n[sda] Attached SCSI disk\nsda: sda1 sda2\nEFI PART\n' > "$KW/07_logs/console_1.txt"
V=$(python3 "$S/verify.py" "$KW" --target F2 --container "$KW/fw.bin" 2>/dev/null)
chk "partitions_up → 최소 완료" "$(echo "$V" | python3 -c 'import json,sys;print("최소 완료" in json.load(sys.stdin)["ufs_controller"]["stage"])')" "True"
chk "  커널측 열거가 있으면 이중 구동(항목 6) 통과" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][5]["pass"])')" "True"

# 11d. 소스 negative — 주석·#include 는 출력이 아니다
CW=$(new_ws srcneg)
printf '#include "qapi/error.h"\n/* 분석 주석: autoboot 게이트 */\nstatic void f(void){ qemu_chr_fe_write_all(c,b,1); }\n' > "$CW/06_machine/machine.c"
printf 'autoboot error\n' > "$CW/07_logs/console_1.txt"
printf 'x\x00autoboot\x00error\x00' > "$CW/bl3.bin"
printf '| shell_func | 0x1234abcd |\n' > "$CW/STATIC.md"
printf '0x1234abcd: stp\n' > "$CW/07_logs/run_1.log"
V=$(python3 "$S/verify.py" "$CW" --target F2 --container "$CW/bl3.bin" --trace "$CW/07_logs/run_1.log" 2>/dev/null)
chk "주석·#include 는 누출로 안 셈" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][0]["pass"])')" "True"

# 11e. 0 바이트 initramfs 를 QEMU 에 넘기지 않는가
ZW=$(new_ws zeroinit); : > "$ZW/fw/initramfs.cpio.gz"; touch "$ZW/fw/Image.patched"
printf 'int z;\n' > "$ZW/06_machine/machine_kernel.c"
printf 'boot\n' > "$ROOT/conz.txt"; printf 'trace\n' > "$ROOT/trcz.txt"; make_qemu "$ROOT/conz.txt" "$ROOT/trcz.txt"
cat > "$BIN/fake-qemu-args" <<EOF
#!/usr/bin/env bash
echo "\$@" > "$ROOT/qemu_args_seen.txt"
OUT=""; LOG=""
# -serial 값이 file: 로 시작할 때만 파일이다. 무조건 접두를 벗기면 \`-serial stdio\` 가
# "stdio" 라는 파일명이 되어 실행한 폴더(저장소 루트)에 찌꺼기를 남긴다.
while [ \$# -gt 0 ]; do
  case "\$1" in
    -serial) case "\$2" in file:*) OUT="\${2#file:}";; esac; shift 2;;
    -D) LOG="\$2"; shift 2;;
    *) shift;;
  esac
done
[ -n "\$OUT" ] && echo boot > "\$OUT"
[ -n "\$LOG" ] && echo trace > "\$LOG"
exit 0
EOF
chmod +x "$BIN/fake-qemu-args"
QEMU="$BIN/fake-qemu-args" bash "$S/run_full.sh" "$ZW" test-kernel 1 >/dev/null 2>&1
if grep -q '\-initrd' "$ROOT/qemu_args_seen.txt" 2>/dev/null; then bad "0 바이트 initramfs 가 QEMU 로 전달됨"; else ok "0 바이트 initramfs 는 전달 안 함"; fi
rm -f "$ROOT/qemu_args_seen.txt"

# =============================================================================
hdr "12. 벤더 다양성 — MediaTek (LK / MT6833 사례 회귀)"

# 12a. carve_check 가 아키텍처별 기준을 쓰는가 (LK 는 1.5MB, S-Boot 기준이면 오탐)
REPO="$REPO" python3 - > /tmp/carve_res.txt <<'PY'
import sys, types, os, io, contextlib
sys.modules.setdefault('capstone', types.SimpleNamespace(
    Cs=None, CS_ARCH_ARM64=0, CS_ARCH_ARM=0, CS_MODE_ARM=0, CS_MODE_THUMB=0))
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
import carve_disasm as cd
blob = bytearray(b"\x00" * (1500 * 1024))
blob[100:108] = b"fastboot"; blob[200:209] = b"preloader"
open("/tmp/lk_t.bin","wb").write(bytes(blob))
def full(a):
    cd.ARCH = a; b = io.StringIO()
    with contextlib.redirect_stdout(b): cd.carve_check("/tmp/lk_t.bin")
    return "is_full: True" in b.getvalue()
print(full("arm64")); print(full("arm32")); os.remove("/tmp/lk_t.bin")
PY
chk "LK 를 arm64 기준으로 보면 carve 오탐" "$(sed -n 1p /tmp/carve_res.txt)" "False"
chk "LK 를 arm32 기준으로 보면 full"       "$(sed -n 2p /tmp/carve_res.txt)" "True"
rm -f /tmp/carve_res.txt

# 12b. fastboot 표면의 마일스톤을 run_qemu 가 인식하는가
FW=$(new_ws mtk_fb); printf 'int q;\n' > "$FW/06_machine/machine.c"
printf 'fastboot_init()\nfastboot: processing commands\n[fastboot: command buf]-[getvar:version]\n' > "$ROOT/confb.txt"
printf 'no exceptions\n' > "$ROOT/trcfb.txt"; make_qemu "$ROOT/confb.txt" "$ROOT/trcfb.txt"
printf 'x' > "$FW/lk.bin"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$FW" mtk-bootloader 1 fastboot "fastboot" "$FW/lk.bin" help fastboot > "$ROOT/obsfb.json" 2>/dev/null
chk "fastboot 표면 마일스톤 인식" "$(python3 -c "import json;print(json.load(open('$ROOT/obsfb.json'))['milestone'])" 2>/dev/null)" "fastboot"

# 12c. fastboot 표면에서 머신이 입력 명령을 지어내면 게이트 3 불통과
VW=$(new_ws mtk_v); printf 'x\x00fastboot: processing commands\x00' > "$VW/lk.bin"
printf 'fastboot: processing commands\n' > "$VW/07_logs/console_1.txt"
printf 'const char *c = "getvar:version";\n' > "$VW/06_machine/machine.c"
printf -- '- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$VW/06_machine/bypasses.md"
printf '| shell_func | 0xdeadbeef |\n' > "$VW/STATIC.md"; printf '0xdeadbeef: x\n' > "$VW/07_logs/run_1.log"
V=$(python3 "$S/verify.py" "$VW" --target F2 --surface fastboot --container "$VW/lk.bin" --trace "$VW/07_logs/run_1.log" 2>/dev/null)
chk "머신이 입력 명령을 지어내면 불통과" "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][2]["pass"])')" "False"
printf 'static void f(void){}\n' > "$VW/06_machine/machine.c"
V=$(python3 "$S/verify.py" "$VW" --target F2 --surface fastboot --container "$VW/lk.bin" --trace "$VW/07_logs/run_1.log" 2>/dev/null)
chk "외부 입력이면 게이트 3 통과"        "$(echo "$V" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][2]["pass"])')" "True"


# 12d. 등급이 실제로 사다리를 바꾸는가 (A/B/C)
GW=$(new_ws grades); printf 'int g;\n' > "$GW/06_machine/machine.c"
printf 'S-BOOT # help\nFollowing commands\nreset: OK\nautoboot aborted..\n' > "$ROOT/cong.txt"
printf 'trace\n' > "$ROOT/trcg.txt"; make_qemu "$ROOT/cong.txt" "$ROOT/trcg.txt"
printf 'shell\tFollowing commands\ncommands\treset: OK\nautoboot\tautoboot aborted\n' > "$GW/milestone_tokens.txt"
printf 'x' > "$GW/bl.bin"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$GW" bl-test 1 shell "shell,commands,autoboot" "$GW/bl.bin" help shell > "$ROOT/obsg.json" 2>/dev/null
LISTG=$(python3 -c "import json;print(','.join(json.load(open('$ROOT/obsg.json'))['milestones_reached']))" 2>/dev/null)
TOPG=$(python3 -c "import json;print(json.load(open('$ROOT/obsg.json'))['milestone'])" 2>/dev/null)
chk "등급 단(commands·autoboot) 관측" "$LISTG" "shell,commands,autoboot"
chk "최고 단은 autoboot"              "$TOPG"  "autoboot"

# 13. Windows → WSL 브리지 (wsl_bridge.sh)
printf '\n\033[1m== 13. Windows → WSL 브리지 ==\033[0m\n'

# 경로 변환 단위 검증
sed -n '/^__to_wsl() {/,/^}/p' "$S/wsl_bridge.sh" > "$ROOT/to_wsl.sh"
tw() { echo "$(. "$ROOT/to_wsl.sh"; __to_wsl "$1")"; }
chk "Windows 백슬래시 경로 변환" "$(tw 'C:\Users\mawj0\x.sh')" "/mnt/c/Users/mawj0/x.sh"
chk "Git Bash 드라이브 경로 변환" "$(tw '/c/Users/mawj0/ws')"      "/mnt/c/Users/mawj0/ws"
chk "이미 Linux 경로면 그대로"    "$(tw '/home/marista/rehost')"   "/home/marista/rehost"
chk "경로 아닌 인자는 그대로"    "$(tw 'code=BLOCKED_ENV')"       "code=BLOCKED_ENV"

# 가짜 Git Bash + 가짜 wsl.exe 로 end-to-end
WB="$ROOT/winbin"; mkdir -p "$WB"
printf '#!/usr/bin/env bash\necho "MINGW64_NT-10.0-22631"\n' > "$WB/uname"; chmod +x "$WB/uname"
cat > "$WB/wsl.exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ROOT/argv.txt"
a=(); for x in "\$@"; do a+=( "\${x/#\/mnt\/c\//$ROOT/c/}" ); done
set -- "\${a[@]}"; [ "\$1" = "-e" ] && shift
PATH="/usr/bin:/bin" exec "\$@"
EOF
chmod +x "$WB/wsl.exe"
mkdir -p "$ROOT/c/plug" "$ROOT/c/My Work/ws"; cp -R "$S" "$ROOT/c/plug/scripts"

PATH="$WB:$PATH" bash "$ROOT/c/plug/scripts/journal.sh" 'C:/My Work/ws' note "브리지" >/dev/null 2>&1
chk "Git Bash 면 wsl.exe 로 건너간다" "$(head -1 "$ROOT/argv.txt")" "-e"
chk "공백 있는 경로가 한 인자로 보존" "$(grep -c '^/mnt/c/My Work/ws$' "$ROOT/argv.txt")" "1"
chk "건너간 뒤 실제로 파일을 쓴다"    "$([ -f "$ROOT/c/My Work/ws/JOURNAL.md" ] && echo yes)" "yes"

PATH="$WB:$PATH" bash "$ROOT/c/plug/scripts/py.sh" record.py 'C:/My Work/ws' blocker code=T detail=d >/dev/null 2>&1
chk "python 도 브리지를 탄다" "$([ -s "$ROOT/c/My Work/ws/blockers.jsonl" ] && echo yes)" "yes"

# wsl.exe 가 없으면 정직하게 실패해야 한다
NB="$ROOT/nowsl"; mkdir -p "$NB"; cp "$WB/uname" "$NB/"
PATH="$NB:/usr/bin:/bin" bash "$ROOT/c/plug/scripts/journal.sh" 'C:/x' note y >/dev/null 2>&1
chk "wsl.exe 없으면 EX_CONFIG(78)" "$?" "78"
JN=$(PATH="$NB:/usr/bin:/bin" bash "$ROOT/c/plug/scripts/check_env.sh" 'C:/x' 1 2>/dev/null)
chk "그래도 check_env 는 JSON 을 낸다" \
    "$(echo "$JN" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')" "False"

# Linux 에서는 가드가 무동작
JL=$(bash "$S/check_env.sh" "$(new_ws bridge)" 1 2>/dev/null)
chk "Linux/macOS 에서는 가드 무동작" \
    "$(echo "$JL" | python3 -c 'import json,sys;print(json.load(sys.stdin)["os"] in ("Linux","Darwin"))')" "True"


# 14. 도출 결과 배선 (derived_facts.py) — 찾은 것이 실제로 쓰이는가
printf '\n\033[1m== 14. 도출 결과 배선 ==\033[0m\n'
DW=$(new_ws derived)
cat > "$DW/STATIC.md" <<'EOF'
# 정적 도출

## 도출된 정지점

| 시그니처 | 관측 | 메커니즘 (근거) | 담당 fixer | 시도할 변경 |
|---|---|---|---|---|
| `entry_vector_refault` | FAR==ELR=0x620 | VBAR 미설정 (capstone 근거) | `fixer-bootflow` | 진입 PC 수정 |
EOF
D1=$(python3 "$S/derived_facts.py" "$DW")
chk "도출한 정지점을 읽는다"     "$(echo "$D1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new"])')" "1"
chk "담당 fixer 를 뽑아낸다"     "$(echo "$D1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_points"][0]["fixer"])')" "fixer-bootflow"

# 같은 정지점을 또 도출해도 '새 사실' 이 늘면 안 된다 (자기신고 대체의 핵심)
D2=$(python3 "$S/derived_facts.py" "$DW")
chk "같은 정지점 재도출은 new=0" "$(echo "$D2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new"])')" "0"

printf '| `smc_unhandled` | 예외2, ELR 이 smc | psci 미구현 (근거) | `fixer-el3` | id 처리 |\n' >> "$DW/STATIC.md"
D3=$(python3 "$S/derived_facts.py" "$DW")
chk "진짜 새 정지점은 new=1"     "$(echo "$D3" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new"])')" "1"

# 표가 없으면 0 이어야 한다 (없는 걸 지어내지 않음)
EW2=$(new_ws derived_empty)
D4=$(python3 "$S/derived_facts.py" "$EW2")
chk "표가 없으면 new=0"          "$(echo "$D4" | python3 -c 'import json,sys;print(json.load(sys.stdin)["new"])')" "0"

# 측정값이 정지 판정까지 이어지는가
python3 - "$DW" <<'PY2'
import json, os, sys
w = sys.argv[1]
with open(os.path.join(w, "rounds.jsonl"), "w") as f:
    for i in range(5, 23):
        f.write(json.dumps({"round": i, "goal": "shell", "fp_exc": "2020000",
            "fp_far": "0x620", "fp_elr": "0x620", "fp_milestone": "none", "fp_bytes": 0,
            "category": "unknown", "fixer": "fixer-bootflow", "change_key": None,
            "effect": "stall", "analyst_new_facts": 0, "fixer_no_new_change": True}) + "\n")
PY2
SC=$(python3 "$S/stop_conditions.py" "$DW" --ladder shell)
chk "새 도출 0 + fixer 소진 → EXHAUSTED" \
    "$(echo "$SC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

# 반대로 도출이 계속 나오면 멈추면 안 된다
python3 - "$DW" <<'PY3'
import json, os, sys
w = sys.argv[1]
rows = open(os.path.join(w, "rounds.jsonl")).read().replace('"analyst_new_facts": 0',
                                                            '"analyst_new_facts": 1')
open(os.path.join(w, "rounds.jsonl"), "w").write(rows)
PY3
SC2=$(python3 "$S/stop_conditions.py" "$DW" --ladder shell)
chk "새 도출이 있으면 계속 진행" \
    "$(echo "$SC2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"


# 15. 층 판정 신호 (futile_changes) — 고쳤는데 아무 변화 없음을 보는가
printf '\n\033[1m== 15. 층 판정 신호 ==\033[0m\n'
LW=$(new_ws layer)
python3 - "$LW" <<'PY4'
import json, os, sys
w = sys.argv[1]
with open(os.path.join(w, "rounds.jsonl"), "w") as f:
    for i in range(1, 21):
        # 회차 10·15 에 변경을 적용했지만 지문은 계속 0x620 그대로
        f.write(json.dumps({"round": i, "goal": "shell", "fp_exc": "2130000",
            "fp_far": "0x620", "fp_elr": "0x620", "fp_milestone": "none", "fp_bytes": 0,
            "category": "unknown", "fixer": "fixer-bootflow",
            "change_key": f"bandaid_{i}" if i in (10, 15) else None,
            "effect": "applied" if i in (10, 15) else "stall",
            "analyst_new_facts": 1, "fixer_no_new_change": False}) + "\n")
PY4
LJ=$(python3 "$S/stop_conditions.py" "$LW" --ladder shell)
chk "무효 변경을 센다"           "$(echo "$LJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["futile_changes"])')" "2"
chk "층 재검토 신호 발화"        "$(echo "$LJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["needs_layer_review"])')" "True"
chk "그래도 정지는 아니다"       "$(echo "$LJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

# 지문을 움직인 변경은 무효가 아니다
python3 - "$LW" <<'PY5'
import json, os, sys
w = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(w, "rounds.jsonl"))]
for r in rows[15:]:
    r["fp_far"] = "0xC90A5028"          # 변경이 지문을 움직였다
open(os.path.join(w, "rounds.jsonl"), "w").write(
    "".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rows))
PY5
LJ2=$(python3 "$S/stop_conditions.py" "$LW" --ladder shell)
chk "지문이 움직이면 무효 아님"  "$(echo "$LJ2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["needs_layer_review"])')" "False"

# 관측 문서에 신호가 실려 나가는가 (supervisor 가 봐야 판단한다)
grep -q 'needs_layer_review' "$S/run_round.sh"
chk "run_round 가 신호를 병합"   "$?" "0"

# build 층 정지점이 지식 테이블에 있는가
grep -q "entry_el_mismatch" "$REPO/knowledge/faults_unified.md"
chk "build 층 정지점 등재"       "$?" "0"
grep -q "rebuild" "$REPO/agents/supervisor.md"
chk "supervisor 가 rebuild 를 안다" "$?" "0"


# 16. 최후수단 fixer + 담당 경계
printf '\n\033[1m== 16. fixer-general · 담당 경계 ==\033[0m\n'

# 범위 무제한 fixer 가 정지를 막지 못해야 한다
GW2=$(new_ws general)
python3 - "$GW2" <<'PY6'
import json, os, sys
w = sys.argv[1]
with open(os.path.join(w, "rounds.jsonl"), "w") as f:
    for i in range(1, 21):
        f.write(json.dumps({"round": i, "goal": "shell", "fp_exc": "2130000",
            "fp_far": "0x620", "fp_elr": "0x620", "fp_milestone": "none", "fp_bytes": 0,
            "category": "unknown", "fixer": "fixer-general",
            "change_key": f"try_{i}" if i >= 8 else None,
            "effect": "applied" if i >= 8 else "stall",
            "analyst_new_facts": 0, "fixer_no_new_change": False}) + "\n")
PY6
GJ=$(python3 "$S/stop_conditions.py" "$GW2" --ladder shell)
chk "무효 변경은 수로 안 센다"     "$(echo "$GJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["futile_spent"])')" "True"
chk "general 이 시도 중이어도 소진" "$(echo "$GJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_reason"])')" "EXHAUSTED"

# 지문이 움직이면 소진이 아니다
python3 - "$GW2" <<'PY7'
import json, os, sys
w = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(w, "rounds.jsonl"))]
for n, r in enumerate(rows):
    if n >= 9: r["fp_far"] = f"0x{0xC90A5000 + n:X}"
open(os.path.join(w, "rounds.jsonl"), "w").write(
    "".join(json.dumps(x, ensure_ascii=False) + "\n" for x in rows))
PY7
GJ2=$(python3 "$S/stop_conditions.py" "$GW2" --ladder shell)
chk "진전 중이면 소진 아님"        "$(echo "$GJ2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop"])')" "False"

# 통합 플로우에는 트랙별 fixer 분리가 없다. 한 실행이 부트로더와 커널을 모두 지나므로
# 스토리지·커널 fixer 도 같은 목록에 있어야 한다.
T1=$(python3 - <<'PY8'
import re, pathlib
s = pathlib.Path("workflows/pipeline.js").read_text()
m = re.search(r"KNOWN_FIXERS = \[([^\]]*)\]", s, re.S)
print(",".join(re.findall(r"'([^']+)'", m.group(1))) if m else "PARSE_FAIL")
PY8
)
chk "fixer 목록이 단일"  "$T1" \
    "fixer-memory,fixer-el3,fixer-bootflow,fixer-secureboot,fixer-storage,fixer-kernel"
grep -q 'fixer-general' <<< "$T1"
chk "general 은 순위 목록 밖"      "$?" "1"
grep -q 'reached_by: decline_only' "$REPO/fixers/registry.yaml"
chk "registry 에 도달 조건 명시"   "$?" "0"
grep -q 'fixer_candidates.md' "$REPO/agents/fixer-general.md"
chk "후보 기록 지시 있음"          "$?" "0"

# supervisor 가 명부를 보고 처방하고, 담당 없으면 직행하는가
grep -q 'prescribed_fixer' "$REPO/agents/supervisor.md"
chk "supervisor 가 처방을 안다"    "$?" "0"
grep -q 'route === GENERAL_FIXER' "$REPO/workflows/pipeline.js"
chk "general 직행 경로 배선"       "$?" "0"
grep -q 'KNOWN_FIXERS.includes(sup?.prescribed_fixer)' "$REPO/workflows/pipeline.js"
chk "처방은 트랙 fixer 만 허용"    "$?" "0"


# 17. 최초 예외 · 지문 안정성 · 반영 · 철회 (S921N 25시간 로그 회귀)
printf '\n\033[1m== 17. 최초 예외 · 지문 안정성 ==\033[0m\n'

# 17a. storm 의 지문은 첫 예외여야 한다 (마지막 FAR 는 재귀가 멈춘 자리일 뿐)
OW=$(new_ws origin); printf 'int o;\n' > "$OW/06_machine/machine.c"
printf '' > "$ROOT/cono.txt"
{
  printf 'Taking exception 4 [Data Abort] on CPU 0\n'
  printf '...from EL1 to EL1\n...with ESR 0x25/0x96000046\n'
  printf '...with FAR 0xf4865914\n...with ELR 0xf4801204\n'
  for f in f4444810 f44447f0 f4444770; do
    printf 'Taking exception 4 [Data Abort] on CPU 0\n...with FAR 0x%s\n...with ELR 0xf4801204\n' "$f"
  done
} > "$ROOT/trco.txt"
make_qemu "$ROOT/cono.txt" "$ROOT/trco.txt"
printf 'x' > "$OW/bl.bin"
QEMU="$BIN/fake-qemu" bash "$S/run_round.sh" "$OW" sboot-test 1 shell "shell" "$OW/bl.bin" help > "$ROOT/obso.json" 2>/dev/null
gj() { python3 -c "import json;print(json.load(open('$1'))['$2'])" 2>/dev/null; }
chk "최초 FAR 를 뽑는다"        "$(gj "$ROOT/obso.json" origin_far)" "0xf4865914"
chk "최초 ESR 도 뽑는다"        "$(gj "$ROOT/obso.json" origin_esr)" "0x25/0x96000046"
chk "마지막 FAR 는 따로 보존"     "$(gj "$ROOT/obso.json" far)"        "0xf4444770"
grep -q '최초 예외' "$OW/07_logs/run_1.summary.txt"
chk "요약이 최초 예외부터 보여준다"  "$?" "0"

# 17b. 마지막 FAR 만 움직이는 storm 은 정체로 잡혀야 한다 (19회차 런어웨이 회귀)
FW17="$ROOT/fp17"; mkdir -p "$FW17"
for i in 1 2 3; do
  python3 "$S/record.py" "$FW17" round round=$i goal=shell \
    fp_exc=$((2860000 + i * 7000)) fp_far=0xf444${i}770 fp_elr=0xf4801204 \
    fp_origin_esr=0x25/0x96000046 fp_origin_far=0x0 fp_origin_elr=0xf4865914 \
    fp_milestone=none fp_bytes=7734 fp_uniq=118 \
    analyst_new_facts=2 fixer_no_new_change=false >/dev/null
done
J17=$(python3 "$S/stop_conditions.py" "$FW17" --ladder shell)
chk "마지막 FAR 가 걸어도 정체 인식" \
    "$(echo "$J17" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stall_count"])')" "2"
chk "예외 수 요동은 지문을 바꾸지 않음" \
    "$(echo "$J17" | python3 -c 'import json,sys;print(json.load(sys.stdin)["escalate_to_analyst"])')" "True"
chk "부팅 깊이를 기록"  \
    "$(echo "$J17" | python3 -c 'import json,sys;print(json.load(sys.stdin)["best_progress"]["uniq"])')" "118"

# 17c. 실행이 안 됐는데 깨끗한 회차로 보이면 안 된다 (거짓 EXHAUSTED 회귀)
NW=$(new_ws norun); printf 'int n;\n' > "$NW/06_machine/machine.c"
cat > "$BIN/fake-qemu-dead" <<'EOF'
#!/usr/bin/env bash
echo "qemu: could not open kernel file '~/rehost/x.bin'" >&2
exit 1
EOF
chmod +x "$BIN/fake-qemu-dead"
printf 'x' > "$NW/bl.bin"
QEMU="$BIN/fake-qemu-dead" bash "$S/run_round.sh" "$NW" m 1 shell "shell" "$NW/bl.bin" help > "$ROOT/obsn.json" 2>/dev/null
chk "실행 실패를 run_ok=false 로"  "$(gj "$ROOT/obsn.json" run_ok)" "False"
RE=$(python3 -c "import json;print('종료코드' in json.load(open('$ROOT/obsn.json'))['run_error'])" 2>/dev/null)
chk "실패 사유를 문장으로 남김"    "$RE" "True"
grep -q 'BLOCKED_ENV' "$REPO/workflows/pipeline.js"
chk "파이프라인이 실행실패를 정지로" "$?" "0"

# 17d. 고친 소스가 실제로 빌드되는 트리에 들어가는가 (stale binary 회귀)
SW=$(new_ws sync); printf 'int v1;\n' > "$SW/06_machine/machine.c"
QROOT="$ROOT/qemu_fake"; mkdir -p "$QROOT/hw/arm"
printf 'int old;\n' > "$QROOT/hw/arm/sboot_test.c"
bash "$S/sync_machine.sh" "$SW" sboot-test "$QROOT" >/dev/null 2>&1
chk "머신 소스를 트리로 복사"      "$(cat "$QROOT/hw/arm/sboot_test.c")" "int v1;"
printf 'int v2;\n' > "$SW/06_machine/machine.c"
bash "$S/sync_machine.sh" "$SW" sboot-test "$QROOT" >/dev/null 2>&1
chk "다음 회차 수정도 전파"        "$(cat "$QROOT/hw/arm/sboot_test.c")" "int v2;"
UW=$(new_ws sync_bad); printf 'int z;\n' > "$UW/06_machine/machine.c"
bash "$S/sync_machine.sh" "$UW" no-such-machine "$QROOT" >/dev/null 2>&1
chk "대상이 없으면 정직하게 실패"  "$?" "3"
grep -q 'sync_machine.sh' "$REPO/workflows/pipeline.js"
chk "회차 적용 단계에 배선"        "$?" "0"

# 17e. 반증된 우회를 되돌릴 수 있는가
RW17=$(new_ws revert)
printf 'int keep;\nint target;\nint tail;\n' > "$RW17/06_machine/machine.c"
bash "$S/check_change.sh" "$RW17" snapshot 5 >/dev/null 2>&1
printf 'int keep;\nint target_BYPASS;\nint tail;\n' > "$RW17/06_machine/machine.c"
bash "$S/check_change.sh" "$RW17" snapshot 6 >/dev/null 2>&1
printf 'int keep_LATER;\nint target_BYPASS;\nint tail;\n' > "$RW17/06_machine/machine.c"
bash "$S/revert_change.sh" "$RW17" 5 "메커니즘이 반증됨" >/dev/null 2>&1
chk "회차 5 변경만 제거"      "$(grep -c 'target_BYPASS' "$RW17/06_machine/machine.c")" "0"
chk "이후 회차 변경은 유지"   "$(grep -c 'keep_LATER'   "$RW17/06_machine/machine.c")" "1"
chk "철회도 우회 4항목으로 기록" \
    "$(grep -c '우회 철회' "$RW17/06_machine/bypasses.md")" "1"
bash "$S/revert_change.sh" "$RW17" 99 "없는 회차" >/dev/null 2>&1
chk "스냅샷 없으면 거부"      "$?" "4"
grep -q "route === 'revert'" "$REPO/workflows/pipeline.js"
chk "supervisor 철회 경로 배선" "$?" "0"

# 17f. 도출표 파서 — 하위 절의 행과 줄바꿈된 '#' 문장 (17/20 유실 회귀)
DW17=$(new_ws derived17)
cat > "$DW17/STATIC.md" <<'EOF'
# 정적 도출

## 12) 머신 빌드용 값
| carve | full | derived | carve_check |

## 도출된 정지점

| 시그니처 | 관측 | 메커니즘 (근거) | 담당 fixer | 시도할 변경 |
|---|---|---|---|---|
| `first_row` | 관측 | 근거 | `fixer-bootflow` | 변경 |

### round 5 재도출 (escalation) — 새 정지점 1건

에러 카운터가
#179→#180 증가하며 무한 루프.

| `after_subsection` | 관측 | 바이트 `4ac10011|280140b9` 근거 | `fixer-memory` | 변경 |

### round 9 재도출 (escalation)

| `after_false_heading` | 관측 | 근거 | `fixer-el3` | 변경 |
EOF
D17=$(python3 "$S/derived_facts.py" "$DW17" --peek)
chk "하위 절의 행도 읽는다"       "$(echo "$D17" | python3 -c 'import json,sys;print(json.load(sys.stdin)["total"])')" "3"
chk "줄바꿈된 #문장이 표를 안 닫음" \
    "$(echo "$D17" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_points"][2]["signature"])')" "after_false_heading"
chk "셀 안의 파이프에도 담당 인식" \
    "$(echo "$D17" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stop_points"][1]["fixer"])')" "fixer-memory"
chk "값 표는 정지점이 아니다" \
    "$(echo "$D17" | python3 -c 'import json,sys;print(any(r["signature"]=="carve" for r in json.load(sys.stdin)["stop_points"]))')" "False"

# 17g. 기록이 커지면 근거는 보관하고 표는 남긴다
python3 - "$DW17" <<'PY9'
import sys, os
w = sys.argv[1]
p = os.path.join(w, "STATIC.md")
text = open(p, encoding="utf-8").read()
filler = "\n".join("근거 문장 %d" % i for i in range(4000))
open(p, "a", encoding="utf-8").write("\n### round 12 재도출\n" + filler + "\n")
PY9
R17=$(python3 "$S/static_rotate.py" "$DW17" --keep 1 --max-bytes 20000)
chk "회전 수행"          "$(echo "$R17" | python3 -c 'import json,sys;print(json.load(sys.stdin)["rotated"])')" "True"
rm -f "$DW17/derived_facts.jsonl"
D17B=$(python3 "$S/derived_facts.py" "$DW17" --peek)
chk "회전 후에도 행은 전부 남음" \
    "$(echo "$D17B" | python3 -c 'import json,sys;print(json.load(sys.stdin)["total"])')" "3"
[ -s "$DW17/08_docs/static_archive.md" ] && ok "근거는 08_docs 로 보관" || bad "보관 파일 없음"

# 17h. 반려한 fixer 다음에 2·3순위를 실제로 물어보는가
grep -q 'candidates.slice(0, 3)' "$REPO/workflows/pipeline.js"
chk "2·3순위까지 후보로 시도"  "$?" "0"
grep -q 'best_progress' "$REPO/scripts/stop_conditions.py"
chk "정지 보고에 부팅 깊이"    "$?" "0"


# 18. 외부 입력 하니스 — autoboot 게이트 (S921N 셸 미도달 회귀)
printf '\n\033[1m== 18. 외부 입력 하니스 ==\033[0m\n'

# 게이트를 진짜로 흉내내는 가짜 QEMU: CR 3연타를 받아야 프롬프트를 낸다
cat > "$BIN/fake-qemu-gate" <<'PYEOF'
#!/usr/bin/env python3
import sys
need = int(__import__("os").environ.get("GATE_CR", "3"))
sys.stdout.write("booting...\n"); sys.stdout.flush()
cnt = 0
while True:
    b = sys.stdin.buffer.read(1)
    if not b:
        sys.exit(0)
    if b == b"\r":
        cnt += 1
        if cnt >= need:
            break
    else:
        cnt = 0
sys.stdout.write("S-BOOT # \n"); sys.stdout.flush()
# 실제 셸처럼: 빈 줄(CR 연타 잔여)은 프롬프트만 다시 찍고 계속 기다린다
line = b""
while True:
    b = sys.stdin.buffer.read(1)
    if not b:
        sys.exit(0)
    if b != b"\r":
        line += b
        continue
    if not line:
        sys.stdout.write("S-BOOT # \n"); sys.stdout.flush()
        continue
    sys.stdout.write("Following commands are supported\n" if line == b"help" else "?\n")
    sys.stdout.flush()
    break
PYEOF
chmod +x "$BIN/fake-qemu-gate"

HW=$(new_ws harness); printf 'int h;\n' > "$HW/06_machine/machine.c"
printf 'shell\tS-BOOT # \ncommands\tFollowing commands are supported\n' > "$HW/milestone_tokens.txt"
printf 'x' > "$HW/bl.bin"
# 인터럽트 패턴은 도출된 게이트에서만 온다. 계획이 없으면 하니스는 아무것도 보내지 않는다 (아래 별도 시험).
printf '{"autoboot_interrupt":{"bytes":"\\r","count":3,"contiguous":true,"empty_poll_budget":0,"evidence":"synthetic"}}\n' > "$HW/input_plan.json"
TIMEOUT=6 QEMU="$BIN/fake-qemu-gate" bash "$S/run_round.sh" "$HW" t 1 shell "shell,commands" "$HW/bl.bin" help shell > "$ROOT/obsh.json" 2>/dev/null
chk "CR 연타로 게이트 통과 → 셸 도달" \
    "$(python3 -c "import json;print(json.load(open('$ROOT/obsh.json'))['milestone'])" 2>/dev/null)" "commands"
chk "머신 자가주입 아님" \
    "$(python3 -c "import json;print(json.load(open('$ROOT/obsh.json'))['injected'])" 2>/dev/null)" "False"
grep -q "autoboot 중단 시도" "$HW/07_logs/input_1.txt" 2>/dev/null
chk "보낸 입력을 기록으로 남김"  "$?" "0"
grep -q "명령" "$HW/07_logs/input_1.txt" 2>/dev/null
chk "프롬프트 관측 후 명령 전송" "$?" "0"

# 도출된 패턴(count)을 따르는가 — exynos 하드코딩이 아니라 슬롯이어야 한다
HW2=$(new_ws harness_plan); printf 'int h;\n' > "$HW2/06_machine/machine.c"
printf 'shell\tS-BOOT # \n' > "$HW2/milestone_tokens.txt"
printf 'x' > "$HW2/bl.bin"
printf '{"autoboot_interrupt":{"bytes":"\\r","count":5,"contiguous":true,"empty_poll_budget":0,"evidence":"gate @0x1234 cmp w8,#5"}}\n' \
    > "$HW2/input_plan.json"
GATE_CR=5 TIMEOUT=6 QEMU="$BIN/fake-qemu-gate" bash "$S/run_round.sh" "$HW2" t 1 shell "shell" "$HW2/bl.bin" help shell > /dev/null 2>&1
grep -q "x5 (derived" "$HW2/07_logs/input_1.txt" 2>/dev/null
chk "도출된 연타 수를 사용"      "$?" "0"
chk "5연타 게이트도 통과" \
    "$(python3 -c "import json;print(json.load(open('$HW2/observation.json'))['milestone'])" 2>/dev/null)" "shell"
# 도출된 게이트 성질이 산문이 아니라 기계가 읽는 필드로 전달되는가
chk "게이트 성질이 요약에 실림" \
    "$(python3 -c "import json;d=json.load(open('$HW2/input_summary.json'));print(d['count'],d['contiguous'],d['empty_poll_budget'],d['source'])" 2>/dev/null)" \
    "5 True 0 derived"
# 프롬프트를 못 봤으면 명령을 보내지 않는다 — 블라인드 전송 폐기 회귀
chk "프롬프트 관측 후에만 명령 전송" \
    "$(python3 -c "import json;d=json.load(open('$HW2/input_summary.json'));print(d['prompt_seen'],d['command_sent'],d['command_blind'])" 2>/dev/null)" \
    "True True False"
# 관측 문서까지 배선됐는가 — 입력 경로 사실이 회차에 실려야 분류가 그것을 볼 수 있다
chk "관측 문서에 입력 경로 사실" \
    "$(python3 -c "import json;d=json.load(open('$HW2/observation.json'));print(d['prompt_seen'],d['input_offered'],d['input_starved'])" 2>/dev/null)" \
    "True True False"

# 도출된 게이트가 없으면 하니스는 인터럽트 패턴을 보내지 않고 출처를 absent 로 남긴다 (기본 CR 3연타 폐기)
HW3=$(new_ws harness_noplan); printf 'int h;\n' > "$HW3/06_machine/machine.c"
printf 'shell\tS-BOOT # \n' > "$HW3/milestone_tokens.txt"
printf 'x' > "$HW3/bl.bin"
TIMEOUT=4 QEMU="$BIN/fake-qemu-gate" bash "$S/run_round.sh" "$HW3" t 1 shell "shell" "$HW3/bl.bin" help shell > /dev/null 2>&1
chk "계획이 없으면 보낸 바이트 0, 출처 absent" \
    "$(python3 -c "import json;d=json.load(open('$HW3/input_summary.json'));print(d['source'],d['bytes_sent'],d['input_offered'])" 2>/dev/null)" \
    "absent 0 False"
chk "계획이 없으면 게이트를 못 넘어 셸 미도달" \
    "$(python3 -c "import json;print(json.load(open('$HW3/observation.json'))['milestone'])" 2>/dev/null)" "none"

# 머신은 입력을 만들지 않는다 — 템플릿 회귀
grep -q "rx_seed" "$REPO/templates/machine_full.c.tmpl"
chk "템플릿에 자가 시드 없음"    "$?" "1"
grep -q "qemu_chr_fe_accept_input" "$REPO/templates/machine_full.c.tmpl"
chk "accept_input 호출 있음"     "$?" "0"
grep -q "{{RESET_PC}}" "$REPO/templates/machine_full.c.tmpl"
chk "리셋 PC 가 적재주소와 별개 슬롯" "$?" "0"

# 검증 게이트 3 — shell 표면에서도 자가입력을 잡는가
IW=$(new_ws item4)
printf 'Following commands are supported\x00' > "$IW/bl3.bin"
printf 'Following commands are supported\n'   > "$IW/07_logs/console_1.txt"
printf '| shell_func | 0x9021f3dc |\n' > "$IW/STATIC.md"
printf '0x9021f3dc: stp\n' > "$IW/07_logs/run_1.log"
printf 'static void f(void){ qemu_chr_fe_write_all(s->chr,b,1); }\n' > "$IW/06_machine/machine.c"
V4=$(python3 "$S/verify.py" "$IW" --target F2 --container "$IW/bl3.bin" --trace "$IW/07_logs/run_1.log" --input-token help 2>/dev/null)
chk "외부 입력이면 게이트 3 통과" \
    "$(echo "$V4" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][2]["pass"])')" "True"
printf 'static void rx_seed(S*s,const char*p){}\nstatic void f(void){ qemu_chr_fe_write_all(s->chr,b,1); }\n' \
    > "$IW/06_machine/machine.c"
V4=$(python3 "$S/verify.py" "$IW" --target F2 --container "$IW/bl3.bin" --trace "$IW/07_logs/run_1.log" --input-token help 2>/dev/null)
chk "머신이 RX 를 채우면 게이트 3 불통과" \
    "$(echo "$V4" | python3 -c 'import json,sys;print(json.load(sys.stdin)["items"][2]["pass"])')" "False"

# 실행 명령이 하나이고, 그 문서에 범위가 못박혀 있는가
grep -q "reset PC" "$REPO/skills/start/SKILL.md"
chk "start SKILL 에 실행 범위 명시"  "$?" "0"
chk "파이프라인을 부르는 스킬은 하나" \
    "$(grep -l 'pipeline.js' "$REPO"/skills/*/SKILL.md | wc -l | tr -d ' ')" "1"

# =============================================================================
# 18b. 파티션표 가용성 — 등급 C 는 매체를 읽어야 도달한다 (S921N PIT 회귀)
# =============================================================================
printf '\n\033[1m== 18b. 파티션표 가용성 ==\033[0m\n'

# 펌웨어가 파티션표 부재를 스스로 보고하는 콘솔을 내는 가짜 QEMU
cat > "$BIN/fake-qemu-pit" <<'PYEOF'
#!/usr/bin/env python3
import os, sys, time
say = lambda t: (sys.stdout.write(t), sys.stdout.flush())
say("get_boot_device() == BOOT_UFS\n")
say("UFS link established\n")
if os.environ.get("PIT_OK") == "1":
    say("pit_check_integrity: pit is valid\n")
else:
    say("pit_check_integrity: invalid pit.(0x0)\n")
    say("update_guid_partition_table: There is no pit binary.\n")
say("check sbl_shell mode\n\nautoboot aborted..\nS-BOOT # ")
time.sleep(1.2)
PYEOF
chmod +x "$BIN/fake-qemu-pit"

PW=$(new_ws pit); printf 'int p;\n' > "$PW/06_machine/machine.c"
printf 'shell\tS-BOOT # \n' > "$PW/milestone_tokens.txt"
printf 'x' > "$PW/bl.bin"
printf 'missing\tThere is no pit binary\nmissing\tpit_check_integrity: invalid pit.\nok\tpit_check_integrity: pit is valid\n' \
    > "$PW/storage_tokens.txt"
TIMEOUT=3 QEMU="$BIN/fake-qemu-pit" bash "$S/run_round.sh" "$PW" t 1 shell "shell" "$PW/bl.bin" help shell >/dev/null 2>&1
chk "파티션표 부재를 관측" \
    "$(python3 -c "import json;print(json.load(open('$PW/observation.json'))['storage_partition_table'])" 2>/dev/null)" "missing"
chk "판정 근거 토큰을 남김" \
    "$(python3 -c "import json;print(bool(json.load(open('$PW/observation.json'))['storage_token']))" 2>/dev/null)" "True"
# 매체를 못 읽어도 표면 도달은 영향을 받지 않는다 (등급 A 는 그대로)
chk "표면 도달은 영향 없음" \
    "$(python3 -c "import json;print(json.load(open('$PW/observation.json'))['milestone'])" 2>/dev/null)" "shell"

# 표가 정상이면 ok 로 관측되어야 한다
PIT_OK=1 TIMEOUT=3 QEMU="$BIN/fake-qemu-pit" bash "$S/run_round.sh" "$PW" t 2 shell "shell" "$PW/bl.bin" help shell >/dev/null 2>&1
chk "정상이면 ok 로 관측" \
    "$(python3 -c "import json;print(json.load(open('$PW/observation.json'))['storage_partition_table'])" 2>/dev/null)" "ok"

# ★ 미관측은 막지 않는다 — 토큰 파일이 없으면 unknown 이어야 한다.
#   침묵을 'missing' 으로 읽으면 스토리지에 닿기도 전에 죽은 회차가 등급을 막는다.
NW=$(new_ws pit_unknown); printf 'int p;\n' > "$NW/06_machine/machine.c"
printf 'shell\tS-BOOT # \n' > "$NW/milestone_tokens.txt"
printf 'x' > "$NW/bl.bin"
TIMEOUT=3 QEMU="$BIN/fake-qemu-pit" bash "$S/run_round.sh" "$NW" t 1 shell "shell" "$NW/bl.bin" help shell >/dev/null 2>&1
chk "토큰 파일 없으면 unknown"  \
    "$(python3 -c "import json;print(json.load(open('$NW/observation.json'))['storage_partition_table'])" 2>/dev/null)" "unknown"

# 규칙이 문서·지식표·등록부에 등재됐는가
# BLOCKED_STORAGE 는 0.19.0 에서 폐기됐다 — 매체를 직접 합성하므로 파티션표 부재는
# 트랙 경계가 아니라 합성 이미지의 결함이고, fixer-storage 가 담당한다.
grep -q "BLOCKED_STORAGE" "$REPO/CLAUDE.md"
chk "폐기된 블로커가 문서에 없음" "$?" "1"
grep -q "partition_table_unavailable" "$REPO/knowledge/faults_unified.md"
chk "정지점이 지식표에"          "$?" "0"
grep -q "partition_table_unavailable" "$REPO/fixers/registry.yaml"
chk "담당 없음으로 등록"         "$?" "0"
grep -q "partition_table_unavailable" "$REPO/knowledge/faults_unified.md"
chk "정지점이 통합 분류표에"      "$?" "0"
grep -q "storage_tokens.txt" "$REPO/agents/static-analyzer.md"
chk "도출 지시가 분석가에"        "$?" "0"

# =============================================================================
# 19. 실행 분석 — jsonl 기록에서 소요·정체·귀인을 계산
# =============================================================================
printf '\n\033[1m== 19. 실행 분석 ==\033[0m\n'

AW=$(new_ws analysis)
printf '| 모델 | SM-TEST |\n| 트랙 | 1 |\n' > "$AW/INPUT.md"
# 5회차: 2·3·4 가 같은 정지점(정체), 그중 2·3 의 변경은 관측을 못 움직임.
# 재분석(600초)·재생성이 4회차와 5회차 사이에 끼어 있다.
# 실제 기록과 같은 모양: 회차마다 Run/Loop 이벤트가 있어 단계 구간이 좁게 잡힌다.
{
  printf '{"epoch":1000,"ts":"T0","phase":"Start","event":"session_start"}\n'
  printf '{"epoch":1100,"ts":"T1","phase":"Build","event":"build_end","tokens_total":1000}\n'
  printf '{"epoch":1250,"ts":"T1a","phase":"Run","round":1,"event":"run_end"}\n'
  printf '{"epoch":1300,"ts":"T1b","phase":"Loop","round":1,"event":"apply_end","tokens_total":1500}\n'
  printf '{"epoch":1550,"ts":"T2a","phase":"Run","round":2,"event":"run_end"}\n'
  printf '{"epoch":1600,"ts":"T2b","phase":"Loop","round":2,"event":"apply_end","tokens_total":2200}\n'
  printf '{"epoch":2450,"ts":"T3a","phase":"Run","round":3,"event":"run_end"}\n'
  printf '{"epoch":2500,"ts":"T3b","phase":"Loop","round":3,"event":"apply_end","tokens_total":3600}\n'
  printf '{"epoch":4050,"ts":"T4a","phase":"Run","round":4,"event":"run_end"}\n'
  printf '{"epoch":4100,"ts":"T4b","phase":"Loop","round":4,"event":"apply_end","tokens_total":5000}\n'
  printf '{"epoch":5000,"ts":"T5","phase":"Analyze","event":"analyze_end","tokens_total":9000}\n'
  printf '{"epoch":5100,"ts":"T6","phase":"Build","event":"build_end","tokens_total":9500}\n'
} > "$AW/metrics.jsonl"
{
  printf '{"epoch":1200,"ts":"T2","round":1,"fp_origin_esr":"0x1","fp_origin_far":"0xa","fp_origin_elr":"0xb","fp_milestone":"none","fp_bytes":10,"fp_uniq":5,"fp_exc":1,"category":"data_abort_unmapped","fixer":"fixer-memory","change_key":"memory:w1","effect":"applied","tokens_total":1500}\n'
  printf '{"epoch":1500,"ts":"T3","round":2,"fp_origin_esr":"0x2","fp_origin_far":"0xc","fp_origin_elr":"0xd","fp_milestone":"none","fp_bytes":20,"fp_uniq":9,"fp_exc":1,"category":"unknown","fixer":"fixer-memory","change_key":"memory:w2","effect":"applied","analyst_new_facts":0,"tokens_total":2200}\n'
  printf '{"epoch":2400,"ts":"T4","round":3,"fp_origin_esr":"0x2","fp_origin_far":"0xc","fp_origin_elr":"0xd","fp_milestone":"none","fp_bytes":20,"fp_uniq":9,"fp_exc":1,"category":"unknown","fixer":"fixer-memory","change_key":"memory:w3","effect":"applied","tokens_total":3600}\n'
  printf '{"epoch":4000,"ts":"T4b","round":4,"fp_origin_esr":"0x2","fp_origin_far":"0xc","fp_origin_elr":"0xd","fp_milestone":"none","fp_bytes":20,"fp_uniq":9,"fp_exc":1,"category":"data_abort_unmapped","fixer":"fixer-memory","change_key":"memory:w4","effect":"applied","tokens_total":5000}\n'
  printf '{"epoch":5400,"ts":"T7","round":1,"fp_origin_esr":"0x3","fp_origin_far":"0xe","fp_origin_elr":"0xf","fp_milestone":"shell","fp_bytes":900,"fp_uniq":80,"fp_exc":1,"category":"reached","effect":"progress","tokens_total":10000}\n'
} > "$AW/rounds.jsonl"
A=$(python3 "$S/analyze_run.py" "$AW" 2>/dev/null)
chk "분석 생성 성공"            "$?" "0"
chk "회차 수를 셈"              "$(echo "$A" | python3 -c 'import json,sys;print(json.load(sys.stdin)["rounds"])')" "5"
chk "회차 번호 되감김을 구간으로" "$(echo "$A" | python3 -c 'import json,sys;print(json.load(sys.stdin)["series"])')" "2"
chk "정체 구간을 찾음"          "$(echo "$A" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stall_stretches"])')" "1"
# 3회차(2-3 아님, 1-3)는 앞뒤가 같은 정지점이라 정체 구간에 들어가야 한다
chk "정체 구간 길이 3회차"      "$(python3 -c 'import json;print(json.load(open("'"$AW"'/analysis.json"))["stretches"][0]["rounds"])')" "3"
# 재분석·재생성(1000초)이 낀 회차는 그 시간을 회차 소요에서 빼야 한다
chk "단계 시간이 회차에서 분리됨" \
    "$(python3 -c 'import json;r=[x for x in json.load(open("'"$AW"'/analysis.json"))["rounds"] if x["label"]=="2-1"][0];print(r["stage_seconds"], r["raw_duration_s"], r["duration_s"])')" \
    "1000 1400 400"
# 토큰은 누적값이라 델타로 복원되어야 한다 (일부 이벤트에만 실려 있어도)
chk "단계별 토큰이 0 이 아님" \
    "$(python3 -c 'import json;p=json.load(open("'"$AW"'/analysis.json"))["phases"];print(p["Analyze"]["tokens"]>0 and p["Build"]["tokens"]>0)')" "True"
grep -q "소요 원인 분석" "$AW/ANALYSIS.md"
chk "원인 분석 절이 있음"        "$?" "0"
grep -q "기록의 한계" "$AW/ANALYSIS.md"
chk "기록 한계를 밝힘"          "$?" "0"
grep -q "관측을 움직이지 못한 변경" "$AW/ANALYSIS.md"
chk "무효 변경을 짚음"          "$?" "0"
# 기록이 아예 없어도 죽지 않아야 한다 (내보내기 중간에 멈추면 안 됨)
EW=$(new_ws analysis_empty)
python3 "$S/analyze_run.py" "$EW" >/dev/null 2>&1
chk "기록이 없어도 생성"        "$?" "0"


# =============================================================================
printf '\n\033[1m== 20. 릴리스 일관성 ==\033[0m\n'
# 버전을 올리지 않고 내용을 내보내면, 그 번호를 이미 받은 환경은 수정을 못 받는다.
# 0.19.0 에서 실제로 그렇게 됐다 (46개 파일이 같은 번호로 나감).

# 저장소 자신에 대해서는 "판정이 나오는가"만 본다. 개발 중에는 미커밋 변경이 있는 것이
# 정상이고, 그때 검문이 막는 것도 정상이므로 통과를 요구하면 시험이 항상 깨진다.
# 검문의 로직은 아래 가짜 저장소로 양방향 확인한다.
RC=$(bash "$S/check_release.sh" >/dev/null 2>&1; echo $?)
[ "$RC" = "0" ] || [ "$RC" = "1" ]
chk "저장소에 대해 판정이 나옴"  "$?" "0"

PV=$(python3 -c 'import json;print(json.load(open(".claude-plugin/plugin.json"))["version"])')
MV=$(python3 -c 'import json;print(json.load(open(".claude-plugin/marketplace.json"))["plugins"][0]["version"])')
chk "plugin=marketplace 버전"    "$PV" "$MV"
grep -q "^## $PV" CHANGELOG.md
chk "CHANGELOG 에 항목이 있음"   "$?" "0"

# 검문이 실제로 잡는지 — 가짜 저장소로 위반을 만든다. 통과만 확인하면
# 언제나 통과하는 검문과 구별되지 않는다.
mk_repo() {   # $1=plugin 버전 $2=marketplace 버전
  local R="$ROOT/rel_$3"; mkdir -p "$R/.claude-plugin" "$R/skills"
  ( cd "$R"
    git init -q . 2>/dev/null; git config user.email t@t; git config user.name t
    printf '{"version": "%s"}\n' "$1" > .claude-plugin/plugin.json
    printf '{"plugins":[{"version": "%s"}]}\n' "$2" > .claude-plugin/marketplace.json
    echo one > skills/a.md
    git add -A >/dev/null; git commit -qm v1 >/dev/null )
  echo "$R"
}
RS="$S/check_release.sh"

R1=$(mk_repo 1.0.0 1.0.0 clean)
chk "깨끗한 저장소는 통과"      "$(REPO="$R1" bash "$RS" >/dev/null 2>&1; echo $?)" "0"

# 같은 버전으로 동작 표면을 바꾸면 막혀야 한다
( cd "$R1" && echo two > skills/a.md && git add -A >/dev/null && git commit -qm drift >/dev/null )
chk "버전 없는 변경을 막음"      "$(REPO="$R1" bash "$RS" >/dev/null 2>&1; echo $?)" "1"
REPO="$R1" bash "$RS" 2>&1 | grep -q 'skills/a.md'
chk "바뀐 파일을 지목함"        "$?" "0"

# 버전을 올리면 다시 통과해야 한다 (막기만 하면 릴리스가 불가능해진다)
( cd "$R1" && sed -i '' 's/1\.0\.0/1.1.0/g' .claude-plugin/*.json && git add -A >/dev/null && git commit -qm v2 >/dev/null )
chk "버전을 올리면 통과"        "$(REPO="$R1" bash "$RS" >/dev/null 2>&1; echo $?)" "0"

# 문서만 바뀐 것은 릴리스를 강요하지 않는다
( cd "$R1" && mkdir -p docs && echo d > docs/x.md && git add -A >/dev/null && git commit -qm doc >/dev/null )
chk "문서 변경은 통과"          "$(REPO="$R1" bash "$RS" >/dev/null 2>&1; echo $?)" "0"

# 카탈로그가 낮으면 갱신이 사용자에게 닿지 않는다 (0.17.0 사례)
R2=$(mk_repo 1.0.0 0.9.0 drift)
chk "카탈로그 드리프트를 막음"   "$(REPO="$R2" bash "$RS" >/dev/null 2>&1; echo $?)" "1"


# =============================================================================
printf '\n\033[1m== 21. 검증 게이트 — 지어낸 로그를 잡는가 ==\033[0m\n'
# 게이트 3항만 판정을 막는다. 목적은 하나 — 머신이나 에이전트가 만들어 낸 콘솔이
# 진짜 부팅으로 읽히지 않게 하는 것. 통과만 확인하면 언제나 통과하는 검문과 같다.

VG=$(new_ws vgate); mkdir -p "$VG/03_bootloader"
printf 'S-BOOT # \x00Following commands are supported\x00UFS link established\x00' > "$VG/03_bootloader/fw.bin"
CLEAN_MACHINE='static void w(void){ qemu_chr_fe_write_all(&s->chr,&b,1); }'
GOOD_CONSOLE='S-BOOT # \nFollowing commands are supported\nUFS link established\n'

vg_verdict() {   # -> VERIFIED | UNVERIFIED
  python3 "$S/verify.py" "$VG" --target F2 --container "$VG/03_bootloader/fw.bin" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])'
}
vg_gate() {      # $1 = 게이트 번호 -> True | False
  python3 "$S/verify.py" "$VG" --target F2 --container "$VG/03_bootloader/fw.bin" 2>/dev/null \
    | python3 -c "import json,sys;print({i['n']:i['pass'] for i in json.load(sys.stdin)['items']}[$1])"
}

# ① 정상 — 콘솔이 펌웨어에서 나왔고 머신은 깨끗하다
printf "$GOOD_CONSOLE" > "$VG/07_logs/console_1.txt"
printf '%s\n' "$CLEAN_MACHINE" > "$VG/06_machine/machine_full.c"
chk "정상 실행은 VERIFIED"       "$(vg_verdict)" "VERIFIED"

# ② 머신이 콘솔 문자열을 직접 출력한다
printf 'static const char *p = "Following commands are supported";\n' > "$VG/06_machine/machine_full.c"
chk "머신의 문자열 출력을 잡음"   "$(vg_gate 1)" "False"
chk "  → 판정이 막힘"            "$(vg_verdict)" "UNVERIFIED"

# ③ 콘솔에 펌웨어에 없는 줄이 섞였다 (에이전트가 지어냄)
printf '%s\n' "$CLEAN_MACHINE" > "$VG/06_machine/machine_full.c"
{ printf "$GOOD_CONSOLE"
  for i in $(seq 1 40); do echo "FabricatedKernelBanner$i totally invented output"; done; } > "$VG/07_logs/console_1.txt"
chk "지어낸 콘솔 줄을 잡음"       "$(vg_gate 2)" "False"

# ④ 머신이 자기 수신 버퍼를 채운다 (자기 자신과 대화)
printf "$GOOD_CONSOLE" > "$VG/07_logs/console_1.txt"
printf 'static void go(void){ rx_seed(s, "help"); }\n' > "$VG/06_machine/machine_full.c"
chk "자가 주입을 잡음"           "$(vg_gate 3)" "False"

# ⑤ 머신 소스가 없다 — 검사하지 못한 것은 통과가 아니다.
#    0.20.0 까지 verify.py 가 machine_full.c 를 못 찾아 소스 0 개로 공허하게 통과했다.
rm -f "$VG/06_machine/machine_full.c"
chk "소스 0 개는 통과가 아님"     "$(vg_gate 1)" "False"

# ⑥ 런타임 조립분(%d 치환값)은 미발견으로 세지 않는다
printf '%s\n' "$CLEAN_MACHINE" > "$VG/06_machine/machine_full.c"
{ printf "$GOOD_CONSOLE"; for i in $(seq 1 200); do printf '[0: %06d] 0x%08x\n' "$i" "$i"; done; } > "$VG/07_logs/console_1.txt"
chk "런타임 수치는 대조 대상 아님" "$(vg_gate 2)" "True"

# ⑦ MemoryRegion 이름은 콘솔 출력이 아니다 (rehost.itmon%d 오탐 회귀)
printf "$GOOD_CONSOLE" > "$VG/07_logs/console_1.txt"
printf 'static void n(void){ snprintf(nm,8,"rehost.itmon%%d",i); memory_region_init_io(&r,NULL,&o,s,"itmon",4); }\n' \
  > "$VG/06_machine/machine_full.c"
chk "객체 이름은 오탐이 아님"     "$(vg_gate 1)" "True"


# =============================================================================
printf '\n\033[1m== 22. 매체 합성과 실행 실패 판정 ==\033[0m\n'

# --- sparse 이미지는 raw 로 풀지 않으면 정지한다 -----------------------------
# 그대로 복사하면 부트로더가 파티션을 파싱하지 못하고, 그 결함은 한참 뒤 AVB 실패로
# 나타나 원인을 찾기 어렵다. 조용히 잘못된 바이트를 쓰는 것보다 멈추는 편이 낫다.
BW=$(new_ws medium)
printf '\x3a\xff\x26\xed' > "$BW/fw/system.img"; head -c 4096 /dev/zero >> "$BW/fw/system.img"
BJ=$(python3 "$S/build_lu.py" "$BW" --out "$BW/fw/lu0.img" 2>/dev/null)
chk "sparse 를 감지해 정지"  "$(echo "$BJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])')" "False"
echo "$BJ" | grep -q 'sparse'
chk "  이유를 sparse 로 밝힘"  "$?" "0"

# --- 커맨드라인을 PARAM 파티션에 심는다 --------------------------------------
# 부트로더가 console=ram 을 고르면 커널이 완벽히 떠도 시리얼에 한 줄도 안 나온다.
# PARAM 기록은 부트로더의 정상 경로를 쓰므로 우회가 아니다.
CW2=$(new_ws cmdline)
mkdir -p "$CW2/02_unpacked"
head -c 8192 /dev/zero > "$CW2/02_unpacked/param.bin"
head -c 4096 /dev/urandom > "$CW2/fw/boot.img"
printf '{"default":"console=ram","uart":"console=ttySAC0,115200n8 earlycon=exynos4210,mmio32,0x10840000"}\n' \
  > "$CW2/cmdline_plan.json"
CJ=$(python3 "$S/build_lu.py" "$CW2" --out "$CW2/fw/lu0.img" 2>/dev/null)
chk "커맨드라인을 기록함"      "$(echo "$CJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cmdline_written"])')" "True"
strings "$CW2/fw/lu0.img" 2>/dev/null | grep -q 'earlycon=exynos4210'
chk "  매체 안에 실제로 존재"  "$?" "0"

# 계획이 있어도 PARAM 이 없으면 심지 않고, 그 사실을 밝힌다
CW3=$(new_ws cmdline_noparam)
head -c 4096 /dev/urandom > "$CW3/fw/boot.img"
cp "$CW2/cmdline_plan.json" "$CW3/cmdline_plan.json"
NJ=$(python3 "$S/build_lu.py" "$CW3" --out "$CW3/fw/lu0.img" 2>/dev/null)
chk "PARAM 없으면 기록 안 함"  "$(echo "$NJ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cmdline_written"])')" "False"
echo "$NJ" | grep -q 'warning_cmdline'
chk "  못 심었음을 보고"       "$?" "0"

# --- 총 크기가 바뀌면 경고한다 ----------------------------------------------
# 30 MiB 만 늘려도 부트로더가 GPT 를 재작성하고 신규 프로비저닝으로 간주해 전원을 내린다.
SW=$(new_ws medium_size)
head -c 4096 /dev/urandom > "$SW/fw/boot.img"
printf '{"block_size":4096,"total_bytes":1,"partitions":[{"name":"boot","source":"fw/boot.img"}]}\n' \
  > "$SW/lu_manifest.json"
SJ=$(python3 "$S/build_lu.py" "$SW" --out "$SW/fw/lu0.img" 2>/dev/null)
echo "$SJ" | grep -q 'warning_size'
chk "총 크기 변화를 경고"      "$?" "0"

# --- 콘솔이 나온 뒤의 비정상 종료는 환경이 아니라 머신 결함이다 ---------------
# QEMU 가 assert 로 죽어도 게스트가 이미 출력을 냈다면 실행은 된 것이다. 이걸
# BLOCKED_ENV 로 처리하면 담당이 배정되지 않아 손으로 고쳐야 한다 (blk_set_perm 사례).
FV=$(mktemp -d)
printf 'qemu: block/io.c:2006: Assertion `child->perm & BLK_PERM_WRITE` failed.\n' > "$FV/err.txt"
printf 'trace\n' > "$FV/log.txt"
verdict() {   # $1=rc $2=console_bytes [$3=trace파일] -> "failed fault"
  ( . "$S/fingerprint_lib.sh"
    fp_run_verdict "$1" "${3:-$FV/log.txt}" "$2" "$FV/err.txt"
    echo "$FP_RUN_FAILED ${FP_RUN_FAULT:-0}" )
}
: > "$FV/empty.log"
chk "정상 종료는 둘 다 0"        "$(verdict 0 1000)"   "0 0"
chk "timeout(124) 도 실패 아님"  "$(verdict 124 1000)" "0 0"
chk "콘솔 있는 assert → 머신 결함" "$(verdict 250 596865)" "0 1"
# 트레이스도 콘솔도 0 이어야 "실행된 적 없음"이다. 트레이스가 있으면 QEMU 는 돈 것이다.
chk "콘솔·트레이스 0 → 환경 문제" "$(verdict 250 0 "$FV/empty.log")" "1 0"
chk "트레이스만 있어도 실행됨"    "$(verdict 250 0)"                  "0 1"
rm -rf "$FV"

# --- 매체는 기본이 snapshot 이다 --------------------------------------------
# 부트로더가 PARAM·DDI 에 실제로 쓰므로, 그대로 두면 회차가 이전 회차의 디스크
# 상태를 물려받아 지문 비교가 오염된다.
grep -q 'snapshot=on' "$S/run_full.sh"
chk "매체를 snapshot 으로 염"   "$?" "0"


# =============================================================================
printf '\n\033[1m== 23. 옛 버전 캐시 강제 정리 · push 게이트 ==\033[0m\n'
# 캐시는 버전마다 폴더가 남는다. 옛 폴더가 있으면 옛 스킬·에이전트가 다시 로드될 수
# 있고, 그러면 회차·로그·판정이 전부 옛 규칙을 따른다. 실제로 0.2.0 과 0.17.0 이
# 남아 있고 세션이 0.17.0 을 로드한 상태가 관측됐다 — 저장소가 0.24.0 인데도.

PC="$ROOT/purge"; mkdir -p "$PC/cache/mk/sboot-rehost"/{0.2.0,0.17.0,9.9.9} "$PC/other/sboot-rehost/1.0.0"
mkdir -p "$PC/cache/other-plugin/1.0.0"
printf '{"plugins":[{"name":"sboot-rehost","version":"0.17.0"}]}\n' > "$PC/reg.json"

purge() { CACHE_ROOT="$PC/cache" REGISTRY="$PC/reg.json" bash "$S/purge_cache.sh" "$@" 2>/dev/null; }
J=$(purge --keep 9.9.9 --dry-run)
chk "최신만 남기기로 판정"    "$(echo "$J" | python3 -c 'import json,sys;print(json.load(sys.stdin)["keep"])')" "9.9.9"
chk "옛 버전 2개를 지울 대상"  "$(echo "$J" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["removed"]))')" "2"
chk "dry-run 은 실제로 안 지움" "$([ -d "$PC/cache/mk/sboot-rehost/0.2.0" ] && echo yes)" "yes"

# 세션이 옛 버전을 로드 중이면 막아야 한다 — 캐시를 지워도 로드된 것은 안 바뀐다
chk "옛 버전 로드 시 종료코드 1" \
    "$(CACHE_ROOT="$PC/cache" REGISTRY="$PC/reg.json" bash "$S/purge_cache.sh" --keep 9.9.9 --dry-run >/dev/null 2>&1; echo $?)" "1"

# 실제 삭제
purge --keep 9.9.9 >/dev/null
chk "옛 버전이 실제로 지워짐"  "$([ -d "$PC/cache/mk/sboot-rehost/0.2.0" ] || echo gone)" "gone"
chk "최신은 남음"             "$([ -d "$PC/cache/mk/sboot-rehost/9.9.9" ] && echo kept)" "kept"
chk "다른 플러그인은 안 건드림" "$([ -d "$PC/cache/other-plugin/1.0.0" ] && echo safe)" "safe"

# 세션이 최신이면 통과한다
printf '{"plugins":[{"name":"sboot-rehost","version":"9.9.9"}]}\n' > "$PC/reg.json"
chk "최신 로드 시 종료코드 0" \
    "$(CACHE_ROOT="$PC/cache" REGISTRY="$PC/reg.json" bash "$S/purge_cache.sh" --keep 9.9.9 >/dev/null 2>&1; echo $?)" "0"

# --- push 전 버전 검문 -------------------------------------------------------
# check_release.sh 는 사람이 부를 때만 돌았다. 0.19.0 이 그렇게 새어나갔으므로
# 잊을 수 없는 자리(pre-push)에 둔다.
[ -x "$REPO/scripts/git-hooks/pre-push" ]
chk "pre-push 훅이 실행 가능"  "$?" "0"
grep -q 'check_release.sh' "$REPO/scripts/git-hooks/pre-push"
chk "  훅이 릴리스 검문을 부름" "$?" "0"
grep -q 'core.hooksPath' "$REPO/scripts/install_git_hooks.sh"
chk "설치 스크립트가 있음"     "$?" "0"


# =============================================================================
printf '\n\033[1m== 24. 스테이지 경계: 평문 앞부분을 암호화에 흘려보내지 않는다 ==\033[0m\n'
# 옛 규칙은 스텁-스텁 구간의 암호화 비율이 60% 를 넘으면 구간 전체를 encrypted 로
# 표시했다. Exynos 9820 에서 BL1(20 KB 평문, 진입 스텁 0x10)이 EPBL(38 KB 암호화)과
# 한 구간이라 65.5% 가 되어 함께 버려졌고, 리셋 PC 가 BL33 으로 밀렸다.
# 그러면 "첫 스테이지부터 연속 실행"이 성립하지 않는다.

SMW="$ROOT/stagemap"; mkdir -p "$SMW"
python3 - "$SMW/fake.bin" <<'PYGEN'
import random, struct, sys
def stub():
    return (struct.pack("<I", 0x14000001) + struct.pack("<I", 0x10000000) +
            struct.pack("<I", 0xD5384241) + struct.pack("<I", 0xD51EC000))
def plain(n, seed):
    rnd = random.Random(seed); b = bytearray()
    toks = [b"Pass: Loading EPBL\x00", b"DMC\x00", b"Samsung S-Boot 4.0\x00"]
    while len(b) < n:
        b += rnd.choice(toks) if rnd.random() < 0.25 else struct.pack("<I", 0xA9BF7BFD)
    return bytes(b[:n])
def cipher(n, seed):
    rnd = random.Random(seed); return bytes(rnd.randrange(256) for _ in range(n))
# G977N 배치: BL1 평문 20 KB → EPBL 암호화 38 KB → BL2 평문
img = stub() + plain(0x5000 - 16, 1) + cipher(0xe800 - 0x5000, 2) \
    + stub() + plain(0x30000 - 0xe800 - 16, 3)
open(sys.argv[1], "wb").write(img)
PYGEN

python3 "$S/stage_map.py" "$SMW/fake.bin" --out "$SMW/sm.json" --quiet >/dev/null 2>&1
SM="$SMW/sm.json"
q() { python3 -c "import json;d=json.load(open('$SM'));$1" 2>/dev/null; }

chk "평문 앞부분이 exec 로 남음" \
    "$(q 'print(d["stages"][0]["state"])')" "exec"
chk "  그 범위가 암호화 시작 전까지" \
    "$(q 'print(hex(d["stages"][0]["file_range"][1]))')" "0x5000"
chk "암호화 구간은 따로 분리" \
    "$(q 'print(d["stages"][1]["state"])')" "encrypted"
chk "첫 실행 가능 스테이지가 파일 선두" \
    "$(q 'print([s["file_range"][0] for s in d["stages"] if s["state"]=="exec"][0])')" "0"
chk "진입 스텁이 그 스테이지에 붙음" \
    "$(q 'print(d["stages"][0]["entry_pc_file_offset"])')" "0"
chk "건너뛸 스테이지는 하나뿐" \
    "$(q 'print(sum(1 for s in d["stages"] if s["state"]!="exec"))')" "1"

# 반대 경우: 구간이 암호화로 시작하면 쪼개지 않는다
python3 - "$SMW/enc_first.bin" <<'PYGEN'
import random, struct, sys
def stub():
    return (struct.pack("<I", 0x14000001) + struct.pack("<I", 0x10000000) +
            struct.pack("<I", 0xD5384241) + struct.pack("<I", 0xD51EC000))
def plain(n, seed):
    rnd = random.Random(seed); b = bytearray()
    while len(b) < n: b += struct.pack("<I", 0xA9BF7BFD)
    return bytes(b[:n])
def cipher(n, seed):
    rnd = random.Random(seed); return bytes(rnd.randrange(256) for _ in range(n))
open(sys.argv[1], "wb").write(cipher(0x8000, 9) + stub() + plain(0x8000 - 16, 3))
PYGEN
python3 "$S/stage_map.py" "$SMW/enc_first.bin" --out "$SMW/sm2.json" --quiet >/dev/null 2>&1
chk "암호화로 시작하면 쪼개지 않음" \
    "$(python3 -c "import json;d=json.load(open('$SMW/sm2.json'));print(d['stages'][0]['state'])" 2>/dev/null)" "encrypted"


# =============================================================================
printf '\n\033[1m== 25. 트레이스 용량 (디스크를 채워 기계를 죽이지 않는다) ==\033[0m\n'
# `-d int,in_asm,nochain` 은 폴트 루프에서 회차당 10~12 GB 를 쓴다. 15회차가 281 GB
# 디스크를 채우고 WSL 이 재시작된 적이 있다. 정작 파이프라인이 읽는 것은 넷뿐이다 —
# 예외 개수, 최초 예외 블록, 마지막 FAR/ELR, 스테이지 진입 PC 의 등장 순서.

TFW="$ROOT/tracefilter"; mkdir -p "$TFW"
python3 - "$TFW/big.log" <<'PYGEN'
import sys
w = open(sys.argv[1], "w")
w.write("Taking exception 4 [Data Abort]\n")
w.write("...ESR 0x25/0x96000046 FAR 0x12860010 ELR 0x9021f3dc\n")
w.write("0xc9000000:  stp x29, x30, [sp, #-16]!\n")
for i in range(20000):
    w.write("0x%x:  nop\n" % (0x91000000 + i * 4))
w.write("0x02100000:  mrs x1, currentel\n")
for i in range(20000):
    w.write("0x%x:  nop\n" % (0x92000000 + i * 4))
w.write("Taking exception 4 [Data Abort]\n")
w.write("...FAR 0x12869999 ELR 0x90210000\n")
w.close()
PYGEN

python3 "$S/trace_filter.py" --out "$TFW/small.log" --stats "$TFW/st.json" \
    --watch 0xc9000000,0x02100000 < "$TFW/big.log"

BIG=$(wc -c < "$TFW/big.log" | tr -d ' ')
SMALL=$(wc -c < "$TFW/small.log" | tr -d ' ')
[ "$SMALL" -lt $((BIG / 100)) ]
chk "1% 미만으로 줄어듦"          "$?" "0"

tj() { python3 -c "import json;print($1)" 2>/dev/null; }
chk "예외 개수는 원본 전체 기준"  "$(tj "json.load(open('$TFW/st.json'))['exceptions']")" "2"
chk "감시 PC 를 등장 순서대로"    \
    "$(tj "','.join(e['pc'] for e in json.load(open('$TFW/st.json'))['stage_entries_seen'])")" \
    "0xc9000000,0x02100000"

# 최초 예외 블록이 살아 있어야 fp_origin 이 원인을 뽑는다
( . "$S/fingerprint_lib.sh"; fp_origin "$TFW/small.log" "$TFW/origin.txt"
  echo "$FP_ORIGIN_TYPE|$FP_ORIGIN_ESR|$FP_ORIGIN_FAR" ) > "$TFW/orig.txt"
chk "최초 예외를 그대로 뽑음" "$(cat "$TFW/orig.txt")" \
    "Data Abort|0x25/0x96000046|0x12860010"

# 마지막 FAR/ELR 은 기록용으로 꼬리에 남아야 한다
grep -q '0x12869999' "$TFW/small.log"
chk "마지막 FAR 이 꼬리에 남음"   "$?" "0"

# 입력이 없으면 빈 파일이어야 한다. "트레이스·콘솔 0바이트"가 QEMU 가 아예 실행되지
# 않았다는 신호이고, 여기에 안내 줄을 쓰면 환경 실패가 펌웨어 판정으로 둔갑한다.
printf '' | python3 "$S/trace_filter.py" --out "$TFW/empty.log" --stats "$TFW/e.json"
chk "빈 입력이면 빈 파일"        "$(wc -c < "$TFW/empty.log" | tr -d ' ')" "0"

# 디스크가 부족하면 회차를 시작하지 않는다
DW=$(new_ws diskguard); printf 'x' > "$DW/bl.bin"
printf '### 우회1\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$DW/06_machine/bypasses.md"
RC=$(MIN_FREE_MB=999999999 QEMU="$BIN/fake-qemu" bash "$S/run_full.sh" \
       "$DW" m "$DW/bl.bin" help 1 shell >/dev/null 2>&1; echo $?)
chk "디스크 부족이면 시작 안 함"  "$RC" "3"


# =============================================================================
# 영역별 추가 시험 (tests/parts/*.sh) - 각 파일은 단독 실행도 된다
for _part in "$REPO"/tests/parts/[a-z]*.sh; do
  [ -f "$_part" ] || continue
  . "$_part"
done

printf '\n\033[1m════════ 결과: %d 통과 / %d 실패 ════════\033[0m\n' "$PASS" "$FAIL"
echo "작업 폴더: $ROOT"
[ "$FAIL" -eq 0 ]
