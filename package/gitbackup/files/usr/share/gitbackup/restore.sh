# shellcheck shell=sh
#
# gitbackup -- Path 2 restore, applying a backup set straight back onto the
# filesystem (spec "Восстановление"). This is the module that makes
# manifest.json's mode/uid/gid/target fields matter: git stores none of
# them, so a plain checkout of files/ would hand back /etc/shadow at
# whatever mode git happens to give a new file (world-readable) and every
# dropbear host key owned by whoever ran the restore -- a router that
# LOOKS restored but that dropbear and login refuse to trust.
#
# Exposes gb_restore; every _gb_restore_-prefixed helper below is private
# and namespaced by module, same convention every other module here uses
# (all of *.sh end up sourced into one process by usr/sbin/gitbackup, so a
# bare _gb_ helper name could collide with a sibling module's). Sourced,
# never executed: nothing here runs at load time.
#
# Depends on lib.sh (gb_log, gb_uci_get, gb_json_str is NOT used here --
# see this file's own JSON readers below) and gitio.sh (gb_remote_head,
# gb_fetch_meta) already being sourced by the caller -- restore reuses
# gitio.sh's own proven fetch machinery (a NAMED "origin" remote, a
# --filter=blob:none fetch) for the common case instead of re-deriving it.
# Does NOT depend on collect.sh or device.sh: the device being restored is
# whatever the caller passes as an argument, never gb_device_id's own
# resolution -- a fresh/bare router calling `gitbackup restore --device D`
# has, by construction, no working device_id config yet (bootstrap's own
# Path 1 step 4 runs this before the restored gitbackup.main.device_id even
# exists on disk), so gb_expand's automatic gb_device_id() call cannot be
# reused here; _gb_restore_expand below is a deliberate, small duplicate of
# gb_expand's substitution loop that takes the device explicitly instead.
#
# GB_ROOT overrides the filesystem root every write and every real-path
# read goes through (default '', meaning the actual '/') -- the same seam
# collect.sh's GB_ROOT already is, so a test can point this at a fixture
# tree instead of the host filesystem and collect_fixture-shaped setups
# apply unchanged. GB_URL is read from the environment, not taken as an
# argument -- same convention gitio.sh/visibility.sh use for config context
# the CLI already resolved once.

GB_ROOT="${GB_ROOT:-}"

