# 0003: One branch per device, not one shared branch

## Context

The brief wanted one shared repository for the whole fleet (R14), with each device writing
under its own subdirectory of a common tree (implied by R98's original schema). This collides
with the no-clone constraint (0002): composing a single shared root tree on every run would
require knowing about every other device's current subtree, which means fetching it.

## Decision

Each device pushes to its own branch, `device/<id>` by default. There is no combined tree on
`main`; "one repository for the fleet" holds only at the hosting level (one GitHub repo, one
set of access controls), not as a single git history.

## Why

A single shared branch, with each device only ever touching its own subdirectory, was the
literal reading of R14/R98 and was considered first. It was rejected because preserving other
devices' subtrees on every commit means reading the current root tree before writing — exactly
the "read everything to write your own part" cost that branch-per-device avoids entirely.
Branch-per-device means a device's commit only ever depends on its own previous commit; no
other device's state needs to be fetched, known, or reasoned about.

## Consequences

There is no single commit that represents "the whole fleet's state right now" — inspecting
multiple devices means checking out multiple branches. Non-fast-forward races become
practically impossible except between two runs of the *same* device (already handled by
`flock` and a single retry). The `path_prefix` default (`devices/{device}`) is now partly
redundant with the branch name, kept mainly so restore's sparse-checkout path and the on-disk
layout stay meaningful if this decision is ever revisited.
