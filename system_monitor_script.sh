
Can you look at this code block and see how we can optimize it to show the complete mysql query :

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
    }

—- 
this is how it shows now but it is not useful:

1863464 system     0s   Filling      schema table SELECT ID, DB, TIME, STATE, INFO

the queries from mysql should show up as :

 26398 | wpdb3176u3156 | localhost | wp3273926152db_3176 | Query   | 0    | Sending data | SELECT COUNT(DISTINCT product_or_parent_id) as term_count, term_id as term_count_id FROM wp_wc_product_attributes_lookup
                         LEFT JOIN wp_term_relationships ON (wp_wc_product_attributes_lookup.product_or_parent_id = wp_term_relationships.object_id)  LEFT JOIN wp_term_relationships AS tt1 ON (wp_wc_product_attributes_lookup.product_or_parent_id = tt1.object_id)
                        INNER JOIN wp_posts ON wp_posts.ID = wp_wc_product_attributes_lookup.product_or_parent_id
                        WHERE wp_posts.post_type IN ( 'product' )
                        AND wp_posts.post_status = 'publish'
                         AND (
  wp_wc_product_attributes_lookup.product_or_parent_id NOT IN (
                                SELECT object_id
                                FROM wp_term_relationships
                                WHERE term_taxonomy_id IN (7)
                        )
  AND
  wp_term_relationships.term_taxonomy_id IN (16,17,19,20,930,931,932,933,934,935,936,937,938,939,940,941,942,943,945,946,948,949,950,951,952,953,954,955,109684,109685)
  AND
  (
                                SELECT COUNT(1)
                                FROM wp_term_relationships
                                WHERE term_taxonomy_id IN (12163)
                                AND object_id = wp_wc_product_attributes_lookup.product_or_parent_id
                        ) = 1
  AND
  (
                                SELECT COUNT(1)
                                FROM wp_term_relationships
                                WHERE term_taxonomy_id IN (12122)
                                AND object_id = wp_wc_product_attributes_lookup.product_or_parent_id
                        ) = 1
  AND
  (
                                SELECT COUNT(1)
                                FROM wp_term_relationships
                                WHERE term_taxonomy_id IN (109293)
                                AND object_id = wp_wc_product_attributes_lookup.product_or_parent_id
                        ) = 1
  AND
  tt1.term_taxonomy_id IN (16,17,19,20,930,931,932,933,934,935,936,937,938,939,940,941,942,943,945,946,948,949,950,951,952,953,954,955,109684,109685)
)
                        AND wp_wc_product_attributes_lookup.taxonomy='pa_filter-by-baldric-size'
                        AND wp_wc_product_attributes_lookup.term_id IN (109289,109304,109303,109290,109250)
                                                AND product_or_parent_id IN ( SELECT product_or_parent_id FROM (
                                                        SELECT product_or_parent_id
                                                        FROM wp_wc_product_attributes_lookup lt
                                                        WHERE is_variation_attribute=0
                                                        AND term_id in (12163,12122,109293)
                                                        GROUP BY product_id
                                                        HAVING COUNT(product_id)=3
                                                        UNION
                                                        SELECT product_or_parent_id
                                                        FROM wp_wc_product_attributes_lookup lt
                                                        WHERE is_variation_attribute=1
                                                        AND term_id in (12163,12122,109293)
                                                        GROUP BY product_or_parent_id
                                                        HAVING COUNT(DISTINCT term_id)=3
                                                ) temp ) GROUP BY wp_wc_product_attributes_lookup.term_id | 0.000    |

So have to print something on to the script such that it shows something useful for the admin

Show more
10:59 AM
The core problem is two-fold: awk splits on whitespace so multi-word queries get mangled, and you're truncating to 45 characters with %.45s. Here's the optimized version:

