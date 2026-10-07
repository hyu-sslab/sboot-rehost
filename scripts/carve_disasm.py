#!/usr/bin/env python3
"""
carve_disasm.py — capstone 래퍼.
static-analyzer agent 가 호출.

--arch arm64 (기본) | arm32   AArch32/Thumb 부트로더(예: MediaTek LK)는 arm32.
--family <계열>               carve_check 의 문자열·크기 잣대를 고른다. 잣대는 아키텍처가 아니라
                              계열(SoC 제품군)에 딸려 있다: exynos · mediatek 만 잣대가 있고,
                              generic 이거나 잣대가 없는 계열은 컨테이너 헤더 근거도 없으면
                              is_full 을 판정하지 않는다 (`is_full: null`, 거짓이 아니다).
                              주지 않으면 예전 동작 (--arch 로 잣대를 고른다).

사용법:
  carve_disasm.py disasm <bl3.bin> <file_off> <size> <base_va>
  carve_disasm.py xref <bl3.bin> <ascii_string>
  carve_disasm.py find_xref_to <bl3.bin> <target_va> <base_va>
  carve_disasm.py carve_check <bl3.bin>
  carve_disasm.py score_entry <bl3.bin> <off>
"""
import sys
import os
import struct

try:
    import capstone
except ImportError:
    print("ERROR: capstone 미설치. pip3 install capstone", file=sys.stderr)
    sys.exit(2)


ARCH = "arm64"          # set by main() from --arch
FAMILY = None           # set by main() from --family; None = not given (ISA-keyed yardstick)


def _md():
    """Disassembler for the target's architecture.

    Not every bootloader at this stage is AArch64: MediaTek LK runs AArch32
    Thumb-2, so hardcoding ARM64 would make every derivation on such an image
    silently wrong rather than merely unsupported.
    """
    if ARCH == "arm32":
        md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB)
        md.skipdata = True
        return md
    return capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)


def _md_arm():
    """AArch32 in ARM (non-Thumb) mode - reset vectors are usually ARM."""
    return capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)


def disasm(path, off, size, base):
    data = open(path, "rb").read()[off:off + size]
    md = _md()
    for ins in md.disasm(data, base):
        print(f"0x{ins.address:08x}: {ins.mnemonic:10s} {ins.op_str}  ; {ins.bytes.hex()}")


def xref(path, needle):
    data = open(path, "rb").read()
    if isinstance(needle, str):
        needle = needle.encode("latin-1")
    pos = data.find(needle)
    if pos < 0:
        print("NOT FOUND")
        return
    print(f"file_offset: 0x{pos:x}")


def find_xref_to(path, target_va, base_va):
    """target_va 를 가리키는 정렬된 포인터 위치들을 binary 안에서 검색.

    포인터 폭은 아키텍처가 정한다. AArch32 부트로더(LK)에서 8 B 포인터를 찾으면
    히트가 0 이 나와 "명령 테이블 없음" 으로 오판한다.
    """
    width = 4 if ARCH == "arm32" else 8
    fmt = "<I" if width == 4 else "<Q"
    data = open(path, "rb").read()
    needle = struct.pack(fmt, target_va & (0xFFFFFFFF if width == 4 else 0xFFFFFFFFFFFFFFFF))
    pos = 0
    hits = []
    while True:
        pos = data.find(needle, pos)
        if pos < 0:
            break
        if pos % width == 0:
            hits.append(pos)
        pos += 1
    for h in hits:
        va = base_va + h
        print(f"file_offset: 0x{h:x}  va: 0x{va:x}  (ptr {width}B)")
    if not hits:
        print("NOT FOUND")


# What a "full" bootloader image looks like depends on the vendor. Samsung S-Boot
# is a ~4 MB AArch64 image with its shell banner; MediaTek LK is a ~1.5 MB
# AArch32 image with entirely different strings. Judging LK by the S-Boot
# yardstick reports a carve and blocks a perfectly complete image.
#
# These two sets were measured on ONE bootloader each. They are keyed by FAMILY below
# (CARVE_YARDSTICKS): the architecture does not say whose banner an image carries -
# an AArch64 bootloader of another family measured against the S-Boot set is judged
# partial for want of strings it never had. CARVE_PROFILES stays ISA-keyed only for a
# caller that does not pass --family (the previous behaviour).
CARVE_PROFILES = {
    "arm64": {
        "min_size": 4 * 1024 * 1024,
        "strings": [b"S-BOOT", b"autoboot", b"Following commands",
                    b"help", b"reset", b"dramtest"],
        "need": 3,
    },
    "arm32": {
        "min_size": 512 * 1024,
        "strings": [b"Little Kernel", b"lk build", b"fastboot", b"preloader",
                    b"boot mode", b"help", b"printenv"],
        "need": 2,
    },
}

# family -> yardstick. A family that is not here (generic, or one nobody measured) has
# no string/size yardstick: only the image's own container header can say it is partial.
CARVE_YARDSTICKS = {
    "exynos": CARVE_PROFILES["arm64"],
    "mediatek": CARVE_PROFILES["arm32"],
}


