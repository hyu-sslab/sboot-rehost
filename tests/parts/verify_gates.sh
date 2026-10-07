#!/usr/bin/env bash
# tests/parts/verify_gates.sh - 출처 검증 게이트 (verify.py · verify_gates.py · verify_prep.py ·
# make_negative_image.py · check_change.sh 의 우회 장부 검사).
#
# 단독 실행: bash tests/parts/verify_gates.sh
# 실물 자료는 환경변수가 가리킬 때만 쓴다 (저장소 시험은 합성 입력만으로 통과해야 한다):
#   SBOOT_MT_KIT   수동 키트 폴더 (machine/machine_preloader.c, machine/bypasses.md)
#   SBOOT_MT_RUN   실행 산출물 폴더 (console.txt = 호스트 줄이 섞인 UART, kernel.log)
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
[ -n "${PARTS_STANDALONE:-}" ] && trap 'rm -rf "$ROOT"' EXIT
export PYTHONDONTWRITEBYTECODE=1        # 시험이 저장소에 __pycache__ 를 남기지 않게

hdr "검증 게이트 — 렉서 · 입력 계약 · 우회 보고 · 증거 준비"

VT="$ROOT/vgates_part"; rm -rf "$VT"; mkdir -p "$VT"
VGPY="$S/verify_gates.py"

# --- 도우미 (시험 전용) ------------------------------------------------------
vgp_j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
vgp_sha()  { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
vgp_v()   { python3 "$S/verify.py" "$@" 2>/dev/null; }
cat > "$VT/pre.py" <<'PY'
import os, sys, time
VT = os.environ["VT"]
sys.path.insert(0, os.environ["VG_SCRIPTS"])
import verify_gates as vg

def path(name):
    return os.path.join(VT, name)

def view(console):
    return vg.ConsoleView.of(console if isinstance(console, bytes) else console.encode("latin-1"))

def gate1(name, console, protected=None):
    facts = vg.analyze_files([path(name)])
    return vg.source_negative(facts, view(console), protected)

def leaks(name, console):
    return len(gate1(name, console)["leaks"])

def g3(name):
    res = vg.input_origin(vg.analyze_files([path(name)]))
    return sorted({x["kind"] for x in res["findings"]})
PY
vgp_u() { VT="$VT" VG_SCRIPTS="$S" python3 -c "exec(open('$VT/pre.py').read()); print($1)"; }
vgp_ws() {   # $1 = 이름 -> 게이트를 통과하는 최소 워크스페이스
  local w="$VT/$1"; rm -rf "$w"; mkdir -p "$w/06_machine" "$w/07_logs" "$w/03_bootloader" "$w/fw"
  printf '### #1 uart\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$w/06_machine/bypasses.md"
  printf 'static void w(void){ qemu_chr_fe_write_all(&s->chr,&b,1); }\n' > "$w/06_machine/machine_full.c"
  printf 'S-BOOT # \0Following commands are supported\0verify ok\0' > "$w/03_bootloader/fw.bin"
  printf 'S-BOOT # \nFollowing commands are supported\nverify ok\n' > "$w/07_logs/console_1.txt"
  echo "$w"
}

# 합성 GPT 매체 (4096 블록: boot · vbmeta · param · prism). prism 은 끝에 AVB 푸터 매직을 가진다.
cat > "$VT/mkgpt.py" <<'PY'
import binascii, hashlib, struct, sys
wd, bs = sys.argv[1], 4096
parts = [("boot", bytes((i * 7 + 3) & 0xFF for i in range(8192))),
         ("vbmeta", (b"AVB0" + bytes((i * 13 + 5) & 0xFF for i in range(3000))).ljust(4096, b"\0")),
         ("param", bytes(4096)),
         ("prism", (b"forged chain vbmeta" + bytes(range(1, 200))).ljust(4096 - 64, b"\0") + b"AVBf" + bytes(60))]
entries = bytearray(128 * 128)
lba = 2 + 4
lay = []
for i, (name, data) in enumerate(parts):
    n = max(1, (len(data) + bs - 1) // bs)
    off = i * 128
    entries[off:off + 16] = b"\xa2\xa0\xd0\xeb\xe5\xb9\x33\x44\x87\xc0\x68\xb6\xb7\x26\x99\xc7"
    entries[off + 16:off + 32] = hashlib.sha256(name.encode()).digest()[:16]
    struct.pack_into("<QQQ", entries, off + 32, lba, lba + n - 1, 0)
    nm = name.encode("utf-16-le"); entries[off + 56:off + 56 + len(nm)] = nm
    lay.append((lba, data)); lba += n
total = lba + 4 + 1
img = bytearray(total * bs)
img[510:512] = b"\x55\xaa"
h = bytearray(92); h[0:8] = b"EFI PART"
struct.pack_into("<III", h, 8, 0x00010000, 92, 0)
struct.pack_into("<QQQQ", h, 24, 1, total - 1, 6, lba - 1)
struct.pack_into("<QIII", h, 72, 2, 128, 128, binascii.crc32(bytes(entries)) & 0xFFFFFFFF)
struct.pack_into("<I", h, 16, binascii.crc32(bytes(h)) & 0xFFFFFFFF)
img[bs:bs + 92] = h
img[2 * bs:2 * bs + len(entries)] = entries
for l, data in lay:
    img[l * bs:l * bs + len(data)] = data
open(wd + "/fw/lu0.img", "wb").write(bytes(img))
PY

# =============================================================================
# 1. 게이트 1 — 렉서 (PR #3 의 사례 A·B, 시간 상한)
# =============================================================================
# 정규식으로 "문장"을 잘라 내던 방식은 문자열 안의 ';' 와 문자 리터럴 '"' 에서 따옴표 짝이 뒤집혀
# 그 뒤의 위조 출력을 놓쳤다. 렉서는 문자열을 토큰으로 먼저 읽는다.
cat > "$VT/caseA.c" <<'C'
void f(void){ info_report("note; the console shows SECRET-PROMPT here"); qemu_chr_fe_write(c,(uint8_t*)"S-BOOT # ",9); }
C
cat > "$VT/caseB.c" <<'C'
void f(void){ info_report("x %c", '"'); qemu_chr_fe_write(c,(uint8_t*)"FORGED-PROMPT> ",15); g("bar"); }
C
cat > "$VT/caseB2.c" <<'C'
void f(void){ printf("x %c", '"'); qemu_chr_fe_write(c,(uint8_t*)"FORGED-PROMPT> ",15); g("bar"); }
C
cat > "$VT/caseC.c" <<'C'
void f(void){ info_report("plain message"); qemu_chr_fe_write(c,(uint8_t*)"just a hello",12); }
C
FAKE='boot ... FORGED-PROMPT> ... S-BOOT # ... SECRET-PROMPT ...'
chk "사례 A: 호스트 진단 문자열 안의 ';' 뒤의 위조 출력을 잡음 (1 건)"  "$(vgp_u "leaks('caseA.c', '$FAKE')")" "1"
chk "  호스트 진단 안의 문자열 자체는 누출이 아님"  "$(vgp_u "[l['text'] for l in gate1('caseA.c', '$FAKE')['leaks']]")" "['S-BOOT #']"
chk "사례 B: 호스트 진단 안의 문자 리터럴 '\"' 뒤의 위조 출력을 잡음"  "$(vgp_u "leaks('caseB.c', '$FAKE')")" "1"
chk "  printf 안의 '\"' 도 같다 (printf 는 면제하지 않음)"             "$(vgp_u "leaks('caseB2.c', '$FAKE')")" "1"
chk "정상 소스는 통과 (누출 0)"                                       "$(vgp_u "leaks('caseC.c', '$FAKE')")" "0"

# 종결자가 없는 입력 — 정규식이면 지수 시간. 렉서는 선형이고 마감 시한이 있다.
cat > "$VT/bound.py" <<'PY'
import os, sys, time, tempfile
sys.path.insert(0, os.environ["VG_SCRIPTS"])
import verify_gates as vg
console = vg.ConsoleView.of(b"boot FORGED-PROMPT> boot\n")
out = []
for n in (20, 2000, 100000):
    body = 'info_report(' + ' '.join('"seg%d"' % i for i in range(n)) + '\nvoid g(void){ uart_puts("FORGED-PROMPT> "); }\n'
    fd, p = tempfile.mkstemp(suffix=".c"); os.write(fd, body.encode()); os.close(fd)
    t = time.time(); r = vg.source_negative(vg.analyze_files([p]), console); dt = time.time() - t
    os.unlink(p)
    out.append((dt < 1.0 + n / 20000.0, len(r["leaks"])))
# 병적 입력 (따옴표만 300 만 개)도 끝난다
fd, p = tempfile.mkstemp(suffix=".c"); os.write(fd, b'"' * 3000000); os.close(fd)
t = time.time(); vg.analyze_files([p]); big = time.time() - t; os.unlink(p)
# 시한이 지나면 통과가 아니라 실패
fd, p = tempfile.mkstemp(suffix=".c"); os.write(fd, b'x = 1;\n' * 200000); os.close(fd)
try:
    vg.analyze_files([p], deadline=time.monotonic() - 1); timed = False
except vg.ScanTimeout:
    timed = True
os.unlink(p)
print(out, big < 30, timed)
PY
chk "종결자 없는 입력: n=20·2000·100000 이 시간 안에 끝나고 뒤의 위조 출력도 잡음" \
    "$(VG_SCRIPTS="$S" python3 "$VT/bound.py")" "[(True, 1), (True, 1), (True, 1)] True True"

# --- 합성 실험 6 건 (조사 노트 g1test t1..t6) --------------------------------
CON6='Starting kernel...\nlogging DV6DAB\nLinux version 4.14.186\ninit first stage started!\n# OK\nKernel_init_done\n'
cat > "$VT/t1.c" <<'C'
static void a(void){ uart_puts("Starting kernel...\n"); }
C
cat > "$VT/t2.c" <<'C'
static const char lg[] = {'l','o','g','g','i','n','g',0};
static const uint8_t pn[] = {0x44,0x56,0x36,0x44,0x41,0x42};
C
cat > "$VT/t3.c" <<'C'
static void a(void){ printf("Linux version 4.14.186\n"); fprintf(stdout, "init first stage started!"); }
C
cat > "$VT/t4.c" <<'C'
static void a(void){ uart_puts("Linux " "version 4.14.186"); uart_puts("# "); uart_puts("OK"); uart_puts("Kernel_init_done"); }
C
cat > "$VT/t5.c" <<'C'
static void a(void){ uart_puts("Kernel_init_done"); }
C
cat > "$VT/t6.c" <<'C'
static void f(void){ s->rx[s->rx_head++] = 'h'; s->rx_count++; qemu_chr_be_write(chr, buf, 4); }
C
chk "t1  \\n 이스케이프 (리터럴 끝의 백슬래시 n 이 콘솔 줄과 일치)"  "$(vgp_u "leaks('t1.c', b'$CON6'.decode('unicode_escape'))")" "1"
chk "t2  문자 배열 {'l','o','g'..} 과 바이트 배열 {0x44,..}"          "$(vgp_u "sorted(l['text'] for l in gate1('t2.c', b'$CON6'.decode('unicode_escape'))['leaks'])")" "['DV6DAB', 'logging']"
chk "t3  printf · fprintf(stdout) 는 호스트 진단이 아니다"            "$(vgp_u "leaks('t3.c', b'$CON6'.decode('unicode_escape'))")" "2"
chk "t4  인접 리터럴을 이어 붙여 대조 (조각난 것도 놓치지 않음)"      "$(vgp_u "sorted(l['text'] for l in gate1('t4.c', b'$CON6'.decode('unicode_escape'))['leaks'])")" "['Kernel_init_done', 'Linux version 4.14.186']"
chk "t5  기준선 (평범한 리터럴)"                                      "$(vgp_u "leaks('t5.c', b'$CON6'.decode('unicode_escape'))")" "1"
chk "t6  직접 RX 버퍼 쓰기 + qemu_chr_be_write (게이트 3)"            "$(vgp_u "g3('t6.c')")" "['chr_be_write', 'rx_write']"

# 십진 코드 목록 {104,101} 은 두 글자로도 글이다. 0x.. 바이트 표는 네 글자 이상이어야 글로 읽는다.
cat > "$VT/dec.c" <<'C'
static const char a[] = {104, 101, 0};
C
cat > "$VT/hex2.c" <<'C'
static const uint8_t t[] = {0x68, 0x65, 0x00};
C
chk "십진 문자 코드 목록 {104,101} = he"             "$(vgp_u "[l['kind'] for l in gate1('dec.c', 'he\nxx yy zz\n')['leaks']]")" "['char_list']"
chk "  0x.. 바이트 표 두 개는 글로 읽지 않는다"       "$(vgp_u "leaks('hex2.c', 'he\nxx yy zz\n')")" "0"

# 6자 미만 조각은 "콘솔 한 줄 전체"와 일치할 때만 본다
cat > "$VT/short.c" <<'C'
static void a(void){ uart_puts("# "); }
C
chk "짧은 리터럴: 콘솔 한 줄이 그것과 같으면 누출"           "$(vgp_u "leaks('short.c', '# \nfoo bar baz\n')")" "1"
chk "  콘솔의 한 줄 안에 부분으로만 있으면 누출이 아님"      "$(vgp_u "leaks('short.c', '# OK\nfoo bar baz\n')")" "0"
# 32/64 비트 상수, 매크로 문자열 이어 붙이기
cat > "$VT/wide.c" <<'C'
static const unsigned long long k = 0x4e6f475a2d4f4b21ULL;
C
cat > "$VT/macro.c" <<'C'
#define PFX "Linux "
static void a(void){ uart_puts(PFX "version 4.14"); }
C
chk "ASCII 로 읽히는 64 비트 상수 (0x4e6f475a2d4f4b21 = NoGZ-OK!)"  "$(vgp_u "leaks('wide.c', 'NoGZ-OK!\n')")" "1"
chk "#define 문자열 + 인접 리터럴"                                "$(vgp_u "leaks('macro.c', 'Linux version 4.14\n')")" "1"
# 서식 변환은 건너뛰고 그 사이의 고정 조각만 본다
cat > "$VT/fmt.c" <<'C'
static void a(void){ uart_puts("fixed prompt %d done"); }
C
chk "서식 %d 사이의 고정 조각은 대조 (6 자 이상만)"            "$(vgp_u "leaks('fmt.c', 'fixed prompt 7 done\n')")" "1"
chk "  서식이 있는 줄 전체는 요구하지 않음"                    "$(vgp_u "leaks('fmt.c', 'nothing here at all\n')")" "0"

# 호스트 진단 면제는 정해진 호출뿐
cat > "$VT/diag.c" <<'C'
static void a(void){
    error_report("ERR-REPORT-LINE");  info_report("INFO-REPORT-LINE");  warn_report("WARN-REPORT-LINE");
    qemu_log("QEMU-LOG-LINE\n");  qemu_log_mask(LOG_UNIMP, "QEMU-LOG-MASK-LINE\n");
    fprintf(stderr, "STDERR-LINE-HERE\n");
    fprintf(stdout, "STDOUT-LINE-HERE\n");  printf("PRINTF-LINE-HERE\n");
}
C
chk "면제는 error/info/warn_report · qemu_log* · fprintf(stderr) 만 (printf · fprintf(stdout) 은 누출)" \
    "$(vgp_u "sorted(l['text'] for l in gate1('diag.c', 'ERR-REPORT-LINE\nINFO-REPORT-LINE\nWARN-REPORT-LINE\nQEMU-LOG-LINE\nQEMU-LOG-MASK-LINE\nSTDERR-LINE-HERE\nSTDOUT-LINE-HERE\nPRINTF-LINE-HERE\n')['leaks'])")" \
    "['PRINTF-LINE-HERE', 'STDOUT-LINE-HERE']"
# QEMU 객체 이름은 출력이 아니다 (rehost.itmon%d 오탐 회귀)
cat > "$VT/naming.c" <<'C'
static void n(void){ memory_region_init_io(&r, NULL, &o, s, "itmon-region-name", 4); mc->desc = "Itmon Board"; }
C
chk "MemoryRegion 이름·mc->desc 는 누출이 아님"  "$(vgp_u "leaks('naming.c', 'itmon-region-name\nItmon Board\n')")" "0"

# --- 추가 검사: UART 출력 경로 1 곳, pstore 영역 -------------------------------
cat > "$VT/tx2.c" <<'C'
static void a(void){ qemu_chr_fe_write_all(&s->chr, &b, 1); }
static void b(void){ qemu_chr_fe_write(&s->chr, &b, 1); }
C
cat > "$VT/tx1.c" <<'C'
static void a(void){ qemu_chr_fe_write_all(&s->chr, &b, 1); }
C
cat > "$VT/pst.c" <<'C'
static void a(void){ qemu_chr_fe_write_all(&s->chr, &b, 1); *(volatile uint32_t *)0x48090010 = 1; }
C
chk "UART 출력 경로가 2 곳이면 게이트 1 실패"          "$(vgp_u "(vg.source_negative_verdict(gate1('tx2.c', 'x y z'), 1)[0], len(gate1('tx2.c', 'x y z')['tx_paths']))")" "(False, 2)"
chk "  1 곳이면 통과"                                 "$(vgp_u "vg.source_negative_verdict(gate1('tx1.c', 'x y z'), 1)[0]")" "True"
chk "보호 영역(pstore) 안의 주소 참조를 잡음"          "$(vgp_u "(vg.source_negative_verdict(gate1('pst.c', 'x', vg.parse_ranges('0x48090000:0xe0000')), 1)[0], len(gate1('pst.c', 'x', vg.parse_ranges('0x48090000:0xe0000'))['protected_hits']))")" "(False, 1)"
chk "  범위를 주지 않으면 확인하지 않음"               "$(vgp_u "vg.source_negative_verdict(gate1('pst.c', 'x'), 1)[0]")" "True"
W=$(vgp_ws pstore)
cp "$VT/pst.c" "$W/06_machine/machine_full.c"
printf '{"channel":"memdump","region_base":"0x48090000","region_size":917504,"console_size":262144,"source":"cmdline","evidence":"t"}\n' > "$W/memdump_plan.json"
chk "memdump_plan.json 의 영역을 verify.py 가 읽어 게이트 1 에 적용"  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][0]["pass"]')" "False"
rm -f "$W/memdump_plan.json"
chk "  계획이 없으면 (memdump 채널 꺼짐) 동작이 그대로"           "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][0]["pass"]')" "True"

# --- 빌드된 소스만 (qemu_targets.txt) -----------------------------------------
W=$(vgp_ws stale)
rm -f "$W/06_machine/machine_full.c"
printf 'static void w(void){ qemu_chr_fe_write_all(&s->chr,&b,1); }\n' > "$W/06_machine/machine_new.c"
printf 'static const char *old = "Following commands are supported";\n' > "$W/06_machine/machine_v1_old.c"
chk "qemu_targets.txt 가 없으면 .c 전부를 본다 (낡은 파일의 누출도 잡힘)" \
    "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][0]["pass"]')" "False"
printf 'machine_new.c\t/qemu/hw/arm/machine_new.c\n' > "$W/06_machine/qemu_targets.txt"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "qemu_targets.txt 가 있으면 빌드된 것만 본다"            "$(echo "$J" | vgp_j 'd["items"][0]["pass"]')" "True"
chk "  제외한 낡은 파일을 이름으로 보고"                     "$(echo "$J" | vgp_j 'd["inputs"]["skipped_stale"]')" "['machine_v1_old.c']"
printf '#include "extra.h"\nstatic void z(void){}\n' >> "$W/06_machine/machine_new.c"
printf 'static const char *h = "Following commands are supported";\n' > "$W/06_machine/extra.h"
printf 'static const char *h2 = "Following commands are supported";\n' > "$W/06_machine/stale.h"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "  빌드된 .c 가 포함하는 헤더는 본다 (헤더 안의 문자열 누출)"  "$(echo "$J" | vgp_j 'd["items"][0]["pass"]')" "False"
chk "  포함되지 않는 헤더는 낡은 파일로 보고"                "$(echo "$J" | vgp_j '"stale.h" in d["inputs"]["skipped_stale"]')" "True"

# =============================================================================
# 2. 입력 계약 — 게스트 콘솔, 호스트 줄, 워크스페이스·회차에 묶기
# =============================================================================
# 재현 실행에서 호스트 진단 5,183 줄이 콘솔 파일에 섞이면, 우회 설명 문자열(패치 표의 이유)이
# 머신 소스의 리터럴과 일치해 65 건이 거짓 적발되었다.
cat > "$VT/hostmix.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["VG_SCRIPTS"])
import verify_gates as vg
vt = os.environ["VT"]
rows = ["patch description number %02d keeps the model going" % i for i in range(65)]
src = "static const char *desc[] = {\n" + ",\n".join('  "%s"' % r for r in rows) + "\n};\n"
src += "static void w(void){ qemu_chr_fe_write_all(&s->chr,&b,1); }\n"
src += 'static void p(int i){ info_report("code patch @0x%x (%s)", 0, desc[i]); }\n'
open(os.path.join(vt, "hostmix.c"), "w").write(src)
host = b"".join(b"1791179918.%06d qemu-system-aarch64: info: rehost: code patch @0x%x (%s)\n" % (i, i, rows[i].encode()) for i in range(65))
guest = b"S-BOOT # \nFollowing commands are supported\n"
open(os.path.join(vt, "hostmix_console.txt"), "wb").write(host + guest)
facts = vg.analyze_files([os.path.join(vt, "hostmix.c")])
raw = vg.source_negative(facts, vg.ConsoleView.of(host + guest))
cons = vg.read_guest_console(os.path.join(vt, "hostmix_console.txt"))
fil = vg.source_negative(facts, cons)
print(len(raw["leaks"]), len(fil["leaks"]), cons["host_dropped"], cons["uart_lines"])
PY
chk "호스트 줄을 섞으면 65 건 거짓 적발, 걸러 내면 0 건 (줄 65 개를 버림)" \
    "$(VT="$VT" VG_SCRIPTS="$S" python3 "$VT/hostmix.py")" "65 0 65 2"
W=$(vgp_ws hostmix)
cp "$VT/hostmix.c" "$W/06_machine/machine_full.c"; cp "$VT/hostmix_console.txt" "$W/07_logs/console_1.txt"
chk "verify.py 는 호스트 줄을 스스로 걸러 낸다 (방어)"  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][0]["pass"]')" "True"
chk "  걸러 낸 줄 수를 보고"                              "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["guest_console"]["host_lines_dropped"]')" "65"

