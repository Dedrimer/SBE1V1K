#!/usr/bin/env bash

set -Eeuo pipefail

# CachyOS / Arch Linux (pacman) variant of build-sbe1v1k.sh.
# Runs fine from fish or any other shell: bash ./build-sbe1v1k-cachyos.sh

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
SOURCE_DIR="$(dirname "$SCRIPT_PATH")"
readonly SOURCE_DIR

if [[ -z "${BUILD_LOG_FILE:-}" ]]; then
	BUILD_LOG_FILE="$SOURCE_DIR/.build-logs/build-$(date +%Y%m%d-%H%M%S)-$$.log"
fi
mkdir -p "$(dirname "$BUILD_LOG_FILE")"
BUILD_LOG_FILE="$(cd "$(dirname "$BUILD_LOG_FILE")" && pwd -P)/$(basename "$BUILD_LOG_FILE")"
export BUILD_LOG_FILE
if [[ -z "${BUILD_LOG_ACTIVE:-}" ]]; then
	export BUILD_LOG_ACTIVE=1
	exec > >(tee -a "$BUILD_LOG_FILE") 2>&1
fi
printf '\n===== SBE1V1K build started: %s =====\n' "$(date --iso-8601=seconds)"
printf 'Script: %s\nSource: %s\nLog: %s\nCommand: bash %q\n' \
	"$SCRIPT_PATH" "$SOURCE_DIR" "$BUILD_LOG_FILE" "$*"
SCRIPT_STARTED_AT="${SCRIPT_STARTED_AT:-$(date +%s)}"
export SCRIPT_STARTED_AT

JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)}"
INSTALL_DEPS=1
CLEAN_BUILD=0
DOWNLOAD_ONLY=0
RETRY_SERIAL=1
BUILD_STARTED_AT=0
BUILD_FINISHED_AT=0

format_duration() {
	local total_seconds="$1"
	local hours=$((total_seconds / 3600))
	local minutes=$(((total_seconds % 3600) / 60))
	local seconds=$((total_seconds % 60))
	printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
}

report_build_time() {
	local exit_code=$?
	local finished_at compilation_finished_at elapsed status script_elapsed

	finished_at="$(date +%s)"
	status="failed"
	((exit_code == 0)) && status="completed"
	if ((BUILD_STARTED_AT > 0)); then
		compilation_finished_at="$finished_at"
		((BUILD_FINISHED_AT > 0)) && compilation_finished_at="$BUILD_FINISHED_AT"
		elapsed=$((compilation_finished_at - BUILD_STARTED_AT))
		printf '\n==> Firmware compilation %s in %s\n' \
			"$status" "$(format_duration "$elapsed")"
	fi
	script_elapsed=$((finished_at - SCRIPT_STARTED_AT))
	printf '===== SBE1V1K build %s: %s (exit code %d) =====\n' \
		"$status" "$(date --iso-8601=seconds)" "$exit_code"
	printf 'Total script time: %s\n' "$(format_duration "$script_elapsed")"
	return "$exit_code"
}

trap report_build_time EXIT

usage() {
	cat <<'EOF'
Usage: bash ./build-sbe1v1k-cachyos.sh [options]

Prepare a clean CachyOS/Arch Linux host and build the SBE1V1K firmware
from start to finish. Works from any shell, including fish:
  bash ./build-sbe1v1k-cachyos.sh

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
  BUILD_LOG_FILE=PATH
                     Override the full execution log path

Supported dependency installer: pacman (CachyOS/Arch official repos only).
Run as a normal user with sudo access. Direct root execution creates an
unprivileged "openwrt-builder" account because OpenWrt refuses root builds.
EOF
}

detect_distro() {
	local id=""
	if [[ -r /etc/os-release ]]; then
		id="$(. /etc/os-release; printf '%s' "${ID:-}")"
	fi
	case "$id" in
	cachyos|arch|archarm|endeavouros|manjaro)
		return 0
		;;
	esac
	if ! command -v pacman >/dev/null 2>&1; then
		die "this script targets CachyOS/Arch Linux (pacman); use build-sbe1v1k.sh on other distributions"
	fi
	log "Note: /etc/os-release reports ID=$id; continuing because pacman is available"
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

detect_distro

cd "$SOURCE_DIR"
OUTPUT_ROOT="$SOURCE_DIR/out"
readonly OUTPUT_ROOT
mkdir -p "$OUTPUT_ROOT"