# gb_restore <device> <commit-or-empty> [--dry-run] [--force] [--yes] [--with-packages]
#
# <commit-or-empty> is "" or "HEAD" for the branch's current tip (the
# common case, and the only one bootstrap's Path 1 ever uses); anything
# else is fetched as a specific historical commit, which needs the whole
# branch's history (not gb_fetch_meta's own --depth=1) to be reachable at
# all -- still only THIS device's one branch, never every branch in the
# repository, so "полного клона не появляется" holds either way.
#
# Returns 0 on success, 1 on a general failure (sha256 mismatch, missing
# manifest, declined confirmation), 2 on a bad argument, 3 on network/auth,
# 4 refused for safety (board mismatch without --force) -- the same
# four-code contract every other module here already answers to
# (interfaces.md, "Коды выхода"); usr/sbin/gitbackup's cmd_restore is what
# turns this into the process's actual exit code.
gb_restore() {
	_gb_device="$1"
	_gb_commit="${2:-}"
	shift 2

	_gb_dry=0
	_gb_force=0
	_gb_yes=0
	_gb_wp=0
	for _gb_flag in "$@"; do
		case "$_gb_flag" in
			--dry-run) _gb_dry=1 ;;
			--force) _gb_force=1 ;;
			--yes) _gb_yes=1 ;;
			--with-packages) _gb_wp=1 ;;
		esac
	done

	[ -n "$_gb_device" ] || { gb_log err 'gb_restore: device is required'; return 2; }
	: "${GB_URL:?gb_restore: GB_URL is not set}"

	_gb_branch=$(_gb_restore_expand "$(gb_uci_get gitbackup.origin.branch 'device/{device}')" "$_gb_device")
	_gb_prefix=$(_gb_restore_expand "$(gb_uci_get gitbackup.main.path_prefix 'devices/{device}')" "$_gb_device")

	# Everything from here lives under /tmp, same rule cmd_run's own WORK
	# follows (never flash, never USB) -- trap fires when THIS PROCESS (or
	# the caller's subshell, in a test) exits, not when this function
	# returns, so every early `return` below needs no manual cleanup of
	# its own, same convention cmd_run's scattered gb_die calls already
	# rely on.
	_gb_work=$(mktemp -d "${TMPDIR:-/tmp}/gitbackup-restore.XXXXXX") ||
		{ gb_log err 'gb_restore: cannot create a work directory under /tmp'; return 1; }
	trap 'rm -rf "$_gb_work"' EXIT INT TERM
	_gb_repodir="$_gb_work/repo"

	if [ -z "$_gb_commit" ] || [ "$_gb_commit" = HEAD ]; then
		_gb_tip=$(gb_remote_head "$_gb_branch")
		_gb_tip_rc=$?
		[ "$_gb_tip_rc" -eq 0 ] || return 3
		if [ -z "$_gb_tip" ]; then
			gb_log err "gb_restore: $_gb_branch does not exist on $GB_URL yet -- nothing to restore"
			return 1
		fi
		gb_fetch_meta "$_gb_branch" "$_gb_repodir" || return 3
		_gb_target="$_gb_tip"
	else
		# A specific past commit needs the branch's full history to be
		# reachable at all -- gb_fetch_meta's own --depth=1 (gitio.sh,
		# tuned for `run`'s own "just the tip" need) cannot reach it, so
		# this repeats gb_fetch_meta's init/remote-add shape without the
		# depth limit rather than changing gitio.sh's contract for a case
		# it was never meant to serve. Still one branch, not the
		# repository: "минимально: своя ветка, нужный коммит" (spec).
		mkdir -p "$_gb_repodir"
		git init -q "$_gb_repodir" || return 1
		git -C "$_gb_repodir" remote get-url origin >/dev/null 2>&1 ||
			git -C "$_gb_repodir" remote add origin "$GB_URL" 2>/dev/null
		_gb_fe=$(git -C "$_gb_repodir" fetch -q --filter=blob:none origin "$_gb_branch" 2>&1)
		_gb_fe_rc=$?
		if [ "$_gb_fe_rc" -ne 0 ]; then
			gb_log err "gb_restore: git fetch $GB_URL $_gb_branch failed: $_gb_fe"
			return 3
		fi
		_gb_target="$_gb_commit"
	fi

	if ! git -C "$_gb_repodir" cat-file -e "$_gb_target^{commit}" 2>/dev/null; then
		gb_log err "gb_restore: commit $_gb_target was not found on $_gb_branch at $GB_URL"
		return 1
	fi

	# The one checkout call this whole module needs: a pathspec-scoped
	# `checkout <commit> -- <path>` reads only $_gb_prefix's own tree from
	# $_gb_target and lazily fetches only the blobs under it (the
	# --filter=blob:none fetch above already marked this remote a
	# promisor, same mechanism gitio.sh's own gb_fetch_meta comment
	# documents for `cat-file -p`) -- this is "sparse на devices/<D>/"
	# without needing git's separate sparse-checkout feature at all.
	_gb_co_err=$(git -C "$_gb_repodir" checkout -q "$_gb_target" -- "$_gb_prefix" 2>&1)
	_gb_co_rc=$?
	if [ "$_gb_co_rc" -ne 0 ] || [ ! -d "$_gb_repodir/$_gb_prefix" ]; then
		gb_log err "gb_restore: could not read $_gb_prefix from $_gb_target on $_gb_branch: $_gb_co_err"
		return 1
	fi

	_gb_srcroot="$_gb_repodir/$_gb_prefix"
	_gb_manifest="$_gb_srcroot/manifest.json"
	if [ ! -r "$_gb_manifest" ]; then
		gb_log err "gb_restore: $_gb_prefix/manifest.json missing at $_gb_target -- nothing to restore"
		return 1
	fi

	_gb_restore_check_board "$_gb_srcroot/meta/board.json" "$_gb_force"
	_gb_board_rc=$?
	[ "$_gb_board_rc" -eq 0 ] || return "$_gb_board_rc"

	_gb_restore_check_release "$_gb_srcroot/meta/os-release.txt"

	# The whole point of this module: not one byte reaches GB_ROOT until
	# every file's content is proven correct against the manifest.
	_gb_restore_verify_sha "$_gb_srcroot/files" "$_gb_manifest" || return 1

	if [ "$_gb_dry" -eq 1 ]; then
		_gb_restore_print_plan "$_gb_manifest"
		return 0
	fi

	if [ "$_gb_yes" -ne 1 ]; then
		_gb_restore_print_plan "$_gb_manifest" >&2
		printf 'Restore %s from %s onto this router? [y/N] ' "$_gb_device" "$_gb_target" >&2
		IFS= read -r _gb_ans
		case "$_gb_ans" in
			y|Y|yes|YES) ;;
			*) gb_log notice 'gb_restore: declined by the operator'; return 1 ;;
		esac
	fi

	# Files first (content only), THEN mode/uid/gid/empty-dirs/symlinks in
	# a second pass (spec: "разложить файлы, затем применить mode/uid/gid,
	# создать пустые каталоги, пересоздать симлинки") -- content and
	# ownership are deliberately two passes, not interleaved per entry.
	_gb_restore_write_files "$_gb_srcroot/files" "$_gb_manifest" ||
		{ gb_log err 'gb_restore: writing one or more files failed'; return 1; }
	_gb_restore_apply_perms "$_gb_manifest"

	_gb_restore_print_scrubbed "$_gb_manifest"

	[ "$_gb_wp" -eq 1 ] && _gb_restore_packages "$_gb_srcroot/meta"

	gb_log notice "gb_restore: restored $_gb_device from $_gb_target on $_gb_branch"
	printf 'restored %s from %s\n' "$_gb_device" "$_gb_target"
	return 0
}

