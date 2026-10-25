# Standing instructions for agents

This file is the contract for any agent working in this checkout, whatever harness or model
runs it. It replaces instructions that would otherwise have to be repeated in chat. The first
part is the ticket loop, which is the same in every project that uses it; the **Project rules**
below it are this project's own and are what the loop prompts mean when they say "Project rules".

## The loop

- **Settings.** `.loop.toml` holds everything the loop knows about this project:
  `default_branch`, `check` (the full check), `check_fast` (the check to run while iterating),
  `review_paths` (changes that need a human review),
  `trailer_required`, `kit` (where the loop kit lives), and `sprint_label` (the Beads label that
  marks the tickets to work now, by priority then id: either a chosen subset, leaving the rest as
  the pick list `--open` prints, or every open ticket, so an omission is a fault). `scripts/loop-config.sh --all` prints the effective values. Prompts and scripts read them from there; they never hard-code
  a branch, a path, or a build command.
- **Tickets.** The queue is Beads (`bd`), a hard dependency. A ticket is an issue whose id is
  `<PREFIX>-<suffix>`, where the suffix is a number until the prefix's numeric space is spent
  and then the alphanumeric id Beads mints instead (`LK-1af`): its `description` is the intent,
  its `acceptance_criteria` is the done line naming the test, fixture, or measurable output that
  proves it, its `blocks` dependencies are its blockers, and its `section:` and `story:` labels
  group it and name the story it serves. Git is the record of done: a ticket is done when a
  commit whose subject starts with its id is on the default branch, and
  `scripts/backlog-status.sh` derives every ticket's state
  from the commits and the queue (`--next` names the first ready ticket, the `sprint_label`
  tickets first by priority; `--sprint` their states; `--open` the tickets outside the sprint;
  `--sprint-check` the label pairing; `--reconcile` git against Beads; `--show <id>` a ticket
  or story in full; `--stories` every story with a status derived from the tickets that serve
  it; `scripts/sprint.sh add|remove|set` edits the Beads labels). A ticket leaves the queue
  without landing only as **dropped** (kit decision 0030): closed by
  `bd duplicate <id> --of <canonical>` when the same work was ticketed twice, or by
  `bd supersede <id> --with <replacement>` when another ticket carries the work (a fix that
  landed under its commit included), or, for an owner's decision that nothing carries, given the
  `loop:dropped` label (`bd update <id> --add-label loop:dropped`), which is the marker, and
  closed with the reason a label drop also needs (`bd close <id> --force --reason "<why>"`:
  `--force` because bd refuses to close a ticket that is still blocked, and bd keeps a closed
  ticket's first reason, so one already closed is reopened and closed again). Before dropping,
  remove any dependency the ticket already has on its replacement (a `blocks` or
  `discovered-from` edge, say), since `bd duplicate` and `bd supersede` refuse to add a link over
  one, re-point every ticket it blocks to the replacement (`bd dep remove <dependent> <id>`, then
  `bd dep add <dependent> <replacement>`; after a label drop, which nothing carries, only the
  remove), and give the replacement its `story:` labels; afterwards release its `ticket/<id>`
  branch and close any pull request it has. Only the agent holding a ticket's claim, or the
  owner, drops it: a ticket another agent holds is reported to that agent, never dropped over its
  claim. A dropped ticket is never done: it is never ready or offered, no omission from the
  sprint, and no part of a story's count, and a ticket carrying a drop marker that Beads has not
  closed is not offered either. A ticket Beads says is `closed` with no naming
  commit and no drop is a false close, and a landed commit naming a ticket Beads still has open
  is an orphan; `--reconcile` fails both, and every drop it cannot honour: a drop marker on a
  ticket Beads has not closed, a label drop with no reason (bd's placeholder `Closed` is none), a
  landed commit naming a ticket that carries a drop marker, a drop link to anything but a ticket
  in this queue that is not itself dropped, a ticket still to land blocked by a dropped one, and a
  story a link-dropped ticket serves that its replacement does not.
  These rules govern over the generic Beads guidance at the end of this file: a plain `bd close`
  is only for a ticket whose commit has landed, and `--next`, not `bd ready` (which takes any
  closed blocker as satisfied), names the work. Anything discovered while working goes in as a
  new ticket (`bd create`), not into the current one.
- **Merge profile.** A project's pull-request gates follow one of two profiles: staged/legacy
  (the project's existing handoff and gates under the named coordinator, including a staged
  rollout whose queue files are installed but whose controller is not live) or `github-v1` (the
  live App controller, kit decision 0026). The profile is staged/legacy unless the Project rules
  declare `github-v1` active on a line of its own, `Merge profile: github-v1`; a line
  `Merge profile: legacy` states the default, and a contract with no such line is staged/legacy.
  Activation and rollback are explicit edits to that line, made at the cutover and rollback in
  the queue runbook (`templates/queue-operations.md`, installed under `loop/templates/`) and
  recorded in the project's migration decision. Installed queue files, workflows, controller
  statuses or a running controller never change the profile (kit decision 0028). Reading it,
  the prompts stop before changing a gate only when the declaration is contradictory or
  unreadable (more than one `Merge profile:` line in the Project rules, a value other than these
  two, `github-v1` declared while the Project rules describe a legacy gate agents operate as
  active, or staged/legacy in force while they describe the App controller as the live merge
  actor); a check the operator alone arranges during migration or keeps for rollback is not a
  legacy gate agents operate, and the prompts' other stops still apply.
- **Claims and hand-off.** Before work starts, claim the ticket in Beads (`bd update <id>
  --claim`) and push `ticket/<id>` to origin with `scripts/open-ticket-pr.sh <id> --claim`;
  `backlog-status.sh --next` passes over claimed tickets, so several agents can hold several
  tickets. After the commit, `scripts/open-ticket-pr.sh <id>` pushes
  the branch and opens the pull request. When the Project rules declare `github-v1`, the live
  App controller, active, use `--draft`, verify auto-merge is disabled, then mark ready for
  review; retain any required human review for `review_paths`. In the staged/legacy profile,
  the default, preserve the project's complete existing handoff, including whether the PR opens
  as draft or ready and whether auto-merge is armed; copied queue files do not activate the
  controller.
  Several agents can implement at once. In the legacy profile, the named coordinator records
  merge order and selects one candidate in Beads (kit decision 0028). In `github-v1` (kit
  decision 0026), the App selects the candidate and owns CI admission, the merge gate and merging. Existing
  authors and independent reviewers use `queue-handoff` for nomination, selection verification
  and acceptance; they do not create or claim a legacy coordinator, reset legacy statuses or
  publish `Agent review`. Normal Beads ticket claims and proof requirements still apply.
  Waiting PRs do not rebase or request CI. Never run
  `scripts/open-ticket-pr.sh --update-all` as a review handoff. Only the selected candidate gets
  the project's sanctioned refresh after predecessors land, followed by completed head review,
  independent acceptance, then CI and final gate verification. Shadow planning grants no live
  admission. Never push the default branch. Never force-push. Never
  rewrite its history. For legacy gates, `scripts/pr-readiness.sh` prints, for every open pull request, the six
  facts a merge waits on (`--pr <number>` for one of them, `--ready` for the ones that pass all
  six): the project's check ran on the head, no review conversation is unresolved, no changes
  are requested, the agent review's status is success, the branch is current and clean, and the
  branch and the head commit subject name one claimed Beads ticket that carries no drop marker.
- **Commits.** One initial implementation commit per ticket. After publication, append review-fix
  commits on that ticket's branch with the same ticket id rather than rewriting published history.
  Keep unrelated work in another ticket. Every commit's subject starts with the ticket id (`AB-12: ...`); the
  body says what changed and how the done line is proven; the message ends with a
  `Co-Authored-By: <agent> <email>` trailer naming the agent and model that did the work when
  `trailer_required` is on (the PR script refuses a commit without one).
- **Definition of done.** The full check (`check` in `.loop.toml`) passes, and the commit
  includes the test or fixture that proves the ticket's done line; `scripts/proof-gate.sh`,
  run from the check, fails a code change that brings none (a commit body line
  `No new test: <reason>` is the stated exception), and `scripts/coverage-ratchet.sh` fails
  a drop in coverage below the committed floor (a ticket that raises coverage raises the
  floor with `--set` in its commit). Run the fast check while iterating and the full check
  before committing. CI runs the same script; there are no separate
  hand-written CI steps to keep in sync.
- **Isolation.** Prefer an isolated worktree per ticket. The check script knows how to run
  from one (see the project rules for what it resolves).
- **Releases.** Tag them: `scripts/release-notes.sh <from> <to>` lists what shipped, and
  `--archive <tag>` writes the release into `CHANGELOG.md` and closes its shipped tickets in
  Beads.
- **Decisions.** Architecture and product decisions live as records in the decisions
  directory (`decisions` in `.loop.toml`, `docs/decisions` by default), one numbered file each,
  never edited in place; a change is a new record that supersedes the old
  (`scripts/decisions.sh new "<title>" [--supersedes NNNN]`). Read the index before deciding
  anything; cite records by number; write one when a choice is made.
- **Prompts.** `loop/prompts/next-ticket.md` takes the next ticket to done;
  `loop/prompts/grill-me.md` turns a loose idea into stories, acceptance criteria, and
  tickets; `loop/prompts/grill-project.md` is the first-day interview that writes the
  Project rules, the decision records, the first epics, and the check skeleton for a new
  project; `loop/prompts/review-prs.md` reviews the open pull requests and posts the
  `review_context` status the branch rules require (red only for a missing proof, an unmet
  done line, a rules breach, or a named defect). A harness with slash commands wraps them
  in its command directory, and one that loads skills gets a `SKILL.md` pointer per prompt;
  both are pointers, so neither restates a rule; any other agent is pointed at the prompt
  file directly.
- **The kit.** The scripts and prompts are copies from the loop kit named by `kit` in
  `.loop.toml`; `scripts/loop-kit-sync.sh --check` fails when they drift, and
  `scripts/loop-kit-sync.sh` brings them up to the kit's tag. Change them in the kit, not here.

## Project rules

This repository is the ticket loop itself: the scripts, the prompts, the templates, and the
installer that other projects copy from a tag. It is a bash project — nothing is compiled — and
since the kit's own work is ticketed here (decision 0001), it is also the loop's first user.

### Layout

- `scripts/*.sh` and `scripts/*.py` are the shipping surface. Every shell script is bash that
  stays within bash 3.2 (macOS's system bash: no `declare -A`, no `mapfile`, no `${var,,}`) and
  carries a `--self-test` that proves it against a fixture repository it builds in a temporary
  directory; a Python helper carries a `--self-test` that builds its own fixture the same way.
  `scripts/loop-config.sh` reads `.loop.toml`; every other script takes its project-specific
  values from it and names no branch, path, or build command of a project.
- `prompts/*.md` are what an agent follows: `next-ticket`, `grill-me`, `grill-project`,
  `review-prs`, `respond-to-review`. A prompt carries its rules as phrases, and `scripts/prompt-check.sh` fails when
  one loses a phrase that states a rule.
- `templates/` is what a project receives: `decision.md` and the per-stack check and CI
  skeletons (`templates/check/*.sh`, `templates/ci/*.yml`). `commands/*.md` are the wrappers a
  harness with slash commands installs, and `skills/*/SKILL.md` the pointers a harness that
  loads skills reads: one per prompt, frontmatter plus the sentence naming
  `loop/prompts/<name>.md`, checked by `install.sh --skills <dir>` so a skill cannot restate a
  rule and drift from its prompt (LK-18).
- `check.sh` sits at the repository root on purpose, so `install.sh` never copies it over a
  project's own `scripts/check.sh`. `install.sh` copies everything else and never overwrites a
  project's `AGENTS.md`, `CLAUDE.md`, `.loop.toml`, or workflow. A fresh project's `AGENTS.md` is
  the loop section above, a placeholder Project rules that declares the legacy merge profile,
  and the generated Beads block at the end of this file, so these Project rules, and the merge
  profile below, never reach a project (0028).
  `loop.toml.example` is the one file that sits beside a copy of itself: it is copied to the
  root and refreshed, while the `.loop.toml` written from it is kept, so the settings
  documentation a project reads stays current; `scripts/loop-kit-sync.sh` carries it for the
  same reason (LK-19).
- `ci/` holds what a project applies: the workflow skeleton and the `ruleset.json` that pairs
  with it, whose required context is the job that skeleton reports (`Check (scripts/check.sh)`).
  New installations request it with `ci:run`; the first step rejects unrelated label events
  before expensive work (0020). The installer preserves existing workflows.
  `.github/` holds this repository's own pair — `.github/workflows/ci.yml` and
  `.github/ruleset.json` — whose required contexts are the job this repository reports
  (`Check (check.sh)`) and the legacy agent review (`Agent review`), a commit status the legacy
  coordinator posts rather than a job (LK-06; decision 0007, superseded through 0019 by 0028).
  That pair records the legacy gates; under this repository's merge profile below it is not the
  live gate, and no agent here posts `Agent review`. The two pairs differ by where the check sits — a project's under `scripts/`,
  the kit's at the root — and by that second context, and they are not interchangeable.
  `scripts/ruleset-check.sh` fails when either pair disagrees, so neither can drift; the review
  context is the one context it accepts without a job (decision 0006).
- The queue is this repository's Beads database (`.beads`), `docs/PRODUCT_BACKLOG.md` holds its
  stories, and `docs/decisions/` its records (index in its `README.md`; cite a record by number
  and never restate one in a doc or a ticket).

### Build, run, restart

Nothing is compiled and no service is installed by the kit. `scripts/merge-queue.sh` is a
shadow-only journal and read-only observer (0016). Separately, `scripts/review-workers.sh`
runs explicitly configured author/acceptance adapters with durable PR/worktree ownership (0018).
It has no CI, status-publication or merge adapter; installation does not start workers.
A separate opt-in `scripts/queue-controller.sh` supplies App-owned live adapters (0021),
requiring protected operator setup and controlled migration in `templates/queue-operations.md`.
The V1 existing-agent handoff (0026) uses `scripts/queue-handoff.sh` for nomination and
independent acceptance under explicitly approved shared-account trust, without hosted workers.
Its offline fixtures are not live rollout evidence. Installation starts no controller service,
so a project the kit is installed into stays staged/legacy until its operator activates one and
declares `github-v1`; this repository's own controller runs outside the kit, under the merge
profile below. `./check.sh` is both the build and the test. A change to
`scripts/*.sh` reaches a project only when it is tagged and that project's `kit_ref` moves;
until then `scripts/loop-kit-sync.sh --check` fails there, which is the intended signal.

### Merge profile

Merge profile: github-v1

This repository runs the `github-v1` handoff (0026) with its live App controller: the App
selects the candidate, admits CI and merges, and is the only updater of `main`, whose required
gate is the App's `Queue merge gate`; repository auto-merge is off. Authors open drafts, keep
auto-merge disabled, and nominate through `scripts/queue-handoff.sh`; independent reviewers
publish `Queue acceptance` through it. No agent here runs the legacy coordinator, posts
`Agent review` or arms auto-merge. Decision 0028 records this activation and the live evidence
behind it (LK-e9y's controlled proof, the App-merged pull requests, the two queue rulesets,
auto-merge off and the legacy `ci.yml` disabled); 0005's account of this repository's gating
predates it. Rolling back to `legacy` is an edit to the line above, made with the rollback in
`templates/queue-operations.md` and recorded in a decision (0028).

### The check

`./check.sh` is the definition of done, and CI runs the same script. The kit-only
`.github/tests/queue_workflow_test.py` exercises its rendered queue workflow admission before
checkout or setup. Under the merge profile above, the App-dispatched `queue.yml` runs this
script for the selected candidate, and the legacy `ci.yml` is not a required gate. In order it runs every
script's `--self-test`, then `scripts/prompt-check.sh` (a prompt may not lose a rule), then
`scripts/decisions.sh --check` (the kit's records answer to the same sections and index a project's
check demands of them), then `scripts/reference-check.sh` (every ticket carries acceptance
criteria, every `blocks` dependency and `story:` label resolves, no dependency cycle, and every
decision a ticket or a story cites is a record), then the two checks that compare what is written
down more than once,
`scripts/check-list.sh` and `scripts/ruleset-check.sh`, then `./install.sh --self-test`, which
installs into a fresh repository and runs the installed scripts' self-tests there, then
`scripts/backlog-status.sh --sprint-check` (the sprint here is every open ticket, so an omission is
a fault) and `scripts/backlog-status.sh --reconcile` (a ticket Beads has closed must have a landed
commit unless it is dropped, a drop must be one the queue can honour, and a landed commit must
name a ticket Beads has closed that carries no drop marker; 0012, 0030). There is no fast variant: the whole thing takes about
eight minutes, most of it the self-test suite, which the install runs once and then proves the six
stack skeletons' own stack steps separately, rather than paying for the suite once per skeleton
(LK-11). Nothing is resolved from a worktree, since there is nothing to build. The section's list of
checks is compared with the script's by `scripts/check-list.sh --section`, so the two cannot drift
apart again (LK-16).

### Conventions

- **A new script is not done until it is wired in.** Add it to the marked block in `check.sh` and
  to the one in `templates/check/common.sh` — `scripts/check-list.sh` compares the two blocks and
  fails naming a check only one of them runs (LK-14) — and to `install.sh`'s self-test, or its
  `--self-test` never runs in the kit or in any project. A check that does work of its own also
  belongs in "The check" above, which `scripts/check-list.sh --section` compares with `check.sh`
  and fails naming the side that lacks it (LK-16). `install.sh` copies `scripts/*.sh` by
  glob, so nothing else there needs changing.
- **`scripts/*.sh` and `scripts/*.py` ship; nothing else under `scripts/` does.**
  `scripts/loop-kit-sync.sh` and `install.sh` both glob those two extensions, so a fixture
  directory beside the scripts, or a helper in a third language, silently never reaches a
  project (LK-35). A fixture a self-test needs is written into a temporary directory by the
  test itself. Adding a third extension means widening both globs in the same change.
- **Nothing here writes to a project's default branch, and nothing here commits.** The scripts
  print and the agent or the owner commits: `scripts/open-ticket-pr.sh` pushes a `ticket/<id>`
  branch, and `scripts/sprint.sh` edits the Beads queue's labels only (decision 0013).
- **`--self-test` is the proof.** A change with no fixture behind it has not met its done line;
  the exception is a commit body line `No new test: <reason>`.
- **A prompt changes with its phrases.** Editing a rule out of a prompt fails
  `scripts/prompt-check.sh`, and a prompt's change also wants a recorded real run in its pull
  request.

### Docs to keep current

After opening a ticket PR, the author follows `prompts/respond-to-review.md` (installed as
`loop/prompts/respond-to-review.md`) through evidence-backed responses and completed review of
the resulting head (0017). Waiting PRs do not rebase or request CI. The author does not post its
own passing review status; independent acceptance review and final admission remain separate.

`README.md` — the kit's inventory, whose table names every script — and this file, when the
loop's rules change.

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
