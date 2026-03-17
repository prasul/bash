#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  WordPress Security Scanner - Complete Edition
#  Bash 4.2+ compatible with confidence-based malware detection
#
#  Includes:
#  - WordPress Core Checksums
#  - Plugin Verification
#  - Theme Audits
#  - Database Malware Scanning
#  - Admin User Checks
#  - File Permissions
#  - PHP Malware Detection (Confidence-based)
#
#  Usage: bash wp-security-scanner.sh [directory] [confidence_threshold]
# ════════════════════════════════════════════════════════════════

set -eo pipefail

# ─────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────
SCAN_PATH="${1:-/home/nginx/domains}"
CONFIDENCE_THRESHOLD="${2:-80}"
REPORT_DIR="${REPORT_DIR:-/tmp/wp-security-reports}"
HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)

# ─────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────
if [ -t 1 ] && command -v tput &>/dev/null 2>&1; then
    RED=$(tput setaf 1; tput bold)
    GREEN=$(tput setaf 2; tput bold)
    YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RESET=$(tput sgr0)
else
    RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[0;33m'
    CYAN='\e[0;36m'; BOLD='\e[1m'; DIM='\e[2m'; RESET='\e[0m'
fi

info()    { echo -e "${CYAN}${*}${RESET}"; }
success() { echo -e "${GREEN}${*}${RESET}"; }
warn()    { echo -e "${YELLOW}${*}${RESET}"; }
error()   { echo -e "${RED}${*}${RESET}"; }

# ─────────────────────────────────────────────
# GLOBAL TRACKING
# ─────────────────────────────────────────────
REPORT_TMPDIR=$(mktemp -d)
TOTAL_ISSUES=0
TOTAL_SITES=0
CLEAN_SITES=0

# Tracking arrays (for summary)
CORE_FAILED=""
PLUGIN_FAILED=""
THEME_FAILED=""
PERM_FAILED=""
PHP_FAILED=""
DB_FAILED=""
USER_FAILED=""

# ─────────────────────────────────────────────
# HTML UTILITIES
# ─────────────────────────────────────────────
html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    echo "$s"
}

html_finding() {
    local frag="$1" severity="$2" check="$3" detail="$4"
    local badge_class="badge-info"
    case "$severity" in
        critical) badge_class="badge-critical" ;;
        warning)  badge_class="badge-warning"  ;;
    esac
    cat >> "$frag" <<ENDFINDING
            <tr>
              <td><span class="badge ${badge_class}">${severity}</span></td>
              <td class="check-name">$(html_escape "$check")</td>
              <td class="finding-detail">$(html_escape "$detail")</td>
            </tr>
ENDFINDING
}

