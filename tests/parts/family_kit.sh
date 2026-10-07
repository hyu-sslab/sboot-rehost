#!/usr/bin/env bash
# tests/parts/family_kit.sh - 계열 자료 묶음: family_kit.py, 프로필의 평면 키, 계열 지식표 형식,
# registry 의 담당 등록, stage_map.py 의 stage_hints 읽기.
#
# 실제 MediaTek 이미지는 쓰지 않는다. 마지막 절만 SBOOT_MT_FIXTURES 가 lk-verified.img 가 든
# 폴더를 가리킬 때 실행한다 (저장소에 복사하지 않는다).
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

FK="$S/family_kit.py"
FT="$ROOT/family_kit"; rm -rf "$FT"; mkdir -p "$FT"
export PYTHONDONTWRITEBYTECODE=1        # 시험이 저장소 안에 .pyc 를 남기지 않게

# 검사용 파이썬 도우미는 임시 폴더에 만든다 (맨 아래에서 폴더째 지운다)
cat > "$FT/hints_check.py" <<'PY'
import importlib.util, json, os, re, sys
sys.dont_write_bytecode = True
scripts, path, name = sys.argv[1:4]
try:
    spec = importlib.util.spec_from_file_location("stage_map", os.path.join(scripts, "stage_map.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    hints = m.load_profile_hints(name)
except Exception as exc:                     # noqa: BLE001 - 시험이라 사유를 그대로 낸다
    print(f"IMPORT_FAIL {exc.__class__.__name__}: {exc}"); sys.exit(0)
text = open(path, encoding="utf-8").read()
block = re.search(r"^stage_hints:\s*$(.*?)(?=^\S|\Z)", text, re.M | re.S).group(1)
want = {}
for line in block.splitlines():
    mm = re.match(r"\s+([a-z0-9_]+):\s*(\[.*\])\s*$", line)
    if mm: want[mm.group(1)] = json.loads(mm.group(2))
bad = [k for k, v in want.items() if hints.get(k) != v]
print("OK" if want and not bad and len(want) == 7 else f"MISMATCH keys={sorted(want)} bad={bad}")
PY
cat > "$FT/hints_override.py" <<'PY'
import importlib.util, os, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("stage_map", os.path.join(sys.argv[1], "stage_map.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
h = m.load_profile_hints("mediatek")
print("OK" if h != m.DEFAULT_HINTS and "sspm" in h["power_fw"] and "bl31" in h["el3_monitor"] else "DEFAULTS")
PY
cat > "$FT/table_format.py" <<'PY'
import os, re, sys
kdir = sys.argv[1]
def tables(path):
    """파일 안의 표들: [(header_cells, [data_rows])]. 셀은 이스케이프되지 않은 | 로 나눈다."""
    out, cur = [], None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.startswith("|"):
            cur = None; continue
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
        if cur is None:
            cur = [cells, []]; out.append(cur); continue
        if all(re.fullmatch(r":?-+:?", c) for c in cells): continue    # 구분선
        cur[1].append(cells)
    return out
uni = tables(os.path.join(kdir, "faults_unified.md"))
mt = tables(os.path.join(kdir, "faults_mediatek.md"))
uni_counts = {len(h) for h, _ in uni}
problems = []
if not mt: problems.append("표 없음")
names = []
for h, rows in mt:
    if len(h) not in uni_counts: problems.append(f"열 수 {len(h)} 가 faults_unified.md 에 없는 형식")
    if h[0] != "name": problems.append(f"첫 열이 name 이 아님: {h[0]}")
    for r in rows:
        if len(r) != len(h): problems.append(f"{r[0]}: 열 {len(r)} != {len(h)}")
        m = re.fullmatch(r"`([a-z0-9_]+)`", r[0])
        if not m: problems.append(f"이름 칸이 `snake_case` 가 아님: {r[0]}")
        else: names.append(m.group(1))
if len(names) != len(set(names)): problems.append("이름 중복")
print("OK %d" % len(names) if not problems else "; ".join(problems))
PY
cat > "$FT/registry_check.py" <<'PY'
import re, sys, os
root = sys.argv[1]
reg = open(os.path.join(root, "fixers/registry.yaml"), encoding="utf-8").read()
reg_nc = "\n".join(l.split("#", 1)[0] if not l.lstrip().startswith("#") else "" for l in reg.splitlines())

def block(name):
    m = re.search(r"^  %s:\n(.*?)(?=^  \S|^\S|\Z)" % re.escape(name), reg_nc, re.M | re.S)
    return m.group(1) if m else ""
def handles(name):
    b = block(name)
    m = re.search(r"^    handles:(.*?)(?=^    [a-z_]+:|\Z)", b, re.M | re.S)
    return set(re.findall(r"[A-Za-z0-9_]+", m.group(1))) if m else set()
build = set(re.findall(r"[A-Za-z0-9_]+", (re.search(r"^build_layer:\s*\[(.*?)\]", reg_nc, re.M | re.S) or [None, ""])[1]))

out = []
st = handles("fixer-storage")
need = {"msdc_dma_rerun", "msdc_basic_len", "msdc_write_lost", "emmc_36bit_addr", "emmc_wp_group"}
out.append("storage_new=%s" % ("OK" if need <= st else "MISSING:" + ",".join(sorted(need - st))))
out.append("storage_old=%s" % ("OK" if {"poll_stall", "partition_table_unavailable"} <= st else "LOST"))
out.append("storage_knowledge=%s" % ("OK" if "knowledge/faults_storage.md" in block("fixer-storage") else "NO"))
order = [reg.find(k) for k in ("  fixer-general:", "unmapped_policy:")]
out.append("general_in_fixers=%s" % ("OK" if 0 < order[0] < order[1] else "NO"))

# faults_storage.md 의 eMMC 절 이름은 전부 fixer-storage 가 담당
fs = open(os.path.join(root, "knowledge/faults_storage.md"), encoding="utf-8").read()
sec = re.search(r"^## eMMC controller.*?(?=^## )", fs, re.M | re.S)
emmc, in_names = set(), False       # `| name |` 표의 행만 (마일스톤 표는 제외)
for line in (sec.group(0).splitlines() if sec else []):
    if line.startswith("| name |"): in_names = True; continue
    if not line.startswith("|"): in_names = False; continue
    m = re.match(r"^\| `([a-z0-9_]+)` \|", line)
    if in_names and m: emmc.add(m.group(1))
out.append("emmc_rows=%d" % len(emmc))
out.append("emmc_owned=%s" % ("OK" if emmc and emmc <= st else "MISSING:" + ",".join(sorted(emmc - st))))

# faults_mediatek.md 의 담당 칸 ↔ registry
bad = []
for line in open(os.path.join(root, "knowledge/faults_mediatek.md"), encoding="utf-8"):
    cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
    if len(cells) != 5 or not re.fullmatch(r"`[a-z0-9_]+`", cells[0]): continue
    name, owner = cells[0].strip("`"), cells[3]
    m = re.match(r"`(fixer-[a-z0-9-]+)`", owner)
    if m:
        if name not in handles(m.group(1)): bad.append(f"{name} 가 {m.group(1)} handles 에 없음")
    elif owner.startswith("**build layer"):
        if name not in build: bad.append(f"{name} 가 build_layer 에 없음")
    else:   # 담당 없음: 어느 fixer 의 handles 에도 있으면 안 된다
        if any(name in handles(f) for f in re.findall(r"^  (fixer-[a-z0-9-]+):", reg_nc, re.M)):
            bad.append(f"{name} 은 담당 없음인데 handles 에 있음")
out.append("mediatek_rows_registered=%s" % ("OK" if not bad else "; ".join(bad)))
print("\n".join(out))
PY

# JSON 한 필드를 꺼낸다 (문자열은 그대로, 나머지는 JSON 으로)
jget() { python3 -c '
import json, sys
d = json.load(sys.stdin); v = d.get(sys.argv[1], "<없음>")
print(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))' "$1"; }

hdr "family_kit.py - 세 프로필"
for fam in mediatek exynos generic; do
  OUT=$(cd / && python3 "$FK" "$fam"); RC=$?
  chk "$fam: 종료코드 0"           "$RC" "0"
  chk "$fam: family 필드"          "$(printf '%s' "$OUT" | jget family)" "$fam"
  chk "$fam: 프로필 경로"          "$(printf '%s' "$OUT" | jget profile)" "profiles/$fam.yaml"
  chk "$fam: 가리키는 파일이 전부 있음" "$(printf '%s' "$OUT" | jget missing)" "<없음>"
done
OUT=$(python3 "$FK" mediatek)
chk "mediatek: 계열 지식표"        "$(printf '%s' "$OUT" | jget knowledge)" '["knowledge/faults_mediatek.md"]'
chk "mediatek: 진행 가이드"        "$(printf '%s' "$OUT" | jget runbook)" "knowledge/runbook_mediatek.md"
for fam in exynos generic; do
  OUT=$(python3 "$FK" "$fam")
  chk "$fam: 계열 지식표 없음(빈 목록)" "$(printf '%s' "$OUT" | jget knowledge)" "[]"
  chk "$fam: 진행 가이드 없음(빈 문자열)" "$(printf '%s' "$OUT" | jget runbook)" ""
done
OUT=$(python3 "$FK" "$REPO/profiles/mediatek.yaml")
chk "경로로 읽어도 같은 결과"      "$(printf '%s' "$OUT" | jget knowledge)" '["knowledge/faults_mediatek.md"]'
chk "플러그인 안 경로는 상대로 표기" "$(printf '%s' "$OUT" | jget profile)" "profiles/mediatek.yaml"

hdr "family_kit.py - 합성 프로필, 대체, 오류"
# 키가 없는 프로필
printf 'name: bare\ndescription: no kit keys\nchain:\n  container_format: flat\n' > "$FT/bare.yaml"
OUT=$(python3 "$FK" "$FT/bare.yaml"); RC=$?
chk "키 없음: 종료코드 0"          "$RC" "0"
chk "키 없음: 빈 지식표"           "$(printf '%s' "$OUT" | jget knowledge)" "[]"
chk "키 없음: 빈 가이드"           "$(printf '%s' "$OUT" | jget runbook)" ""
chk "키 없음: family 는 name 값"   "$(printf '%s' "$OUT" | jget family)" "bare"
# 키가 있는 프로필: 따옴표 · 줄 끝 주석 · 같은 이름의 들여쓴 키(읽지 않아야 한다)
cat > "$FT/full.yaml" <<'YAML'
name: synth
knowledge: ["knowledge/a.md", 'knowledge/b.md' ,knowledge/c.md]   # 줄 끝 주석
runbook: "knowledge/r.md"   # 줄 끝 주석
kernel:
  knowledge: [decoy.md]
  runbook: decoy_runbook.md
YAML
OUT=$(python3 "$FK" "$FT/full.yaml"); RC=$?
chk "키 있음: 종료코드 0"          "$RC" "0"
chk "키 있음: 목록 3개(따옴표·주석 처리)" "$(printf '%s' "$OUT" | jget knowledge)" '["knowledge/a.md", "knowledge/b.md", "knowledge/c.md"]'
chk "키 있음: 가이드(들여쓴 같은 이름은 무시)" "$(printf '%s' "$OUT" | jget runbook)" "knowledge/r.md"
chk "키 있음: 플러그인에 없는 파일을 missing 으로"  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["missing"]))')" "4"
# CRLF 로 저장된 프로필
printf 'name: crlf\r\nknowledge: [knowledge/x.md]\r\nrunbook: knowledge/y.md\r\n' > "$FT/crlf.yaml"
OUT=$(python3 "$FK" "$FT/crlf.yaml")
chk "CRLF 프로필도 같은 값"        "$(printf '%s' "$OUT" | jget runbook)" "knowledge/y.md"
# 모르는 계열은 generic 으로 대체하고 note 를 남긴다
OUT=$(python3 "$FK" no_such_family); RC=$?
chk "없는 계열: 종료코드 0"        "$RC" "0"
chk "없는 계열: generic 으로 대체" "$(printf '%s' "$OUT" | jget family)" "generic"
chk "없는 계열: note 가 있음"      "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print("note" in json.load(sys.stdin))')" "True"
OUT=$(python3 "$FK" "bad name"); RC=$?
chk "이상한 이름도 generic 대체(경로 이탈 없음)" "$RC $(printf '%s' "$OUT" | jget family)" "0 generic"
# 읽지 못하는 프로필은 종료코드 2 (stdout 에는 같은 모양의 JSON + error)
OUT=$(python3 "$FK" "$FT/none.yaml" 2>/dev/null); RC=$?
chk "없는 파일: 종료코드 2"        "$RC" "2"
chk "없는 파일: error 필드가 있음" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print("error" in json.load(sys.stdin))')" "True"
mkdir -p "$FT/adir.yaml"
python3 "$FK" "$FT/adir.yaml" >/dev/null 2>&1; chk "디렉터리: 종료코드 2" "$?" "2"
printf '\xff\xfe\x00bad' > "$FT/bad_utf8.yaml"
python3 "$FK" "$FT/bad_utf8.yaml" >/dev/null 2>&1; chk "인코딩 오류: 종료코드 2" "$?" "2"
python3 "$FK" >/dev/null 2>&1; chk "인자 없음: 종료코드 1" "$?" "1"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$FK"
chk "family_kit.py 문법"           "$?" "0"

hdr "프로필의 평면 키가 가리키는 파일"
for f in "$REPO"/profiles/*.yaml; do
  n=$(basename "$f" .yaml)
  chk "$n: knowledge: 와 runbook: 가 0열 한 줄" \
      "$(grep -cE '^(knowledge:[ ]*\[.*\]|runbook:)' "$f")" "2"
  OUT=$(python3 "$FK" "$f")
  # 이름이 가리키는 파일마다 실제로 있는지
  MISS=$(printf '%s' "$OUT" | python3 -c '
import json, os, sys
d = json.load(sys.stdin); root = sys.argv[1]
files = d["knowledge"] + ([d["runbook"]] if d["runbook"] else [])
print(" ".join(p for p in files if not os.path.isfile(os.path.join(root, p))))' "$REPO")
  chk "$n: 가리키는 파일이 전부 있음" "$MISS" ""
done
if command -v ruby >/dev/null 2>&1; then
  for f in "$REPO"/profiles/*.yaml; do
    ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$f" >/dev/null 2>&1
    chk "$(basename "$f"): 엄격한 YAML 로 읽힌다" "$?" "0"
  done
else
  echo "  (ruby 없음 - 엄격한 YAML 검사는 건너뜀)"
fi

hdr "stage_map.py 가 stage_hints 를 그대로 읽는다"
for n in mediatek exynos generic; do
  RES=$(python3 "$FT/hints_check.py" "$S" "$REPO/profiles/$n.yaml" "$n")
  chk "$n: 일곱 가지 힌트를 한 줄씩 읽음" "$RES" "OK"
done
RES=$(python3 "$FT/hints_override.py" "$S")
chk "mediatek 힌트가 기본값을 덮어씀" "$RES" "OK"

hdr "지식표 행 형식 (faults_mediatek.md ↔ faults_unified.md)"
RES=$(python3 "$FT/table_format.py" "$REPO/knowledge")
chk "faults_mediatek.md 의 표가 faults_unified.md 와 같은 열 수" "${RES%% *}" "OK"
chk "faults_mediatek.md 행 수(정지점 이름)"  "${RES#OK }" "7"

hdr "registry.yaml - 담당 등록과 지식표의 일치"
RES=$(python3 "$FT/registry_check.py" "$REPO")
for key in storage_new storage_old storage_knowledge general_in_fixers emmc_owned mediatek_rows_registered; do
  chk "registry: $key" "$(printf '%s\n' "$RES" | sed -n "s/^$key=//p")" "OK"
done
EMMC_ROWS=$(printf '%s\n' "$RES" | sed -n 's/^emmc_rows=//p')
chk "faults_storage.md eMMC 절의 행 수" "$EMMC_ROWS" "6"

hdr "에이전트 프롬프트에 계열 자료가 연결됨"
# 여섯 전문가와 마지막 수단 fixer 가 계열 자료를 읽으라는 문장은 파이프라인이 모든 fixer 프롬프트에 붙이는 FIXER_RULES(workflows/pipeline.js)
# 에 한 번만 있다. 에이전트 파일에는 그 규칙이 파이프라인 프롬프트로 온다는 한 줄만 남는다 (규칙이 사라진 것으로 읽히지 않게).
# FIXER_RULES 의 글은 tests/pipeline_sim/fixer_rules.js 가 pipeline.js 에서 그 상수만 잘라 평가해 낸다 (node 가 없으면 이 문구 시험은 건너뛴다).
NEU_FR_FILE="$FT/fixer_rules.txt"; : > "$NEU_FR_FILE"
NEU_NODE=no
if command -v node >/dev/null 2>&1; then NEU_NODE=yes; node "$REPO/tests/pipeline_sim/fixer_rules.js" "$REPO" > "$NEU_FR_FILE" 2>/dev/null; fi
NEU_FR=$(tr '\n' ' ' < "$NEU_FR_FILE" | tr -s ' ')
if [ "$NEU_NODE" = yes ]; then
  chk "pipeline.js 의 FIXER_RULES 를 읽었다 (한 상수, 다른 이름을 참조하지 않는다)" "$([ -s "$NEU_FR_FILE" ] && echo yes || echo no)" "yes"
  case "$NEU_FR" in *'`Family knowledge:`'*'`Runbook:`'*'as absolute paths - open them as given'*'Read them before you act'*) NEU_FRV=yes ;; *) NEU_FRV=no ;; esac
  chk "FIXER_RULES: 계열 지식·가이드 줄을 절대 경로로 열고 행동 전에 읽으라는 문장 (fixer 일곱에 한 번)" "$NEU_FRV" "yes"
else
  ok "SKIP node 가 없어 FIXER_RULES 문구 시험을 건너뜁니다"
fi
for a in fixer-memory fixer-el3 fixer-bootflow fixer-kernel fixer-storage fixer-general fixer-secureboot; do
  AN=$(tr '\n' ' ' < "$REPO/agents/$a.md" | tr -s ' ')
  case "$AN" in *'arrive with the pipeline prompt as `FIXER_RULES` (`workflows/pipeline.js`)'*) PTR=yes ;; *) PTR=no ;; esac
  chk "$a: 공통 규칙은 파이프라인 프롬프트(FIXER_RULES)로 온다는 한 줄이 있다" "$PTR" "yes"
done
grep -q 'Runbook:' "$REPO/agents/supervisor.md"
chk "supervisor: 가이드를 라우팅·계층 판정에 쓴다" "$?" "0"
grep -q 'Family knowledge:' "$REPO/agents/fault-classifier.md"
chk "fault-classifier: 계열 지식표를 읽는다" "$?" "0"
grep -q 'first-ranked fixer runs' "$REPO/agents/fault-classifier.md"
chk "fault-classifier: '첫 순위만 실행' 서술이 없다" "$?" "1"
grep -q 'up to three candidates' "$REPO/agents/fault-classifier.md"
chk "fault-classifier: 최대 3명을 순서대로 묻는다" "$?" "0"
# 떠돌던 registry 줄이 입력 표 안(첫 '## ' 절 앞)으로 들어왔다
chk "fault-classifier: registry 입력 줄의 위치" \
    "$(awk '/^\| registry \|/{r=NR} /^## Before naming/{b=NR} END{print (r>0 && r<b) ? "ok" : "no"}' "$REPO/agents/fault-classifier.md")" "ok"
grep -q -- '--arch <arch> --family <family> carve_check' "$REPO/agents/static-analyzer.md"
chk "static-analyzer: carve 단계에 --arch 와 --family (기준자는 계열이 고른다)" "$?" "0"
grep -q 'memdump_plan.json' "$REPO/agents/static-analyzer.md" && grep -q '<channel>' "$REPO/agents/static-analyzer.md"
chk "static-analyzer: memdump_plan.json 과 세 번째 열" "$?" "0"

# 실제 MediaTek 이미지가 있을 때만: LK 는 arch 와 무관하게 full 이다 (arm32 는 문자열 기준, arm64 는
# 문자열이 모자라도 컨테이너 헤더가 선언한 크기만큼 있으므로 - integration 14)
if [ -n "${SBOOT_MT_FIXTURES:-}" ] && [ -f "$SBOOT_MT_FIXTURES/lk-verified.img" ] \
   && python3 -c 'import capstone' >/dev/null 2>&1; then
  hdr "실제 LK 이미지 (SBOOT_MT_FIXTURES)"
  A32=$(python3 "$S/carve_disasm.py" --arch arm32 carve_check "$SBOOT_MT_FIXTURES/lk-verified.img" | sed -n 's/^is_full: //p')
  A64=$(python3 "$S/carve_disasm.py" --arch arm64 carve_check "$SBOOT_MT_FIXTURES/lk-verified.img" | sed -n 's/^is_full: //p')
  chk "LK: arm32 기준 full"          "$A32" "True"
  chk "LK: arm64 기준도 full (컨테이너 헤더가 선언한 크기만큼 있음)" "$A64" "True"
fi


# =============================================================================
hdr "가이드 본문: 진행 가이드 · 분류기 · 도출 규칙이 코드가 하는 일과 같다"
# 문구가 있는지만이 아니라 코드와 맞물리는 것은 코드로 확인한다 (사다리는 pipeline.js 에서 읽고,
# 장부 규칙은 verify_gates.py · check_change.sh 를 실제로 돌린다).
cat > "$FT/guide_check.py" <<'PY'
import importlib.util, os, re, sys
sys.dont_write_bytecode = True
root = sys.argv[1]
out = []
def emit(k, v): out.append("%s=%s" % (k, v))
def rd(p): return open(os.path.join(root, p), encoding="utf-8").read()
def norm(t): return re.sub(r"\s+", " ", t)
def section(text, start, end):
    a = text.find(start); b = text.find(end, a + 1)
    return text[a:b] if a >= 0 and b > a else ""

rb = rd("knowledge/runbook_mediatek.md"); rbn = norm(rb)
sa = rd("agents/static-analyzer.md"); san = norm(sa)
fc = rd("agents/fault-classifier.md")
pj = rd("workflows/pipeline.js")

# ---- 사다리는 pipeline.js 의 goalsFor 에서 읽는다
m = re.search(r"function goalsFor\(.*?\n\}\n", pj, re.S)
ladder = [x for x in re.findall(r"'([a-z_]+)'", m.group(0)) if x != "none"] if m else []
emit("ladder_read", "OK" if len(ladder) >= 8 and ladder[0] == "medium_up" and ladder[-1] == "super_mounted" else "BAD:%s" % ladder)

# ---- 1. 단계 번호가 사다리 순서를 따른다 (rs-1, rs-2)
steps = [(int(n), t) for n, t in re.findall(r"^### S(\d+)\. (.*)$", rb, re.M)]
def step_of(rung):
    for n, t in steps:
        if "`%s`" % rung in t: return n
    return None
pos = [(r, step_of(r)) for r in ladder]
miss = [r for r, n in pos if n is None]
seq = [n for r, n in pos if n is not None]
emit("runbook_rungs_in_headings", "OK" if not miss else "MISSING:" + ",".join(miss))
emit("runbook_steps_follow_ladder", "OK" if seq == sorted(seq) else "ORDER:%s" % pos)
hand = [n for n, t in steps if "Chain handoff" in t]
emit("runbook_handoff_before_medium", "OK" if hand and step_of("medium_up") and hand[0] < step_of("medium_up") else "NO")

# ---- 2. S1 (rs-6, fc-9)
s1 = norm(section(rb, "### S1.", "### S2."))
emit("s1_base_load_base", "OK" if "base.load_base" in s1 else "NO")
emit("s1_confidence_per_isa", "OK" if "AArch64: `derived`" in s1 and "AArch32: `cross_checked`" in s1 else "NO")
emit("s1_failure_path", "OK" if "one bounded re-derivation" in s1 and "BLOCKED_BUILD" in s1 else "NO")

# ---- 3. 예외 루프 함정 (rs-4, fc-3)
emit("exception_trap_opt_in", "OK" if "opt-in and off by default" in rbn and "do not lower it" not in rbn else "NO")

# ---- 4. 그 밖의 런북 문구
emit("rule6_untested", "OK" if re.search(r"^\| 6 \|.*\(design proposal, untested\) \|$", rb, re.M) else "NO")
emit("header_not_exercised", "OK" if "has not yet been exercised end to end by the agent loop" in rbn else "NO")
emit("rehost_rx_prefix", "OK" if "REHOST-RX" in rbn and "printed without the `rehost: ` prefix" in rbn else "NO")
emit("resume_no_step_promise", "OK" if "which step of this runbook it stopped in" not in rbn and "does not record a runbook step" in rbn else "NO")
emit("host_file_guarantee", "OK" if "whenever a round produced host lines" in rbn and "host_log" in rbn else "NO")
emit("task_regex_file", "OK" if all("kernel_task_regex.txt" in t and "KERNEL_TASK_REGEX" not in t for t in (rb, sa)) else "NO")

# ---- 5. 주소 창 표는 템플릿의 정의를 가리킨다 (복사하지 않는다)
tmpl_head = "\n".join(rd("templates/machine_mixed_arch.c.tmpl").splitlines()[:80])
emit("windows_defined_in_template", "OK" if "address windows" in tmpl_head and "security_effect" in tmpl_head else "NO")
for name, path in (("runbook", "knowledge/runbook_mediatek.md"), ("static_analyzer", "agents/static-analyzer.md"), ("fixer_memory", "agents/fixer-memory.md")):
    t = rd(path)
    emit("windows_pointer_" + name, "OK" if "templates/machine_mixed_arch.c.tmpl" in t and "address windows" in t and "security_effect" not in t else "NO")

# ---- 6. 분류기 (fc-10, fc-13)
emit("classifier_no_kboot", "OK" if "kboot" not in fc else "NO")
rg = section(fc, "## Reaching a goal is not a stop point", "## Output (JSON)")
rows = [l for l in rg.splitlines() if l.startswith("|")]
rowtext = "\n".join(rows)
emit("classifier_ladder_table", "OK" if all(("`%s`" % r) in rowtext for r in ladder) else "MISSING:" + ",".join(r for r in ladder if ("`%s`" % r) not in rowtext))
bogus = [x for x in ("commands", "rootfs", "link_up", "power_mode", "scsi_attach") if x in rowtext]
emit("classifier_no_foreign_rungs", "OK" if not bogus else "FOREIGN:" + ",".join(bogus))
emit("classifier_summary_name", "OK" if "07_logs/run_N.summary.txt" in fc else "NO")

# ---- 7. static-analyzer
emit("sa_no_point_user", "OK" if "Point the user at" not in sa and "The pipeline stages these assets before you run" in sa else "NO")
owner = section(sa, "- **담당 fixer**", "- **If the mechanism")
want = ["fixer-memory", "fixer-el3", "fixer-bootflow", "fixer-secureboot", "fixer-storage", "fixer-kernel"]
emit("sa_owner_column", "OK" if all(("`%s`" % w) in owner for w in want) and "`build`" in owner else "NO")
emit("sa_memdump_plan", "OK" if "only when the base and the size are derived" in san and "no tool derives it" in san and "console_size" in san else "NO")
s14a = norm(section(sa, "### 14a)", "### 14b)"))
emit("sa_cmdline_labelled", "OK" if s14a.count("the values are not yours, derive them from your target") >= 1 else "NO")

# ---- 7b. 다른 지식표가 부르는 런북 단계 번호가 그 단계의 제목과 맞는다 / 도출 행의 담당 칸 규칙
head = dict(steps)
fm = norm(rd("knowledge/faults_mediatek.md"))
refs = (("decided in step S(\\d+) of the runbook", "Boot medium"),
        ("the runbook \\(S(\\d+)\\) gives the order", "Chain handoff"),
        ("verification order in the runbook \\(S(\\d+)\\)", "verify_ok"))
badref = []
for rx, word in refs:
    mm = re.search(rx, fm)
    if not mm or word not in head.get(int(mm.group(1)), ""): badref.append("%s->%s" % (rx[:24], mm.group(1) if mm else None))
emit("faults_mediatek_step_refs", "OK" if not badref else "BAD:" + ";".join(badref))
fu = norm(section(rd("knowledge/faults_unified.md"), "## Derived stop points", "## Common 4-byte"))
emit("faults_unified_owner_rule", "OK" if all(("`%s`" % w) in fu for w in want) and "`build`" in fu and "not `fixer-general`" in fu else "NO")

# ---- 8. 행 모양이 코드가 읽는 모양과 같다
sys.path.insert(0, os.path.join(root, "scripts"))
def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(root, "scripts", name + ".py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
try:
    df = load("derived_facts")
    static = "## 도출된 정지점\n\n| 시그니처 | 관측 | 메커니즘 | 담당 fixer | 시도할 변경 |\n|---|---|---|---|---|\n"
    for i, w in enumerate(want + ["build"]):
        static += "| `sig_%d` | o | m | `%s` | t |\n" % (i, w)
    static += "| `sig_prose` | o | m | the memory fixer, probably | t |\n"
    tmp = os.path.join(sys.argv[2], "STATIC.md")
    open(tmp, "w", encoding="utf-8").write(static)
    got = {r["signature"]: r["fixer"] for r in df.parse_table(tmp)}
    emit("owner_rows_read", "OK" if [got.get("sig_%d" % i) for i in range(7)] == want + ["build"] else "BAD:%s" % got)
    emit("owner_prose_skipped", "OK" if "sig_prose" not in got else "NO")
except Exception as exc:                       # noqa: BLE001
    emit("owner_rows_read", "ERR:%s" % exc); emit("owner_prose_skipped", "ERR")
try:
    vg = load("verify_gates")
    fn = getattr(vg, "parse_hash_engine_rows", None)
    if fn is None:
        emit("hash_row_shape_read", "SKIP")
    else:
        block = re.search(r"```markdown\n## 해시 계산 위치\n(.*?)```", sa, re.S).group(1)
        row = [l for l in block.splitlines() if l.startswith("| hash_engine")][0]
        row = row.replace("<hardware or software>", "hardware")
        row = re.sub(r"<digest function.*?>", "digest function 0x1234; SMC id 0x82000001", row)
        r = fn("## 해시 계산 위치\n\n" + row + "\n")
        emit("hash_row_shape_read", "OK" if len(r) == 1 and r[0]["ok"] and r[0]["value"] == "hardware" else "BAD:%s" % r)
except Exception as exc:                       # noqa: BLE001
    emit("hash_row_shape_read", "ERR:%s" % exc)

# ---- 9. 14a 의 계획 예는 build_lu.py 가 실제로 읽는 모양이고, 14a 의 서술은 그 동작과 같다
# 가이드가 보이는 예를 그대로 build_lu.py 에 먹여, 문서가 약속한 동작(partition 을 이름으로 찾아 쓴다 ·
# 자리표시 이름은 조용히 추측하지 않는다 · 파티션이 아닌 출처는 아무것도 쓰지 않고 경고한다 · 아무것도
# 말하지 않으면 param 으로 가며 경고한다)이 코드와 같은지 본다. 예시 값은 모두 합성이다.
import json, subprocess
s14a_raw = section(sa, "### 14a)", "### 14b)")
s14a = norm(s14a_raw)
mj = re.search(r"```json\n(.*?)```", s14a_raw, re.S)
plan = None
try:
    plan = json.loads(mj.group(1))
    emit("sa_cmdline_example_json", "OK")
except Exception as exc:                       # noqa: BLE001
    emit("sa_cmdline_example_json", "BAD:%s" % exc)
if plan is not None:
    need = {"default", "uart", "partition", "offset", "source", "evidence"}
    emit("sa_cmdline_example_keys", "OK" if need <= set(plan) else "KEYS:%s" % sorted(set(plan)))
    ws = os.path.join(sys.argv[2], "cl_ws")
    os.makedirs(os.path.join(ws, "fw"), exist_ok=True)
    json.dump({"medium": "emmc", "partitions": [
        {"name": "boot_x", "kind": "zero", "size": 65536},
        {"name": "param", "kind": "zero", "size": 65536}]},
        open(os.path.join(ws, "lu_manifest.json"), "w"))
    def build(p, family=None):
        json.dump(p, open(os.path.join(ws, "cmdline_plan.json"), "w"))
        r = subprocess.run([sys.executable, os.path.join(root, "scripts", "build_lu.py"), ws,
                            "--out", os.path.join(ws, "fw", "lu0.img")]
                           + (["--family", family] if family else []),
                           capture_output=True, text=True)
        try: return json.loads(r.stdout)
        except ValueError: return {"ok": False, "raw": r.stdout[-200:] + r.stderr[-200:]}
    named = dict(plan, partition="boot_x")
    r = build(named)
    emit("sa_cmdline_example_writes_named_partition",
         "OK" if r.get("cmdline_written") is True and r.get("cmdline_target", {}).get("partition") == "boot_x"
         and r["cmdline_target"].get("basis") == "plan.partition" and "warning_cmdline" not in r
         else "BAD:%s" % {k: r.get(k) for k in ("ok", "cmdline_written", "cmdline_target", "warning_cmdline", "raw")})
    r = build(plan)            # 자리표시 이름을 그대로 둔 예: 이름이 매체에 없으면 아무것도 쓰지 않고 말한다
    emit("sa_cmdline_example_placeholder_is_loud",
         "OK" if r.get("cmdline_written") is False and "warning_cmdline" in r else "BAD:%s" % r.get("cmdline_written"))
    nopart = {k: v for k, v in plan.items() if k not in ("partition", "offset")}
    r = build(nopart)          # 문서의 "파티션에서 오지 않는다" 경우: partition 을 쓰지 않고 source 에 출처를 적는다
    emit("sa_cmdline_no_partition_writes_nothing",
         "OK" if r.get("cmdline_written") is False and "warning_cmdline" in r and "warning_cmdline_target" not in r
         else "BAD:%s" % {k: r.get(k) for k in ("cmdline_written", "warning_cmdline", "warning_cmdline_target")})
    bare = {k: v for k, v in plan.items() if k not in ("partition", "offset", "source")}
    r = build(bare, "exynos")  # 아무 파티션도 말하지 않은 계획: exynos 일 때만 param 으로 가고 추측이라고 경고한다
    emit("sa_cmdline_names_nothing_falls_to_param",
         "OK" if r.get("cmdline_written") is True and r.get("cmdline_target", {}).get("partition") == "param"
         and "warning_cmdline_target" in r else "BAD:%s" % r.get("cmdline_target"))
    # 14a 의 두 번째 항: 다른 계열(그리고 모르는 계열)은 같은 계획에서 아무것도 쓰지 않고 warning_cmdline 만 낸다.
    # 매니페스트에 param 이 있어도 그렇다 - 폴백은 한 계열의 레이아웃이고 이름을 추측하지 않는다.
    other = []
    for fam in ("mediatek", "generic", "someotherfamily"):
        r = build(bare, fam)
        if not (r.get("cmdline_written") is False and "warning_cmdline" in r
                and "warning_cmdline_target" not in r and "warning_family" not in r):
            other.append("%s:%s" % (fam, {k: r.get(k) for k in ("cmdline_written", "warning_cmdline", "warning_cmdline_target")}))
    emit("sa_cmdline_param_fallback_exynos_only", "OK" if not other else "BAD:" + ";".join(other))
    # --family 를 주지 않은 옛 호출자: 예전 동작(param) 그대로이고 warning_family 가 붙는다 (14a 의 셋째 항)
    r = build(bare)
    emit("sa_cmdline_no_family_old_behaviour",
         "OK" if r.get("cmdline_written") is True and r.get("cmdline_target", {}).get("partition") == "param"
         and "warning_family" in r else "BAD:%s" % {k: r.get(k) for k in ("cmdline_written", "warning_family")})
emit("sa_cmdline_no_param_sentence",
     "OK" if "into the PARAM partition" not in sa and '"source": "PARAM partition"' not in sa else "OLD")
emit("sa_cmdline_names_keys_and_warnings",
     "OK" if all(("`%s`" % k) in s14a for k in ("partition", "offset", "source", "warning_cmdline", "warning_cmdline_target"))
     else "MISSING")

# 커널 태스크 정규식: 문서의 서술(검색 · 고정하지 않음 · 처음 N 자 · ^ 로 고정 · 첫 그룹이 태스크)이
# memdump_observe.py 의 task_of 가 실제로 하는 일과 같다. N 은 코드의 TASK_WINDOW 에서 읽는다.
try:
    mo = load("memdump_observe")
    win = mo.TASK_WINDOW
    def task(rx, text):
        c, why = mo.compile_task_regex(rx)
        mo.TASK_RE = c
        return mo.task_of(text)
    probes = [task(r"zz:(\w+)", "abc zz:foo") == "foo",                  # 검색이다 (줄 처음이 아니어도 맞는다)
              task(r"^zz:(\w+)", "abc zz:foo") is None,                  # ^ 는 줄 텍스트의 처음에 고정한다
              task(r"^zz:(\w+)", "zz:foo") == "foo",
              task(r"zz:(\w+)", " " * (win - 6) + "zz:foo") == "foo",     # 창의 끝까지는 본다
              task(r"zz:(\w+)", " " * win + "zz:foo") is None,           # 창 밖은 보지 않는다
              task(r"zz:\w+", "abc zz:foo") == "zz:foo"]                 # 그룹이 없으면 맞은 전체
    emit("task_regex_code_behaviour", "OK" if all(probes) else "BAD:%s" % probes)
    for name, t in (("runbook", rbn), ("static_analyzer", san)):
        said = ("start of each kernel line" not in t and "not anchored" in t and "`^`" in t
                and ("first %d characters" % win) in t and "first capture group" in t)
        emit("task_regex_doc_" + name, "OK" if said else "WRONG")
except Exception as exc:                       # noqa: BLE001
    emit("task_regex_code_behaviour", "ERR:%s" % exc)
    emit("task_regex_doc_runbook", "ERR"); emit("task_regex_doc_static_analyzer", "ERR")

# ---- 10. 분석가 문서가 말하는 동작이 코드가 하는 동작과 같다: carve 기준자(계열) · 입력 계획(기본값 없음) · param 폴백(exynos 만)
# 에이전트 문서가 지워진 동작(CR 세 번 기본값 · --arch 로 고르는 기준자 · 모든 계열의 param 폴백)을 계속 말하면
# 분석가가 문서대로 따라 해서 파이프라인 프롬프트와 어긋난 일을 한다. 문서의 문장마다 그 문장이 약속하는 동작을 코드로 돌린다.
import types
try:
    import capstone                              # noqa: F401  (진짜 capstone 이 있는지는 stub 을 끼우기 전에 본다)
    have_cap = True
except ImportError:
    have_cap = False
carve_raw = section(sa, "### 1) Carve verdict", "### 2) Entry offset")
carve = norm(carve_raw)
a12_raw = section(sa, "### 12a)", "### 12c)")
a12 = norm(a12_raw)
sa_out2 = sa[sa.index("## Output (JSON)"):]

# 10a. carve: 모든 carve_check 명령이 --arch 와 --family 를 싣고, 기준자 표는 --arch 가 아니라 --family 로 키를 단다
cmds = re.findall(r"^[^\n]*carve_disasm\.py[^\n]*carve_check[^\n]*$", sa, re.M)
emit("sa_carve_commands_carry_family",
     "OK" if cmds and all("--family" in c and "--arch" in c for c in cmds) else "BAD:%s" % cmds)
emit("sa_carve_table_keyed_by_family",
     "OK" if "| `--family` | `full` means |" in carve_raw and "| `--arch` | `full` means |" not in sa
     and "never run the default on an AArch32" in carve else "BAD")
# 표의 숫자와 문자열은 코드의 CARVE_YARDSTICKS 와 같다 (한쪽만 고치면 이 시험이 낸다)
try:
    if not have_cap:
        sys.modules["capstone"] = types.ModuleType("capstone")      # 표 대조에는 디스어셈블러가 필요 없다
    cd = load("carve_disasm")
    bad = []
    if set(cd.CARVE_YARDSTICKS) != {"exynos", "mediatek"}:
        bad.append("families:%s" % sorted(cd.CARVE_YARDSTICKS))
    for fam, prof in cd.CARVE_YARDSTICKS.items():
        row = [l for l in carve_raw.splitlines() if l.startswith("| `%s` |" % fam)]
        row = norm(row[0]) if row else ""
        ms = prof["min_size"]
        size = ("%d MB" % (ms // 1048576)) if ms % 1048576 == 0 else ("%d KB" % (ms // 1024))
        if not row:
            bad.append(fam + ":no row"); continue
        if (">= " + size) not in row: bad.append("%s:size %s" % (fam, size))
        if ("at least %d of" % prof["need"]) not in row: bad.append("%s:need %d" % (fam, prof["need"]))
        for s in prof["strings"]:
            if ("`%s`" % s.decode()) not in row: bad.append("%s:token %s" % (fam, s.decode()))
    grow = [l for l in carve_raw.splitlines() if l.startswith("| `generic`")]
    if not grow or "no yardstick" not in grow[0]: bad.append("generic row")
    emit("sa_carve_table_matches_code", "OK" if not bad else "BAD:" + ";".join(bad))
except Exception as exc:                       # noqa: BLE001
    emit("sa_carve_table_matches_code", "ERR:%s" % exc)
# 세 값 (true · false · null) 과 carve_note 가 문서에 있고, 출력 예와 아래 요약이 null 을 막힘으로 세지 않는다
emit("sa_carve_null_documented",
     "OK" if ("`null`" in carve and "is_full_note" in carve and "`carve_note`" in carve
              and "only `false` stops the run" in carve and "not a carve" in carve
              and '"carve_note"' in sa_out2 and "`carve_is_full=null` is not" in norm(sa_out2)) else "BAD")
# 문서가 약속하는 동작을 돌려 본다: 합성한 빈 이미지 (헤더도 문자열도 없다)
if have_cap:
    img = os.path.join(sys.argv[2], "blank.img")
    open(img, "wb").write(bytes(4096))
    def carve_out(*flags):
        r = subprocess.run([sys.executable, os.path.join(root, "scripts", "carve_disasm.py")] + list(flags)
                           + ["carve_check", img], capture_output=True, text=True)
        return r.stdout
    g = carve_out("--arch", "arm64", "--family", "generic")
    x = carve_out("--arch", "arm64", "--family", "exynos")
    o = carve_out("--arch", "arm64")
    emit("sa_carve_doc_behaviour",
         "OK" if ("is_full: null" in g and "is_full_note:" in g and "family: generic" in g
                  and "is_full: False" in x and "family: exynos" in x
                  and "family:" not in o and "warning" not in o.lower()) else "BAD:%r|%r|%r" % (g, x, o))
else:
    emit("sa_carve_doc_behaviour", "SKIP")

# 10b. 12a: 쓰지 않은 계획은 "문서화된 기본값" 이 아니다 - 하니스는 아무것도 보내지 않고 출처를 absent 로 적는다
emit("sa_12a_no_default_promise",
     "OK" if ("documented default" not in sa and "CR x3" not in sa and "no** interrupt pattern" in a12
              and "`absent`" in a12 and "미확정" in a12) else "BAD")
try:
    uh = load("uart_harness")
    def plan_of(obj, name):
        pth = os.path.join(sys.argv[2], name)
        if obj is not None: json.dump(obj, open(pth, "w"))
        return uh.load_plan(pth)
    none = plan_of(None, "plan_missing.json")
    bytes_only = plan_of({"autoboot_interrupt": {"bytes": "\r"}}, "plan_bytes.json")
    count_only = plan_of({"autoboot_interrupt": {"count": 3}}, "plan_count.json")
    both = plan_of({"autoboot_interrupt": {"bytes": "\\r", "count": 3}}, "plan_both.json")
    ok10 = (all(p["source"] == "absent" and p["byte"] == "" and p["count"] == 0 for p in (none, bytes_only, count_only))
            and both["source"] == "derived" and both["byte"] == "\r" and both["count"] == 3
            and bool(none["note"]))
    emit("sa_12a_matches_harness", "OK" if ok10 else "BAD:%s" % [none, bytes_only, count_only, both])
except Exception as exc:                       # noqa: BLE001
    emit("sa_12a_matches_harness", "ERR:%s" % exc)

# 10c. 14a: param 폴백은 exynos 만 (위의 build() 시험이 코드를 돌렸고, 여기서는 문서가 같은 말을 하는지)
emit("sa_cmdline_doc_fallback_per_family",
     "OK" if ("`exynos`: it falls back to a partition literally called `param`" in s14a
              and "any other family" in s14a and "**no fallback.**" in s14a
              and "`build_lu.py` falls back to a partition literally" not in s14a
              and "`--family` left out" in s14a and "`warning_family`" in s14a) else "BAD")
print("\n".join(out))
PY
GC=$(python3 "$FT/guide_check.py" "$REPO" "$FT")
gc() { printf '%s\n' "$GC" | sed -n "s/^$1=//p"; }
chk "사다리를 pipeline.js 의 goalsFor 에서 읽었다"            "$(gc ladder_read)" "OK"
chk "runbook: 사다리의 칸이 단계 제목에 다 있다"              "$(gc runbook_rungs_in_headings)" "OK"
chk "runbook: 단계 번호가 사다리 순서를 따른다 (userspace 가 partitions_up 앞)" "$(gc runbook_steps_follow_ladder)" "OK"
chk "runbook: 체인 핸드오프가 부트 매체 앞 단계다"            "$(gc runbook_handoff_before_medium)" "OK"
chk "runbook S1: load_base 는 base.load_base"                 "$(gc s1_base_load_base)" "OK"
chk "runbook S1: ISA 별 confidence (AArch64 derived · AArch32 cross_checked)" "$(gc s1_confidence_per_isa)" "OK"
chk "runbook S1: 실패 경로 (재도출 한 번, BLOCKED_BUILD)"     "$(gc s1_failure_path)" "OK"
chk "runbook: 예외 루프 조기 종료는 선택이고 기본 꺼짐"        "$(gc exception_trap_opt_in)" "OK"
chk "runbook: 규칙 6 에 (design proposal, untested)"          "$(gc rule6_untested)" "OK"
chk "runbook: 에이전트 루프로 끝까지 돌려 본 적 없다고 적음"   "$(gc header_not_exercised)" "OK"
chk "runbook: REHOST-RX 는 rehost: 접두 없이 찍힌다고 적음"    "$(gc rehost_rx_prefix)" "OK"
chk "runbook: RESUME.md 에 단계를 적는다는 약속이 없다"        "$(gc resume_no_step_promise)" "OK"
chk "runbook: host_<N>.txt 는 호스트 줄이 있으면 쓰인다"       "$(gc host_file_guarantee)" "OK"
chk "runbook · static-analyzer: kernel_task_regex.txt (환경변수 아님)" "$(gc task_regex_file)" "OK"
chk "주소 창 표의 정의는 템플릿 Conventions 에 있다"           "$(gc windows_defined_in_template)" "OK"
chk "runbook 이 주소 창 표를 템플릿 정의로 가리킨다 (복사하지 않음)"           "$(gc windows_pointer_runbook)" "OK"
chk "static-analyzer 가 주소 창 표를 템플릿 정의로 가리킨다 (복사하지 않음)"   "$(gc windows_pointer_static_analyzer)" "OK"
chk "fixer-memory 가 주소 창 표를 템플릿 정의로 가리킨다 (복사하지 않음)"      "$(gc windows_pointer_fixer_memory)" "OK"
chk "fault-classifier: kboot_ 가 없다"                        "$(gc classifier_no_kboot)" "OK"
chk "fault-classifier: 목표 표가 사다리의 칸을 전부 담는다"    "$(gc classifier_ladder_table)" "OK"
chk "fault-classifier: 목표 표에 사다리에 없는 칸이 없다"      "$(gc classifier_no_foreign_rungs)" "OK"
chk "fault-classifier: 요약 로그 이름은 run_N.summary.txt"    "$(gc classifier_summary_name)" "OK"
chk "faults_mediatek.md 가 부르는 런북 단계 번호가 제목과 맞는다 (S5 매체 · S4 핸드오프 · S6 검증)" "$(gc faults_mediatek_step_refs)" "OK"
chk "faults_unified.md: 도출 행의 담당 칸은 여섯 fixer 또는 build" "$(gc faults_unified_owner_rule)" "OK"
chk "static-analyzer: 사용자에게 추출 스크립트를 안내하지 않는다" "$(gc sa_no_point_user)" "OK"
chk "static-analyzer: 담당 칸은 여섯 fixer 와 build"          "$(gc sa_owner_column)" "OK"
chk "static-analyzer: derived_facts.py 가 여섯 fixer 와 build 를 담당으로 읽는다" "$(gc owner_rows_read)" "OK"
chk "static-analyzer: 담당 칸이 문장이면 그 행은 읽히지 않는다" "$(gc owner_prose_skipped)" "OK"
chk "static-analyzer: memdump 계획 (base·size 도출, console_size, dtb 는 손으로)" "$(gc sa_memdump_plan)" "OK"
chk "static-analyzer: 명령줄 예시에 값은 대상에서 도출하라는 표시" "$(gc sa_cmdline_labelled)" "OK"
chk "static-analyzer 14a: 계획 예가 JSON 으로 읽힌다"          "$(gc sa_cmdline_example_json)" "OK"
chk "static-analyzer 14a: 계획 예에 partition · offset 키가 있다 (파이프라인 프롬프트 9번과 같은 키)" "$(gc sa_cmdline_example_keys)" "OK"
chk "static-analyzer 14a: 예의 partition 이름에 build_lu.py 가 쓴다 (plan.partition)" "$(gc sa_cmdline_example_writes_named_partition)" "OK"
chk "static-analyzer 14a: 자리표시 이름을 그대로 두면 build_lu.py 가 쓰지 않고 경고한다 (추측하지 않는다)" "$(gc sa_cmdline_example_placeholder_is_loud)" "OK"
chk "static-analyzer 14a: partition 이 없고 source 가 파티션 이름이 아니면 아무것도 안 쓰고 warning_cmdline" "$(gc sa_cmdline_no_partition_writes_nothing)" "OK"
chk "static-analyzer 14a: 아무것도 말하지 않으면 param 으로 가고 warning_cmdline_target" "$(gc sa_cmdline_names_nothing_falls_to_param)" "OK"
chk "static-analyzer 14a: 'PARAM 파티션에 쓴다'는 옛 문장이 없다" "$(gc sa_cmdline_no_param_sentence)" "OK"
chk "static-analyzer 14a: param 폴백은 --family exynos 일 때만이고, mediatek · generic · 모르는 계열은 같은 계획에서 아무것도 쓰지 않고 warning_cmdline 만 낸다 (build_lu.py 를 돌려 확인)" "$(gc sa_cmdline_param_fallback_exynos_only)" "OK"
chk "static-analyzer 14a: --family 를 주지 않은 옛 호출자는 param 으로 가고 warning_family 가 붙는다 (build_lu.py 를 돌려 확인)" "$(gc sa_cmdline_no_family_old_behaviour)" "OK"
chk "static-analyzer 14a: 문서가 폴백을 계열별로 서술한다 (exynos 만 param, 그 밖은 폴백 없음, --family 생략은 warning_family)" "$(gc sa_cmdline_doc_fallback_per_family)" "OK"
chk "static-analyzer 1): 모든 carve_check 명령이 --arch 와 --family 를 싣는다" "$(gc sa_carve_commands_carry_family)" "OK"
chk "static-analyzer 1): 기준자 표는 --arch 가 아니라 --family 로 키를 단다" "$(gc sa_carve_table_keyed_by_family)" "OK"
chk "static-analyzer 1): 기준자 표의 크기 · 개수 · 토큰이 carve_disasm.py 의 CARVE_YARDSTICKS 와 같다" "$(gc sa_carve_table_matches_code)" "OK"
chk "static-analyzer 1): true · false · null 세 값과 is_full_note · carve_note 를 서술하고 null 은 막힘이 아니다 (출력 예 포함)" "$(gc sa_carve_null_documented)" "OK"
GCB=$(gc sa_carve_doc_behaviour)
if [ "$GCB" = "SKIP" ]; then echo "  (capstone 이 없어 carve_check 동작 대조는 건너뜀)"
else chk "static-analyzer 1): 문서가 약속한 carve_check 동작 (generic 은 null + is_full_note, exynos 기준자는 False, --family 를 빼면 family 줄도 경고도 없다)" "$GCB" "OK"; fi
chk "static-analyzer 12a: 계획이 없으면 '문서화된 기본값(CR x3)' 이 아니라 패턴을 보내지 않고 출처를 absent 로 적는다고 서술하고 미확정을 쓰라고 한다" "$(gc sa_12a_no_default_promise)" "OK"
chk "static-analyzer 12a: 서술이 uart_harness.load_plan 과 같다 (파일 없음 · bytes 만 · count 만은 absent, 둘 다 있어야 derived)" "$(gc sa_12a_matches_harness)" "OK"
chk "static-analyzer 14a: partition · offset · source · 경고 키 둘을 설명한다" "$(gc sa_cmdline_names_keys_and_warnings)" "OK"
chk "memdump_observe.py: task_of 는 TASK_WINDOW 안을 고정 없이 검색한다 (^ 는 고정, 그룹 없으면 맞은 전체)" "$(gc task_regex_code_behaviour)" "OK"
chk "runbook S7: 태스크 정규식은 처음 N 자에서 검색하고 고정하지 않는다 (^ 를 직접 붙인다)" "$(gc task_regex_doc_runbook)" "OK"
chk "static-analyzer 14b: 태스크 정규식은 처음 N 자에서 검색하고 고정하지 않는다 (^ 를 직접 붙인다)" "$(gc task_regex_doc_static_analyzer)" "OK"
HR=$(gc hash_row_shape_read)
if [ "$HR" = "SKIP" ]; then echo "  (verify_gates.py 에 parse_hash_engine_rows 가 아직 없음 - hash_engine 행 모양 대조는 건너뜀)"
else chk "static-analyzer: hash_engine 행 모양을 verify_gates.py 가 읽는다" "$HR" "OK"; fi

hdr "가이드 본문: 장부 규칙 문장은 FIXER_RULES 에 한 번 있고, 게이트가 실제로 하는 일과 같다"
if [ "$NEU_NODE" = yes ]; then
  ALL=yes
  for frag in 'never `(기록 없음)`' 'heading `#<id>`' '- 메타: 종류=…; 표지=…; 출처=…; 도출=…' '/* bypass:<id> */' 'rejects a **new or edited** entry' '(exit 2, naming the entry)' 'only when at least one tag exists' 'tag every row' 'as absolute paths - open them as given'; do
    case "$NEU_FR" in *"$frag"*) ;; *) ALL="no: $frag" ;; esac
  done
  chk "FIXER_RULES: 장부 규칙 문장 (비움 금지 · #<id> · 메타 · 행 태그 · 새·고친 항목만 반려 · 태그 점검의 한계)와 계열 자료 절대 경로 안내 - fixer 일곱이 이 한 본문을 받는다" "$ALL" "yes"
