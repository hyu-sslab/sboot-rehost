#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# clean_env.sh - init 이 옛 환경을 정리하는 단계. 지운 것의 경로와 크기를 JSON 으로 보고한다.
#
# Usage:
#   clean_env.sh [--dry-run] [--clean] [--wipe-workspaces] [--layers L1,L2,L3,L4]
#                [--workspaces-root DIR]
#   clean_env.sh --status        (읽기 전용: 환경 매니페스트 비교 결과만 출력)
#
# 왜 필요한가
# -----------
# purge_cache.sh 는 플러그인 자신의 캐시만 정리한다. 그 플러그인이 만든 도구 체인
# (QEMU 트리, pip 모듈)과 파생물은 옛 것이 그대로 재사용됐고, 그래서 최신 플러그인으로
# 진행한다고 믿는 사용자가 옛 QEMU 로 돌았다. 층별로 나눠 정리한다.
#
#   L1 플러그인 캐시의 옛 버전, __pycache__   purge_cache.sh 를 그대로 쓴다
#   L2 도구 체인  ~/qemu-build 의 트리·tarball, ~/.sboot/env.json, pip 모듈
#   L3 임시·파생물 /tmp/sboot_*, ~/rehost/_traces/run_*.log
#   L4 워크스페이스 rehost_workspaces/<id>   기본은 보고만
#
# 지우는 기준
# -----------
# 기본은 **옛 것으로 입증된 것만** 지운다. 입증은 층마다 다르다.
#   L1  최신이 아닌 버전 폴더 (purge_cache.sh)
#   L2  표지가 있는 트리가 환경 매니페스트(env_manifest.json)와 어긋남
#   L3  마지막 수정이 CLEAN_MIN_AGE_SEC(기본 3600) 이전 — 실행 중인 것을 지우지 않는다
#   L4  지우지 않는다. 옛 버전이 만든 것(.sboot_version 이 다르거나 없음)을 보고한다
# --clean 은 L1~L3 를 조건 없이 지운다 (L2 의 표지 규칙은 그대로다).
# --wipe-workspaces 는 L4 를 삭제가 아니라 rehost_workspaces/_archive/<id>_<시각> 으로 옮긴다.
#
# 표지 규칙: 지우는 것은 **이 플러그인이 만들었다는 표지가 있는 것뿐**이다.
#   트리      <트리>/.sboot_created (created_by=sboot-rehost)
#   tarball   <tarball>.sboot_created (setup_env.sh 가 직접 내려받았을 때만 만든다)
#   env.json  created_by=sboot-rehost
#   pip 모듈  env.json 의 pip_installed (init 이 설치하기 전에는 없던 것)
#   임시      이름 패턴 (sboot_*, run_*.log)
# 표지가 없는 것은 skipped_no_marker 로 보고하고 **어떤 옵션으로도 지우지 않는다.**
# 사용자가 따로 설치한 QEMU 를 init 이 지우면 안 된다.
#
# --dry-run 이면 아무것도 바꾸지 않고, 목록은 "지워질 것"을 뜻한다.
#
# stdout: JSON 한 개
#   removed[{path,bytes,layer}]  지운 것 (pip 모듈은 path 가 pip:<이름>, bytes 는 null)
#   kept[{path,layer,reason}]    남긴 것
#   skipped_no_marker[...]       표지가 없어 지우지 않은 것
#   workspaces_old[{id,path,version,reason}]  옛 버전이 만든 워크스페이스
#   archived[{from,to,bytes}]    --wipe-workspaces 로 옮긴 것
#   l2{status,reasons,rebuild_needed,...}     환경 매니페스트 비교 결과
# 종료코드: 0 정상 · 1 세션이 옛 버전(재시작 필요)이거나 일부 실패 · 2 사용법
#
# 환경(시험·비표준 배치용): QEMU_BUILD_ROOT(~/qemu-build) ENV_MANIFEST ENV_STATE(~/.sboot/env.json)
#   TRACE_DIR(~/rehost/_traces) SBOOT_TMP_DIRS(콜론 구분, 기본 $TMPDIR 와 /tmp) CLEAN_MIN_AGE_SEC

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export SBOOT_SCRIPTS_DIR="$HERE" SBOOT_PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
command -v python3 >/dev/null 2>&1 || {
    echo '{"ok":false,"notes":["python3 가 없어 정리를 수행할 수 없습니다"]}'; exit 1; }
