# 변경 이력

이 플러그인은 `.claude-plugin/plugin.json` 의 `version` 을 올렸을 때만 사용자에게
업데이트가 전달된다. 각 버전에 무엇이 들어갔는지 여기에 기록한다.

---

## 0.29.2 — 2026-10-08

**LLM 이 읽는 글(정본 · 스킬 · 파이프라인의 에이전트 지시)을 짧은 영어로 옮겼다.** 같은 내용이 영어로는 토큰이 덜 든다는 판단이다. 사람이 읽는 출력은 그대로 한국어다.

**0.29.0 과 0.29.1 은 배포된 적이 없고** (`origin/main` 은 0.27.0 이었다) **0.29.2 가 이 변경을 처음 내보내는 버전이다.** 버전을 올린 것은 `CLAUDE.md` · `skills/` · `workflows/` 가 릴리스 표면(`scripts/check_release.sh`)이라 문서만 고쳐도 상승이 필요하기 때문이다.

### 무엇이 바뀌었나

- **영어로 옮긴 것**: `CLAUDE.md`, 스킬 `start` · `init` · `export` 의 본문, `workflows/pipeline.js` 안에서 에이전트에게 주는 한국어 지시(`DOC_STYLE`, 지문 줄 끝의 `최초 예외 블록:` 라벨은 `Origin exception block:` 으로, 도출 행의 `[담당 …] 시도:` 라벨은 `[owner …] try:` 로, 그 밖의 문구 몇 곳. 모두 27줄). 직역이 아니라 짧게 다시 썼다. 규칙 · 수치 · 명령 · 표 행 · 정직성 규칙의 이유 한 줄은 줄이지 않았다. 번호와 제목 구조(§ 번호, Step 번호)는 그대로다.
- **한국어로 둔 것**:
  - `skills/status/SKILL.md` — 일부러 둔다. 시험이 한글이 비공백 글자의 20% 를 넘는지 본다.
  - 사용자에게 보이는 모든 출력 — 진행 · 보고 · 질문 · 에이전트가 쓰는 문서 · 보고 서식 · 기록 문구. 옮긴 파일마다 "사용자에게 하는 말과 쓰는 문서는 한국어" 한 문장을 넣었다.
  - `README.md` · `CHANGELOG.md`.
  - **계약 문자열** — 스크립트 · verifier · 시험이 바이트 그대로 맞춘다. 장부 필드(`대상` · `이유` · `방법` · `부작용` · `알려진 부작용` · `메타`), 메타 키(`종류` · `표지` · `출처` · `도출` · `근거`), `(기록 없음)`, `## 도출된 정지점` · `시그니처`, `미확정`, `주소 창`, 판정 문구(`VERIFIED (출처 검증 통과)` · `검증 우회 N건` · `verify_ok: reached_bypassed`), 등급 표기 `F2 (verify_ok 우회 N건)`, `배너 미관측`. 목록은 `CLAUDE.md` 맨 앞 "Language" 절의 표가 정본이다.
- **스크립트는 바꾸지 않았고 `workflows/pipeline.js` 의 코드와 분기도 그대로다.** `agents/` 는 이미 대부분 영어였고, 이번에 옮긴 것은 `agents/fixer-secureboot.md` 의 판정 표(`상황 | 판정`)와 조사 순서의 굵은 머리말뿐이다. 남은 한국어는 계약 문자열 · 출력 예다. 바뀐 것은 에이전트가 읽는 문구(정본 · 스킬 · 프롬프트 · 그 에이전트 파일의 두 곳)뿐이라, 같은 입력에서 에이전트의 선택이 달라질 수 있다. 그 효과는 측정하지 않았다.
- **문서 정리**: 초기 설계 노트와 설계 초안(`_design/`)을 [설계 근거](docs/design-rationale.md)와 [백로그](docs/backlog.md)로 합치고 원본(`docs/agent-architecture-rationale.md` · `docs/improvement-proposals.md` · `_design/`)은 지웠다 (0.29.1 의 D4 는 이것으로 닫힌다). 설계 근거 3.2 의 흐름은 시퀀스 다이어그램 4장(준비 · 회차 루프 · 정지점 처리 · 검증과 포장)으로 나눴고, README · components · onboarding 의 그림은 Mermaid 로 바꿨다. onboarding 02 의 정지 코드 표와 onboarding README 의 명령 블록은 README 로 연결되는 링크로 바꿨다.
- `fixers/registry.yaml` 의 주석 두 곳: `fixer-general` 이 마지막 수단으로 있다는 사실과 어긋나던 설명을 고쳤다 (영어 주석이고 코드 동작은 없다).

### 토큰 절감은 추정이다 (측정하지 않았다)

| 파일 | 이전 (바이트) | 이후 (바이트) | 비율 |
|---|---|---|---|
| `CLAUDE.md` | 62,413 | 55,204 | 88% |
| `skills/start/SKILL.md` | 24,728 | 20,888 | 84% |
| `skills/init/SKILL.md` | 19,859 | 16,404 | 83% |
| `skills/export/SKILL.md` | 13,499 | 11,824 | 88% |
| 위 네 파일 합계 | 120,499 | 104,320 | 87% |
| `workflows/pipeline.js` | 272,261 | 271,852 | 99.8% (프롬프트는 대부분 이미 영어였다) |

- 한국어는 글자당 3바이트이고 영어는 1바이트 안팎이라 **바이트 비율은 토큰 비율이 아니다.** 토큰 수는 재지 않았다. 절감 폭은 추정이다.
- 산문을 한국어의 60% 쯤으로 줄이는 것이 목표였으나 도달하지 못했다. 규칙 · 수치 · 명령 · 표를 줄이지 않았기 때문이다.

### 시험

- `canon` 에 "한국어 계약 문자열" 묶음(canon 9)을 더했다. 위 계약 문자열마다 정본 표 · 파서 · (장부 필드 · 메타 줄 · 빈 기록 표지는) 에이전트 지시에 그대로 남았는지 보고, 파서의 `부작용` · `pipeline.js` 의 `배너 미관측` · 정본 표의 `주소 창` 을 영어로 바꾼 사본을 그 검사가 정확히 그 셋으로 잡는지 본다. 에이전트 지시 층은 `대상` · `메타` 같은 흔한 낱말 하나가 아니라 `FIXER_RULES` 4 항과 `agents/fixer-secureboot.md` 의 문장 조각(`` `대상 / 이유 / 방법 / 부작용` `` · `` `- 메타: 종류=…; 표지=…; 출처=…; 도출=…` `` · `` never `(기록 없음)` `` 등)에 고정했고, 그 조각을 영어로 바꾼 사본을 장부 필드 · 메타 키 · `(기록 없음)` 전부 잡는지도 본다. 그 밖에 status 스킬이 한국어로 남았는지, 한국어 출력 문장이 정본 · 스킬 셋 · `pipeline.js` 에 모두 있는지를 본다.
- 영어로 바뀐 문장을 고정하던 시험(`canon` · `init_clean` · `smoke` · `pipeline_sim/scenarios_neutral.js`)의 조각은 같은 규칙을 말하는 영어 조각으로 옮겼다. 규칙이 번역에서 빠진 곳은 시험을 고치지 않고 번역의 결함으로 올린다는 방침이었고, 이 항목을 쓸 때 그런 곳은 없었다.

### 커버리지

영역별 시험 `tests/parts/*.sh` 를 파일별로 단독 실행한 값 (2026-10-07, 번역 직후):
`family_kit` 162 · `init_clean` 184 · `integration` 115 · `machine_tmpl` 152 · `medium` 167 ·
`observe` 205 · `pipeline_family` 696 · `stage_map_arm32` 250 · `verify_gates` 269 · `canon` 473
(합계 2,673, 실패 0). 이 항목에서 개수가 늘어난 것은 `canon` 뿐이다 (번역 직후 412 → 473: 계약 문자열 묶음 · 에이전트 층 시험 · 0.29.2 항목 시험을 더했다). 전부 가짜 QEMU 와 합성 입력으로 돈 것이다.

### 확인하지 못한 것

- **의미 보존**: 번역한 담당의 자기 점검과 시험이 고정한 문장이 근거다. 원문과 줄 단위로 독립 대조하지는 않았다.
- 전체 `tests/smoke.sh` 는 영어 번역 직후에는 돌리지 않았고(영역별 시험만 단독으로 돌렸다), 문서 정리와 문구 보정까지 끝낸 뒤 한 번 돌려 2,885 통과 / 0 실패였다. 가짜 QEMU 와 합성 입력으로 돈 것이다.
- **열린 결정 (코드와 문서가 어긋남)**: `CLAUDE.md` §4 · `agents/fixer-general.md` · `fixers/registry.yaml`(`reached_by: decline_only`)은 `fixer-general` 이 전문가가 전부 반려한 뒤에만 도달한다고 적는데, `workflows/pipeline.js` 는 그 밖에 두 길을 더 연다. supervisor 가 담당 fixer 가 없다고 판단하면 분류를 건너뛰고 바로 보내고(`route === GENERAL_FIXER`), QEMU 가 콘솔 출력 뒤에 비정상 종료하면(`qemu_abort`) 곧장 보낸다. 문서를 코드에 맞출지 코드를 문서에 맞출지 정하지 않았다.
- 영어 지시로 실제 LLM · QEMU · 워크플로 런타임을 돌린 적이 없다 (0.29.1 의 알려진 한계와 같다).
- 검증자 프롬프트에 들어가는 `hash_engine` 행 서술 한 줄은 `[검증]` 로그 줄과 같은 문자열이라 시험이 한국어로 고정하고 있어 옮기지 않았다 (`hashEngineText`). 그 줄은 한국어로 남은 에이전트 입력이다.

---

## 0.29.1 — 2026-10-06

**0.29.0 이전에 쓴 MediaTek 설계 문서 12개를 지운다.** 구현이 끝난 지금 설계 문서는 더
필요 없고, 내용은 git 이력(1d47260 이후)에 남는다.

### 무엇이 바뀌었나

- `docs/mediatek/` 의 설계 문서 12개(README · boot-medium · bypass-policy · family ·
  goals-observation · init-clean · machine · roadmap · runbook · stage-map · status ·
  verification)를 지웠다.
- `README.md` 의 "현재 상태" 를 줄였다: 쉽게 낡는 영역별 시험 수와 합계를 뺐고(측정한 개수는
  이 변경 이력이 정본이다), 정직한 한계(실제 QEMU · LLM · 워크플로 런타임 미실행, 템플릿은
  컴파일만, MediaTek 근거는 한 기기 수작업 키트뿐, 하드웨어 해시 예외는 잠정)는 그대로 둔다.
  문서 표의 설계 문서 링크도 뺐다.
- `CLAUDE.md` 와 `knowledge/runbook_mediatek.md` 가 삭제한 문서를 가리키던 포인터를 자립형으로
  바꿨다. `examples/a136u-mt6833/` 의 머리말 포인터도 같다.
- **어느 스크립트나 에이전트 프롬프트의 동작도 바뀌지 않았다.** 지운 것은 설계 문서와 그 문서를
  가리키던 포인터, 그리고 그 문서를 고정하던 `canon` · `family_kit` · `machine_tmpl` 시험뿐이다.

**0.29.0 은 배포되지 않았고**(`origin/main` 은 0.27.0 이다) **0.29.1 도 배포 전이다.** 버전을
올린 것은 `CLAUDE.md` 와 `knowledge/` 가 릴리스 표면(`scripts/check_release.sh`)이라 문서만
고쳐도 상승이 필요하기 때문이고, 동작이 바뀌어서가 아니다.

### 열려 있는 항목 · 열린 결정

삭제한 설계 문서의 `status.md` §10-3 · §11 과 `roadmap.md` §4 에 있던 것 중 아직 열려 있는
것이다. 0.29.0 항목의 "열어 둔 것" 에 더해:

- **Q3 (사용자 미답)**: 하드웨어 해시 엔진 펌웨어의 검증 우회 예외는 정본 §11 에 **잠정**으로
  들어갔다. 사용자가 답해야 확정되거나 지워진다. (c) 엄격 모드는 미구현(D3).
- **Q12 (사용자 미답)**: `init` 의 "시작 폴더" 를 세션을 연 폴더(`<cwd>/rehost_workspaces`)로
  이해한 것이 맞는지.
- **Q13 (사용자 미답)**: 수작업 키트의 머신 소스를 `examples/a136u-mt6833/` 참조 예제로 넣은
  것 (소스와 우회 장부만 있고 펌웨어는 없다. `.gitignore` 예외와 함께 커밋했다).
- 그 밖의 열린 결정: Q4(게이트 2 미발견 형태별 상한 — 지금은 보고만), Q8(키트 `08_docs` 자료
  입수), Q9(PR #3 작성자 피드백 — 남기지 않았다), D4(`docs/agent-architecture-rationale.md` ·
  `docs/improvement-proposals.md` 추적 여부).
- **D7**: 링 용량(`console_size`)이 없는 메모리 덤프 영역의 두 경로가 어긋난다. 실제 기기에서 정한다.
- **C16 ②**: 에스컬레이션 프롬프트와 `agents/static-analyzer.md` 14d 가 `hash_engine` 행을
  `## 도출된 정지점` 절 위의 자기 절에 쓰라고 지정하지 않는다 (①·③ 은 닫힘).
- 일부러 둔 리뷰 지적: eMMC 컨트롤러 골격 없음(C9), 게이트 2 를 전체 참조 집합에 돌려 시간
  예산 안에 끝나는지 미측정(C10), `derived_facts.py` 가 `hash_engine` 행을 새 사실로 세지
  않음(C12), 파이프라인이 분석가의 `has_super` 를 되읽지 않음(A20), `generic.yaml` 의 남은
  Exynos 힌트와 지식표의 한 기기 문자열(L6 · L7), `surface_not_credited` 를 `observation.json`
  으로 옮기지 않음(L12).
- **알려진 한계**: 실제 QEMU · 실제 LLM · 실제 워크플로 런타임으로 돌린 적이 없다. 머신 템플릿은
  QEMU 헤더에 대해 컴파일만 했다. MediaTek 진행 가이드(`knowledge/runbook_mediatek.md`)를
  에이전트 루프가 실제 펌웨어에서 끝까지 따라 돈 적이 없다. 근거는 SM-A136U 한 대의 수작업 키트뿐이다.

---

## 0.29.0 — 2026-10-06

**0.28.0 에 담긴 MediaTek 계열 작업을 처음 배포하고, 그 위에서 한 기기의 값이 계열 중립 경로에 기본값으로 박힌 곳을 걷어 낸다.**

**0.28.0 은 배포되지 않았다** (`origin/main` 은 0.27.0 이다). 사용자의 결정으로 버전을 0.29.0 으로 올렸다. 아래 0.28.0 항목은 그 개정이 담은 내용의 이력으로 그대로 두고, 0.29.0 은 그 항목의 모든 변경과 이 항목의 변경을 함께 담는다. 그래서 MediaTek 계열 작업을 처음 받는 버전이 0.29.0 이다.

### 무슨 일이 있었나

0.28.0 의 2차 작업 뒤 감사가 두 가지를 짚었다. 한 기기의 값(파티션 이름, 부트로더 배너, 기본 입력 패턴, 한 벤더의 성분 이름)이 계열 중립 경로에 기본값이나 판정 입력으로 남아 있었다는 것, 그리고 폐기된 `--track` 흐름의 코드와 문서가 남아 있었다는 것이다. 플러그인은 순서 · 근거 · 측정을 주는 가이드이고 값은 대상 펌웨어에서 도출한다 (정본 §7 규칙 3 · 4). 이 개정은 그 원칙에서 벗어난 곳을 걷어 낸다. **계열이 주어졌을 때 Exynos 와 MediaTek 실행이 하는 일을 바꾸지 않는 것이 목표였고**, 알고 있는 예외를 아래 "동작이 달라지는 곳"에 적었다. **그 표는 알고 있는 예외의 목록이지 완전하다는 보증이 아니다:** `workflows/pipeline.js` 의 프롬프트와 분기를 이전 판과 줄 단위로 전수 대조하지는 않았다 ("확인하지 못한 것" 참조).

### 동작이 달라지는 곳

| 곳 | 이전 | 지금 |
|---|---|---|
| `build_lu.py` | 계열을 몰랐다. 기본 레이아웃에 Exynos 이름(`keystorage` · `param` · `up_param`)과 "`param` 파티션에 쓴다" 폴백이 있었다 | `--family` 를 받는다. `exynos` 일 때만 그 이름과 폴백이 있다. 다른 계열은 이름 없는 중립 레이아웃이고, 계획 · 매니페스트가 이름 붙인 파티션에만 쓰며 아니면 `warning_cmdline`. 생략하면 예전 동작과 `warning_family`. 파이프라인은 항상 넘긴다 |
| `carve_disasm.py` | 아키텍처가 문자열 · 크기 기준을 골랐다 (arm64 면 S-Boot 식 묶음) | `--family` 가 고른다. 기준이 없는 계열이고 컨테이너 헤더 근거도 없으면 `is_full: null` (판정 불가, 거짓이 아니다). 파이프라인은 `false` 일 때만 `BLOCKED_CARVE`, `null` 은 "carve undetermined" 로 기록하고 계속한다. 생략하면 예전 동작 |
| `run_full.sh` 표면 칸 | `milestone_tokens.txt` 가 없으면 한 부트로더의 배너로 shell 표면을 도달로 셌다 | 내장 배너가 없다. 도달로 세지 않고 `fingerprint.json` 에 `surface_not_credited: "no derived token file"` 을 남긴다. **계열과 무관하게 달라진다** |
| `uart_harness.py` | `input_plan.json` 이 없으면 CR 세 번이 기본 패턴이었다 | 인터럽트 패턴을 보내지 않고 `source: "absent"`. `bytes` 와 `count` 가 둘 다 있어야 쓸 수 있는 계획이다. **계열과 무관하게 달라진다** |
| 스토리지 골격 | 매체 종류와 상관없이 에이전트에 제시했다 | UFS 이거나, 미정이면서 계열이 exynos 일 때만 제시한다. 템플릿은 Exynos UFS 골격이라고 밝히고 값은 자리표시자다 |
| `fixer-general` 의 변경 | `check_change.sh` 를 거치지 않고 셌다 | 전문가와 같은 적용 단계(검문, 위반이면 복원, 동기화, 빌드, 기록)를 거친다. `qemu_abort` 경로의 일반 fixer 도 같다. **범위는 전문가와 다르다 (사용자의 결정, 2026-10-06):** 파이프라인이 `fixer-general` 에게만 `CHANGE_SCOPE=general` 을 주고, 그 범위에서 `check_change.sh` 는 **소스 파일 하나 검사와 `MAX_HUNKS` 검사만 건너뛴다.** 변경 없음 · 우회 기록 4항목 · 쓸 수 있는 기록 · 패치 표 행 대응 · `hash_engine` 행은 전문가와 똑같이 묶는다. 하나의 일관된 메커니즘이 여러 곳 · 여러 파일에 걸치는 것을 한 회차의 변경 1건으로 센다 (모든 정지점에 담당 fixer 가 있지 않아서 쓰는 마지막 수단이다) |
| fixer 의 답 | `escalate` · `suspect_prior_bypass` · `bypass_doc` · `category` 필드가 있었다 (파이프라인이 읽지 않았다) | 필드가 없다. 열린 질문은 `no_new_change=true` 와 `rationale` 로 답하고, 반려한 fixer 의 `rationale` 이 다음 에스컬레이션의 초점이 된다 |
| 일반 fixer 의 빌드 실패 판정 | 일반 fixer 가 자기 답에 `build_ok=false` 를 쓰면 그것만으로 `BLOCKED_BUILD` 로 정지했다. 파이프라인이 잰 빌드 결과는 이 경로에 없었고, `qemu_abort` 경로의 일반 fixer 는 빌드 실패를 아예 보지 않았다 | 적용 단계가 `ninja` 를 재서 `build_ok` 를 낸다. **측정이 권위다:** 측정이 `false` 이면 정지하고, 측정이 `true` 이면 fixer 가 자기 빌드를 실패라고 보고해도 정지하지 않는다. 측정이 없거나 `null` 일 때만 fixer 의 `false` 가 선다 (`applyChange`). **계열과 무관하게 달라진다** (일반 fixer 에 닿는 모든 실행). 전문가 경로는 이전처럼 측정값만 본다 |
| fixer 프롬프트의 구성 | 전문가 프롬프트에는 `Originating exception block` 줄이 있었고 `Console` · `Summary` · `Full trace` 줄은 일반 fixer 만 받았다. 일반 fixer 는 supervisor 의 `suspect_prior_bypass`(정체 때 앞선 우회의 부작용부터 의심하라는 줄)를 받지 않았다. 규칙은 각 프롬프트의 꼬리 문구와 에이전트 파일에 따로 있었다 | 둘이 한 함수(`fixerContext`)로 같은 맥락을 받는다. 전문가 프롬프트에 `Console` · `Summary` · `Full trace` 줄이 **더해지고** `Originating exception block` 줄은 **빠진다** (같은 블록은 `Fingerprint` 줄 끝의 `최초 예외 블록:` 으로 여전히 간다). 일반 fixer 도 `suspect_prior_bypass` 줄을 받는다. 규칙 본문은 `FIXER_RULES` 로 옮겼다. **계열과 무관하게 달라진다.** fixer 가 읽는 입력이 바뀌므로 fixer 의 선택이 달라질 수 있고, 그 효과는 측정하지 않았다 |
| `verify.py` | 옛 `--track` · `--bl3` 흐름과 `verify_byte_match.py` | 없다. 두 옵션은 인자 오류(종료코드 2)다. 판정 로직과 JSON 키는 그대로다 |

