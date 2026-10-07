#!/usr/bin/env bash
. "$(dirname "$0")/wsl_bridge.sh"
# sync_machine.sh - copy the workspace machine sources into the QEMU source tree.
#
# Usage:
#   sync_machine.sh <workdir> <machine_name> [qemu_root]
#
# Why this exists
# ---------------
# A fixer edits <workdir>/06_machine/machine.c - that is the file the one-change
# gate snapshots and diffs. What ninja compiles is the COPY that lives in the
# QEMU tree under hw/arm/. Nothing carried the edit from one to the other, so a
# round could pass its gate, rebuild cleanly, and run the previous binary. The
# fingerprint then did not move, the diagnosis was recorded as futile, and the
# run eventually declared itself out of moves - on a fix that was never in the
# binary. Five rounds of the S921N log burned exactly this way, byte-identical
# traces and all.
#
# Mapping, in order:
#   1. <workdir>/06_machine/qemu_targets.txt  (lines "<basename>\t<abs dest>")
#      written here on first success, so an unusual layout only needs solving once
#   2. hw/arm/<machine with '-' replaced by '_'>.c   - the name Build is told to use
#   3. hw/arm/<same basename>                        - a file already there
#
# The map follows the workspace: a source that was deleted or renamed is dropped from
# qemu_targets.txt before the sources are mapped. verify.py reads that file as "the list
# of sources that were built" and reports a workspace .c that is not in it as stale; a
# line for a file that no longer exists would keep naming a built source nobody can read.
# (The copy already in the QEMU tree is left as it is - removing it is Build's decision.)
#
# Touched-file manifest (C5): every file this script adds to the tree or overwrites is
# also recorded in $QEMU_ROOT/.sboot_touched through qemu_tree.sh, so that Build can put
# the tree back to pristine before the next firmware ("A" added, "M" an original QEMU
# file modified). Recording never changes the mapping, the JSON or the exit code - a
# failure is a warning on stderr, because a sync that cannot be recorded is still a sync.
#
# Exit: 0 synced (or nothing to do), 3 a source could not be mapped.
# stdout: one JSON object.

set -u

WD="${1:?workdir required}"
MACHINE="${2:?machine name required}"
QEMU_ROOT="${3:-${QEMU_ROOT:-$HOME/qemu-build/qemu-10.2.2}}"

SRC="$WD/06_machine"
HW="$QEMU_ROOT/hw/arm"
MAP="$SRC/qemu_targets.txt"
TAB="$(printf '\t')"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'; }

if [ ! -d "$SRC" ]; then
    printf '{"synced":0,"skipped":true,"reason":"%s 가 없습니다"}\n' "$(json_escape "$SRC")"
    exit 0
fi
if [ ! -d "$HW" ]; then
    printf '{"synced":0,"error":true,"reason":"QEMU 소스 트리를 찾을 수 없습니다: %s (QEMU_ROOT 로 지정하세요)"}\n' \
        "$(json_escape "$HW")"
    exit 3
fi

MACHINE_FILE="$(printf '%s' "$MACHINE" | tr '-' '_').c"

mapped_dest() {   # $1 = basename -> echoes dest path or empty
    local base="$1" line
    if [ -f "$MAP" ]; then
        line=$(grep -F "${base}${TAB}" "$MAP" 2>/dev/null | tail -1)
        if [ -n "$line" ]; then printf '%s' "${line#*$TAB}"; return 0; fi
    fi
    case "$base" in
        machine.c|machine_kernel.c|machine_full.c)
            # machine_full.c is what the unified Build writes into the workspace, and it
            # is told to copy it into the tree as hw/arm/<machine>.c - the same name.
            [ -f "$HW/$MACHINE_FILE" ] && { printf '%s' "$HW/$MACHINE_FILE"; return 0; }
            ;;
    esac
    [ -f "$HW/$base" ] && { printf '%s' "$HW/$base"; return 0; }
    printf ''
}

HERE="$(cd "$(dirname "$0")" && pwd)"

