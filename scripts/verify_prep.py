#!/usr/bin/env python3
"""verify_prep.py - prepare the EVIDENCE the origin gates compare against.

The firmware's strings are not always where verify.py looks. A kernel inside
boot.img is gzip-compressed, so its banner is not in any raw search; the ramdisk
is a compressed cpio; a rootfs is thousands of files in directories, while the
reference loader reads only top-level files up to 128 MB. And the console that
comes out of a real run carries values (addresses, kallsyms-resolved symbols)
that no image contains. This step makes all of that comparable WITHOUT making it
easier to pass:

  reference set   <workdir>/verify_ref/
                    kernel_Image.img        boot.img's kernel, decompressed
                    boot_ramdisk.cpio.img   boot.img's ramdisk, decompressed
                    <label>_NN.bin          files from --flatten packed into pieces
                                            below the size cap (overlapping, so a
                                            string at a seam still matches whole)
                  Partitions that build_lu.py synthesized or forged (lu_provenance
                  .json) and the synthesized medium image are left OUT: bytes we
                  wrote cannot be the evidence for output we want to prove genuine.

  console         07_logs/guest_console_<N>.raw.txt    the guest console as it is
                                                       (UART + memory-dump kernel
                                                       log, host lines removed)
                  07_logs/guest_console_<N>.norm.txt   the same, normalized by
                                                       DELETION and SUBSTITUTION only:
                    R1  hex literal 0x... -> 0x
                    R2  delete lines carrying a kallsyms-resolved symbol
                        (`calling fn+0x..`, `initcall fn returned`, `fn+0x../0x..`)
                    R3  delete pstore boundary markers (the persistent-ram signature)
                    R4  delete hex-dump lines (`: [0x..] = `)
                  The raw console is kept next to it and is what gate 1 reads: a
                  line deleted from the normalized copy could hide a leak.

Read in binary. A text-mode read silently drops a guest line that carries a stray
carriage return.

Usage:
  verify_prep.py <workdir> [--round N] [--boot-img FILE] [--flatten PATH ...]
                 [--label NAME] [--console FILE] [--memdump-log FILE]
                 [--out-dir DIR] [--piece-mb 120] [--overlap-kb 4]

Prints one JSON object describing what was written.
"""
import argparse
import bz2
import glob
import json
import lzma
import os
import re
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_gates as vg  # noqa: E402

# --- console normalization (deletion and substitution only) -------------------
R1_HEX = re.compile(rb"0[xX][0-9A-Fa-f]+")
R2_KALLSYMS = re.compile(
    rb"calling\s+\S+\+0x[0-9A-Fa-f]+|initcall\s+\S+\s+returned|\[<[0-9A-Fa-f]{8,}>\]|"
    rb"\b(?:pc|lr)\s*:\s*\S+\+0x|\S+\+0x[0-9A-Fa-f]+/0x[0-9A-Fa-f]+")
R3_PSTORE = re.compile(rb"DBGC")        # the persistent-ram buffer signature, "DBGC"
R4_HEXDUMP = re.compile(rb": \[0x[0-9A-Fa-f]+\] = ")


def normalize_lines(lines):
    """(normalized_lines, counts). Every output line is an input line with `0x...`
    shortened, or absent. Nothing is ever added."""
    out, counts = [], {"R1": 0, "R2": 0, "R3": 0, "R4": 0}
    for ln in lines:
        if R3_PSTORE.search(ln):
            counts["R3"] += 1
            continue
        if R2_KALLSYMS.search(ln):
            counts["R2"] += 1
            continue
        if R4_HEXDUMP.search(ln):
            counts["R4"] += 1
            continue
        ln, k = R1_HEX.subn(b"0x", ln)
        counts["R1"] += k
        out.append(ln)
    return out, counts


