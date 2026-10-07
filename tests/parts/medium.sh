#!/usr/bin/env bash
# tests/parts/medium.sh - 부팅 매체 합성(build_lu.py)과 매체 종류 판정(detect_medium.py).
#
# 단독 실행: bash tests/parts/medium.sh
# 실물 이미지는 환경변수가 가리킬 때만 쓴다 (저장소 시험은 합성 입력만으로 통과해야 한다):
#   SBOOT_MT_FIXTURES  lk-verified.img 가 있는 폴더 (DTB 를 품은 부트로더 이미지)
#   SBOOT_MT_CONSOLE   부트로더 UART 로그 (호스트 진단 줄이 섞여 있어도 된다)
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -n "${PARTS_STANDALONE:-}" ] && trap 'rm -rf "$ROOT"' EXIT

hdr "매체 합성 — kind · lba · medium · 출처 기록"

MD="$ROOT/medium_part"; rm -rf "$MD"; mkdir -p "$MD"
BLU="$S/build_lu.py"
DET="$S/detect_medium.py"
md_get() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

# --- 도우미 (시험 전용) ------------------------------------------------------
# 원본 바이트는 길이마다 다른 규칙으로 만든다 (같은 값이 우연히 겹쳐 통과하지 않도록).
cat > "$MD/mkfix.py" <<'PY'
import json, os, sys
wd = sys.argv[1]
os.makedirs(os.path.join(wd, "fw"), exist_ok=True)
def put(rel, n, a, b):
    with open(os.path.join(wd, rel), "wb") as fh:
        fh.write(bytes((i * a + b) & 0xFF for i in range(n)))
put("fw/boot.img", 10000, 7, 3)
put("fw/vbmeta.img", 5000, 13, 5)
put("fw/pit.bin", 3000, 11, 1)
put("fw/chain.bin", 2048, 17, 9)
put("fw/mod.img", 1500, 19, 2)
PY

cat > "$MD/gpt_inspect.py" <<'PY'
import binascii, json, struct, sys
img, block = sys.argv[1], int(sys.argv[2])
d = open(img, "rb").read()
crc = lambda b: binascii.crc32(b) & 0xFFFFFFFF
def header_ok(h):
    c = struct.unpack_from("<I", h, 16)[0]
    z = bytearray(h); z[16:20] = bytes(4)
    return h[:8] == b"EFI PART" and crc(bytes(z)) == c
h = d[block:block + 92]
ent_lba, n, esz, ecrc = struct.unpack_from("<QIII", h, 72)
arr = d[ent_lba * block:ent_lba * block + n * esz]
parts = []
for i in range(n):
    e = arr[i * esz:(i + 1) * esz]
    if e[:16] == bytes(16):
        continue
    s, en = struct.unpack_from("<QQ", e, 32)
    parts.append({"name": e[56:128].decode("utf-16-le").rstrip("\0"), "start": s, "end": en})
last = len(d) // block - 1
bh = d[last * block:last * block + 92]
b_ent_lba = struct.unpack_from("<Q", bh, 72)[0]
print(json.dumps({
    "hdr_ok": header_ok(h), "array_ok": crc(arr) == ecrc,
    "backup_ok": header_ok(bh) and crc(d[b_ent_lba * block:b_ent_lba * block + n * esz]) == ecrc,
    "mbr_ok": d[510:512] == b"\x55\xaa" and d[450] == 0xEE,
    "total": len(d), "parts": parts}))
PY

cat > "$MD/region.py" <<'PY'
# region.py <img> <offset> <length> [<src>] -> zero | src+pad0 | mismatch
import sys
img, off, ln = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = open(img, "rb").read()[off:off + ln]
if len(sys.argv) < 5:
    print("zero" if len(d) == ln and not any(d) else "mismatch")
else:
    s = open(sys.argv[4], "rb").read()
    print("src+pad0" if d[:len(s)] == s and not any(d[len(s):]) and len(d) == ln else "mismatch")
PY

cat > "$MD/sha.py" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY

gpt() { python3 "$MD/gpt_inspect.py" "$1" "$2"; }
gpt_start() { echo "$1" | md_get "[p['start'] for p in d['parts'] if p['name']=='$2'][0]"; }

# =============================================================================
# 1. kind 가 섞인 eMMC 매니페스트
EW="$MD/emmc"; mkdir -p "$EW"; python3 "$MD/mkfix.py" "$EW"
cat > "$EW/lu_manifest.json" <<'EOF'
{"medium": "emmc",
 "partitions": [
  {"name": "boot",       "source": "fw/boot.img"},
  {"name": "misc",       "kind": "zero", "size": 1048576},
  {"name": "vbmeta",     "source": "fw/vbmeta.img", "size": 65536},
  {"name": "vendor_img", "kind": "modified", "source": "fw/mod.img"},
  {"name": "prism",      "kind": "forged", "source": "fw/chain.bin"},
  {"name": "boot_para",  "kind": "synthesized", "source": "fw/pit.bin", "lba": 4096, "vendor": "acme"},
  {"name": "userdata",   "kind": "zero", "size": 8192}
 ]}
EOF
EJ=$(python3 "$BLU" "$EW" --out "$EW/fw/lu0.img" 2>/dev/null)
chk "eMMC 매니페스트로 합성됨"         "$(echo "$EJ" | md_get 'd["ok"]')" "True"
chk "  medium 은 매니페스트에서"       "$(echo "$EJ" | md_get '(d["medium"], d["medium_source"])')" "('emmc', 'manifest')"
chk "  논리 블록 512"                  "$(echo "$EJ" | md_get 'd["block_size"]')" "512"
G=$(gpt "$EW/fw/lu0.img" 512)
chk "  GPT 헤더·배열 CRC"              "$(echo "$G" | md_get '(d["hdr_ok"], d["array_ok"])')" "(True, True)"
chk "  백업 GPT"                       "$(echo "$G" | md_get 'd["backup_ok"]')" "True"
chk "  보호 MBR"                       "$(echo "$G" | md_get 'd["mbr_ok"]')" "True"
chk "  파티션 이름·순서"               "$(echo "$G" | md_get '[p["name"] for p in d["parts"]]')" \
    "['boot', 'misc', 'vbmeta', 'vendor_img', 'prism', 'boot_para', 'userdata']"
chk "  고정 lba 에 놓임"               "$(gpt_start "$G" boot_para)" "4096"
# 고정 위치 뒤에서 이어 붙는다: boot_para(3000 B = 6 블록) 다음은 4102
chk "  고정 위치 뒤에서 이어짐"        "$(gpt_start "$G" userdata)" "4102"
chk "  첫 파티션은 배열 바로 뒤"       "$(gpt_start "$G" boot)" "34"
chk "  총 크기 = 마지막 블록 + 백업"   "$(echo "$G" | md_get 'd["total"]')" "$(( (4102 + 16 + 32 + 1) * 512 ))"
OFF() { echo "$G" | md_get "[p['start'] for p in d['parts'] if p['name']=='$1'][0]*512"; }
chk "  firmware 바이트가 그대로"       "$(python3 "$MD/region.py" "$EW/fw/lu0.img" "$(OFF boot)" 10000 "$EW/fw/boot.img")" "src+pad0"
chk "  size 가 원본보다 크면 0 으로 채움" "$(python3 "$MD/region.py" "$EW/fw/lu0.img" "$(OFF vbmeta)" 65536 "$EW/fw/vbmeta.img")" "src+pad0"
chk "  zero 파티션은 0"                "$(python3 "$MD/region.py" "$EW/fw/lu0.img" "$(OFF misc)" 1048576)" "zero"
chk "  synthesized 바이트"             "$(python3 "$MD/region.py" "$EW/fw/lu0.img" "$(OFF boot_para)" 3072 "$EW/fw/pit.bin")" "src+pad0"
chk "  forged 바이트"                  "$(python3 "$MD/region.py" "$EW/fw/lu0.img" "$(OFF prism)" 2048 "$EW/fw/chain.bin")" "src+pad0"