# ─────────────────────────────────────────────
# WORDPRESS DETECTION
# ─────────────────────────────────────────────
is_wordpress_root() {
    local dir="$1"
    if [ -f "$dir/wp-config.php" ] || [ -f "$dir/wp-load.php" ] || [ -d "$dir/wp-content" ]; then
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────
# MALWARE PATTERNS (CONFIDENCE-BASED)
# ─────────────────────────────────────────────
CRITICAL_PATTERNS=(
    'eval\s*\(\s*base64_decode\s*\(\s*gzinflate'
    'eval\s*\(\s*base64_decode\s*\(\s*str_rot13'
    'assert\s*\(\s*base64_decode'
    'r57shell|c99shell|WSO\s*2\.[0-9]|b374k|FilesMan|ALFA_DATA'
    'anonymousfox|IndoXploit|alfa-shell|GanjaShell|fx29shell'
    'if\s*\(\s*md5\s*\(\s*\$_(GET|POST)\[.*\]\s*\)\s*==.*\)'
    '\$_(GET|POST)\[.{1,15}(pass|pwd|auth|key).\]\s*==.*md5'
    '[A-Za-z0-9+/=]{600,}'
    'preg_replace.*["\x27]/.*e["\x27]'
    '\\x65\\x76\\x61\\x6c|\\x73\\x79\\x73\\x74\\x65\\x6d'
    'call_user_func(_array)?\s*\(\s*\$_(GET|POST|REQUEST)\['
)

HIGH_RISK_PATTERNS=(
    'eval\s*\(\s*base64_decode\s*\('
    'eval\s*\(\s*gzinflate\s*\('
    'system\s*\(\s*\$_(GET|POST|REQUEST)\['
    'shell_exec\s*\(\s*\$_(GET|POST|REQUEST)\['
    'exec\s*\(\s*\$_(GET|POST|REQUEST)\['
    'passthru\s*\(\s*\$_(GET|POST|REQUEST)\['
    'file_put_contents\s*\(\s*\$_(GET|POST|REQUEST)\['
    'create_function\s*\(.*\$_(GET|POST|REQUEST)'
)

MEDIUM_RISK_PATTERNS=(
    'chr\s*\(\s*[0-9]+\s*\)\s*\.\s*chr\s*\(\s*[0-9]+\s*\)\s*\.\s*chr'
    'O0O0O+|l1l1l+|I1I1I+|OOO000O'
)

# ─────────────────────────────────────────────
# DATABASE PATTERNS
# ─────────────────────────────────────────────
DB_PATTERNS=(
    '<script[^>]*src=["\x27]https\?://'
    'eval\s*\('
    'base64_decode\s*\('
    'atob\s*\('
    'String\.fromCharCode\s*\('
    '<iframe[^>]*style=["\x27][^"]*display\s*:\s*none'
    'casino|viagra|cialis|pharma|porn|xxx'
    'gzinflate\s*\(\s*base64_decode'
    '<\?php'
    'coinhive\.min\.js'
)

# ─────────────────────────────────────────────
# CONFIDENCE SCORING FUNCTIONS
# ─────────────────────────────────────────────
calculate_pattern_score() {
    local file="$1"
    local score=0
    local details=""
    local pattern

    for pattern in "${CRITICAL_PATTERNS[@]}"; do
        if grep -qP "$pattern" "$file" 2>/dev/null; then
            score=$((score + 10))
            local line=$(grep -nP "$pattern" "$file" 2>/dev/null | head -1 | cut -d: -f1)
            details="${details}[CRIT:L${line}] "
        fi
    done

    for pattern in "${HIGH_RISK_PATTERNS[@]}"; do
        if grep -qP "$pattern" "$file" 2>/dev/null; then
            score=$((score + 7))
            local line=$(grep -nP "$pattern" "$file" 2>/dev/null | head -1 | cut -d: -f1)
            details="${details}[HIGH:L${line}] "
        fi
    done

    if [ "${score:-0}" -gt 0 ] 2>/dev/null ]; then
        for pattern in "${MEDIUM_RISK_PATTERNS[@]}"; do
            if grep -qP "$pattern" "$file" 2>/dev/null; then
                score=$((score + 4))
            fi
        done
    fi

    echo "${score}|${details}"
}

calculate_context_score() {
    local file="$1"
    local context=0

    # PHP in uploads = CRITICAL
    echo "$file" | grep -q '/wp-content/uploads/' && context=$((context + 15))

    # Multiple encoding layers
    local enc=0
    grep -qP 'base64_decode' "$file" 2>/dev/null && enc=$((enc + 1))
    grep -qP 'gzinflate' "$file" 2>/dev/null && enc=$((enc + 1))
    grep -qP 'str_rot13' "$file" 2>/dev/null && enc=$((enc + 1))
    [ $enc -ge 3 ] && context=$((context + 8))
    [ "${enc:-0}" -eq 2 ] 2>/dev/null ] && context=$((context + 4))

    # High entropy
    grep -qP '[A-Za-z0-9+/=]{300,}' "$file" 2>/dev/null && context=$((context + 5))

    # Suspicious filename
    local fname=$(basename "$file")
    echo "$fname" | grep -qP '^\.|^[0-9a-f]{32}\.php$|^[a-z]{1,2}\.php$' && context=$((context + 5))

    # Low comment ratio
    local lines=$(wc -l < "$file" 2>/dev/null || echo 1)
    if [ "${lines:-0}" -gt 30 ] 2>/dev/null ]; then
        local comments=$(grep -cP '^\s*(//|#|\*)' "$file" 2>/dev/null || echo 0)
        local ratio=$((comments * 100 / lines))
        [ $ratio -lt 3 ] && context=$((context + 3))
    fi

    echo $context
}

