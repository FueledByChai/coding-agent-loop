# Changelog

What shipped, by release: the commits that carry a ticket id between two tags, with the
ticket text read from Beads (scripts/release-notes.sh --archive).

## v0.22.0 — 2026-09-22 (v0.21.1..HEAD)

### scripts (LK)

- **LK-6yn** Persist a fenced merge queue and inspect GitHub in shadow mode — 2026-09-20 · ca4e6c9 (persist a fenced shadow merge queue)
- **LK-sm4** The kit has no prompt for the author's side of a review conversation — 2026-09-20 · b8133c2 (carry authors through evidence-backed review responses)
- **LK-3pg** Run author repair and acceptance workers from durable queue jobs — 2026-09-20 · 6e55a5c (run durable author and acceptance workers)
- **LK-og8** Repair reviewer cleanup and author receipt contract after PR73 merge — 2026-09-20 · 9cb57c7 (recover missing review trees and describe resulting author heads)
- **LK-9r7** A day's pull requests have no merge order, so every merge re-tests all the others — 2026-09-20 · cedcb17 (plan merge order and defer final gates to the selected candidate)
- **LK-kpe** Bind worker acceptance receipts to ticket dependencies and labels — 2026-09-21 · 0e56f7a (invalidate worker evidence when ticket graph metadata changes)
- **LK-412** The CI skeleton runs the whole check on every push, and the obvious way to narrow it is a trap — 2026-09-21 · eea5785 (request consumer CI explicitly without skipped green checks)
- **LK-pge** Install the kit queue CI workflow while retaining legacy gates — 2026-09-22 · 84a0dc9 (bootstrap App-admitted queue CI under legacy protections)
- **LK-evm** Document V1 nomination and independent acceptance for the live queue pilot — 2026-09-22 · b5525e1 (document existing-agent queue handoff for the pilot)
- **LK-d50** Document queue restart and blocked-attempt recovery for the live pilot — 2026-09-22 · c9696e0 (document queue restart and blocked-attempt recovery)
- **LK-4l2** Document portable queue host migration and rollback for the live pilot — 2026-09-22 · 4e457c6 (document portable queue host migration and rollback)
- **LK-e9y** Enforce one admitted CI candidate with a dedicated GitHub App gate — 2026-09-21 · dd0e7cf (add opt-in trusted App admission and merge controller)
- **LK-af3** Document the controlled automatic-recovery queue proof — 2026-09-22 · c6d4fbf (document the controlled observation recovery proof)
- **LK-v4s** Retry changing pre-admission review snapshots without manual queue recovery — 2026-09-22 · e803c9a (retry changing observations before CI admission)

### scripts (LK): archived tickets

#### LK-6yn Persist a fenced merge queue and inspect GitHub in shadow mode — 2026-09-20 · ca4e6c9

Implement the first executable increment of the owner-approved merge queue. A reusable Python/SQLite controller records candidate identity, review and acceptance evidence, FIFO eligibility, one fenced promotion slot per repository and base branch, and an audit log. Ship a read-only GitHub scan and JSON status/plan commands; shadow mode must not rebase, comment, request CI, post checks or merge. Beads remains task tracking. This foundation serves LS-03 and enables LK-9r7, LK-sm4, LK-412 and the RockBox consumer RB-g6do. Follow-up adapters supply trusted acceptance, worker automation and an App-issued required gate.

**Done when:** scripts/merge-queue.sh --self-test proves three-PR ordering with dependency blockers, exact head and acceptance revision invalidation, duplicate and out-of-order observations, restart persistence, atomic competing claims, fenced stale-worker refusal, explicit release and failure recovery, and no automatic lease stealing. A stub gh proves paginated read-only scanning, complete review-thread reads, errors fail closed, and no GitHub mutations. The installed script and helper pass the same tests in install.sh; the full kit check passes. A live read-only scan of the consumer is recorded without changing any workflow or merge protection.

