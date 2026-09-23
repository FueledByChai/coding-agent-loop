# 0028 — Stage queue files without changing an active legacy merge path

Status: accepted, supersedes 0019
Date: 2026-09-23

## Context

Decision 0019 made draft pull requests and disabled auto-merge part of its legacy bootstrap.
That assumed the new queue handoff could become authoritative as soon as its files reached a
consumer. A controlled migration cannot make that switch atomically: the trusted workflow must
land before the App installation, protected controller state, ruleset and pilot can be verified.
RockBox PR #165 exposed the result. The v0.22.0 author and reviewer prompts would disable its
still-authoritative legacy auto-merge path while the new workflow was deliberately inert, leaving
green pull requests with no actor permitted to merge them. LK-ddt records the compatibility rule.

## Decision

Keep 0019's recorded merge order, one selected candidate, waiting-PR freeze, completed exact-head
review, independent acceptance, final-head CI and fresh final-gate verification. Change the pull
request handoff according to the profile explicitly named by the consumer's Project rules:

- Staging queue files does not activate the App controller. In legacy or staged mode, authors,
  backlog planners and reviewers preserve the project's existing draft, auto-merge and status
  publication procedure.
- In operator-enabled `github-v1`, authors open drafts and keep ordinary auto-merge disabled; the
  App owns selection, CI admission, the final gate and merging.
- A project-required status wrapper owns every legacy status transition, including pending
  invalidation. If stale success cannot be reset through that sanctioned path, the coordinator
  disables and verifies auto-merge before stopping, so known-invalid evidence cannot merge.

Prompts and generic documentation must state both profiles. Presence of workflow, prompt or
controller files is never evidence that the live profile changed.

## Alternatives

- Make installation the cutover: creates an interval with no functioning merge actor and makes
  rollback depend on editing every waiting PR.
- Always preserve auto-merge: lets a legacy request bypass the App after `github-v1` activation.
- Allow raw status writes around a required wrapper: defeats the consumer's chosen serialization,
  context and audit boundary.

## Consequences

Queue rollout needs an explicit Project-rules change at activation and again at rollback. Generic
prompts must defer the mechanical draft/auto-merge/status commands to that declared profile while
retaining 0019's single-candidate and evidence gates. A legacy coordinator that cannot neutralize
stale success must fence auto-merge and report the missing transition rather than continuing.

## What would show this was wrong

A transactional installer that proves workflow, credentials, service, protections and rollback
before making any pull request mergeable under the new authority could remove the staged profile.
Evidence that a declared profile can still leave two merge actors active would require a stronger
cutover fence.
