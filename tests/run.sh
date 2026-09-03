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
for module in "$share/lib.sh" "$share/device.sh" "$share/collect.sh" "$share/scrub.sh" "$share/remoteurl.sh" "$share/visibility.sh" "$share/auth.sh" "$share/askpass.sh" "$share/schedule.sh" "$share/gitio.sh" "$files/usr/sbin/gitbackup" "$files/etc/init.d/gitbackup"; do
	[ -r "$module" ] || { printf 'missing: %s\n' "$module" >&2; exit 1; }
done

# gitio.sh and the deep half of `run` are tested against a REAL local git
# repository, not a stub (interfaces.md: "Единственное исключение --
# gitio.sh и restore.sh, которые проверяются интеграционно на локальном
# bare-репозитории" -- there is no faithful way to fake object-database
# plumbing). GB_TEST_REAL_GIT is captured here, before PATH gains the git
# stub below, so that stub can delegate to it on request.
GB_TEST_REAL_GIT=$(command -v git) || { printf 'git not found on PATH\n' >&2; exit 1; }
export GB_TEST_REAL_GIT

# --------------------------------------------------------------------------
# stubs
# --------------------------------------------------------------------------

mkdir -p "$work/bin"

cat >"$work/bin/uci" <<'STUB'
#!/bin/sh
# Test double for uci(1). Two unrelated call shapes, dispatched on whether
# -c is present:
#
#   `uci -q get <path>` (no -c)      -- answers out of GB_TEST_UCI, a file of
#                                        key=value lines, for reading THIS
#                                        router's own config (gb_uci_get).
#                                        Unchanged from before scrub.sh
#                                        existed -- every other module's
#                                        fixtures depend on this exact shape.
#   `uci -c <dir> show|get|set|commit ...` -- scrub.sh's own shape, editing
#                                        real UCI text files under <dir>. A
#                                        structural parser of that format
#                                        (config/option/list lines), not a
#                                        line-regex stand-in -- verified
#                                        against openwrt/uci's list.c/cli.c
#                                        (uci_lookup_section_ref: an
#                                        anonymous section's ref is
#                                        "@type[N]", N counting only
#                                        anonymous sections of that TYPE seen
#                                        so far in file order; uci_show_value:
#                                        a list option's values print
#                                        space-separated, each individually
#                                        single-quoted, on one line) and
#                                        against the real tool built from
#                                        that source and run live on the
#                                        owlab 25.12.4 stand ("uci -t <dir>"
#                                        is the one that keeps `commit`
#                                        working -- "-P" also sets
#                                        CLI_FLAG_NOCOMMIT and silently
#                                        no-ops a later commit, verified live
#                                        the same way). Constrained to what
#                                        this suite's fixtures actually
#                                        write: quoted option/list values,
#                                        one per line, no line continuations.
#
# Every other invocation is refused loudly: a stub that answers "" to a call
# it does not understand turns a broken test green.
confdir=''
savedir=''
args=''
quiet=0
while [ $# -gt 0 ]; do
	case "$1" in
		-c) confdir="$2"; shift 2 ;;
		-t) savedir="$2"; shift 2 ;;
		-q) quiet=1; shift ;;
		*) break ;;
	esac
done

if [ -z "$confdir" ]; then
	# Original shape: `uci -q get <path>` against GB_TEST_UCI.
	[ "${1:-}" = "get" ] || { echo "uci stub: unsupported argument '${1:-}'" >&2; exit 64; }
	key="${2:-}"
	[ -n "$key" ] || { echo "uci stub: no key given" >&2; exit 64; }
	value=$(grep "^${key}=" "${GB_TEST_UCI:-/dev/null}" 2>/dev/null | head -n 1)
	if [ -z "$value" ]; then
		[ "$quiet" = 1 ] || echo "uci: Entry not found" >&2
		exit 1
	fi
	printf '%s\n' "${value#*=}"
	exit 0
fi

cmd="${1:-}"
shift 2>/dev/null

case "$cmd" in
	show)
		cfg="$1"
		f="$confdir/$cfg"
		[ -r "$f" ] || { echo "uci: Entry not found" >&2; exit 1; }
		awk -v cfg="$cfg" '
			function unq(s,   q) {
				q = substr(s, 1, 1)
				if ((q == "\x27" || q == "\"") && substr(s, length(s), 1) == q)
					return substr(s, 2, length(s) - 2)
				return s
			}
			function flushopt() {
				if (curopt != "") {
					if (nvals <= 1) {
						printf "%s.%s.%s=\x27%s\x27\n", cfg, curref, curopt, vals[1]
					} else {
						line = cfg "." curref "." curopt "="
						for (i = 1; i <= nvals; i++) {
							if (i > 1) line = line " "
							line = line "\x27" vals[i] "\x27"
						}
						print line
					}
				}
				curopt = ""; nvals = 0
			}
			/^[ \t]*config[ \t]+/ {
				flushopt()
				line = $0
				sub(/^[ \t]*config[ \t]+/, "", line)
				n = split(line, parts, /[ \t]+/)
				curtype = parts[1]
				name = (n >= 2) ? unq(parts[2]) : ""
				if (name == "") {
					c = (curtype in seen) ? seen[curtype] : 0
					curref = "@" curtype "[" c "]"
					seen[curtype] = c + 1
				} else {
					curref = name
				}
				print cfg "." curref "=" curtype
				next
			}
			/^[ \t]*option[ \t]+/ {
				flushopt()
				line = $0
				sub(/^[ \t]*option[ \t]+/, "", line)
				sub(/^[ \t]+/, "", line)
				sp = match(line, /[ \t]/)
				name = substr(line, 1, sp - 1)
				rest = substr(line, sp + 1)
				sub(/^[ \t]+/, "", rest)
				printf "%s.%s.%s=\x27%s\x27\n", cfg, curref, name, unq(rest)
				next
			}
			/^[ \t]*list[ \t]+/ {
				line = $0
				sub(/^[ \t]*list[ \t]+/, "", line)
				sub(/^[ \t]+/, "", line)
				sp = match(line, /[ \t]/)
				name = substr(line, 1, sp - 1)
				rest = substr(line, sp + 1)
				sub(/^[ \t]+/, "", rest)
				if (name != curopt) flushopt()
				curopt = name
				nvals++
				vals[nvals] = unq(rest)
				next
			}
			END { flushopt() }
		' "$f"
		;;
	get)
		path="$1"
		cfg="${path%%.*}"
		rest="${path#*.}"
		ref="${rest%%.*}"
		opt="${rest#*.}"
		out=$(uci -c "$confdir" show "$cfg" 2>/dev/null | \
			awk -F= -v want="$cfg.$ref.$opt" '$1==want{sub(/^[^=]*=/,"");print;found=1;exit} END{if(!found)exit 1}')
		rc=$?
		[ "$rc" -eq 0 ] && [ -n "$out" ] || exit 1
		printf '%s\n' "$out" | sed "s/^'//;s/'\$//"
		;;
	set)
		[ -n "$savedir" ] || { echo "uci stub: set needs -t" >&2; exit 64; }
		arg="$1"
		path="${arg%%=*}"
		val="${arg#*=}"
		cfg="${path%%.*}"
		rest="${path#*.}"
		ref="${rest%%.*}"
		opt="${rest#*.}"
		mkdir -p "$savedir"
		printf '%s\t%s\t%s\n' "$ref" "$opt" "$val" >>"$savedir/$cfg"
		;;
	commit)
		cfg="$1"
		f="$confdir/$cfg"
		delta="$savedir/$cfg"
		[ -r "$f" ] || exit 0
		[ -n "$savedir" ] && [ -r "$delta" ] || exit 0
		awk -v deltafile="$delta" '
			BEGIN {
				while ((getline line < deltafile) > 0) {
					n = split(line, f, "\t")
					newval[f[1] SUBSEP f[2]] = f[3]
				}
			}
			function unq(s,   q) {
				q = substr(s, 1, 1)
				if ((q == "\x27" || q == "\"") && substr(s, length(s), 1) == q)
					return substr(s, 2, length(s) - 2)
				return s
			}
			/^[ \t]*config[ \t]+/ {
				line = $0
				sub(/^[ \t]*config[ \t]+/, "", line)
				n = split(line, parts, /[ \t]+/)
				curtype = parts[1]
				name = (n >= 2) ? unq(parts[2]) : ""
				if (name == "") {
					c = (curtype in seen) ? seen[curtype] : 0
					curref = "@" curtype "[" c "]"
					seen[curtype] = c + 1
				} else {
					curref = name
				}
				print
				next
			}
			/^[ \t]*option[ \t]+/ {
				line = $0
				sub(/^[ \t]*option[ \t]+/, "", line)
				sub(/^[ \t]+/, "", line)
				sp = match(line, /[ \t]/)
				name = substr(line, 1, sp - 1)
				key = curref SUBSEP name
				if (key in newval) {
					indent = $0
					sub(/[^ \t].*/, "", indent)
					printf "%soption %s \x27%s\x27\n", indent, name, newval[key]
				} else {
					print
				}
				next
			}
			{ print }
		' "$f" >"$f.new" && mv "$f.new" "$f"
		;;
	*)
		echo "uci stub: unsupported command '$cmd'" >&2
		exit 64
		;;
esac
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
#
# `-b <file>` (ticket 07, `run`'s own archive step) writes a fixed,
# obviously-fake placeholder to <file> -- its content does not matter to
# anything under test, only whether/how often this stub was invoked, which
# it records as one line per call to GB_TEST_SYSUPGRADE_B_LOG when that is
# set (the seam t_gitio_archive_not_rebuilt_when_unchanged uses to prove
# `run` skips this call on an unchanged manifest, not just that the file
# happens to still be there).
case "${1:-}" in
	-l|--list-backup) ;;
	-b)
		[ -n "${GB_TEST_SYSUPGRADE_B_LOG:-}" ] && printf 'called %s\n' "$2" >>"$GB_TEST_SYSUPGRADE_B_LOG"
		printf 'fake sysupgrade backup archive\n' >"$2"
		exit 0
		;;
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

cat >"$work/bin/ssh" <<'STUB'
#!/bin/sh
# Test double for ssh(1), covering only gb_accept_hostkey's one invocation
# shape: `ssh -o UserKnownHostsFile=<file> -o StrictHostKeyChecking=accept-new
# -o BatchMode=yes -p <port> git@<host> exit`. Real ssh writes the host's key
# into -o UserKnownHostsFile even when the authentication that follows fails
# (verified live on the owlab stand, auth.sh's own comment on
# gb_accept_hostkey has the exact command and result) -- this stub
# reproduces that shape from GB_TEST_SSH_HOSTKEY, a fixed "host keytype
# base64key" line appended to whatever file -o UserKnownHostsFile= named,
# and writes nothing when GB_TEST_SSH_HOSTKEY is unset, standing in for a
# host that could not be reached at all.
known=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o)
			case "$2" in
				UserKnownHostsFile=*) known="${2#UserKnownHostsFile=}" ;;
			esac
			shift 2
			continue
			;;
		*) shift ;;
	esac
done
[ -n "$known" ] || { echo "ssh stub: no -o UserKnownHostsFile= seen" >&2; exit 64; }
[ -n "${GB_TEST_SSH_HOSTKEY:-}" ] && printf '%s\n' "$GB_TEST_SSH_HOSTKEY" >>"$known"
exit 255
STUB

cat >"$work/bin/git" <<'STUB'
#!/bin/sh
# Test double for git(1). Two entirely different jobs, picked by
# GB_TEST_GIT_REAL:
#
#   GB_TEST_GIT_REAL=1 -- gitio.sh's own functions and the deep half of
#     `run` need REAL git plumbing (hash-object/write-tree/commit-tree/
#     push against a real object database) -- there is no faithful way to
#     fake that, so this execs straight through to GB_TEST_REAL_GIT
#     (captured before this stub went on PATH). GB_TEST_GIT_REMOTE_URL/
#     GB_TEST_GIT_REMOTE_PATH, if both set, rewrite that one argument
#     first: `run` needs GB_URL to be a schema-valid https://.../ssh://...
#     string to pass gb_parse_url/gb_visibility_ok, but there is no real
#     server anywhere in this test -- so the fixture's schema-valid URL is
#     swapped for a real local bare-repo path at the last possible moment,
#     the one git itself actually receives.
#
#   unset/0 -- the original, narrow double covering only `git ls-remote
#     <url>` for cmd_test's one real-git call (ticket 04). GB_TEST_GIT_RC
#     controls the exit code (default 0); GB_TEST_GIT_ERR is written to
#     stderr when it is non-zero, standing in for git's own "fatal: ..."
#     text cmd_test folds into its error message. Unchanged by this
#     ticket -- gitio.sh's tests always set GB_TEST_GIT_REAL=1 instead of
#     touching this branch.
if [ "${GB_TEST_GIT_REAL:-0}" = 1 ]; then
	if [ -n "${GB_TEST_GIT_REMOTE_URL:-}" ] && [ -n "${GB_TEST_GIT_REMOTE_PATH:-}" ]; then
		_gb_oldifs="$IFS"
		IFS='
