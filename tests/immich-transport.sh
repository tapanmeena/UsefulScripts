#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
export HOME="$WORK_DIR/home" XDG_CONFIG_HOME="$WORK_DIR/config"
export IMMICH_TO_PIXEL_CONFIG="$XDG_CONFIG_HOME/immich-to-pixel.conf"
export IMMICH_URL="http://immich.test:2283" IMMICH_API_KEY="test-key"
export REMOTE_DIR="/sdcard/DCIM/ImmichSync"
export KEEP_DAYS=7 MIN_FREE_MB=1 PAGE_SIZE=500
export USB_SERIAL="USBPIXEL123" WIRELESS_ADDR="192.0.2.50:5555"
export MDNS_ADDR="192.0.2.50:37123" DISCOVER_WIRELESS=1
export USB_MODE=device WIRELESS_STATE=device FAIL_PUSH=0
export PIXEL_ADDR="$WIRELESS_ADDR" ASSET_FILE="$WORK_DIR/photo.jpg"
printf 'photo fixture\n' >"$ASSET_FILE"
SYNC_SCRIPT="$REPO_DIR/immich-to-pixel.sh"
ASSET_ID="12345678-1234-1234-1234-123456789abc"
ASSET_TIME="2026-09-01T00:00:00.000Z"

curl() {
    case "${*: -1}" in
        "$IMMICH_URL/api/users/me")
            printf '{"email":"test@example.test"}\n'
            ;;
        "$IMMICH_URL/api/search/metadata")
            jq -nc --arg path "$ASSET_FILE" \
                '{assets: {items: [{id: "12345678-1234-1234-1234-123456789abc",
                    type: "IMAGE", updatedAt: "2026-09-01T00:00:00.000Z",
                    originalPath: $path, originalFileName: "photo.jpg"}]}}'
            ;;
        *)
            printf 'unexpected curl call: %s\n' "$*" >&2
            return 1
            ;;
    esac
}

adb() {
    printf '%s\n' "$*" >>"$ADB_LOG"
    case "$*" in
        '-d get-serialno')
            case "$USB_MODE" in
                missing | multiple)
                    printf 'error: %s USB device\n' "$USB_MODE" >&2
                    return 1
                    ;;
                unknown) printf 'unknown\n' ;;
                *) printf '%s\n' "$USB_SERIAL" ;;
            esac
            return 0
            ;;
        'mdns services')
            case "$DISCOVER_WIRELESS" in
                1) printf 'pixel\t_adb-tls-connect._tcp.\t%s\n' "$MDNS_ADDR" ;;
                error)
                    printf 'error: mDNS discovery unavailable\n' >&2
                    return 1
                    ;;
            esac
            return 0
            ;;
        "connect $WIRELESS_ADDR" | "connect $MDNS_ADDR")
            [ "$WIRELESS_STATE" = device ]
            return
            ;;
    esac

    [ "$1" = -s ] || {
        printf 'unexpected adb call: %s\n' "$*" >&2
        return 1
    }
    local target="$2" state
    shift 2
    case "$target" in
        "$USB_SERIAL") state="$USB_MODE" ;;
        "$WIRELESS_ADDR" | "$MDNS_ADDR") state="$WIRELESS_STATE" ;;
        *)
            printf 'unexpected adb target: %s\n' "$target" >&2
            return 1
            ;;
    esac

    if [ "$1" = get-state ]; then
        case "$state" in
            unauthorized)
                printf 'error: device unauthorized\n' >&2
                return 1
                ;;
            failed-probe)
                printf 'device\n'
                return 1
                ;;
            *) printf '%s\n' "$state" ;;
        esac
        return 0
    fi
    [ "$state" = device ] || return 1

    case "$*" in
        "push $ASSET_FILE $REMOTE_DIR/12345678_photo.jpg")
            [ "$FAIL_PUSH" -eq 0 ]
            ;;
        "shell mkdir -p $REMOTE_DIR" | "shell find $REMOTE_DIR -type f -mtime +$KEEP_DAYS")
            return 0
            ;;
        "shell df -k $REMOTE_DIR")
            printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
            printf '/dev/fuse 2000000 1000000 1000000 50%% /sdcard\n'
            ;;
        "shell for f in $REMOTE_DIR/12345678_photo.jpg;"*)
            printf 'Y\n'
            ;;
        'shell content call --uri content://media --method scan_volume --arg external_primary')
            return 0
            ;;
        *)
            printf 'unexpected adb command: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
export -f curl adb

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

run_sync() {
    local name="$1"
    shift
    export XDG_STATE_HOME="$WORK_DIR/$name/state"
    export STATE_DIR="$XDG_STATE_HOME/immich-to-pixel"
    export ADB_LOG="$WORK_DIR/$name/adb.log"
    OUTPUT="$WORK_DIR/$name/output"
    mkdir -p "$WORK_DIR/$name"
    : >"$ADB_LOG"
    EXIT_CODE=0
    bash "$SYNC_SCRIPT" --batch 1 --debug "$@" >"$OUTPUT" 2>&1 || EXIT_CODE=$?
}