# 출처 기록 (C11)
PV="$EW/fw/lu_provenance.json"
chk "출처 기록이 이미지 옆에 생김"      "$([ -f "$PV" ] && echo yes || echo no)" "yes"
chk "  결과가 그 경로를 알림"          "$(echo "$EJ" | md_get 'd["provenance"].endswith("/fw/lu_provenance.json")')" "True"
chk "  이름 → kind 표"                 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["partitions"])' "$PV")" \
    "{'boot': 'firmware', 'misc': 'zero', 'vbmeta': 'firmware', 'vendor_img': 'modified', 'prism': 'forged', 'boot_para': 'synthesized', 'userdata': 'zero'}"
chk "  종류별 개수"                    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["counts"])' "$PV")" \
    "{'firmware': 2, 'zero': 2, 'synthesized': 1, 'forged': 1, 'modified': 1}"
chk "  vendor·고정 lba·오프셋 기록"    "$(python3 -c '
import json,sys
d=[x for x in json.load(open(sys.argv[1]))["details"] if x["name"]=="boot_para"][0]
print((d["vendor"], d["fixed_lba"], d["offset"], d["bytes"]))' "$PV")" "('acme', True, 2097152, 3000)"
chk "  블록·매체 기록"                 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d["medium"], d["block_size"], d["image"]))' "$PV")" \
    "('emmc', 512, 'lu0.img')"

# 재빌드는 바이트 단위로 같다 (GUID 가 결정적이라는 약속)
H1=$(python3 "$MD/sha.py" "$EW/fw/lu0.img")
python3 "$BLU" "$EW" --out "$EW/fw/lu0_again.img" >/dev/null 2>&1
chk "같은 입력의 재빌드는 동일 바이트"  "$(python3 "$MD/sha.py" "$EW/fw/lu0_again.img")" "$H1"

# =============================================================================
# 2. 하위 호환 — kind 없는 매니페스트는 v0.27.0 의 이미지와 바이트 단위로 같다
# 기대 해시는 v0.27.0 의 build_lu.py 가 같은 입력으로 만든 값이다 (고정 입력, 결정적 GUID).
GW="$MD/gold"; mkdir -p "$GW/fw" "$GW/02_unpacked"
python3 - "$GW" <<'PY'
import json, os, sys
wd = sys.argv[1]
open(os.path.join(wd, "fw/boot.img"), "wb").write(bytes((i * 7 + 3) & 0xFF for i in range(10000)))
open(os.path.join(wd, "fw/vbmeta.img"), "wb").write(bytes((i * 13 + 5) & 0xFF for i in range(5000)))
open(os.path.join(wd, "02_unpacked/param.bin"), "wb").write(bytes(8192))
json.dump({"block_size": 4096, "partitions": [
    {"name": "boot", "source": "fw/boot.img"},
    {"name": "vbmeta", "source": "fw/vbmeta.img"},
    {"name": "param", "source": "02_unpacked/param.bin"}]}, open(os.path.join(wd, "lu_manifest.json"), "w"))
json.dump({"uart": "console=ttyS0,115200n8"}, open(os.path.join(wd, "cmdline_plan.json"), "w"))
PY
GOLD4096="7ff13e3ae1ad53770405c5d8d0dca3392ec19aa35034d5295d282d8d2b8585bf"
GOLD512="1b3e570a8c42a599f419350451bb4d95b38815692be012424e78fb088c21b6f9"
GJ=$(python3 "$BLU" "$GW" --out "$GW/fw/a.img" 2>/dev/null)
chk "kind 없는 매니페스트: v0.27.0 과 동일 이미지" "$(python3 "$MD/sha.py" "$GW/fw/a.img")" "$GOLD4096"
chk "  medium 기본값 ufs (4096)"       "$(echo "$GJ" | md_get '(d["medium"], d["medium_source"], d["block_size"])')" "('ufs', 'default', 4096)"
chk "  기존 출력 키 유지"              "$(echo "$GJ" | md_get 'all(k in d for k in ("ok","image","block_size","total_bytes","names_derived","manifest","partitions","missing_sources","cmdline_written","cmdline","cmdline_source"))')" "True"
chk "  이름 없는 plan 은 예전 동작이되 추측이라 밝힘" "$(echo "$GJ" | md_get '(d["cmdline_target"]["basis"], "warning_cmdline_target" in d, "warning_medium" in d)')" "('legacy_default', True, True)"
chk "  전부 firmware 로 기록"          "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["partitions"])' "$GW/fw/lu_provenance.json")" \
    "{'boot': 'firmware', 'vbmeta': 'firmware', 'param': 'firmware'}"
chk "  커맨드라인 주입을 기록"         "$(python3 -c '
import json,sys
i=json.load(open(sys.argv[1]))["injected"]
print([(x["partition"], x["what"], x["offset"]) for x in i])' "$GW/fw/lu_provenance.json")" "[('param', 'cmdline', 45056)]"
mv "$GW/lu_manifest.json" "$GW/lu_manifest.off"
python3 "$BLU" "$GW" --out "$GW/fw/b.img" >/dev/null 2>&1
chk "매니페스트 없음(기본 배치)도 동일"  "$(python3 "$MD/sha.py" "$GW/fw/b.img")" "$GOLD4096"
python3 "$BLU" "$GW" --out "$GW/fw/c.img" --block-size 512 >/dev/null 2>&1
chk "--block-size 512 도 동일"           "$(python3 "$MD/sha.py" "$GW/fw/c.img")" "$GOLD512"
python3 "$BLU" "$GW" --out "$GW/fw/d.img" --medium ufs >/dev/null 2>&1
chk "--medium ufs 는 현행과 같음"        "$(python3 "$MD/sha.py" "$GW/fw/d.img")" "$GOLD4096"

# =============================================================================
# 3. --medium emmc
MJ=$(python3 "$BLU" "$GW" --out "$GW/fw/e.img" --medium emmc 2>/dev/null)
chk "--medium emmc 는 512 B 블록"        "$(echo "$MJ" | md_get '(d["medium"], d["medium_source"], d["block_size"])')" "('emmc', 'cli', 512)"
chk "  기본 배치에서 Exynos 이름은 뺌"   "$(echo "$MJ" | md_get '[p["name"] for p in d["partitions"]]')" "['boot', 'vbmeta']"
chk "  이름 미도출 경고는 그대로"        "$(echo "$MJ" | md_get '"warning" in d and "Exynos" in d["warning"]')" "True"
chk "  PARAM 이 없으면 커맨드라인 못 심음" "$(echo "$MJ" | md_get '(d["cmdline_written"], "warning_cmdline" in d)')" "(False, True)"
chk "  GPT 가 512 B 블록 기준"           "$(gpt "$GW/fw/e.img" 512 | md_get 'd["hdr_ok"] and d["array_ok"] and d["backup_ok"]')" "True"
RJ=$(python3 "$BLU" "$EW" --out "$EW/fw/f.img" --medium ufs 2>/dev/null)
chk "CLI 가 매니페스트의 medium 을 이김" "$(echo "$RJ" | md_get '(d["medium"], d["medium_source"], d["block_size"])')" "('ufs', 'cli', 4096)"
BJ2=$(python3 "$BLU" "$EW" --out "$EW/fw/g.img" --block-size 4096 2>/dev/null)
chk "eMMC 에 4096 블록은 거부"           "$(echo "$BJ2" | md_get 'd["ok"]')" "False"

