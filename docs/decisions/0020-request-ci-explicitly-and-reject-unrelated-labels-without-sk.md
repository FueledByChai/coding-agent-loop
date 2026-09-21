# 0020 — Request CI explicitly and reject unrelated labels without skipping the required job

Status: accepted
Date: 2026-09-21

## Context

LK-412 records repeated full builds during author review and the skipped-required-job trap.
The installed workflow is ci/workflow.yml; templates/ci contains stack setup snippets. The
queue guidance in 0019 orders review and acceptance before final validation, but the default
skeleton still builds on PR opening, every push and every main merge.

## Decision

New installations use pull_request labeled events only. The required Check (scripts/check.sh)
job always starts; its first shell step rejects anything except a ci:run label-add event on a
non-draft PR with failure before checkout, toolchain setup or full checks. Event fields enter
through quoted environment variables. Checkout names the event's full PR head explicitly.
Keep the ruleset context and strict up-to-date policy. Authors hand review evidence to the
named coordinator; only its selected, reviewed and independently accepted candidate is requested.

Existing project workflows and the kit's own workflow remain unchanged. Migration is deliberate:
retain unique post-merge checks/deployments, remove duplicate full builds only after evaluating
them, and keep an independent final merge gate. This skeleton is a cooperative request protocol,
not a trusted authorization boundary. Live App admission, serialization and idempotent dispatch
remain LK-e9y. The coordinator reuses valid running/successful evidence; a changed head or explicit
retry requires removal/re-addition after the review prerequisites are met.

## Alternatives

- Job-level label if: skipped required jobs can satisfy protection without tests.
- Build for every label: wastes expensive CI on progress/triage labels and waiting PRs.
- workflow_dispatch alone: its Actions job does not satisfy the current PR-required context;
  switch only with the separate App check migration.
- Change all installed workflows automatically: could remove project-specific release behavior
  and disrupt existing branch protection before controller enforcement is available.

## Consequences

Ordinary pushes and PR openings spend no full CI with the new skeleton. Unrelated label events
still start a cheap failed job and can replace earlier green status; avoid label changes after
validation. A persistent label is not a request for a new head. Someone able to add ci:run can
still request a waiting PR, so the trusted gate is required for enforceable admission.
The full check and its status name remain unchanged. Installer tests execute the actual shell
gate across request, unrelated label, draft, synchronize, opening, removal, push, dispatch,
missing-label and shell-like-label inputs, and verify installed workflow/ruleset compatibility.

## What would show this was wrong

An unrelated label or draft reaching expensive work, a request rejection reporting success,
an ordinary push starting full CI, or the installed ruleset requiring a missing job refutes the
skeleton. Concurrent or unauthorized requests demonstrate the documented need for LK-e9y,
not permission to treat a label as queue ownership.

Primary reference: https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks
