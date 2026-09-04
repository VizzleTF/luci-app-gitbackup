#!/bin/sh
# The shellcheck gate, run against a PINNED shellcheck rather than whatever
# the machine happens to have.
#
#   sh tools/shellcheck-gate.sh
#
# Why pinned. The first CI run of this repository was red on findings that a
# developer machine reported none of: shellcheck's own checks change between
# releases (0.11.0 stopped flagging `[ a ] && [ b ] || continue` as SC2015,
# and suppresses SC2317 in cases an older release did not), so "shellcheck is
# clean" meant two different things in two places. A gate whose meaning
# depends on a runner image bump is not a gate.
#
# The binary is downloaded once into .cache/ (gitignored, same convention
# tools/fetch-eslint-config.sh already uses) and checked against the sha256
# recorded below before it is run -- a downloaded binary that is executed
# without checking is a supply chain the length of whoever controls that
# host.
#
# The file list is derived from the tree by tools/find-shell-files.sh, never
# typed by hand: a hand-written list here once silently dropped bootstrap.sh
# and tests/bootstrap/run.sh.
set -eu

version='0.11.0'
root=$(cd "$(dirname "$0")/.." && pwd)
cache="$root/.cache/shellcheck-$version"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in
	arm64) arch='aarch64' ;;
	amd64) arch='x86_64' ;;
esac

case "$os.$arch" in
	linux.x86_64)    sha='8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198' ;;
	linux.aarch64)   sha='12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588' ;;
	darwin.aarch64)  sha='56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79' ;;
	*)
		echo "shellcheck-gate: no pinned checksum for $os.$arch -- add one before trusting this gate here" >&2
		exit 1
		;;
esac

bin="$cache/shellcheck"
if [ ! -x "$bin" ]; then
	mkdir -p "$cache"
	tarball="$cache/shellcheck.tar.xz"
	url="https://github.com/koalaman/shellcheck/releases/download/v$version/shellcheck-v$version.$os.$arch.tar.xz"
	echo "shellcheck-gate: fetching $url" >&2
	curl -fsSL "$url" -o "$tarball"

	got=$(shasum -a 256 "$tarball" 2>/dev/null | awk '{print $1}') || got=''
	[ -n "$got" ] || got=$(sha256sum "$tarball" | awk '{print $1}')
	if [ "$got" != "$sha" ]; then
		rm -f "$tarball"
		echo "shellcheck-gate: checksum mismatch for $url" >&2
		echo "  expected $sha" >&2
		echo "  got      $got" >&2
		exit 1
	fi

	tar -xJf "$tarball" -C "$cache" --strip-components=1 "shellcheck-v$version/shellcheck"
	rm -f "$tarball"
	chmod 0755 "$bin"
fi

"$bin" --version | sed -n 's/^version: /shellcheck-gate: using shellcheck /p' >&2
# shellcheck disable=SC2046  # the file list is one path per line, no spaces (find-shell-files.sh)
exec "$bin" -s sh $(sh "$root/tools/find-shell-files.sh")