# =============================================================================
# 4. 잘못된 매니페스트는 추측하지 않고 이유를 밝힌다
bad_case() {   # $1=이름 $2=partitions JSON [$3=추가 최상위 JSON 조각] -> build_lu 결과 JSON
  local w="$MD/bad_$1"; mkdir -p "$w"; python3 "$MD/mkfix.py" "$w"
  printf '{"medium":"emmc"%s,"partitions":%s}\n' "${3:-}" "$2" > "$w/lu_manifest.json"
  python3 "$BLU" "$w" --out "$w/fw/lu0.img" 2>/dev/null
}
J=$(bad_case kind '[{"name":"boot","source":"fw/boot.img","kind":"bogus"}]')
chk "알 수 없는 kind 는 거부"            "$(echo "$J" | md_get '(d["ok"], "bogus" in " ".join(d["errors"]))')" "(False, True)"
J=$(bad_case zsrc '[{"name":"misc","kind":"zero","source":"fw/boot.img","size":512}]')
chk "zero 가 source 를 가지면 거부"      "$(echo "$J" | md_get '(d["ok"], "source" in " ".join(d["errors"]))')" "(False, True)"
J=$(bad_case trunc '[{"name":"boot","source":"fw/boot.img","size":512}]')
chk "size 가 원본보다 작으면 거부"       "$(echo "$J" | md_get '(d["ok"], "잘라" in d["detail"])')" "(False, True)"
J=$(bad_case overlap '[{"name":"boot","source":"fw/boot.img"},{"name":"boot_para","kind":"synthesized","source":"fw/pit.bin","lba":40}]')
chk "고정 lba 가 앞 파티션과 겹치면 거부" "$(echo "$J" | md_get '(d["ok"], "겹칩" in d["detail"])')" "(False, True)"
J=$(bad_case lbatype '[{"name":"boot","source":"fw/boot.img","lba":"0x100"}]')
chk "lba 가 정수가 아니면 거부"          "$(echo "$J" | md_get '(d["ok"], "lba" in " ".join(d["errors"]))')" "(False, True)"
J=$(bad_case noname '[{"source":"fw/boot.img"}]')
chk "name 이 없으면 거부 (역추적 없음)"   "$(echo "$J" | md_get 'd["ok"]')" "False"
J=$(bad_case medium '[{"name":"boot","source":"fw/boot.img"}]' ',"extra":1')
chk "정상 항목은 통과 (대조군)"          "$(echo "$J" | md_get 'd["ok"]')" "True"
J=$(bad_case badmedium '[{"name":"boot","source":"fw/boot.img"}]'); W="$MD/bad_badmedium"
printf '{"medium":"nvme","partitions":[{"name":"boot","source":"fw/boot.img"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "알 수 없는 medium 은 거부"          "$(echo "$J" | md_get 'd["ok"]')" "False"
printf '{"medium":"unknown","partitions":[{"name":"boot","source":"fw/boot.img"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "medium=unknown 은 기본값으로 가되 밝힘" "$(echo "$J" | md_get '(d["ok"], d["medium"], d["medium_source"], "warning_medium" in d)')" "(True, 'ufs', 'default', True)"

# 129 개는 GPT 엔트리 수를 넘는다 (배열 밖으로 새지 않고 거부)
W="$MD/many"; mkdir -p "$W/fw"; python3 "$MD/mkfix.py" "$W"
python3 - "$W" <<'PY'
import json, sys
json.dump({"medium": "emmc", "partitions": [{"name": f"p{i}", "kind": "zero", "size": 512} for i in range(129)]},
          open(sys.argv[1] + "/lu_manifest.json", "w"))
PY
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "엔트리 수 초과는 거부"              "$(echo "$J" | md_get '(d["ok"], "128" in d["detail"])')" "(False, True)"

# size 없는 zero 는 1 블록으로 만들고 밝힌다
W="$MD/zsize"; mkdir -p "$W/fw"; python3 "$MD/mkfix.py" "$W"
printf '{"medium":"emmc","partitions":[{"name":"boot","source":"fw/boot.img"},{"name":"frp","kind":"zero"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "size 없는 zero: 1 블록 + 경고"      "$(echo "$J" | md_get '([p["lbas"] for p in d["partitions"] if p["name"]=="frp"][0], "warning_zero_size" in d)')" "(1, True)"

# 원본이 없는 항목은 건너뛰고 밝힌다 — 출처 기록에도 없다
W="$MD/miss"; mkdir -p "$W/fw"; python3 "$MD/mkfix.py" "$W"
printf '{"medium":"emmc","partitions":[{"name":"boot","source":"fw/boot.img"},{"name":"optics","kind":"forged","source":"fw/nope.bin"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "원본 없는 forged 는 건너뛰고 밝힘"  "$(echo "$J" | md_get '(d["ok"], len(d["missing_sources"]), "warning_missing" in d)')" "(True, 1, True)"
chk "  출처 기록에도 없음"               "$(python3 -c 'import json,sys; print(list(json.load(open(sys.argv[1]))["partitions"]))' "$W/fw/lu_provenance.json")" "['boot']"

# 같은 이름이 두 번이면 덜 믿는 쪽을 남긴다 (우리 바이트가 firmware 로 세어지지 않게)
W="$MD/dup"; mkdir -p "$W/fw"; python3 "$MD/mkfix.py" "$W"
printf '{"medium":"emmc","partitions":[{"name":"x","source":"fw/boot.img"},{"name":"x","kind":"forged","source":"fw/chain.bin"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "이름 중복: 경고 + 덜 믿는 kind"     "$(echo "$J" | md_get '"warning_duplicate_names" in d')$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["partitions"]["x"])' "$W/fw/lu_provenance.json")" "Trueforged"

# 총 크기 고정 경고는 그대로 (v0.27.0 동작)
W="$MD/pin"; mkdir -p "$W/fw"; python3 "$MD/mkfix.py" "$W"
printf '{"medium":"emmc","total_bytes":1,"partitions":[{"name":"boot","source":"fw/boot.img"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "총 크기 변화 경고 유지"             "$(echo "$J" | md_get '"warning_size" in d')" "True"

# =============================================================================
# 5. 매체 종류를 정하지 않았을 때 (M1): 키를 빼는 것이 안내된 경로이므로 경고가 같아야 한다
W="$MD/nomedium"; mkdir -p "$W/fw"; python3 "$MD/mkfix.py" "$W"
printf '{"partitions":[{"name":"boot","source":"fw/boot.img"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "medium 키가 없으면: 기본값으로 가되 경고"   "$(echo "$J" | md_get '(d["ok"], d["medium"], d["medium_source"], d["block_size"], "warning_medium" in d)')" "(True, 'ufs', 'default', 4096, True)"
chk "  경고가 무엇이 정하는지 말함"             "$(echo "$J" | md_get '("detect_medium.py" in d["warning_medium"], "첫 부트로더 로그" in d["warning_medium"], "medium 이 없" in d["warning_medium"])')" "(True, True, True)"
rm -f "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "매니페스트가 없어도 같은 경고"             "$(echo "$J" | md_get '(d["medium_source"], "warning_medium" in d)')" "('default', True)"
printf '{"medium":"emmc","partitions":[{"name":"boot","source":"fw/boot.img"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "medium 이 정해지면 경고 없음 (대조군)"     "$(echo "$J" | md_get '(d["medium_source"], "warning_medium" in d)')" "('manifest', False)"
printf '{"partitions":[{"name":"boot","source":"fw/boot.img"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" --medium emmc 2>/dev/null)
chk "키가 없어도 --medium 을 주면 경고 없음"    "$(echo "$J" | md_get '(d["medium"], d["medium_source"], "warning_medium" in d)')" "('emmc', 'cli', False)"
printf '{"medium":"unknown","partitions":[{"name":"boot","source":"fw/boot.img"}]}\n' > "$W/lu_manifest.json"
J=$(python3 "$BLU" "$W" --out "$W/fw/lu0.img" 2>/dev/null)
chk "unknown 도 같은 안내를 함"                 "$(echo "$J" | md_get '("detect_medium.py" in d["warning_medium"], "unknown" in d["warning_medium"])')" "(True, True)"

