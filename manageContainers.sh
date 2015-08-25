#!/bin/bash
# set -x
##################################################################################
## 
## VERSION		:2.0.5
## DATE			:26Aug2015
##
## USAGE		:This script will help to start, stop and remove containers. Poor mans version of kitematic
##################################################################################

# Ref	:	http://wiki.bash-hackers.org/syntax/arrays
# Ref	:	https://www.gnu.org/s/gawk/manual/html_node/Printf-Examples.html

# [ -n "$__DEBUG" ] && set -x

# home="$( cd "$( dirname "$0" )" && pwd )"


# Set the colors to be used
RED_COLOR='\e[0;31m'			# Red
GREEN_COLOR='\e[0;32m'			# Green
NC='\033[0m'					# No Color
# Usage : printf "I ${RED}love${NC} Stack Overflow\n"

# declare -A, introduced with Bash 4 to declare an associative array
declare -A quickStartContainers

# Google readme recommends cAdvisor to be run in privileged mode to monitor docker container in RHEL
# https://github.com/google/cadvisor/blob/master/docs/running.md
quickStartContainers["cAdvisor"]="docker run \
--detach=true \
--name=cadvisor \
--privileged=true \
--volume=/cgroup:/cgroup:ro \
--volume=/:/rootfs:ro \
--volume=/var/run:/var/run:rw \
--volume=/sys:/sys:ro \
--volume=/var/lib/docker/:/var/lib/docker:ro \
--publish=8080:8080 \
google/cadvisor:latest"

quickStartContainers["ClouderaMgrNode"]="docker run -dti \
--name clouderamgrnode \
-p 32768:22 \
-p 7180:7180 \
-p 28910:80 \
--privileged=true \
-v /media/sf_dockerRepos:/media/sf_dockerRepos \
local/clouderamgrnode:v1 /usr/sbin/sshd -D"

quickStartContainers["namenode1"]="docker run -dti \
--name namenode1 \
-p 32769:22 \
--privileged=true \
-v /media/sf_dockerRepos:/media/sf_dockerRepos \
local/clouderanodebase:v2 /usr/sbin/sshd -D"

quickStartContainers["datanode1"]="docker run -dti \
--name datanode1 \
-p 32770:22 \
--privileged=true \
-v /media/sf_dockerRepos:/media/sf_dockerRepos \
local/clouderanodebase:v2 /usr/sbin/sshd -D"

quickStartContainers["datanode2"]="docker run -dti \
--name datanode2 \
-p 32771:22 \
--privileged=true \
-v /media/sf_dockerRepos:/media/sf_dockerRepos \
local/clouderanodebase:v2 /usr/sbin/sshd -D"

quickStartContainers["RepoNode"]="docker run -dti \
--name reponode \
-p 28915:80 \
-p 28916:8080 \
-p 28917:8082 \
-v /media/sf_dockerRepos:/media/sf_dockerRepos \
local/alpinepython:v1 /bin/sh"

quickStartContainers["webnode1"]="docker run -dti \
--name webnode1 \
-p 8082:80 \
-v /media/sf_dockerRepos:/media/sf_dockerRepos \
httpd:latest /bin/bash"

quickStartContainers["Weave"]="weave launch && weave launch-dns && weave launch-proxy"
quickStartContainers["Scope"]="scope launch"
quickStartContainers["Busybox"]="docker run -dti busybox /bin/sh"
quickStartContainers["alpinetest"]="docker run -dti --name alpinetest -p 28918:80 -v /media/sf_dockerRepos:/media/sf_dockerRepos alpine:latest /bin/sh"


# Function Manipulation
#	${arr[*]}         # All of the items in the array
#	${!arr[*]}        # All of the indexes in the array
#	${#arr[*]}        # Number of items in the array
#	${#arr[0]}        # Length of item zero

docker info > /dev/null 2>&1 && printf "\n\t Preparing the menu...\n\n" || { printf "\n\tDocker is not running! Ensure Docker is running before running this script\n\n"; exit; }

