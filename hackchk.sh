#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  WordPress Security Scanner by AI Prasul
#  Scans all sites under BASE_DIR for malware, misconfigurations,
#  and integrity violations. Outputs to terminal and HTML report.
# ════════════════════════════════════════════════════════════════

BASE_DIR="/home/nginx/domains"
REPORT_DIR="/usr/local/nginx/html/reports"
HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)

# ─────────────────────────────────────────────
# TERMINAL COLOR & STYLE DEFINITIONS
# ─────────────────────────────────────────────
if [ -t 1 ] && command -v tput &>/dev/null; then
    RED=$(tput setaf 1; tput bold)
    GREEN=$(tput setaf 2; tput bold)
    YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    WHITE=$(tput setaf 7)
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RESET=$(tput sgr0)
else
    RED='\e[1;31m'
    GREEN='\e[1;32m'
    YELLOW='\e[0;33m'
    CYAN='\e[0;36m'
    WHITE='\e[0;37m'
    BOLD='\e[1m'
    DIM='\e[2m'
    RESET='\e[0m'
fi

info()    { echo -e "${CYAN}${*}${RESET}"; }
success() { echo -e "${GREEN}${*}${RESET}"; }
warn()    { echo -e "${YELLOW}${*}${RESET}"; }
error()   { echo -e "${RED}${*}${RESET}"; }

# ─────────────────────────────────────────────
# GLOBAL TRACKING ARRAYS (terminal summary)
# ─────────────────────────────────────────────
FAILED_SITES=()
INFECTED_SITES=()
DB_INFECTED_SITES=()
PLUGIN_FAILED_SITES=()
THEME_FAILED_SITES=()
PERM_FAILED_SITES=()
USER_FAILED_SITES=()

# ─────────────────────────────────────────────
# HTML REPORT INFRASTRUCTURE
# ─────────────────────────────────────────────
REPORT_TMPDIR=$(mktemp -d)
HTML_FRAGMENTS=()
TOTAL_ISSUES_ALL=0

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    echo "$s"
}

# Append one finding row to the site's fragment file
# Usage: html_finding <frag_file> <severity> <check_name> <detail>
html_finding() {
    local frag="$1" severity="$2" check="$3" detail="$4"
    local badge_class
    case "$severity" in
        critical) badge_class="badge-critical" ;;
        warning)  badge_class="badge-warning"  ;;
        *)        badge_class="badge-info"     ;;
    esac
    local detail_esc
    detail_esc=$(html_escape "$detail")
    cat >> "$frag" <<ENDFINDING
            <tr>
              <td><span class="badge ${badge_class}">${severity}</span></td>
              <td class="check-name">$(html_escape "$check")</td>
              <td class="finding-detail">${detail_esc}</td>
            </tr>
ENDFINDING
}

# ─────────────────────────────────────────────
# PHP FILE MALWARE PATTERNS
# ─────────────────────────────────────────────
PHP_PATTERNS=(
    # Obfuscated eval/execution
    'eval\s*\(\s*base64_decode'
    'eval\s*\(\s*gzinflate'
    'eval\s*\(\s*gzuncompress'
    'eval\s*\(\s*str_rot13'
    'eval\s*\(\s*rawurldecode'
    'eval\s*\(\s*stripslashes'
    'eval\s*\(\s*hex2bin'
    'eval\s*(/\*)?\s*\('
    'assert\s*\(\s*base64_decode'
    'assert\s*\(\s*\$_'
    '\$[a-zA-Z_]\w*\s*=\s*["\x27]assert["\x27]'
    # Hex/char encoding tricks
    '\\\\x63\\\\x72\\\\x65\\\\x61\\\\x74\\\\x65'
    'chr\s*\(\s*[0-9]+\s*\)\s*\.'
    'str_replace.*base64'
    'hex2bin\s*\(\s*["\x27][0-9a-fA-F]'
    '[A-Za-z0-9+/=]{200,}'
    # Remote code/file fetching
    'file_get_contents\s*\(\s*["\x27]https\?://'
    'file_get_contents\s*\(\s*\$_(GET|POST|REQUEST|COOKIE)'
    'base64_decode.*\$_(SERVER|ENV)'
    'gzinflate\s*\(\s*base64_decode'
    'gzuncompress\s*\(\s*base64_decode'
    'str_rot13\s*\(\s*base64_decode'
    'curl_exec\s*\('
    'curl_setopt.*CURLOPT_URL.*\$_(GET|POST|REQUEST)'
    'fopen\s*\(.*[waxc]\s*\)'
    # Backdoor / webshell indicators
    '\$_GET\s*\[.pw.\]'
    '\$_GET\s*\[.cmd.\]'
    '\$_POST\s*\[.pass.\]'
    '\$_POST\s*\[.cmd.\]'
    'if\s*\(\s*md5\s*\(\s*\$_(GET|POST|REQUEST|COOKIE)'
    'passthru\s*\(\s*\$_(GET|POST|REQUEST)'
    'system\s*\(\s*\$_(GET|POST|REQUEST)'
    'shell_exec\s*\(\s*\$_(GET|POST|REQUEST)'
    'exec\s*\(\s*\$_(GET|POST|REQUEST)'
    'popen\s*\(\s*\$_(GET|POST|REQUEST)'
    'proc_open\s*\(\s*\$_(GET|POST|REQUEST)'
    'preg_replace\s*\(.*\/e[^a-z]'
    'create_function\s*\('
    '\$[a-zA-Z_]\w*\s*\(\s*\$_(GET|POST|REQUEST|COOKIE)'
    'call_user_func(_array)?\s*\(\s*\$_(GET|POST|REQUEST)'
    'ReflectionFunction\s*\('
    # Known webshell signatures
    'anonymousfox'
    'blackpanther1337'
    'Upl0ader'
    'r57shell'
    'c99shell'
    'FilesMan'
    'webshell'
    'WSO\s*[0-9]'
    'b374k'
    'sym_linked'
    'IndoXploit'
    'GanjaShell'
    'JspSpy'
    'ALFA_DATA'
    'alfa-shell'
    'ghost_shell'
    'fx29shell'
    # Spam/mailer patterns
    'fsockopen.*smtp'
    'mail\s*\(.*\$_(GET|POST|REQUEST)'
    'substr_count.*\$_(GET|POST|REQUEST)'
    'spam.*base64'
    '@sendmail'
    'From:.*base64_encode'
    'PHPMailer.*\$_(GET|POST|REQUEST)'
    # Variable variable / deep obfuscation
    '\${\$[a-zA-Z_]'
    'O0O0OO0O0O0'
    'OOO000O\|O0O0OO'
    'implode\s*\(\s*["\x27]["\x27]\s*,.*chr\s*\('
    'str_split\s*\(.*\)\s*\[.*\]'
    # SQL injection helpers
    '\$wpdb->query\s*\(\s*["\x27]\s*SELECT.*\$_(GET|POST|REQUEST)'
    '\$wpdb->get_results\s*\(.*\$_(GET|POST|REQUEST)'
    '\$wpdb->prepare\s*\(.*\$_(GET|POST|REQUEST).*%[sd]'
    '\$wpdb->(query|get_results|get_row|get_var)\s*\(\s*["\x27].*(SELECT|INSERT|UPDATE|DELETE).*\.\s*\$'
    # WordPress-specific injection hooks
    'add_(action|filter)\s*\(.*eval\s*\('
    'wp_remote_(get|post)\s*\(.*\$_(GET|POST|REQUEST)'
    'wp_redirect\s*\(.*\$_(GET|POST|REQUEST)'
)

