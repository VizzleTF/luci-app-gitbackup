#!/bin/sh
# shellcheck shell=sh
#
# gitbackup bootstrap -- bring a bare, freshly flashed OpenWrt 25.12 router
# back to the state it had before it died, in one command run over ssh
# (spec "Восстановление", Path 1; ticket 09).
#
#   uclient-fetch -qO- https://raw.githubusercontent.com/VizzleTF/luci-app-gitbackup/main/bootstrap.sh \
#     | sh -s -- --repo https://github.com/<owner>/<routers> --device r1 --token <PAT>
#
# THE CHICKEN AND THE EGG: this script is public and carries no secret of
# its own -- that is what lets it be fetched over plain https, with no
# token, from a public raw-file host. The data it restores is private, so
# the one thing it cannot get from anywhere but the operator is the
# credential: --token or --ssh-key. Whoever runs this command has to bring
# it, typed or pasted, every time.
#
# THE SHARP EDGE (spec: "Самое тонкое место"): /etc/gitbackup/** is a
# hard-exclude in collect.sh's own exclude.list, so the credential this
# script writes in step 3 below is NEVER going to come back out of a
# restored backup -- a deploy key with write access to the whole repository
# must never sit inside that same repository, under any configuration. That
# is why step 3 writes it from this script's own argument, and step 6 below
# re-checks with `gitbackup test` that the SAME credential still works
# after the restore has overwritten everything else.
#
# This script does not reimplement restore: everything from "does this
# backup's board match this hardware" to "which files get which mode" is
# already `gitbackup restore`'s job (ticket 08, restore.sh), reused as-is.
# What this script owns is only getting a bare router to the point where
# that command can run at all: network reachable, the signed package
# installed, and a credential on disk.
#
# POSIX sh, busybox ash only (interfaces.md): no [[, no arrays, no `local`
# assumed, no bashisms of any kind, and -- unlike every file under
# usr/share/gitbackup/ -- no dependency whatsoever on anything gitbackup's
# own DEPENDS would otherwise guarantee, because none of it is installed
# yet when this script starts. Only what the spec's own "Проверенные факты"
# confirm ships in the stock 25.12 image: uclient-fetch, libustream-mbedtls,
# ca-bundle, jsonfilter, ubus, sha256sum, mktemp -d, apk, uci. `apk add
# ca-bundle` at the top is deliberately absent -- measured live, https
# already works without it.
#
# Testable like every sibling module (interfaces.md's one seam: a file
# usable via `.`-inclusion, no side effects at load time) even though it is
# not one of them: everything below this point is function definitions;
# the actual run only starts at the very bottom, guarded by
# GB_BOOTSTRAP_SOURCED so tests/bootstrap can `. bootstrap.sh` and call
# gb_bs_* functions directly instead of exec'ing the whole flow.
#
# Every URL/key constant below is overridable through an environment
# variable a real invocation never sets -- the same GB_TEST_*-style seam
# every module under usr/share/gitbackup/ already uses, here so the ticket's
# own mandatory owlab end-to-end run can point this script at a throwaway
# local feed instead of the real one and prove the exact same code path.

set -u

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

# The project's OWN repository (VizzleTF/luci-app-gitbackup), never the
# operator's private one -- this is where the gitbackup PACKAGE and its
# signing key come from, unrelated to --repo (the operator's own backup
# repository, restored in step 4).
#
# GB_APK_KEY_PEM is the gitbackup feed's real, current signing public key
# (generated with `owfeed keygen`, matching what `owfeed install-snippet`
# emits for this project's own owfeed.yml) -- embedded here, not fetched
# separately, so it travels inside the one file this whole chain of trust
# already depends on this script arriving over https intact (spec: "Ключ
# вшит в bootstrap.sh -- он публичный, а сам скрипт приезжает по TLS").
# Its matching private half is not, and must never be, anywhere in this
# repository; only whoever runs the release pipeline (ticket 15) holds it,
# as a CI secret.
GB_APK_KEYNAME='gitbackup'
GB_APK_KEY_PEM='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEWNNjZVT3Ti/IAk8K/h7JmEvcngli
CQXxEls3JruVEh6z+rLxvkJP/DofULHTQAJvfL7dkW3lSid8RI6K0/JuZQ==
-----END PUBLIC KEY-----'

