#!/usr/bin/env bash
#
# ============================================================
# wan-watch - prove what your connection actually did
# ============================================================
#
# Runs on: Pi (bash 5)
# Requires: ping awk
#
# Speedtests measure the wrong thing. What ruins calls and uploads is latency
# under load, jitter and loss, not peak megabits, and faults are intermittent
# so a test run at the moment you are annoyed proves nothing to anyone.
#
# So this samples cheaply and constantly, and tests expensively and rarely.
#
#   --probe        every minute from a timer; four anchors, one CSV row
#   --full         throughput, gated so it never measures your own traffic
#   --bufferbloat  latency while saturated, which is the number that matters
#   --report       sparklines, worst windows, and a time-of-day heatmap
#
# The four anchors exist to answer one question: is it them or is it you.
# The gateway covers your LAN and wifi, the ISP hop covers the last mile, and
# the public resolvers cover transit. Gateway fine but transit bad means the
# ISP. Gateway bad too means your own network. Most people cannot tell these
# apart and spend a week blaming the wrong party.
#
# Outage alerts are spooled to disk and flushed on recovery, because an alert
# that needs the connection to report the connection being down is decoration.
#
# Config file (default ~/.config/wan-watch.conf, mode 600):
#   ANCHORS="1.1.1.1 8.8.8.8"
#   DNS_NAME="cloudflare.com"
#   FAIL_STREAK=3
#   OK_STREAK=2
#
# Usage:  wan-watch.sh --probe             (every minute, from a timer)
#         wan-watch.sh --report [--days N]
#         wan-watch.sh --full | --bufferbloat | --outages
# ============================================================

set -euo pipefail

# install.sh symlinks this into ~/.local/bin, where dirname "$0" points at the
# symlink rather than the repo. The symlinks it creates are absolute.
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
# shellcheck source=lib/common.sh
. "$_lib"

require_linux
require_tools ping awk

NOW="$(date +%s)"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

load_config wan-watch

ANCHORS="${ANCHORS:-1.1.1.1 8.8.8.8}"
DNS_NAME="${DNS_NAME:-cloudflare.com}"
PING_COUNT="${PING_COUNT:-10}"
FAIL_STREAK="${FAIL_STREAK:-3}"
OK_STREAK="${OK_STREAK:-2}"
PUBLIC_IP_EVERY="${PUBLIC_IP_EVERY:-15}"
PUBLIC_IP_URL="${PUBLIC_IP_URL:-https://api.ipify.org}"
BUSY_KB_S="${BUSY_KB_S:-200}"
# Big enough that it does not finish before the measurement window, and fetched
# in parallel because one stream rarely fills a modern link.
BLOAT_URL="${BLOAT_URL:-http://speedtest.tele2.net/100MB.zip}"
BLOAT_STREAMS="${BLOAT_STREAMS:-4}"
BLOAT_MIN_KB_S="${BLOAT_MIN_KB_S:-1000}"
REPORT_DAYS="${REPORT_DAYS:-7}"

MODE=report
AS_JSON=0

usage() {
    cat <<'EOF'
Continuous connection quality monitoring, with reports that prove what happened.

Usage: wan-watch.sh [options]

  --probe          Take one cheap measurement. Run every minute from a timer.
  --full           Run a throughput test. Skipped if the link is already busy.
  --bufferbloat    Measure latency under load and grade it.
  --report         Summarise the history (default).
  --outages        List recorded outages.
  --days N         Report window in days (default 7).
  --json           Machine-readable output.
  -h, --help       Show this help.

Settings (config file wins over environment):
  ANCHORS, DNS_NAME, PING_COUNT, FAIL_STREAK, OK_STREAK, PUBLIC_IP_EVERY
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --probe)
            MODE=probe
            shift
            ;;
        --full)
            MODE=full
            shift
            ;;
        --bufferbloat)
            MODE=bloat
            shift
            ;;
        --report)
            MODE=report
            shift
            ;;
        --outages)
            MODE=outages
            shift
            ;;
        --days)
            REPORT_DAYS="${2:?--days needs a value}"
            shift 2
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

