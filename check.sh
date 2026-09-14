#!/usr/bin/env bash
# The kit's own definition of done: every script's self-test, then the install into a fresh
# repository with a stub check, which runs the installed self-tests there. CI runs this same
# script. It sits at the kit's root, not under scripts/, so install.sh never copies it over a
# project's own check.
set -euo pipefail
cd "$(dirname "$0")"
# The checks between the markers are the same ones a project runs from
# loop/templates/check/common.sh, and scripts/check-list.sh compares the two blocks: a check added
# here or there alone fails naming it. What sits outside the markers is deliberately one-sided -
# ./install.sh --self-test proves the install, which only the kit has.
# >>> loop checks: shared with templates/check/common.sh (scripts/check-list.sh compares this block)
for script in loop-config backlog-status open-ticket-pr release-notes loop-kit-sync proof-gate coverage-ratchet review-status decisions prompt-check sprint loop-tui check-list; do
  "scripts/$script.sh" --self-test
done
# The prompts carry their rules: a phrase that states a rule may not be edited away.
scripts/prompt-check.sh
# The kit's records answer to the same sections and index a project's check demands of them.
scripts/decisions.sh --check
# <<< loop checks
# The block above and a project's are one list; this fails when they have drifted apart (LK-14).
scripts/check-list.sh check.sh templates/check/common.sh
./install.sh --self-test
echo "KIT CHECKS PASSED"
