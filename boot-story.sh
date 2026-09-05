#!/usr/bin/env bash
#
# ============================================================
# boot-story - why did it reboot, in one paragraph
# ============================================================
#
# Runs on: Pi (bash 5)
# Requires: journalctl
#
# Reconstructs how the machine came up and why the previous run ended, then
# states a verdict with the evidence behind it and a suggested fix. The point
# is to answer "what happened" without reading dmesg by hand at 2am.
#
# Evidence is ranked. A missing systemd shutdown sequence in the previous boot
# means the machine was cut off rather than asked to stop; combining that with
# undervoltage or USB over-current usually identifies power as the cause.
#
# When journald has not retained the previous boot, the current boot still
# carries proof of how the last one ended: ext4 orphan cleanup and journal
# recovery only happen after an unclean stop.
#
# Config file (default ~/.config/boot-story.conf, mode 600):
#   APT_WINDOW_MIN=30
#
# Usage:  boot-story.sh [--boots N] [--json] [--quiet]
# ============================================================

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

require_linux
require_tools journalctl

TAB="$(printf '\t')"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

load_config boot-story

APT_WINDOW_MIN="${APT_WINDOW_MIN:-30}"

SHOW_BOOTS=0
AS_JSON=0
QUIET=0

usage() {
    cat <<'EOF'
Explain why the machine last rebooted, with the evidence behind the verdict.

Usage: boot-story.sh [options]

  --boots N    Also list the last N boots with durations.
  --quiet      Print nothing unless the last stop was unclean.
  --json       Machine-readable output.
  -h, --help   Show this help.

Exits 1 when the previous stop was unclean and 2 when this boot shows data loss.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --boots)
            SHOW_BOOTS="${2:?--boots needs a value}"
            shift 2
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        --json)
            AS_JSON=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

# ------------------------------------------------------------
# BOOT INVENTORY
# ------------------------------------------------------------

jrn() { journalctl "$@" 2>/dev/null || true; }

# Newer systemd prints a header row; the index is always the first field.
list_boots() {
    jrn --list-boots --no-pager | awk '$1 ~ /^-?[0-9]+$/ { print }'
}

BOOT_COUNT="$(list_boots | grep -c . || true)"
HAVE_PREVIOUS=0
[ "$BOOT_COUNT" -gt 1 ] && HAVE_PREVIOUS=1

BOOT_START="$(jrn -b 0 --no-pager -o short-iso -n 1 | awk '{ print $1 }')"
[ -n "$BOOT_START" ] || BOOT_START="$(who -b 2>/dev/null | awk '{ print $3, $4 }')"

UPTIME_S=0
[ -r /proc/uptime ] && UPTIME_S="$(awk '{ printf "%d", $1 }' /proc/uptime)"

# ------------------------------------------------------------
# EVIDENCE
#
# Each finding is severity<TAB>text. Flags drive the verdict below.
# ------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
# shellcheck disable=SC2329  # invoked via on_exit
cleanup_workdir() { rm -rf "$WORK_DIR"; }
on_exit cleanup_workdir

FINDINGS="$WORK_DIR/findings.tsv"
: >"$FINDINGS"

note() { printf '%s\t%s\n' "$1" "$2" >>"$FINDINGS"; }

CLEAN_SHUTDOWN=unknown
HAS_PANIC=0
HAS_OOM=0
HAS_UNDERVOLT=0
HAS_OVERCURRENT=0
HAS_THERMAL=0
HAS_FS_RECOVERY=0
HAS_DATA_LOSS=0
HAS_APT=0
OOM_VICTIM=''

# --- how the previous boot ended -----------------------------------------

if [ "$HAVE_PREVIOUS" -eq 1 ]; then
    prev_tail="$(jrn -b -1 --no-pager -n 60)"
    if printf '%s' "$prev_tail" |
        grep -qiE 'systemd-shutdown|Reached target (System )?Power-?Off|Reached target (System )?Reboot|Powering off|Shutting down'; then
        CLEAN_SHUTDOWN=yes
        note info "previous boot ended with a proper systemd shutdown sequence"
    else
        CLEAN_SHUTDOWN=no
        note crit "previous boot has no shutdown sequence in its journal, so it was cut off"
    fi

    if printf '%s' "$(jrn -b -1 --no-pager -k)" |
        grep -qiE 'Kernel panic|Oops:|BUG: |soft lockup'; then
        HAS_PANIC=1
        note crit "previous boot logged a kernel panic or oops"
    fi

    prev_oom="$(printf '%s' "$(jrn -b -1 --no-pager)" |
        grep -iE 'Out of memory: Kill|oom-kill|oom_reaper' | tail -1)"
    if [ -n "$prev_oom" ]; then
        HAS_OOM=1
        OOM_VICTIM="$(printf '%s' "$prev_oom" | sed -n 's/.*[Kk]illed process [0-9]* (\([^)]*\)).*/\1/p')"
        [ -n "$OOM_VICTIM" ] || OOM_VICTIM="$(printf '%s' "$prev_oom" | sed -n 's/.*comm=\([^ ,]*\).*/\1/p')"
        note crit "previous boot ran out of memory${OOM_VICTIM:+ and killed $OOM_VICTIM}"
    fi
