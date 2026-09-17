# Work queue

The ticket list an agent loop works through. `docs/PRODUCT_BACKLOG.md` holds product intent and
long-form acceptance criteria; this file is the executable queue. Protocol:

- One ticket per commit. The commit message starts with the id. `./check.sh` must pass.
- A ticket's **Done when** line names a test, fixture, or measurable output that ships in the
  same commit. If it cannot be tested, rewrite the ticket until it can.
- Git is the record of done: a ticket is done when a commit whose subject starts with its id
  is on `main`. `scripts/backlog-status.sh` lists every ticket with its derived state, date,
  and sha; `--next` names the first `todo` whose `Blocked by` tickets have landed. This file
  carries only the claims: no state (or `todo`), `doing` while someone works it,
  `blocked <reason>`. Take what `--next` reports, never two at once, and clear the `doing`
  claim in the ticket's own commit; never write a done line.
- Anything discovered while working goes in as a new ticket, not into the current one.
- The loop's work used to be ticketed in `FueledByChai/tessera` under `HK-`; the kit is its own
  project now and its work is ticketed here (decision 0001). The first forty-eight `HK-` tickets
  stay in Tessera's history.

## The loop's scripts

### LK-01 `loop-tui.sh` renders the loop's state as a frame
The loop's state is spread over `scripts/backlog-status.sh` (eight flags), `scripts/sprint.sh`
(five subcommands), and the files themselves, and nothing prints one screen that answers "what
is left, and what do I run next". Add `scripts/loop-tui.sh` to the kit: a renderer that turns
the existing scripts' output into frames at a given width, plus the dashboard view — a header,
the sprint as a table with a `ready` and a `blocked by` column, a `NEXT` line carrying the
exact `scripts/open-ticket-pr.sh <id> --claim` command, the counts of what is left, a stories
line, and a keybar. The renderer is split from the terminal: `--render` prints one frame and
exits, `--width <n>` fixes the width, and the script takes no keys and writes nothing, so the
interactive mode of LK-03 is a key handler over these frames rather than a second
implementation. Serves LS-01. Decisions: 0002.
**Done when:** `scripts/loop-tui.sh --self-test` builds a fixture repository — a backlog with a
done, a claimed, a blocked, and a ready ticket, a `.loop.toml` with a sprint, and a product
backlog with ticketed and unticketed stories — and asserts, by named line, the header's sprint
counts, the done ticket's row, the `NEXT` line and the claim command it prints, the `LEFT`
counts, and the stories line at 78 columns; the same frame at 60 columns drops columns with no
line wider than the width, and at 200 columns stops truncating titles; and the golden frames for
60, 78, and 200 columns, kept in the script as heredocs so that `scripts/loop-kit-sync.sh`
(which ships `scripts/*.sh` only) carries them to a project, match byte for byte.
`loop-tui` is added to the script list in `check.sh`, to `install.sh`'s self-test, and to
`templates/check/common.sh`, and `README.md`'s table names it.

### LK-02 `loop-tui.sh` shows the stories, the open tickets, and one item in full — Blocked by LK-01
`scripts/backlog-status.sh` has the three views but prints them as fixed-width tables that cut
the epic at about thirty columns (`Epic F: Data inventory, cover…`), and `--open` prints a
single summary line whenever the sprint holds every open ticket. Add the `stories`, `open`, and
`show` views to `scripts/loop-tui.sh` on LK-01's renderer: the stories view lists every story in
the product backlog with its derived status (done, open k/n, unticketed), its ticket count, and
its epic untruncated when the width allows; the open view groups the tickets outside the sprint
by section with their blockers and the story each serves; the show view prints one ticket or
story in full with its state, its sprint position, and the story it serves. The dashboard's
stories line counts every story rather than the ticketed ones. Serves LS-01. Decisions: 0002.
**Done when:** `scripts/loop-tui.sh --self-test` asserts the stories view's status column for a
done, an open k/n, and an unticketed story from the fixture; the open view's grouping by section
and its blockers; the show view's `state:` and `serves:` lines for a ticket and its `status:`
and `ticket:` lines for a story; that a fixture epic name appears in full at 200 columns and
truncated at 78; that a fixture with no `stories` file prints its "none configured" line rather
than an empty table; and the golden frames for the three views at 78 columns match byte for
byte.

### LK-03 The sprint is worked from the terminal — Blocked by LK-02
Choosing what to work on next means `scripts/sprint.sh add|remove` and reading `.loop.toml` by
hand, with nowhere to see the sprint and act on it at once. Add the interactive mode to
`scripts/loop-tui.sh`: with a terminal it takes the alternate screen, hides the cursor, and
reads single keys to move through the sprint, open a ticket or a story in full, add a ticket to
the sprint, remove one, switch to the stories and open views, refresh, and quit. Every write
goes through `scripts/sprint.sh` and edits only the `sprint` list in `.loop.toml`; the screen
marks the change as uncommitted, and the script never runs `git add`, `git commit`, or
`git push`. An add is refused, with the reason on screen, when the id is not a ticket heading,
is already done, or is already in the sprint. Refresh is on keypress and `r` fetches from origin
first; nothing is fetched otherwise. `--keys '<keys>'` and a stdout that is not a terminal
render frames instead of taking the screen, so the whole program is driven without a
pseudo-terminal, and a `trap` restores the terminal on every exit path. Serves LS-02.
Decisions: 0002, 0003.
**Done when:** `scripts/loop-tui.sh --self-test` drives the fixture with `--keys` and asserts
the frames — the selection marker moves and wraps, `<sp>` opens the selected ticket, `a` adds a
ready ticket and marks the sprint uncommitted, `x` removes it, and an add of a done id, an
unknown id, and an id already in the sprint each leaves the sprint unchanged with the reason on
screen; `--keys 'q'` writes nothing; and `git status --porcelain` in the fixture shows only
`.loop.toml` modified and no commit.

### LK-04 `release-notes.sh --archive` takes a prefix filter
`scripts/release-notes.sh --archive` selects the tickets it moves by commit range alone
(`git log from..to` for subjects that start with a ticket id), so it cannot archive one prefix's
work: in a history where one prefix's commits interleave with another's, an archive over the
range moves both. Add `--prefix <P>` (repeatable, or comma-separated) to the kit's
`release-notes.sh`, filtering both the notes and the archive to the prefixes named, so that one
prefix's tickets can leave a backlog without touching the rest. Serves the migration in LK-07.
**Done when:** `scripts/release-notes.sh --self-test` extends its fixture with two prefixes and
proves that `--archive <tag> <from> <to> --prefix AA` moves exactly the AA tickets into
`CHANGELOG.md`, leaves the other prefix's tickets in the backlog untouched, and prints the count
it moved; that a prefix matching nothing archives nothing and exits 0; and that the behaviour
without the flag is unchanged.

