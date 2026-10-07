# 개선 과제 목록

이 문서는 2026-09-16 에 작성한 개선 제안 노트(`docs/improvement-proposals.md`) 가운데 아직
플러그인에 반영되지 않은 나머지를 옮긴 것이다. 원래 노트는 삭제했다. 이미 반영됐거나 현재
구조에서 의미를 잃은 항목은 옮기지 않았다.

수치는 모두 한 기기(SM-G970N, Exynos 9820)의 한 차례 완주 기록에서 나왔다. 규모를 가늠하는
근거로만 읽어야 하며, 다른 기기에서 같은 절감이 나온다는 약속이 아니다.

항목을 채택할 때는 노트가 정한 범용성 기준을 따른다.

| 등급 | 뜻 | 채택 |
|---|---|---|
| 범용 | 아키텍처·벤더와 무관하다 | 우선 채택 |
| 아키텍처 의존 | ARM64 계열 전반에 적용된다 | 채택. 다른 아키텍처는 파라미터로 분리 |
| 표준 의존 | 공개 표준(DTB·UFS·SCSI 등)을 쓰는 기기에 적용된다 | 채택. 표준을 쓰지 않는 기기는 기존 경로로 |
| 벤더 의존 | 특정 벤더 펌웨어에만 적용된다 | 조건부. `profiles/*.yaml` 로 분리 |
| 기기 한정 | 이 기기에만 해당한다 | 채택하지 않는다 |

공개 표준의 구조 정의는 다른 기기에서 빌린 값이 아니라 그 기기가 준수한다고 선언한 규격이므로
규칙 3과 충돌하지 않는다. 다만 벤더가 표준을 변형한 부분은 여전히 도출 대상이다. 정지점을
다룰 때는 CLAUDE.md 4절의 순서를 지킨다. 먼저 기존 fixer 의 `handles` 와
`knowledge/faults_unified.md` 의 행을 늘리는 것으로 처리할 수 있는지 본다. 새 fixer 는 파일
하나로 끝나지 않는다. `workflows/pipeline.js` 의 `KNOWN_FIXERS` 와 `tests/smoke.sh` 의 단언이
하드코딩되어 있어 함께 고쳐야 한다.

순서에 관한 노트의 판단도 옮긴다. P-10 과 P-11 은 난이도가 낮고 판정 신뢰도에 직결되므로 먼저
한다. 기존 fixer 보완을 신설보다 먼저 한다. 담당이 무엇을 할 수 있는지 분명하지 않은 채 담당을
늘리면 분류기의 선택지만 늘고 각각의 신뢰도는 그대로이기 때문이다.

## 측정 근거

측정 구간은 2026-08-31 12:17 부터 2026-09-07 21:41 까지 총 177시간 23분이고, 근거 데이터는 `rounds.jsonl`(194행), `metrics.jsonl`, `bypasses.md`(우회 163건)이다.

| 단계 | 소요 | 비율 |
|---|---:|---:|
| Analyze (정적 분석·재도출) | 75시간 14분 | 42.4% |
| Run (QEMU 실행 자체) | 53시간 55분 | 30.4% |
| Loop (판단·변경·재빌드) | 37시간 53분 | 21.4% |
| Build | 8시간 51분 | 5.0% |
| Verify | 1시간 31분 | 0.9% |

- 정지점 분류(194회차): `unmapped_mmio` 37 (19.1%), `data_abort_unmapped` 27 (13.9%),
  `reached` 25 (12.9%), `unknown` 24 (12.4%), `kernel_oops` 17 (8.8%),
  `partition_table_unavailable` 12 (6.2%), `unowned` 8 (4.1%), UFS 관련 3종 10 (5.2%),
  `itmon_*` 5종 5 (2.6%), 기타 단발 29 (15.0%). 앞의 두 분류와 `itmon_*` 를 합친 69회차(35.6%)가
  "주소에 창이 없다"는 하나의 원인이다.
- 변경 도메인(`change_key` 접두): `memory` 77 (39.7%), `none` 44 (22.7%), `storage` 28 (14.4%),
  `kernel` 11 (5.7%), `el3` 9 (4.6%), `rkp` 4 (2.1%), 나머지 12종 21 (10.8%).
- 변경의 효과(`effect`): `applied` 140, `stall` 23, `progress` 21, `reverted` 10. 부팅 깊이를
  실제로 늘린 회차는 194회차 중 셋뿐이다(콘솔 고유 줄 수 1 → 1,738 → 13,457).
