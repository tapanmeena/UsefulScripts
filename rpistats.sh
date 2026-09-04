#!/bin/bash

# ============================================================
# Raspberry Pi System Health
# ============================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    local label="$1"
    local status="$2"

    case "$status" in
        running|active|healthy)
            printf "%-24s ${GREEN}%s${NC}\n" "$label" "$status"
            ;;
        warning|degraded)
            printf "%-24s ${YELLOW}%s${NC}\n" "$label" "$status"
            ;;
        *)
            printf "%-24s ${RED}%s${NC}\n" "$label" "$status"
            ;;
    esac
}

printf "\n${BLUE}===== Raspberry Pi Health =====${NC}\n"

# ------------------------------------------------------------
# SYSTEM
# ------------------------------------------------------------

printf "\n${BLUE}System${NC}\n"

printf "%-24s %s\n" "Hostname" "$(hostname)"
printf "%-24s %s\n" "Uptime" "$(uptime -p)"
printf "%-24s %s\n" "Load Average" "$(awk '{print $1", "$2", "$3}' /proc/loadavg)"

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------

printf "\n${BLUE}CPU${NC}\n"

TEMP_RAW=$(vcgencmd measure_temp 2>/dev/null | cut -d '=' -f2)
TEMP_C=${TEMP_RAW::-2}

if [ -n "$TEMP_C" ]; then
    if (( $(echo "$TEMP_C >= 70" | bc -l) )); then
        TEMP_COLOR=$RED
    elif (( $(echo "$TEMP_C >= 60" | bc -l) )); then
        TEMP_COLOR=$YELLOW
    else
        TEMP_COLOR=$GREEN
    fi

    printf "%-24s ${TEMP_COLOR}%s°C${NC}\n" "Temperature" "$TEMP_C"
fi

CPU_USE=$(top -bn1 | awk -F'[,:%]' '/Cpu\(s\)/ {
    for (i=1; i<=NF; i++) {
        if ($i ~ /id/) {
            gsub(/[^0-9.]/, "", $(i-1))
            print 100 - $(i-1)
            exit
        }
    }
}')

printf "%-24s %.1f%%\n" "CPU Usage" "$CPU_USE"

CLOCK=$(vcgencmd measure_clock arm 2>/dev/null |
    awk -F= '{printf "%.0f MHz", $2/1000000}')

printf "%-24s %s\n" "CPU Clock" "$CLOCK"

TOP_PROC=$(ps -eo comm,%cpu --sort=-%cpu | sed -n '2p')
printf "%-24s %s\n" "Top CPU Process" "$TOP_PROC"

# ------------------------------------------------------------
# MEMORY
# ------------------------------------------------------------

printf "\n${BLUE}Memory${NC}\n"

MEM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
MEM_USED=$(free -h | awk '/Mem:/ {print $3}')
MEM_AVAILABLE=$(free -h | awk '/Mem:/ {print $7}')
MEM_PERCENT=$(free | awk '/Mem:/ {printf "%.1f%%", $3/$2*100}')

SWAP_TOTAL=$(free -h | awk '/Swap:/ {print $2}')
SWAP_USED=$(free -h | awk '/Swap:/ {print $3}')

printf "%-24s %s\n" "RAM Total" "$MEM_TOTAL"
printf "%-24s %s\n" "RAM Used" "$MEM_USED"
printf "%-24s %s\n" "RAM Available" "$MEM_AVAILABLE"
printf "%-24s %s\n" "RAM Usage" "$MEM_PERCENT"

printf "%-24s %s / %s\n" "Swap Used" "$SWAP_USED" "$SWAP_TOTAL"

# ------------------------------------------------------------
# STORAGE
# ------------------------------------------------------------

printf "\n${BLUE}Storage${NC}\n"

ROOT_INFO=$(df -h / | awk 'NR==2 {
    printf "%s / %s used / %s free (%s)",
    $2, $3, $4, $5
}')

printf "%-24s %s\n" "Root (/)" "$ROOT_INFO"

