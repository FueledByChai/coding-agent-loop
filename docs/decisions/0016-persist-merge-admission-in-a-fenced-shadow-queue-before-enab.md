# 0016 — Persist merge admission in a fenced shadow queue before enabling live adapters

Status: accepted
Date: 2026-09-20

## Context

LS-03 needs one PR admitted to final validation at a time. Prompt-only merge ordering cannot
arbitrate two workers, preserve an attempt across a process restart, or reject a late result
from an expired worker. The owner approved an executable queue whose review and acceptance
work precedes CI. LK-6yn supplies its first increment. Existing rulesets and CI triggers must
keep protecting repositories while the new enforcement is built.

## Decision

Use Python 3.9 standard-library SQLite for a transactional execution journal, separate from
Beads ticket tracking. Ship the first controller as shadow-only: observation, FIFO requests,
readiness explanations, and fenced promotion leases, with a read-only GitHub/Beads adapter.
There is no live execution or GitHub mutation command in this release.

One repository/base pair has at most one active attempt. Its identity includes the full head,
base SHA, candidate revision and a monotonically increasing token. Candidate or base changes
permanently invalidate the token but do not release the slot; failures and expired leases need
explicit reconciliation. Restarting or merely waiting cannot prove a worker has stopped.
Observations are timestamped when collection starts; old observations cannot replace newer
ones and incomplete provider reads cannot refresh readiness. Live scans never invent acceptance
proof from the current review status or interpret a closed PR as merged.

A later controller-owned GitHub App check is the live enforcement boundary. It will require
trusted review/acceptance and CI evidence; imported simulation observations are not such
proof. Credentials and execution must be separated before a live gate is enabled. This record
does not replace existing merge rules or grant the shadow CLI permission to merge.

## Alternatives

- Labels and a scheduled agent prompt: visible, but neither supplies atomic ownership or a
  durable fencing token, and labels are editable by authors.
- An in-memory lock: loses active work on restart and cannot reject results from old workers.
- Expire a lease and immediately start another build: elapsed time does not prove the first
  runner stopped, so two candidates could spend CI or publish competing results.
- Ship all live adapters before exercising the queue: leaves concurrency and crash recovery
  untested until they can affect real branches and required checks.

## Consequences

The journal remains outside Git and holds operational identities/evidence, not customer data
or credentials. Bash wrappers stay portable to macOS 3.2; Python uses only the standard library.
The fixture suite and installed self-tests prove competing claims, restart, stale evidence,
dependency order and provider failure. A live read-only scan demonstrates the adapter without
changing repository protection. Full-head reviews recorded only in shortened summary comments
remain unknown until a trusted resolver exists. Worker adapters, service supervision, exact
candidate CI dispatch and the GitHub App gate remain required before live queue operation.

## What would show this was wrong

Two active attempts for one repository/base, an old token affecting a newer attempt, an absent
PR treated as merged, a provider error treated as fresh readiness, or any GitHub write made by
the shadow CLI would violate this decision and fail its executable proof.
