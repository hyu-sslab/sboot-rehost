#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# qemu_tree.sh - QEMU 소스 트리를 pristine 상태로 되돌린다.
#
# Usage:
#   qemu_tree.sh reset  [--qemu-src DIR]
#   qemu_tree.sh status [--qemu-src DIR]
#   qemu_tree.sh record [--qemu-src DIR] [--kind A|M] <relpath>...
#
# 왜 필요한가
# -----------
# init 이 만든 트리는 패치 없는 기준(pristine) 빌드다. 그런데 펌웨어 하나를 돌리면
# 그 트리에 머신 소스 복사본, Kconfig·meson 항목, 계열별 코어 패치가 쌓인다. 다음
# 펌웨어가 그 위에서 시작하면 앞 펌웨어의 머신이 같은 트리에 등록된 채 남고, 한 계열의
# 코어 패치가 다른 계열의 실행에 남는다. 트리에 더한 것을 **지우려면 무엇을 더했는지
# 알아야** 하므로, 건드린 파일을 $QEMU_SRC/.sboot_touched 에 한 줄씩 적는다.
#
#   M <relpath>   원래 QEMU 에 있던 파일을 고쳤다  -> reset 이 tarball 에서 되돌린다
#   A <relpath>   우리가 새로 더한 파일이다        -> reset 이 지운다
#
# 장부에 없는 파일은 건드리지 않는다. 사용자가 트리에 직접 고친 것까지 지우면 안 된다.
#
# reset
#   - 장부가 없거나 비어 있으면 할 일이 없다 (종료코드 0).
#   - 장부에 항목이 있는데 pristine tarball($QEMU_SRC/../<트리 이름>.tar.xz)이 없으면
#     **아무것도 바꾸지 않고** 실패한다 (종료코드 2). 되돌릴 원본이 없는데 성공으로
#     보고하면 오염된 트리를 깨끗하다고 믿게 된다.
#   - 바꾸기 전에 모든 항목을 검증한다: 경로가 트리 밖을 가리키지 않는지, M 항목이 모두
#     tarball 에 있는지. 하나라도 어긋나면 아무것도 바꾸지 않는다.
#   - 끝나면 장부를 비운다. 멱등: 다시 불러도 아무것도 하지 않는다.
#
# record (sync_machine.sh · patch_qemu_core.py 가 쓴다)
#   - 경로당 한 줄만 적는다. 이미 있으면 아무것도 하지 않는다.
#   - --kind 를 생략하면 tarball 에 그 파일이 있는지로 M/A 를 가른다. tarball 이 없으면
#     가를 수 없으므로 적지 않고 실패한다 (종료코드 3) — 추측해서 M 으로 적으면 reset 이
#     tarball 에 없는 파일을 되돌리려다 멈춘다.
#
# 환경: QEMU_SRC (기본 ~/qemu-build/qemu-10.2.2), QEMU_TARBALL (기본 <부모>/<트리 이름>.tar.xz)
# stdout: JSON 한 개.  종료코드: 0 정상 · 1 사용법 · 2 reset 불가 · 3 record 불가

set -u
command -v python3 >/dev/null 2>&1 || { echo '{"error":"python3 가 없습니다"}'; exit 2; }
exec python3 - "$@" <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile

MANIFEST_NAME = ".sboot_touched"


