# 0026 — Use existing agent acceptance for the first live merge queue

Status: accepted
Date: 2026-09-22

## Context

The owner approved V1 for LK-e9y and RockBox adoption RB-g6do after hosted worker
supervision delayed the requested merge queue. The dedicated App and durable controller
already exist. The owner explicitly approved trusting independent review performed by
existing agents under the shared GitHub account for V1.

## Decision

Add an opt-in `github-v1` handoff profile to the controller in 0021. Existing authors own
review replies, fixes and the sanctioned selected-branch refresh. Existing independent
reviewers assess acceptance before CI and publish a `Queue acceptance` commit status tied
to the complete observed head/base, criteria, ticket metadata and feedback digest. The
status cites their submitted assessment on that head. A configured GitHub actor allowlist
and explicit shared-account trust acknowledgement are mandatory. Author/reviewer separation
inside an allowed shared account is procedural, not a credential or adversarial boundary.
Authors must never self-accept.

`Queue nomination` is only a request. The protected controller imports nominations in
stable order into its journal, selects one candidate, and supplies an App-owned `Queue
selected` check only when that candidate needs refresh. Waiting PRs receive no controller
refresh or full CI. The author verifies the current App selection and expected head/base
before using the project's sanctioned refresh path, then completes final-head review.
The controller does not start or supervise models in this profile; it waits for the remote
branch and a fresh independent acceptance. A changed base blocks rather than reviving old
selection. From CI admission onward, all existing fencing and restart rules remain intact.

This profile supersedes the requirement for protected worker receipts as a V1 prerequisite,
not the availability or isolation guarantees of worker mode. LK-0fs, LK-65i, LK-bfo and
LK-ld7 remain separate work; their incomplete work is not reported as accepted or deployed.

## Alternatives

- Finish general unattended worker hosting first: outside the approved V1 scope.
- Treat a ready label or successful CI as acceptance: neither proves the independent review.
- Give existing agents the App key or merge bypass: unnecessary and defeats the queue.

## Consequences

The controller remains under its protected account on one host. Existing agent workflows
must use the handoff commands, with one independent reviewer responsible for acceptance.
Any harness may run them; Codex is the initial code-review provider only. Changing
head/base/criteria/feedback invalidates the recorded acceptance. No worker runtime, provider
SDK, shared author Git metadata or reviewer-owned journal is required for this profile.

Bootstrap the dedicated workflow under legacy protection (LK-pge), prove three PRs and
restart/failure behavior in the kit, then migrate gates and retire duplicate CI paths.
RockBox receives a tagged kit release and its own verified workflow/protection migration.
Until those live proofs pass, legacy protection stays active and V1 is not declared deployed.

## What would show this was wrong

An unchanged candidate producing duplicate full builds, a waiting PR being refreshed,
a stale acceptance passing, or a workflow agent self-accepting would reopen this decision.
If shared-account trust is unacceptable, require separate reviewer credentials or the
stronger worker profile before activation; do not describe procedural separation as enforced.