else
  ok "SKIP node 가 없어 FIXER_RULES 의 장부 규칙 문구 시험을 건너뜁니다"
fi
# 에이전트 파일에는 그 문장의 사본이 없다 (한 곳에서 고치면 일곱 곳이 같이 고쳐지게)
for a in fixer-memory fixer-el3 fixer-bootflow fixer-storage fixer-kernel fixer-general fixer-secureboot; do
  N=$(tr '\n' ' ' < "$REPO/agents/$a.md" | tr -s ' ')
  COPY=none
  for frag in 'rejects a **new or edited** entry' 'as absolute paths - open them as given' '## Rules shared by every fixer' '## Output language' 'tag every row'; do
    case "$N" in *"$frag"*) COPY="has: $frag" ;; esac
  done
  chk "$a: 공통 규칙(장부 규칙 · 계열 자료 안내 · 공통 규칙 절 · 출력 언어 절)의 사본이 없다" "$COPY" "none"
done
SBN=$(tr '\n' ' ' < "$REPO/agents/fixer-secureboot.md" | tr -s ' ')
case "$SBN" in *"or the gate rolls it back"*) SBR=old ;; *) SBR=fixed ;; esac
chk "fixer-secureboot: 태그 행 규칙을 게이트가 막는다는 서술이 없다" "$SBR" "fixed"
case "$SBN" in *"a row you forget to tag passes the gate"*) SBR=says ;; *) SBR=missing ;; esac
chk "fixer-secureboot: 태그가 하나도 없으면 안 걸린다고 적었다" "$SBR" "says"

