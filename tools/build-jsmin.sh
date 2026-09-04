#!/bin/sh
# Build the exact jsmin the OpenWrt buildbot minifies our LuCI JS with.
# Prints the path to the compiled binary; tools/jsmin-verify.mjs reads it
# from $JSMIN.
#
# Pinned to a commit and checksummed (tools/luci-upstream.pin), because of
# what this file is: C source fetched over the network, compiled, and then
# run as the gate that decides whether our shipped JavaScript is safe. From a
# moving `master` the gate would be whatever upstream pushed last.
set -eu
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./tools/luci-upstream.pin
: "${RUNNER_TEMP:=${TMPDIR:-/tmp}}"

src="$RUNNER_TEMP/gitbackup-jsmin.c"
bin="$RUNNER_TEMP/gitbackup-jsmin"

curl -fsSL --proto '=https' --proto-redir '=https' -o "$src" \
	"https://raw.githubusercontent.com/openwrt/luci/$LUCI_PIN/modules/luci-base/src/jsmin.c"
echo "$JSMIN_SHA256  $src" | sha256sum -c - >&2
cc -O2 -o "$bin" "$src"

echo "$bin"
