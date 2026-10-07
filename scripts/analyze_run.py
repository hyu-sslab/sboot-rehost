#!/usr/bin/env python3
"""analyze_run.py - turn the recorded measurements into a run analysis.

Why this exists
---------------
The workspace already records everything a round did: `rounds.jsonl` holds one
line per round (stop point, classification, fixer, change, effect),
`metrics.jsonl` holds the timing and cumulative token count per stage, and
`blockers.jsonl` holds the hard blockers. What was missing was the reading:
the export carried elapsed time and a token total and nothing that answered
"where did the time actually go, which stop point cost the most rounds, and
why".

Those answers are derivable, not a matter of opinion:

  - a round's wall time is the gap between consecutive round records;
  - its token cost is the difference of the cumulative totals;
  - the stop point it was working on is its fingerprint signature, computed the
    same way `stop_conditions.py` computes it, so the counts here and the stall
    counts the loop acted on cannot drift apart;
  - a stretch of rounds sharing one signature is, by definition, the stretch
    where the run made no progress.

Every figure below is a measurement or an arithmetic consequence of one. Where a
record is missing or ambiguous the report says so under "기록의 한계" instead of
filling the gap.

Usage:
  analyze_run.py <workdir> [--top N]

Writes:
  <workdir>/ANALYSIS.md    the report people read
  <workdir>/analysis.json  the same figures, for further processing
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Reuse the loop's own definition of a stop point's identity. Restating it here
# would let the two drift, and then this report would count stalls the loop
# never saw - or miss the ones it acted on.
from stop_conditions import fingerprint  # noqa: E402

PHASE_ORDER = ["Start", "Analyze", "Build", "Loop", "Run", "Verify", "Package"]


# --- reading -----------------------------------------------------------------
def read_jsonl(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def read_json(path, default=None):
    if not os.path.exists(path):
        return default
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def input_slots(workdir):
    """The INPUT.md slot table, so the report can name what was analysed."""
    path = os.path.join(workdir, "INPUT.md")
    slots = {}
    if not os.path.exists(path):
        return slots
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = [p.strip() for p in line.strip().strip("|").split("|")]
            if len(parts) == 2 and parts[0] and not parts[0].startswith("-"):
                slots.setdefault(parts[0], parts[1])
    return slots


# --- formatting --------------------------------------------------------------
def hms(seconds):
    if seconds is None:
        return "-"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}시간 {m}분 {s}초"
    if m:
        return f"{m}분 {s}초"
    return f"{s}초"


def pct(part, whole):
    if not whole:
        return "-"
    return f"{100.0 * part / whole:.1f}%"


def thousands(value):
    return "-" if value is None else f"{int(value):,}"


def cell(text, width=None):
    """Table-cell safe: a pipe inside a value would shift every later column."""
    text = "-" if text is None else str(text)
    text = text.replace("|", "\\|").replace("\n", " ")
    if width and len(text) > width:
        text = text[: width - 1] + "…"
    return text


# --- derivation --------------------------------------------------------------
def split_series(rounds):
    """Group rounds into execution series.

    The round counter starts at 1 whenever the pipeline is invoked again, so a
    resumed or rebuilt run writes a second `round=1`. Reading the file as one
    sequence would make round 1 look like it happened twice and would pair the
    wrong records when measuring durations. Sequence order is authoritative;
    the printed round number is not.
    """
    series, current, last = [], [], None
    for row in rounds:
        number = row.get("round")
        if last is not None and isinstance(number, int) and number <= last:
            series.append(current)
            current = []
        current.append(row)
        if isinstance(number, int):
            last = number
    if current:
        series.append(current)
    return series


NON_ROUND_PHASES = ("Analyze", "Build", "Verify", "Package")


def stage_intervals(metrics):
    """Spans of work that belong to a stage, not to a round.

    A re-derivation or a machine rebuild happens between two round records, so
    the naive gap charges all of it to the round that follows. On the S921N run
    that put 1 시간 27 분 of re-analysis and rebuild onto a single round and made
    it look like the most expensive round of the whole session. These intervals
    are subtracted so a round's figure is the round's own work.
    """
    events = [m for m in metrics if isinstance(m.get("epoch"), int)]
    events.sort(key=lambda m: m["epoch"])
    spans, prev, last_total = [], None, None
    for row in events:
        here = row.get("tokens_total")
        tokens = 0
        if isinstance(here, int):
            tokens = here - last_total if isinstance(last_total, int) else here
            tokens = max(tokens, 0)
            last_total = here
        if prev is not None and row.get("phase") in NON_ROUND_PHASES:
            spans.append({"start": prev["epoch"], "end": row["epoch"],
                          "phase": row.get("phase"), "tokens": tokens})
        prev = row
    return spans


def overlap(spans, start, end):
    """Seconds and tokens of stage work inside a round's window."""
    if not isinstance(start, int) or not isinstance(end, int) or end <= start:
        return 0, 0
    seconds = tokens = 0
    for span in spans:
        lo, hi = max(span["start"], start), min(span["end"], end)
        if hi <= lo:
            continue
        seconds += hi - lo
        width = span["end"] - span["start"]
        # Tokens are only known for the whole span, so charge them in proportion
        # to the part that falls inside the window.
        tokens += span["tokens"] * (hi - lo) / width if width else span["tokens"]
    return seconds, int(tokens)


