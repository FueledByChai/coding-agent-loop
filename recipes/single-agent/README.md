# Single-agent delivery

This recipe is the deliberately small alternative to the full ticket loop. It keeps Beads as
the durable backlog and GitHub as the merge gate, but installs no coordinator, merge queue,
review worker, acceptance journal, agent-review status, or kit synchronization.

Use it when one agent needs to ship useful work before the project invests in parallel agents.
The operating limit is one claimed implementation ticket and one open implementation pull
request. A project can add concurrency later without changing its backlog.

## What stays

- The existing Beads database and Dolt remote.
- Product stories, decisions, application source, tests, and deployment safeguards.
- A project-owned `scripts/check.sh` that is the one required CI check.
- Protected `main`, pull requests, rebase merges, and GitHub auto-merge.

## What does not belong in this profile

- A selected-candidate or merge-order record.
- Review or acceptance workers.
- A required AI-review status or mandatory AI-review loop.
- A coordinator or queue deciding which pull request may request CI.
- Repeated full local checks after each edit.
- Copied framework scripts that inspect or synchronize the process itself.

## Install in a new project

1. Initialize or connect Beads and publish its Dolt state.
2. Copy this directory into the project deliberately. The full-loop installer and kit-sync script
   do not install or update `recipes/`; this profile is an alternative, not another full-loop file.
3. Copy `AGENTS.template.md` to `AGENTS.md` and replace the bracketed project rules.
4. Provide an application-owned `scripts/check.sh`. It must run non-interactively and return
   nonzero on failure. Keep targeted local test commands in the project rules.
5. Copy `ci.yml` to `.github/workflows/ci.yml` and add the project's toolchain setup before the
   check step.
6. Create the `ci:run` pull-request label. Apply `ruleset.json` to the default branch and enable repository auto-merge and automatic
   deletion of merged branches.
7. Validate the copied recipe with `./recipes/single-agent/validate.sh` before adapting it.

The ruleset requires only `Check (scripts/check.sh)`. It deliberately does not require review
thread resolution or an `Agent review` status. A project that needs human approval for specific
high-risk paths should state those paths in `AGENTS.md` and withhold auto-merge for those pull
requests. Do not make every ordinary change pay the high-risk path.

## Cut over an existing loop installation

Make the cutover as one repository change, but change external controls in this order:

1. Pause schedulers, merge captains, and review monitors for the repository.
2. Disable auto-merge on obsolete orchestration pull requests and close them unmerged. Preserve
   their branches and Beads history.
3. Replace the branch ruleset with `ruleset.json`; keep pull requests and the application check
   required throughout the transition.
4. Remove installed queue, coordination, review, prompt, kit-sync, and CI-request machinery.
   Never delete `.beads`, its Dolt remote, product stories, decision history, source, or tests.
5. Replace the workflow with `ci.yml` and the standing instructions with
   `AGENTS.template.md`, adapted to the project.
6. Make `scripts/check.sh` application-only. Framework self-tests and backlog reconciliation do
   not belong in the application's definition of done.
7. Open the cutover pull request, complete the one bounded review pass, add `ci:run`, run the one
   required check, and merge it. Close or supersede
   only obsolete framework tickets; leave product tickets untouched.

## Everyday use

The operator can say: `Take the next product ticket and get it merged.` The agent then:

1. Pulls Beads state and finishes any existing claimed ticket or open pull request.
2. Selects one ready product ticket, reads it, claims it, and publishes the claim.
3. Creates `ticket/<id>` from current `origin/main` in an isolated worktree.
4. Implements the acceptance criteria and runs focused local proof.
5. Reviews the diff once, commits, pushes, and opens a ready pull request without starting full CI.
6. Gives the initial Codex review one bounded opportunity, reads every finding once, and batches
   accepted corrections into one push without requesting an ordinary re-review.
7. Brings the branch current, reviews and proves the final diff, then adds `ci:run` to start the
   required full check and enables rebase auto-merge.
8. Verifies the merge, closes the Bead, publishes Beads state, and only then selects more work.

If CI fails, fix the actual failure and push once, then remove and re-add `ci:run` for the new head.
Do not start an unbounded review/re-review cycle. Unrelated label additions are deliberately rejected
before checkout: a skipped required job can incorrectly satisfy protection, so the job must start
and fail closed instead.

## Growing beyond one agent

Add a second agent only after this path is reliably boring. Give each agent a separate worktree
and a disjoint ticket, retain one owner per pull request, and add merge serialization only when
simultaneous green pull requests become a measured problem. The backlog and application check do
not need to change.