# DEFAULT_KUBECONFIG="${HOME}/.kube/config"

DOCKER_IMAGES_DIR=/media/sf_dockerRepos/dockerBckUps

shopt -s nullglob
declare -a puppetOptions=("Load Containers" "Start Containers" "Restart Exited Containers" "Stop Containers" "Remove Images" "Remove Containers" "Stop And Remove Containers" "Exit")
declare -a loadedImages=($(docker images | awk -F ' ' '{print $1":"$2}' | grep -v "REPOSITORY" 2> /dev/null))
declare -a runningContainers=($(docker inspect --format '{{.Name}}' $(docker ps -q) 2> /dev/null | cut -d\/ -f2))
declare -a exitedContaiers=($(docker inspect --format '{{.Name}}' $(docker ps -q -f status=exited) 2> /dev/null | cut -d\/ -f2 ))

declare -a imageList=( "$DOCKER_IMAGES_DIR"/*.tar )
# Trims the prefixes and give only file names
imageList=( "${imageList[@]##*/}" )
# Removes the extensions from the file names
imageList=( "${imageList[@]%.*}" )

# Functions to manage the containers

# Check if a value exists in an array
# @param $1 mixed  Needle  
# @param $2 array  Haystack
# @return  Success (0) if value exists, Failure (1) otherwise
# Usage: in_array "$needle" "${haystack[@]}"
# See: http://fvue.nl/wiki/Bash:_Check_if_array_element_exists

in_array() {
    local hay needle=$1
    shift
    for hay; do
        [[ "$hay" == "$needle" ]] && return 0
    done
    return 1
}

function refreshArrStatus() {
	exitedContaiers=($(docker inspect --format '{{.Name}}' $(docker ps -q -f status=exited) | cut -d\/ -f2 &1> /dev/null))
	}

function flushStatus() {	
	# pass assocociative array in string form to function
	e="$( declare -p $1 )"
	eval "declare -A myArr=${e#*=}"
	
	if [[ -n "${myArr[*]}" ]] &> /dev/null; then
		printf "\n\n\t\t Finished processing request for,"
		printf "\n\t\t ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n"
		for index in "${!myArr[@]}"
		do
			if [ "${myArr["${index}"]}" == "SUCCESS" ] &> /dev/null; then
				printf "%32s : ${GREEN_COLOR}%s${NC}\n" "$index" "${myArr["${index}"]}"
			else
				printf "%32s : ${RED_COLOR}%s${NC}\n" "$index" "${myArr["${index}"]}"
			fi
		done
		printf "\t\t ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n\n"
	else
		{ printf "\n\t\t Nothing to process!!\n\n"; }
	fi
	exit
	}

function startWeave() {
	# Currently CentOS7 doesn't like weave containers passing around ICMP, until that is resolved
	# https://github.com/weaveworks/weave/issues/1266
	iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited 2> /dev/null
	iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2> /dev/null
	
	# Lets check if weave environment variable is set if not set it
	if [[ -z "$DOCKER_HOST" ]] 2>&1 > /dev/null; then
		eval $(weave proxy-env) &> /dev/null
		if [[ -z "$DOCKER_HOST" ]] 2>&1 > /dev/null; then
			{ weave launch &> /dev/null && weave launch-dns &> /dev/null && weave launch-proxy &> /dev/null && eval $(weave proxy-env) &> /dev/null && printf "\n\n\t Successfully started weave\n\n"; return 0; } \
			|| { printf "\n\t Not able to start weave, Starting without weave\n\n"; return 1; }
		fi		 
	fi
	}

function manageContainers () {
	#Check if any arguments are passed
	if [ "$#" -eq 0 ]; then
		echo "You didn't choose any options"		
		return 1
	fi
	if [ "$1" == "Load Containers" ]; then
		loadContainers
		elif [ "$1" == "Start Containers" ]; then
		startContainers
		elif [ "$1" == "Restart Exited Containers" ]; then
		startExitedContainers
		elif [ "$1" == "Stop Containers" ]; then
		stopContainers
		elif [ "$1" == "Remove Images" ]; then
		removeImages
		elif [ "$1" == "Remove Containers" ]; then
		removeContainers
		elif [ "$1" == "Stop And Remove Containers" ]; then
		stop_removeContainers
		elif [ "$1" == "Exit" ]; then
		return 0
	fi
	}