# 위 문장이 말하는 동작을 실제 스크립트로 확인한다 (verify_gates.py ledger, check_change.sh)
LG="$FT/ledger"; rm -rf "$LG"; mkdir -p "$LG/06_machine"
E1=$'### #1 first\n- 대상: window A\n- 이유: r\n- 방법: m\n- 부작용: a real side effect\n- 메타: 종류=P; 출처=A; 도출=semi\n'
E2=$'### #2 second\n- 대상: window B\n- 이유: r\n- 방법: m\n- 부작용: (기록 없음)\n- 메타: 종류=P; 출처=A; 도출=semi\n'
printf '%s\n' "$E1" > "$LG/base.md"
printf '%s\n%s\n' "$E1" "$E2" > "$LG/06_machine/bypasses.md"
printf 'int x;\n' > "$LG/06_machine/m.c"
kinds() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(sorted(set(i["kind"] for i in d["issues"]))) or "none")'; }
OUT=$(python3 "$S/verify_gates.py" ledger "$LG" --baseline "$LG/base.md" 2>/dev/null)
chk "게이트: 새 항목의 부작용이 '(기록 없음)' 이면 반려 (항목 번호를 댄다)" "$(printf '%s' "$OUT" | kinds | grep -c side_effect_empty) $(printf '%s' "$OUT" | grep -c '#2')" "1 1"
printf '%s\n%s\n' "$E1" "$E2" > "$LG/base2.md"
OUT=$(python3 "$S/verify_gates.py" ledger "$LG" --baseline "$LG/base2.md" 2>/dev/null)
chk "게이트: 옛 회차의 같은 결함은 이번 회차 탓으로 세지 않는다" "$(printf '%s' "$OUT" | kinds | grep -c side_effect_empty)" "0"
E2OK=$'### #2 second\n- 대상: window B\n- 이유: r\n- 방법: m\n- 부작용: a real side effect\n- 메타: 종류=P; 출처=A; 도출=semi\n'
printf '%s\n%s\n' "$E1" "$E2OK" > "$LG/06_machine/bypasses.md"
OUT=$(python3 "$S/verify_gates.py" ledger "$LG" 2>/dev/null)
chk "게이트: 소스에 태그가 하나도 없으면 종류=P 항목의 행이 없어도 안 걸린다 (그래서 행 태그는 fixer 의 몫)" "$(printf '%s' "$OUT" | kinds)" "none"
printf 'int x; /* bypass:2 */\n' > "$LG/06_machine/m.c"
OUT=$(python3 "$S/verify_gates.py" ledger "$LG" 2>/dev/null)
chk "게이트: 태그가 하나라도 있으면 행 없는 종류=P 항목(#1)을 반려한다" "$(printf '%s' "$OUT" | kinds)" "entry_no_tag"
# check_change.sh: 종료코드 2, 사유가 항목 번호를 댄다
CC="$FT/cc"; rm -rf "$CC"; mkdir -p "$CC/06_machine"
printf 'int a;\n' > "$CC/06_machine/m.c"; printf '%s\n' "$E1" > "$CC/06_machine/bypasses.md"
bash "$S/check_change.sh" "$CC" snapshot >/dev/null 2>&1
printf 'int a;\nint b;\n' > "$CC/06_machine/m.c"; printf '%s\n%s\n' "$E1" "$E2" > "$CC/06_machine/bypasses.md"
OUT=$(bash "$S/check_change.sh" "$CC" verify 2>/dev/null); RC=$?
chk "check_change.sh: 새 항목이 장부 규칙을 어기면 종료코드 2, 사유가 #2 를 댄다" "$RC $(printf '%s' "$OUT" | grep -c '#2')" "2 1"

