#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export XDG_STATE_HOME="$WORK_DIR/state" XDG_CONFIG_HOME="$WORK_DIR/config"
export PROBE_LOG="$WORK_DIR/probes" RUNWAY_MAX_AGE=60 HDD_MAX_AGE=60 WAN_MAX_AGE=60
mkdir -p "$XDG_CONFIG_HOME"

printf '/mnt/photos\twarn\t+2.4G/day; ~46 days left; short-history\n' | write_status_snapshot disk-runway warn
printf '/dev/test\tcrit\t3 new USB resets\n' | write_status_snapshot hdd-sentinel crit
printf 'Last 24h\tok\t100%% sampled reachability\n' | write_status_snapshot wan-watch ok
printf 'Cause\tunknown\tCLEAN OR UNKNOWN (low confidence)\n' | write_status_snapshot boot-story unknown
printf 'unchanged baseline\n' >"$XDG_STATE_HOME/hdd-sentinel/kernel.tsv"

uname() { printf 'Linux\n'; }
hostname() { printf '%s\n' "${TEST_HOSTNAME:-test-pi}"; }
uptime() { printf 'up 2 days\n'; }
vcgencmd() {
    [ "${METRICS_MODE:-available}" != missing ] || return 1
    case "$1" in
        measure_temp) printf "temp=%s'C\n" "${TEST_TEMP:-45.0}" ;;
        measure_clock) printf 'frequency(48)=1500000000\n' ;;
        get_throttled) printf 'throttled=%s\n' "${THROTTLED_REGISTER:-0x0}" ;;
    esac
}
top() {
    [ "$*" = '-bn2 -d 0.2' ] || return 1
    [ "${METRICS_MODE:-available}" != missing ] || return 1
    printf '%%Cpu(s): 50.0 us, 0.0 sy, 50.0 id, 0.0 wa\n'
    printf '%%Cpu(s): 10.0 us, 0.0 sy, 90.0 id, 0.0 wa\n'
}
free() {
    [ "$*" = '-b' ] || return 1
    [ -z "${MEMORY_LOG:-}" ] || printf 'sample\n' >>"$MEMORY_LOG"
    [ "${METRICS_MODE:-available}" != missing ] || return 1
    printf ' total used free shared buff/cache available\nMem: 1000 650 200 100 300 %s\nSwap: 100 0 100\n' "${TEST_AVAILABLE_RAM:-600}"
}
df() {
    local percent="${TEST_DISK_PERCENT:-10}"
    [ -z "${MOUNT_DF_LOG:-}" ] || printf '%s\n' "${!#}" >>"$MOUNT_DF_LOG"
    [ "${DF_MODE:-available}" != missing ] || return 1
    printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/root 1000 %s %s %s%% /\n' \
        "$((percent * 10))" "$((1000 - percent * 10))" "$percent"
}
findmnt() {
    case "${MOUNT_MODE:-root}" in
        missing) return 1 ;;
        external)
            printf '{"filesystems":[{"source":"/dev/root","target":"/","fstype":"ext4"},{"source":"/dev/nvme0n1","target":"/mnt/My Photos","fstype":"ext4"},{"source":"/dev/mapper/photos","target":"/mnt/archive","fstype":"ext4"}]}\n'
            ;;
        *) printf '{"filesystems":[{"source":"/dev/root","target":"/","fstype":"ext4"}]}\n' ;;
    esac
}
ip() {
    [ "$*" = '-j address show up' ] || return 1
    [ "${NETWORK_MODE:-available}" != missing ] || return 1
    printf '[{"ifname":"eth0","addr_info":[{"family":"inet","local":"192.0.2.1","prefixlen":24},{"family":"inet6","local":"fd00::2","prefixlen":64}]},{"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8}]},{"ifname":"docker0","addr_info":[{"family":"inet","local":"172.17.0.1","prefixlen":16}]}]\n'
}
ps() { printf 'COMMAND %%CPU\ntest 1.0\n'; }
systemctl() { printf '%s\n' "${SERVICE_STATE:-active}"; }
docker() {
    [ "${DOCKER_STATE:-available}" != unavailable ] || return 1
    [ "$1" != info ] || return 0
    [ "${DOCKER_STATE:-available}" != missing ] || return 1
    printf '%s %s\n' "${CONTAINER_STATE:-running}" "${CONTAINER_HEALTH:-healthy}"
}
awk() {
    if [ "${!#}" = /proc/loadavg ]; then
        printf '0.1, 0.2, 0.3\n'
    else
        command awk "$@"
    fi
}
unexpected_probe() {
    printf '%s\n' 'unexpected probe' >>"$PROBE_LOG"
    return 99
}
smartctl() { unexpected_probe; }
ping() { unexpected_probe; }
journalctl() { unexpected_probe; }
sudo() { unexpected_probe; }
disk-runway() { unexpected_probe; }
hdd-sentinel() { unexpected_probe; }
wan-watch() { unexpected_probe; }
boot-story() { unexpected_probe; }
export -f uname hostname uptime vcgencmd top free df findmnt ip ps systemctl docker awk
export -f unexpected_probe smartctl ping journalctl sudo disk-runway hdd-sentinel wan-watch boot-story

