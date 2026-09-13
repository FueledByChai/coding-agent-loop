# 0003 — The terminal UI edits the working tree and never commits

Status: accepted
Date: 2026-09-13

## Context

The owner asked to be able to add items from the UI (LS-02). Two kinds of item were on the
table: a ticket added to the sprint, which is the `sprint` list in `.loop.toml`, and a brand-new
ticket, which is a block in `BACKLOG.md`. The loop's rules say a ticket is done by a commit on
the default branch and that nothing pushes the default branch: `scripts/open-ticket-pr.sh`
pushes a `ticket/<id>` branch and opens a pull request, and `prompts/grill-me.md` writes new
tickets and stories on a `backlog/<slug>` branch and opens a pull request. So a UI that wrote a
new ticket could not simply commit it, and a UI that committed a sprint change would be doing by
machine what the loop reserves for an agent's pull request. `scripts/sprint.sh` already set the
precedent for the sprint half: every one of its commands rewrites the one line in `.loop.toml`
and prints the new list, and its header says that committing the change is the owner's.

## Decision

The UI changes only the `sprint` list in `.loop.toml`, through `scripts/sprint.sh`, in the
working tree. It marks the change as uncommitted on screen and never runs `git add`,
`git commit`, or `git push`. Committing the sprint stays the owner's. New tickets and stories
stay `prompts/grill-me.md`'s job, on a branch with a pull request.

## Alternatives

- Branch and pull request from the UI, as grill-me does: it would let the UI write new tickets
  as well, but a sprint edit is not a backlog change, and it turns one keystroke into a branch, a
  commit, and a pull request.
- Read-only, printing the command to copy: zero risk of a stray edit, and it is the safest
  reading of "show me what is left", but it leaves "add items to it" as manual work, which is the
  complaint the UI exists to answer.
- Write and commit on the current branch: simplest to build, and it would put an unreviewed
  commit on whatever branch the owner happens to be on, including the default one.

## Consequences

The owner commits the sprint change, so an edit can sit uncommitted and be lost to a
`git checkout` or a rebase; the on-screen uncommitted marker is the whole safeguard, which is
why it is in the wireframe rather than a later addition, and why LK-03's self-test asserts that
`git status --porcelain` shows only `.loop.toml` and no commit.

The UI is not a way to grow the backlog, so `grill-me` remains the only writer of new tickets
and keeps its branch-and-pull-request discipline — which also means the UI never has to decide
what a ticket's body should say, or which section it belongs in.

## What would show this was wrong

Sprint edits are lost often enough to matter: the owner forgets to commit after a session and a
later `git checkout` or rebase drops the change, so the UI commits its own sprint edit to a
branch, in a superseding record. Or the owner wants new tickets from the UI often enough that
leaving them to grill-me is the bottleneck — which would reopen the branch-and-pull-request
question rather than this one, since the UI cannot write a ticket without answering it.