### 지운 것과 줄인 것

- `scripts/verify.py` 의 옛 흐름(`verify_track1` · `verify_track2` · 옛 판정 문구, 931 → 688 줄), `scripts/verify_byte_match.py`(80 줄. 문서가 말하던 "`verify.py` 와 같은 판정"은 거짓이었다), `derived_facts.py` · `static_rotate.py` · `analyze_run.py` 의 숨은 `--track`, `make_export.sh` 의 `kboot_*` 글롭, `docs/bootchain-feasibility.md`(폐기된 트랙 1 · 2 구분 위의 v0.18.0 기록)
- 한 벤더의 이름: `verify_gates.py` 의 성분 이름과 게이트 2 실패 문구, `profiles/generic.yaml` 의 힌트(`epbl` · `teegris` · 셸 프롬프트 · `keystorage`는 `exynos.yaml` 로), `storage_hci.c.tmpl` 의 항상 준비 · 전부 1 반환 값
- 검증자(verifier) 프롬프트가 더는 명시적 `--pc` 를 권하지 않는다 (`verify.py` 는 그 옵션을 받고 무시한다. 항목은 "열어 둔 것")
- fixer 공통 규칙은 `workflows/pipeline.js` 의 `FIXER_RULES` 하나가 되어 전문가 여섯과 `fixer-general` 에 붙는다. `agents/fixer-*.md` 일곱 파일은 889 → 712 줄이 되었고 그 fixer 만의 것과 포인터 한 단락이 남았다. 일반 fixer 호출 세 곳이 `settleGeneral` 하나로, 적용 단계가 `applyChange` 하나로 모였다. 그래도 **`pipeline.js` 는 4,184 → 4,315 줄로 늘었다.** 새 적용 단계 · 질문 이월 · carve 기록이 지운 중복보다 컸다
- 텍스트 중립: 여섯 fixer · supervisor · static-analyzer · 분류기의 JSON 예에 "모양만" 표시와 자리표시자, 마일스톤 열은 줄 모양으로, static-analyzer 저장소 절은 매체 종류를 먼저 정한다. `examples/s921n-exynos2400` 에 "값을 차용하지 않는다" 표지, `.gitignore` 의 문서 이름은 `/NAME` 으로 고정

### 정본과 문서가 바뀐 곳

- `CLAUDE.md` §3: `kernel_entry` 는 한 부트로더의 문자열이 아니라 "부트로더가 자기 커널 점프 줄(도출값)을 낸 것". 커맨드라인의 `param` 폴백은 `--family exynos` 일 때만. 표면 칸의 내장 배너가 없다는 것과 입력 계획이 없으면 패턴도 없다는 것. §4: `FIXER_RULES`, 일반 fixer 의 검문과 그 범위(`CHANGE_SCOPE=general` 은 파일 · hunk 검사만 건너뜀), 스크립트 표(`carve_disasm.py` 행 신설, `check_change.sh` 행에 범위). §9 · §16: 회차 1건 = 변경 1건에서 일반 fixer 는 한 메커니즘이 여러 곳에 걸쳐도 1건이고 파일 · hunk 수는 전문가의 한계다. §10: `BLOCKED_CARVE` 는 `false` 일 때만. §11: 항목 2 의 대조 대상에서 한 벤더의 성분 이름을 뺌
- `README.md` 의 "지키는 것", `docs/components.md`, `docs/onboarding/04`, 그리고 설계 문서 runbook · bypass-policy(0.29.1 에서 삭제)의 회차당 변경 1건 서술에 같은 범위를 적었다. 설계 문서 status §10-3(삭제됨)에 이 정리와 **의도적으로 열어 둔 것**을 적고(구현 현황의 단일 출처), roadmap(삭제됨)은 정리가 새 단계가 아님을 적었다. 세 설계 문서가 입력 위치로 적던 `analyze/<기기>.zip` 은 "수작업 키트(저장소에 포함되지 않는다)"로 바꿨다. verification(삭제됨)의 낡은 서술(옛 `verify_track1` 이 `--surface` 를 읽는다는 것)을 바로잡았다
- `agents/static-analyzer.md` 를 코드와 맞췄다. carve 절은 기준을 `--family` 로 고른다고 쓰고(`exynos` · `mediatek` 은 그 계열의 기준, `generic` 이나 기준이 없는 계열은 기준 없음. `--family` 를 생략하면 예전 아키텍처별 동작이고 `family:` 줄이 없다), `is_full` 의 `True` · `False` · `null` 과 `carve_note` 를 설명한다. 입력 계획 절(12a)은 쓸 수 있는 계획이 없으면 인터럽트 패턴을 보내지 않고 `source: "absent"` 라고 쓴다 (옛 "기본값 CR 세 번" 서술을 지웠다). 명령줄 절(14a)은 `param` 폴백이 `--family exynos` 일 때만이라고 쓴다. 이 서술은 `tests/parts/family_kit.sh` 가 코드(`carve_disasm.py` 의 기준표, `uart_harness.py` 의 입력 계획, `build_lu.py` 의 폴백)와 대조한다. 설계 문서 status(삭제됨)의 L13 은 그래서 지웠고, 이미 고쳐져 있던 C13 · C14 (계획 예의 `partition` · `offset`, 태스크 정규식의 검색 서술)는 닫힘으로 바꿨다

### 열어 둔 것

감사가 지적했으나 일부러 고치지 않은 것이다. 이유와 전체 목록(13건)은 삭제된 설계 문서 status §10-3 에 있었다 (git 이력 1d47260 이후). 아직 열려 있는 것은 0.29.1 항목이 옮겼다.

- 매체 종류를 정하지 못했을 때의 UFS 기본값 (`warning_medium` 으로 알린다. 호환 시험이 고정한다)
- `patch_qemu_core.py` 의 세트 이름 `exynos` (이름이 계열이 아니라 SMC 훅이라는 동작이다)
- 정지와 회차 한계의 인계 블록 중복 (문구와 반환 필드가 다르고 시험이 각각을 고정한다)
- 서로 닮은 분석가 프롬프트 (시험이 각 문구를 고정한다)
- `run_full.sh` 의 fastboot 표면 폴백, `verify.py` 의 `--pc` 수용(무시) 등
- 일반 fixer 의 변경이 정말 한 메커니즘인지는 기계가 세지 않는다. 파일 · hunk 수를 일반 fixer 에게 세지 않기로 한 결정의 결과이고 (위 "동작이 달라지는 곳"), 그 판단은 `agents/fixer-general.md` 규칙 1 의 한 문장 설명 요구(프롬프트)와 "지문을 움직이지 못한 변경은 시도로 세지 않는다"가 맡는다

### 커버리지

영역별 시험 `tests/parts/*.sh` 를 파일별로 단독 실행한 값 (2026-10-06):
`family_kit` 163 · `init_clean` 184 · `integration` 115 · `machine_tmpl` 153 · `medium` 167 ·
`observe` 205 · `pipeline_family` 696 · `stage_map_arm32` 250 · `verify_gates` 269 · `canon` 471
(합계 2,673). 직전 점검(0.28.0 2차 작업 뒤)의 값은 `family_kit` 133 · `init_clean` 184 · `integration` 104 · `machine_tmpl` 143 ·
`medium` 141 · `observe` 187 · `pipeline_family` 556 · `stage_map_arm32` 228 · `verify_gates` 261 · `canon` 413 이었다.
`tests/uart_harness_test.py` 는 `smoke.sh` 가 부르지 않아 따로 돌렸고 통과했다. 전부 가짜 QEMU 와 합성 입력으로 돈 것이다.
**전체 `tests/smoke.sh` 는 이 항목을 쓸 때 돌리지 않았다** (마지막 전체 실행은 이 정리 전의 2,557 통과 / 0 실패다).
새 동작마다 되돌린 사본에서 시험이 실패하는 것을 담당자가 확인했다고 보고했고, 이 항목의 정본 · 문서 시험(`canon` 8c)은
문서나 코드 표식을 되돌린 사본에서 실패하는 것을 확인했다.

### 확인하지 못한 것

- **QEMU 에서 실행한 것이 없다.** 이번 변경 어느 곳도 실제 QEMU 로 돌려 보지 않았다.
- **계열이 주어졌을 때 Exynos 와 MediaTek 실행이 하는 일이 같다는 것**(위 "동작이 달라지는 곳" 의 예외를 뺀 것)은 코드를 읽고 합성 입력 시험으로 확인한 것이다. 실제 펌웨어로 이전 버전과 같은 결과가 나오는지는 돌려 보지 못했다.
- **"동작이 달라지는 곳" 은 알고 있는 차이의 목록이다.** `workflows/pipeline.js` 의 프롬프트 문구와 분기를 이전 판과 줄 단위로 전수 대조하지 않았다. 표에 뒤늦게 더한 둘(일반 fixer 의 빌드 실패 판정, fixer 프롬프트의 구성)은 검토에서 표 밖의 차이로 발견된 것이다. 같은 종류의 차이가 더 남아 있을 수 있다.
- 표면 칸의 내장 배너와 기본 CR 패턴 폐기는 계열과 무관하게 동작이 바뀐다. `milestone_tokens.txt` 나 `input_plan.json` 없이 표면에 닿던 실행이 실제로 있었는지 확인하지 못했다. 있었다면 이제 static-analyzer 가 그 파일을 써야 닿는다.
- `workflows/pipeline.js` 는 합성 에이전트로만 돌려 봤다. 실제 워크플로 런타임 · 실제 LLM 으로는 돌리지 않았다.
- `storage_hci.c.tmpl` 은 자리표시자로 바뀌었고 스텁 헤더로 구문만 검사했다. QEMU 10.2.2 헤더에 대한 컴파일은 하지 못했다.
- 0.28.0 항목의 "확인하지 못한 것"은 그대로 유효하다 (아래).

---

## 0.28.0 — 2026-10-05 (배포되지 않음, 0.29.0 에 포함)

**MediaTek 계열을 가이드 수준으로 지원하고, 그 설계 과정에서 드러난 공통 결함을 함께 고친다.**

### 무슨 일이 있었나

SM-A136U(MT6833) 한 대를 수작업으로 끝까지 진행한 키트가 있었다. 그 키트가 MT 지원을
위해 고쳤다고 적은 항목은 **저장소에 하나도 반영되어 있지 않았다.** 설계 12개 문서
(0.29.1 에서 삭제)를 쓰고 그 구현을 이번 버전에 넣었다.

설계 과정에서 MT 와 무관한 결함이 같이 나왔다. 이쪽이 Exynos 에도 해당한다.

| 결함 | 영향 |
|---|---|
| `run_full.sh` 의 감시 PC 목록이 항상 비어 있음 (`base` 가 딕셔너리인데 정수로 걸렀다) | 참고 항목 4 가 모든 SoC 에서 통과 불가 |
| 게이트 1 이 문자 배열 · 바이트 배열 · `printf` 를 놓치고, 호스트 줄이 섞이면 65건을 거짓 적발 | 위조 콘솔이 통과하거나 진짜 콘솔이 실패 |
| `verify.py` 가 `~/rehost/_traces` 의 다른 실행 트레이스를 집을 수 있음 | 항목 4 가 남의 트레이스를 판정 |
| `init` 의 정리가 플러그인 캐시에 한정되어 옛 QEMU 가 계속 재사용됨 | 최신 플러그인이라 믿고 옛 환경으로 진행 |
| `avb_negative.txt` 를 만드는 코드가 없음 | 참고 항목 5 가 모든 SoC 에서 통과 불가 |
| `ufs_controller` 라벨이 eMMC 기기에 찍힘, 템플릿에 `.interfaces` 가 없음, 부트 이미지 폴백의 page size 오프셋 오류, `registry.yaml` 이 엄격한 YAML 이 아님 | 판정 문구 오류, `-M help` 가 머신을 못 찾을 수 있음 |
| `export` 가 폐기된 "6/6 REAL" 을 요구하고 `plugin.json` 설명도 "6/6" | export 가 막히고 마켓 문구가 과장 |

### 무엇이 바뀌었나

| 영역 | 변경 | 주요 파일 |
|---|---|---|
| `init` 정리 | 정리를 캐시에서 도구 체인(QEMU 트리, pip), 임시 파일, 워크스페이스 보고까지 넓힘. 옛 것인지는 플러그인 버전이 아니라 **환경 개정 번호**로 판정. 표지가 있는 것만 지우고 표지 없는 것은 어떤 옵션으로도 지우지 않음. `--clean`, `--wipe-workspaces`(삭제가 아니라 이동), `--replace-unmarked` | `env_manifest.json`, `scripts/clean_env.sh`, `scripts/qemu_tree.sh`, `scripts/setup_env.sh`, `scripts/check_env.sh`, `scripts/purge_cache.sh`, `skills/init/SKILL.md` |
| 계열 자료 | 프로필의 `knowledge:` · `runbook:` 로 계열 지식표와 진행 가이드를 연결. `start` 가 판별 근거를 기록. 워크스페이스에 `.sboot_version` 표지 | `scripts/family_kit.py`, `profiles/*.yaml`, `skills/start/SKILL.md` |
| 진행 가이드와 지식표 | MediaTek 진행 가이드(S0~S9), 정지점 표 7행, eMMC(MSDC) 절. 담당 등록 확장과 `registry.yaml` 의 엄격 YAML 정정 | `knowledge/runbook_mediatek.md`, `knowledge/faults_mediatek.md`, `knowledge/faults_storage.md`, `fixers/registry.yaml`, `agents/*.md` |
| 스테이지 지도 | 스키마 v2(스테이지별 `arch` · `origin` · `entry_pc` · `confidence`), arm32 도출(컨테이너 헤더, GFH, **독립된 두 앵커**), 수렴하지 않으면 `unconfirmed` | `scripts/stage_map.py`, `scripts/carve_disasm.py`, `scripts/extract_boot_assets.sh` |
| 부팅 매체 | 항목별 `kind` · `lba` · `vendor`, `--medium emmc`, 출처 기록 `lu_provenance.json`, eMMC·UFS 판정(`unknown` 이면 고르지 않음) | `scripts/build_lu.py`, `scripts/detect_medium.py` |
| 관측 | 게스트 RAM 의 커널 로그를 호스트가 읽는 **메모리 덤프 채널**, 토큰 파일의 채널 열, 커널 채널 지문과 채널별 정체 판정, 게스트 리셋 신호, 예외 수 조기 종료(기본 꺼짐), 호스트 줄 분리 | `scripts/memdump_observe.py`, `scripts/run_full.sh`, `scripts/run_round.sh`, `scripts/stop_conditions.py`, `scripts/trace_filter.py`, `scripts/uart_harness.py`, `scripts/fingerprint_lib.sh` |
| 검증 | 게이트 1 을 C 렉서로 교체, 입력을 워크스페이스·회차에 묶음, 게이트 3 확장(타이머 콜백, 모니터 명령), 증거 준비 단계, 음성 시험용 매체, **검증 우회 보고**와 판정 문구, 우회 기록 검사(부작용 비움 금지, 패치 표 행 대응) | `scripts/verify_gates.py`, `scripts/verify.py`, `scripts/verify_prep.py`, `scripts/make_negative_image.py`, `scripts/check_change.sh`, `agents/verifier.md` |
| 머신 | 혼합 아키텍처 골격(구조만, 칩 상수 없음), `.interfaces`, 계열별 QEMU 코어 패치 세트(`--family`) | `templates/machine_mixed_arch.c.tmpl`, `templates/machine_full.c.tmpl`, `scripts/patch_qemu_core.py`, `examples/a136u-mt6833/` |
| 정본과 문서 | 아래 | `CLAUDE.md`, `skills/*`, `agents/fixer-secureboot.md`, `knowledge/faults_unified.md`, `scripts/make_export.sh`, `README.md`, `docs/*` |

### 정본이 바뀐 곳 (`CLAUDE.md`)

- **§3**: 표면 칸은 선택이다. `kernel_alive` 는 "커널만 낼 수 있는 줄이 어느 채널에서든 확인됨"으로
  일반화한다. 칸 상태는 `reached` · `reached_bypassed` · `not_reached` 이고 검증 우회가 있으면
  "F2 (verify_ok 우회 N건)" 으로 쓴다. 관측 채널과 계열 자료 묶음을 적었다.
- **§4**: "새 fixer 는 파일 하나와 등록 몇 줄"이라는 서술이 **틀렸다.** `KNOWN_FIXERS` 가
  `pipeline.js` 에 하드코딩되어 있고 `smoke.sh` 가 고정한다. 바로잡았다.
- **§7**: 우회 기록의 선택 항목 `메타` 한 줄, 부작용 비움 금지, 패치 표 행 태그 `/* bypass:<id> */`.
- **§10**: `BLOCKED_ARCH` 는 아키텍처가 아니라 **도출기가 진입 시그니처를 못 찾았을 때만** 선다.
  `BLOCKED_NO_INPUT_PATH` 는 입력 대기가 관측됐을 때만 선다.
- **§11**: 게스트 콘솔 정의, 게이트 1~3 의 새 내용, 검증 우회 보고, 판정 문구
  `VERIFIED (출처 검증 통과) · 검증 우회 N건 · verify_ok: reached_bypassed`.
- **§11 유일한 예외 (잠정)**: "검증 결과는 위조하지 않는다"에 **해시를 하드웨어 엔진이 계산하는
  펌웨어 하나**에 한해 예외를 넣었다. 순서는 엔진 모델링 → 라벨 달린 우회 → 정지이고, 소프트웨어 해시
  펌웨어에는 적용하지 않는다. **이것은 규칙의 완화다.** 예외가 없던 규칙에 한 경우의 예외를 넣었고,
  사용자의 결정(설계 문서 roadmap Q3, 0.29.1 에서 삭제)은 받지 않았다 (설계 권고를 적용했다. status D2).
  그래서 정본에 **잠정**으로 적고 사용자가 반대하면 지운다. 문을 여는 선행 조건을 붙였다: 해시가
  하드웨어 엔진이라는 사실을 static-analyzer 가 `STATIC.md` 에 `hash_engine` 으로 도출해야 하고,
  fixer 는 그 행을 쓰지 못한다. **그 조건의 기계 검사는 처음에는 없었고, 2차 작업(아래)에서 행의 유무와 모양만
  구현됐다** (`check_change.sh`, `status.md` D6). 행을 누가 썼는지와 (a) 의 실현 불가 판정은 기계가 하지 못해
  프롬프트와 verifier 가 집행한다.
  `agents/fixer-secureboot.md` 가 같은 분기와 조건을 따른다.