def container_extent(data):
    """(format, extent, how) from the image's OWN header, or None.

    The string yardstick above is tuned to one bootloader's banner; a first-stage
    container (a preloader) carries none of those strings and was judged a carve.
    A recognised container header says how much the image must hold: a payload
    size field (header + payload), or the length a GFH block declares (counted from
    where that block sits). An image that holds at least what its header declares
    is not a partial extraction. Only a header whose payload start was CONFIRMED
    counts: stage_map.parse_container marks a header larger than the file
    `unconfirmed`, which is exactly a carve.
    """
    try:
        import stage_map
    except ImportError:
        return None
    try:
        c = stage_map.parse_container(data)
    except Exception:
        return None
    if not c or c.get("payload_offset") is None or c.get("confidence") != "derived":
        return None
    po = c["payload_offset"]
    field = c.get("payload_size_field")
    if isinstance(field, int) and not isinstance(field, bool) and field > 0:
        return c["format"], po + field, "페이로드 크기 필드"
    try:
        g = stage_map.find_gfh(data, po)
    except Exception:
        g = None
    if not g:
        return None
    flen, goff = g.get("file_len"), g.get("file_offset")
    if isinstance(flen, int) and flen > 0 and isinstance(goff, int):
        return c["format"], goff + flen, "GFH 가 선언한 길이"
    return None


def truncated_extent(data):
    """(format, extent, how) of a recognised header that declares MORE than the file holds.

    container_extent() only trusts a header whose payload start was confirmed, and
    stage_map.parse_container refuses to confirm one whose declared size runs past the
    end of the file - which is exactly what a partial extraction looks like. That refusal
    is also the header's own statement that the image is cut, so a family with no string
    yardstick can still call it False on the header's say-so. Only the one case the
    parser itself names (header + payload size beyond the file) counts; a header it
    merely could not make sense of says nothing about the file's size."""
    try:
        import stage_map
        c = stage_map.parse_container(data)
    except Exception:
        return None
    if not c or c.get("format") != "mtk_image" or c.get("payload_offset") is not None:
        return None
    hsz, field = c.get("header_size_field"), c.get("payload_size_field")
    if not all(isinstance(v, int) and not isinstance(v, bool) for v in (hsz, field)):
        return None
    if 0x38 <= hsz <= 0x10000 and hsz % 4 == 0 and field > 0 and hsz + field > len(data):
        return c["format"], hsz + field, "페이로드 크기 필드"
    return None


def carve_verdict(data, arch, family):
    """Judge one image: a dict with is_full (True | False | None) and what decided it.

    is_full is None when nothing measurable applies: --family was given, that family
    has no yardstick, and the image carries no container header that says how big it
    must be. Undetermined is not a carve - calling it False would block a whole run on
    a measurement nobody could make. False needs a yardstick or the header to say so.
    family None keeps the previous behaviour: the ISA picks the yardstick."""
    size = len(data)
    if family is None:
        prof, yardstick = CARVE_PROFILES[arch], "isa:" + arch
    else:
        prof = CARVE_YARDSTICKS.get(family)
        yardstick = ("family:" + family) if prof else None
    found = []
    by_strings = False
    if prof:
        for s in prof["strings"]:
            off = data.find(s)
            if off >= 0:
                found.append((s.decode(errors="replace"), hex(off)))
        by_strings = size >= prof["min_size"] and len(found) >= prof["need"]
    ext = container_extent(data)
    if ext is None and family is not None:
        ext = truncated_extent(data)      # a header that says "I am cut" is evidence too
    by_header = bool(ext and size >= ext[1])
    note = None
    if by_strings or by_header:
        is_full = True
    elif prof or ext:
        is_full = False          # a yardstick or the header measured it, and it came up short
    else:
        is_full = None
        note = (f"family '{family}' has no string/size yardstick and the image carries no "
                "recognised container header - undetermined, not a carve")
    return {"is_full": is_full, "size": size, "prof": prof, "yardstick": yardstick,
            "found": found, "ext": ext, "by_strings": by_strings, "by_header": by_header,
            "note": note}


def carve_check(path):
    """부트로더 이미지가 full 인지 carve(부분 추출)인지 판정 (True · False · null=판정 못 함)."""
    data = open(path, "rb").read()
    v = carve_verdict(data, ARCH, FAMILY)
    prof, size, ext = v["prof"], v["size"], v["ext"]
    print(f"arch: {ARCH}")
    if FAMILY is not None:
        print(f"family: {FAMILY}")
        print(f"yardstick: {v['yardstick'] or 'none'}")
    print(f"size: {size} ({size // 1024} KB" + (f", 기준 {prof['min_size'] // 1024} KB 이상)" if prof else ")"))
    if prof:
        print(f"found_strings: {v['found']}  (기준 {prof['need']} 개 이상)")
    if ext:
        print(f"container: {ext[0]}, 헤더가 요구하는 범위 {ext[1]} B ({ext[2]}), 파일 {size} B → "
              + ("그만큼 있음" if v["by_header"] else "모자람 (부분 추출 의심)"))
    is_full = v["is_full"]
    print("is_full: " + ("null" if is_full is None else str(is_full)))
    if is_full:
        print("is_full_basis: " + ("컨테이너 헤더" if v["by_header"] and not v["by_strings"] else "문자열 기준"))
    if v["note"]:
        print(f"is_full_note: {v['note']}")