check_sanitization() {
    local file="$1"
    local reduction=0

    grep -qP 'sanitize_text_field|sanitize_email|esc_html|esc_attr|esc_sql|wp_kses' "$file" 2>/dev/null \
        && reduction=$((reduction + 3))

    grep -qP 'wp_verify_nonce|check_admin_referer' "$file" 2>/dev/null \
        && reduction=$((reduction + 2))

    grep -qP 'filter_var|filter_input|is_numeric|absint|intval' "$file" 2>/dev/null \
        && reduction=$((reduction + 2))

    echo $reduction
}

# ════════════════════════════════════════════════════════════════
#  CHECK FUNCTIONS
# ════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────
# 1. WORDPRESS CORE CHECKSUMS
# ─────────────────────────────────────────────
check_core() {
    local wp_root="$1" domain="$2" frag="$3"

    if ! command -v wp &>/dev/null; then
        warn "      · WP-CLI not found - skipping core check"
        html_finding "$frag" "warning" "Core Checksums" "WP-CLI not available - manual verification required"
        return 2
    fi

    if wp --allow-root core verify-checksums --path="$wp_root" --quiet 2>/dev/null; then
        return 0
    else
        html_finding "$frag" "critical" "Core Checksums" "WordPress core files modified or corrupted"
        return 1
    fi
}

# ─────────────────────────────────────────────
# 2. PLUGIN CHECKSUMS
# ─────────────────────────────────────────────
check_plugins() {
    local wp_root="$1" domain="$2" frag="$3"
    local found=0

    if ! command -v wp &>/dev/null; then
        warn "      · WP-CLI not found - skipping plugin check"
        return 2
    fi

    local plugin_list=$(wp --allow-root plugin list --path="$wp_root" --format=csv --fields=name,status,version --quiet 2>/dev/null)

    if [ -z "$plugin_list" ]; then
        warn "      · Could not retrieve plugin list"
        return 2
    fi

    echo "$plugin_list" | tail -n +2 | while IFS=',' read -r plugin_name status version; do
        [ "$status" = "must-use" ] && continue
        [ "$status" = "dropin" ] && continue

        local verify_output=$(wp --allow-root plugin verify-checksums "$plugin_name" --path="$wp_root" --quiet 2>&1)
        local exit_code=$?

        if echo "$verify_output" | grep -q "not available on WordPress.org"; then
            continue
        elif [ "${exit_code:-0}" -ne 0 ] 2>/dev/null ]; then
            echo "$verify_output" | while read -r line; do
                [ -n "$line" ] && html_finding "$frag" "critical" "Plugin Checksums" "${plugin_name}: ${line}"
            done
            found=1
        fi
    done

    return $found
}

# ─────────────────────────────────────────────
# 3. THEME AUDIT
# ─────────────────────────────────────────────
check_themes() {
    local wp_root="$1" domain="$2" frag="$3"
    local found=0

    if ! command -v wp &>/dev/null; then
        warn "      · WP-CLI not found - skipping theme check"
        return 2
    fi

    local theme_list=$(wp --allow-root theme list --path="$wp_root" --format=csv --fields=name,status,version --quiet 2>/dev/null)

    if [ -z "$theme_list" ]; then
        warn "      · Could not retrieve theme list"
        return 2
    fi

    # For now, just flag if themes exist (full checksum comparison would go here)
    local theme_count=$(echo "$theme_list" | tail -n +2 | wc -l)

    if [ "${theme_count:-0}" -gt 5 ] 2>/dev/null ]; then
        html_finding "$frag" "warning" "Theme Audit" "Unusual number of themes installed: ${theme_count} (consider cleanup)"
    fi

    return 0
}