- **§14 · §15**: `init` 의 정리 범위와 인자, 환경 매니페스트, 디렉터리 도해의 `.sboot_version` ·
  `memdump_plan.json` · `lu_provenance.json`. 도해의 "6항목 측정" 오기를 고쳤다.
- **2차 작업에서 더한 것 (같은 0.28.0 안):** §3 관측 채널(`REHOST_MEMDUMP_REGION` 내보내기, `kernel_task_regex.txt`,
  호스트 줄을 계획과 무관하게 `host_N.txt` 로, `observation.json` 의 `kernel_log` · `host_log`), §3 커맨드라인은
  "PARAM 파티션"이 아니라 계획이 이름 붙인 파티션, §4 스크립트 표(`--detect-arch`, `extract_boot_assets.sh`, 새 키),
  §5 흐름(아키텍처 확정 · 커널 자산 적재가 Analyze 에), §10 정지 코드(`BLOCKED_ARCH` 의 `unknown` 처리, `BLOCKED_ASSET` 은
  적재한 뒤에도 없을 때만, `BLOCKED_KO` 의 방출기, `init` 의 종료코드 7, 재개 때의 회차 번호), §11(`hash_engine` 행의
  기계 검사 범위, 주소 창 표 참고 지표), §14(sudo 사전 점검, `start` 의 슬롯표), §15(`INPUT.md` 슬롯, `kernel_task_regex.txt`).

### 동작이 달라지는 곳

| 곳 | 이전 | 지금 |
|---|---|---|
| `check_change.sh` | 기록이 한 건도 없는 장부가 통과 (`count_field` 버그) | 반려. 부작용 비움 · `(기록 없음)` · 표 행 대응도 반려 (이번 회차에 새로 쓰거나 고친 기록만) |
| 게이트 1 | `error_setg` · `assert` 와 `printf` 가 면제 | 면제는 `error_report` 류와 `fprintf(stderr, …)` 뿐. UART 송신 호출 지점이 둘 이상이면 실패 |
| `verify.py` | 홈 폴더의 최신 트레이스를 폴백으로 읽음 | 읽지 않는다. **항목 4 를 계산하려면 `--trace` 를 넘겨야 한다** |
| `init` 기본 | 캐시만 정리 | 매니페스트와 어긋난 도구 체인을 지우고 재구축(시작 전에 알림), 1시간 이상 지난 임시 파일·트레이스를 지움 |
| 표지 없는 `~/qemu-build/qemu-10.2.2` | 그대로 재사용 | **지우지 않고 멈춘다.** `init --replace-unmarked` 로 옆으로 옮긴 뒤 새로 짓는다 |
| `make_export.sh` | `run.sh` 가 컨테이너만 넘김, `-m` 없음, `-cpu cortex-a76` 고정, 시간 한도 20초 | 합성 매체를 `-drive` 로 넘기고 `-m 2G`(회차와 같음). 시간 한도는 회차가 쓴 값(기본 200초, `RUN_TIMEOUT_S` 로 덮음), `handoff_tick` 이 있는 머신은 `-accel tcg,thread=single`, `-cpu` 는 `CPU` 를 줄 때만(혼합 머신은 주지 않음). `BUNDLE_FIRMWARE=0` 은 펌웨어 없이 해시 기록만 둔다. `build.sh` 가 계열 패치 세트를 적용 |
| 키트 완료 조건 | "6/6 REAL" | 게이트 3/3 + 목표 마일스톤 + 검증 우회 건수 명시. F2 의 최종 칸은 `kernel_alive` |
| `INPUT.md` · `.active` (2차) | 쓰는 곳이 없었다. `status` · `export` 가 읽는 `model` · `target` · `build` 가 비었다 | `start` 가 언팩 뒤에 슬롯표를 쓰고(출처가 없으면 `unknown`) `.active` 를 쓴다. `status` · `export` 는 슬롯이 없으면 `PROGRESS.md` 머리말로 대신하고 표시한다 |
| 아키텍처 (2차) | 스킬이 `arch` 를 넘기지 않고, 파이프라인 기본값 arm64 가 AArch32 이미지를 오류 없이 읽을 수 있었다 | `start` 가 `stage_map.py --detect-arch` 로 첫 컨테이너를 도출해 근거와 함께 기록하고 넘긴다. 파이프라인은 명시값을 따르고 `unknown` 이면 다시 묻고, 그래도 `unknown` 이면 임시 arm64 로 지도를 도출해 시그니처가 없을 때 근거와 함께 `BLOCKED_ARCH` |
| 커널 자산 (2차) | static-analyzer 가 사용자에게 `extract_boot_assets.sh` 를 부르라고 했다 (기본 F2 실행이 사람을 기다리는 `BLOCKED_ASSET`) | 파이프라인이 F2 이상에서 Analyze 앞에 그 스크립트를 부른다. 종료코드 4(super 만 실패)는 부분 적재. `BLOCKED_ASSET` 은 적재한 뒤에도 없을 때만 |
| 재개 (2차) | 회차 번호가 1 부터 다시 시작해 이전 회차의 로그를 덮고 `rounds.jsonl` 에 같은 번호가 생겼다 | 그 워크스페이스의 마지막 번호 다음부터 이어서 매긴다. `runtime_round_cap` 은 이번 실행의 회차만 센다 |
| `BLOCKED_KO` (2차) | 정본이 말하는 정지 코드인데 세우는 코드가 없었다 | F2 이상에서 분석가의 `storage_driver.form=absent` 일 때 파이프라인이 세운다 |
| 호스트 줄 (2차) | 메모리 덤프 계획이나 리셋 패턴이 있을 때만 `host_N.txt` 로 나뉘었다 | 회차가 `qemu-system-*:` 줄을 냈으면 항상. `observation.json` 에 `kernel_log` · `host_log` 경로 (없으면 null) |
| 쓰기 보호 영역 · 태스크 형식 (2차) | 머신 템플릿이 읽는 `REHOST_MEMDUMP_REGION` 을 내보내는 곳이 없었고 태스크 형식은 환경변수로만 바꿀 수 있었다 | 계획이 쓸 수 있으면 `run_full.sh` 가 영역을 내보낸다(없으면 설정하지 않고 환경의 옛 값도 지운다). 형식은 작업 폴더의 `kernel_task_regex.txt`. 키트 `run.sh` 도 같다 |
| 하드웨어 해시 우회 (2차) | `hash_engine` 행은 프롬프트로만 집행됐다 | 이번 회차의 표지 `F` 해시·다이제스트·서명 우회에 사용할 수 있는 `hardware` 행이 없으면 `check_change.sh` 가 반려한다. 보고에 `verify_bypass.hash_engine` 과 (혼합 아키텍처) 주소 창 표 상태 |
| 커맨드라인 (2차) | `build_lu.py` 가 항상 `param` 이라는 파티션에 썼다 (S-Boot 이름) | 계획이 이름 붙인 파티션에만 쓰고, 파티션에서 오지 않으면 쓰지 않고 `warning_cmdline`. 매체 종류의 근거가 없으면 `warning_medium` |
| `init` (2차) | sudo 가 비밀번호를 요구하면 백그라운드 `apt-get` 이 아무도 모르게 영원히 기다렸다 | 설치·삭제 전에 `sudo -n true` 로 시험하고 실패하면 종료코드 7(`BLOCKED_ENV`)과 사용자가 실행할 `apt-get` 줄을 내며 멈춘다 |

### 커버리지

영역별 시험 `tests/parts/*.sh` 를 파일별로 단독 실행한 값 (2차 작업 뒤, 최종 점검 2026-10-06):
`family_kit` 133 · `init_clean` 184 · `integration` 104 · `machine_tmpl` 143 · `medium` 141 ·
`observe` 187 · `pipeline_family` 556 · `stage_map_arm32` 228 · `verify_gates` 261 · `canon` 413
(합계 2,350). 통합 단계에서 처음 재었을 때의 값은 1,376(`family_kit` 74 · `init_clean` 154 ·
`integration` 70 · `machine_tmpl` 122 · `medium` 87 · `observe` 110 · `pipeline_family` 209 ·
`stage_map_arm32` 145 · `verify_gates` 157 · `canon` 248)이고 늘어난 것은 2차 작업의 시험이다.
**전체 `tests/smoke.sh` 는 최종 점검에서 끝까지 돌렸다: 2,557 통과 / 0 실패** (통합 단계의 값은 1,534 / 0).
`tests/uart_harness_test.py` 는 `smoke.sh` 가 부르지 않아 따로 돌렸고 통과했다. 전부 가짜 QEMU 와 합성 입력으로 돈 것이고
`stage_map_arm32` 의 실제 이미지 시험(`SBOOT_FIXTURES`)은 이 환경에서 건너뛰었다.
스테이지 지도와 매체 합성은 구현을 일부러 깨 보는 변이 시험으로 시험이 실패하는 것을 확인했고,
통합 시험(`integration`)과 파이프라인 시험(`pipeline_family`)도 같은 방식으로 확인했다. 2차 작업의 각 영역도
수정을 되돌린 사본에서 시험이 실패하는 것을 확인했다고 담당자가 보고했다 (이 정리 작업에서 다시 돌리지는 않았다).
`canon` 의 키트 시험(회차와 `run.sh` 의 QEMU 인자 비교, 환경 전달)과 정본 문구 시험도 옛 동작으로 되돌린 사본에서
실패하는 것을 확인했다.

### 통합 단계에서 맞춘 것

영역별 구현이 끝난 뒤 영역 사이의 인터페이스를 양쪽에서 읽어 어긋난 곳을 고쳤다.

- 입력 대기: 표면이 `none` 이면 하니스가 입력을 주지 않고(`--surface none`), 콘솔이 조용한데
  머신의 수신 폴링이 계속 늘면 `waiting_for_input` 을 `observation.json` 에 싣는다. 혼합 아키텍처
  템플릿에는 그 폴링 카운터(`REHOST-RX`)가 없어 하니스가 읽을 것이 없었다. 추가했다.
- 말이 없는 스테이지의 진입 칸은 트레이스에서 진입 PC 가 **실행된 줄**로 보일 때만 인정한다.
  FAR/ELR 줄에 이름만 나온 PC 는 진입이 아니다. 첫 스테이지는 머신이 CPU 를 놓은 자리라 제외한다.
- 검증 보고의 펌웨어 상태 문자열을 스크립트에서 모두 뺐다(벤더 문자열 금지). `status_tokens.txt`
  (static-analyzer 가 도출)와 `--status-token` 에서만 온다. **자동 보고가 이전보다 약해졌다.**
- `sync_machine.sh`: `machine_full.c` 가 `hw/arm/<기계>.c` 로 매핑되지 않던 것(Build 가 그 이름으로
  복사하라고 하는 소스를 동기화가 못 찾았다)과, 사라진 소스의 줄이 `qemu_targets.txt` 에 남던 것.
- `stage_map.py --merge`(이미지마다 돌린 지도를 합친다), `carve_check` 가 컨테이너 헤더가 선언한
  크기를 보는 것(실제 프리로더가 `is_full: False` 로 나오던 것), `-accel tcg,thread=single`(혼합
  머신만), 게이트 1 이 게스트 메모리 쓰기 위치를 보고로 싣는 것.
- 문서 대 코드: `patch_kernel.py` 는 세 번째 인자 `kernel_patch_sites.json` 을 받는다(문서는 코드에
  없는 PATCHES 표를 말했다). 여섯 fixer 프롬프트에 장부 규칙 문장. `.gitignore` 의
  `examples/a136u-mt6833` 예외.

### 리뷰에서 고친 것

독립 리뷰가 지적하고 재현으로 확인한 것 가운데 정본·스킬·내보내기 쪽이다.

- **재현 키트가 회차의 조건으로 돌지 않았다** (`make_export.sh`). `run.sh` 에 `-accel tcg,thread=single`
  이 없었고(혼합 아키텍처 머신), 시간 한도가 20초라 체인이 커널까지 가기 전에 끝나 `kernel_alive` 를
  관측할 수 없었고, 회차가 주지 않는 `-cpu cortex-a76` 을 고정으로 넘겨 그 CPU 를 허용하지 않는 머신은
  QEMU 가 거부했다. 지금은 회차와 같은 조건이다. `canon.sh` 가 같은 워크스페이스로 `run_full.sh` 와
  `run.sh` 를 모두 돌려 QEMU 인자를 비교한다.
- **`start` 가 `arch` 를 입력으로 넘기던 것.** 값을 정하는 규칙이 없고 파이프라인의 기본값이 arm64 라서
  AArch32 이미지가 오류 없이 AArch64 `exec` 스테이지로 읽혔다. 리뷰 시점에는 스킬이 `arch` 를 넘기지 않고
  도출한다고만 적었고 **그 도출은 들어 있지 않았다.** 2차 작업이 `stage_map.py --detect-arch` 와 파이프라인의
  도출 경로를 넣었다 (위 표의 "아키텍처").
- **정본 §11 예외**: 위 "정본이 바뀐 곳" 의 서술을 규칙의 완화로 고쳐 적었다.

### 2차 작업 — 감사에서 확인된 항목

리뷰 뒤에 한 번 더, 코드와 문서가 "플러그인은 순서·근거·측정을 주고 에이전트가 수행한다. 사용자는 단계마다 프롬프트를
넣지 않는다"는 원칙에서 벗어난 곳을 감사해 확인된 것을 영역별로 고쳤다. **버전은 올리지 않았다** (0.28.0 미배포).

| 영역 | 변경 | 주요 파일 |
|---|---|---|
| `init` | sudo 가 비밀번호를 요구하면 설치·삭제 전에 종료코드 7 로 멈춘다 (`--dry-run` 이 같은 점검, 계획 JSON 의 `apt`). root 는 `sudo` 없이 `apt-get` | `scripts/setup_env.sh`, `skills/init/SKILL.md` |
| `start` | 언팩 뒤에 `INPUT.md` 슬롯표(`model` · `build` · `target` · `bootloader_path` · `has_super` · `arch` · `bl_surface` · `soc_family` 와 근거)와 `.active` 를 쓴다. 값마다 출처가 있고 없으면 `unknown`. `arch` 는 첫 컨테이너의 `--detect-arch`. `status` · `export` 는 슬롯이 없으면 `PROGRESS.md` 로 대신하고 표시한다. 커맨드라인은 계획이 이름 붙인 파티션에 쓴다고 정정 | `skills/start/SKILL.md` · `skills/status/SKILL.md` · `skills/export/SKILL.md` |
| 스테이지 지도 | `--detect-arch <경로>`: 한 줄 JSON(`arch` · `entry_signature` · `basis` · `confidence`), 구조적 시그니처가 있어야만 이름을 대고 `unknown` 이 정직한 답. `extract_boot_assets.sh` 는 비대화형 · 멱등 · 종료코드 0~4 · 고정 요약 줄 · `xxd` 불필요 · 잘린 boot.img 거부 | `scripts/stage_map.py`, `scripts/extract_boot_assets.sh` |
| 파이프라인 | 아키텍처 입력 또는 도출(`unknown` 을 기본값으로 대신하지 않음), 커널 자산을 파이프라인이 적재, 재개 때 회차 번호 이어 매기기, `BLOCKED_KO` 방출(분석가의 `storage_driver`), 가이드 · 계열 자료 경로를 절대 경로로, 이미지별 `--detect-arch` 안내, `hash_engine` · 주소 창 표 보고, `kernel_log` · `host_log` | `workflows/pipeline.js` |
| 관측 | `run_full.sh` 가 `REHOST_MEMDUMP_REGION` 을 내보내고(계획이 없으면 설정하지 않음) `kernel_task_regex.txt` 를 스캔에 넘긴다. 호스트 줄은 매 회차 `host_N.txt` 로. `observation.json` 에 `kernel_log` · `host_log`. `RESUME.md` 에 마지막 회차의 로그 경로. 환경변수 `KERNEL_TASK_REGEX` 가 틀린 정규식이면 모든 `memdump_observe.py` 명령이 죽던 것 | `scripts/run_full.sh`, `scripts/run_round.sh`, `scripts/fingerprint_lib.sh`, `scripts/memdump_observe.py`, `scripts/make_resume.py` |
| 검증 | 이번 회차의 표지 `F` 해시·다이제스트·서명 우회에 `0x` 근거가 있는 `hardware` 행(`STATIC.md` 의 `hash_engine`)이 없으면 `check_change.sh` 가 반려(종료코드 2). 보고에 `verify_bypass.hash_engine`. 혼합 아키텍처 머신의 주소 창 표를 참고 지표(`address_windows`)로. 게이트는 셋 그대로 | `scripts/verify_gates.py`, `scripts/verify.py`, `scripts/check_change.sh`, `agents/verifier.md` |
| 매체 | `medium` 키가 없을 때도 `warning_medium`(UFS 기본값은 이전 호환이지만 조용하지 않다). 커맨드라인은 계획의 `partition`(선택 `offset`) · `source` · 매니페스트 `cmdline_partition` 순으로 파티션을 정하고, 해당 없으면 쓰지 않고 `warning_cmdline` | `scripts/build_lu.py` |
| 가이드 | 진행 가이드를 사다리 순서로 재정렬(S4 체인, S5 매체, S6 부트로더, S7 `kernel_alive`, S8 `userspace`, S9 `partitions_up`), 분류기 · supervisor 의 사다리 표를 `goalsFor()` 와 맞춤, 담당 열은 여섯 fixer 이름 또는 `build`, `hash_engine` 행의 모양(`static-analyzer.md` 14d), 장부 규칙은 "새로 쓰거나 고친 기록만"이라고 일곱 fixer 에 같은 문장 | `knowledge/runbook_mediatek.md`, `agents/*.md`, `fixers/registry.yaml`, `knowledge/faults_*.md` |
| 키트 | `run.sh` 가 회차처럼 `REHOST_MEMDUMP_REGION` 을 내보내고 `kernel_task_regex.txt` 를 가져간다. 기본 CPU(`cortex-a76`)는 0.28.0 리뷰에서 이미 없앴고 `CPU` 를 줄 때만 `-cpu` 를 넘기는 것은 그대로다 | `scripts/make_export.sh` |
| 기록 회전 (최종 점검) | `STATIC.md` 회전이 오래된 재도출 하위 절의 `hash_engine` 행과 주소 창 표를 보관 파일로 보내 검증의 `hash_engine` 상태가 `hardware` 에서 `absent` 로 바뀌었다 (다음 표지 `F` 해시 우회가 반려됐다). 정지점 행처럼 본문으로 올리되 `verify_gates.py` 의 같은 파서로 읽어 그대로 옮긴다 (파일 순서 유지: 마지막 행이 이긴다). 본문 정지점 표는 머리 줄이나 담당 열이 있는 첫 표로 찾아서, 옮겨 온 표가 그 표를 끊지 않는다 | `scripts/static_rotate.py` |

