#!/usr/bin/env python3
"""make_negative_image.py - a copy of the boot medium with ONE byte flipped.

The two-way verification asks: does the firmware's verified boot actually say "no"?
A verifier that is stubbed to say "equal" to everything also prints "succeeded"
on an intact image, so a pass proves nothing by itself. Run the same boot on a
medium with one byte damaged inside a named partition (default: the vbmeta that
holds the signed digests): a real verifier fails or refuses, a stubbed one boots
on. verify.py reads that second console through --negative-console.

  - the ORIGINAL image is never opened for writing; the copy is
  - the partition is located from the medium's own GPT (the partition table the
    firmware reads), falling back to lu_manifest.json entries that carry an `lba`
  - the byte is inside the partition's non-zero extent, near its middle, so the
    damage lands in data the verifier reads rather than in padding; --offset
    chooses another byte (relative to the partition start)
  - one bit is flipped (xor 0x01): the smallest corruption that is still a change

Usage:
  make_negative_image.py <workdir> [--image fw/lu0.img] [--partition vbmeta]
                         [--out fw/lu0_negative.img] [--offset N] [--manifest F]

Prints one JSON object. Exit 0 when the copy was made, 1 otherwise.
"""
import argparse
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_gates as vg  # noqa: E402

SCAN_CAP = 64 * 1024 * 1024         # how much of a partition is read to find its data
FLIP = 0x01


def fail(reason, **extra):
    print(json.dumps(dict({"ok": False, "reason": reason}, **extra), ensure_ascii=False, indent=2))
    return 1


def pick_partition(names, wanted):
    """The partition to damage: the one asked for, else the vbmeta family's head."""
    if wanted:
        for n in names:
            if n.lower() == wanted.lower():
                return n
        return None
    fam = sorted((n for n in names if n.lower().startswith("vbmeta")), key=lambda n: (len(n), n))
    return fam[0] if fam else None


def manifest_partitions(workdir, manifest_path):
    """name -> {start, size, block_size} from manifest entries that carry an lba."""
    path = manifest_path or os.path.join(workdir, "lu_manifest.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    block = int(data.get("block_size") or 4096)
    out = {}
    for p in data.get("partitions") or []:
        if not isinstance(p, dict) or p.get("lba") is None or not p.get("name"):
            continue
        size = None
        src = os.path.join(workdir, p.get("source") or "")
        if p.get("source") and os.path.isfile(src):
            size = os.path.getsize(src)
        if size:
            out[p["name"]] = {"start": int(p["lba"]) * block, "size": size, "block_size": block}
    return out


def data_extent(fh, part):
    """(first, last, buffer): offsets of the first and last non-zero byte of the
    partition (looked up with C-speed strips; a 64 MiB partition of zeros is not
    walked byte by byte), or None when it is all zeros."""
    n = min(part["size"], SCAN_CAP)
    fh.seek(part["start"])
    buf = fh.read(n)
    stripped = buf.lstrip(b"\0")
    if not stripped:
        return None
    first = len(buf) - len(stripped)
    last = len(buf.rstrip(b"\0")) - 1
    return first, last, buf


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workdir")
    ap.add_argument("--image", default=None, help="the medium image (default: fw/lu0.img)")
    ap.add_argument("--partition", default=None,
                    help="partition to damage (default: the vbmeta partition)")
    ap.add_argument("--out", default=None, help="the damaged copy (default: <image>_negative)")
    ap.add_argument("--offset", type=lambda v: int(v, 0), default=None,
                    help="byte offset inside the partition (default: middle of its data)")
    ap.add_argument("--manifest", default=None)
    args = ap.parse_args(argv)

    image = args.image or os.path.join(args.workdir, "fw", "lu0.img")
    if not os.path.isfile(image):
        return fail("매체 이미지가 없습니다: %s" % image)
    stem, ext = os.path.splitext(image)
    out = args.out or (stem + "_negative" + ext)
    if os.path.exists(out) and os.path.samefile(out, image):
        return fail("출력이 원본과 같은 파일입니다 — 원본은 절대 수정하지 않습니다")
    if os.path.realpath(out) == os.path.realpath(image):
        return fail("출력이 원본과 같은 경로입니다 — 원본은 절대 수정하지 않습니다")

    parts = vg.gpt_partitions(image)
    source = "GPT"
    if not parts:
        parts = manifest_partitions(args.workdir, args.manifest)
        source = "lu_manifest.json (lba)"
    if not parts:
        return fail("파티션 위치를 알 수 없습니다 — 이미지에 GPT 가 없고 매니페스트에도 lba 가 "
                    "없습니다", image=image)
    name = pick_partition(list(parts), args.partition)
    if name is None:
        return fail("대상 파티션을 찾지 못했습니다 (%s)" % (args.partition or "vbmeta*"),
                    partitions=sorted(parts))
    part = parts[name]

    before = os.stat(image)
    with open(image, "rb") as fh:                     # read-only: the original stays as it is
        if args.offset is not None:
            if not 0 <= args.offset < part["size"]:
                return fail("--offset 이 파티션 밖입니다 (파티션 크기 %d)" % part["size"])
            rel = args.offset
            fh.seek(part["start"] + rel)
            orig = fh.read(1)
        else:
            ext_ = data_extent(fh, part)
            if ext_ is None:
                return fail("파티션 '%s' 이 전부 0 입니다 — 훼손해도 검증이 읽을 데이터가 없습니다" % name)
            first, last, buf = ext_
            mid = (first + last) // 2
            rel = next((i for i in range(mid, last + 1) if buf[i]), first)
            orig = buf[rel:rel + 1]
    if not orig:
        return fail("이미지가 파티션 끝보다 짧습니다")
    new = bytes([orig[0] ^ FLIP])

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    shutil.copyfile(image, out)
    with open(out, "r+b") as fh:
        fh.seek(part["start"] + rel)
        fh.write(new)
        fh.flush()
        os.fsync(fh.fileno())
    after = os.stat(image)

    kinds = vg.load_medium_kinds(args.workdir)
    print(json.dumps({
        "ok": True,
        "original": os.path.abspath(image),
        "image": os.path.abspath(out),
        "partition": name,
        "partition_kind": (kinds.get(name) or {}).get("kind"),
        "located_by": source,
        "block_size": part.get("block_size"),
        "partition_start": part["start"],
        "partition_size": part["size"],
        "offset_in_partition": rel,
        "offset_abs": part["start"] + rel,
        "original_byte": "0x%02x" % orig[0],
        "new_byte": "0x%02x" % new[0],
        "original_unchanged": (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns),
        "note": "이 이미지로 회차를 한 번 더 돌려 그 콘솔을 verify.py --negative-console 로 넘기십시오. "
                "훼손했는데도 새 실패 줄이 없으면 그 검증은 우회되어 있는 것입니다.",
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