def annotate_rounds(rounds, metrics):
    """Attach duration, token cost, signature and effect-on-fingerprint.

    A round's record is written when the round ends, so the gap between two
    consecutive records is the wall time of the later one, minus any stage work
    that happened in between. The first round is measured from the last stage
    event that preceded it (normally the build), because that is when the loop
    actually started.
    """
    prior = None
    for row in metrics:
        if row.get("event") in ("build_end", "analyze_end", "session_start"):
            if isinstance(row.get("epoch"), int):
                prior = row
    baseline_epoch = prior.get("epoch") if prior else None
    baseline_tokens = prior.get("tokens_total") if prior else None
    spans = stage_intervals(metrics)

    # Which execution series each round belongs to. The round number alone is
    # ambiguous once the counter has restarted, so every label the report prints
    # carries the series when there is more than one.
    series = split_series(rounds)
    multi = len(series) > 1
    series_of, position = {}, 0
    for number, block in enumerate(series, 1):
        for _ in block:
            series_of[position] = number
            position += 1

    signatures = [fingerprint(r) for r in rounds]
    out = []
    for i, row in enumerate(rounds):
        prev_epoch = rounds[i - 1].get("epoch") if i else baseline_epoch
        prev_tokens = rounds[i - 1].get("tokens_total") if i else baseline_tokens
        epoch = row.get("epoch")
        tokens = row.get("tokens_total")

        raw_duration = (epoch - prev_epoch) if (isinstance(epoch, int)
                                                and isinstance(prev_epoch, int)) else None
        raw_cost = (tokens - prev_tokens) if (isinstance(tokens, int)
                                              and isinstance(prev_tokens, int)) else None
        stage_seconds, stage_tokens = overlap(spans, prev_epoch, epoch)
        duration = max(raw_duration - stage_seconds, 0) if raw_duration is not None else None
        cost = max(raw_cost - stage_tokens, 0) if raw_cost is not None else None
        # A change is judged by the NEXT round's fingerprint: that is the first
        # observation taken after it was built into the image.
        moved = None
        if row.get("effect") == "applied" and i + 1 < len(rounds):
            moved = signatures[i + 1] != signatures[i]

        out.append({
            "index": i,
            "round": row.get("round"),
            "series": series_of.get(i, 1),
            # What every table prints. "2-3" reads as "second execution series,
            # round 3", which is the only unambiguous way to name a round once
            # the counter has restarted.
            "label": (f"{series_of.get(i, 1)}-{row.get('round')}" if multi
                      else str(row.get("round"))),
            "goal": row.get("goal"),
            "signature": signatures[i],
            "category": row.get("category"),
            "fixer": row.get("fixer"),
            "change_key": row.get("change_key"),
            "effect": row.get("effect"),
            # Why that change. Carried through so the report can separate a round
            # that was reasoned about from one that merely happened.
            "rationale": row.get("rationale"),
            "rationale_missing": row.get("rationale_missing"),
            "analyst_new_facts": row.get("analyst_new_facts"),
            "fixer_no_new_change": row.get("fixer_no_new_change"),
            "origin_esr": row.get("fp_origin_esr"),
            "origin_far": row.get("fp_origin_far"),
            "origin_elr": row.get("fp_origin_elr"),
            "milestone": row.get("fp_milestone"),
            "uniq": row.get("fp_uniq"),
            "bytes": row.get("fp_bytes"),
            "exceptions": row.get("fp_exc"),
            "epoch": epoch,
            "duration_s": duration,
            "tokens": cost,
            # Kept so the report can show what was taken out and why, instead of
            # quietly shrinking a number the reader can check against the journal.
            "raw_duration_s": raw_duration,
            "stage_seconds": stage_seconds,
            "stage_tokens": stage_tokens,
            "tokens_total": tokens,
            "moved_fingerprint": moved,
            "ts": row.get("ts"),
        })
    return out


def phase_costs(metrics):
    """Attribute each interval between stage events to the stage that ended it.

    `tokens_total` is cumulative, so a stage's own cost is the difference from
    the previous event. Intervals with no token figure are counted for time
    only, and that gap is reported rather than smoothed over.
    """
    events = [m for m in metrics if isinstance(m.get("epoch"), int)]
    events.sort(key=lambda m: m["epoch"])
    stats = {}
    prev = None
    last_total = None
    for row in events:
        phase = row.get("phase") or "기타"
        entry = stats.setdefault(phase, {"seconds": 0, "tokens": 0, "events": 0})
        entry["events"] += 1
        if prev is not None:
            entry["seconds"] += row["epoch"] - prev["epoch"]
        # Only some events carry the cumulative total - a QEMU run does not spend
        # tokens, so `run_end` has none. Comparing neighbours therefore threw the
        # delta away whenever an event without a total sat between two with one,
        # and every stage but the first reported zero. Carry the last known total
        # forward instead: the cost belongs to the stage that reports the rise.
        here = row.get("tokens_total")
        if isinstance(here, int):
            if isinstance(last_total, int):
                if here >= last_total:
                    entry["tokens"] += here - last_total
            else:
                entry["tokens"] += here      # first report is everything so far
            last_total = here
        prev = row
    return stats


