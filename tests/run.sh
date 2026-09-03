#!/bin/sh
# shellcheck disable=SC1091,SC2089,SC2090,SC2016
#
# SC1091: lib.sh/device.sh are sourced from a path built at runtime.
# SC2089/SC2090: GB_TEST_BOARD fixtures below are plain data read back with
# printf, never eval'd or passed to a command as if still shell-quoted.
# SC2016: the bashism grep pattern is single-quoted on purpose -- it must not
# expand.
#
# Unit tests for the gitbackup shell modules.
#
#   sh tests/run.sh          run everything
#   sh tests/run.sh <name>   run one test (substring match on its name)
#
# POSIX sh only: the same file has to run under macOS /bin/sh during
# development and under busybox ash on the router, and a test suite that needs
# bash cannot be run where the code it tests actually lives.
#
# The modules under test read the router through four commands that do not
# exist on a development host -- uci, ubus, jsonfilter, logger. They are
# replaced here by stubs on PATH rather than by variables in the code, so the
# call sites stay exactly what ships.

set -u

root=$(cd "$(dirname "$0")/.." && pwd)
files="$root/package/gitbackup/files"
share="$files/usr/share/gitbackup"

work=$(mktemp -d "${TMPDIR:-/tmp}/gitbackup-tests.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT INT TERM

only="${1:-}"

# A missing module has to stop the run here. Every test body is a subshell, and
# a failed `.` inside one kills that subshell without asserting anything -- the
# suite would report "0 failed" for code that does not exist.
for module in "$share/lib.sh" "$share/device.sh" "$share/collect.sh" "$share/remoteurl.sh" "$share/visibility.sh" "$files/usr/sbin/gitbackup"; do
	[ -r "$module" ] || { printf 'missing: %s\n' "$module" >&2; exit 1; }
done

# --------------------------------------------------------------------------
# stubs
# --------------------------------------------------------------------------

mkdir -p "$work/bin"

cat >"$work/bin/uci" <<'STUB'
#!/bin/sh
# Test double for uci(1). Answers `uci -q get <path>` out of GB_TEST_UCI, a
# file of key=value lines. Every other invocation is refused loudly: a stub
# that answers "" to a call it does not understand turns a broken test green.
quiet=0
key=
while [ $# -gt 0 ]; do
	case "$1" in
		-q) quiet=1 ;;
		get) shift; key="${1:-}"; break ;;
		*) echo "uci stub: unsupported argument '$1'" >&2; exit 64 ;;
	esac
	shift
done
[ -n "$key" ] || { echo "uci stub: no key given" >&2; exit 64; }
value=$(grep "^${key}=" "${GB_TEST_UCI:-/dev/null}" 2>/dev/null | head -n 1)
if [ -z "$value" ]; then
	[ "$quiet" = 1 ] || echo "uci: Entry not found" >&2
	exit 1
fi
printf '%s\n' "${value#*=}"
STUB

cat >"$work/bin/ubus" <<'STUB'
#!/bin/sh
# Test double for ubus(1). `call system board` is the only call the modules
# make; it answers with GB_TEST_BOARD so a test can hand it any hostname.
if [ "${1:-}" = "call" ] && [ "${2:-}" = "system" ] && [ "${3:-}" = "board" ]; then
	board="${GB_TEST_BOARD-}"
	[ -n "$board" ] || board='{}'
	printf '%s\n' "$board"
	exit 0
fi
echo "ubus stub: unsupported call '$*'" >&2
exit 64
STUB

cat >"$work/bin/jsonfilter" <<'STUB'
#!/bin/sh
# Test double for jsonfilter(1). Supports the single form the modules use --
# `jsonfilter -e @.<field>` over a one-level object on stdin -- and, like the
# real one, prints nothing and exits 0 when the field is absent.
[ "${1:-}" = "-e" ] || { echo "jsonfilter stub: expected -e, got '${1:-}'" >&2; exit 64; }
expr="${2:-}"
case "$expr" in
	@.*) field="${expr#@.}" ;;
	*) echo "jsonfilter stub: unsupported expression '$expr'" >&2; exit 64 ;;
esac
case "$field" in
	*.*) echo "jsonfilter stub: nested expressions are not supported" >&2; exit 64 ;;
esac
sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
STUB

cat >"$work/bin/logger" <<'STUB'
#!/bin/sh
# Test double for logger(1): appends the message to GB_TEST_LOG so a test can
# assert that something was written, and swallows it otherwise.
msg=
while [ $# -gt 0 ]; do
	case "$1" in
		-t|-p) shift ;;
		--) shift; msg="$*"; break ;;
		*) msg="$*"; break ;;
	esac
	shift
done
[ -n "${GB_TEST_LOG:-}" ] && printf '%s\n' "$msg" >>"$GB_TEST_LOG"
exit 0
STUB

cat >"$work/bin/sysupgrade" <<'STUB'
#!/bin/sh
# Test double for sysupgrade(1). collect.sh only ever calls `-l`; answers
# with the contents of GB_TEST_SYSUPGRADE_L, one path per line -- the fixed
# list ticket 02's tests hand it, standing in for the real tool's own merge
# of /etc/sysupgrade.conf, /lib/upgrade/keep.d/* and changed conffiles.
case "${1:-}" in
	-l|--list-backup) ;;
	*) echo "sysupgrade stub: unsupported argument '${1:-}'" >&2; exit 64 ;;
esac
cat "${GB_TEST_SYSUPGRADE_L:-/dev/null}"
STUB

cat >"$work/bin/apk" <<'STUB'
#!/bin/sh
# Test double for apk(1). collect.sh only ever calls `list --installed`;
# answers with the contents of GB_TEST_APK_INSTALLED.
if [ "${1:-}" = "list" ] && [ "${2:-}" = "--installed" ]; then
	cat "${GB_TEST_APK_INSTALLED:-/dev/null}"
	exit 0
fi
echo "apk stub: unsupported call '$*'" >&2
exit 64
STUB

cat >"$work/bin/stat" <<'STUB'
#!/bin/sh
# Test double for GNU/busybox stat(1), backed by the host's real stat(1).
# collect.sh only ever calls `stat -c '%a %u %g' <path>` (no -L, i.e.
# lstat semantics -- a symlink reports its own mode, never the target's).
# macOS ships a BSD stat with different flags entirely, so this stub
# translates on Darwin; elsewhere it defers straight to the real GNU stat,
# found via the POSIX default PATH so it does not recurse into itself.
[ "${1:-}" = "-c" ] || { echo "stat stub: expected -c, got '${1:-}'" >&2; exit 64; }
fmt="$2"; path="$3"
[ "$fmt" = '%a %u %g' ] || { echo "stat stub: unsupported format '$fmt'" >&2; exit 64; }
if [ "$(uname -s)" = "Darwin" ]; then
	/usr/bin/stat -f '%Lp %u %g' "$path"
