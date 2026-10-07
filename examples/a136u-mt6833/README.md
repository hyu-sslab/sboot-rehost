# SM-A136U (MediaTek MT6833) — 수동 진행의 참조 자료

> **값을 차용하지 않는다.** 이 폴더는 한 기기를 사람이 수동으로 끝까지 진행한 기록이다. 주소, 오프셋, 레지스터 값,
> 패치 바이트는 그 펌웨어 빌드(`A136USQSFDYJ1`)의 것이고, 다른 펌웨어의 값은 그 펌웨어에서 도출한다 (CLAUDE.md §7 규칙 3).
> **펌웨어는 이 저장소에 없다.** Samsung 의 저작물이라 담지 않았고, 이 폴더만으로는 아무것도 실행되지 않는다.

## 이것이 무엇이고 무엇이 아닌가

| 이다 | 아니다 |
|---|---|
| AArch32 프리로더 → AArch64 EL3 모니터 → 부트로더 → 커널이 **한 머신에서** 이어지는 체인을 사람이 어떻게 구현했는지의 **구조** 예 | 플러그인이 도출한 머신. 수동 진행의 도출 기록(`STATIC.md`, `stage_map.json`)은 최종 체인 사실을 한 줄도 담지 않는다 |
| 구조 골격(`templates/machine_mixed_arch.c.tmpl`)의 각 절이 실제로 어떤 모습이었는지 보는 자료 | 복사해서 쓸 시작점. 칩 상수가 전부 박혀 있다 |
| 관측 문자열의 **예** (`EXPECTED_MILESTONES.txt`) | 바이트 단위 정답이나 `diff` 의 통과 기준. `examples/s921n-exynos2400/EXPECTED_OUTPUT.txt` 도 같다 |

## 파일

| 파일 | 내용 |
|---|---|
| [machine.c](machine.c) | 수동 진행이 만든 머신 소스 (키트 `machine/machine_preloader.c`, 2,072줄). **코드는 그대로이고** 맨 위에 경고 주석 31줄만 붙였다 |
| [bypasses.md](bypasses.md) | 수동 진행의 우회 장부 92항목 (키트 `machine/bypasses.md`). 맨 위에 **알려진 결함** 8개를 적었고 원문은 고치지 않았다 |
| [EXPECTED_MILESTONES.txt](EXPECTED_MILESTONES.txt) | 같은 바이너리를 다시 실행(2026-10-05)해 얻은 마일스톤 이름과 관측 문자열. 채널(`uart` / `memdump`) 포함. 펌웨어 바이트는 없다 |

## 낡은 값이 남아 있다

`machine.c` 의 **헤더 주석은 폐기된 v1 서술**이다. 주석은 `load_base 0x200f10`, `reset_pc 0x201604` 를 도출값이라고 적지만, 코드는 v2 에서
`LOAD_BASE`, `RESET_PC` 정의로 바뀌었다 (payload 가 0x600 높게 적재된 어긋남을 바로잡은 것). 주석을 믿지 말고 `#define` 을 읽는다.
함께 읽을 때 주의할 것:

