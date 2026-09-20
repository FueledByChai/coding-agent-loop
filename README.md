# The ticket loop

A small kit that lets coding agents work a backlog of tickets to done, one commit per ticket,
handed off through pull requests that merge on their own when CI is green. It is written for
no particular model or harness: the instructions live in `AGENTS.md`, the prompts are plain
Markdown, and every project-specific value sits in one settings file, `.loop.toml`.

The only hosting assumption is GitHub: the hand-off uses `gh`, and merges are gated with a
branch ruleset and auto-merge. Everything else is bash, git, perl, and the few `scripts/*.py`
helpers a stack needs — a JaCoCo coverage figure today, the Beads import path next.

## What is in the kit

| Path | What it is |
| --- | --- |
| `scripts/loop-config.sh` | reads `.loop.toml` (`<key>`, `--all`), with defaults |
| `scripts/backlog-status.sh` | ticket states derived from git; `--next` names the next ticket; `--open`, `--show <id>`, `--stories`, `--sprint` are the views; `--plain` gives `--stories` and `--open` as tab-separated fields for a renderer; `--sprint-check` fails when the sprint and the open tickets disagree |
| `scripts/sprint.sh` | edits the sprint in Beads: the `sprint_label` label and priorities (`add`, `remove`, `set`, `clear`) |
| `scripts/open-ticket-pr.sh` | claims (`--claim`), opens the PR, applies the merge policy |
| `scripts/release-notes.sh` | what shipped between two refs; `--archive` into `CHANGELOG.md`; `--prefix` narrows either to one ticket prefix |
| `scripts/loop-kit-sync.sh` | keeps a project's copies of these files in step with the kit |
| `scripts/proof-gate.sh` | fails a change to code that brings no change to a test, fixture, or check |
| `scripts/coverage-ratchet.sh` | fails when the project's coverage figure is below the committed floor; `--set` raises the floor |
| `scripts/coverage-percent.py` | prints line coverage from a JaCoCo CSV, for the `coverage` command in `.loop.toml`; refuses an absent or unmeasured report |
| `scripts/review-status.sh` | lists pull requests awaiting the agent review (`--pending`) and posts its verdict as a commit status |
| `scripts/decisions.sh` | decision records: `new "<title>" [--supersedes NNNN]`, `index`, `--check` |
| `scripts/prompt-check.sh` | fails when a prompt no longer carries a phrase that states one of its rules |
| `scripts/check-list.sh` | fails when two places that run or describe the same checks disagree — the kit's `check.sh` and a project's `templates/check/common.sh`, or a prose section and the script it describes (`--section`) — naming the check only one of them has |
| `scripts/ruleset-check.sh` | fails when a ruleset requires a status check the workflow it pairs with never reports |
| `scripts/merge-queue.sh` | shadow merge queue: observe, scan GitHub read-only, enqueue, plan, and simulate fenced worker leases; never runs CI or merges |
| `scripts/merge-queue.py` | Python 3.9+ standard-library SQLite execution journal and read-only GitHub adapter |
| `scripts/merge-queue-tests.py` | synthetic race, persistence, invalidation, and CLI fixtures, run by `merge-queue.sh --self-test` |
| `scripts/pr-readiness.sh` | the six facts a merge waits on for every open pull request — the project's check ran on the head, no review conversation is unresolved, no changes are requested, the agent review's status is success, the branch is current and clean, and the branch and subject name one claimed Beads ticket; `--pr <number>` judges one, `--ready` lists the ones that pass all six |
| `scripts/reference-check.sh` | the queue's own references: every ticket carries acceptance criteria, every `blocks` dependency and `story:` label resolves, no dependency cycle, and every decision cited is a record; another project's ids quoted in prose are left alone |
| `scripts/with-test-postgres.sh` | runs a command against a disposable PostgreSQL: a uniquely named container, two ownership labels, the connection URL in the environment (`test_db_*` in `.loop.toml`), and a cleanup that removes only the container it created |
| `scripts/compose-smoke.sh` | starts the project's Compose stack under a name of its own (`compose_files`), waits for it to be healthy, runs `compose_proof` against it with `COMPOSE_PROJECT_NAME` and `COMPOSE_FILE` exported, and takes that stack down with its volumes — printing its logs first when anything failed |
| `templates/decision.md` | the decision record: Context, Decision, Alternatives, Consequences, what would show it was wrong |
| `prompts/review-prs.md` | the prompt that reviews pending pull requests against their ticket and the Project rules |
| `prompts/next-ticket.md` | the prompt that takes the next ticket to done |
| `prompts/grill-me.md` | the prompt that turns a loose idea into stories and tickets, with a text wireframe for every story that touches a screen |
| `prompts/grill-project.md` | the first-day interview: Project rules, decision records, first epics, and a check skeleton |
| `templates/check/*.sh` | check skeletons per stack (Rust, Python, Node, Java, Go, other) that pass on an empty repository |
| `templates/ci/*.yml` | the CI toolchain steps per stack that grill-project splices into the workflow |
| `AGENTS.md` | the standing instructions: the loop section, then an empty Project rules |
| `loop.toml.example` | the settings documentation: `install.sh` writes `.loop.toml` from it once, and `loop-kit-sync.sh` keeps the example itself current in the project (LK-19) |
| `ci/workflow.yml` | the workflow a project installs: one job per check command |
| `ci/ruleset.json` | the branch ruleset that pairs with it, requiring the job that workflow reports |
| `.github/workflows/ci.yml`, `.github/ruleset.json` | this repository's own pair, requiring `Check (check.sh)` and `Agent review` |
| `commands/*.md` | two-line wrappers for a harness with slash commands |
| `skills/*/SKILL.md` | the same pointer with the frontmatter a harness needs to load it, one per prompt; `--skills <dir>` installs them and refuses one that restates its prompt |
| `install.sh` | copies all of the above into a checkout and says what is still missing |
| `check.sh` | the kit's own check: every self-test, then an install into a fresh repository |

