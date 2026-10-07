#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# setup_env.sh — sboot-rehost 의 의존성 자동 설치
# /sboot-rehost:init 이 호출. 사용자가 init 을 직접 부른 것이 동의이며, 실행 중 질문은 없다.
# 소요: 약 18 분 (대부분 QEMU 빌드)
#
# Usage: setup_env.sh [--dry-run] [--replace-unmarked]
#   --dry-run           설치하지 않고 무엇을 할지(JSON)만 출력한다. 막히면 종료코드 4 또는 7.
#   --replace-unmarked  표지 없는 QEMU 트리를 지우지 않고 옆으로 옮긴 뒤 새로 만든다.
#
# 환경 매니페스트 (env_manifest.json = 요구, ~/.sboot/env.json = 현재)
# -----------------------------------------------------------------
# 예전에는 ~/qemu-build/qemu-10.2.2 가 있으면 무엇으로 어떻게 빌드됐는지 묻지 않고
# 재사용했다. 그러면 옛 QEMU 가 최신 플러그인 밑에서 계속 쓰인다. 이제는 이 플러그인이
# 만들었다는 표지(<트리>/.sboot_created)가 있고 env.json 이 요구와 일치할 때만 재사용한다.
#
#   ok          일치 -> 빌드하지 않고 검사만
#   incomplete  표지는 맞고 빌드가 끝나지 않음 -> 그 트리에서 이어서 빌드
#   stale       표지는 있으나 요구와 어긋남 -> 지우고(clean_env.sh --layers L2) 새로 빌드
#   missing     없음 -> 새로 빌드
#   unmarked    표지 없는 트리가 있음 -> **지우지 않는다.** 보고하고 종료코드 4.
#               옛 setup_env.sh 가 만든 것이 확실하면 --replace-unmarked 로 옆으로 옮기고
#               새로 만든다 (이동이지 삭제가 아니다).
#
# init 은 패치를 적용하지 않은 기준(pristine) QEMU 만 만든다. 코어 패치는 계열마다 달라
# Build 에서 적용하고 그때 건드린 파일은 .sboot_touched 에 기록된다 (qemu_tree.sh).
# 그 되돌림의 원본이 되도록 소스 tarball 은 트리 옆에 둔다.
#
# sudo 사전 점검 (apt 가 실제로 필요할 때만)
# -----------------------------------------------------------------
# init 은 백그라운드로 돈다. sudo 가 비밀번호를 요구하면 apt-get 은 대답할 사람 없이 영원히
# 기다리고, 사용자는 18 분 동안 "설치 중"이라고 믿게 된다. 그래서 무엇이든 설치하거나 지우기
# 전에, root 가 아니면 `sudo -n true` (비밀번호를 묻지 않는 시험)를 먼저 해 본다. 실패하면
# 아무것도 설치·삭제하지 않고 종료코드 7 로 멈추며, 사용자가 터미널에서 한 번 실행할
# 명령을 그대로 출력한다. 그 뒤 init 을 다시 부르면 이어서 진행한다 (이미 설치된 apt
# 패키지는 dpkg-query 로 가려 sudo 없이 건너뛴다). --dry-run 도 같은 점검을 하므로
# 백그라운드를 띄우기 전에 알 수 있다.
#
# 종료코드: 0 완료 · 2 사용법/매니페스트 · 4 표지 없는 트리 때문에 중단 · 5 pip 최소 버전 미달
#           · 6 빌드 산출물이 요구 버전이 아님
#           · 7 apt 설치가 필요한데 sudo 가 비밀번호 없이 동작하지 않음 (BLOCKED_ENV)

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
MANIFEST="${ENV_MANIFEST:-$PLUGIN_DIR/env_manifest.json}"
BUILD_ROOT="${QEMU_BUILD_ROOT:-$HOME/qemu-build}"
STATE="${ENV_STATE:-$HOME/.sboot/env.json}"

DRY=0; REPLACE_UNMARKED=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --replace-unmarked) REPLACE_UNMARKED=1 ;;
        *) echo "알 수 없는 인자: $arg (사용법: setup_env.sh [--dry-run] [--replace-unmarked])" >&2; exit 2 ;;
    esac
done