else
	command -p stat -c '%a %u %g' "$path"
fi
STUB

cat >"$work/bin/uclient-fetch" <<'STUB'
#!/bin/sh
# Test double for uclient-fetch(1). visibility.sh's whole gate rests on how
# this real tool reports an HTTP status, so the stub has to answer with the
# real tool's own behavior instead of a shape convenient for the test --
# verified against openwrt/uclient's uclient-fetch.c (header_done_cb's
# `default: fprintf(stderr, "HTTP error %d\n", ...); error_ret = 8` for any
# status code other than 200/204/206/416, and handle_uclient_error's
# `error_ret = 4` with "Connection error: ..." for a refused/timed-out
# connection). GB_TEST_HTTP is a file of "<url> <code>" lines, one request
# answered per matching line; a URL with no matching line behaves like an
# unreachable host, the same as the real tool facing a dead link -- there is
# no "answers the same for every URL" fallback, which is the shape of mock
# that proves nothing (ticket 03's own warning).
url=""
for gb_a in "$@"; do url="$gb_a"; done
code=$(awk -v u="$url" '$1==u{print $2; exit}' "${GB_TEST_HTTP:-/dev/null}")
case "$code" in
	2??) exit 0 ;;
	[0-9][0-9][0-9]) echo "HTTP error $code" >&2; exit 8 ;;
	*) echo "Connection error: Connection failed" >&2; exit 4 ;;
esac
STUB

