# 0024 — Keep isolated author starts free of ignored files

Status: accepted
Date: 2026-09-21

## Context

The canonical tracked-byte check in 0023 does not cover untracked files hidden by Git
exclusions. LK-0fs reproduced an ignored conftest.py changing the available test source
while the assigned checkout passed its starting-state validation.

## Decision

In isolated author mode, enumerate every untracked file without standard Git exclusions.
Refuse launch when any exists, including files ignored by committed .gitignore rules,
repository-local exclusions or global exclusion settings. Git's own metadata is not a
working-tree source file. Keep the legacy single-identity behavior unchanged.

## Alternatives

- Trust ignored files: allows unreviewed configuration and code to influence repairs.
- Allow caches by filename: cache directories can also contain executable code; a generic
  path allowance cannot establish that their contents are safe for the assigned job.
- Automatically delete files during validation: could destroy valuable local state and
  turn a read/validation boundary into destructive cleanup.

## Consequences

LK-e9y must use dedicated worker checkouts, keep credentials, Beads state, runtime state
and caches outside them, and establish a clean starting checkout before each assignment.
A job may generate build output, but cleanup or fresh-checkout preparation must complete
before another author job is dispatched. Waiting PRs still receive no rebuild or refresh.
The validator reports the dirty start and deletes nothing. Existing user worktrees must
not be repurposed and indiscriminately cleaned by the controller.

The real-UID proof checks ignored-file rejection; self-tests cover local, global and
committed ignore rules and verify a clean checkout remains accepted after fixture cleanup.

## What would show this was wrong

An ignored worktree file accepted at launch, validation deleting local files, or host
integration depending on in-checkout credentials/state would require correction before
activation. Supporting safe persistent artifacts needs a separate explicit design.