def out(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def die(code, message, **extra):
    print(message, file=sys.stderr)
    out(dict({"error": message}, **extra), code)


def parse_args(argv):
    if not argv or argv[0] not in ("reset", "status", "record"):
        print("사용법: qemu_tree.sh reset|status|record [--qemu-src DIR] [--kind A|M] <relpath>...",
              file=sys.stderr)
        sys.exit(1)
    cmd, rest = argv[0], argv[1:]
    src = os.environ.get("QEMU_SRC") or os.path.join(os.path.expanduser("~"), "qemu-build", "qemu-10.2.2")
    kind, paths, i = None, [], 0
    while i < len(rest):
        a = rest[i]
        if a == "--qemu-src" and i + 1 < len(rest):
            src, i = rest[i + 1], i + 2
        elif a == "--kind" and i + 1 < len(rest):
            kind, i = rest[i + 1], i + 2
        else:
            paths.append(a)
            i += 1
    if kind not in (None, "A", "M"):
        print("--kind 는 A 또는 M 이어야 합니다", file=sys.stderr)
        sys.exit(1)
    return cmd, os.path.normpath(src), kind, paths


def safe_rel(rel):
    """A manifest path must stay inside the tree - it drives cp and rm."""
    if not rel or "\0" in rel or os.path.isabs(rel):
        return None
    norm = os.path.normpath(rel)
    if norm == "." or norm == ".." or norm.startswith(".." + os.sep):
        return None
    return norm


def read_manifest(path):
    """-> (entries [(kind, rel)], errors). Once per path; first line wins."""
    entries, errors, seen = [], [], set()
    try:
        with open(path) as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return entries, errors
    except OSError as exc:
        return entries, ["장부를 읽지 못했습니다: %s" % exc]
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        m = re.fullmatch(r"([MA]) (\S.*)", line)
        if not m:
            errors.append("장부 %d 행 형식 오류 (\"M <경로>\" 또는 \"A <경로>\"): %r" % (n, line))
            continue
        rel = safe_rel(m.group(2))
        if rel is None:
            errors.append("장부 %d 행 경로가 트리 밖을 가리킵니다: %r" % (n, m.group(2)))
            continue
        if rel in seen:
            continue
        seen.add(rel)
        entries.append((m.group(1), rel))
    return entries, errors


def tar_members(tarball):
    p = subprocess.run(["tar", "-tf", tarball], capture_output=True, text=True)
    if p.returncode != 0:
        return None, (p.stderr or "").strip()
    return set(line.rstrip("/") for line in p.stdout.splitlines()), ""


def main():
    cmd, src, kind, paths = parse_args(sys.argv[1:])
    top = os.path.basename(src)
    manifest = os.path.join(src, MANIFEST_NAME)
    tarball = os.environ.get("QEMU_TARBALL") or os.path.join(os.path.dirname(src), top + ".tar.xz")

    if cmd == "status":
        entries, errors = read_manifest(manifest)
        out({
            "qemu_src": src,
            "tree_present": os.path.isdir(src),
            "manifest": manifest,
            "manifest_exists": os.path.exists(manifest),
            "tarball": tarball,
            "tarball_present": os.path.isfile(tarball),
            "modified": [r for k, r in entries if k == "M"],
            "added": [r for k, r in entries if k == "A"],
            "dirty": bool(entries),
            "errors": errors,
        })

    if cmd == "record":
        if not paths:
            print("record 는 경로가 하나 이상 필요합니다", file=sys.stderr)
            sys.exit(1)
        if not os.path.isdir(src):
            die(3, "QEMU 트리가 없습니다: %s" % src)
        entries, errors = read_manifest(manifest)
        if errors:
            die(3, "장부가 깨져 있어 적지 않습니다: %s" % "; ".join(errors))
        known = set(r for _k, r in entries)
        members, why = None, ""
        recorded, skipped, unclassified = [], [], []
        new_lines = []
        for raw in paths:
            rel = safe_rel(raw)
            if rel is None:
                die(3, "경로가 트리 밖을 가리킵니다: %r" % raw)
            if rel in known:
                skipped.append(rel)
                continue
            k = kind
            if k is None:
                if members is None:
                    if not os.path.isfile(tarball):
                        unclassified.append(rel)
                        continue
                    members, why = tar_members(tarball)
                    if members is None:
                        unclassified.append(rel)
                        continue
                k = "M" if (top + "/" + rel) in members else "A"
            known.add(rel)
            new_lines.append("%s %s\n" % (k, rel))
            recorded.append({"kind": k, "path": rel})
        if new_lines:
            with open(manifest, "a") as fh:
                fh.write("".join(new_lines))
        if unclassified:
            die(3, "tarball 로 M/A 를 가를 수 없어 적지 않았습니다 (%s): %s"
                % (tarball if not os.path.isfile(tarball) else why or "목록을 읽지 못함", ", ".join(unclassified)),
                recorded=recorded, already=skipped, unclassified=unclassified)
        out({"recorded": recorded, "already": skipped})

    # --- reset ---------------------------------------------------------------
    entries, errors = read_manifest(manifest)
    if errors:
        die(2, "장부를 믿을 수 없어 아무것도 바꾸지 않았습니다: %s" % "; ".join(errors))
    if not entries:
        out({"action": "reset", "restored": [], "removed": [], "absent": [], "noop": True})
    if not os.path.isdir(src):
        die(2, "QEMU 트리가 없습니다: %s" % src)
    if not os.path.isfile(tarball):
        die(2, "pristine tarball 이 없어 복원할 수 없습니다: %s — 아무것도 바꾸지 않았습니다. "
               "장부에 %d 건이 남아 있으므로 이 트리는 깨끗하다고 볼 수 없습니다 "
               "(/sboot-rehost:init 으로 재구축하세요)" % (tarball, len(entries)),
            tarball=tarball)

    modified = [r for k, r in entries if k == "M"]
    added = [r for k, r in entries if k == "A"]
    stage = tempfile.mkdtemp(prefix="qemu_tree.")
    try:
        if modified:
            members = [top + "/" + r for r in modified]
            p = subprocess.run(["tar", "-xf", tarball, "-C", stage] + members,
                               capture_output=True, text=True)
            missing = [r for r in modified
                       if not os.path.isfile(os.path.join(stage, top, r))]
            if missing:
                die(2, "장부의 M 항목이 pristine tarball 에 없어 아무것도 바꾸지 않았습니다 "
                       "(원래 QEMU 에 없던 파일을 M 으로 적었을 수 있습니다): %s%s"
                    % (", ".join(missing),
                       "" if p.returncode == 0 else " [tar: %s]" % (p.stderr or "").strip()[:200]),
                    missing=missing)
        restored, removed, absent, failed = [], [], [], []
        for rel in modified:
            dest = os.path.join(src, rel)
            try:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                staged = os.path.join(stage, top, rel)
                # Copy the bytes only: the archive's mtime is older than the build
                # outputs, so a preserved timestamp would make ninja skip the rebuild.
                shutil.copyfile(staged, dest)
                shutil.copymode(staged, dest)
                restored.append(rel)
            except OSError as exc:
                failed.append("%s: %s" % (rel, exc))
        for rel in added:
            dest = os.path.join(src, rel)
            try:
                if os.path.lexists(dest):
                    if os.path.isdir(dest) and not os.path.islink(dest):
                        failed.append("%s: 디렉터리라 지우지 않았습니다 (A 항목은 파일이어야 합니다)" % rel)
                        continue
                    os.remove(dest)
                    removed.append(rel)
                else:
                    absent.append(rel)
            except OSError as exc:
                failed.append("%s: %s" % (rel, exc))
        if failed:
            # Keep the manifest: a rerun repeats what is left, and the entries that
            # already succeeded are harmless to repeat.
            die(2, "일부를 되돌리지 못했습니다 (장부는 그대로 둡니다): %s" % "; ".join(failed),
                restored=restored, removed=removed, absent=absent)
        open(manifest, "w").close()
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    out({"action": "reset", "restored": restored, "removed": removed, "absent": absent, "noop": False})


main()
PY
