include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-plexmediaserver
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Custom User
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-plexmediaserver
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Support for Plex Media Server
  DEPENDS:=+luci-base +luci-mod-admin-full +curl +unzip +kmod-fs-squashfs +ntfs-3g +mount-utils
  PKGARCH:=all
endef

define Package/luci-app-plexmediaserver/description
  This package provides a LUCI web interface and init script 
  to manage Plex Media Server on OpenWRT.
endef

define Build/Compile
endef

define Package/luci-app-plexmediaserver/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d

	# Install the init script (executable)
	$(INSTALL_BIN) ./files/etc/init.d/plexmediaserver $(1)/etc/init.d/plexmediaserver

	# Install the config file (if exists, otherwise touch it)
	[ -f ./files/etc/config/plexmediaserver ] && $(INSTALL_CONF) ./files/etc/config/plexmediaserver $(1)/etc/config/plexmediaserver || touch $(1)/etc/config/plexmediaserver

	# Install Lua files
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/plexmediaserver.lua $(1)/usr/lib/lua/luci/controller/plexmediaserver.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/plexmediaserver.lua $(1)/usr/lib/lua/luci/model/cbi/plexmediaserver.lua

	# Install ACL file
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-plexmediaserver.json $(1)/usr/share/rpcd/acl.d/luci-app-plexmediaserver.json
endef

$(eval $(call BuildPackage,luci-app-plexmediaserver))