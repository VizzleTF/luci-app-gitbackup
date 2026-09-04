// gitbackup -- unit tests for history.js's pure helpers: diff parsing,
// gbBoardMismatch and the restore-log terminal-line regex (ticket 15's own
// acceptance criterion: "Юнит-тесты на JS... history.js, единственный
// экран, необратимо перезаписывающий файловую систему роутера... разбор
// диффа, регэксп терминальной строки лога"). Scoped to exactly those three
// seams, named in the ticket -- not "all of history.js".
//
// Run: node --test tests/history_view.test.mjs
//
// history.js is never imported directly (see tests/lib/extract_luci_view.mjs
// for why); each function's exact source is pulled out of the real file and
// evaluated on its own, so this tests the byte-for-byte shipped
// implementation. Expected values below are worked out BY HAND against
// git's own documented unified-diff shape and against restore.sh's/
// history.js's own comments on which two board.json fields matter
// (_gb_restore_check_board: "model", "release.target") -- never by calling
// the function under test to produce its own expectation.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { extractFunctionSource, extractVarStatement } from './lib/extract_luci_view.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const HISTORY_PATH = join(__dirname, '..', 'applications', 'luci-app-gitbackup',
	'htdocs', 'luci-static', 'resources', 'view', 'gitbackup', 'history.js');

function loadHelpers() {
	const src = readFileSync(HISTORY_PATH, 'utf8');
	const fns = [
		'gbDiffSections', 'gbSectionPath', 'gbSectionStatus', 'gbDiffFileList',
		'gbBoardMismatch', 'gbFilesPath', 'gbRestorePlan', 'gbRestoreLogSuccess',
		'gbClassifyRestoreLog', 'gbRestoreSeverity'
	];
	const body = fns.map((n) => extractFunctionSource(src, n)).join('\n')
		+ '\n' + extractVarStatement(src, 'GB_RESTORE_TERMINAL_RE')
		+ '\nfunction _(s) { return s; }' // gbClassifyRestoreLog's own messages go through LuCI's gettext _() -- a plain passthrough here, same convention this file already needs none of otherwise (its extracted functions carry no user-facing text of their own).
		+ '\nreturn { gbDiffSections, gbSectionPath, gbSectionStatus, gbDiffFileList, '
		+ 'gbBoardMismatch, gbFilesPath, gbRestorePlan, gbRestoreLogSuccess, '
		+ 'gbClassifyRestoreLog, gbRestoreSeverity, GB_RESTORE_TERMINAL_RE };';
	// eslint-disable-next-line no-new-func
	return new Function(body)();
}

const H = loadHelpers();

// A plain two-file `git diff` -- one modified config, one newly added file.
// (spec "Формат коммита": the tree under a device's branch is
// devices/<id>/files/<real path>, devices/<id>/meta/*, manifest.json.)
const DIFF_TWO_FILES = [
	'diff --git a/etc/config/network b/etc/config/network',
	'index abc123..def456 100644',
	'--- a/etc/config/network',
	'+++ b/etc/config/network',
	'@@ -1,3 +1,3 @@',
	'-\toption ipaddr \'192.168.1.1\'',
	'+\toption ipaddr \'192.168.1.2\'',
	'diff --git a/etc/config/dropbear b/etc/config/dropbear',
	'new file mode 100644',
	'index 0000000..1111111',
	'--- /dev/null',
	'+++ b/etc/config/dropbear',
	'@@ -0,0 +1,2 @@',
	'+config dropbear',
	'+\toption PasswordAuth \'on\''
].join('\n');

test('gbDiffSections groups body lines under each "diff --git" header', () => {
	const sections = H.gbDiffSections(DIFF_TWO_FILES);
	assert.equal(sections.length, 2);
	assert.equal(sections[0].header, 'diff --git a/etc/config/network b/etc/config/network');
	assert.equal(sections[0].body.length, 6);
	assert.equal(sections[1].header, 'diff --git a/etc/config/dropbear b/etc/config/dropbear');
	assert.equal(sections[1].body.length, 7);
});

test('gbSectionPath reads the "b/..." side of the header', () => {
	const sections = H.gbDiffSections(DIFF_TWO_FILES);
	assert.equal(H.gbSectionPath(sections[0].header), 'etc/config/network');
	assert.equal(H.gbSectionPath(sections[1].header), 'etc/config/dropbear');
	assert.equal(H.gbSectionPath('not a diff header'), null);
});

