#!/bin/sh
# shellcheck disable=SC1090,SC1091,SC2034,SC2030,SC2031
#
# SC1090/SC1091: bootstrap.sh is sourced from a path built at runtime.
# SC2034: GB_BOOTSTRAP_SOURCED is read by bootstrap.sh itself after being
# sourced, not used in this file.
# SC2030/SC2031 (ticket 15 review -- these five sites were invisible to CI
# before it, see .github/workflows/ci.yml's own shellcheck job for why):
# every `PATH="$stubdir:$PATH"` in this file sits inside a whole-test-body
# `( ... )` subshell (t_bootstrap_dry_run_untouched and friends below) and
# is read only by commands later in that SAME subshell -- the "local to
# subshell"/"might be lost" shellcheck warns about is exactly the isolation
# these tests want, so a sibling test's own PATH is never touched by this
# one. Confirmed by design, not by accident: this is the identical
# subshell-per-test-body shape tests/run.sh's own harness uses everywhere
# (that file's header explains why: a real assignment inside one WOULD be
# invisible outside it, which is the point here and was the actual bug
# there for the shared pass/fail counter, hence action via a file, not a
# variable).
# Unit tests for bootstrap.sh -- the root-router installer (ticket 09), kept
# separate from tests/run.sh (which only covers package/gitbackup/files/):
# bootstrap.sh lives in the repository root, is never installed onto a
# router, and is fetched/run as a whole script rather than dot-sourced by a
# shared CLI, so its own seam is smaller and does not belong in that file.
#
#   sh tests/bootstrap/run.sh          run everything
#   sh tests/bootstrap/run.sh <name>   run one test (substring match)
#
# Covers only what can be proven on a developer's host without a router:
# argument parsing, the host-extraction helper, validation of the required/
# mutually-exclusive flags, and that --dry-run truly changes nothing (every
# destructive command bootstrap.sh could call is stubbed to fail loudly).
# The one thing this suite cannot cover -- apk actually installing a signed
# package, `gitbackup test`/`restore` actually reaching a remote -- is the
# ticket's own mandatory end-to-end run on the owlab stand instead
# (interfaces.md: "то, что уже проверено интеграционно на стенде, второй
# раз в юнит-тестах не проверяется").
set -u

root=$(cd "$(dirname "$0")/../.." && pwd)
bootstrap="$root/bootstrap.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/gitbackup-bootstrap-tests.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT INT TERM

only="${1:-}"
results="$work/results"
: >"$results"

ok() { printf 'PASS\n' >>"$results"; printf '  ok    %s\n' "$1"; }
no() { printf 'FAIL\n' >>"$results"; printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want [$2] got [$3]"; fi
}

contains() {
	case "$3" in
		*"$2"*) ok "$1" ;;
		*) no "$1" "'$2' not found in: $3" ;;
	esac
}

run_test() {
	desc="$1"
	fn="$2"
	if [ -n "$only" ]; then
		case "$fn" in *"$only"*) ;; *) return 0 ;; esac
	fi
	printf '%s\n' "$desc"
	"$fn"
}

[ -r "$bootstrap" ] || { printf 'missing: %s\n' "$bootstrap" >&2; exit 1; }

# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------

t_bootstrap_parses_all_flags() {
	(
		GB_BOOTSTRAP_SOURCED=1
		# shellcheck disable=SC1090
		. "$bootstrap"
		gb_bs_parse_args --repo https://example.com/acme/routers --device r1 \
			--commit deadbeef --token PAT123 --branch custom/branch \
			--with-packages --dry-run --force
		eq 'parses --repo' 'https://example.com/acme/routers' "$GB_BS_REPO"
		eq 'parses --device' 'r1' "$GB_BS_DEVICE"
		eq 'parses --commit' 'deadbeef' "$GB_BS_COMMIT"
		eq 'parses --token' 'PAT123' "$GB_BS_TOKEN"
		eq 'parses --branch' 'custom/branch' "$GB_BS_BRANCH"
		eq 'parses --with-packages' '1' "$GB_BS_WITHPKGS"
		eq 'parses --dry-run' '1' "$GB_BS_DRYRUN"
		eq 'parses --force' '1' "$GB_BS_FORCE"

		gb_bs_parse_args --repo=x --device=y --ssh-key=/tmp/k --list
		eq 'parses --repo=VALUE form' 'x' "$GB_BS_REPO"
		eq 'parses --device=VALUE form' 'y' "$GB_BS_DEVICE"
		eq 'parses --ssh-key=VALUE form' '/tmp/k' "$GB_BS_SSHKEY"
		eq 'parses --list' '1' "$GB_BS_LIST"
	)
}