'
		set -f
		set -- $(for _gb_a in "$@"; do
			if [ "$_gb_a" = "$GB_TEST_GIT_REMOTE_URL" ]; then
				printf '%s\n' "$GB_TEST_GIT_REMOTE_PATH"
			else
				printf '%s\n' "$_gb_a"
			fi
		done)
		set +f
		IFS="$_gb_oldifs"
	fi
	exec "$GB_TEST_REAL_GIT" "$@"
fi
case "${1:-}" in
	ls-remote) ;;
	*) echo "git stub: unsupported subcommand '${1:-}'" >&2; exit 64 ;;
esac
rc="${GB_TEST_GIT_RC:-0}"
if [ "$rc" -ne 0 ]; then
	printf '%s\n' "${GB_TEST_GIT_ERR:-git stub: authentication failed}" >&2
fi
exit "$rc"
STUB

cat >"$work/bin/df" <<'STUB'
#!/bin/sh
# Test double for df(1), used only through lib.sh's gb_free_kb ("df -Pk
# <dir>", NR==2 $4). GB_TEST_DF_KB, when set, prints a synthetic Avail
# column so cmd_run's space check (ticket 07, "недостаток места -> exit 1
# с числами") can be exercised deterministically -- the real free space on
# whatever machine runs this suite is not a number this test controls.
# Unset (the default): straight through to the host's real df, same
# translate-on-request shape as the stat/date stubs above.
if [ -z "${GB_TEST_DF_KB:-}" ]; then
	exec command -p df "$@"
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted-on\n'
printf 'test 1 1 %s 1%% %s\n' "$GB_TEST_DF_KB" "${2:-/tmp}"
STUB

cat >"$work/bin/flock" <<'STUB'
#!/bin/sh
# Test double for busybox flock(1)'s FD form (`flock -n FD`). There is no
# flock(1) on macOS at all, and the real locking semantics are the
# kernel's job, not this suite's -- this only lets cmd_run's own branch on
# flock's exit code be tested deterministically, via GB_TEST_FLOCK_LOCKED.
# Unset (the default): the lock is free, same as a router that has never
# run `run` twice at once.
[ "${GB_TEST_FLOCK_LOCKED:-0}" = 1 ] && exit 1
exit 0
STUB

cat >"$work/bin/logread" <<'STUB'
#!/bin/sh
# Test double for logread(1) (cmd_log, ticket 07). Only the one shape
# cmd_log actually uses, `-e <pattern>`; answers out of GB_TEST_LOGREAD, a
# fixture file of already-formatted log lines, filtered the same way the
# real tool's own -e does (a plain substring/regexp match, not anchored).
[ "${1:-}" = "-e" ] || { echo "logread stub: expected -e, got '${1:-}'" >&2; exit 64; }
pattern="${2:-}"
grep -e "$pattern" "${GB_TEST_LOGREAD:-/dev/null}" 2>/dev/null
exit 0
STUB

cat >"$work/bin/date" <<'STUB'
#!/bin/sh
# Test double for busybox date(1), backed by the host's real date(1).
# schedule.sh only ever uses two of the forms busybox `date --help` lists
# under "Recognized TIME formats" on the 25.12.4 stand: `date -u +FMT` (now)
# and `date -u -d @<epoch> +FMT` (format a given epoch). GNU date (Linux CI,
# and busybox itself) already understands both directly and this stub just
# execs through to it; macOS ships a BSD date with no -d at all, so on
# Darwin this translates the epoch form to BSD's own `-r <epoch>` (same
# translate-only-on-Darwin strategy as the stat stub above).
if [ "$(uname -s)" != "Darwin" ]; then
	exec command -p date "$@"
fi
epoch=""
fmt="+%s"
while [ $# -gt 0 ]; do
	case "$1" in
		-u) ;;
		-d)
			shift
			case "$1" in
				'@'*) epoch="${1#@}" ;;
				*) echo "date stub: unsupported -d value '$1'" >&2; exit 64 ;;
			esac
			;;
		+*) fmt="$1" ;;
		*) echo "date stub: unsupported argument '$1'" >&2; exit 64 ;;
	esac
	shift
done
if [ -n "$epoch" ]; then
	/bin/date -u -r "$epoch" "$fmt"
else
	/bin/date -u "$fmt"
fi
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

# t_have_net_busybox_shape -- D01 itself: the OLD body (`nc -w 5 host port`)
# fails this test outright, because this image's real busybox nc (v1.37.0,
# confirmed live on the owlab stand) is `nc [IPADDR PORT]` and nothing
# else -- any flag at all makes it print its usage banner and exit 1. This
# stub reproduces exactly that shape rather than a generic fake, so a
# regression back to passing nc any flag turns this red for the right
# reason.
t_have_net_busybox_shape() {
	(
		. "$share/lib.sh"
		# A dedicated directory, not $work/bin (already first on this whole
		# suite's PATH): overwriting nc there would leak this fake nc into
		# every test that runs afterward, including run's own network
		# precheck further down this file -- shellcheck (SC2030/SC2031)
		# flags exactly this shape of mistake for a bare `PATH=` assignment
		# inside a subshell, which is what caught it here.
		mkdir -p "$work/nc-busybox-shape"
		cat >"$work/nc-busybox-shape/nc" <<'STUB'
#!/bin/sh
case "$1" in
	-*) echo "usage: nc [IPADDR PORT]" >&2; exit 1 ;;
esac
[ "$#" -eq 2 ] || { echo "usage: nc [IPADDR PORT]" >&2; exit 1; }
exit 0
STUB
		chmod +x "$work/nc-busybox-shape/nc"
		PATH="$work/nc-busybox-shape:$PATH" gb_have_net 127.0.0.1 443
		eq 'gb_have_net succeeds against a busybox nc that only accepts IPADDR PORT (D01)' '0' "$?"
	)
}

# t_have_net_bounded_timeout -- a host that never answers at all (no RST,
# no reply) must not hang gb_have_net for the kernel's own multi-minute
# connect timeout. A stub nc that just sleeps stands in for that address;
# gb_have_net's own 5s watchdog has to kill it well inside this test's
# generous 8s ceiling.
t_have_net_bounded_timeout() {
	(
		. "$share/lib.sh"
		mkdir -p "$work/nc-hangs"
		cat >"$work/nc-hangs/nc" <<'STUB'
#!/bin/sh
sleep 30
STUB
		chmod +x "$work/nc-hangs/nc"
		_gb_start=$(date +%s)
		PATH="$work/nc-hangs:$PATH" gb_have_net 10.255.255.1 443
		_gb_rc=$?
		_gb_elapsed=$(($(date +%s) - _gb_start))
		if [ "$_gb_rc" -ne 0 ]; then
			ok 'gb_have_net reports failure for a host that never answers'
		else
			no 'gb_have_net reports failure for a host that never answers' "got rc=$_gb_rc"
		fi
		if [ "$_gb_elapsed" -le 15 ]; then
			ok 'gb_have_net returns within its own bound instead of hanging'
		else
			no 'gb_have_net returns within its own bound instead of hanging' "took ${_gb_elapsed}s"
		fi
	)
}

# t_have_net_no_leaked_watchdog -- found live on the owlab stand, not by
# any unit test until this one: the previous implementation's watchdog was
# `( sleep 5; kill $ncpid ) & watchpid=$!; ...; kill $watchpid` -- and
# killing that SUBSHELL does not kill the plain `sleep 5` still running
# inside it, a separate process that survives, orphaned, for whatever time
# was left. Confirmed live: that orphaned sleep still held run's own
# step-1 flock fd it had inherited, long after the `run` process that
# opened it had already exited, making a SECOND `run` right after see the
# lock as busy for no reason. `nc` finishing well before the 5s bound (a
# real open port, or -- as here -- a refused connection, both near-
# instant) is exactly the case that used to leak; this fixture never
# spawns "sleep 5" anywhere else, so finding one running a moment later is
# an unambiguous, specific signal of the leak, not a guess.
t_have_net_no_leaked_watchdog() {
	(
		. "$share/lib.sh"
		command -v pgrep >/dev/null 2>&1 || return 0
		gb_have_net 127.0.0.1 1
		sleep 0.3
		if pgrep -f '^sleep 5$' >/dev/null 2>&1; then
			no 'gb_have_net leaves no orphaned watchdog process behind' 'found a leftover "sleep 5" process'
		else
			ok 'gb_have_net leaves no orphaned watchdog process behind'
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
# scrub.sh
# --------------------------------------------------------------------------

# scrub_fixture -- same starting point as collect_fixture (gb_scrub's tests
# all start from a real gb_collect'd tree, not a hand-assembled manifest, so
# a bug in how gb_scrub touches entries[]/scrubbed[] shows up against the
# same manifest shape collect.sh actually writes), plus a config directory
# to drop UCI fixture files into and the real, shipped scrub.list -- these
# tests are exercising ticket 05's own scrub.list content, not a stand-in.
scrub_fixture() {
	collect_fixture
	mkdir -p "$work/froot/etc/config"
	GB_SCRUB_LIST="$share/scrub.list"; export GB_SCRUB_LIST
}

t_scrub_no_side_effect_on_source() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		scrub_fixture
		cat >"$work/froot/etc/config/wireless" <<'EOF'
config wifi-iface 'default_radio0'
	option key 'topsecretpsk'
EOF
		sysupgrade_list '/etc/config/wireless'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_before=$(cat "$work/out/files/etc/config/wireless")

		# Sourcing scrub.sh defines functions and touches nothing else --
		# gb_scrub is never called in this test.
		. "$share/scrub.sh"

		eq 'sourcing scrub.sh alone leaves an already-collected tree untouched' \
			"$gb_before" "$(cat "$work/out/files/etc/config/wireless")"
	)
}

t_scrub_wireless() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		# ht_capab lives on a DIFFERENT section (radio0, wifi-device) than the
		# key being redacted (default_radio0, wifi-iface) but in the SAME
		# file -- exactly the shape a whole-file sed pass risks corrupting.
		cat >"$work/froot/etc/config/wireless" <<'EOF'
config wifi-device 'radio0'
	option type 'mac80211'
	option channel '11'
	list ht_capab 'SHORT-GI-20'
	list ht_capab 'HT40+'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option ssid 'MyWiFi'
	option encryption 'psk2'
	option key 'supersecretpassword'
EOF
		sysupgrade_list '/etc/config/wireless'
		gb_collect "$work/out" >/dev/null 2>&1

		gb_out=$(gb_scrub "$work/out")
		gb_after=$(cat "$work/out/files/etc/config/wireless")

		case "$gb_after" in
			*supersecretpassword*) no 'the WPA PSK is gone from the config file' 'found it' ;;
			*) ok 'the WPA PSK is gone from the config file' ;;
		esac
		contains 'replaced with the placeholder, not a hash' \
			"option key '<gitbackup:redacted>'" "$gb_after"
		contains 'the multi-line ht_capab list keeps its first entry' \
			"list ht_capab 'SHORT-GI-20'" "$gb_after"
		contains 'and its second entry -- neither was lost or merged' \
			"list ht_capab 'HT40+'" "$gb_after"
		contains 'gb_scrub prints the redacted option path on stdout' \
			'wireless.default_radio0.key' "$gb_out"
		case "$gb_out" in
			*supersecretpassword*) no 'gb_scrub never prints the secret value itself' 'found it' ;;
			*) ok 'gb_scrub never prints the secret value itself' ;;
		esac

		gb_manifest_text=$(cat "$(gb_manifest_path "$work/out")")
		contains 'manifest.scrubbed records the file path' \
			'"path":"/etc/config/wireless"' "$gb_manifest_text"
		contains 'and the fully-qualified option that was redacted' \
			'"option":"wireless.default_radio0.key"' "$gb_manifest_text"
		case "$gb_manifest_text" in
			*supersecretpassword*) no 'the secret value never reaches manifest.json' 'found it' ;;
			*) ok 'the secret value never reaches manifest.json' ;;
		esac
		gb_want_sha=$(sha256sum "$work/out/files/etc/config/wireless" | awk '{print $1}')
		contains "entries[]'s sha256 for the scrubbed file matches the file as scrubbed" \
			"\"sha256\":\"$gb_want_sha\"" "$gb_manifest_text"
	)
}

t_scrub_network_pppoe() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		cat >"$work/froot/etc/config/network" <<'EOF'
config interface 'wan'
	option proto 'pppoe'
	option ifname 'eth1'
	option username 'isp_user'
	option password 'isp_pass123'
EOF
		sysupgrade_list '/etc/config/network'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_scrub "$work/out" >/dev/null
		gb_after=$(cat "$work/out/files/etc/config/network")

		contains 'PPPoE username is redacted' "option username '<gitbackup:redacted>'" "$gb_after"
		contains 'PPPoE password is redacted' "option password '<gitbackup:redacted>'" "$gb_after"
		contains 'an unrelated option (ifname) is left alone' "option ifname 'eth1'" "$gb_after"
	)
}

