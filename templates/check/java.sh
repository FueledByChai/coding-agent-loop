#!/usr/bin/env bash
# The definition of done for a Java project, Maven or Gradle, as a command: exits non-zero on
# the first failure. Written by grill-project from the kit's skeleton; every stack step is
# skipped with a note until pom.xml or a Gradle build file exists, so this passes on an empty
# repository and starts failing as code arrives. Fill the TODO lines as the project decides
# them.
#
#   scripts/check.sh            everything
#   scripts/check.sh --fast     skip the coverage ratchet (the check to run while iterating)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAST=0
for arg in "$@"; do case "$arg" in --fast) FAST=1 ;; *) echo "unknown flag: $arg" >&2; exit 2 ;; esac; done
step() { printf '\n== %s\n' "$1"; }
started=$(date +%s)
. loop/templates/check/common.sh
loop_checks

if [ -f pom.xml ]; then
  step "format"
  mvn -q -B spotless:check   # TODO: or drop it until the project adopts a formatter
  step "tests and build"
  mvn -q -B verify
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  step "format, lint, tests, and build"
  ./gradlew -q check          # TODO: add spotlessCheck to `check` once the project adopts a formatter
else
  step "stack"; echo "skipped: no pom.xml or build.gradle yet"
fi

if [ "$FAST" = 0 ]; then
  # `coverage` in .loop.toml should print one percentage. With JaCoCo (line coverage from its
  # CSV, after `mvn -q -B verify` or `./gradlew jacocoTestReport`) the kit ships the figure:
  #   coverage = "python3 scripts/coverage-percent.py"
  # reads target/site/jacoco/jacoco.csv, and takes another CSV path as its argument; use your
  # own command for anything else.
  ratchet
fi

printf '\nALL CHECKS PASSED (%ss)\n' "$(( $(date +%s) - started ))"
