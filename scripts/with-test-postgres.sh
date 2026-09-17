#!/usr/bin/env bash
# A disposable synthetic PostgreSQL for a command that needs one - an integration test suite, a
# migration rehearsal - and nothing else: start a container, wait for it to accept connections,
# run the command with the connection URL in its environment, and take the container down
# again. Only the container this run created is touched, and nothing is ever pruned.
#
#   scripts/with-test-postgres.sh <command> [args...]   run <command> against a fresh database
#   scripts/with-test-postgres.sh --self-test           a stub docker proves the lifecycle
#
# Settings come from .loop.toml through scripts/loop-config.sh:
#   test_db_image  "postgres:17-bookworm"   the server image
#   test_db_name   "test"                   the database created inside it
#   test_db_user   "test"                   the role the URL names
#   test_db_env    "TEST_DATABASE_URL"      the variable the command reads; "" exports none
#   test_db_url    "postgres://{user}:{password}@{host}:{port}/{name}"
#                                           {host} {port} {name} {user} and {password} are
#                                           filled in; the password is fixed because the
#                                           database is disposable and bound to loopback, and a
#                                           JDBC project writes the jdbc: form here instead
#
# The container carries two labels, loop.synthetic-test=true and
# loop.test-invocation=<container>. The cleanup removes a container only when the second one
# names this run, so a collision with somebody else's container is left alone rather than
# deleted - and a run interrupted between Docker creating the container and `docker run`
# returning is still cleaned up, because the label is on the container, not in this shell.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
CONFIG="$SCRIPT_ROOT/scripts/loop-config.sh"
# Fixed on purpose: the database exists for the length of one command, on loopback, and is
# deleted at the end of it. Nothing here is a credential for anything that outlives the run.
DB_PASSWORD=synthetic-test-only
POLL_ATTEMPTS=60
# The container this run creates. A script-level variable, not a `local` of run(): the EXIT
# trap that removes it fires after run has returned, when a local would already be out of
# scope and `set -u` would turn the cleanup into an error.
CONTAINER=""

MODE=run
case "${1:-}" in
  --self-test) MODE=selftest ;;
  ""|-*) echo "usage: scripts/with-test-postgres.sh <command> [args...] | --self-test" >&2; exit 2 ;;
esac

