#!/usr/bin/env bash
# The sprint is a Beads label and priority (0012): the tickets carrying `sprint_label` are the
# sprint, worked by priority then id, and there is no list in .loop.toml to keep in step. Every
# command writes to bd; committing anything is the owner's, as with any bd change.
#
#   scripts/sprint.sh                          the sprint's tickets with their states
#                                              (scripts/backlog-status.sh --sprint)
#   scripts/sprint.sh add <id> [--priority N]  label a ticket as sprint (P0-P4/0-4; a ticket that
#                                              is already done is refused)
#   scripts/sprint.sh remove <id>              take the label off
#   scripts/sprint.sh set <id> [<id> ...]      replace the whole sprint with these tickets
#   scripts/sprint.sh clear                    unlabel every ticket
#   scripts/sprint.sh --self-test              a fixture repository with a real bd proves each
#
# Settings come from .loop.toml through scripts/loop-config.sh (`sprint_label`, `default_branch`).
# LOOP_ROOT points at another checkout (the self-test's fixture). Needs `bd` with its database.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
CONFIG="$SCRIPT_ROOT/scripts/loop-config.sh"
FILE="${LOOP_CONFIG:-$ROOT/.loop.toml}"
PROJECT="$(cd "$(dirname "$FILE")" && pwd)"

label() { LOOP_CONFIG="$FILE" "$CONFIG" sprint_label; }

bd_run() { ( cd "$PROJECT" && bd "$@" ); }

# The ids carrying the label, in priority then id order, one per line.
labelled_ids() {
  local l; l="$(label)"
  bd_run list --json -n 0 --label "$l" 2>/dev/null | python3 -c '
import json, sys
rows = json.load(sys.stdin)
rows.sort(key=lambda r: (r.get("priority", 9), r["id"]))
print("\n".join(r["id"] for r in rows))
'
}

print_sprint() {
  local ids
  ids="$(labelled_ids | tr '\n' ' ' | sed 's/ *$//')"
  if [ -z "$ids" ]; then echo "sprint: empty"; else echo "sprint: $ids"; fi
}

# A ticket id must exist in the Beads queue and not be done (git is the proof).
check_id() {
  local id="$1" state
  [[ "$id" =~ ^[A-Z]+-[0-9]+$ ]] || { echo "not a ticket id: $id" >&2; return 1; }
  bd_run show "$id" --json >/dev/null 2>&1 \
    || { echo "$id is not in the Beads queue" >&2; return 1; }
  state="$(LOOP_ROOT="$PROJECT" LOOP_CONFIG="$FILE" "$SCRIPT_ROOT/scripts/backlog-status.sh" --local 2>/dev/null | awk -v id="$id" '$1 == id { print $2 }')"
  [ "$state" != "done" ] || { echo "$id is already done" >&2; return 1; }
  return 0
}

cmd="${1:-}"
case "$cmd" in
  "")
    exec "$SCRIPT_ROOT/scripts/backlog-status.sh" --sprint ;;
  add)
    id="${2:-}"; [ -n "$id" ] || { echo "usage: scripts/sprint.sh add <id> [--priority N]" >&2; exit 2; }
    priority=""
    if [ "${3:-}" = "--priority" ]; then priority="${4:-}"; [ -n "$priority" ] || { echo "--priority needs a value" >&2; exit 2; }; fi
    check_id "$id"
    bd_run update "$id" --add-label "$(label)" >/dev/null
    [ -z "$priority" ] || bd_run update "$id" --priority "$priority" >/dev/null
    print_sprint ;;
  remove)
    id="${2:-}"; [ -n "$id" ] || { echo "usage: scripts/sprint.sh remove <id>" >&2; exit 2; }
    bd_run update "$id" --remove-label "$(label)" >/dev/null
    print_sprint ;;
  set)
    shift; [ $# -gt 0 ] || { echo "usage: scripts/sprint.sh set <id> [<id> ...]" >&2; exit 2; }
    for id in "$@"; do check_id "$id"; done
    for id in $(labelled_ids); do bd_run update "$id" --remove-label "$(label)" >/dev/null; done
    for id in "$@"; do bd_run update "$id" --add-label "$(label)" >/dev/null; done
    print_sprint ;;
  clear)
    for id in $(labelled_ids); do bd_run update "$id" --remove-label "$(label)" >/dev/null; done
    print_sprint ;;
  --self-test)
    dir="$(mktemp -d "${TMPDIR:-/tmp}/sprint.XXXXXX")"; trap 'rm -rf "$dir"' EXIT
    me="$SCRIPT_ROOT/scripts/sprint.sh"
    (
      cd "$dir"
      git init -q
      git config user.email t@example.com
      git config user.name t
      printf 'scaffold\n' > README.md
      git add -A
      git commit -q -m "Scaffold"
      git branch -q -M main
      bd init --prefix AA --non-interactive >/dev/null 2>&1
      bd create "First" --id AA-01 --description "first" --acceptance "proof" --priority 2 --silent >/dev/null
      bd create "Second" --id AA-02 --description "second" --acceptance "proof" --priority 2 --silent >/dev/null
      bd create "Third" --id AA-03 --description "third" --acceptance "proof" --priority 2 --silent >/dev/null
      git commit -q --allow-empty -m "AA-03: third landed"
    )
    printf '[loop]\ndefault_branch = "main"\n' > "$dir/.loop.toml"
    export LOOP_ROOT="$dir"
    out="$("$me" add AA-01)"; [ "$out" = "sprint: AA-01" ] || { echo "self-test: add should label the ticket: $out"; exit 1; }
    # A pipeline ending in `grep -q` can fail under `set -o pipefail` when grep closes early,
    # so the whole document is read into a variable and matched as a shell pattern.
    a01_json="$(bd -C "$dir" show AA-01 --json)"
    case "$a01_json" in *'"sprint"'*) ;; *) echo "self-test: AA-01 should carry the sprint label"; exit 1 ;; esac
    out="$("$me" add AA-02 --priority 1)"; [ "$out" = "sprint: AA-02 AA-01" ] || { echo "self-test: --priority should order the sprint: $out"; exit 1; }
    if "$me" add AA-03 >/dev/null 2>&1; then echo "self-test: a done ticket must be refused"; exit 1; fi
    if "$me" add AA-09 >/dev/null 2>&1; then echo "self-test: an id not in the queue must be refused"; exit 1; fi
    out="$("$me" remove AA-01)"; [ "$out" = "sprint: AA-02" ] || { echo "self-test: remove should unlabel: $out"; exit 1; }
    out="$("$me" set AA-01 AA-02)"; [ "$out" = "sprint: AA-02 AA-01" ] || { echo "self-test: set should replace the sprint: $out"; exit 1; }
    out="$("$me" clear)"; [ "$out" = "sprint: empty" ] || { echo "self-test: clear should empty the sprint: $out"; exit 1; }
    remaining="$(bd -C "$dir" list --json -n 0 --label sprint 2>/dev/null)"
    case "$remaining" in ""|"[]") ;; *) echo "self-test: no ticket should carry the label after clear"; exit 1 ;; esac
    unset LOOP_ROOT
    echo "sprint self-test passed" ;;
  *) echo "usage: scripts/sprint.sh [add <id> [--priority N] | remove <id> | set <id>... | clear | --self-test]" >&2; exit 2 ;;
esac