- 실행 시간: Run 이 전체의 약 30%이고 회차당 평균 약 12분이 QEMU 실행에만 들었다. 대부분은 타임아웃까지 기다린 시간이다.
- 지문이 빈 회차(`none|none|none|none|0|0|0`): 4회차, 4시간 23분. 마일스톤이 `pending` 인 서명도 따로 4회차다.
- 변경 사유가 없는 회차(`rationale_missing`): 194회차 중 47회차(24%).
- 낭비로 분류된 시간: `fixer-general` 29회차 18시간 37분, `unknown` 24회차 14시간 55분, 새 사실 없는
  재도출 13회차 6시간 49분, 관측을 못 움직인 변경 12회차 6시간 25분.
- `fixer-general` 29회차의 군집: 하이퍼바이저 대행 4, 실행 환경·하니스(`qemu_abort`) 6, 보드 전원·센서 3,
  매체 합성 3, 계측 설치·제거 3, TEE 인터페이스 채널 2, 나머지 단발 8.

## A. 계측과 실행 시간

**P-1 DTB 근거 주변장치 창 일괄 개설**
- 요지: static-analyzer 가 DTB 의 모든 노드 `reg` 를 `compatible`·노드 경로와 함께 `mmio_windows.json` 으로 내고, Build 가 그 목록을 MemoryRegion 으로 한꺼번에 연다. 기본 동작은 읽기 0, 쓰기 흡수이고 각 창에 노드 경로를 태그로 남긴다.
- 근거: `memory` 77회차, "창 없음" 69회차. 노트의 보수적 추정은 약 45회차(전체의 23%), 25시간 안팎.
- 제약: DTB 에 없는 주소는 여전히 폴트를 내야 한다. 그래야 `data_abort_unmapped` 가 진짜 정지점으로 남고, 근거 없는 주소까지 삼키면 규칙 1의 추측 스텁이 된다. 각 창은 접근을 집계해야 한다(P-2). 창이 한꺼번에 열리면 처음 보는 정지점이 몰려 나오므로 P-2·P-3 과 한 묶음이다. ACPI 기기는 대체 파서가 필요하고 DTB 가 없으면 기존 경로로 떨어진다.
- 현재: `templates/machine_mixed_arch.c.tmpl` 에만 있다(DTB 창마다 shadow 창 하나). 단일 아키텍처 경로(`machine_full`, `agents/fixer-memory.md`)는 회차당 창 하나를 연다. 혼합 템플릿의 catch-all 은 한 범위 전체를 읽기 0·쓰기 흡수로 받는데, 노트의 조건은 그 반대다.
- 들어갈 곳: `agents/static-analyzer.md`(도출), `templates/machine_full.c.tmpl`(생성), `agents/fixer-memory.md`.

**P-2 MMIO 접근 상시 집계**
- 요지: 주소마다 {읽기 수, 쓰기 수, 마지막 읽은 값, 마지막 쓴 값, 최초 PC, 최종 PC} 를 누적하고 종료 시 한 번만 접근 횟수 내림차순으로 `07_logs/mmio_N.txt` 에 덤프한다.
- 근거: `unknown` 24회차, 관측을 못 움직인 변경 12회차. 노트 추정 약 18회차, 10시간.
- 제약: 실행 중 줄 단위 출력 금지. UFS PRDT 탐침이 초당 수백 줄을 stderr 로 내 매체 접근이 62배 느려지고 하니스가 멈춘 기록이 있다(B-153, B-154).
- 현재: 혼합 템플릿에서 4 KiB 페이지를 처음 만질 때 호스트 줄 하나를 내는 것뿐이다.
- 들어갈 곳: `templates/machine_full.c.tmpl`, `templates/machine_mixed_arch.c.tmpl`, `scripts/run_full.sh`.

**P-3 폴링 루프 자동 탐지**
- 요지: P-2 집계에서 읽기 횟수가 임계(예: 1,000회)를 넘고, 읽은 PC 가 좁은 범위(예: 64바이트)에 모이고, 값이 계속 같은 주소를 `observation.json` 의 `poll_candidates` 로 보고한다.
- 근거: ADC STAT 비트, DSIM PLL 락, PHY 레인 ready, RX FIFO, MCT write-ack 를 각각 따로 진단했다. 노트 추정 8~12회차.
- 제약: 세 조건이 함께 서야 한다. 어느 비트를 기다리는지는 여전히 디스어셈블로 확정한다.
- 현재: 혼합 템플릿이 같은 값 3000회 읽기 뒤 POLL 호스트 줄을 내는 것뿐이다.
- 들어갈 곳: P-2 위에 `scripts/run_round.sh`(관측 문서), `agents/fault-classifier.md`.

