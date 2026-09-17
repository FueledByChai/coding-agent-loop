#!/usr/bin/env bash
# The Compose proof: start the project's stack under a name of this run's own, wait for it to
# be healthy, run the project's proof against it, and take that stack down - never the stack a
# developer already has running, and never with a prune.
#
#   scripts/compose-smoke.sh              start, prove, tear down
#   scripts/compose-smoke.sh --self-test  a stub docker proves the lifecycle
#
# Settings come from .loop.toml through scripts/loop-config.sh:
#   compose_files  ["compose.yaml"]  the files the stack is made of, in order
#   compose_env    ""                a command run from the root whose output is KEY=VALUE
#                                    lines, exported before the stack starts: the ports and
#                                    secrets a compose file reads from its environment
#   compose_proof  ""                a command run from the root once the stack is healthy;
#                                    empty proves only that it came up
#
# The proof and the environment command both run with COMPOSE_PROJECT_NAME and COMPOSE_FILE
# exported for this run's project, so a proof can drive the same stack - `docker compose exec`
# against its database, a `down` and `up` for a restart proof, `logs` - without recomputing
# any of it. The stack is started with `--wait`, so it is healthy before the proof sees it, and
# a failing run prints its logs and then removes its own containers and volumes.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
CONFIG="$SCRIPT_ROOT/scripts/loop-config.sh"
WAIT_SECONDS=240
MODE=run
case "${1:-}" in
  "") ;;
  --self-test) MODE=selftest ;;
  *) echo "usage: scripts/compose-smoke.sh | --self-test" >&2; exit 2 ;;
esac

# Script-level, not locals of run(): the EXIT trap fires after run has returned, and `set -u`
# would turn a cleaned-up local into an error in the trap instead of a stack that goes away.
PROJECT=""
compose=()

teardown() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "${#compose[@]}" -gt 0 ]; then
    # A stack that failed to come up is judged by its logs, not by a message that it did not.
    "${compose[@]}" logs --no-color --tail=100 || true
  fi
  if [ "${#compose[@]}" -gt 0 ]; then
    "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  exit "$rc"
}

# The variables a compose file reads from its environment, one export per KEY=VALUE line. A line
# that is not one is refused rather than exported as something else: `source`ing arbitrary
# output would run it, and eval'ing it would too.
export_env_command() {
  local cmd="$1" line failed=0
  [ -n "$cmd" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      [A-Za-z_]*=*)
        case "${line%%=*}" in
          *[!A-Za-z0-9_]*) echo "compose-smoke: not a variable name: ${line%%=*}" >&2; failed=1 ;;
          *) export "$line" ;;
        esac
        ;;
      *) echo "compose-smoke: compose_env should print KEY=VALUE lines, not: $line" >&2; failed=1 ;;
    esac
  done < <(cd "$ROOT" && bash -c "$cmd")
  [ "$failed" = 0 ]
}

