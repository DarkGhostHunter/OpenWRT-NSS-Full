include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-plexmediaserver
PKG_VERSION:=2.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Italo ISrael Baeza Cabrera

LUCI_TITLE:=LuCI support for Plex Media Server
LUCI_DEPENDS:=+luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,luci-app-plexmediaserver))