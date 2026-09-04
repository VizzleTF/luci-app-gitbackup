# 0002: Push a commit without ever cloning the repository

## Context

The router has no room for a persistent repository clone, and the customer explicitly
forbade downloading the repository to the device at all, even a temporary full copy in `/tmp`
("качать репозиторий на роутер вообще нельзя").

## Decision

`run` never clones. It asks the server for one SHA (`git ls-remote origin
refs/heads/<branch>`), fetches only the minimum metadata needed for that parent commit,
builds the new commit's tree entirely on the router (`hash-object` / `update-index` /
`write-tree`), and pushes the result — git then negotiates and transfers only the objects the
server doesn't already have.

## Why

Verified empirically: `git commit-tree -p <parent>` only requires the parent **commit object**
to exist locally, not its tree or any blobs. Two fetch strategies were tested against real
hosts: `--filter=tree:0`, which yields a stable ~12 KiB parent object regardless of repository
size, and `--filter=blob:none`, which also pulls the tree objects (up to ~644 KiB on a large
test repo) but no blobs. A plain `--depth=1` clone was measured too (11–14 MiB on real
repositories) and rejected outright as exactly the "download the repo" outcome that was
forbidden. `--filter=blob:none` was chosen over the cheaper `--filter=tree:0` only because a
later step needs to read the old `manifest.json` blob for comparison, which requires the tree
to be present; on a per-device branch that tree is tiny anyway, so the extra cost is
negligible in practice.

## Consequences

Nothing that needs full repository content — browsing history, diffing an old commit, showing
a modal diff in LuCI — can be served from what `run` already has on disk; those features
(History tab, `restore` from an arbitrary past commit) must do their own on-demand shallow
fetch into `/tmp`, as a separate code path from `run`. Partial-clone filters aren't guaranteed
server-side (a self-hosted Gitea can have `uploadpack.allowFilter` off); the code has to detect
the soft degradation warning and accept falling back to a full `--depth=1` fetch, which is only
acceptable because it is still scoped to one device's small branch, not the whole repository.
