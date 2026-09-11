# The ticket loop

A small kit that lets coding agents work a backlog of tickets to done, one commit per ticket,
handed off through pull requests that merge on their own when CI is green. It is written for
no particular model or harness: the instructions live in `AGENTS.md`, the prompts are plain
Markdown, and every project-specific value sits in one settings file, `.loop.toml`.

The only hosting assumption is GitHub: the hand-off uses `gh`, and merges are gated with a
branch ruleset and auto-merge. Everything else is bash, git, and perl.

## What is in the kit

| Path | What it is |
| --- | --- |
| `scripts/loop-config.sh` | reads `.loop.toml` (`<key>`, `--all`), with defaults |
| `scripts/backlog-status.sh` | ticket states derived from git; `--next` names the next ticket |
| `scripts/open-ticket-pr.sh` | claims (`--claim`), opens the PR, applies the merge policy |
| `scripts/release-notes.sh` | what shipped between two refs; `--archive` into `CHANGELOG.md` |
| `scripts/loop-kit-sync.sh` | keeps a project's copies of these files in step with the kit |
| `scripts/proof-gate.sh` | fails a change to code that brings no change to a test, fixture, or check |
| `scripts/coverage-ratchet.sh` | fails when the project's coverage figure is below the committed floor; `--set` raises the floor |
| `scripts/review-status.sh` | lists pull requests awaiting the agent review (`--pending`) and posts its verdict as a commit status |
| `prompts/review-prs.md` | the prompt that reviews pending pull requests against their ticket and the Project rules |
| `prompts/next-ticket.md` | the prompt that takes the next ticket to done |
| `prompts/grill-me.md` | the prompt that turns a loose idea into stories and tickets |
| `AGENTS.md` | the standing instructions: the loop section, then an empty Project rules |
| `loop.toml.example` | a `.loop.toml` to copy and fill in |
| `ci/workflow.yml` | a workflow skeleton: one job per check command |
| `ci/ruleset.json` | the branch ruleset that makes merges wait for green, up-to-date CI |
| `commands/*.md` | two-line wrappers for a harness with slash commands |
| `install.sh` | copies all of the above into a checkout and says what is still missing |
| `check.sh` | the kit's own check: every self-test, then an install into a fresh repository |

Every script has a `--self-test`; a project's check runs them, and `./check.sh` here runs
them all plus the install (CI runs the same script).

## How the loop works

- **Tickets** live in a Markdown file (`BACKLOG.md` by default). A ticket is a heading
  `### <ID> <title>`, a paragraph of intent, and a **Done when** line naming the test,
  fixture, or measurable output that proves it. Ids are `<PREFIX>-<number>`.
- **Git is the record of done.** A ticket is done when a commit whose subject starts with its
  id is on the default branch. The file carries only claims: `doing` and `blocked <reason>`.
- **Claims** are `ticket/<id>` branches on origin. `--next` passes over claimed ids, so
  several agents can hold several tickets.
- **Hand-off** is a pull request from that branch. A green PR that is up to date with the
  default branch merges on its own; one that touches a `review_paths` entry is labelled
  `needs-review` and waits for a person.
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

## Installing it in a project

```bash
git clone https://github.com/FueledByChai/coding-agent-loop /tmp/loop-kit
/tmp/loop-kit/install.sh /path/to/your/checkout [--commands <dir>]
```

`install.sh` copies the scripts into `scripts/`, the prompts into `loop/prompts/`, writes
`AGENTS.md` and `.loop.toml` when they do not exist (it never overwrites either), puts the
workflow skeleton at `.github/workflows/loop.yml` when there is no workflow yet, and, with
`--commands <dir>`, writes the three wrappers into the harness's command directory. Then it
prints what the project still has to supply:

1. `scripts/check.sh`: the definition of done, exit non-zero on anything not shippable. The
   kit does not know how to build or test your code. Have it run the loop self-tests too.
2. Optionally a deploy script, if a merged PR should reach a running service on its own.
3. The branch ruleset, applied once with `gh api` (see `ci/ruleset.json` and the commands
   below); repository settings that allow auto-merge and delete merged branches.
4. The **Project rules** section of `AGENTS.md`: what never to touch, build and run commands,
   conventions the prompts should follow.

The repository settings and ruleset, as `gh` commands (edit the job name in the JSON to match
your workflow):

```bash
gh api -X PATCH repos/<owner>/<repo> -F allow_auto_merge=true -F delete_branch_on_merge=true \
  -F allow_merge_commit=false -F allow_squash_merge=false -F allow_rebase_merge=true
gh api -X POST repos/<owner>/<repo>/rulesets --input ci/ruleset.json
```

GitHub's merge queue is not available on user-owned repositories; the ruleset's "up to date
with the default branch" requirement plus auto-merge gives the same one-at-a-time guarantee.

## Keeping a project in step

Set `kit` in the project's `.loop.toml` to this repository's URL and `kit_ref` to a tag.
`scripts/loop-kit-sync.sh --check` fails when any copied file differs from that tag, and
`scripts/loop-kit-sync.sh` copies the tag's files in. Run the check from the project's check
script so drift shows up as a failing build. A project that carries the kit's source inside
its own tree names that directory instead of a URL.

## Running an agent

Point the agent at `AGENTS.md` and at `loop/prompts/next-ticket.md`; a harness with slash
commands gets the wrappers from `commands/`. The prompt claims a ticket, works it in a
worktree, runs the fast and full checks, commits with the ticket id and (when
`trailer_required` is on) a `Co-Authored-By` trailer naming the agent and model, and opens the
PR. `loop/prompts/grill-me.md` is the other prompt: it interrogates a loose idea and drafts
stories, acceptance criteria, and tickets for the owner to confirm.

## Licence

Use it under the licence of the repository it ships in.
