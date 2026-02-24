#!/bin/bash

# ============================================================
#   DISK USAGE MONITOR — Directory Breakdown + Plain Text Report By AI Prasul
# ============================================================

# ── Colors & Styles (terminal output) ────────────────────────
RESET="\033[0m";  BOLD="\033[1m";  DIM="\033[2m"
RED="\033[91m";   GREEN="\033[92m"; YELLOW="\033[93m"
BLUE="\033[94m";  MAGENTA="\033[95m"; CYAN="\033[96m"
WHITE="\033[97m"; BLACK="\033[30m"
BG_RED="\033[41m"; BG_YELLOW="\033[43m"; BG_GREEN="\033[42m"; BG_BLUE="\033[44m"

# ── Configuration ─────────────────────────────────────────────
WARN_THRESHOLD=70
CRIT_THRESHOLD=90
TOP_N=10
MONITOR_DIRS=("/" "/home" "/var" "/backup" "/tmp" "/opt" "/data")

# ── Report Output ─────────────────────────────────────────────
REPORT_DIR="/var/log/disk_reports"          # folder where reports are saved
mkdir -p "$REPORT_DIR"
REPORT_FILE="${REPORT_DIR}/disk_report_$(date '+%Y%m%d_%H%M%S').txt"
LATEST_LINK="${REPORT_DIR}/disk_report_latest.txt"

# ─────────────────────────────────────────────────────────────
# TERMINAL HELPERS
# ─────────────────────────────────────────────────────────────
draw_bar() {
    local pct=$1 width=${2:-28}
    local filled=$(( pct * width / 100 )); local empty=$(( width - filled ))
    if   [ "$pct" -ge "$CRIT_THRESHOLD" ]; then C=$RED
    elif [ "$pct" -ge "$WARN_THRESHOLD" ]; then C=$YELLOW
    else C=$GREEN; fi
    printf "${C}["; for((i=0;i<filled;i++)); do printf "█"; done
    printf "${DIM}"; for((i=0;i<empty;i++)); do printf "░"; done
    printf "${C}]${RESET}"
}

mini_bar() {
    local pct=$1 width=15; local filled=$(( pct * width / 100 )); local empty=$(( width - filled ))
    printf "${CYAN}"; for((i=0;i<filled;i++)); do printf "▪"; done
    printf "${DIM}"; for((i=0;i<empty;i++)); do printf "·"; done
    printf "${RESET}"
}

badge() {
    local pct=$1
    if   [ "$pct" -ge "$CRIT_THRESHOLD" ]; then echo -e "${BG_RED}${WHITE}${BOLD} CRITICAL ${RESET}"
    elif [ "$pct" -ge "$WARN_THRESHOLD" ]; then echo -e "${BG_YELLOW}${BLACK}${BOLD} WARNING  ${RESET}"
    else                                        echo -e "${BG_GREEN}${BLACK}${BOLD}   OK     ${RESET}"; fi
}

dir_pct_of_partition() {
    local dir_kb=$1 part_kb=$2
    [ "$part_kb" -eq 0 ] && echo 0 && return
    echo $(( dir_kb * 100 / part_kb ))
}

# ─────────────────────────────────────────────────────────────
# PLAIN TEXT REPORT HELPERS
# ─────────────────────────────────────────────────────────────
txt_badge() {
    local pct=$1
    if   [ "$pct" -ge "$CRIT_THRESHOLD" ]; then echo "[CRITICAL]"
    elif [ "$pct" -ge "$WARN_THRESHOLD" ]; then echo "[WARNING] "
    else                                        echo "[  OK   ] "; fi
}

txt_bar() {
    local pct=$1 width=30
    local filled=$(( pct * width / 100 )); local empty=$(( width - filled ))
    printf "|"; for((i=0;i<filled;i++)); do printf "#"; done
    for((i=0;i<empty;i++)); do printf "."; done; printf "| %3s%%" "$pct"
}

# ─────────────────────────────────────────────────────────────
# SHARED DATA
# ─────────────────────────────────────────────────────────────
TIMESTAMP=$(date '+%A, %d %B %Y — %H:%M:%S')
HOSTNAME=$(hostname)
ALERTS=()

