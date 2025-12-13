include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pairdrop
PKG_VERSION:=1.0.0
PKG_RELEASE:=4

PKG_MAINTAINER:=OpenWRT Community
PKG_LICENSE:=GPL-3.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-pairdrop
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=PairDrop (Runtime Downloader)
  # Dependencies:
  # - coturn-server: Pre-installed/System requirement per prompt
  # - kmod-fs-squashfs, kmod-loop, liblz4: For mounting the app
  # - squashfs-tools-mksquashfs: To create the image on the router
  # - wget-ssl, ca-bundle, tar: To download and extract resources
  DEPENDS:=+luci-base +coturn-server +kmod-fs-squashfs +kmod-loop +liblz4 \
           +squashfs-tools-mksquashfs +wget-ssl +ca-bundle +tar
  PKGARCH:=all
endef

define Package/luci-app-pairdrop/description
  A lightweight package that downloads and installs PairDrop and Node.js
  onto external storage (/mnt/sda1) at runtime.
  Creates an LZ4 compressed SquashFS image to save space.
endef

$(eval $(call BuildPackage,luci-app-pairdrop))