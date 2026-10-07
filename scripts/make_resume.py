#!/usr/bin/env python3
"""make_resume.py - write RESUME.md when a run stops.

A stop is a handover, not a failure. What makes it a handover is that the next
person - or the next session - can see where the run got to, what was already
tried, and what is left. That is exactly what scrolls away when only the last
fingerprint survives.

Inputs (all optional; a missing one is reported as missing, never as empty):
  observation.json    last round's merged observation
  rounds.jsonl        every round: fingerprint / category / fixer / change / why
  blockers.jsonl      hard blockers observed as fact
  resolutions.jsonl   stop points that were cleared, and how
  prompts.jsonl       what the user actually typed
  stage_map.json      derived stage map (unified track)
  fixer_candidates.md cases fixer-general handled that have no specialist yet

Output: <workdir>/RESUME.md  (overwritten each stop - it describes the present)

Usage:
  make_resume.py <workdir> [--ladder a,b,c] [--command "/sboot-rehost:start"]

The fingerprint signature is imported from stop_conditions rather than rebuilt,
so "did this change move anything" is answered the same way the stop conditions
answer it. Two implementations of that question would eventually disagree, and
the disagreement would be invisible.
"""
import argparse
import json
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stop_conditions import read_jsonl, fingerprint  # noqa: E402


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (json.JSONDecodeError, OSError):
        return default


def esc(text):
    """Make a value safe inside a markdown table cell."""
    s = "" if text is None else str(text)
    return s.replace("|", "\\|").replace("\n", " ").strip()


def first_line(text, limit=90):
    s = (text or "").strip().splitlines()
    if not s:
        return ""
    head = s[0]
    more = " …" if (len(s) > 1 or len(head) > limit) else ""
    return esc(head[:limit]) + more


def moved(rows):
    """Per row: did the fingerprint differ from the row before it?

    This is the only honest measure of whether a change did anything. `effect`
    says what the loop intended; this says what the firmware did.

    Indexed by position, never by round number: a resumed workspace restarts its
    numbering, so `round` is not unique across the file and keying on it silently
    merged two different rounds into one verdict.
    """
    out = []
    prev = None
    for row in rows:
        sig = fingerprint(row)
        out.append(None if prev is None else (sig != prev))
        prev = sig
    return out


def section_where(obs, ladder):
    lines = ["## 1. 어디까지 갔나", ""]
    if not obs:
        lines += ["**observation.json 이 없습니다** — 회차가 한 번도 완료되지 않았거나",
                  "워크스페이스가 다른 위치입니다. 아래 항목은 판정할 수 없습니다.", ""]
        return lines
    reached = obs.get("milestones_reached") or []
    best = obs.get("best_progress") or {}
    rungs = []
    for rung in (ladder or []):
        rungs.append(f"~~{rung}~~" if rung in reached else f"**{rung}**")
    lines += [
        "| 항목 | 값 |", "|---|---|",
        f"| 목표 | {esc(obs.get('goal'))} |",
        f"| 사다리 | {' → '.join(rungs) if rungs else '(미지정)'} |",
        f"| 도달한 칸 | {esc(', '.join(reached)) if reached else '없음'} |",
        f"| 최고 마일스톤 | {esc(obs.get('best_milestone')) or '없음'} |",
        f"| 최고 부팅 깊이 | 콘솔 고유 줄 {esc(best.get('uniq'))} (회차 {esc(best.get('round'))}) |",
        f"| 마지막 회차 | {esc(obs.get('round'))} |",
        f"| 정지 | {'예' if obs.get('stop') else '아니오'} — {esc(obs.get('stop_reason')) or '사유 없음'} |",
        "",
    ]
    if obs.get("timeout_bound"):
        lines += ["> `timeout_bound=true` — 더 오래 돌리니 콘솔이 더 나왔습니다.",
                  "> 그 벽은 펌웨어가 아니라 **우리 실행 시간**입니다. fixer 를 보내지 마십시오.", ""]
    return lines


