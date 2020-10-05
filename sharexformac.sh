#/bin/bash
#version 0.3
#Prasuls bash script to create a random name for screenshot name in MAC and upload it to FTP server. 
#Upload the script on to the folder where the screenshots are getting created.
#Warning: Script doesn't take screenshots yet - it just renames and uploads the file to FTP

#Get username and password

ftpservip=
ftpun=
ftppw=
shareurl=

#Get screenshot prefix
scrnshotprfx=

#remove additional space characters
for f in *\ *; do mv 2>/dev/null "$f" "${f// /_}"; done

#filename change and upload
for file in `find . -name "$scrnshotprfx*.png"`;
do 
	filename=`/usr/bin/openssl rand -hex 24`;
  	mv "$file" $filename.png;
	tput setaf 2;
  	echo "\nUploading screenshot:";tput setaf 3; 
	curl --progress-bar -T $filename.png ftp://$ftpservip --user $ftpun:$ftppw; 
	newshareurl="$shareurl/$filename.png"; 
	echo $newshareurl >> urls;
	tput setaf 4; echo "removing screenshot from local...";
	rm -v $filename*
done

#beautify the result
tput setaf 2; echo  "=======================\n Share URL \n======================="
tput sgr0;
cat urls;

#copy the url to clipboard
echo "\n(URL copied!)"
cat urls|pbcopy
rm urls;
tput setaf 2; echo  "=======================\n End of Script \n=======================\n\n"
