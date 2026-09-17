Turn a loosely stated feature idea into user stories with acceptance criteria and into tickets
the loop can execute. Interrogate first, draft second, write third. Follow the standing
instructions in `AGENTS.md` (the loop section and the Project rules).

The queue is Beads (`bd`), a hard dependency; the settings file is `.loop.toml` and the stories
document is the product backlog named by `stories`. Settings come from `scripts/loop-config.sh`:
`check` (the full check), `trailer_required`, `decisions` (the directory of decision records,
`docs/decisions` by default), `sprint_label` (the Beads label that marks the sprint) and `stories`.
The Project rules name the product backlog when the project keeps one; without one, keep the
stories at the top of the product backlog you write, not in Beads, because stories are intent and
Beads holds tickets.

## 1. Ground yourself before asking anything

Before anything else, check that this repository is loop-managed: it must have the settings file
and the Beads queue. The settings file is `.loop.toml` at the repository root; the queue is the
`.beads` workspace `bd where` names (`bd init --prefix <PREFIX>` creates one). When either is
missing, stop before any other question and ask the owner where the artifacts belong - this
repository, a new one, or a sibling of it - and where the settings file should live, because
nothing below can run until they exist. Do not infer either from the code: a repository with
neither is not an invitation to guess, and a session that guesses spends its rounds working out
what one question would have settled.

Then read the decision records: the index in the decisions directory (`docs/decisions/README.md`
by default) and every record that touches the idea. A decision that has a record is settled;
never ask about it, cite it by number. Then read the product backlog (every epic that touches the
idea), the Beads queue (`bd list --all --json`, the ids and sections the idea touches), and run
`scripts/backlog-status.sh --stories` and `--open` so you know which stories are unticketed or
open and what has landed. Skim the code and docs the idea would change, using the Layout in the
Project rules to find them, so every question you ask is one the repository cannot answer.

## 2. Grill

Ask in rounds: at most four questions per round, each with a recommended default first, in
whatever way the harness offers for asking the owner (a structured question tool when there is
one, otherwise numbered questions in chat). Ask only questions whose answer changes a story, a
done line, or a decision. Ask at least three rounds, more when an answer changes a story; the
last round is proofs and edge cases only. No story is drafted without a named proof: if none
comes to mind for a story, ask again until one does, or drop the story and say so.

Cover, in roughly this order, skipping what the idea, the records, or the repository already
settle:

- **Who and why.** Which user and what they do today instead. What would make them stop
  using it.
- **Edges of scope.** What is explicitly out. Which existing page, endpoint, command, or module
  it changes, and which it must leave alone.
- **Inputs and data.** What it reads; what happens when that is missing, partial, or wrong.
  Whether anything private is involved that the Project rules keep out of this repository.
- **Where it shows up.** Which surface: a page and panel, an endpoint, command output, or a
  file. For a page: which of the UI conventions in the Project rules apply, and what the
  panel holds in what order. Sketch that as a text wireframe in the next round's restatement,
  so the owner corrects a picture rather than a paragraph.
- **Decisions.** A story that implies a decision no record covers (a store, a protocol, a
  library, a boundary, a rule) does not get to guess: stop, ask the owner the decision as its
  own question with the alternatives named, and write the record in this session
  (`scripts/decisions.sh new "<title>"`, then fill its Context, Decision, Alternatives,
  Consequences, and what would show it was wrong). A story that contradicts a record stops
  for "which wins"; when the decision changes, write a superseding record
  (`scripts/decisions.sh new "<title>" --supersedes NNNN`) rather than editing the old one.
  Every ticket cites the records it rests on.
- **Failure and guardrails.** What must refuse rather than guess. What a wrong answer would
  look like in the output.
- **Proof** (the last round). For each candidate story: what test, fixture, self-test, or
  measurable output would convince the owner it is done, and which edge cases that proof
  must cover. If nothing testable comes to mind, the story is not ready.
- **Order and dependencies.** What has to exist first; what could ship on its own.

Push back on vague answers ("it should just work", "like the other page") with a concrete
alternative to accept or reject. Restate the owner's answers in your own words at the start of
the next round so misreadings surface early.

## 3. Draft

