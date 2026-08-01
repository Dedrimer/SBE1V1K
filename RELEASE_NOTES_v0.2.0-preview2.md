# Stable Preview 2 / 稳定预览版 2

## 中文

这是 Spectrum/Askey SBE1V1K（RTQ7300T）的实验性 OpenWrt 主线预览固件。

主要修复：

- 美国部署设备默认监管域改为 `US`，修复 `country_code=00` 导致 hostapd
  无法启动的问题。
- 每次无线启动时动态解析 2.4/5/6GHz radio index，适应重启后 radio 编号变化。
- 三频共享 wiphy 时串行启动 hostapd，降低 ath12k vdev 初始化竞争和 6GHz
  热重载超时。
- sysupgrade 写入前强制检查 `CONTROL`、`kernel` 和 `root`，拒绝截断包。
- 实机连续 5 轮三频热重载通过，均保持 3 个 hostapd 和 3 个 SSID。

主要刷写文件：

```text
openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin
SHA-256: 09967f4742c9d428b1e3644e71ce936df440282edf9a80773eb65a5428ed339e
```

本固件仍为实验版本。刷写前必须备份，确认分区布局并准备串口或 HTTP
chainloader 恢复路径。不要通过 LuCI 刷入 `factory.bin`。

## English

This is an experimental mainline OpenWrt preview for the Spectrum/Askey
SBE1V1K (RTQ7300T).

Highlights:

- Defaults US-deployed units to the `US` regulatory domain, fixing hostapd
  rejection of generated `country_code=00`.
- Dynamically resolves 2.4/5/6GHz radio indices on every setup.
- Serializes hostapd setup on the shared multi-radio wiphy to avoid ath12k vdev
  races and 6GHz hot-reload timeouts.
- Rejects truncated sysupgrade archives unless `CONTROL`, `kernel`, and `root`
  are all present.
- Passed five consecutive hardware tri-band reload cycles with three hostapd
  objects and three SSIDs in every cycle.

Primary image:

```text
openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin
SHA-256: 09967f4742c9d428b1e3644e71ce936df440282edf9a80773eb65a5428ed339e
```

This is still experimental firmware. Back up the device, identify the exact
partition layout, and prepare a serial or HTTP-chainloader recovery path before
flashing. Never upload `factory.bin` through LuCI.
