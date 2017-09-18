#!/bin/bash

# Copyright 2017 Linaro Limited
#
# SPDX-License-Identifier: GPL-2.0

PROGNAME=$(basename $0)

set -e		# Accept no failure

# "Sizes" are all in sectors.  Otherwise we call it "bytes".
SECTOR_BYTES=512
EMMC_SIZE=15269888	# 7456 MB in sectors (not hex)

CHUNK_SIZE=524288	# Partition image chuck size in sectors (not hex)
IN_ADDR=0x08000000	# Buffer address for compressed data in from USB (hex)
OUT_ADDR=0x10000000	# Buffer address for uncompressed data for MMC (hex)
SUB_ADDR=0x07800000	# Buffer address for sub-installer scripts
EMMC_IO_BYTES=0x100000	# EMMC write buffer size in bytes (hex)

EMMC_DEV=/dev/mmcblk0	# Linux path to main eMMC device on target

# Recommended alignment (in sectors) for partitions other than 1 and 4
PART_ALIGNMENT=2048	# Align at 1MB (512-byte sectors)

# Input files
# The "l-loader.bin" boot loader package (for eMMC)
L_LOADER=l-loader.bin
# In case the USB boot loader is different from what we want on eMMC
USB_LOADER=${L_LOADER}	# Must be full l-loader.bin (including first sector)
KERNEL_IMAGE=Image
DEVICE_TREE_BINARY=hi3798cv200-poplar.dtb
# Initial ramdisk is optional; don't define it if it's not set
# INIT_RAMDISK=initrd.img		# a cpio.gz file
############
ANDROID_BOOT_IMAGE=boot.img
ANDROID_SYSTEM_IMAGE=system.img
ANDROID_CACHE_IMAGE=cache.img
ANDROID_USER_DATA_IMAGE=userdata.img

# Temporary output files
IMAGE=disk_image	# disk image file

# Directory in which copies of output files are created
RECOVERY=recovery_files
# recovery content
LOADER=loader.bin	# in /boot on target; omits 1st sector of l-loader.bin
INSTALL_SCRIPT=install	# for U-boot to run on the target


TEMPFILE=$(mktemp -p .)

###############

function usage() {
	echo >&2
	echo "${PROGNAME}: $@" >&2
	echo >&2
	echo "Usage: ${PROGNAME}>" >&2
	echo >&2
	exit 1
}

function parseargs() {
	# Make sure no arguments were supplied
	[ $# -ne 0 ] && usage "arguments supplied (none required)"

	INPUT_FILES="L_LOADER USB_LOADER"
	INPUT_FILES="${INPUT_FILES} ANDROID_BOOT_IMAGE"
	INPUT_FILES="${INPUT_FILES} ANDROID_SYSTEM_IMAGE"
	INPUT_FILES="${INPUT_FILES} ANDROID_CACHE_IMAGE"
	INPUT_FILES="${INPUT_FILES} ANDROID_USER_DATA_IMAGE"
}

function suser() {
	echo
	echo To continue, superuser credentials are required.
	sudo -k || nope "failed to kill superuser privilege"
	sudo -v || nope "failed to get superuser privilege"
	SUSER=yes
}

function cleanup() {
	[ "${LOOP_ATTACHED}" ] && loop_detach
	rm -f ${LOADER}
	rm -f ${IMAGE}
	rm -f ${TEMPFILE}
}

function nope() {
	if [ $# -gt 0 ]; then
		echo "" >&2
		echo "${PROGNAME}: $@" >&2
		echo "" >&2
	fi
	echo === Poplar recovery image builder ended early ===
	exit 1
}

function howmany() {
	local total_size=$1
	local unit_size=$2

	[ ${unit_size} -gt 0 ] || nope "bad unit_size ${unit_size} in howmany()"
	expr \( ${total_size} + ${unit_size} - 1 \) / ${unit_size}
}

function file_bytes() {
	local filename=$1

	stat --dereference --format="%s" ${filename} ||
	nope "unable to stat \"${filename}\""
}

# Make sure we have all our input files, and don't clobber anything
function file_validate() {
	local file

	# Don't kill anything that already exists.  Tell the user
	# that they must be removed instead.
	for i in RECOVERY LOADER IMAGE; do
		file=$(eval echo \${$i})
		[ -e ${file} ] &&
		nope "$i file \"$file\" exists it must be removed to continue"
	done

	# Make sure all the input files we need *do* exist and are readable
	for i in ${INPUT_FILES} ; do
		file=$(eval echo \${$i})
		[ -f ${file} ] || nope "$i file \"$file\" does not exist"
		[ -r ${file} ] || nope "$i \"$file\" is not readable"
		[ -s ${file} ] || nope "$i \"$file\" is empty"
	done
	[ $(file_bytes ${L_LOADER}) -gt ${SECTOR_BYTES} ] ||
	nope "l_loader is much too small"
}

# We use the partition types accepted in /etc/fstab for Linux.
# If valid, the value to use for "parted" is echoed.  Otherwise
# we exit with an error.
function fstype_parted() {
	local fstype=$1

	case ${fstype} in
	vfat)		echo fat32 ;;
	ext4|xfs)	echo ${fstype} ;;
	none)		echo "" ;;
	*)		nope "invalid fstype \"${fstype}\"" ;;
	esac
}

