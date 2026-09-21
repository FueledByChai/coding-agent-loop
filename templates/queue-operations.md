# Trusted queue operator runbook

This is an opt-in runtime, not a deployed service. Do not retire legacy gates on the strength
of offline tests. `queue-controller.sh --self-test` is offline; `preflight` reads GitHub and
`tick`/`serve` can dispatch, publish checks, cancel and merge. The shadow CLI is unchanged.

## Identities and protected installation

Use three OS identities: controller, author and independent reviewer. A distinct HOME under
one shared UID is not isolation. Install reviewed kit files under a root/controller-owned
path such as `/opt/coding-agent-loop`, protected through every ancestor. Keep a trusted
observation mirror with Beads under the controller identity; never execute PR code there.
Launch the shell wrapper directly (its fixed privileged-mode Bash ignores startup hooks),
or use `/usr/bin/python3 -I` as in the service unit below. Do not invoke it through an
ambient `bash`/`python3` search or drop Python isolated mode at the privileged boundary.
The wrapper fixes PATH and removes shell/Python startup overrides before using the fixed
system interpreter; custom observation tools still use the validated private `read_path`.
Run the existing author/acceptance guardian under its configured service boundary. Author
fixes and completed Codex review still precede independent acceptance (0017–0018).

Create/install a dedicated GitHub App only for the selected repository. Grant Checks, Contents,
Actions and Pull requests write; Administration read; Metadata read. Store its PEM and policy
as controller-owned mode 0600 files below a mode 0700 private directory. Do not place either in
Git, Actions secrets, worker environments or the author/reviewer homes. The controller uses
short-lived installation tokens scoped to this repository and never passes them to adapters.
`app_actor_id` is the App bot's numeric user id, not the App id or installation id.

Configure exactly one absolute, protected wrapper executable per adapter, with no command
arguments. Put interpreter, script, config and UID-switch arguments inside the reviewed
wrapper; an interpreter followed by an external script path is rejected. Adapter environments
allow only `PATH`, `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE` and `TZ`; PATH entries and HOME must be
protected too. Interpreter/preload variables such as `BASH_ENV` and `PYTHONPATH` are rejected.
Use a narrowly allowed `sudo -n -u`
command or a comparably isolated service boundary. The acceptance wrapper runs the shipped
`queue-controller.py --root ... --state ... --policy ... worker-receipt` command **as the
independent reviewer**, with that reviewer's existing worker policy, journal and read-only
GitHub identity. It compares fresh GitHub/Beads evidence with the requested binding, validates
an existing completed acceptance job, and returns no App authority. No caller-provided verdict
is accepted. Missing acceptance holds the candidate; the separate worker service prepares/runs
review jobs. It does not cause the gate service to execute an AI worker with App credentials.

The refresh wrapper receives repository, PR, ticket, expected head/base and attempt on stdin.
Under the author's durable guardian, verify exclusive PR/worktree ownership and both remote
SHAs, then use the project's sanctioned refresh helper; request completed Codex review of any
new head. Return JSON `{"stopped":true,"head":"<full resulting SHA>"}` only after proving the
worker group stopped and the remote head matches. Conflicts, timeouts or uncertain stop proof
must fail. Never implement the wrapper with an unguarded force-push or update-all call.

Example policy (replace every example, inspect the resulting private file):

```json
{
  "repo": "owner/project", "base": "main",
  "state_dir": "/var/lib/queue-gate/state",
  "app_id": 123, "installation_id": 456, "app_actor_id": 789,
  "private_key": "/etc/queue-gate/app.pem",
  "workflow_id": 1011, "workflow_path": ".github/workflows/queue.yml",
  "workflow_sha256": "SHA256_OF_COMPLETE_RENDERED_WORKFLOW",
  "ci_job": "Queue full check", "ruleset_ids": [1213, 1415],
  "author_uid": 1002, "reviewer_uid": 1003,
  "reviewer_identity": "independent-acceptance-v1",
  "read_path": "/usr/local/bin:/usr/bin:/bin",
  "acceptance": {"command": ["/usr/local/libexec/queue-acceptance"],
    "env": {"PATH":"/usr/bin:/bin","HOME":"/var/lib/queue-gate"}, "timeout": 180},
  "refresh": {"command": ["/usr/local/libexec/queue-refresh"],
    "env": {"PATH":"/usr/bin:/bin","HOME":"/var/lib/queue-gate"}, "timeout": 900}
}
```

