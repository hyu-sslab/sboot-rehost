#!/usr/bin/env python3
"""uart_harness_test.py - regression tests for the input harness.

These run without QEMU: tests/fake_guest.py stands in for the guest. They exist
because the S921N logs showed the harness failing in a way no artifact flagged -
run 7, 8 and 9 all ended with the command fired blind, including the two runs
that reached the shell - so the designed path was never exercised and nothing
said so.

Case B is the one that matters. The old harness gave up on the gate at 65% of
the budget and fired the command without ever seeing the prompt; a gate that
opens at 80% could therefore never be reported honestly.

Usage:  python3 tests/uart_harness_test.py
Exit code 0 when every case passes.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HARNESS = os.path.join(ROOT, "scripts", "uart_harness.py")
GUEST = os.path.join(HERE, "fake_guest.py")
PROMPT = "S-BOOT # "


def run_case(name, guest_args, timeout=4.0, plan=None):
    workdir = tempfile.mkdtemp(prefix="uart-harness-")
    console = os.path.join(workdir, "console.txt")
    inlog = os.path.join(workdir, "input.txt")
    summary = os.path.join(workdir, "input_summary.json")
    plan_path = None
    if plan is not None:
        plan_path = os.path.join(workdir, "input_plan.json")
        with open(plan_path, "w", encoding="utf-8") as fh:
            json.dump(plan, fh)

    cmd = [sys.executable, HARNESS,
           "--console", console, "--input-log", inlog, "--summary", summary,
           "--timeout", str(timeout), "--cmd", "help",
           "--prompt-token", PROMPT, "--surface", "shell"]
    if plan_path:
        cmd += ["--plan", plan_path]
    cmd += ["--", sys.executable, GUEST] + guest_args

    proc = subprocess.run(cmd, capture_output=True, timeout=timeout + 20)
    with open(summary, encoding="utf-8") as fh:
        got = json.load(fh)
    with open(console, "rb") as fh:
        text = fh.read().decode("latin-1")
    got["_console"] = text
    got["_prompts"] = text.count(PROMPT)
    got["_stderr"] = proc.stderr.decode("latin-1")
    return name, got, workdir


def check(name, got, expected):
    problems = []
    for key, want in expected.items():
        have = got.get(key)
        if have != want:
            problems.append(f"    {key}: 기대 {want!r} / 실제 {have!r}")
    if problems:
        print(f"[FAIL] {name}")
        print("\n".join(problems))
        return False
    print(f"[PASS] {name}")
    return True


def main():
    gate_count = 10
    plan = {"autoboot_interrupt": {"bytes": "\\r", "count": gate_count,
                                   "contiguous": True, "empty_poll_budget": 0,
                                   "gate_addr": "0xf4844f7c",
                                   "evidence": "test"}}
    ok = True

    # A - the gate opens early, inside any reasonable window.
    name, got, _ = run_case(
        "A 게이트가 창 안(0.8s)에서 열린다",
        ["--gate-at", "0.8", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "4", "--rx-report"],
        timeout=4.0, plan=plan)
    ok &= check(name, got, {"prompt_seen": True, "command_sent": True,
                            "command_blind": False, "input_starved": False})

    # B - the gate opens at 80% of the budget. The old harness had already fired
    # the command blind by 65% and stopped supplying the pattern, so this case
    # could not be reported honestly. THIS IS THE REGRESSION.
    name, got, _ = run_case(
        "B 게이트가 창 밖(예산 80%)에서 열린다 ★ 핵심 회귀",
        ["--gate-at", "3.2", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "5", "--rx-report"],
        timeout=4.0, plan=plan)
    ok &= check(name, got, {"prompt_seen": True, "command_sent": True,
                            "command_blind": False})

    # C - the surface never comes up. The command must not be sent: a run that
    # could not reach the surface has to look like one.
    name, got, _ = run_case(
        "C 표면이 끝까지 안 열린다 → 명령을 보내지 않는다",
        ["--gate-at", "0.8", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "4", "--rx-report", "--never-prompt"],
        timeout=3.0, plan=plan)
    ok &= check(name, got, {"prompt_seen": False, "command_sent": False})

    # D - no RX report channel (a machine built before the counters). The
    # fallback must still reach the surface.
    name, got, _ = run_case(
        "D 머신이 RX 를 보고하지 않는다 (구 워크스페이스) → 폴백으로 도달",
        ["--gate-at", "1.2", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "4"],
        timeout=4.0, plan=plan)
    ok &= check(name, got, {"prompt_seen": True, "command_sent": True,
                            "rx_reported": False})

    # E - the command must land as a command, not behind a hundred empty lines.
    # 92 empty prompts is what the S921N run actually produced.
    name, got, _ = run_case(
        "E 명령이 빈 줄 뒤에 묻히지 않는다",
        ["--gate-at", "0.8", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "4", "--rx-report"],
        timeout=4.0, plan=plan)
    if got["_prompts"] > 6:
        print(f"[FAIL] {name}\n    프롬프트 재출력 {got['_prompts']} 회 — "
              f"잔여 패턴이 빈 명령줄로 소비되고 있습니다")
        ok = False
    elif "Following commands are supported" not in got["_console"]:
        print(f"[FAIL] {name}\n    명령이 실행되지 않았습니다")
        ok = False
    else:
        print(f"[PASS] {name} (프롬프트 {got['_prompts']} 회)")

    # F - the plan's derived fields reach the code, not just the evidence prose.
    name, got, _ = run_case(
        "F 도출된 게이트 성질이 요약에 실린다",
        ["--gate-at", "0.8", "--gate-count", str(gate_count),
         "--prompt", PROMPT, "--run", "3", "--rx-report"],
        timeout=3.0, plan=plan)
    ok &= check(name, got, {"count": gate_count, "contiguous": True,
                            "empty_poll_budget": 0, "source": "derived",
                            "gate_addr": "0xf4844f7c"})

    # G - CC4: no input_plan.json means no derived gate. The harness must NOT offer an
    # interrupt pattern of its own (there used to be a default of three carriage
    # returns): a gate that wants a run of bytes simply stays shut, and the summary says
    # the plan was absent instead of the run looking like it had been given one.
    name, got, wd = run_case(
        "G 계획 파일이 없다 → 인터럽트 패턴을 한 바이트도 보내지 않는다",
        ["--gate-at", "0.5", "--gate-count", "3",
         "--prompt", PROMPT, "--run", "2.5", "--rx-report"],
        timeout=2.5, plan=None)
    ok &= check(name, got, {"source": "absent", "plan_note": "no input_plan.json",
                            "bytes_sent": 0, "supply_attempts": 0, "input_offered": False,
                            "input_starved": False, "prompt_seen": False,
                            "command_sent": False, "count": 0, "pattern": ""})
    with open(os.path.join(wd, "input.txt"), encoding="utf-8") as fh:
        inlog = fh.read()
    if "인터럽트 패턴: 없음" in inlog and "autoboot 중단 시도" not in inlog:
        print("[PASS] G2 입력 기록이 '패턴 없음' 을 말하고 보낸 시도가 없다")
    else:
        print("[FAIL] G2 입력 기록이 '패턴 없음' 을 말하지 않거나 시도가 남아 있다")
        ok = False

    # H - a plan that exists but is not a usable gate is the same as no plan: `bytes`
    # and `count` are both required, and neither is completed from a default.
    for label, bad in (
            ("bytes 만 있고 count 가 없다", {"autoboot_interrupt": {"bytes": "\\r"}}),
            ("count 만 있고 bytes 가 없다", {"autoboot_interrupt": {"count": 3}}),
            ("count 가 0 이다", {"autoboot_interrupt": {"bytes": "\\r", "count": 0}}),
            ("autoboot_interrupt 가 비었다", {"autoboot_interrupt": {}}),
            ("객체가 아닌 계획", [1, 2, 3])):
        name, got, _ = run_case(
            f"H 쓸 수 없는 계획({label}) → 기본값으로 채우지 않고 보내지 않는다",
            ["--gate-at", "0.5", "--gate-count", "3",
             "--prompt", PROMPT, "--run", "1.8", "--rx-report"],
            timeout=1.8, plan=bad)
        ok &= check(name, got, {"source": "absent", "bytes_sent": 0, "supply_attempts": 0,
                                "prompt_seen": False, "command_sent": False})

    # I - no derived gate does not mean no command: a bootloader with no gate shows its
    # prompt by itself, and the harness - which keeps watching for it - still types the
    # command exactly once. That is the only input it ever gave (no interrupt before it).
    name, got, _ = run_case(
        "I 게이트가 없는 펌웨어 + 계획 없음 → 프롬프트가 보이면 명령만 한 번 보낸다",
        ["--gate-at", "0.5", "--gate-count", "0",
         "--prompt", PROMPT, "--run", "2.5", "--rx-report"],
        timeout=2.5, plan=None)
    ok &= check(name, got, {"source": "absent", "prompt_seen": True, "command_sent": True,
                            "command_blind": False, "supply_attempts": 0,
                            "bytes_sent": len(b"help\r"), "input_offered": True,
                            "input_starved": False})
    if "Following commands are supported" not in got["_console"]:
        print("[FAIL] I2 명령이 실행되지 않았습니다")
        ok = False
    else:
        print("[PASS] I2 명령이 실행되었다")

    print()
    print("전부 통과" if ok else "실패한 항목이 있습니다")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
