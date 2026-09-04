'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require ui';

// gitbackup -- Settings (ticket 12, spec "Решения по реализации -> LuCI ->
// Settings", "UCI-схема", "Аутентификация", "Парсер remote URL",
// "Расписание", "Гейт видимости"). Client-side JS only, luci-base only,
// same jsmin-conservative style (plain ES5, `var`/`function`, no
// let/const/arrow/template literals, every statement semicolon-terminated)
// as overview.js (ticket 11), paths.js (ticket 13) and history.js (ticket
// 14), all read before writing this file -- their rpcd/style/poller-cleanup
// patterns are reused here, not reinvented. This is the fourth and last of
// the four tabs (interfaces.md: "четыре экрана").
//
// Unlike the other three views, this one IS a config form (form.Map over
// the whole "gitbackup" UCI package), so the stock Save/Apply/Reset row is
// left alone -- rule 11 of the spec's style guide only says stock buttons
// must never be hidden with CSS, not that every view must null them out;
// overview.js/paths.js/history.js null them out because none of them are
// backed by a form.Map in the first place.
//
// ---------------------------------------------------------------------
// rpcd bindings -- copied from root/usr/share/rpcd/acl.d/luci-app-
// gitbackup.json and usr/libexec/rpcd/luci.gitbackup's own gbrpc_*
// handlers (package/gitbackup, out of this ticket's zone). `set_secret`
// and `keygen` are the two write methods no other view touches.
// ---------------------------------------------------------------------

var callStatus = rpc.declare({
	object: 'luci.gitbackup',
	method: 'status'
});

var callPubkey = rpc.declare({
	object: 'luci.gitbackup',
	method: 'pubkey'
});

var callKeygen = rpc.declare({
	object: 'luci.gitbackup',
	method: 'keygen',
	params: [ 'force' ]
});

var callSetSecret = rpc.declare({
	object: 'luci.gitbackup',
	method: 'set_secret',
	params: [ 'value' ]
});

var callTest = rpc.declare({
	object: 'luci.gitbackup',
	method: 'test'
});

var callLog = rpc.declare({
	object: 'luci.gitbackup',
	method: 'log',
	params: [ 'lines' ]
});

var callValidateCron = rpc.declare({
	object: 'luci.gitbackup',
	method: 'validate_cron',
	params: [ 'expr' ]
});

// ---------------------------------------------------------------------
// Remote URL parsing / provider resolution / deploy-key deep links.
//
// Deliberately NOT calling remoteurl.sh's gb_parse_url/gb_provider/
// gb_deeplink (package/gitbackup, out of this ticket's zone): there is no
// rpcd method exposing any of the three (root/usr/share/rpcd/acl.d/
// luci-app-gitbackup.json's read tier lists exactly status/log/diff/
// config_diff/pubkey/list_paths/history/audit_paths/validate_cron, nothing
// named "parse_url"/"provider"/"deeplink"), and this needs to react to the
// URL/provider *form* fields as the operator edits them, before anything
// is saved -- a round trip for every keystroke would both hit uhttpd's own
// "-n 3" concurrent-call ceiling (interfaces.md, ticket 13) and be too slow
// to feel live. Mirrors gb_parse_url/gb_provider/gb_deeplink's own logic in
// client JS instead, the same choice overview.js already made for its own,
// narrower "view this commit" link. Kept deliberately in lock-step with
// remoteurl.sh's own three accepted forms and five gb_deeplink cases --
// re-read that file before changing either side.
// ---------------------------------------------------------------------

// gbParseRemoteUrl <url> -- { scheme, host, owner, repo } for one of the
// three forms gb_parse_url accepts (scp-like "git@host:owner/repo.git",
// "ssh://[user@]host[:port]/owner/repo(.git)?", "https://host[:port]/
// owner/repo(.git)?"), or null. Port is parsed but not kept: gb_deeplink's
// own signature never takes one either (a deploy-key settings page is
// always reached over a provider's standard port).
function gbParseRemoteUrl(url) {
	var m;

	url = url || '';

	m = url.match(/^https:\/\/([^/:]+)(?::\d+)?\/([^/]+)\/([^/]+?)(?:\.git)?\/?$/);
	if (m)
		return { scheme: 'https', host: m[1], owner: m[2], repo: m[3] };

	m = url.match(/^ssh:\/\/(?:[^@/]+@)?([^/:]+)(?::\d+)?\/([^/]+)\/([^/]+?)(?:\.git)?\/?$/);
	if (m)
		return { scheme: 'ssh', host: m[1], owner: m[2], repo: m[3] };

	// scp-like alias syntax: "[user@]host:owner/repo(.git)?" -- gb_parse_url
	// accepts this only when nothing before the first ":" contains a "/",
	// which is exactly what tells it apart from the two forms above.
	m = url.match(/^(?:[^@/:]+@)?([^/:]+):([^/]+)\/([^/]+?)(?:\.git)?\/?$/);
	if (m)
		return { scheme: 'ssh', host: m[1], owner: m[2], repo: m[3] };

	return null;
}

// gbResolveProvider <url> <providerOption> -- gb_provider's own logic:
// an explicit, non-"auto" option wins outright; "auto" (the default) falls
// back to a fixed host table, and anything else -- including a URL that
// does not parse at all -- resolves to "generic". This is the function the
// generic-remote acknowledgement gate and the deploy-key link/instructions
// switch both key off of, and it is why neither can be a plain `.depends()`
// on the "provider" option alone: "auto" against an unrecognized self-hosted
// host is exactly the case gb_visibility_ok itself (package/gitbackup,
// visibility.sh) treats as generic, and a UI that only reacted to an
// explicit provider="generic" selection would silently skip the
// acknowledgement gate for that router.
function gbResolveProvider(url, providerOption) {
	var parsed;

	if (providerOption && providerOption !== 'auto')
		return providerOption;

	parsed = gbParseRemoteUrl(url);
	switch (parsed ? parsed.host : '') {
	case 'github.com':
		return 'github';
	case 'gitlab.com':
		return 'gitlab';
	case 'bitbucket.org':
		return 'bitbucket';
	case 'codeberg.org':
		return 'gitea';
	default:
		return 'generic';
	}
}

