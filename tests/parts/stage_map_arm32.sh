#!/usr/bin/env bash
# tests/parts/stage_map_arm32.sh - 스테이지 지도: arm32 도출, 스키마 v2, arm64 하위 호환,
# extract_boot_assets.sh 폴백 헤더 파서.
#
# 합성 입력만으로 돈다. 실제 이미지는 SBOOT_FIXTURES 가 가리키는 폴더(lk-verified.img,
# preloader.img, boot_head.img)가 있을 때에만 추가로 확인한다 - 저장소는 그 파일들에 의존하지 않는다.
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SMA="$ROOT/stagemap_arm32"; rm -rf "$SMA"; mkdir -p "$SMA"

# ---------------------------------------------------------------------------
hdr "stage_map arm32: 합성 이미지 만들기"
# 실제 이미지가 따르는 패턴을 흉내 낸 작은 blob 이다. 값(주소·오프셋)은 일부러 실제 기기와 다르게
# 잡았다 - 도출기가 어디선가 빌려 온 값을 쓰면 여기서 틀린다.
#   lk_*   : MTK 헤더(0x58881688) + 페이로드 선두의 벡터 테이블 + 자기재배치 스텁(링크 주소·복사 끝·
#            재배치 후 진입 리터럴) + 문자열/함수 프롤로그를 가리키는 리터럴 풀
#   pl_*   : EMMC_BOOT 헤더 + BRLYT + 페이로드+0x600 의 GFH(FILE_INFO) + crt0(0 워드 뒤 b,
#            ldr pc 로 Thumb 함수로 점프)
python3 - "$SMA" <<'PYGEN'
import os, random, struct, sys
out = sys.argv[1]
LK_BASE = 0x80c00000
PL_LOAD, PL_GFH, PL_JUMP = 0x00101c10, 0x400, 0x80       # GFH 위치·점프 오프셋도 실제 값과 다르게
LK_HDR, PL_HDR = 0x300, 0x400                              # 컨테이너 헤더 크기도

