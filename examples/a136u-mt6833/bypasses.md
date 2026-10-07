> **참조용 — 값 차용 금지.** 이 장부는 SM-A136U (MT6833) 한 대의 수동 진행 기록이다. 주소·오프셋·레지스터 값·패치 바이트는
> 그 펌웨어 빌드의 것이므로 다른 펌웨어에 옮기지 않는다. 펌웨어는 이 저장소에 없다.
>
> **이 사본의 알려진 문제.** 원문(아래 `---` 이후)은 고치지 않았다. 아래는 이 장부를 참조할 때 알아야 할 결함이다.
>
> 1. **#65 가 훼손되어 있다.** 표 형식 문서를 변환하는 중 필드가 잘렸다. "이유" 가 `RMR(AA64` 에서 끊기고, 이어지는 `RR) + WFI` 와
>    "QEMU 는 한 CPU 의 AArch32↔AArch64 전환 불가" 가 "부작용" 에 들어가 있다. 이 항목의 실제 이유와 부작용은 위 원문으로는
>    복원되지 않는다. 핸드오프 구현은 `machine.c` 의 `handoff_tick` 과 그 위 주석을 읽는다.
> 2. **부작용이 "(기록 없음)" 인 항목이 22개다:** #40, #50~#53, #54, #58, #62, #63, #66, #68, #74, #77, #78, #79, #80, #84, #86,
>    #98, #100, #111, #113, #114, #119, #128. 원 기록에 없던 부작용을 지어내지 않고 비워 둔 것이며, 정본 규칙(CLAUDE.md §7:
>    "부작용 항목은 정체 시 가장 먼저 참조된다") 으로는 무효 항목이다.
> 3. **제목 하나가 번호 여러 개를 묶는다:** `#42~#44, #48~#49`, `#50~#53`, `#94 → #101`, `#95 → #103`. 제목은 92개이고 번호는 100개다(#115 없음).
>    `#43` 은 `#42~#44` 범위와 단독 `#43` 제목에 두 번 나온다. 표 1행 = 우회 1건이 아니다.
> 4. **메타 줄이 없다.** 종류(M/V/S/P/I/H), 표지(F/K/L/R/X), 출처(A/B/C/D), 도출(auto/semi/manual/none/n/a) 은 이 장부에 없고,
>    조사에서 사후에 붙인 판단이다.
> 5. **장부와 `machine.c` 의 런타임 패치 표가 우회 번호로 1:1 대응하지 않는다.** 패치 표는 53행, 장부는 92건이다.
> 6. **검증을 우회한 항목이 들어 있다** (예: #36 DXCC 큐 핸드셰이크만, #55, #89 OEM digest 비교, #90 `avb_safe_memcmp` 항상 "같음",
>    #121·#122·#125·#126 잠금 상태·검증 상태·verity 처리). 이 머신의 `verify_ok` 는 `reached_bypassed` 다
>    (CLAUDE.md §11).
> 7. **원인을 검증하지 않은 항목이 있다** (표지 X): 우선 재검증 대상은 #114·#117·#118 (CFQ 패치. 원인이 eMMC DMA 모델 오류였을 가능성을
>    키트가 인정했으나 되돌려 재검증하지 않았다), #61·#62 (헤더 복사 길이, 보안 힙), #59·#92 (SSPM·spmfw 이미지가 패키지에 있었는데 "없다" 고
>    판단), #88 (원인이 아닌 것으로 판명).
> 8. **퓨즈 값 0 은 장부에 항목으로 없다.** 값이 0 이라서 `[LIB] NS-CHIP`, `[SBC] sbc_en = 0` 이 관측되어 서명 검증 경로 일부가
>    꺼진 채 통과로 찍힌다. 실제 기기의 값이라는 근거는 없다.

---

# 우회 기록 (Bypasses) — v2 머신 (#30~#130)

