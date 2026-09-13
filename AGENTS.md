# Standing instructions for agents

This file is the contract for any agent working in this checkout, whatever harness or model
runs it. It replaces instructions that would otherwise have to be repeated in chat. The first
part is the ticket loop, which is the same in every project that uses it; the **Project rules**
below it are this project's own and are what the loop prompts mean when they say "Project rules".

## The loop

- **Settings.** `.loop.toml` holds everything the loop knows about this project:
  `default_branch`, `backlog` (the ticket file), `check` (the full check), `check_fast` (the
  check to run while iterating), `review_paths` (changes that need a human review),
  `trailer_required`, `kit` (where the loop kit lives), and `sprint` (the tickets chosen
  for now, in order). `scripts/loop-config.sh --all` prints the effective values. Prompts and scripts read them from there; they never hard-code
  a branch, a path, or a build command.
- **Tickets.** The backlog is a list of tickets, each a paragraph of intent plus a **Done when**
  line naming the test, fixture, or measurable output that proves it. Git is the record of
  done: a ticket is done when a commit whose subject starts with its id is on the default
  branch. `scripts/backlog-status.sh` derives every ticket's state from the commits and
  `--next` names the first `todo` whose `Blocked by` tickets have landed, taking the
  `sprint` list first and file order after it (`--sprint` shows the sprint's states;
  `--open` the pick list of tickets not done and not in the sprint; `--show <id>` a ticket
  or story in full; `--stories` every story with a status derived from the tickets that
  serve it; `scripts/sprint.sh add|remove|set` edits the sprint list). The backlog file
  carries only claims: `doing` while someone works a ticket, `blocked <reason>` when it needs
  a decision. Clear the `doing` claim in the ticket's own commit and never write a done line.
  Anything discovered while working goes in as a new ticket, not into the current one.
- **Claims and hand-off.** Before work starts, `scripts/open-ticket-pr.sh <id> --claim` pushes
  `ticket/<id>` to origin; `backlog-status.sh --next` passes over claimed ids, so several
  agents can hold several tickets. After the commit, `scripts/open-ticket-pr.sh <id>` pushes
  the branch and opens the pull request; a green PR up to date with the default branch merges
  on its own, one that touches a review path is labelled `needs-review` and waits for the
  owner. Several agents can run at once: claims keep them on different tickets, and
  `scripts/open-ticket-pr.sh --update-all` (run first by the review pass) rebases the open
  pull requests a merge left behind. Never push the default branch. Never force-push. Never
  rewrite its history.
- **Commits.** One commit per ticket. The subject starts with the ticket id (`AB-12: ...`); the
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
  `--archive <tag>` moves the shipped tickets out of the backlog into `CHANGELOG.md`.
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
  in its command directory; any other agent is pointed at the prompt file directly.
- **The kit.** The scripts and prompts are copies from the loop kit named by `kit` in
  `.loop.toml`; `scripts/loop-kit-sync.sh --check` fails when they drift, and
  `scripts/loop-kit-sync.sh` brings them up to the kit's tag. Change them in the kit, not here.

## Project rules

This repository is the ticket loop itself: the scripts, the prompts, the templates, and the
installer that other projects copy from a tag. It is a bash project — nothing is compiled — and
since the kit's own work is ticketed here (decision 0001), it is also the loop's first user.

### Layout

- `scripts/*.sh` is the shipping surface. Every script is bash that stays within bash 3.2
  (macOS's system bash: no `declare -A`, no `mapfile`, no `${var,,}`) and carries a
  `--self-test` that proves it against a fixture repository it builds in a temporary directory.
  `scripts/loop-config.sh` reads `.loop.toml`; every other script takes its project-specific
  values from it and names no branch, path, or build command of a project.
- `prompts/*.md` are what an agent follows: `next-ticket`, `grill-me`, `grill-project`,
  `review-prs`. A prompt carries its rules as phrases, and `scripts/prompt-check.sh` fails when
  one loses a phrase that states a rule.
- `templates/` is what a project receives: `decision.md` and the per-stack check and CI
  skeletons (`templates/check/*.sh`, `templates/ci/*.yml`). `commands/*.md` are the wrappers a
  harness with slash commands installs.
- `check.sh` sits at the repository root on purpose, so `install.sh` never copies it over a
  project's own `scripts/check.sh`. `install.sh` copies everything else and never overwrites a
  project's `AGENTS.md`, `CLAUDE.md`, `.loop.toml`, or workflow.
- `ci/` holds the workflow skeleton and `ruleset.json`, the branch ruleset a project applies.
- `BACKLOG.md` is this project's executable queue, `docs/PRODUCT_BACKLOG.md` its stories, and
  `docs/decisions/` its records (index in its `README.md`; cite a record by number and never
  restate one in a doc or a ticket).

### Build, run, restart

Nothing is built and no service runs. `./check.sh` is both the build and the test. A change to
`scripts/*.sh` reaches a project only when it is tagged and that project's `kit_ref` moves;
until then `scripts/loop-kit-sync.sh --check` fails there, which is the intended signal.

### The check

`./check.sh` is the definition of done, and CI runs the same script: every script's `--self-test`
in a fixed order, then `scripts/prompt-check.sh` (a prompt may not lose a rule), then
`./install.sh --self-test`, which installs into a fresh repository and runs the installed
scripts' self-tests there. There is no fast variant — the whole thing takes about three minutes
on a laptop, under a minute on CI. Most of it is that self-test suite, which the install runs once
and then proves the six stack skeletons' own stack steps separately, rather than paying for the
suite once per skeleton (LK-11). Nothing is resolved from a worktree, since there is nothing to
build. `scripts/decisions.sh --check` is not wired in yet (LK-05).

### Conventions

- **A new script is not done until it is wired in.** Add it to the list in `check.sh`, to
  `install.sh`'s self-test, and to `templates/check/common.sh`, or its `--self-test` never runs
  in the kit or in any project. `install.sh` copies `scripts/*.sh` by glob, so nothing else there
  needs changing.
- **`scripts/*.sh` is the only thing that ships.** `scripts/loop-kit-sync.sh` and `install.sh`
  both glob that extension, so a helper in another language, or a fixture directory beside the
  scripts, silently never reaches a project (decision 0002). A fixture a self-test needs is
  written into a temporary directory by the test itself.
- **Nothing here writes to a project's default branch, and nothing here commits.** The scripts
  print and the agent or the owner commits: `scripts/open-ticket-pr.sh` pushes a `ticket/<id>`
  branch, and `scripts/sprint.sh` and the terminal UI edit the working tree only (decision 0003).
- **`--self-test` is the proof.** A change with no fixture behind it has not met its done line;
  the exception is a commit body line `No new test: <reason>`.
- **A prompt changes with its phrases.** Editing a rule out of a prompt fails
  `scripts/prompt-check.sh`, and a prompt's change also wants a recorded real run in its pull
  request.

### Docs to keep current

`README.md` — the kit's inventory, whose table names every script — and this file, when the
loop's rules change.
