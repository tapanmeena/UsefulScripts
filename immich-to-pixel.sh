#!/usr/bin/env bash
#
# ============================================================
# Immich -> Pixel -> Google Photos
# ============================================================
#
# Copies assets newly added to Immich (for the user owning the API key) onto a
# Pixel over adb, into a folder that Google Photos is configured to back up.
#
# Work proceeds in batches: push BATCH_SIZE files, register them with MediaStore
# so Google Photos starts uploading, then continue. An asset is only recorded as
# done once it has been indexed, and files awaiting indexing are never pruned.
#
# Runs on: Pi (bash 5)
# Requires: curl jq adb
#
# Host requirements:  bash, curl, jq, adb
#
# One-time phone setup:
#   1. Enable wireless debugging and pair:   adb pair <ip>:<pairing-port>
#   2. Pin a stable port (survives until reboot, needs USB once):
#        adb -d tcpip 5555
#   3. Google Photos -> Backup -> Back up device folders -> enable "ImmichSync"
#   4. Settings -> Apps -> Google Photos -> Battery -> Unrestricted
#   5. Keep the phone on Wi-Fi and charging.
#
# Config file (default ~/.config/immich-to-pixel.conf, mode 600):
#   IMMICH_URL="http://localhost:2283"
#   IMMICH_API_KEY="..."
#   PIXEL_ADDR="192.168.1.50:5555"
#
# Values in the config file take precedence over environment variables.
#
# Usage:  immich-to-pixel.sh [--dry-run] [--limit N] [--since ISO8601]
#                            [--batch N] [--scan-volume] [--debug] [--config PATH]

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

usage() {
    cat <<'EOF'
Copy assets newly added to Immich onto a Pixel over adb, into a folder that
Google Photos is configured to back up.

Usage: immich-to-pixel.sh [options]

  --dry-run        List what would be transferred; change nothing.
  --limit N        Stop after N assets. Useful for the first backlog run.
  --since ISO8601  Ignore the saved cursor and start from this timestamp.
  --batch N        Push N files, then index them, then continue (default 50).
  --scan-volume    Trigger one full MediaStore volume scan per batch instead of
                   scanning each pushed file individually.
  --debug          Emit verbose trace output for script execution.
  --config PATH    Config file (default ~/.config/immich-to-pixel.conf).
  -h, --help       Show this help.

Settings (config file wins over environment):
  IMMICH_URL, IMMICH_API_KEY, PIXEL_ADDR, REMOTE_DIR, STATE_DIR,
  KEEP_DAYS, MIN_FREE_MB, PAGE_SIZE, BATCH_SIZE
EOF
}

# ------------------------------------------------------------
# ARGUMENTS
# ------------------------------------------------------------

CONFIG_FILE="${IMMICH_TO_PIXEL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/immich-to-pixel.conf}"
DRY_RUN=0
LIMIT=0
BATCH_OVERRIDE=""
SCAN_VOLUME=0
SINCE_OVERRIDE=""
VERBOSE="${VERBOSE:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --scan-volume)
            SCAN_VOLUME=1
            shift
            ;;
        --debug)
            VERBOSE=1
            shift
            ;;
        --limit)
            LIMIT="${2:?--limit needs a value}"
            shift 2
            ;;
        --batch)
            BATCH_OVERRIDE="${2:?--batch needs a value}"
            shift 2
            ;;
        --since)
            SINCE_OVERRIDE="${2:?--since needs a value}"
            shift 2
            ;;
        --config)
            CONFIG_FILE="${2:?--config needs a value}"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

case "$LIMIT" in
    '' | *[!0-9]*) die "--limit must be a non-negative integer" ;;
esac

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

if [ "$VERBOSE" = "1" ] || [ "$VERBOSE" = "true" ]; then
    export VERBOSE=1
else
    export VERBOSE=""
fi

debug "using config: $CONFIG_FILE"

IMMICH_URL="${IMMICH_URL:-http://localhost:2283}"
IMMICH_API_KEY="${IMMICH_API_KEY:-}"
PIXEL_ADDR="${PIXEL_ADDR:-}"
REMOTE_DIR="${REMOTE_DIR:-/sdcard/DCIM/ImmichSync}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-to-pixel}"
KEEP_DAYS="${KEEP_DAYS:-7}"
MIN_FREE_MB="${MIN_FREE_MB:-8192}"
PAGE_SIZE="${PAGE_SIZE:-500}"
BATCH_SIZE="${BATCH_SIZE:-50}"
[ -n "$BATCH_OVERRIDE" ] && BATCH_SIZE="$BATCH_OVERRIDE"

