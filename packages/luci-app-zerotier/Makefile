include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-zerotier
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Italo ISrael Baeza Cabrera

LUCI_TITLE:=LuCI support for Zerotier
LUCI_DEPENDS:=+luci-base +tailscale +ethtool
LUCI_PKGARCH:=all

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/luci/luci.mk

# Call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,luci-app-zerotier))