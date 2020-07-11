#!/bin/bash
# The amazing automated lets encrypt issue script made by the one and only Prasul

if [[ -s $(pwd |grep public) ]]; then
        Current_domain=$(pwd |awk -F\/ '{print $5}') && yes \
        | /usr/local/src/centminmod/addons/acmetool.sh issue "${Current_domain}" live && cat /root/centminlogs/acmesh-issue_*.log |grep "${Current_domain}"-acme|head -3 > add.txt
        if grep -q 'cer\|key' add.txt; then
                if grep acme /usr/local/nginx/conf/conf.d/"${Current_domain}".ssl.conf; then
                        echo -e "WPO configuration already has acme entries"
                        rm -f add.txt
                else
                        if [[ -s add.txt ]]; then
                                echo -e "updating"
                                sed -i '/ssl_dhparam/r add.txt' /usr/local/nginx/conf/conf.d/"${Current_domain}".ssl.conf && rm -f add.txt
                                if nginx -t > /dev/null 2>&1; then
                                        sleep 15
                                        npreload > /dev/null 2>&1
                                else
                                        nginx -t 2>&1 | mail -s "WPO URGENT - Nginx conf fail during issueing SSL on ${Current_domain}  -  $HOSTNAME" monitor@bigscoots.com
                                        exit 1
                                fi
                        else
                                echo " No certs found "
                        fi
               fi
        else
               echo -e "WPO Error :Try runnning the command again, no certs created"

        fi


else
 echo "run the script from public folder"
fi
