#!/usr/bin/env bash
#
# ============================================================
# Schedule Immich -> Pixel transfers on a Raspberry Pi
# ============================================================
#
# Runs on: Pi (bash 5)
# Requires: systemctl systemd-analyze
#
# Installs an opt-in systemd user timer for:
#   immich-to-pixel.sh --batch 1000 --scan-volume --debug
# Uses the existing immich-to-pixel config and state; never runs as root.
#
# Usage: immich-to-pixel-schedule.sh [--schedule CALENDAR] [--dry-run]
#        immich-to-pixel-schedule.sh --status | --uninstall

set -euo pipefail

_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

usage() {
    cat <<'EOF'
Schedule: immich-to-pixel.sh --batch 1000 --scan-volume --debug

Usage: immich-to-pixel-schedule.sh [options]

  --schedule CALENDAR  systemd calendar expression (default: hourly).
                       Daily at 03:00: --schedule '*-*-* 03:00:00'
                       Every 6 hours: --schedule '*-*-* 00/6:00:00'
  --dry-run            Preview units and commands; change nothing.
  --status             Show the timer and last transfer status.
  --uninstall          Remove the schedule; keep config and transfer state.
  -h, --help           Show this help.

Run as your normal Pi user, not with sudo. The existing config is read from
${XDG_CONFIG_HOME:-$HOME/.config}/immich-to-pixel.conf (mode 600).
Schedules use the Pi's local timezone unless the calendar specifies another.
A missed run is caught up when the timer next starts. Runs never overlap.
--batch 1000 is the batch size, not a limit on the total assets transferred.

After installation, enable startup without login (one-time setup):
  sudo loginctl enable-linger "$USER"

Logs: journalctl --user -u immich-to-pixel.service -f
Without a per-user journal:
    sudo journalctl _SYSTEMD_USER_UNIT=immich-to-pixel.service _UID="$(id -u)" -f
EOF
}

SCHEDULE=hourly
MODE=install
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --schedule)
            SCHEDULE="${2:?--schedule needs a value}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --status)
            MODE=status
            shift
            ;;
        --uninstall)
            MODE=uninstall
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
UNIT_DIR="$CONFIG_HOME/systemd/user"
SYNC_SCRIPT="$REPO_DIR/immich-to-pixel.sh"

unit_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '"%s"' "$value"
}

service_unit() {
    cat <<EOF
[Unit]
Description=Immich to Pixel scheduled transfer

[Service]
Type=oneshot
WorkingDirectory=${REPO_DIR//%/%%}
Environment=$(unit_quote "PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin")
Environment=$(unit_quote "XDG_CONFIG_HOME=$CONFIG_HOME")
Environment=$(unit_quote "XDG_STATE_HOME=$STATE_HOME")
ExecStart=/bin/bash $(unit_quote "${SYNC_SCRIPT//\$/\$\$}") --batch 1000 --scan-volume --debug
TimeoutStartSec=0
SuccessExitStatus=75
UMask=0077
StandardOutput=journal
StandardError=journal
EOF
}

timer_unit() {
    cat <<EOF
[Unit]
Description=Scheduled Immich to Pixel transfers

[Timer]
OnCalendar=$SCHEDULE
Persistent=true
Unit=immich-to-pixel.service

[Install]
WantedBy=timers.target
EOF
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

cleanup_units() {
    rm -rf "$UNIT_WORK_DIR"
}

if [ "$DRY_RUN" -eq 0 ]; then
    is_linux || die "scheduling requires Linux with systemd; use --dry-run to preview"
    [ "$(id -u)" -ne 0 ] || die "run as the Pi user who configured adb and Immich, not root"
    require_tools systemctl
fi

case "$MODE" in
    status)
        run systemctl --user list-timers --all immich-to-pixel.timer --no-pager
        run systemctl --user status immich-to-pixel.service --no-pager --full
        exit 0
        ;;
    uninstall)
        run systemctl --user disable --now immich-to-pixel.timer
        run rm -f "$UNIT_DIR/immich-to-pixel.timer" "$UNIT_DIR/immich-to-pixel.service"
        run systemctl --user daemon-reload
        info "schedule removed; config, state, and any running transfer are left alone"
        exit 0
        ;;
esac

case "$SCHEDULE" in
    '' | *$'\n'* | *$'\r'* | *%*) die "--schedule must be a non-empty calendar expression without newlines or %" ;;
esac
[ -f "$SYNC_SCRIPT" ] || die "missing transfer script: $SYNC_SCRIPT"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n%s\n' "$UNIT_DIR/immich-to-pixel.service"
    service_unit
    printf '\n%s\n' "$UNIT_DIR/immich-to-pixel.timer"
    timer_unit
else
    require_tools systemd-analyze curl jq adb
    systemd-analyze calendar -- "$SCHEDULE" >/dev/null || die "invalid calendar: $SCHEDULE"
    [ -f "$CONFIG_HOME/immich-to-pixel.conf" ] || die "create $CONFIG_HOME/immich-to-pixel.conf (mode 600) before scheduling"
    umask 077
    UNIT_WORK_DIR="$(mktemp -d)"
    on_exit cleanup_units
    service_unit >"$UNIT_WORK_DIR/immich-to-pixel.service"
    timer_unit >"$UNIT_WORK_DIR/immich-to-pixel.timer"
    systemd-analyze --user verify "$UNIT_WORK_DIR/immich-to-pixel.service" \
        "$UNIT_WORK_DIR/immich-to-pixel.timer" || die "generated units failed validation; existing schedule left unchanged"
    mkdir -p "$UNIT_DIR"
    mv -f "$UNIT_WORK_DIR/immich-to-pixel.service" "$UNIT_WORK_DIR/immich-to-pixel.timer" "$UNIT_DIR/"
fi

run systemctl --user daemon-reload
run systemctl --user enable immich-to-pixel.timer
run systemctl --user restart immich-to-pixel.timer
info "schedule: $SCHEDULE"
info "logs: journalctl --user -u immich-to-pixel.service -f"

if [ "$DRY_RUN" -eq 0 ] && command -v loginctl >/dev/null 2>&1; then
    LINGER="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
    if [ "$LINGER" != yes ]; then
        warn "enable scheduling after logout and reboot: sudo loginctl enable-linger $(id -un)"
    fi
fi