hdr "registry.yaml 머리말이 코드와 맞다"
RG=$(tr '\n' ' ' < "$REPO/fixers/registry.yaml" | tr -s ' ' | tr -d '#')
case "$RG" in *"The pipeline only reads this file"*) RGO=old ;; *) RGO=fixed ;; esac
chk "registry: '파이프라인이 읽는다 / 코드는 안 바뀐다' 서술이 없다" "$RGO" "fixed"
case "$RG" in *"hard-coded KNOWN_FIXERS list in workflows/pipeline.js"*) RGO=says ;; *) RGO=missing ;; esac
chk "registry: KNOWN_FIXERS 가 하드코딩이라고 적었다" "$RGO" "says"
python3 - "$REPO" > "$FT/kf.txt" <<'PY'
import re, sys
root = sys.argv[1]
pj = open(root + "/workflows/pipeline.js", encoding="utf-8").read()
reg = open(root + "/fixers/registry.yaml", encoding="utf-8").read()
known = re.search(r"KNOWN_FIXERS = \[([^\]]*)\]", pj, re.S).group(1)
known = set(re.findall(r"'(fixer-[a-z0-9-]+)'", known))
listed = set(re.findall(r"^  (fixer-[a-z0-9-]+):", reg, re.M))
print("OK" if known <= listed and listed - known == {"fixer-general"} else "DIFF known=%s listed=%s" % (sorted(known), sorted(listed)))
PY
chk "registry 의 fixer 블록 = KNOWN_FIXERS + fixer-general (머리말이 말하는 두 목록의 관계)" "$(cat "$FT/kf.txt")" "OK"

