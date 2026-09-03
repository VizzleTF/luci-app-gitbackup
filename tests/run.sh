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
for module in "$share/lib.sh" "$share/device.sh" "$files/usr/sbin/gitbackup"; do
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
