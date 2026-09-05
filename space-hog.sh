#!/usr/bin/env bash
#
# ============================================================
# space-hog - where the disk actually went
# ============================================================
#
# Runs on: Mac + Pi (bash 3.2 safe)
# Requires: du find
#
# Categorised, age-aware reclaim report. Reports by default and never deletes
# unless you name a category and a minimum age, because "delete everything
# regenerable" is how you lose an afternoon rebuilding caches.
#
# Age is the newer of the directory mtime and the enclosing repository's last
# commit, so a project you touched yesterday is never suggested for cleanup.
#
# On macOS it also reports the two numbers that never appear in `du` output:
# APFS local Time Machine snapshots, which routinely hold tens of gigabytes,
# and purgeable space, which explains the gap between `df` and Finder.
#
# Config file (default ~/.config/space-hog.conf, mode 600):
#   ROOTS="$HOME/Desktop/Projects"
#   MIN_REPORT_MB=100
#
# Usage:  space-hog.sh [--top N] [--json]
#         space-hog.sh --delete node_modules --older-than 90 [--yes]
# ============================================================

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

TAB="$(printf '\t')"
NOW="$(date +%s)"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

load_config space-hog

ROOTS="${ROOTS:-$HOME/Desktop/Projects}"
MIN_REPORT_MB="${MIN_REPORT_MB:-50}"

TOP=0
AS_JSON=0
DELETE_CAT=''
OLDER_THAN=''
ASSUME_YES=0

usage() {
    cat <<'EOF'
Categorised, age-aware disk reclaim report.

Usage: space-hog.sh [options]

  --top N              Also list the N largest individual paths.
  --delete CATEGORY    Delete entries in CATEGORY. Requires --older-than.
  --older-than N       Only touch entries untouched for N days.
  --yes                Skip the confirmation prompt.
  --json               Machine-readable output.
  --root DIR           Project directory to scan (repeatable).
  -h, --help           Show this help.

Only categories marked safe can be deleted. Run without --delete to see them.
EOF
}

ROOT_OVERRIDE=''
while [ $# -gt 0 ]; do
    case "$1" in
        --top)
            TOP="${2:?--top needs a value}"
            shift 2
            ;;
        --delete)
            DELETE_CAT="${2:?--delete needs a category}"
            shift 2
            ;;
        --older-than)
            OLDER_THAN="${2:?--older-than needs a value}"
            shift 2
            ;;
        --root)
            ROOT_OVERRIDE="$ROOT_OVERRIDE ${2:?--root needs a value}"
            shift 2
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

if [ -n "$DELETE_CAT" ] && [ -z "$OLDER_THAN" ]; then
    die "--delete requires --older-than N, so a project you touched this week is never removed"
fi
case "${OLDER_THAN:-0}" in
    '' | *[!0-9]*) die "--older-than must be a non-negative integer" ;;
esac

require_tools du find

# ------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------

WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
# shellcheck disable=SC2329  # invoked via on_exit
cleanup_workdir() { rm -rf "$WORK_DIR"; }
on_exit cleanup_workdir

ITEMS="$WORK_DIR/items.tsv"
: >"$ITEMS"

# du exits non-zero on a single unreadable entry, and pipefail would turn that
# into a fatal error even though the total it printed is still usable.
dir_kb() { { du -sk -x "$1" 2>/dev/null || true; } | awk 'NR==1 { print $1 + 0 }'; }

# Newer of the directory mtime and the enclosing repo's last commit, so an
# active project is never proposed for deletion.
age_days() {
    local path="$1" parent newest commit
    newest="$(stat_mtime "$path")"
    case "$newest" in
        '' | *[!0-9]*) newest=0 ;;
    esac
    parent="$(dirname "$path")"
    if [ -d "$parent/.git" ] || [ -f "$parent/.git" ]; then
        commit="$({ git -C "$parent" log -1 --format=%ct 2>/dev/null || true; } | head -1)"
        case "$commit" in
            '' | *[!0-9]*) commit=0 ;;
        esac
        [ "$commit" -gt "$newest" ] && newest="$commit"
    fi
    if [ "$newest" -le 0 ]; then
        echo 0
    else
        echo $(((NOW - newest) / 86400))
    fi
}

