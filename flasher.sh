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
	
	mformat -i "$dev"@@"$(( 512 * EFI_START ))" -T "$(EFI_SIZE)" -F "::" && \
	  mmd   -i "$dev"@@"$(( 512 * EFI_START ))" "::efi" && \
	  mmd   -i "$dev"@@"$(( 512 * EFI_START ))" "::efi/boot" && \
	  mcopy -i "$dev"@@"$(( 512 * EFI_START ))" "${IPXE_EFI}" "::efi/boot/bootx64.efi"
	
	if [ "$?" -ne 0 ]; then
		ERROR="Cannot write EFI boot data"
		return 1
	fi
	
	return 0
}

target_device=""
write_once="false"
compile_only="false"
for_test_use="false"
interactive="true"

while [ "$#" -gt 0 ]]; do
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
		*)
			target_device="$1"
			break
	esac
done

if [ "$for_test_use" = "true" ]; then
	return 2>/dev/null || exit
fi

if [ "$compile_only" = "true" -o "$write_once" = "true" ]; then
	interactive="false"
fi

if [ ! -t 0 ]; then
	interactive="false"
fi


