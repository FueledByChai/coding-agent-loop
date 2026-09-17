# 0015 — The markdown ticket file retires, and the stories stay a document

Status: accepted
Date: 2026-09-16

## Context

Decision 0012 made Beads the ticket store and kept `BACKLOG.md` until its last reader moved. The
readers were `scripts/backlog-status.sh`, `scripts/sprint.sh`, `scripts/release-notes.sh
--archive`, `scripts/reference-check.sh`, and the four prompts; LK-42 to LK-45 moved them all.
`docs/PRODUCT_BACKLOG.md` held the stories - intent, acceptance criteria, wireframes - which are
not tickets.

## Decision

`BACKLOG.md` is deleted, and the `backlog` setting is gone from `.loop.toml`. Tickets live in
Beads. `docs/PRODUCT_BACKLOG.md` stays as the stories document: a story is intent and acceptance
criteria a person reads, a ticket is the shippable slice, and a ticket says which story it serves
with a `story:<ID>` label. A story's status is derived, never written by hand, and `--stories`
and `--show <story>` still read it.

## Alternatives

- **Keep `BACKLOG.md` as the record of what the tickets were.** Git history is that record, and
  the file's last reader has moved.
- **Move the stories into Beads as epics too** (the shape the owner's rockbox-ghl migration
  uses). Rejected for the kit: a story's acceptance criteria and wireframe are long prose a
  human reads and a review cites, while Beads' issue model is the tickets the loop claims and
  commits; the stories file is not a second record of ticket state.
- **Generate the stories document from Beads.** 0012's rejected projection, at a different
  scope: the file would lose the wireframes and the product prose.

## Consequences

The kit has no markdown ticket file and `scripts/*` name none. A project's stories remain a
document it can edit freely without touching the queue's state. `--stories` is now the only
reader of that file, so a project that keeps no stories file gets the "no product backlog"
message rather than a failure.

## What would show this was wrong

A story's acceptance criteria needing to be queried or claimed like a ticket's, or a second
writer of ticket state appearing in the stories file, which would say the split put state back
into prose. Or a project wanting the stories in Beads and finding `--stories` cannot express
them.