Every script has a `--self-test`; a project's check runs them, and `./check.sh` here runs
them all plus the install (CI runs the same script). It takes about eight minutes on a laptop.
Most of that is the loop's suite, which the install self-test runs once and proves the six stack
skeletons' own stack steps separately, instead of running the whole suite once per skeleton
(LK-11).

## How the loop works

- **Tickets** live in Beads (`bd`), a hard dependency: an issue whose id is `<PREFIX>-<suffix>`,
  a number until the prefix's numeric space is spent and the alphanumeric id Beads mints after
  that (`LK-1af`), with a paragraph of intent in `description`, a **Done when** line in
  `acceptance_criteria` naming the test, fixture, or measurable output that proves it, blockers
  as `blocks` dependencies, and `section:`/`story:` labels. The queue is the Dolt database in
  `.beads`,
  synced through the `refs/dolt/data` ref (`bd dolt push`, `bd bootstrap` on a fresh clone, and
  the CI workflow bootstraps it).
- **Git is the record of done.** A ticket is done when a commit whose subject starts with its
  id is on the default branch; a ticket Beads says is `closed` with no naming commit is a false
  close, and a landed commit naming a ticket Beads still has open is an orphan, and
  `scripts/backlog-status.sh --reconcile` fails both (0012).
- **Claims** are `bd update <id> --claim`, with the `ticket/<id>` branch on origin beside them.
  `--next` passes over claimed tickets, so several agents can hold several tickets.
- **The sprint** is the Beads label named by `sprint_label` in `.loop.toml` (`sprint` by
  default), ordered by priority then id: `--next` takes the first ready labelled ticket before
  the rest, `--sprint` shows their states, and `scripts/sprint.sh add|remove|set|clear` edits the
  label. A project may mean either of two things by it: the tickets chosen for now, so what is
  not labelled is the pick list `--open` prints, or **every open ticket**, so an omission is a
  fault. This repository means the second, and runs `scripts/backlog-status.sh --sprint-check`
  from `./check.sh`, which fails naming an open ticket without the label (LK-15).
- **Stories** live in the product backlog (`stories` in `.loop.toml`, `docs/PRODUCT_BACKLOG.md`
  by default) as `### BT-nnn — <title>` with acceptance criteria; a ticket says which it serves
  with a `story:BT-nnn` label. Stories are product intent, not tickets. `--stories` derives each
  story's status from git (done when every serving ticket landed, open k/n, unticketed), `--open`
  is the pick list for the next sprint where the sprint is a subset, and `--show <id>` prints a
  ticket or a story in full.
