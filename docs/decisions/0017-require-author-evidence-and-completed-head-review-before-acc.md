# 0017 — Require author evidence and completed head review before acceptance handoff

Status: accepted
Date: 2026-09-20

## Context

LK-sm4 records a gap between opening a PR and the independent review: no reusable prompt tells
the author how to handle findings. LS-03 needs that contract before durable repair workers can
use it. Resolving a thread without a repair, filing a follow-up without deciding whether it
blocks, and treating a push as a completed Codex review all produce false readiness.

## Decision

Ship an author-response prompt, command and skill pointer, invoked from the ticket handoff.
The assigned author fixes, disproves or separately tickets each finding with evidence tied to
the full head; disputed or deferred findings remain blocked until an independent reviewer
accepts the disposition. A substantiated published fix may be resolved by the author where
project policy allows, but author responses never supply independent acceptance or a passing
review status. Require completed review of the resulting commit before handing it forward.

## Alternatives

- Have the reviewer repair its own findings: loses the independent assessment and risks two
  workers editing the same worktree.
- Mark all replied-to threads resolved: a reply may dispute or defer a defect without fixing it.
- Depend on implicit review after a push: the Codex app may need a new review request for a
  changed head; a queued request and a shortened commit string alone are not completion evidence.

## Consequences

The author stays responsible after opening a PR, records blockers durably, and does not rebase
or request CI while waiting for admission. Prompt rules and installed pointers are checked;
the PR records a real author-response run. This does not install a worker service or change CI
triggers or protections. LK-3pg supplies durable ownership, independent acceptance jobs and
trusted evidence adapters; LK-e9y supplies the live enforcement boundary described in 0016.

## What would show this was wrong

An author treating a reply as independent approval, clearing a blocker only by filing a new
ticket, using a review from another commit, or starting overlapping repairs would invalidate
this handoff. Repeated legitimate work blocked solely by unclear resolution authority would
also require revisiting the contract.
