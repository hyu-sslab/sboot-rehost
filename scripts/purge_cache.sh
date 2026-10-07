#!/usr/bin/env bash
# purge_cache.sh — 옛 버전 캐시를 지우고, 세션이 최신을 로드했는지 강제한다.
#
# 왜 필요한가:
#   플러그인 캐시는 버전마다 폴더가 남는다. 옛 폴더가 있으면 어떤 경로로든 옛 스킬·
#   에이전트·스크립트가 다시 로드될 수 있고, 그러면 회차·로그·판정이 전부 옛 규칙을
#   따른다. 이 저장소에서 실제로 0.2.0 과 0.17.0 이 남아 있었고 세션은 0.17.0 을
#   로드하고 있었다 — 저장소가 0.24.0 인데도.
#
#   **세션이 이미 로드한 것은 지워도 바뀌지 않는다.** 그래서 이 스크립트는 두 가지를
#   한다: 옛 캐시를 실제로 없애고, 세션이 최신이 아니면 종료코드 1 로 막는다.
#   막지 않고 진행하면 "정리했다"는 보고와 함께 옛 코드가 계속 돈다.
#
# 사용법:
#   purge_cache.sh [--keep <version>] [--dry-run]
#
# 종료코드: 0 최신으로 정리됨 · 1 재시작 필요 · 2 판정 불가(캐시 없음 등)
#
# 출력 JSON: removed/kept 는 버전 목록이고, removed_detail/kept_detail/pycache_detail 은
# 경로와 크기(bytes)를 담는다. clean_env.sh 가 이것을 읽어 "무엇을 얼마나 지웠는지" 보고한다.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
CACHE_ROOT="${CACHE_ROOT:-$HOME/.claude/plugins/cache}"
REGISTRY="${REGISTRY:-$HOME/.claude/plugins/installed_plugins.json}"

KEEP=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) shift;;
  esac
done

python3 - "$PLUGIN_DIR" "$CACHE_ROOT" "$REGISTRY" "$KEEP" "$DRY" <<'PY'
import json, os, re, shutil, sys

plugin_dir, cache_root, registry, keep_arg, dry = sys.argv[1:6]
dry = dry == "1"


def semver(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or "0")[:3] or [0])


def dir_bytes(path):
    """Size of a tree without following symlinks - what removing it frees."""
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def repo_version():
    path = os.path.join(plugin_dir, ".claude-plugin", "plugin.json")
    try:
        with open(path) as fh:
            return json.load(fh).get("version")
    except (OSError, ValueError):
        return None


def session_version():
    """What this session actually loaded - the only version that is running."""
    try:
        with open(registry) as fh:
            blob = fh.read()
    except OSError:
        return None
    best = None
    for m in re.finditer(r'sboot-rehost[^{}]*?"version"\s*:\s*"([0-9][0-9.]*)"', blob):
        if best is None or semver(m.group(1)) > semver(best):
            best = m.group(1)
    return best


# Every cached copy of THIS plugin. Other plugins are never touched.
version_dirs = []
if os.path.isdir(cache_root):
    for market in sorted(os.listdir(cache_root)):
        base = os.path.join(cache_root, market, "sboot-rehost")
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            full = os.path.join(base, name)
            if os.path.isdir(full) and re.fullmatch(r"\d+(\.\d+)*", name):
                version_dirs.append((name, full))

repo = repo_version()
keep = keep_arg or repo or (max((v for v, _ in version_dirs), key=semver)
                            if version_dirs else None)

# removed/kept stay version lists (callers read them); the *_detail lists carry the
# path and size so a cleanup report can say exactly what went and what it freed.
removed, kept, failed = [], [], []
removed_detail, kept_detail = [], []
for version, path in version_dirs:
    if version == keep:
        kept.append(version)
        kept_detail.append({"version": version, "path": path})
        continue
    size = dir_bytes(path)
    if dry:
        removed.append(version)
        removed_detail.append({"version": version, "path": path, "bytes": size})
        continue
    try:
        shutil.rmtree(path)
        removed.append(version)
        removed_detail.append({"version": version, "path": path, "bytes": size})
    except OSError as exc:
        failed.append(f"{version}: {exc}")

# Stale bytecode in the plugin tree. A .pyc compiled from a since-edited script
# is the same class of problem in miniature.
pyc = 0
pyc_detail = []
for root, dirs, files in os.walk(plugin_dir):
    if "__pycache__" in dirs:
        target = os.path.join(root, "__pycache__")
        size = dir_bytes(target)
        if not dry:
            try:
                shutil.rmtree(target)
            except OSError:
                pass
        pyc += 1
        pyc_detail.append({"path": target, "bytes": size})
        dirs.remove("__pycache__")

session = session_version()
needs_restart = bool(session and keep and semver(session) < semver(keep))
if session is None:
    note = ("세션이 로드한 버전을 확인하지 못했습니다 — 등록부를 읽을 수 없습니다. "
            "개발 체크아웃이면 정상입니다.")
elif needs_restart:
    lost = session in removed
    note = (f"세션은 {session} 을 로드했고 최신은 {keep} 입니다. "
            "캐시는 정리했지만 **이미 로드된 것은 바뀌지 않습니다**"
            + (f" — 방금 지운 것이 그 {session} 이므로 재시작 전까지 이 세션의 "
               "명령은 동작하지 않을 수 있습니다." if lost else " —")
            + " 아래를 실행하고 Claude Code 를 재시작한 뒤 다시 부르십시오.")
else:
    note = f"세션이 최신({session or keep})을 로드했습니다."

print(json.dumps({
    "ok": not needs_restart and not failed,
    "keep": keep,
    "repo_version": repo,
    "session_version": session,
    "removed": removed,
    "kept": kept,
    "removed_detail": removed_detail,
    "kept_detail": kept_detail,
    "failed": failed,
    "pycache_removed": pyc,
    "pycache_detail": pyc_detail,
    "dry_run": dry,
    "needs_restart": needs_restart,
    "note": note,
    "commands": [
        "/plugin marketplace update sboot-rehost-marketplace",
        "/plugin install sboot-rehost@sboot-rehost-marketplace",
    ] if needs_restart else [],
}, ensure_ascii=False, indent=2))
sys.exit(1 if needs_restart or failed else 0)
PY