# 병합한 메모리 덤프 로그에 배너가 한 스냅샷에만 있어도 판정에 쓰인다
cat > "$VT/merge.py" <<'PY'
import os, sys, re
vt = os.environ["VT"]
snaps = [[],                                                                 # 1: pstore 콘솔이 아직 없음
         ["0.000000 Linux version 4.14.186-t (b@h) #1", "1.200000 mmcblk0: p1 p2 p3", "5.0 init: first stage"],
         ["20.0 only late lines", "21.5 more late lines"]]                   # 3: 링이 돌아 배너가 덮임
seen = {}
for s in snaps:
    for ln in s:
        t, text = ln.split(" ", 1)
        seen[(float(t), text)] = 1
merged = sorted(seen)
open(os.path.join(vt, "kernel_merged.log"), "w").write("\n".join("%.6f %s" % kv for kv in merged) + "\n")
last = snaps[-1]
open(os.path.join(vt, "kernel_last_only.log"), "w").write("\n".join(last) + "\n")
print(len(merged))
PY
chk "스냅샷 3 개를 합친다 (배너는 두 번째에만 있음)"  "$(VT="$VT" python3 "$VT/merge.py")" "5"
W=$(vgp_ws snap)
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\nEFI PART\n' > "$W/07_logs/console_1.txt"
printf 'Linux version 4.14.186-t (b@h) #1 SMP\0mmcblk%%d: p%%d\0init: first stage\0only late lines\0more late lines\0EFI PART\0' > "$W/03_bootloader/kernel.img"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --memdump-log "$VT/kernel_merged.log")
chk "병합 로그로 판정: 배너가 게스트 콘솔에 있음"        "$(echo "$J" | vgp_j 'd["guest_console"]["kernel_alive_in_guest_console"]')" "True"
chk "  메모리 덤프 줄 수 (UART 와 따로 셈)"              "$(echo "$J" | vgp_j '(d["guest_console"]["uart_lines"], d["guest_console"]["memdump_lines"])')" "(4, 5)"
chk "  커널 쪽 파티션 열거(mmcblk) 인정 → 이중 구동 통과"  "$(echo "$J" | vgp_j 'd["items"][5]["pass"]')" "True"
chk "  게이트 2 도 메모리 덤프 줄을 같은 이미지로 대조"  "$(echo "$J" | vgp_j 'd["items"][1]["pass"]')" "True"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --memdump-log "$VT/kernel_last_only.log")
chk "병합하지 않고 마지막 스냅샷만 쓰면 배너가 없다"      "$(echo "$J" | vgp_j 'd["guest_console"]["kernel_alive_in_guest_console"]')" "False"
# 라운드 규칙: kernel_<N>.log 는 console_<N>.txt 와 같은 N 으로 자동 선택된다
cp "$VT/kernel_merged.log" "$W/07_logs/kernel_1.log"
chk "kernel_<N>.log 는 같은 회차의 console_<N>.txt 와 함께 읽힘"  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["guest_console"]["memdump_lines"]')" "5"
chk "  milestone_tokens.txt 의 kernel_alive 토큰(채널 열 포함)을 사용" \
    "$(printf 'kernel_alive\tFirst stage init\tmemdump\n' > "$W/milestone_tokens.txt"; vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(d["guest_console"]["kernel_alive_token"], d["guest_console"]["kernel_alive_channel"])')" "('First stage init', 'memdump')"

# find_console/find_trace 는 워크스페이스·회차에 묶인다
W=$(vgp_ws bound)
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\n' > "$W/07_logs/console_2.txt"
printf 'ROUND-ONE-ONLY\n' > "$W/07_logs/console_1.txt"
chk "--round 로 그 회차의 콘솔을 고른다"          "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --round 1 | vgp_j 'd["inputs"]["console"].split("/")[-1]')" "console_1.txt"
chk "  기본은 가장 큰 회차 번호"                  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["inputs"]["console"].split("/")[-1]')" "console_2.txt"
mkdir -p "$VT/home/rehost/_traces"
printf '[stage-entry 0x40080000 @line 5] x\n' > "$VT/home/rehost/_traces/run_2.log"
printf '{"stages":[{"name":"bl2","state":"exec","entry_pc":"0x40080000"}]}\n' > "$W/stage_map.json"
chk "~/rehost/_traces 는 읽지 않는다 (--trace 로 넘긴 것만)" \
    "$(HOME="$VT/home" vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(d["items"][3]["pass"], d["inputs"]["trace"])')" "(False, None)"
chk "  --trace 로 주면 쓴다"  "$(HOME="$VT/home" vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --trace "$VT/home/rehost/_traces/run_2.log" | vgp_j 'd["items"][3]["pass"]')" "True"
printf '[stage-entry 0x40080000 @line 5] x\n' > "$W/07_logs/run_2.log"
chk "  워크스페이스 07_logs/run_<N>.log 는 회차로 자동 선택"  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][3]["pass"]')" "True"

# =============================================================================
# 3. 참고 항목 4·6
# =============================================================================
# 항목 4: stage_map v2 의 entry_pc 가 감시값과 검증값이다. v1 은 base 가 딕셔너리다 (예전 코드는
# int 인지 물어 감시 목록이 항상 비었다).
W=$(vgp_ws item4)
printf '[stage-entry 0x0000000040080000 @line 3] a\n[stage-entry 0x200000 @line 9] b\n' > "$W/07_logs/run_1.log"
printf '{"stages":[{"name":"bl2","state":"exec","entry_pc":"0x200000","arch":"aarch32","base":{"load_base":"0x1"}},{"name":"lk","state":"exec","entry_pc":"0x40080000","origin":"medium"}]}\n' > "$W/stage_map.json"
chk "v2 entry_pc: 순서가 어긋나면 '순서' 표기 없이 불통과"  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][3]["pass"]')" "False"
printf '{"stages":[{"name":"lk","state":"exec","entry_pc":"0x40080000","origin":"medium"},{"name":"bl2","state":"exec","entry_pc":"0x200000","arch":"aarch32"}]}\n' > "$W/stage_map.json"
chk "v2 entry_pc: 제로 패딩된 트레이스 주소와 순서를 인정"  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][3]["evidence"]')" "스테이지 2/2 진입 PC 확인 (순서 lk → bl2)"
printf '{"stages":[{"name":"bl2","state":"exec","base":{"load_base":2097152},"file_range":[256,512],"entry_pc_file_offset":256}]}\n' > "$W/stage_map.json"
chk "v1 지도(base 딕셔너리)는 옛 공식으로 폴백"            "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][3]["pass"]')" "True"
printf '[stage-entry 0x400800001 @line 3] longer address\n' > "$W/07_logs/run_1.log"
printf '{"stages":[{"name":"lk","state":"exec","entry_pc":"0x40080000"}]}\n' > "$W/stage_map.json"
chk "더 긴 주소(0x400800001)의 앞부분은 일치로 세지 않음"   "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][3]["pass"]')" "False"
chk "--watch-list: 트레이스 감시값 (v1 base 딕셔너리도 값이 나온다)"  "$(printf '{"stages":[{"name":"a","state":"exec","base":{"load_base":2097152},"file_range":[256,512],"entry_pc_file_offset":256},{"name":"b","state":"exec","entry_pc":"0x40080000"},{"name":"c","state":"skip","entry_pc":"0x1"}]}\n' > "$VT/sm_watch.json"; python3 "$S/verify.py" "$W" --stage-map "$VT/sm_watch.json" --watch-list)" "0x200000,0x40080000"
printf '{"stages":[{"name":"lk","state":"exec","entry_pc":"0x40080000"}]}\n' > "$VT/sm_other.json"
printf '[stage-entry 0x40080000 @line 3] a\n' > "$W/07_logs/run_1.log"
rm -f "$W/stage_map.json"
chk "--stage-map 으로 다른 지도를 줄 수 있다"             "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --stage-map "$VT/sm_other.json" | vgp_j 'd["items"][3]["pass"]')" "True"