run() {
  local f cmd joined
  command -v docker >/dev/null 2>&1 || { echo "the Compose proof needs Docker (brew install --cask docker)" >&2; exit 1; }
  docker info >/dev/null 2>&1 || { echo "Docker is installed but its daemon is not running" >&2; exit 1; }

  PROJECT="loop-smoke-$(date +%s)-$$"
  compose=(docker compose --project-name "$PROJECT")
  joined=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    compose+=(--file "$ROOT/$f")
    if [ -n "$joined" ]; then joined="$joined:$ROOT/$f"; else joined="$ROOT/$f"; fi
  done < <("$CONFIG" compose_files)
  # `docker compose --project-name <project>` and nothing else: no file was configured.
  if [ "${#compose[@]}" -le 4 ]; then
    echo "compose-smoke: no compose_files configured in .loop.toml" >&2; exit 2
  fi
  export COMPOSE_PROJECT_NAME="$PROJECT" COMPOSE_FILE="$joined"

  trap teardown EXIT
  export_env_command "$("$CONFIG" compose_env)" || exit 1

  "${compose[@]}" up --build --detach --wait --wait-timeout "$WAIT_SECONDS"

  cmd="$("$CONFIG" compose_proof)"
  if [ -n "$cmd" ]; then (cd "$ROOT" && bash -c "$cmd"); fi
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-smoke.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR" me="$SCRIPT_ROOT/scripts/compose-smoke.sh" out rc failed=0
  mkdir -p "$dir/bin" "$dir/work/scripts" "$dir/state"

  # A stub docker that records the compose invocations and answers them the way a daemon would.
  cat > "$dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info)
    [ -n "${STUB_NOT_RUNNING:-}" ] && exit 1
    exit 0
    ;;
  compose)
    printf '%s\n' "$*" >> "$STUB_STATE/compose"
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --project-name|--file) shift 2; continue ;;
      esac
      break
    done
    case "${1:-}" in
      up) [ -n "${STUB_UP_FAILS:-}" ] && exit 1; exit 0 ;;
      logs|down) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$dir/bin/docker"
  # The project's two commands: one prints the variables its compose file reads, the other
  # records what it was handed. Both are commands in .loop.toml, not scripts the kit ships.
  cat > "$dir/work/scripts/env.sh" <<'EOF'
#!/usr/bin/env bash
printf 'DB_PASSWORD=from-the-env-command\n'
printf 'HTTP_PORT=9280\n'
EOF
  cat > "$dir/work/scripts/proof.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${COMPOSE_PROJECT_NAME:-}" > "$PROOF_STATE/project"
