# 구성 요소

파일 하나가 무엇을 맡고, 무엇을 강제하는지의 목록이다.
운영 규칙의 정본은 [CLAUDE.md](../CLAUDE.md), 개념 설명은 [온보딩 문서](onboarding/README.md) 다.

> 원칙: **측정은 스크립트가, 해석과 제어는 에이전트가, 정지 판정의 입력값은 관측 사실이 맡는다.**

---

## 1. 흐름 제어

### `workflows/pipeline.js`

- 전체 흐름을 배선한다
- 에이전트가 관측에 근거한 정지를 뒤집지 못하도록 강제하는 것이 핵심 역할이다

```mermaid
flowchart LR
  A["버전 확인"] --> B["환경 확인"] --> C["아키텍처 확정"] --> D["커널 자산 적재"] --> E["도출"] --> F["빌드"]
  F --> G["회차 루프: 실행 · 분류 · 수정 (반복)"] --> H["검증"] --> I["재현 키트"]
```

단계별 호출 순서는 [설계 근거 3.2](design-rationale.md#32-흐름)의 시퀀스 다이어그램에 있다.

| 강제하는 것 | 방법 |
|---|---|
| 최신 버전으로만 실행 | `check_version.sh` 를 첫 게이트로 |
| 실행 가능한 환경에서만 회차 소모 | `check_env.sh` 선행 |
| 목표 단계는 도출값 | `stage_map.json` 의 실행 가능 스테이지로 구성 |
| 정지 판정 우선 | `stop=true` 인데 계속 지시가 오면 강제 정지 + 모순 기록 |
| 정지는 인계 | 정지 직후 `make_resume.py` 호출 |
| 지시 맥락 보존 | 시작 시 사용자 입력 원문 기록 |
| 계열 자료 전달 | `family_kit.py` 로 읽어 위임 프롬프트에 `Family knowledge:` · `Runbook:` 주입 |
| 계열 간 오염 방지 | Build 시작에서 `qemu_tree.sh reset` |
| 계열 기본값은 계열이 주어졌을 때만 | `build_lu.py` · `carve_disasm.py` 에 항상 `--family`(프로필의 계열을 `exynos` · `mediatek` · `generic` 으로 좁힌 값)를 넘긴다. carve 판정은 `false` 일 때만 `BLOCKED_CARVE` 이고 `null` 은 "carve undetermined" 로 기록하고 계속한다 |
| 스토리지 골격은 UFS 일 때만 | `templates/storage_hci.c.tmpl` 은 매체가 UFS 이거나, 미정이면서 계열이 exynos 일 때만 에이전트에게 준다 (골격이고 값은 도출한다고 적는다) |
| 아키텍처는 도출값 | `start` 가 넘긴 `arch`(`arm32` · `arm64`)는 그대로 따르고, `unknown` 이면 `stage_map.py --detect-arch` 로 다시 도출한다. 그래도 `unknown` 이면 임시 arm64 로 지도를 도출해 시그니처가 없을 때 근거와 함께 `BLOCKED_ARCH` |
| 커널 자산은 사람이 꺼내지 않는다 | F2 이상에서 `02_unpacked/boot.img` 가 있으면 Analyze 앞에서 `extract_boot_assets.sh` 를 부르고 `fw/` 의 실제 내용으로 판정한다 |
| 재개 때 기록을 덮지 않는다 | 그 워크스페이스의 마지막 회차 번호 다음부터 번호를 매긴다 (`runtime_round_cap` 은 이번 실행의 회차만 센다) |
| 구조상 불가능한 것만 정지 | `BLOCKED_KO` 는 F2 이상에서 분석가가 `storage_driver.form=absent` 로 보고할 때 세운다 |

계열 자료 전달과 `qemu_tree.sh reset` 의 배선은 합성 에이전트와 실제 스크립트로만 시험했다. 배선 현황과 열린 항목은 가장 최근 `CHANGELOG.md` 항목이 정본이다. 분석가가 보고한 `has_super` 는 파이프라인이 되읽지 않는다 (`start` 가 넘긴 값이 사다리를 정한다).

---

### 환경 준비

| 파일 | 역할 |
|---|---|
| `env_manifest.json` | **요구 환경.** `env_revision` · QEMU 버전 · pip 최소 버전 · 필수 도구. 환경 요구가 바뀔 때만 개정 번호를 올린다 |
| `setup_env.sh` | 의존성 설치와 **패치 없는 기준(pristine)** QEMU 10.2.2 빌드. 약 18분이 걸리므로 `init` 이 배경으로 실행한다. 만든 트리에 표지를 남기고 `~/.sboot/env.json`(현재 환경)을 쓴다. apt 가 실제로 필요한데 root 가 아니고 `sudo -n true` 가 실패하면 설치·삭제 전에 종료코드 7(`BLOCKED_ENV`)로 멈추고 실행할 `apt-get` 줄을 낸다 |
| `clean_env.sh` | `init` 의 층별 정리(L1 플러그인 · L2 도구 체인 · L3 임시 · L4 워크스페이스). 표지가 있는 것만 지우고, 지운 것의 경로·크기를 JSON 으로 보고한다. `--status` 는 매니페스트 비교만 한다 |
| `qemu_tree.sh` | QEMU 트리를 pristine 으로 되돌린다 (`reset` · `status` · `record`). 건드린 파일을 `$QEMU_SRC/.sboot_touched` 에 적은 장부(`M` 수정 · `A` 추가)로 원본 tarball 에서 복원한다 |
| `extract_boot_assets.sh` | `02_unpacked/boot.img`(와 super · DTB)에서 부팅 자산을 `fw/` 로 꺼낸다. **파이프라인이 F2 이상에서 Analyze 앞에 부른다.** 비대화형 · 멱등이고 종료코드는 0 적재 · 1 인자 부족 · 2 입력 없음 · 3 boot.img 해석 실패 · 4 super 만 실패. 마지막 줄은 `assets: image= dtb= initrd= super=` |
| `wsl_bridge.sh` | 셸이 Windows 면 WSL 로 전환한다 |
| `py.sh` | 파이썬 스크립트를 일관된 인터프리터로 실행한다 |

---

## 2. 에이전트 (`agents/`)

| 이름 | 역할 | 소스 수정 |
|---|---|---|
| `static-analyzer` | 바이너리·자산에서 사실 도출. 근거 없으면 "미확정" | 불가 |
| `supervisor` | 라우팅·정지·계층 판정·우회 철회 | 불가 |
| `fault-classifier` | 정지점 이름과 담당 지정. 모르면 `unknown` | 불가 |
| `fixer-memory` | 메모리 맵과 주변장치 창 | 가능 |
| `fixer-el3` | EL3·SMC·PSCI·FP 트랩 | 가능 |
| `fixer-bootflow` | 체인 제어 흐름, 핸드오프 슬롯, 콘솔 경로 | 가능 |
| `fixer-secureboot` | 부트로더 자체 서명 검증 (AVB·롤백 인덱스·키 저장소). 해시가 하드웨어 엔진이면 엔진 모델링 → 라벨 달린 우회 → 정지 순 | 가능 |
| `fixer-storage` | 스토리지 컨트롤러 모델, UPIU, 매체 구성 | 가능 |
| `fixer-kernel` | 커널 `.text` 패치, GIC 배선, rootfs 경로 | 가능 |
| `fixer-general` | 담당이 없을 때만. 범위 무제한: 하나의 일관된 메커니즘이 여러 곳 · 여러 파일에 걸쳐도 한 회차에 처리한다 | 가능 |
| `verifier` | 스크립트 측정을 2차 재검증 | 불가 |

**수정 권한은 fixer 에게만 있다.** 분류하는 쪽과 고치는 쪽이 같으면 고칠 대상을 만들기 위해
없는 원인을 지목하게 된다.

- `fixer-general` 은 전문가가 전부 반려했을 때만 도달하며 순위로는 선택되지 않는다. 그 변경도
  `check_change.sh` 를 통과해야 센다 (위반이면 되돌리고 `reverted` 로 기록). **범위는 다르다:** 모든 정지점에
  담당 fixer 가 있지 않으므로 하나의 일관된 메커니즘이 여러 곳 · 여러 파일에 걸쳐도 한 건이다. 파이프라인이
  `fixer-general` 에게만 `CHANGE_SCOPE=general` 을 주고, 그 범위에서 `check_change.sh` 는 소스 파일 하나 검사와
  `MAX_HUNKS` 검사만 건너뛴다. 변경 없음 · 우회 기록 4항목 · 쓸 수 있는 기록 · 패치 표 행 대응 · `hash_engine`
  행은 전문가와 똑같이 묶는다
- 모든 fixer 가 공유하는 규칙은 `workflows/pipeline.js` 의 상수 `FIXER_RULES` 하나에 있고 모든 fixer 프롬프트(전문가와
  `fixer-general`)에 붙는다. `agents/fixer-*.md` 는 그 fixer 만의 것을 담는다. fixer 의 JSON 에는 `escalate` ·
  `suspect_prior_bypass` · `bypass_doc` · `category` 가 없고, 열린 질문은 `no_new_change=true` 와 `rationale` 로 답한다
  (반려한 fixer 의 `rationale` 은 다음 static-analyzer 에스컬레이션의 초점으로 간다)
- 범위가 무제한이라 "시도할 것이 없다"는 답이 잘 나오지 않으므로, **지문을 움직이지
  못한 변경은 시도로 세지 않는다**

---

## 3. 도출

| 스크립트 | 역할 |
|---|---|
| `stage_map.py` | 스테이지 지도 도출 → `stage_map.json` (스키마 v2). 이미지마다 한 번 돌리고 `--merge` 로 사슬 순서에 합친다. `--detect-arch <경로>` 는 이미지 하나의 아키텍처를 한 줄 JSON(`arch` · `entry_signature` · `basis` · `confidence`)으로 낸다 (`unknown` 이 정직한 답이고 종료코드 2 는 읽지 못함 · 64 는 호출 오류) |
| `carve_disasm.py` | capstone 래퍼 (디스어셈블·교차참조·엔트리 점수). `--arch arm32` 는 ARM 모드 진입 점수도 낸다. `carve_check` 는 문자열 기준에 더해 컨테이너 헤더가 선언한 크기도 본다. 문자열 · 크기 기준은 `--family` 가 고른다 (exynos · mediatek 만 기준이 있다). 기준이 없는 계열이고 헤더 근거도 없으면 `is_full: null` 과 `is_full_note` 이고 `false` 가 아니다. `--family` 를 생략하면 예전의 ISA 별 기준 |
| `detect_medium.py` | 부팅 매체 종류(eMMC · UFS) 판정. 부트로더 로그의 초기화 줄 → DTB 노드 순이고, 못 정하면 `unknown` |
| `family_kit.py` | 프로필의 `knowledge:` · `runbook:` 을 읽어 계열 자료 목록을 JSON 으로 낸다. PyYAML 없이 정규식으로 읽는다 |
| `derived_facts.py` | 도출표에 늘어난 줄 수 측정 (자기 신고 방지) |
| `static_rotate.py` | 도출 기록이 커지면 근거는 보관하고 표는 유지. 오래된 재도출 하위 절의 정지점 행은 본문 표로 올리고, 검증이 읽는 `hash_engine` 행과 주소 창 표(담당 열이 없어 정지점 행이 아니다)도 그대로 옮겨 회전 전후에 `verify_gates.py` 가 읽는 것이 같게 한다 (같은 파서로 읽고 파일 순서를 지킨다). 시험은 `canon` 8b (C16) |

### `stage_map.py` 의 4단계

| # | 단계 | 방법 |
|---|---|---|
| 1 | 구간 분류 | 엔트로피 격자 (평문 / 암호화 / 제로). **경계에서 스테이지를 쪼갠다** |
| 2 | 스테이지 경계 | 아키텍처별 리셋 스텁 시그니처 |
| 3 | 구간 식별 | 문자열 문맥 (`profiles/*.yaml` 의 힌트) |
| 4 | 적재 주소 | basefind + **리터럴 앵커 교차 검증** |

- **4단계 교차 검증은 생략 불가.** 포인터 포함률만으로 고른 후보는 실측에서 틀렸다
- BSS 포인터를 파일 오프셋으로 환산해 **제로 패딩 시작 지점에 착지**해야 확정값이다
- 앵커가 없으면 `candidate` 로 표기하고 확정값으로 쓰지 않는다
- 진입 시그니처(AArch64 리셋 스텁, arm32 의 GFH 진입 · 페이로드 선두 벡터 테이블 · crt0)를
  못 찾으면 종료코드 3. **"스테이지 없음"이 아니라 "도구가 못 찾음"** 이며 파이프라인은
  `BLOCKED_ARCH` 로 정지한다
- 시그니처는 찾았으나 로드 베이스가 독립된 앵커 둘로 수렴하지 않으면 종료코드 0 이고 그
  스테이지는 `state: unconfirmed` (실행 불가, 후보와 반려된 앵커가 사유와 함께 남는다)

---

## 4. 실행

| 스크립트 | 역할 | 강제하는 것 |
|---|---|---|
| `run_round.sh` | 회차 1회 → 관측 문서 1개 | 에이전트가 정지 판정을 조립하지 못하게 |
| `run_full.sh` | QEMU 실행 → 지문 추출 · 출력 출처 검증 · 실행 실패 판정. 메모리 덤프 계획이 있으면 `REHOST_MEMDUMP_REGION` 을 내보내고 작업 폴더의 `kernel_task_regex.txt` 를 스캔에 넘긴다. shell 표면인데 `milestone_tokens.txt` 가 없으면 내장 배너로 판정하지 않고 표면 칸을 도달로 세지 않는다 (`fingerprint.json` 의 `surface_not_credited`) | 규칙 7 (매 회차) |
| `uart_harness.py` | QEMU 외부에서 콘솔 입력 주입. 도출된 `input_plan.json`(`bytes` 와 `count` 둘 다)이 없으면 인터럽트 패턴을 보내지 않고 `source: "absent"` 로 기록한다 (기본 연타 수 없음). `--surface none` 이면 입력 없음, 입력 대기는 `waiting_for_input` 으로 보고 | 입력은 외부에서만 |
| `memdump_observe.py` | 게스트 RAM 의 커널 로그 링을 모니터 `pmemsave` 로 읽어 병합 (`memdump` 채널). 영역 도출 · 유실 검출 · 리셋 신호. `region`(계획 → `<base>:<size>`) · `task-regex`(형식 검사) 보조 명령 | 모니터는 `pmemsave` 만 |
| `trace_filter.py` | QEMU 트레이스를 스트리밍으로 걸러 필요한 부분만 남긴다 (회차당 10 GB → 수 MB). 감시 PC 는 스테이지의 `entry_pc` 이고, 명령 줄로 실행된 것과 FAR/ELR 줄에 이름만 나온 것을 따로 센다 | 트레이스가 디스크를 채우지 않게 |
| `fingerprint_lib.sh` | 최초 예외 추출 · 콘솔 고유 줄 수 | 재귀 말미가 아니라 원인을 지문으로 |
| `build_lu.py` | 부팅 매체 합성 (GPT + 파티션). 항목별 `kind`(firmware · zero · synthesized · forged · modified) · `lba` · `vendor`, `--medium emmc\|ufs`, `--family`(벤더 기본 레이아웃 이름과 `param` 커맨드라인 폴백은 `exynos` 일 때만. 생략하면 예전 동작과 `warning_family`). 결과 옆에 `lu_provenance.json`. 커맨드라인은 계획이 이름 붙인 파티션에만 쓰고(해당 없으면 `warning_cmdline`), 매체 종류의 근거가 없으면 `warning_medium` | 파티션 이름은 도출값, 우리가 만든 바이트는 검증 참조에서 제외 |

### `run_full.sh` 가 하는 일

```
① uart_harness.py 로 QEMU 실행 (종료코드 보존). memdump_plan.json 이 있으면 관측기를 함께 띄운다
② 실행 성공 판정
③ 최초 예외 블록 추출
④ 요약 로그 생성
⑤ 지문 추출 (콘솔 고유 줄 수 포함, 커널 채널이 켜져 있으면 커널 지표도)
⑥ 마일스톤 판정 (토큰의 채널별) + 출력 출처 검증
⑦ 타임아웃 프로브 (정체된 정지 상태일 때만 1회)
```

`console_N.txt` 는 게스트 UART 줄만이고, QEMU 호스트 줄은 회차가 냈으면 계획과 무관하게 `host_N.txt`, 병합한
커널 로그는 `kernel_N.log` 로 나뉜다 (`observation.json` 의 `host_log` · `kernel_log` 가 경로, 없으면 null).
호스트 줄은 게스트 증거가 아니다.

QEMU 에 **커널·DTB·initrd 를 넘기지 않는다.** 부트로더 컨테이너와 합성 매체만 붙인다.

---

## 5. 검문과 정지

| 스크립트 | 역할 |
|---|---|
| `purge_cache.sh` | 옛 버전 캐시를 지운다. `init` 의 첫 단계(L1)이며, 세션이 옛 버전을 로드 중이면 종료코드 1 로 막는다 |
| `check_version.sh` | 로드된 플러그인 버전 확인 (첫 게이트) |
| `check_env.sh` | QEMU, ninja, capstone, dtc, lz4, simg2img, WSL 확인 + **환경 매니페스트 비교** (`~/.sboot/env.json` 대 `env_manifest.json`). QEMU 를 환경변수로 직접 지정하면 비교를 건너뛰고 `skipped` 로 보고한다 |
| `check_change.sh` | 변경 1건 검문 (diff + 우회 기록 4항목) + 회차별 스냅샷. 전문가의 변경은 소스 파일 하나 · `MAX_HUNKS`(기본 3) hunk 이내여야 하고, `CHANGE_SCOPE=general`(`fixer-general` 에게만 준다)은 그 둘만 건너뛴다. 이번 회차에 새로 쓰거나 고친 기록에 대해 부작용 비움·`(기록 없음)`·메타 어휘·패치 표 행(`/* bypass:<id> */`)과 기록의 일대일 대응을 검사한다. 표지 `F` 해시·다이제스트·서명 우회(종류 `M` 제외)는 `STATIC.md` 에 `0x` 근거가 있는 `hash_engine` · `hardware` 행이 없으면 종료코드 2 로 반려한다 (누가 썼는지와 엔진 모델링 불가는 확인하지 못한다) |
| `revert_change.sh` | 반증된 우회를 해당 회차 변경만 역패치 |
| `sync_machine.sh` | 워크스페이스 소스를 QEMU 트리에 반영하고, 건드린 경로를 트리 장부(`.sboot_touched`)에 적는다. 사라진 소스는 `qemu_targets.txt` 에서 뺀다 |
| `check_release.sh` | 버전을 올리지 않은 배포를 막는다. `pre-push` 훅이 호출한다 |
| `install_git_hooks.sh` | `pre-push` 릴리스 검문을 켠다 |
| `stop_conditions.py` | 정지 조건 계산 |
| `patch_kernel.py` | 커널 패치 (사전 이미지 불일치면 적용 거부) |
| `patch_qemu_core.py` | QEMU 코어 패치 (멱등). `--family exynos`(SMC 훅 3패치, 기본) · `mediatek`(`cpu.c` 의 `aarch64=false` 거부를 KVM 에만 적용해 TCG 가 AArch32 CPU 를 만들게 함) · `all`. 건드린 파일은 트리 장부에 적는다 |

- `sync_machine.sh` 가 없으면 검문을 통과하고 빌드도 성공하는데 **이전 바이너리를 측정**하게 된다
- 회차 적용·재생성·general fixer 모두 ninja 앞에 이것을 호출한다

---

## 6. 검증

| 스크립트 | 역할 |
|---|---|
| `verify.py` | 게이트 3항 + 참고 지표 + 검증 우회 보고 측정 → `verdict_script.json` |
| `verify_gates.py` | 게이트 논리 (C 렉서, 콘솔 읽기, 참조 이미지 집합, 장부 파서, `hash_engine_state`, `address_windows_report`). 단위 시험이 가능하도록 `verify.py` 에서 분리 |
| `verify_prep.py` | 증거 준비: 압축된 커널·램디스크 해제, 큰 파일 조각화, 콘솔 정규화(삭제·치환만, 원본 보존) |
| `make_negative_image.py` | 음성 시험용 매체 사본 (vbmeta 1비트 훼손). 원본 매체는 건드리지 않는다 |

검증이 읽는 **게스트 콘솔 = UART 콘솔 + 메모리 덤프 커널 로그**이고, QEMU 호스트 줄은 걸러 낸다.
입력은 워크스페이스와 회차에 묶는다.

| # | 구분 | 항목 |
|---|---|---|
| 1 | **게이트** | 소스 negative: 실제로 빌드된 머신 소스가 낸 문자열이 게스트 콘솔에 없다 (렉서 기반, UART 송신 한 곳, stdout 쓰기 없음, pstore 영역 참조 없음) |
| 2 | **게이트** | 출력 출처: 콘솔의 고정 문자열이 펌웨어 이미지 안에 있다 (우리가 만든 파티션·매체는 참조에서 제외, 줄 형태 미발견 목록 보고) |
| 3 | **게이트** | 입력 출처: 머신이 자기 수신 버퍼를 채우지 않는다 (chardev 콜백 밖 쓰기, 자기 콜백 직접 호출, `pmemsave` 외 모니터 명령 포함) |
| 4 | 참고 | 체인 PC 트레이스: 스테이지 `entry_pc` 가 순서대로 나타남 + 커널 진입 |
| 5 | 참고 | 검증 양방향: 정상 통과 + 훼손 매체에서 실패 (`avb_negative.txt`) |
| 6 | 참고 | 스토리지 이중 구동 (`sda` · `mmcblk` 패턴) |
| 7 | 참고 | 우회 기록: 4항목 · 부작용 · 패치 표 행 대응 (표지 `F` 해시 우회가 기대는 `hash_engine` 행 포함) |
| 8 | 참고 | 주소 창 표(`STATIC.md`): 있는지 · 열이 모자라지 않는지 · 창 수 · `security_effect` 가 빈 행 수. 혼합 아키텍처 머신에만 |
| 보고 | **보고** | **검증 우회 보고** `verify_bypass {count, signals[], status, hash_engine}`. 판정 문구에 병기. `hash_engine` 은 건수를 늘리지 않는다 |

**게이트 3항을 모두 통과해야 `VERIFIED`.** 검증 우회가 있으면 `VERIFIED (출처 검증 통과) · 검증 우회 N건 ·
verify_ok: reached_bypassed` 로 쓴다. 2단계에서 verifier 가 재검증하며, 낮추는 것은 자유롭고 올리는 것은
바이트 수준 증거가 있을 때만이다. `kernel_alive` 가 `memdump` 채널이면 커널 시각과 태스크 접두가 붙은 줄이
둘 이상 있어야 인정한다.

---

## 7. 기록

| 스크립트 | 산출 |
|---|---|
| `journal.sh` | `JOURNAL.md` 에 세션, 회차, 판단, 사용자 입력, 가설, 해결 경위를 남긴다 |
| `record.py` | `metrics` · `rounds` · `blockers` · `prompts` · `resolutions` (JSONL) |
| `make_resume.py` | 정지했을 때 인계 문서인 `RESUME.md` 를 만든다 |
| `analyze_run.py` | 소요, 비용, 정체 구간, 해결 경위를 `ANALYSIS.md` 와 `analysis.json` 으로 낸다 |
| `make_export.sh` | 재현 키트. `run.sh` 가 합성 매체를 넘기고, `BUNDLE_FIRMWARE=0` 이면 펌웨어 없이 해시 기록(`SHA256SUMS`)만 둔다. `FAMILY` 로 키트 `build.sh` 의 코어 패치 세트를 정한다. `run.sh` 는 회차와 같은 조건(`-accel tcg,thread=single`(혼합 머신), 시간 한도, `-cpu` 없음, 메모리 덤프 계획이 있으면 `REHOST_MEMDUMP_REGION` 과 `kernel_task_regex.txt`)으로 돈다 |

- 시각은 반드시 실제 `date` 출력을 쓴다.
- 사용자 입력은 요약하지 않고 원문 그대로 남긴다.
- fixer 를 지정한 회차는 변경 사유가 필수이며, 없으면 그렇게 표시된다.

---

## 8. 데이터

| 파일 | 내용 |
|---|---|
| `fixers/registry.yaml` | 정지점 → 담당 fixer. `not_firmware` 와 `build_layer` 목록 포함 |
| `knowledge/faults_unified.md` | 정지점 분류표 (체인 위치별) |
| `knowledge/faults_storage.md` | 스토리지 컨트롤러 상세 (UFS, eMMC(MSDC) 절 포함) |
| `knowledge/faults_mediatek.md` | MediaTek 계열 정지점 표 |
| `knowledge/runbook_mediatek.md` | MediaTek 진행 가이드 (단계 순서 · 막힘과 다음 행동 · 금지) |
| `knowledge/kernel_gates.md` | 커널 보안 게이트 패치 지점 도출 절차 |
| `profiles/*.yaml` | SoC 탐색 힌트. **값이 아니라 어디를 볼지만 적는다.** 계열 자료를 가리키는 평면 키 `knowledge:` · `runbook:` 포함 |
| `env_manifest.json` | 요구 환경 (`env_revision` · QEMU 버전 · pip 최소 버전) |
| `templates/machine_full.c.tmpl` | 통합 머신 템플릿 (AArch64 단일 CPU) |
| `templates/machine_mixed_arch.c.tmpl` | 혼합 아키텍처(AArch32 + AArch64) 체인용 머신 골격. **구조만** 담고 칩 상수는 없다. QEMU 10.2.2 헤더에 대한 컴파일만 확인했고 실행은 없다 |
| `templates/storage_hci.c.tmpl` | Exynos UFS 컨트롤러 **골격**. 창 이름과 반환값은 예시이고 자리표시자(`HCS_READY_VALUE` 등)라 펌웨어에서 도출해 채운다. 파이프라인은 UFS 이거나 (미정이면서 exynos) 일 때만 제시한다 |
| `examples/s921n-exynos2400/` | Exynos 구조 참고 예제. 부트 체인을 연속 실행하는 지금 방식 이전의 단독 BL3 방식으로 만든 머신 소스 한 개다 (**값 차용 금지**) |
| `examples/a136u-mt6833/` | MediaTek 참조 예제 (수작업 키트의 머신 소스, **값 차용 금지**, 펌웨어 없음). `.gitignore` 의 `!examples/a136u-mt6833` 예외로 추적 대상이다 |

**새 정지점은 분류표 한 줄이다.** 계열 전용 표와 진행 가이드는 프로필의 `knowledge:` · `runbook:`
한 줄로 연결하므로 프롬프트는 고치지 않는다. 담당이 이미 있는 fixer 의 `handles` 를 늘리는 것이면
`registry.yaml` 만 고친다. **새 fixer 는 파일 하나와 등록 몇 줄이 아니다.** `workflows/pipeline.js` 의
`KNOWN_FIXERS` 와 `tests/smoke.sh` 의 해당 단언도 함께 고쳐야 한다 (하드코딩).

### `registry.yaml` 의 세 분류

| 분류 | 뜻 |
|---|---|
| `fixers` | 담당이 있는 정지점 |
| `not_firmware` | 펌웨어에 대한 사실이 아닌 것 (예: 하네스 입력 실패). fixer 를 배정하면 없는 결함을 고치게 된다 |
| `build_layer` | 회차로 고칠 수 없는 전제. supervisor 가 머신 재생성으로 라우팅 |

---

## 9. 워크스페이스 산출물

| 파일 | 내용 |
|---|---|
| `.sboot_version` | 이 워크스페이스를 만든 플러그인 버전 (표지) |
| `INPUT.md` | 입력 슬롯표 (`start` 가 쓴다: `model` · `build` · `target` · `bootloader_path` · `has_super` · `arch` · `bl_surface` · `soc_family` 와 각 근거. 값마다 출처가 있고 없으면 `unknown`) |
| `STATIC.md` | 도출 기록 (추가 전용) |
| `stage_map.json` | 스테이지 지도 (스키마 v2) |
| `lu_manifest.json` | 매체 파티션 구성 (항목별 `kind` · `lba` · `vendor`) |
| `fw/lu_provenance.json` | 합성 매체의 파티션별 출처 종류 (검증이 참조 집합을 가르는 근거) |
| `memdump_plan.json` | 메모리 덤프 채널의 영역 (도출, 있을 때만 채널이 켜진다. 위치와 크기가 필요하고 링 용량은 선택) |
| `kernel_task_regex.txt` | 커널 줄의 태스크 접두 형식 (도출, 기본 형식과 다를 때만. 첫 비어 있지 않은 줄이 정규식) |
| `milestone_tokens.txt` | 목표 단계별 관측 문자열 + 채널(`uart` 기본 · `memdump`) |
| `input_plan.json` | 입력 게이트 패턴 (도출. 없으면 하니스는 패턴을 보내지 않는다) |
| `fingerprint.json` | 마지막 회차 지문 |
| `observation.json` | 마지막 회차 관측 문서 (`kernel_log` · `host_log` 경로 포함, 없으면 null) |
| `07_logs/kernel_N.log` · `host_N.txt` | 병합한 커널 로그(게스트 증거) · QEMU 호스트 줄(증거 아님) |
| `verdict_script.json` | 게이트 3항 + 참고 지표 + 검증 우회 보고 측정값 |
| `VERIFICATION.md` | verifier 최종 판정 |
| `06_machine/bypasses.md` | 우회 기록 |
| `RESUME.md` | 정지 시 인계 문서 |
