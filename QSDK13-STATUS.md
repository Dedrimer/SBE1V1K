# QSDK 13 integration status / QSDK 13 集成状态

## English

The obsolete CodeAurora workflow described by older QSDK articles has moved to CodeLinaro. The reproducible public baseline selected for this project is:

- Manifest repository: `https://git.codelinaro.org/clo/qsdk/releases/manifest/qstak.git`
- Manifest: `NHSS.QSDK.13.1.5.r2-00023-O.xml`
- Variant: Open (`-O`)
- OpenWrt base: 24.x
- Kernel: Qualcomm Linux 6.6

The manifest was fully synchronized and inspected. It contains the IPQ9574 target, NSS DP/PPE/ECM/SSDK sources, the open WLAN stack, and an RDP433 reference DTS. RDP433 uses three external WLAN devices with board IDs `0x01`, `0x04`, and `0x02`, matching the three SBE1V1K calibration variants. This makes a real QSDK 13 port feasible.

It is not yet safe to flash an unmodified RDP433 build. Its Ethernet PHY map, LEDs, fan, eMMC layout, network defaults, and QSDK multi-section upgrade path differ from SBE1V1K. A QSDK image must receive a dedicated board DTS and the proven SBE1V1K eMMC upgrade guard before it can be called a test image.

The Linux 6.18 mainline build remains the recommended firmware. QSDK 13 is experimental until it passes build-time checks and real-device recovery-mode testing.

## 中文

旧文章使用的 CodeAurora 流程已经迁移到 CodeLinaro。本项目选择的可复现公开基线为：

- 清单仓库：`https://git.codelinaro.org/clo/qsdk/releases/manifest/qstak.git`
- 清单文件：`NHSS.QSDK.13.1.5.r2-00023-O.xml`
- 类型：开放版（`-O`）
- OpenWrt 基线：24.x
- 内核：Qualcomm Linux 6.6

该清单已经完整同步并检查，包含 IPQ9574、NSS DP/PPE/ECM/SSDK、开放 WLAN 栈以及 RDP433 参考设备树。RDP433 的三张外置无线卡使用 `0x01`、`0x04`、`0x02` 三个 board ID，与 SBE1V1K 的三个校准变体一致，因此真正的 QSDK 13 移植具备可行性。

不能直接刷原始 RDP433 镜像：它的网口 PHY、LED、风扇、eMMC 分区、网络默认值和 QSDK 多段升级流程均与 SBE1V1K 不同。只有完成专用设备树以及已验证的 SBE1V1K eMMC 升级保护后，才可以标为测试固件。

目前推荐使用 Linux 6.18 主线版；QSDK 13 在完成编译检查和真机恢复模式验证前均为实验项目。
