#!/usr/bin/env bash
# tests/parts/canon.sh - 정본·스킬·릴리스 메타데이터: 버전 일치, CHANGELOG 항목, CLAUDE.md 의 새 서술,
# 스킬에서 6/6 REAL 제거, fixer-secureboot 의 하드웨어 해시 분기, make_export.sh.
# 2차 작업 뒤: 정본·문서가 코드의 동작을 말하는 곳은 코드의 표식과 같이 본다 (canon 2b), start 의 입력 슬롯표와
# pipeline.js 가 읽는 방식의 일치 (canon 3), 문서가 서로 같은 번호·같은 사실을 말하는지 (canon 5),
# 키트가 회차처럼 메모리 덤프 환경을 내보내는지 (canon 8), STATIC.md 회전이 검증이 읽는 사실을 잃지 않는지 (canon 8b).
# 0.29.2: 정본 · 스킬 · pipeline.js 의 지시는 영어이고, 스크립트가 바이트 그대로 맞추는 한국어 계약 문자열은 번역되지 않았는지 (canon 9).
#
# check_release.sh 의 로직은 여기서 돌리지 않는다 (smoke.sh 가 가짜 저장소로 양방향 확인한다).
# 이 시험은 문서가 서로 어긋나지 않는지와, 정본에 넣기로 한 문장이 실제로 들어 있는지를 본다.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"


cn_has() {   # cn_has <파일> <고정 문자열> -> yes|no
    if grep -qF -- "$2" "$1"; then echo yes; else echo no; fi
}
cn_flat_has() {   # cn_flat_has <파일> <고정 문자열> -> yes|no. 줄바꿈을 공백 하나로 접은 뒤 찾는다 (문서가 줄을 접는 자리에 시험이 묶이지 않는다)
    if tr '\n' ' ' < "$1" | tr -s ' ' | grep -qF -- "$2"; then echo yes; else echo no; fi
}

# FIXER_RULES (workflows/pipeline.js): 모든 fixer 프롬프트가 받는 공통 규칙 본문. 그 상수만 tests/pipeline_sim/fixer_rules.js 가 잘라 평가해
# 낸다 (fixer-*.md 에는 이제 그 문구가 없다). node 가 없으면 이 문구 시험은 건너뛴다 (시험 하나는 그대로 한 건으로 센다).
cn_fixer_rules() {   # -> 한 줄로 합친 FIXER_RULES (없으면 빈 문자열)
    command -v node >/dev/null 2>&1 || return 0
    node "$REPO/tests/pipeline_sim/fixer_rules.js" "$REPO" 2>/dev/null | tr '\n' ' ' | tr -s ' '
}
cn_fr_chk() {   # cn_fr_chk <설명> <고정 문자열>   (FRT 는 cn_main 이 채운다)
    if ! command -v node >/dev/null 2>&1; then ok "SKIP node 가 없어 건너뜀: $1"; return 0; fi
    case "$FRT" in *"$2"*) chk "$1" "yes" "yes" ;; *) chk "$1" "no" "yes" ;; esac
}

# 한국어 계약 문자열 (canon 9): 스크립트 · verifier · 시험이 바이트 그대로 맞추는 문자열이라 번역하면 조용히 깨진다.
# 한 줄 = 정본 표의 문자열 | 파서 쪽 문자열(비면 같은 것) | 파서 파일(repo 상대, 공백으로 구분) | 에이전트 쪽 조각
# 에이전트 쪽 조각 = "<파일>=<고정 문자열>" 을 ";;" 로 이은 것. 나열한 조각이 모두 그 파일에 있어야 한다. '-' = 요구 없음.
# 장부 필드 · 메타 줄 · 빈 기록 표지만 이 층을 둔다. 이 낱말들은 pipeline.js 어디에나 흔하므로 낱말 하나가 아니라
# 에이전트에게 쓰라고 하는 문장 조각(여러 낱말)에 고정한다: 흔한 낱말만 찾으면 FIXER_RULES 를 번역해도 통과한다.
# 파서 쪽 문자열이 표의 것과 다른 줄은 코드가 그 문구를 조각으로 쓰기 때문이다 (예: 검증 우회 %d건).
CN_AG_LEDGER='workflows/pipeline.js=`대상 / 이유 / 방법 / 부작용`;;agents/fixer-secureboot.md=대상 / 이유 / 방법 / **부작용**'
CN_AG_META='workflows/pipeline.js=`- 메타: 종류=…; 표지=…; 출처=…; 도출=…`;;agents/fixer-secureboot.md=- 메타: 종류=P; 표지=F; 출처=A; 도출=semi'
CN_LIT_ROWS='대상||scripts/check_change.sh scripts/verify_gates.py scripts/verify.py|'"$CN_AG_LEDGER"';;agents/fixer-secureboot.md=대상 / 이유 / 방법 that talk about verification
이유||scripts/check_change.sh scripts/verify_gates.py|'"$CN_AG_LEDGER"';;agents/fixer-secureboot.md=in the entry'"'"'s 이유
방법||scripts/check_change.sh scripts/verify_gates.py scripts/verify.py|'"$CN_AG_LEDGER"';;agents/fixer-secureboot.md=대상 / 이유 / 방법 that talk about verification
부작용||scripts/check_change.sh scripts/verify_gates.py scripts/verify.py|'"$CN_AG_LEDGER"';;workflows/pipeline.js=The 부작용 is never empty;;agents/fixer-secureboot.md=the 부작용 names what
알려진 부작용|알려진|scripts/check_change.sh scripts/verify_gates.py scripts/verify.py|-
메타||scripts/verify_gates.py|'"$CN_AG_META"'
종류||scripts/verify_gates.py|'"$CN_AG_META"';;workflows/pipeline.js=a patch entry `종류=P`;;agents/fixer-secureboot.md=or 종류=M
표지||scripts/verify_gates.py|'"$CN_AG_META"';;agents/fixer-secureboot.md=with **표지 F**
출처||scripts/verify_gates.py|'"$CN_AG_META"'
도출||scripts/verify_gates.py|'"$CN_AG_META"'
근거||scripts/verify_gates.py|-
(기록 없음)||scripts/verify_gates.py|workflows/pipeline.js=never `(기록 없음)`;;agents/fixer-secureboot.md=never `(기록 없음)`
## 도출된 정지점|도출된 정지점|scripts/derived_facts.py|-
시그니처||scripts/derived_facts.py scripts/static_rotate.py|-
미확정||scripts/verify_gates.py scripts/stage_map.py workflows/pipeline.js|-
주소 창||scripts/verify_gates.py scripts/static_rotate.py scripts/verify.py workflows/pipeline.js|-
VERIFIED (출처 검증 통과)||scripts/verify_gates.py scripts/verify.py workflows/pipeline.js|-
검증 우회 N건|검증 우회 %d건|scripts/verify_gates.py|-
verify_ok: reached_bypassed||scripts/verify_gates.py scripts/verify.py workflows/pipeline.js|-
UNVERIFIED (출처 검증 실패)||scripts/verify_gates.py|-
F2 (verify_ok 우회 N건)|(verify_ok 우회 ${|workflows/pipeline.js|-
배너 미관측||workflows/pipeline.js|-'

cn_lit_path() {   # <repo 상대 경로> -> 파일 경로. CN_OVERLAY 에 같은 경로가 있으면 그것을 쓴다 (변조한 사본으로 시험을 시험하려고)
    if [ -n "${CN_OVERLAY:-}" ] && [ -f "$CN_OVERLAY/$1" ]; then printf '%s' "$CN_OVERLAY/$1"; else printf '%s' "$REPO/$1"; fi
}
cn_lit_scan() {   # 줄마다 "<정본 표의 문자열><TAB><표>/<파서>/<에이전트>". 전부 맞으면 ok/ok/ok, 아니면 어느 층이 비었는지
    local tbl tl pl pf af f ts ps as miss rest pair
    tbl=$(awk '/^\|.*\| Matched by \|[[:space:]]*$/{f=1} f && /^\|/{print; next} f{exit}' "$(cn_lit_path CLAUDE.md)")
    while IFS='|' read -r tl pl pf af; do
        [ -n "$tl" ] || continue
        [ -n "$pl" ] || pl="$tl"
        # 표에서는 코드 조각(`…`)으로 감싼 채 찾는다: 다른 칸의 낱말 속에 있는 같은 글자가 이 칸을 대신하지 않게
        if printf '%s\n' "$tbl" | grep -qF -- "\`$tl\`"; then ts=ok; else ts=table_missing; fi
        miss=""
        for f in $pf; do grep -qF -- "$pl" "$(cn_lit_path "$f")" 2>/dev/null || miss="$miss,$f"; done
        if [ -z "$miss" ]; then ps=ok; else ps="parser_missing:${miss#,}"; fi
        miss=""
        rest="$af"
        if [ "$rest" = "-" ]; then rest=""; fi   # 요구가 없는 줄은 이 층을 충족한 것으로 센다
        while [ -n "$rest" ]; do   # "<파일>=<조각>;;<파일>=<조각>": 조각마다 그 파일에 있어야 한다
            pair="${rest%%;;*}"
            if [ "$pair" = "$rest" ]; then rest=""; else rest="${rest#*;;}"; fi
            grep -qF -- "${pair#*=}" "$(cn_lit_path "${pair%%=*}")" 2>/dev/null || miss="$miss,${pair%%=*}"
        done
        if [ -z "$miss" ]; then as=ok; else as="agent_missing:${miss#,}"; fi
        printf '%s\t%s/%s/%s\n' "$tl" "$ts" "$ps" "$as"
    done <<< "$CN_LIT_ROWS"
}

cn_main() {
    # smoke.sh 가 이 파일을 source 하므로 변수를 지역으로 둔다 (다른 절의 변수를 덮지 않는다)
    local CN PV MV FIRST DESC MDESC C28 CM EX ST SS FS FU RM CP O2 O5 EMD NDOC MISS WS K0 K1 K2 RUN1 R_NONE RC_NONE R_OK R_BAD RC_BAD R_SKIP H1 H2 sk f b n sc v
    local PJ SU PA CODE_HAS EXPECT_UNIMPL FRT C29 C292 NEU_N O4 GS FCTX CL_OUT CL_N CL_ROWS_N lit res af_file af_str ST_H LANG_N CL_FLAG CL_BASE
    CN="$ROOT/canon_t"; rm -rf "$CN"; mkdir -p "$CN"
    export PYTHONDONTWRITEBYTECODE=1

# =============================================================================
hdr "canon 1. 버전과 CHANGELOG"

PV=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$REPO/.claude-plugin/plugin.json")
MV=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["plugins"][0]["version"])' "$REPO/.claude-plugin/marketplace.json")
chk "plugin.json 과 marketplace.json 의 버전이 같다" "$PV" "$MV"
chk "버전이 X.Y.Z 모양" "$(printf '%s' "$PV" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$')" "1"
chk "CHANGELOG 에 현재 버전 머리말" "$(grep -cE "^## $(printf '%s' "$PV" | sed 's/\./\\./g') " "$REPO/CHANGELOG.md")" "1"
chk "CHANGELOG 에 0.28.0 머리말" "$(grep -c '^## 0\.28\.0 ' "$REPO/CHANGELOG.md")" "1"
# 0.28.0 절 안에 '확인하지 못한 것' 이 있어야 한다 (한 일만 적고 못 한 일을 빼지 않는다)
C28=$(awk '/^## 0\.28\.0 /{f=1;next} /^## /{f=0} f' "$REPO/CHANGELOG.md")
chk "CHANGELOG 0.28.0: 확인하지 못한 것 절" "$(printf '%s\n' "$C28" | grep -c '^### 확인하지 못한 것')" "1"
chk "CHANGELOG 0.28.0: 실제 QEMU 종단 실행을 주장하지 않는다" \
    "$(printf '%s\n' "$C28" | grep -c '종단 실행에 성공')" "0"
# 정본 §11 의 예외 도입은 규칙의 완화이고 사용자 결정 전이다. 완화를 '약화가 아니다' 라고 쓰지 않는다
chk "CHANGELOG 0.28.0: 예외 도입을 '약화한 것이 아니다' 라고 적지 않는다" \
    "$(printf '%s\n' "$C28" | grep -c '규칙을 약화한 것이 아니라')" "0"
chk "CHANGELOG 0.28.0: 예외 도입은 규칙의 완화라고 적는다" \
    "$(printf '%s\n' "$C28" | grep -c '이것은 규칙의 완화다')" "1"
chk "CHANGELOG 0.28.0: 사용자 결정 없이 들어갔다고 확인하지 못한 것에 적는다" \
    "$(printf '%s\n' "$C28" | grep -c '사용자의 결정 없이 들어갔다')" "1"
# 가장 최근 항목이 맨 위 (역순 정렬 유지)
FIRST=$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+ ' "$REPO/CHANGELOG.md" | awk '{print $2}')
chk "CHANGELOG 의 첫 항목이 현재 버전" "$FIRST" "$PV"

DESC=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["description"])' "$REPO/.claude-plugin/plugin.json")
MDESC=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["plugins"][0]["description"])' "$REPO/.claude-plugin/marketplace.json")
chk "plugin.json 설명에 6/6 이 없다"      "$(printf '%s' "$DESC" | grep -c '6/6')" "0"
chk "plugin.json 설명이 3-gate 를 말한다" "$(printf '%s' "$DESC" | grep -ci '3-gate\|three-gate\|3 gate')" "1"
chk "plugin.json 설명이 MediaTek 의 한계를 밝힌다" \
    "$(printf '%s' "$DESC" | grep -i 'mediatek' | grep -ci 'guide level')" "1"
chk "plugin.json 설명이 종단 실행 없음을 밝힌다" \
    "$(printf '%s' "$DESC" | grep -ci 'not yet run end to end')" "1"
chk "marketplace 설명이 MediaTek 을 과장하지 않는다" \
    "$(printf '%s' "$MDESC" | grep -ci 'Mobile SoCs (Exynos, MediaTek, ...)')" "0"
chk "marketplace 설명이 MediaTek 의 수준을 적는다" \
    "$(printf '%s' "$MDESC" | grep -ci 'guide level')" "1"

# =============================================================================
hdr "canon 2. CLAUDE.md 의 새 서술"

