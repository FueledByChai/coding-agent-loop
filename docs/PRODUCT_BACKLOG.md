# Product Backlog

This is the working feature and user-story backlog for the ticket loop. It records product
intent and acceptance criteria; it is not evidence that a feature has been implemented. The
tickets live in Beads (0012), so a story is intent and a ticket's `story:<ID>` label says which
story it serves.

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

### LS-01 — Withdrawn

The terminal UI this story described was withdrawn with the `loop-tui.sh` that rendered it
(0013). The id is kept so the tickets and records that name it still resolve; no ticket serves
it.

### LS-02 — Withdrawn

Withdrawn with LS-01 (0013); the id is kept for the same reason.


### LS-03 — Serialize reviewed changes through final validation

**In progress.** As a project owner, I want agents to complete code and acceptance review before
one selected PR is refreshed and tested, so waiting PRs do not pay repeated CI costs each time
another change lands.

Acceptance: durable queue state survives restarts; only one candidate can hold the promotion
slot; changed commit, base or evidence invalidates prior readiness; author workers handle
review findings; waiting candidates receive no queue-driven rebase or CI; a trusted required
GitHub check enforces final validation before merge. Decision 0016 starts with a shadow-only
foundation; its existence alone does not establish the live acceptance criteria.
