# 0030 — A ticket leaves the queue without landing only as dropped

Status: accepted, narrows 0012
Date: 2026-10-24

## Context

Decision 0012 made Beads the ticket store and kept Git as the proof: a ticket is done when a
commit whose subject starts with its id is on the default branch, and `--reconcile` fails a
ticket Beads has closed that no such commit names. Its "What would show this was wrong" names
the failure that has now happened: a reconciliation that cannot be made to pass. On 2026-10-24
the consumer fueledbychai-rs had four tickets closed on purpose with no commit (LK-3ni):

- FBC-omhd, an owner decision that changed nothing;
- FBC-ue2q, a duplicate of FBC-goci;
- FBC-vgl, retired by the owner in favour of FBC-p0aa and two tickets in another repository;
- FBC-89f5, whose fix landed under FBC-840's commit.

`backlog-status.sh` had no way to tell them from a premature close. Each read `todo`, so `--next`
could offer it once its blockers landed, a ticket it blocked stayed blocked for good, and a story
counting it never read done.

Beads already records two of these closes. As bd 1.3.0 stores them:

- `bd duplicate X --of C` closes X and gives it a `duplicates` dependency on C.
- `bd supersede X --with R` closes X and gives it a `supersedes` dependency on R, which bd reads
  as "X is superseded by R".

In both, the link sits on the dropped ticket and `depends_on_id` is the ticket that carries its
work. Both work on a ticket that is already closed, and both keep its close reason.

A retirement that nothing carries has only its close reason. bd stores the placeholder `Closed`
when a close is given no reason (`bd close X`, or `--reason ""`). On a ticket already closed,
`bd close X --reason "<why>"` reports success and leaves the stored reason unchanged, so the only
way to set the reason is `bd reopen X && bd close X --reason "<why>"`.

`bd reopen` keeps a ticket's links and labels. `bd duplicate` and `bd supersede` refuse to add
their link when the ticket already has a dependency of any type on the other one, a `blocks` or
`discovered-from` edge for example, and `bd close` refuses a ticket that is still blocked unless it
is given `--force`. `bd ready` treats a closed blocker as satisfied; the loop's readiness does not.

## Decision

0012 says "a ticket is closed in `bd` only when a commit whose subject starts with its id is on
the default branch". This record narrows that sentence by one exception: a ticket may also be
closed when it is **dropped**. The rest of 0012 stands, and Git stays the only proof of done. A
dropped ticket is never done.

**What counts as dropped.** A ticket is dropped when Beads has closed it, no landed commit names
it, and it carries a drop marker. There are two markers:

- **A link** to the ticket that carries its work:
  - `bd duplicate X --of C` when the same work was ticketed twice;
  - `bd supersede X --with R` when another ticket carries or replaced the work, including a fix
    that landed under another ticket's commit.
- **The `loop:dropped` label.** This is for an owner's decision that nothing in this queue carries;
  work carried in another repository is named in the reason. The label alone is the marker, and
  a label drop must also carry a close reason, which `--reconcile` checks (fault 2 below).

A reason is a close reason that is not empty, not blank, and not bd's placeholder `Closed`.

**How the state is derived.** It is one derivation: done (Git) beats dropped (closed and marked),
and dropped beats every other state. A dropped ticket is:

- never ready, and never offered by `--next`;
- not in `--open`'s pick list;
- never an omission for `--sprint-check`;
- left out of a story's ticket count. A story whose tickets are all dropped reads unticketed.
  `--show <story>` still lists them.

The table shows each one as `dropped (duplicate of C)`, `dropped (superseded by R)` or
`dropped (<reason>)`, and `--sprint` counts them apart. A ticket that carries a marker but that
Beads has not closed is not dropped, and it is never ready either until fault 1 below is settled,
so a marker added before the close cannot leave the ticket to be picked. The table shows it, like a
done ticket that carries a marker, with `(marked dropped in bd)`.

**What `--reconcile` checks.** It accepts a dropped ticket that no commit names. It fails each of
these:

1. A drop marker, label or link, on a ticket Beads has not closed and no commit names.
2. A ticket dropped by the label alone with no reason.
3. A landed commit naming a ticket that carries a marker. The state is done, since Git wins, and
   the marker contradicts it.
4. A drop link to anything but a ticket in this queue that is not itself dropped. That one rule
   refuses a cycle, a self-link, an epic, another queue's id and a chain alike, and the fix names
   the dropped target's own carrier where it has one.
5. A ticket that is neither done nor dropped blocked by a dropped ticket. The fix is the
   command that re-points the dependency to the carrier, or, when the blocker's own link names a
   dropped ticket, to that ticket's carrier, the one fault 4 points the blocker at. It removes the
   dependency only when nothing else carries the work: the dependent carries it itself, already
   depends on the carrier, or waits on a label drop. A blocker whose link names no live ticket at
   all is fixed first, and its dependent is never told to remove the dependency, since another
   ticket may still carry the work.
