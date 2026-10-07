# 03. 부팅 매체와 스토리지 컨트롤러

## 1. 왜 매체가 필요한가

커널을 QEMU 가 넘겨주지 않으므로, 부트로더가 기기에서 하던 대로
**컨트롤러 기동 → 파티션 테이블 읽기 → 이름으로 조회 → 이미지 추출**을 한다.

| 읽는 주체 | 무엇을 | 비고 |
|---|---|---|
| 첫 스테이지 | 파티션 테이블 | 앞 단계의 함수 포인터로 읽는다. **컨트롤러 모델 불필요** |
| 부트로더 | boot image · 검증 자료 | 자체 드라이버로 구동 |
| 커널 | rootfs | 빌트인 벤더 드라이버로 **같은 컨트롤러** 구동 |

**같은 모델을 두 드라이버가 차례로 구동한다.** 한쪽에 맞춘 모델은 다른 쪽에서 깨지므로
이 구조 자체가 검증 장치다.

---

## 2. UFS 와 LUN

| 계층 | 역할 |
|---|---|
| UFSHCI 레지스터 | 호스트가 명령을 올리고 완료를 확인하는 창구 |
| UTRD | 전송 요청 서술자 |
| UPIU | 명령·응답 패킷. **LUN 은 헤더 3번째 바이트** |
| PRDT | 데이터 스캐터 목록. 항목 간격이 벤더 확장으로 넓어질 수 있다 |

LUN 을 잘못 읽으면 장치를 붙이고도 파티션을 열거하지 못한다.

---

## 3. 매체 합성 (`build_lu.py`)

```bash
bash scripts/py.sh build_lu.py <workdir> --out <workdir>/fw/lu0.img
```

보호 MBR, 주 헤더, 128개 엔트리 배열, 백업 헤더, 각각의 CRC32 를 갖춘 GPT 디스크를 만든다.

```json
{
  "block_size": 4096,
  "total_bytes": 13288484864,
  "partitions": [
    {"name": "boot",       "source": "fw/boot.img"},
    {"name": "vbmeta",     "source": "fw/vbmeta.img"},
    {"name": "keystorage", "source": "02_unpacked/keystorage.bin"}
  ]
}
```

### 파티션 이름은 도출값

- 부트로더는 파티션을 **이름으로** 조회한다. 지어낸 이름은 영원히 찾지 못한다
- 실패가 한참 뒤 검증 오류나 조용한 다운로드 모드 진입으로 나타난다
- 이름은 `lu_manifest.json` 에서 온다. static-analyzer 가 부트로더 문자열에서 도출
- 매니페스트가 없으면 기본 레이아웃을 쓰되 **기본값을 썼다고 결과에 명시**한다. 한 벤더의 기본 이름
  (`keystorage` · `param` · `up_param`)은 `--family exynos` 일 때만 들어가고, 다른 계열(과 eMMC)은 그 이름이
  없는 중립 레이아웃이다. `--family` 를 생략하면 예전 동작(Exynos 기본값)과 결과의 `warning_family` 다

### 블록 크기

512 와 4096 중 어느 쪽인지는 컨트롤러 보고값과 GPT 서명 위치로 확정한다.
어긋나면 첫 블록만 읽고 서명을 못 찾거나, 그럴듯한 쓰레기를 읽는다.

### sparse 이미지

- `system.img` · `super.img` 는 AP 패키지에서 **sparse 포맷**으로 나온다
- 그대로 복사하면 파티션을 파싱하지 못하고, 결함이 한참 뒤 서명 검증 실패로 나타난다
- `build_lu.py` 는 매직 `0xed26ff3a` 를 검사해 발견하면 **정지한다**

```bash
simg2img system.img system.raw
```

### 매체 종류 (eMMC · UFS)와 항목의 출처 종류

- 매체 종류는 `detect_medium.py` 가 판정한다. **부트로더 로그의 초기화 줄**이 1순위이고 DTB 노드가
  2순위이며, 못 정하면 `unknown` 이다 (DTB 에 UFS 호스트 노드가 있다는 사실만으로는 정하지 않는다).
  `build_lu.py --medium emmc` 는 512 바이트 블록을 쓴다
- 매니페스트 항목은 출처 종류 `kind`(`firmware` · `zero` · `synthesized` · `forged` · `modified`)를
  적을 수 있고, 결과 옆의 `lu_provenance.json` 에 파티션별로 남는다. **우리가 만든 바이트(`synthesized` ·
  `forged`)는 검증의 참조 집합에서 빠진다.** 우리가 쓴 바이트가 "펌웨어에 있는 문자열"의 근거가 되면
  출력 출처 게이트가 자기 자신을 확인하게 된다
- 펌웨어 바이트를 고쳤으면(`modified`) 우회 기록에 이미지 수정(종류 `I`)으로 적는다
- 벤더 고유 구조(파티션 표, 부트 파라미터, 위조한 체인 파티션)는 `build_lu.py` 가 만들지 않는다.
  에이전트가 펌웨어별로 도출해 만든 파일을 `synthesized` · `forged` 로 넘긴다

### 커맨드라인은 계획이 이름 붙인 파티션에

