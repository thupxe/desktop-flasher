#!/bin/bash

CLI_NS="lab.cs.thu.edu.cn"
CLI_NS_UUID=""
ERROR=""
CLI_PART_NAME="thupxeroot"

pre_req () {
	local tools=( "sfdisk" "sgdisk" "dd" "xxd" "uuidgen" "lsblk" "base64" "partx")
	for i in "${tools[@]}"; do
		command -v "$i" > /dev/null
		if [ "$?" -ne 0 ]; then
			echo "Error: Command $i not found" >&2
			exit -1
		fi
	return 0
}

read_serial () {
	lsblk --output SERIAL --nodeps --noheadings -- "$1"
}

gen_cli_uuid () {
	if [ -z "$CLI_NS_UUID" ]; then
		CLI_NS_UUID="$(uuidgen --sha1 --namespace @dns --name "$CLI_NS")"
	fi
	uuidgen --sha1 --namespace "$CLI_NS_UUID" --name "$1"
}

write_table () {
	declare -r MBR_START=446
	declare -r MBR_SIZE=66
	local dev="$1"
	local dev_serial="$(read_serial "$dev")"
	if [ -z "$dev_serial" ]; then
		ERROR="Cannot read device serial"
		return 1
	fi
	local partuuid="$(gen_cli_uuid "$dev_serial")"
	sgdisk --zap-all -- "$dev"
	if [ "$?" -ne 0 ]; then 
		ERROR="Cannot clear partition table"
		return 1
	fi
	sfdisk --no-reread --no-tell-kernel -- "$dev" << EOF
label: dos
1    33    ee -
34   2014  ef *
2048 -     ee -
EOF
	local mbr="$(dd if="$dev" bs=1 count=${MBR_SIZE} skip=${MBR_START} | base64 -w 0)"
	local mbr_sig="$(echo "$mbr" | base64 -d | tail --bytes 2 | xxd -p)"
	if [ "$mbr_sig" != "55aa" ]; then
		ERROR="Failed to write MBR partition table"
		return 1
	fi
	sgdisk --zap-all -- "$dev"
	sgdisk --set-alignment=1 --new=2:34:2047 --typecode=2:EF02 --attributes=2:set:2 -- "$dev"
	sgdisk --new=3:1M:+512M --typecode=3:EF00 -- "$dev"
	sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:"${CLI_PART_NAME}" --attributes=1:set:62 -- "$dev"
	sgdisk --partition-guid=1:"$partuuid" -- "$dev"
	echo "$mbr" | base64 -d | dd of="$dev" bs=1 seek="${MBR_START}" count="${MBR_SIZE}" conv=nocreat,notrunc
	if [ "$?" -ne 0 ]; then
		ERROR="Failed to write Hybird MBR partition table"
		return 1
	fi
	sgdisk --verify "$dev"
	if [ "$?" -ne 0 ]; then
		ERROR="Problems detected in partition table"
		return 1
	fi
}

