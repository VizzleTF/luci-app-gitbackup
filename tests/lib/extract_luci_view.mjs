// Shared brace/statement extraction for pulling a pure function or a `var`
// statement out of a LuCI view file's raw source, so a unit test exercises
// the byte-for-byte shipped implementation rather than a reimplementation
// that could quietly drift from what ships. Same technique as
// tests/settings_cron_fixture.test.js's own loadValidator() (ticket 12) --
// factored out here because tests/history_view.test.mjs needs it for
// several functions plus one `var` statement, not just one function.
//
// Views are never require()'d/import()'d directly: they are browser-only
// LuCI resource files (`'require view';` etc. are LuCI's own module-loader
// pragmas, harmless no-op string-literal statements under plain Node) whose
// module-level code ends in a top-level `return view.extend({...})` that
// would throw under Node (no `view` global) -- extraction sidesteps that
// entirely by never evaluating anything past the pieces asked for.

// _realBraceDepthAtEnd <text> -- net count of '{'/'}' characters in text
// that are genuine code (not sitting inside a string, regex literal, or
// comment), i.e. the brace depth a real JS tokenizer would report at the
// end of text. Only used to validate a slice extractFunctionSource has
// already decided on: that slice starts right after a function's own
// opening '{' and, if it truly is the whole function, real depth returns
// to exactly 0 by its last character -- every block it opened has closed.
//
// This exists because the naive char-by-char counter above cannot tell a
// real brace from one sitting inside a string or regex literal. A body
// like `if (x) { var s = 'oops}'; }` has one *extra* '}' at the source
// level (inside the string) that the naive counter still sees, so it can
// reach depth 0 one real closing brace early -- at the `if` block's own
// '}', not the function's -- and stop there. The slice that produces is
// syntactically valid on its own (new Function() parses it fine) and its
// naive brace count is balanced by construction, so neither check the
// caller already had catches it; only re-counting while skipping string/
// regex/comment content reveals that a real block (here, the function
// itself) was left open.
//
// The shipped views this runs against are plain ES5 by their own header
// comment (history.js: "no let/const/arrow/template literals"), so this
// does not attempt template-literal parsing -- any backtick in the actual
// sources lives inside a `//` comment, which is skipped whole below
// regardless of what it contains.
function _realBraceDepthAtEnd(text) {
	var i = 0, n = text.length, depth = 0, ch, prev = '';

	function precedesRegex() {
		// A '/' opens a regex literal unless the last significant
		// character looks like the end of a value (identifier/number
		// char or a closing bracket), in which case it is division.
		// Good enough for this codebase's plain ES5; misclassifying
		// division as a regex start can only make this scan swallow a
		// few extra characters looking for a closing '/', never silently
		// accept a truncated body.
		return prev === '' || !/[\w$)\]]/.test(prev);
	}

	while (i < n) {
		ch = text[i];

		if (ch === '/' && text[i + 1] === '/') {
			i += 2;
			while (i < n && text[i] !== '\n') i++;
			continue;
		}
		if (ch === '/' && text[i + 1] === '*') {
			i += 2;
			while (i < n && !(text[i] === '*' && text[i + 1] === '/')) i++;
			i += 2;
			continue;
		}
		if (ch === '\'' || ch === '"') {
			var quote = ch;
			i++;
			while (i < n && text[i] !== quote) {
				if (text[i] === '\\') i++;
				i++;
			}
			i++;
			prev = quote;
			continue;
		}
		if (ch === '/' && precedesRegex()) {
			var j = i + 1, inClass = false, closed = false;
			while (j < n) {
				if (text[j] === '\\') { j += 2; continue; }
				if (text[j] === '\n') break;
				if (text[j] === '[') inClass = true;
				else if (text[j] === ']') inClass = false;
				else if (text[j] === '/' && !inClass) { j++; closed = true; break; }
				j++;
			}
			if (closed) {
				while (j < n && /[a-z]/i.test(text[j])) j++;
				i = j;
				prev = '/';
				continue;
			}
			// No closing '/' before end-of-line: not actually a regex.
			// Fall through and treat this '/' as an ordinary character.
		}

		if (ch === '{') { depth++; prev = ch; i++; continue; }
		if (ch === '}') { depth--; prev = ch; i++; continue; }

		if (!/\s/.test(ch)) prev = ch;
		i++;
	}

	return depth;
}

export function extractFunctionSource(src, name) {
	var re = new RegExp('function ' + name + '\\([^)]*\\)\\s*\\{');
	var m = re.exec(src);
	var i, depth, result;

	if (!m)
		throw new Error('could not find function ' + name + '()');

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

	result = src.slice(m.index, i);

	if (_realBraceDepthAtEnd(result) !== 0)
		throw new Error('extractFunctionSource(' + name + '): extracted text does not ' +
			'look like a whole function -- a brace inside a string or regex ' +
			'literal likely made the naive brace count balance early, so ' +
			'extraction stopped before the function\'s real closing brace');

	return result;
}

// extractVarStatement <src> <name> -- the full `var NAME = ...;` statement,
// scanning for the first top-level-depth `;` (tracking ([{/}]) depth so a
// semicolon inside e.g. a string or an array literal does not end it early).
// Used here for history.js's GB_RESTORE_TERMINAL_RE, a `new RegExp([...].
// join('|'))` -- not a function, so extractFunctionSource does not apply.
export function extractVarStatement(src, name) {
	var re = new RegExp('var\\s+' + name + '\\s*=');
	var m = re.exec(src);
	var i, depth, ch;

	if (!m)
		throw new Error('could not find "var ' + name + ' ="');

	i = m.index;
	depth = 0;
	for (; i < src.length; i++) {
		ch = src[i];
		if (ch === '(' || ch === '[' || ch === '{') depth++;
		else if (ch === ')' || ch === ']' || ch === '}') depth--;
		else if (ch === ';' && depth === 0) { i++; break; }
	}

	return src.slice(m.index, i);
}
