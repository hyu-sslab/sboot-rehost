#!/usr/bin/env bash
# tests/parts/init_clean.sh - init 정리: 층별 삭제, 환경 매니페스트, QEMU 트리 복원.
#
# 진짜 빌드도 네트워크도 쓰지 않는다. 임시 HOME 과 가짜 캐시·레지스트리·QEMU 트리,
# 가짜 sudo/apt-get/dpkg-query/pip3/ninja/curl 로 전부 격리한다. 플러그인은 임시 폴더로 복사해 쓴다
# (purge_cache.sh 가 플러그인 트리의 __pycache__ 를 지우므로 실제 저장소를 건드리지 않게).
#
# 단독 실행: bash tests/parts/init_clean.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
hdr "init 정리 (L1~L4 · 환경 매니페스트 · QEMU 트리 복원)"

IC="$(mktemp -d "$ROOT/init_clean.XXXXXX")"
IC_PLUG="$IC/plug"
mkdir -p "$IC_PLUG/scripts" "$IC_PLUG/.claude-plugin" "$IC/bin" "$IC/tmp" "$IC/site"
for icf in purge_cache.sh clean_env.sh qemu_tree.sh check_env.sh setup_env.sh sync_machine.sh wsl_bridge.sh; do
    cp "$REPO/scripts/$icf" "$IC_PLUG/scripts/$icf"
done
printf '{"name":"sboot-rehost","version":"9.9.9"}\n' > "$IC_PLUG/.claude-plugin/plugin.json"
cp "$REPO/env_manifest.json" "$IC_PLUG/env_manifest.json"
printf '{"plugins":[{"name":"sboot-rehost","version":"9.9.9"}]}\n' > "$IC/reg.json"

IC_REV="$(python3 -c 'import json;print(json.load(open("'"$IC_PLUG"'/env_manifest.json"))["env_revision"])')"
IC_VER="$(python3 -c 'import json;print(json.load(open("'"$IC_PLUG"'/env_manifest.json"))["qemu_version"])')"
IC_OLD=$((IC_REV - 1))

# --- 격리 도우미 -------------------------------------------------------------
ICH=""      # 시험마다 새 HOME
ic() {   # smoke.sh 가 export 해 둔 TRACE_DIR 같은 값이 새어 들어오지 않게 비운다
    env -u QEMU -u QEMU_ROOT -u QEMU_SRC -u QEMU_TARBALL -u QEMU_BUILD_ROOT -u ENV_MANIFEST -u ENV_STATE \
        -u CLEAN_MIN_AGE_SEC -u CURL_FORBID \
        HOME="$ICH" TMPDIR="$IC/tmp" SBOOT_TMP_DIRS="$IC/tmp" CACHE_ROOT="$IC/cache" REGISTRY="$IC/reg.json" \
        TRACE_DIR="$ICH/rehost/_traces" \
        PATH="$IC/bin:$PATH" PYTHONPATH="$IC/site${PYTHONPATH:+:$PYTHONPATH}" "$@"
}
ic_home() {   # $1 = 이름 -> 새 HOME 을 만들고 ICH 로 설정
    ICH="$IC/h_$1"; rm -rf "$ICH"; mkdir -p "$ICH"
    IC_BR="$ICH/qemu-build"; IC_ENV="$ICH/.sboot/env.json"; IC_WS="$IC/wsr_$1"
    rm -rf "$IC_WS"
}
ic_jv() { python3 -c 'import json,sys; j=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
ic_yes_no() { if eval "$1" >/dev/null 2>&1; then echo yes; else echo no; fi; }
ic_clean() { ic bash "$IC_PLUG/scripts/clean_env.sh" --workspaces-root "$IC_WS" "$@" 2>/dev/null; }

ic_tree() {   # $1=루트 $2=버전 $3=개정 $4=state $5=산출물(1/0)
    local d="$1/qemu-$2"; mkdir -p "$d/build"
    printf '{"created_by":"sboot-rehost","state":"%s","env_revision":%s,"qemu_version":"%s","plugin_version":"9.9.9","created_at":"t"}\n' \
        "$4" "$3" "$2" > "$d/.sboot_created"
    if [ "$5" = 1 ]; then
        printf '#!/bin/sh\necho "QEMU emulator version %s"\n' "$2" > "$d/build/qemu-system-aarch64"
        chmod +x "$d/build/qemu-system-aarch64"
    fi
    printf 'source\n' > "$d/README"
}
ic_envjson() {   # $1=경로 $2=개정 $3=버전 $4=created_by $5=pip_installed(JSON)
    mkdir -p "$(dirname "$1")"
    printf '{"created_by":"%s","env_revision":%s,"qemu_version":"%s","pip_installed":%s}\n' "$4" "$2" "$3" "${5:-[]}" > "$1"
}
ic_tarball() {   # $1=루트 $2=버전 $3=표지(1 이면 sidecar)
    mkdir -p "$1"; printf 'tar-bytes-%s' "$2" > "$1/qemu-$2.tar.xz"
    [ "$3" = 1 ] && : > "$1/qemu-$2.tar.xz.sboot_created"
    return 0
}
ic_snap() {   # 폴더들의 이름·내용 지문
    local d
    for d in "$@"; do
        [ -e "$d" ] || { echo "(없음 $d)"; continue; }
        [ -f "$d" ] && { echo "(파일 $d)"; cksum < "$d"; continue; }   # 파일 하나(env.json 등)도 지문을 낸다
        ( cd "$d" && find . | LC_ALL=C sort && find . -type f | LC_ALL=C sort | while IFS= read -r icfile; do cksum < "$icfile"; done )
    done | cksum
}
ic_old() { touch -t 202001010000 "$@"; }

# 가짜 도구: pip3 (설치를 흉내: PYTHONPATH 의 dist-info 를 만든다), sudo, apt-get, curl, ninja
cat > "$IC/bin/pip3" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$IC/pip.log"
case "\$1" in
  install)
    mkdir -p "$IC/site/capstone-5.0.9.dist-info"
    printf 'Metadata-Version: 2.1\nName: capstone\nVersion: 5.0.9\n' > "$IC/site/capstone-5.0.9.dist-info/METADATA"
    printf '__version__ = "5.0.9"\n' > "$IC/site/capstone.py" ;;
esac
exit 0
EOF
# 가짜 sudo: 기본은 비밀번호 없이 통과(예전과 같음). FAKE_SUDO_PASSWORD=1 이면 비밀번호가 필요한
# 상태를 흉내 낸다 - `sudo -n` 은 진짜처럼 즉시 실패하고, -n 없이 불리면(= 백그라운드에서 비밀번호를
# 기다리게 될 호출) PROMPTED 를 남기고 실패시켜 시험이 멈추지 않게 한다. 모든 호출은 sudo.log 에 남긴다.
cat > "$IC/bin/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$IC/sudo.log"
if [ -n "\${FAKE_SUDO_PASSWORD:-}" ]; then
  [ "\$1" = "-n" ] && { echo "sudo: a password is required" >&2; exit 1; }
  echo "PROMPTED" >> "$IC/sudo.log"; exit 1
fi
[ "\$1" = "-n" ] && shift
exec "\$@"
EOF
# 가짜 apt-get 은 부르는 대로 기록한다 (설치가 시작됐는지 보려고)
cat > "$IC/bin/apt-get" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$IC/apt.log"
exit 0
EOF
# 가짜 dpkg-query: 기본은 "설치 안 됨"(예전과 같은 흐름). FAKE_APT_INSTALLED=1 이면 전부 설치됨.
cat > "$IC/bin/dpkg-query" <<EOF
#!/usr/bin/env bash
[ -n "\${FAKE_APT_INSTALLED:-}" ] && { printf 'install ok installed'; exit 0; }
echo "dpkg-query: no packages found matching the given name" >&2; exit 1
EOF
cat > "$IC/bin/ninja" <<'EOF'
#!/usr/bin/env bash
printf '#!/bin/sh\necho "QEMU emulator version 10.2.2"\n' > qemu-system-aarch64
chmod +x qemu-system-aarch64
EOF
# curl: 내려받기를 흉내 낸다 (-o <파일> 에 가짜 tarball 을 쓴다). 안 불려야 할 때는 CURL_FORBID 로 실패시킨다.
cat > "$IC/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$@" >> "$IC/curl.log"
[ -n "\${CURL_FORBID:-}" ] && { echo "curl 이 불리면 안 됩니다" >&2; exit 99; }
out=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
cp "$IC/qemu-$IC_VER.tar.xz" "\$out"
EOF
chmod +x "$IC/bin/"*

# 가짜 pristine tarball (진짜 QEMU 가 아니라 구조만): 트리 이름은 qemu-<버전>
mkdir -p "$IC/fx/qemu-$IC_VER/hw/arm"
printf 'virt pristine\n' > "$IC/fx/qemu-$IC_VER/hw/arm/virt.c"
printf 'meson pristine\n' > "$IC/fx/qemu-$IC_VER/hw/arm/meson.build"
printf '#!/bin/sh\n: > build.ninja\n' > "$IC/fx/qemu-$IC_VER/configure"; chmod +x "$IC/fx/qemu-$IC_VER/configure"
if command -v xz >/dev/null 2>&1; then
    tar -C "$IC/fx" -cJf "$IC/qemu-$IC_VER.tar.xz" "qemu-$IC_VER"
else
    tar -C "$IC/fx" -cf "$IC/qemu-$IC_VER.tar.xz" "qemu-$IC_VER"   # tar 는 읽을 때 압축을 가려낸다