// gbDeeplinkInfo <url> <providerOption> -- one of:
//   { kind: 'unparsed' }                  -- <url> does not match any of
//                                            the three accepted forms yet
//   { kind: 'link', url: '...' }          -- a real "add deploy key" page
//   { kind: 'generic', host: '...' }      -- no such page exists anywhere
// Mirrors gb_deeplink's own five cases exactly (package/gitbackup,
// remoteurl.sh) -- GitHub and Bitbucket hardcoded to their one cloud host
// (gb_provider only ever resolves "github"/"bitbucket" for those two
// hosts), GitLab/Gitea built from the remote's own host because both are
// commonly self-hosted. gb_deeplink's own <scheme> parameter only ever
// matters to coerce a non-"http"/"https" scheme (i.e. "ssh") to "https" --
// gbParseRemoteUrl above never produces anything else, so that coercion is
// already unconditionally true here and is not reproduced as a branch.
function gbDeeplinkInfo(url, providerOption) {
	var parsed = gbParseRemoteUrl(url);
	var provider;

	if (!parsed)
		return { kind: 'unparsed' };

	provider = gbResolveProvider(url, providerOption);

	switch (provider) {
	case 'github':
		return { kind: 'link', url: 'https://github.com/' + parsed.owner + '/' + parsed.repo + '/settings/keys/new' };
	case 'gitlab':
		return { kind: 'link', url: 'https://' + parsed.host + '/' + parsed.owner + '/' + parsed.repo + '/-/settings/repository' };
	case 'gitea':
		return { kind: 'link', url: 'https://' + parsed.host + '/' + parsed.owner + '/' + parsed.repo + '/settings/keys' };
	case 'bitbucket':
		return { kind: 'link', url: 'https://bitbucket.org/' + parsed.owner + '/' + parsed.repo + '/admin/access-keys/' };
	default:
		return { kind: 'generic', host: parsed.host };
	}
}

// ---------------------------------------------------------------------
// Cron validator -- the JS half of the brief's "две реализации" acceptance
// criterion. Kept in exact lock-step with schedule.sh's own gb_cron_valid/
// _gb_field_values (package/gitbackup, out of this ticket's zone, read
// before writing this): same field bounds (minute 0-59, hour 0-23,
// day-of-month 1-31, month 1-12, day-of-week 0-6 -- NOT 0-7, busybox has no
// Sunday-as-7 alias), same "*", "*/N", "A", "A-B", "A-B/N", comma-list
// grammar, same rejection of a leading/trailing/doubled comma, a reversed
// range, an out-of-[min,max] bound or a step outside [1,max]. Verified
// against the shared fixture file both sides run
// (tests/fixtures/cron.tsv) by tests/settings_cron_fixture.test.js (this
// ticket's own zone) -- a mismatch there is exactly the "расхождение
// обязано красить CI" the brief calls for, even though wiring that check
// into the project's actual CI gate is ticket 15's job, not this one's.
//
// A pure decimal parseInt is used throughout, unlike schedule.sh's own
// _gb_strip_lead0 dance: that workaround exists only because busybox ash's
// `$(( ))` reads a leading zero as an octal prefix (verified on the stand,
// interfaces.md ticket 06) -- `parseInt('08', 10)` has no such ambiguity.
function gbFieldValid(expr, min, max) {
	var terms, i, term, rangeStr, stepStr, step, idx, loStr, hiStr, lo, hi;

	// A leading, trailing or doubled comma has to be rejected before the
	// split below: naive splitting on "," would otherwise turn "5," into
	// the single term "5" (JS, unlike busybox ash's IFS-splitting, does
	// keep a trailing empty field, but that empty field is caught the same
	// way any other empty term is below -- checked here up front anyway so
	// this stays one rule instead of two, same as _gb_field_values' own
	// comment explains for its own, differently-shaped pitfall).
	if (expr === '' || /^,|,$|,,/.test(expr))
		return false;

	terms = expr.split(',');
	for (i = 0; i < terms.length; i++) {
		term = terms[i];
		if (!term)
			return false;

		rangeStr = term;
		step = 1;

		idx = term.indexOf('/');
		if (idx !== -1) {
			rangeStr = term.slice(0, idx);
			stepStr = term.slice(idx + 1);
			if (!/^[0-9]+$/.test(stepStr))
				return false;
			step = parseInt(stepStr, 10);
			// A step of 0, or bigger than the field's own span, parses
			// without complaint in real busybox crond but silently
			// degenerates to firing on the field's single lowest value
			// forever (measured on the stand, interfaces.md ticket 06) --
			// exactly the "looks configured, never really runs" trap this
			// validator exists to catch before it reaches a crontab.
			if (step < 1 || step > max)
				return false;
		}

		if (rangeStr === '*') {
			lo = min;
			hi = max;
		} else if (rangeStr.indexOf('-') !== -1) {
			idx = rangeStr.indexOf('-');
			loStr = rangeStr.slice(0, idx);
			hiStr = rangeStr.slice(idx + 1);
			if (!/^[0-9]+$/.test(loStr) || !/^[0-9]+$/.test(hiStr))
				return false;
			lo = parseInt(loStr, 10);
			hi = parseInt(hiStr, 10);
			if (lo < min || lo > max || hi < min || hi > max)
				return false;
			// A reversed range ("5-2") parses in real busybox crond too,
			// but produces a bitmap wrong in a way no user intended
			// (measured on the stand) -- rejected here instead of
			// reproduced.
			if (lo > hi)
				return false;
		} else {
			if (!/^[0-9]+$/.test(rangeStr))
				return false;
			lo = hi = parseInt(rangeStr, 10);
			if (lo < min || lo > max)
				return false;
		}
	}

	return true;
}

