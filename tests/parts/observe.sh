#!/usr/bin/env bash
# tests/parts/observe.sh - 관측 채널: 메모리 덤프 · 호스트/게스트 분리 · 감시 PC · 정체 판정
#
# 단독 실행: bash tests/parts/observe.sh
#
# 가짜 QEMU(fakeqemu.py)는 두 가지를 한다. 유닉스 소켓 HMP 모니터로 `pmemsave` 를 알아듣고
# 링이 한 바퀴 도는 합성 메모리를 돌려주며, 가짜 qemu-system 으로서 UART·호스트 줄·트레이스를
# 낸다. 영역 주소·크기·문자열은 전부 이 시험이 지어낸 값이며 실제 기기 값이 아니다.
# 실제 이미지는 OBSERVE_REAL_DIR 이 가리킬 때만 쓴다 (저장소 시험은 그것에 기대지 않는다).
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
export PYTHONDONTWRITEBYTECODE=1

hdr "관측 채널 (observe)"

OB="$ROOT/observe"; mkdir -p "$OB"
FQ="$OB/fakeqemu.py"
cat > "$FQ" <<'PYEOF'
import os
import re
import signal
import socket
import sys
import threading
import time


class Ring:
    """A console ring inside a larger region (offset zone_off, zone bytes), wrapping like pstore."""

    def __init__(self, size, zone, zone_off=0x40, pad=0):
        self.size, self.zone, self.zone_off, self.pad = size, zone, zone_off, pad
        self.buf = bytearray(zone)
        self.pos = 0
        self.t = 0.0
        self.n = 0
        self.lock = threading.Lock()

    def emit(self, text, dt=0.1):
        if self.pad:                    # fixed-size lines: none ever straddles the wrap
            text = text.ljust(self.pad - 16)
        with self.lock:
            for b in b"[%12.6f] %s\n" % (self.t, text.encode()):
                self.buf[self.pos] = b
                self.pos = (self.pos + 1) % self.zone
            self.t += dt
            self.n += 1

    def emit_many(self, count, task="[1:swapper/0]", dt=0.1):
        for _ in range(count):
            self.emit("<0>.(0)%smsg %d" % (task, self.n), dt)

    def image(self):
        with self.lock:
            mem = bytearray(self.size)
            mem[self.zone_off:self.zone_off + self.zone] = self.buf
            return bytes(mem)


class Monitor(threading.Thread):
    """HMP over a unix socket: banner + prompt, `pmemsave ADDR SIZE "FILE"`."""
    PROMPT = b"(qemu) "

    def __init__(self, path, base, ring, on_dump=None):
        super().__init__(daemon=True)
        self.path, self.base, self.ring, self.on_dump = path, base, ring, on_dump
        self.dumps = 0
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if os.path.exists(path):
            os.unlink(path)
        self.srv.bind(path)
        self.srv.listen(4)

    def run(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        conn.sendall(b"QEMU monitor - type 'help' for more information\r\n" + self.PROMPT)
        buf = b""
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    return
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    conn.sendall(line + b"\r\n" + self.handle(line.decode().strip()) + self.PROMPT)
        except OSError:
            return
        finally:
            conn.close()

    def handle(self, cmd):
        m = re.match(r'pmemsave\s+(\S+)\s+(\d+)\s+"(.*)"$', cmd)
        if not m:
            return b"unknown command: '%s'\r\n" % cmd.encode()
        addr, size, path = int(m.group(1), 0), int(m.group(2)), m.group(3)
        if addr != self.base or size != self.ring.size:
            return b"Invalid parameter 'addr'\r\n"
        if self.on_dump:
            self.on_dump(self)
        with open(path, "wb") as fh:
            fh.write(self.ring.image())
        self.dumps += 1
        return b""


def main(argv):
    mon_path = fifo = None
    i = 0
    while i < len(argv):
        if argv[i] == "-monitor" and argv[i + 1].startswith("unix:"):
            mon_path = argv[i + 1][5:].split(",")[0]
            i += 1
        elif argv[i] == "-D":
            fifo = argv[i + 1]
            i += 1
        i += 1
    env = os.environ.get
    with open(env("FAKE_ARGS_OUT", os.devnull), "w") as fh:
        fh.write(" ".join(argv) + "\n")
    # what the QEMU process was given in its environment (the machine reads these)
    with open(env("FAKE_ENV_OUT", os.devnull), "w") as fh:
        fh.write("REHOST_MEMDUMP_REGION=%s\n" % os.environ.get("REHOST_MEMDUMP_REGION", "<unset>"))

    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    ring = Ring(int(env("FAKE_SIZE", "16384"), 0), int(env("FAKE_ZONE", "4096"), 0),
                pad=int(env("FAKE_PAD", "0")))
    base = int(env("FAKE_BASE", "0x50100000"), 0)
    adv = int(env("FAKE_ADV", "10"))
    task = env("FAKE_TASK", "[1:swapper/0]")

    bare = int(env("FAKE_BARE", "0"))
    bare_text = env("FAKE_BARE_TEXT", "boot stage")

    def on_dump(mon):
        if mon.dumps == 0:
            # the bootloader's own lines in a shared ring: a timestamp, and no task at all
            for i in range(bare):
                ring.emit("%s %d ready" % (bare_text, i), 0.1)
        if mon.dumps == 0 and env("FAKE_BANNER", "1") == "1":
            ring.emit("<0>-(0)[0:swapper]Linux version 9.9.9-test", 0.1)
        ring.emit_many(adv, task=task)

    if mon_path:
        Monitor(mon_path, base, ring, on_dump).start()

    out, err = sys.stdout, sys.stderr
    out.write("[BLDR] boot start\n")
    out.flush()
    time.sleep(float(env("FAKE_JUMP_AFTER", "0.3")))
    out.write("[LK]jump to K64 0x40080000\n")
    out.flush()
    t_jump = time.time()
    for extra in (env("FAKE_STDOUT_EXTRA") or "").split("|"):
        if extra:
            out.write(extra + "\n")
            out.flush()
    if env("FAKE_NO_HOST") != "1":
        err.write("qemu-system-aarch64: info: fake-machine: image attached\n")
        err.flush()
    reset_after = env("FAKE_RESET_AFTER")
    reset_done = reset_after is None

    storm = int(env("FAKE_EXC", "0"))
    trace_lines = [x for x in (env("FAKE_TRACE") or "").split("|") if x]
    tf = open(fifo, "w") if (fifo and (storm or trace_lines)) else None
    if tf:
        for x in trace_lines:
            tf.write(x + "\n")
        tf.flush()
        if not storm:
            tf.close()
            tf = None

    t_end = time.time() + float(env("FAKE_RUN", "30"))
    while time.time() < t_end:
        if not reset_done and time.time() - t_jump >= float(reset_after):
            err.write("qemu-system-aarch64: info: fake-machine: %s\n" %
                      env("FAKE_RESET_LINE", "UNMODELLED read 0xfeed0010"))
            err.flush()
            reset_done = True
        if tf:
            try:
                for _ in range(2000):
                    tf.write("Taking exception 4 [Data Abort]\nFAR 0x1000\n")
                tf.flush()
                storm -= 1
                if storm <= 0:
                    tf.close()
                    tf = None
            except (BrokenPipeError, ValueError, OSError):
                tf = None
        else:
            time.sleep(0.05)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PYEOF

mkdir -p "$OB/bin"
printf '#!/usr/bin/env bash\nexec python3 "%s" "$@"\n' "$FQ" > "$OB/bin/fake-qemu"
chmod +x "$OB/bin/fake-qemu"
MO="$S/memdump_observe.py"
ob_jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print($2)" "$1" 2>/dev/null; }

# ── 1. 샘플링 간격: 링 용량 ÷ 최근 채움 속도로 정한다 ─────────────────────────
OB_R=$(PYTHONPATH="$S" python3 - <<'PY'
import memdump_observe as m
cap = 262144
p = m.IntervalPlanner(cap, floor=3, ceiling=12, initial=5)
a = p.update(0, 5)                                       # 아직 데이터 없음 -> 초기값
p2 = m.IntervalPlanner(cap, 3, 12, 5); p2.update(1000, 5); b = p2.update(10, 100)
p3 = m.IntervalPlanner(cap, 3, 12, 5); c = p3.update(500000, 5)    # 빠름 -> 하한
p4 = m.IntervalPlanner(cap, 3, 12, 5); d = p4.update(100000, 5)    # 20000 B/s -> 0.5*cap/rate
p5 = m.IntervalPlanner(cap, 3, 12, 5); p5.update(500000, 5); e = p5.update(0, 5)   # 폭주를 평균내지 않는다
p6 = m.IntervalPlanner(cap, 1, 12, 5); f = p6.update(100, 4, overrun=True)         # 덮임 -> 링이 가득 찼던 것으로
print(a, b, c, round(d, 2), e, f)
PY
)
chk "간격: 데이터 전엔 초기값, 조용하면 상한, 빠르면 하한, 중간은 용량÷속도의 절반, 폭주는 평균내지 않고, 덮임은 가득 찬 것으로" \
    "$OB_R" "5.0 12.0 3.0 6.55 3.0 2.0"

# ── 2. 병합: 합집합 · 정렬 · 삭제만 · 바이너리로 읽기 ───────────────────────
OB_R=$(PYTHONPATH="$S" python3 - <<'PY'
import memdump_observe as m
A = (b"\0\0[   1.000000] <0>.(0)[1:init]alpha\n[   2.000000] <0>.(0)[1:init]beta\n"
     b"[   3.000000] <0>.(0)[1:init]gam")                      # 덤프 끝에서 잘린 줄
B = (b"[   2.000000] <0>.(0)[1:init]beta\n[   3.000000] <0>.(0)[1:init]gamma\n"
     b"[   4.000000] dump: [0x10] = 0x1\n\r[   5.000000] after-cr\n"
     b"[   6.000000] ab\n[   6.000000] abc\n")
merged = m.merge_parsed([m.parse_snapshot(A), m.parse_snapshot(B)])
print("|".join("%g %s" % (t, x.split("]", 1)[-1]) for t, x in merged))
gaps = m.find_gaps([(0, ""), (1, ""), (2.6, ""), (4.0, ""), (10.0, "")])
print(len(gaps), round(sum(g[2] for g in gaps), 2))
rep = m.gap_report([(0.0, ""), (1.0, ""), (2.6, ""), (4.0, ""), (10.0, "")])
print(rep["count"], rep["total_s"], rep["span_s"])
PY
)
chk "병합: 잘린 줄은 온전한 사본이 있으면 지우고, 완결된 짧은 줄은 둘 다 두고, 헥스 덤프 줄만 지우고, \\r 로 시작하는 줄을 잃지 않는다" \
    "$(echo "$OB_R" | sed -n 1p)" "1 alpha|2 beta|3 gamma|5 after-cr|6 ab|6 abc"
chk "유실 의심: 1.5 s 넘는 간격(1.6 s, 6.0 s)만 센다" "$(echo "$OB_R" | sed -n 2p)" "2 7.6"
chk "유실 보고에 합계와 전체 길이" "$(echo "$OB_R" | sed -n 3p)" "2 7.6 10.0"

# ── 3. 모니터 소켓으로 덤프: 링이 도는 합성 메모리 ───────────────────────────
OB_PLAN="$OB/plan.json"
cat > "$OB_PLAN" <<'EOF'
{"channel":"memdump","region_base":"0x50100000","region_size":16384,"console_size":2048,"source":"cmdline","evidence":"synthetic"}
EOF
ob_serve() {   # $1 소켓  $2 덤프마다 쌓이는 줄 수  $3 서버 수명(초)
    rm -f "$1"
    FAKE_BASE=0x50100000 FAKE_SIZE=16384 FAKE_ZONE=2048 FAKE_PAD=64 FAKE_ADV="$2" FAKE_RUN="$3" \
        python3 "$FQ" -monitor "unix:$1,server,nowait" >/dev/null 2>&1 &
    OB_SRV=$!
    local i=0; while [ ! -S "$1" ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i+1)); done
}
# 링은 64 바이트 줄 32 개. 덤프 사이에 12 줄이 쌓이면 겹치므로 하나도 잃지 않는다.
ob_serve "$OB/m1.sock" 12 8
python3 "$MO" watch --plan "$OB_PLAN" --socket "$OB/m1.sock" --snap-dir "$OB/s1" \
    --out "$OB/k1.log" --stats "$OB/k1.json" --deadline 1.0 --final-margin 0.2 \
    --floor 0.05 --ceiling 0.15 --initial 0.1 >/dev/null 2>&1
kill "$OB_SRV" 2>/dev/null; wait "$OB_SRV" 2>/dev/null
OB_N=$(ob_jget "$OB/k1.json" "d['snapshots']")
chk "덤프가 여러 번 찍힘" "$([ "${OB_N:-0}" -ge 3 ] && echo yes || echo no)" "yes"
chk "링이 돌아도 합집합에 줄을 잃지 않음 (덤프당 12줄 + 배너 1줄)" \
    "$(ob_jget "$OB/k1.json" "d['lines']")" "$((1 + 12 * ${OB_N:-0}))"
chk "겹치는 덤프에서는 유실 의심 0 구간" "$(ob_jget "$OB/k1.json" "d['gaps']['count']")" "0"
chk "원본 스냅샷을 보존" "$(ls "$OB/s1"/ps_*.bin 2>/dev/null | wc -l | tr -d ' ')" "$OB_N"
chk "병합 로그가 '<커널 초> <텍스트>' 한 줄씩이고 시각순" \
    "$(python3 - "$OB/k1.log" <<'PY'
import sys
ts = []
for l in open(sys.argv[1], encoding="latin1"):
    head, _, text = l.rstrip("\n").partition(" ")
    ts.append(float(head))
print("sorted" if ts == sorted(ts) and ts else "bad")
PY
)" "sorted"
chk "영역·출처는 계획에서만 와서 통계에 그대로 실림" \
    "$(ob_jget "$OB/k1.json" "d['region']['base'], d['region']['size'], d['region']['source']")" "0x50100000 16384 cmdline"

# 덤프 사이에 50줄 (링 32줄) 이 쌓이면 덮여 사라진다 - 침묵하지 않고 유실로 보고해야 한다
ob_serve "$OB/m2.sock" 50 8
python3 "$MO" watch --plan "$OB_PLAN" --socket "$OB/m2.sock" --snap-dir "$OB/s2" \
    --out "$OB/k2.log" --stats "$OB/k2.json" --deadline 0.8 --final-margin 0.2 \
    --floor 0.05 --ceiling 0.15 --initial 0.1 >/dev/null 2>&1
kill "$OB_SRV" 2>/dev/null; wait "$OB_SRV" 2>/dev/null
chk "덮여 사라진 구간을 유실 의심으로 셈 (1.5 s 초과)" \
    "$(ob_jget "$OB/k2.json" "'yes' if d['gaps']['count']>=1 and d['gaps']['total_s']>=1.5 else 'no'")" "yes"
chk "덮임(overrun) 을 따로 셈" "$(ob_jget "$OB/k2.json" "'yes' if d['overruns']>=1 else 'no'")" "yes"
chk "빠른 채움에는 간격이 하한까지 줄어듦" "$(ob_jget "$OB/k2.json" "d['interval']['min_used']")" "0.05"