**2차 작업이 닫지 못해 남긴 것** (담당 파일이 이 정리의 범위 밖이었다. 상세와 근거는 삭제된 설계 문서 status §11 에 있었다):
`scripts/derived_facts.py` 가 `hash_engine` 행을 "새 사실"로 세지 않는다 (C12), `agents/static-analyzer.md` 14a 가 `partition`
키를 말하지 않는다 (C13), 가이드의 태스크 정규식 서술이 코드(검색, 처음 64자)와 다르다 (C14), 파이프라인이 분석가의
`has_super` 를 되읽지 않는다 (A20), 링 용량이 없는 영역의 두 경로가 어긋난다 (D7), `agents/static-analyzer.md` 14d 와 에스컬레이션 프롬프트가
`hash_engine` 행을 어느 절에 쓸지 말하지 않아, `## 해시 계산 위치` 를 파일 끝에 덧붙이면 그 뒤에 덧붙는 재도출 하위 절의 정지점 행이
`## 도출된 정지점` 절 밖에 놓여 읽히지 않는다 (C16 의 ②. 회전이 `hash_engine` 행과 주소 창 표를 보관 파일로 보내던 ①은 최종 점검에서
`scripts/static_rotate.py` 를 고쳐 닫았고 시험 `canon` 8b 가 잡는다).

### 확인하지 못한 것

- **QEMU 에서 실행한 것이 없다.** 이번 변경 어느 곳도 실제 QEMU 로 돌려 보지 않았다.
  메모리 덤프 관측기는 가짜 모니터 서버로만, 혼합 아키텍처 머신 템플릿은 QEMU 10.2.2 헤더에 대한
  컴파일만 확인했다. `cpu.c` 패치가 TCG 의 AArch32 CPU 생성을 실제로 여는지는 바이너리를 못 만들어 모른다.
- **플러그인이 MediaTek 기기를 처음부터 끝까지 진행한 적이 없다.** 근거는 한 기기(SM-A136U)의
  수작업 키트와 그 재현 실행이고, 다른 SoC 에서의 일반성은 확인하지 않았다. 키트의 `08_docs` 자료는
  입수하지 못해 arm32 도출은 실제 LK·프리로더 이미지와 디스어셈블 근거로 다시 구현했고, 임계값은 그 이미지에
  맞춰 정했다.
- **`workflows/pipeline.js` 는 합성 에이전트로만 돌려 봤다.** 실제 워크플로 런타임 · 실제 LLM ·
  QEMU 로는 돌리지 않았다. 항목별 현황은 삭제된 설계 문서 status §11-A 에 있었다.
- **입력 대기(`waiting_for_input`) 판정의 기준값**(최종 구간 길이, 폴링 증가)은 측정한 값이 아니다.
  머신이 수신 폴링을 드물게 보고하므로(첫 폴링과 약 100만 회마다) 보고 사이 증가로 판단한다.
- **프리로더의 `is_full`** 은 GFH 가 선언한 길이를 GFH 위치에서부터 센 값으로 비교한다. 그 필드의
  기준점이 GFH 시작인지 페이로드 시작인지는 한 이미지로만 봤다 (틀려도 더 엄격해질 뿐이다).
- `-accel tcg,thread=single` 은 혼합 머신에만 건다. 다중 스레드 TCG 에서 핸드오프 감시기가 안전한지는
  모른다. 매체가 eMMC 일 때의 컨트롤러 골격 템플릿은 만들지 않았다.
- capstone 이 없는 Python(예: macOS 기본 3.9)에서는 `carve_disasm.py` 와 `stage_map_arm32` 의 일부 시험이
  돌지 않는다. 시험은 그 경우를 건너뛴다고 말한다.
- 게이트 2 를 전체 참조 집합(수 GB)에 돌리지 못했다. 시간 예산 안에 끝나는지 모른다.
- **하드웨어 해시 엔진 모델링이 가능한지는 시험하지 않았다.** 정본 §11 예외의 첫 단계는 실현 가능성이
  미검증이다.
- **정본 §11 의 하드웨어 해시 예외는 사용자의 결정 없이 들어갔다.** 잠정이라고 적었고, 선행 조건(`STATIC.md`
  의 `hash_engine` 도출 행)의 기계 검사는 처음에는 없었고 2차 작업에서 행의 유무와 모양만 구현됐다. 사용자가 Q3 에
  답해야 확정되거나 지워진다.
- 실제 Linux · WSL 에서의 QEMU 18분 빌드와 GNU tar, 메모리 덤프의 `pmemsave` 지연,
  `console=ttyS0` 인데도 UART 가 침묵하는 원인은 확인하지 못했다.
- **2차 작업도 QEMU 로 돌리지 않았다.** 파이프라인의 새 경로(아키텍처 도출, 커널 자산 적재, 회차 번호 재개, `BLOCKED_KO`)는
  합성 에이전트와 실제 스크립트로만 시험했고 실제 워크플로 런타임 · 실제 LLM 으로는 돌리지 않았다.
- `--detect-arch` 의 임계값은 **실제 AArch32 이미지 둘과 합성·무작위 입력**으로 맞췄다. **실제 AArch64 부트로더로는 맞추지
  못했다.** 이 환경에서 실제 이미지 시험(`SBOOT_FIXTURES`)은 건너뛰었다.
- **`INPUT.md` 슬롯표와 `.active` 는 스킬 지시를 읽은 에이전트가 쓴다.** 스크립트가 아니라서 시험은 지시 문구가 코드와
  맞는지만 본다. 에이전트가 실제로 올바르게 쓰는지는 확인하지 못했다.
- 하드웨어 해시 선행 조건의 기계 검사는 **행의 유무와 모양만** 본다. 행을 누가 썼는지, (a) 가 정말 불가능했는지,
  `hash` · `digest` · `signature` 계열의 말이 없는 기록은 보지 못한다 (설계 문서 status D6, 0.29.1 에서 삭제).
- 실제 Linux 에서 `init` 이 sudo 사전 점검을 지나 apt 설치까지 가는 경로, 키트 `run.sh` 가 낸 `REHOST_MEMDUMP_REGION` 을
  실제 머신이 읽고 쓰기를 거부하는지는 확인하지 못했다 (가짜 `sudo` · 환경을 찍는 가짜 QEMU 로만).
- `examples/a136u-mt6833/` 는 `.gitignore` 예외를 넣었으나 **커밋하지 않았다.**

---

## 0.27.0 — 2026-09-01

**트레이스가 디스크를 채워 기계를 죽이던 것을 고친다.**

### 무슨 일이 있었나

SM-G970N 파이프라인이 15회차를 돌면서 회차마다 QEMU 전체 명령 트레이스를 10~12 GB 씩
남겼다. 약 6시간 만에 281 GB 디스크가 99%(여유 5.7 GB)까지 차고 **WSL 이 재시작됐다.**

### 정작 읽는 것은 넷뿐이다

| 소비처 | 무엇을 |
|---|---|
| `fp_origin` | **최초** `Taking exception` 블록 12줄 |
| 요약 로그 | 최초 예외 + 마지막 매칭 60줄 |
| 지문 | 예외 **개수** (내용이 아니라) |
| 참고 지표 | 스테이지 진입 PC 가 순서대로 나타났는가 |

나머지 10 GB 는 아무도 읽지 않는다. 특히 **원인은 첫 예외**이고 그 뒤의 재귀가 용량의
대부분인데, 재귀는 진단에 쓰지 않는다고 이미 문서에 적어 두었다.

### `scripts/trace_filter.py`

QEMU 와 로그 파일 사이에 FIFO 로 끼워, 위 넷만 남긴다.

- **스트리밍**이라 실행이 길어져도 메모리가 일정하다
- 머리: 최초 예외 블록 40개 (각 12줄)
- 꼬리: 매칭 줄 400개 (마지막 FAR/ELR 보존)
- 감시 PC: `stage_map.json` 의 실행 가능 스테이지 베이스. **첫 등장을 순서대로** 기록
- 중간은 한 줄 요약으로 대체

실측: **5,100,175 B → 451 B (0.009%)**. 예외 개수, 최초 예외, 감시 PC 순서 모두 보존.

예외 개수는 **잘린 로그가 아니라 필터가 원본 전체를 센 값**을 쓴다.

### 실행 실패 신호를 지우지 않는다

필터가 안내 줄을 항상 쓰면 로그가 비어 있지 않게 되어, "트레이스·콘솔 0바이트"라는
**QEMU 가 아예 실행되지 않았다는 신호가 사라진다.** 그러면 환경 실패가 펌웨어 판정으로
둔갑한다. 입력이 없으면 **빈 파일**을 쓰도록 했다. 이 회귀는 시험 17c 가 잡았다.

FIFO 교착도 막았다. QEMU 가 `-D` 를 열지 않으면 필터가 EOF 를 못 받아 `wait` 가 영원히
멈추므로, 셸이 쓰기 FD 를 잡고 있다가 QEMU 종료 후 닫는다.

### 디스크 가드와 보관 정책

- 회차 시작 전 `df` 로 여유를 확인하고 부족하면 **회차를 시작하지 않는다**
  (`MIN_FREE_MB`, 기본 4 GB, 종료코드 3)
- 지난 트레이스는 최근 것만 남긴다 (`TRACE_KEEP`, 기본 10)

### 커버리지

25절 신설 7항. **210 통과 / 0 실패.**

---

## 0.26.0 — 2026-08-31

**평문인 첫 스테이지를 암호화 구간에 흘려보내던 결함을 고친다.**

### 증상

실행 중이던 G977N 회차에서 `stage0(BL1)` 이 EPBL·B·C 와 함께 전부 건너뛰기로 확정되고,
리셋 PC 가 곧바로 `0xc9000000`(BL33)에 놓였다. **폐기한 트랙 1 이 sboot.bin 을 떼어내
BL3 만 올린 것과 도달 지점이 같아진다.** "첫 스테이지부터 연속 실행"이라는 이 흐름의
전제가 성립하지 않는다.

### 원인

`stage_map.py` 가 스테이지 상태를 **스텁-스텁 구간 전체의 암호화 비율**로 정했다.

```python
state = "encrypted" if enc_bytes > (hi - lo) * 0.6 else "exec"
```

G977N 에 대입하면 이렇다. 두 값 모두 `BOOTCHAIN_ANALYSIS.md` 의 확정값이다.

| 구간 | 크기 | 실제 |
|---|---|---|
| BL1 `0x0–0x5000` | 20,480 B | **평문. 진입 스텁 `0x10`** |
| EPBL `0x5000–0xe800` | 38,912 B | 암호화 (ent 7.92) |

진입 스텁이 BL1 과 BL2 에서 잡히므로 stage[0] 은 둘을 합친 59,392 B 가 되고,
**38,912 / 59,392 = 65.5% > 60%** 라서 실행 가능한 BL1 이 EPBL 과 함께 버려졌다.

### 수정

엔트로피 경계에서 스테이지를 쪼갠다 (`split_at_encryption`).

- 평문으로 시작해 암호화로 이어지는 구간은 **두 스테이지**다. 앞은 `exec`(진입 스텁을
  가진 쪽), 뒤는 `encrypted`
- 구간이 **암호화로 시작하면 쪼개지 않는다.** 진입할 수 없기 때문이다
- 암호화가 **꼬리 조각**이면(격자 하나 미만) 쪼개지 않는다. 포장 데이터나 키다

합성 이미지로 G977N 배치를 재현해 확인했다.

```
전: [0] first_stage encrypted 0x000000-0x00e800     ← BL1 이 흡수됨
후: [0] first_stage exec      0x000000-0x005000     ← BL1 살아남
    [1] stage1      encrypted 0x005000-0x00e800     ← EPBL 만 건너뜀
    [2] first_stage exec      0x00e800-0x030000
```

### 영향 범위

SoC 와 무관한 일반 로직이므로 벤더를 가리지 않는다.

| 대상 | 상태 |
|---|---|
| Exynos 9820 | 발동 확인 (BL1 20 KB 가 흡수) |
| Exynos 2400 | 발동 확인 (앞 32 KB 평문, `CLAIM_AUDIT.md` 6절 실측) |
| MediaTek | 여기까지 오지 않는다. arm32 라 `BLOCKED_ARCH` 로 먼저 정지 |

전 스테이지가 평문인 펌웨어는 건너뛰기 자체가 없어 이 경로를 타지 않는다.

### 커버리지

24절 신설. 변이 시험으로 옛 규칙을 되돌리면 4개 항목이 실패하는 것을 확인했다.
**203 통과 / 0 실패.**

---

## 0.25.3 — 2026-08-29

**문서에서 설명 문장을 걷어내고 표와 항목만 남겼다.**

| 문서 | 0.25.1 | 지금 | 산문 줄 |
|---|---|---|---|
| `README.md` | 180 | **108** | 25 → 18 |
| `01-rehosting-overview.md` | 187 | **122** | 31 → 5 |
| `02-unified-chain.md` | 190 | **141** | 59 → 19 |
| `03-boot-medium.md` | 183 | **138** | 55 → 16 |
| `04-loop-and-honesty.md` | 251 | **183** | 51 → 20 |
| `onboarding/README.md` | 30 | **28** | 10 → 5 |

- "왜 그런지"를 길게 푼 문장을 지웠다. 판단에 필요한 사실만 남긴다
- 표로 표현할 수 있는 것은 전부 표로
- 서론과 "읽고 나면" 안내를 제거

---

## 0.25.2 — 2026-08-29

**문서를 개괄식으로. 동작은 그대로다.**

- 문체를 한다체로 통일. `README.md` 에 섞여 있던 합니다체 35곳 정리
- 산문을 항목으로 바꿔 분량을 줄임

| 문서 | 전 | 후 |
|---|---|---|
| `README.md` | 180줄 | 118줄 |
| `01-rehosting-overview.md` | 187줄 | 148줄 |
| `02-unified-chain.md` | 190줄 | 159줄 |
| `03-boot-medium.md` | 183줄 | 149줄 |
| `04-loop-and-honesty.md` | 251줄 | 213줄 |

- 엠대시를 전부 제거. 제목 구분자는 콜론으로, 본문은 문장을 나누거나 접속 표현으로
- `05-plugin-check.md` 환경 표에 `lz4` 와 `simg2img` 추가
- `05-plugin-check.md` 에 `init` 의 캐시 삭제 동작 반영
- `components.md` 의 남은 산문을 항목으로

---

## 0.25.1 — 2026-08-29

**문서만 고쳤다. 동작은 그대로다.**

문서가 플러그인과 함께 배포되므로, 이미 받은 사용자에게 수정본이 가도록 패치 버전을
올린다.

### 문서가 구현과 어긋나 있었다

가장 큰 문제는 `README.md` 가 **한 문서 안에서 스스로 모순**된 것이다. 정직성 절에서는
"출처 검증 게이트 3항"을 통과 조건으로 적어 놓고, 바로 아래 "검증 6항목" 절에서는
0.21.0 에 폐기된 6항목을 통과 조건으로 다시 적고 있었다. 같은 서술이 온보딩 문서 04,
`components.md`, 온보딩 색인까지 여덟 곳에 남아 있었다.

전부 실제 구현으로 옮겼다. 판정을 막는 것은 게이트 3항(소스 대조, 출력 출처, 입력
출처)뿐이고, 체인 트레이스와 검증 양방향, 스토리지 이중 구동, 우회 기록은 측정해서
보고만 한다.

### 하지 않은 일을 한 것처럼 적고 있었다

`README.md` 의 비교표가 서명 검증을 **"통과시킨다"** 라고 단언하고 있었다. 실제로는
검증을 무력화하지 않는 것이 설계 원칙일 뿐이고, **어떤 펌웨어에서도 아직 서명 검증을
통과시킨 사례가 없다.** 지향하는 목표와 달성한 결과를 구분해 적었다.

같은 이유로 "Samsung Exynos · MediaTek 계열에서 검증 중"도 고쳤다. MediaTek LK 를
비롯한 AArch32 부트로더는 진입 스텁 시그니처와 머신 템플릿이 없어 `BLOCKED_ARCH` 로
정지한다.

**현재 상태** 절을 새로 넣었다. 실제 QEMU 실행을 아직 하지 않았다는 것, `machine_full.c.tmpl`
을 컴파일한 적이 없다는 것, `build_lu.py` 가 만든 GPT 를 실제 UFS 드라이버가 읽은 적이
없다는 것을 그대로 적었다.

### 빠져 있던 것

- **`kernel_entry` 와 `kernel_alive` 의 구분이 문서 어디에도 없었다.** 0.21.0 에서
  넣은 구분인데, 이것이 없으면 부트로더가 `Starting kernel...` 을 출력한 것만으로
  커널이 실행됐다고 오독하게 된다. 실제로 그런 사례가 있었다.
- `console=ram` 때문에 커널이 조용할 수 있다는 설명이 없었다.
- 매체 합성 문서에 sparse 이미지 정지, PARAM 커맨드라인 기록, 총 크기 고정,
  `snapshot=on` 기본값이 모두 빠져 있었다.
- `components.md` 에 스크립트 7개(`purge_cache.sh`, `check_release.sh`,
  `install_git_hooks.sh`, `setup_env.sh`, `extract_boot_assets.sh`, `wsl_bridge.sh`,
  `py.sh`)가 없었다.
- 정지 코드 표에 `BLOCKED_KO` 와 `BLOCKED_BUILD` 가 없었다.

### 읽기 쉽게

제목의 구분자로 쓰던 엠대시를 콜론으로 바꾸고, 본문의 엠대시 12곳은 문장을 나누거나
접속 표현으로 풀었다. 엠대시는 앞뒤 관계를 지나치게 함축해서 무엇이 무엇의 근거인지
흐려진다.

`docs/bootchain-feasibility.md` 는 v0.18.0 시점의 기록이라 손대지 않았다. 지난 판단을
지금 기준으로 고쳐 쓰면 그것은 더 이상 기록이 아니다.

---

## 0.25.0 — 2026-08-29

**옛 버전을 지우고서야 시작한다. 그리고 버전을 안 올리면 push 가 막힌다.**

### `init` 이 옛 캐시를 먼저 없앤다 (`scripts/purge_cache.sh`)

플러그인 캐시는 버전마다 폴더가 남는다. 옛 폴더가 있으면 어떤 경로로든 옛 스킬·
에이전트·스크립트가 다시 로드될 수 있고, 그러면 회차·로그·판정이 전부 옛 규칙을
따른다. **이 저장소에서 실제로 `0.2.0` 과 `0.17.0` 이 남아 있었고 세션은 `0.17.0` 을
로드하고 있었다 — 저장소가 `0.24.0` 인데도.**

`init` 의 Step 0 가 최신 하나만 남기고 전부 지운다. `__pycache__` 도 지운다.
다른 플러그인의 캐시는 건드리지 않는다.

**세션이 이미 로드한 것은 캐시를 지워도 바뀌지 않는다.** 그래서 옛 버전을 로드 중이면
종료코드 1 로 **거기서 멈추고** 갱신·재시작을 요구한다 — 정리했다고 보고하면서 옛
코드로 계속 도는 것이 가장 나쁘다. 지운 것이 지금 세션이 쓰던 버전이면 재시작 전까지
명령이 동작하지 않을 수 있다는 것도 함께 알린다.

### push 전 버전 검문이 잊을 수 없는 자리로 (`scripts/git-hooks/pre-push`)

`check_release.sh` 는 있었지만 **사람이 부를 때만** 돌았다. 0.19.0 이 정확히 그렇게
새어나갔다 — 버전을 박은 커밋 뒤로 커밋 3 개가 같은 번호로 46 개 파일을 내보냈고,
0.19.0 을 이미 받은 환경은 그 수정을 영원히 받지 못했다.

이제 `pre-push` 훅이 부른다. 버전을 올리지 않았으면 push 가 막힌다.
`bash scripts/install_git_hooks.sh` 로 켜고, 의도적으로 넘기려면 `--no-verify`.

### 커버리지

23 절 신설 — 캐시 정리(최신만 남김 · dry-run · 실제 삭제 · **다른 플러그인 불가침** ·
옛 버전 로드 시 종료코드 1 · 최신 로드 시 0)와 push 게이트.

