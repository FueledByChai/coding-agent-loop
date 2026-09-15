# 0010 — The settings example is a synced kit file, and .loop.toml beside it is the project's

Status: accepted
Date: 2026-09-15

## Context

`install.sh` writes a project's `.loop.toml` from the kit's `loop.toml.example` and never overwrites
it afterwards — right, because that file is the project's own: its sprint, its `kit` and `kit_ref`,
its paths. But `scripts/loop-kit-sync.sh` listed only `scripts/*.sh`, `prompts/*.md`,
`templates/*.md`, `templates/check/*.sh` and `templates/ci/*.yml`, so the example reached a project
once and was never mentioned again: a change to it after a project installed was invisible to that
project and to every check, while the scripts and prompts beside it were compared and reported.

LK-15 is the case that made it matter. It added a paragraph on the two readings of `sprint` to the
example and to this repository's `.loop.toml`, and the prompts and `AGENTS.md` now settle which
reading applies by pointing at "the comment above the list" — the comment the project's `.loop.toml`
carries, which came from the example. A project installed before LK-15 has the old comment and no
example to read the new one from, so the pointer resolves to nothing. Tessera is such a project: its
sprint is a chosen subset, its `.loop.toml` still carries HK-39's one-line comment, and it has no
`loop.toml.example` at all. And `prompts/grill-project.md` tells a first-day session to write
`.loop.toml` "from `loop.toml.example`" — a file a project set up by `install.sh` did not have.

## Decision

`loop.toml.example` is a kit file like the scripts. `install.sh` copies it to the project root,
beside the `.loop.toml` it writes from it, and `scripts/loop-kit-sync.sh` carries it, so `--check`
fails in a project whose copy differs from the kit's. `.loop.toml` is untouched by both and stays
the project's own, written once.

It sits at the root rather than under `loop/` because that is where both readers look:
`prompts/grill-project.md` names `loop.toml.example`, the kit's own `.loop.toml` points at it, and
the kit keeps its copy at the root — one path that is right in the kit and in a project.

## Alternatives

- **Answer it the other way: stop pointing at the example.** One comment in the kit's `.loop.toml`
  satisfies the ticket's second route literally, but it fixes the smaller half.
  `prompts/grill-project.md` is read in *every* project and names `loop.toml.example` as the source
  of a project's `.loop.toml`; deleting the kit's pointer leaves that one dangling, and leaves the
  example's staleness unreported.
- **Sync the example into the project's `.loop.toml`.** That overwrites the project's settings — its
  sprint, its `kit`, its paths — on every sync.
- **Sync it under `loop/`, with the prompts and templates.** The file's path then differs between the
  kit (root) and a project (`loop/`), and a shared prompt cannot name both. That is LK-25's fault —
  a path right in one layout and wrong in the other — and this record does not add a second instance.
- **Generate one from the other.** The two files answer different questions: one documents every key,
  the other is one project's values. Deriving either from the other loses the documentation the
  moment a project edits its config.
- **Leave it unsynced and document the copy step.** That is the state the ticket was filed from.

## Consequences

A project's `loop-kit-sync.sh --check` reports `missing: loop.toml.example` until its first sync
after this lands. That is the report the ticket asked for, not a fault, and the sync repairs it.

Every project now carries two settings files, and the distinction has to hold: the example is the
kit's and is current, `.loop.toml` is the project's and may say anything. A project that edits the
example is drifted and `--check` says so; the fix is to edit `.loop.toml`, which is where a project's
settings belong. This is the one place in the kit where a file and a copy of it sit side by side by
design, so it is the one place that distinction is worth repeating.

## What would show this was wrong

A project whose `.loop.toml` is generated from, or read from, `loop.toml.example` at run time — the
two would then have to agree, and the sync would be overwriting a config rather than refreshing
documentation. Or a project that finds the second file confusing enough to edit it instead of
`.loop.toml`, which would show up as `--check` failing in a project that believes it configured
something.