def channel_log_lines(obs):
    """Where the last round's kernel and host logs are, when it had them.

    The UART console alone cannot show a kernel that logs into RAM, and the machine's own
    lines (what it modelled or refused) are not in the console either: a resumed session
    that reads only the console would conclude there was nothing to see. A key that is
    absent or null means the round had no such file, and nothing is printed for it.
    """
    chan = obs.get("channels") or {}
    out = []
    if obs.get("kernel_log"):
        out.append(f"- 커널 로그 (메모리 덤프 채널, 게스트 증거, {esc(chan.get('kernel_lines', '?'))} 줄): "
                   f"`{esc(obs.get('kernel_log'))}`")
    if obs.get("host_log"):
        out.append(f"- 호스트 로그 (머신이 한 말, 게스트 증거 아님, {esc(chan.get('host_lines', '?'))} 줄): "
                   f"`{esc(obs.get('host_log'))}`")
    # The task-line shape decides kernel_alive on the memory-dump channel. A resumed session
    # must know when it was not the measured default: a refused shape (too loose) fell back to
    # the default, and a custom one that matched every ring line was never shown to separate
    # the bootloader's lines from the kernel's.
    shape = obs.get("task_regex")
    if isinstance(shape, dict):
        rejected = shape.get("rejected")
        if isinstance(rejected, dict) and rejected.get("pattern"):
            out.append(f"- 커널 태스크 형식: 지정한 `{esc(rejected.get('pattern'))}` 은 너무 느슨해 쓰지 않았고 "
                       f"기본 형식으로 판정했다 ({esc('; '.join(rejected.get('problems') or []))})")
        elif shape.get("custom"):
            out.append(f"- 커널 태스크 형식: 커스텀 `{esc(shape.get('pattern'))}` 로 판정했다"
                       + (" (링의 모든 줄에 맞아 부트로더 줄과 커널 줄을 가르는지 확인되지 않음)"
                          if shape.get("discriminates") is False else ""))
    return out


def section_why(obs):
    lines = ["## 2. 왜 거기서 멈췄나 — 마지막 지문", ""]
    if not obs:
        return lines + ["(observation.json 없음)", ""]
    lines += [
        "| 항목 | 값 |", "|---|---|",
        f"| 최초 예외 종류 | {esc(obs.get('origin_type'))} |",
        f"| ESR | `{esc(obs.get('origin_esr'))}` |",
        f"| FAR (원인) | `{esc(obs.get('origin_far'))}` |",
        f"| ELR (원인) | `{esc(obs.get('origin_elr'))}` |",
        f"| 예외 수 | {esc(obs.get('exceptions'))} |",
        f"| 정체 회차 | {esc(obs.get('stall_count'))} |",
        f"| A↔B 진동 | {'예' if obs.get('oscillating') else '아니오'} |",
        f"| 무효 변경 | {esc(obs.get('futile_changes'))} |",
        f"| 층 재검토 필요 | {'예' if obs.get('needs_layer_review') else '아니오'} |",
        "",
        "근거 로그:", "",
        f"- 최초 예외 블록: `{esc(obs.get('origin_block'))}`",
        f"- 콘솔: `{esc(obs.get('console'))}`",
        f"- 트레이스: `{esc(obs.get('trace'))}`",
    ]
    lines += channel_log_lines(obs) + [""]
    if obs.get("far") not in (None, "none"):
        lines += ["> 마지막 FAR/ELR (`%s` / `%s`) 은 **재귀의 위치이지 원인이 아닙니다.**"
                  % (esc(obs.get("far")), esc(obs.get("elr"))),
                  "> 진단 입력으로 쓰지 마십시오 — 위의 origin 이 원인입니다.", ""]
    return lines