t_bootstrap_unknown_flag_dies() {
	(
		GB_BOOTSTRAP_SOURCED=1
		. "$bootstrap"
		out=$(gb_bs_parse_args --nonsense 2>&1)
		eq 'an unrecognized flag exits nonzero' '1' "$?"
		contains 'and names the bad flag, not a stack trace' '--nonsense' "$out"
	)
}

# --------------------------------------------------------------------------
# gb_bs_host_of -- same four remote URL forms remoteurl.sh's gb_parse_url
# accepts once installed (t_remoteurl_valid_forms, tests/run.sh); this is
# the small, separate duplicate this script needs before that module exists
# on disk (see bootstrap.sh's own header comment on gb_bs_host_of).
# --------------------------------------------------------------------------

t_bootstrap_host_of() {
	(
		GB_BOOTSTRAP_SOURCED=1
		. "$bootstrap"
		eq 'https://host/owner/repo' 'host' "$(gb_bs_host_of https://host/owner/repo)"
		eq 'https://host:8443/owner/repo.git' 'host:8443' "$(gb_bs_host_of https://host:8443/owner/repo.git)"
		eq 'git@host:owner/repo.git (scp-like)' 'host' "$(gb_bs_host_of git@host:owner/repo.git)"
		eq 'ssh://user@host:2222/owner/repo.git' 'host:2222' "$(gb_bs_host_of ssh://user@host:2222/owner/repo.git)"
	)
}

# --------------------------------------------------------------------------
# required / mutually exclusive flags -- run through gb_bs_main itself (a
# subshell: it calls exit on every path), with every externally visible
# command stubbed so a bug that reaches past validation is caught here
# rather than by accidentally touching the real host.
# --------------------------------------------------------------------------

# _bs_stub_path -- a directory whose apk/uci/gitbackup/reboot each append
# their own name plus arguments to $work/calls.log and exit 0, so a test
# can assert on exactly what bootstrap.sh tried to run (the state-changing
# commands only). uclient-fetch is ALSO stubbed -- it is not on a dev
# host's PATH at all -- but reports success without logging: step 1's
# network reachability probe is a plain read-only GET that runs even under
# --dry-run by design (the plan it prints should say honestly whether the
# repo is reachable), and is not one of the STATE changes "--dry-run
# changes nothing" is actually about.
_bs_stub_path() {
	_bs_bin="$work/bin"
	rm -rf "$_bs_bin"
	mkdir -p "$_bs_bin"
	for _bs_cmd in apk uci gitbackup reboot; do
		cat >"$_bs_bin/$_bs_cmd" <<EOF
#!/bin/sh
printf '%s %s\n' "$_bs_cmd" "\$*" >>"$work/calls.log"
exit 0
EOF
		chmod +x "$_bs_bin/$_bs_cmd"
	done
	cat >"$_bs_bin/uclient-fetch" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod +x "$_bs_bin/uclient-fetch"
	printf '%s' "$_bs_bin"
}

