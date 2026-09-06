#!/usr/bin/env bash
#
# ============================================================
# rpistats - Raspberry Pi system health on one screen
# ============================================================
#
# Runs on: Pi (bash 5)
# Requires: awk
#
# CPU, memory, storage, network, services and Immich containers, colour coded
# against thresholds so problems stand out without reading the numbers.
#
# --oneline collapses the whole report to a single line, which is what
# obsidian-daily embeds in the daily note.
#
# Config file (default ~/.config/rpistats.conf, mode 600):
#   SERVICES="ssh docker"
#   IMMICH_CONTAINERS="immich_postgres=PostgreSQL immich_server=Server"
#   TEMP_WARN=60
#   TEMP_CRIT=70
#
# Usage:  rpistats.sh [--oneline]
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

load_config rpistats

SERVICES="${SERVICES:-ssh docker}"
# container=Label pairs, space separated. Labels cannot contain spaces.
IMMICH_CONTAINERS="${IMMICH_CONTAINERS:-immich_postgres=PostgreSQL immich_server=Server immich_redis=Cache immich_machine_learning=ML}"
TEMP_WARN="${TEMP_WARN:-60}"
TEMP_CRIT="${TEMP_CRIT:-70}"
DISK_WARN="${DISK_WARN:-85}"
DISK_CRIT="${DISK_CRIT:-95}"
ROOT_WARN="${ROOT_WARN:-90}"
STATUS_SOURCES="${STATUS_SOURCES-disk-runway hdd-sentinel wan-watch boot-story}"
RUNWAY_MAX_AGE="${RUNWAY_MAX_AGE:-7200}"
HDD_MAX_AGE="${HDD_MAX_AGE:-93600}"
WAN_MAX_AGE="${WAN_MAX_AGE:-300}"
BOOT_MAX_AGE="${BOOT_MAX_AGE:-0}"

ONELINE=0

usage() {
    cat <<'EOF'
Raspberry Pi health: CPU, memory, storage, network, services, Immich.

Usage: rpistats.sh [options]

  --oneline    Collapse the report to a single line for embedding elsewhere.
  -h, --help   Show this help.

Settings (config file wins over environment):
  SERVICES, IMMICH_CONTAINERS, TEMP_WARN, TEMP_CRIT, DISK_WARN, DISK_CRIT
    STATUS_SOURCES, RUNWAY_MAX_AGE, HDD_MAX_AGE, WAN_MAX_AGE, BOOT_MAX_AGE

Monitoring summaries read cached results only. MAX_AGE settings are seconds;
0 disables age expiry. Results from another boot are always stale.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --oneline)
            ONELINE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

# Checked after argument parsing so --help works on any platform.
require_linux

for CACHE_SETTING in RUNWAY_MAX_AGE HDD_MAX_AGE WAN_MAX_AGE BOOT_MAX_AGE; do
    CACHE_VALUE="${!CACHE_SETTING}"
    case "$CACHE_VALUE" in
        '' | *[!0-9]* | 0[0-9]*) die "$CACHE_SETTING must be a non-negative integer without leading zeros" ;;
    esac
    [ "${#CACHE_VALUE}" -le 9 ] || die "$CACHE_SETTING is too large"
done
for STATUS_SOURCE in $STATUS_SOURCES; do
    case "$STATUS_SOURCE" in
        disk-runway | hdd-sentinel | wan-watch | boot-story) ;;
        *) die "unknown STATUS_SOURCES entry: $STATUS_SOURCE" ;;
    esac
done
STATUS_NOW="$(date +%s)"
STATUS_BOOT_ID='-'
if [ -r /proc/sys/kernel/random/boot_id ]; then
    IFS= read -r STATUS_BOOT_ID </proc/sys/kernel/random/boot_id || STATUS_BOOT_ID='-'
fi

# ------------------------------------------------------------
# MEASUREMENTS
# ------------------------------------------------------------

cpu_temp() {
    local raw
    raw="$(vcgencmd measure_temp 2>/dev/null | cut -d '=' -f2 || true)"
    printf '%s' "${raw%\'C}"
}

cpu_usage() {
    { top -bn1 2>/dev/null || true; } | awk -F'[,:%]' '/Cpu\(s\)/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /id/) {
                gsub(/[^0-9.]/, "", $(i - 1))
                printf "%.1f", 100 - $(i - 1)
                exit
            }
        }
    }'
}

mem_percent() { free 2>/dev/null | awk '/Mem:/ { printf "%.1f", $3 / $2 * 100 }'; }
root_percent() { df -P / 2>/dev/null | awk 'NR==2 { gsub("%", "", $5); print $5 }'; }

# Mounted partitions on external USB disks as "device<TAB>mount<TAB>use%".
external_disks() {
    local dev mp use
    lsblk -pnro NAME,TYPE,MOUNTPOINT 2>/dev/null |
        awk '$2 == "part" && $1 ~ /^\/dev\/sd[a-z][0-9]+$/ && $3 != "" { print $1, $3 }' |
        while read -r dev mp; do
            use="$(df -P "$mp" 2>/dev/null | awk 'NR==2 { gsub("%", "", $5); print $5 }')"
            [ -n "$use" ] && printf '%s\t%s\t%s\n' "$dev" "$mp" "$use"
        done
}

