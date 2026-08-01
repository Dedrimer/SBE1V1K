# SBE1V1K Codex Stable Preview

This build is a stability-first OpenWrt image for the Askey/Spectrum
SBE1V1K. It is based on the repository's mainline `qualcommbe/ipq95xx`
port and intentionally excludes the experimental LEDE QSDK PPE/ECM stack.

## Local fixes

- Reject incomplete or malformed eMMC sysupgrade tar archives before reboot.
- Require `CONTROL`, `kernel`, and `root` payloads for SBE1V1K upgrades.
- Keep the mainline rootfs-first/kernel-last eMMC upgrade sequence.
- Resolve ath12k multi-radio indices from the requested band at every setup,
  avoiding persistent dependence on non-deterministic radio numbering.
- Set the SBE1V1K deployment regulatory domain to `US` so hostapd never
  receives the invalid generated country code `00`, including on 6 GHz.
- Serialize hostapd setup on a shared multi-radio wiphy and allow four seconds
  for ath12k vdev startup before configuring the next band.
- Include LuCI HTTPS, Simplified Chinese, iperf3, ethtool, pciutils and
  tcpdump-mini for initial validation.
- Include `/usr/bin/sbe1v1k-diag` for collecting a first-boot report.

## Build

```sh
./scripts/feeds update -a
./scripts/feeds install -a
cp configs/sbe1v1k.config .config
make defconfig
make download -j8
make -j8 V=s
```

## Host-side checks

```sh
./sbe1v1k-tests/test-upgrade-validation.sh
tar tf bin/targets/qualcommbe/ipq95xx/*sbe1v1k*sysupgrade.bin
sha256sum bin/targets/qualcommbe/ipq95xx/*sbe1v1k*
```

## Required hardware validation

Do not flash the persistent image before the initramfs image has booted and
the following have been confirmed on the exact unit:

1. eMMC partitions and ART calibration data are readable.
2. LAN1/LAN2/LAN3 and WAN link and pass traffic at their expected speeds.
3. 2.4 GHz, 5 GHz and 6 GHz radios are each detected on ten cold boots.
4. The fan changes speed with thermal state and never remains stopped hot.
5. `sysupgrade -T` accepts only the matching, complete image.

After initramfs testing, collect a report with:

```sh
sbe1v1k-diag > /tmp/sbe1v1k-diag.txt 2>&1
```

This preview cannot be called hardware-validated until those results are
recorded from a physical SBE1V1K.