fi

# =============================================================================
printf '\n\033[1m-- A. 환경 매니페스트 (env_manifest.json) --\033[0m\n'
ICM="$REPO/env_manifest.json"
chk "env_revision 은 1 이상의 정수" "$(python3 -c 'import json;v=json.load(open("'"$ICM"'"))["env_revision"];print(isinstance(v,int) and v>=1)')" "True"
chk "QEMU 버전은 10.2.2"           "$(python3 -c 'import json;print(json.load(open("'"$ICM"'"))["qemu_version"])')" "10.2.2"
chk "setup_env 가 설치하는 pip 모듈 전부에 최소 버전" \
    "$(python3 -c 'import json;p=json.load(open("'"$ICM"'"))["pip"];print(sorted(p)==sorted(["capstone","meson","lz4","keystone-engine"]) and all(v.get("min") for v in p.values()))')" "True"
chk "필수 도구 목록이 있다" \
    "$(python3 -c 'import json;print(len(json.load(open("'"$ICM"'"))["tools"])>0)')" "True"
# 매니페스트의 도구가 check_env.sh 의 점검에서 빠지면 요구와 점검이 어긋난다
ICDRIFT=""
for ict in $(python3 -c 'import json;print(" ".join(c for x in json.load(open("'"$ICM"'"))["tools"] for c in x["any_of"]))'); do
    grep -q "$ict" "$REPO/scripts/check_env.sh" || ICDRIFT="$ICDRIFT $ict"
done
chk "매니페스트의 도구가 전부 check_env.sh 에서 점검됨" "${ICDRIFT:-none}" "none"

# =============================================================================
printf '\n\033[1m-- B. L1 플러그인 캐시: 옛 버전 삭제, 최신 유지, pycache --\033[0m\n'
ic_home l1
mkdir -p "$IC/cache/mk/sboot-rehost"/{0.2.0,0.17.0,9.9.9} "$IC/cache/other-plugin/1.0.0" "$IC_PLUG/scripts/__pycache__"
printf 'old' > "$IC/cache/mk/sboot-rehost/0.2.0/x"; printf 'older' > "$IC/cache/mk/sboot-rehost/0.17.0/x"
printf 'new' > "$IC/cache/mk/sboot-rehost/9.9.9/x"; printf 'pyc' > "$IC_PLUG/scripts/__pycache__/a.pyc"
ICJ="$(ic_clean --layers L1)"; ICRC=$?
chk "L1: 세션이 최신이면 종료코드 0"        "$ICRC" "0"
chk "L1: 옛 버전 폴더 둘이 지워짐"          "$(ic_yes_no "[ ! -d '$IC/cache/mk/sboot-rehost/0.2.0' ] && [ ! -d '$IC/cache/mk/sboot-rehost/0.17.0' ]")" "yes"
chk "L1: 최신은 남음"                       "$(ic_yes_no "[ -d '$IC/cache/mk/sboot-rehost/9.9.9' ]")" "yes"
chk "L1: 다른 플러그인은 건드리지 않음"     "$(ic_yes_no "[ -d '$IC/cache/other-plugin/1.0.0' ]")" "yes"
chk "L1: __pycache__ 가 지워짐"             "$(ic_yes_no "[ ! -d '$IC_PLUG/scripts/__pycache__' ]")" "yes"
chk "L1: 지운 것이 경로와 크기로 보고됨" \
    "$(echo "$ICJ" | ic_jv 'sorted(r["path"].rsplit("/",1)[1] for r in j["removed"] if r["layer"]=="L1" and r["bytes"]>0)')" "['0.17.0', '0.2.0', '__pycache__']"
chk "L1: 최신 버전은 kept 로 보고됨"        "$(echo "$ICJ" | ic_jv 'any(k["path"].endswith("9.9.9") for k in j["kept"])')" "True"

# 세션이 옛 버전을 로드 중이면 L2 이후를 건드리지 않고 멈춘다 (캐시를 지워도 로드된 것은 안 바뀐다)
ic_home l1stop
mkdir -p "$IC/cache/mk/sboot-rehost/0.17.0"; ic_tree "$IC_BR" "$IC_VER" "$IC_OLD" built 1
printf '{"plugins":[{"name":"sboot-rehost","version":"0.17.0"}]}\n' > "$IC/reg.json"
ICJ="$(ic_clean)"; ICRC=$?
chk "세션이 옛 버전이면 종료코드 1"         "$ICRC" "1"
chk "  needs_restart 가 서고 L1 에서 멈춤"  "$(echo "$ICJ" | ic_jv 'j["needs_restart"] and j["layers"]==["L1"]')" "True"
chk "  멈추면 낡은 QEMU 트리를 지우지 않음" "$(ic_yes_no "[ -d '$IC_BR/qemu-$IC_VER' ]")" "yes"
printf '{"plugins":[{"name":"sboot-rehost","version":"9.9.9"}]}\n' > "$IC/reg.json"
rm -rf "$IC/cache"

# =============================================================================
printf '\n\033[1m-- C. L2 도구 체인: 매니페스트 불일치만 지운다 --\033[0m\n'
ic_home l2stale
ic_tree "$IC_BR" "$IC_VER" "$IC_OLD" built 1
ic_envjson "$IC_ENV" "$IC_OLD" "$IC_VER" sboot-rehost '["fakepkg"]'
ic_tarball "$IC_BR" "$IC_VER" 1
printf 'mine' > "$IC_BR/user_notes.txt"
: > "$IC/pip.log"
ICJ="$(ic_clean --layers L2)"
chk "개정이 낮으면 판정이 stale"            "$(echo "$ICJ" | ic_jv 'j["l2"]["status"]')" "stale"
chk "  표지 있는 낡은 트리가 삭제됨"        "$(ic_yes_no "[ ! -d '$IC_BR/qemu-$IC_VER' ]")" "yes"
chk "  낡은 env.json 도 삭제됨"             "$(ic_yes_no "[ ! -e '$IC_ENV' ]")" "yes"
chk "  같은 버전 tarball 은 재사용하려고 남김" "$(ic_yes_no "[ -f '$IC_BR/qemu-$IC_VER.tar.xz' ]")" "yes"
chk "  사용자 파일은 그대로"                "$(cat "$IC_BR/user_notes.txt")" "mine"
chk "  기본 모드는 pip 모듈을 지우지 않음"  "$(wc -c < "$IC/pip.log" | tr -d ' ')" "0"
chk "  지운 뒤 재구축이 필요하다고 보고"    "$(echo "$ICJ" | ic_jv 'j["l2"]["rebuild_needed"] and j["l2"]["status_after"]=="missing"')" "True"
chk "  지운 경로·크기가 removed 에 있음" \
    "$(echo "$ICJ" | ic_jv 'any(r["layer"]=="L2" and r["path"].endswith("qemu-'"$IC_VER"'") and r["bytes"]>0 for r in j["removed"])')" "True"

ic_home l2ver
ic_tree "$IC_BR" "10.1.0" "$IC_REV" built 1; ic_tarball "$IC_BR" "10.1.0" 1
ic_tree "$IC_BR" "$IC_VER" "$IC_REV" built 1; ic_envjson "$IC_ENV" "$IC_REV" "$IC_VER" sboot-rehost
ICJ="$(ic_clean --layers L2)"
chk "QEMU 버전이 다른 옛 트리는 삭제"       "$(ic_yes_no "[ ! -d '$IC_BR/qemu-10.1.0' ]")" "yes"
chk "  그 버전의 tarball 도 삭제(표지 있음)" "$(ic_yes_no "[ ! -e '$IC_BR/qemu-10.1.0.tar.xz' ] && [ ! -e '$IC_BR/qemu-10.1.0.tar.xz.sboot_created' ]")" "yes"
chk "  요구 버전 트리는 그대로"             "$(ic_yes_no "[ -x '$IC_BR/qemu-$IC_VER/build/qemu-system-aarch64' ]")" "yes"

ic_home l2ok
ic_tree "$IC_BR" "$IC_VER" "$IC_REV" built 1; ic_envjson "$IC_ENV" "$IC_REV" "$IC_VER" sboot-rehost
ICJ="$(ic_clean --layers L2)"
chk "매니페스트와 일치하면 ok"              "$(echo "$ICJ" | ic_jv 'j["l2"]["status"]')" "ok"
chk "  아무것도 지우지 않음"                "$(echo "$ICJ" | ic_jv 'len([r for r in j["removed"] if r["layer"]=="L2"])')" "0"
chk "  재구축 불필요"                       "$(echo "$ICJ" | ic_jv 'j["l2"]["rebuild_needed"]')" "False"
chk "  트리가 남아 있음"                    "$(ic_yes_no "[ -d '$IC_BR/qemu-$IC_VER' ] && [ -f '$IC_ENV' ]")" "yes"

ic_home l2inc
ic_tree "$IC_BR" "$IC_VER" "$IC_REV" building 0
ICJ="$(ic_clean --layers L2)"
chk "빌드가 끊긴 우리 트리는 지우지 않고 이어 짓는다" "$(echo "$ICJ" | ic_jv 'j["l2"]["status"]')" "incomplete"
chk "  트리 보존"                           "$(ic_yes_no "[ -d '$IC_BR/qemu-$IC_VER' ]")" "yes"