def w32(buf, off, v): struct.pack_into("<I", buf, off, v & 0xFFFFFFFF)
def b_(src, dst): return 0xEA000000 | (((dst - (src + 8)) // 4) & 0xFFFFFF)
def ldr_(rd, src, lit):
    d = lit - (src + 8)
    return (0xE59F0000 if d >= 0 else 0xE51F0000) | (rd << 12) | abs(d)

def mtk_header(psize):
    h = bytearray(b"\xff" * LK_HDR)
    struct.pack_into("<II", h, 0, 0x58881688, psize)
    h[8:40] = b"lk".ljust(32, b"\0")
    struct.pack_into("<II", h, 0x28, 0xffffffff, 0xffffffff)     # 적재 주소·모드: 미지정
    struct.pack_into("<III", h, 0x30, 0x58891689, LK_HDR, 1)   # 확장 헤더: 헤더 크기
    return bytes(h)

def gfh(load, jump, file_len=0x100):
    g = bytearray(0x38)
    g[0:4] = b"MMM\x01"
    struct.pack_into("<HH", g, 4, 0x38, 0)
    g[8:20] = b"FILE_INFO\0\0\0"
    struct.pack_into("<I", g, 0x14, 1)
    struct.pack_into("<HBB", g, 0x18, 1, 5, 5)
    struct.pack_into("<IIIIII", g, 0x1c, load, file_len, 0x80000, jump, 0x20, jump)
    struct.pack_into("<I", g, 0x34, 0xc2600001)
    return bytes(g)

def lk_payload(base, N=0x6000, stub=True, ptr_skew=0, gfh_load=None, nstr=24, nfun=16):
    p = bytearray(N)
    for i in range(8):                         # 벡터 테이블: 8 슬롯 전부 b
        w32(p, 4 * i, b_(4 * i, 0x100 + 8 * i))
        w32(p, 0x100 + 8 * i, b_(0x100 + 8 * i, 0x100 + 8 * i))
    if stub:                                   # mov r0,pc; sub r0,r0,#0x48; ldr r1,[pc,..]; cmp; beq ...
        code = [0xE1A0000F, 0xE2400048, ldr_(1, 0x48, 0x74), 0xE1500001,
                0x0A000000 | (((0x80 - (0x50 + 8)) // 4) & 0xFFFFFF),
                ldr_(2, 0x54, 0x78), 0xE4903004, 0xE4813004, 0xE1510002,
                0x1A000000 | (((0x58 - (0x64 + 8)) // 4) & 0xFFFFFF),
                ldr_(0, 0x68, 0x7c), 0xE12FFF10]
        for k, c in enumerate(code):
            w32(p, 0x40 + 4 * k, c)
        w32(p, 0x74, base)                     # 링크 주소
        w32(p, 0x78, base + N - 0x40)          # 복사 끝
        w32(p, 0x7c, base + 0x80)              # 재배치 후 진입
    rnd = random.Random(7)
    stroff, pos = [], 0x1000
    for i in range(nstr):                      # 문자열은 NUL 뒤에서 시작
        s = ("Little Kernel boot %02d: fastboot mode %s" % (i, "ready" * (1 + rnd.randrange(3)))).encode()
        p[pos:pos + len(s)] = s
        stroff.append(pos); pos += len(s) + 1
    funcs, pos = [], 0x2000
    for j in range(nfun):                      # 함수 간격은 불규칙하게: 규칙적이면 어긋난 base 도 다른 함수에 착지한다
        funcs.append(pos); pos += 0x30 + 4 * rnd.randrange(0, 9)
    for j in range(nfun):                      # push {r4,lr}; ldr; ldr; pop {r4,pc}; 리터럴 둘
        f = funcs[j]
        w32(p, f, 0xE92D4010)
        w32(p, f + 4, ldr_(0, f + 4, f + 0x20))
        w32(p, f + 8, ldr_(1, f + 8, f + 0x24))
        w32(p, f + 12, 0xE8BD8010)
        w32(p, f + 0x20, base + stroff[j % nstr] + ptr_skew)
        w32(p, f + 0x24, base + funcs[(j + 1) % nfun] + ptr_skew)
    if gfh_load is not None:                   # 페이로드 안의 GFH: 다른 로드베이스를 주장
        p[0x1c00:0x1c00 + 0x38] = gfh(gfh_load, 0x40)
    return bytes(p)

def lk_image(base, size_skew=0, **kw):
    p = lk_payload(base, **kw)
    return mtk_header(len(p) + size_skew) + p + b"\xff" * 0x1000

def pl_image(load, ptr_shift=0, size=0x8000):
    pay = bytearray(size)
    pay[0:8] = b"BRLYT\0\0\0"
    struct.pack_into("<II", pay, 8, 1, 0x800)
    pay[PL_GFH:PL_GFH + 0x38] = gfh(load, PL_JUMP)
    entry = PL_GFH + PL_JUMP
    crt0 = entry + 0x20
    w32(pay, entry + 4, b_(entry + 4, crt0))   # entry 의 첫 워드는 0, 다음이 b
    for k, c in enumerate([0xE10F0000, 0xE3C0001F, 0xE38000D3, 0xE129F000, 0xE51FF004]):
        w32(pay, crt0 + 4 * k, c)              # mrs/bic/orr/msr cpsr; ldr pc,[pc,#-4]
    func, base = PL_GFH + 0x400, load - PL_GFH
    w32(pay, crt0 + 20, (base + func + ptr_shift) | 1)      # Thumb 함수 주소
    for o in range(func - 8, func + 0x40, 2):
        pay[o:o + 2] = b"\x00\xbf"             # nop
    pay[func:func + 2] = b"\xf0\xb5"           # push {r4-r7, lr}
    hdr = bytearray(b"\xff" * PL_HDR)
    hdr[0:12] = b"EMMC_BOOT\0\0\0"
    struct.pack_into("<II", hdr, 0xc, 1, PL_HDR)
    return bytes(hdr) + bytes(pay) + b"\xff" * 0x1000

def put(name, data):
    open(os.path.join(out, name), "wb").write(data)

put("lk_ok.bin", lk_image(LK_BASE))
put("lk_size.bin", lk_image(LK_BASE, size_skew=0x1000))           # 헤더 페이로드 크기와 복사 끝 불일치
put("lk_skew.bin", lk_image(LK_BASE, ptr_skew=4))                 # 스텁은 맞고 풀 포인터는 안 착지
put("lk_nostub.bin", lk_image(LK_BASE, stub=False))               # 선언된 앵커 없음
put("lk_gfh.bin", lk_image(LK_BASE, gfh_load=LK_BASE + 0x2000 + 0x1c00))   # GFH 가 다른 값을 주장
_noext = bytearray(lk_image(LK_BASE)); struct.pack_into("<I", _noext, 0x30, 0)
put("lk_noext.bin", bytes(_noext))                                # 확장 헤더가 없어 페이로드 시작을 알 수 없다
put("pl_ok.bin", pl_image(PL_LOAD))
put("pl_v1.bin", pl_image(PL_LOAD, ptr_shift=PL_GFH))             # 점프 리터럴이 GFH 주소를 페이로드 시작으로 본 값
rnd = random.Random(3)
put("noentry.bin", struct.pack("<I", 0x58881688) + bytes(rnd.randrange(256) for _ in range(0x4000)))

# arm64: smoke.sh 의 합성 이미지와 같은 모양 + 앵커가 있는 이미지
def stub64():
    return (struct.pack("<I", 0x14000001) + struct.pack("<I", 0x10000000) +
            struct.pack("<I", 0xD5384241) + struct.pack("<I", 0xD51EC000))
def plain(n, seed):
    r = random.Random(seed); b = bytearray()
    toks = [b"Pass: Loading EPBL\x00", b"DMC\x00", b"Samsung S-Boot 4.0\x00"]
    while len(b) < n:
        b += r.choice(toks) if r.random() < 0.25 else struct.pack("<I", 0xA9BF7BFD)
    return bytes(b[:n])
def cipher(n, seed):
    r = random.Random(seed); return bytes(r.randrange(256) for _ in range(n))
put("a64_fake.bin", stub64() + plain(0x5000 - 16, 1) + cipher(0xe800 - 0x5000, 2)
    + stub64() + plain(0x30000 - 0xe800 - 16, 3))
body = bytearray(stub64() + plain(0x4000 - 16, 5))
for k in range(16):
    struct.pack_into("<Q", body, 0x1000 + 8 * k, 0x80000000 + 0x100 * k)
struct.pack_into("<Q", body, 0x1000 + 8 * 16, 0x80000000 + 0x4000)   # BSS 시작(제로 패딩 시작)
put("a64_anchor.bin", bytes(body) + bytes(0x4000))

# --detect-arch 용: 한 가지 근거만 있는 이미지, 근거가 어긋나는 이미지, 근거가 없는 이미지
put("lk_vtonly.bin", lk_image(LK_BASE, stub=False, nfun=0))             # 벡터 테이블만 (함수가 없어 패턴 근거도 없다)
mixed = bytearray(lk_image(LK_BASE, stub=False))                        # ARM 벡터 테이블 + 함수들 ...
mixed[LK_HDR + 0x3000:LK_HDR + 0x3000 + 16] = stub64()                  # ... 그리고 한가운데에 AArch64 진입 스텁
put("lk_with_a64stub.bin", bytes(mixed))
a64body = bytearray(lk_image(LK_BASE, stub=False, nfun=0))              # ARM 벡터 테이블 뒤가 전부 AArch64 프레임 레코드
for o in range(LK_HDR + 0x400, LK_HDR + 0x4000, 4):
    struct.pack_into("<I", a64body, o, 0xA9BF7BFD)
put("lk_a64body.bin", bytes(a64body))
badentry = bytearray(pl_image(PL_LOAD))                                 # GFH 는 있으나 선언한 진입이 0 뿐 (ARM 으로 해독 불가)
badentry[0x880:0x8c0] = bytes(0x40)
put("pl_badentry.bin", bytes(badentry))
put("a64_stubonly.bin", stub64() + bytes(0x1000))                       # AArch64 스텁뿐, 패턴 근거 없음
put("a64_nostub.bin", struct.pack("<I", 0xA9BF7BFD) * 0x1000 + struct.pack("<I", 0xD65F03C0) * 0x100)   # 프레임 레코드만
rnd = random.Random(5)
put("rand64k.bin", bytes(rnd.randrange(256) for _ in range(0x10000)))
put("empty.bin", b"")
put("tiny.bin", b"\x01\x02\x03\x04" * 4)
PYGEN
chk "합성 이미지 생성" "$([ -s "$SMA/lk_ok.bin" ] && [ -s "$SMA/pl_ok.bin" ] && echo yes)" "yes"

sm32_j() { python3 -c "import json,sys;d=json.load(open('$1'));print($2)" 2>/dev/null; }
sm32_run() {   # <이미지> <출력 json> [추가 인자...] -> 종료코드
  local img="$1" js="$2"; shift 2
  python3 "$S/stage_map.py" "$img" --out "$js" --quiet "$@" >/dev/null 2>&1
  echo $?
}

# ---------------------------------------------------------------------------
hdr "stage_map arm32: LK 꼴 - 앵커 둘이 수렴하면 cross_checked"
chk "종료코드 0 (지도가 만들어졌다)" "$(sm32_run "$SMA/lk_ok.bin" "$SMA/lk_ok.json" --arch arm32)" "0"
SM_L="$SMA/lk_ok.json"
chk "스키마 v2" "$(sm32_j "$SM_L" 'd["schema_version"]')" "2"
chk "최상위 arch 는 v1 어휘 유지" "$(sm32_j "$SM_L" 'd["arch"]')" "arm32"
chk "스테이지 arch" "$(sm32_j "$SM_L" 'd["stages"][0]["arch"]')" "aarch32"
chk "state exec" "$(sm32_j "$SM_L" 'd["stages"][0]["state"]')" "exec"
chk "confidence cross_checked" "$(sm32_j "$SM_L" 'd["stages"][0]["confidence"]')" "cross_checked"
chk "로드베이스는 헤더가 아니라 도출 (0x80c00000)" "$(sm32_j "$SM_L" 'd["stages"][0]["base"]["load_base_hex"]')" "0x80c00000"
chk "v1 필드: base 는 딕셔너리, load_base 는 정수" \
    "$(sm32_j "$SM_L" 'type(d["stages"][0]["base"]["load_base"]).__name__')" "int"
chk "file_range 는 페이로드 시작부터" "$(sm32_j "$SM_L" 'd["stages"][0]["file_range"][0]')" "768"
chk "진입 파일 오프셋 = 페이로드 선두의 벡터 테이블" "$(sm32_j "$SM_L" 'd["stages"][0]["entry_pc_file_offset"]')" "768"
chk "entry_pc 는 절대 주소(소문자 16진)" "$(sm32_j "$SM_L" 'd["stages"][0]["entry_pc"]')" "0x80c00000"
chk "진입 종류" "$(sm32_j "$SM_L" 'd["stages"][0]["entry_kind"]')" "vector_table"
chk "origin 기본값" "$(sm32_j "$SM_L" 'd["stages"][0]["origin"]')" "container"
chk "entered_by (컨테이너 첫 스테이지)" "$(sm32_j "$SM_L" 'd["stages"][0]["entered_by"]')" "reset"
chk "앵커 3종이 기록됨" \
    "$(sm32_j "$SM_L" '",".join(d["stages"][0]["anchors"])')" \
    "self_relocation_literal,copy_end_minus_header_size,literal_pool_landing"
chk "컨테이너 형식" "$(sm32_j "$SM_L" 'd["stages"][0]["container"]["format"]')" "mtk_image"
chk "컨테이너 페이로드 오프셋 (확장 헤더의 헤더 크기 필드)" "$(sm32_j "$SM_L" 'd["stages"][0]["container"]["payload_offset"]')" "768"
chk "컨테이너 헤더 크기 필드" "$(sm32_j "$SM_L" 'd["stages"][0]["container"]["header_size_field"]')" "768"
chk "컨테이너 파싱 근거가 남음" \
    "$(sm32_j "$SM_L" 'len(d["stages"][0]["container"]["evidence"]) >= 3')" "True"
chk "복사 끝 − 헤더 페이로드 크기 차이가 허용 이내" \
    "$(sm32_j "$SM_L" '[a for a in d["stages"][0]["base"]["anchors"] if a["kind"]=="self_relocation_literal"][0]["copy_end_minus_header_size"] <= 192')" "True"
chk "entry_pc = base + (진입 오프셋 - file_range 시작)  (verify.py 항목 4 가 기대하는 식)" \
    "$(sm32_j "$SM_L" 'hex(d["stages"][0]["base"]["load_base"] + (d["stages"][0]["entry_pc_file_offset"] - d["stages"][0]["file_range"][0])) == d["stages"][0]["entry_pc"]')" "True"

chk "--origin medium --partition: 종료코드" \
    "$(sm32_run "$SMA/lk_ok.bin" "$SMA/lk_med.json" --arch arm32 --origin medium --partition lk)" "0"
chk "  origin" "$(sm32_j "$SMA/lk_med.json" 'd["stages"][0]["origin"]')" "medium"
chk "  partition" "$(sm32_j "$SMA/lk_med.json" 'd["stages"][0]["partition"]')" "lk"
chk "  entered_by (이전 스테이지가 분기)" "$(sm32_j "$SMA/lk_med.json" 'd["stages"][0]["entered_by"]')" "branch"

# ---------------------------------------------------------------------------
hdr "stage_map arm32: 프리로더 꼴 - GFH 는 페이로드+0x600, 진입은 GFH 선언"
chk "종료코드 0" "$(sm32_run "$SMA/pl_ok.bin" "$SMA/pl_ok.json" --arch arm32)" "0"
SM_P="$SMA/pl_ok.json"
chk "컨테이너 형식" "$(sm32_j "$SM_P" 'd["stages"][0]["container"]["format"]')" "emmc_boot"
chk "컨테이너 페이로드 오프셋 (BRLYT 로 확인)" "$(sm32_j "$SM_P" 'd["stages"][0]["container"]["payload_offset"]')" "1024"
chk "confidence cross_checked" "$(sm32_j "$SM_P" 'd["stages"][0]["confidence"]')" "cross_checked"
chk "로드베이스 = GFH 로드 주소 - GFH 의 페이로드 내 위치 (0x101c10 - 0x400)" \
    "$(sm32_j "$SM_P" 'd["stages"][0]["base"]["load_base_hex"]')" "0x101810"
chk "컨테이너 기록에 GFH 위치 (페이로드+0x400)" "$(sm32_j "$SM_P" 'd["stages"][0]["container"]["gfh"]["payload_offset"]')" "1024"
chk "  GFH 파싱 근거가 컨테이너 evidence 에 남음" \
    "$(sm32_j "$SM_P" 'any("GFH FILE_INFO" in e for e in d["stages"][0]["container"]["evidence"])')" "True"
chk "GFH 가 없는 컨테이너는 gfh=null" "$(sm32_j "$SM_L" 'd["stages"][0]["container"]["gfh"]')" "None"
chk "GFH 위치가 앵커 기록에도 페이로드 기준으로 남음" \
    "$(sm32_j "$SM_P" '[a for a in d["stages"][0]["base"]["anchors"] if a["kind"]=="gfh_load_addr"][0]["gfh_payload_offset"]')" "1024"
chk "앵커: GFH + 리터럴 풀" "$(sm32_j "$SM_P" '",".join(d["stages"][0]["anchors"])')" "gfh_load_addr,literal_pool_landing"
chk "풀 앵커의 강도가 기록됨 (점프 리터럴 근거)" \
    "$(sm32_j "$SM_P" '[a for a in d["stages"][0]["base"]["anchors"] if a["kind"]=="literal_pool_landing"][0]["strength"]')" "jump_literal"
chk "진입 종류" "$(sm32_j "$SM_P" 'd["stages"][0]["entry_kind"]')" "gfh_jump"
chk "진입 PC = GFH 로드 주소 + 점프 오프셋 뒤 첫 명령 (0 워드 하나 건너뜀)" \
    "$(sm32_j "$SM_P" 'd["stages"][0]["entry_pc"]')" "0x101c94"
chk "GFH 선언 PC 는 따로 보존" "$(sm32_j "$SM_P" 'd["entry_stubs"][0]["declared_pc"]')" "0x101c90"
chk "건너뛴 0 워드 수" "$(sm32_j "$SM_P" 'd["entry_stubs"][0]["skipped_zero_words"]')" "1"
chk "진입 ISA" "$(sm32_j "$SM_P" 'd["stages"][0]["entry_isa"]')" "arm"
chk "entry_pc = base + (진입 오프셋 - file_range 시작)" \
    "$(sm32_j "$SM_P" 'hex(d["stages"][0]["base"]["load_base"] + (d["stages"][0]["entry_pc_file_offset"] - d["stages"][0]["file_range"][0])) == d["stages"][0]["entry_pc"]')" "True"

# ---------------------------------------------------------------------------
hdr "stage_map arm32: 수렴하지 않으면 unconfirmed - 후보만 내고 실행 가능으로 세지 않는다"
sm32_unconfirmed() {   # <설명> <이미지> <json>
  local desc="$1" img="$2" js="$3"
  chk "$desc: 종료코드 0 (지도는 만들어졌다)" "$(sm32_run "$img" "$js" --arch arm32)" "0"
  chk "  state 는 exec 가 아니다" "$(sm32_j "$js" 'd["stages"][0]["state"]')" "unconfirmed"
  chk "  confidence unconfirmed" "$(sm32_j "$js" 'd["stages"][0]["confidence"]')" "unconfirmed"
  chk "  load_base 를 단정하지 않는다" "$(sm32_j "$js" 'd["stages"][0]["base"]["load_base"]')" "None"
  chk "  entry_pc 도 비운다" "$(sm32_j "$js" 'd["stages"][0]["entry_pc"]')" "None"
  chk "  실행 가능 스테이지 수 0 (소비자의 state==exec 필터)" \
      "$(sm32_j "$js" 'sum(1 for s in d["stages"] if s["state"]=="exec")')" "0"
  chk "  이유가 기록됨" "$(sm32_j "$js" 'bool(d["stages"][0]["base"]["why"])')" "True"
}
sm32_unconfirmed "헤더 페이로드 크기와 복사 끝 불일치 (앵커 (a) 무효, 풀만 남음)" "$SMA/lk_size.bin" "$SMA/lk_size.json"
chk "  무효가 된 앵커와 이유가 남음" \
    "$(sm32_j "$SMA/lk_size.json" 'bool(d["stages"][0]["base"]["rejected_anchors"][0]["rejected"])')" "True"
chk "  후보에 풀 앵커만 붙음" \
    "$(sm32_j "$SMA/lk_size.json" '",".join(d["stages"][0]["base"]["candidates"][0]["anchors"])')" "literal_pool_landing"
sm32_unconfirmed "스텁은 맞는데 풀 포인터가 착지하지 않음 (앵커 하나뿐)" "$SMA/lk_skew.bin" "$SMA/lk_skew.json"
chk "  후보 하나가 앵커 (a) 만 달고 남음" \
    "$(sm32_j "$SMA/lk_skew.json" '",".join(d["stages"][0]["base"]["candidates"][0]["anchors"])')" \
    "self_relocation_literal,copy_end_minus_header_size"
sm32_unconfirmed "선언된 앵커가 없음 (스텁도 GFH 도 없다 - 풀만으로는 후보를 내지 않는다)" "$SMA/lk_nostub.bin" "$SMA/lk_nostub.json"
chk "  후보 목록이 비어 있음" "$(sm32_j "$SMA/lk_nostub.json" 'len(d["stages"][0]["base"]["candidates"])')" "0"
sm32_unconfirmed "앵커가 서로 다른 값을 가리킴 (스텁+풀 vs 페이로드 안 GFH)" "$SMA/lk_gfh.bin" "$SMA/lk_gfh.json"
chk "  후보가 둘 이상 나열됨" "$(sm32_j "$SMA/lk_gfh.json" 'len(d["stages"][0]["base"]["candidates"]) >= 2')" "True"
chk "  불일치로 표시됨" "$(sm32_j "$SMA/lk_gfh.json" '"불일치" in d["stages"][0]["base"]["why"]')" "True"
sm32_unconfirmed "GFH 주소를 페이로드 시작으로 읽은 값(+0x600)으로 점프 리터럴이 만들어짐" "$SMA/pl_v1.bin" "$SMA/pl_v1.json"
chk "  GFH 후보는 앵커 하나로만 남음" \
    "$(sm32_j "$SMA/pl_v1.json" '",".join(d["stages"][0]["base"]["candidates"][0]["anchors"])')" "gfh_load_addr"

# ---------------------------------------------------------------------------
hdr "stage_map arm32: 종료코드 3 은 '진입 시그니처를 찾지 못함' 일 때만"
chk "진입 시그니처 없음: 종료코드 3" "$(sm32_run "$SMA/noentry.bin" "$SMA/ne.json" --arch arm32)" "3"
chk "  스테이지를 만들어 내지 않는다" "$(sm32_j "$SMA/ne.json" 'len(d["stages"])')" "0"
chk "  arch_supported=false" "$(sm32_j "$SMA/ne.json" 'd["arch_supported"]')" "False"
chk "  BLOCKED_ARCH 안내" "$(sm32_j "$SMA/ne.json" '"BLOCKED_ARCH" in " ".join(d["notes"])')" "True"
chk "헤더는 MTK 인데 페이로드 시작을 확정 못함: 시그니처를 못 찾아 3 (오프셋을 흔한 값으로 채우지 않는다)" \
    "$(sm32_run "$SMA/lk_noext.bin" "$SMA/noext.json" --arch arm32)" "3"
chk "  컨테이너는 인식했으나 unconfirmed, payload_offset 은 비어 있음" \
    "$(sm32_j "$SMA/noext.json" 'd["container"]["format"] + " " + d["container"]["confidence"] + " " + str(d["container"]["payload_offset"])')" \
    "mtk_image unconfirmed None"
chk "arm64 이미지를 arm32 로 읽으면 3" "$(sm32_run "$SMA/a64_fake.bin" "$SMA/x.json" --arch arm32)" "3"
chk "컨테이너 헤더를 인식 못해도 벡터 테이블이 있으면 도출은 한다 (형식은 unconfirmed)" \
    "$(REPO="$REPO" python3 - "$SMA" <<'PYX'
import subprocess, sys, json, os
d = open(os.path.join(sys.argv[1], "lk_ok.bin"), "rb").read()[0x300:]       # 헤더를 뗀 원시 페이로드
open(os.path.join(sys.argv[1], "raw.bin"), "wb").write(d)
r = subprocess.run(["python3", os.path.join(os.environ["REPO"], "scripts", "stage_map.py"),
                    os.path.join(sys.argv[1], "raw.bin"), "--arch", "arm32", "--quiet",
                    "--out", os.path.join(sys.argv[1], "raw.json")])
j = json.load(open(os.path.join(sys.argv[1], "raw.json")))["stages"][0]
print(r.returncode, j["container"]["format"], j["container"]["confidence"], j["state"])
PYX
)" "0 unknown unconfirmed unconfirmed"

# ---------------------------------------------------------------------------
hdr "stage_map arm64: 하위 호환 (v1 필드는 그대로, v2 필드가 추가)"
chk "종료코드 0" "$(sm32_run "$SMA/a64_fake.bin" "$SMA/a64.json")" "0"
SM_A="$SMA/a64.json"
chk "평문 앞부분이 exec 로 남음" "$(sm32_j "$SM_A" 'd["stages"][0]["state"]')" "exec"
chk "  범위가 암호화 시작 전까지" "$(sm32_j "$SM_A" 'hex(d["stages"][0]["file_range"][1])')" "0x5000"
chk "암호화 구간은 따로 분리" "$(sm32_j "$SM_A" 'd["stages"][1]["state"]')" "encrypted"
chk "진입 스텁이 그 스테이지에 붙음" "$(sm32_j "$SM_A" 'd["stages"][0]["entry_pc_file_offset"]')" "0"
chk "건너뛸 스테이지는 하나뿐" "$(sm32_j "$SM_A" 'sum(1 for s in d["stages"] if s["state"]!="exec")')" "1"
chk "v1 최상위 필드 유지" \
    "$(sm32_j "$SM_A" 'all(k in d for k in ("image_size","arch","grid","entropy_runs","encrypted_total","entry_stubs","stages","notes"))')" "True"
chk "v1 스테이지 필드 유지" \
    "$(sm32_j "$SM_A" 'all(k in d["stages"][0] for k in ("index","name","identified","file_range","size","state","entry_pc_file_offset","vbar_writes","encrypted_bytes","evidence","base"))')" "True"
chk "최상위 arch 는 arm64" "$(sm32_j "$SM_A" 'd["arch"]')" "arm64"
chk "스테이지 arch" "$(sm32_j "$SM_A" 'd["stages"][0]["arch"]')" "aarch64"
chk "첫 스테이지 entered_by" "$(sm32_j "$SM_A" 'd["stages"][0]["entered_by"]')" "reset"
chk "다음 스테이지 entered_by" "$(sm32_j "$SM_A" 'd["stages"][2]["entered_by"]')" "branch"
chk "앵커 없는 base 는 unconfirmed 이나 state 는 v1 그대로 exec" \
    "$(sm32_j "$SM_A" 'd["stages"][0]["confidence"] + " " + d["stages"][0]["state"]')" "unconfirmed exec"
chk "base 가 없으면 entry_pc 는 비어 있음" "$(sm32_j "$SM_A" 'd["stages"][0]["entry_pc"]')" "None"
chk "arm64 앵커 이미지: 종료코드 0" "$(sm32_run "$SMA/a64_anchor.bin" "$SMA/a64a.json")" "0"
SM_B="$SMA/a64a.json"
chk "  base (v1 도출 그대로)" "$(sm32_j "$SM_B" 'd["stages"][0]["base"]["load_base"]')" "2147483648"
chk "  base.confidence 는 v1 어휘 derived" "$(sm32_j "$SM_B" 'd["stages"][0]["base"]["confidence"]')" "derived"
chk "  entry_pc = base + (진입 오프셋 - 범위 시작)" "$(sm32_j "$SM_B" 'd["stages"][0]["entry_pc"]')" "0x80000000"
chk "  confidence" "$(sm32_j "$SM_B" 'd["stages"][0]["confidence"]')" "derived"
chk "  앵커 이름" "$(sm32_j "$SM_B" 'd["stages"][0]["anchors"][0]')" "bss_zero_padding"
chk "  컨테이너 헤더가 없으면 null" "$(sm32_j "$SM_B" 'd["stages"][0]["container"]')" "None"

# ---------------------------------------------------------------------------
hdr "stage_map --detect-arch: 이미지가 스스로 말하는 ISA (기본값에 기대지 않는다)"
sm32_det() {   # <이미지> <python 식: d 는 판정 JSON>
  python3 "$S/stage_map.py" --detect-arch "$1" 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);print($2)" 2>/dev/null
}
sm32_dt() { sm32_det "$1" 'd["arch"]+" "+d["entry_signature"]+" "+d["confidence"]'; }

# 계약 (K1): stdout 에는 JSON 객체 하나, 키는 넷, 종료코드 0
chk "stdout 은 한 줄짜리 JSON 객체 하나" \
    "$(python3 "$S/stage_map.py" --detect-arch "$SMA/lk_ok.bin" 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "  키는 arch · basis · confidence · entry_signature 넷뿐" \
    "$(sm32_det "$SMA/lk_ok.bin" '",".join(sorted(d))')" "arch,basis,confidence,entry_signature"
chk "  종료코드 0" "$(python3 "$S/stage_map.py" --detect-arch "$SMA/lk_ok.bin" >/dev/null 2>&1; echo $?)" "0"
chk "  unknown 이어도 종료코드 0 (답이다)" \
    "$(python3 "$S/stage_map.py" --detect-arch "$SMA/rand64k.bin" >/dev/null 2>&1; echo $?)" "0"
chk "  같은 입력은 같은 출력" \
    "$([ "$(python3 "$S/stage_map.py" --detect-arch "$SMA/pl_ok.bin")" = "$(python3 "$S/stage_map.py" --detect-arch "$SMA/pl_ok.bin")" ] && echo same)" "same"
SM_BEFORE="$(ls "$SMA" | cksum)"
python3 "$S/stage_map.py" --detect-arch "$SMA/lk_ok.bin" >/dev/null 2>&1
chk "  파일을 만들지 않는다 (stage_map.json 도 없다)" "$([ "$(ls "$SMA" | cksum)" = "$SM_BEFORE" ] && echo same)" "same"
chk "--help 에 --detect-arch 가 있다" "$([ "$(python3 "$S/stage_map.py" --help | grep -c -- '--detect-arch')" -ge 1 ] && echo yes)" "yes"
chk "없는 파일: 종료코드 2, stdout 은 비어 있다" \
    "$(python3 "$S/stage_map.py" --detect-arch "$SMA/없는파일.bin" 2>/dev/null | wc -c | tr -d ' ') $(python3 "$S/stage_map.py" --detect-arch "$SMA/없는파일.bin" >/dev/null 2>&1; echo $?)" "0 2"
chk "폴더를 주면 읽을 수 없으므로 종료코드 2" "$(python3 "$S/stage_map.py" --detect-arch "$SMA" >/dev/null 2>&1; echo $?)" "2"
chk "이미지와 함께 주면 사용 오류 (종료코드 64, 2 는 읽기 실패 전용)" \
    "$(python3 "$S/stage_map.py" "$SMA/lk_ok.bin" --detect-arch "$SMA/lk_ok.bin" >/dev/null 2>&1; echo $?)" "64"

# 모든 합성 이미지가 계약의 어휘 안에서 답하고 근거를 단다
SM_ALL="lk_ok lk_vtonly lk_nostub lk_size lk_skew lk_gfh lk_noext pl_ok pl_v1 pl_badentry noentry rand64k empty tiny a64_fake a64_anchor a64_stubonly a64_nostub lk_with_a64stub lk_a64body"
SM_BAD=""
for f in $SM_ALL; do
  r="$(sm32_det "$SMA/$f.bin" 'int(d["arch"] in ("arm32","arm64","unknown") and d["confidence"] in ("derived","cross_checked","unconfirmed") and __import__("re").match(r"^(gfh|vector_table|crt0|stub:[a-z0-9_]+|none)$", d["entry_signature"]) is not None and len(d["basis"]) >= 1 and all(isinstance(b,str) and b for b in d["basis"]) and ((d["arch"]=="unknown") == (d["entry_signature"]=="none") == (d["confidence"]=="unconfirmed")))')"
  [ "$r" = "1" ] || SM_BAD="$SM_BAD $f"
done
chk "모든 이미지가 어휘 안에서 답하고 근거(basis)를 단다 · unknown 일 때만 none/unconfirmed" "${SM_BAD:-none}" "none"

# AArch32: 구조 근거 + 그 근거들이 몇 종 일치하는가
chk "LK 꼴 (벡터 테이블 + 자기재배치 스텁 + 패턴): 셋이 일치하면 cross_checked" "$(sm32_dt "$SMA/lk_ok.bin")" "arm32 vector_table cross_checked"
chk "  판정 줄이 독립 근거 3종을 말한다" "$(sm32_det "$SMA/lk_ok.bin" '"독립 근거 3종 (code_anchor, entry_code, pattern)" in d["basis"][-1]')" "True"
chk "  컨테이너 헤더는 근거로 세지 않는다고 적는다" "$(sm32_det "$SMA/lk_ok.bin" 'any("근거로 세지 않고" in b for b in d["basis"])')" "True"
chk "벡터 테이블뿐: 근거 한 종이면 derived" "$(sm32_dt "$SMA/lk_vtonly.bin")" "arm32 vector_table derived"
chk "벡터 테이블 + 함수 패턴 (스텁 없음): 둘이 일치하면 cross_checked" "$(sm32_dt "$SMA/lk_nostub.bin")" "arm32 vector_table cross_checked"
chk "프리로더 꼴 (GFH 가 선언한 진입이 ARM, 그 진입이 crt0 로 이어짐)" "$(sm32_dt "$SMA/pl_ok.bin")" "arm32 gfh cross_checked"
chk "  GFH 위치와 선언한 진입이 근거 줄에 남는다" \
    "$(sm32_det "$SMA/pl_ok.bin" 'any("GFH FILE_INFO @0x800" in b and "0x101c90" in b for b in d["basis"])')" "True"
chk "GFH 가 있으나 선언한 진입이 ARM 으로 해독되지 않으면 그것만으로 arm32 라 하지 않는다" "$(sm32_dt "$SMA/pl_badentry.bin")" "unknown none unconfirmed"
chk "  그렇게 판단한 이유가 basis 에 있다" "$(sm32_det "$SMA/pl_badentry.bin" 'any("해독되지 않음" in b for b in d["basis"])')" "True"
chk "컨테이너 헤더가 없는 원시 페이로드도 선두 벡터 테이블로 판정" "$(sm32_dt "$SMA/raw.bin")" "arm32 vector_table cross_checked"
chk "  컨테이너를 못 알아봤다고 적는다" "$(sm32_det "$SMA/raw.bin" 'any("알려진 컨테이너 헤더" in b for b in d["basis"])')" "True"
chk "MTK 헤더인데 페이로드 시작을 못 정함: 스텁과 패턴으로 arm32, 확정 못 했다고 적는다" "$(sm32_dt "$SMA/lk_noext.bin")" "arm32 stub:self_relocation cross_checked"
chk "  basis 에 페이로드 시작 미확정" "$(sm32_det "$SMA/lk_noext.bin" 'any("확정하지 못해" in b for b in d["basis"])')" "True"
# AArch64
chk "arm64 합성 이미지 (CurrentEL + VBAR 스텁 + 프레임 패턴)" "$(sm32_dt "$SMA/a64_fake.bin")" "arm64 stub:currentel_vbar_el3 cross_checked"
chk "arm64 앵커 이미지" "$(sm32_dt "$SMA/a64_anchor.bin")" "arm64 stub:currentel_vbar_el3 cross_checked"
chk "arm64 스텁뿐이면 derived" "$(sm32_dt "$SMA/a64_stubonly.bin")" "arm64 stub:currentel_vbar_el3 derived"
# unknown 이 정답인 것들
chk "무작위 바이트 파일은 unknown" "$(sm32_dt "$SMA/rand64k.bin")" "unknown none unconfirmed"
chk "  고엔트로피라 명령 패턴이 의미 없다고 적는다" "$(sm32_det "$SMA/rand64k.bin" 'any("엔트로피" in b for b in d["basis"])')" "True"
chk "MTK 매직 + 무작위 몸통은 unknown" "$(sm32_dt "$SMA/noentry.bin")" "unknown none unconfirmed"
chk "빈 파일은 unknown (읽을 수는 있으므로 종료코드 0)" \
    "$(sm32_dt "$SMA/empty.bin") $(python3 "$S/stage_map.py" --detect-arch "$SMA/empty.bin" >/dev/null 2>&1; echo $?)" "unknown none unconfirmed 0"
chk "16 바이트 파일은 unknown" "$(sm32_dt "$SMA/tiny.bin")" "unknown none unconfirmed"
chk "AArch64 프레임 레코드만 있고 진입 스텁이 없으면 통계만으로 arm64 라 하지 않는다" "$(sm32_dt "$SMA/a64_nostub.bin")" "unknown none unconfirmed"
chk "  통계가 어느 쪽으로 기우는지는 basis 에 적는다" "$(sm32_det "$SMA/a64_nostub.bin" 'any("AArch64 패턴이 우세" in b for b in d["basis"])')" "True"
chk "AArch32 와 AArch64 진입 시그니처가 함께 있으면 unknown (어느 쪽으로도 기본값을 두지 않는다)" "$(sm32_dt "$SMA/lk_with_a64stub.bin")" "unknown none unconfirmed"
chk "  두 시그니처가 모두 basis 에 있다" \
    "$(sm32_det "$SMA/lk_with_a64stub.bin" 'any(b.startswith("AArch32 시그니처") for b in d["basis"]) and any(b.startswith("AArch64 시그니처") for b in d["basis"])')" "True"
chk "벡터 테이블이 있으나 통계가 반대 ISA 로 우세하면 unknown" "$(sm32_dt "$SMA/lk_a64body.bin")" "unknown none unconfirmed"
chk "  반증 이유가 basis 에 있다" "$(sm32_det "$SMA/lk_a64body.bin" 'any("반대 ISA" in b for b in d["basis"])')" "True"
# 지도 도출기와의 일관성: arm32 지도가 만들어지는 이미지는 arm32, 진입 시그니처가 없어 3 인 이미지는 unknown
SM_DISAGREE=""
for f in lk_ok lk_size lk_skew lk_nostub lk_gfh pl_ok pl_v1; do
  rc="$(sm32_run "$SMA/$f.bin" "$SMA/agree_$f.json" --arch arm32)"
  [ "$rc" = "0" ] && [ "$(sm32_det "$SMA/$f.bin" 'd["arch"]')" = "arm32" ] || SM_DISAGREE="$SM_DISAGREE $f"
done
chk "arm32 지도가 나오는 이미지(7개)는 detect 도 arm32" "${SM_DISAGREE:-none}" "none"
chk "arm32 로 읽으면 종료코드 3 인 무작위 이미지는 detect 도 unknown" \
    "$(sm32_run "$SMA/noentry.bin" "$SMA/agree_ne.json" --arch arm32) $(sm32_det "$SMA/noentry.bin" 'd["arch"]')" "3 unknown"
chk "arm64 로 읽으면 지도가 나오는 AArch32 이미지를 detect 는 arm64 라 하지 않는다 (옛 기본값 arm64 의 오판)" \
    "$(sm32_run "$SMA/lk_ok.bin" "$SMA/agree_default.json") $(sm32_det "$SMA/lk_ok.bin" 'd["arch"]')" "0 arm32"

# S2: 임계값 주석은 한 이미지로 맞춘 값이라고 솔직히 적는다 (동작은 그대로)
chk "COPY_END_TOLERANCE 주석이 '장치 값이 아니다' 라고 하지 않는다" "$(grep -c 'not a device value' "$S/stage_map.py")" "0"
chk "  한 이미지로 맞춘 값이라고 적는다" "$(grep -c 'Calibrated on ONE image' "$S/stage_map.py")" "1"
chk "  동작은 그대로 (192 B)" \
    "$(PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys;sys.path.insert(0,'$S');import stage_map;print(stage_map.COPY_END_TOLERANCE)")" "192"

# ---------------------------------------------------------------------------
hdr "extract_boot_assets.sh: 폴백 헤더 파서 (page size 0x24, header_version 0x28)"
python3 - "$SMA" <<'PYGEN'
import gzip, os, random, struct, sys
out = sys.argv[1]
rnd = random.Random(11)
def blob(n): return bytes(rnd.randrange(256) for _ in range(n))
def rup(n, ps): return (n + ps - 1) // ps * ps
def pad(b, ps): return b + bytes(rup(len(b), ps) - len(b))

def boot(name, hv, ps, kernel, ramdisk, dtb=b"", legacy28=None):
    h = bytearray(max(ps, 0x1000))
    h[0:8] = b"ANDROID!"
    if hv >= 3:                                    # v3/v4: 페이지 4096 고정
        assert ps == 4096
        struct.pack_into("<II", h, 8, len(kernel), len(ramdisk))
        struct.pack_into("<I", h, 0x28, hv)
        body = pad(kernel, ps) + pad(ramdisk, ps)
    else:                                          # v0-v2
        struct.pack_into("<I", h, 0x08, len(kernel))
        struct.pack_into("<I", h, 0x10, len(ramdisk))
        struct.pack_into("<I", h, 0x24, ps)
        struct.pack_into("<I", h, 0x28, hv if legacy28 is None else legacy28)
        body = pad(kernel, ps) + pad(ramdisk, ps)
        if hv == 2:
            struct.pack_into("<I", h, 0x670, len(dtb))
            body += pad(dtb, ps)
    open(os.path.join(out, name), "wb").write(bytes(h[:ps]) + body)

kern = blob(5000); ram = blob(3000); dtb = blob(900)
open(os.path.join(out, "kern.bin"), "wb").write(kern)
open(os.path.join(out, "ram.bin"), "wb").write(ram)
open(os.path.join(out, "dtb.bin"), "wb").write(dtb)
boot("boot_v0.img", 0, 2048, kern, ram)
boot("boot_v0_legacy.img", 0, 4096, kern, ram, legacy28=0x1a000)      # 0x28 에 옛 dt_size
boot("boot_v1.img", 1, 4096, kern, ram)
boot("boot_v2.img", 2, 2048, kern, ram, dtb)
boot("boot_v3.img", 3, 4096, kern, ram)
boot("boot_v2_gz.img", 2, 2048, gzip.compress(kern), ram, dtb)
PYGEN
SM_EB="$S/extract_boot_assets.sh"
sm32_extract() {   # <이름> <img> [기대 dtb 있음]
  local name="$1" img="$2" wd="$SMA/ex_$1"
  rm -rf "$wd"; mkdir -p "$wd"
  UNPACK_BOOTIMG=/nonexistent bash "$SM_EB" "$wd" "$SMA/$img" >"$wd/log.txt" 2>&1
  chk "$name: 종료코드 0" "$?" "0"
  chk "  폴백으로 처리됨" "$(grep -c '폴백' "$wd/log.txt")" "1"
  chk "  커널이 원본과 같다" "$(cmp -s "$wd/fw/Image" "$SMA/kern.bin" && echo same)" "same"
  chk "  램디스크가 원본과 같다" "$(cmp -s "$wd/fw/initramfs.cpio.gz" "$SMA/ram.bin" && echo same)" "same"
}
sm32_extract "헤더 v0 (page 2048)" boot_v0.img
sm32_extract "헤더 v0, 0x28 에 옛 dt_size" boot_v0_legacy.img
sm32_extract "헤더 v1 (page 4096)" boot_v1.img
sm32_extract "헤더 v2 (page 2048)" boot_v2.img
chk "  v2 의 dtb 도 꺼낸다" "$(cmp -s "$SMA/ex_헤더 v2 (page 2048)/fw/dtb" "$SMA/dtb.bin" && echo same)" "same"
sm32_extract "헤더 v3 (page 4096 고정, 램디스크 크기는 0xc)" boot_v3.img
sm32_extract "gzip 커널 (헤더 v2)" boot_v2_gz.img
# 0x28 을 page size 로 읽던 옛 코드는 v2 에서 page size 2 를 얻어 커널을 엉뚱한 곳에서 잘랐다.
chk "page size 를 0x28 에서 읽지 않는다" \
    "$(! grep -qE "unpack\('<I',b,0x28\)\[0\] or 4096|struct.unpack_from\('<I',b,0x28\)\[0\] or 4096" "$SM_EB" && echo ok)" "ok"

# ---------------------------------------------------------------------------
hdr "extract_boot_assets.sh: 비대화형 · 멱등 (파이프라인이 Analyze 앞에서 그대로 부른다)"
sm32_eb() {   # <workdir> <인자...> -> 종료코드. 출력은 <workdir>.log. stdin 은 닫는다 (질문하면 여기서 멈춘다)
  local wd="$1"; shift
  UNPACK_BOOTIMG="${SM_UNPACK:-/nonexistent}" PATH="${SM_PATH:-$PATH}" "$BASH" "$SM_EB" "$wd" "$@" >"$wd.log" 2>&1 </dev/null
  echo $?
}
sm32_ck() { cksum "$1"/fw/Image "$1"/fw/initramfs.cpio.gz "$1"/fw/dtb 2>/dev/null | tr '\n' ' '; }
python3 - "$SMA" <<'PYGEN'
import os, random, sys
out = sys.argv[1]
rnd = random.Random(21)
def blob(n): return bytes(rnd.randrange(256) for _ in range(n))
open(os.path.join(out, "notandroid.img"), "wb").write(blob(9000))
open(os.path.join(out, "super_raw.bin"), "wb").write(b"RAWSUPER" + blob(3000))
open(os.path.join(out, "super_raw2.bin"), "wb").write(b"SECONDSUPER" + blob(3000))
open(os.path.join(out, "super_sparse.bin"), "wb").write(bytes([0x3a, 0xff, 0x26, 0xed]) + blob(3000))
PYGEN
head -c 5000 "$SMA/boot_v2.img" > "$SMA/boot_trunc.img"        # 헤더는 멀쩡하나 커널이 잘렸다

chk "인자가 없으면 종료코드 1" "$(bash "$SM_EB" >/dev/null 2>&1 </dev/null; echo $?)" "1"
chk "boot.img 인자가 없으면 종료코드 1" "$(bash "$SM_EB" "$SMA/ex_noarg" >/dev/null 2>&1 </dev/null; echo $?)" "1"
SM_W="$SMA/ex_missing"; rm -rf "$SM_W"; mkdir -p "$SM_W"
chk "boot.img 가 없으면 종료코드 2" "$(sm32_eb "$SM_W" "$SMA/없는.img")" "2"
chk "super 인자가 가리키는 파일이 없으면 종료코드 2" "$(sm32_eb "$SM_W" "$SMA/boot_v2.img" "$SMA/없는.lz4")" "2"
chk "  (입력 검사에서 멈춰 fw/ 를 만들지 않는다)" "$([ -e "$SM_W/fw" ] && echo made || echo none)" "none"
chk "Android boot image 가 아니면 종료코드 3" "$(sm32_eb "$SM_W" "$SMA/notandroid.img")" "3"
chk "  Image 를 만들지 않는다" "$([ -e "$SM_W/fw/Image" ] && echo made || echo none)" "none"

SM_W="$SMA/ex_idem"; rm -rf "$SM_W"; mkdir -p "$SM_W"
chk "첫 실행 (super·dtb 는 빈 문자열 - 파이프라인이 부르는 형태)" "$(sm32_eb "$SM_W" "$SMA/boot_v2.img" "" "")" "0"
SM_H1="$(sm32_ck "$SM_W")"
chk "  마지막 줄은 고정 형식의 요약" "$(tail -1 "$SM_W.log")" "assets: image=1 dtb=1 initrd=1 super=none"
chk "  DTB 를 꺼냈으면 '미확보' 라고 하지 않는다" "$(grep -c '미확보' "$SM_W.log")" "0"
chk "다시 실행: 종료코드 0" "$(sm32_eb "$SM_W" "$SMA/boot_v2.img" "" "")" "0"
chk "  fw/ 의 내용이 그대로" "$(sm32_ck "$SM_W")" "$SM_H1"
chk "  임시 폴더가 남지 않고, fw/ 에는 이 스크립트가 만든 파일뿐" "$(LC_ALL=C ls -A "$SM_W/fw" | tr '\n' ' ')" "Image dtb initramfs.cpio.gz "
chk "  파이프라인의 표지 파일(.assets_staged)은 건드리지 않는다" \
    "$(: > "$SM_W/fw/.assets_staged"; sm32_eb "$SM_W" "$SMA/boot_v2.img" "" "" >/dev/null; [ -f "$SM_W/fw/.assets_staged" ] && echo kept)" "kept"
chk "잘린 boot.img 로 다시 실행: 종료코드 3" "$(sm32_eb "$SM_W" "$SMA/boot_trunc.img")" "3"
chk "  이미 적재된 fw/ 를 짧은 Image 로 덮지 않는다" "$(sm32_ck "$SM_W")" "$SM_H1"
chk "비 Android 파일로 다시 실행: 종료코드 3, fw/ 그대로" "$(sm32_eb "$SM_W" "$SMA/notandroid.img") $([ "$(sm32_ck "$SM_W")" = "$SM_H1" ] && echo same)" "3 same"
chk "지정한 DTB 는 board.dtb 로 복사" "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "" "$SMA/dtb.bin") $(cmp -s "$SM_W/fw/board.dtb" "$SMA/dtb.bin" && echo same)" "0 same"
chk "지정한 DTB 가 없으면 경고만 하고 계속한다" "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "" "$SMA/없는.dtb") $(grep -c '지정한 DTB' "$SM_W.log")" "0 1"
SM_W="$SMA/ex_nodtb"; rm -rf "$SM_W"; mkdir -p "$SM_W"
chk "DTB 가 없는 boot.img: 종료코드 0, 요약 dtb=0, 미확보 안내" \
    "$(sm32_eb "$SM_W" "$SMA/boot_v0.img") $(tail -1 "$SM_W.log") $(grep -c '미확보' "$SM_W.log")" \
    "0 assets: image=1 dtb=0 initrd=1 super=none 1"

# super: 이미 적재된 것을 다시 주어도 실패하지 않고, 원본이 바뀌면 다시 적재한다
SM_W="$SMA/ex_super"; rm -rf "$SM_W"; mkdir -p "$SM_W"
chk "raw super 적재" "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SMA/super_raw.bin") $(cmp -s "$SM_W/fw/super.img" "$SMA/super_raw.bin" && echo same) $(tail -1 "$SM_W.log")" \
    "0 same assets: image=1 dtb=0 initrd=1 super=raw"
chk "이미 적재된 fw/super.img 를 super 인자로 다시 주어도 종료코드 0 (같은 파일을 cp 하지 않는다)" \
    "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SM_W/fw/super.img") $(cmp -s "$SM_W/fw/super.img" "$SMA/super_raw.bin" && echo same)" "0 same"
chk "같은 원본이면 다시 풀지 않는다" "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SMA/super_raw.bin") $(grep -c '다시 풀지 않음' "$SM_W.log")" "0 1"
touch -t 203012312359 "$SMA/super_raw2.bin"
chk "원본이 더 새로우면 다시 적재한다" "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SMA/super_raw2.bin") $(cmp -s "$SM_W/fw/super.img" "$SMA/super_raw2.bin" && echo same)" "0 same"
if command -v lz4 >/dev/null 2>&1; then
  lz4 -q -f "$SMA/super_raw.bin" "$SMA/super_raw.bin.lz4" >/dev/null 2>&1
  SM_W="$SMA/ex_lz4"; rm -rf "$SM_W"; mkdir -p "$SM_W"
  chk "super.img.lz4 해제" "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SMA/super_raw.bin.lz4") $(cmp -s "$SM_W/fw/super.img" "$SMA/super_raw.bin" && echo same)" "0 same"
  chk "  다시 실행해도 같은 결과" "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SMA/super_raw.bin.lz4") $(cmp -s "$SM_W/fw/super.img" "$SMA/super_raw.bin" && echo same)" "0 same"
