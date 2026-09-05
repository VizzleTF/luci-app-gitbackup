# 0001: No encryption; a hard public-repository gate is the only line of defense

## Context

Backup content includes real secrets in plaintext: `/etc/shadow`, dropbear host keys,
`authorized_keys`, WPA PSKs, WireGuard private keys, PPPoE credentials, `uhttpd.key`. The
brief raised encryption as an open question up front.

## Decision

The backup is stored unencrypted. The single safety mechanism is a hard block on pushing
when the remote repository is public: `visibility=public` with `scrub=0` is treated as an
impossible configuration state (scrub is forced on), and if the repository is actually public
while `visibility=private` is set, `run` exits 4 without pushing, with no override flag.

## Why

At-rest encryption was considered and rejected. A router has no secure place to hold a
decryption key that isn't itself part of the thing being backed up, and restore is meant to
work from an arbitrary machine at the moment of a catastrophe — a forgotten or lost passphrase
would make the backup unrecoverable, defeating the feature's entire purpose. Plaintext plus a
mechanical, testable gate (one exit code, one condition) is simpler to verify than "encrypted,
except when the user mismanages the key." Users who need encryption are pointed to
`docs/COMPARISON.md`, which discusses restic/borg for that case instead of retrofitting
encryption here.

## Consequences

If the repository is ever switched from private to public, or is compromised, the entire
history leaks in plaintext — forks and the GitHub Archive Program do not un-leak it. The
project accepts this and documents it loudly (README Security model, an always-visible
"what leaves in the open" block in the Overview) rather than mitigating it technically. Users
are pushed toward operational mitigations (separate org, mandatory 2FA, deploy key instead of
an account-wide PAT), none of which are enforced by the tool itself.

## Revisited, 2026-09-05

The question was reopened and researched in full:
[docs/research/encrypted-backups.md](../research/encrypted-backups.md). Two things changed
since this decision was first written, and one did not.

Changed: the tool cost is small (`openssl-util` is +939 KiB on top of the `libopenssl3` that
`git` already installs), and deterministic — convergent — encryption with an IV derived from
the plaintext's own sha256 keeps an unchanged file's blob identical, so change detection and
repository growth are not the obstacles this ADR assumed. "A router has no secure place to
hold a key" is also weaker than stated: `/etc/gitbackup/` is 0700 and already a hard exclude
from the backup set, which is where the deploy key lives today.

Unchanged, and still decisive: a git credential that is lost can be regenerated; a decryption
key for backups already pushed cannot. The one artefact this project built for recovering a
router from nothing — the recovery card — has a deliberate, tested invariant against carrying
a secret, and no other place survives a total device loss. The research recommends keeping
this decision, and names the single call that would reverse it: accepting "no externally
stored key means permanent data loss" as a consequence documented as loudly as the
public-repository one above.
