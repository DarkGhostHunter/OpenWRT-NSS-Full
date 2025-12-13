include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tailscale
PKG_VERSION:=2025.11
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Italo ISrael Baeza Cabrera

LUCI_TITLE:=LuCI support for Tailscale
LUCI_DEPENDS:=+luci-base +tailscale +ethtool
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,luci-app-tailscale))