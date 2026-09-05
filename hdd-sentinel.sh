#!/usr/bin/env bash
#
# ============================================================
# hdd-sentinel - warn before the disk holding your photos dies
# ============================================================
#
# Runs on: Pi (bash 5)
# Requires: smartctl jq
#
# Reports SMART health for every attached disk, but alerts on the *change*
# rather than the absolute value. A reallocated sector count that moves from 0
# to 8 is an emergency; one that has sat at 8 for two years is not. Alerting on
# absolute thresholds is why people learn to ignore SMART.
#
# It also tracks three things SMART is blind to, which matter because USB disks
# usually fail at the power rail or the bridge rather than the platter:
#
#   * USB over-current events, where the controller cut power mid-transfer
#   * USB reset and I/O error counts from the kernel ring buffer
#   * device letter reassignment, which means an enclosure dropped off the bus
#
# Over-current is normally the cause and the other two are its symptoms. When
# every port reports it at once the rail itself collapsed, which means the bus
# cannot supply the attached disks and no cable or disk swap will help.
#
# Reads are done with `-n standby` so polling never spins up a sleeping disk.
# Waking a drive every hour to ask whether it is healthy causes the wear it is
# meant to detect.
#
# smartctl needs root. This uses passwordless sudo when available, so the
# script itself can run as your normal user from a timer.
#
# Config file (default ~/.config/hdd-sentinel.conf, mode 600):
#   DEVICES=""            # empty means auto-detect via smartctl --scan
#   TEMP_WARN=45
#   TEMP_CRIT=55
#
# Usage:  hdd-sentinel.sh [--quiet] [--json] [--wake] [--device /dev/sda]
#         hdd-sentinel.sh --test short|long [--device /dev/sda]
# ============================================================

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

TAB="$(printf '\t')"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

load_config hdd-sentinel

DEVICES="${DEVICES:-}"
TEMP_WARN="${TEMP_WARN:-45}"
TEMP_CRIT="${TEMP_CRIT:-55}"
USB_RESET_WARN="${USB_RESET_WARN:-5}"
# SMART normalized values count down from 100 toward the failure threshold.
LOAD_CYCLE_NORM_WARN="${LOAD_CYCLE_NORM_WARN:-20}"
HISTORY_DAYS="${HISTORY_DAYS:-90}"
# Short windows measure noise: head parking is bursty and tied to workload.
MIN_RATE_HOURS="${MIN_RATE_HOURS:-6}"
# Below this much movement the observed rate is too small to project from.
MIN_RATE_DELTA="${MIN_RATE_DELTA:-50}"

QUIET=0
AS_JSON=0
WAKE=0
TEST_KIND=''

usage() {
    cat <<'EOF'
SMART health for attached disks, alerting on change rather than absolute value.

Usage: hdd-sentinel.sh [options]

  --quiet            Print nothing unless something needs attention.
  --json             Machine-readable output.
  --wake             Query disks even if they are spun down. Off by default.
  --device DEV       Check only this device (repeatable).
  --test short|long  Start a self test, then exit. Results appear on later runs.
  -h, --help         Show this help.

Exits 1 on a warning and 2 on a critical finding.

Settings (config file wins over environment):
  DEVICES, TEMP_WARN, TEMP_CRIT, USB_RESET_WARN
EOF
}

DEVICE_OVERRIDE=''
while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)
            QUIET=1
            shift
            ;;
        --json)
            AS_JSON=1
            shift
            ;;
        --wake)
            WAKE=1
            shift
            ;;
        --device)
            DEVICE_OVERRIDE="$DEVICE_OVERRIDE ${2:?--device needs a value}"
            shift 2
            ;;
        --test)
            TEST_KIND="${2:?--test needs short or long}"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

[ -n "$DEVICE_OVERRIDE" ] && DEVICES="$DEVICE_OVERRIDE"

case "$TEST_KIND" in
    '' | short | long) ;;
    *) die "--test takes short or long, not $TEST_KIND" ;;
esac

# Checked after argument parsing so --help works on any platform.
require_linux
require_tools smartctl jq

STATE="$(state_dir hdd-sentinel)"

# ------------------------------------------------------------
# PRIVILEGE
#
# smartctl talks to the device directly and needs root even to read.
# ------------------------------------------------------------

declare -a SMARTCTL=()
if [ "$(id -u)" -eq 0 ]; then
    SMARTCTL=(smartctl)
elif sudo -n true 2>/dev/null; then
    SMARTCTL=(sudo -n smartctl)