CM="$REPO/CLAUDE.md"
# 3절: 표면 선택, 칸 상태, kernel_alive 일반화, 채널, 계열
chk "§3 표면 칸은 선택"                       "$(cn_has "$CM" '**The surface rung is optional.**')" "yes"
chk "§3 칸 상태 셋"                           "$(cn_has "$CM" '`reached_bypassed`')" "yes"
chk "§3 도달 서술 'F2 (verify_ok 우회 N건)'"  "$(cn_has "$CM" 'F2 (verify_ok 우회 N건)')" "yes"
chk "§3 kernel_alive 는 어느 채널에서든"     "$(cn_flat_has "$CM" 'line only the kernel can emit is confirmed on any observation channel')" "yes"
chk "§3 대체 토큰이면 '배너 미관측' 기록"     "$(cn_has "$CM" '배너 미관측')" "yes"
chk "§3 토큰 파일의 채널 열"                  "$(cn_has "$CM" '<rung><TAB><token>[<TAB><channel>]')" "yes"
chk "§3 관측 채널 표 (memdump)"               "$(cn_has "$CM" '| `memdump` |')" "yes"
chk "§3 memdump_plan.json"                    "$(cn_has "$CM" 'memdump_plan.json')" "yes"
chk "§3 계열은 start 가 판별"                 "$(cn_has "$CM" 'detects the family **when it receives the firmware**')" "yes"
chk "§3 family_kit.py 와 프롬프트 줄"         "$(cn_has "$CM" 'Family knowledge:')" "yes"
chk "§3 계열 자료에 값이 없다"                "$(cn_has "$CM" '**Kits contain no values**')" "yes"
chk "§3 MediaTek 은 한 대에서 도출한 후보"    "$(cn_has "$CM" '**one SM-A136U**')" "yes"
chk "§3 입력 대기가 관측될 때만 NO_INPUT_PATH" "$(cn_flat_has "$CM" 'only when a round was observed stopped waiting for input and no input path exists')" "yes"
# 4절: KNOWN_FIXERS, 새 스크립트
chk "§4 KNOWN_FIXERS 하드코딩을 적는다"      "$(cn_has "$CM" 'KNOWN_FIXERS')" "yes"
chk "§4 '새 fixer 는 파일 하나' 서술을 정정"   "$(cn_has "$CM" '**A new fixer is not one file plus a few registration lines.**')" "yes"
chk "§4 옛 서술이 남아 있지 않다"             "$(cn_has "$CM" 'A new fixer is one file plus a few registration lines.')" "no"
chk "§4 프로필의 knowledge:/runbook: 키"      "$(cn_has "$CM" '`knowledge:` · `runbook:`')" "yes"
for sc in clean_env.sh qemu_tree.sh family_kit.py detect_medium.py memdump_observe.py verify_gates.py verify_prep.py make_negative_image.py env_manifest.json; do
    chk "§4 스크립트 표에 $sc" "$(cn_has "$CM" "\`$sc\`")" "yes"
done
# 7절: 우회 기록
chk "§7 부작용 비움 금지"                     "$(cn_has "$CM" 'or `(기록 없음)` is invalid')" "yes"
chk "§7 메타 한 줄"                           "$(cn_has "$CM" '- 메타: 종류=P; 표지=F,L; 출처=A; 도출=semi')" "yes"
chk "§7 패치 표 행 태그"                      "$(cn_has "$CM" '/* bypass:<id> */')" "yes"
for v in '`M` model' '`I` image modification' '`X` insufficient basis'; do
    chk "§7 메타 어휘 $v" "$(cn_has "$CM" "$v")" "yes"
done
chk "§7 호스트 진단은 게스트 증거가 아니다"   "$(cn_has "$CM" "machine's host diagnostics")" "yes"
# 8절: 커널 채널
chk "§8 정체는 채널별로"                      "$(cn_has "$CM" '**Stall is computed per channel.**')" "yes"
# 10절: 정지 조건
chk "§10 BLOCKED_ARCH 의 새 의미"             "$(cn_has "$CM" 'Entry signature (GFH entry · vector table at payload start · crt0) not found')" "yes"
chk "§10 옛 BLOCKED_ARCH 서술이 없다"         "$(cn_has "$CM" 'entry-stub signature undefined for the architecture')" "no"
chk "§10 arm32 라는 이유로 정지하지 않는다"   "$(cn_has "$CM" 'merely because the image is arm32')" "yes"
chk "§10 BLOCKED_NO_INPUT_PATH 는 관측 기반"  "$(cn_has "$CM" 'A round stopped waiting for input and no surface has an input path')" "yes"
chk "§10 환경 매니페스트 불일치"              "$(cn_has "$CM" 'environment manifest mismatch')" "yes"
chk "§10 check_env 의 skipped 예외를 밝힌다"  "$(cn_has "$CM" '`skipped`')" "yes"
chk "§10 MAX_EXCEPTIONS 는 기본 꺼짐"        "$(cn_has "$CM" '`MAX_EXCEPTIONS`')" "yes"
# 11절: 검증
chk "§11 게스트 콘솔 = UART + 메모리 덤프"    "$(cn_has "$CM" '**The guest console that verification reads = UART console')" "yes"
chk "§11 게이트 1 은 빌드된 소스만"           "$(cn_has "$CM" '**actually built** machine source')" "yes"
chk "§11 게이트 3 은 pmemsave 외 모니터 명령" "$(cn_has "$CM" 'monitor commands other than `pmemsave`')" "yes"
chk "§11 검증 우회 보고 절"                   "$(cn_has "$CM" '### Verification-bypass report')" "yes"
chk "§11 판정 문구"                           "$(cn_has "$CM" 'VERIFIED (출처 검증 통과) · 검증 우회 N건 · verify_ok: reached_bypassed')" "yes"
chk "§11 하드웨어 해시 예외 절"               "$(cn_has "$CM" '### The only exception')" "yes"
chk "§11 예외는 소프트웨어 해시에 적용 안 함" "$(cn_has "$CM" 'A software-hash firmware must still pass unpatched')" "yes"
chk "§11 엔진 모델링 먼저 (a)"                "$(cn_has "$CM" '**Model the engine (M)**')" "yes"
chk "§11 우리가 만든 바이트는 참조에서 제외"  "$(cn_has "$CM" '**Bytes we made are not evidence.**')" "yes"
# 14, 15절
chk "§14 init 인자"                           "$(cn_has "$CM" '/sboot-rehost:init [--clean] [--wipe-workspaces] [--replace-unmarked]')" "yes"
chk "§14 판정은 env_revision"                 "$(cn_has "$CM" '`env_revision` in `env_manifest.json`')" "yes"
chk "§14 --wipe-workspaces 는 이동"           "$(cn_has "$CM" 'moved to `_archive/<id>_<timestamp>`, not deleted')" "yes"
chk "§14 표지 없는 것은 지우지 않는다"        "$(cn_has "$CM" 'Delete only what carries a mark that this plugin made it')" "yes"
chk "§14 .sboot_version"                      "$(cn_has "$CM" '.sboot_version')" "yes"
chk "§15 도해의 6항목 표기가 없다"            "$(cn_has "$CM" '6-item measurement')" "no"
chk "§15 verdict_script.json 설명"            "$(cn_has "$CM" '3 gates + reference metrics + verification-bypass report measurement')" "yes"
chk "§15 lu_provenance.json"                  "$(cn_has "$CM" 'lu_provenance.json')" "yes"
chk "CLAUDE.md 에 6/6 이 없다"                "$(cn_has "$CM" '6/6')" "no"
# 정직성 규칙 7개 표는 그대로 (규칙을 약화시키지 않았다)
chk "§7 규칙 7개가 남아 있다" "$(awk '/^## 7\./{f=1;next} /^## 8\./{f=0} f' "$CM" | grep -cE '^\| [1-7] \| \*\*')" "7"
chk "§7 적응형 토글 금지가 '완화해도 지키는 것' 에 남아 있다" "$(cn_has "$CM" '| **No speculative stubs** | Adaptive toggles above all.')" "yes"

# §11 의 예외는 규칙의 완화이고 사용자가 아직 결정하지 않았다 (리뷰 지적: 완화를 완화가 아니라고 적었고,
# 조건은 프롬프트뿐이었다). 정본이 그 사실과 조건, 조건의 집행 수단을 정직하게 적는지 본다.
chk "§11 예외 표 행이 사용자 미승인을 밝힌다"   "$(cn_has "$CM" 'provisional exception the user has not yet approved')" "yes"
chk "§11 예외 절의 제목이 잠정이라고 적는다"    "$(grep -c '^### The only exception.*(provisional)$' "$CM")" "1"
chk "§11 완화이고 사용자 결정을 받지 않았다"    "$(cn_has "$CM" 'This exception relaxes a rule, and the user has not decided on it')" "yes"
chk "§11 되돌리는 법: 절을 지우면 원래 규칙"     "$(cn_has "$CM" 'the rule returns to its original, exception-free form')" "yes"
chk "§11 (b) 는 선행 조건이 갖춰졌을 때만"      "$(cn_has "$CM" 'and only when the preconditions below are met')" "yes"
chk "§11 선행 조건: STATIC.md 의 hash_engine 행"  "$(cn_has "$CM" 'first cell is `hash_engine` and second cell is `hardware`')" "yes"
chk "§11 선행 조건: fixer 는 그 행을 쓰지 못한다" "$(cn_has "$CM" '**A fixer cannot write this row**')" "yes"
chk "§11 (a) 불가는 기계가 판정하지 못한다고 적는다" "$(cn_has "$CM" 'A machine cannot judge that (a) is infeasible')" "yes"
chk "§11 선행 조건은 필요 조건이지 충분 조건이 아니다" "$(cn_has "$CM" 'necessary, not sufficient')" "yes"
# 정본이 '기계가 확인한다'고 말하는 것은 코드가 실제로 확인할 때만이다. 코드의 표식은 verify_gates.py 장부 검사의
# 문제 종류 "hash_engine_row_missing" 이다 (verify 담당이 지목했고 verify_gates.sh 도 같은 문자열을 본다).
# 표식이 있으면 정본은 구현됐다고 적고 무엇을 확인하고 무엇을 확인하지 않는지 밝혀야 하며, 없으면 미구현이라고 적어야 한다.
CODE_HAS=no
grep -qs '"kind": "hash_engine_row_missing"' "$S/verify_gates.py" && CODE_HAS=yes
[ "$CODE_HAS" = "yes" ] && EXPECT_UNIMPL=no || EXPECT_UNIMPL=yes
chk "§11 선행 조건의 기계 검사: 코드에 표식이 있으면 '미구현' 이 아니고, 없으면 '미구현' 이다" \
    "$(cn_has "$CM" '**Unimplemented.** The design')" "$EXPECT_UNIMPL"
if [ "$CODE_HAS" = "yes" ]; then
    chk "check_change.sh 가 그 장부 검사를 실제로 부른다 (표식이 코드에 있어도 호출되지 않으면 검사가 아니다)" \
        "$(cn_has "$S/check_change.sh" 'verify_gates.py" ledger')" "yes"
    chk "§11 선행 조건: 문제 종류 이름을 적는다 (hash_engine_row_missing)" "$(cn_has "$CM" 'hash_engine_row_missing')" "yes"
    chk "§11 선행 조건: 기계가 확인하는 것(행의 유무와 모양)을 적는다" "$(cn_has "$CM" 'Only row presence and shape are checked')" "yes"
    chk "§11 선행 조건: 근거 칸의 0x 주소를 요구한다고 적는다" "$(cn_has "$CM" 'a `0x` address in the evidence cell')" "yes"
    chk "§11 선행 조건: 확인하지 않는 것 (누가 썼는지)" "$(cn_has "$CM" 'who wrote the row')" "yes"
    chk "§11 선행 조건: 확인하지 않는 것 ((a) 의 실현 불가)" "$(cn_has "$CM" 'whether (a) was really impossible')" "yes"
    chk "§11 선행 조건: 옛 '기계 검사가 구현되기 전에는' 문단이 없다" "$(cn_has "$CM" 'Before the machine check was implemented')" "no"
    chk "§4 check_change.sh 행이 hash_engine 행 검사를 말한다" "$(grep '^| `check_change.sh` |' "$CM" | grep -c 'hash_engine')" "1"
fi
# 주소 창 표(참고 지표)도 같은 방식: 코드에 보고 함수가 있으면 정본이 그것을 보고라고만 적는다 (게이트가 아니다)
if grep -qs 'def address_windows_report' "$S/verify_gates.py"; then
    chk "§11 주소 창 표: 코드에 보고가 있고 정본이 말한다 (address_windows)" "$(cn_has "$CM" '`address_windows`')" "yes"
    chk "§11 주소 창 표: 보고만 하고 판정은 바뀌지 않는다고 적는다" "$(cn_has "$CM" 'The verdict and the gate count do not change')" "yes"
fi

# =============================================================================
hdr "canon 2b. 정본이 코드의 동작을 말하는 곳: 코드의 표식과 정본의 문장을 같이 본다"

# 정본이 "한다"고 쓴 것이 코드에 없으면 문서가 코드를 앞서 나간 것이고, 코드에 있는데 정본이 말하지 않으면
# 규칙이 코드와 어긋난 것이다. 한쪽만 바뀌면 이 시험이 알려 준다.
cn_code_doc() {   # cn_code_doc <설명> <코드 파일> <코드 고정 문자열> <문서 파일> <문서 고정 문자열>
    chk "$1: 코드에 있다" "$(cn_has "$2" "$3")" "yes"
    chk "$1: 문서가 말한다" "$(cn_flat_has "$4" "$5")" "yes"
}
PJ="$REPO/workflows/pipeline.js"
cn_code_doc "K2 계획의 영역을 QEMU 환경으로 내보낸다 (REHOST_MEMDUMP_REGION)" "$S/run_full.sh" 'export REHOST_MEMDUMP_REGION=' "$CM" '`REHOST_MEMDUMP_REGION=<base>:<size>`'
cn_code_doc "K2 계획이 없으면 변수를 설정하지 않고 옛 값을 지운다" "$S/run_full.sh" 'unset REHOST_MEMDUMP_REGION' "$CM" "a value left in the caller's environment is also cleared"
cn_code_doc "K3 관측 문서에 kernel_log (경로 또는 null)" "$S/run_round.sh" '"kernel_log": path_or_none' "$CM" '`kernel_log` and `host_log`'
cn_code_doc "K3 관측 문서에 host_log (경로 또는 null)" "$S/run_round.sh" '"host_log": path_or_none' "$CM" 'paths of `07_logs/kernel_N.log` and `07_logs/host_N.txt`'
cn_code_doc "K4 호스트 줄은 채널과 무관하게 매 회차 나눈다" "$S/run_full.sh" 'CHAN_ARGS=(--host-log "$HOSTF")' "$CM" 'Always used when the round emitted host lines, regardless of plan'
cn_code_doc "K5 작업 폴더의 kernel_task_regex.txt 를 읽는다" "$S/run_full.sh" 'TASK_RX_FILE="$WORKDIR/kernel_task_regex.txt"' "$CM" 'writes `kernel_task_regex.txt`'
cn_code_doc "K1 stage_map.py --detect-arch" "$S/stage_map.py" '--detect-arch' "$CM" '`--detect-arch <path>`'
cn_code_doc "K8 파이프라인이 커널 자산을 적재한다" "$PJ" 'function stageAssetsCmd()' "$CM" 'pipeline calls it before Analyze'
cn_code_doc "K8 파이프라인이 extract_boot_assets.sh 를 부른다" "$PJ" 'scripts/extract_boot_assets.sh' "$CM" 'into `fw/` with `extract_boot_assets.sh`'
cn_code_doc "init 의 sudo 사전 점검은 종료코드 7" "$S/setup_env.sh" 'exit 7' "$CM" 'exit code **7**'
cn_code_doc "BLOCKED_KO 를 세우는 코드 (분석가의 storage_driver)" "$PJ" "blockers.push(['BLOCKED_KO'," "$CM" '`storage_driver.form=absent`'
cn_code_doc "재개 때 회차 번호를 이어 매긴다" "$PJ" 'function roundBaseCmd()' "$CM" '**only rounds run in this execution**'
cn_code_doc "매체 종류의 근거가 없으면 warning_medium" "$S/build_lu.py" 'warning_medium' "$CM" '`warning_medium`'
cn_code_doc "커맨드라인은 계획이 이름 붙인 파티션에 (cmdline_partition)" "$S/build_lu.py" 'manifest.cmdline_partition' "$CM" '`cmdline_partition`'
cn_code_doc "파이프라인은 arch 입력을 따르고 unknown 이면 도출한다" "$PJ" "archInput !== 'unknown'" "$CM" 'the pipeline asks again if `unknown`'
# 정본의 §10 이 BLOCKED_ASSET 을 "적재한 뒤에도" 로 쓰려면 코드가 그 문구로 선다
chk "BLOCKED_ASSET 의 정지 문구가 적재 결과를 싣는다 (정본: 적재한 뒤에도 없을 때만)" "$(cn_has "$PJ" '적재한 뒤에도 없습니다')" "yes"
chk "정본 §10: BLOCKED_ASSET 은 적재한 뒤에도 없을 때" "$(cn_has "$CM" 'still missing **after** the pipeline loaded them')" "yes"
chk "정본 §10: super 만 못 푼 경우(종료코드 4)는 정지가 아니다" "$(cn_has "$CM" 'script exit code 4')" "yes"
chk "정본: INPUT.md 슬롯표를 start 가 쓴다 (§15)" "$(cn_has "$CM" 'written by start: model · build · target · bootloader_path · has_super')" "yes"
chk "정본: .active 를 start 가 쓴다 (§15)" "$(cn_has "$CM" 'start writes the workspace it is currently working on')" "yes"
chk "정본 §3: 커맨드라인은 PARAM 파티션이라고 못박지 않는다" "$(cn_has "$CM" 'PARAM partition')" "no"

# =============================================================================
hdr "canon 3. 스킬: 6/6 REAL 제거, 새 완료 조건"

for sk in start export status init; do
    f="$REPO/skills/$sk/SKILL.md"
    chk "skills/$sk: 6/6 이 없다"  "$(cn_has "$f" '6/6')" "no"
    chk "skills/$sk: FORCED 표기가 없다" "$(cn_has "$f" 'FORCED')" "no"
    chk "skills/$sk: frontmatter name" "$(sed -n '2p' "$f")" "name: $sk"
done
EX="$REPO/skills/export/SKILL.md"
chk "export: 게이트 3/3 + 마일스톤 + 검증 우회 표기" "$(cn_has "$EX" '**Gates 3/3 passed.**')" "yes"
chk "export: 목표 마일스톤 도달"             "$(cn_has "$EX" '**Target milestone reached.**')" "yes"
chk "export: 검증 우회 건수 명시"            "$(cn_has "$EX" '**State the verification-bypass count.**')" "yes"
chk "export: F2 의 최종 칸은 kernel_alive"   "$(cn_has "$EX" '**F2**=`kernel_alive`')" "yes"
chk "export: 검증 우회가 있어도 막지 않고 병기" "$(cn_has "$EX" 'A count above 0 does not block export')" "yes"
chk "export: BUNDLE_FIRMWARE"                "$(cn_has "$EX" 'BUNDLE_FIRMWARE=0')" "yes"
chk "export: run.sh 가 합성 매체를 넘긴다"   "$(cn_has "$EX" '**`run.sh` passes the synthesized medium**')" "yes"
chk "export: run.sh 는 회차가 돈 조건으로 돈다" "$(cn_has "$EX" "**\`run.sh\` runs under the rounds' conditions.**")" "yes"
chk "export: -accel tcg,thread=single (handoff_tick)" "$(cn_has "$EX" '`-accel tcg,thread=single`')" "yes"
chk "export: RUN_TIMEOUT_S 를 안내한다"      "$(cn_has "$EX" 'RUN_TIMEOUT_S')" "yes"
chk "export: -cpu 를 기본으로 주지 않는다"   "$(cn_has "$EX" 'Do not pass `-cpu`')" "yes"
chk "export: 호출 예가 CPU 를 고정으로 넘기지 않는다" "$(grep -c '^MACHINE=.* CPU=' "$EX")" "0"
ST="$REPO/skills/status/SKILL.md"
chk "status: 검증 열이 VERIFIED/UNVERIFIED"  "$(cn_has "$ST" '`VERIFIED`(게이트 3/3)')" "yes"
chk "status: 검증 우회 건수 병기"            "$(cn_has "$ST" '검증 우회 건수')" "yes"
SS="$REPO/skills/start/SKILL.md"
chk "start: .sboot_version 을 새 워크스페이스에만" "$(cn_has "$SS" 'Write `.sboot_version` at the root **only in a newly created workspace**')" "yes"
chk "start: 재개 때는 덮어쓰지 않는다"       "$(cn_has "$SS" '**Never write or overwrite it on resume**')" "yes"
chk "start: 계열 판별 근거를 INPUT.md·STATIC.md 에" "$(cn_has "$SS" 'soc_family_evidence')" "yes"
chk "start: family_kit.py"                   "$(cn_has "$SS" 'family_kit.py')" "yes"
chk "start: 옛 BLOCKED_ARCH 서술이 없다"     "$(cn_flat_has "$SS" '(currently arm32)')" "no"
chk "start: 검증 우회 병기 문구"             "$(cn_has "$SS" 'verify_ok: reached_bypassed')" "yes"
# arch 는 기본값이 아니라 도출값이다 (리뷰 지적: 규칙 없이 파이프라인에 넘기면 기본값 arm64 가 AArch32 이미지를
# 오류 없이 AArch64 exec 스테이지로 읽는다). 2차 작업 뒤의 계약: start 가 첫 컨테이너로 --detect-arch 를 돌려
# INPUT.md 에 근거와 함께 적고 그 값(arm32|arm64|unknown)을 넘긴다. unknown 은 기본값으로 대신하지 않고 파이프라인이 다시 묻는다.
PA=$(awk '/^pipeline\.js\(\{/{f=1} f{print} f && /^\}\)/{exit}' "$SS")
chk "start: pipeline 인자 블록을 찾았다"                "$(printf '%s\n' "$PA" | grep -c 'bootloader_path')" "1"
chk "start: pipeline 인자에 arch 가 있다 (INPUT.md 슬롯 그대로)" "$(printf '%s\n' "$PA" | grep -cE '^ +arch,')" "1"
chk "start: pipeline 인자에 has_super 가 있다 (INPUT.md 슬롯 그대로)" "$(printf '%s\n' "$PA" | grep -cE '^ +has_super,')" "1"
chk "start: pipeline 인자에 bl_surface 를 항상 넘기지 않는다" "$(printf '%s\n' "$PA" | grep -cw 'bl_surface')" "0"
chk "start: arch 는 기본값이 아니라 INPUT.md 에 기록한 도출값"  "$(cn_has "$SS" '**Pass `arch` as the derived value recorded in INPUT.md, never a default.**')" "yes"
chk "start: 아키텍처는 입력이 아니라 도출값"             "$(cn_has "$SS" '**Derived**, not input')" "yes"
chk "start: 첫 컨테이너로 --detect-arch 를 돌린다"        "$(cn_has "$SS" 'stage_map.py --detect-arch <bootloader_path>')" "yes"
chk "start: unknown 은 정직한 답이고 기본값으로 대신하지 않는다" "$(cn_has "$SS" '**`unknown` is an honest answer;')" "yes"
chk "start: 기본값(arm64)으로 대신하지 않는다"            "$(cn_has "$SS" 'never replace it with the default arm64')" "yes"
chk "start: 옛 'arch 는 넘기지 않는다' 서술이 없다"        "$(cn_flat_has "$SS" '**`arch` is not passed.**')" "no"
chk "start: 옛 '두 해석으로 읽고' 서술이 없다 (컨테이너는 --detect-arch)" "$(cn_flat_has "$SS" 'two readings')" "no"
chk "start: 재개에서 사람이 arch 를 고치는 길 (INPUT.md 의 arch)" "$(cn_has "$SS" 'edit `arch` in INPUT.md')" "yes"
chk "start: 하드웨어 해시 예외는 잠정"               "$(cn_has "$SS" 'a provisional one the user has not yet approved')" "yes"
# 코드가 그렇게 읽는다: 파이프라인은 arch 입력 'unknown' 을 도출로 보내고 has_super 는 args 에서만 읽는다
chk "pipeline.js: arch 입력 unknown 은 도출 (start 의 서술과 맞는다)" "$(cn_has "$PJ" "archInput !== 'unknown'")" "yes"
chk "pipeline.js: has_super 는 args.has_super === true 로만 읽는다" "$(cn_has "$PJ" 'const hasSuper = args?.has_super === true')" "yes"
chk "pipeline.js: 분석가의 답 스키마에 has_super 가 없다 (start 가 되읽지 않는다고 적은 근거)" "$(awk '/^const ANALYST_SCHEMA/{f=1} f{print} f && /^}/{exit}' "$PJ" | grep -c 'has_super')" "0"
chk "start: has_super 는 파이프라인이 되읽지 않는다고 적는다" "$(cn_has "$SS" '**The pipeline does not read `has_super` back.**')" "yes"
# INPUT.md 슬롯표: start 가 쓰는 슬롯과 출처, status · export 가 읽는 슬롯이 같다
for sl in model build target bootloader_path has_super arch arch_basis bl_surface soc_family soc_family_evidence; do
    chk "start: INPUT.md 슬롯표에 $sl" "$(cn_has "$SS" "| \`$sl\` |")" "yes"
done
chk "start: 슬롯의 값마다 출처가 있고 없으면 unknown"      "$(cn_has "$SS" '**Every value has a source; no source → `unknown`.**')" "yes"
chk "start: 재개에서는 INPUT.md 값을 덮어쓰지 않는다"     "$(cn_has "$SS" '**On resume never overwrite values**')" "yes"
chk "start: .active 를 쓴다"                              "$(cn_has "$SS" 'Write the current workspace id (new or resumed) on one line to `<WORKROOT>/.active`')" "yes"
chk "start: 커널 자산은 사용자에게 꺼내라고 하지 않는다 (파이프라인이 적재)" "$(cn_has "$SS" 'Never tell the user to run it')" "yes"
chk "start: 커맨드라인은 계획이 이름 붙인 파티션에"       "$(cn_flat_has "$SS" 'writes the UART combination into the partition the plan names')" "yes"
chk "start: 옛 'PARAM 파티션에 UART 조합을 기록한다' 가 없다" "$(cn_flat_has "$SS" 'writes the UART combination into the PARAM partition')" "no"
chk "start: 재개의 회차 번호 서술 (이어서 매긴다)"          "$(cn_has "$SS" 'After resume, round numbers continue after the last number')" "yes"
SU="$REPO/skills/status/SKILL.md"
chk "status: 슬롯이 없으면 PROGRESS.md 머리말로 대신하고 표시한다" "$(cn_has "$SU" 'PROGRESS.md` 머리말의 `목표 등급` 으로 대신하고')" "yes"
chk "status: .active 는 start 가 쓴다"                    "$(cn_has "$SU" '`start` 가 쓴다. 없으면 active 표시를 하지 않는다')" "yes"
chk "export: 슬롯이 없으면 PROGRESS.md 머리말, 그것도 없으면 추측하지 않는다" "$(cn_has "$EX" '목표 등급을 알 수 없다')" "yes"
chk "export: 머신 이름 규칙 (파이프라인의 <slug>-full)"    "$(cn_has "$EX" '`<slug>-full`')" "yes"
chk "pipeline.js: 머신 이름은 <slug>-full (export 의 서술과 맞는다)" "$(cn_has "$PJ" 'const machine = `${slug}-full`')" "yes"
chk "export: 키트가 REHOST_MEMDUMP_REGION 과 kernel_task_regex.txt 를 가져간다고 적는다" "$(cn_has "$EX" 'REHOST_MEMDUMP_REGION=<base>:<size>')" "yes"
chk "make_export.sh 가 REHOST_MEMDUMP_REGION 을 내보낸다 (export 서술의 코드 쪽)" "$(cn_has "$S/make_export.sh" 'export REHOST_MEMDUMP_REGION=')" "yes"
chk "make_export.sh 가 kernel_task_regex.txt 를 키트에 넣는다" "$(cn_has "$S/make_export.sh" 'kernel_task_regex.txt')" "yes"
chk "export: 호출 예에 MACHINE=<INPUT machine name> 이 없다 (INPUT.md 에는 그 슬롯이 없다)" "$(cn_has "$EX" 'MACHINE=<INPUT machine name>')" "no"
# smoke.sh 가 걸어 둔 조건 (start 에 'reset PC', pipeline.js 를 언급하는 스킬은 하나)
chk "start: 실행 범위('reset PC')가 남아 있다" "$(cn_has "$SS" 'reset PC')" "yes"
chk "pipeline.js 를 부르는 스킬은 하나"       "$(grep -l 'pipeline.js' "$REPO"/skills/*/SKILL.md | wc -l | tr -d ' ')" "1"

