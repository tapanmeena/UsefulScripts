#!/usr/bin/env bash
#
# ============================================================
# rpistats - Raspberry Pi system health on one screen
# ============================================================
#
# Runs on: Pi (bash 5)
# Requires: awk jq
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
# Usage:  rpistats.sh [--oneline | --json] [--check]
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

SERVICES="${SERVICES-ssh docker}"
# container=Label pairs, space separated. Labels cannot contain spaces.
IMMICH_CONTAINERS="${IMMICH_CONTAINERS-immich_postgres=PostgreSQL immich_server=Server immich_redis=Cache immich_machine_learning=ML}"
TEMP_WARN="${TEMP_WARN:-60}"
TEMP_CRIT="${TEMP_CRIT:-70}"
DISK_WARN="${DISK_WARN:-85}"
DISK_CRIT="${DISK_CRIT:-95}"
ROOT_WARN="${ROOT_WARN:-90}"
ROOT_CRIT="${ROOT_CRIT:-95}"
RAM_WARN="${RAM_WARN:-85}"
RAM_CRIT="${RAM_CRIT:-95}"
EXPECTED_MOUNTS="${EXPECTED_MOUNTS:-}"
CPU_SAMPLE_SECONDS="${CPU_SAMPLE_SECONDS:-0.2}"
STATUS_SOURCES="${STATUS_SOURCES-disk-runway hdd-sentinel wan-watch boot-story}"
RUNWAY_MAX_AGE="${RUNWAY_MAX_AGE:-7200}"
HDD_MAX_AGE="${HDD_MAX_AGE:-93600}"
WAN_MAX_AGE="${WAN_MAX_AGE:-300}"
BOOT_MAX_AGE="${BOOT_MAX_AGE:-0}"

ONELINE=0
AS_JSON=0
CACHED_JSON='[]'
CHECK_HEALTH=0
HEALTH_CODE=0
HEALTH_STATUS=ok

usage() {
    cat <<'EOF'
Raspberry Pi health: CPU, memory, storage, network, services, Immich.

Usage: rpistats.sh [options]

  --oneline    Collapse the report to a single line for embedding elsewhere.
    --json       Emit one structured JSON report (cannot combine with --oneline).
    --check      Exit 0 healthy, 1 warning/unknown, or 2 critical after reporting.
  -h, --help   Show this help.

Settings (config file wins over environment):
  SERVICES, IMMICH_CONTAINERS, TEMP_WARN, TEMP_CRIT, DISK_WARN, DISK_CRIT
    ROOT_WARN, ROOT_CRIT, RAM_WARN, RAM_CRIT, CPU_SAMPLE_SECONDS, EXPECTED_MOUNTS
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
        --check)
            CHECK_HEALTH=1
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

[ "$ONELINE" -eq 0 ] || [ "$AS_JSON" -eq 0 ] || die '--json and --oneline cannot be combined'

# Checked after argument parsing so --help works on any platform.
require_linux
require_tools awk jq
export LC_ALL=C

for THRESHOLD_GROUP in TEMP ROOT DISK RAM; do
    WARN_SETTING="${THRESHOLD_GROUP}_WARN"
    CRIT_SETTING="${THRESHOLD_GROUP}_CRIT"
    WARN_VALUE="${!WARN_SETTING}"
    CRIT_VALUE="${!CRIT_SETTING}"
    if ! awk -v warning="$WARN_VALUE" -v critical="$CRIT_VALUE" -v group="$THRESHOLD_GROUP" 'BEGIN {
        limit = group == "TEMP" ? 200 : 100
        exit !(warning ~ /^[0-9]+$/ && critical ~ /^[0-9]+$/ &&
            warning + 0 <= critical + 0 && critical + 0 <= limit)
    }'; then
        die "$WARN_SETTING and $CRIT_SETTING must be ordered non-negative thresholds (percentages at most 100)"
    fi