exec python3 - "$@" <<'PY'
import fnmatch, json, os, re, shutil, subprocess, sys, time

CREATOR = "sboot-rehost"
MARKER = ".sboot_created"
SIDECAR = ".sboot_created"          # tarball 옆에 두는 표지: <tarball>.sboot_created
PIP_CMD = os.environ.get("PIP", "pip3")

HOME = os.path.expanduser("~")
SCRIPTS = os.environ["SBOOT_SCRIPTS_DIR"]
PLUGIN_DIR = os.environ["SBOOT_PLUGIN_DIR"]
BUILD_ROOT = os.environ.get("QEMU_BUILD_ROOT") or os.path.join(HOME, "qemu-build")
MANIFEST = os.environ.get("ENV_MANIFEST") or os.path.join(PLUGIN_DIR, "env_manifest.json")
STATE = os.environ.get("ENV_STATE") or os.path.join(HOME, ".sboot", "env.json")
TRACE_DIR = os.environ.get("TRACE_DIR") or os.path.join(HOME, "rehost", "_traces")
try:
    MIN_AGE = int(os.environ.get("CLEAN_MIN_AGE_SEC", "3600"))
except ValueError:
    MIN_AGE = 3600


# ---------------------------------------------------------------- 공용 도우미
def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", str(v or "")))


def vcmp(a, b):
    """-1/0/1 over dotted numbers, zero-padded so 5.0 == 5.0.0."""
    ta, tb = vtuple(a), vtuple(b)
    n = max(len(ta), len(tb))
    ta, tb = ta + (0,) * (n - len(ta)), tb + (0,) * (n - len(tb))
    return (ta > tb) - (ta < tb)