# record <category> <path> <safe>
record() {
    local cat="$1" path="$2" safe="$3" kb age
    [ -e "$path" ] || return 0
    kb="$(dir_kb "$path")"
    [ -n "$kb" ] || return 0
    [ "$kb" -gt 0 ] || return 0
    age="$(age_days "$path")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$cat" "$kb" "$age" "$safe" "$path" >>"$ITEMS"
}

# ------------------------------------------------------------
# PROJECT SCAN
#
# One find pass with prunes. Scanning for each category separately would
# descend into node_modules once per category.
# ------------------------------------------------------------

scan_projects() {
    local root dir base cat safe count=0
    for root in $ROOTS; do
        [ -d "$root" ] || {
            warn "no such directory: $root"
            continue
        }
        while IFS= read -r dir; do
            [ -n "$dir" ] || continue
            base="$(basename "$dir")"
            safe=1
            case "$base" in
                node_modules)
                    cat=node_modules
                    # Without a lockfile the exact tree is not reproducible.
                    if [ -f "$(dirname "$dir")/package-lock.json" ] ||
                        [ -f "$(dirname "$dir")/pnpm-lock.yaml" ] ||
                        [ -f "$(dirname "$dir")/yarn.lock" ] ||
                        [ -f "$(dirname "$dir")/bun.lockb" ]; then
                        safe=1
                    else
                        safe=0
                    fi
                    ;;
                .venv | venv) cat=python-venv ;;
                __pycache__ | .tox) cat=python-cache ;;
                target)
                    [ -f "$(dirname "$dir")/Cargo.toml" ] || continue
                    cat=rust-target
                    ;;
                .next) cat=next-build ;;
                .expo) cat=expo-cache ;;
                Pods) cat=cocoapods ;;
                *) continue ;;
            esac
            record "$cat" "$dir" "$safe"
            count=$((count + 1))
            render_progress "$count" "$count" 0 0 "scanning $base"
        done <<EOF
$(find "$root" -maxdepth 4 -type d \
            \( -name node_modules -o -name .venv -o -name venv \
            -o -name __pycache__ -o -name .tox -o -name target \
            -o -name .next -o -name .expo -o -name Pods \) \
            -prune -print 2>/dev/null)
EOF
    done
    clear_progress
}

# ------------------------------------------------------------
# FIXED PATHS
# ------------------------------------------------------------

scan_caches() {
    record go-modules "$HOME/go/pkg/mod" 1
    record gradle "$HOME/.gradle/caches" 1
    record npm-cache "$HOME/.npm" 1
    record nuget "$HOME/.nuget" 1
    record cocoapods "$HOME/.cocoapods" 1
    record dotnet "$HOME/.dotnet" 1
    record nvm "$HOME/.nvm" 1
    record rustup "$HOME/.rustup" 1
    record expo-cache "$HOME/.expo" 1
    record degit "$HOME/.degit" 1
    record deno "$HOME/.deno" 1
    record gem "$HOME/.gem" 1
    record ollama "$HOME/.ollama" 0
    record docker-data "$HOME/.docker" 0

    # Android emulator images are several gigabytes each and hold device state.
    if [ -d "$HOME/.android/avd" ]; then
        record android-avd "$HOME/.android/avd" 0
    fi

    if is_macos; then
        record xcode-derived "$HOME/Library/Developer/Xcode/DerivedData" 1
        record ios-devicesupport "$HOME/Library/Developer/Xcode/iOS DeviceSupport" 1
        record xcode-archives "$HOME/Library/Developer/Xcode/Archives" 0
        record simulators "$HOME/Library/Developer/CoreSimulator/Devices" 0
        record trash "$HOME/.Trash" 1
    fi

    record downloads "$HOME/Downloads" 0
}

