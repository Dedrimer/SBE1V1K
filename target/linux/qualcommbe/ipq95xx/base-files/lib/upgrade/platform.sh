PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='fw_printenv fw_setenv head'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'

SBE1V1K_SYS_BLOCK="${SBE1V1K_SYS_BLOCK:-/sys/block}"
SBE1V1K_SYS_CLASS_BLOCK="${SBE1V1K_SYS_CLASS_BLOCK:-/sys/class/block}"
SBE1V1K_DEV_ROOT="${SBE1V1K_DEV_ROOT:-/dev}"

sbe1v1k_validate_sysupgrade_tar() {
	local archive="$1"
	local archive_list board_dir board_dirs control gz=""

	[ "$(identify_magic_long "$(get_magic_long "$archive" cat)")" = "gzip" ] && gz="z"
	archive_list="$(tar t${gz}f "$archive" 2>/dev/null)" || {
		echo "The sysupgrade image is not a complete tar archive."
		return 1
	}

	board_dirs="$(printf '%s\n' "$archive_list" |
		sed -n 's#^\(sysupgrade-[^/]*/\)$#\1#p')"
	[ "$(printf '%s\n' "$board_dirs" | sed '/^$/d' | wc -l)" -eq 1 ] || {
		echo "The sysupgrade image must contain exactly one board directory."
		return 1
	}
	board_dir="$board_dirs"
	board_dir="${board_dir%/}"

	for member in CONTROL kernel root; do
		[ "$(printf '%s\n' "$archive_list" |
			grep -Fxc "$board_dir/$member")" -eq 1 ] || {
			echo "The sysupgrade image is missing $member."
			return 1
		}
	done

	control="$(tar x${gz}f "$archive" "$board_dir/CONTROL" -O 2>/dev/null)" || return 1
	[ "$control" = "BOARD=askey_sbe1v1k" ] || {
		echo "The sysupgrade image has an unexpected board identifier."
		return 1
	}

	SBE1V1K_BOARD_DIR="$board_dir"
	SBE1V1K_TAR_GZ="$gz"
}

sbe1v1k_mmc_rootdev() {
	local name="${1##*/}"

	case "$name" in
	mmcblk*p[0-9]*) echo "${name%p[0-9]*}" ;;
	*) return 1 ;;
	esac
}

sbe1v1k_find_mmc_part() {
	local label="$1"
	local rootdev="${2:-mmcblk*}"
	local devname found="" partname

	for devname in $SBE1V1K_SYS_BLOCK/$rootdev/mmcblk*p*; do
		[ -f "$devname/uevent" ] || continue
		partname="$(sed -n 's/^PARTNAME=//p' "$devname/uevent")"
		[ "$partname" = "$label" ] || continue
		[ -z "$found" ] || {
			echo "Duplicate eMMC partition label $label." >&2
			return 2
		}
		found="$SBE1V1K_DEV_ROOT/${devname##*/}"
	done

	[ -n "$found" ] || return 1
	echo "$found"
}

sbe1v1k_is_block_device() {
	[ -b "$1" ]
}

sbe1v1k_validate_partition() {
	local dev="$1"
	local expected_start="$2"
	local expected_size="$3"
	local minimum_size="${4:-$expected_size}"
	local name="${dev##*/}"
	local start size

	sbe1v1k_is_block_device "$dev" || {
		echo "Required eMMC partition $dev is not a block device."
		return 1
	}
	read -r start < "$SBE1V1K_SYS_CLASS_BLOCK/$name/start" || return 1
	read -r size < "$SBE1V1K_SYS_CLASS_BLOCK/$name/size" || return 1
	[ "$start" = "$expected_start" ] || {
		echo "Partition $dev starts at LBA $start, expected $expected_start."
		return 1
	}
	[ "$size" -ge "$minimum_size" ] || {
		echo "Partition $dev has $size sectors, expected at least $minimum_size."
		return 1
	}
	[ -z "$expected_size" ] || [ "$size" = "$expected_size" ] || {
		echo "Partition $dev has $size sectors, expected $expected_size."
		return 1
	}
}

sbe1v1k_tar_member_sectors() {
	local archive="$1"
	local member="$2"
	local bytes gz="" rc

	[ "$(identify_magic_long "$(get_magic_long "$archive" cat)")" = "gzip" ] && gz="z"
	set -o pipefail
	bytes="$(tar x${gz}f "$archive" "$member" -O 2>/dev/null | wc -c)"
	rc=$?
	set +o pipefail
	[ "$rc" -eq 0 ] && [ "$bytes" -gt 0 ] || return 1

	SBE1V1K_MEMBER_SECTORS=$(((bytes + 511) / 512))
}