if [ ! -f "$MANIFEST" ]; then
    echo "환경 매니페스트가 없습니다: $MANIFEST" >&2
    exit 2
fi

json_get() {   # $1 = file, $2 = python expression over j
    python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}
ENV_REVISION="$(json_get "$MANIFEST" 'j["env_revision"]')"
QEMU_VERSION="$(json_get "$MANIFEST" 'j["qemu_version"]')"
PLUGIN_VERSION="$(json_get "$PLUGIN_DIR/.claude-plugin/plugin.json" 'j["version"]' 2>/dev/null || echo unknown)"
PIP_SPECS=()
while IFS= read -r spec; do PIP_SPECS+=("$spec"); done < <(python3 - "$MANIFEST" <<'PY'
import json, sys
for name, spec in sorted(json.load(open(sys.argv[1]))["pip"].items()):
    print("%s>=%s" % (name, spec["min"]))
PY
)

QEMU_DIR="$BUILD_ROOT/qemu-$QEMU_VERSION"
TARBALL_NAME="qemu-$QEMU_VERSION.tar.xz"
TARBALL="$BUILD_ROOT/$TARBALL_NAME"
MARKER="$QEMU_DIR/.sboot_created"

# ---- 0) 무엇을 할지 먼저 정한다 (설치보다 앞서: 막힐 거면 sudo 전에 막는다) ----
ENV_JSON="$(bash "$HERE/clean_env.sh" --status)"
ENV_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$ENV_JSON")"
ENV_REASON="$(python3 -c 'import json,sys; print("; ".join(json.load(sys.stdin).get("reasons") or []))' <<<"$ENV_JSON")"

case "$ENV_STATUS" in
    ok)         ACTION=reuse ;;
    incomplete) ACTION=resume ;;
    stale)      ACTION=rebuild ;;
    missing)    ACTION=fresh ;;
    unmarked)   if [ "$REPLACE_UNMARKED" -eq 1 ]; then ACTION=replace_unmarked; else ACTION=blocked_unmarked; fi ;;
    *)          ACTION=fresh ;;
esac

# ---- 0a) apt 가 실제로 필요한가, 필요하다면 sudo 를 비밀번호 없이 쓸 수 있는가 ----
# 이 목록이 설치 단계와 사전 점검의 단일 출처다 (커널/DTB: dtc=fdtdump, flex/bison=QEMU dtc).
APT_PKGS=(build-essential ninja-build pkg-config
    libglib2.0-dev libpixman-1-dev libslirp-dev
    python3 python3-pip python3-venv
    socat unzip wget curl tar lz4 file
    android-sdk-libsparse-utils
    flex bison device-tree-compiler)
APT_MISSING=(); APT_KNOWN=0
if command -v dpkg-query >/dev/null 2>&1; then
    APT_KNOWN=1
    for pkg in "${APT_PKGS[@]}"; do
        case "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" in
            "install ok installed") ;;
            *) APT_MISSING+=("$pkg") ;;
        esac
    done
else
    APT_MISSING=("${APT_PKGS[@]}")      # 가려낼 수 없으면 필요하다고 본다
fi
SUDO=""; SUDO_STATE=not_needed; SUDO_WHY=""
if [ "${#APT_MISSING[@]}" -gt 0 ]; then
    if [ "$(id -u)" -eq 0 ]; then
        SUDO_STATE=root
    elif ! command -v sudo >/dev/null 2>&1; then
        SUDO_STATE=unavailable; SUDO_WHY="sudo 명령이 없습니다"
    elif sudo -n true </dev/null >/dev/null 2>&1; then
        SUDO=sudo; SUDO_STATE=passwordless
    else
        SUDO_STATE=unavailable; SUDO_WHY="sudo 가 비밀번호를 요구합니다 (sudo -n true 실패)"
    fi
fi

# 이전 env.json 이 우리 것이면 그때 init 이 설치한 pip 목록을 먼저 읽어 둔다. 재구축은 낡은
# env.json 을 지우므로, 나중에 읽으면 "무엇을 우리가 설치했는지"가 사라져 --clean 이 모른다.
PREV_PIP="$(python3 - "$STATE" <<'PY'
import json, sys
try:
    prev = json.load(open(sys.argv[1]))
    ours = prev.get("created_by") == "sboot-rehost"
