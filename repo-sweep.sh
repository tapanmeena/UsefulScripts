#!/usr/bin/env bash
#
# ============================================================
# repo-sweep - what did I leave half-finished
# ============================================================
#
# Runs on: Mac + Pi (bash 3.2 safe)
# Requires: git
#
# Scans a directory of git repositories and reports, per repo, the work that is
# at risk of being lost: unpushed commits, stashes, uncommitted changes, and
# branches with no upstream. Sorted by risk rather than alphabetically, because
# unpushed commits exist only on this disk.
#
# Sibling `<repo>.worktrees/` directories are scanned one level deeper, since a
# linked worktree stores .git as a file rather than a directory.
#
# Never contacts the network unless you pass --fetch.
#
# Config file (default ~/.config/repo-sweep.conf, mode 600):
#   ROOTS="$HOME/Desktop/Projects $HOME/work"
#   JOBS=8
#   STALE_DAYS=90
#   BIG_FILE_MB=10
#
# Usage:  repo-sweep.sh [--root DIR] [--dirty|--unpushed|--stale N] [--json]
#                       [--fetch] [--jobs N] [--prune-merged [--yes]]
# ============================================================

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

# ------------------------------------------------------------
# WORKER
#
# xargs cannot call a shell function, so the parallel pass re-executes this
# script with --collect-one. Handled before normal argument parsing so the
# worker starts as cheaply as possible.
# ------------------------------------------------------------

TAB="$(printf '\t')"

# git_field <fallback> <command...>
#
# `x=$(cmd || echo fallback)` is a trap: a command that fails *after* writing to
# stdout, which git does for an unborn HEAD, leaves you with its output and the
# fallback concatenated. That silently shifts every later column.
git_field() {
    local fallback="$1" out
    shift
    # The `|| true` is load-bearing under pipefail: git exits non-zero for an
    # unborn HEAD, which would otherwise kill the worker.
    out="$({ "$@" 2>/dev/null || true; } | head -1 | tr -d '\r\n')"
    [ -n "$out" ] || out="$fallback"
    printf '%s' "$out"
}

# rel_age <epoch> - compact fixed-width age, since %cr runs to "1 year, 5 months ago".
rel_age() {
    awk -v t="$1" -v now="$(date +%s)" 'BEGIN {
        if (t <= 0) { print "never"; exit }
        d = now - t
        if (d < 3600)   { printf "%dm", d / 60 }
        else if (d < 86400)   { printf "%dh", d / 3600 }
        else if (d < 2592000) { printf "%dd", d / 86400 }
        else if (d < 31536000) { printf "%dmo", d / 2592000 }
        else { printf "%.1fy", d / 31536000 }
    }'
}

collect_one() {
    local dir="$1" outdir="$2"
    local name branch st staged unstaged untracked dirty
    local ahead behind upstream stash last_epoch last_rel
    local merged worktrees big notes score default sz f

    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0

    name="$(basename "$dir")"
    case "$(dirname "$dir")" in
        *.worktrees) name="$(basename "$(dirname "$dir")" .worktrees)/$name" ;;
    esac

    if [ "${DO_FETCH:-0}" -eq 1 ]; then
        git -C "$dir" fetch --quiet --no-tags --prune 2>/dev/null || true
    fi

    # --show-current reports the branch even for an unborn HEAD, and prints
    # nothing when detached, which rev-parse cannot distinguish.
    branch="$(git_field '' git -C "$dir" branch --show-current)"
    [ -n "$branch" ] || branch='(detached)'

    st="$(git -C "$dir" status --porcelain 2>/dev/null || true)"
    staged="$(printf '%s\n' "$st" | grep -c '^[MADRC]' || true)"
    unstaged="$(printf '%s\n' "$st" | grep -c '^.[MD]' || true)"
    untracked="$(printf '%s\n' "$st" | grep -c '^??' || true)"
    dirty=$((staged + unstaged + untracked))

    if git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        upstream=1
        read -r behind ahead <<EOF
