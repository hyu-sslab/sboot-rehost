#!/usr/bin/env bash
# tests/parts/integration.sh - 영역 사이의 계약(C1-C12)을 양쪽에서 확인한다.
#
# 각 영역의 시험은 자기 쪽만 본다. 여기서는 한쪽이 쓴 것을 다른 쪽이 실제로 읽는지,
# 그리고 통합 단계에서 맞춘 인터페이스가 이후에도 맞는지를 합성 입력으로 확인한다.
# 값(주소·오프셋)은 전부 시험용 합성값이며 어떤 기기의 것도 아니다.
#
# 사용: bash tests/parts/integration.sh      (smoke.sh 가 source 해도 된다)
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

IT="$ROOT/integration"; rm -rf "$IT"; mkdir -p "$IT"
# 가짜 QEMU: 콘솔 파일($1)을 stdout 에, 트레이스 파일($2)을 -D 로 내보낸다 (smoke.sh 의 make_qemu 와 같은 일)
it_make_qemu() {
    cat > "$BIN/fake-qemu" <<FQ
#!/usr/bin/env bash
LOG=""
while [ \$# -gt 0 ]; do
  case "\$1" in -D) LOG="\$2"; shift 2;; *) shift;; esac
done
[ -n "\$LOG" ] && cat "$2" > "\$LOG"
cat "$1"
FQ
    chmod +x "$BIN/fake-qemu"
}
it_j() {   # stdin JSON, $1 = python expression on d
    python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null
}
it_f() {   # $1 = file, $2 = expression on d
    python3 -c "import json;d=json.load(open('$1'));print($2)" 2>/dev/null
}

hdr "integration 1. C3: stage_map.py 가 쓴 지도를 읽는 쪽 셋이 같은 진입 PC 를 얻는다"
# 합성 AArch64 이미지 (스텁 둘, 암호화 없음)
python3 - "$IT/a64.bin" <<'PYGEN'
import random, struct, sys
def stub():
    return (struct.pack("<I", 0x14000001) + struct.pack("<I", 0x10000000) +
            struct.pack("<I", 0xD5384241) + struct.pack("<I", 0xD51EC000))
def plain(n):
    b = bytearray()
    while len(b) < n: b += struct.pack("<I", 0xA9BF7BFD)
    return bytes(b[:n])
open(sys.argv[1], "wb").write(stub() + plain(0x8000 - 16) + stub() + plain(0x8000 - 16))
PYGEN
python3 "$S/stage_map.py" "$IT/a64.bin" --out "$IT/sm.json" --quiet >/dev/null 2>&1
chk "stage_map.py 가 v2 지도를 씀 (stages · entry_pc · arch · origin)" \
    "$(it_f "$IT/sm.json" 'all(all(k in s for k in ("entry_pc","arch","origin","confidence","anchors","entered_by","container")) for s in d["stages"])')" "True"
# 앵커가 없는 합성 arm64 이미지는 base 를 못 내므로(그래서 entry_pc 가 null) PC 비교는 값을 채운 사본으로 한다
python3 - "$IT/sm.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["stages"]:
    if s.get("state") == "exec":
        s["base"] = {"load_base": 0x40000000}
        s["entry_pc"] = hex(0x40000000 + s["file_range"][0] + (s.get("entry_pc_file_offset") or 0))
json.dump(d, open(sys.argv[1], "w"))
PY
WATCH_V=$(python3 "$S/verify.py" "$IT" --stage-map "$IT/sm.json" --watch-list)
WATCH_T=$(python3 - "$S" "$IT/sm.json" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import trace_filter as tf
print(",".join(w["pc"] for w in tf.stage_watch(sys.argv[2])))
PY
)
chk "verify.py --watch-list 와 trace_filter.stage_watch 가 같은 목록" "$WATCH_V" "$WATCH_T"
chk "  목록이 비어 있지 않다 (예전 인라인 목록은 항상 비었다)" "$([ -n "$WATCH_V" ] && echo yes || echo no)" "yes"
# v1 지도(entry_pc 없음, base 가 dict)도 두 쪽이 같은 값을 만든다
python3 - "$IT/sm.json" "$IT/sm_v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["stages"]:
    s.pop("entry_pc", None)
    if s.get("state") == "exec":
        s["base"] = {"load_base": 0x40000000 + s["file_range"][0]}
json.dump(d, open(sys.argv[2], "w"))
PY
V1A=$(python3 "$S/verify.py" "$IT" --stage-map "$IT/sm_v1.json" --watch-list)
V1B=$(python3 - "$S" "$IT/sm_v1.json" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import trace_filter as tf
print(",".join(w["pc"] for w in tf.stage_watch(sys.argv[2])))
PY
)
chk "v1 지도에서도 두 계산이 같다 (load_base + 진입 오프셋)" "$V1A" "$V1B"

hdr "integration 2. C3: stage_map.py --merge (이미지마다 돌린 지도를 사슬 순서로 합친다)"
python3 - "$IT/b64.bin" <<'PYGEN'
import struct, sys
def stub():
    return (struct.pack("<I", 0x14000001) + struct.pack("<I", 0x10000000) +
            struct.pack("<I", 0xD5384241) + struct.pack("<I", 0xD51EC000))
b = bytearray(stub())
while len(b) < 0x4000: b += struct.pack("<I", 0xA9BF7BFD)
open(sys.argv[1], "wb").write(bytes(b))
PYGEN
python3 "$S/stage_map.py" "$IT/b64.bin" --origin medium --partition second --out "$IT/sm_b.json" --quiet >/dev/null 2>&1
python3 - "$IT/sm_b.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for s in d["stages"]:
    if s.get("state") == "exec":
        s["base"] = {"load_base": 0x48000000}
        s["entry_pc"] = hex(0x48000000 + (s.get("entry_pc_file_offset") or 0))
json.dump(d, open(sys.argv[1], "w"))
PY
python3 "$S/stage_map.py" --merge "$IT/sm.json" "$IT/sm_b.json" --out "$IT/merged.json" --quiet >/dev/null 2>&1
chk "합친 지도의 스테이지 수 = 입력의 합" \
    "$(it_f "$IT/merged.json" 'len(d["stages"])')" "$(( $(it_f "$IT/sm.json" 'len(d["stages"])') + $(it_f "$IT/sm_b.json" 'len(d["stages"])') ))"
chk "  스테이지 번호가 0 부터 이어서 매겨짐" "$(it_f "$IT/merged.json" '[s["index"] for s in d["stages"]] == list(range(len(d["stages"])))')" "True"
chk "  각 스테이지가 어느 이미지에서 왔는지 기록" "$(it_f "$IT/merged.json" 'all(s.get("image") for s in d["stages"])')" "True"
chk "  뒤 이미지의 origin/partition 이 보존됨" "$(it_f "$IT/merged.json" '(d["stages"][-1]["origin"], d["stages"][-1].get("partition"))')" "('medium', 'second')"
chk "  v1 필드가 그대로 (file_range · state · entry_pc_file_offset)" "$(it_f "$IT/merged.json" 'all(k in s for s in d["stages"] for k in ("file_range","state","entry_pc_file_offset"))')" "True"
chk "  합친 지도에서도 시험 두 쪽이 같은 PC 를 얻음" \
    "$(python3 "$S/verify.py" "$IT" --stage-map "$IT/merged.json" --watch-list | tr ',' '\n' | grep -c .)" \
    "$(it_f "$IT/merged.json" 'sum(1 for s in d["stages"] if s["state"]=="exec" and s.get("entry_pc"))')"
printf 'not json' > "$IT/bad.json"
python3 "$S/stage_map.py" --merge "$IT/sm.json" "$IT/bad.json" --out "$IT/m2.json" >/dev/null 2>&1
chk "읽을 수 없는 입력이면 종료코드 2 (파일을 쓰지 않음)" "$?:$([ -f "$IT/m2.json" ] && echo wrote || echo none)" "2:none"

hdr "integration 3. 트레이스: 진입 PC 는 '실행된 줄'로만 센다 (FAR 줄에 이름만 나온 것은 진입이 아니다)"
printf 'IN: f\n0x0000000040080000:  d53800a0  mrs x0, mpidr_el1\nTaking exception 3 [Data Abort]\n  FAR 0x0000000048200000\n0x0000000048200000:  e59f0000  ldr r0, [pc]\n' \
  | python3 "$S/trace_filter.py" --out "$IT/tf.log" --stats "$IT/tf.json" --watch 0x40080000,0x48200000