# 시작 신호: 콘솔에 점프 안내가 나오기 전에는 덤프하지 않는다
ob_serve "$OB/m3.sock" 12 8
: > "$OB/con3.txt"
python3 "$MO" watch --plan "$OB_PLAN" --socket "$OB/m3.sock" --snap-dir "$OB/s3" \
    --out "$OB/k3.log" --stats "$OB/k3.json" --deadline 1.8 --final-margin 0.2 \
    --floor 0.05 --ceiling 0.15 --initial 0.1 \
    --console "$OB/con3.txt" --start-token "jump to K64" >/dev/null 2>&1 &
OB_W=$!
sleep 0.6
OB_T0=$(python3 -c "import time;print('%.6f'%time.time())")
printf 'boot\n[LK]jump to K64 0x1\n' >> "$OB/con3.txt"
wait "$OB_W"
kill "$OB_SRV" 2>/dev/null; wait "$OB_SRV" 2>/dev/null
chk "시작 신호 이후에 덤프를 시작" \
    "$(python3 - "$OB/s3/ps_1.time" "$OB_T0" <<'PY'
import sys
print("after" if float(open(sys.argv[1]).read()) >= float(sys.argv[2]) else "before")
PY
)" "after"
chk "통계에 시작 계기가 kernel_entry 로 남음" "$(ob_jget "$OB/k3.json" "d['started']")" "kernel_entry"

# 모니터가 없으면(QEMU 가 못 뜸) 빈 로그와 이유를 남기고 끝난다
python3 "$MO" watch --plan "$OB_PLAN" --socket "$OB/none.sock" --snap-dir "$OB/s4" \
    --out "$OB/k4.log" --stats "$OB/k4.json" --deadline 1 --socket-wait 0.3 >/dev/null 2>&1
chk "모니터가 없으면 이유를 기록" "$(ob_jget "$OB/k4.json" "d['ended']")" "no_monitor"
chk "관측 못 한 채널은 빈 로그 (파일 부재와 구별)" "$(wc -l < "$OB/k4.log" | tr -d ' ')" "0"

# 실행이 끝나 SIGTERM 을 받으면 가진 스냅샷을 병합하고 끝난다
ob_serve "$OB/m5.sock" 12 8
python3 "$MO" watch --plan "$OB_PLAN" --socket "$OB/m5.sock" --snap-dir "$OB/s5" \
    --out "$OB/k5.log" --stats "$OB/k5.json" --floor 0.05 --ceiling 0.15 --initial 0.1 >/dev/null 2>&1 &
OB_W=$!
sleep 0.8; kill -TERM "$OB_W" 2>/dev/null; wait "$OB_W" 2>/dev/null
kill "$OB_SRV" 2>/dev/null; wait "$OB_SRV" 2>/dev/null
chk "SIGTERM 으로 끝나도 병합 로그가 남음" "$(ob_jget "$OB/k5.json" "'yes' if d['lines']>0 and d['ended']=='signal' else 'no'")" "yes"

# 영역 계획이 없거나 깨졌으면 채널을 켜지 않는다
printf '{"channel":"memdump","region_base":"zz","region_size":10}\n' > "$OB/bad_plan.json"
printf '{"channel":"uart","region_base":"0x1000","region_size":4096}\n' > "$OB/wrong_ch.json"
printf '{"channel":"memdump","region_base":"0x1000","region_size":4096}\n' > "$OB/no_console.json"
python3 "$MO" check-plan "$OB_PLAN" 2>/dev/null; chk "정상 계획은 통과" "$?" "0"
python3 "$MO" check-plan "$OB/nope.json" 2>/dev/null; chk "계획이 없으면 채널 꺼짐" "$?" "1"
python3 "$MO" check-plan "$OB/bad_plan.json" 2>/dev/null; chk "숫자가 아닌 영역은 거부" "$?" "1"
python3 "$MO" check-plan "$OB/wrong_ch.json" 2>/dev/null; chk "채널이 memdump 가 아니면 거부" "$?" "1"
python3 "$MO" check-plan "$OB/no_console.json" 2>/dev/null; chk "console_size 가 없어도 쓸 수 있다 (용량을 영역 전체로 가정)" "$?" "0"

# ── 4. 영역 도출: 부트로더 로그 / 커널 커맨드라인 ───────────────────────────
cat > "$OB/bl.log" <<'EOF'
1791000000.100000 [0100] boot stage start
1791000000.200000 [0200] reserve-R[3].start: 0x50100000, size: 0x40000 map:0 name:pstore
1791000000.300000 RAM_CONSOLE pstore_addr:0x50100000, pstore_size:0x40000, pstore_console_size:0x20000, pstore_pmsg_size:0x8000
1791000000.400000 [0300] reserve-R[4].start: 0x60000000, size: 0x100000 map:0 name:other
EOF
python3 "$MO" derive --bootloader-log "$OB/bl.log" > "$OB/derived_lk.json" 2>/dev/null
chk "부트로더 로그에서 영역 도출 (시작·크기·console_size)" \
    "$(ob_jget "$OB/derived_lk.json" "d['region_base'], d['region_size'], d['console_size'], d['source']")" \
    "0x50100000 262144 131072 lk_log"
chk "도출 근거로 원문 줄을 돌려줌" \
    "$(ob_jget "$OB/derived_lk.json" "'yes' if 'name:pstore' in d['evidence'] and 'pstore_console_size' in d['evidence'] else 'no'")" "yes"
chk "채널 이름은 C4 대로 memdump" "$(ob_jget "$OB/derived_lk.json" "d['channel']")" "memdump"

python3 "$MO" derive --cmdline 'console=ttyS0 ramoops.mem_address=0x50100000 ramoops.mem_size=0x40000 ramoops.console_size=0x20000 quiet' \
    > "$OB/derived_cl.json" 2>/dev/null
chk "커맨드라인 토큰에서 영역 도출" \
    "$(ob_jget "$OB/derived_cl.json" "d['region_base'], d['region_size'], d['console_size'], d['source']")" \
    "0x50100000 262144 131072 cmdline"
python3 "$MO" derive --cmdline 'ramoops.mem_address=0x50100000 ramoops.mem_size=256K ramoops.console_size=128K' \
    > "$OB/derived_k.json" 2>/dev/null
chk "K/M 접미사를 해석" "$(ob_jget "$OB/derived_k.json" "d['region_size'], d['console_size']")" "262144 131072"

python3 "$MO" derive --bootloader-log "$OB/bl.log" \
    --cmdline 'ramoops.mem_address=0x50100000 ramoops.mem_size=0x40000 ramoops.console_size=0x20000' \
    --out "$OB/plan_out.json" >/dev/null 2>&1
chk "두 출처가 일치하면 합치고 계획 파일을 씀" \
    "$(ob_jget "$OB/plan_out.json" "d['source'], d['region_base']")" "cmdline 0x50100000"
python3 "$MO" check-plan "$OB/plan_out.json" 2>/dev/null
chk "도출한 계획은 그대로 watch 가 읽는다" "$?" "0"

python3 "$MO" derive --bootloader-log "$OB/bl.log" \
    --cmdline 'ramoops.mem_address=0x70000000 ramoops.mem_size=0x40000' >/dev/null 2>&1
chk "출처끼리 영역이 다르면 추측하지 않고 실패" "$?" "1"
printf 'nothing about rings here\n' > "$OB/bl_none.log"
python3 "$MO" derive --bootloader-log "$OB/bl_none.log" >/dev/null 2>&1
chk "영역을 말하는 줄이 없으면 실패" "$?" "1"
python3 "$MO" derive --cmdline 'ramoops.mem_address=0x50100000' >/dev/null 2>&1
chk "크기 없이 시작만 있으면 실패 (한쪽만으로 짐작하지 않음)" "$?" "1"

# ── 5. 토큰 채널 (C2) 과 kernel_alive 의 엄격한 판정 ─────────────────────────
printf 'kernel_alive\tLinux version\tmemdump\nshell\tprompt$\nrootfs\tfoo\tuart\npartitions_up\tmmcblk\\d+: p\\d+\tmemdump\n' > "$OB/tok.txt"
chk "세 번째 열이 없으면 uart" \
    "$(PYTHONPATH="$S" python3 -c "
import memdump_observe as m
print(','.join(c for _,_,c in m.read_tokens('$OB/tok.txt')))")" "memdump,uart,uart,memdump"

cat > "$OB/k_ok.log" <<'EOF'
0.000000 <0>-(0)[0:swapper]Linux version 9.9.9-test (x@y)
0.100000 <0>.(0)[1:swapper/0]some line
5.000000 <0>.(0)[4:kworker/0:0] mmcblk0: p1 p2 p3
EOF
python3 "$MO" scan --tokens "$OB/tok.txt" --log "$OB/k_ok.log" > "$OB/scan_ok.json"
chk "memdump 토큰만 평가 (uart 토큰은 건드리지 않음)" "$(ob_jget "$OB/scan_ok.json" "' '.join(d['reached'])")" "kernel_alive partitions_up"
chk "kernel_alive 증거에 커널 시각·태스크·배너" \
    "$(ob_jget "$OB/scan_ok.json" "d['alive_evidence']['kernel_time'], d['alive_evidence']['task'], d['alive_evidence']['banner'], d['alive_evidence']['via']")" \
    "0.0 swapper True banner"
chk "정규식 토큰(백슬래시)은 정규식으로" "$(ob_jget "$OB/scan_ok.json" "d['hits']['partitions_up']['matched']")" "mmcblk0: p1"

# 문자열이 있어도 태스크 접두가 없으면 실행 중인 커널이 아니다
cat > "$OB/k_notask.log" <<'EOF'
0.000000 Linux version 9.9.9-test pasted by someone
1.000000 another line without a task
EOF
python3 "$MO" scan --tokens "$OB/tok.txt" --log "$OB/k_notask.log" > "$OB/scan_nt.json"
chk "태스크 접두 없는 줄은 kernel_alive 로 세지 않음" "$(ob_jget "$OB/scan_nt.json" "'kernel_alive' in d['reached']")" "False"
# 한 줄뿐이면 연속성이 없다
printf '0.000000 <0>-(0)[0:swapper]Linux version 9.9.9-test\n' > "$OB/k_one.log"
python3 "$MO" scan --tokens "$OB/tok.txt" --log "$OB/k_one.log" > "$OB/scan_one.json"
chk "태스크 줄이 하나뿐이면 거부하고 이유를 남김" \
    "$(ob_jget "$OB/scan_one.json" "('kernel_alive' in d['reached'], len(d['hits'].get('kernel_alive_rejected', [])))")" "(False, 1)"

# 대체 토큰: 배너가 링에서 덮였을 때. 기록에 '배너 미관측' 이 남아야 한다
printf 'kernel_alive\tFreeing unused kernel memory\tmemdump\n' > "$OB/tok_alt.txt"
cat > "$OB/k_alt.log" <<'EOF'
96.000000 <0>.(0)[1:swapper/0]Freeing unused kernel memory: 5632K
97.000000 <0>.(0)[1:init]init: first stage
EOF
python3 "$MO" scan --tokens "$OB/tok_alt.txt" --log "$OB/k_alt.log" > "$OB/scan_alt.json"
chk "대체 토큰으로 판정하면 배너 미관측을 기록" \
    "$(ob_jget "$OB/scan_alt.json" "(d['alive_evidence']['via'], d['alive_evidence']['banner'], '배너' in d['alive_evidence']['note'])")" \
    "('alternate', False, True)"

# 출처 게이트: 머신 소스에 같은 문자열이 있으면 우리가 쓴 것이다
mkdir -p "$OB/src"; printf 'static const char *s = "Linux version";\n' > "$OB/src/m.c"
python3 "$MO" scan --tokens "$OB/tok.txt" --log "$OB/k_ok.log" --src-dir "$OB/src" > "$OB/scan_inj.json"
chk "머신 소스에 있는 토큰은 자가주입으로 판정" "$(ob_jget "$OB/scan_inj.json" "d['injected'], d['injected_token']")" "True Linux version"

# ── 6. 호스트/게스트 분리 (C1) ──────────────────────────────────────────────
printf 'guest one\r\n1791000000.5 qemu-system-aarch64: info: x\nqemu-system-aarch64: warning: y\nguest two\n' > "$OB/con_h.txt"
python3 "$MO" split-host --console "$OB/con_h.txt" --host "$OB/host_h.txt" >/dev/null
chk "콘솔에는 게스트 줄만 남고 바이트가 그대로" "$(od -An -c "$OB/con_h.txt" | tr -s ' \n' ' ')" \
    "$(printf 'guest one\r\nguest two\n' | od -An -c | tr -s ' \n' ' ')"
chk "호스트 줄(시각 있는 것과 없는 것)은 host 파일로" "$(wc -l < "$OB/host_h.txt" | tr -d ' ')" "2"
printf 'only guest\n' > "$OB/con_g.txt"; cp "$OB/con_g.txt" "$OB/con_g.before"
python3 "$MO" split-host --console "$OB/con_g.txt" --host "$OB/host_g.txt" >/dev/null
chk "호스트 줄이 없으면 콘솔 파일을 건드리지 않음" "$(cmp -s "$OB/con_g.txt" "$OB/con_g.before" && echo same)" "same"
chk "호스트 줄이 없으면 host 파일을 만들지 않음" "$([ -e "$OB/host_g.txt" ] && echo made || echo none)" "none"

# ── 7. 게스트 리셋 신호: 점프 후 N 초 안의 호스트 줄 ─────────────────────────
OB_R=$(PYTHONPATH="$S" python3 - <<'PY'
import memdump_observe as m
host = [(100.0, "qemu-system-aarch64: info: m: warm start"),
        (101.4, "qemu-system-aarch64: info: m: UNMODELLED read 0xfeed0010"),
        (None, "qemu-system-aarch64: info: m: UNMODELLED read 0xfeed0010")]
pats = ["UNMODELLED read 0xfeed0010"]
r = lambda **kw: m.guest_reset(**kw)
a = r(host_lines=host, kernel_entry_epoch=100.5, patterns=pats, window_s=5)     # 0.9 s 뒤
b = r(host_lines=host, kernel_entry_epoch=90.0, patterns=pats, window_s=5)      # 11.4 s 뒤: 창 밖
c = r(host_lines=host, kernel_entry_epoch=102.0, patterns=pats, window_s=5)     # 줄이 점프보다 앞
d = r(host_lines=[host[2]], kernel_entry_epoch=100.5, patterns=pats, window_s=5) # 시각 없는 줄
e = r(host_lines=host, kernel_entry_epoch=None, patterns=pats, window_s=5)      # 점프 미관측
f = r(host_lines=host, kernel_entry_epoch=100.5, patterns=[], window_s=5)       # 패턴 없음
g = r(host_lines=host, kernel_entry_epoch=100.5, patterns=["UNMODELLED read 0x[0-9a-f]+"], window_s=5)
print(a["signal"], b["signal"], c["signal"], d["signal"], e["signal"], f["signal"], g["signal"], a["delta_s"])
PY
)
chk "창 안이면 참 · 창 밖/점프 이전/시각 없음/점프 미관측/패턴 없음이면 거짓 · 정규식도 허용" \
    "$OB_R" "True False False False False False True 0.9"
