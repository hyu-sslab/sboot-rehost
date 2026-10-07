#!/usr/bin/env python3
"""verify.py - measure the unified-chain verification (stage 1 verdict).

Three GATE items decide the verdict. They exist for one purpose: **a console
that was invented - by the machine or by an agent editing it - must not read as
a real boot.**

  1. source negative  the machine C prints none of the console text
  2. output origin    every fixed console string exists inside the firmware
  3. input origin     the machine never fills its own UART receive buffer

The gate logic lives in verify_gates.py (a C lexer, the console reader, the
reference-image set, the ledger parser) so it can be tested on its own; this
file reads the workspace, calls it, and writes the verdict.

Everything else (chain trace, two-way verification, dual storage drive, bypass
record) is measured and reported but does NOT block. Holding the whole 6/6 bar
turned every run into FORCED and buried the progress actually made.

A verification BYPASS report rides along (verify_bypass in the JSON): ledger rows
that change what verified boot decides, forged or modified media, the firmware's
own status lines, and whether a corrupted image was rejected. It is not a gate -
a gate would make every MediaTek run UNVERIFIED and blur what the gates answer
(did this console come out of the firmware?) - but the label carries it:
  VERIFIED (출처 검증 통과) · 검증 우회 N건 · verify_ok: reached_bypassed

Two more things are read from STATIC.md and reported, never gated: whether the row saying the
firmware's digest is computed by a hardware engine exists (verify_bypass.hash_engine; the ledger
check in check_change.sh turns its absence into a rejection of a labelled hash bypass), and, for
a mixed-architecture machine only, whether the "address windows" table is there and complete
(address_windows, reference item 8).

This is stage 1 of a two-stage check. The verifier agent re-examines the
verdict_script.json produced here and may lower the verdict freely; raising it
requires byte-level evidence.

Inputs are bound to the workspace and the round: console_<N>.txt (UART lines
only), kernel_<N>.log (the merged memory-dump log), run_<N>.log. The guest console
is the UART console plus the memory-dump log; QEMU's own diagnostic lines are
never guest evidence. Nothing outside the workspace is read unless a path is
passed (--trace).

Item names and evidence strings stay in Korean on purpose: they are copied
straight into VERIFICATION.md, which the user reads.

Usage:
  verify.py <workdir> --target F2 --container <container.bin> [--round N]
            [--memdump-log F] [--bypass-ledger F] [--negative-console F]
            [--stage-map F] [--trace F] [--protected-ranges BASE:SIZE,...]

Output: JSON on stdout + <workdir>/verdict_script.json
"""
import argparse
import glob
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_gates as vg  # noqa: E402

# The four bypass fields, written with optional markdown emphasis and, for the
# side-effect field, the longer "알려진 부작용" wording that real workspaces use.
BYPASS_FIELDS = {
    "대상": r"대상",
    "이유": r"이유",
    "방법": r"방법",
    "부작용": r"(?:알려진\s*)?부작용",
}


# --- input discovery ---------------------------------------------------------
def newest(paths):
    files = [p for p in paths if os.path.isfile(p)]
    return max(files, key=os.path.getmtime) if files else None


def _numbered(workdir, stem, ext, rnd):
    """07_logs/<stem>_<N><ext> for round N; without a round, the highest N.

    Bound to the workspace and the round on purpose: picking "the newest file
    anywhere" read a trace from a different run (a kit's verdict cited run_8.log
    that this run never wrote)."""
    d = os.path.join(workdir, "07_logs")
    if rnd is not None:
        path = os.path.join(d, "%s_%s%s" % (stem, rnd, ext))
        return path if os.path.isfile(path) else None
    best, best_n = None, -1
    for path in glob.glob(os.path.join(d, "%s_*%s" % (stem, ext))):
        m = re.fullmatch(r"%s_(\d+)%s" % (re.escape(stem), re.escape(ext)),
                         os.path.basename(path))
        if m and int(m.group(1)) > best_n and os.path.isfile(path):
            best, best_n = path, int(m.group(1))
    if best:
        return best
    # No numbered file: an older workspace that named its logs freely.
    return newest(glob.glob(os.path.join(d, "%s_*%s" % (stem, ext))))


def find_console(workdir, rnd=None):
    return _numbered(workdir, "console", ".txt", rnd)


def find_memdump(workdir, rnd=None):
    """The merged memory-dump kernel log (one `<kernel_seconds> <text>` per line)."""
    return _numbered(workdir, "kernel", ".log", rnd)


