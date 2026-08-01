# SBE1V1K Codex host validation

Result: PASS for build-time and host-side checks. Physical router validation is pending.

- OpenWrt full build completed with exit code 0.
- Generated initramfs, factory squashfs and sysupgrade tar images.
- `sha256sum -c sha256sums` passed for all target artifacts.
- Final sysupgrade tar lists exactly one board directory with `CONTROL`, `kernel` and `root`.
- The new validator accepted the final image and rejected both a truncated image and an image
  without its root payload.
- FIT inspection confirmed ARM64 Linux 6.18.39, load/entry `0x42080000`, SBE1V1K DTB and
  default configuration `config@rtq7300t-rev0`.
- Squashfs inspection confirmed the upgrade validator, runtime ucode multi-radio resolver,
  fallback resolver, release marker and diagnostic script.
- Squashfs file modes were checked after correcting NTFS-to-WSL permission mapping.
- The target AArch64 ucode interpreter, run under qemu-user, compiled both modified ucode
  scripts to bytecode successfully.
- The resolver's no-radio fallback path executed and returned the configured index.
- Manifest inspection confirmed LuCI HTTPS, Simplified Chinese, ath12k, ethtool-full,
  iperf3, pciutils and tcpdump-mini.

Not verified without the user's physical SBE1V1K:

- Boot, eMMC partition mapping and recovery behavior.
- Ethernet PHY mapping, link rates and throughput.
- 2.4/5/6 GHz RF operation and stability over repeated cold boots.
- Thermal sensor and fan response.
- Real power-loss behavior during an upgrade.
