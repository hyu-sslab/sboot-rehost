#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# check_change.sh - enforce "one round, one change" by counting the diff.
#
# A fixer edits sources directly and only what passes this gate gets built.
# The rule is enforced by counting the diff, not by asking the prompt nicely.
#
# Usage:
#   check_change.sh <workdir> snapshot   # before the fixer edits - capture the baseline
#   check_change.sh <workdir> verify     # after the fixer edits - gate (JSON on stdout)
#   check_change.sh <workdir> restore    # on violation - roll back to the baseline
#
# restore rolls back the machine sources AND the bypass record. A rejected change must not
# leave its record behind: the next snapshot copies whatever the ledger holds as the
# baseline, and an entry in the baseline is "history", which the per-round checks below
# (4, 5) never look at again. Restoring only the sources let a rejected entry become
# history, so the identical patch retried one round later passed with the record already
# there. A source file the round created (absent from the snapshot) is removed too, or its
# `/* bypass:<id> */` rows would outlive the entry they point to.
#
# Scope. A specialist fixer's change is held to checks 1 and 2 below. The last-resort fixer
# (fixer-general) exists because not every stop point has a specialist yet: it may treat ONE
# coherent mechanism that crosses several places and files in one round. For it the pipeline
# sets CHANGE_SCOPE=general and checks 1 and 2 do not apply. Every other check (an empty
# change, 3, 4, 5) applies to both scopes unchanged: widening what may be touched never
# widens what may go unrecorded.
#
# Checks:
#   1. exactly one source file changed  (several files at once means a batched change;
#                                        not applied to CHANGE_SCOPE=general)
#   2. hunks within MAX_HUNKS           (default 3, a realistic ceiling for one change;
#                                        not applied to CHANGE_SCOPE=general)
#   3. the bypass record has all four fields (대상 / 이유 / 방법 / 부작용)
#   4. the record is usable: no empty 부작용 / "(기록 없음)", the optional 메타 line
#      uses the vocabulary, and patch-table rows tagged /* bypass:<id> */ map one
#      to one onto entries (scripts/verify_gates.py ledger). Only entries new or
#      edited since the snapshot are held to it - a fixer cannot repair history.
#      An entry whose 대상/이유/방법 touch verification (Korean or English words)
#      must carry 표지=F, or 종류=M when the engine is modelled and the digest
#      really computed. The words are a heuristic: whether the firmware's hash
#      is computed by hardware is not checked by these words (see 5).
#   5. A new entry that is labelled 표지=F and changes a hash, digest or signature
#      comparison (and is not 종류=M, where the engine is modelled) is accepted only if
#      STATIC.md carries a row saying the digest is computed by a hardware engine:
#      a table row  | hash_engine | hardware | <function address or SMC id, 0x...> |
#      or the line  hash_engine: hardware (evidence: ...). Only the static-analyzer
#      writes it (CLAUDE.md section 11, the provisional hardware-hash exception).
#      Without it the change is rejected (exit 2) with a message naming the entry and
#      the missing row. A ledger check, not a fourth gate. The script cannot tell who
#      wrote the row or whether modelling the engine was really infeasible: the row is
#      a necessary condition, never proof (verify.py reports it as
#      verify_bypass.hash_engine, the verifier reads the entry's 이유).
#
# The reason field is surfaced to the user, so it is written in Korean.
#
# Environment:
#   MAX_HUNKS      allowed hunk count (default 3)
#   CHANGE_SCOPE   "general" for the last-resort fixer: skips checks 1 and 2 only (see Scope).
#                  Anything else, or unset, is the specialist scope.
set -u

WD="${1:-}"; OP="${2:-}"; ROUND="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "$WD" ] && [ -n "$OP" ] || { echo "usage: check_change.sh <workdir> snapshot [round]|verify|restore" >&2; exit 1; }

SRC="$WD/06_machine"
PRE="$WD/08_docs/.record/pre"
PRE_LEDGER="$WD/08_docs/.record/pre_ledger.md"
# The file name the ledger had at snapshot time (empty = there was no ledger). Its presence
# marks a snapshot that restore may roll the ledger back from; a snapshot made by an older
# version has no marker and its ledger is left as it is.
PRE_LEDGER_NAME="$WD/08_docs/.record/pre_ledger.name"
# Per-round snapshots. Without them a bypass whose mechanism is later disproven
# can only be argued about: there is no record of the sources as they stood
# before it, so nothing can take it back out and the wrong model keeps
# accumulating for the rest of the run.
ROUNDS="$WD/08_docs/.record/rounds"
MAX_HUNKS="${MAX_HUNKS:-3}"
# "general" = the last-resort fixer (see the header, Scope); every other value is the specialist scope.
if [ "${CHANGE_SCOPE:-}" = general ]; then SCOPE=general; else SCOPE=specialist; fi

