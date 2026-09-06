#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export XDG_STATE_HOME="$WORK_DIR/state" XDG_CONFIG_HOME="$WORK_DIR/config"

uname() { printf 'Linux\n'; }
systemctl() { return 0; }
who() { return 0; }
vcgencmd() { printf 'throttled=0x0\n'; }
journalctl() {
    if [ "${BOOT_MODE:-clean}" = unknown ]; then
        return 0
    fi
    case " $* " in
        *' --list-boots '*) printf ' -1 previous-boot\n 0 current-boot\n' ;;
        *' -o short-iso '*) printf '2026-09-06T10:00:00+0000 test boot\n' ;;
        *' -b -1 '*'-n 60 '*)
            if [ "${BOOT_MODE:-clean}" = clean ]; then
                printf 'systemd-shutdown: Shutting down\n'
            else
                printf 'last recorded activity\n'
            fi
            ;;
        *' -b 0 '*'-k '*)
            if [ "${BOOT_MODE:-clean}" = power ]; then
                printf 'Under-voltage detected\nEXT4-fs (test): recovery complete\n'
            fi
            ;;
    esac
    return 0
}
export -f uname systemctl who vcgencmd journalctl

OUTPUT="$(bash "$REPO_DIR/boot-story.sh" --quiet)"
[ -z "$OUTPUT" ]
SNAPSHOT="$XDG_STATE_HOME/boot-story/status.tsv"
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = ok ]
grep -q 'CLEAN REBOOT.*(high confidence)' "$SNAPSHOT"

export BOOT_MODE=power
EXIT_CODE=0
bash "$REPO_DIR/boot-story.sh" --json >"$WORK_DIR/result.json" || EXIT_CODE=$?
[ "$EXIT_CODE" -eq 1 ]
jq -e '.verdict == "POWER LOSS" and .confidence == "high"' "$WORK_DIR/result.json" >/dev/null
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = crit ]
grep -q 'POWER LOSS (high confidence)' "$SNAPSHOT"
grep -q 'powered USB hub' "$SNAPSHOT"

export BOOT_MODE=unknown
bash "$REPO_DIR/boot-story.sh" --json >"$WORK_DIR/result.json"
jq -e '.verdict == "CLEAN OR UNKNOWN"' "$WORK_DIR/result.json" >/dev/null
[ "$(awk -F '\t' 'NR == 1 { print $3 }' "$SNAPSHOT")" = unknown ]

printf 'PASS: boot snapshots, clean shutdown without OOM, power loss, and missing journal\n'
