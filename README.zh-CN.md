# SBE1V1K Nexus 固件

本分支保留 `naoki66/ImmortalWrt-for-Gemtek-XR1710G` 的应用功能和 Argon
界面，但所有硬件边界均替换为已经在真机验证的 Askey/Spectrum SBE1V1K
适配。

## 安全边界

- 目标仅为 `qualcommbe/ipq95xx` 的 `askey_sbe1v1k`。
- 硬件为 Qualcomm IPQ9574 和三颗 QCN9274。
- 使用兼容原厂的 SBE1V1K eMMC 分区布局。
- Wi-Fi 使用本机 BDF、ART 校准提取、稳定 radio 序号解析、共享 wiphy
  串行启动以及美国区域码。
- 升级前严格校验机型及归档完整性；先写 rootfs，最后写 kernel，降低
  意外中断时的变砖风险。
- 不包含 XR1710G 专属的 Airoha AN7581 设备树、MT7996 固件、NPU、
  风扇控制和 MLO 插件，这些组件与本机硬件不兼容。

PassWall、OpenClash、AdGuardHome 等可选应用会预装，但首次启动默认
禁用，配置完成后再手动启用。公开镜像不会预置登录密码或 Wi-Fi 密码。

## 编译

```sh
./scripts/feeds update -a
./scripts/feeds install -a
cp configs/sbe1v1k-nexus-mainline.config .config
make defconfig
make download -j8
make -j$(nproc)
```

从已经运行 SBE1V1K OpenWrt 的系统升级时使用 `sysupgrade.bin`。跨固件
系列首次升级建议不保留配置。