function loadContainers () {
	[[ -n "${imageList[*]}" ]] || { printf "\n\t There are no images to load!\n\n";exit; }
	cd "$DOCKER_IMAGES_DIR"
	printf "\n\t Choose the images to load :"
	printf "\n\t --------------------------\n"
	for index in "${!imageList[@]}"
	do
		printf "%12d : %s\n" $index "${imageList[$index]}"
	done
	printf "\t --------------------------\n"
	
	declare -a cIndexes
	declare -A cStatus
	
	read -p "	 Choose the images to be loaded (by indexes seperated by spaces) : " -a cIndexes
	
	for index in "${cIndexes[@]}"
	do
		# Check if the chosen input is from the displayed input array
		in_array "$index" "${!imageList[@]}" && \
		{
			printf "\n\n\t\t Starting to load image\t\t: %s" "${imageList["$index"]}"
			docker load < "${imageList["$index"]}".tar &> /dev/null \
			&& { printf "\n\t\t COMPLETED loading image\t: %s" "${imageList["$index"]}"; cStatus["${imageList["$index"]}"]="SUCCESS"; } \
			|| { printf "\n\t\t FAILED to load image\t\t: %s" "${imageList["$index"]}"; cStatus["${imageList["$index"]}"]="FAILED"; }
		}
	done
	
	flushStatus "cStatus"
	}

function startContainers () {
	printf "\n\t Choose images to start :"
	printf "\n\t --------------------------\n"
	for index in "${!quickStartContainers[@]}"
	do
		printf "%12s %s\n" ">" "${index}"
	done
	printf "\t --------------------------\n"
	
	declare -a cIndexes
	declare -A cStatus
	
	read -p "	Choose the containers to be started (by indexes seperated by spaces) : " -a cIndexes
	
	# Lets check if weave environment variable is set if not set it
	startWeave
	
	for index in "${cIndexes[@]}"
	do
		# Check if the chosen input is from the displayed input array
		in_array "$index" "${!quickStartContainers[@]}" && \
		{ 
			printf "\n\n\t\t Starting container\t\t: %s" "${index}"
			${quickStartContainers["$index"]} &> /dev/null \
			&& { printf "\n\t\t Successfully started container\t: %s" "${index}"; cStatus["$index"]="SUCCESS"; } \
			|| { printf "\n\t\t FAILED to start container\t: %s" "${index}"; cStatus["$index"]="FAILED"; }
		}
	done
	
	flushStatus "cStatus"
	exit
}

function startExitedContainers() {
	printf "\n\t Choose containers to start :"
	printf "\n\t --------------------------\n"
	for index in "${!exitedContaiers[@]}"
	do
		printf "%12d : %s\n" $index "${exitedContaiers["$index"]}"
	done
	printf "\t --------------------------\n"
	
	read -p "	Choose the containers to be started (by indexes seperated by spaces) : " -a cIndexes
	
	# Lets check if weave environment variable is set if not set it
	startWeave
	
	declare -A cStatus
	
	for index in "${cIndexes[@]}"
	do
		# Check if the chosen input is from the displayed input array
		in_array "$index" "${!runningContainers[@]}" && \
		{ 
			printf "\n\n\t\t Starting container\t\t: %s" "${exitedContaiers["$index"]}"
			docker start "${exitedContaiers["$index"]}" &> /dev/null \
			&& { printf "\n\t\t Successfully started container\t: %s" "${exitedContaiers["$index"]}"; cStatus["${exitedContaiers["$index"]}"]="SUCCESS"; } \
			|| { printf "\n\t\t FAILED to start container\t: %s" "${exitedContaiers["$index"]}"; cStatus["${exitedContaiers["$index"]}"]="FAILED"; }
		}
	done
	
	flushStatus "cStatus"
	}

