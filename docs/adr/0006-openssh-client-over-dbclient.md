# 0006: openssh-client over the built-in dbclient

## Context

The router already ships dropbear/`dbclient`. Pulling in `openssh-client` +
`openssh-keygen` adds roughly 1.3 MiB on top of an already ~22 MiB git+https dependency stack,
which is the kind of addition a size-constrained OpenWrt package is supposed to avoid by
default.

## Decision

SSH authentication uses `openssh-client`/`ssh-keygen`, not `dbclient`.

## Why

`dbclient` was tried and measured to fail on three independent, each individually
disqualifying grounds: it cannot read OpenSSH-format private keys — `ssh-keygen -t ed25519`'s
output, in both the modern `BEGIN OPENSSH PRIVATE KEY` form and PEM, produces `Exited: String
too long`; it doesn't understand the `UserKnownHostsFile` option (`Ignoring unknown
configuration option`), forcing reliance on `~/.ssh/known_hosts`, which conflicts with keeping
everything gitbackup-owned under the hard-excluded `/etc/gitbackup/`; and git's capability probe
(`-G`) against it fails, causing git to silently drop to "simple" SSH invocation and stop
passing *any* `-o` option — meaning `StrictHostKeyChecking=yes` never actually reaches the
process. A `dropbearkey` + `dropbearconvert` workaround was considered, since it would have
saved the 1.3 MiB — rejected because it introduces a separate, non-standard key format and
still leaves known_hosts pinned to `~/.ssh/`, buying a small size saving at the cost of
complicating the one path (host-key verification) that is the project's actual security
boundary for the sshkey auth mode.

## Consequences

The package permanently carries an extra ~1.3 MiB DEPENDS, called out explicitly in the
README's size table rather than hidden in a transitive dependency. `known_hosts` lives under
`/etc/gitbackup/` and is therefore excluded from every backup by the same rule that protects
the private key — every bare-metal recovery re-accepts the host key from scratch during
`gitbackup test` rather than trusting a value carried over from before, which the project
treats as the correct behavior rather than a gap to close later.