else
    die "smartctl needs root. Run as root, or grant passwordless sudo:
  echo '$(id -un) ALL=(root) NOPASSWD: $(command -v smartctl)' | sudo tee /etc/sudoers.d/hdd-sentinel"
fi

smart() { "${SMARTCTL[@]}" "$@" 2>/dev/null || true; }

# ------------------------------------------------------------
# DEVICE DISCOVERY
#
# --scan works unprivileged and already reports the right -d type, which is
# the part that normally breaks on USB enclosures. The probe below is only a
# fallback for bridges it fails to identify.
# ------------------------------------------------------------

TYPE_CACHE="$STATE/device-types.tsv"

probe_type() {
    local dev="$1" t
    for t in sat "sat,12" usbjmicron usbsunplus usbcypress scsi nvme auto; do
        if smart -j -i -d "$t" "$dev" | jq -e '.serial_number // .model_name // empty' >/dev/null 2>&1; then
            printf '%s' "$t"
            return 0
        fi
    done
    return 1
}

device_type() {
    local dev="$1" cached
    if [ -f "$TYPE_CACHE" ]; then
        cached="$(awk -F"$TAB" -v d="$dev" '$1 == d { print $2; exit }' "$TYPE_CACHE")"
        [ -n "$cached" ] && {
            printf '%s' "$cached"
            return 0
        }
    fi
    local t
    if t="$(probe_type "$dev")"; then
        printf '%s\t%s\n' "$dev" "$t" >>"$TYPE_CACHE"
        printf '%s' "$t"
        return 0
    fi
    return 1
}

discover() {
    if [ -n "$DEVICES" ]; then
        local d
        for d in $DEVICES; do printf '%s\t%s\n' "$d" "$(device_type "$d" || echo auto)"; done
        return 0
    fi
    # "/dev/sda -d sat # comment"
    { smartctl --scan 2>/dev/null || true; } | awk '
        /^\/dev\// {
            dev = $1
            type = "auto"
            for (i = 1; i < NF; i++) if ($i == "-d") type = $(i + 1)
            print dev "\t" type
        }'
}

# ------------------------------------------------------------
# KERNEL SIGNALS
#
# SMART says nothing about a bridge that keeps dropping off the bus, which is
# how most USB disks actually fail.
# ------------------------------------------------------------

usb_reset_count() {
    { dmesg 2>/dev/null || true; } |
        grep -ciE 'reset (high|super|full)-speed USB device' || true
}

# The controller reports one line per port, so a single rail collapse looks
# like six events. Counting distinct "change #N" values gives incidents.
over_current_count() {
    { dmesg 2>/dev/null || true; } |
        grep -oiE 'over-?current change #[0-9]+' | sort -u | grep -c . || true
}

io_error_count() {
    { dmesg 2>/dev/null || true; } |
        grep -ciE 'I/O error|EXT4-fs error|critical medium error' || true
}

# A drive that keeps the same serial but changes device letter dropped off the
# bus and came back. One that vanishes entirely was unplugged. Matching on
# serials tells those apart; matching on letters in dmesg cannot.
DEVMAP="$STATE/devices.tsv"

detect_device_changes() {
    local present="$1" ser dev old
    if [ ! -f "$DEVMAP" ]; then
        cp "$present" "$DEVMAP"
        return 0
    fi

    while IFS="$TAB" read -r ser dev; do
        [ -n "$ser" ] || continue
        old="$(awk -F"$TAB" -v s="$ser" '$1 == s { print $2; exit }' "$DEVMAP")"
        if [ -n "$old" ] && [ "$old" != "$dev" ]; then
            printf 'bus: %s moved %s -> %s, so it dropped off the bus and re-enumerated\n' \
                "$ser" "$old" "$dev" >>"$NOTES"
            [ "$WORST" -lt 1 ] && WORST=1
        fi
    done <"$present"

    while IFS="$TAB" read -r ser dev; do
        [ -n "$ser" ] || continue
        if ! awk -F"$TAB" -v s="$ser" '$1 == s { found = 1 } END { exit !found }' "$present"; then
            printf 'bus: %s (was %s) is no longer attached\n' "$ser" "$dev" >>"$NOTES"
        fi
    done <"$DEVMAP"

    cp "$present" "$DEVMAP"
}

# ------------------------------------------------------------
# SELF TEST
# ------------------------------------------------------------

