# 0008: Custom rollout on restore, not sysupgrade -r

## Context

Restore has to apply exact permissions/ownership from `manifest.json` (0004) and must not
leave the system half-restored if something goes wrong partway through.

## Decision

`gitbackup restore` (Path 2, and the restore step inside the Path 1 bootstrap) unpacks and
applies files itself. It does not shell out to `sysupgrade -r`.

## Why

Measured directly on the target: `sysupgrade -r` is effectively `tar -C / -xzf ...; exit $?` —
non-atomic, and it stops on tar's first error, leaving whatever had already been extracted in
place. Two things restore needs are structurally impossible to get from that: verifying every
file's sha256 *before* writing anything (tar has already started writing by the time an error
surfaces), and re-applying `mode`/`uid`/`gid` from the manifest (tar restores whatever
permissions happen to be recorded inside the archive it was given, not gitbackup's
separately-tracked manifest values). Path 0 — uploading `backup.tar.gz` through the stock LuCI
Restore screen when nothing is installed yet — still goes through `sysupgrade -r`, because it's
the only thing available with zero dependencies; the spec documents this difference explicitly
in `docs/RESTORE.md` rather than letting users assume both paths behave identically.

## Consequences

Two restore code paths now exist with genuinely different failure semantics: Path 0 can leave a
partially-extracted filesystem on error (inherited from `sysupgrade -r`'s behavior, out of
gitbackup's control), Path 2 cannot (it stops before the first byte is written on any checksum
mismatch). Restore logic — manifest parsing, permission application, symlink recreation,
pre-write verification — is now gitbackup's own code to maintain and test, rather than
something delegated to a stock, already-hardened OpenWrt tool.
