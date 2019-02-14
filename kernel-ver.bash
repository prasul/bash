
#title           :kernel_check.sh
#description     :This script checks for kernel versions available on CL/RHEL servers.
#author		 :prasul
#date            :20180911
#version         :0.4    
#usage		 :bash kernel_check.sh

#!/bin/bash
if [ -f /etc/redhat-release ]; then
  /usr/bin/yum list kernel > /root/UpdateInfo
  update1=$(grep Available -A 1 /root/UpdateInfo|tail -1|awk '{print $2}')
  var1=$(grep Installed -A 1 /root/UpdateInfo|tail -1|awk '{print $2}')
  if [[ -z "$update1" ]]; then 
  	#send messages ready for slack
		echo -e "{\n 
			\"attachments\": [\n 
			{ \n 
			\"fallback\": \"Kernel is up-to-date on `hostname`\",
			\"title\": \"`hostname`: Kernel is up-to-date\",
			\"text\": \"_Kernel is up-to-date: current version is $var1 _ \",
			\"color\": \"#008000\",
			\"mrkdwn_in\": [\"text\"]\n
			}\n
			]\n
			}
			" > /root/kernel_update.txt
 	 else
		echo -e "{\n 
			\"attachments\": [\n 
			{ \n 
			\"fallback\": \"New Kernel is available on `hostname`\",
			\"title\": \"`hostname`: New Kernel Version available\",
			\"text\": \"_*New kernel is: $update1 *_ : _current version is $var1 _\",
			\"color\": \"#fc1e0d\",
			\"mrkdwn_in\": [\"text\"]\n
			}\n
			]\n
			}
			" > /root/kernel_update.txt
	fi
else
	echo "Not RHEL system"
fi