t_scrub_openvpn() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		# openvpn's own /etc/config/openvpn migrates onto network/interface
		# (openwrt/packages net/openvpn/files/etc/uci-defaults/60_openvpn_migrate.sh,
		# see scrub.list) -- this is the post-migration shape a real router has.
		cat >"$work/froot/etc/config/network" <<'EOF'
config interface 'myvpn'
	option proto 'openvpn'
	option ovpnproto 'udp'
	option cert_password 'clientcertpassphrase'
EOF
		sysupgrade_list '/etc/config/network'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_scrub "$work/out" >/dev/null
		gb_after=$(cat "$work/out/files/etc/config/network")

		contains 'OpenVPN client cert passphrase is redacted' \
			"option cert_password '<gitbackup:redacted>'" "$gb_after"
		contains 'the transport option is left alone' "option ovpnproto 'udp'" "$gb_after"
	)
}

t_scrub_wireguard() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		# The peer section's TYPE is "wireguard_wg0" -- dynamic, per interface
		# name (openwrt/luci wireguard.js, see scrub.list) -- and carries both
		# the redacted preshared_key and an untouched multi-value
		# allowed_ips list in the very same section.
		cat >"$work/froot/etc/config/network" <<'EOF'
config interface 'wg0'
	option proto 'wireguard'
	option private_key 'wgInterfacePrivateKeyBASE64=='

config wireguard_wg0
	option public_key 'peerPublicKeyBASE64=='
	option preshared_key 'wgPresharedKeyBASE64=='
	list allowed_ips '10.0.0.0/24'
	list allowed_ips '10.0.1.0/24'
EOF
		sysupgrade_list '/etc/config/network'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_out=$(gb_scrub "$work/out")
		gb_after=$(cat "$work/out/files/etc/config/network")

		contains 'the interface private key is redacted' \
			"option private_key '<gitbackup:redacted>'" "$gb_after"
		contains 'the peer preshared key is redacted' \
			"option preshared_key '<gitbackup:redacted>'" "$gb_after"
		contains 'the peer public key is left alone (not a secret)' \
			"option public_key 'peerPublicKeyBASE64=='" "$gb_after"
		contains 'the multi-value allowed_ips list keeps its first entry' \
			"list allowed_ips '10.0.0.0/24'" "$gb_after"
		contains 'and its second entry, in the very same section as the redacted key' \
			"list allowed_ips '10.0.1.0/24'" "$gb_after"
		contains 'gb_scrub names the dynamic wireguard_wg0 type in its record' \
			'network.@wireguard_wg0[0].preshared_key' "$gb_out"
	)
}

t_scrub_ddns() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		cat >"$work/froot/etc/config/ddns" <<'EOF'
config service 'myddns'
	option lookup_host 'host.example.org'
	option username 'ddnsuser'
	option password 'ddnstoken123'
EOF
		sysupgrade_list '/etc/config/ddns'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_scrub "$work/out" >/dev/null
		gb_after=$(cat "$work/out/files/etc/config/ddns")

		contains 'DDNS username is redacted' "option username '<gitbackup:redacted>'" "$gb_after"
		contains 'DDNS password/token is redacted' "option password '<gitbackup:redacted>'" "$gb_after"
		contains 'the lookup_host option is left alone' "option lookup_host 'host.example.org'" "$gb_after"
	)
}

t_scrub_openconnect() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		cat >"$work/froot/etc/config/network" <<'EOF'
config interface 'ocvpn'
	option proto 'openconnect'
	option server 'vpn.example.org'
	option password2 'otp-123456'
	option userkey '-----BEGIN PRIVATE KEY-----FAKE-----END PRIVATE KEY-----'
EOF
		sysupgrade_list '/etc/config/network'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_scrub "$work/out" >/dev/null
		gb_after=$(cat "$work/out/files/etc/config/network")

		contains 'the OTP/second-factor password is redacted' \
			"option password2 '<gitbackup:redacted>'" "$gb_after"
		contains 'the inline PEM private key is redacted' \
			"option userkey '<gitbackup:redacted>'" "$gb_after"
		contains 'the server address is left alone' "option server 'vpn.example.org'" "$gb_after"
	)
}

t_scrub_mwan3_has_nothing_to_redact() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		# scrub.list carries no mwan3 pattern at all (checked and found to
		# have no inline UCI secret, see scrub.list's own header) -- this
		# proves gb_scrub leaves an mwan3 config it iterates over completely
		# alone rather than merely "having no pattern to try".
		cat >"$work/froot/etc/config/mwan3" <<'EOF'
config interface 'wan'
	option enabled '1'
	option family 'ipv4'

config member 'wan_m1'
	option interface 'wan'
	option metric '1'
EOF
		sysupgrade_list '/etc/config/mwan3'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_before=$(cat "$work/out/files/etc/config/mwan3")
		gb_manifest_before=$(cat "$(gb_manifest_path "$work/out")")

		gb_out=$(gb_scrub "$work/out")

		eq 'mwan3 config is byte-for-byte unchanged' "$gb_before" \
			"$(cat "$work/out/files/etc/config/mwan3")"
		eq 'gb_scrub prints nothing -- nothing was redacted' '' "$gb_out"
		eq 'manifest.json is unchanged too (no rehash of an untouched file)' \
			"$gb_manifest_before" "$(cat "$(gb_manifest_path "$work/out")")"
	)
}

t_scrub_option_not_present_is_left_alone() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		# A wifi-iface with no 'key' at all (open network) -- gb_scrub must
		# not fabricate one. Verified against openwrt/uci's list.c uci_set:
		# `set` on a nonexistent option CREATES it, so the existence check
		# this guards is load-bearing, not defensive dead code.
		cat >"$work/froot/etc/config/wireless" <<'EOF'
config wifi-iface 'open_ap'
	option device 'radio0'
	option ssid 'OpenNetwork'
	option encryption 'none'
EOF
		sysupgrade_list '/etc/config/wireless'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_out=$(gb_scrub "$work/out")

		case "$(cat "$work/out/files/etc/config/wireless")" in
			*'option key'*) no 'no key option is fabricated on an open network' 'one appeared' ;;
			*) ok 'no key option is fabricated on an open network' ;;
		esac
		eq 'and nothing was recorded as scrubbed' '' "$gb_out"
	)
}

t_scrub_dedupes_overlapping_patterns() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		# Found live on the owlab stand: gitbackup.security's own shipped
		# default (list scrub_option 'wireless.@wifi-iface[*].key', ticket
		# 01) is the exact same line scrub.list already carries. Redacting
		# was correct either way, but the option got PRINTED and RECORDED
		# in manifest.scrubbed twice, once per source that named it.
		fixture 'gitbackup.security.scrub_option=wireless.@wifi-iface[*].key'
		cat >"$work/froot/etc/config/wireless" <<'EOF'
config wifi-iface 'default_radio0'
	option key 'onlyredactonce'
EOF
		sysupgrade_list '/etc/config/wireless'
		gb_collect "$work/out" >/dev/null 2>&1
		gb_out=$(gb_scrub "$work/out")

		eq 'gb_scrub prints the redacted option exactly once' \
			1 "$(printf '%s\n' "$gb_out" | grep -c 'wireless.default_radio0.key')"
		gb_manifest_text=$(cat "$(gb_manifest_path "$work/out")")
		eq 'manifest.scrubbed records it exactly once too' \
			1 "$(printf '%s\n' "$gb_manifest_text" | grep -c '"option":"wireless.default_radio0.key"')"
	)
}

t_scrub_hard_exclude_pattern_survives_a_real_glob_match() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		# Found live on the owlab stand, where /etc/dropbear genuinely has
		# host keys matching the real pattern: unquoted `set -- $_gb_pat`
		# doesn't just trim the mandatory space after "#public:", it
		# pathname-expands the pattern THEN AND THERE against the real
		# filesystem root (an absolute pattern glob-expands against root
		# regardless of cwd) -- so on a host where something happens to
		# match, $_gb_pat silently became that real path instead of staying
		# the literal pattern, and outdir/files was never even looked at
		# under the intended name. Reproduced host-portably with /etc/passwd
		# standing in for a real host key: any POSIX host running this
		# suite has one, so a hard-exclude pattern of "/etc/pass*" is
		# guaranteed to have something to wrongly expand into if the fix
		# regresses.
		GB_EXCLUDE_LIST="$work/exclude.list"; export GB_EXCLUDE_LIST
		printf '#public: /etc/pass*\n' >"$GB_EXCLUDE_LIST"
		mkdir -p "$work/froot/etc"
		printf 'not-a-real-passwd-file\n' >"$work/froot/etc/passfile"
		sysupgrade_list '/etc/passfile'
		gb_collect "$work/out" >/dev/null 2>&1

		gb_scrub "$work/out" >/dev/null

		if [ -e "$work/out/files/etc/passfile" ]; then
			no 'the pattern still matches inside outdir/files, not a real /etc/passwd it collided with' \
				'still present'
		else
			ok 'the pattern still matches inside outdir/files, not a real /etc/passwd it collided with'
		fi
	)
}

t_scrub_hard_exclude_public() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"; . "$share/scrub.sh"
		scrub_fixture
		mkdir -p "$work/froot/etc/dropbear" "$work/froot/etc/ssl/private" "$work/froot/etc/wireguard"
		printf 'root:$1$hash:19000:0:99999:7:::\n' >"$work/froot/etc/shadow"
		printf 'fake-rsa-host-key-data\n' >"$work/froot/etc/dropbear/dropbear_rsa_host_key"
		printf 'fake-tls-key-data\n' >"$work/froot/etc/uhttpd.key"
		printf 'fake-private-key-data\n' >"$work/froot/etc/ssl/private/server.key"
		printf 'fake-wg-key-data\n' >"$work/froot/etc/wireguard/wg0.key"
		printf 'keep me\n' >"$work/froot/etc/keepme"
		sysupgrade_list '/etc/shadow' '/etc/dropbear/dropbear_rsa_host_key' \
			'/etc/uhttpd.key' '/etc/ssl/private/server.key' '/etc/wireguard/wg0.key' '/etc/keepme'

		gb_collect "$work/out" >/dev/null 2>&1
		gb_scrub "$work/out" >/dev/null

		for gb_p in etc/shadow etc/dropbear/dropbear_rsa_host_key etc/uhttpd.key \
			etc/ssl/private/server.key etc/wireguard/wg0.key; do
			if [ -e "$work/out/files/$gb_p" ]; then
				no "$gb_p is gone from the tree entirely" 'still present'
			else
				ok "$gb_p is gone from the tree entirely"
			fi
		done
		if [ -f "$work/out/files/etc/keepme" ]; then
			ok 'a file the public hard-exclude does not name survives'
		else
			no 'a file the public hard-exclude does not name survives' 'missing'
		fi

		gb_manifest_text=$(cat "$(gb_manifest_path "$work/out")")
		for gb_p in /etc/shadow /etc/dropbear/dropbear_rsa_host_key /etc/uhttpd.key \
			/etc/ssl/private/server.key /etc/wireguard/wg0.key; do
			case "$gb_manifest_text" in
				*"\"path\":\"$gb_p\""*) no "manifest.json's entries[] drops $gb_p too" 'found it' ;;
				*) ok "manifest.json's entries[] drops $gb_p too" ;;
			esac
		done
		contains 'entries[] still lists the file that was not hard-excluded' \
			'"path":"/etc/keepme"' "$gb_manifest_text"
	)
}

t_scrub_private_tree_untouched_by_not_scrubbing() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		scrub_fixture
		# visibility=private means the caller (usr/sbin/gitbackup's
		# _gb_effective_scrub, already covered by
		# t_cli_public_forces_scrub/t_cli_private_leaves_scrub_off) never
		# calls gb_scrub at all -- proved here by building a real collected
		# tree and confirming it still has every secret gb_scrub would
		# otherwise redact, since this test does not call it either.
		mkdir -p "$work/froot/etc/dropbear"
		cat >"$work/froot/etc/config/wireless" <<'EOF'
config wifi-iface 'default_radio0'
	option key 'stillherepsk'
EOF
		printf 'fake-host-key\n' >"$work/froot/etc/dropbear/dropbear_rsa_host_key"
		printf 'root:hash:0:0:99999:7:::\n' >"$work/froot/etc/shadow"
		sysupgrade_list '/etc/config/wireless' '/etc/dropbear/dropbear_rsa_host_key' '/etc/shadow'

		gb_collect "$work/out" >/dev/null 2>&1

		contains 'the wifi key is still there in full' 'stillherepsk' \
			"$(cat "$work/out/files/etc/config/wireless")"
		if [ -f "$work/out/files/etc/shadow" ]; then
			ok '/etc/shadow is present -- private is not even hard-excluded'
		else
			no '/etc/shadow is present -- private is not even hard-excluded' 'missing'
		fi
		if [ -f "$work/out/files/etc/dropbear/dropbear_rsa_host_key" ]; then
			ok 'the dropbear host key is present too'
		else
			no 'the dropbear host key is present too' 'missing'
		fi
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
# auth.sh
# --------------------------------------------------------------------------