STATE="$(state_dir wan-watch)"
SAMPLES="$STATE/samples-$(date +%Y-%m).csv"
OUTAGES="$STATE/outages.tsv"
SPOOL="$STATE/spool.txt"
OUTAGE_STATE="$STATE/outage.state"
CSV_HEADER='ts,gw_rtt,gw_loss,isp_rtt,inet_rtt,inet_loss,jitter,dns_ms,public_ip'

# ------------------------------------------------------------
# MEASUREMENT
# ------------------------------------------------------------

default_gateway() {
    ip route 2>/dev/null | awk '/^default/ { print $3; exit }'
}

# One hop past the gateway. traceroute is not installed everywhere, but a TTL
# limited ping gets the same answer from the ICMP time-exceeded reply.
discover_isp_hop() {
    local cache="$STATE/isp-hop" anchor hop
    if [ -f "$cache" ]; then
        hop="$(cat "$cache" 2>/dev/null || true)"
        [ -n "$hop" ] && {
            printf '%s' "$hop"
            return 0
        }
    fi
    for anchor in $ANCHORS; do
        hop="$({ ping -c 1 -t 2 -W 2 -n "$anchor" 2>/dev/null || true; } |
            awk '/From|from/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit } }' | head -1)"
        if [ -n "$hop" ]; then
            printf '%s' "$hop" >"$cache"
            printf '%s' "$hop"
            return 0
        fi
    done
    return 1
}

# ping_stats <host> [count] -> "loss avg mdev", avg and mdev empty when down.
ping_stats() {
    local host="$1" count="${2:-$PING_COUNT}"
    { ping -c "$count" -i 0.2 -W 1 -n "$host" 2>/dev/null || true; } | awk '
        /packet loss/ {
            for (i = 1; i <= NF; i++) if ($i ~ /%$/) { gsub(/%/, "", $i); loss = $i }
        }
        /^(rtt|round-trip)/ { split($4, a, "/"); avg = a[2]; mdev = a[4] }
        END { printf "%s %s %s", (loss == "" ? 100 : loss), avg, mdev }
    '
}

# Resolution failures feel exactly like the internet being down but are not.
dns_ms() {
    local start end
    start="$(date +%s%N)"
    if getent ahostsv4 "$DNS_NAME" >/dev/null 2>&1; then
        end="$(date +%s%N)"
        echo $(((end - start) / 1000000))
    else
        echo -1
    fi
}

public_ip() {
    command -v curl >/dev/null 2>&1 || return 0
    local stamp="$STATE/public-ip.stamp" cached="$STATE/public-ip" last=0
    [ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
    case "$last" in '' | *[!0-9]*) last=0 ;; esac

    if [ $((NOW - last)) -lt $((PUBLIC_IP_EVERY * 60)) ] && [ -f "$cached" ]; then
        cat "$cached"
        return 0
    fi

    local ip
    ip="$(curl -s --max-time 5 "$PUBLIC_IP_URL" 2>/dev/null || true)"
    case "$ip" in
        *[!0-9.]* | '') ip='' ;;
    esac
    if [ -n "$ip" ]; then
        # An address change is worth knowing about even without dynamic DNS.
        if [ -f "$cached" ] && [ "$(cat "$cached")" != "$ip" ]; then
            notify info "wan-watch: public IP changed" "$(cat "$cached") -> $ip"
            printf '%s\t%s\t%s\n' "$NOW" "$(cat "$cached")" "$ip" >>"$STATE/ip-history.tsv"
        fi
        printf '%s' "$ip" >"$cached"
        printf '%s' "$NOW" >"$stamp"
        printf '%s' "$ip"
    elif [ -f "$cached" ]; then
        cat "$cached"
    fi
}

# ------------------------------------------------------------
# OUTAGE STATE MACHINE
#
# Hysteresis stops a single dropped packet opening an outage. The spool exists
# because the notification cannot leave the house while the link is down.
# ------------------------------------------------------------

