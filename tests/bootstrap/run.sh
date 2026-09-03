#!/bin/sh
# shellcheck disable=SC1090,SC1091,SC2034
#
# SC1090/SC1091: bootstrap.sh is sourced from a path built at runtime.
# SC2034: GB_BOOTSTRAP_SOURCED is read by bootstrap.sh itself after being
# sourced, not used in this file.
#
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
run_test 'bootstrap: parses every flag, both "--f v" and "--f=v" forms' t_bootstrap_parses_all_flags
run_test 'bootstrap: an unknown flag dies with a message naming it' t_bootstrap_unknown_flag_dies
run_test 'bootstrap: gb_bs_host_of covers all four remote URL forms' t_bootstrap_host_of
run_test 'bootstrap: --repo and --device are both required' t_bootstrap_requires_repo_and_device
run_test 'bootstrap: exactly one of --token/--ssh-key is required' t_bootstrap_requires_exactly_one_credential
run_test 'bootstrap: --dry-run touches nothing at all' t_bootstrap_dry_run_untouched

passed=$(grep -c '^PASS$' "$results")
failed=$(grep -c '^FAIL$' "$results")
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