def group_by_signature(annotated):
    """Rounds that shared one stop point, with what the run spent on it."""
    groups = {}
    for row in annotated:
        key = row["signature"]
        entry = groups.setdefault(key, {
            "signature": key, "rounds": [], "seconds": 0, "tokens": 0,
            "categories": [], "changes": [], "fixers": [],
        })
        entry["rounds"].append(row["label"])
        entry["seconds"] += row["duration_s"] or 0
        entry["tokens"] += row["tokens"] or 0
        for field, bucket in (("category", "categories"),
                              ("change_key", "changes"), ("fixer", "fixers")):
            value = row.get(field)
            if value and value not in entry[bucket]:
                entry[bucket].append(value)
    return sorted(groups.values(), key=lambda g: (-g["seconds"], -len(g["rounds"])))


def stall_stretches(annotated, minimum=2):
    """Consecutive rounds with an identical stop point, and what ended each.

    This is the direct measurement of "where the run got stuck": the loop kept
    producing rounds and the observation did not change.
    """
    stretches, start = [], 0
    for i in range(1, len(annotated) + 1):
        same = (i < len(annotated)
                and annotated[i]["signature"] == annotated[start]["signature"])
        if same:
            continue
        length = i - start
        if length >= minimum:
            block = annotated[start:i]
            stretches.append({
                "from_round": block[0]["label"],
                "to_round": block[-1]["label"],
                "rounds": length,
                "seconds": sum(r["duration_s"] or 0 for r in block),
                "tokens": sum(r["tokens"] or 0 for r in block),
                "signature": block[0]["signature"],
                "categories": sorted({r["category"] for r in block if r["category"]}),
                "changes": [r["change_key"] for r in block if r["change_key"]],
                "escaped_by": (annotated[i]["change_key"] if i < len(annotated) else None),
                "escaped_at_round": (annotated[i]["label"] if i < len(annotated) else None),
            })
        start = i
    return sorted(stretches, key=lambda s: -s["seconds"])


def depth_jumps(annotated):
    """Rounds where the boot went measurably deeper.

    On a one-rung ladder the milestone stays "none" for the whole run, so
    distinct console lines are the only forward signal there is.
    """
    jumps, best = [], 0
    for row in annotated:
        uniq = row.get("uniq") or 0
        if uniq > best:
            jumps.append({"round": row["label"], "uniq": uniq, "gain": uniq - best,
                          "change_key": row["change_key"], "category": row["category"]})
            best = uniq
    return sorted(jumps, key=lambda j: -j["gain"])