record_outage_state() {
    local up="$1" fails=0 oks=0 start=0
    if [ -f "$OUTAGE_STATE" ]; then
        read -r fails oks start <"$OUTAGE_STATE" 2>/dev/null || true
        : "${fails:=0}" "${oks:=0}" "${start:=0}"
    fi

    if [ "$up" -eq 0 ]; then
        fails=$((fails + 1))
        oks=0
        if [ "$fails" -eq "$FAIL_STREAK" ] && [ "$start" -eq 0 ]; then
            start="$NOW"
            printf 'outage started %s\n' "$(date -d "@$NOW" '+%F %T')" >>"$SPOOL"
        fi
    else
        oks=$((oks + 1))
        fails=0
        if [ "$start" -gt 0 ] && [ "$oks" -ge "$OK_STREAK" ]; then
            local dur=$((NOW - start))
            printf '%s\t%s\t%s\n' "$start" "$NOW" "$dur" >>"$OUTAGES"
            notify warn "wan-watch: connection restored" \
                "outage lasted $(human_duration "$dur"), started $(date -d "@$start" '+%F %T')"
            : >"$SPOOL"
            start=0
        fi
    fi

    printf '%s %s %s\n' "$fails" "$oks" "$start" >"$OUTAGE_STATE"
}

# ------------------------------------------------------------
# PROBE
# ------------------------------------------------------------

do_probe() {
    local gw isp gw_s isp_s inet_s best_rtt worst_loss jitter dns ip
    gw="$(default_gateway || true)"
    isp="$(discover_isp_hop || true)"

    local gw_loss=100 gw_rtt='' isp_rtt=''
    if [ -n "$gw" ]; then
        gw_s="$(ping_stats "$gw" 5)"
        gw_loss="$(printf '%s' "$gw_s" | awk '{ print $1 }')"
        gw_rtt="$(printf '%s' "$gw_s" | awk '{ print $2 }')"
    fi
    if [ -n "$isp" ]; then
        isp_s="$(ping_stats "$isp" 5)"
        isp_rtt="$(printf '%s' "$isp_s" | awk '{ print $2 }')"
    fi

    best_rtt=''
    worst_loss=100
    jitter=''
    local a loss rtt mdev
    for a in $ANCHORS; do
        inet_s="$(ping_stats "$a")"
        loss="$(printf '%s' "$inet_s" | awk '{ print $1 }')"
        rtt="$(printf '%s' "$inet_s" | awk '{ print $2 }')"
        mdev="$(printf '%s' "$inet_s" | awk '{ print $3 }')"
        # Best anchor wins: one unhappy resolver is not an outage.
        if [ -n "$rtt" ]; then
            if [ -z "$best_rtt" ] || awk -v a="$rtt" -v b="$best_rtt" 'BEGIN { exit !(a < b) }'; then
                best_rtt="$rtt"
                jitter="$mdev"
            fi
        fi
        awk -v a="$loss" -v b="$worst_loss" 'BEGIN { exit !(a < b) }' && worst_loss="$loss"
    done

    dns="$(dns_ms)"
    ip="$(public_ip || true)"

    csv_append "$SAMPLES" "$CSV_HEADER" \
        "$NOW,${gw_rtt:-},${gw_loss:-100},${isp_rtt:-},${best_rtt:-},${worst_loss:-100},${jitter:-},${dns:--1},${ip:-}"

    local up=1
    [ -z "$best_rtt" ] && up=0
    record_outage_state "$up"

    if [ "$AS_JSON" -eq 1 ]; then
        printf '{"ts":%s,"gw_rtt":"%s","gw_loss":%s,"isp_rtt":"%s","inet_rtt":"%s","inet_loss":%s,"jitter":"%s","dns_ms":%s,"public_ip":"%s","up":%s}\n' \
            "$NOW" "${gw_rtt:-}" "${gw_loss:-100}" "${isp_rtt:-}" "${best_rtt:-}" "${worst_loss:-100}" "${jitter:-}" "${dns:--1}" "${ip:-}" "$up"
    else
        if [ "$up" -eq 1 ]; then
            ok "up: gateway ${gw_rtt:-?}ms, isp ${isp_rtt:-?}ms, internet ${best_rtt}ms, loss ${worst_loss}%, dns ${dns}ms"
        else
            warn "internet unreachable (gateway ${gw_rtt:-unreachable})"
        fi
    fi

    [ "$up" -eq 1 ] || exit "$EX_WARN"
}