chk "느슨한 목격 (예전 의미)은 FAR 줄도 센다 — 둘 다" "$(it_f "$IT/tf.json" '[e["pc"] for e in d["stage_entries_seen"]]')" "['0x40080000', '0x48200000']"
chk "  실행 목격은 명령 줄에서만, 순서대로 (줄 번호가 FAR 줄이 아니라 뒤의 명령 줄)" "$(it_f "$IT/tf.json" '[(e["pc"], e["line"]) for e in d["stage_entries_executed"]]')" "[('0x40080000', 2), ('0x48200000', 5)]"
printf 'Taking exception 3\n  FAR 0x0000000048200000\n  ELR 0x0000000048200000\n' \
  | python3 "$S/trace_filter.py" --out "$IT/tf2.log" --stats "$IT/tf2.json" --watch 0x48200000
chk "FAR/ELR 줄에만 나온 PC 는 실행 목격이 아니다" "$(it_f "$IT/tf2.json" '(len(d["stage_entries_seen"]), len(d["stage_entries_executed"]))')" "(1, 0)"

hdr "integration 4. 말이 없는 스테이지의 진입 칸은 PC 로 인정된다 (stage_rungs.json · run_full.sh)"
RW=$(new_ws pcrung)
cat > "$RW/stage_map.json" <<'JSON'
{"schema_version": 2, "arch": "arm64", "stages": [
 {"index": 0, "name": "alpha", "state": "exec", "entry_pc": "0x40080000", "arch": "aarch64", "origin": "container",
  "file_range": [0, 4096], "base": {"load_base": 1074266112}, "entry_pc_file_offset": 0},
 {"index": 1, "name": "beta",  "state": "exec", "entry_pc": "0x48200000", "arch": "aarch64", "origin": "container",
  "file_range": [4096, 8192], "base": {"load_base": 1209008128}, "entry_pc_file_offset": 4096},
 {"index": 2, "name": "gamma", "state": "exec", "entry_pc": "0x50100000", "arch": "aarch64", "origin": "container",
  "file_range": [8192, 12288], "base": {"load_base": 1343225856}, "entry_pc_file_offset": 8192}]}
JSON
cat > "$RW/stage_rungs.json" <<'JSON'
{"schema": 1, "rungs": [
 {"rung": "alpha_entry", "stage": "alpha", "index": 0, "entry_pc": "0x40080000"},
 {"rung": "beta_entry",  "stage": "beta",  "index": 1, "entry_pc": "0x48200000"},
 {"rung": "gamma_entry", "stage": "gamma", "index": 2, "entry_pc": "0x50100000"}]}
JSON
printf 'alpha_entry\tALPHA-BANNER\n' > "$RW/milestone_tokens.txt"
printf 'x' > "$RW/bl.bin"
printf 'ALPHA-BANNER\n' > "$ROOT/it_con.txt"
# beta 는 명령 줄로 실행됨, gamma 는 FAR 줄에만 나옴
printf 'IN: f\n0x0000000048200000:  d503201f  nop\nTaking exception 3\n  FAR 0x0000000050100000\n' > "$ROOT/it_trc.txt"
it_make_qemu "$ROOT/it_con.txt" "$ROOT/it_trc.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_full.sh" "$RW" m "$RW/bl.bin" help 1 shell "alpha_entry,beta_entry,gamma_entry" >/dev/null 2>&1
chk "토큰이 있는 칸은 토큰으로, 없는 칸은 실행된 PC 로 인정" "$(it_f "$RW/fingerprint.json" 'sorted(d["milestones_reached"])')" "['alpha_entry', 'beta_entry']"
chk "  FAR 줄에만 나온 스테이지(gamma)는 인정하지 않는다" "$(it_f "$RW/fingerprint.json" '"gamma_entry" in d["milestones_reached"]')" "False"
chk "  가장 높은 칸이 마일스톤" "$(it_f "$RW/fingerprint.json" 'd["milestone"]')" "beta_entry"
# 머신 소스가 토큰을 갖고 있으면 PC 로 센 칸까지 전부 취소 (주입은 우선)
printf 'static const char *x = "ALPHA-BANNER";\n' > "$RW/06_machine/machine.c"
QEMU="$BIN/fake-qemu" bash "$S/run_full.sh" "$RW" m "$RW/bl.bin" help 2 shell "alpha_entry,beta_entry,gamma_entry" >/dev/null 2>&1
chk "출처 게이트가 걸리면 PC 로 센 칸도 인정하지 않는다" "$(it_f "$RW/fingerprint.json" '(d["milestones_reached"], d["source_gate"]["injected"])')" "([], True)"
rm -f "$RW/06_machine/machine.c"
# 첫 스테이지의 진입은 머신이 CPU 를 놓은 자리라 PC 만으로는 인정하지 않는다
printf '' > "$RW/milestone_tokens.txt"
printf 'IN: f\n0x0000000040080000:  d503201f  nop\n0x0000000048200000:  d503201f  nop\n' > "$ROOT/it_trc2.txt"
it_make_qemu "$ROOT/it_con.txt" "$ROOT/it_trc2.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_full.sh" "$RW" m "$RW/bl.bin" help 4 shell "alpha_entry,beta_entry,gamma_entry" >/dev/null 2>&1
chk "첫 스테이지(alpha)는 PC 로 인정하지 않고, 그 뒤 스테이지(beta)는 인정" "$(it_f "$RW/fingerprint.json" 'd["milestones_reached"]')" "['beta_entry']"
it_make_qemu "$ROOT/it_con.txt" "$ROOT/it_trc.txt"
# 토큰 파일에 그 칸의 줄이 이미 있으면 (문자열이 주인) PC 로는 올리지 않는다
printf 'alpha_entry\tALPHA-BANNER\nbeta_entry\tNEVER-PRINTED\n' > "$RW/milestone_tokens.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_full.sh" "$RW" m "$RW/bl.bin" help 3 shell "alpha_entry,beta_entry,gamma_entry" >/dev/null 2>&1
chk "자기 토큰이 있는 칸은 토큰이 안 보이면 PC 가 있어도 올리지 않는다" "$(it_f "$RW/fingerprint.json" 'd["milestones_reached"]')" "['alpha_entry']"

hdr "integration 5. 하니스: 표면 없음(--surface none)은 입력을 주지 않고, 입력 대기는 관측으로만 말한다"
cat > "$IT/fq_parked.py" <<'PY'
import sys, time
# 처음 한 줄을 찍고 조용해진 뒤, 수신 상태 폴링 횟수가 계속 늘어난다
sys.stdout.write("boot line\n"); sys.stdout.flush()
p = 0; t0 = time.time()
while time.time() - t0 < 30:
    p += 1000000
    sys.stderr.write("qemu-system-aarch64: info: REHOST-RX s=0 e=%d p=%d q=0\n" % (p, p)); sys.stderr.flush()
    time.sleep(0.25)
PY
cat > "$IT/fq_chatty.py" <<'PY'
import sys, time
p = 0; t0 = time.time()
while time.time() - t0 < 30:
    p += 1000000
    sys.stdout.write("still printing %d\n" % p); sys.stdout.flush()
    sys.stderr.write("REHOST-RX s=0 e=%d p=%d q=0\n" % (p, p)); sys.stderr.flush()
    time.sleep(0.25)
PY
cat > "$IT/fq_flat.py" <<'PY'
import sys, time
sys.stdout.write("boot line\n"); sys.stdout.flush()
sys.stderr.write("REHOST-RX s=0 e=1 p=1 q=0\n"); sys.stderr.flush()
time.sleep(30)
PY
cat > "$IT/fq_mute.py" <<'PY'
import sys, time
sys.stdout.write("boot line\n"); sys.stdout.flush()
time.sleep(30)
PY
hrun() {   # $1 = fake qemu, $2 = surface -> summary json path
    local out="$IT/hs_$(basename "$1" .py)_$2.json"
    python3 "$S/uart_harness.py" --console "$IT/hc.txt" --input-log "$IT/hi.txt" --summary "$out" \
        --timeout 5 --surface "$2" -- python3 "$1" >/dev/null 2>&1
    echo "$out"
}
J=$(hrun "$IT/fq_parked.py" none)
chk "표면 없음: 입력을 한 바이트도 주지 않음 (input_offered=false, bytes_sent=0)" "$(it_f "$J" '(d["input_offered"], d["bytes_sent"], d["supply_attempts"])')" "(False, 0, 0)"
chk "  굶음(input_starved)도 false — 준 것이 없으니 못 읽었다고 말할 수 없다" "$(it_f "$J" 'd["input_starved"]')" "False"
chk "  조용해진 뒤 폴링이 계속 늘면 waiting_for_input=true" "$(it_f "$J" 'd["waiting_for_input"]')" "True"
J=$(hrun "$IT/fq_chatty.py" none)
chk "콘솔이 계속 움직이면 폴링이 늘어도 waiting_for_input=false" "$(it_f "$J" 'd["waiting_for_input"]')" "False"
J=$(hrun "$IT/fq_flat.py" none)
chk "폴링 횟수가 늘지 않으면 waiting_for_input=false" "$(it_f "$J" 'd["waiting_for_input"]')" "False"
J=$(hrun "$IT/fq_mute.py" none)
chk "머신이 RX 를 보고하지 않으면 null (모른다는 것은 아니라는 뜻이 아니다)" "$(it_f "$J" 'd["waiting_for_input"]')" "None"
# CC4: 표면이 있어도 도출된 게이트(input_plan.json)가 없으면 인터럽트 패턴을 보내지 않는다 (예전의 CR 세 번 기본값은 없다).
# 파이프라인이 분석가에게 "파일을 쓰지 못하면 쓰지 말라, 하니스는 아무 패턴도 보내지 않고 출처를 absent 로 기록한다"고 말하는 것과 같은 계약이다.
J=$(hrun "$IT/fq_parked.py" shell)
chk "표면이 있어도 입력 계획이 없으면 패턴을 주지 않는다 — 출처 absent, 이유가 남는다 (기본값 없음)" \
    "$(it_f "$J" '(d["input_offered"], d["bytes_sent"], d["source"], d.get("plan_note"))')" "(False, 0, 'absent', 'no input_plan.json')"