# The feed's release base: owfeed.yml's own `feed.url` plus the
# `releases/<line>/<arch>/packages.adb` layout `owfeed index` actually
# writes (confirmed live: `owfeed install-snippet -format sh` against this
# project's committed owfeed.yml prints exactly this shape). Overridable so
# the mandatory owlab end-to-end run in this ticket can point it at a
# throwaway local feed built the same way (`owfeed build && owfeed sign &&
# owfeed index`) instead of waiting on ticket 15's release pipeline to have
# published the real one.
GB_APK_FEED_BASE="${GB_BOOTSTRAP_FEED_BASE:-https://github.com/VizzleTF/luci-app-gitbackup/releases}"

GB_PKG_NAME='gitbackup'

# ---------------------------------------------------------------------------
# small helpers -- no dependency on the not-yet-installed package
# ---------------------------------------------------------------------------

gb_bs_log() {
	printf 'bootstrap: %s\n' "$*" >&2
}

gb_bs_die() {
	printf 'bootstrap: %s\n' "$*" >&2
	# shellcheck disable=SC2016  # backtick is prose (a literal command name), not substitution
	printf 'bootstrap: if this keeps failing, use Path 0 instead: download backup.tar.gz from the repository web UI and restore it through LuCI (System -> Backup / Flash Firmware -> Restore) or `sysupgrade -r`. See docs/RESTORE.md.\n' >&2
	exit 1
}

gb_bs_usage() {
	cat <<'EOF'
Usage: bootstrap.sh --repo URL --device NAME [options]

  --repo URL          the operator's own backup repository (required, unless --list)
  --device NAME       the device id to restore (required, unless --list)
  --commit SHA        restore this commit instead of the branch tip (default HEAD)
  --token PAT         personal access token for an https:// --repo
  --ssh-key PATH      path to an already-registered deploy private key, for an ssh --repo
  --branch NAME       override the device branch template (default device/{device})
  --with-packages     best-effort reinstall of the packages the backup recorded
  --dry-run           print the plan, change nothing
  --force             overwrite an existing credential file, override a board mismatch
  --list              list the device branches found on --repo and exit; no install

Exactly one of --token or --ssh-key is required for a real run.
EOF
}

# gb_bs_host_of <url> -- host[:port] out of any of the four remote URL forms
# gb_parse_url (remoteurl.sh, once installed) also accepts. Deliberately a
# small, separate duplicate rather than sourcing that module: this runs
# BEFORE the package -- and remoteurl.sh with it -- exists on disk at all.
# Good enough for a reachability probe and for --list's provider guess; the
# real, strict parse happens later, inside the installed `gitbackup`
# commands this script calls, which is what actually has to get it right.
gb_bs_host_of() {
	_gb_hu="$1"
	case "$_gb_hu" in
		https://*) _gb_hu="${_gb_hu#https://}" ;;
		ssh://*)
			_gb_hu="${_gb_hu#ssh://}"
			case "$_gb_hu" in *@*) _gb_hu="${_gb_hu#*@}" ;; esac
			;;
		*:*)
			# scp-like [user@]host:owner/repo
			_gb_hu="${_gb_hu%%:*}"
			case "$_gb_hu" in *@*) _gb_hu="${_gb_hu#*@}" ;; esac
			printf '%s\n' "$_gb_hu"
			return 0
			;;
	esac
	_gb_hu="${_gb_hu%%/*}"
	printf '%s\n' "$_gb_hu"
}

