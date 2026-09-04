# 0009: Two independent cron-expression validator implementations

## Context

A cron expression needs validating twice: live, per keystroke, in the LuCI Settings JS view,
and again by the shell backend before it is ever written into `/etc/crontabs/root`.

## Decision

Two separate implementations exist on purpose — `lib.sh` in POSIX shell, and a JS module used
by the view — rather than one implementation shared across both layers.

## Why

This duplication was an explicit customer requirement, not a default: the brief and the
customer both called for "two implementations." A single shared implementation was the
available alternative — either driving the shell validator from JS over a ubus round-trip on
every keystroke, or embedding a JS engine in the shell backend — and was rejected on two
counts: it is exactly what the customer said not to build, and it would also have been
impractical on its own merits, since per-keystroke validation over ubus is latency-bound and
busybox `ash` has no JS runtime to run shared code the other direction.

## Consequences

The two implementations can silently diverge on edge cases (a five-field expression the shell
version accepts and the JS version rejects, or vice versa) since there is no single source of
truth for "what is valid." The only thing keeping this in check is a shared fixture file
(`tests/fixtures/cron.tsv`) run through both `sh` and `node` in CI, with disagreement between
them treated as a red build. That test is now load-bearing infrastructure: without it, this
deliberate duplication would be an ordinary maintenance hazard instead of a controlled one.
