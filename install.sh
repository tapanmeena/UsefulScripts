#!/usr/bin/env bash
#
# ============================================================
# UsefulScripts installer
# ============================================================
#
# Runs on: Mac + Pi (bash 3.2 safe)
# Requires: ln
#
# Symlinks the scripts into ~/.local/bin without their .sh extension, seeds
# example config files, and installs the scheduled ones as systemd user timers
# (Linux) or launchd agents (macOS).
#
# Scripts describe themselves in their banner, so there is no registry to keep
# in sync here:
#
#   # Runs on: Pi (bash 5)          -> installed on Linux only
#   # Runs on: Mac (bash 3.2 safe)  -> installed on macOS only
#   # Runs on: Mac + Pi (...)       -> installed everywhere
#   # Requires: curl jq adb         -> checked by --check
#
# Usage:  install.sh [--prefix DIR] [--no-timers] [--dry-run]
#         install.sh --check
#         install.sh --uninstall
#         install.sh --target arcadia [other options]
# ============================================================

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

# ------------------------------------------------------------
# SCHEDULE
#
# name|when|args     when: minutely | hourly | daily HH:MM
# Scripts absent from this table are linked but never scheduled.
# ------------------------------------------------------------

SCHEDULE='
hdd-sentinel|daily 06:00|--quiet
wan-watch|minutely|--probe
disk-runway|hourly|--sample
obsidian-daily|daily 23:50|
'

LAUNCHD_PREFIX='com.usefulscripts'

# ------------------------------------------------------------
# ARGUMENTS
# ------------------------------------------------------------

PREFIX="${PREFIX:-$HOME/.local/bin}"
DRY_RUN=0
DO_TIMERS=1
MODE=install
TARGET=''
# Expanded by the remote shell, not this one.
# shellcheck disable=SC2088
REMOTE_PATH='~/UsefulScripts'

usage() {
    cat <<'EOF'
Install the UsefulScripts collection: symlinks, config seeds, and timers.

Usage: install.sh [options]

  --prefix DIR     Where to symlink scripts (default ~/.local/bin).
  --no-timers      Skip systemd/launchd scheduling.
  --check          Report dependencies, configs, and timer status; change nothing.
  --uninstall      Remove symlinks and timers. Never touches configs or state.
  --target HOST    rsync this repo to HOST and install there over SSH.
  --remote-path P  Where to sync on the target (default ~/UsefulScripts).
  --dry-run        Print what would happen; change nothing.
  -h, --help       Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            PREFIX="${2:?--prefix needs a value}"
            shift 2
            ;;
        --target)
            TARGET="${2:?--target needs a value}"
            shift 2
            ;;
        --remote-path)
            REMOTE_PATH="${2:?--remote-path needs a value}"
            shift 2
            ;;
        --no-timers)
            DO_TIMERS=0
            shift
            ;;
        --check)
            MODE=check
            shift
            ;;
        --uninstall)
            MODE=uninstall
            shift
            ;;
        --dry-run)
            DRY_RUN=1
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

# ------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  %bwould:%b %s\n' "$DIM" "$NC" "$*"
    else
        "$@"
    fi
}

# write_file <path> - content on stdin.
write_file() {
    local path="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        cat >/dev/null
        printf '  %bwould:%b write %s\n' "$DIM" "$NC" "$path"
    else
        mkdir -p "$(dirname "$path")"
        cat >"$path"
    fi
}

host_kind() {
    if is_macos; then echo mac; else echo linux; fi
}

# Every *.sh in the repo root except this installer.
discover_scripts() {
    local f
    for f in "$REPO_DIR"/*.sh; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            install.sh) continue ;;
        esac
        printf '%s\n' "$f"
    done
}

# meta_runs_on <file> - mac | linux | any
meta_runs_on() {
    local line
    line="$(sed -n 's/^#[[:space:]]*Runs on:[[:space:]]*//p' "$1" | head -1)"
    case "$line" in
        '') echo any ;;
        *Mac*Pi* | *Pi*Mac*) echo any ;;
        *Pi* | *Linux*) echo linux ;;
        *Mac*) echo mac ;;
        *) echo any ;;
    esac
}

# meta_requires <file> - space separated tool list, possibly empty.
meta_requires() {
    sed -n 's/^#[[:space:]]*Requires:[[:space:]]*//p' "$1" | head -1
}