- **Hand-off** is a pull request from that branch. A green PR that is up to date with the
  default branch merges on its own; one that touches a `review_paths` entry is labelled
  `needs-review` and waits for a person. With several agents at once, each merge leaves the
  other PRs behind the default branch: `scripts/open-ticket-pr.sh --update-all` rebases them,
  and the review pass runs it first, so parallel lanes drain without a hand on the wheel.
- **Done** means the project's check passes and the commit carries the proof. The check is
  the project's own script; CI runs the same script.
- **The proof gate** makes "carries the proof" a check: with `code_paths`, `proof_paths`, and
  `proof_pattern` set in `.loop.toml`, `scripts/proof-gate.sh` fails when a code file changed
  and no proof path changed and no added line in a code file matches the pattern (`"#\\[test\\]"` for Rust,
  `"@Test"` for Java, `"def test_"` for Python; a backslash in a TOML string is written `\\`). A commit body line `No new test: <reason>` lets
  a change through and prints the reason. It judges the working tree, uncommitted and
  untracked files included, against where the branch left the default branch, so a check run
  before the commit exercises it. Run it from the project's check; in CI the checkout needs
  the default branch fetched (`fetch-depth: 0`, or a fetch of that branch) for the diff.
  `scripts/proof-gate.sh --code-changed` is the query on its own (exit 1 when no code path
  changed), so a check can skip work only code can move, such as the coverage ratchet, on a
  docs-only branch.
- **The coverage ratchet** keeps the test suite from eroding: `coverage` in `.loop.toml` is
  a command whose output ends in one percentage (cargo-llvm-cov, JaCoCo, coverage.py, or
  anything else, wrapped to print the figure), and `scripts/coverage-ratchet.sh` fails when
  that figure is below the number in `coverage_floor` (default `coverage-floor.txt`, committed).
  Above the floor it passes and names the new floor; the ticket that raised coverage records it
  with `--set` in the same commit, so the floor only moves up. `coverage_slack` (default 0)
  absorbs run-to-run jitter: a measurement within the slack below the floor passes, and a
  raise is suggested only when it clears the floor by more than the slack.
  For JaCoCo the kit ships the figure itself: `coverage = "python3 scripts/coverage-percent.py"`
  reads `target/site/jacoco/jacoco.csv` (or the CSV path you give it), and refuses a report with
  no executable lines rather than printing the `0.00` a `0/0` would produce.

## Deciding things once

An architecture or product decision is not a story and not a ticket: it is a choice with
alternatives, a reason, and consequences, and it needs writing down once where every later
story and every agent can cite it. `scripts/decisions.sh new "<title>"` creates the next
numbered record in the decisions directory (`decisions` in `.loop.toml`, `docs/decisions` by
default) from `templates/decision.md`; the record is never edited in place, a change is a new
record with `--supersedes NNNN`, and `index` keeps `README.md` there listing them. `--check`
fails when a record lacks a section or the index is out of step; run it from the project's
check. `prompts/grill-me.md` reads the index before asking anything, stops to write a record
when a story implies a decision none covers, asks which wins when a story contradicts one,
and cites the records in every ticket.

A prompt cannot be unit-tested, so its rules are asserted instead: `scripts/prompt-check.sh`
fails when a prompt no longer contains a phrase that states one of its rules ("at least three
rounds", "docs/decisions", "superseding", ...). The other half of a prompt's proof is a recorded
real run in the pull request that changed it.

## Reviewing pull requests

A green build is not a review. `prompts/review-prs.md` has an agent review every open pull
request whose head commit carries no review status yet: it reads the ticket the title names
(its done line), the diff, and the Project rules, posts one review comment with its findings,
and posts a commit status (`review_context` in `.loop.toml`, default `Agent review`) through
`scripts/review-status.sh`. The status is red only for a missing proof, an unmet done line,
a Project-rules breach, or a defect named with file and line; everything else is a comment.
Add the context to the branch ruleset's required status checks and auto-merge waits for it.
Run the prompt from a schedule on a machine with the owner's agent subscription (every ten
minutes is plenty): each head is reviewed once, a new push gets a fresh review, and no API
key has to live on GitHub.

When the review is wrong, the owner overrides it with a reason, which is recorded in the
status and its history:

```bash
scripts/review-status.sh <sha> pass "override: <reason>"
```

`--pending` shows what is waiting; `gh api repos/<owner>/<repo>/commits/<sha>/status` shows
what was posted.

## Starting a project