- 부트로더가 `console=ram` 을 고르면 커널 로그가 RAM 버퍼로 간다
- static-analyzer 가 `cmdline_plan.json` 에 도출 (`partition`: 부트로더가 커맨드라인을 읽는 파티션의
  이름, 매니페스트와 같은 이름) → `build_lu.py` 가 **그 파티션에** 기록
- 커맨드라인이 파티션에서 오지 않으면(부트로더에 내장, 부트 이미지 헤더 등) 쓰지 않고
  `warning_cmdline` 으로 이유를 알린다. 계획이 파티션을 말하지 않고 `param` 이라는 파티션이 있으면
  거기에 쓰는 폴백은 `--family exynos` 일 때만 있고(파이프라인이 항상 `--family` 를 넘긴다) 그 이름이
  추측이라 `warning_cmdline_target` 으로 알린다. 다른 계열에는 벤더 기본 이름도 폴백도 없다
- **우회가 아니다.** 부트로더 자신의 경로를 쓰고, 문자열은 이미 펌웨어 안에 있다. 어느 파티션인지는
  펌웨어마다 도출한다 (예: Exynos S-Boot 는 PARAM 을 `setup_param_info` → `sbl_set_bootargs` 로
  읽는다. 한 부트로더의 예이지 규칙이 아니다)
- 매체 종류(eMMC·UFS)를 정한 근거가 없으면 `warning_medium` 이 알린다 (UFS 기본값은 이전 호환)

### 총 크기 고정

**30 MiB 만 늘려도** 부트로더가 GPT 를 재작성하고 신규 프로비저닝으로 간주해 전원을 내린다.

```
UFS guid partition table updated. → Make New Param Env File..
  → validate_debug_part_magic: magic mis-match → [FMM] Unkonwn State[0x2f]
  → _sys_restart → 전원 차단
```

`lu_manifest.json` 에 `total_bytes` 를 고정하고, 파티션을 바꿔도 총량은 유지한다.

### 매체는 기본이 스냅샷

- 부트로더는 PARAM 과 DDI 에 **실제로 쓴다**
- 쓰기 가능으로 두면 회차가 이전 회차의 디스크 상태를 물려받는다
- 회차 루프는 "변하는 것은 머신 소스뿐"이라는 전제로 지문을 비교한다. 누적된 상태는
  변경 효과 판정, 정체 계산, 되돌리기를 모두 오염시킨다
- 기본값 `snapshot=on`. 쓰기를 봐야 하는 회차만 `MEDIUM_WRITABLE=1` 로 해제하고 기록한다

---

## 4. 컨트롤러 모델

데이터시트가 없으므로 **드라이버를 계측기로 쓴다.** 벤더 드라이버가 무엇을 폴링하고
어떤 값을 기다리는지 관찰한 뒤, 관찰한 것만 채운다.

> **4바이트 리터럴 스캔으로 MMIO 주소를 찾지 않는다.** AArch64 는 상수를 MOVZ/MOVK 로
> 조립하므로 리터럴 스캔은 우연히 일치한 바이트열을 찾고 실제 베이스는 놓친다.
> DTB 값을 기준으로 삼고 코드에서 MOVZ/MOVK 로 복원해 교차 확인한다.

| 정지점 | 신호 | 처방 |
|---|---|---|
| `poll_stall` | 같은 오프셋 읽기가 수백 회 반복 | **기다리는 비트만** 세운다 |
| `irq_edge_level` | 완료 비트를 세웠는데 타임아웃 | 레벨 트리거여야 한다. 펄스는 놓친다 |
| `is_bit_layout` | 링크는 되는데 전원 모드 전환 실패 | 비트 위치를 드라이버 마스크에서 도출 |
| `prdt_stride` | 읽기는 되는데 내용이 다름 | 스캐터 항목 간격 실측 |
| `upiu_field_off` | 장치는 붙는데 파티션이 없음 | UPIU 헤더의 LUN·길이 필드 위치 수정 |
| `block_size` | LBA0 만 읽고 GPT 서명 못 찾음 | 백킹 이미지에서 서명 위치 확인 |

상세는 `knowledge/faults_storage.md`.

**벤더 드라이버가 `.ko` 일 필요는 없다.** 빌트인(`CONFIG_SCSI_UFS_*=y`)이면 `.ko` 는
설계상 없다. `.ko` 도 없고 커널 이미지에도 없을 때만 `BLOCKED_KO` (F2 이상에서 static-analyzer 가
저장소 드라이버의 형태를 `module` · `builtin` · `absent` 로 보고하고 `absent` 일 때 파이프라인이 세운다).

---

## 5. 완료 지점

| 마일스톤 | 뜻 |
|---|---|
| `medium_up` | 링크 확립. 컨트롤러가 응답 |
| `partitions` | 부트로더의 파티션 조회 성공 |
| `partitions_up` | 커널이 파티션 열거. **커널 쪽 최소 완료** |
| `super_mounted` | 논리 파티션 마운트. 해당 이미지가 있는 펌웨어만 |

- `super.img` 가 없는 펌웨어는 마지막 줄을 낼 수 없으므로 목표에 넣지 않는다
- `partitions_up` 미도달은 컨트롤러 모델이 미완성이라는 뜻이다
