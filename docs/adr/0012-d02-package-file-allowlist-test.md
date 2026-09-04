# 0012 (D02): CI enforces an explicit allowlist for package/gitbackup/files

## Context

Across three separate build waves, implementers left working artifacts behind inside
`package/gitbackup/files/` — `*.bak` files, a stray `files/tmp/` directory — and those files
ended up shipped inside the built `.apk`, because nothing checked package contents against
what was actually intended to ship.

## Decision

A CI test fails on any file found under `package/gitbackup/files/` that is not on an explicit
allowlist of files the package is meant to contain.

## Why

Relying on code review to catch stray files was tried, implicitly, across three build waves,
and failed each time — a reviewer skimming a diff does not reliably notice one extra file
sitting in an otherwise-large tree, and nothing in a normal diff view distinguishes "an
intentional new file" from "leftover debris" for a human to react to. Making the check
mechanical (a fixed list, compared against what's actually on disk) removes the judgment call
entirely rather than asking reviewers to be more careful next time.

## Consequences

Every legitimately new shipped file now requires a matching allowlist update, adding one extra
line to review on every packaging change. That is a deliberate, small, permanent tax, accepted
in exchange for making it structurally impossible for a `.bak` file or a debug directory to
reach an end user's `.apk` unnoticed again.