else
    note info "journald has not retained the previous boot, so its cause cannot be read directly"
fi

# --- filesystem proof of how the last stop went --------------------------
#
# These only appear when the filesystem was not unmounted cleanly, which makes
# them usable even with no previous journal.

fs_recovery="$(jrn -b 0 --no-pager -k | grep -iE 'EXT4-fs \(.*\): (recovery complete|orphan cleanup)' || true)"
if [ -n "$fs_recovery" ]; then
    HAS_FS_RECOVERY=1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        dev="$(printf '%s' "$line" | sed -n 's/.*EXT4-fs (\([^)]*\)).*/\1/p')"
        kind="$(printf '%s' "$line" | grep -oiE 'recovery complete|orphan cleanup')"
        note warn "filesystem $dev needed $kind at mount, which only happens after an unclean stop"
    done <<EOF
$fs_recovery
EOF
fi

data_loss="$(jrn -b 0 --no-pager -k | grep -icE 'potential data loss|failed to convert unwritten extents' || true)"
if [ "$data_loss" -gt 0 ]; then
    HAS_DATA_LOSS=1
    note crit "$data_loss ext4 write failures reported potential data loss in this boot"
fi

# --- power ---------------------------------------------------------------

uv="$(jrn -b 0 --no-pager -k | grep -icE 'under-?voltage' || true)"
if [ "$uv" -gt 0 ]; then
    HAS_UNDERVOLT=1
    note crit "$uv undervoltage events on the core supply"
fi

if command -v vcgencmd >/dev/null 2>&1; then
    thr="$(vcgencmd get_throttled 2>/dev/null | sed 's/throttled=//')"
    if [ -n "$thr" ] && [ "$thr" != 0x0 ]; then
        HAS_UNDERVOLT=1
        note warn "throttling register is $thr, so the supply has sagged at some point"
    fi
fi

oc="$(jrn -b 0 --no-pager -k | grep -oiE 'over-?current change #[0-9]+' | sort -u | grep -c . || true)"
if [ "$oc" -gt 0 ]; then
    HAS_OVERCURRENT=1
    note crit "$oc USB over-current incidents, meaning the bus cut power to attached devices"
fi

if jrn -b 0 --no-pager -k | grep -qiE 'thermal shutdown|critical temperature'; then
    HAS_THERMAL=1
    note crit "thermal shutdown was reported"
fi

# --- package activity ----------------------------------------------------

if [ -r /var/log/apt/history.log ] && [ "$HAVE_PREVIOUS" -eq 1 ]; then
    if find /var/log/apt/history.log -newermt "-${APT_WINDOW_MIN} minutes" >/dev/null 2>&1 &&
        [ -n "$(find /var/log/apt/history.log -newermt "-${APT_WINDOW_MIN} minutes" 2>/dev/null)" ]; then
        HAS_APT=1
        note info "apt ran within $APT_WINDOW_MIN minutes of this boot, so an update may have triggered it"
    fi
fi

# --- current state -------------------------------------------------------

failed="$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{ print $1 }' | grep -c . || true)"
if [ "$failed" -gt 0 ]; then
    note warn "$failed unit(s) failed to start: $(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{ printf "%s ", $1 }')"
fi

# ------------------------------------------------------------
# VERDICT
#
# Ordered by how specific the evidence is: a panic or an OOM names itself,
# whereas power loss is inferred from the absence of a shutdown sequence.
# ------------------------------------------------------------

VERDICT=''
CONFIDENCE=''
SUGGESTION=''

if [ "$HAS_PANIC" -eq 1 ]; then
    VERDICT='KERNEL PANIC'
    CONFIDENCE=high
    SUGGESTION='Check the previous boot with: journalctl -b -1 -k -p err'
elif [ "$HAS_OOM" -eq 1 ]; then
    VERDICT='OUT OF MEMORY'
    CONFIDENCE=high
    SUGGESTION="Cap the memory of ${OOM_VICTIM:-the offending service}, or add swap"
elif [ "$HAS_THERMAL" -eq 1 ]; then
    VERDICT='THERMAL SHUTDOWN'
    CONFIDENCE=high
    SUGGESTION='Improve cooling; check the heatsink and fan'
elif [ "$CLEAN_SHUTDOWN" = no ] && { [ "$HAS_UNDERVOLT" -eq 1 ] || [ "$HAS_OVERCURRENT" -eq 1 ]; }; then
    VERDICT='POWER LOSS'
    CONFIDENCE=high
    SUGGESTION='Move bus-powered disks onto a powered USB hub, or fit a larger supply'