printf '{"autoboot_interrupt": {"bytes": "\\r", "count": 3}}\n' > "$IT/hplan.json"
python3 "$S/uart_harness.py" --console "$IT/hc.txt" --input-log "$IT/hi.txt" --summary "$IT/hs_plan.json" --plan "$IT/hplan.json" \
    --timeout 5 --surface shell -- python3 "$IT/fq_parked.py" >/dev/null 2>&1
chk "  도출된 입력 계획이 있으면 그 패턴을 준다 (출처 derived)" \
    "$(it_f "$IT/hs_plan.json" '(d["input_offered"], d["source"], d["count"])')" "(True, 'derived', 3)"
# run_full.sh → fingerprint.json → run_round.sh → observation.json 로 그대로 흐른다
RP=$(new_ws parked); printf 'x' > "$RP/bl.bin"
cat > "$BIN/fake-qemu-parked" <<EOF
#!/usr/bin/env bash
exec python3 "$IT/fq_parked.py"
EOF
chmod +x "$BIN/fake-qemu-parked"
TIMEOUT=5 TIMEOUT_PROBE=0 QEMU="$BIN/fake-qemu-parked" bash "$S/run_round.sh" "$RP" m 1 autoboot "autoboot" "$RP/bl.bin" help none > "$IT/obs_parked.json" 2>/dev/null
chk "observation.json 의 waiting_for_input 이 하니스 판정 그대로" "$(it_f "$IT/obs_parked.json" '(d["waiting_for_input"], d["input_offered"], d["input_starved"], d["rx_reported"])')" "(True, False, False, True)"

hdr "integration 6. C12: observation.json 의 새 키를 파이프라인 스키마가 안다"
chk "run_round.sh 가 쓰는 C12 키 (channels · kernel_alive_evidence · guest_reset_signal)" \
    "$(it_f "$IT/obs_parked.json" 'all(k in d for k in ("channels","kernel_alive_evidence","guest_reset_signal","waiting_for_input"))')" "True"
chk "run_round.sh 가 쓰는 K3 키 (kernel_log · host_log: 경로 문자열 또는 null)" \
    "$(it_f "$IT/obs_parked.json" 'all(k in d and (d[k] is None or isinstance(d[k], str)) for k in ("kernel_log","host_log"))')" "True"
PY_SCHEMA=$(python3 - "$REPO/workflows/pipeline.js" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"const RUN_SCHEMA = \{(.*?)\n\}\n", s, re.S)
print(" ".join(sorted(set(re.findall(r"^\s{4}([a-z_]+):", m.group(1), re.M)))))
PY
)
for k in channels kernel_alive_evidence guest_reset_signal waiting_for_input kernel_last_time kernel_uniq kernel_moving early_exit kernel_log host_log; do
    case " $PY_SCHEMA " in *" $k "*) ok "RUN_SCHEMA 에 $k" ;; *) bad "RUN_SCHEMA 에 $k" "파이프라인 스키마에 없음" ;; esac
done
chk "RUN_SCHEMA 의 모든 키를 run_round.sh 가 쓴다 (없는 키를 기다리지 않는다)" \
    "$(python3 - "$IT/obs_parked.json" "$PY_SCHEMA" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
missing = [k for k in sys.argv[2].split() if k not in d and k not in ("type", "properties", "required")]
print("ok" if not missing else missing)
PY
)" "ok"

hdr "integration 7. C2: 같은 milestone_tokens.txt 를 세 쪽이 같게 읽는다 (세 번째 열 = 채널)"
printf 'shell\tS-BOOT #\nkernel_entry\tStarting kernel\tuart\nkernel_alive\tLinux version\tmemdump\nverify_ok\tverify ok\r\nbare line for the surface\n' > "$IT/tokens.txt"
mkdir -p "$IT/tokws"; cp "$IT/tokens.txt" "$IT/tokws/milestone_tokens.txt"
chk "verify.py milestone_token" \
    "$(python3 - "$S" "$IT/tokws" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import verify
w = sys.argv[2]
print([verify.milestone_token(w, n) for n in ("shell", "kernel_entry", "kernel_alive")])
PY
)" "[('S-BOOT #', 'uart'), ('Starting kernel', 'uart'), ('Linux version', 'memdump')]"
chk "memdump_observe.py read_tokens (같은 파일)" \
    "$(python3 - "$S" "$IT/tokws/milestone_tokens.txt" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import memdump_observe as mo
rows = mo.read_tokens(sys.argv[2])
print([(m, t, c) for (m, t, c) in rows if m in ("shell", "kernel_entry", "kernel_alive")])
PY
)" "[('shell', 'S-BOOT #', 'uart'), ('kernel_entry', 'Starting kernel', 'uart'), ('kernel_alive', 'Linux version', 'memdump')]"
printf 'Starting kernel\nS-BOOT # \n' > "$ROOT/it_c2.txt"; : > "$ROOT/it_c2t.txt"
C2=$(new_ws c2); printf 'x' > "$C2/bl.bin"; cp "$IT/tokens.txt" "$C2/milestone_tokens.txt"
it_make_qemu "$ROOT/it_c2.txt" "$ROOT/it_c2t.txt"
QEMU="$BIN/fake-qemu" bash "$S/run_full.sh" "$C2" m "$C2/bl.bin" help 1 shell "shell,kernel_entry,kernel_alive" >/dev/null 2>&1
chk "run_full.sh: uart 열은 콘솔에서, memdump 열은 콘솔로 인정하지 않는다" "$(it_f "$C2/fingerprint.json" 'sorted(d["milestones_reached"])')" "['kernel_entry', 'shell']"

hdr "integration 8. C4: memdump_plan.json — 쓰는 쪽(derive)과 읽는 세 쪽(check-plan · 보호 영역 · 합친 로그)"
printf '[LK] pstore_addr:0x5000, pstore_size:0x4000, pstore_console_size:0x800\nqemu-system-aarch64: info: rehost: pstore addr:0x9000, size:0x100, pstore_console_size:0x10\n' > "$IT/lk.txt"
python3 "$S/memdump_observe.py" derive --bootloader-log "$IT/lk.txt" --out "$IT/memdump_plan.json" >/dev/null 2>&1
chk "derive: 호스트 줄은 후보가 아니다 (우리 줄이 영역을 지목해도 충돌로 끝나지 않음)" "$(it_f "$IT/memdump_plan.json" '(d["region_base"], d["region_size"], d["console_size"], d["source"])')" "('0x5000', 16384, 2048, 'lk_log')"
chk "check-plan 이 그 파일을 받아들임" "$(python3 "$S/memdump_observe.py" check-plan "$IT/memdump_plan.json" >/dev/null 2>&1; echo $?)" "0"
chk "verify_gates 가 같은 파일에서 보호 영역을 읽음" "$(python3 -c "
import sys; sys.path.insert(0,'$S')
import verify_gates as vg
print(vg.plan_ranges('$IT'))")" "[(20480, 16384)]"
chk "C4 필수 키가 모두 있다" "$(it_f "$IT/memdump_plan.json" 'all(k in d for k in ("channel","region_base","region_size","console_size","source","evidence"))')" "True"