test('gbSectionStatus tells modified/added apart from the body\'s own marker lines', () => {
	const sections = H.gbDiffSections(DIFF_TWO_FILES);
	assert.equal(H.gbSectionStatus(sections[0]), 'modified');
	assert.equal(H.gbSectionStatus(sections[1]), 'added');
});

test('gbDiffFileList -- one entry per changed file, path plus status', () => {
	assert.deepEqual(H.gbDiffFileList(DIFF_TWO_FILES), [
		{ path: 'etc/config/network', status: 'modified' },
		{ path: 'etc/config/dropbear', status: 'added' }
	]);
});

// gbBoardMismatch -- keyed on "model"/"target" lines actually changing
// (+/- prefixed) inside a meta/board.json section, mirroring restore.sh's
// own _gb_restore_check_board fields (history.js's own comment above the
// function).
test('gbBoardMismatch is true when board.json\'s "model" line is added/removed', () => {
	const diff = [
		'diff --git a/devices/r1/meta/board.json b/devices/r1/meta/board.json',
		'index aaa..bbb 100644',
		'--- a/devices/r1/meta/board.json',
		'+++ b/devices/r1/meta/board.json',
		'@@ -1,3 +1,3 @@',
		'-  "model": "GL.iNet GL-MT6000",',
		'+  "model": "GL.iNet GL-MT3000",',
		'   "hostname": "r1"'
	].join('\n');
	assert.equal(H.gbBoardMismatch(diff), true);
});

test('gbBoardMismatch is false when only board.json\'s "hostname" line changes', () => {
	const diff = [
		'diff --git a/devices/r1/meta/board.json b/devices/r1/meta/board.json',
		'index aaa..bbb 100644',
		'--- a/devices/r1/meta/board.json',
		'+++ b/devices/r1/meta/board.json',
		'@@ -1,3 +1,3 @@',
		'   "model": "GL.iNet GL-MT6000",',
		'-  "hostname": "old-name"',
		'+  "hostname": "new-name"'
	].join('\n');
	assert.equal(H.gbBoardMismatch(diff), false);
});

test('gbBoardMismatch is false when the diff never touches meta/board.json at all', () => {
	assert.equal(H.gbBoardMismatch(DIFF_TWO_FILES), false);
});

// gbRestorePlan -- the actual files a restore would touch: create/overwrite
// under files/, never meta/manifest bookkeeping, never a path git shows as
// deleted (restore.sh has no delete pass -- history.js's own comment).
test('gbRestorePlan lists only real files/ paths, skips meta/ and deletions', () => {
	const diff = [
		'diff --git a/devices/r1/files/etc/config/network b/devices/r1/files/etc/config/network',
		'index aaa..bbb 100644',
		'--- a/devices/r1/files/etc/config/network',
		'+++ b/devices/r1/files/etc/config/network',
		'@@ -1 +1 @@',
		'-x',
		'+y',
		'diff --git a/devices/r1/files/etc/config/new_file b/devices/r1/files/etc/config/new_file',
		'new file mode 100644',
		'index 000..111',
		'--- /dev/null',
		'+++ b/devices/r1/files/etc/config/new_file',
		'@@ -0,0 +1 @@',
		'+z',
		'diff --git a/devices/r1/meta/board.json b/devices/r1/meta/board.json',
		'index aaa..bbb 100644',
		'--- a/devices/r1/meta/board.json',
		'+++ b/devices/r1/meta/board.json',
		'@@ -1 +1 @@',
		'-a',
		'+b',
		'diff --git a/devices/r1/files/etc/config/removed_file b/devices/r1/files/etc/config/removed_file',
		'deleted file mode 100644',
		'index 111..000',
		'--- a/devices/r1/files/etc/config/removed_file',
		'+++ /dev/null',
		'@@ -1 +0,0 @@',
		'-w'
	].join('\n');

	assert.deepEqual(H.gbRestorePlan(diff), [
		{ path: '/etc/config/network', action: 'overwrite' },
		{ path: '/etc/config/new_file', action: 'create' }
	]);
});