def find_trace(workdir, rnd=None):
    return _numbered(workdir, "run", ".log", rnd)


def find_normalized(workdir, rnd=None):
    """The normalized guest console verify_prep.py wrote, if it ran."""
    return _numbered(workdir, "guest_console", ".norm.txt", rnd) if rnd is not None else \
        newest(glob.glob(os.path.join(workdir, "07_logs", "guest_console_*.norm.txt")))


def machine_sources(workdir):
    """(built, skipped): the machine files that were actually compiled, and the
    stale ones left beside them (reported by name, never silently dropped).

    A machine source that is not scanned is not evidence of anything, so every
    .c is taken unless qemu_targets.txt says which ones were synced into the QEMU
    tree; headers and .inc files are scanned too (a string can live there)."""
    return vg.resolve_sources(workdir)


def find_bypass(workdir):
    src = os.path.join(workdir, "06_machine")
    for name in ("bypasses.md", "우회_패치_목록.md"):
        path = os.path.join(src, name)
        if os.path.isfile(path):
            return path
    return None


def read_bytes(path):
    if not path or not os.path.isfile(path):
        return b""
    with open(path, "rb") as fh:
        return fh.read()


def read_text(path):
    if not path or not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# --- shared items ------------------------------------------------------------
def check_bypass(workdir, strict=False, ledger=None):
    """Every bypass entry must carry all four fields.

    Real workspaces write these with markdown emphasis (`**대상**:`) and often
    spell the last one "알려진 부작용", so matching the bare literal `대상:`
    reported zero fields and failed a compliant file. Match the field name with
    optional emphasis and an optional leading list marker instead.

    `strict` (the unified flow) also holds the ledger to its quality bar: a
    부작용 that is empty or "(기록 없음)" is rejected, the optional 메타 line must
    use the vocabulary, and patch-table rows tagged /* bypass:<id> */ must map
    one to one onto entries. Counting field lines alone passed a table row with
    no record behind it.
    """
    path = ledger or find_bypass(workdir)
    if not path or not os.path.isfile(path):
        return False, "우회 기록 파일이 없습니다 (06_machine/bypasses.md)"
    text = read_text(path)
    counts = {}
    for label, pattern in BYPASS_FIELDS.items():
        rx = re.compile(rf"^[\s>\-*+]*\**\s*{pattern}\s*\**\s*[:：]", re.M)
        counts[label] = len(rx.findall(text))
    entries = counts["대상"]
    complete = entries > 0 and len(set(counts.values())) == 1
    if not complete:
        return False, f"{os.path.basename(path)}: 항목 수가 어긋납니다 {counts}"
    if strict:
        built, _skipped = machine_sources(workdir)
        issues = vg.ledger_issues(vg.parse_ledger(text), vg.scan_tags(built),
                                  hash_engine=vg.hash_engine_state(workdir))
        if issues:
            return False, (f"{os.path.basename(path)}: 우회 {entries} 건, 4 항목은 갖췄으나 기록에 "
                           f"문제가 {len(issues)} 건 있습니다: "
                           f"{[i['message'] for i in issues[:3]]}")
    return True, f"{os.path.basename(path)}: 우회 {entries} 건, 모두 4 항목을 갖췄습니다"


def check_source_negative(sources, console_bytes):
    """Does the machine emit any string that shows up on the guest console?

    The test runs literal -> console, not console token -> literal. The earlier
    direction flagged a MemoryRegion built as "rehost.itmon%d" because the word
    "itmon" also appears in the firmware's own ITMON messages - a machine that
    names a device after the hardware it models is not forging output. Asking
    whether a machine literal *appears on the console* has no such ambiguity:
    if the machine writes "S-BOOT # " and the console shows "S-BOOT # ", that is
    injection, and nothing else trips it.

    Literals come from a lexer, not from regexes over the source text (see
    verify_gates.py): `;` and quotes inside strings and char literals no longer
    flip what is read as code.
    """
    return vg.check_source_negative(sources, console_bytes)