**P-4 실행 시간의 적응적 관리**
- 요지: 그 회차의 목표 토큰이 나오면 즉시 끝낸다. 최근 N초 동안 콘솔 고유 줄이 늘지 않고 예외 수만 늘면 조기 종료한다.
- 근거: Run 53시간 55분(30.4%). 노트 추정은 그중 30~40%, 약 16~21시간. 가장 가치가 큰 항목이다.
- 제약: 무진전으로 끊은 회차는 별도 플래그로 표시하고 `timeout_bound`("더 오래 실행하니 콘솔이 더 나왔다")와 구분해 정체 판정에서 다르게 다룬다.
- 현재: `MAX_EXCEPTIONS`(기본 꺼짐)만 있다.
- 들어갈 곳: `scripts/run_full.sh`, `scripts/fingerprint_lib.sh`, `scripts/stop_conditions.py`.

**6-9 계측 회차는 수정이 아니다**
- 요지: 회차에 `round_kind ∈ {change, instrument, revert, rebuild}` 를 붙이고, `instrument` 회차는 지문 불변을 정체로 세지 않으며 소진 판정 입력에서 뺀다. 대신 `instrument_question`(무엇을 확인하려는가)을 필수로 요구한다.
- 근거: `fixer-general` 29회차 중 3회차가 계측 설치·제거였고, 우회 기록까지 세면 읽기 전용 계측 회차가 10건이 넘는다.
- 제약: 계측은 설치와 제거가 한 쌍이라 최소 두 회차를 쓴다. 지금은 진단이 전진하는데도 소진 판정이 가까워진다. P-2 가 들어가도 남겨야 한다. P-10, 7-1 과 같은 정체 계산을 건드리므로 함께 처리한다.
- 현재: 구현되지 않았다. D 절의 7-5(`fixer-storage` 계측 우선)가 이것에 기댄다.
- 들어갈 곳: `scripts/stop_conditions.py`, `scripts/record.py`, `workflows/pipeline.js`, `agents/fixer-storage.md`.

## B. 기록과 판정

**P-5 재생성 뒤 다시 적용되지 않은 우회 경고**
- 요지: 재생성 단계가 적용 대상을 기계 판독 형태로 읽어, 다시 적용되지 않은 항목을 경고로 띄운다. 전제가 바뀌었을 수 있는 항목은 자동 재적용하지 않고 경고만 낸다.
- 형태: `{id, layer, target{file, offset, va}, precondition, apply}`. `layer` 는 medium · machine · kernel_text, `precondition` 은 사전 이미지 바이트열, `apply` 는 적용 바이트열이나 생성 스크립트 경로다. `bypasses.md` 는 사람이 읽는 기록으로 둔다.
- 근거: 매체에 파티션 테이블을 둔 우회가 재생성으로 두 번 사라져 세 번 적용했다(B-34 → B-46 → B-59).
- 현재: 머신 소스 쪽은 있다(`/* bypass:<id> */` 행이 없는 장부 기록을 잡는다). 이미지(I)·매체 우회와 `stage_map.json` 에 항목이 없는 데이터 블롭은 경고가 없다.
- 들어갈 곳: `scripts/build_lu.py`, `scripts/verify_gates.py`(장부 검사).

**P-6 머신 소스 런타임 패치 헬퍼**
- 요지: 대상 VA 를 계산하고 `cpu_memory_rw_debug` 로 사전 이미지를 읽어 기대 바이트와 같을 때만 쓰며, 다르면 패치하지 않고 알리는 헬퍼를 템플릿에 둔다. 패치 목록은 표 하나로 관리한다.
- 근거: 같은 구조의 커널 `.text` 워드 패치가 최소 7건이고 매번 손으로 다시 썼다(B-145, B-150, B-151, B-152, B-156, B-157, B-159).
- 현재: 혼합 템플릿에는 패치 장부 엔진이 있고 `scripts/patch_kernel.py` 는 오프라인용이다. `machine_full` 에는 런타임 사전 이미지 검사 헬퍼가 없다.
- 들어갈 곳: `templates/machine_full.c.tmpl`. 7-3 의 구현체다.

**P-7 스토리지 표준 골격**
- 요지: UFS 3.x 의 UTRD·UPIU·PRDT 구조 정의와 SCSI 명령 골격을 템플릿에 두고, 벤더 변형만 도출 대상으로 남긴다. eMMC 도 같은 방식으로 골격을 둔다.
- 근거: `storage` 28회차 중 상당수가 필드 오프셋을 계측으로 하나씩 찾은 회차였다(B-36 ~ B-53). 노트 추정 8~12회차.
- 제약: JEDEC 공개 규격의 구조 정의이지 다른 기기의 관측값이 아님을 주석과 `bypasses.md` 에 적는다. 골격은 출발점이고 관측으로 검증해야 한다. 이 기기에서도 `resp_off` 배율과 `prdt_off`/`prdtl` 의 DW7 상하위 역할이 규격 해석과 달라 계측으로 확정했다.
- 현재: `templates/storage_hci.c.tmpl` 의 `handle_query`·`handle_scsi` 가 빈 스텁이고 PRDT 전송은 주석뿐이며 UTRD 응답·PRDT 오프셋이 없다. eMMC 골격은 없다(CHANGELOG 0.29.1 의 C9).
- 들어갈 곳: `templates/storage_hci.c.tmpl`, `agents/fixer-storage.md`.