# ─────────────────────────────────────────────────────────────
# START REPORT FILE
# ─────────────────────────────────────────────────────────────
{
printf '=%.0s' {1..70}; echo
printf "  DISK USAGE REPORT\n"
printf "  Host      : %s\n" "$HOSTNAME"
printf "  Generated : %s\n" "$TIMESTAMP"
printf "  Thresholds: OK < %s%%   WARNING < %s%%   CRITICAL >= %s%%\n" \
       "$WARN_THRESHOLD" "$CRIT_THRESHOLD" "$CRIT_THRESHOLD"
printf '=%.0s' {1..70}; echo
echo
} > "$REPORT_FILE"

# ─────────────────────────────────────────────────────────────
# TERMINAL HEADER
# ─────────────────────────────────────────────────────────────
clear
echo
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║       💾  DISK USAGE MONITOR — Directory Breakdown  💾           ║${RESET}"
printf "${BOLD}${CYAN}║       %-57s║${RESET}\n" "$TIMESTAMP"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "  Thresholds: ${GREEN}■ OK${RESET} < ${WARN_THRESHOLD}%   ${YELLOW}■ WARNING${RESET} < ${CRIT_THRESHOLD}%   ${RED}■ CRITICAL${RESET} ≥ ${CRIT_THRESHOLD}%   ${DIM}│ Top ${TOP_N} subdirs per folder${RESET}"
echo

# ─────────────────────────────────────────────────────────────
# SECTION 1 — PARTITION OVERVIEW
# ─────────────────────────────────────────────────────────────
echo -e "${BOLD}${BG_BLUE}${WHITE}  ── PARTITION OVERVIEW ─────────────────────────────────────────  ${RESET}"
echo
printf "  ${BOLD}${BLUE}%-22s %-7s %-7s %-7s  %-34s %s${RESET}\n" \
       "MOUNT POINT" "SIZE" "USED" "FREE" "USAGE" "STATUS"
echo -e "  ${DIM}$(printf '%.0s─' {1..82})${RESET}"

{
printf '=%.0s' {1..70}; echo
printf "  SECTION 1 — PARTITION OVERVIEW\n"
printf '=%.0s' {1..70}; echo
printf "%-22s %-7s %-7s %-7s  %-36s %s\n" \
       "MOUNT POINT" "SIZE" "USED" "FREE" "USAGE" "STATUS"
printf '%.0s-' {1..70}; echo
} >> "$REPORT_FILE"

while IFS= read -r line; do
    sz=$(echo "$line"|awk '{print $2}')
    used=$(echo "$line"|awk '{print $3}'); av=$(echo "$line"|awk '{print $4}')
    pct=$(echo "$line"|awk '{print $5}'|tr -d '%'); mnt=$(echo "$line"|awk '{print $6}')
    if   [ "$pct" -ge "$CRIT_THRESHOLD" ]; then MC=$RED
    elif [ "$pct" -ge "$WARN_THRESHOLD" ]; then MC=$YELLOW
    else MC=$GREEN; fi
    # Terminal
    printf "  ${BOLD}${MC}%-22s${RESET} %-7s %-7s %-7s  %b ${BOLD}%3s%%${RESET}  %b\n" \
           "$mnt" "$sz" "$used" "$av" "$(draw_bar $pct)" "$pct" "$(badge $pct)"
    # Report
    printf "%-22s %-7s %-7s %-7s  %-36s %s\n" \
           "$mnt" "$sz" "$used" "$av" "$(txt_bar $pct)" "$(txt_badge $pct)" >> "$REPORT_FILE"
done < <(df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
         | grep -Ev "^Filesystem|tmpfs|devtmpfs|squashfs|overlay|udev" \
         | sort -k5 -rn)

echo >> "$REPORT_FILE"

# ─────────────────────────────────────────────────────────────
# SECTION 2 — DIRECTORY BREAKDOWN
# ─────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${BG_BLUE}${WHITE}  ── DIRECTORY BREAKDOWN (Top ${TOP_N} subdirectories each) ──────────────  ${RESET}"

{
printf '=%.0s' {1..70}; echo
printf "  SECTION 2 — DIRECTORY BREAKDOWN (Top %s subdirectories each)\n" "$TOP_N"
printf '=%.0s' {1..70}; echo
} >> "$REPORT_FILE"

