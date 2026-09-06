// gitbackup -- a static gate over every view file's E() calls: a child
// argument must always be an ARRAY, never a bare string.
//
// Why this is a security test and not a style test. LuCI's own dom.append()
// (modules/luci-base/htdocs/luci-static/resources/luci.js at the commit
// tools/luci-upstream.pin names) branches on the shape of what it is given:
//
//   append: function(node, children) {
//       if (Array.isArray(children)) { ... document.createTextNode(...) ... }
//       else if (this.elem(children)) { ... }
//       else if (typeof children === 'function') { ... }
//       else if (children !== null && children !== undefined) {
//           node.innerHTML = '' + children;      // <-- HTML, not text
//           return node.lastChild;
//       }
//   }
//
// Only the ARRAY branch runs the string through createTextNode(). A bare
// string child lands on the last branch and is parsed as markup. Every
// other layer this project has is fine with that: gb_json_esc (lib.sh)
// escapes only what JSON requires -- `"`, `\`, LF, TAB, CR -- and passes
// `<`, `>`, `&` straight through, which is correct for JSON and useless
// for HTML; LuCI's String.format('%s') does not escape either (that is
// what '%h' is for); and there is no CSP on a LuCI page. So the array
// bracket at each call site IS the escaping.
//
// The data reaching these sinks is not ours: commit subjects, changed-file
// paths and diff bodies come off the backup remote (gbrpc_history/gbrpc_diff
// -> `git log`/`git diff`), and error `reason` strings relay git's own
// stderr, which can carry a hostile server's `remote:` lines verbatim.
// Executing script there runs it in the admin's authenticated LuCI session,
// which on OpenWrt is root-equivalent (rpcd/ubus, gbrpc_restore included).
//
// Run: node --test tests/dom_text_children.test.mjs
//
// This is a source scan, not a DOM test: views are browser-only LuCI
// resource files that cannot be imported under plain Node (same reason
// tests/lib/extract_luci_view.mjs exists), and the property being checked
// -- "no call site anywhere passes a bare child" -- is exactly the kind a
// whole-file scan can prove and a hand-written per-widget render test
// cannot.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const VIEW_DIR = join(__dirname, '..', 'applications', 'luci-app-gitbackup',
	'htdocs', 'luci-static', 'resources', 'view', 'gitbackup');