### LK-08 `backlog-status.sh --stories` counts the archived tickets
`scripts/release-notes.sh --archive` moves shipped tickets out of the ticket file into
`CHANGELOG.md`, so a story served only by archived tickets reads `unticketed` once a release is
archived — as this project's own LS-01 and LS-02 would, since the tickets that serve them are
archived as they land. Make the kit's `scripts/backlog-status.sh` read the archived tickets
under `CHANGELOG.md` (the `#### <id> <title>` headings `--archive` writes) for their `Serves`
lines and count them as done, in `--stories` and in `--show`. Moved here from Tessera's HK-41,
which is kit work.
**Done when:** `scripts/backlog-status.sh --self-test` archives a fixture release with
`scripts/release-notes.sh --archive` and shows the story it served still `done` rather than
`unticketed`, and `--show <story>` lists the archived ticket as done with its archive date.

### LK-10 `backlog-status.sh --self-test` does not read the project's own config
`scripts/backlog-status.sh --self-test` builds a fixture repository, but most of the calls it
makes leave `LOOP_CONFIG` unset, so they resolve the `sprint` list through the checkout the test
is run in. The moment this repository gained a `.loop.toml` with a sprint, the self-test began
writing 125 lines to stderr — 120 of `sprint: LK-nn is not in the backlog file`, one per sprint
entry per call that resolves the sprint, and five of `sprint: nothing ready in it; falling back
to file order` — while its stdout stayed the single line `backlog-status self-test passed`.
Nothing fails, but a self-test whose output depends on the project it runs in cannot be read, and
a real fixture mismatch would be lost in the noise. `scripts/sprint.sh --self-test` already gets
this right, exporting `LOOP_CONFIG` to its own fixture before it calls anything; make
`backlog-status.sh`'s fixture point every call at its own config the same way, so its output is
the same wherever the test runs.
**Done when:** `scripts/backlog-status.sh --self-test` writes nothing to stderr and prints the
same stdout, both in this checkout and in a copy with `.loop.toml` removed, and still passes;
`scripts/sprint.sh --self-test` is unchanged and still writes nothing to stderr; and `./check.sh`'s
output is byte-identical between the two checkouts.

### LK-19 `loop.toml.example` reaches a project once and is never synced again
`install.sh` copies `loop.toml.example` into a project's `.loop.toml` at install time and never
overwrites it afterwards, which is right — that file is the project's own. But `loop-kit-sync.sh`
copies only `scripts/*.sh`, `prompts/*.md`, `templates/*.md`, `templates/check/*.sh` and
`templates/ci/*.yml`, so a change to the example after a project installed never reaches it, and
nothing reports the drift while every script around it is compared and reported. LK-15 is the case
in hand — PR #36, merged since this was filed, so on `main` today both files carry it: it adds a
paragraph on the two readings of `sprint` to the example and to this repository's `.loop.toml`, and
points at the example as the thing that settles which one applies — but a project that installed
before LK-15 landed has neither the paragraph nor the file, so the pointer resolves to nothing and
the kit moves on without it. Tessera is such a project: its sprint is a chosen subset, its
`.loop.toml` still carries only HK-39's one-line comment, and it has no `loop.toml.example` at all.
**Done when:** either `scripts/loop-kit-sync.sh` carries `loop.toml.example` and `--check` fails in
a project whose copy differs from the kit's, with `install.sh` still keeping a project's own
`.loop.toml`, or the ticket is answered the other way and the kit's `.loop.toml` no longer points
at a file a project cannot have; and whichever route is taken is proved in the self-tests of
`install.sh` and `loop-kit-sync.sh`.

### LK-20 The stories view's keybar offers two keys nothing reads
`scripts/loop-tui.sh stories` ends with ` e epic filter   d hide unticketed   r refresh   q quit`,
and the key handler LK-03 added reads `r` and `q` from that view but neither `e` nor `d`: the epic
filter and the hide-unticketed toggle were drawn onto the frame by LK-02 as part of the view and
were never implemented, so half the keys the frame offers do nothing. Either implement them or stop
advertising them; the same question hangs over `? help` in the other three keybars, which LK-03
answered by adding a help screen rather than by removing the key.
**Done when:** `scripts/loop-tui.sh --self-test` drives the stories view with `--keys` and asserts
what `e` and `d` do - the epic filter narrowing the rows to the chosen epic and the toggle dropping
the unticketed ones, each with the frame showing which is on - or asserts that the keybar no longer
names them; and the stories golden frame is regenerated if the keybar changed.

### LK-22 `ruleset-check.sh` fails a ruleset that requires the agent review, which the README tells every project to do
`scripts/ruleset-check.sh` is one-way on purpose: every required context must name a workflow job,
because a required context no job reports holds every pull request forever (LK-13). But the agent
review's status is not a job and never will be. It is a commit status posted by
`scripts/review-status.sh` from a machine with the owner's subscription, and the README tells a
project to do exactly that: "Add the context to the branch ruleset's required status checks and
auto-merge waits for it." So the kit instructs a configuration its own check fails. Verified
against this repository's real pair, with `{"context": "Agent review"}` added to a copy of
`.github/ruleset.json`:

```
$ scripts/ruleset-check.sh /tmp/rs-test.json .github/workflows/ci.yml
ruleset-check: /tmp/rs-test.json requires "Agent review", which .github/workflows/ci.yml has no job named; its jobs report "Check (check.sh)"
exit=1
```

That is the very file LK-06 has to write to require the review here, and it is not a hypothetical:
Tessera's committed `docs/github/ruleset-main.json` is already in this shape — its required checks
are the two job contexts plus `{"context": "Agent review"}` — so a project that names that pair in
its own check cannot pass it while following the README, and would have to either drop the review
requirement or drop the check. The distinction the check is missing is in the file itself: a
context bound to a GitHub App carries `integration_id` (15368 is Actions, which is what every job
context has), while the review's carries none, because a status posted with a user's token belongs
to no app and no workflow can report it.
**Done when:** `scripts/ruleset-check.sh` passes a ruleset that requires the loop's own
`review_context` (from `.loop.toml`) beside the job contexts, and still fails a context that is
neither a job name nor that context, proved by a self-test for each direction; and `./check.sh`
stays green with `.github/ruleset.json` unchanged.

