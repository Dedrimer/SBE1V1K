#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT INT TERM

SBE1V1K_SYS_BLOCK="$work_dir/sys/block"
SBE1V1K_SYS_CLASS_BLOCK="$work_dir/sys/class/block"
SBE1V1K_DEV_ROOT="$work_dir/dev"

board_name() {
	echo 'askey,sbe1v1k'
}

get_magic_long() {
	od -An -N4 -tx1 "$1" | tr -d ' \n'
}

get_magic_word() {
	od -An -N2 -tx1 "$1" | tr -d ' \n'
}

identify_magic_long() {
	case "$1" in
	d00dfeed) echo fit ;;
	1f8b*) echo gzip ;;
	*) echo unknown ;;
	esac
}

. "$repo_root/target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh"

# Tests use sparse regular files in place of block devices.
sbe1v1k_is_block_device() {
	[ -f "$1" ]
}

clear_layout() {
	rm -rf -- "$SBE1V1K_SYS_BLOCK" "$SBE1V1K_SYS_CLASS_BLOCK" "$SBE1V1K_DEV_ROOT"
	mkdir -p "$SBE1V1K_SYS_BLOCK/mmcblk0" "$SBE1V1K_SYS_CLASS_BLOCK" "$SBE1V1K_DEV_ROOT"
}

add_partition() {
	local name="$1" label="$2" start="$3" sectors="$4"

	mkdir -p "$SBE1V1K_SYS_BLOCK/mmcblk0/$name" "$SBE1V1K_SYS_CLASS_BLOCK/$name"
	printf 'PARTNAME=%s\n' "$label" > "$SBE1V1K_SYS_BLOCK/mmcblk0/$name/uevent"
	printf '%s\n' "$start" > "$SBE1V1K_SYS_CLASS_BLOCK/$name/start"
	printf '%s\n' "$sectors" > "$SBE1V1K_SYS_CLASS_BLOCK/$name/size"
	truncate -s $((sectors * 512)) "$SBE1V1K_DEV_ROOT/$name"
}

make_large_layout() {
	clear_layout
	add_partition mmcblk0p25 '0:HLOS' 81954 14336
	add_partition mmcblk0p28 chainloader 110626 8192
	add_partition mmcblk0p29 kernel 118818 65536
	add_partition mmcblk0p30 rootfs 184354 2097152
	add_partition mmcblk0p31 rootfs_data 2281506 1048576
	printf 'HLOS-anchor\n' | dd of="$SBE1V1K_DEV_ROOT/mmcblk0p25" conv=notrunc 2>/dev/null
	printf 'chainloader-anchor\n' | dd of="$SBE1V1K_DEV_ROOT/mmcblk0p28" conv=notrunc 2>/dev/null
	printf 'old-kernel\n' | dd of="$SBE1V1K_DEV_ROOT/mmcblk0p29" conv=notrunc 2>/dev/null
	printf 'old-overlay\n' | dd of="$SBE1V1K_DEV_ROOT/mmcblk0p31" conv=notrunc 2>/dev/null
}

make_mainline_layout() {
	clear_layout
	add_partition mmcblk0p25 '0:HLOS' 81954 14336
	add_partition mmcblk0p26 '0:HLOS_1' 96290 14336
	add_partition mmcblk0p27 rootfs 110626 249856
	add_partition mmcblk0p29 rootfs_data 610338 1048576
	add_partition mmcblk0p40 rsvd_2 5201954 65536
}

assert_member_written() {
	local source="$1" target="$2" bytes

	bytes="$(wc -c < "$source")"
	head -c "$bytes" "$target" | cmp -s - "$source"
}

mkdir -p "$work_dir/image/sysupgrade-askey_sbe1v1k"
printf 'BOARD=askey_sbe1v1k\n' > "$work_dir/image/sysupgrade-askey_sbe1v1k/CONTROL"
dd if=/dev/zero of="$work_dir/image/sysupgrade-askey_sbe1v1k/kernel" bs=1024 count=16 2>/dev/null
printf 'SBE1V1K-kernel\n' | dd of="$work_dir/image/sysupgrade-askey_sbe1v1k/kernel" conv=notrunc 2>/dev/null
dd if=/dev/zero of="$work_dir/image/sysupgrade-askey_sbe1v1k/root" bs=1024 count=64 2>/dev/null
printf 'SBE1V1K-rootfs\n' | dd of="$work_dir/image/sysupgrade-askey_sbe1v1k/root" conv=notrunc 2>/dev/null
tar -C "$work_dir/image" -cf "$work_dir/valid.bin" sysupgrade-askey_sbe1v1k
gzip -c "$work_dir/valid.bin" > "$work_dir/valid.bin.gz"
dd if=/dev/zero of="$work_dir/zero.4k" bs=4096 count=1 2>/dev/null

make_large_layout
platform_check_image "$work_dir/valid.bin"
[ "$SBE1V1K_LAYOUT:$CI_KERNPART:$CI_ROOTDEV" = "large:kernel:mmcblk0" ]
platform_check_image "$work_dir/valid.bin.gz"

if [ "$#" -gt 0 ]; then
	platform_check_image "$1"
	echo "built sysupgrade validation passed: $1"
fi