# schedule_for <name> - echoes "when|args", empty when unscheduled.
schedule_for() {
    printf '%s\n' "$SCHEDULE" | while IFS='|' read -r n when args; do
        [ -n "$n" ] || continue
        if [ "$n" = "$1" ]; then
            printf '%s|%s\n' "$when" "$args"
            break
        fi
    done
}

systemd_calendar() {
    case "$1" in
        minutely) echo '*:0/1' ;;
        hourly) echo 'hourly' ;;
        'daily '*) echo "*-*-* ${1#daily } :00" | sed 's/ :00$/:00/' ;;
        *) echo "$1" ;;
    esac
}

# Without lingering, systemd user timers only run while a session is open, so a
# headless box silently never fires them.
linger_enabled() {
    is_linux || return 0
    command -v loginctl >/dev/null 2>&1 || return 0
    local l
    l="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null ||
        loginctl show-user "$(id -un)" -p Linger 2>/dev/null | sed 's/^Linger=//')"
    [ "$l" = yes ]
}

# ------------------------------------------------------------
# REMOTE
# ------------------------------------------------------------

if [ -n "$TARGET" ]; then
    require_tools rsync ssh
    info "syncing $REPO_DIR -> $TARGET:$REMOTE_PATH"
    # No --delete: the remote copy is often a git checkout with its own state,
    # and silently removing files there is not worth the tidiness.
    run rsync -az \
        --exclude '.git' --exclude '.DS_Store' \
        "$REPO_DIR/" "$TARGET:$REMOTE_PATH/"

    remote_args=''
    [ "$MODE" = check ] && remote_args='--check'
    [ "$MODE" = uninstall ] && remote_args='--uninstall'
    [ "$DO_TIMERS" -eq 0 ] && remote_args="$remote_args --no-timers"
    [ "$DRY_RUN" -eq 1 ] && remote_args="$remote_args --dry-run"

    info "running installer on $TARGET"
    run ssh "$TARGET" "cd $REMOTE_PATH && ./install.sh $remote_args"
    exit 0
fi

HOST_KIND="$(host_kind)"

# ------------------------------------------------------------
# LINK
# ------------------------------------------------------------

do_link() {
    section "Linking into $PREFIX"
    run mkdir -p "$PREFIX"

    local file name runs target
    for file in $(discover_scripts); do
        name="$(basename "$file" .sh)"
        runs="$(meta_runs_on "$file")"
        target="$PREFIX/$name"

        if [ "$runs" != any ] && [ "$runs" != "$HOST_KIND" ]; then
            # It may have been installed here before it was reclassified.
            if [ -L "$target" ]; then
                run rm -f "$target"
                kv "$name" "unlinked (runs on $runs)"
            else
                kv "$name" "skipped (runs on $runs)"
            fi
            continue
        fi

        run chmod +x "$file"

        if [ -L "$target" ] && [ "$(_realpath "$target")" = "$(_realpath "$file")" ]; then
            kv "$name" "already linked"
            continue
        fi
        if [ -e "$target" ] && [ ! -L "$target" ]; then
            warn "$target exists and is not a symlink; skipping"
            continue
        fi

        run ln -sfn "$file" "$target"
        kv "$name" "linked"
    done

    case ":$PATH:" in
        *":$PREFIX:"*) ;;
        *) warn "$PREFIX is not on your PATH. Add: export PATH=\"\$PATH:$PREFIX\"" ;;
    esac
}

# ------------------------------------------------------------
# CONFIGS
#
# Seeds from examples/<name>.conf.example. Never overwrites an existing config,
# because that is where the API keys live.
# ------------------------------------------------------------