$(git -C "$dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || echo '0 0')
EOF
    else
        upstream=0
        behind=0
        # No upstream means every commit is unpushed, not zero.
        ahead="$(git_field 0 git -C "$dir" rev-list --count HEAD)"
        [ "$ahead" -gt 999 ] && ahead=999
    fi

    stash="$(git -C "$dir" stash list 2>/dev/null | grep -c . || true)"
    last_epoch="$(git_field 0 git -C "$dir" log -1 --format=%ct)"
    last_rel="$(rel_age "$last_epoch")"

    default="$(git_field main git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD)"
    default="${default#origin/}"
    if git -C "$dir" rev-parse --verify --quiet "$default" >/dev/null 2>&1; then
        merged="$(git -C "$dir" branch --merged "$default" --format='%(refname:short)' 2>/dev/null |
            grep -v "^${default}\$" | grep -c . || true)"
    else
        merged=0
    fi

    worktrees="$(git -C "$dir" worktree list 2>/dev/null | grep -c . || true)"
    worktrees=$((worktrees > 0 ? worktrees - 1 : 0))

    big=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$dir/$f" ] || continue
        sz="$(stat_size "$dir/$f")"
        [ "$sz" -gt $((BIG_FILE_MB * 1024 * 1024)) ] && big=$((big + 1))
    done <<EOF
$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null | head -300)
EOF

    notes=''
    [ "$upstream" -eq 0 ] && notes="${notes}no-upstream,"
    [ "$branch" = '(detached)' ] && notes="${notes}detached,"
    [ "$stash" -gt 0 ] && notes="${notes}${stash}-stash,"
    [ "$behind" -gt 0 ] && notes="${notes}behind-${behind},"
    [ "$merged" -gt 0 ] && notes="${notes}${merged}-merged,"
    [ "$big" -gt 0 ] && notes="${notes}${big}-big-untracked,"
    if [ -f "$dir/.env" ] && ! git -C "$dir" check-ignore -q .env 2>/dev/null; then
        notes="${notes}env-unignored,"
    fi
    notes="${notes%,}"
    [ -n "$notes" ] || notes='-'

    # Unpushed work outranks everything: this disk is its only copy.
    score=$((ahead * 10 + stash * 5 + big * 3))
    [ "$upstream" -eq 0 ] && score=$((score + 8))
    if [ "$dirty" -gt 20 ]; then score=$((score + 20)); else score=$((score + dirty)); fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$score" "$name" "$branch" "$staged" "$unstaged" "$untracked" \
        "$ahead" "$behind" "$stash" "$last_epoch" "$last_rel" "$worktrees" "$notes" \
        >"$outdir/$(printf '%s' "$dir" | tr -c 'A-Za-z0-9' '_').tsv"
}

if [ "${1:-}" = '--collect-one' ]; then
    BIG_FILE_MB="${BIG_FILE_MB:-10}"
    collect_one "$2" "$3"
    exit 0
fi

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

load_config repo-sweep

ROOTS="${ROOTS:-$HOME/Desktop/Projects}"
JOBS="${JOBS:-8}"
STALE_DAYS="${STALE_DAYS:-90}"
BIG_FILE_MB="${BIG_FILE_MB:-10}"

FILTER=all
STALE_ARG=""
DO_FETCH=0
AS_JSON=0
PRUNE=0
ASSUME_YES=0

usage() {
    cat <<'EOF'
Report unfinished and at-risk work across a directory of git repositories.

Usage: repo-sweep.sh [options]

  --root DIR       Directory of repositories (repeatable). Default ~/Desktop/Projects.
  --dirty          Only repos with uncommitted changes.
  --unpushed       Only repos with commits that exist nowhere else.
  --stale N        Only repos untouched for N days.
  --fetch          Update remote-tracking refs first. Slow; off by default.
  --jobs N         Parallel workers (default 8).
  --prune-merged   List local branches already merged into the default branch.
  --yes            With --prune-merged, actually delete them.
  --json           Machine-readable output.
  -h, --help       Show this help.

Settings (config file wins over environment): ROOTS, JOBS, STALE_DAYS, BIG_FILE_MB
EOF
}

ROOT_OVERRIDE=''
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            ROOT_OVERRIDE="$ROOT_OVERRIDE ${2:?--root needs a value}"
            shift 2
            ;;
        --dirty)
            FILTER=dirty
            shift
            ;;
        --unpushed)
            FILTER=unpushed
            shift
            ;;
        --stale)
            FILTER=stale
            STALE_ARG="${2:?--stale needs a value}"
            shift 2
            ;;
        --fetch)
            DO_FETCH=1
            shift
            ;;
        --jobs)
            JOBS="${2:?--jobs needs a value}"
            shift 2
            ;;
        --prune-merged)
            PRUNE=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --json)
            AS_JSON=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

