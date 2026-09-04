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
perl "$scanner" "$APP/htdocs" >"$fresh_pot"

# msgids only, sorted -- comparing the whole file would also flag a changed
# comment/line-number or a reordered entry, neither of which is "drifted
# from sources". POT-Creation-Date and other header noise never reach this
# extraction, since it looks only at msgid lines.
extract_msgids() {
	sed -n 's/^msgid "\(.*\)"$/\1/p' "$1" | sort
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