### LK-29 `loop-kit-sync.sh`'s header lists fewer files than it copies, and nothing compares them
`scripts/loop-kit-sync.sh` opens with what a sync touches: "copy the kit's `scripts/*.sh` into
`scripts/`, its `prompts/*.md` into `loop/prompts/`, its `templates/*.md` into `loop/templates/`,
and its `loop.toml.example` to the root, and say what changed". `pairs()` copies five groups: those
three, plus `templates/check/*.sh` into `loop/templates/check/` and `templates/ci/*.yml` into
`loop/templates/ci/`. The header has been short by two groups since it was written and nothing
compares it with the function, while `install.sh`'s header and its `installed:` line name all five —
so the two files that describe the same copy disagree, and the one a reader opens first is the
wrong one. `loop-kit-sync.sh` is the file a project reads to learn what a sync will change, and it
under-reports. LK-19 edited this header and left the omission in place rather than widening its own
diff, which is how it was found.

It is the LK-14/LK-16/LK-28 shape again — one fact written down twice with nothing keeping the two
in step — but the pair here is a comment and the function under it, so a comparison of two lists in
two files is not the fix: either the header states the rule without enumerating, or the list is
printed from `pairs()` rather than written by hand.
**Done when:** the header and `pairs()` cannot disagree — either the header names no group and says
where the list lives, or a check fails naming a group `pairs()` copies that the header omits — and
the route taken is proved by a self-test that drops a group from the header and sees the check fail.

### LK-30 The stories view's keybar is the only one that names neither the help key nor a way out — `blocked withdrawn by owner; the terminal UI is withdrawn (0013)`
`scripts/loop-tui.sh` draws a keybar under each of its four views, and it is the only place a
reader learns which keys the view in front of them answers to. The dashboard's is
` ? help   <sp> show   a add   x remove   r refresh   q quit`, the open view's is
` o sprint   s stories   r refresh   q quit`, and the show view's is
` ? help   o open   s stories   r refresh   q quit`. LK-20 made the stories view's two settings real,
and its keybar now reads ` e epic: any   d unticketed: shown   r refresh   q quit` — the only one of
the four that names no key taking you to another view and no `? help`. Both work there: `?` is the
handler's global help screen and `s` comes back to the dashboard. The help screen is also where
LK-20 documented `e` and `d`, so the one screen that explains the two new keys is the one the
stories keybar does not name.

`? help` is on two of the four keybars and a way out of the view on three, and the four are one
fact — which keys a view answers to — written down four times with nothing comparing them, which is
the LK-14/LK-16/LK-28 shape again. LK-20 saw it while widening this keybar and left it rather than
widen its own diff, the way LK-19 left LK-29's.
**Done when:** the stories view's keybar names `? help` and a key that leaves the view, so it
under-reports nothing the handler reads, and `scripts/loop-tui.sh --self-test` asserts it by named
line with the stories golden frame regenerated.

### LK-31 The other three keybars are cut at narrow widths, and `q` is off them at the 40-column floor — `blocked withdrawn by owner; the terminal UI is withdrawn (0013)`
LK-20 made the stories view's keybar give way in a fixed order — the labels shorten first, then the
key words, and the epic's name is cut last — so it states both settings and keeps `r` and `q` at
every width `frame_width()` allows. The other three bars are cut by `$emit` like any other line.
Measured on the LK-20 repair: the dashboard's reads ` ? help   <sp> show   a add   x remove …` at 40
columns, with `r refresh` and `q quit` both off it, ` ? help   <sp> show   a add   x remove   r …` at
44 with `q quit` still off, and ` ? help   <sp> show   a add   x remove   r refres…` at 50. The open
view's ` o sprint   s stories   r refresh   q quit` and the show view's
` ? help   o open   s stories   r refresh   q quit` have the same shape at the same widths.

So at the minimum supported width the frame does not name the key that quits the program, and the
only bar that adapts is the one LK-20 happened to touch. The self-test's width loop asserts only
that a line *fits*, never what it says, so nothing catches it: LK-20 added three key-driven
assertions at 40 for its own bar and the other three have none. LK-30 asks the stories bar to name
`? help` and a way out; this asks the other three to keep their keys. Both edit the same four lines,
so whichever lands second rebases onto the first.
**Done when:** each of the four keybars keeps its keys on the bar at every width `frame_width()`
allows, with the words giving way before the keys the way the stories bar now does, and
`scripts/loop-tui.sh --self-test` drives each one at 40 by named line with the affected goldens
regenerated.