**P-8 무담당 정지점의 승격 임계**
- 요지: 같은 성격의 정지점이 `fixer-general` 로 N회 이상 떨어지면 `RESUME.md` 와 세션 종료 보고에 새 fixer 후보로 제안한다. 근거는 그 회차들의 `category` 와 `change_key` 접두다.
- 근거: `fixer-general` 29회차, 18시간 37분.
- 제약: 에이전트 레지스트리는 세션 시작 시점의 스냅숏이라 신설은 언제나 다음 세션을 위한 커밋이다.
- 현재: `rounds.jsonl` 로 임계를 계산하는 곳이 없고 `scripts/analyze_run.py` 는 `fixer_candidates.md` 를 읽지 않는다.
- 들어갈 곳: `scripts/analyze_run.py`, `scripts/make_resume.py`.

**P-10 빈 지문의 별도 처리**
- 요지: 실행은 됐는데 지문 구성요소가 비어 있으면 `low_information` 으로 표시하고, 그 회차를 계측이나 static-analyzer 로 먼저 보낸다.
- 근거: 4회차, 4시간 23분이 "같은 지문"으로 묶여 정체로 세졌다.
- 제약: 노트 원안은 `INSUFFICIENT_FINGERPRINT` 로 표시하고 정체 계산에서 제외하는 것이었다. 검토 의견으로 `low_information` 플래그로 바꾸고 정체 계산에서 통째로 빼지 않는다. 빼면 `EXHAUSTED` 에 닿을 수 없게 될 수 있기 때문이다. `run_failed`(QEMU 미기동)와는 다른 경우다.
- 현재: 실행된 빈 지문 회차는 정체로 센다.
- 들어갈 곳: `scripts/fingerprint_lib.sh`, `scripts/stop_conditions.py`, `workflows/pipeline.js`.

**P-11 집계 결함 두 건**
- (c) 단계별 토큰 비율: `scripts/analyze_run.py` 의 비율이 100%를 넘을 수 있다(관측 Loop 168.7%). `tokens_total` 이 세션마다 초기화되는데 분모가 세션 합이 아니라 `max(totals)` 이기 때문이다.
- (b) `analyst_new_facts` 의 `-1` 은 "측정하지 않음" 표지인데 `rounds.jsonl` 문서에 설명이 없다(관측 합계 -125). 문서화하거나 `null` 로 쓴다.

**P-12 판정 단일화**
- 요지: verifier 의 최종 판정을 기계가 읽는 파일에 역기록한다. 원래 스크립트 판정은 따로 보존하고 상향 근거의 출처도 남긴다.
- 근거: `verdict_script.json` 은 `UNVERIFIED`, `VERIFICATION.md` 는 `VERIFIED` 로 키트 안에 두 판정이 공존했다.
- 현재: verifier 는 `script_passes`, `final_verdict`, `override{direction, evidence}` 를 이미 돌려주지만, 그것을 `verdict_script.json`(또는 `verdict_final.json`)에 쓰는 곳이 없다.
- 들어갈 곳: `workflows/pipeline.js`, `agents/verifier.md`.

**P-13 변경 사유 필수화**
- 요지: 노트 원안은 `rationale` 이 없으면 회차 기록을 거부하고 fixer 에게 되돌리는 것이었다. 검토 의견으로, 기록 소실을 막기 위해 응답 단계에서 막는다: `FIXER_SCHEMA` 와 `GENERAL_SCHEMA` 에서 `rationale` 을 required 로 하고, `scripts/record.py` 의 표시는 백스톱으로 둔다.
- 근거: 47/194 회차에 사유가 없었다.
- 들어갈 곳: `workflows/pipeline.js`.

**P-15 주입 감시의 오탐**
- 요지: 토큰을 게스트 콘솔 리터럴 집합과 대조한다. `scripts/verify_gates.py` 의 `analyze_files` 가 이미 렉서로 주석을 걷어 내고 그 리터럴을 뽑는다.
- 근거: 토큰이 주석과 stderr 전용 검색 앵커에 있어도 사다리가 무효화됐고, 대응으로 리터럴을 두 조각으로 끊어 `grep -qF` 를 피했다(B-148).
- 제약: 집행 장치를 소스 쪽에서 피하는 것은 옳은 대응이 아니다. 리터럴 쪼개기는 규칙 7을 약하게 만든다.
- 대안: 정확한 판정이 어려우면 토큰이 콘솔 쓰기 함수의 호출 그래프에 닿는지로 판정한다. 생성 머신의 콘솔 쓰기 경로가 하나인 동안만 성립한다.
- 현재: `scripts/run_full.sh` 의 `scan_token` 과 `scripts/memdump_observe.py` 가 주석과 stderr 전용 인자를 포함한 소스 원문에서 부분 문자열로 찾는다.
- 들어갈 곳: `scripts/run_full.sh`, `scripts/memdump_observe.py`.

