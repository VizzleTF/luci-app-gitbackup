'use strict';
'require view';
'require poll';
'require rpc';
'require uci';
'require ui';

// gitbackup -- Overview (ticket 11, spec "Решения по реализации -> LuCI ->
// Overview"). Client-side JS only, luci-base only -- no Lua, no
// luci-compat, no luci-lib-ipkg anywhere in this file or in its
// dependencies (LUCI_DEPENDS:=+gitbackup only).
//
// Written conservatively for OpenWrt buildbot's own jsmin.c (spec: "старый
// минификатор, не понимает современного синтаксиса, чувствителен к
// отсутствию точек с запятой") -- plain ES5 (`var`, `function`), no
// let/const, no arrow functions, no template literals, every statement
// terminated with an explicit semicolon.

// ---------------------------------------------------------------------
// rpcd bindings -- every object/method/param name below is copied from
// root/usr/share/rpcd/acl.d/luci-app-gitbackup.json and from
// usr/libexec/rpcd/luci.gitbackup's own gbrpc_* handlers (package/
// gitbackup). Nothing invented: `history`, `log`, `run`, `test`, `card`
// and `config_diff` are exactly the read methods and one of the two
// write methods this view uses. `config_diff` (gbrpc_config_diff) is a
// thin JSON wrapper around `gitbackup diff` (usr/sbin/gitbackup's own
// cmd_diff) -- it re-collects the current backup set and compares its
// manifest against the last commit's, field by field, so it catches a
// chmod/chown `git status`/`git diff` never sees at all (same blob, same
// tree entry mode class either way).
// ---------------------------------------------------------------------

var callStatus = rpc.declare({
	object: 'luci.gitbackup',
	method: 'status'
});

var callLog = rpc.declare({
	object: 'luci.gitbackup',
	method: 'log',
	params: [ 'lines' ]
});

var callHistory = rpc.declare({
	object: 'luci.gitbackup',
	method: 'history',
	params: [ 'limit' ]
});

var callConfigDiff = rpc.declare({
	object: 'luci.gitbackup',
	method: 'config_diff'
});

var callValidateCron = rpc.declare({
	object: 'luci.gitbackup',
	method: 'validate_cron',
	params: [ 'expr' ]
});

var callRun = rpc.declare({
	object: 'luci.gitbackup',
	method: 'run'
});

var callTest = rpc.declare({
	object: 'luci.gitbackup',
	method: 'test'
});

var callCard = rpc.declare({
	object: 'luci.gitbackup',
	method: 'card'
});

// service.list is procd's own stock ubus object, not part of this
// package's ACL declaration -- the same call luci-app-frpc/frps/natmap/
// irqbalance/transmission/... already make for their own "is my daemon
// running" checks (confirmed against those views in this checkout), and
// every LuCI session already has read access to it. Used only to answer
// the "crond stopped" banner (spec: "Красные баннеры: ... crond не
// запущен"). Confirmed live on the owlab stand: `ubus call service list
// '{"name":"cron"}'` answers `{"cron":{"instances":{"instance1":
// {"running":true,...}}}}` while crond is up, and a bare `{}` (no "cron"
// key at all) the moment `/etc/init.d/cron stop` has run -- that absence
// is exactly the signal this view treats as "not running".
var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ]
});

// ---------------------------------------------------------------------
// Remote URL parsing / provider deep link (view-commit URL)
//
// Deliberately NOT calling remoteurl.sh's gb_deeplink (package/gitbackup,
// out of this ticket's zone): that function builds the provider's *add a
// deploy key* settings page for the Settings tab (ticket 12), not a *view
// this commit* URL, and there is no rpcd method exposing it or an
// equivalent -- root/usr/share/rpcd/acl.d/luci-app-gitbackup.json's read
// tier lists exactly status/log/diff/pubkey/list_paths/history/
// audit_paths/validate_cron, nothing named "deeplink". This mirrors
// gb_parse_url/gb_provider's own per-host mapping (remoteurl.sh) in
// client JS instead, scoped to this view's own need: a link straight to
// the commit, not to the key-management page.
// ---------------------------------------------------------------------

