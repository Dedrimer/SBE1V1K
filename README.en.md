# SBE1V1K OpenWrt English Guide

[简体中文](README.zh-CN.md) | [Project home](README.md)

## Overview

This repository is a complete OpenWrt `qualcommbe/ipq95xx` source tree for
the Spectrum/Askey SBE1V1K, also known as RTQ7300T. Stable Preview 2 favors
stability and recovery and intentionally excludes the experimental LEDE/QSDK
ECM/NSS fast-path stack.

SBE1V1K support is not yet an official OpenWrt stable release. This firmware is
intended for advanced users with a serial console, HTTP chainloader, or another
verified recovery path.

## Stable Preview 2 fixes

- Resolves the current ath12k radio index from each requested 2.4, 5, or 6GHz
  frequency range on every setup, avoiding band swaps after PCI enumeration
  changes.
- Defaults US-deployed SBE1V1K units to the `US` regulatory domain instead of
  generating the invalid hostapd country code `00`.
- Serializes hostapd setup when three radios share one wiphy and holds a
  per-PHY lock for four seconds so ath12k can finish vdev initialization.
- Fully validates SBE1V1K sysupgrade tar archives and requires `CONTROL`,
  `kernel`, and `root` before any persistent write.
- Includes LuCI HTTPS, Simplified Chinese, `sbe1v1k-diag`, iperf3, ethtool,
  pciutils, and tcpdump-mini.

## Hardware validation

- LAN management at `192.168.1.1` and WAN DHCP passed.
- 2.4, 5, and 6GHz APs ran at 2412, 5180, and 5955MHz.
- Five consecutive `wifi reload` cycles retained three hostapd objects and
  three SSIDs.
- No new vdev-start, hostapd-add-interface, or beacon-initialization error was
  recorded.

See [VALIDATION-CODEX-20260801.md](VALIDATION-CODEX-20260801.md) for details.

## Build

Ubuntu 24.04 or WSL2 Ubuntu 24.04 is recommended. Keep the source tree on a
case-sensitive Linux filesystem.

```bash
sudo apt update
sudo apt install -y \
  build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
  gettext git libncurses-dev libssl-dev python3-setuptools rsync swig \
  unzip zlib1g-dev file wget bc bzip2 libelf-dev liblzma-dev \
  python3-dev time xxd zstd

git clone https://github.com/yintaomu/SBE1V1K-OpenWrt.git
cd SBE1V1K-OpenWrt

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
./scripts/feeds update -a
./scripts/feeds install -a
cp configs/sbe1v1k.config .config
make defconfig
make download -j"$(nproc)"
make -j"$(nproc)" world
```

Images are written to:

```text
out/targets/qualcommbe/ipq95xx/
```

## Choosing an image

- `*-initramfs-uImage.itb`: RAM boot, first-stage testing, or rescue; it does
  not install a persistent root filesystem.
- `*-squashfs-sysupgrade.bin`: install or upgrade an SBE1V1K already running
  OpenWrt, including through the HTTP chainloader firmware page.
- `*-squashfs-factory.bin`: raw squashfs root filesystem. Do not upload it to
  LuCI and do not write it to a kernel partition.

Stable Preview 2 sysupgrade:

```text
SHA-256: 09967f4742c9d428b1e3644e71ce936df440282edf9a80773eb65a5428ed339e
```

## Flashing warning

1. Back up eMMC boot0, boot1, GPT, and critical partitions first.
2. Identify the current factory A/B, mainline, or third-party large layout.
   Never mix procedures intended for different layouts.
3. HTTP-chainloader users should normally upload the sysupgrade image through
   the `192.168.255.1` Firmware page.
4. Maintain stable power, Ethernet, and browser connectivity throughout every
   write operation.
5. A clean OpenWrt installation keeps Wi-Fi disabled and root passwordless by
   default. Set a login password and encrypted Wi-Fi immediately. Public images
   never embed private credentials.

Detailed instructions:

- [SBE1V1K-OpenWrt-Guide.md](SBE1V1K-OpenWrt-Guide.md)
- [SBE1V1K-UBOOT.md](SBE1V1K-UBOOT.md)

## Known limitations

- Device support is still experimental and not an official OpenWrt stable
  target.
- Stable NSS hardware routing acceleration is not available.
- More ten-cold-boot, fan-control, and long-duration throughput testing is
  required on additional units.
- The `US` default is only appropriate for hardware physically operated in the
  United States. Other deployments must select their lawful local domain.

## Credits and license

Based on OpenWrt, Andrew LaMarche's device work, and the integration maintained
by [luckkyboy/SBE1V1K](https://github.com/luckkyboy/SBE1V1K).
OpenWrt is licensed under GPL-2.0; individual files retain their upstream
licenses and copyright notices.