## C. 등급 정의

이 기기에서 표면(`autoboot aborted..`)과 커널은 양립하지 않았다. 우회 B-60 이 autoboot 게이트 분기를 NOP 으로 덮어 셸 진입을 막았고 그래서 커널까지 갔다. 키트 제목은 F2 인데 F1 의 한 칸이 비었다. autoboot 을 가진 부트로더(U-Boot 포함)는 대부분 같은 구조라 다른 펌웨어에서도 반복된다.

**8a 표면과 커널의 분기**
- 요지: 사다리를 `stage_entry × N` 뒤에서 표면 경로와 매체·커널 경로로 갈라 표현한다.
- 현재: 표면 칸은 도출값이 `none` 일 때만 빠진다. shell·fastboot 이면 사다리는 일렬이다. 셸이나 커널 중 하나만 허용하는 autoboot 게이트를 표현하는 분기가 없다.

**8b 두 회차의 합집합으로 판정**
- 요지: 표면 도달과 커널 도달을 같은 실행에서 요구하지 않고, 각각 다른 회차로 도달시켜 합집합으로 등급을 본다.
- 현재: `observedRungs` 가 회차를 넘어 쌓이는 것은 우연이다. 표면을 위한 회차를 계획하지 않고, 커널에 닿으면 루프가 돌아가지 않는다.

**8c 칸별 도달 회차 기록**
- 요지: 어느 회차가 어느 칸을 채웠는지 칸 → 회차 표로 남긴다.
- 현재: `kernel_alive` 와 마지막으로 통과한 칸만 회차 번호를 가진다.

**8d 빈 칸이 있는 등급 보고**
- 요지: 앞 칸이 비어 있으면 등급 문구가 그것을 말해야 한다.
- 현재: `gradeText` 는 목표와 우회 건수만 쓴다. 빈 칸은 `rung_states` 와 `passed_over` 에만 드러난다.
- 들어갈 곳(8a~8d): `workflows/pipeline.js`, CLAUDE.md 3절.

## D. 정지점과 fixer

**6-3 EL2 대행 정지점**
- 요지: 게스트 하이퍼바이저(RKP/uH, QHEE 등)가 커널 대신 하는 동작(EL2 게이트웨이 호출, 페이지 테이블 위임 쓰기, RO 객체 초기화)을 머신이 대행한다. 정지점 `hvc_undef`(`hvc #0` 에서 미정의 예외), `hvc_returns_zero`(게이트웨이가 0을 반환해 물리주소 0에 구조를 만든다), `ro_object_uninitialized`(RO 객체 역포인터가 비어 무결성 검사 실패), `pgtable_delegation_missing`(위임된 페이지 테이블 쓰기가 반영되지 않는다).
- 근거: `fixer-el3` 의 8회차 중 등록 담당은 1회차뿐이고 나머지 7회차가 HVC/RKP 4, `security_gate` 2, `kernel_oops` 1 이었다. 하이퍼바이저 군집은 최소 7건(B-70, B-71, `fixer-general` 4건, RO 페이지 응답 1건). 대행 우회 B-78, B-83~B-86 은 전부 `fixer-general` 이 처리했다.
- 제약: 경계 표를 그대로 지키고, 판별이 서지 않으면 반려한다. 잘못 고르면 정반대 변경이 들어간다.

  | 상황 | 처방 |
  |---|---|
  | 커널이 자기 하이퍼바이저를 싣고 있고 우리가 잘못 가로챘다 | 가로채기를 제거한다(`hvc_pkvm`, 지금의 `fixer-el3`) |
  | 실기에는 별도 하이퍼바이저가 있고 이 환경에는 없다 | 그 응답을 대행한다(새 정지점 넷) |

  대행은 머신이 커널 메모리를 직접 쓰는 것이라, 부작용 항목에 어느 무결성 검사가 의미를 잃는지 반드시 적는다. 구조체 오프셋(`struct cred` 등)은 커널 이미지에서 도출하고 벤더별 호출 번호는 `profiles/*.yaml` 에 둔다.
