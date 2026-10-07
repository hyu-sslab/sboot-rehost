#!/usr/bin/env python3
"""build_lu.py - synthesise the boot medium the bootloader reads from.

The unified flow does not hand the kernel to QEMU. The bootloader loads it the
way it does on the device: it brings the storage controller up, reads a
partition table, finds a partition BY NAME, and pulls the image out of it. That
only works if the medium we model actually has those partitions, under the names
the firmware looks up.

So this writes a real GPT disk - protective MBR, primary and backup headers, a
128-entry array with correct CRC32s - and fills each partition from a file.

★ Partition NAMES are derived, not invented. A name we made up is a partition
  the firmware will never find, and the failure surfaces much later as a
  verification error or a silent fall-through to download mode. Names come from
  <workdir>/lu_manifest.json, which static-analyzer writes from the bootloader's
  own strings. Without a manifest this falls back to documented defaults and
  SAYS SO in the result, the same way the input harness reports a default gate
  pattern rather than pretending it derived one.

Usage:
  build_lu.py <workdir> [--out <img>] [--block-size 4096|512] [--manifest <json>]
                        [--medium emmc|ufs] [--family exynos|mediatek|generic]

--family says whose bootloader this medium is for, and with it which DEFAULTS may apply
(a manifest is never touched by it). The vendor default layout names (keystorage, param,
up_param) and the "param" command-line fallback are Exynos guesses: with --family exynos
they stay, with any other family (mediatek, generic, one not listed) the default layout
carries no vendor names and the command line is written ONLY to the partition the plan or
the manifest names (else warning_cmdline). Without --family the previous behaviour is kept
- Exynos defaults - and the result says so (warning_family): a caller that does not know
the family must not get Exynos guesses silently.

Manifest (angle brackets mark values the agent derives from the firmware):
  {
    "medium": "emmc",                          (optional; ufs when absent - and the
                                                result then carries warning_medium)
    "cmdline_partition": "<name>",             (optional; see "Kernel command line")
    "block_size": 512,                         (optional; 512 for emmc, 4096 for ufs)
    "partitions": [
      {"name": "boot",       "source": "fw/boot.img"},
      {"name": "<name>",     "kind": "zero", "size": <bytes>},
      {"name": "<name>",     "kind": "synthesized", "source": "fw/<built file>",
                             "lba": <block>, "vendor": "<vendor>"},
      {"name": "<name>",     "kind": "forged", "source": "fw/<forged file>"}
    ]
  }

Entry fields:
  kind    where the bytes come from - recorded in lu_provenance.json so the
          verifier can tell firmware bytes from ours. Absent = firmware.
            firmware     bytes taken from the firmware as they are
            zero         zero fill, no source (the bootloader only checks the NAME)
            synthesized  a structure we built (partition table, boot parameters ...)
            forged       a forged structure (e.g. an AVB chain footer)
            modified     firmware bytes we edited (record it in bypasses.md as I)
  size    partition size in bytes. A zero entry needs it (nothing else says how big
          the zero area is; absent = one block, reported). For the others it pads a
          smaller source up to that size; a larger source is an error, because
          firmware bytes are never truncated.
  lba     FIXED start position, in logical blocks OF THIS MEDIUM (512 B for emmc).
          Entries are laid out in manifest order and a fixed one moves the cursor
          there; going backwards (overlap) is an error. Derive the value from the
          bootloader - a made-up position is a partition it never finds.
  vendor  label for a vendor-specific structure. Only recorded; this tool never
          builds vendor structures (partition tables, boot parameters, chain
          partitions) - the agent writes them per firmware and passes them in as
          synthesized/forged.

Kernel command line (<workdir>/cmdline_plan.json, written by static-analyzer):
  The plan's "uart" line is written into ONE partition of the medium, and which one
  is a fact about the bootloader, not a constant of this tool. In order:
    1. plan "partition"          the name of the partition, as in the manifest
                                 (optional "offset": bytes from its start, default 0)
    2. plan "source"             free text; counts only when, minus the word
                                 "partition", it IS a partition name ("PARAM partition")
                                 - any other text means the command line comes from
                                 somewhere that is not a partition: nothing is written
    3. manifest "cmdline_partition"
    4. the plan names nothing    the partition literally called "param" if there is
                                 one (what this tool always did), reported as
                                 warning_cmdline_target: that name is a guess here
  Nothing is written - and warning_cmdline says why - when no partition qualifies.
  The write is recorded in lu_provenance.json "injected" with the basis it used.

To hit a pinned "total_bytes" exactly, end the manifest with a zero entry sized to
the remainder (the backup partition table takes its own blocks at the very end); a
total that differs from the pinned one is only reported.

Prints one JSON object describing what was written. Next to the image it also
writes lu_provenance.json (partition name -> kind, plus where each one sits).
"""
import argparse
import binascii
import hashlib
import json
import os
import re
import struct
import sys

