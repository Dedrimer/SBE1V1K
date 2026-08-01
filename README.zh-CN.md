# SBE1V1K OpenWrt 中文说明

[English](README.en.md) | [项目首页](README.md)

## 项目定位

本仓库是 Spectrum/Askey SBE1V1K（别名 RTQ7300T）的完整 OpenWrt
`qualcommbe/ipq95xx` 源码树。Stable Preview 2 以稳定和可恢复为优先，不混入
实验性 LEDE/QSDK ECM/NSS 快速转发栈。

该机型支持尚未成为 OpenWrt 官方稳定版本，因此固件适合能够使用串口、HTTP
chainloader 或其他恢复手段的高级用户。

## Stable Preview 2 修复

- 每次启动无线时，根据实际频率范围解析 2.4/5/6GHz radio index，避免重启后
  radio 编号变化导致频段错配。
- 美国部署版本默认监管域为 `US`，不再生成 hostapd 无法接受的国家码 `00`。
- 三路 radio 共用一个 wiphy 时，hostapd 按顺序启动，每路等待 4 秒让 ath12k
  完成 vdev 初始化，避免热重载时 6GHz 超时。
- sysupgrade 写入前完整检查 tar，必须包含 `CONTROL`、`kernel` 和 `root`，拒绝
  截断或缺少成员的升级包。
- 包含 LuCI HTTPS、简体中文、`sbe1v1k-diag`、iperf3、ethtool、pciutils 和
  tcpdump-mini。

## 实机验证

- LAN 管理地址 `192.168.1.1` 正常。
- WAN DHCP 正常。
- 2.4GHz、5GHz、6GHz 分别在 2412、5180、5955MHz 正常建立 AP。
- 连续 5 轮 `wifi reload`，每轮均为 3 个 hostapd、3 个 SSID。
- 未新增 `failed to start vdev`、`hostapd.add_iface failed` 或 beacon 初始化错误。

完整记录见 [VALIDATION-CODEX-20260801.md](VALIDATION-CODEX-20260801.md)。

## 编译

推荐 Ubuntu 24.04 或 WSL2 Ubuntu 24.04，并将源码放到 Linux 文件系统中：

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

输出目录：

```text
bin/targets/qualcommbe/ipq95xx/
```

## 固件选择

- `*-initramfs-uImage.itb`：内存启动、首次测试或救援，不持久写入 rootfs。
- `*-squashfs-sysupgrade.bin`：已经运行 SBE1V1K OpenWrt 或通过 HTTP
  chainloader 安装/升级时使用。
- `*-squashfs-factory.bin`：纯 squashfs rootfs；不要上传到 LuCI，也不要写入
  内核分区。

Preview 2 sysupgrade：

```text
SHA-256: 09967f4742c9d428b1e3644e71ce936df440282edf9a80773eb65a5428ed339e
```

## 刷机警告

1. 先备份 eMMC boot0、boot1、GPT 和关键分区。
2. 确认当前是 mainline、原厂 A/B 还是第三方 large 布局，不能混用流程。
3. HTTP chainloader 用户优先从 `192.168.255.1` 的 Firmware 页面上传
   sysupgrade 镜像。
4. 写入期间保持稳定供电、网线和浏览器连接，禁止断电。
5. 全新清空配置后，OpenWrt 默认关闭无线且 root 无密码；首次进入 LuCI 后立即
   设置登录密码并配置加密 Wi-Fi。密码不会硬编码到公开固件。

具体步骤见：

- [SBE1V1K-OpenWrt-Guide.md](SBE1V1K-OpenWrt-Guide.md)
- [SBE1V1K-UBOOT.md](SBE1V1K-UBOOT.md)

## 已知限制

- 仍不是 OpenWrt 官方稳定支持。
- 没有稳定的 NSS 硬件路由加速。
- 仍需更多设备完成十次冷启动、风扇温控和长时间吞吐验证。
- 固件默认 `US` 仅适用于实际位于美国的设备；其他国家必须改为当地合法监管域。

## 来源和许可证

项目基于 OpenWrt、Andrew LaMarche 的设备支持和
[luckkyboy/SBE1V1K](https://github.com/luckkyboy/SBE1V1K) 的整合工作。
OpenWrt 使用 GPL-2.0，各文件继续保留其原有许可证和版权声明。