Produce two artifacts and show both in chat before writing anything.

**Product stories**, in the product backlog's exact format under the matching epic (or a new
epic with the next letter and a new hundred block of its story prefix):

```
### BT-nnn — <title>

**Status:** Proposed  
**User story:** As a <user>, I want <capability> so that <outcome>.

**Acceptance criteria:**

- <observable, testable statement>
- ...
```

Each criterion is a statement someone could check without reading the code. No "works
correctly", "is fast", "handles errors"; say what is shown, refused, frozen, or measured.

**Executable tickets in Beads**, one per shippable slice, created with `bd create` (never a
markdown heading): a title, a paragraph of intent in `--description` with the file and function
names and the story and decision records it rests on ("Serves BT-nnn"; "Decisions: 0007, 0012"),
the done line in `--acceptance`, blockers as `--deps blocked-by:<id>`, a `section:<name>` label and
a `story:<ID>` label, and a priority that states the order to work them. Ids continue the
project's prefix and sequence; give the id explicitly (`bd create ... --id <PREFIX>-nn`) so the
loop's `<ID>: ...` commit subjects keep matching. A ticket is one commit's worth of work for one
agent, testable on its own with the full check, and carries the done line the review judges it
against. Split anything larger. Put a dependency only where the work cannot start earlier.

**Wireframes.** A story that touches a screen carries, after its acceptance criteria, a fenced
text wireframe at most 80 columns wide that names the panels, tables, and controls and
their order, top to bottom and left to right, with what the story adds or changes marked.
The owner confirms it with the draft. The ticket points at it by story id in its description
(`Wireframe: BT-nnn`) rather than describing the layout again, and its done line's fixture or
check matches the wireframe. When the owner asks for a mockup, or the screen is new rather than
changed, make one with the harness's design canvas when it has one and otherwise as a
single HTML file, save it beside the product backlog (`docs/wireframes/<story id>.html`),
and link it from the story and the ticket.

**The sprint.** The sprint is the Beads label `sprint_label` names (`sprint` by default), worked by
priority then id - there is no list in `.loop.toml`. It means one of two things, and the comment
above `sprint_label` in `.loop.toml` says which: the tickets chosen for now, leaving the rest as
the pick list `--open` prints, or every open ticket, so an omission is a fault that
`scripts/backlog-status.sh --sprint-check` fails on. Ask the owner which of the new tickets carry
the label and at what priority (`scripts/sprint.sh add <id> [--priority N]`) - and "or none" only
where that comment states the subset reading, because under the other one a ticket you file and
leave unlabelled is a ticket the full check fails on. The write step labels them in the same
session.

Ask the owner to confirm the draft, and apply their edits, before going on.

## 4. Write and hand off

Never write to the default branch. From the main checkout:

1. `git checkout -b backlog/<short-slug>` from the default branch.
2. Write the stories into the product backlog, the decision records written during the session
   (with the index, `scripts/decisions.sh index`), and any wireframes. Create the tickets with
   `bd create`, then push the queue (`bd dolt push`) so the tickets exist for the next
   `scripts/backlog-status.sh --next` however it is run. Keep the product backlog's ordering
   (epics by letter, stories by id). If a story replaces or narrows an existing one, edit that
   story's status line rather than adding a duplicate.
3. Commit the stories, records, and wireframes with the subject `Backlog: <XX-nn..XX-mm> <one-line
   summary>` and, when the config requires it, a `Co-Authored-By: <agent> <email>` trailer naming
   the agent and model.
4. `git push -u origin backlog/<short-slug>` and open the PR with `gh pr create --fill`, then
   `gh pr merge --auto --rebase`; CI on a docs-only change is quick and the owner can merge or
   wait for auto-merge.
5. Report: the PR URL, the story ids and ticket ids added, the decision records written or
   superseded, what the first next-ticket run will pick up, and any question the owner deferred
   (record those as `bd update <id> --status blocked --append-notes "<the question>"` on the ticket
   that needs the answer).

Rules: this prompt changes only the product backlog, the decision records, the wireframe files, the
Beads queue's tickets and labels, and never edits code or anything the Project rules say never to
touch, and never copies private details into a public backlog.