printf '\320\015\376\355' > "$work_dir/recovery.bin"
set +e
platform_check_image "$work_dir/recovery.bin"
check_status=$?
set -e
if [ "$check_status" -ne 74 ]; then
	echo 'ERROR: recovery FIT was accepted by sysupgrade' >&2
	exit 1
fi

head -c 32768 "$work_dir/valid.bin" > "$work_dir/truncated.bin"
if platform_check_image "$work_dir/truncated.bin"; then
	echo 'ERROR: truncated archive was accepted' >&2
	exit 1
fi

rm "$work_dir/image/sysupgrade-askey_sbe1v1k/root"
tar -C "$work_dir/image" -cf "$work_dir/missing-root.bin" sysupgrade-askey_sbe1v1k
if platform_check_image "$work_dir/missing-root.bin"; then
	echo 'ERROR: archive without root payload was accepted' >&2
	exit 1
fi

dd if=/dev/zero of="$work_dir/image/sysupgrade-askey_sbe1v1k/root" bs=1024 count=64 2>/dev/null
printf 'SBE1V1K-rootfs\n' | dd of="$work_dir/image/sysupgrade-askey_sbe1v1k/root" conv=notrunc 2>/dev/null
printf 'BOARD=wrong_device\n' > "$work_dir/image/sysupgrade-askey_sbe1v1k/CONTROL"
tar -C "$work_dir/image" -cf "$work_dir/wrong-board.bin" sysupgrade-askey_sbe1v1k
if platform_check_image "$work_dir/wrong-board.bin"; then
	echo 'ERROR: archive for another board was accepted' >&2
	exit 1
fi
printf 'BOARD=askey_sbe1v1k\n' > "$work_dir/image/sysupgrade-askey_sbe1v1k/CONTROL"

# A mismatched chainloader boundary must block all writes.
printf '110627\n' > "$SBE1V1K_SYS_CLASS_BLOCK/mmcblk0p28/start"
set +e
platform_check_image "$work_dir/valid.bin"
check_status=$?
set -e
if [ "$check_status" -ne 74 ]; then
	echo 'ERROR: unsafe large layout was accepted' >&2
	exit 1
fi
printf '110626\n' > "$SBE1V1K_SYS_CLASS_BLOCK/mmcblk0p28/start"

# No-config upgrade clears rootfs_data and commits the kernel last.
UPGRADE_BACKUP=""
unset SBE1V1K_CONFIG_COPIED
dd if="$SBE1V1K_DEV_ROOT/mmcblk0p25" of="$work_dir/hlos.before" bs=4096 count=1 2>/dev/null
dd if="$SBE1V1K_DEV_ROOT/mmcblk0p28" of="$work_dir/chainloader.before" bs=4096 count=1 2>/dev/null
platform_do_upgrade "$work_dir/valid.bin"
assert_member_written "$work_dir/image/sysupgrade-askey_sbe1v1k/root" "$EMMC_ROOT_DEV"
assert_member_written "$work_dir/image/sysupgrade-askey_sbe1v1k/kernel" "$EMMC_KERN_DEV"
dd if="$EMMC_DATA_DEV" bs=4096 count=1 2>/dev/null | cmp -s - "$work_dir/zero.4k"
dd if="$SBE1V1K_DEV_ROOT/mmcblk0p25" bs=4096 count=1 2>/dev/null | cmp -s - "$work_dir/hlos.before"
dd if="$SBE1V1K_DEV_ROOT/mmcblk0p28" bs=4096 count=1 2>/dev/null | cmp -s - "$work_dir/chainloader.before"

# Config backup is placed in rootfs_data before the new kernel is committed.
make_large_layout
mkdir -p "$work_dir/backup/etc/config"
printf 'config system\n' > "$work_dir/backup/etc/config/system"
tar -C "$work_dir/backup" -czf "$work_dir/sysupgrade.tgz" etc
UPGRADE_BACKUP="$work_dir/sysupgrade.tgz"
unset SBE1V1K_CONFIG_COPIED
platform_do_upgrade "$work_dir/valid.bin"
backup_bytes="$(wc -c < "$UPGRADE_BACKUP")"
head -c "$backup_bytes" "$EMMC_DATA_DEV" | cmp -s - "$UPGRADE_BACKUP"
[ "$SBE1V1K_CONFIG_COPIED" = 1 ]
platform_copy_config

# If rootfs writing fails, platform_do_upgrade exits and leaves kernel invalid.
make_large_layout
UPGRADE_BACKUP=""
unset SBE1V1K_CONFIG_COPIED
if (
	sbe1v1k_write_tar_member() { return 1; }
	platform_do_upgrade "$work_dir/valid.bin"
); then
	echo 'ERROR: failed rootfs write did not abort upgrade' >&2
	exit 1
fi
dd if="$SBE1V1K_DEV_ROOT/mmcblk0p29" bs=4096 count=1 2>/dev/null | cmp -s - "$work_dir/zero.4k"

# Mainline is recognized only when all U-Boot anchors match; it remains unverified on hardware.
make_mainline_layout
platform_check_image "$work_dir/valid.bin"
[ "$SBE1V1K_LAYOUT:$CI_KERNPART:$CI_ROOTDEV" = "mainline:0:HLOS:mmcblk0" ]

echo 'upgrade validation tests passed'