else
  ok "lz4 없음 - super.img.lz4 해제 시험 건너뜀"
fi

# 외부 도구가 없는 환경 (xxd · lz4 · simg2img 없음): 필요한 명령만 링크한 PATH 로 돌린다
SM_NOX="$SMA/nox"; rm -rf "$SM_NOX"; mkdir -p "$SM_NOX"
SM_NOX_OK=1
for c in dirname uname mkdir rm od tr head cp mv gzip python3 ls grep; do
  t="$(command -v "$c" 2>/dev/null)"
  if [ -n "$t" ]; then ln -s "$t" "$SM_NOX/$c"; else SM_NOX_OK=""; fi
done
if [ -n "$SM_NOX_OK" ] && ! PATH="$SM_NOX" command -v xxd >/dev/null 2>&1; then
  SM_PATH="$SM_NOX"
  SM_W="$SMA/ex_nolz4"; rm -rf "$SM_W"; mkdir -p "$SM_W"
  chk "lz4 가 없으면 종료코드 4 (boot.img 쪽 자산은 이미 fw/ 에 있다)" \
      "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SMA/super_raw.bin.lz4") $([ -s "$SM_W/fw/Image" ] && echo image)" "4 image"
  chk "  요약 줄은 super=none" "$(tail -1 "$SM_W.log")" "assets: image=1 dtb=0 initrd=1 super=none"
  SM_W="$SMA/ex_nosimg"; rm -rf "$SM_W"; mkdir -p "$SM_W"
  chk "sparse 인데 simg2img 가 없으면 경고하고 종료코드 0, 요약은 super=sparse (xxd 없이 sparse 를 알아본다)" \
      "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SMA/super_sparse.bin") $(tail -1 "$SM_W.log") $(grep -c 'simg2img 없음' "$SM_W.log")" \
      "0 assets: image=1 dtb=0 initrd=1 super=sparse 1"
  printf '#!/bin/sh\nprintf RAWCONVERTED > "$2"\n' > "$SM_NOX/simg2img"; chmod +x "$SM_NOX/simg2img"
  chk "  다음 실행에서 simg2img 가 있으면 raw 로 바꾼다 (sparse 는 '새로움' 으로 건너뛰지 않는다)" \
      "$(sm32_eb "$SM_W" "$SMA/boot_v0.img" "$SMA/super_sparse.bin") $(cat "$SM_W/fw/super.img") $(tail -1 "$SM_W.log")" \
      "0 RAWCONVERTED assets: image=1 dtb=0 initrd=1 super=raw"
  SM_PATH=""
