#!/usr/bin/env node
'use strict';

// gitbackup -- ticket 12's own verification that the JS cron validator
// shipped in settings.js (view/gitbackup/settings.js's own gbCronValid/
// gbFieldValid) agrees with schedule.sh's gb_cron_valid on every row of
// the shared fixture file, tests/fixtures/cron.tsv (owned by ticket 06,
// not this one -- read, never edited, by both sides). The brief's own
// words: "Валидатор — две реализации... Общий файл кейсов
// tests/fixtures/cron.tsv гоняется и через sh, и через node; расхождение —
// красный CI." Wiring this into the project's actual CI gate is ticket
// 15's job (interfaces.md, ticket 12: "Гейт ставит таск 15, но фикстуру
// используй ты"); this script is this ticket's own proof that there is
// nothing left for that gate to catch.
//
// Run directly: `node tests/settings_cron_fixture.test.js`
//
// settings.js is never require()'d directly here and gets no
// Node-specific export seam of its own: it is a browser-only LuCI view
// file, loaded by the OpenWrt LuCI runtime's own module loader (not
// CommonJS) and round-tripped through the buildbot's old jsmin.c
// (verified separately, not by this script) -- adding `module.exports`
// or any other Node-only branch to it would be dead weight in the one
// environment that actually runs it, purely to serve this one test.
// Instead, gbFieldValid/gbCronValid's exact source is pulled out of the
// real file by brace-matching (both are pure: no rpc/DOM/`this`/closure
// over anything else in the file) and evaluated on their own, so this
// tests the byte-for-byte shipped implementation, not a reimplementation
// of it that could quietly drift from what ships.

var fs = require('fs');
var path = require('path');

var SETTINGS_PATH = path.join(__dirname, '..', 'applications', 'luci-app-gitbackup',
	'htdocs', 'luci-static', 'resources', 'view', 'gitbackup', 'settings.js');
var FIXTURE_PATH = path.join(__dirname, 'fixtures', 'cron.tsv');

function extractFunctionSource(src, name) {
	var re = new RegExp('function ' + name + '\\([^)]*\\)\\s*\\{');
	var m = re.exec(src);
	var i, depth;

	if (!m)
		throw new Error('could not find function ' + name + '() in ' + SETTINGS_PATH);

	i = m.index + m[0].length;
	depth = 1;
	while (depth > 0) {
		if (i >= src.length)
			throw new Error('unbalanced braces while extracting ' + name + '()');
		if (src[i] === '{')
			depth++;
		else if (src[i] === '}')
			depth--;
		i++;
	}

	return src.slice(m.index, i);
}

function loadValidator() {
	var src = fs.readFileSync(SETTINGS_PATH, 'utf8');
	var body = extractFunctionSource(src, 'gbFieldValid') + '\n' +
		extractFunctionSource(src, 'gbCronValid') + '\n' +
		'return gbCronValid;';

	// `_` is the only free identifier gbCronValid's own body reaches for
	// (its %s/%d-formatted rejection reasons) -- a plain identity function
	// plus a minimal String.prototype.format polyfill is enough for this
	// test, which only asserts the boolean verdict, never the message text.
	if (!String.prototype.format) {
		String.prototype.format = function() {
			var args = arguments;
			var i = 0;
			return this.replace(/%[sd]/g, function() {
				return String(args[i++]);
			});
		};
	}

	// eslint-disable-next-line no-new-func
	return new Function('_', body)(function(s) { return s; });
}

function loadFixtures() {
	var text = fs.readFileSync(FIXTURE_PATH, 'utf8');
	var cases = [];

	text.split('\n').forEach(function(line, idx) {
		var tab, expr, expect;

		if (!line || line.charAt(0) === '#')
			return;

		tab = line.indexOf('\t');
		if (tab === -1) {
			throw new Error('fixtures/cron.tsv:' + (idx + 1) + ': no tab separator in "' + line + '"');
		}

		expr = line.slice(0, tab);
		expect = line.slice(tab + 1).replace(/\r$/, '');
		if (expect !== 'valid' && expect !== 'invalid')
			throw new Error('fixtures/cron.tsv:' + (idx + 1) + ': expected "valid"/"invalid", got "' + expect + '"');

		cases.push({ line: idx + 1, expr: expr, expect: expect === 'valid' });
	});

	return cases;
}

function main() {
	var gbCronValid = loadValidator();
	var cases = loadFixtures();
	var failures = [];

	cases.forEach(function(c) {
		var res = gbCronValid(c.expr);
		if (res.valid !== c.expect) {
			failures.push('fixtures/cron.tsv:' + c.line + ': "' + c.expr + '" expected ' +
				(c.expect ? 'valid' : 'invalid') + ', gbCronValid said ' +
				(res.valid ? 'valid' : 'invalid (' + res.reason + ')'));
		}
	});

	if (failures.length) {
		console.error('FAIL: ' + failures.length + '/' + cases.length + ' cron.tsv cases disagree with settings.js\'s gbCronValid:');
		failures.forEach(function(f) { console.error('  ' + f); });
		process.exit(1);
	}

	console.log('OK: settings.js\'s gbCronValid agrees with all ' + cases.length + ' cases in tests/fixtures/cron.tsv');
}

main();
