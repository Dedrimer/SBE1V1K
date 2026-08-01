#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT INT TERM

board_name() {
	echo 'askey,sbe1v1k'
}

. "$repo_root/target/linux/qualcommbe/ipq95xx/base-files/lib/upgrade/platform.sh"

if [ "$#" -gt 0 ]; then
	platform_check_image "$1"
	echo "built sysupgrade validation passed: $1"
fi

mkdir -p "$work_dir/sysupgrade-askey_sbe1v1k"
printf 'BOARD=askey_sbe1v1k\n' > "$work_dir/sysupgrade-askey_sbe1v1k/CONTROL"
dd if=/dev/zero of="$work_dir/sysupgrade-askey_sbe1v1k/kernel" bs=1024 count=16 2>/dev/null
dd if=/dev/zero of="$work_dir/sysupgrade-askey_sbe1v1k/root" bs=1024 count=64 2>/dev/null
tar -C "$work_dir" -cf "$work_dir/valid.bin" sysupgrade-askey_sbe1v1k

platform_check_image "$work_dir/valid.bin"

head -c 32768 "$work_dir/valid.bin" > "$work_dir/truncated.bin"
if platform_check_image "$work_dir/truncated.bin"; then
	echo 'ERROR: truncated archive was accepted' >&2
	exit 1
fi

rm "$work_dir/sysupgrade-askey_sbe1v1k/root"
tar -C "$work_dir" -cf "$work_dir/missing-root.bin" sysupgrade-askey_sbe1v1k
if platform_check_image "$work_dir/missing-root.bin"; then
	echo 'ERROR: archive without root payload was accepted' >&2
	exit 1
fi

echo 'upgrade validation tests passed'