### LK-32 `Never force-push` does not say whose history, and a repair after a failed review has no stated path
`AGENTS.md`'s Claims and hand-off bullet ends `Never push the default branch. Never force-push.
Never rewrite its history.` The first clause names the default branch and the next two do not, so
`its` reads as the default branch's — but three imperatives in a row read as three rules, and an
agent taking them that way must not force-push any branch. Nothing in the kit says which.

The kit rewrites a pull request's head itself: `scripts/open-ticket-pr.sh --update` is
`gh pr update-branch --rebase`, `--update-all` runs it over every pull request that is behind, and
`prompts/review-prs.md` says a rebased pull request "gets a new head commit and new checks". So the
prohibition cannot cover every branch without the kit contradicting itself — and the one place an
agent needs it plain is the one place it is not: a repair.

A pull request whose `Agent review` came back fail needs its defects fixed on the same branch, and
the status is pinned to a sha, so any repair changes the head and discards it. `prompts/review-prs.md`
reviews and posts and stops; `prompts/next-ticket.md` ends at a green pull request; neither says
whether the repair is another commit on the branch, a rebase, or `--update`. LK-20's repair (PR #50)
needed that decision, and took it wrongly: the three defects were fixed and the fix went out as
`git push --force-with-lease` when the commit was a direct child of the head the review had judged,
so a plain `git push` would have fast-forwarded and the question would never have arisen. The rule
was breached for no reason, which is the shape this ticket exists to close — a rule that does not say
what it is about cannot be obeyed knowingly.
**Done when:** `AGENTS.md` says which history the prohibition covers and what a repair after a failed
review is, and either `scripts/open-ticket-pr.sh` has a mode that lands one or the rule says plainly
that a repair is another commit pushed without a rewrite — with a check that a repair commit descends
from the head the review judged, so no repair ever needs a force.

## The prompts

### LK-12 grill-me grounds itself in the repository it is run in
`prompts/grill-me.md` assumes the project it runs in is loop-managed: it takes its settings from
`.loop.toml`, names `scripts/backlog-status.sh`, and says stories go at the top of the ticket
file when there is no product backlog. Run in a repository that has neither a settings file nor
a ticket file — as this one was before the bootstrap — it has no step that stops and asks where
the stories and tickets belong, and the session that produced LK-01 to LK-08 had to work that
out over two extra rounds. Add to section 1 a check for the settings file and the ticket file,
and when either is missing, a stop that asks the owner where the artifacts belong — this
repository, a new one, or a sibling — before any other question.
**Done when:** `scripts/prompt-check.sh`'s rules carry the new phrase, so deleting the step from
`prompts/grill-me.md` fails the check; and the pull request records a real run of the prompt in a
fixture checkout with no `.loop.toml`, showing it stop to ask where the artifacts belong.

### LK-18 The kit installs its commands but not its skills, so the skills a harness loads are copies that drift
The kit's prompts exist once, in `prompts/<name>.md`, and `commands/<name>.md` deliberately does not
restate them: it is a pointer — "Read `loop/prompts/<name>.md` and follow it exactly, with
`AGENTS.md` as the standing instructions" — so there is nothing to keep in step. The skills a
harness loads are the other half of that integration, and the kit does not own them. `install.sh`
takes `--commands <dir>` and has no flag for skills; the `SKILL.md` files a harness reads are copies
of the prompt body that someone made by hand. Nothing compares a skill with its prompt, so they
drift silently, and a drifted skill is worse than a missing one: the harness loads it, the agent
follows the older rule, and no check can see it, because the file it would have to compare is not in
the repository. It has already happened. On 2026-09-14 `next-ticket`'s skill was missing the
sentence that has `--next` take the `sprint` list first, in its order, then file order — so an agent
that loaded the skill worked tickets out of the order the list states, which is the failure LK-15
exists to catch; `review-prs`'s skill was missing the whole `scripts/open-ticket-pr.sh --update-all`
paragraph; and `grill-me`'s was missing four passages, among them the sprint paragraph LK-17 is
about. All three were re-synced by hand, which fixes the copies and not the cause: the next prompt
edit drifts them again, and an agent that reads the prompt and an agent that loads the skill
disagree about what the loop does.

Give the kit the skills the way it has the commands. Either ship a `skills/<name>/SKILL.md` per
prompt and install it with a `--skills <dir>`, so the skill is a pointer to the prompt and cannot
restate a rule — the `commands/` pattern, which makes drift impossible rather than merely
detectable — or keep the skills outside the kit and add the check that compares each one against its
prompt. Decide which, and say in `README.md` what a harness has to load.
**Done when:** a skill that states a rule its prompt does not fails `./check.sh` naming the skill
and the passage, proved by a self-test that drifts a paragraph into a skill and one that drops a
paragraph from it — or, if the skills ship as pointers instead, `install.sh --skills <dir>` installs
one per prompt, its self-test asserts each is the pointer naming `loop/prompts/<name>.md`, and a
self-test that replaces a skill's body with the prompt's fails — so a fresh install cannot
reproduce the drift this ticket was filed from.

### LK-27 grill-me requires three rounds and has no rule for an owner who ends them early
Section 2 of `prompts/grill-me.md` requires "at least three rounds" of questions, the last one on
proofs and edge cases, and forbids drafting a ticket with no named proof. Nothing says what to do
when the owner is satisfied before the third round. In the recorded run in LK-17's pull request the
owner answered round 2 with "Proceed to the write step", which leaves the agent two ways to be
wrong: draft without the proof round the same section demands, or spend a round the owner has just
ended. That run chose the second and said so inside the round it ran, which is the right call and
is nowhere in the prompt - so it is the agent's judgement, and two agents will differ. The prompt
is also the one place the round count is stated, so nothing else in the kit can settle it.
**Done when:** the prompt states, one way only, what happens when the owner ends the rounds early -
either that a proofs round still runs before the draft, or that the owner may end them and every
ticket in the draft must still name a proof; `scripts/prompt-check.sh` pins the phrase that states
it, as a new row in its table rather than prose alone; and the recorded run in LK-17's pull request
is named in the ticket as the case the wording was written from.

## The kit as a project

### LK-05 The kit's check runs the decision-record check
`./check.sh` runs every script's `--self-test`, `scripts/prompt-check.sh`, and
`install.sh --self-test`, but not `scripts/decisions.sh --check`, which the skeletons the kit
installs into projects do run (`templates/check/common.sh`, `loop_checks`). A record that loses
a section, or an index that falls out of step, therefore passes the kit's own CI while failing
in every project that carries the kit. Add the check to `./check.sh` beside `prompt-check.sh`.
**Done when:** `./check.sh` fails when `docs/decisions/` holds a record with a section removed
and when the index omits a record, and passes on the kit's own records; `install.sh`'s
self-test still passes, since a freshly installed project has no records for it to check.

### LK-06 The kit's ruleset requires the agent review — Blocked by LK-22
`.github/ruleset.json` (LK-13) names one required status, `Check (check.sh)`, and Tessera's ruleset
also waits for the agent review. `prompts/review-prs.md` reviews every open pull request whose
head carries no review status, but it runs from a schedule on a machine with the owner's
subscription and nothing runs it for this repository yet — so requiring its status before
something produces it would hold every kit pull request forever. Set the review running for this
repository, confirm it posts, and only then require its status. LK-09 applies the ruleset this
ticket then extends: until it lands this repository has no required status at all, not even the
check.
**Done when:** `scripts/review-status.sh --pending` lists a kit pull request whose head has no
review status, the review prompt has posted a verdict for it, and
`gh api repos/FueledByChai/coding-agent-loop/rulesets` shows the `Agent review` context among
the required status checks with a merge held until it is green.

### LK-07 Tessera's backlog stops carrying the loop's work — Blocked by LK-04
`FueledByChai/tessera`'s `BACKLOG.md` still holds the kit's history under `## Housekeeping`:
forty-eight `HK-` tickets, forty-three of them done, mixed in with Tessera's own housekeeping
(the deploy loop, `scripts/coverage.sh`, `scripts/scratch-console.sh`, the console layout
checks). With the kit its own project that section should hold only Tessera's own work. Move the
loop's share out with LK-04's filter: archive the forty-three done `HK-` tickets into a new
`CHANGELOG.md` there with `scripts/release-notes.sh --archive <tag> <from> <to> --prefix HK`,
note in the changelog's header that the commits proving them are in Tessera's history, remove
HK-41 from `BACKLOG.md` (it is kit work, and it moves to this backlog as LK-08) and from the
`sprint` list in `.loop.toml`, and leave HK-43, HK-45, HK-46, and HK-48 — Tessera's own code —
where they are. Tessera's `.loop.toml` moves `kit_ref` to the tag carrying LK-04 first, so the
filtered archive is the synced script. HK-46 is the one ticket that spans both repositories (a
kit default and a Tessera `.loop.toml` line); it stays whole there rather than being split for
one regex, and record 0001 names it as the exception.
**Done when:** `scripts/loop-kit-sync.sh --check` is clean in Tessera at the new `kit_ref`;
`grep -c '^### HK-' BACKLOG.md` there counts four; `git log --format=%s main | grep -oE
'^HK-[0-9]+' | sort -u | wc -l` there still finds the forty-three landed tickets, so the archive
lost nothing (count tickets, not commits: HK-27 carries two, so a raw `grep -c '^HK-'` reads
44); `CHANGELOG.md` carries their bodies under the archive tag; and
`scripts/backlog-status.sh --sprint` there lists no HK-41.