6. A story served by a link-dropped ticket that none of its carriers serves, so that the story
   cannot read done while the work sits outside it.

A plain close with neither marker and no commit stays a false close.

**The label.** The label is `loop:dropped`, namespaced and fixed in the kit as `loop:coordination`
is, with no setting.

**The surrounding tools.** `scripts/sprint.sh` refuses to add a dropped ticket to the sprint.
`scripts/pr-readiness.sh`'s bead fact fails a ticket carrying a drop marker, which would otherwise
merge and become fault 3 on the default branch. The loop's Tickets bullet in `AGENTS.md` governs
over the generic Beads guidance below it: a plain `bd close` is only for a ticket whose commit has
landed, and `--next`, not `bd ready`, names the work.

## Alternatives

- **Supersede 0012 and restate it whole.** Only one sentence of it changes, and restating the
  rest invites the two to drift. The cost is that 0012, which is never edited, does not point
  forward to this record; this record cites it.
- **Let any close with a reason be a drop.** A premature close carries a reason too, so the false
  close 0012 guards against would disappear.
- **Retype the ticket to an epic, milestone or decision.** That is not a drop: it takes the
  ticket out of every view in silence, with nothing to say where its work went.
- **Make readiness follow a drop link**, so that a ticket blocked by a dropped one becomes ready
  once the carrier lands. That re-points dependencies without anyone seeing it. The loud fault
  and its one-command fix keep the graph as written. The loop's readiness differs from
  `bd ready`'s on purpose.
- **Follow chains of drop links to the live carrier.** It needs traversal and cycle detection.
  Requiring every link to name a live ticket gives the same answer with one rule.
- **A bare `dropped` label**, as the ticket named it. Rejected because a project may already use
  that word, the kit's markers being namespaced like `loop:coordination` (owner decision
  2026-10-25).
- **Check the Beads-only faults in `scripts/reference-check.sh`**, which every project's check
  runs. The drop state needs Git, because a marked ticket that a commit names is done and not
  dropped. That derivation lives in `backlog-status.sh`, so splitting the rules across two
  scripts would derive the state twice.

## Consequences

The faults above hold wherever `--reconcile` runs. That is the kit's own check, and any project
that runs it. A project whose check runs only the shared block gets the drop state in every view,
but not the faults.

`scripts/release-notes.sh --archive` needs no change. It closes only shipped tickets that are
still open. A dropped ticket has no commit, so it never ships. A dropped ticket that did ship is
already closed, so it is reported "already closed", and it is fault 3. The queue's Python needs
no change either: the worker observer requires `in_progress`, and the controller's readiness
requires a commit naming each blocker.

Dropping a ticket is a small procedure, and `AGENTS.md` and `prompts/next-ticket.md` state it:

- Re-point the tickets it blocks, and give its carrier its `story:` labels.
- Remove any dependency the ticket already has on its carrier, a `blocks` or `discovered-from`
  edge for example, before `bd duplicate` or `bd supersede`, which refuse to add a link over one.
- Mark a label drop with `bd update <id> --add-label loop:dropped` and close it with
  `bd close --force`, because bd refuses to close a ticket that is still blocked. Nothing carries
  its work, so each ticket it blocks loses that dependency rather than being re-pointed.
- Release the dropped ticket's claim branch and close any pull request it has. An agent that
  drops another ticket in favour of its own keeps its own claim and goes on with it.

An agent drops by link only when another ticket's landed commit already meets the done line, or
the work was ticketed twice. A drop by the label only records the owner's decision. No agent drops
a ticket another agent holds: it reports the ticket to that agent instead, and only that agent or
the owner drops it.

For the fueledbychai-rs rollout:

- copy the kit's new Tickets bullet, with its sentence that it governs over the generic Beads
  guidance, into the loop section of fueledbychai-rs's `AGENTS.md`, which `install.sh` and
  `scripts/loop-kit-sync.sh` leave as the project wrote it
- `bd duplicate FBC-ue2q --of FBC-goci`
- `bd dep remove FBC-89f5 FBC-840 && bd supersede FBC-89f5 --with FBC-840`, since FBC-89f5 was
  created `discovered-from` FBC-840
- `bd supersede FBC-vgl --with FBC-p0aa`, keeping its cross-repository replacements in its reason
- the `loop:dropped` label on FBC-omhd, with its reason. If FBC-omhd holds bd's placeholder
  reason, it is reopened and closed with a real one.

FBC-vgl serves story BT-402, which FBC-p0aa does not serve, so fault 6 asks for that label too.

## What would show this was wrong

Any of these would reopen this decision:

- Drops used to clear a reconciliation for work that was never done: a supersedes link to a ticket
  that does not carry the work, found when a story reads done and its feature is missing.
- The drop faults firing on most drops, so that the check is waived rather than met.
- bd changing the side a drop link sits on, or the placeholder it stores for a close with no
  reason, which would make the derivation misread every drop.