bash
{
    printf "${MAGENTA}${BOLD}  ▶  MYSQL ACTIVE PROCESSES${R}\n"
    
    # Fetch with tab-separated output using \t as safe delimiter
    # We use --batch --silent to get tab-separated output without borders
    mysql_out=$(mysql --batch --silent -e "
        SELECT 
            ID, 
            IFNULL(DB, 'system') AS DB, 
            TIME, 
            IFNULL(STATE, '') AS STATE, 
            IFNULL(INFO, '') AS INFO 
        FROM information_schema.PROCESSLIST 
        WHERE COMMAND != 'Sleep' AND INFO IS NOT NULL 
        ORDER BY TIME DESC 
        LIMIT 8;" 2>/dev/null)

    if [ -z "$mysql_out" ]; then
        printf "  ${GRAY}${DIM}(no active queries)${R}\n"
        return
    fi

    echo "$mysql_out" | while IFS=$'\t' read -r id db time state query; do
        # Skip header row if present
        [[ "$id" == "ID" ]] && continue

        # Color time: red if > 5s, orange otherwise
        if [ "$time" -gt 5 ] 2>/dev/null; then
            tc="\033[38;5;196m"
        else
            tc="\033[38;5;214m"
        fi

        # Print the summary header line for this process
        printf "  \033[38;5;244m%-8s\033[0m \033[38;5;82m%-20s\033[0m ${tc}%-6s\033[0m \033[38;5;45m%s\033[0m\n" \
            "$id" "$db" "${time}s" "$state"

        # Print the full query, word-wrapped at 100 chars with indentation
        printf "\033[38;5;255m%s\033[0m\n" "$query" | fold -s -w 100 | while IFS= read -r line; do
            printf "    \033[38;5;240m│\033[0m \033[38;5;255m%s\033[0m\n" "$line"
        done

        # Separator between processes
        printf "  \033[38;5;237m%s\033[0m\n" "$(printf '─%.0s' {1..105})"
    done
}
```

**Key changes and why:**

**`--batch --silent` flag** — This makes MySQL output tab-separated values instead of the pipe-bordered table format. Tabs are safe delimiters because SQL queries rarely contain literal tab characters.

**`IFS=$'\t' read -r id db time state query`** — By setting the field separator to tab, the entire query (including spaces, newlines, special characters) lands cleanly in the `$query` variable without being split.

**`fold -s -w 100`** — Word-wraps the full query at 100 characters respecting word boundaries (`-s`). This means even a 5000-character WooCommerce monstrosity like your example will display fully, just wrapped neatly.

**Visual tree structure with `│`** — Each line of the query is prefixed with a dim vertical bar, making it visually clear that the wrapped lines belong to the same query entry rather than looking like separate rows.

**`IFNULL()` in SQL** — Handles NULL values at the database level rather than in awk, which is cleaner and more reliable.

The output will now look something like:
```
  ▶  MYSQL ACTIVE PROCESSES
  26398    wp3273926152db_3176   0s     Sending data
    │ SELECT COUNT(DISTINCT product_or_parent_id) as term_count, term_id as
    │ term_count_id FROM wp_wc_product_attributes_lookup LEFT JOIN wp_term_re
    │ lationships ON (wp_wc_product_attributes_lookup.product_or_parent_id =
    │ ...
  ─────────────────────────────────────────────────────────────────────────
on that note, is there anything on bash that can define these column sizes so that it doesn’t break the layout of other elements

11:00 AM
Yes — the key is terminal-aware dynamic sizing using tput. Here's the concept:

bash
# Get terminal width once at the top of your script or function
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

# Define your fixed columns first
COL_ID=8
COL_DB=20
COL_TIME=6
COL_STATE=14

# The query column gets whatever is LEFT over (minus padding/borders)
# 2 = left indent, 3 = separators between columns
COL_QUERY=$(( TERM_WIDTH - COL_ID - COL_DB - COL_TIME - COL_STATE - 2 - 3 ))

# Guard: never let it go negative or too small to be useful
[ "$COL_QUERY" -lt 30 ] && COL_QUERY=30
Then use those variables everywhere consistently:

bash
# Header
printf "  ${DGRAY}%-${COL_ID}s %-${COL_DB}s %-${COL_TIME}s %-${COL_STATE}s %s${R}\n" \
    "ID" "DB" "TIME" "STATE" "QUERY"

# Separator line — generated dynamically to match exact width
SEP_LINE=$(printf '─%.0s' $(seq 1 $TERM_WIDTH))
printf "  \033[38;5;237m%s\033[0m\n" "$SEP_LINE"

# Data rows
printf "  \033[38;5;244m%-${COL_ID}s\033[0m \033[38;5;82m%-${COL_DB}s\033[0m ${tc}%-${COL_TIME}s\033[0m \033[38;5;45m%-${COL_STATE}s\033[0m\n" \
    "$id" "$db" "${time}s" "$state"

# Query wrapped to its computed column width
printf "%s\n" "$query" | fold -s -w "$COL_QUERY" | while IFS= read -r line; do
    printf "  \033[38;5;240m│\033[0m \033[38;5;255m%-${COL_QUERY}s\033[0m\n" "$line"
done
A few patterns worth knowing:

tput cols is the right tool for terminal width — it reads the actual TTY dimensions and respects window resizes if you call it fresh each render. If you're running inside a non-interactive shell or a cron job it falls back gracefully with the || echo 80 default.

%-${COL_DB}s — variable-width printf formatting works exactly like %-20s, bash just expands the variable before printf sees it. This is the cleanest way to keep all your column math in one place at the top.

Truncation with printf — for the fixed columns you still want to prevent overflow if a DB name is 40 chars. You can do %-20.20s dynamically too:

bash
printf "%-${COL_DB}.${COL_DB}s" "$db"
Centralizing it as a layout config block at the top of your dashboard function means one place to tune for different screen sizes:

bash
_layout() {
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
    COL_ID=8
    COL_DB=20
    COL_TIME=6
    COL_STATE=14
    COL_QUERY=$(( TERM_WIDTH - COL_ID - COL_DB - COL_TIME - COL_STATE - 5 ))
    [ "$COL_QUERY" -lt 30 ] && COL_QUERY=30
    export COL_ID COL_DB COL_TIME COL_STATE COL_QUERY TERM_WIDTH
}

# Call once before rendering
_layout
This way if you ever add or remove a column, you change one number and the query column self-adjusts automatically across every printf in your script.

Can you correct this code:

    # ════════════════════════════════════════════
    #  BLOCK 6: RECENT FILE CHANGES (Cached)
    # ════════════════════════════════════════════
    {
        CUR_TIME=$(date +%s)

        # Only run the heavy 'find' command if the interval has passed
        if (( CUR_TIME - LAST_FILE_SCAN > SCAN_INTERVAL )); then
            # Perform the scan and save to cache
            find /home/nginx/domains/*/public/wp-content/{plugins,themes} -maxdepth 3 -mmin -1440 -type f \( -name "*.php" -o -name "*.js" \) 2>/dev/null | awk -F'/' '{
                dom=$5; type=$8; name=$9;
                cmd = "stat -c %y " $0;
                cmd | getline mod_time; close(cmd);
                split(mod_time, t, " ");

                if (type == "plugins") { t_col="\033[38;5;45m"; t_label="Plugin"; }
                else { t_color="\033[38;5;171m"; t_label="Theme"; }
                printf "  \033[38;5;114m%-18.18s\033[0m %b%-12s\033[0m \033[38;5;255m%-15.15s\033[0m \033[38;5;244m%s\033[0m\n", 
                    dom, t_col, t_label, name, t[2]
            }' | sort -u | head -8 > "$FILE_CACHE"

            LAST_FILE_SCAN=$CUR_TIME
        fi
        printf "${ORANGE}${BOLD}  ▶  FILE CHANGES (Last 24h - Scanned every 15m)${R}\n"
        printf "  ${DGRAY}%-18s %-12s %-15s %s${R}\n" "DOMAIN" "TYPE" "NAME" "TIME"
        printf "  ${DGRAY}%-18s %-12s %-15s %s${R}\n" "────────────────" "────────" "─────────────" "────────"

        if [ -s "$FILE_CACHE" ]; then
            cat "$FILE_CACHE"
        else
            printf "  ${GRAY}${DIM}(no changes detected in the last 24h)${R}\n"
        fi
    } > "$C2"

So it doesn’t repeat the same plugin name instead shows the plugin name once and the last time it was updated

Show more
11:23 AM
The core issue is that sort -u deduplicates exact lines but since timestamps differ per file, the same plugin appears multiple times. You need to track the latest modification time per plugin/theme and deduplicate by name. The awk script also has a bug — it uses t_col in the printf but assigns t_color for themes.

Here's the corrected block:

bash
# ════════════════════════════════════════════
#  BLOCK 6: RECENT FILE CHANGES (Cached)
# ════════════════════════════════════════════
{
    CUR_TIME=$(date +%s)
    
    if (( CUR_TIME - LAST_FILE_SCAN > SCAN_INTERVAL )); then

        find /home/nginx/domains/*/public/wp-content/{plugins,themes} -maxdepth 3 -mmin -1440 -type f \( -name "*.php" -o -name "*.js" \) 2>/dev/null \
        | awk -F'/' '
        {
            dom=$5; type=$8; name=$9;

            # Get modification time via stat
            cmd = "stat -c %y " $0;
            cmd | getline mod_time; close(cmd);
            split(mod_time, t, " ");
            mod = t[2];

            # Build a unique key: domain + type + plugin/theme name
            key = dom "|" type "|" name;

            # Only keep the LATEST modification time per key
            if (!(key in seen) || mod > latest[key]) {
                seen[key]   = 1;
                latest[key] = mod;
                domain[key] = dom;
                ptype[key]  = type;
                pname[key]  = name;
            }
        }
        END {
            for (key in seen) {
                type = ptype[key];
                if (type == "plugins") {
                    t_col   = "\033[38;5;45m";
                    t_label = "Plugin";
                } else {
                    t_col   = "\033[38;5;171m";
                    t_label = "Theme";
                }
                printf "  \033[38;5;114m%-18.18s\033[0m %b%-12s\033[0m \033[38;5;255m%-20.20s\033[0m \033[38;5;244m%s\033[0m\n",
                    domain[key], t_col, t_label, pname[key], latest[key];
            }
        }' \
        | sort -t' ' -k5 -r \
        | head -8 > "$FILE_CACHE"

        LAST_FILE_SCAN=$CUR_TIME
    fi

    printf "${ORANGE}${BOLD}  ▶  FILE CHANGES (Last 24h - Scanned every 15m)${R}\n"
    printf "  ${DGRAY}%-18s %-12s %-20s %s${R}\n" "DOMAIN" "TYPE" "NAME" "TIME"
    printf "  ${DGRAY}%-18s %-12s %-20s %s${R}\n" "──────────────────" "────────────" "────────────────────" "────────"

    if [ -s "$FILE_CACHE" ]; then
        cat "$FILE_CACHE"
    else
        printf "  ${GRAY}${DIM}(no changes detected in the last 24h)${R}\n"
    fi
} > "$C2"
What was fixed and why:

t_col vs t_color bug — the original assigned t_color for themes but referenced t_col in the printf, so themes would inherit whatever color was last set or print garbage. Both branches now consistently use t_col.

Deduplication by key — instead of relying on sort -u on full lines, awk now builds a key from domain|type|name. When the same plugin/theme is seen again, it only updates the stored time if the new one is later, so you always get the most recent modification per unique plugin.

END block for output — nothing gets printed until all files are processed, ensuring the deduplication is complete before any line is written. The sort -t' ' -k5 -r then sorts the final deduplicated output by time descending so the most recently changed items appear first.

%-20.20s for NAME — widened slightly since plugin folder names can be long (e.g. woocommerce-product-filter), and the header is updated to match.

It is the last file modified date that we need to show and the file name

11:28 AM
Good catch — showing the plugin/theme folder name is not very useful. What the admin actually needs is the specific file that changed and when. Here's the corrected version:

bash
# ════════════════════════════════════════════
#  BLOCK 6: RECENT FILE CHANGES (Cached)
# ════════════════════════════════════════════
{
    CUR_TIME=$(date +%s)
    
    if (( CUR_TIME - LAST_FILE_SCAN > SCAN_INTERVAL )); then

        find /home/nginx/domains/*/public/wp-content/{plugins,themes} -maxdepth 3 -mmin -1440 -type f \( -name "*.php" -o -name "*.js" \) 2>/dev/null \
        | while IFS= read -r filepath; do
            # Extract fields directly from the path
            dom=$(echo "$filepath"  | cut -d'/' -f5)
            type=$(echo "$filepath" | cut -d'/' -f8)
            file=$(basename "$filepath")

            # Get last modified time formatted cleanly
            mod_time=$(stat -c "%y" "$filepath" 2>/dev/null | cut -d'.' -f1)  # strips microseconds
            mod_date=$(echo "$mod_time" | cut -d' ' -f1)
            mod_hour=$(echo "$mod_time" | cut -d' ' -f2)

            if [ "$type" = "plugins" ]; then
                t_col="\033[38;5;45m"
                t_label="Plugin"
            else
                t_col="\033[38;5;171m"
                t_label="Theme"
            fi

            printf "  \033[38;5;114m%-18.18s\033[0m ${t_col}%-8s\033[0m \033[38;5;255m%-30.30s\033[0m \033[38;5;244m%s %s\033[0m\n" \
                "$dom" "$t_label" "$file" "$mod_date" "$mod_hour"

        done \
        | sort -k5,5r -k6,6r \
        | head -8 > "$FILE_CACHE"

        LAST_FILE_SCAN=$CUR_TIME
    fi

    printf "${ORANGE}${BOLD}  ▶  FILE CHANGES (Last 24h - Scanned every 15m)${R}\n"
    printf "  ${DGRAY}%-18s %-8s %-30s %s${R}\n" "DOMAIN" "TYPE" "FILE" "LAST MODIFIED"
    printf "  ${DGRAY}%-18s %-8s %-30s %s${R}\n" "──────────────────" "────────" "──────────────────────────────" "───────────────────"

    if [ -s "$FILE_CACHE" ]; then
        cat "$FILE_CACHE"
    else
        printf "  ${GRAY}${DIM}(no changes detected in the last 24h)${R}\n"
    fi
} > "$C2"
```

**What changed and why:**

**`basename "$filepath"`** — instead of parsing the 9th path segment with awk (which breaks if the path depth varies), `basename` reliably pulls just the filename regardless of how deep it sits.

**`stat -c "%y"`** — this gives you the true last-modified timestamp of that specific file. The `| cut -d'.' -f1` strips the microseconds so you get a clean `2025-02-24 14:32:11` format instead of `2025-02-24 14:32:11.483920`.

**Split date and time** — stored separately so `sort -k5,5r -k6,6r` can sort by date first then time, giving you the most recently modified files at the top.

**Switched from awk to `while read`** — path parsing with awk's `$8`, `$9` positional fields is fragile if domain names contain unusual characters or the directory depth shifts. The `cut -d'/' -f5` approach is explicit and easier to adjust.

The output will now look like:
```
  ▶  FILE CHANGES (Last 24h - Scanned every 15m)
  DOMAIN             TYPE     FILE                           LAST MODIFIED
  ────────────────── ──────── ────────────────────────────── ───────────────────
  example.com        Plugin   class-wc-query.php             2025-02-24 14:32:11
  shop.example.com   Theme    functions.php                  2025-02-24 11:18:44

#!/bin/bash # ═══════════════════════════════════════════════ # SYSTEM MONITOR DASHBOARD — AI Prasul :-P # ═══════════════════════════════════════════════ R="\033[0m" BOLD="\033[1m" DIM="\033[2m" RED="\033[38;5;196m" RED_S="\033[38;5;203m" GREEN="\033[38;5;82m" GREEN_S="\033[38;5;114m" YELLOW="\

pasted

Perfect! Can you look at  and ensure that the column widths are not affected by other columns and the layout is clear. From what I see.. the mysql queries part is where the layout breaks and is there any option that you can think to ensure that the display of queries is more meaningful - also need to add a warning on top if the disk usage is above 98%

11:39 AM
Looking at the full script, I can see several layout issues. The MySQL block is the main culprit — it outputs multi-line wrapped queries into a half-width column that was never designed for it. Here's my plan:

MySQL gets its own full-width block (not crammed into a half-column)
Disk warning added at the top near the header
Column widths normalized using the layout variables we discussed
Block 4 & 5 layout fixes for consistent padding

Reading the frontend design skill
Reading the frontend design skill
Now let me write the corrected script:


Created a file, read a file
Created a file, read a file
Here's a summary of every change made:

MySQL is now full-width (biggest fix). It was previously crammed into a HALF-width column via render_two_cols, which is why the queries were mangling the layout. It now renders directly to the terminal outside of the two-column system, so COL_MYSQL_QUERY gets the full remaining width. Each process shows a compact summary line (ID / DB / TIME / STATE) followed by the full query wrapped neatly with │ prefix lines.

Centralized layout config block at the top. Every column width is now a named variable (COL_IP_ADDR, COL_WL_DOM, etc.) defined in one place. All printf calls reference these variables with %-${COL_X}.${COL_X}s syntax so truncation and padding are always in sync — change one number and every affected column adjusts.

Disk warning banner. Added before the header renders. It loops through df output, checks for any mount at 98%+, and if triggered renders a full-width blinking red alert bar listing exactly which mounts are critical.

WP-Login and Live Traffic moved into Block 4 together (left/right) so the old Block 5 slot is freed up for MySQL's full-width block.

Separator lines auto-generated from column widths using printf '─%.0s' $(seq 1 $COL_X) so they always match the actual column width rather than being hardcoded strings that drift out of alignment.

Monitor
SH 
can we add the plugin name to the monitor as well

11:49 AM
Looking at the file changes block — right now it shows domain, type (Plugin/Theme), filename, and modified time. You want the plugin/theme folder name as well (e.g. woocommerce, elementor) alongside the specific file that changed.

The plugin folder sits at path position 9 (/home/nginx/domains/DOMAIN/public/wp-content/plugins/PLUGIN_NAME/...file):


Viewed 2 files
Viewed 2 files
Now I have a clear picture. I need to extract path field 9 as the plugin/theme folder name and add a COL_FC_PLUGIN column. Let me update the layout config and the file changes block:


Edited 2 files, read a file
Edited 2 files, read a file
Three focused changes:

cut -d'/' -f9 — the path structure is /home/nginx/domains/DOMAIN/public/wp-content/plugins/PLUGIN_NAME/file.php, so field 9 is always the plugin or theme folder name (e.g. woocommerce, elementor, astra). Field 8 is already plugins or themes, field 9 is the name inside that.

New COL_FC_PLUGIN=22 column — sized at 22 chars (enough for most plugin names) and rendered in yellow \033[38;5;220m to visually distinguish it from the filename which stays white. The existing columns were slightly trimmed (DOM 20→18, TYPE 8→7, FILE 30→26) to make room without breaking the half-width layout.

Sort fix — the sort keys shifted from k5,k6 to k6,k7 to account for the new plugin column being inserted before the date/time fields.

The output will now look like:

  DOMAIN             TYPE    PLUGIN / THEME         FILE                       LAST MODIFIED
  example.com        Plugin  woocommerce            class-wc-query.php         2025-02-24 14:32:11
  shop.example.com   Theme   astra                  functions.php              2025-02-24 11:18:44
Monitor
SH 
or better, if we can just list the plugin name instead of showing the file that it was updated recently  with the date and may be list the count of files updated on the plugin

11:51 AM
Good call — much more useful for an admin to see "woocommerce had 4 files changed" than a list of individual filenames. Let me update the block:


View the full file changes block to understand current structure
View the full file changes block to understand current structure
Now I also need to update the layout config since COL_FC_FILE is no longer needed:


Remove COL_FC_FILE from layout config, rename COL_FC_PLUGIN to be wider
Remove COL_FC_FILE from layout config, rename COL_FC_PLUGIN to be wider
Now replace the entire file changes block with the new aggregated approach:


Edited a file, read a file
Edited a file, read a file
The output will now look like this:

  ▶  FILE CHANGES (Last 24h — Scanned every 15m)
  DOMAIN               TYPE    FILES  PLUGIN / THEME               LAST MODIFIED
  ────────────────────  ───────  ──────  ────────────────────────────  ───────────────────
  example.com          Plugin  8      woocommerce                  2025-02-24 14:32:11
  example.com          Plugin  2      elementor                    2025-02-24 13:10:05
  shop.example.com     Theme   1      astra                        2025-02-24 11:18:44
What changed and why:

Two-pass approach — the find now emits a raw TSV of domain/type/plugin/modtime per file, then awk aggregates that into one row per unique domain+type+plugin key, counting files and keeping only the latest mod time. This is done entirely before anything hits the cache file.

FILES count column — coloured green for small counts and orange for 6+ files, which is a useful signal that something more significant happened (e.g. a plugin auto-update touching dozens of files vs. a single config tweak).

Sorted by most recent mod time — sort -t$'\t' -k5,5r sorts on the latest-modified timestamp so the most recently active plugin always floats to the top.

head -12 instead of 8 — since we're now showing one row per plugin rather than per file, bumping to 12 gives a better picture of everything that changed across a busy server with many domains.

Monitor
SH 
The error logs for nginx is at /home/nginx/domains/domainname/log/error.log - can we add a code to monitor this as well - show something like:

——————————-
domain name   |  error log entry detected |  Changes | snippet | request to
——————————

example.com NEW (2025-02-24 14:32:11) |  +2  | *65595 access forbidden by rule, client: 103.65.236.204

The log format is as follows:

2026/02/25 00:11:51 [error] 3999724#3999724: *65595 access forbidden by rule, client: 103.65.236.204, server: buyingasword.com, request: "GET //xmlrpc.php?rsd HTTP/2.0", host: "buyingasword.com"
2026/02/25 00:16:34 [error] 3999730#3999730: *68195 access forbidden by rule, client: 195.178.110.159, server: buyingasword.com, request: "GET /.git/config HTTP/2.0", host: "buyingasword.com"

Show more
12:01 PM
Good addition — nginx error logs are a goldmine for spotting attacks, bad bots, and misconfigs. Let me design this properly before coding it.

The log has structured fields we can parse: timestamp, error type, client IP, server, request method+path. The most useful groupings for an admin are error type + request path per domain, with a delta count showing new errors since last refresh.


Viewed 2 files
Viewed 2 files
Good. Now I'll add the nginx error log columns to the layout config and insert the new full-width block between the file changes block and the footer:


Edited 3 files
Edited 3 files
Now insert the nginx error log block before the footer:


Edited a file, read a file
Edited a file, read a file
Here's what was built and the reasoning behind each decision:

Full-width block — like MySQL, error log entries are too content-rich to survive in a half-column. They get their own row spanning the terminal.

tail -n 200 per domain — reading the whole error log on every 20s refresh would be slow on busy servers. 200 lines captures recent activity without hammering disk I/O, and since entries are sorted by timestamp descending the most relevant ones always surface.

Deduplication by client + request + core_message — the same attack (e.g. a bot hammering /.git/config) generates dozens of identical lines. Grouping on those three fields collapses them into one row with a count, keeping the display clean.

Delta column (Δ NEW) — the ERRLOG_STATE file persists counts between refreshes. On each cycle it compares the new count against the old and shows +N in red if new errors arrived, — if the count is unchanged, or NEW in orange the first time an entry appears. This means at a glance you can see which domains are actively being hit vs. which errors are stale.

Snippet column is dynamic — COL_ERR_SNIPPET is computed as whatever width is left after the fixed columns, so it automatically expands on wide terminals and shrinks gracefully on narrow ones without breaking the line.

The output per row will look like:

  DOMAIN                 LAST SEEN             Δ NEW   CLIENT IP           REQUEST                   ERROR SNIPPET
  buyingasword.com       2026/02/25 00:16:34   +2      195.178.110.159     GET /.git/config          access forbidden by rule
  example.com            2026/02/25 00:11:51   NEW     103.65.236.204      GET //xmlrpc.php?rsd      access forbidden by rule
Monitor
SH 
what more information will be useful during high load situations

12:17 PM
Great question — high load situations have a specific set of questions an admin needs answered fast:

"What is saturating the server right now?"

Which processes are in D-state (uninterruptible sleep — usually waiting on disk I/O)
Disk I/O wait percentage (separate from CPU usage — a server can be 90% iowait with low CPU)
Which disk/mount is being hammered (iostat — reads/writes per second, await time)
"Is it memory pressure causing the load?"

Swap usage and swap I/O rate (if swap is actively being used, you're in trouble)
OOM killer activity (dmesg recent kills)
Available memory vs cached — the number that actually matters is available, not free
"Is PHP-FPM the bottleneck?"

Active vs idle worker count per pool — if active = max_children you're queueing requests
PHP-FPM queue depth (accepted connections waiting)
Average request duration per pool from the slowlog
"Is it a database bottleneck?"

MySQL thread count vs max_connections percentage
Queries per second rate (delta between refreshes)
InnoDB buffer pool hit rate — below 95% means excessive disk reads
Tables locked / lock wait count
"Is it network saturation?"

Bytes in/out per second per interface (not just connection counts)
Packet drop/error counts on the NIC
TIME_WAIT count — if very high (10k+) you may be exhausting ephemeral ports
"What just changed?"

Recent cron jobs that fired in the last 5 minutes (/var/log/cron)
Any new processes that appeared since last refresh (diff of process list)
Here's what I'd suggest adding to the dashboard, ranked by usefulness during an actual incident:

Priority 1 — add immediately:

┌─ SYSTEM PRESSURE ──────────────────────────────────────────┐
│ CPU iowait: 34%  │ Mem available: 1.2G  │ Swap used: 800M  │
│ Swap I/O:  in 4MB/s  out 12MB/s  ← this alone tells a story│
│ D-state processes: 3  (mysqld, php-fpm, nginx)              │
└────────────────────────────────────────────────────────────-┘
Priority 2 — high value:

┌─ PHP-FPM POOLS ─────────────────────────────────────────────┐
│ POOL         ACTIVE   IDLE   MAX    QUEUE   STATUS           │
│ www          48       2      50     12      ⚠ SATURATED      │
│ domain_pool  3        17     20     0       ✔ OK             │
└─────────────────────────────────────────────────────────────┘

┌─ MYSQL HEALTH ──────────────────────────────────────────────┐
│ Threads: 42/151  QPS: 1,240 (+340)  Lock waits: 8           │
│ InnoDB hit rate: 91%  ⚠  Slow queries (last min): 14        │
└─────────────────────────────────────────────────────────────┘
Priority 3 — useful context:

┌─ DISK I/O ──────────────────────────────────────────────────┐
│ DEVICE    READ/s    WRITE/s   AWAIT(ms)   UTIL%             │
│ sda       124KB     48MB      142ms ⚠     89% ⚠             │
└─────────────────────────────────────────────────────────────┘
Want me to code all three priority levels into the dashboard? I'd suggest:

Priority 1 as a new full-width "SYSTEM PRESSURE" bar right below the host/uptime line — always visible, zero scrolling
Priority 2 as a two-column block (PHP-FPM left, MySQL health summary right) — MySQL health replaces the verbose query block during high load isn't needed
Priority 3 as a collapsible or always-on block after file changes
That way the most critical diagnostics are at the top where eyes go first during an incident. Should I implement all three, or start with Priority 1 and 2?

yes lets go with all three

12:18 PM
Let me plan this carefully before writing any code — there are several data sources involved and I want to get the commands right first.


Viewed 3 files
Viewed 3 files
Good. Now I have a clear picture of the full structure. Let me build all three priority blocks and wire them in cleanly:


Edited 2 files
Edited 2 files
Now insert the Priority 1 — System Pressure Bar right after the host/uptime/load line:


Insert system pressure bar after host/uptime line
Insert system pressure bar after host/uptime line
Now insert Priority 2 — PHP-FPM (left) | MySQL Health (right) as a new block after block 1:


Insert PHP-FPM and MySQL health block after block 1 CPU/Memory
Insert PHP-FPM and MySQL health block after block 1 CPU/Memory
Now insert Priority 3 — Disk I/O as a full-width block just before the nginx error log block:


Edited a file, read a file
Edited a file, read a file
Here's a summary of everything added and the reasoning behind each design decision:

Priority 1 — System Pressure Bar (always visible, sits right below the host line)

Six metrics on a single line so nothing is hidden below the fold during an incident. The iowait uses a two-snapshot /proc/stat delta rather than a single read — a single read gives you a lifetime average which is useless; the delta gives you what's happening right now. OOM kills check dmesg tail so they survive log rotation. If any threshold is breached the whole bar gets a ⚠ HIGH LOAD DETECTED badge.

Priority 2 — PHP-FPM Pools (left) | MySQL Health (right)

PHP-FPM tries cgi-fcgi against discovered unix sockets first — this gives you the real pool status page data including listen queue depth, which is the single most important number (if queue > 0 you are dropping requests). Falls back to ps stat counting if the status page isn't set up.

MySQL health computes QPS as a delta between refreshes using MYSQL_QPS_STATE — a cumulative Questions counter is meaningless; what you need is queries per second right now. InnoDB buffer pool hit rate below 95% means MySQL is reading from disk instead of memory, which explains high iowait. Colour thresholds are set at operationally meaningful levels: connections at 70%/90% of max_connections, slow queries at 5/20, buffer pool hit rate at 99%/95%.

Priority 3 — Disk I/O (full-width, before error logs)

Uses iostat -xk 1 2 if available — the 1 2 means two samples one second apart, and only the second sample is used because the first is a cumulative average since boot. Falls back to /proc/diskstats two-snapshot delta if iostat isn't installed. Await time is the most useful single disk metric — high await with low utilisation means the drive is slow (or failing); high await and high utilisation means it's genuinely saturated.

Monitor
SH 


Want to be notified when Claude responds?



Claude is AI and can make mistakes. Please double-check responses.
Monitor · SH
Copy

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
ERRORLOG_PATH="/home/nginx/domains/*/log/error.log"
SLOWLOG="/var/log/php-fpm/www-slow.log"
IP_STATE_FILE="/tmp/ip_counts.state"
touch "$IP_STATE_FILE"
FILE_CACHE="/tmp/recent_file_changes.cache"
LAST_FILE_SCAN=0
SCAN_INTERVAL=900  # 900 seconds = 15 minutes
ERRLOG_STATE="/tmp/nginx_error_counts.state"  # persists per-domain error counts across refreshes
touch "$ERRLOG_STATE"
MYSQL_QPS_STATE="/tmp/mysql_qps.state"        # tracks query count between refreshes for QPS delta
touch "$MYSQL_QPS_STATE"
PHPFPM_STATUS_URL="http://127.0.0.1/status"   # adjust if your fpm status page is on a different path/port

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

# Nginx error log columns (full-width block)
COL_ERR_DOM=22     # domain name
COL_ERR_TIME=20    # timestamp of latest entry
COL_ERR_DELTA=6    # +N new errors since last refresh
COL_ERR_CLIENT=18  # client IP
COL_ERR_REQ=24     # request path
# snippet (error message) gets the remainder

# PHP-FPM pool columns (two-column block, left side)
COL_FPM_POOL=20    # pool name
COL_FPM_ACT=7      # active workers
COL_FPM_IDLE=6     # idle workers
COL_FPM_MAX=6      # max children
COL_FPM_QUEUE=7    # queue depth
COL_FPM_STATUS=12  # status label

# MySQL health columns (two-column block, right side)
COL_MH_LABEL=18    # metric label
COL_MH_VAL=14      # metric value

# Disk I/O columns (full-width block)
COL_IO_DEV=10      # device name
COL_IO_READ=10     # read KB/s
COL_IO_WRITE=10    # write KB/s
COL_IO_AWAIT=12    # await ms
COL_IO_UTIL=8      # utilisation %

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

    # ══════════════════════════════════════════════
    #  SYSTEM PRESSURE BAR — always visible
    #  Sits directly below host line so it's the
    #  first thing eyes land on during an incident.
    #  Sources: /proc/stat (iowait), /proc/meminfo
    #  (available/swap), vmstat (swap I/O),
    #  ps D-state count
    # ══════════════════════════════════════════════
    {
        # ── CPU iowait % ──────────────────────────
        # Read two snapshots 0.3s apart for an accurate delta
        read_cpu1=$(awk '/^cpu / {print $5, $6}' /proc/stat 2>/dev/null)
        read_total1=$(awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat 2>/dev/null)
        sleep 0.3
        read_cpu2=$(awk '/^cpu / {print $5, $6}' /proc/stat 2>/dev/null)
        read_total2=$(awk '/^cpu / {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat 2>/dev/null)
        IOWAIT_PCT=$(awk -v c1="$read_cpu1" -v t1="$read_total1" \
                         -v c2="$read_cpu2" -v t2="$read_total2" '
            BEGIN {
                split(c1,a1," "); split(c2,a2," ")
                diowait = a2[1] - a1[1]
                dtotal  = t2 - t1
                if (dtotal > 0) printf "%.0f", (diowait/dtotal)*100
                else print "0"
            }')

        # ── Memory: available and total ───────────
        MEM_AVAIL=$(awk '/^MemAvailable:/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null)
        MEM_TOTAL=$(awk '/^MemTotal:/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null)
        MEM_USED=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.0f", ((t-a)/t)*100}' /proc/meminfo 2>/dev/null)

        # ── Swap: used and I/O rates ──────────────
        SWAP_USED=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{
            used=(t-f)/1024; printf "%.0fM", used}' /proc/meminfo 2>/dev/null)
        SWAP_TOTAL=$(awk '/^SwapTotal:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)

        # Swap I/O: read two vmstat snapshots
        SWAP_IN=0; SWAP_OUT=0
        if command -v vmstat &>/dev/null; then
            vmstat_line=$(vmstat 1 2 2>/dev/null | tail -1)
            SWAP_IN=$(echo  "$vmstat_line" | awk '{print $7}')
            SWAP_OUT=$(echo "$vmstat_line" | awk '{print $8}')
        fi

        # ── D-state (uninterruptible sleep) count ─
        DSTATE=$(ps -eo stat 2>/dev/null | grep -c '^D' || echo 0)

        # ── OOM kills in last 100 dmesg lines ─────
        OOM_COUNT=$(dmesg 2>/dev/null | tail -n 100 | grep -c "Out of memory\|oom-kill" || echo 0)

        # ── Colour helpers ────────────────────────
        iowait_col="${GREEN_S}";  [ "${IOWAIT_PCT:-0}" -ge 20 ] && iowait_col="${ORANGE}";  [ "${IOWAIT_PCT:-0}" -ge 50 ] && iowait_col="${RED}${BOLD}"
        mem_col="${GREEN_S}";     [ "${MEM_USED:-0}"   -ge 80 ] && mem_col="${ORANGE}";     [ "${MEM_USED:-0}"   -ge 95 ] && mem_col="${RED}${BOLD}"
        swap_col="${GREEN_S}";    [ "${SWAP_OUT:-0}"   -ge 10 ] && swap_col="${ORANGE}";    [ "${SWAP_OUT:-0}"   -ge 50 ] && swap_col="${RED}${BOLD}"
        dstate_col="${GREEN_S}";  [ "${DSTATE:-0}"     -ge 3  ] && dstate_col="${ORANGE}";  [ "${DSTATE:-0}"     -ge 10 ] && dstate_col="${RED}${BOLD}"
        oom_col="${GREEN_S}";     [ "${OOM_COUNT:-0}"  -ge 1  ] && oom_col="${RED}${BOLD}${BLINK}"

        printf "${CYAN}${BOLD}  ▶  SYSTEM PRESSURE${R}"

        # Alert label if things look bad
        if [ "${IOWAIT_PCT:-0}" -ge 50 ] || [ "${MEM_USED:-0}" -ge 95 ] || \
           [ "${DSTATE:-0}" -ge 10 ]     || [ "${OOM_COUNT:-0}" -ge 1 ]; then
            printf "  ${BG_ALERT}${RED}${BOLD}${BLINK} ⚠ HIGH LOAD DETECTED ${R}"
        fi
        printf "\n"

        printf "  ${DGRAY}CPU iowait:${R} ${iowait_col}${BOLD}%-6s%%${R}  " "${IOWAIT_PCT:-0}"
        printf "${DGRAY}Mem used:${R} ${mem_col}${BOLD}%-4s%%${R} ${DGRAY}(${R}${WHITE}${MEM_AVAIL}G avail / ${MEM_TOTAL}G${R}${DGRAY})${R}  "
        printf "${DGRAY}Swap:${R} ${swap_col}${BOLD}%-6s${R}  "  "${SWAP_USED}"
        printf "${DGRAY}Swap I/O in/out:${R} ${swap_col}${BOLD}%s/%s KB/s${R}  " "${SWAP_IN:-0}" "${SWAP_OUT:-0}"
        printf "${DGRAY}D-state procs:${R} ${dstate_col}${BOLD}%s${R}  " "${DSTATE:-0}"
        printf "${DGRAY}OOM kills:${R} ${oom_col}${BOLD}%s${R}\n" "${OOM_COUNT:-0}"
    }
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
    #  BLOCK 2: PHP-FPM Pools (left) | MySQL Health (right)
    # ════════════════════════════════════════════
    C1=$(mktemp); C2=$(mktemp)

    # LEFT — PHP-FPM pool status
    # Reads /proc/net/unix to find fpm socket paths, then
    # queries each pool's status page via cgi-fcgi or curl.
    # Falls back to parsing the master process children via ps
    # if the status page isn't reachable.
    {
        printf "${CYAN}${BOLD}  ▶  PHP-FPM POOLS${R}\n"
        printf "  ${DGRAY}%-${COL_FPM_POOL}s %-${COL_FPM_ACT}s %-${COL_FPM_IDLE}s %-${COL_FPM_MAX}s %-${COL_FPM_QUEUE}s %s${R}\n" \
            "POOL" "ACTIVE" "IDLE" "MAX" "QUEUE" "STATUS"
        printf "  ${DGRAY}%-${COL_FPM_POOL}s %-${COL_FPM_ACT}s %-${COL_FPM_IDLE}s %-${COL_FPM_MAX}s %-${COL_FPM_QUEUE}s %s${R}\n" \
            "$(printf '─%.0s' $(seq 1 $COL_FPM_POOL))" "──────" "─────" "─────" "──────" "──────────"

        fpm_found=0

        # Method 1: query status pages via unix sockets using cgi-fcgi
        if command -v cgi-fcgi &>/dev/null; then
            for sock in /var/run/php*.sock /run/php/*.sock /tmp/php*.sock; do
                [ -S "$sock" ] || continue
                pool=$(basename "$sock" .sock | sed 's/php[0-9.-]*-fpm-\?//')
                [ -z "$pool" ] && pool=$(basename "$sock" .sock)

                status_raw=$(SCRIPT_FILENAME=/status SCRIPT_NAME=/status \
                    REQUEST_METHOD=GET cgi-fcgi -bind -connect "$sock" 2>/dev/null)

                active=$(echo "$status_raw" | grep "^active processes:"  | awk '{print $NF}')
                idle=$(echo   "$status_raw" | grep "^idle processes:"    | awk '{print $NF}')
                maxc=$(echo   "$status_raw" | grep "^max children reached" | awk '{print $NF}')
                queue=$(echo  "$status_raw" | grep "^listen queue:"      | awk '{print $NF}')
                maxq=$(echo   "$status_raw" | grep "^max listen queue:"  | awk '{print $NF}')

                [ -z "$active" ] && continue
                fpm_found=1

                total=$(( ${active:-0} + ${idle:-0} ))
                [ "$total" -eq 0 ] && total=1
                pct=$(( ${active:-0} * 100 / total ))

                if   [ "${active:-0}" -ge "${maxc:-999}" ] 2>/dev/null; then
                    st="${RED}${BOLD}⚠ SATURATED${R}"
                elif [ "$pct" -ge 80 ]; then
                    st="${ORANGE}▲ HIGH${R}"
                else
                    st="${GREEN_S}✔ OK${R}"
                fi

                printf "  ${WHITE}%-${COL_FPM_POOL}.${COL_FPM_POOL}s${R} " "$pool"
                printf "${ORANGE}%-${COL_FPM_ACT}s${R} "    "${active:-0}"
                printf "${GRAY}%-${COL_FPM_IDLE}s${R} "     "${idle:-0}"
                printf "${DGRAY}%-${COL_FPM_MAX}s${R} "     "${maxc:-?}"
                printf "${YELLOW}%-${COL_FPM_QUEUE}s${R} "  "${queue:-0}"
                printf "%b\n" "$st"
            done
        fi

        # Method 2: fallback — count php-fpm worker processes via ps
        if [ "$fpm_found" -eq 0 ]; then
            ps -eo comm,stat 2>/dev/null | awk '
            /php-fpm/ || /php[0-9].*-fpm/ {
                if ($2 ~ /^S/) idle++
                else if ($2 ~ /^R/) active++
                total++
            }
            END {
                if (total > 0) {
                    pct = int(active*100/total)
                    st = (pct >= 80) ? "\033[38;5;196mHIGH\033[0m" : "\033[38;5;82m✔ OK\033[0m"
                    printf "  \033[38;5;255m%-20s\033[0m %-7s %-6s %-6s %-7s %b\n",
                        "php-fpm", active+0, idle+0, total, "n/a", st
                } else {
                    print "  \033[38;5;244m(php-fpm not detected or status page unreachable)\033[0m"
                }
            }'
        fi
    } > "$C1"

    # RIGHT — MySQL Health metrics
    # Uses mysqladmin status + SHOW GLOBAL STATUS for key counters.
    # QPS is computed as a delta against the previous refresh so it
    # shows actual queries/sec rather than a lifetime cumulative.
    {
        printf "${MAGENTA}${BOLD}  ▶  MYSQL HEALTH${R}\n"
        printf "  ${DGRAY}%-${COL_MH_LABEL}s %s${R}\n" "METRIC" "VALUE"
        printf "  ${DGRAY}%-${COL_MH_LABEL}s %s${R}\n" "$(printf '─%.0s' $(seq 1 $COL_MH_LABEL))" "──────────────"

        # Fetch all status vars in one query
        mysql_health=$(mysql --batch --silent -e "
            SHOW GLOBAL STATUS WHERE Variable_name IN (
                'Threads_connected','Threads_running','max_used_connections',
                'Questions','Slow_queries','Table_locks_waited',
                'Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests',
                'Innodb_row_lock_waits','Com_select','Com_insert',
                'Com_update','Com_delete','Aborted_connects'
            );
            SHOW VARIABLES WHERE Variable_name = 'max_connections';" 2>/dev/null)

        if [ -z "$mysql_health" ]; then
            printf "  ${GRAY}${DIM}(mysql not accessible)${R}\n"
        else
            get_val() { echo "$mysql_health" | awk -v k="$1" '$1==k{print $2}'; }

            threads_conn=$(get_val "Threads_connected")
            threads_run=$(get_val  "Threads_running")
            max_conn=$(get_val     "max_connections")
            questions=$(get_val    "Questions")
            slow_q=$(get_val       "Slow_queries")
            lock_wait=$(get_val    "Table_locks_waited")
            bp_reads=$(get_val     "Innodb_buffer_pool_reads")
            bp_req=$(get_val       "Innodb_buffer_pool_read_requests")
            row_locks=$(get_val    "Innodb_row_lock_waits")
            aborted=$(get_val      "Aborted_connects")

            # ── QPS delta ─────────────────────────
            prev_q=$(cat "$MYSQL_QPS_STATE" 2>/dev/null || echo 0)
            QPS=0
            if [ -n "$questions" ] && [ "${prev_q:-0}" -gt 0 ] 2>/dev/null; then
                QPS=$(( (questions - prev_q) / 20 ))   # 20s refresh interval
                [ "$QPS" -lt 0 ] && QPS=0
            fi
            echo "${questions:-0}" > "$MYSQL_QPS_STATE"

            # ── InnoDB buffer pool hit rate ────────
            BP_HIT="n/a"
            if [ -n "$bp_req" ] && [ "${bp_req:-0}" -gt 0 ] 2>/dev/null; then
                BP_HIT=$(awk -v r="${bp_reads:-0}" -v req="$bp_req" \
                    'BEGIN{printf "%.1f%%", (1-(r/req))*100}')
            fi

            # ── Colour thresholds ──────────────────
            conn_pct=0
            [ "${max_conn:-0}" -gt 0 ] && conn_pct=$(( ${threads_conn:-0} * 100 / max_conn ))
            conn_col="${GREEN_S}";   [ "$conn_pct" -ge 70 ] && conn_col="${ORANGE}";  [ "$conn_pct" -ge 90 ] && conn_col="${RED}${BOLD}"
            run_col="${GREEN_S}";    [ "${threads_run:-0}" -ge 10 ] && run_col="${ORANGE}"; [ "${threads_run:-0}" -ge 30 ] && run_col="${RED}${BOLD}"
            slow_col="${GREEN_S}";   [ "${slow_q:-0}" -ge 5  ] && slow_col="${ORANGE}"; [ "${slow_q:-0}" -ge 20 ] && slow_col="${RED}${BOLD}"
            lock_col="${GREEN_S}";   [ "${lock_wait:-0}" -ge 1  ] && lock_col="${ORANGE}"; [ "${lock_wait:-0}" -ge 10 ] && lock_col="${RED}${BOLD}"
            bp_num=$(echo "$BP_HIT" | tr -d '%')
            bp_col="${GREEN_S}";     [ "${bp_num:-100}" != "n/a" ] && [ "${bp_num%.*}" -lt 99 ] 2>/dev/null && bp_col="${ORANGE}"
                                     [ "${bp_num:-100}" != "n/a" ] && [ "${bp_num%.*}" -lt 95 ] 2>/dev/null && bp_col="${RED}${BOLD}"
            qps_col="${GREEN_S}";    [ "${QPS:-0}" -ge 500  ] && qps_col="${ORANGE}"; [ "${QPS:-0}" -ge 2000 ] && qps_col="${RED}${BOLD}"

            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${conn_col}%s / %s${R} ${DGRAY}(%s%%)${R}\n" \
                "Connections" "${threads_conn:-?}" "${max_conn:-?}" "$conn_pct"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${run_col}%s${R}\n" \
                "Threads running"  "${threads_run:-?}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${qps_col}%s q/s${R}\n" \
                "QPS (last 20s)"   "${QPS}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${slow_col}%s${R}\n" \
                "Slow queries"     "${slow_q:-?}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${lock_col}%s${R}\n" \
                "Table lock waits" "${lock_wait:-?}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${bp_col}%s${R}\n" \
                "InnoDB hit rate"  "${BP_HIT}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${ORANGE}%s${R}\n" \
                "Row lock waits"   "${row_locks:-?}"
            printf "  ${DGRAY}%-${COL_MH_LABEL}s${R} ${GRAY}%s${R}\n" \
                "Aborted connects" "${aborted:-?}"
        fi
    } > "$C2"

    render_two_cols "$C1" "$C2"
    rm -f "$C1" "$C2"
    hline '─' "$DGRAY"
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
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 8: DISK I/O — FULL WIDTH
    #
    #  Uses /proc/diskstats with a 1s delta to
    #  compute real KB/s read+write and await ms.
    #  Only shows physical disks (sd*, nvme*, vd*).
    #  Falls back to iostat if available.
    # ════════════════════════════════════════════
    {
        printf "${YELLOW}${BOLD}  ▶  DISK I/O${R}\n"
        printf "  ${DGRAY}%-${COL_IO_DEV}s %-${COL_IO_READ}s %-${COL_IO_WRITE}s %-${COL_IO_AWAIT}s %-${COL_IO_UTIL}s %s${R}\n" \
            "DEVICE" "READ/s" "WRITE/s" "AWAIT(ms)" "UTIL%" "STATUS"
        printf "  ${DGRAY}%-${COL_IO_DEV}s %-${COL_IO_READ}s %-${COL_IO_WRITE}s %-${COL_IO_AWAIT}s %-${COL_IO_UTIL}s %s${R}\n" \
            "──────────" "──────────" "──────────" "────────────" "────────" "──────────"

        if command -v iostat &>/dev/null; then
            # iostat -x: extended stats, 2 samples 1s apart, show only the second
            iostat -xk 1 2 2>/dev/null | awk '
            /^(sd|nvme|vd|xvd|hd)[a-z0-9]/ {
                dev=$1; rkbs=$6; wkbs=$7; await=$10; util=$NF
                # colour thresholds
                uc="\033[38;5;82m"
                if (util+0 >= 50) uc="\033[38;5;214m"
                if (util+0 >= 85) uc="\033[38;5;196m\033[1m"
                ac="\033[38;5;82m"
                if (await+0 >= 20) ac="\033[38;5;214m"
                if (await+0 >= 100) ac="\033[38;5;196m\033[1m"

                st="✔ OK"
                stc="\033[38;5;82m"
                if (util+0 >= 85 || await+0 >= 100) { st="⚠ HIGH"; stc="\033[38;5;196m\033[1m" }
                else if (util+0 >= 50 || await+0 >= 20) { st="▲ BUSY"; stc="\033[38;5;214m" }

                printf "  \033[38;5;255m%-10s\033[0m %s%-9s\033[0m %s%-9s\033[0m %s%-10s\033[0m %s%-8s\033[0m %b%s\033[0m\n",
                    dev,
                    "\033[38;5;45m",  sprintf("%.0fK", rkbs),
                    "\033[38;5;171m", sprintf("%.0fK", wkbs),
                    ac, sprintf("%.1fms", await),
                    uc, sprintf("%.0f%%", util),
                    stc, st
            }' | tail -n +2   # skip first sample (cumulative), keep second (interval)
        else
            # Fallback: /proc/diskstats two-snapshot delta
            snap1=$(awk '/^[ ]*[0-9]+ [0-9]+ (sd|nvme|vd)/ {print $3,$6,$10,$13}' /proc/diskstats 2>/dev/null)
            sleep 1
            snap2=$(awk '/^[ ]*[0-9]+ [0-9]+ (sd|nvme|vd)/ {print $3,$6,$10,$13}' /proc/diskstats 2>/dev/null)

            paste <(echo "$snap1") <(echo "$snap2") | awk '{
                dev=$1
                dr=($6-$2)*512/1024    # sectors→KB
                dw=($7-$3)*512/1024
                dio_ms=($8-$4)         # ms spent in I/O
                # simple util: ms doing I/O in last 1000ms
                util=(dio_ms > 1000) ? 100 : dio_ms/10

                uc="\033[38;5;82m"
                if (util >= 50) uc="\033[38;5;214m"
                if (util >= 85) uc="\033[38;5;196m\033[1m"

                st="✔ OK"; stc="\033[38;5;82m"
                if (util >= 85) { st="⚠ HIGH"; stc="\033[38;5;196m\033[1m" }
                else if (util >= 50) { st="▲ BUSY"; stc="\033[38;5;214m" }

                printf "  \033[38;5;255m%-10s\033[0m \033[38;5;45m%-10s\033[0m \033[38;5;171m%-10s\033[0m \033[38;5;244m%-12s\033[0m %s%-8s\033[0m %b%s\033[0m\n",
                    dev,
                    sprintf("%.0fK/s", dr),
                    sprintf("%.0fK/s", dw),
                    "n/a",
                    uc, sprintf("%.0f%%", util),
                    stc, st
            }'
        fi
    }
    hline '─' "$DGRAY"

    # ════════════════════════════════════════════
    #  BLOCK 9: NGINX ERROR LOG MONITOR — FULL WIDTH
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