OB_R=$(REHOST_RESET_PATTERNS='[ "a b", "c" ]' PYTHONPATH="$S" python3 -c "
import memdump_observe as m
print(m.reset_patterns(None))")
chk "패턴은 환경변수(JSON 목록)에서" "$OB_R" "['a b', 'c']"
OB_R=$(REHOST_RESET_PATTERNS=$'x y\nz' PYTHONPATH="$S" python3 -c "
import memdump_observe as m
print(m.reset_patterns(None))")
chk "패턴은 환경변수(줄 구분)에서" "$OB_R" "['x y', 'z']"
printf '{"channel":"memdump","region_base":"0x1000","region_size":4096,"reset_patterns":["from-plan"],"reset_window_s":2.5}\n' > "$OB/plan_rp.json"
OB_R=$(REHOST_RESET_WINDOW_S= PYTHONPATH="$S" python3 -c "
import memdump_observe as m
print(m.reset_patterns('$OB/plan_rp.json', env={}), m.reset_window('$OB/plan_rp.json', env={}),
      m.reset_window('$OB/plan_rp.json', env={'REHOST_RESET_WINDOW_S': '7'}), m.reset_window(None, env={}))")
chk "패턴·창은 계획에서, 환경변수가 창을 덮어쓰고, 내장 목록은 없다" "$OB_R" "['from-plan'] 2.5 7.0 10.0"
chk "패턴이 없으면 비어 있다 (내장 장치값 없음)" "$(PYTHONPATH="$S" python3 -c "
import memdump_observe as m
print(m.reset_patterns(None, env={}))")" "[]"

# ── 8. 감시 PC: stage_map 의 진입 PC ────────────────────────────────────────
cat > "$OB/sm_v2.json" <<'EOF'
{"stages":[
 {"index":0,"name":"s0","state":"exec","arch":"aarch32","origin":"container","entry_pc":"0x60000000","base":{"load_base":1610612736},"file_range":[0,4096],"entry_pc_file_offset":0},
 {"index":1,"name":"s1","state":"exec","arch":"aarch64","origin":"medium","entry_pc":"0x60400000"},
 {"index":2,"name":"s2","state":"encrypted","entry_pc":"0x60800000"},
 {"index":3,"name":"s3","state":"exec","entry_pc":null}]}
EOF
cat > "$OB/sm_v1.json" <<'EOF'
{"stages":[
 {"index":0,"name":"bl1","state":"exec","file_range":[4096,8192],"entry_pc_file_offset":4352,"base":{"load_base":3221225472,"confidence":"x"}},
 {"index":1,"name":"bl2","state":"exec","file_range":[8192,16384],"entry_pc_file_offset":null,"base":{"load_base":3221233664}},
 {"index":2,"name":"enc","state":"encrypted","file_range":[0,4096],"entry_pc_file_offset":0}]}
EOF
OB_R=$(PYTHONPATH="$S" python3 - "$OB" <<'PY'
import json, sys
import trace_filter as t
ob = sys.argv[1]
v2 = t.stage_watch(ob + "/sm_v2.json")
v1 = t.stage_watch(ob + "/sm_v1.json")
print(",".join(x["pc"] for x in v2), "|", ",".join(x["from"] for x in v2))
print(",".join(x["pc"] for x in v1), "|", ",".join(x["from"] for x in v1))
print(t.stage_watch(ob + "/missing.json"), t.stage_watch(ob + "/plan.json"))
PY
)
chk "v2: entry_pc 를 쓰고(AArch64 포함) 실행 불가·진입 없음은 뺀다" "$(echo "$OB_R" | sed -n 1p)" "0x60000000,0x60400000 | entry_pc,entry_pc"
chk "v1: dict base 에서 load_base + (진입 오프셋 - 범위 시작)" "$(echo "$OB_R" | sed -n 2p)" "0xc0000100 | base+entry_offset"
chk "지도가 없거나 스테이지가 없으면 빈 목록 (실패하지 않음)" "$(echo "$OB_R" | sed -n 3p)" "[] []"
if OB_V=$(PYTHONPATH="$S" python3 - "$OB" <<'PY' 2>/dev/null
import os, shutil, sys, tempfile
import verify
ob = sys.argv[1]
d = tempfile.mkdtemp()
shutil.copy(ob + "/sm_v1.json", d + "/stage_map.json")
print(",".join(hex(s["pc"]) for s in verify.stage_entries(d)))
shutil.rmtree(d)
PY
); then
    chk "감시값이 verify.py 항목 4 가 찾는 진입 PC 와 같다 (v1)" "$OB_V" "0xc0000100"
fi

# 필터: 0 패딩 표기·더 긴 숫자·블록 안 발견·조기 종료
{
    echo "Taking exception 4 [Data Abort]"
    echo "...ESR 0x25/0x96000046 FAR 0x12860010 ELR 0x00000000c0000100"
    echo "0x00000000c0000100:  nop"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do echo "0x9100000$i:  nop"; done
    echo "0x1c0000100:  nop"
    echo "0x0000000060400000:  nop"
    echo "0xc0000100:  nop"
} > "$OB/trace_a.log"
python3 "$S/trace_filter.py" --out "$OB/trace_a.out" --stats "$OB/trace_a.json" \
    --stage-map "$OB/sm_v1.json" --watch 0x60400000 < "$OB/trace_a.log"
# 첫 등장은 예외 줄의 ELR(2번째 줄), 0x1c0000100(18번째 줄)은 같은 숫자로 시작하는 더 긴 주소다
chk "제로 패딩으로 찍힌 PC 도 잡고, 더 긴 숫자(0x1c0000100)는 잡지 않고, 처음 한 번만" \
    "$(ob_jget "$OB/trace_a.json" "','.join('%s@%d' % (e['pc'], e['line']) for e in d['stage_entries_seen'])")" \
    "0xc0000100@2,0x60400000@19"
chk "--watch 와 --stage-map 의 합집합 (중복 없음)" "$(ob_jget "$OB/trace_a.json" "d['watch']")" "['0x60400000', '0xc0000100']"
chk "예외 블록 안 발견은 블록 뒤에 표지 (블록을 쪼개지 않음)" \
    "$(awk '/Taking exception/{b=1} b&&n<12{n++; if (/stage-entry/) bad=1} END{print bad?"split":"intact"}' "$OB/trace_a.out")" "intact"
chk "표지는 verify.py 가 찾는 0x… 표기로 남는다" "$(grep -c '^\[stage-entry 0xc0000100 ' "$OB/trace_a.out")" "1"
( . "$S/fingerprint_lib.sh"; fp_origin "$OB/trace_a.out" "$OB/origin_a.txt"; echo "$FP_ORIGIN_TYPE|$FP_ORIGIN_FAR|$FP_ORIGIN_ELR" ) > "$OB/orig_a.txt"
chk "최초 예외 추출은 표지에 영향받지 않음" "$(cat "$OB/orig_a.txt")" "Data Abort|0x12860010|0x00000000c0000100"

{ for i in $(seq 1 30); do echo "Taking exception 4 [Data Abort]"; echo "FAR 0x1000"; done; } > "$OB/trace_b.log"
python3 "$S/trace_filter.py" --out "$OB/trace_b.out" --stats "$OB/trace_b.json" < "$OB/trace_b.log"
chk "예외 한도를 안 주면 조기 종료 없음 (기본 동작)" "$(ob_jget "$OB/trace_b.json" "d['early_exit']")" "None"
rm -f "$OB/stop.flag"
python3 "$S/trace_filter.py" --out "$OB/trace_c.out" --stats "$OB/trace_c.json" \
    --max-exceptions 10 --stop-file "$OB/stop.flag" < "$OB/trace_b.log"
chk "한도를 넘으면 정지 파일을 만들고 사유를 기록" \
    "$([ -e "$OB/stop.flag" ] && echo flag || echo none) $(ob_jget "$OB/trace_c.json" "d['early_exit']['limit']")" "flag 10"
chk "조기 종료 신호 뒤에도 끝까지 읽어 예외를 센다" "$(ob_jget "$OB/trace_c.json" "d['exceptions']")" "30"

# 8b. 말이 없는 스테이지의 칸 (stage_rungs.json): 이름은 스테이지를 가리지 못한다
# 이미지 둘을 `stage_map.py --merge` 로 합치면 이미지마다 `stage0`·`stage1` 이 다시 생긴다.
# 칸 → 스테이지를 이름으로만 찾으면 마지막 동명 스테이지가 이겨, 돌지 않은 스테이지의 칸이
# 다른 스테이지의 실행으로 인정된다. 주소는 전부 이 시험이 지어낸 값이다.
ob_rg_ws() {   # $1 이름 $2 지도 JSON $3 칸 JSON -> 작업 폴더
    local wd="$OB/$1"; mkdir -p "$wd/06_machine" "$wd/07_logs" "$wd/fw"
    printf '### 우회1\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$wd/06_machine/bypasses.md"
    printf 'container' > "$wd/bl.bin"; : > "$wd/milestone_tokens.txt"
    printf '%s' "$2" > "$wd/stage_map.json"; printf '%s' "$3" > "$wd/stage_rungs.json"
    echo "$wd"
}
ob_rg_run() {   # $1 작업폴더 $2 실행된 PC (공백 구분) $3 사다리 -> milestones_reached
    local wd="$1" pc
    mkdir -p "$OB/bin_rg"; : > "$OB/rg_trace.txt"
    for pc in $2; do printf 'IN: f\n0x%016x:  d503201f  nop\n' "$pc" >> "$OB/rg_trace.txt"; done
    printf 'boot line\n' > "$OB/rg_console.txt"
    cat > "$OB/bin_rg/fake-qemu" <<FQ
#!/usr/bin/env bash
LOG=""
while [ \$# -gt 0 ]; do case "\$1" in -D) LOG="\$2"; shift 2;; *) shift;; esac; done
[ -n "\$LOG" ] && cat "$OB/rg_trace.txt" > "\$LOG"
cat "$OB/rg_console.txt"
FQ
    chmod +x "$OB/bin_rg/fake-qemu"
    QEMU="$OB/bin_rg/fake-qemu" bash "$S/run_full.sh" "$wd" m "$wd/bl.bin" help 1 shell "$3" >/dev/null 2>&1
    ob_jget "$wd/fingerprint.json" "sorted(d['milestones_reached'])"
}
RG_LADDER="stage0_entry,stage1_entry,stage02_entry,stage13_entry"
RG_MAP='{"schema_version":2,"arch":"arm64","stages":[
 {"index":0,"name":"stage0","state":"exec","entry_pc":"0x201000","arch":"aarch64","origin":"container","image":"a.img"},
 {"index":1,"name":"stage1","state":"exec","entry_pc":"0x202000","arch":"aarch64","origin":"container","image":"a.img"},
 {"index":2,"name":"stage0","state":"exec","entry_pc":"0x48000000","arch":"aarch64","origin":"container","image":"b.img"},
 {"index":3,"name":"stage1","state":"exec","entry_pc":"0x48100000","arch":"aarch64","origin":"container","image":"b.img"}]}'
RG_RUNGS='{"schema":1,"rungs":[
 {"rung":"stage0_entry","stage":"stage0","index":0,"entry_pc":"0x201000"},
 {"rung":"stage1_entry","stage":"stage1","index":1,"entry_pc":"0x202000"},
 {"rung":"stage02_entry","stage":"stage0","index":2,"entry_pc":"0x48000000"},
 {"rung":"stage13_entry","stage":"stage1","index":3,"entry_pc":"0x48100000"}]}'
RGW=$(ob_rg_ws rg_dup "$RG_MAP" "$RG_RUNGS")
chk "[칸] 동명 스테이지: 둘째 이미지의 stage1 만 돌았으면 그 칸만 인정 (첫 이미지의 stage1 칸은 아님)" \
    "$(ob_rg_run "$RGW" "$((0x48100000))" "$RG_LADDER")" "['stage13_entry']"
chk "[칸] 동명 스테이지: 첫 이미지의 stage1 만 돌았으면 stage1_entry 만 인정" \
    "$(ob_rg_run "$RGW" "$((0x202000))" "$RG_LADDER")" "['stage1_entry']"
chk "[칸] 동명 스테이지: 둘 다 돌았으면 둘 다 인정" \
    "$(ob_rg_run "$RGW" "$((0x202000)) $((0x48100000))" "$RG_LADDER")" "['stage13_entry', 'stage1_entry']"
chk "[칸] 첫 스테이지(index 0)는 PC 만으로 인정하지 않는다 (동명 스테이지 사이에서도)" \
    "$(ob_rg_run "$RGW" "$((0x201000)) $((0x48000000))" "$RG_LADDER")" "['stage02_entry']"

# entry_pc 가 없는 칸 (v1 지도): 동명이면 사슬에서의 자리(index)로, 지도와 일대일로 맞을 때만
RG_RUNGS_NOPC='{"schema":1,"rungs":[
 {"rung":"stage0_entry","stage":"stage0","index":0},
 {"rung":"stage1_entry","stage":"stage1","index":1},
 {"rung":"stage02_entry","stage":"stage0","index":2},
 {"rung":"stage13_entry","stage":"stage1","index":3}]}'
RGW=$(ob_rg_ws rg_nopc "$RG_MAP" "$RG_RUNGS_NOPC")
chk "[칸] entry_pc 가 없어도 지도와 일대일로 맞으면 index 로 구분한다" \
    "$(ob_rg_run "$RGW" "$((0x48100000))" "$RG_LADDER")" "['stage13_entry']"
# 지도에 PC 를 못 얻는 실행 스테이지가 하나 더 있으면 감시 목록과 지도가 어긋난다 → 구분 불가이면 인정하지 않는다
RG_MAP_GAP='{"schema_version":2,"arch":"arm64","stages":[
 {"index":0,"name":"stage0","state":"exec","entry_pc":"0x201000"},
 {"index":1,"name":"stage1","state":"exec","entry_pc":"0x202000"},
 {"index":2,"name":"stage0","state":"exec","entry_pc":"0x48000000"},
 {"index":3,"name":"stage1","state":"exec","entry_pc":"0x48100000"},
 {"index":4,"name":"stage4","state":"exec","entry_pc":null}]}'
RGW=$(ob_rg_ws rg_gap "$RG_MAP_GAP" "$RG_RUNGS_NOPC")
chk "[칸] 어긋나서 동명 스테이지를 구분할 수 없으면 아무것도 인정하지 않는다 (추측하지 않음)" \
    "$(ob_rg_run "$RGW" "$((0x48100000))" "$RG_LADDER")" "[]"
# 칸 파일이 지도와 다른 PC 를 말하면(옛 파일) 인정하지 않는다
RG_RUNGS_STALE='{"schema":1,"rungs":[
 {"rung":"alpha_entry","stage":"alpha","index":0,"entry_pc":"0x40080000"},
 {"rung":"beta_entry","stage":"beta","index":1,"entry_pc":"0x999000"}]}'