# 항목 6: eMMC 는 mmcblkN: pM 으로 열거되고, UFS 라벨은 UFS 에만 붙는다
W=$(vgp_ws storage)
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\nEFI PART\nmmcblk0: p1 p2 p3\n' > "$W/07_logs/console_1.txt"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "mmcblk0: p1 p2 → 커널측 열거 (partitions_up)"        "$(echo "$J" | vgp_j 'd["items"][5]["pass"]')" "True"
chk "  eMMC 로 보고하고 ufs_controller 라벨은 없다"       "$(echo "$J" | vgp_j '(d["storage_controller"]["kind"], "ufs_controller" in d)')" "('emmc', False)"
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\nEFI PART\nscsi host0: ufshcd\nsda: sda1 sda2\n' > "$W/07_logs/console_1.txt"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "UFS 는 sda: sdaN 으로 그대로 인정, 라벨도 유지"       "$(echo "$J" | vgp_j '(d["items"][5]["pass"], d["storage_controller"]["kind"], "ufs_controller" in d)')" "(True, 'ufs', True)"
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\n' > "$W/07_logs/console_1.txt"
chk "매체 종류를 모르면 'UFS 컨트롤러 미완성'이라 쓰지 않는다" "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '"UFS" in d["storage_controller"]["stage"]')" "False"

# =============================================================================
# 4. 게이트 2 — 줄 형태 목록과 참조 집합
# =============================================================================
cat > "$VT/shapes.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["VG_SCRIPTS"])
import verify_gates as vg
img = (b"[Thermal/TZ/CPU]%s: temp %d\0Starting kernel...\0"
       b"All good kernel starting boot done\0unrelated words here: good kernel boot\0")
img += b"rootfs mounted on\0/dev/block/mmcblk\0read_all_tc_temperature\0"   # __func__ 문자열은 이미지에 따로 있다
con = (b"[Thermal/TZ/CPU]read_all_tc_temperature: temp 45\n"
       b"Starting kernel...\n"
       b"rootfs mounted on /dev/block/mmcblk0p12\n"
       b"All good kernel starting boot done\n"           # 이미지에 그대로 있으니 일치
       b"good kernel boot starting done All\n")          # 실제 단어로만 지어낸 줄
lines = [l for l in con.split(b"\n") if l]
res = vg.output_origin({"lines": lines, "bytes": con}, [img])
sh = res["shapes"]
print(res["pass"], sh["by_class"], sh["matched"], [e["class"] for e in sh["unmatched"]][:1])
PY
chk "줄 형태: 서식+함수명 · 런타임 조립 · 의심을 분류하고, 단어 규칙은 통과 (의심은 목록에만)" \
    "$(VG_SCRIPTS="$S" python3 "$VT/shapes.py")" "True {'suspicious': 1, 'format_plus_function': 1, 'runtime_assembled': 1} 2 ['suspicious']"
W=$(vgp_ws shapes)
printf 'Following commands are supported good boot\0kernel starting\0' >> "$W/03_bootloader/fw.bin"
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\nboot good kernel starting\n' > "$W/07_logs/console_1.txt"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "의심 형태가 있어도 아직 판정을 막지 않는다 (Q4 미결)"  "$(echo "$J" | vgp_j 'd["items"][1]["pass"]')" "True"
chk "  JSON 에 전수 목록과 분류별 개수"                     "$(echo "$J" | vgp_j '(d["items"][1]["detail"]["shapes"]["by_class"]["suspicious"], len(d["items"][1]["detail"]["shapes"]["unmatched"]))')" "(1, 1)"
chk "  본문(evidence)에도 의심 형태를 눈에 띄게 적음"       "$(echo "$J" | vgp_j '"의심 형태 1 건" in d["items"][1]["evidence"]')" "True"

# 합성·위조 파티션은 참조 집합에서 뺀다 (우리가 쓴 바이트는 근거가 아님)
W=$(vgp_ws prov)
printf 'Forged chain partition text appears only there\0' > "$W/fw/prism.img"
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\nForged chain partition text appears only there\n' > "$W/07_logs/console_1.txt"
chk "참조 이미지에 있으면 통과"                          "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][1]["pass"]')" "True"
printf '{"boot":"firmware","prism":"forged"}\n' > "$W/fw/lu_provenance.json"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "lu_provenance 가 forged 로 적은 파티션은 참조에서 제외 → 불통과"  "$(echo "$J" | vgp_j 'd["items"][1]["pass"]')" "False"
chk "  제외한 파일과 이유를 보고"                                   "$(echo "$J" | vgp_j '[x["file"] for x in d["items"][1]["detail"]["reference"]["excluded"]]')" "['prism.img']"
printf 'S-BOOT # \0Following commands are supported\0verify ok\0Forged chain partition text appears only there\0' > "$W/fw/lu0.img"
printf '{"partitions":[{"name":"prism","kind":"firmware"}]}\n' > "$W/lu_manifest.json"
printf '{"prism":{"kind":"synthesized"}}\n' > "$W/fw/lu_provenance.json"
chk "  합성한 매체 이미지(lu0.img) 자체도 참조가 아님"             "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][1]["pass"]')" "False"

# gzip 커널은 압축을 푼 Image 로 검색한다
W=$(vgp_ws gz)
python3 - "$W" <<'PY'
import gzip, sys
open(sys.argv[1] + "/fw/Image", "wb").write(gzip.compress(b"\0" * 64 + b"Linux version 4.14.186-gz mounted rootfs\0"))
PY
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\nLinux version 4.14.186-gz mounted rootfs\n' > "$W/07_logs/console_1.txt"
chk "gzip 으로 압축된 커널 안의 문자열도 출처로 인정"  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][1]["pass"]')" "True"

# =============================================================================
# 5. 게이트 3 — 입력 출처
# =============================================================================
cat > "$VT/rx_ok.c" <<'C'
static void push(S *s, uint8_t c) { s->rx[s->rx_tail] = c; s->rx_tail = (s->rx_tail + 1) % 256; }
static void uart_receive(void *o, const uint8_t *buf, int n) { for (int i = 0; i < n; i++) push(o, buf[i]); }
static int uart_can_receive(void *o) { return 1; }
static void init(S *s) { qemu_chr_fe_set_handlers(&s->chr, uart_can_receive, uart_receive, NULL, NULL, s, NULL, true); }
C
cat > "$VT/rx_timer.c" <<'C'
static void tick(void *o) { S *s = o; s->rx[s->rx_tail++] = 'h'; }
static void init(S *s) { s->t = timer_new_ms(QEMU_CLOCK_VIRTUAL, tick, s); timer_mod(s->t, 5); }
C
cat > "$VT/rx_shared.c" <<'C'
static void push(S *s, uint8_t c) { s->rx[s->rx_tail] = c; }
static void uart_receive(void *o, const uint8_t *buf, int n) { push(o, buf[0]); }
static void tick(void *o) { push(o, 'h'); }
static void init(S *s) { qemu_chr_fe_set_handlers(&s->chr, NULL, uart_receive, NULL, NULL, s, NULL, true);
                         s->t = timer_new_ms(QEMU_CLOCK_VIRTUAL, tick, s); }
C
cat > "$VT/rx_call.c" <<'C'
static void uart_receive(void *o, const uint8_t *buf, int n) { }
static void tick(void *o) { uart_receive(o, "help\n", 5); }
static void init(S *s) { qemu_chr_fe_set_handlers(&s->chr, NULL, uart_receive, NULL, NULL, s, NULL, true);
                         s->t = timer_new_ms(QEMU_CLOCK_VIRTUAL, tick, s); }
C
cat > "$VT/rx_memcpy.c" <<'C'
static void go(S *s) { memcpy(s->rx_buf, "help\n", 5); fifo8_push(&s->rx_fifo, 'x'); }
C
cat > "$VT/rx_seed.c" <<'C'
static void rx_seed(S *s, const char *p) { }
C
cat > "$VT/rx_macro.c" <<'C'
#define RX_PUSH(c) s->rx[s->rx_tail++] = (c)
static void uart_receive(void *o, const uint8_t *b, int n) { RX_PUSH(b[0]); }
static void init(S *s) { qemu_chr_fe_set_handlers(&s->chr, NULL, (IOReadHandler *)uart_receive, NULL, NULL, s, NULL, true); }
C
cat > "$VT/rx_macro_timer.c" <<'C'
#define RX_PUSH(c) s->rx[s->rx_tail++] = (c)
static void tick(void *o) { RX_PUSH('h'); }
static void init(S *s) { s->t = timer_new_ms(QEMU_CLOCK_VIRTUAL, tick, s); }
C
cat > "$VT/rx_reset.c" <<'C'
static void reset(S *s) { memset(s->rx, 0, sizeof(s->rx)); s->rx[0] = 0; fifo8_reset(&s->rx_fifo); }
C
cat > "$VT/rx_decl.c" <<'C'
static uint8_t rx_buf[16] = {0};
static void a(void) { uint8_t rbr = 0; int rxbyte = 1; (void)rbr; (void)rxbyte; if (s->rx[0] == 5) {} }
C
chk "chardev 콜백과 그것만 부르는 보조 함수의 RX 쓰기는 정상"      "$(vgp_u "g3('rx_ok.c')")" "[]"
chk "타이머 콜백에서 RX 버퍼에 쓰면 적발 (콜백 밖)"                "$(vgp_u "g3('rx_timer.c')")" "['rx_write']"
chk "  보고에 '타이머 콜백'이 적힌다"                            "$(vgp_u "any('타이머' in x['detail'] for x in vg.input_origin(vg.analyze_files([path('rx_timer.c')]))['findings'])")" "True"
chk "콜백과 타이머가 함께 쓰는 보조 함수는 정상으로 보지 않음"      "$(vgp_u "g3('rx_shared.c')")" "['rx_write']"
chk "머신이 자기 수신 콜백을 직접 호출하면 적발"                  "$(vgp_u "g3('rx_call.c')")" "['callback_call']"
chk "memcpy·fifo8_push 로 RX 버퍼를 채우면 적발"                 "$(vgp_u "sorted({x['detail'].split()[-1] if False else x['kind'] for x in vg.input_origin(vg.analyze_files([path('rx_memcpy.c')]))['findings']})")" "['rx_write']"
chk "  (두 호출 모두)"                                          "$(vgp_u "len(vg.input_origin(vg.analyze_files([path('rx_memcpy.c')]))['findings'])")" "2"
chk "rx_seed 류 함수 이름 (정의만 있어도)"                       "$(vgp_u "g3('rx_seed.c')")" "['rx_seed']"
chk "선언·초기화·읽기·비교는 쓰기가 아님"                        "$(vgp_u "g3('rx_decl.c')")" "[]"
chk "매크로 안의 RX 쓰기: 콜백(캐스트로 등록)에서 쓰면 정상"         "$(vgp_u "g3('rx_macro.c')")" "[]"
chk "  같은 매크로를 타이머 콜백에서 쓰면 적발"                    "$(vgp_u "g3('rx_macro_timer.c')")" "['rx_write']"
chk "버퍼를 비우는 코드(memset 0 · =0 · fifo8_reset)는 입력이 아님"  "$(vgp_u "g3('rx_reset.c')")" "[]"

cat > "$VT/rx_token.c" <<'C'
static const char *cmd = "help\n";
static const char *fb = "getvar:version";
static const char *prompt = "type help for the list of commands";
C
chk "호스트가 치는 명령(--input-token)이 머신에 통째 리터럴로 있으면 적발"  "$(vgp_u "[(x['kind'], x['line']) for x in vg.input_origin(vg.analyze_files([path('rx_token.c')]), (), 'help')['findings']]")" "[('input_command', 1)]"
chk "  fastboot 처럼 ':' 로 끝나는 토큰은 접두로 본다"                    "$(vgp_u "[x['line'] for x in vg.input_origin(vg.analyze_files([path('rx_token.c')]), (), 'getvar:')['findings']]")" "[2]"
chk "  문장 속의 낱말은 아님 (토큰 없이도 영향 없음)"                       "$(vgp_u "vg.input_origin(vg.analyze_files([path('rx_token.c')]))['findings']")" "[]"

# 하니스의 모니터 명령은 pmemsave 만
cat > "$VT/h_ok.sh" <<'SH'
mon() { { sleep 0.5; echo "$1"; } | socat - "UNIX-CONNECT:$OUT/m.sock"; }
mon "pmemsave 0x48090000 917504 \"$OUT/ps/ps_$N.bin\""
SH
cat > "$VT/h_bad.sh" <<'SH'
mon() { { sleep 0.5; echo "$1"; } | socat - "UNIX-CONNECT:$OUT/m.sock"; }
mon "pmemsave 0x48090000 917504 \"$OUT/ps.bin\""
mon "sendkey ret"
echo 'chardev-send-break serial0' | socat - UNIX-CONNECT:m.sock
SH
cat > "$VT/h_py.py" <<'PY'
import socket
mon = socket.socket(socket.AF_UNIX)
mon.sendall(b"pmemsave 0x1 2 f\n")
mon.sendall(b"human-monitor-command\n")
hmp(sock, 'pmemsave 0x1 2 "f"')
hmp(sock, 'quit')
# never sendkey here
out = open("log.txt", "w"); out.write("hello world\n")
raise MonitorGone("monitor closed")
PY
chk "모니터 명령이 pmemsave 뿐이면 정상"       "$(vgp_u "vg.scan_monitor([path('h_ok.sh')])[0]")" "[]"
chk "sendkey · chardev-send-break 를 적발"      "$(vgp_u "sorted(x['detail'].split()[2] for x in vg.scan_monitor([path('h_bad.sh')])[0])")" "[\"'chardev-send-break'\", \"'sendkey'\"]"
chk "파이썬 하니스의 소켓 쓰기·hmp() 도 본다 (파일 쓰기·예외 문구·주석은 아님)"  "$(vgp_u "sorted(x['detail'].split()[2] for x in vg.scan_monitor([path('h_py.py')])[0])")" "[\"'human-monitor-command'\", \"'quit'\"]"
chk "플러그인이 쓰는 하니스(uart_harness.py)에는 모니터 명령이 없다"  "$(vgp_u "vg.scan_monitor(['$S/uart_harness.py'])[0]")" "[]"
W=$(vgp_ws harness)
cp "$VT/h_bad.sh" "$W/run.sh"
chk "verify.py 가 워크스페이스의 run 스크립트를 게이트 3 에 반영"  "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][2]["pass"]')" "False"
cp "$VT/h_ok.sh" "$W/run.sh"
chk "  pmemsave 만 쓰면 통과"                                       "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["items"][2]["pass"]')" "True"

# =============================================================================
# 6. 검증 우회 보고 (게이트가 아니라 병기)
# =============================================================================
W=$(vgp_ws bypass)
cat > "$W/06_machine/bypasses.md" <<'MD'
### #1 DXCC 스텁
- 대상: avb_safe_memcmp
- 이유: LK 안의 digest 비교가 하드웨어 SHA 에 의존한다
- 방법: movs r0,#0; bx lr
- 부작용: 모든 AVB 비교가 같음으로 나온다
- 메타: 종류=P; 표지=F,L; 출처=A; 도출=semi

### #2 열센서
- 대상: LVTS
- 이유: 없는 하드웨어
- 방법: 값 고정
- 부작용: 온도 의존 분기가 검증되지 않는다
- 메타: 종류=V; 표지=; 출처=B; 도출=auto