**196 통과 / 0 실패.**

---

## 0.24.0 — 2026-08-29

**시험이 다시 제품을 지킨다 — 47 실패에서 185 통과 / 0 실패로.**

`tests/smoke.sh` 는 0.19.0 통합 개편 이후 통합 이전 규약을 쓰고 있어서, 그 뒤 다섯 판
동안 어떤 변경도 회귀로 지켜지지 않았다. 이번 판에서만 배선 누락 두 건과 없는 함수
호출 한 건이 하네스로만 잡혔던 이유다.

### 원인은 인자 하나였다

`run_round.sh` 에서 `track` 위치 인자가 없어졌는데 시험이 계속 넘겨서, 모든 인자가 한
칸씩 밀렸다 — `run_n` 자리에 머신 이름이 들어가는 식이다. 16 개 호출에서 그 인자를
빼자 **47 → 12 실패**가 됐다.

### 그 과정에서 드러난 제품 버그

**커널측 마일스톤이 도달해도 선택되지 않았다.** `run_full.sh` 의 "최고 단 선택" 루프가
`surface` · `commands` · `autoboot` 라는 **부트로더 칸만** 순회했다. 트랙 1 시대의
목록이 그대로 남은 것으로, `scsi_attach` 나 `kernel_alive` 에 도달해도
`milestone=none` 이 나온다. 사다리를 `run_round.sh` 가 넘겨주고, 최고 단을 **그 사다리
순서로** 고르도록 고쳤다.

`milestone` 과 `milestones_reached` 의 역할도 갈랐다 — 앞은 "이 사다리에서 어디까지",
뒤는 "무엇을 봤나"다. 사다리 밖 단에 도달한 회차가 목표 판정을 흐리지 않는다.

### 낡은 시험 정리

폐기된 것을 검사하던 일곱 항목을 현재 계약으로 옮겼다 — `FIXERS_BY_TRACK`(0.19.0 에서
`KNOWN_FIXERS` 로), `BLOCKED_STORAGE`·`STORAGE_DEPENDENT_RUNGS`(0.19.0 폐기),
`{ENTRY_PC}`(`{RESET_PC}` 로), `K3a`(`최소 완료` 로), `ANALYSIS.md` 절 번호 고정.

커널 마일스톤 시험은 **도출 토큰 계약**을 지키도록 고쳤다. 통합 설계에서 관측 문자열은
`milestone_tokens.txt` 도출값이지 코드에 박힌 값이 아니므로, 시험도 그 파일을 쓴다.

### 없던 커버리지 (22 절 신설)

변이 시험으로 **잡지 못하는 것**을 찾아 채웠다 — sparse 차단, PARAM 커맨드라인 기록,
총 크기 경고, `qemu_abort` 판정, 매체 snapshot.

`fp_run_verdict` 는 네 경우를 모두 시험한다: 정상 종료 · `timeout`(124) · 콘솔이 나온
뒤의 assert(머신 결함) · 콘솔도 트레이스도 0(환경 실패). 트레이스만 있어도 QEMU 는
실행된 것이므로 머신 결함으로 센다.

### 시험이 저장소를 더럽히던 것

가짜 QEMU 가 `-serial` 값에서 무조건 `file:` 접두를 벗겨, `-serial stdio` 가 `stdio`
라는 파일명이 됐다. 실행할 때마다 저장소 루트에 `stdio` 가 생겼다. `file:` 로 시작할
때만 파일로 보도록 고치고, 임시 파일도 `/tmp` 대신 작업 폴더로 옮겼다.

---

## 0.23.0 — 2026-08-29

**`init` 복원, 그리고 지난 판에서 만들어만 두고 연결하지 않은 배선을 잇는다.**

### `init` 복원 — 명령 넷

| 명령 | 역할 |
|---|---|
| `/sboot-rehost:init` | **설치 후 1회.** QEMU 10.2.2 빌드 + 의존성 + 작업 폴더 (약 18분) |
| `/sboot-rehost:start [F1\|F2\|F3]` | 실행 |
| `/sboot-rehost:status` | 조회 |
| `/sboot-rehost:export` | 재현 키트 |

0.22.0 에서 `init` 을 `start` 에 흡수시킨 것을 되돌린다. **QEMU 빌드가 18분**이라
실행 명령 안에 넣으면 리호스팅을 시작한 줄 아는 사용자를 그만큼 기다리게 한다.
환경은 펌웨어가 몇 개든 한 번만 만들면 되므로 성격이 다르다.

`start` 는 이제 환경이 미비하면 **`BLOCKED_ENV` 로 정지하고 `init` 을 안내**한다.
설치를 스스로 시작하지 않는다.

### 연결되지 않은 배선 두 곳

0.21.0 에서 만들었으나 **소비하는 쪽이 없어 실제로는 동작하지 않던** 것들이다.

- **`run_fault` 가 아무에게도 도달하지 않았다.** `run_full.sh` 가 JSON 으로 내보내기만
  하고 `run_round.sh` 의 `observation.json` 에 옮기지 않아, 파이프라인은 여전히
  `run_failed` 만 봤다. 이제 관측 문서로 옮기고 파이프라인이 **`fixer-general` 에
  `qemu_abort` 로 라우팅**한다 — assert 줄을 증거로 함께 넘긴다.
- **`cmdline_plan.json` 을 아무도 요구하지 않았다.** `build_lu.py` 는 읽을 준비가
  돼 있었지만 Analyze 단계가 산출을 지시하지 않아 파일이 생기지 않았다. 9번 항목으로
  추가했고, `kernel_entry` 와 `kernel_alive` 가 같은 토큰을 쓰면 안 된다는 것도 명시했다.

### 환경 점검이 도구 둘을 빠뜨리고 있었다

`check_env.sh` 가 `lz4` 와 `simg2img` 를 검사하지 않았다. `lz4` 가 없으면 BL 패키지에서
`sboot.bin` 을 꺼내지 못하고, `simg2img` 가 없으면 sparse 이미지를 raw 로 풀 수 없어
매체 합성이 정지한다. `setup_env.sh` 도 `simg2img`(`android-sdk-libsparse-utils`)를
설치하지 않고 있었다.

### 릴리스 검문 시험이 개발 중에 항상 깨졌다

`smoke.sh` 20절이 "저장소가 검문을 통과"를 요구했는데, 검문이 작업 트리를 보게 된
0.22.0 이후로는 미커밋 변경이 있는 한 항상 실패한다 — 개발 중에는 그게 정상이다.
저장소 자신에 대해서는 **판정이 나오는지만** 보고, 검문의 로직은 가짜 저장소로
양방향 확인하도록 바꿨다.

---

## 0.22.0 — 2026-08-29

**명령 셋만 남기고 전부 정리한다. 이름에서 중복도 없앤다.**

### 명령 표면 — 8개 → 3개

| 이제 | 역할 |
|---|---|
| `/sboot-rehost:start [F1\|F2\|F3]` | 실행 (환경 준비부터 검증까지) |
| `/sboot-rehost:status` | 조회 |
| `/sboot-rehost:export` | 재현 키트 |

- `rehost-init` · `rehost-setup` · `rehost-full` · `rehost-bootloader` · `rehost-kernel`
  **삭제**. 0.21.0 에서 안내 스텁으로 남겨뒀으나, 명령 목록에 8개가 뜨는 것이 정리하려던
  바로 그 문제였다. 명령 목록에 이들이 보이면 옛 버전이 로드된 것이다.
- `rehost-status` → **`status`**, `rehost-export` → **`export`**.
  네임스페이스가 이미 `/sboot-rehost:` 이므로 `rehost-` 접두는 중복이었다.

### 죽은 명령을 가리키던 살아 있는 코드

문서가 아니라 **실행 경로**에 남아 있던 것들이다.

- `make_resume.py` 의 `--command` 기본값이 `rehost-full` — 정지 시 사용자에게 **재개
  명령으로 출력되는 값**이었다. 없는 명령을 안내하고 있었다.
- `check_version.sh` 가 "`rehost-full` 이 보이면 최신"이라고 안내
- `check_env.sh` 가 "`rehost-init` 이 설치합니다"라고 안내
- `setup_env.sh` 가 "다음 단계: `rehost-full` 호출"로 끝남
- `inbox_readme.txt`(사용자가 드롭 폴더에서 읽는 파일)이 `rehost-setup` 을 안내

### `PROGRESS.md` 머리말이 만들어지지 않고 있었다

회차 루프가 `PROGRESS.md` 에 한 줄씩 **추가만** 하는데 머리말을 만드는 곳이 없어서,
그 이력이 어느 펌웨어·어느 등급의 것인지 알 수 없는 상태로 쌓였다.
`templates/PROGRESS.md.tmpl` 이 그 자리인데 **아무도 참조하지 않는 고아 파일**이었고,
`{TRACK}` placeholder 를 그대로 갖고 있었다. 트랙 슬롯을 없애고 `start` 에 배선했다.

### 릴리스 검문이 커밋 전에는 막지 못했다

`check_release.sh` 가 `git diff STAMP..HEAD` 만 봐서 **작업 트리의 변경을 보지 못했다.**
커밋한 뒤에야 경고하므로 정작 막아야 할 시점에는 조용했다. 스테이지·미추적 파일까지
포함하도록 고쳤다.

### 트랙 잔재

`fault-classifier` 의 표 머리 `| track |`, `supervisor` 의 "fixers implemented on this
track", `static-analyzer` 의 "**track boundary**, not a firmware fault"(0.19.0 에서
폐기된 개념), `analyze_run.py` 가 `INPUT.md` 에서 읽던 `트랙` 슬롯을 정리했다.

`--track` 을 조용히 무시하는 `static_rotate.py` · `derived_facts.py` 의 숨은 인자는
옛 워크스페이스 호환을 위해 남긴다.

---

## 0.21.0 — 2026-08-29

**명령은 `start` 하나, 검증은 "지어낸 로그 차단"만.**

### 명령 통합

`rehost-init`(폴더) → 펌웨어 배치 → `rehost-setup`(워크스페이스) → `rehost-full`(실행)
네 걸음이 **`/sboot-rehost:start` 하나**가 됐다. 세 단계로 나뉘어 있던 이유는 각각이
사용자 결정을 요구했기 때문인데, 지금은 전부 상태에서 도출되므로 가를 이유가 없다.

- `start` 는 상태를 보고 스스로 다음을 정한다 — 의존성이 없으면 설치하고, `_inbox/` 가
  비었으면 안내 후 종료하며, 펌웨어가 있으면 끝까지 자율 진행하고, 워크스페이스가 이미
  있으면 이어서 간다.
- 등급은 인자로만 받고 기본값 `F2`. **질문하지 않는다.**
- 남는 명령: `start`(실행) · `rehost-status`(조회) · `rehost-export`(키트).
  `rehost-init` · `rehost-setup` · `rehost-full` · `rehost-bootloader` · `rehost-kernel`
  은 안내 스텁이 됐다.

### 검증 — 6/6 게이트를 게이트 3항으로

전부를 통과 조건으로 두면 실제 진전이 `FORCED` 하나로 묻힌다. 판정을 막는 것은
**머신이나 에이전트가 만들어 낸 콘솔이 진짜 부팅으로 읽히는 것**뿐이어야 한다.

| # | 게이트 |
|---|---|
| 1 | 소스 negative — 머신이 출력하는 문자열이 콘솔에 나타나지 않는다 |
| 2 | 출력 출처 — 콘솔의 고정 문자열이 펌웨어 이미지 안에 있다 |
| 3 | 입력 출처 — 머신이 자기 수신 버퍼를 채우지 않는다 |

판정: `REAL`/`FORCED` → **`VERIFIED`(출처 검증 통과) / `UNVERIFIED`**.
체인 트레이스 · 검증 양방향 · 스토리지 이중 구동 · 우회 기록은 **측정해서 보고만** 한다.

**`verify.py` 가 통합 플로우에서 무력화돼 있었다.** `find_machine_sources()` 가
`machine.c`(트랙1) 와 `machine_kernel.c`(트랙2) 만 찾아 통합 템플릿의 산출물
`machine_full.c` 를 놓쳤고, 그 결과 자가주입 검출이 **소스 0 개를 검사하고 공허하게
통과**했다. 트랙 제거 때 놓친 잔재다. 이제 `06_machine/*.c` 를 전부 읽고,
**소스가 0 개면 통과가 아니라 실패**로 판정한다.

정밀화 세 가지:

- 검사 방향을 **리터럴 → 콘솔**로 뒤집었다. 반대 방향은 `"rehost.itmon%d"` 라는
  MemoryRegion 이름을 펌웨어의 ITMON 메시지와 충돌시켜 오탐을 냈다.
- `error_report`/`qemu_log` 인자와 QEMU 객체 이름은 게스트 콘솔이 아니므로 제외한다.
- 런타임 조립분(`%d` 치환값)은 대조 대상이 아니다. 실제 콘솔에서 4,511 개 중 3,131 개가
  숫자라는 이유로 실패하던 것을 고쳤다. 대조 범위도 같은 UART 를 쓰는 성분 전부로 넓혔다.

`tests/smoke.sh` 21 절에서 **막는 것과 통과시키는 것을 모두** 시험한다 — 머신의 문자열
출력, 지어낸 콘솔 줄, 자가 주입, 소스 0 개는 잡고, 런타임 숫자와 객체 이름은 통과시킨다.

### 커널이 조용한 이유 — `console=ram`

부트로더가 기본 커맨드라인으로 `console=ram` 을 고르면 커널 로그가 RAM 버퍼로 가서
**커널이 완벽히 떠도 시리얼에 한 줄도 안 나온다.** 그 침묵은 실패의 증거가 아니다.

- `static-analyzer` 가 후보를 도출해 `cmdline_plan.json` 에 쓴다.
- `build_lu.py` 가 **PARAM 파티션에 UART 조합을 기록**한다. 부트로더의 정상 경로
  (`setup_param_info` → `sbl_set_bootargs`)를 쓰므로 우회가 아니다.
- 사다리에 **`kernel_alive`** 칸을 신설했다. `kernel_entry`(부트로더가 `Starting
  kernel...` 을 찍음)와 `kernel_alive`(커널이 `Linux version` 을 찍음)는 다르다.
  점프 선언만으로 도달로 세면 커널이 실행되지 않은 실행을 완주로 보고하게 된다.

### 매체 합성

- **sparse 이미지를 감지하면 정지한다.** 매직 `0xed26ff3a` 를 그대로 복사하면 파일구조가
  깨지고, 그 결함은 한참 뒤 AVB 실패로 나타나 원인을 찾기 어렵다.
- **총 크기 고정.** 매체 크기가 바뀌면 부트로더가 GPT 를 재작성하고 신규 프로비저닝으로
  간주해 전원을 내린다 — 30 MiB 만 늘려도 걸린다.
- **`snapshot=on` 기본.** 부트로더가 PARAM·DDI 에 실제로 쓰므로 이대로 두면 회차가
  이전 회차의 디스크 상태를 물려받아 지문 비교가 오염된다. 쓰기를 관찰해야 하는 회차만
  `MEDIUM_WRITABLE=1` 로 해제하고, 그 사실을 기록한다.

### 새 정지점

- **`qemu_abort`** — 콘솔이 나온 뒤의 비정상 종료를 `BLOCKED_ENV` 로 처리하던 것을
  고쳤다. 게스트가 출력을 냈다면 QEMU 는 실행된 것이므로 환경이 아니라 머신 결함이며,
  assert 줄이 파일과 함수를 지목하므로 위치도 이미 특정돼 있다.
- **`handoff_slot_empty` · `boot_info_word_missing` · `download_mode_entry`** —
  건너뛴 스테이지가 남겼어야 할 값. `fixer-bootflow` 담당이며 **증거 3항**(읽는 명령의
  주소 · 실행됐다는 트레이스/콘솔 줄 · 채운 뒤 무엇이 검증되지 않는가)을 못 대면
  값을 지어내지 말고 `unknown` 을 반환한다.

---

## 0.20.0 — 2026-08-23

**0.19.0 이 두 번에 걸쳐 나갔다.** 버전을 박은 커밋 뒤로 커밋 3개가 같은 번호로 46개
파일을 바꿨다. 0.19.0 을 이미 받아간 환경은 그 수정을 받을 수 없다. 이 릴리스는 그
내용을 정식 번호로 내보내고, 같은 일이 다시 일어나지 않게 막는다.

### 통합 명령으로 남은 정리 (0.19.0 이후 전달되지 않았던 것)

- `rehost-setup` 이 트랙 1/2 를 묻고 `INPUT.md` 에 `track` 을 쓰고 있었다. 등급(F1/F2/F3)만
  묻도록 재작성했고 `track` 슬롯을 없앴다. **에이전트가 실제로 읽는 파일이라 이 하나로
  통합 이후에도 옛 질문이 나왔다.**
- `static-analyzer` 의 트랙별 체크리스트를 스테이지 지도 우선의 단일 체크리스트로 교체.
- `fault-classifier` · `supervisor` · `fixer-*` · `make_export.sh` · `setup_env.sh` ·
  `profiles/*` · `templates/*` 의 트랙 표현 제거.
- 옛 모델을 설명하던 `run_qemu.sh` · `run_kernel.sh` · `machine.c.tmpl` ·
  `machine_kernel.c.tmpl` 삭제. 남겨두면 다음 개편에서 또 참조된다.
- `KERNEL_STATIC.md` 를 `STATIC.md` 하나로 통합. 등급 이름 K3a/K3b 를 실제 마일스톤
  이름(`partitions_up` · `super_mounted`)으로 교체.

### 릴리스 검문 (`scripts/check_release.sh`)

버전을 올리지 않은 채 동작 표면이 바뀌면 종료코드 1 로 막는다.

- 검사 1 — `plugin.json` 과 `marketplace.json` 의 version 일치. 카탈로그가 낮으면 클라이언트가
  갱신을 보지 못한다 (0.17.0 에 두 판 묶여 있던 사례).
- 검사 2 — 현재 version 을 박은 커밋 이후 `agents` · `fixers` · `hooks` · `knowledge` ·
  `profiles` · `scripts` · `skills` · `templates` · `workflows` · `CLAUDE.md` ·
  `.claude-plugin` 이 바뀌었는가.
- 문서·시험은 대상이 아니다. 오타 하나에 릴리스를 강요하면 규칙이 지켜지지 않는다.
- `tests/smoke.sh` 20절에 편입. **막는 것뿐 아니라 버전을 올리면 다시 통과하는 것까지**
  가짜 저장소로 확인한다 — 언제나 통과하는 검문은 검문이 아니다.

### 알려진 문제 — `tests/smoke.sh` 가 통합 이전 규약을 쓴다

`run_round.sh` 의 `track` 인자가 없어지고 `run_full.sh` 의 콘솔 전달 방식이 바뀌었는데
시험 하네스가 따라오지 않았다. 가짜 QEMU 가 옛 CLI 를 흉내내 콘솔을 0바이트로 만들고,
그 결과 13개 절 48개 항목이 실패한다. **제품 코드의 결함이 아니다** — `run_round.sh` 를
통합 서명으로 직접 호출하면 유효한 `observation.json` 을 낸다.

또한 0.19.0 에서 추가된 `stage_map.py` · `build_lu.py` · `verify_full` · `check_version.sh` ·
`make_resume.py` 에는 smoke 커버리지가 없다. 나머지 항목은 legacy `--track` 경로를 지난다.
통합 경로의 시험은 다음 판의 작업이다.

---

## 0.19.0 — 2026-08-20

**트랙 2종을 통합 체인 하나로 대체한다. 부트로더가 커널을 직접 적재한다.**

