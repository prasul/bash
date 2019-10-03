
#!/bin/bash
STATUS=$(/usr/bin/MegaCli64 -CfgDsply -aALL -nolog |grep '^State' |awk '{print $3}')
#STATUS=degraded
RAIDSTATUS=$(/usr/bin/MegaCli64 -LDInfo -Lall -aALL |grep -C6 Degraded)
HOSTNAME=$(echo "`hostname` : `ifconfig | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p'`")
#RAIDSTATUS=/usr/bin/MegaCli64 -LDRecon ShowProg L0 -a0
echo $HOSTNAME $STATUS : $RAIDSTATUS
if [ "$STATUS" != "Optimal" ]; then
 #echo -e "Subject: RAID WARNING @ 119.252.189.63 : \n\n$STATUS"|/usr/sbin/sendmail server.alerts@xhostsolutions.com.au
 /usr/sbin/sendmail server.alerts@xhostsolutions.com.au << EOF
subject: Warning: Raid Status on $HOSTNAME : $STATUS
from: raid@xhostsolutions.com.au
Hostname: $HOSTNAME
Raid Status Warning: $STATUS
Raid Status: $RAIDSTATUS

please check!
EOF
fi