except (OSError, ValueError):
    prev, ours = {}, False
print(json.dumps(sorted(prev.get("pip_installed") or []) if ours else []))
PY
)"

report_plan() {
    python3 - "$ACTION" "$ENV_STATUS" "$ENV_REASON" "$QEMU_DIR" "$ENV_REVISION" "$QEMU_VERSION" \
        "$SUDO_STATE" "$APT_KNOWN" ${APT_MISSING[@]+"${APT_MISSING[@]}"} <<'PY'
import json, sys
action, status, reason, qdir, rev, ver, sudo_state, known = sys.argv[1:9]
missing = sys.argv[9:]
print(json.dumps({"action": action, "env_status": status, "reason": reason, "qemu_dir": qdir,
                  "required": {"env_revision": int(rev), "qemu_version": ver},
                  "rebuild_minutes": 0 if action == "reuse" else 18,
                  "apt": {"needed": bool(missing), "checked": known == "1",
                          "missing": missing, "sudo": sudo_state}}, ensure_ascii=False))
PY
}

if [ "$ACTION" = "blocked_unmarked" ]; then
    report_plan
    {
        echo
        echo "중단: $QEMU_DIR 가 이 플러그인이 만든 것이 아닙니다 (표지 .sboot_created 없음)."
        echo "  - 최신 여부를 보증할 수 없고, 사용자가 따로 설치한 것일 수 있어 지우지 않습니다."
        echo "  - 옛 setup_env.sh 가 만든 것이 맞다면 다음으로 옆으로 옮기고(삭제 아님) 새로 만듭니다:"
        echo "      bash $0 --replace-unmarked"
        echo "  - 옮긴 트리는 $QEMU_DIR.unmarked.<시각> 에 그대로 남습니다."
    } >&2
    exit 4
fi
if [ "$SUDO_STATE" = "unavailable" ]; then
    # 설치도 삭제도 시작하기 전에 멈춘다. 백그라운드에서는 비밀번호에 답할 사람이 없다.
    report_plan
    {
        echo
        echo "BLOCKED_ENV: apt 패키지를 설치해야 하는데 ${SUDO_WHY}."
        echo "  init 은 백그라운드로 돌아 비밀번호를 물을 수 없습니다. 그래서 아무것도 설치하거나"
        echo "  지우지 않고 여기서 멈춥니다 (종료코드 7). 터미널에서 한 번만 실행한 뒤 init 을 다시 부르세요:"
        echo "    1) 필요한 apt 패키지를 직접 설치 (이미 설치된 것은 다음 실행에서 건너뜁니다):"
        echo "         sudo apt-get update && sudo apt-get install -y ${APT_MISSING[*]}"
        echo "    2) 또는 sudo 가 비밀번호 없이 동작하게 한 뒤 다시 init (sudo 설정에 따라 다른"
        echo "       터미널에는 적용되지 않을 수 있으니 1) 이 확실합니다):  sudo -v"
        echo "  다시 /sboot-rehost:init 을 부르면 이어서 진행합니다."
    } >&2
    exit 7
fi
if [ "$DRY" -eq 1 ]; then
    report_plan
    exit 0
fi

echo "============================================================"
if [ "$ACTION" = "reuse" ]; then
    echo " sboot-rehost — 의존성 확인 (QEMU 는 환경 매니페스트와 일치: 다시 만들지 않음)"
else
    echo " sboot-rehost — 의존성 셋업 (~18 분)  [QEMU: $ACTION]"
fi
echo "============================================================"
if [ -n "$ENV_REASON" ]; then echo "환경 판정: $ENV_STATUS — $ENV_REASON"; fi

# ---- 1) apt ----
if [ "${#APT_MISSING[@]}" -eq 0 ]; then
    echo "=== [1/3] apt 패키지: 모두 설치되어 있음 (sudo 불필요) ==="
else
    echo "=== [1/3] apt 패키지 설치 (${SUDO_STATE}) ==="
    $SUDO apt-get update
    $SUDO apt-get install -y "${APT_MISSING[@]}"
fi
# rootfs 단계(dm-linear/모듈 로드)는 aarch64 크로스툴체인이 추가로 필요 —
# 무루트 확보는 worked example 의 get_xtool.sh (공식 Ubuntu .deb apt-get download) 참고.