def score_entry(path, off):
    """AArch64 부팅 패턴 점수."""
    data = open(path, "rb").read()
    chunk = data[off:off + 0x100]
    md = _md()
    isa = "thumb" if ARCH == "arm32" else None
    if ARCH == "arm32" and len(chunk) >= 4:
        # Exception vectors and crt0 are ARM-state code. Decoding them as Thumb
        # gives plausible-looking garbage and a score that means nothing, so an
        # entry that starts with an ARM branch / `ldr pc` is decoded as ARM.
        w = struct.unpack_from("<I", chunk)[0]
        if (w & 0xFF000000) == 0xEA000000 or (w & 0xFFFFF000) == 0xE59FF000:
            md = _md_arm()
            md.skipdata = True
            isa = "arm"
    insns = list(md.disasm(chunk, off))
    text = "\n".join(f"{i.mnemonic} {i.op_str}" for i in insns)
    score = 0
    reasons = []
    if ARCH == "arm32":
        # AArch32 bootloaders start at an exception vector table and set up
        # MMU/caches through CP15, which look nothing like the AArch64 pattern.
        if "mrc" in text or "mcr" in text:
            score += 3; reasons.append("CP15 mrc/mcr (+3)")
        if text.strip().startswith("b ") or "\nb " in text:
            score += 3; reasons.append("벡터 b reset (+3)")
        if "cpsid" in text or "cpsr" in text:
            score += 2; reasons.append("cpsid/CPSR (+2)")
        if any(i.mnemonic in ("b", "bl", "blx") for i in insns[-5:]):
            score += 1; reasons.append("b/bl 끝 (+1)")
        print(f"score: {score}/10  (arch=arm32, isa={isa})")
        for r in reasons: print(f"  {r}")
        print("--- 첫 0x40 디스어셈블 ---")
        for ins in insns[:16]:
            print(f"  0x{ins.address:08x}: {ins.mnemonic:10s} {ins.op_str}")
        return
    if "msr vbar_el" in text:
        score += 3
        reasons.append("msr vbar_el (+3)")
    if "currentel" in text and ("b.eq" in text or "b.ne" in text):
        score += 3
        reasons.append("EL 분기 (+3)")
    if "msr scr_el3" in text or "msr sctlr_el" in text:
        score += 2
        reasons.append("msr scr/sctlr (+2)")
    if "daifset" in text:
        score += 1
        reasons.append("daifset (+1)")
    if any(i.mnemonic in ("b", "bl") for i in insns[-5:]):
        score += 1
        reasons.append("b/bl 끝 (+1)")
    print(f"score: {score}/10")
    for r in reasons:
        print(f"  {r}")
    print(f"--- 첫 0x40 디스어셈블 ---")
    for ins in insns[:16]:
        print(f"  0x{ins.address:08x}: {ins.mnemonic:10s} {ins.op_str}")


def main():
    global ARCH, FAMILY
    argv = sys.argv[1:]
    # --arch arm64|arm32 may appear anywhere; strip it before positional parsing.
    if "--arch" in argv:
        i = argv.index("--arch")
        ARCH = argv[i + 1] if i + 1 < len(argv) else "arm64"
        del argv[i:i + 2]
    if ARCH not in ("arm64", "arm32"):
        print(f"carve_disasm: unknown --arch '{ARCH}' (arm64|arm32)", file=sys.stderr)
        sys.exit(1)
    # --family <name> likewise. Any non-empty name is accepted: a family nobody measured
    # simply has no yardstick (undetermined), which is the honest answer, whereas refusing
    # it would stop a run on a family the pipeline learned about after this script was written.
    if "--family" in argv:
        i = argv.index("--family")
        fam = argv[i + 1].strip().lower() if i + 1 < len(argv) else ""
        if not fam or fam.startswith("--"):
            print("carve_disasm: --family 에는 계열 이름이 필요합니다 (exynos|mediatek|generic ...)",
                  file=sys.stderr)
            sys.exit(1)
        FAMILY = fam
        del argv[i:i + 2]
    sys.argv = [sys.argv[0]] + argv

    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    op = sys.argv[1]
    if op == "disasm":
        disasm(sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0), int(sys.argv[5], 0))
    elif op == "xref":
        xref(sys.argv[2], sys.argv[3])
    elif op == "find_xref_to":
        find_xref_to(sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0))
    elif op == "carve_check":
        carve_check(sys.argv[2])
    elif op == "score_entry":
        score_entry(sys.argv[2], int(sys.argv[3], 0))
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