The controller validates configured UID separation and protected paths. Every `read_path`
entry must be absolute, nonempty and protected through its ancestors; the resolved `gh` and
`bd` binaries must also be protected, including symlink targets. Validation happens before
requesting an App token or executing observation tools. Use service-managed tool installations
instead of author/reviewer-owned package-manager directories. It cannot prove an
operator-written wrapper actually crosses that boundary: inspect the wrapper and sudo policy,
and demonstrate that the author cannot read the key or alter the controller before activation.
Do not clone the policy/key/journal to a second active host. Only one canonical journal/service
owns a lane. Back up the stopped journal and audit trail together; do not reset it to retry CI.

## Workflow and rules

`loop/templates/ci/queue-controller.yml` is a **complete optional workflow**, unlike the six
stack snippets beside it. Render `__QUEUE_APP_ID__` to the dedicated numeric App id. Add the
project's pinned toolchain, Beads installation/bootstrap and other setup after admission;
use the configured full check as the `Full check` step. Preserve those two step names, the job
name, read-only permissions, exact-head checkout and `persist-credentials: false`. Pin the
complete resulting file's SHA256 in private policy. Leave unrendered placeholders fail-closed.
Never execute a helper from the PR before admission. This workflow's dispatch job does not
replace a legacy PR-required Actions context by itself; the App check is the new required gate.

Configure two active branch rulesets with exact include `["refs/heads/<base>"]`, no excludes:

1. Restrict updates (`update`), with sole bypass actor
   `{"actor_id":<APP_ID>,"actor_type":"Integration","bypass_mode":"always"}`.
2. No bypass actors; deletion and non-fast-forward protection; pull request with rebase-only
   methods and resolved conversations; strict required status checks containing
   `{"context":"Queue merge gate","integration_id":<APP_ID>}`. Retain any existing required
   human/security checks. **Never grant this App a bypass on this second ruleset.**

Disable repository auto-merge and reconcile existing requests before controlled operation.
The App lacks administration-write permission; this runtime never weakens or edits rulesets.
`preflight` reads both configured rulesets, auto-merge setting, active workflow ID/path mapping
and full workflow bytes. Admission check external IDs are versioned SHA256 digests of the
complete run/head/base/App identity, avoiding repository-name dependent provider limits. Existing
`ruleset-check.sh` still validates legacy job/context pairs. It cannot validate an external App
check; use controller `preflight` for this additional pair, keeping legacy checks during migration.

## Supervision and recovery

Example systemd unit, after preparing actual accounts, mirror, adapters and private policy:

```ini
[Unit]
Description=One-candidate merge queue
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=queue-gate
Group=queue-gate
WorkingDirectory=/var/lib/queue-gate/mirror
ExecStart=/usr/bin/python3 -I /opt/coding-agent-loop/scripts/queue-controller.py --root /var/lib/queue-gate/mirror --state /var/lib/queue-gate/state --policy /etc/queue-gate/policy.json serve
Restart=on-failure
RestartSec=15
KillMode=control-group
UMask=0077
[Install]
WantedBy=multi-user.target
```

Do not enable `NoNewPrivileges` with a sudo-based adapter; it prevents the required UID switch.
A macOS installation needs an equivalent launchd service under the dedicated account, with
protected paths and process-group stop proof. Installing the kit does not install either service.

