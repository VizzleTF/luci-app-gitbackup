#!/bin/sh
# Every POSIX shell script in this repository, derived from the tree by
# extension/shebang -- not typed by hand.
#
# Ticket 15 finding: .github/workflows/ci.yml used to spell the shellcheck
# file list out by hand, and it had drifted -- bootstrap.sh and
# tests/bootstrap/run.sh were both missing from it, and the fifteen
# SC2030/SC2031 warnings the latter carries (the exact class of bug that
# once made this project's own test counter print "0 failed" on real
# failures -- an increment lost across a subshell boundary) passed
# unnoticed as a result. A list built by hand cannot fail to notice a new
# file; a list built from the tree can, by construction.
#
# A file counts if EITHER its name ends in .sh, OR one of its first three
# lines is a `#!.../sh` shebang or a `# shellcheck shell=sh` directive --
# several of this project's own scripts are dot-sourced or router-invoked
# with no extension and no shebang at all (package/gitbackup/files/usr/
# sbin/gitbackup, etc/init.d/gitbackup, etc/uci-defaults/99-gitbackup,
# usr/libexec/rpcd/luci.gitbackup, every usr/share/gitbackup/*.sh module),
# and mark themselves for shellcheck with that directive instead.
#
# .git/, node_modules/ and dist/ (owfeed build output, gitignored, and
# possibly containing a copied .sh under a staged tree) are pruned: none of
# them are this project's own source.
set -eu
cd "$(dirname "$0")/.."

find . \
	\( -path ./.git -o -path ./node_modules -o -path ./.owlab -o -name dist -o -path './package/*/dist' \) -prune -o \
	-type f -print |
while IFS= read -r f; do
	case "$f" in
		*.sh)
			printf '%s\n' "$f"
			continue
			;;
	esac
	# head on a binary file (an .apk, a signature) is harmless, just
	# pointless to grep -- capped to the first 200 bytes so a large binary
	# is never read whole. `grep -a` treats that chunk as text regardless of
	# what it actually is, so a NUL byte inside it cannot make grep silently
	# skip the file as "binary" and report no match either way.
	if head -c 200 "$f" 2>/dev/null | grep -aqE '^#!.*(/|[[:space:]])sh([[:space:]]|$)|^# *shellcheck +shell=sh'; then
		printf '%s\n' "$f"
	fi
done | LC_ALL=C sort