- 현재: 없다. 노트 원안은 신설(`fixer-hypervisor`)이고 근거는 도구 분기(커널 자료구조 필드 배치를 알아야 한다)다. 여기서는 CLAUDE.md 4절에 따라 `fixer-el3` 의 처리 범위 확장으로 적었다. 그 `hvc_pkvm` 처방은 "HVC 가로채기를 제거하라"로 방향이 반대다.
- 들어갈 곳: `knowledge/faults_unified.md` 행, `fixers/registry.yaml` 의 `fixer-el3` handles, `agents/fixer-el3.md`.

**6-4 보드 상태**
- 요지: 부트로더가 부팅 계속 여부를 정하려고 읽는 배터리 전압·온도, 충전기 종류, JIG, 리비전 스트랩을 모델링한다. 정지점 `power_gate_shutdown`, `sensor_value_out_of_range`, `bus_slave_absent`, `strap_pin_reads_zero`.
- 근거: `fixer-general` 의 보드 전원·센서 3회차(PMIC 비트뱅 I2C, ADC 배터리 서미스터, CCIC RID).
- 제약: 임계값은 펌웨어 자신의 비교 명령에서 도출하고 근거를 적는다. "25.0 °C" 같은 값을 정하면 그것이 추측 스텁이다(규칙 1). 값이 버스 슬레이브에 있으면 창이 아니라 버스 트랜잭션을 모델링한다.
- 현재: 노트 원안은 신설(`fixer-board`)이고 근거는 도구 분기다. 여기서는 CLAUDE.md 4절에 따라 `fixer-memory` 의 처리 범위 확장으로 적었다. 다만 `fixer-memory` 에 두면 읽기 0 처방과 방향이 충돌하므로 별도 처방 행과 버스 모델이 필요하다.
- 들어갈 곳: `knowledge/faults_unified.md` 행, `fixer-memory` handles, `agents/fixer-memory.md`.

**6-5 매체**
- 요지: 정지점 `partition_absent_in_table`, `partition_offset_mismatch`, `partition_asset_missing`, `medium_regenerated_bypass_lost`. 노트는 `partition_table_unavailable` 과 `keystore_partition_missing` 을 매체 담당으로 옮긴다.
- 근거: `fixer-general` 의 매체 합성 3회차, B-34 → B-46 → B-59. AVB 이름의 정지점 3종을 `fixer-storage` 가 처리했다.
- 제약: 새 fixer 를 만들지 않는다. `fixer-storage` 는 handles 가 이미 21개로 노트의 기준(약 10개)을 넘는다. 결정되지 않은 것이 둘이다. (1) `fixer-secureboot` 와의 경계. 노트의 안 A 는 목적으로 가른다: AVB 체인이 요구한 매체 변경은 `fixer-secureboot`, 그 밖의 매체 구조(PARAM env 배치, PIT 예약, 블록 수 보정)는 매체 담당. 이때 `fixer-secureboot` 는 AVB 가 이 파티션을 요구한다는 근거를 콘솔이나 vbmeta 에서 못 대면 반려하고, 매체 담당은 AVB 로그가 그 파티션 이름을 부르면 반려한다. (2) "매체 변경은 재생성 스크립트에 남겨 재생성을 견뎌야 한다"는 규칙(P-5 와 짝).
- 들어갈 곳: `knowledge/faults_unified.md` 행, `fixers/registry.yaml`, `agents/fixer-storage.md`, `agents/fixer-secureboot.md`.

**6-6 하니스**
- 요지: `instrumentation_cost`(계측 출력이 실행을 늦춰 타임아웃을 부른다)와 `harness_race`(하니스와 QEMU 의 종료 순서 경합)를 `not_firmware` 목록에 한 줄 처방과 함께 넣는다. 노트에는 `run_env_degraded`(디스크나 메모리 부족이 회차를 방해한다)도 있다.
- 노트 원안: `not_firmware` 에는 `harness_input_starved` 만 두고, 고칠 대상이 있는 넷(`qemu_abort` 포함)은 신설 `fixer-harness` 가 맡는다. 노트는 이것을 신설 1순위로 두었다. 환경 결함을 펌웨어 결함으로 오진하는 것을 막고, 신설을 모두 하면 `fixer-general` 도달이 29회차에서 한 자리로 준다고 추정했다. 여기서는 `instrumentation_cost` 와 `harness_race` 를 `not_firmware` 목록에 두는 쪽으로 적었다.
- 근거: `qemu_abort` 7회차. 살아 있는 리더 밑에서 콘솔을 닫아 `rc=124` 가 `SIGABRT 134` 로 바뀐 결정론적 경합이었고 고친 곳은 `uart_harness.py` 였다. 계측 비용 사례는 B-153, B-154.
- 제약: 노트의 전제는 환경 결함을 펌웨어 결함으로 고치면 정당화될 수 없는 우회가 남는다는 것이다.
- 현재: `qemu_abort` 는 `fixer-general` 소관이고 머신 소스 결함으로 다뤄져 노트의 전제와 어긋난다. `fixers/registry.yaml` 의 `not_firmware` 주석에 앞뒤가 끊긴 `partition_table_unavailable / downstream failure` 조각이 남아 있다.
- 들어갈 곳: `fixers/registry.yaml`.