case_probe="$SOURCE_DIR/.openwrt-case-probe-$$"
touch "${case_probe}.lower" || die "the source directory is not writable: $SOURCE_DIR"
if [[ -e "${case_probe}.LOWER" ]]; then
	die "OpenWrt requires a case-sensitive filesystem; clone the repository into a native Linux filesystem"
fi
rm -f -- "${case_probe}.lower"

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
	if ! command -v pacman >/dev/null 2>&1; then
		die "pacman was not found; this script is for CachyOS/Arch Linux. Use --skip-deps if dependencies are already installed"
	fi
	log "Installing CachyOS/Arch Linux build dependencies (official repos only)"

	local -a packages=(
		base-devel clang flex bison gawk gettext git ncurses openssl
		python python-setuptools rsync swig unzip file wget curl
		ca-certificates bc bzip2 elfutils xz zstd patch perl time vim libxslt
	)
	if pacman -Q zlib-ng-compat >/dev/null 2>&1; then
		log "zlib-ng-compat is installed and already provides zlib headers and libz; skipping the conflicting zlib package"
	else
		packages+=(zlib)
	fi

	run_as_root pacman -Syu --needed --noconfirm "${packages[@]}"
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
	chown "$build_user:$(id -gn "$build_user")" "$BUILD_LOG_FILE"

	build_args=(--skip-deps --jobs "$JOBS")
	((CLEAN_BUILD)) && build_args+=(--clean)
	((DOWNLOAD_ONLY)) && build_args+=(--download-only)
	((RETRY_SERIAL)) || build_args+=(--no-retry)

	exec runuser -u "$build_user" -- env \
		HOME="$build_home" BUILD_LOG_FILE="$BUILD_LOG_FILE" BUILD_LOG_ACTIVE=1 SCRIPT_STARTED_AT="$SCRIPT_STARTED_AT" "${proxy_env[@]}" \
		/bin/bash "$SCRIPT_PATH" "${build_args[@]}"
fi

available_kib="$(df -Pk "$SOURCE_DIR" | awk 'NR == 2 { print $4 }')"
if [[ "$available_kib" =~ ^[0-9]+$ ]] && ((available_kib < 20 * 1024 * 1024)); then
	die "at least 20 GiB of free disk space is required (currently $((available_kib / 1024 / 1024)) GiB)"
fi

log "Preparing the SBE1V1K firmware configuration"
cp configs/sbe1v1k.config .config

if ((CLEAN_BUILD)); then
	log "Cleaning previous build products"
	make CONFIG_BINARY_FOLDER="$OUTPUT_ROOT" dirclean
fi

printf 'Git commit: '; git rev-parse HEAD
printf 'Kernel: '; uname -a
printf 'Working directory filesystem: '; df -T "$SOURCE_DIR" | awk 'NR == 2 { print $2 }'
printf 'Available disk space: '; df -h "$SOURCE_DIR" | awk 'NR == 2 { print $4 }'

log "Updating and installing locked OpenWrt feeds"
./scripts/feeds update -a

istore_makefile="$SOURCE_DIR/feeds/istore/luci/luci-app-store/Makefile"
istore_patch="$SOURCE_DIR/config/istore-openwrt-main.patch"
legacy_istore_dependency="LUCI_DEPENDS+=\$(if \$(CONFIG_USE_APK)"
[[ -f "$istore_makefile" ]] || die "the locked iStore source was not downloaded"
if grep -Fq "$legacy_istore_dependency" "$istore_makefile"; then
	patch --batch --forward -d "$SOURCE_DIR/feeds/istore" -p1 < "$istore_patch"
elif ! grep -Fq '+USE_APK:luci-compat' "$istore_makefile"; then
	die "the locked iStore source does not match the expected dependency format"
fi

./scripts/feeds install -a

argon_source="$SOURCE_DIR/feeds/argon"
argon_target="$SOURCE_DIR/package/feeds/argon/luci-theme-argon"
argon_repository="https://github.com/jerrykuku/luci-theme-argon.git"
argon_commit="136eb5d42f30554e89cc737fd90f503909810660"
if [[ -d "$argon_source/.git" ]]; then
	git -C "$argon_source" remote set-url origin "$argon_repository"
else
	[[ ! -e "$argon_source" ]] || die "cannot initialize Argon over an existing path: $argon_source"
	mkdir -p "$argon_source"
	git -C "$argon_source" init
	git -C "$argon_source" remote add origin "$argon_repository"