def section_blockers(blockers, obs):
    lines = ["## 3. 하드 블로커 (사실로 감지됨)", ""]
    rows = list(blockers)
    for code in (obs or {}).get("blockers") or []:
        if not any(b.get("code") == code for b in rows):
            rows.append({"code": code, "detail": "(observation 에만 기록됨)"})
    if not rows:
        return lines + ["없음. 구조상 도달 불가로 판정된 것이 없습니다.", ""]
    lines += ["| 코드 | 상세 | 시각 |", "|---|---|---|"]
    for b in rows:
        lines.append(f"| `{esc(b.get('code'))}` | {esc(b.get('detail'))} | {esc(b.get('ts'))} |")
    return lines + [""]


def section_tried(rounds):
    lines = ["## 4. 시도한 변경 전부 — 지문을 움직였나", ""]
    if not rounds:
        return lines + ["`rounds.jsonl` 이 없습니다 — 기록된 회차가 없습니다.", ""]
    mv = moved(rounds)
    lines += ["| # | 회차 | 정지점 | fixer | 변경 | 효과 | 지문 이동 | 왜 그 변경인지 |",
              "|---|---|---|---|---|---|---|---|"]
    for i, row in enumerate(rounds):
        n = row.get("round")
        m = mv[i]
        mark = "—" if m is None else ("**이동**" if m else "불변")
        why = row.get("rationale")
        why = esc(why) if why else ("⚠ **미기록**" if row.get("fixer") else "—")
        lines.append(
            f"| {i + 1} | {esc(n)} | {esc(row.get('category'))} | {esc(row.get('fixer'))} "
            f"| `{esc(row.get('change_key'))}` | {esc(row.get('effect'))} | {mark} | {why} |")
    unexplained = sum(1 for r in rounds if r.get("fixer") and not r.get("rationale"))
    lines.append("")
    if unexplained:
        lines += [f"> ⚠ **{unexplained} 회차가 이유 없이 기록되었습니다.** 그 회차들은 왜 그 변경을",
                  "> 했는지 되짚을 수 없습니다. fixer 는 `rationale` 을 반드시 남겨야 합니다.", ""]
    return lines


def section_resolutions(res):
    lines = ["## 5. 풀린 정지점", ""]
    if not res:
        return lines + ["기록된 해결이 없습니다.", ""]
    lines += ["| 정지점 | 시도 | 해결 | 근거 | 회차 |", "|---|---|---|---|---|"]
    for r in res:
        lines.append(f"| `{esc(r.get('stop'))}` | {esc(r.get('tried'))} | {esc(r.get('fix'))} "
                     f"| {esc(r.get('evidence'))} | {esc(r.get('rounds'))} |")
    return lines + [""]


def section_left(workdir, rounds, resolutions):
    lines = ["## 6. 아직 안 써본 수단", ""]
    solved = {r.get("stop") for r in resolutions}
    # Not stop points: `reached` marks success, `unknown` means the classifier
    # declined to name one, `none` is the absence of a category. Listing them as
    # unfinished work sends the next session after things that were never faults.
    NOT_A_STOP = {"reached", "unknown", "none", None, ""}
    seen, open_stops = set(), []
    for row in rounds:
        cat = row.get("category")
        if cat and cat not in seen:
            seen.add(cat)
            if cat not in solved and cat not in NOT_A_STOP:
                open_stops.append(cat)
    if open_stops:
        lines += ["**미해결 정지점** (해결 기록이 없는 분류):", ""]
        lines += [f"- `{esc(c)}`" for c in open_stops] + [""]
    else:
        lines += ["미해결로 남은 분류가 없습니다.", ""]

    cand = os.path.join(workdir, "fixer_candidates.md")
    if os.path.exists(cand):
        try:
            body = open(cand, encoding="utf-8").read().strip()
        except OSError:
            body = ""
        n = body.count("\n## ") + (1 if body.startswith("## ") else 0)
        lines += [f"**fixer 승격 후보**: `fixer_candidates.md` 에 {n or '여러'} 건. "
                  "전담 fixer 로 만들면 다음 회차가 짧아집니다.", ""]
    else:
        lines += ["`fixer_candidates.md` 없음 — fixer-general 이 처리한 사례가 없습니다.", ""]
    return lines