else
  ok "필요한 명령을 링크하지 못하거나 PATH 에서 xxd 를 뺄 수 없음 - 외부 도구 없는 환경 시험 건너뜀"
fi

# 표준 unpack_bootimg 경로 (가짜 도구): 커널이 gzip 인지는 이름이 아니라 매직으로 가른다
SM_FB="$SMA/fakebin"; mkdir -p "$SM_FB"
cat > "$SM_FB/unpack_bootimg" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in --boot_img) shift 2;; --out) out="$2"; shift 2;; *) shift;; esac; done
[ -n "$FAKE_FAIL" ] && { echo "boom" >&2; exit 1; }
mkdir -p "$out"
cp "$FAKE_KERNEL" "$out/kernel"
[ -n "$FAKE_RAMDISK" ] && cp "$FAKE_RAMDISK" "$out/ramdisk"
[ -n "$FAKE_DTB" ] && cp "$FAKE_DTB" "$out/dtb"
exit 0
FAKE
chmod +x "$SM_FB/unpack_bootimg"
SM_UNPACK="$SM_FB/unpack_bootimg"; export FAKE_RAMDISK="$SMA/ram.bin" FAKE_DTB="$SMA/dtb.bin"
gzip -c "$SMA/kern.bin" > "$SMA/kern.gz"
{ cat "$SMA/kern.gz"; printf 'TRAILING-GARBAGE'; } > "$SMA/kern_trail.gz"
: > "$SMA/kern_empty.bin"
head -c 2000 "$SMA/kern.gz" > "$SMA/kern_cut.gz"                 # 도중에 끊긴 gzip
SM_W="$SMA/ex_std_raw"; rm -rf "$SM_W"; mkdir -p "$SM_W"
chk "표준 도구 + raw 커널: Image 가 원본과 같다 (raw 커널을 .gz 로 부르지 않는다)" \
    "$(FAKE_KERNEL="$SMA/kern.bin" sm32_eb "$SM_W" "$SMA/boot_v0.img") $(cmp -s "$SM_W/fw/Image" "$SMA/kern.bin" && echo same) $([ -e "$SM_W/fw/Image.gz" ] && echo gz-left)" "0 same "