# gb_bs_check_network <repo-url> -- step 1 of the spec's Path 1 order:
# fail here, with a message pointing at Path 0, rather than several minutes
# later inside an apk or git error nobody asked to decode. Probes the
# operator's OWN repo host, not github.com: the two are frequently on
# different networks (a self-hosted GitLab/Gitea behind the same router's
# own VPN, say), and a check that only proves github.com is reachable would
# still send the operator into a confusing git failure two steps later.
gb_bs_check_network() {
	_gb_cn_host=$(gb_bs_host_of "$1")
	[ -n "$_gb_cn_host" ] || gb_bs_die "--repo '$1' does not look like a URL bootstrap can read a host out of"

	_gb_cn_hostonly="${_gb_cn_host%%:*}"
	_gb_cn_msg=$(uclient-fetch --timeout=10 -O /dev/null "https://$_gb_cn_host/" 2>&1 >/dev/null)
	_gb_cn_rc=$?
	# rc 8 is uclient-fetch's own "server answered, with an HTTP error status"
	# (visibility.sh's own confirmed contract) -- that IS reachable: a 404 or
	# 000 body from a plain https:// GET to the bare host proves DNS resolved
	# and TCP+TLS completed, which is all this check is for.
	case "$_gb_cn_rc" in
		0 | 8) return 0 ;;
	esac
	case "$_gb_cn_msg" in
		*'Resolving'*'failed'* | *'not resolve'* | *'bad address'*)
			gb_bs_die "cannot resolve $_gb_cn_hostonly -- check DNS/network, or use Path 0 (no network needed)"
			;;
		*)
			gb_bs_die "cannot reach $_gb_cn_hostonly: $_gb_cn_msg"
			;;
	esac
}

# gb_bs_install_pkg -- spec Path 1 step 2: the signed package, with a
# STANDARD apk signature check, never --allow-untrusted (interfaces.md,
# ticket acceptance criterion). Mirrors this project's own
# `owfeed install-snippet` output for this exact feed, minus the `apk add
# ca-bundle` line that snippet includes defensively for feeds in general --
# measured live on the 25.12.4 stand (spec "Проверенные факты"): ca-bundle
# and https already work out of the box here, so that line would be dead
# weight on every single run of this script.
gb_bs_install_pkg() {
	mkdir -p /etc/apk/keys /etc/apk/repositories.d
	printf '%s\n' "$GB_APK_KEY_PEM" >"/etc/apk/keys/$GB_APK_KEYNAME.pem"

	_gb_ip_release=''
	[ -r /etc/openwrt_release ] && _gb_ip_release=$(sed -n "s/^DISTRIB_RELEASE='\\{0,1\\}\\([^']*\\)'\\{0,1\\}\$/\\1/p" /etc/openwrt_release)
	[ -n "$_gb_ip_release" ] || gb_bs_die 'could not read DISTRIB_RELEASE from /etc/openwrt_release -- is this actually an OpenWrt router?'
	# Feed line, not point release: owfeed publishes by major.minor
	# (confirmed against this project's own owfeed.yml/install-snippet), the
	# same "25.12" a 25.12.4 and a 25.12.5 router both read from.
	_gb_ip_line="${_gb_ip_release%.*}"

	_gb_ip_arch=''
	[ -r /etc/apk/arch ] && _gb_ip_arch=$(cat /etc/apk/arch)
	[ -n "$_gb_ip_arch" ] || gb_bs_die 'could not read /etc/apk/arch'

	printf '%s\n' "$GB_APK_FEED_BASE/$_gb_ip_line/$_gb_ip_arch/packages.adb" \
		>"/etc/apk/repositories.d/$GB_APK_KEYNAME.list"

	# Keep both across a firmware upgrade, same as the feed's own
	# install-snippet -- a missing key after sysupgrade reads as an
	# UNTRUSTED signature, not as "reinstall the key".
	mkdir -p /lib/upgrade/keep.d
	printf '%s\n' "/etc/apk/keys/$GB_APK_KEYNAME.pem" "/etc/apk/repositories.d/$GB_APK_KEYNAME.list" \
		>"/lib/upgrade/keep.d/$GB_APK_KEYNAME"

	gb_bs_log "installing $GB_PKG_NAME from $GB_APK_FEED_BASE/$_gb_ip_line/$_gb_ip_arch/ ..."
	apk update || gb_bs_die 'apk update failed -- see above'
	# No --allow-untrusted anywhere, ever: a signature failure here MUST stop
	# the script, not fall back to installing an unverified package (ticket
	# acceptance criterion; spec: "-allow-untrusted не использовать ни при
	# каких флагах").
	apk add "$GB_PKG_NAME" || gb_bs_die "apk add $GB_PKG_NAME failed -- see above (an UNTRUSTED signature error here means the key or feed URL is wrong, not a network problem)"
}

