# 0028 — Offer a manually adopted single-agent profile beside the full loop

Status: accepted
Date: 2026-09-23

## Context

The full loop provides durable multi-agent ownership, independent acceptance, fenced CI admission
and merge authority. Those controls are useful only after a project needs their concurrency and
trust boundaries. A project trying to establish one reliable agent can instead spend more time
operating the controls than delivering its first pull requests.

The smaller profile still needs to preserve the useful boundaries: Beads owns durable work, one
application check is required on the current pull-request head, and high-risk changes wait for a
person. Codex review can identify real defects, but running the expensive check while its first
findings are still changing the head wastes the run. GitHub does not count a workflow_dispatch run
as a pull-request required check, and a skipped required job can satisfy protection.

## Decision

Ship `recipes/single-agent/` as a manually copied alternative profile. The installer and kit-sync
do not copy it into full-loop consumers. The profile permits one claimed implementation ticket and
one implementation pull request, with no coordinator, review worker, acceptance journal, required
AI-review status or merge queue.

The agent runs focused proof while editing, opens the pull request, gives its initial Codex review
one bounded opportunity, and handles all credible findings in one correction. Ordinary corrections
do not request another review. Only the resulting final head requests the expensive check by adding
`ci:run`; a pull-request labeled workflow starts its required job and fails before checkout unless
that exact label was added to a non-draft pull request. A later push removes and re-adds the label.
The required context is bound to the GitHub Actions integration, and strict up-to-date protection
keeps a stale base from merging. Auto-merge is enabled only after review triage and CI admission.

The recipe validator executes the admission block against accepted, unrelated-label and draft
fixtures, verifies the exact job/context and GitHub Actions integration, and is itself part of the
kit's check. Projects adapt toolchain setup and project rules explicitly.

## Alternatives

- Run full CI on open and every push: simple, but every review correction invalidates an expensive
  run and reproduces the delay this profile exists to remove.
- Use workflow_dispatch: GitHub documents that its checks do not satisfy pull-request required
  status checks.
- Skip the required job for unrelated labels: a skipped required check can satisfy protection.
- Install the profile beside the full loop: creates two competing delivery contracts in a consumer.
- Ignore Codex findings entirely: faster only by knowingly permitting reported defects to merge.

## Consequences

An ordinary change pays for targeted proof, at most one bounded Codex review pass, and one full CI
run on the final head. CI failures can add a run, but review corrections do not start an automatic
review/CI cycle. The cooperative label is not a trusted authorization boundary; it is sufficient
for one owner and one in-flight pull request, not for hostile or concurrent authors. Adding agents
later requires measured coordination rather than silently stretching this profile.

## What would show this was wrong

An unrelated label or draft reaching expensive work, a required check accepted from another App,
known initial-review defects routinely merging, or ordinary tickets needing repeated review/CI
cycles would refute the profile. Multiple simultaneous implementation pull requests would require
a stronger admission owner rather than more rules in this recipe.

Primary references:

- https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks
- https://developers.openai.com/blog/custom-code-review-rules-for-codex
