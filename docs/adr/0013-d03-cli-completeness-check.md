# 0013 (D03): CLI completeness is verified as a whole, not inferred from manifest status

## Context

R89 requires eleven CLI subcommands. Four of them — `collect`, `diff`, `paths`, `card` — were
still stubs printing "not implemented yet" while the manifest line for R89 read `done`. This
was only discovered incidentally: task 11 (the LuCI Overview screen) needed `diff`/`collect`
output to render an honest "uncommitted changes" indicator and found nothing to call. No
reviewer had caught the gap before that, because review happened per task, and "the CLI as a
whole" wasn't any single task's explicit responsibility.

## Decision

CLI completeness against R89's full subcommand list is checked as its own explicit item
(tracked as task T17), instead of being assumed true because the requirement's manifest status
already reads `done`.

## Why

The alternative — trusting a `done` status on a manifest line to mean the described surface
actually exists — is what failed here. A status field captures intent recorded at planning
time; once work is split across separate tasks and executors, nothing keeps that field
synchronized with what code actually landed. The gap was found only because a downstream
consumer (the Overview screen) happened to exercise the missing commands directly — an accident
of task ordering, not a designed safeguard.

## Consequences

A cross-cutting "does the full public interface actually exist and work" check now needs an
owner that isn't any single feature task — T17 fills that role for this specific interface
(the CLI), but the underlying blind spot is general: any other multi-task requirement in this
project's manifest can carry a `done` status without its full surface having been exercised
end-to-end, and this ADR does not close that gap structurally, only for this one case.