done
EXPECTED_MOUNT_LIST="$(jq -cn --arg mounts "$EXPECTED_MOUNTS" '
    $mounts | split("\n") | map(select(length > 0) | sub("/+$"; "") | if . == "" then "/" else . end) | unique
')"
if ! printf '%s' "$EXPECTED_MOUNT_LIST" | jq -e 'all(.[]; startswith("/"))' >/dev/null; then
    die 'EXPECTED_MOUNTS must contain absolute mount paths, one per line'
fi

if ! awk -v interval="$CPU_SAMPLE_SECONDS" 'BEGIN {
    exit !(interval ~ /^[0-9]+([.][0-9]+)?$/ && interval > 0 && interval <= 5)
}'; then
    die 'CPU_SAMPLE_SECONDS must be greater than 0 and at most 5'
fi

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
STATUS_BOOT_ID='-'
if [ -r /proc/sys/kernel/random/boot_id ]; then
    IFS= read -r STATUS_BOOT_ID </proc/sys/kernel/random/boot_id || STATUS_BOOT_ID='-'
fi

# ------------------------------------------------------------
# MEASUREMENTS
# ------------------------------------------------------------

cpu_temp() {
    local raw
    raw="$(vcgencmd measure_temp 2>/dev/null | awk -F= '
        /^temp=/ { sub(/.C$/, "", $2); if ($2 ~ /^[0-9]+([.][0-9]+)?$/) print $2 }
    ' || true)"
    if [ -z "$raw" ] && [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        raw="$(awk '/^[0-9]+$/ { printf "%.1f", $1 / 1000 }' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)"
    fi
    printf '%s' "$raw"
}

cpu_usage() {
    { top -bn2 -d "$CPU_SAMPLE_SECONDS" 2>/dev/null || true; } | awk -F'[,:%]' '
        /Cpu\(s\)/ {
            for (field = 1; field <= NF; field++) {
                if ($field ~ /[[:space:]]id([[:space:]]|$)/) {
                    idle = $field
                    gsub(/[^0-9.]/, "", idle)
                    if (idle ~ /^[0-9]+([.][0-9]+)?$/ && idle + 0 >= 0 && idle + 0 <= 100) {
                        usage = 100 - idle
                        samples++
                    }
                }
            }
        }
        END { if (samples >= 2) printf "%.1f", usage }
    '
}

cpu_clock() {
    local clock
    clock="$(vcgencmd measure_clock arm 2>/dev/null | awk -F= '
        /^frequency\([0-9]+\)=/ && $2 ~ /^[0-9]+$/ && $2 > 0 { printf "%.0f", $2 / 1000000 }
    ' || true)"
    if [ -z "$clock" ] && [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
        clock="$(awk '/^[0-9]+$/ && $1 > 0 { printf "%.0f", $1 / 1000 }' \
            /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || true)"
    fi
    printf '%s' "$clock"
}

collect_memory() {
    read -r RAM_TOTAL RAM_USED RAM_AVAILABLE RAM_USAGE SWAP_TOTAL SWAP_USED <<EOF
$({ free -b 2>/dev/null || true; } | awk '
    BEGIN { total = used = available = percent = swap_total = swap_used = "-" }
    /^Mem:/ && $2 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/ && $2 > 0 && $7 <= $2 {
        total = $2; available = $7; used = total - available
        percent = sprintf("%.1f", used / total * 100)
    }
    /^Swap:/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 <= $2 {
        swap_total = $2; swap_used = $3
    }
    END { print total, used, available, percent, swap_total, swap_used }
')
EOF
}

percent_text() {
    case "$1" in
        '' | '-') printf unavailable ;;
        *) printf '%s%%' "$1" ;;
    esac
}

bytes_text() {
    case "$1" in
        '' | '-') printf unavailable ;;
        *) human_bytes "$1" ;;
    esac
}