ROOT_USED=$(df / | awk 'NR==2 {gsub("%","",$5); print $5}')

if [ "$ROOT_USED" -ge 90 ]; then
    printf "${RED}WARNING: Root filesystem is %s%% full${NC}\n" "$ROOT_USED"
fi

printf "\nExternal HDDs:\n"

FOUND_HDD=false

while read -r DEVICE SIZE MOUNTPOINT; do

    [ -z "$MOUNTPOINT" ] && continue

    FOUND_HDD=true

    DF_INFO=$(df -h "$MOUNTPOINT" | awk 'NR==2 {
        printf "%s total / %s used / %s free (%s)",
        $2, $3, $4, $5
    }')

    USAGE=$(df "$MOUNTPOINT" | awk 'NR==2 {
        gsub("%","",$5)
        print $5
    }')

    if [ "$USAGE" -ge 95 ]; then
        COLOR=$RED
    elif [ "$USAGE" -ge 85 ]; then
        COLOR=$YELLOW
    else
        COLOR=$GREEN
    fi

    printf "\n  Device      : %s\n" "$DEVICE"
    printf "  Mount Point : %s\n" "$MOUNTPOINT"
    printf "  Usage       : ${COLOR}%s${NC}\n" "$DF_INFO"

    if [ "$USAGE" -ge 95 ]; then
        printf "  ${RED}WARNING: Disk almost full${NC}\n"
    fi

done < <(
    lsblk -pnro NAME,TYPE,MOUNTPOINT |
    awk '$2 == "part" && $1 ~ /^\/dev\/sd[a-z][0-9]+$/ && $3 != "" {
        print $1, $1, $3
    }'
)

if [ "$FOUND_HDD" = false ]; then
    printf "  ${RED}No mounted external HDDs found${NC}\n"
fi

# ------------------------------------------------------------
# NETWORK
# ------------------------------------------------------------

printf "\n${BLUE}Network${NC}\n"

ip -4 -o addr show up |
awk '$2 !~ /^(lo|docker.*|br-.*)$/ {
    split($4, a, "/")
    printf "%-24s %s\n", $2, a[1]
}'

# ------------------------------------------------------------
# SERVICES
# ------------------------------------------------------------

printf "\n${BLUE}System Services${NC}\n"

for svc in ssh docker; do
    STATUS=$(systemctl is-active "$svc" 2>/dev/null)

    if [ "$STATUS" = "active" ]; then
        print_status "$svc" "running"
    else
        print_status "$svc" "stopped"
    fi
done

# ------------------------------------------------------------
# IMMICH
# ------------------------------------------------------------

printf "\n${BLUE}Immich${NC}\n"

check_immich_container() {
    local NAME="$1"
    local LABEL="$2"

    local STATUS
    local HEALTH
    local RESTARTS

    STATUS=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)
    HEALTH=$(docker inspect -f \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$NAME" 2>/dev/null)
    RESTARTS=$(docker inspect -f '{{.RestartCount}}' "$NAME" 2>/dev/null)

    if [ -z "$STATUS" ]; then
        print_status "$LABEL" "not found"
        return
    fi

    if [ "$STATUS" = "running" ]; then

        if [ "$HEALTH" = "healthy" ]; then
            print_status "$LABEL" "running / healthy"
        elif [ "$HEALTH" = "unhealthy" ]; then
            print_status "$LABEL" "running / UNHEALTHY"
        else
            print_status "$LABEL" "running"
        fi

        if [ "$RESTARTS" -gt 0 ]; then
            printf "  Restarts: %s\n" "$RESTARTS"
        fi

    else
        print_status "$LABEL" "$STATUS"
    fi
}

check_immich_container "immich_postgres" "PostgreSQL"
check_immich_container "immich_server" "Immich Server"
check_immich_container "immich_redis" "Immich Cache"
check_immich_container "immich_machine_learning" "Immich ML"

printf "\n${BLUE}================================${NC}\n\n"