부트로더 트랙과 커널 트랙을 따로 돌리면, 커널은 QEMU 가 `-kernel` 로 넘겨받는다. 그러면
부트 과정 전체가 건너뛰어져 커널 이미지만 실행하는 것과 구별되지 않는다. 컨테이너를 한 번
적재하고 첫 스테이지부터 rootfs 까지 한 번에 가도록 바꿨다.

### 통합 체인

- **QEMU 에 `-kernel Image` · `-dtb` · `-initrd` 를 주지 않는다.** 부트로더가 매체에서
  읽고 검증해 커널로 넘긴다.
- 목표 단계 A/B/C · K1/K2/K3 → **F1/F2/F3**. 스테이지 칸 수는 고정하지 않고
  `stage_map.json` 이 센 실행 가능 스테이지만큼 만든다.
- 실행 불가한 스테이지(암호화·부재)는 다음 실행 가능 스테이지로 진입을 재지정해 건너뛴다.
  건너뛰기가 정당하려면 이후 스테이지가 그 스테이지가 쓴 메모리를 읽지 않아야 하며,
  대신할 값을 지어내지 않는다.
- `BLOCKED_STORAGE` 폐기. 매체를 직접 모델하므로 파티션표 부재는 트랙 경계가 아니라
  합성 이미지의 결함이며 `fixer-storage` 가 담당한다.

### 스테이지 지도 도출 (`scripts/stage_map.py`)

엔트로피 격자 → 진입 스텁 스캔 → 문자열 문맥 → 적재 주소 순으로 도출한다.
**적재 주소는 basefind 만으로 확정하지 않는다.** 이미지 내부 포인터를 파일 오프셋으로
환산해 제로 패딩 시작 지점에 착지하는지 교차 검증해야 확정값이며, 앵커가 없으면 후보로만
표기한다. 포인터 포함률만으로 고른 값은 실제 펌웨어에서 틀렸다.

AArch32 는 진입 스텁 시그니처가 없어 종료코드 3 을 반환하고 `BLOCKED_ARCH` 로 정지한다.
"스테이지 없음"이 아니라 "도구 없음"이다.

### 검증 6항목

기존 5항목에 두 가지를 더했다.

- **검증 양방향** — 정상 이미지 통과에 더해 1바이트 훼손 시 실패해야 한다. 항상 통과하는
  검증기는 항상 통과하는 스텁과 구별되지 않는다.
- **스토리지 이중 구동** — 같은 모델을 부트로더 드라이버와 커널 드라이버가 둘 다 구동해야
  한다. 한 드라이버에 맞춘 모델은 컨트롤러의 모델이 아니다.

### 버전 게이트 (`scripts/check_version.sh`)

세션은 시작 시점에 로드한 플러그인 버전을 계속 쓴다. 갱신해도 이미 실행 중인 세션은 옛
버전으로 돈다 — 루프는 돌고 로그는 정상으로 보이는데 동작만 이전 릴리스의 것이다.
파이프라인 맨 앞에서 확인하고 어긋나면 `BLOCKED_VERSION` 으로 **정지한다.** 판정이
불가능한 경우(작업 사본)는 막지 않고 사유를 기록한다.

### 기록 — 멈춘 뒤 되짚을 수 있게

- `prompts.jsonl` — 사용자 입력 **원문**. 요약하지 않는다.
- `resolutions.jsonl` — 정지점이 풀린 경위. 목표 도달 시 자동 기록.
- `rounds.jsonl` 에 `rationale` 추가. fixer 를 지정했는데 사유가 없으면 그렇게 표시된다.
- `RESUME.md` — 정지·회차 한계 시 자동 생성. 도달 지점, 시도한 변경과 각각의 효과,
  아직 안 써본 수단, 재개 명령.
- `journal.sh` 에 `prompt` · `hypothesis` · `resolution` 동사 추가.

### 부팅 매체 합성 (`scripts/build_lu.py`)

GPT 디스크를 만든다(보호 MBR · 주/백업 헤더 · 엔트리 배열 CRC32). 파티션 이름은 부트로더
문자열에서 도출하며, 도출하지 못하면 기본값을 썼다고 결과에 명시한다. 지어낸 이름은
펌웨어가 영원히 찾지 못하는 파티션이다.

### 버전 배포 형식

`marketplace.json` 이 0.17.0 에 멈춰 있었다. 클라이언트는 이 카탈로그를 보고 갱신 여부를
판단하므로, `plugin.json` 만 올리면 사용자에게 아무것도 전달되지 않는다.
`check_version.sh` 가 두 파일의 버전이 어긋나면 정지하도록 했다.

### 플러그인 전반의 정합

개편이 파이프라인에만 반영되고 주변 파일은 옛 모양을 설명한 채 남아 있었다. 그중 둘은
동작에 직접 영향을 줬다.

- **`rehost-setup`** 이 트랙 1/2 를 프롬프트로 묻고 `INPUT.md` 에 `track` 을 썼다.
  이제 등급(F1/F2/F3)만 묻고 실행 명령도 `rehost-full` 하나만 안내한다.
- **`verifier`** 가 5항목으로 판정했다. 6항목 실행을 잘못된 기준에 대고 보고했을 것이다.

그 밖에 `static-analyzer` 의 트랙별 체크리스트를 스테이지 지도 우선의 단일 체크리스트로
바꾸고, `make_export.sh` 의 죽은 트랙 2 분기를 제거했으며, `run_qemu.sh` · `run_kernel.sh` ·
`machine.c.tmpl` · `machine_kernel.c.tmpl` 을 삭제했다. `KERNEL_STATIC.md` 는 `STATIC.md`
하나로 합쳤다.

### 그 밖에

- `fixer-secureboot` 신설 — 부트로더 자체 서명 검증. **검증을 패치로 무력화하지 않는다.**
- 지식표를 `knowledge/faults_unified.md` 하나로 병합하고 체인 위치 열을 뒀다.
- `entry_el_mismatch` 처방이 `has_el3=false` 로 편향돼 있던 것을 고쳤다. 진입 EL 은
  스테이지의 진입 스텁이 쓰는 `vbar_el*` 가 정한다.
- 프로파일을 트랙 기준에서 체인 기준(`chain:`)으로 재구성했다.
- `rehost-bootloader` · `rehost-kernel` 은 안내만 하고 종료한다.

---

## 0.18.0 — 2026-08-08

**입력 경로가 포기하지 않게 하고, 회차마다 무엇에 시간을 썼는지 기록에서 계산해 낸다.**

S921N(Exynos 2400) 실행 기록을 대조하다 하니스가 설계대로 동작한 적이 없다는 것을
확인했다. 그 수정과, 그 과정에서 드러난 두 가지를 함께 담았다.

### 하니스 — 표면 도달이 운이 아니라 설계로

`uart_harness.py` 는 예산의 65% 가 지나면 프롬프트를 못 봤어도 명령을 보내고 패턴 공급을
멈췄다. S921N 의 run 7·8·9 가 **전부** `명령 (프롬프트 미관측)` 으로 끝났다 — 셸에 도달한
두 회차까지 포함해서다. 즉 "프롬프트를 관측하면 명령을 보낸다" 는 분기는 한 번도 실행된
적이 없고, 도달은 t=0 에 부어둔 바이트가 버퍼에 남아 있어 성립한 것이었다.

- `SUPPLY` → `DISPATCH` → `COLLECT` 상태기로 나누고 **"포기" 상태를 없앴다.** 공급은
  프롬프트를 볼 때까지 또는 예산이 끝날 때까지 계속된다.
- 표면을 못 보면 **명령을 보내지 않고** `prompt_seen=false` 로 보고한다.
- 머신이 RX 소비를 stderr 로 보고하면(`templates/machine.c.tmpl`) 버퍼가 빈 시점에만
  다시 채운다. 프롬프트 재출력이 92 회에서 2 회로 줄었다.
- 게이트 성질(`contiguous`·`empty_poll_budget`)이 `input_plan.json` 의 **기계가 읽는
  필드**가 됐다. 그전에는 "빈 폴링 1회면 실패" 가 사람이 읽는 산문에만 있었다.
- 하니스 결과가 `observation.json` 까지 배선됐다. **게이트가 우리 바이트를 한 번도 읽지
  않은 회차**는 펌웨어 판정이 아니므로 fixer 를 부르지 않고 다시 실행한다.
- 회차 예산 기본값을 8 초에서 20 초로 올리고 `run_timeout_s` 로 노출했다. 프롬프트가
  벽시계 5.2~8.0 초에 나와 여유가 없었다.
- `timeout_bound` 가 세 값이 됐다. 프로브를 안 돌린 회차는 `false` 가 아니라 `null` 이다 —
  S921N 12~16 회차는 콘솔이 5 회 연속 같았는데 예외가 있다는 이유로 프로브가 생략됐고,
  측정하지 않은 값이 측정값처럼 판단에 들어갔다.
- 재현 키트의 `run.sh` 도 하니스를 쓴다. 그전에는 `sleep 3; printf` 파이프라 게이트
  패턴을 아예 보내지 않았고, 키트가 셸을 재현할 수 없었다.

### 실행 분석 — 시간과 비용이 어디로 갔나

`scripts/analyze_run.py` 를 추가했다. `rounds.jsonl` · `metrics.jsonl` · `blockers.jsonl`
에서 계산해 `ANALYSIS.md`(읽는 문서)와 `analysis.json`(수치)을 만들고, 내보내기와 Package
단계가 이것을 넣는다. 정지점의 동일성은 `stop_conditions.py` 의 판정 함수를 그대로 쓴다 —
다시 구현하면 보고서의 정체 횟수와 루프가 실제로 반응한 횟수가 갈라진다.

- 단계별 소요·비용, 오래 걸린 회차, **가장 오래 머문 정지점**, 정체 구간과 그것을 끝낸
  변경, 분류·담당 분포, 실제로 부팅을 전진시킨 변경, 소요 원인, 기록의 한계.
- 회차 소요에서 **재분석·재생성 시간을 분리**한다. 빼지 않으면 재생성 직후 회차 하나가
  세션에서 가장 비싼 회차로 잘못 잡힌다(S921N 에서 1 시간 54 분 → 27 분).
- 회차 번호가 되감기면 `2-1` 처럼 구간을 붙여 쓰고, 그 사실을 한계 절에 남긴다.

### 등급 C 와 트랙 경계 — 파티션표

부트로더가 파티션표를 못 읽으면 그 뒤의 환경변수·패널·모뎀·다음 단계 적재가 전부
실패한다. 파서 문제가 아니라 **읽어올 데이터가 없는 것**이고, 트랙 1 은 스토리지
컨트롤러를 구현하지 않으므로 고칠 수단도 없다. 그런데 사다리는 트랙이 금지한 수단을
요구하는 칸(등급 C)을 내걸고 있었다.

- 파티션표 가용성이 **관측값**이 됐다. 판정 문자열은 벤더마다 다르므로 static-analyzer 가
  `storage_tokens.txt` 에 도출하고, `run_qemu.sh` 가 `ok`/`missing`/`unknown` 을 기록한다.
- **토큰이 안 보이는 것은 근거가 아니다.** 스토리지 초기화 전에 죽은 회차는 `unknown`
  이며 아무 칸도 막지 않는다.
- `missing` 인 상태로 매체가 필요한 칸에 진입하면 `BLOCKED_STORAGE` 로 정지한다. 그 아래
  칸(A·B)은 영향이 없고, 정지 문구는 이것이 펌웨어의 한계가 아니라 트랙 경계임을 밝힌다.
- 하류 실패들은 정지점 하나(`partition_table_unavailable`)로 묶는다.

### 문서

- 사람이 읽는 문서의 서술 규칙을 `pipeline.js` 의 한 상수로 모아 다섯 곳에 붙였다 —
  공식적인 한국어, **용어를 새로 만들지 않기**, 통용되는 영어 용어는 그대로, 줄글 대신
  표·목록으로 항목화, 수치에 근거 파일 병기.

### 테스트

- `tests/uart_harness_test.py` — QEMU 없이 가짜 게스트로 도는 하니스 회귀 6 건. 핵심은
  **게이트가 예산 80% 지점에서 열리는 경우**로, 구 하니스는 여기서 반드시 블라인드로
  명령을 쏜다.
- `tests/smoke.sh` — 파티션표 관측 10 건, 실행 분석 11 건 추가. 155 건 전부 통과.

---

## 0.17.0 — 2026-07-28

**문서와 코드를 맞추고, 공개 문서의 용어를 통용어로 정리했다.**

문서를 전수 대조해 코드와 어긋난 11 건을 고쳤다. 가장 무거운 것부터:

- **`verifier` 가 옛 기준으로 재검증하고 있었다.** 항목 4 는 0.16.0 에서 셸 표면의 입력
  출처까지 보게 바뀌었는데 에이전트 문서에는 "single UART path" 만 남아 있었다.
  검증 판정 주체라 영향이 가장 컸다. `methodology/general_tables.md` 의 Table G 도 같다.
- **`skills/rehost-bootloader/SKILL.md` 가 한 파일 안에서 자기모순이었다** — 항목 4 설명이
  앞뒤로 달랐다.
- **`static-analyzer` 체크리스트에 두 도출이 없었다.** 파이프라인 프롬프트는 컨테이너
  TOC → BL33 진입점과 autoboot 게이트 입력 패턴(`input_plan.json`)을 요구하는데, 방법을
  적은 문서에는 없었다. 프롬프트로만 지시하면 규약이지 기구가 아니다.
- `README.md` — 결정론 컴포넌트 6/15 만 나열, `fixer-general` 누락, 정지 코드에
  `BLOCKED_ENV`·`BLOCKED_NO_INPUT_PATH` 누락, 흐름도에 rebuild/revert/sync 누락.
- `BLOCKED_TEE` 는 **자동 감지가 없다** — 다른 블로커는 전부 스크립트가 사실로 감지하는데
  이것만 사람이 판단해 기록한다. 문서 4곳이 자동인 것처럼 읽혔다.
- 컴포넌트 수(결정론 5 → 15), 트랙 1 도출 항목 수(12 → 14) 등 숫자 정정.

### 용어

공개 문서에서 임의 조어를 통용어로 바꿨다 — 무브 → 시도, 셤 → shim, 캡스톤 → 최종 단계,
런어웨이 → 폭주, 본령 → 핵심. 코드 식별자(`moves_exhausted` 등)는 그대로 두고 문서에서
병기한다. README 에 **용어 표**를 추가했다: 회차 · 지문 · 최초 예외 · 정지점 · 표면 ·
목표 사다리 · 우회 · 출처 게이트 · 시도 소진.

### 입력 하니스

게이트를 통과한 직후에도 인터럽트 패턴을 계속 보내면 그 바이트가 **빈 명령줄로 소비**되는
경합이 있었다. 폴링 주기(0.1s)와 타이핑 주기(0.3s)를 분리하고, 콘솔이 응답 중이면 다음
시도를 미룬다. 다만 부팅 로그가 계속 찍히는 펌웨어에서 굶지 않도록 상한(0.9s)을 둔다.

---

## 0.16.0 — 2026-07-27

**셸에 닿을 수 없던 이유: 입력이 없었다.**

부트로더는 부팅 중 콘솔을 잠깐 폴링해 **CR 연타** 같은 특정 패턴이 오면 셸로, 아니면
autoboot 으로 간다. 게이트는 보통 one-shot 이다. 그런데 실행 스크립트는 `-serial file:`
(출력 전용)이라 **입력 경로가 아예 없었고**, 머신이 리셋 시점에 자기 RX 버퍼를 `help\r`
로 한 번 채우고 있었다. 셋 다 틀렸다 —

1. `help\r` 은 게이트가 세는 CR 연타가 아니라 **조건이 성립할 수 없고**
2. t=0 한 번은 나중에 열리는 게이트에 대한 **타이밍 추측**이며
3. 머신이 자기 명령을 만들면 **순환검증**이다 (정직성 §7)

방법론 문서(`instruction.md` §8.1·§8.2·§8.4)에는 이 셋이 전부 정확히 적혀 있었다.
구현이 따라가지 않았을 뿐이다.

### 입력은 QEMU 밖에서 온다

- **`uart_harness.py`** — `-serial stdio` 로 게스트 콘솔을 잡고, 게이트 창 동안 인터럽트
  패턴을 **반복 시도**하다가 프롬프트가 관측되면 명령을 보낸다. 보낸 바이트는 전부
  `07_logs/input_N.txt` 에 남는다 — 우리가 친 것과 펌웨어가 찍은 것이 구분돼야 한다.
- **패턴은 도출값이다.** static-analyzer 가 셸 함수의 첫 `bl`(게이트)을 디스어셈블해
  연타 수 N 과 게이트 주소를 `input_plan.json` 에 쓴다. 벤더별 하드코딩이 아니다.
  도출 실패 시 문서화된 기본값(CR×3)을 쓰고 **기본값이었다고 기록**한다.
- **머신은 입력을 만들지 않는다.** 템플릿에서 자가 시드를 제거하고, 빠져 있던
  `qemu_chr_fe_accept_input()` 을 넣었다 — 없으면 QEMU 가 도중에 입력 공급을 멈추며,
  연타가 필요한 게이트에서는 치명적이다.
- **검증 항목 4 가 shell 표면에도 입력을 본다.** 셸에는 출력·입력 두 위험이 다 있는데
  출력만 검사했다. 머신이 자기 RX 를 채우면 이제 두 표면 모두에서 불통과다.

### 진입 PC 는 로드 주소가 아니다

컨테이너 이미지(TOC 헤더 + EPBL/BL2/BL33)는 통째로 로드하지만 **파일 오프셋 0 은 헤더**라,
거기로 진입하면 헤더를 코드로 실행해 첫 워드에서 트랩한다. 템플릿이 로드 주소로 진입해
루프가 rebuild 두 번으로 BL33 리셋 진입점을 알아내야 했다.

- 템플릿에 `ENTRY_PC` 슬롯 분리, Build 는 도출된 진입점을 요구하고 미확정이면 정직하게
  실패 보고한다 (로드 주소로 폴백하지 않는다).
- static-analyzer 사전 도출에 **컨테이너 TOC 파싱**과 **게이트 입력 패턴**을 추가했다.
  둘 다 루프에 맡기면 회차를 쓰는 항목이다.

### 구현 범위를 문서에 못박았다

`BROM → Preloader/BL1·BL2 → ★부트로더★ → 커널` 다이어그램이 "이 전부를 리호스팅한다"로
읽혔다. 그건 **어느 자리인가를 가리키는 지도**이고, 실행 범위는 처음부터 BL33 하나였다.

- SKILL.md 에 명시: BROM·BL1·BL2·시큐어월드는 **실행하지 않고** 셤/모델로 성립시킨다.
  컨테이너는 통째로 로드하되 BL33 세그먼트만 실행한다.
- 모델링(정상 모델)과 셤·우회(FORCED)를 구분해 적었다.

`tests/smoke.sh` 119 → 131 케이스. 게이트를 흉내내는 가짜 QEMU 로 하니스를 끝까지 돌린다.

---

## 0.15.0 — 2026-07-27

**지문을 최초 예외로 잡고, 고친 소스가 실제로 빌드되게 했다.**

exynos2400(S921N) 트랙 1 실행 기록 — 120 회차 / 25.1 시간 / 도달 등급 0 — 을 코드와
대조해 나온 결함들이다. 그 실행에서 **변경을 적용한 회차는 18 개**였고 78 회차는 아래
결함으로 소모됐다. 펌웨어가 어려웠던 것과 별개로, 루프가 스스로 만든 손실이다.

### 지문이 storm 에서 매 회차 달라져 정지·에스컬레이션·층판정이 죽어 있었다

`run_*.sh` 는 `grep FAR | tail -1` 로 지문을 잡았다. 핸들러가 자기 컨텍스트 세이브에서
다시 폴트하면 abort 가 중첩되어 FAR 이 0x20 씩 걷고, 실행은 타임아웃이 끊은 자리에서
멈춘다. **그 주소는 재귀의 위치이지 원인이 아니고, 같은 정지점인데도 회차마다 다르다.**

