#!/usr/bin/env bash
# tests/parts/pipeline_family.sh - workflows/pipeline.js: 계열 자료, BLOCKED_ARCH 의미, 목표 사다리,
# 관측 채널, 검증 호출과 음성 시험, Build 준비(트리 복원·코어 패치·매체 판정), 회차 번호,
# kernel_alive 의 배너 근거(UART 는 "미검증"), 정지 시 검증 우회 건수, 커널 로그 경로, 콘솔 필터(NUL·비 UTF-8),
# 음성 콘솔과 실제 verify.py 의 접합, 토큰 파일의 칸 이름 대조, 계열 자료·템플릿 경로가 절대 경로이고
# 실제로 열리는가(P1), 아키텍처 도출과 BLOCKED_ARCH(P2), 커널 자산 적재(P3), 재개 시 회차 번호(P4),
# 관측 문서의 kernel_log·host_log(P5), 커널 태스크 정규식 파일(P6), 담당 열의 build(P7),
# BLOCKED_KO(P8), 머신 빌드 프롬프트의 선독(P9), 그리고 다른 담당이 넘긴 것: 뒤 이미지마다 detect-arch(H1),
# extract_boot_assets.sh 종료코드(H2), 분석가 프롬프트의 hash_engine 행·cmdline partition·memdump 계획(H3),
# 주소 창 표(H5), verify 의 hash_engine · address_windows(H7), 에스컬레이션의 hash_engine(H8).
# 그리고 중립화 회차(scenarios_neutral.js): 스크립트에 넘기는 --family 와 carve 판정 불가(V1), 저장소 골격의 제시 조건(V2),
# 마지막 수단 fixer 의 변경도 check_change.sh 를 거친다(V3, 실제 검문 실행 V3x), fixer 가 답하는 필드와 남기는 질문(V4),
# 모든 fixer 프롬프트의 공통 맥락(V5), 여섯 전문가와 마지막 수단 fixer 의 프롬프트가 모두 같은 규칙 본문 FIXER_RULES 로 끝난다(V6).
#
# pipeline.js 는 에이전트를 부르는 스크립트라 실제로는 돌릴 수 없다. 여기서는 node 로 같은 소스를
# 그대로 컴파일하고 `agent` 만 대본으로 바꿔 끝까지 돌린다 (플러그인 저장소에 이런 하니스가 없어
# 이 파일이 만든다). 확인하는 것은 세 층이다.
#   1. 정적: 문법, smoke.sh 가 고정한 문자열, 위임 지점 수(위임 프롬프트마다 계열 자료 줄이 있는가),
#      소스에 기기 값(주소)이 없는가.
#   2. 시뮬레이션: 에이전트 대본으로 파이프라인 전체를 돌려 프롬프트·정지·판정·보고를 확인한다.
#   3. 실행: 파이프라인이 낸 셸 명령 자체를 가짜 플러그인 폴더(진짜 py.sh)와 임시 워크스페이스에서
#      실제로 실행한다 (음성 시험, verify 인자, 표지 파일, 매체 판정, 메모리 덤프 영역 도출).
# 그리고 변조: pipeline.js 의 약속 하나씩을 일부러 깨뜨린 사본에 같은 시험을 돌려, 시험이 그것을
# 잡는지 본다 (잡지 못하면 시험이 아무것도 지키지 않는 것이다).
#
# 실제 펌웨어·QEMU 는 쓰지 않는다. 실제 프로필(family_kit.py)과 memdump_observe.py 만 읽는다.
# 하니스와 시나리오는 tests/pipeline_sim/ 에 있다 (harness.js 가 에이전트 대본, common.js 가 공용 준비와 변조 목록,
# scenarios_flow.js · scenarios_guide.js · scenarios_neutral.js 가 시나리오). 이 파일은 그것을 한 번, 그리고 변조마다 한 번씩
# 돌려 세고 읽는다. 중립화 회차의 변조(NEUTRAL_MUTS)는 그 약속을 지키는 scenarios_neutral.js 에만 돌린다 (앞의 두 파일은
# 그 약속과 무관해 변조마다 다시 돌릴 이유가 없고, 몇 분이 더 걸린다).
# 사용: bash tests/parts/pipeline_family.sh        (node 필요)
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# smoke.sh 가 이 파일을 source 하므로 변수는 지역으로 둔다 (다른 절의 변수를 덮지 않는다)
pf_main() {
    local PF PJ SIM sc f N_PASS N_FAIL line what detail rest m out n_total MUTS NEUTRAL_MUTS running
    PJ="$REPO/workflows/pipeline.js"
    PF="$ROOT/pipeline_family"; rm -rf "$PF"; mkdir -p "$PF"
    export PYTHONDONTWRITEBYTECODE=1        # 시험이 저장소 안에 .pyc 를 남기지 않게

    hdr "pipeline 1. 문법과 파일"
    if ! command -v node >/dev/null 2>&1; then
        ok "SKIP node 가 없어 파이프라인 시뮬레이션을 건너뜁니다 (이 플러그인의 워크플로 런타임이 node 계열이라 보통은 있습니다)"
        rm -rf "$PF"; return 0
    fi
    [ -f "$PJ" ] && ok "workflows/pipeline.js 가 있다" || { bad "workflows/pipeline.js 가 없다"; rm -rf "$PF"; return 0; }

    # --- 하니스와 시나리오: tests/pipeline_sim/ (저장소 파일). 시험은 임시 폴더에만 쓴다 ---
    SIM="$REPO/tests/pipeline_sim"
    for f in harness.js common.js fixer_rules.js scenarios_flow.js scenarios_guide.js scenarios_neutral.js; do
        [ -f "$SIM/$f" ] || { bad "tests/pipeline_sim/$f 가 없다"; rm -rf "$PF"; return 0; }
    done

    # smoke.sh 는 pipeline.js 의 문법을 검사하지 않는다. 최상위 await·return 이 있는 스크립트라
    # `node --check` 가 맞지 않으므로, 워크플로 런타임이 하듯 비동기 함수 본문으로 컴파일해 본다.
    out=$(node -e '
const fs = require("fs")
const src = fs.readFileSync(process.argv[1], "utf8").replace(/^export const meta/m, "const meta")
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
try { new AsyncFunction("args", "log", "agent", "phase", "budget", src); console.log("ok") }
catch (e) { console.log("SYNTAX " + e.message) }' "$PJ" 2>&1)
    chk "pipeline.js 가 컴파일된다" "$out" "ok"

    hdr "pipeline 2. 시뮬레이션과 실행 (에이전트 대본, 파이프라인이 낸 명령의 실제 실행)"
    : > "$PF/out.txt"; : > "$PF/err.txt"
    for sc in scenarios_flow scenarios_guide scenarios_neutral; do
        SBOOT_TEST_TMP="$PF" node "$SIM/$sc.js" "$REPO" >> "$PF/out.txt" 2>> "$PF/err.txt"
    done
    [ -s "$PF/err.txt" ] && bad "시나리오 실행기가 stderr 를 냈다" "$(head -c 400 "$PF/err.txt")"
    N_PASS=0; N_FAIL=0
    while IFS= read -r line; do
        case "$line" in
            "PASS "*) ok "${line#PASS }"; N_PASS=$((N_PASS+1)) ;;
            "FAIL "*) what="${line#FAIL }"; detail=""; case "$what" in *" :: "*) detail="${what#* :: }" ;; esac
                      bad "${what%% :: *}" "$detail"; N_FAIL=$((N_FAIL+1)) ;;
            *) [ -n "$line" ] && printf '        %s\n' "$line" ;;
        esac
    done < "$PF/out.txt"
    n_total=$((N_PASS+N_FAIL))
    [ "$n_total" -ge 150 ] && ok "시나리오 검사 $n_total 건이 실제로 돌았다 (대본이 비어 있지 않다)" \
                           || bad "시나리오 검사가 너무 적다 ($n_total 건)" "실행기가 중간에 멈췄을 수 있다: $(head -c 300 "$PF/err.txt")"

    hdr "pipeline 3. 변조 — 약속 하나를 깨뜨린 사본을 시험이 잡는가"
    MUTS="classifier-without-family-kit abort-round-counted-twice reached-goals-overreports
          surface-none-is-a-static-blocker arm32-alone-blocks negative-console-saved-as-a-round
          script-bypass-count-ignored unprovable-tree-is-built-on host-lines-read-as-bootloader
          kernel-metrics-always-recorded negative-test-before-a-passing-stage-1 verify-trace-not-passed
          uart-alive-reads-as-banner-observed stop-reports-no-verification-bypass round-cap-reports-no-verification-bypass
          stop-journal-counts-the-advanced-index kernel-log-path-not-given
          guest-filter-reads-console-as-text negative-console-keeps-kernel-timestamps
          token-names-never-checked
          family-lines-relative detected-arch-ignored unknown-arch-never-blocks explicit-arch-derived-anyway
          kernel-assets-never-staged staging-exit-4-reads-as-failure provisional-arch-kept-silently round-restarts-at-one
          round-cap-counts-the-absolute-number round-base-ignores-the-logs round-base-counts-the-negative-range
          null-kernel-log-becomes-a-path kernel-task-regex-by-environment owner-column-excludes-build
          ko-without-an-emitter build-prompt-not-told-to-read run-schema-lacks-the-log-fields
          plugin-root-trailing-slash-kept registry-and-templates-relative blocked-asset-hides-the-staging
          later-images-share-one-arch asset-exit-codes-unexplained sparse-super-reads-as-ready
          memdump-plan-demands-the-ring hash-engine-evidence-unspecified cmdline-plan-without-partition
          address-windows-never-requested hash-engine-silent-in-verify hash-engine-unbacked-not-reported
          address-windows-silent-in-verify verifier-not-told-the-hash-row escalation-never-asks-for-the-digest-row
          analyst-not-asked-for-the-storage-driver task-regex-said-to-be-anchored
          derived-arch-basis-not-asked-for-in-static
          arch-probe-never-run arm64-exit-zero-is-a-signature probe-stub-count-never-read
          probe-failure-reads-as-no-signature both-signatures-pick-a-reading probe-always-answers-arm64
          blocker-text-capped-at-400 arch-decision-text-capped-at-400 provisional-journal-hides-the-probe
          absent-without-evidence-stops ko-search-not-medium-aware later-image-trusts-the-arm64-exit-code"
    # 중립화 회차: 스크립트에 --family 를 넘긴다(build-lu-without-family · carve-without-family), 알려진 계열만 그대로 넘긴다,
    # carve 판정 null 은 멈추지 않고 기록된다, 저장소 골격은 매체·계열로 제시된다, 마지막 수단 fixer 의 변경도 검문·되돌림·
    # 재빌드·기록을 거친다(general-fixer-bypasses-the-gate · rejected-change-*), 빌드 판정은 측정이 이긴다, fixer 가 답하는
    # 필드는 파이프라인이 읽는 것뿐이고 열린 질문은 rationale 로 다음 에스컬레이션의 초점이 된다, 두 fixer 프롬프트는 같은 맥락을 쓴다,
    # 모든 fixer 프롬프트가 규칙 본문 FIXER_RULES 를 한 번씩 싣고(fixer-rules-missing-* · fixer-rules-twice-*), 그 본문은 규칙을 약화하거나
    # 번호로 인용하지 않는다(fixer-rules-open-question-gone 이하). 검증 프롬프트는 읽히지 않는 --pc 를 권하지 않는다(verifier-prompt-offers-dead-pc-option)
    NEUTRAL_MUTS="build-lu-without-family carve-without-family family-flag-passes-any-family carve-null-blocks
          carve-undetermined-silent carve-note-not-in-schema param-fallback-told-to-every-family interrupt-default-promised
          storage-template-for-every-undecided-medium storage-template-for-emmc storage-template-ufs-needs-exynos
          general-fixer-bypasses-the-gate general-fixer-gets-the-specialist-limits specialist-gets-the-general-scope rejected-change-not-rolled-back rejected-change-recorded-as-applied
          general-build-claim-ignored general-build-claim-beats-measurement general-abort-decline-continues
          general-context-forked specialist-context-forked fixer-schema-keeps-escalate general-schema-keeps-bypass-doc
          fixer-rules-missing-for-specialists fixer-rules-missing-for-general fixer-rules-twice-in-the-specialist-prompt
          fixer-rules-open-question-gone fixer-rules-ledger-rule-weakened fixer-rules-family-paragraph-gone
          fixer-rules-allow-adaptive-toggles fixer-rules-cite-honesty-by-number fixer-rules-machine-may-speak
          verifier-prompt-offers-dead-pc-option
          declined-questions-dropped
          declined-questions-never-cleared declined-questions-kept-forever escalation-focus-ignores-its-own
          escalation-never-takes-the-questions"
    # 변조 사본마다 시나리오 전체를 돌리므로(수 초) 몇 개씩 묶어 병렬로 돌린다. 각 실행은 자기 임시
    # 폴더만 쓰고, 결과는 순서대로 읽는다.
    running=0
    for m in $MUTS; do
        ( for sc in scenarios_flow scenarios_guide; do
              SBOOT_MUTATE="$m" SBOOT_TEST_TMP="$PF" node "$SIM/$sc.js" "$REPO" 2>/dev/null
          done > "$PF/mut_$m.out" ) &
        running=$((running+1)); [ $((running % 6)) -eq 0 ] && wait
    done
    wait
    for m in $NEUTRAL_MUTS; do
        ( SBOOT_MUTATE="$m" SBOOT_TEST_TMP="$PF" node "$SIM/scenarios_neutral.js" "$REPO" 2>/dev/null > "$PF/mut_$m.out" ) &
        running=$((running+1)); [ $((running % 6)) -eq 0 ] && wait
    done
    wait
    for m in $MUTS $NEUTRAL_MUTS; do
        out=$(cat "$PF/mut_$m.out" 2>/dev/null)
        if printf '%s\n' "$out" | grep -q 'mutation did not apply'; then
            bad "변조 $m 가 적용되지 않았다" "pipeline.js 의 해당 코드가 옮겨졌다 — 시험의 변조 정의를 고치세요"
        elif printf '%s\n' "$out" | grep -q '^FAIL'; then
            ok "변조 $m 를 시험이 잡는다 ($(printf '%s\n' "$out" | grep -c '^FAIL') 건 실패)"
        else
            bad "변조 $m 를 시험이 잡지 못한다" "이 약속은 지금 아무 시험도 지키지 않는다"
        fi
    done

    rm -rf "$PF"
}
pf_main
parts_finish
