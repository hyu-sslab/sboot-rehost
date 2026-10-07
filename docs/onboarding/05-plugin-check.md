# 05. 설치와 버전 확인

## 1. 정체

| 항목 | 값 |
|---|---|
| 플러그인 이름 | `sboot-rehost` |
| 마켓플레이스 | `sboot-rehost-marketplace` |
| 저장소 버전 | `.claude-plugin/plugin.json` 의 `version` (이 문서에 적지 않는다) |
| 명령 접두사 | `/sboot-rehost:` |

---

## 2. 세션이 쓰는 버전

**세션은 시작 시점에 로드한 버전을 계속 쓴다.** 저장소나 캐시를 갱신해도 실행 중인
세션이 쓰는 것은 로드 시점의 것이다.

- 실패가 눈에 띄지 않는다. 루프는 돌고 로그는 정상인데 동작이 이전 릴리스의 것이다
- 두 버전 전에 고쳐진 문제를 다시 디버깅하게 된다
- `/sboot-rehost:start` 는 무엇보다 먼저 버전을 확인하고 어긋나면 `BLOCKED_VERSION` 으로
  **정지한다**
- `/sboot-rehost:init` 은 **옛 버전 캐시를 실제로 지운다.** 다만 이미 로드된 것은 지워도
  바뀌지 않으므로, 옛 버전을 로드 중이면 거기서 멈추고 재시작을 요구한다

```bash
bash scripts/check_version.sh "$PLUGIN_DIR"
```

| 값 | 뜻 |
|---|---|
| `running` | 지금 실행되는 스크립트가 속한 버전 |
| `registered` | **세션이 실제로 로드한 버전** (스킬·에이전트의 출처) |
| `available` | 이 컴퓨터에 있는 최신 버전 |

- `registered` < `available` 이면 스킬과 에이전트가 이전 세대의 것이다
- `running` ≠ `registered` 면 스크립트와 프롬프트가 서로 다른 세대일 수 있다
- 판정 불가(작업 사본 실행, 캐시 없음)는 **막지 않고 사유를 기록한다**

### 수동 확인

```bash
# 세션이 로드한 버전
python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.claude/plugins/installed_plugins.json')))
for k,v in d['plugins'].items():
    if 'sboot' in k:
        for e in v: print(e['version'], e['scope'], e['installPath'])"

# 이 컴퓨터에 있는 버전들
ls ~/.claude/plugins/cache/sboot-rehost-marketplace/sboot-rehost/
```

---

## 3. 어긋났을 때

```
/plugin marketplace update sboot-rehost-marketplace    # 카탈로그 갱신
/plugin install sboot-rehost@sboot-rehost-marketplace  # 등록을 최신으로
/reload-plugins                                        # 재시작 없이 적용
        ↓ 그래도 안 되면
Claude Code 재시작
        ↓ 그래도 안 되면
rm -rf ~/.claude/plugins/cache                         # 캐시 삭제 후 재설치
```

VS Code 확장이면 `/plugins` → Marketplaces 탭 → 새로고침 → 재시작.

### 가장 빠른 판별

명령 목록에 **`/sboot-rehost:start`** 가 보이면 최신이다.

| 보이는 것 | 버전 |
|---|---|
| `init` `start` `status` `export` | v0.23.0 이상 |
| `start` 는 있으나 `init` 이 없음 | v0.22.x |
| `rehost-full` 은 있으나 `start` 가 없음 | v0.19.0 ~ v0.20.x |
| `rehost-bootloader` · `rehost-kernel` 만 | v0.19.0 이전 |

---

## 4. 설치

```
/plugin marketplace add hyu-sslab/sboot-rehost
/plugin install sboot-rehost@sboot-rehost-marketplace
```

---

## 5. 구성 요소 확인

```bash
V=$(ls ~/.claude/plugins/cache/sboot-rehost-marketplace/sboot-rehost/ | sort -V | tail -1)   # 가장 높은 버전
R=~/.claude/plugins/cache/sboot-rehost-marketplace/sboot-rehost/$V
ls $R/skills/    # init start status export  (넷뿐이어야 한다)
ls $R/agents/    # static-analyzer supervisor fault-classifier fixer-* verifier
ls $R/scripts/   # check_version.sh purge_cache.sh stage_map.py build_lu.py ...
```

| 있어야 하는 것 | 없으면 |
|---|---|
| `skills/init/` · `skills/start/` | v0.23.0 이전 |
| `scripts/purge_cache.sh` | v0.25.0 이전 |
| `scripts/stage_map.py` · `build_lu.py` | v0.19.0 이전 |
| `knowledge/faults_unified.md` | v0.19.0 이전 |

---

## 6. 실행 환경

`check_env.sh` 가 루프 전에 확인한다. 하나라도 없으면 `BLOCKED_ENV`.

| 항목 | 용도 |
|---|---|
| QEMU (aarch64) | 실행 |
| ninja | 머신 재빌드 |
| python3 + capstone | 정적 도출 |
| dtc 또는 fdtdump | DTB 파싱 (F2 이상) |
| lz4 | BL 패키지의 `.lz4` 해제 |
| simg2img | sparse 이미지를 raw 로 (F2 이상) |
| WSL | 셸이 Windows 인 경우 |

`~/.sboot/env.json`(현재 환경)이 플러그인의 `env_manifest.json`(요구 환경)과 어긋나면 `BLOCKED_ENV` 로
`init` 을 안내한다. 판정은 플러그인 버전이 아니라 **환경 개정 번호**(`env_revision`)와 QEMU 버전, pip 최소
버전으로 한다. QEMU 를 환경변수로 직접 지정하면 이 비교는 건너뛰고 `skipped` 로 보고한다.

`init` 은 백그라운드로 돌아 비밀번호에 답할 사람이 없다. 그래서 apt 패키지가 실제로 필요한데 root 가 아니고
`sudo -n true` 가 실패하면 아무것도 설치하거나 지우기 전에 종료코드 7(`BLOCKED_ENV`)로 멈추고, 사용자가 터미널에서
한 번 실행할 `apt-get` 줄을 안내한다. 그 뒤 `init` 을 다시 부르면 이어서 진행한다.