function loop_init() {
	LOOP=$(sudo losetup -f) || nope "unable to find a loop device"
}

function loop_attach() {
	local offset=$1
	local size=$2
	local file=$3

	# Convert to bytes; that's the unit "losetup" wants.  Check
	# for 0 here to avoid non-zero exit status for "expr".
	[ ${offset} -ne 0 ] && offset=$(expr ${offset} \* ${SECTOR_BYTES})
	[ ${size} -gt 0 ] || nope "loop device size must be non-zero"
	size=$(expr ${size} \* ${SECTOR_BYTES})
	sudo losetup ${LOOP} ${file} --offset=${offset} --sizelimit=${size} ||
	nope "unable to set up loop device ${LOOP} on image file ${file}"
	LOOP_ATTACHED=yes
}

function loop_detach() {
	sudo losetup -d ${LOOP} || nope "failed to detach ${LOOP}"
	sudo rm -f ${LOOP}p?    # Linux doesn't remove partitions we created
	unset LOOP_ATTACHED
}

# Certain partitions are special, and for those we record their number
function map_description() {
	local part_number=$1
	local description=$2

	case ${description} in
	/)			PART_ROOT=${part_number} ;;
	/boot)			PART_BOOT=${part_number} ;;
	android_boot)		PART_ANDROID_BOOT=${part_number} ;;
	android_system)		PART_ANDROID_SYSTEM=${part_number} ;;
	android_cache)		PART_ANDROID_CACHE=${part_number} ;;
	android_user_data)	PART_ANDROID_USER_DATA=${part_number} ;;
	*)			;;	# We don't care about any others
	esac;
}

function partition_init() {
	PART_COUNT=0	# Total number of partitions, including extended
	DISK_OFFSET=0	# Next available offset on the disk
}