t_auth_git_env() {
	(
		. "$share/lib.sh"; . "$share/auth.sh"
		GB_ETC_DIR="$work/etc-ge"; export GB_ETC_DIR
		GB_SHARE="$share"; export GB_SHARE

		fixture 'gitbackup.origin.key_file=/etc/gitbackup/id_ed25519' 'gitbackup.origin.ca_file='
		out=$(gb_git_env)
		contains 'GIT_SSH_COMMAND names the configured key with -i' '/etc/gitbackup/id_ed25519' "$out"
		contains 'and passes it via -i' " -i " "$out"
		contains 'GIT_SSH_COMMAND points UserKnownHostsFile at GB_ETC_DIR' \
			"UserKnownHostsFile" "$out"
		contains 'at the known_hosts path under GB_ETC_DIR' "$work/etc-ge/known_hosts" "$out"
		contains 'GIT_SSH_COMMAND enforces StrictHostKeyChecking=yes' 'StrictHostKeyChecking=yes' "$out"
		contains 'GIT_SSH_COMMAND never prompts (BatchMode=yes)' 'BatchMode=yes' "$out"
		contains 'GIT_ASKPASS points at askpass.sh, never a raw credential' "$share/askpass.sh" "$out"
		case "$out" in
			*GIT_SSL_CAINFO*) no 'GIT_SSL_CAINFO is absent when ca_file is empty' "$out" ;;
			*) ok 'GIT_SSL_CAINFO is absent when ca_file is empty' ;;
		esac

		fixture 'gitbackup.origin.key_file=/etc/gitbackup/id_ed25519' \
			'gitbackup.origin.ca_file=/etc/gitbackup/ca.pem'
		out=$(gb_git_env)
		contains 'option ca_file becomes GIT_SSL_CAINFO' 'GIT_SSL_CAINFO=' "$out"
		contains 'carrying the configured CA path' '/etc/gitbackup/ca.pem' "$out"
		case "$out" in
			*sslVerify=false*|*GIT_SSL_NO_VERIFY*)
				no 'never disables certificate verification, even with a CA configured' "$out" ;;
			*) ok 'never disables certificate verification, even with a CA configured' ;;
		esac

		# A key_file with a space and a single quote must survive both
		# layers of quoting: eval'ing gb_git_env's own output, and then a
		# shell actually running the resulting GIT_SSH_COMMAND (which is
		# exactly what git itself does with it) must still see the whole
		# path as one argument -- not two, not truncated at the quote. This
		# runs the real string through a real shell instead of recomputing
		# the escaping by hand, which could only ever agree with itself.
		_gb_weird="/etc/git backup/id'key"
		fixture "gitbackup.origin.key_file=$_gb_weird" 'gitbackup.origin.ca_file='
		(
			eval "$(gb_git_env)"
			mkdir -p "$work/argvcheck"
			cat >"$work/argvcheck/ssh" <<'FAKESSH'
#!/bin/sh
for gb_a in "$@"; do printf '<%s>\n' "$gb_a"; done
FAKESSH
			chmod +x "$work/argvcheck/ssh"
			_gb_argv=$(PATH="$work/argvcheck:$PATH" sh -c "$GIT_SSH_COMMAND")
			contains 'a key_file with a space and a quote is one argument when GIT_SSH_COMMAND actually runs' \
				"<$_gb_weird>" "$_gb_argv"
		)
	)
}

t_auth_keygen() {
	(
		. "$share/lib.sh"; . "$share/auth.sh"
		_gb_key="$work/authkeys/id_ed25519"
		fixture "gitbackup.origin.key_file=$_gb_key"

		gb_keygen >/dev/null 2>&1
		eq 'gb_keygen returns 0 on first generation' '0' "$?"
		if [ -f "$_gb_key" ]; then ok 'the private key file exists'; else no 'the private key file exists' 'missing'; fi
		if [ -f "$_gb_key.pub" ]; then ok 'the public key file exists'; else no 'the public key file exists' 'missing'; fi

		_gb_mug=$(stat -c '%a %u %g' "$_gb_key" 2>/dev/null)
		# shellcheck disable=SC2086
		set -- $_gb_mug
		eq 'the private key is 0600' '600' "$1"
		_gb_dmug=$(stat -c '%a %u %g' "$(dirname "$_gb_key")" 2>/dev/null)
		# shellcheck disable=SC2086
		set -- $_gb_dmug
		eq 'the containing directory is 0700' '700' "$1"

		contains 'the generated key really is ed25519' 'ssh-ed25519' "$(cat "$_gb_key.pub")"

		_gb_before=$(cat "$_gb_key")
		gb_keygen >/dev/null 2>&1
		eq 'calling gb_keygen again with no force argument refuses' '1' "$?"
		eq 'and the existing key is left untouched' "$_gb_before" "$(cat "$_gb_key")"

		gb_keygen force >/dev/null 2>&1
		eq 'a non-empty force argument regenerates the key' '0' "$?"
		if [ "$(cat "$_gb_key")" = "$_gb_before" ]; then
			no 'the key actually changed after force' 'identical bytes as before'
		else
			ok 'the key actually changed after force'
		fi
	)
}

t_auth_pubkey() {
	(
		. "$share/lib.sh"; . "$share/auth.sh"
		_gb_key="$work/authkeys2/id_ed25519"
		fixture "gitbackup.origin.key_file=$_gb_key"

		out=$( ( gb_pubkey ) 2>&1 )
		eq 'pubkey before any key exists fails' '1' "$?"
		contains 'and tells the operator to run keygen first' 'keygen' "$out"

		gb_keygen >/dev/null 2>&1
		_gb_want=$(cat "$_gb_key.pub")
		eq 'pubkey prints exactly the generated .pub file' "$_gb_want" "$(gb_pubkey)"

		rm -f "$_gb_key.pub"
		contains 'pubkey derives the public half from the private key when .pub is missing' \
			'ssh-ed25519' "$(gb_pubkey)"
	)
}

t_auth_accept_hostkey() {
	(
		. "$share/lib.sh"; . "$share/auth.sh"

		GB_ETC_DIR="$work/etc-hk1"; export GB_ETC_DIR
		unset GB_TEST_SSH_HOSTKEY
		out=$( ( gb_accept_hostkey unreachable.example 22 </dev/null ) 2>&1 )
		eq 'a host whose key could not be obtained returns 2' '2' "$?"
		if [ -e "$GB_ETC_DIR/known_hosts" ]; then
			no 'nothing is written when the host is unreachable' 'known_hosts exists'
		else
			ok 'nothing is written when the host is unreachable'
		fi

		GB_ETC_DIR="$work/etc-hk2"; export GB_ETC_DIR
		GB_TEST_SSH_HOSTKEY='example.com ssh-ed25519 AAAAtestkey'; export GB_TEST_SSH_HOSTKEY
		out=$( ( printf 'n\n' | gb_accept_hostkey example.com 22 ) 2>&1 )
		eq 'declining the fingerprint returns 1' '1' "$?"
		if [ -e "$GB_ETC_DIR/known_hosts" ]; then
			no 'and nothing was written on decline' 'known_hosts exists'
		else
			ok 'and nothing was written on decline'
		fi

		( printf 'y\n' | gb_accept_hostkey example.com 22 ) >/dev/null 2>&1
		eq 'accepting the fingerprint returns 0' '0' "$?"
		contains 'and the key is appended to known_hosts' 'example.com ssh-ed25519 AAAAtestkey' \
			"$(cat "$GB_ETC_DIR/known_hosts")"
		_gb_khmug=$(stat -c '%a %u %g' "$GB_ETC_DIR/known_hosts" 2>/dev/null)
		# shellcheck disable=SC2086
		set -- $_gb_khmug
		eq 'known_hosts is written 0600' '600' "$1"

		( gb_accept_hostkey example.com 22 </dev/null ) >/dev/null 2>&1
		eq 'a host already in known_hosts is a silent no-op, exit 0 with no prompt' '0' "$?"
		unset GB_TEST_SSH_HOSTKEY
	)
}

t_askpass() {
	(
		GB_SHARE="$share"; export GB_SHARE
		_gb_token_file="$work/token1"
		printf 'ghp_supersecrettoken\n' >"$_gb_token_file"
		fixture "gitbackup.origin.token_file=$_gb_token_file"

		# The username prompt must NEVER get the token (this file's own
		# comment explains why: git echoes whatever the username prompt
		# returns into the URL of its next prompt, handed to askpass again
		# as argv -- a token answered here would leak into that argv on the
		# very next call, exactly what "never in argv" forbids). Only the
		# password prompt gets the real token.
		_gb_user_answer=$(sh "$share/askpass.sh" "Username for 'https://github.com': ")
		case "$_gb_user_answer" in
			ghp_supersecrettoken) no 'the username prompt is never answered with the token' "$_gb_user_answer" ;;
			*) ok 'the username prompt is never answered with the token' ;;
		esac
		if [ -n "$_gb_user_answer" ]; then
			ok 'and it answers with something non-empty (git requires that)'
		else
			no 'and it answers with something non-empty (git requires that)' 'empty'
		fi

		eq 'answers a password prompt with the token' 'ghp_supersecrettoken' \
			"$(sh "$share/askpass.sh" "Password for 'https://gitbackup@github.com': ")"

		rm -f "$_gb_token_file"
		_gb_user_answer2=$(sh "$share/askpass.sh" "Username for 'https://github.com': ")
		eq 'the username prompt still succeeds with no token file at all' '0' "$?"
		if [ -n "$_gb_user_answer2" ]; then
			ok 'and still answers with something non-empty'
		else
			no 'and still answers with something non-empty' 'empty'
		fi

		out=$( ( sh "$share/askpass.sh" 'Password: ' ) 2>&1 )
		eq 'a password prompt with no readable token file fails outright, exit 1' '1' "$?"
		contains 'and the message names the missing token_file' 'token' "$out"
	)
}

# --------------------------------------------------------------------------
# gitio.sh (ticket 07) -- tested against a REAL local git repository, not
# stubs (interfaces.md: "gitio.sh и restore.sh ... проверяются
# интеграционно на локальном bare-репозитории" -- there is no faithful way
# to fake object-database plumbing). GB_TEST_GIT_REAL=1 makes the git stub
# above exec straight through to the real git captured as GB_TEST_REAL_GIT.
# --------------------------------------------------------------------------

t_gitio_remote_head_no_branch() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"
		GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
		GB_URL="$work/gitio-rh-bare.git"; export GB_URL
		rm -rf "$GB_URL"
		git init --bare -q "$GB_URL"

		out=$(gb_remote_head 'device/rt1')
		eq 'a reachable but branchless repository returns 0' '0' "$?"
		eq 'and prints nothing (no parent yet)' '' "$out"
	)
}

t_gitio_remote_head_unreachable() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"
		GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
		GB_URL="$work/gitio-rh-no-such-repo.git"; export GB_URL
		rm -rf "$GB_URL"

		out=$(gb_remote_head 'device/rt1' 2>/dev/null)
		eq 'a repository that does not exist at all returns 1' '1' "$?"
		eq 'and prints nothing' '' "$out"
	)
}

# t_gitio_first_commit_no_parent -- the first-ever backup for a device:
# gb_build_tree with no GB_PARENT, gb_commit_push with an empty parent
# (commit-tree's own root-commit form). Exercises both mode kinds
# (100644, 120000 for a dangling symlink -- the one collect.sh's own
# backup sets are full of, /etc/resolv.conf and friends) in the same tree.
t_gitio_first_commit_no_parent() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"
		GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
		GB_URL="$work/gitio-first-bare.git"; export GB_URL
		rm -rf "$GB_URL"
		git init --bare -q "$GB_URL"

		_gt_repodir="$work/gitio-first-repo"
		_gt_tree="$work/gitio-first-tree"
		rm -rf "$_gt_repodir" "$_gt_tree"
		mkdir -p "$_gt_tree/files/etc/config"
		printf 'config network\n' >"$_gt_tree/files/etc/config/network"
		ln -s /tmp/resolv.conf.d/resolv.conf.auto "$_gt_tree/files/etc/resolv.conf"
		git init -q "$_gt_repodir"

		unset GB_PARENT
		GB_PREFIX='devices/rt1'; export GB_PREFIX
		_gt_tree_sha=$(gb_build_tree "$_gt_repodir" "$_gt_tree")
		if [ -n "$_gt_tree_sha" ]; then
			ok 'gb_build_tree prints a tree SHA with no parent'
		else
			no 'gb_build_tree prints a tree SHA with no parent' 'empty'
		fi

		: >"$work/gitio-first-msg"
		printf '2026-01-01 00:00 rt1: network\n' >"$work/gitio-first-msg"
		_gt_commit=$(gb_commit_push "$_gt_repodir" "$_gt_tree_sha" '' "$work/gitio-first-msg" 'device/rt1')
		eq 'gb_commit_push succeeds for a brand-new branch' '0' "$?"

		_gt_seen=$(git --git-dir="$GB_URL" cat-file -p "$_gt_commit:devices/rt1/files/etc/config/network" 2>/dev/null)
		eq 'the pushed commit carries the regular file at its prefixed path' 'config network' "$_gt_seen"

		_gt_mode=$(git --git-dir="$GB_URL" ls-tree "$_gt_commit" devices/rt1/files/etc/resolv.conf | awk '{print $1}')
		eq 'the dangling symlink is stored as mode 120000, not dereferenced' '120000' "$_gt_mode"

		_gt_target=$(git --git-dir="$GB_URL" cat-file -p "$_gt_commit:devices/rt1/files/etc/resolv.conf" 2>/dev/null)
		eq 'and its blob is the raw target text' '/tmp/resolv.conf.d/resolv.conf.auto' "$_gt_target"

		unset GB_PREFIX
	)
}

