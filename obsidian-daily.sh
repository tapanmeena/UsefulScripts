#!/usr/bin/env bash
#
# ============================================================
# obsidian-daily - write the day's machine log into your vault
# ============================================================
#
# Runs on: Mac + Pi (bash 3.2 safe)
# Requires: git
#
# Appends an idempotent block to the Obsidian daily note containing what your
# machines actually did: commits across every repository, photos added to
# Immich, and a one line health summary from the Pi. It is a work journal you
# did not have to write.
#
# The daily note folder and filename format are read from
# .obsidian/daily-notes.json rather than hardcoded, so changing the format in
# Obsidian does not break this. Moment tokens are translated to strftime.
#
# The block is delimited by HTML comments and replaced in place, so running it
# from a timer several times a day is safe.
#
# --range backfills, which will reconstruct months of history from git in one
# pass the first time you run it.
#
# Config file (default ~/.config/obsidian-daily.conf, mode 600):
#   VAULT="$HOME/Desktop/ObsiSync"
#   ROOTS="$HOME/Desktop/Projects"
#   PI_HOST="arcadia"
#   IMMICH_URL="http://192.168.1.11:2283"
#   IMMICH_API_KEY="..."
#
# Usage:  obsidian-daily.sh [--date YYYY-MM-DD] [--range A..B]
#                           [--dry-run] [--commit]
# ============================================================

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

START_MARK='<!-- machine-log:start -->'
END_MARK='<!-- machine-log:end -->'

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

load_config obsidian-daily

VAULT="${VAULT:-$HOME/Desktop/ObsiSync}"
ROOTS="${ROOTS:-$HOME/Desktop/Projects}"
PI_HOST="${PI_HOST:-}"
IMMICH_URL="${IMMICH_URL:-}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
PROJECT_NOTES="${PROJECT_NOTES:-04 - Projects}"
SECTION_TITLE="${SECTION_TITLE:-## Machine Log}"

TARGET_DATE=''
RANGE=''
DRY_RUN=0
DO_COMMIT=0

usage() {
    cat <<'EOF'
Write an automatic machine log into the Obsidian daily note.

Usage: obsidian-daily.sh [options]

  --date YYYY-MM-DD   Write the note for this date (default today).
  --range A..B        Backfill every date in the inclusive range.
  --dry-run           Print what would be written; change nothing.
  --commit            Commit the vault afterwards. Off by default.
  -h, --help          Show this help.

Settings (config file wins over environment):
  VAULT, ROOTS, PI_HOST, IMMICH_URL, IMMICH_API_KEY, PROJECT_NOTES
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --date)
            TARGET_DATE="${2:?--date needs a value}"
            shift 2
            ;;
        --range)
            RANGE="${2:?--range needs A..B}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --commit)
            DO_COMMIT=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

require_tools git
[ -d "$VAULT" ] || die "vault not found: $VAULT"

# ------------------------------------------------------------
# DATES
# ------------------------------------------------------------

dfmt() {
    if is_macos; then
        date -j -f '%Y-%m-%d' "$1" "+$2" 2>/dev/null
    else
        date -d "$1" "+$2" 2>/dev/null # bash32-lint: allow
    fi
}

next_day() {
    if is_macos; then
        date -j -v+1d -f '%Y-%m-%d' "$1" '+%Y-%m-%d' 2>/dev/null
    else
        date -d "$1 + 1 day" '+%Y-%m-%d' 2>/dev/null # bash32-lint: allow
    fi
}

# Obsidian stores moment.js tokens; strftime needs different ones. Longer
# tokens are replaced first so MM does not eat the tail of MMMM.
moment_to_strftime() {
    printf '%s' "$1" | sed \
        -e 's/YYYY/%Y/g' \
        -e 's/MMMM/%B/g' \
        -e 's/MMM/%b/g' \
        -e 's/MM/%m/g' \
        -e 's/dddd/%A/g' \
        -e 's/ddd/%a/g' \
        -e 's/DD/%d/g' \
        -e 's/HH/%H/g' \
        -e 's/mm/%M/g' \
        -e 's/ss/%S/g'
}

# ------------------------------------------------------------
# VAULT LAYOUT
# ------------------------------------------------------------

