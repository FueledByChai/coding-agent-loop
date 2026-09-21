# 0019 — Plan merge order and separate acceptance from final status publication

Status: accepted
Date: 2026-09-20

## Context

LK-9r7 requires a merge order beside planned tickets. The review prompt still refreshes every
open PR and posts a passing status immediately after its own assessment, contradicting the
waiting-PR contract in 0017 and the separate acceptance receipt in 0018. PR #73 merged while
Codex review was running; two subsequent findings required another ticket and PR. A review
verdict must not double as permission to merge an unfinished candidate.

## Decision

Extend planning, author and reviewer prompts with a recorded order, predecessors, named
coordinator and one selected candidate. Record confirmed plans and revisions in a coordinating
Beads issue and link participating tickets. Ordering preferences are not implementation
blockers. Verify predecessor merges and landed commits before selection; revise the recorded
order explicitly when bypassing a failed candidate. Only the selected candidate receives the
project's sanctioned refresh and CI request. Waiting PRs may receive fixes, local proof and
independent acceptance but never a queue-driven refresh or CI request.

This refines 0016–0018 and replaces the immediate passing-status handoff described in 0007.
Acceptance workers return receipts only. In the legacy bootstrap, a named independent
coordinator may relay acceptance only after completed full-head Codex review, resolved findings,
fresh independent acceptance and successful actual final-head CI, rechecking evidence after CI.
Open PRs as drafts and disable auto-merge before marking ready. Reassess changed evidence even
without a new head. Missing readiness leaves status unposted; invalidate stale passing evidence.

A shadow plan is not live admission. Without a live controller, one coordinator serializes
handoffs using existing Beads and GitHub tools; notes are not an atomic lock. Ambiguous ownership
stops admission. The legacy status API cannot fence a last-moment review race; live trusted App
publication and CI admission remain LK-e9y and LK-412. This change does not alter CI triggers,
repository rules, installed consumer pins or services.

## Alternatives

- Refresh every waiting PR: for N independently prebuilt PRs, rebuilding after each merge can
  add N(N-1)/2 full runs. Five PRs cost 15 runs instead of five successful candidate runs.
- Turn merge preferences into dependencies: unnecessarily blocks parallel implementation.
- Let each author select itself from a plan: multiple candidates can spend CI concurrently.
- Publish acceptance as a passing required status before Codex or CI completes: repeats the
  premature merge rather than preserving the independent acceptance boundary.

## Consequences

Prompt phrase mutations protect each new planning and review rule; a recorded real prompt run
checks selected, waiting, changed-head and incomplete-review scenarios. The savings describe
redundant runs, not a guarantee of one build despite actual failures or code changes. Existing
push-triggered builds continue until the separate admission rollout. No new tool is required.

## What would show this was wrong

Two authors treating a planned order as independent admission, a waiting PR refreshed by a
reviewer, or a passing gate posted while head review is running would refute the handoff. If
operators cannot reliably serialize manual selection, live enforcement must precede adoption.