sbe1v1k_validate_payload_sizes() {
	local archive="$1" kernel_capacity root_capacity
	local kernel_name="${EMMC_KERN_DEV##*/}"
	local root_name="${EMMC_ROOT_DEV##*/}"

	read -r kernel_capacity < "$SBE1V1K_SYS_CLASS_BLOCK/$kernel_name/size" || return 1
	read -r root_capacity < "$SBE1V1K_SYS_CLASS_BLOCK/$root_name/size" || return 1

	sbe1v1k_tar_member_sectors "$archive" "$SBE1V1K_BOARD_DIR/kernel" || return 1
	[ "$SBE1V1K_MEMBER_SECTORS" -le "$kernel_capacity" ] || {
		echo "Kernel payload exceeds the $SBE1V1K_LAYOUT kernel partition."
		return 1
	}
	sbe1v1k_tar_member_sectors "$archive" "$SBE1V1K_BOARD_DIR/root" || return 1
	[ "$SBE1V1K_MEMBER_SECTORS" -le "$root_capacity" ] || {
		echo "Rootfs payload exceeds the $SBE1V1K_LAYOUT rootfs partition."
		return 1
	}
}

sbe1v1k_prepare_layout() {
	local archive="$1"
	local chainloader_dev hlos1_dev hlos_dev kernel_dev rootdev

	unset EMMC_KERN_DEV EMMC_ROOT_DEV EMMC_DATA_DEV CI_ROOTDEV

	# LBAs match YYH2913/http-uboot's SBE1V1K layout descriptors. The large
	# layout is preferred when both legacy HLOS and the dedicated kernel
	# partition are present.
	if kernel_dev="$(sbe1v1k_find_mmc_part kernel)"; then
		SBE1V1K_LAYOUT="large"
		CI_KERNPART="kernel"
		rootdev="$(sbe1v1k_mmc_rootdev "$kernel_dev")" || return 1
		CI_ROOTDEV="$rootdev"
		EMMC_KERN_DEV="$kernel_dev"
		hlos_dev="$(sbe1v1k_find_mmc_part '0:HLOS' "$rootdev")"
		chainloader_dev="$(sbe1v1k_find_mmc_part chainloader "$rootdev")"
		EMMC_ROOT_DEV="$(sbe1v1k_find_mmc_part rootfs "$rootdev")"
		EMMC_DATA_DEV="$(sbe1v1k_find_mmc_part rootfs_data "$rootdev")"
		[ -n "$hlos_dev" ] && [ -n "$chainloader_dev" ] &&
			[ -n "$EMMC_ROOT_DEV" ] && [ -n "$EMMC_DATA_DEV" ] || {
			echo "The SBE1V1K large eMMC layout is incomplete."
			return 1
		}
		sbe1v1k_validate_partition "$hlos_dev" 81954 14336 || return 1
		sbe1v1k_validate_partition "$chainloader_dev" 110626 8192 || return 1
		sbe1v1k_validate_partition "$EMMC_KERN_DEV" 118818 65536 || return 1
		sbe1v1k_validate_partition "$EMMC_ROOT_DEV" 184354 2097152 || return 1
		sbe1v1k_validate_partition "$EMMC_DATA_DEV" 2281506 "" 1048576 || return 1
	else
		[ "$?" -eq 1 ] || return 1
		SBE1V1K_LAYOUT="mainline"
		CI_KERNPART="0:HLOS"
		kernel_dev="$(sbe1v1k_find_mmc_part "0:HLOS")"
		[ -n "$kernel_dev" ] || {
			echo "Neither the large kernel partition nor mainline 0:HLOS was found."
			return 1
		}
		rootdev="$(sbe1v1k_mmc_rootdev "$kernel_dev")" || return 1
		CI_ROOTDEV="$rootdev"
		EMMC_KERN_DEV="$kernel_dev"
		hlos1_dev="$(sbe1v1k_find_mmc_part '0:HLOS_1' "$rootdev")"
		chainloader_dev="$(sbe1v1k_find_mmc_part rsvd_2 "$rootdev")"
		EMMC_ROOT_DEV="$(sbe1v1k_find_mmc_part rootfs "$rootdev")"
		EMMC_DATA_DEV="$(sbe1v1k_find_mmc_part rootfs_data "$rootdev")"
		[ -n "$hlos1_dev" ] && [ -n "$chainloader_dev" ] &&
			[ -n "$EMMC_ROOT_DEV" ] && [ -n "$EMMC_DATA_DEV" ] || {
			echo "The SBE1V1K mainline eMMC layout is incomplete."
			return 1
		}
		sbe1v1k_validate_partition "$EMMC_KERN_DEV" 81954 14336 || return 1
		sbe1v1k_validate_partition "$hlos1_dev" 96290 14336 || return 1
		sbe1v1k_validate_partition "$EMMC_ROOT_DEV" 110626 249856 || return 1
		sbe1v1k_validate_partition "$EMMC_DATA_DEV" 610338 1048576 || return 1
		sbe1v1k_validate_partition "$chainloader_dev" 5201954 65536 || return 1
		[ "$EMMC_ROOT_DEV" = "$SBE1V1K_DEV_ROOT/${rootdev}p27" ] || {
			echo "The mainline rootfs partition is not ${rootdev}p27."
			return 1
		}
		echo "Using the declared but not hardware-validated SBE1V1K mainline layout."
	fi

	CI_ROOTPART="rootfs"
	CI_DATAPART="rootfs_data"
	export SBE1V1K_LAYOUT CI_KERNPART CI_ROOTPART CI_DATAPART CI_ROOTDEV
	export EMMC_KERN_DEV EMMC_ROOT_DEV EMMC_DATA_DEV
	sbe1v1k_validate_payload_sizes "$archive"
}