read_daily_config() {
    local cfg="$VAULT/.obsidian/daily-notes.json"
    DAILY_FOLDER='Daily'
    DAILY_FORMAT='YYYY-MM-DD'
    TEMPLATE_PATH=''
    [ -f "$cfg" ] || return 0

    if command -v jq >/dev/null 2>&1; then
        DAILY_FOLDER="$(jq -r '.folder // "Daily"' "$cfg")"
        DAILY_FORMAT="$(jq -r '.format // "YYYY-MM-DD"' "$cfg")"
        TEMPLATE_PATH="$(jq -r '.template // ""' "$cfg")"
    else
        DAILY_FOLDER="$(sed -n 's/.*"folder"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)"
        DAILY_FORMAT="$(sed -n 's/.*"format"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)"
        [ -n "$DAILY_FOLDER" ] || DAILY_FOLDER='Daily'
        [ -n "$DAILY_FORMAT" ] || DAILY_FORMAT='YYYY-MM-DD'
    fi
}

note_path_for() {
    local d="$1" fmt
    fmt="$(moment_to_strftime "$DAILY_FORMAT")"
    printf '%s/%s/%s.md' "$VAULT" "$DAILY_FOLDER" "$(dfmt "$d" "$fmt")"
}

# Templater expressions only evaluate inside Obsidian, so a note created here
# would otherwise keep raw <% %> markers forever.
render_template() {
    local d="$1" tpl="$2"
    sed -e "s|<% *tp\.date\.now([^)]*) *%>|$(dfmt "$d" '%A, %d-%B-%Y')|g" \
        -e '/<%.*tp\.web\..*%>/d' \
        -e 's|<%[^%]*%>||g' "$tpl"
}

# ------------------------------------------------------------
# CONTENT
# ------------------------------------------------------------

is_repo() { [ -d "$1/.git" ] || [ -f "$1/.git" ]; }