function gbParseRemote(url) {
	var m;

	url = url || '';

	m = url.match(/^https:\/\/([^/:]+)(?::\d+)?\/([^/]+)\/([^/]+?)(?:\.git)?$/);
	if (m)
		return { host: m[1], owner: m[2], repo: m[3] };

	m = url.match(/^ssh:\/\/(?:[^@/]+@)?([^/:]+)(?::\d+)?\/([^/]+)\/([^/]+?)(?:\.git)?$/);
	if (m)
		return { host: m[1], owner: m[2], repo: m[3] };

	// scp-like alias syntax: "[user@]host:owner/repo(.git)?" -- same shape
	// remoteurl.sh's gb_parse_url accepts for this form, restricted the
	// same way: nothing before the first ":" may contain a "/".
	m = url.match(/^(?:[^@/:]+@)?([^/:]+):([^/]+)\/([^/]+?)(?:\.git)?$/);
	if (m)
		return { host: m[1], owner: m[2], repo: m[3] };

	return null;
}

function gbProvider(host, override) {
	if (override && override !== 'auto')
		return override;

	switch (host) {
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

function gbCommitUrl(parsed, provider, sha) {
	if (!parsed || !sha)
		return null;

	switch (provider) {
	case 'github':
		return 'https://github.com/' + parsed.owner + '/' + parsed.repo + '/commit/' + sha;
	case 'gitlab':
		return 'https://' + parsed.host + '/' + parsed.owner + '/' + parsed.repo + '/-/commit/' + sha;
	case 'gitea':
		return 'https://' + parsed.host + '/' + parsed.owner + '/' + parsed.repo + '/commit/' + sha;
	case 'bitbucket':
		return 'https://bitbucket.org/' + parsed.owner + '/' + parsed.repo + '/commits/' + sha;
	default:
		return null;
	}
}

// ---------------------------------------------------------------------
// Log classification -- "результат последнего прогона" (what the last
// completed `run` actually did: pushed, found nothing new, was blocked,
// skipped, failed) is read out of the `log` text (usr/sbin/gitbackup's
// cmd_log, a tag-filtered `logread`), not out of a dedicated field: what
// every completed `run` leaves behind is one of a small, fixed set of
// gb_log lines (usr/sbin/gitbackup, cmd_run/_gb_run_backup), so this
// reads the most recent one instead of inventing a structured result the
// backend does not produce.
//
// This is deliberately NOT how the live "has the config drifted from the
// last commit" indicator is computed any more -- that one used to be
// approximated from this same log line (a completed run's outcome, as of
// whenever that run finished) for lack of anything better, which could
// not reflect a single change made on the router afterward. It now comes
// from a dedicated, always-current check instead: see
// gbConfigDiffView/refreshConfigDiff below, backed by the config_diff
// rpcd method.
// ---------------------------------------------------------------------

function gbClassifyLog(text) {
	var lines = (text || '').split('\n');
	var i, line;

	for (i = lines.length - 1; i >= 0; i--) {
		line = lines[i];
		if (!line)
			continue;

		if (line.indexOf('publicly visible to an anonymous request') !== -1)
			return {
				kind: 'blocked_public',
				synced: null,
				message: _('Blocked: the repository is publicly visible to an anonymous request; the last push was refused.')
			};

		if (/pushed [0-9a-f]+ to /.test(line))
			return {
				kind: 'pushed',
				synced: true,
				message: _('Pushed a new commit on the last run.')
			};

		if (line.indexOf('no changes since the last backup') !== -1)
			return {
				kind: 'no_changes',
				synced: true,
				message: _('No changes since the last commit.')
			};

		if (line.indexOf('another run already holds the lock') !== -1)
			return {
				kind: 'skipped_lock',
				synced: null,
				message: _('Skipped: another run was already in progress.')
			};

		if (/unreachable, skipped/.test(line))
			return {
				kind: 'skipped_network',
				synced: null,
				message: _('Skipped: the remote was unreachable.')
			};

		if (line.indexOf('could not verify whether') !== -1 && line.indexOf('is public') !== -1)
			return {
				kind: 'skipped_visibility',
				synced: null,
				message: _('Skipped: could not verify whether the repository is public.')
			};

		if (line.indexOf('not enough space') !== -1)
			return {
				kind: 'error_space',
				synced: null,
				message: _('Failed: not enough free space under /tmp to build the backup set.')
			};

		if (line.indexOf('reachable and authenticated') !== -1)
			return {
				kind: 'test_ok',
				synced: null,
				message: _('Connection test succeeded.')
			};
	}

	return { kind: 'unknown', synced: null, message: _('No completed run recorded yet.') };
}

// Terminal markers for the live-log poller (handleRun/handleTest):
// matching any one of these on a freshly-arrived log line means the
// backgrounded CLI invocation has finished, one way or another. Kept as
// one regex so the "did this just finish" check in pollLiveLog and the
// "what was the outcome" check in gbClassifyLog can never name a
// different set of endings by accident.
var GB_LOG_TERMINAL_RE = new RegExp(
	[
		'pushed [0-9a-f]+ to ',
		'no changes since the last backup',
		'another run already holds the lock',
		'unreachable, skipped',
		'could not verify whether .* is public',
		'not enough space',
		'publicly visible to an anonymous request',
		'reachable and authenticated'
	].join('|')
);

function gbMissingText(key) {
	switch (key) {
	case 'device_id':
		return _('Device identifier could not be resolved (hostname is still the default "OpenWrt", or a custom device name is empty). Set it on the Settings tab.');
	case 'cron_expr':
		return _('Schedule is set to a custom cron expression, but it is not a valid 5-field busybox crontab line. Fix it on the Settings tab.');
	case 'url':
		return _('Repository URL is not set. Set it on the Settings tab.');
	default:
		return key;
	}
}

function gbScheduleText(schedule, cronExpr, cronNext) {
	var base;

	switch (schedule) {
	case 'off':
		return _('Disabled');
	case 'hourly':
		base = _('Hourly (minute chosen per device to avoid a fleet-wide stampede)');
		break;
	case 'daily':
		base = _('Daily, once in a randomized night window (00:00-05:59), per device');
		break;
	case 'weekly':
		base = _('Weekly, once in a randomized night window, per device');
		break;
	case 'cron':
		base = _('Custom cron: %s').format(cronExpr || '-');
		if (cronNext)
			base += ' — ' + _('next: %s UTC').format(cronNext);
		return base;
	default:
		return schedule || '-';
	}

	return base;
}

function gbFormatDate(iso) {
	var d;

	if (!iso)
		return _('never');

	d = new Date(iso);
	if (isNaN(d.getTime()))
		return iso;

	return d.toLocaleString();
}

function gbCommitTime(subject) {
	var m = (subject || '').match(/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})/);
	return m ? m[1] : null;
}