# ─────────────────────────────────────────────
# DATABASE MALWARE PATTERNS
# ─────────────────────────────────────────────
DB_PATTERNS=(
    '<script[^>]*src=["\x27]https\?://'
    'eval\s*\('
    'base64_decode\s*\('
    'atob\s*\('
    'String\.fromCharCode\s*\('
    'document\.write\s*\(\s*unescape'
    '<iframe[^>]*style=["\x27][^"]*display\s*:\s*none'
    'onclick\s*=.*base64'
    '\.href\s*=.*base64_decode'
    'window\[.location.\]'
    'casino|viagra|cialis|pharma|porn|xxx|adult|dating'
    '<a\s+href=["\x27]https\?://[^"]*\.(ru|cn|tk|ml|ga|cf)["\x27]'
    'gzinflate\s*\(\s*base64_decode'
    'str_rot13\s*\(\s*base64_decode'
    '<\?php'
    'wp_check_hash'
    'auto_update_setting'
    '_transient_doing_cron.*sleep'
    'coinhive\.min\.js'
    'cryptonight'
    'miner\.start'
    'wp_redirect.*exit.*base64'
    'wp-cron.*eval'
)

# ════════════════════════════════════════════════════════════════
#  CHECK FUNCTIONS
#  Signature: check_xxx <site_dir> <domain> <html_frag_file>
#  Returns:   0 = clean, 1 = issues found, 2 = skip/error
# ════════════════════════════════════════════════════════════════

check_suspicious_files() {
    local site_dir="$1" domain="$2" frag="$3"
    local pub="$site_dir/public"
    local found=0

    local disguised php_in_uploads shell_scripts writable_php recent_core

    disguised=$(find "$pub/wp-content" \
        \( -name '*.php.jpg' -o -name '*.php.png' -o -name '*.php.gif' \
           -o -name '*.php.js' -o -name '*.php5' -o -name '*.phtml' \
           -o -name '*.phar' \) \
        ! -path '*/.git/*' 2>/dev/null)

    php_in_uploads=$(find "$pub/wp-content/uploads" \
        \( -name '*.php' -o -name '*.php5' -o -name '*.phtml' \) \
        2>/dev/null)

    shell_scripts=$(find "$pub" -maxdepth 3 \
        \( -name '*.sh' -o -name '*.py' -o -name '*.pl' -o -name '*.cgi' \) \
        ! -path '*/.git/*' 2>/dev/null)

    writable_php=$(find "$pub" -name '*.php' -perm -o+w \
        ! -path '*/.git/*' 2>/dev/null)

    recent_core=$(find "$pub" -maxdepth 2 -name '*.php' \
        -newer "$pub/wp-login.php" \
        ! -path '*/wp-content/*' \
        ! -path '*/.git/*' \
        2>/dev/null | head -10)

    if [ -n "$php_in_uploads" ]; then
        found=1
        while IFS= read -r f; do
            local rel="${f#$pub/}"
            warn "      · PHP in uploads: $rel"
            html_finding "$frag" "critical" "File Placement" "PHP file inside uploads directory (must not exist): $rel"
        done <<< "$php_in_uploads"
    fi

    if [ -n "$disguised" ]; then
        found=1
        while IFS= read -r f; do
            local rel="${f#$pub/}"
            warn "      · Disguised PHP: $rel"
            html_finding "$frag" "critical" "File Placement" "PHP file disguised as another file type: $rel"
        done <<< "$disguised"
    fi

    if [ -n "$shell_scripts" ]; then
        found=1
        while IFS= read -r f; do
            local rel="${f#$pub/}"
            warn "      · Script in webroot: $rel"
            html_finding "$frag" "critical" "File Placement" "Shell / script file found in webroot: $rel"
        done <<< "$shell_scripts"
    fi

    if [ -n "$writable_php" ]; then
        found=1
        while IFS= read -r f; do
            local rel="${f#$pub/}"
            warn "      · World-writable PHP: $rel"
            html_finding "$frag" "warning" "File Placement" "World-writable PHP file: $rel"
        done <<< "$writable_php"
    fi

    if [ -n "$recent_core" ]; then
        while IFS= read -r f; do
            local rel="${f#$pub/}"
            warn "      · Recently modified core: $rel"
            html_finding "$frag" "warning" "File Placement" "Recently modified core PHP file — verify integrity: $rel"
        done <<< "$recent_core"
    fi

    if [ "$found" -eq 0 ]; then
        success "✔ Clean"
    else
        error "✘ Issues found"
    fi
    return $found
}

check_permissions() {
    local site_dir="$1" domain="$2" frag="$3"
    local pub="$site_dir/public"
    local found=0

    if [ -f "$pub/wp-config.php" ]; then
        local cfg_perm
        cfg_perm=$(stat -c '%a' "$pub/wp-config.php" 2>/dev/null)
        if [[ "$cfg_perm" =~ [2367]$ ]]; then
            warn "      · wp-config.php permissions: $cfg_perm"
            html_finding "$frag" "critical" "File Permissions" "wp-config.php is world-readable/writable (${cfg_perm}) — should be 400 or 440"
            found=1
        fi
    fi

    if [ -f "$pub/.htaccess" ]; then
        local ht_perm
        ht_perm=$(stat -c '%a' "$pub/.htaccess" 2>/dev/null)
        if [[ "$ht_perm" =~ [2-7][2-7][2-7]$ ]] || [[ "$ht_perm" == *[67] ]]; then
            warn "      · .htaccess group/world writable: $ht_perm"
            html_finding "$frag" "warning" "File Permissions" ".htaccess is group/world writable (${ht_perm})"
            found=1
        fi
        if grep -qiP 'AddType.*application/x-httpd-php|php_value|php_flag|auto_prepend_file' \
                "$pub/.htaccess" 2>/dev/null; then
            warn "      · .htaccess has PHP execution directives"
            html_finding "$frag" "critical" "File Permissions" ".htaccess contains PHP execution directives — possible injection vector"
            found=1
        fi
    fi

    if [ -d "$pub/wp-content/uploads" ]; then
        local up_perm
        up_perm=$(stat -c '%a' "$pub/wp-content/uploads" 2>/dev/null)
        if [[ "$up_perm" == *[1357]* ]]; then
            warn "      · uploads execute bit set: $up_perm"
            html_finding "$frag" "warning" "File Permissions" "wp-content/uploads has execute bit set (${up_perm}) — remove execute permissions"
            found=1
        fi
    fi

    if [ "$found" -eq 0 ]; then
        success "✔ OK"
    else
        error "✘ Issues found"
    fi
    return $found
}

