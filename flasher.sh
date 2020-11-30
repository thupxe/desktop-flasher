#!/bin/bash

declare -r MBR_START=446
declare -r MBR_SIZE=66
declare -r BIOS_BOOT_START=34
declare -r EFI_START=2048
declare -r EFI_SIZE=1048576

declare -r IPXE_SRC="ipxe/src"
declare -r IPXE_BIOS_BOOT="${IPXE_SRC}/bin-i386-pcbios/ipxe.hd"
declare -r IPXE_MBR="${IPXE_SRC}/bin-i386-pcbios/mbr.bin"
declare -r IPXE_EFI="${IPXE_SRC}/bin-x86_64-efi/ipxe.efi"

CLI_NS="lab.cs.thu.edu.cn"
CLI_NS_UUID=""
ERROR=""
CLI_PART_NAME="thupxeroot"

pre_req () {
	local tools=( "sfdisk" "sgdisk" "dd" "xxd" "uuidgen" "lsblk" "base64" "partx" "mcopy" "mformat" "mmd" )
	for i in "${tools[@]}" "$@"; do
		command -v "$i" > /dev/null
		if [ "$?" -ne 0 ]; then
			echo "Error: Command $i not found" >&2
			exit -1
		fi
	done
	return 0
}

read_serial () {
	lsblk --output SERIAL --nodeps --noheadings -- "$1"
}

uuidgen_fixed () {
	# Work around https://github.com/karelzak/util-linux/issues/683
	declare -r test_v_fix="e4651143-99bb-5707-b2a5-93f9534add4f"
	declare -r test_v_bug="e4651143-99bb-5707-92a5-93f9534add4f"
	local test_result="$(uuidgen --sha1 --namespace @dns --name " ")"
	if [ "$test_result" = "$test_v_fix" ]; then
		uuidgen_fixed () {
			local ns=$1
			local name=$2
			uuidgen --sha1 --namespace "$ns" --name "$name"
		}
	elif [ "$test_result" = "$test_v_bug" ]; then
		uuidgen_fixed () {
			local ns=$1
			local name=$2
			case "$ns" in
				@dns)
					ns="6ba7b810-9dad-11d1-80b4-00c04fd430c8"
				;;
				@url)
					ns="6ba7b811-9dad-11d1-80b4-00c04fd430c8"
				;;
				@oid)
					ns="6ba7b812-9dad-11d1-80b4-00c04fd430c8"
				;;
				@x500)
					ns="6ba7b814-9dad-11d1-80b4-00c04fd430c8"
				;;
			esac
			local buguuid=$(uuidgen --sha1 --namespace "$ns" --name "$name")
			local correct_byte=$((echo "$ns" | tr -d '-' | xxd -r -p; echo -n "$name") | sha1sum | cut -d" " -f 1 | head --byte 17 | tail --byte 1)
			printf -v correct_byte "%x" $(( ( "0x$correct_byte" & 0x3 ) | 0x8 ))
			echo "${buguuid:0:19}${correct_byte}${buguuid:20}"
		}
	else
		echo "I do not know how to fix uuidgen" >&2
		exit 1
	fi
	uuidgen_fixed "$@"
}

gen_cli_uuid () {
	if [ -z "$CLI_NS_UUID" ]; then
		CLI_NS_UUID="$(uuidgen_fixed @dns "$CLI_NS")"
	fi
	uuidgen_fixed "$CLI_NS_UUID" "$1"
}

write_table () {
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
1                    $((BIOS_BOOT_START - 1))          ee -
${BIOS_BOOT_START}   $((EFI_START - BIOS_BOOT_START))  ef *
${EFI_START}         -                                 ee -
EOF
	local mbr="$(dd if="$dev" bs=1 count=${MBR_SIZE} skip=${MBR_START} | base64 -w 0)"
	local mbr_sig="$(echo "$mbr" | base64 -d | tail --bytes 2 | xxd -p)"
	if [ "$mbr_sig" != "55aa" ]; then
		ERROR="Failed to write MBR partition table"
		return 1
	fi
	sgdisk --zap-all \
	       --set-alignment=1 --new=2:"${BIOS_BOOT_START}":"$((EFI_START - 1))" --typecode=2:EF02 --attributes=2:set:2 \
	       --new=3:"${EFI_START}":+"${EFI_SIZE}" --typecode=3:EF00 \
	       --new=1:0:0 --typecode=1:8300 --change-name=1:"${CLI_PART_NAME}" --attributes=1:set:62 \
	       --partition-guid=1:"$partuuid" \
	       -- "$dev"
	echo "$mbr" | base64 -d | dd of="$dev" bs=1 seek="${MBR_START}" count="${MBR_SIZE}" conv=nocreat,notrunc
	if [ "$?" -ne 0 ]; then
		ERROR="Failed to write Hybird MBR partition table"
		return 1
	fi
	sgdisk --verify -- "$dev"
	if [ "$?" -ne 0 ]; then
		ERROR="Problems detected in partition table"
		return 1
	fi
	return 0
}

