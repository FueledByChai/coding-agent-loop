# 0005 — This repository's own merge gating is applied by hand and recorded, not checked

Status: accepted
Date: 2026-09-14

## Context

The kit documents, for a project, the two `gh api` commands that turn on merge gating: a PATCH
setting `allow_auto_merge`, `delete_branch_on_merge`, and the merge methods, and a POST of a
branch ruleset that requires the status the project's workflow reports. The kit is its own loop
project (0001), and it had applied neither. `gh api repos/FueledByChai/coding-agent-loop/rulesets`
was empty, `allow_auto_merge` was false, `allow_merge_commit` and `allow_squash_merge` were still
true, and `delete_branch_on_merge` was false, so nothing gated a merge here.

Two consequences were already visible. Both pull requests this repository had merged went in
mid-check: PR #19 at 19:44:26Z, five seconds into a run that started at 19:44:21Z and finished
green at 19:45:13Z, and PR #20 at 19:57:30Z, thirteen seconds into a run that started at
19:57:17Z and finished green at 19:58:06Z. And the second of those was
`gh pr merge 20 --auto --rebase`, which printed `✓ Rebased and merged pull request #20` — with
auto-merge disabled, `--auto` does not arm anything, so the flag the loop's hand-off depends on
did the opposite of what it says.

The ruleset to apply is `.github/ruleset.json`, not `ci/ruleset.json`: the two files differ by
one context and are not interchangeable. `ci/ruleset.json` is the template `install.sh` gives a
project, whose check lives under `scripts/`; this repository's check is `./check.sh` at the root,
and `.github/workflows/ci.yml` reports `Check (check.sh)`, which is what `.github/ruleset.json`
requires (LK-13).

Applying it raises a question the commands do not answer: what keeps it applied? Nothing in
`git` records the settings or the ruleset, so the state is invisible to every check here.

## Decision

This repository's own merge gating — the five repository settings and the branch ruleset in
`.github/ruleset.json` — is applied by hand, once, with the two `gh api` commands the README
already documents for a project, and the applied ruleset's identity is recorded in this record.
Nothing in the kit's check re-applies or verifies it: `scripts/ruleset-check.sh` answers whether
the ruleset and the workflow it pairs with name the same context, which is a different question
from whether the pair has been applied.

## Alternatives

- A check that calls the API and fails when a setting drifts: `./check.sh` is the kit's shipping
  surface and runs in every project that installs the kit, so the check would assert this
  repository's settings against a consumer's repository. It would also need a token with admin
  scope in CI, which a project's workflow does not have and should not be given to run a check.
- `scripts/apply-settings.sh` in the kit, run once per repository: `install.sh` and
  `loop-kit-sync.sh` copy `scripts/*.sh` into every project, so a script whose job is to PATCH a
  repository's settings would be shipped to repositories it must not touch, and it would still
  need the admin token.
- Record the applied ruleset id in `.loop.toml`: the config describes what the loop does and is
  read by every script; GitHub's state is not the loop's state, and a key nothing consults would
  go stale in exactly the way the comment it replaced did.
- Leave it undocumented: the state is invisible to `git`, so nothing distinguishes a ruleset
  never applied from one applied and later deleted. PRs #19 and #20 are what that costs.
- Give the repository a merge queue instead: GitHub's merge queue is not available on user-owned
  repositories. The ruleset's "up to date with the default branch" requirement plus auto-merge is
  the substitute the README already names.

## Consequences

The applied ruleset is id 23399949, `default branch: pull requests, green and up-to-date CI`,
enforcement `active` on `~DEFAULT_BRANCH`, requiring `Check (check.sh)` with
`strict_required_status_checks_policy: true` and allowing only rebase merges. The id is written
down here because nothing else in the repository names it: deleting the ruleset, or turning
`allow_auto_merge` back off, is silent until a pull request merges mid-check again.

`--auto` now arms, which is the half of the loop's hand-off that was missing: the merge policy
arms auto-merge and had nothing to arm. `delete_branch_on_merge` is on, so a merged pull
request's branch goes without anyone deleting it.

Applying stays a manual step, and this record is where its result is written down. That is a real
gap and it is deliberate: the pair's consistency is what the check can judge without a token, so
that is what the check judges. LK-06 extends the ruleset with the agent review's context, which is
now a PATCH or a re-POST of an applied ruleset rather than a first application — and it must not
land before something runs the review for this repository, or every pull request waits for a
status nothing produces.

## What would show this was wrong

The settings drift back — auto-merge off, the ruleset deleted — and a pull request merges
mid-check again. That would mean a setting applied by hand and read by nothing is not a setting,
and the answer is a check or a scheduled re-application rather than this record.

Or the kit grows a check that calls the API and catches the drift there, which would mean the
manual step was a placeholder and this record should have said so.

Or the recorded id stops matching the applied ruleset because someone re-applied it, and naming
the id here turns out to be a liability that a lookup should have held instead.
