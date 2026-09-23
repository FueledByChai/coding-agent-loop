# Project instructions

## Delivery workflow

Beads is the durable backlog. Keep exactly one implementation ticket claimed and one
implementation pull request open at a time.

1. Run `bd dolt pull`, inspect `bd ready`, and finish existing in-progress work before selecting
   anything new. Stories and epics are context, not implementation tickets.
2. Read the selected ticket with `bd show <id> --json`, then claim it with
   `bd update <id> --claim` and publish the claim with `bd dolt push`.
3. Fetch `origin`, create an isolated worktree and `ticket/<id>` from current `origin/main`, and
   keep the change limited to that ticket. Record discovered work in Beads.
4. Implement the acceptance criteria. Run focused tests for the changed behavior while working;
   do not repeatedly run the full repository check after every edit.
5. Review `git diff origin/main...HEAD` once for correctness, scope, missing proof, secrets, and
   unintended generated files.
6. Commit with the ticket id first in the subject. Push the branch, open a ready pull request,
   and enable rebase auto-merge. CI owns the full `scripts/check.sh` run.
7. If CI fails, fix the demonstrated failure and push the smallest correction. Batch concrete
   review findings into one correction; AI review is not a required merge gate.
8. After GitHub merges the pull request, verify the commit is on `origin/main`, close the Bead,
   and run `bd dolt push`. Never close a ticket merely because a pull request is open or green.

Never push directly to the default branch, force-push published history, delete backlog state,
deploy, mutate a provider, or perform customer-visible actions unless the ticket and operator
explicitly authorize it.

## High-risk changes

Do not enable auto-merge for authentication or authorization changes, irreversible migrations,
payments, secrets, production infrastructure, destructive operations, or customer-visible
external side effects. Report the exact proof and wait for the project's named human gate.

## Project-specific rules

[Describe the architecture, targeted local test commands, protected paths, runtime/deployment
boundaries, and any customer-data restrictions here.]
