#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
trap 'rm -rf "$WORK_DIR"' EXIT
export HOME="$WORK_DIR/home"
export XDG_CONFIG_HOME="$WORK_DIR/config %" XDG_STATE_HOME="$WORK_DIR/state"
export SYSTEMCTL_LOG="$WORK_DIR/systemctl.log"
export VERIFY_LOG="$WORK_DIR/verify.log" XDG_RUNTIME_DIR="$WORK_DIR/runtime"
REAL_SYSTEMD_ANALYZE="$(type -P systemd-analyze || true)"
export REAL_SYSTEMD_ANALYZE
mkdir -m 700 "$XDG_RUNTIME_DIR"
SCHEDULER="$REPO_DIR/immich-to-pixel-schedule.sh"
UNIT_DIR="$XDG_CONFIG_HOME/systemd/user"

uname() { printf 'Linux\n'; }
id() {
    case "$1" in
        -u) printf '1000\n' ;;
        -un) printf 'pi\n' ;;
        *) command id "$@" ;;
    esac
}
systemctl() { printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"; }
systemd-analyze() {
    case "$1" in
        calendar)
            [ "$2" = -- ] || return 1
            case "$3" in
                hourly | '*-*-* 03:00:00' | '*-*-* 00/6:00:00') return 0 ;;
                *) return 1 ;;
            esac
            ;;
        --user)
            [ "$2" = verify ] && [ -f "$3" ] && [ -f "$4" ] || return 1
            printf '%s\n' "$3" "$4" >"$VERIFY_LOG"
            [ "${FAIL_UNIT_VERIFY:-0}" -eq 0 ] || return 1
            if [ -n "$REAL_SYSTEMD_ANALYZE" ]; then
                "$REAL_SYSTEMD_ANALYZE" "$@"
            fi
            ;;
        *) return 1 ;;
    esac
}
loginctl() { printf '%s\n' "${LINGER_ENABLED:-yes}"; }
adb() { return 0; }
export -f uname id systemctl systemd-analyze loginctl adb

bash "$SCHEDULER" --dry-run >"$WORK_DIR/preview"
grep -q '^OnCalendar=hourly$' "$WORK_DIR/preview"
grep -Fq -- '--batch 1000 --scan-volume --debug' "$WORK_DIR/preview"
[ ! -e "$XDG_CONFIG_HOME" ]
[ ! -e "$XDG_STATE_HOME" ]
[ ! -e "$SYSTEMCTL_LOG" ]

if bash "$SCHEDULER" >"$WORK_DIR/missing-config" 2>&1; then
    printf 'FAIL: installation accepted without a config\n' >&2
    exit 1
fi
[ ! -e "$XDG_CONFIG_HOME" ]
[ ! -e "$SYSTEMCTL_LOG" ]

mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME/immich-to-pixel"
printf 'IMMICH_URL="http://localhost:2283"\n' >"$XDG_CONFIG_HOME/immich-to-pixel.conf"
chmod 600 "$XDG_CONFIG_HOME/immich-to-pixel.conf"
printf 'saved cursor\n' >"$XDG_STATE_HOME/immich-to-pixel/cursor"

for INVALID_CALENDAR in invalid --help; do
    if bash "$SCHEDULER" --schedule "$INVALID_CALENDAR" >"$WORK_DIR/invalid" 2>&1; then
        printf 'FAIL: invalid calendar accepted\n' >&2
        exit 1
    fi
done
[ ! -e "$UNIT_DIR" ]
[ ! -e "$SYSTEMCTL_LOG" ]

if FAIL_UNIT_VERIFY=1 bash "$SCHEDULER" >"$WORK_DIR/rejected-units" 2>&1; then
    printf 'FAIL: installation continued after unit verification failed\n' >&2
    exit 1
fi
[ ! -e "$UNIT_DIR" ]
[ ! -e "$SYSTEMCTL_LOG" ]
while IFS= read -r STAGED_UNIT; do
    [ ! -e "$(dirname "$STAGED_UNIT")" ]
done <"$VERIFY_LOG"

bash "$SCHEDULER" --schedule '*-*-* 03:00:00' >"$WORK_DIR/install"
grep -q '^OnCalendar=\*-\*-\* 03:00:00$' "$UNIT_DIR/immich-to-pixel.timer"
grep -q '^Persistent=true$' "$UNIT_DIR/immich-to-pixel.timer"
grep -Fqx "WorkingDirectory=$REPO_DIR" "$UNIT_DIR/immich-to-pixel.service"
grep -Fqx "ExecStart=/bin/bash \"$REPO_DIR/immich-to-pixel.sh\" --batch 1000 --scan-volume --debug" "$UNIT_DIR/immich-to-pixel.service"
grep -Fqx "Environment=\"XDG_CONFIG_HOME=$WORK_DIR/config %%\"" "$UNIT_DIR/immich-to-pixel.service"
grep -q '^TimeoutStartSec=0$' "$UNIT_DIR/immich-to-pixel.service"
grep -q '^SuccessExitStatus=75$' "$UNIT_DIR/immich-to-pixel.service"
grep -qx -- '--user enable immich-to-pixel.timer' "$SYSTEMCTL_LOG"
grep -qx -- '--user restart immich-to-pixel.timer' "$SYSTEMCTL_LOG"
[ "$(wc -l <"$SYSTEMCTL_LOG" | tr -d ' ')" -eq 3 ]