# =============================================================================
# 6. 커맨드라인이 가는 파티션은 plan 이 말한다 (M2)
# 한 매체에 "param" 과 다른 이름의 파티션이 함께 있다: 어느 쪽에 쓰는가가 plan 의 진술로
# 갈리는지 본다. 쓰이지 않은 파티션은 원본 바이트 그대로여야 한다.
cat > "$MD/cstr.py" <<'PY'
# cstr.py <img> <offset> -> the NUL-terminated string at that offset
import sys
d = open(sys.argv[1], "rb").read()[int(sys.argv[2]):][:200]
print(d.split(b"\0")[0].decode("latin-1"))
PY
cat > "$MD/same.py" <<'PY'
# same.py <img> <img_offset> <length> <src> <src_offset> -> same | diff
import sys
img, off, ln, src, so = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
a = open(img, "rb").read()[off:off + ln]
b = open(src, "rb").read()[so:so + ln]
print("same" if a == b and len(a) == ln else "diff")
PY
CMD='console=ttyX0,115200n8 earlycon=synth'
UL='"uart":"'"$CMD"'"'
CLP='[{"name":"boot","source":"fw/boot.img"},{"name":"bootargs_a","source":"fw/chain.bin"},{"name":"param","source":"fw/mod.img"}]'
cl_run() {   # $1=이름 $2=plan 본문 ("-" 이면 파일 없음) [$3=매니페스트 추가 조각] [$4=partitions JSON] -> CJ CIMG CPV CG
  local w="$MD/cl_$1"; rm -rf "$w"; mkdir -p "$w"; python3 "$MD/mkfix.py" "$w"
  printf '{"medium":"emmc"%s,"partitions":%s}\n' "${3:-}" "${4:-$CLP}" > "$w/lu_manifest.json"
  if [ "$2" != "-" ]; then printf '%s\n' "$2" > "$w/cmdline_plan.json"; fi
  CJ=$(python3 "$BLU" "$w" --out "$w/fw/lu0.img" 2>/dev/null)
  CIMG="$w/fw/lu0.img"; CPV="$w/fw/lu_provenance.json"; CW="$w"
  CG=$(gpt "$CIMG" 512 2>/dev/null || echo '{"parts":[]}')
}
cl_start() { echo "$CG" | md_get "[p['start'] for p in d['parts'] if p['name']=='$1'][0]*512"; }
cl_intact() {   # $1=파티션 $2=원본 $3=길이(블록 단위로 올린 크기) -> src+pad0 | mismatch
  python3 "$MD/region.py" "$CIMG" "$(cl_start "$1")" "$3" "$CW/fw/$2"; }
