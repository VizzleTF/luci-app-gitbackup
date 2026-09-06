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

# `gitbackup run`'s own $WORK (usr/sbin/gitbackup), gb_restore's scratch
# workdir (restore.sh) and `gitbackup diff`'s scratch dir all create their
# scratch directory under "${TMPDIR:-/tmp}", never a hardcoded "/tmp" --
# usr/sbin/gitbackup's own step-4/5 comment already calls this "a TMPDIR
# override (tests/run.sh's own seam...)". It was never actually turned on
# here, which is why two `sh tests/run.sh` invocations running at the same
# time could see, and even pick up, EACH OTHER's scratch directories
# through a bare `find /tmp -name 'gitbackup*'` -- confirmed live:
# launched together with no wait between them, one invocation's
# t_restore_fetches_only_its_own_branch found an empty ref list (it had
# grabbed the OTHER invocation's workdir) and its leftover-/tmp count in
# t_run_integration_bare_repo came back one directory high, for the same
# reason. $work above is unique per invocation (mktemp -d), so pointing
# every scratch directory the code under test creates at $work instead of
# the shared system /tmp removes the collision instead of racing to avoid
# it: nothing under $work is ever visible to a different invocation.
TMPDIR="$work"
export TMPDIR

only="${1:-}"

# A missing module has to stop the run here. Every test body is a subshell, and
# a failed `.` inside one kills that subshell without asserting anything -- the
# suite would report "0 failed" for code that does not exist.
for module in "$share/lib.sh" "$share/device.sh" "$share/collect.sh" "$share/scrub.sh" "$share/remoteurl.sh" "$share/visibility.sh" "$share/auth.sh" "$share/askpass.sh" "$share/schedule.sh" "$share/gitio.sh" "$share/restore.sh" "$share/card.sh" "$share/paths.sh" "$files/usr/sbin/gitbackup" "$files/etc/init.d/gitbackup" "$files/usr/libexec/rpcd/luci.gitbackup"; do
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
# Test double for jsonfilter(1). Supports the forms the modules -- and, as
# of ticket 10, the rpcd plugin -- actually use: `jsonfilter -e @.<field>`
# for a scalar (a quoted string, confirmed live against the real tool, OR a
# bare number/true/false/null, also confirmed live -- ticket 10's own
# params like "lines"/"force"/"dry_run" are never quoted), one level of
# nesting `@.<parent>.<field>` (restore.sh's own board.release.target), and
# one level of "@.<field>[*]" array iteration (rpcd's own set_paths, one
# element per line -- confirmed live too). Like the original stub, this
# always exits 0 and simply prints nothing for a field that is not there;
# no caller anywhere in this tree checks this command's exit status, only
# the string it prints.
[ "${1:-}" = "-e" ] || { echo "jsonfilter stub: expected -e, got '${1:-}'" >&2; exit 64; }
expr="${2:-}"
input=$(cat)
case "$expr" in
	@.*) field="${expr#@.}" ;;
	*) echo "jsonfilter stub: unsupported expression '$expr'" >&2; exit 64 ;;
esac

# _gb_jf_scalar <json-blob> <key> -- quoted-string match first, then a bare
# (unquoted) token up to the next comma/brace, so a number or a boolean
# extracts the same as the real tool's own output for one. Which branch to
# use is decided by whether a quote actually follows the colon, NOT by
# whether the quoted match came back empty -- a genuinely empty string
# value ("value":"") must stay empty, not fall through to the bare-token
# regex, which would otherwise swallow the closing quote itself as if it
# were unquoted content (found by t_rpcd_set_secret_perms_and_no_log's own
# "clear the secret" case: "value":"" was coming back as the two-character
# string \"\" instead of "").
_gb_jf_scalar() {
	if printf '%s' "$1" | grep -q '"'"$2"'"[[:space:]]*:[[:space:]]*"'; then
		printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
	else
		printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | \
			head -n 1 | sed 's/[[:space:]]*$//'
	fi
}

case "$field" in
	*'[*]')
		key="${field%'[*]'}"
		printf '%s' "$input" | \
			sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | \
			tr ',' '\n' | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p'
		;;
	*.*.*) echo "jsonfilter stub: more than one level of nesting is not supported" >&2; exit 64 ;;
	*.*)
		parent="${field%%.*}"
		child="${field#*.}"
		blob=$(printf '%s' "$input" | sed -n 's/.*"'"$parent"'"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p')
		val=$(_gb_jf_scalar "$blob" "$child")
		[ -n "$val" ] && printf '%s\n' "$val"
		;;
	*)
		val=$(_gb_jf_scalar "$input" "$field")
		[ -n "$val" ] && printf '%s\n' "$val"
		;;
esac
exit 0
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
# restore.sh's own tests (ticket 08) additionally use `stat -c '%u %g'`
# alone -- a symlink's lstat MODE is not portable to assert (Linux always
# reports 0777 for one regardless of chmod; macOS/BSD does not), but its
# ownership is, so the permissions test checks that pair on its own for a
# symlink and the full triple for files/dirs. `%d` (ticket 19,
# _gb_restore_check_writable's own device-number comparison) is a third,
# separate format -- BSD stat has a directly equivalent %d of its own, no
# field reordering needed the way %a/%Lp needed. macOS ships a BSD stat
# with different flags entirely, so this stub translates on Darwin;
# elsewhere it defers straight to the real GNU stat, found via the POSIX
# default PATH so it does not recurse into itself.
[ "${1:-}" = "-c" ] || { echo "stat stub: expected -c, got '${1:-}'" >&2; exit 64; }
fmt="$2"; path="$3"
case "$fmt" in
	'%a %u %g') bsd_fmt='%Lp %u %g' ;;
	'%u %g') bsd_fmt='%u %g' ;;
	'%d') bsd_fmt='%d' ;;
	*) echo "stat stub: unsupported format '$fmt'" >&2; exit 64 ;;
esac
if [ "$(uname -s)" = "Darwin" ]; then
	/usr/bin/stat -f "$bsd_fmt" "$path"
else
	command -p stat -c "$fmt" "$path"
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

cat >"$work/bin/sort" <<'STUB'
#!/bin/sh
# Test double for the one busybox sort(1) quirk ticket 17's own diff work
# actually hit live on the owlab 25.12.4 stand: `sort -o FILE FILE` (the
# SAME path as both the -o target and the sole input) is a no-op for -o on
# that busybox -- it sorts and prints to STDOUT same as no -o at all, and
# leaves FILE completely untouched. GNU/BSD sort's own -o (this host)
# writes to the file as documented, so nothing here ever exercised that
# path without this stub -- confirmed by cmd_diff's own former
# `sort -o "$_gb_dd_out" "$_gb_dd_out"` leaking 37 sorted lines straight
# into `gitbackup diff`'s own stdout, ahead of the real report, the first
# time this ran on real hardware. Reproduces exactly that one shape;
# everything else (a plain sort, `sort -u`, `-o` with two DIFFERENT
# files, ...) passes straight through to the host's own real sort(1),
# same "translate on request, defer otherwise" convention the stat/df
# stubs above already use.
if [ "$#" -eq 3 ] && [ "$1" = "-o" ] && [ "$2" = "$3" ]; then
	command -p sort "$2"
	exit 0
fi
command -p sort "$@"
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
#
# Ticket 28: this used to be `exec command -p df "$@"`, which always fails
# under dash ("exec: command: not found") -- `command` is a shell builtin,
# and exec(3) can only take over the process image with a real executable
# found on disk. See the date stub's own comment for why the fix is an
# explicit directory scan rather than `command -p df` without the exec.
if [ -z "${GB_TEST_DF_KB:-}" ]; then
	for _gb_df_dir in /usr/bin /bin; do
		if [ -x "$_gb_df_dir/df" ]; then
			exec "$_gb_df_dir/df" "$@"
		fi
	done
	echo "df stub: no real df(1) found in /usr/bin or /bin" >&2
	exit 127
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
#
# Ticket 28: the non-Darwin branch used to be `exec command -p date "$@"`.
# `command` is a shell builtin -- exec(3) can only replace the process
# image with a real executable found on disk, so `exec command ...`
# always fails ("exec: command: not found"), a gap bash papers over (it
# special-cases a builtin right after `exec` at parse time) but dash --
# this stub's own interpreter under Ubuntu CI, and /bin/sh on plenty of
# other Linux hosts -- does not. Dropping just the `exec` and keeping
# `command -p date "$@"` would dodge that specific crash, but still
# resolves the real binary via a PATH lookup (`-p`'s own "guaranteed
# standard PATH"); an explicit directory scan is what this project
# settled on instead, so the fallback used when a named tool is missing
# says exactly where it looked, and can never end up resolving to
# something unexpected ahead of the standard locations. It also, unlike a
# bare `date`, cannot recurse into this very stub: $work/bin (the stub's
# own directory) is never one of the directories searched.
if [ "$(uname -s)" != "Darwin" ]; then
	for _gb_date_dir in /usr/bin /bin; do
		if [ -x "$_gb_date_dir/date" ]; then
			exec "$_gb_date_dir/date" "$@"
		fi
	done
	echo "date stub: no real date(1) found in /usr/bin or /bin" >&2
	exit 127
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

# skip <name> <reason> -- ticket 28: this suite always had assertions that
# quietly do nothing at all when an optional host tool (python3, nc,
# pgrep) is missing, or when a precondition the test needs cannot be
# fabricated in the current environment (running as root) -- the count of
# tests that actually ran differed silently from one host to the next as
# a result (734 on a fully-equipped macOS dev machine vs. 656 on the
# minimal debian:stable-slim container this project's CI uses to
# reproduce Linux locally, and neither run said why). `skip` is the
# printed, counted alternative: it goes into $results as its own SKIP
# line (never PASS or FAIL -- a skip is not evidence either way) and
# prints immediately, so a smaller total is always something the output
# says plainly, not something left to be noticed by counting.
skip() { printf 'SKIP\n' >>"$results"; printf '  skip  %s (%s)\n' "$1" "$2"; }

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

# t_manifest_field/tail/each -- the manifest reader (ticket 18's consolidation
# of what collect.sh, scrub.sh and restore.sh each used to parse on their
# own) had no test of its own before this one: the suite only ever exercised
# it indirectly through gb_collect/gb_scrub/gb_restore, which is why the
# escaped-quote truncation below went unnoticed even after it started
# reaching all three modules at once.
t_manifest_field() {
	(
		. "$share/lib.sh"
		eq 'a quoted value with an escaped quote reads back whole, not truncated at it' \
			'/etc/weird "name".conf' \
			"$(gb_manifest_field '{"path":"/etc/weird \"name\".conf","type":"file"}' path)"
		eq 'an escaped backslash in a quoted value is also un-escaped' \
			'C:\path\file' \
			"$(gb_manifest_field '{"path":"C:\\path\\file","type":"file"}' path)"
		eq 'a bare numeric field is returned as-is' '600' \
			"$(gb_manifest_field '{"path":"/etc/x","mode":600}' mode)"
		eq 'JSON null becomes an empty string, not the literal "null"' '' \
			"$(gb_manifest_field '{"path":"/etc/x","sha256":null}' sha256)"
		eq 'a field absent from the object is empty' '' \
			"$(gb_manifest_field '{"path":"/etc/x"}' mode)"
	)
}

t_manifest_tail() {
	(
		. "$share/lib.sh"
		gb_m="$work/manifest_tail.json"
		cat >"$gb_m" <<'EOF'
{
  "version": "1",
  "generated": "2026-01-01T00:00:00Z",
  "entries": [
    {"path":"/etc/a","type":"file"},
    {"path":"/etc/b","type":"file"}
  ],
  "scrubbed": [
    {"path":"/etc/config/wireless","option":"wireless.default_radio0.key"}
  ]
}
EOF
		gb_tail="$(gb_manifest_tail "$gb_m")"
		contains 'the default section (entries) starts the tail at its own array' \
			'"path":"/etc/a"' "$gb_tail"
		contains 'the tail runs to end of file, past entries into scrubbed' \
			'"path":"/etc/config/wireless"' "$gb_tail"
		case "$gb_tail" in
			'"version"'*|*'"version"'*) no 'the tail excludes everything before the section' "$gb_tail" ;;
			*) ok 'the tail excludes everything before the section' ;;
		esac
		gb_scrubbed_tail="$(gb_manifest_tail "$gb_m" scrubbed)"
		contains 'a named section starts its own tail at that array instead' \
			'"path":"/etc/config/wireless"' "$gb_scrubbed_tail"
		case "$gb_scrubbed_tail" in
			*'"path":"/etc/a"'*) no 'a named tail excludes the section written before it' "$gb_scrubbed_tail" ;;
			*) ok 'a named tail excludes the section written before it' ;;
		esac
	)
}

t_manifest_each() {
	(
		. "$share/lib.sh"
		gb_m="$work/manifest_each.json"
		cat >"$gb_m" <<'EOF'
{
  "version": "1",
  "entries": [
    {"path":"/etc/a","type":"file"},
    {"path":"/etc/b","type":"file"}
  ],
  "scrubbed": [
  ]
}
EOF
		gb_count=0
		gb_last=''
		# shellcheck disable=SC2329  # invoked indirectly, by name, from inside gb_manifest_each below
		gb_each_cb() {
			gb_count=$((gb_count + 1))
			gb_last="$1"
		}
		gb_manifest_each "$gb_m" entries gb_each_cb
		# A plain pipe into this loop would fork a subshell, and gb_count's
		# increments inside it would vanish the moment that subshell exits
		# (the same trap this suite's own harness works around for $passed/
		# $failed) -- exactly why gb_manifest_each reads via `done <"$file"`
		# rather than `cat "$file" | while ...`. Asserting the count is
		# 2, not 0, is what would catch that regression.
		eq 'the callback runs once per array item, not lost to a subshell' '2' "$gb_count"
		eq 'the trailing comma is stripped before the callback sees the object' \
			'{"path":"/etc/b","type":"file"}' "$gb_last"

		gb_count=0
		gb_manifest_each "$gb_m" scrubbed gb_each_cb
		eq 'an empty section calls the callback zero times' '0' "$gb_count"
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
			skip 'gb_have_net fails against a port nothing listens on' 'nc not found on PATH'
			skip 'gb_have_net succeeds against an open port' 'nc not found on PATH'
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
			# Port 0 -- an OS-assigned free port, not a literal -- is what
			# makes this safe against a second `sh tests/run.sh` running at
			# the same time: a fixed literal here (this test's own port
			# 18291 before the fix) is a real, reproducible collision the
			# instant two invocations' listeners overlap in time, since
			# SO_REUSEADDR only forgives a socket's OWN prior TIME_WAIT
			# state and does nothing for a second process trying to bind a
			# port a first one is actively listening on. The listener
			# writes its OS-assigned port to a file once bound (after
			# listen(), so the file appearing is also proof the socket is
			# already accepting) and this polls for that file instead of a
			# fixed sleep, which only ever encoded "how long Python usually
			# takes to start", not a guarantee.
			gb_hn_port_file="$work/t_have_net_port.$$"
			rm -f "$gb_hn_port_file"
			python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0))
s.listen(1)
with open('$gb_hn_port_file', 'w') as f:
    f.write(str(s.getsockname()[1]))
time.sleep(3)
" &
			listener_pid=$!
			gb_hn_waited=0
			while [ ! -s "$gb_hn_port_file" ] && [ "$gb_hn_waited" -lt 50 ]; do
				sleep 0.1
				gb_hn_waited=$((gb_hn_waited + 1))
			done
			if [ -s "$gb_hn_port_file" ]; then
				gb_have_net 127.0.0.1 "$(cat "$gb_hn_port_file")"
				eq 'gb_have_net succeeds against an open port' '0' "$?"
			else
				no 'gb_have_net succeeds against an open port' \
					'listener never reported its port within 5s'
			fi
			kill "$listener_pid" 2>/dev/null
			wait "$listener_pid" 2>/dev/null
		else
			skip 'gb_have_net succeeds against an open port' 'python3 not found on PATH'
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
		if ! command -v pgrep >/dev/null 2>&1; then
			skip 'gb_have_net leaves no orphaned watchdog process behind' 'pgrep not found on PATH'
			return 0
		fi
		# The pids of any "sleep 5" ALREADY running before this test, so a
		# foreign one is not read as ours. `pgrep -f '^sleep 5$'` is
		# host-global, and a leaked watchdog is orphaned by definition --
		# reparented, so its parentage cannot identify it either. This test
		# failed once on a developer machine because an unrelated process
		# elsewhere on the host was sitting in `until ...; do sleep 5; done`;
		# the leak this guards against is a NEW pid appearing across the
		# call, which is what is compared here.
		_hn_before=$(pgrep -f '^sleep 5$' 2>/dev/null | sort)
		gb_have_net 127.0.0.1 1
		sleep 0.3
		_hn_after=$(pgrep -f '^sleep 5$' 2>/dev/null | sort)
		_hn_new=$(printf '%s\n' "$_hn_after" | grep -vxF -e "$_hn_before" 2>/dev/null || true)
		[ -n "$_hn_before" ] || _hn_new="$_hn_after"
		if [ -n "$_hn_new" ]; then
			no 'gb_have_net leaves no orphaned watchdog process behind' \
				"found a leftover \"sleep 5\" process ($(printf '%s' "$_hn_new" | tr '\n' ' '))"
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

# t_collect_hard_exclude_non_canonical -- the same directory the test above
# proves is excluded, spelled the three ways that used to slip past
# _gb_collect_is_excluded's own `case` match. This is the half of the fix
# that does not depend on gb_paths_validate: `sysupgrade -l` unions in
# /lib/upgrade/keep.d/* and changed conffiles, neither of which this
# package validates or even writes, so the exclude matcher has to hold on
# a path that never went through the paths editor at all. What leaked
# otherwise was not incidental -- /etc/gitbackup holds the deploy private
# key and the git token, i.e. exactly the credentials that authenticate
# the push, committed into the repository they authenticate to.
t_collect_hard_exclude_non_canonical() {
	(
		. "$share/lib.sh"; . "$share/collect.sh"
		collect_fixture
		mkdir -p "$work/froot/etc/gitbackup"
		printf 'shh
' >"$work/froot/etc/gitbackup/token"
		printf 'PRIVATE KEY
' >"$work/froot/etc/gitbackup/id_ed25519"
		sysupgrade_list '//etc/gitbackup/token' '/etc/./gitbackup/id_ed25519' '/etc/../etc/gitbackup/token'

		gb_collect "$work/out" >/dev/null 2>&1

		if [ -e "$work/out/files/etc/gitbackup" ]; then
			no 'no spelling of /etc/gitbackup reaches the tree' 'it was collected'
		else
			ok 'no spelling of /etc/gitbackup reaches the tree'
		fi
		case "$(cat "$(gb_manifest_path "$work/out")")" in
			*gitbackup*) no 'and none reaches the manifest either' 'found it' ;;
			*) ok 'and none reaches the manifest either' ;;
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
		else
			skip 'manifest.json stays valid JSON with quotes, spaces and non-ASCII in a path' \
				'python3 not found on PATH'
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
	)
}

# t_auth_keygen_force_needs_confirm -- ticket 25's own headline bug: `keygen
# --force` alone used to destroy the working key on the spot. Now it must
# only ever show the current key's fingerprint (never a bare y/N prompt --
# no `read` anywhere in this path at all, sidestepping ticket 20's own
# EOF-is-neither-yes-nor-no trap entirely) and refuse, exactly the same
# whether a human or a script is calling it, until a SECOND call names that
# exact fingerprint back with `confirm`.
t_auth_keygen_force_needs_confirm() {
	(
		. "$share/lib.sh"; . "$share/auth.sh"
		_gb_key="$work/authkeys-force/id_ed25519"
		fixture "gitbackup.origin.key_file=$_gb_key"

		gb_keygen >/dev/null 2>&1
		_gb_before=$(cat "$_gb_key")
		_gb_before_fp=$(ssh-keygen -lf "$_gb_key.pub" 2>/dev/null)

		out=$(gb_keygen force 2>/dev/null)
		eq 'force with no confirmation at all refuses to destroy anything' '4' "$?"
		eq 'and the existing key is left untouched' "$_gb_before" "$(cat "$_gb_key")"
		eq 'and prints the fingerprint of the current key, nothing more' \
			"confirm-required $_gb_before_fp" "$out"

		out=$(gb_keygen force 'not the right fingerprint' 2>/dev/null)
		eq 'a wrong confirmation is refused the same way as none at all' '4' "$?"
		eq 'and still leaves the key untouched' "$_gb_before" "$(cat "$_gb_key")"

		_gb_fp=$(printf '%s\n' "$out" | cut -d' ' -f2-)
		gb_keygen force "$_gb_fp" >/dev/null 2>&1
		eq 'naming back the exact fingerprint shown regenerates the key' '0' "$?"
		if [ "$(cat "$_gb_key")" = "$_gb_before" ]; then
			no 'and the key actually changed' 'identical bytes as before'
		else
			ok 'and the key actually changed'
		fi
	)
}

# t_auth_keygen_keeps_old -- ticket 25's decision: the key a confirmed
# `--force` just replaced is kept aside as "<key>.old" rather than deleted
# outright, until gb_keygen_forget_old below is told the new one works.
t_auth_keygen_keeps_old() {
	(
		. "$share/lib.sh"; . "$share/auth.sh"
		_gb_key="$work/authkeys-old/id_ed25519"
		fixture "gitbackup.origin.key_file=$_gb_key"

		gb_keygen >/dev/null 2>&1
		_gb_before=$(cat "$_gb_key")
		_gb_before_pub=$(cat "$_gb_key.pub")

		_gb_fp=$(gb_keygen force 2>/dev/null | cut -d' ' -f2-)
		gb_keygen force "$_gb_fp" >/dev/null 2>&1

		eq 'the previous private key survives as .old' "$_gb_before" "$(cat "$_gb_key.old" 2>/dev/null)"
		eq 'the previous public key survives as .old.pub' "$_gb_before_pub" "$(cat "$_gb_key.old.pub" 2>/dev/null)"

		_gb_omug=$(stat -c '%a %u %g' "$_gb_key.old" 2>/dev/null)
		# shellcheck disable=SC2086
		set -- $_gb_omug
		eq 'the .old private key is 0600, same as a fresh one' '600' "$1"

		gb_keygen_forget_old
		if [ -e "$_gb_key.old" ] || [ -e "$_gb_key.old.pub" ]; then
			no 'gb_keygen_forget_old removes both .old files' 'still present'
		else
			ok 'gb_keygen_forget_old removes both .old files'
		fi

		# No-op when there is nothing to forget -- must not fail or touch
		# the actual, current key.
		gb_keygen_forget_old
		eq 'and calling it again with nothing to forget does not fail' '0' "$?"
		if [ -f "$_gb_key" ]; then ok 'the current key is untouched by forgetting .old'; else no 'the current key is untouched by forgetting .old' 'missing'; fi
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

# t_auth_accept_hostkey_eof -- ticket 20's first defect. A dial that DOES
# obtain a host key, followed by an EOF on stdin (no controlling terminal
# at all -- exactly gbrpc_test's own `"$GB_BIN" test </dev/null` shape) must
# be told apart from a real, typed "no": different exit code, different
# log line, and -- the actual bug reported live -- the message must never
# say "declined by the operator" for an operator who was never asked.
t_auth_accept_hostkey_eof() {
	(
		. "$share/lib.sh"; . "$share/auth.sh"

		GB_ETC_DIR="$work/etc-hk-eof"; export GB_ETC_DIR
		GB_TEST_SSH_HOSTKEY='example.com ssh-ed25519 AAAAtestkey'; export GB_TEST_SSH_HOSTKEY
		out=$( ( gb_accept_hostkey example.com 22 </dev/null ) 2>&1 )
		eq 'EOF on the confirmation prompt returns 3, not 1' '3' "$?"
		if [ -e "$GB_ETC_DIR/known_hosts" ]; then
			no 'and nothing was written' 'known_hosts exists'
		else
			ok 'and nothing was written'
		fi
		case "$out" in
			*'declined by the operator'*) no 'the message never blames the operator for declining' "$out" ;;
			*) ok 'the message never blames the operator for declining' ;;
		esac
		contains 'and says a confirmation could not be asked for' 'could not ask' "$out"
		unset GB_TEST_SSH_HOSTKEY GB_ETC_DIR
	)
}