- `fingerprint_lib.sh` 신설 — 첫 `Taking exception` 블록(ESR/FAR/ELR)을 뽑아
  `origin` 으로 싣고 `07_logs/origin_N.txt` 에 남긴다. 마지막 FAR/ELR 은 기록으로만.
- 요약 로그가 **최초 예외부터** 보여준다. 이전에는 280만 예외의 마지막 60줄만 줬다.
- `stop_conditions.py` 지문 = (최초 예외 ESR/FAR/ELR, 마일스톤, 콘솔 바이트, 콘솔 고유
  줄, **예외 수 자릿수**). 2.86M 과 2.88M 은 같은 관측이므로 자릿수로 비교한다.
- 그 실행에서 회차 78~96 은 ELR 이 19 회차 내내 동일했는데 `stall_count` 는 계속 0 이었다.
  회차 5~27 의 23 회차 런어웨이도 층 재검토가 발화하지 못해 생긴 것이다.
- 옛 회차 기록(원발 필드 없음)은 옛 키로 비교해, 재개한 워크스페이스의 이력이 한 덩어리로
  뭉개지지 않는다.

### 고친 소스가 빌드되는 트리에 들어가지 않았다

fixer 는 `06_machine/machine.c` 를 고치고 ninja 는 QEMU 트리 `hw/arm/` 사본을 빌드하는데,
둘을 잇는 단계가 없었다. 회차는 검문을 통과하고 빌드도 성공한 채 **이전 바이너리를
측정**했고, 넣은 적 없는 수정이 "무효 변경" 으로 기록됐다.

- `sync_machine.sh` 신설. 회차 적용 · `rebuild` · `fixer-general` · `revert` 네 경로 모두
  ninja 앞에 부른다. 대상을 못 찾으면 `BLOCKED_BUILD` 로 정지한다 — 그 상태의 회차는
  측정이 아니기 때문이다.
- Build 단계는 `hw/arm/<machine>.c` 라는 이름으로 복사하도록 지시가 구체화됐다.

### 실행되지 않은 회차가 "구조상 도달 불가" 로 끝났다

QEMU 종료코드를 `tail` 파이프가 삼켰고, 실패해도 0 으로 채운 지문이 쓰였다. 전부 0 인
지문은 완벽히 안정되므로 정체 → `EXHAUSTED` 가 된다. 실행된 적 없는 펌웨어에 대해서.

- 종료코드(124·137 은 정상 타임아웃)와 트레이스·콘솔 0바이트를 검사해 `run_failed` 를
  세우고, 파이프라인은 그 회차에 `BLOCKED_ENV` 로 정지한다. 하네스 문제를 펌웨어 판정으로
  바꾸지 않기 위해서다.

### 도출표에 써도 닿지 않았다 — 20 건 중 3 건만 전달

`derived_facts.py` 가 `#` 로 시작하는 모든 줄을 제목으로 보고 섹션을 닫았다. 분석가가
회차마다 다는 `### round N 재도출` 이 첫 줄부터 표를 닫았고, 줄바꿈으로 `#` 로 시작하게
된 문장(`#179→#180 …`)도 같은 일을 했다.

- 섹션은 `#`·`##` 에서만 열리고 닫힌다. 코드펜스 안은 무시한다.
- 담당 fixer 칸을 기준으로 열을 잡아, 셀 안의 인코딩 바이트열(`4ac10011|280140b9|…`)이
  열을 밀어도 행을 잃지 않는다.
- 같은 시그니처는 한 행으로 합치고 최신 내용이 대체한다.
- 담당 fixer 칸이 없는 값 표(`carve` `bss_start` …)는 정지점으로 세지 않는다.
- 그 실행의 STATIC.md 로 재현하면 3 → 18 건이 전달된다.

### 반려가 회차를 끝냈다 — 순위 2·3 은 장식이었다

- 한 회차 안에서 순위 3위까지 실제로 물어본다. 반려는 변경이 아니므로 회차를 소모하지
  않고 다음 후보로 간다. 전원 반려해야 `fixer-general` 이 받는다.
- 그 실행의 120 회차 중 86 회차가 1 순위 반려만으로 끝났다.

### 반증된 우회를 되돌릴 수 없었다

우회는 하드웨어에 대한 가설이고 틀릴 수 있는데, 루프는 더하기만 가능했다. 틀린 모델이
남고 이후 모든 변경이 그 위에 쌓였다.

- `check_change.sh snapshot <N>` 이 회차별 소스 스냅샷을 남기고, `revert_change.sh` 가
  **그 회차의 diff 만 역패치**한다(그 회차로 롤백하지 않는다 — 이후의 옳은 변경은 유지).
- supervisor 에 `revert` 경로 추가. 이후 회차가 같은 자리를 고쳤으면 거부하고, 그 거부는
  "두 변경이 상호작용한다" 는 정보로 쓰인다.
- 철회도 우회 4항목으로 기록되므로 검증 항목 5 가 넣은 것과 뺀 것을 모두 보고한다.

### 사다리가 한 칸이면 전진을 셀 수 없었다

등급 A 사다리는 `[표면]` 한 칸이라, 부팅이 PMIC 를 지나 스토리지 초기화까지 가도
`best_milestone` 은 계속 null 이다.

- `best_progress` (콘솔 **고유** 줄 수) 를 정지 조건이 계산하고 정지 보고가 함께 낸다.
  바이트가 아닌 이유는 재시도 루프가 한 줄로 394KB 를 찍기 때문이다.
- `timeout_bound` — 정체된 hang 일 때만 4배 길게 한 번 더 돌려, 콘솔이 더 나오면
  "벽은 펌웨어가 아니라 우리 실행 시간" 이라고 보고한다. 지문은 건드리지 않는다.

### 도출 기록이 무한히 커졌다

에스컬레이션마다 근거 산문이 쌓여 302KB 가 됐고, 매 회차 다시 읽는 분석이 비싸졌다
(회차 6분 → 20분).

- `static_rotate.py` — 오래된 근거 산문만 `08_docs/static_archive.md` 로 옮기고, 그 안의
  표 행은 **먼저 본문 표로 승격**한다. 승격 없는 보관은 사실을 지우는 것이므로 전제다.
- 그 실행 기록으로 302KB → 52KB, 도출 18 건 전부 유지.

### 그 밖에

- 용어: 실행 기록·주석의 "원발/말단" 을 **최초 예외 / 마지막 예외**로 정리.
- `tests/smoke.sh` 91 → 119 케이스. 추가분은 전부 위 결함의 회귀 테스트다.

---

## 0.14.0 — 2026-07-23

**담당 없는 정지점에 출구를 냈다 (`fixer-general`), 그리고 트랙 1 은 스토리지로 가지 않는다.**

전문가 fixer 5명 중 아무도 담당하지 않는 정지점은 루프의 막다른 길이었다. supervisor 는
이제 **fixer 명부를 읽고 처방**하며, 어느 구현체도 그 메커니즘을 담당하지 않으면
`fixer-general` 로 직행시킨다.

- **`fixer-general`** — 범위 무제한. 어떤 머신 소스든 수정하고 빌드·실행까지 한다.
  도메인이 갈라놓은 것을 가로지르는 메커니즘을 한 회차에 처리하기 위해서다.
  **순위로는 못 오른다** (`KNOWN_FIXERS` 밖). 도달 경로는 둘뿐 — supervisor 가 직행시키거나,
  supervisor 가 지정한 전문가가 반려했을 때.
- **후보 기록이 절반의 일이다.** `<workdir>/fixer_candidates.md` 에 시그니처·메커니즘·고친
  곳·필요했던 지식·재발 횟수를 append 한다. 여러 펌웨어에서 같은 항목이 반복되면 정식
  fixer 로 승격한다 — **승격은 사람이 커밋한다.** 에이전트 레지스트리는 세션 시작
  스냅샷이라 런타임에 만든 파일은 그 회차에 로드되지 않는다.
- **소진 방어**: 범위가 무제한이면 "새로 시도할 변경 없음" 이 잘 안 나온다. 그래서
  `stop_conditions.py` 가 **지문을 못 움직인 변경은 수(手)로 세지 않는다**
  (`futile_spent`, 기본 6회). 도출도 말랐을 때만 적용되므로, 진전 중이면 멈추지 않는다.
- **supervisor 처방**: `treatment_plan` + `prescribed_fixer`. 이 처방이 분류기 순위보다
  우선한다 — supervisor 는 그 회차에 머신 소스와 도출 사실을 읽었고 분류기는 읽지 않는다.
  **패치가 아니라 방향까지만** 준다. 정확한 패치를 지정하면 fixer 가 판단을 멈추는데,
  `no_new_change` 를 답하는 건 fixer 이고 그게 정직한 정지의 입력이다.

**트랙 1 이 UFS 구현으로 새지 않게 막았다.** 스킬 문서에는 트랙 1 fixer 가 3명이라고
써 있었지만 코드는 5명을 다 허용했고, 분류기에는 트랙과 무관하게 지식 테이블 3종이
전부 넘어갔다. 그래서 부트로더 회차가 `poll_stall` 같은 트랙 2 정지점에 매칭될 수 있었다.

- `FIXERS_BY_TRACK` — 트랙 1 은 `fixer-memory`/`fixer-el3`/`fixer-bootflow` 만.
- 분류기에 넘기는 지식도 트랙별로 갈랐다 (트랙 1 = `faults_bootloader.md` 만).
- 스킬에 경계를 명시: 등급 C 의 스토리지는 **autoboot 이 막히지 않을 만큼**(스텁·우회
  가능)이고, 진짜 벤더 드라이버 구동은 트랙 2 K3 의 목표다.

스모크 테스트 11건 추가 — 총 91건 통과.

---

## 0.13.0 — 2026-07-23

**supervisor 에게 판단을 준다 — 루프가 못 고치는 층에 출구를 냈다.**

66회차 런어웨이(지문 `0x620` 고정, unknown 61/66, 무효 변경 2건, 2.13M 토큰,
`EXHAUSTED` 미발동)를 규명한 결과 네 가지가 맞물려 있었다.

- **supervisor 에게 결정권이 없었다.** 라우팅 표 5줄이 전부 입력에 이미 답이 들어있는
  조회였고, 그중 3줄은 파이프라인이 따로 강제하고 있었다. 정체 상황에서 남는 선택지가
  재도출 아니면 분류뿐이라 "무조건 넘기는" 것처럼 보인 게 아니라 실제로 그것뿐이었다.
- **Build 로 돌아가는 길이 없었다.** 이번 근본 원인은 `has_el3=true` 로 BL33 을 EL3 에
  진입시킨 것 — machine.c 의 리셋 전제다. fixer 는 "한 곳 수정" 만 하므로 밴드에이드
  (`vbar_el3_entry_clobber`) 밖에 못 붙였고, supervisor 는 원인을 알아도 "머신을 다시
  만들어라" 라고 말할 문법이 없었다.
- **소진 판정이 마지막 한 줄만 봤다.** 65회차가 전부 dry 여도 마지막 회차에 새 시그니처
  하나만 있으면 `analyst_dry=false` 로 리셋됐다.
- **"고쳤는데 아무 변화 없음" 을 아무도 안 봤다.** `stop_conditions.py` 의 `effect`
  참조가 0 이었다.

바뀐 것:

- **`rebuild` route 신설.** supervisor 가 Build 층으로 판정하면 구체적 전제 수정을 지정해
  머신을 재생성한다. 같은 `change_key` 재시도는 거부 — rebuild 가 무한 공급이면 소진이
  성립할 수 없다.
- **supervisor 가 판단자가 됐다.** 기계적 route 는 측정이 정하고 파이프라인이 강제하며,
  supervisor 에게는 **층 판정**이라는 실제 질문이 남는다. 그 판단에 필요한 근거(최근 회차
  이력, 도출표, 머신 소스 경로, 무효 변경 수)를 받고, `model: opus` 에 층 재검토가 필요한
  회차는 `effort: high` 로 돈다. 스크립트 결과를 옮겨 적는 자리가 아니다.
- **`futile_changes` / `needs_layer_review` 신호.** 변경이 적용됐는데 지문이 안 움직인
  횟수를 세어, 임계를 넘으면 supervisor 가 라우팅 전에 머신 소스를 읽도록 요구한다.
- **dryness 를 창(기본 3회차)으로 판정.** 한 회차의 반짝임이 수십 회차의 정체를 지우지
  못한다.
- **`entry_el_mismatch` 정지점 등재** — 담당은 `build layer`. 지식 테이블에 "어떤 fixer 도
  못 고치는 정지점" 절을 추가했고, fault-classifier 는 그때 `fixer_ranking` 을 비우고
  `layer: "build"` 로 답한다.

스모크 테스트 10건 추가 (창 판정 회귀 가드 포함) — 총 80건 통과.

---

## 0.12.0 — 2026-07-22

**도출한 사실이 실제로 쓰이게 배선 — 루프가 같은 unknown 을 반복하던 원인.**

실행 중 발견: 23회차 내내 지문이 `0x620` 으로 고정, 분류의 73%가 `unknown`, 적용된
변경 단 1건, 그런데 `EXHAUSTED` 도 안 나서 round cap 까지 토큰만 태울 궤적이었다.
원인은 네 군데였고 전부 **도출 결과가 아무 데도 가지 않는 것**에서 나왔다.

- **재도출 결과가 버려지고 있었다.** `esc.new_facts_count` 숫자만 꺼내 쓰고 `esc.facts`
  는 버렸으며, 분류기 프롬프트에 `STATIC.md` 언급이 0회였다. 그래서 분류기는 매 회차
  **직전과 동일한 입력**을 받았고, 같은 입력에 같은 답(`unknown`)이 나왔다. 사전 도출
  → Build 는 배선돼 있었는데 루프 안의 재도출만 끊겨 있었다.
- **`knowledge/*.md` 는 아무도 쓰지 않는 읽기 전용이었다.** "새 정지점 = 테이블 한 줄"
  이라고 선언해놓고 그 줄을 쓸 주체를 정하지 않았다.
- 이제 static-analyzer 가 **펌웨어당 하나의 기록**(`STATIC.md`)의 `## 도출된 정지점`
  표에 append 하고, 분류기와 fixer 가 그 표를 받는다. fixer 는 그 줄의 "시도할 변경"
  을 적용하고 기존대로 `check_change` → `ninja` 로 이어진다.
- **`new_facts_count` 를 스크립트 측정으로 교체** (`scripts/derived_facts.py`).
  시그니처로 dedup 하므로 같은 `0x620` 을 다시 도출하면 0 이고, 그때 `analyst_dry`
  가 **사실로** 성립해 `EXHAUSTED` 가 정상 작동한다. 자기신고는 반증이 불가능해
  정지의 입력값이 될 수 없다.
- **`unknown` 이어도 fixer 를 부른다.** 도출표가 담당을 지목하면 그리로 넘긴다.
  그리고 아무 fixer 도 안 부른 회차를 `fixer_no_new_change=true`(전원 포기)로 기록하던
  거짓 기록을 없앴다 — 그 값은 소진 조건의 입력이라 무브 소진을 거짓으로 성립시켰다.

에이전트를 동적으로 늘리는 방식은 택하지 않았다. 에이전트 레지스트리는 세션 시작
시점 스냅샷이라 회차 중 만든 파일은 로드되지 않고, 근거 없이 만든 fixer 는 §1 위반이며,
"언제든 새 fixer 를 만들 수 있다" 는 `fixer_no_new_change` 를 영원히 거짓으로 만들어
방금 고친 버그를 그대로 재현한다. 자라는 것은 에이전트가 아니라 **검증 가능한 지식**이다.

스모크 테스트 7건 추가 — 총 70건 통과.

---

## 0.11.0 — 2026-07-22

**Windows 세션 지원 — 실행만 WSL 로 건너간다 (`wsl_bridge.sh`).**

세션을 WSL 안에서 띄우면 예전부터 그대로 돌았지만, Windows 의 VS Code 에서 띄우면 Bash
도구가 Git Bash 라 Linux QEMU 가 돌지 않았다. 이제 **어느 쪽에서 띄워도 된다.**

- `scripts/wsl_bridge.sh` 신설 — 모든 `scripts/*.sh` 가 첫 줄에서 source 하고, 셸이
  Windows 면 `wsl.exe -e` 로 자기 자신을 다시 실행한다. 호출부(`pipeline.js`·스킬·에이전트)는
  한 글자도 바뀌지 않는다.
- `-e` 를 쓰는 이유는 argv 를 그대로 넘겨 **인용 계층이 늘지 않기** 때문이다. `-lc "…"` 였다면
  `shq()` 로 이미 인용된 문자열을 두 번째 셸이 다시 펼쳤을 것이다.
- 경로는 `C:\…` · `C:/…` · `/c/…` → `/mnt/c/…` 로 바꾸되 플래그·`key=value` 는 건드리지
  않고, 인자 경계를 보존해 **공백 있는 경로도 한 인자로 남는다.**
- `scripts/py.sh` 신설 — Windows 셸엔 `python3` 이 없어 가드가 실행될 기회조차 없으므로,
  파이썬 7종은 이 셸 진입점을 거친다. `pipeline.js` 의 직접 호출 14곳을 여기로 돌렸다.
- `pipeline.js` 가 경로의 백슬래시를 슬래시로 정규화한다 (bash 에서 `\U` 는 이스케이프다).
- `check_env.sh` 는 유일하게 브리지를 *인지*하는 스크립트다. Windows 인데 `wsl.exe` 가
  없으면 그 사실을 JSON 으로 보고하고, 있으면 건너가서 Linux 툴체인을 점검한다.

파일 배치는 두 경우 모두 같다 — **폴더·문서는 Windows, 빌드·실행·트레이스는 WSL.**

브리지 스모크 테스트 11건 추가 (경로 변환 6, 가짜 Git Bash + 가짜 `wsl.exe` end-to-end 5).
총 63건 통과. 다만 **실제 Windows 검증은 아직**이다 — 위장 셸까지가 한계다.

---

## 0.10.4 — 2026-07-22

**실행 환경 선행 검사 — 못 도는 셸에서 회차를 태우지 않는다 (`BLOCKED_ENV`).**

네이티브 Windows 에서 실행하면 에이전트의 Bash 도구가 **Git Bash** 라서 `/mnt/c` 가
보이지 않고 Linux QEMU 도 돌지 않는다. 그런데 파이프라인은 이걸 평범한 정지점으로
취급해, 같은 이유로 매 회차 실패하면서 **런타임 한계(120회)까지 헛돌았다.**

실행 자체가 불가능한 셸은 목표 판정의 문제가 아니라 **선행 조건의 문제**다.

- `scripts/check_env.sh` 신설 — 셸 종류(`uname -s` 가 `MINGW*`/`MSYS*`/`CYGWIN*` 인지),
  워크스페이스 가시성, QEMU·python3·ninja·capstone(트랙 2 는 dtc)까지 한 번에 점검하고
  JSON 으로 낸다.
- `workflows/pipeline.js` 가 **Analyze 맨 앞**에서 호출한다. 실패하면 `record.py blocker`
  로 `BLOCKED_ENV` 를 사실로 남기고 **루프에 들어가기 전에** 정지한다.
- 보고 문구는 원인과 해결을 같이 준다 — "WSL 터미널에서 claude 를 실행하세요".
  Claude Code 공식 문서도 Linux 툴체인을 쓸 때는 WSL 안에서 설치·실행하도록 안내한다.
- **이것은 도달 불가 판정이 아니다.** 환경만 갖추면 같은 워크스페이스·`INPUT.md` 로
  그대로 재개된다.

