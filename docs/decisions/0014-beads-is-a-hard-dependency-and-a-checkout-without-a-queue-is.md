# 0014 — Beads is a hard dependency, and a checkout without a queue is told so

Status: accepted
Date: 2026-09-16

## Context

The port moved every reader of the queue onto `bd` (LK-42 to LK-44): the tickets, their
acceptance criteria, their dependencies, their labels and their state live in a Dolt database
under `.beads`, and the working tree carries only its configuration. `bd` is installed by hand on
the owner's machine, and the database is not a file a clone gets: it is synced through the
`refs/dolt/data` ref. A fresh checkout, and a project that has never run `bd init`, has no
database at all, so every reader has to decide whether that is an empty queue, a skip, or a
failure.

## Decision

Beads is a hard dependency of the loop. `scripts/backlog-status.sh` and
`scripts/reference-check.sh` fail with the command that creates a database (`bd init --prefix
<PREFIX>`) rather than printing an empty queue or skipping; `install.sh` names the step and its
self-test creates a queue in its fixture; and both CI workflows install the pinned v1.3.0 release
and run `bd bootstrap --yes` before the check, so a runner reads the same queue a checkout does.
A project publishes its queue with `bd dolt push`.

## Alternatives

- **Skip when there is no `.beads`.** An empty queue prints an empty table, which reads as "no
  work" rather than "no queue" - the affordance-nothing-reads shape this kit files tickets
  against itself over.
- **Commit `.beads/issues.jsonl` and read that.** A second record of the queue, hand-kept in
  step with the database, which is the shape 0012 exists to remove.
- **Require the owner to install `bd` and leave CI out of it.** The check's own consumers run in
  CI, so the queue has to be readable there or the checks cannot run.

## Consequences

Every machine and runner that runs the loop needs `bd`; CI carries the pinned install and the
bootstrap, and a fresh clone needs `bd bootstrap`. The kit's own check therefore depends on the
network path to GitHub's release and the `refs/dolt/data` ref, which is a new failure mode for a
script that used to read a file.

## What would show this was wrong

`bd` failing on a machine the loop is expected to run on, or the install-and-bootstrap steps
making CI too slow or too flaky to keep, which would say the store is not portable enough to be
the loop's.
