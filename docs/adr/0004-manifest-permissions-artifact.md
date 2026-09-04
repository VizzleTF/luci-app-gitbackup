# 0004: A separate manifest.json carries permissions and ownership

## Context

Git's tree objects record only three blob modes — `100644`, `100755`, `120000` (symlink) — and
nothing for arbitrary uid/gid, exact permission bits, or empty directories. Correct restore
depends on exact values in places like `/etc/shadow` (must come back `0600 root:root`, not
`0644`) and dropbear host keys.

## Decision

`collect` writes `manifest.json` next to the file tree on every commit, recording `type`,
`mode`, `uid`, `gid`, and `sha256` per entry (plus `target` for symlinks and directory entries
for empty directories). `restore` applies these explicitly, after checksums are verified and
before anything is considered done.

## Why

This is the sole reason `manifest.json` exists at all — there was no alternative to evaluate,
because git's object model genuinely cannot represent this information; the only question was
where to keep it, and "alongside the tree it describes, in the same commit" was the only place
that keeps it versioned together with the content it applies to.

## Consequences

The manifest and the tree can, in principle, drift apart (a tampered blob, a partial write to
the remote); restore must verify sha256 for every entry before writing the first byte, and
does. Every tool that touches the tree — `collect`, `scrub`, `restore`, the diff viewer — must
keep manifest and tree in lockstep, and manifest comparison (rather than tree comparison) is
what decides whether a run produces "no changes" or a new commit, making the manifest a second
source of truth that has to be trusted as much as the tree itself.