function partition_define() {
	local part_size=$1
	local part_fstype=$2
	local description=$3
	local part_offset=${DISK_OFFSET}	# might change, below
	local part_number=$(expr ${PART_COUNT} + 1)
	local need_boot_record	# By default, no
	local remaining

	[ ${part_size} -ne 0 ] || nope "partition size must be non-zero"

	[ ${EMMC_SIZE} -gt ${DISK_OFFSET} ] || nope "disk space exhausted"

	remaining=$(expr ${EMMC_SIZE} - ${DISK_OFFSET})

	# The first partition is preceded by a 1-sector MBR.  The fourth
	# partition is extended (and accounted for silently below).  All
	# others are preceded by a 1-sector EBR.  In other words, all
	# partitions but 2 and 3 require a sector to hold a boot record.
	if [ ${part_number} -ne 2 -a ${part_number} -ne 3 ]; then
		[ ${remaining} -gt 1 ] || nope "disk space exhausted (extended)"
		remaining=$(expr ${remaining} - 1)
		need_boot_record=yes
	fi
	# A non-positive size (-1) means use the rest of the disk
	if [ ${part_size} -le 0 ]; then
		part_size=${remaining}
	fi
	[ ${part_size} -gt ${remaining} ] &&
	nope "partition too large (${part_size} > ${remaining})"

	# At this point we assume the partition is OK.  Set the
	# partition type, and leave room for a boot record if needed
	if [ ${part_number} -lt 4 ]; then
		PART_TYPE[${part_number}]=primary
	else
		if [ ${part_number} -eq 4 ]; then
			# Fourth partition is extended.  Silently
			# define it to fill what's left of the disk,
			# and then bump the partition number.
			PART_OFFSET[4]=${part_offset}
			PART_SIZE[4]=$(expr ${EMMC_SIZE} - ${part_offset})
			PART_TYPE[4]=extended
			PART_FSTYPE[4]=none

			part_number=5;
		fi
		# The rest are logical partitions, preceded by an EBR
		PART_TYPE[${part_number}]=logical
	fi

	# Reserve space for the MBR or EBR if necessary
	[ "${need_boot_record}" ] && part_offset=$(expr ${part_offset} + 1)

	# Record the partition's offset and size (and final sector)
	PART_OFFSET[${part_number}]=${part_offset}
	PART_SIZE[${part_number}]=${part_size}
	PART_FSTYPE[${part_number}]=${part_fstype}
	DESCRIPTION[${part_number}]=${description}
	map_description ${part_number} ${description}

	# Consume the partition on the disk
	DISK_OFFSET=$(expr ${part_offset} + ${part_size})
	PART_COUNT=${part_number}
}

function partition_check_alignment() {
	local part_number=$1
	local offset=${PART_OFFSET[${part_number}]}
	local prev_number
	local excess
	local recommended

	# We expect partition 1 to start at unaligned offset 1, and extended
	# partition 4 to be one less than an aligned offset so its first
	# logical partition is aligned.
	[ ${part_number} -eq 1 -o ${part_number} -eq 4 ] && return

	# If the partition is aligned we're fine; use "expr" status
	if ! expr ${offset} % ${PART_ALIGNMENT} > /dev/null; then
		return;
	fi

	# Report a warning, and make it helpful.
	prev_number=$(expr ${part_number} - 1)
	[ ${part_number} -eq 5 ] && prev_number=3
	excess=$(expr ${offset} % ${PART_ALIGNMENT})
	recommended=$(expr ${PART_SIZE[${prev_number}]} - ${excess})
	echo Warning: partition ${part_number} is not well aligned.
	echo -n "  Recommend changing partition ${prev_number} size "
	echo to ${recommended} or $(expr ${recommended} + ${PART_ALIGNMENT})
}

# Only one thing to validate right now.  The loader file (without MBR)
# must fit in the first partition.  Warn for non-aligned partitions.
function partition_validate() {
	local loader_bytes=$(expr $(file_bytes ${L_LOADER}) - ${SECTOR_BYTES})
	local loader_part_bytes=$(expr ${PART_SIZE[1]} \* ${SECTOR_BYTES});
	local i

	[ ${loader_bytes} -le ${loader_part_bytes} ] ||
	nope "loader is too big for partition 1" \
		"(${loader_bytes} > ${loader_part_bytes} bytes)"
	for i in $(seq 1 ${PART_COUNT}); do
		partition_check_alignment $i
	done
	# Warn if there's some unused space on the disk; use "expr" status
	if expr ${EMMC_SIZE} - ${DISK_OFFSET} > /dev/null; then
		echo Warning: unused sectors on disk.
		echo -n "  Recommend increasing partition ${PART_COUNT} size "
		echo "to $(expr ${EMMC_SIZE} - ${PART_OFFSET[${PART_COUNT}]})"
		echo
	fi
}

