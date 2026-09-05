#!/usr/bin/env bash
#
# ============================================================
# disk-runway - days until this filesystem is full
# ============================================================
#
# Runs on: Mac + Pi (bash 3.2 safe)
# Requires: df awk
#
# Samples used space hourly, then fits a least-squares line over the history to
# answer the only question that matters: how long until this fills up.
#
# Two slopes are reported. When the 7 day slope is much steeper than the 30 day
# slope, something changed recently, and that is more actionable than the raw
# runway. R-squared is reported alongside so "58 days, confident" is
# distinguishable from "58 days, but the data is noise".
#
# --attribute turns a warning into an action by diffing per-directory usage
# against the previous snapshot, naming what actually grew.
#
# Config file (default ~/.config/disk-runway.conf, mode 600):
#   MOUNTS="/ /mnt/backup-drive"
#   WARN_DAYS=60
#   CRIT_DAYS=14
#
# Usage:  disk-runway.sh --sample            (hourly, from a timer)
#         disk-runway.sh [--report] [--days N] [--json]
#         disk-runway.sh --attribute /mnt/backup-drive
# ============================================================

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

TAB="$(printf '\t')"
NOW="$(date +%s)"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

load_config disk-runway

MOUNTS="${MOUNTS:-}"
WARN_DAYS="${WARN_DAYS:-60}"
CRIT_DAYS="${CRIT_DAYS:-14}"
WINDOW_DAYS="${WINDOW_DAYS:-30}"

MODE=report
ATTRIBUTE_MOUNT=''
AS_JSON=0
QUIET=0

usage() {
    cat <<'EOF'
Estimate how many days until each filesystem is full.

Usage: disk-runway.sh [options]

  --sample             Record one measurement. Run hourly from a timer.
  --report             Show the forecast (default).
  --days N             Regression window in days (default 30).
  --attribute MOUNT    Show which directories grew since the last snapshot.
  --quiet              Print nothing unless a threshold is crossed.
  --json               Machine-readable output.
  -h, --help           Show this help.

Exits 1 below WARN_DAYS and 2 below CRIT_DAYS, so a timer can alert on it.

Settings (config file wins over environment): MOUNTS, WARN_DAYS, CRIT_DAYS
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --sample)
            MODE=sample
            shift
            ;;
        --report)
            MODE=report
            shift
            ;;
        --attribute)
            MODE=attribute
            ATTRIBUTE_MOUNT="${2:?--attribute needs a mount point}"
            shift 2
            ;;
        --days)
            WINDOW_DAYS="${2:?--days needs a value}"
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

case "$WINDOW_DAYS" in
    '' | *[!0-9]* | 0) die "--days must be a positive integer" ;;
esac

require_tools df awk

STATE="$(state_dir disk-runway)"
SAMPLES="$STATE/samples.tsv"

# ------------------------------------------------------------
# MOUNT DISCOVERY
#
# Real block devices only. Both platforms report those as /dev/*, which keeps
# tmpfs, overlays and macOS synthetic volumes out of the history.
# ------------------------------------------------------------

discover_mounts() {
    if [ -n "$MOUNTS" ]; then
        # shellcheck disable=SC2086  # MOUNTS is a space separated list
        printf '%s\n' $MOUNTS
        return 0
    fi
    { df -P -k 2>/dev/null || true; } | awk '
        NR > 1 && $1 ~ /^\/dev\// {
            mp = $6
            for (i = 7; i <= NF; i++) mp = mp " " $i
            if (mp ~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware)/) next
            print mp
        }'
}

# ------------------------------------------------------------
# SAMPLE
# ------------------------------------------------------------

do_sample() {
    local mp used total line count=0
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        line="$({ df -P -k "$mp" 2>/dev/null || true; } | awk 'NR==2 { print $2, $3 }')"
        [ -n "$line" ] || continue
        total="${line%% *}"
        used="${line##* }"
        case "$total$used" in
            '' | *[!0-9]*) continue ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$NOW" "$mp" "$used" "$total" >>"$SAMPLES"
        count=$((count + 1))
    done <<EOF
$(discover_mounts)
EOF
    [ "$QUIET" -eq 1 ] || ok "recorded $count mount(s) to $SAMPLES"
}

# ------------------------------------------------------------
# FORECAST
#
# One awk pass per mount: closed-form least squares over (epoch, used_kb),
# which needs no external maths and stays exact enough for a daily trend.
# ------------------------------------------------------------