chk "  램디스크·dtb 도 같다" "$(cmp -s "$SM_W/fw/initramfs.cpio.gz" "$SMA/ram.bin" && echo same) $(cmp -s "$SM_W/fw/dtb" "$SMA/dtb.bin" && echo same)" "same same"
SM_W="$SMA/ex_std_gz"; rm -rf "$SM_W"; mkdir -p "$SM_W"
chk "표준 도구 + gzip 커널: Image 가 원본과 같고 .gz 는 남지 않는다" \
    "$(FAKE_KERNEL="$SMA/kern.gz" sm32_eb "$SM_W" "$SMA/boot_v0.img") $(cmp -s "$SM_W/fw/Image" "$SMA/kern.bin" && echo same) $([ -e "$SM_W/fw/Image.gz" ] && echo gz-left)" "0 same "
SM_W="$SMA/ex_std_trail"; rm -rf "$SM_W"; mkdir -p "$SM_W"
chk "  꼬리에 쓰레기가 붙은 gzip 도 풀린다" \
    "$(FAKE_KERNEL="$SMA/kern_trail.gz" sm32_eb "$SM_W" "$SMA/boot_v0.img") $(cmp -s "$SM_W/fw/Image" "$SMA/kern.bin" && echo same)" "0 same"
chk "  표준 도구로 다시 실행해도 같다" \
    "$(FAKE_KERNEL="$SMA/kern.gz" sm32_eb "$SM_W" "$SMA/boot_v0.img") $(cmp -s "$SM_W/fw/Image" "$SMA/kern.bin" && echo same)" "0 same"