# Notes under the projects folder, so repository names can be linked into the
# graph instead of sitting there as dead text.
project_note_for() {
    local name norm cand cnorm
    name="$1"
    norm="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        cnorm="$(basename "$cand" .md | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
        if [ "$cnorm" = "$norm" ]; then
            basename "$cand" .md
            return 0
        fi
    done <<EOF
$(find "$VAULT/$PROJECT_NOTES" -name '*.md' 2>/dev/null)
EOF
    return 1
}

commits_for() {
    local d="$1" root dir name email log linked any=0
    for root in $ROOTS; do
        [ -d "$root" ] || continue
        for dir in "$root"/*; do
            [ -d "$dir" ] || continue
            is_repo "$dir" || continue
            name="$(basename "$dir")"
            email="$(git -C "$dir" config user.email 2>/dev/null || true)"

            if [ -n "$email" ]; then
                log="$({ git -C "$dir" log --no-merges --author="$email" \
                    --since="$d 00:00:00" --until="$d 23:59:59" \
                    --format='%s' 2>/dev/null || true; })"
            else
                log="$({ git -C "$dir" log --no-merges \
                    --since="$d 00:00:00" --until="$d 23:59:59" \
                    --format='%s' 2>/dev/null || true; })"
            fi

            [ -n "$log" ] || continue
            any=1
            if linked="$(project_note_for "$name")"; then
                printf '\n**[[%s|%s]]**\n' "$linked" "$name"
            else
                printf '\n**%s**\n' "$name"
            fi
            printf '%s\n' "$log" | sed 's/^/- /'
        done
    done
    [ "$any" -eq 1 ] || printf '\n_No commits._\n'
}

immich_added_on() {
    [ -n "$IMMICH_URL" ] && [ -n "$IMMICH_API_KEY" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    local d="$1" cfg count
    cfg="$(mktemp)"
    (umask 077 && printf 'header = "x-api-key: %s"\n' "$IMMICH_API_KEY" >"$cfg")
    count="$({ curl -sS -f -K "$cfg" --max-time 10 \
        -H 'Content-Type: application/json' \
        --data-binary "{\"takenAfter\":\"${d}T00:00:00.000Z\",\"takenBefore\":\"${d}T23:59:59.999Z\",\"size\":1}" \
        "${IMMICH_URL%/}/api/search/metadata" 2>/dev/null || true; } |
        jq -r '.assets.total // empty' 2>/dev/null || true)"
    rm -f "$cfg"
    [ -n "$count" ] || return 1
    printf '%s' "$count"
}

pi_health() {
    [ -n "$PI_HOST" ] || return 1
    # Instantaneous CPU and memory say nothing useful in a daily journal and
    # would make the note differ on every run. Keep the durable fields.
    ssh -o BatchMode=yes -o ConnectTimeout=6 "$PI_HOST" \
        'PATH=$HOME/.local/bin:$PATH rpistats --oneline' 2>/dev/null |
        awk -F' \\| ' '{
            out = $1
            for (i = 2; i <= NF; i++)
                if ($i !~ /^(cpu|ram) /) out = out " | " $i
            print out
        }'
}

build_block() {
    local d="$1" photos health
    printf '### Commits\n'
    commits_for "$d"

    if photos="$(immich_added_on "$d")"; then
        printf '\n### Photos\n- %s asset(s) added to Immich\n' "$photos"
    fi

    if health="$(pi_health)"; then
        # The backticks are markdown, not a command substitution.
        # shellcheck disable=SC2016
        printf '\n### Pi\n- `%s`\n' "$health"
    fi

    # Date only, not time: a timestamp that moves every minute would make the
    # block differ on every run and churn the vault's sync history.
    printf '\n_Machine generated for %s._\n' "$d"
}

# ------------------------------------------------------------
# WRITE
# ------------------------------------------------------------

write_note() {
    local d="$1" note block tmp
    note="$(note_path_for "$d")"
    [ -n "$note" ] || die "cannot resolve a note path for $d"

    block="$(mktemp)"
    build_block "$d" >"$block"

    if [ "$DRY_RUN" -eq 1 ]; then
        section "$d -> $note"
        printf '%s\n' "$SECTION_TITLE"
        printf '%s\n' "$START_MARK"
        cat "$block"
        printf '%s\n' "$END_MARK"
        rm -f "$block"
        return 0
    fi

    mkdir -p "$(dirname "$note")"

    if [ ! -f "$note" ]; then
        local tpl="$VAULT/Templates/Daily Template.md"
        if [ -n "$TEMPLATE_PATH" ] && [ -f "$VAULT/$TEMPLATE_PATH" ]; then
            tpl="$VAULT/$TEMPLATE_PATH"
        fi
        if [ -f "$tpl" ]; then
            render_template "$d" "$tpl" >"$note"
        else
            printf '# %s\n' "$(dfmt "$d" '%A, %d-%B-%Y')" >"$note"
        fi
    fi

    tmp="$(mktemp)"
    if grep -qF "$START_MARK" "$note"; then
        # Replace between the markers so repeated runs do not stack up.
        awk -v s="$START_MARK" -v e="$END_MARK" -v f="$block" '
            $0 == s { print; while ((getline line < f) > 0) print line; skip = 1; next }
            $0 == e { skip = 0; print; next }
            !skip { print }
        ' "$note" >"$tmp"
    else
        {
            cat "$note"
            printf '\n%s\n%s\n' "$SECTION_TITLE" "$START_MARK"
            cat "$block"
            printf '%s\n' "$END_MARK"
        } >"$tmp"
    fi

    mv "$tmp" "$note"
    rm -f "$block"
    ok "wrote $note"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

read_daily_config

if [ -n "$RANGE" ]; then
    from="${RANGE%%..*}"
    to="${RANGE##*..}"
    [ -n "$from" ] && [ -n "$to" ] || die "--range needs the form YYYY-MM-DD..YYYY-MM-DD"
    d="$from"
    guard=0
    while :; do
        write_note "$d"
        [ "$d" = "$to" ] && break
        d="$(next_day "$d")"
        [ -n "$d" ] || die "could not advance past $from"
        guard=$((guard + 1))
        [ "$guard" -gt 3660 ] && die "range longer than ten years, refusing"
    done
else
    [ -n "$TARGET_DATE" ] || TARGET_DATE="$(date '+%Y-%m-%d')"
    write_note "$TARGET_DATE"
fi

if [ "$DO_COMMIT" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ -n "$(git -C "$VAULT" status --porcelain 2>/dev/null)" ]; then
        git -C "$VAULT" add -A
        git -C "$VAULT" commit -q -m "chore: machine log for $(date '+%Y-%m-%d')"
        ok "committed the vault"
    else
        info "vault unchanged, nothing to commit"
    fi
fi
