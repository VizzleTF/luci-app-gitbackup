# gitbackup

Automatic configuration backup for OpenWrt routers, pushed straight into a Git repository —
no clone, no working copy on the router, no separate backup server. Each device gets its own
branch, its own path prefix, and a manifest that records file modes and ownership as well as
content, so a restore can put files back exactly as they were, not just with the right bytes.

Two packages: `gitbackup` (the CLI, the scheduler, the rpcd backend) and `luci-app-gitbackup`
(the four-tab web UI: Overview, Settings, Paths, History). Either works alone; most people want
both.

<!-- TODO(screenshot): docs/screenshot-overview.png is not yet captured. Take it from a running
     router: System -> Git Backup -> Overview, at default width, after a successful run so the
     status cards are populated. This README references the file below on purpose, before it
     exists, so the gap is visible instead of silently missing. -->

![Overview tab screenshot — not yet captured, see docs/screenshot-overview.png](docs/screenshot-overview.png)

**Screenshot pending.** The image above will not render until `docs/screenshot-overview.png` is
added; it has not been faked or replaced with a stock image. See the `TODO(screenshot)` comment
in this file's own source for what to capture and from where.

## Does this fit your router?

Read this before installing anything. `gitbackup` depends on a real `git` client, not a
reimplementation, and a full git-over-https stack is not small on an embedded router.

Measured on a live OpenWrt 25.12.4 stand (`tools/size-report.sh`, one clean install of both
packages together; see `dist/size-report.json` for the raw numbers this table is built from):

| state | installed | packages |
|---|---|---|
| clean 25.12.4 image | 21.0 MiB | 137 |
| + `gitbackup` | 45.7 MiB | 147 |
| + `gitbackup` + `luci-app-gitbackup` | 45.9 MiB | 148 |

An earlier, separate measurement of the same clean image put it at 15.9 MiB — that run used a
plainer stand than this one, which carries a few extra owlab test fixtures on top of stock
25.12.4; either baseline is fine to reason from as long as it is not mixed with the other one's
delta, which is why this table sticks to numbers from a single `size-report.sh` run.

`gitbackup` itself is 226 KiB and `luci-app-gitbackup` is 139 KiB (`apk info -s`); essentially
everything else in that ~25 MiB delta is dependencies pulled in once, on the first install:

- **`git` + `git-http`** — the actual git-over-https stack, pulling in `libopenssl3` (for `git`)
  and `libcurl4` + `libnghttp2` (for `git-http`, required for `git fetch https://` at all —
  without it git fails outright with `remote-https is not a git command`). This is the bulk of
  the delta, roughly 22 MiB on its own.
- **`openssh-client` + `openssh-keygen`** — about 1.3 MiB. Busybox's own `dbclient` was tried and
  rejected: it cannot read OpenSSH-format private keys, does not honor `UserKnownHostsFile`, and
  — measured on a 25.12.4 stand with `GIT_TRACE=1`, dropbear 2025.89, git 2.50.1, see the comment
  above `gb_git_env` in `auth.sh` — git silently drops `-o StrictHostKeyChecking=yes` (and every
  other `-o` option) when it falls back to dbclient's `simple` mode. None of that is acceptable
  for a tool whose whole job is not silently failing open.
- **`coreutils-stat`** — about 100 KiB. The base image ships no `stat` at all, and the backup
  manifest (which records file modes and ownership) depends on it.

**This means a device with 16 MB of flash cannot run this package at all**, and shouldn't try —
there is no partial install that fits. Treat 128 MB of flash as the practical minimum before
going any further. If your router has less, stop here; see `docs/COMPARISON.md` for lighter
alternatives and their own trade-offs.

## Quick start