# _gb_restore_expand <template> <device> -- gb_expand's own substitution
# loop (device.sh), duplicated rather than reused: gb_expand always
# resolves {device} through gb_device_id() itself, which is exactly what
# this module must NOT do (see this file's header). Kept in lockstep with
# gb_expand by inspection -- the loop body is identical on purpose.
_gb_restore_expand() {
	_gb_tpl="$1"
	_gb_dev="$2"
	_gb_out=''
	_gb_rest="$_gb_tpl"
	while true; do
		case "$_gb_rest" in
			*'{device}'*)
				_gb_out="$_gb_out${_gb_rest%%\{device\}*}$_gb_dev"
				_gb_rest="${_gb_rest#*\{device\}}"
				;;
			*)
				_gb_out="$_gb_out$_gb_rest"
				break
				;;
		esac
	done
	printf '%s\n' "$_gb_out"
}

# _gb_restore_check_board <old-board.json> <force> -- 0 (match, or --force
# overrode a mismatch) or 4 (refused). Compares "model" (the field
# device.sh's own board strategy already reads, and the one confirmed
# `null` on generic/armsr targets -- spec: "Поле board бывает null...
# Это не дефект") and "release.target" (the actual build target, e.g.
# "mediatek/filogic" -- present even when model is not, so it is what
# actually catches a generic-target-to-generic-target restore across
# genuinely different hardware that model alone would wave through as
# "both null, must match").
#
# Confirmed live on the owlab 25.12.4 armsr/armv8 stand: `ubus call system
# board` there has no "model" key at all (this target's own real-world
# instance of "Поле board бывает null" -- not a fixture assumption) and
# does have "release": {"target": "armsr/armv8", ...}; the real jsonfilter
# parses that pretty-printed, multi-line, tab-indented object correctly
# with `-e '@.release.target'` -- confirmed against the real binary, not
# just this suite's flat-JSON test stub.
_gb_restore_check_board() {
	_gb_old_board="$1"
	_gb_force="$2"
	if [ ! -r "$_gb_old_board" ]; then
		gb_log warning 'gb_restore: no meta/board.json in this backup, skipping the board check'
		return 0
	fi
	_gb_old_json=$(cat "$_gb_old_board")
	_gb_new_json=$(ubus call system board 2>/dev/null)
	_gb_old_model=$(printf '%s' "$_gb_old_json" | jsonfilter -e '@.model' 2>/dev/null)
	_gb_new_model=$(printf '%s' "$_gb_new_json" | jsonfilter -e '@.model' 2>/dev/null)
	_gb_old_target=$(printf '%s' "$_gb_old_json" | jsonfilter -e '@.release.target' 2>/dev/null)
	_gb_new_target=$(printf '%s' "$_gb_new_json" | jsonfilter -e '@.release.target' 2>/dev/null)

	if [ "$_gb_old_model" = "$_gb_new_model" ] && [ "$_gb_old_target" = "$_gb_new_target" ]; then
		return 0
	fi
	if [ "$_gb_force" -eq 1 ]; then
		gb_log notice "gb_restore: board mismatch (model '$_gb_old_model' -> '$_gb_new_model', target '$_gb_old_target' -> '$_gb_new_target'), proceeding: --force"
		return 0
	fi
	gb_log err "gb_restore: this backup was taken on a different board (model '$_gb_old_model' vs '$_gb_new_model', target '$_gb_old_target' vs '$_gb_new_target') -- interface names and wireless radios from that hardware will not match this one; pass --force to restore anyway"
	return 4
}