# Drop map lines whose source is gone from the workspace. Rewritten through a temporary
# file so an interruption never leaves a half-written map.
if [ -f "$MAP" ]; then
    KEEP_TMP="$MAP.tmp.$$"; : > "$KEEP_TMP"; DROPPED=0
    while IFS= read -r mline || [ -n "$mline" ]; do
        mbase="${mline%%$TAB*}"
        if [ -n "$mbase" ] && { [ -f "$SRC/$mbase" ] || [ "$mbase" = "$mline" ]; }; then
            printf '%s\n' "$mline" >> "$KEEP_TMP"
        else
            DROPPED=$((DROPPED + 1))
        fi
    done < "$MAP"
    if [ "$DROPPED" -gt 0 ]; then
        mv "$KEEP_TMP" "$MAP"
        echo "sync_machine: 워크스페이스에 없는 소스 ${DROPPED} 개를 qemu_targets.txt 에서 뺐습니다" >&2
    else
        rm -f "$KEEP_TMP"
    fi
fi

REC_ADDED=(); REC_EXISTING=()   # paths relative to the tree, split by whether dest was there before

SYNCED=0; UNMAPPED=""; TARGETS=""
for cur in "$SRC"/*.c "$SRC"/*.h; do
    [ -f "$cur" ] || continue
    base="$(basename "$cur")"
    dest="$(mapped_dest "$base")"
    if [ -z "$dest" ]; then
        UNMAPPED="${UNMAPPED:+$UNMAPPED, }$base"
        continue
    fi
    if ! cmp -s "$cur" "$dest"; then
        existed=0; [ -e "$dest" ] && existed=1
        cp "$cur" "$dest" || {
            UNMAPPED="${UNMAPPED:+$UNMAPPED, }$base(복사 실패)"
            continue
        }
        SYNCED=$((SYNCED + 1))
        case "$dest" in
            "$QEMU_ROOT"/*)
                if [ "$existed" -eq 0 ]; then REC_ADDED+=("${dest#"$QEMU_ROOT"/}")
                else REC_EXISTING+=("${dest#"$QEMU_ROOT"/}"); fi ;;
            *) echo "sync_machine: 트리 밖에 복사해 장부(.sboot_touched)에 적지 않습니다: $dest" >&2 ;;
        esac
    fi
    TARGETS="${TARGETS:+$TARGETS, }$base -> $dest"
    # Remember the mapping so the next round does not have to rediscover it.
    if ! grep -qF "${base}${TAB}${dest}" "$MAP" 2>/dev/null; then
        printf '%s\t%s\n' "$base" "$dest" >> "$MAP"
    fi
done

# Record what was touched. A dest that did not exist is certainly new ("A"); one that
# did may be an original QEMU file or a copy an earlier step left, which only the pristine
# tarball can tell apart, so qemu_tree.sh decides.
if [ -f "$HERE/qemu_tree.sh" ]; then
    if [ "${#REC_ADDED[@]}" -gt 0 ]; then
        QEMU_SRC="$QEMU_ROOT" bash "$HERE/qemu_tree.sh" record --kind A "${REC_ADDED[@]}" >/dev/null \
            || echo "sync_machine: 더한 파일을 장부에 적지 못했습니다" >&2
    fi
    if [ "${#REC_EXISTING[@]}" -gt 0 ]; then
        QEMU_SRC="$QEMU_ROOT" bash "$HERE/qemu_tree.sh" record "${REC_EXISTING[@]}" >/dev/null \
            || echo "sync_machine: 덮어쓴 파일을 장부에 적지 못했습니다 (pristine tarball 이 없으면 M/A 를 가를 수 없습니다)" >&2
    fi
fi

if [ -n "$UNMAPPED" ]; then
    printf '{"synced":%d,"unmapped":"%s","targets":"%s","reason":"QEMU 트리에서 대상 파일을 찾지 못했습니다 — hw/arm/%s 로 복사하고 meson.build 에 등록했는지 확인하세요"}\n' \
        "$SYNCED" "$(json_escape "$UNMAPPED")" "$(json_escape "$TARGETS")" "$(json_escape "$MACHINE_FILE")"
    exit 3
fi

printf '{"synced":%d,"unmapped":"","targets":"%s"}\n' "$SYNCED" "$(json_escape "$TARGETS")"
exit 0
