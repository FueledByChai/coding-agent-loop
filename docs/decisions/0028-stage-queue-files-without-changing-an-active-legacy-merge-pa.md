# 0028 — Stage queue files without changing an active legacy merge path

Status: accepted, supersedes 0019
Date: 2026-10-26

## Context

Decision 0019 made draft pull requests and disabled auto-merge part of its legacy bootstrap.
That assumed the new queue handoff could become authoritative as soon as its files reached a
consumer. A controlled migration cannot make that switch atomically: the trusted workflow must
land before the App installation, protected controller state, ruleset and pilot can be verified.
RockBox PR #165 exposed the result. The v0.22.0 author and reviewer prompts would disable its
still-authoritative legacy auto-merge path while the new workflow was deliberately inert, leaving
green pull requests with no actor permitted to merge them. LK-ddt records the compatibility rule.

A first draft of this record made the prompts stop whenever a retained contract mentioned rollout
or a controller without naming its profile. The kit's own shared loop section mentions the
controller and nothing declared a profile, so that rule stopped every fresh install, which is
legacy by construction, and the kit itself, which runs `github-v1`. A reader of the kit's Project
rules could also take their shadow-journal and bootstrap wording for a legacy declaration and arm
auto-merge beside the live App. Every retained contract needs a profile an agent can determine
without guessing.

## Decision

Keep 0019's recorded merge order, one selected candidate, waiting-PR freeze, completed exact-head
review, independent acceptance, final-head CI and fresh final-gate verification. Change the pull
request handoff according to the project's merge profile:

- The profile is staged/legacy unless the Project rules declare `github-v1` active on a line of
  its own, `Merge profile: github-v1`. `Merge profile: legacy` states the default, and a contract
  with no such line, including one retained from before this record, is staged/legacy. The kit's
  shared loop section states this default.
- In staged/legacy, which includes a staged rollout whose queue files are installed and whose
  controller is not live, authors, backlog planners and reviewers preserve the project's existing
  draft, auto-merge and status publication procedure.
- In `github-v1`, authors open drafts and keep ordinary auto-merge disabled; the App owns
  selection, CI admission, the final gate and merging.
- Activation and rollback are explicit edits to that line, made in the runbook's cutover and
  rollback steps and recorded in the project's migration decision. Installed workflow, prompt or
  controller files, controller statuses and a running controller are never evidence that the
  profile changed: agents do not infer activation.
- Queue-aware prompts stop before changing a gate only when the declaration is contradictory or
  unreadable: more than one `Merge profile:` line in the Project rules, a value other than
  `legacy` or `github-v1`, `github-v1` declared while the Project rules describe a legacy gate
  agents operate (a coordinator-posted required status, armed auto-merge) as active, or
  staged/legacy in force while they describe the App controller as the live merge actor.
  Otherwise they follow the declared profile or the default. A check the operator alone arranges
  during migration, or keeps for rollback, is not a legacy gate agents operate: the Project rules
  name it as operator-only, and a declaration beside it is consistent.
- A fresh install's `AGENTS.md` is the kit's loop section, a placeholder Project rules declaring
  `Merge profile: legacy`, and the generated Beads block the whole-file copy used to carry; the
  kit's own Project rules, which declare `github-v1` for the kit's repository, never reach a
  project. `install.sh` and grill-project ask a new project for its profile and recommend the
  default.
- A project-required status wrapper owns every legacy status transition, including pending
  invalidation. If stale success cannot be reset through that sanctioned path, the coordinator
  disables and verifies auto-merge before stopping, so known-invalid evidence cannot merge.

## Alternatives

- Make installation the cutover: creates an interval with no functioning merge actor and makes
  rollback depend on editing every waiting PR.
- Always preserve auto-merge: lets a legacy request bypass the App after `github-v1` activation.
- Allow raw status writes around a required wrapper: defeats the consumer's chosen serialization,
  context and audit boundary.
- Stop whenever a contract mentions rollout or a controller without naming a profile (the first
  draft): the shared loop section itself mentions the controller, so every fresh install and the
  kit stopped, and an agent was left to read a profile out of prose.
- Infer `github-v1` from installed controller files, queue statuses or a running service: that is
  activation by inference, the failure this record exists to prevent.
- Default to `github-v1`: installing starts no controller, so a fresh project's pull requests
  would wait on a merge actor that does not exist.

## Consequences

Queue rollout needs an explicit retained-`AGENTS.md` contract change at activation and again at
rollback, and the runbook's cutover and rollback steps carry it. Generic prompts read both the
shared loop section and Project rules, and defer the mechanical draft/auto-merge/status commands
to the declared profile or the staged/legacy default, while retaining 0019's single-candidate and
evidence gates. A legacy coordinator that cannot neutralize stale success must fence auto-merge
and report the missing transition rather than continuing. A project whose controller goes live
before its declaration lands is treated as staged/legacy, so the cutover order matters:
repository auto-merge is disabled, then the declaration is merged by hand under the legacy
protection, then the update and `Queue merge gate` rulesets are applied, so the controller's
first live selection, the controlled candidate, comes after it. Once those rulesets are active
only the App can land a pull request, the declaration included. The kit declares its own profile
in its Project rules, and `install.sh` no longer copies those rules into a project.

The kit's own controller went live in the LK-e9y pilot before this record, so its declaration
lands after the fact, through the App. This record is the kit's activation record, on this live
evidence: LK-e9y closed on its controlled proof; pull requests #78, #82 to #84 and #86 to #88
merged by the App (`app/fueledbychai-merge-queue`); ruleset 23848482 makes the App (integration
5024825) the only updater of `main`, and ruleset 23848480, with no bypass actor, requires its
`Queue merge gate`; repository auto-merge is off; the legacy `ci.yml` is disabled and
`queue.yml` active; ruleset 23399949 no longer requires a status check. Decision 0005's account
of the kit's gating (23399949 requiring `Check (check.sh)`, `--auto` arming) therefore predates
the live gate; replacing it is a record of its own, since a record supersedes one record at a
time and this one supersedes 0019.

## What would show this was wrong

A project whose App controller merges while its contract declares or defaults to staged/legacy,
with agents arming auto-merge beside it, would show the default needs a machine fence, such as
the controller refusing live operation or the check failing until the contract declares
`github-v1`. Agents stopping on a contract that declares one known profile consistently would
show the contradiction test is too broad; agents proceeding on a contract whose Project rules
describe both profiles as live would show it is too narrow. A transactional installer that proves
workflow, credentials, service, protections and rollback before making any pull request mergeable
under the new authority could remove the staged profile. Evidence that a declared profile can
still leave two merge actors active would require a stronger cutover fence.