if [ -n "$TEST_KIND" ]; then
    started=0
    while IFS="$TAB" read -r dev type; do
        [ -n "$dev" ] || continue
        started_ok="$(smart -t "$TEST_KIND" -d "$type" "$dev" | grep -ci 'test has begun\|testing has begun' || true)"
        if [ "${started_ok:-0}" -gt 0 ]; then
            ok "$dev: $TEST_KIND self test started"
            started=$((started + 1))
        else
            warn "$dev: could not start $TEST_KIND self test"
        fi
    done <<EOF
$(discover)
EOF
    [ "$started" -gt 0 ] || exit "$EX_WARN"
    info "results appear in later runs; the disk stays usable meanwhile"
    exit "$EX_OK"
fi

# ------------------------------------------------------------
# COLLECT
# ------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
# shellcheck disable=SC2329  # invoked via on_exit
cleanup_workdir() { rm -rf "$WORK_DIR"; }
on_exit cleanup_workdir

ROWS="$WORK_DIR/rows.tsv"
: >"$ROWS"
NOTES="$WORK_DIR/notes.txt"
: >"$NOTES"
PRESENT="$WORK_DIR/present.tsv"
: >"$PRESENT"

# The five Backblaze found actually predict failure, plus 199, which counts CRC
# failures on the link itself. A high 199 with zero media errors means the
# cable or bridge is corrupting transfers while the platters are perfect, and
# that is the common failure for USB attached disks.
CRITICAL_IDS="5 187 188 197 198 199"
INFO_IDS="9 12 193"

attr_label() {
    case "$1" in
        5) echo Reallocated ;;
        187) echo Reported_Uncorrect ;;
        188) echo Command_Timeout ;;
        193) echo Load_Cycles ;;
        197) echo Pending_Sector ;;
        198) echo Offline_Uncorrect ;;
        199) echo Link_CRC ;;
        *) echo "attr $1" ;;
    esac
}