# The storage ladder k3_stage_report reads off the guest console and the trace: how far
# the kernel got with the medium. The bar is partitions_up (minimum completion);
# super_mounted is the capstone and only applies to firmware that ships a super image.
# Link-up wording differs by driver: the ufshcd core or the vendor glue driver.
LINK_UP_PATTERNS = [
    r"scsi host\d+: ufshcd",
    r"ufs\w*[^\n]*: UFS link established",
]
K3_STAGES = {
    # The kernel prints the partition list under whatever the medium is: `sda: sda1`
    # on UFS/SCSI, `mmcblk0: p1 p2` on eMMC. Only the first used to count, so an
    # eMMC kernel that enumerated every partition read as "not up".
    "partitions_up": [r"\bsda: sda\d", r"\bmmcblk\d+: p\d+"],
    "super_mounted": [r"supermount: SUCCESS",
                      r"erofs: \(device dm-\d+\): mounted"],
}
# Rungs below the completion bar. Reaching one of these is progress, not K3.
K3_PROGRESS = {
    "link_up": LINK_UP_PATTERNS,
    "power_mode": [r"Power mode change\(\d+\)"],
    "scsi_attach": [r"\[sda\] Attached SCSI disk"],
}


def any_match(patterns, haystack):
    return [p for p in patterns if re.search(p, haystack)]


def k3_stage_report(haystack, kind="ufs"):
    """Which rung of the storage ladder the run actually cleared.

    `kind` names the medium. The "UFS 컨트롤러 미완성" wording is true only for a
    UFS device; printing it for an eMMC boot blamed a controller the machine does
    not have."""
    cleared = [n for n, p in K3_PROGRESS.items() if any_match(p, haystack)]
    if any_match(K3_STAGES["partitions_up"], haystack):
        cleared.append("partitions_up")
    if any_match(K3_STAGES["super_mounted"], haystack):
        cleared.append("super_mounted")
    if "super_mounted" in cleared:
        stage = "최종 칸 (완전한 컨트롤러 — super 마운트)" if kind == "ufs" \
            else "최종 칸 (super 마운트)"
    elif "partitions_up" in cleared:
        stage = "최소 완료 (파티션 열거)"
    elif kind == "ufs":
        stage = "미완 (UFS 컨트롤러 미완성)"
    else:
        stage = "미도달 (커널의 파티션 열거 없음)"
    return {"stage": stage, "cleared": cleared}


def storage_kind(haystack):
    """ufs | emmc | unknown, from what the kernel itself printed."""
    if re.search(r"ufshcd|\bsd[a-z]: sd[a-z]\d|\[sd[a-z]\] Attached SCSI", haystack):
        return "ufs"
    if re.search(r"\bmmcblk\d+\b", haystack):
        return "emmc"
    return "unknown"


# --- unified chain -----------------------------------------------------------
# Besides the three gates, this flow makes two claims a console string alone cannot
# prove: that the chain really ran stage by stage, and that the firmware's own
# verified boot passed on its own terms. Both are easy to fake, so each gets an item
# that can FAIL.

def stage_pc(st):
    """The PC a stage is entered at.

    stage_map v2 carries it as `entry_pc` (absolute, lowercase hex string, filled
    for AArch64 stages too), and that is the one value both the trace watch and
    this item must use. The v1 formula stays as the fallback for an old map:
    `base` is a dict ({"load_base": ...}), and reading it as an int silently
    produced an empty watch list - the item could never pass on any firmware."""
    pc = st.get("entry_pc")
    if pc not in (None, ""):
        try:
            return int(str(pc), 0)
        except ValueError:
            pass
    base = st.get("base")
    base = base.get("load_base") if isinstance(base, dict) else base
    off = st.get("entry_pc_file_offset")
    rng = st.get("file_range") or [None, None]
    if not isinstance(base, int) or isinstance(base, bool) or off is None or rng[0] is None:
        return None
    return base + (off - rng[0])


def stage_entries(workdir, stage_map=None):
    """Per-stage entry PCs from the derived map, in chain order."""
    path = stage_map or os.path.join(workdir, "stage_map.json")
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError):
        return []
    out = []
    for st in data.get("stages") or []:
        if st.get("state") != "exec":
            continue
        pc = stage_pc(st)
        if pc is None:
            continue
        out.append({"name": st.get("name") or f"stage{st.get('index')}",
                    "pc": pc, "arch": st.get("arch")})
    return out


def pc_pattern(pc, arch=None):
    """The entry PC as it can appear in a trace: any zero padding after `0x`, and
    nothing hex-like around it (so 0x40080000 does not match 0x400800001). A
    Thumb entry carries bit 0 in the map but not in the executed address."""
    vals = {pc}
    if arch == "aarch32":
        vals.add(pc & ~1)
    alts = "|".join("0x0*%x" % v for v in sorted(vals))
    return re.compile(r"(?<![0-9a-fx])(?:%s)(?![0-9a-f])" % alts, re.I)