cl_inj() { python3 -c '
import json,sys
print([(x["partition"], x["what"], x["basis"]) for x in json.load(open(sys.argv[1]))["injected"]])' "$CPV"; }
cl_json() { echo "$CJ" | md_get "$1"; }

# 6-1. plan 이 partition 으로 적은 곳에 쓴다 — 이름이 param 이 아니어도
cl_run t1 "{$UL,\"partition\":\"bootargs_a\"}"
chk "plan.partition 이 가리킨 파티션에 씀"     "$(cl_json '(d["cmdline_written"], d["cmdline_target"]["partition"], d["cmdline_target"]["basis"], d["cmdline_target"]["offset"])')" "(True, 'bootargs_a', 'plan.partition', 0)"
chk "  그 자리에 실제로 있음"                  "$(python3 "$MD/cstr.py" "$CIMG" "$(cl_start bootargs_a)")" "$CMD"
chk "  param 은 원본 그대로"                   "$(cl_intact param mod.img 1536)" "src+pad0"
chk "  boot 도 원본 그대로"                    "$(cl_intact boot boot.img 10240)" "src+pad0"
chk "  출처 기록에 파티션 이름과 근거"         "$(cl_inj)" "[('bootargs_a', 'cmdline', 'plan.partition')]"
chk "  기록된 오프셋이 이미지와 일치"          "$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1]))["injected"][0]["offset"])' "$CPV")" "$(cl_start bootargs_a)"
chk "  추측 경고가 없음"                       "$(cl_json '("warning_cmdline_target" in d, "warning_cmdline" in d)')" "(False, False)"

# 6-2. source 가 파티션을 가리키면 (현행 가이드의 "PARAM partition")
cl_run t2 '{'"$UL"',"source":"PARAM partition"}'
chk "source=\"PARAM partition\" 은 param 에 씀"  "$(cl_json '(d["cmdline_written"], d["cmdline_target"]["partition"], d["cmdline_target"]["basis"])')" "(True, 'param', 'plan.source')"
chk "  bootargs_a 는 원본 그대로"              "$(cl_intact bootargs_a chain.bin 2048)" "src+pad0"
chk "  근거가 plan 이라 추측 경고 없음"        "$(cl_json '"warning_cmdline_target" in d')" "False"
cl_run t2b '{'"$UL"',"source":"partition: bootargs_a"}'
chk "source 가 다른 파티션 이름이면 그쪽에 씀"   "$(cl_json '(d["cmdline_target"]["partition"], d["cmdline_target"]["basis"])')" "('bootargs_a', 'plan.source')"
chk "  param 은 원본 그대로"                   "$(cl_intact param mod.img 1536)" "src+pad0"

# 6-3. source 가 파티션이 아니면 아무것도 쓰지 않는다 — 매니페스트에 param 이 있어도 (감사 지적)
cl_run t3 '{'"$UL"',"source":"lk built-in command line"}'
chk "파티션이 아닌 source: 쓰지 않음"          "$(cl_json '(d["ok"], d["cmdline_written"], d["cmdline"], d["cmdline_target"])')" "(True, False, None, None)"
chk "  param 은 원본 그대로 (덮어쓰지 않음)"   "$(cl_intact param mod.img 1536)" "src+pad0"
chk "  bootargs_a 도 원본 그대로"              "$(cl_intact bootargs_a chain.bin 2048)" "src+pad0"
chk "  이유를 밝힘 (source 문구 포함)"         "$(cl_json '("warning_cmdline" in d and "lk built-in command line" in d["warning_cmdline"])')" "True"
chk "  출처 기록에 주입 없음"                  "$(cl_inj)" "[]"
cl_run t3b '{'"$UL"',"source":"boot image header"}'
chk "source 에 파티션 이름이 낱말로 끼어 있어도 안 씀" "$(cl_json '(d["cmdline_written"], "warning_cmdline" in d)')" "(False, True)"
chk "  boot 는 원본 그대로"                    "$(cl_intact boot boot.img 10240)" "src+pad0"

# 6-4. plan 이 아무것도 말하지 않으면: 예전 동작(param)은 남기되 추측이라고 밝힌다
cl_run t4 "{$UL}"
chk "이름 없는 plan: param 에 쓰되 근거를 legacy 로"  "$(cl_json '(d["cmdline_written"], d["cmdline_target"]["partition"], d["cmdline_target"]["basis"])')" "(True, 'param', 'legacy_default')"
chk "  추측이라는 경고가 따로 있음"            "$(cl_json '("warning_cmdline_target" in d and "도출한 것이 아닙니다" in d["warning_cmdline_target"])')" "True"
chk "  출처 기록에도 근거가 남음"              "$(cl_inj)" "[('param', 'cmdline', 'legacy_default')]"
cl_run t5 "{$UL}" "" '[{"name":"boot","source":"fw/boot.img"},{"name":"bootargs_a","source":"fw/chain.bin"}]'
chk "이름 없는 plan + param 없음: 못 쓰고 경고"  "$(cl_json '(d["ok"], d["cmdline_written"], "warning_cmdline" in d, "warning_cmdline_target" in d)')" "(True, False, True, False)"
chk "  다른 파티션을 짐작해 쓰지 않음"          "$(cl_intact bootargs_a chain.bin 2048)$(cl_intact boot boot.img 10240)" "src+pad0src+pad0"
chk "  경고가 찾은 이름을 밝힘"                "$(cl_json '"param" in d["warning_cmdline"]')" "True"

# 6-5. 쓸 수 없는 plan 은 이유와 함께 건너뛴다
cl_run t6 "{$UL,\"partition\":\"nvram\"}"
chk "plan 이 말한 파티션이 매체에 없음: 경고"   "$(cl_json '(d["cmdline_written"], "nvram" in d["warning_cmdline"])')" "(False, True)"
chk "  param 으로 바꿔 쓰지 않음"              "$(cl_intact param mod.img 1536)" "src+pad0"
cl_run t7 "{$UL,\"partition\":\"\"}"
chk "빈 partition 은 거부"                     "$(cl_json '(d["cmdline_written"], "partition" in d["warning_cmdline"])')" "(False, True)"
cl_run t8 "{$UL,\"partition\":\"PARAM\"}"
chk "partition 은 대소문자를 가리지 않음"       "$(cl_json '(d["cmdline_written"], d["cmdline_target"]["partition"])')" "(True, 'param')"
cl_run t9 '{"default":"console=ram"}'
chk "uart 줄이 없는 plan: 쓰지 않고 밝힘"       "$(cl_json '(d["ok"], d["cmdline_written"], "uart" in d["warning_cmdline"])')" "(True, False, True)"
cl_run t10 '{not json'
chk "읽지 못한 plan: 경고 (조용히 넘기지 않음)"  "$(cl_json '(d["ok"], d["cmdline_written"], "읽지 못" in d["warning_cmdline"])')" "(True, False, True)"
cl_run t11 '[1,2]'
chk "객체가 아닌 plan: 경고"                   "$(cl_json '(d["ok"], "객체" in d["warning_cmdline"])')" "(True, True)"
cl_run t12 "{$UL,\"partition\":\"bootargs_a\"}" "" '[{"name":"boot","source":"fw/boot.img"},{"name":"bootargs_a","kind":"zero","size":4096}]'
chk "zero 파티션에도 쓸 수 있음"               "$(python3 "$MD/cstr.py" "$CIMG" "$(cl_start bootargs_a)")" "$CMD"
chk "  zero 로 기록되어 있어도 주입을 밝힘"     "$(cl_inj)" "[('bootargs_a', 'cmdline', 'plan.partition')]"

# 6-6. offset: 파티션 처음이 아니라 plan 이 말한 곳에
cl_run t13 "{$UL,\"partition\":\"bootargs_a\",\"offset\":512}"
chk "offset 에 씀"                              "$(python3 "$MD/cstr.py" "$CIMG" "$(( $(cl_start bootargs_a) + 512 ))")" "$CMD"
chk "  앞 512 B 는 원본 그대로"                 "$(python3 "$MD/same.py" "$CIMG" "$(cl_start bootargs_a)" 512 "$CW/fw/chain.bin" 0)" "same"
chk "  기록된 오프셋 = 시작 + offset"           "$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1]))["injected"][0]["offset"])' "$CPV")" "$(( $(cl_start bootargs_a) + 512 ))"
chk "  결과의 target 에 offset"                 "$(cl_json 'd["cmdline_target"]["offset"]')" "512"
cl_run t14 "{$UL,\"partition\":\"bootargs_a\",\"offset\":4096}"
chk "파티션 밖으로 나가는 offset 은 쓰지 않음"   "$(cl_json '(d["cmdline_written"], "크지 않습니다" in d["warning_cmdline"])')" "(False, True)"
chk "  원본 그대로"                            "$(cl_intact bootargs_a chain.bin 2048)" "src+pad0"
cl_run t15 "{$UL,\"partition\":\"bootargs_a\",\"offset\":\"abc\"}"
chk "정수가 아닌 offset 은 거부"                "$(cl_json '(d["cmdline_written"], "offset" in d["warning_cmdline"])')" "(False, True)"
cl_run t15b "{$UL,\"partition\":\"bootargs_a\",\"offset\":-1}"
chk "음수 offset 은 거부"                      "$(cl_json 'd["cmdline_written"]')" "False"

# 6-7. 우선순위: partition > source > 매니페스트 cmdline_partition > (예전 동작)
cl_run t16 '{'"$UL"',"partition":"bootargs_a","source":"PARAM partition"}'
chk "partition 이 source 보다 앞"               "$(cl_json '(d["cmdline_target"]["partition"], d["cmdline_target"]["basis"])')" "('bootargs_a', 'plan.partition')"
cl_run t17 "{$UL}" ',"cmdline_partition":"bootargs_a"'
chk "plan 이 침묵하면 매니페스트 cmdline_partition"  "$(cl_json '(d["cmdline_target"]["partition"], d["cmdline_target"]["basis"], "warning_cmdline_target" in d)')" "('bootargs_a', 'manifest.cmdline_partition', False)"
chk "  param 은 원본 그대로"                   "$(cl_intact param mod.img 1536)" "src+pad0"
cl_run t18 '{'"$UL"',"source":"lk built-in command line"}' ',"cmdline_partition":"bootargs_a"'
chk "plan 이 파티션 아님이라 했으면 매니페스트가 못 뒤집음" "$(cl_json '(d["cmdline_written"], "warning_cmdline" in d)')" "(False, True)"

# 6-8. 이름 풀이의 경계 (함수 단위)
PN=$(python3 - "$S" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import build_lu as b
print([b.partition_named_by(t, n) for t, n in (
    ("PARAM partition", ["boot", "param"]),
    ("partition: up_param", ["param", "up_param"]),
    ("param", ["Param"]),
    ("the param partition", ["param"]),
    ("boot image header", ["boot"]),
    ("", ["param"]),
    ("partition", ["partition"]),
)])
PY
)
chk "source 풀이: 전체 일치만 인정"             "$PN" "['param', 'up_param', 'Param', None, None, None, None]"

# =============================================================================
# 7. --family (CC1): 벤더 기본 이름과 "param" 폴백은 exynos 에만 — 다른 계열은 중립 기본값
# 매니페스트가 이름을 정하면 --family 는 아무것도 바꾸지 않는다. 바꾸는 것은 매니페스트가 없을 때의
# 기본 배치와, plan 이 침묵할 때의 커맨드라인 대상뿐이다.
FW_="$MD/family"; rm -rf "$FW_"; mkdir -p "$FW_/fw" "$FW_/02_unpacked"; python3 "$MD/mkfix.py" "$FW_"
for _n in keystorage param up_param; do head -c 4096 /dev/zero > "$FW_/02_unpacked/$_n.bin"; done
fam_names() {   # $1 = --family 값 ("" 이면 안 줌) -> 기본 배치의 파티션 이름
  local out
  if [ -n "$1" ]; then out=$(python3 "$BLU" "$FW_" --out "$FW_/fw/lu_f.img" --medium ufs --family "$1" 2>/dev/null)
  else out=$(python3 "$BLU" "$FW_" --out "$FW_/fw/lu_f.img" --medium ufs 2>/dev/null); fi
  echo "$out" | md_get '[p["name"] for p in d["partitions"]]'
}
chk "기본 배치 + exynos: 벤더 기본 이름이 남는다 (예전과 같음)" "$(fam_names exynos)" "['boot', 'vbmeta', 'keystorage', 'param', 'up_param']"
chk "기본 배치 + 계열 없음: 예전 동작 그대로 (Exynos 이름 포함)" "$(fam_names '')" "['boot', 'vbmeta', 'keystorage', 'param', 'up_param']"
chk "기본 배치 + mediatek: 벤더 이름 없는 중립 배치" "$(fam_names mediatek)" "['boot', 'vbmeta']"
chk "기본 배치 + generic: 벤더 이름 없는 중립 배치" "$(fam_names generic)" "['boot', 'vbmeta']"
chk "기본 배치 + 이름만 있는 다른 계열도 중립 배치" "$(fam_names qualcomm)" "['boot', 'vbmeta']"
chk "  계열 이름은 대소문자를 가리지 않는다" "$(fam_names EXYNOS)" "['boot', 'vbmeta', 'keystorage', 'param', 'up_param']"
FJ=$(python3 "$BLU" "$FW_" --out "$FW_/fw/lu_f.img" --medium ufs --family mediatek 2>/dev/null)
chk "  중립 배치도 이름을 도출하지 않았다고 밝히고, 왜 뺐는지 계열을 댄다" \
    "$(echo "$FJ" | md_get '(d["names_derived"], "mediatek" in d["warning"], "Exynos" in d["warning"])')" "(False, True, True)"
chk "  --family 를 줬으면 warning_family 는 없다" "$(echo "$FJ" | md_get '"warning_family" in d')" "False"
FJ=$(python3 "$BLU" "$FW_" --out "$FW_/fw/lu_f.img" --medium ufs --family exynos 2>/dev/null)
chk "exynos 도 --family 를 줬으면 warning_family 는 없다" "$(echo "$FJ" | md_get '"warning_family" in d')" "False"
FJ=$(python3 "$BLU" "$FW_" --out "$FW_/fw/lu_f.img" --medium ufs 2>/dev/null)
chk "--family 를 안 주면 warning_family 가 선다 (문구 고정)" "$(echo "$FJ" | md_get 'd.get("warning_family")')" "family not given; Exynos defaults applied"
FJ=$(python3 "$BLU" "$FW_" --out "$FW_/fw/lu_f.img" --medium ufs --family '' 2>/dev/null)
chk "빈 --family 는 거부 (조용히 예전 동작으로 가지 않는다)" "$(echo "$FJ" | md_get 'd["ok"]')" "False"

# 매니페스트가 이름을 정하면 계열은 그 이름을 건드리지 않는다
FM="$MD/family_man"; rm -rf "$FM"; mkdir -p "$FM/fw" "$FM/02_unpacked"; python3 "$MD/mkfix.py" "$FM"
head -c 4096 /dev/zero > "$FM/02_unpacked/param.bin"
printf '{"medium":"ufs","partitions":[{"name":"boot","source":"fw/boot.img"},{"name":"param","source":"02_unpacked/param.bin"}]}\n' > "$FM/lu_manifest.json"
FJ=$(python3 "$BLU" "$FM" --out "$FM/fw/lu_f.img" --family mediatek 2>/dev/null)
chk "매니페스트의 param 은 mediatek 이어도 그대로 놓인다" "$(echo "$FJ" | md_get '(d["names_derived"], [p["name"] for p in d["partitions"]])')" "(True, ['boot', 'param'])"

# 커맨드라인: plan 이 침묵할 때 "param" 폴백은 exynos 에만
printf '{"uart":"console=ttyX0,115200n8"}\n' > "$FM/cmdline_plan.json"
fam_cmd() {   # $1 = --family 값 ("" 이면 안 줌) -> 결과 JSON (원본 param 이 그대로인지도 본다)
  if [ -n "$1" ]; then python3 "$BLU" "$FM" --out "$FM/fw/lu_c.img" --family "$1" 2>/dev/null
  else python3 "$BLU" "$FM" --out "$FM/fw/lu_c.img" 2>/dev/null; fi
}
FJ=$(fam_cmd exynos)
chk "plan 침묵 + exynos: param 폴백 (근거 legacy_default, 추측 경고 포함)" \
    "$(echo "$FJ" | md_get '(d["cmdline_written"], d["cmdline_target"]["partition"], d["cmdline_target"]["basis"], "warning_cmdline_target" in d)')" "(True, 'param', 'legacy_default', True)"
FJ=$(fam_cmd '')
chk "plan 침묵 + 계열 없음: 예전 동작 (param 폴백) + warning_family" \
    "$(echo "$FJ" | md_get '(d["cmdline_written"], d["cmdline_target"]["basis"], "warning_family" in d)')" "(True, 'legacy_default', True)"
for _f in mediatek generic; do
  FJ=$(fam_cmd $_f)
  chk "plan 침묵 + $_f: 폴백 없음 — 쓰지 않고 이유를 밝힌다" \
      "$(echo "$FJ" | md_get '(d["ok"], d["cmdline_written"], d["cmdline_target"], "warning_cmdline" in d, "warning_cmdline_target" in d)')" "(True, False, None, True, False)"
  chk "  경고가 \"partition 으로 적으라\"고 안내하고 계열을 댄다" \
      "$(echo "$FJ" | md_get '("partition" in d["warning_cmdline"], "'"$_f"'" in d["warning_cmdline"])')" "(True, True)"
  chk "  param 은 원본 그대로 (덮어쓰지 않음)" \
      "$(python3 "$MD/region.py" "$FM/fw/lu_c.img" "$(python3 "$MD/gpt_inspect.py" "$FM/fw/lu_c.img" 4096 | md_get "[p['start'] for p in d['parts'] if p['name']=='param'][0]*4096")" 4096)" "zero"
done
# plan 이나 매니페스트가 이름을 대면 계열과 무관하게 쓴다
printf '{"uart":"console=ttyX0,115200n8","partition":"param"}\n' > "$FM/cmdline_plan.json"
FJ=$(fam_cmd mediatek)
chk "plan.partition 이 있으면 mediatek 도 쓴다 (근거 plan.partition, 추측 경고 없음)" \
    "$(echo "$FJ" | md_get '(d["cmdline_written"], d["cmdline_target"]["basis"], "warning_cmdline_target" in d, "warning_cmdline" in d)')" "(True, 'plan.partition', False, False)"
printf '{"uart":"console=ttyX0,115200n8"}\n' > "$FM/cmdline_plan.json"
python3 - "$FM" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "lu_manifest.json")
d = json.load(open(p)); d["cmdline_partition"] = "param"
json.dump(d, open(p, "w"))
PY
FJ=$(fam_cmd generic)
chk "매니페스트 cmdline_partition 이 있으면 generic 도 쓴다" \
    "$(echo "$FJ" | md_get '(d["cmdline_written"], d["cmdline_target"]["basis"])')" "(True, 'manifest.cmdline_partition')"