do_configs() {
    [ -d "$REPO_DIR/examples" ] || return 0
    section "Seeding configs in $CONFIG_HOME"

    local example name target
    for example in "$REPO_DIR"/examples/*.conf.example; do
        [ -f "$example" ] || continue
        name="$(basename "$example" .conf.example)"
        target="$CONFIG_HOME/$name.conf"

        if [ -e "$target" ]; then
            kv "$name.conf" "exists, left alone"
            continue
        fi

        run mkdir -p "$CONFIG_HOME"
        run cp "$example" "$target"
        run chmod 600 "$target"
        kv "$name.conf" "created (mode 600) - edit before use"
    done
}

# ------------------------------------------------------------
# TIMERS
# ------------------------------------------------------------

# remove_timer <name> <reason> - tears down a schedule this host should not
# have, which happens when a script is reclassified to another platform.
remove_timer() {
    local name="$1" reason="$2" removed=0
    if is_macos; then
        local plist="$HOME/Library/LaunchAgents/$LAUNCHD_PREFIX.$name.plist"
        if [ -f "$plist" ]; then
            run launchctl unload "$plist" 2>/dev/null || true
            run rm -f "$plist"
            removed=1
        fi
    else
        if [ -f "$CONFIG_HOME/systemd/user/$name.timer" ]; then
            run systemctl --user disable --now "$name.timer" 2>/dev/null || true
            run rm -f "$CONFIG_HOME/systemd/user/$name.timer" \
                "$CONFIG_HOME/systemd/user/$name.service"
            run systemctl --user daemon-reload
            removed=1
        fi
    fi
    if [ "$removed" -eq 1 ]; then
        kv "$name" "schedule removed ($reason)"
    else
        kv "$name" "skipped ($reason)"
    fi
}

install_timer_systemd() {
    local name="$1" when="$2" args="$3"
    local unit_dir="$CONFIG_HOME/systemd/user"
    local cal
    cal="$(systemd_calendar "$when")"

    write_file "$unit_dir/$name.service" <<EOF
[Unit]
Description=UsefulScripts: $name

[Service]
Type=oneshot
ExecStart=$PREFIX/$name $args
EOF

    write_file "$unit_dir/$name.timer" <<EOF
[Unit]
Description=UsefulScripts timer: $name

[Timer]
OnCalendar=$cal
Persistent=true

[Install]
WantedBy=timers.target
EOF

    run systemctl --user daemon-reload
    run systemctl --user enable --now "$name.timer"
    kv "$name" "systemd timer ($cal)"
}

install_timer_launchd() {
    local name="$1" when="$2" args="$3"
    local label="$LAUNCHD_PREFIX.$name"
    local plist="$HOME/Library/LaunchAgents/$label.plist"
    local logdir="${XDG_STATE_HOME:-$HOME/.local/state}/$name"
    local interval=''

    case "$when" in
        minutely) interval='<key>StartInterval</key><integer>60</integer>' ;;
        hourly) interval='<key>StartInterval</key><integer>3600</integer>' ;;
        'daily '*)
            local hhmm="${when#daily }"
            interval="<key>StartCalendarInterval</key><dict><key>Hour</key><integer>${hhmm%%:*}</integer><key>Minute</key><integer>${hhmm##*:}</integer></dict>"
            ;;
        *)
            warn "$name: unsupported schedule '$when' on macOS"
            return 0
            ;;
    esac

    run mkdir -p "$logdir"
    write_file "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-lc</string>
    <string>exec "$PREFIX/$name" $args</string>
  </array>
  $interval
  <key>StandardOutPath</key><string>$logdir/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$logdir/launchd.err.log</string>
</dict>
</plist>
EOF

    run launchctl unload "$plist" 2>/dev/null || true
    run launchctl load -w "$plist"
    kv "$name" "launchd agent ($when)"
}

do_timers() {
    [ "$DO_TIMERS" -eq 1 ] || return 0
    section "Scheduling"

    local name when args runs file
    printf '%s\n' "$SCHEDULE" | while IFS='|' read -r name when args; do
        [ -n "$name" ] || continue
        file="$REPO_DIR/$name.sh"

        if [ ! -f "$file" ]; then
            kv "$name" "not built yet, skipped"
            continue
        fi

        runs="$(meta_runs_on "$file")"
        if [ "$runs" != any ] && [ "$runs" != "$HOST_KIND" ]; then
            remove_timer "$name" "runs on $runs"
            continue
        fi

        if is_macos; then
            install_timer_launchd "$name" "$when" "$args"
        else
            install_timer_systemd "$name" "$when" "$args"
        fi
    done

    if ! linger_enabled; then
        warn "user lingering is off, so these timers only run while you are logged in.
      Enable it with: sudo loginctl enable-linger $(id -un)"
    fi
}

# ------------------------------------------------------------
# CHECK
# ------------------------------------------------------------

timer_status() {
    local name="$1"
    if is_macos; then
        local label="$LAUNCHD_PREFIX.$name"
        if launchctl list 2>/dev/null | grep -q "$label"; then
            echo "loaded"
        elif [ -f "$HOME/Library/LaunchAgents/$label.plist" ]; then
            echo "plist present, not loaded"
        else
            echo "-"
        fi
    else
        # Query the unit rather than grepping list-timers, whose columns get
        # truncated to the terminal width and hide the longer unit names.
        local enabled next
        enabled="$(systemctl --user is-enabled "$name.timer" 2>/dev/null || true)"
        case "$enabled" in
            '') echo "-" ;;
            enabled)
                next="$(systemctl --user show "$name.timer" \
                    -p NextElapseUSecRealtime --value 2>/dev/null || true)"
                if [ -n "$next" ] && [ "$next" != 0 ]; then
                    echo "next ${next% *}"
                else
                    echo "enabled"
                fi
                ;;
            *) echo "$enabled" ;;
        esac
    fi
}

do_check() {
    section "UsefulScripts doctor ($HOST_KIND)"
    printf '%-18s %-9s %-10s %-22s %s\n' SCRIPT LINK CONFIG DEPS TIMER
    printf '%-18s %-9s %-10s %-22s %s\n' ------ ---- ------ ---- -----

    local file name runs link cfg deps missing tool timer sched
    for file in $(discover_scripts); do
        name="$(basename "$file" .sh)"
        runs="$(meta_runs_on "$file")"

        if [ "$runs" != any ] && [ "$runs" != "$HOST_KIND" ]; then
            printf '%-18s %bn/a on %s%b\n' "$name" "$DIM" "$HOST_KIND" "$NC"
            continue
        fi

        if [ -L "$PREFIX/$name" ]; then link=ok; else link=MISSING; fi

        if [ -f "$CONFIG_HOME/$name.conf" ]; then
            cfg="$(stat_mode "$CONFIG_HOME/$name.conf")"
            case "$cfg" in
                *00) ;;
                *) cfg="$cfg!" ;;
            esac
        elif [ -f "$REPO_DIR/examples/$name.conf.example" ]; then
            cfg=MISSING
        else
            cfg='-'
        fi

        deps="$(meta_requires "$file")"
        missing=''
        for tool in $deps; do
            command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
        done
        if [ -z "$deps" ]; then
            missing='-'
        elif [ -z "$missing" ]; then
            missing=ok
        else
            missing="need:$missing"
        fi

        sched="$(schedule_for "$name")"
        if [ -n "$sched" ]; then
            timer="$(timer_status "$name")"
        else
            timer='-'
        fi

        printf '%-18s %-9s %-10s %-22s %s\n' "$name" "$link" "$cfg" "$missing" "$timer"
    done

    printf '\n%bLINK%b MISSING means run ./install.sh.  ' "$DIM" "$NC"
    printf '%bCONFIG%b shows file mode; a trailing ! means it is not 600.\n' "$DIM" "$NC"

    if is_linux && ! linger_enabled; then
        printf '\n'
        warn "user lingering is off: timers only run while you are logged in.
      Enable it with: sudo loginctl enable-linger $(id -un)"
    fi
}

# ------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------

do_uninstall() {
    section "Removing symlinks from $PREFIX"
    local file name target
    for file in $(discover_scripts); do
        name="$(basename "$file" .sh)"
        target="$PREFIX/$name"
        if [ -L "$target" ]; then
            run rm -f "$target"
            kv "$name" "unlinked"
        fi
    done

    section "Removing timers"
    printf '%s\n' "$SCHEDULE" | while IFS='|' read -r name when args; do
        [ -n "$name" ] || continue
        if is_macos; then
            local plist="$HOME/Library/LaunchAgents/$LAUNCHD_PREFIX.$name.plist"
            if [ -f "$plist" ]; then
                run launchctl unload "$plist" 2>/dev/null || true
                run rm -f "$plist"
                kv "$name" "launchd agent removed"
            fi
        else
            if [ -f "$CONFIG_HOME/systemd/user/$name.timer" ]; then
                run systemctl --user disable --now "$name.timer" 2>/dev/null || true
                run rm -f "$CONFIG_HOME/systemd/user/$name.timer" \
                    "$CONFIG_HOME/systemd/user/$name.service"
                kv "$name" "systemd timer removed"
            fi
        fi
    done
    is_macos || run systemctl --user daemon-reload

    ok "Configs in $CONFIG_HOME and state in ${XDG_STATE_HOME:-$HOME/.local/state} were left alone."
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

case "$MODE" in
    check) do_check ;;
    uninstall) do_uninstall ;;
    install)
        do_link
        do_configs
        do_timers
        printf '\n'
        ok "Done. Run ./install.sh --check to verify."
        ;;
esac