container_state() {
    local name="$1" status health
    command -v docker >/dev/null 2>&1 || {
        printf 'no docker'
        return 0
    }
    status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
    [ -n "$status" ] || {
        printf 'not found'
        return 0
    }
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)"
    if [ "$status" = running ] && [ "$health" = unhealthy ]; then
        printf 'running / UNHEALTHY'
    elif [ "$status" = running ] && [ "$health" = healthy ]; then
        printf 'running / healthy'
    else
        printf '%s' "$status"
    fi
}

cached_summary() {
    local source="$1" title="$2" key="$3" max_age="$4"
    local dir="${XDG_STATE_HOME:-$HOME/.local/state}/$source" payload='' rows=''
    local level=unavailable message='no cached result' checked_at snapshot_boot _version age observed_level
    local label row_level text color
    if [ -r "$dir/status.tsv" ]; then
        if payload="$(LC_ALL=C awk -F '\t' '
            NR == 1 {
                if (NF != 4 || $1 != "1" || $2 !~ /^[1-9][0-9]*$/ || length($2) > 12 ||
                    $3 !~ /^(ok|warn|crit|unknown)$/ || $4 !~ /^[A-Za-z0-9._-]+$/) exit 1
                print
                next
            }
            {
                if (NF != 3 || $1 == "" || $3 == "" || $2 !~ /^(ok|warn|crit|unknown)$/ ||
                    $1 ~ /[[:cntrl:]]/ || $3 ~ /[[:cntrl:]]/) exit 1
                print
            }
            END { if (NR < 2) exit 1 }
        ' "$dir/status.tsv" 2>/dev/null)"; then
            IFS="$TAB" read -r _version checked_at level snapshot_boot <<EOF
$payload
EOF
            if [ "$checked_at" -gt "$STATUS_NOW" ]; then
                level=unavailable
                message='cached timestamp is in the future'
            else
                age=$((STATUS_NOW - checked_at))
                rows="${payload#*$'\n'}"
                message="checked $(human_duration "$age") ago"
                observed_level="$level"
                if [ "$snapshot_boot" != "$STATUS_BOOT_ID" ]; then
                    level=stale
                    message="$message; from a different boot; last result $observed_level"
                elif [ "$max_age" -gt 0 ] && [ "$age" -gt "$max_age" ]; then
                    level=stale
                    message="$message; last result $observed_level"
                fi
            fi
        else
            message='invalid cached result'
        fi
    elif [ ! -e "$dir" ] && [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/$source.conf" ]; then
        level='not configured'
    fi

    if [ "$ONELINE" -eq 1 ]; then
        printf ' | %s %s' "$key" "$level"
        return 0
    fi

    section "$title"
    case "$level" in
        ok) color="$GREEN" ;;
        crit) color="$RED" ;;
        warn | stale | unknown | unavailable) color="$YELLOW" ;;
        *) color="$DIM" ;;
    esac
    printf "%-${KV_WIDTH}s %b%s%b; %s\n" Status "$color" "$level" "$NC" "$message"
    [ -n "$rows" ] || return 0
    while IFS="$TAB" read -r label row_level text; do
        case "$row_level" in
            ok) color="$GREEN" ;;
            crit) color="$RED" ;;
            *) color="$YELLOW" ;;
        esac
        [ "$level" != stale ] || color="$DIM"
        printf "  %-${KV_WIDTH}s %b%s%b; %s\n" "$label" "$color" "$row_level" "$NC" "$text"
    done <<EOF
$rows
EOF
}

cached_summaries() {
    local source
    for source in $STATUS_SOURCES; do
        case "$source" in
            disk-runway) cached_summary "$source" 'Storage outlook' runway "$RUNWAY_MAX_AGE" ;;
            hdd-sentinel) cached_summary "$source" 'Drive health' hdd "$HDD_MAX_AGE" ;;
            wan-watch) cached_summary "$source" 'Connection quality' wan "$WAN_MAX_AGE" ;;
            boot-story) cached_summary "$source" 'Last reboot' boot "$BOOT_MAX_AGE" ;;
        esac
    done
}

# ------------------------------------------------------------
# ONELINE
# ------------------------------------------------------------

if [ "$ONELINE" -eq 1 ]; then
    line="$(hostname) up $(uptime -p 2>/dev/null | sed 's/^up //' || echo '?')"
    t="$(cpu_temp)"
    [ -n "$t" ] && line="$line | cpu ${t}C $(cpu_usage)%"
    line="$line | ram $(mem_percent)% | / $(root_percent)%"

    while IFS="$TAB" read -r _ mp use; do
        [ -n "$mp" ] || continue
        line="$line | $(basename "$mp") ${use}%"
    done <<EOF
