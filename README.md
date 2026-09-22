# The ticket loop

A small kit that lets coding agents work a backlog of tickets to done, one initial commit per ticket,
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
| `scripts/review-workers.sh` | opt-in durable author/acceptance jobs, fresh evidence validation and crash reconciliation; no merge authority |
| `scripts/review-workers.py` | isolated command environments, local process guardian and worker receipt validation |
| `scripts/review-workers-tests.py` | offline concurrency, process crash, timeout, freshness and reply-evidence fixtures |
| `scripts/pr-readiness.sh` | the six facts a merge waits on for every open pull request — the project's check ran on the head, no review conversation is unresolved, no changes are requested, the agent review's status is success, the branch is current and clean, and the branch and subject name one claimed Beads ticket; `--pr <number>` judges one, `--ready` lists the ones that pass all six |
| `scripts/reference-check.sh` | the queue's own references: every ticket carries acceptance criteria, every `blocks` dependency and `story:` label resolves, no dependency cycle, and every decision cited is a record; another project's ids quoted in prose are left alone |
| `scripts/with-test-postgres.sh` | runs a command against a disposable PostgreSQL: a uniquely named container, two ownership labels, the connection URL in the environment (`test_db_*` in `.loop.toml`), and a cleanup that removes only the container it created |
| `scripts/compose-smoke.sh` | starts the project's Compose stack under a name of its own (`compose_files`), waits for it to be healthy, runs `compose_proof` against it with `COMPOSE_PROJECT_NAME` and `COMPOSE_FILE` exported, and takes that stack down with its volumes — printing its logs first when anything failed |
| `templates/decision.md` | the decision record: Context, Decision, Alternatives, Consequences, what would show it was wrong |
| `prompts/review-prs.md` | the prompt that reviews pending pull requests against their ticket and the Project rules |
| `prompts/next-ticket.md` | the prompt that takes the next ticket to done |
| `prompts/respond-to-review.md` | the author's repair, evidence reply and fresh-review handoff for an existing PR |
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
- **Hand-off** is a pull request from that branch, opened as a draft during queue rollout.
  Verify auto-merge is disabled before marking ready for review. Keep required human review
  for `review_paths`. The coordinator records merge order beside the day's tickets in Beads,
  with one selected candidate after predecessors land. Waiting PRs do not rebase or request CI;
  author fixes, Codex review and independent acceptance may proceed. Only the selected candidate
  gets a sanctioned refresh, renewed head review/acceptance, then CI. Never batch-refresh from
  a review pass. Selection and final gates are described in `prompts/review-prs.md` and 0019.
  Standalone and first-project tickets bootstrap a discoverable `loop:coordination` Beads epic;
  the next independent review run claims coordination and selects the candidate, so a missing
  interview plan does not strand the PR. Pull shared Beads state before discovery and push every
  coordination/assessment update before handoff; synchronization failure blocks admission. Planning preferences do not become false implementation
  dependencies. Five independent PRs
  prebuilt and repeatedly refreshed can cost 15 full runs. With existing automatic PR triggers (including this kit repository),
  draft openings still cost five runs and selected refreshes cost four: nine runs, saving six.
  After the separate CI-admission rollout suppresses opening/push runs, the target becomes five
  successful candidate runs, saving ten against the original 15. Genuine failures or code changes
  can add runs. Prompts do not disable those triggers or provide an atomic admission lock.
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

## Requesting full CI

New installations receive the request-only `ci/workflow.yml` skeleton (0020). Opening a PR,
marking it ready, pushing review fixes and merging do not run its full check. Existing workflows,
including this kit repository's own CI, are preserved by the installer and require deliberate
migration. Compare the template with your workflow; retain any unique post-merge deployment or
validation steps instead of deleting them along with a duplicate full build.

The author hands completed head review and proof to the coordinator recorded in Beads. Only
after that coordinator selects this PR, verifies its predecessors landed, and obtains fresh
independent acceptance should it request the full check. Waiting PRs receive no refresh or CI
request. With this skeleton, create the request label once and then add it to the selected PR:

```bash
gh label create ci:run --description "Request full CI for the selected reviewed candidate"
gh pr edit <pr> --add-label ci:run
```

If the label already exists, keep it. Inspect the current head and existing CI run first; adding
an already-present label is not a new request. Reuse an in-progress or successful run for the same
head/base. After a new head has completed review and acceptance, or an explicit failed-run retry
is needed, remove `ci:run` and add it again. Removal itself does not trigger this skeleton.
Verify the requested head and tested commit, actual successful full job and current base before
publishing the final gate. A later push invalidates old evidence and requires a new request.