# =============================================================================
printf '\n\033[1m-- D. 표지 없는 것은 어떤 옵션으로도 지우지 않는다 --\033[0m\n'
ic_home nomark
mkdir -p "$IC_BR/qemu-$IC_VER/build"; printf 'users own\n' > "$IC_BR/qemu-$IC_VER/mine.c"
mkdir -p "$IC_BR/qemu-9.0.0"; printf 'x' > "$IC_BR/qemu-9.0.0/y"
ic_tarball "$IC_BR" "$IC_VER" 0
ic_envjson "$IC_ENV" "$IC_OLD" "$IC_VER" someone-else
for icflags in "" "--clean"; do
    ICJ="$(ic_clean $icflags --layers L2)"
    chk "표지 없는 트리가 남음 (${icflags:-기본})" \
        "$(ic_yes_no "[ -f '$IC_BR/qemu-$IC_VER/mine.c' ] && [ -f '$IC_BR/qemu-9.0.0/y' ]")" "yes"
    chk "  표지 없는 tarball 이 남음 (${icflags:-기본})" "$(ic_yes_no "[ -f '$IC_BR/qemu-$IC_VER.tar.xz' ]")" "yes"
    chk "  남의 env.json 이 남음 (${icflags:-기본})"     "$(ic_yes_no "[ -f '$IC_ENV' ]")" "yes"
done
chk "  skipped_no_marker 로 보고됨" \
    "$(echo "$ICJ" | ic_jv 'sorted(s["path"].rsplit("/",1)[1] for s in j["skipped_no_marker"])')" "['env.json', 'qemu-10.2.2', 'qemu-10.2.2.tar.xz', 'qemu-9.0.0']"
chk "  판정은 unmarked 이고 재구축이 막힘" \
    "$(echo "$ICJ" | ic_jv 'j["l2"]["status"]=="unmarked" and j["l2"]["blocked_by_unmarked"]')" "True"
chk "  removed 에는 L2 가 없음"  "$(echo "$ICJ" | ic_jv 'len([r for r in j["removed"] if r["layer"]=="L2"])')" "0"

# =============================================================================
printf '\n\033[1m-- E. L3 임시·파생물 --\033[0m\n'
ic_home l3
mkdir -p "$ICH/rehost/_traces"
printf 'old' > "$IC/tmp/sboot_old.log"; ic_old "$IC/tmp/sboot_old.log"
printf 'new' > "$IC/tmp/sboot_new.log"
printf 'keep' > "$IC/tmp/unrelated.txt"
printf 't1' > "$ICH/rehost/_traces/run_1.log"; ic_old "$ICH/rehost/_traces/run_1.log"
printf 't2' > "$ICH/rehost/_traces/run_2.log"
printf 'n' > "$ICH/rehost/_traces/notes.txt"; ic_old "$ICH/rehost/_traces/notes.txt"
ICJ="$(ic_clean --layers L3)"
chk "기본: 오래된 임시 파일만 삭제"         "$(ic_yes_no "[ ! -e '$IC/tmp/sboot_old.log' ] && [ -e '$IC/tmp/sboot_new.log' ]")" "yes"
chk "  패턴 밖의 파일은 건드리지 않음"      "$(cat "$IC/tmp/unrelated.txt")" "keep"
chk "  오래된 트레이스만 삭제"              "$(ic_yes_no "[ ! -e '$ICH/rehost/_traces/run_1.log' ] && [ -e '$ICH/rehost/_traces/run_2.log' ]")" "yes"
chk "  플러그인 패턴이 아닌 트레이스 폴더 파일은 skipped_no_marker" \
    "$(echo "$ICJ" | ic_jv 'any(s["path"].endswith("notes.txt") for s in j["skipped_no_marker"])')" "True"
chk "  최근 것은 kept 로 이유와 함께 보고"  "$(echo "$ICJ" | ic_jv 'any(k["layer"]=="L3" and k["path"].endswith("sboot_new.log") for k in j["kept"])')" "True"
rm -f "$IC/tmp/"*

# =============================================================================
printf '\n\033[1m-- F. L4 워크스페이스: 기본 보고만, --wipe-workspaces 는 보관 이동 --\033[0m\n'
ic_home l4
mkdir -p "$IC_WS/_inbox" "$IC_WS/wsCurrent" "$IC_WS/wsNoMark" "$IC_WS/wsOld"
printf 'fw' > "$IC_WS/_inbox/DROP_FIRMWARE_HERE.txt"
printf '9.9.9\n' > "$IC_WS/wsCurrent/.sboot_version"
printf '0.1.0\n' > "$IC_WS/wsOld/.sboot_version"
printf 'log-a' > "$IC_WS/wsCurrent/JOURNAL.md"; printf 'log-b' > "$IC_WS/wsNoMark/JOURNAL.md"; printf 'log-c' > "$IC_WS/wsOld/JOURNAL.md"
ICJ="$(ic_clean --layers L4)"
chk "기본: 옛 버전·표지 없는 워크스페이스를 보고"  "$(echo "$ICJ" | ic_jv 'sorted(w["id"] for w in j["workspaces_old"])')" "['wsNoMark', 'wsOld']"
chk "  표지 없음과 버전 다름을 구분해 보고" \
    "$(echo "$ICJ" | ic_jv '[w["version"] for w in sorted(j["workspaces_old"], key=lambda w: w["id"])]')" "[None, '0.1.0']"
chk "  아무것도 옮기거나 지우지 않음" \
    "$(ic_yes_no "[ -f '$IC_WS/wsCurrent/JOURNAL.md' ] && [ -f '$IC_WS/wsNoMark/JOURNAL.md' ] && [ -f '$IC_WS/wsOld/JOURNAL.md' ] && [ ! -d '$IC_WS/_archive' ]")" "yes"
ICJ="$(ic_clean --layers L4 --wipe-workspaces)"
chk "--wipe-workspaces: 셋 다 보관 이동"            "$(echo "$ICJ" | ic_jv 'len(j["archived"])')" "3"
chk "  원래 자리에서 사라짐"                        "$(ic_yes_no "[ ! -d '$IC_WS/wsCurrent' ] && [ ! -d '$IC_WS/wsNoMark' ] && [ ! -d '$IC_WS/wsOld' ]")" "yes"
chk "  _archive/<id>_<시각> 에 내용이 그대로 있음 (삭제가 아님)" \
    "$(cat "$IC_WS"/_archive/wsNoMark_*/JOURNAL.md "$IC_WS"/_archive/wsOld_*/JOURNAL.md "$IC_WS"/_archive/wsCurrent_*/JOURNAL.md | tr -d '\n')" "log-blog-clog-a"
chk "  이동한 크기가 보고됨"                        "$(echo "$ICJ" | ic_jv 'all(a["bytes"]>0 for a in j["archived"])')" "True"
chk "  펌웨어 드롭 폴더 _inbox 는 그대로"           "$(cat "$IC_WS/_inbox/DROP_FIRMWARE_HERE.txt")" "fw"
chk "  removed 에 워크스페이스가 없음 (삭제가 아니라 이동)" "$(echo "$ICJ" | ic_jv 'len([r for r in j["removed"] if r["layer"]=="L4"])')" "0"
ICJ="$(ic_clean --layers L4 --wipe-workspaces)"
chk "  다시 불러도 _archive 를 다시 옮기지 않음"     "$(echo "$ICJ" | ic_jv 'len(j["archived"])')" "0"

# =============================================================================
printf '\n\033[1m-- G. --dry-run 은 아무것도 바꾸지 않고, --clean 은 L1~L3 를 지운다 --\033[0m\n'
ic_rich() {   # 모든 층에 지울 것이 있는 상태
    ic_home "$1"
    rm -rf "$IC/cache" "$IC/tmp"; mkdir -p "$IC/tmp" "$IC/cache/mk/sboot-rehost"/{0.17.0,9.9.9} "$IC_PLUG/scripts/__pycache__"
    printf 'p' > "$IC_PLUG/scripts/__pycache__/a.pyc"; printf 'o' > "$IC/cache/mk/sboot-rehost/0.17.0/x"
    ic_tree "$IC_BR" "$IC_VER" "$IC_REV" built 1; ic_envjson "$IC_ENV" "$IC_REV" "$IC_VER" sboot-rehost '["fakepkg"]'
    ic_tarball "$IC_BR" "$IC_VER" 1
    mkdir -p "$ICH/rehost/_traces" "$IC_WS/_inbox" "$IC_WS/wsA"
    printf 'x' > "$ICH/rehost/_traces/run_1.log"; printf 'x' > "$IC/tmp/sboot_fresh.log"; printf 'keep' > "$IC/tmp/other.txt"
    printf 'j' > "$IC_WS/wsA/JOURNAL.md"
    mkdir -p "$IC/site/fakepkg-1.0.dist-info"
    printf 'Metadata-Version: 2.1\nName: fakepkg\nVersion: 1.0\n' > "$IC/site/fakepkg-1.0.dist-info/METADATA"
}
ic_rich dry
ICS1="$(ic_snap "$ICH" "$IC/cache" "$IC/tmp" "$IC_WS" "$IC_PLUG")"
ICJ="$(ic_clean --clean --wipe-workspaces --dry-run)"
ICS2="$(ic_snap "$ICH" "$IC/cache" "$IC/tmp" "$IC_WS" "$IC_PLUG")"
chk "--dry-run: 아무것도 바뀌지 않음"           "$ICS2" "$ICS1"
chk "  그래도 지울 것은 목록으로 보여 줌"        "$(echo "$ICJ" | ic_jv 'j["dry_run"] and len(j["removed"])>=5 and len(j["archived"])==1')" "True"