### LK-09 The repository's branch ruleset is applied, and auto-merge is on — Blocked by LK-13
`.github/ruleset.json` (LK-13) and the README's setup commands exist, but this repository has none
of them applied: `gh api repos/FueledByChai/coding-agent-loop/rulesets` is empty, `allow_auto_merge` is
false, `allow_merge_commit` and `allow_squash_merge` are still true, and
`delete_branch_on_merge` is false — so nothing gates a merge, and `--auto` is worse than useless:
with auto-merge disabled it does not arm anything, it merges on the spot. Both pull requests this
repository has merged went in mid-check: PR #19 at 19:44:26Z, five seconds into a run that
started at 19:44:21Z and finished green at 19:45:13Z, and PR #20 at 19:57:30Z, thirteen seconds
into a run that started at 19:57:17Z and finished green at 19:58:06Z. The second was
`gh pr merge 20 --auto --rebase`, which printed `✓ Rebased and merged pull request #20` — the
flag the loop's merge policy depends on did the opposite of arming. Apply what the README
documents:
`gh api -X PATCH repos/FueledByChai/coding-agent-loop -F allow_auto_merge=true -F
delete_branch_on_merge=true -F allow_merge_commit=false -F allow_squash_merge=false -F
allow_rebase_merge=true`, then `gh api -X POST repos/FueledByChai/coding-agent-loop/rulesets
--input .github/ruleset.json`, the file LK-13 gives this repository. It is not `ci/ruleset.json`,
which has to keep the context a project's workflow reports. This is the prerequisite for LK-06,
which extends the ruleset, and for the loop's own hand-off, whose merge policy arms auto-merge and
has nothing to arm without it.
**Done when:** `gh api repos/FueledByChai/coding-agent-loop` reports `allow_auto_merge: true`,
`delete_branch_on_merge: true`, `allow_merge_commit: false`, `allow_squash_merge: false`, and
`allow_rebase_merge: true`; `gh api repos/FueledByChai/coding-agent-loop/rulesets` lists the
ruleset with `enforcement: active` and `Check (check.sh)` — the context this repository's workflow
reports, per LK-13 — among its required status checks; and a test pull request shows the check
required, with `gh pr merge <n> --auto --rebase` arming auto-merge and the merge happening only
once the check is green.

### LK-11 The check's cost is measured, and the install self-test stops repeating the suite
`./check.sh` takes about eight minutes here, not the seconds `AGENTS.md` claims, because
`install.sh --self-test` runs the whole self-test suite once per stack skeleton — rust, python,
node, java, go, other — six full passes, each redirected to its own log so nothing appears on
the terminal while it happens. Only the stack step differs between the six; the loop checks each
one runs are identical, and repeating them is what makes the check slow enough that a
contributor assumes it has hung. Run the loop checks once and prove the six skeletons' stack
steps separately. The eight minutes is the machine's figure, not the kit's: the same script on
CI's ubuntu-latest runner ran every self-test and the install in 54s (run 34781943672,
20:49:23Z to 20:50:17Z), and the eleven self-tests that are not the install take 1m 02s here
against 6.6s there. The six passes are the cost in both places — 87% of the total there, 88%
here — so the diagnosis holds and only the number needs a machine beside it.
**Done when:** `install.sh --self-test` prints how many times it ran the loop checks and that
number is 1; each of the six skeletons is still proven to pass on an empty repository; and
`time ./check.sh` is reported in the pull request and matches the figure `README.md` and
`AGENTS.md` state.

### LK-15 The sprint is said to hold every open ticket, and nothing checks that it does
`.loop.toml` says the `sprint` list is "Every open ticket, in the order to work them", and
`scripts/backlog-status.sh --next` takes the first ready one of these before falling back to file
order. The pairing is checked in one direction only: a sprint id with no heading is reported —
`sprint: ZZ-99 is not in the backlog file` (`backlog-status.sh:181`, with a self-test at `:310`) —
while a heading for an open ticket with no sprint entry is reported nowhere. `--next` walks the
sprint and, only when nothing in it is ready, announces the fallback and walks the file
(`:190-192`), so a ticket filed
without a sprint entry sits outside the order the list claims and is worked in file order once the
sprint drains — and file order is not sprint order: this repository's headings run LK-01, LK-02,
LK-03, LK-04, LK-08, LK-10, LK-12, LK-05, LK-06, LK-07, LK-09, LK-11 while its sprint runs
LK-01…LK-12. The only sign of the omission is a count in another flag's output: `--open` ends
`open: N ticket(s) not done and not in the sprint`, which reads as a design — the flag's own comment
calls those the list for the next sprint (HK-40) — rather than as an omission, and nothing fails.
`scripts/sprint.sh add` will not let an id into the sprint that is not a heading and not done, but
nothing keeps the other direction whole; two tickets filed in parallel make it likelier, because
both append to the one `sprint` line and both edit `BACKLOG.md`, so one resolution can drop the
other's entry with nothing noticing. That is how this ticket was found.

Decide which the sprint is — every open ticket, as `.loop.toml` says, or the current sprint's subset,
as `--open`'s comment assumes — and make the check say so, both directions of the pairing checked
alike.
**Done when:** an open ticket in the backlog file that `sprint` omits makes `./check.sh` fail naming
it — a heading whose ticket is already done may leave the sprint freely, since the invariant is about
open tickets and completion is derived from git — or, if the subset reading is chosen, the `sprint`
comment and `--next` state it and `--next` or `--sprint` report the omission rather than only
`--open` counting it — proved by a self-test that drops an open heading's id from `sprint` and one
that adds an id with no heading.
### LK-14 The kit's check and a project's check keep the loop's check list in two places — Blocked by LK-05
`check.sh` and `templates/check/common.sh`'s `loop_checks` both enumerate the loop's checks by
hand: the same eleven `--self-test` calls, then `prompt-check.sh` and `decisions.sh --check`.
`AGENTS.md` asks the author of a new script to add it in three places — `check.sh`, `install.sh`'s
self-test, and `templates/check/common.sh` — and nothing compares them, so the only thing keeping
the two lists equal is that someone remembered. They have already drifted once: the kit's check ran
no `decisions.sh --check` while every project's did, which is LK-05 — and which is why this is
blocked by it: a test comparing the two lists fails on that drift until LK-05 lands, so working this
first would either fail on it or quietly absorb LK-05's work. The next script, or the next
check added to one side, repeats it silently, because a check line that is missing looks exactly
like a check line that passed.
**Done when:** adding a check to the kit's `check.sh` or to `templates/check/common.sh` without
the other cannot leave them apart — one list derived from the other, or a test comparing them —
proved by a self-test that drops a check from one side and sees `./check.sh` fail naming it.
### LK-13 The ruleset this repository would apply requires a status its CI never reports
`ci/ruleset.json` names one required status check, `"Check (scripts/check.sh)"`, and LK-09
applies that file to this repository with `gh api -X POST .../rulesets --input ci/ruleset.json`.
But the only workflow here, `.github/workflows/ci.yml`, names its job `Check (check.sh)` and runs
`./check.sh`: the kit's check sits at the repository root, not under `scripts/`, which is what
`.loop.toml`'s `check = "./check.sh"` and `AGENTS.md` both say. `gh pr checks 22` and
`gh pr checks 23` each report exactly one check, `CI/Check (check.sh)`. A required context is
satisfied by a check run of that name and no other, so `Check (scripts/check.sh)` is a context
nothing here will ever report — and the moment LK-09 lands, every pull request waits for a status
that never arrives and nothing merges. LK-09's own done-when would pass while that happened: it
asks that the ruleset list `Check (scripts/check.sh)`, which is the very string that is wrong.