RG_MAP_UNIQ='{"schema_version":2,"arch":"arm64","stages":[
 {"index":0,"name":"alpha","state":"exec","entry_pc":"0x40080000"},
 {"index":1,"name":"beta","state":"exec","entry_pc":"0x48200000"}]}'
RGW=$(ob_rg_ws rg_stale "$RG_MAP_UNIQ" "$RG_RUNGS_STALE")
chk "[칸] 칸 파일의 entry_pc 가 지도와 다르면 (옛 파일) 지도의 PC 가 실행돼도 인정하지 않는다" \
    "$(ob_rg_run "$RGW" "$((0x48200000))" "alpha_entry,beta_entry")" "[]"
# 회귀: 이름이 유일하면 예전처럼 지도의 PC 로 인정
RG_RUNGS_UNIQ='{"schema":1,"rungs":[
 {"rung":"alpha_entry","stage":"alpha","index":0,"entry_pc":"0x40080000"},
 {"rung":"beta_entry","stage":"beta","index":1,"entry_pc":"0x48200000"}]}'
RGW=$(ob_rg_ws rg_uniq "$RG_MAP_UNIQ" "$RG_RUNGS_UNIQ")
chk "[칸] 이름이 유일하면 그대로 인정 (회귀)" \
    "$(ob_rg_run "$RGW" "$((0x48200000))" "alpha_entry,beta_entry")" "['beta_entry']"

# ── 9. 정체 판정: 커널 채널이 움직이면 UART 가 고정이어도 정체가 아니다 ───────
ob_sc_row() {   # $1=회차 $2=fp_klast $3=fp_kuniq (비우면 커널 필드 없음) [$4=effect]
    local r="{\"round\":$1,\"fp_exc\":0,\"fp_far\":\"none\",\"fp_elr\":\"none\",\"fp_origin_esr\":\"none\",\"fp_origin_far\":\"none\",\"fp_origin_elr\":\"none\",\"fp_milestone\":\"kernel_entry\",\"fp_bytes\":45,\"fp_uniq\":2"
    [ -n "$2" ] && r="$r,\"fp_klast\":$2,\"fp_kuniq\":$3"
    [ -n "${4:-}" ] && r="$r,\"effect\":\"$4\""
    echo "$r}"
}
ob_sc_run() { python3 "$S/stop_conditions.py" "$1" --ladder kernel_entry,kernel_alive 2>/dev/null; }
mkdir -p "$OB/sc1" "$OB/sc2" "$OB/sc3" "$OB/sc4" "$OB/sc5"
{ ob_sc_row 1 "" ""; ob_sc_row 2 "" ""; ob_sc_row 3 "" ""; } > "$OB/sc1/rounds.jsonl"
OB_J=$(ob_sc_run "$OB/sc1")
chk "커널 필드가 없는 기록은 예전 그대로 정체 (stall 2)" "$(echo "$OB_J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["stall_count"], d["kernel_moving"])')" "2 False"
chk "커널 필드가 없으면 best_progress 에 커널 항목을 만들지 않음" "$(echo "$OB_J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("kernel_uniq" in d["best_progress"])')" "False"
{ ob_sc_row 1 26 3000; ob_sc_row 2 140 9000; ob_sc_row 3 390 40000; } > "$OB/sc2/rounds.jsonl"
OB_J=$(ob_sc_run "$OB/sc2")
chk "UART 지문이 같아도 커널 로그가 깊어지면 정체가 아님" "$(echo "$OB_J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["stall_count"], d["kernel_moving"])')" "0 True"
chk "best_progress 에 커널 깊이" "$(echo "$OB_J" | python3 -c 'import json,sys;d=json.load(sys.stdin);b=d["best_progress"];print(b["kernel_uniq"], b["kernel_last_time"], b["kernel_round"])')" "40000 390.0 3"
{ ob_sc_row 1 390 40000; ob_sc_row 2 396 40800; ob_sc_row 3 388 39500; } > "$OB/sc3/rounds.jsonl"
OB_J=$(ob_sc_run "$OB/sc3")
chk "같은 고원에서 호스트 속도로 ±몇 % 흔들리는 것은 진전이 아님 (정체가 쌓임)" "$(echo "$OB_J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["stall_count"], d["kernel_moving"])')" "2 False"
{ ob_sc_row 1 "" ""; ob_sc_row 2 "" ""; ob_sc_row 3 26 3000; } > "$OB/sc4/rounds.jsonl"
OB_J=$(ob_sc_run "$OB/sc4")
chk "커널 로그가 처음 나타난 회차는 움직임 (조용하던 채널이 살아남)" "$(echo "$OB_J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["stall_count"], d["kernel_moving"])')" "0 True"
# 변경을 가했더니 UART 는 그대로인데 커널이 깊어졌다 = 헛수고가 아니다
{ ob_sc_row 1 390 40000 applied; ob_sc_row 2 1500 120000; } > "$OB/sc5/rounds.jsonl"
OB_J=$(ob_sc_run "$OB/sc5")
chk "UART 불변이어도 커널이 깊어진 변경은 futile 로 세지 않음" "$(echo "$OB_J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["futile_changes"])')" "0"
{ ob_sc_row 1 390 40000 applied; ob_sc_row 2 392 40100; } > "$OB/sc5/rounds.jsonl"
OB_J=$(ob_sc_run "$OB/sc5")
chk "UART 도 커널도 안 움직인 변경은 futile" "$(echo "$OB_J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["futile_changes"])')" "1"

# 검문이 되돌린 fixer-general 의 변경도 시도로 센다. 범위 제한이 없는 fixer 는 "시도할 변경 없음" 을
# 거의 말하지 않으므로(fixer_no_new_change=false), 지문을 못 움직인 변경을 세는 것이 소진·계층 재검토에
# 닿는 유일한 길이다. 되돌려진 변경(effect=reverted)을 세지 않으면 검문이 계속 반려하는 실행은 런타임 한계까지
# 간다. 전문 fixer 의 반려는 세지 않는다 (전문가는 접을 수 있고 supervisor 가 다른 곳으로 돌린다).
ob_sg_row() {   # $1=회차 $2=fixer $3=effect $4=analyst_new_facts [$5=fp_uniq, 기본 2] -> 같은 지문의 한 줄
    echo "{\"round\":$1,\"fp_exc\":0,\"fp_far\":\"none\",\"fp_elr\":\"none\",\"fp_origin_esr\":\"none\",\"fp_origin_far\":\"none\",\"fp_origin_elr\":\"none\",\"fp_milestone\":\"none\",\"fp_bytes\":45,\"fp_uniq\":${5:-2},\"fixer\":\"$2\",\"effect\":\"$3\",\"analyst_new_facts\":$4,\"fixer_no_new_change\":false}"
}
ob_sg_run() {   # $1 = 작업 폴더 -> "<stop_reason> <futile_changes> <needs_layer_review> <moves_exhausted>"
    python3 "$S/stop_conditions.py" "$1" 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["stop_reason"], d["futile_changes"], d["needs_layer_review"], d["moves_exhausted"])'
}
mkdir -p "$OB/sg1" "$OB/sg2" "$OB/sg3" "$OB/sg4" "$OB/sg5" "$OB/sg6"
for i in 1 2 3 4 5 6 7 8 9; do ob_sg_row $i fixer-general reverted 0; done > "$OB/sg1/rounds.jsonl"
chk "[소진] 검문이 되돌린 fixer-general 변경이 지문을 못 움직이면 futile 로 세어 EXHAUSTED" \
    "$(ob_sg_run "$OB/sg1")" "EXHAUSTED 8 True True"
for i in 1 2 3 4 5 6 7 8 9; do ob_sg_row $i fixer-storage reverted 0; done > "$OB/sg2/rounds.jsonl"
chk "[소진] 전문 fixer 의 반려(reverted)는 futile 로 세지 않는다 (계속한다)" \
    "$(ob_sg_run "$OB/sg2")" "None 0 False False"
for i in 1 2 3; do ob_sg_row $i fixer-general reverted 0; done > "$OB/sg3/rounds.jsonl"
chk "[소진] 되돌려진 general 변경 둘이면 계층 재검토 (needs_layer_review), 아직 소진은 아님" \
    "$(ob_sg_run "$OB/sg3")" "None 2 True False"
{ ob_sg_row 1 fixer-general reverted 0; ob_sg_row 2 fixer-general reverted 0; ob_sg_row 3 fixer-general reverted 0 9; } > "$OB/sg4/rounds.jsonl"
chk "[소진] 되돌려진 변경 뒤에 지문이 움직였으면 그 줄에서 끊긴다 (움직임은 futile 이 아님)" \
    "$(ob_sg_run "$OB/sg4")" "None 0 False False"
{ for i in 1 2 3 4 5 6 7 8; do ob_sg_row $i fixer-general reverted 0; done; ob_sg_row 9 fixer-general reverted 1; } > "$OB/sg5/rounds.jsonl"
chk "[소진] 분석가가 새 사실을 내는 동안에는 소진이 아니다 (analyst_dry 가 필요하다)" \
    "$(ob_sg_run "$OB/sg5")" "None 8 True False"
for i in 1 2 3 4 5 6 7 8 9; do ob_sg_row $i fixer-general applied 0; done > "$OB/sg6/rounds.jsonl"
chk "[소진] 회귀: 적용된(applied) 변경은 전과 같이 센다" \
    "$(ob_sg_run "$OB/sg6")" "EXHAUSTED 8 True True"

# ── 9b. CC3: 도출된 토큰 파일이 없으면 셸 표면은 도달로 세지 않는다 ─────────────
# 벤더 배너를 코드에 두지 않는다. 배너가 콘솔에 실제로 나와도, 도출한 토큰이 없으면 그 칸을 판정하지
# 않고 이유를 말한다 (거짓 도달도, 말없는 미도달도 아니다). 문자열은 전부 시험이 지어낸 것이다.
chk "run_full.sh 에 벤더 배너 문자열이 없다 (S-BOOT · Following commands)" \
    "$(grep -c 'S-BOOT\|Following commands' "$S/run_full.sh")" "0"
ob_ns_run() {   # $1 이름 $2 표면 $3 토큰 파일 본문 ("-" 이면 파일 없음) $4 콘솔 본문 -> 작업 폴더
    local wd="$OB/$1"; rm -rf "$wd"; mkdir -p "$wd/06_machine" "$wd/07_logs" "$wd/fw" "$OB/bin_ns"
    printf '### 우회1\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$wd/06_machine/bypasses.md"
    printf 'container' > "$wd/bl.bin"
    if [ "$3" != "-" ]; then printf '%s' "$3" > "$wd/milestone_tokens.txt"; fi
    printf '%b' "$4" > "$OB/ns_console.txt"; printf 'boot\n' > "$OB/ns_trace.txt"
    cat > "$OB/bin_ns/fake-qemu" <<FQNS
#!/usr/bin/env bash
LOG=""
while [ \$# -gt 0 ]; do case "\$1" in -D) LOG="\$2"; shift 2;; *) shift;; esac; done
[ -n "\$LOG" ] && cat "$OB/ns_trace.txt" > "\$LOG"
cat "$OB/ns_console.txt"
FQNS
    chmod +x "$OB/bin_ns/fake-qemu"
    QEMU="$OB/bin_ns/fake-qemu" TIMEOUT=4 TIMEOUT_PROBE=0 bash "$S/run_full.sh" "$wd" m "$wd/bl.bin" help 1 "$2" "$2" >/dev/null 2> "$wd/err.txt"
    echo "$wd"
}
NS_CON='S-BOOT # \nFollowing commands are supported\n'
NSW=$(ob_ns_run ns_none shell - "$NS_CON")
chk "[표면] 토큰 파일이 없으면 셸 배너가 콘솔에 있어도 도달로 세지 않는다" \
    "$(ob_jget "$NSW/fingerprint.json" "d['milestone'], d['milestones_reached'], d['source_gate']['injected']")" "none [] False"
chk "  이유가 지문에 실린다 (no derived token file)" "$(ob_jget "$NSW/fingerprint.json" "d['surface_not_credited']")" "no derived token file"
chk "  회차 stderr 에도 같은 이유" "$(grep -c 'no derived token file' "$NSW/err.txt")" "1"
NSW=$(ob_ns_run ns_empty shell "" "$NS_CON")
chk "[표면] 빈 토큰 파일도 같다 (도출한 것이 없다)" \
    "$(ob_jget "$NSW/fingerprint.json" "d['milestone'], d['surface_not_credited']")" "none no derived token file"
NSW=$(ob_ns_run ns_tok shell $'shell\tS-BOOT # \n' "$NS_CON")
chk "[표면] 도출한 토큰이 있으면 그 토큰으로 도달 (대조군)" \
    "$(ob_jget "$NSW/fingerprint.json" "d['milestone'], 'surface_not_credited' in d")" "shell False"
NSW=$(ob_ns_run ns_other shell $'shell\tNO_SUCH_PROMPT\n' "$NS_CON")
chk "[표면] 토큰 파일은 있으나 그 토큰이 안 나오면 미도달이되 '파일 없음' 이유는 붙지 않는다" \
    "$(ob_jget "$NSW/fingerprint.json" "d['milestone'], 'surface_not_credited' in d")" "none False"
NSW=$(ob_ns_run ns_fb fastboot - 'fastboot: processing commands\n')
chk "[표면] fastboot 은 이 계약의 대상이 아니다 (예전 폴백 그대로)" \
    "$(ob_jget "$NSW/fingerprint.json" "d['milestone'], 'surface_not_credited' in d")" "fastboot False"
NSW=$(ob_ns_run ns_nosurf none - "$NS_CON")
chk "[표면] 표면이 없으면(none) 판정할 칸이 없으니 이유도 붙이지 않는다" \
    "$(ob_jget "$NSW/fingerprint.json" "d['milestone'], 'surface_not_credited' in d")" "none False"

# ── 10. 하니스 곁채널: 시각 표지 · 호스트 로그 · 정지 파일 ───────────────────
OBH="$OB/harness"; mkdir -p "$OBH"
FAKE_RUN=6 FAKE_RESET_AFTER=0.3 python3 "$S/uart_harness.py" --console "$OBH/c.txt" --input-log "$OBH/i.txt" \
    --summary "$OBH/s.json" --timeout 1.5 --host-log "$OBH/h.txt" --mark "kernel_entry=jump to K64" \
    -- python3 "$FQ" >/dev/null 2>&1
chk "표지: 토큰이 처음 나온 벽시계를 요약에 남김" "$(ob_jget "$OBH/s.json" "'yes' if d['marks']['kernel_entry']['epoch'] else 'no'")" "yes"
chk "호스트 줄은 시각과 함께 host 로그로 (게스트 콘솔에는 없음)" \
    "$(python3 - "$OBH/h.txt" "$OBH/c.txt" <<'PY'
import re, sys
h = open(sys.argv[1]).read().splitlines()
c = open(sys.argv[2]).read()
ok = h and all(re.match(r"^\d+\.\d+ qemu-system-aarch64: ", l) for l in h) and "qemu-system" not in c
print("ok" if ok else "bad")
PY
)" "ok"
chk "요약의 호스트 줄 수" "$(ob_jget "$OBH/s.json" "d['host_lines']")" "2"
chk "리셋 신호: 점프 뒤 창 안의 호스트 줄을 시각으로 판정" \
    "$(REHOST_RESET_PATTERNS='UNMODELLED read 0xfeed0010' python3 "$MO" reset-signal --host-log "$OBH/h.txt" --summary "$OBH/s.json" --window 5 | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["signal"], d["delta_s"] < 5)')" "True True"