# --- decompression --------------------------------------------------------------
def detect_compression(data):
    if data[:2] == b"\x1f\x8b":
        return "gzip"
    if data[:6] == b"\xfd7zXZ\x00":
        return "xz"
    if data[:3] == b"BZh":
        return "bzip2"
    if data[:4] in (b"\x04\x22\x4d\x18", b"\x02\x21\x4c\x18"):
        return "lz4"
    if data[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    return None


def decompress(data):
    """(plain_bytes, kind). kind is the compression found; plain is None when it
    is one this script cannot undo (lz4, zstd) - said out loud, not skipped."""
    kind = detect_compression(data)
    if kind is None:
        return data, None
    try:
        if kind == "gzip":
            d = zlib.decompressobj(31)
            out, total = [], 0
            for i in range(0, len(data), 1 << 20):
                chunk = d.decompress(data[i:i + (1 << 20)])
                total += len(chunk)
                if total > vg.GUNZIP_CAP:
                    return None, kind
                out.append(chunk)
                if d.eof:
                    break
            return b"".join(out), kind
        if kind == "xz":
            return lzma.LZMADecompressor().decompress(data), kind
        if kind == "bzip2":
            return bz2.BZ2Decompressor().decompress(data), kind
    except (zlib.error, lzma.LZMAError, OSError, EOFError, ValueError):
        return None, kind
    return None, kind


# --- Android boot image ---------------------------------------------------------
def parse_boot_img(data):
    """The kernel and ramdisk extents of an Android boot image (header v0-v4).

    v0-v2 keep the page size at 0x24; v3+ use a fixed 4096 and move the sizes. The
    header version is at 0x28 in all of them."""
    if data[:8] != b"ANDROID!" or len(data) < 48:
        return None
    ver = struct.unpack_from("<I", data, 40)[0]
    if ver >= 3:
        ks, rs = struct.unpack_from("<II", data, 8)[0], struct.unpack_from("<I", data, 12)[0]
        page = 4096
    else:
        ks, rs = struct.unpack_from("<I", data, 8)[0], struct.unpack_from("<I", data, 16)[0]
        page = struct.unpack_from("<I", data, 36)[0]
    if page < 512 or page & (page - 1):
        return None
    koff = page
    roff = page + ((ks + page - 1) // page) * page
    return {"version": ver, "page_size": page, "kernel": (koff, ks), "ramdisk": (roff, rs)}


def cpio_names(data, limit=500000):
    """Entry names of a newc cpio (what the ramdisk contains)."""
    names, pos = [], 0
    while pos + 110 <= len(data) and len(names) < limit:
        if data[pos:pos + 6] != b"070701":
            break
        try:
            filesize = int(data[pos + 54:pos + 62], 16)
            namesize = int(data[pos + 94:pos + 102], 16)
        except ValueError:
            break
        name = data[pos + 110:pos + 110 + namesize - 1].decode("latin-1")
        if name == "TRAILER!!!":
            break
        names.append(name)
        pos = (pos + 110 + namesize + 3) & ~3
        pos = (pos + filesize + 3) & ~3
    return names


def prepare_boot(boot_path, out_dir, notes):
    rep = {"boot_img": boot_path, "kernel": None, "ramdisk": None}
    with open(boot_path, "rb") as fh:
        data = fh.read()
    info = parse_boot_img(data)
    if info is None:
        notes.append("boot.img 가 Android 부트 이미지가 아닙니다: %s" % boot_path)
        return rep
    rep["header_version"] = info["version"]
    for key, fname in (("kernel", "kernel_Image.img"), ("ramdisk", "boot_ramdisk.cpio.img")):
        off, size = info[key]
        blob = data[off:off + size]
        if not blob:
            continue
        plain, kind = decompress(blob)
        if plain is None:
            notes.append("%s 의 압축(%s)을 풀지 못했습니다 — 풀지 않은 채로는 문자열이 검색되지 "
                         "않습니다. 직접 풀어 --flatten 으로 넘기십시오" % (key, kind))
            plain = blob
        path = os.path.join(out_dir, fname)
        with open(path, "wb") as fh:
            fh.write(plain)
        rep[key] = {"file": path, "compressed": kind, "bytes_in": len(blob), "bytes_out": len(plain)}
        if key == "ramdisk":
            names = cpio_names(plain)
            rep[key]["entries"] = len(names)
    return rep


# --- flatten ---------------------------------------------------------------------
def collect_files(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in sorted(files):
                    out.append(os.path.join(root, f))
        elif os.path.isfile(p):
            out.append(p)
    return sorted(set(out))


def flatten(paths, out_dir, label, piece, overlap, kinds, workdir):
    """Pack the files into pieces of at most `piece` bytes.

    The reference loader reads only top-level files and skips any above the cap, so
    a rootfs tree or a 1 GB image is invisible to it as it is. A file bigger than a
    piece is cut into windows that overlap by `overlap` bytes (a string lying on a
    seam still sits whole inside one piece); small files are appended one after the
    other with a NUL between them."""
    for old in glob.glob(os.path.join(out_dir, "%s_[0-9][0-9].bin" % label)):
        os.remove(old)
    bad_names = {n.lower() for n, v in kinds.items() if v["kind"] in ("synthesized", "forged")}
    bad_paths = {os.path.realpath(os.path.join(workdir, v["source"])) for v in kinds.values()
                 if v["kind"] in ("synthesized", "forged") and v["source"]}
    excluded, written, n_files = [], [], 0
    state = {"fh": None, "size": 0, "n": 0}

    def open_piece():
        if state["fh"]:
            state["fh"].close()
        path = os.path.join(out_dir, "%s_%02d.bin" % (label, state["n"]))
        state["n"] += 1
        state["fh"], state["size"] = open(path, "wb"), 0
        written.append(path)

    for path in collect_files(paths):
        base = os.path.basename(path)
        real = os.path.realpath(path)
        if os.path.islink(path):
            continue
        if real in bad_paths or os.path.splitext(base)[0].lower() in bad_names \
                or vg._MEDIUM_NAME.search(base):
            excluded.append({"file": path, "reason": "합성·위조 파티션 또는 합성 매체"})
            continue
        n_files += 1
        try:
            with open(path, "rb") as src:
                size = os.path.getsize(path)
                if size > piece:
                    step = piece - overlap
                    for start in range(0, size, step):
                        src.seek(start)
                        chunk = src.read(piece)
                        if state["fh"] is None or state["size"]:
                            open_piece()
                        state["fh"].write(chunk)
                        state["size"] = piece           # a window fills its piece
                        if start + piece >= size:
                            break
                    continue
                data = src.read()
        except OSError:
            continue
        if state["fh"] is None or state["size"] + len(data) + 1 > piece:
            open_piece()
        state["fh"].write(data + b"\0")
        state["size"] += len(data) + 1
    if state["fh"]:
        state["fh"].close()
    return {"label": label, "files": n_files, "pieces": written, "excluded": excluded}


# --- console ---------------------------------------------------------------------
def prepare_console(workdir, rnd, console_path, memdump_path, notes):
    logs = os.path.join(workdir, "07_logs")
    if rnd is None and console_path:
        m = re.fullmatch(r"console_(\d+)\.txt", os.path.basename(console_path))
        rnd = m.group(1) if m else None
    if not console_path:
        cands = [(int(m.group(1)), p) for p in glob.glob(os.path.join(logs, "console_*.txt"))
                 for m in [re.fullmatch(r"console_(\d+)\.txt", os.path.basename(p))] if m]
        if rnd is not None:
            console_path = os.path.join(logs, "console_%s.txt" % rnd)
        elif cands:
            n, console_path = max(cands)
            rnd = str(n)
    if rnd is None:
        rnd = "1"
    if not memdump_path:
        cand = os.path.join(logs, "kernel_%s.log" % rnd)
        memdump_path = cand if os.path.isfile(cand) else None
    if not console_path or not os.path.isfile(console_path):
        notes.append("콘솔이 없습니다 (07_logs/console_<N>.txt) — 정규화하지 않았습니다")
        return None
    guest = vg.read_guest_console(console_path, memdump_path)
    raw_path = os.path.join(logs, "guest_console_%s.raw.txt" % rnd)
    norm_path = os.path.join(logs, "guest_console_%s.norm.txt" % rnd)
    with open(raw_path, "wb") as fh:
        fh.write(guest["bytes"])
    norm, counts = normalize_lines(guest["lines"])
    with open(norm_path, "wb") as fh:
        fh.write(b"\n".join(norm) + (b"\n" if norm else b""))
    return {"round": rnd, "console": console_path, "memdump_log": memdump_path,
            "raw": raw_path, "normalized": norm_path,
            "uart_lines": guest["uart_lines"], "memdump_lines": guest["memdump_lines"],
            "host_lines_dropped": guest["host_dropped"],
            "lines_raw": len(guest["lines"]), "lines_normalized": len(norm), "rules": counts}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workdir")
    ap.add_argument("--round", default=None)
    ap.add_argument("--boot-img", default=None,
                    help="boot.img whose kernel and ramdisk are unpacked "
                         "(default: fw/boot.img or 02_unpacked/boot.img)")
    ap.add_argument("--flatten", nargs="*", default=[],
                    help="files or directories to pack into reference pieces")
    ap.add_argument("--label", default="flat")
    ap.add_argument("--console", default=None)
    ap.add_argument("--memdump-log", default=None)
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--piece-mb", type=int, default=120,
                    help="piece size; must stay below the 128 MB the reference loader reads")
    ap.add_argument("--overlap-kb", type=int, default=4)
    args = ap.parse_args(argv)

    wd = args.workdir
    out_dir = args.out_dir or os.path.join(wd, "verify_ref")
    os.makedirs(out_dir, exist_ok=True)
    notes = []
    piece = args.piece_mb * 1024 * 1024
    if piece >= vg.IMAGE_MAX:
        notes.append("--piece-mb 가 기준 이미지 상한(%d MB) 이상이라 조각이 건너뛰어집니다 — %d MB 로 "
                     "낮췄습니다" % (vg.IMAGE_MAX // (1 << 20), 120))
        piece = 120 * 1024 * 1024
    overlap = min(args.overlap_kb * 1024, piece // 2)

    report = {"ok": True, "out_dir": out_dir, "boot": None, "flatten": None,
              "console": None, "notes": notes}
    boot = args.boot_img
    if not boot:
        for cand in (os.path.join(wd, "fw", "boot.img"), os.path.join(wd, "02_unpacked", "boot.img")):
            if os.path.isfile(cand):
                boot = cand
                break
    if boot and os.path.isfile(boot):
        report["boot"] = prepare_boot(boot, out_dir, notes)
    elif args.boot_img:
        report["ok"] = False
        notes.append("boot.img 가 없습니다: %s" % args.boot_img)
    else:
        notes.append("boot.img 를 찾지 못했습니다 — 커널·램디스크를 풀지 않았습니다 "
                     "(커널 문자열은 gzip 안에 있어 원본으로는 검색되지 않습니다)")
    if args.flatten:
        kinds = vg.load_medium_kinds(wd)
        report["flatten"] = flatten(args.flatten, out_dir, args.label, piece, overlap, kinds, wd)
    report["console"] = prepare_console(wd, args.round, args.console, args.memdump_log, notes)

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
