#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export XDG_STATE_HOME="$WORK_DIR/state" XDG_CONFIG_HOME="$WORK_DIR/config"
export NOTIFY_BACKEND=stdout FAIL_STREAK=1 OK_STREAK=1 PROBE_LOG="$WORK_DIR/probes"

uname() { printf 'Linux\n'; }
date() {
    case "$1" in
        +%s%N) printf '%s000000000\n' "$(command date +%s)" ;;
        -d)
            shift 2
            command date "$@"
            ;;
        *) command date "$@" ;;
    esac
}
ip() { printf 'default via 192.0.2.1 dev eth0\n'; }
curl() { printf '203.0.113.5\n'; }
getent() { [ "${WAN_STATE:-up}" = up ]; }
ping() {
    local target="${!#}"
    printf '%s\n' "$*" >>"$PROBE_LOG"
    case " $* " in
        *' -t '*) printf 'From 192.0.2.254 icmp_seq=1 Time to live exceeded\n' ;;
        *)
            if [ "${WAN_STATE:-up}" = down ] && { [ "$target" = 1.1.1.1 ] || [ "$target" = 8.8.8.8 ]; }; then
                printf '10 packets transmitted, 0 received, 100%% packet loss, time 1ms\n'
                return 1
            fi
            printf '10 packets transmitted, 10 received, 0%% packet loss, time 1ms\n'
            printf 'rtt min/avg/max/mdev = 10/18/30/1 ms\n'
            ;;
    esac
}
export -f uname date ip curl getent ping

bash "$REPO_DIR/wan-watch.sh" --probe --json >"$WORK_DIR/result.json"
jq -e '.up == 1' "$WORK_DIR/result.json" >/dev/null
SNAPSHOT="$XDG_STATE_HOME/wan-watch/status.tsv"
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = ok ]
grep -q '100.00% sampled reachability (1 samples); avg 18.0 ms' "$SNAPSHOT"
[ "$(wc -l <"$PROBE_LOG" | tr -d ' ')" = 5 ]

NOW="$(command date +%s)"
printf '%s\t%s\t900\n' "$((NOW - 1800))" "$((NOW - 900))" >"$XDG_STATE_HOME/wan-watch/outages.tsv"
export WAN_STATE=down
EXIT_CODE=0
bash "$REPO_DIR/wan-watch.sh" --probe --json >"$WORK_DIR/result.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 1 ]
jq -e '.up == 0' "$WORK_DIR/result.json" >/dev/null
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = warn ]
grep -q 'DOWN; gateway 18 ms; internet unreachable;' "$SNAPSHOT"
grep -q 'Resolution failed' "$SNAPSHOT"
grep -q '50.00% sampled reachability (2 samples)' "$SNAPSHOT"
grep -q '1 completed in 24h; longest 15m' "$SNAPSHOT"
grep -q 'awaiting recovery confirmation' "$SNAPSHOT"
[ "$(wc -l <"$PROBE_LOG" | tr -d ' ')" = 9 ]

BEFORE="$(cksum <"$SNAPSHOT")"
bash "$REPO_DIR/wan-watch.sh" --report --days 1 --json >"$WORK_DIR/result.json"
jq -e '.samples == 2 and .uptime_pct == 50 and .avg_rtt_ms == 18 and .avg_loss_pct == 50' "$WORK_DIR/result.json" >/dev/null
[ "$(cksum <"$SNAPSHOT")" = "$BEFORE" ]

printf 'PASS: WAN snapshots, DNS failures, outage summaries, and probe-free reports\n'