case "$BATCH_SIZE" in
    '' | *[!0-9]* | 0) die "BATCH_SIZE must be a positive integer" ;;
esac

# adb shell re-splits the command on the device, so an unquoted path with
# whitespace would break every remote loop.
case "$REMOTE_DIR" in
    *[[:space:]]*) die "REMOTE_DIR must not contain whitespace: $REMOTE_DIR" ;;
esac

# Paths sent per adb shell invocation, to stay well inside the device's
# argument length limit.
SCAN_CHUNK=100

IMMICH_URL="${IMMICH_URL%/}"

[ -n "$IMMICH_API_KEY" ] || die "IMMICH_API_KEY is not set. Create $CONFIG_FILE (mode 600) containing:
  IMMICH_URL=\"http://localhost:2283\"
  IMMICH_API_KEY=\"<key from Immich > Account Settings > API Keys>\"
  PIXEL_ADDR=\"192.168.1.6:41653\""

for tool in curl jq adb; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# ------------------------------------------------------------
# STATE
# ------------------------------------------------------------

mkdir -p "$STATE_DIR"

# Two overlapping runs would interleave their writes to the cursor file and
# silently skip whatever the loser had already transferred.
if ! acquire_lock immich-to-pixel; then
    warn "another copy is already running"
    exit "$EX_LOCKED"
fi

CURSOR_FILE="$STATE_DIR/cursor"
PUSHED_FILE="$STATE_DIR/pushed.txt"
touch "$PUSHED_FILE"

if [ -n "$SINCE_OVERRIDE" ]; then
    cursor="$SINCE_OVERRIDE"
elif [ -s "$CURSOR_FILE" ]; then
    cursor="$(cat "$CURSOR_FILE")"
else
    cursor="1970-01-01T00:00:00.000Z"
fi

new_cursor="$cursor"

WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"

# Remote filenames pushed but not yet indexed. Google Photos has had no chance
# to see these, so pruning must leave them alone.
PROTECT_FILE="$WORK_DIR/protect.txt"
: >"$PROTECT_FILE"
declare -a batch_names=()
declare -a batch_ids=()
batch_cursor=""

finish() {
    local rc=$?
    if [ "$DRY_RUN" -eq 0 ] && [ "$new_cursor" != "$cursor" ]; then
        printf '%s\n' "$new_cursor" >"$CURSOR_FILE" || true
    fi
    rm -rf "$WORK_DIR" || true
    return $rc
}
on_exit finish

# ------------------------------------------------------------
# IMMICH API
# ------------------------------------------------------------

# Keep the API key out of the process table.
CURL_CFG="$WORK_DIR/curl.cfg"
(
    umask 077
    printf 'header = "x-api-key: %s"\n' "$IMMICH_API_KEY" >"$CURL_CFG"
)

api_get() { curl -sS -f -K "$CURL_CFG" "$IMMICH_URL/api$1"; }
api_post() {
    curl -sS -f -K "$CURL_CFG" -H 'Content-Type: application/json' \
        --data-binary "$2" "$IMMICH_URL/api$1"
}

me_json="$(api_get /users/me 2>/dev/null || api_get /user/me 2>/dev/null || true)"
[ -n "$me_json" ] || die "cannot authenticate to Immich at $IMMICH_URL (check URL and API key)"
immich_user="$(jq -r '.email // .name // "unknown"' <<<"$me_json")"

# ------------------------------------------------------------
# TRANSPORT (adb)
#
# Everything the phone touches goes through these five functions, so swapping
# adb for Termux+rsync later means rewriting only this block.
# ------------------------------------------------------------

declare -a ADB=()

