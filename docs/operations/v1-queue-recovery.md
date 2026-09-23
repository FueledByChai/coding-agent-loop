# V1 queue observation and recovery

This guide applies to the separately installed V1 controller used by the kit pilot. It does
not claim that restart recovery has been proven live; LK-e9y owns that evidence. The
operator uses the installed, reviewed release and canonical private journal. Agents do not
receive its App key. Repository checkout files are not substitutes for the protected runtime.

The governing live recovery decision is [0021 in the reviewed controller release](https://github.com/FueledByChai/coding-agent-loop/blob/ea20eeccb07f8de74582a5d4438a562f3b67698a/docs/decisions/0021-fence-live-ci-admission-and-merge-authority-with-a-dedicated.md),
with the existing-agent V1 profile defined in [0026](https://github.com/FueledByChai/coding-agent-loop/blob/ea20eeccb07f8de74582a5d4438a562f3b67698a/docs/decisions/0026-use-existing-agent-acceptance-for-the-first-live-merge-queue.md).
Those records are also present in the kit after PR #78 merged.
The instructions below apply their recovery rules; this guide introduces no new policy.

## Observe before changing anything

On the pilot Mac, inspect launchd without changing the service:

```sh
launchctl print system/com.fueledbychai.merge-queue.kit
```

The public diagnostic log is `/usr/local/var/coding-agent-loop/kit-monitor/controller.log`.
An idle tick prints `null`. Launchd running and idle output prove neither a successful merge
nor a currently passing protection check. Canonical status comes from the controller journal,
using administrator access to the controller identity. Replace the example release below
with the exact release in the loaded service's `ProgramArguments` before running it:

```sh
sudo -H -u _loop_gate /usr/bin/python3 -I \
  /usr/local/libexec/coding-agent-loop/releases/ea20eeccb07f8de74582a5d4438a562f3b67698a/scripts/queue-controller.py \
  --root /usr/local/var/coding-agent-loop/kit/mirror \
  --state /usr/local/var/coding-agent-loop/kit/state \
  --policy /usr/local/etc/coding-agent-loop/kit/v1-policy-admin-write.json status
```

Use the same runtime and `--root`, `--state`, `--policy` prefix for the commands below.
The operator must confirm these paths match the currently loaded service. Status reports
`active` and the pending `requests`; use the active attempt's identity and saved run when
checking GitHub. Preserve the journal, policy, source revision and provider evidence.

## Restart is not retry

An ordinary supervisor restart resumes the same journal and attempt. Do not enqueue a
replacement attempt, clear files or rerun CI just because the controller process stopped.
On this Mac, an operator-approved restart of the loaded service is:

```sh
sudo launchctl kickstart -k system/com.fueledbychai.merge-queue.kit
```

Before and after, record the active attempt, head, base and run identity. Confirm launchd
returns to running, the journal retains the same attempt, and no duplicate run is created.
A process restart alone is not sufficient proof. Only one service may own this lane; its
file lock is local to the host and does not coordinate two servers.

The runtime persists intent before dispatch, check creation and merge. A lost response is
reconciled against GitHub on later ticks. It does not blindly repeat a mutation. A missing
or ambiguous provider result holds the lane for reconciliation; elapsed time grants no
permission to release it. A merge accepted by GitHub still needs landed PR, ancestry and
tree verification before the next candidate is admitted.

## Supported recovery commands

With the LK-v4s repair installed, changing source/review evidence between reads before gate
creation or dispatch waits automatically for a stable observation. The same selected attempt
and queue position remain; cached acceptance is discarded. A first unstable read reports
`observing` with no active attempt yet. Do not restart or run `retry` for this ordinary wait.
Confirm the installed release carries the repair before relying on this behavior.

Stable changed bases during external refresh, invalid evidence, uncertain mutations and
post-admission changes still require the existing blocked-attempt handling below. Reaction
counts alone do not invalidate evidence; edited findings, review verdicts and thread state do.

For a blocked attempt, diagnose its reason first. With the canonical command prefix:

```sh
# Replace the reason with the actual diagnosis and corrective action.
# ... retry --reason "verified cause corrected; previous run is stopped"
```

The actual subcommand is `retry --reason REASON`. It accepts only a blocked attempt and
requires proof that dispatched CI has stopped. It retires that attempt and leaves the same
PR at the front for a new attempt. It does not waive review, acceptance, head or base checks.
Do not treat cancellation requested as cancellation completed.

For a closed, draft or otherwise invalid waiting PR with no active attempt, use
`retire-request PR --reason REASON`. This records an audited retirement and refuses active
attempts, including blocked ones. It does not cancel or release active work. After restoring
that PR, explicit `enqueue PR` places the retired request at the tail; duplicate pending
requests retain their existing position.

Unknown dispatches, check creation, refresh outcomes or merges may require operator
reconciliation beyond these commands. There is no safe force-release command. Preserve the
hold and investigate rather than deleting state, modifying SQLite rows, inventing a success
status, or starting another host. Report the limitation if the evidence cannot be established.