assert_success() {
    local target="$1"
    if [ "$EXIT_CODE" -ne 0 ]; then
        cat "$OUTPUT" >&2
        fail "sync exited with $EXIT_CODE"
    fi
    [ "$(head -n 1 "$ADB_LOG")" = '-d get-serialno' ] || fail "USB was not checked first"
    grep -Fqx -- "-s $target push $ASSET_FILE $REMOTE_DIR/12345678_photo.jpg" "$ADB_LOG"
    awk -v target="$target" '$1 == "-s" && $3 != "get-state" && $2 != target { exit 1 }' "$ADB_LOG"
    grep -Eq '^Pushed +1$' "$OUTPUT"
    grep -Eq '^Indexed +1$' "$OUTPUT"
    grep -Eq '^Failed +0$' "$OUTPUT"
    [ "$(cat "$STATE_DIR/pushed.txt")" = "$ASSET_ID" ]
    [ "$(cat "$STATE_DIR/cursor")" = "$ASSET_TIME" ]
}

assert_no_wireless() {
    if grep -Eq '^(connect |mdns services$)' "$ADB_LOG"; then
        fail "wireless was attempted after selecting USB"
    fi
}

assert_no_transfer() {
    if grep -Eq ' push | shell (mkdir|rm) |--method scan_' "$ADB_LOG"; then
        fail "device was modified without a successful transfer"
    fi
    [ ! -s "$STATE_DIR/pushed.txt" ]
    [ ! -e "$STATE_DIR/cursor" ]
}

run_sync usb-preferred
assert_success "$USB_SERIAL"
assert_no_wireless
grep -Fq "ADB connection ready: USB ($USB_SERIAL)" "$OUTPUT"
grep -Fq -- '--method scan_file' "$ADB_LOG"

PIXEL_ADDR="" WIRELESS_STATE=offline DISCOVER_WIRELESS=0 run_sync usb-without-wireless --scan-volume
assert_success "$USB_SERIAL"
assert_no_wireless
grep -Fqx -- "-s $USB_SERIAL shell content call --uri content://media --method scan_volume --arg external_primary" "$ADB_LOG"

for MODE in missing offline unauthorized multiple unknown failed-probe; do
    USB_MODE="$MODE" run_sync "wireless-$MODE"
    assert_success "$WIRELESS_ADDR"
    grep -Fqx "connect $WIRELESS_ADDR" "$ADB_LOG"
    grep -Fq 'trying wireless adb' "$OUTPUT"
    grep -Fq "ADB connection ready: wireless ($WIRELESS_ADDR)" "$OUTPUT"
    if grep -Fqx 'mdns services' "$ADB_LOG"; then
        fail "mDNS was used despite a configured wireless address"
    fi
done

USB_MODE=missing PIXEL_ADDR="" run_sync wireless-mdns
assert_success "$MDNS_ADDR"
grep -Fqx 'mdns services' "$ADB_LOG"
grep -Fqx "connect $MDNS_ADDR" "$ADB_LOG"
grep -Fq "ADB connection ready: wireless ($MDNS_ADDR)" "$OUTPUT"

USB_MODE=missing WIRELESS_STATE=offline run_sync no-ready-connection
[ "$EXIT_CODE" -eq 2 ]
grep -Fq "device $WIRELESS_ADDR is not available" "$OUTPUT"
assert_no_transfer

USB_MODE=missing PIXEL_ADDR="" DISCOVER_WIRELESS=0 run_sync no-wireless-address
[ "$EXIT_CODE" -eq 2 ]
grep -Fq 'mDNS discovery found no adb-tls-connect service' "$OUTPUT"
assert_no_transfer

USB_MODE=missing PIXEL_ADDR="" DISCOVER_WIRELESS=error run_sync discovery-failed
[ "$EXIT_CODE" -eq 2 ]
grep -Fq 'wireless adb mDNS discovery failed' "$OUTPUT"
assert_no_transfer

run_sync usb-dry-run --dry-run
[ "$EXIT_CODE" -eq 0 ]
grep -Fq "ADB connection ready: USB ($USB_SERIAL)" "$OUTPUT"
assert_no_wireless
assert_no_transfer

FAIL_PUSH=1 run_sync usb-interrupted
[ "$EXIT_CODE" -eq 1 ]
grep -Fq 'push failed: 12345678_photo.jpg' "$OUTPUT"
assert_no_wireless
[ ! -s "$STATE_DIR/pushed.txt" ]
[ ! -e "$STATE_DIR/cursor" ]

printf 'PASS: USB preference, wireless fallback, discovery, errors, dry-run, and interrupted transfers\n'