# t_gitio_commit_push_no_global_git_identity -- found live on the owlab
# stand (not in any unit test, until this one): a freshly booted router
# has no ~/.gitconfig and no [user] section anywhere at all, and
# `commit-tree` refuses outright ("Author identity unknown ... Please
# tell me who you are") rather than guess one -- every host-side test up
# to that point had passed only because the DEVELOPMENT MACHINE'S OWN
# global gitconfig was quietly supplying user.name/user.email. HOME
# pointed at an empty directory plus GIT_CONFIG_NOSYSTEM=1 reproduces a
# router's total absence of git identity configuration; gb_commit_push has
# to work anyway (GIT_AUTHOR_*/GIT_COMMITTER_* set explicitly, not left to
# git's fallback chain).
t_gitio_commit_push_no_global_git_identity() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"
		GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
		GB_URL="$work/gitio-noident-bare.git"; export GB_URL
		rm -rf "$GB_URL"
		git init --bare -q "$GB_URL"

		_gt_repodir="$work/gitio-noident-repo"
		_gt_tree="$work/gitio-noident-tree"
		rm -rf "$_gt_repodir" "$_gt_tree"
		mkdir -p "$_gt_tree/files/etc/config"
		printf 'config network\n' >"$_gt_tree/files/etc/config/network"
		git init -q "$_gt_repodir"

		unset GB_PARENT
		GB_PREFIX='devices/rt1'; export GB_PREFIX
		_gt_tree_sha=$(gb_build_tree "$_gt_repodir" "$_gt_tree")

		: >"$work/gitio-noident-msg"
		printf '2026-01-01 00:00 rt1: network\n' >"$work/gitio-noident-msg"

		mkdir -p "$work/gitio-noident-empty-home"
		_gt_commit=$(HOME="$work/gitio-noident-empty-home" GIT_CONFIG_NOSYSTEM=1 \
			gb_commit_push "$_gt_repodir" "$_gt_tree_sha" '' "$work/gitio-noident-msg" 'device/rt1')
		eq 'gb_commit_push succeeds with no git identity configured anywhere' '0' "$?"
		if [ -n "$_gt_commit" ]; then
			ok 'and prints the commit SHA'
		else
			no 'and prints the commit SHA' 'empty'
		fi

		unset GB_PREFIX
	)
}

# t_gitio_shared_branch_preserves_other_device -- spec step 11, a branch
# with no {device} in it: seeding the index from the parent's full tree
# before overlaying this device's own prefix must leave another device's
# files untouched, and their blobs must never be fetched at all.
t_gitio_shared_branch_preserves_other_device() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"
		GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
		GB_URL="$work/gitio-shared-bare.git"; export GB_URL
		rm -rf "$GB_URL"
		git init --bare -q "$GB_URL"
		# A plain local path never speaks the partial-clone protocol
		# extension at all (confirmed live: it degrades straight to
		# --depth=1 with a "filtering not recognized" warning, fetching
		# every blob regardless of --filter=blob:none) -- allowFilter is
		# what a real GitHub/GitLab/Forgejo server already has on, and is
		# the only way this test can exercise the actual "blobs never
		# fetched" codepath rather than always taking the degraded one.
		git config --file "$GB_URL/config" uploadpack.allowFilter true

		# Seed the shared branch directly (as if rt2 had already pushed).
		_gt_seed="$work/gitio-shared-seed"
		rm -rf "$_gt_seed"
		git init -q "$_gt_seed"
		git -C "$_gt_seed" config user.email a@b.c
		git -C "$_gt_seed" config user.name t
		mkdir -p "$_gt_seed/devices/rt2/files/etc/config"
		printf 'rt2 network\n' >"$_gt_seed/devices/rt2/files/etc/config/network"
		git -C "$_gt_seed" add -A
		git -C "$_gt_seed" commit -q -m 'seed: rt2'
		git -C "$_gt_seed" push -q "$GB_URL" HEAD:refs/heads/shared

		_gt_repodir="$work/gitio-shared-repo"
		_gt_tree="$work/gitio-shared-tree"
		rm -rf "$_gt_repodir" "$_gt_tree"
		mkdir -p "$_gt_tree/files/etc/config"
		printf 'rt1 network\n' >"$_gt_tree/files/etc/config/network"

		GB_PARENT=$(gb_remote_head shared)
		[ -n "$GB_PARENT" ] || no 'the seeded shared branch has a parent to build on' 'empty'
		export GB_PARENT
		gb_fetch_meta shared "$_gt_repodir" >/dev/null 2>&1
		eq 'gb_fetch_meta succeeds against the shared branch' '0' "$?"

		# gb_fetch_meta's own --filter=blob:none: rt2's blob, which this
		# device never touches, must never have been downloaded -- only
		# trees, never someone else's content. `--batch-all-objects`
		# enumerates only what is ALREADY physically present, so it cannot
		# itself trigger the lazy fetch it is checking for -- unlike
		# `cat-file -e <sha>` on a promisor repo, which (confirmed live)
		# transparently fetches the object just to answer the existence
		# check, silently invalidating the very thing it was asked to
		# prove.
		_gt_blob_count=$(git --git-dir="$_gt_repodir/.git" cat-file --batch-all-objects \
			--batch-check='%(objecttype)' 2>/dev/null | grep -c '^blob$')
		eq 'no blob was fetched by gb_fetch_meta, only the commit and its trees' '0' "$_gt_blob_count"

		GB_PREFIX='devices/rt1'; export GB_PREFIX
		_gt_tree_sha=$(gb_build_tree "$_gt_repodir" "$_gt_tree")
		_gt_commit=$(GIT_DIR="$_gt_repodir/.git" git commit-tree "$_gt_tree_sha" -p "$GB_PARENT" -m 'rt1 backup')
		git --git-dir="$_gt_repodir/.git" push -q "$GB_URL" "$_gt_commit:refs/heads/shared"

		_gt_rt1=$(git --git-dir="$GB_URL" cat-file -p "$_gt_commit:devices/rt1/files/etc/config/network" 2>/dev/null)
		eq 'this devices own file is present' 'rt1 network' "$_gt_rt1"
		_gt_rt2=$(git --git-dir="$GB_URL" cat-file -p "$_gt_commit:devices/rt2/files/etc/config/network" 2>/dev/null)
		eq 'and the OTHER devices file survives untouched' 'rt2 network' "$_gt_rt2"

		unset GB_PARENT GB_PREFIX
	)
}

# t_gitio_commit_push_nonfastforward_then_retry -- spec step 14. Builds a
# commit on top of parent P0, then (simulating a second run of the same
# router winning the race) pushes a DIFFERENT commit also on P0 first, so
# the original push is genuinely stale when it is attempted -- not just
# fed a wrong SHA by the test.
t_gitio_commit_push_nonfastforward_then_retry() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"
		GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
		GB_URL="$work/gitio-race-bare.git"; export GB_URL
		rm -rf "$GB_URL"
		git init --bare -q "$GB_URL"

		_gt_seed="$work/gitio-race-seed"
		rm -rf "$_gt_seed"
		git init -q "$_gt_seed"
		git -C "$_gt_seed" config user.email a@b.c
		git -C "$_gt_seed" config user.name t
		printf 'base\n' >"$_gt_seed/f"
		git -C "$_gt_seed" add -A
		git -C "$_gt_seed" commit -q -m base
		git -C "$_gt_seed" push -q "$GB_URL" HEAD:refs/heads/device/rt1
		_gt_p0=$(git -C "$_gt_seed" rev-parse HEAD)

		_gt_repodir="$work/gitio-race-repo"
		rm -rf "$_gt_repodir"
		git init -q "$_gt_repodir"
		GIT_DIR="$_gt_repodir/.git" git fetch -q --depth=1 "$GB_URL" device/rt1

		# Our own commit, parented on P0.
		: >"$work/gitio-race-msg"
		printf 'ours\n' >"$work/gitio-race-msg"
		_gt_tree=$(GIT_DIR="$_gt_repodir/.git" git rev-parse "$_gt_p0^{tree}")

		# The competitor lands on the branch FIRST, also parented on P0 --
		# now genuinely ahead of what our own push below still thinks the
		# tip is.
		git -C "$_gt_seed" push -q "$GB_URL" HEAD:refs/heads/device/rt1 --force 2>/dev/null
		printf 'competitor\n' >"$_gt_seed/f"
		git -C "$_gt_seed" commit -q -am competitor
		git -C "$_gt_seed" push -q "$GB_URL" HEAD:refs/heads/device/rt1

		_gt_commit=$(gb_commit_push "$_gt_repodir" "$_gt_tree" "$_gt_p0" "$work/gitio-race-msg" device/rt1)
		eq 'a push against a parent the branch has moved past is rejected, not silently accepted' '2' "$?"
		eq 'and nothing is printed on that rejection' '' "$_gt_commit"

		# The retry: re-resolve the parent, rebuild on top of it, push again.
		_gt_p1=$(gb_remote_head device/rt1)
		GIT_DIR="$_gt_repodir/.git" git fetch -q --depth=1 "$GB_URL" device/rt1
		_gt_commit2=$(gb_commit_push "$_gt_repodir" "$_gt_tree" "$_gt_p1" "$work/gitio-race-msg" device/rt1)
		eq 'retrying once against the now-current parent succeeds' '0' "$?"
		if [ -n "$_gt_commit2" ]; then
			ok 'and prints the new commit SHA'
		else
			no 'and prints the new commit SHA' 'empty'
		fi
	)
}

# --------------------------------------------------------------------------
# schedule.sh
# --------------------------------------------------------------------------

t_schedule_preset_expr() {
	(
		. "$share/lib.sh"; . "$share/schedule.sh"
		gb_a1=$(gb_preset_expr daily router-a)
		gb_a2=$(gb_preset_expr daily router-a)
		eq 'the same device gets the same daily preset every time' "$gb_a1" "$gb_a2"

		gb_b1=$(gb_preset_expr daily router-b)
		case "$gb_a1" in
			"$gb_b1") no 'two different devices do not land on the same daily minute/hour' \
				"both got '$gb_a1' -- fine by chance, suspicious as a rule" ;;
			*) ok 'two different devices do not land on the same daily minute/hour' ;;
		esac

		gb_hourly=$(gb_preset_expr hourly router-a)
		case "$gb_hourly" in
			*' * * * *') ok 'hourly is "M * * * *"' ;;
			*) no 'hourly is "M * * * *"' "got '$gb_hourly'" ;;
		esac
		gb_weekly=$(gb_preset_expr weekly router-a)
		# set -f: gb_weekly's own fields are literal "*"s, same reason
		# schedule.sh's own field split is noglob-guarded -- an unguarded
		# split here pathname-expands them against the current directory
		# instead (this test caught exactly that during development).
		set -f
		# shellcheck disable=SC2086
		set -- $gb_weekly
		set +f
		eq 'weekly has 5 fields' '5' "$#"
		eq 'weekly hour/dom/month are "H * *"' '* *' "$3 $4"

		# The minute has to actually be inside [0,59] and the (daily/weekly)
		# hour inside the spec's 0-5 night window -- not just "some digits".
		set -f
		# shellcheck disable=SC2086
		set -- $gb_a1
		set +f
		gb_m="$1"; gb_h="$2"
		case "$gb_m" in
			''|*[!0-9]*) no 'the preset minute is a plain integer' "got '$gb_m'" ;;
			*)
				if [ "$gb_m" -ge 0 ] && [ "$gb_m" -le 59 ]; then
					ok 'the preset minute is within 0-59'
				else
					no 'the preset minute is within 0-59' "got '$gb_m'"
				fi
				;;
		esac
		case "$gb_h" in
			''|*[!0-9]*) no 'the daily preset hour is a plain integer' "got '$gb_h'" ;;
			*)
				if [ "$gb_h" -ge 0 ] && [ "$gb_h" -le 5 ]; then
					ok 'the daily preset hour is within the 0-5 night window'
				else
					no 'the daily preset hour is within the 0-5 night window' "got '$gb_h'"
				fi
				;;
		esac
	)
}