// gbCronValid <expr> -- { valid: true } or { valid: false, reason: '...' },
// reason text copied verbatim from gb_cron_valid's own printf strings
// (schedule.sh) so the two validators do not merely agree on the verdict
// but say the same thing for it -- the brief's own acceptance criterion
// ("@daily отклоняется обоими с одинаковым текстом") asks for exactly
// that, not just a matching boolean.
function gbCronValid(expr) {
	var e = expr || '';
	var trimmed, fields;

	if (e.charAt(0) === '@') {
		return {
			valid: false,
			reason: _('busybox crond does not understand "%s" (no @-macro support on 25.12); use an explicit expression, e.g. "0 3 * * *" for once a day at 03:00').format(e)
		};
	}

	trimmed = e.replace(/^\s+|\s+$/g, '');
	fields = trimmed ? trimmed.split(/\s+/) : [];

	if (fields.length !== 5) {
		return {
			valid: false,
			reason: _('a cron expression needs exactly 5 fields (minute hour day-of-month month day-of-week), got %d in "%s"').format(fields.length, e)
		};
	}

	if (!gbFieldValid(fields[0], 0, 59))
		return { valid: false, reason: _('%s field is not a valid value, range, step or list of them in "%s"').format('minute', e) };
	if (!gbFieldValid(fields[1], 0, 23))
		return { valid: false, reason: _('%s field is not a valid value, range, step or list of them in "%s"').format('hour', e) };
	if (!gbFieldValid(fields[2], 1, 31))
		return { valid: false, reason: _('%s field is not a valid value, range, step or list of them in "%s"').format('day-of-month', e) };
	if (!gbFieldValid(fields[3], 1, 12))
		return { valid: false, reason: _('%s field is not a valid value, range, step or list of them in "%s"').format('month', e) };
	if (!gbFieldValid(fields[4], 0, 6))
		return { valid: false, reason: _('%s field is not a valid value, range, step or list of them in "%s"').format('day-of-week', e) };

	return { valid: true };
}

// ---------------------------------------------------------------------
// Copy-without-secure-context (spec, verbatim): navigator.clipboard is
// only reachable in a secure context, and LuCI reached over plain LAN
// http:// -- overwhelmingly the common case for a home router -- is not
// one. The fallback builds a throwaway <textarea> *inside the node this
// view already owns* (never document.body -- rule 10 of the style guide),
// selects it and asks the browser to copy the current selection with the
// old execCommand('copy') API, then removes the node again either way.
// Returns a plain boolean, synchronously, so a caller never has to guess
// whether "Copied" is true -- see gbCopyText below for the async wrapper
// that also tries the modern API first when it is actually available.
function gbCopyViaTextarea(text, container) {
	var ta = document.createElement('textarea');
	var ok = false;

	ta.value = text;
	ta.setAttribute('readonly', 'readonly');
	// Off-screen, not display:none -- select()/execCommand('copy') both
	// require the node to actually be rendered to work in every browser
	// this has been checked against.
	ta.style.position = 'fixed';
	ta.style.top = '0';
	ta.style.left = '0';
	ta.style.opacity = '0';
	container.appendChild(ta);

	ta.focus();
	ta.select();
	ta.setSelectionRange(0, text.length);

	try {
		ok = document.execCommand('copy');
	} catch (e) {
		ok = false;
	}

	container.removeChild(ta);
	return ok;
}

// gbCopyText <text> <container> -- Promise<boolean>. Tries the modern,
// secure-context-only API first (nicer for the https:// case this stand
// itself is not, but some deployments are), falls back to the textarea
// trick otherwise or if the modern API itself rejects. The caller (see
// handleCopyPubkey below) is what enforces "show 'Copied' only on actual
// success, never on the mere click" -- this function's own contract is
// simply to never resolve `true` unless a copy really happened.
function gbCopyText(text, container) {
	if (window.isSecureContext && window.navigator && navigator.clipboard && navigator.clipboard.writeText) {
		return navigator.clipboard.writeText(text).then(function() {
			return true;
		}, function() {
			return gbCopyViaTextarea(text, container);
		});
	}

	return Promise.resolve(gbCopyViaTextarea(text, container));
}

// ---------------------------------------------------------------------
// `Test connection` outcome classification -- deliberately a separate,
// narrower copy of overview.js's own gbClassifyLog, not a shared helper:
// each view here is self-contained by this project's own established
// convention (paths.js's own GB_CSS/gbSequentialMap, history.js's own
// gbCommitTime, both duplicated rather than factored out). Keyed on
// cmd_test's own fixed set of gb_log/gb_die lines (usr/sbin/gitbackup,
// out of this ticket's zone, read before writing this) -- the exact three
// ways a connection test can fail per the brief ("для каждого из трёх
// отказов"): the remote could not be reached at all, it was reached but
// authentication failed, or it was confirmed publicly visible and refused
// on sight. "Could not verify" (network/API down while checking
// visibility) is a fourth, narrower case cmd_test's own gb_visibility_ok
// branch can also produce; folding it into "network" would misreport a
// case where the *credentials* were never even tried as an auth failure.
function gbClassifyTestLog(text) {
	var lines = (text || '').split('\n');
	var i, line;

	for (i = lines.length - 1; i >= 0; i--) {
		line = lines[i];
		if (!line)
			continue;

		if (line.indexOf('reachable and authenticated') !== -1)
			return { kind: 'ok', message: _('Connected -- the remote is reachable and the credentials work.') };

		if (line.indexOf('publicly visible to an anonymous request') !== -1)
			return { kind: 'public', message: _('Blocked: this repository is publicly visible to an anonymous request. Push is refused until it is made private, or the remote is changed.') };

		if (line.indexOf('could not verify whether') !== -1 && line.indexOf('is public') !== -1)
			return { kind: 'unknown_visibility', message: _('Could not verify whether the repository is public -- the network or the provider\'s API was unreachable. Try again once connectivity is confirmed.') };

		if (line.indexOf('cannot reach ') !== -1)
			return { kind: 'network', message: _('Could not reach the remote -- check the URL, DNS and internet connectivity.') };

		if (line.indexOf('authentication to ') !== -1 && line.indexOf('failed') !== -1)
			return { kind: 'auth', message: _('The remote was reached, but authentication failed -- check the deploy key or the token.') };

		if (line.indexOf('host key was not accepted') !== -1)
			return { kind: 'auth', message: _('The SSH host key was not accepted.') };

		if (line.indexOf('host key could not be obtained') !== -1)
			return { kind: 'network', message: _('Could not reach the remote to obtain its SSH host key -- check the URL and connectivity.') };
	}

	return { kind: 'pending', message: _('Waiting for the test to finish…') };
}

// Terminal markers for the live-log poller below -- same convention and
// same reasoning as overview.js's own GB_LOG_TERMINAL_RE: one regex so the
// "did this just finish" check and gbClassifyTestLog's own "what happened"
// check can never disagree about where a run ends.
var GB_TEST_TERMINAL_RE = new RegExp(
	[
		'reachable and authenticated',
		'publicly visible to an anonymous request',
		'could not verify whether .* is public',
		'cannot reach ',
		'authentication to .* failed',
		'host key was not accepted',
		'host key could not be obtained'
	].join('|')
);