# gb_bs_write_credential -- spec Path 1 step 3, the one secret this script
# ever touches, taken only from its own argument and never from the backup
# it is about to restore (see this file's own header: GB_ETC_DIR is a
# hard-exclude for exactly this reason). 0700 on the directory, 0600 on the
# file -- the same permissions gb_keygen (auth.sh) already asserts rather
# than trusts, applied here to the same paths auth.sh's own defaults name
# (gitbackup.origin.token_file/.key_file), since the temporary UCI config
# gb_bs_write_config below sets those defaults explicitly.
gb_bs_write_credential() {
	mkdir -p /etc/gitbackup
	chmod 0700 /etc/gitbackup

	if [ -n "$GB_BS_TOKEN" ]; then
		if [ -e /etc/gitbackup/token ] && [ "$GB_BS_FORCE" -ne 1 ]; then
			gb_bs_log '/etc/gitbackup/token already exists, keeping it (pass --force to replace it)'
		else
			printf '%s\n' "$GB_BS_TOKEN" >/etc/gitbackup/token
			chmod 0600 /etc/gitbackup/token
		fi
	fi

	if [ -n "$GB_BS_SSHKEY" ]; then
		[ -r "$GB_BS_SSHKEY" ] || gb_bs_die "--ssh-key $GB_BS_SSHKEY is not a readable file (copy it onto the router first, e.g. with scp, then pass its path here)"
		if [ -e /etc/gitbackup/id_ed25519 ] && [ "$GB_BS_FORCE" -ne 1 ]; then
			gb_bs_log '/etc/gitbackup/id_ed25519 already exists, keeping it (pass --force to replace it)'
		else
			cp "$GB_BS_SSHKEY" /etc/gitbackup/id_ed25519
			chmod 0600 /etc/gitbackup/id_ed25519
		fi
	fi
}

# gb_bs_write_config -- spec Path 1 step 3's "минимальная временная UCI-
# конфигурация remote -- ровно столько, чтобы прошло чтение ветки". Not the
# router's real configuration -- step 5 (the restored /etc/config/gitbackup
# from the backup itself) overwrites every bit of this, on purpose.
#
# gitbackup.main.device_id is forced to 'custom' with .device=$GB_BS_DEVICE
# rather than left at its packaged default ('hostname'): a bare router
# fresh out of the box almost always still carries the stock 'OpenWrt'
# hostname, which device.sh's own _gb_device_by_hostname refuses outright
# (two such routers would collide) -- `gitbackup test`/`restore` would die
# on gb_device_id before ever reaching the network, on the very case this
# script exists for. Restoring the real device_id strategy is, again, the
# backup's own job in step 5.
gb_bs_write_config() {
	uci set gitbackup.origin.url="$GB_BS_REPO"
	[ -n "$GB_BS_BRANCH" ] && uci set gitbackup.origin.branch="$GB_BS_BRANCH"
	[ -n "$GB_BS_TOKEN" ] && uci set gitbackup.origin.token_file=/etc/gitbackup/token
	[ -n "$GB_BS_SSHKEY" ] && uci set gitbackup.origin.key_file=/etc/gitbackup/id_ed25519
	uci set gitbackup.main.device_id=custom
	uci set gitbackup.main.device="$GB_BS_DEVICE"
	uci commit gitbackup
}

