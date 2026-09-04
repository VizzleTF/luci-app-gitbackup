#!/bin/sh
# The real installed footprint of gitbackup + luci-app-gitbackup and their
# dependencies, measured on a live OpenWrt 25.12.4 stand -- not typed by
# hand. Feeds README's own size table (task 16); this script is the one
# place that number is computed, per ticket 15's own acceptance criterion
# ("Размерный бюджет считает реальный размер обоих пакетов с зависимостями
# и питает таблицу README").
#
#   sh tools/size-report.sh <router-id>
#
# Preconditions: <router-id> is already up (`owlab up <router-id>`) on
# release 25.12.4, with NEITHER of this project's own packages installed yet
# -- this script installs both itself, in order, taking a size snapshot
# before each step so the git/git-http delta (spec "Проверенные факты ->
# Размеры": +git pulls libopenssl3, +git-http pulls libcurl4/libnghttp2) is
# visible rather than folded into one final number. dist/noarch/*.apk must
# already be built (tools/stage.sh && owfeed build).
#
# `du -sx /` (excludes bind-mounted pseudo-filesystems -- proc, sys, dev --
# via -x's "stay on one filesystem", same reasoning as measuring a router's
# real flash use rather than the Docker host's) is the actual footprint
# metric; `apk info -s` (named in the brief verbatim) additionally reports
# each of THIS project's own two packages' own installed size, which
# du's whole-filesystem number cannot isolate on its own.
#
# Every `owlab exec` call below is a single, pipe-free command. owlab exec's
# own -c/--config flag collides with a `sh -c '...'` argument handed to it
# (interfaces.md, ticket 03's own finding) -- so every count/sum below
# happens HERE, over plain output already returned to this shell, never via
# a remote shell pipeline.
set -eu
cd "$(dirname "$0")/.."

router="${1:?usage: sh tools/size-report.sh <router-id>}"
OWLAB="${OWLAB:-owlab}"

gb_apk=$(find dist/noarch -maxdepth 1 -name 'gitbackup-*.apk' 2>/dev/null | head -n 1) || true
luci_apk=$(find dist/noarch -maxdepth 1 -name 'luci-app-gitbackup-*.apk' 2>/dev/null | head -n 1) || true
[ -n "$gb_apk" ] || { echo "size-report: no dist/noarch/gitbackup-*.apk -- build first" >&2; exit 1; }
[ -n "$luci_apk" ] || { echo "size-report: no dist/noarch/luci-app-gitbackup-*.apk -- build first" >&2; exit 1; }

_kib() { "$OWLAB" exec "$router" -- du -sx / | awk '{print $1}'; }
_count() { "$OWLAB" exec "$router" -- apk list --installed | wc -l | tr -d ' '; }
_mib() { awk -v kib="$1" 'BEGIN { printf "%.1f", kib / 1024 }'; }

clean_kib=$(_kib); clean_n=$(_count)
"$OWLAB" install "$router" "$gb_apk" >&2
gb_kib=$(_kib); gb_n=$(_count)
"$OWLAB" install "$router" "$luci_apk" >&2
luci_kib=$(_kib); luci_n=$(_count)

gb_own=$("$OWLAB" exec "$router" -- apk info -s gitbackup | sed -n '2p')
luci_own=$("$OWLAB" exec "$router" -- apk info -s luci-app-gitbackup | sed -n '2p')

clean_mib=$(_mib "$clean_kib")
gb_mib=$(_mib "$gb_kib")
luci_mib=$(_mib "$luci_kib")

# Machine-readable copy for whatever generates README's table (task 16) to
# consume without re-parsing the markdown below.
mkdir -p dist
cat >dist/size-report.json <<EOF
{
  "clean": { "mib": $clean_mib, "packages": $clean_n },
  "plus_gitbackup": { "mib": $gb_mib, "packages": $gb_n },
  "plus_luci_app_gitbackup": { "mib": $luci_mib, "packages": $luci_n },
  "gitbackup_own_size": "$gb_own",
  "luci_app_gitbackup_own_size": "$luci_own"
}
EOF

printf '| состояние | установлено |\n'
printf '|---|---|\n'
printf '| чистый образ 25.12.4 | %s MiB / %s пакетов |\n' "$clean_mib" "$clean_n"
printf '| + gitbackup | %s MiB / %s |\n' "$gb_mib" "$gb_n"
printf '| + gitbackup + luci-app-gitbackup | %s MiB / %s |\n' "$luci_mib" "$luci_n"
printf '\ngitbackup installed size (apk info -s): %s\n' "$gb_own"
printf 'luci-app-gitbackup installed size (apk info -s): %s\n' "$luci_own"
printf '\nwrote dist/size-report.json\n'

# The "budget" half of "Размерный бюджет": a generous ceiling, not the exact
# measured number (that varies with the base image and with upstream git/
# libopenssl3/libcurl4 version bumps this project does not control) --
# meant to catch a REGRESSION (an accidentally-added heavy dependency, a
# DEPENDS typo that pulls in something unrelated), not to nag on every
# patch release of git. spec's own measured facts put the full git+git-http
# stack at roughly 38 MiB on a 15.9 MiB base (~22 MiB delta); the ceiling
# below leaves comfortable headroom above that on top of THIS stand's own
# (larger, owlab-fixture-laden) base rather than asserting spec's exact
# numbers against an environment that was never claimed to reproduce them
# byte for byte.
: "${GB_SIZE_BUDGET_MIB:=70}"
over=$(awk -v v="$luci_mib" -v b="$GB_SIZE_BUDGET_MIB" 'BEGIN{print (v>b)?1:0}')
if [ "$over" = 1 ]; then
	echo "" >&2
	echo "size-report: installed footprint is ${luci_mib} MiB, over the ${GB_SIZE_BUDGET_MIB} MiB budget." >&2
	echo "If this is a deliberate dependency addition, raise GB_SIZE_BUDGET_MIB in this script" >&2
	echo "and say what bought it; if not, something pulled in far more than expected." >&2
	exit 1
fi