$(external_disks)
EOF

    down=0
    for spec in $IMMICH_CONTAINERS; do
        case "$(container_state "${spec%%=*}")" in
            running*) ;;
            *) down=$((down + 1)) ;;
        esac
    done
    if [ "$down" -eq 0 ]; then
        line="$line | immich ok"
    else
        line="$line | immich $down down"
    fi

    printf '%s' "$line"
    cached_summaries
    printf '\n'
    exit "$EX_OK"
fi

# ------------------------------------------------------------
# REPORT
# ------------------------------------------------------------

print_status() {
    local label="$1" status="$2" color
    case "$status" in
        running* | active | healthy) color="$GREEN" ;;
        warning | degraded) color="$YELLOW" ;;
        *) color="$RED" ;;
    esac
    printf "%-${KV_WIDTH}s %b%s%b\n" "$label" "$color" "$status" "$NC"
}

section "===== Raspberry Pi Health ====="

section "System"
kv "Hostname" "$(hostname)"
kv "Uptime" "$(uptime -p 2>/dev/null || true)"
kv "Load Average" "$(awk '{ print $1", "$2", "$3 }' /proc/loadavg)"

section "CPU"
TEMP_C="$(cpu_temp)"
if [ -n "$TEMP_C" ]; then
    if awk -v t="$TEMP_C" -v c="$TEMP_CRIT" 'BEGIN { exit !(t >= c) }'; then
        TEMP_COLOR="$RED"
    elif awk -v t="$TEMP_C" -v w="$TEMP_WARN" 'BEGIN { exit !(t >= w) }'; then
        TEMP_COLOR="$YELLOW"
    else
        TEMP_COLOR="$GREEN"
    fi
    printf "%-${KV_WIDTH}s %b%s°C%b\n" "Temperature" "$TEMP_COLOR" "$TEMP_C" "$NC"
fi
kv "CPU Usage" "$(cpu_usage)%"
kv "CPU Clock" "$({ vcgencmd measure_clock arm 2>/dev/null || true; } | awk -F= '{ printf "%.0f MHz", $2 / 1000000 }')"
kv "Top CPU Process" "$({ ps -eo comm,%cpu --sort=-%cpu 2>/dev/null || true; } | sed -n '2p')"

section "Memory"
kv "RAM Total" "$(free -h | awk '/Mem:/ { print $2 }')"
kv "RAM Used" "$(free -h | awk '/Mem:/ { print $3 }')"
kv "RAM Available" "$(free -h | awk '/Mem:/ { print $7 }')"
kv "RAM Usage" "$(mem_percent)%"
kv "Swap Used" "$(free -h | awk '/Swap:/ { print $3" / "$2 }')"

section "Storage"
kv "Root (/)" "$(df -h / | awk 'NR==2 { printf "%s / %s used / %s free (%s)", $2, $3, $4, $5 }')"
ROOT_USED="$(root_percent)"
if [ -n "$ROOT_USED" ] && [ "$ROOT_USED" -ge "$ROOT_WARN" ]; then
    printf '%bWARNING: root filesystem is %s%% full%b\n' "$RED" "$ROOT_USED" "$NC"
fi

printf '\nExternal disks:\n'
FOUND=0
while IFS="$TAB" read -r dev mp use; do
    [ -n "$dev" ] || continue
    FOUND=1
    if [ "$use" -ge "$DISK_CRIT" ]; then
        COLOR="$RED"
    elif [ "$use" -ge "$DISK_WARN" ]; then
        COLOR="$YELLOW"
    else
        COLOR="$GREEN"
    fi
    printf '\n  Device      : %s\n' "$dev"
    printf '  Mount Point : %s\n' "$mp"
    printf '  Usage       : %b%s%b\n' "$COLOR" \
        "$(df -h "$mp" | awk 'NR==2 { printf "%s total / %s used / %s free (%s)", $2, $3, $4, $5 }')" "$NC"
    [ "$use" -ge "$DISK_CRIT" ] && printf '  %bWARNING: disk almost full%b\n' "$RED" "$NC"
done <<EOF
$(external_disks)
EOF
[ "$FOUND" -eq 1 ] || printf '  %bno mounted external disks found%b\n' "$RED" "$NC"

section "Network"
ip -4 -o addr show up 2>/dev/null |
    awk '$2 !~ /^(lo|docker.*|br-.*|veth.*)$/ { split($4, a, "/"); printf "%-24s %s\n", $2, a[1] }'

section "System Services"
for svc in $SERVICES; do
    if [ "$(systemctl is-active "$svc" 2>/dev/null || true)" = active ]; then
        print_status "$svc" running
    else
        print_status "$svc" stopped
    fi
done

section "Immich"
for spec in $IMMICH_CONTAINERS; do
    [ -n "$spec" ] || continue
    print_status "${spec#*=}" "$(container_state "${spec%%=*}")"
done

cached_summaries

printf '\n'