check_users() {
    local site_dir="$1" domain="$2" frag="$3"
    local found=0

    local admin_count
    admin_count=$(wp --allow-root user list \
        --path="$site_dir/public" \
        --role=administrator \
        --format=count \
        --quiet 2>/dev/null)

    if [ -z "$admin_count" ]; then
        warn "      · Could not retrieve user list"
        html_finding "$frag" "info" "Admin Users" "Could not retrieve user list — manual check required"
        return 2
    fi

    if [ "$admin_count" -gt 3 ] 2>/dev/null; then
        warn "      · Unusual admin count: $admin_count"
        html_finding "$frag" "warning" "Admin Users" "Unusual number of administrator accounts: ${admin_count} (expected ≤ 3)"
        found=1
    fi

    local suspicious_names
    suspicious_names=$(wp --allow-root user list \
        --path="$site_dir/public" \
        --fields=user_login,user_email \
        --format=csv \
        --quiet 2>/dev/null | grep -iP \
        'admin[0-9]+|support_[a-z0-9]+|wordpress_[a-z0-9]+|wp_[a-z0-9]+|test_admin|backdoor|shell|hack' \
        2>/dev/null)

    if [ -n "$suspicious_names" ]; then
        while IFS= read -r u; do
            warn "      · Suspicious username: $u"
            html_finding "$frag" "critical" "Admin Users" "Suspicious administrator username: $u"
        done <<< "$suspicious_names"
        found=1
    fi

    if [ "$found" -eq 0 ]; then
        success "✔ $admin_count admin(s) — OK"
    else
        error "✘ Issues found"
    fi
    return $found
}

check_themes() {
    local site_dir="$1" domain="$2" frag="$3"
    local pub="$site_dir/public"
    local theme_path="$pub/wp-content/themes"
    local found=0 verified_count=0 skipped_count=0

    local TMPDIR_THEMES
    TMPDIR_THEMES=$(mktemp -d 2>/dev/null) || TMPDIR_THEMES="/tmp/wp_theme_$$"
    mkdir -p "$TMPDIR_THEMES"

    local theme_list
    theme_list=$(wp --allow-root theme list \
        --path="$pub" \
        --format=csv \
        --fields=name,status,version \
        --quiet 2>/dev/null)

    if [ -z "$theme_list" ]; then
        warn "      · Could not retrieve theme list"
        html_finding "$frag" "info" "Theme Audit" "Could not retrieve theme list — manual check required"
        rm -rf "$TMPDIR_THEMES"
        return 2
    fi

    while IFS=',' read -r theme_name status version; do
        [ "$theme_name" = "name" ] && continue
        local theme_dir="$theme_path/$theme_name"
        [ ! -d "$theme_dir" ] && continue

        local api_url="https://downloads.wordpress.org/theme/${theme_name}.${version}.zip"
        local zip_file="$TMPDIR_THEMES/${theme_name}-${version}.zip"
        local extract_dir="$TMPDIR_THEMES/${theme_name}-${version}"

        # Try to fetch official theme zip from WP.org
        if curl -fsSL --max-time 10 --retry 1 \
                -o "$zip_file" "$api_url" 2>/dev/null \
                && [ -s "$zip_file" ]; then

            if unzip -q "$zip_file" -d "$extract_dir" 2>/dev/null; then
                local ref_dir="$extract_dir/$theme_name"
                [ ! -d "$ref_dir" ] && ref_dir="$extract_dir"

                # SHA256 compare every reference file
                while IFS= read -r ref_file; do
                    local rel="${ref_file#$ref_dir/}"
                    local inst_file="$theme_dir/$rel"
                    if [ ! -f "$inst_file" ]; then
                        warn "      · $theme_name: missing: $rel"
                        html_finding "$frag" "warning" "Theme Audit" "${theme_name}: Missing file from WP.org release: ${rel}"
                        found=1
                    else
                        local rh ih
                        rh=$(sha256sum "$ref_file"  2>/dev/null | awk '{print $1}')
                        ih=$(sha256sum "$inst_file" 2>/dev/null | awk '{print $1}')
                        if [ "$rh" != "$ih" ]; then
                            warn "      · $theme_name: checksum mismatch: $rel"
                            html_finding "$frag" "critical" "Theme Audit" "${theme_name}: Checksum mismatch — possible tampering: ${rel}"
                            found=1
                        fi
                    fi
                done < <(find "$ref_dir" -type f)

                # Flag extra PHP files not in the official release
                while IFS= read -r inst_file; do
                    local rel="${inst_file#$theme_dir/}"
                    if [ ! -f "$ref_dir/$rel" ]; then
                        warn "      · $theme_name: unexpected PHP: $rel"
                        html_finding "$frag" "critical" "Theme Audit" "${theme_name}: PHP file not in WP.org release (possible injected backdoor): ${rel}"
                        found=1
                    fi
                done < <(find "$theme_dir" \
                    \( -name '*.php' -o -name '*.phtml' -o -name '*.php5' \) \
                    2>/dev/null)

                ((verified_count++))
                rm -rf "$zip_file" "$extract_dir"
                continue
            fi
        fi

        # Premium / custom theme — fall back to PHP malware pattern scan
        ((skipped_count++))
        local theme_infected=false
        local -A theme_seen
        for pattern in "${PHP_PATTERNS[@]}"; do
            local matches
            matches=$(grep -rlP "$pattern" \
                --include='*.php' --include='*.phtml' --include='*.php5' \
                --exclude-dir='.git' \
                "$theme_dir" 2>/dev/null)
            if [ -n "$matches" ]; then
                while IFS= read -r mfile; do
                    local rel="${mfile#$theme_dir/}"
                    if [ -z "${theme_seen[$rel]}" ]; then
                        local line_ctx
                        line_ctx=$(grep -nP "$pattern" "$mfile" 2>/dev/null | head -2 | tr '\n' ' | ')
                        warn "      · $theme_name (premium): $rel"
                        html_finding "$frag" "critical" "Theme Audit" "${theme_name} (premium — PHP scan): Suspicious content in ${rel} — ${line_ctx}"
                        theme_seen[$rel]=1
                        found=1
                    fi
                    theme_infected=true
                done <<< "$matches"
            fi
        done

        if ! $theme_infected; then
            html_finding "$frag" "info" "Theme Audit" "${theme_name} (v${version}): Not on WP.org — PHP scan clean, manual review recommended"
        fi
        rm -f "$zip_file"

    done <<< "$theme_list"

    rm -rf "$TMPDIR_THEMES"

    if [ "$found" -eq 0 ]; then
        if [ "$skipped_count" -gt 0 ]; then
            success "✔ OK ($verified_count checksummed, $skipped_count PHP-scan only)"
        else
            success "✔ All $verified_count theme(s) checksummed — clean"
        fi
    else
        error "✘ Issues found"
    fi
    return $found
}