t_schedule_cron_valid_examples() {
	(
		. "$share/lib.sh"; . "$share/schedule.sh"
		gb_cron_valid '0 3 * * *'
		eq 'a plain 5-field expression is valid' '0' "$?"
		gb_cron_valid '*/15 * * * *'
		eq 'a step is valid' '0' "$?"
		gb_cron_valid '0 3 * * 1-5'
		eq 'a range is valid' '0' "$?"

		gb_out=$( ( gb_cron_valid '@daily' ) 2>&1 >/dev/null )
		eq '@daily is rejected' '1' "$?"
		contains 'the message names the actual macro used' '@daily' "$gb_out"
		contains 'and suggests a working replacement' '0 3 * * *' "$gb_out"

		gb_cron_valid '@hourly'; eq '@hourly is rejected too' '1' "$?"

		( gb_cron_valid '0 3 * * 7' ) >/dev/null 2>&1
		eq 'weekday 7 (no Sunday-as-7 alias on this busybox) is rejected' '1' "$?"
		( gb_cron_valid '60 * * * *' ) >/dev/null 2>&1
		eq 'minute 60 is rejected' '1' "$?"

		# gb_cron_valid's field split is unquoted (it has to be, to count
		# fields); an unguarded split treats a literal "*" field as a glob
		# and pathname-expands it against the current directory instead of
		# leaving it alone -- caught during development by running the
		# suite from the repo root, where "*" silently became a couple
		# dozen filenames and every field count came out wrong.
		( cd "$root" && . "$share/lib.sh" && . "$share/schedule.sh" && gb_cron_valid '0 3 * * *' ) >/dev/null 2>&1
		eq 'field splitting does not pathname-expand a literal "*" field' '0' "$?"
	)
}

t_schedule_cron_valid_fixtures() {
	(
		. "$share/lib.sh"; . "$share/schedule.sh"
		gb_fixtures="$root/tests/fixtures/cron.tsv"
		if [ ! -r "$gb_fixtures" ]; then
			no 'tests/fixtures/cron.tsv is readable' "missing: $gb_fixtures"
			return
		fi
		gb_tab=$(printf '\t')
		gb_n=0
		while IFS="$gb_tab" read -r gb_expr gb_want; do
			case "$gb_expr" in ''|'#'*) continue ;; esac
			gb_n=$((gb_n + 1))
			if gb_cron_valid "$gb_expr" >/dev/null 2>&1; then
				gb_got=valid
			else
				gb_got=invalid
			fi
			eq "fixture: '$gb_expr' -> $gb_want" "$gb_want" "$gb_got"
		done <"$gb_fixtures"
		if [ "$gb_n" -eq 0 ]; then
			no 'the fixture file actually contains cases' 'read zero rows -- the loop or the file is broken'
		fi
	)
}

t_schedule_cron_next() {
	(
		. "$share/lib.sh"; . "$share/schedule.sh"

		gb_now=$(date -u +%s)
		gb_out=$(gb_cron_next '0 3 * * *')
		eq 'gb_cron_next prints something for a valid expression' '0' "$?"
		case "$gb_out" in
			[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9])
				ok 'the answer looks like "YYYY-MM-DD HH:MM"' ;;
			*) no 'the answer looks like "YYYY-MM-DD HH:MM"' "got '$gb_out'" ;;
		esac
		# The minute/hour fields are fixed (0 and 3); the day is whatever
		# day this is run on, but the time-of-day never depends on it.
		contains 'the time-of-day matches the expression'\''s fixed minute/hour' \
			' 03:00' "$gb_out"

		gb_today=$(date -u -d "@$gb_now" '+%Y-%m-%d')
		gb_tomorrow=$(date -u -d "@$((gb_now + 86400))" '+%Y-%m-%d')
		gb_out_date="${gb_out%% *}"
		case "$gb_out_date" in
			"$gb_today"|"$gb_tomorrow")
				ok 'the date is today or tomorrow (both valid depending on the current time)' ;;
			*)
				no 'the date is today or tomorrow (both valid depending on the current time)' \
					"got '$gb_out_date', today is '$gb_today'" ;;
		esac

		gb_out2=$(gb_cron_next '* * * * *')
		# "* * * * *" fires every minute, so the answer must land within the
		# next 60s of "now" -- a loose but real bound: it fails red if the
		# search walked in the wrong direction or off by whole days. Needs
		# python3 to parse the "YYYY-MM-DD HH:MM" answer back into an epoch
		# (this test's own verification, not the code under test); skipped
		# silently when it is not installed, same as this suite's other
		# python3-gated assertions.
		if command -v python3 >/dev/null 2>&1; then
			gb_out2_epoch=$(python3 -c "
import calendar, time
print(calendar.timegm(time.strptime('$gb_out2', '%Y-%m-%d %H:%M')))
")
			gb_diff=$((gb_out2_epoch - gb_now))
			if [ "$gb_diff" -ge 0 ] && [ "$gb_diff" -le 60 ]; then
				ok 'every-minute expression answers within the next minute of now'
			else
				no 'every-minute expression answers within the next minute of now' \
					"now=$gb_now answer_epoch=$gb_out2_epoch diff=${gb_diff}s"
			fi
		fi

		gb_cron_next '@daily' >/dev/null 2>&1
		eq 'an invalid expression is refused, not guessed at' '1' "$?"
	)
}

t_schedule_cron_apply_idempotent() {
	(
		. "$share/lib.sh"; . "$share/device.sh"; . "$share/schedule.sh"
		GB_CRONTAB="$work/crontab-root"; export GB_CRONTAB
		printf '30 3 * * 0 /sbin/sysupgrade -b /root/x.tar.gz\n' >"$GB_CRONTAB"
		fixture 'gitbackup.main.schedule=cron' 'gitbackup.main.cron_expr=0 4 * * *'

		gb_cron_apply
		gb_lines1=$(grep -c '# gitbackup$' "$GB_CRONTAB")
		eq 'applying once adds exactly one marked line' '1' "$gb_lines1"
		contains 'the crontab still carries the line that was not ours' \
			'sysupgrade -b' "$(cat "$GB_CRONTAB")"

		gb_cron_apply
		gb_lines2=$(grep -c '# gitbackup$' "$GB_CRONTAB")
		eq 'applying a second time in a row still leaves exactly one marked line' '1' "$gb_lines2"
		contains 'and it still is not a duplicate of the foreign line' \
			'sysupgrade -b' "$(cat "$GB_CRONTAB")"
		gb_total_sysupgrade=$(grep -c 'sysupgrade -b' "$GB_CRONTAB")
		eq 'the foreign line was not duplicated either' '1' "$gb_total_sysupgrade"

		contains 'the applied line uses the configured cron_expr verbatim' \
			'0 4 * * * ' "$(grep '# gitbackup$' "$GB_CRONTAB")"

		fixture 'gitbackup.main.schedule=off'
		gb_cron_apply
		gb_lines3=$(grep -c '# gitbackup$' "$GB_CRONTAB")
		eq 'schedule=off removes the gitbackup line' '0' "$gb_lines3"
		if [ -f "$GB_CRONTAB" ]; then
			ok 'schedule=off leaves the crontab file itself in place'
		else
			no 'schedule=off leaves the crontab file itself in place' \
				'the file was deleted -- crond refuses to start on an empty /etc/crontabs/ directory'
		fi
		contains 'and the foreign line survives schedule=off too' \
			'sysupgrade -b' "$(cat "$GB_CRONTAB")"
	)
}

t_schedule_cron_apply_bad_cron_expr() {
	(
		. "$share/lib.sh"; . "$share/device.sh"; . "$share/schedule.sh"
		GB_CRONTAB="$work/crontab-bad"; export GB_CRONTAB
		rm -f "$GB_CRONTAB"
		GB_TEST_LOG="$work/schedule-log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
		fixture 'gitbackup.main.schedule=cron' 'gitbackup.main.cron_expr=@daily'

		gb_cron_apply
		if [ -f "$GB_CRONTAB" ] && ! grep -q '# gitbackup$' "$GB_CRONTAB"; then
			ok 'an unrunnable cron_expr leaves the crontab without a gitbackup line'
		else
			no 'an unrunnable cron_expr leaves the crontab without a gitbackup line' \
				"$(cat "$GB_CRONTAB" 2>/dev/null)"
		fi
		contains 'and it says why in the log' 'schedule' "$(cat "$GB_TEST_LOG")"
		unset GB_TEST_LOG

		fixture 'gitbackup.main.schedule=daily' 'gitbackup.main.device_id=custom' \
			'gitbackup.main.device=rt1'
		gb_cron_apply
		contains 'a preset schedule installs a line built from gb_preset_expr' \
			'/usr/sbin/gitbackup run' "$(cat "$GB_CRONTAB")"
	)
}

# --------------------------------------------------------------------------
# etc/init.d/gitbackup
# --------------------------------------------------------------------------

t_init_backed_up_packages() {
	(
		GB_SHARE="$share"; export GB_SHARE
		GB_TEST_SYSUPGRADE_L="$work/init-supg-l"; export GB_TEST_SYSUPGRADE_L
		printf '/etc/config/network\n/etc/config/dhcp\n/etc/config/network\n/etc/config/gitbackup\n/etc/nosuch\n' \
			>"$GB_TEST_SYSUPGRADE_L"
		# shellcheck disable=SC1091
		. "$files/etc/init.d/gitbackup"
		gb_got=$(_gb_backed_up_packages | sort | tr '\n' ' ')
		eq 'own config is excluded, others deduplicated and sorted' 'dhcp network ' "$gb_got"
	)
}

t_init_config_change_debounces() {
	(
		GB_SHARE="$share"; export GB_SHARE
		GB_STATE_DIR="$work/init-state"; export GB_STATE_DIR
		rm -rf "$GB_STATE_DIR"
		GB_RUN_LOG="$work/init-run.log"; export GB_RUN_LOG
		: >"$GB_RUN_LOG"
		GB_BIN="$work/fake-gitbackup.sh"; export GB_BIN
		cat >"$GB_BIN" <<'FAKE'
#!/bin/sh
printf 'ran %s\n' "$1" >>"$GB_RUN_LOG"
FAKE
		chmod +x "$GB_BIN"
		fixture 'gitbackup.main.debounce=1'
		# shellcheck disable=SC1091
		. "$files/etc/init.d/gitbackup"

		config_change
		sleep 0.3
		config_change
		sleep 2.5
		gb_runs=$(wc -l <"$GB_RUN_LOG" | tr -d ' ')
		eq 'two config-change events inside the debounce window produce exactly one run' \
			'1' "$gb_runs"

		rm -f "$GB_STATE_DIR/debounce.pid"
	)
}

# --------------------------------------------------------------------------
# usr/sbin/gitbackup
# --------------------------------------------------------------------------