`ci/ruleset.json` is right for what it is. It is the file `install.sh` gives a project, paired
with `ci/workflow.yml`, whose job is `Check (scripts/check.sh)` and which runs
`scripts/check.sh` — a project's check does live under `scripts/`. The kit's own workflow is a
hand-written sibling of that template rather than a copy of it, and nothing compares the two:
`install.sh` only tells the operator to "compare with the kit's `ci/workflow.yml`" by eye. So one
file is being asked to serve two repositories whose check scripts sit in different places, and
neither the kit's check nor its CI notices when the pair drifts.

Give this repository its own ruleset at `.github/ruleset.json` — beside `.github/workflows/ci.yml`,
the workflow it has to match, while `ci/ruleset.json` stays the template a project applies beside
`ci/workflow.yml` — whose context is the job this repository actually reports, and make the pairing
something the check tests rather than something a person is asked to look at. Naming the file is
part of this ticket rather than a detail left open: LK-09's command and LK-06's paragraph each name
a ruleset file and both land after this one, so the name has to be fixed before either can be
written down correctly — LK-09's command still posts `ci/ruleset.json`, the very file this ticket
says must keep the context that deadlocks this repository. `README.md`'s table and `AGENTS.md`'s
`ci/` line then want a word about which file belongs to whom.
**Done when:** `.github/ruleset.json` names `Check (check.sh)` and not
`Check (scripts/check.sh)`, and is the file LK-09 applies; `ci/ruleset.json` still names
`Check (scripts/check.sh)` and still matches `ci/workflow.yml`, so nothing a project installs
changes; and `./check.sh` fails when a ruleset file and the workflow it pairs with disagree,
proved by a self-test that renames the job and one that renames the context.

