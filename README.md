# SBE1V1K Nexus Firmware

This branch keeps the applications and Argon interface from
`naoki66/ImmortalWrt-for-Gemtek-XR1710G`, while replacing every hardware
boundary with the validated Askey/Spectrum SBE1V1K port.

## Safety boundary

- Target: `qualcommbe/ipq95xx`, device `askey_sbe1v1k` only.
- Hardware: Qualcomm IPQ9574 with three QCN9274 radios.
- Storage: factory-compatible SBE1V1K eMMC layout.
- Wi-Fi: the SBE1V1K BDF, ART calibration extraction, stable radio-index
  resolver, serialized shared-wiphy startup, and US regulatory domain.
- Upgrade: rejects a wrong model or incomplete archive before any write;
  writes rootfs first and kernel last.
- Excluded: XR1710G Airoha AN7581 DTS, MT7996 firmware, NPU, fan-control and
  MLO packages. They are incompatible with this router.

Optional proxy and DNS applications are included but disabled on first boot.
No login or Wi-Fi password is embedded in published images.

## Build

```sh
./scripts/feeds update -a
./scripts/feeds install -a
cp configs/sbe1v1k-nexus-mainline.config .config
make defconfig
make download -j8
make -j$(nproc)
```

Use the generated `sysupgrade.bin` only from a currently running OpenWrt for
SBE1V1K. Keep settings disabled for the first upgrade of a different firmware
family.