cli() {
	# GB_LOCK_FILE (ticket 07, cmd_run's step 1): the router's own default
	# is /var/run/gitbackup.lock, not writable by the non-root user this
	# suite runs as -- every `run` test needs it redirected under $work,
	# same as GB_SHARE/GB_STATE_DIR already are.
	GB_SHARE="$share" GB_STATE_DIR="$work/state" GB_LOCK_FILE="$work/gitbackup.lock" \
		sh "$files/usr/sbin/gitbackup" "$@"
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

	# ticket 07: `run` is real now, not a stub -- a valid config takes it
	# straight past gb_validate_config and into cmd_run's own step 3
	# (network precheck). 127.0.0.1 with nothing listening is the same
	# fast, offline, deterministic "unreachable" fixture t_cli_test_*
	# already uses below; example.org would make this test's result depend
	# on whether this host actually has internet access.
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://127.0.0.1:1/o/r.git'
	out=$(cli run 2>&1)
	eq 'a valid configuration gets past validation, into run itself' '0' "$?"
	contains 'and run reports the network skip, not a leftover stub message' 'skipped' "$out"
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

t_cli_private_leaves_scrub_off() {
	# The other half of t_cli_public_forces_scrub: visibility=private with
	# security.scrub=0 is the default a fresh install starts from, and
	# _gb_effective_scrub must leave it off -- this is the decision that,
	# per spec ("Scrub"), keeps gb_scrub from ever being invoked at
	# visibility=private (see scrub.sh's tests,
	# t_scrub_private_tree_untouched_by_not_scrubbing).
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git' \
		'gitbackup.origin.visibility=private' 'gitbackup.security.scrub=0'
	out=$(cli status 2>/dev/null)
	contains 'a private remote with scrub=0 leaves status reporting scrub off' \
		'"scrub": false' "$out"
}

t_cli_test_network_unreachable() {
	# https transport: no host-key step, so this exercises _gb_test_classify
	# directly against git's own wording for a connection that was never
	# made -- verified live on the owlab stand (this file's own comment on
	# cmd_test: `git ls-remote https://127.0.0.1:1/...` really does say
	# "Failed to connect to 127.0.0.1 port 1 ...: Error", which is why
	# gitbackup's own gb_have_net pre-check was removed -- busybox nc's `-w`
	# is not implemented on that image at all, and reported every host,
	# reachable or not, as unreachable).
	GB_ETC_DIR="$work/etc-t1"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://127.0.0.1:1/o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'
	GB_TEST_GIT_RC=128; export GB_TEST_GIT_RC
	GB_TEST_GIT_ERR='fatal: unable to access '"'"'https://127.0.0.1:1/o/r.git/'"'"': Failed to connect to 127.0.0.1 port 1 after 0 ms: Error'
	export GB_TEST_GIT_ERR
	out=$(cli test </dev/null 2>&1)
	eq 'a connection git itself never managed to make exits 3' '3' "$?"
	contains 'and the message says the host could not be reached, not "authentication"' 'cannot reach' "$out"
	unset GB_TEST_GIT_RC GB_TEST_GIT_ERR GB_ETC_DIR
}

t_cli_test_public_repo_refused() {
	GB_ETC_DIR="$work/etc-t2"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://github.com/acme/pub.git' 'gitbackup.origin.provider=auto'
	http_fixture 'https://api.github.com/repos/acme/pub=200'
	out=$(cli test </dev/null 2>&1)
	eq 'a publicly visible repository exits 4' '4' "$?"
	contains 'and the message says why' 'publicly visible' "$out"
	unset GB_ETC_DIR
}

t_cli_test_visibility_inconclusive() {
	GB_ETC_DIR="$work/etc-t3"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://github.com/acme/flaky.git' 'gitbackup.origin.provider=auto'
	http_fixture 'https://api.github.com/repos/acme/flaky=500'
	out=$(cli test </dev/null 2>&1)
	eq 'an inconclusive visibility check exits 3, never treated as ok' '3' "$?"
	contains 'and the message says it could not be verified' 'could not verify' "$out"
	unset GB_ETC_DIR
}

t_cli_test_hostkey_unreachable() {
	# ssh transport, GB_TEST_SSH_HOSTKEY unset: the ssh stub writes nothing
	# to the scratch known_hosts file, the same shape as a host that never
	# answers -- gb_accept_hostkey's own unit test already covers this
	# return code directly; this confirms cmd_test wires it to exit 3 with
	# a message distinct from "declined" and from "authentication failed".
	GB_ETC_DIR="$work/etc-t4"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=git@example.com:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'
	unset GB_TEST_SSH_HOSTKEY
	out=$(cli test </dev/null 2>&1)
	eq 'a host whose key could not be obtained exits 3' '3' "$?"
	contains 'and the message says the key could not be obtained' 'could not be obtained' "$out"
	unset GB_ETC_DIR
}

t_cli_test_hostkey_declined() {
	GB_ETC_DIR="$work/etc-t5"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=git@example.com:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'
	GB_TEST_SSH_HOSTKEY='example.com ssh-ed25519 AAAAtestkey'; export GB_TEST_SSH_HOSTKEY
	out=$(printf 'n\n' | cli test 2>&1)
	eq 'declining an unknown host key exits 3' '3' "$?"
	contains 'and the message says the host key was not accepted' 'host key was not accepted' "$out"
	unset GB_TEST_SSH_HOSTKEY GB_ETC_DIR
}

t_cli_test_ok() {
	GB_ETC_DIR="$work/etc-t6"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=git@example.com:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'
	GB_TEST_SSH_HOSTKEY='example.com ssh-ed25519 AAAAtestkey'; export GB_TEST_SSH_HOSTKEY
	GB_TEST_GIT_RC=0; export GB_TEST_GIT_RC
	out=$(printf 'y\n' | cli test 2>&1)
	eq 'an accepted host key and a working remote exits 0' '0' "$?"
	contains 'and reports success' 'reachable and authenticated' "$out"
	unset GB_TEST_SSH_HOSTKEY GB_TEST_GIT_RC GB_ETC_DIR
}

t_cli_test_auth_rejected() {
	GB_ETC_DIR="$work/etc-t7"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=git@example.com:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'
	GB_TEST_SSH_HOSTKEY='example.com ssh-ed25519 AAAAtestkey'; export GB_TEST_SSH_HOSTKEY
	GB_TEST_GIT_RC=128; export GB_TEST_GIT_RC
	GB_TEST_GIT_ERR='Permission denied (publickey).'; export GB_TEST_GIT_ERR
	out=$(printf 'y\n' | cli test 2>&1)
	eq 'a rejected credential exits 3, the same bucket as unreachable' '3' "$?"
	contains 'and the message says authentication failed' 'authentication' "$out"
	contains 'carrying the underlying git error' 'Permission denied' "$out"
	unset GB_TEST_SSH_HOSTKEY GB_TEST_GIT_RC GB_TEST_GIT_ERR GB_ETC_DIR
}

t_cli_keygen_pubkey() {
	GB_ETC_DIR="$work/etc-kp"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.key_file=$work/etc-kp/id_ed25519" \
		'gitbackup.origin.url='
	out=$(cli pubkey 2>&1)
	eq 'pubkey before keygen exits 1' '1' "$?"
	contains 'and says to run keygen first' 'keygen' "$out"

	out=$(cli keygen 2>&1)
	eq 'keygen with no remote configured still succeeds -- it needs no URL or device' '0' "$?"
	contains 'and names the key it generated' "$work/etc-kp/id_ed25519" "$out"

	out=$(cli pubkey 2>&1)
	eq 'pubkey after keygen succeeds' '0' "$?"
	contains 'and prints an ed25519 public key' 'ssh-ed25519' "$out"
	unset GB_ETC_DIR
}

# gb_listener <port> -- a background TCP listener on 127.0.0.1:<port>, for
# `run` tests that need gb_have_net's real connect to succeed with no real
# git/HTTP protocol behind it. Sets GB_LISTENER_PID (or leaves it empty when
# python3 is not installed, same skip-gracefully convention t_have_net's
# open-port case already uses -- nc itself never needs the far end to
# accept(), only for the TCP handshake to complete, so a bare listen() is
# enough). NOT `pid=$(gb_listener ...)`: a command substitution runs this
# function in a subshell, and the background job it starts dies the moment
# that subshell exits to produce the substitution's output -- confirmed
# live, `ps` on the "returned" PID immediately after shows it already gone.
# Caller kills it (`kill "$GB_LISTENER_PID"; wait "$GB_LISTENER_PID"
# 2>/dev/null`) once done.
gb_listener() {
	GB_LISTENER_PID=''
	command -v python3 >/dev/null 2>&1 || return 0
	_gl_port="$1"
	# Actually accept()s and closes every connection, rather than just
	# listen()ing and never draining the backlog: measured live on macOS,
	# a listener that never accepts leaves the very first connect() to it
	# stalling for ~10s before finally succeeding (some BSD-side delayed-
	# ACK/backlog quirk this suite has no reason to depend on), where a
	# real accept loop connects in single-digit milliseconds every time.
	python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $_gl_port))
s.listen(5)
s.settimeout(30)
end = time.time() + 30
while time.time() < end:
    try:
        c, _ = s.accept()
        c.close()
    except socket.timeout:
        break
" &
	GB_LISTENER_PID=$!
}

t_cli_run_flock_busy() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://127.0.0.1:1/o/r.git'
	GB_TEST_FLOCK_LOCKED=1; export GB_TEST_FLOCK_LOCKED
	out=$(cli run 2>&1)
	eq 'a busy lock exits 0' '0' "$?"
	contains 'and reports skipped, not an error' 'skipped' "$out"
	unset GB_TEST_FLOCK_LOCKED
}

t_cli_run_space_check_fails() {
	gb_listener 18491
	_gl_pid="$GB_LISTENER_PID"
	[ -n "$_gl_pid" ] || return 0
	sleep 1
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://127.0.0.1:18491/o/r.git' \
		'gitbackup.origin.acknowledged=1'
	GB_TEST_DF_KB=100; export GB_TEST_DF_KB
	out=$(cli run 2>&1)
	eq 'not enough space in /tmp exits 1' '1' "$?"
	contains 'and the message names how much is needed' 'need ~' "$out"
	contains 'and how much is actually free' '100 KB free' "$out"
	unset GB_TEST_DF_KB
	kill "$_gl_pid" 2>/dev/null
	wait "$_gl_pid" 2>/dev/null
}

# t_run_integration_bare_repo -- the ticket's own headline acceptance
# criterion: a full `gitbackup run`, through the real CLI (flock, the
# network precheck, the visibility gate, all of it), pushing to a REAL
# local bare git repository three times over. First run creates the
# branch; second run, nothing changed, makes no commit (idempotence);
# third run, after a chmod-only edit git itself would never notice,
# produces a new commit (manifest catches what git can't see) -- and along
# the way checks the commit message format, the archive step, and that
# the archive is not rebuilt on the no-op run.
#
# GB_URL has to be a schema-valid https://... (gb_parse_url/
# gb_visibility_ok both die otherwise), so GB_TEST_GIT_REMOTE_URL/PATH
# (the git stub, GB_TEST_GIT_REAL=1) transparently swap it for a real
# local bare-repo path the moment git itself is invoked -- there is no
# real server anywhere in this test. gb_have_net still needs a REAL open
# port to connect to, which is what gb_listener is for.
t_run_integration_bare_repo() {
	gb_listener 18492
	_gl_pid="$GB_LISTENER_PID"
	[ -n "$_gl_pid" ] || return 0
	sleep 1

	collect_fixture
	GB_DEVICE=rt1
	mkdir -p "$work/froot/etc/config"
	printf 'config interface lan\n\toption proto static\n' >"$work/froot/etc/config/network"
	chmod 0600 "$work/froot/etc/config/network"
	printf 'config defaults\n\toption input ACCEPT\n' >"$work/froot/etc/config/firewall"
	chmod 0644 "$work/froot/etc/config/firewall"
	sysupgrade_list '/etc/config/network' '/etc/config/firewall'
	printf "DISTRIB_RELEASE='25.12.4'\nDISTRIB_REVISION='r99999-deadbeef'\n" >"$work/froot/etc/openwrt_release"

	GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL

	_gt_bare="$work/run-integration-bare.git"
	rm -rf "$_gt_bare"
	git init --bare -q "$_gt_bare"

	GB_TEST_GIT_REMOTE_URL='https://127.0.0.1:18492/o/r.git'; export GB_TEST_GIT_REMOTE_URL
	GB_TEST_GIT_REMOTE_PATH="$_gt_bare"; export GB_TEST_GIT_REMOTE_PATH
	GB_TEST_SYSUPGRADE_B_LOG="$work/sysupgrade-b.log"; export GB_TEST_SYSUPGRADE_B_LOG
	: >"$GB_TEST_SYSUPGRADE_B_LOG"

	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.url=$GB_TEST_GIT_REMOTE_URL" \
		'gitbackup.origin.acknowledged=1' 'gitbackup.main.archive=1'

	# Acceptance criterion: "на роутере после прогона нет ни одного файла
	# репозитория" -- $WORK is always under /tmp (never flash/USB) and its
	# own `trap 'rm -rf "$WORK"' EXIT` is what has to make it disappear the
	# moment `run` finishes, successful push or not. Counted before/after
	# rather than a fixed path: WORK's own mktemp name is only known
	# inside the child process this test never sees directly.
	_gt_tmp_before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gitbackup.*' 2>/dev/null | grep -c .)

	# --- run 1: creates the branch ---
	out1=$(cli run 2>&1)
	eq 'run 1 exits 0' '0' "$?"
	contains 'and reports a push, not a stub or a skip' 'pushed' "$out1"

	_gt_tmp_after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gitbackup.*' 2>/dev/null | grep -c .)
	eq 'run leaves nothing behind under /tmp once it is done (trap cleanup)' \
		"$_gt_tmp_before" "$_gt_tmp_after"

	_gt_log1=$(git --git-dir="$_gt_bare" log --oneline device/rt1 2>/dev/null)
	_gt_count1=$(printf '%s\n' "$_gt_log1" | grep -c .)
	eq 'run 1 creates exactly one commit on device/rt1' '1' "$_gt_count1"

	_gt_subject1=$(git --git-dir="$_gt_bare" log -1 --format=%s device/rt1)
	case "$_gt_subject1" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]\ rt1:*)
			ok 'the subject starts with the backup date and time, then the device'
			;;
		*)
			no 'the subject starts with the backup date and time, then the device' "$_gt_subject1"
			;;
	esac
	_gt_body1=$(git --git-dir="$_gt_bare" log -1 --format=%b device/rt1)
	# Alphabetical (_gb_run_changed_configs's own `sort -u`), not collection
	# order: firewall before network.
	contains 'the body names what changed' 'Changed: /etc/config/firewall, /etc/config/network' "$_gt_body1"
	contains 'and the trigger (default: cron, schedule.sh'"'"'s own crontab line never passes --trigger)' 'Trigger: cron' "$_gt_body1"
	contains 'and the OpenWrt release/revision from /etc/openwrt_release' 'OpenWrt: 25.12.4 r99999-deadbeef' "$_gt_body1"
	contains 'and the device name again' 'Device: rt1' "$_gt_body1"

	_gt_archive1=$(git --git-dir="$_gt_bare" cat-file -p device/rt1:devices/rt1/backup.tar.gz 2>/dev/null)
	if [ -n "$_gt_archive1" ]; then
		ok 'option archive 1 puts backup.tar.gz next to the backup'
	else
		no 'option archive 1 puts backup.tar.gz next to the backup' 'missing'
	fi
	_gt_barchive_calls1=$(grep -c . "$GB_TEST_SYSUPGRADE_B_LOG")
	eq 'sysupgrade -b was called once, for run 1' '1' "$_gt_barchive_calls1"

	# --- run 2: nothing changed ---
	out2=$(cli run 2>&1)
	eq 'run 2 exits 0' '0' "$?"
	contains 'and reports no changes, not a second push' 'no changes' "$out2"

	_gt_count2=$(git --git-dir="$_gt_bare" log --oneline device/rt1 | grep -c .)
	eq 'run 2 adds no commit -- idempotence' "$_gt_count1" "$_gt_count2"
	_gt_barchive_calls2=$(grep -c . "$GB_TEST_SYSUPGRADE_B_LOG")
	eq 'and sysupgrade -b was NOT called again -- the archive is not rebuilt when unchanged' \
		"$_gt_barchive_calls1" "$_gt_barchive_calls2"

	# --- run 3: a chmod-only edit git itself would never see ---
	chmod 0644 "$work/froot/etc/config/network"
	out3=$(cli run 2>&1)
	eq 'run 3 exits 0' '0' "$?"
	contains 'and reports a new push -- manifest caught the chmod' 'pushed' "$out3"

	_gt_count3=$(git --git-dir="$_gt_bare" log --oneline device/rt1 | grep -c .)
	eq 'run 3 adds exactly one more commit' '2' "$_gt_count3"
	_gt_mode3=$(git --git-dir="$_gt_bare" ls-tree device/rt1 devices/rt1/files/etc/config/network 2>/dev/null | awk '{print $1}')
	eq 'and the pushed tree now carries the new mode' '100644' "$_gt_mode3"
	_gt_barchive_calls3=$(grep -c . "$GB_TEST_SYSUPGRADE_B_LOG")
	if [ "$_gt_barchive_calls3" -gt "$_gt_barchive_calls2" ]; then
		ok 'and the archive IS rebuilt on this real change'
	else
		no 'and the archive IS rebuilt on this real change' "call count stayed at $_gt_barchive_calls3"
	fi

	unset GB_TEST_GIT_REAL GB_TEST_GIT_REMOTE_URL GB_TEST_GIT_REMOTE_PATH GB_TEST_SYSUPGRADE_B_LOG
	kill "$_gl_pid" 2>/dev/null
	wait "$_gl_pid" 2>/dev/null
}

