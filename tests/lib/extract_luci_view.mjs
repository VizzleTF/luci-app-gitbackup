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

export function extractFunctionSource(src, name) {
	var re = new RegExp('function ' + name + '\\([^)]*\\)\\s*\\{');
	var m = re.exec(src);
	var i, depth;

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

	return src.slice(m.index, i);
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