: > "$IC/pip.log"
ic_rich clean
ICJ="$(ic_clean --clean)"
chk "--clean: 옛 캐시(L1)"                      "$(ic_yes_no "[ ! -d '$IC/cache/mk/sboot-rehost/0.17.0' ]")" "yes"
chk "  일치하는 트리(L2)도 조건 없이 삭제"       "$(ic_yes_no "[ ! -d '$IC_BR/qemu-$IC_VER' ]")" "yes"
chk "  tarball 과 표지, env.json 삭제"          "$(ic_yes_no "[ ! -e '$IC_BR/qemu-$IC_VER.tar.xz' ] && [ ! -e '$IC_BR/qemu-$IC_VER.tar.xz.sboot_created' ] && [ ! -e '$IC_ENV' ]")" "yes"
chk "  비어 버린 ~/qemu-build 도 정리"           "$(ic_yes_no "[ ! -d '$IC_BR' ]")" "yes"
chk "  init 이 설치한 pip 모듈만 제거 요청"      "$(grep -c 'uninstall -y --break-system-packages fakepkg' "$IC/pip.log")" "1"
chk "  최근 임시 파일(L3)도 조건 없이 삭제"      "$(ic_yes_no "[ ! -e '$IC/tmp/sboot_fresh.log' ] && [ ! -e '$ICH/rehost/_traces/run_1.log' ]")" "yes"
chk "  패턴 밖의 임시 파일은 그대로"             "$(cat "$IC/tmp/other.txt")" "keep"
chk "  L4 워크스페이스는 --wipe-workspaces 없이는 그대로" "$(ic_yes_no "[ -f '$IC_WS/wsA/JOURNAL.md' ]")" "yes"
chk "  지운 것의 총 크기가 보고됨"               "$(echo "$ICJ" | ic_jv 'j["freed_bytes"]>0')" "True"
rm -rf "$IC/cache" "$IC/tmp"; mkdir -p "$IC/tmp"

# =============================================================================
printf '\n\033[1m-- H. qemu_tree.sh: pristine 복원 (C5) --\033[0m\n'
ICQT="$IC_PLUG/scripts/qemu_tree.sh"
ic_qt_home() {   # 트리 하나와 그 옆 tarball
    ic_home "$1"; mkdir -p "$IC_BR"
    cp "$IC/qemu-$IC_VER.tar.xz" "$IC_BR/"; tar -xf "$IC_BR/qemu-$IC_VER.tar.xz" -C "$IC_BR"
    ICQS="$IC_BR/qemu-$IC_VER"
}
ic_qt() { ic env QEMU_SRC="$ICQS" bash "$ICQT" "$@" 2>/dev/null; }
ic_qt_home ic_qt
printf 'patched virt\n' > "$ICQS/hw/arm/virt.c"                 # M: 원래 있던 파일을 고침
printf 'added by machine\n' > "$ICQS/hw/arm/sboot_machine.c"    # A: 우리가 더함
printf 'user edit\n' > "$ICQS/hw/arm/user_edit.c"                # 장부에 없는 파일
printf 'M hw/arm/virt.c\nA hw/arm/sboot_machine.c\n' > "$ICQS/.sboot_touched"
ICJ="$(ic_qt reset)"; ICRC=$?
chk "reset 종료코드 0"                           "$ICRC" "0"
chk "  M 항목이 tarball 에서 복원됨"              "$(cat "$ICQS/hw/arm/virt.c")" "virt pristine"
chk "  A 항목이 삭제됨"                          "$(ic_yes_no "[ ! -e '$ICQS/hw/arm/sboot_machine.c' ]")" "yes"
chk "  장부에 없는 파일은 건드리지 않음"          "$(cat "$ICQS/hw/arm/user_edit.c")" "user edit"
chk "  장부를 비움"                              "$(wc -c < "$ICQS/.sboot_touched" | tr -d ' ')" "0"
chk "  복원·삭제 목록을 JSON 으로 보고" \
    "$(echo "$ICJ" | ic_jv '(j["restored"], j["removed"])')" "(['hw/arm/virt.c'], ['hw/arm/sboot_machine.c'])"
chk "  복원한 파일의 mtime 이 지금이라 ninja 가 다시 빌드함" \
    "$(python3 -c 'import os,time;print(time.time()-os.path.getmtime("'"$ICQS/hw/arm/virt.c"'")<600)')" "True"
ICS1="$(ic_snap "$ICQS")"
ICJ="$(ic_qt reset)"; ICRC=$?
chk "멱등: 두 번째 reset 은 아무것도 하지 않고 성공" "$ICRC $(echo "$ICJ" | ic_jv 'j["noop"]') $(ic_snap "$ICQS" | tr -d ' ')" "0 True $(echo "$ICS1" | tr -d ' ')"

# 장부가 아예 없어도 성공(할 일 없음)
rm -f "$ICQS/.sboot_touched"; ic_qt reset >/dev/null; chk "장부가 없으면 할 일 없음(0)" "$?" "0"

# 되돌릴 원본이 없으면 크게 실패하고 아무것도 바꾸지 않는다
printf 'patched virt\n' > "$ICQS/hw/arm/virt.c"; printf 'A hw/arm/sboot_machine.c\nM hw/arm/virt.c\n' > "$ICQS/.sboot_touched"
printf 'added\n' > "$ICQS/hw/arm/sboot_machine.c"
mv "$IC_BR/qemu-$IC_VER.tar.xz" "$IC_BR/hidden.tar"
ICS1="$(ic_snap "$ICQS")"
ic_qt reset >"$IC/out.json"; ICRC=$?
chk "tarball 이 없으면 실패(종료코드 2)"           "$ICRC" "2"
chk "  실패 JSON 에 사유"                         "$(ic_jv 'bool(j.get("error"))' < "$IC/out.json")" "True"
chk "  아무것도 바꾸지 않음 (A 파일도 그대로)"     "$(ic_snap "$ICQS" | tr -d ' ')" "$(echo "$ICS1" | tr -d ' ')"
mv "$IC_BR/hidden.tar" "$IC_BR/qemu-$IC_VER.tar.xz"

# 트리 밖을 가리키는 경로는 장부가 깨진 것으로 보고 아무것도 바꾸지 않는다
printf 'victim\n' > "$IC_BR/outside.txt"
printf 'M hw/arm/virt.c\nA ../outside.txt\n' > "$ICQS/.sboot_touched"
ic_qt reset >/dev/null; ICRC=$?
chk "../ 경로가 든 장부는 거부(종료코드 2)"       "$ICRC" "2"
chk "  트리 밖 파일은 무사"                       "$(cat "$IC_BR/outside.txt")" "victim"
chk "  다른 항목도 적용되지 않음"                 "$(cat "$ICQS/hw/arm/virt.c")" "patched virt"
printf 'A /etc/passwd\n' > "$ICQS/.sboot_touched"; ic_qt reset >/dev/null; chk "절대 경로도 거부" "$?" "2"

# 원래 QEMU 에 없던 파일을 M 으로 적었다면 되돌릴 수 없으니 멈춘다 (추측으로 지우지 않는다)
printf 'M hw/arm/not_in_qemu.c\n' > "$ICQS/.sboot_touched"; printf 'x\n' > "$ICQS/hw/arm/not_in_qemu.c"
ic_qt reset >/dev/null; ICRC=$?
chk "M 항목이 tarball 에 없으면 실패하고 파일을 지우지 않음" "$ICRC $(ic_yes_no "[ -f '$ICQS/hw/arm/not_in_qemu.c' ]")" "2 yes"

# record: 경로당 한 줄, tarball 로 M/A 를 가름
: > "$ICQS/.sboot_touched"
ic_qt record hw/arm/virt.c hw/arm/brand_new.c >/dev/null
ic_qt record hw/arm/virt.c >/dev/null
ic_qt record --kind A hw/arm/other_new.c >/dev/null
chk "record: tarball 에 있으면 M, 없으면 A, 경로당 한 줄" "$(tr '\n' ',' < "$ICQS/.sboot_touched")" "M hw/arm/virt.c,A hw/arm/brand_new.c,A hw/arm/other_new.c,"
ICJ="$(ic_qt status)"
chk "status: 건드린 파일 목록"                   "$(echo "$ICJ" | ic_jv '(j["modified"], j["added"], j["dirty"])')" "(['hw/arm/virt.c'], ['hw/arm/brand_new.c', 'hw/arm/other_new.c'], True)"
mv "$IC_BR/qemu-$IC_VER.tar.xz" "$IC_BR/hidden.tar"
ic_qt record hw/arm/ambiguous.c >/dev/null; ICRC=$?
chk "record: tarball 이 없으면 M/A 를 추측하지 않고 실패(3)" "$ICRC $(grep -c ambiguous "$ICQS/.sboot_touched")" "3 0"
mv "$IC_BR/hidden.tar" "$IC_BR/qemu-$IC_VER.tar.xz"