function partition_show() {
	local i
	local ebr_offset

	echo === Using the following disk layout ===
	echo

	printf "# %8s %8s %8s %7s %s\n" Start Size Type "FS Type" "Description"
	# The "\055" is just a (leading) dash character (-)
	printf "\055 %8s %8s %8s %7s %s\n" ----- ---- ---- ------- -----------
	printf "* %8u %8u %8s\n" 0 1 MBR
	for i in $(seq 1 ${PART_COUNT}); do
		if [ $i -gt 4 ]; then
			ebr_offset=$(expr ${PART_OFFSET[$i]} - 1)
			printf "* %8u %8u %8s\n" ${ebr_offset} 1 EBR
		fi
		printf "%1u %8u %8u %8s" $i \
			${PART_OFFSET[$i]} ${PART_SIZE[$i]} ${PART_TYPE[$i]}
		# No FS type or description for the extended partition
		[ $i -ne 4 ] &&
			printf " %7s %s" ${PART_FSTYPE[$i]} ${DESCRIPTION[$i]}
		echo
	done
	echo "Total EMMC size is ${EMMC_SIZE} ${SECTOR_BYTES}-byte sectors"
}

# Ask the user to verify whether to continue, for safety
function disk_init() {
	echo
	echo "NOTE: ${LOOP} (backed by image file \"${IMAGE}\") will be"
	echo "      partitioned (i.e., OVERWRITTEN)!"
	echo
	echo "ARE YOU SURE YOU WANT TO OVERWRITE \"${LOOP}\"?"
	echo
	echo -n "Please type \"yes\" to proceed: "
	read -i no x
	[ "${x}" = "yes" ] || nope "aborted by user"
	echo
}

function disk_partition() {
	local i
	local end
	local fstype

	echo === creating partitioned disk image ===

	# Create an empty image file the same size as our target eMMC
	rm -f ${IMAGE} || echo "unable to remove image file \"${IMAGE}\""
	truncate -s $(expr ${EMMC_SIZE} \* ${SECTOR_BYTES}) ${IMAGE} ||
	nope "unable to create empty image file \"${IMAGE}\""
	loop_attach 0 ${EMMC_SIZE} ${IMAGE}

	# Partition our disk image.
	# Note: Do *not* use --script to "parted"; it caused problems...
	{								\
		echo mklabel msdos;					\
		echo unit s;						\
		for i in $(seq 1 ${PART_COUNT}); do			\
			end=$(expr ${PART_OFFSET[$i]} + ${PART_SIZE[$i]} - 1); \
			fstype=$(fstype_parted ${PART_FSTYPE[$i]});	\
			echo -n "mkpart ${PART_TYPE[$i]} ${fstype} ";	\
			echo		"${PART_OFFSET[$i]} ${end}";	\
		done;							\
		[ "${PART_BOOT}" ] && echo "set ${PART_BOOT} boot on";	\
		echo quit;						\
	} | sudo parted ${LOOP} || nope "failed to partition image"
}

function disk_finish() {
	loop_detach
}

# Create the loader file.  It is always in partition 1.
#
# The first sector of l-loader.bin is removed in the loader "loader.bin"
# we maintain.  The boot ROM ignores the first sector, but the "l-loader.bin"
# must be built to contain space for it.  We create "loader.bin" by dropping
# that first sector.  That way "loader.bin" can be written directly into the
# first partition without disturbing the MBR.  We have already verified
# "l-loader" isn't too large for the first partition; it's OK if it's smaller.
function loader_create() {
	dd status=none if=${L_LOADER} of=${LOADER} \
		bs=${SECTOR_BYTES} skip=1 count=${PART_SIZE[1]} ||
	nope "failed to create loader"
}

# Populate a partition using "raw" data from a file
function populate_image() {
	local part_number=$1
	local source_image=$2

	cp ${source_image} ${RECOVERY}/partition${part_number} ||
	nope "unable to copy partition ${part_number} to ${RECOVERY}"
}

# Populate a partition using an Android sparse file system image
function populate_simage() {
	local part_number=$1
	local source_image=$2

	simg2img ${source_image} ${RECOVERY}/partition${part_number} ||
	nope "unable to expand ${source_image}"
}

