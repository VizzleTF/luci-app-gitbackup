# How this compares to restic, borg and etckeeper

This is not a features table. The point of this document is the last section: who this tool is
the wrong choice for, and why — because the honest answer is "more people than you'd think."

## The short version

`gitbackup` backs up a router's *configuration* — small text and a handful of keys, not general
files — by pushing it straight into a Git repository, with no clone and no working tree kept on
the router. It exists because a `git` client is a small, well-understood OpenWrt package and
nothing else on this list realistically fits inside a router's flash and RAM budget alongside
everything else the device already has to run. That size argument is also its biggest weakness:
Git was never designed as a backup tool, and the corners this project cuts to use it anyway are
exactly the corners restic and borg do not cut.

## restic and borg: encryption and retention, at a real cost

Both restic and borg encrypt data client-side before it ever leaves the machine being backed up.
That single property changes the whole security conversation: the storage backend does not have
to be trusted at all. A restic repository on any object storage, or a borg repository on any
SSH host, can be read by an attacker who compromises the storage provider and it does not matter
— without the encryption key, what they get is ciphertext. `gitbackup` has no equivalent. Every
byte it pushes is plain text except for whatever a UCI-level scrub rule strips out, and the whole
security model in this project's own README rests on trusting the Git hosting provider instead
of encrypting around the need to trust it.

Both also implement **retention**: `restic forget` / `borg prune` remove old snapshots according
to a policy (keep daily for a week, weekly for a month, and so on), so storage growth is bounded
and, just as importantly, **old secrets actually leave the backend eventually** once their
snapshot is pruned and the underlying data is garbage-collected. `gitbackup`'s history is a Git
history: every commit that was ever pushed remains reachable indefinitely unless someone
deliberately rewrites branch history on every affected device's branch — which is exactly the
kind of fleet-wide manual operation nobody does routinely, so in practice it never happens. A
Wi-Fi password rotated three years ago is still sitting in an old commit today.

Neither of these is a reason to avoid restic or borg. They are heavier, compiled tools built
around a dedup+encrypt+prune engine, and that engine is precisely the part that does not fit
comfortably in an OpenWrt router's flash and RAM budget the way a `git` client already does —
which is the whole reason this project reaches for Git in the first place, not a claim that Git
does the job better.

## borg's append-only mode vs. a deploy key that can rewrite everything

There's a second, more specific gap worth naming. Borg supports an **append-only** remote mode:
a client holding that mode's key can add new archives to a repository but cannot delete or
overwrite existing ones, which directly limits the blast radius of a single compromised client —
it cannot be used to destroy or rewrite *other* machines' backup history on the same repository.

`gitbackup`'s deploy key has no equivalent restriction. It is an ordinary Git deploy key with
write access to the whole repository, because Git's own permission model has no concept of "may
push to `device/this-one` only." A single compromised router's deploy key can rewrite or delete
every other device's branch in the same repository — see the README's own Security model section
for this exact trade-off spelled out in full.

## etckeeper: the same idea, without the fleet or the safety rails

Etckeeper is the closest relative on this list, conceptually: it also puts `/etc` under Git and
commits on package-manager hooks. If you stripped `gitbackup` down to "system config lives in a
Git repository," you would land close to etckeeper.

What etckeeper does not do, that `gitbackup` was built specifically to do:

- **No secret-scrubbing gate.** A naive etckeeper setup with a `post-commit` hook that pushes to
  a remote will happily push `/etc/shadow` and every Wi-Fi password with it — there is no
  built-in mechanism stopping that, because etckeeper was never designed with "this repository
  might end up public" as a threat it defends against.
- **No visibility check before pushing.** `gitbackup` queries the provider's API anonymously
  before every push and refuses to push at all if the repository turns out to be publicly
  visible. Etckeeper has no concept of "provider" at all — it is a local git repository with
  whatever remote you wire up yourself, and nothing stops a push to a remote that quietly went
  public.
- **No fleet layout.** `gitbackup` gives every device its own branch and path prefix in a single
  shared repository, with presets that deliberately stagger schedules so a whole fleet does not
  hit the same provider API endpoint in the same second. Etckeeper has no multi-machine model at
  all; running it across a fleet means reinventing this by hand, once per fleet.
- **No deploy-key provisioning UI**, no OpenWrt-specific manifest capturing file modes and
  ownership the way `sysupgrade` itself understands them, no LuCI integration.

In exchange, etckeeper inherits none of `gitbackup`'s two biggest weaknesses by construction: a
purely local etckeeper repository has no "account compromise" blast radius at all, and nothing
about etckeeper requires trusting a hosting provider with plaintext secrets, because nothing
about etckeeper requires a remote in the first place.

## Who this tool is the wrong choice for

This is the part that matters more than any feature comparison above.

- **If you cannot accept "the hosting account being compromised means every router's root
  password hash, host keys and Wi-Fi passwords are compromised,"** this is the wrong tool,
  full stop. That is not a corner case of `gitbackup` — it is the design.
- **If your environment has a compliance or policy requirement for encryption at rest,** this
  tool cannot satisfy it. There is no encryption anywhere in this pipeline.
- **If you need bounded, prunable history** — a legal requirement to actually delete old data
  after a retention period, not just stop looking at it — Git's append-only-by-convention model
  is the wrong shape. Rewriting history to truly remove an old secret has to happen per branch,
  by hand, and nothing in this project automates it.
- **If your threat model includes "a single compromised router should not threaten every other
  router,"** the shared deploy key with fleet-wide write access is a direct violation of that
  requirement, and there is no configuration of this tool that fixes it — the fix is a
  fundamentally different repository-permission model than Git deploy keys provide.

For any of those, restic or borg pushing encrypted, prunable backups to any storage backend they
support is the better-fitting tool, and the router-side footprint and complexity of running one
of them is the price for the properties `gitbackup` does not have.
