'use strict';
'require view';

// Deliberately unsafe for jsmin (ticket 15 acceptance criterion:
// "Намеренно сломанный тестовый файл гейт валит"). jsmin.c's `next()`
// unconditionally treats a '/' followed by another '/' as the start of a
// line comment -- BEFORE `action()` ever gets to decide whether the first
// '/' was a regex or a division, and only the confirmed-regex copy loop in
// `action()` (reached when the preceding significant character is one of
// '(', ',', '=', ':', '[', '!', '&', '|', '?', '+', '-', '~', '*', '/',
// '{', '}', ';') reads its body through raw get() to bypass that check.
// After `return`, the preceding character is 'n' -- not on that list -- so
// jsmin falls through to its normal, non-regex path. The regex literal
// below is `/\//` (matches a literal "/"): its last two characters are an
// escaped slash immediately followed by the closing delimiter, i.e. a bare
// "//" once next() looks one character ahead -- exactly what next()'s own
// comment check fires on. jsmin therefore reads everything from that point
// to the end of the line as a comment, and everything after that up to the
// next real "//"/"/*" pair as ordinary (but now syntactically broken)
// source, all while exiting 0 -- confirmed live against the pinned jsmin
// binary (tools/build-jsmin.sh) before this fixture was written:
//
//   $ printf 'function f(s){\n\treturn /\\//.test(s);\n}\nvar ok = 1;\nreturn ok;\n' | jsmin
//   function f(s){return/\}
//   var ok=1;return ok;
//
// -- ".test(s);" and the closing "}" of f() are gone, replaced by a stray
// "}" pulled from the next line, while jsmin's own exit code stays 0. A
// gate that only checks that exit code would call this file safe.
function gbMatchesSlash(s) {
	return /\//.test(s);
}

return view.extend({
	load: function() {
		return gbMatchesSlash('a/b');
	}
});