# Prefer the current name, still accept the legacy one in older workspaces.
bypass_file() {
    if   [ -f "$SRC/bypasses.md" ];       then echo "$SRC/bypasses.md"
    elif [ -f "$SRC/우회_패치_목록.md" ];  then echo "$SRC/우회_패치_목록.md"
    else echo ""
    fi
}

case "$OP" in
  snapshot)
    rm -rf "$PRE"; mkdir -p "$PRE"
    # Only machine sources are snapshotted; the bypass record is checked separately.
    find "$SRC" -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) \
        -exec cp {} "$PRE/" \; 2>/dev/null || true
    if [ -n "$ROUND" ]; then
        rm -rf "$ROUNDS/$ROUND"; mkdir -p "$ROUNDS/$ROUND"
        cp "$PRE"/* "$ROUNDS/$ROUND/" 2>/dev/null || true
    fi
    # The ledger as it stood, so verify can tell this round's entries from history.
    SBF="$(bypass_file)"
    if [ -n "$SBF" ]; then
        cp "$SBF" "$PRE_LEDGER" 2>/dev/null || true
        basename "$SBF" > "$PRE_LEDGER_NAME"
    else
        rm -f "$PRE_LEDGER"
        : > "$PRE_LEDGER_NAME"
    fi
    echo "check_change: snapshot $(find "$PRE" -type f 2>/dev/null | wc -l | tr -d ' ') files${ROUND:+ (round $ROUND)}"
    ;;

  verify)
    [ -d "$PRE" ] || { echo '{"pass":false,"reason":"스냅샷이 없습니다 — 수정 전에 snapshot 을 먼저 실행하세요"}'; exit 1; }

    changed_files=0; total_hunks=0; changed_list=""
    for cur in "$SRC"/*.c "$SRC"/*.h; do
        [ -f "$cur" ] || continue
        base="$(basename "$cur")"
        old="$PRE/$base"
        if [ ! -f "$old" ]; then
            # A brand new source file also counts as one change.
            changed_files=$((changed_files + 1))
            total_hunks=$((total_hunks + 1))
            changed_list="$changed_list $base(new)"
            continue
        fi
        h=$(diff -u "$old" "$cur" 2>/dev/null | grep -c '^@@' || true)
        if [ "$h" -gt 0 ]; then
            changed_files=$((changed_files + 1))
            total_hunks=$((total_hunks + h))
            changed_list="$changed_list $base($h)"
        fi
    done

    # Field names appear with markdown emphasis (`**대상**:`) and a list marker in
    # real workspaces, and the last one is often written "알려진 부작용".
    # Matching the bare literal `대상:` scored a compliant file as zero fields.
    count_field() {   # $1 = field regex
        # grep -c prints 0 and still exits 1 on no match; `|| echo 0` then made the
        # count "0\n0", the numeric tests below errored, and a ledger with no
        # entries at all passed the four-field check.
        local n
        n=$(grep -cE "^[[:space:]>*+-]*\**[[:space:]]*$1[[:space:]]*\**[[:space:]]*[:：]" "$2" 2>/dev/null)
        echo "${n:-0}"
    }

    BF="$(bypass_file)"
    if [ -n "$BF" ]; then
        n_target=$(count_field '대상' "$BF")
        n_reason=$(count_field '이유' "$BF")
        n_method=$(count_field '방법' "$BF")
        n_effect=$(count_field '(알려진[[:space:]]*)?부작용' "$BF")
    else
        n_target=0; n_reason=0; n_method=0; n_effect=0
    fi

    bypass_ok=true
    if [ "$n_target" -eq 0 ] \
       || [ "$n_target" -ne "$n_reason" ] \
       || [ "$n_target" -ne "$n_method" ] \
       || [ "$n_target" -ne "$n_effect" ]; then
        bypass_ok=false
    fi

    # Record quality beyond the field count. Python is optional here: without it
    # the four-field check above still stands, exactly as before.
    LEDGER_ISSUES=0; LEDGER_MSG=""
    if [ -n "$BF" ] && [ "$n_target" -gt 0 ] && command -v python3 >/dev/null 2>&1 \
       && [ -f "$HERE/verify_gates.py" ]; then
        BASE_ARG=""; [ -f "$PRE_LEDGER" ] && BASE_ARG="--baseline $PRE_LEDGER"
        LJ="$(python3 "$HERE/verify_gates.py" ledger "$WD" $BASE_ARG 2>/dev/null)" || true
        if [ -n "$LJ" ]; then
            LPARSED="$(printf '%s' "$LJ" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
iss = d.get("issues") or []
print(len(iss))
print(" / ".join(i.get("message", "") for i in iss[:3]))
' 2>/dev/null)" || LPARSED=""
            LEDGER_ISSUES="$(printf '%s\n' "$LPARSED" | sed -n 1p)"
            LEDGER_MSG="$(printf '%s\n' "$LPARSED" | sed -n 2p | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\t')"
            case "$LEDGER_ISSUES" in ''|*[!0-9]*) LEDGER_ISSUES=0;; esac
        fi
    fi

    pass=true; reason=""
    if [ "$changed_files" -eq 0 ]; then
        pass=false; reason="변경된 소스가 없습니다 (fixer 가 아무것도 고치지 않았습니다)"
    elif [ "$SCOPE" != general ] && [ "$changed_files" -gt 1 ]; then
        pass=false; reason="소스 파일 ${changed_files} 개를 동시에 고쳤습니다 — 한 회차 한 변경 위반입니다"
    elif [ "$SCOPE" != general ] && [ "$total_hunks" -gt "$MAX_HUNKS" ]; then
        pass=false; reason="변경 hunk 가 ${total_hunks} 개로 상한(${MAX_HUNKS})을 넘었습니다 — 여러 변경을 묶은 것으로 보입니다"
    elif [ "$bypass_ok" != true ]; then
        pass=false; reason="우회 기록 4 항목이 갖춰지지 않았습니다 (대상=$n_target 이유=$n_reason 방법=$n_method 부작용=$n_effect)"
    elif [ "$LEDGER_ISSUES" -gt 0 ]; then
        pass=false; reason="우회 기록에 문제가 ${LEDGER_ISSUES} 건 있습니다: ${LEDGER_MSG}"
    fi

    printf '{"pass":%s,"scope":"%s","changed_files":%d,"total_hunks":%d,"changed":"%s","bypass_entries":%d,"bypass_ok":%s,"bypass_issues":%d,"reason":"%s"}\n' \
        "$pass" "$SCOPE" "$changed_files" "$total_hunks" "$(echo "$changed_list" | sed 's/^ //')" \
        "$n_target" "$bypass_ok" "$LEDGER_ISSUES" "$reason"

    [ "$pass" = true ] || exit 2
    ;;

  restore)
    [ -d "$PRE" ] || { echo "check_change: 되돌릴 스냅샷이 없습니다" >&2; exit 1; }
    for old in "$PRE"/*; do
        [ -f "$old" ] || continue
        cp "$old" "$SRC/$(basename "$old")"
    done
    # A source the round created is part of the rejected change (verify counted it as one).
    REMOVED=""
    for cur in "$SRC"/*.c "$SRC"/*.h; do
        [ -f "$cur" ] || continue
        [ -f "$PRE/$(basename "$cur")" ] && continue
        rm -f "$cur" && REMOVED="$REMOVED $(basename "$cur")"
    done
    # The bypass record goes back to the snapshot too (see the header).
    LEDGER_NOTE=""
    if [ -f "$PRE_LEDGER_NAME" ]; then
        LNAME="$(basename "$(cat "$PRE_LEDGER_NAME" 2>/dev/null)")"
        if [ -n "$LNAME" ] && [ "$LNAME" != "." ] && [ -f "$PRE_LEDGER" ]; then
            cp "$PRE_LEDGER" "$SRC/$LNAME"
            # bypass_file() prefers bypasses.md: one created this round would shadow the
            # legacy-named ledger that was there at snapshot time.
            [ "$LNAME" = "bypasses.md" ] || rm -f "$SRC/bypasses.md"
            LEDGER_NOTE="; 우회 기록($LNAME)도 스냅샷 시점으로"
        elif [ -z "$LNAME" ] || [ "$LNAME" = "." ]; then
            # No ledger existed at snapshot time: whatever is there was written this round.
            if [ -f "$SRC/bypasses.md" ] || [ -f "$SRC/우회_패치_목록.md" ]; then
                rm -f "$SRC/bypasses.md" "$SRC/우회_패치_목록.md"
                LEDGER_NOTE="; 이번 회차에 새로 쓴 우회 기록은 지웠습니다"
            fi
        fi
    fi
    echo "check_change: 위반한 변경을 스냅샷으로 되돌렸습니다${REMOVED:+ (새 소스 삭제:$REMOVED)}${LEDGER_NOTE}"
    ;;

  *) echo "check_change: unknown op '$OP'" >&2; exit 1;;
esac