# Every adb call gets </dev/null. `adb shell` forwards stdin to the remote
# command, so without this it drains whatever fd 0 happens to be - including the
# queue being read by the transfer loop.
transport_connect() {
    if [ -z "$PIXEL_ADDR" ]; then
        PIXEL_ADDR="$(adb mdns services 2>/dev/null 9>&- </dev/null |
            awk '/_adb-tls-connect/ { print $3; exit }')"
        [ -n "$PIXEL_ADDR" ] ||
            die "no PIXEL_ADDR set and mDNS discovery found no adb-tls-connect service"
        info "discovered device at $PIXEL_ADDR"
    fi

    adb connect "$PIXEL_ADDR" >/dev/null 2>&1 9>&- </dev/null || true
    ADB=(adb -s "$PIXEL_ADDR")

    local state
    state="$("${ADB[@]}" get-state 2>/dev/null 9>&- </dev/null || true)"
    [ "$state" = "device" ] ||
        die "device $PIXEL_ADDR is not available (state: ${state:-offline}). Re-pair wireless debugging, or run 'adb -d tcpip 5555' over USB to pin the port."
}

transport_push() {
    "${ADB[@]}" push "$1" "$REMOTE_DIR/$2" >/dev/null 9>&- </dev/null
}

# Scan a batch of files in one adb round trip. The device-side loop echoes one
# line per file so the host can still drive a progress bar. Remote names are
# sanitised to [A-Za-z0-9._-] at push time, so they need no quoting here.
transport_scan_batch() {
    local cmd='for f in' name
    for name in "$@"; do
        cmd="$cmd $REMOTE_DIR/$name"
    done
    cmd="$cmd; do content call --uri content://media --method scan_file"
    cmd="$cmd --arg \$f >/dev/null 2>&1 && echo Y || echo N; done"

    "${ADB[@]}" shell "$cmd" 2>/dev/null 9>&- </dev/null | tr -d '\r'
}

transport_scan_volume() {
    "${ADB[@]}" shell content call --uri content://media \
        --method scan_volume --arg external_primary >/dev/null 2>&1 9>&- </dev/null
}

# Available space on the shared volume, in KiB. Empty if unparseable.
transport_free_kb() {
    "${ADB[@]}" shell df -k "$REMOTE_DIR" 2>/dev/null 9>&- </dev/null |
        awk 'NR==2 && $4 ~ /^[0-9]+$/ { print $4 }'
}

transport_list_oldest_first() {
    "${ADB[@]}" shell ls -t "$REMOTE_DIR" 2>/dev/null 9>&- </dev/null |
        tr -d '\r' | sed '/^$/d' |
        awk '{ line[NR] = $0 } END { for (i = NR; i >= 1; i--) print line[i] }'
}

