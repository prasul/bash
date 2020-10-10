#/bin/bash
#version 0.4
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
for file in `find . -name "$scrnshotprfx*"`;
do 
	ext=${file: -4};
	echo $ext;
	if [[ "$ext" != *"."* ]];
	then
		echo "$file does not a valid screenshot extension";
		continue;
	elif [ $ext == ".png" ]
	then
		echo "compressing the file.."
		magick $file -strip -interlace Plane -resize 80% -quality 80 newfile.png || { echo 'convert command failed, check if imagemagick is installed' ; exit 1; }
		rm -fv $file;
		file=newfile.png;
	else
		echo "no optimizations done!"
	fi
	filename=`/usr/bin/openssl rand -hex 24`;
	mv "$file" $filename$ext;
	tput setaf 2;echo "\nUploading screenshot:";tput setaf 3; 
	curl --progress-bar -T $filename$ext ftp://$ftpservip --user $ftpun:$ftppw || { echo 'uploading failed - try again manually' ; exit 1; }
	newshareurl="$shareurl/$filename$ext"; 
	echo $newshareurl >> urls;
	newshareurl="";
	tput setaf 4; echo "removing screenshot...";
	rm -v $filename*
done

#beautify the result
tput setaf 2; echo  "=======================\n Share URL \n======================="
tput sgr0;
cat 2>/dev/null urls|| { echo 'No urls to share :(' ; exit 1; }
echo "\n(URL copied!)"
cat urls|pbcopy
rm urls;
tput setaf 2; echo  "=======================\n End of Script \n=======================\n\n"
