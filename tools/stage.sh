#!/bin/sh
# Stage gitbackup's rootfs for owfeed -- the half of the build owfeed does not do.
#
#   ./tools/stage.sh              # dist/root + dist/VERSION
#   GB_VERSION=1.2.0-r1 ./tools/stage.sh
#
# `owfeed build` packages a DIRECTORY; it does not build one. gitbackup is noarch --
# POSIX shell, UCI text and JSON, not one compiled byte -- so staging is a straight
# copy of package/gitbackup/files, which already mirrors the router's root (etc/,
# usr/), plus the version stamp an SDK build would otherwise be the only source of.
#
# No lifecycle-script extraction here, unlike luci-theme-footstrap's tools/stage.sh.
# That script pulls postinst/prerm bodies out of its Makefile because that Makefile
# defines both. gitbackup's Makefile (package/gitbackup/Makefile) defines neither --
# the spec is explicit that installing the package must not run a backup or generate
# keys, so there is no custom postinst to hold, and package/gitbackup/files/etc/uci-
# defaults/99-gitbackup does the one-time /etc/gitbackup setup instead. owfeed wraps
# every apk package's post-install in default_postinst regardless of whether a custom
# body was supplied (owfeed/internal/build/build.go, writeScripts -> openwrtPostInstall
# is called unconditionally), which is what makes that uci-defaults script run at all.
# If a later ticket adds Package/gitbackup/postinst or .../prerm to the Makefile, this
# script and owfeed.yml's `scripts:` block need to grow the same extraction footstrap's
# has, so the Makefile stays the one place those bodies are written.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/package/gitbackup"
DIST="${DIST:-$ROOT/dist}"
STAGE="$DIST/root"

rm -rf "$DIST"
mkdir -p "$STAGE"

# files/ already mirrors the router's root 1:1 -- the same tree the Makefile's
# `$(CP) ./files/* $(1)/` installs -- so staging is just that tree, copied.
cp -a "$SRC/files/." "$STAGE/"

# macOS writes these into any directory Finder has looked at; owfeed refuses a
# payload that carries one.
find "$STAGE" -name '.DS_Store' -delete

# PKG_VERSION/PKG_RELEASE are the Makefile's own declared intent (R162i), read back
# here rather than duplicated, so a version bump has exactly one place to happen.
VER="${GB_VERSION:-}"
if [ -z "$VER" ]; then
	_pkg_version=$(sed -n 's/^PKG_VERSION:=//p' "$SRC/Makefile")
	_pkg_release=$(sed -n 's/^PKG_RELEASE:=//p' "$SRC/Makefile")
	if [ -z "$_pkg_version" ] || [ -z "$_pkg_release" ]; then
		echo "stage: PKG_VERSION or PKG_RELEASE missing from $SRC/Makefile" >&2
		exit 1
	fi
	VER="$_pkg_version-r$_pkg_release"
fi
printf '%s\n' "$VER" >"$DIST/VERSION"

echo "staged $DIST/root at $(cat "$DIST/VERSION")"