BEFORE="$(find "$XDG_STATE_HOME" -type f -exec cksum {} \; | sort)"
OUTPUT="$(bash "$REPO_DIR/rpistats.sh")"
printf '%s\n' "$OUTPUT" | grep -q 'Storage outlook'
printf '%s\n' "$OUTPUT" | grep -q '+2.4G/day; ~46 days left'
printf '%s\n' "$OUTPUT" | grep -q '3 new USB resets'
printf '%s\n' "$OUTPUT" | grep -q 'CLEAN OR UNKNOWN (low confidence)'
ONELINE="$(bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in
    'test-pi up 2 days | cpu 45.0C 10.0% | ram 40.0% | / 10% | immich ok | power ok | runway warn | hdd crit | wan ok | boot unknown') ;;
    *)
        printf 'FAIL: unexpected one-line output: %s\n' "$ONELINE" >&2
        exit 1
        ;;
esac
[ "$(printf '%s\n' "$ONELINE" | wc -l | tr -d ' ')" = 1 ]
[ "$(find "$XDG_STATE_HOME" -type f -exec cksum {} \; | sort)" = "$BEFORE" ]
[ ! -e "$PROBE_LOG" ]

NOW="$(date +%s)"
printf '/\tok\tOld forecast\n' | write_status_snapshot disk-runway ok "$((NOW - 3600))"
ONELINE="$(bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | runway stale | '*) ;; *) exit 1 ;; esac

printf '1\t%s\tok\tprevious-boot\nCause\tok\tCLEAN REBOOT\n' "$NOW" >"$XDG_STATE_HOME/boot-story/status.tsv"
ONELINE="$(bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | boot stale') ;; *) exit 1 ;; esac

printf '/\tok\tFuture forecast\n' | write_status_snapshot disk-runway ok "$((NOW + 3600))"
printf 'broken snapshot\n' >"$XDG_STATE_HOME/hdd-sentinel/status.tsv"
ONELINE="$(bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | runway unavailable | hdd unavailable | '*) ;; *) exit 1 ;; esac

rm -rf "$XDG_STATE_HOME/wan-watch"
ONELINE="$(bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | wan not configured | '*) ;; *) exit 1 ;; esac
touch "$XDG_CONFIG_HOME/wan-watch.conf"
ONELINE="$(bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | wan unavailable | '*) ;; *) exit 1 ;; esac

ONELINE="$(STATUS_SOURCES='' bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | immich ok | power ok') ;; *) exit 1 ;; esac
if RUNWAY_MAX_AGE=bad bash "$REPO_DIR/rpistats.sh" --oneline >"$WORK_DIR/output" 2>"$WORK_DIR/error"; then
    printf 'FAIL: invalid cache age was accepted\n' >&2
    exit 1
fi
[ ! -e "$PROBE_LOG" ]

OUTPUT="$(MEMORY_LOG="$WORK_DIR/memory-samples" bash "$REPO_DIR/rpistats.sh")"
[ "$(wc -l <"$WORK_DIR/memory-samples" | tr -d ' ')" -eq 1 ]
printf '%s\n' "$OUTPUT" | grep -q 'RAM Used *400'
printf '%s\n' "$OUTPUT" | grep -q 'CPU Clock *1500 MHz$'
OUTPUT="$(METRICS_MODE=missing bash "$REPO_DIR/rpistats.sh")"
printf '%s\n' "$OUTPUT" | grep -q 'CPU Usage *unavailable'
printf '%s\n' "$OUTPUT" | grep -q 'RAM Usage *unavailable'
ONELINE="$(METRICS_MODE=missing bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' unavailable | ram unavailable | '*) ;; *) exit 1 ;; esac