// ---------------------------------------------------------------------
// Pure view-model builders -- no DOM access at all, deliberately. LuCI's
// own view lifecycle (luci.js: `ready.then(load).then(render).then(nodes
// => DOM.content(vp, nodes))`) does not attach this view's tree to
// `document` until *after* render() has already returned -- confirmed by
// reading that chain directly. A `document.getElementById(...)` call
// made synchronously inside render() therefore always misses (the node
// exists only in memory at that point) and silently does nothing, since
// every DOM update below is behind an `if (el)` guard. These two
// functions compute what the initial paint AND every later poll tick
// should show, as plain data; render() below feeds their result straight
// into the E() tree it builds, and applyStatusDom/applyHistoryDom (used
// only from refreshStatus/refreshHistory, i.e. only after the view is
// already live) push the same shape into the DOM by id.
// ---------------------------------------------------------------------

function gbStatusView(status, logRes, serviceRes, schedule, cronExpr, cronNext) {
	var cls = gbClassifyLog((logRes && logRes.text) || '');
	var banners = [];
	var cronRunning = false;
	var k;

	if (!status.configured && status.missing && status.missing.length) {
		banners.push(_('Configuration is incomplete:') + ' ' + status.missing.map(gbMissingText).join(' '));
	}

	if (serviceRes && serviceRes.cron && serviceRes.cron.instances) {
		for (k in serviceRes.cron.instances) {
			if (serviceRes.cron.instances[k] && serviceRes.cron.instances[k].running)
				cronRunning = true;
		}
	}
	if (!cronRunning && schedule !== 'off') {
		banners.push(_('The cron service (crond) does not appear to be running -- scheduled backups will not happen until it does. Run "/etc/init.d/cron start" or check the System > Startup page.'));
	}

	if (cls.kind === 'blocked_public')
		banners.push(cls.message);

	return {
		enabledText: status.enabled ? _('Enabled') : _('Disabled'),
		scheduleText: gbScheduleText(schedule, cronExpr, cronNext),
		resultText: cls.message,
		resultDotClass: 'gitbackup-dot ' + (
			cls.synced === true ? 'gitbackup-dot-ok' :
			cls.kind === 'blocked_public' || cls.kind === 'error_space' ? 'gitbackup-dot-error' :
			cls.synced === null && cls.kind !== 'unknown' ? 'gitbackup-dot-warn' : ''
		),
		resultHint: status.last_run ?
			_('Last completed run: %s').format(gbFormatDate(status.last_run)) :
			_('This device has not completed a run yet.'),
		banners: banners
	};
}