[ -n "$ROOT_OVERRIDE" ] && ROOTS="$ROOT_OVERRIDE"
[ -n "$STALE_ARG" ] && STALE_DAYS="$STALE_ARG"

case "$JOBS" in
    '' | *[!0-9]* | 0) die "--jobs must be a positive integer" ;;
esac

require_tools git

export DO_FETCH BIG_FILE_MB

# ------------------------------------------------------------
# DISCOVERY
# ------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
# shellcheck disable=SC2329  # invoked via on_exit
cleanup_workdir() { rm -rf "$WORK_DIR"; }
on_exit cleanup_workdir

REPO_LIST="$WORK_DIR/repos"
: >"$REPO_LIST"

is_repo() { [ -d "$1/.git" ] || [ -f "$1/.git" ]; }

for root in $ROOTS; do
    [ -d "$root" ] || {
        warn "no such directory: $root"
        continue
    }
    for entry in "$root"/*; do
        [ -d "$entry" ] || continue
        if is_repo "$entry"; then
            printf '%s\n' "$entry" >>"$REPO_LIST"
            continue
        fi
        # Linked worktrees live one level down and keep .git as a file.
        case "$entry" in
            *.worktrees)
                for wt in "$entry"/*; do
                    [ -d "$wt" ] || continue
                    is_repo "$wt" && printf '%s\n' "$wt" >>"$REPO_LIST"
                done
                ;;
        esac
    done
done

REPO_COUNT="$(grep -c . "$REPO_LIST" || true)"
[ "$REPO_COUNT" -gt 0 ] || die "no git repositories found under: $ROOTS"

# ------------------------------------------------------------
# COLLECT
#
# Each worker writes its own file. Appending to a shared file from N processes
# would interleave once a line exceeds the pipe buffer.
# ------------------------------------------------------------

OUT_DIR="$WORK_DIR/out"
mkdir -p "$OUT_DIR"

[ "$DO_FETCH" -eq 1 ] && [ "$AS_JSON" -eq 0 ] && info "fetching $REPO_COUNT repositories with $JOBS workers..."

xargs -P "$JOBS" -I{} "$SCRIPT_PATH" --collect-one {} "$OUT_DIR" <"$REPO_LIST"

ALL="$WORK_DIR/all.tsv"
RAW="$WORK_DIR/raw.tsv"
cat "$OUT_DIR"/*.tsv 2>/dev/null >"$RAW" || true
[ -s "$RAW" ] || die "collected nothing from $REPO_COUNT repositories"

# A short row means some field swallowed a newline and shifted the columns.
# Drop it loudly rather than printing a garbled line.
awk -F"$TAB" -v n=13 'NF == n' "$RAW" | sort -t"$TAB" -k1,1nr -k10,10nr >"$ALL"
MALFORMED="$(awk -F"$TAB" -v n=13 'NF != n' "$RAW" | grep -c . || true)"
[ "$MALFORMED" -gt 0 ] && warn "$MALFORMED malformed row(s) dropped"
[ -s "$ALL" ] || die "every collected row was malformed"

# ------------------------------------------------------------
# FILTER
# ------------------------------------------------------------

NOW="$(date +%s)"
STALE_CUTOFF=$((NOW - STALE_DAYS * 86400))
FILTERED="$WORK_DIR/filtered.tsv"

awk -F"$TAB" -v mode="$FILTER" -v cutoff="$STALE_CUTOFF" '
    {
        dirty  = $4 + $5 + $6
        ahead  = $7
        stash  = $9
        last   = $10
    }
    mode == "all"                                      { print; next }
    mode == "dirty"    && dirty > 0                    { print; next }
    mode == "unpushed" && (ahead > 0 || stash > 0)     { print; next }
    mode == "stale"    && last < cutoff                { print; next }
' "$ALL" >"$FILTERED"

# ------------------------------------------------------------
# PRUNE MERGED
# ------------------------------------------------------------

if [ "$PRUNE" -eq 1 ]; then
    section "Local branches already merged into the default branch"
    found=0
    while IFS= read -r dir; do
        default="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
        [ -n "$default" ] || default=main
        git -C "$dir" rev-parse --verify --quiet "$default" >/dev/null 2>&1 || continue
        current="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

        while IFS= read -r br; do
            [ -n "$br" ] || continue
            [ "$br" = "$default" ] && continue
            [ "$br" = "$current" ] && continue
            found=$((found + 1))
            if [ "$ASSUME_YES" -eq 1 ]; then
                if git -C "$dir" branch -d "$br" >/dev/null 2>&1; then
                    ok "deleted $(basename "$dir"):$br"
                else
                    warn "could not delete $(basename "$dir"):$br"
                fi
            else
                kv "$(basename "$dir")" "$br"
            fi
        done <<EOF
$(git -C "$dir" branch --merged "$default" --format='%(refname:short)' 2>/dev/null || true)
EOF
    done <"$REPO_LIST"

    if [ "$found" -eq 0 ]; then
        ok "nothing to prune"
    elif [ "$ASSUME_YES" -eq 0 ]; then
        printf '\n'
        info "$found branch(es) listed. Re-run with --prune-merged --yes to delete them."
    fi
    exit "$EX_OK"
fi

# ------------------------------------------------------------
# OUTPUT
# ------------------------------------------------------------

if [ "$AS_JSON" -eq 1 ]; then
    awk -F"$TAB" '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
        BEGIN { print "[" ; first = 1 }
        {
            if (!first) print ","
            first = 0
            printf "  {\"repo\":\"%s\",\"branch\":\"%s\",\"staged\":%d,\"unstaged\":%d,",
                esc($2), esc($3), $4, $5
            printf "\"untracked\":%d,\"ahead\":%d,\"behind\":%d,\"stash\":%d,",
                $6, $7, $8, $9
            printf "\"last_commit_epoch\":%d,\"last_commit\":\"%s\",\"worktrees\":%d,",
                $10, esc($11), $12
            printf "\"notes\":\"%s\",\"score\":%d}", esc($13), $1
        }
        END { print ""; print "]" }
    ' "$FILTERED"
    exit "$EX_OK"
fi

SHOWN="$(grep -c . "$FILTERED" || true)"

if [ "$SHOWN" -eq 0 ]; then
    ok "nothing matched (scanned $REPO_COUNT repositories)"
    exit "$EX_OK"
fi

# Fit the two variable-width columns to the terminal, capped so one long
# worktree path cannot push NOTES off the screen.
NAME_W="$(awk -F"$TAB" '{ if (length($2) > m) m = length($2) } END { print m + 0 }' "$FILTERED")"
BRANCH_W="$(awk -F"$TAB" '{ if (length($3) > m) m = length($3) } END { print m + 0 }' "$FILTERED")"
[ "$NAME_W" -lt 4 ] && NAME_W=4
[ "$NAME_W" -gt 32 ] && NAME_W=32
[ "$BRANCH_W" -lt 6 ] && BRANCH_W=6
[ "$BRANCH_W" -gt 16 ] && BRANCH_W=16

NOTE_W=$((TERM_COLS - NAME_W - BRANCH_W - 31))
[ "$NOTE_W" -lt 10 ] && NOTE_W=10

emit_table() {
    printf "%-${NAME_W}.${NAME_W}s  %-${BRANCH_W}.${BRANCH_W}s %5s %6s %6s %6s  %s\n" \
        REPO BRANCH DIRTY AHEAD STASH LAST NOTES

    local score name branch staged unstaged untracked ahead behind stash
    local last_epoch last_rel worktrees notes dirty color
    while IFS="$TAB" read -r score name branch staged unstaged untracked ahead behind stash last_epoch last_rel worktrees notes; do
        dirty=$((staged + unstaged + untracked))

        color="$NC"
        if [ "$ahead" -gt 0 ] || [ "$stash" -gt 0 ]; then
            color="$YELLOW"
        elif [ "$dirty" -gt 0 ]; then
            color="$BLUE"
        fi
        [ "$score" -ge 40 ] && color="$RED"

        printf "%b%-${NAME_W}.${NAME_W}s%b  %-${BRANCH_W}.${BRANCH_W}s %5s %6s %6s %6s  %.${NOTE_W}s\n" \
            "$color" "$name" "$NC" "$branch" "$dirty" "$ahead" "$stash" "$last_rel" "$notes"
    done <"$FILTERED"
}

# Piping into head closes stdout early; that is not an error worth reporting.
emit_table 2>/dev/null || true

printf '\n' 2>/dev/null || exit "$EX_OK"
info "$SHOWN of $REPO_COUNT repositories shown. Sorted by risk: unpushed, then stashed, then dirty."
[ "$DO_FETCH" -eq 0 ] && printf '%bAHEAD is measured against the last fetch. Use --fetch to refresh.%b\n' "$DIM" "$NC"

exit "$EX_OK"
