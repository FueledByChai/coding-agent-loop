# 0013 — The terminal UI is removed and the prompts with their skills are the whole interface

Status: accepted, supersedes 0002
Date: 2026-09-16

## Context

The kit grew a terminal UI. `scripts/loop-tui.sh` rendered the dashboard and the `stories`,
`open`, and `show` views as frames, and with a terminal it took the alternate screen and answered
single keys (0002, 0003, 0004). By the time it was withdrawn it was 1777 lines — the largest file
in the kit — and the kit's own product backlog had narrowed to it: both stories in
`docs/PRODUCT_BACKLOG.md` (LS-01, LS-02) describe the screen and its keys, and two of the open
tickets (LK-30, LK-31) were keybar repairs on views LK-02 and LK-03 had added.

The owner does not drive the loop from it. The loop is started from a harness that loads the four
prompts as skills (`next-ticket`, `grill-me`, `grill-project`, `review-prs`), and a screen that
restates what `scripts/backlog-status.sh` already prints is a second derivation of the same
figures — the shape 0004 and 0011 exist to keep in step, and a shape the kit keeps filing tickets
against itself over (LK-11, LK-14, LK-16, LK-20, LK-28).

## Decision

The kit ships no terminal UI. `scripts/loop-tui.sh` is deleted and the records that describe it
(0002, 0003, 0004, 0011) are superseded; `prompts/*.md` and the skills that point at them are the
whole interface; and `scripts/backlog-status.sh` keeps printing the tables and answering `--next`,
`--sprint`, `--open`, `--show`, and `--stories` for whoever asks directly.

## Alternatives

- **Keep it and stop maintaining it.** An affordance nothing reads is a lie printed on the frame
  (LK-20), and a screen left in the tree while the work moves to prompts reads as the way in.
- **Keep the one-shot renderer and drop the interactive mode.** The same objection at a smaller
  size: `--render` and `--keys` exist to prove the keys and the views, which are the part being
  withdrawn.
- **Replace it with a board in a browser.** The same second derivation with a port, a process,
  and a front end to keep in step, and this repository is bash that ships only scripts (0002).
- **Land LK-30 and LK-31 first, then withdraw it.** Both are repairs to a screen that is going
  away; the work would have been spent twice.

## Consequences

The kit loses its only interactive surface. `--plain` on `scripts/backlog-status.sh` — a
tab-separated field mode whose only caller was the renderer — now has no reader. This change
leaves it in place and files it as its own ticket, because a ticket does not grow by what it
finds; `scripts/backlog-status.sh --self-test` still exercises the mode, so it cannot rot silently
while the ticket waits.

`check.sh`, `templates/check/common.sh`, and `install.sh` no longer name `loop-tui` among the
scripts they run or install. A project that already has a copy keeps the file — the installer
never deletes — but the kit stops running its self-test, and `loop-kit-sync.sh` stops carrying it.

LS-01 and LS-02 are marked withdrawn where they stand rather than deleted, so `--stories` still
has a file to read and shows them as withdrawn with the record that withdrew them. Withdrawing the
TUI tickets (LK-30, LK-31) the same way — a `blocked` claim that says who withdrew them and why —
keeps their ids from being reused and keeps `--next` off them, which is what the loop already does
for a ticket the owner has set aside.

## What would show this was wrong

A second reader appearing that renders the loop's state from `scripts/backlog-status.sh` and needs
the uncut fields `--plain` exists for — that would say the withdrawal was a preference rather than
a consequence. Or work starting from a screen rather than from a prompt, which would say the
interface this record kept was the wrong one.