# =============================================================================
hdr "canon 4. fixer-secureboot 와 지식표: 하드웨어 해시 분기"

FS="$REPO/agents/fixer-secureboot.md"
FRT=$(cn_fixer_rules)
chk "fixer-secureboot: 해시 계산 위치를 먼저 도출"   "$(cn_has "$FS" '**First decide where the digest is computed.**')" "yes"
chk "fixer-secureboot: 소프트웨어 해시는 무패치 통과" "$(cn_has "$FS" 'Software hash - the premise that holds')" "yes"
chk "fixer-secureboot: 하드웨어 해시 절"              "$(cn_has "$FS" 'Hardware hash - the premise that does not hold')" "yes"
chk "fixer-secureboot: (a) 엔진 모델링"               "$(cn_has "$FS" '(a) Model the engine (kind M)')" "yes"
chk "fixer-secureboot: (b) 라벨 달린 우회"            "$(cn_has "$FS" '(b) Labelled bypass')" "yes"
chk "fixer-secureboot: (c) 정지"                      "$(cn_has "$FS" '(c) Stop')" "yes"
chk "fixer-secureboot: 라벨 규칙을 풀지 않는다"       "$(cn_has "$FS" 'loosen the labelling rule')" "yes"
cn_fr_chk "fixer-secureboot (공통 규칙 FIXER_RULES): 부작용 비움 금지"  'never `(기록 없음)`'
cn_fr_chk "fixer-secureboot (공통 규칙 FIXER_RULES): 패치 표 행 태그"   '/* bypass:<id> */'
chk "fixer-secureboot: 음성 시험은 건드리지 않는다"   "$(cn_has "$FS" 'the negative test stays possible')" "yes"
chk "fixer-secureboot: 머신이 성공 문자열을 내는 것은 계속 금지" "$(cn_has "$FS" 'the machine printing a success string')" "yes"
cn_fr_chk "fixer-secureboot (공통 규칙 FIXER_RULES): 계열 자료 줄을 읽는다" 'Family knowledge:'
chk "fixer-secureboot: 소프트웨어 해시의 무패치 전제는 그대로 남아 있다" "$(cn_has "$FS" 'So verification is supposed to pass')" "yes"
chk "fixer-secureboot: 하드웨어 해시 선언은 fixer 의 몫이 아니다" "$(cn_has "$FS" 'You do not get to declare it a hardware hash.')" "yes"
chk "fixer-secureboot: STATIC.md 의 hash_engine 행을 먼저 읽는다" "$(cn_has "$FS" '**Read STATIC.md first.**')" "yes"
chk "fixer-secureboot: 행이 없으면 소프트웨어 해시로 다룬다" "$(cn_has "$FS" 'treat the firmware as a software')" "yes"
chk "fixer-secureboot: 행을 스스로 쓰지 않는다"       "$(cn_has "$FS" 'do not write the row yourself')" "yes"
chk "fixer-secureboot: (b) 는 hash_engine 행이 있을 때만" "$(cn_has "$FS" 'Only if (a) is not feasible and the `hash_engine` row exists.')" "yes"
chk "fixer-secureboot: 예외가 잠정이라고 적는다"      "$(cn_has "$FS" 'also **provisional**')" "yes"
chk "fixer-secureboot: 금지 변경의 예외도 hash_engine 행이 조건" "$(cn_has "$FS" 'For a hardware-hash firmware (the `hash_engine` row exists)')" "yes"
FU="$REPO/knowledge/faults_unified.md"
chk "faults_unified: avb_verify_fail 행에 분기"       "$(grep '^| `avb_verify_fail`' "$FU" | grep -c 'Hardware engine')" "1"
chk "faults_unified: 함정 목록에도 분기"              "$(cn_has "$FU" 'Do not patch out `avb_verify_fail` when the hash is software.')" "yes"
chk "faults_unified: 라벨 없는 우회를 허용하지 않는다" "$(cn_has "$FU" 'labelled bypass')" "yes"

