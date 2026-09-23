# Trusted queue operator runbook

This is an opt-in runtime, not a deployed service. Do not retire legacy gates on the strength
of offline tests. `queue-controller.sh --self-test` is offline; `preflight` reads GitHub and
`tick`/`serve` can dispatch, publish checks, cancel and merge. The shadow CLI is unchanged.

## Identities and protected installation

Worker mode uses three OS identities: controller, author and independent reviewer.
The V1 profile below uses a protected controller plus existing agent workflows. A distinct HOME under
one shared UID is not isolation. Install reviewed kit files under a root/controller-owned
path such as `/opt/coding-agent-loop`, protected through every ancestor. Keep a trusted
observation mirror with Beads under the controller identity; never execute PR code there.

Before any privileged controller command, including `preflight`, the trusted service setup
must verify each executed or imported source file as required by 0021; checking its parent
directory alone is insufficient. Validate the shell/Python entry points, `review-workers.py`,
`merge-queue.py` and the complete reviewed release inventory against a pinned manifest or
archive. Verify expected bytes, root/controller ownership, no group/other write permission,
no symlinks, and protected ancestors before Python or Bash loads any of those files. Refuse
to enable or upgrade the service when a file fails. Keep the bootstrap verifier and its
interpreter inside the operator's trusted installation boundary as well. Runtime path checks
cannot establish the trust of code that has already executed. The service example below
assumes this installation verification has passed and those files remain protected.

Launch the shell wrapper directly (its fixed privileged-mode Bash ignores startup hooks),
or use `/usr/bin/python3 -I` as in the service unit below. Do not invoke it through an
ambient `bash`/`python3` search or drop Python isolated mode at the privileged boundary.
The wrapper starts the fixed interpreter with an empty environment plus the system PATH.
The direct Python entry also clears its environment before importing TLS or helper modules.
Caller proxy, certificate, OpenSSL, token and HOME overrides are discarded; configure the
controller account's registered home directory itself. Custom observation tools still use
the validated private `read_path`, and receipt reads use the configured reviewer HOME below.
Run the existing author/acceptance guardian under its configured service boundary. Author
fixes and completed Codex review still precede independent acceptance (0017–0018).

Create/install a dedicated GitHub App only for the selected repository. Grant Checks, Contents,
Actions and Pull requests write; Metadata read. GitHub returns a ruleset's `bypass_actors`
only to callers with write access to that ruleset. Therefore live protection verification
requires explicit operator approval of Administration write (0027), both in the App installation
and as `"ruleset_administration": "write"` in protected policy. The default token request
remains read-only and preflight stops if GitHub omits the bypass list. This broader permission
also lets the App modify repository settings and rules; the controller's ruleset adapter only
performs GET requests, but credential authority is wider than that code behavior. Keep its
key isolated and scope installation to the pilot repository. Do not substitute an absent
bypass list with an empty list or treat a cached snapshot as current verification.
See [GitHub's ruleset API](https://docs.github.com/en/rest/repos/rules#get-a-repository-ruleset).
Store its PEM and policy
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

For `worker-receipt`, add a top-level `read_path` to that **worker policy**, for example
`"read_path": "/opt/queue-tools:/usr/bin:/bin"`. It must contain protected `gh` and `bd`
executables and any tools Beads needs, with the same path protections described below.
The receipt reader uses `roles.acceptance.env.HOME` for the reviewer's read-only GitHub login
store; protect that home through its ancestors too. Inherited tokens and other environment
settings are discarded. Both the shell wrapper and isolated Python entry point use these
explicit settings for the Beads sync and both evidence observations. Configure this before
running acceptance jobs: the worker policy hash binds it, so older receipts become stale.

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
  "ruleset_administration": "write",
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

## V1 with existing agents

Decision 0026 adds `handoff: "github-v1"` to private controller policy. Replace the worker
`acceptance`, `refresh`, `reviewer_uid` and `reviewer_identity` settings with:

```json
{
  "handoff": "github-v1",
  "shared_account_workflow_trust": true,
  "nominator_ids": [7119529],
  "acceptance_actor_ids": [7119529]
}
```

Use the operator-approved numeric GitHub actor IDs. The App additionally needs **Commit
statuses: read**, never status-write. Agents use their existing `gh` login. The controller
still needs protected code, mirror, journal, key, tools, workflow and rules. This mode uses
no worker journal, sudo bridge or model-launch adapter. Shared-account author/reviewer
separation is procedural: authors must not self-accept, but this profile cannot prevent an
allowed account from impersonating either role. The operator must explicitly accept that trust.

After completing Codex feedback, the author nominates the PR:

```sh
scripts/queue-handoff.sh --pr 123 nominate
```

The controller discovers nominations on each poll and preserves their order in its journal.
Duplicate nominations retain position. Retired requests need explicit operator re-enqueue.
Nomination grants no gate authority and starts no CI by itself.

A stale branch may refresh only after verifying the current App selection:

```sh
scripts/queue-handoff.sh --pr 123 --app-id 5024825 selected
```

The result names the attempt, expected head and base. Missing, completed, foreign-App or stale
selection fails. Verify those remote revisions immediately before the project's sanctioned
refresh and its resulting head afterwards. RockBox uses `scripts/refresh-ticket.sh`; no new
force-push path is authorized. Finish review again on the resulting head. The controller
waits without starting an agent or replaying refresh. A changed base blocks the attempt.
An unavailable author leaves a visible waiting lane, not a proven unattended worker service.

The independent reviewer assesses all acceptance criteria and posts a substantive COMMENTED
review, then inspects the post-comment snapshot:

```sh
scripts/queue-handoff.sh --pr 123 inspect
scripts/queue-handoff.sh --pr 123 --binding HASH_FROM_INSPECT \
  --proof-url https://github.com/OWNER/REPO/pull/123#pullrequestreview-REVIEW_ID accept
```

Assess the intent, criteria, diff, rules and feedback before accepting; `inspect` is not an
assessment. The command verifies the binding and that the cited assessment belongs to the
current login and exact head. It publishes `Queue acceptance`, not a merge gate. Unchanged
publication reuses its status. The controller checks the latest status and allowed actor;
changed head/base/criteria/feedback or a later failure/pending status invalidates acceptance.
CI progress alone does not invalidate it.

At cutover, existing author and independent reviewer automations adopt these commands.
Replace the captain's post-CI acceptance and merge duties with pre-CI acceptance; keep repair
in the author workflow. Preserve the legacy captain until the migration proof below succeeds.
The stronger hosted-worker mode remains separate and retains its original identity rules.

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
Live verification requires the explicitly approved Administration-write authority (0027).
This runtime only reads rulesets with GET requests; the credential itself can change them.
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
Before any merge-gate or CI-admission check creation intent or dispatch intent, a source or
feedback change between reads waits for the next poll. The controller retains the selected
attempt and queue order, discards cached acceptance, and requires a complete stable snapshot,
completed head review and matching independent acceptance before continuing. A first torn
observation reports `observing` without allocating an attempt; its request remains first.
Reaction counters and profile display fields do not change the review evidence. Actual review
text, actor, verdict and thread changes do. An active attempt records `observation_retries`.
This retry never changes the original external-refresh selection or base: a subsequent stable
changed base still blocks, as does a changed head that remains stale. Uncertain worker refreshes,
ordinary validation/provider failures, and changes after authority intent retain the existing
fail-closed behavior. Automatic polling is not permission to replay an uncertain mutation.
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
The workflow admission check also reads to the end of its inventory, rejecting duplicate
matches even on late pages before any PR checkout or full check runs.

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