sbe1v1k_write_tar_member() {
	local archive="$1" member="$2" target="$3" rc

	sbe1v1k_is_block_device "$target" || return 1
	set -o pipefail
	tar x${SBE1V1K_TAR_GZ}f "$archive" "$member" -O 2>/dev/null |
		dd of="$target" bs=512 conv=notrunc
	rc=$?
	set +o pipefail
	return "$rc"
}

sbe1v1k_copy_config() {
	local backup_blocks capacity data_name="${EMMC_DATA_DEV##*/}"

	[ -f "$UPGRADE_BACKUP" ] || return 1
	[ "$(get_magic_word "$UPGRADE_BACKUP" cat)" = "1f8b" ] || return 1
	backup_blocks=$((($(wc -c < "$UPGRADE_BACKUP") + 511) / 512))
	[ "$backup_blocks" -gt 0 ] || return 1
	read -r capacity < "$SBE1V1K_SYS_CLASS_BLOCK/$data_name/size" || return 1
	[ "$backup_blocks" -le "$capacity" ] || {
		echo "The configuration backup does not fit in $EMMC_DATA_DEV."
		return 1
	}
	dd if="$UPGRADE_BACKUP" of="$EMMC_DATA_DEV" bs=512 conv=notrunc || return 1
	sync || return 1
	SBE1V1K_CONFIG_COPIED=1
}

sbe1v1k_do_upgrade() {
	local archive="$1"

	unset SBE1V1K_CONFIG_COPIED
	# Keep the kernel invalid until rootfs, rootfs_data and the backup are safe.
	dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 count=8 conv=notrunc || return 1
	sync || return 1
	sbe1v1k_write_tar_member "$archive" "$SBE1V1K_BOARD_DIR/root" \
		"$EMMC_ROOT_DEV" || return 1
	sync || return 1

	if [ -n "$UPGRADE_BACKUP" ]; then
		sbe1v1k_copy_config || return 1
	else
		dd if=/dev/zero of="$EMMC_DATA_DEV" bs=512 count=8 conv=notrunc || return 1
		sync || return 1
	fi

	sbe1v1k_write_tar_member "$archive" "$SBE1V1K_BOARD_DIR/kernel" \
		"$EMMC_KERN_DEV" || return 1
	sync
}

platform_check_image() {
	case "$(board_name)" in
	askey,sbe1v1k)
		[ "$(identify_magic_long "$(get_magic_long "$1")")" = "fit" ] && {
			echo "The recovery image can only be written from U-Boot HTTP recovery."
			return 74
		}
		sbe1v1k_validate_sysupgrade_tar "$1" || return 74
		sbe1v1k_prepare_layout "$1" || return 74
		;;
	esac

	return 0;
}

platform_do_upgrade() {
	case "$(board_name)" in
	8devices,kiwi-dvk)
		CI_KERNPART="0:HLOS"
		CI_ROOTPART="rootfs"
		emmc_do_upgrade "$1"
		;;
	askey,sbe1v1k)
		sbe1v1k_validate_sysupgrade_tar "$1" &&
			sbe1v1k_prepare_layout "$1" &&
			sbe1v1k_do_upgrade "$1" || {
			echo "SBE1V1K upgrade failed; refusing to reboot."
			exit 1
		}
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}

platform_copy_config() {
	case "$(board_name)" in
	8devices,kiwi-dvk)
		emmc_copy_config
		;;
	askey,sbe1v1k)
		# The backup was written before the kernel commit in sbe1v1k_do_upgrade().
		[ "${SBE1V1K_CONFIG_COPIED:-}" = 1 ] || {
			echo "SBE1V1K configuration backup was not written; refusing to reboot."
			exit 1
		}
		;;
	esac
}