run() {
  command -v docker >/dev/null 2>&1 || { echo "a disposable PostgreSQL needs Docker (brew install --cask docker)" >&2; exit 1; }
  docker info >/dev/null 2>&1 || { echo "Docker is installed but its daemon is not running" >&2; exit 1; }

  local image name user env_name template
  image="$("$CONFIG" test_db_image)"
  name="$("$CONFIG" test_db_name)"
  user="$("$CONFIG" test_db_user)"
  env_name="$("$CONFIG" test_db_env)"
  template="$("$CONFIG" test_db_url)"

  CONTAINER="loop-test-postgres-$(date +%s)-$$-$RANDOM"
  cleanup() {
    local owner
    owner="$(docker inspect --format '{{index .Config.Labels "loop.test-invocation"}}' "$CONTAINER" 2>/dev/null)" || return 0
    if [ "$owner" = "$CONTAINER" ]; then docker rm -fv "$CONTAINER" >/dev/null 2>&1 || true; fi
    return 0
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  docker run -d --name "$CONTAINER" \
    --label loop.synthetic-test=true --label "loop.test-invocation=$CONTAINER" \
    -e "POSTGRES_DB=$name" -e "POSTGRES_USER=$user" -e "POSTGRES_PASSWORD=$DB_PASSWORD" \
    -p 127.0.0.1::5432 "$image" >/dev/null

  local ready=false attempt
  for attempt in $(seq 1 "$POLL_ATTEMPTS"); do
    if docker exec "$CONTAINER" pg_isready -U "$user" -d "$name" >/dev/null 2>&1; then ready=true; break; fi
    sleep 1
  done
  [ "$ready" = true ] || { echo "the synthetic PostgreSQL ($CONTAINER) never accepted connections" >&2; exit 1; }

  local port url
  port="$(docker port "$CONTAINER" 5432/tcp | awk -F: '{print $NF}')"
  url="$template"
  url="${url//\{host\}/127.0.0.1}"
  url="${url//\{port\}/$port}"
  url="${url//\{name\}/$name}"
  url="${url//\{user\}/$user}"
  url="${url//\{password\}/$DB_PASSWORD}"
  if [ -n "$env_name" ]; then export "$env_name=$url"; fi

  "$@"
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/with-test-postgres.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR" me="$SCRIPT_ROOT/scripts/with-test-postgres.sh" out rc failed=0
  mkdir -p "$dir/bin" "$dir/work" "$dir/state"
  printf '[loop]\ntest_db_image = "postgres:16-alpine"\ntest_db_name = "appdb"\ntest_db_user = "app"\ntest_db_env = "TEST_DATABASE_URL"\ntest_db_url = "jdbc:postgresql://{host}:{port}/{name}"\n' > "$dir/work/.loop.toml"

  # A stub docker that keeps the state a real daemon would: which container exists, what its
  # ownership label says, and which containers were removed. The lifecycle is what is under
  # test, so the daemon is simulated rather than required - the kit's own check runs on
  # machines with no Docker at all, and a proof that needs one would be a proof that skips.
  cat > "$dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="$STUB_STATE"
case "${1:-}" in
  info)
    [ -n "${STUB_NOT_RUNNING:-}" ] && exit 1
    exit 0
    ;;
  run)
    printf '%s\n' "$@" > "$state/run-args"
    shift
    name=""; label=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift 2; continue ;;
        --label) case "$2" in loop.test-invocation=*) label="${2#loop.test-invocation=}" ;; esac; shift 2; continue ;;
      esac
      shift
    done
    printf '%s\n' "$name" > "$state/name"
    if [ -n "${STUB_FOREIGN:-}" ]; then printf 'somebody-elses-container\n' > "$state/label"
    else printf '%s\n' "$label" > "$state/label"; fi
    echo cid1234
    ;;
  exec)
    shift
    [ -f "$state/name" ] && [ "${1:-}" = "$(cat "$state/name")" ] || exit 1
    printf '%s\n' "$*" >> "$state/exec"
    exit 0
    ;;
  port) echo "127.0.0.1:54321" ;;
  inspect)
    [ -f "$state/label" ] || exit 1
    cat "$state/label"
    ;;
  rm)
    printf '%s\n' "${3:-}" >> "$state/removed"
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$dir/bin/docker"
  export PATH="$dir/bin:$PATH" STUB_STATE="$dir/state" LOOP_ROOT="$dir/work"

  reset() { rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE"; unset STUB_FOREIGN STUB_NOT_RUNNING; }
  label() { cat "$STUB_STATE/$1" 2>/dev/null || true; }
  # assert_cleaned <label> -- the container this run created was the one removed.
  assert_cleaned() {
    local name; name="$(label name)"
    [ -n "$name" ] || { echo "self-test[$1]: no container was created"; return 1; }
    [ "$(label removed)" = "$name" ] || { echo "self-test[$1]: $name should have been removed, removed: '$(label removed)'"; return 1; }
    return 0
  }

  # The command runs with the URL the settings describe, built from the port Docker published,
  # and the container is gone afterwards.
  reset
  out="$("$me" bash -c 'echo "$TEST_DATABASE_URL"')" || { echo "self-test: the run should succeed:"; echo "$out"; exit 1; }
  [ "$out" = "jdbc:postgresql://127.0.0.1:54321/appdb" ] \
    || { echo "self-test: the URL should be the template filled in, got '$out'"; failed=1; }
  name="$(label name)"
  case "$name" in loop-test-postgres-*) ;; *) echo "self-test: the container should be named for the run, got '$name'"; failed=1 ;; esac
  grep -qxF 'postgres:16-alpine' "$STUB_STATE/run-args" || { echo "self-test: test_db_image should be the image"; failed=1; }
  grep -qxF 'POSTGRES_DB=appdb' "$STUB_STATE/run-args" || { echo "self-test: test_db_name should be the database"; failed=1; }
  grep -qxF 'POSTGRES_USER=app' "$STUB_STATE/run-args" || { echo "self-test: test_db_user should be the role"; failed=1; }
  grep -qxF 'loop.synthetic-test=true' "$STUB_STATE/run-args" || { echo "self-test: the synthetic-test label is missing"; failed=1; }
  grep -qxF "loop.test-invocation=$name" "$STUB_STATE/run-args" || { echo "self-test: the ownership label is missing"; failed=1; }
  grep -qxF '127.0.0.1::5432' "$STUB_STATE/run-args" || { echo "self-test: the port should be published on loopback alone"; failed=1; }
  assert_cleaned "success" || failed=1

  # A failing command: its exit code reaches the caller and the container still goes.
  reset
  rc=0; "$me" bash -c 'exit 23' || rc=$?
  [ "$rc" = 23 ] || { echo "self-test: the command's exit code should pass through (got $rc)"; failed=1; }
  assert_cleaned "failure" || failed=1

  # An interruption mid-command: 143, and the container still goes.
  reset
  rc=0; "$me" bash -c 'kill -TERM "$PPID"' || rc=$?
  [ "$rc" = 143 ] || { echo "self-test: an interrupted command should exit 143 (got $rc)"; failed=1; }
  assert_cleaned "interruption" || failed=1

  # The ownership guard: a container whose label belongs to somebody else is not removed,
  # however the names collide.
  reset
  export STUB_FOREIGN=1
  "$me" true >/dev/null 2>&1 || { echo "self-test: the run should still succeed when the label is foreign"; failed=1; }
  if [ -n "$(label removed)" ]; then echo "self-test: a container this run does not own must not be removed"; failed=1; fi
  unset STUB_FOREIGN

  # The refusals: no Docker at all, a daemon that is not running, and no command to run. The
  # first runs the script on a PATH that carries the tools it needs and no docker, rather than
  # on a PATH that merely hopes the machine has none - a CI runner has one.
  reset
  mkdir -p "$dir/nodocker"
  for tool in bash dirname mktemp cat awk seq sleep date rm; do
    ln -sf "$(command -v "$tool")" "$dir/nodocker/$tool" 2>/dev/null || true
  done
  if PATH="$dir/nodocker" "$me" true >/dev/null 2>&1; then
    echo "self-test: a machine with no docker must be refused"; failed=1
  else
    out="$(PATH="$dir/nodocker" "$me" true 2>&1 || true)"
    printf '%s\n' "$out" | grep -q 'needs Docker' || { echo "self-test: the refusal should say docker is missing:"; echo "$out"; failed=1; }
  fi
  reset
  export STUB_NOT_RUNNING=1
  rc=0; "$me" true >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "self-test: a daemon that is not running should be refused (rc $rc)"; failed=1; }
  out="$("$me" true 2>&1 || true)"
  printf '%s\n' "$out" | grep -q 'daemon is not running' || { echo "self-test: the refusal should say why:"; echo "$out"; failed=1; }
  unset STUB_NOT_RUNNING
  rc=0; "$me" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "self-test: no command should be a usage error (rc $rc)"; failed=1; }

  [ "$failed" = 0 ] || exit 1
  # Not PATH: the trap that removes the fixture runs after this and needs `rm` to find it.
  unset LOOP_ROOT STUB_STATE
  echo "with-test-postgres self-test passed"
}

case "$MODE" in
  selftest) self_test ;;
  run) run "$@" ;;
esac