# _gb_restore_check_release <old-os-release.txt> -- a major-version
# mismatch is a warning, never a refusal (spec: "Расхождение os-release.txt
# в мажорной версии -> предупреждение, не отказ"). Missing/unparsable data
# on either side is silently skipped, not a warning of its own -- an old
# backup predating this field, or a target with no /etc/os-release at all,
# is not itself evidence of anything wrong.
_gb_restore_check_release() {
	_gb_old_rel="$1"
	[ -r "$_gb_old_rel" ] || return 0
	_gb_old_ver=$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$_gb_old_rel" | head -n 1)
	_gb_new_ver=''
	[ -r "${GB_ROOT:-}/etc/os-release" ] &&
		_gb_new_ver=$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${GB_ROOT:-}/etc/os-release" | head -n 1)
	[ -n "$_gb_old_ver" ] && [ -n "$_gb_new_ver" ] || return 0
	_gb_old_major="${_gb_old_ver%%.*}"
	_gb_new_major="${_gb_new_ver%%.*}"
	if [ "$_gb_old_major" != "$_gb_new_major" ]; then
		gb_log warning "gb_restore: this backup was taken on OpenWrt $_gb_old_ver, this router runs $_gb_new_ver -- config options from a different major release may not apply cleanly"
	fi
	return 0
}

# _gb_restore_json_str <object> <field> -- <field>'s quoted string value
# out of one manifest entry object, unescaped for \" and \\ (the only two
# escapes gb_json_esc, collect.sh's own writer, ever produces for a
# filesystem path or symlink target -- newlines/tabs/CR do not occur in
# either). Empty when the field is absent or JSON null.
_gb_restore_json_str() {
	_gb_js_obj="$1"
	_gb_js_field="$2"
	case "$_gb_js_obj" in
		*'"'"$_gb_js_field"'":"'*)
			_gb_js_v="${_gb_js_obj#*\""$_gb_js_field"\":\"}"
			_gb_js_v="${_gb_js_v%%\"*}"
			printf '%s' "$_gb_js_v" | sed 's/\\"/"/g; s/\\\\/\\/g'
			;;
		*) printf '' ;;
	esac
}

# _gb_restore_json_num <object> <field> -- an unquoted numeric field's raw
# text (mode/uid/gid). Empty when absent, never "0": unlike collect.sh's
# own _gb_collect_json_num (which needs SOME digit to keep the manifest
# valid JSON), a missing mode/uid/gid here must not silently become chmod/
# chown 0 -- the caller skips the operation instead.
_gb_restore_json_num() {
	_gb_jn_obj="$1"
	_gb_jn_field="$2"
	case "$_gb_jn_obj" in
		*'"'"$_gb_jn_field"'":'*)
			_gb_jn_v="${_gb_jn_obj#*\""$_gb_jn_field"\":}"
			_gb_jn_v="${_gb_jn_v%%[,\}]*}"
			printf '%s' "$_gb_jn_v"
			;;
		*) printf '' ;;
	esac
}