# t_auth_hostkey_show_accept -- ticket 20's second defect: a way to accept
# the host key without an interactive terminal at all. gb_hostkey_show
# fetches and caches, never asking or writing known_hosts; gb_hostkey_accept
# commits ONLY the cached material, and only when handed back the exact
# fingerprint gb_hostkey_show printed for it -- a real key pair is
# generated here (not the fixed "AAAAtestkey" string the other tests use)
# so ssh-keygen -lf actually produces a fingerprint to compare, making the
# match/mismatch assertions below meaningful rather than two empty strings
# agreeing by accident.
t_auth_hostkey_show_accept() {
	(
		. "$share/lib.sh"; . "$share/auth.sh"

		_gb_hk_key="$work/hostkey-show-key"
		rm -f "$_gb_hk_key" "$_gb_hk_key.pub"
		ssh-keygen -t ed25519 -N '' -f "$_gb_hk_key" >/dev/null
		GB_TEST_SSH_HOSTKEY="example.com $(cat "$_gb_hk_key.pub")"; export GB_TEST_SSH_HOSTKEY

		GB_ETC_DIR="$work/etc-hk-show1"; export GB_ETC_DIR
		unset GB_TEST_SSH_HOSTKEY_UNSET_MARKER
		_gb_hk_saved="$GB_TEST_SSH_HOSTKEY"
		unset GB_TEST_SSH_HOSTKEY
		out=$( ( gb_hostkey_show unreachable.example 22 ) 2>/dev/null )
		eq 'show on an unreachable host returns 2' '2' "$?"
		eq 'and prints nothing' '' "$out"
		GB_TEST_SSH_HOSTKEY="$_gb_hk_saved"; export GB_TEST_SSH_HOSTKEY

		out=$(gb_hostkey_show example.com 22 2>/dev/null)
		eq 'show on a reachable, untrusted host returns 0' '0' "$?"
		case "$out" in
			pending\ example.com\ 22\ *) ok 'and reports pending with a fingerprint' ;;
			*) no 'and reports pending with a fingerprint' "$out" ;;
		esac
		_gb_hk_fp=$(printf '%s\n' "$out" | cut -d' ' -f4-)
		if [ -s "$GB_ETC_DIR/hostkey_pending" ]; then
			ok 'and caches the fetched key on disk'
		else
			no 'and caches the fetched key on disk' 'hostkey_pending missing'
		fi
		if [ -e "$GB_ETC_DIR/known_hosts" ]; then
			no 'show never writes known_hosts by itself' 'known_hosts exists'
		else
			ok 'show never writes known_hosts by itself'
		fi

		out=$(gb_hostkey_accept example.com 22 'not the right fingerprint' 2>&1)
		eq 'accept with a mismatched fingerprint returns 4' '4' "$?"
		if [ -e "$GB_ETC_DIR/known_hosts" ]; then
			no 'and a mismatch never writes known_hosts' 'known_hosts exists'
		else
			ok 'and a mismatch never writes known_hosts'
		fi
		if [ -s "$GB_ETC_DIR/hostkey_pending" ]; then
			ok 'and the pending cache survives a rejected attempt'
		else
			no 'and the pending cache survives a rejected attempt' 'hostkey_pending gone'
		fi

		gb_hostkey_accept example.com 22 "$_gb_hk_fp" >/dev/null 2>&1
		eq 'accept with the exact shown fingerprint returns 0' '0' "$?"
		contains 'and known_hosts now carries the cached key' "$(cat "$_gb_hk_key.pub")" \
			"$(cat "$GB_ETC_DIR/known_hosts" 2>/dev/null)"
		if [ -e "$GB_ETC_DIR/hostkey_pending" ]; then
			no 'and the pending cache is consumed' 'hostkey_pending still exists'
		else
			ok 'and the pending cache is consumed'
		fi

		out=$(gb_hostkey_accept example.com 22 "$_gb_hk_fp" 2>&1)
		eq 'accepting again with nothing pending returns 1' '1' "$?"

		out=$(gb_hostkey_show example.com 22 2>/dev/null)
		eq 'show on an already-trusted host reports trusted, not a fresh fingerprint' \
			'trusted example.com 22' "$out"

		unset GB_TEST_SSH_HOSTKEY GB_ETC_DIR
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

# t_gitio_build_tree_extra_root_file -- ticket 22: a device-branch README.md
# has to sit at the BRANCH ROOT, a sibling of GB_PREFIX ("devices/<id>"), not
# inside it -- that is the one thing GitHub actually renders when a human
# opens the branch from a phone. gb_build_tree's own file-staging loop only
# ever walks <treedir> and always prefixes with GB_PREFIX, so reaching the
# branch root needs a second, explicit staging path: an optional 3rd/4th
# argument pair (a local file, and the exact git path to stage it at) that
# bypasses GB_PREFIX entirely. Omitting both arguments must leave existing
# behavior untouched -- the two tests above call gb_build_tree with only two
# arguments and still have to pass.
t_gitio_build_tree_extra_root_file() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"
		GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
		GB_URL="$work/gitio-extra-bare.git"; export GB_URL
		rm -rf "$GB_URL"
		git init --bare -q "$GB_URL"

		_gt_repodir="$work/gitio-extra-repo"
		_gt_tree="$work/gitio-extra-tree"
		_gt_extra="$work/gitio-extra-README.md"
		rm -rf "$_gt_repodir" "$_gt_tree"
		mkdir -p "$_gt_tree/files/etc/config"
		printf 'config network\n' >"$_gt_tree/files/etc/config/network"
		printf 'recovery instructions\n' >"$_gt_extra"
		git init -q "$_gt_repodir"

		unset GB_PARENT
		GB_PREFIX='devices/rt1'; export GB_PREFIX
		_gt_tree_sha=$(gb_build_tree "$_gt_repodir" "$_gt_tree" "$_gt_extra" 'README.md')
		if [ -n "$_gt_tree_sha" ]; then
			ok 'gb_build_tree still prints a tree SHA when an extra root file is given'
		else
			no 'gb_build_tree still prints a tree SHA when an extra root file is given' 'empty'
		fi

		: >"$work/gitio-extra-msg"
		printf '2026-01-01 00:00 rt1: network\n' >"$work/gitio-extra-msg"
		_gt_commit=$(gb_commit_push "$_gt_repodir" "$_gt_tree_sha" '' "$work/gitio-extra-msg" 'device/rt1')
		eq 'gb_commit_push succeeds with the extra root file staged' '0' "$?"

		_gt_seen=$(git --git-dir="$GB_URL" cat-file -p "$_gt_commit:README.md" 2>/dev/null)
		eq 'the extra file lands at the exact git path given, at the branch root' 'recovery instructions' "$_gt_seen"

		_gt_prefixed=$(git --git-dir="$GB_URL" cat-file -p "$_gt_commit:devices/rt1/files/etc/config/network" 2>/dev/null)
		eq 'and the normal prefixed content is still there too' 'config network' "$_gt_prefixed"

		case "$(git --git-dir="$GB_URL" ls-tree "$_gt_commit" devices/rt1/README.md 2>/dev/null)" in
			'') ok 'the extra file is NOT also duplicated under the prefix' ;;
			*) no 'the extra file is NOT also duplicated under the prefix' 'found under devices/rt1/README.md' ;;
		esac

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
		# GIT_AUTHOR_*/GIT_COMMITTER_* explicit, same as gb_commit_push
		# itself (gitio.sh) -- this is a raw `git commit-tree` the test
		# calls directly, not through gb_commit_push, so it does not
		# inherit that function's own env vars and is just as exposed as
		# any other git invocation to a host with no git identity
		# configured at all. Confirmed on Linux CI: git's own auto-detect
		# fails outright there ("fatal: unable to auto-detect email
		# address") because the container's root user has no gecos entry
		# to derive one from, whereas a macOS dev account always has one --
		# an environment difference this test has no business depending on.
		_gt_commit=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.st \
			GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.st \
			GIT_DIR="$_gt_repodir/.git" git commit-tree "$_gt_tree_sha" -p "$GB_PARENT" -m 'rt1 backup')
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
# restore.sh
# --------------------------------------------------------------------------
#
# Tested against a REAL local bare git repository, same reasoning as
# gitio.sh's own tests (interfaces.md: "Единственное исключение -- gitio.sh
# и restore.sh, которые проверяются интеграционно на локальном
# бэре-репозитории"). gb_remote_head/gb_fetch_meta -- and every plain `git`
# call restore.sh makes directly -- go through the git stub's
# GB_TEST_GIT_REAL=1 real-git passthrough with the same GB_TEST_GIT_REMOTE_URL/
# GB_TEST_GIT_REMOTE_PATH swap t_run_integration_bare_repo already relies on,
# so GB_URL can stay a schema-valid https://... string (gb_parse_url is
# never involved here, but GB_URL is still what gb_remote_head/gb_fetch_meta
# print into their own error messages) while every actual git operation
# lands on a real local bare repo, no network anywhere.

# restore_entry_file/dir/symlink/scrubbed -- one manifest.json array-item
# object per call, the exact shape collect.sh's own _gb_collect_entry_*
# functions write (field order does not matter to restore.sh's own
# substring-based JSON readers, but matching it keeps a fixture readable
# next to a real manifest).
restore_entry_file() {
	printf '{"path":"%s","type":"file","mode":%s,"uid":%s,"gid":%s,"sha256":"%s"}' "$1" "$2" "$3" "$4" "$5"
}
restore_entry_dir() {
	printf '{"path":"%s","type":"dir","mode":%s,"uid":%s,"gid":%s}' "$1" "$2" "$3" "$4"
}
restore_entry_symlink() {
	printf '{"path":"%s","type":"symlink","mode":%s,"uid":%s,"gid":%s,"target":"%s"}' "$1" "$2" "$3" "$4" "$5"
}
restore_scrubbed_entry() {
	printf '{"path":"%s","option":"%s"}' "$1" "$2"
}

# restore_join_array <newline-separated-objects> -- 4-space-indented,
# comma-joined, no trailing comma -- collect.sh's own array-body shape
# (_gb_collect_join), reimplemented here rather than sourced: this is test
# fixture code building input for restore.sh, not sharing collect.sh's
# own private helper the way scrub.sh's header explains modules must not.
restore_join_array() {
	_rj_first=1
	printf '%s\n' "$1" | while IFS= read -r _rj_l; do
		[ -n "$_rj_l" ] || continue
		if [ "$_rj_first" -eq 1 ]; then _rj_first=0; else printf ',\n'; fi
		printf '    %s' "$_rj_l"
	done
	[ -z "$1" ] || printf '\n'
}

# restore_write_manifest <path> <entries> <scrubbed> -- entries/scrubbed
# are newline-separated restore_entry_*/restore_scrubbed_entry() outputs
# (either may be empty). Every top-level field besides entries/scrubbed is
# a fixed placeholder: restore.sh never reads manifest.json's own
# version/generated/hostname/device/openwrt/board fields (board comes from
# the separate meta/board.json instead, checked independently).
restore_write_manifest() {
	{
		printf '{\n  "version": "1",\n  "generated": "2026-01-01T00:00:00Z",\n'
		printf '  "hostname": "seed",\n  "device": "rt1",\n  "openwrt": "25.12.4",\n  "board": "Test Board",\n'
		printf '  "entries": [\n'
		restore_join_array "$2"
		printf '  ],\n  "scrubbed": [\n'
		restore_join_array "$3"
		printf '  ]\n}\n'
	} >"$1"
}

# restore_seed_push <bare-repo> <branch> <prefix> -- commits and pushes
# whatever is under $work/restore-seed/<prefix> as the sole commit on
# <branch> of <bare-repo>, using PLAIN git (init/add/commit/push) -- this
# is fixture setup, not the code under test, so it deliberately does not
# reuse gitio.sh's own push-without-clone machinery. Requires
# GB_TEST_GIT_REAL=1 already exported (the stub's real-git passthrough),
# same as every call site below sets before calling this.
restore_seed_push() {
	_rsp_bare="$1"
	_rsp_branch="$2"
	git -C "$work/restore-seed" -c user.name=t -c user.email=t@t.test add -A >/dev/null 2>&1
	git -C "$work/restore-seed" -c user.name=t -c user.email=t@t.test commit -q -m seed >/dev/null 2>&1
	git -C "$work/restore-seed" push -q "$_rsp_bare" "HEAD:refs/heads/$_rsp_branch" >/dev/null 2>&1
}

# restore_setup -- common fixture: a fresh bare repo, a fresh seed working
# tree, GB_URL/GB_ROOT/the git-stub swap all pointed at each other. Callers
# populate $work/restore-seed/devices/rt1/{files,meta,manifest.json}
# themselves (each test's own manifest is the point under test) and then
# call restore_seed_push, then `gb_restore rt1 ...`.
restore_setup() {
	GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
	rm -rf "$work/restore-bare.git" "$work/restore-seed" "$work/restore-dest"
	git init --bare -q "$work/restore-bare.git"
	git init -q "$work/restore-seed"
	mkdir -p "$work/restore-seed/devices/rt1/files" "$work/restore-seed/devices/rt1/meta" "$work/restore-dest"
	GB_URL='https://example.org/o/r.git'; export GB_URL
	GB_TEST_GIT_REMOTE_URL="$GB_URL"; export GB_TEST_GIT_REMOTE_URL
	GB_TEST_GIT_REMOTE_PATH="$work/restore-bare.git"; export GB_TEST_GIT_REMOTE_PATH
	GB_ROOT="$work/restore-dest"; export GB_ROOT
	GB_TEST_BOARD='{"model":"Test Board","release":{"target":"testarch/generic"}}'; export GB_TEST_BOARD
	printf '{"model":"Test Board","release":{"target":"testarch/generic"}}\n' \
		>"$work/restore-seed/devices/rt1/meta/board.json"
	printf 'NAME="OpenWrt"\nVERSION_ID="25.12.4"\n' >"$work/restore-seed/devices/rt1/meta/os-release.txt"
	fixture 'gitbackup.origin.branch=device/{device}' 'gitbackup.main.path_prefix=devices/{device}'
}

restore_teardown() {
	unset GB_TEST_GIT_REAL GB_TEST_GIT_REMOTE_URL GB_TEST_GIT_REMOTE_PATH GB_TEST_BOARD GB_URL GB_ROOT
}

# restore_manifest_entries <manifest.json> -- prints one entries[] object
# per line, verbatim. Deliberately a fresh little parser, NOT a call into
# restore.sh's own _gb_restore_each_entry: the ticket's own permissions
# test below has to walk the manifest independently of the code under
# test, or a bug shared by both readers (say, a field silently dropped)
# would agree with itself and never turn red (executor.md: "утверждение,
# которое считает ответ тем же способом, что и код, не может с ним не
# согласиться"). Relies on the same one-object-per-line, no-nested-
# brackets shape collect.sh writes and restore.sh's own reader already
# assumes.
restore_manifest_entries() {
	_rme_in=0
	while IFS= read -r _rme_line || [ -n "$_rme_line" ]; do
		case "$_rme_line" in
			'  "entries": ['*) _rme_in=1; continue ;;
			'  ],') _rme_in=0; continue ;;
		esac
		[ "$_rme_in" -eq 1 ] || continue
		_rme_obj="${_rme_line%,}"
		_rme_obj="${_rme_obj#    }"
		[ -n "$_rme_obj" ] && printf '%s\n' "$_rme_obj"
	done <"$1"
}

# restore_field <object> <field> -- a quoted-string field's value out of
# one manifest entry object (plain sed, independent of restore.sh's own
# _gb_restore_json_str -- see restore_manifest_entries above for why).
restore_field() {
	printf '%s' "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p'
}

# restore_field_num <object> <field> -- an unquoted numeric field's value
# (mode/uid/gid), or empty if the field is absent.
restore_field_num() {
	printf '%s' "$1" | sed -n 's/.*"'"$2"'":\([0-9][0-9]*\).*/\1/p'
}

# t_restore_permissions_symlinks_emptydirs -- the ticket's own headline
# acceptance criterion, taken literally: "восстановить и сравнить
# stat -c '%a %u %g' по каждому пути с manifest" -- EVERY path in
# entries[], walked programmatically via restore_manifest_entries/
# restore_field* above, not four hand-picked assertions. A fixture with
# only four entries still has to be walked rather than enumerated by
# name, because the walk itself -- not this particular fixture size -- is
# what has to keep catching a fifth path some future manifest adds.
#
# uid/gid in the fixture are this test's own (id -u/-g): chown to a uid a
# non-root test runner does not own would fail for reasons that have
# nothing to do with restore.sh's own correctness, so the fidelity being
# tested here is "does restore.sh apply exactly what the manifest says",
# not "can this suite run as root". A same-uid fixture cannot, by itself,
# prove chown was ever actually called (a file this process creates is
# already owned by this process) -- that is exactly what the separate
# t_restore_chown_is_actually_called below exists to close.
t_restore_permissions_symlinks_emptydirs() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup
		_rt_uid=$(id -u)
		_rt_gid=$(id -g)

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config" \
			"$work/restore-seed/devices/rt1/files/etc/dropbear"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		printf 'root:!:19000:0:99999:7:::\n' >"$work/restore-seed/devices/rt1/files/etc/shadow"
		printf 'fake-host-key\n' >"$work/restore-seed/devices/rt1/files/etc/dropbear/dropbear_rsa_host_key"
		ln -s '/tmp/resolv.conf.d/resolv.conf.auto' "$work/restore-seed/devices/rt1/files/etc/resolv.conf"

		_rt_sha_net=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_sha_shadow=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/shadow" | awk '{print $1}')
		_rt_sha_key=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/dropbear/dropbear_rsa_host_key" | awk '{print $1}')

		_rt_entries=$(printf '%s\n%s\n%s\n%s\n%s\n' \
			"$(restore_entry_file /etc/config/network 640 "$_rt_uid" "$_rt_gid" "$_rt_sha_net")" \
			"$(restore_entry_file /etc/shadow 600 "$_rt_uid" "$_rt_gid" "$_rt_sha_shadow")" \
			"$(restore_entry_file /etc/dropbear/dropbear_rsa_host_key 600 "$_rt_uid" "$_rt_gid" "$_rt_sha_key")" \
			"$(restore_entry_symlink /etc/resolv.conf 777 "$_rt_uid" "$_rt_gid" /tmp/resolv.conf.d/resolv.conf.auto)" \
			"$(restore_entry_dir /var/empty-thing 750 "$_rt_uid" "$_rt_gid")")
		_rt_manifest="$work/restore-seed/devices/rt1/manifest.json"
		restore_write_manifest "$_rt_manifest" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1
		_rt_seed_commit=$(git -C "$work/restore-seed" rev-parse HEAD)

		out=$(gb_restore rt1 '' --yes 2>&1)
		eq 'gb_restore exits 0' '0' "$?"

		# Review finding: _gb_restore_perm_one's own symlink branch once
		# reused gb_restore's outer "_gb_target" (the commit sha) as its
		# own local variable name for the symlink's target string --
		# clobbering it, since nothing in this codebase declares locals.
		# A manifest with a symlink made the closing "restored ... from
		# ..." message print the symlink's target instead of the commit.
		# This fixture already has a symlink, so it is the right place to
		# pin the fix.
		contains 'the closing message names the actual commit restored, not a symlink target the fix once clobbered it with' \
			"restored rt1 from $_rt_seed_commit" "$out"

		# The walk itself: a guard first (a broken parser silently
		# iterating zero times would otherwise leave every check below
		# vacuously green), then one mode/uid/gid comparison per entry
		# plus a content check appropriate to its type.
		eq 'the manifest walk below actually iterates over every entries[] item' \
			'5' "$(restore_manifest_entries "$_rt_manifest" | wc -l | tr -d ' ')"

		restore_manifest_entries "$_rt_manifest" | while IFS= read -r _rt_obj; do
			_rt_path=$(restore_field "$_rt_obj" path)
			_rt_type=$(restore_field "$_rt_obj" type)
			_rt_mode=$(restore_field_num "$_rt_obj" mode)
			_rt_want_uid=$(restore_field_num "$_rt_obj" uid)
			_rt_want_gid=$(restore_field_num "$_rt_obj" gid)
			_rt_dest="$work/restore-dest$_rt_path"

			# Mode is skipped for a symlink, same reason the fixture this
			# replaced already noted: lstat's mode bits for a symlink are
			# not portable (Linux always reports 0777 regardless of
			# chmod, per restore.sh's own _gb_restore_perm_one comment;
			# macOS's lstat instead reflects the creating process's
			# umask) -- asserting it here would fail on this dev host for
			# a platform difference, not a restore.sh bug. uid/gid are
			# still real and checked on every type, mode included.
			if [ "$_rt_type" = symlink ]; then
				eq "manifest walk: $_rt_path -- stat -c '%u %g' matches uid/gid from manifest.json (mode not portable for a symlink)" \
					"$_rt_want_uid $_rt_want_gid" \
					"$(stat -c '%u %g' "$_rt_dest" 2>/dev/null)"
			else
				eq "manifest walk: $_rt_path -- stat -c '%a %u %g' matches mode/uid/gid from manifest.json" \
					"$_rt_mode $_rt_want_uid $_rt_want_gid" \
					"$(stat -c '%a %u %g' "$_rt_dest" 2>/dev/null)"
			fi

			case "$_rt_type" in
				file)
					_rt_want_sha=$(restore_field "$_rt_obj" sha256)
					eq "manifest walk: $_rt_path -- restored content's sha256 matches manifest.json" \
						"$_rt_want_sha" "$(sha256sum "$_rt_dest" 2>/dev/null | awk '{print $1}')"
					;;
				symlink)
					if [ -L "$_rt_dest" ]; then
						ok "manifest walk: $_rt_path -- restored as a symlink, not copied as file content"
					else
						no "manifest walk: $_rt_path -- restored as a symlink, not copied as file content" 'it is a regular file'
					fi
					_rt_want_target=$(restore_field "$_rt_obj" target)
					eq "manifest walk: $_rt_path -- symlink target matches manifest.json verbatim" \
						"$_rt_want_target" "$(readlink "$_rt_dest" 2>/dev/null)"
					;;
				dir)
					if [ -d "$_rt_dest" ]; then
						ok "manifest walk: $_rt_path -- directory exists after restore"
					else
						no "manifest walk: $_rt_path -- directory exists after restore" 'missing'
					fi
					;;
			esac
		done

		restore_teardown
	)
}

# t_restore_chown_is_actually_called -- Condition 2 of the dozapros for
# this ticket: the walk above alone cannot go red if gb_restore's chown
# calls are deleted outright, because its fixture's uid/gid are this test
# runner's own (id -u/-g) -- a file this same process creates already has
# that owner with no chown ever run. Confirmed by mutation: commenting
# out both chown lines in _gb_restore_perm_one left the walk above fully
# green.
#
# Fix: use a uid/gid that is NOT the current user (so a no-op restore
# would visibly disagree with the manifest), and stub `chown` on PATH to
# RECORD every invocation instead of running the real syscall -- an
# unprivileged test runner cannot chown to an arbitrary uid for real
# (that would fail on any non-root environment for a reason that has
# nothing to do with restore.sh), but it can always prove the call
# happened with the right arguments. Same "stub the exact tool, not the
# module" method t_restore_overwrites_existing_destination already uses
# for busybox cp's shape.
t_restore_chown_is_actually_called() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		_rt_other_uid=$(($(id -u) + 1))
		_rt_other_gid=$(($(id -g) + 1))

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		ln -s /tmp/target "$work/restore-seed/devices/rt1/files/etc/resolv.conf"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')

		_rt_entries=$(printf '%s\n%s\n%s\n' \
			"$(restore_entry_file /etc/config/network 640 "$_rt_other_uid" "$_rt_other_gid" "$_rt_sha")" \
			"$(restore_entry_symlink /etc/resolv.conf 777 "$_rt_other_uid" "$_rt_other_gid" /tmp/target)" \
			"$(restore_entry_dir /var/empty-thing 750 "$_rt_other_uid" "$_rt_other_gid")")
		_rt_manifest="$work/restore-seed/devices/rt1/manifest.json"
		restore_write_manifest "$_rt_manifest" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		_rt_chown_log="$work/chown-calls.log"
		: >"$_rt_chown_log"
		mkdir -p "$work/chown-stub"
		cat >"$work/chown-stub/chown" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$_rt_chown_log"
exit 0
STUB
		chmod +x "$work/chown-stub/chown"

		PATH="$work/chown-stub:$PATH" gb_restore rt1 '' --yes >/dev/null 2>&1
		eq 'gb_restore exits 0 with chown stubbed to a recording no-op' '0' "$?"

		restore_manifest_entries "$_rt_manifest" | while IFS= read -r _rt_obj; do
			_rt_path=$(restore_field "$_rt_obj" path)
			_rt_type=$(restore_field "$_rt_obj" type)
			_rt_want_uid=$(restore_field_num "$_rt_obj" uid)
			_rt_want_gid=$(restore_field_num "$_rt_obj" gid)
			_rt_dest="$work/restore-dest$_rt_path"
			if [ "$_rt_type" = symlink ]; then
				_rt_want_call="-h $_rt_want_uid:$_rt_want_gid $_rt_dest"
			else
				_rt_want_call="$_rt_want_uid:$_rt_want_gid $_rt_dest"
			fi
			# Mutation check: delete gb_restore's chown call for this
			# entry type (restore.sh, _gb_restore_perm_one) and this
			# specific assertion turns red -- nothing else in the suite
			# depends on the real ownership actually changing.
			contains "chown was actually invoked for $_rt_path with the manifest's uid:gid" \
				"$_rt_want_call" "$(cat "$_rt_chown_log")"
		done

		restore_teardown
	)
}

# t_restore_overwrites_existing_destination -- owlab stand finding: busybox
# cp (unlike GNU/BSD cp on a dev host) refuses an existing destination
# outright ("File exists") unless given -f, which broke restoring over
# ANY path that already exists on the router -- i.e. nearly everything,
# found live restoring over /etc/hosts. A plain macOS/GNU `cp` cannot
# reproduce this (it overwrites by default with no flag at all), so this
# stubs `cp` to enforce busybox's own stricter rule for this one test,
# the same technique t_have_net_busybox_shape already uses for D01.
t_restore_overwrites_existing_destination() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'new content\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(restore_entry_file /etc/config/network 640 0 0 "$_rt_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		mkdir -p "$work/restore-dest/etc/config"
		printf 'stale content already on disk\n' >"$work/restore-dest/etc/config/network"

		mkdir -p "$work/cp-busybox-shape"
		cat >"$work/cp-busybox-shape/cp" <<'STUB'
#!/bin/sh
case " $* " in
	*' -f '*) ;;
	*) echo "cp: can't create destination: File exists" >&2; exit 1 ;;
esac
for a in "$@"; do
	case "$a" in
		-*) ;;
		*) last="$a" ;;
	esac
done
args=""
for a in "$@"; do
	case "$a" in
		-*) ;;
		*) args="$args $a" ;;
	esac
done
# shellcheck disable=SC2086
command -p cp $args
STUB
		chmod +x "$work/cp-busybox-shape/cp"

		PATH="$work/cp-busybox-shape:$PATH" gb_restore rt1 '' --yes >"$work/restore-overwrite-out.txt" 2>&1
		eq 'restoring over an existing file succeeds against a busybox-shaped cp (owlab finding)' \
			'0' "$?"
		eq 'and the stale content is actually replaced' 'new content' \
			"$(cat "$work/restore-dest/etc/config/network")"

		restore_teardown
	)
}

