#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

for file in README.md AGENTS.template.md ci.yml ruleset.json validate.sh; do
  test -f "$ROOT/$file" || { echo "missing recipe file: $file" >&2; exit 1; }
done

python3 -m json.tool "$ROOT/ruleset.json" >/dev/null

workflow_contexts=$(grep -c 'name: Check (scripts/check.sh)' "$ROOT/ci.yml")
ruleset_contexts=$(grep -c '"context": "Check (scripts/check.sh)"' "$ROOT/ruleset.json")
test "$workflow_contexts" -eq 1
test "$ruleset_contexts" -eq 1

if grep -Eiq 'Agent review|ci:run|merge[- ]queue|review worker' \
    "$ROOT/AGENTS.template.md" "$ROOT/ci.yml" "$ROOT/ruleset.json"; then
  echo "single-agent gate templates contain orchestration machinery" >&2
  exit 1
fi

echo "single-agent recipe validated"