# Re-exported so callers (and the older scripts) keep one place to look.
FIXED_WORD = vg.FIXED_WORD
IMAGE_DIRS = vg.IMAGE_DIRS
IMAGE_MAX = vg.IMAGE_MAX
ORIGIN_MIN_RATIO = vg.ORIGIN_MIN_RATIO


def firmware_images(workdir, extra):
    """Every firmware component whose strings the console may contain (the
    reference set; synthesized and forged partitions are not in it)."""
    return vg.reference_images(workdir, list(extra)).blobs


def check_output_origin(console, images):
    """Every fixed string on the console must exist inside a firmware image.

    This is the load-bearing anti-fabrication check: if the machine (or an agent
    editing it) invented console text, the words will not be in any binary. The
    pass rule is still the word ratio; the line-shape list rides along."""
    return vg.check_output_origin(console, images)


def check_input_origin(sources):
    """The machine must not fill its own UART receive buffer.

    A machine that seeds RX is talking to itself; the shell "responding" then
    proves nothing. Input may only arrive through the chardev callback."""
    return vg.check_input_origin(sources)


def discover_harness(workdir, extra=()):
    """The files that drive QEMU from outside: the plugin's own harness and run
    scripts, plus any run script the workspace carries."""
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [os.path.join(here, n) for n in
             ("uart_harness.py", "run_full.sh", "run_round.sh", "memdump_observe.py")]
    cands += sorted(glob.glob(os.path.join(workdir, "*.sh")))
    cands += sorted(glob.glob(os.path.join(workdir, "*.py")))
    cands += sorted(glob.glob(os.path.join(workdir, "harness", "*")))
    cands += list(extra or [])
    seen, out = set(), []
    for c in cands:
        real = os.path.realpath(c)
        if os.path.isfile(c) and real not in seen:
            seen.add(real)
            out.append(c)
    return out


def read_lines(path):
    """Guest lines of a console-like file (host diagnostics removed), or None."""
    if not path or not os.path.isfile(path):
        return None
    lines, _dropped = vg.filter_host(read_bytes(path))
    return lines or None


def milestone_token(workdir, name):
    """(token, channel) the static-analyzer derived for a milestone (C2 format:
    milestone TAB token [TAB channel]); channel defaults to uart."""
    path = os.path.join(workdir, "milestone_tokens.txt")
    for line in read_text(path).splitlines():
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[0].strip() == name:
            return parts[1], (parts[2].strip() if len(parts) > 2 and parts[2].strip() else "uart")
    return None, None


def _round_of(path):
    m = re.fullmatch(r"console_(\d+)\.txt", os.path.basename(path or ""))
    return m.group(1) if m else None


