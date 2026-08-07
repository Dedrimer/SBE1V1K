include $(TOPDIR)/rules.mk

LUCI_TITLE:=SBE1V1K Network Mode Switch
LUCI_DESCRIPTION:=Quickly switch Askey SBE1V1K between main router, bypass router and repeater modes
LUCI_DEPENDS:=+luci-base +relayd
LUCI_PKGARCH:=all

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Codex <noreply@localhost>

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/sbe1v1k_netmode
endef

# call BuildPackage - OpenWrt buildroot signature