# ---- 2) pip ----
echo "=== [2/3] pip 패키지 (capstone, meson 등 — 최소 버전은 env_manifest.json) ==="
# init 이 새로 설치한 모듈만 나중에 --clean 이 지울 수 있도록, 설치 전에 없던 것을 적어 둔다.
PIP_ABSENT="$(python3 - "$MANIFEST" <<'PY'
import json, sys
from importlib import metadata
absent = []
for name in sorted(json.load(open(sys.argv[1]))["pip"]):
    try:
        metadata.version(name)
    except Exception:
        absent.append(name)
print(json.dumps(absent))
PY
)"
pip3 install --break-system-packages "${PIP_SPECS[@]}" || {
    echo "  fallback: --user 로 재시도"
    pip3 install --user "${PIP_SPECS[@]}"
}

# pip 위치 PATH 추가 (한 번)
if ! grep -q '/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

# 설치됐다는 것과 최소 버전을 만족한다는 것은 다르다. 이미 있던 옛 모듈은 install 이
# 조용히 지나칠 수 있으므로 실제 버전을 다시 읽어 강제한다.
python3 - "$MANIFEST" <<'PY' || exit 5
import json, re, sys
from importlib import metadata

def vt(v):
    t = tuple(int(x) for x in re.findall(r"\d+", v or ""))
    return t + (0,) * (6 - len(t))

bad = []
for name, spec in sorted(json.load(open(sys.argv[1]))["pip"].items()):
    try:
        have = metadata.version(name)
    except Exception:
        have = None
    if have is None:
        if not spec.get("optional"):
            bad.append("%s 가 설치되지 않았습니다 (필요 >= %s)" % (name, spec["min"]))
        else:
            print("  (선택) %s 없음" % name)
    elif vt(have) < vt(spec["min"]):
        bad.append("%s %s 이(가) 최소 버전 %s 에 못 미칩니다" % (name, have, spec["min"]))
    else:
        print("  %s %s (>= %s)" % (name, have, spec["min"]))
if bad:
    print("pip 최소 버전 미달:\n  " + "\n  ".join(bad), file=sys.stderr)
    sys.exit(1)
PY

# ---- 3) QEMU ----
echo "=== [3/3] QEMU $QEMU_VERSION (기준 빌드, 패치 없음) ==="

write_marker() {   # $1 = building | built
    python3 - "$MARKER" "$1" "$ENV_REVISION" "$QEMU_VERSION" "$PLUGIN_VERSION" <<'PY'
import json, os, subprocess, sys
path, state, rev, ver, plugin = sys.argv[1:6]
try:
    created = json.load(open(path)).get("created_at")
except (OSError, ValueError):
    created = None
if not created:
    created = subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], capture_output=True, text=True).stdout.strip()
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump({"created_by": "sboot-rehost", "state": state, "env_revision": int(rev),
               "qemu_version": ver, "plugin_version": plugin, "created_at": created},
              fh, ensure_ascii=False, indent=2)
os.replace(tmp, path)
PY
}

case "$ACTION" in
    reuse)
        echo "QEMU 는 환경 매니페스트와 일치합니다 — 다시 만들지 않습니다."
        ;;
    replace_unmarked)
        ASIDE="$QEMU_DIR.unmarked.$(date +%Y%m%dT%H%M%S)"
        mv "$QEMU_DIR" "$ASIDE"
        echo "표지 없는 트리를 옮겼습니다(삭제 아님): $ASIDE"
        ;;
    rebuild)
        echo "낡은 QEMU 를 지웁니다 (표지가 있는 것만):"
        bash "$HERE/clean_env.sh" --layers L2 | python3 -c '
import json, sys
for r in json.load(sys.stdin)["removed"]:
    print("  - %s (%s bytes)" % (r["path"], r["bytes"]))'
        if [ -d "$QEMU_DIR" ]; then
            echo "낡은 트리를 지우지 못했습니다: $QEMU_DIR — 그 위에 빌드하지 않습니다" >&2
            exit 1
        fi
        ;;
esac

