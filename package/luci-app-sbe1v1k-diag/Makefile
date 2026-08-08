include $(TOPDIR)/rules.mk

LUCI_TITLE:=SBE1V1K Hardware Diagnostics
LUCI_DESCRIPTION:=Reads thermal/fan state, PPE/EIP debugfs nodes, hardware counters and offload state on Askey SBE1V1K (IPQ9574)
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Codex <noreply@localhost>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