def attribute_cost(annotated, stretches, groups, blockers, total_seconds):
    """Why the run took as long as it did, with the figure behind each claim.

    Each item is an observation, its cost, and the record it came from. Nothing
    here is a judgement about whether the time was well spent - that reading is
    the reader's, and it needs the numbers, not an adjective.
    """
    findings = []

    for stretch in stretches[:3]:
        share = pct(stretch["seconds"], total_seconds)
        findings.append({
            "제목": f"동일한 정지점에서 {stretch['rounds']}회차 연속 정체",
            "관측": (f"회차 {stretch['from_round']}–{stretch['to_round']} 의 관측이 "
                     f"완전히 같았습니다. 분류: {', '.join(stretch['categories']) or '기록 없음'}"),
            "비용": f"{hms(stretch['seconds'])} (전체의 {share}), {thousands(stretch['tokens'])} 토큰",
            "탈출": (f"회차 {stretch['escaped_at_round']} 의 `{stretch['escaped_by']}` 에서 "
                     f"관측이 바뀌었습니다"
                     if stretch["escaped_by"] else "이 구간 이후 기록이 없습니다"),
            "근거": f"rounds.jsonl — 정지점 서명 `{cell(stretch['signature'], 80)}`",
        })

    futile = [r for r in annotated if r["moved_fingerprint"] is False]
    if futile:
        seconds = sum(r["duration_s"] or 0 for r in futile)
        findings.append({
            "제목": f"관측을 움직이지 못한 변경 {len(futile)}건",
            "관측": ("변경을 적용하고 다시 실행했으나 다음 회차의 관측이 직전과 동일했습니다. "
                     "해당 회차: " + ", ".join(f"{r['label']}({r['change_key']})" for r in futile[:8])
                     + (" 외" if len(futile) > 8 else "")),
            "비용": f"{hms(seconds)} (전체의 {pct(seconds, total_seconds)})",
            "탈출": "-",
            "근거": "rounds.jsonl — effect=applied 이면서 다음 회차 서명이 불변",
        })

    unknown = [r for r in annotated if r["category"] in ("unknown", None)]
    if unknown:
        seconds = sum(r["duration_s"] or 0 for r in unknown)
        findings.append({
            "제목": f"정지점을 이름 붙이지 못한 회차 {len(unknown)}건",
            "관측": (f"전체 {len(annotated)}회차 중 {pct(len(unknown), len(annotated))} 가 "
                     f"`unknown` 으로 분류되어 재도출로 넘어갔습니다. "
                     f"해당 회차: {', '.join(r['label'] for r in unknown[:10])}"),
            "비용": f"{hms(seconds)} (전체의 {pct(seconds, total_seconds)})",
            "탈출": "-",
            "근거": "rounds.jsonl — category 필드",
        })

    dry = [r for r in annotated if r["analyst_new_facts"] == 0]
    if dry:
        findings.append({
            "제목": f"재도출이 새 사실을 내지 못한 회차 {len(dry)}건",
            "관측": ("정적 분석을 다시 돌렸으나 도출표에 새 줄이 늘지 않았습니다. "
                     f"해당 회차: {', '.join(r['label'] for r in dry[:10])}"),
            "비용": (f"해당 회차들의 총 소요 {hms(sum(r['duration_s'] or 0 for r in dry))} "
                     f"(재도출에만 쓴 시간은 따로 기록되지 않습니다)"),
            "탈출": "-",
            "근거": "rounds.jsonl — analyst_new_facts=0 (derived_facts.py 가 센 값)",
        })

    build_layer = [r for r in annotated if r["category"] == "build_layer"]
    for row in build_layer:
        before = [s for s in stretches if s["escaped_at_round"] == row["label"]]
        cost = f"{hms(before[0]['seconds'])} ({before[0]['rounds']}회차)" if before else "-"
        findings.append({
            "제목": f"회차 {row['label']} 에서 머신 전제를 다시 잡음 (재생성)",
            "관측": (f"루프 안의 변경으로는 닿지 않는 전제가 원인이었습니다. "
                     f"적용한 변경: `{row['change_key']}`"),
            "비용": f"그 전까지 같은 정지점에 쓴 시간 {cost}",
            "탈출": "재생성 이후 관측이 바뀌었습니다",
            "근거": "rounds.jsonl — category=build_layer",
        })

    general = [r for r in annotated if r["fixer"] == "fixer-general"]
    if general:
        findings.append({
            "제목": f"담당 fixer 가 없어 최후수단으로 처리한 회차 {len(general)}건",
            "관측": ("전문 fixer 가 전원 반려했거나 담당이 지정되지 않은 정지점입니다. "
                     f"해당 회차: {', '.join(r['label'] for r in general)}"),
            "비용": f"{hms(sum(r['duration_s'] or 0 for r in general))}",
            "탈출": "-",
            "근거": "rounds.jsonl — fixer=fixer-general",
        })

    starved = [r for r in annotated if r["category"] == "harness_input_starved"]
    if starved:
        findings.append({
            "제목": f"입력이 게이트에 닿지 않아 다시 실행한 회차 {len(starved)}건",
            "관측": "펌웨어가 콘솔을 폴링했으나 하니스가 보낸 바이트를 읽지 못했습니다.",
            "비용": f"{hms(sum(r['duration_s'] or 0 for r in starved))}",
            "탈출": "-",
            "근거": "rounds.jsonl — category=harness_input_starved (펌웨어 관측이 아님)",
        })

    for blocker in blockers:
        findings.append({
            "제목": f"하드 블로커 {blocker.get('code')}",
            "관측": str(blocker.get("detail", "")),
            "비용": "이 시점에서 실행이 정지했습니다",
            "탈출": "-",
            "근거": "blockers.jsonl",
        })

    if groups:
        widest = max(groups, key=lambda g: len(g["changes"]))
        if len(widest["changes"]) >= 3:
            findings.append({
                "제목": f"한 정지점에 서로 다른 변경 {len(widest['changes'])}건을 시도",
                "관측": "같은 관측에 대해 여러 처방을 차례로 시도했습니다: "
                        + ", ".join(f"`{c}`" for c in widest["changes"][:8]),
                "비용": f"{hms(widest['seconds'])}, {thousands(widest['tokens'])} 토큰",
                "탈출": "-",
                "근거": f"rounds.jsonl — 서명 `{cell(widest['signature'], 80)}`",
            })

    return findings


def data_caveats(rounds, series, metrics, annotated):
    """What the records cannot support, stated rather than smoothed over."""
    notes = []
    if len(series) > 1:
        sizes = ", ".join(str(len(s)) for s in series)
        notes.append(
            f"**회차 번호가 {len(series)}번 다시 1부터 시작합니다** (구간별 회차 수: {sizes}). "
            "파이프라인을 다시 호출하면 번호가 초기화되고, 회차별 산출물"
            "(`07_logs/console_N.txt`, 트레이스, 소스 스냅샷)이 같은 이름으로 덮입니다. "
            "이 보고서는 기록 순서를 기준으로 세므로 집계는 정확하지만, "
            "**번호만으로 특정 회차의 원본 로그를 찾을 수는 없습니다.**")
    missing_tokens = [r for r in annotated if r["tokens"] is None]
    if missing_tokens:
        notes.append(
            f"토큰 기록이 없는 회차가 {len(missing_tokens)}건 있어 비용 합계에서 빠졌습니다.")
    missing_time = [r for r in annotated if r["duration_s"] is None]
    if missing_time:
        notes.append(
            f"시각 기록이 없는 회차가 {len(missing_time)}건 있어 소요 합계에서 빠졌습니다.")
    if not metrics:
        notes.append("`metrics.jsonl` 이 없어 단계별 소요와 비용을 낼 수 없습니다.")
    if not rounds:
        notes.append("`rounds.jsonl` 이 없어 회차 분석을 낼 수 없습니다.")
    negative = [r for r in annotated if (r["duration_s"] or 0) < 0]
    if negative:
        notes.append(
            f"소요가 음수로 계산된 회차가 {len(negative)}건 있습니다. "
            "기록 순서와 시각이 어긋난 것이므로 해당 값은 신뢰하지 마십시오.")
    notes.append(
        "회차 소요는 **회차 기록 시각 사이의 간격**입니다. QEMU 실행 시간"
        "(`metrics.jsonl` 의 `elapsed_s`)은 그중 일부이며, 나머지는 분석·판단·"
        "빌드에 쓰인 시간입니다.")
    return notes