**6-7 인터럽트**
- 요지: 정지점 `no_clockevent_tick`, `irq_not_wired`, `timer_write_ack_missing`.
- 근거: 이 기기에서 실제 문제는 아키텍처 타이머 PPI 가 아니라 벤더 타이머(MCT)의 SPI 배선이었다. 틱이 없으면 `jiffies` 가 멈추고 커널이 `wfi` 에서 영원히 잔다. 증상이 조용해 진단이 어렵다.
- 현재: 노트 원안은 신설(`fixer-interrupt`, `gic_ppi` 이관)이고 근거는 도구 분기와 낮은 성공률이다. 여기서는 CLAUDE.md 4절에 따라 `fixer-kernel` 의 처리 범위 확장으로 적었다.
- 들어갈 곳: `knowledge/faults_unified.md` 행(`gic_ppi` 옆), `fixer-kernel` handles.

**6-8 기존 fixer 확장(표 행과 handles 만)**
- `sysreg_undef`(CPU 시스템 레지스터 미구현) → `fixer-el3`. 근거 `cpu:ras_error_record_regs:errselr_...`.
- `cmdline_token_rejected`(부트 파라미터가 화이트리스트에 막힘) → `fixer-bootflow`. 근거 `cmdline:earlycon_via_whitelist_name_swap`.
- `uart_cfg_readback`(UART 설정 되읽기 불일치) → `fixer-bootflow`. 근거 `uart:cfg_reg_readback_and_utrstat_txe`.
- `mailbox_ipc_no_response`(창만으로는 안 되고 요청에 응답해야 한다) → `fixer-memory`. 근거 `dbgcore:advtrc_mailbox_ipc_response`, 이 기기에서 3건 이상(디버그 코어, ACPM IPC). 다음 기기에서 반복되면 별도 담당 후보로 본다.

**7-1 fixer 별 효과 집계**
- 요지: `scripts/analyze_run.py` 에 fixer × category 별 `moved` 와 `reverted`(철회) 수를 낸다. 필요하면 `fingerprint_delta` 를 `rounds.jsonl` 에 저장한다.
- 근거: 전문가 fixer 가 붙은 회차는 전부 `applied` 나 `reverted` 였다. `progress` 는 fixer 미지정 39회차에만(21), `stall` 은 미지정 18과 `fixer-general` 5에만 있었다. `registry.yaml` 의 분할 기준 "성공률이 유독 낮은 fault 는 떼어 낸다"를 잴 수단이 없다.

**7-2 담당 밖 처리 기록**
- 요지: fixer 가 자기 handles 밖의 category 를 처리하면 `boundary_violation` 으로 보고하고, 한 번도 불리지 않은 handles 를 기기를 거듭하며 추적한다. 두 기기 연속 미호출이면 그 이름이 관측과 맞지 않는다는 신호다.
- 근거: 담당 밖 처리 `fixer-memory` 16/76, `fixer-storage` 6/27, `fixer-el3` 7/8. `fixer-bootflow`·`fixer-secureboot` 는 담당으로 한 번도 불리지 않았다.
- 들어갈 곳: `scripts/analyze_run.py`.

**7-3 `fixer-kernel` 런타임 게스트 메모리 패치 경로**
- 요지: 부트로더의 AVB 검사가 끝난 뒤에만 적용되는 런타임 훅 경로를 더한다. 사전 이미지 검사는 유지한다.
- 근거: 커널은 부트로더가 매체에서 읽어 AVB 가 해시 검증한다. 매체 바이트를 패치하면 소프트웨어 해시 AVB 가 정당하게 실패해 `verify_ok` 가 무너진다(B-73). 이 기기는 `start_kernel` 안의 관측으로 확정한 PC 를 훅 지점으로 잡았다.
- 현재: `agents/fixer-kernel.md` 는 오프라인 `scripts/patch_kernel.py`(매체 수정 경로)를 쓴다. 혼합 템플릿은 이미 런타임에 패치하지만 `machine_full` 에는 런타임 경로가 없다.
- 들어갈 곳: `agents/fixer-kernel.md`, P-6.