형식: 대상 / 이유 / 방법 / 부작용. 번호는 `08_docs/PRELOADER_V2_BRINGUP.md` §3 표와 같다.
v1(로드베이스 0x200f10, #1~#29)은 +0x600 어긋남의 부산물이라 무효이며 `bypasses_v1_archive.md` 에 보존했다.
원 기록에 없던 방법·부작용은 지어내지 않고 "(기록 없음)"으로 남겼다(해당 항목 22 곳).

---

## #30

- **대상**: 로드베이스
- **이유**: `*0x251078==0xc00`, crt0 점프 리터럴 → 진짜 prologue
- **방법**: 0x200f10 → 0x200910, 옛 포인터 우회 전부 삭제
- **부작용**: 옛 #11~#29 는 무효

## #31

- **대상**: APXGPT 0x10008000
- **이유**: udelay 헬퍼 0x2375e8
- **방법**: +0x48 = 13 MHz 카운터 (QEMU virtual clock)
- **부작용**: 배속 옵션

## #32

- **대상**: SPM PWR_STATUS
- **이유**: mtcmos 폴링 0x23664e (bit21)
- **방법**: 0x1000616c/0x10006170 = 0xffffffff
- **부작용**: 전원 상태 항상 ON

## #33

- **대상**: PMIF 0x10027000
- **이유**: 0x23375a 등
- **방법**: SW 인터페이스 FSM (STA bits[3:1])
- **부작용**: 슬레이브 레지스터는 단순 저장

## #34

- **대상**: PWRAP 0x10026000
- **이유**: 0x23375a/0x2337a0
- **방법**: WACS2 (CMD 0x880 / WDATA 0x884 / RDATA 0x894 / VLDCLR 0x8a4 / STA 0x8a8), PMIC 16bit 레지스터 파일
- **부작용**: 0x40e=0x5aa5 (DEW_READ_TEST), 0x2a=0x000a (키 놓음)

## #35

- **대상**: MSDC0 + eMMC
- **이유**: 드라이버가 실제로 쓴 레지스터만
- **방법**: CMD0/1/2/3/6/7/8/9/12/13/16/17/18/23/24/25, DMA, PIO FIFO, EXT_CSD, 이미지 읽기
- **부작용**: R1b busy → MSDC_PS=0x01ff0001

## #36

- **대상**: DXCC 0x10210000
- **이유**: 0x242304
- **방법**: 큐/IRR/완료 카운터 핸드셰이크만. 암호 연산 없음
- **부작용**: 보안 엔진 스텁 (암호 구역은 건너뛰라는 지시)

## #37

- **대상**: PMIC OTP 포트
- **이유**: assert pmic_initial_setting.c:641 (0x233310)
- **방법**: 워드 3 의 bits[15:13]=5
- **부작용**: 다른 워드는 0

## #38

- **대상**: PMIC reg 0xa1a bit2
- **이유**: 0x232a74 → 0x272d30 → 0x231b56 "Power key boot!"
- **방법**: = 1
- **부작용**: 전원키 부팅으로 판정

## #39

- **대상**: PMIC reg 0xc8e
- **이유**: "[PMIC ERROR]NO EFUSE!!" 루프 0x206156
- **방법**: 0x1000 (스텁)
- **부작용**: FG 보정값은 가짜

## #40

- **대상**: PMIC reg 0x546 bit3
- **이유**: 0x2350d8 busy 폴링
- **방법**: 읽기 시 0
- **부작용**: (기록 없음)

## #41

- **대상**: topckgen 주파수 미터 0x10000220/0x224
- **이유**: FUN_0020dfd8
- **방법**: start 비트 자동 해제, 결과 0x400 (=26 MHz)
- **부작용**: 선택 클럭 무관하게 26 MHz

## #42~#44, #48~#49

- **대상**: DRAMC NAO (0x10234xxx/0x10244xxx)
- **이유**: FUN_00221014/002210cc/00220d90, 0x2136fa
- **방법**: +0x88 응답 비트, +0x120 완료, +0x170=8, +0x80 bit2, +0x54 bit0
- **부작용**: MRW/MRR/테스트엔진 즉시 완료

## #43

- **대상**: DRAM 4 GiB 매핑
- **이유**: rank 2×2 GB
- **방법**: 0x40000000~0x13fffffff 평면 RAM
- **부작용**: DRAM PHY 동작 없음

## #45

- **대상**: LPDDR4X 모드 레지스터
- **이유**: check_qvl (dramc_top.c:1626), 표 0x251f50
- **방법**: MR5=0x01(삼성), MR8=0x10 (NAO+0x8c 상위 16비트)
- **부작용**: 4 GB 삼성 항목 선택

## #46

- **대상**: eMMC CID
- **이유**: 표 0x251f50 의 3번 항목
- **방법**: 장치 식별(MID 0x15, CBX 01, OID 00, PNM)을 머신 소스에 적지 않고 프리로더 자신의 eMMC+LPDDR4X 표 3 번째 항목(메모리 0x252060, 9 바이트)에서 머신 초기화 때 읽어 CID 로 사용
- **부작용**: 이 개체의 실제 부품명은 미상

## #47

- **대상**: 코드 패치 0x213dcc
- **이유**: rank1 RX 캘리브레이션 스윕(성공=0)
- **방법**: `movs r0,#0; bx lr`
- **부작용**: 캘리브레이션 결과값 없음

## #50~#53

- **대상**: DDRPHY NAO/AO 상태 비트
- **이유**: FUN_00210cc8, 0x20d432, 0x20d994
- **방법**: 0x10236510 b2, 0x10236010 b16/17, 0x109470b0 전부
- **부작용**: (기록 없음)

## #54

- **대상**: eFuse 컨트롤러 0x11c10000 (DTB 에 없음)
- **이유**: 0x242dd4 리터럴, "[EFUSE] Start Check"
- **방법**: bit0=ready
- **부작용**: (기록 없음)

## #55

- **대상**: DXCC LCS/OTP
- **이유**: FUN_00240f6c, 0x2412fc
- **방법**: +0xabc=1, +0xad4=5(Secure), OTP[10]=0x30000
- **부작용**: 수명주기 5 로 보고

## #56

- **대상**: TRNG 0x1020f000
- **이유**: 0x240f24
- **방법**: bit31=ready, 데이터 0
- **부작용**: 엔트로피 없음

## #57

- **대상**: RPMB
- **이유**: 0x2283xx RPMB 카운터 읽기
- **방법**: EXT_CSD[179]&7==3 일 때 JEDEC 프레임, MAC 검증 없음
- **부작용**: 키 없음

## #58

- **대상**: 키패드 KP_MEM1..5
- **이유**: FUN_002263a4 일반 경로
- **방법**: 0xffff (모두 안 눌림)
- **부작용**: (기록 없음)

## #59

- **대상**: 코드 패치 0x227e62
- **이유**: SSPM 펌웨어는 AP/BL 패키지에 없음
- **방법**: SSPM 로드 실패 분기 → 성공 경로(0x22804c)
- **부작용**: SSPM 미구동

## #60

- **대상**: gz1/gz2 파티션
- **이유**: "[GZINIT] gz1 part. ATF load fail" 이 치명적
- **방법**: tee-verified.img 사본
- **부작용**: GZ 이미지는 패키지에 없음

## #61

- **대상**: 코드 패치 0x2305e2
- **이유**: 로그 버퍼(20칸)가 파티션 테이블(0x78ea4)을 덮어씀
- **방법**: 헤더 섹터 복사 길이 0x200→0
- **부작용**: 헤더 보관 없음

## #62

- **대상**: 코드 패치 0x23648c/0x236492
- **이유**: NS-CHIP 에서 힙 리셋 호출이 없고 free 가 빈 함수
- **방법**: sec 힙 0x10c020/4 KiB → 0x400000/128 KiB
- **부작용**: (기록 없음)

## #63

- **대상**: EXT_CSD[168] RPMB_SIZE_MULT
- **이유**: FUN_00224ce8 이 RPMB 크기 ≥ 0x20000 요구(아니면 잘못된 %s 로 크래시)
- **방법**: 0x20 (4 MiB)
- **부작용**: (기록 없음)

## #64

- **대상**: chipid@0x08000000
- **이유**: 부트태그 빌더 0x224ef8 이 읽음. 이 SoC 의 hw_code 는 이미지에서 도출 불가
- **방법**: 쉐도우 블록, 값 0
- **부작용**: LK 의 hw_code 출력이 0

## #65

- **대상**: AArch32→AArch64 핸드오프
- **이유**: FUN_00227a10: RVBAR 기록 + RMR(AA64
- **방법**: 2번째 AArch64 cortex-a55(cpu1, 꺼진 채 생성). cpu0 이 WFI 스핀(0x226270) 에 들어가면 RVBAR(0x0c53c900 의 값, 여기 0x48c03000) 로 cpu1 reset·시작, R0..R14→X0..X14 복사
- **부작용**: RR) + WFI | QEMU 는 한 CPU 의 AArch32↔AArch64 전환 불가

## #66

- **대상**: RAS 오류레코드 레지스터
- **이유**: BL31 이 0x48c26770 에서 접근, QEMU 최소 RAS 는 UNDEF
- **방법**: ERRSELR/ERXFR/ERXCTLR/ERXSTATUS/ERXADDR/ERXMISC0,1 RAZ/WI 정의, ID_AA64PFR0.RAS=1
- **부작용**: (기록 없음)

## #67

- **대상**: cortex-a55 구현정의 레지스터 (crn=15)
- **이유**: BL31 0x48c10d44..0x48c10d60 이 c3_5 에 0xf0 쓰고 c3_7[7:4]==0xf 를 폴링
- **방법**: opc1 0/6 전부 RW 저장, s3_0_c15_c3_7 은 c3_5 를 반영
- **부작용**: 의미 없는 저장소

## #68

- **대상**: MPIDR_EL1
- **이유**: TEEGRIS 가 0x76a05cc8 의 8항목 표(0x81000000, 0x81000100…)에서 코어를 찾고 없으면 `b .`
- **방법**: 0x81000000 (MT 비트, Aff1=코어)
- **부작용**: (기록 없음)

## #69

- **대상**: HACC 0x1000a104
- **이유**: BL31 0x48c159d8
- **방법**: bit15=done
- **부작용**: 계산 안 함

## #70

- **대상**: 코드 패치 0x2249c0
- **이유**: gz1 파티션이 ATF 이미지여야 해서 GZ 센티널("ZGoN")이 안 서고, 그러면 부트태그에 GZ 태그가 붙고 BL33 진입점이 GZ 하이퍼바이저(0x7ee00000, 미제공)로 바뀜
- **방법**: `movs r0,#0; bx lr` ("GZ 사용 안 함")
- **부작용**: GZ 없음

## #71

- **대상**: GICv3
- **이유**: LK 가 ICC_SRE 접근(0x4825aad8)
- **방법**: arm-gicv3, 2 CPU, 분배기 0x0c000000 / 재분배기 0x0c040000, 보안확장 켬
- **부작용**: 인터럽트 소스는 아래 #75/#76 만 연결

## #72

- **대상**: DXCC +0xa78/+0xa7c
- **이유**: TEEGRIS udelay 루프 0x76a4af10
- **방법**: 13 MHz 64비트 자유 카운터
- **부작용**: 주파수 미상

## #73

- **대상**: AUXADC DAT0..15 (+0x14+4*ch)
- **이유**: LK adc_api "wait for channel[6] ready"
- **방법**: bit12=ready
- **부작용**: 값 0

## #74

- **대상**: MSDC: CMD8(0x1aa)/CMD55/ACMD41/CMD5
- **이유**: eMMC 는 SD 탐침에 응답하지 않음, 응답하면 LK 가 SD 경로로 가서 실패
- **방법**: 명령 타임아웃(INT bit9)
- **부작용**: (기록 없음)

## #75

- **대상**: MSDC0 IRQ → GIC SPI 99
- **이유**: DTB interrupts <0 0x63 4>
- **방법**: 레벨 = INT & INTEN
- **부작용**: 환경변수 REHOST_MSDC_IRQ 로 켬

## #76

- **대상**: APXGPT 1..5 타이머 + IRQ(SPI 211)
- **이유**: LK 스케줄러 틱 = GPT5 (CMP 0x147 @32k = 10 ms)
- **방법**: CON/CLK/CNT/CMP, CLK bit4=32.768 kHz, one-shot/repeat, IRQSTA/ACK
- **부작용**: REHOST_TICK_SLOW 로 틱 주기 늘림

## #77

- **대상**: CPU affinity
- **이유**: GICD_IROUTER=0 → affinity 0
- **방법**: cpu1 mp-affinity 0, cpu0 0x100
- **부작용**: (기록 없음)

## #78

- **대상**: MSDC 디스크립터 DMA
- **이유**: LK 의 DMA_SA 는 GPD 주소였고 기본모드 모델이 디스크립터와 LK 의 이벤트 객체를 덮어씀(타이머/ISR 크래시의 원인)
- **방법**: DMA_CTRL bit8: GPD(+BD 체인) 를 따라 복사, HWO 해제
- **부작용**: (기록 없음)

## #79

- **대상**: UART LSR
- **이유**: LK putc 0x48292d0a
- **방법**: 0x60 (THRE|TEMT)
- **부작용**: (기록 없음)

## #80

- **대상**: 코드 패치 0x230da8
- **이유**: 키를 누르지 않아도 프리로더/LK 로그 유지. 키를 누르면(REHOST_LOG_KEY) LK 가 홈키를 읽어 다른 모드로 감
- **방법**: `cbnz r0,0x230dba` → `b 0x230dc4` (UART 로그 끄는 분기 건너뜀)
- **부작용**: (기록 없음)

## #81

- **대상**: PIT 파티션
- **이유**: LK `get_pit_partinfo_byname` 이 파티션 "pit" 를 읽고 magic 을 검사(0x48254128). 없으면 "emergency download"
- **방법**: GPT 에 `pit`(16 KiB, Odin PIT: magic 0x12349876 + 132바이트 항목, 대/소문자 이름 둘 다)
- **부작용**: 항목의 시작/크기만 GPT 를 반영, 나머지 필드는 추정

## #82

- **대상**: 추가 파티션
- **이유**: LK 문자열/로그의 "partition not found"
- **방법**: `boot`, `dtbo`, `vbmeta`, `vbmeta_system`, `recovery`, `misc`(AP 이미지), `param`, `up_param`, `efuse`(BL 이미지, lz4 해제), 나머지 LK 가 이름으로 찾는 파티션(persistent/efs/steady/seccfg/proinfo/nvram/expdb/frp/metadata/prism/optics/hidden/cache/carrier/odm/vendor_boot/para/tzar/spmfw/audio/sec1/cam_vpu1/md1img/logo/nvcfg/nvdata/boot_para/btd/super/userdata)는 0 으로 채운 빈 파티션
- **부작용**: 빈 파티션 = 내용 미상

## #83

- **대상**: REHOST_LOG_KEY
- **이유**: pmic 0x2a bit3
- **방법**: 빈 문자열이면 "키 안 누름" (이전엔 빈 값도 누름으로 처리되어 LK 가 `Key : VOL_DN` 으로 읽었다)
- **부작용**: 앞서 시험한 GPIO DIN/ADC/SPMI 우회 3건은 이 버그의 증상이라 되돌림

## #84

- **대상**: cpu1 power_state
- **이유**: start-powered-off 로 만든 CPU 는 `arm_cpu_has_work()` 가 PSCI_OFF 동안 항상 거짓 → LK 의 첫 WFI(idle 스레드)에서 영영 안 깨어나 스케줄러 틱이 죽음(GPT5 IRQ 19번째 이후 미소비). 이게 "LK 가 로고 뒤에 멈춤" 의 진짜 원인이었음
- **방법**: 시작 시 `PSCI_ON` 으로 설정
- **부작용**: (기록 없음)

## #85

- **대상**: GPT 13 MHz 카운터 배속
- **이유**: 배속 카운터는 32비트가 4.3 s/배속 마다 감김
- **방법**: 핸드오프 시 REHOST_TIME_SCALE 을 1 로
- **부작용**: 프리로더 단계 대기는 여전히 배속 사용

## #86

- **대상**: MSDC0 IRQ(SPI 99) 상시 연결
- **이유**: LK `msdc_lk_intr_wait` 가 이 인터럽트를 기다림(없으면 DMA data error)
- **방법**: 머신 소스에서 확인 — MSDC0 인터럽트 라인을 `qdev_get_gpio_in(gic, 99)`(GIC SPI 99)에 연결하고 레벨을 `INT & INTEN` 으로 유지(#75 와 같은 연결)
- **부작용**: (기록 없음)

## #87

- **대상**: PMIC AUXADC 결과 레지스터
- **이유**: 프리로더 "pmic_get_auxadc_value Time out"
- **방법**: 0x10b0 등 12개: bit15=ready, ch0(BATADC) raw 20800 = 4.0 V
- **부작용**: 다른 채널 0

## #88

- **대상**: LK 런타임 코드 패치
- **이유**: LK 부트모드 디스패처가 9 를 받음(배터리/충전기 입력 미모델)
- **방법**: 가상시간 폴링으로 LK 메모리의 원본 바이트 확인 후 패치(REHOST_LK_PATCHES). 0x4822b9b4: boot mode 9(LOW_POWER_OFF_CHARGING) → 0
- **부작용**: 모드 0 으로 바꿔도 LK 는 똑같이 Odin 으로 감 → 이 패치는 원인이 아니었음, 기본 비활성

## #89

- **대상**: 0x482c798a (oem img 인증 FUN_482c794c)
- **이유**: digest 비교 0x7021 → overlay dtb 미초기화 → `sec_check_download=7` → Odin
- **방법**: `cbz r0,pass` → `b pass`
- **부작용**: Samsung 서명 자료 재현 불가

## #90

- **대상**: 0x482b9510/12 (`avb_safe_memcmp`)
- **이유**: LK 의 SHA 는 SMC 0x8200010b~f → BL31 → DXCC 하드웨어이고 DXCC 모델은 핸드셰이크만 해서 모든 digest 가 틀림(`avb_vbmeta_image.c:207 Hash does not match`)
- **방법**: `movs r0,#0; bx lr`
- **부작용**: 모든 AVB digest/서명패딩 비교 무력화

## #91

- **대상**: 0x482861a0
- **이유**: prism/optics 가 CUSTOM 으로 판정되어 red → 다운로드 모드. 상태 이름 점프테이블(0x48285fa6)에서 red=3 확인
- **방법**: `beq red_state_warning` → nop (boot state 값 3 = red)
- **부작용**: red 상태로 계속 부팅

## #92

- **대상**: 0x482928d2, 0x482928e8 (SPM 펌웨어 로더)
- **이유**: spmfw 파티션이 펌웨어에 없음 → SBC 인증서 컨테이너 없음(0x6003) → red_state_warning
- **방법**: `bne cert_vfy_fail` 두 곳 nop
- **부작용**: SPM 펌웨어 없이 진행(전원관리만 영향)

## #93

- **대상**: 0x482537e4 (SECURE CHECK 에러 화면)
- **이유**: md1img 가 없어 모뎀 로더가 이 함수를 호출 → secure_error.jpg 표시 후 key 8 까지 무한 대기
- **방법**: `push {r4,lr}` → `bx lr`
- **부작용**: 모뎀 없이 진행

## #94 → #101

- **대상**: INFRACFG_AO 버스 프로텍트
- **이유**: LK(0x482197d0: 0x12a0 에 0x80 쓰고 0x1228 bit7 폴링), 커널 clk-mt6833-pg.c(VDE: SET 0x2d4, STA1 0x2ec) 코드와 레지스터 덤프
- **방법**: SET 쓰기 → STA 비트 즉시 세트, SET+4(CLR) 쓰기 → 해제. 그룹: 0x2a0→0x228, 0xb84→0xb90, 0x2a8→0x258, 0x2d4→0x2ec, 0x714→0x724, 0xdcc→0xdd8
- **부작용**: 일부 그룹의 SET/CLR 오프셋은 EN+4/EN+8 패턴에서 **추정**

## #95 → #103

- **대상**: SPM PWR_STATUS/2ND (0x1000616c/0x10006170)
- **이유**: LK 모뎀 전원차단 루프(bit0 폴링), 커널 spm_mtcmos_ctrl_*_pwr
- **방법**: 핸드오프 이후 비트 k = PWR_CON[0x300+4k] 의 PWR_ON(bit2)과 PWR_ON_2ND(bit3). 핸드오프 전은 기존 all-ones
- **부작용**: 비트 k 와 레지스터의 대응은 MD1(bit0)만 확인, 나머지는 추정

## #96

- **대상**: 0x0c53a840 읽기
- **이유**: BL31 0x48c0c5f4: `ldr w0,[0x0c53a840]; cmp w0,#0xc001; b.ne` 로 대기(커널 점프 SMC 처리)
- **방법**: 0xc001
- **부작용**: 상수는 유일한 근거

## #97

- **대상**: CPU 생성 순서
- **이유**: BL31 은 MPIDR(Aff0=0)로 core 0 → 프레임 0 만 그룹/보안 PPI 설정. 프레임 1 은 IGROUPR0=0(모든 PPI secure)이라 커널이 NS 물리 타이머 PPI(30)를 켤 수 없어 tick 이 없었고 init_heavy_tlb 이후 idle 로 영원히 정지(GIC 레지스터를 gdb 로 직접 읽어 확인)
- **방법**: AArch64 CPU 를 먼저 생성(QEMU cpu index 0 = GIC CPU 0 = redistributor 프레임 0)
- **부작용**: 프리로더 AArch32 CPU 는 index 1

## #98

- **대상**: SPM CPU_PWR_STATUS 0x10006174
- **이유**: 커널 PSCI CPU_ON → BL31 이 0x48c13100 에서 코어 비트(마스크 2)가 세트될 때까지 폴링
- **방법**: 0xffffffff
- **부작용**: (기록 없음)

## #99

- **대상**: PMIC HWCID (pwrap 레지스터 0x8)
- **이유**: 커널 mt6358_probe: 상위바이트 0x57/58/59/66/90 만 허용, 아니면 오류경로에서 NULL 역참조(irq_domain_remove)
- **방법**: 핸드오프 후 0x5900
- **부작용**: 하위(리비전) 바이트 미상 = 0

## #100

- **대상**: `sspm_ipi_timeout_cb` 0xffffff80087cef24
- **이유**: SSPM 펌웨어가 없어 PMIC regmap IPI 가 타임아웃 → AEE + `kernel BUG at sspm_ipi_timeout_cb.c:61` → panic → PSCI reset
- **방법**: 첫 명령 `ret`
- **부작용**: (기록 없음)

## #102

- **대상**: SPM *_PWR_CON (0x10006300~3ff) 읽기
- **이유**: clk-mt6833-pg.c: bit8 세트 후 bit12 세트 대기, 해제 후 클리어 대기
- **방법**: ACK 비트[15:12] = PDN 비트[11:8]
- **부작용**: 모든 도메인에 일괄 적용

## #104

- **대상**: `read_all_tc_temperature` 0xffffff8008a354f8 의 BUG 분기 2곳
- **이유**: LVTS 열센서 미모델링(원시값 0) → 20 회 재시도 후 `kernel BUG at mtk_ts_cpu_noBank.c:1625`
- **방법**: 함수 epilogue 로 분기
- **부작용**: 온도값 무의미

## #105

- **대상**: `mtk_ipi_send_compl` 0xffffff80085c6188
- **이유**: PMIC 레지스터마다 2 s 타임아웃으로 pid 1 이 극도로 느림. 처음엔 -6 으로 즉시 실패시켰으나 PMIC 레귤레이터가 등록되지 않아 eem/pbm 에서 `ERR_PTR(-EPROBE_DEFER)` 역참조 Oops 가 반복돼 성공으로 변경
- **방법**: `mov w0,wzr; ret` (성공으로 즉시 반환)
- **부작용**: PMIC 읽기값은 쓰레기

## #106

- **대상**: `find_panel_ext` 0xffffff80086c28c0
- **이유**: LCM 없음(LK: islcmfound=0, lcdtype=0) → Samsung 패널 리스트 손상 → 쓰레기 포인터 역참조
- **방법**: `mov x0,xzr; ret`
- **부작용**: 패널 없음

## #107

- **대상**: `mtk_dsi_probe` 0xffffff80086a133c
- **이유**: 패널 재프로브가 10 ms 마다 반복되며 pstore 링(256 KiB)을 수백 ms 에 채움
- **방법**: `movn w0,#18; ret` (-ENODEV)
- **부작용**: 디스플레이 없음

## #108

- **대상**: `eem_probe` 0xffffff8008737a40
- **이유**: `regulator_set_mode(ERR_PTR(-EPROBE_DEFER)+0x50)` Oops
- **방법**: -ENODEV
- **부작용**: EEM(CPU 전압 튜닝) 없음

## #109

- **대상**: 커널 `psci_cpu_boot` 0xffffff80080903b8 (물리 0x400903f6)
- **이유**: QEMU 에 CPU 가 2개뿐인데 DT 는 8개: BL31 이 CPU_ON 에 INVALID_PARAMS 를 반환하고 PPM 핫플러그 스레드가 `psci: failed to boot CPUn (-22)` 를 초당 수천 번 출력해 pstore 링을 1 초 분량으로 만들고 TCG 단일 스레드를 점유
- **방법**: `mov w20,w0` → `mov w20,wzr` (CPU_ON 이 성공했다고 보고)
- **부작용**: 코어는 올라오지 않고 커널이 자체 타임아웃으로 포기

## #110

- **대상**: MSDC `DMA_SA_H4B` (0x8c) 와 GPD/BD 의 H4 비트
- **이유**: 커널 msdc 드라이버는 4 GiB 위의 버퍼를 쓴다. EXT_CSD(CMD8) 가 0x128ee800(비 RAM)에 써져 SEC_COUNT 가 0 → `mmcblk0: ... 0 B`, 파티션 없음. 커널 구간에서만 새로 나타나는 레지스터 쓰기를 기록(`REHOST_MSDC_TRACE2`)해 0x8c 를 찾음
- **방법**: 36 비트 DMA 주소: GPD 주소 = (H4<<32)|DMA_SA, GPD/BD 의 PTR_H4(비트 31:28)·NEXT_H4(27:24) 반영, 기본 DMA 경로도 동일
- **부작용**: LK 는 상위 비트를 모두 0 으로 써 영향 없음

## #111

- **대상**: eMMC CSD/EXT_CSD 쓰기 그룹
- **이유**: Samsung `add_partition` 검사 `Start 0x7800 of disk mmcblk0 not write group aligned` (16 MiB 단위였음)
- **방법**: CSD ERASE_GRP_SIZE/MULT/WP_GRP_SIZE 0x1f → 0, EXT_CSD[224]=[221]=1
- **부작용**: (기록 없음)

## #112

- **대상**: eMMC CMD30/CMD31 (쓰기보호 조회)
- **이유**: 파티션 추가 때마다 CMD31 을 PIO 로 읽고 `msdc0 -> XXX PIO Data Timeout: CMD<31>` → `mmcblk0: pN could not be added: 5`
- **방법**: 4/8 바이트 0 응답
- **부작용**: 보호된 그룹 없음

## #113

- **대상**: eMMC CMD35/36/38 (erase)
- **이유**: init 이 metadata 를 BLKDISCARD 하려 함. 다만 커널 mmc 코어가 명령을 보내기 전에 EINVAL 로 끝내(원인 미확정) 이 모델은 현재 쓰이지 않는다
- **방법**: 범위를 이미지에서 0 으로 (디스크에는 저장 안 함)
- **부작용**: (기록 없음)

## #114

- **대상**: 커널 `cfq_completed_request` 0xffffff8008505540
- **이유**: metadata 를 읽은 요청이 완료될 때 CFQ 큐 포인터가 NULL (`Unable to handle kernel NULL pointer dereference at virtual address 000000b8`, mmcqd/0 Oops). I/O 스케줄러 통계용 훅
- **방법**: 첫 명령 `ret`
- **부작용**: (기록 없음)

## #116

- **대상**: eMMC 이미지 매핑
- **이유**: 8 GB 이미지를 RAM 에 복사할 수 없음; LK 단계 쓰기는 디스크에 안 남김
- **방법**: `MAP_PRIVATE|MAP_NORESERVE` mmap(수 GB 이미지), 핸드오프 후 쓰기는 이미지에 반영(`emmc_write_done`)
- **부작용**: 쓰기는 프로세스 내에서만 유지(파일 불변)

## #117

- **대상**: 커널 `cfq_put_request` 0xffffff8008506064
- **이유**: I/O 스케줄러(CFQ) 통계/큐 포인터가 NULL 이라 완료 경로에서 NULL 역참조
- **방법**: 첫 명령 `ret`
- **부작용**: CFQ 통계 누락

## #118

- **대상**: 커널 `cfq_set_request` 0xffffff8008505d50
- **이유**: 같은 이유(요청마다 elv 데이터 할당 실패로 보고 → `__get_request: request aux data allocation failed` 경고만 남고 I/O 는 진행)
- **방법**: `movn w0,#11; ret` (-ENOMEM)
- **부작용**: 경고 로그가 요청마다 나옴

## #119

- **대상**: MSDC DMA 1 명령 1 회
- **이유**: 위 원인 1 (반복 실행)
- **방법**: `rd_dma_done` 플래그: descriptor-DMA 는 명령당 한 번만 실행
- **부작용**: (기록 없음)

## #120

- **대상**: MSDC `DMA_CTRL.START` / basic-DMA 길이 / GPD HWO
- **이유**: 위 원인 1~3. `REHOST_MSDC_TRACE6`(0x10/0x14/0x8c~0xa8 쓰기 순서)로 확인: 커널은 `0x9c=2; 0x98=0x6403` 처럼 DMA_SA 를 갱신하지 않은 채 START 가 포함된 RMW 를 쓴다
- **방법**: ① START 는 write-1 pulse: 저장값·읽기값에서 bit0 제거(원시 레지스터 저장소 포함), 데이터 명령이 아직 없으면 `dma_armed` 로 기억했다가 명령 도착 때 실행 ② basic-DMA 는 START 당 `min(DMA_LEN, 남은 길이)` 만 전송하고 순서대로 이어서 전달 ③ GPD 는 HWO=1 일 때만 처리
- **부작용**: 실제 HW 의 START 동작과 일치

## #121

- **대상**: LK `FUN_482b422c`(AVB ops get_device_unlocked) 0x482b424c
- **이유**: seccfg 가 0 채움이라 lock_state=2(잠김)로 읽혀 cmdline 이 `device_state=locked`. 함수는 `unlocked = !(lock_state ∈ {1,2,4})` 계산
- **방법**: `ldr r2,[sp,#4]`(019a) → `movs r2,#3`(0322): lock_state 를 LKS_UNLOCK 으로
- **부작용**: seccfg 자체는 그대로(해시가 하드웨어 키에 묶임); `[AVB20] lock_state = 0x2` 로그는 그대로 출력

## #122

- **대상**: LK `FUN_48286208`(boot state → cmdline 문자열) TBB 표 0x4828621a
- **이유**: LK 의 상태는 prism/optics 서명 검사 실패로 RED(3). 표: state 0 green, 1 yellow, 2 orange, 3 red → 분기 `14 02 0e 08`. 커널 cmdline 이 `verifiedbootstate=orange` 가 됨
- **방법**: state 3(red) 항목 `08` → `0e`(orange 분기)
- **부작용**: LK 내부 상태는 red 그대로(경고 화면은 #91 로 생략); 이후 init 이 dm-verity 오류를 허용

## #123

- **대상**: 커널 `softdog_fire` 0xffffff8008c88990 (PA 0x40c88990)
- **이유**: userspace 가 softdog 를 600 s 마진으로 켜는데 아무도 ping 하지 않아 ~13 분에 `Software Watchdog Timer expired` 패닉
- **방법**: 패닉 경로 첫 명령을 정상 리턴으로 분기
- **부작용**: 워치독 무력화

## #124

- **대상**: `/vendor/etc/init/teegris_v4.rc` (vendor 블록 7261)
- **이유**: TEEGRIS 가 없어 tzdaemon 이 status 1 로 죽고 init 이 `on post-fs` 에서 영원히 대기
- **방법**: `wait_for_prop vendor.tz*daemon Ready` → `setprop … Ready`(같은 길이), `write /proc/iccc_ready 1` 주석 처리
- **부작용**: TEE 구역 스텁(사용자 지시)

## #125

- **대상**: LK 의 veritymode 문자열 선택 — PC 상대 리터럴 0x482b50b0, 0x482b50c0 ("enforcing" 을 가리키던 것)
- **이유**: vendor 수정 후 해시트리 불일치
- **방법**: 두 리터럴의 하위 halfword 를 숫자로만 바꿔(0x0348→0x0380, 0x0326→0x035e) LK 가 이미 가진 "logging" 문자열(0x48325368)을 가리키게 함 — 머신 소스에 문자열 없음
- **부작용**: vbmeta HASHTREE_DISABLED 플래그는 LK 가 `authinfo vbmeta` 후 키 입력을 영원히 기다려 불가

## #126

- **대상**: 커널 dm-verity 손상 핸들러 0xffffff8008caed4c (PA 0x40caed4c)
- **이유**: Samsung verity 는 모드와 무관하게 `panic("dmv corrupt")`; 수정한 rc/fstab 블록이 FEC(RS(255,253), 오류 1 개까지 정정)로 원복되므로 같은 stripe(간격 470/474 블록)의 미사용 블록(`/etc/recovery-resource.dat`)을 손상시켜 FEC 를 무력화
- **방법**: `mov w0,wzr; ret`
- **부작용**: **손상 데이터가 조용히 통과**(진짜 손상도 가려짐 — #130 발견 경위)

## #127

- **대상**: `/vendor/etc/fstab.emmc`(init 이 실제로 읽는 파일; `mount_all --late` 에 인자 없음) 의 userdata 줄
- **이유**: 실제 줄은 keymaster/TEE 가 만든 메타데이터 암호화 키를 요구, vold 가 userdata 를 포맷·언락하지 못해 `Rebooting into recovery`
- **방법**: `f2fs`→`ext4`, 옵션·플래그를 같은 길이로 교체(`fileencryption`/`keydirectory` 제거)
- **부작용**: 암호화 없는 /data

## #128

- **대상**: userdata 파티션
- **이유**: fstab 에 `formattable` 이 없어 빈 파티션은 마운트 실패
- **방법**: 호스트 `mke2fs -t ext4` 2 GiB 이미지를 미리 기록(`mk8.sh`)
- **부작용**: (기록 없음)

## #129

- **대상**: 커널 `idletime_get` 0xffffff80086baed4 (PA 0x406baed4)
- **이유**: `mtkPowerAIDL` HAL 이 읽는 debugfs 속성의 getter 가 MTK idle 드라이버 전역 객체(미생성)를 `+0x340` 역참조
- **방법**: `str xzr,[x1]; mov w0,wzr; ret`
- **부작용**: SPM/MCUSYS idle 통계 없음

## #130

- **대상**: MSDC 쓰기 경로
- **이유**: `BLK_NUM` 은 상한일 뿐인데 모델은 그 길이만큼 모일 때까지 기다렸다 한 번에 기록 → 적게 오면 명령이 끝나지 않아 **데이터 유실**: apexd 가 `/data` 에 푼 ART APEX 에 0 블록 33 개(3833–3839, 4070–4095)가 있어 zygote 가 `libart!Mutex::ExclusiveLock` NULL 역참조로 계속 죽었음
- **방법**: START 마다 **실제로 옮긴 바이트**를 명령의 현재 위치에 즉시 기록, 다음 데이터 명령/CMD12 에서 쓰기 상태 정리 (RPMB 만 기존 방식)
- **부작용**: 쓰기 상태를 정리하지 않으면 다음 읽기의 START 를 쓰기로 오인해 LK 가 Odin 다운로드 모드로 빠짐(`sec_check_download: 7`)
