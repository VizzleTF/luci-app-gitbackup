# Restoring a router

Three ways to get a router's configuration back, in the order you should actually try them.
Path 0 is listed first on purpose — it is the only one that cannot fail partway and leave the
router in a worse state than it started in, because it needs nothing this project provides.

## Path 0: stock LuCI restore, no package required

Use this whenever the router still boots into *any* working OpenWrt image with LuCI on it — a
factory reset, a fresh flash, a device you have never installed `gitbackup` on at all. It needs:

- a file, downloaded from the repository through an ordinary web browser (`backup.tar.gz`,
  written next to the working tree on every run when that option is enabled — see the
  "Keep a local archive" setting — **and** the run does not scrub, see below), and
- **nothing else.** No package, no network reachable from the router at restore time beyond
  whatever it takes to load the LuCI page itself, no deploy key, no token.

Steps:

1. From any computer, open the repository's web UI and download `devices/<device>/backup.tar.gz`
   (or the archive attached to whichever commit you want) to your machine.
2. On the router, open **System → Backup / Flash Firmware**.
3. Under "Restore configuration", choose the downloaded file and upload it.
4. Reboot when LuCI asks to.

This is stock OpenWrt behavior (`sysupgrade -r`), not anything `gitbackup`-specific — which is
exactly why it is the most reliable of the three paths. It is also the one with the sharpest
edge, described below.

### When Path 0 is not there

No `backup.tar.gz` is pushed when config scrubbing is on for a run — which includes every run
against a repository marked public, where scrubbing is forced on whether you asked for it or
not. `sysupgrade -b` builds its archive from the live filesystem, not from the scrubbed tree,
so pushing it would put back exactly the secrets scrubbing had just taken out: `/etc/shadow`,
the dropbear host keys, the Wi-Fi pre-shared keys. Between "the archive is complete" and "the
repository has no secrets in it", turning scrubbing on is you choosing the second.

The recovery card generated on each run says which of the two applies to that router, so you
are not left looking for a file that was never there. Path 1 and Path 2 work either way.

### Why Path 0 is not what the other two paths use internally

`sysupgrade -r` is, under the hood, `tar -C / -xzf <archive>` followed by `exit $?`. That is
**not atomic**: if the archive extraction hits an error partway through — a full `/tmp`, a
corrupted download, anything `tar` itself trips on — the process stops where it failed, having
already overwritten some files and not others. There is no rollback; the router is left in
whatever half-old, half-new state `tar` reached before it gave up.

`gitbackup restore` (used internally by Path 1 and directly by Path 2, below) does not go
through `sysupgrade -r` at all, specifically to avoid this. It reads the backup's manifest,
computes the sha256 of **every file the restore would write, and verifies all of them against
the manifest before writing a single byte to disk.** Only once every file that will be touched
has passed that check does it start applying content, followed by permissions, ownership,
symlinks and empty directories — all read back out of the manifest, since Git itself stores none
of that.

Path 0 is still first in this document because it needs no working `gitbackup` install at all —
that is a stronger guarantee than atomicity when the alternative is a router with nothing on it
to run a restore with. Prefer Path 1 or Path 2 whenever the router can reach either.

## Path 1: `bootstrap.sh`, for a bare router with network but no package yet

Use this for a freshly flashed router that has never had `gitbackup` installed: it has network
reachability (DHCP got it an address, DNS resolves) but nothing else. One command, run over ssh:

```sh
uclient-fetch -qO- https://raw.githubusercontent.com/VizzleTF/luci-app-gitbackup/main/bootstrap.sh \
  | sh -s -- --repo https://github.com/<owner>/<routers> --device <device-id> --token <PAT>
```

or, with an SSH deploy key instead of a token:

```sh
uclient-fetch -qO- https://raw.githubusercontent.com/VizzleTF/luci-app-gitbackup/main/bootstrap.sh \
  | sh -s -- --repo git@github.com:<owner>/<routers>.git --device <device-id> --ssh-key /path/to/key
```

`bootstrap.sh` itself carries no secret — that is what lets it be fetched anonymously over plain
https, with no authentication of its own. Every credential it needs comes from the operator, on
the command line, every time. Flags that matter:

| flag | meaning |
|---|---|
| `--repo URL` | the backup repository (required unless `--list`) |
| `--device NAME` | which device's branch to restore (required unless `--list`) |
| `--commit SHA` | restore this commit instead of the branch tip (default: HEAD) |
| `--token PAT` | for an `https://` repo |
| `--ssh-key PATH` | for an `ssh` repo, an already-registered deploy private key already copied onto the router |
| `--branch NAME` | override the device branch template (default `device/{device}`) |
| `--with-packages` | best-effort reinstall of the packages the backup recorded |
| `--dry-run` | print the plan, change nothing |
| `--force` | overwrite an existing credential file, override a board mismatch |
| `--list` | list the device branches found on `--repo` and exit — no restore |

Exactly one of `--token` or `--ssh-key` is required for a real (non-`--list`) run. Internally,
this installs the signed `gitbackup` package, writes the credential to `/etc/gitbackup/` (never
into UCI, never into argv beyond this one command), and calls `gitbackup restore` — the same
sha256-verify-before-write restore Path 2 uses directly, not `sysupgrade -r`.

## Path 2: `gitbackup restore`, on a router that already has the package

Use this on a router where `gitbackup` is already installed and configured — rolling back to an
earlier commit without reflashing anything, for example. This is what the **History** tab's own
**Restore** button calls under the hood; the same thing is available directly from the CLI:

```sh
gitbackup restore --commit <sha>
```

Restoring another device's branch onto this router, or restoring without an existing
`gitbackup.origin.url` configured yet, needs the device explicitly:

```sh
gitbackup restore --device <device-id> --commit <sha>
```

Flags: `--dry-run` (print the plan, write nothing), `--force` (proceed despite a detected board
mismatch), `--yes` (skip the interactive confirmation), `--with-packages` (best-effort reinstall
of recorded packages — see the README's own note on what a config restore does not do).

A board mismatch — restoring a backup taken on a different router model — is refused by default:
interface names and wireless radios on different hardware will not line up, and restoring anyway
can leave the network unreachable until the configuration is fixed by hand. `--force` is the
explicit override for when that is actually intended.