Use the same `--root`, `--state`, `--policy` prefix for `preflight`, `enqueue <PR>`, `status`,
`tick`, `serve`, `retry --reason <reason>`, and `retire-request <PR> --reason <reason>`. Enqueue order is durable; only its first PR can
refresh or dispatch. The lock spans every observation/mutation within a tick, including network
calls. It has no timeout-based takeover. Polls are 15 seconds. Supervisors may restart the
process, but saved mutation intent prevents duplicate dispatch/refresh/merge/check creation.
A lost check-creation response stays unknown until its original check appears; stale inventories
do not cause another create request. If evidence changes meanwhile, CI cancellation proceeds
even while check revocation is waiting for visibility. Do not retire that attempt until the
unknown check is reconciled. A creation that never reached GitHub requires operator
reconciliation; elapsed time does not authorize another POST.

`status` reports the active attempt and ordered pending requests. If an unadmitted queued PR
is closed, made draft, or becomes unobservable, the service retains its request rather than
assuming a provider failure means it was merged. The operator may use `retire-request` with a
reason to retire that request and unblock later candidates. This command performs no remote
mutation and refuses any request with an active attempt, even a blocked one; it cannot release
a running worker or CI slot. The retirement is recorded in the audit journal. After restoring the PR, an explicit `enqueue`
request adds it back at the tail; duplicate requests for a still-pending PR retain their position.

Dispatch discovery uses the persisted dispatch time (with a small clock-skew allowance) and
base SHA, so old workflow history cannot bury the current attempt. Missing legacy dispatch
timestamps fail closed for reconciliation. Dependency lookup stops as soon as every required
naming commit is found. Pagination has no fixed history ceiling and rejects repeated pages.

A blocked attempt retains the lane. `retry` retires it only after actual CI stop is verified
(or no dispatch/uncertain refresh ever occurred); it retries the same PR with a new identity.
A successful or uncertain merge stays in `merging`: later ticks reconcile landed PR, ancestry
and tree evidence without replaying the merge or admitting the next PR. Delayed reads do not
permanently block it. An uncertain dispatch with no discovered run, an uncertain refresh, or a
merge that never becomes provably landed remains held for operator reconciliation. Do not delete state or manually release it because
time elapsed. Review the journal, provider event and guardian process evidence first. Recovery
for an uncertain refresh/merge currently requires an operator adapter extension; the runtime
intentionally has no unsafe force-release command. Report that limitation rather than silently
marking the ticket or candidate done.

## Controlled migration evidence

Retain exports of original settings, rulesets, workflow bytes and automation configuration.
Install the new workflow through a reviewed PR while legacy protection still applies. Register
the App check and add its expected-source requirement and exclusive updater rule. Test a
controlled candidate with **both** old and new checks, accepting one-time duplicate validation
for migration. Preserve project deployments and distinct security checks.

Record three PR identities/order, the unchanged heads of both waiting PRs, no waiting run or
refresh, independent acceptance binding, actual admitted run/job/step ids, App check source/id,
expected-head merge response and landed tree/ancestry. Kill/restart the supervisor while CI
runs and prove it reuses that run. Send unauthorized, duplicate, stale-head and rerun requests;
prove they stop before `Full check`, never publish a passing gate and do not release the lane.
Exercise reopened feedback and changed base before merge. Retain the old/new successful
contexts on the same controlled head and the final live ruleset reads.

Only after that evidence exists, propose the reviewed removal of duplicate push/label full
builds and the exact legacy captain automation. Verify the resulting active workflow inventory,
required contexts and service health before the next candidate. Rollback restores the saved
legacy workflow/check/captain configuration before disabling the new gate. Do not leave an
App-only gate required while its controller is offline and claim migration succeeded.

This runbook is not evidence that migration happened. LK-e9y remains unfinished until its
controlled live proof and migration verification are recorded; consumer adoption is RB-g6do.
