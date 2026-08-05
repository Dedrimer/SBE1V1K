#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SOURCE_DIR="$(dirname "$SCRIPT_PATH")"
readonly SOURCE_DIR

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)}"
INSTALL_DEPS=1
CLEAN_BUILD=0
DOWNLOAD_ONLY=0
RETRY_SERIAL=1

usage() {
	cat <<'EOF'
Usage: bash ./build-sbe1v1k.sh [options]

Prepare a clean Linux host and build the SBE1V1K firmware from start to finish.

Options:
  -j, --jobs N       Number of parallel build jobs (default: all CPUs)
      --skip-deps    Do not install host build dependencies
      --clean        Run "make dirclean" before configuring
      --download-only
                     Stop after downloading all source archives
      --no-retry     Do not retry a failed parallel build with -j1 V=s
  -h, --help         Show this help

Environment:
  JOBS=N             Alternative way to set parallel jobs
  HTTP_PROXY=URL     Proxy inherited by package managers, Git and downloads
  HTTPS_PROXY=URL    HTTPS proxy inherited by package managers, Git and downloads

Supported dependency installers: apt, dnf, pacman and zypper.
Run as a normal user with sudo access. Direct root execution creates an
unprivileged "openwrt-builder" account because OpenWrt refuses root builds.
EOF
}

log() {
	printf '\n\033[1;32m==> %s\033[0m\n' "$*"
}

die() {
	printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
	exit 1
}

while (($#)); do
	case "$1" in
	-j|--jobs)
		(($# >= 2)) || die "$1 requires a value"
		JOBS="$2"
		shift 2
		;;
	--skip-deps)
		INSTALL_DEPS=0
		shift
		;;
	--clean)
		CLEAN_BUILD=1
		shift
		;;
	--download-only)
		DOWNLOAD_ONLY=1
		shift
		;;
	--no-retry)
		RETRY_SERIAL=0
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1"
		;;
	esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "jobs must be a positive integer"
[[ "$(uname -s)" == Linux ]] || die "this script must run on native Linux or WSL2"
[[ "$SOURCE_DIR" != *[[:space:]]* ]] || die "OpenWrt cannot build from a path containing spaces: $SOURCE_DIR"
[[ -f "$SOURCE_DIR/Makefile" && -x "$SOURCE_DIR/scripts/feeds" ]] || \
	die "the script must remain in the OpenWrt source root"

cd "$SOURCE_DIR"

case_probe="$SOURCE_DIR/.openwrt-case-probe-$$"
trap 'rm -f -- "${case_probe}.lower"' EXIT
touch "${case_probe}.lower" || die "the source directory is not writable: $SOURCE_DIR"
if [[ -e "${case_probe}.LOWER" ]]; then
	die "OpenWrt requires a case-sensitive filesystem; clone the repository into a native Linux filesystem"
fi
rm -f -- "${case_probe}.lower"
trap - EXIT

proxy_env=()
for proxy_name in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy; do
	if [[ -n "${!proxy_name:-}" ]]; then
		proxy_env+=("$proxy_name=${!proxy_name}")
	fi
done

run_as_root() {
	if ((EUID == 0)); then
		env "${proxy_env[@]}" "$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo env "${proxy_env[@]}" "$@"
	else
		die "installing dependencies requires root privileges or sudo; use --skip-deps if already installed"
	fi
}

install_dependencies() {
	if command -v apt-get >/dev/null 2>&1; then
		log "Installing Debian/Ubuntu build dependencies"
		run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update
		run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
			build-essential clang flex bison gawk gcc-multilib g++-multilib gettext git \
			libncurses-dev libssl-dev python3 python3-setuptools python3-dev rsync swig \
			unzip zlib1g-dev file wget curl ca-certificates bc bzip2 libelf-dev \
			liblzma-dev libzstd-dev patch perl time xxd xsltproc zstd
	elif command -v dnf >/dev/null 2>&1; then
		log "Installing Fedora/RHEL build dependencies"
		run_as_root dnf install -y \
			'@Development Tools' clang flex bison gawk gcc-c++ glibc-devel.i686 \
			libstdc++-devel.i686 gettext git ncurses-devel openssl-devel python3 \
			python3-setuptools python3-devel rsync swig unzip zlib-devel file wget \
			curl ca-certificates bc bzip2 elfutils-libelf-devel xz-devel libzstd-devel \
			patch perl time vim-common libxslt
	elif command -v pacman >/dev/null 2>&1; then
		log "Installing Arch Linux build dependencies"
		run_as_root pacman -Syu --needed --noconfirm \
			base-devel clang flex bison gawk gcc-multilib gettext git ncurses openssl \
			python python-setuptools rsync swig unzip zlib file wget curl ca-certificates \
			bc bzip2 libelf xz zstd patch perl time vim libxslt
	elif command -v zypper >/dev/null 2>&1; then
		log "Installing openSUSE build dependencies"
		run_as_root zypper --non-interactive install -t pattern devel_basis
		run_as_root zypper --non-interactive install \
			clang flex bison gawk gcc-c++ gcc-32bit gcc-c++-32bit gettext-tools git \
			ncurses-devel libopenssl-devel python3 python3-setuptools python3-devel \
			rsync swig unzip zlib-devel file wget curl ca-certificates bc bzip2 \
			libelf-devel xz-devel libzstd-devel patch perl time vim libxslt-tools
	else
		die "unsupported distribution; install OpenWrt build prerequisites and rerun with --skip-deps"
	fi
}

