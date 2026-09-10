#!/usr/bin/env bash
# The kit's own definition of done: every script's self-test, then the install into a fresh
# repository with a stub check, which runs the installed self-tests there. CI runs this same
# script. It sits at the kit's root, not under scripts/, so install.sh never copies it over a
# project's own check.
set -euo pipefail
cd "$(dirname "$0")"
for script in loop-config backlog-status open-ticket-pr release-notes loop-kit-sync; do
  "scripts/$script.sh" --self-test
done
./install.sh --self-test
echo "KIT CHECKS PASSED"