# =============================================================================
printf '\n\033[1m-- I. sync_machine.sh 가 건드린 파일을 장부에 적는다 (JSON 은 그대로) --\033[0m\n'
ic_qt_home sync
mkdir -p "$IC/swd/06_machine"; rm -f "$IC/swd/06_machine/"*
printf 'int machine;\n' > "$ICQS/hw/arm/sboot_m.c"              # Build 가 복사해 둔 머신 (원본 QEMU 에 없음)
printf 'int m1;\n' > "$IC/swd/06_machine/machine.c"
printf 'patched\n' > "$IC/swd/06_machine/virt.c"              # 원본 QEMU 파일을 덮어쓰는 경우
printf 'int dev;\n' > "$IC/swd/06_machine/newdev.c"            # 매핑 파일이 가리키는 아직 없는 대상
printf 'newdev.c\t%s\n' "$ICQS/hw/arm/newdev.c" > "$IC/swd/06_machine/qemu_targets.txt"
ICJ="$(ic bash "$IC_PLUG/scripts/sync_machine.sh" "$IC/swd" sboot-m "$ICQS" 2>/dev/null)"; ICRC=$?
chk "sync: 종료코드와 JSON 형식은 그대로"        "$ICRC $(echo "$ICJ" | ic_jv 'sorted(j.keys())')" "0 ['synced', 'targets', 'unmapped']"
chk "  세 파일이 복사됨"                          "$(echo "$ICJ" | ic_jv 'j["synced"]')" "3"
chk "  덮어쓴 원본 파일은 M, 새 파일은 A"          "$(LC_ALL=C sort "$ICQS/.sboot_touched" | tr '\n' ',')" "A hw/arm/newdev.c,A hw/arm/sboot_m.c,M hw/arm/virt.c,"
ic bash "$IC_PLUG/scripts/sync_machine.sh" "$IC/swd" sboot-m "$ICQS" >/dev/null 2>&1
printf 'int m2;\n' > "$IC/swd/06_machine/machine.c"
ic bash "$IC_PLUG/scripts/sync_machine.sh" "$IC/swd" sboot-m "$ICQS" >/dev/null 2>&1
chk "  다시 맞춰도 경로당 한 줄"                   "$(wc -l < "$ICQS/.sboot_touched" | tr -d ' ')" "3"
ic_qt reset >/dev/null
chk "  이어서 reset: 원본 복원 + 더한 파일 삭제" \
    "$(cat "$ICQS/hw/arm/virt.c" | tr -d '\n') $(ic_yes_no "[ ! -e '$ICQS/hw/arm/sboot_m.c' ] && [ ! -e '$ICQS/hw/arm/newdev.c' ]")" "virt pristine yes"

# tarball 이 없는 트리(옛 smoke 의 가짜 트리 같은): 기존 동작 그대로, 추측해서 적지 않는다
ic_home syncold
mkdir -p "$IC/old_tree/hw/arm"; printf 'int old;\n' > "$IC/old_tree/hw/arm/sboot_test.c"; rm -f "$IC/old_tree/.sboot_touched"
rm -f "$IC/swd/06_machine/"*; printf 'int v1;\n' > "$IC/swd/06_machine/machine.c"
ICJ="$(ic bash "$IC_PLUG/scripts/sync_machine.sh" "$IC/swd" sboot-test "$IC/old_tree" 2>/dev/null)"; ICRC=$?
chk "tarball 이 없어도 sync 는 성공하고 복사함" "$ICRC $(cat "$IC/old_tree/hw/arm/sboot_test.c" | tr -d '\n')" "0 int v1;"
chk "  M/A 를 가를 수 없으니 장부에 추측으로 적지 않음" "$(ic_yes_no "[ ! -s '$IC/old_tree/.sboot_touched' ]")" "yes"
chk "  JSON 은 그대로" "$(echo "$ICJ" | ic_jv 'j["synced"]')" "1"

# =============================================================================
printf '\n\033[1m-- J. check_env.sh 가 매니페스트 불일치를 problems 로 보고 --\033[0m\n'
ic_home chk_stale
ic_tree "$IC_BR" "$IC_VER" "$IC_OLD" built 1; ic_envjson "$IC_ENV" "$IC_OLD" "$IC_VER" sboot-rehost
ICJ="$(ic bash "$IC_PLUG/scripts/check_env.sh" "" F1 2>/dev/null)"
chk "낡은 환경이면 ok=false"                     "$(echo "$ICJ" | ic_jv 'j["ok"]')" "False"
chk "  env_manifest.status=stale"                "$(echo "$ICJ" | ic_jv 'j["env_manifest"]["status"]')" "stale"
chk "  problems 에 낡았다는 문장"                "$(echo "$ICJ" | ic_jv 'any("낡았습니다" in p for p in j["problems"])')" "True"
chk "  hint 가 /sboot-rehost:init 을 안내"        "$(echo "$ICJ" | ic_jv '"/sboot-rehost:init" in j["hint"]')" "True"
chk "  기존 출력 키(ok·os·wsl·problems·hint)가 그대로" "$(echo "$ICJ" | ic_jv 'all(k in j for k in ("ok","os","wsl","problems","hint"))')" "True"

ic_home chk_missing
ICJ="$(ic bash "$IC_PLUG/scripts/check_env.sh" "" F1 2>/dev/null)"
chk "이 플러그인이 만든 환경이 없으면 missing 으로 보고" \
    "$(echo "$ICJ" | ic_jv 'j["env_manifest"]["status"]=="missing" and any("만든 QEMU 환경이 없습니다" in p for p in j["problems"])')" "True"

ic_home chk_unmarked
mkdir -p "$IC_BR/qemu-$IC_VER/build"
ICJ="$(ic bash "$IC_PLUG/scripts/check_env.sh" "" F1 2>/dev/null)"
chk "표지 없는 트리는 unmarked 로 보고" \
    "$(echo "$ICJ" | ic_jv 'j["env_manifest"]["status"]=="unmarked" and any("표지 없음" in p for p in j["problems"])')" "True"

ic_home chk_ok
ic_tree "$IC_BR" "$IC_VER" "$IC_REV" built 1; ic_envjson "$IC_ENV" "$IC_REV" "$IC_VER" sboot-rehost
ICJ="$(ic bash "$IC_PLUG/scripts/check_env.sh" "" F1 2>/dev/null)"
chk "일치하는 환경이면 매니페스트 문제가 없음" \
    "$(echo "$ICJ" | ic_jv 'j["env_manifest"]["status"]=="ok" and not any(("매니페스트" in p or "QEMU 환경" in p or "낡았" in p) for p in j["problems"])')" "True"

ICJ="$(ic env QEMU=/bin/true bash "$IC_PLUG/scripts/check_env.sh" "" F1 2>/dev/null)"
chk "QEMU 를 직접 지정하면 비교를 건너뛰고 그 사실을 밝힘" "$(echo "$ICJ" | ic_jv 'j["env_manifest"]["status"]')" "skipped"

# =============================================================================
printf '\n\033[1m-- K. setup_env.sh: 재사용 조건과 기록 (가짜 빌드) --\033[0m\n'
ic_plan() { ic bash "$IC_PLUG/scripts/setup_env.sh" --dry-run "$@" 2>/dev/null; }

ic_home su_plan
ICJ="$(ic_plan)"; chk "트리가 없으면 새로 만든다 (fresh)"             "$(echo "$ICJ" | ic_jv 'j["action"]')" "fresh"
ic_tree "$IC_BR" "$IC_VER" "$IC_REV" built 1; ic_envjson "$IC_ENV" "$IC_REV" "$IC_VER" sboot-rehost
ICJ="$(ic_plan)"; chk "env.json 이 요구와 일치하면 재사용 (reuse)"      "$(echo "$ICJ" | ic_jv 'j["action"]')" "reuse"
ic_envjson "$IC_ENV" "$IC_OLD" "$IC_VER" sboot-rehost
ICJ="$(ic_plan)"; chk "env_revision 이 낮으면 재구축 (rebuild)"        "$(echo "$ICJ" | ic_jv 'j["action"]')" "rebuild"
ic_envjson "$IC_ENV" "$IC_REV" "10.1.0" sboot-rehost
ICJ="$(ic_plan)"; chk "QEMU 버전이 다르면 재구축"                      "$(echo "$ICJ" | ic_jv 'j["action"]')" "rebuild"
rm -rf "$IC_BR"; ic_tree "$IC_BR" "$IC_VER" "$IC_REV" building 0
ICJ="$(ic_plan)"; chk "빌드가 끊겼으면 이어서 (resume)"                "$(echo "$ICJ" | ic_jv 'j["action"]')" "resume"
rm -rf "$IC_BR"; mkdir -p "$IC_BR/qemu-$IC_VER"; printf 'mine\n' > "$IC_BR/qemu-$IC_VER/mine.c"
ic bash "$IC_PLUG/scripts/setup_env.sh" --dry-run >"$IC/out.json" 2>/dev/null; ICRC=$?
chk "표지 없는 트리면 중단(종료코드 4)하고 지우지 않음"           "$ICRC $(cat "$IC_BR/qemu-$IC_VER/mine.c")" "4 mine"
chk "  계획에 blocked_unmarked"                                "$(ic_jv 'j["action"]' < "$IC/out.json")" "blocked_unmarked"
ICJ="$(ic_plan --replace-unmarked)"
chk "  --replace-unmarked 면 옆으로 옮기는 계획 (삭제 아님)"      "$(echo "$ICJ" | ic_jv 'j["action"]')" "replace_unmarked"