| 위치 | 상태 |
|---|---|
| 헤더 주석의 `load_base`, `reset_pc` 와 그 도출 서술 | v1. `LOAD_BASE`, `RESET_PC` 정의가 현재 값이다 |
| `SRAM_BASE`, `SRAM_SIZE` (8 MiB 평면 RAM) | 낡은 것이 아니라 **근거 없이 정한 값**이다 (실제 크기 미도출) |
| `mc->max_cpus = 1` | `-smp` 는 의미가 없다. 머신이 CPU 두 개를 직접 만든다 (생성 순서가 의미를 가진다) |
| `bypasses.md` 머리말의 v1 장부 (#1~#29) 언급 | 보존했다는 `bypasses_v1_archive.md` 는 키트 zip 에도 없다. v1 은 무효다 (`machine.c` 는 v1 의 포인터 우회를 모두 제거했다고 적는다) |
| 소스 안의 `REHOST_LK_PATCHES` 등 환경변수 이름 | 키트의 `run.sh` 가 설정하던 것이다. 플러그인 쪽 이름은 `templates/machine_mixed_arch.c.tmpl` 이 정한다 |

## 무엇을 우회했나

상세는 `bypasses.md`. 요약만 적는다 (분류는 수동 진행이 아니라 조사에서 붙인 판단이다).

| 갈래 | 내용 |
|---|---|
| **없는 하드웨어** | 코프로세서 IPI (SSPM, MCUPM, SCP), 열센서, 디스플레이, 모뎀, CPU 핫플러그. 8개 CPU 중 2개만 존재 |
| **값 (V)** | 배터리·키·충전기 입력, PMIC·AUXADC 값, 폴링 완료 비트, 퓨즈. 입력 값을 머신이 정한다 |
| **패치 (P)** | 프리로더 코드 6곳, 런타임 패치 53행 (부트로더 11, 커널 42). 부트로더·커널 메모리를 실행 중에 고친다 |
| **이미지 수정 (I)** | vendor rc/fstab 바이트, 위조한 체인 파티션 |
| **호스트 사정 (H)** | CPU 생성 순서, `MAP_PRIVATE` 매핑, 한 CPU 가 AArch32 ↔ AArch64 로 못 바뀌어 CPU 를 둘 두는 것 |

## 검증을 우회했다

이 머신의 **`verify_ok` 는 도달이 아니라 `reached_bypassed`** 다 (CLAUDE.md §11).

- 부트로더 안의 **모든 AVB digest·서명패딩 비교가 항상 "같음"** 이다 (`avb_safe_memcmp` 를 `movs r0,#0; bx lr` 로 바꿈). OEM 이미지 digest 비교도 강제 통과다.
- 암호 엔진(DXCC) 모델은 **큐 핸드셰이크만** 하고 암호 연산이 없다. 그래서 SHA 가 SMC → 모니터 → 엔진 경로로 계산되는 이 칩에서는 실제 digest 가 틀리고, 위 패치가 그것을 덮는다.
- 콘솔의 `SECURE : Signature verification succeed (boot)` 는 **그 스텁 위의 성공**이다. 서명이 검증되었다는 뜻이 아니다.
- 퓨즈 값이 0 이라서 `[LIB] NS-CHIP`, `[SBC] sbc_en = 0` 이 관측된다. 서명 검증 경로 일부가 꺼진 채 통과로 찍히며, 장부에는 이 항목이 없다.
- lock 상태와 verified boot 상태, dm-verity 오류 모드도 바꿨다 (`bypasses.md` #121, #122, #125, #126).
- 출처 검증 게이트(`verify.py` 3항) 통과는 **부팅 완주를 뜻하지 않는다** (CLAUDE.md §11).

## 검증되지 않은 우회

- **원인을 확인하지 않은 항목** (표지 X, 13건). 우선 재검증 대상: #114·#117·#118 (CFQ 패치 3건. 원인이 eMMC DMA 모델의 중복 실행이었을 가능성을 키트가 인정했으나
  되돌려 재검증하지 않았다), #61·#62, #59·#92 (코프로세서·spmfw 이미지가 패키지에 있었는데 "없다" 고 판단), #88.
- **부작용이 기록되지 않은 항목 22개**와 **훼손된 #65**. 목록은 `bypasses.md` 맨 위.
- **런타임 패치의 선검사가 약하다.** 엔트리마다 독립된 2바이트 비교이고, 빌드 식별이 없다. 같은 우회의 여러 행이 일부만 적용될 수 있다. 커널 행은 주소 무작위화가
  없다는 전제 아래 고정된 주소를 쓴다. `machine_mixed_arch.c.tmpl` 의 장부 엔진이 이것을 고친 형태다.
- 퓨즈·수명주기·잠금 값은 도출할 수 없다. 장부는 그 값이 실제 기기의 것이라고 주장하지 않는다.

## 관측 채널

이 머신에서 **커널은 UART 에 아무것도 출력하지 않는다.** 커널 로그는 로그 영역(pstore)을 호스트가 메모리 덤프로 읽어 복원한 것뿐이다. UART 가 침묵하는 원인은
**미확인**이다. 그래서 `EXPECTED_MILESTONES.txt` 의 `kernel_alive` 이후 칸은 채널이 `memdump` 다. `kernel_alive` 의 배너는 링이 한 바퀴 돌기 전에 덤프가 찍힌 경우에만
보이므로 **관측이 보장되지 않는다.** 초기 정지가 간헐적으로(측정 12회 중 3회) 있었고 원인은 미확정이다.

## 구조 골격과의 대응

`templates/machine_mixed_arch.c.tmpl` 의 절과 이 소스에서 읽을 곳 (값이 아니라 구조를 읽는다).

| 골격의 절 | `machine.c` 에서 |
|---|---|
| CPU 생성 순서 (모니터를 실행할 CPU 가 먼저) | `rehost_preloader_init` 안, AArch64 CPU 를 만드는 블록과 그 위 주석 |
| 핸드오프 감시 | `handoff_tick` 과 그 위 주석 |
| 섀도우 / 읽기 덮어쓰기 / catch-all / 폴링 진단 | `shadow_read`, `read_overrides`, `catchall_read`, `poll_note` |
| 전용 모델 | UART, MSDC0 + eMMC, 타이머, PMIF/PWRAP, 보안 엔진 스텁 |
| 런타임 패치 | `lk_patches`, `lkp_tick` |
| 컨테이너 적재와 코드 패치 | `place_container` |

골격이 이 소스와 다른 점: 섀도우가 첫 접근을 **4 KiB 페이지 단위로 기록**하고, 칩별 특례는 콜백 밖 표로 나가 있으며, 런타임 패치가 **대상 빌드를 식별하고 그룹 단위로
원자적으로 적용하며 적용하지 못한 행을 기록**하고, `g_post_handoff` 를 한 곳에서 정의한다 (이 소스에는 잠정 정의가 두 번 있다).

## QEMU 코어 패치

수동 진행의 `patches/qemu-rehost-core.patch` 는 머신 등록, `cpu.c` 의 `aarch64=false` 제한 해제, 그리고 이 머신이 쓰지 않는 `interrupt_handler` 훅이다. 플러그인에서
AArch32 CPU 를 만들 수 있게 하는 것은 `scripts/patch_qemu_core.py --family mediatek` 의 `cpu.c` 한 건뿐이다. 머신 등록은 이 폴더에 없다.