SM_H2="$(sm32_ck "$SM_W")"
chk "표준 도구가 비어 있는 커널을 내면 종료코드 3, 적재된 fw/ 는 그대로" \
    "$(FAKE_KERNEL="$SMA/kern_empty.bin" sm32_eb "$SM_W" "$SMA/boot_v0.img") $([ "$(sm32_ck "$SM_W")" = "$SM_H2" ] && echo same)" "3 same"
chk "표준 도구가 끊긴 gzip 커널을 내면 종료코드 3, 적재된 fw/ 는 그대로 (풀다 만 Image 로 덮지 않는다)" \
    "$(FAKE_KERNEL="$SMA/kern_cut.gz" sm32_eb "$SM_W" "$SMA/boot_v0.img") $([ "$(sm32_ck "$SM_W")" = "$SM_H2" ] && echo same)" "3 same"
# GNU gzip 은 끊긴 입력에서도 풀린 만큼을 내보내고 실패한다 (BSD gzip 은 아무것도 내지 않는다)
mkdir -p "$SMA/fakegz"; printf '#!/bin/sh\nprintf PARTIAL-OUTPUT\nexit 1\n' > "$SMA/fakegz/gzip"; chmod +x "$SMA/fakegz/gzip"
chk "gzip 이 풀다 만 출력을 내고 실패해도 종료코드 3, 적재된 fw/ 는 그대로" \
    "$(SM_PATH="$SMA/fakegz:$PATH" FAKE_KERNEL="$SMA/kern.gz" sm32_eb "$SM_W" "$SMA/boot_v0.img") $([ "$(sm32_ck "$SM_W")" = "$SM_H2" ] && echo same)" "3 same"