hdr "integration 9. 게이트 1 ↔ 템플릿: 채운 템플릿이 게이트 1·3 을 통과한다 (UART 출력 경로 1, 수신 주입 없음)"
TW="$IT/tpl"; mkdir -p "$TW/06_machine" "$TW/07_logs" "$TW/03_bootloader"
head -c 4096 /dev/urandom > "$TW/03_bootloader/fw.bin"
printf '### #1 x\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$TW/06_machine/bypasses.md"
printf 'boot ok\n' > "$TW/07_logs/console_1.txt"
# 합성 자리표시자 값(0x1000 의 배수)과 겹치지 않는 보호 영역
printf '{"channel":"memdump","region_base":"0x7f000000","region_size":1048576,"console_size":65536,"source":"cmdline","evidence":"fixture"}\n' > "$TW/memdump_plan.json"
it_fill() {   # $1 = 템플릿, $2 = 출력 — 코드 자리의 자리표시자만 합성값으로 채운다
    python3 - "$1" "$2" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
code = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
vals, i = {}, 0
for n in sorted(set(re.findall(r'\{\{([A-Z0-9_]+)\}\}', code))):
    if n in ('MODEL', 'MODEL_LOWER'): vals[n] = 'dummy'
    elif n.startswith('CPU') and n.endswith('TYPE'): vals[n] = 'cortex-a55'
    elif '_HAS_' in n or n.startswith('HAS_'): vals[n] = 'true'
    elif n == 'SMP': vals[n] = '1'
    elif n == 'GIC_REVISION': vals[n] = '3'
    elif n == 'GIC_NUM_IRQ': vals[n] = '288'
    elif n == 'HANDOFF_COPY_REGS': vals[n] = '4'
    elif n.endswith('_HZ'): vals[n] = '13000000'
    elif n.endswith('_STR') or n.endswith('_NAME'): vals[n] = 'dummy'
    else:
        i += 1; vals[n] = str(0x1000 * i)
for n, v in vals.items(): s = s.replace('{{%s}}' % n, v)
open(sys.argv[2], 'w').write(s)
PY
}
for tpl in machine_mixed_arch machine_full; do
    rm -f "$TW/06_machine"/*.c
    it_fill "$REPO/templates/$tpl.c.tmpl" "$TW/06_machine/machine_full.c"
    [ "$tpl" = machine_full ] && it_fill "$REPO/templates/storage_hci.c.tmpl" "$TW/06_machine/storage_hci.c"
    J=$(python3 "$S/verify.py" "$TW" --target F2 --container "$TW/03_bootloader/fw.bin" --round 1 2>/dev/null)
    chk "$tpl: 게이트 1 (소스 negative · UART 경로 1) 통과" "$(echo "$J" | it_j 'd["items"][0]["pass"]')" "True"
    chk "$tpl: 게이트 3 (입력 출처) 통과" "$(echo "$J" | it_j 'd["items"][2]["pass"]')" "True"
done
rm -f "$TW/06_machine"/*.c
it_fill "$REPO/templates/machine_mixed_arch.c.tmpl" "$TW/06_machine/machine_full.c"
J=$(python3 "$S/verify.py" "$TW" --target F2 --container "$TW/03_bootloader/fw.bin" --round 1 2>/dev/null)
chk "메모리 덤프 계획이 있으면 게이트 1 이 게스트 메모리 쓰기 위치를 알려준다 (통과를 막지 않음)" \
    "$(echo "$J" | it_j '("게스트 메모리에 쓰는 호출" in d["items"][0]["evidence"], d["items"][0]["pass"])')" "(True, True)"
rm -f "$TW/memdump_plan.json"
J=$(python3 "$S/verify.py" "$TW" --target F2 --container "$TW/03_bootloader/fw.bin" --round 1 2>/dev/null)
chk "  계획이 없으면 그 안내는 붙지 않는다" "$(echo "$J" | it_j '"게스트 메모리에 쓰는 호출" in d["items"][0]["evidence"]')" "False"
chk "템플릿이 RX 보고(REHOST-RX)를 stderr 로 낸다 — 하니스 정규식이 읽는 형식" \
    "$(python3 - "$S" "$REPO/templates/machine_mixed_arch.c.tmpl" <<'PY'
import re, sys
sys.path.insert(0, sys.argv[1])
import uart_harness as uh
src = open(sys.argv[2]).read()
at = src.index('info_report("REHOST-RX')
stmt = src[at:src.index(';', at)]
fmt = ''.join(re.findall(r'"([^"]*)"', stmt)).replace('%u', '3').replace('%', '7')
print(bool(uh.RX_REPORT.search(fmt)), fmt)
PY
)" "True REHOST-RX s=7 e=7 p=7 q=3"

hdr "integration 10. C7: 템플릿의 우회 행 태그 · 장부 (check_change.sh 가 같은 규칙으로 읽는다)"
LW="$IT/ledger"; mkdir -p "$LW/06_machine" "$LW/08_docs/.record/pre"
printf '/* bypass:7 */\nint a;\n' > "$LW/06_machine/m.c"; cp "$LW/06_machine/m.c" "$LW/08_docs/.record/pre/m.c"
printf '### #7 첫째\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: 비어 있지 않은 설명\n- 메타: 종류=P; 표지=F; 출처=A; 도출=semi\n' > "$LW/06_machine/bypasses.md"
printf '/* bypass:7 */\nint b;\n' > "$LW/06_machine/m.c"
OUT=$(bash "$S/check_change.sh" "$LW" verify 2>/dev/null); RC=$?
chk "태그가 장부의 #id 와 일치하면 통과 (종료 0)" "$RC:$(echo "$OUT" | it_j 'd["pass"]')" "0:True"
# 부작용이 비었거나 '(기록 없음)' 이면 종료 2 로 거절하는 경우는 tests/parts/verify_gates.sh 의 7 절이 이미 단언한다 (같은 단언을 두 번 두지 않는다).

hdr "integration 10b. 일반 fixer 범위 — 한 파일·hunk 상한만 면제하고 우회 기록 검사는 그대로 건다 (CHANGE_SCOPE=general)"
# 마지막 수단 fixer 는 전문가가 아직 없는 정지점의 공백을 메운다: 한 원인이 여러 파일·여러 곳에 걸칠 수 있다.
GW="$IT/scope"; mkdir -p "$GW/06_machine"
for f in a b; do seq 1 30 | sed 's/^/int v/;s/$/;/' > "$GW/06_machine/$f.c"; done
printf '### #1 기준\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: 비어 있지 않은 설명\n' > "$GW/06_machine/bypasses.md"
bash "$S/check_change.sh" "$GW" snapshot >/dev/null 2>&1
# a.c 네 곳(1, 9, 17, 25행)과 b.c 한 곳 — 파일 2개, hunk 5개
sed -e '1s/.*/int X1;/' -e '9s/.*/int X9;/' -e '17s/.*/int X17;/' -e '25s/.*/int X25;/' "$GW/06_machine/a.c" > "$GW/a.new" && mv "$GW/a.new" "$GW/06_machine/a.c"
sed -e '5s/.*/int Y5;/' "$GW/06_machine/b.c" > "$GW/b.new" && mv "$GW/b.new" "$GW/06_machine/b.c"
OUT=$(bash "$S/check_change.sh" "$GW" verify 2>/dev/null); RC=$?
chk "전문가 범위: 소스 둘 · hunk 다섯은 반려 (종료 2, scope=specialist)" "$RC:$(echo "$OUT" | it_j 'd["pass"]'):$(echo "$OUT" | it_j 'd["scope"]')" "2:False:specialist"
chk "... 사유가 한 회차 한 변경 위반이다" "$(echo "$OUT" | it_j '"한 회차 한 변경" in d["reason"]')" "True"
OUT=$(CHANGE_SCOPE=general bash "$S/check_change.sh" "$GW" verify 2>/dev/null); RC=$?
chk "일반 범위: 같은 변경이 통과 (종료 0, scope=general, 파일 2, hunk 4 이상)" "$RC:$(echo "$OUT" | it_j 'd["pass"]'):$(echo "$OUT" | it_j 'd["scope"]'):$(echo "$OUT" | it_j 'd["changed_files"]'):$(echo "$OUT" | it_j 'd["total_hunks"]>=4')" "0:True:general:2:True"
OUT=$(CHANGE_SCOPE=other bash "$S/check_change.sh" "$GW" verify 2>/dev/null); RC=$?
chk "알 수 없는 범위 값은 전문가 범위다 (면제가 새지 않는다)" "$RC:$(echo "$OUT" | it_j 'd["scope"]')" "2:specialist"
# 면제는 두 검사뿐이다: 새 우회 기록의 부작용이 비면 일반 범위도 반려한다
printf '### #2 둘째\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: (기록 없음)\n' >> "$GW/06_machine/bypasses.md"
OUT=$(CHANGE_SCOPE=general bash "$S/check_change.sh" "$GW" verify 2>/dev/null); RC=$?
chk "일반 범위도 우회 기록 검사는 그대로: 부작용 (기록 없음) 은 반려 (종료 2)" "$RC:$(echo "$OUT" | it_j 'd["pass"]')" "2:False"
# 네 항목 검사도 면제되지 않는다. 글자(스크립트의 철자)가 아니라 동작으로 묶는다: 일반 범위에서 이 검사를 건너뛰는
# 어떤 철자의 변경이든 아래 넷 중 하나가 통과해 버린다. 새 기록 #2 가 네 항목을 다 갖추면 통과(대조군)하고,
# 하나라도 빠지면 반려한다. 소스 변경(파일 2 · hunk 5)은 위와 그대로라서 면제된 검사는 이 반려의 원인이 될 수 없다.
for miss in none 대상 이유 방법 부작용; do
    printf '### #1 기준\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: 비어 있지 않은 설명\n' > "$GW/06_machine/bypasses.md"
    {
        printf '### #2 둘째\n'
        for f in 대상 이유 방법 부작용; do
            [ "$f" = "$miss" ] || printf -- '- %s: 비어 있지 않은 설명\n' "$f"
        done
    } >> "$GW/06_machine/bypasses.md"
    OUT=$(CHANGE_SCOPE=general bash "$S/check_change.sh" "$GW" verify 2>/dev/null); RC=$?
    if [ "$miss" = none ]; then
        chk "일반 범위: 새 기록이 네 항목을 다 갖추면 통과 (종료 0, scope=general, bypass_ok=true) — 아래 반려의 대조군" \
            "$RC:$(echo "$OUT" | it_j 'd["pass"]'):$(echo "$OUT" | it_j 'd["scope"]'):$(echo "$OUT" | it_j 'd["bypass_ok"]')" "0:True:general:True"
    else
        chk "일반 범위도 새 기록에서 '$miss' 항목이 빠지면 반려 (종료 2, bypass_ok=false, 사유가 4 항목)" \
            "$RC:$(echo "$OUT" | it_j 'd["pass"]'):$(echo "$OUT" | it_j 'd["scope"]'):$(echo "$OUT" | it_j 'd["bypass_ok"]'):$(echo "$OUT" | it_j '"4 항목" in d["reason"]')" \
            "2:False:general:False:True"
    fi