# =============================================================================
hdr "canon 5. 문서 정합성"

# README: 시험 수 자리표시자가 남지 않았다
RM="$REPO/README.md"
chk "README: 자리표시자가 남지 않았다"       "$(cn_has "$RM" '__PARTS_COUNT__')" "no"
chk "README: MediaTek 은 가이드 수준이라고 적는다" "$(cn_has "$RM" '**가이드 수준.**')" "yes"
chk "README: 플러그인이 끝까지 진행한 적은 없다고 적는다" "$(cn_has "$RM" '플러그인이 자동으로 이 계열의 기기를 끝까지 진행한 적은 없다')" "yes"
chk "README: 실제 QEMU 실행 없음을 유지"      "$(cn_has "$RM" '| 실제 QEMU 실행 | **없음**')" "yes"
chk "README: 하드웨어 해시 예외는 잠정이다"   "$(cn_has "$RM" '사용자가 아직 승인하지 않은 잠정 예외')" "yes"
chk "README: 옛 196개 표기가 없다"            "$(cn_has "$RM" '시험 196개')" "no"
chk "README: BLOCKED_ARCH 의 옛 설명이 없다"  "$(cn_has "$RM" '진입 스텁 시그니처 미정의')" "no"
# components.md
CP="$REPO/docs/components.md"
chk "components: 폐기된 6항목 표가 없다"      "$(cn_has "$CP" '| 5 | 스토리지 이중 구동 |')" "no"
chk "components: 검증 표가 게이트 1~3 과 참고 4~7" "$(grep -cE '^\| [1-3] \| \*\*게이트\*\*|^\| [4-7] \| 참고' "$CP")" "7"
for sc in clean_env.sh qemu_tree.sh family_kit.py detect_medium.py memdump_observe.py verify_gates.py verify_prep.py make_negative_image.py env_manifest.json faults_mediatek.md runbook_mediatek.md machine_mixed_arch.c.tmpl; do
    chk "components: $sc" "$(cn_has "$CP" "$sc")" "yes"
