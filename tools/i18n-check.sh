#!/bin/sh
# i18n sync gate (ticket 15 acceptance criterion: "`.pot` не разошёлся с
# исходниками, `po/ru` не отстал").
#
# po/templates/gitbackup.pot and po/ru/gitbackup.po are a LATER ticket's own
# files (spec "Упаковка": applications/luci-app-gitbackup/po/templates/
# gitbackup.pot, po/ru/gitbackup.po -- neither exists as this ticket is
# written). This script has exactly two honest outcomes when they are
# missing: say so and exit 0 (there is nothing yet to have drifted), never
# silently "pass" as if a real check ran, and never fail a build for a file
# a different ticket owns creating.
#
# Once they exist, this regenerates the .pot from source with the SAME tool
# luci.mk itself uses -- openwrt/luci's own build/i18n-scan.pl, pinned and
# checksummed in tools/luci-upstream.pin exactly like jsmin.c -- and:
#   1. diffs the regenerated .pot's msgids against the committed one (a
#      string added or removed in a view/*.js without rerunning the
#      extraction is exactly "разошёлся с исходниками");
#   2. runs msgcmp against every po/<lang>/gitbackup.po found, which fails
#      when the .po is missing a msgid the .pot has (a string that would
#      silently render in English) -- msgcmp, not a byte-diff, because a
#      translated msgstr changing is not staleness.
set -eu
cd "$(dirname "$0")/.."

APP=applications/luci-app-gitbackup
POT="$APP/po/templates/gitbackup.pot"

if [ ! -f "$POT" ]; then
	echo "i18n-check: $POT does not exist yet (a later ticket adds it) -- nothing to check."
	echo "i18n-check: this is NOT a verified pass, only an honest skip."
	exit 0
fi

for tool in perl xgettext msgcmp; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "i18n-check: $tool not found (install perl + gettext)" >&2
		exit 1
	}
done

# shellcheck disable=SC1091
. ./tools/luci-upstream.pin
: "${RUNNER_TEMP:=${TMPDIR:-/tmp}}"

scanner="$RUNNER_TEMP/gitbackup-i18n-scan.pl"
curl -fsSL --proto '=https' --proto-redir '=https' -o "$scanner" \
	"https://raw.githubusercontent.com/openwrt/luci/$LUCI_PIN/build/i18n-scan.pl"
echo "$I18N_SCAN_SHA256  $scanner" | sha256sum -c - >&2
chmod +x "$scanner"

fresh_pot="$RUNNER_TEMP/gitbackup-fresh.pot"
# i18n-scan.pl scans a whole directory tree by extension (.js among them,
# per its own %keywords table) and writes one combined .pot to stdout.
#
# Ticket 22: this used to scan only "$APP/htdocs" -- which meant every menu
# title in root/usr/share/luci/menu.d and every ACL description in
# root/usr/share/rpcd/acl.d was silently invisible to this whole gate, even
# though i18n-scan.pl's own %keywords table (confirmed against the real
# openwrt/luci checkout, build/i18n-sync.sh: `./build/i18n-scan.pl "$dir"`
# with $dir the WHOLE package, not one subdirectory) explicitly extracts
# "title"/"description" from exactly those two paths (preprocess_json's own
# `s/("(?:title|description)")\s*:\s*(...)/$1: _($2)/`). Scanning only
# "$APP" (the whole package) instead is what real luci.mk tooling actually
# does, and it is the only way a renamed tab (ticket 22's own "Название
# живёт в menu.d, и его же надо провести через po/ru") can ever be
# something this gate verifies rather than something nobody ever checks.
perl "$scanner" "$APP" >"$fresh_pot"

# msgids only, sorted -- comparing the whole file would also flag a changed
# comment/line-number or a reordered entry, neither of which is "drifted
# from sources". POT-Creation-Date and other header noise never reach this
# extraction, since it looks only at msgid lines.
#
# A gettext .pot wraps a long msgid across several lines -- `msgid ""`
# followed by one bare-quoted continuation line per fragment, no "msgid"
# keyword on those lines. A plain `s/^msgid "\(.*\)"$/\1/` (what used to be
# here) only matches the first line, capturing an empty string, and never
# looks at the continuation lines at all -- so a reworded multi-line string
# collapses to the same "" for both the fresh and the committed .pot as long
# as the *count* of multi-line entries did not change, and the comparison
# below passes on a wording change it never actually read. This awk instead
# tracks an in_msgid flag across lines and concatenates every bare-quoted
# line that follows a `msgid "..."` line into one string before printing it,
# so a multi-line reword changes what gets compared, not just what gets
# printed.
extract_msgids() {
	awk '
		/^msgid "/ {
			id = $0
			sub(/^msgid "/, "", id)
			sub(/"$/, "", id)
			in_msgid = 1
			next
		}
		in_msgid && /^"/ {
			line = $0
			sub(/^"/, "", line)
			sub(/"$/, "", line)
			id = id line
			next
		}
		in_msgid {
			print id
			in_msgid = 0
		}
		END { if (in_msgid) print id }
	' "$1" | sort
}

fresh_ids=$(extract_msgids "$fresh_pot")
committed_ids=$(extract_msgids "$POT")

if [ "$fresh_ids" != "$committed_ids" ]; then
	echo "i18n-check: $POT is STALE -- a translatable string was added, removed or" >&2
	echo "reworded in applications/luci-app-gitbackup/htdocs/**/*.js without" >&2
	echo "regenerating the .pot. Diff (missing from the committed .pot on the left," >&2
	echo "extra in it on the right):" >&2
	printf '%s\n' "$fresh_ids" >"$RUNNER_TEMP/gitbackup-fresh-ids.$$"
	printf '%s\n' "$committed_ids" >"$RUNNER_TEMP/gitbackup-committed-ids.$$"
	diff "$RUNNER_TEMP/gitbackup-fresh-ids.$$" "$RUNNER_TEMP/gitbackup-committed-ids.$$" >&2 || true
	rm -f "$RUNNER_TEMP/gitbackup-fresh-ids.$$" "$RUNNER_TEMP/gitbackup-committed-ids.$$"
	exit 1
fi
echo "i18n-check: $POT matches the source strings ($(printf '%s\n' "$fresh_ids" | grep -c . || true) msgid(s))."

found_po=0
for po in "$APP"/po/*/gitbackup.po; do
	[ -f "$po" ] || continue
	found_po=1
	lang=$(basename "$(dirname "$po")")
	if msgcmp "$po" "$fresh_pot" >/tmp/gitbackup-msgcmp.$$ 2>&1; then
		echo "i18n-check: po/$lang/gitbackup.po covers every current msgid."
	else
		echo "i18n-check: po/$lang/gitbackup.po is STALE -- missing or extra msgid(s)" >&2
		echo "against the current source strings; the missing ones render in English" >&2
		echo "silently instead of failing loudly. msgcmp output:" >&2
		cat /tmp/gitbackup-msgcmp.$$ >&2
		rm -f /tmp/gitbackup-msgcmp.$$
		exit 1
	fi
	rm -f /tmp/gitbackup-msgcmp.$$
done

if [ "$found_po" -eq 0 ]; then
	echo "i18n-check: no po/*/gitbackup.po yet -- nothing to check there, .pot is in sync."
fi