hdr "text-neutral: 에이전트 · 지식표 · 예제 · .gitignore 에 한 기기의 값이 기본값처럼 남지 않는다"
# 문구가 있는지만 보는 시험이다. 값이 다시 들어오거나(옛 문장) 라벨이 빠지면 실패한다.
cat > "$FT/neutral_check.py" <<'PY'
import os, re, sys
root = sys.argv[1]
out = []
def emit(k, v): out.append("%s=%s" % (k, v))
def rd(p): return open(os.path.join(root, p), encoding="utf-8").read()
def norm(t): return re.sub(r"\s+", " ", t)
# FIXER_RULES (pipeline.js 의 규칙 본문): 세 번째 인자가 그 글을 담은 파일이다. 비어 있으면(node 없음) 그것을 보는 시험은 SKIP.
frp = sys.argv[2] if len(sys.argv) > 2 else ""
fr = norm(open(frp, encoding="utf-8").read()) if frp and os.path.exists(frp) else ""
def blocks(text):
    """[(앞 400자 정규화, 블록 본문)] - 코드 펜스 ```json 마다"""
    res = []
    for m in re.finditer(r"```json\n(.*?)```", text, re.S):
        res.append((norm(text[max(0, m.start() - 400):m.start()]), m.group(1)))
    return res