chk "같은 줄이라도 창을 0 으로 좁히면 거짓" \
    "$(REHOST_RESET_PATTERNS='UNMODELLED read 0xfeed0010' python3 "$MO" reset-signal --host-log "$OBH/h.txt" --summary "$OBH/s.json" --window 0.05 | python3 -c 'import json,sys;print(json.load(sys.stdin)["signal"])')" "False"

FAKE_RUN=6 python3 "$S/uart_harness.py" --console "$OBH/c2.txt" --input-log "$OBH/i2.txt" \
    --summary "$OBH/s2.json" --timeout 1.2 -- python3 "$FQ" >/dev/null 2>&1
chk "옵션이 없으면 요약에 곁채널 항목이 생기지 않음 (예전 요약 그대로)" \
    "$(ob_jget "$OBH/s2.json" "any(k in d for k in ('marks','host_lines','early_exit'))")" "False"
# CC4: 도출한 게이트가 없으면 인터럽트를 보내지 않는다 (예전에는 CR 3 개가 기본값이었다)
FAKE_RUN=6 python3 "$S/uart_harness.py" --console "$OBH/c4.txt" --input-log "$OBH/i4.txt" \
    --summary "$OBH/s4.json" --timeout 1.2 -- python3 "$FQ" >/dev/null 2>&1
chk "계획 파일이 없으면: 한 바이트도 보내지 않고 계획 출처는 absent" \
    "$(ob_jget "$OBH/s4.json" "d['source'], d['bytes_sent'], d['supply_attempts'], d['input_offered'], d['plan_note']")" "absent 0 0 False no input_plan.json"
printf '{"autoboot_interrupt":{"bytes":"\\r","count":4}}\n' > "$OBH/plan4.json"
FAKE_RUN=6 python3 "$S/uart_harness.py" --console "$OBH/c5.txt" --input-log "$OBH/i5.txt" \
    --summary "$OBH/s5.json" --timeout 1.2 --plan "$OBH/plan4.json" -- python3 "$FQ" >/dev/null 2>&1
chk "도출한 계획이 있으면 그 개수만큼 보낸다 (대조군): 출처 derived" \
    "$(ob_jget "$OBH/s5.json" "d['source'], d['count'], d['bytes_sent'] >= 4, 'plan_note' in d")" "derived 4 True False"
chk "함수 단위: load_plan 은 없는 파일 · count 없는 게이트를 모두 absent 로 (기본 CR 개수가 없다)" \
    "$(python3 - "$S" "$OBH/plan4.json" <<'PY'
import json, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import uart_harness as uh
t = tempfile.mkdtemp()
def put(obj):
    p = os.path.join(t, "p.json"); json.dump(obj, open(p, "w")); return p
rows = [uh.load_plan(None), uh.load_plan(os.path.join(t, "nope.json")),
        uh.load_plan(put({"autoboot_interrupt": {"bytes": "\\r"}})),
        uh.load_plan(put({"autoboot_interrupt": {"count": 3}}))]
print([(r["source"], r["count"], r["byte"]) for r in rows], hasattr(uh, "DEFAULT_CR_COUNT"))
PY
)" "[('absent', 0, ''), ('absent', 0, ''), ('absent', 0, ''), ('absent', 0, '')] False"
rm -f "$OBH/stop.flag"
( sleep 0.8; : > "$OBH/stop.flag" ) &
FAKE_RUN=30 python3 "$S/uart_harness.py" --console "$OBH/c3.txt" --input-log "$OBH/i3.txt" \
    --summary "$OBH/s3.json" --timeout 20 --stop-file "$OBH/stop.flag" -- python3 "$FQ" >/dev/null 2>&1
OB_RC=$?
wait
chk "정지 파일이 생기면 시간 한도 전에 끝나고 정상 종료(124)로 처리" \
    "$OB_RC $(ob_jget "$OBH/s3.json" "d['early_exit'], d['elapsed_s'] < 10")" "124 stop_file True"

# ── 11. 지문 도우미 ─────────────────────────────────────────────────────────
OB_R=$( . "$S/fingerprint_lib.sh"; fp_kernel_metrics "$OB/k_ok.log"; echo "$FP_KLINES $FP_KUNIQ $FP_KLAST"
        fp_kernel_metrics "$OB/none.log"; echo "$FP_KLINES $FP_KUNIQ $FP_KLAST" )
chk "커널 지표: 줄 수·고유 텍스트 수·마지막 커널 시각 (로그가 없으면 null)" "$OB_R" "3 3 5.0
null null null"
printf '{"console_bytes": 45, "kernel": {"uniq": 1000}}\n' > "$OB/prev.json"
chk "UART 크기가 같고 커널이 안 자랐으면 막힌 것" "$( . "$S/fingerprint_lib.sh"; fp_prev_stuck "$OB/prev.json" 45 1050 )" "yes"
chk "UART 크기가 같아도 커널 고유 줄이 1 할 넘게 늘었으면 막힌 것이 아님" "$( . "$S/fingerprint_lib.sh"; fp_prev_stuck "$OB/prev.json" 45 1500 )" "no"
chk "커널 인자를 안 주면 예전 판정 그대로" "$( . "$S/fingerprint_lib.sh"; fp_prev_stuck "$OB/prev.json" 45 )" "yes"

# ── 12. run_round.sh 로 한 회차: 가짜 QEMU 에 모니터 소켓이 붙는가 ─────────────
ob_ws() {   # $1 이름 -> 작업 폴더
    local wd="$OB/$1"; mkdir -p "$wd/06_machine" "$wd/07_logs" "$wd/fw"
    printf '### 우회1\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$wd/06_machine/bypasses.md"
    printf 'static int unrelated;\n' > "$wd/06_machine/machine.c"
    printf 'container' > "$wd/bl.bin"
    printf 'kernel_entry\tjump to K64\nkernel_alive\tLinux version\tmemdump\nuserspace\tmsg 5\tmemdump\n' > "$wd/milestone_tokens.txt"
    echo "$wd"
}
ob_round() {   # $1 작업폴더 $2 회차 $3 사다리 — 환경변수는 호출 쪽에서
    QEMU="$OB/bin/fake-qemu" TRACE_DIR="$OB/traces" MEMDUMP_FLOOR=0.2 MEMDUMP_CEILING=0.5 FAKE_PAD=64 \
        bash "$S/run_round.sh" "$1" fakem "$2" kernel_alive "$3" "$1/bl.bin" help shell > "$1/obs_$2.json" 2> "$1/err_$2.txt"
}
cat > "$OB/plan_e2e.json" <<'EOF'
{"channel":"memdump","region_base":"0x50100000","region_size":16384,"console_size":4096,"source":"cmdline","evidence":"synthetic","reset_patterns":["UNMODELLED read 0xfeed0010"],"reset_window_s":5}
EOF
python3 - "$OB" <<'PY'
import json, sys
ob = sys.argv[1]
json.dump({"stages": [
    {"index": 0, "name": "s0", "state": "exec", "arch": "aarch32", "entry_pc": "0x60000000"},
    {"index": 1, "name": "s1", "state": "exec", "arch": "aarch64", "entry_pc": "0x60400000"}]},
    open(ob + "/sm_e2e.json", "w"))
PY

# 12a. 계획이 있다: 모니터가 붙고, 호스트 줄이 갈라지고, 커널 로그가 칸을 채운다
OBW1=$(ob_ws e2e_on); cp "$OB/plan_e2e.json" "$OBW1/memdump_plan.json"; cp "$OB/sm_e2e.json" "$OBW1/stage_map.json"
TIMEOUT=4 TIMEOUT_PROBE=0 FAKE_RUN=30 FAKE_RESET_AFTER=0.4 FAKE_ARGS_OUT="$OB/args_on.txt" \
    FAKE_ENV_OUT="$OB/env_on.txt" REHOST_MEMDUMP_REGION=0x1:0x2 \
    FAKE_TRACE='0x0000000060000000:  nop|0x60400000:  nop' \
    FAKE_STDOUT_EXTRA='qemu-system-aarch64: info: leaked into stdout|S-BOOT guest line' \
    ob_round "$OBW1" 1 "kernel_entry,kernel_alive,userspace"
OB_O="$OBW1/obs_1.json"
chk "[계획 있음] QEMU 인자에 모니터 소켓" "$(grep -c -- '-monitor unix:.*,server,nowait' "$OB/args_on.txt")" "1"
chk "[계획 있음] 콘솔은 게스트 줄만 (호스트 줄 제거, 게스트 줄은 보존)" \
    "$(grep -c 'qemu-system' "$OBW1/07_logs/console_1.txt") $(grep -c 'S-BOOT guest line' "$OBW1/07_logs/console_1.txt")" "0 1"
chk "[계획 있음] 호스트 줄은 host_1.txt 에 (시각 있는 줄 + 콘솔에서 옮겨 온 줄)" \
    "$(grep -c 'qemu-system' "$OBW1/07_logs/host_1.txt") $(grep -c 'leaked into stdout' "$OBW1/07_logs/host_1.txt") $(grep -c '^[0-9]*\.[0-9]* qemu-system' "$OBW1/07_logs/host_1.txt")" "3 1 2"
chk "[계획 있음] 커널 로그 kernel_1.log 가 '<초> <텍스트>'" "$(head -1 "$OBW1/07_logs/kernel_1.log" | grep -c '^0.000000 .*Linux version')" "1"
chk "[계획 있음] memdump 토큰으로 kernel_alive·userspace 도달 (uart 토큰 kernel_entry 도 함께)" \
    "$(ob_jget "$OB_O" "','.join(d['milestones_reached'])")" "kernel_entry,kernel_alive,userspace"
chk "[계획 있음] 가장 높은 칸은 userspace" "$(ob_jget "$OB_O" "d['milestone']")" "userspace"
chk "[계획 있음] kernel_alive 증거 (배너·태스크·커널 시각)" \
    "$(ob_jget "$OB_O" "d['kernel_alive_evidence']['via'], d['kernel_alive_evidence']['task'], d['kernel_alive_evidence']['kernel_time']")" "banner swapper 0.0"
chk "[계획 있음] channels: UART 바이트·커널 줄·호스트 줄" \
    "$(ob_jget "$OB_O" "'yes' if d['channels']['uart_bytes']>0 and d['channels']['kernel_lines']>=20 and d['channels']['host_lines']==3 else d['channels']")" "yes"
chk "[계획 있음] 점프 직후 리셋 호스트 줄 → guest_reset_signal" "$(ob_jget "$OB_O" "d['guest_reset_signal']")" "True"
chk "[계획 있음] 커널 깊이 지표 (마지막 시각·고유 줄)" "$(ob_jget "$OB_O" "'yes' if d['kernel_last_time']>=1 and d['kernel_uniq']>=20 else 'no'")" "yes"
chk "[계획 있음] 감시 PC: v2 진입 PC 를 (제로 패딩 포함) 트레이스에서 잡음" \
    "$(ob_jget "$OBW1/07_logs/trace_1.json" "','.join(e['pc'] for e in d['stage_entries_seen'])")" "0x60000000,0x60400000"
chk "[계획 있음] 원본 스냅샷이 트레이스 영역에 남음" "$(ls "$OB/traces/memdump_1"/ps_*.bin 2>/dev/null | wc -l | tr -d ' ' | awk '{print ($1>=3)?"yes":"no"}')" "yes"
chk "[계획 있음] 지문에 channels/kernel 이 붙음" "$(ob_jget "$OBW1/fingerprint.json" "'channels' in d and d['kernel']['enabled']")" "True"
chk "[계획 있음] run_ok" "$(ob_jget "$OB_O" "d['run_ok']")" "True"
# K2: the machine's write guard is armed from the plan - the range the host reads (16384 = 0x4000)
chk "[계획 있음] QEMU 프로세스에 REHOST_MEMDUMP_REGION=<base>:<size> (계획의 값. 환경에 있던 옛 값이 아님)" \
    "$(cat "$OB/env_on.txt")" "REHOST_MEMDUMP_REGION=0x50100000:0x4000"
chk "[계획 있음] 보호 영역을 회차 stderr 에 밝힘" "$(grep -c 'REHOST_MEMDUMP_REGION=0x50100000:0x4000' "$OBW1/err_1.txt")" "1"
# K3: where the channel logs are
chk "[계획 있음] 관측 문서에 kernel_log · host_log 경로 (이 회차의 07_logs, 파일이 실제로 있음)" \
    "$(ob_jget "$OB_O" "d['kernel_log'].endswith('/07_logs/kernel_1.log') and d['host_log'].endswith('/07_logs/host_1.txt')") $([ -f "$OBW1/07_logs/kernel_1.log" ] && [ -f "$OBW1/07_logs/host_1.txt" ] && echo files)" \
    "True files"

# 12b. 계획이 없다: 예전과 똑같다 (모니터 없음, 새 파일 없음, 콘솔 그대로, 지문 키 그대로)
OBW2=$(ob_ws e2e_off); cp "$OB/sm_e2e.json" "$OBW2/stage_map.json"
TIMEOUT=4 TIMEOUT_PROBE=0 FAKE_RUN=1 FAKE_ARGS_OUT="$OB/args_off.txt" \
    FAKE_ENV_OUT="$OB/env_off.txt" REHOST_MEMDUMP_REGION=0x1:0x2 REHOST_RESET_PATTERNS= \
    FAKE_STDOUT_EXTRA='qemu-system-aarch64: info: leaked into stdout|S-BOOT guest line' \
    ob_round "$OBW2" 1 "kernel_entry,kernel_alive,userspace"
OB_O="$OBW2/obs_1.json"
chk "[계획 없음] QEMU 인자에 모니터 소켓이 없다" "$(grep -c -- '-monitor' "$OB/args_off.txt")" "0"
chk "[계획 없음] 커널 로그 · memdump · 리셋 파일을 만들지 않는다" \
    "$(ls "$OBW2/07_logs" | grep -c '^kernel_\|^memdump_\|^reset_')" "0"
# K4: the host lines are recorded without a plan and without reset patterns
chk "[계획 없음] 호스트 줄이 있었으니 host_1.txt 가 있다 (계획 · 리셋 패턴과 무관)" \
    "$(grep -c 'qemu-system' "$OBW2/07_logs/host_1.txt") $(grep -c 'image attached' "$OBW2/07_logs/host_1.txt") $(grep -c 'leaked into stdout' "$OBW2/07_logs/host_1.txt")" "2 1 1"
chk "[계획 없음] stderr 에서 온 줄에는 시각이 붙는다 (옮겨 온 줄에는 없다)" \
    "$(grep -c '^[0-9]*\.[0-9]* qemu-system' "$OBW2/07_logs/host_1.txt")" "1"