collect_power() {
    local raw register bit labels current='' history=''
    raw="$(vcgencmd get_throttled 2>/dev/null || true)"
    POWER_REGISTER=''
    POWER_LEVEL=unknown
    POWER_CURRENT=unavailable
    POWER_HISTORY=unavailable
    [[ "$raw" =~ ^throttled=0x[[:xdigit:]]{1,8}$ ]] || return 0
    POWER_REGISTER="${raw#throttled=}"
    register=$((POWER_REGISTER))
    labels=('undervoltage' 'frequency capped' 'throttled' 'soft temperature limit')
    for bit in 0 1 2 3; do
        if [ "$((register & (1 << bit)))" -ne 0 ]; then
            current="${current:+$current, }${labels[$bit]}"
        fi
        if [ "$((register & (1 << (bit + 16))))" -ne 0 ]; then
            history="${history:+$history, }${labels[$bit]}"
        fi
    done
    POWER_CURRENT="${current:-none}"
    POWER_HISTORY="${history:-none}"
    POWER_LEVEL=ok
    if [ "$((register & 5))" -ne 0 ]; then
        POWER_LEVEL=crit
    elif [ "$register" -ne 0 ]; then
        POWER_LEVEL=warn
    fi
    if [ "$((register & ~0xF000F))" -ne 0 ]; then
        POWER_CURRENT="${POWER_CURRENT}; unrecognized register flags"
    fi
}

numeric_level() {
    awk -v value="$1" -v warning="$2" -v critical="$3" 'BEGIN {
        if (value !~ /^[0-9]+([.][0-9]+)?$/) print "unknown"
        else if (value + 0 >= critical + 0) print "crit"
        else if (value + 0 >= warning + 0) print "warn"
        else print "ok"
    }'
}

record_health() {
    case "$1" in
        crit)
            HEALTH_CODE=2
            HEALTH_STATUS=crit
            ;;
        warn | stale)
            if [ "$HEALTH_CODE" -lt 2 ]; then
                HEALTH_CODE=1
                HEALTH_STATUS=warn
            fi
            ;;
        unknown | unavailable)
            if [ "$HEALTH_CODE" -eq 0 ]; then
                HEALTH_CODE=1
                HEALTH_STATUS=unknown
            fi
            ;;
    esac
    return 0
}

finish_report() {
    [ "$CHECK_HEALTH" -eq 0 ] || exit "$HEALTH_CODE"
    exit "$EX_OK"
}