# _gb_restore_each_entry <manifest.json> <callback> -- calls
# "<callback> <json-object>" once per entries[] item, the object
# unindented and with its trailing comma (if any) already stripped -- the
# same one-object-per-line, no-nested-brackets shape collect.sh's own
# gb_manifest_equal already relies on. Reads the file via a plain
# redirect, not a pipe: POSIX sh only forks a subshell for the pipe form,
# so a callback's own global-variable accumulation (e.g.
# _gb_restore_verify_sha's _gb_sha_bad) survives the loop here, unlike
# collect.sh's _gb_collect_files, which has to write to a file instead for
# exactly that reason.
_gb_restore_each_entry() {
	_gb_re_manifest="$1"
	_gb_re_cb="$2"
	_gb_re_in=0
	while IFS= read -r _gb_re_line || [ -n "$_gb_re_line" ]; do
		case "$_gb_re_line" in
			'  "entries": ['*) _gb_re_in=1; continue ;;
			'  ],') _gb_re_in=0; continue ;;
		esac
		[ "$_gb_re_in" -eq 1 ] || continue
		_gb_re_obj="${_gb_re_line%,}"
		_gb_re_obj="${_gb_re_obj#    }"
		[ -n "$_gb_re_obj" ] || continue
		"$_gb_re_cb" "$_gb_re_obj"
	done <"$_gb_re_manifest"
}

# gb_restore's own hard gate: computes _gb_sha_bad (space-separated bad
# paths) via _gb_restore_verify_sha_one, then refuses as a whole if
# anything mismatched. _gb_srcfiles is set right before the each_entry
# call and consumed only inside it -- a temporary, not a public seam.
_gb_restore_verify_sha() {
	_gb_srcfiles="$1"
	_gb_manifest="$2"
	_gb_sha_bad=''
	_gb_restore_each_entry "$_gb_manifest" _gb_restore_verify_sha_one
	if [ -n "$_gb_sha_bad" ]; then
		gb_log err "gb_restore: sha256 mismatch, refusing to write anything to disk:$_gb_sha_bad"
		return 1
	fi
	return 0
}

_gb_restore_verify_sha_one() {
	_gb_obj="$1"
	case "$_gb_obj" in
		*'"type":"file"'*) ;;
		*) return 0 ;;
	esac
	_gb_path=$(_gb_restore_json_str "$_gb_obj" path)
	_gb_want=$(_gb_restore_json_str "$_gb_obj" sha256)
	_gb_got=$(sha256sum "$_gb_srcfiles$_gb_path" 2>/dev/null | awk '{print $1}')
	[ -n "$_gb_got" ] && [ "$_gb_got" = "$_gb_want" ] || _gb_sha_bad="$_gb_sha_bad $_gb_path"
}

# _gb_restore_print_plan <manifest.json> -- --dry-run's own output, and
# also what the interactive confirmation prompt shows before asking. Marks
# each path "overwrite" (something is already there at GB_ROOT) or
# "create" (nothing is), which is what "печатает, что будет перезаписано"
# actually needs to be useful, not just a bare path list.
_gb_restore_print_plan() {
	_gb_manifest="$1"
	printf 'The following paths will be written:\n'
	_gb_restore_each_entry "$_gb_manifest" _gb_restore_plan_one
}

_gb_restore_plan_one() {
	_gb_obj="$1"
	_gb_type=$(_gb_restore_json_str "$_gb_obj" type)
	_gb_path=$(_gb_restore_json_str "$_gb_obj" path)
	_gb_dest="${GB_ROOT:-}$_gb_path"
	if [ -e "$_gb_dest" ] || [ -L "$_gb_dest" ]; then
		printf '  overwrite %s (%s)\n' "$_gb_path" "$_gb_type"
	else
		printf '  create    %s (%s)\n' "$_gb_path" "$_gb_type"
	fi
}