check_plugins() {
    local site_dir="$1" domain="$2" frag="$3"
    local plugin_path="$site_dir/public/wp-content/plugins"
    local found=0 verified_count=0 skipped_count=0

    if [ ! -d "$plugin_path" ]; then
        warn "      · Plugins directory not found"
        html_finding "$frag" "info" "Plugin Checksums" "Plugins directory not found — manual check required"
        return 2
    fi

    local plugin_list
    plugin_list=$(wp --allow-root plugin list \
        --path="$site_dir/public" \
        --format=csv \
        --fields=name,status,version \
        --quiet 2>/dev/null)

    if [ -z "$plugin_list" ]; then
        warn "      · Could not retrieve plugin list"
        html_finding "$frag" "info" "Plugin Checksums" "Could not retrieve plugin list via WP-CLI"
        return 2
    fi

    # Detect unregistered plugin directories (rogue installs)
    local rogue_dirs
    rogue_dirs=$(find "$plugin_path" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | \
        while read -r d; do
            pname=$(basename "$d")
            if ! echo "$plugin_list" | grep -q "^$pname,"; then
                echo "$pname"
            fi
        done)

    if [ -n "$rogue_dirs" ]; then
        while IFS= read -r rp; do
            warn "      · Unregistered plugin dir: $rp"
            html_finding "$frag" "critical" "Plugin Checksums" "Plugin directory not registered in WordPress (possible rogue install): ${rp}"
        done <<< "$rogue_dirs"
        found=1
    fi

    while IFS=',' read -r plugin_name status version; do
        [ "$plugin_name" = "name" ] && continue
        [ "$status" = "must-use" ] && continue
        [ "$status" = "dropin" ] && continue

        local verify_output
        verify_output=$(wp --allow-root plugin verify-checksums "$plugin_name" \
            --path="$site_dir/public" \
            --quiet 2>&1)
        local exit_code=$?

        if echo "$verify_output" | grep -q "not available on WordPress.org"; then
            html_finding "$frag" "info" "Plugin Checksums" "${plugin_name} (v${version}): Not on WP.org — manual review recommended"
            ((skipped_count++))
        elif [ $exit_code -ne 0 ]; then
            while IFS= read -r line; do
                if [ -n "$line" ]; then
                    warn "      · $plugin_name: $line"
                    html_finding "$frag" "critical" "Plugin Checksums" "${plugin_name}: ${line}"
                    found=1
                fi
            done <<< "$verify_output"
            ((verified_count++))
        else
            ((verified_count++))
        fi
    done <<< "$plugin_list"

    if [ "$found" -eq 0 ]; then
        if [ "$skipped_count" -gt 0 ]; then
            success "✔ OK ($verified_count verified, $skipped_count not on WP.org)"
        else
            success "✔ All $verified_count plugins verified"
        fi
    else
        error "✘ Issues found"
    fi
    return $found
}

check_php_files() {
    local site_dir="$1" domain="$2" frag="$3"
    local -A seen_files
    local found=0

    for pattern in "${PHP_PATTERNS[@]}"; do
        local matches
        matches=$(grep -rlP "$pattern" \
            --include='*.php' \
            --include='*.phtml' \
            --include='*.php5' \
            --exclude-dir='.infected_*' \
            --exclude-dir='.git' \
            --exclude-dir='node_modules' \
            "$site_dir/public" 2>/dev/null)

        if [ -n "$matches" ]; then
            while IFS= read -r match; do
                local relative="${match#$site_dir/public/}"
                if [ -z "${seen_files[$relative]}" ]; then
                    local line_info
                    line_info=$(grep -nP "$pattern" "$match" 2>/dev/null | head -3 | tr '\n' ' | ')
                    warn "      · $relative"
                    [ -n "$line_info" ] && echo -e "        ${DIM}↳ $line_info${RESET}"
                    html_finding "$frag" "critical" "PHP Malware Scan" "${relative} — ${line_info}"
                    seen_files[$relative]=1
                    found=1
                fi
            done <<< "$matches"
        fi
    done

    if [ "$found" -eq 0 ]; then
        success "✔ Clean"
    else
        error "✘ Suspicious files found"
    fi
    return $found
}

check_db() {
    local site_dir="$1" domain="$2" frag="$3"
    local found=0

    if ! wp --allow-root db check --path="$site_dir/public" --quiet 2>/dev/null; then
        warn "      · Cannot connect to DB — skipping"
        html_finding "$frag" "info" "Database Scan" "Cannot connect to database — scan skipped"
        return 2
    fi

    for pattern in "${DB_PATTERNS[@]}"; do
        local result
        result=$(wp --allow-root db search "$pattern" \
            --path="$site_dir/public" \
            --regex \
            --stats \
            --quiet 2>/dev/null | grep -c 'matches' 2>/dev/null || echo 0)

        if [ "$result" -gt 0 ] 2>/dev/null; then
            warn "      · DB match: $pattern"
            html_finding "$frag" "critical" "Database Scan" "Suspicious content found in database — pattern: ${pattern}"
            found=1
        fi
    done

    # Check wp_options for malicious keys/values
    local suspicious_options
    suspicious_options=$(wp --allow-root option list \
        --path="$site_dir/public" \
        --format=csv \
        --quiet 2>/dev/null | grep -iP \
        'auto_prepend|eval|base64|gzinflate|shell_exec|wp_check_hash' \
        2>/dev/null)

    if [ -n "$suspicious_options" ]; then
        while IFS= read -r opt; do
            warn "      · Suspicious wp_option: $opt"
            html_finding "$frag" "critical" "Database Scan" "Suspicious wp_options entry: ${opt}"
        done <<< "$suspicious_options"
        found=1
    fi

    # Non-standard cron hooks (informational)
    local cron_hooks
    cron_hooks=$(wp --allow-root cron event list \
        --path="$site_dir/public" \
        --format=csv \
        --fields=hook,next_run \
        --quiet 2>/dev/null | grep -vP \
        '^(hook|wp_scheduled_delete|wp_update_themes|wp_update_plugins|wp_version_check|wp_scheduled_auto_draft_delete|delete_expired_transients|recovery_mode_clean_expired_keys|wp_privacy_delete_old_export_files)' \
        2>/dev/null)

    if [ -n "$cron_hooks" ]; then
        while IFS= read -r hook; do
            warn "      · Non-standard cron hook: $hook"
            html_finding "$frag" "warning" "Database Scan" "Non-standard WP cron hook — verify legitimacy: ${hook}"
        done <<< "$cron_hooks"
    fi

    if [ "$found" -eq 0 ]; then
        success "✔ Clean"
    else
        error "✘ Suspicious content found"
    fi
    return $found
}

