# 0012 — Beads is the ticket store, and Git is still the proof

Status: accepted
Date: 2026-09-16

## Context

The loop keeps its tickets in a markdown file: `### <ID> <title>` headings with a paragraph of
intent, a **Done when** line, a `Blocked by` list, and the claims `doing` and `blocked <reason>`.
`scripts/backlog-status.sh` parses it and derives each ticket's state from the commits. It works,
and its limits are real: the file is the only place a claim can be written, so two agents claiming
at once is a branch on origin rather than a lock; a dependency is text the loop re-reads, so the
ready set is recomputed by hand on every call; and there is no query beyond what the file's shape
allows.

Beads (`bd`) is installed on the owner's machine — a Dolt-backed issue graph with dependencies,
hash or explicit ids, atomic claims, and a `ready` query that computes the unblocked set. The
owner has migrated `rockbox-ghl` to it: 94 tickets and 19 stories imported with no status or
dependency mismatch against `scripts/backlog-status.sh`.

The kit's own rule is the constraint that shapes the choice: a ticket is done when a commit whose
subject starts with its id is on the default branch. That is what makes "done" a fact rather than
an assertion, and it is the rule this decision must not lose.

## Decision

Beads becomes the ticket store and Git stays the proof. Tickets, their dependencies, and their
state live in `bd`; a ticket is closed in `bd` only when a commit whose subject starts with its id
is on the default branch; and the check reconciles the two, failing when a closed issue names no
such commit and when a commit names an issue that is still open. The markdown backlog retires.

## Alternatives

- **Keep the markdown file and add nothing.** The claims stay a branch on origin, the ready set
  stays a re-parse, and every project keeps its own copy of the queue.
- **Keep the file as the record and mirror it into `bd`.** Two records, one of them written by
  hand, with nothing deciding which wins when they disagree — the shape this kit files tickets
  against itself over.
- **Make the file a generated view of `bd`.** Single write path, every existing script keeps
  working, and it is the smaller step. Rejected as the destination because the generated file
  cannot express what `bd` holds — a claim's actor, a comment, a dependency's type — so the loop
  would keep reading a lossy projection of its own data. Worth revisiting only if the scripts
  prove impossible to move.
- **Let `bd close` be the record of done.** The smaller port, and it gives up the rule above:
  nothing would then tie a closed ticket to the commit that proves it.
- **Give each project the store it prefers.** Two loops to keep in step, and `loop-kit-sync.sh`
  has no way to compare them.

## Consequences

`scripts/backlog-status.sh` gains a ticket source and every script that reads the file follows it
one ticket at a time: claims move to `bd update --claim`, the sprint list becomes labels and
priorities rather than a line in `.loop.toml`, and `--archive` closes out of `bd` rather than
moving headings into `CHANGELOG.md`. The kit's own backlog migrates too, so the loop's first user
remains its own test.

Two semantics change and are worth naming. `--ref` currently means "judge done as of this commit",
which is what lets a checkout that has not pulled avoid re-offering merged work; a Dolt database
has no such ref, so the flag narrows to naming the commit a ticket's proof is verified against.
And the file's order — the order tickets are worked in — has no equivalent: `bd` orders by
dependency and priority, so an order that matters has to be stated as a priority rather than
implied by a position.

The kit depends on `bd` being installed. `check.sh` runs the scripts' self-tests, so the beads
paths need a `bd` on the machine running them, and CI needs a decision about installing one — a
third-party binary the owner has, to date, installed by hand from Homebrew.

`BACKLOG.md` stays in the tree until the last reader has moved, as the record of what the tickets
were, and is deleted in the change that removes its final reader.

## What would show this was wrong

A reconciliation that cannot be made to pass — a closed ticket the commits do not name, or a
commit naming an open one, showing up often enough that the gate is being waived rather than met.
Or `bd` failing on a machine the loop is expected to run on, which would say the store is not
portable enough to be the loop's. Or the sprint order turning out to matter more than a priority
can carry, which would say the file's ordering was load-bearing and this record gave it away.