transport_delete() {
    [ $# -gt 0 ] || return 0
    printf '%s\n' "$@" | sed "s|^|$REMOTE_DIR/|" |
        xargs -n 40 "${ADB[@]}" shell rm -f >/dev/null 2>&1 9>&- || true
}

# ------------------------------------------------------------
# SPACE MANAGEMENT
#
# Files pushed here are copies; Immich still holds the originals, so the worst
# case for over-pruning is a missed upload that a later run re-pushes.
#
# FREE_KB caches the device's free space so the common case costs no adb round
# trip. -1 means "unreadable", in which case space logic is bypassed and pushes
# are simply attempted.
# ------------------------------------------------------------

FREE_KB=-1

refresh_free() {
    local v
    v="$(transport_free_kb)"
    if [ -n "$v" ]; then FREE_KB="$v"; else FREE_KB=-1; fi
}

file_size_kb() {
    local bytes
    bytes="$(stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0)"
    echo $(((bytes + 1023) / 1024))
}

write_protect_file() {
    : >"$PROTECT_FILE"
    if [ "${#batch_names[@]}" -gt 0 ]; then
        printf '%s\n' "${batch_names[@]}" >"$PROTECT_FILE"
    fi
}

# Drop protected names from a newline-separated list. Keyed on FILENAME because
# NR==FNR misfires when the protect file is empty.
filter_protected() {
    awk -v pf="$PROTECT_FILE" '
        FILENAME == pf { protected[$0] = 1; next }
        !($0 in protected)
    ' "$PROTECT_FILE" "$1"
}

# prune_remote [extra_kb] - free space until MIN_FREE_MB + extra_kb is available.
prune_remote() {
    local need_kb="${1:-0}"
    local deleted=0
    local target_kb=$((MIN_FREE_MB * 1024 + need_kb))
    local raw="$WORK_DIR/prune.raw"

    write_protect_file

    "${ADB[@]}" shell find "$REMOTE_DIR" -type f -mtime "+$KEEP_DAYS" 2>/dev/null 9>&- </dev/null |
        tr -d '\r' | sed "s|^$REMOTE_DIR/||" | sed '/^$/d' >"$raw" || true

    local -a stale=()
    while read -r name; do
        [ -n "$name" ] && stale+=("$name")
    done < <(filter_protected "$raw")

    if [ "${#stale[@]}" -gt 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "would prune ${#stale[@]} file(s) older than $KEEP_DAYS days"
        else
            transport_delete "${stale[@]}"
            deleted=$((deleted + ${#stale[@]}))
        fi
    fi

    refresh_free
    if [ "$FREE_KB" -lt 0 ]; then
        warn "could not read free space on the device; skipping space-based pruning"
        [ "$deleted" -gt 0 ] && info "pruned $deleted file(s)"
        return 0
    fi

    if [ "$FREE_KB" -lt "$target_kb" ]; then
        # Oldest indexed file first: it has had the longest to upload.
        transport_list_oldest_first >"$raw"
        local -a oldest=()
        while read -r name; do
            [ -n "$name" ] && oldest+=("$name")
        done < <(filter_protected "$raw")

        local i=0
        while [ "$FREE_KB" -lt "$target_kb" ] && [ "$i" -lt "${#oldest[@]}" ]; do
            local -a batch=("${oldest[@]:i:40}")
            if [ "$DRY_RUN" -eq 1 ]; then
                info "would prune ${#batch[@]} oldest file(s) to reclaim space"
                break
            fi
            transport_delete "${batch[@]}"
            deleted=$((deleted + ${#batch[@]}))
            i=$((i + 40))
            refresh_free
            [ "$FREE_KB" -lt 0 ] && break
        done
    fi

    [ "$deleted" -gt 0 ] && info "pruned $deleted file(s)"
    return 0
}

# Reserve room for a file of the given size, pruning if necessary.
# Returns non-zero when the device still cannot fit it.
ensure_space() {
    local need_kb="$1"
    local target_kb=$((MIN_FREE_MB * 1024 + need_kb))

    if [ "$FREE_KB" -lt 0 ] || [ "$FREE_KB" -ge "$target_kb" ]; then
        return 0
    fi

    # The cache says we are short; confirm against the device before deleting.
    refresh_free
    if [ "$FREE_KB" -lt 0 ] || [ "$FREE_KB" -ge "$target_kb" ]; then
        return 0
    fi

    prune_remote "$need_kb"
    if [ "$FREE_KB" -lt 0 ]; then
        return 0
    fi
    [ "$FREE_KB" -ge "$target_kb" ]
}

# ------------------------------------------------------------
# COLLECT NEW ASSETS
# ------------------------------------------------------------

info "Immich  $IMMICH_URL  (user: $immich_user)"
info "Cursor  $cursor"
debug "remote dir: $REMOTE_DIR"
debug "state dir: $STATE_DIR"
debug "batch size: $BATCH_SIZE"
[ "$SCAN_VOLUME" -eq 1 ] && debug "full MediaStore volume scan enabled"

PENDING="$WORK_DIR/pending.tsv"
: >"$PENDING"

page=1
while :; do
    body="$(jq -nc \
        --arg after "$cursor" \
        --argjson size "$PAGE_SIZE" \
        --argjson page "$page" \
        '{updatedAfter: $after, size: $size, page: $page}')"

    resp="$(api_post /search/metadata "$body")" ||
        die "search request failed (is this Immich v1.94 or newer?)"

    # "-" stands in for a missing path so no field is ever empty; bash collapses
    # runs of tab when splitting, which would otherwise shift columns.
    jq -r '
        .assets.items[]
        | select(.type == "IMAGE" or .type == "VIDEO")
        | [ .id,
            .updatedAt,
            (if (.originalPath // "") == "" then "-" else .originalPath end),
            (if (.originalFileName // "") == "" then "unnamed" else .originalFileName end)
          ]
        | @tsv
    ' <<<"$resp" >>"$PENDING"

    next="$(jq -r '.assets.nextPage // empty' <<<"$resp")"
    [ -n "$next" ] || break
    page="$next"
done

# Ascending updatedAt so the cursor only ever advances past finished work.
sort -t$'\t' -k2,2 -o "$PENDING" "$PENDING"

total="$(wc -l <"$PENDING" | tr -d ' ')"
if [ "$total" -eq 0 ]; then
    ok "nothing new"
    exit 0
fi
info "Found   $total asset(s) updated since the cursor"

# Mark assets already sent in a previous run rather than dropping them, so the
# cursor can still advance past them. Keyed on FILENAME rather than NR==FNR,
# which misfires when pushed.txt is empty.
QUEUE="$WORK_DIR/queue.tsv"
awk -F'\t' -v pushed="$PUSHED_FILE" '
    FILENAME == pushed { seen[$1] = 1; next }
    { print (($1 in seen) ? "skip" : "send") "\t" $0 }
' "$PUSHED_FILE" "$PENDING" >"$QUEUE"

# ------------------------------------------------------------
# TRANSFER
# ------------------------------------------------------------

transport_connect
debug "ADB connection ready: ${PIXEL_ADDR}"

if [ "$DRY_RUN" -eq 0 ]; then
    "${ADB[@]}" shell mkdir -p "$REMOTE_DIR" >/dev/null 2>&1 9>&- </dev/null ||
        die "could not create $REMOTE_DIR on the device"
fi

pushed=0
indexed=0
skipped=0
failed=0
processed=0
cursor_frozen=0
device_full=0
sent_kb=0
start_time=$SECONDS

prune_remote

debug "pending send count: $(awk -F'\t' '$1 == "send"' "$QUEUE" | wc -l | tr -d ' ')"

# Denominator for the progress bar: rows that will actually be transferred.
if [ "$LIMIT" -gt 0 ]; then
    to_send="$(head -n "$LIMIT" "$QUEUE" | awk -F'\t' '$1 == "send"' | wc -l | tr -d ' ')"
else
    to_send="$(awk -F'\t' '$1 == "send"' "$QUEUE" | wc -l | tr -d ' ')"
fi

# Advance the cursor only while nothing has failed. A later success must never
# carry the cursor past an asset that did not make it, or that asset is lost.
advance_cursor() {
    if [ "$cursor_frozen" -eq 0 ]; then
        new_cursor="$1"
    fi
}

# Index the pending batch, then commit it. Recording assets before they are
# indexed would let an interrupted run mark work complete that Google Photos
# never saw, and those assets would never be retried.
flush_batch() {
    [ "${#batch_names[@]}" -gt 0 ] || return 0

    local total="${#batch_names[@]}"
    local failures=0 done_n=0 t0=$SECONDS i=0 verdict

    if [ "$SCAN_VOLUME" -eq 1 ]; then
        render_progress 0 "$total" 0 0 "indexing $total file(s)"
        transport_scan_volume || failures="$total"
    else
        while [ "$i" -lt "$total" ]; do
            while read -r verdict <&3; do
                if [ "$done_n" -lt "$total" ]; then
                    [ "$verdict" = "N" ] && failures=$((failures + 1))
                    render_progress "$done_n" "$total" 0 $((SECONDS - t0)) \
                        "indexing ${batch_names[done_n]#*_}"
                fi
                done_n=$((done_n + 1))
            done 3< <(transport_scan_batch "${batch_names[@]:i:SCAN_CHUNK}")
            i=$((i + SCAN_CHUNK))
        done
        # Fewer replies than files means the remote shell died partway through.
        [ "$done_n" -lt "$total" ] && failures=$((failures + total - done_n))
    fi

    if [ "$failures" -gt 0 ]; then
        warn "$failures scan(s) failed; falling back to a volume scan"
        if ! transport_scan_volume; then
            warn "volume scan failed too - leaving this batch uncommitted so it retries next run"
            cursor_frozen=1
            return 1
        fi
    fi

    printf '%s\n' "${batch_ids[@]}" >>"$PUSHED_FILE"
    advance_cursor "$batch_cursor"
    indexed=$((indexed + total))
    batch_names=()
    batch_ids=()
    return 0
}

# Read on fd 3, never stdin: a subprocess that drains fd 0 would silently
# truncate the run.
while IFS=$'\t' read -r state id updated_at orig_path orig_name <&3; do
    [ -n "$id" ] || continue

    if [ "$LIMIT" -gt 0 ] && [ "$processed" -ge "$LIMIT" ]; then
        info "reached --limit $LIMIT; remaining assets will be picked up next run"
        break
    fi

    if [ "$state" = "skip" ]; then
        skipped=$((skipped + 1))
        processed=$((processed + 1))
        # With a batch outstanding, this timestamp is ahead of uncommitted work,
        # so it has to be committed by the flush rather than immediately.
        if [ "${#batch_names[@]}" -eq 0 ]; then
            advance_cursor "$updated_at"
        else
            batch_cursor="$updated_at"
        fi
        continue
    fi

    # UUID prefix guarantees uniqueness; sanitising avoids quoting hazards in
    # every later adb shell command.
    safe_name="$(printf '%s' "$orig_name" | tr -c 'A-Za-z0-9._-' '_')"
    remote_name="${id:0:8}_${safe_name}"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  would push  %s\n' "$remote_name"
        pushed=$((pushed + 1))
        processed=$((processed + 1))
        advance_cursor "$updated_at"
        continue
    fi
    # Drawn before the download so a slow fetch still shows the current file.
    render_progress "$pushed" "$to_send" "$sent_kb" $((SECONDS - start_time)) "${remote_name#*_}"

    # Prefer the local library file; fall back to the API when Immich does not
    # expose originalPath or the path is not readable from here.
    src="$orig_path"
    downloaded=0
    if [ "$src" = "-" ] || [ ! -r "$src" ]; then
        src="$WORK_DIR/download.bin"
        if ! curl -sS -f -K "$CURL_CFG" -o "$src" "$IMMICH_URL/api/assets/$id/original"; then
            warn "download failed: $id ($orig_name)"
            failed=$((failed + 1))
            cursor_frozen=1
            continue
        fi
        downloaded=1
    fi

    need_kb="$(file_size_kb "$src")"
    if ! ensure_space "$need_kb"; then
        # The outstanding batch is protected from pruning. Index it first: that
        # releases it for reuse and is usually enough to continue.
        flush_batch
        if ! ensure_space "$need_kb"; then
            warn "device full: cannot fit $remote_name (needs ${need_kb}KB, ${FREE_KB}KB free, reserving ${MIN_FREE_MB}MB)"
            [ "$downloaded" -eq 1 ] && rm -f "$src"
            cursor_frozen=1
            device_full=1
            break
        fi
    fi

    if transport_push "$src" "$remote_name"; then
        batch_names+=("$remote_name")
        batch_ids+=("$id")
        batch_cursor="$updated_at"
        pushed=$((pushed + 1))
        processed=$((processed + 1))
        if [ "$FREE_KB" -ge 0 ]; then
            FREE_KB=$((FREE_KB - need_kb))
        fi
        sent_kb=$((sent_kb + need_kb))
        if [ "${#batch_names[@]}" -ge "$BATCH_SIZE" ]; then
            flush_batch
        fi
    else
        warn "push failed: $remote_name"
        failed=$((failed + 1))
        cursor_frozen=1
        refresh_free
    fi

    [ "$downloaded" -eq 1 ] && rm -f "$src"
done 3<"$QUEUE"

flush_batch
render_progress "$pushed" "$to_send" "$sent_kb" $((SECONDS - start_time)) "complete"
finish_progress

# ------------------------------------------------------------
# SUMMARY
# ------------------------------------------------------------

printf '\n'
printf '%-12s %s\n' "Pushed" "$pushed"
printf '%-12s %s\n' "Indexed" "$indexed"
printf '%-12s %s\n' "Skipped" "$skipped"
printf '%-12s %s\n' "Failed" "$failed"
printf '%-12s %s\n' "Cursor" "$new_cursor"
if [ "$cursor_frozen" -eq 1 ]; then
    printf '%-12s %s\n' "" "(held back by a failure; those assets retry next run)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n%bdry run - nothing was transferred and the cursor was not advanced%b\n' \
        "$YELLOW" "$NC"
elif [ "$device_full" -eq 1 ]; then
    printf '\n'
    warn "stopped early: device out of space. Let Google Photos finish uploading,
      then re-run. Lower KEEP_DAYS (currently $KEEP_DAYS) to reclaim sooner."
elif [ "$pushed" -gt 0 ]; then
    printf '\n'
    ok "Keep the phone on Wi-Fi and charging; Google Photos uploads on its own schedule."
fi

[ "$failed" -eq 0 ] && [ "$device_full" -eq 0 ]