### #3 표지 F
- 대상: 검증 경로
- 이유: 인증 실패 화면을 건너뜀
- 방법: 분기 반전
- 부작용: 실패 화면이 나오지 않는다
- 메타: 종류=P; 표지=F; 출처=C; 도출=manual
MD
python3 "$VT/mkgpt.py" "$W"
printf '{"prism":"forged","param":"synthesized","vbmeta":"modified","boot":"firmware"}\n' > "$W/fw/lu_provenance.json"
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\nsbc_en = 0\n' > "$W/07_logs/console_1.txt"
printf 'sbc_en = 0\0' >> "$W/03_bootloader/fw.bin"
# 펌웨어 상태 토큰은 스크립트가 아니라 static-analyzer 가 도출한 status_tokens.txt 에서 온다
printf '# 도출한 상태 토큰\nsbc_en\n' > "$W/status_tokens.txt"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "우회 장부 신호: 표지 F 와 'digest' 문구 행 (3 건)"      "$(echo "$J" | vgp_j '[s["count"] for s in d["verify_bypass"]["signals"] if s["id"]=="ledger"][0]')" "2"
chk "  (#1 은 F + digest 이므로 한 번만 센다)"               "$(echo "$J" | vgp_j '[x["id"] for s in d["verify_bypass"]["signals"] if s["id"]=="ledger" for x in s["items"]]')" "['1', '3']"
chk "매체의 위조(forged)·수정(modified) 파티션"              "$(echo "$J" | vgp_j '[(s["id"], s["count"]) for s in d["verify_bypass"]["signals"] if s["id"] in ("forged_media","modified_images")]')" "[('forged_media', 1), ('modified_images', 1)]"
chk "  위조 파티션의 AVB 푸터 매직(AVBf)을 매체에서 확인"          "$(echo "$J" | vgp_j '[x for s in d["verify_bypass"]["signals"] if s["id"]=="forged_media" for x in s["items"]]')" "[{'partition': 'prism', 'avb_footer': True}]"
chk "  합성한 매체(lu0.img)는 게이트 2 의 참조 집합에 들어가지 않는다"  "$(echo "$J" | vgp_j '[x["file"] for x in d["items"][1]["detail"]["reference"]["excluded"]]')" "['lu0.img']"
chk "펌웨어 자신의 상태 토큰 (status_tokens.txt 에서 도출)"       "$(echo "$J" | vgp_j '[x["token"] for s in d["verify_bypass"]["signals"] if s["id"]=="firmware_status" for x in s["items"]]')" "['sbc_en']"
# 도출된 토큰이 없으면 아무 벤더 문자열도 스스로 찾지 않는다 (스크립트에 벤더 문자열 없음)
mv "$W/status_tokens.txt" "$W/status_tokens.off"
chk "도출된 토큰이 없으면 상태 로그를 찾지 않고 그 사실을 밝힘" \
    "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '[(s["count"], "status_tokens.txt" in s["label"]) for s in d["verify_bypass"]["signals"] if s["id"]=="firmware_status"]')" "[(0, True)]"
mv "$W/status_tokens.off" "$W/status_tokens.txt"
chk "verify_gates.py 에 벤더 상태 문자열이 없다" \
    "$(grep -c -e 'sbc_en' -e 'NS-CHIP' -e 'Hash does not match' "$REPO/scripts/verify_gates.py" | head -1)" "0"
chk "음성 시험 미실시는 건수가 아니라 '증명 안 됨'으로 표기"   "$(echo "$J" | vgp_j '(d["verify_bypass"]["unproven"], [s["count"] for s in d["verify_bypass"]["signals"] if s["id"]=="negative_test"])')" "(True, [0])"
chk "판정 문구에 건수와 reached_bypassed 를 병기"             "$(echo "$J" | vgp_j '(d["verdict"], d["verify_bypass"]["count"], d["verdict_label"])')" "('VERIFIED', 5, 'VERIFIED (출처 검증 통과) · 검증 우회 5건 · verify_ok: reached_bypassed')"
# 음성 시험: 훼손해도 새 실패 줄이 없으면 우회의 증거
printf 'S-BOOT # \nFollowing commands are supported\nverify ok\nsbc_en = 0\n' > "$VT/neg_same.txt"
printf 'S-BOOT # \nverify failed: hash mismatch in vbmeta\nFollowing commands are supported\nsbc_en = 0\n' > "$VT/neg_rejected.txt"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --negative-console "$VT/neg_same.txt")
chk "훼손해도 결과가 같다 → 우회 +1 건, 참고 항목 5 불통과"  "$(echo "$J" | vgp_j '(d["verify_bypass"]["count"], d["items"][4]["pass"], d["verify_bypass"]["negative_test"]["rejected"])')" "(6, False, False)"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --negative-console "$VT/neg_rejected.txt")
chk "훼손 이미지에서 새 실패 줄이 나온다 → 거부됨, 건수 불변, 항목 5 통과"  "$(echo "$J" | vgp_j '(d["verify_bypass"]["count"], d["items"][4]["pass"], d["verify_bypass"]["negative_test"]["rejected"])')" "(5, True, True)"
# 우회가 없으면 문구는 그대로
W=$(vgp_ws nobypass)
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "우회 신호가 없으면 문구는 '출처 검증 통과' 그대로"  "$(echo "$J" | vgp_j '(d["verdict_label"], d["verify_bypass"]["count"], d["verify_bypass"]["status"])')" "('출처 검증 통과', 0, 'none')"
chk "게이트가 실패하면 UNVERIFIED (우회 건수는 따로)"      "$(printf 'static const char *p = \"Following commands are supported\";\n' > "$W/06_machine/machine_full.c"; vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(d["verdict"], d["verdict_label"])')" "('UNVERIFIED', '출처 검증 실패')"
chk "--bypass-ledger · --status-token 으로 다른 장부·토큰을 줄 수 있다" \
    "$(printf 'x\n' > "$W/07_logs/note.txt"; printf '### #9 a\n- 대상: x\n- 이유: unlock 상태를 바꿈\n- 방법: m\n- 부작용: s\n' > "$VT/other_ledger.md"; printf 'static void w(void){ qemu_chr_fe_write_all(&s->chr,&b,1); }\n' > "$W/06_machine/machine_full.c"; vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --bypass-ledger "$VT/other_ledger.md" --status-token verify | vgp_j '(d["verify_bypass"]["count"], [x["token"] for s in d["verify_bypass"]["signals"] if s["id"]=="firmware_status" for x in s["items"]])')" "(2, ['verify'])"