# t_cli_log -- A01: `gitbackup log` has to show the timings `run` itself
# writes to syslog for collect/compare/push, since gb_log (lib.sh) is
# their only record once a run finishes (state.json holds only the LATEST
# run, tmpfs, gone on reboot; the recent history A01 asks for is exactly
# what syslog already keeps). No `run` here -- this just proves cmd_log's
# own logread wiring (tag filter, -e gitbackup, line count) against a
# fixture log that already looks like what run's own timing line produces.
t_cli_log() {
	GB_TEST_LOGREAD="$work/logread-fixture"
	cat >"$GB_TEST_LOGREAD" <<'EOF'
Mon Jan  1 00:00:00 2026 daemon.info dnsmasq[1]: unrelated noise
Mon Jan  1 00:00:01 2026 daemon.notice gitbackup: gitbackup run: timings -- collect 3s, compare 1s, push 2s
Mon Jan  1 00:00:02 2026 daemon.notice gitbackup: gitbackup run: pushed abc123 to device/rt1
EOF
	export GB_TEST_LOGREAD
	out=$(cli log 2>&1)
	eq 'log exits 0' '0' "$?"
	contains 'and shows a run'"'"'s collect/compare/push timings' 'timings -- collect 3s, compare 1s, push 2s' "$out"
	contains 'and its push result' 'pushed abc123' "$out"
	case "$out" in
		*'unrelated noise'*) no 'and filters to the gitbackup tag, not the whole syslog' "$out" ;;
		*) ok 'and filters to the gitbackup tag, not the whole syslog' ;;
	esac
	unset GB_TEST_LOGREAD
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

# t_no_untracked_files_in_package_tree -- D02: three waves of executors
# have each left working litter (*.bak, a files/tmp/ scratch directory)
# under package/gitbackup/files/, which `$(CP) ./files/* $(1)/`
# (Makefile) / `files: ./dist/root` (owfeed.yml) would ship straight into
# the .apk with no packaging step to notice. The fix is an explicit
# allow-list rather than a pattern-based ignore (a glob for "*.bak" would
# not have caught a stray files/tmp/ directory, which is exactly one of
# the three incidents) -- any new file has to be named here in the same
# change that adds it, gitio.sh (this ticket) included.
t_no_untracked_files_in_package_tree() {
	_gb_allow="$work/allowed-package-files.txt"
	cat >"$_gb_allow" <<'EOF'
etc/config/gitbackup
etc/init.d/gitbackup
etc/uci-defaults/99-gitbackup
usr/sbin/gitbackup
usr/share/gitbackup/askpass.sh
usr/share/gitbackup/auth.sh
usr/share/gitbackup/collect.sh
usr/share/gitbackup/device.sh
usr/share/gitbackup/exclude.list
usr/share/gitbackup/gitio.sh
usr/share/gitbackup/lib.sh
usr/share/gitbackup/remoteurl.sh
usr/share/gitbackup/schedule.sh
usr/share/gitbackup/scrub.list
usr/share/gitbackup/scrub.sh
usr/share/gitbackup/visibility.sh
EOF
	_gb_stray=$(cd "$files" && find . -type f | sed 's#^\./##' | while IFS= read -r _gb_f; do
		grep -qxF "$_gb_f" "$_gb_allow" || printf '%s\n' "$_gb_f"
	done)
	eq 'every file under package/gitbackup/files/ is on the explicit whitelist' '' "$_gb_stray"
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
run_test 'lib.sh: gb_have_net against a real busybox-shaped nc (D01)' t_have_net_busybox_shape
run_test 'lib.sh: gb_have_net does not hang past its own bound' t_have_net_bounded_timeout
run_test 'lib.sh: gb_have_net leaks no watchdog process (owlab finding)' t_have_net_no_leaked_watchdog
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
run_test 'scrub.sh: sourcing alone has no side effect' t_scrub_no_side_effect_on_source
run_test 'scrub.sh: wireless WPA PSK, multi-line list survives' t_scrub_wireless
run_test 'scrub.sh: network PPPoE username/password' t_scrub_network_pppoe
run_test 'scrub.sh: openvpn client cert passphrase' t_scrub_openvpn
run_test 'scrub.sh: wireguard private/preshared keys, allowed_ips list survives' t_scrub_wireguard
run_test 'scrub.sh: ddns username/password' t_scrub_ddns
run_test 'scrub.sh: openconnect OTP password and inline PEM key' t_scrub_openconnect
run_test 'scrub.sh: mwan3 has nothing to redact and is left alone' t_scrub_mwan3_has_nothing_to_redact
run_test 'scrub.sh: a missing option is never fabricated' t_scrub_option_not_present_is_left_alone
run_test 'scrub.sh: an overlapping list scrub_option default is not double-recorded' t_scrub_dedupes_overlapping_patterns
run_test 'scrub.sh: hard-exclude pattern is not hijacked by a real glob match' \
	t_scrub_hard_exclude_pattern_survives_a_real_glob_match
run_test 'scrub.sh: public hard-exclude removes files no redaction can save' t_scrub_hard_exclude_public
run_test 'scrub.sh: private tree is full because gb_scrub is never called' t_scrub_private_tree_untouched_by_not_scrubbing
run_test 'remoteurl.sh: valid URL forms parse' t_remoteurl_valid_forms
run_test 'remoteurl.sh: garbage URLs are rejected outright' t_remoteurl_garbage_rejected
run_test 'remoteurl.sh: provider detection and override' t_remoteurl_provider
run_test 'remoteurl.sh: deploy-key deep links' t_remoteurl_deeplink
run_test 'visibility.sh: a publicly visible repository is refused' t_visibility_public_refused
run_test 'visibility.sh: a private/nonexistent repository is allowed' t_visibility_private_ok
run_test 'visibility.sh: 5xx and offline are skipped, not ok' t_visibility_inconclusive_is_skipped
run_test 'visibility.sh: cache is honored for a day and expires after' t_visibility_cache
run_test 'visibility.sh: generic remote requires acknowledgement' t_visibility_generic_needs_acknowledgement
run_test 'auth.sh: gb_git_env' t_auth_git_env
run_test 'auth.sh: gb_keygen' t_auth_keygen
run_test 'auth.sh: gb_pubkey' t_auth_pubkey
run_test 'auth.sh: gb_accept_hostkey' t_auth_accept_hostkey
run_test 'askpass.sh: answers prompts with the token' t_askpass
run_test 'gitio.sh: gb_remote_head on a branchless repository' t_gitio_remote_head_no_branch
run_test 'gitio.sh: gb_remote_head against an unreachable repository' t_gitio_remote_head_unreachable
run_test 'gitio.sh: first commit on a new branch, no parent' t_gitio_first_commit_no_parent
run_test 'gitio.sh: commit-tree works with no git identity configured (owlab finding)' t_gitio_commit_push_no_global_git_identity
run_test 'gitio.sh: a shared branch preserves another device untouched' t_gitio_shared_branch_preserves_other_device
run_test 'gitio.sh: non-fast-forward push is rejected, then retried once' t_gitio_commit_push_nonfastforward_then_retry
run_test 'schedule.sh: gb_preset_expr is deterministic per device' t_schedule_preset_expr
run_test 'schedule.sh: gb_cron_valid on hand-picked examples' t_schedule_cron_valid_examples
run_test 'schedule.sh: gb_cron_valid against tests/fixtures/cron.tsv' t_schedule_cron_valid_fixtures
run_test 'schedule.sh: gb_cron_next' t_schedule_cron_next
run_test 'schedule.sh: gb_cron_apply is idempotent and off removes the line' t_schedule_cron_apply_idempotent
run_test 'schedule.sh: gb_cron_apply on an unrunnable cron_expr' t_schedule_cron_apply_bad_cron_expr
run_test 'init.d/gitbackup: backed-up package list from sysupgrade -l' t_init_backed_up_packages
run_test 'init.d/gitbackup: config_change debounces a burst into one run' t_init_config_change_debounces
run_test 'cli: usage' t_cli_usage
run_test 'cli: unwritten subcommands' t_cli_not_implemented
run_test 'cli: status json' t_cli_status_json
run_test 'cli: status on the default config' t_cli_status_default_config
run_test 'cli: configuration validation' t_cli_validation
run_test 'cli: public remote forces scrub' t_cli_public_forces_scrub
run_test 'cli: private remote leaves scrub off' t_cli_private_leaves_scrub_off
run_test 'cli: test -- network unreachable' t_cli_test_network_unreachable
run_test 'cli: test -- public repository refused' t_cli_test_public_repo_refused
run_test 'cli: test -- visibility inconclusive' t_cli_test_visibility_inconclusive
run_test 'cli: test -- host key unreachable' t_cli_test_hostkey_unreachable
run_test 'cli: test -- host key declined' t_cli_test_hostkey_declined
run_test 'cli: test -- accepted host key and working remote' t_cli_test_ok
run_test 'cli: test -- credentials rejected' t_cli_test_auth_rejected
run_test 'cli: keygen and pubkey need no remote configuration' t_cli_keygen_pubkey
run_test 'cli: run -- a busy lock is skipped, not an error' t_cli_run_flock_busy
run_test 'cli: run -- not enough space in /tmp' t_cli_run_space_check_fails
run_test 'run: integration on a real local bare repository (3 runs)' t_run_integration_bare_repo
run_test 'cli: log shows run timings (A01)' t_cli_log
run_test 'packaging: Makefile contract' t_makefile_contract
run_test 'packaging: config sections match code' t_config_sections_match_code
run_test 'packaging: owfeed.yml matches Makefile' t_owfeed_yml_matches_makefile
run_test 'packaging: no bashisms' t_no_bashisms
run_test 'packaging: no untracked files under package/gitbackup/files (D02)' t_no_untracked_files_in_package_tree

passed=$(grep -c '^PASS$' "$results")
failed=$(grep -c '^FAIL$' "$results")
printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
