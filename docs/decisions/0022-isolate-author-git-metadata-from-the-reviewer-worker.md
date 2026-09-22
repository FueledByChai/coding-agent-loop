# 0022 — Isolate author Git metadata from the reviewer worker

Status: accepted
Date: 2026-09-21

## Context

LK-0fs follows the Mac activation work under LK-e9y. The local worker model in 0018
uses linked worktrees. An author-configured core.fsmonitor command executes during
reviewer git status in that shared repository. Giving a separate reviewer UID access
to author-writable Git metadata would let hooks or filters reach reviewer credentials
and receipts. Separate HOME directories and a model prompt do not fix that boundary.

## Decision

Keep the legacy local worker mode for existing trusted single-identity operation.
Add an explicit isolated mode: one reviewer-owned canonical journal and observation
mirror, protected through every ancestor, and a configured non-root author UID distinct
from the reviewer. The reviewer never runs Git in an author checkout. A protected policy
maps each ticket to one canonical author path; this mapping, role identities and code
remain part of the policy binding. Acceptance uses detached worktrees of the reviewer's
own mirror, fetching the exact published head there before inspection.

Run author jobs through one fixed root-owned foreground wrapper which switches to the
configured author UID and calls the installed author-bridge command with a fixed protected
policy. The bridge rejects another UID, role, path, repository, branch, head or dirty
checkout before executing the configured adapter. It replaces packet instructions with
the installed author instructions and requires the original guardian process group.
The bridge has no acceptance, CI or merge authority. Wrapper and sudo configuration are
operator-owned deployment artifacts; the kit never grants sudo rights or starts services.

The reviewer owns job preparation and final provider validation for both roles. All
roles contend for the same repository/PR ownership in that journal. No author-written
journal is imported as acceptance. Migrate only stopped journals, retaining history;
retire the old registration before dispatching from the new authority. Do not run two
hosts or independent journals for the same repository. Existing receipts become stale
when the policy or worker implementation changes.

## Alternatives

- Share writable Git metadata across UIDs: author Git settings can execute as reviewer.
- Run all workers under one UID: does not establish independent reviewer storage.
- Give every role an independently writable journal: loses canonical ownership and lets
  author-created receipts masquerade as independent acceptance.
- Use a general privileged shell: grants unnecessary authority; only a fixed role wrapper
  and fixed configuration are appropriate.

## Consequences

Git worktrees remain useful within a role's own clone, but are not the cross-identity
boundary. Waiting PRs still receive no rebases or CI. Completed exact-head review and
all existing feedback/criteria/policy bindings still precede acceptance.

A reviewer cannot kill a different-UID author process. A timeout kills the guardian's
reachable group members; surviving or inaccessible members keep the job owned. Operator
stop/reconciliation is required in that case. UID-switch wrappers that create a separate
process group, detach descendants or hide execution are unsupported and must be rejected
before live use, not treated as a successful stop on lease expiry.

Offline tests exercise the protocol and malicious Git configuration. An explicit
root-run synthetic identity proof additionally uses two real non-root UIDs to verify
private storage denial, separate Git metadata, fixed bridge execution and retention
until a surviving author is stopped. That proof does not spend a model call, contact
GitHub, install sudo rights or activate the queue. LK-e9y still requires the actual
host wrapper, supervisor and complete live acceptance before cutover.

## What would show this was wrong

An author setting executing as reviewer, author access to protected receipt state,
a bridge accepting an unassigned checkout, or releasing a job while a cross-UID child
survives would invalidate this boundary. Such a result blocks activation.