# ------------------------------------------------------------
# THROUGHPUT
# ------------------------------------------------------------

link_busy_kb_s() {
    local iface rx1 rx2 tx1 tx2
    iface="$(ip route 2>/dev/null | awk '/^default/ { for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit }')"
    [ -n "$iface" ] || {
        echo 0
        return 0
    }
    read -r rx1 tx1 < <(awk -v i="$iface:" '$1 == i { print $2, $10 }' /proc/net/dev)
    sleep 3
    read -r rx2 tx2 < <(awk -v i="$iface:" '$1 == i { print $2, $10 }' /proc/net/dev)
    echo $(((rx2 - rx1 + tx2 - tx1) / 3 / 1024))
}

do_full() {
    require_tools speedtest
    local busy
    busy="$(link_busy_kb_s)"
    if [ "$busy" -gt "$BUSY_KB_S" ]; then
        # Measuring while your own sync is running poisons the history.
        info "link already doing ${busy} KB/s, skipping throughput test"
        exit "$EX_OK"
    fi

    info "running throughput test..."
    local json
    json="$(speedtest --json 2>/dev/null || true)"
    [ -n "$json" ] || die "speedtest produced no output"

    local down up png
    down="$(printf '%s' "$json" | awk -F'[,:]' '/"download"/ { print $2; exit }')"
    up="$(printf '%s' "$json" | awk -F'[,:]' '/"upload"/ { print $2; exit }')"
    png="$(printf '%s' "$json" | awk -F'[,:]' '/"ping"/ { print $2; exit }')"

    csv_append "$STATE/throughput.csv" 'ts,down_bps,up_bps,ping_ms' \
        "$NOW,${down:-0},${up:-0},${png:-0}"

    if [ "$AS_JSON" -eq 1 ]; then
        printf '{"ts":%s,"down_mbps":%.1f,"up_mbps":%.1f,"ping_ms":%.1f}\n' \
            "$NOW" "$(awk -v v="${down:-0}" 'BEGIN{print v/1000000}')" \
            "$(awk -v v="${up:-0}" 'BEGIN{print v/1000000}')" "${png:-0}"
    else
        kv "Download" "$(awk -v v="${down:-0}" 'BEGIN { printf "%.1f Mbps", v / 1000000 }')"
        kv "Upload" "$(awk -v v="${up:-0}" 'BEGIN { printf "%.1f Mbps", v / 1000000 }')"
        kv "Idle ping" "$(awk -v v="${png:-0}" 'BEGIN { printf "%.0f ms", v }')"
    fi
}

# ------------------------------------------------------------
# BUFFERBLOAT
#
# A 500 Mbps line that adds 400ms under load is worse to live with than a
# 100 Mbps line that adds 10ms, and no speedtest number shows that.
# ------------------------------------------------------------

