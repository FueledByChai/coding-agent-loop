# 0007 — The agent review is required here, and a scheduled run on the owner's machine produces it

Status: accepted
Date: 2026-09-14

## Context

`.github/ruleset.json` named one required status, `Check (check.sh)`. The README documents the
other half of the loop's gating for a project — "Add the context to the branch ruleset's required
status checks and auto-merge waits for it" — and LK-09 turned auto-merge on here, so a green pull
request now merges itself. What "green" means is therefore the whole of the gate, and a check that
runs `./check.sh` does not read the diff against the ticket it claims to serve.

The review is not a workflow. `prompts/review-prs.md` reads the ticket, the diff, and the Project
rules, posts one comment, and records the verdict with `scripts/review-status.sh` as a commit
status posted from a machine with the owner's subscription, because no agent subscription lives on
GitHub and no API key should be placed there. So requiring its status before something produces it
would hold every pull request forever — which is why LK-06 was blocked by LK-09 (no ruleset was
applied at all) and then by LK-22 (the check forbade the context).

There was also no working example to copy. Tessera's committed `docs/github/ruleset-main.json`
requires the context, but its applied ruleset does not, and nothing posts it there either: the file
and the applied state had drifted and the review had never run. So this is the first time the kit's
own loop requires a review, and the runner has to be decided rather than inherited.

## Decision

This repository requires the `Agent review` context, in `.github/ruleset.json` and in the applied
ruleset, and a recurring run of `prompts/review-prs.md` on the owner's machine produces it. The
runner is a schedule, not a workflow.

## Alternatives

- A GitHub Actions job that runs the review: rejected because it needs an agent API key living on
  GitHub, which the README's review section rules out, and because a job that cannot really judge
  the diff would be a required check that always passes — worse than none, since it looks like one.
- Require the context only once a person has run the review by hand: rejected because a review is
  per head commit. The next push is a new sha with no status, so the gate would hold the very pull
  request it had just let through.
- Keep the review advisory and do not require it: rejected because the loop merges on green, so an
  advisory review lands after the merge or never. That is what the kit has had until now, and the
  two pull requests it merged mid-check are what it bought.
- Require it and have the owner post the status by hand each time: rejected because it makes the
  owner the runner, which is the work the schedule exists to remove.
- Require it and let the review's absence be visible as a red status: rejected because "the review
  has not run yet" and "the review failed" are different states, and a gate cannot tell them apart
  by holding everything.

## Consequences

Every pull request here now waits for `Agent review` as well as `Check (check.sh)`, both green on a
branch up to date with the default branch. The owner's override for a wrong verdict is
`scripts/review-status.sh <sha> pass "override: <reason>"`, which is recorded in the status.

The runner is invisible to `git` and to CI: it is a schedule on one machine. A machine that is
asleep, or a schedule that is paused, stalls merges without anything in the repository going red —
the same shape of risk as 0005, one step further out, and the reason this is written down. The
review costs an agent run per interval whether or not a pull request is waiting.

`scripts/ruleset-check.sh` accepts the context because it is the loop's own `review_context`
(0006), so the file and the applied ruleset can be kept in step by re-applying the file rather than
by remembering a second edit.

## What would show this was wrong

Merges stall for hours with `Agent review` the only thing outstanding, so the schedule is not
keeping up and the gate costs more than the review returns. Or the verdict is red often enough for
reasons the author cannot act on that the owner overrides it routinely — a gate everyone overrides
is not a gate, and the review should go back to being a comment.

Or the kit grows a runner that does not depend on one machine — a hosted service the owner
authorises, or a check that the review ran rather than one that waits for it — which would mean
"a schedule, not a workflow" was a constraint of the moment rather than a choice.