**7-4 나머지**
- 버스 모니터(ITMON, NoC error 등) 오류 로그가 있으면 지문의 FAR 보다 먼저 읽는다. 일반 문장으로 쓰고 벤더 이름은 `profiles/*.yaml` 에 둔다. 근거: `itmon_*` 5회차가 미등록 주소를 주소째로 알려 주었다.
- DTB 에 노드가 없을 때 창 폭은 0x1000 을 넘지 않는다. 근거: 실제로 연 창은 0x100, 0x1000, 0x8000 수준이었다.
- 들어갈 곳: `agents/fixer-memory.md`, `profiles/exynos.yaml`.

**7-5 `fixer-storage` 계측 우선**
- 요지: 벤더 컨트롤러의 필드 위치와 오프셋이 미확정이면 값을 고치기 전에 읽기 전용 계측을 먼저 넣는다. 추정 오프셋으로 쓴 값은 틀리면 철회로 끝나 회차 둘을 쓰지만, 계측은 틀려도 한 회차만 잃는다.
- 근거: 27회차 중 10회차가 철회(37%)였고 다른 fixer 의 철회는 0이었다. B-38 ~ B-52 가 "값 변경 → 반증 → 철회"의 반복이었다(UPIU 응답 오프셋, PRDT 위치, 게이트 바이트 위치). 실제로 부딪힌 스토리지 정지점은 등록표에 없는 이름 둘로 각각 6회차, 4회차였다.
- 제약: 6-9 의 `round_kind: instrument` 에 기댄다. 계측 회차가 정체로 세어지지 않아야 이 순서를 권할 수 있다.
- 들어갈 곳: `agents/fixer-storage.md`.

**7-6 `fixer-bootflow` 처방 채우기**
- 요지: 등록된 9개 fault 를 에이전트 파일에 모두 적고, `stage_handoff_missing`·`boot_info_word_missing` 행에 관측 증상을 더한다: 건너뛴 스테이지가 쓰지 않아 하류의 크기나 워드가 0으로 읽힌다.
- 현재: 9개 모두 `knowledge/faults_unified.md` 에 처방 행이 있다. 빠진 것은 관측에서 읽히는 증상 서명이고, `agents/fixer-bootflow.md` 는 아직 3개만 적는다.
- 근거: 분류기가 로그에서 보는 것은 "SRAM 의 워드가 0이라 DRAM 크기가 0으로 선언됐다"이지 "핸드오프 슬롯이 비었다"가 아니다. 이 기기에서 핸드오프 문제를 `fixer-memory` 와 `fixer-general` 이 나눠 처리했다.
- 들어갈 곳: `agents/fixer-bootflow.md`, `knowledge/faults_unified.md`.

**7-8 `fixer-general` 등록 정리**
- 요지: `handles: [unowned, qemu_abort]` 와 `reached_by: decline_only` 가 함께 있는데 `qemu_abort` 는 곧바로 이 fixer 로 간다. 주석에 두 경로를 모두 적거나 handles 를 뺀다.
- 들어갈 곳: `fixers/registry.yaml`.

**7-9 정지점 이름 축적**
- 요지: 기기를 넘는 `fault_candidates.md` 를 두고, 분류표에 없는 즉석 이름과 서명을 모은다. `agents/static-analyzer.md` 에 이름 규칙(주소·심볼·벤더 문자열은 이름이 아니라 서명에 넣는다)과 승격 규칙(두 기기에서 나오면 표 한 줄)을 둔다.
- 근거: 34종 중 22종(31회차)이 분류표와 등록표 어디에도 없는 즉석 이름이었다. 예: `itmon_bts_window_1b180000_narrow` 는 이름이 `bus_monitor_window_too_narrow`, `0x1b180000` 은 서명이어야 한다.
- 제약: 커밋은 다음 세션 몫이다.

## E. 채택하지 않은 아이디어

- 캐치올(광역 흡수) 창의 공식 채택: 넓은 창은 다음 정지점을 가리고 미매핑 폴트를 지워 `fault-classifier` 를 무력화한다. 규칙 1에 저촉된다. 근거 있는 대안은 P-1 이며 이 이유는 지금도 유효하다. (나머지 넷, 값 차용·정규식 단독 마일스톤·회차 상한의 판정 사용·벤더 문자열 하드코딩은 CLAUDE.md 에 있다.)

## F. 한계

- 예상 절감은 한 기기의 회차 분포에서 추정했다. 스토리지가 eMMC 인 기기는 P-7 의 효과가 다르다.
- `applied` 140회차가 전진인지 정체인지 분류되지 않았다. `scripts/analyze_run.py` 는 다음 지문으로 `moved` 를 계산하지만 `rounds.jsonl` 에는 `applied` 만 남는다. 실제 낭비 비율은 여기 적은 것보다 클 수 있다.
- 단계별 소요는 직전 기록 이벤트부터의 간격이라, 기록되지 않은 대기 시간이 어느 단계에 잡혔는지 확정할 수 없다.