chmod 0755 "$work/bin"/*
PATH="$work/bin:$PATH"
export PATH

# --------------------------------------------------------------------------
# harness
# --------------------------------------------------------------------------

# Results go to a file, not to the $passed/$failed variables their names
# suggest: most test bodies below run inside a `( ... )` subshell, so an
# ordinary `passed=$((passed + 1))` there is invisible to this script the
# instant that subshell exits -- verified by breaking an assertion on
# purpose and watching the final tally not move. Appending to a shared file
# survives the subshell boundary; tests run one at a time, so there is no
# concurrent-write race to guard against.
results="$work/results"
: >"$results"
ok() { printf 'PASS\n' >>"$results"; printf '  ok    %s\n' "$1"; }
no() { printf 'FAIL\n' >>"$results"; printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

# eq <name> <expected> <actual>
eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}

# contains <name> <needle> <haystack>
contains() {
	case "$3" in
		*"$2"*) ok "$1" ;;
		*) no "$1" "expected to find [$2] in [$3]" ;;
	esac
}

# fixture <key=value>... -> writes a uci fixture and points the stub at it
fixture() {
	: >"$work/uci"
	for kv in "$@"; do printf '%s\n' "$kv" >>"$work/uci"; done
	GB_TEST_UCI="$work/uci"
	export GB_TEST_UCI
}

# http_fixture <url=code>... -> writes a uclient-fetch fixture and points the
# stub at it. <code> is a 3-digit HTTP status, or anything else to mean
# "unreachable" (the stub's fallback case).
http_fixture() {
	: >"$work/http"
	for kv in "$@"; do
		gb_u="${kv%%=*}"
		gb_c="${kv#*=}"
		printf '%s %s\n' "$gb_u" "$gb_c" >>"$work/http"
	done
	GB_TEST_HTTP="$work/http"
	export GB_TEST_HTTP
}

run_test() {
	case "$1" in
		*"$only"*) ;;
		*) return 0 ;;
	esac
	printf '%s\n' "$1"
	"$2"
}

# --------------------------------------------------------------------------
# lib.sh
# --------------------------------------------------------------------------

t_json_esc() {
	(
		. "$share/lib.sh"
		eq 'plain string is unchanged' 'devices/rt1' "$(gb_json_esc 'devices/rt1')"
		eq 'double quote is escaped' 'say \"hi\"' "$(gb_json_esc 'say "hi"')"
		eq 'backslash is escaped' 'a\\\\b' "$(gb_json_esc 'a\\b')"
		eq 'newline becomes \\n' 'a\nb' "$(gb_json_esc 'a
b')"
		eq 'tab becomes \\t' "a\\tb" "$(gb_json_esc "a$(printf '\t')b")"
	)
}

t_uci_get() {
	(
		. "$share/lib.sh"
		fixture 'gitbackup.main.schedule=weekly'
		eq 'existing option is returned' 'weekly' "$(gb_uci_get gitbackup.main.schedule)"
		eq 'missing option falls back to the default' 'daily' \
			"$(gb_uci_get gitbackup.main.nosuch daily)"
		eq 'missing option with no default is empty' '' \
			"$(gb_uci_get gitbackup.main.nosuch)"
	)
}

t_free_kb() {
	(
		. "$share/lib.sh"
		kb=$(gb_free_kb "$work")
		case "$kb" in
			''|*[!0-9]*) no 'free space is a number of kilobytes' "got [$kb]" ;;
			*) ok 'free space is a number of kilobytes' ;;
		esac
	)
}

t_have_net() {
	(
		. "$share/lib.sh"
		# gb_have_net is documented in interfaces.md as a public entry point
		# (lib.sh: "gb_have_net <host> [port]") but had no test or stub;
		# ticket 01 review flagged it. There is no fake nc(1) on the stub
		# PATH -- gb_have_net's whole job is talking to the real network stack
		# -- so this exercises the real nc against loopback instead.
		if ! command -v nc >/dev/null 2>&1; then
			return
		fi

		# Port 1 is privileged and unbound on a dev machine and in CI alike,
		# so the connect fails fast (ECONNREFUSED) rather than hanging until
		# gb_have_net's own 5s timeout -- this is the case `run` relies on to
		# tell "offline" from "reachable" without a slow probe every time.
		gb_have_net 127.0.0.1 1
		eq 'gb_have_net fails against a port nothing listens on' '1' "$?"

		# The success path needs a real open port; python3's socket module
		# behaves identically on every host this suite runs on (unlike nc's
		# listen flags, which differ between BSD and GNU builds), so it is
		# what stands in for "a server is actually there." Skipped silently,
		# same as this suite's other python3-gated assertions, when python3
		# is not installed.
		if command -v python3 >/dev/null 2>&1; then
			# The sleep after listen() is not padding: without it the
			# process exits and closes the socket the instant it is bound,
			# and gb_have_net loses the race against its own connect().
			python3 -c '
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 18291))
s.listen(1)
time.sleep(3)
' &
			listener_pid=$!
			sleep 0.5
			gb_have_net 127.0.0.1 18291
			eq 'gb_have_net succeeds against an open port' '0' "$?"
			kill "$listener_pid" 2>/dev/null
			wait "$listener_pid" 2>/dev/null
		fi
	)
}

t_die() {
	(
		. "$share/lib.sh"
		GB_TEST_LOG="$work/log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
		( gb_die 2 'bad config' ) >/dev/null 2>&1
		eq 'gb_die exits with the code it was given' '2' "$?"
		contains 'gb_die logs the message' 'bad config' "$(cat "$work/log")"
	)
}

# --------------------------------------------------------------------------
# device.sh
# --------------------------------------------------------------------------

# board_fixture <mac>... -- a fake /sys/class/net for the board strategy
board_fixture() {
	rm -rf "$work/net"
	mkdir -p "$work/net/lo"
	printf '00:00:00:00:00:00\n' >"$work/net/lo/address"
	_n=0
	for mac in "$@"; do
		mkdir -p "$work/net/eth$_n"
		printf '%s\n' "$mac" >"$work/net/eth$_n/address"
		_n=$((_n + 1))
	done
	GB_SYSFS_NET="$work/net"
	export GB_SYSFS_NET
}

t_device_hostname() {
	(
		. "$share/lib.sh"; . "$share/device.sh"
		fixture 'gitbackup.main.device_id=hostname'
		GB_TEST_BOARD='{"hostname":"attic-router","model":"GL.iNet GL-MT6000"}'
		export GB_TEST_BOARD
		eq 'hostname strategy returns the router hostname' 'attic-router' "$(gb_device_id)"
	)
}

t_device_hostname_default() {
	(
		. "$share/lib.sh"; . "$share/device.sh"
		fixture 'gitbackup.main.device_id=hostname'
		GB_TEST_BOARD='{"hostname":"OpenWrt","model":"GL.iNet GL-MT6000"}'
		export GB_TEST_BOARD
		out=$( ( gb_device_id ) 2>&1 >/dev/null )
		eq 'the stock hostname is refused with exit 2' '2' "$?"
		contains 'and the message says why' 'overwrite' "$out"
	)
}

t_device_custom() {
	(
		. "$share/lib.sh"; . "$share/device.sh"
		fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt-office_1.b'
		eq 'custom strategy returns the configured name' 'rt-office_1.b' "$(gb_device_id)"

		fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device='
		out=$( ( gb_device_id ) 2>&1 >/dev/null )
		eq 'an empty custom name is refused with exit 2' '2' "$?"
		contains 'and the message names the option' 'device' "$out"

		fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=has spaces'
		( gb_device_id ) >/dev/null 2>&1
		eq 'a name outside [A-Za-z0-9._-] is refused with exit 2' '2' "$?"
	)
}

t_device_board() {
	(
		. "$share/lib.sh"; . "$share/device.sh"
		fixture 'gitbackup.main.device_id=board'
		GB_TEST_BOARD='{"hostname":"OpenWrt","model":"GL.iNet GL-MT6000"}'
		export GB_TEST_BOARD
		board_fixture 'aa:bb:cc:dd:ee:ff' '11:22:33:44:55:66'
		eq 'board strategy is model-slug plus the first MAC tail' \
			'gl-inet-gl-mt6000-ddeeff' "$(gb_device_id)"
	)
}

t_device_unknown_strategy() {
	(
		. "$share/lib.sh"; . "$share/device.sh"
		fixture 'gitbackup.main.device_id=carrier-pigeon'
		out=$( ( gb_device_id ) 2>&1 >/dev/null )
		eq 'an unknown device_id strategy is refused with exit 2' '2' "$?"
		contains 'and the message names the bad value' 'carrier-pigeon' "$out"
	)
}

t_device_board_no_mac() {
	(
		. "$share/lib.sh"; . "$share/device.sh"
		fixture 'gitbackup.main.device_id=board'
		GB_TEST_BOARD='{"hostname":"OpenWrt","model":"GL.iNet GL-MT6000"}'
		export GB_TEST_BOARD
		# Every interface present is either lo or has an all-zero MAC --
		# board_fixture with no arguments plus one such extra interface, the
		# only shape a real router can be in that gb_device_id must still
		# refuse rather than silently mint a device name out of nothing.
		board_fixture '00:00:00:00:00:00'
		out=$( ( gb_device_id ) 2>&1 >/dev/null )
		eq 'no usable MAC address is refused with exit 2' '2' "$?"
		contains 'and the message says none was found' 'no network interface' "$out"
	)
}

t_expand() {
	(
		. "$share/lib.sh"; . "$share/device.sh"
		# gb_expand takes only the template (interfaces.md): the device name
		# is always gb_device_id's own answer, resolved from this fixture.
		fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1'
		eq 'the placeholder is replaced' 'devices/rt1' "$(gb_expand 'devices/{device}')"
		eq 'every occurrence is replaced' 'rt1/x/rt1' "$(gb_expand '{device}/x/{device}')"
		eq 'a template without one is untouched' 'devices/all' "$(gb_expand 'devices/all')"
	)
}

# --------------------------------------------------------------------------
# collect.sh
# --------------------------------------------------------------------------

# collect_fixture -- a fake router filesystem under $work/froot, and
# collect.sh's seams (GB_ROOT, GB_EXCLUDE_LIST, GB_DEVICE, the sysupgrade/apk
# stubs) pointed at it. Callers add files under $work/froot and call
# sysupgrade_list before calling gb_collect against $work/out.
collect_fixture() {
	rm -rf "$work/froot" "$work/out"
	mkdir -p "$work/froot/etc" "$work/out"
	GB_ROOT="$work/froot"; export GB_ROOT
	GB_EXCLUDE_LIST="$share/exclude.list"; export GB_EXCLUDE_LIST
	GB_TEST_SYSUPGRADE_L="$work/sysupgrade_l"; export GB_TEST_SYSUPGRADE_L
	: >"$GB_TEST_SYSUPGRADE_L"
	GB_TEST_APK_INSTALLED="$work/apk_installed"; export GB_TEST_APK_INSTALLED
	: >"$GB_TEST_APK_INSTALLED"
	GB_TEST_BOARD='{"hostname":"testhost","model":"Test Board"}'; export GB_TEST_BOARD
	GB_DEVICE='rt1'; export GB_DEVICE
}

# sysupgrade_list <path>... -- appends absolute paths to the sysupgrade -l stub's answer.
sysupgrade_list() {
	for gb_p in "$@"; do printf '%s\n' "$gb_p" >>"$GB_TEST_SYSUPGRADE_L"; done
}

t_collect_layout() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		mkdir -p "$work/froot/etc/config" "$work/froot/etc/apk/repositories.d"
		printf 'config network\n' >"$work/froot/etc/config/network"
		sysupgrade_list '/etc/config/network'
		printf 'https://example.org/repo\n' >"$work/froot/etc/apk/repositories.d/distfeeds.list"
		printf 'NAME="OpenWrt"\nVERSION_ID="25.12.4"\n' >"$work/froot/etc/os-release"

		gb_collect "$work/out" >/dev/null 2>&1
		eq 'gb_collect returns 0' '0' "$?"

		eq 'the file lands under files/ with its path preserved' 'config network' \
			"$(cat "$work/out/files/etc/config/network" 2>/dev/null)"

		for gb_f in board.json installed_packages.txt repositories.txt sysupgrade.conf os-release.txt; do
			if [ -f "$work/out/meta/$gb_f" ]; then
				ok "meta/$gb_f is written"
			else
				no "meta/$gb_f is written" 'missing'
			fi
		done
		contains 'meta/repositories.txt holds the repositories.d content' \
			'https://example.org/repo' "$(cat "$work/out/meta/repositories.txt")"

		gb_manifest="$(gb_manifest_path "$work/out")"
		if [ -f "$gb_manifest" ]; then
			ok 'manifest.json is written'
		else
			no 'manifest.json is written' 'missing'
		fi
		contains 'manifest.json names the collected file' \
			'"path":"/etc/config/network"' "$(cat "$gb_manifest")"
		contains 'manifest.json records the device from GB_DEVICE' \
			'"device": "rt1"' "$(cat "$gb_manifest")"
	)
}

t_collect_paths_from_sysupgrade_only() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		printf 'a\n' >"$work/froot/etc/listed"
		printf 'b\n' >"$work/froot/etc/unlisted"
		sysupgrade_list '/etc/listed'

		gb_collect "$work/out" >/dev/null 2>&1

		if [ -f "$work/out/files/etc/listed" ]; then
			ok 'a path sysupgrade -l reports is collected'
		else
			no 'a path sysupgrade -l reports is collected' 'missing'
		fi
		if [ -e "$work/out/files/etc/unlisted" ]; then
			no 'a path sysupgrade -l does not report is left out' 'it was collected anyway'
		else
			ok 'a path sysupgrade -l does not report is left out'
		fi
		case "$(cat "$(gb_manifest_path "$work/out")")" in
			*unlisted*) no 'manifest has no trace of the unlisted file' 'found it' ;;
			*) ok 'manifest has no trace of the unlisted file' ;;
		esac
	)
}

t_collect_symlink_not_dereferenced() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		mkdir -p "$work/froot/tmp/resolv.conf.d"
		printf 'nameserver 1.1.1.1\n' >"$work/froot/tmp/resolv.conf.d/resolv.conf.auto"
		ln -s '/tmp/resolv.conf.d/resolv.conf.auto' "$work/froot/etc/resolv.conf"
		sysupgrade_list '/etc/resolv.conf'

		gb_collect "$work/out" >/dev/null 2>&1

		if [ -L "$work/out/files/etc/resolv.conf" ]; then
			ok 'the collected path is still a symlink'
		else
			no 'the collected path is still a symlink' 'it was dereferenced into a regular file'
		fi
		eq 'the symlink target is preserved verbatim' '/tmp/resolv.conf.d/resolv.conf.auto' \
			"$(readlink "$work/out/files/etc/resolv.conf")"

		gb_manifest_text="$(cat "$(gb_manifest_path "$work/out")")"
		contains 'manifest records it as type symlink' '"type":"symlink"' "$gb_manifest_text"
		contains 'manifest records the target instead of hashing content' \
			'"target":"/tmp/resolv.conf.d/resolv.conf.auto"' "$gb_manifest_text"
	)
}

t_collect_file_manifest_fields() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		printf 'secret-ish content\n' >"$work/froot/etc/thing"
		chmod 600 "$work/froot/etc/thing"
		sysupgrade_list '/etc/thing'

		gb_collect "$work/out" >/dev/null 2>&1
		gb_manifest_text="$(cat "$(gb_manifest_path "$work/out")")"

		# The expected hash comes from sha256sum on the source, not from any
		# path collect.sh itself takes to produce it.
		gb_want_sha=$(sha256sum "$work/froot/etc/thing" | awk '{print $1}')
		contains 'manifest records the type as file' '"type":"file"' "$gb_manifest_text"
		contains 'manifest records the file mode' '"mode":600' "$gb_manifest_text"
		contains 'manifest records the sha256 of the content' \
			"\"sha256\":\"$gb_want_sha\"" "$gb_manifest_text"
	)
}

t_collect_empty_dir() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		mkdir -p "$work/froot/etc/empty" "$work/froot/etc/nonempty"
		printf 'x\n' >"$work/froot/etc/nonempty/file"
		sysupgrade_list '/etc/nonempty/file'
		printf '/etc/empty\n/etc/nonempty\n' >"$work/froot/etc/sysupgrade.conf"

		gb_collect "$work/out" >/dev/null 2>&1
		gb_manifest_text="$(cat "$(gb_manifest_path "$work/out")")"

		contains 'an empty directory becomes a dir entry' \
			'{"path":"/etc/empty","type":"dir"' "$gb_manifest_text"
		case "$gb_manifest_text" in
			*'"path":"/etc/nonempty","type":"dir"'*)
				no 'a directory that has content gets no dir entry of its own' 'it did' ;;
			*) ok 'a directory that has content gets no dir entry of its own' ;;
		esac
	)
}

t_collect_empty_dir_trailing_slash_source() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		# /lib/upgrade/keep.d/* lines name a directory with a trailing "/"
		# (measured on the 25.12.4 owlab stand, e.g. base-files' own
		# "/etc/config/") -- found live because it made the path in the
		# manifest come out as "/etc/config/" instead of "/etc/config".
		mkdir -p "$work/froot/lib/upgrade/keep.d" "$work/froot/etc/trailing"
		printf '/etc/trailing/\n' >"$work/froot/lib/upgrade/keep.d/some-pkg"

		gb_collect "$work/out" >/dev/null 2>&1
		gb_manifest_text="$(cat "$(gb_manifest_path "$work/out")")"

		contains 'the trailing slash in the source line is stripped from the manifest path' \
			'"path":"/etc/trailing","type":"dir"' "$gb_manifest_text"
		case "$gb_manifest_text" in
			*'/etc/trailing/"'*)
				no 'the manifest path never carries a trailing slash' 'it did' ;;
			*) ok 'the manifest path never carries a trailing slash' ;;
		esac
	)
}

t_collect_hard_exclude() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		mkdir -p "$work/froot/etc/gitbackup"
		printf 'shh\n' >"$work/froot/etc/gitbackup/token"
		sysupgrade_list '/etc/gitbackup/token'
		printf '/etc/gitbackup\n' >"$work/froot/etc/sysupgrade.conf"

		gb_collect "$work/out" >/dev/null 2>&1

		if [ -e "$work/out/files/etc/gitbackup" ]; then
			no '/etc/gitbackup is absent from the tree' 'it was collected'
		else
			ok '/etc/gitbackup is absent from the tree'
		fi
		case "$(cat "$(gb_manifest_path "$work/out")")" in
			*gitbackup*) no '/etc/gitbackup is absent from the manifest' 'found it' ;;
			*) ok '/etc/gitbackup is absent from the manifest' ;;
		esac
	)
}

t_collect_manifest_equal() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		gb_a="$work/manifest_a.json"
		gb_b="$work/manifest_b.json"
		gb_c="$work/manifest_c.json"
		cat >"$gb_a" <<'EOF'
{
  "version": "1",
  "generated": "2026-01-01T00:00:00Z",
  "hostname": "r1",
  "device": "r1",
  "openwrt": "25.12.4",
  "board": "generic",
  "entries": [
    {"path":"/etc/config/network","type":"file","mode":644,"uid":0,"gid":0,"sha256":"abc"}
  ],
  "scrubbed": [
  ]
}
EOF
		# Same entries/scrubbed, different generated timestamp and hostname:
		# neither participates in the comparison (spec, "Сбор и manifest.json").
		cat >"$gb_b" <<'EOF'
{
  "version": "1",
  "generated": "2026-06-15T12:30:00Z",
  "hostname": "r1-renamed",
  "device": "r1",
  "openwrt": "25.12.4",
  "board": "generic",
  "entries": [
    {"path":"/etc/config/network","type":"file","mode":644,"uid":0,"gid":0,"sha256":"abc"}
  ],
  "scrubbed": [
  ]
}
EOF
		# Same file, mode changed by a chmod: must be caught (R24's own test).
		cat >"$gb_c" <<'EOF'
{
  "version": "1",
  "generated": "2026-01-01T00:00:00Z",
  "hostname": "r1",
  "device": "r1",
  "openwrt": "25.12.4",
  "board": "generic",
  "entries": [
    {"path":"/etc/config/network","type":"file","mode":600,"uid":0,"gid":0,"sha256":"abc"}
  ],
  "scrubbed": [
  ]
}
EOF
		gb_manifest_equal "$gb_a" "$gb_b"
		eq 'two runs with the same entries are equal despite generated/hostname differing' '0' "$?"
		gb_manifest_equal "$gb_a" "$gb_c"
		eq 'a mode change (chmod) makes the manifests unequal' '1' "$?"
	)
}

t_collect_json_special_chars() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		gb_weird='/etc/weird "name" тест.conf'
		printf 'x\n' >"$work/froot$gb_weird"
		sysupgrade_list "$gb_weird"

		gb_collect "$work/out" >/dev/null 2>&1
		gb_manifest_file="$(gb_manifest_path "$work/out")"

		if command -v python3 >/dev/null 2>&1; then
			if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$gb_manifest_file" 2>/dev/null; then
				ok 'manifest.json stays valid JSON with quotes, spaces and non-ASCII in a path'
			else
				no 'manifest.json stays valid JSON with quotes, spaces and non-ASCII in a path' \
					"$(cat "$gb_manifest_file")"
			fi
		fi
		contains 'the quote in the path is escaped, not left to break the JSON' \
			'\"name\"' "$(cat "$gb_manifest_file")"
	)
}

# --------------------------------------------------------------------------
# remoteurl.sh
# --------------------------------------------------------------------------

t_remoteurl_valid_forms() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"
		# url|scheme host port owner repo -- port is "0" when the URL named
		# none (remoteurl.sh does not guess a scheme's default, see its own
		# comment on gb_parse_url). 14 fixtures: the scp-like form (with and
		# without an explicit user@, since git accepts both), ssh:// with and
		# without a port, https:// with and without a port, self-hosted hosts,
		# with and without a trailing .git, and dots/dashes in owner/repo.
		while IFS='|' read -r gb_url gb_want; do
			[ -n "$gb_url" ] || continue
			gb_got=$(gb_parse_url "$gb_url") || gb_got='<rejected>'
			eq "parses: $gb_url" "$gb_want" "$gb_got"
		done <<'FIXTURES'
git@github.com:owner/repo.git|ssh github.com 0 owner repo
git@gitlab.com:group/repo|ssh gitlab.com 0 group repo
git@git.example.com:my-org/my.repo.git|ssh git.example.com 0 my-org my.repo
example.com:owner/repo.git|ssh example.com 0 owner repo
ssh://git@example.com:2222/owner/repo.git|ssh example.com 2222 owner repo
ssh://git@github.com/owner/repo.git|ssh github.com 0 owner repo
ssh://git@example.com/owner.name/repo.name.git|ssh example.com 0 owner.name repo.name
https://git.example.com:8443/owner/repo.git|https git.example.com 8443 owner repo
https://github.com/owner/repo.git|https github.com 0 owner repo
https://gitlab.com/owner/repo|https gitlab.com 0 owner repo
https://git.example.com:3000/my-org/my-repo.git|https git.example.com 3000 my-org my-repo
https://bitbucket.org/workspace/repo.git|https bitbucket.org 0 workspace repo
git@codeberg.org:owner/repo.git|ssh codeberg.org 0 owner repo
https://host:1/o/r|https host 1 o r
FIXTURES
	)
}

t_remoteurl_garbage_rejected() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"
		# A malformed URL must fail outright, not get parsed halfway into a
		# wrong-but-plausible {scheme,host,owner,repo} (ticket 03 acceptance
		# criterion) -- gb_parse_url must print nothing and return non-zero.
		for gb_url in \
			'ftp://host/owner/repo' \
			'https://host/onlyowner' \
			'git@host:owner' \
			'https://host/owner/repo/extra' \
			'not a url at all' \
			'' \
			'https://host:abc/owner/repo' \
			'/local/path:owner/repo'
		do
			gb_got=$(gb_parse_url "$gb_url")
			gb_rc=$?
			eq "rejected outright: '$gb_url'" '1' "$gb_rc"
			eq "and nothing was printed for: '$gb_url'" '' "$gb_got"
		done
	)
}

t_remoteurl_provider() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"
		fixture 'gitbackup.origin.provider=auto'
		eq 'github.com is detected as github' 'github' "$(gb_provider github.com)"
		eq 'gitlab.com is detected as gitlab' 'gitlab' "$(gb_provider gitlab.com)"
		eq 'bitbucket.org is detected as bitbucket' 'bitbucket' "$(gb_provider bitbucket.org)"
		# Codeberg runs Forgejo, whose anonymous repo API is shaped like
		# Gitea's (spec, "Проверенные факты"); the UCI provider enum has no
		# separate codeberg/forgejo value.
		eq 'codeberg.org is detected as gitea (forgejo-compatible API)' 'gitea' "$(gb_provider codeberg.org)"
		eq 'an unrecognized host falls back to generic' 'generic' "$(gb_provider git.example.com)"

		fixture 'gitbackup.origin.provider=gitea'
		eq 'an explicit option provider wins over host detection' 'gitea' "$(gb_provider github.com)"
	)
}

t_remoteurl_deeplink() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"
		eq 'github deep link' 'https://github.com/acme/site/settings/keys/new' \
			"$(gb_deeplink github https github.com acme site)"
		eq 'gitlab deep link is built from the remote'\''s own host, not gitlab.com' \
			'https://gitlab.example.com/acme/site/-/settings/repository' \
			"$(gb_deeplink gitlab ssh gitlab.example.com acme site)"
		eq 'gitea/forgejo deep link is built from the remote'\''s own host' \
			'https://git.example.com/acme/site/settings/keys' \
			"$(gb_deeplink gitea ssh git.example.com acme site)"
		eq 'bitbucket deep link' 'https://bitbucket.org/acme/site/admin/access-keys/' \
			"$(gb_deeplink bitbucket https bitbucket.org acme site)"
		gb_out=$(gb_deeplink generic ssh git.example.com acme site)
		contains 'generic gets an instruction naming authorized_keys, not a link' 'authorized_keys' "$gb_out"
		contains 'and it recommends restrict,command="git-shell"' 'git-shell' "$gb_out"
		case "$gb_out" in
			http*://*) no 'the generic instruction is not itself a clickable URL' "$gb_out" ;;
			*) ok 'the generic instruction is not itself a clickable URL' ;;
		esac
	)
}

# --------------------------------------------------------------------------
# visibility.sh
# --------------------------------------------------------------------------

t_visibility_public_refused() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/visibility.sh"
		fixture 'gitbackup.origin.provider=auto'
		GB_STATE_DIR="$work/vis-public"; export GB_STATE_DIR
		# The mock varies per URL on purpose (ticket 03: "мок, который отвечает
		# одинаково на любой URL, ничего не проверяет") -- this is the one
		# acceptance criterion the ticket calls out by name: a repository the
		# provider's anonymous API answers 200 for must come back exit 4, so
		# whatever calls gb_visibility_ok in `run` (ticket 04/05) never pushes.
		http_fixture 'https://api.github.com/repos/acme/pub=200'
		( gb_visibility_ok 'https://github.com/acme/pub.git' ) >/dev/null 2>&1
		eq 'a repository visible to an anonymous GET is refused with exit 4' '4' "$?"
	)
}

t_visibility_private_ok() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/visibility.sh"
		fixture 'gitbackup.origin.provider=auto'
		GB_STATE_DIR="$work/vis-private"; export GB_STATE_DIR
		http_fixture 'https://api.github.com/repos/acme/priv=404'
		( gb_visibility_ok 'https://github.com/acme/priv.git' ) >/dev/null 2>&1
		eq 'a 404 (private or nonexistent -- anonymously the same answer) is let through, exit 0' \
			'0' "$?"
	)
}

t_visibility_inconclusive_is_skipped() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/visibility.sh"
		fixture 'gitbackup.origin.provider=auto'

		GB_STATE_DIR="$work/vis-5xx"; export GB_STATE_DIR
		http_fixture 'https://api.github.com/repos/acme/flaky=500'
		( gb_visibility_ok 'https://github.com/acme/flaky.git' ) >/dev/null 2>&1
		eq 'a 5xx from the API is skipped (exit 3), never silently treated as private' '3' "$?"

		GB_STATE_DIR="$work/vis-down"; export GB_STATE_DIR
		http_fixture
		( gb_visibility_ok 'https://github.com/acme/offline.git' ) >/dev/null 2>&1
		eq 'an unreachable API is skipped (exit 3), never silently treated as private' '3' "$?"
	)
}

t_visibility_cache() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/visibility.sh"
		fixture 'gitbackup.origin.provider=auto'
		GB_STATE_DIR="$work/vis-cache"; export GB_STATE_DIR

		http_fixture 'https://api.github.com/repos/acme/priv=404'
		( gb_visibility_ok 'https://github.com/acme/priv.git' ) >/dev/null 2>&1
		eq 'first check reads the private verdict from the (mocked) network' '0' "$?"

		# Break the mock so a real second request would answer "unreachable"
		# (exit 3) instead -- a still-0 result proves the cache answered
		# without touching the network at all, not just that 0 came back twice.
		http_fixture
		( gb_visibility_ok 'https://github.com/acme/priv.git' ) >/dev/null 2>&1
		eq 'a second check within a day reuses the cached verdict' '0' "$?"

		# A day-old cache entry, written directly rather than waited for
		# (spec: kept "на сутки"/one day) -- must not be reused.
		gb_stale_ts=$(( $(command -p date +%s) - 90000 ))
		printf 'https://github.com/acme/priv.git\n%s\n0\n' "$gb_stale_ts" >"$GB_STATE_DIR/visibility"
		http_fixture 'https://api.github.com/repos/acme/priv=200'
		( gb_visibility_ok 'https://github.com/acme/priv.git' ) >/dev/null 2>&1
		eq 'a cache entry older than a day is re-checked, not reused' '4' "$?"
	)
}

t_visibility_generic_needs_acknowledgement() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/visibility.sh"
		GB_STATE_DIR="$work/vis-generic"; export GB_STATE_DIR
		GB_TEST_LOG="$work/vislog"; export GB_TEST_LOG; : >"$GB_TEST_LOG"

		fixture 'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=0'
		gb_out=$( ( gb_visibility_ok 'git@intranet.example:acme/site.git' ) 2>&1 >/dev/null )
		eq 'a generic remote without acknowledged=1 is refused with exit 2' '2' "$?"
		contains 'and the message names what a public one would expose' '/etc/shadow' "$gb_out"
		contains 'including WireGuard private keys' 'WireGuard' "$gb_out"

		fixture 'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'
		( gb_visibility_ok 'git@intranet.example:acme/site.git' ) >/dev/null 2>&1
		eq 'an acknowledged generic remote proceeds -- nothing about it can be checked' '0' "$?"
		unset GB_TEST_LOG
	)
}

# --------------------------------------------------------------------------
# usr/sbin/gitbackup
# --------------------------------------------------------------------------

cli() {
	GB_SHARE="$share" GB_STATE_DIR="$work/state" sh "$files/usr/sbin/gitbackup" "$@"
}

t_cli_usage() {
	out=$(cli 2>&1)
	contains 'bare gitbackup lists its subcommands' 'status' "$out"
	contains 'including the ones not written yet' 'restore' "$out"
}

t_cli_not_implemented() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git'
	out=$(cli collect 2>&1)
	eq 'an unwritten subcommand exits 1' '1' "$?"
	contains 'and says so instead of pretending' 'not implemented' "$out"
}

t_cli_status_json() {
	fixture 'gitbackup.main.enabled=1' 'gitbackup.main.device_id=custom' \
		'gitbackup.main.device=rt1' 'gitbackup.origin.url=https://example.org/o/r.git'
	out=$(cli status 2>/dev/null)
	if command -v python3 >/dev/null 2>&1; then
		if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
			ok 'status prints parseable JSON'
		else
			no 'status prints parseable JSON' "got [$out]"
		fi
	fi
	contains 'status reports enabled' '"enabled": true' "$out"
	contains 'status reports the device' '"device": "rt1"' "$out"
	contains 'status reports whether a token is stored' '"token_set": false' "$out"
	contains 'status reports that nothing has run yet' '"last_run": null' "$out"
}

t_cli_status_default_config() {
	# Ticket 01 review: a freshly installed router's default config --
	# device_id=hostname with the stock hostname, no url set -- must not turn
	# `gitbackup status` into exit 2. status is the one command allowed to run
	# before the device and remote are configured.
	fixture 'gitbackup.main.device_id=hostname'
	GB_TEST_BOARD='{"hostname":"OpenWrt","model":"GL.iNet GL-MT6000"}'
	export GB_TEST_BOARD
	out=$(cli status 2>/dev/null)
	eq 'status on the default config exits 0' '0' "$?"
	if command -v python3 >/dev/null 2>&1; then
		if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
			ok 'status still prints parseable JSON on the default config'
		else
			no 'status still prints parseable JSON on the default config' "got [$out]"
		fi
	fi
	contains 'status reports the config as not configured' '"configured": false' "$out"
	contains 'status reports the device as unresolved' '"device": null' "$out"
	contains 'and names device_id among what is missing' '"device_id"' "$out"
	contains 'and names url among what is missing' '"url"' "$out"
	unset GB_TEST_BOARD
}

t_cli_validation() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url='
	out=$(cli run 2>&1)
	eq 'an empty remote url exits 2' '2' "$?"
	contains 'and the message names the url' 'url' "$out"

	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.main.schedule=cron' 'gitbackup.main.cron_expr=@daily' \
		'gitbackup.origin.url=https://example.org/o/r.git'
	out=$(cli run 2>&1)
	eq 'a cron expression busybox crond cannot parse exits 2' '2' "$?"
	contains 'and the message names cron_expr' 'cron_expr' "$out"

	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=' \
		'gitbackup.origin.url=https://example.org/o/r.git'
	cli run >/dev/null 2>&1
	eq 'an empty custom device exits 2' '2' "$?"

	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git'
	cli run >/dev/null 2>&1
	eq 'a valid configuration gets past validation to the stub' '1' "$?"
}

t_cli_public_forces_scrub() {
	GB_TEST_LOG="$work/scrublog"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git' \
		'gitbackup.origin.visibility=public' 'gitbackup.security.scrub=0'
	cli status >/dev/null 2>&1
	contains 'a public remote forces scrub on and says so in the log' \
		'scrub' "$(cat "$GB_TEST_LOG")"
	out=$(cli status 2>/dev/null)
	contains 'and status reports scrub as on' '"scrub": true' "$out"
	unset GB_TEST_LOG
}

# --------------------------------------------------------------------------
# packaging
# --------------------------------------------------------------------------

t_makefile_contract() {
	mk="$root/package/gitbackup/Makefile"
	for var in PKG_NAME PKG_VERSION PKG_RELEASE PKG_LICENSE PKG_MAINTAINER; do
		if grep -q "^$var:=" "$mk"; then
			ok "Makefile declares $var"
		else
			no "Makefile declares $var" "not found in $mk"
		fi
	done
	# Spelled out rather than pattern-matched: every entry was put there by a
	# measured failure on 25.12.4, and a silent drop is how one comes back.
	want='+git +git-http +ca-bundle +jsonfilter +coreutils-stat +openssh-client +openssh-keygen'
	got=$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$mk")
	eq 'DEPENDS is exactly what the stand proved necessary' "$want" "$got"
	if grep -q '^/etc/config/gitbackup$' "$mk"; then
		ok 'the config file is declared a conffile'
	else
		no 'the config file is declared a conffile' \
			'a package upgrade would overwrite the user configuration'
	fi
}

t_owfeed_yml_matches_makefile() {
	# owfeed.yml hand-duplicates DEPENDS and conffiles from package/gitbackup/Makefile
	# while its own comments call the Makefile the source of truth for both (owfeed.yml,
	# near lines 34 and 39) -- tools/stage.sh already reads the version out of the
	# Makefile instead of repeating it, but nothing did the same for these two lists.
	# Regenerating owfeed.yml's `depends:`/`conffiles:` from the Makefile at build time
	# was considered and rejected: owfeed.yml is a static file owfeed reads directly
	# (unlike PKG_VERSION, which reaches it only through dist/VERSION via `version-from:
	# file:...`, a documented indirection), and owfeed has no equivalent file-indirection
	# for a YAML list -- inventing one would be exactly the kind of unverified API this
	# project's rules forbid. A test that fails loudly on drift is the honest version of
	# "kept in sync" for two lists that already agree today.
	mk="$root/package/gitbackup/Makefile"
	yml="$root/owfeed.yml"

	# Makefile DEPENDS, minus the package.mk '+' (select-by-default) prefix, which
	# has no owfeed equivalent (see owfeed.yml's own comment on its depends: line).
	mk_depends=$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$mk" | tr ' ' '\n' | sed 's/^+//' | sort)
	yml_depends=$(sed -n 's/^[[:space:]]*depends: \[\(.*\)\]/\1/p' "$yml" |
		tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort)
	eq 'owfeed.yml depends: matches Makefile DEPENDS' "$mk_depends" "$yml_depends"

	# The Package/gitbackup/conffiles block, one path per line between the markers.
	mk_conffiles=$(sed -n '/^define Package\/gitbackup\/conffiles$/,/^endef$/p' "$mk" | sed '1d;$d' | sort)
	yml_conffiles=$(sed -n 's/^[[:space:]]*conffiles: \[\(.*\)\]/\1/p' "$yml" |
		tr ',' '\n' | tr -d '"' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort)
	eq 'owfeed.yml conffiles: matches Makefile Package/gitbackup/conffiles' "$mk_conffiles" "$yml_conffiles"
}

t_config_sections_match_code() {
	# Ticket 01 review: the CLI once read gitbackup.remote.* while the shipped
	# config declares `config remote 'origin'` -- UCI addresses a section by
	# its quoted NAME ('origin'), not its TYPE word ('remote'), so url,
	# visibility and token_file would have resolved to nothing on every real
	# router, forever. No fixture caught it: tests/run.sh's uci stub matches
	# whatever key a fixture hands it, so a wrong key and a right one look
	# identical to it. This test does not use that stub -- it parses the
	# actual conffile that ships to the router and checks the code against
	# it, so a fixture rewritten to match a bug stays unable to hide one.
	cfg="$files/etc/config/gitbackup"
	declared=$(sed -n "s/^config [A-Za-z0-9_]*[[:space:]]*'\\([A-Za-z0-9_]*\\)'.*/\\1/p" "$cfg" | sort -u | tr '\n' ' ')
	used=$(grep -oh 'gitbackup\.[A-Za-z0-9_]*\.' \
		"$share"/*.sh "$files/usr/sbin/gitbackup" \
		"$files/etc/init.d/gitbackup" "$files/etc/uci-defaults/"* 2>/dev/null |
		sed 's/^gitbackup\.//; s/\.$//' | sort -u)
	[ -n "$used" ] || { no 'the code addresses at least one gitbackup.<section>.<option>' \
		'grep found none -- the search itself is broken'; return; }
	missing=''
	for name in $used; do
		case " $declared " in
			*" $name "*) ;;
			*) missing="$missing $name" ;;
		esac
	done
	eq 'every gitbackup.<section>.* the code addresses is a section actually declared in the shipped config' \
		'' "$missing"
}

t_no_bashisms() {
	found=''
	for f in "$share"/*.sh "$files/usr/sbin/gitbackup" "$files/etc/init.d/gitbackup" \
		"$files/etc/uci-defaults/99-gitbackup"; do
		grep -n '\[\[\|\${[A-Za-z_]*^^\|<(\|^function ' "$f" >/dev/null 2>&1 &&
			found="$found $f"
	done
	eq 'no bash-only construct reaches busybox ash' '' "$found"
}

# --------------------------------------------------------------------------

run_test 'lib.sh: gb_json_esc' t_json_esc
run_test 'lib.sh: gb_uci_get' t_uci_get
run_test 'lib.sh: gb_free_kb' t_free_kb
run_test 'lib.sh: gb_die' t_die
run_test 'lib.sh: gb_have_net' t_have_net
run_test 'device.sh: hostname strategy' t_device_hostname
run_test 'device.sh: stock hostname is refused' t_device_hostname_default
run_test 'device.sh: custom strategy' t_device_custom
run_test 'device.sh: board strategy' t_device_board
run_test 'device.sh: unknown device_id strategy' t_device_unknown_strategy
run_test 'device.sh: board strategy with no usable MAC' t_device_board_no_mac
run_test 'device.sh: gb_expand' t_expand
run_test 'collect.sh: layout (files/meta/manifest.json)' t_collect_layout
run_test 'collect.sh: paths come only from sysupgrade -l' t_collect_paths_from_sysupgrade_only
run_test 'collect.sh: symlinks are not dereferenced' t_collect_symlink_not_dereferenced
run_test 'collect.sh: manifest fields for a file' t_collect_file_manifest_fields
run_test 'collect.sh: empty directories become dir entries' t_collect_empty_dir
run_test 'collect.sh: a trailing slash in a keep.d source is stripped' t_collect_empty_dir_trailing_slash_source
run_test 'collect.sh: /etc/gitbackup/** is always hard-excluded' t_collect_hard_exclude
run_test 'collect.sh: gb_manifest_equal' t_collect_manifest_equal
run_test 'collect.sh: JSON escaping of odd paths' t_collect_json_special_chars
run_test 'remoteurl.sh: valid URL forms parse' t_remoteurl_valid_forms
run_test 'remoteurl.sh: garbage URLs are rejected outright' t_remoteurl_garbage_rejected
run_test 'remoteurl.sh: provider detection and override' t_remoteurl_provider
run_test 'remoteurl.sh: deploy-key deep links' t_remoteurl_deeplink
run_test 'visibility.sh: a publicly visible repository is refused' t_visibility_public_refused
run_test 'visibility.sh: a private/nonexistent repository is allowed' t_visibility_private_ok
run_test 'visibility.sh: 5xx and offline are skipped, not ok' t_visibility_inconclusive_is_skipped
run_test 'visibility.sh: cache is honored for a day and expires after' t_visibility_cache
run_test 'visibility.sh: generic remote requires acknowledgement' t_visibility_generic_needs_acknowledgement
run_test 'cli: usage' t_cli_usage
run_test 'cli: unwritten subcommands' t_cli_not_implemented
run_test 'cli: status json' t_cli_status_json
run_test 'cli: status on the default config' t_cli_status_default_config
run_test 'cli: configuration validation' t_cli_validation
run_test 'cli: public remote forces scrub' t_cli_public_forces_scrub
run_test 'packaging: Makefile contract' t_makefile_contract
run_test 'packaging: config sections match code' t_config_sections_match_code
run_test 'packaging: owfeed.yml matches Makefile' t_owfeed_yml_matches_makefile
run_test 'packaging: no bashisms' t_no_bashisms

passed=$(grep -c '^PASS$' "$results")
failed=$(grep -c '^FAIL$' "$results")
printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