do_bloat() {
    require_tools curl
    local anchor idle loaded delta grade iface rx1 rx2 kbps i
    local -a pids=()
    anchor="$(printf '%s' "$ANCHORS" | awk '{ print $1 }')"
    iface="$(ip route 2>/dev/null | awk '/^default/ { for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit }')"

    info "measuring idle latency..."
    idle="$(ping_stats "$anchor" 10 | awk '{ print $2 }')"
    [ -n "$idle" ] || die "cannot reach $anchor"

    info "saturating the link with $BLOAT_STREAMS streams..."
    for i in $(seq 1 "$BLOAT_STREAMS"); do
        curl -s -o /dev/null --max-time 40 "$BLOAT_URL" &
        pids+=($!)
    done
    sleep 3

    rx1="$(awk -v i="$iface:" '$1 == i { print $2 }' /proc/net/dev)"
    loaded="$(ping_stats "$anchor" 20 | awk '{ print $2 }')"
    rx2="$(awk -v i="$iface:" '$1 == i { print $2 }' /proc/net/dev)"

    for i in "${pids[@]}"; do kill "$i" 2>/dev/null || true; done
    wait 2>/dev/null || true

    [ -n "$loaded" ] || die "lost the anchor while loaded, which is itself a bad sign"

    # A result measured on an unsaturated link is meaningless, so say so
    # rather than reporting a flattering grade.
    kbps=$(((rx2 - rx1) / 4 / 1024))
    delta="$(awk -v a="$idle" -v b="$loaded" 'BEGIN { d = b - a; printf "%.0f", (d < 0 ? 0 : d) }')"
    grade="$(awk -v d="$delta" 'BEGIN {
        if (d < 5) print "A+"
        else if (d < 30) print "A"
        else if (d < 60) print "B"
        else if (d < 200) print "C"
        else if (d < 400) print "D"
        else print "F"
    }')"
    [ "$kbps" -lt "$BLOAT_MIN_KB_S" ] && grade="$grade (unreliable)"

    if [ "$AS_JSON" -eq 1 ]; then
        printf '{"idle_ms":%s,"loaded_ms":%s,"increase_ms":%s,"grade":"%s","load_kb_s":%s}\n' \
            "$idle" "$loaded" "$delta" "$grade" "$kbps"
    else
        section "Bufferbloat"
        kv "Idle latency" "$(awk -v v="$idle" 'BEGIN { printf "%.1f ms", v }')"
        kv "Latency under load" "$(awk -v v="$loaded" 'BEGIN { printf "%.1f ms", v }')"
        kv "Increase" "+${delta} ms"
        kv "Load achieved" "$(human_bytes $((kbps * 1024)))/s"
        kv "Grade" "$grade"
        if [ "$kbps" -lt "$BLOAT_MIN_KB_S" ]; then
            warn "the link never saturated, so this grade means little; raise BLOAT_STREAMS or use a nearer file"
        fi
    fi
    csv_append "$STATE/bufferbloat.csv" 'ts,idle_ms,loaded_ms,delta_ms,grade,load_kb_s' \
        "$NOW,$idle,$loaded,$delta,$grade,$kbps"
}

# ------------------------------------------------------------
# REPORT
# ------------------------------------------------------------

all_samples() {
    cat "$STATE"/samples-*.csv 2>/dev/null | grep -v '^ts,' || true
}