collect_storage() {
    local inventory mounts record target mounted usage total used available percent level
    local rows='' inventory_ok=true
    MOUNT_INVENTORY_LEVEL=ok
    if ! inventory="$(findmnt --json --list --output SOURCE,TARGET,FSTYPE 2>/dev/null)" ||
        ! printf '%s' "$inventory" | jq -e '
            type == "object" and (.filesystems | type == "array") and
            all(.filesystems[]; (.source | type == "string") and (.target | type == "string" and startswith("/")))
        ' >/dev/null 2>&1; then
        inventory='{"filesystems":[]}'
        inventory_ok=false
        MOUNT_INVENTORY_LEVEL=unknown
    fi
    mounts="$(printf '%s' "$inventory" | jq -c --argjson expected "$EXPECTED_MOUNT_LIST" --argjson inventory_ok "$inventory_ok" '
        [.filesystems[] | .target as $target |
            select($target == "/" or ($expected | index($target)) != null or
                ((.source | startswith("/dev/")) and .fstype != "squashfs" and .fstype != "iso9660")) |
            {source, target, fstype, mounted: true, expected: (($expected | index($target)) != null)}] |
        if any(.[]; .target == "/") then . else [{source: null, target: "/", fstype: null, mounted: true, expected: false}] + . end |
        . as $mounted |
        . + [$expected[] as $target | select(all($mounted[]; .target != $target)) |
            {source: null, target: $target, fstype: null, mounted: (if $inventory_ok then false else null end), expected: true}] |
        unique_by(.target) | sort_by(.target)
    ')"
    while IFS= read -r record; do
        target="$(printf '%s' "$record" | jq -r '.target')"
        mounted="$(printf '%s' "$record" | jq -r '.mounted')"
        total=null used=null available=null percent=null
        level=unknown
        if [ "$mounted" = true ]; then
            if usage="$(df -P -k "$target" 2>/dev/null)"; then
                read -r total used available percent <<EOF
$(printf '%s\n' "$usage" | awk '
    BEGIN { total = used = available = percent = "null" }
    NR == 2 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^-?[0-9]+$/ && $5 ~ /^[0-9]+%$/ {
        total = $2; used = $3; available = $4; percent = $5; sub(/%$/, "", percent)
    }
    END { print total, used, available, percent }
')
EOF
            fi
            if [ "$target" = / ]; then
                level="$(numeric_level "$percent" "$ROOT_WARN" "$ROOT_CRIT")"
            else
                level="$(numeric_level "$percent" "$DISK_WARN" "$DISK_CRIT")"
            fi
        elif [ "$mounted" = false ]; then
            level=crit
        fi
        record="$(printf '%s' "$record" | jq -c --arg level "$level" --argjson total "$total" --argjson used "$used" \
            --argjson available "$available" --argjson percent "$percent" '
            . + {level: $level, total_bytes: ($total | if . == null then null else . * 1024 end),
                used_bytes: ($used | if . == null then null else . * 1024 end),
                available_bytes: ($available | if . == null then null else . * 1024 end), use_percent: $percent}
        ')"
        rows="$rows$record"$'\n'
    done <<EOF
$(printf '%s' "$mounts" | jq -c '.[]')
EOF
    STORAGE_JSON="$(printf '%s' "$rows" | jq -s '.')"
    ROOT_USED="$(printf '%s' "$STORAGE_JSON" | jq -r '.[] | select(.target == "/") | .use_percent // empty')"
}

level_color() {
    case "$1" in
        ok) printf '%s' "$GREEN" ;;
        crit) printf '%s' "$RED" ;;
        *) printf '%s' "$YELLOW" ;;
    esac
}

render_storage() {
    local record target mounted level total used available percent color
    [ "$MOUNT_INVENTORY_LEVEL" = ok ] || kv Inventory unavailable
    while IFS= read -r record; do
        target="$(printf '%s' "$record" | jq -r '.target')"
        mounted="$(printf '%s' "$record" | jq -r '.mounted')"
        level="$(printf '%s' "$record" | jq -r '.level')"
        color="$(level_color "$level")"
        printf "%-${KV_WIDTH}s %b%s%b" "$target" "$color" "$level" "$NC"
        if [ "$mounted" = false ]; then
            printf '; MISSING expected mount\n'
        elif [ "$mounted" = null ]; then
            printf '; mount inventory unavailable\n'
        else
            read -r total used available percent <<EOF
$(printf '%s' "$record" | jq -r '[.total_bytes, .used_bytes, .available_bytes, .use_percent] | map(if . == null then "-" else . end) | @tsv')
EOF
            printf '; %s / %s used; %s free (%s)\n' \
                "$(bytes_text "$used")" "$(bytes_text "$total")" "$(bytes_text "$available")" "$(percent_text "$percent")"
        fi
    done <<EOF
$(printf '%s' "$STORAGE_JSON" | jq -c '.[]')
EOF
}

container_state() {
    local name="$1" status health details
    if [ "$DOCKER_ACCESS" != available ]; then
        printf '%s' "$DOCKER_ACCESS"
        return 0
    fi
    if ! details="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)"; then
        if docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
            printf 'not found'
        else
            printf 'docker unavailable'
        fi
        return 0
    fi
    read -r status health <<EOF
$details
EOF
    if [ "$status" = running ]; then
        case "$health" in
            unhealthy) printf 'running / UNHEALTHY' ;;
            healthy) printf 'running / healthy' ;;
            starting) printf 'running / starting' ;;
            none) printf 'running (no healthcheck)' ;;
            *) printf 'unknown health' ;;
        esac
    else
        printf '%s' "${status:-unknown state}"
    fi
}

