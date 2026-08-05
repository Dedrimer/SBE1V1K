# SBE1V1K OpenWrt 源码分支

本仓库的 `main` 本身就是完整 OpenWrt 源码树，以 Andrew LaMarche 的 SBE1V1K 设备提交 `525e6238f4` 为设备支持基线，并已同步 OpenWrt 官方 `main` 至 `bd7188a81e`。克隆后不需要运行源码生成脚本，也不需要再克隆另一个 OpenWrt 仓库。

## 源码提交组成

```text
3858b913cc Merge OpenWrt upstream/main
c221a773d6 ipq-wifi: vendor Askey SBE1V1K BDF
72dce28ee0 wifi-scripts: support multiple candidate PCI paths
d5ed1d2f5d wifi: ath12k: set per-radio MAC address from DT
6942f0be45 Merge SBE1V1K project history onto OpenWrt
525e6238f4 qualcommbe: add support for Askey SBE1V1K
```

- `525e6238f4` 是 [PR 作者分支](https://github.com/andrewjlamarche/openwrt/tree/sbe1v1k)的设备支持提交。
- `d5ed1d2f5d` 来自 OpenWrt PR #23786 的 ath12k per-radio MAC 修复。
- `72dce28ee0` 是多候选 PCI 路径方案的早期本地集成；OpenWrt 官方实现现已作为 `2c64257627` 合入，并在合并时采用官方版本。
- `c221a773d6` 固定 firmware_qca-wireless PR #123 的 SBE1V1K QCN9274 BDF。
- `3858b913cc` 将 OpenWrt 官方 `main` 的 20 个后续提交同步到本分支。

`author-head` 分支严格指向 Andrew 的代码，用于比较；`project-meta` 保留迁移前的脚本/补丁项目历史。推荐编译 `main`。

## Ubuntu / WSL2 编译

推荐在仓库根目录运行全自动脚本。它会识别 Debian/Ubuntu、Fedora/RHEL、Arch
或 openSUSE，安装编译依赖、同步锁定的 feeds、载入 SBE1V1K 配置、下载源码并完成编译：

```bash
bash ./build-sbe1v1k.sh
```

可用 `bash ./build-sbe1v1k.sh --help` 查看并行数、清理构建和仅下载等选项。脚本会继承
`HTTP_PROXY`、`HTTPS_PROXY` 等标准代理环境变量。固件默认使用 Argon 主题并预置
iStore，同时包含 LuCI 软件包管理器、Docker、Aria2、Samba、文件管理器、Web 终端、
SmartDNS、广告过滤、流量统计、SQM、DDNS、UPnP、WireGuard 和 eMMC 管理工具。
OpenWrt 官方 feeds、Argon 与 iStore 源均固定到精确提交以便复现构建。
脚本会统计固件编译耗时，所有固件、软件包索引和构建信息统一写入根目录 `out/`；
需要清理输出时可直接删除该目录，`out/` 已加入 `.gitignore`。

也可以手动执行以下步骤。

先安装依赖：

```bash
sudo apt update
sudo apt install -y \
  build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
  gettext git libncurses-dev libssl-dev python3-setuptools rsync swig \
  unzip zlib1g-dev file wget bc bzip2 libelf-dev liblzma-dev \
  python3-dev time xxd zstd
```

然后直接在本仓库根目录编译：

```bash
git clone https://github.com/yintaomu/SBE1V1K-OpenWrt.git
cd SBE1V1K

# WSL 用户应避免继承包含 Windows “Program Files”的 PATH，
# 否则 find -execdir 会在 package/install 阶段拒绝执行。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

cp configs/sbe1v1k.config .config
./scripts/feeds update -a
patch --batch --forward -d feeds/istore -p1 < config/istore-openwrt-main.patch
./scripts/feeds install -a
mkdir -p feeds/argon
git -C feeds/argon init
git -C feeds/argon remote add origin https://github.com/jerrykuku/luci-theme-argon.git
git -C feeds/argon fetch --depth 1 origin 136eb5d42f30554e89cc737fd90f503909810660
git -C feeds/argon checkout --detach --force FETCH_HEAD
mkdir -p package/feeds/argon
rsync -a --delete --exclude=.git/ feeds/argon/ package/feeds/argon/luci-theme-argon/
make defconfig
make download -j"$(nproc)"
make -j"$(nproc)" world
```

五个官方 feeds 已在 `feeds.conf.default` 中固定到精确提交。目标输出在：

```text
out/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-initramfs-uImage.itb
out/targets/qualcommbe/ipq95xx/openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-squashfs-sysupgrade.bin
```

本次固件编译耗时保存在 `out/build-time.txt`。

若并行构建失败：

```bash
make -j1 V=s
```

详细支持状态、拆机与刷机步骤见 `SBE1V1K-OpenWrt-Guide.md`。可选的 HTTP U-Boot chainloader 用法见 `SBE1V1K-UBOOT.md`。