# forecast <mount> <window_days> -> "slope_kb_per_day r2 samples span_days"
forecast() {
    local mp="$1" days="$2" cutoff
    cutoff=$((NOW - days * 86400))

    awk -F"$TAB" -v mp="$mp" -v cutoff="$cutoff" '
        $2 == mp && $1 >= cutoff {
            x = $1; y = $3
            n++; sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y
            if (n == 1 || x < minx) minx = x
            if (n == 1 || x > maxx) maxx = x
        }
        END {
            if (n < 3) { print "nodata"; exit }
            denom = n * sxx - sx * sx
            vary  = n * syy - sy * sy
            if (denom <= 0) { print "nodata"; exit }
            slope = (n * sxy - sx * sy) / denom
            num = n * sxy - sx * sy
            r2 = (vary <= 0) ? 1 : (num * num) / (denom * vary)
            printf "%.4f %.4f %d %.2f\n", slope * 86400, r2, n, (maxx - minx) / 86400
        }' "$SAMPLES"
}

current_usage() {
    { df -P -k "$1" 2>/dev/null || true; } | awk 'NR==2 { print $2, $3, $4 }'
}

# runway_days <free_kb> <slope_per_day>
runway_days() {
    awk -v free="$1" -v slope="$2" 'BEGIN {
        if (slope <= 0) { print "-1"; exit }
        printf "%.0f", free / slope
    }'
}

# rate_text <kb_per_day> - signed, human readable growth rate.
rate_text() {
    awk -v v="$1" 'BEGIN {
        s = (v < 0) ? "-" : "+"
        a = (v < 0) ? -v : v
        split("K M G T", u, " ")
        i = 1
        while (a >= 1024 && i < 4) { a /= 1024; i++ }
        printf "%s%.1f%s", s, a, u[i]
    }'
}

do_report() {
    if [ ! -s "$SAMPLES" ]; then
        # Not an error: the timer has simply not run yet.
        [ "$QUIET" -eq 1 ] || info "no samples yet. Run disk-runway --sample, or wait for the hourly timer."
        exit "$EX_OK"
    fi

    local mp f30 f7 slope30 r2 n span slope7 usage total used free runway flag
    local worst=999999 rows="$STATE/.report.$$"
    : >"$rows"

    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        f30="$(forecast "$mp" "$WINDOW_DAYS")"
        [ "$f30" = nodata ] && continue

        slope30="$(printf '%s' "$f30" | awk '{ print $1 }')"
        r2="$(printf '%s' "$f30" | awk '{ print $2 }')"
        n="$(printf '%s' "$f30" | awk '{ print $3 }')"
        span="$(printf '%s' "$f30" | awk '{ print $4 }')"

        f7="$(forecast "$mp" 7)"
        if [ "$f7" = nodata ]; then
            slope7="$slope30"
        else
            slope7="$(printf '%s' "$f7" | awk '{ print $1 }')"
        fi

        usage="$(current_usage "$mp")"
        [ -n "$usage" ] || continue
        total="$(printf '%s' "$usage" | awk '{ print $1 }')"
        used="$(printf '%s' "$usage" | awk '{ print $2 }')"
        free="$(printf '%s' "$usage" | awk '{ print $3 }')"

        runway="$(runway_days "$free" "$slope7")"

        flag=''
        if awk -v a="$slope7" -v b="$slope30" 'BEGIN { exit !(b > 0 && a > b * 2) }'; then
            flag=accelerating
        elif awk -v a="$slope30" 'BEGIN { exit !(a <= 0) }'; then
            flag=shrinking
        fi
        if awk -v r="$r2" 'BEGIN { exit !(r < 0.5) }'; then
            flag="${flag:+$flag,}noisy"
        fi
        # Extrapolating a 30 day runway from two days of samples is guesswork.
        if awk -v s="$span" -v w="$WINDOW_DAYS" 'BEGIN { exit !(s < w / 2) }'; then
            flag="${flag:+$flag,}short-history"
        fi

        [ "$runway" -ge 0 ] && [ "$runway" -lt "$worst" ] && worst="$runway"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$mp" "$used" "$total" "$free" "$slope7" "$slope30" "$runway" "$r2" "$n" "${flag:--}" \
            >>"$rows"
    done <<EOF
$(discover_mounts)
EOF

    if [ ! -s "$rows" ]; then
        rm -f "$rows"
        [ "$QUIET" -eq 1 ] || info "not enough history yet; need at least 3 samples per mount."
        exit "$EX_OK"
    fi

    if [ "$AS_JSON" -eq 1 ]; then
        awk -F"$TAB" '
            BEGIN { print "["; first = 1 }
            {
                if (!first) print ","
                first = 0
                printf "  {\"mount\":\"%s\",\"used_kb\":%d,\"total_kb\":%d,\"free_kb\":%d,",
                    $1, $2, $3, $4
                printf "\"kb_per_day_7d\":%.1f,\"kb_per_day_30d\":%.1f,",
                    $5, $6
                printf "\"runway_days\":%d,\"r2\":%.3f,\"samples\":%d,\"flag\":\"%s\"}",
                    $7, $8, $9, $10
            }
            END { print ""; print "]" }
        ' "$rows"
        rm -f "$rows"
    else
        if [ "$QUIET" -eq 0 ] || [ "$worst" -lt "$WARN_DAYS" ]; then
            section "Disk runway (${WINDOW_DAYS}d window)"
            printf '%-22s %9s %5s %11s %11s %8s %5s  %s\n' \
                MOUNT USED 'USE%' 7D/DAY 30D/DAY RUNWAY 'R2' FLAG
            while IFS="$TAB" read -r mp used total free s7 s30 runway r2 n flag; do
                local pct rtxt color rate7 rate30
                pct="$(awk -v u="$used" -v t="$total" 'BEGIN { printf "%.0f%%", t ? u / t * 100 : 0 }')"
                rate7="$(rate_text "$s7")"
                rate30="$(rate_text "$s30")"
                color="$NC"
                if [ "$runway" -lt 0 ]; then
                    rtxt='none'
                else
                    rtxt="${runway}d"
                    [ "$runway" -lt "$WARN_DAYS" ] && color="$YELLOW"
                    [ "$runway" -lt "$CRIT_DAYS" ] && color="$RED"
                fi
                printf '%-22.22s %9s %5s %11s %11s %b%8s%b %5.2f  %s\n' \
                    "$mp" "$(human_bytes $((used * 1024)))" "$pct" \
                    "$rate7" "$rate30" "$color" "$rtxt" "$NC" "$r2" "$flag"
            done <"$rows"
        fi
        rm -f "$rows"
    fi

    if [ "$worst" -lt "$CRIT_DAYS" ]; then
        notify_dedupe "runway-crit" 21600 crit \
            "disk-runway: a filesystem fills in ${worst} days"
        exit "$EX_CRIT"
    elif [ "$worst" -lt "$WARN_DAYS" ]; then
        notify_dedupe "runway-warn" 86400 warn \
            "disk-runway: a filesystem fills in ${worst} days"
        exit "$EX_WARN"
    fi
    exit "$EX_OK"
}