do_report() {
    local cutoff window
    cutoff=$((NOW - REPORT_DAYS * 86400))
    window="$(all_samples | awk -F, -v c="$cutoff" '$1 >= c')"

    if [ -z "$window" ]; then
        info "no samples in the last ${REPORT_DAYS}d. Run wan-watch --probe, or wait for the timer."
        exit "$EX_OK"
    fi

    local total up_n uptime_pct avg_rtt max_rtt avg_loss
    total="$(printf '%s\n' "$window" | grep -c . || true)"
    up_n="$(printf '%s\n' "$window" | awk -F, '$5 != "" { n++ } END { print n + 0 }')"
    uptime_pct="$(awk -v a="$up_n" -v b="$total" 'BEGIN { printf "%.2f", b ? a / b * 100 : 0 }')"
    avg_rtt="$(printf '%s\n' "$window" | awk -F, '$5 != "" { s += $5; n++ } END { printf "%.1f", n ? s / n : 0 }')"
    max_rtt="$(printf '%s\n' "$window" | awk -F, '$5 != "" && $5 + 0 > m { m = $5 } END { printf "%.1f", m }')"
    avg_loss="$(printf '%s\n' "$window" | awk -F, '{ s += $6; n++ } END { printf "%.2f", n ? s / n : 0 }')"

    if [ "$AS_JSON" -eq 1 ]; then
        printf '{"days":%s,"samples":%s,"uptime_pct":%s,"avg_rtt_ms":%s,"max_rtt_ms":%s,"avg_loss_pct":%s}\n' \
            "$REPORT_DAYS" "$total" "$uptime_pct" "$avg_rtt" "$max_rtt" "$avg_loss"
        exit "$EX_OK"
    fi

    section "Connection quality, last ${REPORT_DAYS}d"
    kv "Samples" "$total"
    kv "Reachable" "${uptime_pct}%"
    kv "Latency" "avg ${avg_rtt} ms, worst ${max_rtt} ms"
    kv "Packet loss" "avg ${avg_loss}%"

    # Hourly mean latency, oldest to newest.
    local hourly
    hourly="$(printf '%s\n' "$window" | awk -F, '
        $5 != "" { b = int($1 / 3600); s[b] += $5; n[b]++ }
        END { for (k in s) printf "%d %.1f\n", k, s[k] / n[k] }' | sort -n | awk '{ print $2 }')"
    if [ -n "$hourly" ]; then
        # shellcheck disable=SC2086  # deliberate word splitting into arguments
        printf '\n%bHourly mean latency%b  %s\n' "$BLUE" "$NC" "$(sparkline $hourly)"
        printf '%b%s%b\n' "$DIM" "  oldest to newest, one cell per hour" "$NC"
    fi

    # Same hour every day, which is where ISP congestion shows itself.
    # Bucketed in local time, since "every evening at nine" is the claim you
    # want to be able to make.
    local tod tz_off
    tz_off="$(date +%z | awk '{ s = substr($0,1,1); h = substr($0,2,2); m = substr($0,4,2); v = h * 3600 + m * 60; print (s == "-" ? -v : v) }')"
    tod="$(printf '%s\n' "$window" | awk -F, -v off="$tz_off" '
        $5 != "" { h = int((($1 + off) % 86400) / 3600); s[h] += $5; n[h]++ }
        END { for (h = 0; h < 24; h++) printf "%.1f\n", (n[h] ? s[h] / n[h] : 0) }')"
    if [ -n "$tod" ]; then
        # shellcheck disable=SC2086  # deliberate word splitting into arguments
        printf '\n%bBy hour of day%b       %s\n' "$BLUE" "$NC" "$(sparkline $tod)"
        printf '%b%s%b\n' "$DIM" "  00h                     12h                     23h (local)" "$NC"
    fi

    section "Worst 5 windows"
    printf '%s\n' "$window" | awk -F, '
        { score = $6 * 10 + ($5 == "" ? 1000 : $5); print score "\t" $1 "\t" $5 "\t" $6 }' |
        sort -rn | head -5 |
        while IFS="$(printf '\t')" read -r _ ts rtt loss; do
            printf '  %s  %6s ms  %5s%% loss\n' \
                "$(date -d "@$ts" '+%F %H:%M')" "${rtt:-down}" "$loss"
        done

    local n_out
    n_out="$(grep -c . "$OUTAGES" 2>/dev/null || true)"
    if [ "${n_out:-0}" -gt 0 ]; then
        local longest
        longest="$(awk -F'\t' -v c="$cutoff" '$1 >= c && $3 + 0 > m { m = $3 } END { print m + 0 }' "$OUTAGES")"
        printf '\n'
        kv "Outages" "$(awk -F'\t' -v c="$cutoff" '$1 >= c { n++ } END { print n + 0 }' "$OUTAGES") in window, longest $(human_duration "$longest")"
    fi
}

do_outages() {
    if [ ! -s "$OUTAGES" ]; then
        info "no outages recorded"
        exit "$EX_OK"
    fi
    section "Recorded outages"
    printf '%-20s %-20s %s\n' START END DURATION
    while IFS="$(printf '\t')" read -r start end dur; do
        printf '%-20s %-20s %s\n' \
            "$(date -d "@$start" '+%F %H:%M:%S')" \
            "$(date -d "@$end" '+%F %H:%M:%S')" \
            "$(human_duration "$dur")"
    done <"$OUTAGES"
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

case "$MODE" in
    probe) with_lock wan-watch do_probe ;;
    full) with_lock wan-watch-full do_full ;;
    bloat) do_bloat ;;
    report) do_report ;;
    outages) do_outages ;;
esac