OUTPUT="$(THROTTLED_REGISTER=0x50000 bash "$REPO_DIR/rpistats.sh")"
printf '%s\n' "$OUTPUT" | grep -q 'Current flags *none$'
printf '%s\n' "$OUTPUT" | grep -q 'Since boot *undervoltage, throttled$'
ONELINE="$(THROTTLED_REGISTER=0x50000 bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | power warn | '*) ;; *) exit 1 ;; esac
ONELINE="$(THROTTLED_REGISTER=0x5 bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | power crit | '*) ;; *) exit 1 ;; esac
ONELINE="$(THROTTLED_REGISTER=invalid bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | power unknown | '*) ;; *) exit 1 ;; esac

ONELINE="$(MOUNT_MODE=external EXPECTED_MOUNTS=$'/mnt/My Photos\n/mnt/archive\n/mnt/backup' MOUNT_DF_LOG="$WORK_DIR/df-calls" bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | My Photos 10% | archive 10% | backup MISSING | '*) ;; *) exit 1 ;; esac
[ "$(wc -l <"$WORK_DIR/df-calls" | tr -d ' ')" -eq 3 ]
if grep -q '^/mnt/backup$' "$WORK_DIR/df-calls"; then
    printf 'FAIL: missing mounts must not use parent-filesystem df readings\n' >&2
    exit 1
fi
OUTPUT="$(MOUNT_MODE=missing EXPECTED_MOUNTS='/mnt/photos' bash "$REPO_DIR/rpistats.sh")"
printf '%s\n' "$OUTPUT" | grep -q '/mnt/photos *unknown; mount inventory unavailable'
ONELINE="$(DF_MODE=missing bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | / unavailable | '*) ;; *) exit 1 ;; esac

ONELINE="$(CONTAINER_HEALTH=unhealthy bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | immich 4 unhealthy | '*) ;; *) exit 1 ;; esac
ONELINE="$(CONTAINER_HEALTH=starting bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | immich 4 starting | '*) ;; *) exit 1 ;; esac
ONELINE="$(CONTAINER_HEALTH=none bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | immich ok | '*) ;; *) exit 1 ;; esac
ONELINE="$(DOCKER_STATE=missing bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | immich 4 down | '*) ;; *) exit 1 ;; esac
ONELINE="$(DOCKER_STATE=unavailable bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in *' | immich 4 unknown (docker unavailable) | '*) ;; *) exit 1 ;; esac
[ ! -e "$PROBE_LOG" ]

EXIT_CODE=0
STATUS_SOURCES='' bash "$REPO_DIR/rpistats.sh" --oneline --check >"$WORK_DIR/check-output" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 0 ]
EXIT_CODE=0
STATUS_SOURCES='' CONTAINER_HEALTH=starting bash "$REPO_DIR/rpistats.sh" --oneline --check >"$WORK_DIR/check-output" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 1 ]
EXIT_CODE=0
STATUS_SOURCES='' CONTAINER_HEALTH=unhealthy bash "$REPO_DIR/rpistats.sh" --oneline --check >"$WORK_DIR/check-output" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
EXIT_CODE=0
STATUS_SOURCES='' SERVICE_STATE=failed bash "$REPO_DIR/rpistats.sh" --oneline --check >"$WORK_DIR/check-output" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
EXIT_CODE=0
STATUS_SOURCES='' EXPECTED_MOUNTS=/mnt/missing bash "$REPO_DIR/rpistats.sh" --oneline --check >"$WORK_DIR/check-output" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
EXIT_CODE=0
STATUS_SOURCES='' DOCKER_STATE=unavailable bash "$REPO_DIR/rpistats.sh" --oneline --check >"$WORK_DIR/check-output" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 1 ]

STATUS_SOURCES='' bash "$REPO_DIR/rpistats.sh" --json --check >"$WORK_DIR/report.json"
jq -e '
    .schema_version == 1 and .status == "ok" and .health_exit_code == 0 and
    .cpu.usage_percent == 10 and .cpu.clock_mhz == 1500 and
    .memory.total_bytes == 1000 and .memory.used_bytes == 400 and .memory.usage_percent == 40 and
    .power.current_flags == [] and .power.historical_flags == [] and
    .storage.filesystems[0].use_percent == 10 and .network.addresses[0].address == "192.0.2.1" and
    (.network.addresses | length) == 2 and .network.addresses[1].family == "inet6" and
    (.services | length) == 2 and (.containers | length) == 4 and
    .containers[0].runtime_status == "running" and .containers[0].health_status == "healthy"
' "$WORK_DIR/report.json" >/dev/null

TEST_HOSTNAME='Pi "photos" \ archive' bash "$REPO_DIR/rpistats.sh" --json >"$WORK_DIR/report.json"
jq -e '.system.hostname == "Pi \"photos\" \\ archive" and (.cached | length) == 4 and .cached[0].status == "unavailable"' "$WORK_DIR/report.json" >/dev/null

