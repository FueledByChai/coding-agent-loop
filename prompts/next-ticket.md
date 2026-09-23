Work the next ticket in the queue to done, autonomously, following the standing instructions
in `AGENTS.md` (the loop section and the Project rules).

The queue is Beads (`bd`), so `bd` is a hard dependency. Settings come from `.loop.toml`:
`scripts/loop-config.sh` names `check_fast` (the check to run while iterating), `check` (the full
check), `default_branch` (the branch pull requests target), `sprint_label` (the Beads label that
marks the sprint) and `trailer_required` (whether commits sign with an agent trailer).

Before changing a pull-request gate, inspect the entire retained `AGENTS.md` contract, including
both its shared loop section and Project rules. If that contract mentions queue rollout or a
controller and does not explicitly declare either staged/legacy operation or `github-v1` as the
active profile, stop before mutating gates and update the project's migration decision and
standing contract before using this prompt. Do not infer activation from installed queue files.

In the operator-enabled github-v1 profile, skip legacy coordination bootstrap in step 1;
keep the normal Beads ticket and Git branch claims. Follow `respond-to-review.md` to nominate
reviewed work and verify App selection before a refresh. The App owns selection, CI admission
and merging; hand off to the independent reviewer without creating or claiming a legacy coordinator.

Steps:

