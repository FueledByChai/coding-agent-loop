# 0027 — Require explicit permission for complete live ruleset inspection

Status: accepted
Date: 2026-09-22

## Context

The first protected V1 preflight for LK-e9y authenticated correctly and read the two live
rulesets, but GitHub omitted `bypass_actors`. GitHub documents that this field requires
write access to the ruleset. Administration read cannot establish the complete bypass
policy required by 0021. The queue stopped before service startup.

## Decision

Add an explicit protected-policy option, `ruleset_administration: "write"`. The default
installation-token request remains Administration read. Live operators must separately
approve and accept Administration write for the repository-scoped GitHub App before
selecting this option. Missing or malformed bypass lists stop preflight with a clear error;
never interpret an absent list as empty. Validate the full returned bypass lists unchanged.

The controller continues to perform only GET requests against rulesets, but this is a code
restriction, not a credential restriction. Administration write gives its App the ability
to alter repository settings and protections. The App must therefore be trusted with that
broader authority; keep the key and runtime inaccessible to authors, reviewers and CI.
The owner explicitly approved this broader authority for the existing coding-agent-loop
installation on 2026-09-22. GitHub confirmed the installed permission and kit-only scope.
This approval does not establish runtime activation or live pilot acceptance.

## Alternatives

- Keep Administration read: safe to leave stopped, but it cannot run this complete live
  bypass-policy verification.
- Pin an administrator-observed snapshot and compare `updated_at`: an experiment showed
  timezone differences and stale public reads; GitHub does not document the timestamp as
  a unique version guaranteed to change with every hidden bypass edit. This is not an
  equivalent replacement for inspecting the complete live list.
- Give existing agents the controller key or an administrative token: widens the author
  authority boundary without solving the visibility requirement more safely.

## Consequences

No permission is silently upgraded. Default configurations remain read-only; explicit
write configuration is tested for repository scope and unchanged other permissions.
Approval and installed permission verification precede a new protected runtime/preflight.
The kit pilot keeps legacy gates until its live migration evidence is complete. RockBox
access and rollout remain separate. Full review and actual CI evidence still bind every
candidate, and this permission alone grants no passing queue check.

## What would show this was wrong

Any unapproved token permission upgrade, absent bypass list passing preflight, ruleset
mutation by the controller, or author access to its key would refute this implementation.
A supported GitHub API exposing the complete list with narrower authority would justify
removing the write requirement.

Primary reference: https://docs.github.com/en/rest/repos/rules#get-a-repository-ruleset
