#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export XDG_STATE_HOME="$WORK_DIR/state" XDG_CONFIG_HOME="$WORK_DIR/config"
export MOUNTS='/' NOTIFY_BACKEND=stdout

df() {
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf '/dev/test 1000000 999000 1000 99%% /\n'
}
export -f df

OUTPUT="$(bash "$REPO_DIR/disk-runway.sh" --sample --quiet)"
[ -z "$OUTPUT" ]
SNAPSHOT="$XDG_STATE_HOME/disk-runway/status.tsv"
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = unknown ]

NOW="$(date +%s)"
printf '%s\t/\t998800\t1000000\n%s\t/\t998900\t1000000\n' \
    "$((NOW - 172800))" "$((NOW - 86400))" >"$XDG_STATE_HOME/disk-runway/samples.tsv"
OUTPUT="$(bash "$REPO_DIR/disk-runway.sh" --sample --quiet)"
[ -z "$OUTPUT" ]
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = crit ]
grep -q '~10 days left; short-history' "$SNAPSHOT"
[ "$(awk -F '\t' 'NR == 1 { print $2 }' "$SNAPSHOT")" -ge "$NOW" ]

EXIT_CODE=0
bash "$REPO_DIR/disk-runway.sh" --report --quiet >/dev/null || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 2 ]

printf '%s\t/\t998800\t1000000\n%s\t/\t998900\t1000000\n%s\t/\t999000\t1000000\n' \
    "$((NOW - 345600))" "$((NOW - 259200))" "$((NOW - 172800))" >"$XDG_STATE_HOME/disk-runway/samples.tsv"
bash "$REPO_DIR/disk-runway.sh" --report --quiet >/dev/null || [ "$?" -eq 2 ]
[ "$(awk -F '\t' 'NR == 1 { print $2 }' "$SNAPSHOT")" -eq "$((NOW - 172800))" ]

printf 'PASS: runway snapshots, unknown history, silent sampling, and sample age\n'