DOCKER_ACCESS=available
if [ -z "$IMMICH_CONTAINERS" ]; then
    DOCKER_ACCESS='not configured'
elif ! command -v docker >/dev/null 2>&1; then
    DOCKER_ACCESS='docker not installed'
elif ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
    DOCKER_ACCESS='docker unavailable'
fi

container_level() {
    case "$1" in
        'running / healthy' | 'running (no healthcheck)') printf ok ;;
        'running / starting') printf warn ;;
        'docker not installed' | 'docker unavailable' | 'unknown health' | 'unknown state') printf unknown ;;
        *) printf crit ;;
    esac
}

collect_services() {
    local service state level rows=''
    for service in $SERVICES; do
        state="$(systemctl is-active "$service" 2>/dev/null || true)"
        case "$state" in
            active) level=ok ;;
            activating | reloading | deactivating) level=warn ;;
            inactive | failed) level=crit ;;
            *)
                state=unknown
                level=unknown
                ;;
        esac
        record_health "$level"
        rows="$rows$(jq -cn --arg name "$service" --arg state "$state" --arg level "$level" '{name: $name, state: $state, level: $level}')"$'\n'
    done
    SERVICES_JSON="$(printf '%s' "$rows" | jq -s '.')"
}

collect_containers() {
    local spec name label state level rows=''
    for spec in $IMMICH_CONTAINERS; do
        name="${spec%%=*}"
        label="${spec#*=}"
        state="$(container_state "$name")"
        level="$(container_level "$state")"
        record_health "$level"
        rows="$rows$(jq -cn --arg name "$name" --arg label "$label" --arg state "$state" --arg level "$level" '
            {name: $name, label: $label, state: $state, level: $level,
                runtime_status: (if $state | startswith("running") then "running"
                    elif $state == "not found" then "missing"
                    elif ["created", "restarting", "removing", "paused", "exited", "dead"] | index($state) then $state else null end),
                health_status: (if $state == "running / healthy" then "healthy"
                    elif $state == "running / UNHEALTHY" then "unhealthy"
                    elif $state == "running / starting" then "starting"
                    elif $state == "running (no healthcheck)" then "none" else null end)}
        ')"$'\n'
    done
    CONTAINERS_JSON="$(printf '%s' "$rows" | jq -s '.')"
}

collect_network() {
    local addresses
    NETWORK_JSON='[]'
    NETWORK_LEVEL=unknown
    if addresses="$(ip -j address show up 2>/dev/null)" && printf '%s' "$addresses" | jq -e '
        type == "array" and all(.[]; (.ifname | type == "string") and (.addr_info | type == "array"))
    ' >/dev/null 2>&1; then
        NETWORK_JSON="$(printf '%s' "$addresses" | jq -c '[.[] |
            select(.ifname | test("^(lo|docker.*|br-.*|veth.*)$") | not) |
            .ifname as $interface | .addr_info[] | select(.family == "inet" or .family == "inet6") |
            {interface: $interface, family, address: .local, prefix_length: .prefixlen}
        ]')"
        NETWORK_LEVEL=ok
        [ "$NETWORK_JSON" != '[]' ] || NETWORK_LEVEL=warn
    fi
    record_health "$NETWORK_LEVEL"
}

