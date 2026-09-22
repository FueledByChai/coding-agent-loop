# Move the V1 queue controller to another host

The Mac is the first host, not a permanent dependency. The controller is a Python process
with a private policy, Git/Beads observation replica, GitHub App credentials and SQLite
journal. Existing author and reviewer agents communicate through GitHub. A server move
does not require those agents to use the controller's host or coding harness.

This is an operator procedure, not evidence that a move has been performed. LK-e9y owns
live rollout acceptance. Use the separately reviewed installed release during the kit pilot;
this documentation PR does not supply or activate that runtime.

## Establish one stopped source

1. Record the loaded source revision, file hashes, service identity, policy, workflow ID/hash,
   App installation and repository scope, active protection rules, and canonical state path.
   Save the existing host's service configuration and required checks for rollback.
2. Let the active attempt complete and reconcile its final PR/tree/ancestry evidence. If its
   outcome is uncertain, stop the move and investigate. Do not discard a held attempt to move.
3. Stop and disable the old controller through its supervisor. On the pilot Mac, unloading
   `system/com.fueledbychai.merge-queue.kit` with `launchctl bootout` stops the loaded job;
   also disable that label or otherwise prevent automatic loading on reboot. Verify the
   controller and any controller-owned adapter processes have stopped. Check GitHub for
   unfinished admitted CI before proceeding.
4. Obtain a final canonical status and confirm no active attempt. Do not run `serve` or
   `tick` to obtain this status. Prevent other operators or automation from restarting the
   old service during the move.

A local file lock is not a distributed lease. Two machines must never operate copies of
this queue at the same time, even if both copies have identical paths and credentials.

## Copy consistent state and protect the destination

Take a SQLite-consistent backup of `controller.sqlite` using SQLite's backup API while the
source service is stopped; do not copy only the main database file while ignoring a possible
WAL. Run `PRAGMA integrity_check` on the backup. Retain the full ordered request, attempt,
lane and event history plus any other private state needed by the configured profile.
Record a checksum and keep the backup private. Never add credentials or private state to Git.

Provision a dedicated non-login controller identity on the destination, separate from the
author/reviewer identities. Install the same reviewed runtime bytes and trusted tool versions
into protected directories. Configure the actual Python path and a supervisor appropriate to
that server, such as systemd on Linux. Verify the key, policy, runtime, journal and all their
ancestors satisfy the runtime's ownership and access checks. Give only the controller access
to its App key, private home and state; CI must not receive them.

Restore and verify the journal with the queue order and audit history intact. Re-create a
private read-only observation replica and fresh Beads data using the documented operator
setup. Do not register a different lane against the restored journal. Adjust host-specific
paths, numeric identities and trusted tool paths only while no attempt is active; changes
to implementation or policy invalidate old admission evidence. Preserve the repository,
App identity, approved permission scope and expected workflow/protection configuration.
The destination must explicitly request the approved Administration-write scope needed to
read complete bypass lists; runtime GET-only behavior does not narrow that credential's
technical authority.

## Verify, then enable one host

Before starting the destination service, verify the archive/file hashes, protected account
and paths, SQLite integrity, pending order and empty active slot. Run controller `preflight`
as its dedicated identity against the real repository. It must validate complete rulesets,
expected App authority, disabled ordinary auto-merge and the pinned active workflow.
Compare the configuration with the saved source evidence; do not weaken protection to pass.

Confirm the old service remains disabled, then enable exactly one destination service.
Observe canonical status, provider evidence and a controlled candidate through admission,
CI and verified landing. Keep the source backup and service definition until that validation
is complete. A running supervisor or successful authentication alone is not migration proof.

## Roll back without losing protection or queue history

If the destination has processed any requests, do not resume a stale source backup. First
stop the destination, reconcile uncertain outcomes and unfinished CI, and preserve its latest
consistent journal and audit history. Transfer that authoritative state through the same
stopped-host procedure before enabling the original host. If an active attempt cannot be
safely reconciled, keep both hosts stopped and investigate; do not create a second owner.

Host rollback does not require removing repository protections. A separate workflow rollback
must restore the saved legacy workflow, required contexts and reviewer/coordinator process
before removing queue gates. Retain the exclusive updater restriction or equivalent protection
through the transition. Verify active rules and actual successful checks before merging again;
never create an unprotected default-branch interval.