# t_restore_sha_mismatch_stops_before_write -- a corrupted/tampered backup
# must refuse outright, and refuse BEFORE touching GB_ROOT at all: the
# destination is asserted to still not exist, not just that the command
# exited non-zero.
# t_restore_refuses_a_hostile_manifest_entry -- the manifest is remote
# input, and every field in it decides something argv-shaped: `path` picks
# the destination, `mode`/`uid`/`gid` become chmod/chown arguments. None of
# them was checked before _gb_restore_check_entries existed.
#
# The point of each case below is NOT "this path is forbidden" -- restoring
# writes back the whole backup set wherever it lived, by design, and there
# is no allowlist. It is that an entry has to say what it means in the one
# spelling every pass agrees on, and that a value which is not a mode
# cannot reach `chmod` as if it were one. Exit 4 (refused for safety), and
# the whole manifest is refused rather than the one entry skipped: a
# manifest collect.sh did not write is not a backup worth half-applying.
t_restore_refuses_a_hostile_manifest_entry() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(restore_entry_file '/etc/../etc/config/network' 640 0 0 "$_rt_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		out=$(gb_restore rt1 '' --yes 2>&1)
		eq 'a non-canonical entry path is refused with exit 4' '4' "$?"
		contains 'and the reason says which entry and why' 'not a canonical path' "$out"
		if [ -e "$work/restore-dest/etc/config/network" ]; then
			no 'nothing was written before the refusal' 'the file exists anyway'
		else
			ok 'nothing was written before the refusal'
		fi

		restore_teardown
	)
}

# t_restore_refuses_an_option_shaped_mode -- the same gate, on the field
# that reaches `chmod` argv. "--reference=/etc/shadow" is a real chmod
# option: left unchecked it copies another file's permission bits onto the
# destination instead of setting the mode the manifest claims to carry.
t_restore_refuses_an_option_shaped_mode() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(printf '{"path":"%s","type":"file","mode":"%s","uid":%s,"gid":%s,"sha256":"%s"}' \
			'/etc/config/network' '--reference=/etc/shadow' 0 0 "$_rt_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		out=$(gb_restore rt1 '' --yes 2>&1)
		eq 'an option-shaped mode is refused with exit 4' '4' "$?"
		contains 'and the reason names the field' 'is not 3 or 4 octal digits' "$out"

		restore_teardown
	)
}

# t_restore_never_writes_through_a_symlink -- a "file" entry whose
# destination is currently a symlink pointing somewhere else entirely.
# GNU cp -f opens the destination O_TRUNC, which follows the link and
# rewrites the target -- a path the manifest never named -- while busybox
# cp unlinks first; this pins the one behaviour, and pins it on the host
# whose cp has the following variant. The manifest's own set of paths is
# the complete set of files a restore may touch.
t_restore_never_writes_through_a_symlink() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(restore_entry_file '/etc/config/network' 640 0 0 "$_rt_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		# The router as found: something else already sitting at the
		# destination, as a link to a file the manifest says nothing about.
		mkdir -p "$work/restore-dest/etc/config"
		printf 'ORIGINAL\n' >"$work/restore-dest/etc/elsewhere"
		ln -s "$work/restore-dest/etc/elsewhere" "$work/restore-dest/etc/config/network"

		gb_restore rt1 '' --yes >/dev/null 2>&1
		eq 'the restore itself succeeds' '0' "$?"
		eq 'the link target is untouched' 'ORIGINAL' "$(cat "$work/restore-dest/etc/elsewhere")"
		if [ -L "$work/restore-dest/etc/config/network" ]; then
			no 'the destination is a real file now, not still a link' 'it is still a symlink'
		else
			ok 'the destination is a real file now, not still a link'
		fi
		eq 'and it holds what the backup held' 'config network' "$(cat "$work/restore-dest/etc/config/network")"

		restore_teardown
	)
}

t_restore_sha_mismatch_stops_before_write() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_entries=$(restore_entry_file /etc/config/network 640 0 0 'deadbeef0000000000000000000000000000000000000000000000000000')
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		out=$(gb_restore rt1 '' --yes 2>&1)
		eq 'a sha256 mismatch is refused with exit 1' '1' "$?"
		if [ -e "$work/restore-dest/etc/config/network" ]; then
			no 'nothing was written to disk before the mismatch was caught' 'the file exists anyway'
		else
			ok 'nothing was written to disk before the mismatch was caught'
		fi

		restore_teardown
	)
}

# t_restore_board_mismatch -- refused without --force, with an explanation
# naming interfaces/wireless; proceeds and actually writes with --force.
t_restore_board_mismatch() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup
		# The router this restore runs on: a different board entirely.
		GB_TEST_BOARD='{"model":"Other Board","release":{"target":"otherarch/generic"}}'
		export GB_TEST_BOARD

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(restore_entry_file /etc/config/network 640 0 0 "$_rt_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		out=$(gb_restore rt1 '' --yes 2>&1)
		eq 'a board mismatch without --force is refused with exit 4' '4' "$?"
		contains 'and the message explains why (interfaces/wireless will not match)' 'wireless' "$out"
		if [ -e "$work/restore-dest/etc/config/network" ]; then
			no 'nothing was written for the refused restore' 'the file exists anyway'
		else
			ok 'nothing was written for the refused restore'
		fi

		out2=$(gb_restore rt1 '' --yes --force 2>&1)
		eq 'the same mismatch with --force exits 0' '0' "$?"
		if [ -f "$work/restore-dest/etc/config/network" ]; then
			ok 'and --force actually restores the file'
		else
			no 'and --force actually restores the file' 'missing'
		fi

		restore_teardown
	)
}

# t_restore_os_release_major_mismatch_warns -- a major OpenWrt version gap
# is a warning (logged), never a refusal -- restore still proceeds.
t_restore_os_release_major_mismatch_warns() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup
		GB_TEST_LOG="$work/restore-log"; export GB_TEST_LOG
		: >"$GB_TEST_LOG"
		mkdir -p "$work/restore-dest/etc"
		printf 'NAME="OpenWrt"\nVERSION_ID="25.12.4"\n' >"$work/restore-dest/etc/os-release"
		printf 'NAME="OpenWrt"\nVERSION_ID="21.02.3"\n' >"$work/restore-seed/devices/rt1/meta/os-release.txt"

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(restore_entry_file /etc/config/network 640 0 0 "$_rt_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		out=$(gb_restore rt1 '' --yes 2>&1)
		eq 'a major OpenWrt version gap does not refuse the restore' '0' "$?"
		contains 'but it is logged as a warning' '21.02.3' "$(cat "$GB_TEST_LOG")"
		if [ -f "$work/restore-dest/etc/config/network" ]; then
			ok 'and the restore actually completed'
		else
			no 'and the restore actually completed' 'missing'
		fi

		unset GB_TEST_LOG
		restore_teardown
	)
}

# t_restore_scrubbed_list_printed -- a non-empty manifest.scrubbed must be
# surfaced to the operator, since a redacted option's real value can only
# ever be typed back in by hand (spec: "manifest.scrubbed != [] -- напечатать
# список значений, которые надо ввести руками").
t_restore_scrubbed_list_printed() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(restore_entry_file /etc/config/network 640 0 0 "$_rt_sha")
		_rt_scrubbed=$(restore_scrubbed_entry /etc/config/wireless 'wireless.@wifi-iface[0].key')
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" "$_rt_scrubbed"
		restore_seed_push "$work/restore-bare.git" device/rt1

		out=$(gb_restore rt1 '' --yes 2>&1)
		eq 'exits 0 -- a scrubbed value is a to-do, not a failure' '0' "$?"
		contains 'the redacted option is printed for the operator to re-enter by hand' \
			'wireless.@wifi-iface[0].key' "$out"

		restore_teardown
	)
}

# t_restore_dry_run_untouched -- --dry-run describes the plan and touches
# nothing: the destination directory must still be completely empty
# afterward, not merely "the one file we happened to check is absent".
t_restore_dry_run_untouched() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(restore_entry_file /etc/config/network 640 0 0 "$_rt_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		out=$(gb_restore rt1 '' --dry-run 2>&1)
		eq '--dry-run exits 0' '0' "$?"
		contains 'and prints what would be written' '/etc/config/network' "$out"

		_rt_left=$(find "$work/restore-dest" -mindepth 1 2>/dev/null | grep -c .)
		eq '--dry-run leaves the destination completely untouched' '0' "$_rt_left"

		restore_teardown
	)
}

# t_restore_fetches_only_its_own_branch -- "тянуть данные минимально: своя
# ветка ... полного клона не появляется". A second device's branch exists
# on the same bare repo; restoring rt1 must leave the scratch repo with no
# trace of rt2's branch at all, proving this fetched one ref, not `--all`.
t_restore_fetches_only_its_own_branch() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_entries=$(restore_entry_file /etc/config/network 640 0 0 "$_rt_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		# A second device, its own unrelated branch on the same repo.
		rm -rf "$work/restore-seed2"
		git init -q "$work/restore-seed2"
		mkdir -p "$work/restore-seed2/devices/rt2/files/etc"
		printf 'unrelated rt2 content\n' >"$work/restore-seed2/devices/rt2/files/etc/other"
		git -C "$work/restore-seed2" -c user.name=t -c user.email=t@t.test add -A >/dev/null 2>&1
		git -C "$work/restore-seed2" -c user.name=t -c user.email=t@t.test commit -q -m seed2 >/dev/null 2>&1
		git -C "$work/restore-seed2" push -q "$work/restore-bare.git" HEAD:refs/heads/device/rt2 >/dev/null 2>&1

		# Not `out=$(gb_restore ...)`: that form would itself fork a
		# subshell to run gb_restore in, and gb_restore's own EXIT trap
		# would then fire the instant THAT subshell finishes -- i.e.
		# immediately, before this line even returns control here, wiping
		# the scratch repo away before it could be inspected below. A
		# plain redirect keeps gb_restore running in the CURRENT (test
		# body) subshell, so its trap only fires once this whole test
		# function's own subshell exits, same as restore.sh's header
		# comment describes.
		gb_restore rt1 '' --yes >"$work/restore-fetch-out.txt" 2>&1
		eq 'gb_restore exits 0' '0' "$?"

		# $TMPDIR is this run's own $work (see the top of this file), not
		# the shared system /tmp, so this scan can only ever see scratch
		# directories THIS invocation created -- a bare `find /tmp -name
		# 'gitbackup-restore.*' | head -n1` used to be able to pick up a
		# DIFFERENT `sh tests/run.sh` invocation's own directory instead
		# when two ran at the same time.
		_rt_workdir=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gitbackup-restore.*' 2>/dev/null | head -n 1)
		if [ -n "$_rt_workdir" ] && [ -d "$_rt_workdir/repo" ]; then
			_rt_refs=$(git -C "$_rt_workdir/repo" for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null)
			contains 'the scratch repo fetched device/rt1' 'device/rt1' "$_rt_refs"
			case "$_rt_refs" in
				*device/rt2*) no 'and never fetched the other device'"'"'s branch' "found it: $_rt_refs" ;;
				*) ok 'and never fetched the other device'"'"'s branch' ;;
			esac
		else
			no 'the scratch repo could be inspected before its own cleanup trap fires' 'not found'
		fi

		restore_teardown
	)
}

# t_restore_write_failure_does_not_block_perms -- ticket 19's own headline
# scenario, reproduced exactly as found on the owlab stand: restoring over
# /etc/hosts there fails because it is a Docker/OrbStack bind mount, and
# busybox/coreutils cp's own "File exists" is stubbed here verbatim (same
# "stub the exact tool's shape" technique t_restore_overwrites_existing_
# destination already uses for busybox's own missing -f) rather than
# fabricated a real mount, which an unprivileged host test cannot do.
# Everything ELSE in the manifest must still land with the manifest's own
# mode, the operator must be told the truth about the one path that did
# not, and the exit code must say so too.
#
# Mutation check: putting the old
#   _gb_restore_write_files ... || { ...; return 1; }
# back in front of _gb_restore_apply_perms's own call (restore.sh) turns
# the mode assertion below red -- that `return 1` leaves gb_restore before
# _gb_restore_apply_perms ever runs for /etc/shadow or anything else, so
# it keeps whatever mode `cp` itself produced (this process' own umask,
# never 600) instead of the manifest's.
t_restore_write_failure_does_not_block_perms() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc"
		printf '127.0.0.1 localhost\n' >"$work/restore-seed/devices/rt1/files/etc/hosts"
		printf 'root:!:19000:0:99999:7:::\n' >"$work/restore-seed/devices/rt1/files/etc/shadow"
		_rt_sha_hosts=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/hosts" | awk '{print $1}')
		_rt_sha_shadow=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/shadow" | awk '{print $1}')
		_rt_uid=$(id -u)
		_rt_gid=$(id -g)
		_rt_entries=$(printf '%s\n%s\n' \
			"$(restore_entry_file /etc/hosts 644 "$_rt_uid" "$_rt_gid" "$_rt_sha_hosts")" \
			"$(restore_entry_file /etc/shadow 600 "$_rt_uid" "$_rt_gid" "$_rt_sha_shadow")")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		# Something has to already be at the destination for a "cannot
		# replace it" cp to have anything to refuse -- an empty
		# destination directory has nothing to overwrite in the first
		# place. Left world-readable on purpose, like a real /etc/hosts:
		# the point is that the REPLACE is refused, not that the file's
		# own permission bits were ever wrong.
		mkdir -p "$work/restore-dest/etc"
		printf "stale hosts file, e.g. Docker's own bind mount\\n" >"$work/restore-dest/etc/hosts"
		chmod 644 "$work/restore-dest/etc/hosts"

		mkdir -p "$work/cp-hosts-stuck"
		cat >"$work/cp-hosts-stuck/cp" <<'STUB'
#!/bin/sh
for a in "$@"; do dest="$a"; done
case "$dest" in
	*etc/hosts) echo "cp: can't create '$dest': File exists" >&2; exit 1 ;;
esac
args=""
for a in "$@"; do
	case "$a" in
		-*) ;;
		*) args="$args $a" ;;
	esac
done
# shellcheck disable=SC2086
command -p cp $args
STUB
		chmod +x "$work/cp-hosts-stuck/cp"

		out=$(PATH="$work/cp-hosts-stuck:$PATH" gb_restore rt1 '' --yes 2>&1)
		eq 'a write failure on one path exits non-zero, not a silent 0' '1' "$?"
		contains 'and names the specific path that failed' 'etc/hosts' "$out"
		contains 'with the real reason cp reported, not a swallowed one' 'File exists' "$out"

		eq 'the OTHER path (etc/shadow) still got the manifest'"'"'s own mode despite etc/hosts failing' \
			'600 '"$_rt_uid $_rt_gid" \
			"$(stat -c '%a %u %g' "$work/restore-dest/etc/shadow" 2>/dev/null)"

		if [ -f "$work/restore-dest/etc/shadow" ]; then
			ok 'and etc/shadow was actually written despite etc/hosts failing'
		else
			no 'and etc/shadow was actually written despite etc/hosts failing' 'missing'
		fi

		restore_teardown
	)
}

# t_restore_precheck_skips_a_known_unwritable_path_before_attempting_cp --
# criterion 3: writability is checked the same way sha256 already is,
# BEFORE the first file is touched, not discovered only when cp happens to
# fail. Proven with a directory stripped of its own write permission
# (chmod 555) -- unlike the st_dev-based half of the same check restore.sh
# also does for a single bind-mounted FILE (confirmed live on the owlab
# stand only: /etc/hosts there is device 41, /etc is device 1048628 --
# there is no portable, unprivileged way to fabricate a real distinct
# mount point from a host test), an unwritable directory is a real,
# unprivileged-reproducible instance of "this destination cannot be
# replaced" that the very same preflight is expected to catch.
#
# The proof that this was caught AHEAD OF TIME, not merely handled after a
# failed attempt (which the previous test already covers): cp(1) itself,
# stubbed to log every invocation it receives, never once runs for the
# locked path -- only for the other, writable one.
t_restore_precheck_skips_a_known_unwritable_path_before_attempting_cp() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/locked" \
			"$work/restore-seed/devices/rt1/files/etc/config"
		printf 'locked content\n' >"$work/restore-seed/devices/rt1/files/etc/locked/hosts"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_rt_sha_locked=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/locked/hosts" | awk '{print $1}')
		_rt_sha_net=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_rt_uid=$(id -u)
		_rt_gid=$(id -g)
		_rt_entries=$(printf '%s\n%s\n' \
			"$(restore_entry_file /etc/locked/hosts 644 "$_rt_uid" "$_rt_gid" "$_rt_sha_locked")" \
			"$(restore_entry_file /etc/config/network 640 "$_rt_uid" "$_rt_gid" "$_rt_sha_net")")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_rt_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		mkdir -p "$work/restore-dest/etc/locked"
		printf 'already there, directory refuses to give it up\n' >"$work/restore-dest/etc/locked/hosts"
		chmod 555 "$work/restore-dest/etc/locked"

		_rt_cp_log="$work/cp-calls.log"
		: >"$_rt_cp_log"
		mkdir -p "$work/cp-logger"
		cat >"$work/cp-logger/cp" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$_rt_cp_log"
args=""
for a in "\$@"; do
	case "\$a" in
		-*) ;;
		*) args="\$args \$a" ;;
	esac
done
# shellcheck disable=SC2086
command -p cp \$args
STUB
		chmod +x "$work/cp-logger/cp"

		out=$(PATH="$work/cp-logger:$PATH" gb_restore rt1 '' --yes 2>&1)
		_rt_rc=$?
		# Ticket 28: chmod 555 only makes a directory unwritable to an
		# UNPRIVILEGED process -- access(2) (what `[ -w ]`, and therefore
		# _gb_restore_check_writable, is built on) grants W_OK to a real
		# uid of 0 regardless of permission bits, so root's own cp
		# genuinely succeeds against this "locked" directory, exactly as
		# it would on the router itself (gitbackup always runs as root
		# there too -- there is no other user). That is not a bug in
		# restore.sh: the write really does go through for root, so
		# refusing it ahead of time would be the wrong answer, a false
		# preflight failure over a path cp could actually have written.
		# It does mean this half of the precondition -- same as the
		# st_dev/bind-mount half already documented above as
		# stand-verified only -- cannot be fabricated from a root test
		# runner (the default identity inside a plain `docker run`, unlike
		# a macOS dev shell or GitHub Actions' own non-root runner user).
		if [ "$(id -u)" = 0 ]; then
			skip 'restore still exits non-zero (etc/locked/hosts really did not get written)' \
				'running as root -- chmod cannot revoke this process'\''s own write access'
			skip 'and names the path the preflight refused' \
				'running as root -- chmod cannot revoke this process'\''s own write access'
			skip 'cp was never invoked for the locked path -- the preflight skipped it ahead of time' \
				'running as root -- chmod cannot revoke this process'\''s own write access'
		else
			eq 'restore still exits non-zero (etc/locked/hosts really did not get written)' '1' "$_rt_rc"
			contains 'and names the path the preflight refused' 'etc/locked/hosts' "$out"

			case "$(cat "$_rt_cp_log")" in
				*etc/locked/hosts*)
					no 'cp was never invoked for the locked path -- the preflight skipped it ahead of time' \
						"it was: $(cat "$_rt_cp_log")"
					;;
				*)
					ok 'cp was never invoked for the locked path -- the preflight skipped it ahead of time'
					;;
			esac
		fi
		contains 'but cp WAS invoked for the other, writable path' 'etc/config/network' "$(cat "$_rt_cp_log")"

		eq 'and that other path still got the manifest'"'"'s mode despite the skip' \
			'640 '"$_rt_uid $_rt_gid" \
			"$(stat -c '%a %u %g' "$work/restore-dest/etc/config/network" 2>/dev/null)"

		chmod 755 "$work/restore-dest/etc/locked" 2>/dev/null
		restore_teardown
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
		else
			skip 'every-minute expression answers within the next minute of now' 'python3 not found on PATH'
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
# paths.sh (ticket 17, spec "LuCI -> Paths", "Проверенные факты 25.12.4 ->
# sysupgrade")
# --------------------------------------------------------------------------

# paths_fixture -- a fake router filesystem under $work/paths-root and a
# fresh GB_SYSUPGRADE_CONF under $work, pointed at by GB_ROOT/
# GB_SYSUPGRADE_CONF -- gb_paths_validate's own existence check and
# gb_paths_size_kb's own sysupgrade -l walk both go through GB_ROOT, same
# seam collect.sh already uses, so a test never touches the real host
# filesystem.
paths_fixture() {
	rm -rf "$work/paths-root"
	mkdir -p "$work/paths-root/etc/config"
	: >"$work/paths-root/etc/config/network"
	GB_ROOT="$work/paths-root"; export GB_ROOT
	GB_SYSUPGRADE_CONF="$work/paths-sysupgrade.conf"; export GB_SYSUPGRADE_CONF
	rm -f "$GB_SYSUPGRADE_CONF"
}

# t_paths_validate_non_canonical -- the blacklist above is `case` glob
# matching, so it only ever held for one spelling. Every entry below names
# the reserved /etc/gitbackup directory to find(1) -- which is exactly what
# a sysupgrade.conf line becomes -- while matching none of the patterns
# that reserve it, and each one was accepted before gb_path_canon existed.
# Refused as a plain bad argument (exit 2), not a safety refusal (exit 4):
# the objection is to the spelling, and the message says which spelling to
# use instead, so the Paths view can show an operator what to type.
t_paths_validate_non_canonical() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture
		mkdir -p "$work/paths-root/etc/gitbackup"
		: >"$work/paths-root/etc/gitbackup/token"

		gb_paths_validate '//etc/gitbackup' 2>/dev/null
		eq 'a doubled leading slash is refused (exit 2)' '2' "$?"
		gb_paths_validate '/etc/./gitbackup' 2>/dev/null
		eq 'a "." component is refused (exit 2)' '2' "$?"
		gb_paths_validate '/etc/../etc/gitbackup/token' 2>/dev/null
		eq 'a ".." component is refused (exit 2)' '2' "$?"
		gb_paths_validate '/etc/config/' 2>/dev/null
		eq 'a trailing slash is refused (exit 2)' '2' "$?"

		contains 'and the reason names the canonical spelling to use instead' 			'/etc/gitbackup' "$(gb_paths_validate '//etc/gitbackup' 2>&1)"
	)
}

# t_path_canon -- gb_path_canon is the one answer two textual gates
# (gb_paths_validate's blacklist, collect.sh's hard-exclude) agree on. The
# expectations below are the four spellings POSIX pathname resolution
# treats as one path, worked out by hand from the rules themselves
# (repeated slashes are one slash, "." is the directory itself, ".." is its
# parent, a trailing slash names the same directory) -- never by running
# the function and writing down what it said.
t_path_canon() {
	(
		. "$share/lib.sh"

		eq 'an already-canonical path is returned unchanged' '/etc/gitbackup' "$(gb_path_canon '/etc/gitbackup')"
		eq 'a doubled leading slash collapses' '/etc/gitbackup' "$(gb_path_canon '//etc/gitbackup')"
		eq 'a doubled inner slash collapses' '/etc/gitbackup' "$(gb_path_canon '/etc//gitbackup')"
		eq 'a "." component is dropped' '/etc/gitbackup' "$(gb_path_canon '/etc/./gitbackup')"
		eq 'a ".." component is resolved lexically' '/etc/gitbackup' "$(gb_path_canon '/etc/../etc/gitbackup')"
		eq 'a trailing slash is dropped' '/etc/gitbackup' "$(gb_path_canon '/etc/gitbackup/')"
		eq 'the root itself survives as "/"' '/' "$(gb_path_canon '/')"
		eq '".." cannot climb above the root' '/' "$(gb_path_canon '/../..')"
		eq 'a relative path is handed back untouched' 'etc/gitbackup' "$(gb_path_canon 'etc/gitbackup')"
	)
}

t_paths_validate_blacklist() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture

		gb_paths_validate '/etc/gitbackup/token' 2>/dev/null
		eq '/etc/gitbackup/** is refused for safety (exit 4)' '4' "$?"
		gb_paths_validate '/proc/cpuinfo' 2>/dev/null
		eq '/proc/* is refused for safety (exit 4)' '4' "$?"
		gb_paths_validate '/sys/class' 2>/dev/null
		eq '/sys/* is refused for safety (exit 4)' '4' "$?"
		gb_paths_validate '/tmp/x' 2>/dev/null
		eq '/tmp/* is refused for safety (exit 4)' '4' "$?"

		_reason=$(gb_paths_validate '/etc/gitbackup/token' 2>&1)
		eq 'and a reason is printed, not a silent refusal' '1' "$([ -n "$_reason" ] && echo 1 || echo 0)"
	)
}

# t_paths_validate_space_and_missing -- the other half of "paths add
# отклоняет несуществующий путь, путь с пробелом" (ticket 17): both are
# plain bad-argument refusals (exit 2), distinct from the fixed-blacklist
# refusals above (exit 4) -- gb_paths_validate's own return code is what a
# caller uses to pick gb_die's exit status without reclassifying it.
t_paths_validate_space_and_missing() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture

		gb_paths_validate '/etc/config/has space' 2>/dev/null
		eq 'a path with a space is refused (exit 2 -- sysupgrade cannot support it)' '2' "$?"
		gb_paths_validate '/etc/config/does-not-exist' 2>/dev/null
		eq 'a nonexistent path is refused (exit 2)' '2' "$?"
		gb_paths_validate 'relative/path' 2>/dev/null
		eq 'a relative path is refused (exit 2)' '2' "$?"
		gb_paths_validate '/etc/config/network' 2>/dev/null
		eq 'an existing, absolute, unlisted path is accepted' '0' "$?"
	)
}