cached_summary() {
    local source="$1" title="$2" key="$3" max_age="$4"
    local dir="${XDG_STATE_HOME:-$HOME/.local/state}/$source" payload='' rows=''
    local level=unavailable message='no cached result' checked_at='' snapshot_boot='' _version age='' observed_level=''
    local label row_level text color now
    now="$(date +%s)"
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
            if [ "$checked_at" -gt "$now" ]; then
                level=unavailable
                message='cached timestamp is in the future'
            else
                age=$((now - checked_at))
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

    record_health "$level"
    if [ "$AS_JSON" -eq 1 ]; then
        CACHED_JSON="$(printf '%s' "$CACHED_JSON" | jq -c --arg source "$source" --arg title "$title" \
            --arg level "$level" --arg message "$message" --arg epoch "$checked_at" --arg age "$age" \
            --arg boot "$snapshot_boot" --arg observed "$observed_level" --arg rows "$rows" '
            . + [{source: $source, title: $title, status: $level, message: $message,
                sampled_at: (try ($epoch | tonumber) catch null), age_seconds: (try ($age | tonumber) catch null),
                boot_id: (if $boot == "" then null else $boot end),
                observed_status: (if $observed == "" then null else $observed end),
                findings: ($rows | split("\n") | map(select(length > 0) | split("\t") |
                    {label: .[0], level: .[1], summary: .[2]}))}]
        ')"
        return 0
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

emit_json() {
    jq -n --arg generated "$(date_iso)" --arg status "$HEALTH_STATUS" --argjson exit_code "$HEALTH_CODE" \
        --arg hostname "$SYSTEM_HOSTNAME" --arg uptime "$SYSTEM_UPTIME" --arg load "$SYSTEM_LOAD" \
        --arg temperature "$TEMP_C" --arg temperature_status "$TEMP_LEVEL" --arg cpu_usage "$CPU_USAGE" \
        --arg clock "$CPU_CLOCK" --arg process "$TOP_PROCESS" --arg memory_status "$RAM_LEVEL" \
        --arg ram_total "$RAM_TOTAL" --arg ram_used "$RAM_USED" --arg ram_available "$RAM_AVAILABLE" \
        --arg ram_usage "$RAM_USAGE" --arg swap_total "$SWAP_TOTAL" --arg swap_used "$SWAP_USED" \
        --arg power_status "$POWER_LEVEL" --arg register "$POWER_REGISTER" --arg current "$POWER_CURRENT" --arg history "$POWER_HISTORY" \
        --arg inventory_status "$MOUNT_INVENTORY_LEVEL" --argjson storage "$STORAGE_JSON" \
        --arg network_status "$NETWORK_LEVEL" --argjson network "$NETWORK_JSON" \
        --arg docker "$DOCKER_ACCESS" --argjson services "$SERVICES_JSON" --argjson containers "$CONTAINERS_JSON" --argjson cached "$CACHED_JSON" '
        def number: try tonumber catch null;
        def optional: if . == "" then null else . end;
        def flags: if $register == "" then null elif . == "none" then [] else split(", ") end;
        {
            schema_version: 1, generated_at: $generated, status: $status, health_exit_code: $exit_code,
            system: {hostname: $hostname, uptime: $uptime, load_average: (if $load == "" then null else $load | split(",") | map(number) end)},
            cpu: {temperature_c: ($temperature | number), temperature_status: $temperature_status,
                usage_percent: ($cpu_usage | number), clock_mhz: ($clock | number), top_process: ($process | optional)},
            memory: {status: $memory_status, total_bytes: ($ram_total | number), used_bytes: ($ram_used | number),
                available_bytes: ($ram_available | number), usage_percent: ($ram_usage | number),
                swap_total_bytes: ($swap_total | number), swap_used_bytes: ($swap_used | number)},
            power: {status: $power_status, register: ($register | optional), current_flags: ($current | flags), historical_flags: ($history | flags)},
            storage: {inventory_status: $inventory_status, filesystems: $storage},
            network: {status: $network_status, addresses: $network},
            docker_status: $docker, services: $services, containers: $containers, cached: $cached
        }
    '
}

SYSTEM_HOSTNAME="$(hostname 2>/dev/null || true)"
SYSTEM_UPTIME="$(uptime -p 2>/dev/null || true)"
SYSTEM_LOAD="$(awk '{ print $1", "$2", "$3 }' /proc/loadavg 2>/dev/null || true)"
TOP_PROCESS="$({ ps -eo comm,%cpu --sort=-%cpu 2>/dev/null || true; } | sed -n '2p')"
TEMP_C="$(cpu_temp)"
CPU_USAGE="$(cpu_usage)"
CPU_CLOCK="$(cpu_clock)"
collect_memory
collect_power
collect_storage
TEMP_LEVEL="$(numeric_level "$TEMP_C" "$TEMP_WARN" "$TEMP_CRIT")"
RAM_LEVEL="$(numeric_level "$RAM_USAGE" "$RAM_WARN" "$RAM_CRIT")"
record_health "$TEMP_LEVEL"
record_health "$RAM_LEVEL"
record_health "$POWER_LEVEL"
record_health "$MOUNT_INVENTORY_LEVEL"
[ -n "$CPU_USAGE" ] && [ -n "$CPU_CLOCK" ] || record_health unknown
while IFS= read -r DISK_LEVEL; do
    record_health "$DISK_LEVEL"
done <<EOF
$(printf '%s' "$STORAGE_JSON" | jq -r '.[].level')
EOF
collect_services
collect_containers
collect_network

if [ "$AS_JSON" -eq 1 ]; then
    cached_summaries
    emit_json
    finish_report
fi

# ------------------------------------------------------------
# ONELINE
# ------------------------------------------------------------

if [ "$ONELINE" -eq 1 ]; then
    line="${SYSTEM_HOSTNAME:-unknown} up ${SYSTEM_UPTIME#up }"
    line="$line | cpu ${TEMP_C:+${TEMP_C}C }$(percent_text "$CPU_USAGE")"
    line="$line | ram $(percent_text "$RAM_USAGE") | / $(percent_text "$ROOT_USED")"

    while IFS= read -r disk; do
        mp="$(printf '%s' "$disk" | jq -r '.target')"
        [ "$mp" != / ] || continue
        mounted="$(printf '%s' "$disk" | jq -r '.mounted')"
        if [ "$mounted" = false ]; then
            line="$line | $(basename "$mp") MISSING"
        else
            use="$(printf '%s' "$disk" | jq -r '.use_percent // empty')"
            line="$line | $(basename "$mp") $(percent_text "$use")"
        fi
    done <<EOF
$(printf '%s' "$STORAGE_JSON" | jq -c '.[]')
EOF

    down=0 unhealthy=0 starting=0 unknown=0
    while IFS= read -r state; do
        [ -n "$state" ] || continue
        case "$state" in
            'running / healthy' | 'running (no healthcheck)') ;;
            'running / UNHEALTHY') unhealthy=$((unhealthy + 1)) ;;
            'running / starting') starting=$((starting + 1)) ;;
            'docker not installed' | 'docker unavailable' | 'unknown health' | 'unknown state') unknown=$((unknown + 1)) ;;
            *) down=$((down + 1)) ;;
        esac
    done <<EOF