printf '%s\n' "${COMPOSE_FILE:-}" > "$PROOF_STATE/files"
printf '%s\n' "${DB_PASSWORD:-none}" > "$PROOF_STATE/password"
exit "${PROOF_EXIT:-0}"
EOF
  chmod +x "$dir/work/scripts/env.sh" "$dir/work/scripts/proof.sh"
  write_config() {
    local proof="${1-scripts/proof.sh}"
    rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE"
    unset STUB_UP_FAILS STUB_NOT_RUNNING PROOF_EXIT
    {
      printf '[loop]\n'
      printf 'compose_files = ["compose.yaml", "compose.ci.yaml"]\n'
      printf 'compose_env = "scripts/env.sh"\n'
      printf 'compose_proof = "%s"\n' "$proof"
    } > "$dir/work/.loop.toml"
  }
  export PATH="$dir/bin:$PATH" STUB_STATE="$dir/state" PROOF_STATE="$dir/state" LOOP_ROOT="$dir/work"
  record() { cat "$STUB_STATE/compose" 2>/dev/null || true; }

  # A passing proof: the stack is started once with --wait, the proof sees this run's project
  # name and both compose files, the environment command's values reached it, and the stack
  # goes away again - with no logs, because nothing failed.
  write_config
  out="$("$me")" || { echo "self-test: the smoke proof should pass:"; echo "$out"; exit 1; }
  grep -q -- '--project-name loop-smoke-' "$STUB_STATE/compose" || { echo "self-test: the stack should carry this run's project name"; failed=1; }
  grep -q -- '--file .*compose.yaml --file .*compose.ci.yaml up --build --detach --wait --wait-timeout 240' "$STUB_STATE/compose" \
    || { echo "self-test: the stack should be started from both files with --wait:"; record; failed=1; }
  grep -q -- 'down --volumes --remove-orphans' "$STUB_STATE/compose" || { echo "self-test: the stack should be taken down with its volumes"; failed=1; }
  grep -q -- ' logs ' "$STUB_STATE/compose" && { echo "self-test: a passing run should not print logs"; failed=1; }
  grep -q '^loop-smoke-' "$PROOF_STATE/project" || { echo "self-test: the proof should see COMPOSE_PROJECT_NAME, got '$(cat "$PROOF_STATE/project")'"; failed=1; }
  grep -q 'compose.yaml:.*compose.ci.yaml' "$PROOF_STATE/files" || { echo "self-test: the proof should see both files in COMPOSE_FILE, got '$(cat "$PROOF_STATE/files")'"; failed=1; }
  [ "$(cat "$PROOF_STATE/password")" = "from-the-env-command" ] || { echo "self-test: the env command's value should reach the proof, got '$(cat "$PROOF_STATE/password")'"; failed=1; }

  # A failing proof: its exit code reaches the caller, the logs are printed, and the stack goes.
  write_config
  export PROOF_EXIT=7
  rc=0; "$me" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 7 ] || { echo "self-test: the proof's exit code should pass through (got $rc)"; failed=1; }
  grep -q -- ' logs ' "$STUB_STATE/compose" || { echo "self-test: a failing run should print the stack's logs"; failed=1; }
  grep -q -- 'down --volumes --remove-orphans' "$STUB_STATE/compose" || { echo "self-test: a failing run should still take the stack down"; failed=1; }
  unset PROOF_EXIT

  # A stack that never comes up: non-zero, logs, and down.
  write_config
  export STUB_UP_FAILS=1
  if "$me" >/dev/null 2>&1; then echo "self-test: a stack that does not come up must fail"; failed=1; fi
  grep -q -- ' logs ' "$STUB_STATE/compose" || { echo "self-test: a failed start should print the stack's logs"; failed=1; }
  grep -q -- 'down --volumes --remove-orphans' "$STUB_STATE/compose" || { echo "self-test: a failed start should still take the stack down"; failed=1; }
  unset STUB_UP_FAILS

  # No proof command: coming up is the proof, and nothing else runs.
  write_config ""
  out="$("$me")" || { echo "self-test: a stack with no proof command should still pass:"; echo "$out"; exit 1; }
  [ ! -s "$PROOF_STATE/project" ] || { echo "self-test: no proof command should have run"; failed=1; }

  # An environment command that prints something other than KEY=VALUE is refused, and the stack
  # is never started.
  write_config
  printf '#!/usr/bin/env bash\necho "this is not an assignment"\n' > "$dir/work/scripts/env.sh"
  rc=0; "$me" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "self-test: a bad compose_env line should be refused (rc $rc)"; failed=1; }
  grep -q -- ' up ' "$STUB_STATE/compose" && { echo "self-test: a refused env command should not start the stack"; failed=1; }
  out="$("$me" 2>&1 || true)"
  printf '%s\n' "$out" | grep -q 'should print KEY=VALUE lines' || { echo "self-test: the refusal should say what is wrong:"; echo "$out"; failed=1; }
  printf '#!/usr/bin/env bash\nprintf "DB_PASSWORD=from-the-env-command\\n"\nprintf "HTTP_PORT=9280\\n"\n' > "$dir/work/scripts/env.sh"
  chmod +x "$dir/work/scripts/env.sh"

  # The refusals: no docker, a daemon that is not running, and a stack with no files named.
  mkdir -p "$dir/nodocker"
  for tool in bash dirname mktemp cat grep rm; do ln -sf "$(command -v "$tool")" "$dir/nodocker/$tool" 2>/dev/null || true; done
  write_config
  if PATH="$dir/nodocker" "$me" >/dev/null 2>&1; then echo "self-test: a machine with no docker must be refused"; failed=1; fi
  write_config
  export STUB_NOT_RUNNING=1
  rc=0; "$me" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "self-test: a daemon that is not running should be refused (rc $rc)"; failed=1; }
  unset STUB_NOT_RUNNING
  printf '[loop]\ncompose_files = []\n' > "$dir/work/.loop.toml"
  rc=0; "$me" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "self-test: no compose_files should be a usage error (rc $rc)"; failed=1; }
  rc=0; "$me" --bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "self-test: an unknown flag should be a usage error (rc $rc)"; failed=1; }

  [ "$failed" = 0 ] || exit 1
  # Not PATH: the trap that removes the fixture runs after this and needs `rm` to find it.
  unset LOOP_ROOT STUB_STATE PROOF_STATE
  echo "compose-smoke self-test passed"
}

case "$MODE" in
  selftest) self_test ;;
  run) run ;;
esac
