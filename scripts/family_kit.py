#!/usr/bin/env python3
"""family_kit.py - 계열 자료 묶음(지식표·진행 가이드)을 프로필에서 읽는다.

프로필(profiles/<계열>.yaml)의 최상위 평면 키 두 개를 읽어 JSON 으로 낸다.

    knowledge: [knowledge/faults_mediatek.md]     한 줄 목록 - 이 계열만의 지식표
    runbook: knowledge/runbook_mediatek.md        한 줄 - 에이전트가 따르는 진행 가이드

파이프라인은 계열 자료를 **이 스크립트로만** 읽는다. 공통 지식표(faults_unified.md 등)는
파이프라인이 붙이고, 이 스크립트는 프로필이 선언한 계열 자료만 낸다. 그래서 "새 계열
지식표는 프로필에 한 줄"이 성립하고, 분류기·fixer·supervisor 프롬프트는 고치지 않는다.

PyYAML 없이 동작해야 하므로 stage_map.py 가 stage_hints 를 읽는 것과 같은 방식으로
정규식만 쓴다. 그래서 두 키는 **들여쓰기 없는 한 줄**이어야 한다 (중첩된 같은 이름의
키는 읽지 않는다).

사용법:
  family_kit.py <계열 이름 | 프로필 경로>

  계열 이름이면 profiles/<이름>.yaml 을 읽고, 그 프로필이 없으면 generic 으로 대체하며
  `note` 필드에 그 사실을 적는다. 경로이면 그 파일을 그대로 읽는다.

출력 (stdout, JSON):
  {"family": "mediatek", "profile": "profiles/mediatek.yaml",
   "knowledge": ["knowledge/faults_mediatek.md"],
   "runbook": "knowledge/runbook_mediatek.md"}

  - note     계열 프로필이 없어 generic 으로 대체했다 (대체했을 때만)
  - missing  프로필이 가리키지만 플러그인에 없는 파일 (있을 때만)
  - error    읽지 못한 사유 (종료코드 2 일 때만)

종료 코드:
  0  읽었다. 키가 없으면 knowledge 는 빈 목록, runbook 은 빈 문자열이다
  1  사용법 오류
  2  프로필을 읽지 못했다 (없음, 디렉터리, 인코딩 오류 ...)
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 계열 이름은 파일 이름 한 조각이다. 경로 이탈(`../x`)이 되지 않게 모양을 제한한다.
FAMILY_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")

# 최상위(0열) 평면 키만 읽는다. `kernel:` 아래의 들여쓴 같은 이름은 맞지 않는다.
RE_KNOWLEDGE = re.compile(r"^knowledge:[ \t]*\[(.*?)\][ \t]*(?:#.*)?$", re.M)
RE_RUNBOOK = re.compile(r"^runbook:[ \t]*(.*?)[ \t]*$", re.M)
RE_NAME = re.compile(r"^name:[ \t]*(.*?)[ \t]*$", re.M)


def _scalar(raw):
    """한 줄 스칼라에서 따옴표와 줄 끝 주석을 걷어낸다."""
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        end = raw.find(raw[0], 1)
        return raw[1:end] if end > 0 else raw[1:]
    return re.split(r"[ \t]#", raw, maxsplit=1)[0].strip()


def _items(raw):
    """`a, "b", 'c'` -> ['a', 'b', 'c'] (빈 항목은 버린다)."""
    out = []
    for part in raw.split(","):
        item = _scalar(part)
        if item:
            out.append(item)
    return out


def parse_profile(text):
    """프로필 본문에서 (name, knowledge, runbook) 을 읽는다. 키가 없으면 빈 값."""
    text = text.replace("\r\n", "\n")
    m = RE_KNOWLEDGE.search(text)
    knowledge = _items(m.group(1)) if m else []
    m = RE_RUNBOOK.search(text)
    runbook = _scalar(m.group(1)) if m else ""
    m = RE_NAME.search(text)
    name = _scalar(m.group(1)) if m else ""
    return name, knowledge, runbook


def _is_path(arg):
    return ("/" in arg or "\\" in arg or os.sep in arg
            or arg.lower().endswith((".yaml", ".yml")))


def _display(path):
    """플러그인 안의 파일은 루트 기준 상대 경로로, 밖의 파일은 절대 경로로 적는다."""
    full = os.path.abspath(path)
    try:
        rel = os.path.relpath(full, ROOT)
    except ValueError:        # 다른 드라이브 (Windows)
        return full
    return full if rel.startswith("..") else rel.replace(os.sep, "/")


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def kit_for(arg):
    """(결과 dict, 종료코드). 결과는 실패해도 같은 모양을 유지한다."""
    note = None
    if _is_path(arg):
        path = arg
        family = os.path.splitext(os.path.basename(path))[0]
    else:
        family = arg
        path = os.path.join(ROOT, "profiles", f"{arg}.yaml")
        if not FAMILY_NAME.match(arg) or not os.path.isfile(path):
            note = (f"'{arg}' 계열의 프로필(profiles/{arg}.yaml)이 없어 generic 으로 "
                    f"대체했습니다")
            family = "generic"
            path = os.path.join(ROOT, "profiles", "generic.yaml")

    result = {"family": family, "profile": _display(path),
              "knowledge": [], "runbook": ""}
    if note:
        result["note"] = note
    try:
        text = _read(path)
    except (OSError, UnicodeDecodeError) as exc:
        result["error"] = f"프로필을 읽지 못했습니다: {path} ({exc.__class__.__name__}: {exc})"
        return result, 2

    name, knowledge, runbook = parse_profile(text)
    if _is_path(arg) and name:
        result["family"] = name
    result["knowledge"] = knowledge
    result["runbook"] = runbook
    missing = [p for p in knowledge + ([runbook] if runbook else [])
               if not os.path.isfile(os.path.join(ROOT, p))]
    if missing:
        result["missing"] = missing
    return result, 0


def main(argv):
    if len(argv) != 1 or argv[0] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 1
    result, code = kit_for(argv[0])
    print(json.dumps(result, ensure_ascii=False))
    if code:
        sys.stderr.write(f"family_kit: {result.get('error', '')}\n")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
