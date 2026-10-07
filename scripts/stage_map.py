#!/usr/bin/env python3
"""stage_map.py - derive the executable stage map of a bootloader container.

A vendor bootloader image is several stages concatenated: some plaintext and
runnable, some encrypted with a key that lives in silicon, some absent entirely.
Rehosting the chain means knowing **which is which, where each one loads, and
where it starts** - and knowing it as derived fact, not as a value borrowed from
another device.

This encodes the procedure that worked, so it can be re-run on the next firmware
instead of re-invented:

  1. entropy grid      plaintext / encrypted / zero-padding, on a fixed grid
  2. entry-stub scan   arch-specific reset-stub signature marks a stage boundary
  3. string context    what each region says about itself
  4. base derivation   basefind, then **cross-checked against a literal anchor**

AArch32 (--arch arm32) has no CurrentEL and no VBAR_EL*, so steps 2 and 4 use
other evidence: the stage is entered at a vector table (or at the entry a GFH
header declares), and its base is accepted only when TWO independent anchors
land on the same value (a self-relocation literal checked against the header's
payload size, a GFH load address, absolute literal-pool pointers that land on
strings and function prologues). Anchors that do not converge leave the stage
`unconfirmed` - listed with its candidates and not runnable.

Step 4's cross-check is the part that must not be skipped. Pointer-containment
alone picked a wrong base on real firmware (off by ~0xBE000000); the base only
became fact when a BSS pointer from the image, converted to a file offset,
landed exactly where the file's zero padding began. A base with no anchor is
reported as a candidate, never as derived.

Usage:
  stage_map.py <image> [--arch arm64|arm32] [--profile <name>]
                       [--origin container|medium|handoff] [--partition <name>]
                       [--out stage_map.json] [--grid 0x800] [--quiet]

`--arch` is an input, not a default to trust: decide it first with

  stage_map.py --detect-arch <image-or-container>

which prints ONE JSON object on stdout and exits 0:

  {"arch": "arm32"|"arm64"|"unknown",
   "entry_signature": "gfh"|"vector_table"|"crt0"|"stub:<name>"|"none",
   "basis": ["<evidence line>", ...],
   "confidence": "derived"|"cross_checked"|"unconfirmed"}

arch is that of the ISA the image's first stage is entered in. It is named only when
the image carries a structural signature (the entry a GFH header declares, a vector
table or crt0 at the payload start, an AArch32 self-relocation stub, an AArch64
CurrentEL/VBAR stub); byte-pattern statistics alone never name it. `cross_checked`
means two independent evidence classes agree and none disagrees, `derived` one.
`unknown` (confidence `unconfirmed`) is a real answer: no signature, signatures of
both ISAs, or a signature the statistics contradict. basis always says why. Run it
per image: a chain can mix ISAs (the first container's answer is not the chain's).

One image per run. A chain whose stages live in several images (a preloader
container, then a bootloader the preloader reads from the medium) is mapped one
image at a time - `--origin medium --partition <name>` for the later ones - and
then combined, in chain order:

  stage_map.py --merge a.json b.json ... [--out stage_map.json] [--quiet]

The merge only concatenates and renumbers: every stage keeps all its fields (each one
also records the `image` it was derived from, because file_range is an offset into THAT
image), nothing is re-derived, and the top-level fields of the first map stay what a
v1 reader expects (`arch` is the first stage's, `arch_supported` is true only if every
input says so). The inputs are the files the per-image runs wrote.

Output is schema v2: every v1 field is kept, and each stage also carries
arch, origin, entered_by, entry_pc (absolute), anchors, confidence, container.

Exit codes:
  0  a map was produced (possibly with unresolved bases - see `confidence`);
     --detect-arch: the JSON object was printed (arch may be unknown)
  2  --merge: an input is not a stage map (unreadable, not JSON, no stages list);
     --detect-arch: the file cannot be read
  3  no entry signature was found for this architecture: caller should report
     BLOCKED_ARCH rather than pretend the image has no stages
  64 --detect-arch was combined with an image or --merge (a usage error, not a read failure)
"""
import argparse
import json
import math
import os
import re
import struct
import sys
from collections import Counter

# ---- AArch64 encodings we match without a disassembler -----------------------
# Raw masks keep this script dependency-free: capstone is not needed to find a
# reset stub, and requiring it would put a pip install between the analyst and
# the first fact.
A64 = {
    "mrs_currentel": (0xFFFFFFE0, 0xD5384240),
    "msr_vbar_el1":  (0xFFFFFFE0, 0xD518C000),
    "msr_vbar_el2":  (0xFFFFFFE0, 0xD51CC000),
    "msr_vbar_el3":  (0xFFFFFFE0, 0xD51EC000),
}
A64_ADR = (0x9F000000, 0x10000000)

ENC_MIN = 7.5      # entropy at or above this reads as encrypted/compressed
PLAIN_MAX = 5.0    # below this is text, tables or sparse data


def entropy(block):
    if not block:
        return 0.0
    counts = Counter(block)
    n = len(block)
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


def classify(block):
    if not block or block == bytes(len(block)):
        return "zero"
    e = entropy(block)
    if e >= ENC_MIN:
        return "enc"
    if e < PLAIN_MAX:
        return "plain"
    return "mid"          # dense code reads here; so does light compression


def entropy_runs(data, grid):
    """Collapse the grid into labelled runs [start, end, label, max_entropy]."""
    runs, prev = [], None
    for off in range(0, len(data), grid):
        block = data[off:off + grid]
        label = classify(block)
        e = entropy(block)
        if label != prev:
            runs.append([off, off + len(block), label, e])
            prev = label
        else:
            runs[-1][1] = off + len(block)
            runs[-1][3] = max(runs[-1][3], e)
    return [{"start": a, "end": b, "label": l, "max_entropy": round(e, 2)}
            for a, b, l, e in runs]


def words(data):
    """Little-endian 32-bit words with their file offsets, 4-byte aligned."""
    for i in range(0, len(data) - 3, 4):
        yield i, int.from_bytes(data[i:i + 4], "little")


def find_entry_stubs_arm64(data, window=80):
    """A stage's reset stub, not every function that reads CurrentEL.

    The distinguishing shape is `CurrentEL` read **and** a vector base written
    nearby: `mrs xN, currentel` on its own is a getter, and matching on it alone
    reported helper functions as stage boundaries.
    """
    cur, vbar, adrs = [], {}, set()
    for off, w in words(data):
        m, v = A64["mrs_currentel"]
        if w & m == v:
            cur.append(off)
            continue
        for name in ("msr_vbar_el1", "msr_vbar_el2", "msr_vbar_el3"):
            m, v = A64[name]
            if w & m == v:
                vbar[off] = name
        m, v = A64_ADR
        if w & m == v:
            adrs.add(off)

    stubs = []
    for off in cur:
        near = {o: n for o, n in vbar.items() if -16 <= o - off <= window}
        if not near:
            continue                      # a getter, not a stub
        levels = sorted({n.split("_")[-1] for n in near.values()})
        # The stub loads its vector table address before testing the level.
        has_adr = any(off - 24 <= a < off for a in adrs)
        stubs.append({
            "at": off,
            "vbar_writes": levels,
            "adr_before": has_adr,
            # An entry stub is the first instruction of a stage, so the stage
            # starts at the branch that precedes it, not at the `mrs`.
            "stage_start": stub_start(data, off),
        })
    return stubs


def stub_start(data, mrs_off, back=32):
    """Walk back to the `b .+4` / `adr` preamble that opens the stub."""
    start = mrs_off
    for off in range(max(0, mrs_off - back), mrs_off, 4):
        w = int.from_bytes(data[off:off + 4], "little")
        if w & 0xFC000000 == 0x14000000:      # unconditional B
            start = off
            break
        m, v = A64_ADR
        if w & m == v:
            start = min(start, off)
    return start


def strings_in(data, lo, hi, minlen=8, limit=4000):
    out = []
    for m in re.finditer(rb"[ -~]{%d,}" % minlen, data[lo:hi]):
        out.append((lo + m.start(), m.group().decode("ascii", "replace")))
        if len(out) >= limit:
            break
    return out


