#!/usr/bin/env node
'use strict';

// gitbackup -- ticket 29's own proof that the three live-log "is this
// operation over" regexes (overview.js's GB_LOG_TERMINAL_RE, settings.js's
// GB_TEST_TERMINAL_RE, history.js's GB_RESTORE_TERMINAL_RE) classify every
// line in the shared fixture tests/fixtures/terminal-markers.tsv the way
// that fixture says they should.
//
// What this proves: for every <regexvar>/<line> pair in the fixture, the
// named regex's own .test(line) agrees with the fixture's <terminal>
// column, AND every alternative inside each regex (its own `a|b|c` split)
// is exercised by at least one "yes" row -- so a regex alternative with no
// fixture coverage at all fails loudly here rather than being silently
// unverified.
//
// What this does NOT prove: that the <line> text is what the shell
// actually prints. That is tests/run.sh's own job (see its "terminal
// marker fixture" section, and the fixture file's own header comment) --
// this script only ever reads the three view/gitbackup/*.js files and the
// fixture, never any shell source. A rename made identically in the shell
// source, the fixture AND a still-correct regex would pass every test
// here; catching that class of drift is what the header comment on the
// fixture's own "anchor" column and tests/run.sh's grep-against-source
// check exist for.
//
// Run directly: `node tests/terminal_markers_fixture.test.js`
//
// Same reasoning as tests/settings_cron_fixture.test.js for not requiring
// a Node-specific export seam from the three view files: each RegExp is
// pulled out of its own source by a small textual match on its fixed
// `new RegExp([...].join('|'))` shape (verified against all three files
// before writing this) and evaluated on its own -- this tests the
// byte-for-byte shipped regex, not a reimplementation that could drift.

var fs = require('fs');
var path = require('path');

var VIEW_DIR = path.join(__dirname, '..', 'applications', 'luci-app-gitbackup',
	'htdocs', 'luci-static', 'resources', 'view', 'gitbackup');
var OVERVIEW_PATH = path.join(VIEW_DIR, 'overview.js');
var SETTINGS_PATH = path.join(VIEW_DIR, 'settings.js');
var HISTORY_PATH = path.join(VIEW_DIR, 'history.js');
var FIXTURE_PATH = path.join(__dirname, 'fixtures', 'terminal-markers.tsv');

// extractRegexVar <src> <file> <name> -- pulls `var <name> = new
// RegExp([ 'alt1', 'alt2', ... ].join('|'));` out of <src> by matching that
// fixed shape (present, unchanged, in all three files as of ticket 23) and
// evaluates the array literal to get the exact alternatives the shipped
// code uses -- not a hand-copied duplicate of them.
function extractRegexVar(src, file, name) {
	var re = new RegExp('var ' + name + ' = new RegExp\\(\\s*\\[([\\s\\S]*?)\\]\\s*\\.join\\(\'\\|\'\\)\\s*\\);');
	var m = re.exec(src);
	var alternatives;

	if (!m)
		throw new Error('could not find ' + name + ' = new RegExp([...].join(\'|\')) in ' + file);

	// eslint-disable-next-line no-new-func
	alternatives = new Function('return [' + m[1] + '];')();
	if (!Array.isArray(alternatives) || alternatives.length === 0)
		throw new Error(name + ' in ' + file + ' extracted to an empty/non-array alternative list');

	return { regex: new RegExp(alternatives.join('|')), alternatives: alternatives };
}

function loadRegexVars() {
	var overviewSrc = fs.readFileSync(OVERVIEW_PATH, 'utf8');
	var settingsSrc = fs.readFileSync(SETTINGS_PATH, 'utf8');
	var historySrc = fs.readFileSync(HISTORY_PATH, 'utf8');

	return {
		GB_LOG_TERMINAL_RE: extractRegexVar(overviewSrc, OVERVIEW_PATH, 'GB_LOG_TERMINAL_RE'),
		GB_TEST_TERMINAL_RE: extractRegexVar(settingsSrc, SETTINGS_PATH, 'GB_TEST_TERMINAL_RE'),
		GB_RESTORE_TERMINAL_RE: extractRegexVar(historySrc, HISTORY_PATH, 'GB_RESTORE_TERMINAL_RE')
	};
}

function loadFixtures() {
	var text = fs.readFileSync(FIXTURE_PATH, 'utf8');
	var cases = [];

	text.split('\n').forEach(function(line, idx) {
		var fields, regexvar, terminal, caseLine, anchor;

		if (!line || line.charAt(0) === '#')
			return;

		fields = line.split('\t');
		if (fields.length !== 4) {
			throw new Error('fixtures/terminal-markers.tsv:' + (idx + 1) +
				': expected 4 tab-separated fields, got ' + fields.length + ' in "' + line + '"');
		}

		regexvar = fields[0];
		terminal = fields[1];
		caseLine = fields[2];
		anchor = fields[3].replace(/\r$/, '');

		if (terminal !== 'yes' && terminal !== 'no') {
			throw new Error('fixtures/terminal-markers.tsv:' + (idx + 1) +
				': expected "yes"/"no" in the terminal column, got "' + terminal + '"');
		}

		cases.push({
			line: idx + 1,
			regexvar: regexvar,
			text: caseLine,
			anchor: anchor,
			expectTerminal: terminal === 'yes'
		});
	});

	return cases;
}

function main() {
	var regexVars = loadRegexVars();
	var cases = loadFixtures();
	var failures = [];
	var seenPerVar = {};
	var varName;

	Object.keys(regexVars).forEach(function(name) { seenPerVar[name] = []; });

	cases.forEach(function(c) {
		var entry = regexVars[c.regexvar];
		var got;

		if (!entry) {
			failures.push('fixtures/terminal-markers.tsv:' + c.line +
				': unknown regexvar "' + c.regexvar + '" (known: ' + Object.keys(regexVars).join(', ') + ')');
			return;
		}

		got = entry.regex.test(c.text);
		if (got !== c.expectTerminal) {
			failures.push('fixtures/terminal-markers.tsv:' + c.line + ': [' + c.regexvar + '] "' + c.text +
				'" expected terminal=' + c.expectTerminal + ', regex said ' + got);
		}

		if (c.expectTerminal)
			seenPerVar[c.regexvar].push(c.text);
	});

	// Branch coverage: every single alternative inside each regex (its own
	// `a|b|c` split) has to be matched by at least one "yes" fixture row --
	// otherwise a regex alternative could be silently unexercised by this
	// whole fixture and nobody would notice.
	for (varName in regexVars) {
		if (!Object.prototype.hasOwnProperty.call(regexVars, varName))
			continue;
		regexVars[varName].alternatives.forEach(function(alt) {
			var altRe = new RegExp(alt);
			var covered = seenPerVar[varName].some(function(text) { return altRe.test(text); });
			if (!covered) {
				failures.push(varName + ': alternative /' + alt +
					'/ is not matched by any "yes" row in fixtures/terminal-markers.tsv');
			}
		});
	}

	if (failures.length) {
		console.error('FAIL: ' + failures.length + ' problem(s) with terminal-markers.tsv vs. the shipped regexes:');
		failures.forEach(function(f) { console.error('  ' + f); });
		process.exit(1);
	}

	console.log('OK: GB_LOG_TERMINAL_RE/GB_TEST_TERMINAL_RE/GB_RESTORE_TERMINAL_RE agree with all ' +
		cases.length + ' cases in tests/fixtures/terminal-markers.tsv, every alternative covered');
}

main();
