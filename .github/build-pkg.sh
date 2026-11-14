#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# 直接打包脚本（参考 homeproxy 的 build-ipk.sh），绕过 buildroot/SDK，
# 用 apk-tools / ipkg-build / po2lmo 直接把源码打成 apk 与 ipk。

set -o errexit
set -o pipefail

PKG_MGR="${1:-apk}"

export PKG_SOURCE_DATE_EPOCH="$(date "+%s")"
export SOURCE_DATE_EPOCH="$PKG_SOURCE_DATE_EPOCH"

BASE_DIR="$(cd "$(dirname $0)"; pwd)"
PKG_DIR="$BASE_DIR/.."

function get_mk_value() {
	awk -F "$1:=" '{print $2}' "$PKG_DIR/Makefile" | xargs
}

PKG_NAME="$(get_mk_value "PKG_NAME")"
# Prefer PKG_VERSION/PKG_RELEASE from Makefile, fall back to a
# snapshot-style timestamp version when they are not defined
PKG_VERSION="$(get_mk_value "PKG_VERSION")"
PKG_RELEASE="$(get_mk_value "PKG_RELEASE")"
if [ -n "$PKG_VERSION" ] && [ -n "$PKG_RELEASE" ]; then
	PKG_VERSION="$PKG_VERSION-r$PKG_RELEASE"
else
	PKG_VERSION="$PKG_SOURCE_DATE_EPOCH~$(git rev-parse --short HEAD)-r99"
fi

# 用模板形式而非 GNU 专有的 mktemp -p，保证 macOS 上也能本地构建
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/luci-app-ipsec-vpnd-build.XXXXXX")"
TEMP_PKG_DIR="$TEMP_DIR/$PKG_NAME"
mkdir -p "$TEMP_PKG_DIR/lib/upgrade/keep.d/"
mkdir -p "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/"
mkdir -p "$TEMP_PKG_DIR/www/"
if [ "$PKG_MGR" == "apk" ]; then
	mkdir -p "$TEMP_PKG_DIR/lib/apk/packages/"
else
	mkdir -p "$TEMP_PKG_DIR/CONTROL/"
fi