$(printf '%s' "$CONTAINERS_JSON" | jq -r '.[].state')
EOF
    if [ -z "$IMMICH_CONTAINERS" ]; then
        line="$line | immich not configured"
    elif [ "$((down + unhealthy + starting + unknown))" -eq 0 ]; then
        line="$line | immich ok"
    else
        line="$line | immich"
        [ "$down" -eq 0 ] || line="$line $down down"
        [ "$unhealthy" -eq 0 ] || line="$line $unhealthy unhealthy"
        [ "$starting" -eq 0 ] || line="$line $starting starting"
        if [ "$unknown" -gt 0 ]; then
            reason="$(printf '%s' "$CONTAINERS_JSON" | jq -r '[.[] | select(.level == "unknown")][0].state')"
            line="$line $unknown unknown ($reason)"
        fi
    fi

    printf '%s | power %s' "$line" "$POWER_LEVEL"
    cached_summaries
    printf '\n'
    finish_report
fi

# ------------------------------------------------------------
# REPORT
# ------------------------------------------------------------

print_status() {
    local label="$1" status="$2" color
    case "$status" in
        running | 'running / healthy' | 'running (no healthcheck)' | active | healthy | ok) color="$GREEN" ;;
        'running / starting' | 'docker unavailable' | 'docker not installed' | 'unknown health' | 'unknown state' | warning | degraded | warn | unknown | activating | reloading | deactivating) color="$YELLOW" ;;
        *) color="$RED" ;;
    esac
    printf "%-${KV_WIDTH}s %b%s%b\n" "$label" "$color" "$status" "$NC"
}