def to_int(value, default=-1):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def load_json(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def path_bytes(path):
    """What removing it frees. lstat only - never follow a symlink out of the tree."""
    try:
        st = os.lstat(path)
    except OSError:
        return 0
    if not os.path.isdir(path) or os.path.islink(path):
        return st.st_size
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def newest_mtime(path):
    """Newest mtime in a tree - a live writer keeps this fresh."""
    try:
        newest = os.lstat(path).st_mtime
    except OSError:
        return 0
    if os.path.isdir(path) and not os.path.islink(path):
        for root, dirs, files in os.walk(path):
            for name in dirs + files:
                try:
                    newest = max(newest, os.lstat(os.path.join(root, name)).st_mtime)
                except OSError:
                    pass
    return newest


def real_date(fmt):
    """The real clock through date(1) - a journal-grade timestamp, not an invented one."""
    try:
        p = subprocess.run(["date", fmt], capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip()
    except OSError:
        pass
    return time.strftime(fmt.lstrip("+"))


# ---------------------------------------------------------------- 환경 매니페스트 비교
def read_manifest():
    man = load_json(MANIFEST)
    if not isinstance(man, dict) or "env_revision" not in man or "qemu_version" not in man:
        return None
    return man


def read_marker(tree):
    """A tree's creation marker, or None. A marker that does not name us is not ours."""
    data = load_json(os.path.join(tree, MARKER))
    if isinstance(data, dict) and data.get("created_by") == CREATOR:
        return data
    return None


def read_env_state():
    """-> (state | None, foreign). foreign=True: a file exists but is not ours."""
    if not os.path.exists(STATE):
        return None, False
    data = load_json(STATE)
    if isinstance(data, dict) and data.get("created_by") == CREATOR:
        return data, False
    return None, True


def scan_trees():
    """Every qemu-* directory under the build root, with its marker (None if absent)."""
    trees = []
    try:
        names = sorted(os.listdir(BUILD_ROOT))
    except OSError:
        return trees
    for name in names:
        full = os.path.join(BUILD_ROOT, name)
        if not name.startswith("qemu-") or name.endswith(".tar.xz") or name.endswith(SIDECAR):
            continue
        if not os.path.isdir(full):
            continue
        symlink = os.path.islink(full)
        trees.append({"path": full, "name": name, "symlink": symlink,
                      "marker": None if symlink else read_marker(full)})
    return trees


def installed_version(name):
    try:
        from importlib import metadata
        return metadata.version(name)
    except Exception:
        return None


def pip_status(man):
    out = []
    for name, spec in sorted((man.get("pip") or {}).items()):
        low = (spec or {}).get("min")
        optional = bool((spec or {}).get("optional"))
        have = installed_version(name)
        if have is None:
            if not optional:
                out.append({"name": name, "installed": None, "min": low, "optional": optional})
        elif low and vcmp(have, low) < 0:
            out.append({"name": name, "installed": have, "min": low, "optional": optional})
    return out


def inspect_env(man):
    req_rev, req_ver = int(man["env_revision"]), str(man["qemu_version"])
    expected = os.path.join(BUILD_ROOT, "qemu-" + req_ver)
    env, foreign = read_env_state()
    trees = scan_trees()
    by_path = {t["path"]: t for t in trees}
    tree = by_path.get(expected)
    reasons, notes = [], []
    status = "ok"

    if tree is not None and tree["marker"] is None:
        status = "unmarked"
        reasons.append("%s 가 있지만 표지(%s)가 없습니다 — 이 플러그인이 만든 것으로 확인되지 않아 "
                       "최신 여부를 보증할 수 없고 지우지도 않습니다" % (expected, MARKER))
    elif tree is not None:
        mk = tree["marker"]
        binary = os.path.join(expected, "build", "qemu-system-aarch64")
        if mk.get("qemu_version") != req_ver:
            status = "stale"
            reasons.append("트리의 QEMU 버전 %s 이(가) 요구 %s 와 다릅니다" % (mk.get("qemu_version"), req_ver))
        elif to_int(mk.get("env_revision")) < req_rev:
            status = "stale"
            reasons.append("트리의 env_revision %s 이(가) 요구 %d 보다 낮습니다" % (mk.get("env_revision"), req_rev))
        elif mk.get("state") != "built":
            status = "incomplete"
            reasons.append("QEMU 빌드가 끝나지 않았습니다 (state=%s) — setup_env.sh 가 이어서 빌드합니다" % mk.get("state"))
        elif env is None:
            status = "stale"
            reasons.append("환경 상태 파일(%s)이 없거나 이 플러그인이 만든 것이 아닙니다" % STATE)
        elif env.get("qemu_version") != req_ver:
            status = "stale"
            reasons.append("env.json 의 QEMU 버전 %s 이(가) 요구 %s 와 다릅니다" % (env.get("qemu_version"), req_ver))
        elif to_int(env.get("env_revision")) < req_rev:
            status = "stale"
            reasons.append("env.json 의 env_revision %s 이(가) 요구 %d 보다 낮습니다" % (env.get("env_revision"), req_rev))
        elif not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
            status = "stale"
            reasons.append("빌드 산출물이 없습니다: %s" % binary)
        elif to_int(env.get("env_revision")) > req_rev:
            notes.append("환경 개정 %s 이(가) 요구 %d 보다 새롭습니다 — 그대로 씁니다" % (env.get("env_revision"), req_rev))
    else:
        status = "missing"
        reasons.append("%s 가 없습니다" % expected)
        if env is not None:
            reasons.append("env.json 은 남아 있으나 가리키는 트리가 없습니다")
    if foreign:
        notes.append("%s 가 있지만 이 플러그인이 만든 것이 아니어서 건드리지 않습니다" % STATE)

    stale_trees = []
    for t in trees:
        mk = t["marker"]
        if mk is None:
            continue
        old = (mk.get("qemu_version") != req_ver) or (to_int(mk.get("env_revision")) < req_rev)
        if old or (t["path"] == expected and status == "stale"):
            stale_trees.append(t["path"])

    return {
        "status": status,
        "reasons": reasons,
        "notes": notes,
        "rebuild_needed": status != "ok",
        "blocked_by_unmarked": status == "unmarked",
        "required": {"env_revision": req_rev, "qemu_version": req_ver},
        "current": env,
        "build_root": BUILD_ROOT,
        "qemu_dir": expected,
        "env_state_path": STATE,
        "tree_present": tree is not None,
        "tree_marked": bool(tree and tree["marker"]),
        "stale_trees": stale_trees,
        "pip_outdated": pip_status(man),
        "_trees": trees, "_env": env, "_foreign_env": foreign,
    }


def public(info):
    return {k: v for k, v in info.items() if not k.startswith("_")}


# ---------------------------------------------------------------- 보고서
class Report:
    def __init__(self, args):
        self.args = args
        self.removed, self.kept, self.skipped = [], [], []
        self.workspaces_old, self.archived = [], []
        self.failed, self.notes = [], []
        self.needs_restart = False
        self.extra = {}

    def remove(self, path, layer, reason=""):
        size = path_bytes(path)
        if not self.args["dry_run"]:
            try:
                if os.path.isdir(path) and not os.path.islink(path):
                    shutil.rmtree(path)
                else:
                    os.remove(path)
            except OSError as exc:
                self.failed.append("%s: %s" % (path, exc))
                return False
        entry = {"path": path, "bytes": size, "layer": layer}
        if reason:
            entry["reason"] = reason
        self.removed.append(entry)
        return True

    def keep(self, path, layer, reason):
        self.kept.append({"path": path, "layer": layer, "reason": reason})

    def skip(self, path, layer, reason):
        self.skipped.append({"path": path, "layer": layer, "reason": reason})


# ---------------------------------------------------------------- L1
def layer1(rep):
    cmd = ["bash", os.path.join(SCRIPTS, "purge_cache.sh")]
    if rep.args["dry_run"]:
        cmd.append("--dry-run")
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as exc:
        rep.failed.append("purge_cache.sh 를 실행하지 못했습니다: %s" % exc)
        return
    try:
        j = json.loads(p.stdout)
    except ValueError:
        rep.failed.append("purge_cache.sh 출력을 읽지 못했습니다 (종료코드 %d)" % p.returncode)
        return
    for r in j.get("removed_detail", []):
        rep.removed.append({"path": r["path"], "bytes": r["bytes"], "layer": "L1",
                            "reason": "옛 플러그인 버전 %s" % r["version"]})
    for r in j.get("pycache_detail", []):
        rep.removed.append({"path": r["path"], "bytes": r["bytes"], "layer": "L1",
                            "reason": "__pycache__"})
    for r in j.get("kept_detail", []):
        rep.keep(r["path"], "L1", "최신 버전 %s" % r["version"])
    for f in j.get("failed", []):
        rep.failed.append("L1 " + f)
    if j.get("needs_restart"):
        rep.needs_restart = True
        rep.extra["restart"] = {"note": j.get("note"), "commands": j.get("commands", []),
                                "session_version": j.get("session_version"), "keep": j.get("keep")}
        rep.notes.append(j.get("note") or "세션이 옛 버전을 로드 중입니다")


# ---------------------------------------------------------------- L2
def layer2(rep, man):
    clean = rep.args["clean"]
    info = inspect_env(man)
    rep.extra["l2"] = public(info)
    req_ver = info["required"]["qemu_version"]
    trees = info["_trees"]
    stale = set(info["stale_trees"])
    removed_trees = []

    for t in trees:
        if t["marker"] is None:
            why = "심볼릭 링크라 따라가지 않습니다" if t["symlink"] else \
                "표지(%s)가 없습니다 — 이 플러그인이 만든 것으로 확인되지 않아 지우지 않습니다" % MARKER
            rep.skip(t["path"], "L2", why)
            continue
        if clean or t["path"] in stale:
            why = "--clean" if clean else "환경 매니페스트와 어긋남"
            if rep.remove(t["path"], "L2", why):
                removed_trees.append(t["path"])
        else:
            rep.keep(t["path"], "L2", "환경 매니페스트와 일치" if t["path"] == info["qemu_dir"]
                     else "표지 있음, 요구 버전")

    # tarball: setup_env.sh 가 직접 내려받은 것(옆에 표지 파일)만. 같은 버전이면 재사용하려고 둔다.
    try:
        names = sorted(os.listdir(BUILD_ROOT))
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".tar.xz"):
            continue
        tar = os.path.join(BUILD_ROOT, name)
        side = tar + SIDECAR
        if not os.path.isfile(side):
            if os.path.isfile(tar):
                rep.skip(tar, "L2", "내려받았다는 표지(%s)가 없습니다 — 지우지 않습니다" % os.path.basename(side))
            continue
        m = re.fullmatch(r"qemu-(.+)\.tar\.xz", name)
        ver = m.group(1) if m else None
        if clean or ver != req_ver:
            if rep.remove(tar, "L2", "--clean" if clean else "요구 버전 %s 이(가) 아닌 tarball" % req_ver):
                rep.remove(side, "L2")
        else:
            rep.keep(tar, "L2", "같은 버전 소스 — 재구축에 재사용 (pristine 복원의 원본)")

    # 추출 중 끊긴 임시 폴더 (setup_env.sh 가 만드는 이름)
    for name in names:
        full = os.path.join(BUILD_ROOT, name)
        if name.startswith(".extract.") and os.path.isdir(full) and not os.path.islink(full):
            if clean or time.time() - newest_mtime(full) >= MIN_AGE:
                rep.remove(full, "L2", "추출이 끊긴 임시 폴더")
            else:
                rep.keep(full, "L2", "최근 수정 — 추출 중일 수 있어 보존")

    # env.json: 표지(created_by)가 있을 때만. 트리가 사라졌거나 낡았으면 더는 현재를 말하지 않는다.
    env, foreign = info["_env"], info["_foreign_env"]
    if foreign:
        rep.skip(STATE, "L2", "created_by=%s 표지가 없습니다 — 이 플러그인이 만든 것으로 확인되지 않아 지우지 않습니다" % CREATOR)
    elif env is not None:
        if clean or info["status"] in ("stale", "missing"):
            rep.remove(STATE, "L2", "--clean" if clean else "가리키는 트리가 없거나 낡음")
        else:
            rep.keep(STATE, "L2", "환경 매니페스트와 일치" if info["status"] == "ok" else "빌드가 이어질 때까지 보존")

    # pip 모듈: init 이 설치한 것만, --clean 일 때만 (옛 버전 모듈은 setup_env.sh 가 다시 설치한다).
    if clean and env is not None:
        for name in env.get("pip_installed") or []:
            if installed_version(name) is None:
                continue
            if rep.args["dry_run"]:
                rep.removed.append({"path": "pip:%s" % name, "bytes": None, "layer": "L2", "reason": "--clean"})
                continue
            ok = False
            for extra in (["--break-system-packages"], []):
                p = subprocess.run([PIP_CMD, "uninstall", "-y"] + extra + [name], capture_output=True, text=True)
                if p.returncode == 0:
                    ok = True
                    break
            if ok:
                rep.removed.append({"path": "pip:%s" % name, "bytes": None, "layer": "L2", "reason": "--clean"})
            else:
                rep.failed.append("pip 모듈 %s 를 지우지 못했습니다" % name)
    elif not clean and info["pip_outdated"]:
        for o in info["pip_outdated"]:
            rep.notes.append("pip 모듈 %s 가 최소 버전 %s 에 못 미칩니다 (설치 %s) — setup_env.sh 가 이 모듈만 다시 설치합니다"
                             % (o["name"], o["min"], o["installed"] or "없음"))

    # 비어 버린 상위 폴더만 치운다. 사용자 파일이 하나라도 있으면 남는다.
    if not rep.args["dry_run"]:
        for d in (BUILD_ROOT, os.path.dirname(STATE)):
            try:
                if os.path.isdir(d) and not os.listdir(d) and (removed_trees or clean or d != BUILD_ROOT):
                    os.rmdir(d)
                    rep.removed.append({"path": d, "bytes": 0, "layer": "L2", "reason": "비어 있음"})
            except OSError:
                pass

    if clean:
        info["rebuild_needed"] = True
        rep.extra["l2"]["rebuild_needed"] = True
    # 지운 뒤의 상태를 다시 판정해 호출자가 곧바로 재구축을 판단하게 한다.
    if not rep.args["dry_run"]:
        after = inspect_env(man)
        rep.extra["l2"]["status_after"] = after["status"]
        rep.extra["l2"]["rebuild_needed"] = after["rebuild_needed"]
        rep.extra["l2"]["blocked_by_unmarked"] = after["blocked_by_unmarked"]


# ---------------------------------------------------------------- L3
def tmp_dirs():
    raw = os.environ.get("SBOOT_TMP_DIRS")
    cands = raw.split(":") if raw else [os.environ.get("TMPDIR") or "", "/tmp"]
    seen, out = set(), []
    for c in cands:
        if not c or not os.path.isdir(c):
            continue
        real = os.path.realpath(c)
        if real not in seen:
            seen.add(real)
            out.append(c)
    return out


def layer3(rep):
    clean = rep.args["clean"]
    now = time.time()

    def maybe_remove(path, reason_old):
        if os.path.islink(path):
            rep.skip(path, "L3", "심볼릭 링크라 지우지 않습니다")
            return
        age = now - newest_mtime(path)
        if clean or age >= MIN_AGE:
            rep.remove(path, "L3", "--clean" if clean else reason_old)
        else:
            rep.keep(path, "L3", "최근 수정(%d 분 이내) — 실행 중일 수 있어 보존" % max(1, int(MIN_AGE // 60)))

    for d in tmp_dirs():
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for name in names:
            if fnmatch.fnmatch(name, "sboot_*"):
                maybe_remove(os.path.join(d, name), "임시 파일")

    if os.path.isdir(TRACE_DIR):
        for name in sorted(os.listdir(TRACE_DIR)):
            full = os.path.join(TRACE_DIR, name)
            if fnmatch.fnmatch(name, "run_*.log"):
                maybe_remove(full, "지난 회차 트레이스")
            else:
                rep.skip(full, "L3", "이름이 플러그인 패턴(run_*.log)과 다릅니다 — 지우지 않습니다")
        if not rep.args["dry_run"]:
            try:
                if not os.listdir(TRACE_DIR):
                    os.rmdir(TRACE_DIR)
            except OSError:
                pass

    # 이전 펌웨어가 QEMU 트리에 더한 파일: 지금 되돌리면 이미 빌드된 워크스페이스의 머신이
    # 코어 패치를 잃는다. Build 가 시작할 때 qemu_tree.sh reset 으로 되돌리므로 보고만 한다.
    man = read_manifest()
    if man:
        tree = os.path.join(BUILD_ROOT, "qemu-" + str(man["qemu_version"]))
        touched = os.path.join(tree, ".sboot_touched")
        try:
            n = sum(1 for line in open(touched) if line.strip())
        except OSError:
            n = 0
        if n and os.path.isdir(tree) and not clean:
            rep.keep(touched, "L3", "이전 펌웨어가 QEMU 트리에 더한 %d 건 — Build 시작 시 qemu_tree.sh reset 이 되돌립니다" % n)


# ---------------------------------------------------------------- L4
def plugin_version():
    j = load_json(os.path.join(PLUGIN_DIR, ".claude-plugin", "plugin.json"))
    return j.get("version") if isinstance(j, dict) else None


def layer4(rep, root):
    pv = plugin_version()
    if not os.path.isdir(root):
        rep.notes.append("워크스페이스 루트가 없습니다: %s" % root)
        return
    if pv is None:
        rep.notes.append("플러그인 버전을 읽지 못해 워크스페이스의 옛 버전 여부를 판정하지 않았습니다")
    ids = [n for n in sorted(os.listdir(root))
           if not n.startswith("_") and not n.startswith(".")
           and os.path.isdir(os.path.join(root, n)) and not os.path.islink(os.path.join(root, n))]
    wipe = rep.args["wipe_workspaces"]
    archive = os.path.join(root, "_archive")
    stamp = real_date("+%Y%m%dT%H%M%S")
    moved_ids = []
    for wid in ids:
        full = os.path.join(root, wid)
        try:
            with open(os.path.join(full, ".sboot_version")) as fh:
                ver = fh.read().strip() or None
        except OSError:
            ver = None
        if pv is not None and ver != pv:
            rep.workspaces_old.append({
                "id": wid, "path": full, "version": ver,
                "reason": "표지(.sboot_version) 없음 — 어느 버전이 만든 것인지 알 수 없음" if ver is None
                else "플러그인 %s 가 만듦 (현재 %s)" % (ver, pv)})
        if not wipe:
            rep.keep(full, "L4", "작업 기록 보존 (삭제는 --wipe-workspaces 로 보관 이동)")
            continue
        dest = os.path.join(archive, "%s_%s" % (wid, stamp))
        n = 1
        while os.path.exists(dest):
            dest = os.path.join(archive, "%s_%s-%d" % (wid, stamp, n))
            n += 1
        size = path_bytes(full)
        if not rep.args["dry_run"]:
            try:
                os.makedirs(archive, exist_ok=True)
                shutil.move(full, dest)
            except OSError as exc:
                rep.failed.append("%s 를 보관하지 못했습니다: %s" % (full, exc))
                continue
        rep.archived.append({"from": full, "to": dest, "bytes": size})
        moved_ids.append(wid)
    if moved_ids:
        active = os.path.join(root, ".active")
        try:
            cur = open(active).read().strip()
        except OSError:
            cur = None
        if cur in moved_ids:
            rep.notes.append(".active 가 보관한 워크스페이스(%s)를 가리킵니다 — 파일은 그대로 둡니다" % cur)
        rep.notes.append("보관한 워크스페이스는 삭제가 아니라 이동입니다: %s" % archive)
    if os.path.isdir(os.path.join(root, "_inbox")):
        rep.keep(os.path.join(root, "_inbox"), "L4", "펌웨어 드롭 폴더")


# ---------------------------------------------------------------- 진입점
def main(argv):
    args = {"dry_run": False, "clean": False, "wipe_workspaces": False, "status": False,
            "layers": ["L1", "L2", "L3", "L4"],
            "root": os.path.join(os.getcwd(), "rehost_workspaces")}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dry-run":
            args["dry_run"] = True
        elif a == "--clean":
            args["clean"] = True
        elif a == "--wipe-workspaces":
            args["wipe_workspaces"] = True
        elif a == "--status":
            args["status"] = True
        elif a == "--layers" and i + 1 < len(argv):
            args["layers"] = [x.strip().upper() for x in argv[i + 1].split(",") if x.strip()]
            i += 1
        elif a == "--workspaces-root" and i + 1 < len(argv):
            args["root"] = argv[i + 1]
            i += 1
        else:
            print("알 수 없는 인자: %s" % a, file=sys.stderr)
            print("사용법: clean_env.sh [--dry-run] [--clean] [--wipe-workspaces] "
                  "[--layers L1,L2,L3,L4] [--workspaces-root DIR] | --status", file=sys.stderr)
            return 2
        i += 1
    bad = [x for x in args["layers"] if x not in ("L1", "L2", "L3", "L4")]
    if bad:
        print("알 수 없는 층: %s" % ",".join(bad), file=sys.stderr)
        return 2

    man = read_manifest()
    if args["status"]:
        if man is None:
            print(json.dumps({"status": "unknown", "rebuild_needed": True,
                              "reasons": ["환경 매니페스트를 읽지 못했습니다: %s" % MANIFEST]},
                             ensure_ascii=False))
            return 0
        print(json.dumps(public(inspect_env(man)), ensure_ascii=False, indent=2))
        return 0

    rep = Report(args)
    ran = []
    if "L1" in args["layers"]:
        ran.append("L1")
        layer1(rep)
    if rep.needs_restart:
        rep.notes.append("세션이 옛 버전이라 여기서 멈춥니다 — L2 이후는 재시작한 뒤 다시 실행하세요")
    else:
        if "L2" in args["layers"]:
            ran.append("L2")
            if man is None:
                rep.failed.append("환경 매니페스트를 읽지 못해 L2 를 건너뜁니다: %s" % MANIFEST)
            else:
                layer2(rep, man)
        if "L3" in args["layers"]:
            ran.append("L3")
            layer3(rep)
        if "L4" in args["layers"]:
            ran.append("L4")
            layer4(rep, args["root"])

    notes = list(rep.notes)
    if args["dry_run"]:
        notes.insert(0, "dry-run: 아무것도 바꾸지 않았습니다. removed/archived 는 \"지워질 것\"입니다")
    out = {
        "ok": not rep.needs_restart and not rep.failed,
        "dry_run": args["dry_run"], "clean": args["clean"], "wipe_workspaces": args["wipe_workspaces"],
        "plugin_version": plugin_version(),
        "layers": ran,
        "needs_restart": rep.needs_restart,
        "removed": rep.removed,
        "kept": rep.kept,
        "skipped_no_marker": rep.skipped,
        "workspaces_old": rep.workspaces_old,
        "archived": rep.archived,
        "failed": rep.failed,
        "freed_bytes": sum(r["bytes"] or 0 for r in rep.removed),
        "notes": notes,
    }
    out.update(rep.extra)
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0 if out["ok"] else 1


sys.exit(main(sys.argv[1:]))
PY