### LK-16 The check section of AGENTS.md is one paragraph spliced onto another, and it contradicts the check
Two branches rewrote `AGENTS.md`'s "The check" section at the same time — LK-05 (`a9d52e6`, the
decision-record check is wired into `./check.sh`) and LK-11 (`92d0085`, the install self-test runs
the loop's suite once, so the check takes about three minutes) — and the merge that landed both
kept a piece of each. What ships on the default branch is LK-11's paragraph with LK-05's stale
sentence left on the end of it, followed by the remains of LK-05's paragraph with its opening
sentence cut off, so the section starts a new paragraph mid-clause:

```
... Nothing is resolved from a worktree, since there is nothing to build.
`scripts/decisions.sh --check` is not wired in yet (LK-05).
`scripts/decisions.sh --check` (the kit's records answer to the same sections and index a
project's check demands of them), then `./install.sh --self-test`, which installs into a fresh
repository and runs the installed scripts' self-tests there. There is no fast variant — the whole
thing takes seconds. Nothing is resolved from a worktree, since there is nothing to build.
```

The section says the decision-record check is not wired in, one line above the sentence that says
it is; gives two figures for the same run, "about three minutes on a laptop, under a minute on CI"
and "takes seconds"; and states "nothing is resolved from a worktree" twice. `./check.sh` runs
`scripts/decisions.sh --check`, so the file that defines done disagrees with the script that
enforces it — the defect LK-05's own commit message names, reintroduced by a merge resolution
rather than by an edit, and the same shape as LK-14 and LK-15: one fact kept in two places with
nothing comparing them. `scripts/prompt-check.sh` pins phrases in `prompts/*.md` and nothing reads
`AGENTS.md`'s prose, so a splice like this is invisible to every check and to a reader who trusts
the heading — which is what makes it worth a ticket rather than a quiet fix: nothing here would
have caught it, and nothing will catch the next one.
**Done when:** `AGENTS.md`'s "The check" section is one paragraph stating the sequence `./check.sh`
runs, `scripts/decisions.sh --check` among them, with no sentence saying that check is not wired in
and one figure for the run — the figure `README.md` states and `time ./check.sh` reports here; and
the section's list of checks cannot drift from the script again, either by `scripts/prompt-check.sh`
pinning it or by a check comparing the two, proved by a self-test that drops a check from one side
and sees `./check.sh` fail naming it.

### LK-17 grill-me offers "or none" for the sprint, which one reading of the sprint does not allow
LK-15 settled that `sprint` in `.loop.toml` means one of two things and made the check enforce the
stricter one here: either the tickets chosen for now, leaving the rest as the pick list `--open`
prints, or every open ticket, so an omission is a fault — this repository means the second and runs
`scripts/backlog-status.sh --sprint-check` from `./check.sh`. `prompts/grill-me.md` still states only
the first. Its sprint paragraph opens "`sprint` in `.loop.toml` is the list of tickets chosen for
now, in order", and closes by telling the agent to "Ask the owner which of the new tickets go into
the sprint and where (ahead of, behind, or between the ones there), **or none**". Under the reading
this repository uses there is no "none": a ticket the prompt files and leaves out of the sprint is a
ticket the next `./check.sh` fails on, so the prompt's own hand-off produces the state its own check
rejects, and the agent that followed it is left to discover why.

The prompt is shared with projects, and a project that keeps the subset reading does allow "none", so
the fix is not to drop the choice but to state both and point at the ticket file's own comment as
the thing that settles which applies — the shape LK-15 gave `AGENTS.md`'s sprint bullet for exactly
this reason, and the reason `loop.toml.example` now carries the same note.

A prompt is not edited without a recorded run: `scripts/prompt-check.sh`'s header states that the
phrases it pins are one half of a prompt's proof and a real run in the pull request is the other.
That is what keeps this out of LK-15 and makes it its own ticket.
**Done when:** `prompts/grill-me.md`'s sprint paragraph states both readings, names the `.loop.toml`
comment above the list as the thing that settles which one applies, and does not offer "or none"
except under the subset reading; `scripts/prompt-check.sh` still finds the phrases it pins for that
prompt; and the pull request carries a recorded run of the prompt against a repository using the
stricter reading, showing a filed ticket added to the sprint rather than left out.

### LK-21 `.loop.toml` names the wrong ruleset file for this repository's own gating
The comment above `review_context` says `ci/ruleset.json does not require it here yet (LK-06)`.
"Here" is this repository, and this repository's own ruleset is `.github/ruleset.json`: the two
files differ by the one context they require — `Check (check.sh)` here, `Check (scripts/check.sh)`
in the template a project installs — and that difference is what LK-13 was filed to settle. LK-13
updated `AGENTS.md`'s `ci/` paragraph and `README.md`'s table to say which file belongs to whom;
`.loop.toml`'s comment was written before it (`1cb4511`, which created the file) and still names
the file that has to keep the other context, which is the one thing LK-09's own text is careful
about ("It is not `ci/ruleset.json`"). The cost is small and it lands in the worst place: the file
a reader opens to learn what governs this repository's merges points at the ruleset a project
applies instead.

LK-06 landed after this was filed, so the comment is now wrong twice over: it names the wrong file
*and* says the review is not required here yet, which `.github/ruleset.json` has required since
LK-06. The fix is one comment either way — name this repository's own ruleset and say that it does
require the review — so this ticket is where both are written right, rather than LK-06 editing a
comment LK-21 exists to correct.
**Done when:** the comment names `.github/ruleset.json` as the ruleset that requires the review here
(not the template a project applies, and not "yet"), and `./check.sh` passes with nothing else in
`.loop.toml` changed.

### LK-23 The check takes about eight minutes here and about one on CI, and nothing explains the gap
Measured while working LK-16, with LK-11 long landed: the fourteen self-tests take 150s (50s of
that `scripts/loop-tui.sh` alone), `./install.sh --self-test` takes 282s, and `time ./check.sh`
reports 8m18s in total - against the 57-64s the `Check (check.sh)` job takes on CI for the same
script. The loop's suite also runs twice in every full check: `./check.sh` runs it, and then the
install self-test runs it again inside the fresh repository, which is most of the second figure.
LK-11 measured 6m59s before its change and claimed about three minutes after it, and nothing
measured it again until now - which is how the figure the docs stated drifted from the figure
`time` reports, the defect LK-16 corrected the wording of without asking why.
**Done when:** either the check is measurably faster, with the figure in `AGENTS.md` and
`README.md` corrected to what `time ./check.sh` then reports, or the difference between this
machine and CI is written down where a contributor reads it, naming what costs the time and why
it cannot be removed.

### LK-24 `prompts/next-ticket.md` hands off a pull request that cannot merge until another prompt has run
Step 6 says "The owner merges the PR", which was true when it was written and is now true of
nothing: `scripts/open-ticket-pr.sh` arms auto-merge, so the PR merges itself, and since LK-06 this
repository's ruleset also requires `Agent review`, which only a scheduled run of
`prompts/review-prs.md` posts. An agent that follows the prompt finishes believing its PR is ready
while it sits `BLOCKED` on a status that arrives on a schedule - and the prompt never mentions the
review at all. LK-16 ran into exactly that: the branch was green on CI, armed, and blocked, and the
report could only say so.
**Done when:** step 6 says what actually merges the PR and names the review status its branch has to
carry before that happens, and `scripts/prompt-check.sh` pins the phrase that states it.

### LK-25 `AGENTS.md`'s Prompts bullet names a path this repository does not have
The Prompts bullet names `loop/prompts/next-ticket.md`, `loop/prompts/grill-me.md`,
`loop/prompts/grill-project.md` and `loop/prompts/review-prs.md`. That is the layout `install.sh`
gives a project: it copies the kit's `prompts/` to `loop/prompts/` there, which is why
`commands/*.md` points at that path on purpose. This repository is the kit, and `git ls-files loop`
is empty - the files are `prompts/*.md`. The same file says so in its own inventory forty lines
later ("`prompts/*.md` are what an agent follows"), so the bullet contradicts it, and the standing
instructions send a reader to four paths that do not exist in the checkout they are reading. The
run recorded in LK-17's pull request hit it and named it as "the installed-project layout" - the
same class as LK-16, which is the check section of this file misdescribing the check.
**Done when:** every prompt path `AGENTS.md` names exists in this checkout -
`prompts/next-ticket.md`, `prompts/grill-me.md`, `prompts/grill-project.md` and
`prompts/review-prs.md` - and any line that still mentions `loop/prompts/` says it is a project's
layout rather than this repository's, so `grep -n 'loop/prompts' AGENTS.md` finds only such a line
or nothing; and `./check.sh` passes.

### LK-26 The trailer rule names three different things and only its presence is checked
`AGENTS.md` says a commit carries "a `Co-Authored-By: <agent> <email>` trailer naming the agent and
model that did the work when `trailer_required` is on (the PR script refuses a commit without
one)", and `.loop.toml` sets `trailer_required = true`. Three texts disagree about what goes in it:
`AGENTS.md` says "the agent and model", `scripts/open-ticket-pr.sh:129` says "the agent that did the
work", and every commit in this repository's history carries `Co-Authored-By: WorkBuddy AI
<noreply@workbuddy.ai>` - a harness and a role, naming neither an agent nor a model. Nothing can
tell the three apart, because the refusal only asks whether a trailer is there at all:
`head_trailer` (`scripts/open-ticket-pr.sh:104`) reads the line and the caller tests it with `-z`.
So the rule cannot be followed as written and a reader cannot learn from it what to write. The run
recorded in LK-17's pull request followed the history and flagged the difference rather than
inventing a name, which is the behaviour the ticket exists to settle.
**Done when:** one wording in all three places - `AGENTS.md`, the refusal message in
`scripts/open-ticket-pr.sh`, and the trailer the next commit carries - says the same thing about
what the trailer names; the script's message says what the script actually tests, which is that a
trailer is present rather than what it says; and `./check.sh` passes.
### LK-28 The command wrappers and the skill pointers are the same sentences twice, and nothing compares them
LK-18 made `skills/<name>/SKILL.md` a pointer at its prompt so that it cannot restate a rule, and
left `commands/<name>.md` where it was: the same pointer, for a harness with slash commands. The two
files now carry the same sentences. Each wrapper is "Read `loop/prompts/<name>.md` and follow it
exactly, with `AGENTS.md` as the standing instructions." plus one ticket-specific sentence — "Work in
an isolated worktree." for `next-ticket` — and each skill is that text minus the `$ARGUMENTS` clause
a command substitutes into, under the frontmatter a harness needs to load it. Three of the four
skills differ from their wrapper only by that clause; `review-prs`'s skill and its wrapper are
identical.

Nothing compares them. `install.sh`'s `check_skill` compares a skill with the prompt it points at
and never with the wrapper beside it, so an edit to one of the pair leaves the two harnesses
disagreeing about what the loop does — the fault LK-18 was filed from, one level down: an agent that
loads the skill and an agent that runs the slash command read different instructions while both read
the right prompt. It is the LK-14/LK-15/LK-16 shape again, two places holding one fact with nothing
keeping them in step, and `scripts/prompt-check.sh` does not see it, since it pins phrases in
`prompts/*.md` and reads neither pointer.

The cheap fix is to derive one from the other: the wrapper is the body, the skill is that body under
frontmatter, so there is one copy and each skill's `description:` stays the only hand-written part.
**Done when:** `./check.sh` fails when a command wrapper and the skill beside it disagree, naming the
pair and the passage — proved by a self-test that drops a sentence from one side — or the skill's
body is derived from its wrapper at install time, so that a disagreement cannot exist.

### LK-33 `backlog-status.sh --plain` has no reader now that the terminal UI is withdrawn
`--plain` prints `--stories` and `--open` as tab-separated fields with nothing cut, so a renderer
can lay them out at its own width. Its only caller was `scripts/loop-tui.sh`, which 0013 removed,
so the mode now serves a renderer that does not exist — and a mode nothing reads is the shape this
kit keeps filing against itself (LK-20). Either remove the mode and its self-test, or name what
reads it; the padded tables are what a person and a prompt read.
**Done when:** `./check.sh` passes with `--plain` either gone from `scripts/backlog-status.sh` —
its flag, its Perl branches, and its self-test's assertions all removed, with the padded tables
unchanged — or kept and given a caller named in this file and in the script's header comment.

### LK-34 The terminal UI is withdrawn, and the records that describe it are superseded
`scripts/loop-tui.sh` is the kit's only interactive surface: 1777 lines, the largest file here,
and the subject of both product stories (LS-01, LS-02), four decision records (0002, 0003, 0004,
0011), and two open tickets (LK-30, LK-31). The owner drives the loop from the prompts —
`next-ticket`, `grill-me`, `grill-project`, `review-prs` — loaded as skills, and does not use the
screen; a frame that restates what `scripts/backlog-status.sh` already prints is a second
derivation of the same figures, the shape this kit keeps filing against itself (LK-11, LK-14,
LK-16, LK-20, LK-28). Decision 0013 records the withdrawal, 0012 records Beads as the ticket
store that replaces the markdown queue, and the four records that describe the screen are
superseded where they stand.
**Done when:** `./check.sh` passes with `scripts/loop-tui.sh` gone; `check.sh`,
`templates/check/common.sh`, and `install.sh` name no `loop-tui`; LK-30 and LK-31 carry the
`blocked withdrawn by owner` claim that keeps `--next` off them; and `scripts/backlog-status.sh
--self-test` still passes, because the field mode the renderer read (`--plain`) stays until its
own ticket (LK-33) moves it.

### LK-35 The kit ships helpers in Python too, and the JaCoCo coverage figure is one of them
`scripts/*.sh` is the shipping surface: `install.sh` and `scripts/loop-kit-sync.sh` both glob
that extension, so a helper in another language never reaches a project — it would sit in the
kit looking shipped and be absent everywhere the kit is installed. The Beads import path, the
project-owned build helpers (a JaCoCo coverage figure, a Compose proof), and this kit's own
record say otherwise: the loop needs one non-shell helper and the honest place for it is
`scripts/`. Widen both globs to carry `scripts/*.py` as well as `scripts/*.sh`, and put the
first real one there: `scripts/coverage-percent.py`, the JaCoCo line-coverage figure that
`templates/check/java.sh` currently documents as a `python3 -c` one-liner for every Java
project to copy by hand.
**Done when:** `./check.sh` passes with `scripts/coverage-percent.py` installed into the fresh
repository by `install.sh --self-test`, which runs the helper's own `--self-test` there;
`scripts/loop-kit-sync.sh --self-test` proves a `.py` file is copied, is identical after a
sync, and is reported as drift when the project edits it; and `templates/check/java.sh` names
the helper rather than repeating its one-liner.

### LK-36 The readiness gate is a kit script, and it can judge one pull request
A green build is not a merge-ready pull request: the check can pass on a branch that is behind
with a review outstanding, an unresolved conversation, and a branch that names no ticket at
all. rockbox-ghl wrote the six facts a person reads into `scripts/pr-readiness.sh`, and it is
the one project-owned script every consumer of this kit needs: the criteria come from
`.loop.toml` (`check`, `review_context`, `default_branch`) and from the branch and subject that
`open-ticket-pr.sh` already names, so nothing in it is rockbox-shaped. Bring it up, and add
what a queue report cannot do — `--pr <number>` judges one pull request, so the owner can ask
about the one they are looking at without reading the whole queue. Two readings get fixed on
the way: the check command is compared as the file it names (`./check.sh` in the kit's
`.loop.toml` is the job `Check (check.sh)` its workflow reports), and a pull request that
targets something other than the default branch is refused rather than judged.
**Done when:** `./check.sh` passes with `scripts/pr-readiness.sh` installed into the fresh
repository and its `--self-test` in the shared check block; the self-test shows each of the six
criteria failing alone with a reason while the other five pass, `--pr 12` reading one pull
request without listing the queue and reporting `#12 is ready`, a number that is not there
exiting non-zero, and a pull request to another branch refused by name.

### LK-37 The queue's own references are checked by the kit, not by each project
Every project writes the same integrity check beside its backlog: that each `Serves` names a
story that exists, each `Blocked by` names a ticket that exists, no dependency cycle means a
ticket never becomes ready, every ticket carries the **Done when** line the loop's whole notion
of done rests on, and every `Decisions: NNNN` names a record. rockbox-ghl carries it in its
project-owned `check.sh` where nothing shares it; the kit's own copy of the same faults has no
check at all, which is why a ticket can be filed with a typo for its blocker and `--next` will
walk it in silence. Bring it up as `scripts/reference-check.sh`, scoped to the id spaces the
project's own headings define, so a ticket may still quote another project's ids as prose.
**Done when:** `./check.sh` passes with `scripts/reference-check.sh` in the shared check block
and its name in "The check" above, and its `--self-test` shows the clean queue passing while a
missing **Done when** line, an unknown dependency, a dependency cycle, a duplicate id, an
undefined ticket or story named in either file, and a citation of a record that does not exist
each fail alone naming the file and the fault.
