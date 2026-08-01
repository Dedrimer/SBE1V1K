PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='fw_printenv fw_setenv head'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'

platform_check_image() {
	local image="$1"
	local board_dir

	case "$(board_name)" in
	askey,sbe1v1k)
		# emmc_do_upgrade() consumes a tar archive.  Validate the complete
		# archive before entering the upgrade ramfs so a partial download
		# cannot leave the kernel and rootfs at different revisions.
		tar tf "$image" >/dev/null 2>&1 || {
			echo "Invalid or truncated SBE1V1K sysupgrade archive"
			return 1
		}

		board_dir="$(tar tf "$image" | sed -n 's#^\(sysupgrade-[^/]*/\)$#\1#p' | head -n 1)"
		[ -n "$board_dir" ] || {
			echo "SBE1V1K sysupgrade archive has no board directory"
			return 1
		}

		for payload in CONTROL kernel root; do
			tar tf "$image" "${board_dir}${payload}" >/dev/null 2>&1 || {
				echo "SBE1V1K sysupgrade archive is missing ${payload}"
				return 1
			}
		done
		;;
	esac

	return 0
}

platform_do_upgrade() {
	case "$(board_name)" in
	8devices,kiwi-dvk)
		CI_KERNPART="0:HLOS"
		CI_ROOTPART="rootfs"
		emmc_do_upgrade "$1"
		;;
	askey,sbe1v1k)
		CI_KERNPART="0:HLOS"
		CI_ROOTPART="rootfs"
		CI_DATAPART="rootfs_data"
		emmc_do_upgrade "$1"
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}

platform_copy_config() {
	case "$(board_name)" in
	8devices,kiwi-dvk|\
	askey,sbe1v1k)
		emmc_copy_config
		;;
	esac
}