if [ "$ACTION" != "reuse" ]; then
    mkdir -p "$BUILD_ROOT"
    if [ ! -d "$QEMU_DIR" ]; then
        if [[ ! -f "$TARBALL" ]]; then
            # 받다 만 파일이 tarball 로 남지 않도록 임시 이름으로 받고 끝나면 옮긴다.
            curl -fL -o "$TARBALL.part" "https://download.qemu.org/$TARBALL_NAME"
            mv "$TARBALL.part" "$TARBALL"
            # 직접 내려받았다는 표지. clean_env.sh 는 이 표지가 있는 tarball 만 지운다.
            : > "$TARBALL.sboot_created"
        fi
        # 추출이 끊겨도 표지 없는 반쪽 트리가 남지 않도록 임시 폴더에 풀고 이름을 바꾼다.
        EXTRACT="$(mktemp -d "$BUILD_ROOT/.extract.XXXXXX")"
        tar xf "$TARBALL" -C "$EXTRACT"
        mv "$EXTRACT/qemu-$QEMU_VERSION" "$QEMU_DIR"
        rmdir "$EXTRACT"
        write_marker building
    fi

    cd "$QEMU_DIR"
    if [[ ! -f build/build.ninja ]]; then
        rm -rf build            # 표지가 있는 우리 트리 안의, configure 가 끊긴 반쪽 build
        mkdir build && cd build
        ../configure \
            --target-list=aarch64-softmmu \
            --disable-werror \
            --disable-sdl \
            --disable-vnc \
            --disable-gtk \
            --disable-docs
    else
        cd build
    fi

    ninja qemu-system-aarch64

    # 만든 것이 요구한 버전인지 확인한다. 아니면 매니페스트에 기록하지 않는다.
    BUILT="$("$QEMU_DIR/build/qemu-system-aarch64" --version | head -1)"
    case "$BUILT" in
        *"$QEMU_VERSION"*) ;;
        *) echo "빌드한 QEMU 가 요구 버전($QEMU_VERSION)이 아닙니다: $BUILT" >&2; exit 6 ;;
    esac
    write_marker built

    mkdir -p "$(dirname "$STATE")"
    BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$STATE" "$MANIFEST" "$ENV_REVISION" "$QEMU_VERSION" "$QEMU_DIR" "$PLUGIN_VERSION" "$BUILT_AT" "$PIP_ABSENT" "$PREV_PIP" <<'PY'
import json, os, sys
from importlib import metadata
state, manifest, rev, ver, qdir, plugin, built_at, absent, prev_pip = sys.argv[1:10]
pip = {}
for name in sorted(json.load(open(manifest))["pip"]):
    try:
        pip[name] = metadata.version(name)
    except Exception:
        pip[name] = None
# 설치 전에 없던 것 + 이전 환경에서 우리가 설치한 것. 지금 실제로 있는 것만 적는다.
installed = {n for n in set(json.loads(absent)) | set(json.loads(prev_pip)) if pip.get(n)}
tmp = state + ".tmp"
with open(tmp, "w") as fh:
    json.dump({"created_by": "sboot-rehost", "env_revision": int(rev), "qemu_version": ver,
               "qemu_dir": qdir, "pip": pip, "pip_installed": sorted(installed),
               "built_at": built_at, "plugin_version": plugin},
              fh, ensure_ascii=False, indent=2)
os.replace(tmp, state)
PY
    echo "환경 상태를 기록했습니다: $STATE (env_revision $ENV_REVISION, QEMU $QEMU_VERSION)"
fi

# ---- 검증 ----
echo
echo "=== 검증 ==="
"$QEMU_DIR/build/qemu-system-aarch64" --version | head -1
python3 -c "import capstone; print('capstone', capstone.__version__)"
python3 -c "import keystone; print('keystone OK')" || echo "  (keystone optional)"
which meson && meson --version || true
python3 - "$MANIFEST" <<'PY'
import json, shutil, sys
missing = []
for tool in json.load(open(sys.argv[1]))["tools"]:
    if not any(shutil.which(c) for c in tool["any_of"]):
        missing.append("%s (%s)" % ("/".join(tool["any_of"]), tool.get("purpose", "")))
if missing:
    print("  경고: 필요한 도구가 PATH 에 없습니다: " + ", ".join(missing))
PY

echo
echo "OK: 환경 셋업 완료."
echo "다음 단계: _inbox/ 에 펌웨어를 넣고 /sboot-rehost:start 호출"