done
# 변경이 아예 없으면 일반 범위도 반려한다
bash "$S/check_change.sh" "$GW" restore >/dev/null 2>&1
OUT=$(CHANGE_SCOPE=general bash "$S/check_change.sh" "$GW" verify 2>/dev/null); RC=$?
chk "일반 범위도 변경이 없으면 반려 (종료 2)" "$RC:$(echo "$OUT" | it_j 'd["pass"]')" "2:False"

hdr "integration 11. C5: sync_machine.sh — 워크스페이스를 따라 qemu_targets.txt 가 정리되고, machine_full.c 가 hw/arm/<기계>.c 로 간다"
SW="$IT/sync"; QT="$IT/qtree"; mkdir -p "$SW/06_machine" "$QT/hw/arm"
printf 'int old;\n' > "$QT/hw/arm/my_machine.c"
printf 'int full;\n' > "$SW/06_machine/machine_full.c"
J=$(QEMU_ROOT="$QT" bash "$S/sync_machine.sh" "$SW" my-machine 2>/dev/null); RC=$?
chk "machine_full.c 가 hw/arm/my_machine.c 로 매핑됨 (Build 가 그 이름으로 복사하라고 한다)" "$RC:$(cat "$QT/hw/arm/my_machine.c")" "0:int full;"
chk "  매핑이 qemu_targets.txt 에 남음" "$(cut -f1 "$SW/06_machine/qemu_targets.txt")" "machine_full.c"
printf 'machine_old.c\t%s\nbroken-line-without-tab\n' "$QT/hw/arm/old.c" >> "$SW/06_machine/qemu_targets.txt"
QEMU_ROOT="$QT" bash "$S/sync_machine.sh" "$SW" my-machine >/dev/null 2>&1
chk "워크스페이스에 없는 소스의 줄은 빠진다 (verify 가 '빌드된 소스 목록'으로 읽는다)" "$(cut -f1 "$SW/06_machine/qemu_targets.txt" | tr '\n' ' ')" "machine_full.c broken-line-without-tab "
chk "  남은 소스는 그대로 매핑" "$(grep -c '^machine_full.c' "$SW/06_machine/qemu_targets.txt")" "1"

hdr "integration 12. C11: build_lu.py 가 쓴 출처 기록을 verify 가 읽는다 · detect_medium.py"
MW="$IT/med"; mkdir -p "$MW/fw" "$MW/06_machine" "$MW/07_logs" "$MW/03_bootloader"
head -c 8192 /dev/urandom > "$MW/fw/boot.img"; printf 'AVBf' > "$MW/fw/forged.bin"
python3 - "$MW" <<'PY'
import json, sys
json.dump({"medium": "emmc", "partitions": [
    {"name": "boot", "source": "fw/boot.img"},
    {"name": "vbmeta", "kind": "forged", "source": "fw/forged.bin"},
    {"name": "scratch", "kind": "zero", "size": 65536}]}, open(sys.argv[1] + "/lu_manifest.json", "w"))
PY
python3 "$S/build_lu.py" "$MW" --out "$MW/fw/lu0.img" >/dev/null 2>&1
chk "build_lu.py 가 lu_provenance.json 을 이미지 옆에 씀" "$([ -f "$MW/fw/lu_provenance.json" ] && echo yes)" "yes"
chk "verify_gates.load_medium_kinds 가 그 파일의 kind 를 읽음" \
    "$(python3 - "$S" "$MW" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import verify_gates as vg
k = vg.load_medium_kinds(sys.argv[2])
print({n: v["kind"] for n, v in sorted(k.items())})
PY
)" "{'boot': 'firmware', 'scratch': 'zero', 'vbmeta': 'forged'}"
chk "합성 매체 이미지(lu0.img)와 위조 원본은 게이트 2 의 참조 집합에서 빠진다" \
    "$(python3 - "$S" "$MW" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import verify_gates as vg
bs = vg.reference_images(sys.argv[2])
try:
    print(sorted(bs.names), sorted(x["file"] for x in bs.excluded))
finally:
    bs.close()
PY
)" "['boot.img'] ['forged.bin', 'lu0.img']"
printf 'verify ok\n' > "$MW/07_logs/console_1.txt"; printf 'x' > "$MW/06_machine/m.c"
printf '### #1 x\n- 대상: t\n- 이유: r\n- 방법: m\n- 부작용: s\n' > "$MW/06_machine/bypasses.md"
J=$(python3 "$S/verify.py" "$MW" --target F2 --container "$MW/fw/boot.img" --round 1 2>/dev/null)
chk "verify_bypass 가 위조 파티션을 센다 (AVB 푸터 확인 포함)" "$(echo "$J" | it_j '[(s["id"], s["count"]) for s in d["verify_bypass"]["signals"] if s["id"]=="forged_media"]')" "[('forged_media', 1)]"
printf '[SD0] Initialized, eMMC45\n' > "$IT/blog.txt"
chk "detect_medium.py 의 JSON 키 (hci_kind · evidence) — build_lu 의 --medium 값과 같은 어휘" \
    "$(python3 "$S/detect_medium.py" --bootloader-log "$IT/blog.txt" | it_j '(d["hci_kind"], isinstance(d["evidence"], list), d["hci_kind"] in ("emmc","ufs","unknown"))')" "('emmc', True, True)"

hdr "integration 13. verify.py: --surface none · 상태 토큰은 도출 파일에서만 (스크립트에 벤더 문자열 없음)"
J=$(python3 "$S/verify.py" "$MW" --target F2 --container "$MW/fw/boot.img" --round 1 --surface none 2>/dev/null); RC=$?
chk "--surface none 을 받아들이고 판정을 낸다" "$RC:$(echo "$J" | it_j '"verdict" in d')" "0:True"
chk "  입력 항목이 명령 토큰 없이도 계산된다 (게이트 3 이 통과/불통과로 나옴)" "$(echo "$J" | it_j 'isinstance(d["items"][2]["pass"], bool)')" "True"

hdr "integration 14. carve_check: 컨테이너 헤더가 선언한 크기만큼 있으면 부분 추출이 아니다"
python3 - "$IT" <<'PYGEN'
import struct, sys
d = sys.argv[1]
# MTK 꼴 헤더: 매직 · 페이로드 크기 · 이름 · 확장 헤더(0x30 매직, 0x34 헤더 크기)
def mtk(total, payload):
    b = bytearray(total)
    struct.pack_into("<I", b, 0, 0x58881688)
    struct.pack_into("<I", b, 4, payload)
    b[8:8 + 4] = b"unit"
    struct.pack_into("<I", b, 0x30, 0x58891689)
    struct.pack_into("<I", b, 0x34, 0x200)
    b[0x200:0x204] = struct.pack("<I", 0xEA000000)
    return bytes(b)
