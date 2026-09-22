# V1 queue handoff for existing agents

For the governing review, coordination and CI rules, follow decisions
[0017](../decisions/0017-require-author-evidence-and-completed-head-review-before-acc.md),
[0019](../decisions/0019-plan-merge-order-and-separate-acceptance-from-final-status-p.md) and
[0020](../decisions/0020-request-ci-explicitly-and-reject-unrelated-labels-without-sk.md).
The V1 existing-agent procedure and its trust limits are defined in
[0026 in the reviewed controller release](https://github.com/FueledByChai/coding-agent-loop/blob/ea20eeccb07f8de74582a5d4438a562f3b67698a/docs/decisions/0026-use-existing-agent-acceptance-for-the-first-live-merge-queue.md).
The steps below are an operator walkthrough of those records, not a separate policy.

This guide describes the controlled coding-agent-loop pilot, not a completed rollout.
The reviewed controller release is installed separately while PR #78 remains open. The
commands below therefore use that installed release; do not assume this branch contains
the handoff helper. The operator must supply the trusted release path and App ID. On the
pilot Mac the verified release is:

```sh
QUEUE_RELEASE=/usr/local/libexec/coding-agent-loop/releases/ea20eeccb07f8de74582a5d4438a562f3b67698a
QUEUE_APP_ID=5024825
```

Run commands from the repository checkout. Substitute the actual PR number for `123`.
Use the agent's existing GitHub login. Never copy the controller's App key or private state.

## Author: finish review, then nominate

Address or dispute each finding with evidence, resolve the conversation only when addressed,
and obtain completed Codex review on the current head. A new push needs another completed
head review. Then nominate:

```sh
/usr/bin/python3 -I "$QUEUE_RELEASE/scripts/queue-handoff.py" --root "$PWD" --pr 123 nominate
```

Nomination is a request to join the durable queue, not acceptance or permission to merge.
Unchanged repeated nominations do not move a waiting PR ahead. No CI is started merely
by publishing this status. The controller may advance a selected PR only when all its gates
are satisfied; an already valid independent acceptance can make it eligible for queue CI.

## Author: refresh only the selected PR

Before refreshing a stale branch, verify its current selection:

```sh
/usr/bin/python3 -I "$QUEUE_RELEASE/scripts/queue-handoff.py" --root "$PWD" --pr 123 \
  --app-id "$QUEUE_APP_ID" selected
```

The command checks the App identity, active selection, exact PR head, base and attempt.
A failure means stop and inspect the queue; it does not authorize an override. Recheck the
remote head and base immediately before the project's permitted refresh procedure. Follow
that project's history rules; this guide grants no force-push permission. Verify the resulting
remote head, complete review again, and obtain fresh independent acceptance. The controller
waits for the existing author agent; it does not launch an author process in V1.

## Independent reviewer: bind acceptance to the finished revision

Read the ticket's intent and acceptance criteria, the diff, project rules, proof and current
review feedback. The author must not accept its own work. Post a substantive COMMENTED
GitHub review on the exact head, then inspect the resulting snapshot:

```sh
/usr/bin/python3 -I "$QUEUE_RELEASE/scripts/queue-handoff.py" --root "$PWD" --pr 123 inspect
```

After confirming that snapshot matches the assessment, use its `binding` and the submitted
review's URL:

```sh
/usr/bin/python3 -I "$QUEUE_RELEASE/scripts/queue-handoff.py" --root "$PWD" --pr 123 \
  --binding HASH_FROM_INSPECT \
  --proof-url https://github.com/FueledByChai/coding-agent-loop/pull/123#pullrequestreview-REVIEW_ID accept
```

The helper verifies the review belongs to the current login and head. It refuses changed
assessment evidence. The controller also checks the current head, base, criteria and review
binding before admission; changes require reassessment, not reuse of an old pass. Publishing
`Queue acceptance` is not the App-owned `Queue merge gate` and cannot itself merge a PR.

## Trust and pilot limits

The owner approved V1's shared-account workflow trust: author and reviewer are separate
agents following role rules, but they use the same permitted GitHub account. Credentials do
not enforce their independence. The controller's App key remains separate and protected.

Legacy required checks remain during migration. For the selected pilot PR only, the operator
must arrange the legacy check and independent `Agent review` status before publishing final
queue acceptance, so the App does not try to merge against an unmet legacy gate. Other PRs
remain waiting. This temporary overlap is not proof that duplicate CI has been retired.

Controller startup proves readiness to operate, not successful PR processing. LK-e9y owns
the three-PR ordering, restart, admission and migration evidence. This document does not
claim that proof, unattended author execution, or RockBox activation.