# Fill the loader partition.  Always partition 1.
function populate_loader() {
	local part_number=1	# Not dollar-1, just 1

	# Just image copy the loader file we already created.
	echo "- loader"
	populate_image ${part_number} ${LOADER}
}

function populate_android_boot() {
	local part_number=$1

	echo "- Android boot"
	populate_image ${part_number} ${ANDROID_BOOT_IMAGE}
}

function populate_android_system() {
	local part_number=$1

	echo "- Android system"
	populate_simage ${part_number} ${ANDROID_SYSTEM_IMAGE}
}

function populate_android_cache() {
	local part_number=$1

	echo "- Android cache"
	populate_simage ${part_number} ${ANDROID_CACHE_IMAGE}
}

function populate_android_user_data() {
	local part_number=$1

	echo "- Android user data"
	populate_simage ${part_number} ${ANDROID_USER_DATA_IMAGE}
}

function installer_update() {
	echo "$@" >> ${CURRENT_SCRIPT}
}

function installer_compile() {
	local description="$@"

	sudo mkimage -T script -A arm64 -C none -n "${description}" \
		-d ${CURRENT_SCRIPT} ${CURRENT_SCRIPT}.scr ||
	nope "failed to compile image for \"${CURRENT_SCRIPT}\""
}

function installer_init() {
	echo
	echo === generating installation files ===

	CURRENT_SCRIPT=${RECOVERY}/${INSTALL_SCRIPT}
	cp /dev/null ${CURRENT_SCRIPT}

	installer_update "# Poplar recovery script"
	installer_update "# Created $(date)"
	installer_update ""
}

function installer_init_sub_script() {
	local sub_script="${INSTALL_SCRIPT}-$1"; shift
	local description="$@"

	# Add commands to the top-level script to source the one we
	# will be created.  It will be compiled into a binary file
	# with the extension ".scr" when we're done creating it
	installer_update "# ${description}"
	installer_update "tftp ${SUB_ADDR} ${RECOVERY}/${sub_script}.scr"
	installer_update "source ${SUB_ADDR}"
	installer_update ""

	# Switch to the sub-script file and give it a short header
	CURRENT_SCRIPT=${RECOVERY}/${sub_script}
	cp /dev/null ${CURRENT_SCRIPT}

	installer_update "# ${description}"
	installer_update ""
}

function installer_add_file() {
	local filename=$1;
	local offset=$(printf "0x%08x" $2)
	local filepath=${RECOVERY}/${filename};
	local bytes=$(file_bytes ${filepath});
	local hex_bytes=$(printf "0x%08x" ${bytes})
	local size=$(howmany ${bytes} ${SECTOR_BYTES})
	local hex_size=$(printf "0x%08x" ${size})

	gzip ${filepath}

	installer_update "tftp ${IN_ADDR} ${RECOVERY}/${filename}.gz"
	installer_update "unzip ${IN_ADDR} ${OUT_ADDR} ${hex_bytes}"
	installer_update "mmc write ${OUT_ADDR} ${offset} ${hex_size}"
	installer_update "echo"
	installer_update ""
}

function installer_finish_sub_script() {
	# Compile the sub-script into <filename>.scr, then switch
	# back to the top-level sript.
	installer_compile $(basename ${CURRENT_SCRIPT})

	CURRENT_SCRIPT=${RECOVERY}/${INSTALL_SCRIPT}
}

function installer_finish() {
	installer_update "echo ============ INSTALLATION IS DONE ============="
	installer_update "echo (Please reset your board)"

	echo
	echo === building installer ===
	installer_compile "Poplar Recovery"

	unset CURRENT_SCRIPT
}

function save_boot_record() {
	local filename=$1;
	local filepath=${RECOVERY}/${filename};
	local offset=$2;	# sectors

	# These sectors seem to be OK
	dd status=none if=${IMAGE} of=${filepath} bs=${SECTOR_BYTES} \
			skip=${offset} count=1

	installer_add_file ${filename} ${offset}
}