open(d + "/hdr_full.img", "wb").write(mtk(0x20000, 0x10000))
open(d + "/hdr_cut.img", "wb").write(mtk(0x8000, 0x10000))
PYGEN
if python3 -c "import capstone" >/dev/null 2>&1; then
CF=$(python3 "$S/carve_disasm.py" --arch arm32 carve_check "$IT/hdr_full.img" 2>/dev/null)
chk "토큰이 하나도 없어도 헤더가 선언한 만큼 있으면 is_full (근거 = 컨테이너 헤더)" \
    "$(echo "$CF" | sed -n 's/^is_full: //p'):$(echo "$CF" | sed -n 's/^is_full_basis: //p')" "True:컨테이너 헤더"
CF=$(python3 "$S/carve_disasm.py" --arch arm32 carve_check "$IT/hdr_cut.img" 2>/dev/null)
chk "헤더가 선언한 것보다 파일이 짧으면 carve 의심 (False)" "$(echo "$CF" | sed -n 's/^is_full: //p')" "False"
printf 'plain bytes with no header at all\n' > "$IT/nohdr.bin"
CF=$(python3 "$S/carve_disasm.py" --arch arm32 carve_check "$IT/nohdr.bin" 2>/dev/null)
chk "헤더가 없는 이미지는 예전 문자열 기준 그대로 (False)" "$(echo "$CF" | sed -n 's/^is_full: //p')" "False"
else
    ok "SKIP carve_check 시험 (capstone 미설치 - carve_disasm.py 는 capstone 이 필요합니다)"
fi

hdr "integration 15. 구문 검사 (이번 통합이 건드린 파일)"
bash -n "$S/run_full.sh" "$S/run_round.sh" "$S/sync_machine.sh" "$REPO/tests/parts/_lib.sh" && ok "구문 검사 (run_full.sh run_round.sh sync_machine.sh _lib.sh)" || bad "구문 검사 (shell)"
( cd "$S" && PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import ast, sys
for f in ("uart_harness.py", "trace_filter.py", "stage_map.py", "carve_disasm.py", "verify.py",
          "verify_gates.py", "memdump_observe.py"):
    ast.parse(open(f, encoding="utf-8").read(), f)
PY
) && ok "구문 검사 (python)" || bad "구문 검사 (python)"

hdr "integration 16. 시험이 사용자의 트레이스 폴더(~/rehost/_traces)를 건드리지 않는다"
# run_full.sh 는 TRACE_DIR 이 없으면 $HOME/rehost/_traces 에 쓰고 옛 run_*.log 를 지운다 (TRACE_KEEP).
# 단독 실행되는 부분 시험이 그 값을 받지 못하면 사용자의 실제 트레이스가 지워진다.
# HOME 을 임시 폴더로 돌려 두고 단독 실행 부분 하나를 실제로 돌려서 본다 (실제 홈은 읽지 않는다).
TH="$IT/home"; rm -rf "$TH"; mkdir -p "$TH/rehost/_traces"
for _n in 100 101 102 103 104 105 106 107 108 109 110 111 112 113 114; do
    printf 'user trace %s\n' "$_n" > "$TH/rehost/_traces/run_$_n.log"
done
TH_BEFORE=$(ls -1 "$TH/rehost/_traces" | tr '\n' ' ')
cat > "$IT/probe_part.sh" <<'PROBE'
#!/usr/bin/env bash
. "${PROBE_LIB:-$REPO/tests/parts/_lib.sh}"
PW=$(new_ws probe); printf 'x' > "$PW/bl.bin"
QEMU="$PROBE_QEMU" bash "$S/run_full.sh" "$PW" m "$PW/bl.bin" help 1 shell shell >/dev/null 2>&1
printf 'TRACE_DIR=%s\n' "${TRACE_DIR:-<unset>}"
parts_finish
PROBE
it_make_qemu "$ROOT/it_con.txt" "$ROOT/it_trc.txt"
env -u TRACE_DIR HOME="$TH" ROOT="$IT/probe_root" REPO="$REPO" PROBE_QEMU="$BIN/fake-qemu" \
    bash "$IT/probe_part.sh" > "$IT/probe_out.txt" 2>&1
chk "단독 실행(TRACE_DIR 없음): 사용자의 트레이스 폴더가 그대로다 (새 파일도 없고 지워진 것도 없다)" \
    "$(ls -1 "$TH/rehost/_traces" | tr '\n' ' ')" "$TH_BEFORE"
chk "  실행은 실제로 돌았고 트레이스는 시험 폴더로 갔다" "$([ -f "$IT/probe_root/_traces/run_1.log" ] && echo yes || echo no)" "yes"
rm -rf "$IT/probe_root"
env HOME="$TH" TRACE_DIR="$TH/rehost/_traces" ROOT="$IT/probe_root" REPO="$REPO" PROBE_QEMU="$BIN/fake-qemu" \
    bash "$IT/probe_part.sh" > "$IT/probe_out.txt" 2>&1
chk "  호출자가 TRACE_DIR 을 실제 폴더로 줘도 시험 폴더로 돌린다 (상속값을 쓰지 않는다)" \
    "$(ls -1 "$TH/rehost/_traces" | tr '\n' ' '):$(grep -c "^TRACE_DIR=$IT/probe_root/_traces$" "$IT/probe_out.txt")" "$TH_BEFORE:1"
# smoke.sh 처럼 source 되는 경우: chk 가 이미 정의되어 있으면 부모가 정한 값을 존중하되 실제 폴더는 거절
SRC_LIB="$REPO/tests/parts/_lib.sh"
SRC_OUT=$(env HOME="$TH" TRACE_DIR="$TH/rehost/_traces" ROOT="$IT/src_root" \
    bash -c 'chk() { :; }; . "$1"; echo reached' _ "$SRC_LIB" 2>&1); SRC_RC=$?
chk "source 된 경우: TRACE_DIR 이 실제 폴더 안이면 거절 (종료 2, 이후 시험이 돌지 않는다)" \
    "$SRC_RC:$(echo "$SRC_OUT" | grep -c '^reached$')" "2:0"
SRC_OUT=$(env HOME="$TH" TRACE_DIR="$TH/rehost/_traces/../_traces/." ROOT="$IT/src_root" \
    bash -c 'chk() { :; }; . "$1"; echo reached' _ "$SRC_LIB" 2>&1); SRC_RC=$?
chk "  경로를 돌려 써도 같다 (실제 경로로 비교)" "$SRC_RC:$(echo "$SRC_OUT" | grep -c '^reached$')" "2:0"
SRC_OUT=$(env -u TRACE_DIR HOME="$TH" ROOT="$IT/src_root" \
    bash -c 'chk() { :; }; . "$1"; echo "TD=$TRACE_DIR"' _ "$SRC_LIB" 2>&1); SRC_RC=$?
chk "  값이 없으면 부모의 ROOT 안으로 정한다 (~/rehost 로 가지 않는다)" "$SRC_RC:$SRC_OUT" "0:TD=$IT/src_root/_traces"
SRC_OUT=$(env HOME="$TH" TRACE_DIR="$IT/elsewhere/_traces" ROOT="$IT/src_root" \
    bash -c 'chk() { :; }; . "$1"; echo "TD=$TRACE_DIR"' _ "$SRC_LIB" 2>&1); SRC_RC=$?
chk "  부모가 시험용 폴더를 정했으면 그대로 쓴다 (smoke.sh 의 경우)" "$SRC_RC:$SRC_OUT" "0:TD=$IT/elsewhere/_traces"
chk "  거절한 뒤에도 사용자의 폴더는 그대로" "$(ls -1 "$TH/rehost/_traces" | tr '\n' ' ')" "$TH_BEFORE"
rm -rf "$TH" "$IT/probe_root" "$IT/src_root" "$IT/probe_part.sh" "$IT/probe_out.txt"

hdr "integration 17. pipeline.js 와 상대 영역의 계약: K1 detect-arch · K5 정규식 파일 · K6 담당 열 · K8 자산 적재"
PJS="$REPO/workflows/pipeline.js"
# K1: 파이프라인이 읽는 키와 stage_map.py --detect-arch 가 실제로 내는 것
K1=$(python3 - "$S" "$IT" "$PJS" <<'PY'
import json, re, subprocess, sys
S, IT, PJS = sys.argv[1:4]
src = open(PJS, encoding="utf-8").read()
m = re.search(r"const DETECT_ARCH_SCHEMA = \{(.*?)\n\}\n", src, re.S)
want = set(re.findall(r"^\s{4}([a-z_]+):", m.group(1), re.M)) - {"exit_code"}
arches = set(re.findall(r"'([a-z0-9]+)'", re.search(r"const ARCHES\s*=\s*\[([^\]]*)\]", src).group(1)))
sm = open(S + "/stage_map.py", encoding="utf-8").read()
choices = set(re.findall(r'"([a-z0-9]+)"', re.search(r'"--arch",[^)]*choices=\(([^)]*)\)', sm).group(1)))
open(IT + "/noise_arch.bin", "wb").write(b"x" * 4096)
def det(path):
    p = subprocess.run([sys.executable, S + "/stage_map.py", "--detect-arch", path],
                       capture_output=True, text=True)
    return p.returncode, p.stdout.strip()
res = {}
for name in ("a64.bin", "noise_arch.bin"):
    rc, o = det(IT + "/" + name)
    j = json.loads(o)
    # [contract keys the pipeline does not read, keys the pipeline reads that the script does not give]
    res[name] = (rc, j["arch"], [sorted({"arch", "entry_signature", "basis", "confidence"} - want), sorted(want - set(j))], j.get("confidence"))
rc, o = det(IT + "/does_not_exist.bin")
print(json.dumps({"a64": res["a64.bin"], "noise": res["noise_arch.bin"], "unreadable": [rc, o],
                  "pipeline_arches": sorted(arches), "stage_map_arch_choices": sorted(choices)}))
PY
)
chk "K1: 파이프라인이 계약의 네 키(arch · entry_signature · basis · confidence)를 모두 읽고, 그 키를 실제 --detect-arch 가 모두 낸다" \
    "$(echo "$K1" | it_j '(d["a64"][2], d["noise"][2])')" "([[], []], [[], []])"
