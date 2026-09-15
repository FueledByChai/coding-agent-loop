# Product Backlog

This is the working feature and user-story backlog for the ticket loop. It records product
intent and acceptance criteria; it is not evidence that a feature has been implemented.

Statuses: **Proposed**, **Ready**, **In progress**, **Complete**, or **Deferred**. The written
status is intent; the status that matters is the one `scripts/backlog-status.sh --stories`
derives from git — `done` when every ticket that serves the story has landed, `open k/n` while
some are left, `unticketed` when no ticket names it.

Architecture and product decisions are the records under `docs/decisions/` (index in its
`README.md`): cite them by number and never restate one here.

The loop's work used to be ticketed in `FueledByChai/tessera`, whose Epic I holds the stories
BT-901 to BT-906 for the same tooling (decision 0001). Those stay there for now; stories written
from here on live here.

## Epic A: The loop's tooling

### LS-01 — The loop's state is one screen in the terminal

**Status:** Proposed
**User story:** As the owner, I want the queue, the sprint, and the stories on one terminal
screen with the command for the next action beside them, so that I stop having to remember
which of the loop's scripts to run and which flags it takes.

**Acceptance criteria:**

- `scripts/loop-tui.sh` prints one screen — a header, the sprint as a table with each ticket's
  state, readiness and blockers, the next ticket with the exact command that claims it, the
  counts of what is left, and a stories line — and exits; it starts no terminal session and
  writes nothing.
- The views are chosen by argument: no argument is the dashboard, `stories` lists every story in
  the product backlog with its derived status, `open` lists the tickets outside the sprint
  grouped by section, and `show <id>` prints one ticket or story in full with its state and the
  story it serves.
- Every line fits the terminal's width: a narrower terminal drops columns rather than wrapping
  or truncating a number mid-figure, and `--width` fixes the width so the output can be piped
  and diffed.
- When there is nothing left — every ticket done, no sprint set, no `.loop.toml`, or no backlog
  file — the screen says which, and prints no empty table.
- One renderer draws every view, so the interactive mode is a key handler over these frames
  rather than a second implementation.

**Wireframe** (the dashboard, 78 columns; run in a project, so the tickets are that project's):

```
TICKET LOOP  Tessera  main@beed072   13 in sprint: 3 done 9 ready 1 claimed
----------------------------------------------------------------------------
 SPRINT
   #  id     state    ready  blocked  title
   1  UI-10  done       -              The dialog fit check covers choice…
   2  WB-16  done       -              Promotion freezes the study and the…
   3  WB-17  done       -     WB-16    A nightly job rescores promoted fe…
   4  WB-18  claimed    -     WB-17    The studies page shows decayed fea…
   5  DS-12  todo      yes    DS-04    Exchange resolutions come from the…
   6  DS-13  todo      yes    DS-07    The usage refresh has a short time…
   7  DS-14  todo      yes    DS-08    Catalog files are regenerated per …
   8  DS-15  todo      yes    DS-08    The EOD nightly's call discipline b…
   9  HK-41  todo      yes             --stories counts the tickets archi…
  10  HK-43  todo      yes             The scratch console from a worktree…
   …  (3 more)
----------------------------------------------------------------------------
 NEXT  DS-12  Exchange resolutions come from the provider, not from a ta…
       -> scripts/open-ticket-pr.sh DS-12 --claim
----------------------------------------------------------------------------
 LEFT  9 ready  1 claimed  0 blocked   outside the sprint: 0 open tickets
 STORIES  70 - 16 done - 5 open - 49 unticketed
----------------------------------------------------------------------------
 ? help   <sp> show   a add   x remove   r refresh   q quit
```

**Wireframe** (the stories view; every story, unticketed ones shown as such):

```
STORIES  70 - 16 done - 5 open - 49 unticketed
------------------------------------------------------------------------------
 id       status      t  epic                       title
 BT-101   unticketed  -  Epic A: Strategy, engine   Versioned strategy-packa…
 BT-607   open 0/1    1  Epic F: Data inventory     Move run-specific covera…
 BT-901   done        2  Epic I: Delivery loop q    Every code change ships …
 BT-906   done        2  Epic I: Delivery loop q    grill-me grills, and sho…
 BT-1207  done        2  Epic L: Provider data so   Per-dataset schedules in…
 …
------------------------------------------------------------------------------
 e epic: any   d unticketed: shown   r refresh   q quit
```

**Wireframe** (the open view; the tickets outside the sprint, by section):

```
OPEN  0 tickets outside the sprint (the sprint holds every open ticket)
----------------------------------------------------------------------------
 (when it does not, the tickets group by section)
 Data sources
   DS-16  todo   Blocked by DS-12!   The intraday probe is cached per ex…
 Housekeeping
   HK-49  todo   ready               loop-tui.sh renders the loop's state…
----------------------------------------------------------------------------
 o sprint   s stories   r refresh   q quit
```

### LS-02 — The loop is driven from the terminal

**Status:** Proposed
**User story:** As the owner, I want to move through the sprint, open a ticket in full, and add
or remove tickets without editing `.loop.toml` by hand, so that choosing what to work on next is
one screen rather than a script and its flags.

**Acceptance criteria:**

- With a terminal, `scripts/loop-tui.sh` takes the alternate screen, hides the cursor, and reads
  single keys: move, open a ticket or a story in full, add a ticket to the sprint, remove one,
  switch to the stories and open views, refresh, and quit.
- Adding and removing edit only the `sprint` list in `.loop.toml`, through
  `scripts/sprint.sh`. The screen marks the change as uncommitted, and the script never runs
  `git add`, `git commit`, or `git push`.
- An add is refused, with the reason on screen, when the id is not a ticket heading, is already
  done, or is already in the sprint.
- The screen redraws when a key is pressed; `r` fetches from origin first, and nothing is
  fetched otherwise.
- With stdout not a terminal, or with `--keys`, it renders frames instead of taking the screen,
  so the whole program is driven without a pseudo-terminal.
- On every exit path, including a signal, the terminal is restored: alternate screen off, cursor
  visible, echo back.

**Wireframe** (the interactive screen, 78 columns; the marked row is the selection):

```
TICKET LOOP  Tessera  main@beed072   13 in sprint: 3 done 9 ready 1 claimed
----------------------------------------------------------------------------
 SPRINT                                    selected: DS-12 (todo, ready)
 > 1  UI-10  done       -          The dialog fit check covers choice…
   2  WB-16  done       -          Promotion freezes the study and the…
   3  WB-17  done       -  WB-16    A nightly job rescores promoted fe…
   4  WB-18  claimed    -  WB-17    The studies page shows decayed fea…
   5  DS-12  todo      yes DS-04    Exchange resolutions come from the…
   6  DS-13  todo      yes DS-07    The usage refresh has a short time…
   7  DS-14  todo      yes DS-08    Catalog files are regenerated per …
   8  DS-15  todo      yes DS-08    The EOD nightly's call discipline b…
   9  HK-41  todo      yes          --stories counts the tickets archi…
----------------------------------------------------------------------------
 NEXT  DS-12  Exchange resolutions come from the provider, not from a …
       -> scripts/open-ticket-pr.sh DS-12 --claim
----------------------------------------------------------------------------
 LEFT  9 ready  1 claimed  0 blocked   outside the sprint: 0 open tickets
 STORIES  70 - 16 done - 5 open - 49 unticketed
----------------------------------------------------------------------------
 j/k move  <sp> show  a add  x remove  s stories  o open  r refresh  q quit
                                                     UNCOMMITTED: sprint
```