# --- report ------------------------------------------------------------------
def render(workdir, data):
    slots = data["slots"]
    annotated = data["rounds"]
    total_seconds = data["total_seconds"]
    total_tokens = data["total_tokens"]
    out = []
    add = out.append

    add("# 실행 분석 — 소요 시간과 비용의 근거\n")
    add("이 문서는 `rounds.jsonl` · `metrics.jsonl` · `blockers.jsonl` 에 기록된 "
        "측정값만으로 작성됐습니다. 모든 수치는 기록된 값이거나 그 값들의 산술 결과이며, "
        "기록이 없는 항목은 채우지 않고 마지막 절에 한계로 밝힙니다.\n")

    # 1
    add("## 1. 개요\n")
    add("| 항목 | 값 |")
    add("|---|---|")
    for label, key in (("모델", "model"), ("빌드", "build"), ("SoC", "soc"),
                       ("부트로더", "bootloader"), ("목표 등급", "target")):
        if slots.get(key):
            add(f"| {label} | {cell(slots[key])} |")
    add(f"| 기록된 회차 | {len(annotated)}회 |")
    add(f"| 실행 구간 | {len(data['series'])}개 |")
    add(f"| 측정 구간 | {cell(data['first_ts'])} ~ {cell(data['last_ts'])} |")
    add(f"| 총 소요 | {hms(total_seconds)} |")
    add(f"| 총 토큰 | {thousands(total_tokens)} |")
    add(f"| 회차당 평균 소요 | {hms(total_seconds / len(annotated)) if annotated else '-'} |")
    add(f"| 회차당 평균 토큰 | {thousands(total_tokens / len(annotated)) if annotated and total_tokens else '-'} |")
    if data["verdict"]:
        add(f"| 스크립트 1차 판정 | {data['verdict']['passes']}/{data['verdict']['total']} "
            f"({data['verdict']['verdict']}) |")
    if data["best_milestone"]:
        add(f"| 도달한 최고 마일스톤 | {cell(data['best_milestone'])} |")
    add(f"| 최고 부팅 깊이 | 콘솔 고유 {thousands(data['best_uniq'])} 줄 |")
    if data.get("prompts"):
        add(f"| 기록된 사용자 지시 | {len(data['prompts'])}건 |")
    add("")

    # 2
    add("## 2. 단계별 소요와 비용\n")
    if data["phases"]:
        add("| 단계 | 소요 | 소요 비율 | 토큰 | 토큰 비율 | 기록 이벤트 |")
        add("|---|---:|---:|---:|---:|---:|")
        ordered = sorted(data["phases"].items(),
                         key=lambda kv: PHASE_ORDER.index(kv[0])
                         if kv[0] in PHASE_ORDER else 99)
        for name, value in ordered:
            add(f"| {cell(name)} | {hms(value['seconds'])} | "
                f"{pct(value['seconds'], total_seconds)} | {thousands(value['tokens'])} | "
                f"{pct(value['tokens'], total_tokens)} | {value['events']} |")
        add("")
        add("- 단계 소요는 **직전 기록 이벤트부터 그 단계의 기록 이벤트까지**의 간격입니다.")
        add("- `Run` 은 QEMU 실행 자체, `Loop` 는 그 결과를 판단하고 변경을 적용해 "
            "다시 빌드하기까지를 가리킵니다.")
    else:
        add("`metrics.jsonl` 에 단계 기록이 없습니다.")
    add("")

    # 3
    add(f"## 3. 소요가 길었던 회차 (상위 {data['top']}건)\n")
    if annotated:
        add("| 순위 | 회차 | 분류 | 담당 | 적용한 변경 | 회차 소요 | 토큰 | 관측 변화 | 사이에 낀 재분석·재생성 |")
        add("|---:|---:|---|---|---|---:|---:|---|---:|")
        ranked = sorted([r for r in annotated if r["duration_s"] is not None],
                        key=lambda r: -r["duration_s"])[:data["top"]]
        for rank, row in enumerate(ranked, 1):
            moved = {True: "바뀜", False: "불변", None: "-"}[row["moved_fingerprint"]]
            stage = hms(row["stage_seconds"]) if row["stage_seconds"] else "-"
            add(f"| {rank} | {row['label']} | {cell(row['category'], 28)} | "
                f"{cell(row['fixer'], 18)} | {cell(row['change_key'], 40)} | "
                f"{hms(row['duration_s'])} | {thousands(row['tokens'])} | {moved} | {stage} |")
        add("")
        add("- **관측 변화**는 그 변경을 적용한 뒤 다음 회차의 정지점이 달라졌는지입니다. "
            "`불변` 은 그 회차의 시간이 진단을 바꾸지 못했다는 뜻입니다.")
        add("- **회차 소요**에서 재분석·재생성 구간은 빼놓았습니다. 그 작업은 회차가 아니라 "
            "단계에 속하며, 빼지 않으면 재생성 직후 회차 하나가 세션에서 가장 비싼 회차처럼 "
            "보입니다. 빠진 양은 마지막 열에 그대로 적었고 2절의 단계 집계에 들어 있습니다.")
    add("")

    # 4
    add("## 4. 가장 오래 머문 정지점\n")
    add("정지점의 동일성은 루프가 정체를 판정할 때 쓰는 것과 같은 기준"
        "(최초 예외의 ESR/FAR/ELR · 마일스톤 · 콘솔 규모 · 예외 수 자릿수)으로 셌습니다.\n")
    top_groups = data["groups"][:5]
    if top_groups:
        add("| 순위 | 회차 수 | 소요 | 소요 비율 | 토큰 | 분류 | 시도한 변경 수 |")
        add("|---:|---:|---:|---:|---:|---|---:|")
        for rank, group in enumerate(top_groups, 1):
            add(f"| {rank} | {len(group['rounds'])} | {hms(group['seconds'])} | "
                f"{pct(group['seconds'], total_seconds)} | {thousands(group['tokens'])} | "
                f"{cell(', '.join(group['categories']), 40)} | {len(group['changes'])} |")
        add("")
        for rank, group in enumerate(top_groups, 1):
            add(f"### 4-{rank}. 회차 {', '.join(group['rounds'])}\n")
            add(f"- **정지점 서명**: `{cell(group['signature'], 120)}`")
            add(f"- **분류**: {', '.join(group['categories']) or '기록 없음'}")
            add(f"- **담당**: {', '.join(group['fixers']) or '기록 없음'}")
            add(f"- **소요 / 비용**: {hms(group['seconds'])} · {thousands(group['tokens'])} 토큰")
            if group["changes"]:
                add("- **시도한 변경**:")
                for change in group["changes"]:
                    add(f"  - `{cell(change)}`")
            add("")
    else:
        add("집계할 회차 기록이 없습니다.\n")

    # 5
    add("## 5. 정체 구간 (관측이 연속으로 같았던 구간)\n")
    if data["stretches"]:
        add("| 구간 | 회차 수 | 소요 | 소요 비율 | 토큰 | 분류 | 무엇이 구간을 끝냈나 |")
        add("|---|---:|---:|---:|---:|---|---|")
        for stretch in data["stretches"]:
            add(f"| {stretch['from_round']}–{stretch['to_round']} | {stretch['rounds']} | "
                f"{hms(stretch['seconds'])} | {pct(stretch['seconds'], total_seconds)} | "
                f"{thousands(stretch['tokens'])} | "
                f"{cell(', '.join(stretch['categories']), 30)} | "
                f"{cell(stretch['escaped_by'], 44)} |")
        add("")
        add("- 이 구간들은 회차가 계속 돌았는데 관측이 달라지지 않은 구간입니다. "
            "**진단이 정지점을 정확히 짚지 못했거나, 루프가 닿을 수 없는 층의 문제였음**을 "
            "가리키는 직접 측정값입니다.")
    else:
        add("연속으로 동일한 관측이 2회 이상 반복된 구간이 없습니다.")
    add("")

    # 6
    add("## 6. 분류와 담당 분포\n")
    add("| 분류 | 회차 수 | 누적 소요 | 누적 토큰 |")
    add("|---|---:|---:|---:|")
    for name, value in data["by_category"]:
        add(f"| {cell(name)} | {value['count']} | {hms(value['seconds'])} | "
            f"{thousands(value['tokens'])} |")
    add("")
    add("| 담당 | 회차 수 | 관측을 바꾼 회차 | 성공률 |")
    add("|---|---:|---:|---:|")
    for name, value in data["by_fixer"]:
        add(f"| {cell(name)} | {value['count']} | {value['moved']} | "
            f"{pct(value['moved'], value['judged']) if value['judged'] else '-'} |")
    add("")
    add("- **성공률**은 그 담당이 적용한 변경 중 다음 회차의 관측을 바꾼 비율입니다. "
        "관측이 바뀌었다는 것은 정지점이 옮겨졌다는 뜻이지, 목표에 가까워졌다는 "
        "뜻은 아닙니다. 전진 여부는 다음 절에서 따로 봅니다.")
    add("")

    # 7
    add("## 7. 부팅 깊이의 전진\n")
    add("목표 사다리가 한 칸인 등급에서는 마일스톤이 끝까지 `none` 이므로, "
        "콘솔의 고유 줄 수가 유일한 전진 신호입니다.\n")
    if data["jumps"]:
        add("| 회차 | 고유 줄 수 | 증가폭 | 그 회차의 변경 | 분류 |")
        add("|---:|---:|---:|---|---|")
        for jump in data["jumps"][:data["top"]]:
            add(f"| {jump['round']} | {thousands(jump['uniq'])} | +{thousands(jump['gain'])} | "
                f"{cell(jump['change_key'], 40)} | {cell(jump['category'], 28)} |")
        add("")
        add("- 증가폭이 큰 회차가 **실제로 부팅을 전진시킨 변경**입니다. "
            "그 외 회차는 정지점을 옮겼을 뿐 깊이를 늘리지는 못했습니다.")
    else:
        add("깊이가 증가한 회차 기록이 없습니다.")
    add("")

    # 8
    add("## 8. 재도출·전제 재검토·되돌림\n")
    add("| 사건 | 회차 | 내용 |")
    add("|---|---:|---|")
    empty = True
    for row in annotated:
        if row["analyst_new_facts"] is not None and row["analyst_new_facts"] >= 0:
            empty = False
            add(f"| 재도출 | {row['label']} | 도출표에 늘어난 줄 "
                f"{row['analyst_new_facts']}개 |")
        if row["category"] in ("build_layer", "bypass_revert"):
            empty = False
            label = "머신 재생성" if row["category"] == "build_layer" else "우회 철회"
            add(f"| {label} | {row['label']} | `{cell(row['change_key'], 60)}` |")
    if empty:
        add("| - | - | 해당 사건 기록이 없습니다 |")
    add("")

    # 9
    add("## 9. 하드 블로커\n")
    if data["blockers"]:
        add("| 코드 | 내용 | 시각 |")
        add("|---|---|---|")
        for blocker in data["blockers"]:
            add(f"| {cell(blocker.get('code'))} | {cell(blocker.get('detail'), 90)} | "
                f"{cell(blocker.get('ts'))} |")
    else:
        add("사실로 감지된 하드 블로커가 없습니다.")
    add("")

    # 10
    add("## 10. 소요 원인 분석\n")
    add("각 항목은 **관측 → 비용 → 근거** 순으로 적었습니다. 여기서 말하는 비용은 "
        "그 사건에 해당하는 회차들의 소요이며, **항목끼리 겹칠 수 있습니다** — 예를 들어 "
        "정체 구간의 시간과 그 구간에서 관측을 못 움직인 변경의 시간은 같은 회차를 "
        "가리킵니다. 따라서 항목의 비율을 더하면 100%를 넘을 수 있고, 그것은 오류가 "
        "아니라 한 회차가 여러 이유로 길어졌다는 뜻입니다.\n")
    if data["findings"]:
        for i, finding in enumerate(data["findings"], 1):
            add(f"### 10-{i}. {finding['제목']}\n")
            add(f"- **관측**: {finding['관측']}")
            add(f"- **비용**: {finding['비용']}")
            if finding.get("탈출") and finding["탈출"] != "-":
                add(f"- **해소**: {finding['탈출']}")
            add(f"- **근거**: {finding['근거']}")
            add("")
    else:
        add("귀속할 만한 사건이 기록에 없습니다.\n")

    # 11
    add("## 11. 해결 타임라인 — 무엇을 어떻게 풀었나\n")
    add("정지점마다 무엇을 시도했고 무엇이 통했는지입니다. 입력은 `resolutions.jsonl` 과 "
        "`rounds.jsonl` 의 `rationale` 이며, **기록되지 않은 해결은 없는 것과 같으므로** "
        "둘 다 비어 있으면 이 절도 비어 있는 것이 정상입니다.\n")

    add("### 11.1 풀린 정지점\n")
    if data["resolutions"]:
        add("| 정지점 | 시도 | 해결 | 근거 | 회차 |")
        add("|---|---|---|---|---|")
        for r in data["resolutions"]:
            add(f"| {cell(r.get('stop'), 28)} | {cell(r.get('tried'), 40)} | "
                f"{cell(r.get('fix'), 50)} | {cell(r.get('evidence'), 30)} | "
                f"{cell(r.get('rounds'), 12)} |")
    else:
        add("`resolutions.jsonl` 에 기록이 없습니다. 정지점이 풀렸더라도 "
            "**경위가 남지 않아** 다음 펌웨어에 재사용할 수 없습니다.")
    add("")

    named = [r for r in annotated if r["fixer"] and r["fixer"] != "없음"]
    explained = [r for r in named if r.get("rationale")]
    add("### 11.2 회차별 이유 기록률\n")
    add("| 항목 | 값 |")
    add("|---|---|")
    add(f"| fixer 를 지명한 회차 | {len(named)}회 |")
    add(f"| 그중 이유가 기록된 회차 | {len(explained)}회 ({pct(len(explained), len(named))}) |")
    add("")
    if named and len(explained) < len(named):
        add(f"> ⚠ **{len(named) - len(explained)}회차의 변경 이유가 없습니다.** 그 회차들은 "
            "무엇을 왜 바꿨는지 되짚을 수 없어, 같은 정지점을 다시 만났을 때 처음부터 "
            "다시 판단해야 합니다.")
        add("")

    add("### 11.3 이유가 기록된 회차\n")
    if explained:
        add("| 회차 | 정지점 | 적용한 변경 | 관측 변화 | 이유 |")
        add("|---|---|---|---|---|")
        ordered = sorted(explained, key=lambda r: (r["moved_fingerprint"] is not True,))
        for row in ordered:
            moved = {True: "바뀜", False: "불변", None: "-"}[row["moved_fingerprint"]]
            add(f"| {row['label']} | {cell(row['category'], 26)} | "
                f"{cell(row['change_key'], 38)} | {moved} | {cell(row.get('rationale'), 60)} |")
        add("")
        add("- **관측 변화가 `바뀜` 인 행이 실제로 통한 처방**입니다. 다음 펌웨어에서 같은 "
            "정지점을 만나면 여기부터 봅니다.")
        add("- `불변` 인데 이유가 그럴듯했다면, 그 이유가 틀렸다는 기록입니다. 지우지 마십시오.")
    else:
        add("이유가 기록된 회차가 없습니다.")
    add("")

    add("## 12. 기록의 한계\n")
    for note in data["caveats"]:
        add(f"- {note}")
    add("")

    add("---\n")
    add("생성: `scripts/analyze_run.py` · 입력: "
        "`rounds.jsonl`, `metrics.jsonl`, `blockers.jsonl`, `INPUT.md`, "
        "`verdict_script.json`")
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workdir")
    parser.add_argument("--top", type=int, default=10,
                        help="how many entries the ranked tables show")
    args = parser.parse_args()
    workdir = args.workdir

    rounds = read_jsonl(os.path.join(workdir, "rounds.jsonl"))
    metrics = read_jsonl(os.path.join(workdir, "metrics.jsonl"))
    blockers = read_jsonl(os.path.join(workdir, "blockers.jsonl"))
    resolutions = read_jsonl(os.path.join(workdir, "resolutions.jsonl"))
    prompts = read_jsonl(os.path.join(workdir, "prompts.jsonl"))
    verdict = read_json(os.path.join(workdir, "verdict_script.json"))

    series = split_series(rounds)
    annotated = annotate_rounds(rounds, metrics)
    phases = phase_costs(metrics)

    total_seconds = sum(v["seconds"] for v in phases.values())
    if not total_seconds:
        total_seconds = sum(r["duration_s"] or 0 for r in annotated)
    totals = [m.get("tokens_total") for m in metrics if isinstance(m.get("tokens_total"), int)]
    totals += [r.get("tokens_total") for r in rounds if isinstance(r.get("tokens_total"), int)]
    total_tokens = max(totals) if totals else 0

    by_category = {}
    for row in annotated:
        entry = by_category.setdefault(row["category"] or "기록 없음",
                                       {"count": 0, "seconds": 0, "tokens": 0})
        entry["count"] += 1
        entry["seconds"] += row["duration_s"] or 0
        entry["tokens"] += row["tokens"] or 0

    by_fixer = {}
    for row in annotated:
        entry = by_fixer.setdefault(row["fixer"] or "없음",
                                    {"count": 0, "moved": 0, "judged": 0})
        entry["count"] += 1
        if row["moved_fingerprint"] is not None:
            entry["judged"] += 1
            entry["moved"] += 1 if row["moved_fingerprint"] else 0

    groups = group_by_signature(annotated)
    stretches = stall_stretches(annotated)
    milestones = [r["milestone"] for r in annotated
                  if r["milestone"] and r["milestone"] != "none"]

    data = {
        "slots": input_slots(workdir),
        "rounds": annotated,
        "series": series,
        "phases": phases,
        "groups": groups,
        "stretches": stretches,
        "jumps": depth_jumps(annotated),
        "by_category": sorted(by_category.items(), key=lambda kv: -kv[1]["seconds"]),
        "by_fixer": sorted(by_fixer.items(), key=lambda kv: -kv[1]["count"]),
        "blockers": blockers,
        "resolutions": resolutions,
        "prompts": prompts,
        "verdict": verdict,
        "total_seconds": total_seconds,
        "total_tokens": total_tokens,
        "best_milestone": milestones[-1] if milestones else None,
        "best_uniq": max([r["uniq"] or 0 for r in annotated], default=0),
        # The window has to be the one the totals were summed over, or the header
        # would report ten hours between two timestamps four hours apart.
        "first_ts": min(stamps) if (stamps := sorted(
            r.get("ts") for r in (metrics + rounds) if r.get("ts"))) else None,
        "last_ts": max(stamps) if stamps else None,
        "top": args.top,
    }
    data["findings"] = attribute_cost(annotated, stretches, groups, blockers, total_seconds)
    data["caveats"] = data_caveats(rounds, series, metrics, annotated)

    report = render(workdir, data)
    with open(os.path.join(workdir, "ANALYSIS.md"), "w", encoding="utf-8") as fh:
        fh.write(report)

    machine = {k: v for k, v in data.items() if k not in ("slots",)}
    machine["slots"] = data["slots"]
    with open(os.path.join(workdir, "analysis.json"), "w", encoding="utf-8") as fh:
        json.dump(machine, fh, ensure_ascii=False, indent=2)

    print(json.dumps({
        "analysis_md": os.path.join(workdir, "ANALYSIS.md"),
        "analysis_json": os.path.join(workdir, "analysis.json"),
        "rounds": len(annotated),
        "series": len(series),
        "total_seconds": total_seconds,
        "total_tokens": total_tokens,
        "stall_stretches": len(stretches),
        "findings": len(data["findings"]),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