On a new repository run `install.sh`, then the `grill-project` prompt. It interviews you in
five rounds, one area each (who and where; the data; runtime and deploy; the UI;
non-negotiables), and each area ends in a decision record or a dated deferral, never a guess.
Then it writes the Project rules section of `AGENTS.md`, the records, a product backlog with
the first epics, the Beads queue with a first ticket, `.loop.toml`, and `scripts/check.sh`
from the skeleton for your stack under `templates/check/` (Rust, Python, Node or TypeScript,
Java with Maven or Gradle, Go; anything else gets a skeleton of TODO lines). The skeletons run
the loop's own checks first and skip the stack steps until the manifest exists, so the check
is green on day one and starts failing as code arrives. The workflow gets the stack's
toolchain steps from `templates/ci/` the same way, so the first real ticket does not fail in
CI for want of a toolchain. After that, `/next-ticket` works.

## Installing it in a project

```bash
git clone https://github.com/FueledByChai/coding-agent-loop /tmp/loop-kit
/tmp/loop-kit/install.sh /path/to/your/checkout [--commands <dir>] [--skills <dir>]
```

`install.sh` copies the scripts into `scripts/`, the prompts into `loop/prompts/`, and
`loop.toml.example` to the root, writes `AGENTS.md` and `.loop.toml` when they do not exist (it
never overwrites either), puts the workflow skeleton at `.github/workflows/loop.yml` and the
ruleset that pairs with it at `ci/ruleset.json` when neither is there, and, with
`--commands <dir>`, writes the four wrappers into the harness's command directory. With
`--skills <dir>` it writes one `SKILL.md` per prompt
into the harness's skill directory, each in its own folder. A skill is the same pointer a wrapper
is — frontmatter, then the sentence naming `loop/prompts/<name>.md` — so a prompt edit leaves no
skill behind to go stale, and the install refuses a skill whose body restates its prompt rather
than copying it (LK-18). The example is the one file that sits beside a copy of itself: `.loop.toml`
is written from it once and is the project's own, while the example is the kit's and is refreshed by
every install and by `loop-kit-sync.sh`, so what a project reads to learn what a setting means does
not go stale (LK-19). `CLAUDE.md` is written as the one line `@AGENTS.md` when absent: Codex
reads `AGENTS.md` on its own, Claude Code reads `CLAUDE.md`, and both then follow the same file.
Then it prints what the project still has to supply:

1. `scripts/check.sh`: the definition of done, exit non-zero on anything not shippable. The
   kit does not know how to build or test your code. Have it run the loop self-tests too.
2. Optionally a deploy script, if a merged PR should reach a running service on its own.
3. The branch ruleset, applied once with `gh api` (the installed `ci/ruleset.json` and the
   commands below); repository settings that allow auto-merge and delete merged branches.
4. The **Project rules** section of `AGENTS.md`: what never to touch, build and run commands,
   conventions the prompts should follow.

The repository settings and ruleset, as `gh` commands (edit the job name in the JSON to match
your workflow):

```bash
gh api -X PATCH repos/<owner>/<repo> -F allow_auto_merge=true -F delete_branch_on_merge=true \
  -F allow_merge_commit=false -F allow_squash_merge=false -F allow_rebase_merge=true
gh api -X POST repos/<owner>/<repo>/rulesets --input ci/ruleset.json
```

A required status check is satisfied by a check run of that name and no other, so a context the
workflow never reports holds every pull request forever while every other check is green. Name
the pair in the project's check — `scripts/ruleset-check.sh <ruleset.json> <workflow.yml>` — and
a ruleset asking for a job nobody runs fails the build instead of the merge queue.

GitHub's merge queue is not available on user-owned repositories; the ruleset's "up to date
with the default branch" requirement plus auto-merge gives the same one-at-a-time guarantee.

## Keeping a project in step

Set `kit` in the project's `.loop.toml` to this repository's URL and `kit_ref` to a tag.
`scripts/loop-kit-sync.sh --check` fails when any copied file differs from that tag, and
`scripts/loop-kit-sync.sh` copies the tag's files in. Run the check from the project's check
script so drift shows up as a failing build. `loop.toml.example` is one of the files it keeps in
step — not `.loop.toml`, which is the project's own, but the example beside it, so the settings
documentation a project reads is the current one (LK-19). A project that carries the kit's source
inside its own tree names that directory instead of a URL.

