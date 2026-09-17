# 0002 — The terminal UI is bash with tput and stty, and the kit ships only scripts

Status: superseded by 0013
Date: 2026-09-13

## Context

The owner asked for a terminal UI over the loop's own state (LS-01, LS-02): the queue, the
sprint, and the stories on one screen, htop-like, with the sprint editable from it. The kit is
bash, git, and perl and has no other runtime dependency; its `README.md` says so, and
`scripts/loop-config.sh` states that TOML is only the config format and says nothing about a
project's language. Three shapes were available — hand-rolled terminal code in bash, python3
with the standard library's `curses`, or an external picker such as `fzf` — and two facts
decided it.

`scripts/loop-kit-sync.sh` and `install.sh` both glob `scripts/*.sh` when they copy the kit into
a project, and the kit's README promises that the copies are what a project runs. A file in
another language, or a fixtures directory beside the scripts, would silently never reach a
project: no error, no drift report, just a script that is not there. Second, the kit stays
within bash 3.2 — macOS's system bash, 3.2.57 in this checkout — and contains no `declare -A`,
no `mapfile`, and no `${var,,}`.

## Decision

The terminal UI is one bash script, `scripts/loop-tui.sh`, that stays within bash 3.2 and takes
its terminal behaviour from `tput` and `stty`, both present on every machine the loop runs on.
It adds no runtime the loop does not already need, and the kit's shipping surface stays
`scripts/*.sh`.

Rendering is split from the terminal: a frame is a string, printed by `--render` at a width
given by `--width`, so the layout is asserted without a terminal and the interactive mode is a
key handler over the same frames rather than a second implementation. Fixtures a self-test needs
are written into a temporary directory by the test itself, never kept beside the scripts.

## Alternatives

- python3 with the standard library's `curses`: less code, no hand-rolled redraw, and a real
  window and key model. Rejected because `scripts/loop-kit-sync.sh` and `install.sh` glob
  `scripts/*.sh`, so a `.py` file would silently never reach a project, and because it makes
  python3 a requirement of the kit. `install.sh` already probes python3 as an optional YAML
  fallback for its own self-test, which is not the same as depending on it.
- `fzf` as the picker: the least code, and the best fit for choosing an action from a list.
  Rejected because it is a second install on every machine that runs the loop, it is not a
  dashboard, and its absence has to be handled anyway — so it would be a fast path beside the
  real thing rather than the real thing.
- A fixtures directory beside the scripts for the golden frames: cleaner to read in a diff than
  heredocs. Rejected because the sync glob would not carry it, which is the same failure that
  ruled out python3.
- Node or Ink: a toolchain the kit does not otherwise touch, for a script that has to run
  wherever bash does.

## Consequences

`scripts/loop-tui.sh` becomes the kit's longest script, and redraw and resize are the parts that
need the most care — which is why the dashboard (LK-01) ships before the interactive mode
(LK-03) rather than both at once. Every later terminal feature pays the same tax: no windows, no
key tables, no resize event, no colour abstraction. The golden frames live in the script as
heredocs, so a layout change shows up as a diff in a bash file rather than in a fixture file
beside it.

Any future need for a helper in another language, or for a fixture that ships with the kit, is
first a change to `scripts/loop-kit-sync.sh` and `install.sh` and to their self-tests — a change
to how the kit ships, not a detail of any one script.

## What would show this was wrong

The bash terminal code proves unmaintainable in practice: redraw bugs that no self-test catches,
or a resize or signal path that repeatedly leaves a terminal unusable, so the script is
rewritten in a language with `curses` in a superseding record that also changes what the kit
ships. Or a project needs the UI on a machine without `tput` or `stty`, which would mean they
are not as universal as assumed here.
