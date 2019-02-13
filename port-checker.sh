#!/bin/bash
#checks if a port is open on CSF - if not then it will be added to the config and saved. The following script opens port for zabbix.

portchk=`grep 10050 /etc/csf/csf.conf`

if [ -z "$portchk" ]; then
cp /etc/csf/csf.conf /etc/csf/csf.conf.ori-Aug18
newtcpin=`cat /etc/csf/csf.conf |grep TCP_IN|grep "="|sed 's/\"$/\,10050\,10051\"/'`
newtcpout=`cat /etc/csf/csf.conf |grep TCP_OUT|grep "="|sed 's/\"$/\,10050\,10051\"/'`
sed -i '/TCP\_IN\ \=\ /c\'"$newtcpin"'' /etc/csf/csf.conf
sed -i '/TCP\_OUT\ \=\ /c\'"$newtcpout"'' /etc/csf/csf.conf
csf -r
else
echo "port open"
fi
