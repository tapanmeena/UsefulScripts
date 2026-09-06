#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export XDG_STATE_HOME="$WORK_DIR/state"

printf 'Drive\twarn\t3 new USB resets\n' | write_status_snapshot hdd-sentinel warn
SNAPSHOT="$XDG_STATE_HOME/hdd-sentinel/status.tsv"
awk -F '\t' '
    NR == 1 { if (NF != 4 || $1 != 1 || $2 !~ /^[0-9]+$/ || $3 != "warn" || $4 == "") exit 1 }
    NR == 2 { if ($1 != "Drive" || $2 != "warn" || $3 != "3 new USB resets") exit 1 }
    END { if (NR != 2) exit 1 }
' "$SNAPSHOT"
[ "$(stat_mode "$SNAPSHOT")" = 600 ]

printf 'Drive\tok\tNo new findings\n' | write_status_snapshot hdd-sentinel ok
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = ok ]
[ "$(awk -F '\t' 'NR == 2 { print $3 }' "$SNAPSHOT")" = 'No new findings' ]
[ "$(find "$XDG_STATE_HOME" -name '.status.*' | wc -l | tr -d ' ')" = 0 ]

BEFORE="$(cksum <"$SNAPSHOT")"
cat() { return 1; }
if write_status_snapshot hdd-sentinel crit </dev/null; then
    printf 'FAIL: unsuccessful writes must be reported\n' >&2
    exit 1
fi
unset -f cat
[ "$(cksum <"$SNAPSHOT")" = "$BEFORE" ]
[ "$(find "$XDG_STATE_HOME" -name '.status.*' | wc -l | tr -d ' ')" = 0 ]

printf 'PASS: atomic status snapshots, permissions, and failed-write preservation\n'
