#!/bin/sh
# Stage both of this repository's packages' rootfs for owfeed -- the half of
# the build owfeed does not do.
#
#   ./tools/stage.sh              # dist/root + dist/VERSION (gitbackup)
#                                  # dist/luci-root + dist/LUCI_VERSION (luci-app-gitbackup)
#   GB_VERSION=1.2.0-r1 ./tools/stage.sh
#   GB_LUCI_VERSION=1.2.0-r1 ./tools/stage.sh
#
# `owfeed build` packages a DIRECTORY; it does not build one. Both packages are
# noarch -- POSIX shell, UCI text, JSON and client-side JS, not one compiled byte
# (spec "Упаковка") -- so staging is a straight copy of each package's own files,
# plus the version stamp an SDK build would otherwise be the only source of.
#
# No lifecycle-script extraction here, unlike luci-theme-footstrap's tools/stage.sh.
# That script pulls postinst/prerm bodies out of its Makefile because that Makefile
# defines both. Neither of this repository's Makefiles defines any -- the spec is
# explicit that installing gitbackup must not run a backup or generate keys, so
# there is no custom postinst to hold, and package/gitbackup/files/etc/uci-
# defaults/99-gitbackup does the one-time /etc/gitbackup setup instead. owfeed wraps
# every apk package's post-install in default_postinst regardless of whether a custom
# body was supplied (owfeed/internal/build/build.go, writeScripts -> openwrtPostInstall
# is called unconditionally), which is what makes that uci-defaults script run at all.
# If a later ticket adds a Package/*/postinst or .../prerm define to either Makefile,
# this script and owfeed.yml's `scripts:` block need to grow the same extraction
# footstrap's has, so the Makefile stays the one place those bodies are written.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${DIST:-$ROOT/dist}"

rm -rf "$DIST"

# _stage_version <makefile> -- PKG_VERSION-rPKG_RELEASE, the Makefile's own
# declared intent (R162i), read back here rather than duplicated, so a
# version bump has exactly one place to happen.
_stage_version() {
	_sv_mk="$1"
	_sv_version=$(sed -n 's/^PKG_VERSION:=//p' "$_sv_mk")
	_sv_release=$(sed -n 's/^PKG_RELEASE:=//p' "$_sv_mk")
	if [ -z "$_sv_version" ] || [ -z "$_sv_release" ]; then
		echo "stage: PKG_VERSION or PKG_RELEASE missing from $_sv_mk" >&2
		exit 1
	fi
	printf '%s-r%s' "$_sv_version" "$_sv_release"
}

# --------------------------------------------------------------------------
# gitbackup -- files/ already mirrors the router's root 1:1 -- the same tree
# the Makefile's `$(CP) ./files/* $(1)/` installs -- so staging is just that
# tree, copied.
# --------------------------------------------------------------------------
GB_SRC="$ROOT/package/gitbackup"
GB_STAGE="$DIST/root"
mkdir -p "$GB_STAGE"
cp -a "$GB_SRC/files/." "$GB_STAGE/"

VER="${GB_VERSION:-}"
[ -n "$VER" ] || VER=$(_stage_version "$GB_SRC/Makefile")
printf '%s\n' "$VER" >"$DIST/VERSION"

# --------------------------------------------------------------------------
# luci-app-gitbackup -- two source trees, one router root: root/ already
# mirrors it (menu.d, acl.d, same convention as gitbackup's own files/), and
# htdocs/ is luci.mk's own convention for a LuCI app's web-served tree,
# always /www (confirmed against this project's own owlab.yaml, which maps
# the two the same way for the dev stand).
# --------------------------------------------------------------------------
LUCI_SRC="$ROOT/applications/luci-app-gitbackup"
LUCI_STAGE="$DIST/luci-root"
mkdir -p "$LUCI_STAGE/www"
[ -d "$LUCI_SRC/root" ] && cp -a "$LUCI_SRC/root/." "$LUCI_STAGE/"
[ -d "$LUCI_SRC/htdocs" ] && cp -a "$LUCI_SRC/htdocs/." "$LUCI_STAGE/www/"

LUCI_VER="${GB_LUCI_VERSION:-}"
[ -n "$LUCI_VER" ] || LUCI_VER=$(_stage_version "$LUCI_SRC/Makefile")
printf '%s\n' "$LUCI_VER" >"$DIST/LUCI_VERSION"

# macOS writes these into any directory Finder has looked at; owfeed refuses a
# payload that carries one.
find "$DIST" -name '.DS_Store' -delete

echo "staged $DIST/root at $(cat "$DIST/VERSION")"
echo "staged $DIST/luci-root at $(cat "$DIST/LUCI_VERSION")"
