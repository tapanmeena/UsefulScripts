#!/usr/bin/env bash
#
# ============================================================
# Shared helpers for UsefulScripts
# ============================================================
#
# Runs on: Mac + Pi (bash 3.2 safe)
#
# Source this from a script in the repo root:
#
#   . "$(dirname "$(_common_self=$0; readlink "$_common_self" || echo "$_common_self")")/lib/common.sh"
#
# In practice scripts use the two-liner documented in the README, which resolves
# symlinks so `install.sh` can drop them into ~/.local/bin.
#
# This file deliberately does NOT set -euo pipefail; that belongs to the script.
#
# Bash 3.2 constraints (macOS ships 3.2 and will not ship anything newer):
#   no declare -A, no mapfile/readarray, no ${x,,}, no ${arr[-1]}, no &>>,   # bash32-lint: allow
#   no globstar, no readlink -f, no date -d, no stat -c, no `sed -i` w/o arg.  # bash32-lint: allow
# Shims for the last four live below.
#
# Expanding an empty array as "${a[@]}" is an unbound-variable error under
# `set -u` in bash 3.2. Guard with a count check or index directly.
# ============================================================

[ -n "${_COMMON_SH:-}" ] && return 0
_COMMON_SH=1

# ------------------------------------------------------------
# PATHS
#
# BASH_SOURCE[0] is this file, [1] is whoever sourced it, so every script gets
# SCRIPT_NAME/REPO_DIR for free.
# ------------------------------------------------------------