# ─────────────────────────────────────────────
# 4. FILE PERMISSIONS
# ─────────────────────────────────────────────
check_permissions() {
    local wp_root="$1" domain="$2" frag="$3"
    local found=0

    # Check wp-config.php
    if [ -f "$wp_root/wp-config.php" ]; then
        local cfg_perm=$(stat -c '%a' "$wp_root/wp-config.php" 2>/dev/null)
        if [[ "$cfg_perm" =~ [2367]$ ]]; then
            warn "      · wp-config.php permissions: $cfg_perm"
            html_finding "$frag" "critical" "File Permissions" "wp-config.php is world-readable/writable (${cfg_perm})"
            found=1
        fi
    fi

    # Check .htaccess
    if [ -f "$wp_root/.htaccess" ]; then
        if grep -qiP 'AddType.*application/x-httpd-php|php_value|auto_prepend_file' "$wp_root/.htaccess" 2>/dev/null; then
            warn "      · .htaccess has PHP execution directives"
            html_finding "$frag" "critical" "File Permissions" ".htaccess contains PHP execution directives"
            found=1
        fi
    fi

    # Check uploads execute bit
    if [ -d "$wp_root/wp-content/uploads" ]; then
        local up_perm=$(stat -c '%a' "$wp_root/wp-content/uploads" 2>/dev/null)
        if [[ "$up_perm" == *[1357]* ]]; then
            warn "      · uploads execute bit set: $up_perm"
            html_finding "$frag" "warning" "File Permissions" "uploads has execute bit (${up_perm})"
            found=1
        fi
    fi

    return $found
}

# ─────────────────────────────────────────────
# 5. SUSPICIOUS FILE PLACEMENT
# ─────────────────────────────────────────────
check_file_placement() {
    local wp_root="$1" domain="$2" frag="$3"
    local found=0

    # PHP in uploads
    local php_in_uploads=$(find "$wp_root/wp-content/uploads" -name '*.php' -o -name '*.php5' -o -name '*.phtml' 2>/dev/null)

    if [ -n "$php_in_uploads" ]; then
        echo "$php_in_uploads" | while read -r f; do
            local rel="${f#$wp_root/}"
            warn "      · PHP in uploads: $rel"
            html_finding "$frag" "critical" "File Placement" "PHP file in uploads directory: $rel"
        done
        found=1
    fi

    # Disguised PHP files
    local disguised=$(find "$wp_root/wp-content" \( -name '*.php.jpg' -o -name '*.php.png' -o -name '*.php.gif' \) 2>/dev/null)

    if [ -n "$disguised" ]; then
        echo "$disguised" | while read -r f; do
            local rel="${f#$wp_root/}"
            warn "      · Disguised PHP: $rel"
            html_finding "$frag" "critical" "File Placement" "Disguised PHP file: $rel"
        done
        found=1
    fi

    return $found
}

