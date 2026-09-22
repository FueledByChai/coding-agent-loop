# 0025 — Require whole-job lifecycle stop proof before releasing worker ownership

Status: accepted
Date: 2026-09-22

## Context

The foreground contract in 0018 cannot contain the first real Codex tool adapter. Mac probes
observed command process groups different from the launcher with both tool execution modes.
A parent process, group or session disappearing does not establish that its job has stopped.
The user wants Codex first and interchangeable worker providers later.

## Decision

Add an opt-in, provider-neutral lifecycle broker. The journal records a lifecycle intent in
the same transaction as each new job. Existing jobs/events remain intact; the first domain-bound job advances the journal version
to v2 so an older binary refuses it. A job with that
intent cannot release ownership using process-group evidence alone: its fixed trusted broker
must return matching job, role and fence identities and a permanently closed domain.
Missing state, failed calls, unreadable population, conflicting assignments and failed stops
retain ownership. Broker configuration/runtime revisions are pinned into worker policy and
therefore into acceptance evidence. Switching providers invalidates prior receipts.

A broker reservation claims one role lane, and consuming it records launch before forking.
The trusted child inherits a launch lock until kernel enrollment, credential drop and exec.
A killed launcher cannot open a gap in which reconciliation releases a not-yet-enrolled child.
The broker closes a job permanently; old requests cannot relaunch it or stop a newer job.
A normal adapter exit with surviving commands fails the job and drains its domain. Timeout
also stops the domain; unproven cleanup holds ownership. No model selects a command, OS
identity or stop target; root executes only fixed trusted launch code before dropping privileges.

Use Linux cgroup v2 membership, `cgroup.kill`, and `cgroup.events` population. Keep cgroup
control files root-owned and unavailable for worker writes; set no_new_privs before exec.
On macOS use one exclusive non-login real UID for each execution role, distinct from the
interactive user, trusted observer and merge controller. Query all real-UID members through
libproc's kernel-filtered inventory, including zombies. Cleanup broadcasts SIGKILL only after
dropping to that execution UID, avoiding PID reuse hazards. Never apply UID cleanup to the
interactive account. An inherited system sandbox denies job creation, authorization rights and cron/at spool writes.
Accounts must have no sudo or service/scheduler launch grants. These are
local command containment contracts, not support for delegated remote jobs or privileged
services that can launch work outside the domain.

The portable interface is reserve/run/seal/stop with structured requests. Provider invocation,
model choice, credentials and output parsing stay in fixed adapters. The caller's harness
neither chooses nor weakens containment. This broker has no GitHub, CI, status or merge actions.

## Alternatives

- Keep the Codex commands in one process group: the real tool runtime does not do that.
- Poll a process tree, or replace the group with a session: reparenting and setsid leave gaps.
- Share the interactive UID: cannot stop that domain without affecting unrelated user work.
- Treat an exited adapter or elapsed timeout as proof: surviving commands could edit a reused tree.
- Require every AI provider at first launch: unnecessary; one real Codex adapter and a deterministic
  non-Codex fixture can prove the same neutral protocol before adding production providers.

## Consequences

Installation only ships code. Production activation requires protected fixed entry points,
private execution accounts, independent observer/journal identity, pinned artifacts, and host
acceptance. The previous foreground mode remains explicitly limited to compliant adapters.
The new path must be integrated with the isolated-worker increment before the controlled pilot.
The existing Mac accounts and journal are not silently repurposed or migrated by this change.

Offline fixtures and the Linux host proof are distinct from Mac host acceptance and a real
Codex interruption test. Those remaining proofs keep LK-65i and downstream activation open.
No proof in this increment authorizes CI, a gate migration or merging a PR.

## What would show this was wrong

A command surviving a successful stop proof, a child starting after sealing, an old request
stopping a new assignment, changed provider policy reusing acceptance, or incomplete kernel
visibility reported as empty invalidates this design. A provider that delegates work to another
service needs a separate containment backend and must remain disabled until it is proven.