chk "표준 도구가 실패하면 종료코드 3, 적재된 fw/ 는 그대로" \
    "$(FAKE_FAIL=1 FAKE_KERNEL="$SMA/kern.bin" sm32_eb "$SM_W" "$SMA/boot_v0.img") $([ "$(sm32_ck "$SM_W")" = "$SM_H2" ] && echo same)" "3 same"
SM_UNPACK=""; unset FAKE_RAMDISK FAKE_DTB

# ---------------------------------------------------------------------------
hdr "carve_disasm.py: arm32 진입 점수 (ARM 상태 진입은 ARM 으로 해독)"
if python3 -c "import capstone" 2>/dev/null; then
  SM_SC="$(python3 "$S/carve_disasm.py" score_entry "$SMA/lk_ok.bin" 0x300 --arch arm32 2>&1)"
  chk "벡터 테이블 진입은 ARM 으로 해독" "$(printf '%s' "$SM_SC" | head -1 | grep -c 'isa=arm')" "1"
  chk "  벡터 b reset 점수" "$(printf '%s' "$SM_SC" | grep -c '벡터 b reset')" "1"
  chk "  벡터 슬롯이 b 로 해독됨 (Thumb 쓰레기가 아님)" \
      "$(printf '%s' "$SM_SC" | grep -A8 '^---' | grep -c ': b  ')" "8"
  SM_SC2="$(python3 "$S/carve_disasm.py" score_entry "$SMA/noentry.bin" 0x1000 --arch arm32 2>&1)"
  chk "ARM 분기로 시작하지 않는 바이트는 종전처럼 Thumb" "$(printf '%s' "$SM_SC2" | head -1 | grep -c 'isa=thumb')" "1"
else
  ok "capstone 없음 - carve_disasm 점수 시험 건너뜀"
fi

# ---------------------------------------------------------------------------
# CC2: carve_check 의 잣대는 아키텍처가 아니라 계열(--family)에 딸린다. 입력은 전부 합성이다.
hdr "carve_disasm.py --family: 계열이 잣대를 고른다 (판정 못 하면 null, 거짓이 아니다)"
export PYTHONDONTWRITEBYTECODE=1      # carve_disasm.py 가 stage_map 을 읽어 가져온다: 저장소에 바이트코드를 남기지 않는다
if python3 -c "import capstone" 2>/dev/null; then
  python3 - "$SMA" <<'PYCF'
import struct, sys
d = sys.argv[1]
def mtk(total, payload):          # 매직 · 페이로드 크기 · 확장 헤더 (페이로드 시작은 0x200)
    b = bytearray(total)
    struct.pack_into("<I", b, 0, 0x58881688)
    struct.pack_into("<I", b, 4, payload)
    struct.pack_into("<I", b, 0x30, 0x58891689)
    struct.pack_into("<I", b, 0x34, 0x200)
    return bytes(b)
def stamped(total, words):
    b = bytearray(total)
    for i, w in enumerate(words):
        b[0x100 + 0x40 * i:0x100 + 0x40 * i + len(w)] = w
    return bytes(b)
open(d + "/cf_a64.bin", "wb").write(stamped(4 * 1024 * 1024, [b"S-BOOT", b"autoboot", b"Following commands"]))
open(d + "/cf_a32.bin", "wb").write(stamped(600 * 1024, [b"Little Kernel", b"lk build"]))
open(d + "/cf_plain.bin", "wb").write(b"plain bytes with no header at all\n")
open(d + "/cf_hdr_full.img", "wb").write(mtk(0x20000, 0x10000))
open(d + "/cf_hdr_cut.img", "wb").write(mtk(0x8000, 0x10000))
PYCF
  sm32_cc() {   # $1 = 이미지, 나머지 = carve_disasm 인자 -> "is_full|basis"
    local img="$1"; shift
    local out; out="$(python3 "$S/carve_disasm.py" "$@" carve_check "$img" 2>/dev/null)"
    printf '%s|%s' "$(printf '%s\n' "$out" | sed -n 's/^is_full: //p')" "$(printf '%s\n' "$out" | sed -n 's/^is_full_basis: //p')"
  }
  chk "[계열 없음] 예전 동작: arm64 가 S-Boot 잣대를 쓴다" "$(sm32_cc "$SMA/cf_a64.bin" --arch arm64)" "True|문자열 기준"
  chk "[계열 없음] 예전 동작: arm64 로 보면 LK 는 carve 오탐 (그래서 계열이 잣대를 골라야 한다)" "$(sm32_cc "$SMA/cf_a32.bin" --arch arm64)" "False|"
  chk "[계열 없음] 예전 동작: 계열 줄이 출력에 없다" \
      "$(python3 "$S/carve_disasm.py" --arch arm64 carve_check "$SMA/cf_a64.bin" 2>/dev/null | grep -c '^family:\|^yardstick:')" "0"
  chk "exynos: 아키텍처가 arm32 여도 S-Boot 잣대" "$(sm32_cc "$SMA/cf_a64.bin" --family exynos --arch arm32)" "True|문자열 기준"
  chk "mediatek: 아키텍처가 arm64 여도 LK 잣대" "$(sm32_cc "$SMA/cf_a32.bin" --family mediatek --arch arm64)" "True|문자열 기준"
  chk "exynos: 잣대에 못 미치면 False (잣대가 말한다)" "$(sm32_cc "$SMA/cf_a32.bin" --family exynos --arch arm64)" "False|"
  chk "mediatek: 잣대에 못 미치면 False" "$(sm32_cc "$SMA/cf_plain.bin" --family mediatek --arch arm32)" "False|"
  chk "generic: 잣대도 헤더도 없으면 null (S-Boot 이미지여도 판정하지 않는다)" "$(sm32_cc "$SMA/cf_a64.bin" --family generic --arch arm64)" "null|"
  chk "generic: 문자열이 하나도 없어도 null — carve 라고 말하지 않는다" "$(sm32_cc "$SMA/cf_plain.bin" --family generic --arch arm64)" "null|"
  chk "잣대가 없는 계열(이름만 있는 다른 계열)도 null" "$(sm32_cc "$SMA/cf_a32.bin" --family unmeasured --arch arm32)" "null|"
  chk "  null 에는 이유(is_full_note)가 붙고 근거(is_full_basis)는 없다" \
      "$(python3 "$S/carve_disasm.py" --family generic carve_check "$SMA/cf_plain.bin" 2>/dev/null | grep -c '^is_full_note: .*yardstick')/$(python3 "$S/carve_disasm.py" --family generic carve_check "$SMA/cf_plain.bin" 2>/dev/null | grep -c '^is_full_basis')" "1/0"
  chk "generic: 컨테이너 헤더가 선언한 만큼 있으면 True (근거 = 컨테이너 헤더)" "$(sm32_cc "$SMA/cf_hdr_full.img" --family generic --arch arm32)" "True|컨테이너 헤더"
  chk "generic: 헤더가 선언한 것보다 짧으면 False — 헤더가 말하므로 (null 이 아니다)" "$(sm32_cc "$SMA/cf_hdr_cut.img" --family generic --arch arm32)" "False|"
  chk "mediatek: 잘린 헤더는 잣대와 무관하게 False" "$(sm32_cc "$SMA/cf_hdr_cut.img" --family mediatek --arch arm32)" "False|"
  chk "계열 이름은 대소문자를 가리지 않는다" "$(sm32_cc "$SMA/cf_a64.bin" --family EXYNOS)" "True|문자열 기준"
  chk "--family 뒤에 이름이 없으면 종료코드 1" "$(python3 "$S/carve_disasm.py" carve_check "$SMA/cf_a64.bin" --family >/dev/null 2>&1; echo $?)" "1"
  chk "  빈 이름도 거부" "$(python3 "$S/carve_disasm.py" --family '' carve_check "$SMA/cf_a64.bin" >/dev/null 2>&1; echo $?)" "1"
