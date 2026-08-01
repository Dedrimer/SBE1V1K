# SBE1V1K Codex 稳定预览版 2

这是为 Askey/Spectrum SBE1V1K 编译的 OpenWrt 主线预览固件，基于
`luckkyboy/SBE1V1K` 的 `qualcommbe/ipq95xx` 支持。为了优先保证稳定性，
没有混入 LEDE/QSDK 的实验性 ECM/NSS 快速转发栈。

## 文件用途

- `*-initramfs-uImage.itb`：内存启动和救援测试，不写入持久 rootfs。
- `*-squashfs-sysupgrade.bin`：已经运行 SBE1V1K OpenWrt 时使用的升级包。
- `*-squashfs-factory.bin`：初次安装流程使用的纯 squashfs rootfs；不要把它
  上传到 LuCI 的“刷写固件”页面，也不要直接刷到内核分区。

## 本地修复

- sysupgrade 进入升级环境前完整扫描 tar，并要求 `CONTROL/kernel/root` 齐全，
  阻止截断包造成内核与 rootfs 版本不一致。
- 保留 OpenWrt 主线 eMMC 的安全顺序：先使旧内核失效、写 rootfs、最后写新内核。
- ath12k 每次启动无线时按实际 2.4/5/6 GHz 频段解析 radio index，降低三频
  radio 编号在重启后变化造成 Wi-Fi 配错的概率。
- SBE1V1K 默认监管域改为 `US`，不再生成会被 hostapd 拒绝的国家码 `00`；
  6 GHz 可在美国法规允许的信道上正常启动。
- 同一个 wiphy 上的三路 hostapd 配置改为串行执行，每路启动后等待 ath12k
  完成 vdev 初始化，避免热重载时三路并发造成 6 GHz 超时。
- 包含 LuCI HTTPS、简体中文、iperf3、ethtool、pciutils、tcpdump-mini 和
  `sbe1v1k-diag` 诊断脚本。

## 刷写前

1. 强烈建议先用 initramfs 启动并确认 LAN/WAN、eMMC、风扇和三频 Wi-Fi。
2. 备份原机分区表、校准数据和当前可用固件；不要覆盖 ART/校准分区。
3. 在路由器上运行 `sysupgrade -T <sysupgrade.bin>`，必须显示可接受再继续。
4. 从 LEDE/QSDK 固件切换到此主线版本时建议清空旧配置，避免旧无线和加速配置残留：

   ```sh
   sysupgrade -n /tmp/openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin
   ```

刷写有断电和设备差异风险。电脑端验证不能代替实机验证；没有串口或可用救援路径时，
不要直接写入持久固件。

## 首次启动检查

```sh
sbe1v1k-diag > /tmp/sbe1v1k-diag.txt 2>&1
iw phy
ip -br link
ethtool <网口名>
```

至少做 10 次冷启动，确认 2.4 GHz、5 GHz、6 GHz 每次都绑定到正确频段，
并分别验证三个 LAN 口与 WAN 口的链路和吞吐。

全新清空配置安装仍遵循 OpenWrt 的默认安全策略：无线 SSID 默认关闭，root
默认无密码，首次进入 LuCI 后应立即设置登录密码并配置加密 Wi-Fi。普通
sysupgrade 保留配置时，现有 SSID 和密码会继续保留；密码没有硬编码进镜像。

## SHA-256

```text
e176d7521ae7fde443fa52f035b34a4ebf2691d3e4963cde3b7965d92d2d52ae  openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-initramfs-uImage.itb
6498c6017980a48c0ee6c6376bf76a3181eec8a6b22cfbc8d8b94c468434abcc  openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-factory.bin
09967f4742c9d428b1e3644e71ce936df440282edf9a80773eb65a5428ed339e  openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin
```
