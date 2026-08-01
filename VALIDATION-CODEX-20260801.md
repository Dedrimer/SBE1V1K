# SBE1V1K Codex Stable Preview 2 Validation

## Fixes verified

- The SBE1V1K board defaults now provide the `US` regulatory domain.
  Fresh wireless configuration therefore no longer writes the invalid
  `country_code=00` which made hostapd reject all three APs.
- The mac80211 ucode backend resolves the current ath12k radio index from
  the requested 2.4, 5, or 6 GHz frequency range on every setup.
- hostapd setup is serialized when several radios share one wiphy.  The
  per-PHY runtime lock remains held for four seconds after each setup so
  ath12k can finish vdev startup before the next band is configured.

## Hardware regression test

Tested on the flashed Askey SBE1V1K through wired SSH:

- 5 consecutive `wifi reload` cycles completed.
- Every cycle reported 3 hostapd ubus objects and 3 active SSIDs.
- No new `failed to start vdev`, `Interface initialization failed`,
  `hostapd.add_iface failed`, or `Failed to set beacon parameters` event.
- Final frequencies were 2412 MHz, 5180 MHz, and 5955 MHz.

## Image checks

- All entries in `sha256sums` passed.
- Sysupgrade tar contains `CONTROL`, `kernel`, and `root`.
- The negative validator rejected truncated and missing-root archives.
- SquashFS extraction confirmed the Preview 2 release marker, `US` board
  default, and multi-radio setup lock in the actual root payload.
- FIT inspection confirmed Linux 6.18.39, the SBE1V1K DTB, and default
  configuration `config@rtq7300t-rev0`.

## Primary image

`openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin`

SHA-256:

`09967f4742c9d428b1e3644e71ce936df440282edf9a80773eb65a5428ed339e`
