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
hostname() { printf 'test-pi\n'; }
uptime() { printf 'up 2 days\n'; }
vcgencmd() {
    case "$1" in
        measure_temp) printf "temp=45.0'C\n" ;;
        measure_clock) printf 'frequency(48)=1500000000\n' ;;
    esac
}
top() { printf '%%Cpu(s): 10.0 us, 0.0 sy, 90.0 id, 0.0 wa\n'; }
free() { printf ' total used free shared buff/cache available\nMem: 1000 400 200 100 300 600\nSwap: 100 0 100\n'; }
df() { printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/root 1000 100 900 10%% /\n'; }
lsblk() { return 0; }
ip() { printf '2: eth0 inet 192.0.2.1/24\n'; }
ps() { printf 'COMMAND %%CPU\ntest 1.0\n'; }
systemctl() { printf 'active\n'; }
docker() {
    case "$3" in
        '{{.State.Status}}') printf 'running\n' ;;
        *) printf 'healthy\n' ;;
    esac
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
export -f uname hostname uptime vcgencmd top free df lsblk ip ps systemctl docker awk
export -f unexpected_probe smartctl ping journalctl sudo disk-runway hdd-sentinel wan-watch boot-story

BEFORE="$(find "$XDG_STATE_HOME" -type f -exec cksum {} \; | sort)"
OUTPUT="$(bash "$REPO_DIR/rpistats.sh")"
printf '%s\n' "$OUTPUT" | grep -q 'Storage outlook'
printf '%s\n' "$OUTPUT" | grep -q '+2.4G/day; ~46 days left'
printf '%s\n' "$OUTPUT" | grep -q '3 new USB resets'
printf '%s\n' "$OUTPUT" | grep -q 'CLEAN OR UNKNOWN (low confidence)'
ONELINE="$(bash "$REPO_DIR/rpistats.sh" --oneline)"
case "$ONELINE" in
    'test-pi up 2 days | cpu '*'% | ram 40.0% | / 10% | immich ok | runway warn | hdd crit | wan ok | boot unknown') ;;
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
case "$ONELINE" in *' | immich ok') ;; *) exit 1 ;; esac
if RUNWAY_MAX_AGE=bad bash "$REPO_DIR/rpistats.sh" --oneline >"$WORK_DIR/output" 2>"$WORK_DIR/error"; then
    printf 'FAIL: invalid cache age was accepted\n' >&2
    exit 1
fi
[ ! -e "$PROBE_LOG" ]

printf 'PASS: rpistats cached summaries, freshness, validation, opt-out, and read-only behavior\n'