chk "[계획 없음] 같은 줄이 qemu_1.stderr.txt 에도 그대로 남는다" "$(grep -c 'image attached' "$OBW2/07_logs/qemu_1.stderr.txt")" "1"
chk "[계획 없음] 콘솔은 게스트 줄만 (QEMU 가 stdout 에 흘린 호스트 줄은 host 로그로 옮겨진다)" \
    "$(grep -c 'leaked into stdout' "$OBW2/07_logs/console_1.txt") $(grep -c 'S-BOOT guest line' "$OBW2/07_logs/console_1.txt")" "0 1"
chk "[계획 없음] 지문에 커널 · 리셋 · 조기 종료 키가 없다 (channels 는 호스트 줄 수만)" \
    "$(ob_jget "$OBW2/fingerprint.json" "any(k in d for k in ('kernel','guest_reset_signal','early_exit')), d['channels']")" \
    "False {'uart_bytes': $(ob_jget "$OBW2/fingerprint.json" "d['console_bytes']"), 'kernel_lines': 0, 'host_lines': 2, 'host_lines_moved': 1}"
chk "[계획 없음] QEMU 프로세스에 REHOST_MEMDUMP_REGION 이 없다 (호출자 환경에 있어도)" "$(cat "$OB/env_off.txt")" "REHOST_MEMDUMP_REGION=<unset>"
chk "[계획 없음] 환경의 보호 영역을 무시했다고 밝힘" "$(grep -c 'REHOST_MEMDUMP_REGION 을 무시' "$OBW2/err_1.txt")" "1"
chk "[계획 없음] 관측 문서: kernel_log 는 null, host_log 는 경로" \
    "$(ob_jget "$OB_O" "d['kernel_log'], d['host_log'].endswith('/07_logs/host_1.txt')")" "None True"
chk "[계획 없음] memdump 토큰 칸은 도달로 세지 않는다 (uart 토큰만)" "$(ob_jget "$OB_O" "','.join(d['milestones_reached'])")" "kernel_entry"
chk "[계획 없음] 관측 문서: 끈 커널 채널은 모름이 아니라 0, 호스트 줄은 센 만큼" \
    "$(ob_jget "$OB_O" "d['channels']['kernel_lines'], d['channels']['host_lines'], d['guest_reset_signal'], d['kernel_alive_evidence']")" "0 2 False None"
chk "[계획 없음] 안내 문구: 관측 채널이 없다 (도달 불가가 아님)" "$(grep -c '관측 채널이 없는 것' "$OBW2/err_1.txt")" "1"
chk "[계획 없음] v2 지도에서도 감시 PC 를 잡는다 (예전엔 항상 빈 목록)" \
    "$(ob_jget "$OBW2/07_logs/trace_1.json" "len(d['watch'])")" "2"

# 12c. 머신 소스에 토큰 문자열이 있으면 memdump 도달도 인정하지 않는다
OBW3=$(ob_ws e2e_inj); cp "$OB/plan_e2e.json" "$OBW3/memdump_plan.json"
printf 'static const char *s = "Linux version";\n' > "$OBW3/06_machine/machine.c"
TIMEOUT=4 TIMEOUT_PROBE=0 FAKE_RUN=3 ob_round "$OBW3" 1 "kernel_entry,kernel_alive,userspace"
chk "[자가주입] memdump 토큰이 머신 소스에 있으면 아무 칸도 인정하지 않는다" \
    "$(ob_jget "$OBW3/obs_1.json" "d['injected'], d['milestone'], d['milestones_reached']")" "True none []"
chk "[자가주입] 인정하지 않은 칸의 kernel_alive 증거는 보고하지 않고 보류로 표시" \
    "$(ob_jget "$OBW3/obs_1.json" "d['kernel_alive_evidence'], d['kernel']['alive_withheld']")" "None True"

# 12c2. 타임아웃 프로브가 커널 채널도 본다: UART 는 그대로고 더 오래 돌리니 커널 로그가 더 나왔다
OBW5=$(ob_ws e2e_probe); cp "$OB/plan_e2e.json" "$OBW5/memdump_plan.json"
printf 'kernel_entry\tjump to K64\nkernel_alive\tNO_SUCH_STRING\tmemdump\n' > "$OBW5/milestone_tokens.txt"
TIMEOUT=2 TIMEOUT_PROBE=0 FAKE_RUN=30 ob_round "$OBW5" 1 "kernel_alive"
# 앞 회차의 커널 고유 줄 수를 크게 못 박아 "이전 회차와 같은 막힌 상태" 판정이 실행 속도에 흔들리지 않게 한다
python3 - "$OBW5/fingerprint.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["kernel"]["uniq"] = 1000000
json.dump(d, open(sys.argv[1], "w"))
PY
TIMEOUT=2 PROBE_MULT=2 TIMEOUT_PROBE=1 FAKE_RUN=30 ob_round "$OBW5" 2 "kernel_alive"
chk "[프로브] 칸에 못 닿은 막힌 회차는 더 긴 실행으로 확인한다" "$(ob_jget "$OBW5/obs_2.json" "d['milestone']")" "none"
chk "[프로브] UART 가 그대로여도 커널 로그가 더 나오면 timeout_bound (실행 시간이 벽)" \
    "$(ob_jget "$OBW5/obs_2.json" "d['timeout_bound'], d['kernel']['probe_uniq'] > d['kernel']['uniq']")" "True True"

# 12d. 예외 폭주 조기 종료 (환경변수로 켤 때만)
OBW4=$(ob_ws e2e_exc)
OB_START=$(date +%s)
MAX_EXCEPTIONS=4000 TIMEOUT=30 TIMEOUT_PROBE=0 FAKE_RUN=60 FAKE_EXC=300 ob_round "$OBW4" 1 "kernel_entry"
OB_ELAPSED=$(( $(date +%s) - OB_START ))
chk "[조기 종료] 예외가 한도를 넘으면 시간 한도 전에 끝난다" "$([ "$OB_ELAPSED" -lt 20 ] && echo early || echo "late(${OB_ELAPSED}s)")" "early"
chk "[조기 종료] 사유와 한도가 관측 문서에 남는다" "$(ob_jget "$OBW4/obs_1.json" "d['early_exit']['reason'], d['early_exit']['limit']")" "exception_threshold 4000"
chk "[조기 종료] 실행 실패로 취급하지 않는다" "$(ob_jget "$OBW4/obs_1.json" "d['run_ok']")" "True"

# 12e. 호스트 줄이 하나도 없는 회차: 계획도 채널도 없으면 host 파일을 만들지 않는다 (null 은 "없음")
OBW6=$(ob_ws e2e_quiet); cp "$OB/sm_e2e.json" "$OBW6/stage_map.json"
TIMEOUT=3 TIMEOUT_PROBE=0 FAKE_RUN=1 FAKE_NO_HOST=1 REHOST_RESET_PATTERNS= ob_round "$OBW6" 1 "kernel_entry"
chk "[호스트 줄 없음] host_1.txt 를 만들지 않는다 (빈 파일로 '말이 없었다' 와 '채널이 없다' 를 섞지 않는다)" \
    "$(ls "$OBW6/07_logs" | grep -c '^host_\|^kernel_')" "0"
chk "[호스트 줄 없음] 관측 문서: kernel_log · host_log 는 null, 호스트 줄 0" \
    "$(ob_jget "$OBW6/obs_1.json" "d['kernel_log'], d['host_log'], d['channels']['host_lines']")" "None None 0"
chk "[호스트 줄 없음] 지문에 channels 키가 없다 (끈 채널의 지문은 예전 그대로)" \
    "$(ob_jget "$OBW6/fingerprint.json" "any(k in d for k in ('channels','kernel','guest_reset_signal','early_exit'))")" "False"

# 12f. 리셋 패턴만 있고 계획은 없다 (옛 채널): 말이 없어도 빈 host 파일이 있다 = "채널 켬, 조용함"
OBW7=$(ob_ws e2e_pat); cp "$OB/sm_e2e.json" "$OBW7/stage_map.json"
TIMEOUT=3 TIMEOUT_PROBE=0 FAKE_RUN=1 FAKE_NO_HOST=1 REHOST_RESET_PATTERNS='UNMODELLED read 0x1' ob_round "$OBW7" 1 "kernel_entry"
chk "[리셋 패턴] 채널이 켜져 있고 조용하면 빈 host_1.txt 가 있다" \
    "$([ -f "$OBW7/07_logs/host_1.txt" ] && [ ! -s "$OBW7/07_logs/host_1.txt" ] && echo empty-file || echo other)" "empty-file"
chk "[리셋 패턴] 관측 문서: host_log 는 그 파일, kernel_log 는 null (계획이 없으므로)" \
    "$(ob_jget "$OBW7/obs_1.json" "d['host_log'].endswith('/07_logs/host_1.txt'), d['kernel_log']")" "True None"

# 12g. 깨진 계획: 채널을 켜지 않고, 보호 영역도 주지 않는다
OBW8=$(ob_ws e2e_badplan); cp "$OB/sm_e2e.json" "$OBW8/stage_map.json"; cp "$OB/bad_plan.json" "$OBW8/memdump_plan.json"
TIMEOUT=3 TIMEOUT_PROBE=0 FAKE_RUN=1 FAKE_ARGS_OUT="$OB/args_bad.txt" FAKE_ENV_OUT="$OB/env_bad.txt" ob_round "$OBW8" 1 "kernel_entry"
chk "[깨진 계획] 모니터 소켓도 보호 영역도 없고 회차는 정상" \
    "$(grep -c -- '-monitor' "$OB/args_bad.txt") $(cat "$OB/env_bad.txt") $(ob_jget "$OBW8/obs_1.json" "d['run_ok'], d['kernel_log']")" \
    "0 REHOST_MEMDUMP_REGION=<unset> True None"
chk "[깨진 계획] 쓸 수 없다고 밝힘" "$(grep -c 'memdump_plan.json 을 쓸 수 없어' "$OBW8/err_1.txt")" "1"

# 12h. 커널 태스크 줄 형식 (K5): 이 대상의 커널이 [pid:comm] 으로 찍지 않을 때 분석가가 파일에 쓴다.
# 가짜 커널은 "{comm=init}" 로 찍는다. 기본 형식으로는 태스크 줄이 하나도 없어 kernel_alive 를 인정하지 않는다.
ob_rx_ws() {   # $1 이름 -> 작업 폴더 (계획 있음, memdump 토큰만 있는 칸)
    local wd; wd=$(ob_ws "$1"); cp "$OB/plan_e2e.json" "$wd/memdump_plan.json"; cp "$OB/sm_e2e.json" "$wd/stage_map.json"
    printf 'kernel_entry\tjump to K64\nkernel_alive\tmsg\tmemdump\n' > "$wd/milestone_tokens.txt"
    echo "$wd"
}
ob_rx_round() {   # $1 작업폴더 — 환경변수는 호출 쪽에서
    TIMEOUT=4 TIMEOUT_PROBE=0 FAKE_RUN=30 FAKE_BANNER=0 FAKE_TASK='{comm=init}' ob_round "$1" 1 "kernel_entry,kernel_alive"
}
OBW9=$(ob_rx_ws e2e_rx_file); printf '\\{comm=([a-z]+)\\}\n' > "$OBW9/kernel_task_regex.txt"
KERNEL_TASK_REGEX= ob_rx_round "$OBW9"
chk "[태스크 형식] kernel_task_regex.txt 의 형식으로 kernel_alive 를 인정한다 (태스크 이름은 첫 그룹)" \
    "$(ob_jget "$OBW9/obs_1.json" "d['milestone'], d['kernel_alive_evidence']['task']")" "kernel_alive init"
chk "[태스크 형식] 어떤 형식으로 판정했는지 스캔 보고에 남는다 (기본 형식이 아니다)" \
    "$(ob_jget "$OBW9/07_logs/memdump_scan_1.json" "d['task_regex']['custom'], d['task_regex']['pattern']")" 'True \{comm=([a-z]+)\}'
chk "[태스크 형식] 어느 파일에서 왔는지 stderr 에 밝힌다" "$(grep -c 'kernel_task_regex.txt' "$OBW9/err_1.txt")" "1"
OBW10=$(ob_rx_ws e2e_rx_env); printf '\\{comm=([a-z]+)\\}\n' > "$OBW10/kernel_task_regex.txt"
KERNEL_TASK_REGEX='\{nomatch=([a-z]+)\}' ob_rx_round "$OBW10"
chk "[태스크 형식] 환경의 KERNEL_TASK_REGEX 가 파일보다 앞선다 (맞지 않는 형식이면 인정하지 않는다)" \
    "$(ob_jget "$OBW10/obs_1.json" "d['milestone']") $(ob_jget "$OBW10/07_logs/memdump_scan_1.json" "d['task_regex']['pattern']")" 'kernel_entry \{nomatch=([a-z]+)\}'
OBW11=$(ob_rx_ws e2e_rx_bad); printf '(\n' > "$OBW11/kernel_task_regex.txt"
KERNEL_TASK_REGEX= ob_rx_round "$OBW11"
chk "[태스크 형식] 깨진 정규식은 밝히고 기본 형식으로 돌아간다 (회차는 정상, 인정은 없다)" \
    "$(grep -c 'kernel_task_regex.txt 에 올바른 정규식이 없어' "$OBW11/err_1.txt") $(ob_jget "$OBW11/obs_1.json" "d['run_ok'], d['milestone']") $(ob_jget "$OBW11/07_logs/memdump_scan_1.json" "d['task_regex']['custom']")" \
    "1 True kernel_entry False"

# 12i. 태스크 형식의 타당성: 분석가가 고른 형식이 판정을 느슨하게 만들 수 없다.
# 링을 부트로더와 커널이 함께 쓰면 부트로더 줄에도 타임스탬프는 있고 태스크만 없다. 느슨한 형식
# (예: [a-z]+ [a-z]+ 나 \w+) 은 그 줄을 "태스크 줄" 로 읽어, 커널이 한 번도 돌지 않은 링에서
# kernel_alive 를 인정한다. 형식을 읽을 때 걸러야 하고, 걸렀다는 사실이 관측에 남아야 한다.
ob_bare_ws() {   # $1 이름 -> 작업 폴더 (링에 부트로더 줄만 있고 커널 줄은 없다. 토큰은 그 줄에 맞는다)
    local wd; wd=$(ob_ws "$1"); cp "$OB/plan_e2e.json" "$wd/memdump_plan.json"; cp "$OB/sm_e2e.json" "$wd/stage_map.json"
    printf 'kernel_entry\tjump to K64\nkernel_alive\tboot stage\tmemdump\n' > "$wd/milestone_tokens.txt"
    echo "$wd"
}
ob_bare_round() {   # $1 작업폴더 — 환경변수는 호출 쪽에서. 커널 줄 0, 배너 없음, 부트로더 줄 4
    TIMEOUT=4 TIMEOUT_PROBE=0 FAKE_RUN=30 FAKE_BANNER=0 FAKE_ADV=0 FAKE_BARE=4 ob_round "$1" 1 "kernel_entry,kernel_alive"
}
OBW13=$(ob_bare_ws e2e_rx_loose_file); printf '[a-z]+ [a-z]+\n' > "$OBW13/kernel_task_regex.txt"
KERNEL_TASK_REGEX= ob_bare_round "$OBW13"
chk "[느슨한 형식] 부트로더 줄뿐인 링에서 kernel_alive 를 인정하지 않는다 (파일의 형식)" \
    "$(ob_jget "$OBW13/obs_1.json" "d['run_ok'], d['milestone'], d['kernel_alive_evidence']")" "True kernel_entry None"