스모크 테스트 5건 추가 (Git Bash 위장 셸, 안 보이는 워크스페이스) — 총 57건 통과.

---

## 0.10.3 — 2026-07-22

**`rehost-sboot` 별칭 제거 — 트랙 1 명령을 `rehost-bootloader` 하나로 통합.**

0.10.0 에서 개명하며 하위 호환용 별칭을 남겼는데, 같은 일을 하는 명령이 두 개 보이면
어느 것이 정본인지 모호하다. 통합이 목적이었으므로 별칭을 지운다.

- `skills/rehost-sboot/` 삭제 → 트랙 1 명령은 **`/sboot-rehost:rehost-bootloader`** 하나
- `scripts/setup_env.sh` 의 완료 안내, `examples/` README, `CLAUDE.md` 의 별칭 문구 정리

**이전에 `rehost-sboot` 을 쓰던 분은 `rehost-bootloader` 로 바꿔 부르면 됩니다.**
동작은 완전히 같습니다 (`pipeline.js` 를 `track: 1` 로 호출).

## 0.10.2 — 2026-07-22

전체 플로우 재검토에서 **표면·등급이 끝까지 이어지지 않는 지점 4곳**을 찾아 고쳤다.

- **`milestone_tokens.txt` 에 생산자가 없었다.** `run_qemu.sh` 가 읽기만 하고 아무도
  만들지 않아, 등급 B·C 를 목표로 잡아도 관측이 불가능했다. static-analyzer 체크리스트에
  작성 절차를 추가 (도출한 문자열만 쓸 것 — 머신에도 있으면 자가주입으로 처리된다).
- **표면 정정이 자율 계약을 어겼다.** static-analyzer 가 표면을 정정하면 파이프라인이
  "INPUT.md 를 고치고 재실행하라" 며 멈췄다. 표면 정정은 **도출된 사실**이지 구조적
  불가가 아니므로, 이제 사다리를 바꿔 그대로 계속하고 JOURNAL 에 결정만 남긴다.
  (사다리를 `goalsFor(surface)` 함수로 바꿔 실행 중 재계산 가능하게 했다.)
- **fault-classifier 가 신규 마일스톤을 몰랐다** — `fastboot`·`commands`·`autoboot` 이
  목록에 없어 도달을 보고할 수 없었다.
- **워크스페이스 폴더 이름 불일치** — setup 은 `03_bootloader` 를 만드는데 CLAUDE.md 는
  `03_bl3` 로 적혀 있었다.

### 문서
- `docs/components.md` 에 **"트랙 1 의 목표 — 부트로더의 인터랙티브 표면"** 절 신설.
  트랙 2 목표 절만 있고 트랙 1 은 없어, 표면·등급이 컴포넌트 문서에 0건이었다.
  LK 사례(명령 테이블은 실재하나 도달 불가)와 표면별 검증 항목 4 차이를 포함.
- 벤더 종속 표현 정리 (`BL3 가 carve` → `부트로더 이미지가 carve`).

## 0.10.1 — 2026-07-22

**등급을 실제 목표로 만들었다.** 다른 펌웨어를 세팅할 때 도달 수준을 고를 수 있어야
하는데, 트랙 1 의 A/B/C 가 정의도 없고 사다리에 반영되지도 않고 있었다.

### 유실됐던 등급 정의 복원 + 표면별 일반화
0.9.0 재작성 때 구 CLAUDE.md 의 `A=help / B=명령 핸들러 / C=autoboot` 정의가 사라져,
문서가 "A/B/C" 라고만 쓰고 뜻을 말하지 않고 있었다. 복원하면서 표면에 맞춰 일반화:

| 등급 | 뜻 | `shell` (S-Boot) | `fastboot` (LK) |
|---|---|---|---|
| **A** | 표면 도달 + 목록 명령 실행 | 프롬프트 + `help` | `getvar:` 수신·dispatch |
| **B** | 다른 명령 핸들러가 실제로 동작 | `reset`·`printenv` | `flash`·`reboot` |
| **C** | 부트로더가 정상 부팅 흐름 진행 | autoboot | 부트모드 결정 → 커널 로드 |

### 등급이 사다리를 결정한다
`LADDERS[1]` 이 등급과 무관하게 `[표면]` 하나였다 — A·B·C 를 골라도 같은 목표였다.
이제 `A: [표면]` · `B: [표면, commands]` · `C: [표면, commands, autoboot]`.

- `milestone_tokens.txt` 가 `<마일스톤>\t<토큰>` 형식을 지원한다. static-analyzer 가
  도출한 문자열을 쓰므로 **벤더 배너를 코드에 박지 않고도** B/C 단을 관측한다.
- 파일이 없으면 표면 기본 토큰만 쓰이므로 등급 A 만 관측 가능하다는 점을 명시.
- setup 의 등급 질문이 **판별한 표면에 맞춰 설명을 바꿔** 제시한다.

### 회귀
52 케이스 (등급 사다리 2 케이스 추가).

## 0.10.0 — 2026-07-22

**벤더 중립화.** MediaTek(SM-A136U / MT6833) 실제 산출물과 대조해, 트랙 1 이 Samsung
S-Boot 한 종류를 전제하고 있던 것을 부트로더 **단계** 전반으로 넓혔다.

### 명령 개명 — `rehost-sboot` → `rehost-bootloader`
`S-Boot` 은 삼성 Exynos 의 부트로더 **구현체 이름**이라 MediaTek LK·Qualcomm aboot 에
쓰면 틀린 이름이었다. 명령을 가르는 축은 **부팅 체인의 진입점**이지 벤더가 아니므로,
명령은 2개(부트로더 / 커널)를 유지하고 이름만 단계 이름으로 바꿨다.
`rehost-sboot` 은 별칭으로 남겼다 (→ **0.10.3 에서 제거**, 아래 참조).

### 목표를 "인터랙티브 표면" 으로 일반화
부트로더마다 사용자 명령을 받는 경로가 다르다. 목표는 셸이 아니라 **그 부트로더에서
실제로 도달 가능한 표면**이다.

| 표면 | 도달 증거 | 대표 |
|---|---|---|
| `shell` | 프롬프트 + `help` 출력 | Samsung S-Boot |
| `fastboot` | `getvar:` 수신·에코·dispatch | MediaTek LK |

- `bl_surface` 인자로 사다리·검증이 결정된다. setup 은 힌트만 주고 **static-analyzer 가
  사실로 확정**한다 (UART 수신 경로 유무, USB dispatcher 가 명령 테이블을 참조하는가).
- 검증 항목 4 가 표면별로 달라진다 — `shell` 은 **UART 단일 경로**, `fastboot` 은
  **입력이 외부에서 옴**(머신이 명령을 지어내면 순환검증).
- 새 하드 블로커 **`BLOCKED_NO_INPUT_PATH`** — 어느 표면에도 입력 경로가 없을 때.
  실제 LK 사례가 이걸 증명했다: 12명령 콘솔이 바이너리에 실재하지만 UART 는 출력
  전용이고 어떤 USB 리더도 그 테이블을 참조하지 않아 인터랙티브 도달이 구조적으로
  불가능했다(트램폴린으로 출력을 강제하는 건 FORCED).

### MediaTek 을 막고 있던 결함 (실제 lk.bin 으로 확인)
- **`carve_check` 가 S-Boot 잣대(4 MB + Exynos 문자열)를 모든 이미지에 적용**해,
  1.5 MB LK 를 carve 로 오판하고 `BLOCKED_CARVE` 로 **첫 단계에서 거부**했다.
  아키텍처별 기준(arm32: 512 KB + LK 문자열)으로 교정.
- **`find_xref_to` 가 8 바이트 포인터만 스캔** — AArch32 는 4 바이트라 명령 테이블을
  못 찾고 "없음" 으로 오판했다.
- `carve_disasm.py --arch arm64|arm32` 신설 (Thumb 디스어셈블, AArch32 진입 패턴 점수).
- `soc_family` · `arch` · `bootloader_path`(구 `bl3_path` 도 인식) 슬롯 도입.
- setup 이 파일·매직·문자열로 **SoC 계열과 부트로더를 사실로 판별**한다.

### MediaTek 트랙 2 지식 (코드 변경 없이 이득)
- **`cpu_cluster_mpidr`** — DTB `cpu reg` 와 QEMU cores-per-cluster 불일치로
  `psci cpu_on -22` → `cpuhp` 가 `cpu_hotplug_lock` 점유 → init 영구 블록.
  **에러 메시지 없이 부팅이 멈추는** 유형. MTK K1 의 실제 근본원인이었다.
- **`irq_edge_level`** — HCI 인터럽트는 level-triggered 여야 한다 (edge 면 UIC -110).
- **`is_bit_layout`** — IS 비트 위치 (UPMS 는 bit 4, bit 8 로 오해하기 쉬움).
- **`query_upiu_overwrite`** — 응답 UPIU 는 헤더+페이로드를 **1회** 로 써야 한다.
- **`sparse_super_gpt`** — Android sparse super 는 GPT 디스크가 아니다. LUN 합성 필요.
- 프로필 `mediatek.yaml` 확장 (LK 구조·엔트리 16 B·포인터 4 B·`-icount`·`initcall_debug`).

### 남은 격차 (정직 기록)
- **AArch32 머신 템플릿이 없다.** 트랙 1 MediaTek 은 Build 단계에서 AArch64 템플릿을
  쓰지 않고 **정직하게 실패를 보고**하도록 했다 — 잘못된 머신을 조용히 만드는 것보다
  낫기 때문이다. USB 컨트롤러 모델도 아직 없다.
- 트랙 2 MediaTek 은 지식·프로필이 준비됐으나, sparse super → GPT LUN 합성 도구는
  아직 없다.

### 회귀
하니스 45 → **50 케이스** (MediaTek 5 케이스 추가: carve 아키텍처 기준, fastboot 표면
마일스톤, 외부 입력 검증).

## 0.9.2 — 2026-07-22

실제 리호스팅 산출물(SM-G977N / Exynos 9820)과 대조해 **한 펌웨어 형상에 과적합된
전제**를 걷어내고, 트랙 2 의 목표를 문서·코드에 제대로 반영했다.

### 트랙 2 의 목표를 명시 — K3 = 진짜 UFS 컨트롤러 구현
- `docs/components.md` 에 **"트랙 2 의 목표 — 진짜 UFS 컨트롤러 구현"** 절 신설.
  목표는 rootfs 마운트가 아니라 컨트롤러를 구동시키는 것이고 마일스톤은 그 완성도의
  눈금이라는 점, "드라이버를 계측기로 쓴다" 는 핵심 발상, 어느 컴포넌트가 무엇을
  맡는지를 정리. 기존에는 `fixer-storage` 항목 하나로 격하돼 있었다.
- K3a(`partitions_up`, 최소 완료) / K3b(`super_mounted`, 캡스톤) 단계를
  `verify.py` · `knowledge` · `fixer-storage` · `CLAUDE.md` · 스킬에 일관 반영.

### 잘못된 REAL 을 막는 수정
- **`verify.py` K3 항목 2 가 3개 패턴의 OR 판정이라, `power_mode` 같은 중간
  마일스톤 하나만 있어도 통과했다.** 방법론이 "컨트롤러 미완성" 이라 규정한 상태에
  REAL 을 주던 홀 — `partitions_up` 필수로 교정하고 도달 단계를 `ufs_controller`
  필드로 보고.

### 오탐으로 REAL 을 깎던 수정
- **항목 3(소스 negative)** 이 주석과 `#include` 까지 검사해 정상 산출물을 누출로
  판정했다. 주석·include 를 제거하고 **문자열 리터럴만** 검사하도록 수정.
- **우회 4항목 검출**이 리터럴 `대상:` 만 찾아, `**대상**:` · `알려진 부작용` 같은
  실제 표기를 0건으로 읽었다. 마크다운 강조·표기 변형을 허용 (`verify.py`,
  `check_change.sh`).
- 두 오탐 탓에 실제 5/5 REAL 인 산출물이 3/5 FORCED 로 측정됐다.

### 형상 다양성 — 한 기기 형태를 보편으로 박지 않는다
- **`BLOCKED_KO` 정교화**: `.ko` 부재만으로 블로커를 내면 **도달 가능한 실행을
  거부**한다. 커널이 UFS 를 빌트인(`=y`)으로 컴파일하면 `.ko` 는 설계상 없고 진짜
  벤더 드라이버는 커널 안에 있다(**K3\***). 이제 `.ko` 부재 **그리고** 커널 이미지에도
  드라이버가 없을 때만 블로커이며, static-analyzer 가 사실로 도출한다.
- **rootfs 마일스톤**이 EROFS 전제였다. ext4(`EXT4-fs … mounted` /
  `VFS: Mounted root (ext4 …)`)와 `UFS link established` 변형을 수용.
- **캡스톤은 토폴로지가 정한다**: `super.img` 가 없는 분리형 system/vendor 펌웨어는
  `super_mounted` 를 구조적으로 찍을 수 없다. `has_super` 인자로 사다리에서 제외해
  존재할 수 없는 목표를 요구하지 않는다.
- `run_kernel.sh` 가 **0 바이트 initramfs**(system-as-root)를 `-f` 로 통과시켜 QEMU 에
  넘기던 문제 → `-s`.

### 지식 보강
- 새 정지점 **`prdt_stride`** 추가 — 벤더 확장 sg 엔트리(Samsung Exynos FMP 인라인
  암호: 16 B + 112 B = **128 B stride**)를 16 B 로 오독하면 read 는 `got == bytes` 로
  "성공" 하는데 멀티페이지 배치가 어긋나 유저스페이스가 엉뚱한 바이트를 실행한다.
- **"완전성은 정확성이 아니다"** 교훈 추가 — `got == bytes` 계측은 scatter 배치
  오류를 놓친다.
- 회귀 하니스에 형상 다양성 7 케이스 추가 (총 45).

## 0.9.1 — 2026-07-21

문서 보강. 기능 변경 없음.

- `docs/components.md` 신설 — 아키텍처의 각 컴포넌트를 실행 순서대로
  (Analysis → Build → Run → Manage → Diagnosis → Fix → Verify → Package) 정리.
  컴포넌트마다 역할 · 정체 · 입력/출력 · 동작 과정 · 규칙을 항목화.
- `README.md` 을 진입점으로 재작성하고 **업데이트 절** 신설 —
  CLI · VS Code 확장 각각의 절차, 자동 업데이트가 서드파티 마켓플레이스에서
  기본 비활성이라는 점, 업데이트가 안 될 때의 조치.

## 0.9.0 — 2026-07-21

**아키텍처 전면 재설계.** 측정은 스크립트, 해석·제어는 LLM, 정지의 입력값은 사실.

### 에이전트 재편 (8 → LLM 5 역할)
- `static-analyzer` — `bl3-analyzer` + `stub-locator` + `kernel-boot-analyzer` +
  `storage-modeler`(`.ko` 역어셈블) 병합. 사전 도출 + 에스컬레이션 2 모드
- `supervisor` 신설 — 회차 라우팅·정지
- `fault-classifier` 신설 — 분류를 수리에서 분리. `unknown` 이 정상 답
- `fixer-memory` / `el3` / `bootflow` / `kernel` / `storage` — 담당 오류 + 도구로 분화.
  LLM 중 유일하게 쓰기 권한
- `verifier` — 검증 5/5 의 2 차 재검증
- `critic` 삭제 — 정지 조건으로 흡수

### 결정론 계층 신설
- `run_round.sh` — 한 회차를 통째로 수행하고 관측 문서 하나(`observation.json`)를 냄
- `check_change.sh` — diff 로 "회차 = 한 변경" 강제, 우회 4항목 검문
- `stop_conditions.py` — 정지 조건 계산 (구조상 도달 불가만)
- `verify.py` — 검증 5/5 측정
- `record.py` — 시간·토큰 등 측정치를 `metrics.jsonl` · `rounds.jsonl` ·
  `blockers.jsonl` 로 실시간 기록
- `run_qemu.sh` / `run_kernel.sh` — 지문 추출 + **출처 게이트를 매 회차 집행**

### 파이프라인 통합
- `pipeline.js` + `pipeline_kernel.js` + `iter-loop.js` → **`pipeline.js` 하나**
  (`track` 인자 + 목표 사다리)
- 목표 전진을 **관측으로만** 판정 (supervisor 의 주장으로는 사다리가 움직이지 않음)

### 정지 정책 변경
- **회차 수·소요 시간은 더 이상 정지 사유가 아니다.** `max_iterations` 상한 제거
- 정지는 구조상 도달 불가만 — `BLOCKED_*` 5종 + `EXHAUSTED`(무브 소진)
- 사실로 측정된 정지를 LLM 이 우회하려 하면 파이프라인이 **강제 정지**

### 검증 2단화
- 스크립트가 5/5 를 측정하고, LLM 이 재검증
- **방향 비대칭** — 낮추기(REAL→FORCED)는 자유, 올리기는 byte-level 증거 필요

### 지식 / 프로세스 분리
- `fixers/registry.yaml` — 오류 이름 → 담당 fixer
- `knowledge/faults_bootloader.md` · `faults_kernel.md` · `faults_storage.md` ·
  `kernel_gates.md` — 정지점 테이블
- `profiles/generic.yaml` · `exynos.yaml` · `mediatek.yaml` — SoC 탐색 힌트(값 아님)
- 새 정지점 = 테이블 한 줄, 새 fixer = 파일 하나 + 등록부 몇 줄

### 수정한 결함 (전부 재현으로 확정)
- `grep -c` 가 0 매치일 때 `fingerprint.json` 이 깨지던 문제
- `verify.py` 항목 1 이 영구 FAIL 이라 REAL 도달이 불가능하던 문제
  (PC 를 `STATIC.md` 에서 자동 도출하도록 수정)
- 목표 초과 도달 시 사다리가 전진하지 않던 문제
- 사다리가 건너뛴 단 때문에 하위 도달이 가려지던 문제
- 에이전트 자유 텍스트를 통한 **쉘 인젝션** (단일따옴표 이스케이프로 차단)
- 에스컬레이션 임계값이 소진 임계값과 같아 도출이 한 번도 불리지 못하던 문제
- 회차 이중 기록으로 정체를 오탐하던 문제
- 콘솔이 오염돼도 다른 토큰으로 도달을 인정하던 출처 게이트 허점
- `record.py` 가 16진 주소를 정수로 바꿔 지문 비교가 깨지던 문제

### 기타
- `tests/smoke.sh` 신설 — 가짜 QEMU 로 결정론 계층을 검증하는 회귀 하니스 (38 케이스)
- 에이전트 프롬프트를 영어로, 사용자가 읽는 산출물은 한국어로 분리
- 우회 기록 파일명을 `bypasses.md` 로 (기존 워크스페이스의 옛 이름도 계속 인식)

---

## 이전 버전

| 버전 | 내용 |
|---|---|
| 0.8.1 | 슬래시 명령 네임스페이스화 (`/sboot-rehost:rehost-*`) + `disable-model-invocation` |
| 0.8.0 | `/rehost-init` 재도입 (폴더 스캐폴딩), 작업·예제 폴더 전부 gitignore |
| 0.7.0 | `/rehost-export` — 펌웨어·트랙별 "빌드 없이 실행" 키트 |
| 0.6.1 | `/rehost-setup` 이 이름만 받고, 트랙은 마지막에 프롬프트 |
| 0.6.0 | init→setup 통합, 펌웨어별 격리 워크스페이스, `_inbox` 자동 생성 |
| 0.5.0 | init/setup 분리, Windows cwd 문서 + WSL 대용량 쓰기, 자율 실행 |
| 0.4.0 | 두 트랙 분리, 실행 명령 분리, JOURNAL 기록, 자율 실행 |
| 0.2.0 | `/rehost-init` + `/rehost` 분리, 병렬 멀티에이전트용 `pipeline.js` |
