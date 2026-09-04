#!/bin/sh
# The jsmin gate, wired together: build the pinned jsmin, prove it still
# catches a known-broken file (tests/fixtures/jsmin-broken.js -- ticket 15
# acceptance criterion "Намеренно сломанный тестовый файл гейт валит"), and
# only then run it for real against every shipped view.
#
# The self-check runs FIRST and is not optional: a gate that silently
# stopped catching anything (a jsmin.c that no longer has the bug, a broken
# fixture that stopped triggering it, a jsmin-verify.mjs regression) would
# otherwise look identical to a clean pass on real files -- exactly the
# "полностью зелёный CI" this ticket exists to close.
set -eu
cd "$(dirname "$0")/.."

export RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
JSMIN=$(sh tools/build-jsmin.sh)
export JSMIN

echo '-- self-check: the gate must reject tests/fixtures/jsmin-broken.js --'
if node tools/jsmin-verify.mjs tests/fixtures/jsmin-broken.js >/tmp/jsmin-selfcheck.$$ 2>&1; then
	echo 'jsmin-gate: tests/fixtures/jsmin-broken.js was accepted -- the gate no longer catches the'
	echo 'regex-vs-division bug it exists for (jsmin.c changed, the fixture stopped triggering it,'
	echo 'or jsmin-verify.mjs regressed). See tests/fixtures/jsmin-broken.js for how this was'
	echo 'confirmed live and what the pinned jsmin binary does to it.'
	cat /tmp/jsmin-selfcheck.$$
	rm -f /tmp/jsmin-selfcheck.$$
	exit 1
fi
cat /tmp/jsmin-selfcheck.$$
rm -f /tmp/jsmin-selfcheck.$$
echo '-- self-check passed: the gate does catch it --'
echo

echo '-- the real gate: every shipped view/*.js --'
node tools/jsmin-verify.mjs