# 가짜 빌드 전 과정: 내려받기(가짜 curl) -> 추출 -> configure -> ninja -> 표지·env.json
ic_home su_build
rm -f "$IC/site/capstone.py"; rm -rf "$IC/site/capstone-5.0.9.dist-info"; : > "$IC/pip.log"; : > "$IC/curl.log"
ic bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/setup.log" 2>&1; ICRC=$?
chk "가짜 빌드가 끝까지 성공"                                 "$ICRC" "0"
[ "$ICRC" -ne 0 ] && tail -15 "$IC/setup.log" | sed 's/^/        /'
chk "  tarball 을 트리 옆에 둠(내려받음)"                    "$(ic_yes_no "[ -f '$IC_BR/qemu-$IC_VER.tar.xz' ] && [ ! -e '$IC_BR/qemu-$IC_VER.tar.xz.part' ]")" "yes"
chk "  직접 내려받았다는 표지를 tarball 옆에 남김"           "$(ic_yes_no "[ -f '$IC_BR/qemu-$IC_VER.tar.xz.sboot_created' ]")" "yes"
chk "  트리에 표지(created_by, state=built)"                  "$(ic_jv '(j["created_by"], j["state"], j["env_revision"], j["qemu_version"])' < "$IC_BR/qemu-$IC_VER/.sboot_created")" "('sboot-rehost', 'built', $IC_REV, '$IC_VER')"
chk "  ~/.sboot/env.json 에 요구한 필드를 기록" \
    "$(ic_jv '(j["created_by"], j["env_revision"], j["qemu_version"], bool(j["built_at"]), j["plugin_version"], j["pip"]["capstone"])' < "$IC_ENV")" "('sboot-rehost', $IC_REV, '$IC_VER', True, '9.9.9', '5.0.9')"
chk "  init 이 새로 설치한 pip 모듈을 기록"                   "$(ic_jv 'j["pip_installed"]' < "$IC_ENV")" "['capstone']"
chk "  pip 에 최소 버전 지정을 넘김"                          "$(grep -c 'capstone>=5.0.0' "$IC/pip.log")" "1"
chk "  빌드 직후 판정이 ok"                                   "$(ic_clean --status | ic_jv 'j["status"]')" "ok"
chk "  패치 없는 기준 빌드: 장부가 비어 있음"                  "$(ic_yes_no "[ ! -s '$IC_BR/qemu-$IC_VER/.sboot_touched' ]")" "yes"
ICJ="$(ic_plan)"; chk "  다시 부르면 재사용"                        "$(echo "$ICJ" | ic_jv 'j["action"]')" "reuse"

# 일치하면 다시 만들지 않는다: 내려받기도 빌드도 없이 끝나고 env.json 은 그대로다
ICS1="$(ic_snap "$IC_BR" "$IC_ENV")"
: > "$IC/curl.log"
ic env CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/setup1b.log" 2>&1; ICRC=$?
chk "  일치하면 두 번째 실행은 재사용하고 성공"                "$ICRC $(grep -c '다시 만들지 않습니다' "$IC/setup1b.log")" "0 1"
chk "  트리와 env.json 이 바뀌지 않음"                        "$(ic_snap "$IC_BR" "$IC_ENV")" "$ICS1"

# 환경 개정이 오르면 다시 만든다. 같은 버전 tarball 은 재사용하고 다시 내려받지 않는다.
python3 - "$IC_PLUG/env_manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["env_revision"] += 1
json.dump(m, open(p, "w"), ensure_ascii=False, indent=2)
PY
ICJ="$(ic_plan)"; chk "매니페스트 개정이 오르면 재구축 계획"          "$(echo "$ICJ" | ic_jv 'j["action"]')" "rebuild"
: > "$IC/curl.log"
ic env CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/setup2.log" 2>&1; ICRC=$?
chk "  재구축 성공 (같은 버전 tarball 재사용, 내려받지 않음)"  "$ICRC $(wc -c < "$IC/curl.log" | tr -d ' ')" "0 0"
chk "  새 개정으로 기록됨"                                    "$(ic_jv 'j["env_revision"]' < "$IC_ENV")" "$((IC_REV + 1))"
chk "  이전에 설치한 pip 목록을 이어받음"                      "$(ic_jv 'j["pip_installed"]' < "$IC_ENV")" "['capstone']"
chk "  tarball 의 직접 내려받은 표지가 유지됨"                 "$(ic_yes_no "[ -f '$IC_BR/qemu-$IC_VER.tar.xz.sboot_created' ]")" "yes"
cp "$REPO/env_manifest.json" "$IC_PLUG/env_manifest.json"

# 미리 놓아 둔 tarball 은 우리가 내려받은 것이 아니므로 표지를 붙이지 않는다 (나중에 지우지 않는다)
ic_home su_pre
mkdir -p "$IC_BR"; cp "$IC/qemu-$IC_VER.tar.xz" "$IC_BR/"
ic env CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/setup3.log" 2>&1; ICRC=$?
chk "미리 놓은 tarball 로 빌드 (내려받지 않음)"                "$ICRC" "0"
chk "  그 tarball 에는 표지가 없음 -> clean 이 지우지 않음"    "$(ic_yes_no "[ ! -e '$IC_BR/qemu-$IC_VER.tar.xz.sboot_created' ]")" "yes"
ICJ="$(ic_clean --layers L2 --clean)"
chk "  --clean 은 우리 트리만 지우고 놓아 둔 tarball 은 남김"   "$(ic_yes_no "[ ! -d '$IC_BR/qemu-$IC_VER' ] && [ -f '$IC_BR/qemu-$IC_VER.tar.xz' ]")" "yes"
chk "  남긴 tarball 을 skipped_no_marker 로 보고"               "$(echo "$ICJ" | ic_jv 'any(s["path"].endswith(".tar.xz") for s in j["skipped_no_marker"])')" "True"

# 끊긴 빌드는 지우지 않고 그 트리에서 이어 짓는다 (반쯤 된 configure 는 다시 한다)
ic_home su_resume
ic_tree "$IC_BR" "$IC_VER" "$IC_REV" building 0; mkdir -p "$IC_BR/qemu-$IC_VER/build"; printf 'half\n' > "$IC_BR/qemu-$IC_VER/build/partial"
printf '#!/bin/sh\n: > build.ninja\n' > "$IC_BR/qemu-$IC_VER/configure"; chmod +x "$IC_BR/qemu-$IC_VER/configure"
printf 'kept\n' > "$IC_BR/qemu-$IC_VER/hw_marker.txt"
ic env CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/setup5.log" 2>&1; ICRC=$?
chk "끊긴 빌드를 이어서 완료"                                  "$ICRC $(ic_jv 'j["state"]' < "$IC_BR/qemu-$IC_VER/.sboot_created")" "0 built"
chk "  그 트리의 파일은 그대로(새로 풀지 않음)"                 "$(cat "$IC_BR/qemu-$IC_VER/hw_marker.txt")" "kept"

# 표지 없는 트리: --replace-unmarked 면 지우지 않고 옆으로 옮긴 뒤 새로 만든다
ic_home su_aside
mkdir -p "$IC_BR/qemu-$IC_VER"; printf 'users own\n' > "$IC_BR/qemu-$IC_VER/mine.c"; cp "$IC/qemu-$IC_VER.tar.xz" "$IC_BR/"; : > "$IC/pip.log"
ic env CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/setup6.log" 2>&1; ICRC=$?
chk "플래그 없이는 중단(4)하고 아무것도 설치하지 않음"           "$ICRC $(wc -c < "$IC/pip.log" | tr -d ' ')" "4 0"
: > "$IC/pip.log"
ic env CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" --replace-unmarked >"$IC/setup6.log" 2>&1; ICRC=$?
chk "--replace-unmarked: 성공"                                  "$ICRC" "0"
chk "  사용자 트리는 삭제되지 않고 옆에 그대로 있음"             "$(cat "$IC_BR"/qemu-$IC_VER.unmarked.*/mine.c)" "users own"
chk "  새 트리가 표지와 함께 만들어짐"                           "$(ic_clean --status | ic_jv 'j["status"]')" "ok"
chk "  옮긴 트리는 이후 정리에서도 skipped_no_marker"            "$(ic_clean --layers L2 --clean | ic_jv 'any("unmarked" in s["path"] for s in j["skipped_no_marker"])')" "True"

# pip 최소 버전을 못 맞추면 기록하지 않고 멈춘다 (가짜 pip 가 낮은 버전만 설치하는 경우)
ic_home su_lowpip
mkdir -p "$IC_BR"; cp "$IC/qemu-$IC_VER.tar.xz" "$IC_BR/"
rm -rf "$IC/site/capstone-5.0.9.dist-info" "$IC/site/capstone.py"
cp "$IC/bin/pip3" "$IC/bin/pip3.bak"
sed -i.tmp 's/5\.0\.9/4.0.0/g' "$IC/bin/pip3"; rm -f "$IC/bin/pip3.tmp"
ic env CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/setup4.log" 2>&1; ICRC=$?
chk "pip 최소 버전 미달이면 종료코드 5"                         "$ICRC" "5"
chk "  그 환경은 env.json 으로 기록되지 않음"                   "$(ic_yes_no "[ ! -e '$IC_ENV' ]")" "yes"
mv "$IC/bin/pip3.bak" "$IC/bin/pip3"; rm -rf "$IC/site/capstone-4.0.0.dist-info" "$IC/site/capstone.py"

# =============================================================================
printf '\n\033[1m-- M. sudo 사전 점검: 비밀번호가 필요하면 설치·삭제 전에 멈춘다 (I1) --\033[0m\n'
# init 은 백그라운드로 돈다. 비밀번호를 기다리는 sudo 는 18 분 동안 아무에게도 안 보인 채 멈춘다.
ic_zero() { wc -c < "$1" | tr -d ' '; }
ic_reset_logs() { : > "$IC/pip.log"; : > "$IC/curl.log"; : > "$IC/apt.log"; : > "$IC/sudo.log"; }
ic_fresh_pip() { rm -f "$IC/site/capstone.py"; rm -rf "$IC/site/capstone-5.0.9.dist-info"; }

