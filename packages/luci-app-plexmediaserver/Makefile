include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-plexmediaserver
PKG_VERSION:=2.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Custom User
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-plexmediaserver
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Support for Plex Media Server (Modern JS)
  DEPENDS:=+luci-base +curl +unzip +kmod-fs-squashfs +ntfs-3g +mount-utils
  PKGARCH:=all
endef

define Package/luci-app-plexmediaserver/description
  This package provides a Modern LuCI web interface and init script
  to manage Plex Media Server on OpenWRT.
endef

define Build/Compile
endef

define Package/luci-app-plexmediaserver/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d

	# Install the init script
	$(INSTALL_BIN) ./files/init.d/plexmediaserver $(1)/etc/init.d/plexmediaserver

	# Install the config file
	$(INSTALL_CONF) ./files/etc/config/plexmediaserver $(1)/etc/config/plexmediaserver

	# Install Modern Menu Definition
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-plexmediaserver.json $(1)/usr/share/luci/menu.d/luci-app-plexmediaserver.json

	# Install Modern JavaScript View
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/plexmediaserver.js $(1)/www/luci-static/resources/view/plexmediaserver.js

	# Install ACL file
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-plexmediaserver.json $(1)/usr/share/rpcd/acl.d/luci-app-plexmediaserver.json
endef

$(eval $(call BuildPackage,luci-app-plexmediaserver))