t_bootstrap_requires_repo_and_device() {
	(
		GB_BOOTSTRAP_SOURCED=1
		. "$bootstrap"
		out=$(gb_bs_main --device r1 --token t 2>&1)
		eq 'missing --repo dies nonzero' '1' "$?"
		contains 'and says --repo, not a stack trace' '--repo is required' "$out"

		out=$(gb_bs_main --repo https://h/o/r --token t 2>&1)
		eq 'missing --device dies nonzero' '1' "$?"
		contains 'and says --device' '--device is required' "$out"
	)
}

t_bootstrap_requires_exactly_one_credential() {
	(
		GB_BOOTSTRAP_SOURCED=1
		. "$bootstrap"
		out=$(gb_bs_main --repo https://h/o/r --device r1 2>&1)
		eq 'neither --token nor --ssh-key dies nonzero' '1' "$?"
		contains 'and explains the credential is required' 'credential' "$out"

		out=$(gb_bs_main --repo https://h/o/r --device r1 --token t --ssh-key /tmp/k 2>&1)
		eq 'both --token and --ssh-key dies nonzero' '1' "$?"
		contains 'and says to pass only one' 'not both' "$out"
	)
}

# t_bootstrap_dry_run_untouched -- the acceptance criterion, checked the
# only way that actually proves it: every command capable of installing a
# package, writing a credential, or touching UCI is stubbed to log itself
# and succeed, then --dry-run is run for real (through gb_bs_main, not by
# calling gb_bs_install_pkg/write_credential directly) and the log must
# stay completely empty.
t_bootstrap_dry_run_untouched() {
	(
		GB_BOOTSTRAP_SOURCED=1
		. "$bootstrap"
		stubdir=$(_bs_stub_path)
		rm -f "$work/calls.log"
		PATH="$stubdir:$PATH"
		out=$(gb_bs_main --repo https://h/o/r --device r1 --token t --dry-run 2>&1)
		eq 'dry-run exits 0' '0' "$?"
		contains 'and prints the restore command it would run' 'gitbackup restore' "$out"
		contains 'and says nothing was changed' 'nothing was changed' "$out"
		if [ -r "$work/calls.log" ]; then
			no 'dry-run calls no external command at all (apk/uci/gitbackup/reboot)' "$(cat "$work/calls.log")"
		else
			ok 'dry-run calls no external command at all (apk/uci/gitbackup/reboot)'
		fi
	)
}

# --------------------------------------------------------------------------
# --list -- rewritten (ticket 09 follow-up) from an anonymous/token-in-argv
# REST call to `git ls-remote` over the SAME git+askpass transport the rest
# of this product uses (bootstrap.sh's own header comment above gb_bs_list).
# That means --list now needs the package installed (auth.sh/askpass.sh
# sourced/exec'd for real, not stubbed) to prove anything meaningful, so
# these tests run the REAL module files from package/gitbackup/files --
# same boundary this suite's own header already draws for gitio.sh/
# restore.sh-style integration coverage, just for auth.sh/askpass.sh
# instead. `git` and `uci` are still stubs (a real router's git/uci, not a
# dev host's), but ones that round-trip values and replay git's own
# askpass dance faithfully enough to prove the credential actually flows
# through GIT_ASKPASS and never through argv.
# --------------------------------------------------------------------------

# _bs_stub_list_path -- PATH for the --list tests below. Separate from
# _bs_stub_path (which only needs to prove "nothing was called" for the
# --dry-run test above): `git` here fakes the exact askpass exchange real
# git performs for an authenticated `ls-remote --heads` while logging its
# own full argv, and `uci` actually stores what it is `set`, unlike
# _bs_stub_path's log-only version -- auth.sh's gb_git_env and askpass.sh
# are sourced/exec'd UNMODIFIED here and read gitbackup.origin.* back
# through real `uci -q get` calls; a stub that always answers empty would
# make every one of them fall back to a hardcoded default and never prove
# the credential this test wrote is what actually gets read back.
_bs_stub_list_path() {
	_bsl_bin="$work/bin-list"
	rm -rf "$_bsl_bin"
	mkdir -p "$_bsl_bin"

	cat >"$_bsl_bin/uclient-fetch" <<'EOF'
#!/bin/sh
exit 0
EOF

	cat >"$_bsl_bin/uci" <<'EOF'
#!/bin/sh
db="${GB_TEST_UCIDB:?uci stub: GB_TEST_UCIDB is not set}"
[ "$1" = -q ] && shift
case "$1" in
	get)
		val=$(grep "^$2=" "$db" 2>/dev/null | tail -n 1)
		[ -n "$val" ] || exit 1
		printf '%s\n' "${val#*=}"
		;;
	set)
		key="${2%%=*}"
		val="${2#*=}"
		grep -v "^$key=" "$db" >"$db.tmp" 2>/dev/null
		printf '%s=%s\n' "$key" "$val" >>"$db.tmp"
		mv "$db.tmp" "$db"
		;;
	commit) : ;;
	*) echo "uci stub: unsupported '$*'" >&2; exit 64 ;;
esac
EOF

	cat >"$_bsl_bin/git" <<EOF
#!/bin/sh
printf 'git %s\n' "\$*" >>"$work/calls.log"
if [ "\$1 \$2" = 'ls-remote --heads' ]; then
	# Replay git's own real askpass dance (auth.sh's gb_git_env sets
	# GIT_ASKPASS to the real askpass.sh): username prompt first
	# (discarded, same as real git), then the password prompt -- the
	# canned branch list below is only printed when the password
	# askpass.sh actually returned matches what this test configured,
	# proving the token really did flow through GIT_ASKPASS.
	if [ -n "\${GIT_ASKPASS:-}" ]; then
		"\$GIT_ASKPASS" "Username for 'https://example.com': " >/dev/null
		pass=\$("\$GIT_ASKPASS" "Password for 'https://gitbackup@example.com': ")
	else
		pass="\${GB_TEST_EXPECTED_TOKEN:-}"
	fi
	if [ "\$pass" != "\${GB_TEST_EXPECTED_TOKEN:-}" ]; then
		echo 'fatal: Authentication failed' >&2
		exit 128
	fi
	printf 'aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111\trefs/heads/device/r1\n'
	printf 'bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222\trefs/heads/main\n'
	exit 0
fi
exit 0
EOF
	chmod +x "$_bsl_bin"/*
	printf '%s' "$_bsl_bin"
}

# t_bootstrap_list_never_puts_token_in_argv -- the mutation-sensitive check
# the ticket asks for: every external command --list can invoke logs its
# full argv, and the token must never appear in that log. Verified by
# actually flipping this red once by hand while writing it (reintroducing
# a `--header=...$token...` argv word into gb_bs_list made this fail; the
# checked-in version does not).
t_bootstrap_list_never_puts_token_in_argv() {
	(
		GB_BOOTSTRAP_SOURCED=1
		GB_BOOTSTRAP_SECRET_DIR="$work/etc-list-argv"
		export GB_BOOTSTRAP_SECRET_DIR
		. "$bootstrap"

		GB_SHARE="$root/package/gitbackup/files/usr/share/gitbackup"
		export GB_SHARE

		stubdir=$(_bs_stub_list_path)
		rm -f "$work/calls.log"
		: >"$work/ucidb"
		GB_TEST_UCIDB="$work/ucidb"
		export GB_TEST_UCIDB
		PATH="$stubdir:$PATH"

		token='SECRET_TOKEN_never_in_argv_98765'
		GB_TEST_EXPECTED_TOKEN="$token"
		export GB_TEST_EXPECTED_TOKEN
		GB_BS_REPO='https://example.com/acme/routers'
		GB_BS_TOKEN="$token"
		GB_BS_SSHKEY=''
		GB_BS_FORCE=0

		out=$(gb_bs_list 2>&1)
		eq 'gb_bs_list against an already-installed package exits 0' '0' "$?"
		contains 'and lists the device branch it found' 'r1' "$out"
		case "$out" in
			*main*) no 'and does not list the non-device/* branch' "$out" ;;
			*) ok 'and does not list the non-device/* branch' ;;
		esac

		if grep -q "$token" "$work/calls.log"; then
			no 'the token never appears in any external command'\''s argv' "$(cat "$work/calls.log")"
		else
			ok 'the token never appears in any external command'\''s argv'
		fi
		contains 'git is invoked with ls-remote, never a REST call' 'ls-remote' "$(cat "$work/calls.log")"
	)
}

# t_bootstrap_list_installs_package_if_missing -- requirement 2's first
# question: --list installs the package itself when it is not there yet,
# rather than refusing. gb_bs_install_pkg is redefined here rather than
# exercised for real: it needs a real OpenWrt image (apk, DISTRIB_RELEASE,
# /etc/apk/arch) this suite's own header already excludes for the same
# reason as the main flow's own gb_bs_install_pkg (never called by any
# existing test either) -- what this test actually proves is that
# gb_bs_list CALLS it when auth.sh/lib.sh are missing, by having the fake
# installer materialize the real module files a real apk install would
# have placed there.
t_bootstrap_list_installs_package_if_missing() {
	(
		GB_BOOTSTRAP_SOURCED=1
		GB_BOOTSTRAP_SECRET_DIR="$work/etc-list-install"
		export GB_BOOTSTRAP_SECRET_DIR
		. "$bootstrap"

		missing_share="$work/pkg-not-installed-yet"
		rm -rf "$missing_share"
		GB_SHARE="$missing_share"
		export GB_SHARE

		# shellcheck disable=SC2329  # shadows bootstrap.sh's own definition; invoked indirectly via gb_bs_list -> gb_bs_ensure_pkg
		gb_bs_install_pkg() {
			printf 'install_pkg called\n' >>"$work/calls.log"
			mkdir -p "$missing_share"
			cp "$root/package/gitbackup/files/usr/share/gitbackup/lib.sh" "$missing_share/"
			cp "$root/package/gitbackup/files/usr/share/gitbackup/auth.sh" "$missing_share/"
			cp "$root/package/gitbackup/files/usr/share/gitbackup/askpass.sh" "$missing_share/"
		}

		stubdir=$(_bs_stub_list_path)
		rm -f "$work/calls.log"
		: >"$work/ucidb"
		GB_TEST_UCIDB="$work/ucidb"
		export GB_TEST_UCIDB
		PATH="$stubdir:$PATH"

		token='tok-for-install-test'
		GB_TEST_EXPECTED_TOKEN="$token"
		export GB_TEST_EXPECTED_TOKEN
		GB_BS_REPO='https://example.com/acme/routers'
		GB_BS_TOKEN="$token"
		GB_BS_SSHKEY=''
		GB_BS_FORCE=0

		out=$(gb_bs_list 2>&1)
		eq 'gb_bs_list installs the missing package first, then still succeeds' '0' "$?"
		contains 'install_pkg was actually called' 'install_pkg called' "$(cat "$work/calls.log")"
		contains 'and the listing itself still worked afterwards' 'r1' "$out"
	)
}

# t_bootstrap_list_skips_install_when_already_installed -- the flip side:
# an already-installed package (auth.sh/lib.sh present) must not trigger a
# second, pointless apk run. gb_bs_install_pkg is redefined to a trap that
# fails the test if it is ever called at all.
t_bootstrap_list_skips_install_when_already_installed() {
	(
		GB_BOOTSTRAP_SOURCED=1
		GB_BOOTSTRAP_SECRET_DIR="$work/etc-list-noinstall"
		export GB_BOOTSTRAP_SECRET_DIR
		. "$bootstrap"

		GB_SHARE="$root/package/gitbackup/files/usr/share/gitbackup"
		export GB_SHARE

		# shellcheck disable=SC2329  # shadows bootstrap.sh's own definition; invoked indirectly, if at all, by gb_bs_list -> gb_bs_ensure_pkg
		gb_bs_install_pkg() { printf 'install_pkg called\n' >>"$work/calls.log"; }

		stubdir=$(_bs_stub_list_path)
		rm -f "$work/calls.log"
		: >"$work/ucidb"
		GB_TEST_UCIDB="$work/ucidb"
		export GB_TEST_UCIDB
		PATH="$stubdir:$PATH"

		token='tok-for-noinstall-test'
		GB_TEST_EXPECTED_TOKEN="$token"
		export GB_TEST_EXPECTED_TOKEN
		GB_BS_REPO='https://example.com/acme/routers'
		GB_BS_TOKEN="$token"
		GB_BS_SSHKEY=''
		GB_BS_FORCE=0

		out=$(gb_bs_list 2>&1)
		eq 'gb_bs_list on an already-installed package exits 0' '0' "$?"
		if grep -q 'install_pkg called' "$work/calls.log" 2>/dev/null; then
			no 'an already-installed package is never reinstalled' "$(cat "$work/calls.log")"
		else
			ok 'an already-installed package is never reinstalled'
		fi
	)
}

# t_bootstrap_list_dry_run_installs_nothing -- requirement 2's third
# question: --list --dry-run must not become a surprise install. Every
# state-changing command is stubbed to log itself (the same _bs_stub_path
# the plain --dry-run test above uses), and the log must stay empty.
t_bootstrap_list_dry_run_installs_nothing() {
	(
		GB_BOOTSTRAP_SOURCED=1
		. "$bootstrap"
		stubdir=$(_bs_stub_path)
		rm -f "$work/calls.log"
		PATH="$stubdir:$PATH"
		out=$(gb_bs_main --repo https://h/o/r --list --dry-run 2>&1)
		eq '--list --dry-run exits 0' '0' "$?"
		contains 'and says nothing was changed' 'nothing was changed' "$out"
		contains 'and the plan mentions installing the package' 'install' "$out"
		if [ -r "$work/calls.log" ]; then
			no '--list --dry-run calls no external command at all' "$(cat "$work/calls.log")"
		else
			ok '--list --dry-run calls no external command at all'
		fi
	)
}

# t_bootstrap_help_documents_list_needs_package -- --help must actually
# say --list now requires/installs the package, replacing the removed
# warning about token-in-ps for the old REST implementation.
t_bootstrap_help_documents_list_needs_package() {
	out=$(sh "$bootstrap" --help 2>&1)
	eq 'bootstrap.sh --help exits 0' '0' "$?"
	contains '--help documents that --list needs the package installed' \
		'needs the package installed' "$out"
	contains 'and that --list --dry-run installs nothing' \
		'installs nothing' "$out"
}

# --------------------------------------------------------------------------
run_test 'bootstrap: parses every flag, both "--f v" and "--f=v" forms' t_bootstrap_parses_all_flags
run_test 'bootstrap: an unknown flag dies with a message naming it' t_bootstrap_unknown_flag_dies
run_test 'bootstrap: gb_bs_host_of covers all four remote URL forms' t_bootstrap_host_of
run_test 'bootstrap: --repo and --device are both required' t_bootstrap_requires_repo_and_device
run_test 'bootstrap: exactly one of --token/--ssh-key is required' t_bootstrap_requires_exactly_one_credential
run_test 'bootstrap: --dry-run touches nothing at all' t_bootstrap_dry_run_untouched
run_test 'bootstrap: --list never puts the token in any command'\''s argv' t_bootstrap_list_never_puts_token_in_argv
run_test 'bootstrap: --list installs the package if it is missing' t_bootstrap_list_installs_package_if_missing
run_test 'bootstrap: --list skips install when the package is already there' t_bootstrap_list_skips_install_when_already_installed
run_test 'bootstrap: --list --dry-run installs nothing' t_bootstrap_list_dry_run_installs_nothing
run_test 'bootstrap: --help documents --list needs the package' t_bootstrap_help_documents_list_needs_package

passed=$(grep -c '^PASS$' "$results")
failed=$(grep -c '^FAIL$' "$results")
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