fi
git -C "$argon_source" fetch --depth 1 origin "$argon_commit"
git -C "$argon_source" checkout --detach --force FETCH_HEAD
git -C "$argon_source" clean -fdx
[[ "$(git -C "$argon_source" rev-parse HEAD)" == "$argon_commit" ]] || die "Argon commit verification failed"
[[ -f "$argon_source/Makefile" ]] || die "the locked Argon source was not downloaded"
mkdir -p "$(dirname "$argon_target")"
if [[ -L "$argon_target" ]]; then
	rm -f -- "$argon_target"
elif [[ -e "$argon_target" && ! -d "$argon_target" ]]; then
	die "cannot install Argon over an existing non-symlink path: $argon_target"
fi
mkdir -p "$argon_target"
rsync -a --delete --exclude=.git/ "$argon_source/" "$argon_target/"

log "Applying the SBE1V1K firmware configuration"
make CONFIG_BINARY_FOLDER="$OUTPUT_ROOT" defconfig
configured_output_dir="$(make -s CONFIG_BINARY_FOLDER="$OUTPUT_ROOT" val.OUTPUT_DIR)"
expected_output_dir="$(readlink -f "$OUTPUT_ROOT")"
actual_output_dir="$(readlink -f "$configured_output_dir")"
[[ "$actual_output_dir" == "$expected_output_dir" ]] || \
	die "OpenWrt output directory mismatch: expected $expected_output_dir, got $actual_output_dir"
printf 'Verified OpenWrt output directory: %s\n' "$actual_output_dir"

while IFS= read -r package_config; do
	grep -qx "${package_config}=y" .config || \
		die "required package was not selected after make defconfig: ${package_config#CONFIG_PACKAGE_}"
done < <(sed -n 's/^\(CONFIG_PACKAGE_[A-Za-z0-9_.+-]*\)=y$/\1/p' configs/sbe1v1k.config)

log "Downloading all source archives with $JOBS jobs"
make CONFIG_BINARY_FOLDER="$OUTPUT_ROOT" download -j"$JOBS"

if ((DOWNLOAD_ONLY)); then
	log "Downloads completed; build skipped by request"
	exit 0
fi

log "Building SBE1V1K firmware with $JOBS jobs"
BUILD_STARTED_AT="$(date +%s)"
output_dir="$OUTPUT_ROOT/targets/qualcommbe/ipq95xx"
mkdir -p "$output_dir"
case "$output_dir" in
	"$OUTPUT_ROOT"/*) ;;
	*) die "refusing to clean output outside OUTPUT_ROOT: $output_dir" ;;
esac
find "$output_dir" -maxdepth 1 -type f -name '*askey_sbe1v1k*' -delete
if ! make CONFIG_BINARY_FOLDER="$OUTPUT_ROOT" -j"$JOBS" world; then
	if ((RETRY_SERIAL)); then
		log "Parallel build failed; retrying serially with verbose output"
		make CONFIG_BINARY_FOLDER="$OUTPUT_ROOT" -j1 V=s world
	else
		die "firmware build failed"
	fi
fi
BUILD_FINISHED_AT="$(date +%s)"

sysupgrade_image="$(find "$output_dir" -maxdepth 1 -type f -name '*askey_sbe1v1k*squashfs-sysupgrade.bin' -print -quit 2>/dev/null || true)"
initramfs_image="$(find "$output_dir" -maxdepth 1 -type f -name '*askey_sbe1v1k*initramfs-uImage.itb' -print -quit 2>/dev/null || true)"

[[ -n "$sysupgrade_image" ]] || die "build finished without the expected SBE1V1K sysupgrade image"
[[ -n "$initramfs_image" ]] || die "build finished without the expected SBE1V1K initramfs image"

log "Build completed successfully"
build_elapsed=$((BUILD_FINISHED_AT - BUILD_STARTED_AT))
build_duration="$(format_duration "$build_elapsed")"
printf 'Compilation time: %s (%d seconds)\n' "$build_duration" "$build_elapsed" | tee "$OUTPUT_ROOT/build-time.txt"
printf 'Initramfs: %s\n' "$initramfs_image"
printf 'Sysupgrade: %s\n' "$sysupgrade_image"
sha256sum "$initramfs_image" "$sysupgrade_image"