t_paths_add_del_idempotent() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture

		gb_paths_add '/etc/config/network'
		eq 'add succeeds' '0' "$?"
		gb_paths_add '/etc/config/network'
		eq 'adding the same path again is a no-op, not a duplicate' '0' "$?"
		eq 'the file has exactly one line' '1' "$(grep -c . "$GB_SYSUPGRADE_CONF")"

		gb_paths_add '/proc/cpuinfo' 2>/dev/null
		eq 'a blacklisted add is refused' '4' "$?"
		eq 'and never reaches the file' '0' "$(grep -c '/proc' "$GB_SYSUPGRADE_CONF")"

		gb_paths_del '/etc/config/network'
		eq 'del succeeds' '0' "$?"
		eq 'the line is gone' '0' "$(grep -c . "$GB_SYSUPGRADE_CONF")"
		gb_paths_del '/etc/config/network'
		eq 'deleting an absent path again is a no-op, not an error' '0' "$?"
	)
}

t_paths_list_and_size() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture
		awk 'BEGIN{for(i=0;i<2048;i++)printf "a"}' >"$work/paths-root/etc/config/network"
		printf '/etc/config/network\n' >"$GB_SYSUPGRADE_CONF"
		GB_TEST_SYSUPGRADE_L="$work/paths-sysupgrade-l"; export GB_TEST_SYSUPGRADE_L
		printf '/etc/config/network\n' >"$GB_TEST_SYSUPGRADE_L"

		eq 'gb_paths_list prints the raw sysupgrade.conf content' '/etc/config/network' "$(gb_paths_list)"
		eq 'gb_paths_size_kb ceils a 2048-byte effective set to 2 KB' '2' "$(gb_paths_size_kb)"
		unset GB_TEST_SYSUPGRADE_L
	)
}

# GB_STOCK_SYSUPGRADE_CONF -- the exact four lines the ticket 26 bug report
# reproduced against a stock OpenWrt 25.12.4 /etc/sysupgrade.conf: two
# header comments that happen to be one English sentence split in half, a
# commented-out example file, a commented-out example directory. Every one
# of the four starts with '#' -- none is a real entry.
GB_STOCK_SYSUPGRADE_CONF='## This file contains files and directories that should
## be preserved during an upgrade.
# /etc/example.conf
# /etc/openvpn/'

# t_paths_entries_stock_file -- ticket 26's own acceptance criterion: a
# stock /etc/sysupgrade.conf, untouched by any human, has zero genuine
# entries -- gb_paths_entries must report an empty list, not the four
# comment lines gb_paths_list (still raw) keeps returning unchanged.
t_paths_entries_stock_file() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture

		printf '%s\n' "$GB_STOCK_SYSUPGRADE_CONF" >"$GB_SYSUPGRADE_CONF"

		eq 'gb_paths_entries is empty on a stock, untouched file' '' "$(gb_paths_entries)"
		eq 'gb_paths_list itself is unchanged -- still the raw four comment lines' \
			"$GB_STOCK_SYSUPGRADE_CONF" "$(gb_paths_list)"
	)
}

# t_paths_entries_comments_only -- same shape as the stock file above, but
# with the two commented-out example lines given a leading '##' and an
# extra blank line thrown in, to make sure the filter is "starts with '#'
# at all", not "starts with exactly one '#'", and that blank lines are
# dropped too, not just single-'#' comments.
t_paths_entries_comments_only() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture

		printf '## a\n\n## b\n#c\n' >"$GB_SYSUPGRADE_CONF"

		eq 'gb_paths_entries is empty on a comments-and-blanks-only file' '' "$(gb_paths_entries)"
	)
}

# t_paths_entries_mixed_and_blanks -- the general case: real entries
# interleaved with comments and blank lines, in an order that does not put
# every comment first. gb_paths_entries must return exactly the real
# entries, in their original relative order, and nothing else -- neither a
# comment nor a blank line, wherever in the file they sit.
t_paths_entries_mixed_and_blanks() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture

		printf '# header\n\n/etc/config/network\n\n# a commented-out example\n/root/scripts\n#trailing\n' >"$GB_SYSUPGRADE_CONF"

		eq 'gb_paths_entries keeps only the two real entries, in order, comments and blanks dropped' \
			"$(printf '/etc/config/network\n/root/scripts')" "$(gb_paths_entries)"
	)
}

# t_paths_replace_entries_preserves_comments -- the trap ticket 26 exists to
# close: `set_paths` (ticket 13) writes back verbatim whatever entry list
# it is given, and that list never includes comments (gb_paths_entries is
# what the LuCI view now edits) -- so a full-list replace that simply wrote
# the given entries as the WHOLE new file would silently erase a stock
# router's own header comments on the very first save. gb_paths_replace_entries
# is the fix: every comment/blank line already in the file survives,
# unchanged and in its original order, and the new entries are appended
# after them -- exactly as given, never expanded (a directory entry stays
# one line).
t_paths_replace_entries_preserves_comments() {
	(
		. "$share/lib.sh"; . "$share/paths.sh"
		paths_fixture
		mkdir -p "$work/paths-root/root/scripts"

		printf '%s\n' "$GB_STOCK_SYSUPGRADE_CONF" >"$GB_SYSUPGRADE_CONF"

		gb_paths_replace_entries "$(printf '/etc/config/network\n/root/scripts')"

		eq 'the four original comment lines survive, unchanged and in order, followed by the new entries' \
			"$(printf '%s\n/etc/config/network\n/root/scripts' "$GB_STOCK_SYSUPGRADE_CONF")" \
			"$(cat "$GB_SYSUPGRADE_CONF")"

		# A second replace with an empty entry list (every path removed by
		# the operator) must not duplicate the preserved comments, and must
		# leave the file as comments-only, not delete the comments along
		# with the entries.
		gb_paths_replace_entries ''
		eq 'removing every entry leaves the comments intact, not deleted along with them' \
			"$GB_STOCK_SYSUPGRADE_CONF" "$(cat "$GB_SYSUPGRADE_CONF")"
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
printf 'ran %s\n' "$*" >>"$GB_RUN_LOG"
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
		# Review finding: a config-change-triggered run must be identifiable
		# as such in the commit message's own Trigger: field (_gb_run_write_message,
		# usr/sbin/gitbackup) -- an un-flagged `run` here defaults to
		# --trigger cron (cmd_run's own default), which would misreport a
		# debounced config-change run as "Trigger: cron" in the pushed commit.
		contains 'the debounced run is tagged --trigger procd, not left to default to cron' \
			'--trigger procd' "$(cat "$GB_RUN_LOG")"

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

# t_cli_unknown_command -- ticket 17 closed the last of R89's eleven
# subcommands (collect/diff/paths/card, formerly "not implemented yet"
# placeholders in this same dispatch's default case) -- what is left of
# that branch is exactly what it always was underneath: a name that is
# not a subcommand at all.
t_cli_unknown_command() {
	out=$(cli frobnicate 2>&1)
	eq 'an unknown subcommand exits 1' '1' "$?"
	contains 'and says so' "unknown command 'frobnicate'" "$out"
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
	else
		skip 'status prints parseable JSON' 'python3 not found on PATH'
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
	else
		skip 'status still prints parseable JSON on the default config' 'python3 not found on PATH'
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

# t_cli_test_hostkey_needs_confirmation -- ticket 20's headline bug,
# exercised through the full CLI rather than auth.sh directly: a reachable,
# untrusted host key with NO stdin at all -- exactly gbrpc_test's own
# `"$GB_BIN" test </dev/null` shape -- must read as "needs confirmation",
# never as "was not accepted" (a real, typed decline, t_cli_test_hostkey_
# declined above) and never blame the operator for a question nobody asked.
t_cli_test_hostkey_needs_confirmation() {
	GB_ETC_DIR="$work/etc-t-hk-noask"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=git@example.com:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'
	GB_TEST_SSH_HOSTKEY='example.com ssh-ed25519 AAAAtestkey'; export GB_TEST_SSH_HOSTKEY
	out=$(cli test </dev/null 2>&1)
	eq 'no interactive input to confirm a host key exits 3' '3' "$?"
	contains 'and the message asks for confirmation, not a verdict' 'needs confirmation' "$out"
	case "$out" in
		*'was not accepted'*) no 'and never claims the operator declined' "$out" ;;
		*) ok 'and never claims the operator declined' ;;
	esac
	unset GB_TEST_SSH_HOSTKEY GB_ETC_DIR
}

# t_cli_hostkey_not_ssh -- `hostkey` only makes sense for an ssh:// remote
# (an https:// one authenticates with a token, not a host key); refused
# with exit 2, the same "invalid config for what was asked" bucket
# gb_validate_config itself uses elsewhere.
t_cli_hostkey_not_ssh() {
	GB_ETC_DIR="$work/etc-t-hk-https"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git'
	out=$(cli hostkey show 2>&1)
	eq 'hostkey show on an https remote exits 2' '2' "$?"
	contains 'and explains there is no host key for this transport' 'not ssh' "$out"
	unset GB_ETC_DIR
}

# t_cli_hostkey_show_accept_roundtrip -- ticket 20's second defect, end to
# end through the CLI exactly as the rpcd plugin will drive it: `hostkey
# show` with no stdin at all (there is none to read -- this command never
# asks anything), then `hostkey accept <fingerprint>` with the fingerprint
# copied verbatim out of `show`'s own JSON, then a plain `test` (still with
# no stdin) that now succeeds without ever prompting. A real key pair is
# generated so ssh-keygen actually produces a fingerprint to round-trip,
# instead of two empty strings agreeing by accident.
t_cli_hostkey_show_accept_roundtrip() {
	GB_ETC_DIR="$work/etc-t-hk-rt"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=git@example.com:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'

	_gb_hk_key="$work/cli-hostkey-key"
	rm -f "$_gb_hk_key" "$_gb_hk_key.pub"
	ssh-keygen -t ed25519 -N '' -f "$_gb_hk_key" >/dev/null
	GB_TEST_SSH_HOSTKEY="example.com $(cat "$_gb_hk_key.pub")"; export GB_TEST_SSH_HOSTKEY

	out=$(cli hostkey show </dev/null 2>&1)
	eq 'hostkey show on an untrusted host exits 0 with no stdin needed' '0' "$?"
	contains 'and reports trusted:false' '"trusted": false' "$out"
	_gb_hk_fp=$(printf '%s' "$out" | sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	if [ -n "$_gb_hk_fp" ]; then
		ok 'and includes a non-empty fingerprint'
	else
		no 'and includes a non-empty fingerprint' "$out"
	fi

	out=$(cli hostkey accept 'not the right fingerprint' </dev/null 2>&1)
	eq 'accepting the wrong fingerprint exits 4' '4' "$?"

	out=$(cli hostkey accept "$_gb_hk_fp" </dev/null 2>&1)
	eq 'accepting the exact fingerprint shown exits 0' '0' "$?"
	contains 'and confirms it' '"ok": true' "$out"

	out=$(cli hostkey show </dev/null 2>&1)
	eq 'hostkey show now exits 0' '0' "$?"
	contains 'and reports trusted:true' '"trusted": true' "$out"

	GB_TEST_GIT_RC=0; export GB_TEST_GIT_RC
	out=$(cli test </dev/null 2>&1)
	eq 'test connection now passes without any stdin at all' '0' "$?"
	contains 'and reports success' 'reachable and authenticated' "$out"

	unset GB_TEST_SSH_HOSTKEY GB_TEST_GIT_RC GB_ETC_DIR
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

# t_cli_keygen_force_confirm -- ticket 25, end to end through the CLI: a
# bare `--force` on an existing key only ever shows its fingerprint and
# refuses (exit 4) -- never a `read` prompt, so there is no separate
# non-interactive branch to get wrong the way ticket 20 found for hostkey.
# Only a second call that names that exact fingerprint back with
# `--confirm` actually regenerates.
t_cli_keygen_force_confirm() {
	GB_ETC_DIR="$work/etc-kfc"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.key_file=$work/etc-kfc/id_ed25519" \
		'gitbackup.origin.url='

	cli keygen >/dev/null 2>&1
	_gb_before=$(cat "$work/etc-kfc/id_ed25519")

	out=$(cli keygen --force 2>&1)
	eq 'keygen --force with no confirmation exits 4' '4' "$?"
	eq 'and the key is left untouched' "$_gb_before" "$(cat "$work/etc-kfc/id_ed25519")"
	contains 'and says this is irreversible' 'beyond recovery' "$out"
	contains 'and says the provider needs a new deploy key afterward' 'add the NEW public key at the provider' "$out"

	_gb_fp=$(printf '%s\n' "$out" | sed -n '1s/^confirm-required //p')
	if [ -n "$_gb_fp" ]; then
		ok 'and its first line names a non-empty fingerprint to confirm with'
	else
		no 'and its first line names a non-empty fingerprint to confirm with' "$out"
	fi

	out=$(cli keygen --force --confirm 'not the right fingerprint' 2>&1)
	eq 'a wrong --confirm is refused the same way as none at all' '4' "$?"
	eq 'and the key is still untouched' "$_gb_before" "$(cat "$work/etc-kfc/id_ed25519")"

	out=$(cli keygen --force --confirm "$_gb_fp" 2>&1)
	eq 'the exact fingerprint shown regenerates the key' '0' "$?"
	if [ "$(cat "$work/etc-kfc/id_ed25519")" = "$_gb_before" ]; then
		no 'and the key actually changed' 'identical bytes as before'
	else
		ok 'and the key actually changed'
	fi
	eq 'and the previous key survives as .old' "$_gb_before" "$(cat "$work/etc-kfc/id_ed25519.old" 2>/dev/null)"

	unset GB_ETC_DIR
}

# t_cli_test_forgets_old_key_on_success -- ticket 25's decision half:
# id_ed25519.old must disappear once (and only once) a `gitbackup test` run
# actually proves the CURRENT key works, never before. A real key pair
# stands in for the remote's own SSH host key here (a different concern
# from the deploy key this test is regenerating -- GB_TEST_SSH_HOSTKEY is
# the far end's host identity, key_file is this router's own credential),
# same fixture shape t_cli_hostkey_show_accept_roundtrip already uses.
t_cli_test_forgets_old_key_on_success() {
	GB_ETC_DIR="$work/etc-kfo"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.key_file=$GB_ETC_DIR/id_ed25519" \
		'gitbackup.origin.url=git@example.com:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'

	cli keygen >/dev/null 2>&1
	_gb_fp=$(cli keygen --force 2>&1 | sed -n '1s/^confirm-required //p')
	cli keygen --force --confirm "$_gb_fp" >/dev/null 2>&1
	if [ -e "$GB_ETC_DIR/id_ed25519.old" ]; then
		ok 'the .old key exists right after a confirmed regeneration'
	else
		no 'the .old key exists right after a confirmed regeneration' 'missing'
	fi

	_gb_hk_key="$work/kfo-hostkey"
	rm -f "$_gb_hk_key" "$_gb_hk_key.pub"
	ssh-keygen -t ed25519 -N '' -f "$_gb_hk_key" >/dev/null
	GB_TEST_SSH_HOSTKEY="example.com $(cat "$_gb_hk_key.pub")"; export GB_TEST_SSH_HOSTKEY
	GB_TEST_GIT_RC=0; export GB_TEST_GIT_RC

	out=$(cli hostkey accept "$(cli hostkey show </dev/null 2>&1 | sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" </dev/null 2>&1)
	out=$(cli test </dev/null 2>&1)
	eq 'test now succeeds' '0' "$?"
	contains 'and reports success' 'reachable and authenticated' "$out"

	if [ -e "$GB_ETC_DIR/id_ed25519.old" ] || [ -e "$GB_ETC_DIR/id_ed25519.old.pub" ]; then
		no 'a successful test forgets the .old key' 'still present'
	else
		ok 'a successful test forgets the .old key'
	fi

	unset GB_TEST_SSH_HOSTKEY GB_TEST_GIT_RC GB_ETC_DIR
}

# gb_listener -- a background TCP listener on 127.0.0.1, on an OS-assigned
# free port, for `run` tests that need gb_have_net's real connect to
# succeed with no real git/HTTP protocol behind it. Sets GB_LISTENER_PID
# and GB_LISTENER_PORT (both empty when python3 is not installed, same
# skip-gracefully convention t_have_net's open-port case already uses --
# nc itself never needs the far end to accept(), only for the TCP
# handshake to complete, so a bare listen() is enough).
#
# Used to take the port as an argument (a caller-chosen literal, 18491 and
# 18492 respectively). A reviewer running `sh tests/run.sh` twice back to
# back with no wait between them hit two failures that a lone rerun did not
# reproduce -- two overlapping invocations both trying to bind the same
# fixed port. SO_REUSEADDR only forgives a socket's OWN prior TIME_WAIT
# state; it does nothing for a second, different process binding a port a
# first one is actively listening on. Binding port 0 (the OS picks an
# unused one) and reading it back via getsockname() removes the collision
# instead of shrinking its odds -- two invocations can no longer be handed
# the same port by construction. The port is written to a file only after
# listen() has already been called, so the file appearing is itself proof
# the socket is accepting, not just bound; the caller polls for that file
# instead of a fixed sleep, which only ever encoded "how long Python
# usually takes to start," not a guarantee.
#
# NOT `pid=$(gb_listener)`: a command substitution runs this function in a
# subshell, and the background job it starts dies the moment that subshell
# exits to produce the substitution's output -- confirmed live, `ps` on the
# "returned" PID immediately after shows it already gone. Caller kills it
# (`kill "$GB_LISTENER_PID"; wait "$GB_LISTENER_PID" 2>/dev/null`) once done.
gb_listener() {
	GB_LISTENER_PID=''
	GB_LISTENER_PORT=''
	command -v python3 >/dev/null 2>&1 || return 0
	_gl_port_file="$work/gb_listener_port.$$"
	rm -f "$_gl_port_file"
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
s.bind(('127.0.0.1', 0))
s.listen(5)
with open('$_gl_port_file', 'w') as f:
    f.write(str(s.getsockname()[1]))
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
	_gl_waited=0
	while [ ! -s "$_gl_port_file" ] && [ "$_gl_waited" -lt 50 ]; do
		sleep 0.1
		_gl_waited=$((_gl_waited + 1))
	done
	if [ -s "$_gl_port_file" ]; then
		GB_LISTENER_PORT=$(cat "$_gl_port_file")
	else
		# Never bound within 5s -- treat it the same as python3 missing
		# rather than hand the caller an empty port to connect to.
		kill "$GB_LISTENER_PID" 2>/dev/null
		wait "$GB_LISTENER_PID" 2>/dev/null
		GB_LISTENER_PID=''
	fi
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
	gb_listener
	_gl_pid="$GB_LISTENER_PID"
	if [ -z "$_gl_pid" ]; then
		skip 'cli: run -- not enough space in /tmp' \
			'python3 not found on PATH -- gb_listener needs it for a real listening socket'
		return 0
	fi
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.url=https://127.0.0.1:$GB_LISTENER_PORT/o/r.git" \
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

# t_run_scrub_pushes_no_archive -- the one configuration where the archive
# and the scrub cannot both be honoured. sysupgrade -b reads the LIVE
# filesystem, and its output lands inside the same $WORK tree gb_build_tree
# stages whole -- so before step 11a learned about GB_SCRUB, a scrubbed run
# still pushed a tarball containing every value it had just removed.
# visibility=public forces scrub on precisely because the repository is
# world-readable, which is exactly where that tarball did the most damage.
#
# Asserted on both sides of the seam: sysupgrade -b is never called at all
# (the stub logs each call), and the pushed commit has no backup.tar.gz in
# it. Same real-bare-repo machinery as the integration test above, one run.
t_run_scrub_pushes_no_archive() {
	gb_listener
	_gl_pid="$GB_LISTENER_PID"
	if [ -z "$_gl_pid" ]; then
		skip 'run: a scrubbing run pushes no backup.tar.gz' \
			'python3 not found on PATH -- gb_listener needs it for a real listening socket'
		return 0
	fi

	collect_fixture
	GB_DEVICE=rt1
	mkdir -p "$work/froot/etc/config"
	printf "config wifi-iface\n	option key 'hunter2'\n" >"$work/froot/etc/config/wireless"
	sysupgrade_list '/etc/config/wireless'
	printf "DISTRIB_RELEASE='25.12.4'\n" >"$work/froot/etc/openwrt_release"

	GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
	_gs_bare="$work/run-scrub-bare.git"
	rm -rf "$_gs_bare"
	git init --bare -q "$_gs_bare"

	GB_TEST_GIT_REMOTE_URL="https://127.0.0.1:$GB_LISTENER_PORT/o/r.git"; export GB_TEST_GIT_REMOTE_URL
	GB_TEST_GIT_REMOTE_PATH="$_gs_bare"; export GB_TEST_GIT_REMOTE_PATH
	GB_TEST_SYSUPGRADE_B_LOG="$work/sysupgrade-b-scrub.log"; export GB_TEST_SYSUPGRADE_B_LOG
	: >"$GB_TEST_SYSUPGRADE_B_LOG"

	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.url=$GB_TEST_GIT_REMOTE_URL" \
		'gitbackup.origin.acknowledged=1' 'gitbackup.main.archive=1' \
		'gitbackup.security.scrub=1'

	out=$(cli run 2>&1)
	eq 'the run itself still succeeds' '0' "$?"
	contains 'and says why no archive was pushed' 'no backup.tar.gz is pushed' "$out"

	_gs_calls=$(grep -c . "$GB_TEST_SYSUPGRADE_B_LOG")
	eq 'sysupgrade -b was never called' '0' "$_gs_calls"

	_gs_blob=$(git --git-dir="$_gs_bare" cat-file -p device/rt1:devices/rt1/backup.tar.gz 2>/dev/null)
	if [ -n "$_gs_blob" ]; then
		no 'and no backup.tar.gz reached the commit' 'it is there anyway'
	else
		ok 'and no backup.tar.gz reached the commit'
	fi

	kill "$_gl_pid" 2>/dev/null
	wait "$_gl_pid" 2>/dev/null
	unset GB_TEST_GIT_REAL GB_TEST_GIT_REMOTE_URL GB_TEST_GIT_REMOTE_PATH GB_TEST_SYSUPGRADE_B_LOG
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
	gb_listener
	_gl_pid="$GB_LISTENER_PID"
	if [ -z "$_gl_pid" ]; then
		skip 'run: integration on a real local bare repository (3 runs)' \
			'python3 not found on PATH -- gb_listener needs it for a real listening socket'
		return 0
	fi

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

	GB_TEST_GIT_REMOTE_URL="https://127.0.0.1:$GB_LISTENER_PORT/o/r.git"; export GB_TEST_GIT_REMOTE_URL
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

	# Ticket 22: the same recovery text has to be reachable two ways --
	# devices/<id>/RECOVERY.md (existing) and a README.md at the branch
	# ROOT (new), because GitHub only ever renders the root README when a
	# human opens a branch from a phone. One generator, one gb_card call --
	# byte-identical by construction, not two texts that could drift apart.
	_gt_recovery1=$(git --git-dir="$_gt_bare" cat-file -p device/rt1:devices/rt1/RECOVERY.md 2>/dev/null)
	_gt_readme1=$(git --git-dir="$_gt_bare" cat-file -p device/rt1:README.md 2>/dev/null)
	if [ -n "$_gt_recovery1" ]; then
		ok 'devices/rt1/RECOVERY.md is committed, as before'
	else
		no 'devices/rt1/RECOVERY.md is committed, as before' 'missing'
	fi
	eq 'README.md at the branch root is byte-identical to devices/rt1/RECOVERY.md' \
		"$_gt_recovery1" "$_gt_readme1"

	# Ticket 22, criterion 4: the very first backup of the very first
	# device also creates a "main" branch with a short index README --
	# one extra push, but only ONCE (main did not exist at all yet), never
	# on every run.
	_gt_main_log1=$(git --git-dir="$_gt_bare" log --oneline main 2>/dev/null)
	eq 'the first-ever run also creates a "main" branch (repo was otherwise empty)' \
		'1' "$(printf '%s\n' "$_gt_main_log1" | grep -c .)"
	_gt_main_readme1=$(git --git-dir="$_gt_bare" cat-file -p main:README.md 2>/dev/null)
	contains 'main'\''s README points at the per-device branches' 'device/' "$_gt_main_readme1"

	# --- run 2: nothing changed ---
	out2=$(cli run 2>&1)
	eq 'run 2 exits 0' '0' "$?"
	contains 'and reports no changes, not a second push' 'no changes' "$out2"

	_gt_count2=$(git --git-dir="$_gt_bare" log --oneline device/rt1 | grep -c .)
	eq 'run 2 adds no commit -- idempotence' "$_gt_count1" "$_gt_count2"
	_gt_barchive_calls2=$(grep -c . "$GB_TEST_SYSUPGRADE_B_LOG")
	eq 'and sysupgrade -b was NOT called again -- the archive is not rebuilt when unchanged' \
		"$_gt_barchive_calls1" "$_gt_barchive_calls2"
	_gt_main_log2=$(git --git-dir="$_gt_bare" log --oneline main 2>/dev/null)
	eq 'run 2 (no changes at all) does not push "main" again' \
		'1' "$(printf '%s\n' "$_gt_main_log2" | grep -c .)"

	# --- run 3: a chmod-only edit git itself would never see ---
	chmod 0644 "$work/froot/etc/config/network"
	out3=$(cli run 2>&1)
	eq 'run 3 exits 0' '0' "$?"
	contains 'and reports a new push -- manifest caught the chmod' 'pushed' "$out3"

	# Ticket 18: there used to be a third assertion here too, checking
	# `git ls-tree` for mode 100644 on the just-chmodded file. It read as
	# proof the permission-change detector (gb_manifest_equal, comparing
	# manifest.json's own "mode" field) fired -- but git stores only the
	# executable bit, and this file has none in either 0600 or 0644, so
	# `ls-tree` would print 100644 whether or not the detector noticed
	# anything at all: a chmod-only edit that gb_manifest_equal wrongly
	# called "unchanged" would still leave a 100644 blob mode sitting
	# there from run 1, an assertion green by construction, not by
	# detection. The two checks right above it -- "reports a new push"
	# and "adds exactly one more commit" -- are the ones that actually
	# depend on the chmod having been caught: break gb_manifest_equal's
	# own mode comparison and run 3 answers "no changes" with no new
	# commit, which is exactly what a mutation test (temporarily making
	# gb_collect always write mode "644") turns red here. Confirmed
	# during ticket 18's own work and reverted immediately after.
	_gt_count3=$(git --git-dir="$_gt_bare" log --oneline device/rt1 | grep -c .)
	eq 'run 3 adds exactly one more commit' '2' "$_gt_count3"
	_gt_barchive_calls3=$(grep -c . "$GB_TEST_SYSUPGRADE_B_LOG")
	if [ "$_gt_barchive_calls3" -gt "$_gt_barchive_calls2" ]; then
		ok 'and the archive IS rebuilt on this real change'
	else
		no 'and the archive IS rebuilt on this real change' "call count stayed at $_gt_barchive_calls3"
	fi
	_gt_readme3=$(git --git-dir="$_gt_bare" cat-file -p device/rt1:README.md 2>/dev/null)
	_gt_recovery3=$(git --git-dir="$_gt_bare" cat-file -p device/rt1:devices/rt1/RECOVERY.md 2>/dev/null)
	eq 'run 3'\''s branch-root README.md is still byte-identical to its own RECOVERY.md' \
		"$_gt_recovery3" "$_gt_readme3"
	_gt_main_log3=$(git --git-dir="$_gt_bare" log --oneline main 2>/dev/null)
	eq 'run 3 (device/rt1 already existed) does not push "main" again either' \
		'1' "$(printf '%s\n' "$_gt_main_log3" | grep -c .)"

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
# cli: collect, paths, card, diff (ticket 17)
# --------------------------------------------------------------------------

# t_cli_collect -- a thin wrapper over gb_collect, already proven correct
# by collect.sh's own test section above; this only has to prove the CLI
# actually reaches it and writes to the directory named on the command
# line, and refuses without one (spec/ticket 17: "collect --out DIR --
# обёртка над готовым gb_collect").
t_cli_collect() {
	collect_fixture
	mkdir -p "$work/froot/etc/config"
	printf 'config interface lan\n' >"$work/froot/etc/config/network"
	sysupgrade_list '/etc/config/network'
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git'

	out=$(cli collect --out "$work/cli-collect-out" 2>&1)
	eq 'collect --out DIR exits 0' '0' "$?"
	contains 'and reports where it wrote' "$work/cli-collect-out" "$out"
	eq 'and a manifest.json actually exists there' '1' \
		"$([ -r "$work/cli-collect-out/manifest.json" ] && echo 1 || echo 0)"
	contains 'and the file itself was copied into files/' 'config interface lan' \
		"$(cat "$work/cli-collect-out/files/etc/config/network" 2>/dev/null)"

	out=$(cli collect 2>&1)
	eq 'collect with no --out is refused, exit 2' '2' "$?"
}

# t_cli_card -- a thin wrapper over gb_card (card.sh, ticket 09), already
# proven correct by card.sh's own test section below; this only has to
# prove the CLI writes gb_card's output to the named file and refuses
# without one.
t_cli_card() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git'

	out=$(cli card --out "$work/cli-card-out.md" 2>&1)
	eq 'card --out FILE exits 0' '0' "$?"
	contains 'and reports where it wrote' "$work/cli-card-out.md" "$out"
	_gb_card_text=$(cat "$work/cli-card-out.md" 2>/dev/null)
	contains 'the card names the device' 'rt1' "$_gb_card_text"
	contains 'and is gb_card'\''s own document, not a stub' 'gitbackup recovery card' "$_gb_card_text"

	out=$(cli card 2>&1)
	eq 'card with no --out is refused, exit 2' '2' "$?"
}

# t_cli_paths_list_add_del -- ticket 17's own acceptance criteria for
# `paths`: works with no remote configured at all (unlike collect/diff/
# card above, `paths` is NOT gated by gb_validate_config -- see cmd_paths's
# own header comment), list prints the real file plus a size line, add/del
# actually edit /etc/sysupgrade.conf, and the blacklist/space/missing-path
# refusals every carry a reason and the right exit code.
t_cli_paths_list_add_del() {
	rm -rf "$work/cli-paths-root"
	mkdir -p "$work/cli-paths-root/etc/config"
	: >"$work/cli-paths-root/etc/config/dhcp"
	GB_ROOT="$work/cli-paths-root"; export GB_ROOT
	GB_SYSUPGRADE_CONF="$work/cli-sysupgrade.conf"; export GB_SYSUPGRADE_CONF
	rm -f "$GB_SYSUPGRADE_CONF"
	GB_TEST_SYSUPGRADE_L="$work/cli-sysupgrade-l"; export GB_TEST_SYSUPGRADE_L
	: >"$GB_TEST_SYSUPGRADE_L"
	fixture

	out=$(cli paths add /etc/config/dhcp 2>&1)
	eq 'paths add on a fresh install (no origin.url at all) exits 0' '0' "$?"
	contains 'and confirms' 'added /etc/config/dhcp' "$out"

	out=$(cli paths list 2>&1)
	contains 'paths list prints the file content' '/etc/config/dhcp' "$out"
	contains 'and a total-size line for the UI'\''s 2 MB warning' 'total:' "$out"

	out=$(cli paths add /proc/cpuinfo 2>&1)
	eq 'paths add on the fixed blacklist exits 4' '4' "$?"
	contains 'with an explanation, not silently' 'not a real filesystem path' "$out"

	out=$(cli paths add '/etc/config/has space' 2>&1)
	eq 'paths add with a space in the path exits 2 (sysupgrade cannot support it)' '2' "$?"

	out=$(cli paths add /etc/config/does-not-exist 2>&1)
	eq 'paths add for a nonexistent path exits 2' '2' "$?"

	out=$(cli paths del /etc/config/dhcp 2>&1)
	eq 'paths del exits 0' '0' "$?"
	out=$(cli paths list 2>&1)
	case "$out" in
		*'/etc/config/dhcp'*) no 'the path is actually gone from sysupgrade.conf, not just reported removed' "still present: [$out]" ;;
		*) ok 'the path is actually gone from sysupgrade.conf, not just reported removed' ;;
	esac

	unset GB_ROOT GB_SYSUPGRADE_CONF GB_TEST_SYSUPGRADE_L
}

# t_cli_paths_list_json_entries -- ticket 26's own repro: `paths list
# --json` against a stock, untouched /etc/sysupgrade.conf must report an
# empty "entries" array (nothing here is a real, removable path) while
# "paths" keeps the four raw comment lines exactly as ticket 26's bug
# report captured them -- the JSON shape gbrpc_list_paths forwards
# verbatim to the LuCI view.
t_cli_paths_list_json_entries() {
	rm -rf "$work/cli-paths-json-root"
	mkdir -p "$work/cli-paths-json-root/etc/config"
	GB_ROOT="$work/cli-paths-json-root"; export GB_ROOT
	GB_SYSUPGRADE_CONF="$work/cli-paths-json-sysupgrade.conf"; export GB_SYSUPGRADE_CONF
	GB_TEST_SYSUPGRADE_L="$work/cli-paths-json-sysupgrade-l"; export GB_TEST_SYSUPGRADE_L

	printf '## This file contains files and directories that should\n## be preserved during an upgrade.\n# /etc/example.conf\n# /etc/openvpn/\n' >"$GB_SYSUPGRADE_CONF"
	: >"$GB_TEST_SYSUPGRADE_L"

	out=$(cli paths list --json 2>&1)
	assert_json 'paths list --json is valid JSON' "$out"
	contains 'raw "paths" still carries the four comment lines' \
		'## This file contains files and directories that should' "$out"
	contains '"entries" field itself is present and empty -- none of the four lines is a real path' \
		'"entries": []' "$out"

	rm -f "$GB_SYSUPGRADE_CONF"
	printf '/etc/config/dhcp\n' >"$GB_SYSUPGRADE_CONF"
	: >"$work/cli-paths-json-root/etc/config/dhcp"
	out=$(cli paths list --json 2>&1)
	contains 'a genuine entry does show up in "entries"' '"entries": ["/etc/config/dhcp"]' "$out"

	unset GB_ROOT GB_SYSUPGRADE_CONF GB_TEST_SYSUPGRADE_L
}

# t_cli_paths_audit -- ticket 21's `paths audit`, moved verbatim out of the
# rpcd plugin's own gbrpc_audit_paths (never tested there at all -- this is
# the first test either version of this logic has ever had). /overlay/upper
# is faked under GB_ROOT the same way collect_fixture fakes the rest of the
# filesystem; a path already named by sysupgrade -l is not "changed and
# unbacked", and this package's own secrets directory is hard-excluded
# regardless of what sysupgrade -l says.
t_cli_paths_audit() {
	rm -rf "$work/cli-audit-root"
	mkdir -p "$work/cli-audit-root/overlay/upper/etc/config" "$work/cli-audit-root/overlay/upper/root"
	: >"$work/cli-audit-root/overlay/upper/etc/config/network"
	: >"$work/cli-audit-root/overlay/upper/root/notes.txt"
	mkdir -p "$work/cli-audit-root/overlay/upper/etc/gitbackup"
	: >"$work/cli-audit-root/overlay/upper/etc/gitbackup/token"
	GB_ROOT="$work/cli-audit-root"; export GB_ROOT
	GB_TEST_SYSUPGRADE_L="$work/cli-audit-sysupgrade-l"; export GB_TEST_SYSUPGRADE_L
	printf '/etc/config/network\n' >"$GB_TEST_SYSUPGRADE_L"

	out=$(cli paths audit 2>&1)
	eq 'paths audit exits 0' '0' "$?"
	assert_json 'paths audit is valid JSON' "$out"
	case "$out" in
		*'/etc/config/network'*) no 'a path sysupgrade -l already covers is not reported' "found in [$out]" ;;
		*) ok 'a path sysupgrade -l already covers is not reported' ;;
	esac
	contains 'a changed-but-not-backed-up path is reported' '/root/notes.txt' "$out"
	case "$out" in
		*'/etc/gitbackup'*) no 'this package'\''s own secrets directory is never reported' "found in [$out]" ;;
		*) ok 'this package'\''s own secrets directory is never reported' ;;
	esac

	unset GB_ROOT GB_TEST_SYSUPGRADE_L
}

