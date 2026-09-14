# 0004 — The terminal UI's views render from uncut fields, not from the padded tables

Status: accepted
Date: 2026-09-14

## Context

`scripts/backlog-status.sh` already derives everything the terminal UI's three views show — a
story's status, the tickets outside the sprint and the section each sits in, one ticket or
story in full — but it printed all of it as fixed-width tables for a person to read. The epic
column is padded to about thirty characters, so a story's epic arrives as
`Epic F: Data inventory, cover…`: the rest of the name is gone before the UI ever sees it. And
`--open` collapses to a single summary line whenever the sprint holds every open ticket, which
is a fine sentence for a terminal and useless as a data source.

LK-02 asks the UI (LS-01) for the same three views on LK-01's renderer. The renderer decides
its columns from the frame's width — it drops the ticket count before the status, prints an
epic whole at 200 columns and cuts it at 78 — so it needs the fields before any width is
applied, at a width it does not know until it draws. Two shapes were available: read the
padded tables back, or have `backlog-status.sh` offer the fields uncut.

## Decision

`scripts/backlog-status.sh --plain` prints the same rows as `--stories` and `--open` with the
fields tab-separated and uncut — no padding, no ellipsis, no summary line, one row per line.
The padded tables stay exactly as they were for a person reading them; `--plain` is the
machine-readable form, and the UI's views render from it and never from a padded table. Every
width decision, including where the epic is cut, belongs to the renderer and is made once, as
each line leaves the frame.

## Alternatives

- Read the padded tables back, or regex them apart on runs of spaces: rejected because the
  epic is already truncated in the output — the information a wide frame needs is gone — and
  because the column boundaries are spaces, so any change to `backlog-status.sh`'s padding
  would silently change what the UI parses.
- Give `backlog-status.sh` a `--width`, or widen the tables: rejected because the subprocess
  does not know the terminal's width, and it would put the same layout decision in two scripts,
  so a frame could still be assembled from fields one of them had already cut.
- Have the UI derive the data itself from git and the files: rejected because it would
  duplicate `backlog-status.sh`'s derivations — a ticket's state, its claim, its sprint
  membership, a story's status — which are exactly what that script's self-test already pins.

## Consequences

`--plain` joins `backlog-status.sh`'s surface and carries its own self-test assertions, from
the same fixture as the padded tables, so the two forms are proven to describe the same rows.
The two can still drift — a field added to a table and not to the plain output — and the
field-count assertion is what catches it. The padded tables remain for humans and nothing
parses them; a view that needs a field `--plain` does not print is a change to
`backlog-status.sh`, not a reason for the UI to shell out to git. Decision 0002 is unchanged:
the renderer is still one perl program, and the goldens are still heredocs in the script.

## What would show this was wrong

A view needs a field the plain output does not carry, or drops one the padded table shows,
often enough that the two forms are maintained as separate derivations rather than one — the
sign that a single script should own the layout after all. Or a consumer outside the kit
starts parsing the padded tables, which would mean `--plain` is not in fact the machine-readable
form and the split was drawn in the wrong place.
