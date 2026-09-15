# 0011 — The stories view's filters narrow the rows once, in the shell, not in the renderer

Status: accepted
Date: 2026-09-15

## Context

`scripts/loop-tui.sh stories` ended its frame with ` e epic filter   d hide unticketed   r refresh
q quit`, and the key handler LK-03 added read `r` and `q` from that view and neither `e` nor `d`:
the epic filter and the hide-unticketed toggle had been drawn onto the frame by LK-02 as part of the
view and were never implemented, so half the keys the frame offered did nothing (LK-20). LK-03 had
met the same question over `? help` in the other three keybars and answered it by adding a help
screen rather than by removing the key, and a key that does nothing is a lie printed on the frame.

Implementing them raised a second question, which is the one this record settles. The stories view
has two readers of the same `scripts/backlog-status.sh --stories --plain` output: the Perl renderer,
which lays out the rows, and `view_ids()`, which lists the ids the marker moves over. They were
already two parses of one command. A filter has to reach both, or the marker walks rows the frame
does not draw — `j` would appear to do nothing, which is the failure the marker's own comment names.
Adding the predicate to both would have written one rule down twice with nothing comparing them,
which is the LK-14/LK-16/LK-28 shape the kit keeps filing against itself.

## Decision

The filters are applied in the shell, once, to the `--stories --plain` text, and both readers take
the result: `load_stories()` narrows the rows into `STORIES_TEXT`, the renderer draws that, and
`view_ids()` prints the ids out of it. The renderer holds no filter logic, so the frame and the
marker cannot disagree about which stories are on screen.

The keys are implemented rather than removed, following LK-03's answer to the same question.

Two smaller choices follow from it. The epic filter walks the epics the view holds — unfiltered,
then each in the order the rows are drawn, then back — because the alternative is a text prompt for
a name the frame has just shown, and a list taken unfiltered cannot have its choices narrowed out
from under the key that made it. And the summary line is left whole while the table narrows: it
counts the product backlog, and the filter is a setting on the table under it, which the keybar
states (`e epic: any`, `d unticketed: shown`). A narrowed table is never a silent one.

## Alternatives

- **Filter in the renderer, and again in `view_ids()`.** The obvious reading, and the one this
  record exists to reject: two implementations of one predicate, kept in step by nothing.
- **Filter in the renderer only, and let the marker walk the unfiltered list.** The marker would
  move onto hidden rows and the frame would draw no marker at all, so `j` would look broken.
- **Remove `e` and `d` from the keybar.** The ticket allowed it, and it is the smaller diff. It
  leaves a stories view whose epic column — a field the view exists to show, and the one field that
  has to share the width — cannot be filtered, and it breaks the rule LK-03 set for `?`.
- **Make `e` a prompt for an epic's name.** It reuses the `a` machinery, but it asks a reader to
  type a string the frame has just shown them, and it cannot be driven by a single key in
  `--keys`, which is how the whole program is proved.
- **Recompute the summary from the drawn rows.** The summary is derived by
  `scripts/backlog-status.sh` from the product backlog; recomputing it in the TUI would be a second
  derivation of the same figures, and a third place they could disagree.

## Consequences

`view_ids()` for the stories view now runs `load_stories()` rather than the command directly, so a
keypress in that view calls `--stories` twice — once for the marker and once for the frame. It did
before this change too; the count is unchanged.

The stories view is now the only one with state that is not about a keypress: `EPIC` and
`HIDE_UNTICKETED` live beside `SEL` and `MSG` and are cleared by nothing but the keys. A view
switched away from and back returns to the unfiltered table, which is deliberate — the settings
belong to the view, and `switch_view` already resets the marker.

The keybar is now wider than the frame at 40 columns and is cut there, as every other keybar
already was. The epic segment gives way first, so `r` and `q` stay on the bar at every width.

## What would show this was wrong

A third reader of the stories rows appearing — a check, an export, a second view — that does not go
through `load_stories()`, so that "which stories are on screen" is answered in two places again. Or
a filter whose state has to be carried between views, which would show that putting it on the view
rather than on the rows was the wrong half of the choice.
