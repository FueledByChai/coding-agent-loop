#!/usr/bin/env bash
# The kit's own definition of done: every script's self-test, then the install into a fresh
# repository with a stub check, which runs the installed self-tests there. CI runs this same
# script. It sits at the kit's root, not under scripts/, so install.sh never copies it over a
# project's own check.
set -euo pipefail
cd "$(dirname "$0")"
for script in loop-config backlog-status open-ticket-pr release-notes loop-kit-sync proof-gate coverage-ratchet review-status decisions prompt-check sprint loop-tui ruleset-check; do
  "scripts/$script.sh" --self-test
done
# The prompts carry their rules: a phrase that states a rule may not be edited away.
scripts/prompt-check.sh
# The kit's records answer to the same sections and index a project's check demands of them.
scripts/decisions.sh --check
# A ruleset that requires a status its paired workflow never reports holds every pull request
# forever, and both pairs here are one context apart from each other: this repository's workflow
# reports `Check (check.sh)`, the template a project installs reports `Check (scripts/check.sh)`.
scripts/ruleset-check.sh .github/ruleset.json .github/workflows/ci.yml ci/ruleset.json ci/workflow.yml
./install.sh --self-test
# The `sprint` list here is every open ticket (LK-15), so an open heading it omits is a fault:
# --next would work that ticket in file order once the sprint drains, which is not the order the
# list states. It is deliberately one-sided - a project whose sprint is a chosen subset does not
# name it - so it sits outside the shared block, with the install self-test.
scripts/backlog-status.sh --sprint-check
echo "KIT CHECKS PASSED"