// The restore-log terminal-line regex -- the poller's own stop condition
// (interfaces.md, ticket 14: "терминальная строка лога, 60с простоя,
// жёсткий потолок 5 минут"). A false negative here means the poller never
// notices restore finished; a false positive means it stops watching too
// early.
//
// Ticket 23: this fixture's own "writing one or more files failed" line
// used to stand in for restore.sh's partial-write outcome and never
// actually matched anything the shell side logs -- restore.sh (ticket 19,
// _gb_restore) prints "gb_restore: the following paths were NOT
// written:<list>" instead, verified directly against
// package/gitbackup/files/usr/share/gitbackup/restore.sh. The line below
// is that real string, not the one this test used to assert against.
test('GB_RESTORE_TERMINAL_RE matches every documented terminal outcome', () => {
	const terminalLines = [
		'gb_restore: restored r1 from abc123 on device/r1',
		'gb_restore: the following paths were NOT written:\n  /etc/hosts: could not write',
		'this backup was taken on a different board',
		'sha256 mismatch, refusing to write anything to disk',
		'devices/r1/manifest.json does not exist on origin yet -- nothing to restore',
		'commit abc123 was not found on device/r1 at origin',
		'could not read manifest.json from abc123 on device/r1: fetch failed',
		'git fetch origin device/r1 failed',
		'cannot create a work directory',
		'repository url is required'
	];
	for (const line of terminalLines)
		assert.equal(H.GB_RESTORE_TERMINAL_RE.test(line), true, `expected a match for: ${line}`);
});

test('GB_RESTORE_TERMINAL_RE does not match an unrelated log line', () => {
	assert.equal(H.GB_RESTORE_TERMINAL_RE.test('gitbackup: starting scheduled run'), false);
});

test('gbRestoreLogSuccess is true only for the actual success line', () => {
	assert.equal(H.gbRestoreLogSuccess('gb_restore: restored r1 from abc123 on device/r1'), true);
	assert.equal(H.gbRestoreLogSuccess('gb_restore: starting restore of r1'), false);
	assert.equal(H.gbRestoreLogSuccess('this backup was taken on a different board'), false);
});

// gbClassifyRestoreLog -- ticket 23's own three-way outcome for the
// restore confirmation modal (spec: "Частичный успех restore... обязан
// быть виден и отличаться от полного"). 'partial' is the one this ticket
// exists for: ticket 19's restore.sh always applies permissions to
// whatever DID get written even when a path failed, and this must not
// read as either a clean success or an outright failure.
test('gbClassifyRestoreLog reports the clean-success line as "success"', () => {
	const cls = H.gbClassifyRestoreLog('gb_restore: restored r1 from abc123 on device/r1');
	assert.equal(cls.kind, 'success');
});

test('gbClassifyRestoreLog reports a partial write as "partial", not "success" or plain failure', () => {
	const cls = H.gbClassifyRestoreLog('gb_restore: the following paths were NOT written:\n  /etc/hosts: could not write');
	assert.equal(cls.kind, 'partial');
	assert.notEqual(cls.kind, 'success');
});

test('gbClassifyRestoreLog reports a board mismatch refusal as "blocked", not a generic error', () => {
	const cls = H.gbClassifyRestoreLog('this backup was taken on a different board');
	assert.equal(cls.kind, 'blocked');
});

test('gbClassifyRestoreLog reports a network/fetch failure as "error"', () => {
	assert.equal(H.gbClassifyRestoreLog('git fetch origin device/r1 failed').kind, 'error');
	assert.equal(H.gbClassifyRestoreLog('cannot create a work directory').kind, 'error');
});

// gbRestoreSeverity -- the display-severity gbClassifyRestoreLog's four
// kinds collapse to. Worked out by hand from the spec's own three visible
// states (идёт/хорошо/плохо), not by re-deriving the function's own
// mapping: success is the only "ok", partial and blocked both need a
// second look without being the same "something is broken" as a real
// error.
test('gbRestoreSeverity maps every gbClassifyRestoreLog kind to one of three severities', () => {
	assert.equal(H.gbRestoreSeverity('success'), 'ok');
	assert.equal(H.gbRestoreSeverity('partial'), 'warn');
	assert.equal(H.gbRestoreSeverity('blocked'), 'warn');
	assert.equal(H.gbRestoreSeverity('error'), 'error');
	assert.equal(H.gbRestoreSeverity('unknown'), 'error');
});
