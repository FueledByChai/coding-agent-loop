# 0008 — The section that describes the check is compared with the script by name

Status: accepted
Date: 2026-09-14

## Context

`AGENTS.md`'s "The check" section is the standing description of what `./check.sh` runs, and
nothing read it. Two merges proved the cost. LK-05 wired `scripts/decisions.sh --check` into
`./check.sh` and left the section saying the check was "not wired in yet (LK-05)". LK-16 then
found the section spliced out of two rewrites of itself — LK-05's and LK-11's — so it stated the
sequence twice, gave two figures for one run, and said the decision-record check was not wired in
one line above the sentence that wired it in. `scripts/check-list.sh` already compared the two
shell files that run the loop's checks; the prose was the third place the same list is written
down, and the only one nothing compared. A check line that is missing looks exactly like a check
line that passed.

## Decision

`scripts/check-list.sh --section <doc> <heading> <script>` compares the `scripts/<name>.sh` a
Markdown section names with the checks a script runs as work of its own, and fails in both
directions, naming the check and the side that lacks it. A script the script runs only with
`--self-test` is not a check: the section states that sweep in its own words, once, so a script
joining the sweep does not change the section. `./check.sh` runs the comparison against
`AGENTS.md`'s "The check" section from outside the shared block, because a project's `AGENTS.md`
is its own file.

## Alternatives

- Compare the script and its flags, as the block comparison does: the section would have to spell
  out `scripts/ruleset-check.sh .github/ruleset.json .github/workflows/ci.yml ci/ruleset.json
  ci/workflow.yml`, and prose that repeats a command line is prose that drifts from it.
- Require the section to name the whole sweep, all fourteen scripts: that list is `README.md`'s
  inventory and `check.sh`'s loop, and a list that must be edited whenever a script is added is a
  list nobody keeps current.
- Pin the phrases in `AGENTS.md` with `scripts/prompt-check.sh`: a project installs the kit's
  `AGENTS.md` only when it has none and keeps its own otherwise, so a pin there fails in every
  project that already wrote its check section — a check a project cannot satisfy by its own work.
- Put the comparison in the shared block so every project gets it: a project's `AGENTS.md` may be
  its own and its `scripts/check.sh` is generated from a template, so the pair is not always the
  one the comparison expects.
- Catch only a check dropped from the section: the LK-05 failure was the other direction, a check
  wired into the script and left out of the section, and that is the direction a reader trusts.
- Read the section's prose for the flags it states: prose cannot carry a four-argument command
  line, and a comparison that guessed at partial flags would pass a section naming the wrong
  invocation.

## Consequences

The section and the script can no longer disagree about which checks exist, in either direction,
and `./check.sh` names the check and the side that lost it. The comparison is by name, so the
section may describe a check in any words and the flags stay in the script. Every real check added
to `./check.sh` must be named in the section in the same change or `./check.sh` fails — the
friction is the point, and it is confined to checks that do work, not to scripts joining the
sweep. A project that wants the same guard adds the invocation to its own check, naming its own
`AGENTS.md` and heading; the kit does not install one, since it cannot know what a project calls
its section.

## What would show this was wrong

A check that is real and that the section must not name, or a section that has to name a script
`./check.sh` deliberately does not run, would each make the comparison wrong and reopen the
alternatives above. A merge that splices the section again and still passes would show the
comparison is reading the wrong side.
