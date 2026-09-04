# 0010: Device identifier is chosen, not derived from hostname

## Context

One shared repository for a fleet of routers (R14) collides with the fact that every freshly
flashed OpenWrt device has the same default hostname, literally `OpenWrt`. Two such devices
sharing that identifier would silently overwrite each other's branch and path prefix.

## Decision

`device_id` is a UCI choice among `hostname`, `custom`, and `board` — not an unconditional
dependency on the system hostname. When `device_id=hostname` and the actual hostname is still
the default `OpenWrt`, `run` refuses outright with exit 2, rather than proceeding under a
colliding name.

## Why

Deriving the identifier unconditionally from hostname — the naive reading of R14/R98 before
this was raised — was rejected because the collision it causes isn't a hypothetical edge case;
it is guaranteed for any two out-of-the-box devices, which is exactly the fleet scenario R14
describes. A `board` option (model slug plus the last 6 hex digits of the first MAC) is offered
specifically because it is deterministic and unique without requiring the user to type
anything, for the case where a custom name isn't wanted.

## Consequences

Every branch name, path prefix, and generated `RECOVERY.md` is keyed to whichever identifier
scheme was active the first time the device was configured. Changing `device_id` or `device`
afterward is not a rename from git's point of view — it produces a new branch with no history
continuity with the old one, and nothing in the spec detects or warns about this, so a user
"renaming" a device this way silently starts a fresh history and orphans the old branch.