_realpath() {
    local p="$1" dir
    while [ -L "$p" ]; do
        dir="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)"
        p="$(readlink "$p")"
        case "$p" in
            /*) ;;
            *) p="$dir/$p" ;;
        esac
    done
    dir="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$p")"
}

LIB_DIR="$(cd -P "$(dirname "$(_realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_DIR="$(dirname "$LIB_DIR")"

if [ -n "${BASH_SOURCE[1]:-}" ]; then
    SCRIPT_PATH="$(_realpath "${BASH_SOURCE[1]}")"
else
    SCRIPT_PATH="$(_realpath "$0")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_NAME="${SCRIPT_NAME%.sh}"

export LIB_DIR REPO_DIR SCRIPT_PATH SCRIPT_DIR SCRIPT_NAME

# ------------------------------------------------------------
# EXIT CODES
#
# Every script in this repo uses these so cron and the alerting wrapper can
# branch on severity instead of parsing output.
# ------------------------------------------------------------

EX_OK=0
EX_WARN=1
EX_CRIT=2
EX_USAGE=64
EX_LOCKED=75

export EX_OK EX_WARN EX_CRIT EX_USAGE EX_LOCKED

# ------------------------------------------------------------
# PLATFORM
# ------------------------------------------------------------

is_macos() { [ "$(uname -s)" = "Darwin" ]; }
is_linux() { [ "$(uname -s)" = "Linux" ]; }

# Debian's non-interactive PATH omits sbin, so an ssh-invoked script reports
# smartctl and dumpe2fs as missing when they are installed.
if is_linux; then
    case ":$PATH:" in
        *:/usr/sbin:*) ;;
        *) PATH="$PATH:/usr/sbin:/sbin" ;;
    esac
    export PATH
fi

is_utf8() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8* | *utf-8* | *UTF8* | *utf8*) return 0 ;;
        *) return 1 ;;
    esac
}

# These must branch on the platform rather than try BSD and fall back to GNU:
# GNU `stat -f` means --file-system and exits 0, so a fallback chain silently
# returns filesystem details instead of the file's metadata.
stat_size() {
    if is_macos; then
        stat -f %z "$1" 2>/dev/null || echo 0
    else
        stat -c %s "$1" 2>/dev/null || echo 0 # bash32-lint: allow
    fi
}

# Three digits, no leading-zero surprises: 600, 044, 700.
stat_mode() {
    local m
    if is_macos; then
        m="$(stat -f '%Lp' "$1" 2>/dev/null || echo '')"
    else
        m="$(stat -c '%a' "$1" 2>/dev/null || echo '')" # bash32-lint: allow
    fi
    [ -n "$m" ] || return 1
    while [ "${#m}" -lt 3 ]; do m="0$m"; done
    printf '%s\n' "$m"
}

stat_mtime() {
    if is_macos; then
        stat -f %m "$1" 2>/dev/null || echo 0
    else
        stat -c %Y "$1" 2>/dev/null || echo 0 # bash32-lint: allow
    fi
}

sed_inplace() {
    local expr="$1"
    shift
    if is_macos; then
        sed -i '' -e "$expr" "$@"
    else
        sed -i -e "$expr" "$@" # bash32-lint: allow
    fi
}

date_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# date_days_ago <n> [fmt] - BSD and GNU date take opposite flags for this.
date_days_ago() {
    local n="$1" fmt="${2:-%Y-%m-%d}"
    if is_macos; then
        date -v-"${n}"d "+$fmt"
    else
        date -d "$n days ago" "+$fmt" # bash32-lint: allow
    fi
}

# ------------------------------------------------------------
# OUTPUT
# ------------------------------------------------------------

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' DIM='' NC=''
fi

info() {
    clear_progress
    printf '%b%s%b\n' "$BLUE" "$*" "$NC"
}
ok() {
    clear_progress
    printf '%b%s%b\n' "$GREEN" "$*" "$NC"
}
warn() {
    clear_progress
    printf '%bwarn:%b %s\n' "$YELLOW" "$NC" "$*" >&2
}
die() {
    clear_progress
    printf '%berror:%b %s\n' "$RED" "$NC" "$*" >&2
    exit "$EX_CRIT"
}
debug() {
    [ -n "${VERBOSE:-}" ] || return 0
    clear_progress
    printf '%b%s%b\n' "$DIM" "$*" "$NC" >&2
}

section() {
    clear_progress
    printf '\n%b%s%b\n' "$BLUE" "$*" "$NC"
}

# kv <label> <value...> - the aligned two-column form used across the repo.
KV_WIDTH="${KV_WIDTH:-24}"
kv() {
    local label="$1"
    shift
    clear_progress
    printf "%-${KV_WIDTH}s %s\n" "$label" "$*"
}

# ------------------------------------------------------------
# PROGRESS
#
# Drawn on stderr so stdout stays pipeable. Every log helper clears the line
# first, otherwise warnings would land on top of a half-drawn bar.
# ------------------------------------------------------------

if [ -t 2 ]; then PROGRESS_TTY=1; else PROGRESS_TTY=0; fi
PROGRESS_ACTIVE=0

TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
case "$TERM_COLS" in
    '' | *[!0-9]*) TERM_COLS=80 ;;
esac
[ "$TERM_COLS" -lt 40 ] && TERM_COLS=80

clear_progress() {
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        printf '\r\033[K' >&2
        PROGRESS_ACTIVE=0
    fi
}

finish_progress() {
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
        printf '\n' >&2
        PROGRESS_ACTIVE=0
    fi
}

# render_progress <done> <total> <sent_kb> <elapsed_s> <label>
# Pass 0 for sent_kb to omit the throughput field.
render_progress() {
    local cur="$1" tot="$2" kb="$3" secs="$4" label="$5"
    [ "$tot" -gt 0 ] || return 0

    if [ "$PROGRESS_TTY" -eq 0 ]; then
        # Non-interactive: an occasional line instead of thousands.
        if [ "$cur" -gt 0 ] && [ $((cur % 50)) -eq 0 ]; then
            printf '[%d/%d] %d%% %s\n' "$cur" "$tot" $((cur * 100 / tot)) "$label" >&2
        fi
        return 0
    fi

    local width=24 pct filled i=0 bar='' eta='--:--' stats='' rate10 rem head label_max
    pct=$((cur * 100 / tot))
    filled=$((pct * width / 100))
    while [ "$i" -lt "$width" ]; do
        if [ "$i" -lt "$filled" ]; then bar="$bar="; else bar="$bar "; fi
        i=$((i + 1))
    done

    if [ "$secs" -gt 0 ]; then
        if [ "$kb" -gt 0 ]; then
            rate10=$((kb * 10 / secs / 1024))
            printf -v stats '  %d.%dMB/s' $((rate10 / 10)) $((rate10 % 10))
        fi
        if [ "$cur" -gt 0 ]; then
            rem=$(((tot - cur) * secs / cur))
            printf -v eta '%02d:%02d' $((rem / 60)) $((rem % 60))
        fi
    fi

    # Measure the prefix and trim the label to match. A wrapped line would leave
    # residue behind the \r redraw.
    printf -v head '[%s] %3d%%  %d/%d%s  ETA %s  ' \
        "$bar" "$pct" "$cur" "$tot" "$stats" "$eta"
    label_max=$((TERM_COLS - ${#head} - 1))
    [ "$label_max" -lt 8 ] && label_max=8

    printf '\r\033[K%s%s' "$head" "${label:0:label_max}" >&2
    PROGRESS_ACTIVE=1
}

# ------------------------------------------------------------
# PRECONDITIONS
# ------------------------------------------------------------

require_tools() {
    local tool missing=''
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    [ -z "$missing" ] || die "missing required tool(s):$missing"
}

require_linux() {
    is_linux || die "$SCRIPT_NAME only runs on Linux (this is $(uname -s))"
}

# ------------------------------------------------------------
# CONFIG AND STATE
# ------------------------------------------------------------

# load_config <name> [path] - sources ~/.config/<name>.conf if present.
# Refuses to read a config that group or others can see, because these files
# hold API keys.
load_config() {
    local name="$1" path="${2:-}" mode
    [ -n "$path" ] || path="${XDG_CONFIG_HOME:-$HOME/.config}/$name.conf"
    export CONFIG_FILE="$path"
    [ -f "$path" ] || return 0

    mode="$(stat_mode "$path")" || die "cannot stat config: $path"
    case "$mode" in
        *00) ;;
        *) die "config $path is mode $mode and holds secrets. Run: chmod 600 $path" ;;
    esac

    # shellcheck source=/dev/null
    . "$path"
}

# state_dir <name> - creates and echoes ~/.local/state/<name>.
state_dir() {
    local dir="${XDG_STATE_HOME:-$HOME/.local/state}/$1"
    mkdir -p "$dir" || die "cannot create state dir: $dir"
    printf '%s\n' "$dir"
}

write_status_snapshot() {
    local name="$1" level="$2" dir temporary checked_at boot_id='-'
    dir="${XDG_STATE_HOME:-$HOME/.local/state}/$name"
    mkdir -p "$dir" || return 1
    temporary="$(mktemp "$dir/.status.XXXXXX")" || return 1
    checked_at="${3:-$(date +%s)}"
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        IFS= read -r boot_id </proc/sys/kernel/random/boot_id || boot_id='-'
    fi
    if { printf '1\t%s\t%s\t%s\n' "$checked_at" "$level" "$boot_id" && cat; } >"$temporary" &&
        mv -f "$temporary" "$dir/status.tsv"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}

# ------------------------------------------------------------
# EXIT HANDLERS
#
# bash traps overwrite each other, so both the library and the script would
# otherwise fight over EXIT. Handlers run last-registered-first.
# ------------------------------------------------------------

_ON_EXIT_FNS=()

_run_exit_handlers() {
    local rc=$? i
    i="${#_ON_EXIT_FNS[@]}"
    while [ "$i" -gt 0 ]; do
        i=$((i - 1))
        "${_ON_EXIT_FNS[$i]}" || true
    done
    return "$rc"
}

on_exit() {
    _ON_EXIT_FNS[${#_ON_EXIT_FNS[@]}]="$1"
    trap _run_exit_handlers EXIT
}

# ------------------------------------------------------------
# LOCKING
#
# Returns EX_LOCKED when another copy holds the lock, so cron can tell
# "already running" apart from "the job failed".
# ------------------------------------------------------------

_LOCK_DIR=''
_LOCK_FD_HELD=0

_release_lock() {
    if [ "$_LOCK_FD_HELD" -eq 1 ]; then
        exec 9>&-
        _LOCK_FD_HELD=0
    fi
    [ -n "$_LOCK_DIR" ] || return 0
    rm -f "$_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$_LOCK_DIR" 2>/dev/null || true
    _LOCK_DIR=''
}

# acquire_lock <name> - hold the lock for the rest of this process, releasing
# it on exit. Returns EX_LOCKED when another copy has it. Linear scripts that
# cannot wrap their work in a function want this rather than with_lock.
acquire_lock() {
    local name="$1" dir
    dir="$(state_dir "$name")"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$dir/lock" || return "$EX_LOCKED"
        if ! flock -n 9; then
            exec 9>&-
            return "$EX_LOCKED"
        fi
        _LOCK_FD_HELD=1
        on_exit _release_lock
        return 0
    fi

    # macOS has no flock(1). mkdir is atomic everywhere; the pid file lets us
    # reap a lock left behind by a killed run.
    local lockdir="$dir/lock.d" pid
    if ! mkdir "$lockdir" 2>/dev/null; then
        pid="$(cat "$lockdir/pid" 2>/dev/null || echo '')"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return "$EX_LOCKED"
        fi
        debug "reaping stale lock at $lockdir (pid ${pid:-unknown})"
        rm -rf "$lockdir"
        mkdir "$lockdir" 2>/dev/null || return "$EX_LOCKED"
    fi

    printf '%s\n' "$$" >"$lockdir/pid"
    _LOCK_DIR="$lockdir"
    on_exit _release_lock
    return 0
}

# with_lock <name> <command...>
#
# The command runs in the current shell, so it may be a function. That rules
# out `flock <file> <cmd>`, which execs and would fail with "No such file or
# directory" for anything that is not a real binary. Uses fd 9, so nesting two
# locks in one shell is not supported.
with_lock() {
    local name="$1"
    shift
    local rc=0
    acquire_lock "$name" || return "$EX_LOCKED"
    "$@" || rc=$?
    _release_lock
    return "$rc"
}

# ------------------------------------------------------------
# NOTIFICATIONS
#
# One entry point for every script so alerting is configured once. Backends are
# selected by NOTIFY_BACKEND in the script's config file. syslog is the default
# because it needs nothing installed; ntfy/telegram/gotify are stubs today.
# ------------------------------------------------------------

NOTIFY_BACKEND="${NOTIFY_BACKEND:-syslog}"
_NOTIFY_WARNED=0

_notify_stdout() {
    local level="$1" title="$2" body="$3" color="$BLUE"
    case "$level" in
        crit | critical | error) color="$RED" ;;
        warn | warning) color="$YELLOW" ;;
        ok | info) color="$GREEN" ;;
    esac
    clear_progress
    printf '%b[%s]%b %s\n' "$color" "$level" "$NC" "$title" >&2
    [ -n "$body" ] && printf '%s\n' "$body" >&2
    return 0
}

_notify_syslog() {
    local level="$1" title="$2" body="$3" pri
    command -v logger >/dev/null 2>&1 || return 0
    case "$level" in
        crit | critical | error) pri='user.err' ;;
        warn | warning) pri='user.warning' ;;
        *) pri='user.notice' ;;
    esac
    if [ -n "$body" ]; then
        printf '%s: %s\n' "$title" "$body" | logger -t "$SCRIPT_NAME" -p "$pri"
    else
        logger -t "$SCRIPT_NAME" -p "$pri" -- "$title"
    fi
}

# notify <level> <title> [body]
notify() {
    local level="$1" title="$2" body="${3:-}"
    _notify_stdout "$level" "$title" "$body"
    case "$NOTIFY_BACKEND" in
        stdout | none) ;;
        syslog) _notify_syslog "$level" "$title" "$body" ;;
        ntfy | telegram | gotify)
            if [ "$_NOTIFY_WARNED" -eq 0 ]; then
                _NOTIFY_WARNED=1
                warn "NOTIFY_BACKEND=$NOTIFY_BACKEND is not implemented yet; using syslog"
            fi
            _notify_syslog "$level" "$title" "$body"
            ;;
        *)
            if [ "$_NOTIFY_WARNED" -eq 0 ]; then
                _NOTIFY_WARNED=1
                warn "unknown NOTIFY_BACKEND '$NOTIFY_BACKEND'; using syslog"
            fi
            _notify_syslog "$level" "$title" "$body"
            ;;
    esac
}

# notify_dedupe <key> <cooldown_seconds> <level> <title> [body]
#
# Suppresses repeats of the same key inside the cooldown. Without this a
# once-a-minute health check turns into noise within a day and gets ignored,
# which is worse than no alerting at all.
notify_dedupe() {
    local key="$1" cooldown="$2" level="$3" title="$4" body="${5:-}"
    local dir stamp now last safe
    dir="$(state_dir "${NOTIFY_STATE_NAME:-$SCRIPT_NAME}")/notify"
    mkdir -p "$dir"
    safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
    stamp="$dir/$safe"
    now="$(date +%s)"

    if [ -f "$stamp" ]; then
        last="$(cat "$stamp" 2>/dev/null || echo 0)"
        case "$last" in
            '' | *[!0-9]*) last=0 ;;
        esac
        if [ $((now - last)) -lt "$cooldown" ]; then
            debug "notify suppressed (key=$key, cooldown=${cooldown}s)"
            return 0
        fi
    fi

    printf '%s\n' "$now" >"$stamp"
    notify "$level" "$title" "$body"
}

# ------------------------------------------------------------
# FORMATTING
# ------------------------------------------------------------

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", u, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]
        else printf "%.1f %s", b, u[i]
    }'
}

human_duration() {
    awk -v s="${1:-0}" 'BEGIN {
        s = int(s)
        d = int(s / 86400); s -= d * 86400
        h = int(s / 3600);  s -= h * 3600
        m = int(s / 60);    s -= m * 60
        out = ""
        if (d > 0) out = out d "d "
        if (d > 0 || h > 0) out = out h "h "
        if (d == 0) out = out m "m"
        sub(/ $/, "", out)
        print out
    }'
}

# sparkline <value...> - eight-level bar string, ASCII when the locale is not
# UTF-8. Bucketing happens in one awk pass; the glyph lookup stays in bash
# because mawk splits multi-byte strings by byte.
sparkline() {
    [ $# -gt 0 ] || return 0
    local chars idx out=''
    if is_utf8; then
        chars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
    else
        chars=(_ . - '~' '=' + '*' '#')
    fi

    for idx in $(printf '%s\n' "$@" | awk '
        {
            v[NR] = $1 + 0
            if (NR == 1 || v[NR] < min) min = v[NR]
            if (NR == 1 || v[NR] > max) max = v[NR]
        }
        END {
            span = max - min
            for (i = 1; i <= NR; i++) {
                print (span == 0) ? 0 : int((v[i] - min) / span * 7 + 0.5)
            }
        }'); do
        out="$out${chars[$idx]}"
    done
    printf '%s' "$out"
}

# ------------------------------------------------------------
# DATA
# ------------------------------------------------------------

# csv_append <file> <header> <row> - writes the header only on first use.
csv_append() {
    local file="$1" header="$2" row="$3"
    if [ ! -s "$file" ]; then
        mkdir -p "$(dirname "$file")"
        printf '%s\n' "$header" >"$file"
    fi
    printf '%s\n' "$row" >>"$file"
}

# retry <attempts> <command...> - exponential backoff, for flaky network calls.
retry() {
    local attempts="$1"
    shift
    local i=1 delay=1
    while :; do
        "$@" && return 0
        [ "$i" -ge "$attempts" ] && return 1
        debug "retry $i/$attempts failed, sleeping ${delay}s"
        sleep "$delay"
        delay=$((delay * 2))
        i=$((i + 1))
    done
}
