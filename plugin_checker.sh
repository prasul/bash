#!/bin/bash

### A simple script to identify if a plugin is installed and if it does throw any error we can deactivate the plugin right away from the script and recheck it
## Prasul - GPU license ###

plugin_name=pluginname
error_keyword="yourkeyword here"
for domain in */; do
    domain=${domain%/}
    wp_path="$domain/public"
    plugin_path="$wp_path/wp-content/plugins/$plugin_name"
    url="https://$domain"

    # skip if not wordpress
    if [ ! -f "$wp_path/wp-config.php" ]; then
        continue
    fi

    # check if plugin folder exists
    if [ -d "$plugin_path" ]; then

        echo "======================================"
        echo "Checking $domain"

        # check for error
        if curl -L -s --max-time 10 "$url" | grep -q $error_keyword; then

            echo "Error detected: $error_keyword"

            echo "Deactivating nextgen-gallery-pro..."
            wp --allow-root plugin deactivate $plugin_name --path="$wp_path" --skip-plugins >/dev/null 2>&1

            sleep 2

            echo "Rechecking homepage..."

            status=$(curl -L -s --max-time 10 -o /dev/null -w "%{http_code}" "$url")

            if [ "$status" = "200" ]; then
                echo "$domain : FIXED (HTTP 200 after deactivation)"
            else
                echo "$domain : STILL ERROR ($status)"
            fi

        else
            echo "$domain : No error detected"
        fi

    fi

done