# ════════════════════════════════════════════════════════════════
#  HTML REPORT GENERATOR
# ════════════════════════════════════════════════════════════════
generate_html_report() {
    local scan_date="$1" total_sites="$2" total_clean="$3" duration="$4" report_file="$5"
    local total_affected=$(( total_sites - total_clean ))

    local core_fail=${#FAILED_SITES[@]}
    local plugin_fail=${#PLUGIN_FAILED_SITES[@]}
    local theme_fail=${#THEME_FAILED_SITES[@]}
    local perm_fail=${#PERM_FAILED_SITES[@]}
    local file_fail=${#INFECTED_SITES[@]}
    local db_fail=${#DB_INFECTED_SITES[@]}
    local user_fail=${#USER_FAILED_SITES[@]}

    # ── HTML HEAD + CSS ──────────────────────────────────────────
    cat > "$report_file" <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
HTMLHEAD

    echo "  <title>WordPress Security Report — ${scan_date}</title>" >> "$report_file"

    cat >> "$report_file" <<'HTMLCSS'
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Google+Sans:wght@400;500;600&family=Roboto+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --blue-700:   #1a73e8; --blue-50:    #e8f0fe;
      --red-700:    #c5221f; --red-50:     #fce8e6;
      --yellow-700: #b06000; --yellow-50:  #fef7e0;
      --green-700:  #188038; --green-50:   #e6f4ea;
      --grey-900:   #202124; --grey-700:   #3c4043;
      --grey-500:   #5f6368; --grey-200:   #e8eaed;
      --grey-100:   #f1f3f4; --grey-50:    #f8f9fa;
      --white:      #ffffff;
      --radius:     8px;
      --shadow-sm:  0 1px 3px rgba(0,0,0,.10), 0 1px 2px rgba(0,0,0,.06);
    }
    body {
      font-family: 'Google Sans', 'Roboto', Arial, sans-serif;
      font-size: 14px; color: var(--grey-900);
      background: var(--grey-50); line-height: 1.6;
    }

    /* ─ Header ─ */
    .page-header {
      background: var(--white); border-bottom: 1px solid var(--grey-200);
      padding: 0 40px; position: sticky; top: 0; z-index: 100;
    }
    .header-inner {
      max-width: 1200px; margin: 0 auto;
      display: flex; align-items: center; justify-content: space-between;
      height: 64px;
    }
    .header-brand { display: flex; align-items: center; gap: 12px; }
    .header-title { font-size: 18px; font-weight: 600; letter-spacing: -.01em; }
    .header-sub   { font-size: 12px; color: var(--grey-500); margin-top: 1px; }
    .header-meta  { text-align: right; font-size: 12px; color: var(--grey-500); line-height: 1.9; }
    .header-meta strong { color: var(--grey-700); }

    /* ─ Body ─ */
    .page-body { max-width: 1200px; margin: 0 auto; padding: 32px 40px 64px; }

    /* ─ Summary cards ─ */
    .summary-grid {
      display: grid; grid-template-columns: repeat(4, 1fr);
      gap: 16px; margin-bottom: 28px;
    }
    .summary-card {
      background: var(--white); border: 1px solid var(--grey-200);
      border-radius: var(--radius); padding: 22px 24px;
      box-shadow: var(--shadow-sm);
    }
    .sc-value { font-size: 36px; font-weight: 600; line-height: 1; margin-bottom: 6px; }
    .sc-label { font-size: 11px; color: var(--grey-500); font-weight: 600;
                text-transform: uppercase; letter-spacing: .05em; }
    .sc-blue   .sc-value { color: var(--blue-700); }
    .sc-red    .sc-value { color: var(--red-700);  }
    .sc-green  .sc-value { color: var(--green-700);}
    .sc-yellow .sc-value { color: var(--yellow-700);}

    /* ─ Alert ─ */
    .alert-banner {
      border-radius: var(--radius); padding: 14px 20px;
      margin-bottom: 28px; display: flex; align-items: center;
      gap: 12px; font-size: 14px; font-weight: 500;
    }
    .alert-banner.critical { background: var(--red-50);   color: var(--red-700);   border: 1px solid #f5c6c5; }
    .alert-banner.clean    { background: var(--green-50); color: var(--green-700); border: 1px solid #a8d5b5; }

    /* ─ Section title ─ */
    .section-title {
      font-size: 15px; font-weight: 600; color: var(--grey-900);
      margin-bottom: 14px; margin-top: 32px;
    }
    .section-title:first-of-type { margin-top: 0; }

    /* ─ Check summary table ─ */
    .summary-table {
      width: 100%; border-collapse: collapse; background: var(--white);
      border: 1px solid var(--grey-200); border-radius: var(--radius);
      overflow: hidden; box-shadow: var(--shadow-sm); margin-bottom: 8px;
    }
    .summary-table th {
      background: var(--grey-50); border-bottom: 1px solid var(--grey-200);
      padding: 10px 18px; text-align: left; font-size: 11px; font-weight: 600;
      text-transform: uppercase; letter-spacing: .06em; color: var(--grey-500);
    }
    .summary-table td {
      padding: 11px 18px; border-bottom: 1px solid var(--grey-100);
      font-size: 13px; vertical-align: middle;
    }
    .summary-table tr:last-child td { border-bottom: none; }
    .summary-table tr:hover td { background: var(--grey-50); }
    .domain-chip {
      display: inline-block; background: var(--grey-100); color: var(--grey-700);
      font-size: 11px; font-family: 'Roboto Mono', monospace;
      padding: 2px 8px; border-radius: 4px; margin: 2px 3px 2px 0;
    }

    /* ─ Site cards ─ */
    .site-card {
      background: var(--white); border: 1px solid var(--grey-200);
      border-radius: var(--radius); box-shadow: var(--shadow-sm);
      margin-bottom: 16px; overflow: hidden;
    }
    .site-card-header {
      display: flex; align-items: center; justify-content: space-between;
      padding: 15px 24px; border-bottom: 1px solid var(--grey-200);
      cursor: pointer; user-select: none; transition: background .15s;
    }
    .site-card-header:hover { background: var(--grey-50); }
    .site-name {
      font-size: 14px; font-weight: 600; display: flex;
      align-items: center; gap: 10px; color: var(--grey-900);
    }
    .site-status-pill {
      display: inline-flex; align-items: center; gap: 5px;
      font-size: 11px; font-weight: 600; padding: 3px 11px;
      border-radius: 12px; letter-spacing: .03em;
    }
    .pill-clean  { background: var(--green-50); color: var(--green-700); }
    .pill-issues { background: var(--red-50);   color: var(--red-700);   }
    .toggle-icon { font-size: 16px; color: var(--grey-500); transition: transform .2s; }

    /* ─ Findings table ─ */
    .findings-table { width: 100%; border-collapse: collapse; }
    .findings-table th {
      background: var(--grey-50); padding: 9px 18px; text-align: left;
      font-size: 11px; font-weight: 600; text-transform: uppercase;
      letter-spacing: .06em; color: var(--grey-500);
      border-bottom: 1px solid var(--grey-200);
    }
    .findings-table td {
      padding: 10px 18px; border-bottom: 1px solid var(--grey-100);
      vertical-align: top;
    }
    .findings-table tr:last-child td { border-bottom: none; }
    .findings-table tr:hover td { background: var(--grey-50); }
    .col-severity { width: 90px; }
    .col-check    { width: 170px; font-weight: 500; color: var(--grey-700); white-space: nowrap; }
    .col-detail   {
      font-family: 'Roboto Mono', 'Consolas', monospace;
      font-size: 12px; color: var(--grey-700); word-break: break-all;
    }

    /* ─ Badges ─ */
    .badge {
      display: inline-block; font-size: 10px; font-weight: 700;
      padding: 2px 8px; border-radius: 10px;
      letter-spacing: .05em; text-transform: uppercase; white-space: nowrap;
    }
    .badge-critical { background: var(--red-50);    color: var(--red-700);    }
    .badge-warning  { background: var(--yellow-50); color: var(--yellow-700); }
    .badge-info     { background: var(--blue-50);   color: var(--blue-700);   }
    .badge-ok       { background: var(--green-50);  color: var(--green-700);  }
    .dot-ok   { color: var(--green-700); }
    .dot-fail { color: var(--red-700);   }

    /* ─ Clean site message ─ */
    .clean-msg {
      padding: 18px 24px; color: var(--green-700);
      font-size: 13px; display: flex; align-items: center; gap: 8px;
    }

    /* ─ Footer ─ */
    .page-footer {
      text-align: center; font-size: 12px; color: var(--grey-500);
      padding: 24px 0 0; border-top: 1px solid var(--grey-200);
      margin-top: 40px;
    }

    @media (max-width: 900px) {
      .summary-grid { grid-template-columns: repeat(2, 1fr); }
      .page-body, .page-header { padding-left: 20px; padding-right: 20px; }
      .header-meta { display: none; }
    }
    @media print {
      .site-card-body { display: block !important; }
      .page-header { position: static; }
    }
  </style>
</head>
<body>
HTMLCSS

    # ── Page header ─────────────────────────────────────────────
    cat >> "$report_file" <<HTMLBODY

<header class="page-header">
  <div class="header-inner">
    <div class="header-brand">
      <svg width="30" height="30" viewBox="0 0 24 24" fill="none">
        <rect width="24" height="24" rx="6" fill="#1a73e8"/>
        <path d="M12 4a8 8 0 100 16A8 8 0 0012 4zm0 2a6 6 0 110 12A6 6 0 0112 6zm0 2a4 4 0 100 8 4 4 0 000-8zm0 2a2 2 0 110 4 2 2 0 010-4z" fill="white"/>
      </svg>
      <div>
        <div class="header-title">WordPress Security Report</div>
        <div class="header-sub">Automated malware &amp; integrity scan</div>
      </div>
    </div>
    <div class="header-meta">
      <strong>Host:</strong> ${HOSTNAME_VAL}<br>
      <strong>Scan completed:</strong> ${scan_date}<br>
      <strong>Duration:</strong> ${duration}s &nbsp;·&nbsp; <strong>Sites scanned:</strong> ${total_sites}
    </div>
  </div>
</header>

<div class="page-body">
HTMLBODY

    # ── Alert banner ─────────────────────────────────────────────
    if [ "$total_affected" -gt 0 ]; then
        cat >> "$report_file" <<ALERTFAIL
  <div class="alert-banner critical">
    <svg width="20" height="20" viewBox="0 0 24 24"><path d="M12 2L1 21h22L12 2zm0 3.5L20.5 19h-17L12 5.5zM11 10v4h2v-4h-2zm0 6v2h2v-2h-2z" fill="#c5221f"/></svg>
    <span><strong>${total_affected}</strong> of <strong>${total_sites}</strong> site(s) have security issues requiring immediate attention.</span>
  </div>
ALERTFAIL
    else
        cat >> "$report_file" <<ALERTOK
  <div class="alert-banner clean">
    <svg width="20" height="20" viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41L9 16.17z" fill="#188038"/></svg>
    <span>All <strong>${total_sites}</strong> site(s) passed all security checks — no issues detected.</span>
  </div>
ALERTOK
    fi

    # ── Summary cards ────────────────────────────────────────────
    cat >> "$report_file" <<CARDS
  <div class="summary-grid">
    <div class="summary-card sc-blue">
      <div class="sc-value">${total_sites}</div>
      <div class="sc-label">Sites Scanned</div>
    </div>
    <div class="summary-card sc-green">
      <div class="sc-value">${total_clean}</div>
      <div class="sc-label">Fully Clean</div>
    </div>
    <div class="summary-card sc-red">
      <div class="sc-value">${total_affected}</div>
      <div class="sc-label">Sites with Issues</div>
    </div>
    <div class="summary-card sc-yellow">
      <div class="sc-value">${TOTAL_ISSUES_ALL}</div>
      <div class="sc-label">Total Findings</div>
    </div>
  </div>
CARDS

    # ── Check overview table ──────────────────────────────────────
    echo '  <div class="section-title">Scan Overview</div>' >> "$report_file"
    cat >> "$report_file" <<'CHECKTBL'
  <table class="summary-table">
    <thead>
      <tr>
        <th style="width:220px">Check</th>
        <th style="width:140px">Status</th>
        <th style="width:80px">Affected</th>
        <th>Domains</th>
      </tr>
    </thead>
    <tbody>
CHECKTBL

    _summary_row() {
        local label="$1" count="$2"; shift 2; local arr=("$@")
        local status_html="" domains_html=""
        if [ "$count" -eq 0 ]; then
            status_html='<span class="dot-ok">●</span>&ensp;<span class="badge badge-ok">All Clear</span>'
        else
            status_html='<span class="dot-fail">●</span>&ensp;<span class="badge badge-critical">Issues Found</span>'
        fi
        if [ ${#arr[@]} -gt 0 ]; then
            for s in "${arr[@]}"; do
                domains_html+="<span class=\"domain-chip\">${s}</span>"
            done
        else
            domains_html='<span style="color:var(--grey-400)">—</span>'
        fi
        echo "      <tr><td>${label}</td><td>${status_html}</td><td>${count}</td><td>${domains_html}</td></tr>" >> "$report_file"
    }

    _summary_row "WP Core File Integrity"     "$core_fail"   "${FAILED_SITES[@]}"
    _summary_row "Plugin Checksums"           "$plugin_fail" "${PLUGIN_FAILED_SITES[@]}"
    _summary_row "Theme Audit"                "$theme_fail"  "${THEME_FAILED_SITES[@]}"
    _summary_row "File Permissions"           "$perm_fail"   "${PERM_FAILED_SITES[@]}"
    _summary_row "File Placement &amp; PHP Malware" "$file_fail" "${INFECTED_SITES[@]}"
    _summary_row "Database Content"           "$db_fail"     "${DB_INFECTED_SITES[@]}"
    _summary_row "Admin User Accounts"        "$user_fail"   "${USER_FAILED_SITES[@]}"

    cat >> "$report_file" <<'ENDTBL'
    </tbody>
  </table>
ENDTBL

    # ── Per-site detail cards ─────────────────────────────────────
    echo '  <div class="section-title">Per-Site Findings</div>' >> "$report_file"
    for frag_file in "${HTML_FRAGMENTS[@]}"; do
        [ -f "$frag_file" ] && cat "$frag_file" >> "$report_file"
    done

    # ── Footer ───────────────────────────────────────────────────
    cat >> "$report_file" <<HTMLFOOT
  <div class="page-footer">
    Envisioned by Prasul - Generated by <strong>wp_security_scan.sh</strong> &nbsp;·&nbsp; ${scan_date} &nbsp;·&nbsp; ${HOSTNAME_VAL}
  </div>

</div><!-- /page-body -->

<script>
  document.querySelectorAll('.site-card-header').forEach(function(hdr) {
    var body = hdr.nextElementSibling;
    var icon = hdr.querySelector('.toggle-icon');
    // Start collapsed if clean; expanded if issues
    if (hdr.querySelector('.pill-issues')) {
      body.style.display = 'block';
      icon.style.transform = 'rotate(180deg)';
    } else {
      body.style.display = 'none';
    }
    hdr.addEventListener('click', function() {
      var open = body.style.display !== 'none';
      body.style.display = open ? 'none' : 'block';
      icon.style.transform = open ? '' : 'rotate(180deg)';
    });
  });
</script>
</body>
</html>
HTMLFOOT

    rm -rf "$REPORT_TMPDIR"
}

# ════════════════════════════════════════════════════════════════
#  MAIN LOOP
# ════════════════════════════════════════════════════════════════
SCAN_START=$(date +%s)
SCAN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL_SITES=0
TOTAL_CLEAN=0

mkdir -p "$REPORT_DIR"

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗"
echo -e "║      WordPress Security Scanner v2.1         ║"
echo -e "║      ${SCAN_DATE}                ║"
echo -e "╚══════════════════════════════════════════════╝${RESET}"

for site_dir in "$BASE_DIR"/*; do
    [ ! -d "$site_dir/public" ] && continue

    DOMAIN=$(basename "$site_dir")
    ((TOTAL_SITES++))
    SITE_FAILED=false
    SITE_ISSUE_COUNT=0

    SITE_FRAG="$REPORT_TMPDIR/${DOMAIN}.frag"
    touch "$SITE_FRAG"

    echo -e "\n${BOLD}${WHITE}┌─ Scanning: ${CYAN}$DOMAIN${RESET}"

    # ── 1. WP Core Checksum ──────────────────────────────────────
    printf "│  ${CYAN}%-26s${RESET} " "Core checksums"
    if wp --allow-root core verify-checksums \
            --path="$site_dir/public" --quiet 2>/dev/null; then
        success "✔ OK"
    else
        error "✘ Mismatch detected"
        html_finding "$SITE_FRAG" "critical" "Core Checksums" "WP core checksum verification failed — core files may have been tampered with"
        FAILED_SITES+=("$DOMAIN"); SITE_FAILED=true; ((SITE_ISSUE_COUNT++))
    fi

    # ── 2. Plugin Checksums ──────────────────────────────────────
    printf "│  ${CYAN}%-26s${RESET} " "Plugin checksums"
    check_plugins "$site_dir" "$DOMAIN" "$SITE_FRAG"
    rc=$?; [ $rc -eq 1 ] && { PLUGIN_FAILED_SITES+=("$DOMAIN"); SITE_FAILED=true; ((SITE_ISSUE_COUNT++)); }

    # ── 3. Theme Audit ───────────────────────────────────────────
    printf "│  ${CYAN}%-26s${RESET} " "Theme audit"
    check_themes "$site_dir" "$DOMAIN" "$SITE_FRAG"
    rc=$?; [ $rc -eq 1 ] && { THEME_FAILED_SITES+=("$DOMAIN"); SITE_FAILED=true; ((SITE_ISSUE_COUNT++)); }

    # ── 4. File Permissions ──────────────────────────────────────
    printf "│  ${CYAN}%-26s${RESET} " "File permissions"
    check_permissions "$site_dir" "$DOMAIN" "$SITE_FRAG"
    rc=$?; [ $rc -eq 1 ] && { PERM_FAILED_SITES+=("$DOMAIN"); SITE_FAILED=true; ((SITE_ISSUE_COUNT++)); }

    # ── 5. File Placement ────────────────────────────────────────
    printf "│  ${CYAN}%-26s${RESET} " "File placement"
    check_suspicious_files "$site_dir" "$DOMAIN" "$SITE_FRAG"
    rc=$?; [ $rc -eq 1 ] && { INFECTED_SITES+=("$DOMAIN"); SITE_FAILED=true; ((SITE_ISSUE_COUNT++)); }

    # ── 6. PHP Malware Scan ──────────────────────────────────────
    printf "│  ${CYAN}%-26s${RESET} " "PHP malware scan"
    check_php_files "$site_dir" "$DOMAIN" "$SITE_FRAG"
    rc=$?; [ $rc -eq 1 ] && { INFECTED_SITES+=("$DOMAIN"); SITE_FAILED=true; ((SITE_ISSUE_COUNT++)); }

    # ── 7. Database Scan ─────────────────────────────────────────
    printf "│  ${CYAN}%-26s${RESET} " "Database scan"
    check_db "$site_dir" "$DOMAIN" "$SITE_FRAG"
    rc=$?; [ $rc -eq 1 ] && { DB_INFECTED_SITES+=("$DOMAIN"); SITE_FAILED=true; ((SITE_ISSUE_COUNT++)); }

    # ── 8. Admin User Audit ──────────────────────────────────────
    printf "│  ${CYAN}%-26s${RESET} " "Admin user audit"
    check_users "$site_dir" "$DOMAIN" "$SITE_FRAG"
    rc=$?; [ $rc -eq 1 ] && { USER_FAILED_SITES+=("$DOMAIN"); SITE_FAILED=true; ((SITE_ISSUE_COUNT++)); }

    # ── Build per-site HTML card ─────────────────────────────────
    FRAG_CARD="$REPORT_TMPDIR/${DOMAIN}_card.html"
    local_pill="pill-clean"; local_label="All Clear"
    $SITE_FAILED && { local_pill="pill-issues"; local_label="${SITE_ISSUE_COUNT} check(s) failed"; }
    $SITE_FAILED && TOTAL_ISSUES_ALL=$((TOTAL_ISSUES_ALL + SITE_ISSUE_COUNT))

    local_findings_html=""
    [ -s "$SITE_FRAG" ] && local_findings_html=$(cat "$SITE_FRAG")

    if [ -n "$local_findings_html" ]; then
        cat > "$FRAG_CARD" <<SITECARD
  <div class="site-card">
    <div class="site-card-header">
      <span class="site-name">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none"><rect x="2" y="3" width="20" height="14" rx="2" stroke="#5f6368" stroke-width="1.8"/><path d="M8 21h8M12 17v4" stroke="#5f6368" stroke-width="1.8" stroke-linecap="round"/></svg>
        ${DOMAIN}
      </span>
      <div style="display:flex;align-items:center;gap:12px;">
        <span class="site-status-pill ${local_pill}">${local_label}</span>
        <span class="toggle-icon">▾</span>
      </div>
    </div>
    <div class="site-card-body">
      <table class="findings-table">
        <thead>
          <tr>
            <th class="col-severity">Severity</th>
            <th class="col-check">Check</th>
            <th>Finding</th>
          </tr>
        </thead>
        <tbody>
${local_findings_html}
        </tbody>
      </table>
    </div>
  </div>
SITECARD
    else
        cat > "$FRAG_CARD" <<CLEANCARD
  <div class="site-card">
    <div class="site-card-header">
      <span class="site-name">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none"><rect x="2" y="3" width="20" height="14" rx="2" stroke="#5f6368" stroke-width="1.8"/><path d="M8 21h8M12 17v4" stroke="#5f6368" stroke-width="1.8" stroke-linecap="round"/></svg>
        ${DOMAIN}
      </span>
      <div style="display:flex;align-items:center;gap:12px;">
        <span class="site-status-pill pill-clean">All Clear</span>
        <span class="toggle-icon">▾</span>
      </div>
    </div>
    <div class="site-card-body">
      <div class="clean-msg">
        <svg width="16" height="16" viewBox="0 0 24 24"><path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41L9 16.17z" fill="#188038"/></svg>
        All security checks passed — no issues detected.
      </div>
    </div>
  </div>
CLEANCARD
    fi

    HTML_FRAGMENTS+=("$FRAG_CARD")

    # ── Terminal result line ─────────────────────────────────────
    if $SITE_FAILED; then
        echo -e "${BOLD}${WHITE}└─${RESET} ${RED}● ISSUES FOUND — $DOMAIN requires attention${RESET}"
    else
        ((TOTAL_CLEAN++))
        echo -e "${BOLD}${WHITE}└─${RESET} ${GREEN}● All checks passed — $DOMAIN${RESET}"
    fi
done

# ════════════════════════════════════════════════════════════════
#  TERMINAL FINAL SUMMARY
# ════════════════════════════════════════════════════════════════
SCAN_END=$(date +%s)
SCAN_DURATION=$((SCAN_END - SCAN_START))
ALL_CLEAR=true

echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗"
echo -e "║                 FINAL SUMMARY                ║"
echo -e "╠══════════════════════════════════════════════╣${RESET}"
echo -e " ${DIM}Sites scanned: $TOTAL_SITES  |  Clean: $TOTAL_CLEAN  |  Duration: ${SCAN_DURATION}s${RESET}"
echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════╣${RESET}"

_print_section() {
    local title="$1" color="$2"; shift 2; local sites=("$@")
    if [ ${#sites[@]} -gt 0 ]; then
        ALL_CLEAR=false
        echo -e " ${color}${BOLD}${title}${RESET}"
        for site in "${sites[@]}"; do echo -e "   ${YELLOW}·${RESET} $site"; done
        echo ""
    fi
}

_print_section "Core checksum failures:"         "$RED"    "${FAILED_SITES[@]}"
_print_section "Plugin checksum failures:"       "$RED"    "${PLUGIN_FAILED_SITES[@]}"
_print_section "Theme audit failures:"           "$RED"    "${THEME_FAILED_SITES[@]}"
_print_section "File permission issues:"         "$YELLOW" "${PERM_FAILED_SITES[@]}"
_print_section "PHP malware / suspicious files:" "$RED"    "${INFECTED_SITES[@]}"
_print_section "Suspicious database content:"    "$RED"    "${DB_INFECTED_SITES[@]}"
_print_section "Suspicious admin accounts:"      "$YELLOW" "${USER_FAILED_SITES[@]}"

$ALL_CLEAR && echo -e " ${GREEN}${BOLD}✔  All $TOTAL_SITES domain(s) verified — no issues found!${RESET}"

echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}\n"

# ════════════════════════════════════════════════════════════════
#  GENERATE HTML REPORT
# ════════════════════════════════════════════════════════════════
REPORT_FILENAME="security-report-$(date '+%Y%m%d-%H%M%S').html"
REPORT_PATH="$REPORT_DIR/$REPORT_FILENAME"
REPORT_LATEST="$REPORT_DIR/latest.html"

generate_html_report "$SCAN_DATE" "$TOTAL_SITES" "$TOTAL_CLEAN" "$SCAN_DURATION" "$REPORT_PATH"
ln -sf "$REPORT_PATH" "$REPORT_LATEST"

echo -e "${GREEN}${BOLD}HTML report saved:${RESET}  $REPORT_PATH"
echo -e "${CYAN}Report URL:${RESET}         http://${HOSTNAME_VAL}/reports/${REPORT_FILENAME}"
echo -e "${CYAN}Latest permalink:${RESET}   http://${HOSTNAME_VAL}/reports/latest.html\n"
