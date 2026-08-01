# Reproducible source build / 可复现源码构建

This repository branch is a compact, complete patch set. It avoids copying the
entire upstream Git history while preserving every SBE1V1K source change.

本分支保存完整的 SBE1V1K 补丁集，不重复上传庞大的上游 Git 历史，但不会遗漏任何本机适配改动。

```sh
git clone https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git
cd ImmortalWrt-for-Gemtek-XR1710G
git checkout 5747ad32a4b3ef2484d0b01a5af91ea140b29630
git am /path/to/SBE1V1K-Nexus-Public-Source/patches/*.patch
cp configs/sbe1v1k-nexus-mainline.config .config
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
make download -j8
make -j$(nproc)
```

The expected target is `qualcommbe/ipq95xx/askey_sbe1v1k`. Use the generated
`sysupgrade.bin` for upgrades from a compatible SBE1V1K OpenWrt installation.

预期目标为 `qualcommbe/ipq95xx/askey_sbe1v1k`。从兼容的 SBE1V1K OpenWrt
升级时使用生成的 `sysupgrade.bin`。