# _gb_restore_write_files <srcfiles> <manifest.json> -- pass 1: file
# CONTENT only, no mode/uid/gid yet (_gb_restore_apply_perms is pass 2).
# Only reached after _gb_restore_verify_sha has already confirmed every
# file's hash, so a failure here is an I/O problem (disk full, a path
# collision with an existing directory), not a data-integrity one.
_gb_restore_write_files() {
	_gb_srcfiles="$1"
	_gb_manifest="$2"
	_gb_write_failed=''
	_gb_restore_each_entry "$_gb_manifest" _gb_restore_write_one
	[ -z "$_gb_write_failed" ]
}

_gb_restore_write_one() {
	_gb_obj="$1"
	case "$_gb_obj" in
		*'"type":"file"'*) ;;
		*) return 0 ;;
	esac
	_gb_path=$(_gb_restore_json_str "$_gb_obj" path)
	_gb_dest="${GB_ROOT:-}$_gb_path"
	mkdir -p "$(dirname "$_gb_dest")" || { _gb_write_failed=1; return 1; }
	# -f: busybox cp (unlike GNU/BSD cp) refuses an existing destination
	# outright ("File exists") without it -- found live on the owlab
	# stand restoring over /etc/hosts, not caught by any host-side test
	# since macOS/GNU cp both overwrite by default with no flag at all.
	cp -f "$_gb_srcfiles$_gb_path" "$_gb_dest" || { _gb_write_failed=1; return 1; }
}

# _gb_restore_apply_perms <manifest.json> -- pass 2: mode/uid/gid for
# files and directories, empty directories created outright (they have no
# content of their own to have been written in pass 1), symlinks created
# from scratch (their "content" IS the target string, never copied as a
# file -- collect.sh's own R24.1 comment on the same asymmetry).
_gb_restore_apply_perms() {
	_gb_manifest="$1"
	_gb_restore_each_entry "$_gb_manifest" _gb_restore_perm_one
}

_gb_restore_perm_one() {
	_gb_obj="$1"
	_gb_type=$(_gb_restore_json_str "$_gb_obj" type)
	_gb_path=$(_gb_restore_json_str "$_gb_obj" path)
	_gb_mode=$(_gb_restore_json_num "$_gb_obj" mode)
	_gb_uid=$(_gb_restore_json_num "$_gb_obj" uid)
	_gb_gid=$(_gb_restore_json_num "$_gb_obj" gid)
	_gb_dest="${GB_ROOT:-}$_gb_path"

	case "$_gb_type" in
		dir)
			mkdir -p "$_gb_dest" 2>/dev/null
			[ -n "$_gb_mode" ] && chmod "$_gb_mode" "$_gb_dest" 2>/dev/null
			[ -n "$_gb_uid" ] && [ -n "$_gb_gid" ] && chown "$_gb_uid:$_gb_gid" "$_gb_dest" 2>/dev/null
			;;
		symlink)
			# _gb_symtarget, NOT _gb_target: found live on the owlab stand --
			# gb_restore's own outer scope holds the commit sha being
			# restored in a variable of that exact name (no `local` anywhere
			# in this codebase, interfaces.md's own convention), and this
			# helper runs from inside gb_restore's own call chain
			# (_gb_restore_apply_perms -> _gb_restore_each_entry -> here) --
			# reusing _gb_target here clobbered it, so the FINAL "restored
			# <device> from <commit>" message printed the last symlink's
			# target string instead of the commit sha whenever the backup
			# set contained even one symlink. The restore itself was
			# unaffected (this ran after every actual write), only the
			# closing report was wrong.
			_gb_symtarget=$(_gb_restore_json_str "$_gb_obj" target)
			mkdir -p "$(dirname "$_gb_dest")" 2>/dev/null
			rm -f "$_gb_dest" 2>/dev/null
			ln -s "$_gb_symtarget" "$_gb_dest" 2>/dev/null
			# -h: change the symlink's own ownership, not the (possibly
			# dangling, e.g. /etc/resolv.conf) target's -- busybox chown
			# documents -h for exactly this. Mode is never set on a
			# symlink: Linux always reports lstat mode 0777 for one
			# regardless of chmod, so a freshly `ln -s`'d link already
			# matches whatever collect.sh recorded (it read the same
			# lstat mode the same way). Confirmed live on the owlab
			# 25.12.4 stand: chown -h on this busybox actually changes
			# the symlink's own uid/gid, not a dangling target's.
			[ -n "$_gb_uid" ] && [ -n "$_gb_gid" ] && chown -h "$_gb_uid:$_gb_gid" "$_gb_dest" 2>/dev/null
			;;
		file)
			[ -n "$_gb_mode" ] && chmod "$_gb_mode" "$_gb_dest" 2>/dev/null
			[ -n "$_gb_uid" ] && [ -n "$_gb_gid" ] && chown "$_gb_uid:$_gb_gid" "$_gb_dest" 2>/dev/null
			;;
	esac
}