function save_layout() {
	local i

	installer_init_sub_script layout "Partition layout (MBR and EBRs)"

	save_boot_record mbr.bin 0
	# Partitions 5 and above require an Extended Boot Record
	for i in $(seq 5 ${PART_COUNT}); do
		save_boot_record ebr$i.bin $(expr ${PART_OFFSET[$i]} - 1)
	done

	installer_finish_sub_script
}

# Split up partition into chunks; the last may be short.  We do this
# because we must be able to fit an entire file in memory, and we
# plan here for the worst case (though it's unlikely because we
# compress the chunks).
function save_partition() {
	local part_number=$1;
	local part_name="partition${part_number}";
	local offset=${PART_OFFSET[${part_number}]}
	local coffset=0
	local size=${PART_SIZE[${part_number}]}
	local chunk_size=${CHUNK_SIZE}
	local count=1;
	local limit=$(howmany ${size} ${chunk_size})
	local desc="Partition ${part_number} (${DESCRIPTION[${part_number}]})"

	installer_init_sub_script ${part_name} "${desc}"

	while true; do
		local filename=${part_name}.${count}-of-${limit};
		local filepath=${RECOVERY}/${filename}

		if [ ${size} -lt ${chunk_size} ]; then
			chunk_size=${size}
		fi
		echo "- ${filename} (${chunk_size} sectors)"
		dd status=none if=${IMAGE} of=${filepath} bs=${SECTOR_BYTES} \
				skip=${offset} count=${chunk_size}

		dd status=none if=${RECOVERY}/partition${part_number} \
			of=${RECOVERY}/${filename} bs=${SECTOR_BYTES} \
			skip=${coffset} count=${chunk_size} ||
		nope "unable to copy ${filename} ${RECOVERY}"

		installer_add_file ${filename} ${offset}

		count=$(expr ${count} + 1)
		offset=$(expr ${offset} + ${chunk_size})
		coffset=$(expr ${coffset} + ${chunk_size})
		# Exit loop when it's all written; use "expr" exit status
		size=$(expr ${size} - ${chunk_size}) || break
	done

	# Done with the original image; remove it
	rm ${RECOVERY}/partition${part_number}

	installer_finish_sub_script
}

############################

# Clean up in case we're killed or interrupted in a fairly normal way
trap cleanup EXIT ERR SIGHUP SIGINT SIGQUIT SIGTERM

parseargs "$@"

echo
echo ====== Poplar recovery image builder ======
echo

file_validate

partition_init

partition_define 8191     none loader
partition_define 81920    none android_boot
partition_define 2097151  ext4 android_system
partition_define 2097151  ext4 android_cache
partition_define 10985472 ext4 android_user_data

partition_validate

partition_show

# To go any further we need superuser privilege
suser

loop_init

disk_init
disk_partition
disk_finish

echo === populating loader partition and file systems in image ===

mkdir -p ${RECOVERY} || nope "unable to create copy directory \"${RECOVERY}\""

# Create the loader file and save it to its partition
loader_create
populate_loader

# Now populate the rest of the paritions
[ "${PART_ANDROID_BOOT}" ] &&
	populate_android_boot ${PART_ANDROID_BOOT}
[ "${PART_ANDROID_SYSTEM}" ] &&
	populate_android_system ${PART_ANDROID_SYSTEM}
[ "${PART_ANDROID_CACHE}" ] &&
	populate_android_cache ${PART_ANDROID_CACHE}
[ "${PART_ANDROID_USER_DATA}" ] &&
	populate_android_user_data ${PART_ANDROID_USER_DATA}

# Initialize the installer script
installer_init

# First, we need "fastboot.bin" to make a bootable USB stick
cp ${USB_LOADER} ${RECOVERY}/fastboot.bin

# Start with the partitioning metadata--MBR and all EBRs
save_layout

# Now save off our partition into files used for installation.
for i in $(seq 1 ${PART_COUNT}); do
	# Partition 4 is extended, and is comprised of logical partitions
	[ $i -ne 4 ] && save_partition $i
done

installer_finish

echo ====== Poplar recovery image builder done! ======

exit 0