LABEL = "the values are not yours, derive them from your target"
FIXERS = ["fixer-memory", "fixer-el3", "fixer-bootflow", "fixer-secureboot", "fixer-storage", "fixer-kernel", "fixer-general"]

# ---- E10 / CC6: 파이프라인이 읽지 않는 필드가 fixer 의 JSON 에도 말에도 없다
bad = []
for f in FIXERS:
    t = rd("agents/%s.md" % f)
    sec = t[t.index("## Output (JSON)"):]
    for key in ("escalate", "suspect_prior_bypass", "bypass_doc", "category"):
        if re.search(r'"%s"\s*:' % key, sec): bad.append("%s:json:%s" % (f, key))
    for word in ("escalate.needed", "suspect_prior_bypass", "bypass_doc"):
        if word in t: bad.append("%s:text:%s" % (f, word))
for word in ("escalate.needed", "suspect_prior_bypass", "bypass_doc", '"escalate"', '"category"'):
    if word in fr: bad.append("FIXER_RULES:text:%s" % word)
emit("fixer_removed_fields", "OK" if not bad else "BAD:" + ",".join(bad))
# 열린 질문은 no_new_change=true 와 rationale 로 답한다: 그 문장은 FIXER_RULES 에 한 번 있고, 일곱 fixer 가 모두 받는다
need_oq = 'An open question you cannot settle yourself goes in "rationale", with no_new_change=true'
emit("fixer_open_question_in_rationale", "SKIP" if not fr else ("OK" if need_oq in fr else "MISSING"))
# 전문가 여섯의 JSON 예에는 공통 기본값(거절 깃발 · 바이트를 안 고칠 때의 null)이 없다: 파이프라인 프롬프트가 말한다. 마지막 수단 fixer 는 자기 필드를 가진다
moved = []
for f in FIXERS:
    if f == "fixer-general": continue
    t = rd("agents/%s.md" % f)
    for _, body in blocks(t[t.index("## Output (JSON)"):]):
        for key in ('"not_mine"', '"no_new_change"'):
            if key in body: moved.append("%s:%s" % (f, key))
        if re.search(r'"(encoding|pre_image)":\s*null', body): moved.append("%s:null" % f)
