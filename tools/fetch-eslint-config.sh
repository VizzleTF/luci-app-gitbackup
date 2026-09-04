#!/bin/sh
# Fetch openwrt/luci's own eslint.config.mjs at the pinned commit
# (tools/luci-upstream.pin) and print its path. The brief asks, verbatim,
# for "eslint с конфигом из openwrt/luci" -- this is that config, unmodified,
# not a local reimplementation of its LuCI globals/jsdoc rules that could
# quietly drift from what upstream actually lints its own resource files
# with. Checksummed for the same reason jsmin.c is: it is fetched over the
# network and then loaded as the gate that decides whether our shipped JS
# passes lint.
#
# CI restricts the eslint CLI invocation to our own view/*.js glob, so the
# config's unrelated **/*.md and **/*.json rules (and its jsdoc block, scoped
# to modules/luci-base/**/*.js) never touch anything of ours -- only its
# LuCI-flavored JS block (globalReturn, the cbi/module globals, ecmaVersion)
# actually applies.
#
# Fetched INTO the repo tree (.cache/, gitignored), not $RUNNER_TEMP: the
# config's own `import ... from 'eslint/config'` etc. resolve through plain
# Node ESM resolution, which walks UP from the file doing the importing --
# a copy under /tmp has no node_modules above it anywhere and fails with
# ERR_MODULE_NOT_FOUND before a single rule ever runs, confirmed live.
# Under .cache/ the walk reaches this project's own npm-installed node_modules/.
set -eu
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./tools/luci-upstream.pin

mkdir -p .cache
cfg=".cache/luci-eslint.config.mjs"

curl -fsSL --proto '=https' --proto-redir '=https' -o "$cfg" \
	"https://raw.githubusercontent.com/openwrt/luci/$LUCI_PIN/eslint.config.mjs"
echo "$ESLINT_CONFIG_SHA256  $cfg" | sha256sum -c - >&2

echo "$cfg"