section "===== Raspberry Pi Health ====="

section "System"
kv "Hostname" "${SYSTEM_HOSTNAME:-unavailable}"
kv "Uptime" "${SYSTEM_UPTIME:-unavailable}"
kv "Load Average" "${SYSTEM_LOAD:-unavailable}"

section "CPU"
if [ -n "$TEMP_C" ]; then
    if awk -v t="$TEMP_C" -v c="$TEMP_CRIT" 'BEGIN { exit !(t >= c) }'; then
        TEMP_COLOR="$RED"
    elif awk -v t="$TEMP_C" -v w="$TEMP_WARN" 'BEGIN { exit !(t >= w) }'; then
        TEMP_COLOR="$YELLOW"
    else
        TEMP_COLOR="$GREEN"
    fi
    printf "%-${KV_WIDTH}s %b%s°C%b\n" "Temperature" "$TEMP_COLOR" "$TEMP_C" "$NC"
else
    kv Temperature unavailable
fi
kv "CPU Usage" "$(percent_text "$CPU_USAGE")"
CPU_CLOCK_TEXT="${CPU_CLOCK:+$CPU_CLOCK MHz}"
kv "CPU Clock" "${CPU_CLOCK_TEXT:-unavailable}"
kv "Top CPU Process" "${TOP_PROCESS:-unavailable}"

section "Power and throttling"
print_status Status "$POWER_LEVEL"
kv "Current flags" "$POWER_CURRENT"
kv "Since boot" "$POWER_HISTORY"
kv Register "${POWER_REGISTER:-unavailable}"

section "Memory"
kv "RAM Total" "$(bytes_text "$RAM_TOTAL")"
kv "RAM Used" "$(bytes_text "$RAM_USED")"
kv "RAM Available" "$(bytes_text "$RAM_AVAILABLE")"
printf "%-${KV_WIDTH}s %b%s%b (%s)\n" 'RAM Usage' "$(level_color "$RAM_LEVEL")" "$(percent_text "$RAM_USAGE")" "$NC" "$RAM_LEVEL"
kv "Swap Used" "$(bytes_text "$SWAP_USED") / $(bytes_text "$SWAP_TOTAL")"

section "Storage"
render_storage

section "Network"
print_status Status "$NETWORK_LEVEL"
while IFS="$TAB" read -r interface address prefix; do
    [ -n "$interface" ] || continue
    kv "$interface" "$address/$prefix"
done <<EOF
$(printf '%s' "$NETWORK_JSON" | jq -r '.[] | [.interface, .address, .prefix_length] | @tsv')
EOF

section "System Services"
while IFS="$TAB" read -r svc state; do
    [ -n "$svc" ] || continue
    print_status "$svc" "$state"
done <<EOF
$(printf '%s' "$SERVICES_JSON" | jq -r '.[] | [.name, .state] | @tsv')
EOF

section "Immich"
while IFS="$TAB" read -r label state; do
    [ -n "$label" ] || continue
    print_status "$label" "$state"
done <<EOF
$(printf '%s' "$CONTAINERS_JSON" | jq -r '.[] | [.label, .state] | @tsv')
EOF

cached_summaries

section 'Overall health'
print_status Status "$HEALTH_STATUS"
printf '\n'
finish_report