ENTRY_SIZE = 128
ENTRY_COUNT = 128
# "Basic data" - what Android partitions use. The bootloader looks partitions up
# by NAME, not by type GUID, so one generic type is correct here rather than a
# per-partition guess that would be fiction.
TYPE_GUID = b"\xa2\xa0\xd0\xeb\xe5\xb9\x33\x44\x87\xc0\x68\xb6\xb7\x26\x99\xc7"

# Where an entry's bytes come from. Absent in a manifest = firmware, so manifests
# written before this field existed keep working.
KINDS = ("firmware", "zero", "synthesized", "forged", "modified")
# When one name is listed twice, the provenance keeps the kind we trust least: our
# own bytes must never be counted as firmware because of a duplicate.
TRUST_ORDER = ("firmware", "modified", "zero", "synthesized", "forged")

# The medium decides the logical block. eMMC sectors are 512 B; UFS may be either,
# and 4096 is what this tool has always produced.
MEDIA = ("emmc", "ufs")
MEDIUM_BLOCK = {"emmc": 512, "ufs": 4096}

# Used only when no manifest exists. Reported as defaults, never as derived. Entries up to
# "vbmeta" and from "system" on are Android partition names; the three in the middle are
# Samsung/Exynos names (VENDOR_DEFAULT_NAMES) and apply only where the family says so.
DEFAULT_LAYOUT = [
    ("boot", ["fw/boot.img", "02_unpacked/boot.img"]),
    ("recovery", ["fw/recovery.img"]),
    ("dtbo", ["fw/dtbo.img"]),
    ("vbmeta", ["fw/vbmeta.img", "02_unpacked/vbmeta.img"]),
    ("keystorage", ["02_unpacked/keystorage.bin"]),
    ("param", ["02_unpacked/param.bin"]),
    ("up_param", ["02_unpacked/up_param.bin"]),
    ("system", ["fw/system.img"]),
    ("vendor", ["fw/vendor.img"]),
    ("super", ["fw/super.img"]),
]
# Names in the list above that come from a Samsung/Exynos bootloader. They are a
# guess for any other bootloader, so a build without a manifest leaves them out for eMMC
# and for every family but exynos (the result says names were not derived either way).
VENDOR_DEFAULT_NAMES = ("keystorage", "param", "up_param")
# The one family whose default names those are. None (family not given) keeps the
# previous behaviour, which is the same family.
VENDOR_DEFAULT_FAMILY = "exynos"


def vendor_defaults_apply(family):
    """True when the Exynos default names / legacy "param" fallback may be used.

    family None = --family not given: the previous behaviour (they apply). An explicit
    family that is not exynos gets the neutral defaults."""
    return family is None or family == VENDOR_DEFAULT_FAMILY


class LayoutError(Exception):
    """The manifest asks for a layout that cannot be written faithfully."""


def guid_for(name):
    """Deterministic GUID, so two builds of the same medium are byte-identical.

    A random GUID would make every rebuild a different disk, and 'the image
    changed' would become a permanent false lead when a round misbehaves.
    """
    return hashlib.sha256(("sboot-rehost:" + name).encode()).digest()[:16]


def crc32(data):
    return binascii.crc32(data) & 0xFFFFFFFF


def align_up(value, block):
    return (value + block - 1) // block * block