if [ -n "$REAL_SYSTEMD_ANALYZE" ]; then
    mkdir "$WORK_DIR/bad-unit"
    sed 's|^WorkingDirectory=.*|WorkingDirectory="/tmp"|' \
        "$UNIT_DIR/immich-to-pixel.service" >"$WORK_DIR/bad-unit/immich-to-pixel.service"
    if "$REAL_SYSTEMD_ANALYZE" --user verify "$WORK_DIR/bad-unit/immich-to-pixel.service" >"$WORK_DIR/bad-unit.log" 2>&1; then
        printf 'FAIL: systemd accepted the original quoted WorkingDirectory\n' >&2
        exit 1
    fi
    grep -q 'WorkingDirectory=' "$WORK_DIR/bad-unit.log"
fi

LINGER_ENABLED=no bash "$SCHEDULER" --schedule '*-*-* 00/6:00:00' >"$WORK_DIR/update" 2>&1
grep -Fqx 'OnCalendar=*-*-* 00/6:00:00' "$UNIT_DIR/immich-to-pixel.timer"
grep -Fq 'sudo loginctl enable-linger pi' "$WORK_DIR/update"
[ "$(wc -l <"$SYSTEMCTL_LOG" | tr -d ' ')" -eq 6 ]

SERVICE_BEFORE="$(cksum <"$UNIT_DIR/immich-to-pixel.service")"
TIMER_BEFORE="$(cksum <"$UNIT_DIR/immich-to-pixel.timer")"
if FAIL_UNIT_VERIFY=1 bash "$SCHEDULER" >"$WORK_DIR/rejected-update" 2>&1; then
    printf 'FAIL: schedule update continued after unit verification failed\n' >&2
    exit 1
fi
[ "$(cksum <"$UNIT_DIR/immich-to-pixel.service")" = "$SERVICE_BEFORE" ]
[ "$(cksum <"$UNIT_DIR/immich-to-pixel.timer")" = "$TIMER_BEFORE" ]
[ "$(wc -l <"$SYSTEMCTL_LOG" | tr -d ' ')" -eq 6 ]

if bash "$SCHEDULER" --schedule $'hourly\nUnit=other.service' >"$WORK_DIR/injection" 2>&1; then
    printf 'FAIL: multiline calendar accepted\n' >&2
    exit 1
fi
[ "$(wc -l <"$SYSTEMCTL_LOG" | tr -d ' ')" -eq 6 ]

bash "$SCHEDULER" --status >"$WORK_DIR/status"
grep -qx -- '--user list-timers --all immich-to-pixel.timer --no-pager' "$SYSTEMCTL_LOG"
grep -qx -- '--user status immich-to-pixel.service --no-pager --full' "$SYSTEMCTL_LOG"

bash "$SCHEDULER" --uninstall --dry-run >"$WORK_DIR/uninstall-preview"
[ -f "$UNIT_DIR/immich-to-pixel.timer" ]
[ "$(wc -l <"$SYSTEMCTL_LOG" | tr -d ' ')" -eq 8 ]

bash "$SCHEDULER" --uninstall >"$WORK_DIR/uninstall"
[ ! -e "$UNIT_DIR/immich-to-pixel.timer" ]
[ ! -e "$UNIT_DIR/immich-to-pixel.service" ]
[ -f "$XDG_CONFIG_HOME/immich-to-pixel.conf" ]
[ "$(cat "$XDG_STATE_HOME/immich-to-pixel/cursor")" = 'saved cursor' ]
grep -qx -- '--user disable --now immich-to-pixel.timer' "$SYSTEMCTL_LOG"

FIXTURE_REPO="$WORK_DIR/repo \$NAME % \"quoted\""
mkdir -p "$FIXTURE_REPO/lib"
cp "$SCHEDULER" "$FIXTURE_REPO/immich-to-pixel-schedule.sh"
cp "$REPO_DIR/lib/common.sh" "$FIXTURE_REPO/lib/common.sh"
touch "$FIXTURE_REPO/immich-to-pixel.sh"
bash "$FIXTURE_REPO/immich-to-pixel-schedule.sh" --dry-run >"$WORK_DIR/quoted-preview"
grep -Fqx "WorkingDirectory=$WORK_DIR/repo \$NAME %% \"quoted\"" "$WORK_DIR/quoted-preview"
grep -Fqx "ExecStart=/bin/bash \"$WORK_DIR/repo \$\$NAME %% \\\"quoted\\\"/immich-to-pixel.sh\" --batch 1000 --scan-volume --debug" "$WORK_DIR/quoted-preview"

bash "$FIXTURE_REPO/immich-to-pixel-schedule.sh" >"$WORK_DIR/quoted-install"
if [ -n "$REAL_SYSTEMD_ANALYZE" ]; then
    printf 'PASS: generated units accepted by systemd; original quoted path rejected\n'
fi

printf 'PASS: Immich scheduling, unit validation, dry-run, updates, and uninstall\n'