# gb_bs_allow_tty -- reopens stdin from the controlling terminal when it is
# not one already. The documented one-liner is `fetch | sh -s -- ...`: this
# process's stdin IS the pipe carrying the script's own bytes, and by the
# time it starts running, that pipe is at EOF. Two things downstream still
# need to `read` real operator input on a real ssh remote -- auth.sh's
# gb_accept_hostkey (an unknown ssh host key, asked from inside `gitbackup
# test`) and this script's own reboot prompt at the very end -- and without
# this, both would silently read EOF and take the safe default (decline)
# instead of ever actually asking. A non-interactive invocation (no
# controlling terminal at all -- CI, a script piping bootstrap.sh from
# another process, `owlab exec`) is left exactly as it was: those two
# prompts still default to declining rather than hanging or erroring.
#
# Found live on the owlab stand: `[ -r /dev/tty ]` is not enough of a
# check. In a session with no controlling terminal at all (measured:
# `owlab exec`, which runs the command over a plain non-interactive
# channel) /dev/tty exists as a device node and passes both -r and -w --
# permission bits, not "openable" -- so `exec </dev/tty` still runs, fails
# with ENXIO ("No such device or address"), and POSIX sh treats a failed
# redirection on `exec` as fatal: the whole script exited right there,
# before step 2 ever ran. Opening it in a throwaway subshell first and
# checking that subshell's own exit status is what actually tells "a real
# tty is attached" apart from "the node exists" -- confirmed live, the
# fix lets the exact same non-interactive run proceed instead of dying.
gb_bs_allow_tty() {
	if [ ! -t 0 ] && (exec 3</dev/tty) 2>/dev/null; then
		exec </dev/tty
	fi
}

# gb_bs_propose_reboot -- spec Path 1 step 7: "предложить reboot", never
# performed without asking (ticket acceptance criterion). Only ever reaches
# an actual `reboot` on a real interactive terminal that answered yes; every
# other case -- --dry-run never gets here, a non-interactive stdin defaults
# to no -- just prints the instruction and returns.
gb_bs_propose_reboot() {
	if [ -t 0 ]; then
		printf 'Reboot now to finish applying the restored configuration? [y/N] ' >&2
		IFS= read -r _gb_pr_ans
		case "$_gb_pr_ans" in
			y | Y | yes | YES)
				gb_bs_log 'rebooting...'
				reboot
				return 0
				;;
		esac
	fi
	# shellcheck disable=SC2016  # backtick is prose (a literal command name), not substitution
	gb_bs_log 'not rebooting automatically -- run `reboot` when ready to finish applying the restored configuration'
}

# ---------------------------------------------------------------------------
# --list -- spec acceptance criterion: "показывает доступные устройства и
# коммиты", with nothing installed yet. Reads the operator's OWN provider
# API directly (the same anonymous/token-authenticated shape
# visibility.sh's gb_visibility_ok already relies on for github/gitlab/
# gitea), because there is no git on the router at this point to `ls-remote`
# with -- installing the whole package just to answer "which device" would
# defeat the point of asking first.
# ---------------------------------------------------------------------------

