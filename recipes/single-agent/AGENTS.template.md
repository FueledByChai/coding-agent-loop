# Project instructions

## Delivery workflow

Beads is the durable backlog. Keep exactly one implementation ticket claimed and one
implementation pull request open at a time.

1. Run `bd dolt pull`, then inspect `bd list --status=in_progress --json` and
   `gh pr list --state open`. Finish existing implementation work before inspecting `bd ready`;
   stories and epics are context, not implementation tickets.
2. Read the selected ticket with `bd show <id> --json`, then claim it with
   `bd update <id> --claim` and publish the claim with `bd dolt push`.
3. Read the repository's default branch with
   `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`, fetch it from `origin`, and
   create an isolated worktree and `ticket/<id>` from its current remote head. Keep the change
   limited to that ticket and record discovered work in Beads.
4. Implement the acceptance criteria. Run focused tests for the changed behavior while working;
   do not repeatedly run the full repository check after every edit.
5. Review the branch diff against the remote default branch once for correctness, scope, missing
   proof, secrets, and unintended generated files. Commit with the ticket id first in the subject,
   push, and open a ready pull request. Do not request full CI or enable auto-merge yet.
6. Give the initial Codex review one bounded opportunity to complete (ten minutes by default).
   Read all findings once. Batch every credible finding into one correction and reply once with
   evidence to rejected findings. Run focused proof and review the resulting diff; do not request
   another Codex review for an ordinary change.
7. Bring the branch current with the remote default branch if needed. Any resulting content change
   gets focused proof and one final diff review. Add the `ci:run` label to request the one full
   `scripts/check.sh` run, then enable rebase auto-merge. If the label is already present, remove it
   and add it again. Any later push requires that same remove/add request for the new head.
8. If CI fails, fix only the demonstrated failure, push the smallest correction, and request CI
   once on that new head. Do not reopen the ordinary Codex review loop.
9. After GitHub merges the pull request, verify the commit is on the remote default branch, close the Bead,
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