for DIR in "${MONITOR_DIRS[@]}"; do
    echo
    if [ ! -d "$DIR" ]; then
        echo -e "  ${DIM}${YELLOW}⚠  ${BOLD}${DIR}${RESET}${DIM}  — directory not found, skipping.${RESET}"
        { echo; printf "  %-s  — directory not found, skipping.\n" "$DIR"; } >> "$REPORT_FILE"
        continue
    fi

    DF_LINE=$(df -k "$DIR" 2>/dev/null | tail -1)
    PART_KB=$(echo "$DF_LINE" | awk '{print $2}')
    PART_PCT=$(echo "$DF_LINE" | awk '{print $5}' | tr -d '%')
    PART_SIZE_H=$(df -h "$DIR" 2>/dev/null | tail -1 | awk '{print $2}')
    PART_USED_H=$(df -h "$DIR" 2>/dev/null | tail -1 | awk '{print $3}')
    PART_FREE_H=$(df -h "$DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    PART_MNT=$(df -h "$DIR"  2>/dev/null | tail -1 | awk '{print $6}')

    [ "$PART_PCT" -ge "$WARN_THRESHOLD" ] && ALERTS+=("$PART_PCT|$DIR|$PART_USED_H|$PART_SIZE_H")

    if   [ "$PART_PCT" -ge "$CRIT_THRESHOLD" ]; then HC=$RED;    ICON="🔴"
    elif [ "$PART_PCT" -ge "$WARN_THRESHOLD" ]; then HC=$YELLOW;  ICON="🟡"
    else HC=$GREEN; ICON="🟢"; fi

    # Terminal
    echo -e "  ${ICON}  ${BOLD}${HC}${DIR}${RESET}  ${DIM}(on partition ${PART_MNT})${RESET}"
    echo -e "     $(draw_bar $PART_PCT 34)  ${BOLD}${HC}${PART_PCT}%${RESET}  ${DIM}│${RESET}  ${BOLD}${PART_USED_H}${RESET} used of ${BOLD}${PART_SIZE_H}${RESET}  │  ${BOLD}${PART_FREE_H}${RESET} free  $(badge $PART_PCT)"
    echo -e "     ${DIM}$(printf '%.0s─' {1..70})${RESET}"
    printf "     ${BOLD}${BLUE}%-35s %-10s %s${RESET}\n" "SUBDIRECTORY" "SIZE" "SHARE OF PARTITION"
    echo -e "     ${DIM}$(printf '%.0s·' {1..70})${RESET}"

    # Report
    {
    echo
    printf '%.0s-' {1..70}; echo
    printf "  Directory : %s   (on partition %s)\n" "$DIR" "$PART_MNT"
    printf "  Usage     : %s  %s used of %s  |  %s free\n" \
           "$(txt_bar $PART_PCT)" "$PART_USED_H" "$PART_SIZE_H" "$PART_FREE_H"
    printf "  Status    : %s\n" "$(txt_badge $PART_PCT)"
    printf '%.0s-' {1..70}; echo
    printf "  %-35s %-10s %s\n" "SUBDIRECTORY" "SIZE" "SHARE OF PARTITION"
    printf '%.0s·' {1..70}; echo
    } >> "$REPORT_FILE"

    SUBDIR_DATA=$(du -skx "${DIR%/}"/* 2>/dev/null | sort -rn | head -n "$TOP_N")

    if [ -z "$SUBDIR_DATA" ]; then
        echo -e "     ${DIM}  (no subdirectories found or permission denied)${RESET}"
        printf "  (no subdirectories found or permission denied)\n" >> "$REPORT_FILE"
    else
        while IFS=$'\t' read -r kb path; do
            SIZE_H=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
            SUB_PCT=$(dir_pct_of_partition "$kb" "$PART_KB")
            [ "$SUB_PCT" -gt 100 ] && SUB_PCT=100
            NAME=$(basename "$path")
            [ ${#NAME} -gt 33 ] && NAME="${NAME:0:30}..."
            # Terminal
            printf "     ${CYAN}%-35s${RESET} ${BOLD}%-10s${RESET} %b ${DIM}%3s%%${RESET}\n" \
                   "$NAME" "$SIZE_H" "$(mini_bar $SUB_PCT)" "$SUB_PCT"
            # Report
            printf "  %-35s %-10s |%-15s| %3s%%\n" \
                   "$NAME" "$SIZE_H" "$(printf '%.0s#' $(seq 1 $(( SUB_PCT * 15 / 100 ))))" "$SUB_PCT" >> "$REPORT_FILE"
        done <<< "$SUBDIR_DATA"
    fi

    DIR_TOTAL=$(du -sh "$DIR" 2>/dev/null | awk '{print $1}')
    echo -e "     ${DIM}$(printf '%.0s·' {1..70})${RESET}"
    printf "     ${BOLD}%-35s ${MAGENTA}%-10s${RESET}\n" "Total used in ${DIR}" "${DIR_TOTAL}"

    {
    printf '%.0s·' {1..70}; echo
    printf "  %-35s %s\n" "Total used in ${DIR}" "${DIR_TOTAL}"
    } >> "$REPORT_FILE"

done

echo

# ─────────────────────────────────────────────────────────────
# SECTION 3 — ALERT SUMMARY
# ─────────────────────────────────────────────────────────────
echo -e "${BOLD}${BG_BLUE}${WHITE}  ── ALERT SUMMARY ─────────────────────────────────────────────  ${RESET}"
echo

{
echo
printf '=%.0s' {1..70}; echo
printf "  SECTION 3 — ALERT SUMMARY\n"
printf '=%.0s' {1..70}; echo
} >> "$REPORT_FILE"

if [ "${#ALERTS[@]}" -gt 0 ]; then
    echo -e "  ${RED}${BOLD}🚨  ${#ALERTS[@]} partition(s) require attention:${RESET}"
    echo
    printf "  %s partition(s) require attention:\n" "${#ALERTS[@]}" >> "$REPORT_FILE"
    echo >> "$REPORT_FILE"
    for entry in "${ALERTS[@]}"; do
        IFS='|' read -r pct dir used size <<< "$entry"
        if [ "$pct" -ge "$CRIT_THRESHOLD" ]; then
            ICON="🔴"; LVL="${RED}${BOLD}CRITICAL${RESET}"
        else
            ICON="🟡"; LVL="${YELLOW}${BOLD}WARNING ${RESET}"
        fi
        echo -e "  ${ICON}  ${LVL}  ${BOLD}${dir}${RESET}  →  ${used} / ${size}  (${pct}% used)"
        printf "  %s  %-12s  %-15s  %s used of %s  (%s%% used)\n" \
               "$(txt_badge $pct)" "" "$dir" "$used" "$size" "$pct" >> "$REPORT_FILE"
    done
    echo
    echo -e "  ${DIM}💡 Run: du -sh /path/* 2>/dev/null | sort -rh | head -20${RESET}"
    {
    echo
    printf "  Tip: du -sh /path/* 2>/dev/null | sort -rh | head -20\n"
    } >> "$REPORT_FILE"
else
    echo -e "  ${GREEN}${BOLD}✅  All monitored directories are within safe limits.${RESET}"
    printf "  [OK] All monitored directories are within safe limits.\n" >> "$REPORT_FILE"
fi

{
echo
printf '=%.0s' {1..70}; echo
printf "  END OF REPORT — %s\n" "$TIMESTAMP"
printf '=%.0s' {1..70}; echo
} >> "$REPORT_FILE"

# symlink latest report
ln -sf "$REPORT_FILE" "$LATEST_LINK"

echo
echo -e "${BOLD}${CYAN}╚$(printf '%.0s═' {1..66})╝${RESET}"
echo

# ─────────────────────────────────────────────────────────────
# REPORT SAVE CONFIRMATION
# ─────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}📄  Report saved:${RESET}"
echo -e "    ${BOLD}${GREEN}${REPORT_FILE}${RESET}"
echo -e "    ${DIM}(also available as: ${LATEST_LINK})${RESET}"
echo
echo -e "${DIM}  To view:  cat ${LATEST_LINK}${RESET}"
echo -e "${DIM}  To tail:  tail -f ${LATEST_LINK}${RESET}"
echo -e "${DIM}  Schedule: crontab -e  →  0 8 * * * $(realpath "$0")${RESET}"
echo