chk "우회 장부 신호: 한글로만 쓴 행(메타 없음)도 검증 우회로 센다 — 해시·서명·검증" \
    "$(printf '### #7 해시 비교 결과 변경\n- 대상: 서명 비교 함수\n- 이유: 해시 엔진이 없음\n- 방법: 결과를 0 으로 고정\n- 부작용: s\n\n### #8 타이머\n- 대상: 타이머\n- 이유: 멈춤\n- 방법: 값 고정\n- 부작용: 검증 안 됨\n' > "$VT/ko_ledger.md"; vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" --bypass-ledger "$VT/ko_ledger.md" | vgp_j '[(x["id"], x["why"]) for s in d["verify_bypass"]["signals"] if s["id"]=="ledger" for x in s["items"]]')" "[('7', \"제목·대상·이유·방법에 '해시'\")]"

# =============================================================================
# 7. 우회 장부 — check_change.sh (부작용 · 메타 · 표 행 대응)
# =============================================================================
CW="$VT/cc"; rm -rf "$CW"; mkdir -p "$CW/06_machine"
E1='### #1 첫 우회
- 대상: t
- 이유: r
- 방법: m
- 부작용: 이 경로는 더 이상 검증되지 않는다'
E2_OK='### #2 둘째
- 대상: t2
- 이유: r2
- 방법: m2
- 부작용: 타이머가 멈춘다'
E2_EMPTY='### #2 둘째
- 대상: t2
- 이유: r2
- 방법: m2
- 부작용:'
E2_NOREC='### #2 둘째
- 대상: t2
- 이유: r2
- 방법: m2
- 부작용: (기록 없음)'
vgp_cc() {   # $1 = 수정 전 장부, $2 = 수정 후 장부, $3 = 수정 후 machine.c  -> 종료코드 (JSON 은 $VT/cc.json)
  printf 'int a;\nint b;\n' > "$CW/06_machine/machine.c"
  rm -rf "$CW/08_docs"
  printf '%s\n' "$1" > "$CW/06_machine/bypasses.md"
  bash "$S/check_change.sh" "$CW" snapshot >/dev/null
  printf '%s\n' "$2" > "$CW/06_machine/bypasses.md"
  printf '%b' "${3:-int a;\\nint b2;\\n}" > "$CW/06_machine/machine.c"
  bash "$S/check_change.sh" "$CW" verify > "$VT/cc.json" 2>/dev/null; echo $?
}
vgp_ccj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$VT/cc.json" "$1"; }
chk "정상 장부 + 새 항목 → 통과 (종료 0)"                          "$(vgp_cc "$E1" "$E1
$E2_OK")" "0"
chk "  기존 JSON 키는 그대로, bypass_issues 가 추가됨"               "$(vgp_ccj '(d["bypass_entries"], d["bypass_issues"], d["pass"])')" "(2, 0, True)"
chk "새 항목의 부작용이 비어 있으면 반려 (종료 2)"                  "$(vgp_cc "$E1" "$E1
$E2_EMPTY")" "2"
chk "  사유가 부작용을 짚는다"                                      "$(vgp_ccj '"부작용" in d["reason"] and "#2" in d["reason"]')" "True"
chk "새 항목의 부작용이 '(기록 없음)' 이면 반려"                    "$(vgp_cc "$E1" "$E1
$E2_NOREC")" "2"
chk "과거에 이미 있던 '(기록 없음)' 항목은 이번 회차를 막지 않는다 (기준선)"  "$(vgp_cc "$E1
$E2_NOREC" "$E1
$E2_NOREC
$(printf '%s' "$E2_OK" | sed 's/#2/#3/; s/둘째/셋째/')")" "0"
chk "  그 항목을 이번 회차에 고쳐 쓰다 다시 비우면 반려"             "$(vgp_cc "$E1
$E2_OK" "$E1
$E2_EMPTY")" "2"
chk "기록이 아예 없으면 기존대로 반려 (4 항목)"                     "$(vgp_cc "" "")" "2"
chk "  사유가 4 항목 누락 (기존 문구)"                              "$(vgp_ccj '"4 항목" in d["reason"] and d["bypass_ok"] is False')" "True"
E2_META_BAD="$E2_OK
- 메타: 종류=Z; 표지=F,Q; 출처=A; 도출=semi; 이상=1"
E2_META_OK="$E2_OK
- 메타: 종류=P; 표지=F,L; 출처=A; 도출=semi; 근거=함수 주소 0x2375e8"
chk "메타 어휘가 어긋나면 반려 (종류=Z, 표지=Q, 알 수 없는 키)"      "$(vgp_cc "$E1" "$E1
$E2_META_BAD" 'int a;\nint b2; /* bypass:2 */\n')" "2"
chk "  사유가 메타를 짚는다"                                        "$(vgp_ccj '"메타" in d["reason"]')" "True"
chk "메타 어휘가 맞으면 통과 (표지 여러 개, 근거 자유 서식)"          "$(vgp_cc "$E1" "$E1
$E2_META_OK" 'int a;\nint b2; /* bypass:2 */\n')" "0"
chk "표 행 태그에 대응하는 기록이 없으면 반려"                      "$(vgp_cc "$E1" "$E1
$E2_OK" 'int a;\nint b2; /* bypass:9 */\n')" "2"
chk "  사유가 태그를 짚는다"                                        "$(vgp_ccj '"bypass:9" in d["reason"]')" "True"
chk "같은 번호를 표 두 행에 쓰면 반려 (표 1행 = 우회 1건)"           "$(vgp_cc "$E1" "$E1
$E2_OK" 'int a;\nint b2; /* bypass:2 */\nint c; /* bypass:2 */\n')" "2"
chk "종류=P 인 기록에 표 행 태그가 없으면 반려 (다른 태그가 있을 때)" "$(vgp_cc "$E1
$E2_OK" "$E1
$E2_OK
$(printf '%s\n- 메타: 종류=P' "$E2_OK" | sed 's/#2/#3/; s/둘째/셋째/')" 'int a;\nint b2; /* bypass:2 */\n')" "2"
chk "태그가 하나도 없으면 대응 검사는 하지 않는다 (기존 장부 호환)"    "$(vgp_cc "$E1" "$E1
$E2_OK" 'int a;\nint b2;\n')" "0"
chk "한 번호로 묶은 제목(#2~#4)은 반려"                            "$(vgp_cc "$E1" "$E1
$(printf '%s' "$E2_OK" | sed 's/### #2 둘째/### #2~#4 묶음/')")" "2"
# 표지 F 필수 — 검증 경로를 건드리는 새 기록은 라벨 없이 통과하지 못한다 (찾아낸 우회 사례:
# 한글로 쓴 해시 비교 우회가 메타 줄도 표지도 없이 장부 검사를 통과하고 0 건으로 세어졌다)
E7_HASH='### #7 해시 비교 결과 변경
- 대상: 부트로더의 서명 비교 함수 (RSA 결과 비교)
- 이유: 해시 엔진이 없어 비교가 항상 틀림
- 방법: 비교 결과를 0 으로 고정
- 부작용: 서명이 틀린 이미지도 통과한다'
chk "표지 F 필수: 메타 줄 없이 한글로 쓴 해시·서명 비교 우회는 반려"        "$(vgp_cc "$E1" "$E1
$E7_HASH" 'int a;\nint b7;\n')" "2"
chk "  사유가 번호와 '표지 F' 를 짚는다"                                  "$(vgp_ccj '"#7" in d["reason"] and "표지 F" in d["reason"]')" "True"
chk "  verify_gates.py ledger 도 같은 기록을 verify_unlabelled 로 지적한다 (ok=false)" \
    "$(printf '%s\n' "$E7_HASH" > "$VT/e7.md"; python3 "$VGPY" ledger "$CW" --ledger "$VT/e7.md" | vgp_j '(d["ok"], [i["kind"] for i in d["issues"]])')" "(False, ['verify_unlabelled'])"
# 표지 F 를 단 해시·서명 비교 우회는 STATIC.md 의 hash_engine 행이 있을 때만 통과한다 (아래 V1 시험).
# 여기서는 그 행이 있는 작업 폴더에서 라벨이 있으면 통과한다는 기존 사실만 본다.
vgp_static() { if [ "$1" = "-" ]; then rm -f "$CW/STATIC.md"; else printf '%s\n' "$1" > "$CW/STATIC.md"; fi; }
ROW_T='| hash_engine | hardware | SMC fid 0xc2000100, 함수 0x2375e8 |'
E7_F="$E7_HASH
- 메타: 종류=P; 표지=F; 출처=A; 도출=semi"
vgp_static "$ROW_T"
chk "  표지 F 를 달고 hash_engine 행이 있으면 통과"                       "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "0"
vgp_static -
chk "  메타는 있어도 표지가 F 가 아니면 반려 (종류=P · 표지=K)"              "$(vgp_cc "$E1" "$E1
$E7_HASH
- 메타: 종류=P; 표지=K; 출처=A; 도출=semi" 'int a;\nint b7;\n')" "2"
chk "  영어로만 쓴 기록(digest·signature)도 반려"                         "$(vgp_cc "$E1" "$E1
$(printf '%s' "$E2_OK" | sed 's/^- 대상: t2/- 대상: digest compare in the signature check/')")" "2"
chk "  종류=M (엔진을 모델링해 값이 실제로 계산됨)은 F 를 강요하지 않는다"    "$(vgp_cc "$E1" "$E1
$E7_HASH
- 메타: 종류=M; 출처=A; 도출=semi" 'int a;\nint b7;\n')" "0"
chk "  이 회차에 새로 쓴 기록만 막는다: 기준선의 옛 기록은 라벨이 없어도 통과" "$(vgp_cc "$E1
$E7_HASH" "$E1
$E7_HASH
$E2_OK")" "0"
chk "  그 옛 기록을 이번 회차에 고쳐 쓰면 다시 라벨을 요구한다"             "$(vgp_cc "$E1
$E7_HASH" "$E1
$(printf '%s' "$E7_HASH" | sed 's/항상 틀림/항상 틀림 (재도출)/')")" "2"
chk "  부작용 칸의 '검증'·'서명' 은 세지 않는다 (무엇이 검증 안 되는지 적는 칸)" "$(vgp_cc "$E1" "$E1
$E2_OK
$(printf '%s' "$E2_OK" | sed 's/#2/#3/; s/둘째/셋째/; s/타이머가 멈춘다/서명 검증이 이 경로에서 안 된다/')")" "0"
# 한 변경 검문의 기존 동작은 그대로
chk "기존: 소스 2 개를 동시에 고치면 반려"  "$(printf 'int x;\n' > "$CW/06_machine/other.c"; printf 'int a;\nint b;\n' > "$CW/06_machine/machine.c"; printf '%s\n' "$E1" > "$CW/06_machine/bypasses.md"; bash "$S/check_change.sh" "$CW" snapshot >/dev/null; printf 'int a;\nint bX;\n' > "$CW/06_machine/machine.c"; printf 'int x2;\n' > "$CW/06_machine/other.c"; bash "$S/check_change.sh" "$CW" verify >/dev/null 2>&1; echo $?)" "2"
bash "$S/check_change.sh" "$CW" restore >/dev/null 2>&1
chk "  restore: 소스는 스냅샷 내용으로, 스냅샷 때 있던 장부 기록은 그대로 (이번 회차에 쓴 기록의 되돌림은 V1a)"  "$(cat "$CW/06_machine/other.c"; head -c 6 "$CW/06_machine/bypasses.md")" "int x;
### #1"
# verify_gates.py ledger 직접
printf '%s\n%s\n' "$E1" "$(printf '%s' "$E2_OK" | sed 's/#2/#1/')" > "$VT/dup.md"
chk "ledger: 같은 번호가 두 기록에 겹치면 지적 (#43 사례)"  "$(python3 "$VGPY" ledger "$CW" --ledger "$VT/dup.md" | vgp_j '[i["kind"] for i in d["issues"]]')" "['dup_id']"

# =============================================================================
# 7-b. V1: 하드웨어 해시 예외의 선행 조건 — STATIC.md 의 hash_engine 행 (장부 검사, 네 번째 게이트 아님)
# =============================================================================
# 표지 F 를 단 해시·디제스트·서명 비교 우회는, 해시가 하드웨어 엔진에서 계산된다는 행이 STATIC.md 에
# 있을 때만 받는다. 종류=M(엔진 모델링)은 면제. 행이 없으면 check_change.sh 가 종료코드 2 로 반려하고
# 사유가 기록 번호와 빠진 행을 짚는다. 행은 static-analyzer 가 쓴다 (누가 썼는지는 기계가 모른다).
hdr "V1: STATIC.md 의 hash_engine 행 없이 쓰인 표지 F 해시 우회는 반려"
vgp_static -
chk "행 없음 (STATIC.md 도 없음): 표지 F 해시 비교 우회는 반려 (종료 2)" "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
chk "  사유가 기록 번호와 빠진 행을 짚는다 (#7, hash_engine, hardware)" "$(vgp_ccj '"#7" in d["reason"] and "hash_engine" in d["reason"] and "hardware" in d["reason"]')" "True"
chk "  STATIC.md 가 없다고 말한다"                                       "$(vgp_ccj '"STATIC.md 가 없습니다" in d["reason"]')" "True"
chk "  verify_gates.py ledger 는 hash_engine_row_missing 으로 지적한다 (ok=false)" \
    "$(printf '%s\n' "$E7_F" > "$VT/e7f.md"; python3 "$VGPY" ledger "$CW" --ledger "$VT/e7f.md" | vgp_j '(d["ok"], [i["kind"] for i in d["issues"]], d["hash_engine"]["status"])')" "(False, ['hash_engine_row_missing'], 'no_static')"
vgp_static '# STATIC

## 도출된 정지점

| 시그니처 | 관측 | 메커니즘 (근거) | 담당 fixer | 시도할 변경 |
|---|---|---|---|---|
| `avb_verify_fail` | digest 불일치 | 0x2375e8 | `fixer-secureboot` | 매체 |'
chk "행 없음 (STATIC.md 에 다른 행만): 반려, 사유는 행이 없다고 말한다" "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
chk "  사유: 하드웨어 엔진 행이 없습니다"                                "$(vgp_ccj '"행이 없습니다" in d["reason"]')" "True"
vgp_static "$ROW_T"
chk "표 행 (첫 칸 hash_engine, 둘째 칸 hardware, 근거에 0x… 주소) 이 있으면 통과"  "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "0"
vgp_static '- hash_engine: hardware (evidence: SMC fid 0xc2000100 로 나가는 지점 0x2375e8)'
chk "한 줄 형태 hash_engine: hardware (evidence: …) 도 같은 행으로 읽는다"         "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "0"
vgp_static '| `hash_engine` | **hardware** | 함수 0x2375e8 에서 SMC |'
chk "  백틱·굵게로 감싼 칸도 읽는다"                                          "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "0"
vgp_static '| hash_engine | software | 압축 라운드가 0x4010 의 함수 안에 있다 |'
chk "행이 software 이면 반려 (소프트웨어 해시는 무패치로 통과해야 한다)"            "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
chk "  사유가 software 를 짚는다"                                             "$(vgp_ccj '"software" in d["reason"]')" "True"
vgp_static '| hash_engine | hardware | |'
chk "행은 있으나 근거 칸이 비어 있으면 반려 (근거 없는 행은 추측이다)"             "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
chk "  사유가 근거(함수 주소·SMC id)를 짚는다"                                 "$(vgp_ccj '"근거" in d["reason"] and "SMC" in d["reason"]')" "True"
vgp_static '| hash_engine | hardware | 미확정 — 3 단계에서 확정 |'
chk "  근거가 '미확정' 이면 반려 (0x 주소가 뒤에 붙어도 앞이 미확정이면 도출이 아니다)" "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
vgp_static '| hash_engine | hardware | 하드웨어 엔진으로 보인다 |'
chk "  근거에 함수 주소나 SMC id (0x…) 가 없으면 반려"                          "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
vgp_static '```
| hash_engine | hardware | SMC fid 0xc2000100 |
```'
chk "코드 블록 안에 인용한 행은 도출된 사실이 아니다"                              "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
vgp_static '| hash_engine | hardware | SMC fid 0xc2000100 |
| hash_engine | software | 재도출: 압축 라운드가 0x4010 에 있다 |'
chk "STATIC.md 는 추가 전용이다: 나중에 쓴 software 행이 앞의 hardware 행을 바로잡는다" "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
vgp_static '| hash_engine | software | 처음 도출 0x4010 |
| hash_engine | hardware | 재도출: SMC fid 0xc2000100 |'
chk "  반대로 나중에 쓴 hardware 행이 앞의 software 를 바로잡으면 통과"             "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "0"
vgp_static -
chk "종류=M (엔진을 모델링) 은 면제: 표지 F 를 같이 달아도 행 없이 통과"           "$(vgp_cc "$E1" "$E1
$E7_HASH
- 메타: 종류=M; 표지=F; 출처=A; 도출=semi" 'int a;\nint b7;\n')" "0"
E8_LOCK='### #8 잠금 상태 값
- 대상: 기기 상태 워드
- 이유: r
- 방법: 값 3 을 돌려준다
- 부작용: 잠금 상태가 실제와 다르다
- 메타: 종류=V; 표지=F; 출처=B; 도출=manual'
chk "해시·서명 문구가 없는 표지 F 우회(상태 워드)는 이 검사를 부르지 않는다"      "$(vgp_cc "$E1" "$E1
$E8_LOCK" 'int a;\nint b8;\n')" "0"
chk "  avb · memcmp · 잠금 해제 같은 검증 단어만으로는 부르지 않는다 (해시 비교 한정)" "$(vgp_cc "$E1" "$E1
$(printf '%s' "$E8_LOCK" | sed 's/기기 상태 워드/avb memcmp 잠금 해제/')" 'int a;\nint b8;\n')" "0"
chk "표지 F 가 아니면 이 검사는 하지 않는다 (라벨 누락은 verify_unlabelled 가 따로 잡는다)" "$(vgp_cc "$E1" "$E1
$E7_HASH
- 메타: 종류=P; 표지=K; 출처=A; 도출=semi" 'int a;\nint b7;\n')" "2"
chk "  그 사유는 라벨이다 (hash_engine 행이 아니라 표지 F)"                      "$(vgp_ccj '"표지 F" in d["reason"] and "빠진" not in d["reason"]')" "True"
chk "  라벨 누락 사유가 hash_engine 행도 미리 알려 준다 (한 회차를 아끼려고)"       "$(vgp_ccj '"hash_engine" in d["reason"]')" "True"
chk "기준선에 이미 있던 표지 F 해시 기록은 행이 없어도 이번 회차를 막지 않는다"      "$(vgp_cc "$E1
$E7_F" "$E1
$E7_F
$E2_OK")" "0"
chk "  그 기록을 이번 회차에 고쳐 쓰면 다시 행을 요구한다"                       "$(vgp_cc "$E1
$E7_F" "$E1
$(printf '%s' "$E7_F" | sed 's/항상 틀림/항상 틀림 (재도출)/')")" "2"
# 단어 집합의 포함 관계: 해시 단어는 검증 단어의 부분집합이다 (보고가 세는 것 ⊇ 이 검사가 부르는 것)
chk "HASH_WORDS 의 모든 단어는 VERIFY_WORDS 에도 걸린다 (보고가 세는 행 ⊇ 검사가 부르는 행)" \
    "$(vgp_u "all(vg.VERIFY_WORDS.search(w) for w in ('hash', 'Digest', 'SIGNATURE', 'rsa', 'sha256', 'sha-1', '해시', '다이제스트', '서명') if vg.HASH_WORDS.search(w))")" "True"
chk "  memcmp · avb · unlock 은 HASH_WORDS 에 없다 (좁게 건다)"                  "$(vgp_u "[bool(vg.HASH_WORDS.search(w)) for w in ('memcmp', 'avb', 'unlock', 'verifiedboot', '검증', '인증')]")" "[False, False, False, False, False, False]"
# 보고: verify_bypass.hash_engine (건수에 더하지 않는다)
W=$(vgp_ws hashrow)
printf '%s\n' "$E7_F" > "$W/06_machine/bypasses.md"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "verify_bypass.hash_engine: 행이 없으면 row=false, 기대고 있는 기록과 근거 없는 기록을 적는다" \
    "$(echo "$J" | vgp_j '(lambda h: (h["row"], h["status"], [n["id"] for n in h["needed_by"]], h["unbacked"]))(d["verify_bypass"]["hash_engine"])')" "(False, 'no_static', ['7'], ['7'])"
COUNT_NO=$(echo "$J" | vgp_j 'd["verify_bypass"]["count"]')
chk "  참고 항목 7 (우회 기록) 도 같은 규칙으로 읽어 불통과 (판정은 그대로)"            "$(echo "$J" | vgp_j '(d["items"][6]["pass"], d["verdict"], d["gates_total"])')" "(False, 'VERIFIED', 3)"
printf '# STATIC\n%s\n' "$ROW_T" > "$W/STATIC.md"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "  행이 있으면 row=true, 근거와 줄 번호를 싣고 unbacked 는 비어 있다" \
    "$(echo "$J" | vgp_j '(lambda h: (h["row"], h["value"], h["line"], h["unbacked"], "0x2375e8" in h["evidence"]))(d["verify_bypass"]["hash_engine"])')" "(True, 'hardware', 2, [], True)"
chk "  행이 있어도 없어도 검증 우회 건수는 같다 (행은 신호가 아니라 선행 조건의 상태)"      "$(echo "$J" | vgp_j 'd["verify_bypass"]["count"]')" "$COUNT_NO"
chk "  항목 7 도 통과로 바뀐다"                                                "$(echo "$J" | vgp_j 'd["items"][6]["pass"]')" "True"
W=$(vgp_ws hashrow_none)
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "  해시 우회가 없는 장부는 needed_by 가 비어 있다 (행이 없어도 unbacked 없음)" \
    "$(echo "$J" | vgp_j '(lambda h: (h["row"], h["needed_by"], h["unbacked"]))(d["verify_bypass"]["hash_engine"])')" "(False, [], [])"
vgp_static -
# 정본 시험(canon.sh)이 "기계 검사가 구현되었다" 를 알아보는 표지: 이 이름이 코드에서 사라지면 검사도 없는 것이다
chk "표지: verify_gates.py 에 hash_engine_row_missing 검사 종류가 있다 (정본 시험이 읽는다)" \
    "$(grep -q "\"kind\": \"hash_engine_row_missing\"" "$S/verify_gates.py" && echo yes || echo no)" "yes"

# =============================================================================
# 7-b2. V1a: 반려된 변경은 우회 기록까지 되돌린다 (check_change.sh restore)
# =============================================================================
# restore 가 소스만 되돌리면 반려된 표지 F 기록이 장부에 남는다. 다음 회차의 스냅샷은 그 장부를 기준선(옛
# 이력)으로 삼고, 회차 검사는 기준선에 있는 기록을 다시 보지 않으므로, 같은 소스 패치를 한 회차 뒤에 다시
# 넣으면 hash_engine 행 없이 통과한다. 반려된 기록이 이력이 되지 않게 restore 가 장부도 스냅샷 시점으로 돌린다.
hdr "V1a: restore 는 반려된 변경의 우회 기록도 되돌린다"
RW="$VT/rs"; rm -rf "$RW"; mkdir -p "$RW/06_machine"
rs_j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$VT/rs.json" "$1"; }
rs_try() {   # $1 = 회차, $2 = 새 machine.c (printf %b), $3 = 장부에 덧붙일 기록 (제목이 이미 장부에 있으면 덧붙이지 않는다: 재시도) -> verify 종료코드
  bash "$S/check_change.sh" "$RW" snapshot "$1" >/dev/null
  printf '%b' "$2" > "$RW/06_machine/${RS_SRC:-machine.c}"
  if [ -n "$3" ] && ! grep -qxF "$(printf '%s\n' "$3" | head -1)" "$RW/06_machine/bypasses.md"; then
    printf '\n%s\n' "$3" >> "$RW/06_machine/bypasses.md"
  fi
  bash "$S/check_change.sh" "$RW" verify > "$VT/rs.json" 2>/dev/null; echo $?
}
printf '%s\n' "$E1" > "$RW/06_machine/bypasses.md"; printf 'int a;\nint b;\n' > "$RW/06_machine/machine.c"
cp "$RW/06_machine/bypasses.md" "$VT/rs_base.md"
chk "회차 1: STATIC.md 에 행이 없는 표지 F 해시 우회는 반려 (종료 2)"           "$(rs_try 1 'int a;\nint b7;\n' "$E7_F")" "2"
chk "  사유가 hash_engine 행을 짚는다"                                          "$(rs_j '"hash_engine" in d["reason"]')" "True"
bash "$S/check_change.sh" "$RW" restore >/dev/null 2>&1
chk "  restore: 소스가 스냅샷 내용으로 돌아온다"                                 "$(cat "$RW/06_machine/machine.c")" "int a;
int b;"
chk "  restore: 반려된 #7 기록이 장부에 남지 않는다 (장부 = 스냅샷 때)"           "$(cmp -s "$RW/06_machine/bypasses.md" "$VT/rs_base.md" && echo same || echo differs)" "same"
chk "  restore 뒤 표지 F 행은 기준선과 같은 0 개 (유령 기록이 검증 우회로 세어지지 않는다)" "$(grep -c '표지=F' "$RW/06_machine/bypasses.md")" "0"
# 검찰이 재현한 흐름: 한 회차 뒤에 같은 소스 패치를 다시 넣고, 기록은 장부에 없을 때만 쓴다
chk "회차 2: 같은 패치를 다시 넣어도 통과하지 못한다 (한 회차 뒤의 재시도)"        "$(rs_try 2 'int a;\nint b7;\n' "$E7_F")" "2"
chk "  사유는 다시 hash_engine 행이다 (기준선으로 건너뛰지 않는다)"               "$(rs_j '"hash_engine" in d["reason"] and "#7" in d["reason"]')" "True"
bash "$S/check_change.sh" "$RW" restore >/dev/null 2>&1
chk "회차 3: 세 번째 재시도도 같다 (반려가 쌓여도 이력이 되지 않는다)"              "$(rs_try 3 'int a;\nint b7;\n' "$E7_F")" "2"
bash "$S/check_change.sh" "$RW" restore >/dev/null 2>&1

# 같은 구멍이 열려 있던 다른 검사: 부작용 비움 · 표지 없는 검증 단어
E9_EMPTY='### #9 비운 부작용
- 대상: t9
- 이유: r9
- 방법: m9
- 부작용:'
chk "부작용을 비운 기록도 반려된 뒤 이력이 되지 않는다 (회차 4 반려 → 회차 5 재시도 반려)" \
    "$(rs_try 4 'int a;\nint b9;\n' "$E9_EMPTY"; bash "$S/check_change.sh" "$RW" restore >/dev/null 2>&1; rs_try 5 'int a;\nint b9;\n' "$E9_EMPTY")" "2
2"
bash "$S/check_change.sh" "$RW" restore >/dev/null 2>&1
chk "표지 없이 검증 단어를 쓴 기록도 같다 (회차 6 반려 → 회차 7 재시도 반려)" \
    "$(rs_try 6 'int a;\nint b7;\n' "$E7_HASH"; bash "$S/check_change.sh" "$RW" restore >/dev/null 2>&1; rs_try 7 'int a;\nint b7;\n' "$E7_HASH")" "2
2"
bash "$S/check_change.sh" "$RW" restore >/dev/null 2>&1
chk "  restore 뒤 장부는 처음 스냅샷과 같다 (기록 1 건)"                         "$(cmp -s "$RW/06_machine/bypasses.md" "$VT/rs_base.md" && echo same || echo differs)" "same"

# 통과한 회차는 되돌리지 않는다: 새 기록이 장부에 남아 다음 기준선이 된다
printf 'int a;\nint b;\n' > "$RW/06_machine/machine.c"
chk "통과한 회차(해시와 무관한 새 기록)는 장부에 남는다"                         "$(rs_try 8 'int a;\nint b2;\n' "$E2_OK"; grep -c '^### #2 ' "$RW/06_machine/bypasses.md")" "0
1"

# verify.py 의 보고: 반려된 기록이 검증 우회 건수로 세어지지 않는다
W=$(vgp_ws restore_rep)
RW_SAVE="$RW"; RW="$W"; RS_SRC=machine_full.c
rs_try 1 'static void w(void){ qemu_chr_fe_write_all(&s->chr,&b,1); }\nint b7;\n' "$E7_F" >/dev/null
bash "$S/check_change.sh" "$W" restore >/dev/null 2>&1
RW="$RW_SAVE"; RS_SRC=machine.c
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "반려 + restore 뒤 verify.py: 검증 우회 0 건, hash_engine 이 기대는 기록 없음 (유령 기록이 '검증 우회 1건' 을 만들지 않는다)" \
    "$(echo "$J" | vgp_j '(d["verify_bypass"]["count"], d["verify_bypass"]["hash_engine"]["needed_by"], d["verify_bypass"]["hash_engine"]["unbacked"], d["verdict"])')" "(0, [], [], 'VERIFIED')"

# 장부가 없던 스냅샷, 옛 이름의 장부, 이번 회차가 만든 새 소스, 표지가 없는 옛 스냅샷
RW0="$VT/rs0"; rm -rf "$RW0"; mkdir -p "$RW0/06_machine"; printf 'int a;\n' > "$RW0/06_machine/machine.c"
bash "$S/check_change.sh" "$RW0" snapshot >/dev/null
printf 'int a;\nint b;\n' > "$RW0/06_machine/machine.c"; printf '%s\n' "$E7_F" > "$RW0/06_machine/bypasses.md"
bash "$S/check_change.sh" "$RW0" restore >/dev/null 2>&1
chk "스냅샷 때 장부가 없었으면 restore 가 이번 회차에 새로 쓴 장부를 지운다"         "$([ -e "$RW0/06_machine/bypasses.md" ] && echo kept || echo gone)" "gone"
RWL="$VT/rsl"; rm -rf "$RWL"; mkdir -p "$RWL/06_machine"; printf 'int a;\n' > "$RWL/06_machine/machine.c"
printf '%s\n' "$E1" > "$RWL/06_machine/우회_패치_목록.md"
bash "$S/check_change.sh" "$RWL" snapshot >/dev/null
printf 'int a;\nint b;\n' > "$RWL/06_machine/machine.c"
printf '%s\n%s\n' "$E1" "$E7_F" > "$RWL/06_machine/bypasses.md"; printf '%s\n%s\n' "$E1" "$E7_F" > "$RWL/06_machine/우회_패치_목록.md"
bash "$S/check_change.sh" "$RWL" restore >/dev/null 2>&1
chk "옛 이름(우회_패치_목록.md)의 장부는 그 이름으로 되돌리고, 새로 생긴 bypasses.md 는 지운다 (우선 이름이 가리지 않게)" \
    "$(cmp -s "$RWL/06_machine/우회_패치_목록.md" <(printf '%s\n' "$E1") && echo same || echo differs) $([ -e "$RWL/06_machine/bypasses.md" ] && echo kept || echo gone)" "same gone"
RWN="$VT/rsn"; rm -rf "$RWN"; mkdir -p "$RWN/06_machine"; printf 'int a;\n' > "$RWN/06_machine/machine.c"
printf '%s\n' "$E1" > "$RWN/06_machine/bypasses.md"
bash "$S/check_change.sh" "$RWN" snapshot >/dev/null
printf 'int a;\nint b;\n' > "$RWN/06_machine/machine.c"; printf 'int c; /* bypass:5 */\n' > "$RWN/06_machine/extra.c"
OUTR=$(bash "$S/check_change.sh" "$RWN" restore 2>&1)
chk "이번 회차에 만든 새 소스는 restore 가 지운다 (표 행 태그가 기록보다 오래 남지 않게)" \
    "$([ -e "$RWN/06_machine/extra.c" ] && echo kept || echo gone) $(cat "$RWN/06_machine/machine.c")" "gone int a;"
chk "  지운 새 소스를 restore 출력이 알린다"                                     "$(printf '%s' "$OUTR" | grep -c 'extra.c')" "1"
RWO2="$VT/rso"; rm -rf "$RWO2"; mkdir -p "$RWO2/06_machine"; printf 'int a;\n' > "$RWO2/06_machine/machine.c"
printf '%s\n' "$E1" > "$RWO2/06_machine/bypasses.md"
bash "$S/check_change.sh" "$RWO2" snapshot >/dev/null
rm -f "$RWO2/08_docs/.record/pre_ledger.name"          # 옛 버전이 만든 스냅샷에는 표지가 없다
printf 'int a;\nint b;\n' > "$RWO2/06_machine/machine.c"; printf '%s\n%s\n' "$E1" "$E2_OK" > "$RWO2/06_machine/bypasses.md"
bash "$S/check_change.sh" "$RWO2" restore >/dev/null 2>&1
chk "표지가 없는 옛 스냅샷이면 장부는 건드리지 않는다 (옛 동작 그대로, 소스만 복원)" \
    "$(grep -c '^### #2 ' "$RWO2/06_machine/bypasses.md") $(cat "$RWO2/06_machine/machine.c")" "1 int a;"

# 회차 검사는 이번 회차 것만 본다는 설계는 그대로다: 기준선에 있는 기록은 회차를 막지 않지만,
# 장부 전체를 읽는 쪽(verify_gates.py ledger 기준선 없음, verify.py 참고 항목 7)은 같은 기록을 지적한다
RWB="$VT/rsb"; rm -rf "$RWB"; mkdir -p "$RWB/06_machine"; printf 'int a;\nint b;\n' > "$RWB/06_machine/machine.c"
printf '%s\n%s\n' "$E1" "$E7_F" > "$RWB/06_machine/bypasses.md"
bash "$S/check_change.sh" "$RWB" snapshot >/dev/null
printf 'int a;\nint b2;\n' > "$RWB/06_machine/machine.c"
chk "기준선에 이미 있는 행 없는 F 해시 기록: 회차 게이트는 통과 (옛 이력은 이번 회차를 막지 않는다)" "$(bash "$S/check_change.sh" "$RWB" verify >/dev/null 2>&1; echo $?)" "0"
chk "  장부 전체를 읽으면 같은 기록을 hash_engine_row_missing 으로 지적한다"          "$(python3 "$VGPY" ledger "$RWB" | vgp_j '(d["ok"], [i["kind"] for i in d["issues"]])')" "(False, ['hash_engine_row_missing'])"

# =============================================================================
# 7-b3. V1b: STATIC.md hash_engine 행의 자리표시자와 어림
# =============================================================================
# 자리표시자 정규식이 단어 경계 없이 접두 일치였을 때, na·tbd·todo·unknown 으로 시작하는 정상 근거
# (nand_hash_fn · native · tbdigest)가 버려지고, 반대로 `hardware? undetermined 0x1234` 는 통과했다.
hdr "V1b: hash_engine 행 — 자리표시자는 단어 끝에서만, 어림은 행이 아니다"
vgp_row() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import verify_gates as vg; print([x["ok"] for x in vg.parse_hash_engine_rows(sys.argv[2])])' "$S" "$1"; }
chk "근거가 na·tbd·todo·unknown 글자로 시작하는 식별자여도 도출된 행이다 (nand_hash_fn)"  "$(vgp_row '| hash_engine | hardware | nand_hash_fn 0x1234, SMC 0x82000001 |')" "[True]"
chk "  native crypto SMC id 0x82000010"                                                 "$(vgp_row '| hash_engine | hardware | native crypto SMC id 0x82000010 |')" "[True]"
chk "  tbdigest 0x5555"                                                                  "$(vgp_row '| hash_engine | hardware | tbdigest 0x5555 |')" "[True]"
chk "  unknown_cmd_handler 0x40 (밑줄은 단어의 일부)"                                      "$(vgp_row '| hash_engine | hardware | unknown_cmd_handler 0x40 에서 SMC |')" "[True]"
chk "  한 줄 형태의 nand_hash_fn 도 같다"                                                 "$(vgp_row '- hash_engine: hardware (evidence: nand_hash_fn 0x1234)')" "[True]"
chk "자리표시자는 여전히 도출이 아니다: unknown · n/a · N/A · TBD · todo · unconfirmed · 미확정" \
    "$(for t in 'unknown 0x1' 'n/a 0x1' 'N/A 0x10' 'TBD: 0x5' 'todo 0x7' 'unconfirmed 0x9' '미확정 0x1234' 'na 0x1'; do vgp_row "| hash_engine | hardware | $t |"; done | tr '\n' ' ')" \
    "[False] [False] [False] [False] [False] [False] [False] [False] "
chk "값 뒤에 물음표를 붙이면 행이 아니다 (한 줄: hardware? undetermined 0x1234)"          "$(vgp_row '- hash_engine: hardware? undetermined 0x1234')" "[False]"
chk "  hardware (?) 0x1234"                                                              "$(vgp_row '- hash_engine: hardware (?) 0x1234')" "[False]"
chk "  표: 값 칸이 hardware? 이면 행이 아니다"                                             "$(vgp_row '| hash_engine | hardware? | SMC 0x1234 |')" "[False]"
chk "  근거에 물음표 · maybe · probably · 추정 이 있으면 어림이다"                            "$(for t in 'SMC 0x1234 ?' 'SMC 0x1234 (maybe)' 'probably SMC 0x1234' 'SMC 0x1234 추정' '아마 SMC 0x1234'; do vgp_row "| hash_engine | hardware | $t |"; done | tr '\n' ' ')" "[False] [False] [False] [False] [False] "
chk "  어림 낱말이 식별자의 일부이면 어림이 아니다 (maybe_fn · likelyhood_tab)"             "$(for t in 'maybe_fn 0x10' 'likelyhood_tab 0x20'; do vgp_row "| hash_engine | hardware | $t |"; done | tr '\n' ' ')" "[True] [True] "
vgp_static '- hash_engine: hardware? undetermined 0x1234'
chk "check_change: 어림으로 쓴 행은 (b) 의 문을 열지 못한다 (종료 2)"                      "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "2"
chk "  사유가 어림이라고 말한다"                                                         "$(vgp_ccj '"어림" in d["reason"]')" "True"
vgp_static '| hash_engine | hardware | nand_hash_fn 0x1234, SMC 0x82000001 |'
chk "check_change: nand_hash_fn 근거의 행은 (b) 를 통과시킨다 (예전에는 unevidenced 로 버려졌다)" "$(vgp_cc "$E1" "$E1
$E7_F" 'int a;\nint b7;\n')" "0"
chk "  hash_engine_state 는 hardware, 무시한 행 없음"                                       "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import verify_gates as vg; s = vg.hash_engine_state(sys.argv[2]); print((s["status"], s["ignored"]))' "$S" "$CW")" "('hardware', [])"
vgp_static -

# =============================================================================
# 7-c. V2: STATIC.md 의 "주소 창" 표 (참고 지표, 게이트 아님)
# =============================================================================
# templates/machine_mixed_arch.c.tmpl 의 Conventions 가 정의한 10 열 표. verify.py 는 있는지(present),
# 없는지(missing), 열이 모자라는지(columns_incomplete), 보안 영향 칸이 빈 창이 몇 개인지만 보고한다.
# 혼합 아키텍처가 아닌 머신은 조용히 건너뛴다 (노트만). 판정은 어떤 경우에도 바뀌지 않는다.
hdr "V2: 주소 창 표 (참고 지표)"
H10='| base | size | name | source | model | phase | kind | evidence | bypass | security_effect |
|---|---|---|---|---|---|---|---|---|---|'
W=$(vgp_ws awin_plain)
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "혼합 아키텍처가 아닌 머신: 건너뛰고 노트만 (항목 없음, 항목 수 7)" \
    "$(echo "$J" | vgp_j '(d["address_windows"]["applicable"], d["address_windows"]["status"], "혼합" in d["address_windows"]["note"], len(d["items"]))')" "(False, None, True, 7)"
BASE_V=$(echo "$J" | vgp_j '(d["verdict"], d["gates_passed"], d["gates_total"])')
W=$(vgp_ws awin_mixed)
printf 'static void handoff_tick(void *o){ }\nstatic void w(void){ qemu_chr_fe_write_all(&s->chr,&b,1); }\n' > "$W/06_machine/machine_full.c"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "혼합 머신 + STATIC.md 없음: missing, 참고 항목 8 불통과, 판정은 그대로" \
    "$(echo "$J" | vgp_j '(d["address_windows"]["status"], d["items"][7]["n"], d["items"][7]["gate"], d["items"][7]["pass"], d["verdict"], d["gates_total"])')" "('missing', 8, False, False, 'VERIFIED', 3)"
printf '# STATIC\n\n## 도출된 정지점\n\n| 시그니처 | 관측 |\n|---|---|\n| x | y |\n' > "$W/STATIC.md"
chk "  STATIC.md 에 표가 없으면 missing, 노트가 기록이 닿지 않는다고 말한다" \
    "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(d["address_windows"]["status"], "닿지 않습니다" in d["address_windows"]["note"])')" "('missing', True)"
printf '# STATIC\n\n## 주소 창 (address windows)\n\n%s\n| 0x1000 | 0x1000 | a | dtb | shadow | both | M | 함수 0x10 | | false |\n| 0x2000 | 0x1000 | b | observed | dedicated | both | V | 로그 줄 | #3 | |\n| 0x3000 | 0x1000 | c | assumed | override | post_handoff | V | 가정 | #4 | true |\n' "$H10" > "$W/STATIC.md"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "  10 열 표: present, 창 3 행, 보안 영향 칸이 빈 행 1, true 1" \
    "$(echo "$J" | vgp_j '(lambda a: (a["status"], a["windows"], a["security_effect_empty"], a["security_effect_true"], a["missing_columns"]))(d["address_windows"])')" "('present', 3, 1, 1, [])"
chk "  보안 영향이 빈 행이 있으면 참고 항목 8 은 불통과 (본문에 빈 행 수)" \
    "$(echo "$J" | vgp_j '(d["items"][7]["pass"], "빈 행 1" in d["items"][7]["evidence"], d["verdict"], d["gates_total"], d["gates_passed"])')" "(False, True, 'VERIFIED', 3, 3)"
# 분석가는 도출하지 못한 칸에 미확정을 쓴다. 그 칸도 아직 아무도 답하지 않은 칸이다
printf '# STATIC\n\n## 주소 창 (address windows)\n\n%s\n| 0x1000 | 0x1000 | a | dtb | shadow | both | M | 함수 0x10 | | 미확정 |\n| 0x2000 | 0x1000 | b | observed | dedicated | both | V | 로그 줄 | #3 | |\n| 0x3000 | 0x1000 | c | assumed | override | post_handoff | V | 가정 | #4 | true |\n' "$H10" > "$W/STATIC.md"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "  security_effect 에 미확정을 쓴 행도 빈 행으로 센다 (창 3, 빈 행 2 = 공란 1 + 미확정 1, 미확정 1, true 1)" \
    "$(echo "$J" | vgp_j '(lambda a: (a["windows"], a["security_effect_empty"], a["security_effect_undetermined"], a["security_effect_true"]))(d["address_windows"])')" "(3, 2, 1, 1)"
chk "  항목 8 은 불통과이고 증거가 빈 행 2 와 그 중 미확정 1 을 말한다" \
    "$(echo "$J" | vgp_j '(d["items"][7]["pass"], "빈 행 2" in d["items"][7]["evidence"], "미확정·추정으로 적힌 행 1" in d["items"][7]["evidence"])')" "(False, True, True)"
printf '# STATIC\n\n## 주소 창\n\n%s\n| 0x1 | 0x1000 | a | dtb | shadow | both | M | x | | unknown |\n| 0x2 | 0x1000 | a | dtb | shadow | both | M | x | | TBD |\n| 0x3 | 0x1000 | a | dtb | shadow | both | M | x | | n/a |\n| 0x4 | 0x1000 | a | dtb | shadow | both | M | x | | true? |\n| 0x5 | 0x1000 | a | dtb | shadow | both | M | x | | false |\n| 0x6 | 0x1000 | a | dtb | shadow | both | M | x | | native |\n| 0x7 | 0x1000 | a | dtb | shadow | both | M | x | | true |\n' "$H10" > "$W/STATIC.md"
chk "  unknown · TBD · n/a · true? 도 미확정과 같다. false · native(na 로 시작하는 낱말) · true 는 아니다" \
    "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(lambda a: (a["windows"], a["security_effect_empty"], a["security_effect_undetermined"], a["security_effect_true"]))(d["address_windows"])')" "(7, 4, 4, 1)"
printf '# STATIC\n\n## 주소 창\n\n%s\n| 0x1000 | 0x1000 | a | dtb | shadow | both | M | 함수 0x10 | | false |\n' "$H10" > "$W/STATIC.md"
chk "  전부 채우면 참고 항목 8 통과"                                       "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(d["items"][7]["pass"], d["address_windows"]["security_effect_empty"])')" "(True, 0)"
printf '# STATIC\n\n## 주소 창\n\n| base | size | name | source | model | phase | kind | evidence | bypass |\n|---|---|---|---|---|---|---|---|---|\n| 0x1000 | 0x1000 | a | dtb | shadow | both | M | x | |\n' > "$W/STATIC.md"
J=$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin")
chk "  열이 모자라면 columns_incomplete 와 빠진 열 이름 (security_effect), 항목 8 불통과" \
    "$(echo "$J" | vgp_j '(d["address_windows"]["status"], d["address_windows"]["missing_columns"], d["items"][7]["pass"])')" "('columns_incomplete', ['security_effect'], False)"
chk "  열이 모자란 표는 모든 창이 보안 영향 미기재로 센다"                       "$(echo "$J" | vgp_j 'd["address_windows"]["security_effect_empty"] == d["address_windows"]["windows"] == 1')" "True"
printf '# STATIC\n\n## 기타\n\n%s\n| 0x1000 | 0x1000 | a | dtb | shadow | both | M | x | | false |\n' "$(printf '%s' "$H10" | sed 's/security_effect/security effect/')" > "$W/STATIC.md"
chk "  제목이 없어도 base · size · 템플릿 열을 가진 표는 주소 창 표로 읽고, 'security effect' 철자도 받는다" \
    "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(d["address_windows"]["status"], d["address_windows"]["windows"])')" "('present', 1)"
printf '# STATIC\n\n```\n## 주소 창\n%s\n| 0x1000 | 0x1000 | a | dtb | shadow | both | M | x | | false |\n```\n' "$H10" > "$W/STATIC.md"
chk "  코드 블록 안의 표는 읽지 않는다"                                       "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j 'd["address_windows"]["status"]')" "missing"
printf '# STATIC\n\n## 주소 창\n\n%s\n| 0x1000 | 0x1000 | a | dtb | shadow | both | M | x | | false |\n\n## 이어서 추가한 주소 창\n\n%s\n| 0x2000 | 0x1000 | b | dtb | shadow | both | V | y | | true |\n| 0x3000 | 0x1000 | c | dtb | shadow | both | V | z | | |\n' "$H10" "$H10" > "$W/STATIC.md"
chk "  추가 전용 기록: 여러 번에 나눠 쓴 표를 합친다 (창 3, 빈 행 1)"             "$(vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(lambda a: (a["tables"], a["windows"], a["security_effect_empty"]))(d["address_windows"])')" "(2, 3, 1)"
chk "표가 있든 없든 판정과 게이트 수는 같다 (참고 지표일 뿐)"                    "$(echo "$J" | vgp_j '(d["verdict"], d["gates_passed"], d["gates_total"])')" "$BASE_V"
chk "  VERIFIED 판정과 게이트 3 항 (표 없음·열 모자람 모두 같은 판정)"             "$(rm -f "$W/STATIC.md"; vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(d["verdict"], d["gates_passed"], d["gates_total"])')" "$BASE_V"

# verifier 가 읽는 안내에 새 보고 항목이 이름으로 있다 (verify.py 가 내는 키와 같은 이름)
VERMD="$REPO/agents/verifier.md"
vgp_has() { grep -qF -- "$2" "$1" && echo yes || echo no; }
chk "verifier.md: verify_bypass.hash_engine 을 읽으라고 한다"                 "$(vgp_has "$VERMD" 'verify_bypass.hash_engine')" "yes"
chk "  row · unbacked · needed_by 의 뜻을 적는다"                              "$(vgp_has "$VERMD" '`unbacked`') $(vgp_has "$VERMD" '(`needed_by`)')" "yes yes"
chk "  해시 행은 필요 조건이지 증명이 아니라고 적는다"                         "$(vgp_has "$VERMD" 'necessary condition, never a proof')" "yes"
chk "verifier.md: 주소 창 표(address_windows, 항목 8)는 참고 지표이고 판정을 낮추지 않는다" \
    "$(vgp_has "$VERMD" '(`address_windows`, item 8') $(vgp_has "$VERMD" 'never lowers the verdict')" "yes yes"
chk "verifier.md: check_change.sh 는 회차 단위 게이트이고, 반려하면 소스와 장부를 함께 되돌린다고 적는다" \
    "$(vgp_has "$VERMD" 'is a **per-round** gate') $(vgp_has "$VERMD" 'rolls the sources **and**')" "yes yes"
chk "  장부에 없는 패치는 개수가 보지 못하니 소스를 직접 읽으라고 적는다"                               "$(vgp_has "$VERMD" 'Read the source for comparison patches the ledger does not')" "yes"
chk "  unevidenced 와 security_effect_undetermined 의 뜻을 적는다"                                   "$(vgp_has "$VERMD" '`unevidenced` means a row is there') $(vgp_has "$VERMD" '`security_effect_undetermined`')" "yes yes"

# =============================================================================
# 8. 증거 준비 (verify_prep.py)
# =============================================================================
PW="$VT/prep"; rm -rf "$PW"; mkdir -p "$PW/fw" "$PW/07_logs"
cat > "$VT/mkboot.py" <<'PY'
import gzip, struct, sys
wd = sys.argv[1]
kernel = b"\0" * 64 + b"Linux version 4.14.186-prep (builder) #1 SMP\0" + b"mmcblk%d: p%d\0" + b"\0" * 100
def newc(name, data, ino):
    nm = name.encode() + b"\0"
    hdr = b"070701" + b"".join(b"%08X" % v for v in (ino, 0o100644, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nm), 0))
    out = hdr + nm
    out += b"\0" * ((4 - len(out) % 4) % 4) + data
    return out + b"\0" * ((4 - len(out) % 4) % 4)
cpio = newc("init", b"#!/system/bin/sh\n", 1) + newc("etc/fstab", b"system /system ext4 ro\n", 2) + newc("TRAILER!!!", b"", 0)
gk, gr = gzip.compress(kernel), gzip.compress(cpio)
page = 4096
hdr = bytearray(page)
hdr[0:8] = b"ANDROID!"
struct.pack_into("<I", hdr, 8, len(gk)); struct.pack_into("<I", hdr, 16, len(gr)); struct.pack_into("<I", hdr, 36, page)
pad = lambda b: b + b"\0" * ((-len(b)) % page)
open(wd + "/fw/boot.img", "wb").write(bytes(hdr) + pad(gk) + pad(gr))
# 3 MB 파일의 조각 경계(1 MB - 4 KB 간격)에 걸치는 문자열
big = bytearray(3 * 1024 * 1024)
mark = b"SEAM-CROSSING-STRING-THAT-MUST-STAY-WHOLE"
at = 1024 * 1024 - 20
big[at:at + len(mark)] = mark
open(wd + "/big.bin", "wb").write(bytes(big))
PY
python3 "$VT/mkboot.py" "$PW"
printf '1791179918.17 qemu-system-aarch64: info: x\r\nS-BOOT # hello\r\n\rLinux version 4.14.186-prep ok\n[ 1.0] calling foo+0x10/0x20 @ 1\n[ 2.0] value 0xdeadbeef ok\nDBGC marker\n: [0x1234] = 0x55\n' > "$PW/07_logs/console_1.txt"
printf '0.000000 Linux version 4.14.186-prep (builder)\n1.500000 mmcblk0: p1 p2\n' > "$PW/07_logs/kernel_1.log"
printf '{"prism":"forged"}\n' > "$PW/fw/lu_provenance.json"
mkdir -p "$PW/tree"; printf 'tree file text\n' > "$PW/tree/a.txt"; printf 'forged text\n' > "$PW/tree/prism.img"
J=$(python3 "$S/verify_prep.py" "$PW" --flatten "$PW/big.bin" "$PW/tree" --piece-mb 1 --overlap-kb 4 2>/dev/null)
chk "boot.img 의 gzip 커널을 풀어 kernel_Image.img 로"        "$(echo "$J" | vgp_j '(d["boot"]["kernel"]["compressed"], d["boot"]["kernel"]["bytes_out"] > d["boot"]["kernel"]["bytes_in"])')" "('gzip', True)"
chk "  풀린 커널에 배너가 있다 (원본 boot.img 에는 없다)"      "$(grep -c 'Linux version 4.14.186-prep' "$PW/verify_ref/kernel_Image.img"; grep -c 'Linux version' "$PW/fw/boot.img")" "1
0"
chk "램디스크를 풀고 cpio 항목을 센다"                        "$(echo "$J" | vgp_j '(d["boot"]["ramdisk"]["compressed"], d["boot"]["ramdisk"]["entries"])')" "('gzip', 2)"
chk "큰 파일은 상한(128MB) 아래 조각으로 — 겹치는 창"           "$(echo "$J" | vgp_j 'len(d["flatten"]["pieces"]) >= 3')" "True"
chk "  조각 경계에 걸친 문자열이 어느 한 조각 안에 온전히 있다"  "$(grep -l 'SEAM-CROSSING-STRING-THAT-MUST-STAY-WHOLE' "$PW"/verify_ref/flat_*.bin | wc -l | tr -d ' ')" "1"
chk "  lu_provenance 가 forged 로 적은 파일은 평탄화에서 제외"    "$(echo "$J" | vgp_j '[x["file"].split("/")[-1] for x in d["flatten"]["excluded"]]')" "['prism.img']"
chk "콘솔: 원본 보존(호스트 줄만 제거) + 정규화본"               "$(echo "$J" | vgp_j '(d["console"]["lines_raw"], d["console"]["lines_normalized"], d["console"]["host_lines_dropped"])')" "(8, 5, 1)"
chk "  규칙별 횟수: R1 치환 · R2·R3·R4 삭제"                    "$(echo "$J" | vgp_j '[d["console"]["rules"][k] for k in ("R1","R2","R3","R4")]')" "[1, 1, 1, 1]"
cat > "$VT/subset.py" <<'PY'
import re, sys
wd = sys.argv[1]
raw = [l for l in open(wd + "/07_logs/guest_console_1.raw.txt", "rb").read().split(b"\n") if l]
norm = [l for l in open(wd + "/07_logs/guest_console_1.norm.txt", "rb").read().split(b"\n") if l]
derived = {re.sub(rb"0[xX][0-9A-Fa-f]+", b"0x", l) for l in raw}
print(all(l in derived for l in norm), len(norm) <= len(raw), any(b"0xdeadbeef" in l for l in raw), any(b"0xdeadbeef" in l for l in norm))
PY
chk "정규화본의 모든 줄은 원본 줄의 치환이다 (추가 없음), 원본에는 0xdeadbeef 가 남아 있다"  "$(python3 "$VT/subset.py" "$PW")" "True True True False"
chk "  앞에 \\r 이 붙은 게스트 줄이 버려지지 않는다 (바이너리로 읽음)"     "$(grep -c '^Linux version 4.14.186-prep ok' "$PW/07_logs/guest_console_1.raw.txt")" "1"
chk "  원래의 console_1.txt 는 건드리지 않는다"                          "$(head -c 10 "$PW/07_logs/console_1.txt")" "1791179918"
# 준비한 산출물로 게이트를 돈다: 배너는 압축 해제한 커널에만 있고, 게이트 1 은 원본을 읽는다
mkdir -p "$PW/06_machine" "$PW/03_bootloader"
cp "$VT/tx1.c" "$PW/06_machine/machine_full.c"
printf '### #1 x\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$PW/06_machine/bypasses.md"
printf 'S-BOOT # hello\0value ok\0' > "$PW/03_bootloader/fw.bin"
J=$(vgp_v "$PW" --target F2 --container "$PW/03_bootloader/fw.bin" --round 1)
chk "verify.py 가 정규화 콘솔을 게이트 2 에 쓴다 (게이트 1 은 원본)"  "$(echo "$J" | vgp_j '(d["items"][1]["detail"]["reference"]["console"], d["items"][1]["pass"], d["items"][0]["pass"])')" "('guest_console_1.norm.txt', True, True)"
rm -rf "$PW/verify_ref"
chk "  준비 단계를 빼면 커널 문자열이 압축 안에 있어 불통과"           "$(vgp_v "$PW" --target F2 --container "$PW/03_bootloader/fw.bin" --round 1 | vgp_j 'd["items"][1]["pass"]')" "False"

# =============================================================================
# 9. 훼손 매체 (make_negative_image.py)
# =============================================================================
NW="$VT/neg"; rm -rf "$NW"; mkdir -p "$NW/fw"
python3 "$VT/mkgpt.py" "$NW"
SHA0=$(vgp_sha "$NW/fw/lu0.img")
J=$(python3 "$S/make_negative_image.py" "$NW")
chk "원본과 다른 파일에 복사본을 만든다 (기본 이름 lu0_negative.img)"  "$(echo "$J" | vgp_j '(d["ok"], d["image"].split("/")[-1])')" "(True, 'lu0_negative.img')"
chk "  원본은 바이트 하나도 바뀌지 않는다"                          "$(vgp_sha "$NW/fw/lu0.img" | sed "s/^$SHA0\$/same/")" "same"
chk "  기본 대상은 GPT 의 vbmeta 파티션"                            "$(echo "$J" | vgp_j '(d["partition"], d["located_by"])')" "('vbmeta', 'GPT')"
cat > "$VT/diffcount.py" <<'PY'
import json, sys
a = open(sys.argv[1], "rb").read(); b = open(sys.argv[2], "rb").read()
d = json.loads(sys.argv[3])
diff = [i for i in range(len(a)) if a[i] != b[i]]
print(len(a) == len(b), len(diff), diff == [d["offset_abs"]], d["partition_start"] <= diff[0] < d["partition_start"] + d["partition_size"], a[diff[0]] ^ b[diff[0]])
PY
chk "  정확히 한 바이트, 파티션 안, 한 비트(0x01)만 다르다"          "$(python3 "$VT/diffcount.py" "$NW/fw/lu0.img" "$NW/fw/lu0_negative.img" "$J")" "True 1 True True 1"
chk "  데이터가 있는 구간의 가운데 (패딩이 아님)"                    "$(echo "$J" | vgp_j '0 < d["offset_in_partition"] < 3004 and d["original_byte"] != "0x00"')" "True"
chk "  원본 불변을 스스로 보고"                                     "$(echo "$J" | vgp_j 'd["original_unchanged"]')" "True"
J=$(python3 "$S/make_negative_image.py" "$NW" --partition boot --out "$NW/fw/boot_negative.img" --offset 100)
chk "--partition · --out · --offset 을 따른다"                      "$(echo "$J" | vgp_j '(d["partition"], d["offset_in_partition"], d["offset_abs"] - d["partition_start"])')" "('boot', 100, 100)"
chk "없는 파티션은 실패 (종료 1, 후보 목록)"                         "$(python3 "$S/make_negative_image.py" "$NW" --partition nosuch >"$VT/neg.json" 2>/dev/null; echo $?; python3 -c 'import json;d=json.load(open("'"$VT"'/neg.json"));print(d["ok"], d["partitions"])')" "1
False ['boot', 'param', 'prism', 'vbmeta']"
chk "전부 0 인 파티션은 거절 (훼손할 데이터가 없다)"                   "$(python3 "$S/make_negative_image.py" "$NW" --partition param >/dev/null 2>&1; echo $?)" "1"
chk "출력이 원본과 같은 경로면 거절하고 원본을 건드리지 않는다"        "$(python3 "$S/make_negative_image.py" "$NW" --out "$NW/fw/lu0.img" >/dev/null 2>&1; echo $?; vgp_sha "$NW/fw/lu0.img" | sed "s/^$SHA0\$/same/")" "1
same"
printf '{"block_size":4096,"partitions":[{"name":"vbmeta","source":"vb.bin","lba":6}]}\n' > "$NW/lu_manifest.json"
head -c 100 /dev/urandom > "$NW/not_gpt.img"
dd if=/dev/zero bs=4096 count=8 2>/dev/null >> "$NW/not_gpt.img"; printf 'ABCDEFGHIJ' | dd of="$NW/not_gpt.img" bs=1 seek=24576 conv=notrunc 2>/dev/null
printf 'ABCDEFGHIJ' > "$NW/vb.bin"
chk "GPT 가 없으면 매니페스트의 lba 로 위치를 찾는다"                "$(python3 "$S/make_negative_image.py" "$NW" --image "$NW/not_gpt.img" | vgp_j '(d["ok"], d["located_by"], d["offset_abs"])')" "(True, 'lu_manifest.json (lba)', 24580)"

# =============================================================================
# 10. 개별 도구 · 호환 · 문법
# =============================================================================
chk "verify.py: JSON 키가 그대로 (items·gates_passed·inputs.console)" \
    "$(W=$(vgp_ws compat); vgp_v "$W" --target F2 --container "$W/03_bootloader/fw.bin" | vgp_j '(sorted(k for k in ("items","gates_passed","gates_total","reference_passed","verdict","verdict_label","inputs","note","flow") if k in d), d["flow"], [i["n"] for i in d["items"]], [bool(i.get("gate")) for i in d["items"]])')" \
    "(['flow', 'gates_passed', 'gates_total', 'inputs', 'items', 'note', 'reference_passed', 'verdict', 'verdict_label'], 'unified', [1, 2, 3, 4, 5, 6, 7], [True, True, True, False, False, False, False])"
chk "  verdict_script.json 도 쓴다"  "$(W="$VT/compat"; [ -s "$W/verdict_script.json" ] && echo yes)" "yes"
chk "게이트 모듈이 verify.py 에서 불러지는 이름 (g1test 호환): check_source_negative · check_output_origin · check_input_origin" \
    "$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('verify', '$S/verify.py'); v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
print(all(callable(getattr(v, n)) for n in ('check_source_negative','check_output_origin','check_input_origin','find_console','find_trace','check_bypass','firmware_images','stage_entries')))")" "True"
chk "판정 문구 규칙 (C8)" "$(vgp_u "(vg.verdict_label(True, 0), vg.verdict_label(True, 3), vg.verdict_label(False, 0))")" "('출처 검증 통과', 'VERIFIED (출처 검증 통과) · 검증 우회 3건 · verify_ok: reached_bypassed', '출처 검증 실패')"

# --- 옛 두 트랙 흐름의 제거 (--track · --bl3 · verify_track1/2) ----------------------------
# 파이프라인은 verifyCommand() 로 통합 흐름만 부른다. 옛 플래그가 조용히 되살아나면 REAL/FORCED
# 같은 옛 판정어가 다시 나올 수 있어, 받지 않는다는 것과 옛 이름이 모듈에 없다는 것을 못박는다.
LW=$(vgp_ws legacy)
chk "verify.py 는 옛 --track 을 받지 않는다 (argparse 종료 2)" \
    "$(python3 "$S/verify.py" "$LW" --track 1 --container "$LW/03_bootloader/fw.bin" >/dev/null 2>&1; echo $?)" "2"
chk "  옛 --bl3 도 받지 않는다" \
    "$(python3 "$S/verify.py" "$LW" --bl3 "$LW/03_bootloader/fw.bin" >/dev/null 2>&1; echo $?)" "2"
chk "  --container 가 없으면 종료 1 (옛 별칭으로 대신하지 않는다)" \
    "$(python3 "$S/verify.py" "$LW" --target F2 >/dev/null 2>&1; echo $?)" "1"
cat > "$VT/legacy_gone.py" <<'PY'
import importlib.util, inspect, os
spec = importlib.util.spec_from_file_location("verify", os.path.join(os.environ["VG_SCRIPTS"], "verify.py"))
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
gone = ("verify_track1", "verify_track2", "ROOTFS_PATTERNS", "code_literals", "derive_pcs",
        "find_machine_sources", "RX_SEED")
kept = ("K3_PROGRESS", "K3_STAGES", "any_match", "check_bypass", "k3_stage_report", "verify_full")
print([n for n in gone if hasattr(v, n)], all(hasattr(v, n) for n in kept),
      list(inspect.signature(v.find_console).parameters), list(inspect.signature(v.find_trace).parameters),
      v._round_of("/x/kboot_3.txt"), v._round_of("/x/console_3.txt"))
PY
chk "옛 흐름의 함수·상수는 모듈에 없고, 통합 흐름이 쓰는 것은 남아 있다 (find_console·find_trace 는 track 인자 없이, kboot_N 은 회차 이름이 아니다)" \
    "$(VG_SCRIPTS="$S" python3 "$VT/legacy_gone.py")" "[] True ['workdir', 'rnd'] ['workdir', 'rnd'] None 3"
chk "옛 두 번째 게이트 2 정의(verify_byte_match.py)는 저장소에 없다" \
    "$([ -e "$S/verify_byte_match.py" ] && echo present || echo absent)" "absent"
chk "derived_facts · static_rotate · analyze_run 도 옛 --track 을 받지 않는다 (각각 종료 2)" \
    "$(for sc in derived_facts static_rotate analyze_run; do python3 "$S/$sc.py" "$LW" --track 1 >/dev/null 2>&1; echo -n "$? "; done)" "2 2 2 "
chk "파이프라인·내보내기·스킬·에이전트 어디에도 --track 을 넘기지 않는다" \
    "$(grep -rl -e '--track' "$REPO/workflows" "$S/make_export.sh" "$REPO/skills" "$REPO/agents" 2>/dev/null | wc -l | tr -d ' ')" "0"
chk "make_export.sh 는 사라진 kboot_*.txt 를 복사하지 않는다" "$(grep -c 'kboot' "$S/make_export.sh" | head -1)" "0"
# 게이트 2 불통과 문구는 한 벤더의 성분 이름 대신 '같은 UART 를 쓰는 다른 펌웨어 성분' 이라 쓴다
printf 'invented words appear nowhere inside firmware images\nsecond invented fixture sentence here\n' > "$LW/07_logs/console_1.txt"
chk "게이트 2 불통과 문구: 같은 UART 를 쓰는 다른 펌웨어 성분 (벤더 이름 없음)" \
    "$(vgp_v "$LW" --target F2 --container "$LW/03_bootloader/fw.bin" | vgp_j '(d["items"][1]["pass"], "같은 UART 를 쓰는 다른 펌웨어 성분이 02_unpacked/ 에 없습니다" in d["items"][1]["evidence"], any(w in d["items"][1]["evidence"] for w in ("ldfw", "tzsw", "ACPM")))')" "(False, True, False)"
chk "verify_gates.py 에 한 벤더의 성분 이름(ldfw · tzsw · ACPM · sboot.bin)이 없다" \
    "$(grep -c -E 'ldfw|tzsw|ACPM|sboot\.bin' "$S/verify_gates.py" | head -1)" "0"

# --- 실물 (환경변수가 있을 때만) ---------------------------------------------
if [ -n "${SBOOT_MT_KIT:-}" ] && [ -n "${SBOOT_MT_RUN:-}" ] && [ -f "$SBOOT_MT_KIT/machine/machine_preloader.c" ] && [ -f "$SBOOT_MT_RUN/console.txt" ]; then
  cat > "$VT/real.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["VG_SCRIPTS"])
import verify_gates as vg
kit, run = os.environ["SBOOT_MT_KIT"], os.environ["SBOOT_MT_RUN"]
src = kit + "/machine/machine_preloader.c"
facts = vg.analyze_files([src])
raw = open(run + "/console.txt", "rb").read() + (open(run + "/kernel.log", "rb").read() if os.path.exists(run + "/kernel.log") else b"")
guest = vg.read_guest_console(run + "/console.txt", run + "/kernel.log" if os.path.exists(run + "/kernel.log") else None)
r_raw = vg.source_negative(facts, vg.ConsoleView.of(raw))
r_guest = vg.source_negative(facts, guest, vg.parse_ranges("0x48090000:0xe0000"))
g3 = vg.input_origin(facts)
print(len(r_raw["leaks"]), len(r_guest["leaks"]), len(r_guest["tx_paths"]), len(r_guest["protected_hits"]), g3["findings"], g3["callbacks"])
PY
  chk "[실물] 호스트 줄이 섞인 콘솔은 65 건 적발, 게스트 콘솔은 0 · UART 경로 1 · pstore 참조 0 · 입력 콜백만" \
      "$(VG_SCRIPTS="$S" python3 "$VT/real.py")" "65 0 1 0 [] ['uart_can_receive', 'uart_receive']"
  chk "[실물] 장부: '(기록 없음)' 부작용을 반려 대상으로 센다" \
      "$(python3 "$VGPY" ledger "$VT" --ledger "$SBOOT_MT_KIT/machine/bypasses.md" | vgp_j 'sum(1 for i in d["issues"] if i["kind"]=="side_effect_empty") > 0')" "True"
else
  printf '  (SBOOT_MT_KIT · SBOOT_MT_RUN 이 없어 실물 시험은 건너뜀)\n'
fi

# --- 문법 ---------------------------------------------------------------------
# 컴파일만 한다 (py_compile 은 저장소에 __pycache__ 를 남긴다)
python3 -c 'import sys; [compile(open(f, encoding="utf-8").read(), f, "exec") for f in sys.argv[1:]]' \
    "$S/verify.py" "$S/verify_gates.py" "$S/verify_prep.py" "$S/make_negative_image.py" 2>/dev/null
chk "구문 검사 (verify*.py, make_negative_image.py)" "$?" "0"
bash -n "$S/check_change.sh" 2>/dev/null
chk "구문 검사 (check_change.sh)" "$?" "0"

rm -rf "$VT"
parts_finish