cp -fpR "$PKG_DIR/htdocs"/* "$TEMP_PKG_DIR/www/"
cp -fpR "$PKG_DIR/root"/* "$TEMP_PKG_DIR/"

# 排除 macOS 的 .DS_Store 等垃圾文件，别把它们打进包里
find "$TEMP_PKG_DIR" -name '.DS_Store' -delete

cat > "$TEMP_PKG_DIR/lib/upgrade/keep.d/$PKG_NAME" <<-EOF
/etc/config/ipsec-vpnd
EOF

po2lmo "$PKG_DIR/po/zh_Hans/ipsec-vpnd.po" "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/ipsec-vpnd.zh-cn.lmo"
# Move lmo out, i18n package will handle it
mv "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/ipsec-vpnd.zh-cn.lmo" "$TEMP_DIR/ipsec-vpnd.zh-cn.lmo"

if [ "$PKG_MGR" == "apk" ]; then
	# 用 find + sed 而非 GNU 专有的 -printf，保证 macOS 上也能本地构建
	( cd "$TEMP_PKG_DIR" && find . -type f,l | sed 's|^\./|/|' ) | sort > "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.list"
	echo "/etc/config/ipsec-vpnd" >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"
	cat "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles" | while IFS= read -r file; do
		[ -f "$TEMP_PKG_DIR/$file" ] || continue
		# sha256sum 是 GNU 的，macOS 上用 shasum -a 256
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum "$TEMP_PKG_DIR/$file"
		else
			shasum -a 256 "$TEMP_PKG_DIR/$file"
		fi | sed "s,$TEMP_PKG_DIR/,," >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles_static"
	done

	echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_postinst
[ -n "${IPKG_INSTROOT}" ] || { [ -x /etc/init.d/ipsec ] && { /etc/init.d/ipsec disable 2>/dev/null; /etc/init.d/ipsec stop 2>/dev/null; }
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	/sbin/ifup VPN >/dev/null 2>&1
	exit 0
}' > "$TEMP_DIR/post-install"

	echo -e '#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_postinst
[ -n "${IPKG_INSTROOT}" ] || { [ -x /etc/init.d/ipsec ] && { /etc/init.d/ipsec disable 2>/dev/null; /etc/init.d/ipsec stop 2>/dev/null; }
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	/sbin/ifup VPN >/dev/null 2>&1
	exit 0
}' > "$TEMP_DIR/post-upgrade"

	echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_prerm' > "$TEMP_DIR/pre-deinstall"

	apk mkpkg \
		--info "name:$PKG_NAME" \
		--info "version:$PKG_VERSION" \
		--info "description:LuCI support for IPSec VPN Server (IKEv1 with PSK and Xauth)" \
		--info "arch:noarch" \
		--info "origin:https://github.com/szwjp/luci-app-ipsec-vpnd" \
		--info "url:https://github.com/szwjp/luci-app-ipsec-vpnd" \
		--info "maintainer:szwjp <szwjp@users.noreply.github.com>" \
		--info "provides:" \
		--script "post-install:$TEMP_DIR/post-install" \
		--script "post-upgrade:$TEMP_DIR/post-upgrade" \
		--script "pre-deinstall:$TEMP_DIR/pre-deinstall" \
		--info "depends:libc kmod-tun strongswan-minimal strongswan-mod-xauth-generic strongswan-mod-kernel-libipsec strongswan-mod-des" \
		--files "$TEMP_PKG_DIR" \
		--output "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk"

	mv "$TEMP_DIR/${PKG_NAME}-${PKG_VERSION}.apk" "$BASE_DIR/${PKG_NAME}-${PKG_VERSION}.apk"
else
	mkdir -p "$TEMP_PKG_DIR/CONTROL/"

	cat > "$TEMP_PKG_DIR/CONTROL/control" <<-EOF
		Package: $PKG_NAME
		Version: $PKG_VERSION
		Depends: libc, kmod-tun, strongswan-minimal, strongswan-mod-xauth-generic, strongswan-mod-kernel-libipsec, strongswan-mod-des
		Source: https://github.com/szwjp/luci-app-ipsec-vpnd
		SourceName: $PKG_NAME
		Section: luci
		SourceDateEpoch: $PKG_SOURCE_DATE_EPOCH
		Maintainer: szwjp <szwjp@users.noreply.github.com>
		Architecture: all
		Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
		Description:  LuCI support for IPSec VPN Server (IKEv1 with PSK and Xauth)
	EOF
	chmod 0644 "$TEMP_PKG_DIR/CONTROL/control"

	echo -e "/etc/config/ipsec-vpnd" > "$TEMP_PKG_DIR/CONTROL/conffiles"

	echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@' > "$TEMP_PKG_DIR/CONTROL/postinst"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst"

	echo -e "[ -n "\${IPKG_INSTROOT}" ] || {
	[ -x /etc/init.d/ipsec ] && { /etc/init.d/ipsec disable 2>/dev/null; /etc/init.d/ipsec stop 2>/dev/null; }
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	/sbin/ifup VPN >/dev/null 2>&1
	exit 0
}" > "$TEMP_PKG_DIR/CONTROL/postinst-pkg"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst-pkg"

	echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@' > "$TEMP_PKG_DIR/CONTROL/prerm"
	chmod 0755 "$TEMP_PKG_DIR/CONTROL/prerm"

	ipkg-build -m "" "$TEMP_PKG_DIR" "$TEMP_DIR"

	mv "$TEMP_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${PKG_NAME}-${PKG_VERSION}.ipk"
fi

I18N_NAME="luci-i18n-ipsec-vpnd-zh-cn"
I18N_DIR="$TEMP_DIR/$I18N_NAME"
mkdir -p "$I18N_DIR/usr/lib/lua/luci/i18n/"
cp "$TEMP_DIR/ipsec-vpnd.zh-cn.lmo" "$I18N_DIR/usr/lib/lua/luci/i18n/"

if [ "$PKG_MGR" == "apk" ]; then
	( cd "$I18N_DIR" && find . -type f,l | sed 's|^\./|/|' ) | sort > "$TEMP_DIR/i18n.list"
	apk mkpkg \
		--info "name:$I18N_NAME" \
		--info "version:$PKG_VERSION" \
		--info "description:IPSec VPN Server Chinese translation" \
		--info "arch:noarch" \
		--info "depends:$PKG_NAME" \
		--files "$I18N_DIR" \
		--output "$TEMP_DIR/${I18N_NAME}-${PKG_VERSION}.apk"
	mv "$TEMP_DIR/${I18N_NAME}-${PKG_VERSION}.apk" "$BASE_DIR/${I18N_NAME}-${PKG_VERSION}.apk"
else
	mkdir -p "$I18N_DIR/CONTROL/"
	cat > "$I18N_DIR/CONTROL/control" <<-EOFCTRL
		Package: $I18N_NAME
		Version: $PKG_VERSION
		Depends: $PKG_NAME
		Architecture: all
		Description: IPSec VPN Server Chinese translation
	EOFCTRL
	ipkg-build -m "" "$I18N_DIR" "$TEMP_DIR"
	mv "$TEMP_DIR/${I18N_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${I18N_NAME}-${PKG_VERSION}.ipk"
fi

rm -rf "$TEMP_DIR"