def section_prompts(prompts):
    lines = ["## 7. 사용자 지시 이력", ""]
    if not prompts:
        return lines + ["기록된 사용자 입력이 없습니다 (자율 실행만 있었거나 배선 전).", ""]
    lines += ["| 시각 | phase | round | 입력 (첫 줄) |", "|---|---|---|---|"]
    for p in prompts:
        lines.append(f"| {esc(p.get('ts'))} | {esc(p.get('phase'))} | {esc(p.get('round'))} "
                     f"| {first_line(p.get('text'))} |")
    return lines + ["", "> 원문 전체는 `prompts.jsonl` 과 `JOURNAL.md` 의 `[PROMPT]` 블록에 있습니다.", ""]


def section_resume(workdir, obs, command):
    lines = ["## 8. 재개", ""]
    stop_reason = (obs or {}).get("stop_reason")
    if stop_reason:
        lines += [f"정지 코드: `{esc(stop_reason)}`", ""]
        if str(stop_reason).startswith("BLOCKED_"):
            lines += ["> 이 코드는 **구조상 도달 불가**를 뜻합니다. 같은 목표로 재개하면 같은 곳에서",
                      "> 멈춥니다. 목표를 낮추거나, 블로커가 사실이 아님을 도출로 뒤집어야 합니다.", ""]
        elif stop_reason == "EXHAUSTED":
            lines += ["> 시도 소진입니다. **새 사실 없이 재개하면 같은 결과**입니다.",
                      "> static-analyzer 재도출이나 새 fixer 없이는 회차만 소모됩니다.", ""]
        else:
            lines += ["> 런타임 한계입니다 — 도달 불가가 아닙니다. 그대로 재개하면 이어집니다.", ""]
    lines += ["```bash", f"{command}", "```", ""]
    lines += ["재개 전에 §4 의 `지문 이동 = 불변` 행을 보십시오. 그 변경들은 **다시 시도해도**",
              "**같은 결과**이며, `change_key` 가 같으면 파이프라인이 거부합니다.", ""]
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workdir")
    ap.add_argument("--ladder", default="", help="쉼표로 구분한 목표 사다리")
    ap.add_argument("--command", default="/sboot-rehost:start",
                    help="재개에 쓸 명령 한 줄")
    args = ap.parse_args()
    wd = args.workdir

    obs = read_json(os.path.join(wd, "observation.json"))
    rounds = read_jsonl(os.path.join(wd, "rounds.jsonl"))
    blockers = read_jsonl(os.path.join(wd, "blockers.jsonl"))
    resolutions = read_jsonl(os.path.join(wd, "resolutions.jsonl"))
    prompts = read_jsonl(os.path.join(wd, "prompts.jsonl"))
    ladder = [x.strip() for x in args.ladder.split(",") if x.strip()]

    now = datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
    out = [
        f"# RESUME — {os.path.basename(os.path.abspath(wd))}",
        "",
        "> 정지 시 **자동 생성**됩니다. 손으로 고치지 마십시오 — 다음 정지에 덮어쓰입니다.",
        "> 정지는 포기가 아니라 인계입니다. 아래는 인계에 필요한 전부입니다.",
        f"> 생성: {now}",
        "",
    ]
    out += section_where(obs, ladder)
    out += section_why(obs)
    out += section_blockers(blockers, obs)
    out += section_tried(rounds)
    out += section_resolutions(resolutions)
    out += section_left(wd, rounds, resolutions)
    out += section_prompts(prompts)
    out += section_resume(wd, obs, args.command)

    path = os.path.join(wd, "RESUME.md")
    os.makedirs(wd, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out).rstrip() + "\n")
    print(f"make_resume: {path}")


if __name__ == "__main__":
    main()
