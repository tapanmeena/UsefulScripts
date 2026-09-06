#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export XDG_STATE_HOME="$WORK_DIR/state" XDG_CONFIG_HOME="$WORK_DIR/config"
export NOTIFY_BACKEND=stdout PROBE_LOG="$WORK_DIR/probes"

uname() { printf 'Linux\n'; }
id() { printf '0\n'; }
dmesg() { printf '%s\n' "${KERNEL_MESSAGES:-}"; }
lsblk() { printf 'sda disk\n'; }
smartctl() {
    printf '%s\n' "$*" >>"$PROBE_LOG"
    if [ "$1" = --scan ]; then
        [ "${SCAN_MODE:-normal}" = empty ] || printf '/dev/test -d sat\n'
    elif [ "${SMART_MODE:-awake}" = sleeping ]; then
        printf '{"smartctl":{"messages":[{"string":"Device is in STANDBY mode"}]}}\n'
    elif [ "${SMART_MODE:-awake}" != missing ]; then
        jq -n --argjson pending "${PENDING_SECTORS:-0}" '{
            model_name: "Test Drive", serial_number: "TEST123",
            smart_status: {passed: true}, temperature: {current: 35}, power_on_time: {hours: 200},
            ata_smart_attributes: {table: [{id: 197, raw: {value: $pending}}]}
        }'
    fi
}
export -f uname id dmesg lsblk smartctl

bash "$REPO_DIR/hdd-sentinel.sh" --json >"$WORK_DIR/result.json"
jq -e '.disks[0].level == "ok"' "$WORK_DIR/result.json" >/dev/null
SNAPSHOT="$XDG_STATE_HOME/hdd-sentinel/status.tsv"
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = ok ]
grep -q 'SMART passed; 35C' "$SNAPSHOT"
grep -q -- '-n standby' "$PROBE_LOG"

export SCAN_MODE=empty
rm "$XDG_STATE_HOME/hdd-sentinel/devices.tsv"
bash "$REPO_DIR/hdd-sentinel.sh" --json >"$WORK_DIR/result.json"
jq -e '.disks[0].device == "/dev/sda" and .disks[0].level == "ok"' "$WORK_DIR/result.json" >/dev/null
grep -q -- '-d sat /dev/sda' "$PROBE_LOG"
unset SCAN_MODE

export PENDING_SECTORS=2 KERNEL_MESSAGES='I/O error, dev test'
EXIT_CODE=0
bash "$REPO_DIR/hdd-sentinel.sh" --json >"$WORK_DIR/result.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
jq -e '.disks[0].level == "crit" and .io_errors_new == 1' "$WORK_DIR/result.json" >/dev/null
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = crit ]
grep -q 'rose 0->2' "$SNAPSHOT"
grep -q '1 new I/O errors' "$SNAPSHOT"

export SMART_MODE=sleeping
bash "$REPO_DIR/hdd-sentinel.sh" --quiet >/dev/null
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = unknown ]
grep -q 'Sleeping; SMART not checked' "$SNAPSHOT"

export SMART_MODE=missing
EXIT_CODE=0
bash "$REPO_DIR/hdd-sentinel.sh" --json >"$WORK_DIR/result.json" 2>"$WORK_DIR/error" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = unknown ]
grep -q 'No disks reported SMART data' "$SNAPSHOT"

printf 'PASS: HDD snapshots, SMART deltas, kernel findings, sleeping and unreadable disks\n'