# ------------------------------------------------------------
# ATTRIBUTION
#
# A runway warning is only useful if you know what is eating the space.
# ------------------------------------------------------------

do_attribute() {
    local mp="$1"
    [ -d "$mp" ] || die "not a directory: $mp"
    require_tools du

    local key snap prev
    key="$(printf '%s' "$mp" | tr -c 'A-Za-z0-9' '_')"
    snap="$STATE/du-$key.tsv"
    prev="$STATE/du-$key.prev.tsv"

    [ -f "$snap" ] && cp "$snap" "$prev"

    info "measuring $mp ..."
    { du -sk -x "$mp"/* 2>/dev/null || true; } | awk '{ k = $1; $1 = ""; sub(/^ /, ""); print $0 "\t" k }' |
        sort >"$snap"

    if [ ! -s "$prev" ]; then
        ok "first snapshot recorded. Run again later to see what grew."
        exit "$EX_OK"
    fi

    section "Growth in $mp since the previous snapshot"
    join -t"$TAB" -a1 -a2 -e 0 -o '0,1.2,2.2' "$prev" "$snap" 2>/dev/null |
        awk -F"$TAB" '{ d = $3 - $2; if (d != 0) printf "%d\t%s\n", d, $1 }' |
        sort -rn | head -20 |
        while IFS="$TAB" read -r delta path; do
            if [ "$delta" -gt 0 ]; then
                printf '  %b+%-12s%b %s\n' "$YELLOW" "$(human_bytes $((delta * 1024)))" "$NC" "$path"
            else
                printf '  %b-%-12s%b %s\n' "$GREEN" "$(human_bytes $((-delta * 1024)))" "$NC" "$path"
            fi
        done
    exit "$EX_OK"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

case "$MODE" in
    sample) with_lock disk-runway do_sample ;;
    report) do_report ;;
    attribute) do_attribute "$ATTRIBUTE_MOUNT" ;;
esac
