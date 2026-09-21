# 0021 — Fence live CI admission and merge authority with a dedicated App and protected controller

Status: accepted
Date: 2026-09-21

## Context

LK-e9y adds the trusted execution boundary to LS-03 after 0016–0020. Labels and ordinary
commit statuses cannot prevent competing CI requests or another actor merging while code
review is still running. The existing shadow journal and worker receipts confer no authority.

## Decision

Add an opt-in controller under a dedicated OS identity, with one protected canonical journal
per repository/base. Use a dedicated GitHub App to dispatch a workflow from the trusted base,
authorize one actual run, publish the required head check and merge with the expected full SHA.
Author and independent reviewer identities cannot read its key or modify its installation,
policy, adapters, journal or observation mirror. Installation starts nothing.

The trusted workflow requests no secret from the controller. Its first step reads an
App-issued admission check on the base SHA and verifies repository, App, random attempt,
actual run id, run attempt one, full candidate head and base. Only then does it check out PR
code and run the full suite with read-only Actions permissions and no persisted Git credential.
Pin the complete workflow bytes in controller policy. Dispatch inputs cannot choose a trusted
App: its numeric id is rendered into the trusted workflow itself.

Record mutation intent before dispatch, refresh and merge. Reconcile lost dispatch responses
by the App actor, workflow id, unique run name, base and run attempt; never blindly resend.
Uncertain refreshes retain ownership even if the branch becomes current. Reopened feedback,
changed head/base/criteria/metadata/policy, absent acceptance or non-success CI revoke authority.
Check actual successful admission and full-check steps, not an aggregate green or skipped job.
An uncertain merge is reconciled by the PR's merged state, landed ancestry and tree identity.

Use two rulesets: an update restriction whose sole bypass is the dedicated App, and a separate
protection ruleset with no bypass, requiring resolved conversations, strict up-to-date checks,
rebase-only merging, history protection and the App-pinned Queue merge gate. Disable ordinary
auto-merge. Fresh evidence is checked immediately before merging. GitHub offers no atomic
transaction spanning review metadata, external acceptance and merge; native conversation/head/
base protections remain necessary, and an administrator can always alter repository policy.

## Alternatives

- Give the App a bypass on the protection ruleset: defeats the checks it must enforce.
- Trust a nonce alone in workflow inputs: a user can replay a nonce in another run.
- Dispatch PR-controlled workflow code with an App secret: exposes merge authority to authors.
- Reuse an arbitrary completed Actions run: fails to bind the admitted workflow, base and attempt.
- Retry unknown network outcomes: can launch duplicate suites or steal a live author worker.

## Consequences

The existing CI and rules stay intact until a controlled live migration proves both old and
new gates. Deployment needs a dedicated App installation, protected service account, reviewer
receipt adapter, sanctioned refresh adapter and supervisor configuration. The operator runbook
ships with the kit; local fixtures alone do not establish live enforcement or finish LK-e9y.
RockBox adoption remains RB-g6do and requires a tagged kit update. The shadow CLI remains
read-only and cannot import authorization into the controller.

## What would show this was wrong

A waiting PR spending admitted CI, two admitted runs in a lane, an author-supplied receipt
passing as independent acceptance, a resumed controller stealing active work, or a merge
without completed final-head evidence would refute this design. The controlled live proof must
also expose any GitHub behavior that differs from the offline provider model before cutover.

Primary references:
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- https://docs.github.com/en/rest/checks/runs