# M1. 비밀번호가 필요하고 apt 패키지가 필요하다 -> 아무것도 하지 않고 종료코드 7
ic_home su_nosudo
ic_tree "$IC_BR" "$IC_VER" "$IC_OLD" built 1; ic_envjson "$IC_ENV" "$IC_OLD" "$IC_VER" sboot-rehost '["capstone"]'
ic_tarball "$IC_BR" "$IC_VER" 1
ic_fresh_pip; ic_reset_logs
ICS1="$(ic_snap "$IC_BR")$(cksum < "$IC_ENV")"
ic env FAKE_SUDO_PASSWORD=1 CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/nosudo.out" 2>"$IC/nosudo.err"; ICRC=$?
chk "비밀번호가 필요한 sudo 면 종료코드 7 로 멈춘다 (멈춰 있지 않고)"  "$ICRC" "7"
chk "  BLOCKED_ENV 와 사용자가 실행할 apt-get 명령을 그대로 안내" \
    "$(grep -c 'BLOCKED_ENV' "$IC/nosudo.err")$(grep -c 'sudo apt-get update && sudo apt-get install -y build-essential' "$IC/nosudo.err")$(grep -c '/sboot-rehost:init' "$IC/nosudo.err")" "111"
chk "  sudo 는 -n true 시험만 불렸고 비밀번호를 기다리는 호출이 없음" \
    "$(sort -u "$IC/sudo.log" | tr '\n' '|')" "-n true|"
chk "  apt-get 도 pip 도 내려받기도 시작하지 않음" \
    "$(ic_zero "$IC/apt.log")/$(ic_zero "$IC/pip.log")/$(ic_zero "$IC/curl.log")" "0/0/0"
chk "  낡은 QEMU 트리·env.json·tarball 을 지우지 않음 (재구축 전에 멈춤)" "$(ic_snap "$IC_BR")$(cksum < "$IC_ENV")" "$ICS1"
chk "  계획 JSON 은 stdout 에: 재구축 예정이고 sudo 가 막힘" \
    "$(ic_jv '(j["action"], j["apt"]["needed"], j["apt"]["sudo"], "build-essential" in j["apt"]["missing"])' < "$IC/nosudo.out")" "('rebuild', True, 'unavailable', True)"
chk "  멈춤은 이어 가는 길을 남김: 다시 부르면 재구축 계획이 그대로 (표지 있는 트리 보존)" \
    "$(ic_plan | ic_jv 'j["action"]')" "rebuild"

# M2. --dry-run 도 같은 점검: 백그라운드를 띄우기 전에 알 수 있다
ic_reset_logs
ic env FAKE_SUDO_PASSWORD=1 bash "$IC_PLUG/scripts/setup_env.sh" --dry-run >"$IC/nosudo2.out" 2>/dev/null; ICRC=$?
chk "--dry-run 도 sudo 가 막히면 종료코드 7 과 계획 JSON" "$ICRC $(ic_jv 'j["apt"]["sudo"]' < "$IC/nosudo2.out")" "7 unavailable"
ic env bash "$IC_PLUG/scripts/setup_env.sh" --dry-run >"$IC/okdry.out" 2>/dev/null; ICRC=$?
chk "  sudo 가 비밀번호 없이 되면 --dry-run 은 0 이고 passwordless 로 보고" \
    "$ICRC $(ic_jv 'j["apt"]["sudo"]' < "$IC/okdry.out")" "0 passwordless"
chk "  그 점검은 sudo -n true 만 부르고 설치하지 않음" \
    "$(sort -u "$IC/sudo.log" | tr '\n' '|')/$(ic_zero "$IC/apt.log")" "-n true|/0"

# M3. apt 패키지가 이미 다 있으면 sudo 가 필요 없다 -> 비밀번호가 필요한 sudo 여도 끝까지 간다
ic_home su_aptok
mkdir -p "$IC_BR"; cp "$IC/qemu-$IC_VER.tar.xz" "$IC_BR/"
ic_fresh_pip; ic_reset_logs
ic env FAKE_SUDO_PASSWORD=1 FAKE_APT_INSTALLED=1 bash "$IC_PLUG/scripts/setup_env.sh" --dry-run >"$IC/aptok.out" 2>/dev/null; ICRC=$?
chk "apt 패키지가 모두 설치돼 있으면 sudo 를 시험하지도 않는다 (dry-run 0)" \
    "$ICRC $(ic_jv '(j["apt"]["needed"], j["apt"]["sudo"], j["apt"]["missing"])' < "$IC/aptok.out") $(ic_zero "$IC/sudo.log")" "0 (False, 'not_needed', []) 0"
ic env FAKE_SUDO_PASSWORD=1 FAKE_APT_INSTALLED=1 CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/aptok.log" 2>&1; ICRC=$?
chk "  sudo 가 막혀 있어도 pip·QEMU 단계는 끝까지 성공" "$ICRC $(ic_clean --status | ic_jv 'j["status"]')" "0 ok"
chk "  sudo 도 apt-get 도 부르지 않음" "$(ic_zero "$IC/sudo.log")/$(ic_zero "$IC/apt.log")" "0/0"

# M4. root 면 sudo 를 쓰지 않고 apt-get 을 직접 부른다 (sudo 가 없는 root 컨테이너에서도 동작)
mkdir -p "$IC/bin_root"
printf '#!/usr/bin/env bash\n[ "$1" = "-u" ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' > "$IC/bin_root/id"; chmod +x "$IC/bin_root/id"
ic_home su_root
mkdir -p "$IC_BR"; cp "$IC/qemu-$IC_VER.tar.xz" "$IC_BR/"
ic_fresh_pip; ic_reset_logs
ic env PATH="$IC/bin_root:$IC/bin:$PATH" FAKE_SUDO_PASSWORD=1 CURL_FORBID=1 bash "$IC_PLUG/scripts/setup_env.sh" >"$IC/root.log" 2>&1; ICRC=$?
chk "root 는 sudo 없이 apt-get 을 직접 부르고 성공" "$ICRC $(ic_zero "$IC/sudo.log") $(grep -c '^update$' "$IC/apt.log") $(grep -c '^install -y build-essential ' "$IC/apt.log")" "0 0 1 1"

# =============================================================================
printf '\n\033[1m-- N. init 의 순서: 막힐 일은 지우기 전에 안다 (사전 점검이 Step 3 의 삭제보다 앞선다) --\033[0m\n'
# SKILL.md 의 코드 블록에서 clean_env.sh · setup_env.sh 호출을 문서에 적힌 순서대로 뽑아 격리 환경에서
# 그대로 재생한다. 문서의 순서가 바뀌면(사전 점검이 정리 뒤로 가면) 아래 시나리오에서 트리·env.json 이
# 사라지므로 시험이 깨진다. [--flag] 는 사용자가 준 인자일 때만 켜고, 백그라운드 설치(끝이 &)는 재생하지 않는다.
ic_replay_list() {   # $1 = SKILL.md, $2.. = 사용자가 준 인자 -> 줄마다 "<스크립트> <인자…>" (<cwd>/rehost_workspaces 는 @WSROOT@)
    python3 - "$@" <<'PY'
import re, sys
skill, flags = sys.argv[1], set(sys.argv[2:])
text = open(skill, encoding="utf-8").read()
for block in re.findall(r"```bash\n(.*?)```", text, re.S):
    for line in block.replace("\\\n", " ").splitlines():
        m = re.match(r'bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/(clean_env|setup_env)\.sh"(.*)$', line.strip())
        if not m or m.group(2).rstrip().endswith("&"):
            continue
        rest = re.sub(r"\[(--[a-z-]+)\]", lambda k: k.group(1) if k.group(1) in flags else "", m.group(2))
        rest = rest.replace('"<cwd>/rehost_workspaces"', "@WSROOT@")
        print(m.group(1) + ".sh " + " ".join(rest.split()))
PY
}
IC_REPLAY_STOP=""; IC_REPLAY_RAN=0
ic_replay_run() {   # stdin = 명령 줄들. 사전 점검(setup_env.sh --dry-run)이 4·7 이면 문서대로 멈춘다 -> IC_REPLAY_STOP
    IC_REPLAY_STOP=""; IC_REPLAY_RAN=0
    local line name rest rc
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        name="${line%% *}"; rest="${line#* }"; [ "$rest" = "$line" ] && rest=""
        rest="${rest//@WSROOT@/$IC_WS}"
        rc=0; ic bash "$IC_PLUG/scripts/$name" $rest >/dev/null 2>&1 || rc=$?
        IC_REPLAY_RAN=$((IC_REPLAY_RAN + 1))
        case "$name $rest" in
            "setup_env.sh --dry-run"*) case "$rc" in 4|7) IC_REPLAY_STOP="$rc"; return 0 ;; esac ;;
        esac
    done
}
ic_world() {   # 모든 층에 지울 것이 있는 환경. $1=이름 $2=트리 종류(stale|unmarked)
    ic_home "$1"
    rm -rf "${IC:?}/tmp"; mkdir -p "$IC/tmp" "$ICH/rehost/_traces" "$IC_WS/_inbox" "$IC_WS/wsA"
    if [ "$2" = unmarked ]; then
        mkdir -p "$IC_BR/qemu-$IC_VER/build"; printf 'users own\n' > "$IC_BR/qemu-$IC_VER/mine.c"
    else
        ic_tree "$IC_BR" "$IC_VER" "$IC_OLD" built 1
        ic_envjson "$IC_ENV" "$IC_OLD" "$IC_VER" sboot-rehost '[]'
        ic_tarball "$IC_BR" "$IC_VER" 1
    fi
    printf 'old' > "$IC/tmp/sboot_old.log"; ic_old "$IC/tmp/sboot_old.log"
    printf 't' > "$ICH/rehost/_traces/run_1.log"; ic_old "$ICH/rehost/_traces/run_1.log"
    printf 'j' > "$IC_WS/wsA/JOURNAL.md"
}
ic_world_snap() { ic_snap "$ICH" "$IC/tmp" "$IC_WS"; }
ICSKILL="$REPO/skills/init/SKILL.md"
ICFLAGS="--clean --wipe-workspaces"