chk "  합성 AArch64 스텁은 arm64, 서명 없는 바이트는 unknown, 둘 다 종료코드 0 (unknown 은 실패가 아니다)" \
    "$(echo "$K1" | it_j '(d["a64"][0], d["a64"][1], d["noise"][0], d["noise"][1])')" "(0, 'arm64', 0, 'unknown')"
chk "  읽을 수 없는 파일은 종료코드 2 이고 stdout 에 아무것도 없다 (파이프라인은 그것을 unknown 으로 읽는다)" \
    "$(echo "$K1" | it_j 'd["unreadable"]')" "[2, '']"
chk "  파이프라인이 받아들이는 arch 값 = stage_map.py --arch 의 선택지 (arm32 · arm64)" \
    "$(echo "$K1" | it_j '(d["pipeline_arches"], d["stage_map_arch_choices"])')" "(['arm32', 'arm64'], ['arm32', 'arm64'])"
# K5: 분석가에게 쓰라고 하는 파일 이름을 run_full.sh 가 읽고, 파이프라인은 환경변수를 권하지 않는다
chk "K5: 파이프라인이 분석가에게 쓰라는 kernel_task_regex.txt 를 run_full.sh 가 읽는다" \
    "$(grep -c 'kernel_task_regex\.txt' "$PJS" | sed 's/^0$/no/;s/^[1-9].*/yes/'):$(grep -c 'kernel_task_regex\.txt' "$S/run_full.sh" | sed 's/^0$/no/;s/^[1-9].*/yes/')" "yes:yes"
chk "  파이프라인 프롬프트 어디에도 KERNEL_TASK_REGEX 환경변수를 설정하라는 말이 없다 (회차 명령은 변수를 나르지 못한다)" \
    "$(grep -c 'KERNEL_TASK_REGEX' "$PJS")" "0"
# K6: 담당 열 규칙이 세 곳에서 같다 — 여섯 fixer 이름 전부와 build 라는 낱말
chk "K6: static-analyzer.md · faults_unified.md 의 담당 열 규칙이 여섯 fixer 이름 전부와 literal build 를 말한다 (pipeline.js 와 같은 규칙)" \
    "$(python3 - "$PJS" "$REPO/agents/static-analyzer.md" "$REPO/knowledge/faults_unified.md" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
fixers = re.findall(r"'(fixer-[a-z0-9]+)'", re.search(r"KNOWN_FIXERS = \[([^\]]*)\]", src).group(1))
res = []
res.append(len(fixers) == 6 and "literal word build" in src and "six fixer names" in src)
for f in sys.argv[2:]:
    t = open(f, encoding="utf-8").read()
    m = re.search(r"literal\s+word\s+`?build`?", t)
    win = t[max(0, m.start() - 700): m.end()] if m else ""
    res.append(bool(m) and all(x in win for x in fixers))
print(res)
PY
)" "[True, True, True]"
# K8: 파이프라인이 부르는 인자 · 종료코드 · 마지막 줄을 스크립트가 실제로 그렇게 낸다
chk "K8: 파이프라인이 extract_boot_assets.sh 를 <workdir> <boot.img> <super> <dtb> 네 인자로 부르고, 스크립트 머리말이 같은 사용법과 종료코드 4 (super)를 말한다" \
    "$(grep -c 'extract_boot_assets\.sh" "\$WD" "\$BOOT" "\$SUPER" "\$DTB"' "$PJS"):$(grep -c '<workdir> <boot.img> \[super.img.lz4|super.img\] \[dtb\]' "$S/extract_boot_assets.sh" | sed 's/^[1-9].*/1/'):$(grep -c '^#   4  super' "$S/extract_boot_assets.sh")" "1:1:1"
python3 - "$IT/boot_v0.img" <<'PY'
import struct, sys
ps = 4096; kernel = b"synthetic-kernel-bytes-".ljust(64, b"x")
hdr = bytearray(ps); hdr[0:8] = b"ANDROID!"
struct.pack_into("<I", hdr, 0x08, len(kernel)); struct.pack_into("<I", hdr, 0x10, 0)
struct.pack_into("<I", hdr, 0x24, ps); struct.pack_into("<I", hdr, 0x28, 0)
open(sys.argv[1], "wb").write(bytes(hdr) + kernel + b"\0" * (ps - len(kernel)))
PY
XW="$IT/xassets"; rm -rf "$XW"; mkdir -p "$XW"
UNPACK_BOOTIMG=/nonexistent/unpack_bootimg bash "$S/extract_boot_assets.sh" "$XW" "$IT/boot_v0.img" "" "" > "$IT/xassets.out" 2>&1; XRC=$?
chk "  super 와 dtb 를 빈 문자열로 불러도 종료 0, 마지막 줄 형식 'assets: image=1 dtb=0 initrd=0 super=none' (파이프라인이 grep '^assets: ' 로 읽는다)" \
    "$XRC:$(tail -n 1 "$IT/xassets.out")" "0:assets: image=1 dtb=0 initrd=0 super=none"
UNPACK_BOOTIMG=/nonexistent/unpack_bootimg bash "$S/extract_boot_assets.sh" "$XW" "$IT/boot_v0.img" "" "" > "$IT/xassets2.out" 2>&1
chk "  같은 인자로 다시 불러도 같다 (멱등)" "$(tail -n 1 "$IT/xassets2.out")" "assets: image=1 dtb=0 initrd=0 super=none"
printf 'not a boot image' > "$IT/bad_boot.img"
UNPACK_BOOTIMG=/nonexistent/unpack_bootimg bash "$S/extract_boot_assets.sh" "$XW" "$IT/bad_boot.img" "" "" > /dev/null 2>&1; BRC=$?
chk "  boot.img 가 아니면 종료 3 이고 이전 fw/Image 는 그대로다 (파이프라인은 failed 로 읽는다)" \
    "$BRC:$(head -c 10 "$XW/fw/Image" | tr -d '\0')" "3:synthetic-"
chk "K8: static-analyzer.md 는 더 이상 사용자에게 스크립트를 가리키라고 하지 않는다" \
    "$(grep -c 'Point the user at' "$REPO/agents/static-analyzer.md")" "0"
# 계열 자료: family_kit.py 의 상대 경로가 플러그인 루트 아래에서 실제로 열린다 (파이프라인이 그 앞에 루트를 붙인다)
chk "K9: family_kit.py 가 답한 지식표·진행 가이드(상대 경로)가 플러그인 루트 아래에 실제로 있다 — 파이프라인이 붙이는 절대 경로가 열린다" \
    "$(python3 "$S/family_kit.py" mediatek | python3 -c "
import json, os, sys
d = json.load(sys.stdin)
rel = d['knowledge'] + [d['runbook']]
print(all(not os.path.isabs(p) and os.path.isfile(os.path.join(sys.argv[1], p)) for p in rel) and len(rel) >= 2)" "$REPO")" "True"
chk "K9: pipeline.js 는 그 상대 경로 앞에 플러그인 루트를 붙여 에이전트에게 준다 (familyContext 의 지식표·진행 가이드, 분류기의 지식표)" \
    "$(grep -c 'familyKnowledge.map(abs).join' "$PJS"):$(grep -c 'abs(familyRunbook)' "$PJS"):$(grep -c 'all.map(abs).join' "$PJS")" "1:1:1"
# 종료코드 표: 파이프라인이 설명을 붙이는 종료코드 = 스크립트 머리말이 문서화한 종료코드 (0 은 성공이라 제외)
chk "K8: pipeline.js 의 ASSET_EXIT_MEANING 이 extract_boot_assets.sh 머리말의 종료코드 표와 같은 번호(1 · 2 · 3 · 4)를 말한다" \
    "$(python3 - "$PJS" "$S/extract_boot_assets.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