elif [ "$CLEAN_SHUTDOWN" = no ]; then
    VERDICT='UNCLEAN STOP'
    CONFIDENCE=medium
    SUGGESTION='No panic or power event was logged, so suspect a hard reset or a wedged kernel'
elif [ "$CLEAN_SHUTDOWN" = yes ]; then
    if [ "$HAS_APT" -eq 1 ]; then
        VERDICT='CLEAN REBOOT AFTER PACKAGE UPDATE'
    else
        VERDICT='CLEAN REBOOT'
    fi
    CONFIDENCE=high
    SUGGESTION=''
elif [ "$HAS_FS_RECOVERY" -eq 1 ]; then
    VERDICT='PREVIOUS STOP WAS UNCLEAN'
    CONFIDENCE=medium
    SUGGESTION='The journal for that boot is gone; keep more history with: sudo journalctl --vacuum-time=30d'
else
    VERDICT='CLEAN OR UNKNOWN'
    CONFIDENCE=low
    SUGGESTION='No evidence of a fault was found in this boot'
fi

# Power problems in the current boot outrank a tidy verdict about the last one.
if [ "$HAS_OVERCURRENT" -eq 1 ] && [ "$VERDICT" != 'POWER LOSS' ]; then
    SUGGESTION="${SUGGESTION:+$SUGGESTION. }USB over-current is happening now; a powered hub is the fix"
fi

RC="$EX_OK"
[ "$CLEAN_SHUTDOWN" = no ] && RC="$EX_WARN"
[ "$HAS_FS_RECOVERY" -eq 1 ] && [ "$RC" -lt "$EX_WARN" ] && RC="$EX_WARN"
[ "$HAS_DATA_LOSS" -eq 1 ] && RC="$EX_CRIT"

# ------------------------------------------------------------
# OUTPUT
# ------------------------------------------------------------

if [ "$AS_JSON" -eq 1 ]; then
    printf '{\n'
    printf '  "verdict": "%s",\n  "confidence": "%s",\n' "$VERDICT" "$CONFIDENCE"
    printf '  "boot_start": "%s",\n  "uptime_seconds": %s,\n' "$BOOT_START" "$UPTIME_S"
    printf '  "boots_retained": %s,\n' "$BOOT_COUNT"
    printf '  "previous_shutdown_clean": "%s",\n' "$CLEAN_SHUTDOWN"
    printf '  "flags": {"panic": %d, "oom": %d, "undervolt": %d, "overcurrent": %d, "thermal": %d, "fs_recovery": %d, "data_loss": %d},\n' \
        "$HAS_PANIC" "$HAS_OOM" "$HAS_UNDERVOLT" "$HAS_OVERCURRENT" "$HAS_THERMAL" "$HAS_FS_RECOVERY" "$HAS_DATA_LOSS"
    printf '  "findings": ['
    awk -F"$TAB" '{
        gsub(/"/, "\\\"", $2)
        printf "%s\n    {\"severity\":\"%s\",\"text\":\"%s\"}", (NR > 1 ? "," : ""), $1, $2
    }' "$FINDINGS"
    printf '\n  ],\n'
    printf '  "suggestion": "%s"\n}\n' "$SUGGESTION"
    exit "$RC"
fi

if [ "$QUIET" -eq 1 ] && [ "$RC" -eq "$EX_OK" ]; then
    exit "$RC"
fi

section "Boot story"
kv "Booted" "${BOOT_START:-unknown}"
kv "Uptime" "$(human_duration "$UPTIME_S")"
kv "Boots retained" "$BOOT_COUNT"

case "$CONFIDENCE" in
    high) vcolor="$RED" ;;
    medium) vcolor="$YELLOW" ;;
    *) vcolor="$GREEN" ;;
esac
[ "$RC" -eq "$EX_OK" ] && vcolor="$GREEN"

printf '\n%bVerdict: %s%b (%s confidence)\n' "$vcolor" "$VERDICT" "$NC" "$CONFIDENCE"

if [ -s "$FINDINGS" ]; then
    while IFS="$TAB" read -r sev text; do
        case "$sev" in
            crit) c="$RED" ;;
            warn) c="$YELLOW" ;;
            *) c="$DIM" ;;
        esac
        printf '  %b*%b %s\n' "$c" "$NC" "$text"
    done <"$FINDINGS"
fi

[ -n "$SUGGESTION" ] && printf '\n%bSuggestion:%b %s\n' "$BLUE" "$NC" "$SUGGESTION"

if [ "$SHOW_BOOTS" -gt 0 ]; then
    section "Last $SHOW_BOOTS boot(s)"
    list_boots | tail -"$SHOW_BOOTS" |
        while IFS= read -r line; do
            printf '  %s\n' "$line"
        done
fi

exit "$RC"
