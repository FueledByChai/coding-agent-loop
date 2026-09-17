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
for script in loop-config backlog-status open-ticket-pr release-notes loop-kit-sync proof-gate coverage-ratchet review-status decisions prompt-check sprint check-list ruleset-check pr-readiness; do
  "scripts/$script.sh" --self-test
done
# The prompts carry their rules: a phrase that states a rule may not be edited away.
scripts/prompt-check.sh
# The kit's records answer to the same sections and index a project's check demands of them.
scripts/decisions.sh --check
# <<< loop checks
# The block above and a project's are one list; this fails when they have drifted apart (LK-14).
scripts/check-list.sh check.sh templates/check/common.sh
# The section that describes this script is prose, so it is compared by name: every check this
# script runs as work of its own has to be named there, and nothing else may be - the shape a merge
# of two rewrites of that section broke (LK-16). It sits outside the shared block because a
# project's AGENTS.md is its own file (decision 0008).
scripts/check-list.sh --section AGENTS.md "The check" check.sh
# A ruleset that requires a status its paired workflow never reports holds every pull request
# forever, and the pairs here differ by two contexts: this repository's workflow reports
# `Check (check.sh)` and its ruleset also requires `Agent review`, which no workflow reports - the
# loop posts it as a commit status - while the template a project installs reports
# `Check (scripts/check.sh)` alone (decision 0006).
scripts/ruleset-check.sh .github/ruleset.json .github/workflows/ci.yml ci/ruleset.json ci/workflow.yml
./install.sh --self-test
# The `sprint` list here is every open ticket (LK-15), so an open heading it omits is a fault:
# --next would work that ticket in file order once the sprint drains, which is not the order the
# list states. It is deliberately one-sided - a project whose sprint is a chosen subset does not
# name it - so it sits outside the shared block, with the install self-test.
scripts/backlog-status.sh --sprint-check
echo "KIT CHECKS PASSED"