def verify_full(workdir, args):
    """Measure the unified chain.

    Three GATE items decide the verdict. They exist for one purpose: a console
    that was invented - by the machine or by an agent editing it - must not read
    as a real boot. Everything else is measured and reported but does not block,
    because holding the whole 6/6 bar turned every run into FORCED and buried
    the progress that had actually been made.
    """
    rnd = args.round
    console_path = args.console or find_console(workdir, rnd)
    # Files of one round go together. An explicit --console with no round gets its
    # round from its own name; without either, nothing is guessed.
    eff = rnd if rnd is not None else _round_of(console_path)
    memdump_path = args.memdump_log or (find_memdump(workdir, eff) if eff is not None else None)
    trace_path = args.trace or (find_trace(workdir, eff) if eff is not None else
                                find_trace(workdir) if not args.console else None)
    if args.machine:
        sources, skipped = [args.machine], []
    else:
        sources, skipped = machine_sources(workdir)

    guest = vg.read_guest_console(console_path, memdump_path)
    trace = read_text(trace_path)
    hay = guest["bytes"].decode("utf-8", errors="replace") + "\n" + trace
    kernel_tok, kernel_chan = milestone_token(workdir, "kernel_alive")
    kernel_tok = kernel_tok or "Linux version"
    items, extra = [], {}

    # --- GATE 1: the machine does not print console text -------------------
    protected = vg.parse_ranges(args.protected_ranges) if args.protected_ranges else []
    for rg in vg.plan_ranges(workdir):
        if rg not in protected:
            protected.append(rg)
    deadline = time.monotonic() + vg.SCAN_BUDGET
    facts, timed_out, res1 = [], False, {}
    try:
        facts = vg.analyze_files(sources, deadline)
        res1 = vg.source_negative(facts, guest, protected, skipped, deadline)
    except vg.ScanTimeout:
        timed_out = True
    ok1, detail1 = vg.source_negative_verdict(res1, len(sources), timed_out)
    items.append({"n": 1, "gate": True,
                  "name": "소스 negative (머신 C 에 출력 문자열 없음)",
                  "pass": ok1, "evidence": detail1, "detail": res1 or {"timeout": True}})

    # --- GATE 2: the console came out of the firmware ----------------------
    norm_path = args.console_normalized or (
        find_normalized(workdir, eff) if (eff is not None or not args.console) else None)
    g2 = guest
    norm_lines = read_lines(norm_path)
    if norm_lines:
        g2 = {"lines": norm_lines, "bytes": b"\n".join(norm_lines) + b"\n"}
    bs = vg.reference_images(workdir, [args.container, getattr(args, "kernel", None)],
                             provenance=args.lu_provenance, manifest=args.lu_manifest)
    try:
        res2 = vg.output_origin(g2, bs.blobs, bs.names, args.shape_budget)
    finally:
        bs.close()
    res2["reference"]["excluded"] = bs.excluded
    res2["reference"]["console"] = (os.path.basename(norm_path) if norm_lines
                                    else "게스트 콘솔 원본")
    items.append({"n": 2, "gate": True,
                  "name": "출력 출처 (콘솔 고정 문자열이 펌웨어 안에 존재)",
                  "pass": res2["pass"], "evidence": res2["evidence"],
                  "detail": {k: v for k, v in res2.items() if k not in ("pass", "evidence")}})

    # --- GATE 3: the machine does not feed itself input --------------------
    harness = discover_harness(workdir, args.harness)
    if timed_out:
        ok3, detail3, res3 = False, "소스 스캔이 제한 시간을 넘겼습니다 — 검사하지 못한 것은 통과가 아닙니다", {}
    else:
        token = args.input_token or ("getvar:" if args.surface == "fastboot" else None)
        res3 = vg.input_origin(facts, harness, token)
        ok3, detail3 = vg.input_origin_verdict(res3, len(sources))
    items.append({"n": 3, "gate": True,
                  "name": "입력 출처 (머신이 자기 수신 버퍼를 채우지 않음)",
                  "pass": ok3, "evidence": detail3, "detail": res3})

    # --- verification bypass: reported, never a gate -----------------------
    ledger = args.bypass_ledger or find_bypass(workdir)
    entries = vg.parse_ledger(read_text(ledger)) if ledger else []
    neg_path = args.negative_console or os.path.join(workdir, "07_logs", "avb_negative.txt")
    neg_lines = read_lines(neg_path)
    report = vg.bypass_report(workdir, entries, guest, neg_lines, medium_image=args.lu_image,
                              provenance=args.lu_provenance, manifest=args.lu_manifest,
                              status_tokens=args.status_token or ())

    # --- reference: measured, reported, not a gate -------------------------
    stages = stage_entries(workdir, args.stage_map)
    if not stages:
        ev, ok = "stage_map.json 에서 스테이지 진입 PC 를 얻지 못했습니다", False
    else:
        seen, order_ok, last = [], True, -1
        for st in stages:
            m = pc_pattern(st["pc"], st.get("arch")).search(trace)
            if not m:
                continue
            seen.append(st["name"])
            if m.start() < last:
                order_ok = False
            last = m.start()
        ok = len(seen) == len(stages) and order_ok
        ev = (f"스테이지 {len(seen)}/{len(stages)} 진입 PC 확인"
              + (f" (순서 {' → '.join(seen)})" if ok else ""))
    items.append({"n": 4, "gate": False, "name": "체인 PC 트레이스 (참고)",
                  "pass": ok, "evidence": ev})

    ok_tok = args.verify_ok_token or "verify"
    pos = bool(re.search(re.escape(ok_tok), hay, re.I)) and "fail" not in hay.lower()[-4000:]
    if neg_lines is None:
        ok, ev = False, ("훼손 시험 미실시 — scripts/make_negative_image.py 로 vbmeta 1 바이트를 "
                         "훼손한 매체로 회차를 돌려 그 콘솔을 --negative-console 로 넘기면 검증이 "
                         "실제로 도는지 확인됩니다")
    else:
        neg = report["negative_test"]
        ok = bool(pos and neg["rejected"])
        ev = f"정상 이미지 통과={pos}, 훼손 이미지 거부={neg['rejected']}"
        if not neg["rejected"]:
            ev += " — 훼손해도 새 실패 줄이 없습니다 (검증이 우회되었을 가능성)"
    items.append({"n": 5, "gate": False, "name": "검증 양방향 (참고)",
                  "pass": ok, "evidence": ev})

    boot_side = any_match([r"EFI PART", r"[Pp]artition", r"GPT", r"\[SCSI\] LU"], hay)
    kern_side = any_match(K3_STAGES["partitions_up"], hay)
    items.append({
        "n": 6, "gate": False, "name": "스토리지 이중 구동 (참고)",
        "pass": bool(boot_side and kern_side),
        "evidence": f"부트로더측 파티션 접근={bool(boot_side)}, 커널측 열거={bool(kern_side)}"})

    ok, detail = check_bypass(workdir, strict=True, ledger=ledger)
    items.append({"n": 7, "gate": False, "name": "우회 기록 4 항목 (참고)",
                  "pass": ok, "evidence": detail})

    # The STATIC.md "address windows" table: a reference indicator for the mixed-architecture
    # machine only. Another machine gets no item (a note in the result says why).
    windows = vg.address_windows_report(workdir, sources)
    if windows["applicable"]:
        ok = (windows["status"] == "present" and windows["windows"] > 0
              and windows["security_effect_empty"] == 0)
        if windows["status"] == "present":
            ev = ("STATIC.md 주소 창 표: 창 %d 행, 보안 영향(security_effect) 칸이 빈 행 %d%s, "
                  "true 로 적힌 행 %d"
                  % (windows["windows"], windows["security_effect_empty"],
                     (" (그 중 미확정·추정으로 적힌 행 %d)" % windows["security_effect_undetermined"])
                     if windows.get("security_effect_undetermined") else "",
                     windows["security_effect_true"]))
        else:
            ev = "STATIC.md 주소 창 표: %s — %s" % (windows["status"], windows["note"])
        items.append({"n": 8, "gate": False, "name": "주소 창 표 (참고)",
                      "pass": ok, "evidence": ev, "detail": windows})

    banner = re.search(re.escape(kernel_tok.encode("utf-8")), guest["bytes"]) is not None
    extra = {
        "hay": hay,
        "verify_bypass": report,
        "address_windows": windows,
        "guest_console": {
            "uart_lines": guest["uart_lines"], "memdump_lines": guest["memdump_lines"],
            "host_lines_dropped": guest["host_dropped"],
            "kernel_alive_token": kernel_tok, "kernel_alive_channel": kernel_chan or "memdump",
            "kernel_alive_in_guest_console": banner},
        "inputs": {"memdump": memdump_path, "round": eff, "skipped_stale": skipped,
                   "harness": [os.path.basename(h) for h in harness],
                   "normalized_console": norm_path if norm_lines else None,
                   "bypass_ledger": ledger},
    }
    return items, console_path, trace_path, sources, extra


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("workdir")
    parser.add_argument("--target", default=None, help="F1/F2/F3 (recorded in the verdict)")
    parser.add_argument("--container", default=None,
                        help="the bootloader container, loaded whole")
    parser.add_argument("--kernel", default=None,
                        help="kernel Image, so lines the kernel printed are matched too")
    parser.add_argument("--verify-ok-token", default=None,
                        help="console token that means the firmware's own verification passed")
    parser.add_argument("--machine", default=None, help="machine source (auto-discovered if omitted)")
    parser.add_argument("--console", default=None)
    parser.add_argument("--round", type=int, default=None,
                        help="which round's console_<N>.txt / kernel_<N>.log / run_<N>.log to read "
                             "(default: the highest N in 07_logs)")
    parser.add_argument("--memdump-log", default=None,
                        help="the merged memory-dump kernel log; the guest console is the UART "
                             "console plus this (default: 07_logs/kernel_<N>.log)")
    parser.add_argument("--trace", default=None,
                        help="the filtered trace of the round. Only 07_logs/run_<N>.log is looked "
                             "for otherwise; another run's trace is never picked up")
    parser.add_argument("--bypass-ledger", default=None,
                        help="the bypass record (default: 06_machine/bypasses.md)")
    parser.add_argument("--negative-console", default=None,
                        help="console of a round run on a corrupted medium (make_negative_image.py)")
    parser.add_argument("--stage-map", default=None, help="stage_map.json (default: in the workspace)")
    parser.add_argument("--console-normalized", default=None,
                        help="the normalized guest console verify_prep.py wrote; gate 2 compares "
                             "this one (gate 1 always reads the raw guest console)")
    parser.add_argument("--protected-ranges", default=None,
                        help="BASE:SIZE[,...] the machine must never reference (the pstore region; "
                             "memdump_plan.json is read too)")
    parser.add_argument("--lu-provenance", default=None, help="lu_provenance.json")
    parser.add_argument("--lu-manifest", default=None, help="lu_manifest.json")
    parser.add_argument("--lu-image", default=None, help="the medium image (default: fw/lu0.img)")
    parser.add_argument("--harness", action="append", default=[],
                        help="extra harness/run script to scan for monitor commands")
    parser.add_argument("--status-token", action="append", default=[],
                        help="extra firmware status token to look for in the guest console")
    parser.add_argument("--shape-budget", type=float, default=vg.SHAPE_BUDGET,
                        help="seconds allowed for the gate-2 line-shape comparison")
    parser.add_argument("--watch-list", action="store_true",
                        help="print the stage entry PCs (comma separated, lowercase 0x..) the trace "
                             "watch must look for - the same values item 4 verifies - and exit")
    parser.add_argument("--pc", action="append",
                        help="accepted and ignored: the entry PCs come from stage_map.json "
                             "(--stage-map), the one source the trace watch shares")
    parser.add_argument("--surface", default="shell", choices=("shell", "fastboot", "none"),
                        help="the bootloader's interactive surface; none = the bootloader has "
                             "no input surface (the input-origin checks then look for a machine "
                             "that seeds its own receive buffer, with no command token)")
    parser.add_argument("--input-token", default=None,
                        help="the command the host injects; must not appear in the "
                             "machine sources (fastboot default: getvar:)")
    args = parser.parse_args()

    if args.watch_list:
        # One source for both sides: run_full.sh watches these, item 4 checks them.
        print(",".join(hex(st["pc"]) for st in stage_entries(args.workdir, args.stage_map)))
        return

    if not args.container:
        print("verify: --container (부트로더 컨테이너) 가 필요합니다", file=sys.stderr)
        sys.exit(1)
    items, console, trace, sources, extra = verify_full(args.workdir, args)
    kind = storage_kind(extra["hay"])
    storage = k3_stage_report(extra["hay"], kind)

    passes = sum(1 for i in items if i["pass"])
    # The verdict rests on the GATE items only. They answer one question - did
    # this console come out of the firmware, or was it manufactured? The rest is
    # measured because it is worth knowing, not because it should block.
    gates = [i for i in items if i.get("gate")]
    refs = [i for i in items if not i.get("gate")]
    bypass = extra.get("verify_bypass") or {}
    gate_ok = all(i["pass"] for i in gates)
    verdict = "VERIFIED" if gate_ok else "UNVERIFIED"
    label = vg.verdict_label(gate_ok, bypass.get("count", 0))
    inputs = {"console": console, "trace": trace, "sources": sources}
    inputs.update(extra.get("inputs") or {})
    result = {
        "flow": "unified",
        "target": args.target,
        "passes": passes,
        "total": len(items),
        "gates_passed": sum(1 for i in gates if i["pass"]),
        "gates_total": len(gates),
        "reference_passed": sum(1 for i in refs if i["pass"]),
        "reference_total": len(refs),
        "verdict": verdict,
        "verdict_label": label,
        "items": items,
        "inputs": inputs,
        "note": ("게이트 3 항은 출력·입력이 펌웨어에서 나왔는지만 봅니다. "
                 "나머지는 참고 지표이며 판정을 막지 않습니다. "
                 "verifier 가 2 차로 재검증합니다."),
        "verify_bypass": bypass,
        "address_windows": extra["address_windows"],
        "guest_console": extra["guest_console"],
        "storage_controller": dict(storage, kind=kind),
    }
    if kind == "ufs":
        result["ufs_controller"] = storage

    with open(os.path.join(args.workdir, "verdict_script.json"), "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)

    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