function stopContainers () {
	[[ -n "${runningContainers[*]}" ]] || { printf "\n\t No containers are in running state!\n\n";exit; }
	printf "\n\t Choose containers to stop :"
	printf "\n\t --------------------------\n"
	for index in "${!runningContainers[@]}"
	do
		printf "%12d : %s\n" "$index" "${runningContainers[$index]}"
	done
	printf "\t --------------------------\n"
	
	read -p "	 Choose the containers to be stopped (by indexes seperated by spaces) : " -a cIndexes
	
	# Create associative array with format <index> <image/container Name>
	declare -A cStatus
		
	for index in "${cIndexes[@]}"
	do
		# Check if the chosen input is from the displayed input array
		in_array "$index" "${!runningContainers[@]}" && \
		{ 
			printf "\n\n\t\t Attempting to stop container\t: %s" "${runningContainers["$index"]}"
			docker stop "${runningContainers["$index"]}" &> /dev/null \
			&& { printf "\n\t\t Stopped container\t\t: %s\n" "${runningContainers["$index"]}"; cStatus["${runningContainers["$index"]}"]="SUCCESS"; } \
			|| { printf "\n\t\t FAILED to stop container\t: %s" "${runningContainers["$index"]}"; cStatus["${runningContainers["$index"]}"]="FAILED"; }
		}
	done

	flushStatus "cStatus"
}

function removeImages () {
	[[ -n "${loadedImages[*]}" ]] || { printf "\n\t There are no images in docker!\n\n";exit; }
	
	# Generate the menu to choose images to be removed
	printf "\n\t Choose images to remove :"
	printf "\n\t --------------------------\n"
	for index in "${!loadedImages[@]}"
	do
		printf "%12d : %s\n" "$index" "${loadedImages[$index]}"
	done
	printf "\t --------------------------\n"
	
	read -p "	 Choose the images to be removed (by indexes seperated by spaces) : " -a cIndexes
	
	# Create associative array with format <index> <image/container Name>
	declare -A cStatus
	
	for index in "${cIndexes[@]}"
	do
		# Check if the chosen input is from the displayed input array
		in_array "$index" "${!loadedImages[@]}" && \
		{ 
			printf "\n\n\t\t Attempting to stop container\t: %s" "${loadedImages["$index"]}"
			docker rmi "${loadedImages["$index"]}" &> /dev/null \
			&& { printf "\n\t\t COMPLETED removing image\t: %s\n" "${loadedImages["$index"]}"; cStatus["${loadedImages["$index"]}"]="SUCCESS"; } \
			|| { printf "\n\t\t FAILED to remove image\t\t: %s" "${loadedImages["$index"]}"; cStatus["${loadedImages["$index"]}"]="FAILED"; }
		}
	done

	flushStatus "cStatus"
	return 0
}

function removeContainers() {
	[[ -n "${exitedContaiers[*]}" ]] || { printf "\n\t There are no containers in exited state!\n\n";exit; }
		#Check if any containers are running(-n for not null) if not exit with a message saying no containers are running
		if [[ -n $(docker ps -a -q -f status=exited) ]] &> /dev/null; then
			docker rm -v $(docker ps -a -q -f status=exited) &> /dev/null && { printf "\n\t REMOVED all exited containers\n\n"; exit; } || { printf "\n\t Not able to remove containers\n\n"; exit; }
		fi
	return 0
	}

function stop_removeContainers() {
	stopContainers
	refreshArrStatus
	removeContainers
	exit
	}
clear
printf "\n\n\n\n\n"
PS3=$'\n\t Choose container management task [Enter] : '
select opt in "${puppetOptions[@]}";
do
    if [[ "$opt" != "Exit" ]] ; then
	manageContainers "$opt"
    else
		echo -e "\n\t You chose to exit! \n"
        break
    fi
done
