#!/usr/bin/env node
/* Gate: prove jsmin's output is the SAME PROGRAM as the source.
 *
 * `luci.mk` minifies every LuCI package's JS with jsmin, whose hand-written scanner decides REGEX
 * vs DIVISION from exactly one preceding character against a fixed allow-list -- `n`, the last
 * letter of `return`, is not on it, nor is `>` from `=>`. So `return /re/` makes jsmin read the
 * regex's `//` as a line comment and swallow the rest of the file, exiting 0 while doing it
 * (openwrt/luci#8299, #8020, #8021, #8256).
 *
 * A zero exit code therefore proves nothing. The only proof jsmin did not eat our code is
 * comparing the TOKEN STREAM of source and output -- same tokens, same order, or the build is
 * wrong. (Model: luci-theme-footstrap's tools/jsmin-verify.mjs, which found this exact class of
 * bug first -- adapted here for this project's own view tree instead of a theme's resources/.)
 *
 * `allowReturnOutsideFunction`: a LuCI resource file is evaluated inside a function wrapper and
 * legitimately ends in a top-level `return view.extend({...})`.
 *
 * Usage: node tools/jsmin-verify.mjs [file ...]   -- JSMIN=<path to compiled binary> required */
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import * as acorn from 'acorn';

const JSMIN = process.env.JSMIN || '/tmp/jsmin';
const OPTS = { ecmaVersion: 2022, allowReturnOutsideFunction: true, allowAwaitOutsideFunction: true };

if (!existsSync(JSMIN)) {
	console.error(`jsmin not found at ${JSMIN}. Build it with tools/build-jsmin.sh and set $JSMIN.`);
	process.exit(2);
}

const tokens = (src) => [...acorn.tokenizer(src, OPTS)].map(t => `${t.type.label} ${t.value ?? ''}`);

/* Which JS ships, asked of the filesystem here, once: this is the whole of what luci.mk installs
 * for this app (root/htdocs copied wholesale), so every .js under the view directory IS the
 * shipped set. Spelling the glob out in a CI step and handing the result over in an environment
 * variable puts the answer in two places, and a file left out of one of them silently drops this
 * check on its JS. */
const files = process.argv.length > 2
	? process.argv.slice(2)
	: execFileSync('find', [
		'applications/luci-app-gitbackup/htdocs/luci-static/resources/view/gitbackup',
		'-name', '*.js'
	], { encoding: 'utf8' }).split('\n').filter(Boolean).sort();

if (!files.length) {
	console.error('found no shipped view JS -- the glob or the tree moved');
	process.exit(2);
}

let failed = 0, before = 0, after = 0;

for (const f of files) {
	const src = readFileSync(f, 'utf8');
	const name = f.split('/').pop();

	let min;
	try {
		min = execFileSync(JSMIN, { input: src, encoding: 'utf8' });
	} catch (e) {
		console.log(`  FAIL ${name}: jsmin exited non-zero -- ${String(e.stderr || e.message).trim()}`);
		failed++;
		continue;
	}

	let a, b;
	try {
		a = tokens(src);
		b = tokens(min);
	} catch (e) {
		console.log(`  FAIL ${name}: output does not parse -- ${e.message}`);
		failed++;
		continue;
	}

	const n = Math.max(a.length, b.length);
	let diff = -1;
	for (let i = 0; i < n; i++) {
		if (a[i] !== b[i]) { diff = i; break; }
	}

	if (diff !== -1) {
		const show = (t) => (t === undefined ? '<END OF FILE>' : t.replace(' ', ' '));
		console.log(`  FAIL ${name}: token ${diff} differs -- source has [${show(a[diff])}], jsmin produced [${show(b[diff])}]`);
		console.log('       jsmin ate part of this file. Look for `return /regex/` or `=> /regex/`:');
		console.log('       its regex lookback allow-list has no `n` (return) and no `>` (arrow).');
		failed++;
		continue;
	}

	before += src.length;
	after += min.length;
	console.log(`  ok   ${name.padEnd(20)} ${String(a.length).padStart(5)} tokens identical   ${src.length} -> ${min.length} B`);
}

if (before) {
	const pct = Math.round(100 - (100 * after) / before);
	console.log(`\n  total ${before} -> ${after} B  (-${pct}%)`);
}

if (failed) {
	console.error(`\n${failed} file(s) failed the jsmin equivalence check`);
	process.exit(1);
}
console.log('\njsmin output is token-identical to the source for every shipped view file');