// Expressions accepted as a child without a literal '[' of their own,
// because they already evaluate to an array. Kept deliberately tiny and
// explicit: anything not provably an array here has to be bracketed at the
// call site, which is the whole point of the gate.
//
//   .map(...) / .concat(...)  -- Array methods, array results
//   children                  -- the local `var children = [ ... ]` both
//                                paths.js builders accumulate into
const ARRAY_CALL_RE = /\.(map|concat)\(/;
const ARRAY_IDENTS = new Set([ 'children' ]);

// maskedSpans <src> -- character ranges that are comments or string
// literals, so an `E('div', ...)` written inside a prose comment (settings.js
// has one) is not mistaken for a real call site.
function maskedSpans(src) {
	const spans = [];
	for (let i = 0; i < src.length;) {
		const c = src[i];
		if (c === '/' && src[i + 1] === '/') {
			const end = src.indexOf('\n', i);
			spans.push([ i, end < 0 ? src.length : end ]);
			i = end < 0 ? src.length : end;
		}
		else if (c === '/' && src[i + 1] === '*') {
			const end = src.indexOf('*/', i + 2);
			spans.push([ i, end < 0 ? src.length : end + 2 ]);
			i = end < 0 ? src.length : end + 2;
		}
		else if (c === '\'' || c === '"' || c === '`') {
			let j = i + 1;
			while (j < src.length) {
				if (src[j] === '\\') { j += 2; continue; }
				if (src[j] === c) { j++; break; }
				j++;
			}
			spans.push([ i, j ]);
			i = j;
		}
		else i++;
	}
	return spans;
}

// splitArgs <src> <open> -- the [start, end) span of each top-level argument
// of the call whose '(' sits at <open>, skipping over nested brackets,
// strings and comments. Returns null if the call is unterminated.
function splitArgs(src, open) {
	const args = [];
	let depth = 0, start = open + 1, inStr = null;
	for (let i = open; i < src.length; i++) {
		const c = src[i];
		if (inStr) {
			if (c === '\\') { i++; continue; }
			if (c === inStr) inStr = null;
			continue;
		}
		if (c === '\'' || c === '"' || c === '`') { inStr = c; continue; }
		if (c === '/' && src[i + 1] === '/') {
			const end = src.indexOf('\n', i);
			i = (end < 0 ? src.length : end) - 1;
			continue;
		}
		if (c === '(' || c === '[' || c === '{') depth++;
		else if (c === ')' || c === ']' || c === '}') {
			depth--;
			if (depth === 0) { args.push([ start, i ]); return args; }
		}
		else if (c === ',' && depth === 1) { args.push([ start, i ]); start = i + 1; }
	}
	return null;
}

// bareChildren <src> -- one entry per E() call site whose child argument is
// neither a '[' literal nor a known array expression. E()'s own signature is
// E(tag, attrs, children) or E(tag, children); LuCI's dom.create() tells the
// two apart by whether the second argument is an element or an array, so
// this reads the attribute object the same way: `{`-first means the child is
// the third argument.
function bareChildren(src) {
	const spans = maskedSpans(src);
	const masked = (pos) => spans.some(([ a, b ]) => pos >= a && pos < b);
	const lineOf = (pos) => src.slice(0, pos).split('\n').length;
	const out = [];
	for (const m of src.matchAll(/\bE\(/g)) {
		if (masked(m.index)) continue;
		const args = splitArgs(src, m.index + m[0].length - 1);
		if (!args || args.length < 2) continue;
		const text = args.map(([ a, b ]) => src.slice(a, b).trim());
		const ci = text[1].startsWith('{') ? 2 : 1;
		if (text.length <= ci) continue;
		const child = text[ci];
		if (child.startsWith('[') || ARRAY_CALL_RE.test(child) || ARRAY_IDENTS.has(child))
			continue;
		out.push({ line: lineOf(args[ci][0]), child: child.replace(/\s+/g, ' ').slice(0, 90) });
	}
	return out;
}

const VIEWS = readdirSync(VIEW_DIR).filter((f) => f.endsWith('.js')).sort();

test('every view file is scanned (the gate cannot pass by finding nothing)', () => {
	// A rename or a moved directory would otherwise turn this whole file
	// into a no-op that still reports green.
	assert.ok(VIEWS.length >= 5, `expected the view directory to hold the shipped views, found ${VIEWS.join(', ')}`);
	assert.ok(VIEWS.includes('diffview.js') && VIEWS.includes('history.js'),
		`the two files that render remote-controlled text must be among them, found ${VIEWS.join(', ')}`);
});

test('the scanner really does spot a bare child (it is not vacuously green)', () => {
	const found = bareChildren('var x = E(\'div\', { \'class\': \'a\' }, commit.subject);');
	assert.equal(found.length, 1);
	assert.equal(found[0].child, 'commit.subject');
	assert.equal(bareChildren('var x = E(\'div\', { \'class\': \'a\' }, [ commit.subject ]);').length, 0);
	assert.equal(bareChildren('// E(\'div\', {}, subject) in a comment\n').length, 0);
});

for (const file of VIEWS) {
	test(`${file} passes every E() child as an array, never a bare string`, () => {
		const found = bareChildren(readFileSync(join(VIEW_DIR, file), 'utf8'));
		const report = found.map((f) => `  ${file}:${f.line}  E(..., ${f.child})`).join('\n');
		assert.equal(found.length, 0,
			`bare E() child argument(s) -- these reach dom.append()'s innerHTML branch and\n`
			+ `render their content as markup. Wrap each in [ ... ]:\n${report}`);
	});
}
