# 0018 — Keep review worker jobs durable and separate from merge authority

Status: accepted
Date: 2026-09-20

## Context

LK-3pg implements LS-03's repair and acceptance stage after the shadow queue (0016) and author
handoff (0017). A scheduled prompt alone cannot distinguish a completed job from a crashed
launcher whose editor still runs. Author responses also cannot serve as independent acceptance.

## Decision

Ship a separate opt-in worker journal and foreground command protocol. Provider reads prepare
jobs from actual GitHub and Beads state; imported shadow snapshots never launch them. A durable
identity binds repository, PR, role, worktree, full head/base, feedback, criteria and policy.
SQLite exclusive claims prevent overlapping ownership of either a PR or worktree within the
repository's canonical journal; linked worktrees register that journal in their Git common
directory, and separate clones must be configured to share it. Repeated
requests reuse the job. Acceptance uses a separate detached tree and fresh reviewer session.

Before starting an adapter, a guardian registers its process group durably. An inherited lock
covers the launcher-to-guardian gap. A stopped/failed job releases only when that lock is free
and no executing group members remain; Linux zombie-only groups need two matching complete
task inventories, including nonleader threads. Uncertainty holds the slot. After verified stop,
remove the runtime-owned detached reviewer tree and Git registration while retaining journal
evidence; cleanup failure retains ownership. Author trees remain. Retries require a reason and budget.
This local mode supports trusted foreground POSIX adapters whose descendants stay in that group.
Detached/remote agent execution requires a different stop-proof adapter before unattended use.

Validate structured receipts against fresh provider reads. Every acceptance criterion line
needs evidence covering all its clauses; semantic judgment belongs to the independent reviewer.
Actual thread replies, authors and published fixing commits corroborate repair receipts. Bot
completion summaries count only after provider resolution of their commit to the full current
SHA. Running summaries, stale identities, incomplete output and provider failures cannot pass.

## Alternatives

- Give author jobs the required review context: conflates fixing a finding with independent
  acceptance, and would give author credentials merge-gate authority.
- Release on lease expiry or parent exit: a child can still be editing the worktree.
- Resume an arbitrary previous agent conversation: risks carrying author assumptions into the
  independent review, or attaching to another PR's session.
- Turn shadow imports into live dispatch: would promote simulation data into authorization.

## Consequences

No service starts on install. Adapters, identities and environments come from private operator
configuration outside the checkout; no controller environment is automatically inherited.
Worker code and policy revisions invalidate acceptance. Configuration and the local journal are
trusted operational state, not a hostile-code sandbox or an App-issued gate. Keep future merge
credentials on a separate service identity. LK-e9y still owns supervised live CI/merge adapters
and enforcement; this increment never posts statuses, dispatches CI or merges a PR itself.

Offline process tests prove duplicate delivery, concurrent claims, restart, killed launcher,
live descendants, timeout, missing evidence and stale source rejection. The PR also records
real author and independent reviewer model sessions on a controlled synthetic provider surface.
That proof does not establish production credentials, service supervision or crash containment
for arbitrary external agent harnesses.

## What would show this was wrong

Two editors owning one PR/worktree, a released job with a surviving supported worker, an author
receipt returned as acceptance, or a changed criterion/head still receiving passing evidence
would invalidate this design. A production harness escaping the supported process-group
contract requires a provider/container stop proof, not a weaker reconciliation rule.