function gbHistoryView(historyRes, remoteUrl, provider) {
	var commit = (historyRes && historyRes.commits && historyRes.commits[0]) || null;
	var parsed, href;

	if (!commit)
		return { shaText: _('No commits yet'), shaHref: null, timeText: '-' };

	parsed = gbParseRemote(remoteUrl);
	href = gbCommitUrl(parsed, gbProvider(parsed ? parsed.host : '', provider), commit.sha);

	return {
		shaText: commit.sha.substring(0, 12),
		shaHref: href,
		timeText: gbCommitTime(commit.subject) || commit.subject || '-'
	};
}

// gbConfigDiffView <res> -- pure view-model for the config_diff rpcd
// answer (`{ differs: bool, text: ... }` on success, `{ reason: ... }` on
// failure -- gbrpc_config_diff, package/gitbackup). Unlike gbClassifyLog
// above, a missing/failed answer must NOT read as "all saved": that would
// misreport "could not check" as the one state operators most need to
// trust (spec: "если метод недоступен или упал, индикатор обязан честно
// сказать «не удалось проверить»"), so both "the call itself rejected"
// (res === null, this view's own L.resolveDefault fallback) and "the
// method ran but answered an error object" (res.reason) share the same
// "could not check" branch below, rendered with the neutral/warn dot,
// never the ok one.
function gbConfigDiffView(res) {
	if (!res || typeof res.differs !== 'boolean')
		return {
			text: (res && res.reason) ?
				_('Could not check: %s').format(res.reason) :
				_('Could not check whether the configuration has changed.'),
			dotClass: 'gitbackup-dot gitbackup-dot-warn'
		};

	if (res.differs)
		return {
			text: _('The configuration has changed since the last commit.'),
			dotClass: 'gitbackup-dot gitbackup-dot-warn'
		};

	return {
		text: _('The configuration matches the last commit.'),
		dotClass: 'gitbackup-dot gitbackup-dot-ok'
	};
}

function gbRenderBanner(text) {
	return E('div', { 'class': 'gitbackup-banner' }, [ E('p', {}, text) ]);
}

// ---------------------------------------------------------------------
// Styles -- returned inside this view's own tree (rule 1), never through
// document.head.appendChild, the same pattern stock package-manager.js
// and status/nftables.js use. Every selector is prefixed "gitbackup-"
// (rule 2): no bare .hidden/.toast/.label/.card anywhere. No `:root{}`,
// no `*{}`, no CSS-framework import (rule 3). Every color comes from the
// theme's exported token tier with a literal fallback (rule 4); the
// "warn" family is spelled "warn", not "warning" (there is no bare
// `--text-color` either). Text on a colored fill uses the matching
// `--on-*-color`, never a literal white (rule 5). No `--fs-*` read
// anywhere (rule 6, private theme tier). No `!important` (rule 7). No
// dark-mode media query -- every color already comes from a token, so no
// `data-darkmode` detection is needed at all (rule 8). Layout switches on
// this view's own container width via `@container`, not `@media` (rule
// 9): the sidebar eats real width a viewport-wide media query cannot see.
// No `window.onload`, no node appended to document.body, no absurd
// z-index (rule 10) -- and the one custom poller this view owns
// (pollLiveLog) is bounded and explicitly stopped, see stopLiveLog below
// and its own call sites. Stock Save/Apply/Reset buttons are switched off
// through handleSaveApply/handleSave/handleReset below, never hidden with
// CSS (rule 11).
//
// Defined here, before the view.extend() call below that references it
// inside render(): this file's own top-level code all runs once, in
// order, before any view lifecycle method is ever invoked, but a
// `return` at the top level of a LuCI view module (the `return
// view.extend({...})` below) hands control back to the module loader
// immediately -- every stock view in this checkout ends with exactly
// that as its last statement, none of them have code after it, and a
// `var` placed after such a `return` would be dead code, never
// evaluated at all.
// ---------------------------------------------------------------------
var GB_CSS = [
	'.gitbackup-view { container-type: inline-size; }',
	'.gitbackup-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: .75em; margin: .75em 0; }',
	'@container (max-width: 700px) { .gitbackup-cards { grid-template-columns: 1fr; } }',
	'.gitbackup-card { border: 1px solid var(--background-color-medium, #ddd); border-radius: 4px; padding: .75em 1em; background: var(--background-color-low, #f5f5f5); }',
	'.gitbackup-card-title { font-size: .85em; text-transform: uppercase; letter-spacing: .04em; color: var(--text-color-medium, #666); margin: 0 0 .35em; }',
	'.gitbackup-card-value { font-size: 1.05em; color: var(--text-color-high, #333); word-break: break-word; }',
	'.gitbackup-card-hint { font-size: .85em; color: var(--text-color-medium, #666); margin-top: .35em; }',
	'.gitbackup-link { color: var(--text-color-high, #333); }',
	'.gitbackup-banner { border-radius: 4px; padding: .6em 1em; margin: 0 0 .75em; background: var(--error-color-medium, #f44336); color: var(--on-error-color, #fff); }',
	'.gitbackup-banner p { margin: .2em 0; }',
	'.gitbackup-leak { border: 1px solid var(--warn-color-medium, #f0c629); border-radius: 4px; padding: .75em 1em; margin: .75em 0; background: var(--background-color-low, #f5f5f5); }',
	'.gitbackup-leak-title { font-weight: bold; color: var(--text-color-high, #333); margin: 0 0 .4em; }',
	'.gitbackup-leak-list { margin: 0; padding-left: 1.2em; color: var(--text-color-high, #333); }',
	'.gitbackup-actions { display: flex; flex-wrap: wrap; gap: .5em; margin: .75em 0; }',
	'.gitbackup-log { max-height: 320px; overflow: auto; background: var(--background-color-low, #f5f5f5); color: var(--text-color-high, #333); border: 1px solid var(--background-color-medium, #ddd); border-radius: 4px; padding: .6em .8em; font-family: monospace; font-size: .85em; white-space: pre-wrap; }',
	'.gitbackup-dot { display: inline-block; width: .6em; height: .6em; border-radius: 50%; margin-right: .4em; background: var(--text-color-medium, #999); }',
	'.gitbackup-dot-ok { background: var(--success-color-medium, #4caf50); }',
	'.gitbackup-dot-warn { background: var(--warn-color-medium, #f0c629); }',
	'.gitbackup-dot-error { background: var(--error-color-medium, #f44336); }'
];

