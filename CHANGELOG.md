# Changelog

What shipped, by release: the commits that carry a ticket id between two tags, with the
ticket text read from Beads (scripts/release-notes.sh --archive).

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

