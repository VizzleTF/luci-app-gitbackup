# 0005: sysupgrade -l is the sole source of the file list

## Context

Something has to decide which files on the router are "config" worth backing up. OpenWrt
already has a mechanism for this (`sysupgrade -l`, feeding `/lib/upgrade/keep.d/*` and modified
package conffiles), used to decide what survives a firmware upgrade.

## Decision

The backup set is exactly what `sysupgrade -l` reports (plus a separate directory-listing pass,
since `-l` only ever returns files and symlinks). The set is extended only by editing
`/etc/sysupgrade.conf` — there is no gitbackup-owned, independently maintained path list.

## Why

A dedicated UCI list of paths was on the table (R30's original phrasing allowed for it) and was
rejected: duplicating sysupgrade's file-selection logic would inevitably drift from what a real
firmware upgrade actually preserves, which defeats the point of R30 — paths added for backup
purposes are supposed to also survive a real `sysupgrade`. It was also verified that
`sysupgrade -l`'s output is not simply a subset of what `sysupgrade -b`'s archive contains (the
archive synthesizes `etc/uci-defaults/10_disable_services`, which never exists on disk and
never appears in `-l`), confirming that these are genuinely two different artifacts, not one
computable from the other.

## Consequences

The backup is bounded by whatever sysupgrade already tracks; anything a user wants preserved
across a factory reset but explicitly *not* carried through a real firmware upgrade cannot be
expressed. Constraints inherited from sysupgrade become gitbackup's constraints too — most
visibly, paths containing spaces cannot be supported (sysupgrade's own conf-to-`find` pipeline
breaks on them), so the Paths UI must validate and reject them rather than silently mishandling
them. Empty directories, never reported by `-l`, exist only because `manifest.json` records
them separately (see 0004).