1. Refresh shared Beads state with `bd dolt pull`; resolve any synchronization failure before
   claiming or publishing work. Run `scripts/backlog-status.sh --next`. It names the first ready ticket whose blockers have a
   commit on the default branch, taking the tickets carrying the `sprint_label` first, by priority
   then id, then the rest (`scripts/backlog-status.sh` shows every ticket's derived state;
   `--sprint` shows the sprint's). If it names none, report that and stop. Read the ticket with
   `bd show <id> --json` - its `acceptance_criteria` is the **Done when** line. Before claiming,
   save the prior status/assignee and successfully inspect `git ls-remote --heads origin
   refs/heads/ticket/<id>`. If a branch already exists, reconcile its owner rather than acquiring
   another claim; a remote-read failure also stops claiming. Then claim it with
   `bd update <id> --claim` (the claim the queue honours), publish it with `bd dolt push`,
   then run `scripts/open-ticket-pr.sh <id> --claim`, which pushes `ticket/<id>` to origin and
   refuses when another checkout holds it. If the Git claim fails after a newly acquired Beads
   claim, stop work and roll back only this attempt's Beads claim: pull shared state, verify
   ownership, then use `bd update <id> --if-assignee "<this actor>" --if-status in_progress
   --assignee "" --status "<prior status>"` and `bd dolt push`. Never clear a pre-existing claim,
   overwrite a different owner, or delete an existing remote branch. A failed conditional
   update or rollback publication is an explicit reconciliation blocker; report the actual
   branch/claim state and responsible actor rather than leaving a silent published claim.
   In legacy mode, read the merge order recorded in the coordinating Beads ticket's notes and the named
   coordinator's current selection (0019 in the kit). Ticket claim order is implementation
   scheduling, not merge admission. A shadow plan is not admission. If selection is missing or
   ambiguous, leave admission pending with that coordinator; do not select yourself.
   In legacy mode only, for a standalone, existing or first-project ticket with no coordination link, bootstrap
   coordination before handoff: search `bd list --label loop:coordination --limit 0 --json`
   for this repository and configured base. Reuse the matching active record; if none exists,
   create `bd create "Merge coordination: <repo/base>" --type epic --labels loop:coordination
   --description "<repo/base, ticket, proposed order; selected=none; coordinator=next independent
   review-prs run>"`. Link its id in the ticket's notes and later the PR body. Existing orders
   stay authoritative; propose adding this ticket rather than overwriting the order. Multiple
   conflicting records need reconciliation by the coordinator before admission. With no prior
   order, propose dependency-respecting PR creation order (PR number breaks ties), or this
   ticket alone when no other PR exists. Hand off the record id explicitly to `review-prs`;
   that independent run claims and records coordination before selecting a candidate. This
   supplies a discoverable handoff even when no interview ran; it does not let the author admit
   itself. If no review runner is configured, name `review-prs` and the record id as the next
   invocation needed, rather than waiting for a nonexistent coordinator. Refresh with
   `bd dolt pull` before coordination discovery or later shared-state decisions, and publish
   each creation, ticket link, order or ownership update with `bd dolt push` before handing it
   to another actor. A failed pull/push or unresolved merge conflict leaves admission blocked;
   reconcile the shared record before retrying rather than creating another local-only epic.
2. Read the ticket's **Done when** line first. Decide what test, fixture, or output proves it, and
   write that test before the implementation.
3. Work in an isolated worktree when the harness offers one; otherwise on a branch named after the
   ticket id. Keep the change to that ticket. Anything else you notice becomes a new ticket with
   `bd create` - a paragraph of context, its acceptance criteria in `--acceptance`, its blockers as
   `--deps blocked-by:<id>`, a `section:` label, and the sprint label when it belongs in the sprint.
4. Implement. Run the fast check while iterating and the full check before committing. Fix
   failures yourself. If the full check still fails after three distinct attempts, set the ticket
   to blocked with what fails and what you tried (`bd update <id> --status blocked --append-notes
   "<what fails and what you tried>"`) and stop.
5. Commit with the ticket id first in the subject, a body that says what changed and how the done
   line is proven, and, when the config requires it, a `Co-Authored-By: <agent> <email>` trailer
   naming the agent and model that did the work. Then follow the Project rules' pull-request
   procedure (`--body-file` gives a fuller report than the commit body). When the Project rules
   declare the live App controller active, use `scripts/open-ticket-pr.sh <id> --draft`, verify
   auto-merge is disabled before `gh pr ready <number>` starts review, and keep it disabled
   through the final gate handoff. During staged rollout or legacy mode, preserve the project's
   complete legacy handoff, including whether the PR opens as draft or ready and whether auto-merge
   is armed; staging queue files alone does not activate the controller. Never push the default
   branch.
   The ticket stays claimed while the work is in flight; once its commit is on the default branch it is done, and it is closed in Beads
   (`bd close <id> --reason ...`) - `scripts/backlog-status.sh --reconcile` fails while a landed
   commit names a ticket Beads still has open. `scripts/release-notes.sh --archive` closes a
   release's shipped tickets too.
6. Continue the author handoff with `loop/prompts/respond-to-review.md` (in the kit itself,
   `prompts/respond-to-review.md`) for this PR. Opening it is not the end of the author's work:
   read the review findings, fix or answer them with evidence, and obtain completed review of
   the resulting head. Keep the ticket claimed through this handoff. Waiting for an independent
   reviewer or queue admission is a named handoff, not permission to declare the PR ready.
   In particular, waiting PRs do not rebase or request CI. Required local implementation checks
   still run; review repairs and independent acceptance can proceed while waiting. Only the
   selected candidate, after its predecessors have actually merged and their commits landed,
   may use the project's sanctioned refresh procedure. Never batch-refresh the waiting PRs.
   A changed head needs completed Codex review and fresh independent acceptance before the
   legacy coordinator or V1 App controller requests CI. The reviewer/controller rechecks final evidence before the merge
   gate; an earlier acceptance receipt cannot authorize a changed head or base.
7. Finish with a short report: ticket id, the pull request URL, what was built, how it was
   verified, any new tickets added, anything the owner should look at. A green PR that is up to
   date with the default branch merges only after the project's required gates pass; otherwise
   name the next responsible actor and blocker.

Rules: the Project rules in `AGENTS.md` apply throughout (what never to touch, when not to
restart anything, which baselines not to refresh unless the ticket itself changes results, and
then say so in the commit body).
