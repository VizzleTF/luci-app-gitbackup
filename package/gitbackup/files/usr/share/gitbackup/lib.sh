# shellcheck shell=sh
#
# gitbackup -- primitives shared by every module.
#
# Sourced, never executed: defining functions is all this file does, so a test
# can pull it in and call one function without a router underneath it.
#
# Variables are prefixed _gb_ instead of being declared `local`, because
# `local` is not in POSIX sh; busybox ash has it, the shells this suite also
# runs under do not all agree, and the prefix costs nothing.
#
# Nothing here runs at load time: sourcing this file defines functions and
# touches nothing else, which is what makes it testable off the router.

# gb_log <level> <message>...
#
# level is a syslog level -- debug, info, notice, warning, err -- so it can be
# handed to logger unchanged. Syslog is the log, because `gitbackup log` reads
# it back with logread and nothing else survives a reboot on a read-only root.
gb_log() {
	_gb_level="$1"
	shift
	logger -t gitbackup -p "daemon.$_gb_level" -- "$*" 2>/dev/null
	# Anything the operator has to act on also goes to stderr: a CLI run by
	# hand that answers only into syslog looks like it did nothing.
	case "$_gb_level" in
		notice|warning|err) printf '%s: %s\n' "$_gb_level" "$*" >&2 ;;
	esac
}

# gb_die <exit-code> <message>...
#
# Exit codes are the contract of the whole package: 0 ok, 1 general error,
# 2 invalid configuration, 3 network or authentication, 4 refused for safety.
gb_die() {
	_gb_code="$1"
	shift
	gb_log err "$*"
	exit "$_gb_code"
}

# gb_uci_get <config.section.option> [default]
#
# An unset option and an empty one are the same answer here on purpose: UCI
# writes `option x ''` for a field the user cleared in LuCI, and every caller
# wants the default in both cases.
gb_uci_get() {
	_gb_value=$(uci -q get "$1") || _gb_value=''
	[ -n "$_gb_value" ] || _gb_value="${2-}"
	printf '%s\n' "$_gb_value"
}

# gb_json_esc <string>
#
# Escapes a string for use inside JSON double quotes. Written out rather than
# delegated because the base image has no JSON writer, and "just interpolate
# it" breaks on the first quote in a path -- which is exactly the input this
# package handles.
#
# Only the five characters that can actually reach us are escaped: the values
# are UCI options, filesystem paths and error messages. A NUL cannot survive a
# shell variable in the first place.
gb_json_esc() {
	_gb_rest="${1-}"
	_gb_out=''
	_gb_nl='
'
	_gb_tab=$(printf '\t')
	_gb_cr=$(printf '\r')
	while [ -n "$_gb_rest" ]; do
		# The first character: strip everything after it, then strip it.
		_gb_ch="${_gb_rest%"${_gb_rest#?}"}"
		_gb_rest="${_gb_rest#?}"
		# shellcheck disable=SC1003  # the '\' branch matches a literal backslash, not an escaped quote
		case "$_gb_ch" in
			'"') _gb_out="$_gb_out\\\"" ;;
			'\') _gb_out="$_gb_out\\\\" ;;
			"$_gb_nl") _gb_out="$_gb_out\\n" ;;
			"$_gb_tab") _gb_out="$_gb_out\\t" ;;
			"$_gb_cr") _gb_out="$_gb_out\\r" ;;
			*) _gb_out="$_gb_out$_gb_ch" ;;
		esac
	done
	printf '%s' "$_gb_out"
}

# gb_json_str <string>  -- an escaped, quoted JSON string, or null when empty.
gb_json_str() {
	if [ -z "${1-}" ]; then
		printf 'null'
	else
		printf '"%s"' "$(gb_json_esc "$1")"
	fi
}

# gb_json_bool <value>  -- true when the value is a UCI-style truth, else false.
gb_json_bool() {
	case "${1-}" in
		1|on|true|yes|enabled) printf 'true' ;;
		*) printf 'false' ;;
	esac
}

# gb_free_kb <directory>  -- free kilobytes on the filesystem holding it.
#
# -P because the default df output wraps long device names onto their own line
# and the awk below would then read the wrong row.
gb_free_kb() {
	df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# gb_have_net <host> [port]
#
# True when a TCP connection opens. There is no curl in the base image and
# busybox's `nc -z` is not built everywhere, so the probe is an ordinary
# connect fed from /dev/null: nc exits as soon as the peer sees EOF, and its
# status is the answer. A failure here is not an error -- `run` treats an
# offline router as "skipped", so cron does not mail about the internet.
gb_have_net() {
	nc -w 5 "$1" "${2:-443}" </dev/null >/dev/null 2>&1
}