emit("fixer_json_common_keys_moved", "OK" if not moved else "BAD:" + ",".join(moved))

# ---- E1: 처방이 한 SoC 의 정렬을 말하지 않는다
fm = rd("agents/fixer-memory.md")
row = [l for l in fm.splitlines() if l.startswith("| `data_abort_unmapped`")]
r0 = norm(row[0]) if row else ""
emit("memory_no_fixed_alignment", "OK" if row and "0x10000000" not in fm and "DTB node" in r0 and "never a fixed alignment" in r0 else "NO")

# ---- E2: 값이 든 JSON 예는 라벨이 붙어 있다
unl = []
for f in FIXERS:
    t = rd("agents/%s.md" % f)
    sec = t[t.index("## Output (JSON)"):]
    bl = blocks(sec)
    pre = norm(sec[:sec.index("```json")]) if bl else ""
    if not bl or LABEL not in pre: unl.append(f)
sup = rd("agents/supervisor.md")
for needle, name in (('"route": "rebuild"', "supervisor-rebuild"), ('"route": "revert"', "supervisor-revert"), ('"round": 12', "supervisor-output")):
    ok = [lab for lab, body in blocks(sup) if needle in body and LABEL in lab]
    if not ok: unl.append(name)
sa = rd("agents/static-analyzer.md")
sa_out = sa[sa.index("## Output (JSON)"):]
if LABEL not in norm(sa_out[:sa_out.index("```json")]): unl.append("static-analyzer-output")
emit("json_examples_labelled", "OK" if not unl else "UNLABELLED:" + ",".join(unl))
emit("static_analyzer_output_no_device_value", "OK" if "0x9B983000" not in sa and '"track"' not in sa_out else "NO")