#### LK-sm4 The kit has no prompt for the author's side of a review conversation — 2026-09-20 · b8133c2

review-prs.md is the reviewer's side: it reads a diff and posts a status. next-ticket.md is the
author's side up to the pull request. Nothing in the kit covers what happens between them - the
author reading a review finding and deciding what to do with it.

That gap is where consumer projects lose the work. In rockbox-ghl the step exists as a chat
prompt somebody typed into an orchestrating agent ("monitor the PRs for unresolved convos on each
CI run until there are no unresolved convos"), which is why a reviewer existed, a gate existed,
and the responder did not. The measured shape: a review app reviews every push, so a fresh head
usually carries unresolved threads before anybody has read them; the project's own readiness gate
then counts them and refuses to post the review status, and the pull request is green on CI and
unmergeable with nothing in the repository that says who clears it.

What the prompt has to decide, and what makes it more than a summary of review-prs.md:

- The three answers to a finding are not the same act: a fix lands as a commit; a dispute is a
  reply that says why the reading is wrong; a real finding outside the ticket's scope becomes its
  own ticket and gets named in the reply. Without that, an author either chases something the
  ticket does not cover or silently drops it.
- A reply that answers a finding is not the same as resolving it, and a resolve on a head that
  then moves is worth nothing. The prompt has to connect the answer to the head it is about.
- Resolving a thread is a claim that somebody read it. The prompt should say who may make that
  claim and when, since a reviewer that can resolve its own findings is not a reviewer.


**Done when:** A prompt exists for the author of a pull request: it reads the open review threads on the head, decides for each whether to fix it, dispute it, or file it as its own ticket, says what it does instead of arguing with a finding it cannot disprove, and leaves the head and its status consistent with what it decided. The kit's prompts name it where next-ticket.md hands the pull request over, so an agent running the loop is pointed at it rather than discovering it.

#### LK-3pg Run author repair and acceptance workers from durable queue jobs — 2026-09-20 · 6e55a5c

Add durable job identities and a configurable coding-agent adapter to the merge queue, building on LK-6yn and the author-response prompt in LK-sm4. Dispatch or resume one owner per PR/worktree for verified findings. Collect independent acceptance evidence before CI, bound to full head, criteria hash and policy revision. Resolve clean Codex summary commits through trusted provider evidence rather than prefix-only matching. Keep worker credentials separate from the future merge gate.

**Done when:** Fixture workers prove duplicate delivery and restart do not produce overlapping edits; findings get a fixing-commit/test reply or a supported rebuttal; incomplete or stale output never passes; every acceptance criterion maps to evidence; changed criteria/head invalidate evidence; exhausted or crashed jobs release only after verified stop and report the blocker. A controlled real author/reviewer run is recorded.

#### LK-og8 Repair reviewer cleanup and author receipt contract after PR73 merge — 2026-09-20 · 9cb57c7

PR73 auto-merged at 2026-09-21T00:01:15Z after another reviewer posted Agent review while Codex was still running. The completed Codex review at 00:02:44Z found two valid defects (4058525101 and 4058525106): missing detached reviewer directories retain Git registrations and break retries; author receipt examples incorrectly prefill the starting head despite validation requiring the resulting published head. Fixes and failing regressions were already in progress when merge was discovered. Keep this follow-up PR auto-merge disabled until completed exact-head Codex review and independent acceptance; do not change live consumer policy in this repair.

**Done when:** A runtime fixture deletes a registered detached reviewer tree, reconciles the stopped job, proves its registration is gone and a retry finishes. A protocol fixture proves author packets request the resulting published head and validation accepts that post-fix head. All worker tests pass on macOS and isolated Linux; full kit/fresh-install checks pass. Record separate real author and reviewer sessions exercising the corrected receipt contract.

#### LK-9r7 A day's pull requests have no merge order, so every merge re-tests all the others — 2026-09-20 · cedcb17

The kit plans the day's work but never plans the order the pull requests merge in, and with a
strict up-to-date required-status policy plus rebase-only merges that order is the whole cost.

Measured in a consumer (rockbox-ghl, 2026-09-18): five ready pull requests stalled about five
and a half hours; when the first merged at 12:21:47Z the other four were all rebased to new heads
and went back to their checks, and when the second merged at 12:51:27Z the remaining three were
behind again. A stack of N pull requests pays up to N(N-1)/2 extra full checks that no other run
can overlap, each also re-triggering the review app and invalidating the review status on the new
head.

next-ticket.md takes one ticket at a time and says nothing about the others, so nothing in the
kit tells an orchestrating agent that the fifth pull request it starts will be re-tested four
times. The missing output is a merge order decided when the tickets are chosen, and the rule that
follows from it: a pull request whose turn has not come does not rebase and does not ask for its
check. That turns the stack into one check per ticket, in turn.

Two things belong beside it and are the consumer's to do rather than the kit's: reserving
version numbers for schema migrations so two branches cannot choose the same one (rockbox-ghl hit
exactly that, two branches both taking Flyway V27, which only collides once both are on the same
main), and rebasing through refresh-ticket.sh rather than any branch-update API.


**Done when:** The kit names the merge order as a planning output beside the day's tickets, and says what changes when a pull request is not next in it: its rebase and its check wait until its predecessors have landed. A reader can tell, from the kit's own prompts, whether a given pull request should run its check now or wait. The guidance states the cost it removes in runs rather than in adjectives, and does not require any tool the kit does not already carry.

#### LK-kpe Bind worker acceptance receipts to ticket dependencies and labels — 2026-09-21 · 0e56f7a

Discovered during LK-9r7 PR75 review. The new legacy assessment protocol binds dependencies and labels, but scripts/review-workers.py GitHub.snapshot omits them, verify_source does not compare them, and binding excludes them. A new blocker or story-label change on an unchanged head/criteria can therefore reuse a worker receipt. An AST extraction of the current binding function confirms identical identity after these fields change. Fix this reusable runtime before unattended App-gate rollout; current bounded bootstrap must separately pin and compare full ticket metadata before and after acceptance. Serves LS-03.

**Done when:** Worker self-tests prove adding/removing/changing a ticket blocker or label on the same head invalidates both prepared/running jobs and a stored acceptance receipt, including a mutation during final source verification. Normalize dependency edges and labels so provider ordering alone does not invalidate evidence. Include metadata in the worker packet and binding; full kit and fresh-install checks pass.

#### LK-412 The CI skeleton runs the whole check on every push, and the obvious way to narrow it is a trap — 2026-09-21 · eea5785

A default pull_request trigger includes synchronize, so every push to a ticket branch runs the
whole check. In a consumer that iterates the way the kit's own loop iterates - push, review app
comments, author answers, push again - that is the fix-review-fix loop paying full CI price on
each round, and the push that answers a review finding is the one least likely to be the last.

Measured in rockbox-ghl on 2026-09-18: one ticket's pull request spent three runs and 32m41s
(11m29s, 9m55s, 11m17s) plus a 12m14s run on main after the merge, and the local full check of
the same tree takes about four minutes.

The trap this ticket exists to record, found while narrowing that consumer's trigger: a job
GitHub skips still reports a check run, and GitHub's branch-protection documentation says
required status checks "must have a successful, skipped, or neutral status". So narrowing the
trigger to a request label with a job-level `if: github.event.label.name == ...` does not merely
skip work - it lets any other label satisfy the required context with nothing having run. The
consumer's fix is to trigger on the label event and let the job always run, one check per label
change, which is cheap because labelling is rarer than pushing. Any kit guidance here has to say
that, or the next consumer re-derives it the hard way.

The related consumer-side observation, for whoever writes the guidance: ruleset-check.sh already
requires every required context to name a job, and that check keeps passing under a
label-triggered workflow because it reads job names rather than triggers.


**Done when:** templates/ci/workflow.yml either triggers the check on request rather than on every push, or says in the file why every push is the right default for a kit consumer. If it changes, the required context keeps naming a job the workflow reports - the pair ci/ruleset.json and the workflow pass ruleset-check.sh - and the README says how an author asks for the check. The file records why a job-level if: on a label name must not be used to narrow the trigger.

#### LK-pge Install the kit queue CI workflow while retaining legacy gates — 2026-09-22 · 84a0dc9

Activation prerequisite discovered while auditing LK-e9y. The kit default branch has only legacy CI354963111 (.github/workflows/ci.yml); the App controller requires a dedicated workflow_dispatch file on main. Introduce the rendered queue workflow through a separate reviewed bootstrap PR using the existing legacy protections, so LK-e9y can obtain its controlled live proof without circularly requiring its own unfinished rollout to merge first. Use the reviewed controller workflow template, App5024825, the kit full check ./check.sh, pinned toolchain/Beads bootstrap after admission, exact-head checkout and read-only Actions permissions. Do not activate the queue, alter protections, enable auto-merge, or remove existing CI as part of this prerequisite. Coordinate with LK-44w; proposing this bootstrap ahead of PR78 is not merge admission.

**Done when:** An independently reviewed bootstrap PR lands the queue workflow on main under existing required checks. The rendered workflow has no placeholders, embeds App5024825, and verifies exact run/head/base/attempt admission before checkout and all expensive setup; job and step names match the controller contract. Meaningful local fixtures prove missing, foreign and replayed admission fail before the full suite. Record the actual workflow ID/path and complete file SHA256 after merge. Legacy workflow triggers, required contexts, protections and existing PR merge settings remain unchanged by this ticket. Positive live controller admission and old/new gate migration remain LK-e9y acceptance, not claimed by bootstrap.

#### LK-evm Document V1 nomination and independent acceptance for the live queue pilot — 2026-09-22 · b5525e1

Add a concise operator guide for the existing-agent V1 nomination, selected refresh and independent acceptance handoff. Use this documentation-only PR as the first controlled live queue candidate; the protected runtime is the separately reviewed PR78 release. This ticket covers its own documentation proof, not the complete controller rollout.

**Done when:** A documentation guide accurately names the shipped handoff commands, shared-account trust limit and fresh head/base acceptance requirement. Full kit check passes and independent review finds no unsupported activation claim. The parent LK-e9y retains ownership of live three-PR and migration acceptance.

#### LK-d50 Document queue restart and blocked-attempt recovery for the live pilot — 2026-09-22 · c9696e0

Add an operator guide for observing an idle or running V1 queue, restarting the same controller journal, and handling uncertain dispatch or merge outcomes without duplicate execution. Use this documentation-only PR as the second controlled queue candidate. The controller rollout acceptance remains LK-e9y.

**Done when:** Guide distinguishes restart from retry, retains journal ownership for uncertain work, names supported status and recovery commands, and does not promise automatic recovery without proof. Full kit check and independent documentation review pass.

#### LK-4l2 Document portable queue host migration and rollback for the live pilot — 2026-09-22 · 4e457c6

Add an operator guide for moving the single-host V1 controller from this Mac to another server, preserving queue state and source/policy provenance and avoiding two active hosts. Use this documentation-only PR as the third controlled queue candidate. Live migration itself is outside this ticket; LK-e9y owns queue rollout acceptance.

**Done when:** Guide specifies stopping and reconciling the old host, SQLite-consistent state backup, protected destination credentials/tools, one-host activation, verification and rollback without losing branch protection. Full kit check and independent documentation review pass.

#### LK-e9y Enforce one admitted CI candidate with a dedicated GitHub App gate — 2026-09-21 · dd0e7cf

Implement the trusted promotion/CI/merge adapters and supervised service after the shadow queue and worker evidence exist. Scope dispatch to one head/base/attempt, rebase only the selected PR, re-review after refresh, verify actual CI and merge with the expected head. Pin the required check to a dedicated GitHub App and keep its credentials outside authors/CI. Provide an opt-in migration from legacy required contexts and prompts, preserving protections until the new gate is proven. RockBox rollout remains RB-g6do.

**Done when:** Three-PR and crash/race fixtures plus a controlled live PR prove waiting PRs get no rebase/full CI; an unchanged admitted attempt reuses its run; stale or unauthorized dispatch cannot spend the suite or satisfy the gate; App check fails closed on unread/reopened/changed evidence, non-success CI or changed base; merge verifies expected head and actual landed state; supervisor resumes without stealing active work. Migration verifies old and new gates before retiring duplicate push/label builds and legacy captain.

#### LK-af3 Document the controlled automatic-recovery queue proof — 2026-09-22 · c6d4fbf

Provide a small reviewed predecessor PR and a reusable operator procedure for the LK-v4s live proof. Its merge advances main while the recovery-fix PR waits untouched, so the subsequent App-selected refresh exercises the original observation-race path. Document bounded synthetic review activity, withheld acceptance, same-attempt recovery, final-head review, one admitted CI and verified merge; no live credential or service setting belongs in Git.

**Done when:** A concise kit operations guide names the preconditions, selected-only refresh and bounded feedback-change procedure, expected observation retry evidence, unchanged waiting PRs, and the post-admission fail-closed boundary. Full kit check and independent review pass. The predecessor is merged by the App with one queue CI run; LK-v4s retains ownership of the actual automatic-recovery acceptance proof.

#### LK-v4s Retry changing pre-admission review snapshots without manual queue recovery — 2026-09-22 · e803c9a

Controlled V1 pilot PR83 refreshed through the sanctioned selected-only path. While Codex feedback changed during observer double-read, attempt9c4b8fab04c94c8aa149053e121fddf1 entered persistent blocked state before any gate/dispatch. The safe halt is correct, but ordinary review activity should return to observation automatically before authority exists; post-admission uncertainty must still revoke and hold. Inspect distinct typed observation-race handling and narrowly bounded phase checks, preserving the same lane and never starting CI on stale acceptance.

**Done when:** Tests prove transient head/base/feedback changes during observation before admission wait and recover on stable evidence without operator retry or duplicate attempts; gate creation/dispatch intent or in-flight CI still fails closed and holds ownership. Full kit check and independent review pass. A controlled selected refresh with review activity proceeds without manual reset and waiting PRs remain untouched.

## v0.21.1 — 2026-09-17 (v0.21.0..HEAD)

### kit (LK)

- **LK-7o6** backlog-status.sh reads an unset stories path as an unbound variable — 2026-09-17 · 7142c12 (read the queue when no stories file is configured)
- **LK-c0d** The loop's ticket-id shape drops the ids Beads generates — 2026-09-17 · 1659e21 (read the ids Beads generates)

### kit (LK): archived tickets

#### LK-7o6 backlog-status.sh reads an unset stories path as an unbound variable — 2026-09-17 · 7142c12

loop.toml.example documents stories = "" as the supported setting for a project that keeps no product backlog, and .loop.toml's stories key is optional. scripts/backlog-status.sh does not survive either: status() declares 'local stories json gitlog' and assigns stories only inside 'if [ -n "$STORIES_FILE" ]', then passes "$stories" to perl at line 101. Under set -u the reference is an unbound variable, so every mode that reads the queue - the table, --next, --open, --sprint, --sprint-check, --reconcile, --show and --stories - dies before reading anything.

It reproduces with the setting the documentation names and with no setting at all:

  /opt/homebrew/bin/bash ./scripts/backlog-status.sh --stories-file ""
  ./scripts/backlog-status.sh: line 101: stories: unbound variable   (exit 1)

bash 3.2 initialises 'local' to empty and hides it; bash 5 does not, and bash 5 is what CI runs on ubuntu-latest and what Homebrew installs here. So the defect is invisible on macOS /bin/bash and immediate everywhere the check actually runs. The reviewer raised it as a P2 on rockbox-ghl PR #121, where the synced copy carries the same line.

**Done when:** status() initialises stories to an empty string before the conditional, so scripts/backlog-status.sh reads the queue with stories unset, stories = "" and a stories path all alike; the self-test runs the fixture with no stories configured and proves a table is printed; and the full ./check.sh passes under bash 5.

#### LK-c0d The loop's ticket-id shape drops the ids Beads generates — 2026-09-17 · 1659e21

Beads does not only mint <PREFIX>-<number> ids. Once a prefix's numeric space is spent it mints an alphanumeric suffix - LK-1af here, RB-y3f, RB-50q, RB-6xw and RB-m7x in rockbox-ghl - and every ticket filter in the kit still reads /^[A-Z][A-Z0-9]*-[0-9]+$/, which silently drops them. Nothing errors: the ticket simply is not there.

Four scripts share the shape, and each loses the ticket in its own way. scripts/backlog-status.sh:142 drops it from the table, --next, --open, --sprint, --sprint-check, --reconcile and --show. scripts/reference-check.sh:80 drops it from the acceptance-criteria and dependency checks, so an alphanumeric ticket is never proved and a blocks edge onto one reads as an unknown dependency. scripts/release-notes.sh:111 drops it from the archive and ship list. scripts/pr-readiness.sh:82 and :87 fail to parse 'ticket/RB-y3f' and 'RB-y3f: subject' at all, so the gate's own bead criterion reports that the branch names no ticket.

In this repository the loss is visible today: LK-1af is an open P1 that scripts/backlog-status.sh does not list and scripts/reference-check.sh does not count (it reports 20 tickets against a 21-row queue). In rockbox-ghl it bit PR #121, whose own ticket RB-y3f is invisible to the gate judging it, and the reviewer raised it as a P1 on that pull request. The kit is the place it is fixed: the copies a project syncs then carry the same shape. The documentation states the shape too (backlog-status.sh:32, pr-readiness.sh's branch_ticket comment), so those are corrected with it.

**Done when:** Every ticket filter accepts a Beads id with an alphanumeric suffix as well as a numeric one - the queue rows and the git subjects in scripts/backlog-status.sh, the queue rows in scripts/reference-check.sh, the queue rows and the ship subjects in scripts/release-notes.sh, the validated id in scripts/sprint.sh, and the branch and head subject in scripts/pr-readiness.sh; each of those scripts carries a generated id in its self-test and proves it is read rather than dropped; and in this repository scripts/reference-check.sh counts a ticket for every row of the queue, LK-1af included.

## v0.21.0 — 2026-09-16 (v0.20.0..HEAD)

### kit (LK)

- **LK-40** The kit's queue is a Beads database, written by hand — 2026-09-16 · cd3e91c
- **LK-41** The kit's CI installs Beads and bootstraps the queue — 2026-09-16 · 5f92332 (CI installs Beads and bootstraps the queue)
- **LK-42** backlog-status.sh reads the queue from Beads — 2026-09-16 · 8147086
- **LK-43** The sprint is a Beads label and priority — 2026-09-16 · 9f16c88
- **LK-44** release-notes.sh --archive closes the shipped tickets in Beads — 2026-09-16 · c52b5ea
- **LK-45** The four prompts speak Beads — 2026-09-16 · 9fbde98
- **LK-46** reference-check reads Beads, and BACKLOG.md retires — 2026-09-16 · a1dfb9c
- **LK-48** The CI checkout carries the history the queue checks read — 2026-09-16 · c20464c (CI fetches the history the queue checks read)

### kit (LK): archived tickets

#### LK-40 The kit's queue is a Beads database, written by hand — 2026-09-16 · cd3e91c

The kit's tickets still live in BACKLOG.md headings, and decision 0012 makes Beads the ticket store with git still the proof. Initialise .beads with prefix LK and write the kit's open tickets into it by hand: the open LK-23 to LK-33 (LK-30 and LK-31 blocked with their withdrawal) and this arc's tickets. No import tool ships. Each issue carries its acceptance criteria, its blockers as bd dependencies, a section:<slug> label, and the sprint label because this repository's sprint is every open ticket. scripts/pr-readiness.sh already reads this contract (bd show --json: acceptance_criteria, status, assignee). BACKLOG.md stays the reader in this change; the port that moves it is the next tickets.

**Done when:** bd list --all --json from the kit root lists LK-23 to LK-33 and LK-40 to LK-47 with a non-empty acceptance_criteria; LK-30 and LK-31 are blocked with the withdrawal in their notes; LK-23 is in_progress with an assignee; every open ticket carries the sprint label and a section:<slug> label; bd dep list shows this arc's blockers as blocks dependencies; and ./check.sh still passes because BACKLOG.md is still the reader.

#### LK-41 The kit's CI installs Beads and bootstraps the queue — 2026-09-16 · 5f92332

The loop's checks are about to read bd, and the queue lives in the Dolt database behind refs/dolt/data rather than in the working tree. A GitHub runner has neither bd nor the database. The kit's own workflow and the workflow skeleton a project installs both need the pinned Beads release and bd bootstrap --yes before the check, so the runner reads the same queue a checkout does.

**Done when:** .github/workflows/ci.yml and ci/workflow.yml install the pinned Beads release (the same version this checkout runs) and run bd bootstrap --yes before the check; install.sh --self-test still parses every spliced workflow with the check step last; scripts/ruleset-check.sh still passes for both pairs; and a fresh clone of this repository with no local database, put through the two new steps, then runs the check against the same queue.

#### LK-42 backlog-status.sh reads the queue from Beads — 2026-09-16 · 8147086

scripts/backlog-status.sh parses BACKLOG.md headings for tickets, acceptance criteria, blockers, and claims. Replace that source with bd: bd list --all --json supplies the tickets, their acceptance_criteria, their blocks dependencies, and their state; a commit whose subject starts with the id and is reachable from the judged ref still supplies done, and done still beats a claim left behind. Stories stay in docs/PRODUCT_BACKLOG.md and a ticket says which it serves with a story:<ID> label. Add --reconcile: a bd closed ticket with no naming commit fails, and a landed commit naming a ticket bd has not closed fails. Claims are bd in_progress with an assignee rather than an origin ticket/<id> branch.

**Done when:** the self-test (a fixture git repo and a stub bd) proves: a ticket with no commit reads todo; an in_progress ticket is passed over by --next; a blocked dependency gates --next until its blocker's commit lands; a landed commit reads done even when bd still claims the ticket; --reconcile fails a closed ticket with no commit and an open ticket whose commit landed; --stories derives from story: labels and the product backlog; --show prints one ticket's acceptance criteria and state; and ./check.sh passes with --reconcile wired in beside --sprint-check.

#### LK-43 The sprint is a Beads label and priority — 2026-09-16 · 9f16c88

The sprint is a line in .loop.toml today. Decision 0012 makes it labels and priority in Beads: the tickets carrying the sprint label are the sprint, ordered by priority then id, and the project's reading of the sprint (a subset, or every open ticket so an omission is a fault) is a property the check enforces rather than a list. scripts/sprint.sh labels, unlabels, and prioritises through bd; backlog-status.sh --sprint and --next read the label; --sprint-check fails an open ticket the label omits.

**Done when:** scripts/sprint.sh add <id> [--priority N], remove, set, and clear change bd labels and priorities without touching .loop.toml; --next takes the highest-priority ready sprint ticket before any ticket outside the sprint; --sprint lists the labelled tickets in priority order with a summary; --sprint-check fails naming an open ticket with no sprint label and passes when every open ticket carries it; the sprint key is gone from .loop.toml and loop.toml.example with sprint_label documented in its place; and the self-tests prove each command against a stub bd.

#### LK-44 release-notes.sh --archive closes the shipped tickets in Beads — 2026-09-16 · c52b5ea

release-notes.sh --archive moves shipped markdown headings into CHANGELOG.md today. With the queue in Beads it reads the tickets in the release range from bd, writes their entries into CHANGELOG.md, and closes each shipped ticket in bd with the release named, so the changelog stays the human record and bd carries the state.

**Done when:** release-notes.sh --archive <tag> reads the range's named tickets from bd, writes their entries into CHANGELOG.md, and closes each in bd with the release in the reason; --prefix still narrows the range; an already-closed ticket in the range is left closed and reported; the self-test proves the writes against a stub bd and the changelog against a fixture repo; and ./check.sh passes.

#### LK-45 The four prompts speak Beads — 2026-09-16 · 9fbde98

The prompts still tell agents to read and edit a markdown ticket file, write a doing claim into a heading, and keep a sprint list in .loop.toml. They carry rules scripts/prompt-check.sh asserts, so the rules stay and the mechanics change: the ticket comes from bd show, the claim is bd update --claim, a new ticket is bd create with acceptance criteria and a blocks dependency, the sprint is the label and priorities, and the review reads the head commit's ticket from bd. prompt-check.sh's table pins the phrases that state the rules in their new wording.

**Done when:** prompts/next-ticket.md, grill-me.md, grill-project.md, and review-prs.md name bd for the ticket, the claim, the acceptance criteria, the blockers, and the sprint, and name no markdown ticket file; scripts/prompt-check.sh pins a phrase for each rule that survived and fails when one is removed; scripts/prompt-check.sh passes; and the pull request records a real run of next-ticket against the kit's own Beads queue, showing the claim, the work, and the close.

#### LK-46 reference-check reads Beads, and BACKLOG.md retires — 2026-09-16 · a1dfb9c

reference-check.sh parses BACKLOG.md and docs/PRODUCT_BACKLOG.md, which is BACKLOG.md's last reader. Read the queue from bd instead: every dependency resolves to a ticket, every ticket carries acceptance criteria, no dependency cycle, every story:<ID> label resolves to a story in the product backlog, and every decision a ticket cites is a record. Then delete BACKLOG.md and the backlog setting, keeping docs/PRODUCT_BACKLOG.md as the product-intent and acceptance-criteria document (stories are not tickets), and record the decisions: Beads is a hard dependency and a checkout with no .beads fails with the command that fixes it; the markdown ticket file retires; the stories document stays.

**Done when:** scripts/reference-check.sh reads tickets and dependencies from bd and stories from docs/PRODUCT_BACKLOG.md, and its self-test proves each fault alone against a stub bd; BACKLOG.md is deleted and no script, prompt, or doc names it as the queue; backlog is gone from loop-config.sh's defaults, .loop.toml, and loop.toml.example; docs/PRODUCT_BACKLOG.md is kept, with its withdrawn stories thinned to a note, and decisions 0014 and 0015 record the store, the hard dependency, and both files' fates; ./check.sh passes and install.sh --self-test still passes on a fresh repository.

#### LK-48 The CI checkout carries the history the queue checks read — 2026-09-16 · c20464c

The first main-push run after the Beads port went red: --reconcile reported every landed ticket as a false close (LK-40 to LK-44 closed in Beads but no commit reachable from origin/main names them). The cause is actions/checkout's shallow clone: git log origin/main sees only the tip, so the done derivation has no commits to match. The kit's own workflow and the workflow skeleton a project installs must check out the full history (fetch-depth: 0), which proof-gate already wants in CI.

**Done when:** with fetch-depth 0 in .github/workflows/ci.yml and ci/workflow.yml, the main-push check reads the landed commits and --reconcile passes; install.sh --self-test still parses every spliced workflow with the check step last; scripts/ruleset-check.sh still passes for both pairs; and the PR's own CI run is green with the reconcile step reading the whole history.