attr() {
    printf '%s' "$1" | jq -r --argjson id "$2" '
        [(.ata_smart_attributes.table // [])[] | select(.id == $id) | .raw.value] | first // empty'
}

# The normalized value is the drive's own "life remaining" scale: it starts at
# 100 and falls toward the threshold. Raw counts alone miss this, which is how
# a drive at 13% of its rated load cycles still looks healthy.
attr_norm() {
    printf '%s' "$1" | jq -r --argjson id "$2" '
        [(.ata_smart_attributes.table // [])[] | select(.id == $id) | .value] | first // empty'
}

# record_history <key> <current_attrs_file>
record_history() {
    local key="$1" cur="$2"
    local hist="$STATE/history-$key.tsv" now cutoff
    now="$(date +%s)"
    awk -F"$TAB" -v ts="$now" '{ print ts "\t" $1 "\t" $2 }' "$cur" >>"$hist"
    cutoff=$((now - HISTORY_DAYS * 86400))
    awk -F"$TAB" -v c="$cutoff" '$1 >= c' "$hist" >"$hist.tmp" && mv "$hist.tmp" "$hist"
}

# attr_rate <key> <id> -> "per_hour span_hours delta", empty until the history
# spans MIN_RATE_HOURS. Counters like load cycles accrue in bursts, so a short
# window reports either zero or a wildly inflated rate.
attr_rate() {
    local key="$1" id="$2"
    local hist="$STATE/history-$key.tsv"
    [ -f "$hist" ] || return 1
    awk -F"$TAB" -v id="$id" -v minh="$MIN_RATE_HOURS" '
        $2 == id {
            if (ft == "") { first = $3; ft = $1 }
            last = $3; lt = $1
        }
        END {
            if (ft == "" || lt <= ft) exit 1
            span = (lt - ft) / 3600
            if (span < minh) exit 1
            printf "%.1f %.1f %d", (last - first) / span, span, last - first
        }' "$hist"
}

# project_days <raw> <normalized> <per_hour> - when the normalized value hits 0.
# The drive scales raw to normalized linearly, so the current pair reveals the
# full-life raw count without needing the datasheet.
project_days() {
    awk -v raw="$1" -v norm="$2" -v rate="$3" 'BEGIN {
        if (norm >= 100 || norm < 0 || rate <= 0) { print -1; exit }
        remaining = (raw / (100 - norm)) * 100 - raw
        if (remaining <= 0) { print 0; exit }
        printf "%.0f", remaining / (rate * 24)
    }'
}

WORST=0

while IFS="$TAB" read -r dev type; do
    [ -n "$dev" ] || continue

    if [ "$WAKE" -eq 1 ]; then
        json="$(smart -j -H -A -i -d "$type" "$dev")"
    else
        json="$(smart -j -H -A -i -n standby -d "$type" "$dev")"
    fi

    [ -n "$json" ] || {
        warn "$dev: smartctl returned nothing (type $type)"
        continue
    }

    if printf '%s' "$json" | jq -e '.smartctl.messages[]?.string | select(test("STANDBY"; "i"))' >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$dev" "standby" "-" "-" "-" "-" "-" "-" "-" "-" "asleep, not woken" >>"$ROWS"
        continue
    fi

    model="$(printf '%s' "$json" | jq -r '.model_name // .model_family // "unknown"')"
    serial="$(printf '%s' "$json" | jq -r '.serial_number // "unknown"')"
    passed="$(printf '%s' "$json" | jq -r '.smart_status.passed // empty')"
    temp="$(printf '%s' "$json" | jq -r '.temperature.current // empty')"
    hours="$(printf '%s' "$json" | jq -r '.power_on_time.hours // empty')"

    key="$(printf '%s' "$serial" | tr -c 'A-Za-z0-9._-' '_')"
    snap="$STATE/attrs-$key.tsv"
    printf '%s\t%s\n' "$serial" "$dev" >>"$PRESENT"

    dev_notes=''
    level=ok

    # Health verdict from the drive itself.
    if [ "$passed" = false ]; then
        dev_notes="SMART SAYS FAILING"
        level=crit
    fi

    # The delta is the alert. A value that has been non-zero for years is
    # history; one that moved since the last run is an event.
    cur="$WORK_DIR/cur-$key.tsv"
    : >"$cur"
    for id in $CRITICAL_IDS $INFO_IDS; do
        v="$(attr "$json" "$id")"
        [ -n "$v" ] || continue
        printf '%s\t%s\n' "$id" "$v" >>"$cur"
    done

    for id in $CRITICAL_IDS; do
        v="$(awk -F"$TAB" -v i="$id" '$1 == i { print $2; exit }' "$cur")"
        [ -n "$v" ] || continue
        prev=''
        [ -f "$snap" ] && prev="$(awk -F"$TAB" -v i="$id" '$1 == i { print $2; exit }' "$snap")"

        label="$(attr_label "$id")"
        hint=''
        # 199 counts link errors, so the remedy is a cable, not a disk.
        [ "$id" = 199 ] && hint=' (cable or bridge, not the platters)'

        if [ -n "$prev" ] && [ "$v" -gt "$prev" ]; then
            dev_notes="${dev_notes:+$dev_notes; }$label rose $prev->$v$hint"
            level=crit
        elif [ "$v" -gt 0 ]; then
            dev_notes="${dev_notes:+$dev_notes; }$label = $v (stable)$hint"
            [ "$level" = ok ] && level=warn
        fi
    done

    if [ -n "$temp" ] && [ "$temp" != null ]; then
        if [ "$temp" -ge "$TEMP_CRIT" ]; then
            dev_notes="${dev_notes:+$dev_notes; }temp ${temp}C"
            level=crit
        elif [ "$temp" -ge "$TEMP_WARN" ]; then
            dev_notes="${dev_notes:+$dev_notes; }temp ${temp}C"
            [ "$level" = ok ] && level=warn
        fi
    fi

    cp "$cur" "$snap"
    record_history "$key" "$cur"

    lcc="$(awk -F"$TAB" '$1 == 193 { print $2; exit }' "$cur")"
    lcc_norm="$(attr_norm "$json" 193)"
    if [ -n "$lcc_norm" ] && [ "$lcc_norm" != null ] && [ "$lcc_norm" -le "$LOAD_CYCLE_NORM_WARN" ]; then
        dev_notes="${dev_notes:+$dev_notes; }load cycles at ${lcc_norm}% of rated life"
        [ "$level" = ok ] && level=warn
        [ "$WORST" -lt 1 ] && WORST=1
    fi

    lcc_rate='-'
    lcc_proj='-'
    if rate_pair="$(attr_rate "$key" 193)"; then
        lcc_rate="$(printf '%s' "$rate_pair" | awk '{print $1}')"
        lcc_delta="$(printf '%s' "$rate_pair" | awk '{print $3}')"
        rate_src=observed

        # An idle period barely moves the counter, and dividing by that rate
        # projects centuries. The lifetime average is the honest fallback.
        if [ "$lcc_delta" -lt "$MIN_RATE_DELTA" ] && [ -n "$hours" ] && [ "$hours" -gt 0 ] 2>/dev/null; then
            lcc_rate="$(awk -v r="$lcc" -v h="$hours" 'BEGIN { printf "%.1f", r / h }')"
            rate_src=lifetime
        fi

        if [ -n "$lcc_norm" ] && [ "$lcc_norm" != null ]; then
            lcc_proj="$(project_days "$lcc" "$lcc_norm" "$lcc_rate")"
            if [ "$lcc_proj" -gt 3650 ] 2>/dev/null; then
                dev_notes="${dev_notes:+$dev_notes; }+${lcc_rate}/h ($rate_src), rated life 10y+"
            elif [ "$lcc_proj" -gt 0 ] 2>/dev/null; then
                dev_notes="${dev_notes:+$dev_notes; }+${lcc_rate}/h ($rate_src), rated life ends in ~${lcc_proj}d"
            fi
        fi
    fi

    case "$level" in
        crit) WORST=2 ;;
        warn) [ "$WORST" -lt 1 ] && WORST=1 ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$dev" "$level" "$model" "$serial" "${temp:--}" "${hours:--}" \
        "${lcc:--}${lcc_norm:+ (${lcc_norm}%)}" "$(printf '%s' "$passed" | tr -d ' ')" \
        "$lcc_rate" "$lcc_proj" "${dev_notes:--}" >>"$ROWS"
done <<EOF
$(discover)
EOF

[ -s "$ROWS" ] || die "no disks reported SMART data. Check: smartctl --scan"

# ------------------------------------------------------------
# KERNEL SIGNAL DELTAS
# ------------------------------------------------------------

RESETS="$(usb_reset_count)"
IOERRS="$(io_error_count)"
OVERCUR="$(over_current_count)"
KERNEL_SNAP="$STATE/kernel.tsv"
FIRST_RUN=0
PREV_RESETS=0
PREV_IOERRS=0
PREV_OVERCUR=0
if [ -f "$KERNEL_SNAP" ]; then
    PREV_RESETS="$(awk -F"$TAB" '$1 == "resets" { print $2; exit }' "$KERNEL_SNAP")"
    PREV_IOERRS="$(awk -F"$TAB" '$1 == "ioerrors" { print $2; exit }' "$KERNEL_SNAP")"
    PREV_OVERCUR="$(awk -F"$TAB" '$1 == "overcurrent" { print $2; exit }' "$KERNEL_SNAP")"
    : "${PREV_RESETS:=0}" "${PREV_IOERRS:=0}"
    # A snapshot written before over-current tracking existed has no such key.
    # Treat that as a baseline, not as a burst of brand new events.
    [ -n "$PREV_OVERCUR" ] || PREV_OVERCUR="$OVERCUR"
else
    # Everything already in the ring buffer is history, not news. Baseline it
    # instead of alerting on months of old entries the first time we look.
    FIRST_RUN=1
    PREV_RESETS="$RESETS"
    PREV_IOERRS="$IOERRS"
    PREV_OVERCUR="$OVERCUR"
fi
printf 'resets\t%s\nioerrors\t%s\novercurrent\t%s\n' "$RESETS" "$IOERRS" "$OVERCUR" >"$KERNEL_SNAP"

# dmesg is a ring buffer, so a smaller count means it wrapped, not that errors
# were undone.
RESET_DELTA=$((RESETS - PREV_RESETS))
IOERR_DELTA=$((IOERRS - PREV_IOERRS))
OVERCUR_DELTA=$((OVERCUR - PREV_OVERCUR))
[ "$RESET_DELTA" -lt 0 ] && RESET_DELTA=0
[ "$IOERR_DELTA" -lt 0 ] && IOERR_DELTA=0
[ "$OVERCUR_DELTA" -lt 0 ] && OVERCUR_DELTA=0

# Over-current is the cause; resets, renames and I/O errors are its symptoms.
# dmesg only covers the current boot, so any hit here is recent enough to act
# on and is reported whether or not it changed.
if [ "$OVERCUR" -gt 0 ]; then
    if [ "$OVERCUR_DELTA" -gt 0 ]; then
        printf 'power: %d NEW USB over-current event(s); the port cut power mid-transfer\n' \
            "$OVERCUR_DELTA" >>"$NOTES"
        WORST=2
    else
        printf 'power: %d USB over-current event(s) this boot; the bus cannot supply these drives\n' \
            "$OVERCUR" >>"$NOTES"
        [ "$WORST" -lt 1 ] && WORST=1
    fi
    printf 'power: a powered USB hub addresses this; check attribute 199 separately for cable faults\n' >>"$NOTES"
fi

if [ "$RESET_DELTA" -ge "$USB_RESET_WARN" ]; then
    printf 'usb: %d new bus resets since the last run\n' "$RESET_DELTA" >>"$NOTES"
    [ "$WORST" -lt 1 ] && WORST=1
fi
if [ "$IOERR_DELTA" -gt 0 ]; then
    printf 'io: %d new I/O or filesystem errors in the kernel log\n' "$IOERR_DELTA" >>"$NOTES"
    WORST=2
fi
if [ "$FIRST_RUN" -eq 1 ] && { [ "$RESETS" -gt 0 ] || [ "$IOERRS" -gt 0 ]; }; then
    printf 'baseline: %d reset(s) and %d I/O error(s) already in the ring buffer, recorded as history\n' \
        "$RESETS" "$IOERRS" >>"$NOTES"
fi

detect_device_changes "$PRESENT"

# ------------------------------------------------------------
# OUTPUT
# ------------------------------------------------------------

if [ "$AS_JSON" -eq 1 ]; then
    awk -F"$TAB" -v resets="$RESETS" -v rd="$RESET_DELTA" -v ioerr="$IOERRS" -v iod="$IOERR_DELTA" \
        -v oc="$OVERCUR" -v ocd="$OVERCUR_DELTA" '
        BEGIN { print "{"; printf "  \"disks\": ["; first = 1 }
        {
            if (!first) printf ","
            first = 0
            printf "\n    {\"device\":\"%s\",\"level\":\"%s\",\"model\":\"%s\",\"serial\":\"%s\",", $1, $2, $3, $4
            printf "\"temp_c\":\"%s\",\"power_on_hours\":\"%s\",\"load_cycles\":\"%s\",", $5, $6, $7
            printf "\"smart_passed\":\"%s\",\"load_cycles_per_hour\":\"%s\",", $8, $9
            printf "\"rated_life_days_left\":\"%s\",\"notes\":\"%s\"}", $10, $11
        }
        END {
            printf "\n  ],\n"
            printf "  \"usb_resets\": %d, \"usb_resets_new\": %d,\n", resets, rd
            printf "  \"usb_over_current\": %d, \"usb_over_current_new\": %d,\n", oc, ocd
            printf "  \"io_errors\": %d, \"io_errors_new\": %d\n", ioerr, iod
            print "}"
        }
    ' "$ROWS"
    exit "$WORST"
fi

if [ "$QUIET" -eq 0 ] || [ "$WORST" -gt 0 ]; then
    section "Disk health"
    printf '%-10s %-6s %-20s %5s %8s %14s  %s\n' \
        DEVICE STATE MODEL TEMP HOURS 'LOAD-CYC' NOTES
    while IFS="$TAB" read -r dev level model serial temp hours lcc passed lcc_rate lcc_proj notes; do
        case "$level" in
            crit) color="$RED" ;;
            warn) color="$YELLOW" ;;
            standby) color="$DIM" ;;
            *) color="$GREEN" ;;
        esac
        printf '%-10s %b%-6s%b %-20.20s %5s %8s %14s  %s\n' \
            "$dev" "$color" "$level" "$NC" "$model" "$temp" "$hours" "$lcc" "$notes"
    done <"$ROWS"

    if [ -s "$NOTES" ]; then
        section "Kernel signals"
        while IFS= read -r line; do
            printf '  %b%s%b\n' "$YELLOW" "$line" "$NC"
        done <"$NOTES"
    fi

    printf '\n'
    printf '%bUSB over-current: %s this boot, %s new. Bus resets: %s total, %s new. I/O errors: %s total, %s new.%b\n' \
        "$DIM" "$OVERCUR" "$OVERCUR_DELTA" "$RESETS" "$RESET_DELTA" "$IOERRS" "$IOERR_DELTA" "$NC"
    printf '%bAlerts fire on change, not on a non-zero value that has been stable.%b\n' \
        "$DIM" "$NC"
fi

if [ "$WORST" -eq 2 ]; then
    notify_dedupe hdd-crit 21600 crit "hdd-sentinel: critical disk finding" \
        "$(awk -F"$TAB" '$2 == "crit" { print $1 ": " $11 }' "$ROWS")"
elif [ "$WORST" -eq 1 ]; then
    notify_dedupe hdd-warn 86400 warn "hdd-sentinel: disk warning" \
        "$(awk -F"$TAB" '$2 == "warn" { print $1 ": " $11 }' "$ROWS")"
fi

exit "$WORST"