if ((INSTALL_DEPS)); then
	install_dependencies
fi

if ((EUID == 0)); then
	if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
		build_user="$SUDO_USER"
	else
		build_user="${OPENWRT_BUILD_USER:-openwrt-builder}"
		if ! id "$build_user" >/dev/null 2>&1; then
			log "Creating unprivileged build account: $build_user"
			useradd --create-home --shell /bin/bash "$build_user"
		fi
	fi

	build_home="$(getent passwd "$build_user" | cut -d: -f6)"
	[[ -n "$build_home" ]] || die "cannot determine the home directory for $build_user"
	log "Transferring the source tree to unprivileged builder: $build_user"
	chown -R "$build_user:$(id -gn "$build_user")" "$SOURCE_DIR"

	build_args=(--skip-deps --jobs "$JOBS")
	((CLEAN_BUILD)) && build_args+=(--clean)
	((DOWNLOAD_ONLY)) && build_args+=(--download-only)
	((RETRY_SERIAL)) || build_args+=(--no-retry)

	exec runuser -u "$build_user" -- env \
		HOME="$build_home" "${proxy_env[@]}" \
		/bin/bash "$SCRIPT_PATH" "${build_args[@]}"
fi

available_kib="$(df -Pk "$SOURCE_DIR" | awk 'NR == 2 { print $4 }')"
if [[ "$available_kib" =~ ^[0-9]+$ ]] && ((available_kib < 20 * 1024 * 1024)); then
	die "at least 20 GiB of free disk space is required (currently $((available_kib / 1024 / 1024)) GiB)"
fi

if ((CLEAN_BUILD)); then
	log "Cleaning previous build products"
	make dirclean
fi

log "Updating and installing locked OpenWrt feeds"
./scripts/feeds update -a
./scripts/feeds install -a

log "Applying the SBE1V1K firmware configuration"
cp configs/sbe1v1k.config .config
make defconfig

while IFS= read -r package_config; do
	grep -qx "${package_config}=y" .config || \
		die "required package was not selected after make defconfig: ${package_config#CONFIG_PACKAGE_}"
done < <(sed -n 's/^\(CONFIG_PACKAGE_[A-Za-z0-9_.+-]*\)=y$/\1/p' configs/sbe1v1k.config)

log "Downloading all source archives with $JOBS jobs"
make download -j"$JOBS"

if ((DOWNLOAD_ONLY)); then
	log "Downloads completed; build skipped by request"
	exit 0
fi

log "Building SBE1V1K firmware with $JOBS jobs"
if ! make -j"$JOBS" world; then
	if ((RETRY_SERIAL)); then
		log "Parallel build failed; retrying serially with verbose output"
		make -j1 V=s world
	else
		die "firmware build failed"
	fi
fi

output_dir="$SOURCE_DIR/bin/targets/qualcommbe/ipq95xx"
sysupgrade_image="$(find "$output_dir" -maxdepth 1 -type f -name '*askey_sbe1v1k*squashfs-sysupgrade.bin' -print -quit 2>/dev/null || true)"
initramfs_image="$(find "$output_dir" -maxdepth 1 -type f -name '*askey_sbe1v1k*initramfs-uImage.itb' -print -quit 2>/dev/null || true)"

[[ -n "$sysupgrade_image" ]] || die "build finished without the expected SBE1V1K sysupgrade image"
[[ -n "$initramfs_image" ]] || die "build finished without the expected SBE1V1K initramfs image"

log "Build completed successfully"
printf 'Initramfs: %s\n' "$initramfs_image"
printf 'Sysupgrade: %s\n' "$sysupgrade_image"
sha256sum "$initramfs_image" "$sysupgrade_image"