# _gb_restore_print_scrubbed <manifest.json> -- prints scrubbed[]'s option
# paths to stderr (informational for the operator, same stream
# gb_accept_hostkey's own prompts use), one per line, with a header only
# once and only if there is at least one. Silent when scrubbed[] is empty
# -- a private backup restoring cleanly should say nothing extra.
_gb_restore_print_scrubbed() {
	_gb_manifest="$1"
	_gb_scrub_in=0
	_gb_scrub_any=0
	while IFS= read -r _gb_line || [ -n "$_gb_line" ]; do
		case "$_gb_line" in
			'  "scrubbed": ['*) _gb_scrub_in=1; continue ;;
			'  ]')
				[ "$_gb_scrub_in" -eq 1 ] && _gb_scrub_in=0
				continue
				;;
		esac
		[ "$_gb_scrub_in" -eq 1 ] || continue
		_gb_obj="${_gb_line%,}"
		_gb_obj="${_gb_obj#    }"
		[ -n "$_gb_obj" ] || continue
		_gb_opt=$(_gb_restore_json_str "$_gb_obj" option)
		[ -n "$_gb_opt" ] || continue
		if [ "$_gb_scrub_any" -eq 0 ]; then
			printf 'The following values were redacted before this backup was pushed -- enter them by hand:\n' >&2
			_gb_scrub_any=1
		fi
		printf '  %s\n' "$_gb_opt" >&2
	done <"$_gb_manifest"
	return 0
}

# _gb_restore_packages <meta-dir> -- --with-packages, best-effort (spec:
# "apk add по installed_packages.txt best-effort, в конце напечатать
# список неустановившегося"). Package names come from the `{origin}`
# group `apk list --installed` itself prints (meta/installed_packages.txt
# is that command's own full-line output, per collect.sh's own comment) --
# not from splitting the leading "name-version" token, which is exactly
# the fragile parse the spec warns against (a version string can itself
# contain a dash where the name also could). Restores repositories.txt
# first so a custom feed's own packages have somewhere to come from.
_gb_restore_packages() {
	_gb_meta="$1"
	_gb_repos="$_gb_meta/repositories.txt"
	if [ -s "$_gb_repos" ]; then
		mkdir -p "${GB_ROOT:-}/etc/apk/repositories.d" 2>/dev/null
		cp "$_gb_repos" "${GB_ROOT:-}/etc/apk/repositories.d/gitbackup-restored.list" 2>/dev/null
	fi

	_gb_installed="$_gb_meta/installed_packages.txt"
	[ -r "$_gb_installed" ] || return 0

	_gb_pkg_failed=''
	while IFS= read -r _gb_line || [ -n "$_gb_line" ]; do
		_gb_pkg=$(printf '%s\n' "$_gb_line" | sed -n 's/.*{\([^}]*\)}.*/\1/p')
		[ -n "$_gb_pkg" ] || continue
		apk add "$_gb_pkg" >/dev/null 2>&1 || _gb_pkg_failed="$_gb_pkg_failed $_gb_pkg"
	done <"$_gb_installed"

	if [ -n "$_gb_pkg_failed" ]; then
		printf 'the following packages could not be reinstalled automatically, add them by hand:%s\n' "$_gb_pkg_failed"
	fi
	return 0
}
