#!/usr/bin/env python3
"""detect_medium.py - decide whether the boot medium is eMMC or UFS, from evidence.

The profile used to say `hci_kind: ufs` for every MediaTek device. That is a guess,
and a wrong one for an eMMC phone: the SoC's device tree carries a UFS host node
whether or not the board uses it (the kernel then logs a NULL UFS host), so a UFS
model gets built for storage nobody reads. The medium is a derived fact. This
reads the evidence and prints what it supports - or `unknown` when nothing decides.

Priority, highest first:
  1. bootloader console: a line announcing that ONE kind of storage was
     initialized (init lines first, then lines naming the boot device)
  2. device tree: an mmc-class node that really is an eMMC (8-bit bus, or marked
     non-removable / no-sd) and is not disabled; or a UFS node explicitly enabled
  The mere presence of a UFS node decides nothing, and an mmc node that could just
  as well be an SD slot (narrow bus, no eMMC marker) decides nothing either.

Evidence that must never count:
  - QEMU host diagnostic lines (`qemu-system-*:` prefix): we printed them, not the guest
  - lines that name several kinds at once ("NAND/EMMC/UFS init ...")
  - failed / skipped / absent storage lines
  - two kinds both reported initialized: that is a conflict, reported as unknown

The keywords are generic (init, mmc, ufs, bus-width ...). No device strings.

Usage:
  detect_medium.py [--bootloader-log <file> ...] [--dtb <file> ...] [--builtin-dtb]

  --dtb takes a flattened device tree, a source (.dts) file, or any container that
  embeds one (a bootloader image carries its DTB); embedded trees are found by
  their magic. dtc or fdtdump decodes them when installed (the same tools
  check_env.sh looks for); otherwise a built-in reader is used, so a missing tool
  costs nothing. --builtin-dtb skips the tools.

Prints one JSON object: hci_kind (emmc|ufs|unknown), basis, confidence, reason,
evidence (one string per line that counted or was weighed), details, notes.
Exit code is 0 whenever the input was usable - `unknown` is a result, not an error.
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

MAX_EVIDENCE = 80          # printed evidence lines; the rest is only counted
MAX_BLOBS = 4              # device trees read from one container
LINE_CLIP = 160

# --- bootloader log ----------------------------------------------------------
# QEMU host diagnostics, possibly behind an epoch timestamp. The machine printed
# them; they are never guest evidence.
HOST_LINE = re.compile(r"^\s*(?:\d+(?:\.\d+)?\s+)?qemu-system-\S*:")

# Storage kinds. "mmc"/"emmc"/"msdc" end at a word edge so that identifiers such as
# `mmc_rpmb_read_data` or `log_to_emmc` are not read as a storage announcement.
EMMC_WORD = re.compile(r"\b(?:e?mmc|msdc)\d*\b", re.I)
UFS_WORD = re.compile(r"\bufs(?:hci|hcd)?\b", re.I)

# "storage was brought up". `init` + optional suffix, so `initrd` does not count.
INIT_WORD = re.compile(r"\binit(?:i[a-z]+)?\b|\blink\s*startup\b", re.I)
# Android's init process prefixes its own log lines with `init:`; that is the process
# name, not an announcement that storage was initialized.
INIT_PROCESS = re.compile(r"\binit:", re.I)
# A line that names the boot device the bootloader will hand to the kernel.
BOOTDEV_WORD = re.compile(r"\bboot_?devices?\b|\bbootdevice\b", re.I)
# A failed / skipped / absent line is not an initialization.
NEGATIVE_WORD = re.compile(
    r"\b(?:fail(?:ed|ure|s)?|error|not\s+found|time[ds]?\s*out|timeout|unable|cannot|"
    r"can't|no\s+device|absent|missing|skip(?:ped)?|disabled|unsupported|not\s+supported)\b",
    re.I)


def classify_line(line):
    """(vote, kind_of_line, why) for a guest line that talks about storage, else None.

    vote is emmc | ufs | none; none means the line was weighed and did not count."""
    emmc, ufs = bool(EMMC_WORD.search(line)), bool(UFS_WORD.search(line))
    if not (emmc or ufs):
        return None
    init = bool(INIT_WORD.search(INIT_PROCESS.sub(" ", line)))
    bootdev = bool(BOOTDEV_WORD.search(line))
    if not (init or bootdev):
        return None
    kind_of_line = "init" if init else "boot_device"
    if emmc and ufs:
        return "none", kind_of_line, "한 줄에 eMMC 와 UFS 가 함께 있어 어느 쪽인지 정하지 못함"
    if NEGATIVE_WORD.search(line):
        return "none", kind_of_line, "실패·건너뜀·미검출 줄이라 초기화로 세지 않음"
    vote = "emmc" if emmc else "ufs"
    return vote, kind_of_line, ("초기화 줄" if init else "부트 디바이스 줄")


def clip(line):
    """The line, shortened around the storage word so the reason it matched stays visible."""
    line = line.strip()
    if len(line) <= LINE_CLIP:
        return line
    m = EMMC_WORD.search(line) or UFS_WORD.search(line)
    start = max(0, (m.start() if m else 0) - LINE_CLIP // 3)
    return ("..." if start else "") + line[start:start + LINE_CLIP] + "..."


def scan_log(path, evidence, notes):
    """Weigh every guest line of one log; append what was weighed to `evidence`."""
    if not os.path.isfile(path):
        notes.append(f"부트로더 로그를 찾지 못했습니다: {path}")
        return
    host = 0
    try:
        # Lines are counted by "\n" only, so a number here matches `grep -n`; a UART
        # log also uses lone "\r", which splits a line into separate segments below.
        with open(path, encoding="utf-8", errors="replace", newline="\n") as fh:
            for no, raw in enumerate(fh, 1):
                for line in raw.rstrip("\n").split("\r"):
                    if HOST_LINE.match(line):
                        host += 1
                        continue
                    hit = classify_line(line)
                    if not hit:
                        continue
                    vote, kind_of_line, why = hit
                    evidence.append({"tier": "bootloader_log", "source": os.path.basename(path),
                                     "where": f"line {no}", "text": clip(line),
                                     "vote": vote, "line_kind": kind_of_line, "why": why})
    except OSError as exc:
        notes.append(f"부트로더 로그를 읽지 못했습니다: {path} ({exc})")
        return
    if host:
        notes.append(f"{os.path.basename(path)}: QEMU 호스트 진단 {host} 줄은 증거에서 제외했습니다")


# --- device tree -------------------------------------------------------------
FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def fdt_header(data, off):
    """Parsed header fields if a sane flattened device tree starts at `off`, else None."""
    if len(data) - off < 40:
        return None
    (magic, total, off_struct, off_strings, _rsv, version, last_comp,
     _cpu, size_strings, size_struct) = struct.unpack_from(">10I", data, off)
    if magic != FDT_MAGIC or total < 40 or off + total > len(data):
        return None
    if not (1 <= version <= 17) or last_comp > version:
        return None
    if off_struct + size_struct > total or off_strings + size_strings > total:
        return None
    if off_struct + 4 > total or struct.unpack_from(">I", data, off + off_struct)[0] != FDT_BEGIN_NODE:
        return None
    return {"total": total, "version": version}


def find_fdt_blobs(data):
    """Every flattened device tree in `data` (a whole file or a container), up to MAX_BLOBS."""
    magic = struct.pack(">I", FDT_MAGIC)
    blobs, pos = [], data.find(magic)
    while pos != -1 and len(blobs) < MAX_BLOBS:
        hdr = fdt_header(data, pos)
        if hdr:
            blobs.append((pos, data[pos:pos + hdr["total"]]))
            pos = data.find(magic, pos + hdr["total"])
        else:
            pos = data.find(magic, pos + 1)
    return blobs


_PRINTABLE = set(range(0x20, 0x7F))


def decode_prop(data):
    """A device tree property value as: True (empty), [str], [int], or None (opaque)."""
    if not data:
        return True
    if data[-1] == 0:
        parts = data[:-1].split(b"\0")
        if all(parts) and all(b in _PRINTABLE for p in parts for b in p):
            return [p.decode("ascii") for p in parts]
    if len(data) % 4 == 0:
        return list(struct.unpack(">%dI" % (len(data) // 4), data))
    return None


def walk_fdt(blob):
    """Built-in reader: [{path, name, props}] for one flattened device tree."""
    (_m, _t, off_struct, off_strings, _r, _v, _l, _c,
     size_strings, size_struct) = struct.unpack_from(">10I", blob, 0)
    strings = blob[off_strings:off_strings + size_strings]
    pos, end = off_struct, off_struct + size_struct
    nodes, stack = [], []
    while pos + 4 <= end:
        token = struct.unpack_from(">I", blob, pos)[0]
        pos += 4
        if token == FDT_BEGIN_NODE:
            nul = blob.index(b"\0", pos)
            name = blob[pos:nul].decode("utf-8", "replace")
            pos = (nul + 1 + 3) & ~3
            path = (stack[-1]["path"].rstrip("/") + "/" + name) if stack else "/"
            node = {"path": path, "name": name or "/", "props": {}}
            nodes.append(node)
            stack.append(node)
        elif token == FDT_END_NODE:
            if stack:
                stack.pop()
        elif token == FDT_PROP:
            length, nameoff = struct.unpack_from(">II", blob, pos)
            pos += 8
            value = blob[pos:pos + length]
            pos = (pos + length + 3) & ~3
            name = strings[nameoff:strings.index(b"\0", nameoff)].decode("utf-8", "replace")
            if stack:
                stack[-1]["props"][name] = decode_prop(value)
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            raise ValueError(f"알 수 없는 FDT 토큰 {token:#x}")
    return nodes


_COMMENT_OR_STRING = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)


def parse_prop_text(raw):
    """Value text after `=` in dts source: [str], [int], or None for bytes / references."""
    if raw is None:
        return True
    strs = re.findall(r'"((?:\\.|[^"\\])*)"', raw)
    if strs:
        return strs
    cells = re.findall(r"<([^>]*)>", raw)
    if cells:
        out = []
        for tok in " ".join(cells).split():
            try:
                out.append(int(tok, 0))
            except ValueError:
                pass                           # &label, expressions: not needed here
        return out
    return None


def parse_dts(text):
    """[{path, name, props}] from dts source text (dtc / fdtdump output, or a .dts file)."""
    text = _COMMENT_OR_STRING.sub(lambda m: m.group(0) if m.group(0).startswith('"') else " ", text)
    nodes, stack, buf = [], [], []
    in_str = False
    prev = ""
    for ch in text:
        if in_str:
            buf.append(ch)
            if ch == '"' and prev != "\\":
                in_str = False
        elif ch == '"':
            in_str = True
            buf.append(ch)
        elif ch == "{":
            head = "".join(buf).strip()
            buf = []
            name = head.split(":")[-1].strip() or "/"       # "label: name@addr"
            path = (stack[-1]["path"].rstrip("/") + "/" + name) if stack else "/"
            node = {"path": path, "name": name, "props": {}}
            nodes.append(node)
            stack.append(node)
        elif ch == "}":
            buf = []
            if stack:
                stack.pop()
        elif ch == ";":
            stmt = "".join(buf).strip()
            buf = []
            if stmt and stack:
                key, eq, value = stmt.partition("=")
                stack[-1]["props"][key.strip()] = parse_prop_text(value if eq else None)
        else:
            buf.append(ch)
        prev = ch
    return nodes


def decode_blob(blob, use_tools, notes, label):
    """Nodes of one flattened tree: dtc, then fdtdump, then the built-in reader."""
    if use_tools:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "x.dtb")
            with open(path, "wb") as fh:
                fh.write(blob)
            for tool, cmd in (("dtc", ["dtc", "-I", "dtb", "-O", "dts", "-q", "-o", "-", path]),
                              ("fdtdump", ["fdtdump", path])):
                if not shutil.which(tool):
                    continue
                try:
                    proc = subprocess.run(cmd, capture_output=True, timeout=60)
                except (OSError, subprocess.TimeoutExpired) as exc:
                    notes.append(f"{label}: {tool} 실행 실패 ({exc})")
                    continue
                nodes = parse_dts(proc.stdout.decode("utf-8", "replace")) if proc.returncode == 0 else []
                if nodes:
                    return nodes, tool
                notes.append(f"{label}: {tool} 가 해석 결과를 내지 않았습니다 (종료 {proc.returncode})")
    try:
        return walk_fdt(blob), "builtin"
    except (ValueError, struct.error) as exc:
        notes.append(f"{label}: 내장 해석기도 실패했습니다 ({exc})")
        return [], None


# Property names are the standard device tree binding names; they are not device values.
MMC_NODE = re.compile(r"^(?:e?mmc|msdc|sdhci?|sdhc|sdmmc|dw[-_]?mshc|mshc)", re.I)
MMC_COMPAT = re.compile(r"mmc|msdc|sdhci?|mshc", re.I)
UFS_NODE = re.compile(r"^ufs", re.I)
UFS_COMPAT = re.compile(r"ufs", re.I)


def as_list(v):
    return v if isinstance(v, list) else []


def first_int(v):
    ints = [x for x in as_list(v) if isinstance(x, int)]
    return ints[0] if ints else None


def status_of(props):
    s = as_list(props.get("status"))
    return s[0] if s and isinstance(s[0], str) else None


def judge_nodes(nodes):
    """Per-node weighing: [(vote, node_path, why)] for mmc-class and UFS-class nodes."""
    out = []
    for n in nodes:
        props = n["props"]
        base = n["name"].split("@")[0]
        compat = [c for c in as_list(props.get("compatible")) if isinstance(c, str)]
        status = status_of(props)
        off = status in ("disabled", "fail", "reserved")
        is_mmc = bool(MMC_NODE.match(base) or any(MMC_COMPAT.search(c) for c in compat))
        is_ufs = bool(UFS_NODE.match(base) or any(UFS_COMPAT.search(c) for c in compat))
        if is_mmc and "bus-width" in props:
            width = first_int(props.get("bus-width"))
            marks = []
            if width == 8:
                marks.append("bus-width=8")
            if props.get("non-removable") is True:
                marks.append("non-removable")
            if props.get("no-sd") is True:
                marks.append("no-sd")
            if off:
                out.append(("none", n["path"], f"mmc 노드지만 status={status}"))
            elif marks:
                out.append(("emmc", n["path"], "eMMC 표지: " + ", ".join(marks)))
            else:
                out.append(("none", n["path"],
                            f"mmc 노드 bus-width={width} 뿐이고 eMMC 표지(8비트·non-removable·no-sd)가 "
                            "없음 — SD 슬롯일 수 있어 근거가 못 됨"))
        elif is_ufs and not is_mmc:
            if off:
                out.append(("none", n["path"], f"UFS 노드지만 status={status}"))
            elif status in ("okay", "ok"):
                out.append(("ufs", n["path"], 'UFS 노드가 status="okay" 로 명시됨'))
            else:
                out.append(("none", n["path"],
                            "UFS 노드가 있을 뿐 status 가 없음 — SoC 공용 노드일 수 있어 "
                            "존재만으로는 판정하지 않음"))
    return out


def scan_dtb(path, use_tools, evidence, notes, verdicts):
    """Weigh the device tree(s) in one --dtb input; per-tree verdicts go to `verdicts`."""
    if not os.path.isfile(path):
        notes.append(f"DTB 를 찾지 못했습니다: {path}")
        return
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        notes.append(f"DTB 를 읽지 못했습니다: {path} ({exc})")
        return
    base = os.path.basename(path)
    trees = []
    blobs = find_fdt_blobs(data)
    for off, blob in blobs:
        label = f"{base}@{off:#x}" if off or len(blob) != len(data) else base
        nodes, how = decode_blob(blob, use_tools, notes, label)
        if how:
            notes.append(f"{label}: DTB 를 {how} 로 해석 ({len(nodes)} 노드)")
        trees.append((label, nodes))
    if not blobs:
        head = data[:4096]
        if b"\0" not in head and b"{" in data:
            nodes = parse_dts(data.decode("utf-8", "replace"))
            notes.append(f"{base}: dts 소스로 읽음 ({len(nodes)} 노드)")
            trees.append((base, nodes))
        else:
            notes.append(f"{base}: DTB 가 아닙니다 (FDT 매직 d00dfeed 도, dts 텍스트도 없음)")
            return
    for label, nodes in trees:
        votes = judge_nodes(nodes)
        for vote, node_path, why in votes:
            evidence.append({"tier": "dtb", "source": label, "where": node_path,
                             "text": node_path, "vote": vote, "line_kind": "node", "why": why})
        kinds = {v for v, _p, _w in votes if v != "none"}
        if "emmc" in kinds:
            verdicts.append(("emmc", label, "ufs" in kinds))
        elif "ufs" in kinds:
            verdicts.append(("ufs", label, False))


def evidence_line(e):
    return f'{e["tier"]}: {e["source"]}:{e["where"]}: {e["text"]} -> {e["vote"]} ({e["why"]})'


def decide(evidence, dtb_verdicts, notes):
    """(hci_kind, basis, confidence, reason) by the priority in the module docstring."""
    log = [e for e in evidence if e["tier"] == "bootloader_log" and e["vote"] != "none"]
    for line_kind, label, conf in (("init", "초기화 줄", "high"),
                                   ("boot_device", "부트 디바이스 줄", "medium")):
        kinds = sorted({e["vote"] for e in log if e["line_kind"] == line_kind})
        if len(kinds) == 1:
            return kinds[0], "bootloader_log", conf, f"부트로더 로그의 {label}이 {kinds[0]} 하나만 가리킴"
        if len(kinds) > 1:
            return ("unknown", "none", "none",
                    f"부트로더 로그의 {label}이 eMMC 와 UFS 를 모두 초기화했다고 말함 — 충돌, "
                    "어느 쪽이 부팅 매체인지 이 근거로는 정하지 못함")
    if dtb_verdicts:
        kinds = sorted({k for k, _l, _b in dtb_verdicts})
        if len(kinds) > 1:
            return ("unknown", "none", "none",
                    "DTB 마다 판정이 다름 (" + ", ".join(f"{l}={k}" for k, l, _b in dtb_verdicts) + ")")
        kind = kinds[0]
        if kind == "emmc":
            if any(both for k, _l, both in dtb_verdicts if k == "emmc"):
                notes.append("UFS 노드도 status=okay 이나 SoC 공용 노드일 수 있어 eMMC 표지가 있는 "
                             "mmc 노드를 우선했습니다 — 부트로더 로그로 확인하십시오")
            return "emmc", "dtb", "medium", "DTB 에 eMMC 표지가 있는 mmc 노드가 켜져 있음 (부트로더 로그 근거는 없음)"
        return "ufs", "dtb", "low", "DTB 에서 UFS 노드만 status=okay 로 명시됨 (부트로더 로그 근거는 없음)"
    return "unknown", "none", "none", "매체를 가리키는 근거가 없음"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bootloader-log", action="append", default=[], metavar="FILE")
    ap.add_argument("--dtb", action="append", default=[], metavar="FILE")
    ap.add_argument("--builtin-dtb", action="store_true",
                    help="dtc/fdtdump 를 쓰지 않고 내장 해석기만 사용")
    args = ap.parse_args()

    evidence, notes, dtb_verdicts = [], [], []
    for path in args.bootloader_log:
        scan_log(path, evidence, notes)
    for path in args.dtb:
        scan_dtb(path, not args.builtin_dtb, evidence, notes, dtb_verdicts)
    if not args.bootloader_log and not args.dtb:
        notes.append("입력이 없습니다 (--bootloader-log, --dtb)")

    kind, basis, confidence, reason = decide(evidence, dtb_verdicts, notes)
    # Tiers that were weighed but lost: say so, so nobody reads a silent override.
    other = {v["vote"] for v in evidence if v["tier"] == "dtb" and v["vote"] != "none"}
    if basis == "bootloader_log" and other and kind not in other:
        notes.append(f"DTB 근거({'/'.join(sorted(other))})는 부트로더 로그와 다르지만 "
                     "우선순위에 따라 로그를 채택했습니다")

    shown = evidence[:MAX_EVIDENCE]
    print(json.dumps({
        "hci_kind": kind,
        "basis": basis,
        "confidence": confidence,
        "reason": reason,
        "evidence": [evidence_line(e) for e in shown],
        "evidence_omitted": len(evidence) - len(shown),
        "details": shown,
        "notes": notes,
        "inputs": {"bootloader_log": args.bootloader_log, "dtb": args.dtb},
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