# t_cli_history_rejects_bad_url -- ticket 21 (R109/D07): `gitbackup
# history` now runs GB_URL through gb_parse_url before ever touching git,
# same as cmd_test/cmd_run already did -- unlike the rpcd plugin's own
# former _gb_rpc_resolve_remote, which took gitbackup.origin.url straight
# out of UCI with no shape check at all (this ticket's own headline
# finding). Checked at the CLI level, not only through rpcd, because the
# CLI is the one place this check now actually lives.
t_cli_history_rejects_bad_url() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=/not/a/real/remote/url'
	out=$(cli history 2>&1)
	eq 'history refuses a URL gb_parse_url does not recognize, exit 2' '2' "$?"
	contains 'and explains why' 'does not match any supported remote URL form' "$out"
}

# t_cli_diff_two_arg_rejects_bad_sha -- ticket 21's own explicit acceptance
# criterion: an argument shaped like an option (leading '-') is rejected
# by shape, before it can ever reach `git diff` as a bare argument.
t_cli_diff_two_arg_rejects_bad_sha() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git'

	out=$(cli diff '-upload-pack=touch /tmp/pwned' 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' 2>&1)
	eq 'diff refuses a "from" that is not a full 40-hex sha, exit 2' '2' "$?"
	contains 'and names the offending value' "'-upload-pack=touch /tmp/pwned'" "$out"
	eq 'and no such file was ever created' '0' "$([ -e /tmp/pwned ] && echo 1 || echo 0)"

	out=$(cli diff 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' 'tooshort' 2>&1)
	eq 'diff refuses a "to" that is too short to be a real sha, exit 2' '2' "$?"

	out=$(cli diff onlyonearg 2>&1)
	eq 'diff with exactly one argument is refused, exit 2' '2' "$?"
}

# t_cli_restore_rejects_bad_commit_and_bad_url -- ticket 21: cmd_restore
# used to hand GB_URL straight to gb_restore's own git ls-remote/fetch/
# checkout with no gb_parse_url check at all (unlike cmd_test/cmd_run), and
# --commit was forwarded with no shape check beyond what the caller typed
# -- restore.sh's own git checkout/cat-file calls would have taken it as a
# bare argument. Both are now refused by shape before gb_restore ever runs.
t_cli_restore_rejects_bad_commit_and_bad_url() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git'
	out=$(cli restore --device rt1 --commit '-x' --yes 2>&1)
	eq 'restore refuses a --commit that is not a full 40-hex sha or HEAD/empty, exit 2' '2' "$?"
	contains 'and names the offending value' "'-x'" "$out"

	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=/not/a/real/remote/url'
	out=$(cli restore --device rt1 --yes 2>&1)
	eq 'restore refuses a URL gb_parse_url does not recognize, exit 2' '2' "$?"
	contains 'and explains why' 'does not match any supported remote URL form' "$out"
}

# diff_seed_push <bare-repo> <branch> <tree-dir> -- commits <tree-dir>'s
# own content under devices/rt1/ as the sole commit on <branch>, with
# plain git (fixture setup, not the code under test -- same reasoning
# restore_seed_push's own header comment already gives). <tree-dir> is
# expected to be gb_collect's own real output, never a hand-typed
# manifest -- cmd_diff's field-by-field comparison has to be checked
# against exactly what collect.sh actually writes.
diff_seed_push() {
	_dsp_bare="$1"
	_dsp_branch="$2"
	_dsp_tree="$3"
	rm -rf "$work/diff-seed-co"
	git init -q "$work/diff-seed-co"
	mkdir -p "$work/diff-seed-co/devices/rt1"
	cp -R "$_dsp_tree/." "$work/diff-seed-co/devices/rt1/"
	git -C "$work/diff-seed-co" -c user.name=t -c user.email=t@t.test add -A >/dev/null 2>&1
	git -C "$work/diff-seed-co" -c user.name=t -c user.email=t@t.test commit -q -m seed >/dev/null 2>&1
	git -C "$work/diff-seed-co" push -q "$_dsp_bare" "HEAD:refs/heads/$_dsp_branch" >/dev/null 2>&1
}

# diff_setup -- collect_fixture's own fake router filesystem plus a fresh
# real local bare repository. Ticket 21: cmd_diff now runs GB_URL through
# gb_parse_url before ever touching git (R109/D07, "URL... на каждом пути"
# -- this command used to skip that check, unlike cmd_run/cmd_test's own
# gb_parse_url/gb_visibility_ok), so a plain filesystem path no longer
# passes as gitbackup.origin.url here -- GB_TEST_GIT_REMOTE_URL/PATH (the
# git stub, GB_TEST_GIT_REAL=1) swaps a schema-valid https://... for the
# real local bare-repo path the moment git itself is invoked, same
# mechanism t_run_integration_bare_repo already relies on. Sets $_diff_bare
# for the calling test.
diff_setup() {
	collect_fixture
	GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
	_diff_bare="$work/diff-bare.git"
	rm -rf "$_diff_bare"
	git init --bare -q "$_diff_bare"
	GB_TEST_GIT_REMOTE_URL="https://example.org/o/r.git"; export GB_TEST_GIT_REMOTE_URL
	GB_TEST_GIT_REMOTE_PATH="$_diff_bare"; export GB_TEST_GIT_REMOTE_PATH
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.url=$GB_TEST_GIT_REMOTE_URL" 'gitbackup.origin.branch=device/{device}' \
		'gitbackup.main.path_prefix=devices/{device}'
}

diff_teardown() {
	unset GB_TEST_GIT_REAL GB_TEST_GIT_REMOTE_URL GB_TEST_GIT_REMOTE_PATH
}

# t_cli_diff_no_prior_backup -- the branch does not exist yet (first-ever
# backup): everything currently collected reads as new, not an error.
t_cli_diff_no_prior_backup() {
	diff_setup
	mkdir -p "$work/froot/etc/config"
	printf 'config interface lan\n' >"$work/froot/etc/config/network"
	sysupgrade_list '/etc/config/network'

	out=$(cli diff 2>&1)
	eq 'diff with no backup pushed yet exits 0' '0' "$?"
	contains 'and reports the current config as entirely new' '+ /etc/config/network (file)' "$out"

	diff_teardown
}

# t_cli_diff_unchanged_is_empty -- ticket 17's own acceptance criterion:
# "diff на неизменившейся системе печатает пустой результат и выходит 0".
t_cli_diff_unchanged_is_empty() {
	diff_setup
	mkdir -p "$work/froot/etc/config"
	printf 'config interface lan\n' >"$work/froot/etc/config/network"
	chmod 0644 "$work/froot/etc/config/network"
	sysupgrade_list '/etc/config/network'

	(
		. "$share/lib.sh"; . "$share/device.sh"; . "$share/collect.sh"
		GB_DEVICE=rt1
		gb_collect "$work/diff-seed-tree"
	)
	diff_seed_push "$_diff_bare" device/rt1 "$work/diff-seed-tree"

	out=$(cli diff 2>&1)
	eq 'diff on an unchanged system exits 0' '0' "$?"
	eq 'and prints nothing at all' '' "$out"

	diff_teardown
}

# t_cli_diff_catches_permission_and_membership_changes -- ticket 17's own
# headline acceptance criterion (D03): a chmod-only edit is invisible to
# git (same blob, same tree entry mode class -- 100644 either way) but
# MUST show up here, because the source of truth is manifest.json's own
# mode field, never `git status`/a checkout. Bundled with an added and a
# removed file in the same run so all three shapes (`+`/`-`/`~`) are
# proven against one real backup-set comparison instead of three
# redundant fixtures.
t_cli_diff_catches_permission_and_membership_changes() {
	diff_setup
	mkdir -p "$work/froot/etc/config"
	printf 'config interface lan\n' >"$work/froot/etc/config/network"
	chmod 0644 "$work/froot/etc/config/network"
	printf 'config dhcp lan\n' >"$work/froot/etc/config/dhcp"
	chmod 0644 "$work/froot/etc/config/dhcp"
	sysupgrade_list '/etc/config/network' '/etc/config/dhcp'

	(
		. "$share/lib.sh"; . "$share/device.sh"; . "$share/collect.sh"
		GB_DEVICE=rt1
		gb_collect "$work/diff-seed-tree"
	)
	diff_seed_push "$_diff_bare" device/rt1 "$work/diff-seed-tree"

	# Now: chmod network (git-invisible), remove dhcp, add wireless.
	chmod 0600 "$work/froot/etc/config/network"
	rm -f "$work/froot/etc/config/dhcp"
	printf 'config wifi-device radio0\n' >"$work/froot/etc/config/wireless"
	sysupgrade_list '/etc/config/network' '/etc/config/wireless'

	out=$(cli diff 2>&1)
	eq 'diff exits 0 even though real differences were found' '0' "$?"
	contains 'a chmod-only edit git itself never sees is caught via the manifest'\''s own mode field' \
		'mode 644->600' "$out"
	contains 'a removed path is reported' '- /etc/config/dhcp (file)' "$out"
	contains 'an added path is reported' '+ /etc/config/wireless (file)' "$out"

	diff_teardown
}

# t_rpcd_config_diff_unchanged -- the new read-tier method (config_diff)
# answers "has the live config drifted from the last commit", which the
# existing rpcd `diff` (two already-committed shas, ticket 14/R124) cannot:
# it wraps `gitbackup diff` (ticket 17), which compares the CURRENT
# manifest against the last pushed one, not `git status`/`git diff`. An
# unchanged system must answer differs: false.
t_rpcd_config_diff_unchanged() {
	diff_setup
	mkdir -p "$work/froot/etc/config"
	printf 'config interface lan\n' >"$work/froot/etc/config/network"
	chmod 0644 "$work/froot/etc/config/network"
	sysupgrade_list '/etc/config/network'

	(
		. "$share/lib.sh"; . "$share/device.sh"; . "$share/collect.sh"
		GB_DEVICE=rt1
		gb_collect "$work/diff-seed-tree"
	)
	diff_seed_push "$_diff_bare" device/rt1 "$work/diff-seed-tree"

	out=$(rpcd_call config_diff)
	assert_json 'config_diff (unchanged) is valid JSON' "$out"
	contains 'an unchanged system answers differs: false' '"differs": false' "$out"

	diff_teardown
}

# t_rpcd_config_diff_catches_chmod -- D03's own headline case, reachable
# through rpcd: a chmod-only edit is invisible to `git diff` (same blob,
# same tree entry mode class -- 100644 either way) but MUST flip differs
# to true, because the source of truth is manifest.json's own mode field,
# never git. This is exactly the case the overview indicator has to catch
# that a git-status-based check never could.
t_rpcd_config_diff_catches_chmod() {
	diff_setup
	mkdir -p "$work/froot/etc/config"
	printf 'config interface lan\n' >"$work/froot/etc/config/network"
	chmod 0644 "$work/froot/etc/config/network"
	sysupgrade_list '/etc/config/network'

	(
		. "$share/lib.sh"; . "$share/device.sh"; . "$share/collect.sh"
		GB_DEVICE=rt1
		gb_collect "$work/diff-seed-tree"
	)
	diff_seed_push "$_diff_bare" device/rt1 "$work/diff-seed-tree"

	chmod 0600 "$work/froot/etc/config/network"

	out=$(rpcd_call config_diff)
	assert_json 'config_diff (chmod-only) is valid JSON' "$out"
	contains 'a chmod git cannot see still flips differs to true' '"differs": true' "$out"
	contains 'and the text names the mode change' 'mode 644->600' "$out"

	diff_teardown
}

# t_rpcd_config_diff_unreachable_remote -- gb_die exits nonzero (gitbackup's
# own exit codes 2/3 for config/network failures); config_diff must turn
# that into a { "reason": ... } object like every other rpcd method here,
# never a bare nonzero exit rpcd would otherwise turn into an empty body --
# this is what lets the overview indicator say "could not verify" instead
# of silently defaulting to "all saved".
t_rpcd_config_diff_unreachable_remote() {
	fixture 'gitbackup.origin.url='
	out=$(rpcd_call config_diff)
	assert_json 'config_diff with no remote configured is still valid JSON' "$out"
	contains 'and explains why, via "reason"' '"reason"' "$out"
}

# --------------------------------------------------------------------------
# card.sh (ticket 09, spec "Recovery card и RECOVERY.md")
# --------------------------------------------------------------------------

# t_card_https_token_flag -- an https:// remote's card recommends --token,
# not --ssh-key: the two auth flags are mutually meaningful by scheme, and
# handing an operator the wrong one is a dead end read from an offline card
# with no LuCI available to correct it.
t_card_https_token_flag() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/card.sh"
		GB_DEVICE=rt1
		GB_URL='https://github.com/acme/routers'
		out="$work/card-https.md"
		gb_card "$out"
		eq 'gb_card returns 0' '0' "$?"
		body=$(cat "$out")
		contains 'the one-liner carries --repo with the configured URL' '--repo https://github.com/acme/routers' "$body"
		contains 'and --device with the resolved device id' '--device rt1' "$body"
		contains 'an https remote is told to bring --token' '--token' "$body"
		case "$body" in
			*'--ssh-key'*) no 'and NOT --ssh-key for an https remote' "$body" ;;
			*) ok 'and NOT --ssh-key for an https remote' ;;
		esac
		contains 'links to the repository'\''s own web UI' 'https://github.com/acme/routers' "$body"
		contains 'names Path 0 for when bootstrap.sh cannot run' 'sysupgrade -r' "$body"
	)
}

# t_card_ssh_key_flag -- the scp-like/ssh form gets --ssh-key instead, and
# its web link is coerced to https (same reasoning as gb_deeplink: a browser
# can never open an ssh:// URL).
t_card_ssh_key_flag() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/card.sh"
		GB_DEVICE=rt2
		GB_URL='git@gitlab.example.com:acme/routers.git'
		out="$work/card-ssh.md"
		gb_card "$out"
		body=$(cat "$out")
		contains 'an ssh remote is told to bring --ssh-key' '--ssh-key' "$body"
		case "$body" in
			*'--token <TOKEN>'*) no 'and NOT --token for an ssh remote' "$body" ;;
			*) ok 'and NOT --token for an ssh remote' ;;
		esac
		contains 'the web link is coerced to https, never ssh' 'https://gitlab.example.com/acme/routers' "$body"
	)
}

# t_card_no_secret -- the card is built from GB_URL/GB_DEVICE alone; neither
# gb_card nor its output ever touches, nor could ever repeat, the deploy
# key's private half or the PAT sitting on disk. A marker planted in the
# very files gb_git_env points at proves that content never gets read into
# the card by any accidental `cat`.
t_card_no_secret() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/card.sh"
		GB_DEVICE=rt1
		GB_URL='https://github.com/acme/routers'
		GB_ETC_DIR="$work/card-secret-etc"
		mkdir -p "$GB_ETC_DIR"
		printf 'ghp_supersecrettoken\n' >"$GB_ETC_DIR/token"
		printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nsupersecretkeymaterial\n-----END OPENSSH PRIVATE KEY-----\n' >"$GB_ETC_DIR/id_ed25519"
		out="$work/card-secret.md"
		gb_card "$out"
		body=$(cat "$out")
		case "$body" in
			*'ghp_supersecrettoken'*) no 'the token value never appears in the card' "$body" ;;
			*) ok 'the token value never appears in the card' ;;
		esac
		case "$body" in
			*'supersecretkeymaterial'*) no 'the deploy key'\''s private half never appears in the card' "$body" ;;
			*) ok 'the deploy key'\''s private half never appears in the card' ;;
		esac
	)
}