compile_ipxe () {
	if [ -e "ipxe/.dist" ]; then
		return 0;
	fi
	cat > "${IPXE_SRC}/config/local/general.h" << EOF
#define VLAN_CMD
#define REBOOT_CMD
#define POWEROFF_CMD
#define PING_CMD
EOF
	make -C "${IPXE_SRC}" -j "$(nproc)" \
		bin-i386-pcbios/ipxe.hd \
		bin-i386-pcbios/mbr.bin \
		bin-x86_64-efi/ipxe.efi
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		ERROR="Failed to Compile iPXE"
	fi
	return $rc
}

file_exist () {
	test -e "$1"
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		ERROR="File $1 does not exist"
	fi
	return $rc
}

fsize () {
	wc --bytes -- "$1" | cut -d' ' -f 1
}


verify_ipxe_files () {
	if ! file_exist "${IPXE_BIOS_BOOT}" || \
	   ! file_exist "${IPXE_MBR}" || \
	   ! file_exist "${IPXE_EFI}"; then
		ERROR="$ERROR, ensure this script is executed in its containing directory"
		return 1
	fi
	if [ "$(fsize "${IPXE_MBR}")" -gt "${MBR_START}" ]; then
		ERROR="${IPXE_MBR} is too large to fit in MBR"
		return 1
	fi
	if [ "$(fsize "${IPXE_BIOS_BOOT}")" -gt "$(( 512 * (EFI_START - BIOS_BOOT_START) ))" ]; then
		ERROR="${IPXE_BIOS_BOOT} is too large to fit in bios boot partition"
		return 1
	fi
	if [ "$(fsize "${IPXE_EFI}")" -gt "$(( 512 * EFI_SIZE ))" ]; then
		ERROR="${IPXE_EFI} is too large to fit in EFI partition"
		return 1
	fi
}

write_disk () {
	local dev="$1"
	
	dd of="$dev" if="${IPXE_MBR}" bs=1 count="${MBR_START}" conv=nocreat,notrunc && \
	dd of="$dev" if="${IPXE_BIOS_BOOT}" bs=512 seek="${BIOS_BOOT_START}" count="$(( EFI_START - BIOS_BOOT_START ))" conv=nocreat,notrunc
	
	if [ "$?" -ne 0 ]; then
		ERROR="Cannot write BIOS boot data"
		return 1
	fi
	
	# Work around bug fixed in mtools 4.0.20:
	#  - file/device locking with timeout (rather than immediate failure)
	# Settle udevd before mtools invocation
	
	# Work around missing feature in mtools 4.0.19
	#  - mformat: figure out LBA geometry as last resort if geometry
	#    is neither specified in config and/or commandline, nor can be
	#    queried from the device
	# Manually specify c/h/s parameter, we specify 16 heads and
	#   63 sectors per track and calculate tracks per head
	
	udevadm settle && \
	mformat -i "$dev"@@"$(( 512 * EFI_START ))" -t "$((EFI_SIZE / (63 * 16) ))" -s 63 -h 16 -F "::" && \
	  udevadm settle && \
	  mmd   -i "$dev"@@"$(( 512 * EFI_START ))" "::efi" && \
	  udevadm settle && \
	  mmd   -i "$dev"@@"$(( 512 * EFI_START ))" "::efi/boot" && \
	  udevadm settle && \
	  mcopy -i "$dev"@@"$(( 512 * EFI_START ))" "${IPXE_EFI}" "::efi/boot/bootx64.efi"
	
	if [ "$?" -ne 0 ]; then
		ERROR="Cannot write EFI boot data"
		return 1
	fi
	
	return 0
}

work_on_disk () {
	local dev="$1"
	local ret
	write_table "$dev"
	ret=$?
	if [ "$ret" -ne 0 ]; then
		return $ret
	fi
	write_disk "$dev"
	ret=$?
	if [ "$ret" -ne 0 ]; then
		return $ret
	fi
	return 0
}

prepend () {
	while read line; do
		echo "${1}${line}"
	done
}

target_devices=( )
write_once="false"
compile_only="false"
for_test_use="false"

while [ "$#" -gt 0 ]; do
	key="$1"
	case "$key" in
		--once)
			write_once="true"
			shift
		;;
		--compile)
			compile_only="true"
			shift
		;;
		__TEST__)
			for_test_use="true"
			shift
		;;
		--)
			shift
			break
		;;
		--*)
			echo "Unknown option: $1" >&2
			exit 1
		;;
		*)
			break
	esac
done

