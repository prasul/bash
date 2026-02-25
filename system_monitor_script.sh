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

# ── Terminal dimensions ──────────────────────────
TW=$(tput cols 2>/dev/null || echo 120)
HALF=$(( TW / 2 - 1 ))
COL_INNER=$(( HALF - 4 ))   # usable text width inside each column

# ── Full-width line ───────────────────────────────
#hline() {
#    local char="${1:- }" color="${2:-$DGRAY}"
#    printf "${color}"; printf '%*s' "$TW" '' | tr ' ' "$char"; printf "${R}\n"
#}

hline() {
    local char="${1:- }" color="${2:-$DGRAY}"
    local line=""
    # Build the line based on terminal width
    for ((i=0; i<TW; i++)); do line+="$char"; done
    printf "${color}%s${R}\n" "$line"
}

# ── Column divider character ──────────────────────
#VBAR="${DGRAY}│${R}"
VBAR="${DGRAY}|${R}"  # Use standard | instead of Unicode │

# ── Color a percentage value (integer-safe) ───────
color_pct() {
    local val="${1%.*}" hi="${2:-50}" med="${3:-20}"
    if   [ "${val:-0}" -ge "$hi"  ] 2>/dev/null; then printf "${RED}${BOLD}"
    elif [ "${val:-0}" -ge "$med" ] 2>/dev/null; then printf "${ORANGE}"
    else printf "${GREEN_S}"
    fi
}