# t_card_path0_matches_what_run_actually_pushes -- the recovery card is
# read once, by someone whose router is already down, so a step on it that
# cannot work is worse than an absent step. `run` writes backup.tar.gz only
# when main.archive is on AND the run does not scrub (usr/sbin/gitbackup
# step 11a), and the card has to describe that same router, not the general
# case. GB_SCRUB is read, not gitbackup.security.scrub: visibility=public
# forces scrub on over whatever that option says.
t_card_path0_matches_what_run_actually_pushes() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/card.sh"
		GB_DEVICE=rt1
		GB_URL='https://github.com/acme/routers'

		fixture 'gitbackup.main.archive=1'
		GB_SCRUB=0; export GB_SCRUB
		gb_card "$work/card-archive-on.md"
		contains 'with an archive being pushed, Path 0 points at it' \
			'backup.tar.gz' "$(cat "$work/card-archive-on.md")"

		GB_SCRUB=1; export GB_SCRUB
		gb_card "$work/card-scrubbed.md"
		_ct_body=$(cat "$work/card-scrubbed.md")
		case "$_ct_body" in
			*'download'*'backup.tar.gz'*)
				no 'a scrubbing router never sends the reader after an archive it does not push' "$_ct_body" ;;
			*) ok 'a scrubbing router never sends the reader after an archive it does not push' ;;
		esac
		contains 'and says why that path is unavailable' 'scrubbing is on' "$_ct_body"

		GB_SCRUB=0; export GB_SCRUB
		fixture 'gitbackup.main.archive=0'
		gb_card "$work/card-archive-off.md"
		contains 'archive=0 gets its own reason, not the scrub one' \
			'archive` is off' "$(cat "$work/card-archive-off.md")"

		unset GB_SCRUB
	)
}

# t_card_never_dies -- gb_card is called from the middle of a real backup
# run (usr/sbin/gitbackup: `gb_card ... 2>/dev/null`), in the SAME process
# as the run it rides along with. gb_die calls exit, so if gb_card ever hit
# one on a malformed or missing GB_URL, a cosmetic recovery-document bug
# would silently abort the actual backup. It must degrade to a shorter card
# and return 0 instead, for both a garbage URL and no URL/device at all.
t_card_never_dies() {
	(
		. "$share/lib.sh"; . "$share/remoteurl.sh"; . "$share/card.sh"
		GB_DEVICE=''
		GB_URL='not a valid remote url'
		out="$work/card-garbage.md"
		gb_card "$out"
		eq 'a malformed GB_URL still returns 0, never gb_die'\''s exit' '0' "$?"
		eq 'and still produces a non-empty file' '1' "$([ -s "$out" ] && echo 1 || echo 0)"

		unset GB_DEVICE GB_URL
		out2="$work/card-empty.md"
		gb_card "$out2"
		eq 'no GB_URL/GB_DEVICE at all still returns 0' '0' "$?"
		eq 'and still produces a non-empty file' '1' "$([ -s "$out2" ] && echo 1 || echo 0)"
	)
}

# --------------------------------------------------------------------------
# rpcd (ticket 10, spec "rpcd и ACL")
# --------------------------------------------------------------------------

# rpcd <argv...> -- invokes the plugin the same way rpcd(8) itself does
# (argv, plus one line of JSON on stdin for "call"), pointed at this
# checkout's own tree/state dir/CLI, same override seam `cli()` above
# already uses.
rpcd() {
	GB_SHARE="$share" GB_STATE_DIR="$work/rpcd-state" GB_BIN="$files/usr/sbin/gitbackup" \
		GB_LOCK_FILE="$work/rpcd-gitbackup.lock" GB_SYSUPGRADE_CONF="${GB_TEST_SYSUPGRADE_CONF:-$work/rpcd-sysupgrade.conf}" \
		sh "$files/usr/libexec/rpcd/luci.gitbackup" "$@"
}

# rpcd_call <method> [<json-params>] -- <json-params> defaults to "{}",
# matching a real ubus call with no arguments.
rpcd_call() {
	printf '%s\n' "${2:-\{\}}" | rpcd call "$1"
}

# assert_json <name> <json> -- ticket 28: used to pass silently (no
# assertion recorded at all) when python3 is not on PATH; now records a
# visible, counted skip instead, same "skip rather than fake a result"
# tradeoff t_cli_status_json already established, just printed.
assert_json() {
	if ! command -v python3 >/dev/null 2>&1; then
		skip "$1" 'python3 not found on PATH'
		return 0
	fi
	if printf '%s' "$2" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
		ok "$1"
	else
		no "$1" "not valid JSON: [$2]"
	fi
}

# t_rpcd_acl_read_tier_returns_no_file_content -- the read tier is split
# from the write tier on "may see the router's secrets", not on "changes
# something". `diff` changes nothing at all, and still belongs in write:
# what it returns is `git diff` between two commits of the backup branch,
# i.e. the CONTENT of the backed-up files, and at the shipped default
# (visibility=private, security.scrub='0') that content is unscrubbed --
# /etc/shadow's root hash, the dropbear host keys, the WPA PSKs. Every
# method left in read answers "is the backup healthy" without handing over
# a file's bytes: status/log/history are metadata, and config_diff compares
# manifests (paths, modes, hashes), never content.
#
# Parsed per tier here, unlike t_rpcd_acl_matches_plugin above, which
# deliberately unions both tiers to compare the ACL against the dispatcher.
t_rpcd_acl_read_tier_returns_no_file_content() {
	acl="$root/applications/luci-app-gitbackup/root/usr/share/rpcd/acl.d/luci-app-gitbackup.json"
	[ -r "$acl" ] || { no 'acl.d file exists' "missing: $acl"; return; }

	# Everything between "read": and "write": -- the read tier's own block.
	read_tier=$(awk '/"read":/ { grab=1 } /"write":/ { grab=0 } grab' "$acl" |
		sed -n 's/^[[:space:]]*"\([a-z_][a-z_]*\)".*/\1/p' | sort -u)
	write_tier=$(awk '/"write":/ { grab=1 } grab' "$acl" |
		sed -n 's/^[[:space:]]*"\([a-z_][a-z_]*\)".*/\1/p' | sort -u)

	[ -n "$read_tier" ] || { no 'the read tier parser found at least one method' 'found none -- the parser itself is broken'; return; }
	[ -n "$write_tier" ] || { no 'the write tier parser found at least one method' 'found none -- the parser itself is broken'; return; }

	read_hay=" $(printf '%s' "$read_tier" | tr '\n' ' ') "
	write_hay=" $(printf '%s' "$write_tier" | tr '\n' ' ') "

	case "$read_hay" in
		*' diff '*) no 'diff is not in the read tier -- it returns raw backed-up file content' "read tier: $read_hay" ;;
		*) ok 'diff is not in the read tier -- it returns raw backed-up file content' ;;
	esac
	case "$write_hay" in
		*' diff '*) ok 'diff is in the write tier instead' ;;
		*) no 'diff is in the write tier instead' "write tier: $write_hay" ;;
	esac
	for m in status log history config_diff; do
		case "$read_hay" in
			*" $m "*) ok "the metadata-only method $m stays readable" ;;
			*) no "the metadata-only method $m stays readable" "read tier: $read_hay" ;;
		esac
	done
}

# t_rpcd_acl_matches_plugin -- the ticket's own explicit acceptance
# criterion: "каждый метод из ACL существует в плагине, и каждый метод
# плагина объявлен в ACL -- проверено скриптом, а не глазами". Checked in
# three independent directions (ACL <-> dispatcher, dispatcher <-> "list")
# so a method added to only one of the three places -- exactly the failure
# mode that would leave a button quietly returning "Access denied" to every
# non-root user, per this ticket's own brief -- fails loud here instead.
t_rpcd_acl_matches_plugin() {
	plugin="$files/usr/libexec/rpcd/luci.gitbackup"
	acl="$root/applications/luci-app-gitbackup/root/usr/share/rpcd/acl.d/luci-app-gitbackup.json"

	[ -r "$acl" ] || { no 'acl.d file exists' "missing: $acl"; return; }

	# Each *_methods variable is newline-joined (sort -u's own output) --
	# fine for `for x in $var` word-splitting below, but a substring check
	# needs a SPACE-joined haystack (same "tr '\n' ' '" this file's own
	# t_config_sections_match_code already relies on for exactly this
	# reason) -- a `case " $haystack " in *" $needle "*)` against a
	# newline-joined string never matches at all, since no needle is ever
	# preceded/followed by a literal space in it, only by a newline.
	acl_methods=$(awk '
		/"luci\.gitbackup":/ { grab=1; next }
		grab && /\]/ { grab=0; next }
		grab { print }
	' "$acl" | sed -n 's/.*"\([a-zA-Z_]*\)".*/\1/p' | sort -u)
	case_methods=$(sed -n 's/^\t\t\t\([a-z_][a-z_]*\)) .*/\1/p' "$plugin" | sort -u)
	list_methods=$(sed -n 's/^\t"\([a-z_]*\)":.*/\1/p' "$plugin" | sort -u)

	[ -n "$acl_methods" ] || { no 'the ACL parser found at least one method' 'found none -- the parser itself is broken'; return; }
	[ -n "$case_methods" ] || { no 'the dispatcher parser found at least one method' 'found none -- the parser itself is broken'; return; }

	# Trailing space added explicitly on the outside of each command
	# substitution, not just via tr's own newline-to-space conversion:
	# $(...) strips every trailing newline before `tr` ever sees it, so
	# the LAST (alphabetically, after sort -u) method in each list would
	# otherwise come out with no trailing space at all and never match its
	# own " name " substring pattern below -- found by this exact test
	# failing on "validate_cron" and nothing else, the one entry sort -u
	# always puts last.
	acl_hay=" $(printf '%s' "$acl_methods" | tr '\n' ' ') "
	case_hay=" $(printf '%s' "$case_methods" | tr '\n' ' ') "
	list_hay=" $(printf '%s' "$list_methods" | tr '\n' ' ') "

	missing_in_dispatcher=''
	for m in $acl_methods; do
		case "$case_hay" in
			*" $m "*) ;;
			*) missing_in_dispatcher="$missing_in_dispatcher $m" ;;
		esac
	done
	eq 'every ACL-declared luci.gitbackup method exists in the plugin dispatcher' '' "$missing_in_dispatcher"

	missing_in_acl=''
	for m in $case_methods; do
		case "$acl_hay" in
			*" $m "*) ;;
			*) missing_in_acl="$missing_in_acl $m" ;;
		esac
	done
	eq 'every plugin dispatcher method is declared in the ACL' '' "$missing_in_acl"

	missing_from_list=''
	for m in $case_methods; do
		case "$list_hay" in *" $m "*) ;; *) missing_from_list="$missing_from_list $m" ;; esac
	done
	eq 'every dispatcher method is also declared by "list"' '' "$missing_from_list"

	missing_from_case=''
	for m in $list_methods; do
		case "$case_hay" in *" $m "*) ;; *) missing_from_case="$missing_from_case $m" ;; esac
	done
	eq '"list" declares no method the dispatcher does not implement' '' "$missing_from_case"

	# Checked against the parsed method sets, not a raw grep -- the plugin's
	# own header comment says "get_secret does not exist" in so many words,
	# which a plain `grep -c get_secret` would count as a hit.
	eq 'the ACL never declares a get_secret method' '' "$(printf '%s' "$acl_hay" | grep -o ' get_secret ')"
	eq 'the plugin never dispatches a get_secret method' '' "$(printf '%s' "$case_hay" | grep -o ' get_secret ')"
	eq 'the ACL grants uci access to the gitbackup package in the read tier' \
		'1' "$(awk '/"read":/{f=1} f&&/"uci":.*"gitbackup"/{print 1; exit} /"write":/{exit}' "$acl" | grep -c 1)"
	eq 'the ACL grants uci access to the gitbackup package in the write tier' \
		'1' "$(awk '/"write":/{f=1} f&&/"uci":.*"gitbackup"/{print 1; exit}' "$acl" | grep -c 1)"
}

# t_rpcd_only_calls_gitbackup -- ticket 21's own headline acceptance
# criterion, checked structurally rather than by eye (same reasoning
# t_rpcd_acl_matches_plugin already gives for its own three-way check):
# "Плагин не вызывает git, sysupgrade и прочие внешние команды напрямую --
# только gitbackup". gbrpc_history/gbrpc_diff/gbrpc_list_paths/
# gbrpc_audit_paths are exactly the four methods that used to run `git`/
# `sysupgrade` themselves; each function's own body (not the file as a
# whole, whose header comments necessarily still SAY "git"/"sysupgrade" in
# prose) is extracted and checked for a bare `git`/`sysupgrade` command
# word, and for actually forwarding to "$GB_BIN" instead of just deleting
# the call outright -- a body that satisfies the first check by doing
# nothing at all would be a regression this test must not wave through.
t_rpcd_only_calls_gitbackup() {
	plugin="$files/usr/libexec/rpcd/luci.gitbackup"
	for fn in gbrpc_history gbrpc_diff gbrpc_list_paths gbrpc_audit_paths; do
		_body=$(sed -n "/^${fn}() {/,/^}/p" "$plugin" | grep -v '^[[:space:]]*#')
		[ -n "$_body" ] || { no "$fn: function body was found at all" 'sed range matched nothing -- the test itself is broken'; continue; }
		case "$_body" in
			*'git '*|*'git	'*)
				no "$fn calls only \$GB_BIN, never git directly" "found a bare 'git' call in: $_body" ;;
			*)
				ok "$fn calls only \$GB_BIN, never git directly" ;;
		esac
		case "$_body" in
			*'sysupgrade '*|*'sysupgrade	'*)
				no "$fn calls only \$GB_BIN, never sysupgrade directly" "found a bare 'sysupgrade' call in: $_body" ;;
			*)
				ok "$fn calls only \$GB_BIN, never sysupgrade directly" ;;
		esac
		case "$_body" in
			*'"$GB_BIN"'*) ok "$fn actually forwards to \$GB_BIN" ;;
			*) no "$fn actually forwards to \$GB_BIN" "no \"\$GB_BIN\" call found in: $_body" ;;
		esac
	done
}

t_rpcd_status_hides_secret() {
	GB_ETC_DIR="$work/rpcd-etc-status"; export GB_ETC_DIR
	mkdir -p "$GB_ETC_DIR"
	printf 'the-actual-secret-value\n' >"$GB_ETC_DIR/token"
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git' \
		"gitbackup.origin.token_file=$GB_ETC_DIR/token"
	out=$(rpcd_call status)
	assert_json 'status is valid JSON' "$out"
	contains 'status reports token_set: true' '"token_set": true' "$out"
	case "$out" in
		*'the-actual-secret-value'*) no 'status never contains the secret value' "leaked in [$out]" ;;
		*) ok 'status never contains the secret value' ;;
	esac
	unset GB_ETC_DIR
}

t_rpcd_log_wraps_cli_text() {
	printf 'gitbackup: notice: run: pushed abc123 to device/rt1\n' >"$work/rpcd-logread"
	GB_TEST_LOGREAD="$work/rpcd-logread"; export GB_TEST_LOGREAD
	out=$(rpcd_call log '{"lines":5}')
	assert_json 'log is valid JSON' "$out"
	contains 'log wraps the CLI'\''s own log text in a "text" field' 'pushed abc123' "$out"
	unset GB_TEST_LOGREAD
}

t_rpcd_pubkey_before_and_after_keygen() {
	GB_ETC_DIR="$work/rpcd-etc-pk"; export GB_ETC_DIR
	fixture "gitbackup.origin.key_file=$GB_ETC_DIR/id_ed25519"

	out=$(rpcd_call pubkey)
	assert_json 'pubkey error is valid JSON' "$out"
	contains 'pubkey before keygen answers with a "reason"' '"reason"' "$out"

	rpcd_call keygen >/dev/null
	out=$(rpcd_call pubkey)
	assert_json 'pubkey success is valid JSON' "$out"
	contains 'pubkey after keygen answers with the public key' 'ssh-ed25519' "$out"
	unset GB_ETC_DIR
}

# t_rpcd_keygen_force_requires_confirm -- ticket 25's web path: "force"
# with no "confirm" (or the wrong one) must come back as a structured
# refusal the Settings page can act on (confirm_required + fingerprint),
# never a silent regeneration and never a bare, unparseable error string.
# Only the fingerprint named back exactly is accepted.
t_rpcd_keygen_force_requires_confirm() {
	GB_ETC_DIR="$work/rpcd-etc-kfc"; export GB_ETC_DIR
	fixture "gitbackup.origin.key_file=$GB_ETC_DIR/id_ed25519"

	rpcd_call keygen >/dev/null
	_gb_before=$(cat "$GB_ETC_DIR/id_ed25519")

	out=$(rpcd_call keygen '{ "force": true }')
	assert_json 'keygen (force, no confirm) is valid JSON' "$out"
	contains 'and reports confirm_required: true' '"confirm_required": true' "$out"
	eq 'and the key is left untouched' "$_gb_before" "$(cat "$GB_ETC_DIR/id_ed25519")"

	_gb_fp=$(printf '%s' "$out" | sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	if [ -n "$_gb_fp" ]; then
		ok 'and carries a non-empty fingerprint to confirm with'
	else
		no 'and carries a non-empty fingerprint to confirm with' "$out"
	fi

	out=$(rpcd_call keygen '{ "force": true, "confirm": "not the right fingerprint" }')
	assert_json 'keygen (wrong confirm) is valid JSON' "$out"
	contains 'a mismatched confirmation is refused with a reason' '"reason"' "$out"
	eq 'and the key is still untouched' "$_gb_before" "$(cat "$GB_ETC_DIR/id_ed25519")"

	out=$(rpcd_call keygen "$(printf '{ "force": true, "confirm": "%s" }' "$_gb_fp")")
	assert_json 'keygen (exact confirm) is valid JSON' "$out"
	contains 'the exact fingerprint shown regenerates the key' '"ok": true' "$out"
	if [ "$(cat "$GB_ETC_DIR/id_ed25519")" = "$_gb_before" ]; then
		no 'and the key actually changed' 'identical bytes as before'
	else
		ok 'and the key actually changed'
	fi

	unset GB_ETC_DIR
}

t_rpcd_list_paths() {
	printf '/etc/config/network\n/etc/config/dhcp\n' >"$work/rpcd-sysupgrade-l"
	GB_TEST_SYSUPGRADE_L="$work/rpcd-sysupgrade-l"; export GB_TEST_SYSUPGRADE_L
	out=$(rpcd_call list_paths)
	assert_json 'list_paths is valid JSON' "$out"
	contains 'list_paths "effective" includes /etc/config/network' '/etc/config/network' "$out"
	contains 'list_paths "effective" includes /etc/config/dhcp' '/etc/config/dhcp' "$out"
	unset GB_TEST_SYSUPGRADE_L
}

# t_rpcd_list_paths_raw_vs_effective -- the defect this hand-off closes:
# gbrpc_list_paths used to print ONLY sysupgrade -l's own fully-expanded
# effective set, so a directory line a human added to sysupgrade.conf came
# back already flattened into individual files, and the LuCI view's first
# save (gbrpc_set_paths writes back exactly what it is given) baked that
# flattening into the file permanently -- silently narrowing what a real
# future sysupgrade would protect. list_paths must now carry both: "paths"
# is the raw, unexpanded content of GB_SYSUPGRADE_CONF (what a human wrote,
# the only thing set_paths may ever write back), "effective" is sysupgrade
# -l's own wider union (read-only, sizing/audit only). A directory line
# must appear in "paths" verbatim and must NOT appear, expanded into its
# individual files, there -- only in "effective".
t_rpcd_list_paths_raw_vs_effective() {
	GB_TEST_SYSUPGRADE_CONF="$work/rpcd-raweff-sysupgrade.conf"
	printf '/root/scripts/\n/etc/config/network\n' >"$GB_TEST_SYSUPGRADE_CONF"
	GB_TEST_SYSUPGRADE_L="$work/rpcd-raweff-sysupgrade-l"; export GB_TEST_SYSUPGRADE_L
	printf '/root/scripts/a.sh\n/root/scripts/b.sh\n/etc/config/network\n/etc/config/dhcp\n' >"$GB_TEST_SYSUPGRADE_L"

	out=$(rpcd_call list_paths)
	assert_json 'list_paths (raw+effective) is valid JSON' "$out"

	_gb_t_paths_part="${out%%\"effective\"*}"
	_gb_t_eff_part="${out#*\"effective\"}"

	contains 'raw "paths" keeps the directory line, unexpanded' '/root/scripts/' "$_gb_t_paths_part"
	contains 'raw "paths" also has the plain file line' '/etc/config/network' "$_gb_t_paths_part"
	case "$_gb_t_paths_part" in
		*'/root/scripts/a.sh'*)
			no 'raw "paths" is never expanded into the directory'\''s individual files' "found /root/scripts/a.sh in [$_gb_t_paths_part]" ;;
		*) ok 'raw "paths" is never expanded into the directory'\''s individual files' ;;
	esac

	contains '"effective" carries sysupgrade -l'\''s own expansion of the directory' '/root/scripts/a.sh' "$_gb_t_eff_part"
	contains '"effective" also carries a keep.d/conffiles-only entry' '/etc/config/dhcp' "$_gb_t_eff_part"

	unset GB_TEST_SYSUPGRADE_CONF GB_TEST_SYSUPGRADE_L
}

# t_rpcd_list_paths_entries_excludes_comments -- ticket 26: "paths list
# --json" and rpcd's "list_paths" are the same shape (gbrpc_list_paths
# forwards the CLI's own JSON verbatim, never rebuilding it) -- this pins
# that agreement down for the new "entries" field specifically: a raw
# sysupgrade.conf mixing a header comment, a commented-out example
# directory and two real entries must come back with "entries" holding
# only the two real ones, in order, while "paths" still carries all four
# raw lines unfiltered.
t_rpcd_list_paths_entries_excludes_comments() {
	GB_TEST_SYSUPGRADE_CONF="$work/rpcd-entries-sysupgrade.conf"
	printf '## header\n# /etc/openvpn/\n/etc/config/network\n/root/scripts\n' >"$GB_TEST_SYSUPGRADE_CONF"
	GB_TEST_SYSUPGRADE_L="$work/rpcd-entries-sysupgrade-l"; export GB_TEST_SYSUPGRADE_L
	: >"$GB_TEST_SYSUPGRADE_L"

	out=$(rpcd_call list_paths)
	assert_json 'list_paths is valid JSON' "$out"

	_gb_t_entries_part="${out#*\"entries\"}"
	_gb_t_entries_part="${_gb_t_entries_part%%\"effective\"*}"

	contains 'raw "paths" still has the comment lines' '## header' "$out"
	contains '"entries" has the first real entry' '/etc/config/network' "$_gb_t_entries_part"
	contains '"entries" has the second real entry' '/root/scripts' "$_gb_t_entries_part"
	case "$_gb_t_entries_part" in
		*'## header'*|*'/etc/openvpn/'*)
			no '"entries" excludes both comment lines' "found a comment in [$_gb_t_entries_part]" ;;
		*) ok '"entries" excludes both comment lines' ;;
	esac

	unset GB_TEST_SYSUPGRADE_CONF GB_TEST_SYSUPGRADE_L
}

t_rpcd_validate_cron() {
	out=$(rpcd_call validate_cron '{"expr":"0 3 * * *"}')
	assert_json 'validate_cron (valid) is valid JSON' "$out"
	contains 'a valid expression answers valid: true' '"valid": true' "$out"
	contains 'and names the next run' '"next"' "$out"

	out=$(rpcd_call validate_cron '{"expr":"@daily"}')
	assert_json 'validate_cron (invalid) is valid JSON' "$out"
	contains 'an invalid expression answers valid: false' '"valid": false' "$out"
	contains 'with a human-readable reason, not just a code' 'busybox crond' "$out"
}

# t_rpcd_call_params_survive_no_trailing_newline -- found live against the
# REAL rpcd daemon, never by a manual `printf '...\n' | plugin call ...`
# test (every `rpcd_call` helper call above does exactly that, trailing
# newline included, which is precisely why none of them caught this): the
# real daemon's own call params arrive on stdin with NO trailing newline at
# all, so `read -r` reads the whole line correctly but still returns
# nonzero for reaching EOF instead of a newline. An earlier version of the
# dispatcher's own `IFS= read -r _gb_rpc_input || _gb_rpc_input='{}'`
# treated that nonzero status as "nothing was read" and threw the real,
# fully-read params away in favor of an empty "{}" -- which would have
# silently broken every parameterized method (log/diff/history/
# validate_cron/set_secret/set_paths/restore) the moment this ran under
# real ubus, while every hand-typed test here kept looking green.
t_rpcd_call_params_survive_no_trailing_newline() {
	out=$(printf '%s' '{"expr":"0 3 * * *"}' | rpcd call validate_cron)
	contains 'a call param with no trailing newline on stdin still reaches the method' \
		'"valid": true' "$out"
}

# t_rpcd_set_secret_perms_and_no_log -- ticket 10 acceptance criterion:
# "set_secret пишет файл 0600 и не логирует значение".
t_rpcd_set_secret_perms_and_no_log() {
	GB_ETC_DIR="$work/rpcd-etc-secret"; export GB_ETC_DIR
	GB_TEST_LOG="$work/rpcd-logger.log"; export GB_TEST_LOG
	: >"$GB_TEST_LOG"
	fixture "gitbackup.origin.token_file=$GB_ETC_DIR/token"

	out=$(rpcd_call set_secret '{"value":"ghp_thisIsTheSecret"}')
	assert_json 'set_secret is valid JSON' "$out"
	contains 'set_secret reports token_set: true' '"token_set": true' "$out"

	# The stat stub (this file, above) only answers '%a %u %g' or '%u %g' --
	# not a bare '%a' -- so the mode is pulled out of the three-field form.
	_mode=$(stat -c '%a %u %g' "$GB_ETC_DIR/token" 2>/dev/null | awk '{print $1}')
	eq 'the token file is written 0600' '600' "$_mode"

	case "$out" in
		*'ghp_thisIsTheSecret'*) no 'the JSON response never echoes the secret value' "leaked in [$out]" ;;
		*) ok 'the JSON response never echoes the secret value' ;;
	esac
	case "$(cat "$GB_TEST_LOG")" in
		*'ghp_thisIsTheSecret'*) no 'the secret value is never written to the log' "leaked in [$(cat "$GB_TEST_LOG")]" ;;
		*) ok 'the secret value is never written to the log' ;;
	esac

	out=$(rpcd_call set_secret '{"value":""}')
	contains 'clearing the secret reports token_set: false' '"token_set": false' "$out"
	eq 'and the file exists but is empty, not a lone newline' '0' "$(wc -c <"$GB_ETC_DIR/token" | tr -d ' ')"

	unset GB_ETC_DIR GB_TEST_LOG
}