mine = sorted(int(x) for x in re.findall(r"^\s{2}(\d):", re.search(r"const ASSET_EXIT_MEANING = \{(.*?)\n\}", src, re.S).group(1), re.M))
hdr = open(sys.argv[2], encoding="utf-8").read().split("set -e")[0]
theirs = sorted(int(x) for x in re.findall(r"^#\s+(\d)\s{2}\S", hdr.split("종료코드:")[1].split("마지막 줄")[0], re.M) if int(x) > 0)
print((mine, theirs))
PY
)" "([1, 2, 3, 4], [1, 2, 3, 4])"
# K1: 뒤 이미지마다 묻는 --detect-arch 의 종료코드 (분석가 프롬프트가 2 = 읽을 수 없음, 64 = 호출 실수라고 말한다)
python3 "$S/stage_map.py" --detect-arch "$IT/a64.bin" "$IT/a64.bin" > /dev/null 2>&1; K1RC=$?
python3 "$S/stage_map.py" --detect-arch "$IT/does_not_exist.bin" > /dev/null 2>&1; K1RC2=$?
chk "K1: --detect-arch 를 이미지와 함께 부르면 종료 64, 읽을 수 없는 파일은 종료 2 — 분석가 프롬프트가 말하는 뜻과 같다" \
    "$K1RC:$K1RC2:$(grep -c 'Exit 2 = the file cannot be read' "$PJS"):$(grep -c 'exit 64 = you combined the flag' "$PJS")" "64:2:1:1"
# cmdline_plan.json: 프롬프트가 보이는 키 · 경고 키를 build_lu.py 가 실제로 정의한다
chk "분석가 프롬프트의 cmdline_plan.json 키(partition · offset · source)와 경고 키(warning_cmdline · warning_cmdline_target)를 build_lu.py 가 읽고 낸다" \
    "$(python3 - "$PJS" "$S/build_lu.py" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
blu = open(sys.argv[2], encoding="utf-8").read()
item9 = src.split("9. KERNEL COMMAND LINE")[1].split("10. KERNEL SIDE")[0]
keys = ["partition", "offset", "source"]
warns = ["warning_cmdline", "warning_cmdline_target"]
print(([k for k in keys if '"%s": ' % k not in item9], [w for w in warns if w not in item9],
       [k for k in keys if 'plan.get("%s"' % k not in blu and 'plan["%s"]' % k not in blu],
       [w for w in warns if w not in blu]))
PY
)" "([], [], [], [])"
# verify.py 가 내는 hash_engine · address_windows 객체의 키를 파이프라인이 읽는다
chk "verify 의 hash_engine · address_windows: pipeline.js 가 읽는 키를 verify_gates.py 가 실제로 낸다" \
    "$(python3 - "$PJS" "$S/verify_gates.py" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
vg = open(sys.argv[2], encoding="utf-8").read()
he = re.search(r"function hashEngineSummary\(vb\) \{(.*?)\n\}\n", src, re.S).group(1)
aw = re.search(r"function addressWindowsText\(w\) \{(.*?)\n\}\n", src, re.S).group(1)
hk = sorted(set(re.findall(r"\bhe\.([a-z_]+)", he)))
wk = sorted(set(re.findall(r"\bw\.([a-z_]+)", aw)))
print(([k for k in hk if '"%s"' % k not in vg], [k for k in wk if '"%s"' % k not in vg], len(hk) >= 6, len(wk) >= 5))
PY
)" "([], [], True, True)"
# K1: the unknown-architecture probe (archProbeCmd in pipeline.js) against the REAL stage_map.py. The two readings do not say "no entry
# signature" the same way: arm32 exits 3, but --arch arm64 NEVER does (its map always succeeds, with an exec stage and no entry point, for an
# AArch32 image and for random bytes alike) - so under arm64 a signature is a non-empty entry_stubs list. The count is read by the awk inside the
# emitted command out of the JSON layout json.dump writes; both are checked here against the real files. If stage_map.py ever starts to
# exit 3 under arm64, or writes entry_stubs in another layout, this is where the pipeline's reading stops being true.
# (The checker is written to a file first: bash 3.2 cannot parse a heredoc with backticks inside $( ).)
cat > "$IT/probe_check.py" <<'PY'
import json, os, re, struct, subprocess, sys
S, IT, PJS = sys.argv[1:4]
src = open(PJS, encoding="utf-8").read()
body = src.split("function archProbeCmd()")[1].split("/* What the two readings found")[0]
unesc = lambda t: re.sub(r"\\(.)", lambda m: {"n": "\n", "\\": "\\"}.get(m.group(1), m.group(1)), t)
script = "".join(unesc(x) for x in re.findall(r"`((?:[^`\\]|\\.)*)`", body))
am = re.search(r"awk '(.*?)' \"\$F\"\)", script, re.S)
w32 = lambda n: struct.pack("<I", n & 0xFFFFFFFF)
a32 = b"".join(w32(0xE92D4010) + w32(0xE8BD8010) for _ in range(0x800))
vt = b"".join(w32(0xEAFFFFFE) for _ in range(8))
open(IT + "/probe_vt.bin", "wb").write(vt + a32)
open(IT + "/probe_a32plain.bin", "wb").write(a32)
open(IT + "/probe_noise.bin", "wb").write(b"x" * 4096)
def reading(path, arch):
    out = IT + "/probe_" + arch + ".json"
    if os.path.exists(out):
        os.remove(out)
    p = subprocess.run([sys.executable, S + "/stage_map.py", path, "--arch", arch, "--quiet", "--out", out],
                       capture_output=True, text=True)
    j = json.load(open(out))
    a = subprocess.run(["awk", am.group(1), out], capture_output=True, text=True).stdout.strip()
    st = j["stages"][0] if j["stages"] else None
    return [p.returncode, len(j["entry_stubs"]), a, j["arch_supported"], len(j["stages"]), (st or {}).get("entry_pc"), (st or {}).get("state")]
res = {"awk_found": bool(am), "keys": all(k in src for k in ("arm32_exit", "arm32_entry_stubs", "arm64_exit", "arm64_entry_stubs"))}
for name, f in (("noise", "probe_noise.bin"), ("a32plain", "probe_a32plain.bin"), ("vt", "probe_vt.bin"), ("a64", "a64.bin")):
    res[name] = {"arm32": reading(IT + "/" + f, "arm32"), "arm64": reading(IT + "/" + f, "arm64")}
print(json.dumps(res))
PY
K1P=$(python3 "$IT/probe_check.py" "$S" "$IT" "$PJS")
chk "K1: 파이프라인의 두 해석 비교(archProbeCmd)가 읽는 awk 와 키 네 개가 있다" \
    "$(echo "$K1P" | it_j '(d["awk_found"], d["keys"])')" "(True, True)"
chk "  AArch32 시그니처 없는 이미지와 무작위 바이트: arm32 는 종료 3, arm64 는 종료 0 (arch_supported true, exec 스테이지 하나, 진입점 없음) — 종료코드 0 은 시그니처 증거가 아니다" \
    "$(echo "$K1P" | it_j '(d["noise"]["arm32"][0], d["noise"]["arm64"][:2] + d["noise"]["arm64"][3:], d["a32plain"]["arm32"][0], d["a32plain"]["arm64"][:2] + d["a32plain"]["arm64"][3:])')" \
    "(3, [0, 0, True, 1, None, 'exec'], 3, [0, 0, True, 1, None, 'exec'])"
chk "  ARM 벡터 테이블 이미지: arm32 는 종료 0 에 스텁 1, arm64 는 종료 0 에 스텁 0 — 시그니처가 한 해석에만 있다" \
    "$(echo "$K1P" | it_j '(d["vt"]["arm32"][:2], d["vt"]["arm64"][:2])')" "([0, 1], [0, 0])"
chk "  AArch64 스텁 이미지: arm32 는 종료 3, arm64 는 종료 0 에 스텁이 있다" \
    "$(echo "$K1P" | it_j '(d["a64"]["arm32"][0], d["a64"]["arm64"][0], d["a64"]["arm64"][1] > 0)')" "(3, 0, True)"
chk "  명령 안의 awk 가 읽은 스텁 수 = 실제 지도의 entry_stubs 길이 (여덟 경우 전부)" \
    "$(echo "$K1P" | it_j 'all(str(d[n][a][1]) == d[n][a][2] for n in ("noise", "a32plain", "vt", "a64") for a in ("arm32", "arm64"))')" "True"
rm -rf "$XW" "$IT/boot_v0.img" "$IT/bad_boot.img" "$IT/xassets.out" "$IT/xassets2.out" "$IT/noise_arch.bin" \
       "$IT"/probe_*.bin "$IT"/probe_arm32.json "$IT"/probe_arm64.json "$IT/probe_check.py"

parts_finish
