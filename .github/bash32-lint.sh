#!/usr/bin/env bash
#
# ============================================================
# bash 3.2 compatibility lint
# ============================================================
#
# Runs on: Mac + Pi (bash 3.2 safe)
#
# GitHub runners and the Pi both ship bash 5, so `bash -n` happily accepts
# constructs that blow up on the macOS system bash. This grep pass covers the
# ones that actually bite.
#
# Only files whose banner says "3.2 safe" are checked. Put
# `# bash32-lint: allow` on a line to exempt it, which is what the portability
# shims in lib/common.sh do since they call the GNU form behind a guard.
#
# Usage:  .github/bash32-lint.sh [files...]     (defaults to every *.sh)
# ============================================================

set -uo pipefail

RED='' GREEN='' NC=''
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
fi

TAB="$(printf '\t')"

# pattern<TAB>explanation
RULES="\
declare[[:space:]]+-A|local[[:space:]]+-A${TAB}associative arrays are bash 4
mapfile|readarray${TAB}mapfile and readarray are bash 4
\\\$\\{[A-Za-z_][A-Za-z0-9_]*(\\[[^]]*\\])?[,^]${TAB}case-modifying expansion is bash 4
\\\$\\{[A-Za-z_][A-Za-z0-9_]*\\[-[0-9]${TAB}negative array index is bash 4.3
&>>${TAB}append-both-streams is bash 4
;;&${TAB}case fallthrough is bash 4
readlink[[:space:]]+-f${TAB}readlink -f is GNU only, use _realpath
(^|[^[:alnum:]_])date[[:space:]]+-d[[:space:]]${TAB}date -d is GNU only, use date_days_ago
(^|[^[:alnum:]_])stat[[:space:]]+-c[[:space:]]${TAB}stat -c is GNU only, use stat_size or stat_mode
sed[[:space:]]+-i[[:space:]]+-[^[:space:]]${TAB}sed -i without an argument is GNU only, use sed_inplace
shopt[[:space:]]+-s[[:space:]]+globstar${TAB}globstar is bash 4
exec[[:space:]]+\\{[a-z_]+\\}${TAB}named file descriptors are bash 4.1"

if [ $# -gt 0 ]; then
    FILES="$*"
else
    FILES="$(find . -name '*.sh' -not -path './.git/*' | sort)"
fi

FINDINGS="$(mktemp)"
trap 'rm -f "$FINDINGS"' EXIT

checked=0
for file in $FILES; do
    [ -f "$file" ] || continue
    # This file's rules table is made of the patterns it looks for.
    case "$file" in
        *bash32-lint.sh) continue ;;
    esac
    grep -qi '3\.2 safe' "$file" || continue
    checked=$((checked + 1))

    while IFS="$TAB" read -r pattern reason; do
        [ -n "$pattern" ] || continue
        grep -nE -- "$pattern" "$file" 2>/dev/null |
            grep -v 'bash32-lint: allow' |
            sed "s|^|${file}:|; s|\$|${TAB}${reason}|" >>"$FINDINGS"
    done <<EOF
$RULES
EOF
done

if [ -s "$FINDINGS" ]; then
    while IFS="$TAB" read -r hit reason; do
        printf '%b%s%b\n' "$RED" "$hit" "$NC"
        printf '    %s\n' "$reason"
    done <"$FINDINGS"
    printf '\n%bbash 3.2 lint failed%b (%s finding(s))\n' \
        "$RED" "$NC" "$(wc -l <"$FINDINGS" | tr -d ' ')"
    exit 1
fi

printf '%bbash 3.2 lint clean%b (%d file(s) checked)\n' "$GREEN" "$NC" "$checked"