def build_entries(parts, block):
    """Lay partitions out in order and return (entry_array, placed, first_usable, next_lba).

    Back to back, except that an entry with a fixed "lba" moves the cursor there.
    """
    if len(parts) > ENTRY_COUNT:
        raise LayoutError(f"파티션 {len(parts)} 개가 GPT 엔트리 수({ENTRY_COUNT})를 넘습니다")
    entries = bytearray(ENTRY_SIZE * ENTRY_COUNT)
    array_lbas = align_up(ENTRY_SIZE * ENTRY_COUNT, block) // block
    first_usable = 2 + array_lbas
    lba = first_usable
    placed = []
    for i, p in enumerate(parts):
        data = os.path.getsize(p["path"]) if p.get("path") else 0
        declared = p.get("declared_size")
        if p["kind"] != "zero" and declared is not None and declared < data:
            raise LayoutError(
                f'{p["name"]}: size({declared:,}) 가 원본({data:,} B)보다 작습니다 — '
                "펌웨어 바이트는 잘라 쓰지 않습니다")
        if p.get("lba") is not None:
            if p["lba"] < lba:
                raise LayoutError(
                    f'{p["name"]}: 고정 lba {p["lba"]} 가 앞 파티션과 겹칩니다 '
                    f"(여기까지 쓴 위치 {lba}, 첫 사용 가능 {first_usable})")
            lba = p["lba"]
        extent = max(data, declared or 0)
        n = max(1, align_up(extent, block) // block)
        start, end = lba, lba + n - 1
        off = i * ENTRY_SIZE
        entries[off:off + 16] = TYPE_GUID
        entries[off + 16:off + 32] = guid_for(p["name"])
        struct.pack_into("<QQQ", entries, off + 32, start, end, 0)
        nm = p["name"].encode("utf-16-le")[:70]
        entries[off + 56:off + 56 + len(nm)] = nm
        placed.append({**p, "start_lba": start, "end_lba": end,
                       "size": data, "lbas": n})
        lba = end + 1
    return bytes(entries), placed, first_usable, lba


def header(block, current, backup, first_usable, last_usable, entry_lba, entries_crc):
    h = bytearray(92)
    h[0:8] = b"EFI PART"
    struct.pack_into("<III", h, 8, 0x00010000, 92, 0)      # revision, size, crc=0
    struct.pack_into("<I", h, 20, 0)                        # reserved
    struct.pack_into("<QQQQ", h, 24, current, backup, first_usable, last_usable)
    h[56:72] = guid_for("disk")
    struct.pack_into("<QIII", h, 72, entry_lba, ENTRY_COUNT, ENTRY_SIZE, entries_crc)
    struct.pack_into("<I", h, 16, crc32(bytes(h)))          # header CRC last
    return bytes(h)


def protective_mbr(block, total_lbas):
    mbr = bytearray(512)
    mbr[446] = 0x00
    mbr[450] = 0xEE                                          # GPT protective
    struct.pack_into("<I", mbr, 454, 1)
    struct.pack_into("<I", mbr, 458, min(total_lbas - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def load_manifest(workdir, explicit):
    path = explicit or os.path.join(workdir, "lu_manifest.json")
    if not os.path.exists(path):
        return None, path
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh), path
    except (OSError, json.JSONDecodeError) as exc:
        print(f"build_lu: 매니페스트를 읽지 못했습니다 ({exc})", file=sys.stderr)
        return None, path


# Android sparse images (AP tar ships system/vendor/super this way) are a
# container format, not the filesystem. Copying one byte-for-byte onto the medium
# produces a disk the bootloader cannot parse, and the damage only surfaces much
# later as an AVB failure - so refuse to build rather than write it silently.
SPARSE_MAGIC = b"\x3a\xff\x26\xed"


def is_sparse(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(4) == SPARSE_MAGIC
    except OSError:
        return False


def load_cmdline_plan(workdir):
    """(plan, path, problem): cmdline_plan.json as derived by static-analyzer.

    A bootloader that selects `console=ram` sends kernel output to a RAM buffer,
    so a kernel that boots perfectly prints nothing on the serial console. The
    plan's "uart" line is the variant that reaches the UART. WHERE it is written
    is the plan's own statement (see pick_cmdline_target) - not something this
    function assumes. No file is (None, None, None); a file that cannot be used is
    (None, path, <why>) so the caller reports it instead of skipping it silently.
    """
    path = os.path.join(workdir, "cmdline_plan.json")
    if not os.path.isfile(path):
        return None, None, None
    try:
        with open(path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except (OSError, ValueError) as exc:
        return None, path, f"cmdline_plan.json 을 읽지 못했습니다 ({exc})"
    if not isinstance(plan, dict):
        return None, path, "cmdline_plan.json 은 JSON 객체여야 합니다"
    return plan, path, None


def _nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def partition_named_by(text, names):
    """The partition a free-text "source" names, or None.

    Only a whole-text match counts: with the generic word "partition" removed, what
    is left must BE a partition name ("PARAM partition", "partition: param"). A
    looser reading ("boot image header" contains "boot") would write into a
    partition the plan never named - a missed match is only a loud warning, a wrong
    match is a silent overwrite of firmware bytes."""
    words = [w for w in re.split(r"[\s:=,;()\"'`]+", text.lower())
             if w and w not in ("partition", "파티션")]
    wanted = " ".join(words)
    if not wanted:
        return None
    for n in names:
        if n.lower() == wanted:
            return n
    return None


def pick_cmdline_target(plan, manifest, placed, family=None):
    """Where the command line goes: (entry, basis, offset, problem).

    entry is the placed partition (or None with `problem` saying why). `basis` is
    which statement decided it, so the result and lu_provenance.json can show how
    firmware bytes came to be overwritten. `family` only matters when the plan and the
    manifest name nothing: the "param" fallback is an Exynos guess and is taken only
    where vendor_defaults_apply(family)."""
    names = [p["name"] for p in placed]
    by_lower = {}
    for p in placed:
        by_lower.setdefault(p["name"].lower(), p)          # duplicate names: the first

    offset = plan.get("offset", 0)
    if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
        return None, None, 0, f'cmdline_plan.json 의 offset 은 0 이상의 정수여야 합니다 (받은 값: {offset!r})'

    wanted, basis = None, None
    if plan.get("partition") is not None:
        if not _nonempty_str(plan["partition"]):
            return None, None, offset, 'cmdline_plan.json 의 partition 은 비어 있지 않은 문자열이어야 합니다'
        wanted, basis = plan["partition"].strip(), "plan.partition"
    elif _nonempty_str(plan.get("source")):
        named = partition_named_by(plan["source"], names)
        if named is None:
            return None, None, offset, (
                f'cmdline_plan.json 의 source("{plan["source"].strip()}")가 매체의 파티션을 '
                f"가리키지 않습니다(매체 파티션: {names}) — 커맨드라인을 쓰지 않았습니다. "
                "이 부트로더가 파티션에서 읽는다면 plan 에 partition 을 적으십시오; 아니라면 "
                "그 출처가 이 매체로 해결되지 않는다는 뜻입니다")
        wanted, basis = named, "plan.source"
    elif _nonempty_str((manifest or {}).get("cmdline_partition")):
        wanted, basis = manifest["cmdline_partition"].strip(), "manifest.cmdline_partition"
    elif vendor_defaults_apply(family):
        # The plan names nothing. Before this tool read the plan's own statement it
        # always used the partition called "param" (an Exynos name); that stays only so
        # a plan written without the field keeps working, and the caller reports it.
        wanted, basis = "param", "legacy_default"
    else:
        return None, None, offset, (
            f'cmdline_plan.json 이 어느 파티션인지 말하지 않고 매니페스트에도 cmdline_partition 이 '
            f'없습니다(매체 파티션: {names}) — 계열 "{family}" 에는 기본 파티션 이름을 추측하지 '
            "않으므로 커맨드라인을 쓰지 않았습니다. 부트로더가 커맨드라인을 읽는 파티션을 plan 의 "
            "partition 으로 적으십시오")

    entry = by_lower.get(wanted.lower())
    if entry is None:
        where = {"plan.partition": "plan 이 partition 으로 적은",
                 "plan.source": "plan 의 source 가 가리키는",
                 "manifest.cmdline_partition": "매니페스트 cmdline_partition 이 적은",
                 "legacy_default": "plan 이 파티션을 말하지 않아 기본으로 찾은"}[basis]
        return None, basis, offset, (
            f'{where} 파티션 "{wanted}" 이 매체에 없습니다(매체 파티션: {names}) — '
            "커맨드라인을 쓰지 못했습니다")
    return entry, basis, offset, None


def entry_errors(p):
    """Why one manifest entry cannot be used, as a list of messages."""
    name = p.get("name")
    label = name if isinstance(name, str) and name else "(이름 없음)"
    errs = []
    if not isinstance(name, str) or not name:
        errs.append("name 이 비었거나 문자열이 아닙니다")
    kind = p.get("kind", "firmware")
    if kind not in KINDS:
        errs.append(f'kind "{kind}" 는 {"|".join(KINDS)} 중 하나여야 합니다')
    for key, floor in (("lba", 0), ("size", 1)):
        v = p.get(key)
        if v is not None and (isinstance(v, bool) or not isinstance(v, int) or v < floor):
            errs.append(f"{key} 는 {floor} 이상의 정수여야 합니다 (받은 값: {v!r})")
    if p.get("vendor") is not None and not isinstance(p.get("vendor"), str):
        errs.append("vendor 는 문자열이어야 합니다")
    if kind == "zero" and p.get("source"):
        errs.append("kind=zero 는 source 를 가질 수 없습니다 — 원본이 있으면 firmware 입니다")
    return [f"{label}: {e}" for e in errs]


def resolve(workdir, manifest, medium="ufs", family=None):
    """Return (partitions, derived, missing, sparse, errors).

    Missing sources are skipped loudly; sparse ones stop the build outright; an
    entry that is malformed is an error, not something to guess around. `family`
    matters only for the default layout (no manifest): see vendor_defaults_apply."""
    parts, missing, sparse, errors = [], [], [], []
    if manifest:
        for p in manifest.get("partitions") or []:
            bad = entry_errors(p)
            if bad:
                errors.extend(bad)
                continue
            kind = p.get("kind", "firmware")
            entry = {"name": p["name"], "path": None, "source": p.get("source"),
                     "kind": kind, "lba": p.get("lba"), "vendor": p.get("vendor"),
                     "declared_size": p.get("size")}
            if kind == "zero":
                parts.append(entry)
                continue
            src = os.path.join(workdir, p.get("source", ""))
            if os.path.isfile(src):
                if is_sparse(src):
                    sparse.append(f'{p.get("name")} <- {p.get("source")}')
                    continue
                entry["path"] = src
                parts.append(entry)
            else:
                missing.append(f'{p.get("name")} <- {p.get("source")}')
        return parts, True, missing, sparse, errors

    for name, candidates in DEFAULT_LAYOUT:
        if name in VENDOR_DEFAULT_NAMES and (
                medium == "emmc" or not vendor_defaults_apply(family)):
            continue
        for rel in candidates:
            src = os.path.join(workdir, rel)
            if os.path.isfile(src):
                if is_sparse(src):
                    sparse.append(f"{name} <- {rel}")
                    break
                parts.append({"name": name, "path": src, "source": rel,
                              "kind": "firmware", "lba": None, "vendor": None,
                              "declared_size": None})
                break
    return parts, False, missing, sparse, errors


MEDIUM_DECIDER = ("종류는 첫 부트로더 로그가 정합니다 — scripts/detect_medium.py 에 "
                  "--bootloader-log <콘솔 로그> 를 주어 판정하고, 그 결과를 매니페스트 medium "
                  "이나 --medium 에 적어 다시 만드십시오")


def pick_medium(cli, manifest):
    """(medium, where it came from, problem). CLI beats the manifest beats the default.

    The default (ufs, 4096 B) is only a placeholder for "not decided yet", so the
    third value is set whenever the default was taken - an absent `medium` key is
    the path the guide prescribes while the kind is undecided, and it must say so
    exactly as an explicit "unknown" does."""
    if cli:
        return cli, "cli", None
    declared = (manifest or {}).get("medium")
    if declared in MEDIA:
        return declared, "manifest", None
    if declared in (None, "unknown"):
        # "unknown" is what detect_medium.py prints when nothing decided, and an absent
        # key means the same thing; neither may turn into a silent guess about the
        # block size, so the result flags it.
        what = ('매니페스트 medium 이 "unknown" 입니다' if declared
                else "매니페스트에 medium 이 없습니다")
        note = (f"{what} — 정하지 못한 채 계열과 무관한 기본값 ufs(4096 B)로 만들었습니다 "
                f"(이전 호환 값이며 이 펌웨어에서 도출한 것이 아닙니다). {MEDIUM_DECIDER}")
        return "ufs", "default", note
    return None, "manifest", f'매니페스트 medium "{declared}" 는 {"|".join(MEDIA)} 중 하나여야 합니다'


def write_provenance(out, block, medium, total_bytes, placed, injected):
    """lu_provenance.json beside the image: partition name -> kind, and where each sits.

    The verifier reads it to tell firmware bytes from bytes we made. Written after
    the image, so a provenance file never describes an image that was not built."""
    kinds = {}
    for p in placed:
        prev = kinds.get(p["name"])
        if prev is None or TRUST_ORDER.index(p["kind"]) > TRUST_ORDER.index(prev):
            kinds[p["name"]] = p["kind"]
    details = []
    for p in placed:
        d = {"name": p["name"], "kind": p["kind"]}
        if p.get("vendor"):
            d["vendor"] = p["vendor"]
        if p.get("source"):
            d["source"] = p["source"]
        d.update({"start_lba": p["start_lba"], "end_lba": p["end_lba"],
                  "offset": p["start_lba"] * block, "lbas": p["lbas"],
                  "bytes": p["size"], "fixed_lba": p.get("lba") is not None})
        details.append(d)
    doc = {
        "version": 1,
        "image": os.path.basename(out),
        "medium": medium,
        "block_size": block,
        "total_bytes": total_bytes,
        "partitions": kinds,
        "counts": {k: sum(1 for p in placed if p["kind"] == k) for k in KINDS},
        "details": details,
        "injected": injected,
    }
    path = os.path.join(os.path.dirname(os.path.abspath(out)), "lu_provenance.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    return path


def fail(reason, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra},
                     ensure_ascii=False, indent=2))
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workdir")
    ap.add_argument("--out", default=None)
    ap.add_argument("--block-size", type=int, default=None, choices=(512, 4096))
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--medium", default=None, choices=MEDIA,
                    help="emmc = 512 B logical blocks; ufs (default) = 4096 B; "
                         "taking the default is reported as warning_medium")
    ap.add_argument("--family", default=None,
                    help="exynos | mediatek | generic (any other name is treated like generic): "
                         "the vendor default names and the \"param\" command-line fallback "
                         "apply only to exynos; omitted = previous behaviour, reported as "
                         "warning_family")
    args = ap.parse_args()
    family = args.family.strip().lower() if args.family is not None else None
    if args.family is not None and not family:
        return fail("--family 에는 계열 이름이 필요합니다 (exynos|mediatek|generic ...)")

    wd = args.workdir
    manifest, manifest_path = load_manifest(wd, args.manifest)
    medium, medium_src, medium_note = pick_medium(args.medium, manifest)
    if medium is None:
        return fail(medium_note, manifest=manifest_path)
    block = args.block_size or (manifest or {}).get("block_size") or MEDIUM_BLOCK[medium]
    if medium == "emmc" and block != MEDIUM_BLOCK["emmc"]:
        return fail(f"eMMC 의 논리 블록은 {MEDIUM_BLOCK['emmc']} B 입니다 (받은 값: {block})",
                    hint="--block-size / 매니페스트 block_size 를 빼거나 medium 을 바로잡으십시오.")
    out = args.out or os.path.join(wd, "fw", "lu0.img")

    parts, derived, missing, sparse, errors = resolve(wd, manifest, medium, family)
    if errors:
        return fail("매니페스트 항목이 올바르지 않습니다", errors=errors, manifest=manifest_path)
    if sparse:
        print(json.dumps({
            "ok": False,
            "reason": "sparse 이미지를 raw 로 풀지 않았습니다",
            "sparse": sparse,
            "hint": ("simg2img <in> <out> 으로 먼저 푸십시오. sparse 를 그대로 쓰면 "
                     "부트로더가 파티션을 파싱하지 못하고, 그 결함은 한참 뒤 AVB 실패로 "
                     "나타나 원인을 찾기 어렵습니다."),
        }, ensure_ascii=False, indent=2))
        return 1
    if not parts:
        print(json.dumps({
            "ok": False,
            "reason": "채울 파티션이 하나도 없습니다",
            "manifest": manifest_path,
            "hint": ("펌웨어 자산을 먼저 배치하거나, static-analyzer 가 도출한 파티션 이름으로 "
                     "lu_manifest.json 을 쓰십시오. 이름을 지어내면 펌웨어가 못 찾습니다."),
        }, ensure_ascii=False, indent=2))
        return 1

    try:
        entries, placed, first_usable, next_lba = build_entries(parts, block)
    except LayoutError as exc:
        return fail("파티션을 배치하지 못했습니다", detail=str(exc), block_size=block)
    array_lbas = align_up(ENTRY_SIZE * ENTRY_COUNT, block) // block
    last_usable = next_lba - 1
    total_lbas = next_lba + array_lbas + 1          # backup array + backup header

    # Where the command line goes is the plan's statement (or the manifest's), not a
    # partition name this tool knows: see pick_cmdline_target.
    plan, cmdline_src, plan_problem = load_cmdline_plan(wd)
    cmdline = plan.get("uart") if plan else None
    cmdline_problem = plan_problem
    target, target_basis, target_offset = None, None, 0
    if plan is not None and not _nonempty_str(cmdline):
        cmdline = None
        cmdline_problem = ("cmdline_plan.json 에 기록할 uart 줄이 없어 아무것도 쓰지 않았습니다 "
                           "(부트로더 기본값이 이미 UART 로 가는지는 STATIC.md 의 도출을 보십시오)")
    elif cmdline:
        target, target_basis, target_offset, cmdline_problem = pick_cmdline_target(
            plan, manifest, placed, family)
        if target is not None and (
                target_offset + len(cmdline.encode()) + 1 > target["lbas"] * block):
            cmdline_problem = (
                f'파티션 "{target["name"]}" 은 offset {target_offset} 에 커맨드라인 '
                f"{len(cmdline.encode()) + 1} B 를 둘 만큼 크지 않습니다({target['lbas'] * block} B)")
            target = None
        if target is None:
            cmdline = None

    # The bootloader rewrites the GPT and treats the device as newly provisioned
    # when the medium's total size changes - measured on Exynos 2400, where
    # adding 30 MiB was enough to trigger a full re-init and a power-down. Pin
    # the size in the manifest so swapping a partition cannot change it.
    pinned = (manifest or {}).get("total_bytes")

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    ecrc = crc32(entries)
    with open(out, "wb") as fh:
        fh.truncate(total_lbas * block)
        fh.seek(0)
        mbr = protective_mbr(block, total_lbas)
        fh.write(mbr + bytes(block - len(mbr)) if block > 512 else mbr)

        fh.seek(1 * block)
        fh.write(header(block, 1, total_lbas - 1, first_usable, last_usable,
                        2, ecrc))
        fh.seek(2 * block)
        fh.write(entries)

        for p in placed:
            if not p["path"]:
                continue                     # zero fill: the truncated file already is
            fh.seek(p["start_lba"] * block)
            with open(p["path"], "rb") as src:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    fh.write(chunk)

        # The UART command line, written into the partition the plan names so the
        # kernel prints where we can see it. Written after the partition images, at
        # the plan's offset (default: the partition start) - it REPLACES those bytes of
        # a partition the firmware supplied, which is why the write is recorded below
        # with the statement that chose the partition.
        if cmdline and target is not None:
            payload = cmdline.encode() + b"\x00"
            fh.seek(target["start_lba"] * block + target_offset)
            fh.write(payload)

        backup_array_lba = total_lbas - 1 - array_lbas
        fh.seek(backup_array_lba * block)
        fh.write(entries)
        fh.seek((total_lbas - 1) * block)
        fh.write(header(block, total_lbas - 1, 1, first_usable, last_usable,
                        backup_array_lba, ecrc))

    injected = []
    if cmdline and target is not None:
        injected.append({"partition": target["name"], "what": "cmdline",
                         "offset": target["start_lba"] * block + target_offset,
                         "bytes": len(cmdline.encode()) + 1,
                         "source": os.path.basename(cmdline_src),
                         "basis": target_basis})
    try:
        prov_path = write_provenance(out, block, medium, total_lbas * block,
                                     placed, injected)
    except OSError as exc:
        # Without it the verifier would fall back to treating the whole image as
        # firmware, which is the looser reading - so this is a failure, not a warning.
        return fail("출처 기록(lu_provenance.json)을 쓰지 못했습니다", detail=str(exc))

    actual = os.path.getsize(out)
    size_warning = None
    if pinned and actual != pinned:
        size_warning = (f"매체 총 크기가 고정값과 다릅니다: {actual:,} != {pinned:,} — "
                        "부트로더가 GPT 를 재작성하고 신규 프로비저닝으로 간주해 "
                        "전원을 내릴 수 있습니다 (파티션을 바꿔도 총량은 유지하십시오)")

    result = {
        "ok": True,
        "image": os.path.abspath(out),
        "block_size": block,
        "total_bytes": total_lbas * block,
        "names_derived": derived,
        "manifest": manifest_path if derived else None,
        "partitions": [{"name": p["name"], "source": p["source"],
                        "start_lba": p["start_lba"], "lbas": p["lbas"],
                        "bytes": p["size"], "kind": p["kind"],
                        **({"vendor": p["vendor"]} if p.get("vendor") else {}),
                        **({"fixed_lba": True} if p.get("lba") is not None else {})}
                       for p in placed],
        "medium": medium,
        "medium_source": medium_src,
        "provenance": prov_path,
        "missing_sources": missing,
        "cmdline_written": bool(cmdline),
        "cmdline": cmdline,
        "cmdline_source": cmdline_src if cmdline else None,
        "cmdline_target": ({"partition": target["name"], "offset": target_offset,
                            "basis": target_basis}
                           if cmdline and target is not None else None),
    }
    if size_warning:
        result["warning_size"] = size_warning
    if cmdline is None and cmdline_src:
        result["warning_cmdline"] = (
            f"{cmdline_problem or '커맨드라인을 쓰지 않았습니다'}; 부트로더가 console=ram 을 "
            "고르면 커널이 떠도 시리얼에 아무것도 안 나옵니다")
    if cmdline and target_basis == "legacy_default":
        result["warning_cmdline_target"] = (
            'cmdline_plan.json 이 어느 파티션인지 말하지 않아 이름이 "param" 인 파티션에 '
            "썼습니다 — 그 이름은 이 부트로더에서 도출한 것이 아닙니다. 부트로더가 "
            "커맨드라인을 읽는 곳을 plan 의 partition 으로 적으면 이 경고가 사라집니다")
    if not derived:
        result["warning"] = (
            "파티션 이름을 도출하지 않고 **문서화된 기본값**을 썼습니다. 펌웨어가 다른 "
            "이름으로 찾으면 그 파티션은 없는 것과 같습니다 — static-analyzer 가 "
            "부트로더 문자열에서 이름을 도출해 lu_manifest.json 을 쓰게 하십시오.")
        if medium == "emmc":
            result["warning"] += (f" (eMMC: Exynos 기본 이름 {list(VENDOR_DEFAULT_NAMES)} 은 "
                                  "추측이라 뺐습니다)")
        elif not vendor_defaults_apply(family):
            result["warning"] += (f' (계열 "{family}": Exynos 기본 이름 {list(VENDOR_DEFAULT_NAMES)} 은 '
                                  "다른 계열에는 추측이라 뺐습니다)")
    if medium_note:
        result["warning_medium"] = medium_note
    if family is None:
        result["warning_family"] = "family not given; Exynos defaults applied"
    dup = sorted({p["name"] for p in placed if sum(q["name"] == p["name"] for q in placed) > 1})
    if dup:
        result["warning_duplicate_names"] = (
            f"같은 이름이 여러 번 있습니다: {dup} — 부트로더는 이름으로 찾으므로 어느 쪽이 "
            "선택될지 불확실하고, 출처 기록에는 가장 덜 믿는 종류를 남겼습니다")
    unsized = [p["name"] for p in placed if p["kind"] == "zero" and p.get("declared_size") is None]
    if unsized:
        result["warning_zero_size"] = (
            f"size 가 없는 zero 항목은 1 블록으로 만들었습니다: {unsized} — 크기를 "
            "도출했다면 매니페스트에 적으십시오")
    if missing:
        result["warning_missing"] = (
            f"매니페스트가 지정한 원본 {len(missing)} 개가 없어 건너뛰었습니다: {missing}")

    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
