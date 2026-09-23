# Controlled proof of automatic observation recovery

Use this procedure to validate the LK-v4s controller repair under the existing-agent
profile in [decision 0026](../decisions/0026-use-existing-agent-acceptance-for-the-first-live-merge-queue.md).
It is a validation procedure, not a claim that a checkout or fixture deployed the repair.
Use only the kit pilot and synthetic review text; do not expose credentials or alter protections.

## Arrange a real selected refresh

1. Have a reviewed predecessor PR and the repair PR ready on the same current main revision.
   Record their full heads, current main SHA and workflow-run inventory. Install the independently
   reviewed repair release through the protected operator procedure while the queue is idle;
   verify the installed files, service revision and unchanged journal history.
2. Nominate the predecessor first and repair second. Publish independent acceptance only for
   the predecessor, bound to its final reviewed snapshot. Let the App run its single CI and
   verify the merge. The waiting repair PR must retain its original head and have no CI.
3. Read the App's current selection for the repair PR. Verify its head and new base before the
   author uses the project's sanctioned single-candidate refresh. Never update all branches.

## Exercise changing review evidence before admission

Withhold acceptance while exercising the repair PR. During the selected refresh and observer
reads, create or edit one clearly marked synthetic validation comment on that PR. Use a bounded
sequence (at most 20 edits over at most 90 seconds), then stop and leave a final stable marker.
Record its identity and timestamps; do not post comments on unrelated PRs or after admission.
If no between-read race is observed, report the live proof as inconclusive rather than passed.

The protected controller's public log must show `observation_retries` increasing on the same
selected attempt, followed by resumed observation/review without operator retry or restart.
The pending order must remain unchanged and no CI may start before fresh independent acceptance.
A source read can temporarily report `observing` before allocating an attempt; this alone does
not prove recovery of the selected-refresh attempt. Retain the selected attempt evidence.

Complete Codex review on the refreshed full head, address all findings, finish local validation,
and stop changing feedback. An independent reviewer records the final assessment and uses a fresh
handoff binding to publish acceptance. The App must admit one run, verify successful admission
and the full check, merge the expected head, and confirm landed content before releasing the lane.
Record the run/attempt identities, accepted and landed trees, merge actor and final queue state.

## Preserve the failure boundary

This proof does not authorize retrying an uncertain gate creation, dispatch, worker refresh or
merge. Stable changed bases during an external refresh still block; so do ordinary validation
failures. Source changes after gate/admission creation intent or dispatch retain the lane and
revoke authority. Offline regression tests exercise those unsafe boundaries; do not advance
main during live CI merely to reproduce them. LK-v4s owns the final live acceptance evidence.