STATUS_SOURCES='' METRICS_MODE=missing NETWORK_MODE=missing bash "$REPO_DIR/rpistats.sh" --json >"$WORK_DIR/report.json"
jq -e '.status == "unknown" and .cpu.usage_percent == null and .memory.total_bytes == null and .network.status == "unknown"' "$WORK_DIR/report.json" >/dev/null

EXIT_CODE=0
STATUS_SOURCES='' MOUNT_MODE=external EXPECTED_MOUNTS=$'/mnt/My Photos\n/mnt/missing' THROTTLED_REGISTER=0x50000 CONTAINER_HEALTH=unhealthy \
    bash "$REPO_DIR/rpistats.sh" --json --check >"$WORK_DIR/report.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
jq -e '
    .status == "crit" and .health_exit_code == 2 and
    .power.current_flags == [] and .power.historical_flags == ["undervoltage", "throttled"] and
    .containers[0].health_status == "unhealthy" and
    any(.storage.filesystems[]; .target == "/mnt/My Photos" and .mounted == true) and
    any(.storage.filesystems[]; .target == "/mnt/missing" and .mounted == false and .use_percent == null)
' "$WORK_DIR/report.json" >/dev/null

STATUS_SOURCES='' IMMICH_CONTAINERS='' SERVICES='' bash "$REPO_DIR/rpistats.sh" --json --check >"$WORK_DIR/report.json"
jq -e '.containers == [] and .services == [] and .docker_status == "not configured"' "$WORK_DIR/report.json" >/dev/null

if bash "$REPO_DIR/rpistats.sh" --json --oneline >"$WORK_DIR/output" 2>"$WORK_DIR/error"; then
    printf 'FAIL: incompatible output modes were accepted\n' >&2
    exit 1
fi
[ ! -e "$PROBE_LOG" ]

EXIT_CODE=0
STATUS_SOURCES='' TEST_TEMP=60 bash "$REPO_DIR/rpistats.sh" --json --check >"$WORK_DIR/report.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 1 ]
jq -e '.cpu.temperature_status == "warn"' "$WORK_DIR/report.json" >/dev/null
EXIT_CODE=0
STATUS_SOURCES='' TEST_TEMP=70 bash "$REPO_DIR/rpistats.sh" --json --check >"$WORK_DIR/report.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
jq -e '.cpu.temperature_status == "crit"' "$WORK_DIR/report.json" >/dev/null
EXIT_CODE=0
STATUS_SOURCES='' TEST_AVAILABLE_RAM=150 bash "$REPO_DIR/rpistats.sh" --json --check >"$WORK_DIR/report.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 1 ]
jq -e '.memory.usage_percent == 85 and .memory.status == "warn"' "$WORK_DIR/report.json" >/dev/null
EXIT_CODE=0
STATUS_SOURCES='' TEST_DISK_PERCENT=95 bash "$REPO_DIR/rpistats.sh" --json --check >"$WORK_DIR/report.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
jq -e '.storage.filesystems[0].level == "crit"' "$WORK_DIR/report.json" >/dev/null

printf 'Drive\tcrit\tNew pending sectors\n' | write_status_snapshot hdd-sentinel crit
BEFORE="$(find "$XDG_STATE_HOME" -type f -exec cksum {} \; | sort)"
EXIT_CODE=0
STATUS_SOURCES=hdd-sentinel bash "$REPO_DIR/rpistats.sh" --json --check >"$WORK_DIR/report.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
jq -e '.cached[0].status == "crit" and .cached[0].observed_status == "crit" and .cached[0].age_seconds >= 0 and .cached[0].findings[0].summary == "New pending sectors"' "$WORK_DIR/report.json" >/dev/null
[ "$(find "$XDG_STATE_HOME" -type f -exec cksum {} \; | sort)" = "$BEFORE" ]

if TEMP_WARN=80 TEMP_CRIT=70 bash "$REPO_DIR/rpistats.sh" --oneline >"$WORK_DIR/output" 2>"$WORK_DIR/error"; then
    printf 'FAIL: reversed thresholds were accepted\n' >&2
    exit 1
fi
bash "$REPO_DIR/rpistats.sh" --help >"$WORK_DIR/help"
grep -q -- '--json' "$WORK_DIR/help"
grep -q -- '--check' "$WORK_DIR/help"

printf 'PASS: rpistats cached summaries, freshness, validation, opt-out, and read-only behavior\n'
