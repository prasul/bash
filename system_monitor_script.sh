#!/bin/bash
# ═══════════════════════════════════════════════
#   SYSTEM MONITOR DASHBOARD — AI Prasul :-P
#   v3.0 — optimized for large-scale servers
# ═══════════════════════════════════════════════

set -o pipefail

# ── ANSI CODES ────────────────────────────────
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

# ── CONFIG ────────────────────────────────────
ACCESSLOG_PATH="/home/nginx/domains/*/log/access.log"
ERRORLOG_PATH="/home/nginx/domains/*/log/error.log"
SLOWLOG="/var/log/php-fpm/www-slow.log"
PHPFPM_STATUS_URL="http://127.0.0.1/status"

# How many lines to tail from each access log per refresh.
# 50k lines ≈ last ~10 minutes on a busy site. Covers "all-time in window"
# without scanning GB of history. Increase if you need deeper lookback.
LOG_TAIL_LINES=50000

# How many lines to tail for "current minute" live view
LIVE_TAIL_LINES=2000

# Refresh interval in seconds
REFRESH_INTERVAL=20

# State files (persist across refreshes)
IP_STATE_FILE="/tmp/monitor_ip_counts.state"
FILE_CACHE="/tmp/recent_file_changes.cache"
FILE_SCAN_TS="/tmp/last_file_scan.ts"
SCAN_INTERVAL=900
ERRLOG_STATE="/tmp/nginx_error_counts.state"
MYSQL_QPS_STATE="/tmp/mysql_qps.state"
MYSQL_QPS_TS="/tmp/mysql_qps_ts.state"
LIVE_URL_STATE="/tmp/live_url_ip.state"
LIVE_VEL_STATE="/tmp/live_vel_domip.state"

# AbuseIPDB
ABUSEIPDB_KEY="${ABUSEIPDB_KEY:-}"
ABUSEIPDB_CACHE="/tmp/.monitor_ipcache"

# WP-Login exclusion list (space-separated IPs)
WL_EXCLUDE_IPS="${WL_EXCLUDE_IPS:-}"

# HTML report config
REPORT_WEBROOT="/usr/local/nginx/html"
REPORT_SUBDIR="reports"
REPORT_BASE_URL=""
REPORT_ENDPOINT=""
REPORT_TOKEN="changeme123"

# ── INIT STATE FILES ─────────────────────────
for f in "$IP_STATE_FILE" "$ERRLOG_STATE" "$MYSQL_QPS_STATE" "$ABUSEIPDB_CACHE"; do
    [ -f "$f" ] || touch "$f"
done
chmod 600 "$ABUSEIPDB_CACHE" 2>/dev/null
[ -f "$FILE_SCAN_TS" ] || echo 0 > "$FILE_SCAN_TS"
[ -f "$MYSQL_QPS_TS" ]  || echo 0 > "$MYSQL_QPS_TS"

# ══════════════════════════════════════════════════
#  LAYOUT ENGINE — adapts to terminal width
# ══════════════════════════════════════════════════
_recalc_layout() {
    TW=$(tput cols 2>/dev/null || echo 120)
    [ "$TW" -lt 80 ] && TW=80
    HALF=$(( TW / 2 - 2 ))

    # Ensure HALF is at least usable
    [ "$HALF" -lt 40 ] && HALF=40

    # Dynamic column for full-width blocks
    COL_MYSQL_QUERY=$(( TW - 62 ))
    [ "$COL_MYSQL_QUERY" -lt 40 ] && COL_MYSQL_QUERY=40

    COL_LV_URL=$(( TW - 112 ))
    [ "$COL_LV_URL" -lt 20 ] && COL_LV_URL=20

    COL_ERR_SNIPPET=$(( TW - 96 ))
    [ "$COL_ERR_SNIPPET" -lt 24 ] && COL_ERR_SNIPPET=24
}
_recalc_layout

# ── Precomputed horizontal rule (avoids seq/loop per call) ──
_hline_cache=""
_hline_cache_w=0

# ── Safe integer coercion (strips non-digits, returns 0 for garbage) ──
to_int() {
    local v="${1//[!0-9]/}"
    echo "${v:-0}"
}
hline() {
    local char="${1:- }" color="${2:-$DGRAY}"
    if [ "$_hline_cache_w" -ne "$TW" ] || [ "${_hline_cache_char:-}" != "$char" ]; then
        _hline_cache=$(printf "%${TW}s" "" | tr ' ' "$char")
        _hline_cache_w=$TW
        _hline_cache_char="$char"
    fi
    printf "${color}%s${R}\n" "$_hline_cache"
}

VBAR="${DGRAY}|${R}"

# ── Color a percentage (integer-safe, no subshell) ──
color_pct() {
    local raw="${1:-0}" hi="${2:-50}" med="${3:-20}"
    local val="${raw%%.*}"
    val="${val//[^0-9-]/}"
    [ -z "$val" ] && val=0
    if   [ "$val" -ge "$hi"  ]; then printf "${RED}${BOLD}"
    elif [ "$val" -ge "$med" ]; then printf "${ORANGE}"
    else printf "${GREEN_S}"
    fi
}