while [ "$#" -gt 0 ]; do
	target_devices+=( "$1" )
	shift
done

if [ "$for_test_use" = "true" ]; then
	return 2>/dev/null || exit
fi

compile_ipxe
verify_ipxe_files
ret=$?
if [ "$ret" -ne 0 ]; then
	echo "iPxe compile error: $ERROR"
	exit $ret
fi

if [ "$compile_only" = "true" ]; then
	exit 0
fi

pre_req_add_tool=( )
if [ "$write_once" = "false" ]; then
	pre_req_add_tool+=( "inotifywait" )
fi

pre_req "${pre_req_add_tool[@]}"
if [ "${#target_devices[@]}" -eq 0 ]; then
	echo "Device must be specified"
	exit 1
fi
if [ "$write_once" = "true" ]; then
	for dsk in "${target_devices[@]}"; do
		if [ -b "$dsk" ]; then
			echo "Writing $dsk"
			work_on_disk "$dsk" > >(prepend "$dsk: ") 2>&1
			if [ $? -eq 0 ]; then
				echo "$dsk: ok"
			else
				echo "$dsk: failed because $ERROR"
			fi
		else
			echo "$dsk is not a block device"
		fi
	done
	exit 0
fi

declare -r ESC="$(echo -ne "\x1b")"
declare -r SAVE_CUR="${ESC}7"
declare -r RESTORE_CUR="${ESC}8"
declare -r COLOR_IDLE="${ESC}[32m"
declare -r COLOR_BUSY="${ESC}[33m"
declare -r COLOR_ERROR="${ESC}[31m"
declare -r COLOR_RST="${ESC}[0m"
declare -r AUTO_WRAP="${ESC}[?7h"
declare -r NO_WRAP="${ESC}[?7l"
declare -r CLEAR_RIGHT="${ESC}[0K"

declare -r DEV_BY_PATH="/dev/disk/by-path"

scroll_area_set () {
  lines="$(($1 + 1))"
  echo -n "${SAVE_CUR}${ESC}[${lines};r${RESTORE_CUR}"
}

scroll_area_restore () {
  echo -n "${SAVE_CUR}${ESC}[;r${RESTORE_CUR}"
}

commit_work_on_disk () {
	local line="$1"
	local status
	local color
	local error
	shift
	local dev="$1"
	(
		echo -n "${SAVE_CUR}${ESC}[$((line));1f${NO_WRAP}${COLOR_BUSY}●${COLOR_RST} ${dev}${CLEAR_RIGHT}${AUTO_WRAP}${RESTORE_CUR}"

		if [ -b "$dev" ]; then
			work_on_disk "$dev" > >(prepend "$dev: " >&3) 2>&1
		fi
		status="$?"
		color="${COLOR_IDLE}"
		error=""
		if [ "$status" -ne 0 ]; then
			color="${COLOR_ERROR}"
			error=": ${COLOR_ERROR}$(echo "$ERROR" | tr -d '\n\r')${COLOR_RST}"
		fi

		local sysfs_path="/sys/$(udevadm info --query=path --name="$dev")"
		if [ -w "${sysfs_path}/device/delete" ]; then
		  echo 1 > "${sysfs_path}/device/delete"
		  echo "$dev: Ejected" >&3
		fi

		echo -n "${SAVE_CUR}${ESC}[$((line));1f${NO_WRAP}${color}●${COLOR_RST} ${dev}${error}${CLEAR_RIGHT}${AUTO_WRAP}${RESTORE_CUR}"
	)&
}

onexit () {
	if [ "$inotify_PID" ]; then
		kill -INT "$inotify_PID"
		inotify_PID=
	fi
	wait -f
	scroll_area_restore
	exit 0
}

declare -A disks
counter=1
for dsk in "${target_devices[@]}"; do
	if [[ "$dsk" == *"/"* ]]; then
		if [ "$(realpath --no-symlinks $(dirname "$dsk"))" != "$DEV_BY_PATH" ]; then
			echo "$dsk: ignored because it is not in $DEV_BY_PATH"
			continue
		fi
		dsk="$(basename "$dsk")"
	fi
	disks["$dsk"]=$counter
	counter=$((counter + 1))
done
unset counter

scroll_area_set "${#disks[@]}"
trap onexit EXIT INT

coproc inotify {
	for dsk in "${!disks[@]}"; do
		echo "$dsk"
	done
	exec inotifywait --monitor --event create --format "%f" "$DEV_BY_PATH"
}

exec {inotify[1]}<&-
while read file; do
	if [ -z "$file" ]; then
		continue
	fi
	if [ "${disks["${file}"]+_}" ]; then
		commit_work_on_disk "${disks["${file}"]}" "${DEV_BY_PATH}/${file}"
	fi
done <&"${inotify[0]}" 3> >(tee --append flasher.log)
