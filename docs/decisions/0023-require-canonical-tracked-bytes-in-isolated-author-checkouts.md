# 0023 — Require canonical tracked bytes in isolated author checkouts

Status: accepted
Date: 2026-09-21

## Context

LK-0fs implements the author bridge in 0022. Git status alone cannot prove that a
checkout contains the assigned commit's source: author-defined clean filters and
built-in attribute conversion can report clean while different bytes remain on disk.
Disabling individual stat settings does not address content conversion.

## Decision

In isolated author mode, compare raw tracked file bytes and executable modes with
blob IDs and modes from the assigned commit, and compare symlink target bytes without
following the link. Reject configured clean/smudge/process filters before adapter
execution. Retain branch/head and index-flag checks; inspect staged differences and
untracked files separately through Git plumbing instead of working-tree status.

Require canonical commit bytes in this opt-in mode. Ordinary files and symlinks are
supported; submodules and converted checkouts, including LFS/smudge output or converted
line endings, stop before adapter launch. Legacy single-identity mode is unchanged.

## Alternatives

- Keep adding Git status overrides: misses conversions that intentionally map different
  working bytes to the same committed content.
- Execute author filters to normalize content: the repair agent would still read bytes
  that differ from its assigned commit, and validation would execute author commands.
- Implement recursive submodule and conversion-aware validation now: adds independent
  repository and transformation policies before the controlled kit deployment needs them.

## Consequences

The check reads tracked contents rather than trusting index timestamps. Existing clean
canonical checkouts remain usable without altering their Git configuration or index.
Repositories requiring transformed checkouts or submodules need a separately designed
extension before enabling isolated workers. The current kit checkout needs neither.

This validates an assigned starting checkout; it does not sandbox the author or prevent
later edits. Independent acceptance still fetches the published head into reviewer-owned
Git metadata, and the controller retains all final head and evidence fences from 0022.

## What would show this was wrong

A different tracked file accepted at adapter launch, author filter execution during
validation, or rejection of an ordinary canonical file or symlink would invalidate the
implementation. A consumer requiring transformed checkouts or submodules would require
a new decision specifying their independent validation before widening support.
