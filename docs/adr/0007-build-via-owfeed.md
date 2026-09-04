# 0007: Build via owfeed, not the OpenWrt SDK

## Context

Both packages (`gitbackup`, `luci-app-gitbackup`) are noarch: no compiled bytes at all, only
POSIX shell, JSON, JS and markup. `luci-theme-footstrap` set a working precedent for building
this class of package a different way (raised by the customer as G08).

## Decision

Packages are built with `owfeed build`, not through a full OpenWrt SDK checkout.

## Why

For a noarch package the SDK's only real job is `cp`, but reaching that point means downloading
and validating a full cross-toolchain — minutes spent for zero benefit. `owfeed` does three
things that would otherwise have to be done by hand: it builds the `.lmo` locale catalogs, it
generates the conffiles/scripts sidecars, and — the one that actually matters functionally — it
wraps `default_postinst`, without which `/etc/uci-defaults/99-gitbackup` would never run on
install at all. This last point ruled out "just use SDK and accept the slower build," since it
isn't only a speed tradeoff: skipping the wrapper breaks first-boot setup. Signature-chain
integrity isn't sacrificed by taking this path: `owfeed` uses the host `apk` binary taken from a
release SDK, itself verified through the same ed25519-over-sha256sums chain, pinned from a
separate host than the one serving the packages.

## Consequences

The Makefile stops being the sole build authority: `tools/stage.sh` reads lifecycle scripts out
of it specifically to feed the `owfeed` path, so the Makefile has to stay accurate even though
`make` itself no longer drives what actually ships. Building via a plain SDK checkout still
works for anyone who wants to, but nothing released is produced that way, so that path is
untested by CI and can silently rot without anyone noticing until someone tries it.