You need a **private** Git repository before you start — see [Security model](#security-model)
below for why this is not optional.

1. Install both packages (from a feed that carries them, or `apk add --allow-untrusted` a
   locally built `.apk` during development).
2. Open **System → Git Backup → Settings**. Set the repository URL
   (`git@host:owner/repo.git` or `https://host/owner/repo.git`) and choose an auth method:
   - **SSH deploy key** (recommended): click **Generate deploy key**, then **Add the key to the
     repository** — this opens the provider's own deploy-key page pre-filled where the provider
     supports it. Tick "Allow write access" on the provider's side; without it every push fails
     silently.
   - **API token**: paste a personal access token. Prefer a token scoped to this one repository
     over a broad account-wide one — see Security model.
3. Click **Test connection**. This is also where an unknown SSH host key is shown and accepted,
   once, with its fingerprint on screen.
4. Pick a **Schedule** (hourly/daily/weekly presets stagger themselves per device on purpose, so
   a whole fleet does not hit the provider's API in the same second) or a custom cron expression.
5. Save. Go to **Overview** and click **Backup now** to confirm the whole path works end to end.

Equivalent from the CLI, if you'd rather not touch the UI at all:

```sh
uci set gitbackup.origin.url='git@github.com:you/routers.git'
uci commit gitbackup
gitbackup keygen
gitbackup pubkey        # paste this into the repo's deploy keys, with write access
gitbackup test          # accepts the host key, verifies auth and visibility
gitbackup run           # first backup
```

Recovering a router later is a separate document — see **[docs/RESTORE.md](docs/RESTORE.md)**.

## Security model

**Read this before you push anything.** This tool has no encryption of any kind. Everything it
backs up goes into the repository as plain text, exactly as it sits on the router's filesystem,
except for the specific UCI options `gitbackup` is configured to scrub. Depending on what lives
in your configuration, that plain text can include:

- `/etc/shadow` (the root password hash)
- dropbear's private host keys
- `authorized_keys`
- WPA pre-shared keys (Wi-Fi passwords)
- WireGuard private keys
- PPPoE credentials
- `uhttpd.key` (the router's own HTTPS private key)

**A private repository is not a suggestion — it is the only thing standing between this list and
the public internet.** `gitbackup` refuses to push to a repository it can confirm is public (an
anonymous API check runs before every push), but a provider it cannot query at all (a self-hosted
`generic` remote) is pushed to on trust, with an explicit confirmation checkbox precisely because
that trust cannot be verified by the tool itself.

Two separate compromise scenarios follow from this, and they are not the same risk:

- **Compromise the Git hosting account, and every router in the fleet is compromised.** One
  leaked provider credential (weak password, phished 2FA-less login, a leaked PAT) hands over
  root password hashes, host keys and Wi-Fi passwords for the whole fleet in one place. This is
  a deliberate trade for simplicity — see `docs/COMPARISON.md` for tools built around a different
  trade-off.
- **Compromise a single router, and the attacker gets write access to the *entire* fleet's
  repository.** The deploy key `gitbackup` generates is a repository-wide credential; nothing in
  Git's own access model scopes an SSH deploy key to "only this device's branch and path." A
  router that is otherwise a minor target (weak LAN exposure, an unrelated exploit) becomes a way
  to rewrite or delete every other router's backup history.

**If this repository is ever switched from private to public, the entire history leaks** —
not just the current state, every value that was ever committed, including passwords rotated
years ago. Forks made while it was public keep their own copy forever, and services like the
GitHub Archive Program that mirror public repositories do not un-mirror anything after the fact.
There is no "undo" for this; treat the private/public toggle as a one-way door.

Recommended mitigations, roughly in order of how much they matter:

- Keep the repository under an **organization or account dedicated to infrastructure**, not a
  personal account also used for anything else.
- Turn on **2FA, unconditionally**, on that account.
- Provision a **separate deploy key per device** rather than one shared account-wide token —
  a leaked deploy key from one router can be revoked on its own without touching every other
  device's credential.

## `/etc/sysupgrade.conf` is a feature, not a side effect

Any path added under **Paths** is written directly into `/etc/sysupgrade.conf` — the same file
the router's own `sysupgrade` reads for `-l`/`-b`/`-r`. This is deliberate: a path added here to
widen what `gitbackup` backs up **also** automatically widens what a real firmware `sysupgrade`
preserves across the upgrade, for free, with no second list to keep in sync. A directory added
here stays a directory in that file too — anything created under it later is covered by both
tools without editing anything again.

## What restoring does *not* do

Restoring a configuration backup — through any of the three paths in
[docs/RESTORE.md](docs/RESTORE.md) — puts back configuration files, not installed packages.
**It does not reinstall the packages that were present when the backup was made.** If the
device's package feeds or the OpenWrt release itself have moved on since then, a plain
`apk add <package>` for something the backup's configuration now references can simply fail —
version or feed mismatches are not something a config restore can paper over. `gitbackup restore
--with-packages` makes a best-effort attempt to reinstall recorded packages, but "best effort"
is the operative phrase: it is not a guarantee, and a firmware reinstalled from scratch on a
different release is the case most likely to hit this.

## Theme compatibility

`luci-app-gitbackup` depends only on `luci-base` — it does not require, import, or read
private tokens from any specific theme — and is styled to render correctly under any of them,
footstrap included. This was checked, not assumed: on 2026-09-04, the CSS actually shipped in
all four views (`overview.js`, `settings.js`, `paths.js`, `history.js`) was run through the
"Fix my styles" checker at https://vizzletf.github.io/luci-theme-footstrap/#fix (the eleven
rules on that page — CSS scoped inside the view tree, no `:root`/`*` selectors, only the
`--*-color-*` export tokens with literal fallbacks, no `prefers-color-scheme`, no
`window.onload`, container queries instead of viewport media queries, and so on), which
reported "Nothing flagged — this already follows the rules." A manual grep for the rules that
checker cannot see from pasted CSS alone (`document.head.appendChild`, `window.onload`,
`prefers-color-scheme`, stray `!important`) found none in the shipped JS either.

## Further reading

- **[docs/RESTORE.md](docs/RESTORE.md)** — the three ways to get a router's configuration back,
  in the order you should actually reach for them.
- **[docs/COMPARISON.md](docs/COMPARISON.md)** — an honest comparison with restic, borg and
  etckeeper, including who this tool is the wrong choice for.