# N0. 재생이 비어 있지 않다 (재생이 아무것도 안 하면 아래 시험이 모두 공허하게 통과한다)
ICLIST="$(ic_replay_list "$ICSKILL" $ICFLAGS)"
chk "재생 목록에 사전 점검(setup_env.sh --dry-run)과 clean_env.sh 가 있다" \
    "$(echo "$ICLIST" | grep -c '^setup_env.sh --dry-run' | awk '{print ($1>0)}')$(echo "$ICLIST" | grep -c '^clean_env.sh' | awk '{print ($1>=2)}')" "11"
# 문서의 순서로도 확인한다: 사전 점검이 첫 실제 삭제(--dry-run·--status 가 아닌 clean_env.sh)보다 앞선다
chk "SKILL: 사전 점검(setup_env.sh --dry-run)이 첫 실제 정리(clean_env.sh)보다 앞선다" \
    "$(echo "$ICLIST" | grep -e '^setup_env.sh --dry-run' -e '^clean_env.sh' | grep -v -e '--status' -e '^clean_env.sh --dry-run' | head -1 | cut -d' ' -f1)" "setup_env.sh"

# N1. sudo 가 비밀번호를 요구하면 사전 점검(종료코드 7)에서 멈추고 L2·L3·L4 는 아무것도 지워지지 않는다
ic_world nm_sudo stale
ICS1="$(ic_world_snap)$(ic_snap "$IC_BR")$(cksum < "$IC_ENV")"
FAKE_SUDO_PASSWORD=1; export FAKE_SUDO_PASSWORD
ic_replay_run <<<"$ICLIST"
unset FAKE_SUDO_PASSWORD
chk "비밀번호가 필요한 sudo: 문서의 사전 점검이 종료코드 7 로 멈춘다" "$IC_REPLAY_STOP" "7"
chk "  --clean --wipe-workspaces 가 있어도 L2·L3·L4 가 전부 그대로 (트리·env.json·tarball·임시 파일·트레이스·워크스페이스)" \
    "$(ic_world_snap)$(ic_snap "$IC_BR")$(cksum < "$IC_ENV")" "$ICS1"
chk "  낡은 트리와 env.json 이 남아 있다" \
    "$(ic_yes_no "[ -x '$IC_BR/qemu-$IC_VER/build/qemu-system-aarch64' ] && [ -f '$IC_ENV' ] && [ -f '$IC_BR/qemu-$IC_VER.tar.xz' ]")" "yes"
chk "  워크스페이스는 보관 이동되지 않음" \
    "$(ic_yes_no "[ -f '$IC_WS/wsA/JOURNAL.md' ] && [ ! -d '$IC_WS/_archive' ]")" "yes"

# N2. 표지 없는 트리(종료코드 4)도 지우기 전에 멈춘다. --clean 이 L3 를 먼저 지우지 않는다
ic_world nm_unmarked unmarked
ICS1="$(ic_world_snap)$(ic_snap "$IC_BR")"
ic_replay_run <<<"$ICLIST"
chk "표지 없는 트리: 사전 점검이 종료코드 4 로 멈춘다" "$IC_REPLAY_STOP" "4"
chk "  사용자 트리·임시 파일·트레이스·워크스페이스가 그대로" "$(ic_world_snap)$(ic_snap "$IC_BR")" "$ICS1"

# N3. 양성 대조: sudo 가 막히지 않으면 같은 재생이 끝까지 가서 문서의 정리 명령이 실제로 지운다
ic_world nm_ok stale
ic_replay_run <<<"$ICLIST"
chk "sudo 가 통하면 사전 점검을 통과해 정리까지 진행한다 (정지 없음)" "[$IC_REPLAY_STOP]" "[]"
chk "  재생이 정리 명령을 실제로 실행: 낡은 트리·env.json·tarball(L2) 삭제" \
    "$(ic_yes_no "[ ! -d '$IC_BR/qemu-$IC_VER' ] && [ ! -e '$IC_ENV' ] && [ ! -e '$IC_BR/qemu-$IC_VER.tar.xz' ]")" "yes"
chk "  임시 파일(L3)도 삭제, 워크스페이스(L4)는 보관 이동" \
    "$(ic_yes_no "[ ! -e '$IC/tmp/sboot_old.log' ] && [ ! -d '$IC_WS/wsA' ] && [ -f \"\$(ls -d '$IC_WS'/_archive/wsA_*)/JOURNAL.md\" ]")" "yes"

# N4. 음성 대조: 사전 점검을 정리 뒤로 옮긴 순서(옛 문서)를 재생하면 같은 시나리오에서 트리를 잃는다.
#     이 대조가 깨지면 N1 은 순서를 가려내지 못하는 시험이다.
ic_world nm_old stale
ICREORDER="$( { echo "$ICLIST" | grep -v '^setup_env.sh --dry-run'; echo "$ICLIST" | grep '^setup_env.sh --dry-run'; } )"
FAKE_SUDO_PASSWORD=1; export FAKE_SUDO_PASSWORD
ic_replay_run <<<"$ICREORDER"
unset FAKE_SUDO_PASSWORD
chk "대조: 정리 뒤에 점검하면 7 로 멈추기 전에 이미 트리·env.json 이 지워져 있다" \
    "$IC_REPLAY_STOP $(ic_yes_no "[ ! -d '$IC_BR/qemu-$IC_VER' ] && [ ! -e '$IC_ENV' ]")" "7 yes"
rm -rf "${IC:?}/tmp"; mkdir -p "$IC/tmp"

# =============================================================================
printf '\n\033[1m-- L. 문법과 안내문 --\033[0m\n'
for icf in purge_cache.sh setup_env.sh check_env.sh sync_machine.sh qemu_tree.sh clean_env.sh; do
    bash -n "$REPO/scripts/$icf" 2>/dev/null; chk "bash -n scripts/$icf" "$?" "0"
done
ICSK="$REPO/skills/init/SKILL.md"
chk "SKILL: --clean 과 --wipe-workspaces 를 문서화"   "$(grep -c -e '--clean' "$ICSK" | awk '{print ($1>0)}')$(grep -c -e '--wipe-workspaces' "$ICSK" | awk '{print ($1>0)}')" "11"
chk "SKILL: L1 정리가 첫 단계이고 옛 버전 로드 시 정지" "$(grep -n 'purge_cache.sh' "$ICSK" | head -1 | cut -d: -f1 | awk '{print ($1>0)}')$(grep -c 'you \*\*must stop here\*\*' "$ICSK" | awk '{print ($1>0)}')" "11"
chk "SKILL: 매니페스트 비교와 18 분 사전 고지"          "$(grep -c 'env_manifest' "$ICSK" | awk '{print ($1>0)}')$(grep -c '18 분' "$ICSK" | awk '{print ($1>1)}')" "11"
chk "SKILL: 표지 없는 것은 지우지 않는다고 명시"         "$(grep -c 'skipped_no_marker' "$ICSK" | awk '{print ($1>0)}')" "1"
chk "SKILL: 지운 것의 경로와 크기 보고"                 "$(grep -c 'deleted (path, size), not deleted (reason)' "$ICSK" | awk '{print ($1>0)}')" "1"
chk "SKILL: 작업 기록은 보고가 기본, 이동은 보관 폴더"   "$(grep -c '_archive' "$ICSK" | awk '{print ($1>0)}')" "1"
chk "SKILL: 종료코드 7(sudo 비밀번호)을 문서화하고 묻지 않는다고 명시" \
    "$(grep -c 'sudo -n' "$ICSK" | awk '{print ($1>0)}')$(grep -c -e '\*\*`7`\*\*' "$ICSK" | awk '{print ($1>0)}')$(grep -c 'AskUserQuestion' "$ICSK" | awk '{print ($1>0)}')" "111"
# 정지 보고는 고정 문장이 아니라 실제로 지운 것(Step 0 의 purge_cache.sh 출력)을 옮긴다
chk "SKILL: '아무것도 설치하거나 지우지 않았습니다' 고정 문장이 없다 (Step 0 의 L1 삭제가 있을 수 있다)" \
    "$(grep -c '아무것도 설치하거나 지우지 않았습니다' "$ICSK")" "0"
chk "SKILL: 정지 보고가 Step 0 의 removed_detail 을 옮기고 Step 3 을 하지 않는다고 쓴다" \
    "$(grep -c 'removed_detail' "$ICSK" | awk '{print ($1>=2)}')$(grep -c 'Do not run Step 3' "$ICSK" | awk '{print ($1>=2)}')" "11"
chk "setup_env.sh 머리말이 종료코드 7 을 문서화" "$(grep -c '7 apt 설치가 필요한데 sudo' "$REPO/scripts/setup_env.sh" | awk '{print ($1>0)}')" "1"

rm -rf "$IC"
[ -n "${PARTS_STANDALONE:-}" ] && rm -rf "$ROOT"
parts_finish
