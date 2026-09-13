# 0001 — The kit is its own project; the loop's work is ticketed here

Status: accepted
Date: 2026-09-13

## Context

The kit began inside `FueledByChai/tessera` and was lifted into its own repository (HK-15,
HK-16), but it kept being developed as a Tessera concern: its forty-eight tickets sat in
Tessera's `BACKLOG.md` under `## Housekeeping`, its sprint was Tessera's sprint, and its
decisions would have been Tessera's records. This repository has no `BACKLOG.md`, no
`.loop.toml`, and no `docs/`, and nineteen of its twenty-one commits carry no ticket id, so
`scripts/backlog-status.sh` here reports nothing and the loop has never worked the kit's own
queue.

On 2026-09-13 the owner asked for a terminal UI over the loop's own state (LS-01, LS-02), which
forced the question: a kit feature, ticketed in another project's backlog, with its decisions
filed among that project's product decisions. Reading the forty-eight `HK-` tickets showed the
prefix was not the kit's either — roughly half are Tessera's own housekeeping that shared it:
the deploy loop (HK-11, HK-30, HK-44, HK-47), `scripts/coverage.sh` (HK-23, HK-48),
`scripts/scratch-console.sh` (HK-43), `web/app/page.tsx` (HK-45), the console layout checks
(HK-07, HK-08), the self-hosted runner (HK-12). The owner's instruction was that the project
started in Tessera but should move here, and that the loop's tickets and stories should come out
of Tessera.

## Decision

The kit is its own loop project. Its tickets, stories, sprint, and decision records live in
`FueledByChai/coding-agent-loop` — `BACKLOG.md`, `docs/PRODUCT_BACKLOG.md`, `sprint` in
`.loop.toml`, `docs/decisions/` — and every new kit change is ticketed here.

Its ticket prefix is `LK-` and its story prefix `LS-`, both new sequences, so that `HK-` means
only Tessera's own housekeeping from here on. Tessera keeps its `HK-` tickets and its Epic I,
and the forty-three done `HK-` tickets stay in its history, archived into its `CHANGELOG.md` by
LK-07 rather than re-listed here: a ticket is done by a commit in the repository that holds it,
and those commits are Tessera's.

## Alternatives

- Leave the kit's work in Tessera: one loop, one sprint, one place to look, and the reason
  forty-eight tickets worked. It keeps a kit feature ticketed in an unrelated product's backlog
  and its records among that product's decisions, which is what the owner asked to stop.
- Move all forty-eight `HK-` tickets here: the prefix is not the kit's. Half of them are
  Tessera's own code, and moving them would put Tessera's deploy loop and coverage script in the
  kit's queue.
- Re-list the forty-three done tickets here: they would all read `todo`. Their proving commits
  are in Tessera's history and this repository's commits carry no ticket ids, so `--next` would
  offer `HK-01`.
- A third repository for the loop's tooling: another checkout to keep in step, with no code to
  separate from this one.

## Consequences

Kit changes now take a pull request here and, when they ship to projects, a tag and a `kit_ref`
move in each consumer — the pattern HK-39 and HK-40 already used, now with the ticket in the
same repository as the diff. Tessera's `--next` no longer sees kit tickets, so there are two
queues to look at; the terminal UI of LS-01 is the answer to that, and until it exists the two
backlogs are read separately. Tessera's `.loop.toml` keeps its `kit` and `kit_ref`, so
`scripts/loop-kit-sync.sh --check` still fails there on drift, and LK-07 moves that tag once the
prefix filter it needs has shipped.

Two boundaries stay deliberately uneven. HK-46 spans both repositories — a kit `proof_pattern`
default and a Tessera `.loop.toml` line — and stays whole in Tessera rather than being split for
one regex. And Tessera's Epic I (BT-901 to BT-906) stays there, so the loop's stories are split
across two files until it moves, which is a candidate for a later ticket rather than part of
this one.

The kit's own check does not yet run `scripts/decisions.sh --check` (LK-05), and its ruleset
requires only `Check (scripts/check.sh)`, not the agent review (LK-06) — which must not be added
before something runs the review for this repository, or every pull request would wait forever.

## What would show this was wrong

The two queues prove worse than one: kit work sits unread in `coding-agent-loop/BACKLOG.md`
while the sprint the owner actually looks at is Tessera's, and tickets get worked from the wrong
file. Then the kit's tickets return to a single backlog, in whichever repository holds the
sprint the owner reads, in a superseding record. Or the kit gains consumers other than Tessera
and its releases have to be tracked somewhere those consumers already look.