# ---- E3: 한 기기의 커널 줄이 '칸이 찍는 줄' 로 박혀 있지 않다
lad = []
for path in ("agents/fixer-storage.md", "knowledge/faults_storage.md"):
    t = rd(path)
    for s in ("sda: sda1 sda2 sda3 sda4", "M(1)G(3)L(2)HS-series(2)", "dm-0/dm-4", "supermount: SUCCESS"):
        if s in t: lad.append("%s:%s" % (path, s))
    if "line shape (seen on one device; derive yours)" not in t: lad.append(path + ":header")
    if "line the kernel prints" in t: lad.append(path + ":old-header")
emit("storage_ladder_shapes", "OK" if not lad else "BAD:" + ";".join(lad))

# ---- E4: 중립 표의 다운로드 모드 신호는 일반형이고, S-Boot 문자열은 한 기기로 표시한다
fu = rd("knowledge/faults_unified.md")
rows = {m.group(1): norm(m.group(0)) for m in re.finditer(r"^\| `(handoff_slot_empty|download_mode_entry)` .*$", fu, re.M)}
vendor = ("Entering odin mode", "parallel_download_init", "[CC MODE] Failed")
ok4 = len(rows) == 2
for name, r in rows.items():
    ok4 = ok4 and "download or flash mode" in r and "Exynos" in r and "one device" in r
only = [l for l in fu.splitlines() if any(v in l for v in vendor) and not re.match(r"^\| `(handoff_slot_empty|download_mode_entry)` ", l)]
mt = norm(rd("knowledge/faults_mediatek.md"))
emit("faults_unified_download_generic", "OK" if ok4 and not only and "Extends the row of the same name in `faults_unified.md`" in mt else "NO")

# ---- E5: BLOCKED_KO 의 증거 탐색은 매체 종류에 따른다 (pipeline.js 의 프롬프트와 같다)
k4 = sa[sa.index("### K4) Storage driver provenance"):sa.index("### K5)")]
k4n = norm(k4)
pj = norm(rd("workflows/pipeline.js"))
bad5 = []
for need in ("Decide the medium kind first", "detect_medium.py", "UFS", "eMMC", "`ufshcd`", "`sdhci`", "`dw_mmc`", "compatible",
             'storage_driver: { form: "module" | "builtin" | "absent", evidence: … }', "do **not** report `absent`", "its hit count"):
    if need not in k4n: bad5.append(need)
for gone in ("ufs-exynos", "exynos-ufs", "ufs_qcom", "CONFIG_SCSI_UFS", "*ufs*.ko"):
    if gone in k4n: bad5.append("still:" + gone)
for need in ("sdhci / dw_mmc", "ufshcd"):
    if need not in pj: bad5.append("pipeline:" + need)
emit("k4_medium_aware", "OK" if not bad5 else "BAD:" + ";".join(bad5))

# ---- E6 / E7: 참조 예제가 값 차용을 권하지 않고 죽은 참조가 없다
ex = "examples/s921n-exynos2400/"
rm = rd(ex + "README.md"); inp = rd(ex + "INPUT.md"); mc = rd(ex + "machine.c")
bad6 = []
if "값을 차용하지 않는다" not in rm: bad6.append("banner")
for s in ("byte-identical", "재사용할 수 있다", "폐기된 트랙 1", "md5"):
    if s in rm: bad6.append("readme:" + s)
for s in ("md5", "file_size", "carrier", "samfw", "rehost-setup", "rehost-sboot", "methodology/worked_example"):
    if s in inp: bad6.append("input:" + s)
if "09_another_people_analyze" in mc or "sm_s921b.c" in mc: bad6.append("machine:path")
if "reference implementation by another analyst" not in mc or "not in this repository" not in mc: bad6.append("machine:reworded")
emit("s921n_example_neutral", "OK" if not bad6 else "BAD:" + ",".join(bad6))
print("\n".join(out))
PY
NEU=$(python3 "$FT/neutral_check.py" "$REPO" "$NEU_FR_FILE" 2>&1)
neu() { printf '%s\n' "$NEU" | sed -n "s/^$1=//p"; }
chk "fixer 일곱: JSON 과 본문에 escalate · suspect_prior_bypass · bypass_doc · category 가 없다 (파이프라인이 읽지 않는 필드)" "$(neu fixer_removed_fields)" "OK"
if [ "$(neu fixer_open_question_in_rationale)" = SKIP ]; then ok "SKIP node 가 없어 FIXER_RULES 의 열린 질문 문구 시험을 건너뜁니다"
else chk "FIXER_RULES: 열린 질문은 no_new_change=true 와 rationale 로 답하라고 적었다 (fixer 일곱이 이 한 본문을 받는다)" "$(neu fixer_open_question_in_rationale)" "OK"; fi
chk "전문가 여섯의 JSON 예에 공통 기본값(not_mine · no_new_change · null 인 encoding/pre_image)이 없다 (파이프라인 프롬프트가 말한다)" "$(neu fixer_json_common_keys_moved)" "OK"
chk "fixer-memory: data_abort_unmapped 처방이 정렬 값 대신 DTB 노드 범위를 말한다" "$(neu memory_no_fixed_alignment)" "OK"
chk "JSON 예(fixer 일곱 · supervisor 셋 · static-analyzer 출력)에 '값은 당신 것이 아니다' 라벨이 붙었다" "$(neu json_examples_labelled)" "OK"
chk "static-analyzer 출력 예에 한 기기의 값(릴로케이션 상수)과 폐기된 track 필드가 없다" "$(neu static_analyzer_output_no_device_value)" "OK"
chk "마일스톤 사다리: 한 기기의 커널 줄 대신 모양(정규식 꼴)과 '이 기기에서 본 것, 직접 도출' 머리글" "$(neu storage_ladder_shapes)" "OK"
chk "faults_unified: handoff_slot_empty · download_mode_entry 는 일반 신호이고 S-Boot 문자열은 (Exynos, 한 기기) 로 표시, faults_mediatek 이 확장 관계를 유지" "$(neu faults_unified_download_generic)" "OK"
chk "static-analyzer K4: BLOCKED_KO 증거 탐색이 매체 종류(UFS · eMMC 이름 묶음, DTB compatible)에 따르고 pipeline.js 와 같다" "$(neu k4_medium_aware)" "OK"
chk "s921n 예제: 값 차용 금지 배너, byte-identical 기준 없음, md5 · 판매처 · 죽은 명령 · 다른 분석가의 경로 없음" "$(neu s921n_example_neutral)" "OK"

# .gitignore: 추적 중인 파일을 가리지 않는다 (대소문자를 가리지 않는 파일시스템 포함)
NEU_BARE=""
for n in INPUT.md STATIC.md STUBS.md KERNEL_STATIC.md PROGRESS.md VERIFICATION.md JOURNAL.md ANALYSIS.md fixer_candidates.md; do
  grep -qxF "$n" "$REPO/.gitignore" && NEU_BARE="$NEU_BARE $n"
  grep -qxF "/$n" "$REPO/.gitignore" || NEU_BARE="$NEU_BARE missing:/$n"
done
chk ".gitignore: 문서 이름은 루트에 고정(/NAME)하고 이름만 쓴 줄이 없다" "${NEU_BARE:-none}" "none"
chk ".gitignore: 지워진 /rehost-* 명령 · 트랙 표현이 주석에 남지 않았다" "$(grep -c '/rehost-\|트랙' "$REPO/.gitignore")" "0"
if command -v git >/dev/null 2>&1; then
  NEU_GR="$FT/gi"; rm -rf "$NEU_GR"; mkdir -p "$NEU_GR"
  ( cd "$NEU_GR" && git init -q . && cp "$REPO/.gitignore" .gitignore ) >/dev/null 2>&1
  neu_gi() { ( cd "$NEU_GR" && git -c core.ignorecase=true check-ignore -q "$1" ) >/dev/null 2>&1 && echo ignored || echo tracked; }
  chk ".gitignore(대소문자 무시): 추적 중인 예제 파일은 무시되지 않는다" \
      "$(neu_gi examples/s921n-exynos2400/INPUT.md) $(neu_gi examples/a136u-mt6833/README.md)" "tracked tracked"
  chk ".gitignore: 워크스페이스 문서와 로컬 폴더는 계속 무시된다 (루트 INPUT.md · rehost_workspaces · analyze · _design · portfolio · .omc)" \
      "$(neu_gi INPUT.md) $(neu_gi STATIC.md) $(neu_gi rehost_workspaces/w/INPUT.md) $(neu_gi analyze/x/STATIC.md) $(neu_gi _design/a.md) $(neu_gi portfolio/a.md) $(neu_gi .omc/a)" \
      "ignored ignored ignored ignored ignored ignored ignored"
  if [ -d "$REPO/.git" ]; then
    chk ".gitignore: 추적 중인 파일 중 무시 목록에 걸리는 것이 없다 (git ls-files -ci --exclude-standard)" \
        "$(cd "$REPO" && git ls-files -ci --exclude-standard | wc -l | tr -d ' ')" "0"
  fi
else
  echo "  (git 이 없어 .gitignore 동작 시험은 건너뜀)"
fi

rm -rf "$FT"
parts_finish