Every added label starts a lightweight job because GitHub has no label-name trigger filter.
The first step rejects events other than adding `ci:run` to a non-draft PR, before checkout,
toolchain setup or the full check. Unrelated labels therefore produce a failed check and can
replace an earlier green result; avoid label changes after final validation. Re-request only the
selected candidate after checking its evidence. Never add a job-level `if:` to hide these failures:
a skipped required job can satisfy protection without running tests. The ruleset still requires
`Check (scripts/check.sh)`; `scripts/ruleset-check.sh` verifies that job-name pairing, not admission.
See [GitHub's required-check behavior](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks).

This skeleton reduces automatic work; a label is not authorization and it neither serializes
requests nor prevents a user with label permissions from requesting a waiting PR. Keep the
existing independent final gate during bootstrap. LK-e9y supplies trusted queue admission,
duplicate-dispatch handling and the App-issued gate. A plain `workflow_dispatch` replacement
cannot satisfy the current Actions-required context; migrate that context with the App gate.
No live consumer workflow or protection changes merely because the kit template is upgraded.

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

A green build is not a review. `prompts/review-prs.md` independently assesses each PR's proof,
done line, Project rules and concrete defects. Waiting PRs can receive acceptance before CI,
but acceptance is not merge authorization. Durable workers return receipts; a trusted
controller owns the final gate. During the legacy bootstrap, the named coordinator can relay
independent acceptance as `review_context` only for the selected candidate after completed
Codex review, resolved findings, fresh independent acceptance and successful final-head CI.
Keep auto-merge disabled through that handoff. Missing readiness stays unposted, never green.

Review all open PRs and changed evidence, not just heads with no status. Legacy reviewers store
an assessment binding in the coordinating Beads record and reuse it while unchanged, skipping
duplicate comments but still checking final readiness. After posting feedback, they save the
post-comment binding; CI progress alone does not create another acceptance review. New findings or changed
criteria can invalidate acceptance without a push. A scheduled review may assess waiting PRs,
but never runs `scripts/open-ticket-pr.sh --update-all`. Final status publication must recheck
head, base, criteria, reviews and actual CI; the legacy status API cannot atomically fence new
feedback. Decision 0019 replaces the old batch-refresh and immediate passing-status handoff;
the trusted App gate and CI-admission rollout provide enforcement separately. Legacy adoption
also disables existing auto-merge requests and resets old successes within the configured
default-branch lane only; other-base PRs stay untouched and targets are rechecked before mutation; later passes keep every
waiting/unselected PR pending and require a matching final-gate record before retaining success.
Assessment bindings include ticket dependencies and labels. A failed Git claim rolls back only
the newly acquired Beads claim with ownership guards and publishes the recovery.

The author continues with `prompts/respond-to-review.md` after opening the PR. It covers fixes,
supported disputes and separate tickets, keeps unresolved blockers visible, and verifies a
completed review for the resulting full commit. A push alone is not evidence of a Codex review:
the author checks for an existing request/completion and asks with `@codex review` when needed
([official review guidance](https://learn.chatgpt.com/docs/third-party/github)).
An author may resolve a proven fix where project policy permits, but cannot clear its own dispute
or grant itself a passing review status. Decision 0017 records this handoff. The installed
`respond-to-review` command and skill point to the same prompt. This is agent guidance; durable
dispatch, independent acceptance workers and automated enforcement remain separate work under
LS-03. Existing CI triggers and protection are unchanged.

The kit keeps one initial implementation commit per ticket and appends review-fix commits with
the same ticket id after publication (0017). Existing consumers keep their own `AGENTS.md`;
installing the prompt does not silently relax a consumer's stricter commit policy. A consumer
requiring exactly one commit must adopt a documented repair strategy before author automation
can push review fixes there.

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
`--commands <dir>`, writes one wrapper per prompt into the harness's command directory. With
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

## Review workers (opt-in, before CI)

`scripts/review-workers.sh` supplies LK-3pg's author and acceptance execution layer (0018).
It uses a separate private SQLite journal; shadow observations cannot launch workers. `advance`
reads the actual GitHub PR and claimed Beads ticket, selects author work while code review is
pending/has unresolved threads, or independent acceptance after completed code review, and
runs at most one job. It does not select a PR for merge, refresh branches, request CI, post a
required status or merge. Those adapters and unattended service supervision remain LK-e9y.

Provision an operator-owned policy file **outside the checkout**, a private state directory
(mode 0700), and two foreground adapter commands. Example policy (replace these paths):

```json
{
  "revision": "review-workers-v1",
  "timeout": 900,
  "max_attempts": 3,
  "roles": {
    "author": {
      "identity": "author-worker",
      "github_login": "your-author-bot",
      "command": ["/opt/loop/author-adapter"],
      "env": {"HOME": "/var/lib/loop/author", "PATH": "/usr/local/bin:/usr/bin:/bin"}
    },
    "acceptance": {
      "identity": "acceptance-worker",
      "command": ["/opt/loop/acceptance-adapter"],
      "env": {"HOME": "/var/lib/loop/reviewer", "PATH": "/usr/local/bin:/usr/bin:/bin"}
    }
  }
}
```

Adapters read one JSON packet from stdin and emit one JSON receipt on stdout; diagnostics go
to stderr. Every journal command requires `--policy`, including `status`, `show` and
`reconcile`; missing policy is rejected before any Git command or journal initialization.
Supply the same protected isolation policy for observation and cleanup as for dispatch.
The executable entry points pin system interpreters and disable inherited Bash/Python startup hooks
before reading that policy. Isolated observation then uses the policy's protected tools.
`show <job-id>` exposes the snapshot and identity; the private `<job-id>.request.json`
artifact contains role instructions and the exact receipt shape. Author jobs follow the
installed `respond-to-review` prompt. Receipts include the durable job ID, resulting full head,
criteria hash and policy hash. Each open thread needs a disposition and a reply verified through
GitHub against the configured author login and thread root. Fixes must name a published commit
in both the receipt and reply, with proof; disputes and deferrals retain a blocker. Summary-only
findings remain visible in the packet and must also be assessed by the author/reviewer; this
controller does not claim to extract all natural-language defects automatically.

Worker packets and evidence identities include sorted ticket labels and dependency edges
(target id, relationship type and current status). Adding, removing or changing them invalidates
prepared jobs and completed acceptance, and changes during a worker run or either final source
read fail closed. Provider ordering alone does not invalidate evidence. Dependency notes and
timestamps are excluded; the merge coordinator still checks whether blockers have actually landed.

Acceptance runs in a separate detached worktree and a fresh reviewer session, with no author
conversation history. Configure its adapter to enforce read-only execution; the controller also
rejects a changed head or dirty reviewer worktree. Each nonblank line of the ticket criteria has
a stable `cN` identity in the packet, and every line needs concrete evidence covering **all** its
clauses. Structural coverage is checked in code; the independent reviewer judges whether that
evidence proves the requirements. Missing evidence, unclear review, changed head/base/criteria,
new feedback, changed assignee, policy/config changes or implementation changes invalidate a pass.
An author's `handled` receipt is never an acceptance pass.

```bash
scripts/review-workers.sh --root /path/to/project \
  --state /private/loop-workers --policy /private/worker-policy.json \
  advance --repo OWNER/REPO --pr 123 --worktree /path/to/assigned-author-worktree

# Inspect without executing, then resume a queued job explicitly:
scripts/review-workers.sh --root /path/to/project \
  --state /private/loop-workers --policy /private/worker-policy.json \
  prepare --repo OWNER/REPO --pr 123 --role author --worktree /path/to/assigned-author-worktree
scripts/review-workers.sh --root /path/to/project \
  --state /private/loop-workers --policy /private/worker-policy.json run JOB_ID

# Fresh provider reads are mandatory before exposing acceptance evidence:
scripts/review-workers.sh --root /path/to/project \
  --state /private/loop-workers --policy /private/worker-policy.json \
  acceptance --repo OWNER/REPO --pr 123
```

Duplicate prepare/advance requests reuse the durable job; they do not launch another editor.
One active job owns both its PR and worktree. All controllers for a repository must share
one journal. A registration in the Git common directory prevents linked worktrees from
silently switching journals; moving it is an operator migration after all jobs are verified
stopped. Independent clones must also be configured to use that same journal. `status`, `show JOB_ID` and `reconcile JOB_ID` take
`--state` (and `--root` when used outside that project). Reconcile requires the guardian/launcher
lock to be free **and** the recorded process group to have no executing members. Linux groups
containing only zombies count as stopped after two matching `/proc` task inventories; live
threads, changing inventories or unreadable process data retain the slot. It never kills an unknown or
reused PID. Starting without a recorded group is recoverable only after the inherited lock is
free: the guardian records its group before starting an adapter. No lease timeout steals a slot.
After verified stop, reconciliation removes the runtime-owned detached reviewer checkout and
its Git registration, including failed/dirty reviewer trees; journal receipts and log artifacts
remain available. Cleanup failure retains ownership for retry. Author checkouts are retained.
A failed/blocked stopped job needs `--retry "reason"` on prepare/advance, subject to the configured
attempt budget. `run`/`advance` exit nonzero on blocked/failed work; `acceptance` exits nonzero
without current passing evidence. Historical `show` output is not current readiness.

This local runner supports **trusted foreground POSIX adapters** on macOS/Linux. Adapters must
keep all descendants in the inherited process group and must not daemonize or submit detached
remote work. A live descendant retains the slot even after its parent exits. Timeout/output
limits terminate the job's group; release still needs verified stop. A harness that creates
independent sessions, remote jobs or detached tool processes needs a container/provider stop
adapter before unattended use; do not claim a process-group check proves those workers stopped.
The controlled real-model proof in the PR is a bounded fixture run, not production qualification
of an arbitrary agent CLI under crashes.

Only explicitly configured environment variables reach adapters; the controller's environment
is not inherited. Distinct identities/homes describe the intended roles, not an OS security
boundary. The journal and config are trusted operator state, and adapters must not mutate them.
Do not store the future GitHub App merge credential on this worker account or filesystem. Live
merge enforcement needs separate service/OS credentials and a trusted publisher (LK-e9y); no
worker receipt, including imported or manually edited local data, is itself merge authorization.
No global model, login, credential or agent settings are changed by installation.

### Workers under separate OS accounts

Use isolated mode (0022) before granting a worker receipt live gate significance. Keep
one canonical journal, policy and observation clone under the reviewer UID, inaccessible
to the author. The author keeps its own clone/worktrees and credentials. Do not share
writable Git metadata between those accounts. The reviewer never runs Git commands in
an author checkout; it fetches the exact published head into its own mirror for acceptance.

Add the following to the external worker policy (replace all example paths and UIDs):

```json
{
  "read_path": "/opt/queue-tools:/usr/bin",
  "isolation": {
    "author_uid": 1001,
    "reviewer_uid": 1002,
    "bridge_policy": "/etc/queue-workers/author-bridge.json",
    "author_worktrees": {"AB-12": "/srv/queue-author/AB-12"}
  }
}
```

Keep the other policy fields shown above. The configured reviewer UID must run the
worker CLI; root is rejected. Protect the reviewer HOME (0700), mirror, journal, policy
and observation tools through their ancestors. The isolated author's `command` contains
exactly one root-owned executable wrapper, without caller-supplied arguments. The acceptance
role also uses a single root-owned wrapper. Both wrapper bytes and the root-owned bridge
policy contents are included in receipt policy hashes. Its initial
environment is the reviewer's explicit observation environment, not the author's role env.
The wrapper must clear that environment and switch UID before invoking this fixed command:

```sh
/usr/bin/python3 -I /opt/queue-kit/scripts/review-workers.py \
  --policy /etc/queue-workers/author-bridge.json author-bridge
```

The root-owned bridge policy pins the actual adapter and author environment:

```json
{
  "author_uid": 1001,
  "repo": "owner/project",
  "worktrees": {"AB-12": "/srv/queue-author/AB-12"},
  "command": ["/opt/queue-adapters/author"],
  "env": {"HOME": "/srv/queue-author", "PATH": "/opt/author-tools:/usr/bin"}
}
```

The bridge accepts protocol-1 author packets only. It verifies UID, assigned path,
HTTPS origin repository, ticket branch, full starting head and clean worktree under the
**author** identity, then runs the adapter in the inherited guardian process group.
Checkout validation uses the root-owned `/usr/bin/git` executable (including its resolved
target and ancestors) and a clean system environment, so author tool-path shims cannot
forge the validation results. The repair adapter still receives its configured environment.
Validation ignores system/HOME Git configuration, disables fsmonitor, untracked cache and
hooks, pins the actual worktree, and explicitly checks untracked files and submodule changes.
Validation also rejects assume-unchanged and skip-worktree index flags, which can conceal tracked edits.
Isolated mode requires Git 2.36 or later; older versions interpret boolean fsmonitor
settings differently ([Git configuration reference](https://git-scm.com/docs/git-config)).
Configure sudo only for the exact protected command/arguments; never allow an arbitrary
shell or interpreter invocation. Disable PTY/session creation for this fixed command and
prove actual process-group retention on the target host. The kit does not install grants.
A timeout or crash with a surviving author retains ownership until an operator stops it;
`reconcile` must prove stop before releasing. Do not retry by deleting a journal.

The standard `--worktree` argument names the policy-assigned author path for either role;
acceptance ignores its Git metadata and creates its detached tree in private reviewer state.
Registration remains one canonical journal, including any existing author clones after a
stopped migration. Back up and verify the old journal before rebinding; old state is not a
second runnable lane. Changing paths, identities or policy invalidates old receipts.

The normal worker self-test remains unprivileged. A separately requested synthetic OS
proof is available for a host administrator, using existing UIDs and a root-owned parent:

```sh
sudo /usr/bin/python3 -I /opt/queue-kit/scripts/review-workers-tests.py \
  --identity-proof --author-uid 1001 --reviewer-uid 1002 --proof-parent /opt
```

It creates and removes only its own temporary fixture, uses no real credentials or model
calls, makes no GitHub requests and installs no service/sudo grant. It verifies separate
Git metadata, author denial of reviewer state, bridge UID/target checks, duplicate-role
ownership and retention while a different-UID child survives the guardian. This is
component proof; the actual deployment wrapper and live workflow still need LK-e9y proof.