return view.extend({
	// Not a config form: nothing here is form.Map-backed, so the stock
	// Save/Apply/Reset row has nothing to act on. Rule 11 (spec's style
	// guide): the stock buttons are switched off through the documented
	// hook, never hidden with CSS.
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		var self = this;

		return uci.load('gitbackup').catch(function() { return null; }).then(function() {
			var schedule = uci.get('gitbackup', 'main', 'schedule') || 'daily';
			var cronExpr = uci.get('gitbackup', 'main', 'cron_expr') || '';

			self._remoteUrl = uci.get('gitbackup', 'origin', 'url') || '';
			self._provider = uci.get('gitbackup', 'origin', 'provider') || 'auto';
			self._schedule = schedule;
			self._cronExpr = cronExpr;

			// `history` is deliberately NOT in this Promise.all: it runs a
			// real `git fetch` against the configured remote
			// (usr/libexec/rpcd/luci.gitbackup's own _gb_rpc_full_fetch,
			// out of this ticket's zone) with no timeout of its own, and a
			// router with a genuinely unreachable remote (no internet yet,
			// wrong URL, DNS down) can leave that hanging far longer than
			// the couple of seconds a normal fetch takes -- measured live
			// against a real GitHub remote on the owlab stand. Blocking
			// this view's entire initial paint on that would turn "no
			// internet" into "Overview never loads at all", which is
			// worse than the Last Commit card staying on "Checking..." a
			// while. render() below starts it separately, after the rest
			// of the page (status/log/service, all local-only and fast)
			// is already on screen.
			return Promise.all([
				L.resolveDefault(callStatus(), null),
				L.resolveDefault(callLog(200), null),
				L.resolveDefault(callServiceList('cron'), null),
				(schedule === 'cron' && cronExpr) ? L.resolveDefault(callValidateCron(cronExpr), null) : null
			]);
		});
	},

	render: function(data) {
		var self = this;
		var status = data[0] || {};
		var logRes = data[1] || {};
		var serviceRes = data[2] || {};
		var cronRes = data[3] || null;
		var sv, view;

		self._cronNext = (cronRes && cronRes.valid) ? cronRes.next : null;

		// Computed up front, as plain data, and fed directly into the
		// E() tree below -- see the "Pure view-model builders" comment
		// above gbStatusView/gbHistoryView for why this view never calls
		// applyStatusDom/applyHistoryDom (the getElementById-based
		// updaters used by the later poll ticks) against its own,
		// not-yet-attached initial tree. The commit card starts on a
		// plain "Checking..." placeholder -- not gbHistoryView({}, ...)'s
		// own "No commits yet", which would misreport a remote that
		// simply hasn't answered back yet as one confirmed to have no
		// history -- and refreshHistory() (below, fired once render()
		// returns) fills in the real answer whenever it arrives.
		sv = gbStatusView(status, logRes, serviceRes, self._schedule, self._cronExpr, self._cronNext);

		view = E('div', { 'class': 'gitbackup-view' }, [
			E('style', { 'type': 'text/css' }, [ GB_CSS.join('\n') ]),

			E('h2', {}, _('Git Backup')),

			E('div', { 'id': 'gitbackup-banners' }, sv.banners.map(gbRenderBanner)),

			E('div', { 'class': 'gitbackup-cards' }, [
				E('div', { 'class': 'gitbackup-card' }, [
					E('div', { 'class': 'gitbackup-card-title' }, _('Status')),
					E('div', { 'class': 'gitbackup-card-value', 'id': 'gitbackup-status-enabled' }, sv.enabledText),
					E('div', { 'class': 'gitbackup-card-hint', 'id': 'gitbackup-status-schedule' }, sv.scheduleText)
				]),
				E('div', { 'class': 'gitbackup-card' }, [
					E('div', { 'class': 'gitbackup-card-title' }, _('Last commit')),
					E('div', { 'class': 'gitbackup-card-value', 'id': 'gitbackup-commit-sha' }, _('Checking…')),
					E('div', { 'class': 'gitbackup-card-hint', 'id': 'gitbackup-commit-time' }, '-')
				]),
				E('div', { 'class': 'gitbackup-card' }, [
					E('div', { 'class': 'gitbackup-card-title' }, _('Last run')),
					E('div', { 'class': 'gitbackup-card-value', 'id': 'gitbackup-run-result' }, [
						E('span', { 'class': sv.resultDotClass, 'id': 'gitbackup-run-dot' }),
						E('span', { 'id': 'gitbackup-run-text' }, sv.resultText)
					]),
					E('div', { 'class': 'gitbackup-card-hint', 'id': 'gitbackup-run-hint' }, sv.resultHint)
				]),
				E('div', { 'class': 'gitbackup-card' }, [
					E('div', { 'class': 'gitbackup-card-title' }, _('Configuration')),
					E('div', { 'class': 'gitbackup-card-value', 'id': 'gitbackup-configdiff-result' }, [
						E('span', { 'class': 'gitbackup-dot', 'id': 'gitbackup-configdiff-dot' }),
						E('span', { 'id': 'gitbackup-configdiff-text' }, _('Checking…'))
					]),
					E('div', { 'class': 'gitbackup-card-hint' },
						_('Compared against the last commit right now, not just the last run.'))
				])
			]),

			E('div', { 'class': 'gitbackup-leak' }, [
				E('p', { 'class': 'gitbackup-leak-title' },
					_('The following ends up in the repository in plain text -- there is no encryption in this tool:')),
				E('ul', { 'class': 'gitbackup-leak-list' }, [
					E('li', {}, '/etc/shadow'),
					E('li', {}, _('dropbear private host keys')),
					E('li', {}, 'authorized_keys'),
					E('li', {}, _('WPA pre-shared keys (Wi-Fi passwords)')),
					E('li', {}, _('WireGuard private keys')),
					E('li', {}, _('PPPoE credentials')),
					E('li', {}, 'uhttpd.key')
				])
			]),

			E('div', { 'class': 'gitbackup-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'id': 'gitbackup-btn-run',
					'click': ui.createHandlerFn(self, 'handleRun')
				}, _('Backup now')),
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'id': 'gitbackup-btn-test',
					'click': ui.createHandlerFn(self, 'handleTest')
				}, _('Test connection')),
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'id': 'gitbackup-btn-card',
					'click': ui.createHandlerFn(self, 'handleDownloadCard')
				}, _('Download recovery card'))
			]),

			E('pre', { 'class': 'gitbackup-log', 'id': 'gitbackup-live-log', 'hidden': true }, '')
		]);

		self._boundRefresh = L.bind(self.refreshStatus, self);
		poll.add(self._boundRefresh, 5);

		// Fired once, after render() has already built and returned the
		// tree above -- by the time this promise resolves the view is
		// attached (LuCI's own view lifecycle inserts render()'s return
		// value right after render() itself returns), so
		// applyHistoryDom's getElementById calls land on live nodes. See
		// the "not in load()'s Promise.all" comment on load() for why
		// this is a fire-and-forget call rather than something render()
		// waits on.
		self.refreshHistory();

		// Same reasoning as refreshHistory() just above, and NOT folded
		// into refreshStatus()'s own 5s poll either: config_diff
		// (gbrpc_config_diff) re-collects the whole backup set and talks
		// to the remote to fetch the last commit's manifest, the same
		// "can take several seconds against a real remote" cost this
		// view's own commit-history fetch already has to dodge -- polling
		// that every 5 seconds would hammer both the router's flash and
		// the remote for no reason. Refreshed here once the page is
		// already on screen, and again after a run/test this view itself
		// triggered finishes (pollLiveLog below).
		self.refreshConfigDiff();

		return view;
	},

	// Cheap periodic refresh: status (local file reads) and a short log
	// tail (local logread), never `history` -- that method does a real
	// `git fetch` against the remote on every call (usr/libexec/rpcd/
	// luci.gitbackup's own _gb_rpc_full_fetch), and polling it every 5
	// seconds would hammer the remote for no reason. `history` is
	// refreshed once on load and again right after a run/test this view
	// itself triggered finishes (see pollLiveLog). Both of these run only
	// after the view is already attached (poll ticks always fire well
	// after render() has returned), so applyStatusDom/applyHistoryDom's
	// own getElementById calls are safe here -- unlike inside render()
	// itself, see the "Pure view-model builders" comment above.
	refreshStatus: function() {
		var self = this;

		return Promise.all([
			L.resolveDefault(callStatus(), null),
			L.resolveDefault(callLog(200), null),
			L.resolveDefault(callServiceList('cron'), null)
		]).then(function(data) {
			self.applyStatusDom(gbStatusView(
				data[0] || {}, data[1] || {}, data[2] || {},
				self._schedule, self._cronExpr, self._cronNext
			));
		});
	},

	refreshHistory: function() {
		var self = this;

		return L.resolveDefault(callHistory(1), null).then(function(res) {
			self.applyHistoryDom(gbHistoryView(res || {}, self._remoteUrl, self._provider));
		});
	},

	// L.resolveDefault's own `null` fallback (a rejected call: rpcd
	// unreachable, ACL denial, ...) and gbrpc_config_diff's own
	// `{ "reason": ... }` error object (a reachable failure: bad config,
	// unreachable remote) both have to land on gbConfigDiffView's "could
	// not check" branch, never silently on "all saved" -- see that
	// function's own comment.
	refreshConfigDiff: function() {
		var self = this;

		return L.resolveDefault(callConfigDiff(), null).then(function(res) {
			self.applyConfigDiffDom(gbConfigDiffView(res));
		});
	},

	applyStatusDom: function(sv) {
		var enabledEl = document.getElementById('gitbackup-status-enabled');
		var scheduleEl = document.getElementById('gitbackup-status-schedule');
		var resultTextEl = document.getElementById('gitbackup-run-text');
		var resultDotEl = document.getElementById('gitbackup-run-dot');
		var resultHintEl = document.getElementById('gitbackup-run-hint');
		var bannerBox = document.getElementById('gitbackup-banners');

		if (enabledEl)
			enabledEl.textContent = sv.enabledText;

		if (scheduleEl)
			scheduleEl.textContent = sv.scheduleText;

		if (resultTextEl)
			resultTextEl.textContent = sv.resultText;

		if (resultDotEl)
			resultDotEl.className = sv.resultDotClass;

		if (resultHintEl)
			resultHintEl.textContent = sv.resultHint;

		if (bannerBox) {
			bannerBox.textContent = '';
			sv.banners.forEach(function(b) { bannerBox.appendChild(gbRenderBanner(b)); });
		}
	},

	applyHistoryDom: function(hv) {
		var shaEl = document.getElementById('gitbackup-commit-sha');
		var timeEl = document.getElementById('gitbackup-commit-time');

		if (!shaEl || !timeEl)
			return;

		shaEl.textContent = '';
		if (hv.shaHref) {
			shaEl.appendChild(E('a', {
				'href': hv.shaHref,
				'target': '_blank',
				'rel': 'noopener noreferrer',
				'class': 'gitbackup-link'
			}, hv.shaText));
		} else {
			shaEl.appendChild(document.createTextNode(hv.shaText));
		}

		timeEl.textContent = hv.timeText;
	},

	applyConfigDiffDom: function(cv) {
		var textEl = document.getElementById('gitbackup-configdiff-text');
		var dotEl = document.getElementById('gitbackup-configdiff-dot');

		if (textEl)
			textEl.textContent = cv.text;

		if (dotEl)
			dotEl.className = cv.dotClass;
	},

	setBusy: function(busy) {
		[ 'gitbackup-btn-run', 'gitbackup-btn-test', 'gitbackup-btn-card' ].forEach(function(id) {
			var btn = document.getElementById(id);
			if (btn)
				btn.disabled = busy;
		});
	},

	// Live log for `Backup now` / `Test connection` (spec: "Backup now"
	// показывает живой лог через polling rpcd-метода log"). Both rpcd
	// methods (run/test) background the CLI and answer immediately with
	// `{started:true}` (usr/libexec/rpcd/luci.gitbackup's own gbrpc_run/
	// gbrpc_test) -- the only way to see how it went is to tail the same
	// syslog-backed `log` method, so this starts a faster, bounded poll
	// of it and stops itself: on a matching terminal log line (see
	// GB_LOG_TERMINAL_RE), after 60s with no new output at all, or after
	// a hard 5-minute ceiling regardless -- this poller must never
	// outlive the operation it is watching, and this view's own periodic
	// `refreshStatus` poll (5s, started in render()) keeps running
	// independently the whole time either way.
	startLiveLog: function() {
		var self = this;
		var pre = document.getElementById('gitbackup-live-log');

		if (pre) {
			pre.hidden = false;
			pre.textContent = '';
		}

		self._liveLogIdle = 0;
		self._liveLogTicks = 0;

		return L.resolveDefault(callLog(500), null).then(function(res) {
			var text = (res && res.text) || '';
			self._liveLogLines = text ? text.split('\n').length : 0;

			if (!self._boundLiveLogPoll)
				self._boundLiveLogPoll = L.bind(self.pollLiveLog, self);

			poll.remove(self._boundLiveLogPoll);
			poll.add(self._boundLiveLogPoll, 2);
		});
	},

	stopLiveLog: function() {
		if (this._boundLiveLogPoll)
			poll.remove(this._boundLiveLogPoll);
	},

	pollLiveLog: function() {
		var self = this;

		self._liveLogTicks = (self._liveLogTicks || 0) + 1;

		return callLog(500).then(function(res) {
			var text = (res && res.text) || '';
			var lines = text.split('\n');
			var newLines = (lines.length >= self._liveLogLines) ? lines.slice(self._liveLogLines) : lines;
			var pre = document.getElementById('gitbackup-live-log');
			var add = newLines.filter(function(l) { return l; }).join('\n');
			var finished = false;
			var i;

			self._liveLogLines = lines.length;

			if (add) {
				self._liveLogIdle = 0;
				if (pre) {
					pre.textContent = pre.textContent ? pre.textContent + '\n' + add : add;
					pre.scrollTop = pre.scrollHeight;
				}
				for (i = 0; i < newLines.length; i++) {
					if (GB_LOG_TERMINAL_RE.test(newLines[i]))
						finished = true;
				}
			} else {
				self._liveLogIdle = (self._liveLogIdle || 0) + 1;
			}

			if (finished || self._liveLogIdle >= 30 || self._liveLogTicks >= 150) {
				self.stopLiveLog();
				self.setBusy(false);
				self.refreshStatus();
				self.refreshHistory();
				self.refreshConfigDiff();
			}
		}, function() {
			// A single failed poll must not spin forever either.
			self._liveLogIdle = (self._liveLogIdle || 0) + 30;
			if (self._liveLogIdle >= 30) {
				self.stopLiveLog();
				self.setBusy(false);
			}
		});
	},

	handleRun: function(ev) {
		var self = this;

		self.setBusy(true);

		return self.startLiveLog().then(function() {
			return callRun();
		}).then(function(res) {
			if (!res || res.started !== true) {
				ui.addNotification(null, E('p', {}, _('Could not start a backup run.')), 'error');
				self.setBusy(false);
			}
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Could not start a backup run: %s').format(e.message)), 'error');
			self.setBusy(false);
		});
	},

	handleTest: function(ev) {
		var self = this;

		self.setBusy(true);

		return self.startLiveLog().then(function() {
			return callTest();
		}).then(function(res) {
			if (!res || res.started !== true) {
				ui.addNotification(null, E('p', {}, _('Could not start a connection test.')), 'error');
				self.setBusy(false);
			}
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Could not start a connection test: %s').format(e.message)), 'error');
			self.setBusy(false);
		});
	},

	handleDownloadCard: function(ev) {
		var btn = ev.target;
		var link;

		btn.disabled = true;

		return callCard().then(function(res) {
			if (!res || typeof res.card !== 'string') {
				ui.addNotification(null, E('p', {},
					_('Could not generate the recovery card: %s').format((res && res.reason) || _('unknown error'))), 'error');
				return;
			}

			link = document.createElement('a');
			link.href = window.URL.createObjectURL(new Blob([ res.card ], { type: 'text/markdown' }));
			link.download = 'gitbackup-RECOVERY.md';
			link.click();
			window.URL.revokeObjectURL(link.href);
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Could not generate the recovery card: %s').format(e.message)), 'error');
		}).finally(function() {
			btn.disabled = false;
		});
	}
});