# VERIFY: the branch-listing endpoints and their JSON shapes below are
# documented by each provider, not measured live against a real hosted
# repository from this stand (spec, "Проверенные факты -> Что осталось
# непроверенным" lists the same gap for gb_visibility_ok's own, simpler
# probe) -- unlike gb_visibility_ok's single 200/404 check, a full branch
# list is not something this project's own "Проверенные факты" table
# confirms against a live API. A provider this does not recognize below
# falls back to the generic message rather than guessing at a URL shape
# that might silently return the wrong JSON.
gb_bs_list() {
	_gb_l_repo="$1"
	_gb_l_token="${2:-}"

	_gb_l_host=$(gb_bs_host_of "$_gb_l_repo")
	case "$_gb_l_repo" in
		*://*) _gb_l_path="${_gb_l_repo#*://}" ;;
		*:*) _gb_l_path="${_gb_l_repo#*:}" ;;
		*) _gb_l_path='' ;;
	esac
	_gb_l_path="${_gb_l_path#*/}"
	case "$_gb_l_path" in
		*/*) _gb_l_owner="${_gb_l_path%%/*}"; _gb_l_name="${_gb_l_path#*/}" ;;
		*) gb_bs_die "--repo $_gb_l_repo does not look like host/owner/repo" ;;
	esac
	_gb_l_name="${_gb_l_name%.git}"

	case "$_gb_l_host" in
		github.com)
			_gb_l_api="https://api.github.com/repos/$_gb_l_owner/$_gb_l_name/branches?per_page=100"
			_gb_l_hdr="Authorization: token $_gb_l_token"
			_gb_l_namefield='@[*].name'
			_gb_l_shafield='@[*].commit.sha'
			;;
		gitlab.com)
			_gb_l_api="https://gitlab.com/api/v4/projects/$_gb_l_owner%2F$_gb_l_name/repository/branches?per_page=100"
			_gb_l_hdr="PRIVATE-TOKEN: $_gb_l_token"
			_gb_l_namefield='@[*].name'
			_gb_l_shafield='@[*].commit.id'
			;;
		*)
			gb_bs_log "no branch-listing API known for host '$_gb_l_host' -- open $_gb_l_repo in a browser instead"
			return 1
			;;
	esac

	_gb_l_tmp=$(mktemp "${TMPDIR:-/tmp}/gitbackup-bootstrap-list.XXXXXX") || return 1
	_gb_l_fetch_ok=1
	if [ -n "$_gb_l_token" ]; then
		uclient-fetch --timeout=15 -qO "$_gb_l_tmp" --header="$_gb_l_hdr" "$_gb_l_api" 2>/dev/null || _gb_l_fetch_ok=0
	else
		uclient-fetch --timeout=15 -qO "$_gb_l_tmp" "$_gb_l_api" 2>/dev/null || _gb_l_fetch_ok=0
	fi
	if [ "$_gb_l_fetch_ok" -eq 0 ]; then
		rm -f "$_gb_l_tmp"
		gb_bs_log "could not list branches on $_gb_l_repo (network, or the repository/token is wrong) -- open it in a browser instead"
		return 1
	fi

	_gb_l_names=$(jsonfilter -i "$_gb_l_tmp" -e "$_gb_l_namefield" 2>/dev/null)
	_gb_l_shas=$(jsonfilter -i "$_gb_l_tmp" -e "$_gb_l_shafield" 2>/dev/null)
	rm -f "$_gb_l_tmp"

	_gb_l_any=0
	_gb_l_i=1
	while IFS= read -r _gb_l_n; do
		case "$_gb_l_n" in
			device/*)
				_gb_l_sha=$(printf '%s\n' "$_gb_l_shas" | sed -n "${_gb_l_i}p")
				printf '%s\t%s\n' "${_gb_l_n#device/}" "${_gb_l_sha:-?}"
				_gb_l_any=1
				;;
		esac
		_gb_l_i=$((_gb_l_i + 1))
	done <<EOF
$_gb_l_names
EOF
	[ "$_gb_l_any" -eq 1 ] || gb_bs_log "no device/* branches found on $_gb_l_repo yet"
	return 0
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------

GB_BS_REPO=''
GB_BS_DEVICE=''
GB_BS_COMMIT=''
GB_BS_TOKEN=''
GB_BS_SSHKEY=''
GB_BS_BRANCH=''
GB_BS_WITHPKGS=0
GB_BS_DRYRUN=0
GB_BS_FORCE=0
GB_BS_LIST=0

gb_bs_parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--repo) shift; GB_BS_REPO="${1:-}"; shift ;;
			--repo=*) GB_BS_REPO="${1#--repo=}"; shift ;;
			--device) shift; GB_BS_DEVICE="${1:-}"; shift ;;
			--device=*) GB_BS_DEVICE="${1#--device=}"; shift ;;
			--commit) shift; GB_BS_COMMIT="${1:-}"; shift ;;
			--commit=*) GB_BS_COMMIT="${1#--commit=}"; shift ;;
			--token) shift; GB_BS_TOKEN="${1:-}"; shift ;;
			--token=*) GB_BS_TOKEN="${1#--token=}"; shift ;;
			--ssh-key) shift; GB_BS_SSHKEY="${1:-}"; shift ;;
			--ssh-key=*) GB_BS_SSHKEY="${1#--ssh-key=}"; shift ;;
			--branch) shift; GB_BS_BRANCH="${1:-}"; shift ;;
			--branch=*) GB_BS_BRANCH="${1#--branch=}"; shift ;;
			--with-packages) GB_BS_WITHPKGS=1; shift ;;
			--dry-run) GB_BS_DRYRUN=1; shift ;;
			--force) GB_BS_FORCE=1; shift ;;
			--list) GB_BS_LIST=1; shift ;;
			-h | --help) gb_bs_usage; exit 0 ;;
			*) gb_bs_die "unknown argument '$1' (see --help)" ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

gb_bs_main() {
	gb_bs_parse_args "$@"

	# Skipped when sourced for tests (tests/bootstrap/run.sh, GB_BOOTSTRAP_SOURCED=1):
	# a test calling gb_bs_main directly on a developer's own host is
	# deliberately exercising argument parsing/--dry-run/--list as a normal
	# user, same as every other module here runs its own tests unprivileged.
	if [ "${GB_BOOTSTRAP_SOURCED:-0}" != 1 ]; then
		[ "$(id -u 2>/dev/null)" = 0 ] || gb_bs_die 'must run as root'
	fi

	if [ "$GB_BS_LIST" -eq 1 ]; then
		[ -n "$GB_BS_REPO" ] || gb_bs_die '--list needs --repo'
		gb_bs_list "$GB_BS_REPO" "$GB_BS_TOKEN"
		exit $?
	fi

	[ -n "$GB_BS_REPO" ] || gb_bs_die '--repo is required (see --help)'
	[ -n "$GB_BS_DEVICE" ] || gb_bs_die '--device is required (see --help)'
	if [ -n "$GB_BS_TOKEN" ] && [ -n "$GB_BS_SSHKEY" ]; then
		gb_bs_die 'pass either --token or --ssh-key, not both'
	fi
	if [ -z "$GB_BS_TOKEN" ] && [ -z "$GB_BS_SSHKEY" ]; then
		gb_bs_die 'one of --token or --ssh-key is required -- this is the credential the repository itself can never hand back (see this file'\''s own header)'
	fi

	gb_bs_log "repo=$GB_BS_REPO device=$GB_BS_DEVICE commit=${GB_BS_COMMIT:-HEAD}"

	# Step 1.
	gb_bs_check_network "$GB_BS_REPO"

	if [ "$GB_BS_DRYRUN" -eq 1 ]; then
		printf 'dry run -- would:\n'
		printf '  1. install %s from %s (apk, signature-checked)\n' "$GB_PKG_NAME" "$GB_APK_FEED_BASE"
		[ -n "$GB_BS_TOKEN" ] && printf '  2. write /etc/gitbackup/token (0600)\n'
		[ -n "$GB_BS_SSHKEY" ] && printf '  2. write /etc/gitbackup/id_ed25519 from %s (0600)\n' "$GB_BS_SSHKEY"
		printf '  3. set gitbackup.origin.url=%s, gitbackup.main.device=%s (temporary)\n' "$GB_BS_REPO" "$GB_BS_DEVICE"
		printf '  4. gitbackup test\n'
		printf '  5. gitbackup restore --device %s --commit %s --yes%s%s\n' \
			"$GB_BS_DEVICE" "${GB_BS_COMMIT:-HEAD}" \
			"$([ "$GB_BS_FORCE" -eq 1 ] && printf ' --force')" \
			"$([ "$GB_BS_WITHPKGS" -eq 1 ] && printf ' --with-packages')"
		printf '  6. gitbackup test (confirm the credential still works)\n'
		printf 'nothing was changed.\n'
		exit 0
	fi

	gb_bs_allow_tty

	# Step 2.
	gb_bs_install_pkg

	# Step 3.
	gb_bs_write_credential
	gb_bs_write_config

	gb_bs_log 'verifying the credential and accepting the host key if needed (gitbackup test)...'
	gitbackup test
	_gb_bs_rc=$?
	[ "$_gb_bs_rc" -eq 0 ] || {
		gb_bs_log "gitbackup test failed (exit $_gb_bs_rc) -- the credential in --token/--ssh-key was written to /etc/gitbackup, but does not work against $GB_BS_REPO yet; fix it (wrong PAT scope, deploy key not added to the repo, wrong host key) and re-run \`gitbackup test\` by hand"
		exit "$_gb_bs_rc"
	}

	# Step 4 -- the one call that actually restores anything; --yes because
	# this script's own invocation, with an explicit --device already
	# chosen by the operator, IS the confirmation restore.sh would otherwise
	# still ask for interactively (restore.sh's own gb_restore, ticket 08).
	gb_bs_log "restoring device '$GB_BS_DEVICE'..."
	_gb_bs_restore_flags='--yes'
	[ "$GB_BS_FORCE" -eq 1 ] && _gb_bs_restore_flags="$_gb_bs_restore_flags --force"
	[ "$GB_BS_WITHPKGS" -eq 1 ] && _gb_bs_restore_flags="$_gb_bs_restore_flags --with-packages"
	# shellcheck disable=SC2086  # word-splitting is the point: zero or more bare flag tokens
	gitbackup restore --device "$GB_BS_DEVICE" --commit "${GB_BS_COMMIT:-HEAD}" $_gb_bs_restore_flags
	_gb_bs_rc=$?
	[ "$_gb_bs_rc" -eq 0 ] || {
		gb_bs_log "gitbackup restore failed (exit $_gb_bs_rc); the package is installed and the credential in /etc/gitbackup still works -- re-run \`gitbackup restore --device $GB_BS_DEVICE\` by hand once the problem above is fixed"
		exit "$_gb_bs_rc"
	}

	# Steps 5/6: the restore just overwrote /etc/config/gitbackup with the
	# backup's own real configuration -- this is the one thing this script
	# never re-derives, it is what "restored" means. The credential this
	# script wrote in step 3 is untouched by that (hard-exclude, see this
	# file's own header) -- re-checking it now against whatever origin.url
	# the restored config actually names is the whole point of the sharp
	# edge this ticket exists to close.
	gb_bs_log 'confirming the restored configuration still authenticates (gitbackup test)...'
	gitbackup test
	_gb_bs_rc=$?
	if [ "$_gb_bs_rc" -eq 0 ]; then
		gb_bs_log 'done -- the router is back and ready to back itself up again.'
	else
		gb_bs_log "gitbackup test failed AFTER restore (exit $_gb_bs_rc) -- the configuration was restored, but double-check gitbackup.origin.url/branch in the restored /etc/config/gitbackup still matches the credential in /etc/gitbackup"
	fi

	# Step 7.
	gb_bs_propose_reboot

	exit "$_gb_bs_rc"
}

[ "${GB_BOOTSTRAP_SOURCED:-0}" = 1 ] || gb_bs_main "$@"