chk "[느슨한 형식] 관측 문서의 task_regex 가 기본 형식으로 돌아갔고 무엇을 왜 거절했는지 말한다" \
    "$(ob_jget "$OBW13/obs_1.json" "d['task_regex']['custom'], d['task_regex']['rejected']['pattern'], len(d['task_regex']['rejected']['problems']) >= 1")" \
    "False [a-z]+ [a-z]+ True"
chk "[느슨한 형식] 이유에 고정 글자 수와 태스크 없는 줄에 맞는다는 사실이 있다" \
    "$(ob_jget "$OBW13/obs_1.json" "any('고정 글자가 0 개' in x for x in d['task_regex']['rejected']['problems']), any('태스크가 없는 줄에도 맞음' in x for x in d['task_regex']['rejected']['problems'])")" "True True"
chk "[느슨한 형식] stderr 가 거절했다고 밝힌다" "$(grep -c 'kernel_task_regex.txt 의 형식이 너무 느슨해 판정에 쓰지 않습니다' "$OBW13/err_1.txt")" "1"
chk "[느슨한 형식] 거절 뒤의 판정은 기본 형식의 것이다 (태스크 줄 0, 도달한 memdump 칸 없음)" \
    "$(ob_jget "$OBW13/07_logs/memdump_scan_1.json" "d['task_lines'], d['reached']")" "0 []"
OBW14=$(ob_bare_ws e2e_rx_loose_env)
KERNEL_TASK_REGEX='\w+' ob_bare_round "$OBW14"
chk "[느슨한 형식] 환경의 KERNEL_TASK_REGEX 도 같다 (\\w+ 는 거절, 인정 없음, 거절이 기록에 남는다)" \
    "$(ob_jget "$OBW14/obs_1.json" "d['milestone'], d['task_regex']['custom'], d['task_regex']['rejected']['pattern']")" 'kernel_entry False \w+'
chk "[느슨한 형식] 환경의 형식도 stderr 에 거절을 밝힌다" "$(grep -c '환경의 KERNEL_TASK_REGEX 가 너무 느슨해' "$OBW14/err_1.txt")" "1"
OBW15=$(ob_bare_ws e2e_rx_probe); printf 'boot|jump|stage\n' > "$OBW15/kernel_task_regex.txt"
KERNEL_TASK_REGEX= ob_bare_round "$OBW15"
chk "[느슨한 형식] 고정 글자가 충분해도 태스크 없는 줄에 맞으면 거절한다 (boot|jump|stage)" \
    "$(ob_jget "$OBW15/obs_1.json" "d['milestone'], d['task_regex']['rejected']['pattern']")" "kernel_entry boot|jump|stage"

# 줄을 가르는 올바른 형식: 링에 부트로더 줄 3개와 커널 줄이 섞여 있고, 형식은 커널 줄에만 맞는다
OBW16=$(ob_rx_ws e2e_rx_mixed); printf '\\{comm=([a-z]+)\\}\n' > "$OBW16/kernel_task_regex.txt"
KERNEL_TASK_REGEX= TIMEOUT=4 TIMEOUT_PROBE=0 FAKE_RUN=30 FAKE_BANNER=0 FAKE_BARE=3 FAKE_TASK='{comm=init}' \
    ob_round "$OBW16" 1 "kernel_entry,kernel_alive"
chk "[형식 보고] 줄을 가르는 커스텀 형식은 인정하고, 어떤 형식이 판정했는지 관측 문서와 증거에 둘 다 남긴다" \
    "$(ob_jget "$OBW16/obs_1.json" "d['milestone'], d['task_regex']['custom'], d['task_regex']['pattern'], d['task_regex']['discriminates'], d['kernel_alive_evidence']['task_shape']['custom'], d['kernel_alive_evidence']['task_shape']['discriminates']")" \
    'kernel_alive True \{comm=([a-z]+)\} True True True'
chk "[형식 보고] 형식이 맞춘 줄 수 · 기본 형식이 맞춘 줄 수 · 형식만 인정한 줄의 예" \
    "$(ob_jget "$OBW16/obs_1.json" "d['task_regex']['task_lines'] > 0, d['task_regex']['total_lines'] - d['task_regex']['task_lines'], d['task_regex']['default_task_lines'], len(d['task_regex']['only_custom_examples']), '{comm=init}' in d['task_regex']['only_custom_examples'][0]")" \
    "True 3 0 3 True"
chk "[형식 보고] 증거의 note 가 커스텀 형식이 판정했다고 말한다 (기본 형식이 아니다)" \
    "$(ob_jget "$OBW16/obs_1.json" "'커스텀 태스크 형식' in d['kernel_alive_evidence']['note'], '미검증' in d['kernel_alive_evidence']['note']")" "True False"
# 링의 모든 줄에 맞는 형식은 인정은 하되 줄을 가르는지 확인되지 않았다고 적는다 (위 12h 의 OBW9)
chk "[형식 보고] 모든 줄에 맞는 커스텀 형식은 discriminates=false 와 '형식 미검증' 이 증거에 남는다" \
    "$(ob_jget "$OBW9/obs_1.json" "d['milestone'], d['task_regex']['discriminates'], d['kernel_alive_evidence']['task_shape']['discriminates'], '형식 미검증' in d['kernel_alive_evidence']['note']")" \
    "kernel_alive False False True"
# 기본 형식은 보고가 가볍다: 거절도 커스텀도 없다
OBW17=$(ob_ws e2e_rx_default); cp "$OB/plan_e2e.json" "$OBW17/memdump_plan.json"; cp "$OB/sm_e2e.json" "$OBW17/stage_map.json"
KERNEL_TASK_REGEX= TIMEOUT=4 TIMEOUT_PROBE=0 FAKE_RUN=30 ob_round "$OBW17" 1 "kernel_entry,kernel_alive"
chk "[형식 보고] 기본 형식이면 custom=false · rejected=null 이고 증거의 note 에 형식 얘기가 없다" \
    "$(ob_jget "$OBW17/obs_1.json" "d['milestone'], d['task_regex']['custom'], d['task_regex']['rejected'], d['kernel_alive_evidence']['task_shape']['custom'], '형식' in d['kernel_alive_evidence']['note']")" \
    "kernel_alive False None False False"
chk "[형식 보고] 메모리 덤프 판정이 없으면 task_regex 는 null (키는 있다)" \
    "$(ob_jget "$OBW6/obs_1.json" "'task_regex' in d, d['task_regex']")" "True None"

# 스캔 단위: 이슈의 재현. 부트로더 줄 둘 (타임스탬프 있고 태스크 없음) + 줄에 맞는 토큰
printf 'kernel_alive\tstarted\tmemdump\n' > "$OB/tok_lazy.txt"
printf '1.000000 foo started\n2.000000 bar stuff\n' > "$OB/k_lazy.log"
python3 "$MO" scan --tokens "$OB/tok_lazy.txt" --log "$OB/k_lazy.log" > "$OB/scan_lazy0.json"
KERNEL_TASK_REGEX='.' python3 "$MO" scan --tokens "$OB/tok_lazy.txt" --log "$OB/k_lazy.log" > "$OB/scan_lazy1.json" 2>/dev/null
KERNEL_TASK_REGEX='\w+' python3 "$MO" scan --tokens "$OB/tok_lazy.txt" --log "$OB/k_lazy.log" > "$OB/scan_lazy2.json" 2>/dev/null
chk "scan: 기본 형식이면 부트로더 줄만 있는 링은 kernel_alive 가 아니다 (기준)" "$(ob_jget "$OB/scan_lazy0.json" "d['reached'], d['task_lines']")" "[] 0"
chk "scan: 느슨한 형식 '.' · '\\w+' 는 같은 링에서도 kernel_alive 를 만들지 못한다 (거절되어 기본 형식으로)" \
    "$(ob_jget "$OB/scan_lazy1.json" "d['reached'], d['task_lines'], d['task_regex']['custom']") $(ob_jget "$OB/scan_lazy2.json" "d['reached'], d['task_lines'], d['task_regex']['custom']")" \
    "[] 0 False [] 0 False"
chk "scan: 거절된 형식이 보고에 남는다" "$(ob_jget "$OB/scan_lazy1.json" "d['task_regex']['rejected']['pattern']")" "."
# 줄을 가르는 형식의 보고와 모든 줄에 맞는 형식의 보고
printf '1.000000 boot stage 0 ready\n1.100000 boot stage 1 ready\n2.000000 <0>.(0){comm=init}msg a\n2.100000 <0>.(0){comm=kworker}msg b\n2.200000 <0>.(0)[1:swapper/0]msg c\n' > "$OB/k_mixed.log"
printf 'kernel_alive\tmsg\tmemdump\n' > "$OB/tok_msg.txt"
KERNEL_TASK_REGEX='\{comm=([a-z]+)\}' python3 "$MO" scan --tokens "$OB/tok_msg.txt" --log "$OB/k_mixed.log" > "$OB/scan_mixed.json"
chk "scan: 커스텀 형식 보고 — 줄 수 · 기본 형식과의 차이 · 줄을 가르는가" \
    "$(ob_jget "$OB/scan_mixed.json" "d['task_regex']['total_lines'], d['task_regex']['task_lines'], d['task_regex']['default_task_lines'], d['task_regex']['discriminates'], d['task_lines']")" "5 2 0 True 2"
chk "scan: 커스텀 형식이 인정한 줄의 예는 형식만 인정한 줄이다 (기본 형식이 맞춘 줄은 뺀다)" \
    "$(ob_jget "$OB/scan_mixed.json" "len(d['task_regex']['only_custom_examples']), all('{comm=' in x for x in d['task_regex']['only_custom_examples'])")" "2 True"
chk "scan: 증거의 task_shape 는 보고와 같은 사실" \
    "$(ob_jget "$OB/scan_mixed.json" "d['alive_evidence']['task_shape']")" \
    "{'pattern': '\\\\{comm=([a-z]+)\\\\}', 'custom': True, 'rejected': None, 'discriminates': True, 'task_lines': 2, 'total_lines': 5}"
printf '2.000000 <0>.(0){comm=init}msg a\n2.100000 <0>.(0){comm=kworker}msg b\n' > "$OB/k_allcustom.log"
KERNEL_TASK_REGEX='\{comm=([a-z]+)\}' python3 "$MO" scan --tokens "$OB/tok_msg.txt" --log "$OB/k_allcustom.log" > "$OB/scan_allc.json"
chk "scan: 모든 줄에 맞는 커스텀 형식은 인정하되 discriminates=false 와 note 에 '형식 미검증'" \
    "$(ob_jget "$OB/scan_allc.json" "d['reached'], d['task_regex']['discriminates'], '형식 미검증' in d['alive_evidence']['note']")" "['kernel_alive'] False True"

# 거절된 뒤 기본 형식이 판정해 인정하는 경우에도, 지정한 형식이 거절됐다는 사실이 증거에 남는다
KERNEL_TASK_REGEX='\w+' python3 "$MO" scan --tokens "$OB/tok.txt" --log "$OB/k_ok.log" > "$OB/scan_refused_ok.json" 2>/dev/null
chk "scan: 느슨한 형식이 거절되고 기본 형식이 kernel_alive 를 인정하면 증거가 그 사실을 말한다" \
    "$(ob_jget "$OB/scan_refused_ok.json" "'kernel_alive' in d['reached'], d['alive_evidence']['task_shape']['custom'], d['alive_evidence']['task_shape']['rejected']['pattern'], '너무 느슨해 쓰지 않음' in d['alive_evidence']['note']")" \
    'True False \w+ True'

# task-regex: 올바르면 0, 컴파일 안 되면 1, 컴파일은 되지만 너무 느슨하면 3 (그래도 출력은 한다)
OB_R=""
for v in '\{comm=([a-z]+)\}' '(' '\w+' '.' '[a-z]+ [a-z]+' 'a|bcdef' 'boot|jump|stage' 'x*' '\[\w+\]'; do
    python3 "$MO" task-regex --value "$v" >/dev/null 2>&1; OB_R="$OB_R$? "
done
chk "task-regex: 올바른 형식 0 · 깨진 형식 1 · 느슨한 형식 3 (\\w+ · . · 클래스뿐 · 가장 가난한 가지 · 태스크 없는 줄에 맞음 · 빈 일치 · 고정 글자 2개)" "$OB_R" "0 1 3 3 3 3 3 3 3 "
printf '\\w+\n' > "$OB/rx_loose.txt"
chk "task-regex: 느슨한 형식도 쓴 그대로 출력하고(호출자가 넘겨 거절이 보고되게) 이유를 stderr 에" \
    "$(python3 "$MO" task-regex --file "$OB/rx_loose.txt" 2>"$OB/rx_loose.err"; echo " rc=$?") $(grep -c '너무 느슨\|판정에 쓰지 않습니다' "$OB/rx_loose.err")" '\w+ rc=3 1'
OB_R=$(PYTHONPATH="$S" python3 - <<'PY'
import memdump_observe as m
f = lambda p: m.min_literals(m.ere_to_python(p))
print(f(r"\w+"), f("."), f("x*"), f(r"[a-z]+ [a-z]+"), f(r"\[\w+\]"), f(r"\{comm=([a-z]+)\}"), f(m.DEFAULT_TASK_REGEX))
print(f("a|bcdef"), f("abc|de"), f("(abc)?de"), f("(abc){2}"), f("abc+"), f(r"(?=abc)\w+"), f(r"<[[:digit:]]+\|([[:alpha:]_]+)>"))
print(m.assess_task_regex(m.DEFAULT_TASK_REGEX, m.re.compile(m.DEFAULT_TASK_REGEX)))
PY
)
chk "고정 글자 수: 클래스 · . · 집합 · 양화로 0 회 허용된 것은 세지 않는다" "$(echo "$OB_R" | sed -n 1p)" "0 0 0 0 2 7 3"
chk "고정 글자 수: 갈래는 가장 가난한 쪽 · 선택 묶음은 0 · 반복은 곱 · 앞내다보기는 0" "$(echo "$OB_R" | sed -n 2p)" "1 2 2 6 3 0 3"
chk "고정 글자 수: 기본 [pid:comm] 형식은 하한 안에 든다 (거절되지 않는다)" "$(echo "$OB_R" | sed -n 3p)" "[]"