// gbBuildDeployKeyBody <view> -- the deploy-key textarea/Copy/Regenerate
// block, or the "no key yet" placeholder with a Generate button. A
// standalone builder (rather than inline in the DummyValue's own
// renderWidget below) so handleGenerateKey can rebuild just this one node
// by id after keygen succeeds (same "patch one subtree, not the whole
// page" convention paths.js's own renderBody/gbBuild*Box functions
// already use) instead of re-rendering the entire form.Map and losing
// whatever else the operator was mid-editing elsewhere on the page.
function gbBuildDeployKeyBody(view) {
	var pubkey = view._pubkey;
	var wrap = E('div', { 'id': 'gitbackup-deploykey-body' }, []);

	if (pubkey) {
		wrap.appendChild(E('textarea', {
			'class': 'gitbackup-pubkey',
			'id': 'gitbackup-pubkey-text',
			'rows': '3',
			'readonly': 'readonly'
		}, pubkey));
		wrap.appendChild(E('div', { 'class': 'gitbackup-actions' }, [
			E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'click': ui.createHandlerFn(view, 'handleCopyPubkey')
			}, _('Copy')),
			E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'click': ui.createHandlerFn(view, 'handleGenerateKey', true)
			}, _('Regenerate key')),
			E('span', { 'class': 'gitbackup-copy-status', 'id': 'gitbackup-copy-status' }, '')
		]));
	} else {
		wrap.appendChild(E('p', {}, _('No deploy key has been generated on this router yet.')));
		wrap.appendChild(E('div', { 'class': 'gitbackup-actions' }, [
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(view, 'handleGenerateKey', false)
			}, _('Generate deploy key'))
		]));
	}

	return wrap;
}