# t_rpcd_set_paths_validates_serverside -- gbrpc_set_paths used to
# duplicate only two of gb_paths_validate's checks inline (absolute,
# blacklist), leaving a space and a nonexistent path to the LuCI view's own
# JS -- but set_paths writes straight to flash and the view is not its
# only caller (the CLI's `paths add` already goes through
# gb_paths_validate directly). This now routes every entry through
# paths.sh's own gb_paths_validate, the exact function the CLI already
# uses, so the two can never validate differently -- and a directory that
# passes must land in sysupgrade.conf as one line, not expanded.
t_rpcd_set_paths_validates_serverside() {
	GB_ROOT="$work/rpcd-paths-root"; export GB_ROOT
	rm -rf "$GB_ROOT"
	mkdir -p "$GB_ROOT/etc/config" "$GB_ROOT/root/scripts"
	: >"$GB_ROOT/etc/config/network"

	GB_TEST_SYSUPGRADE_CONF="$work/rpcd-sysupgrade.conf"
	out=$(rpcd_call set_paths '{"paths":["/etc/config/network","/root/scripts","/proc/cpuinfo","relative","/etc/gitbackup/token","/tmp/x","/etc/config/has space","/etc/config/does-not-exist"]}')
	assert_json 'set_paths is valid JSON' "$out"
	contains 'the existing file is reported written' '"/etc/config/network"' "$out"
	contains 'the existing directory is reported written' '"/root/scripts"' "$out"
	contains '/proc/* is rejected with a reason, not silently' '"/proc/cpuinfo"' "$out"
	contains 'a relative path is rejected' '"relative"' "$out"
	contains '/etc/gitbackup/** is rejected as reserved' '"/etc/gitbackup/token"' "$out"
	contains '/tmp/* is rejected as non-persistent' '"/tmp/x"' "$out"
	contains 'a space in the path is now rejected server-side (gb_paths_validate), not only by the JS view' \
		'contains a space' "$out"
	contains 'a nonexistent path is now rejected server-side (gb_paths_validate), not only by the JS view' \
		'no such file or directory' "$out"

	eq 'only the valid entries land in sysupgrade.conf, and the directory is kept as one line, not expanded' \
		"$(printf '/etc/config/network\n/root/scripts')" \
		"$(cat "$GB_TEST_SYSUPGRADE_CONF" 2>/dev/null)"

	unset GB_TEST_SYSUPGRADE_CONF GB_ROOT
}

# t_rpcd_set_paths_preserves_comments -- ticket 26's own trap: the LuCI
# Paths view only ever sends back gb_paths_entries' own list (comments
# excluded by design -- see gbrpc_list_paths's own header comment above),
# so before this ticket the very first `set_paths` call against a stock
# /etc/sysupgrade.conf silently erased its own header comments and its two
# commented-out example lines, because gbrpc_set_paths used to write back
# only what it was sent, nothing else. paths.sh's own
# gb_paths_replace_entries now keeps them; this exercises that through the
# actual rpcd call (argv + stdin JSON), not just the shell function
# directly.
t_rpcd_set_paths_preserves_comments() {
	GB_ROOT="$work/rpcd-paths-comments-root"; export GB_ROOT
	rm -rf "$GB_ROOT"
	mkdir -p "$GB_ROOT/etc/config"
	: >"$GB_ROOT/etc/config/network"

	GB_TEST_SYSUPGRADE_CONF="$work/rpcd-sysupgrade-comments.conf"
	printf '## This file contains files and directories that should\n## be preserved during an upgrade.\n# /etc/example.conf\n# /etc/openvpn/\n' >"$GB_TEST_SYSUPGRADE_CONF"

	# Simulates the fixed LuCI view: it never saw the four comment lines
	# above at all (list_paths's own "entries" excludes them), so it can
	# only ever resubmit real entries -- here, the one path a human added.
	out=$(rpcd_call set_paths '{"paths":["/etc/config/network"]}')
	assert_json 'set_paths is valid JSON' "$out"
	contains 'the submitted entry is reported written' '"/etc/config/network"' "$out"

	eq 'the four original comment lines survive the save, unchanged and in order, the new entry appended after them' \
		"$(printf '## This file contains files and directories that should\n## be preserved during an upgrade.\n# /etc/example.conf\n# /etc/openvpn/\n/etc/config/network')" \
		"$(cat "$GB_TEST_SYSUPGRADE_CONF" 2>/dev/null)"

	unset GB_TEST_SYSUPGRADE_CONF GB_ROOT
}

# t_rpcd_long_methods_return_immediately -- ticket 10 acceptance criterion:
# "Долгие методы (run, restore, test) не блокируют ubus дольше таймаута".
# GB_URL points nowhere real, so each backgrounded CLI invocation fails
# fast on its own -- this test only cares that the ubus-facing call itself
# never waits around for that to happen.
t_rpcd_long_methods_return_immediately() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://127.0.0.1:1/o/r.git'

	for m in run test; do
		_t0=$(date +%s)
		out=$(rpcd_call "$m")
		_t1=$(date +%s)
		assert_json "$m is valid JSON" "$out"
		contains "$m answers immediately with started: true" '"started": true' "$out"
		eq "$m's own call returns in well under a second, not after a network timeout" '1' \
			"$([ "$((_t1 - _t0))" -le 2 ] && echo 1 || echo 0)"
	done

	_t0=$(date +%s)
	out=$(rpcd_call restore '{"device":"rt1"}')
	_t1=$(date +%s)
	assert_json 'restore is valid JSON' "$out"
	contains 'restore answers immediately with started: true' '"started": true' "$out"
	eq 'restore'\''s own call returns immediately too' '1' \
		"$([ "$((_t1 - _t0))" -le 2 ] && echo 1 || echo 0)"

	out=$(rpcd_call restore '{}')
	contains 'restore with no device is refused with a reason, never backgrounded blind' '"reason"' "$out"
}