# 같은 입력에서 --family exynos 의 이미지는 계열을 안 준 이미지와 바이트 단위로 같다 (예전 이미지 보존)
python3 "$BLU" "$GW" --out "$GW/fw/fam_none.img" >/dev/null 2>&1
python3 "$BLU" "$GW" --out "$GW/fw/fam_exy.img" --family exynos >/dev/null 2>&1
chk "--family exynos 의 이미지는 계열 없음의 이미지와 같다 (기존 호출 보존)" "$(python3 "$MD/sha.py" "$GW/fw/fam_exy.img")" "$(python3 "$MD/sha.py" "$GW/fw/fam_none.img")"
chk "  그 해시는 v0.27.0 의 것" "$(python3 "$MD/sha.py" "$GW/fw/fam_exy.img")" "$GOLD4096"
# 매체를 정하지 못한 기본값(ufs)은 계열을 바꾸지 않는다 — 다만 그 기본값이 계열과 무관하다고 말한다
FJ=$(python3 "$BLU" "$GW" --out "$GW/fw/fam_med.img" --family mediatek 2>/dev/null)
chk "매체 미정 기본값은 mediatek 이어도 ufs(4096) 그대로, warning_medium 은 선다" \
    "$(echo "$FJ" | md_get '(d["ok"], d["medium"], d["medium_source"], d["block_size"], "warning_medium" in d)')" "(True, 'ufs', 'default', 4096, True)"
chk "  그 경고는 기본값이 계열과 무관한 이전 호환 값이라고 밝힌다" \
    "$(echo "$FJ" | md_get '("계열과 무관한" in d["warning_medium"], "도출한 것이 아닙니다" in d["warning_medium"], "detect_medium.py" in d["warning_medium"])')" "(True, True, True)"

# =============================================================================
hdr "매체 종류 판정 — detect_medium.py"

dm() { python3 "$DET" "$@" 2>/dev/null; }
LOGS="$MD/logs"; mkdir -p "$LOGS"

# 판정 로그: 호스트 진단 줄이 UFS 를 말해도, 여러 종류를 한 줄에 나열해도, 실패 줄이어도 세지 않는다
cat > "$LOGS/emmc.txt" <<'EOF'
1791179918.100000 qemu-system-aarch64: info: rehost: UFS init done
[SD0] Initialized, eMMC45
[PROFILE] ::: lvl(2) NAND/EMMC/UFS init takes 127 ms
[UFS][ufs_aio_otp_lock_req] OTP partition otp is not found
mmc_rpmb_read_data, rpmb_req.result=0
init: Starting service 'vendor.ufs-hal'
log_to_emmc function flag 0x0!
EOF
J=$(dm --bootloader-log "$LOGS/emmc.txt")
chk "부트로더 로그의 eMMC 초기화 줄"     "$(echo "$J" | md_get '(d["hci_kind"], d["basis"], d["confidence"])')" "('emmc', 'bootloader_log', 'high')"
chk "  근거 줄이 그대로 나옴"            "$(echo "$J" | md_get 'any("[SD0] Initialized, eMMC45" in e and "-> emmc" in e for e in d["evidence"])')" "True"
chk "  호스트 진단 줄은 증거 밖"          "$(echo "$J" | md_get 'any("rehost: UFS init done" in e for e in d["evidence"])')" "False"
chk "  호스트 줄을 제외했다고 밝힘"       "$(echo "$J" | md_get 'any("호스트" in n for n in d["notes"])')" "True"
chk "  여러 종류 나열 줄은 세지 않음"     "$(echo "$J" | md_get 'any("NAND/EMMC/UFS" in e and "-> none" in e for e in d["evidence"])')" "True"
chk "  init: 프로세스 줄은 증거 아님"     "$(echo "$J" | md_get 'any("vendor.ufs-hal" in e for e in d["evidence"])')" "False"
chk "  UFS 표가 하나도 없음"              "$(echo "$J" | md_get 'any("-> ufs" in e for e in d["evidence"])')" "False"