var GB_CSS = [
	'.gitbackup-view { container-type: inline-size; }',
	'.gitbackup-box { border: 1px solid var(--background-color-medium, #ddd); border-radius: 4px; padding: .75em 1em; margin: .5em 0; background: var(--background-color-low, #f5f5f5); }',
	'.gitbackup-box p { margin: .3em 0; }',
	'.gitbackup-box-title { font-weight: bold; color: var(--text-color-high, #333); margin: 0 0 .4em; }',
	'.gitbackup-leak-list { margin: .3em 0; padding-left: 1.2em; color: var(--text-color-high, #333); }',
	'.gitbackup-pubkey { width: 100%; box-sizing: border-box; font-family: monospace; font-size: .8em; resize: vertical; }',
	'.gitbackup-actions { display: flex; flex-wrap: wrap; gap: .5em; margin: .5em 0; align-items: center; }',
	'@container (max-width: 480px) { .gitbackup-actions { flex-direction: column; align-items: stretch; } }',
	'.gitbackup-copy-status { font-size: .85em; color: var(--text-color-medium, #666); }',
	'.gitbackup-warn-text { color: var(--warn-color-high, #b45f06); font-weight: bold; }',
	'.gitbackup-hint { font-size: .85em; color: var(--text-color-medium, #666); margin-top: .3em; }',
	'.gitbackup-hint-ok { color: var(--success-color-high, #2e7d32); }',
	'.gitbackup-hint-error { color: var(--error-color-high, #c62828); }',
	'.gitbackup-log { max-height: 220px; overflow: auto; background: var(--background-color-low, #f5f5f5); color: var(--text-color-high, #333); border: 1px solid var(--background-color-medium, #ddd); border-radius: 4px; padding: .5em .7em; font-family: monospace; font-size: .8em; white-space: pre-wrap; margin-top: .5em; }',
	'.gitbackup-test-result { font-weight: bold; margin-top: .4em; }'
];

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(callStatus(), null),
			L.resolveDefault(callPubkey(), null)
		]);
	},

	render: function(data) {
		var self = this;
		var m, s, o, oUrl, oProvider, oAuth;

		self._status = data[0] || {};
		self._pubkey = (data[1] && typeof data[1].pubkey === 'string') ? data[1].pubkey : null;

		m = new form.Map('gitbackup', _('Git Backup - Settings'),
			_('Configuration for the whole gitbackup package. Saving reloads the schedule and, if the repository is public, forces config scrubbing on -- see the Overview tab for what that means.'));

		// -----------------------------------------------------------
		// Section "main" (UCI schema: "config gitbackup 'main'")
		// -----------------------------------------------------------
		s = m.section(form.NamedSection, 'main', 'gitbackup', _('General'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'),
			_('Turns the whole package on or off -- scheduled runs, the config-change trigger and manual "Backup now" all stay inert while this is unchecked.'));

		o = s.option(form.Flag, 'archive', _('Keep a local archive'),
			_('Also write a backup.tar.gz next to the working tree on every run, for a quick local copy in addition to the git history.'));
		o.default = '1';

		o = s.option(form.ListValue, 'device_id', _('Device identifier'),
			_('How this router names itself in the repository -- its own branch and path prefix are built from this.'));
		o.value('hostname', _('System hostname'));
		o.value('custom', _('Custom name (set below)'));
		o.value('board', _('Board model'));
		o.default = 'hostname';

		o = s.option(form.Value, 'device', _('Custom device name'),
			_('Used only when "Device identifier" above is set to "Custom name".'));
		o.depends('device_id', 'custom');

		o = s.option(form.Value, 'path_prefix', _('Path prefix'),
			_('Where this device\'s files live inside the repository. "{device}" is replaced with the resolved device identifier.'));
		o.placeholder = 'devices/{device}';
		o.default = 'devices/{device}';

		o = s.option(form.Flag, 'on_config_change', _('Back up on config change'),
			_('Watches every UCI config in the backup set and starts a run a short while after any of them changes, instead of waiting for the next scheduled run.'));
		o.default = '1';

		o = s.option(form.Value, 'debounce', _('Debounce (seconds)'),
			_('How long to wait after the last detected config change before actually starting a run -- a burst of edits in the UI collapses into one commit instead of one per change.'));
		o.datatype = 'uinteger';
		o.placeholder = '60';
		o.default = '60';
		o.depends('on_config_change', '1');

		o = s.option(form.ListValue, 'schedule', _('Schedule'));
		o.value('off', _('Off -- manual backups only'));
		o.value('hourly', _('Hourly (minute chosen per device)'));
		o.value('daily', _('Daily, once in a randomized night window'));
		o.value('weekly', _('Weekly, once in a randomized night window'));
		o.value('cron', _('Custom cron expression'));
		o.default = 'daily';
		o.description = _('The hourly/daily/weekly presets deliberately do not all fire at the same wall-clock time: the minute (and, for daily/weekly, the hour) is derived from this device\'s own identifier, so a whole fleet of routers on the same preset does not wake up in the same second and hit the provider\'s API all at once.');

		o = s.option(form.Value, 'cron_expr', _('Cron expression'),
			_('Five fields: minute hour day-of-month month day-of-week. Validated live against exactly the grammar busybox crond on this router understands -- it has no "@daily"/"@hourly"/"@reboot" support at all, and silently drops any line shorter than five fields.'));
		o.placeholder = '0 3 * * *';
		o.depends('schedule', 'cron');
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			var node = form.Value.prototype.renderWidget.apply(this, arguments);
			var input = node.querySelector('input');
			var hint = E('div', { 'class': 'gitbackup-hint', 'id': 'gitbackup-cron-hint' }, '');
			var self2 = this;
			var timer = null;

			function reasonToText(res) {
				if (!res) {
					hint.className = 'gitbackup-hint';
					hint.textContent = '';
					return;
				}
				if (!res.valid) {
					hint.className = 'gitbackup-hint gitbackup-hint-error';
					hint.textContent = res.reason;
					return;
				}
				hint.className = 'gitbackup-hint gitbackup-hint-ok';
				hint.textContent = res.next ?
					_('Next run: %s UTC').format(res.next) :
					_('Valid, but the next run time could not be computed.');
			}

			function revalidate() {
				var expr = input.value;
				var local;

				if (!expr) {
					hint.className = 'gitbackup-hint';
					hint.textContent = '';
					return;
				}

				// Instant, local verdict first (rule of this ticket: "своя
				// JS-проверка мгновенна") -- an invalid expression never
				// waits on a round trip through uhttpd's own "-n 3"
				// concurrent-call ceiling (interfaces.md, ticket 13) to
				// turn red.
				local = gbCronValid(expr);
				if (!local.valid) {
					reasonToText(local);
					return;
				}

				// Locally valid: ask the backend for the one thing only it
				// can compute authoritatively -- the actual next run time
				// (gb_cron_next, schedule.sh) -- rather than reimplementing
				// crontab day/hour/minute arithmetic a third time. The two
				// validators are proven to agree on the fixtures
				// (tests/settings_cron_fixture.test.js), so this call is
				// not expected to ever answer "invalid" here; if it somehow
				// did, its own reason still wins over silence.
				L.resolveDefault(callValidateCron(expr), null).then(function(res) {
					if (input.value !== expr)
						return;
					reasonToText(res || { valid: true, next: null });
				});
			}

			input.addEventListener('input', function() {
				if (timer)
					clearTimeout(timer);
				timer = setTimeout(revalidate, 300);
			});

			node.appendChild(hint);
			if (cfgvalue)
				setTimeout(revalidate, 0);

			return node;
		};

		// -----------------------------------------------------------
		// Section "origin" (UCI schema: "config remote 'origin'")
		// -----------------------------------------------------------
		s = m.section(form.NamedSection, 'origin', 'remote', _('Remote'));
		s.addremove = false;

		oUrl = s.option(form.Value, 'url', _('Repository URL'),
			_('One of: git@host:owner/repo.git, ssh://[user@]host[:port]/owner/repo.git, or https://host[:port]/owner/repo.git.'));
		oUrl.placeholder = 'git@github.com:owner/repo.git';

		o = s.option(form.Value, 'branch', _('Branch'),
			_('"{device}" is replaced with the resolved device identifier -- the default gives every device its own branch on a shared repository.'));
		o.placeholder = 'device/{device}';
		o.default = 'device/{device}';

		oAuth = s.option(form.ListValue, 'auth', _('Authentication'));
		oAuth.value('sshkey', _('SSH deploy key'));
		oAuth.value('token', _('API token'));
		oAuth.default = 'sshkey';

		oProvider = s.option(form.ListValue, 'provider', _('Provider'),
			_('"Auto" detects github.com/gitlab.com/bitbucket.org/codeberg.org by hostname and treats anything else as generic (self-hosted, unknown API). Set this explicitly if a self-hosted GitLab or Gitea/Forgejo instance should get that provider\'s deploy-key link instead of the generic instructions.'));
		oProvider.value('auto', _('Auto-detect'));
		oProvider.value('github', 'GitHub');
		oProvider.value('gitlab', 'GitLab');
		oProvider.value('gitea', _('Gitea / Forgejo'));
		oProvider.value('bitbucket', 'Bitbucket');
		oProvider.value('generic', _('Generic (self-hosted, unknown API)'));
		oProvider.default = 'auto';

		// Test connection -- kept close to the deploy-key/token fields
		// (spec: "Рядом -- кнопка Test connection"), but not gated on
		// auth=sshkey: it exercises whichever credential is actually
		// configured (auth.sh's gb_git_env picks the transport), so a
		// token-auth setup needs this exactly as much as a deploy-key one.
		o = s.option(form.DummyValue, '_test', _('Connection test'));
		o.rawhtml = true;
		o.cfgvalue = function() { return null; };
		o.renderWidget = function(section_id) {
			var self2 = this;
			var wrap = E('div', {}, [
				E('div', { 'class': 'gitbackup-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'id': 'gitbackup-btn-test',
						'click': ui.createHandlerFn(self, 'handleTestConnection')
					}, _('Test connection'))
				]),
				E('div', { 'id': 'gitbackup-test-result', 'class': 'gitbackup-test-result' }),
				E('pre', { 'class': 'gitbackup-log', 'id': 'gitbackup-test-log', 'hidden': true }, '')
			]);
			return wrap;
		};

		// Deploy key -- ssh auth only (spec: brief §5.3 is entirely about
		// the ssh transport; a token has no public half to publish or copy).
		o = s.option(form.DummyValue, '_deploykey', _('Deploy key'));
		o.rawhtml = true;
		o.cfgvalue = function() { return null; };
		o.depends('auth', 'sshkey');
		o.renderWidget = function() {
			return gbBuildDeployKeyBody(self);
		};

		// Known-provider deep link -- shown only when the *resolved*
		// provider (gbResolveProvider: the explicit option, or the
		// host-based guess when it is "auto") is one of the four with a
		// real "add deploy key" page. Overridden checkDepends, not
		// .depends(): a plain dependency can only compare this section's
		// "provider" option against a literal value, and cannot express
		// "auto, but the host happens to resolve to something other than
		// generic" at all -- see gbResolveProvider's own comment. Reusing
		// checkDepends (rather than hand-rolled DOM listeners on the url/
		// provider inputs) is deliberate: the framework already calls
		// every option's checkDepends on every field's change event
		// (form.js: AbstractSection.checkDepends iterates `this.children`
		// unconditionally), so this integrates with the same reactivity
		// every ordinary `.depends()` field already gets, live-updating
		// as the operator types the URL or changes the provider dropdown,
		// with no extra plumbing of its own.
		//
		// checkDepends only ever toggles *visibility* natively (form.js:
		// AbstractSection.checkDepends calls o.setActive(sid, ...), never
		// re-renders anything) -- so besides returning whether this row is
		// active, this ALSO rebuilds its own content in place (by id) on
		// every check, not only the first paint. Confirmed live on the
		// owlab stand this ticket's own acceptance criteria are checked
		// against: without this, typing a github.com URL correctly
		// unhides the row but leaves it showing the stale "enter a valid
		// URL" hint computed back when the field was still empty.
		o = s.option(form.DummyValue, '_deploylink', _('Add the key to the repository'));
		o.rawhtml = true;
		o.cfgvalue = function() { return null; };
		o.checkDepends = function(section_id) {
			var auth = this.section.formvalue(section_id, 'auth');
			var url = this.section.formvalue(section_id, 'url');
			var provider = this.section.formvalue(section_id, 'provider');
			var resolved = gbResolveProvider(url, provider);
			var active = auth === 'sshkey' && resolved !== 'generic';
			var old = document.getElementById('gitbackup-deploylink-body');

			if (old && old.parentNode)
				old.parentNode.replaceChild(this.renderWidget(section_id), old);

			return active;
		};
		o.renderWidget = function(section_id) {
			var url = this.section.formvalue(section_id, 'url');
			var provider = this.section.formvalue(section_id, 'provider');
			var info = gbDeeplinkInfo(url, provider);
			var wrap = E('div', { 'id': 'gitbackup-deploylink-body', 'class': 'gitbackup-box' }, [
				E('p', { 'class': 'gitbackup-warn-text' },
					_('Before saving the key on the provider, tick "Allow write access" (or the equivalent) -- without it the key can read the repository but every push fails silently.'))
			]);

			if (info.kind === 'link') {
				wrap.appendChild(E('div', { 'class': 'gitbackup-actions' }, [
					E('a', {
						'href': info.url,
						'target': '_blank',
						'rel': 'noopener noreferrer',
						'class': 'cbi-button cbi-button-action'
					}, _('Open the repository’s deploy-key page'))
				]));
			} else {
				wrap.appendChild(E('p', { 'class': 'gitbackup-hint' },
					_('Enter a valid repository URL above to get a direct link to the provider’s deploy-key page.')));
			}

			return wrap;
		};

		// Generic-provider instructions -- the exact complement of
		// _deploylink above (same auth=sshkey gate, opposite resolved-
		// provider condition, same "rebuild content on every checkDepends,
		// not only visibility" fix), never a link: there is no such page
		// on an arbitrary self-hosted git server (brief §5.3, gb_deeplink's
		// own "generic" case, remoteurl.sh).
		o = s.option(form.DummyValue, '_deploygeneric', _('Add the key to the server'));
		o.rawhtml = true;
		o.cfgvalue = function() { return null; };
		o.checkDepends = function(section_id) {
			var auth = this.section.formvalue(section_id, 'auth');
			var url = this.section.formvalue(section_id, 'url');
			var provider = this.section.formvalue(section_id, 'provider');
			var resolved = gbResolveProvider(url, provider);
			var active = auth === 'sshkey' && resolved === 'generic';
			var old = document.getElementById('gitbackup-deploygeneric-body');

			if (old && old.parentNode)
				old.parentNode.replaceChild(this.renderWidget(section_id), old);

			return active;
		};
		o.renderWidget = function(section_id) {
			var url = this.section.formvalue(section_id, 'url');
			var provider = this.section.formvalue(section_id, 'provider');
			var info = gbDeeplinkInfo(url, provider);
			var host = (info.kind === 'generic') ? info.host : _('the server');
			var pubkeyText = self._pubkey ? self._pubkey.replace(/\s+$/, '') : 'ssh-ed25519 AAAA... gitbackup';

			return E('div', { 'id': 'gitbackup-deploygeneric-body', 'class': 'gitbackup-box' }, [
				E('p', {},
					_('This provider has no API to link to a settings page. On %s, append the public key above to the "git" user’s ~/.ssh/authorized_keys, ideally prefixed with restrict,command="git-shell" so the key can only run git operations, e.g.:').format(host)),
				E('pre', { 'class': 'gitbackup-log' },
					'restrict,command="git-shell" ' + pubkeyText)
			]);
		};

		o = s.option(form.Value, 'key_file', _('Deploy key path'));
		o.placeholder = '/etc/gitbackup/id_ed25519';
		o.default = '/etc/gitbackup/id_ed25519';
		o.depends('auth', 'sshkey');

		// Token -- NOT one of the UCI options above: the schema only ever
		// stores gitbackup.origin.token_file (a *path*), never the secret
		// itself (interfaces.md: "Метода get_secret не существует",
		// spec's UCI schema section). This field is deliberately virtual --
		// cfgvalue always answers null/empty so the browser never receives
		// the stored secret back (rule: "значение не появляется... в
		// DOM"), and write() goes to set_secret over rpcd rather than
		// uci.set(), so a save never puts it in the config file either
		// (rule: "не появляется... в UCI"). rmempty=true means leaving
		// this blank on save changes nothing -- the only way to change a
		// stored token is to type a new one; there is no "clear" control
		// here because gbrpc_status only ever reports token_set as a
		// boolean, so there is no already-blank state a fresh page load
		// could show to distinguish "never set" from "just cleared".
		o = s.option(form.Value, '_token', _('API token'));
		o.password = true;
		o.rmempty = true;
		o.depends('auth', 'token');
		o.placeholder = self._status.token_set ?
			'••••• (configured)' :
			_('paste a token to enable token authentication');
		o.cfgvalue = function() { return null; };
		o.write = function(section_id, formvalue) {
			return callSetSecret(formvalue);
		};
		o.remove = function() { return null; };

		o = s.option(form.Value, 'token_file', _('Token file path'));
		o.placeholder = '/etc/gitbackup/token';
		o.default = '/etc/gitbackup/token';
		o.depends('auth', 'token');

		o = s.option(form.Value, 'ca_file', _('Custom CA certificate path'),
			_('Only needed for an https remote behind a private certificate authority. Leave empty to use the system’s own trust store.'));
		o.optional = true;
		o.depends('auth', 'token');

		o = s.option(form.ListValue, 'visibility', _('Repository visibility'));
		o.value('private', _('Private'));
		o.value('public', _('Public'));
		o.default = 'private';

		o = s.option(form.DummyValue, '_visibility_private', '');
		o.rawhtml = true;
		o.cfgvalue = function() { return null; };
		o.depends('visibility', 'private');
		o.renderWidget = function() {
			return E('div', { 'class': 'gitbackup-box' }, [
				E('p', {}, _('The remote is expected to be private. Before every push, this is checked anonymously against the provider’s API (no token needed for the check itself) -- if the repository turns out to be publicly visible, the push is refused outright and a red banner appears on the Overview tab. Config scrubbing stays off unless something else requires it.'))
			]);
		};

		o = s.option(form.DummyValue, '_visibility_public', '');
		o.rawhtml = true;
		o.cfgvalue = function() { return null; };
		o.depends('visibility', 'public');
		o.renderWidget = function() {
			return E('div', { 'class': 'gitbackup-box' }, [
				E('p', { 'class': 'gitbackup-warn-text' }, _('Anyone with the URL will be able to read every backup ever pushed.')),
				E('p', {}, _('Saving this forces config scrubbing on (Security section below): the following are stripped from every config file before it is committed --')),
				E('ul', { 'class': 'gitbackup-leak-list' }, [
					E('li', {}, _('every value listed under "Scrub these UCI options" below (Wi-Fi pre-shared keys by default)'))
				]),
				E('p', {}, _('Restoring from a public branch will therefore be incomplete: scrubbed values are gone from the backup entirely and have to be re-entered by hand after a restore, the same way a factory-reset router would need them re-entered.'))
			]);
		};

		o = s.option(form.Flag, 'acknowledged', _('I accept the risk and confirm this repository is actually private'));
		o.checkDepends = function(section_id) {
			var url = this.section.formvalue(section_id, 'url');
			var provider = this.section.formvalue(section_id, 'provider');
			return gbResolveProvider(url, provider) === 'generic';
		};
		o.validate = function(section_id, value) {
			var url = this.section.formvalue(section_id, 'url');
			var provider = this.section.formvalue(section_id, 'provider');
			if (gbResolveProvider(url, provider) !== 'generic')
				return true;
			if (value === this.enabled)
				return true;
			return _('This provider cannot be checked automatically -- tick the box above to confirm the repository is private before saving.');
		};
		o.renderWidget = function(section_id, option_index, cfgvalue) {
			var node = form.Flag.prototype.renderWidget.apply(this, arguments);
			var wrap = E('div', { 'class': 'gitbackup-box' }, [
				E('p', { 'class': 'gitbackup-box-title' },
					_('This provider’s visibility cannot be checked automatically (spec: "generic — проверить нельзя ни при каких условиях"). If this repository is actually public, everything below is exposed in plain text to anyone who can read it:')),
				E('ul', { 'class': 'gitbackup-leak-list' }, [
					E('li', {}, '/etc/shadow'),
					E('li', {}, _('dropbear private host keys')),
					E('li', {}, 'authorized_keys'),
					E('li', {}, _('WPA pre-shared keys (Wi-Fi passwords)')),
					E('li', {}, _('WireGuard private keys')),
					E('li', {}, _('PPPoE credentials')),
					E('li', {}, 'uhttpd.key')
				]),
				node
			]);
			return wrap;
		};

		// -----------------------------------------------------------
		// Section "security" (UCI schema: "config security 'security'")
		// -----------------------------------------------------------
		s = m.section(form.NamedSection, 'security', 'security', _('Security'));
		s.addremove = false;

		o = s.option(form.Flag, 'scrub', _('Scrub secrets before committing'),
			_('Forced on automatically whenever "Repository visibility" above is set to Public -- this checkbox only matters while it is still Private.'));

		o = s.option(form.DynamicList, 'scrub_option', _('Scrub these UCI options'),
			_('UCI paths to blank out before every commit, e.g. "wireless.@wifi-iface[*].key". Applied with uci -c against a scratch copy of the config tree, never touching the router’s own live configuration.'));
		o.placeholder = 'wireless.@wifi-iface[*].key';

		// Style returned inside this view's own tree (rule 1 of the spec's
		// style guide), by inserting it into the `.cbi-map` node m.render()
		// itself hands back rather than wrapping that node in a further
		// <div> -- the returned node IS this view's root either way, so
		// this satisfies the rule the same way overview.js/paths.js/
		// history.js do with their own top-level E('div', ...) wrapper.
		// Every rule from that guide applies here identically: selectors
		// prefixed "gitbackup-" (rule 2), no `:root{}`/`*{}` (rule 3),
		// colors from the theme's exported token tier with a literal
		// fallback and the "warn" family spelled "warn" (rules 4-5), no
		// `--fs-*` (rule 6), no `!important` (rule 7), no dark-mode media
		// query -- every color already comes from a token (rule 8),
		// `@container` rather than `@media` for the one place layout reacts
		// to width (rule 9), no window.onload/document.body/absurd z-index
		// and this view's one custom poller (the test-connection live log)
		// is bounded and explicitly stopped (rule 10), stock Save/Apply/
		// Reset left alone rather than hidden with CSS (rule 11 -- see the
		// file header comment for why this view, unlike the other three,
		// does not null them out at all).
		return m.render().then(function(mapEl) {
			mapEl.classList.add('gitbackup-view');
			mapEl.insertBefore(E('style', { 'type': 'text/css' }, [ GB_CSS.join('\n') ]), mapEl.firstChild);
			return mapEl;
		});
	},

	// handleGenerateKey <force> -- calls keygen (gbrpc_keygen -- ticket
	// 08-10, synchronous, unlike run/test/restore) and patches just the
	// "#gitbackup-deploykey-body" subtree in place (gbBuildDeployKeyBody
	// above) rather than re-rendering the whole form.Map, so an edit the
	// operator has mid-typed anywhere else on this page survives. <force>
	// is only ever true from the "Regenerate key" button (an existing key
	// is otherwise left alone by gb_keygen itself, which refuses to
	// overwrite one without it -- auth.sh, out of this ticket's zone).
	handleGenerateKey: function(force, ev) {
		var self = this;
		var btn = ev.target;

		btn.disabled = true;

		return callKeygen(force ? true : undefined).then(function(res) {
			if (!res || res.ok !== true) {
				ui.addNotification(null, E('p', {},
					_('Could not generate a deploy key: %s').format((res && res.reason) || _('unknown error'))), 'error');
				btn.disabled = false;
				return;
			}
			return L.resolveDefault(callPubkey(), null).then(function(pk) {
				var old = document.getElementById('gitbackup-deploykey-body');

				self._pubkey = (pk && typeof pk.pubkey === 'string') ? pk.pubkey : null;

				if (old && old.parentNode)
					old.parentNode.replaceChild(gbBuildDeployKeyBody(self), old);
			});
		}, function(e) {
			ui.addNotification(null, E('p', {}, _('Could not generate a deploy key: %s').format(e.message)), 'error');
			btn.disabled = false;
		});
	},

	// handleCopyPubkey -- spec, verbatim: "Скопировано" показывается
	// только по факту успеха, не по факту нажатия". The textarea fallback
	// (gbCopyText/gbCopyViaTextarea above) is built and torn down inside
	// the map's own root node (`.cbi-map`, this view's returned tree),
	// never document.body -- rule 10 of the style guide.
	handleCopyPubkey: function(ev) {
		var statusEl = document.getElementById('gitbackup-copy-status');
		var container = document.querySelector('.cbi-map') || document.body;
		var text = this._pubkey || '';

		return gbCopyText(text, container).then(function(ok) {
			if (!statusEl)
				return;
			statusEl.textContent = ok ?
				_('Copied.') :
				_('Could not copy automatically -- select the text above and copy it by hand.');
		});
	},

	// setTestBusy/startTestLog/pollTestLog/stopTestLog -- overview.js's own
	// startLiveLog/pollLiveLog/stopLiveLog, adapted to `test`'s own
	// terminal-line set (GB_TEST_TERMINAL_RE above) instead of run/test's
	// combined one, and rendering gbClassifyTestLog's own human-readable
	// outcome into a dedicated result line rather than only a raw log tail.
	// Same bounds for the same reason: this poller must never outlive the
	// operation it watches (stopped on a matching terminal log line, after
	// 60s with no new output at all, or after a hard 5-minute ceiling
	// regardless), and it is torn down on navigating away from this view
	// the same way every poller in this project is -- LuCI's own view
	// lifecycle discards this whole JS context on tab switch, but a
	// poller left running while the operator stays on this same page long
	// after the test finished would still be a leak this view owns.
	handleTestConnection: function(ev) {
		var self = this;
		var btn = document.getElementById('gitbackup-btn-test');
		var resultEl = document.getElementById('gitbackup-test-result');

		if (btn)
			btn.disabled = true;
		if (resultEl)
			resultEl.textContent = _('Testing…');

		return self.startTestLog().then(function() {
			return callTest();
		}).then(function(res) {
			if (!res || res.started !== true) {
				ui.addNotification(null, E('p', {}, _('Could not start a connection test.')), 'error');
				self.stopTestLog();
				if (btn)
					btn.disabled = false;
			}
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Could not start a connection test: %s').format(e.message)), 'error');
			self.stopTestLog();
			if (btn)
				btn.disabled = false;
		});
	},

	startTestLog: function() {
		var self = this;
		var pre = document.getElementById('gitbackup-test-log');

		if (pre) {
			pre.hidden = false;
			pre.textContent = '';
		}

		self._testLogIdle = 0;
		self._testLogTicks = 0;

		return L.resolveDefault(callLog(500), null).then(function(res) {
			var text = (res && res.text) || '';
			self._testLogLines = text ? text.split('\n').length : 0;

			if (!self._boundTestLogPoll)
				self._boundTestLogPoll = L.bind(self.pollTestLog, self);

			poll.remove(self._boundTestLogPoll);
			poll.add(self._boundTestLogPoll, 2);
		});
	},

	stopTestLog: function() {
		if (this._boundTestLogPoll)
			poll.remove(this._boundTestLogPoll);
	},

	pollTestLog: function() {
		var self = this;

		self._testLogTicks = (self._testLogTicks || 0) + 1;

		return callLog(500).then(function(res) {
			var text = (res && res.text) || '';
			var lines = text.split('\n');
			var newLines = (lines.length >= self._testLogLines) ? lines.slice(self._testLogLines) : lines;
			var pre = document.getElementById('gitbackup-test-log');
			var resultEl = document.getElementById('gitbackup-test-result');
			var btn = document.getElementById('gitbackup-btn-test');
			var add = newLines.filter(function(l) { return l; }).join('\n');
			var finished = false;
			var i;

			self._testLogLines = lines.length;

			if (add) {
				self._testLogIdle = 0;
				if (pre) {
					pre.textContent = pre.textContent ? pre.textContent + '\n' + add : add;
					pre.scrollTop = pre.scrollHeight;
				}
				for (i = 0; i < newLines.length; i++) {
					if (GB_TEST_TERMINAL_RE.test(newLines[i]))
						finished = true;
				}
			} else {
				self._testLogIdle = (self._testLogIdle || 0) + 1;
			}

			if (finished) {
				self.stopTestLog();
				if (btn)
					btn.disabled = false;
				if (resultEl)
					resultEl.textContent = gbClassifyTestLog(text).message;
			} else if (self._testLogIdle >= 30 || self._testLogTicks >= 150) {
				self.stopTestLog();
				if (btn)
					btn.disabled = false;
				if (resultEl)
					resultEl.textContent = _('No result after a while -- check the log below or the syslog by hand.');
			}
		}, function() {
			self._testLogIdle = (self._testLogIdle || 0) + 30;
			if (self._testLogIdle >= 30) {
				self.stopTestLog();
				if (document.getElementById('gitbackup-btn-test'))
					document.getElementById('gitbackup-btn-test').disabled = false;
			}
		});
	}
});
