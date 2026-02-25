#!/bin/bash
# ═══════════════════════════════════════════════
#   SYSTEM MONITOR DASHBOARD — AI Prasul :-P
# ═══════════════════════════════════════════════

R="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

RED="\033[38;5;196m"
RED_S="\033[38;5;203m"
GREEN="\033[38;5;82m"
GREEN_S="\033[38;5;114m"
YELLOW="\033[38;5;220m"
CYAN="\033[38;5;45m"
CYAN_S="\033[38;5;80m"
BLUE_D="\033[38;5;27m"
MAGENTA="\033[38;5;171m"
ORANGE="\033[38;5;214m"
WHITE="\033[38;5;255m"
GRAY="\033[38;5;244m"
DGRAY="\033[38;5;238m"
BG_HEADER="\033[48;5;18m"
BG_ALERT="\033[48;5;52m"
BLINK="\033[5m"

ACCESSLOG_PATH="/home/nginx/domains/*/log/access.log"
SLOWLOG="/var/log/php-fpm/www-slow.log"
IP_STATE_FILE="/tmp/ip_counts.state"
touch "$IP_STATE_FILE"
FILE_CACHE="/tmp/recent_file_changes.cache"
LAST_FILE_SCAN=0
SCAN_INTERVAL=900  # 900 seconds = 15 minutes

# ══════════════════════════════════════════════════════
#  LAYOUT CONFIG — all column math in one place
#  Change numbers here and everything adjusts globally
# ══════════════════════════════════════════════════════
TW=$(tput cols 2>/dev/null || echo 120)
HALF=$(( TW / 2 - 1 ))

# Two-column layout widths (must fit inside HALF)
COL_PROC_N=4       # process rank number
COL_PROC_NAME=26   # process name
COL_PROC_PCT=6     # cpu/mem %

COL_NET_STATE=24   # network state
COL_NET_COUNT=6    # connection count

COL_IP_HITS=10     # ip hit count
COL_IP_ADDR=28     # ip address
COL_IP_DELTA=8     # delta indicator

COL_URL_HITS=8     # url hit count
COL_URL_DOM=22     # domain
COL_URL_PATH=28    # url path

COL_WL_HITS=6      # wp-login hits
COL_WL_DOM=22      # domain
COL_WL_IP=26       # ip
COL_WL_METHOD=8    # method
COL_WL_TIME=14     # timestamp

COL_SLOW_COUNT=8   # slowlog count
COL_SLOW_DOM=26    # domain
COL_SLOW_PLUGIN=22 # plugin name

COL_VEL_HITS=6     # velocity hits
COL_VEL_DOM=22     # domain
COL_VEL_IP=28      # ip
COL_VEL_STATUS=8   # status

COL_FC_DOM=20      # file change domain
COL_FC_TYPE=7      # plugin/theme label
COL_FC_COUNT=6     # number of files changed
COL_FC_PLUGIN=28   # plugin or theme folder name
# last modified (most recent) gets the remainder

# MySQL full-width query wrap (full width minus indent and border char)
COL_MYSQL_ID=8
COL_MYSQL_DB=22
COL_MYSQL_TIME=6
COL_MYSQL_STATE=16
COL_MYSQL_QUERY=$(( TW - COL_MYSQL_ID - COL_MYSQL_DB - COL_MYSQL_TIME - COL_MYSQL_STATE - 10 ))
[ "$COL_MYSQL_QUERY" -lt 40 ] && COL_MYSQL_QUERY=40

# ── Full-width line ───────────────────────────────
hline() {
    local char="${1:- }" color="${2:-$DGRAY}"
    local line=""
    for ((i=0; i<TW; i++)); do line+="$char"; done
    printf "${color}%s${R}\n" "$line"
}

# ── Column divider character ──────────────────────
VBAR="${DGRAY}|${R}"

# ── Color a percentage value (integer-safe) ───────
color_pct() {
    local val="${1%.*}" hi="${2:-50}" med="${3:-20}"
    if   [ "${val:-0}" -ge "$hi"  ] 2>/dev/null; then printf "${RED}${BOLD}"
    elif [ "${val:-0}" -ge "$med" ] 2>/dev/null; then printf "${ORANGE}"
    else printf "${GREEN_S}"
    fi
}