## Running an agent

Point the agent at `AGENTS.md` and at `loop/prompts/next-ticket.md`; a harness with slash
commands gets the wrappers from `commands/`, and one that loads skills gets a `SKILL.md` pointer
per prompt from `skills/` (`install.sh --skills <dir>`). The prompt claims a ticket, works it in
a worktree, runs the fast and full checks, commits with the ticket id and (when
`trailer_required` is on) a `Co-Authored-By` trailer naming the agent and model, and opens the
PR. `loop/prompts/grill-me.md` is the other prompt: it interrogates a loose idea and drafts
stories, acceptance criteria, and tickets for the owner to confirm.

## Licence

Use it under the licence of the repository it ships in.

## Merge queue (shadow)

Decision 0016 introduces the queue foundation. It is **shadow-only**: no command rebases a
branch, asks for review, starts CI, posts a status, resolves a conversation, or merges a PR.
Existing merge policy and workflows remain in force. A successful simulation is not GitHub
merge authorization. GitHub App gating, author/acceptance workers, CI dispatch, queue-aware
prompts, and service supervision are subsequent work; installing this script does not enable them.

Use Python 3.9 or later, `gh` with read access, and the checkout's Beads database. Keep the
SQLite journal outside Git. Every output identifies itself as `mode: shadow` (the event log
contains only shadow journal events). The same journal can hold several repositories/bases.
`LOOP_ROOT` selects the checkout whose `.loop.toml` and Beads database are read; its configured
`default_branch` supplies the base unless `--base` is explicit. `--repo` is required for scan
and local queue commands, so even a failed provider lookup identifies the queue to hold. Scan
verifies the GitHub repository matches that checkout before reading its tickets. Use the same
repository spelling consistently for the shadow journal's keys.

```bash
scripts/merge-queue.sh --db "$HOME/.local/state/coding-agent-loop/shadow.sqlite" \
  --repo OWNER/REPO scan
scripts/merge-queue.sh --db "$HOME/.local/state/coding-agent-loop/shadow.sqlite" \
  --repo OWNER/REPO enqueue 123 --head FULL_HEAD_SHA
scripts/merge-queue.sh --db "$HOME/.local/state/coding-agent-loop/shadow.sqlite" \
  --repo OWNER/REPO plan
scripts/merge-queue.sh --self-test
```

`scan` makes paginated GET requests plus a read-only GraphQL query for every review-thread
page. It rechecks each head and the base before recording a complete observation. It records
missing reviews and unknown mergeability as blockers. It reads completed review objects from
the exact Codex bot on the full head SHA; clean-summary-only reviews currently remain
unverified. It deliberately does **not** infer acceptance from the legacy `Agent review`
status, populate dependency approvals, or manufacture acceptance evidence. Consequently live
PRs stay blocked until the trusted acceptance/dependency adapters exist. API failures hold the
queue; observations expire after 120 seconds. `scan` is one pass, not a background service.

For offline simulation, `observe snapshot.json` imports a complete observation, using the
schema shown by `snapshot()` and `candidate()` in `scripts/merge-queue-tests.py`. Imported
observations are explicitly untrusted simulation input. Never feed this journal to a live
merge gate. `enqueue` requires the observed full head; repeated requests preserve the original
FIFO position. Eligible entries are considered in that order, skipping blocked entries.
Dependencies must be observed as `MERGED`; absent or merely closed PRs cannot unblock them.

`claim --owner WORKER [--ttl SECONDS]` acquires one shadow promotion slot per repository/base.
`renew --owner WORKER --token TOKEN` keeps a still-valid attempt alive. `release --owner WORKER
--token TOKEN --reason RECONCILIATION` records that an attempt is stopped and reconciled before
another can be selected. `status`/`plan` expose the active token and blockers; `events` gives the
audit history. These operations affect only the local shadow journal.

Claims use a database transaction and unique active-slot index. Every attempt gets a new,
monotonically increasing token; old workers cannot renew or release a newer attempt. Changed
head/review/acceptance data, a different base, or a failed scan permanently invalidates the
current token without freeing its slot. Lease expiry does not imply the old worker stopped:
expired attempts need explicit reconciliation and release, even after restarting the process.
Duplicate and older observations cannot roll state back. Queue state is operational data;
Beads remains the durable task tracker. Neither the journal nor a label is a merge credential.