scan_docker() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0

    # RECLAIMABLE is what a prune would actually return.
    { docker system df 2>/dev/null || true; } |
        awk -F'  +' 'NR > 1 && NF >= 4 { print $1 "\t" $NF }' |
        while IFS="$TAB" read -r type reclaim; do
            [ -n "$type" ] || continue
            kb="$(printf '%s' "$reclaim" | awk '
                {
                    n = $0
                    sub(/ *\(.*/, "", n)
                    unit = n
                    gsub(/[0-9.]/, "", unit)
                    gsub(/[^0-9.]/, "", n)
                    m = 0
                    if (unit ~ /^kB|^KB/) m = 1
                    else if (unit ~ /^MB/) m = 1024
                    else if (unit ~ /^GB/) m = 1024 * 1024
                    else if (unit ~ /^TB/) m = 1024 * 1024 * 1024
                    else if (unit ~ /^B/) m = 0.001
                    printf "%d", n * m
                }')"
            [ -n "$kb" ] && [ "$kb" -gt 0 ] || continue
            printf 'docker-%s\t%s\t%s\t%s\t%s\n' \
                "$(printf '%s' "$type" | tr 'A-Z ' 'a-z-')" "$kb" 0 1 "docker ($type)" >>"$ITEMS"
        done
}

# ------------------------------------------------------------
# DELETE
# ------------------------------------------------------------

do_delete() {
    local targets="$WORK_DIR/targets.tsv" count total path kb age safe cat
    awk -F"$TAB" -v c="$DELETE_CAT" -v a="$OLDER_THAN" \
        '$1 == c && $4 == 1 && $3 >= a' "$ITEMS" >"$targets"

    count="$(grep -c . "$targets" || true)"
    if [ "$count" -eq 0 ]; then
        if ! awk -F"$TAB" -v c="$DELETE_CAT" '$1 == c { found = 1 } END { exit !found }' "$ITEMS"; then
            die "unknown category: $DELETE_CAT"
        fi
        ok "nothing in $DELETE_CAT is both safe to delete and older than $OLDER_THAN days"
        exit "$EX_OK"
    fi

    total="$(awk -F"$TAB" '{ s += $2 } END { print s + 0 }' "$targets")"

    section "Would delete $count entr(ies) from $DELETE_CAT, freeing $(human_bytes $((total * 1024)))"
    while IFS="$TAB" read -r cat kb age safe path; do
        printf '  %10s  %4sd  %s\n' "$(human_bytes $((kb * 1024)))" "$age" "$path"
    done <"$targets"

    if [ "$ASSUME_YES" -eq 0 ]; then
        printf '\n'
        printf 'Type %bdelete%b to confirm: ' "$YELLOW" "$NC"
        read -r reply
        [ "$reply" = delete ] || die "aborted"
    fi

    while IFS="$TAB" read -r cat kb age safe path; do
        case "$path" in
            "$HOME" | / | "$HOME/") die "refusing to delete $path" ;;
        esac
        if rm -rf -- "$path"; then
            ok "removed $path"
        else
            warn "could not remove $path"
        fi
    done <"$targets"

    ok "freed roughly $(human_bytes $((total * 1024)))"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

# info writes to stdout, which would corrupt --json output.
[ "$AS_JSON" -eq 1 ] || info "scanning..."
scan_projects
scan_caches
scan_docker

[ -s "$ITEMS" ] || die "found nothing to report"

if [ -n "$DELETE_CAT" ]; then
    do_delete
    exit "$EX_OK"
fi

SUMMARY="$WORK_DIR/summary.tsv"
awk -F"$TAB" '
    {
        kb[$1] += $2
        n[$1]++
        if ($3 > oldest[$1]) oldest[$1] = $3
        if ($4 == 1) safe_kb[$1] += $2
    }
    END {
        for (c in kb)
            printf "%d\t%s\t%d\t%d\t%d\n", kb[c], c, n[c], safe_kb[c] + 0, oldest[c] + 0
    }
' "$ITEMS" | sort -t"$TAB" -k1,1nr >"$SUMMARY"

