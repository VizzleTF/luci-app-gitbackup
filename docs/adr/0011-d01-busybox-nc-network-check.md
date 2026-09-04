# 0011 (D01): Network check is built around busybox nc's actual, limited flag set

## Context

`gb_have_net` in `lib.sh` needs to answer one question reliably — is the network reachable —
to satisfy the "skip cleanly when offline" requirement (R92) and the daily background
visibility re-check (R37/R42). Build-time testing on the target image (owlab) found that this
function reported "unreachable" for *every* host, always, which would have made `run` behave as
permanently offline.

## Decision

The reachability check is implemented against what busybox `nc` 1.37.0 on the target image
actually supports — `nc [IPADDR PORT]` and nothing else — rather than against a GNU-netcat-like
interface with `-w` (timeout) and `-z` (scan, no data) flags.

## Why

The original implementation assumed `-w`/`-z` were available, matching common netcat usage
elsewhere; there was no way to "fix" that assumption in place, because the busybox applet on
this target simply does not implement those flags at all — every call using them was
effectively malformed and failing before it could test anything. The function had to be
rewritten around a plain connect, with the project's own timeout logic (a bounded subshell)
standing in for the `-w` flag nc doesn't have.

## Consequences

The reachability check can no longer rely on documented `nc` timeout behavior and has to own
its own timeout handling in shell instead — one more piece of environment-specific plumbing to
maintain. This gap was invisible from the brief and from code review alike; it surfaced only
because it was run against the real target image, which is why the project now treats
`// VERIFY:` against a real busybox build as mandatory for anything that shells out to a
system tool, not just a nice-to-have.