else
  ok "capstone 없음 - carve_check --family 시험 건너뜀"
fi

# ---------------------------------------------------------------------------
# B6: Exynos 전용 힌트(epbl · teegris · S-BOOT 프롬프트 · keystorage)는 exynos.yaml 에만 있다
hdr "profiles: generic 은 중립, Exynos 전용 힌트는 exynos.yaml 에 (옮겼지 잃지 않았다)"
chk "generic.yaml 에 Exynos 전용 낱말(epbl · teegris · S-BOOT · keystorage)이 없다" \
    "$(grep -ci 'epbl\|teegris\|S-BOOT\|keystorage' "$REPO/profiles/generic.yaml")" "0"
chk "exynos.yaml 은 그 낱말을 모두 가진다" \
    "$(for w in epbl teegris 'S-BOOT # ' keystorage; do grep -qi -- "$w" "$REPO/profiles/exynos.yaml" && echo y; done | wc -l | tr -d ' ')" "4"
chk "generic 의 표면 프롬프트 후보는 중립(# · >)이다" \
    "$(sed -n 's/^  prompt_candidates: //p' "$REPO/profiles/generic.yaml")" '["# ", "> "]'
chk "stage_map 이 읽는 generic 힌트: first_stage 에 epbl 이, secure_os 에 teegris 가 없다" \
    "$(REPO="$REPO" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PYP'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
import stage_map as sm
h = sm.load_profile_hints("generic")
print(any("epbl" in k for k in h["first_stage"]), any("teegris" in k for k in h["secure_os"]))
PYP
)" "False False"
chk "stage_map 이 읽는 exynos 힌트는 둘 다 가진다 (exynos 실행은 달라지지 않는다)" \
    "$(REPO="$REPO" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PYP'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
import stage_map as sm
h = sm.load_profile_hints("exynos")
print(any("epbl" in k for k in h["first_stage"]), any("teegris" in k for k in h["secure_os"]))
PYP
)" "True True"

# ---------------------------------------------------------------------------
hdr "실제 이미지 (SBOOT_FIXTURES 가 있을 때만)"
SM_FX="${SBOOT_FIXTURES:-}"
if [ -n "$SM_FX" ] && [ -f "$SM_FX/lk-verified.img" ] && [ -f "$SM_FX/preloader.img" ]; then
  chk "LK: 종료코드 0" "$(sm32_run "$SM_FX/lk-verified.img" "$SMA/real_lk.json" --arch arm32 --profile mediatek)" "0"
  SM_R="$SMA/real_lk.json"
  chk "LK 로드베이스" "$(sm32_j "$SM_R" 'd["stages"][0]["base"]["load_base_hex"]')" "0x48200000"
  chk "LK 진입 파일 오프셋" "$(sm32_j "$SM_R" 'd["stages"][0]["entry_pc_file_offset"]')" "512"
  chk "LK entry_pc" "$(sm32_j "$SM_R" 'd["stages"][0]["entry_pc"]')" "0x48200000"
  chk "LK confidence" "$(sm32_j "$SM_R" 'd["stages"][0]["confidence"]')" "cross_checked"
  chk "LK 앵커 리터럴 위치 (파일 0x274)" \
      "$(sm32_j "$SM_R" '[a for a in d["stages"][0]["base"]["anchors"] if a["kind"]=="self_relocation_literal"][0]["literal_file_offset"]')" "628"
  chk "LK 복사 끝 리터럴 위치 (파일 0x278)" \
      "$(sm32_j "$SM_R" '[a for a in d["stages"][0]["base"]["anchors"] if a["kind"]=="self_relocation_literal"][0]["copy_end_file_offset"]')" "632"
  chk "LK 복사 끝 − 헤더 페이로드 크기 ≤ 192" \
      "$(sm32_j "$SM_R" '[a for a in d["stages"][0]["base"]["anchors"] if a["kind"]=="self_relocation_literal"][0]["copy_end_minus_header_size"] <= 192')" "True"
  chk "LK 컨테이너 (MTK 헤더, 페이로드 0x200)" \
      "$(sm32_j "$SM_R" 'd["stages"][0]["container"]["magic"] + " " + str(d["stages"][0]["container"]["payload_offset"])')" "0x58881688 512"
  chk "LK 스테이지 이름은 헤더가 말한 이미지 이름" "$(sm32_j "$SM_R" 'd["stages"][0]["name"]')" "lk"
  chk "프리로더: 종료코드 0" "$(sm32_run "$SM_FX/preloader.img" "$SMA/real_pl.json" --arch arm32 --profile mediatek)" "0"
  SM_R="$SMA/real_pl.json"
  chk "프리로더 로드베이스" "$(sm32_j "$SM_R" 'd["stages"][0]["base"]["load_base_hex"]')" "0x200910"
  chk "프리로더 entry_pc" "$(sm32_j "$SM_R" 'd["stages"][0]["entry_pc"]')" "0x201004"
  chk "프리로더 confidence" "$(sm32_j "$SM_R" 'd["stages"][0]["confidence"]')" "cross_checked"
  chk "프리로더 GFH 는 페이로드+0x600" \
      "$(sm32_j "$SM_R" '[a for a in d["stages"][0]["base"]["anchors"] if a["kind"]=="gfh_load_addr"][0]["gfh_payload_offset"]')" "1536"
  chk "프리로더 컨테이너" "$(sm32_j "$SM_R" 'd["stages"][0]["container"]["format"] + " " + str(d["stages"][0]["container"]["payload_offset"])')" "emmc_boot 512"
  chk "detect-arch: 실제 LK 는 arm32 (벡터 테이블 + 자기재배치 스텁 + 패턴)" "$(sm32_dt "$SM_FX/lk-verified.img")" "arm32 vector_table cross_checked"
  chk "detect-arch: 실제 프리로더는 arm32 (GFH 가 선언한 진입 + crt0)" "$(sm32_dt "$SM_FX/preloader.img")" "arm32 gfh cross_checked"
  chk "  실제 프리로더에서 AArch64 시그니처는 찾지 않는다" \
      "$(sm32_det "$SM_FX/preloader.img" 'int(not any("AArch64 진입 스텁" in b for b in d["basis"]))')" "1"
  if [ -f "$SM_FX/boot_head.img" ]; then
    chk "detect-arch: 헤더뿐인 boot_head.img 는 unknown (부트로더 코드가 아니다)" "$(sm32_dt "$SM_FX/boot_head.img")" "unknown none unconfirmed"
  fi
  chk "프리로더 점프 리터럴이 근거 (옛 오류값 0x200f10 은 지지하지 못한다)" \
      "$(REPO="$REPO" PYTHONDONTWRITEBYTECODE=1 python3 - "$SM_FX/preloader.img" <<'PYR'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
import stage_map as sm
d = open(sys.argv[1], "rb").read()
p = d[0x200:]
idx = sm.pool_index(p[:len(p.rstrip(b"\x00\xff"))])
shifts = list(sm.CONTROL_SHIFTS) + [0x200, 0x600]
good = sm.landing_verdict(idx, 0x200910, shifts)["passed"]
bad = sm.landing_verdict(idx, 0x200f10, shifts)["passed"]
print(good, bad)
PYR
)" "True False"
  if [ -f "$SM_FX/boot_head.img" ]; then
    SM_WD="$SMA/ex_real"; mkdir -p "$SM_WD"
    UNPACK_BOOTIMG=/nonexistent bash "$SM_EB" "$SM_WD" "$SM_FX/boot_head.img" >"$SM_WD/log.txt" 2>&1
    chk "boot_head.img (헤더 v2): 폴백이 page 2048 로 읽음" "$(grep -c 'header v2 page 2048' "$SM_WD/log.txt")" "1"
  fi
else
  ok "SBOOT_FIXTURES 없음 - 실제 이미지 시험 건너뜀 (합성 시험만 수행)"
fi

rm -rf "$SMA"
parts_finish