printf '[UFS] Initialized, link up\nmmc_rpmb_read_data, rpmb_req.result=0\n' > "$LOGS/ufs.txt"
J=$(dm --bootloader-log "$LOGS/ufs.txt")
chk "부트로더 로그의 UFS 초기화 줄"      "$(echo "$J" | md_get '(d["hci_kind"], d["basis"], d["confidence"])')" "('ufs', 'bootloader_log', 'high')"

printf '[PROFILE] ::: NAND/EMMC/UFS init takes 3 ms\n[UFS] ufs init failed\nmmc timeout\n' > "$LOGS/none.txt"
J=$(dm --bootloader-log "$LOGS/none.txt")
chk "나열·실패 줄만 있으면 unknown"      "$(echo "$J" | md_get '(d["hci_kind"], d["basis"])')" "('unknown', 'none')"

printf '[UFS] ufs init failed\n[SD0] Initialized, eMMC45\n' > "$LOGS/fallback.txt"
J=$(dm --bootloader-log "$LOGS/fallback.txt")
chk "UFS 실패 뒤 eMMC 성공 → emmc"       "$(echo "$J" | md_get 'd["hci_kind"]')" "emmc"

printf '[UFS] Initialized\n[SD0] Initialized, eMMC45\n' > "$LOGS/both.txt"
J=$(dm --bootloader-log "$LOGS/both.txt")
chk "둘 다 초기화했다고 하면 충돌 → unknown" "$(echo "$J" | md_get '(d["hci_kind"], "충돌" in d["reason"])')" "('unknown', True)"

printf 'androidboot.boot_devices=bootdevice,soc/aaaa.mmc\n' > "$LOGS/bootdev.txt"
J=$(dm --bootloader-log "$LOGS/bootdev.txt")
chk "부트 디바이스 줄만 있으면 medium"   "$(echo "$J" | md_get '(d["hci_kind"], d["confidence"])')" "('emmc', 'medium')"

# UART 로그는 줄바꿈 없는 CR 이 섞인다: 줄 번호는 \n 기준(grep -n 과 같음)
printf 'a\rb\r[SD0] Initialized, eMMC45\nc\n' > "$LOGS/cr.txt"
J=$(dm --bootloader-log "$LOGS/cr.txt")
chk "CR 로 이어진 줄도 읽고 번호는 \\n 기준" "$(echo "$J" | md_get '(d["hci_kind"], d["evidence"][0].split(":")[2].strip())')" "('emmc', 'line 1')"

J=$(dm)
chk "입력이 없으면 unknown + 안내"       "$(echo "$J" | md_get '(d["hci_kind"], len(d["notes"]) > 0)')" "('unknown', True)"
J=$(dm --bootloader-log "$LOGS/none_such.txt" --dtb "$LOGS/none_such.dtb")
chk "없는 파일은 unknown + 안내 (오류 아님)" "$(echo "$J" | md_get '(d["hci_kind"], len(d["notes"]))')" "('unknown', 2)"

# --- DTB 텍스트(.dts) --------------------------------------------------------
dts() {   # $1=파일 $2=msdc0 속성 $3=msdc1 속성 $4=ufshci 속성
  cat > "$1" <<EOF
/dts-v1/;
/ {
	compatible = "x,soc";
	soc {
		ufshci: ufshci@100 {
			compatible = "x,ufshci";
			$4
		};
		msdc0: msdc@200 {
			compatible = "x,msdc";
			$2
		};
		msdc1: msdc@300 {
			compatible = "x,msdc";
			$3
		};
		msdc0_top@400 {
			compatible = "x,top";
		};
	};
};
EOF
}
dts "$LOGS/a.dts" 'bus-width = <0x08>; non-removable; status = "okay";' 'bus-width = <0x04>; cd-gpios = <0x2 0x4 0x0>; status = "okay";' ''
J=$(dm --dtb "$LOGS/a.dts")
chk "DTB: 8비트·non-removable msdc → emmc" "$(echo "$J" | md_get '(d["hci_kind"], d["basis"], d["confidence"])')" "('emmc', 'dtb', 'medium')"
chk "  ufshci 존재만으로는 표가 아님"    "$(echo "$J" | md_get 'any("ufshci" in e and "-> none" in e for e in d["evidence"])')" "True"
chk "  SD 슬롯 msdc1 은 표가 아님"       "$(echo "$J" | md_get 'any("msdc@300" in e and "-> none" in e and "SD 슬롯" in e for e in d["evidence"])')" "True"

dts "$LOGS/b.dts" 'bus-width = <0x08>; non-removable; status = "okay";' 'bus-width = <0x04>;' 'status = "okay";'
J=$(dm --dtb "$LOGS/b.dts")
chk "ufshci 도 okay 이면 eMMC 표지를 우선 + 안내" "$(echo "$J" | md_get '(d["hci_kind"], any("SoC 공용" in n for n in d["notes"]))')" "('emmc', True)"

dts "$LOGS/c.dts" 'bus-width = <0x08>; status = "disabled";' 'bus-width = <0x04>; cd-gpios = <0x2 0x4 0x0>;' ''
J=$(dm --dtb "$LOGS/c.dts")
chk "ufshci 만 있고 상태 없음 → unknown"  "$(echo "$J" | md_get 'd["hci_kind"]')" "unknown"

dts "$LOGS/d.dts" 'bus-width = <0x08>; status = "disabled";' 'bus-width = <0x04>; cd-gpios = <0x2 0x4 0x0>;' 'status = "okay";'
J=$(dm --dtb "$LOGS/d.dts")
chk "eMMC 노드 disabled + ufshci okay → ufs(낮음)" "$(echo "$J" | md_get '(d["hci_kind"], d["basis"], d["confidence"])')" "('ufs', 'dtb', 'low')"

dts "$LOGS/e.dts" 'bus-width = <0x08>; non-removable;' 'bus-width = <0x04>;' 'status = "disabled";'
J=$(dm --dtb "$LOGS/e.dts")
chk "status 없는 msdc(켜짐) + ufshci disabled → emmc" "$(echo "$J" | md_get 'd["hci_kind"]')" "emmc"

# --- 우선순위: 부트로더 로그가 DTB 를 이긴다 ----------------------------------
J=$(dm --bootloader-log "$LOGS/emmc.txt" --dtb "$LOGS/d.dts")
chk "eMMC 로그 vs UFS 만 켜진 DTB → 로그"  "$(echo "$J" | md_get '(d["hci_kind"], d["basis"], any("우선순위" in n for n in d["notes"]))')" "('emmc', 'bootloader_log', True)"
J=$(dm --bootloader-log "$LOGS/ufs.txt" --dtb "$LOGS/a.dts")
chk "UFS 로그 vs eMMC DTB → 로그"          "$(echo "$J" | md_get '(d["hci_kind"], d["basis"])')" "('ufs', 'bootloader_log')"
J=$(dm --bootloader-log "$LOGS/none.txt" --dtb "$LOGS/a.dts")
chk "로그가 못 정하면 DTB 로 내려감"        "$(echo "$J" | md_get '(d["hci_kind"], d["basis"])')" "('emmc', 'dtb')"