# ─────────────────────────────────────────────
# 6. PHP MALWARE SCAN (CONFIDENCE-BASED)
# ─────────────────────────────────────────────
check_php_malware() {
    local wp_root="$1" domain="$2" frag="$3"
    local high_conf=0
    local low_conf=0

    # Use temp file to track seen files (Bash 4.2 compatible)
    local seen_file=$(mktemp)

    find "$wp_root" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.php5' \) \
        ! -path '*/.git/*' ! -path '*/node_modules/*' 2>/dev/null | while read -r phpfile; do

        local rel="${phpfile#$wp_root/}"

        # Check if already seen
        grep -qF "$rel" "$seen_file" 2>/dev/null && continue
        echo "$rel" >> "$seen_file"

        # Calculate scores
        local pattern_result=$(calculate_pattern_score "$phpfile")
        local pattern_score=$(echo "$pattern_result" | cut -d'|' -f1 | tr -d ' \n\r')
        local pattern_details=$(echo "$pattern_result" | cut -d'|' -f2-)

        # Skip if no patterns matched
        [ -z "$pattern_score" ] && pattern_score=0
        [ "$pattern_score" -eq 0 ] 2>/dev/null && continue

        local context_score=$(calculate_context_score "$phpfile")
        local sanitization=$(check_sanitization "$phpfile")

        local total=$((pattern_score + context_score - sanitization))
        [ $total -lt 0 ] && total=0

        # Convert to confidence %
        local confidence=$((total * 100 / 40))
        [ "${confidence:-0}" -gt 100 ] 2>/dev/null ] && confidence=100

        # Report based on threshold
        if [ $confidence -ge "$CONFIDENCE_THRESHOLD" ]; then
            warn "      · $rel"
            echo -e "        ${DIM}↳ Confidence: ${confidence}% | Score: ${total} | ${pattern_details}${RESET}"
            html_finding "$frag" "critical" "PHP Malware" "${rel} — ${confidence}% confidence (score: ${total}) — ${pattern_details}"
            high_conf=$((high_conf + 1))
        elif [ $confidence -ge 50 ]; then
            info "      · $rel (${confidence}% - review later)"
            html_finding "$frag" "warning" "PHP Scan" "${rel} — ${confidence}% confidence"
            low_conf=$((low_conf + 1))
        fi
    done

    rm -f "$seen_file"

    [ "${high_conf:-0}" -gt 0 ] 2>/dev/null ] && return 1 || return 0
}

# ─────────────────────────────────────────────
# 7. DATABASE SCAN
# ─────────────────────────────────────────────
check_database() {
    local wp_root="$1" domain="$2" frag="$3"
    local found=0

    if ! command -v wp &>/dev/null; then
        warn "      · WP-CLI not found - skipping DB check"
        return 2
    fi

    if ! wp --allow-root db check --path="$wp_root" --quiet 2>/dev/null; then
        warn "      · Cannot connect to DB - skipping"
        return 2
    fi

    local pattern
    for pattern in "${DB_PATTERNS[@]}"; do
        local result=$(wp --allow-root db search "$pattern" --path="$wp_root" --regex --stats --quiet 2>/dev/null | grep -c 'matches' 2>/dev/null || echo 0)

        if [ "$result" -gt 0 ] 2>/dev/null; then
            warn "      · DB match: $pattern"
            html_finding "$frag" "critical" "Database Scan" "Suspicious content: ${pattern}"
            found=1
        fi
    done

    return $found
}

# ─────────────────────────────────────────────
# 8. ADMIN USER AUDIT
# ─────────────────────────────────────────────
check_users() {
    local wp_root="$1" domain="$2" frag="$3"
    local found=0

    if ! command -v wp &>/dev/null; then
        warn "      · WP-CLI not found - skipping user check"
        return 2
    fi

    local admin_count=$(wp --allow-root user list --path="$wp_root" --role=administrator --format=count --quiet 2>/dev/null)

    if [ -z "$admin_count" ]; then
        warn "      · Could not retrieve user list"
        return 2
    fi

    if [ "$admin_count" -gt 3 ] 2>/dev/null; then
        warn "      · Unusual admin count: $admin_count"
        html_finding "$frag" "warning" "Admin Users" "Unusual number of administrators: ${admin_count}"
        found=1
    fi

    # Check for suspicious usernames
    local suspicious=$(wp --allow-root user list --path="$wp_root" --fields=user_login,user_email --format=csv --quiet 2>/dev/null | \
        grep -iP 'admin[0-9]+|support_|wordpress_|wp_|test_admin|backdoor' 2>/dev/null)

    if [ -n "$suspicious" ]; then
        echo "$suspicious" | while read -r u; do
            warn "      · Suspicious username: $u"
            html_finding "$frag" "critical" "Admin Users" "Suspicious username: $u"
        done
        found=1
    fi

    return $found
}

# ════════════════════════════════════════════════════════════════
#  MAIN SITE SCANNER
# ════════════════════════════════════════════════════════════════

scan_wordpress_site() {
    local wp_root="$1"
    local domain="$2"

    local site_frag="$REPORT_TMPDIR/${domain}.frag"
    touch "$site_frag"

    local site_failed=0

    echo -e "\n${BOLD}${CYAN}┌─ Scanning: ${domain}${RESET}"
    info "│  WordPress root: $wp_root"

    # 1. Core Checksums
    printf "│  ${CYAN}%-30s${RESET} " "Core checksums"
    if check_core "$wp_root" "$domain" "$site_frag"; then
        success "✔ OK"
    elif [ $? -eq 2 ]; then
        warn "⊘ Skipped"
    else
        error "✘ Failed"
        site_failed=1
        CORE_FAILED="${CORE_FAILED}${domain} "
    fi

    # 2. Plugin Checksums
    printf "│  ${CYAN}%-30s${RESET} " "Plugin checksums"
    if check_plugins "$wp_root" "$domain" "$site_frag"; then
        success "✔ OK"
    elif [ $? -eq 2 ]; then
        warn "⊘ Skipped"
    else
        error "✘ Failed"
        site_failed=1
        PLUGIN_FAILED="${PLUGIN_FAILED}${domain} "
    fi

    # 3. Theme Audit
    printf "│  ${CYAN}%-30s${RESET} " "Theme audit"
    if check_themes "$wp_root" "$domain" "$site_frag"; then
        success "✔ OK"
    elif [ $? -eq 2 ]; then
        warn "⊘ Skipped"
    else
        error "✘ Failed"
        site_failed=1
        THEME_FAILED="${THEME_FAILED}${domain} "
    fi

    # 4. File Permissions
    printf "│  ${CYAN}%-30s${RESET} " "File permissions"
    if check_permissions "$wp_root" "$domain" "$site_frag"; then
        success "✔ OK"
    else
        error "✘ Issues"
        site_failed=1
        PERM_FAILED="${PERM_FAILED}${domain} "
    fi

    # 5. File Placement
    printf "│  ${CYAN}%-30s${RESET} " "File placement"
    if check_file_placement "$wp_root" "$domain" "$site_frag"; then
        success "✔ OK"
    else
        error "✘ Issues"
        site_failed=1
    fi

    # 6. PHP Malware Scan
    printf "│  ${CYAN}%-30s${RESET} " "PHP malware scan"
    if check_php_malware "$wp_root" "$domain" "$site_frag"; then
        success "✔ Clean"
    else
        error "✘ Threats found"
        site_failed=1
        PHP_FAILED="${PHP_FAILED}${domain} "
    fi

    # 7. Database Scan
    printf "│  ${CYAN}%-30s${RESET} " "Database scan"
    if check_database "$wp_root" "$domain" "$site_frag"; then
        success "✔ Clean"
    elif [ $? -eq 2 ]; then
        warn "⊘ Skipped"
    else
        error "✘ Issues"
        site_failed=1
        DB_FAILED="${DB_FAILED}${domain} "
    fi

    # 8. Admin Users
    printf "│  ${CYAN}%-30s${RESET} " "Admin user audit"
    if check_users "$wp_root" "$domain" "$site_frag"; then
        success "✔ OK"
    elif [ $? -eq 2 ]; then
        warn "⊘ Skipped"
    else
        error "✘ Issues"
        site_failed=1
        USER_FAILED="${USER_FAILED}${domain} "
    fi

    # Generate HTML card
    local card="$REPORT_TMPDIR/${domain}_card.html"
    local pill="pill-clean"
    local label="All Clear"
    local issue_count=$(grep -c '<tr>' "$site_frag" 2>/dev/null || echo 0)

    if [ "${site_failed:-0}" -eq 1 ] 2>/dev/null ]; then
        pill="pill-issues"
        label="${issue_count} issue(s) found"
        TOTAL_ISSUES=$((TOTAL_ISSUES + issue_count))
    fi

    if [ -s "$site_frag" ]; then
        cat > "$card" <<CARD
  <div class="site-card">
    <div class="site-card-header">
      <span class="site-name">${domain}</span>
      <span class="site-status-pill ${pill}">${label}</span>
    </div>
    <div class="site-card-body">
      <table class="findings-table">
        <thead><tr><th>Severity</th><th>Check</th><th>Finding</th></tr></thead>
        <tbody>
$(cat "$site_frag")
        </tbody>
      </table>
    </div>
  </div>
CARD
    else
        cat > "$card" <<CARD
  <div class="site-card">
    <div class="site-card-header">
      <span class="site-name">${domain}</span>
      <span class="site-status-pill pill-clean">All Clear</span>
    </div>
    <div class="site-card-body">
      <div class="clean-msg">✓ All security checks passed</div>
    </div>
  </div>
CARD
    fi

    HTML_FRAGMENTS+=("$card")

    # Summary
    if [ "${site_failed:-0}" -eq 0 ] 2>/dev/null ]; then
        echo -e "${BOLD}└─${RESET} ${GREEN}● All checks passed${RESET}"
        return 0
    else
        echo -e "${BOLD}└─${RESET} ${RED}● Issues found${RESET}"
        return 1
    fi
}

# ════════════════════════════════════════════════════════════════
#  HTML REPORT GENERATOR
# ════════════════════════════════════════════════════════════════
generate_report() {
    local scan_date="$1"
    local total="$2"
    local clean="$3"
    local duration="$4"
    local output="$5"

    cat > "$output" <<'HTMLHEAD'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>WordPress Security Report</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
       font-size: 14px; background: #f5f5f5; color: #333; line-height: 1.6; }
.container { max-width: 1200px; margin: 0 auto; padding: 20px; }
.header { background: #fff; border-radius: 8px; padding: 24px; margin-bottom: 20px;
          box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
.header h1 { font-size: 24px; margin-bottom: 8px; color: #1a73e8; }
.header .meta { font-size: 13px; color: #666; }
.summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
           gap: 16px; margin-bottom: 20px; }
.summary-card { background: #fff; border-radius: 8px; padding: 20px;
                box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
.summary-card .value { font-size: 32px; font-weight: 600; margin-bottom: 4px; }
.summary-card .label { font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }
.sc-blue .value { color: #1a73e8; }
.sc-green .value { color: #188038; }
.sc-red .value { color: #c5221f; }
.site-card { background: #fff; border-radius: 8px; margin-bottom: 16px;
             box-shadow: 0 1px 3px rgba(0,0,0,0.1); overflow: hidden; }
.site-card-header { padding: 16px; display: flex; justify-content: space-between;
                    align-items: center; border-bottom: 1px solid #e8eaed; }
.site-name { font-weight: 600; }
.site-status-pill { font-size: 11px; font-weight: 600; padding: 4px 12px; border-radius: 12px; }
.pill-clean { background: #e6f4ea; color: #188038; }
.pill-issues { background: #fce8e6; color: #c5221f; }
.site-card-body { padding: 0; }
.findings-table { width: 100%; border-collapse: collapse; }
.findings-table th { background: #f8f9fa; padding: 10px 16px; text-align: left;
                     font-size: 11px; text-transform: uppercase; color: #666; }
.findings-table td { padding: 12px 16px; border-top: 1px solid #e8eaed; vertical-align: top; font-size: 13px; }
.badge { font-size: 10px; font-weight: 700; padding: 3px 8px; border-radius: 10px; text-transform: uppercase; }
.badge-critical { background: #fce8e6; color: #c5221f; }
.badge-warning { background: #fef7e0; color: #b06000; }
.check-name { font-weight: 500; white-space: nowrap; }
.finding-detail { font-family: 'Courier New', monospace; font-size: 12px; word-break: break-all; }
.clean-msg { padding: 20px; color: #188038; text-align: center; }
</style>
</head><body><div class="container">
HTMLHEAD

    cat >> "$output" <<HTMLBODY
<div class="header">
  <h1>🛡️ WordPress Security Report</h1>
  <div class="meta">
    <strong>Host:</strong> ${HOSTNAME_VAL} &nbsp;|&nbsp;
    <strong>Scan:</strong> ${scan_date} &nbsp;|&nbsp;
    <strong>Duration:</strong> ${duration}s &nbsp;|&nbsp;
    <strong>Threshold:</strong> ${CONFIDENCE_THRESHOLD}%
  </div>
</div>
<div class="summary">
  <div class="summary-card sc-blue"><div class="value">${total}</div><div class="label">Sites Scanned</div></div>
  <div class="summary-card sc-green"><div class="value">${clean}</div><div class="label">Clean Sites</div></div>
  <div class="summary-card sc-red"><div class="value">$((total - clean))</div><div class="label">Sites with Issues</div></div>
  <div class="summary-card sc-red"><div class="value">${TOTAL_ISSUES}</div><div class="label">Total Findings</div></div>
</div>
HTMLBODY

    local frag
    for frag in "${HTML_FRAGMENTS[@]}"; do
        [ -f "$frag" ] && cat "$frag" >> "$output"
    done

    echo '</div></body></html>' >> "$output"
    rm -rf "$REPORT_TMPDIR"
}

# ════════════════════════════════════════════════════════════════
#  MAIN EXECUTION
# ════════════════════════════════════════════════════════════════

SCAN_START=$(date +%s)
SCAN_DATE=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$REPORT_DIR"

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗"
echo -e "║  WordPress Security Scanner - Complete      ║"
echo -e "║  Threshold: ${CONFIDENCE_THRESHOLD}% | $(date '+%Y-%m-%d %H:%M')     ║"
echo -e "╚══════════════════════════════════════════════╝${RESET}"

if [ ! -e "$SCAN_PATH" ]; then
    error "Error: $SCAN_PATH not found"
    exit 1
fi

HTML_FRAGMENTS=()

# Detect scan mode
if is_wordpress_root "$SCAN_PATH"; then
    info "\n📍 Single WordPress site detected\n"
    TOTAL_SITES=1
    domain=$(basename "$(dirname "$SCAN_PATH")" 2>/dev/null || basename "$SCAN_PATH")
    scan_wordpress_site "$SCAN_PATH" "$domain" && CLEAN_SITES=$((CLEAN_SITES + 1))

elif [ -d "$SCAN_PATH/public" ] && is_wordpress_root "$SCAN_PATH/public"; then
    info "\n📍 Single site with /public subdirectory\n"
    TOTAL_SITES=1
    domain=$(basename "$SCAN_PATH")
    scan_wordpress_site "$SCAN_PATH/public" "$domain" && CLEAN_SITES=$((CLEAN_SITES + 1))

elif [ -d "$SCAN_PATH" ]; then
    info "\n📍 Multi-site directory detected\n"

    for site_dir in "$SCAN_PATH"/*; do
        [ ! -d "$site_dir" ] && continue

        local wp_root=""
        local domain=$(basename "$site_dir")

        if is_wordpress_root "$site_dir"; then
            wp_root="$site_dir"
        elif [ -d "$site_dir/public" ] && is_wordpress_root "$site_dir/public"; then
            wp_root="$site_dir/public"
        elif [ -d "$site_dir/public_html" ] && is_wordpress_root "$site_dir/public_html"; then
            wp_root="$site_dir/public_html"
        fi

        if [ -n "$wp_root" ]; then
            TOTAL_SITES=$((TOTAL_SITES + 1))
            scan_wordpress_site "$wp_root" "$domain" && CLEAN_SITES=$((CLEAN_SITES + 1))
        fi
    done

    if [ $TOTAL_SITES -eq 0 ]; then
        error "\n❌ No WordPress installations found"
        exit 1
    fi
fi

SCAN_END=$(date +%s)
DURATION=$((SCAN_END - SCAN_START))

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗"
echo -e "║              SCAN COMPLETE                   ║"
echo -e "╚══════════════════════════════════════════════╝${RESET}"
echo -e " Sites scanned: ${TOTAL_SITES}"
echo -e " Clean sites: ${GREEN}${CLEAN_SITES}${RESET}"
echo -e " Sites with issues: ${RED}$((TOTAL_SITES - CLEAN_SITES))${RESET}"
echo -e " Total findings: ${RED}${TOTAL_ISSUES}${RESET}"
echo -e " Duration: ${DURATION}s\n"

# Generate report
REPORT_FILE="${REPORT_DIR}/security-report-$(date +%Y%m%d-%H%M%S).html"
LATEST_LINK="${REPORT_DIR}/latest.html"

generate_report "$SCAN_DATE" "$TOTAL_SITES" "$CLEAN_SITES" "$DURATION" "$REPORT_FILE"
ln -sf "$REPORT_FILE" "$LATEST_LINK"

success "HTML report: $REPORT_FILE"
info "Latest: $LATEST_LINK\n"

exit $([ $TOTAL_ISSUES -eq 0 ] && echo 0 || echo 1)
You have new mail in /var/spool/mail/root