def basefind(data, lo, hi, granule=0x1000, floor=0x1000):
    """Rank candidate load bases by how many in-image pointers they explain."""
    span = hi - lo
    vals = []
    for i in range(lo, max(lo, hi - 8), 8):
        v = int.from_bytes(data[i:i + 8], "little")
        if floor <= v < (1 << 32):
            vals.append(v)
    if not vals:
        return [], 0
    cands = {(v // granule) * granule for v in vals}
    scored = []
    for base in cands:
        n = sum(1 for v in vals if base <= v < base + span)
        if n:
            scored.append((n, base))
    scored.sort(reverse=True)
    return scored[:32], len(vals)


def anchor_check(data, lo, hi, base, zero_min=0x400):
    """Does a pointer from this region land where the file's padding starts?

    A stage's BSS begins right after its loaded image, so `bss_start - base`
    converted to a file offset must land on zero padding. That coincidence is
    what turns a base candidate into a derived value; without it two bases a
    megabyte apart score almost the same.
    """
    span = hi - lo
    hits = []
    for i in range(lo, max(lo, hi - 8), 8):
        v = int.from_bytes(data[i:i + 8], "little")
        if not (base <= v < base + span + (1 << 24)):
            continue
        off = lo + (v - base)
        if not (lo < off <= len(data) - zero_min):
            continue
        if data[off:off + zero_min] == bytes(zero_min):
            # Padding must START here, or every offset inside a big zero run
            # would look like an anchor.
            if off >= 4 and data[off - 4:off] != bytes(4):
                hits.append({"literal_at": i, "value": v, "file_offset": off})
    return hits


MIN_POINTERS = 8


def low_base_hint(data, lo, hi, sample=4000):
    """Do this stage's own branch targets stay inside the image?

    A first stage often runs at address 0, where every internal call is an
    absolute low address. basefind cannot see that - it only looks at high
    values - so the stage reports no base when the answer is simply zero.
    """
    inside = outside = 0
    span = hi - lo
    for off in range(lo, min(hi, lo + sample * 4), 4):
        w = int.from_bytes(data[off:off + 4], "little")
        if w & 0xFC000000 != 0x94000000:        # BL imm26
            continue
        imm = w & 0x03FFFFFF
        if imm & (1 << 25):
            imm -= (1 << 26)
        target = (off - lo) + imm * 4
        if 0 <= target < span:
            inside += 1
        else:
            outside += 1
    if inside and inside >= outside * 3:
        return (f"내부 BL 대상 {inside}개가 전부 이미지 안입니다 — **base=0 실행 가능성**. "
                f"호출 대상 몇 개를 디스어셈블해 정상 함수 프롤로그인지 확인하십시오")
    return None


def derive_base(data, lo, hi):
    scored, total = basefind(data, lo, hi)
    if not scored:
        return {"load_base": None, "confidence": "none",
                "why": "주소로 볼 만한 64비트 값이 이 구간에 없습니다",
                "low_base_hint": low_base_hint(data, lo, hi)}
    best = []
    for n, base in scored[:12]:
        hits = anchor_check(data, lo, hi, base)
        best.append((len(hits), n, base, hits))
    best.sort(reverse=True)
    anchors, contained, base, hits = best[0]
    if anchors:
        return {
            "load_base": base,
            "confidence": "derived",
            "pointer_containment": round(contained / max(total, 1), 3),
            "anchors": hits[:4],
            "why": "리터럴 앵커가 파일의 제로 패딩 시작에 정확히 착지 (교차검증 통과)",
        }
    contained, base = scored[0]
    # A handful of matches is not a candidate. AArch64 instruction words read as
    # plausible addresses (an `msr vbar_el3` is 0xd51ec000), so a base supported
    # by a few words is usually the encoding of an opcode, not a load address.
    if contained < MIN_POINTERS:
        return {
            "load_base": None,
            "confidence": "none",
            "why": (f"최상위 후보 0x{base:08x} 를 뒷받침하는 포인터가 {contained}개뿐입니다 "
                    f"(하한 {MIN_POINTERS}). 명령어 인코딩이 주소처럼 보인 것일 수 있어 "
                    f"후보로도 내지 않습니다"),
            "low_base_hint": low_base_hint(data, lo, hi),
        }
    return {
        "load_base": base,
        "confidence": "candidate",
        "pointer_containment": round(contained / max(total, 1), 3),
        "anchors": [],
        "why": "포인터 포함률 1위이나 **앵커 교차검증 실패** — 확정값으로 쓰지 마십시오",
    }


# ---- AArch32 (arm32) --------------------------------------------------------
# AArch32 has no CurrentEL and no VBAR_EL*, so the AArch64 reset-stub signature
# finds nothing and "no stages" would be a false observation. What marks a stage
# here is where it is ENTERED: a vector table at the start of the payload, or the
# entry a header declares. Its load address cannot come from BSS padding either -
# literals are 4-byte pool words - so the evidence is different too.
#
# Raw masks again, for the same reason as AArch64: no pip install between the
# analyst and the first fact. capstone is used only to print the entry for a
# human to read, never to decide anything.

# Container formats are parsed, not guessed: these are the formats' own magics,
# not values of any one device.
MTK_MAGIC = 0x58881688        # container header, first word
MTK_EXT_MAGIC = 0x58891689    # extension header inside it; carries the header size
GFH_MAGIC = b"MMM\x01"        # 0x014D4D4D little-endian
GFH_FILE_INFO = b"FILE_INFO"
EMMC_BOOT_ID = b"EMMC_BOOT"
BRLYT_ID = b"BRLYT"

GFH_SCAN = 0x2000             # how far past the payload start a GFH is looked for
SELF_RELOC_SCAN = 0x2000      # startup code window searched for the relocation stub
COPY_END_TOLERANCE = 192      # |copy end - link address - header payload size|, bytes. Calibrated on ONE image:
                              # 0xC0 was the gap there (a footer past the copied code), so this number is
                              # fitted to that image and has no margin on it. Revisit with more images; a
                              # longer footer rejects the self-relocation anchor and leaves the stage
                              # `unconfirmed` (conservative, not wrong)
MIN_STRONG_HITS = 8           # pointers that must land for the pool alone to carry an anchor
CONTROL_RATIO = 3             # the base must beat every shifted control base by this factor
CONTROL_SHIFTS = (4, 8, 0x10, 0x20, 0x100, 0x200, 0x400, 0x800, 0x1000)
GROUP_LABEL = {"self_relocation": "자기재배치 스텁", "gfh": "GFH 로드 주소",
               "pool": "리터럴 풀 착지"}


def u32(data, off):
    if off < 0 or off + 4 > len(data):
        return None
    return int.from_bytes(data[off:off + 4], "little")


def hx(v):
    return None if v is None else "0x%x" % v


def parse_container(data):
    """Recognise a vendor container header and where its payload starts.

    Returns None when the first bytes match no known header. A header that IS
    recognised but whose payload offset cannot be established is returned with
    `confidence: unconfirmed` and `payload_offset: None` - the offset is never
    filled with the usual value.
    """
    magic = u32(data, 0)
    if magic == MTK_MAGIC:
        ev = ["매직 0x58881688 @0x0"]
        size = u32(data, 4)
        name = data[8:40].split(b"\0")[0].decode("ascii", "replace")
        ev.append("페이로드 크기 필드 %s @0x4, 이미지 이름 '%s'" % (hx(size), name))
        c = {"format": "mtk_image", "magic": hx(magic), "name": name,
             "payload_offset": None, "header_size_field": None,
             "payload_size_field": size, "confidence": "unconfirmed",
             "evidence": ev}
        if u32(data, 0x30) != MTK_EXT_MAGIC:
            ev.append("확장 헤더 매직 0x58891689 가 @0x30 에 없음 — 페이로드 시작 미확정")
            return c
        hsz = u32(data, 0x34)
        ev.append("확장 헤더 0x58891689 @0x30, 헤더 크기 필드 %s @0x34" % hx(hsz))
        ok = hsz is not None and 0x38 <= hsz <= min(0x10000, len(data)) and hsz % 4 == 0
        c["header_size_field"] = hsz
        if not ok:
            ev.append("헤더 크기 필드가 헤더 범위를 벗어남 — 페이로드 시작 미확정")
            return c
        if size is not None and hsz + size > len(data):
            ev.append("헤더 크기 + 페이로드 크기가 파일보다 큼 (잘린 파일?) — 페이로드 시작 미확정")
            return c
        c["payload_offset"] = hsz
        c["confidence"] = "derived"
        ev.append("페이로드 = 파일 @%s, %s 바이트" % (hx(hsz), hx(size)))
        return c
    if data[:len(EMMC_BOOT_ID)] == EMMC_BOOT_ID:
        ev = ["식별자 EMMC_BOOT @0x0"]
        hsz = u32(data, 0x10)
        c = {"format": "emmc_boot", "magic": "EMMC_BOOT", "name": "",
             "payload_offset": None, "header_size_field": hsz,
             "payload_size_field": None, "confidence": "unconfirmed",
             "evidence": ev}
        ev.append("헤더 크기 필드 %s @0x10" % hx(hsz))
        if hsz is None or not (0x20 <= hsz <= min(0x10000, len(data) - 4)) or hsz % 4:
            ev.append("헤더 크기 필드가 헤더 범위를 벗어남 — 페이로드 시작 미확정")
            return c
        tag = data[hsz:hsz + len(BRLYT_ID)]
        if tag == BRLYT_ID:
            ev.append("그 오프셋에 BRLYT 가 있음 — 페이로드 시작으로 확인")
        elif data[hsz:hsz + 4] == GFH_MAGIC:
            ev.append("그 오프셋에 GFH 가 있음 — 페이로드 시작으로 확인")
        else:
            ev.append("그 오프셋에서 BRLYT/GFH 를 확인하지 못함 — 페이로드 시작 미확정")
            return c
        c["payload_offset"] = hsz
        c["confidence"] = "derived"
        return c
    return None


def find_gfh(data, lo):
    """A GFH FILE_INFO block, located relative to the payload start.

    The preloader's GFH sits at payload+0x600, not at the payload start; taking
    its load address as the payload's base is off by exactly that distance, which
    is how a whole line of bypasses once got built on the wrong base.
    """
    end = min(len(data) - 0x38, lo + GFH_SCAN)
    pos = lo
    while True:
        i = data.find(GFH_MAGIC, pos, end + 4)
        if i < 0 or i > end:
            return None
        if i % 4 == 0 and data[i + 8:i + 8 + len(GFH_FILE_INFO)] == GFH_FILE_INFO:
            break
        pos = i + 1
    size = int.from_bytes(data[i + 4:i + 6], "little")
    if size < 0x38:
        return None
    g = {"file_offset": i, "payload_relative": i - lo, "size": size,
         "file_type": int.from_bytes(data[i + 0x18:i + 0x1A], "little"),
         "load_addr": u32(data, i + 0x1C), "file_len": u32(data, i + 0x20),
         "max_size": u32(data, i + 0x24), "content_offset": u32(data, i + 0x28),
         "sig_len": u32(data, i + 0x2C), "jump_offset": u32(data, i + 0x30)}
    return g


def _imm_rot(w):
    """ARM data-processing immediate: 8 bits rotated right by 2*rot."""
    imm8, rot = w & 0xFF, ((w >> 8) & 0xF) * 2
    if not rot:
        return imm8
    return ((imm8 >> rot) | (imm8 << (32 - rot))) & 0xFFFFFFFF


def _ldr_pc_target(i, w):
    """Byte offset of the literal an ARM `ldr rX, [pc, #imm]` at word i reads."""
    imm = w & 0xFFF
    return 4 * i + 8 + (imm if w & 0x00800000 else -imm)


def find_self_relocation_arm32(words):
    """The stub a self-relocating image starts with:

        mov rX, pc ; sub rX, rX, #imm ; ldr rY, [pc, #lit] ; cmp rX, rY ; beq run

    followed by a copy loop bounded by a second literal. Offsets are payload
    relative. `sub #imm` is where the stub thinks it sits inside the image, so it
    equals the stub's own offset plus 8 (pc reads 8 ahead) exactly when the
    link-address literal belongs to the PAYLOAD START and not to some other point.
    """
    out = []
    lim = min(len(words), SELF_RELOC_SCAN // 4)
    for i in range(lim - 5):
        a = words[i]
        if a & 0xFFFF0FFF != 0xE1A0000F:                   # mov rX, pc
            continue
        rx = (a >> 12) & 0xF
        sub = cmp_ = beq = None
        ldrs = []
        for j in range(i + 1, min(i + 9, len(words))):
            b = words[j]
            if (b & 0xFFF00000) == 0xE2400000 and (b >> 16) & 0xF == rx \
                    and (b >> 12) & 0xF == rx and sub is None:
                sub = j
            elif (b & 0xFF7F0000) == 0xE51F0000:
                ldrs.append(j)
            elif (b & 0xFFF0FFF0) == 0xE1500000 and cmp_ is None:
                cmp_ = j
            elif (b & 0xFF000000) == 0x0A000000 and cmp_ is not None:
                beq = j
                break
        if sub is None or cmp_ is None or beq is None:
            continue
        # The literal is the one the compare reads next to the mov'd register.
        c = words[cmp_]
        regs = {(c >> 16) & 0xF, c & 0xF}
        if rx not in regs:
            continue
        ry = (regs - {rx}).pop() if len(regs) == 2 else None
        ldr = next((j for j in ldrs if j < cmp_ and (words[j] >> 12) & 0xF == ry), None)
        if ldr is None:
            continue
        lit = _ldr_pc_target(ldr, words[ldr])
        if lit % 4 or not 0 <= lit // 4 < len(words):
            continue
        rec = {"at": 4 * i, "literal_at": lit, "base": words[lit // 4],
               "sub_imm": _imm_rot(words[sub]),
               "stub_offset_ok": _imm_rot(words[sub]) == 4 * i + 8,
               "copy_end": None, "copy_end_at": None, "post_entry": None}
        # The copy loop compares the destination pointer (rY) with a second literal.
        for j in range(beq + 1, min(beq + 13, len(words))):
            b = words[j]
            if (b & 0xFF7F0000) != 0xE51F0000:
                continue
            rz = (b >> 12) & 0xF
            for k in range(j + 1, min(j + 9, len(words))):
                d = words[k]
                if (d & 0xFFF0FFF0) == 0xE1500000 \
                        and (d >> 16) & 0xF == ry and d & 0xF == rz:
                    t = _ldr_pc_target(j, b)
                    if t % 4 == 0 and 0 <= t // 4 < len(words):
                        rec["copy_end_at"], rec["copy_end"] = t, words[t // 4]
                    break
            if rec["copy_end"] is not None:
                break
        # After the copy the stub jumps to the relocated image: ldr rW,[pc,..]; bx rW
        for j in range(beq + 1, min(beq + 20, len(words) - 1)):
            b, d = words[j], words[j + 1]
            if (b & 0xFF7F0000) == 0xE51F0000 and (d & 0xFFFFFFF0) == 0xE12FFF10 \
                    and d & 0xF == (b >> 12) & 0xF:
                t = _ldr_pc_target(j, b)
                if t % 4 == 0 and 0 <= t // 4 < len(words):
                    rec["post_entry"] = words[t // 4]
                break
        out.append(rec)
    return out


def payload_words(data, lo):
    """The payload's 32-bit words, without the 0x00/0xFF tail that pads a flash image."""
    p = data[lo:]
    used = (len(p.rstrip(b"\x00\xff")) + 3) // 4 * 4
    return struct.unpack_from("<%dI" % (min(used, len(p) // 4 * 4) // 4), p)


def _is_branch_arm(w):
    return (w & 0xFF000000) == 0xEA000000


def _is_ldr_pc(w):
    return (w & 0xFF7FF000) == 0xE51FF000


def find_vector_tables(words, base_off=0):
    """8-slot ARM exception vector tables: reset ... FIQ, each a `b` or `ldr pc`.

    The slot after data-abort (offset 0x14) is reserved and may hold anything, so
    seven slots decide. A jump table of `b` instructions can look the same, which
    is why only a table AT the payload start is treated as an entry.
    """
    n = len(words)
    out = []
    for i in range(0, n - 7, 8):                           # 32-byte aligned (VBAR)
        slots = words[i:i + 8]
        ok = True
        for k, w in enumerate(slots):
            if k == 5:
                continue
            if not (_is_branch_arm(w) or _is_ldr_pc(w)):
                ok = False
                break
            if _is_branch_arm(w):
                imm = w & 0x00FFFFFF
                if imm & 0x800000:
                    imm -= 1 << 24
                tgt = 4 * (i + k) + 8 + imm * 4
                if not 0 <= tgt < 4 * n:
                    ok = False
                    break
        if ok:
            out.append(base_off + 4 * i)
    return out


def _sysinsn(w):
    """CP15 transfer, or MSR/MRS of the CPSR: what a crt0 does before anything else."""
    if (w & 0x0F000F10) == 0x0E000F10 and (w >> 8) & 0xF == 0xF:
        return True
    return (w & 0x0FB0FFF0) == 0x0120F000 or (w & 0x0FB0F000) == 0x0320F000 \
        or (w & 0x0FBF0FFF) == 0x010F0000


def _crt0_at(words, i):
    """Is the code at word i a crt0: startup that sets up CP15/CPSR right away?

    Either the first words do it themselves, or the first word is a branch and
    the code it lands on does. Code that merely CONTAINS such instructions
    somewhere after garbage is not an entry.
    """
    if not 0 <= i < len(words):
        return False
    if _is_branch_arm(words[i]):
        imm = words[i] & 0x00FFFFFF
        if imm & 0x800000:
            imm -= 1 << 24
        j = i + 2 + imm
        return 0 <= j < len(words) and sum(1 for w in words[j:j + 64] if _sysinsn(w)) >= 2
    return sum(1 for w in words[i:i + 8] if _sysinsn(w)) >= 2


def find_entry_stubs_arm32(data, lo, words, gfh=None):
    """Where an AArch32 stage can be entered, strongest first.

    gfh_jump      the entry a GFH header declares (load address + jump offset)
    vector_table  an 8-slot table at the payload start
    crt0          a leading branch into startup code that sets up CP15/CPSR

    A table elsewhere in the image is listed but is NOT an entry: vector tables
    sit in the middle of images all the time.
    """
    stubs = []
    if gfh and gfh.get("jump_ok"):
        idx = (gfh["entry_file_offset"] - lo) // 4
        w = words[idx] if 0 <= idx < len(words) else None
        arm = w is not None and (_is_branch_arm(w) or _is_ldr_pc(w) or _crt0_at(words, idx))
        stubs.append({"at": gfh["entry_file_offset"], "kind": "gfh_jump",
                      "isa": "arm" if arm else None, "stage_start": lo,
                      "declared_pc": hx(gfh["declared_pc"]),
                      "skipped_zero_words": gfh["skipped_zero_words"]})
    tables = find_vector_tables(words, lo)
    for t in tables[:16]:                      # ascending, so one at the payload start is listed
        stubs.append({"at": t, "kind": "vector_table", "isa": "arm",
                      "stage_start": lo, "at_payload_start": t == lo})
    if words and lo not in tables and _crt0_at(words, 0):
        stubs.append({"at": lo, "kind": "crt0", "isa": "arm", "stage_start": lo})
    return stubs


def pick_entry(stubs, lo):
    for s in stubs:
        if s["kind"] == "gfh_jump":
            return s
    for s in stubs:
        if s["kind"] == "vector_table" and s["at"] == lo:
            return s
    for s in stubs:
        if s["kind"] == "crt0":
            return s
    return None


def pool_index(p):
    """Everything the literal-pool anchor needs, computed once per payload."""
    n = len(p) // 4 * 4
    words = struct.unpack_from("<%dI" % (n // 4), p)
    halves = struct.unpack_from("<%dH" % (n // 2), p)
    lits, jumps = set(), set()
    for i, a in enumerate(words):                          # ARM ldr rX, [pc, #imm]
        if a >> 28 == 0xF or (a & 0x0F7F0000) != 0x051F0000:
            continue
        t = _ldr_pc_target(i, a)
        if t % 4 or not 0 <= t <= n - 4:
            continue
        lits.add(t)
        rd = (a >> 12) & 0xF
        if rd == 15:
            jumps.add(t)
            continue
        for b in words[i + 1:i + 4]:                       # ... then bx/blx/mov pc, rX
            if ((b & 0x0FFFFFD0) == 0x012FFF10 and b & 0xF == rd) \
                    or ((b & 0x0FFFFFF0) == 0x01A0F000 and b & 0xF == rd):
                jumps.add(t)
                break
    for j, h in enumerate(halves):                         # Thumb ldr rd, [pc, #imm8*4]
        if h & 0xF800 != 0x4800:
            continue
        t = ((2 * j + 4) & ~3) + (h & 0xFF) * 4
        if t > n - 4:
            continue
        lits.add(t)
        rd = (h >> 8) & 7
        for h2 in halves[j + 1:j + 4]:
            if (h2 & 0xFF07) in (0x4700, 0x4780) and (h2 >> 3) & 0xF == rd:
                jumps.add(t)
                break
    a_pro = {4 * i for i, w in enumerate(words)
             if (w & 0xFFFF4000) == 0xE92D4000 or w in (0xE52DE004, 0xE1A0C00D)}
    # A Thumb prologue is not the second half of a 32-bit instruction: without
    # this, a `push` pattern hiding in the tail of an `ldr.w` made a base shifted
    # by a few bytes look as well supported as the real one.
    t_pro = {2 * j for j, h in enumerate(halves)
             if ((h & 0xFF00) == 0xB500
                 or (h == 0xE92D and j + 1 < len(halves) and halves[j + 1] & 0x4000))
             and not (j and halves[j - 1] >> 11 in (0x1D, 0x1E, 0x1F))}
    strs = {m.start() for m in re.finditer(
        rb"(?:(?<=\x00)|(?<!.))[\x20-\x7e\t\r\n]{4,}(?=\x00)", p[:n], re.S)
        if len(re.findall(rb"[A-Za-z]", m.group()[:96])) >= 3}
    return {"n": n, "words": words, "lits": sorted((t, words[t // 4]) for t in lits),
            "jumps": jumps, "a_pro": a_pro, "t_pro": t_pro, "strs": strs}


def landing(idx, base):
    """How many in-image literal pointers land on a string start or a function
    prologue if the payload is loaded at `base`. A Thumb pointer has bit 0 set."""
    inr = strings = prologues = jump_hits = 0
    for t, v in idx["lits"]:
        o = (v & ~1) - base
        if not 0 <= o < idx["n"]:
            continue
        inr += 1
        if (v - base) in idx["strs"]:
            strings += 1
            hit = True
        elif (v & 1 and o in idx["t_pro"]) or (not v & 1 and o in idx["a_pro"]):
            prologues += 1
            hit = True
        else:
            hit = False
        if hit and t in idx["jumps"]:
            jump_hits += 1
    return {"pointers": inr, "strings": strings, "prologues": prologues,
            "jump_literal_hits": jump_hits, "hits": strings + prologues}


def landing_verdict(idx, base, shifts):
    """Does the pool support `base`, measured against bases it should not support?

    The controls are the base moved by amounts a wrong derivation actually
    produces: small misalignments and the container's own structural offsets
    (header size, GFH offset). A real base keeps its landings; a shifted one
    loses them.

    Two ways to pass. `pool`: many pointers land and none of the controls comes
    close (this is what a bootloader full of string pointers looks like). `jump
    literal`: a literal the entry code JUMPS through lands on a function prologue
    and no control does the same - thin, because a preloader's pool is mostly
    peripheral addresses, but it is control-flow evidence rather than a pattern
    match, and the result says which of the two it was.
    """
    at = landing(idx, base)
    ctl = [landing(idx, b) for b in {base + s for d in shifts for s in (d, -d)}
           if b > 0 and b != base]
    worst = max((c["hits"] for c in ctl), default=0)
    worst_jump = max((c["jump_literal_hits"] for c in ctl), default=0)
    pool = at["hits"] >= MIN_STRONG_HITS and at["hits"] >= CONTROL_RATIO * worst
    jump = at["jump_literal_hits"] >= 1 and worst_jump == 0
    at.update({"control_max_hits": worst, "control_max_jump_literal_hits": worst_jump,
               "controls": len(ctl), "passed": pool or jump,
               "strength": "pool" if pool else ("jump_literal" if jump else None)})
    return at


def derive_base_arm32(data, lo, container, gfh):
    """Load base of an AArch32 payload, accepted only on two converging anchors.

    Declared anchors (the image says where it was linked):
      self_relocation_literal + copy_end_minus_header_size
          the stub's link-address literal, valid only if the copy-end literal
          minus it matches the header's payload size within COPY_END_TOLERANCE
          AND the stub's own `sub #imm` places the literal at the payload start
      gfh_load_addr
          the GFH load address minus the GFH's distance from the payload start
    Measured anchor:
      literal_pool_landing
          absolute pool pointers land on string starts / function prologues at
          that base and not at bases shifted by structural distances

    cross_checked needs two different anchors on one value and no valid anchor
    disagreeing. Anything less is `unconfirmed`, with every candidate listed.
    """
    p = data[lo:]
    used = len(p.rstrip(b"\x00\xff"))
    idx = pool_index(p[:used])
    declared = []                                         # candidates, valid or not

    for r in find_self_relocation_arm32(idx["words"]):
        psize = (container or {}).get("payload_size_field")
        diff = None
        if r["copy_end"] is not None and psize is not None:
            diff = abs((r["copy_end"] - r["base"]) - psize)
        why_not = []
        if not r["stub_offset_ok"]:
            why_not.append("스텁의 sub #imm(%s) 이 스텁 오프셋+8(%s) 와 다름 — 리터럴이 페이로드 시작의 링크 주소가 아님"
                           % (hx(r["sub_imm"]), hx(r["at"] + 8)))
        if r["copy_end"] is None:
            why_not.append("복사 끝 리터럴을 찾지 못함")
        elif psize is None:
            why_not.append("컨테이너 헤더의 페이로드 크기가 없어 복사 끝과 대조 불가")
        elif diff > COPY_END_TOLERANCE:
            why_not.append("복사 끝 − 링크 주소(%s) 가 헤더 페이로드 크기(%s) 와 %d B 차이 (허용 %d B)"
                           % (hx(r["copy_end"] - r["base"]), hx(psize), diff, COPY_END_TOLERANCE))
        declared.append({
            "group": "self_relocation", "base": r["base"], "valid": not why_not,
            "kinds": ["self_relocation_literal", "copy_end_minus_header_size"],
            "detail": {"kind": "self_relocation_literal", "stub_file_offset": lo + r["at"],
                       "literal_file_offset": lo + r["literal_at"], "value": hx(r["base"]),
                       "copy_end_file_offset": (lo + r["copy_end_at"]
                                                if r["copy_end_at"] is not None else None),
                       "copy_end": hx(r["copy_end"]), "header_payload_size": hx(psize),
                       "copy_end_minus_header_size": diff,
                       "post_relocation_entry": hx(r["post_entry"]),
                       "sub_imm": hx(r["sub_imm"]), "stub_offset_ok": r["stub_offset_ok"],
                       "rejected": why_not or None}})

    shifts = list(CONTROL_SHIFTS) + [lo]
    if gfh:
        why_not = []
        n = len(data) - lo
        bg = gfh["load_addr"] - gfh["payload_relative"] if gfh["load_addr"] else None
        if bg is None or bg < 0:
            why_not.append("GFH 로드 주소가 없거나 페이로드 시작 기준 환산이 음수")
        elif not (bg <= gfh["load_addr"] + gfh["jump_offset"] < bg + n):
            why_not.append("GFH 진입(로드 주소+점프 오프셋)이 페이로드 밖")
        if gfh["file_len"] is None or gfh["file_offset"] + gfh["file_len"] > len(data):
            why_not.append("GFH 파일 길이가 파일보다 큼")
        shifts.append(gfh["payload_relative"])
        declared.append({
            "group": "gfh", "base": bg if bg is not None and bg >= 0 else None,
            "valid": not why_not and bg is not None, "kinds": ["gfh_load_addr"],
            "detail": {"kind": "gfh_load_addr", "gfh_file_offset": gfh["file_offset"],
                       "gfh_payload_offset": gfh["payload_relative"],
                       "load_addr": hx(gfh["load_addr"]),
                       "value": hx(bg) if bg is not None and bg >= 0 else None,
                       "rejected": why_not or None}})

    # Measure the pool at every distinct declared base, valid or not.
    support = {}
    for c in declared:
        if c["base"] is None:
            continue
        s = support.setdefault(c["base"], {"groups": {}, "landing": None})
        if c["valid"]:
            s["groups"][c["group"]] = c
    for b, s in support.items():
        s["landing"] = landing_verdict(idx, b, shifts)
        if s["landing"]["passed"]:
            detail = {k: v for k, v in s["landing"].items() if k != "passed"}
            s["groups"]["pool"] = {"group": "pool", "kinds": ["literal_pool_landing"],
                                   "detail": dict(kind="literal_pool_landing", value=hx(b), **detail)}

    ranked = sorted(support.items(), key=lambda kv: -len(kv[1]["groups"]))
    cands = [{"base": hx(b), "anchors": [k for g in s["groups"].values() for k in g["kinds"]],
              "groups": len(s["groups"]), "landing": s["landing"]} for b, s in ranked]
    rejected = [c["detail"] for c in declared if not c["valid"]]
    winner = None
    why = None
    anchors = []
    if not declared:
        why = ("자기재배치 스텁도 GFH 도 찾지 못해 후보를 낼 선언된 앵커가 없습니다 — "
               "리터럴 풀만으로는 로드베이스를 제안하지 않습니다")
    elif ranked and len(ranked[0][1]["groups"]) >= 2:
        top = ranked[0][1]
        tied = [b for b, s in ranked[1:] if len(s["groups"]) >= 2]
        valid_bases = {c["base"] for c in declared if c["valid"]}
        if tied:
            why = "서로 다른 값에 앵커 두 개 이상이 수렴 — 후보: " + ", ".join(
                hx(b) for b in [ranked[0][0]] + tied)
        elif valid_bases - {ranked[0][0]}:
            why = ("앵커 둘이 %s 에 수렴하지만 유효한 다른 앵커가 %s 를 가리킴 — 불일치"
                   % (hx(ranked[0][0]), ", ".join(hx(b) for b in sorted(valid_bases - {ranked[0][0]}))))
        else:
            winner = ranked[0][0]
            anchors = [g["detail"] for g in top["groups"].values()]
    if winner is None and why is None:
        why = ("독립된 앵커가 한 값에 수렴하지 않음 (최대 %d 개) — 확정하지 않습니다"
               % (len(ranked[0][1]["groups"]) if ranked else 0))
    if winner is None:
        return {"load_base": None, "confidence": "unconfirmed", "anchors": [],
                "candidates": cands, "rejected_anchors": rejected, "why": why}
    kinds = [k for g in support[winner]["groups"].values() for k in g["kinds"]]
    return {"load_base": winner, "load_base_hex": hx(winner), "confidence": "cross_checked",
            "anchor_kinds": kinds, "anchors": anchors, "candidates": cands,
            "rejected_anchors": rejected,
            "why": "독립된 앵커 %d 개가 %s 에 수렴: %s"
                   % (len(support[winner]["groups"]), hx(winner),
                      ", ".join("%s(%s)" % (GROUP_LABEL[g], "+".join(c["kinds"]))
                                for g, c in support[winner]["groups"].items()))}


def entry_from_gfh(data, lo, gfh):
    """GFH-declared entry: load address + jump offset, then past leading zero words.

    An all-zero word executes as `andeq r0, r0, r0` - a no-op - so entering after
    it changes nothing but the PC. The declared address is kept next to the entry.
    """
    if not gfh["load_addr"] or gfh["jump_offset"] is None:
        gfh["jump_ok"] = False
        return
    declared = gfh["load_addr"] + gfh["jump_offset"]
    off = gfh["file_offset"] + gfh["jump_offset"]
    skipped = 0
    while skipped < 4 and u32(data, off) == 0:
        off += 4
        skipped += 1
    gfh.update({"jump_ok": u32(data, off) is not None and off < len(data),
                "declared_pc": declared, "entry_file_offset": off,
                "skipped_zero_words": skipped})


def entry_disasm(data, off, pc, count=4):
    """The instructions at the entry up to its first branch, for a human reading
    the map (what follows a branch is usually literal data). Best effort."""
    try:
        import capstone
    except ImportError:
        return []
    md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)
    out = []
    for i in md.disasm(data[off:off + 4 * count], pc):
        out.append("%s %s" % (i.mnemonic, i.op_str))
        if i.mnemonic in ("b", "bl", "bx", "blx") or \
                (i.mnemonic == "ldr" and i.op_str.startswith("pc,")):
            break
    return out


def label_region(strs, hints):
    """Name a region from what it says about itself. Unknown stays unknown."""
    joined = " ".join(s for _, s in strs[:600]).lower()
    scores = {}
    for name, keys in hints.items():
        hit = sum(1 for k in keys if k.lower() in joined)
        if hit:
            scores[name] = hit
    if not scores:
        return None, {}
    top = max(scores.items(), key=lambda kv: kv[1])
    return top[0], scores


DEFAULT_HINTS = {
    "first_stage": ["loading", "rx done", "header fail", "preloader", "bl1"],
    "dram_init":   ["dmc", "dram", "mif", "lpddr", "ddr", "training"],
    "bootloader":  ["autoboot", "following commands", "s-boot", "little kernel",
                    "fastboot", "board_power_off", "boot linux"],
    "secure_os":   ["teegris", "sec_os", "trusty", "tzsw"],
    "el3_monitor": ["unhandled kernel synchronous exception", "esr_el1",
                    "runtime service", "smc_handler"],
    "crypto":      ["cryptomanager", "crypto_operation", "rpmb"],
    "power_fw":    ["enter_wfi", "nvic", "acpm", "dvfs"],
}


def load_profile_hints(profile):
    """Profile hints override the defaults; a missing profile is not an error."""
    if not profile:
        return DEFAULT_HINTS
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(os.path.dirname(here), "profiles", f"{profile}.yaml")
    if not os.path.exists(path):
        return DEFAULT_HINTS
    # Deliberately not a YAML parse: only `stage_hints:` is read, so the script
    # keeps working on a machine without PyYAML installed.
    hints = dict(DEFAULT_HINTS)
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return hints
    block = re.search(r"^\s*stage_hints:\s*$(.*?)(?=^\S|\Z)", text,
                      re.M | re.S)
    if not block:
        return hints
    for line in block.group(1).splitlines():
        # Digits belong in a key: el3_monitor, bl2, el2_hyp. Without them the
        # line is skipped in silence and the default quietly wins.
        m = re.match(r"\s+([a-z0-9_]+):\s*\[(.*)\]\s*$", line)
        if m:
            keys = [k.strip().strip('"\'') for k in m.group(2).split(",")]
            hints[m.group(1)] = [k for k in keys if k]
    return hints


def split_at_encryption(lo, hi, runs, grid):
    """A stage that begins in plaintext and continues into ciphertext is TWO
    stages, not one encrypted stage.

    The previous rule marked the whole stub-to-stub span `encrypted` when more
    than 60% of its bytes were high-entropy. On Exynos 9820 that discarded BL1:
    20 KB of plaintext with the entry stub at 0x10, sitting in front of EPBL's
    38 KB of ciphertext. 38912/59392 = 65.5%, so the executable head was skipped
    with the tail and the reset PC moved forward to the bootloader - which is
    exactly the "start at BL33" shortcut this flow exists to avoid. Exynos 2400
    has the same shape (32 KB plaintext head).

    The entry stub sits at `lo`, so the head is the part that can actually be
    entered. The tail starts on ciphertext and cannot be, whatever its ratio.
    """
    enc = [r for r in runs if r["label"] == "enc"
           and r["end"] > lo and r["start"] < hi]
    if not enc:
        return [(lo, hi, "exec")]

    cut = max(min(r["start"] for r in enc), lo)
    if cut - lo < grid:
        # No plaintext head worth entering: the stage begins in ciphertext.
        return [(lo, hi, "encrypted")]
    if hi - cut < grid:
        # Ciphertext is a trailing fragment (packed data, keys), not a stage.
        return [(lo, hi, "exec")]
    return [(lo, cut, "exec"), (cut, hi, "encrypted")]


def encrypted_bytes_in(runs, lo, hi):
    return sum(min(r["end"], hi) - max(r["start"], lo)
               for r in runs if r["label"] == "enc" and r["end"] > lo and r["start"] < hi)


def v2_fields(stage, lo, arch, origin, partition, container, entered_by):
    """Schema v2 additions. Every v1 field is left exactly as it was.

    entry_pc is absolute and computed the way verify.py checks it:
    base + (entry offset - start of the stage's file range).
    """
    base = stage.get("base") or {}
    lb, off = base.get("load_base"), stage.get("entry_pc_file_offset")
    runnable = stage["state"] == "exec" and lb is not None and off is not None
    derived = base.get("confidence") == "derived"
    stage.update({
        "arch": arch,
        "origin": origin,
        "entered_by": entered_by,
        "entry_pc": hx(lb + (off - lo)) if runnable else None,
        "anchors": ["bss_zero_padding"] if derived else [],
        "confidence": "derived" if derived else "unconfirmed",
        "container": container,
    })
    if partition:
        stage["partition"] = partition


def build_map_arm32(data, runs, hints, grid, origin, partition):
    container = parse_container(data)
    notes = []
    if container is None:
        container = {"format": "unknown", "magic": hx(u32(data, 0)), "name": "",
                     "payload_offset": None, "header_size_field": None,
                     "payload_size_field": None, "confidence": "unconfirmed",
                     "evidence": ["알려진 컨테이너 헤더(MTK 0x58881688, EMMC_BOOT)와 일치하지 않음"]}
    lo = container["payload_offset"]
    if lo is None:
        lo = 0
        notes.append("컨테이너 페이로드 시작을 확정하지 못해 파일 선두에서 도출했습니다 — "
                     "container.confidence=unconfirmed")

    words = payload_words(data, lo)
    gfh = find_gfh(data, lo)
    container["gfh"] = None
    if gfh:
        entry_from_gfh(data, lo, gfh)
        container["gfh"] = {"file_offset": gfh["file_offset"],
                            "payload_offset": gfh["payload_relative"],
                            "load_addr": hx(gfh["load_addr"]), "file_len": hx(gfh["file_len"]),
                            "jump_offset": hx(gfh["jump_offset"])}
        container["evidence"].append(
            "GFH FILE_INFO @%s (페이로드+%s), 로드 주소 %s, 점프 오프셋 %s"
            % (hx(gfh["file_offset"]), hx(gfh["payload_relative"]),
               hx(gfh["load_addr"]), hx(gfh["jump_offset"])))
    stubs = find_entry_stubs_arm32(data, lo, words, gfh)
    entry = pick_entry(stubs, lo)

    result = {
        "schema_version": 2,
        "image_size": len(data),
        "arch": "arm32",
        "arch_supported": entry is not None,
        "container": container,
        "grid": grid,
        "entropy_runs": [r for r in runs if r["end"] - r["start"] >= grid],
        "encrypted_total": sum(r["end"] - r["start"] for r in runs if r["label"] == "enc"),
        "entry_stubs": stubs,
        "stages": [],
        "notes": notes,
    }
    if entry is None:
        result["notes"].append(
            "arch=arm32: 진입 시그니처를 찾지 못했습니다 (GFH 진입, 페이로드 선두의 벡터 테이블, crt0). "
            "스테이지를 도출하지 못했으므로 BLOCKED_ARCH 로 정지하십시오 — '스테이지 없음'이 아닙니다.")
        return result

    base = derive_base_arm32(data, lo, container, gfh)
    runnable = base["confidence"] == "cross_checked"
    off = entry["at"]
    strs = strings_in(data, lo, len(data))
    name, scores = label_region(strs, hints)
    if name and scores.get(name, 0) < 2:
        name = None            # one keyword hit in Thumb code is noise, not an identification
    if container.get("name"):
        # The container header names its own image; that is parsed, not inferred.
        name = re.sub(r"[^A-Za-z0-9_]", "_", container["name"]) or name
    stage = {
        "index": 0,
        "name": name or "stage0",
        "identified": bool(name),
        "file_range": [lo, len(data)],
        "size": len(data) - lo,
        # `unconfirmed` is not `exec`: every consumer that lists runnable stages
        # filters on state == "exec", so a base nobody could cross-check never
        # reaches a machine.
        "state": "exec" if runnable else "unconfirmed",
        "entry_pc_file_offset": off,
        "entry_kind": entry["kind"],
        "entry_isa": entry.get("isa"),
        "vbar_writes": [],
        "encrypted_bytes": encrypted_bytes_in(runs, lo, len(data)),
        "base": base,
        "evidence": {
            "label_scores": scores,
            "sample_strings": [s for _, s in strs[:6]],
            "entry_disasm": (entry_disasm(data, off, base["load_base"] + off - lo)
                             if runnable else []),
        },
    }
    v2_fields(stage, lo, "aarch32", origin, partition, container,
              "reset" if origin == "container" else "branch")
    # v2_fields reports the AArch64 anchors; this stage's come from the base.
    stage["anchors"] = base.get("anchor_kinds", [])
    stage["confidence"] = base["confidence"]
    result["stages"].append(stage)
    if not runnable:
        result["notes"].append(
            "stage0: 로드베이스 미확정 — %s. state=unconfirmed 로 두며 실행 가능 스테이지에 "
            "넣지 않습니다 (후보는 base.candidates)." % base["why"])
    if stage["encrypted_bytes"] * 2 > stage["size"]:
        result["notes"].append(
            "stage0: 페이로드의 절반 이상이 고엔트로피입니다 (암호화 또는 압축). "
            "진입은 평문 머리에서 찾았으나 나머지가 실행 가능한지는 확인하지 못했습니다.")
    return result


def build_map(data, arch, hints, grid, origin="container", partition=None):
    runs = entropy_runs(data, grid)
    if arch == "arm32":
        return build_map_arm32(data, runs, hints, grid, origin, partition)
    container = parse_container(data)
    stubs = find_entry_stubs_arm64(data)

    stages = []
    bounds = sorted({s["stage_start"] for s in stubs})
    # A stage runs from its stub to the next stub; the tail belongs to the
    # last one. Regions before the first stub are stage 0 (the entry stage,
    # whose stub is the image header rather than a CurrentEL test).
    edges = [0] + bounds + [len(data)]
    for span_lo, span_hi in zip(edges, edges[1:]):
        if span_hi - span_lo < grid:
            continue
        for lo, hi, state in split_at_encryption(span_lo, span_hi, runs, grid):
            if hi - lo < grid:
                continue
            strs = strings_in(data, lo, hi)
            name, scores = label_region(strs, hints)
            enc_bytes = encrypted_bytes_in(runs, lo, hi)
            entry = next((s for s in stubs if s["stage_start"] == lo), None)
            i = len(stages)
            stage = {
                "index": i,
                "name": name or f"stage{i}",
                "identified": bool(name),
                "file_range": [lo, hi],
                "size": hi - lo,
                "state": state,
                "entry_pc_file_offset": entry["stage_start"] if entry else None,
                "vbar_writes": entry["vbar_writes"] if entry else [],
                "encrypted_bytes": enc_bytes,
                "evidence": {
                    "label_scores": scores,
                    "sample_strings": [s for _, s in strs[:6]],
                },
            }
            if state == "exec":
                stage.update({"base": derive_base(data, lo, hi)})
            v2_fields(stage, lo, "aarch64", origin, partition, container,
                      "reset" if i == 0 and origin == "container" else "branch")
            stages.append(stage)

    notes = []
    if container:
        notes.append("컨테이너 헤더 %s 인식 (페이로드 @%s). arm64 스테이지 범위는 이전과 같이 "
                     "파일 선두부터입니다." % (container["magic"], hx(container["payload_offset"])))
    return {
        "schema_version": 2,
        "image_size": len(data),
        "arch": arch,
        "arch_supported": True,
        "container": container,
        "grid": grid,
        "entropy_runs": [r for r in runs if r["end"] - r["start"] >= grid],
        "encrypted_total": sum(r["end"] - r["start"] for r in runs if r["label"] == "enc"),
        "entry_stubs": stubs,
        "stages": stages,
        "notes": notes,
    }


# ---- architecture detection (--detect-arch) ---------------------------------
# `--arch` is the INPUT of every derivation above, so something has to decide it
# before the first map is drawn, and it must not be a default: a MediaTek first
# stage is AArch32, and reading it as AArch64 yields a plausible-looking map of
# nothing. Detection reads the image and says which evidence it used. Evidence
# comes in classes, and a class counts once however many lines it produced:
#
#   header        the entry a GFH header declares decodes as an ARM-state instruction
#   entry_code    code at the entry has the shape of one ISA's startup: an 8-slot ARM
#                 vector table or a CP15/CPSR crt0 at the payload start, or the crt0 a
#                 GFH-declared entry branches to (AArch32); `mrs currentel` with a
#                 `msr vbar_el*` beside it (AArch64). For a GFH image `header` and
#                 `entry_code` are two facts about two places (the declared entry word,
#                 the code it branches to), not one fact counted twice
#   code_anchor   an AArch32 self-relocation stub (mov rX,pc / sub / ldr / cmp / beq)
#   pattern       one ISA's function prologue/return encodings occur far more often
#                 than they do in random bytes
#
# The container header itself says nothing about the ISA (an MTK header fronts both
# AArch32 and AArch64 images), so it only tells where the payload starts. The
# matchers are the ones the maps use; nothing here re-implements them.
DETECT_SCAN_MAX = 16 << 20       # bytes of the image the scans look at
PATTERN_MIN_HITS = 16            # a pattern class needs at least this many hits ...
PATTERN_MARGIN = 16              # ... and this many times what random bytes would give
                                 # (both fitted: checked on two real AArch32 images, synthetic images and
                                 # random bytes; no AArch64 bootloader was available - revisit with one)

# (mask, accepted values) per instruction family. The chance of a random word matching is
# derived from the masks (len(values) * 2**-fixed_bits), not entered as a number.
A64_PATTERNS = ((0xFFC07FFF, (0xA9807BFD, 0xA9007BFD, 0xA8C07BFD, 0xA9407BFD)),   # stp/ldp x29,x30,[sp..]
                (0xFFFFFC1F, (0xD65F0000, 0xD63F0000)))                           # ret xN / blr xN
A32_PATTERNS = ((0xFFFF4000, (0xE92D4000,)),                                      # push {..,lr}
                (0xFFFF8000, (0xE8BD8000,)),                                      # pop {..,pc}
                (0xFFFFFFFF, (0xE12FFF1E, 0xE49DF004, 0xE1A0F00E)))               # bx lr / pop {pc} / mov pc,lr


def _word_hits(words, patterns):
    hits = 0
    for w in words:
        for mask, vals in patterns:
            if (w & mask) in vals:
                hits += 1
                break
    return hits


def _word_chance(patterns):
    return sum(len(vals) * 2.0 ** -bin(mask).count("1") for mask, vals in patterns)


def pattern_stats(data, lo, words):
    """How often each ISA's own prologue/return encodings occur, against what random
    bytes would give. `present` needs both an absolute floor and a margin over chance, so
    ciphertext and compressed data (which are random bytes) never read as code.

    Word-sized encodings only. Thumb is not counted: a 16-bit `push {..,lr}` is 1 halfword
    in 256, and a push..pop pair measured on a real Thumb-2 bootloader came out within a
    factor of two of random halfwords, so it cannot tell code from noise."""
    def entry(hits, expected):
        return {"hits": hits, "expected": round(expected, 2),
                "present": hits >= max(PATTERN_MIN_HITS, PATTERN_MARGIN * expected)}
    return {"words": len(words),
            "a64": entry(_word_hits(words, A64_PATTERNS), len(words) * _word_chance(A64_PATTERNS)),
            "a32": entry(_word_hits(words, A32_PATTERNS), len(words) * _word_chance(A32_PATTERNS))}


def detect_arch(data):
    """The ISA the image's first stage is entered in: arm32, arm64 or unknown, and why.

    A structural signature (a class other than `pattern`) is required to name an
    architecture; frequency counts alone only cross-check one or lean in the basis.
    unknown is a legitimate answer and is what an image with no signature, a
    signature of each ISA, or a signature the byte statistics decisively contradict gets.
    """
    basis = []

    def result(arch, sig, conf):
        return {"arch": arch, "entry_signature": sig, "basis": basis, "confidence": conf}

    if len(data) < 32:
        basis.append("파일이 %d 바이트뿐이라 아키텍처를 판단할 근거가 없습니다" % len(data))
        return result("unknown", "none", "unconfirmed")

    container = parse_container(data)
    lo = 0
    if container is None:
        basis.append("알려진 컨테이너 헤더(MTK 0x58881688, EMMC_BOOT)와 일치하지 않음 - 파일 선두를 페이로드 시작으로 봄")
    else:
        if container["payload_offset"] is not None:
            lo = container["payload_offset"]
        basis.append("컨테이너 %s (매직 %s), 페이로드 시작 %s [%s] - 컨테이너 헤더는 아키텍처를 말하지 않아 "
                     "근거로 세지 않고 페이로드 시작을 정하는 데만 씀"
                     % (container["format"], container["magic"],
                        hx(container["payload_offset"]) or "미확정", container["confidence"]))
        if container["payload_offset"] is None:
            basis.append("페이로드 시작을 확정하지 못해 파일 선두에서 찾음")

    words = payload_words(data[:lo + DETECT_SCAN_MAX], lo)
    if len(data) > lo + DETECT_SCAN_MAX:
        basis.append("이미지가 %d MiB 를 넘어 앞 %d MiB 만 검사함" % (DETECT_SCAN_MAX >> 20, DETECT_SCAN_MAX >> 20))

    # AArch32 signatures: (class, entry_signature, evidence line)
    sig32 = []
    gfh = find_gfh(data, lo)
    if gfh:
        entry_from_gfh(data, lo, gfh)
    stubs = find_entry_stubs_arm32(data, lo, words, gfh)
    for s in stubs:
        if s["kind"] == "gfh_jump":
            if s["isa"] == "arm":
                sig32.append(("header", "gfh",
                              "GFH FILE_INFO @%s 가 선언한 진입 %s (파일 @%s)의 워드가 ARM 상태 분기/ldr pc/crt0 로 해독됨"
                              % (hx(gfh["file_offset"]), s["declared_pc"], hx(s["at"]))))
                if _crt0_at(words, (s["at"] - lo) // 4):
                    sig32.append(("entry_code", "gfh",
                                  "그 진입이 닿는 코드가 CP15/CPSR 를 바로 설정함 (crt0)"))
            else:
                basis.append("GFH @%s 가 진입 %s 을 선언하나 그 워드가 ARM 상태 명령으로 해독되지 않음 - 근거로 세지 않음"
                             % (hx(gfh["file_offset"]), s["declared_pc"]))
        elif s["kind"] == "vector_table" and s.get("at_payload_start"):
            sig32.append(("entry_code", "vector_table",
                          "페이로드 선두 @%s 에 8 슬롯 ARM 벡터 테이블 (일곱 슬롯이 b / ldr pc, 분기 대상이 이미지 안)" % hx(s["at"])))
        elif s["kind"] == "crt0":
            sig32.append(("entry_code", "crt0",
                          "페이로드 선두 @%s 가 CP15/CPSR 를 바로 설정하는 crt0 형태" % hx(s["at"])))
    elsewhere = [s["at"] for s in stubs if s["kind"] == "vector_table" and not s.get("at_payload_start")]
    if elsewhere:
        basis.append("벡터 테이블 형태가 페이로드 선두가 아닌 곳(@%s%s)에도 있음 - 진입 근거로 세지 않음"
                     % (hx(elsewhere[0]), " 외 %d곳" % (len(elsewhere) - 1) if len(elsewhere) > 1 else ""))
    reloc = find_self_relocation_arm32(words)
    if reloc:
        sig32.append(("code_anchor", "stub:self_relocation",
                      "자기재배치 스텁 @%s (mov rX,pc / sub / ldr / cmp / beq, 링크 주소 리터럴 %s)"
                      % (hx(lo + reloc[0]["at"]), hx(reloc[0]["base"]))))

    # AArch64 signature
    sig64 = []
    stubs64 = find_entry_stubs_arm64(data[:DETECT_SCAN_MAX])
    if stubs64:
        s = stubs64[0]
        sig64.append(("entry_code", "stub:currentel_vbar_" + "_".join(s["vbar_writes"]),
                      "AArch64 진입 스텁 @%s: mrs currentel 옆에 msr vbar_%s%s%s"
                      % (hx(s["at"]), "/".join(s["vbar_writes"]),
                         ", 앞에 adr" if s["adr_before"] else "",
                         " (스텁 %d곳)" % len(stubs64) if len(stubs64) > 1 else "")))

    st = pattern_stats(data, lo, words)
    a32_present, a64_present = st["a32"]["present"], st["a64"]["present"]
    basis.append("명령 패턴 빈도 (페이로드 %d 워드, 괄호는 무작위 바이트의 기대값): AArch64 프레임 stp/ldp·ret/blr %d (%s), "
                 "AArch32 ARM 상태 push/pop/bx lr %d (%s) - Thumb 은 세지 않음"
                 % (st["words"], st["a64"]["hits"], st["a64"]["expected"], st["a32"]["hits"], st["a32"]["expected"]))

    def unknown(why):
        basis.append("판정: unknown - " + why)
        return result("unknown", "none", "unconfirmed")

    if sig32 and sig64:
        basis.append("AArch32 시그니처: " + "; ".join(l for _, _, l in sig32))
        basis.append("AArch64 시그니처: " + sig64[0][2])
        return unknown("AArch32 와 AArch64 진입 시그니처가 함께 있음 (두 ISA 가 섞인 이미지이거나 한쪽이 오탐). "
                       "이미지별로 --arch 를 정해 확인해야 함")
    if not sig32 and not sig64:
        if a32_present != a64_present:
            basis.append("통계만으로는 아키텍처를 단정하지 않음 (%s 패턴이 우세). 진입 시그니처가 없음"
                         % ("AArch32" if a32_present else "AArch64"))
        elif a32_present:
            basis.append("AArch32 와 AArch64 패턴이 모두 우세 - 통계로도 가를 수 없음")
        sample = data[lo:lo + (1 << 20)]
        ent = entropy(sample) if len(sample) >= 4096 else 0.0
        if ent >= ENC_MIN:
            basis.append("페이로드 앞 1 MiB 의 엔트로피 %.2f (기준 %.1f 이상) - 암호화 또는 압축으로 보여 명령 패턴이 의미 없음"
                         % (ent, ENC_MIN))
        return unknown("진입 시그니처(GFH 진입, 벡터 테이블, crt0, 자기재배치 스텁, AArch64 CurrentEL/VBAR 스텁)를 하나도 찾지 못함")

    arch, sigs, own, other = (("arm32", sig32, a32_present, a64_present) if sig32
                              else ("arm64", sig64, a64_present, a32_present))
    for _, _, line in sigs:
        basis.append(line)
    if other and not own:
        return unknown("%s 시그니처가 있으나 명령 패턴 통계는 반대 ISA 쪽이 우세함 (시그니처가 오탐이거나 이미지 대부분이 다른 ISA)"
                       % ("AArch32" if arch == "arm32" else "AArch64"))
    classes = {c for c, _, _ in sigs}
    if own and not other:
        classes.add("pattern")
    elif own and other:
        basis.append("양쪽 ISA 의 패턴이 모두 우세 - 통계는 근거로 세지 않음 (혼합 이미지 가능)")
    # strongest signature names the entry: header, then entry code, then the code anchor
    order = {"header": 0, "entry_code": 1, "code_anchor": 2}
    sig = sorted(sigs, key=lambda x: order[x[0]])[0][1]
    conf = "cross_checked" if len(classes) >= 2 else "derived"
    basis.append("판정: %s - 독립 근거 %d종 (%s)" % (arch, len(classes), ", ".join(sorted(classes))))
    return result(arch, sig, conf)


def merge_maps(paths):
    """(merged_map, error): the stages of several per-image maps, in the order given.

    No stage is changed except `index` (renumbered from 0 across the whole chain) and
    `image` (the image its file_range points into, added when the stage has none)."""
    maps = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError) as exc:
            return None, "%s: 읽을 수 없습니다 (%s)" % (path, exc)
        if not isinstance(data, dict) or not isinstance(data.get("stages"), list):
            return None, "%s: 스테이지 지도가 아닙니다 (stages 목록이 없음)" % path
        maps.append(data)
    if not maps:
        return None, "합칠 지도가 없습니다"
    first = maps[0]
    stages, images, notes = [], [], []
    for data in maps:
        image = data.get("image")
        images.append({"image": image, "arch": data.get("arch"),
                       "image_size": data.get("image_size"),
                       "stages": len(data["stages"])})
        for st in data["stages"]:
            st = dict(st)
            st["index"] = len(stages)
            if image and not st.get("image"):
                st["image"] = image
            stages.append(st)
        notes += list(data.get("notes") or [])
    merged = {k: v for k, v in first.items() if k not in ("stages", "notes")}
    merged.update({
        "schema_version": 2,
        "arch": first.get("arch"),
        "arch_supported": all(d.get("arch_supported", True) for d in maps),
        "stages": stages,
        "notes": notes,
        "images": images,
        "merged_from": [os.path.abspath(p) for p in paths],
    })
    merged["encrypted_total"] = sum(d.get("encrypted_total", 0) for d in maps)
    return merged, ""


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", nargs="?", default=None,
                    help="the image to map (not used with --merge)")
    ap.add_argument("--merge", nargs="+", metavar="MAP", default=None,
                    help="combine per-image stage maps, in chain order, instead of mapping an image")
    ap.add_argument("--arch", default="arm64", choices=("arm64", "arm32"))
    ap.add_argument("--detect-arch", metavar="PATH", default=None,
                    help="이미지(또는 컨테이너)가 어느 ISA 로 진입하는지 판정해 JSON 한 개를 출력하고 끝낸다. "
                         "arch 는 arm32 | arm64 | unknown, 근거는 basis")
    ap.add_argument("--profile", default=None, help="profiles/<name>.yaml 의 stage_hints 사용")
    ap.add_argument("--origin", default="container",
                    choices=("container", "medium", "handoff"),
                    help="이 이미지의 스테이지가 어떻게 적재되는가. 컨테이너 안(기본), "
                         "이전 스테이지가 매체에서 적재, 이전 스테이지 코드가 진입을 결정")
    ap.add_argument("--partition", default=None,
                    help="origin=medium 일 때 매체 파티션 이름 (기록용)")
    ap.add_argument("--out", default=None, help="기본: <image 디렉터리>/stage_map.json")
    ap.add_argument("--grid", default="0x800", help="엔트로피 격자 크기 (기본 0x800)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.detect_arch:
        if args.image or args.merge:
            print("stage_map: --detect-arch 는 이미지나 --merge 와 함께 쓸 수 없습니다", file=sys.stderr)
            return 64
        try:
            with open(args.detect_arch, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            print("stage_map: %s: 읽을 수 없습니다 (%s)" % (args.detect_arch, exc), file=sys.stderr)
            return 2
        out = detect_arch(raw)
        try:
            sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
        except UnicodeEncodeError:                 # a locale that cannot print Korean: escape instead
            sys.stdout.write(json.dumps(out) + "\n")
        return 0
    if args.merge:
        if args.image:
            # `--merge a.json b.json` swallows the file names, but a stray positional
            # (an image) next to it is a mistake worth saying out loud.
            ap.error("--merge 와 이미지를 함께 줄 수 없습니다")
        merged, why = merge_maps(args.merge)
        if merged is None:
            print("stage_map: " + why, file=sys.stderr)
            return 2
        out = args.out or os.path.join(os.path.dirname(os.path.abspath(args.merge[0])),
                                       "stage_map.json")
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(merged, fh, ensure_ascii=False, indent=2)
        if not args.quiet:
            print(f"stage_map: {out}  (합침 {len(args.merge)}개, 스테이지 {len(merged['stages'])}개)")
            for s_ in merged["stages"]:
                print(f"  [{s_['index']}] {s_.get('name')}  {s_.get('state')}  "
                      f"{s_.get('arch')}/{s_.get('origin')}  entry_pc={s_.get('entry_pc') or '-'}")
        return 0 if merged["arch_supported"] else 3
    if not args.image:
        ap.error("이미지(또는 --merge)가 필요합니다")

    with open(args.image, "rb") as fh:
        data = fh.read()

    grid = int(args.grid, 0)
    result = build_map(data, args.arch, load_profile_hints(args.profile), grid,
                       origin=args.origin, partition=args.partition)
    result["image"] = os.path.abspath(args.image)

    out = args.out or os.path.join(os.path.dirname(os.path.abspath(args.image)),
                                   "stage_map.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)

    if not args.quiet:
        print(f"stage_map: {out}")
        print(f"  arch={result['arch']}  이미지 {result['image_size']:,} B  "
              f"암호화 {result['encrypted_total']:,} B")
        for s in result["stages"]:
            base = s.get("base") or {}
            b = base.get("load_base")
            conf = base.get("confidence", "-")
            print(f"  [{s['index']}] {s['name']:<14} {s['state']:<11} "
                  f"0x{s['file_range'][0]:06x}-0x{s['file_range'][1]:06x} "
                  f"base={'0x%08x' % b if b is not None else '미도출':<12} ({conf})"
                  f"  entry_pc={s.get('entry_pc') or '-'}")
            for c in base.get("candidates") or []:
                if base.get("load_base") is None:
                    print(f"        후보 {c['base']}  앵커 {c['anchors'] or '없음'}")
        for n in result["notes"]:
            print(f"  ! {n}")

    return 0 if result["arch_supported"] else 3


if __name__ == "__main__":
    sys.exit(main())
