#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SELF_TEST_DIR=""

validate_recipe() {
  local root="$1" workflow_contexts pull_request_events gate
  for file in README.md AGENTS.template.md ci.yml ruleset.json validate.sh; do
    test -f "$root/$file" || { echo "missing recipe file: $file" >&2; return 1; }
  done

  python3 - "$root/ruleset.json" <<'PY' || return 1
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    ruleset = json.load(source)
required = []
for rule in ruleset.get("rules", []):
    if rule.get("type") == "required_status_checks":
        required.extend(rule.get("parameters", {}).get("required_status_checks", []))
expected = [{"context": "Check (scripts/check.sh)", "integration_id": 15368}]
if required != expected:
    raise SystemExit(f"ruleset required checks should be exactly {expected}, got {required}")
PY

  workflow_contexts=$(grep -Ec '^    name: Check \(scripts/check\.sh\)$' "$root/ci.yml" || true)
  test "$workflow_contexts" -eq 1 \
    || { echo "workflow must report exactly Check (scripts/check.sh)" >&2; return 1; }
  pull_request_events=$(grep -Ec '^  pull_request:$' "$root/ci.yml" || true)
  test "$pull_request_events" -eq 1 \
    || { echo "workflow must use exactly one pull_request event" >&2; return 1; }
  grep -Eq '^  pull_request_target:' "$root/ci.yml" \
    && { echo "workflow must not use pull_request_target" >&2; return 1; }
  grep -Fqx '    types: [labeled]' "$root/ci.yml" \
    || { echo "workflow must run only for pull-request label additions" >&2; return 1; }
  grep -Fqx '  group: ci-${{ github.event.pull_request.number }}-${{ github.event.label.name }}' "$root/ci.yml" \
    || { echo "workflow concurrency must isolate unrelated labels from ci:run" >&2; return 1; }

  gate=$(sed -n '/# >>> single-agent admission/,/# <<< single-agent admission/p' "$root/ci.yml" \
    | sed '1d;$d;s/^          //')
  test -n "$gate" || { echo "workflow has no executable admission fixture" >&2; return 1; }
  REQUESTED_LABEL=ci:run PR_DRAFT=false bash -c "$gate" >/dev/null \
    || { echo "ci:run on a ready pull request failed single-agent CI admission" >&2; return 1; }
  if REQUESTED_LABEL=other PR_DRAFT=false bash -c "$gate" >/dev/null 2>&1; then
    echo "unrelated label passed single-agent CI admission" >&2; return 1
  fi
  if REQUESTED_LABEL=ci:run PR_DRAFT=true bash -c "$gate" >/dev/null 2>&1; then
    echo "draft pull request passed single-agent CI admission" >&2; return 1
  fi

  # README explains the excluded machinery; only executable/configuration templates must omit it.
  if grep -Eiq 'Agent review|merge[- ]queue|review worker|acceptance journal' \
      "$root/AGENTS.template.md" "$root/ci.yml" "$root/ruleset.json"; then
    echo "single-agent gate templates contain full-loop orchestration machinery" >&2
    return 1
  fi
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/single-agent-recipe.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  cp "$ROOT"/{README.md,AGENTS.template.md,ci.yml,ruleset.json,validate.sh} "$SELF_TEST_DIR/"
  validate_recipe "$SELF_TEST_DIR" >/dev/null

  perl -0pi -e 's/name: Check \(scripts\/check\.sh\)/name: Check (scripts\/check.sh) v2/' "$SELF_TEST_DIR/ci.yml"
  if validate_recipe "$SELF_TEST_DIR" >/dev/null 2>&1; then
    echo "self-test: workflow/ruleset context drift passed" >&2; return 1
  fi
  cp "$ROOT/ci.yml" "$SELF_TEST_DIR/ci.yml"
  perl -0pi -e 's/15368/1/g' "$SELF_TEST_DIR/ruleset.json"
  grep -Fq '"integration_id": 1' "$SELF_TEST_DIR/ruleset.json" \
    || { echo "self-test: failed to mutate required-check integration" >&2; return 1; }
  if validate_recipe "$SELF_TEST_DIR" >/dev/null 2>&1; then
    echo "self-test: wrong required-check integration passed" >&2; return 1
  fi
  cp "$ROOT/ruleset.json" "$SELF_TEST_DIR/ruleset.json"
  perl -0pi -e 's/-\$\{\{ github\.event\.label\.name \}\}//' "$SELF_TEST_DIR/ci.yml"
  if validate_recipe "$SELF_TEST_DIR" >/dev/null 2>&1; then
    echo "self-test: shared unrelated-label concurrency passed" >&2; return 1
  fi
  echo "single-agent recipe self-test passed"
}

case "${1:-}" in
  "") validate_recipe "$ROOT"; echo "single-agent recipe validated" ;;
  --self-test) self_test ;;
  *) echo "usage: recipes/single-agent/validate.sh [--self-test]" >&2; exit 2 ;;
esac
