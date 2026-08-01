# SBE1V1K OpenWrt — Codex Stable Preview 2

[简体中文](README.zh-CN.md) | [English](README.en.md)

An experimental, directly buildable OpenWrt source tree for the
Spectrum/Askey SBE1V1K (RTQ7300T), with hardware-tested fixes for stable
2.4/5/6 GHz ath12k operation.

这是面向 Spectrum/Askey SBE1V1K（RTQ7300T）的实验性 OpenWrt 完整源码树，
包含经过实机验证的 2.4/5/6 GHz ath12k 稳定性修复，可直接编译。

## Highlights / 主要特性

- Complete `qualcommbe/ipq95xx` OpenWrt build tree.
- Dynamic radio-index resolution for a shared multi-radio wiphy.
- US regulatory-domain default; fixes invalid `country_code=00` startup.
- Serialized hostapd setup to avoid ath12k vdev races during tri-band reload.
- Strict SBE1V1K sysupgrade archive validation.
- LuCI HTTPS, Simplified Chinese, diagnostics, iperf3 and networking tools.
- 实机 5 轮三频热重载：3 个 hostapd、3 个 SSID、新增启动错误为 0。

## Firmware / 固件

Use the GitHub Releases page. The primary image for an already installed
SBE1V1K OpenWrt/HTTP-chainloader system is:

已经安装 SBE1V1K OpenWrt 或 HTTP chainloader 的设备，主要使用：

```text
openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin
SHA-256: 09967f4742c9d428b1e3644e71ce936df440282edf9a80773eb65a5428ed339e
```

Do not flash `factory.bin` through LuCI. Read the installation guide and make
a full partition backup first. / 不要通过 LuCI 刷入 `factory.bin`；操作前必须阅读
刷机指南并完整备份分区。

## Documentation / 文档

- [中文项目说明](README.zh-CN.md)
- [English project guide](README.en.md)
- [源码、拆机与刷机指南](SBE1V1K-OpenWrt-Guide.md)
- [HTTP U-Boot / chainloader 指南](SBE1V1K-UBOOT.md)
- [Stable Preview 2 实机验证](VALIDATION-CODEX-20260801.md)
- [OpenWrt source history](README-SBE1V1K.md)

## Status and warning / 状态与警告

This remains experimental device support and is not an official OpenWrt
release. A serial console and a verified recovery path are strongly
recommended. Hardware acceleration is limited to the upstream PPE Ethernet
driver; no experimental QSDK ECM/NSS fast path is included.

本项目仍属于实验性设备支持，并非 OpenWrt 官方稳定版。强烈建议保留串口和已验证
的恢复路径。固件仅使用上游 PPE 以太网驱动，不包含实验性 QSDK ECM/NSS 快速转发。

## Credits / 致谢

Based on OpenWrt, the original SBE1V1K work by Andrew LaMarche, and the source
integration maintained by [luckkyboy/SBE1V1K](https://github.com/luckkyboy/SBE1V1K).
See the detailed source-history document for exact commits and provenance.

基于 OpenWrt、Andrew LaMarche 的 SBE1V1K 设备支持，以及
[luckkyboy/SBE1V1K](https://github.com/luckkyboy/SBE1V1K) 的源码整合。
精确提交和来源见源码历史文档。

## License / 许可证

OpenWrt is licensed under GPL-2.0. Individual files retain their upstream
licenses and copyright notices. / OpenWrt 使用 GPL-2.0；各文件继续保留其上游
许可证和版权声明。