if [ "$AS_JSON" -eq 1 ]; then
    awk -F"$TAB" '
        BEGIN { print "["; first = 1 }
        {
            if (!first) print ","
            first = 0
            printf "  {\"category\":\"%s\",\"items\":%d,\"size_kb\":%d,\"reclaimable_kb\":%d,\"oldest_days\":%d}",
                $2, $3, $1, $4, $5
        }
        END { print ""; print "]" }
    ' "$SUMMARY"
    exit "$EX_OK"
fi

DISK_KB="$({ df -k "$HOME" 2>/dev/null || true; } | awk 'NR==2 { print $2 + 0 }')"
[ -n "$DISK_KB" ] || DISK_KB=0

section "Reclaim report"
printf '%-20s %6s %12s %12s %8s\n' CATEGORY ITEMS SIZE RECLAIMABLE OLDEST
TOTAL_KB=0
SAFE_KB=0
while IFS="$TAB" read -r kb cat n safe oldest; do
    TOTAL_KB=$((TOTAL_KB + kb))
    SAFE_KB=$((SAFE_KB + safe))
    [ $((kb / 1024)) -ge "$MIN_REPORT_MB" ] || continue
    if [ "$safe" -eq 0 ]; then
        printf '%-20s %6s %12s %12s %7sd\n' \
            "$cat" "$n" "$(human_bytes $((kb * 1024)))" "-" "$oldest"
    else
        printf '%-20s %6s %12s %b%12s%b %7sd\n' \
            "$cat" "$n" "$(human_bytes $((kb * 1024)))" \
            "$GREEN" "$(human_bytes $((safe * 1024)))" "$NC" "$oldest"
    fi
done <"$SUMMARY"

printf '%-20s %6s %12s %12s\n' '' '' '------------' '------------'
printf '%-20s %6s %12s %b%12s%b\n' TOTAL '' \
    "$(human_bytes $((TOTAL_KB * 1024)))" "$GREEN" "$(human_bytes $((SAFE_KB * 1024)))" "$NC"

if [ "$DISK_KB" -gt 0 ]; then
    printf '\n%s of the volume, %s of it reclaimable.\n' \
        "$(awk -v a="$TOTAL_KB" -v b="$DISK_KB" 'BEGIN { printf "%.1f%%", a / b * 100 }')" \
        "$(awk -v a="$SAFE_KB" -v b="$DISK_KB" 'BEGIN { printf "%.1f%%", a / b * 100 }')"
fi

if [ "$TOP" -gt 0 ]; then
    section "Largest $TOP paths"
    sort -t"$TAB" -k2,2nr "$ITEMS" | head -"$TOP" |
        while IFS="$TAB" read -r cat kb age safe path; do
            printf '%10s  %4sd  %-16s %s\n' \
                "$(human_bytes $((kb * 1024)))" "$age" "$cat" "$path"
        done
fi

# ------------------------------------------------------------
# THE INVISIBLE NUMBERS
#
# Neither of these appears in du output, and local snapshots in particular are
# usually the largest single surprise on a Mac.
# ------------------------------------------------------------

if is_macos; then
    snaps="$({ tmutil listlocalsnapshots / 2>/dev/null || true; } | grep -c 'com.apple.TimeMachine' || true)"
    purge="$({ diskutil info / 2>/dev/null || true; } | awk -F': *' '/Purgeable Space/ { print $2; exit }')"
    # Newer macOS drops the Purgeable line; container free space is the next
    # best answer for "why does df disagree with Finder".
    [ -n "$purge" ] || purge="$({ diskutil info / 2>/dev/null || true; } |
        awk -F': *' '/Container Free Space/ { sub(/ \(.*/, "", $2); print $2; exit }')"

    section "Not visible to du"
    if [ "$snaps" -gt 0 ]; then
        kv "APFS local snapshots" "$snaps (thin with: tmutil thinlocalsnapshots / 10000000000 4)"
    else
        kv "APFS local snapshots" "none"
    fi
    [ -n "$purge" ] && kv "Free (container)" "$purge"
fi

printf '\n'
info "Nothing was deleted. Use --delete CATEGORY --older-than N to reclaim."

exit "$EX_OK"