done
chk "components: 새 fixer 서술 정정"          "$(cn_has "$CP" '**새 fixer 는 파일 하나와 등록 몇 줄이 아니다.**')" "yes"
# onboarding: 정지 코드 표, 05 의 버전 하드코딩 제거
O2="$REPO/docs/onboarding/02-unified-chain.md"
chk "README 정지 표: BLOCKED_KO"              "$(cn_has "$RM" '| `BLOCKED_KO` |')" "yes"
chk "README 정지 표: BLOCKED_BUILD"           "$(cn_has "$RM" '| `BLOCKED_BUILD` |')" "yes"
chk "onboarding 02: 정지 코드 표를 README 와 중복해 두지 않는다" "$(grep -c '^| `BLOCKED_' "$O2")" "0"
chk "onboarding 02: 옛 BLOCKED_ARCH 서술이 없다" "$(cn_has "$O2" '진입 스텁 시그니처 미정의')" "no"
O5="$REPO/docs/onboarding/05-plugin-check.md"
chk "onboarding 05: 버전이 하드코딩되어 있지 않다" "$(grep -cE '`[0-9]+\.[0-9]+\.[0-9]+`|V=[0-9]+\.[0-9]+\.[0-9]+' "$O5")" "0"
# 엠대시 없음 (0.25.2 에서 정한 문체 규칙)
EMD=0
for f in "$RM" "$CP" "$REPO"/docs/onboarding/*.md; do
    n=$(grep -c '—' "$f"); EMD=$((EMD + n))
done
chk "README · components · onboarding 에 엠대시 없음" "$EMD" "0"

# README · components · onboarding 의 상대 링크가 풀린다
cat > "$CN/links.py" <<'PY'
import os, re, sys
repo = sys.argv[1]
bad = []
def check(path):
    base = os.path.dirname(path)
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"```.*?```", "", text, flags=re.S)       # 코드 블록 안의 괄호는 링크가 아니다
    text = re.sub(r"`[^`\n]*`", "", text)                     # 인라인 코드도
    for m in re.finditer(r"\[[^\]\n]*\]\(([^)\s]+)\)", text):
        t = m.group(1)
        if re.match(r"^[a-z]+://", t) or t.startswith("mailto:") or t.startswith("#"):
            continue
        f = t.split("#", 1)[0]
        if not f:
            continue
        if not os.path.exists(os.path.normpath(os.path.join(base, f))):
            bad.append("%s -> %s" % (os.path.relpath(path, repo), t))
for f in ("README.md", "docs/components.md", "docs/onboarding/README.md"):
    check(os.path.join(repo, f))
print("OK" if not bad else "BAD " + "; ".join(bad))
PY
chk "README · components · onboarding 의 링크가 풀린다" "$(python3 "$CN/links.py" "$REPO")" "OK"
# 하드웨어 해시 선행 조건의 기계 검사(hash_engine_row_missing)가 구현되면, CHANGELOG · README 는 "아직 없다" 는 옛 서술을 쓰지 않는다
if grep -qs '"kind": "hash_engine_row_missing"' "$S/verify_gates.py"; then
    chk "CHANGELOG 0.28.0: '기계 검사는 아직 없다' 가 없다" "$(printf '%s\n' "$C28" | grep -c '기계 검사는 아직 없다')" "0"
    chk "README: '기계 검사는 아직 없다' 가 없다" "$(cn_has "$RM" '기계 검사는 아직 없다')" "no"
fi
chk "CHANGELOG 0.28.0: 2차 작업 절" "$(printf '%s\n' "$C28" | grep -c '^### 2차 작업')" "1"
chk "CHANGELOG 0.28.0: 'start 의 도출이 이 개정에 없다' 는 옛 서술이 없다" "$(printf '%s\n' "$C28" | grep -c '이 개정에 들어 있지 않다')" "0"
chk "CHANGELOG 0.28.0: 전체 smoke 를 최종 점검에서 끝까지 돌렸다고 적고 옛 서술은 없다" "$(printf '%s\n' "$C28" | grep -c '전체 `tests/smoke.sh` 는 최종 점검에서 끝까지 돌렸다')/$(printf '%s\n' "$C28" | grep -c '2차 작업 뒤에 돌리지 않았다')" "1/0"
chk "README: 전체 smoke 와 영역별 시험이 통과한다고 적고 옛 개수가 없다" "$(cn_has "$RM" '전체 `tests/smoke.sh` 와 영역별 시험')/$(cn_has "$RM" '2,557')" "yes/no"
chk "CHANGELOG 항목 순서: 0.29.2 · 0.29.1 · 0.29.0 · 0.28.0 · 0.27.0 (0.29.2·0.29.1·0.29.0·0.28.0 미배포, 0.27.0 이 배포본)" "$(grep -E '^## [0-9]+\.[0-9]+\.[0-9]+ ' "$REPO/CHANGELOG.md" | sed -n 1,5p | awk '{print $2}' | tr '\n' ' ')" "0.29.2 0.29.1 0.29.0 0.28.0 0.27.0 "

chk "make_resume.py 에 진행 가이드 단계 필드가 없다" "$(grep -ciE 'runbook|진행 가이드' "$S/make_resume.py")" "0"
chk "onboarding 03: 커맨드라인은 PARAM 파티션에 라는 옛 제목이 없다" "$(cn_has "$REPO/docs/onboarding/03-boot-medium.md" '### 커맨드라인은 PARAM 파티션에')" "no"
chk "components: --detect-arch" "$(cn_has "$CP" '`--detect-arch <경로>`')" "yes"
chk "components: 커널 자산 적재는 파이프라인이" "$(cn_has "$CP" '**파이프라인이 F2 이상에서 Analyze 앞에 부른다.**')" "yes"
chk "components: 주소 창 표 (참고 8)" "$(grep -c '^| 8 | 참고 | 주소 창 표' "$CP")" "1"
chk "components: INPUT.md 슬롯표를 start 가 쓴다" "$(cn_has "$CP" '입력 슬롯표 (`start` 가 쓴다')" "yes"
chk "코드: 참고 8 (주소 창 표) 이 verify.py 에 있다" "$(cn_has "$S/verify.py" 'address_windows')" "yes"


# =============================================================================
hdr "canon 6. make_export.sh: 매체 전달, 펌웨어 없는 키트, 계열 패치 세트"

bash -n "$S/make_export.sh"
chk "make_export.sh 문법" "$?" "0"
/bin/bash -n "$S/make_export.sh" 2>/dev/null
chk "make_export.sh 문법 (시스템 bash)" "$?" "0"

WS="$CN/ws"; mkdir -p "$WS"/{03_bootloader,06_machine,07_logs,fw,02_unpacked}
printf 'CONTAINER-BYTES' > "$WS/03_bootloader/preloader.img"
printf 'MEDIUM-BYTES'    > "$WS/fw/lu0.img"
printf '{"partitions":[]}' > "$WS/lu_manifest.json"
printf '{"partitions":{}}' > "$WS/fw/lu_provenance.json"
printf '### 우회 #1\n- 대상: a\n' > "$WS/06_machine/bypasses.md"
printf 'int x;\n' > "$WS/06_machine/machine_full.c"
printf 'kernel_entry\tjump to K64\n' > "$WS/milestone_tokens.txt"
printf '{}' > "$WS/stage_map.json"
printf '{"channel":"memdump","region_base":"0x50100000","region_size":16384,"console_size":4096,"source":"cmdline","evidence":"synthetic"}' > "$WS/memdump_plan.json"
printf '1.0 [   0.000000] Linux version synthetic\n' > "$WS/07_logs/kernel_1.log"
printf 'host line\n' > "$WS/07_logs/host_1.txt"
cat > "$CN/fakeq" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "fake qemu"; exit 0; fi
echo "FAKEQ ARGS: $*"
EOF
chmod +x "$CN/fakeq"

K1="$CN/kit_bundled"
WS="$WS" DEST="$K1" QEMU="$CN/fakeq" MACHINE=mt_synth SURFACE=none FAMILY=mediatek \
    bash "$S/make_export.sh" >"$CN/mk1.log" 2>&1
chk "묶음 키트: 종료코드 0" "$?" "0"
chk "묶음 키트: 컨테이너 이름을 따른다 (preloader.img)" "$([ -f "$K1/firmware/preloader.img" ] && echo yes || echo no)" "yes"
chk "묶음 키트: 합성 매체를 넣는다"        "$([ -f "$K1/firmware/lu0.img" ] && echo yes || echo no)" "yes"
bash -n "$K1/run.sh"
chk "묶음 키트: run.sh 문법"               "$?" "0"
chk "묶음 키트: run.sh 가 -drive 로 매체를 넘긴다" "$(cn_has "$K1/run.sh" 'id=lu0,snapshot=on')" "yes"
chk "묶음 키트: run.sh 가 컨테이너를 -kernel 로" "$(cn_has "$K1/run.sh" 'firmware/preloader.img')" "yes"
chk "묶음 키트: SURFACE=none 이면 명령을 치지 않는다" "$(cn_has "$K1/run.sh" '--surface none')" "yes"
chk "묶음 키트: --cmd 가 없다"             "$(cn_has "$K1/run.sh" '--cmd ')" "no"
chk "묶음 키트: -m 을 넘긴다 (회차와 같은 2G)" "$(cn_has "$K1/run.sh" '-m 2G')" "yes"
chk "묶음 키트: build.sh 가 mediatek 세트를 적용" "$(cn_has "$K1/scripts/build.sh" '--family mediatek')" "yes"
chk "묶음 키트: build.sh 에 표식이 남지 않았다" "$(cn_has "$K1/scripts/build.sh" '__PATCH_FAMILY__')" "no"
bash -n "$K1/scripts/build.sh"
chk "묶음 키트: build.sh 문법"             "$?" "0"
chk "묶음 키트: patch_qemu_core.py 를 키트에 넣는다" "$([ -f "$K1/scripts/patch_qemu_core.py" ] && echo yes || echo no)" "yes"
chk "묶음 키트: memdump 관측기를 넣는다"   "$([ -f "$K1/scripts/memdump_observe.py" ] && [ -f "$K1/scripts/memdump_plan.json" ] && echo yes || echo no)" "yes"
chk "묶음 키트: run.sh 가 관측기를 돌린다" "$(cn_has "$K1/run.sh" 'memdump_observe.py')" "yes"
chk "묶음 키트: 커널 로그를 evidence 에"   "$([ -f "$K1/evidence/kernel_1.log" ] && echo yes || echo no)" "yes"
chk "묶음 키트: 호스트 줄도 evidence 에 (증거 아님으로 표기됨)" "$([ -f "$K1/evidence/host_1.txt" ] && echo yes || echo no)" "yes"
chk "묶음 키트: lu_provenance.json 을 루트에" "$([ -f "$K1/lu_provenance.json" ] && echo yes || echo no)" "yes"
chk "묶음 키트: SHA256SUMS 를 만들지 않는다 (이전 동작)" "$([ -f "$K1/firmware/SHA256SUMS" ] && echo yes || echo no)" "no"
# 가짜 QEMU 로 run.sh 를 실제로 돌려 인자를 본다
RUN1=$(cd "$K1" && perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1)
chk "묶음 키트: 실행하면 QEMU 에 -drive 가 간다" "$(printf '%s' "$RUN1" | grep -c 'FAKEQ ARGS:.*-drive file=.*firmware/lu0.img,if=none,format=raw,id=lu0,snapshot=on')" "1"
chk "묶음 키트: 실행하면 -monitor unix 가 간다 (관측기)" "$(printf '%s' "$RUN1" | grep -c 'FAKEQ ARGS:.*-monitor unix:')" "1"

# 계열을 주지 않으면 이전 동작 (exynos 세트)
K0="$CN/kit_default"
WS="$WS" DEST="$K0" QEMU="$CN/fakeq" MACHINE=mt_synth bash "$S/make_export.sh" >"$CN/mk0.log" 2>&1
chk "FAMILY 없음: build.sh 는 exynos 세트 (이전 동작)" "$(cn_has "$K0/scripts/build.sh" '--family exynos')" "yes"
chk "SURFACE 기본: shell + help"           "$(cn_has "$K0/run.sh" "--cmd 'help'")" "yes"

# 펌웨어 없는 키트
K2="$CN/kit_nofw"
WS="$WS" DEST="$K2" QEMU="$CN/fakeq" MACHINE=mt_synth BUNDLE_FIRMWARE=0 bash "$S/make_export.sh" >"$CN/mk2.log" 2>&1
chk "펌웨어 없는 키트: 종료코드 0"          "$?" "0"
chk "펌웨어 없는 키트: 컨테이너를 넣지 않는다" "$([ -f "$K2/firmware/preloader.img" ] && echo yes || echo no)" "no"
chk "펌웨어 없는 키트: 매체를 넣지 않는다"   "$([ -f "$K2/firmware/lu0.img" ] && echo yes || echo no)" "no"
chk "펌웨어 없는 키트: README.txt"           "$([ -s "$K2/firmware/README.txt" ] && echo yes || echo no)" "yes"
chk "펌웨어 없는 키트: SHA256SUMS 두 줄"     "$(wc -l < "$K2/firmware/SHA256SUMS" | tr -d ' ')" "2"
H1=$(awk '$2=="preloader.img"{print $1}' "$K2/firmware/SHA256SUMS")
if command -v sha256sum >/dev/null 2>&1; then H2=$(sha256sum "$WS/03_bootloader/preloader.img" | awk '{print $1}')
else H2=$(shasum -a 256 "$WS/03_bootloader/preloader.img" | awk '{print $1}'); fi
chk "펌웨어 없는 키트: 기록된 해시가 컨테이너의 것" "$H1" "$H2"
chk "펌웨어 없는 키트: lu_manifest.json 은 있다 (매체를 다시 만드는 근거)" "$([ -f "$K2/lu_manifest.json" ] && echo yes || echo no)" "yes"
chk "펌웨어 없는 키트: build_lu.py 를 넣는다" "$([ -f "$K2/scripts/build_lu.py" ] && echo yes || echo no)" "yes"
# 파일이 없으면 멈춘다, 같은 파일이면 돈다, 다르면 멈춘다, 건너뛰기는 명시해야 한다
R_NONE=$(cd "$K2" && perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1); RC_NONE=$?
chk "펌웨어 없는 키트: 파일이 없으면 run.sh 가 멈춘다" "$RC_NONE" "1"
chk "펌웨어 없는 키트: 없다고 알린다"        "$(printf '%s' "$R_NONE" | grep -c 'firmware/preloader.img 없음')" "1"
cp "$WS/03_bootloader/preloader.img" "$WS/fw/lu0.img" "$K2/firmware/"
R_OK=$(cd "$K2" && perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1)
chk "펌웨어 없는 키트: 같은 파일이면 돈다"    "$(printf '%s' "$R_OK" | grep -c 'FAKEQ ARGS:')" "1"
printf 'X' >> "$K2/firmware/lu0.img"
R_BAD=$(cd "$K2" && perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1); RC_BAD=$?
chk "펌웨어 없는 키트: 해시가 다르면 멈춘다"  "$RC_BAD" "1"
chk "펌웨어 없는 키트: 같은 재현이 아니라고 알린다" "$(printf '%s' "$R_BAD" | grep -c '같은 재현이 아닙니다')" "1"
chk "펌웨어 없는 키트: 해시 불일치에서는 QEMU 를 띄우지 않는다" "$(printf '%s' "$R_BAD" | grep -c 'FAKEQ ARGS:')" "0"
R_SKIP=$(cd "$K2" && SKIP_SUM_CHECK=1 perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1)
chk "펌웨어 없는 키트: SKIP_SUM_CHECK=1 이면 돈다" "$(printf '%s' "$R_SKIP" | grep -c 'FAKEQ ARGS:')" "1"

# =============================================================================
hdr "canon 7. 키트는 회차(run_full.sh)가 돈 조건으로 돈다: QEMU 인자와 시간 한도"

# 리뷰 지적: run.sh 에 -accel tcg,thread=single 이 없었고(혼합 머신), 시간 한도가 20초였고, 회차가 주지 않는
# -cpu cortex-a76 을 고정으로 넘겼다. 같은 워크스페이스로 run_full.sh 와 run.sh 를 모두 돌려 QEMU 가 받은
# 인자를 직접 비교한다 (-M, -m, -accel, -cpu).
local RQ KIND KW KK KS RF KF RT0 T0 ELAPSED OVSEC
RQ="$CN/recq"
cat > "$RQ" <<'EOF'
#!/usr/bin/env bash
# 받은 인자를 기록하는 가짜 QEMU. RECQ_SLEEP 이 있으면 그만큼 살아 있다 (시간 한도 시험용)
if [ "$1" = "--version" ]; then echo "fake qemu"; exit 0; fi
printf '%s\n' "$*" >> "$RECQ_OUT"
[ -n "${RECQ_SLEEP:-}" ] && sleep "$RECQ_SLEEP"
exit 0
EOF
chmod +x "$RQ"
cat > "$CN/qflags.py" <<'PY'
import sys
t = open(sys.argv[1]).read().split()
want = {"-M": "M", "-m": "m", "-accel": "accel", "-cpu": "cpu"}
got = {}
for i, a in enumerate(t[:-1]):
    if a in want:
        got[want[a]] = t[i + 1]
print(";".join("%s=%s" % (k, got.get(k, "-")) for k in ("M", "m", "accel", "cpu")))
PY
cn_mkws() {   # cn_mkws <이름> <머신 소스 한 줄> -> 워크스페이스 경로
    local w="$CN/$1"; mkdir -p "$w"/{03_bootloader,06_machine,07_logs,fw,02_unpacked}
    printf 'CONTAINER' > "$w/03_bootloader/preloader.img"; printf 'MEDIUM' > "$w/fw/lu0.img"
    printf '%s\n' "$2" > "$w/06_machine/machine_full.c"
    printf '### 우회 #1\n- 대상: a\n' > "$w/06_machine/bypasses.md"
    echo "$w"
}
for KIND in mixed plain; do
    if [ "$KIND" = "mixed" ]; then KS='static void handoff_tick(void) {}'; else KS='int x;'; fi
    KW=$(cn_mkws "rt_$KIND" "$KS")
    export RECQ_OUT="$CN/round_$KIND.txt"; : > "$RECQ_OUT"
    QEMU="$RQ" TIMEOUT=7 TIMEOUT_PROBE=0 bash "$S/run_full.sh" "$KW" mt_synth "$KW/03_bootloader/preloader.img" help 1 none >/dev/null 2>&1
    RF=$(python3 "$CN/qflags.py" "$RECQ_OUT")
    KK="$CN/kit_rt_$KIND"
    # CPU 는 일부러 준다: 혼합 머신에서는 넘기지 않아야 하고, 그 외에도 명시했을 때만 넘어간다
    WS="$KW" DEST="$KK" QEMU="$RQ" MACHINE=mt_synth SURFACE=none CPU=cortex-a76 bash "$S/make_export.sh" >/dev/null 2>&1
    export RECQ_OUT="$CN/kit_$KIND.txt"; : > "$RECQ_OUT"
    (cd "$KK" && perl -e 'alarm 60; exec @ARGV' bash run.sh >/dev/null 2>&1)
    KF=$(python3 "$CN/qflags.py" "$RECQ_OUT")
    if [ "$KIND" = "mixed" ]; then
        chk "회차($KIND): 한 TCG 스레드로 돈다 (handoff_tick)" "$RF" "M=mt_synth;m=2G;accel=tcg,thread=single;cpu=-"
        chk "키트($KIND): 회차와 같은 -M -m -accel, CPU 를 줘도 -cpu 는 없다" "$KF" "$RF"
    else
        chk "회차($KIND): -accel 도 -cpu 도 없다" "$RF" "M=mt_synth;m=2G;accel=-;cpu=-"
        # 회차는 -cpu 를 주지 않으므로 키트가 주는 것은 사용자가 CPU 를 명시한 이 경우뿐이다
        chk "키트($KIND): CPU 를 명시하면 그 값만 -cpu 로 넘어간다" "$KF" "M=mt_synth;m=2G;accel=-;cpu=cortex-a76"
        # CPU 를 주지 않은 키트는 회차와 인자가 완전히 같다
        WS="$KW" DEST="$KK.nocpu" QEMU="$RQ" MACHINE=mt_synth SURFACE=none bash "$S/make_export.sh" >/dev/null 2>&1
        export RECQ_OUT="$CN/kit_${KIND}_nocpu.txt"; : > "$RECQ_OUT"
        (cd "$KK.nocpu" && perl -e 'alarm 60; exec @ARGV' bash run.sh >/dev/null 2>&1)
        chk "키트($KIND): CPU 를 주지 않으면 회차와 같은 인자" "$(python3 "$CN/qflags.py" "$RECQ_OUT")" "$RF"
    fi
    # 시간 한도: 회차가 쓴 값(input_summary.json 의 timeout_s)을 따른다
    chk "키트($KIND): 시간 한도 기본값이 회차가 쓴 값(7초)" "$(grep -c 'RUN_TIMEOUT_S="${RUN_TIMEOUT_S:-7}"' "$KK/run.sh")" "1"
    chk "키트($KIND): 하니스가 그 한도를 쓴다 (--timeout)" "$(grep -c -- '--timeout "$RUN_TIMEOUT_S"' "$KK/run.sh")" "1"
done
# 한도를 알려 주는 기록이 없으면 run_full.sh 의 기본값과 같다 (20초 같은 값을 따로 두지 않는다)
RT0=$(sed -n 's/^TIMEOUT="${TIMEOUT:-\([0-9][0-9]*\)}"$/\1/p' "$S/run_full.sh")
chk "run_full.sh 의 TIMEOUT 기본값을 찾았다" "$(printf '%s' "$RT0" | grep -cE '^[0-9]+$')" "1"
KW=$(cn_mkws rt_nosum 'int x;')
WS="$KW" DEST="$CN/kit_nosum" QEMU="$RQ" MACHINE=mt_synth bash "$S/make_export.sh" >/dev/null 2>&1
chk "키트: 기록이 없으면 시간 한도 기본값은 run_full.sh 의 기본값" "$(grep -c "RUN_TIMEOUT_S=\"\${RUN_TIMEOUT_S:-$RT0}\"" "$CN/kit_nosum/run.sh")" "1"
chk "키트: 옛 20초 한도가 남지 않았다" "$(grep -c -e '--timeout 20 ' -e ':-20}' "$CN/kit_nosum/run.sh")" "0"
# 내보낼 때 RUN_TIMEOUT_S 를 주면 그 값이 기록보다 이긴다
WS="$CN/rt_plain" DEST="$CN/kit_rt_env" QEMU="$RQ" MACHINE=mt_synth RUN_TIMEOUT_S=45 bash "$S/make_export.sh" >/dev/null 2>&1
chk "키트: 내보낼 때 준 RUN_TIMEOUT_S 가 기록보다 우선" "$(grep -c 'RUN_TIMEOUT_S="${RUN_TIMEOUT_S:-45}"' "$CN/kit_rt_env/run.sh")" "1"
# 돌릴 때 같은 이름으로 덮을 수 있고, 하니스가 실제로 그 한도로 끊는다 (가짜 QEMU 가 30초 산다)
export RECQ_OUT="$CN/kit_ov.txt"; : > "$RECQ_OUT"
T0=$SECONDS
(cd "$CN/kit_rt_plain" && RECQ_SLEEP=30 RUN_TIMEOUT_S=3 perl -e 'alarm 60; exec @ARGV' bash run.sh >/dev/null 2>&1)
ELAPSED=$((SECONDS - T0))
OVSEC=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["timeout_s"])' "$CN/kit_rt_plain/out/input_summary.json" 2>/dev/null)
chk "키트: 돌릴 때 RUN_TIMEOUT_S 로 덮으면 하니스가 그 한도를 쓴다" "$OVSEC" "3.0"
chk "키트: 한도에서 끊긴다 (30초 사는 QEMU 가 20초 안에 끝남)" "$([ "$ELAPSED" -lt 20 ] && echo yes || echo no)" "yes"
unset RECQ_OUT

# =============================================================================
hdr "canon 8. 키트의 메모리 덤프 환경: REHOST_MEMDUMP_REGION · kernel_task_regex.txt"

# 회차(run_full.sh)는 계획의 영역을 QEMU 환경으로 내보내고(머신의 쓰기 보호) 작업 폴더의 kernel_task_regex.txt 를 스캔에
# 넘긴다. 키트의 run.sh 도 같아야 한다: 같은 워크스페이스로 키트를 만들어, QEMU 가 받은 환경을 직접 찍는다.
local EQ KE KR1 KR2 KR3 KR4 KR5 NW NK RGX
EQ="$CN/envq"
cat > "$EQ" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "fake qemu"; exit 0; fi
echo "ENVQ REGION=${REHOST_MEMDUMP_REGION:-UNSET} TASKRX=${KERNEL_TASK_REGEX:-UNSET}"
EOF
chmod +x "$EQ"
RGX='\[[0-9]+:([A-Za-z0-9_]+)\]'
printf '\n%s\n' "$RGX" > "$CN/ws/kernel_task_regex.txt"        # 첫 줄은 비어 있다: 첫 비어 있지 않은 줄을 쓴다
KE="$CN/kit_env"
WS="$CN/ws" DEST="$KE" QEMU="$EQ" MACHINE=mt_synth SURFACE=none FAMILY=mediatek bash "$S/make_export.sh" >"$CN/mke.log" 2>&1
chk "환경 키트: 종료코드 0" "$?" "0"
chk "환경 키트: kernel_task_regex.txt 를 키트에 넣는다" "$([ -f "$KE/scripts/kernel_task_regex.txt" ] && echo yes || echo no)" "yes"
# (a) 계획이 있으면 영역을 내보낸다. 호출자 환경의 옛 값은 계획이 이긴다. 태스크 형식은 파일에서
KR1=$(cd "$KE" && REHOST_MEMDUMP_REGION=stale KERNEL_TASK_REGEX= perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1)
chk "환경 키트: 계획의 영역을 <base>:<size> 로 내보낸다 (옛 환경값이 아니라 계획의 값)" \
    "$(printf '%s\n' "$KR1" | grep -cF 'ENVQ REGION=0x50100000:0x4000 ')" "1"
chk "환경 키트: kernel_task_regex.txt 의 첫 비어 있지 않은 줄을 KERNEL_TASK_REGEX 로" \
    "$(printf '%s\n' "$KR1" | grep -cF "ENVQ REGION=0x50100000:0x4000 TASKRX=$RGX")" "1"
# (b) 명시한 KERNEL_TASK_REGEX 가 파일보다 이긴다
KR2=$(cd "$KE" && KERNEL_TASK_REGEX='X(y)' perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1)
chk "환경 키트: 환경에 명시한 KERNEL_TASK_REGEX 가 파일보다 이긴다" "$(printf '%s\n' "$KR2" | grep -cF 'TASKRX=X(y)')" "1"
# (c) 올바른 정규식이 아니면 쓰지 않고 알린다 (기본 형식으로 판정)
printf '%s\n' '([' > "$KE/scripts/kernel_task_regex.txt"
KR3=$(cd "$KE" && KERNEL_TASK_REGEX= perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1)
chk "환경 키트: 올바르지 않은 정규식은 내보내지 않는다" "$(printf '%s\n' "$KR3" | grep -cF 'TASKRX=UNSET')" "1"
chk "환경 키트: 올바르지 않은 정규식은 알린다" "$(printf '%s\n' "$KR3" | grep -c '경고: kernel_task_regex.txt')" "1"
chk "환경 키트: 정규식이 틀려도 영역은 내보낸다" "$(printf '%s\n' "$KR3" | grep -cF 'REGION=0x50100000:0x4000 ')" "1"
# (d) 파일이 없으면 기본 형식 (변수를 설정하지 않는다)
rm -f "$KE/scripts/kernel_task_regex.txt"
KR4=$(cd "$KE" && KERNEL_TASK_REGEX= perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1)
chk "환경 키트: 형식 파일이 없으면 KERNEL_TASK_REGEX 를 설정하지 않는다" "$(printf '%s\n' "$KR4" | grep -cF 'TASKRX=UNSET')" "1"
# (e) 계획이 없는 키트는 영역을 설정하지 않고 호출자 환경의 옛 값도 지운다 (run_full.sh 와 같다)
NW=$(cn_mkws env_noplan 'int x;')
NK="$CN/kit_env_noplan"
WS="$NW" DEST="$NK" QEMU="$EQ" MACHINE=mt_synth SURFACE=none bash "$S/make_export.sh" >"$CN/mkn.log" 2>&1
KR5=$(cd "$NK" && REHOST_MEMDUMP_REGION=stale perl -e 'alarm 60; exec @ARGV' bash run.sh 2>&1)
chk "환경 키트(계획 없음): 영역을 설정하지 않고 옛 환경값도 지운다" "$(printf '%s\n' "$KR5" | grep -cF 'ENVQ REGION=UNSET ')" "1"
chk "환경 키트(계획 없음): 형식 파일도 없다" "$([ -f "$NK/scripts/kernel_task_regex.txt" ] && echo yes || echo no)" "no"
# 회차 쪽도 같은 값을 만든다: 같은 계획에서 run_full.sh 가 쓰는 도구(memdump_observe.py region)가 키트와 같은 문자열
chk "회차와 키트가 같은 도구로 같은 영역 문자열을 만든다 (memdump_observe.py region)" \
    "$(python3 "$S/memdump_observe.py" region "$CN/ws/memdump_plan.json")" "0x50100000:0x4000"
rm -f "$CN/ws/kernel_task_regex.txt"

# 키트는 이 시험이 만든 폴더 안에만 생긴다 (저장소에 남기지 않는다)
chk "저장소에 rehost_exports 가 생기지 않았다" "$([ -e "$REPO/rehost_exports" ] && echo yes || echo no)" "no"

# =============================================================================
hdr "canon 8b. STATIC.md 회전은 검증이 읽는 사실(hash_engine 행 · 주소 창 표)을 잃지 않는다"

# static_rotate.py 는 오래된 `### round N` 하위 절을 보관 파일로 옮기면서 담당 열이 있는 정지점 행만 본문 표로
# 올린다. 그런데 해시 계산 위치를 묻는 에스컬레이션은 정지점 행이 아니라 `hash_engine` 행 하나를 그 하위 절에 쓰고
# (진행 가이드 · 분석가 14d), 주소 창 표도 같은 곳에 쓸 수 있다. 둘 다 verify_gates.py 가 STATIC.md 전체에서 읽는 사실이라,
# 회전이 그것을 보관 파일로 보내면 hash_engine_state 가 hardware 에서 absent 로 바뀌고 다음 표지 F 해시 우회가
# "해시가 하드웨어 엔진에서 계산된다는 행이 없습니다" 로 반려된다. 이 절은 합성 STATIC.md 로 회전 전후에 검증이 읽는 것이
# 같은지 본다 (값은 전부 합성이고 어느 펌웨어의 것도 아니다).
local ROT
cn_rot() { printf '%s\n' "$ROT" | sed -n "s/^$1=//p"; }
cat > "$CN/rot.py" <<'PYEOF'
"""rot.py <scripts_dir> <outdir> - static_rotate.py on synthetic STATIC.md records.

Prints key=value lines. What it asks: does a rotation change what verify_gates.py reads from
STATIC.md (the hash_engine state, the address-window tables) or what derived_facts.py reads
(the stop-point rows)? The records are synthetic; nothing here is a firmware value."""
import json
import os
import subprocess
import sys

S, OUT = sys.argv[1], sys.argv[2]
sys.path.insert(0, S)
import derived_facts as df   # noqa: E402
import verify_gates as vg    # noqa: E402

HEAD = ("# 정적 도출\n\n## 도출된 정지점\n\n"
        "| 시그니처 | 관측 | 메커니즘 (근거) | 담당 fixer | 시도할 변경 |\n|---|---|---|---|---|\n"
        "| `main_row` | 관측 | 근거 | `fixer-bootflow` | 변경 |\n")
HASH_ROW = "| hash_engine | hardware | digest 함수 0x1234, SMC id 0x82000001 |\n"
HASH_SOFT = "| hash_engine | software | 압축 라운드가 함수 0x4010 안에 있다 |\n"
HASH_LINE = "hash_engine: hardware (evidence: SMC id 0x82000001)\n"
WINDOWS = ("#### address windows\n\n"
           "| base | size | name | source | model | phase | kind | evidence | bypass | security_effect |\n"
           "|---|---|---|---|---|---|---|---|---|---|\n"
           "| 0x10000000 | 0x1000 | win_a | derived | stub | boot | read | 0x1234 | 3 | false |\n"
           "| 0x10001000 | 0x1000 | win_b | derived | stub | boot | read | 0x1238 | 4 | |\n")


def sub(n, body=""):
    prose = "".join("근거 문장 %d %d\n" % (n, i) for i in range(60))
    return "\n### round %d 재도출\n\n%s%s" % (n, prose, body)


def stop_row(name, fixer):
    return "| `%s` | 관측 | 근거 | `%s` | 변경 |\n" % (name, fixer)


def workdir(name, text):
    wd = os.path.join(OUT, name)
    os.makedirs(wd, exist_ok=True)
    with open(os.path.join(wd, "STATIC.md"), "w", encoding="utf-8") as fh:
        fh.write(text)
    return wd


def probe(wd):
    path = os.path.join(wd, "STATIC.md")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    st = vg.hash_engine_state(wd)
    tables = vg.address_window_tables(text)
    return {"hash": [st["status"], st["value"], st["evidence"], st["conflict"], st["rows"]],
            "tables": len(tables), "windows": sum(len(t["rows"]) for t in tables),
            "stop": [r["signature"] for r in df.parse_table(path)]}


def rotate(wd):
    proc = subprocess.run([sys.executable, os.path.join(S, "static_rotate.py"), wd,
                           "--keep", "1", "--max-bytes", "2000"],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return {"rotated": False, "error": proc.stderr.strip()[-200:]}


def out(key, value):
    print("%s=%s" % (key, value))


def rows_at(wd, *names):
    with open(os.path.join(wd, "STATIC.md"), encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    at = []
    for name in names:
        hits = [i for i, l in enumerate(lines) if l.startswith("| `%s` |" % name)]
        at.append(hits[0] if hits else -1)
    return at


# A: the hash_engine row and an address-window table sit in OLD escalation subsections
wd = workdir("a", HEAD + sub(1, stop_row("old_row", "fixer-memory")) + sub(2, HASH_ROW) + "\n" + WINDOWS
             + sub(3) + sub(4))
before = probe(wd)
res = rotate(wd)
after = probe(wd)
out("a_rotated", res.get("rotated"))
out("a_hash_before", before["hash"][0])
out("a_hash_after", after["hash"][0])
out("a_hash_same", before["hash"] == after["hash"])
out("a_tables_same", (before["tables"], before["windows"]) == (after["tables"], after["windows"]))
out("a_tables_before", before["tables"])
out("a_stop_same", before["stop"] == after["stop"] and "old_row" in after["stop"])
with open(os.path.join(wd, "08_docs", "static_archive.md"), encoding="utf-8") as fh:
    out("a_archive_has_prose", "근거 문장 2 0" in fh.read())
# a second rotation, after more escalations: nothing is carried twice, the main table stays one table
with open(os.path.join(wd, "STATIC.md"), "a", encoding="utf-8") as fh:
    fh.write(sub(5, stop_row("old_row2", "fixer-el3")) + sub(6))
before2 = probe(wd)
res2 = rotate(wd)
after2 = probe(wd)
out("a2_rotated", res2.get("rotated"))
out("a2_hash_same", before2["hash"] == after2["hash"] and before["hash"] == after2["hash"])
out("a2_hash_rows", after2["hash"][4])
out("a2_tables", "%d/%d" % (after2["tables"], after2["windows"]))
out("a2_stop_same", before2["stop"] == after2["stop"] and "old_row2" in after2["stop"])
at = rows_at(wd, "main_row", "old_row", "old_row2")
out("a2_main_table_contiguous", at[1] == at[0] + 1 and at[2] == at[1] + 1 and at[0] >= 0)

# B: an older row says hardware, a kept (newest) subsection corrects it: the newest still wins
wd = workdir("b", HEAD + sub(1, HASH_ROW) + sub(2) + sub(3, HASH_SOFT))
before = probe(wd)
rotate(wd)
after = probe(wd)
out("b_value", after["hash"][1])
out("b_same", before["hash"] == after["hash"])
out("b_conflict", after["hash"][3])

# C: the one-line form
wd = workdir("c", HEAD + sub(1, HASH_LINE) + sub(2) + sub(3))
before = probe(wd)
rotate(wd)
after = probe(wd)
out("c_value", after["hash"][1])
out("c_same", before["hash"] == after["hash"])

# D: a quoted example inside a code fence is not a fact and must not become one
wd = workdir("d", HEAD + sub(1, "```\n" + HASH_ROW + "```\n") + sub(2) + sub(3))
before = probe(wd)
rotate(wd)
after = probe(wd)
out("d_before", before["hash"][0])
out("d_after", after["hash"][0])

# E: no escalation wrote either fact: nothing is invented
wd = workdir("e", HEAD + sub(1) + sub(2) + sub(3))
rotate(wd)
after = probe(wd)
out("e_after", "%s/%d" % (after["hash"][0], after["tables"]))

# F: a hash_engine row written directly under a window table is a line of that table (the parsers
# cannot tell them apart): it is carried once, inside the table, and both readings stay the same
wd = workdir("f", HEAD + sub(1) + sub(2, WINDOWS + HASH_ROW) + sub(3) + sub(4))
before = probe(wd)
rotate(wd)
after = probe(wd)
out("f_same", before["hash"] == after["hash"] and before["hash"][0] == "hardware"
    and (before["tables"], before["windows"]) == (after["tables"], after["windows"]))

# G: a window table that only a heading names (its header lacks the template's columns)
wd = workdir("g", HEAD + sub(1) + sub(2, "#### 주소 창\n\n| 구간 | 값 |\n|---|---|\n| a | 1 |\n| b | 2 |\n")
             + sub(3) + sub(4))
before = probe(wd)
rotate(wd)
after = probe(wd)
out("g_tables", "%d/%d>%d/%d" % (before["tables"], before["windows"], after["tables"], after["windows"]))

# H: a second rotation brings a NEWER hash_engine row: the carried (older) row stays above it
wd = workdir("h", HEAD + sub(1, HASH_ROW) + sub(2) + sub(3))
rotate(wd)
with open(os.path.join(wd, "STATIC.md"), "a", encoding="utf-8") as fh:
    fh.write(sub(4, HASH_SOFT) + sub(5) + sub(6))
before = probe(wd)
rotate(wd)
after = probe(wd)
with open(os.path.join(wd, "STATIC.md"), encoding="utf-8") as fh:
    text = fh.read()
out("h_same", before["hash"] == after["hash"] and after["hash"][1] == "software" and after["hash"][3])
out("h_order", text.index("| hardware |") < text.index("| software |"))

# I: two hash_engine rows with different values, both in OLD subsections: carried in file order
wd = workdir("i", HEAD + sub(1, HASH_ROW) + sub(2, HASH_SOFT) + sub(3) + sub(4))
before = probe(wd)
rotate(wd)
after = probe(wd)
out("i_same", before["hash"] == after["hash"] and after["hash"][1] == "software" and after["hash"][3])
PYEOF
ROT=$(python3 "$CN/rot.py" "$S" "$CN/rot" 2>&1)
chk "회전 시험 입력: 오래된 하위 절의 행이 회전 전에는 hardware 로 읽힌다 (입력이 유효하다)" "$(cn_rot a_hash_before)" "hardware"
chk "회전 시험 입력: 회전이 실제로 일어난다" "$(cn_rot a_rotated)" "True"
chk "회전: 오래된 하위 절의 hash_engine 행이 회전 뒤에도 hardware 로 읽힌다" "$(cn_rot a_hash_after)" "hardware"
chk "회전: hash_engine 상태(값 · 근거 · 충돌 · 행 수)가 회전 전후에 같다" "$(cn_rot a_hash_same)" "True"
chk "회전: 오래된 하위 절의 주소 창 표(표 수 · 행 수)가 회전 전후에 같다" "$(cn_rot a_tables_same)" "True"
chk "회전: 정지점 행은 여전히 본문 표로 올라간다" "$(cn_rot a_stop_same)" "True"
chk "회전: 근거 산문은 보관 파일로 간다 (옮긴 것은 사실뿐이다)" "$(cn_rot a_archive_has_prose)" "True"
chk "회전 두 번째: 더 쌓인 뒤 다시 돌려도 hash_engine 상태가 같다" "$(cn_rot a2_hash_same)" "True"
chk "회전 두 번째: 옮긴 행이 다시 옮겨져 늘어나지 않는다 (hash_engine 행 1개)" "$(cn_rot a2_hash_rows)" "1"
chk "회전 두 번째: 주소 창 표가 늘어나지 않는다 (표 1개 · 행 2개)" "$(cn_rot a2_tables)" "1/2"
chk "회전 두 번째: 정지점 행 승격이 계속된다" "$(cn_rot a2_stop_same)" "True"
chk "회전 두 번째: 본문 정지점 표가 옮겨 온 표 뒤로 밀려 끊기지 않는다" "$(cn_rot a2_main_table_contiguous)" "True"
chk "회전: 옛 하위 절의 hardware 와 남은 최신 하위 절의 software 중 마지막(최신)이 이긴다" "$(cn_rot b_value)" "software"
chk "회전: 그 두 행의 상태(충돌 표시 포함)가 회전 전후에 같다" "$(cn_rot b_same)" "True"
chk "회전: 두 행이 모두 있었다는 사실(충돌)이 남는다" "$(cn_rot b_conflict)" "True"
chk "회전: 한 줄 형태(hash_engine: hardware (evidence: …))도 옮긴다" "$(cn_rot c_value)" "hardware"
chk "회전: 한 줄 형태의 상태가 회전 전후에 같다" "$(cn_rot c_same)" "True"
chk "회전: 코드 펜스 안의 인용 예시는 회전 전후 모두 사실이 아니다 (옮겨서 사실로 만들지 않는다)" "$(cn_rot d_before)/$(cn_rot d_after)" "absent/absent"
chk "회전: 둘 다 쓰이지 않았으면 만들어 내지 않는다" "$(cn_rot e_after)" "absent/0"
chk "회전: 주소 창 표 바로 아래에 쓴 hash_engine 행은 그 표의 한 줄로 한 번만 옮겨진다 (상태 · 표 수 · 행 수가 같다)" "$(cn_rot f_same)" "True"
chk "회전: 제목으로만 주소 창 표임이 드러나는 표(열 이름이 템플릿과 다르다)도 옮긴다" "$(cn_rot g_tables)" "1/2>1/2"
chk "회전 두 번째: 더 새로운 hash_engine 행이 뒤에 와도 파일 순서가 유지되어 마지막 행이 이긴다" "$(cn_rot h_same)/$(cn_rot h_order)" "True/True"
chk "회전: 오래된 하위 절 둘에 값이 다른 hash_engine 행이 있어도 파일 순서로 옮겨 마지막 행이 이기고 충돌이 남는다" "$(cn_rot i_same)" "True"
# 문서가 이 결함을 말한다: 구성 요소 표의 한 줄과 미결 목록 C16, 변경 이력의 남긴 것
chk "components.md: static_rotate.py 행이 hash_engine 행과 주소 창 표를 말한다" \
    "$(grep '^| `static_rotate.py` |' "$CP" | grep -c 'hash_engine.*주소 창\|주소 창.*hash_engine')" "1"
chk "CHANGELOG.md: 2차 작업이 닫지 못해 남긴 것에 C16 이 있다" \
    "$(awk '/2차 작업이 닫지 못해 남긴 것/{f=1} f&&/^$/{exit} f' "$REPO/CHANGELOG.md" | grep -c 'C16')" "1"
rm -rf "$CN/rot" "$CN/rot.py"

# =============================================================================
hdr "canon 8c. 중립화와 정리 (0.29.0): 지운 것을 문서가 더 이상 가리키지 않고, 정본이 한 기기의 값을 일반 정의로 적지 않는다"

# 0.28.0 은 배포되지 않았고 0.29.0 이 그 작업을 처음 담는다. 문서가 그렇게 말하고, 이 정리가 지운 것(옛 --track 흐름 ·
# verify_byte_match.py · docs/bootchain-feasibility.md)을 아무 문서도 가리키지 않는다. 정본은 한 부트로더의 점프 문자열과
# 한 벤더의 성분 이름을 일반 정의처럼 적지 않는다. 문서가 말하는 새 동작은 코드의 표식과 같이 본다.
C29=$(awk '/^## 0\.29\.0 /{f=1;next} /^## /{f=0} f' "$REPO/CHANGELOG.md")
chk "CHANGELOG 0.29.0: 0.28.0 은 배포되지 않았다고 적는다" "$(printf '%s\n' "$C29" | grep -c '0\.28\.0 은 배포되지 않았다')" "1"
chk "CHANGELOG 0.29.0: 동작이 달라지는 곳 절" "$(printf '%s\n' "$C29" | grep -c '^### 동작이 달라지는 곳')" "1"
chk "CHANGELOG 0.29.0: 열어 둔 것 절" "$(printf '%s\n' "$C29" | grep -c '^### 열어 둔 것')" "1"
chk "CHANGELOG 0.29.0: 확인하지 못한 것 절" "$(printf '%s\n' "$C29" | grep -c '^### 확인하지 못한 것')" "1"
chk "CHANGELOG 0.29.0: 실제 QEMU 종단 실행을 주장하지 않는다" "$(printf '%s\n' "$C29" | grep -c '종단 실행에 성공')" "0"
chk "CHANGELOG 0.29.0: 전체 smoke 를 이 항목을 쓸 때 돌리지 않았다고 적는다" "$(printf '%s\n' "$C29" | grep -c '전체 `tests/smoke.sh` 는 이 항목을 쓸 때 돌리지 않았다')" "1"
chk "docs/bootchain-feasibility.md 는 지웠다" "$([ -e "$REPO/docs/bootchain-feasibility.md" ] && echo present || echo absent)" "absent"
NEU_N=$(cat "$REPO/README.md" "$REPO/docs/components.md" "$REPO"/docs/onboarding/*.md | grep -c 'bootchain-feasibility\.md)')
chk "어느 문서도 지운 bootchain-feasibility.md 로 링크하지 않는다" "$NEU_N" "0"
chk "components.md: 지운 verify_byte_match.py 행이 없다" "$(cn_has "$CP" 'verify_byte_match')" "no"
chk "verify_byte_match.py 는 저장소에 없다" "$([ -e "$S/verify_byte_match.py" ] && echo present || echo absent)" "absent"
# 정본: 한 기기의 값을 일반 정의로 적지 않는다
chk "정본 §3: kernel_entry 는 부트로더가 자기 점프 줄을 낸 것 (한 부트로더의 문자열이 아니다)" "$(cn_has "$CM" '**its own kernel-jump line**')/$(cn_has "$CM" 'Starting kernel')" "yes/no"
chk "정본: 한 벤더의 성분 이름(ldfw · tzsw · ACPM)이 없다" "$(grep -c -E 'ldfw|tzsw|ACPM' "$CM")" "0"
chk "README · 온보딩 · start 스킬: kernel_entry 를 한 부트로더의 문자열로 적지 않는다" \
    "$(cat "$RM" "$REPO/docs/onboarding/01-rehosting-overview.md" "$REPO/docs/onboarding/02-unified-chain.md" "$REPO/skills/start/SKILL.md" | grep -c 'Starting kernel')" "0"
chk "정본 §3: param 폴백은 --family exynos 일 때만이고 옛 서술이 없다" "$(cn_flat_has "$CM" '**only with `build_lu.py --family exynos`**')/$(cn_flat_has "$CM" 'writes there but that name is a guess')" "yes/no"
chk "정본 §3: 표면 칸의 내장 배너가 없고 surface_not_credited 가 이유를 말한다" "$(cn_has "$CM" '`surface_not_credited`')" "yes"
chk "정본 §3: 도출된 입력 계획이 없으면 인터럽트 패턴도 없다 (기본 연타 수 없음)" "$(cn_has "$CM" 'no default repeat count')" "yes"
chk "정본 §10: BLOCKED_CARVE 는 false 일 때만, null 은 기록하고 계속" "$(cn_has "$CM" 'only when the carve verdict is `false`')/$(cn_has "$CM" 'carve undetermined')" "yes/yes"
chk "정본 §4: 공유 규칙은 FIXER_RULES 한 곳" "$(cn_has "$CM" 'in one constant `FIXER_RULES`')" "yes"
chk "정본 §4: 일반 fixer 의 변경도 check_change.sh 를 통과해야 센다" "$(cn_has "$CM" 'must also pass `check_change.sh` to count')" "yes"
chk "정본 §4 스크립트 표: build_lu.py 와 carve_disasm.py 가 --family 를 말한다" \
    "$(grep '^| `build_lu.py` |' "$CM" | grep -c -- '--family')/$(grep '^| `carve_disasm.py` |' "$CM" | grep -c -- '--family')" "1/1"
chk "components.md: build_lu.py · carve_disasm.py · uart_harness.py 행이 새 동작을 말한다" \
    "$(grep '^| `build_lu.py` |' "$CP" | grep -c -- '--family')/$(grep '^| `carve_disasm.py` |' "$CP" | grep -c 'is_full: null')/$(grep '^| `uart_harness.py` |' "$CP" | grep -c 'absent')" "1/1/1"
chk "components.md: FIXER_RULES 와 일반 fixer 의 검문" "$(cn_has "$CP" '상수 `FIXER_RULES` 하나에 있고')/$(cn_has "$CP" '`check_change.sh` 를 통과해야 센다')" "yes/yes"
chk "onboarding 02: 옛 '도출 실패 시 기본값을 쓰고' 가 없다" "$(cn_has "$O2" '도출 실패 시 기본값을 쓰고')" "no"
# 일반 fixer 의 범위 (사용자의 결정, 2026-10-06). 담당 fixer 가 모든 정지점에 있지 않아서 쓰는 마지막 수단이라, 하나의 일관된 메커니즘이면
# 여러 곳 · 여러 파일을 한 회차에 고친다. 파이프라인이 그에게만 CHANGE_SCOPE=general 을 주고, 그 범위에서 check_change.sh 는 소스 파일 하나 검사와
# MAX_HUNKS 검사만 건너뛴다. 나머지 검사는 전문가와 같다. 문서가 이 범위를 같은 말로 하고, 옛 "전문가와 같은 검문" 서술이 남지 않으며, 코드가 그대로다.
O4="$REPO/docs/onboarding/04-loop-and-honesty.md"
GS='소스 파일 하나 검사와 `MAX_HUNKS` 검사만 건너뛴다'
chk "정본 §4: fixer-general 행이 한 메커니즘이 여러 곳 · 여러 파일에 걸쳐도 한 회차라고 적는다" "$(cn_has "$CM" 'one coherent mechanism may span several places and files and is handled in one round')" "yes"
chk "정본 §4: 범위는 CHANGE_SCOPE=general 이고 건너뛰는 것은 파일 · hunk 검사 둘뿐이다" "$(cn_flat_has "$CM" "gives \`CHANGE_SCOPE=general\` to \`fixer-general\` only; in that scope \`check_change.sh\` **skips only the single-source-file check and the \`MAX_HUNKS\` check.**")" "yes"
chk "정본 §4: 나머지 검사(변경 없음 · 4항목 · 쓸 수 있는 기록 · 표 행 대응 · hash_engine 행)는 전문가와 똑같이 묶는다" "$(cn_flat_has "$CM" 'All other checks (no change · bypass record 4 fields · usable record · patch-table row correspondence · the `hash_engine` row for a mark `F` hash bypass) bind as for specialists')" "yes"
chk "정본 §4: 한 메커니즘인지는 기계가 세지 못한다고 적는다 (프롬프트로만 집행)" "$(cn_flat_has "$CM" 'A machine cannot count whether the change is really one mechanism')" "yes"
chk "정본 §4 스크립트 표: check_change.sh 행이 전문가의 한계와 CHANGE_SCOPE=general 을 말한다" "$(grep '^| `check_change.sh` |' "$CM" | grep -c 'CHANGE_SCOPE=general')/$(grep '^| `check_change.sh` |' "$CM" | grep -c 'MAX_HUNKS')" "1/1"
chk "정본 §16: 일반 fixer 는 한 메커니즘이면 여러 곳 · 여러 파일에 걸쳐도 변경 1건이고 파일 · hunk 수는 전문가의 한계다" "$(cn_flat_has "$CM" 'The last resort `fixer-general` counts as one change when **one coherent mechanism** spans several places and files')/$(cn_flat_has "$CM" 'File and hunk counts are specialist limits and do not apply to this fixer')" "yes/yes"
chk "정본 §16: 전문가의 변경 1건은 소스 파일 하나 · MAX_HUNKS 이내다" "$(cn_flat_has "$CM" "Specialist fixer's one change: one source file · within \`MAX_HUNKS\` (default 3) hunks")" "yes"
chk "components.md: fixer-general 행 · 문단 · check_change.sh 행이 같은 범위를 말한다" "$(grep '^| `fixer-general` |' "$CP" | grep -c '하나의 일관된 메커니즘')/$(cn_flat_has "$CP" "$GS")/$(grep '^| `check_change.sh` |' "$CP" | grep -c 'CHANGE_SCOPE=general')" "1/yes/1"
chk "onboarding 04: 일반 fixer 의 범위와 검문이 같은 것을 말한다" "$(cn_flat_has "$O4" '그에게만 `CHANGE_SCOPE=general` 을 주고, 그 범위에서 검문은 소스 파일 하나 검사와 `MAX_HUNKS`(기본 3) 검사만 건너뛴다')" "yes"
chk "README: 회차당 변경 1건과 일반 fixer 의 범위" "$(cn_flat_has "$RM" '`CHANGE_SCOPE=general`: 파일 · hunk 검사만 건너뛰고 우회 기록 검사는 전문가와 같다')" "yes"
chk "CHANGELOG 0.29.0: fixer-general 행이 사용자의 결정과 범위를 적는다" "$(printf '%s\n' "$C29" | tr '\n' ' ' | grep -cF -- "$GS")/$(printf '%s\n' "$C29" | grep -c '사용자의 결정, 2026-10-06')" "1/1"
chk "옛 서술(일반 fixer 도 전문가와 같은 검문)이 어느 문서에도 남지 않았다" \
    "$(cat "$CM" "$RM" "$CP" "$O4" | tr '\n' ' ' | tr -s ' ' | grep -o -e '그 변경도 전문가의 것과 같이 `check_change.sh`' -e '그 변경도 전문가와 같이 `check_change.sh`' -e '같은 검문(`check_change.sh`)을 통과해야 센다' -e 'same check (`check_change.sh`) to count' | wc -l | tr -d ' ')" "0"
# 코드: 범위가 건너뛰는 것은 두 검사뿐이고 기록 검사는 범위를 보지 않는다. 파이프라인은 일반 fixer 에게만 범위를 준다
chk "코드: check_change.sh 는 CHANGE_SCOPE=general 에서 파일 수 · hunk 수 검사만 건너뛴다" \
    "$(cn_has "$S/check_change.sh" '[ "$SCOPE" != general ] && [ "$changed_files" -gt 1 ]')/$(cn_has "$S/check_change.sh" '[ "$SCOPE" != general ] && [ "$total_hunks" -gt "$MAX_HUNKS" ]')/$(cn_has "$S/check_change.sh" '[ "$SCOPE" != general ] && [ "$bypass_ok"')/$(cn_has "$S/check_change.sh" '[ "$SCOPE" != general ] && [ "$LEDGER_ISSUES"')" "yes/yes/no/no"
chk "코드: pipeline.js 는 CHANGE_SCOPE=general 을 fixer-general 에게만 준다" "$(cn_has "$REPO/workflows/pipeline.js" "c.fixer === GENERAL_FIXER ? 'CHANGE_SCOPE=general ' : ''")" "yes"
# "동작이 달라지는 곳" 표는 알고 있는 예외의 목록이다. 계열이 주어졌을 때 실행이 하는 일이 같다는 말의 예외를 표가 "전부"라고 적지 않고,
# 검토가 표 밖에서 찾은 두 차이(일반 fixer 의 빌드 실패 판정 · fixer 프롬프트의 구성)를 CHANGELOG 가 적으며, 코드가 그 서술대로다.
chk "CHANGELOG 0.29.0: 표가 예외의 전부라고 적지 않고 알고 있는 예외의 목록이라고 적는다" \
    "$(printf '%s\n' "$C29" | tr '\n' ' ' | grep -c '예외의 전부다')/$(printf '%s\n' "$C29" | tr '\n' ' ' | grep -c '알고 있는 예외의 목록이지 완전하다는 보증이 아니다')" "0/1"
chk "CHANGELOG 0.29.0: 표에 일반 fixer 의 빌드 실패 판정 행이 있고 측정이 권위라고 적는다" \
    "$(printf '%s\n' "$C29" | grep '^| 일반 fixer 의 빌드 실패 판정 |' | grep -c '측정이 권위다')/$(printf '%s\n' "$C29" | grep '^| 일반 fixer 의 빌드 실패 판정 |' | grep -c 'fixer 가 자기 빌드를 실패라고 보고해도 정지하지 않는다')" "1/1"
chk "CHANGELOG 0.29.0: 표에 fixer 프롬프트의 구성 행이 있고 더해진 줄 · 빠진 줄 · 일반 fixer 가 새로 받는 줄을 적는다" \
    "$(printf '%s\n' "$C29" | grep '^| fixer 프롬프트의 구성 |' | grep -c 'Console')/$(printf '%s\n' "$C29" | grep '^| fixer 프롬프트의 구성 |' | grep -c 'Originating exception block')/$(printf '%s\n' "$C29" | grep '^| fixer 프롬프트의 구성 |' | grep -c 'suspect_prior_bypass')" "1/1/1"
chk "CHANGELOG 0.29.0: 확인하지 못한 것이 표가 프롬프트 · 분기의 전수 대조가 아니라고 적는다" \
    "$(printf '%s\n' "$C29" | grep -c '^- \*\*"동작이 달라지는 곳" 은 알고 있는 차이의 목록이다')" "1"
chk "코드: 일반 fixer 의 빌드 실패는 측정이 권위다 (측정이 true 이면 fixer 의 false 로 정지하지 않는다)" \
    "$(cn_has "$REPO/workflows/pipeline.js" "(applied && applied.build_ok === false) || (c.builtOk === false && applied?.build_ok !== true)")" "yes"
# 분류기 · 분석가 프롬프트는 그 줄을 그대로 가진다. 빠진 것은 fixer 가 받는 맥락(fixerContext)뿐이다.
FCTX=$(awk '/^function fixerContext\(/{f=1} f{print} f&&/^}/{exit}' "$REPO/workflows/pipeline.js")
chk "코드: fixer 맥락(fixerContext)은 Console · Summary · Full trace 를 받고 Originating exception block 줄이 없다" \
    "$(printf '%s\n' "$FCTX" | grep -cF 'Console: ${obs?.console}')/$(printf '%s\n' "$FCTX" | grep -cF 'Summary: ${obs?.summary}')/$(printf '%s\n' "$FCTX" | grep -cF 'Full trace: ${obs?.trace}')/$(printf '%s\n' "$FCTX" | grep -cF 'Originating exception block')/$(printf '%s\n' "$FCTX" | grep -c 'suspectPriorBypass')" "1/1/1/0/2"
# 문서가 말하는 새 동작은 코드의 표식과 같다 (코드를 되돌리면 문서가 거짓이 된다)
chk "코드 표식: warning_family · is_full_note · surface_not_credited · FIXER_RULES · settleGeneral" \
    "$(cn_has "$S/build_lu.py" 'warning_family')/$(cn_has "$S/carve_disasm.py" 'is_full_note')/$(cn_has "$S/run_full.sh" 'surface_not_credited')/$(cn_has "$REPO/workflows/pipeline.js" 'const FIXER_RULES')/$(cn_has "$REPO/workflows/pipeline.js" 'async function settleGeneral')" \
    "yes/yes/yes/yes/yes"

# =============================================================================
hdr "canon 9. 한국어 계약 문자열: 정본 표 · 파서 · 에이전트 지시에 번역 없이 남아 있다"

# 영어로 옮긴 파일(정본 · 스킬 · pipeline.js 의 프롬프트)이 늘어도 스크립트가 바이트 그대로 맞추는 한국어는 그대로여야 한다.
# 문자열마다 세 층을 본다: ① 정본 언어 표(CLAUDE.md 의 `Matched by` 표) ② 그것을 읽는 파서 파일 ③ 에이전트에게 쓰라고 하는 지시
# (장부 필드 · 메타 줄 · 빈 기록 표지만: FIXER_RULES 4 항과 agents/fixer-secureboot.md 의 문장 조각).
# 번역하면 어느 한 층이 비고, 실패 메시지가 어느 층(과 어느 파일)이 비었는지 말한다.
CL_OUT=$(cn_lit_scan)
CL_N=$(printf '%s\n' "$CL_OUT" | grep -c .)
CL_ROWS_N=$(printf '%s\n' "$CN_LIT_ROWS" | grep -c .)
chk "계약 문자열: 표의 모든 줄이 검사됐다" "$CL_N" "$CL_ROWS_N"
while IFS=$'\t' read -r lit res; do
    [ -n "$lit" ] || continue
    chk "계약 문자열 [$lit]: 정본 표 / 파서 / 에이전트 지시" "$res" "ok/ok/ok"
done <<< "$CL_OUT"

# 같은 문자열이 주석이 아니라 코드에 있고, 그 문자열을 인용하는 문서가 그대로 인용한다 (파일 | 고정 문자열).
while IFS='|' read -r af_file af_str; do
    [ -n "$af_file" ] || continue
    chk "계약 문자열 코드·인용: $af_file 의 '$af_str'" "$(cn_has "$REPO/$af_file" "$af_str")" "yes"
done <<'ANCHORS'
scripts/check_change.sh|count_field '대상'
scripts/check_change.sh|count_field '이유'
scripts/check_change.sh|count_field '방법'
scripts/check_change.sh|count_field '(알려진[[:space:]]*)?부작용'
scripts/verify_gates.py|("대상", re.compile(
scripts/verify_gates.py|("이유", re.compile(
scripts/verify_gates.py|("방법", re.compile(
scripts/verify_gates.py|(?:알려진\s*)?부작용
scripts/verify_gates.py|_META_RE = re.compile(r"^[\s>\-*+]*\**\s*메타
scripts/verify_gates.py|"종류": ("M"
scripts/verify_gates.py|"표지": ("F"
scripts/verify_gates.py|"출처": ("A"
scripts/verify_gates.py|"도출": ("auto"
scripts/verify_gates.py|(?:기록\s*없음)?
scripts/verify_gates.py|"VERIFIED (출처 검증 통과) · 검증 우회 %d건 · verify_ok: reached_bypassed"
scripts/verify_gates.py|"UNVERIFIED (출처 검증 실패) · 검증 우회 %d건"
scripts/derived_facts.py|SECTION = "도출된 정지점"
scripts/derived_facts.py|("시그니처", "signature", "name")
scripts/static_rotate.py|HEADER_NAMES = ("시그니처", "signature", "name")
skills/start/SKILL.md|VERIFIED (출처 검증 통과) · 검증 우회 N건 · verify_ok: reached_bypassed
skills/start/SKILL.md|F2 (verify_ok 우회 N건)
skills/start/SKILL.md|배너 미관측
skills/start/SKILL.md|(기록 없음)
skills/export/SKILL.md|F2 (verify_ok 우회 N건)
skills/export/SKILL.md|`VERIFIED`(출처 검증 통과)
skills/export/SKILL.md|[대상/이유/방법/부작용]
CLAUDE.md|F2 (verify_ok 우회 N건)
CLAUDE.md|- 메타: 종류=P; 표지=F,L; 출처=A; 도출=semi
ANCHORS

# 0.29.2 항목: 영어로 옮긴 범위 · 한국어로 둔 것 · 토큰 절감이 추정이라는 것 · 미배포 · 못 한 확인을 적는다 (숫자는 적지 않는다: 문장을 고치면 크기가 달라진다)
C292=$(awk '/^## 0\.29\.2 /{f=1;next} /^## /{f=0} f' "$REPO/CHANGELOG.md")
chk "CHANGELOG 0.29.2: 0.29.0 과 0.29.1 은 배포된 적이 없다고 적는다" "$(printf '%s\n' "$C292" | grep -c '0\.29\.0 과 0\.29\.1 은 배포된 적이 없고')" "1"
chk "CHANGELOG 0.29.2: 한국어로 둔 것(status · 출력 · 계약 문자열)과 이유를 적는다" "$(printf '%s\n' "$C292" | grep -c '^- \*\*한국어로 둔 것\*\*')/$(printf '%s\n' "$C292" | grep -c '\*\*계약 문자열\*\*')/$(printf '%s\n' "$C292" | grep -c 'skills/status/SKILL.md')" "1/1/1"
chk "CHANGELOG 0.29.2: 토큰 절감은 추정이고 측정하지 않았다고 적는다" "$(printf '%s\n' "$C292" | grep -c '^### 토큰 절감은 추정이다 (측정하지 않았다)')/$(printf '%s\n' "$C292" | grep -c '토큰 수는 재지 않았다')" "1/1"
chk "CHANGELOG 0.29.2: 스크립트의 동작이 바뀌지 않았다고 적고 에이전트 선택의 효과는 측정하지 않았다고 적는다" "$(printf '%s\n' "$C292" | grep -c '스크립트는 바꾸지 않았고')/$(printf '%s\n' "$C292" | grep -c '그 효과는 측정하지 않았다')" "1/1"
chk "CHANGELOG 0.29.2: 확인하지 못한 것 절 (의미 보존의 독립 대조 · 전체 smoke)" "$(printf '%s\n' "$C292" | grep -c '^### 확인하지 못한 것')/$(printf '%s\n' "$C292" | grep -c '독립 대조')/$(printf '%s\n' "$C292" | grep -c '전체 `tests/smoke.sh` 는 영어 번역 직후에는 돌리지 않았고')" "1/1/1"

# 시험의 시험: 파서의 '부작용' · pipeline.js 의 '배너 미관측' · 정본 표의 '주소 창' 을 번역한 사본을 이 검사가 잡는가.
# 잡는 것은 그 셋뿐이고 다른 줄은 영향받지 않는다 (잡지 못하면 위 검사는 아무것도 지키지 못한다).
mkdir -p "$CN/lit_mut/scripts" "$CN/lit_mut/workflows"
cn_lit_swap() {   # <원본> <사본> <찾을 것> <바꿀 것> [<찾을 것> <바꿀 것> ...]
    python3 -c 'import sys
t=open(sys.argv[1],encoding="utf-8").read()
for i in range(3,len(sys.argv)-1,2):
    assert sys.argv[i] in t, sys.argv[i]
    t=t.replace(sys.argv[i],sys.argv[i+1])
sys.stdout.write(t)' "$@" > "$2.new" && mv "$2.new" "$2"
}
cn_lit_swap "$S/verify_gates.py" "$CN/lit_mut/scripts/verify_gates.py" '부작용' 'side_effect'
cn_lit_swap "$REPO/workflows/pipeline.js" "$CN/lit_mut/workflows/pipeline.js" '배너 미관측' 'banner not observed'
cn_lit_swap "$REPO/CLAUDE.md" "$CN/lit_mut/CLAUDE.md" '`주소 창`' '`address window`'
# 이미 깨진 줄은 세지 않는다: 변조 사본에서 새로 걸린 줄만 본다 (진짜 깨짐은 위 검사가 이름을 대고 알린다)
CL_BASE=$(printf '%s\n' "$CL_OUT" | awk -F'\t' '$2 != "ok/ok/ok" {printf "%s;", $1}')
cn_lit_newflags() {   # CN_OVERLAY 가 가리키는 변조 사본에서 새로 걸린 줄의 표 문자열을 ";" 로 이어 낸다
    cn_lit_scan | awk -F'\t' -v base="$CL_BASE" 'BEGIN{n=split(base,b,";"); for(i=1;i<=n;i++) bad[b[i]]=1} $2 != "ok/ok/ok" && !($1 in bad) {printf "%s;", $1}'
}
CL_FLAG=$(CN_OVERLAY="$CN/lit_mut" cn_lit_newflags)
chk "계약 문자열 검사가 변조(부작용 · 배너 미관측 · 주소 창)를 정확히 그 셋으로 잡는다" "$CL_FLAG" "부작용;주소 창;배너 미관측;"

# 에이전트 층의 시험: FIXER_RULES 4 항의 장부 필드 문장 · 빈 기록 표지 문장(pipeline.js)과 메타 줄 예(agents/fixer-secureboot.md)를
# 영어로 바꾼 사본. 이 낱말들은 pipeline.js 에 흔해 낱말 하나만 찾으면 통과하므로, 문장 조각에 고정했는지를 본다.
# 파일마다 한 군데씩만 바꾸므로 pipeline.js 의 조각 둘과 fixer-secureboot.md 의 조각 하나가 각각 따로 요구되는지도 드러난다.
mkdir -p "$CN/lit_mut_ag/workflows" "$CN/lit_mut_ag/agents"
cn_lit_swap "$REPO/workflows/pipeline.js" "$CN/lit_mut_ag/workflows/pipeline.js" '`대상 / 이유 / 방법 / 부작용`' '`target / reason / method / side effect`' 'never `(기록 없음)`' 'never `(no record)`'
cn_lit_swap "$REPO/agents/fixer-secureboot.md" "$CN/lit_mut_ag/agents/fixer-secureboot.md" '- 메타: 종류=P; 표지=F; 출처=A; 도출=semi' '- meta: kind=P; mark=F; source=A; derivation=semi'
CL_FLAG=$(CN_OVERLAY="$CN/lit_mut_ag" cn_lit_newflags)
chk "계약 문자열 검사가 에이전트 층의 번역(장부 필드 · 메타 줄 · 빈 기록 표지)을 흔한 낱말까지 정확히 잡는다" "$CL_FLAG" "대상;이유;방법;부작용;메타;종류;표지;출처;도출;(기록 없음);"

# 사람이 읽는 스킬은 한국어로 둔다: status 는 일부러 영어로 옮기지 않았다 (한글이 비공백 글자의 20% 를 넘고 0 이 아니다)
ST_H=$(python3 -c 'import re,sys;t=re.sub(r"\s","",open(sys.argv[1],encoding="utf-8").read());h=len(re.findall(r"[가-힣]",t));print("%d/%d" % (h, int(1000*h/max(len(t),1))))' "$REPO/skills/status/SKILL.md")
chk "status 스킬은 한국어로 남아 있다 (한글 글자 수 > 0, 비공백 글자의 20% 초과)" "$(awk -F/ '$1>0 && $2>200 {print "yes"; exit} {print "no"}' <<< "$ST_H")" "yes"
# 영어로 쓴 지시가 에이전트의 출력까지 영어로 바꾸지 않게 하는 한 문장이 사용자에게 말하는 파일마다 있다
LANG_N=0
for f in CLAUDE.md skills/start/SKILL.md skills/init/SKILL.md skills/export/SKILL.md workflows/pipeline.js; do
    [ "$(cn_has "$REPO/$f" 'All text addressed to the user (progress, reports, questions, summaries, documents)')" = yes ] && LANG_N=$((LANG_N+1))
done
chk "한국어 출력 문장이 정본 · 스킬 셋 · pipeline.js 에 모두 있다" "$LANG_N" "5"

    rm -rf "$CN"
}
cn_main
parts_finish