# ══════════════════════════════════════════════════
# render_two_cols FILE_LEFT FILE_RIGHT
#   Merges two files side-by-side, ANSI-aware padding
# ══════════════════════════════════════════════════
render_two_cols() {
    local left="$1" right="$2"
    local col_w="$HALF"

    awk -v col="$col_w" '
    function strip(s,    r) {
        r = s
        while (match(r, /\033\[[0-9;]*m/)) {
            r = substr(r,1,RSTART-1) substr(r,RSTART+RLENGTH)
        }
        return r
    }
    function pad_to(s, w,    pl, spaces) {
        pl = length(strip(s))
        spaces = w - pl
        if (spaces < 0) spaces = 0
        return s sprintf("%" spaces "s", "")
    }
    BEGIN { i = 0; j = 0 }
    FILENAME == ARGV[1] { left[++i]  = $0; next }
    FILENAME == ARGV[2] { right[++j] = $0 }
    END {
        n = (i > j) ? i : j
        for (k = 1; k <= n; k++) {
            l = (k <= i) ? left[k]  : ""
            r = (k <= j) ? right[k] : ""
            printf "%s  \033[38;5;238m│\033[0m  %s\n", pad_to(l, col), r
        }
    }
    ' "$left" "$right"
}

# ════════════════════════════════════════════════
while true; do
    clear

    NOW=$(date "+%A, %d %b %Y  %H:%M:%S")
    HOST=$(hostname -s 2>/dev/null || echo "server")
    UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up //' || uptime | awk '{print $3,$4}' | tr -d ',')
    LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | xargs)

    # ══════════════════════════════════════════════
    #  DISK WARNING — check before header renders
    #  Shows a full-width alert banner if any mount
    #  is at or above 98% used
    # ══════════════════════════════════════════════
    DISK_WARN=""
    while read -r pct mount; do
        pct_num="${pct%%%}"   # strip the % sign
        if [ "${pct_num:-0}" -ge 98 ] 2>/dev/null; then
            DISK_WARN="${DISK_WARN}${mount} at ${pct}  "
        fi
    done < <(df -h --output=pcent,target 2>/dev/null | awk 'NR>1 && $1!="Use%"')

    # ── HEADER ───────────────────────────────────
    hline '═' "$BLUE_D"
    hdr_left="  🖥  SYSTEM MONITOR DASHBOARD"
    pad=$(( TW - ${#hdr_left} - ${#NOW} - 4 ))
    [ "$pad" -lt 1 ] && pad=1
    printf "${BG_HEADER}${CYAN}${BOLD}%s%*s${YELLOW}%s  ${R}\n" "$hdr_left" "$pad" "" "$NOW"
    hline '═' "$BLUE_D"

    # ── DISK WARNING BANNER (shown only when triggered) ──
    if [ -n "$DISK_WARN" ]; then
        hline '█' "$BG_ALERT"
        # Center the warning text
        warn_txt="  ⚠  CRITICAL DISK USAGE:  ${DISK_WARN}"
        warn_pad=$(( (TW - ${#warn_txt}) / 2 ))
        [ "$warn_pad" -lt 0 ] && warn_pad=0
        printf "${BG_ALERT}${RED}${BOLD}${BLINK}%*s%s%*s${R}\n" \
            "$warn_pad" "" "$warn_txt" "$warn_pad" ""
        hline '█' "$BG_ALERT"
    fi

    printf "\n"
    printf "  ${DGRAY}◆ HOST:${R}  ${WHITE}${BOLD}%-24s${R}  " "$HOST"
    printf "${DGRAY}◆ UPTIME:${R} ${WHITE}${BOLD}%-26s${R}  " "$UPTIME_STR"
    printf "${DGRAY}◆ LOAD AVG:${R} ${WHITE}${BOLD}%s${R}\n\n" "$LOAD_AVG"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 1: CPU (left) | Memory (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — CPU
    {
        printf "${YELLOW}${BOLD}  ▶  TOP CPU PROCESSES${R}\n"
        printf "  ${DGRAY}%-${COL_PROC_N}s %-${COL_PROC_NAME}s %s${R}\n" "#" "PROCESS" "CPU%"
        printf "  ${DGRAY}%-${COL_PROC_N}s %-${COL_PROC_NAME}s %s${R}\n" "──" "─────────────────────────" "────"
        n=0
        ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=7{print $1,$2}' | \
        while read -r proc pct; do
            n=$((n+1))
            pc=$(color_pct "$pct" 50 20)
            printf "  ${GRAY}%2d${R}  ${WHITE}%-${COL_PROC_NAME}.${COL_PROC_NAME}s${R}  ${pc}%s%%${R}\n" \
                "$n" "$proc" "$pct"
        done
    } > "$C1"

    # RIGHT — Memory
    {
        printf "${YELLOW}${BOLD}  ▶  TOP MEMORY PROCESSES${R}\n"
        printf "  ${DGRAY}%-${COL_PROC_N}s %-${COL_PROC_NAME}s %s${R}\n" "#" "PROCESS" "MEM%"
        printf "  ${DGRAY}%-${COL_PROC_N}s %-${COL_PROC_NAME}s %s${R}\n" "──" "─────────────────────────" "────"
        m=0
        ps -eo comm,%mem --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=7{print $1,$2}' | \
        while read -r proc pct; do
            m=$((m+1))
            mc=$(color_pct "$pct" 20 10)
            printf "  ${GRAY}%2d${R}  ${WHITE}%-${COL_PROC_NAME}.${COL_PROC_NAME}s${R}  ${mc}%s%%${R}\n" \
                "$m" "$proc" "$pct"
        done
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 2: Network (left) | Top IPs (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — Network
    {
        printf "${CYAN}${BOLD}  ▶  NETWORK CONNECTIONS${R}\n"
        printf "  ${DGRAY}%-${COL_NET_STATE}s %s${R}\n" "STATE" "COUNT"
        printf "  ${DGRAY}%-${COL_NET_STATE}s %s${R}\n" "───────────────────────" "─────"
        netstat -ant 2>/dev/null | awk '{print $6}' \
            | grep -v 'State\|Foreign\|^$' \
            | sort | uniq -c | sort -nr | head -8 | \
        while read -r cnt state; do
            [ -z "$state" ] && continue
            case "$state" in
                ESTABLISHED) sc="${GREEN}" ;;
                SYN_RECV)    sc="${RED}${BOLD}" ;;
                TIME_WAIT)   sc="${ORANGE}" ;;
                CLOSE_WAIT)  sc="${YELLOW}" ;;
                LISTEN)      sc="${CYAN_S}" ;;
                FIN_WAIT*)   sc="${MAGENTA}" ;;
                *)           sc="${GRAY}" ;;
            esac
            printf "  ${sc}%-${COL_NET_STATE}s${R}  ${WHITE}%s${R}\n" "$state" "$cnt"
        done

        syn_count=$(netstat -ant 2>/dev/null | grep -c "SYN_RECV" | head -n1)
        : "${syn_count:=0}"
        if [ "$syn_count" -gt 20 ]; then
            printf "\n  ${RED}${BOLD}${BLINK}⚠ SYN FLOOD: %s conns!${R}\n" "$syn_count"
        fi
    } > "$C1"

    # RIGHT — Top IPs
    {
        printf "${CYAN}${BOLD}  ▶  TOP IPs & TRAFFIC SPIKES${R}\n"
        printf "  ${DGRAY}%-${COL_IP_HITS}s %-${COL_IP_ADDR}s %s${R}\n" "HITS" "IP ADDRESS" "Δ"
        printf "  ${DGRAY}%-${COL_IP_HITS}s %-${COL_IP_ADDR}s %s${R}\n" "────────" "────────────────────────────" "──────"
        new_state=$(mktemp)
        awk '{print $1}' $ACCESSLOG_PATH 2>/dev/null | sort | uniq -c | sort -nr | head -8 | \
        while read -r count ip; do
            [ -z "$ip" ] && continue
            echo "$ip $count" >> "$new_state"
            prev=$(grep "^$ip " "$IP_STATE_FILE" 2>/dev/null | awk '{print $2}')
            if [ -n "$prev" ]; then
                diff=$((count - prev))
                if   [ "$diff" -gt 100 ]; then chg="${RED}${BOLD}↑+${diff}${R}"
                elif [ "$diff" -gt   0 ]; then chg="${ORANGE}↑+${diff}${R}"
                elif [ "$diff" -lt   0 ]; then chg="${GREEN_S}↓${diff}${R}"
                else chg="${DGRAY}—${R}"
                fi
            else
                chg="${CYAN}${BOLD}NEW${R}"
            fi
            printf "  ${ORANGE}%-${COL_IP_HITS}s${R}  ${CYAN_S}%-${COL_IP_ADDR}.${COL_IP_ADDR}s${R}  %b\n" \
                "$count" "$ip" "$chg"
        done
        mv "$new_state" "$IP_STATE_FILE" 2>/dev/null
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 3: Top URLs (left) | PHP Slowlog (right)
    #  MySQL is now its own FULL-WIDTH block below
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — Top URLs
    {
        printf "${YELLOW}${BOLD}  ▶  TOP URLs BY DOMAIN${R}\n"
        printf "  ${DGRAY}%-${COL_URL_HITS}s %-${COL_URL_DOM}s %s${R}\n" "HITS" "DOMAIN" "URL"
        printf "  ${DGRAY}%-${COL_URL_HITS}s %-${COL_URL_DOM}s %s${R}\n" "──────" "────────────────────" "──────────────────────────"
        url_temp=$(mktemp)
        for logfile in $ACCESSLOG_PATH; do
            [ -f "$logfile" ] || continue
            domain=$(echo "$logfile" | awk -F'/' '{print $5}')
            awk -v dom="$domain" '{print dom, $7}' "$logfile" >> "$url_temp" 2>/dev/null
        done
        sort "$url_temp" | uniq -c | sort -nr | head -10 | \
        awk -v o="${ORANGE}" -v g="${GREEN_S}" -v c="${CYAN_S}" -v r="${R}" \
            -v h="$COL_URL_HITS" -v d="$COL_URL_DOM" -v u="$COL_URL_PATH" \
            '{printf "  %s%-"h"s%s  %s%-"d"."d"s%s  %s%-"u"."u"s%s\n", o,$1,r, g,$2,r, c,$3,r}'
        rm -f "$url_temp"
    } > "$C1"

    # RIGHT — PHP Slowlog
    {
        if [ -f "$SLOWLOG" ]; then
            printf "${RED_S}${BOLD}  ▶  PHP SLOWLOG — TOP CULPRITS${R}\n"
            printf "  ${DGRAY}%-${COL_SLOW_COUNT}s %-${COL_SLOW_DOM}s %s${R}\n" "COUNT" "DOMAIN" "PLUGIN"
            printf "  ${DGRAY}%-${COL_SLOW_COUNT}s %-${COL_SLOW_DOM}s %s${R}\n" "──────" "────────────────────────" "──────────────────────"
            grep "wp-content/plugins/" "$SLOWLOG" | \
            sed -rn 's/.*\/domains\/([^/]+)\/.*plugins\/([^/ ]+).*/\1 \2/p' | \
            sort | uniq -c | sort -nr | head -8 | \
            awk -v o="${ORANGE}" -v g="${GREEN_S}" -v rs="${RED_S}" -v r="${R}" \
                -v sc="$COL_SLOW_COUNT" -v sd="$COL_SLOW_DOM" -v sp="$COL_SLOW_PLUGIN" \
                '{printf "  %s%-"sc"s%s  %s%-"sd"."sd"s%s  %s%-"sp"."sp"s%s\n", o,$1,r, g,$2,r, rs,$3,r}'
        else
            printf "${GRAY}${DIM}  ▶  PHP SLOWLOG${R}\n"
            printf "  ${GRAY}${DIM}(slowlog not found at configured path)${R}\n"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 4: WP-Login (left) | Live Traffic (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — WP-Login
    {
        wplogin_raw=$(grep "wp-login.php" $ACCESSLOG_PATH 2>/dev/null)
        if [ -n "$wplogin_raw" ]; then
            printf "${RED}${BOLD}${BLINK}  ⚠  WP-LOGIN.PHP DETECTED${R}\n"
            printf "  ${DGRAY}%-${COL_WL_HITS}s %-${COL_WL_DOM}s %-${COL_WL_IP}s %-${COL_WL_METHOD}s %s${R}\n" \
                "HITS" "DOMAIN" "IP" "METHOD" "LAST SEEN"
            printf "  ${DGRAY}%-${COL_WL_HITS}s %-${COL_WL_DOM}s %-${COL_WL_IP}s %-${COL_WL_METHOD}s %s${R}\n" \
                "────" "────────────────────" "──────────────────────────" "──────" "──────────────"
            echo "$wplogin_raw" | awk '{
                match($0, /access\.log:/);
                if (RSTART > 0) {
                    filename = substr($0, 1, RSTART+9);
                    split(filename, p, "/"); domain = p[5];
                    content = substr($0, RSTART+10);
                    split(content, parts, " "); ip = parts[1];
                    ts = $4; gsub(/\[/, "", ts);
                    method = $6; gsub(/\042/, "", method);
                    print domain, ip, ts, method
                }
            }' | sort -k1,1 -k2,2 -k3,3r | awk '
                !seen[$1,$2,$4]++ { count[$1,$2,$4]=1; last_ts[$1,$2,$4]=$3 }
                seen[$1,$2,$4]>1  { count[$1,$2,$4]++ }
                END {
                    for (i in count) {
                        split(i, sep, SUBSEP)
                        print count[i], sep[1], sep[2], sep[3], last_ts[i]
                    }
                }' | sort -nr | head -8 | \
            while read -r hits domain ip method ts; do
                [ "$method" = "POST" ] && mfmt="${RED}${BOLD}[POST]${R}" || mfmt="${GREEN_S}[GET] ${R}"
                printf "  ${ORANGE}%-${COL_WL_HITS}s${R}  ${GREEN_S}%-${COL_WL_DOM}.${COL_WL_DOM}s${R}  ${CYAN_S}%-${COL_WL_IP}.${COL_WL_IP}s${R}  %b  ${GRAY}%s${R}\n" \
                    "$hits" "$domain" "$ip" "$mfmt" "$ts"
            done
        else
            printf "${GREEN_S}${BOLD}  ✔  WP-LOGIN.PHP${R}\n"
            printf "  ${GREEN_S}No suspicious activity detected.${R}\n"
        fi
    } > "$C1"

    # RIGHT — LIVE TRAFFIC VELOCITY
    {
        printf "${CYAN}${BOLD}  ▶  LIVE TRAFFIC VELOCITY (REAL-TIME 20s WINDOW)${R}\n"
        printf "  ${DGRAY}%-${COL_VEL_HITS}s %-${COL_VEL_DOM}s %-${COL_VEL_IP}s %s${R}\n" \
            "HITS" "DOMAIN" "IP ADDRESS" "STATUS/Δ"
        printf "  ${DGRAY}%-${COL_VEL_HITS}s %-${COL_VEL_DOM}s %-${COL_VEL_IP}s %s${R}\n" \
            "────" "────────────────────" "──────────────────────────" "────────"

        LIVE_STATE="/tmp/live_velocity.state"
        NEW_LIVE_STATE=$(mktemp)
        CUR_MIN=$(date "+%d/%b/%Y:%H:%M")

        for log in $ACCESSLOG_PATH; do
            [ -f "$log" ] || continue
            dom=$(echo "$log" | awk -F'/' '{print $5}')
            tail -n 200 "$log" | grep "$CUR_MIN" | awk -v d="$dom" '{print d, $1}' >> "$NEW_LIVE_STATE"
        done

        if [ -s "$NEW_LIVE_STATE" ]; then
            sort "$NEW_LIVE_STATE" | uniq -c | sort -nr | head -8 | while read -r count dom ip; do
                [ -z "$ip" ] && continue
                prev_live=$(grep "$dom $ip" "$LIVE_STATE" 2>/dev/null | awk '{print $1}')
                if [ -n "$prev_live" ] && [ "$prev_live" -eq "$prev_live" ] 2>/dev/null; then
                    diff=$((count - prev_live))
                    if   [ "$diff" -gt 3 ]; then v_chg="${RED}${BOLD}↑+${diff}${R}"
                    elif [ "$diff" -lt 0 ]; then v_chg="${GREEN_S}↓${diff}${R}"
                    else v_chg="${DGRAY}steady${R}"
                    fi
                else
                    v_chg="${BLUE_D}ACTIVE${R}"
                fi
                printf "  ${ORANGE}%-${COL_VEL_HITS}s${R}  ${GREEN_S}%-${COL_VEL_DOM}.${COL_VEL_DOM}s${R}  ${CYAN_S}%-${COL_VEL_IP}.${COL_VEL_IP}s${R}  %b\n" \
                    "$count" "$dom" "$ip" "$v_chg"
                echo "$count $dom $ip" >> "${NEW_LIVE_STATE}.final"
            done
            mv "${NEW_LIVE_STATE}.final" "$LIVE_STATE" 2>/dev/null
        else
            printf "  ${GRAY}${DIM}(waiting for new traffic...)${R}\n"
        fi
        rm -f "$NEW_LIVE_STATE"
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 5: MYSQL ACTIVE PROCESSES — FULL WIDTH
    #
    #  MySQL gets its own full-width block because
    #  query text is too long for a half-column.
    #  Each process shows a summary line then the
    #  full query wrapped to terminal width.
    # ════════════════════════════════════════════
    {
        printf "${MAGENTA}${BOLD}  ▶  MYSQL ACTIVE PROCESSES${R}\n"
        printf "  ${DGRAY}%-${COL_MYSQL_ID}s %-${COL_MYSQL_DB}s %-${COL_MYSQL_TIME}s %-${COL_MYSQL_STATE}s %s${R}\n" \
            "ID" "DATABASE" "TIME" "STATE" "QUERY PREVIEW"
        printf "  ${DGRAY}%-${COL_MYSQL_ID}s %-${COL_MYSQL_DB}s %-${COL_MYSQL_TIME}s %-${COL_MYSQL_STATE}s %s${R}\n" \
            "────────" "──────────────────────" "──────" "────────────────" "$(printf '─%.0s' $(seq 1 $COL_MYSQL_QUERY))"

        mysql_out=$(mysql --batch --silent -e "
            SELECT
                ID,
                IFNULL(DB, 'system')    AS DB,
                TIME,
                IFNULL(STATE, '')       AS STATE,
                IFNULL(INFO, '')        AS INFO
            FROM information_schema.PROCESSLIST
            WHERE COMMAND != 'Sleep'
              AND INFO IS NOT NULL
            ORDER BY TIME DESC
            LIMIT 8;" 2>/dev/null)

        if [ -z "$mysql_out" ]; then
            printf "  ${GRAY}${DIM}(no active queries)${R}\n"
        else
            # Use process substitution so IFS=$'\t' applies cleanly per-line
            while IFS=$'\t' read -r id db time state query; do
                [[ "$id" == "ID" ]] && continue
                [ -z "$id" ]        && continue

                # Time colouring: red ≥ 5s, orange otherwise
                if [ "${time:-0}" -ge 5 ] 2>/dev/null; then
                    tc="\033[38;5;196m"   # red
                else
                    tc="\033[38;5;214m"   # orange
                fi

                # ── Summary line: ID  DB  TIME  STATE ──────────────
                printf "  \033[38;5;244m%-${COL_MYSQL_ID}s\033[0m" "$id"
                printf " \033[38;5;82m%-${COL_MYSQL_DB}.${COL_MYSQL_DB}s\033[0m" "$db"
                printf " ${tc}%-${COL_MYSQL_TIME}s\033[0m" "${time}s"
                printf " \033[38;5;45m%-${COL_MYSQL_STATE}.${COL_MYSQL_STATE}s\033[0m\n" "$state"

                # ── Full query, word-wrapped at COL_MYSQL_QUERY ──────
                # Normalize whitespace: collapse newlines/tabs to single space
                clean_query=$(echo "$query" | tr '\n\t' '  ' | tr -s ' ')
                echo "$clean_query" | fold -s -w "$COL_MYSQL_QUERY" | \
                while IFS= read -r qline; do
                    printf "  \033[38;5;240m│\033[0m \033[38;5;255m%s\033[0m\n" "$qline"
                done

                # ── Per-process separator ────────────────────────────
                printf "  \033[38;5;237m%s\033[0m\n" \
                    "$(printf '╌%.0s' $(seq 1 $(( TW - 4 ))))"
            done <<< "$mysql_out"
        fi
    }
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 6: FILE CHANGES (left) | (spare right)
    #  File cache is scanned every SCAN_INTERVAL
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    {
        CUR_TIME=$(date +%s)

        if (( CUR_TIME - LAST_FILE_SCAN > SCAN_INTERVAL )); then

            # Pass 1 — collect every changed file into a flat tsv:
            #   domain <TAB> type <TAB> plugin <TAB> mod_datetime
            find /home/nginx/domains/*/public/wp-content/{plugins,themes} \
                -maxdepth 3 -mmin -1440 -type f \
                \( -name "*.php" -o -name "*.js" \) 2>/dev/null \
            | while IFS= read -r filepath; do
                dom=$(echo   "$filepath" | cut -d'/' -f5)
                ftype=$(echo "$filepath" | cut -d'/' -f8)
                plugin=$(echo "$filepath" | cut -d'/' -f9)
                mod=$(stat -c "%y" "$filepath" 2>/dev/null | cut -d'.' -f1)
                printf "%s\t%s\t%s\t%s\n" "$dom" "$ftype" "$plugin" "$mod"
            done \
            | awk -F'\t' '
            {
                key = $1 "\t" $2 "\t" $3    # domain + type + plugin name
                count[key]++
                # keep the latest mod time per plugin
                if ($4 > latest[key]) latest[key] = $4
            }
            END {
                for (k in count) {
                    split(k, p, "\t")
                    # p[1]=domain  p[2]=type  p[3]=plugin
                    printf "%s\t%s\t%s\t%d\t%s\n", p[1], p[2], p[3], count[k], latest[k]
                }
            }' \
            | sort -t$'\t' -k5,5r \
            | head -12 > "$FILE_CACHE"

            LAST_FILE_SCAN=$CUR_TIME
        fi

        printf "${ORANGE}${BOLD}  ▶  FILE CHANGES (Last 24h — Scanned every 15m)${R}\n"
        printf "  ${DGRAY}%-${COL_FC_DOM}s %-${COL_FC_TYPE}s %-${COL_FC_COUNT}s %-${COL_FC_PLUGIN}s %s${R}\n" \
            "DOMAIN" "TYPE" "FILES" "PLUGIN / THEME" "LAST MODIFIED"
        printf "  ${DGRAY}%-${COL_FC_DOM}s %-${COL_FC_TYPE}s %-${COL_FC_COUNT}s %-${COL_FC_PLUGIN}s %s${R}\n" \
            "$(printf '─%.0s' $(seq 1 $COL_FC_DOM))" \
            "$(printf '─%.0s' $(seq 1 $COL_FC_TYPE))" \
            "$(printf '─%.0s' $(seq 1 $COL_FC_COUNT))" \
            "$(printf '─%.0s' $(seq 1 $COL_FC_PLUGIN))" \
            "───────────────────"

        if [ -s "$FILE_CACHE" ]; then
            while IFS=$'\t' read -r dom ftype plugin count modtime; do
                if [ "$ftype" = "plugins" ]; then
                    t_col="\033[38;5;45m";  t_label="Plugin"
                else
                    t_col="\033[38;5;171m"; t_label="Theme"
                fi

                # Colour the file count: orange if > 5 files changed, green otherwise
                if [ "${count:-0}" -gt 5 ] 2>/dev/null; then
                    c_col="\033[38;5;214m"
                else
                    c_col="\033[38;5;82m"
                fi

                printf "  \033[38;5;114m%-${COL_FC_DOM}.${COL_FC_DOM}s\033[0m ${t_col}%-${COL_FC_TYPE}s\033[0m ${c_col}%-${COL_FC_COUNT}s\033[0m \033[38;5;220m%-${COL_FC_PLUGIN}.${COL_FC_PLUGIN}s\033[0m \033[38;5;244m%s\033[0m\n" \
                    "$dom" "$t_label" "$count" "$plugin" "$modtime"
            done < "$FILE_CACHE"
        else
            printf "  ${GRAY}${DIM}(no changes detected in the last 24h)${R}\n"
        fi
    } > "$C1"

    # Right column can be used for future blocks; blank for now
    printf "" > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"

    # ════════════════════════════════════════════
    #  BLOCK 7: NGINX ERROR LOG MONITOR — FULL WIDTH
    #
    #  Reads the last 200 lines of each domain's
    #  error.log, groups by error type + request,
    #  shows delta (+N) vs previous refresh cycle,
    #  and highlights the client IP and snippet.
    # ════════════════════════════════════════════
    {
        # Compute snippet column width from what's left after fixed columns
        COL_ERR_SNIPPET=$(( TW - COL_ERR_DOM - COL_ERR_TIME - COL_ERR_DELTA - COL_ERR_CLIENT - COL_ERR_REQ - 16 ))
        [ "$COL_ERR_SNIPPET" -lt 30 ] && COL_ERR_SNIPPET=30

        printf "${RED_S}${BOLD}  ▶  NGINX ERROR LOG MONITOR${R}\n"
        printf "  ${DGRAY}%-${COL_ERR_DOM}s %-${COL_ERR_TIME}s %-${COL_ERR_DELTA}s %-${COL_ERR_CLIENT}s %-${COL_ERR_REQ}s %s${R}\n" \
            "DOMAIN" "LAST SEEN" "Δ NEW" "CLIENT IP" "REQUEST" "ERROR SNIPPET"
        printf "  ${DGRAY}%-${COL_ERR_DOM}s %-${COL_ERR_TIME}s %-${COL_ERR_DELTA}s %-${COL_ERR_CLIENT}s %-${COL_ERR_REQ}s %s${R}\n" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_DOM))" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_TIME))" \
            "──────" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_CLIENT))" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_REQ))" \
            "$(printf '─%.0s' $(seq 1 $COL_ERR_SNIPPET))"

        NEW_ERR_STATE=$(mktemp)
        found_any=0

        for errlog in $ERRORLOG_PATH; do
            [ -f "$errlog" ] || continue

            # Extract domain from path: /home/nginx/domains/DOMAIN/log/error.log
            domain=$(echo "$errlog" | cut -d'/' -f5)

            # Parse the last 200 lines — each line format:
            # 2026/02/25 00:11:51 [error] PID#TID: *ID MESSAGE, client: IP, server: DOMAIN, request: "METHOD PATH PROTO", host: "HOST"
            tail -n 200 "$errlog" 2>/dev/null | awk '
            /\[error\]/ {
                # ── Timestamp ──────────────────────────────────
                ts = $1 " " $2

                # ── Error snippet: everything after the *ID ────
                # Field 5 onwards is the message; strip the *NNN prefix
                snippet = ""
                for (i=5; i<=NF; i++) snippet = snippet " " $i
                sub(/^ \*[0-9]+ /, "", snippet)

                # ── Client IP ──────────────────────────────────
                client = ""
                if (match(snippet, /client: ([0-9.]+|[0-9a-f:]+)/, arr)) {
                    client = arr[1]
                } else {
                    # fallback: find "client: X.X.X.X" manually
                    n = split(snippet, parts, ", ")
                    for (j=1; j<=n; j++) {
                        if (parts[j] ~ /^client:/) { client = parts[j]; sub(/^client: /,"",client); break }
                    }
                }

                # ── Request path ───────────────────────────────
                req = ""
                if (match(snippet, /request: "([^"]+)"/, arr2)) {
                    req = arr2[1]
                    # trim to METHOD + PATH only, drop HTTP version
                    sub(/ HTTP\/[0-9.]+$/, "", req)
                } else {
                    n2 = split(snippet, parts2, ", ")
                    for (j2=1; j2<=n2; j2++) {
                        if (parts2[j2] ~ /^request:/) { req = parts2[j2]; sub(/^request: "/,"",req); sub(/"$/,"",req); break }
                    }
                }

                # ── Core error message (strip trailing metadata) ─
                core = snippet
                sub(/, client:.*$/, "", core)
                gsub(/^[ \t]+|[ \t]+$/, "", core)

                # ── Key: domain + core error (dedup similar errors) ─
                key = client "|" req "|" core
                if (!(key in seen)) {
                    seen[key] = 1
                    latest_ts[key] = ts
                    client_ip[key]  = client
                    request[key]    = req
                    message[key]    = core
                } else {
                    if (ts > latest_ts[key]) latest_ts[key] = ts
                }
                total[key]++
            }
            END {
                for (k in seen) {
                    printf "%s\t%s\t%d\t%s\t%s\n", latest_ts[k], client_ip[k], total[k], request[k], message[k]
                }
            }' | sort -t$'\t' -k1,1r | head -6 | \
            while IFS=$'\t' read -r ts client cnt req msg; do
                found_any=1

                # Build state key for delta calculation
                state_key="${domain}|${client}|${req}"
                echo "${state_key}=${cnt}" >> "$NEW_ERR_STATE"

                # Delta vs last refresh
                prev_cnt=$(grep "^${state_key}=" "$ERRLOG_STATE" 2>/dev/null | cut -d'=' -f2)
                if [ -n "$prev_cnt" ] && [ "$prev_cnt" -ne "$cnt" ] 2>/dev/null; then
                    diff=$(( cnt - prev_cnt ))
                    if [ "$diff" -gt 0 ]; then
                        delta="${RED}${BOLD}+${diff}${R}"
                        age_label="${RED}${BOLD}NEW${R}"
                    else
                        delta="${GREEN_S}${diff}${R}"
                        age_label="${GRAY}OLD${R}"
                    fi
                elif [ -z "$prev_cnt" ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                    age_label="${ORANGE}${BOLD}NEW${R}"
                else
                    delta="${DGRAY}—${R}"
                    age_label="${DGRAY}—${R}"
                fi

                # Truncate message to snippet column width
                msg_short="${msg:0:$COL_ERR_SNIPPET}"

                printf "  \033[38;5;114m%-${COL_ERR_DOM}.${COL_ERR_DOM}s\033[0m" "$domain"
                printf " \033[38;5;244m%-${COL_ERR_TIME}.${COL_ERR_TIME}s\033[0m" "$ts"
                printf " %-${COL_ERR_DELTA}b" "$delta"
                printf " \033[38;5;203m%-${COL_ERR_CLIENT}.${COL_ERR_CLIENT}s\033[0m" "$client"
                printf " \033[38;5;45m%-${COL_ERR_REQ}.${COL_ERR_REQ}s\033[0m" "$req"
                printf " \033[38;5;255m%s\033[0m\n" "$msg_short"
            done
        done

        # Rotate state file so next refresh has fresh deltas
        [ -s "$NEW_ERR_STATE" ] && mv "$NEW_ERR_STATE" "$ERRLOG_STATE" || rm -f "$NEW_ERR_STATE"

        if [ "$found_any" -eq 0 ]; then
            printf "  ${GREEN_S}${DIM}(no errors found in nginx logs)${R}\n"
        fi
    }
    
    hline '─' "$DGRAY"

    # ── FOOTER ───────────────────────────────────
    printf "\n"
    hline '═' "$BLUE_D"
    printf "  ${GRAY}${DIM}Refreshing in ${R}${BOLD}${CYAN}20s${R}  ${DGRAY}•${R}  ${GRAY}${DIM}Ctrl+C to exit${R}\n"
    hline '═' "$BLUE_D"
    printf "\n"

    sleep 20
done