# ══════════════════════════════════════════════════
# render_two_cols — ANSI+UTF-8 aware side-by-side
# ══════════════════════════════════════════════════
render_two_cols() {
    local left="$1" right="$2" col_w="$HALF"

    LC_ALL=C awk -v col="$col_w" '
    function visible_len(s,    r) {
        r = s
        # Strip all ANSI escape sequences
        while (match(r, /\033\[[0-9;]*[A-Za-z]/))
            r = substr(r,1,RSTART-1) substr(r,RSTART+RLENGTH)
        return length(r)
    }
    function pad_to(s, w,    pl, spaces) {
        pl = visible_len(s)
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

# ══════════════════════════════════════════════════
#  SINGLE-PASS LOG EXTRACTION
#  This is the core performance optimization.
#  Instead of scanning each log 4-6 times, we do ONE
#  tail + awk pass and produce all aggregates at once.
# ══════════════════════════════════════════════════
#
# Output files (written atomically via temp+mv):
#   /tmp/mon_top_ips.dat      — "count ip" sorted desc
#   /tmp/mon_top_urls.dat     — "count domain url" sorted desc
#   /tmp/mon_live_traffic.dat — "domain ip method url status" (current minute)
#   /tmp/mon_wplogin.dat      — "domain ip ts method status" (wp-login only)
#
# This replaces ~12 separate pipelines from v2.

extract_logs() {
    local cur_min="$1"
    local tmp_ips=$(mktemp)
    local tmp_urls=$(mktemp)
    local tmp_live=$(mktemp)
    local tmp_wplogin=$(mktemp)

    for logfile in $ACCESSLOG_PATH; do
        [ -f "$logfile" ] || continue
        local domain
        domain=$(echo "$logfile" | cut -d'/' -f5)

        # Single awk pass extracts everything we need
        tail -n "$LOG_TAIL_LINES" "$logfile" 2>/dev/null | \
        awk -v dom="$domain" -v cm="$cur_min" \
            -v f_ips="/dev/fd/3" \
            -v f_urls="/dev/fd/4" \
            -v f_live="/dev/fd/5" \
            -v f_wpl="/dev/fd/6" '
        {
            ip = $1
            url = $7
            ts = $4; sub(/^\[/, "", ts)
            method = $6; gsub(/"/, "", method)
            status = $9

            # Accumulate IPs
            ip_count[ip]++

            # Accumulate URLs
            url_key = dom " " url
            url_count[url_key]++

            # Live traffic (current minute)
            if (index(ts, cm) == 1) {
                print dom, ip, method, url, status > f_live
            }

            # WP-Login
            if (url ~ /wp-login\.php/) {
                print dom, ip, ts, method, status > f_wpl
            }
        }
        END {
            for (ip in ip_count) print ip_count[ip], ip > f_ips
            for (uk in url_count) print url_count[uk], uk > f_urls
        }
        ' 3>>"$tmp_ips" 4>>"$tmp_urls" 5>>"$tmp_live" 6>>"$tmp_wplogin"
    done

    # Sort and write final outputs atomically
    sort -rn "$tmp_ips"     | head -20 > /tmp/mon_top_ips.dat.new
    sort -rn "$tmp_urls"    | head -20 > /tmp/mon_top_urls.dat.new
    cat "$tmp_live"                    > /tmp/mon_live_traffic.dat.new
    cat "$tmp_wplogin"                 > /tmp/mon_wplogin.dat.new

    mv /tmp/mon_top_ips.dat.new      /tmp/mon_top_ips.dat
    mv /tmp/mon_top_urls.dat.new     /tmp/mon_top_urls.dat
    mv /tmp/mon_live_traffic.dat.new /tmp/mon_live_traffic.dat
    mv /tmp/mon_wplogin.dat.new      /tmp/mon_wplogin.dat

    rm -f "$tmp_ips" "$tmp_urls" "$tmp_live" "$tmp_wplogin"
}

# ══════════════════════════════════════════════════
#  IP ENRICHMENT (AbuseIPDB + ip-api.com)
#  Cache is stable across refreshes (not PID-based)
# ══════════════════════════════════════════════════

# Load cache into an associative array for O(1) lookups
# (replaces grep-per-IP which was O(n) per lookup)
declare -A IP_CACHE

_load_ip_cache() {
    IP_CACHE=()
    while IFS='|' read -r ip score cc isp _; do
        [ -z "$ip" ] && continue
        IP_CACHE["$ip"]="${score}|${cc}|${isp}"
    done < "$ABUSEIPDB_CACHE" 2>/dev/null
}

_ip_enrich() {
    local ip="$1"

    # Check in-memory cache first
    if [ -n "${IP_CACHE[$ip]+x}" ]; then
        echo "${ip}|${IP_CACHE[$ip]}"
        return
    fi

    # Skip private ranges
    case "$ip" in
        10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|127.*|0.*)
            IP_CACHE["$ip"]="-|--|private"
            echo "${ip}|-|--|private" >> "$ABUSEIPDB_CACHE"
            echo "${ip}|-|--|private"
            return ;;
    esac

    # AbuseIPDB lookup
    local score="-"
    if [ -n "$ABUSEIPDB_KEY" ]; then
        local abuse_raw
        abuse_raw=$(curl -sS --max-time 3 -G "https://api.abuseipdb.com/api/v2/check" \
            --data-urlencode "ipAddress=${ip}" \
            -d "maxAgeInDays=90" \
            -H "Key: ${ABUSEIPDB_KEY}" \
            -H "Accept: application/json" 2>/dev/null)
        local s
        s=$(echo "$abuse_raw" | grep -oP '"abuseConfidenceScore"\s*:\s*\K[0-9]+')
        score="${s:--}"
    fi

    # Geo lookup (ip-api.com free tier — HTTP only)
    local geo_raw cc isp
    geo_raw=$(curl -sS --max-time 3 \
        "http://ip-api.com/json/${ip}?fields=countryCode,isp,org" 2>/dev/null)
    cc=$(echo "$geo_raw"  | grep -oP '"countryCode"\s*:\s*"\K[^"]+')
    isp=$(echo "$geo_raw" | grep -oP '"isp"\s*:\s*"\K[^"]+')
    [ -z "$isp" ] && isp=$(echo "$geo_raw" | grep -oP '"org"\s*:\s*"\K[^"]+')
    cc="${cc:---}"
    isp="${isp:--}"
    [ "${#isp}" -gt 24 ] && isp="${isp:0:23}…"

    local result="${ip}|${score}|${cc}|${isp}"
    IP_CACHE["$ip"]="${score}|${cc}|${isp}"
    echo "$result" >> "$ABUSEIPDB_CACHE"
    echo "$result"
}

_ip_get_cached() {
    # Fast path: in-memory only, no fallback
    local ip="$1"
    if [ -n "${IP_CACHE[$ip]+x}" ]; then
        echo "${IP_CACHE[$ip]}"
    else
        echo "-|--|—"
    fi
}

_abuse_colour() {
    local score="$1"
    if [[ "$score" =~ ^[0-9]+$ ]]; then
        if   [ "$score" -ge 75 ]; then printf '%s' "${RED}${BOLD}"
        elif [ "$score" -ge 25 ]; then printf '%s' "${ORANGE}"
        else                           printf '%s' "${GREEN_S}"
        fi
    else
        printf '%s' "${DGRAY}"
    fi
}

# Bulk-enrich a list of IPs (one per line). Call once before rendering.
_enrich_ips_bulk() {
    local ip_file="$1"
    while read -r ip; do
        [ -z "$ip" ] && continue
        [ -n "${IP_CACHE[$ip]+x}" ] && continue
        _ip_enrich "$ip" > /dev/null
    done < "$ip_file"
}

# ══════════════════════════════════════════════════
#  HTML HELPERS
# ══════════════════════════════════════════════════
html_e() { printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'; }

json_str() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g'   \
        -e 's/	/\\t/g'   \
        -e ':a;N;$!ba;s/\n/\\n/g'
}

# ══════════════════════════════════════════════════
#  PLAIN-TEXT EXIT REPORT
# ══════════════════════════════════════════════════
generate_report() {
    local RPT="/tmp/monitor_report_$(date '+%Y%m%d_%H%M%S').txt"
    local NOW_FULL HOST LOAD UPTIME_S
    NOW_FULL=$(date "+%A, %d %b %Y  %H:%M:%S")
    HOST=$(hostname -s 2>/dev/null || echo "server")
    LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    UPTIME_S=$(uptime -p 2>/dev/null | sed 's/up //')

    {
    cat <<-EOF
	════════════════════════════════════════════════════════════════
	  SERVER PERFORMANCE REPORT
	  Generated : ${NOW_FULL}
	  Host      : ${HOST}
	  Uptime    : ${UPTIME_S}
	  Load avg  : ${LOAD}
	════════════════════════════════════════════════════════════════

	EOF

    echo "┌─── TOP CPU-CONSUMING PROCESSES ────────────────────────────"
    ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=6{
        printf "│  %-3d  %-36s  %s%%\n", NR-1, $1, $2}'
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─── TOP MEMORY-CONSUMING PROCESSES ─────────────────────────"
    ps -eo comm,%mem --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=6{
        printf "│  %-3d  %-36s  %s%%\n", NR-1, $1, $2}'
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─── TOP URLs BY HIT COUNT ─────────────────────────────────"
    if [ -f /tmp/mon_top_urls.dat ]; then
        head -10 /tmp/mon_top_urls.dat | awk '{printf "│  %-8s  %-28s  %s\n", $1, $2, $3}'
    fi
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─── TOP IPs HITTING THE SERVER ────────────────────────────"
    if [ -f /tmp/mon_top_ips.dat ]; then
        head -10 /tmp/mon_top_ips.dat | awk '{printf "│  %-8s  %s\n", $1, $2}'
    fi
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    echo "┌─── WP-LOGIN.PHP ACTIVITY ────────────────────────────────"
    local wl_total=0
    [ -f /tmp/mon_wplogin.dat ] && wl_total=$(wc -l < /tmp/mon_wplogin.dat | tr -d '[:space:]')
    wl_total=$(to_int "$wl_total")
    if [ "$wl_total" -gt 0 ]; then
        echo "│  Total wp-login.php hits in log window: $wl_total"
        echo "│  Top offending IPs:"
        awk '{print $2}' /tmp/mon_wplogin.dat | sort | uniq -c | sort -nr | head -5 | \
            awk '{printf "│    %-8s  %s\n", $1, $2}'
    else
        echo "│  No wp-login.php hits detected"
    fi
    echo "└─────────────────────────────────────────────────────────────"
    echo ""

    # PHP Slowlog summary
    echo "┌─── PHP SLOWLOG — TOP OFFENDING PLUGIN ───────────────────"
    if [ -f "$SLOWLOG" ]; then
        local TOP_PLUGIN
        TOP_PLUGIN=$(grep "wp-content/plugins/" "$SLOWLOG" | \
            sed -rn 's/.*\/plugins\/([^/ ]+).*/\1/p' | \
            sort | uniq -c | sort -nr | head -1 | awk '{print $2}')
        if [ -n "$TOP_PLUGIN" ]; then
            local TOP_COUNT TOP_DOM
            TOP_COUNT=$(grep -c "$TOP_PLUGIN" "$SLOWLOG" 2>/dev/null | tr -d '[:space:]')
            TOP_DOM=$(grep "wp-content/plugins/$TOP_PLUGIN" "$SLOWLOG" | \
                sed -rn 's/.*\/domains\/([^/]+)\/.*/\1/p' | \
                sort | uniq -c | sort -nr | head -1 | awk '{print $2}')
            printf "│  Plugin: %-20s  Domain: %-20s  Entries: %s\n" \
                "$TOP_PLUGIN" "${TOP_DOM:-unknown}" "$TOP_COUNT"
        else
            echo "│  (no plugin entries found)"
        fi
    else
        echo "│  (slowlog not found)"
    fi
    echo "└─────────────────────────────────────────────────────────────"

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  End of report  •  $(date '+%H:%M:%S')"
    echo "════════════════════════════════════════════════════════════════"

    } | tee "$RPT"
    echo ""
    echo "  Report saved to: $RPT"
}

# ══════════════════════════════════════════════════
#  HTML REPORT (generates on Ctrl+C)
# ══════════════════════════════════════════════════
generate_html_report() {
    local NOW_FULL NOW_SLUG HOST_FULL HOST_SHORT LOAD UPTIME_S
    NOW_FULL=$(date "+%A, %d %b %Y  %H:%M:%S")
    NOW_SLUG=$(date '+%Y-%m-%d_%H-%M-%S')
    HOST_FULL=$(hostname -f 2>/dev/null || hostname -s 2>/dev/null || echo "server")
    HOST_SHORT=$(hostname -s 2>/dev/null || echo "server")
    LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    UPTIME_S=$(uptime -p 2>/dev/null | sed 's/up //')

    local PUB_DIR="$REPORT_WEBROOT"
    [ -n "$REPORT_SUBDIR" ] && PUB_DIR="${REPORT_WEBROOT}/${REPORT_SUBDIR}"

    local PUBLIC_BASE="${REPORT_BASE_URL:-https://${HOST_FULL}}"
    PUBLIC_BASE="${PUBLIC_BASE%/}"

    local REPORT_URL="${PUBLIC_BASE}/${REPORT_SUBDIR}/${NOW_SLUG}.html"
    [ -z "$REPORT_SUBDIR" ] && REPORT_URL="${PUBLIC_BASE}/${NOW_SLUG}.html"

    if [ ! -d "$REPORT_WEBROOT" ]; then
        PUB_DIR="/tmp/monitor_reports"
        echo "  Warning: Web root not found ($REPORT_WEBROOT), writing to $PUB_DIR"
    fi
    mkdir -p "$PUB_DIR" 2>/dev/null

    local HTML_FILE="${PUB_DIR}/${NOW_SLUG}.html"

    # ── Build data rows from cached extraction files ──
    # CPU rows
    local cpu_rows=""
    while read -r proc pct; do
        local bar_w col
        bar_w=$(awk -v p="$pct" 'BEGIN{v=int(p*2); if(v>100)v=100; print v}')
        col=$(awk -v p="$pct" 'BEGIN{if(p+0>=50)print "#c92a2a"; else if(p+0>=20)print "#e67700"; else print "#2f9e44"}')
        cpu_rows+="<tr><td class='mono'>$(html_e "$proc")</td><td><div class='bar-cell'><div class='bar-track'><div class='bar-fill' style='width:${bar_w}%;background:${col}'></div></div><span class='bar-val' style='color:${col}'>${pct}%</span></div></td></tr>"
    done < <(ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=8{print $1,$2}')

    # Memory rows
    local mem_rows=""
    while read -r proc pct; do
        local bar_w col
        bar_w=$(awk -v p="$pct" 'BEGIN{v=int(p*5); if(v>100)v=100; print v}')
        col=$(awk -v p="$pct" 'BEGIN{if(p+0>=20)print "#c92a2a"; else if(p+0>=10)print "#e67700"; else print "#1c7ed6"}')
        mem_rows+="<tr><td class='mono'>$(html_e "$proc")</td><td><div class='bar-cell'><div class='bar-track'><div class='bar-fill' style='width:${bar_w}%;background:${col}'></div></div><span class='bar-val' style='color:${col}'>${pct}%</span></div></td></tr>"
    done < <(ps -eo comm,%mem --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=8{print $1,$2}')

    # URL rows from cached data
    local url_rows=""
    if [ -f /tmp/mon_top_urls.dat ]; then
        while read -r hits dom url; do
            url_rows+="<tr><td class='count'>$(html_e "$hits")</td><td class='dim'>$(html_e "$dom")</td><td class='url-cell'>$(html_e "$url")</td></tr>"
        done < <(head -10 /tmp/mon_top_urls.dat)
    fi

    # IP rows from cached data
    local ip_rows="" max_ip_hits=1
    if [ -f /tmp/mon_top_ips.dat ]; then
        max_ip_hits=$(head -1 /tmp/mon_top_ips.dat | awk '{print $1+0}')
        [ "${max_ip_hits:-0}" -eq 0 ] && max_ip_hits=1
        while read -r hits ip; do
            local bw
            bw=$(awk -v h="$hits" -v m="$max_ip_hits" 'BEGIN{printf "%d", h/m*100}')
            ip_rows+="<tr><td class='count'>$(html_e "$hits")</td><td class='ip-cell'>$(html_e "$ip")</td><td><div class='bar-track'><div class='bar-fill' style='width:${bw}%;background:#1c7ed6'></div></div></td></tr>"
        done < <(head -10 /tmp/mon_top_ips.dat)
    fi

    # WP-Login
    local wl_total=0
    [ -f /tmp/mon_wplogin.dat ] && wl_total=$(wc -l < /tmp/mon_wplogin.dat | tr -d '[:space:]')
    wl_total=$(to_int "$wl_total")
    local wl_status_class="ok" wl_status_text="No wp-login.php hits detected" wl_dot_class="ok"
    [ "$wl_total" -gt 0 ] && { wl_status_class="alert"; wl_dot_class="alert"; wl_status_text="Login page hits detected"; }
    local wl_ip_rows=""
    if [ "$wl_total" -gt 0 ] && [ -f /tmp/mon_wplogin.dat ]; then
        while read -r hits ip; do
            wl_ip_rows+="<tr><td class='count count-hi'>$(html_e "$hits")</td><td class='ip-cell'>$(html_e "$ip")</td></tr>"
        done < <(awk '{print $2}' /tmp/mon_wplogin.dat | sort | uniq -c | sort -nr | head -5)
    fi

    # MySQL top queries
    local mysql_query_rows="" mysql_avail=0
    local mysql_raw
    mysql_raw=$(mysql --batch --silent -e "
        SELECT
            IFNULL(SCHEMA_NAME, '—')                  AS db,
            DIGEST_TEXT,
            COUNT_STAR,
            ROUND(SUM_TIMER_WAIT/1000000000000, 3)   AS total_sec,
            ROUND(AVG_TIMER_WAIT/1000000000000, 4)   AS avg_sec,
            ROUND(MAX_TIMER_WAIT/1000000000000, 3)   AS max_sec,
            SUM_ROWS_EXAMINED,
            SUM_ROWS_SENT,
            LAST_SEEN
        FROM performance_schema.events_statements_summary_by_digest
        WHERE DIGEST_TEXT IS NOT NULL
          AND DIGEST_TEXT NOT LIKE '%performance_schema%'
          AND DIGEST_TEXT NOT LIKE '%SHOW%'
        ORDER BY SUM_TIMER_WAIT DESC
        LIMIT 15;" 2>/dev/null)

    if [ -n "$mysql_raw" ]; then
        mysql_avail=1
        while IFS=$'\t' read -r db digest count total_sec avg_sec max_sec rows_exam rows_sent last_seen; do
            [ -z "$digest" ] && continue
            local short_digest="$digest"
            [ "${#digest}" -gt 110 ] && short_digest="${digest:0:107}..."
            local avg_col max_col
            avg_col=$(awk -v a="$avg_sec" 'BEGIN{if(a+0>=1)print "#c92a2a"; else if(a+0>=0.1)print "#e67700"; else if(a+0>=0.01)print "#495057"; else print "#2f9e44"}')
            max_col=$(awk -v m="$max_sec" 'BEGIN{if(m+0>=5)print "#c92a2a"; else if(m+0>=1)print "#e67700"; else print "#2f9e44"}')

            mysql_query_rows+="<tr>"
            mysql_query_rows+="<td class='db-stack'><div class='db-name'>$(html_e "$db")</div></td>"
            mysql_query_rows+="<td class='query-cell'>$(html_e "$short_digest")</td>"
            mysql_query_rows+="<td class='t-right t-num'>${count}</td>"
            mysql_query_rows+="<td class='t-right t-num'>${total_sec}s</td>"
            mysql_query_rows+="<td class='t-right t-num' style='color:${avg_col}'>${avg_sec}s</td>"
            mysql_query_rows+="<td class='t-right t-num' style='color:${max_col}'>${max_sec}s</td>"
            mysql_query_rows+="<td class='t-right t-num'>${rows_exam}</td>"
            mysql_query_rows+="<td class='t-right t-num'>${rows_sent}</td>"
            mysql_query_rows+="<td class='dim' style='white-space:nowrap'>${last_seen}</td>"
            mysql_query_rows+="</tr>"
        done <<< "$mysql_raw"
    fi

    # ── Write HTML ──
    cat > "$HTML_FILE" << 'HTMLEOF_HEADER'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
HTMLEOF_HEADER

    cat >> "$HTML_FILE" << HTMLEOF_TITLE
<title>Server Report — ${HOST_FULL}</title>
HTMLEOF_TITLE

    cat >> "$HTML_FILE" << 'HTMLEOF_STYLE'
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root{--bg:#f8f9fa;--surface:#fff;--border:#e2e6ea;--txt:#212529;--txt2:#495057;--muted:#6c757d;--light:#f1f3f5;--accent:#1c7ed6;--green:#2f9e44;--red:#c92a2a;--orange:#e67700;--mono:'JetBrains Mono','Courier New',monospace;--sans:'Inter',system-ui,sans-serif;--radius:6px;--shadow:0 1px 3px rgba(0,0,0,.08),0 1px 2px rgba(0,0,0,.06)}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:var(--sans);font-size:13.5px;line-height:1.55;-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
code{font-family:var(--mono);font-size:12px;background:var(--light);padding:1px 5px;border-radius:3px;border:1px solid var(--border);color:var(--txt2)}
.wrap{max-width:1280px;margin:0 auto;padding:32px 24px 64px}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:16px}
.grid1{display:grid;grid-template-columns:1fr;gap:16px;margin-bottom:16px}
@media(max-width:800px){.grid2{grid-template-columns:1fr}}
.report-header{display:flex;justify-content:space-between;align-items:flex-start;gap:24px;flex-wrap:wrap;padding-bottom:24px;margin-bottom:28px;border-bottom:2px solid var(--border)}
.rh-left .report-label{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin-bottom:4px}
.rh-left .report-host{font-size:26px;font-weight:600;color:var(--txt);line-height:1.2}
.rh-right{text-align:right;font-size:12.5px;color:var(--txt2);line-height:1.7}
.rh-right strong{color:var(--txt);font-weight:500}
.panel{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow);overflow:hidden}
.panel-header{display:flex;align-items:center;gap:10px;padding:11px 16px;border-bottom:1px solid var(--border);background:var(--light)}
.panel-title{font-size:12px;font-weight:600;color:var(--txt);letter-spacing:.01em;flex:1}
.badge{display:inline-block;font-size:11px;font-weight:500;padding:2px 8px;border-radius:4px;border:1px solid transparent}
.badge-ok{background:#ebfbee;color:#2f9e44;border-color:#b2f2bb}
.badge-warn{background:#fff9db;color:#e67700;border-color:#ffec99}
.badge-alert{background:#fff5f5;color:#c92a2a;border-color:#ffc9c9}
.badge-info{background:#e7f5ff;color:#1971c2;border-color:#a5d8ff}
table{width:100%;border-collapse:collapse}
thead tr{border-bottom:1px solid var(--border)}
th{padding:8px 14px;font-size:11px;font-weight:600;color:var(--muted);text-align:left;text-transform:uppercase;letter-spacing:.06em;background:var(--light)}
td{padding:9px 14px;font-size:13px;color:var(--txt2);border-bottom:1px solid var(--border);vertical-align:middle}
tr:last-child td{border-bottom:none}tbody tr:hover td{background:#f8f9fa}
.count{display:inline-block;font-family:var(--mono);font-size:11.5px;font-weight:500;min-width:42px;text-align:right;color:var(--txt)}
.count-hi{color:var(--red)}.count-med{color:var(--orange)}
.bar-cell{display:flex;align-items:center;gap:10px}
.bar-track{flex:1;height:5px;background:var(--border);border-radius:3px;overflow:hidden;min-width:60px}
.bar-fill{height:100%;border-radius:3px}
.bar-val{font-size:12px;font-family:var(--mono);min-width:40px;text-align:right;color:var(--txt2)}
.mono{font-family:var(--mono);font-size:12px;color:var(--txt)}
.url-cell{font-family:var(--mono);font-size:11.5px;color:var(--accent);word-break:break-all;max-width:320px}
.ip-cell{font-family:var(--mono);font-size:12px;color:var(--txt)}
.dim{color:var(--muted);font-size:12px}
.status-row{display:flex;align-items:center;gap:12px;padding:14px 16px}
.status-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.status-dot.ok{background:var(--green)}.status-dot.alert{background:var(--red)}
.status-label{font-size:13.5px;font-weight:500;color:var(--txt)}
.status-count{margin-left:auto;font-size:22px;font-weight:600;font-family:var(--mono);color:var(--red)}
.kv-table{padding:12px 16px 4px}.kv-table table{border:none}.kv-table td{border:none;padding:4px 16px 4px 0;font-size:12.5px;color:var(--txt2)}.kv-table td:first-child{color:var(--muted);width:120px;font-size:12px}.kv-table td strong{color:var(--txt);font-weight:500}
.empty{padding:20px 16px;font-size:12.5px;color:var(--muted);text-align:center}
.query-cell{font-family:var(--mono);font-size:11.5px;color:var(--txt2);word-break:break-all;max-width:480px;line-height:1.5}
.db-stack{white-space:nowrap;vertical-align:top}.db-name{font-size:12px;font-weight:500;color:var(--accent)}
.mysql-note{padding:10px 16px;font-size:12px;color:var(--muted);border-bottom:1px solid var(--border);background:var(--light)}
.t-right{text-align:right}.t-num{font-family:var(--mono);font-size:12px}
.report-footer{margin-top:48px;padding-top:16px;border-top:1px solid var(--border);display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px;font-size:12px;color:var(--muted)}
</style>
</head>
<body>
<div class="wrap">
HTMLEOF_STYLE

    cat >> "$HTML_FILE" << HTMLEOF_BODY
<div class="report-header">
  <div class="rh-left">
    <div class="report-label">Server Performance Report</div>
    <div class="report-host">${HOST_FULL}</div>
  </div>
  <div class="rh-right">
    <div><strong>${NOW_FULL}</strong></div>
    <div>Uptime: <strong>${UPTIME_S}</strong></div>
    <div>Load average: <strong>${LOAD}</strong></div>
  </div>
</div>

<div class="grid2">
  <div class="panel">
    <div class="panel-header"><span class="panel-title">CPU Usage — Top Processes</span></div>
    <table><thead><tr><th>Process</th><th>CPU %</th></tr></thead><tbody>${cpu_rows}</tbody></table>
  </div>
  <div class="panel">
    <div class="panel-header"><span class="panel-title">Memory Usage — Top Processes</span></div>
    <table><thead><tr><th>Process</th><th>Memory %</th></tr></thead><tbody>${mem_rows}</tbody></table>
  </div>
</div>

<div class="grid2">
  <div class="panel">
    <div class="panel-header"><span class="panel-title">Top URLs by Hit Count</span><span class="badge badge-info">Window</span></div>
    <table><thead><tr><th>Hits</th><th>Domain</th><th>URL</th></tr></thead><tbody>${url_rows}</tbody></table>
  </div>
  <div class="panel">
    <div class="panel-header"><span class="panel-title">Top IP Addresses</span><span class="badge badge-info">Window</span></div>
    <table><thead><tr><th>Hits</th><th>IP Address</th><th>Share</th></tr></thead><tbody>${ip_rows}</tbody></table>
  </div>
</div>

<div class="grid1">
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">WP-Login.php Activity</span>
      $([ "$wl_total" -gt 0 ] && echo "<span class='badge badge-alert'>${wl_total} hits</span>" || echo "<span class='badge badge-ok'>Clear</span>")
    </div>
    <div class="status-row">
      <div class="status-dot ${wl_dot_class}"></div>
      <div><div class="status-label">${wl_status_text}</div></div>
      $([ "$wl_total" -gt 0 ] && echo "<div class='status-count'>${wl_total}</div>")
    </div>
    $([ -n "$wl_ip_rows" ] && echo "<table><thead><tr><th>Hits</th><th>IP Address</th></tr></thead><tbody>${wl_ip_rows}</tbody></table>")
  </div>
</div>

<div class="grid1">
  <div class="panel">
    <div class="panel-header">
      <span class="panel-title">MySQL — Top Queries by Total Execution Time</span>
      $([ "$mysql_avail" -eq 1 ] && echo "<span class='badge badge-info'>performance_schema</span>" || echo "<span class='badge badge-alert'>Unavailable</span>")
    </div>
    $(if [ "$mysql_avail" -eq 1 ] && [ -n "$mysql_query_rows" ]; then
        echo "<div class='mysql-note'>Aggregated since last server restart. Sorted by total cumulative execution time.</div>"
        echo "<div style='overflow-x:auto'><table>"
        echo "<thead><tr><th>Database</th><th>Query Digest</th><th class='t-right'>Calls</th><th class='t-right'>Total</th><th class='t-right'>Avg</th><th class='t-right'>Max</th><th class='t-right'>Rows exam</th><th class='t-right'>Rows sent</th><th>Last seen</th></tr></thead>"
        echo "<tbody>${mysql_query_rows}</tbody></table></div>"
    else
        echo "<div class='empty'>MySQL is not accessible or no query data available.</div>"
    fi)
  </div>
</div>

<div class="report-footer">
  <span>Server Monitor Dashboard &middot; ${HOST_FULL}</span>
  <span>Generated ${NOW_FULL}</span>
</div>
</div></body></html>
HTMLEOF_BODY

    echo "  HTML report written: $HTML_FILE"

    # Redirect page
    local REL_PATH="${REPORT_SUBDIR:+${REPORT_SUBDIR}/}${NOW_SLUG}.html"
    cat > "${REPORT_WEBROOT}/report.html" 2>/dev/null << REOF
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta http-equiv="refresh" content="0;url=${REL_PATH}"></head>
<body><p>Redirecting to <a href="${REL_PATH}">latest report</a>...</p></body></html>
REOF

    # Prune old reports (keep 30)
    local old_reports
    old_reports=$(ls -t "$PUB_DIR"/*.html 2>/dev/null | grep -v "index.html" | tail -n +31)
    [ -n "$old_reports" ] && echo "$old_reports" | xargs rm -f

    echo "  Report URL: ${REPORT_URL}"
}

# ── TRAP: exit report ────────────────────────────
trap '
    echo ""
    echo "  Generating exit report..."
    generate_report
    echo ""
    echo "  Writing HTML report..."
    generate_html_report
    rm -f "${FRAME:-}" /tmp/mon_top_ips.dat /tmp/mon_top_urls.dat /tmp/mon_live_traffic.dat /tmp/mon_wplogin.dat
    exit 0
' INT

# ════════════════════════════════════════════════
#  DETECT SERVER IPs (once at startup — doesn't change)
# ════════════════════════════════════════════════
SERVER_IPS=""
# Primary: all non-loopback IPv4 addresses from interfaces
if command -v ip &>/dev/null; then
    SERVER_IPS=$(ip -4 addr show scope global 2>/dev/null | \
        awk '/inet /{sub(/\/.*/, "", $2); printf "%s  ", $2}')
fi
# Fallback: hostname -I (space-separated, may include IPv6)
if [ -z "$SERVER_IPS" ]; then
    SERVER_IPS=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) printf "%s  ", $i}')
fi
# Append public IP if available (may differ from interface IP behind NAT)
SERVER_PUBLIC_IP=$(curl -sS --max-time 3 https://ifconfig.me 2>/dev/null || \
                   curl -sS --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
if [ -n "$SERVER_PUBLIC_IP" ]; then
    # Only append if it's not already in the list
    case "$SERVER_IPS" in
        *"$SERVER_PUBLIC_IP"*) ;;
        *) SERVER_IPS="${SERVER_IPS}${SERVER_PUBLIC_IP} (public)" ;;
    esac
fi
SERVER_IPS="${SERVER_IPS:-unknown}"

# ════════════════════════════════════════════════
#  MAIN LOOP
# ════════════════════════════════════════════════
FRAME=$(mktemp)

render_frame() {
    # ── Recalc layout on every frame (handles resize) ──
    _recalc_layout

    # ── Timing ────────────────────────────────────
    LOOP_START=$(date +%s)
    NOW=$(date "+%A, %d %b %Y  %H:%M:%S")
    HOST=$(hostname -s 2>/dev/null || echo "server")
    UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up //' || uptime | awk '{print $3,$4}' | tr -d ',')
    LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    CUR_MIN=$(date "+%d/%b/%Y:%H:%M")

    # ── SINGLE-PASS LOG EXTRACTION ────────────────
    extract_logs "$CUR_MIN"

    # ── Load IP cache into memory ─────────────────
    _load_ip_cache

    # ── DISK WARNING ──────────────────────────────
    DISK_WARN=""
    while read -r pct mount; do
        pct_num="${pct%%%}"
        if [ "${pct_num:-0}" -ge 98 ] 2>/dev/null; then
            DISK_WARN="${DISK_WARN}${mount} at ${pct}  "
        fi
    done < <(df -h --output=pcent,target 2>/dev/null | awk 'NR>1 && $1!="Use%"')

    # ── HEADER ────────────────────────────────────
    hline '=' "$BLUE_D"
    hdr_left="  SYSTEM MONITOR DASHBOARD"
    pad=$(( TW - ${#hdr_left} - ${#NOW} - 4 ))
    [ "$pad" -lt 1 ] && pad=1
    printf "${BG_HEADER}${CYAN}${BOLD}%s%*s${YELLOW}%s  ${R}\n" "$hdr_left" "$pad" "" "$NOW"
    hline '=' "$BLUE_D"

    if [ -n "$DISK_WARN" ]; then
        printf "${BG_ALERT}${RED}${BOLD}${BLINK}  CRITICAL DISK USAGE: %s${R}\n" "$DISK_WARN"
    fi

    printf "\n"
    printf "  ${DGRAY}HOST:${R} ${WHITE}${BOLD}%-24s${R}  " "$HOST"
    printf "${DGRAY}UPTIME:${R} ${WHITE}${BOLD}%-26s${R}  " "$UPTIME_STR"
    printf "${DGRAY}LOAD:${R} ${WHITE}${BOLD}%s${R}\n" "$LOAD_AVG"
    printf "  ${DGRAY}SERVER IP:${R} ${CYAN}${BOLD}%s${R}\n\n" "$SERVER_IPS"

    # ── SYSTEM PRESSURE ───────────────────────────
    {
        read_idle1=$(awk '/^cpu / {print $5}' /proc/stat 2>/dev/null)
        read_iow1=$(awk '/^cpu / {print $6}' /proc/stat 2>/dev/null)
        read_total1=$(awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat 2>/dev/null)
        sleep 0.3
        read_idle2=$(awk '/^cpu / {print $5}' /proc/stat 2>/dev/null)
        read_iow2=$(awk '/^cpu / {print $6}' /proc/stat 2>/dev/null)
        read_total2=$(awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat 2>/dev/null)

        dtotal=$(( read_total2 - read_total1 ))
        diowait=$(( read_iow2 - read_iow1 ))
        IOWAIT_PCT=0
        [ "$dtotal" -gt 0 ] && IOWAIT_PCT=$(( diowait * 100 / dtotal ))

        MEM_USED=0; MEM_AVAIL="0"; MEM_TOTAL="0"
        while read -r key val _; do
            case "$key" in
                MemTotal:)     mem_t=$val ;;
                MemAvailable:) mem_a=$val ;;
            esac
        done < /proc/meminfo
        MEM_TOTAL=$(awk -v t="$mem_t" 'BEGIN{printf "%.1f", t/1024/1024}')
        MEM_AVAIL=$(awk -v a="$mem_a" 'BEGIN{printf "%.1f", a/1024/1024}')
        [ "${mem_t:-0}" -gt 0 ] && MEM_USED=$(( (mem_t - mem_a) * 100 / mem_t ))

        SWAP_USED="0M"
        read -r sw_total sw_free < <(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t+0, f+0}' /proc/meminfo 2>/dev/null)
        SWAP_USED="$(( (sw_total - sw_free) / 1024 ))M"

        DSTATE=$(ps -eo stat 2>/dev/null | grep -c '^D')
        DSTATE=$(to_int "$DSTATE")
        OOM_COUNT=$(dmesg 2>/dev/null | tail -100 | grep -c "Out of memory\|oom-kill")
        OOM_COUNT=$(to_int "$OOM_COUNT")

        # Color selection (no subshell)
        iowait_col="${GREEN_S}"
        [ "$IOWAIT_PCT" -ge 20 ] && iowait_col="${ORANGE}"
        [ "$IOWAIT_PCT" -ge 50 ] && iowait_col="${RED}${BOLD}"
        mem_col="${GREEN_S}"
        [ "$MEM_USED" -ge 80 ] && mem_col="${ORANGE}"
        [ "$MEM_USED" -ge 95 ] && mem_col="${RED}${BOLD}"
        oom_col="${GREEN_S}"
        [ "$OOM_COUNT" -ge 1 ] && oom_col="${RED}${BOLD}${BLINK}"

        printf "${CYAN}${BOLD}  SYSTEM PRESSURE${R}"
        if [ "$IOWAIT_PCT" -ge 50 ] || [ "$MEM_USED" -ge 95 ] || [ "$OOM_COUNT" -ge 1 ]; then
            printf "  ${BG_ALERT}${RED}${BOLD}${BLINK} HIGH LOAD ${R}"
        fi
        printf "\n"
        printf "  ${DGRAY}iowait:${R} ${iowait_col}${BOLD}%s%%${R}  " "${IOWAIT_PCT}"
        printf "${DGRAY}mem:${R} ${mem_col}${BOLD}%s%%${R} (${WHITE}${MEM_AVAIL}G/${MEM_TOTAL}G${R})  " "$MEM_USED"
        printf "${DGRAY}swap:${R} ${WHITE}${BOLD}%s${R}  " "$SWAP_USED"
        printf "${DGRAY}D-state:${R} ${WHITE}${BOLD}%s${R}  " "$DSTATE"
        printf "${DGRAY}OOM:${R} ${oom_col}${BOLD}%s${R}\n" "$OOM_COUNT"
    }
    hline '-' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 1: CPU (left) | Memory (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    {
        printf "${YELLOW}${BOLD}  TOP CPU PROCESSES${R}\n"
        printf "  ${DGRAY}%-4s %-26s %s${R}\n" "#" "PROCESS" "CPU%"
        printf "  ${DGRAY}%-4s %-26s %s${R}\n" "--" "-------------------------" "----"
        n=0
        ps -eo comm,%cpu --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=7{print $1,$2}' | \
        while read -r proc pct; do
            n=$((n+1))
            pc=$(color_pct "$pct" 50 20)
            printf "  ${GRAY}%2d${R}  ${WHITE}%-26.26s${R}  ${pc}%s%%${R}\n" "$n" "$proc" "$pct"
        done
    } > "$C1"

    {
        printf "${YELLOW}${BOLD}  TOP MEMORY PROCESSES${R}\n"
        printf "  ${DGRAY}%-4s %-26s %s${R}\n" "#" "PROCESS" "MEM%"
        printf "  ${DGRAY}%-4s %-26s %s${R}\n" "--" "-------------------------" "----"
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
    hline '-' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 2: Top URLs (left) | Top IPs (right)
    #  FIX: v2 had IPs duplicated on both sides
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT: Top URLs
    {
        printf "${CYAN}${BOLD}  TOP URLs${R}\n"
        printf "  ${DGRAY}%-8s  %-20s  %s${R}\n" "HITS" "DOMAIN" "URL"
        printf "  ${DGRAY}%-8s  %-20s  %s${R}\n" "--------" "--------------------" "--------------------"

        if [ -f /tmp/mon_top_urls.dat ]; then
            head -8 /tmp/mon_top_urls.dat | \
            while read -r count dom url; do
                [ -z "$url" ] && continue
                local short_url="$url"
                [ "${#url}" -gt 28 ] && short_url="${url:0:27}…"
                printf "  ${ORANGE}%-8s${R}  ${GREEN_S}%-20.20s${R}  ${YELLOW}%s${R}\n" \
                    "$count" "$dom" "$short_url"
            done
        else
            printf "  ${GRAY}${DIM}(no data yet)${R}\n"
        fi
    } > "$C1"

    # RIGHT: Top IPs with enrichment
    {
        printf "${CYAN}${BOLD}  TOP IPs & TRAFFIC${R}\n"
        printf "  ${DGRAY}%-8s  %-4s  %-6s  %-18s  %-12s${R}\n" \
            "HITS" "CC" "ABUSE" "IP ADDRESS" "DELTA"
        printf "  ${DGRAY}%-8s  %-4s  %-6s  %-18s  %-12s${R}\n" \
            "--------" "----" "------" "------------------" "------------"

        if [ -f /tmp/mon_top_ips.dat ]; then
            # Prefetch enrichment for all IPs (one batch)
            awk '{print $2}' /tmp/mon_top_ips.dat | head -8 > /tmp/mon_ips_to_enrich.tmp
            _enrich_ips_bulk /tmp/mon_ips_to_enrich.tmp
            rm -f /tmp/mon_ips_to_enrich.tmp

            local new_state_file
            new_state_file=$(mktemp)

            head -8 /tmp/mon_top_ips.dat | \
            while read -r count ip; do
                [ -z "$ip" ] && continue
                count=$(to_int "$count")
                echo "$ip $count" >> "$new_state_file"

                # In-memory cache lookup
                local cached_data
                cached_data=$(_ip_get_cached "$ip")
                local lscore lcc lisp
                lscore=$(echo "$cached_data" | cut -d'|' -f1)
                lcc=$(echo "$cached_data" | cut -d'|' -f2)
                lisp=$(echo "$cached_data" | cut -d'|' -f3)
                local acol
                acol=$(_abuse_colour "$lscore")

                # Delta
                local prev chg
                prev=$(grep "^$ip " "$IP_STATE_FILE" 2>/dev/null | awk '{print $2+0}' | head -1)
                prev=$(to_int "$prev")
                if [ "$prev" -gt 0 ]; then
                    local diff=$(( count - prev ))
                    if   [ "$diff" -gt 100 ]; then chg="${RED}${BOLD}+${diff}${R}"
                    elif [ "$diff" -gt   0 ]; then chg="${ORANGE}+${diff}${R}"
                    elif [ "$diff" -lt   0 ]; then chg="${GREEN_S}${diff}${R}"
                    else                           chg="${DGRAY}-${R}"
                    fi
                else
                    chg="${CYAN}${BOLD}NEW${R}"
                fi

                printf "  ${ORANGE}%-8s${R}  " "$count"
                printf "${GRAY}%-4s${R}  " "$lcc"
                printf "${acol}%-6s${R}  " "$lscore"
                printf "${CYAN_S}%-18.18s${R}  " "$ip"
                printf "%b\n" "$chg"
            done

            mv "$new_state_file" "$IP_STATE_FILE" 2>/dev/null
        else
            printf "  ${GRAY}${DIM}(no data yet)${R}\n"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '-' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 3: Network (left) | WP-Login (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT: Network connections
    {
        printf "${CYAN}${BOLD}  NETWORK CONNECTIONS${R}\n"
        printf "  ${DGRAY}%-24s %s${R}\n" "STATE" "COUNT"
        printf "  ${DGRAY}%-24s %s${R}\n" "-----------------------" "-----"
        netstat -ant 2>/dev/null | awk '{print $6}' \
            | grep -v 'State\|Foreign\|^$' \
            | sort | uniq -c | sort -nr | head -8 | \
        while read -r cnt state; do
            [ -z "$state" ] && continue
            local sc
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

        # SYN_RECV detail
        local syn_raw syn_count
        syn_raw=$(netstat -ant 2>/dev/null | grep "SYN_RECV")
        syn_count=$(echo "$syn_raw" | grep -c "SYN_RECV")
        syn_count=$(to_int "$syn_count")

        if [ "$syn_count" -gt 20 ]; then
            printf "\n  ${RED}${BOLD}${BLINK}SYN FLOOD: %s SYN_RECV${R}\n" "$syn_count"
            echo "$syn_raw" | awk '{
                foreign=$5; sub(/:[^:]+$/,"",foreign); gsub(/[\[\]]/,"",foreign)
                dst=$4; sub(/.*:/,"",dst)
                print foreign, dst
            }' | sort | uniq -c | sort -nr | head -10 | \
            while read -r cnt src_ip dst_port; do
                [ -z "$src_ip" ] && continue
                local flag ip_col
                if [ "$cnt" -gt 5 ]; then
                    flag="${RED}${BOLD}FLOOD${R}"; ip_col="${RED}${BOLD}"
                else
                    flag="${DGRAY}-${R}"; ip_col="${ORANGE}"
                fi
                printf "  ${ip_col}%-6s  %-18s${R}  ${GRAY}%-8s${R}  %b\n" "$cnt" "$src_ip" "$dst_port" "$flag"
            done
        elif [ "$syn_count" -gt 0 ]; then
            printf "\n  ${ORANGE}SYN_RECV: %s active${R}\n" "$syn_count"
        fi
    } > "$C1"

    # RIGHT: WP-Login monitor
    {
        local WL_NOW WL_CUR_MIN WL_PREV_MIN
        WL_NOW=$(date "+%H:%M:%S")
        WL_CUR_MIN=$(date "+%d/%b/%Y:%H:%M")
        WL_PREV_MIN=$(date -d "1 minute ago" "+%d/%b/%Y:%H:%M" 2>/dev/null || \
                      date -v-1M "+%d/%b/%Y:%H:%M" 2>/dev/null)

        # Use pre-extracted wp-login data
        local WL_TMP="/tmp/mon_wplogin.dat"
        local wplogin_total=0 wplogin_recent=0

        if [ -f "$WL_TMP" ]; then
            # Apply exclusions if configured
            if [ -n "$WL_EXCLUDE_IPS" ]; then
                local filtered_wl
                filtered_wl=$(mktemp)
                cp "$WL_TMP" "$filtered_wl"
                for excl_ip in $WL_EXCLUDE_IPS; do
                    grep -v " ${excl_ip} " "$filtered_wl" > "${filtered_wl}.tmp" && \
                        mv "${filtered_wl}.tmp" "$filtered_wl"
                done
                wplogin_total=$(wc -l < "$filtered_wl" | tr -d '[:space:]')
                wplogin_recent=$(grep -c "${WL_CUR_MIN}\|${WL_PREV_MIN}" "$filtered_wl" 2>/dev/null)
                # Use filtered file for rendering
                WL_TMP="$filtered_wl"
            else
                wplogin_total=$(wc -l < "$WL_TMP" | tr -d '[:space:]')
                wplogin_recent=$(grep -c "${WL_CUR_MIN}\|${WL_PREV_MIN}" "$WL_TMP" 2>/dev/null)
            fi
        fi
        wplogin_total=$(to_int "$wplogin_total")
        wplogin_recent=$(to_int "$wplogin_recent")

        # Status indicator
        local status_dot status_label
        if [ "$wplogin_recent" -gt 0 ]; then
            status_dot="${RED}${BOLD}${BLINK}*${R}"
            status_label="${RED}${BOLD}  WP-LOGIN — ACTIVE${R}"
        elif [ "$wplogin_total" -gt 0 ]; then
            status_dot="${ORANGE}${BOLD}*${R}"
            status_label="${ORANGE}${BOLD}  WP-LOGIN — PRIOR HITS${R}"
        else
            status_dot="${GREEN_S}*${R}"
            status_label="${GREEN_S}${BOLD}  WP-LOGIN — CLEAR${R}"
        fi

        printf "  %b ${DGRAY}WP-LOGIN MONITOR${R}  ${DIM}%s${R}\n" "$status_dot" "$WL_NOW"
        printf "%b\n" "$status_label"

        if [ "$wplogin_total" -gt 0 ] && [ -f "$WL_TMP" ]; then
            printf "  ${DGRAY}Total:${R} ${ORANGE}${BOLD}%s${R}  " "$wplogin_total"
            printf "${DGRAY}Active (2m):${R} "
            if [ "$wplogin_recent" -gt 0 ]; then
                printf "${RED}${BOLD}%s${R}\n" "$wplogin_recent"
            else
                printf "${GREEN_S}0${R}\n"
            fi

            printf "\n  ${DGRAY}%-6s  %-4s  %-6s  %-18s  %-18s  %s${R}\n" \
                "HITS" "CC" "ABUSE" "IP" "DOMAIN" "METHOD"
            printf "  ${DGRAY}%-6s  %-4s  %-6s  %-18s  %-18s  %s${R}\n" \
                "------" "----" "------" "------------------" "------------------" "------"

            # Aggregate
            local AGG_TMP
            AGG_TMP=$(mktemp)
            awk '{
                key=$1 SUBSEP $2 SUBSEP $4 SUBSEP $5
                count[key]++
                if($3>last[key]) last[key]=$3
            } END {
                for(k in count) {
                    split(k,f,SUBSEP)
                    print count[k], f[1], f[2], f[3], f[4], last[k]
                }
            }' "$WL_TMP" | sort -rn > "$AGG_TMP"

            # Prefetch enrichment
            awk '{print $3}' "$AGG_TMP" | sort -u > /tmp/mon_wl_ips.tmp
            _enrich_ips_bulk /tmp/mon_wl_ips.tmp
            rm -f /tmp/mon_wl_ips.tmp

            head -8 "$AGG_TMP" | \
            while read -r hits dom ip method status ts; do
                [ -z "$ip" ] && continue
                local cached_data lscore lcc acol
                cached_data=$(_ip_get_cached "$ip")
                lscore=$(echo "$cached_data" | cut -d'|' -f1)
                lcc=$(echo "$cached_data" | cut -d'|' -f2)
                acol=$(_abuse_colour "$lscore")

                local mfmt
                [ "$method" = "POST" ] && mfmt="${RED}${BOLD}POST${R}" || mfmt="${GREEN_S}GET${R}"

                printf "  ${ORANGE}%-6s${R}  " "$hits"
                printf "${GRAY}%-4s${R}  " "$lcc"
                printf "${acol}%-6s${R}  " "$lscore"
                printf "${CYAN_S}%-18.18s${R}  " "$ip"
                printf "${GREEN_S}%-18.18s${R}  " "$dom"
                printf "%b\n" "$mfmt"
            done

            rm -f "$AGG_TMP"
        else
            printf "  ${GREEN_S}No wp-login.php hits detected.${R}\n"
        fi

        # Clean up filtered temp if we created one
        [ -n "$WL_EXCLUDE_IPS" ] && [ -f "$WL_TMP" ] && [ "$WL_TMP" != "/tmp/mon_wplogin.dat" ] && rm -f "$WL_TMP"
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '-' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 4: File Changes (left) | PHP Slowlog (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    {
        local CUR_TIME LAST_FILE_SCAN
        CUR_TIME=$(date +%s)
        LAST_FILE_SCAN=$(cat "$FILE_SCAN_TS" 2>/dev/null | tr -d '[:space:]')
        LAST_FILE_SCAN=$(to_int "$LAST_FILE_SCAN")

        if (( CUR_TIME - LAST_FILE_SCAN > SCAN_INTERVAL )); then
            # Use find -printf instead of stat per file
            find /home/nginx/domains/*/public/wp-content/{plugins,themes} \
                -maxdepth 3 -mmin -1440 -type f \
                \( -name "*.php" -o -name "*.js" \) \
                -printf '%h\t%Ty-%Tm-%Td %TH:%TM\n' 2>/dev/null | \
            awk -F'\t' '{
                # Parse: /home/nginx/domains/DOM/public/wp-content/TYPE/PLUGIN/...
                n = split($1, parts, "/")
                if (n >= 9) {
                    dom = parts[5]; ftype = parts[8]; plugin = parts[9]
                    key = dom "\t" ftype "\t" plugin
                    count[key]++
                    if ($2 > latest[key]) latest[key] = $2
                }
            } END {
                for (k in count) {
                    split(k, p, "\t")
                    printf "%s\t%s\t%s\t%d\t%s\n", p[1], p[2], p[3], count[k], latest[k]
                }
            }' | sort -t$'\t' -k5,5r | head -12 > "$FILE_CACHE"
            echo "$CUR_TIME" > "$FILE_SCAN_TS"
        fi

        printf "${ORANGE}${BOLD}  FILE CHANGES (24h, scan/15m)${R}\n"
        printf "  ${DGRAY}%-20s %-7s %-6s %-26s %s${R}\n" \
            "DOMAIN" "TYPE" "FILES" "PLUGIN/THEME" "MODIFIED"
        printf "  ${DGRAY}%-20s %-7s %-6s %-26s %s${R}\n" \
            "--------------------" "-------" "------" "--------------------------" "-------------------"

        if [ -s "$FILE_CACHE" ]; then
            while IFS=$'\t' read -r dom ftype plugin count modtime; do
                local t_col t_label c_col
                [ "$ftype" = "plugins" ] && { t_col="${CYAN}"; t_label="Plugin"; } || { t_col="${MAGENTA}"; t_label="Theme"; }
                count=$(to_int "$count")
                [ "$count" -gt 5 ] && c_col="${ORANGE}" || c_col="${GREEN_S}"
                printf "  ${GREEN_S}%-20.20s${R} ${t_col}%-7s${R} ${c_col}%-6s${R} ${YELLOW}%-26.26s${R} ${GRAY}%s${R}\n" \
                    "$dom" "$t_label" "$count" "$plugin" "$modtime"
            done < "$FILE_CACHE"
        else
            printf "  ${GRAY}${DIM}(no changes in last 24h)${R}\n"
        fi
    } > "$C1"

    {
        if [ -f "$SLOWLOG" ]; then
            printf "${RED_S}${BOLD}  PHP SLOWLOG — TOP CULPRITS${R}\n"
            printf "  ${DGRAY}%-8s %-24s %s${R}\n" "COUNT" "DOMAIN" "PLUGIN"
            printf "  ${DGRAY}%-8s %-24s %s${R}\n" "--------" "------------------------" "----------------------"
            grep "wp-content/plugins/" "$SLOWLOG" | \
            sed -rn 's/.*\/domains\/([^/]+)\/.*plugins\/([^/ ]+).*/\1 \2/p' | \
            sort | uniq -c | sort -nr | head -8 | \
            while read -r cnt dom plugin; do
                printf "  ${ORANGE}%-8s${R}  ${GREEN_S}%-24.24s${R}  ${RED_S}%-22.22s${R}\n" "$cnt" "$dom" "$plugin"
            done
        else
            printf "${GRAY}${DIM}  PHP SLOWLOG${R}\n"
            printf "  ${GRAY}${DIM}(not found)${R}\n"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '-' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 5: LIVE TRAFFIC — FULL WIDTH
    # ════════════════════════════════════════════
    {
        printf "${CYAN}${BOLD}  LIVE TRAFFIC${R}  ${DGRAY}(minute: %s)${R}\n" "$CUR_MIN"

        local LIVE_DATA="/tmp/mon_live_traffic.dat"

        if [ -s "$LIVE_DATA" ]; then
            # Prefetch enrichment for all live IPs
            awk '{print $2}' "$LIVE_DATA" | sort -u > /tmp/mon_live_ips.tmp
            _enrich_ips_bulk /tmp/mon_live_ips.tmp
            rm -f /tmp/mon_live_ips.tmp

            # Sub-section: Top IPs this minute
            printf "\n  ${CYAN}${DIM}Top IPs this minute${R}\n"
            printf "  ${DGRAY}%-6s  %-4s  %-6s  %-18s  %-20s  %s${R}\n" \
                "HITS" "CC" "ABUSE" "IP" "DOMAIN" "DELTA"
            printf "  ${DGRAY}%-6s  %-4s  %-6s  %-18s  %-20s  %s${R}\n" \
                "------" "----" "------" "------------------" "--------------------" "--------"

            local vel_new
            vel_new=$(mktemp)

            awk '{print $1, $2}' "$LIVE_DATA" | sort | uniq -c | sort -nr | head -10 | \
            while read -r count dom ip; do
                [ -z "$ip" ] && continue
                count=$(to_int "$count")

                local cached_data lscore lcc lisp acol
                cached_data=$(_ip_get_cached "$ip")
                lscore=$(echo "$cached_data" | cut -d'|' -f1)
                lcc=$(echo "$cached_data" | cut -d'|' -f2)
                lisp=$(echo "$cached_data" | cut -d'|' -f3)
                acol=$(_abuse_colour "$lscore")

                local state_key="${dom}|${ip}"
                local prev delta
                prev=$(grep "^${state_key}=" "$LIVE_VEL_STATE" 2>/dev/null | head -1 | rev | cut -d'=' -f1 | rev)
                prev=$(to_int "$prev")

                if [ "$prev" -eq 0 ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                else
                    local diff=$(( count - prev ))
                    if   [ "$diff" -gt 5 ]; then delta="${RED}${BOLD}+${diff}${R}"
                    elif [ "$diff" -gt 0 ]; then delta="${ORANGE}+${diff}${R}"
                    elif [ "$diff" -lt 0 ]; then delta="${GREEN_S}${diff}${R}"
                    else                          delta="${DGRAY}-${R}"
                    fi
                fi
                echo "${state_key}=${count}" >> "$vel_new"

                printf "  ${ORANGE}%-6s${R}  " "$count"
                printf "${GRAY}%-4s${R}  " "$lcc"
                printf "${acol}%-6s${R}  " "$lscore"
                printf "${CYAN_S}%-18.18s${R}  " "$ip"
                printf "${GREEN_S}%-20.20s${R}  " "$dom"
                printf "%b\n" "$delta"
            done
            mv "$vel_new" "$LIVE_VEL_STATE" 2>/dev/null

            # Sub-section: URL breakdown
            printf "\n  ${CYAN}${DIM}URL breakdown${R}\n"
            printf "  ${DGRAY}%-6s  %-18s  %-20s  %-6s  %-${COL_LV_URL}s  %s${R}\n" \
                "HITS" "IP" "DOMAIN" "METH" "URL" "ST"
            printf "  ${DGRAY}%-6s  %-18s  %-20s  %-6s  %-${COL_LV_URL}s  %s${R}\n" \
                "------" "------------------" "--------------------" "------" \
                "$(printf -- '-%.0s' $(seq 1 $COL_LV_URL))" "--"

            local url_new
            url_new=$(mktemp)

            awk '{
                key=$1 "\t" $2 "\t" $3 "\t" $4 "\t" $5
                count[key]++
            } END {
                for (k in count) print count[k] "\t" k
            }' "$LIVE_DATA" | sort -t$'\t' -k1,1rn | head -15 | \
            while IFS=$'\t' read -r hits dom ip meth url status; do
                [ -z "$url" ] && continue
                hits=$(to_int "$hits")

                local cached_data lscore lcc acol
                cached_data=$(_ip_get_cached "$ip")
                lscore=$(echo "$cached_data" | cut -d'|' -f1)
                lcc=$(echo "$cached_data" | cut -d'|' -f2)
                acol=$(_abuse_colour "$lscore")

                local state_key="${dom}|${ip}|${url}"
                local prev delta
                prev=$(grep -F "${state_key}=" "$LIVE_URL_STATE" 2>/dev/null | head -1 | rev | cut -d'=' -f1 | rev)
                prev=$(to_int "$prev")
                if [ "$prev" -eq 0 ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                else
                    local diff=$(( hits - prev ))
                    if   [ "$diff" -gt 0 ]; then delta="${RED}${BOLD}+${diff}${R}"
                    elif [ "$diff" -lt 0 ]; then delta="${GREEN_S}${diff}${R}"
                    else                          delta="${DGRAY}-${R}"
                    fi
                fi
                echo "${state_key}=${hits}" >> "$url_new"

                local mc sc
                case "$meth" in POST|PUT|DELETE) mc="${RED_S}" ;; GET) mc="${CYAN_S}" ;; *) mc="${GRAY}" ;; esac
                case "${status:0:1}" in 5) sc="${RED}${BOLD}" ;; 4) sc="${ORANGE}" ;; 3) sc="${YELLOW}" ;; *) sc="${GREEN_S}" ;; esac

                [ "${#url}" -gt "$COL_LV_URL" ] && url="${url:0:$(( COL_LV_URL - 1 ))}…"

                printf "  ${ORANGE}%-6s${R}  " "$hits"
                printf "${CYAN_S}%-18.18s${R}  " "$ip"
                printf "${GREEN_S}%-20.20s${R}  " "$dom"
                printf "${mc}%-6s${R}  " "$meth"
                printf "${YELLOW}%-${COL_LV_URL}s${R}  " "$url"
                printf "${sc}%s${R}\n" "$status"
            done
            mv "$url_new" "$LIVE_URL_STATE" 2>/dev/null
        else
            printf "  ${GRAY}${DIM}(no traffic in current minute — waiting...)${R}\n"
        fi
    }
    hline '-' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 6: NGINX ERROR LOG — FULL WIDTH
    # ════════════════════════════════════════════
    {
        printf "${RED_S}${BOLD}  NGINX ERROR LOG${R}\n"
        printf "  ${DGRAY}%-20s %-18s %-6s %-16s %-22s %s${R}\n" \
            "DOMAIN" "LAST SEEN" "NEW" "CLIENT" "REQUEST" "ERROR"
        printf "  ${DGRAY}%-20s %-18s %-6s %-16s %-22s %s${R}\n" \
            "--------------------" "------------------" "------" "----------------" "----------------------" \
            "$(printf -- '-%.0s' $(seq 1 $COL_ERR_SNIPPET))"

        local NEW_ERR_STATE found_any=0
        NEW_ERR_STATE=$(mktemp)

        for errlog in $ERRORLOG_PATH; do
            [ -f "$errlog" ] || continue
            local domain
            domain=$(echo "$errlog" | cut -d'/' -f5)

            # Collect into a temp file to avoid subshell variable loss
            local err_tmp
            err_tmp=$(mktemp)

            tail -n 200 "$errlog" 2>/dev/null | awk '
            /\[error\]/ {
                ts = $1 " " $2
                snippet = ""
                for (i=5; i<=NF; i++) snippet = snippet " " $i
                sub(/^ \*[0-9]+ /, "", snippet)

                client = ""
                if (match(snippet, /client: ([0-9.]+|[0-9a-f:]+)/, arr))
                    client = arr[1]

                req = ""
                if (match(snippet, /request: "([^"]+)"/, arr2)) {
                    req = arr2[1]
                    sub(/ HTTP\/[0-9.]+$/, "", req)
                }

                core = snippet
                sub(/, client:.*$/, "", core)
                gsub(/^[ \t]+|[ \t]+$/, "", core)

                key = client "|" req "|" core
                if (!(key in seen)) {
                    seen[key] = 1
                    latest_ts[key] = ts
                    client_ip[key] = client
                    request[key] = req
                    message[key] = core
                } else {
                    if (ts > latest_ts[key]) latest_ts[key] = ts
                }
                total[key]++
            }
            END {
                for (k in seen)
                    printf "%s\t%s\t%d\t%s\t%s\n", latest_ts[k], client_ip[k], total[k], request[k], message[k]
            }' | sort -t$'\t' -k1,1r | head -4 > "$err_tmp"

            while IFS=$'\t' read -r ts client cnt req msg; do
                [ -z "$ts" ] && continue
                found_any=1
                cnt=$(to_int "$cnt")

                local state_key="${domain}|${client}|${req}"
                echo "${state_key}=${cnt}" >> "$NEW_ERR_STATE"

                local prev_cnt delta
                prev_cnt=$(grep -F "${state_key}=" "$ERRLOG_STATE" 2>/dev/null | head -1 | rev | cut -d'=' -f1 | rev)
                prev_cnt=$(to_int "$prev_cnt")

                if [ "$prev_cnt" -gt 0 ] && [ "$cnt" -ne "$prev_cnt" ]; then
                    local diff=$(( cnt - prev_cnt ))
                    [ "$diff" -gt 0 ] && delta="${RED}${BOLD}+${diff}${R}" || delta="${GREEN_S}${diff}${R}"
                elif [ "$prev_cnt" -eq 0 ]; then
                    delta="${ORANGE}${BOLD}NEW${R}"
                else
                    delta="${DGRAY}-${R}"
                fi

                local msg_short="${msg:0:$COL_ERR_SNIPPET}"
                printf "  ${GREEN_S}%-20.20s${R}" "$domain"
                printf " ${GRAY}%-18.18s${R}" "$ts"
                printf " %-6b" "$delta"
                printf " ${RED_S}%-16.16s${R}" "$client"
                printf " ${CYAN}%-22.22s${R}" "$req"
                printf " ${WHITE}%s${R}\n" "$msg_short"
            done < "$err_tmp"
            rm -f "$err_tmp"
        done

        [ -s "$NEW_ERR_STATE" ] && mv "$NEW_ERR_STATE" "$ERRLOG_STATE" || rm -f "$NEW_ERR_STATE"

        if [ "$found_any" -eq 0 ]; then
            printf "  ${GREEN_S}${DIM}(no errors in nginx logs)${R}\n"
        fi
    }
    hline '-' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 7: PHP-FPM (left) | MySQL Health (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    {
        printf "${CYAN}${BOLD}  PHP-FPM POOLS${R}\n"
        printf "  ${DGRAY}%-20s %-7s %-6s %-6s %-7s %s${R}\n" \
            "POOL" "ACTIVE" "IDLE" "MAX" "QUEUE" "STATUS"
        printf "  ${DGRAY}%-20s %-7s %-6s %-6s %-7s %s${R}\n" \
            "--------------------" "------" "-----" "-----" "------" "----------"

        local fpm_found=0

        if command -v cgi-fcgi &>/dev/null; then
            for sock in /var/run/php*.sock /run/php/*.sock /tmp/php*.sock; do
                [ -S "$sock" ] || continue
                local pool status_raw active idle maxc queue
                pool=$(basename "$sock" .sock | sed 's/php[0-9.-]*-fpm-\?//')
                [ -z "$pool" ] && pool=$(basename "$sock" .sock)

                status_raw=$(SCRIPT_FILENAME=/status SCRIPT_NAME=/status \
                    REQUEST_METHOD=GET cgi-fcgi -bind -connect "$sock" 2>/dev/null)

                active=$(echo "$status_raw" | awk '/^active processes:/{print $NF}')
                idle=$(echo "$status_raw"   | awk '/^idle processes:/{print $NF}')
                maxc=$(echo "$status_raw"   | awk '/^max children reached/{print $NF}')
                queue=$(echo "$status_raw"  | awk '/^listen queue:/{print $NF}')

                [ -z "$active" ] && continue
                fpm_found=1

                local total pct st
                total=$(( ${active:-0} + ${idle:-0} ))
                [ "$total" -eq 0 ] && total=1
                pct=$(( active * 100 / total ))

                if [ "${active:-0}" -ge "${maxc:-999}" ] 2>/dev/null; then
                    st="${RED}${BOLD}SATURATED${R}"
                elif [ "$pct" -ge 80 ]; then
                    st="${ORANGE}HIGH${R}"
                else
                    st="${GREEN_S}OK${R}"
                fi

                printf "  ${WHITE}%-20.20s${R} ${ORANGE}%-7s${R} ${GRAY}%-6s${R} ${DGRAY}%-6s${R} ${YELLOW}%-7s${R} %b\n" \
                    "$pool" "$active" "$idle" "${maxc:-?}" "$queue" "$st"
            done
        fi

        if [ "$fpm_found" -eq 0 ]; then
            local fpm_count
            fpm_count=$(ps -eo comm 2>/dev/null | grep -c "php-fpm\|php[0-9].*-fpm")
            if [ "${fpm_count:-0}" -gt 0 ]; then
                printf "  ${WHITE}%-20s${R} ${GRAY}%s workers detected${R}\n" "php-fpm" "$fpm_count"
            else
                printf "  ${GRAY}${DIM}(php-fpm not detected)${R}\n"
            fi
        fi
    } > "$C1"

    {
        printf "${MAGENTA}${BOLD}  MYSQL HEALTH${R}\n"
        printf "  ${DGRAY}%-18s %s${R}\n" "METRIC" "VALUE"
        printf "  ${DGRAY}%-18s %s${R}\n" "------------------" "--------------"

        local mysql_health
        mysql_health=$(mysql --batch --silent -e "
            SHOW GLOBAL STATUS WHERE Variable_name IN (
                'Threads_connected','Threads_running','Questions',
                'Slow_queries','Table_locks_waited',
                'Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests',
                'Innodb_row_lock_waits','Aborted_connects'
            );
            SHOW VARIABLES WHERE Variable_name = 'max_connections';" 2>/dev/null)

        if [ -z "$mysql_health" ]; then
            printf "  ${GRAY}${DIM}(mysql not accessible)${R}\n"
        else
            get_val() { echo "$mysql_health" | awk -v k="$1" '$1==k{print $2}'; }

            local threads_conn threads_run max_conn questions slow_q
            local lock_wait bp_reads bp_req row_locks aborted
            threads_conn=$(get_val "Threads_connected")
            threads_run=$(get_val "Threads_running")
            max_conn=$(get_val "max_connections")
            questions=$(get_val "Questions")
            slow_q=$(get_val "Slow_queries")
            lock_wait=$(get_val "Table_locks_waited")
            bp_reads=$(get_val "Innodb_buffer_pool_reads")
            bp_req=$(get_val "Innodb_buffer_pool_read_requests")
            row_locks=$(get_val "Innodb_row_lock_waits")
            aborted=$(get_val "Aborted_connects")

            # Coerce to int
            threads_conn=$(to_int "$threads_conn")
            threads_run=$(to_int "$threads_run")
            max_conn=$(to_int "$max_conn")
            questions=$(to_int "$questions")
            slow_q=$(to_int "$slow_q")
            lock_wait=$(to_int "$lock_wait")
            bp_reads=$(to_int "$bp_reads")
            bp_req=$(to_int "$bp_req")

            # QPS — use actual elapsed time, not assumed 20s
            local prev_q prev_ts QPS
            prev_q=$(cat "$MYSQL_QPS_STATE" 2>/dev/null | tr -d '[:space:]')
            prev_ts=$(cat "$MYSQL_QPS_TS" 2>/dev/null | tr -d '[:space:]')
            prev_q=$(to_int "$prev_q")
            prev_ts=$(to_int "$prev_ts")
            QPS=0
            local now_ts
            now_ts=$(date +%s)
            if [ "$prev_q" -gt 0 ] && [ "$questions" -ge "$prev_q" ] && [ "$prev_ts" -gt 0 ]; then
                local elapsed=$(( now_ts - prev_ts ))
                [ "$elapsed" -le 0 ] && elapsed=1
                QPS=$(( (questions - prev_q) / elapsed ))
                [ "$QPS" -lt 0 ] && QPS=0
            fi
            echo "$questions" > "$MYSQL_QPS_STATE"
            echo "$now_ts"    > "$MYSQL_QPS_TS"

            # InnoDB buffer pool hit rate
            local BP_HIT="n/a"
            if [ "$bp_req" -gt 0 ]; then
                BP_HIT=$(awk -v r="$bp_reads" -v req="$bp_req" 'BEGIN{printf "%.1f%%", (1-(r/req))*100}')
            fi

            # Thresholds
            local conn_pct=0
            [ "$max_conn" -gt 0 ] && conn_pct=$(( threads_conn * 100 / max_conn ))

            local conn_col="${GREEN_S}" run_col="${GREEN_S}" slow_col="${GREEN_S}"
            local lock_col="${GREEN_S}" qps_col="${GREEN_S}"
            [ "$conn_pct"    -ge 70  ] && conn_col="${ORANGE}";  [ "$conn_pct"    -ge 90   ] && conn_col="${RED}${BOLD}"
            [ "$threads_run" -ge 10  ] && run_col="${ORANGE}";   [ "$threads_run" -ge 30   ] && run_col="${RED}${BOLD}"
            [ "$slow_q"      -ge 5   ] && slow_col="${ORANGE}";  [ "$slow_q"      -ge 20   ] && slow_col="${RED}${BOLD}"
            [ "$lock_wait"   -ge 1   ] && lock_col="${ORANGE}";  [ "$lock_wait"   -ge 10   ] && lock_col="${RED}${BOLD}"
            [ "$QPS"         -ge 500 ] && qps_col="${ORANGE}";   [ "$QPS"         -ge 2000 ] && qps_col="${RED}${BOLD}"

            printf "  ${DGRAY}%-18s${R} ${conn_col}%s / %s${R} ${DGRAY}(%s%%)${R}\n" "Connections" "$threads_conn" "$max_conn" "$conn_pct"
            printf "  ${DGRAY}%-18s${R} ${run_col}%s${R}\n"  "Threads running" "$threads_run"
            printf "  ${DGRAY}%-18s${R} ${qps_col}%s q/s${R}\n" "QPS (actual)" "$QPS"
            printf "  ${DGRAY}%-18s${R} ${slow_col}%s${R}\n" "Slow queries" "$slow_q"
            printf "  ${DGRAY}%-18s${R} ${lock_col}%s${R}\n" "Table lock waits" "$lock_wait"
            printf "  ${DGRAY}%-18s${R} ${GREEN_S}%s${R}\n"  "InnoDB hit rate" "$BP_HIT"
            printf "  ${DGRAY}%-18s${R} ${ORANGE}%s${R}\n"   "Row lock waits" "$row_locks"
            printf "  ${DGRAY}%-18s${R} ${GRAY}%s${R}\n"     "Aborted connects" "$aborted"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '-' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 8: DISK I/O — FULL WIDTH
    # ════════════════════════════════════════════
    {
        printf "${YELLOW}${BOLD}  DISK I/O${R}\n"
        printf "  ${DGRAY}%-10s %-10s %-10s %-12s %-8s %s${R}\n" \
            "DEVICE" "READ/s" "WRITE/s" "AWAIT(ms)" "UTIL%" "STATUS"
        printf "  ${DGRAY}%-10s %-10s %-10s %-12s %-8s %s${R}\n" \
            "----------" "----------" "----------" "------------" "--------" "----------"

        if command -v iostat &>/dev/null; then
            # Use -y for fresh stats, 1 sample of 1 second
            iostat -xk -y 1 1 2>/dev/null | awk '
            /^(sd|nvme|vd|xvd|hd)[a-z0-9]/ {
                dev=$1; rkbs=$6; wkbs=$7; await=$10; util=$NF
                uc="\033[38;5;82m"
                if (util+0 >= 50) uc="\033[38;5;214m"
                if (util+0 >= 85) uc="\033[38;5;196m\033[1m"
                ac="\033[38;5;82m"
                if (await+0 >= 20) ac="\033[38;5;214m"
                if (await+0 >= 100) ac="\033[38;5;196m\033[1m"

                st="OK"; stc="\033[38;5;82m"
                if (util+0 >= 85 || await+0 >= 100) { st="HIGH"; stc="\033[38;5;196m\033[1m" }
                else if (util+0 >= 50 || await+0 >= 20) { st="BUSY"; stc="\033[38;5;214m" }

                printf "  \033[38;5;255m%-10s\033[0m %s%-9s\033[0m %s%-9s\033[0m %s%-10s\033[0m %s%-8s\033[0m %s%s\033[0m\n",
                    dev,
                    "\033[38;5;45m", sprintf("%.0fK", rkbs),
                    "\033[38;5;171m", sprintf("%.0fK", wkbs),
                    ac, sprintf("%.1fms", await),
                    uc, sprintf("%.0f%%", util),
                    stc, st
            }'
        else
            # Fallback: /proc/diskstats delta
            local snap1 snap2
            snap1=$(awk '/^[ ]*[0-9]+ [0-9]+ (sd|nvme|vd)/ {print $3,$6,$10,$13}' /proc/diskstats 2>/dev/null)
            sleep 1
            snap2=$(awk '/^[ ]*[0-9]+ [0-9]+ (sd|nvme|vd)/ {print $3,$6,$10,$13}' /proc/diskstats 2>/dev/null)
            paste <(echo "$snap1") <(echo "$snap2") | awk '{
                dev=$1
                dr=($6-$2)*512/1024; dw=($7-$3)*512/1024
                dio_ms=($8-$4)
                util=(dio_ms>1000)?100:(dio_ms>0?dio_ms/10:0)
                uc="\033[38;5;82m"
                if(util>=50) uc="\033[38;5;214m"
                if(util>=85) uc="\033[38;5;196m\033[1m"
                st="OK"; stc="\033[38;5;82m"
                if(util>=85){st="HIGH";stc="\033[38;5;196m\033[1m"}
                else if(util>=50){st="BUSY";stc="\033[38;5;214m"}
                printf "  \033[38;5;255m%-10s\033[0m \033[38;5;45m%-10s\033[0m \033[38;5;171m%-10s\033[0m \033[38;5;244m%-12s\033[0m %s%-8s\033[0m %s%s\033[0m\n",
                    dev, sprintf("%.0fK/s",dr), sprintf("%.0fK/s",dw), "n/a", uc, sprintf("%.0f%%",util), stc, st
            }'
        fi
    }
    hline '-' "$DGRAY"

    # ── FOOTER ────────────────────────────────────
    local LOOP_END LOOP_ELAPSED
    LOOP_END=$(date +%s)
    LOOP_ELAPSED=$(( LOOP_END - LOOP_START ))

    printf "\n"
    hline '=' "$BLUE_D"
    printf "  ${GRAY}${DIM}Refresh in ${R}${BOLD}${CYAN}${REFRESH_INTERVAL}s${R}  "
    printf "${DGRAY}|${R}  ${GRAY}${DIM}Frame: ${R}${WHITE}${LOOP_ELAPSED}s${R}  "
    printf "${DGRAY}|${R}  ${GRAY}${DIM}Ctrl+C to exit + report${R}\n"
    hline '=' "$BLUE_D"
    printf "\n"

}

while true; do
    render_frame > "$FRAME"

    clear
    cat "$FRAME"

    sleep "$REFRESH_INTERVAL"
done

rm -f "$FRAME"