# ═══════════════════════════════════════════════════
# render_two_cols FILE_LEFT FILE_RIGHT
#   Merges two files side-by-side, ANSI-aware padding
# ═══════════════════════════════════════════════════
render_two_cols() {
    local left="$1" right="$2"
    local col_w="$HALF"

    awk -v col="$col_w" -v vbar="${DGRAY}│${R}" '
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
    BEGIN {
        i = 0; j = 0
    }
    FILENAME == ARGV[1] { left[++i] = $0; next }
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

    # ── HEADER ───────────────────────────────────
    hline '═' "$BLUE_D"
    hdr_left="  🖥  SYSTEM MONITOR DASHBOARD"
    pad=$(( TW - ${#hdr_left} - ${#NOW} - 4 ))
    [ "$pad" -lt 1 ] && pad=1
    printf "${BG_HEADER}${CYAN}${BOLD}%s%*s${YELLOW}%s  ${R}\n" "$hdr_left" "$pad" "" "$NOW"
    hline '═' "$BLUE_D"
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
        printf "  ${DGRAY}%-4s %-26s %s${R}\n" "#" "PROCESS" "CPU%"
        printf "  ${DGRAY}%-4s %-26s %s${R}\n" "──" "─────────────────────────" "────"
        n=0
        ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=7{print $1,$2}' | \
        while read -r proc pct; do
            n=$((n+1))
            pc=$(color_pct "$pct" 50 20)
            printf "  ${GRAY}%2d${R}  ${WHITE}%-26.26s${R}  ${pc}%s%%${R}\n" "$n" "$proc" "$pct"
        done
    } > "$C1"

    # RIGHT — Memory
    {
        printf "${YELLOW}${BOLD}  ▶  TOP MEMORY PROCESSES${R}\n"
        printf "  ${DGRAY}%-4s %-26s %s${R}\n" "#" "PROCESS" "MEM%"
        printf "  ${DGRAY}%-4s %-26s %s${R}\n" "──" "─────────────────────────" "────"
        m=0
        ps -eo comm,%mem --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=7{print $1,$2}' | \
        while read -r proc pct; do
            m=$((m+1))
            mc=$(color_pct "$pct" 20 10)
            printf "  ${GRAY}%2d${R}  ${WHITE}%-26.26s${R}  ${mc}%s%%${R}\n" "$m" "$proc" "$pct"
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
        printf "  ${DGRAY}%-24s %s${R}\n" "STATE" "COUNT"
        printf "  ${DGRAY}%-24s %s${R}\n" "───────────────────────" "─────"
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
            printf "  ${sc}%-24s${R}  ${WHITE}%s${R}\n" "$state" "$cnt"
        done
        
        #syn_count=$(netstat -ant 2>/dev/null | grep -c "SYN_RECV" || echo 0)
        #if [ "${syn_count:-0}" -gt 20 ]; then
        #    printf "\n  ${RED}${BOLD}${BLINK}⚠ SYN FLOOD: %s conns!${R}\n" "$syn_count"
        #fi
        
        # We use head -n1 to ensure we only get one integer
        syn_count=$(netstat -ant 2>/dev/null | grep -c "SYN_RECV" | head -n1)
            : "${syn_count:=0}" # Default to 0 if empty
            if [ "$syn_count" -gt 20 ]; then
                printf "\n  ${RED}${BOLD}${BLINK}⚠ SYN FLOOD: %s conns!${R}\n" "$syn_count"
        fi
    } > "$C1"

    # RIGHT — Top IPs
    {
        printf "${CYAN}${BOLD}  ▶  TOP IPs & TRAFFIC SPIKES${R}\n"
        printf "  ${DGRAY}%-10s %-30s %s${R}\n" "HITS" "IP ADDRESS" "Δ"
        printf "  ${DGRAY}%-10s %-30s %s${R}\n" "────────" "────────────────────────────" "──────"
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
            printf "  ${ORANGE}%-10s${R}  ${CYAN_S}%-30.30s${R}  %b\n" "$count" "$ip" "$chg"
        done
        mv "$new_state" "$IP_STATE_FILE" 2>/dev/null
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 3: Top URLs (left) | MySQL (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — Top URLs
    {
        printf "${YELLOW}${BOLD}  ▶  TOP URLs BY DOMAIN${R}\n"
        printf "  ${DGRAY}%-8s %-22s %s${R}\n" "HITS" "DOMAIN" "URL"
        printf "  ${DGRAY}%-8s %-22s %s${R}\n" "──────" "────────────────────" "──────────────────────────"
        url_temp=$(mktemp)
        for logfile in $ACCESSLOG_PATH; do
            [ -f "$logfile" ] || continue
            domain=$(echo "$logfile" | awk -F'/' '{print $5}')
            awk -v dom="$domain" '{print dom, $7}' "$logfile" >> "$url_temp" 2>/dev/null
        done
        sort "$url_temp" | uniq -c | sort -nr | head -10 | \
        awk -v o="${ORANGE}" -v g="${GREEN_S}" -v c="${CYAN_S}" -v r="${R}" \
            '{printf "  %s%-8s%s  %s%-22.22s%s  %s%.28s%s\n", o,$1,r, g,$2,r, c,$3,r}'
        rm -f "$url_temp"
    } > "$C1"

    # RIGHT — MySQL
    #{
     #   printf "${MAGENTA}${BOLD}  ▶  MYSQL ACTIVE QUERIES${R}\n"
     #   printf "  ${DGRAY}%-8s %-18s %-12s %-6s %s${R}\n" "ID" "DATABASE" "USER" "TIME" "QUERY"
     #   printf "  ${DGRAY}%-8s %-18s %-12s %-6s %s${R}\n" "──────" "────────────────" "──────────" "────" "──────────────────────"
     #   mysql_out=$(mysql -e "SELECT ID, USER, DB, TIME, STATE, LEFT(INFO,80) AS QUERY
     #       FROM information_schema.PROCESSLIST
     #       WHERE COMMAND != 'Sleep' AND INFO IS NOT NULL
     #       ORDER BY TIME DESC LIMIT 8;" 2>/dev/null)
     #   if [ -z "$mysql_out" ]; then
     #       printf "  ${GRAY}${DIM}(no active queries or not accessible)${R}\n"
    #    else
    #        echo "$mysql_out" | awk 'NR>1 {
    #            id=$1; user=$2; db=$3; t=$4;
     #           q=""; for(i=6;i<=NF;i++) q=q" "$i;
    #            printf "  \033[38;5;244m%-8s\033[0m \033[38;5;82m%-18s\033[0m \033[38;5;45m%-12s\033[0m \033[38;5;214m%-6s\033[0m \033[38;5;255m%.30s\033[0m\n",
    ##                id, db, user, t, q
     #       }'
     #   fi
    #} > "$C2"


# RIGHT — MySQL
    {
        printf "${MAGENTA}${BOLD}  ▶  MYSQL ACTIVE PROCESSES${R}\n"
        printf "  ${DGRAY}%-6s %-10s %-4s %-12s %s${R}\n" "ID" "DB" "TIME" "STATE" "QUERY"
        printf "  ${DGRAY}%-6s %-10s %-4s %-12s %s${R}\n" "────" "──────────" "────" "────────────" "──────────────────────"
        
        # We fetch ID, DB, TIME, STATE, and the FULL query (INFO)
        # We filter out Sleep to only show active threats/tasks
        mysql_out=$(mysql -e "SELECT ID, DB, TIME, STATE, INFO 
            FROM information_schema.PROCESSLIST 
            WHERE COMMAND != 'Sleep' AND INFO IS NOT NULL 
            ORDER BY TIME DESC LIMIT 8;" 2>/dev/null)

        if [ -z "$mysql_out" ] || [ $(echo "$mysql_out" | wc -l) -le 1 ]; then
            printf "  ${GRAY}${DIM}(no active queries)${R}\n"
        else
            # Logic: We use \t as a delimiter to handle spaces within the Query text
            echo "$mysql_out" | awk 'NR>1 {
                id=$1; db=$2; time=$3; 
                
                # Handle Database NULLs
                if (db == "NULL") db = "system";
                
                # Color time: Red if query > 5s
                tc = (time > 5) ? "\033[38;5;196m" : "\033[38;5;214m";

                # The Query content starts at column 5 and goes to the end
                query=""; for(i=5;i<=NF;i++) query=query $i " ";
                
                # State: we take the 4th column but truncate it to keep the table clean
                state=$4;

                printf "  \033[38;5;244m%-6s\033[0m \033[38;5;82m%-10.10s\033[0m %s%-4s\033[0m \033[38;5;45m%-12.12s\033[0m \033[38;5;255m%.45s\033[0m\n",
                    id, db, tc, time"s", state, query
            }'
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 4: WP-Login (left) | PHP Slowlog (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — WP-Login
    {
        wplogin_raw=$(grep "wp-login.php" $ACCESSLOG_PATH 2>/dev/null)
        if [ -n "$wplogin_raw" ]; then
            printf "${RED}${BOLD}${BLINK}  ⚠  WP-LOGIN.PHP DETECTED${R}\n"
            printf "  ${DGRAY}%-6s %-22s %-28s %-8s %s${R}\n" "HITS" "DOMAIN" "IP" "METHOD" "LAST SEEN"
            printf "  ${DGRAY}%-6s %-22s %-28s %-8s %s${R}\n" "────" "────────────────────" "──────────────────────────" "──────" "──────────────"
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
                printf "  ${ORANGE}%-6s${R}  ${GREEN_S}%-22.22s${R}  ${CYAN_S}%-28.28s${R}  %b  ${GRAY}%s${R}\n" \
                    "$hits" "$domain" "$ip" "$mfmt" "$ts"
            done
        else
            printf "${GREEN_S}${BOLD}  ✔  WP-LOGIN.PHP${R}\n"
            printf "  ${GREEN_S}No suspicious activity detected.${R}\n"
        fi
    } > "$C1"

    # RIGHT — PHP Slowlog
    {
        if [ -f "$SLOWLOG" ]; then
            printf "${RED_S}${BOLD}  ▶  PHP SLOWLOG — TOP CULPRITS${R}\n"
            printf "  ${DGRAY}%-8s %-26s %s${R}\n" "COUNT" "DOMAIN" "PLUGIN"
            printf "  ${DGRAY}%-8s %-26s %s${R}\n" "──────" "────────────────────────" "──────────────────────"
            grep "wp-content/plugins/" "$SLOWLOG" | \
            sed -rn 's/.*\/domains\/([^/]+)\/.*plugins\/([^/ ]+).*/\1 \2/p' | \
            sort | uniq -c | sort -nr | head -8 | \
            awk -v o="${ORANGE}" -v g="${GREEN_S}" -v rs="${RED_S}" -v r="${R}" \
                '{printf "  %s%-8s%s  %s%-26.26s%s  %s%s%s\n", o,$1,r, g,$2,r, rs,$3,r}'
        else
            printf "${GRAY}${DIM}  ▶  PHP SLOWLOG${R}\n"
            printf "  ${GRAY}${DIM}(slowlog not found at configured path)${R}\n"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"

        # ════════════════════════════════════════════
    #  BLOCK 5: LIVE TRAFFIC VELOCITY (Last 20s)
    # ════════════════════════════════════════════
    echo -e "${CYAN}${BOLD}  ▶  LIVE TRAFFIC VELOCITY (REAL-TIME 20s WINDOW)${R}"
    printf "  ${DGRAY}%-6s %-22s %-28s %s${R}\n" "HITS" "DOMAIN" "IP ADDRESS" "STATUS/Δ"
    printf "  ${DGRAY}%-6s %-22s %-28s %s${R}\n" "────" "────────────────────" "──────────────────────────" "────────"

    LIVE_STATE="/tmp/live_velocity.state"
    NEW_LIVE_STATE=$(mktemp)

    # 1. Capture current minute and previous minute to handle "boundary" refreshes
    CUR_MIN=$(date "+%d/%b/%Y:%H:%M")

    # 2. Loop through logs to get domain-specific live hits
    for log in $ACCESSLOG_PATH; do
        [ -f "$log" ] || continue
        dom=$(echo "$log" | awk -F'/' '{print $5}')

        # Filter only for the current minute to represent "Live" traffic
        tail -n 200 "$log" | grep "$CUR_MIN" | awk -v d="$dom" '{print d, $1}' >> "$NEW_LIVE_STATE"
    done

    # 3. Aggregate, sort, and calculate Deltas
    if [ -s "$NEW_LIVE_STATE" ]; then
        sort "$NEW_LIVE_STATE" | uniq -c | sort -nr | head -8 | while read -r count dom ip; do
            [ -z "$ip" ] && continue

            # FIX: We use a unique key (dom+ip) to find the previous count
            # We ensure we only grab the first column (the count) for the math
            prev_live=$(grep "$dom $ip" "$LIVE_STATE" 2>/dev/null | awk '{print $1}')

            if [ -n "$prev_live" ] && [ "$prev_live" -eq "$prev_live" ] 2>/dev/null; then
                diff=$((count - prev_live))
                if [ "$diff" -gt 3 ]; then v_chg="${RED}${BOLD}↑+${diff}${R}"
                elif [ "$diff" -lt 0 ]; then v_chg="${GREEN_S}↓${diff}${R}"
                else v_chg="${DGRAY}steady${R}"; fi
            else
                v_chg="${BLUE_D}ACTIVE${R}"
            fi

            printf "  ${ORANGE}%-6s${R}  ${GREEN_S}%-22.22s${R}  ${CYAN_S}%-28.28s${R}  %b\n" "$count" "$dom" "$ip" "$v_chg"

            # Save for next loop comparison
            echo "$count $dom $ip" >> "${NEW_LIVE_STATE}.final"
        done
        mv "${NEW_LIVE_STATE}.final" "$LIVE_STATE" 2>/dev/null
    else
        printf "  ${GRAY}${DIM}(waiting for new traffic...)${R}\n"
    fi
    # ════════════════════════════════════════════
    #  BLOCK 6: RECENT FILE CHANGES (Last 60m)
    # ════════════════════════════════════════════
    # This block scans for modified PHP/JS files in plugins and themes
    
    {
        printf "${ORANGE}${BOLD}  ▶  RECENT PLUGIN/THEME CHANGES (60m)${R}\n"
        printf "  ${DGRAY}%-18s %-12s %-15s %s${R}\n" "DOMAIN" "TYPE" "NAME" "TIME"
        printf "  ${DGRAY}%-18s %-12s %-15s %s${R}\n" "────────────────" "────────" "─────────────" "────────"

        # Find files modified in the last 60 minutes
        # We limit depth to avoid excessive scanning
        recent_files=$(find /home/nginx/domains/*/public/wp-content/{plugins,themes} -maxdepth 3 -mmin -60 -type f \( -name "*.php" -o -name "*.js" \) 2>/dev/null)

        if [ -z "$recent_files" ]; then
            printf "  ${GRAY}${DIM}(no changes detected)${R}\n"
        else
            echo "$recent_files" | awk -F'/' '{
                # Path parts: /home/nginx/domains/[5:DOMAIN]/public/wp-content/[8:plugins/themes]/[9:NAME]
                dom=$5; type=$8; name=$9;
                
                # Get the modification time of the file
                cmd = "stat -c %y " $0;
                cmd | getline mod_time;
                close(cmd);
                split(mod_time, t, " ");
                
                # Clean up type name for display
                if (type == "plugins") { t_color="\033[38;5;45m"; t_label="Plugin"; }
                else { t_color="\033[38;5;171m"; t_label="Theme"; }

                printf "  \033[38;5;114m%-18.18s\033[0m %b%-12s\033[0m \033[38;5;255m%-15.15s\033[0m \033[38;5;244m%s\033[0m\n", 
                    dom, t_color, t_label, name, t[2]
            }' | sort -u | head -8
        fi
    } > "$C1"  # Or $C2 depending on where you want it in the column layout
    rm -f "$NEW_LIVE_STATE"
    hline '─' "$DGRAY"

        # ── FOOTER ───────────────────────────────────
    printf "\n"
    hline '═' "$BLUE_D"
    printf "  ${GRAY}${DIM}Refreshing in ${R}${BOLD}${CYAN}20s${R}  ${DGRAY}•${R}  ${GRAY}${DIM}Ctrl+C to exit${R}\n"
    hline '═' "$BLUE_D"
    printf "\n"

    sleep 20
done