# --- 바이너리 DTB: 내장 해석기, dtc/fdtdump, 컨테이너에 박힌 DTB --------------
cat > "$MD/fdt_enc.py" <<'PY'
# fdt_enc.py <out> <kind>  : 시험용 FDT 인코더 (dtc 없이도 시험이 돌게 한다)
import struct, sys
def pad4(b): return b + bytes((-len(b)) % 4)
def build(tree):
    strings, offs = bytearray(), {}
    def sid(n):
        if n not in offs:
            offs[n] = len(strings); strings.extend(n.encode() + b"\0")
        return offs[n]
    def val(v):
        if v is True: return b""
        if isinstance(v, str): return v.encode() + b"\0"
        return b"".join(struct.pack(">I", x) for x in v)
    def node(t):
        name, props, kids = t
        out = struct.pack(">I", 1) + pad4(name.encode() + b"\0")
        for k, v in props.items():
            d = val(v)
            out += struct.pack(">III", 3, len(d), sid(k)) + pad4(d)
        for c in kids: out += node(c)
        return out + struct.pack(">I", 2)
    st = node(tree) + struct.pack(">I", 9)
    off_rsv = 40; off_struct = off_rsv + 16; off_str = off_struct + len(st)
    total = off_str + len(strings)
    hdr = struct.pack(">10I", 0xD00DFEED, total, off_struct, off_str, off_rsv, 17, 16, 0, len(strings), len(st))
    return hdr + bytes(16) + st + bytes(strings)
def tree(emmc, ufs_status):
    msdc0 = ("msdc@200", {"compatible": "x,msdc", **({"bus-width": [8], "non-removable": True} if emmc else {"bus-width": [4]})}, [])
    ufs = ("ufshci@100", {"compatible": "x,ufshci", **({"status": "okay"} if ufs_status else {})}, [])
    return ("", {"compatible": "x,soc"}, [("soc", {}, [ufs, msdc0])])
out, kind = sys.argv[1], sys.argv[2]
emmc_blob = build(tree(True, False)); ufs_blob = build(tree(False, True))
if kind == "emmc":   data = emmc_blob
elif kind == "ufs":  data = ufs_blob
elif kind == "embedded":   # 컨테이너: 앞뒤에 잡음, 가운데에 DTB
    data = bytes((i * 31 + 7) & 0xFF for i in range(5003)) + emmc_blob + bytes(77)
elif kind == "two":        # 서로 다른 보드의 DTB 두 개
    data = bytes(64) + emmc_blob + bytes(33) + ufs_blob
elif kind == "junk":
    data = bytes((i * 5 + 1) & 0xFF for i in range(9000))
open(out, "wb").write(data)
PY
python3 "$MD/fdt_enc.py" "$LOGS/emmc.dtb" emmc
python3 "$MD/fdt_enc.py" "$LOGS/ufs.dtb" ufs
python3 "$MD/fdt_enc.py" "$LOGS/emb.img" embedded
python3 "$MD/fdt_enc.py" "$LOGS/two.img" two
python3 "$MD/fdt_enc.py" "$LOGS/junk.bin" junk

J=$(dm --dtb "$LOGS/emmc.dtb" --builtin-dtb)
chk "내장 해석기: eMMC DTB"               "$(echo "$J" | md_get '(d["hci_kind"], d["basis"], any("builtin" in n for n in d["notes"]))')" "('emmc', 'dtb', True)"
J=$(dm --dtb "$LOGS/ufs.dtb" --builtin-dtb)
chk "내장 해석기: ufshci okay 만 있는 DTB" "$(echo "$J" | md_get '(d["hci_kind"], d["confidence"])')" "('ufs', 'low')"
J=$(dm --dtb "$LOGS/emb.img" --builtin-dtb)
chk "컨테이너에 박힌 DTB 를 매직으로 찾음" "$(echo "$J" | md_get '(d["hci_kind"], any("@0x138b" in n for n in d["notes"]))')" "('emmc', True)"
J=$(dm --dtb "$LOGS/two.img" --builtin-dtb)
chk "DTB 마다 판정이 다르면 unknown"       "$(echo "$J" | md_get '(d["hci_kind"], "DTB 마다" in d["reason"])')" "('unknown', True)"
J=$(dm --dtb "$LOGS/junk.bin")
chk "DTB 가 아닌 파일은 unknown + 안내"    "$(echo "$J" | md_get '(d["hci_kind"], any("DTB 가 아닙니다" in n for n in d["notes"]))')" "('unknown', True)"
if command -v dtc >/dev/null 2>&1 || command -v fdtdump >/dev/null 2>&1; then
  J=$(dm --dtb "$LOGS/emmc.dtb")
  chk "dtc/fdtdump 가 있으면 그것으로 해석"  "$(echo "$J" | md_get '(d["hci_kind"], any("builtin" in n for n in d["notes"]))')" "('emmc', False)"
  J=$(dm --dtb "$LOGS/emb.img")
  chk "  컨테이너 안 DTB 도 같은 판정"       "$(echo "$J" | md_get 'd["hci_kind"]')" "emmc"
else
  ok "dtc/fdtdump 없음 — 내장 해석기로 대체됨 (건너뜀)"
fi
# dtc/fdtdump 가 PATH 에 없어도 내장 해석기로 같은 답을 낸다 (--builtin-dtb 없이)
mkdir -p "$MD/emptybin"
J=$(PATH="$MD/emptybin" "$(command -v python3)" "$DET" --dtb "$LOGS/emmc.dtb" 2>/dev/null)
chk "도구가 없으면 내장 해석기로 대체"    "$(echo "$J" | md_get '(d["hci_kind"], any("builtin" in n for n in d["notes"]))')" "('emmc', True)"

# --- 실물 (환경변수가 가리킬 때만) -------------------------------------------
if [ -n "${SBOOT_MT_FIXTURES:-}" ] && [ -f "$SBOOT_MT_FIXTURES/lk-verified.img" ]; then
  J=$(dm --dtb "$SBOOT_MT_FIXTURES/lk-verified.img")
  chk "[실물] 부트로더 이미지 안의 DTB → emmc"   "$(echo "$J" | md_get '(d["hci_kind"], d["basis"])')" "('emmc', 'dtb')"
  chk "  [실물] ufshci 는 존재만으로 세지 않음" "$(echo "$J" | md_get 'any("ufshci" in e and "-> none" in e for e in d["evidence"])')" "True"
  chk "  [실물] SD 슬롯 msdc 는 세지 않음"      "$(echo "$J" | md_get 'any("-> none" in e and "SD 슬롯" in e for e in d["evidence"])')" "True"
  J2=$(dm --dtb "$SBOOT_MT_FIXTURES/lk-verified.img" --builtin-dtb)
  chk "  [실물] 내장 해석기도 같은 판정"        "$(echo "$J2" | md_get 'd["hci_kind"]')" "emmc"
else
  printf '  (SBOOT_MT_FIXTURES 가 없어 실물 DTB 시험은 건너뜀)\n'
fi
if [ -n "${SBOOT_MT_CONSOLE:-}" ] && [ -f "$SBOOT_MT_CONSOLE" ]; then
  J=$(dm --bootloader-log "$SBOOT_MT_CONSOLE")
  chk "[실물] 부트로더 콘솔 → emmc"             "$(echo "$J" | md_get '(d["hci_kind"], d["basis"], d["confidence"])')" "('emmc', 'bootloader_log', 'high')"
  chk "  [실물] 초기화 줄이 근거"               "$(echo "$J" | md_get 'any("Initialized, eMMC45" in e for e in d["evidence"])')" "True"
  chk "  [실물] 호스트 줄은 근거가 아님"        "$(echo "$J" | md_get 'any("eMMC image" in e for e in d["evidence"])')" "False"
else
  printf '  (SBOOT_MT_CONSOLE 이 없어 실물 콘솔 시험은 건너뜀)\n'
fi

# --- 문법 ---------------------------------------------------------------------
# 컴파일만 한다 (py_compile 은 저장소에 __pycache__ 를 남긴다)
python3 -c 'import sys; [compile(open(f, encoding="utf-8").read(), f, "exec") for f in sys.argv[1:]]' "$BLU" "$DET" 2>/dev/null
chk "구문 검사 (build_lu.py, detect_medium.py)" "$?" "0"

rm -rf "$MD"
parts_finish