# 14. 계획의 영역 → 머신의 보호 영역 문자열, 태스크 형식 파일 읽기, ERE → Python
printf '{"channel":"memdump","region_base":"0x50100000","region_size":"256K","console_size":4096}\n' > "$OB/plan_k.json"
printf '{"channel":"memdump","region_base":"0xffffffffffffff00","region_size":256}\n' > "$OB/plan_wrap.json"
printf '{"channel":"memdump","region_base":"0xfffffffffffffe00","region_size":256}\n' > "$OB/plan_edge.json"
chk "region: 계획의 영역을 <base>:<size> (0x 16진) 로" "$(python3 "$MO" region "$OB_PLAN" 2>/dev/null)" "0x50100000:0x4000"
chk "region: K/M 접미사도 16진 숫자로 풀어 준다 (머신 쪽은 C 정수만 읽는다)" "$(python3 "$MO" region "$OB/plan_k.json" 2>/dev/null)" "0x50100000:0x40000"
chk "region: 계획이 없거나 깨졌으면 실패하고 아무것도 출력하지 않는다" \
    "$(python3 "$MO" region "$OB/nope.json" 2>/dev/null; echo "rc=$?") $(python3 "$MO" region "$OB/bad_plan.json" 2>/dev/null; echo "rc=$?")" "rc=1 rc=1"
chk "region: 64비트를 넘는 영역은 머신이 거부하므로 먼저 거부 (넘기 직전은 받는다)" \
    "$(python3 "$MO" region "$OB/plan_wrap.json" >/dev/null 2>&1; echo "rc=$?") $(python3 "$MO" region "$OB/plan_edge.json" 2>/dev/null)" "rc=1 0xfffffffffffffe00:0x100"

printf '\xef\xbb\xbf\r\n   \r\n\\{comm=([a-z]+)\\}  \r\nsecond line\r\n' > "$OB/rx_crlf.txt"
chk "task-regex: BOM · 빈 줄 · 공백뿐인 줄을 건너뛰고 첫 줄을 쓴 그대로 (줄 끝 CR 만 뗀다)" \
    "$(python3 "$MO" task-regex --file "$OB/rx_crlf.txt" 2>/dev/null | od -An -c | tr -s ' ' | tr -d '\n')" \
    "$(printf '\\{comm=([a-z]+)\\}  ' | od -An -c | tr -s ' ' | tr -d '\n')"
: > "$OB/rx_empty.txt"; printf '  \n\r\n' > "$OB/rx_blank.txt"; printf '(unclosed\n' > "$OB/rx_bad.txt"
chk "task-regex: 비었거나 공백뿐이거나 컴파일되지 않거나 파일이 없으면 실패" \
    "$(for f in rx_empty rx_blank rx_bad rx_nofile; do python3 "$MO" task-regex --file "$OB/$f.txt" >/dev/null 2>&1; printf '%s ' "$?"; done)" "1 1 1 1 "
chk "task-regex: --value 도 같은 검사 (올바르면 그대로 출력)" \
    "$(python3 "$MO" task-regex --value '<[[:digit:]]+\|([[:alpha:]_]+)>' 2>/dev/null) $(python3 "$MO" task-regex --value '(' >/dev/null 2>&1; echo "rc=$?")" \
    '<[[:digit:]]+\|([[:alpha:]_]+)> rc=1'

OB_R=$(PYTHONPATH="$S" python3 - <<'PY'
import re
import memdump_observe as m
conv = m.ere_to_python
print(conv(r"[[:digit:]]+"), conv(r"[^]a]"), conv(r"[[:alpha:][:digit:]_]"), conv(r"[[]x"), conv(r"\[[[:space:]]*"))
print(re.search(conv(r"<[[:digit:]]+\|([[:alpha:]_]+)>"), "<12|worker_x>").group(1))
print(bool(re.search(conv(r"[[:punct:]]"), "a")), bool(re.search(conv(r"[[:punct:]]"), "a_")), bool(re.search(conv(r"^[[:xdigit:]]+$"), "09afAF")))
PY
)
chk "ERE → Python: POSIX 클래스만 바꾸고 나머지는 그대로 ([[:digit:]] 가 '[:digit' 집합으로 잘못 읽히지 않는다)" \
    "$(echo "$OB_R" | sed -n 1p)" '[0-9]+ [^\]a] [a-zA-Z0-9_] [\[]x \[[ \t\n\r\f\v]*'
chk "ERE → Python: 바뀐 식이 실제로 맞는다 (클래스 · 구두점 · 16진)" "$(echo "$OB_R" | sed -n 2,3p | tr '\n' ' ')" "worker_x False True True "

OB_R=$(cd "$S" && KERNEL_TASK_REGEX= python3 - <<'PY'
import memdump_observe as m
print(m.task_of("<0>.(0)[1:swapper/0]x"), m.task_of("<0>.(0){comm=init}x"), m.TASK_REGEX_CUSTOM)
PY
)
chk "태스크 형식: 환경변수가 없으면 기본 [pid:comm] 형식 (회귀)" "$OB_R" "swapper/0 None False"
OB_R=$(cd "$S" && KERNEL_TASK_REGEX='\{comm=([a-z]+)\}' python3 - <<'PY'
import memdump_observe as m
print(m.task_of("<0>.(0)[1:swapper/0]x"), m.task_of("<0>.(0){comm=init}x"), m.TASK_REGEX_CUSTOM)
PY
)
chk "태스크 형식: KERNEL_TASK_REGEX 로 바꾸면 그 형식만 본다" "$OB_R" "None init True"
OB_R=$(cd "$S" && KERNEL_TASK_REGEX='<[[:digit:]]+\|([[:alpha:]_]+)>' python3 - <<'PY' 2>/dev/null
import memdump_observe as m
print(m.task_of("<0>.(0)<12|worker_x>x"), m.task_of("<0>.(0)<12|1234>x"), m.TASK_REGEX_CUSTOM)
PY
)
chk "태스크 형식: ERE 로 쓴 POSIX 클래스가 환경변수로도 파일로도 같은 뜻으로 읽힌다" "$OB_R" "worker_x None True"
OB_R=$(cd "$S" && KERNEL_TASK_REGEX='(' python3 - <<'PY' 2>"$OB/rx_import.err"
import memdump_observe as m
print(m.task_of("<0>.(0)[1:swapper/0]x"), m.TASK_REGEX_CUSTOM)
PY
)
chk "태스크 형식: 깨진 KERNEL_TASK_REGEX 는 어느 하위 명령도 죽이지 않고, 밝히고, 기본 형식을 쓴다" \
    "$OB_R $(grep -c 'KERNEL_TASK_REGEX 정규식이 올바르지 않음' "$OB/rx_import.err")" "swapper/0 False 1"
KERNEL_TASK_REGEX='\{comm=([a-z]+)\}' python3 "$MO" scan --tokens "$OB/tok.txt" --log "$OB/k_ok.log" > "$OB/scan_rx.json"
chk "scan: 보고에 판정에 쓴 형식 (기본이면 custom=False, 바꿨으면 True)" \
    "$(ob_jget "$OB/scan_ok.json" "d['task_regex']['custom']") $(ob_jget "$OB/scan_rx.json" "d['task_regex']['custom'], 'kernel_alive' in d['reached']")" "False True False"

# 15. RESUME.md: 마지막 회차의 커널 로그 · 호스트 로그 경로 (있을 때만)
OBR="$OB/resume"; mkdir -p "$OBR/with" "$OBR/null" "$OBR/old"
printf '{"round":3,"goal":"kernel_alive","stop":true,"stop_reason":"EXHAUSTED","console":"/w/07_logs/console_3.txt","kernel_log":"/w/07_logs/kernel_3.log","host_log":"/w/07_logs/host_3.txt","channels":{"uart_bytes":10,"kernel_lines":42,"host_lines":7}}\n' > "$OBR/with/observation.json"
printf '{"round":3,"goal":"kernel_alive","stop":true,"stop_reason":"EXHAUSTED","kernel_log":null,"host_log":null}\n' > "$OBR/null/observation.json"
printf '{"round":3,"goal":"kernel_alive","stop":true,"stop_reason":"EXHAUSTED"}\n' > "$OBR/old/observation.json"
for d in with null old; do python3 "$S/make_resume.py" "$OBR/$d" >/dev/null 2>&1; done
chk "RESUME: 커널 로그 · 호스트 로그 경로와 줄 수를 근거 로그에 적는다" \
    "$(grep -c '^- 커널 로그 .*42 줄.*`/w/07_logs/kernel_3.log`$' "$OBR/with/RESUME.md") $(grep -c '^- 호스트 로그 .*게스트 증거 아님, 7 줄.*`/w/07_logs/host_3.txt`$' "$OBR/with/RESUME.md")" "1 1"
chk "RESUME: 경로가 null 이거나 키가 없으면 줄을 만들지 않는다 (없는 파일을 가리키지 않는다)" \
    "$(grep -c '커널 로그\|호스트 로그' "$OBR/null/RESUME.md") $(grep -c '커널 로그\|호스트 로그' "$OBR/old/RESUME.md")" "0 0"
chk "RESUME: 런북 단계 칸을 만들지 않는다 (가이드가 없는 기록을 주장하지 않게)" "$(grep -ci 'runbook\|런북' "$OBR/with/RESUME.md")" "0"
# 태스크 형식: 기본이 아니었던 판정은 인계 문서에 남는다 (거절된 형식 · 모든 줄에 맞은 커스텀 형식)
mkdir -p "$OBR/shape_custom" "$OBR/shape_rejected" "$OBR/shape_default" "$OBR/shape_sep"
python3 - "$OBR" <<'PY'
import json, sys
base = {"round": 3, "goal": "kernel_alive", "stop": True, "stop_reason": "EXHAUSTED"}
shapes = {
    "shape_custom": {"pattern": r"\{comm=([a-z]+)\}", "custom": True, "rejected": None, "discriminates": False},
    "shape_rejected": {"pattern": r"\[pid\]", "custom": False,
                       "rejected": {"pattern": r"\w+", "problems": ["고정 글자가 0 개뿐", "태스크가 없는 줄에도 맞음: x"]}},
    "shape_default": {"pattern": r"\[pid\]", "custom": False, "rejected": None},
    "shape_sep": {"pattern": "x", "custom": True, "rejected": None, "discriminates": True},
}
for name, shape in shapes.items():
    json.dump(dict(base, task_regex=shape), open("%s/%s/observation.json" % (sys.argv[1], name), "w"))
PY
for d in shape_custom shape_rejected shape_default shape_sep; do python3 "$S/make_resume.py" "$OBR/$d" >/dev/null 2>&1; done
chk "RESUME: 모든 줄에 맞은 커스텀 형식은 형식과 '확인되지 않음' 을 적는다" \
    "$(grep -c '^- 커널 태스크 형식: 커스텀 `\\{comm=(\[a-z\]+)\\}` 로 판정했다 (링의 모든 줄에 맞아 .*확인되지 않음)$' "$OBR/shape_custom/RESUME.md")" "1"
chk "RESUME: 거절된 형식은 무엇을 왜 거절했고 기본 형식으로 판정했다고 적는다" \
    "$(grep -c '^- 커널 태스크 형식: 지정한 `\\w+` 은 너무 느슨해 쓰지 않았고 기본 형식으로 판정했다 (고정 글자가 0 개뿐; 태스크가 없는 줄에도 맞음: x)$' "$OBR/shape_rejected/RESUME.md")" "1"
chk "RESUME: 기본 형식이거나 줄을 가른 커스텀 형식은 경고 문구 없이 형식만 (또는 아무것도) 적는다" \
    "$(grep -c '커널 태스크 형식' "$OBR/shape_default/RESUME.md") $(grep -c '확인되지 않음' "$OBR/shape_sep/RESUME.md") $(grep -c '^- 커널 태스크 형식: 커스텀 `x` 로 판정했다$' "$OBR/shape_sep/RESUME.md")" "0 0 1"

# 16. run_round.sh 의 계약: 지문이 가리키는 로그 파일이 실제로 있을 때만 경로로 싣는다
OBS_STUB="$OB/stub_scripts"; mkdir -p "$OBS_STUB"; cp -R "$S"/. "$OBS_STUB"/
cat > "$OBS_STUB/run_full.sh" <<'STUBEOF'
#!/usr/bin/env bash
wd="$1"; printf 'x\n' > "$wd/07_logs/host_9.txt"
printf '{"round":9,"console_bytes":1,"kernel_log":"%s/07_logs/kernel_9.log","host_log":"%s/07_logs/host_9.txt"}\n' "$wd" "$wd" > "$wd/fingerprint.json"
STUBEOF
OBW12=$(ob_ws e2e_stub)
bash "$OBS_STUB/run_round.sh" "$OBW12" m 9 kernel_entry kernel_entry "$OBW12/bl.bin" help shell > "$OBW12/obs_9.json" 2>/dev/null
chk "run_round: 지문이 가리키는 파일이 없으면 null (없는 파일로 보내지 않는다), 있으면 그 경로" \
    "$(ob_jget "$OBW12/obs_9.json" "d['kernel_log'], d['host_log'] == '$OBW12/07_logs/host_9.txt'")" "None True"

# ── 13. (선택) 실제 이미지 ─────────────────────────────────────────────────
# OBSERVE_REAL_DIR = 이전 실행 산출물 (ps/ 스냅샷, console.txt, kernel.log). 저장소 시험은 이것에 기대지 않는다.
if [ -n "${OBSERVE_REAL_DIR:-}" ] && [ -d "$OBSERVE_REAL_DIR/ps" ]; then
    python3 "$MO" merge --snap-dir "$OBSERVE_REAL_DIR/ps" --out "$OB/real.log" --stats "$OB/real.json" >/dev/null
    if [ -f "$OBSERVE_REAL_DIR/kernel.log" ]; then
        chk "[실제] 병합 결과가 수작업 pmerge 결과와 바이트 단위로 같다" \
            "$(cmp -s "$OB/real.log" "$OBSERVE_REAL_DIR/kernel.log" && echo same || echo differ)" "same"
    fi
    chk "[실제] 유실 의심 구간을 보고한다" "$(ob_jget "$OB/real.json" "'yes' if d['gaps']['span_s']>0 else 'no'")" "yes"
    if [ -f "$OBSERVE_REAL_DIR/console.txt" ]; then
        python3 "$MO" derive --bootloader-log "$OBSERVE_REAL_DIR/console.txt" > "$OB/real_plan.json" 2>/dev/null
        chk "[실제] 부트로더 로그에서 영역을 도출" "$(ob_jget "$OB/real_plan.json" "d['source']")" "lk_log"
        OB_CL=$(grep -m1 'Kernel command line:' "$OB/real.log" | sed 's/^[^ ]* //')
        if [ -n "$OB_CL" ]; then
            python3 "$MO" derive --cmdline "$OB_CL" > "$OB/real_plan_cl.json" 2>/dev/null
            chk "[실제] 커널 커맨드라인에서 도출한 영역이 부트로더 로그에서 도출한 것과 일치" \
                "$(ob_jget "$OB/real_plan_cl.json" "d['region_base'], d['region_size']")" \
                "$(ob_jget "$OB/real_plan.json" "d['region_base'], d['region_size']")"
        fi
    fi
fi

# 정리
if [ -n "${OB:-}" ] && [ -d "$OB" ]; then rm -rf -- "$OB"; fi
if [ -n "${PARTS_STANDALONE:-}" ] && [ -n "${ROOT:-}" ] && [ -d "$ROOT" ]; then rm -rf -- "$ROOT"; fi
parts_finish