# t_rpcd_hostkey_show_accept -- ticket 20's one new rpcd method, driven
# exactly the way LuCI's Settings page will: `hostkey` with no fingerprint
# (show), then again with the fingerprint copied out of that JSON (accept),
# proving the whole web-only path -- no stdin anywhere in this test, unlike
# gb_accept_hostkey's own interactive prompt. Synchronous, unlike run/test/
# restore above: a single SSH dial (ConnectTimeout=15) for show, no network
# call at all for accept.
t_rpcd_hostkey_show_accept() {
	GB_ETC_DIR="$work/rpcd-etc-hostkey"; export GB_ETC_DIR
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=git@example.com:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'

	_gb_hk_key="$work/rpcd-hostkey-key"
	rm -f "$_gb_hk_key" "$_gb_hk_key.pub"
	ssh-keygen -t ed25519 -N '' -f "$_gb_hk_key" >/dev/null
	GB_TEST_SSH_HOSTKEY="example.com $(cat "$_gb_hk_key.pub")"; export GB_TEST_SSH_HOSTKEY

	out=$(rpcd_call hostkey)
	assert_json 'hostkey (show) is valid JSON' "$out"
	contains 'and reports trusted: false' '"trusted": false' "$out"
	_gb_hk_fp=$(printf '%s' "$out" | sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
	if [ -n "$_gb_hk_fp" ]; then
		ok 'and carries a non-empty fingerprint'
	else
		no 'and carries a non-empty fingerprint' "$out"
	fi

	out=$(rpcd_call hostkey '{ "fingerprint": "not the right one" }')
	assert_json 'hostkey (wrong fingerprint) is valid JSON' "$out"
	contains 'a mismatched fingerprint is refused with a reason, not silently accepted' '"reason"' "$out"

	# Not assert_json'd: gb_hostkey_accept's own success line is a gb_log
	# notice, which -- same as gb_keygen's (t_rpcd_pubkey_before_and_after_
	# keygen's own established pattern for this) -- lands on stderr ahead
	# of the JSON body in this 2>&1 capture. The plugin's own real stdout
	# (what ubus actually delivers) is JSON-only; only this test's own
	# capture style mixes the two streams.
	out=$(rpcd_call hostkey "$(printf '{ "fingerprint": "%s" }' "$_gb_hk_fp")")
	contains 'the exact fingerprint shown is accepted' '"ok": true' "$out"

	out=$(rpcd_call hostkey)
	assert_json 'hostkey (show again) is valid JSON' "$out"
	contains 'and now reports trusted: true' '"trusted": true' "$out"

	unset GB_TEST_SSH_HOSTKEY GB_ETC_DIR
}

# t_rpcd_history_and_diff -- against a REAL bare repository (interfaces.md:
# the one sanctioned exception to stubbing git, same as gitio.sh/restore.sh
# above), because history/diff (R163i) are this ticket's own on-demand
# shallow-clone-in-/tmp logic, not a CLI passthrough -- there is nothing
# else that already proves this plumbing works.
t_rpcd_history_and_diff() {
	# Exported before the very first `git` call, not just before the rpcd
	# call below: the fixture setup a few lines down (a real checkout, two
	# real commits) needs the stub's real-git passthrough exactly as much
	# as the method call does -- found by this test itself failing on
	# "git stub: unsupported subcommand 'init'" the first time through.
	GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL

	_bare="$work/rpcd-history-bare.git"
	_co="$work/rpcd-history-checkout"
	rm -rf "$_bare" "$_co"
	git init --bare -q "$_bare"
	git init -q "$_co"
	# Ticket 21: `history`/`diff` now run GB_URL through gb_parse_url
	# (usr/sbin/gitbackup's own cmd_history/cmd_diff) before ever touching
	# git -- a bare filesystem path no longer qualifies, so a schema-valid
	# URL is swapped for the real bare path at the git-stub level, same
	# mechanism diff_setup/t_run_integration_bare_repo already rely on.
	GB_TEST_GIT_REMOTE_URL="https://example.org/o/r.git"; export GB_TEST_GIT_REMOTE_URL
	GB_TEST_GIT_REMOTE_PATH="$_bare"; export GB_TEST_GIT_REMOTE_PATH
	(
		cd "$_co" || exit 1
		git config user.email t@t; git config user.name t
		mkdir -p devices/rt1/files/etc/config
		printf 'option one x\n' >devices/rt1/files/etc/config/network
		echo '{"generated":"t1"}' >devices/rt1/manifest.json
		git add -A
		GIT_AUTHOR_DATE=2026-08-01T00:00:00 GIT_COMMITTER_DATE=2026-08-01T00:00:00 \
			git commit -q -m '2026-08-01 00:00 rt1: network'
		printf 'option one y\n' >devices/rt1/files/etc/config/network
		printf 'option x 1\n' >devices/rt1/files/etc/config/dhcp
		echo '{"generated":"t2"}' >devices/rt1/manifest.json
		git add -A
		GIT_AUTHOR_DATE=2026-08-02T00:00:00 GIT_COMMITTER_DATE=2026-08-02T00:00:00 \
			git commit -q -m '2026-08-02 00:00 rt1: network, dhcp'
		git branch -m device/rt1
		git remote add origin "$_bare"
		git push -q origin device/rt1
	)
	_sha_old=$(git -C "$_co" log --format=%H | tail -n 1)
	_sha_new=$(git -C "$_co" log --format=%H | head -n 1)

	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.url=$GB_TEST_GIT_REMOTE_URL"

	out=$(rpcd_call history '{"limit":10}')
	assert_json 'history is valid JSON' "$out"
	contains 'history names the resolved branch' '"branch": "device/rt1"' "$out"
	contains 'history includes the newest commit'\''s sha' "$_sha_new" "$out"
	contains 'and its date-first subject (G03.1)' '2026-08-02 00:00 rt1' "$out"
	contains 'and the oldest (root) commit'\''s changed files, --root and all' 'devices/rt1/files/etc/config/network' "$out"

	out=$(rpcd_call diff "{\"from\":\"$_sha_old\",\"to\":\"$_sha_new\"}")
	assert_json 'diff is valid JSON' "$out"
	contains 'diff shows the network option changing' '-option one x' "$out"
	contains 'diff shows dhcp being added' '+option x 1' "$out"

	out=$(rpcd_call diff '{}')
	contains 'diff with no from/to is refused with a reason' '"reason"' "$out"

	# Ticket 21's own explicit acceptance criterion: a from/to shaped like
	# an option is rejected, not handed to `git diff` unexamined. This used
	# to be unreachable through this test's own real bare repo (no server
	# to reach at all, per the ticket's own "не воспроизведён" note) -- now
	# it never gets that far, because the CLI's _gb_valid_full_sha rejects
	# the shape before any fetch is attempted.
	out=$(rpcd_call diff "{\"from\":\"-upload-pack=touch /tmp/pwned\",\"to\":\"$_sha_new\"}")
	contains 'a "from" shaped like an option is refused with a reason, never reaching git' \
		'"reason"' "$out"
	eq 'and no such file was ever created' '0' "$([ -e /tmp/pwned ] && echo 1 || echo 0)"

	unset GB_TEST_GIT_REAL GB_TEST_GIT_REMOTE_URL GB_TEST_GIT_REMOTE_PATH
}

# t_rpcd_history_no_backup_yet -- a configured remote whose branch has
# never been pushed to (a router that has never run `run` yet) is not an
# error -- an empty history, same as gb_remote_head's own "branch does not
# exist" contract (gitio.sh) is 0/empty, never a failure.
t_rpcd_history_no_backup_yet() {
	GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
	_bare="$work/rpcd-history-empty-bare.git"
	rm -rf "$_bare"
	git init --bare -q "$_bare"

	# Ticket 21: see t_rpcd_history_and_diff's own comment -- gb_parse_url
	# now runs before git does, so a bare path no longer qualifies.
	GB_TEST_GIT_REMOTE_URL="https://example.org/o/r.git"; export GB_TEST_GIT_REMOTE_URL
	GB_TEST_GIT_REMOTE_PATH="$_bare"; export GB_TEST_GIT_REMOTE_PATH

	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.url=$GB_TEST_GIT_REMOTE_URL"

	out=$(rpcd_call history '{}')
	assert_json 'history on a branchless repo is still valid JSON' "$out"
	contains 'and answers an empty commit list, not an error' '"commits": []' "$out"
	unset GB_TEST_GIT_REAL GB_TEST_GIT_REMOTE_URL GB_TEST_GIT_REMOTE_PATH
}

t_rpcd_history_unconfigured() {
	fixture 'gitbackup.origin.url='
	out=$(rpcd_call history '{}')
	assert_json 'history with no remote configured is still valid JSON' "$out"
	contains 'and explains why, via "reason"' '"reason"' "$out"
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

	# ticket 15 added a second owfeed.yml package block (luci-app-gitbackup) --
	# scoped to just the "- name: gitbackup" block (up to the next top-level
	# "  - name:" or EOF), or a depends:/conffiles: line belonging to the OTHER
	# package would be picked up by the plain grep below and blamed on this one.
	yml_gitbackup_block=$(awk '
		/^  - name: gitbackup$/ { grab = 1; print; next }
		grab && /^  - name:/ { exit }
		grab { print }
	' "$yml")

	# Makefile DEPENDS, minus the package.mk '+' (select-by-default) prefix, which
	# has no owfeed equivalent (see owfeed.yml's own comment on its depends: line).
	mk_depends=$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$mk" | tr ' ' '\n' | sed 's/^+//' | sort)
	yml_depends=$(printf '%s\n' "$yml_gitbackup_block" | sed -n 's/^[[:space:]]*depends: \[\(.*\)\]/\1/p' |
		tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort)
	eq 'owfeed.yml depends: matches Makefile DEPENDS' "$mk_depends" "$yml_depends"

	# The Package/gitbackup/conffiles block, one path per line between the markers.
	mk_conffiles=$(sed -n '/^define Package\/gitbackup\/conffiles$/,/^endef$/p' "$mk" | sed '1d;$d' | sort)
	yml_conffiles=$(printf '%s\n' "$yml_gitbackup_block" | sed -n 's/^[[:space:]]*conffiles: \[\(.*\)\]/\1/p' |
		tr ',' '\n' | tr -d '"' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort)
	eq 'owfeed.yml conffiles: matches Makefile Package/gitbackup/conffiles' "$mk_conffiles" "$yml_conffiles"
}

# t_owfeed_yml_matches_luci_makefile -- ticket 15's own second owfeed.yml
# package block (luci-app-gitbackup, staged by tools/stage.sh into
# dist/luci-root), held to the same "no second source of truth" standard as
# t_owfeed_yml_matches_makefile above: applications/luci-app-gitbackup/
# Makefile's LUCI_DEPENDS is what an SDK build would honor, and owfeed.yml's
# depends: is what the RELEASED apk actually gets, so a drift between the
# two would ship a package an SDK build and the release disagree about.
t_owfeed_yml_matches_luci_makefile() {
	mk="$root/applications/luci-app-gitbackup/Makefile"
	yml="$root/owfeed.yml"

	yml_luci_block=$(awk '
		/^  - name: luci-app-gitbackup$/ { grab = 1; print; next }
		grab && /^  - name:/ { exit }
		grab { print }
	' "$yml")

	mk_depends=$(sed -n 's/^[[:space:]]*LUCI_DEPENDS:=//p' "$mk" | tr ' ' '\n' | sed 's/^+//' | sort)
	yml_depends=$(printf '%s\n' "$yml_luci_block" | sed -n 's/^[[:space:]]*depends: \[\(.*\)\]/\1/p' |
		tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort)
	eq 'owfeed.yml luci-app-gitbackup depends: matches Makefile LUCI_DEPENDS' "$mk_depends" "$yml_depends"
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
		"$files/etc/init.d/gitbackup" "$files/etc/uci-defaults/"* \
		"$files/usr/libexec/rpcd/luci.gitbackup" 2>/dev/null |
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
usr/share/gitbackup/card.sh
usr/share/gitbackup/collect.sh
usr/share/gitbackup/device.sh
usr/share/gitbackup/exclude.list
usr/share/gitbackup/gitio.sh
usr/share/gitbackup/lib.sh
usr/share/gitbackup/paths.sh
usr/share/gitbackup/remoteurl.sh
usr/share/gitbackup/restore.sh
usr/share/gitbackup/schedule.sh
usr/share/gitbackup/scrub.list
usr/share/gitbackup/scrub.sh
usr/share/gitbackup/visibility.sh
usr/libexec/rpcd/luci.gitbackup
EOF
	_gb_stray=$(cd "$files" && find . -type f | sed 's#^\./##' | while IFS= read -r _gb_f; do
		grep -qxF "$_gb_f" "$_gb_allow" || printf '%s\n' "$_gb_f"
	done)
	eq 'every file under package/gitbackup/files/ is on the explicit whitelist' '' "$_gb_stray"
}

t_no_bashisms() {
	found=''
	for f in "$share"/*.sh "$files/usr/sbin/gitbackup" "$files/etc/init.d/gitbackup" \
		"$files/etc/uci-defaults/99-gitbackup" "$files/usr/libexec/rpcd/luci.gitbackup"; do
		grep -n '\[\[\|\${[A-Za-z_]*^^\|<(\|^function ' "$f" >/dev/null 2>&1 &&
			found="$found $f"
	done
	eq 'no bash-only construct reaches busybox ash' '' "$found"
}

# --------------------------------------------------------------------------
# terminal marker fixture (ticket 29, D11)
#
# tests/fixtures/terminal-markers.tsv is the shared source of truth for the
# three "is this operation over" regexes the LuCI views poll the live log
# with (overview.js's GB_LOG_TERMINAL_RE, settings.js's GB_TEST_TERMINAL_RE,
# history.js's GB_RESTORE_TERMINAL_RE). tests/terminal_markers_fixture.
# test.js reads the same file and proves the three regexes classify every
# row the way the fixture says to; what belongs here, on the shell side, is
# proving the fixture's own <line> text is not invented -- ticket 19's own
# failure mode was a shell message renamed with the JS regex left on the old
# text, and nothing caught it because neither side ever compared notes.
#
# Two different strengths of proof, both against the SAME fixture file:
#
#   - t_terminal_markers_fixture_anchors_are_real (below) walks every row
#     and greps its <anchor> column -- literal text taken from <line> with
#     the interpolated ($_gb_*) parts removed -- against the actual shell
#     sources. Catches a straight rename or typo in the source; does NOT
#     catch a rename applied to <anchor> at the same time without also
#     fixing the regex (that is the JS test's job) and does not prove the
#     message is reachable at runtime with exactly this wording, only that
#     the fragment exists somewhere in the source text.
#   - The handful of t_terminal_markers_driven_* tests that follow drive
#     the real CLI/gb_restore against a real flock, a real unreachable
#     port, or a real local bare git repository (same convention gitio.sh/
#     restore.sh's own tests already use) and grep the ACTUAL captured
#     logger() output -- the exact channel `gitbackup log`/logread hands
#     the LuCI poller -- for the fixture's own line. Stronger: proves the
#     message survives quoting and variable interpolation intact, not just
#     that a fragment of it sits in the source file. Only a representative
#     subset of the fixture's branches are driven this way (the ones with
#     existing integration harnesses this file already keeps working) --
#     see each test's own comment for which, and the ticket 29 report for
#     the honest accounting of what is and is not covered by real code.

t_terminal_markers_fixture_anchors_are_real() {
	(
		_tm_fixtures="$root/tests/fixtures/terminal-markers.tsv"
		if [ ! -r "$_tm_fixtures" ]; then
			no 'tests/fixtures/terminal-markers.tsv is readable' "missing: $_tm_fixtures"
			return
		fi
		_tm_tab=$(printf '\t')
		_tm_n=0
		while IFS="$_tm_tab" read -r _tm_var _tm_terminal _tm_line _tm_anchor; do
			case "$_tm_var" in ''|'#'*) continue ;; esac
			_tm_n=$((_tm_n + 1))
			if grep -qF -- "$_tm_anchor" \
				"$files/usr/sbin/gitbackup" \
				"$share/visibility.sh" \
				"$share/auth.sh" \
				"$share/askpass.sh" \
				"$share/restore.sh" \
				"$share/gitio.sh" 2>/dev/null
			then
				ok "terminal-markers.tsv: [$_tm_var/$_tm_terminal] \"$_tm_line\" is real shell text"
			else
				no "terminal-markers.tsv: [$_tm_var/$_tm_terminal] \"$_tm_line\" is real shell text" \
					"anchor [$_tm_anchor] not found in any shell source -- fixture text may be stale (ticket 19's own failure mode)"
			fi
		done <"$_tm_fixtures"
		if [ "$_tm_n" -eq 0 ]; then
			no 'the fixture file actually contains cases' 'read zero rows -- the loop or the file is broken'
		fi
	)
}

# t_terminal_markers_driven_run -- GB_LOG_TERMINAL_RE's own "skipped"
# branches, driven through the real `cli run` dispatch (flock, then the
# network precheck, then the space check -- steps 1/3/5 of cmd_run), with
# the raw logger() text captured via GB_TEST_LOG and checked against the
# exact fixture lines, not just their stdout summaries (t_cli_run_flock_busy/
# t_cli_run_space_check_fails above already cover the stdout side).
t_terminal_markers_driven_run() {
	GB_TEST_LOG="$work/tm-run-lock.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git'
	GB_TEST_FLOCK_LOCKED=1; export GB_TEST_FLOCK_LOCKED
	cli run >/dev/null 2>&1
	contains 'run: a busy lock logs the exact GB_LOG_TERMINAL_RE fixture line' \
		'gitbackup run: another run already holds the lock, skipped' "$(cat "$GB_TEST_LOG")"
	unset GB_TEST_FLOCK_LOCKED GB_TEST_LOG

	GB_TEST_LOG="$work/tm-run-unreachable.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://127.0.0.1:1/o/r.git'
	cli run >/dev/null 2>&1
	contains 'run: an unreachable remote logs a line matching the GB_LOG_TERMINAL_RE fixture shape' \
		'unreachable, skipped' "$(cat "$GB_TEST_LOG")"
	unset GB_TEST_LOG

	gb_listener
	_tm_pid="$GB_LISTENER_PID"
	if [ -z "$_tm_pid" ]; then
		skip 'run: not enough space in /tmp logs a line matching the GB_LOG_TERMINAL_RE fixture shape' \
			'python3 not found on PATH -- gb_listener needs it for a real listening socket'
		return 0
	fi
	GB_TEST_LOG="$work/tm-run-space.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.url=https://127.0.0.1:$GB_LISTENER_PORT/o/r.git" \
		'gitbackup.origin.acknowledged=1'
	GB_TEST_DF_KB=100; export GB_TEST_DF_KB
	cli run >/dev/null 2>&1
	contains 'run: not enough space in /tmp logs a line matching the GB_LOG_TERMINAL_RE fixture shape' \
		'not enough space in /tmp -- need ~' "$(cat "$GB_TEST_LOG")"
	unset GB_TEST_DF_KB GB_TEST_LOG
	kill "$_tm_pid" 2>/dev/null
	wait "$_tm_pid" 2>/dev/null
}

# t_terminal_markers_driven_run_success -- the "pushed"/"no changes" pair,
# driven against a real local bare git repository, same mechanism
# t_run_integration_bare_repo above already relies on. Captures the ACTUAL
# commit sha `run` just pushed and checks the logged line against it
# verbatim, not just a substring -- proof the fixture's own
# 'pushed [0-9a-f]+ to ' shape is not aspirational.
t_terminal_markers_driven_run_success() {
	gb_listener
	_tm_pid="$GB_LISTENER_PID"
	if [ -z "$_tm_pid" ]; then
		skip 'run: pushed/no-changes log the exact GB_LOG_TERMINAL_RE fixture lines' \
			'python3 not found on PATH -- gb_listener needs it for a real listening socket'
		return 0
	fi

	collect_fixture
	GB_DEVICE=rt1
	mkdir -p "$work/froot/etc/config"
	printf 'config interface lan\n\toption proto static\n' >"$work/froot/etc/config/network"
	sysupgrade_list '/etc/config/network'
	printf "DISTRIB_RELEASE='25.12.4'\nDISTRIB_REVISION='r1'\n" >"$work/froot/etc/openwrt_release"

	GB_TEST_GIT_REAL=1; export GB_TEST_GIT_REAL
	_tm_bare="$work/tm-run-success-bare.git"
	rm -rf "$_tm_bare"
	git init --bare -q "$_tm_bare"
	GB_TEST_GIT_REMOTE_URL="https://127.0.0.1:$GB_LISTENER_PORT/o/r.git"; export GB_TEST_GIT_REMOTE_URL
	GB_TEST_GIT_REMOTE_PATH="$_tm_bare"; export GB_TEST_GIT_REMOTE_PATH
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		"gitbackup.origin.url=$GB_TEST_GIT_REMOTE_URL" \
		'gitbackup.origin.acknowledged=1'

	GB_TEST_LOG="$work/tm-run-pushed.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	cli run >/dev/null 2>&1
	_tm_commit=$(git --git-dir="$_tm_bare" log -1 --format=%H device/rt1 2>/dev/null)
	if [ -n "$_tm_commit" ]; then
		contains 'run: a real push logs the exact GB_LOG_TERMINAL_RE "pushed" fixture line' \
			"gitbackup run: pushed $_tm_commit to device/rt1" "$(cat "$GB_TEST_LOG")"
	else
		no 'run: a real push logs the exact GB_LOG_TERMINAL_RE "pushed" fixture line' \
			'run 1 produced no commit on device/rt1 at all'
	fi

	GB_TEST_LOG="$work/tm-run-nochange.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	cli run >/dev/null 2>&1
	contains 'run: an idempotent second run logs the exact GB_LOG_TERMINAL_RE "no changes" fixture line' \
		'gitbackup run: no changes since the last backup on device/rt1' "$(cat "$GB_TEST_LOG")"

	unset GB_TEST_GIT_REAL GB_TEST_GIT_REMOTE_URL GB_TEST_GIT_REMOTE_PATH GB_TEST_LOG
	kill "$_tm_pid" 2>/dev/null
	wait "$_tm_pid" 2>/dev/null
}

# t_terminal_markers_driven_test -- GB_TEST_TERMINAL_RE's own success/
# network/auth branches, driven through the real `cli test` dispatch. https
# only (no ssh host key step involved) -- the host key trio below is its
# own, separate ssh-only test.
t_terminal_markers_driven_test() {
	GB_TEST_LOG="$work/tm-test-ok.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=https://example.org/o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'
	GB_TEST_GIT_RC=0; export GB_TEST_GIT_RC
	cli test >/dev/null 2>&1
	contains 'test: success logs the exact GB_TEST_TERMINAL_RE fixture line' \
		'gitbackup test: https://example.org/o/r.git is reachable and authenticated' "$(cat "$GB_TEST_LOG")"
	unset GB_TEST_GIT_RC GB_TEST_LOG

	GB_TEST_LOG="$work/tm-test-network.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	GB_TEST_GIT_RC=128; export GB_TEST_GIT_RC
	GB_TEST_GIT_ERR="Failed to connect to example.org port 443: Connection refused"; export GB_TEST_GIT_ERR
	cli test >/dev/null 2>&1
	contains 'test: an unreachable remote logs the exact GB_TEST_TERMINAL_RE "cannot reach" fixture line' \
		"cannot reach example.org: Failed to connect to example.org port 443: Connection refused" "$(cat "$GB_TEST_LOG")"
	unset GB_TEST_GIT_RC GB_TEST_GIT_ERR GB_TEST_LOG

	GB_TEST_LOG="$work/tm-test-auth.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	GB_TEST_GIT_RC=128; export GB_TEST_GIT_RC
	GB_TEST_GIT_ERR='Permission denied (publickey).'; export GB_TEST_GIT_ERR
	cli test >/dev/null 2>&1
	contains 'test: rejected credentials log the exact GB_TEST_TERMINAL_RE "authentication" fixture line' \
		'authentication to https://example.org/o/r.git failed: Permission denied (publickey).' "$(cat "$GB_TEST_LOG")"
	unset GB_TEST_GIT_RC GB_TEST_GIT_ERR GB_TEST_LOG
}

# t_terminal_markers_driven_test_hostkey -- GB_TEST_TERMINAL_RE's own
# host-key trio, ssh-only (cmd_test's host key step never runs for https).
# Same three shapes t_cli_test_hostkey_declined/needs_confirmation/
# unreachable above already prove at the stdout/exit-code level; this adds
# the GB_TEST_LOG check against the fixture's own exact text.
t_terminal_markers_driven_test_hostkey() {
	fixture 'gitbackup.main.device_id=custom' 'gitbackup.main.device=rt1' \
		'gitbackup.origin.url=git@example.org:o/r.git' \
		'gitbackup.origin.provider=generic' 'gitbackup.origin.acknowledged=1'

	GB_TEST_LOG="$work/tm-test-hk-declined.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	GB_TEST_SSH_HOSTKEY='example.org ssh-ed25519 AAAAtestkey'; export GB_TEST_SSH_HOSTKEY
	printf 'n\n' | cli test >/dev/null 2>&1
	contains 'test: a declined host key logs the exact GB_TEST_TERMINAL_RE fixture line' \
		'example.org:22 host key was not accepted' "$(cat "$GB_TEST_LOG")"
	unset GB_TEST_SSH_HOSTKEY GB_TEST_LOG

	GB_TEST_LOG="$work/tm-test-hk-noask.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	GB_TEST_SSH_HOSTKEY='example.org ssh-ed25519 AAAAtestkey'; export GB_TEST_SSH_HOSTKEY
	cli test </dev/null >/dev/null 2>&1
	contains 'test: no stdin to confirm a host key logs the exact GB_TEST_TERMINAL_RE fixture line' \
		"example.org:22 host key needs confirmation before this can proceed -- run 'gitbackup hostkey show'" \
		"$(cat "$GB_TEST_LOG")"
	unset GB_TEST_SSH_HOSTKEY GB_TEST_LOG

	GB_TEST_LOG="$work/tm-test-hk-unreachable.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"
	unset GB_TEST_SSH_HOSTKEY
	cli test </dev/null >/dev/null 2>&1
	contains 'test: an unreachable host key logs the exact GB_TEST_TERMINAL_RE fixture line' \
		'example.org:22 host key could not be obtained -- is the network reachable?' "$(cat "$GB_TEST_LOG")"
	unset GB_TEST_LOG
}

# t_terminal_markers_driven_restore_success -- GB_RESTORE_TERMINAL_RE's own
# success line, driven against a real local bare git repository, same
# restore_setup/restore_seed_push harness t_restore_* above already uses.
t_terminal_markers_driven_restore_success() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup
		GB_TEST_LOG="$work/tm-restore-success.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_tm_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_tm_entries=$(restore_entry_file /etc/config/network 640 0 0 "$_tm_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_tm_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		out=$(gb_restore rt1 '' --yes 2>&1)
		eq 'gb_restore exits 0' '0' "$?"
		_tm_commit=$(git -C "$work/restore-seed" log -1 --format=%H 2>/dev/null)
		if [ -n "$_tm_commit" ]; then
			contains 'restore: success logs the exact GB_RESTORE_TERMINAL_RE fixture line' \
				"gb_restore: restored rt1 from $_tm_commit on device/rt1" "$(cat "$GB_TEST_LOG")"
		else
			no 'restore: success logs the exact GB_RESTORE_TERMINAL_RE fixture line' \
				'could not read back the seed commit sha'
		fi

		restore_teardown
	)
}

# t_terminal_markers_driven_restore_failures -- the sha-mismatch and
# board-mismatch refusals, same restore_setup fixtures t_restore_sha_
# mismatch_stops_before_write/t_restore_board_mismatch above already build,
# with GB_TEST_LOG added to check the exact fixture text.
t_terminal_markers_driven_restore_failures() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup
		GB_TEST_LOG="$work/tm-restore-sha.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_tm_entries=$(restore_entry_file /etc/config/network 640 0 0 \
			'deadbeef0000000000000000000000000000000000000000000000000000')
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_tm_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		gb_restore rt1 '' --yes >/dev/null 2>&1
		contains 'restore: a sha256 mismatch logs a line matching the GB_RESTORE_TERMINAL_RE fixture shape' \
			'gb_restore: sha256 mismatch, refusing to write anything to disk:' "$(cat "$GB_TEST_LOG")"

		restore_teardown
	)
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup
		GB_TEST_BOARD='{"model":"Other Board","release":{"target":"otherarch/generic"}}'
		export GB_TEST_BOARD
		GB_TEST_LOG="$work/tm-restore-board.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"

		mkdir -p "$work/restore-seed/devices/rt1/files/etc/config"
		printf 'config network\n' >"$work/restore-seed/devices/rt1/files/etc/config/network"
		_tm_sha=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/config/network" | awk '{print $1}')
		_tm_entries=$(restore_entry_file /etc/config/network 640 0 0 "$_tm_sha")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_tm_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		gb_restore rt1 '' --yes >/dev/null 2>&1
		contains 'restore: a board mismatch logs a line matching the GB_RESTORE_TERMINAL_RE fixture shape' \
			"this backup was taken on a different board (" "$(cat "$GB_TEST_LOG")"

		restore_teardown
	)
}

# t_terminal_markers_driven_restore_write_failure -- the "NOT written"
# branch, same cp-stub trick t_restore_write_failure_does_not_block_perms
# above already uses to make one path's write fail on purpose.
t_terminal_markers_driven_restore_write_failure() {
	(
		. "$share/lib.sh"; . "$share/gitio.sh"; . "$share/restore.sh"
		restore_setup
		GB_TEST_LOG="$work/tm-restore-notwritten.log"; export GB_TEST_LOG; : >"$GB_TEST_LOG"

		mkdir -p "$work/restore-seed/devices/rt1/files/etc"
		printf '127.0.0.1 localhost\n' >"$work/restore-seed/devices/rt1/files/etc/hosts"
		_tm_sha_hosts=$(sha256sum "$work/restore-seed/devices/rt1/files/etc/hosts" | awk '{print $1}')
		_tm_uid=$(id -u)
		_tm_gid=$(id -g)
		_tm_entries=$(restore_entry_file /etc/hosts 644 "$_tm_uid" "$_tm_gid" "$_tm_sha_hosts")
		restore_write_manifest "$work/restore-seed/devices/rt1/manifest.json" "$_tm_entries" ''
		restore_seed_push "$work/restore-bare.git" device/rt1

		mkdir -p "$work/restore-dest/etc"
		printf "stale hosts file, e.g. Docker's own bind mount\\n" >"$work/restore-dest/etc/hosts"
		chmod 644 "$work/restore-dest/etc/hosts"

		mkdir -p "$work/tm-cp-hosts-stuck"
		cat >"$work/tm-cp-hosts-stuck/cp" <<'STUB'
#!/bin/sh
for a in "$@"; do dest="$a"; done
case "$dest" in
	*etc/hosts) echo "cp: can't create '$dest': File exists" >&2; exit 1 ;;
esac
args=""
for a in "$@"; do
	case "$a" in
		-*) ;;
		*) args="$args $a" ;;
	esac
done
# shellcheck disable=SC2086
command -p cp $args
STUB
		chmod +x "$work/tm-cp-hosts-stuck/cp"

		PATH="$work/tm-cp-hosts-stuck:$PATH" gb_restore rt1 '' --yes >/dev/null 2>&1
		contains 'restore: a write failure logs the exact GB_RESTORE_TERMINAL_RE fixture line' \
			'gb_restore: the following paths were NOT written:' "$(cat "$GB_TEST_LOG")"

		restore_teardown
	)
}

# --------------------------------------------------------------------------

run_test 'lib.sh: gb_json_esc' t_json_esc
run_test 'lib.sh: gb_manifest_field' t_manifest_field
run_test 'lib.sh: gb_manifest_tail' t_manifest_tail
run_test 'lib.sh: gb_manifest_each' t_manifest_each
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
run_test 'collect.sh: the hard-exclude holds for every spelling of the same path' t_collect_hard_exclude_non_canonical
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
run_test 'auth.sh: gb_keygen -- force needs a matching confirmation' t_auth_keygen_force_needs_confirm
run_test 'auth.sh: gb_keygen keeps the previous key as .old until forgotten' t_auth_keygen_keeps_old
run_test 'auth.sh: gb_pubkey' t_auth_pubkey
run_test 'auth.sh: gb_accept_hostkey' t_auth_accept_hostkey
run_test 'auth.sh: gb_accept_hostkey -- EOF is not a decline' t_auth_accept_hostkey_eof
run_test 'auth.sh: gb_hostkey_show / gb_hostkey_accept' t_auth_hostkey_show_accept
run_test 'askpass.sh: answers prompts with the token' t_askpass
run_test 'gitio.sh: gb_remote_head on a branchless repository' t_gitio_remote_head_no_branch
run_test 'gitio.sh: gb_remote_head against an unreachable repository' t_gitio_remote_head_unreachable
run_test 'gitio.sh: first commit on a new branch, no parent' t_gitio_first_commit_no_parent
run_test 'gitio.sh: an extra file can be staged at the branch root, bypassing GB_PREFIX' t_gitio_build_tree_extra_root_file
run_test 'gitio.sh: commit-tree works with no git identity configured (owlab finding)' t_gitio_commit_push_no_global_git_identity
run_test 'gitio.sh: a shared branch preserves another device untouched' t_gitio_shared_branch_preserves_other_device
run_test 'gitio.sh: non-fast-forward push is rejected, then retried once' t_gitio_commit_push_nonfastforward_then_retry
run_test 'restore.sh: permissions/symlinks/empty dirs match the manifest' t_restore_permissions_symlinks_emptydirs
run_test 'restore.sh: chown is actually invoked per manifest entry, not just coincidentally matching' t_restore_chown_is_actually_called
run_test 'restore.sh: overwrites an existing destination against a busybox-shaped cp (owlab finding)' t_restore_overwrites_existing_destination
run_test 'restore.sh: a sha256 mismatch stops before any write' t_restore_sha_mismatch_stops_before_write
run_test 'restore.sh: a non-canonical manifest entry path is refused outright' t_restore_refuses_a_hostile_manifest_entry
run_test 'restore.sh: an option-shaped mode never reaches chmod' t_restore_refuses_an_option_shaped_mode
run_test 'restore.sh: a file entry never writes through an existing symlink' t_restore_never_writes_through_a_symlink
run_test 'restore.sh: board mismatch is refused, --force overrides it' t_restore_board_mismatch
run_test 'restore.sh: a major OpenWrt version gap warns, does not refuse' t_restore_os_release_major_mismatch_warns
run_test 'restore.sh: a non-empty manifest.scrubbed is printed to the operator' t_restore_scrubbed_list_printed
run_test 'restore.sh: --dry-run prints the plan and touches nothing' t_restore_dry_run_untouched
run_test 'restore.sh: fetches only its own device branch, not the whole repo' t_restore_fetches_only_its_own_branch
run_test 'restore.sh: a write failure on one path does not block perms on the rest (ticket 19)' t_restore_write_failure_does_not_block_perms
run_test 'restore.sh: the writability preflight skips a known-bad path before ever attempting cp (ticket 19)' t_restore_precheck_skips_a_known_unwritable_path_before_attempting_cp
run_test 'schedule.sh: gb_preset_expr is deterministic per device' t_schedule_preset_expr
run_test 'schedule.sh: gb_cron_valid on hand-picked examples' t_schedule_cron_valid_examples
run_test 'schedule.sh: gb_cron_valid against tests/fixtures/cron.tsv' t_schedule_cron_valid_fixtures
run_test 'schedule.sh: gb_cron_next' t_schedule_cron_next
run_test 'schedule.sh: gb_cron_apply is idempotent and off removes the line' t_schedule_cron_apply_idempotent
run_test 'schedule.sh: gb_cron_apply on an unrunnable cron_expr' t_schedule_cron_apply_bad_cron_expr
run_test 'lib.sh: gb_path_canon' t_path_canon
run_test 'paths.sh: gb_paths_validate against the fixed blacklist' t_paths_validate_blacklist
run_test 'paths.sh: gb_paths_validate refuses a non-canonical spelling of a blacklisted path' t_paths_validate_non_canonical
run_test 'paths.sh: gb_paths_validate on a space and a nonexistent path' t_paths_validate_space_and_missing
run_test 'paths.sh: gb_paths_add/gb_paths_del are idempotent' t_paths_add_del_idempotent
run_test 'paths.sh: gb_paths_list and gb_paths_size_kb' t_paths_list_and_size
run_test 'paths.sh: gb_paths_entries is empty on a stock sysupgrade.conf' t_paths_entries_stock_file
run_test 'paths.sh: gb_paths_entries is empty on a comments-and-blanks-only file' t_paths_entries_comments_only
run_test 'paths.sh: gb_paths_entries on a mixed file with entries, comments and blanks' t_paths_entries_mixed_and_blanks
run_test 'paths.sh: gb_paths_replace_entries preserves comments across a full-list write' t_paths_replace_entries_preserves_comments
run_test 'init.d/gitbackup: backed-up package list from sysupgrade -l' t_init_backed_up_packages
run_test 'init.d/gitbackup: config_change debounces a burst into one run' t_init_config_change_debounces
run_test 'cli: usage' t_cli_usage
run_test 'cli: unknown subcommand' t_cli_unknown_command
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
run_test 'cli: test -- host key needs confirmation (no stdin)' t_cli_test_hostkey_needs_confirmation
run_test 'cli: hostkey -- refused on an https remote' t_cli_hostkey_not_ssh
run_test 'cli: hostkey -- show/accept round trip, no stdin' t_cli_hostkey_show_accept_roundtrip
run_test 'cli: test -- accepted host key and working remote' t_cli_test_ok
run_test 'cli: test -- credentials rejected' t_cli_test_auth_rejected
run_test 'cli: keygen and pubkey need no remote configuration' t_cli_keygen_pubkey
run_test 'cli: keygen --force needs --confirm with the exact fingerprint shown' t_cli_keygen_force_confirm
run_test 'cli: a successful test forgets a kept .old key' t_cli_test_forgets_old_key_on_success
run_test 'cli: run -- a busy lock is skipped, not an error' t_cli_run_flock_busy
run_test 'cli: run -- not enough space in /tmp' t_cli_run_space_check_fails
run_test 'run: integration on a real local bare repository (3 runs)' t_run_integration_bare_repo
run_test 'run: a scrubbing run pushes no backup.tar.gz' t_run_scrub_pushes_no_archive
run_test 'cli: log shows run timings (A01)' t_cli_log
run_test 'cli: collect --out DIR' t_cli_collect
run_test 'cli: card --out FILE' t_cli_card
run_test 'cli: paths list/add/del' t_cli_paths_list_add_del
run_test 'cli: paths list --json "entries" excludes comments (ticket 26)' t_cli_paths_list_json_entries
run_test 'cli: paths audit -- overlay/upper vs sysupgrade -l' t_cli_paths_audit
run_test 'cli: history refuses a URL gb_parse_url does not recognize' t_cli_history_rejects_bad_url
run_test 'cli: diff <from> <to> refuses a sha shaped like an option' t_cli_diff_two_arg_rejects_bad_sha
run_test 'cli: restore refuses a bad --commit and a bad URL' t_cli_restore_rejects_bad_commit_and_bad_url
run_test 'cli: diff -- no prior backup shows everything as new' t_cli_diff_no_prior_backup
run_test 'cli: diff -- unchanged system prints nothing' t_cli_diff_unchanged_is_empty
run_test 'cli: diff -- catches a chmod git cannot see, plus added/removed paths (D03)' t_cli_diff_catches_permission_and_membership_changes
run_test 'card.sh: https remote recommends --token, not --ssh-key' t_card_https_token_flag
run_test 'card.sh: ssh remote recommends --ssh-key, web link coerced to https' t_card_ssh_key_flag
run_test 'card.sh: never leaks the token or deploy key onto the card' t_card_no_secret
run_test 'card.sh: never dies on a malformed or missing GB_URL/GB_DEVICE' t_card_never_dies
run_test 'card.sh: Path 0 matches what run actually pushes' t_card_path0_matches_what_run_actually_pushes
run_test 'rpcd: ACL matches the plugin dispatcher, both directions' t_rpcd_acl_matches_plugin
run_test 'rpcd: the read tier hands over no file content' t_rpcd_acl_read_tier_returns_no_file_content
run_test 'rpcd: history/diff/list_paths/audit_paths call only $GB_BIN, never git/sysupgrade directly' t_rpcd_only_calls_gitbackup
run_test 'rpcd: status never leaks the secret, only token_set' t_rpcd_status_hides_secret
run_test 'rpcd: log wraps the CLI'\''s own text' t_rpcd_log_wraps_cli_text
run_test 'rpcd: pubkey before and after keygen' t_rpcd_pubkey_before_and_after_keygen
run_test 'rpcd: keygen force requires a matching confirm' t_rpcd_keygen_force_requires_confirm
run_test 'rpcd: list_paths' t_rpcd_list_paths
run_test 'rpcd: list_paths keeps raw sysupgrade.conf separate from the expanded effective set' t_rpcd_list_paths_raw_vs_effective
run_test 'rpcd: list_paths "entries" excludes comments (ticket 26)' t_rpcd_list_paths_entries_excludes_comments
run_test 'rpcd: validate_cron -- valid and invalid' t_rpcd_validate_cron
run_test 'rpcd: call params survive a stdin with no trailing newline (real rpcd shape)' t_rpcd_call_params_survive_no_trailing_newline
run_test 'rpcd: set_secret writes 0600 and never logs the value' t_rpcd_set_secret_perms_and_no_log
run_test 'rpcd: set_paths validates server-side' t_rpcd_set_paths_validates_serverside
run_test 'rpcd: set_paths preserves comments across a save (ticket 26)' t_rpcd_set_paths_preserves_comments
run_test 'rpcd: run/test/restore return immediately, not after a timeout' t_rpcd_long_methods_return_immediately
run_test 'rpcd: hostkey -- show/accept round trip' t_rpcd_hostkey_show_accept
run_test 'rpcd: history and diff against a real bare repository' t_rpcd_history_and_diff
run_test 'rpcd: history on a branch with no backup yet' t_rpcd_history_no_backup_yet
run_test 'rpcd: history with no remote configured' t_rpcd_history_unconfigured
run_test 'rpcd: config_diff -- unchanged system answers differs: false' t_rpcd_config_diff_unchanged
run_test 'rpcd: config_diff -- catches a chmod git diff cannot see (D03)' t_rpcd_config_diff_catches_chmod
run_test 'rpcd: config_diff -- no remote configured answers a reason' t_rpcd_config_diff_unreachable_remote
run_test 'packaging: Makefile contract' t_makefile_contract
run_test 'packaging: config sections match code' t_config_sections_match_code
run_test 'packaging: owfeed.yml matches Makefile' t_owfeed_yml_matches_makefile
run_test 'packaging: owfeed.yml luci-app-gitbackup block matches its Makefile' t_owfeed_yml_matches_luci_makefile
run_test 'packaging: no bashisms' t_no_bashisms
run_test 'packaging: no untracked files under package/gitbackup/files (D02)' t_no_untracked_files_in_package_tree
run_test 'terminal-markers.tsv: every anchor is real shell text' t_terminal_markers_fixture_anchors_are_real
run_test 'terminal-markers.tsv: run -- lock/unreachable/space log the exact GB_LOG_TERMINAL_RE lines' t_terminal_markers_driven_run
run_test 'terminal-markers.tsv: run -- pushed/no-changes log the exact GB_LOG_TERMINAL_RE lines' t_terminal_markers_driven_run_success
run_test 'terminal-markers.tsv: test -- ok/network/auth log the exact GB_TEST_TERMINAL_RE lines' t_terminal_markers_driven_test
run_test 'terminal-markers.tsv: test -- host key trio logs the exact GB_TEST_TERMINAL_RE lines' t_terminal_markers_driven_test_hostkey
run_test 'terminal-markers.tsv: restore -- success logs the exact GB_RESTORE_TERMINAL_RE line' t_terminal_markers_driven_restore_success
run_test 'terminal-markers.tsv: restore -- sha/board mismatch log the exact GB_RESTORE_TERMINAL_RE lines' t_terminal_markers_driven_restore_failures
run_test 'terminal-markers.tsv: restore -- write failure logs the exact GB_RESTORE_TERMINAL_RE line' t_terminal_markers_driven_restore_write_failure

passed=$(grep -c '^PASS$' "$results")
failed=$(grep -c '^FAIL$' "$results")
skipped=$(grep -c '^SKIP$' "$results")

# Ticket 18: a filter that matched no test name used to fall through to
# "0 passed, 0 failed" and exit 0 -- a run that executed nothing reporting
# success, the same shape of bug that once made this very counter print
# "0 failed" over real failures (see the harness comment above `results`).
# A filter typo (or a test renamed out from under a caller) has to be loud,
# not a silent no-op that looks exactly like "everything passed".
if [ "$((passed + failed + skipped))" -eq 0 ]; then
	printf '\n%s matched no test -- ran nothing, which is not success\n' "$only" >&2
	exit 1
fi

# Ticket 28: the skipped count only ever appears on the summary line when
# it is non-zero, so a fully-equipped host (every optional tool present,
# not running as root) prints the exact same "N passed, 0 failed" it
# always did -- this is additive, not a format change anything downstream
# has to learn.
if [ "$skipped" -gt 0 ]; then
	printf '\n%s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
else
	printf '\n%s passed, %s failed\n' "$passed" "$failed"
fi
[ "$failed" -eq 0 ]
