#!/usr/bin/env bash
# Installs the loop kit into a checkout (HK-16): the scripts into scripts/, the prompts into
# loop/prompts/, loop.toml.example at the root as the current settings documentation, AGENTS.md
# and .loop.toml when absent, the workflow skeleton when there is no workflow, and the four
# wrappers and four skill pointers when their directories are given. Then it says what the
# project still has to supply.
#
# .loop.toml is written from the example once and is the project's own file afterwards; the example
# beside it is the kit's and is refreshed by every install and by scripts/loop-kit-sync.sh, so the
# file a project reads to learn what a setting means does not go stale (LK-19).
#
#   install.sh <checkout> [--commands <dir>] [--skills <dir>]
#                                               install into <checkout>
#   install.sh --self-test                      a fresh repository with a stub check proves the
#                                               install and the installed self-tests
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
COMMANDS=""
SKILLS=""
[ -n "$TARGET" ] || { echo "usage: install.sh <checkout> [--commands <dir>] [--skills <dir>] | --self-test" >&2; exit 2; }
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --commands) COMMANDS="$2"; shift ;;
    --skills) SKILLS="$2"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

# A skill's body: everything after its frontmatter, which is the only part that could restate a
# rule.
skill_body() { awk '/^---$/{n++; next} n>=2' "$1"; }

# A skill is a pointer, like a command wrapper: frontmatter a harness can match, then the sentence
# that sends the agent to `loop/prompts/<name>.md`, and no line of that prompt. The skills this kit
# used to leave to hand-copies were restatements, and three of them had drifted from their prompts
# before anyone noticed (LK-18), so a skill that carries a prompt line - or names the wrong prompt,
# or has no frontmatter for the harness to load - is refused here rather than installed.
check_skill() {
  local name="$1" skill="$2" prompt="$3" line
  [ -f "$skill" ] || { echo "install: no skills/$name/SKILL.md for loop/prompts/$name.md" >&2; return 1; }
  [ -f "$prompt" ] || { echo "install: no loop/prompts/$name.md for skills/$name/SKILL.md" >&2; return 1; }
  grep -qx "name: $name" "$skill" \
    || { echo "install: skills/$name/SKILL.md should declare 'name: $name'" >&2; return 1; }
  grep -q '^description: .' "$skill" \
    || { echo "install: skills/$name/SKILL.md should carry a description for the harness to match" >&2; return 1; }
  grep -qF "Read \`loop/prompts/$name.md\` and follow it exactly" "$skill" \
    || { echo "install: skills/$name/SKILL.md does not point at loop/prompts/$name.md" >&2; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -Fxq "$line" "$prompt"; then
      echo "install: skills/$name/SKILL.md restates loop/prompts/$name.md: $line" >&2
      return 1
    fi
  done < <(skill_body "$skill")
  return 0
}

install_into() {
  local target="$1" commands="$2" skills="$3" f n d
  [ -d "$target" ] || { echo "no such directory: $target" >&2; return 1; }
  target="$(cd "$target" && pwd)"
  mkdir -p "$target/scripts" "$target/loop/prompts" "$target/loop/templates/check" "$target/loop/templates/ci"
  for f in "$KIT"/scripts/*.sh; do cp "$f" "$target/scripts/"; chmod +x "$target/scripts/$(basename "$f")"; done
  # A helper in another language travels the same way the shell scripts do: two globs, two
  # extensions, and nothing else under scripts/ ships. Widening one and not the other is how a
  # file looks shipped and never arrives (LK-35).
  for f in "$KIT"/scripts/*.py; do [ -e "$f" ] || continue; cp "$f" "$target/scripts/"; chmod +x "$target/scripts/$(basename "$f")"; done
  for f in "$KIT"/prompts/*.md; do cp "$f" "$target/loop/prompts/"; done
  for f in "$KIT"/templates/*.md; do cp "$f" "$target/loop/templates/"; done
  for f in "$KIT"/templates/check/*.sh; do cp "$f" "$target/loop/templates/check/"; done
  for f in "$KIT"/templates/ci/*.yml; do cp "$f" "$target/loop/templates/ci/"; done
  # The example is the kit's file and is refreshed every install, unlike the .loop.toml written
  # from it, which is the project's own and is written once (LK-19).
  cp "$KIT/loop.toml.example" "$target/loop.toml.example"
  echo "installed: scripts/{$(cd "$KIT/scripts" && ls | tr '\n' ',' | sed 's/,$//')}, loop/prompts/*.md, loop/templates/*.md, loop/templates/check/*.sh, loop/templates/ci/*.yml, and loop.toml.example"
  if [ -e "$target/AGENTS.md" ]; then
    echo "kept: AGENTS.md (already present; compare its loop section with the kit's when you update)"
  else
    cp "$KIT/AGENTS.md" "$target/AGENTS.md"; echo "installed: AGENTS.md (fill in the Project rules)"
  fi
  # Codex reads AGENTS.md on its own; Claude Code reads CLAUDE.md, so it gets a one-line
  # pointer at the same file (HK-37).
  if [ -e "$target/CLAUDE.md" ]; then
    echo "kept: CLAUDE.md (already present; make sure it includes @AGENTS.md)"
  else
    printf '@AGENTS.md\n' > "$target/CLAUDE.md"; echo "installed: CLAUDE.md (@AGENTS.md, so Claude Code loads the same instructions Codex reads)"
  fi
  if [ -e "$target/.loop.toml" ]; then
    echo "kept: .loop.toml (already present)"
  else
    cp "$KIT/loop.toml.example" "$target/.loop.toml"; echo "installed: .loop.toml (from the example; set kit to the kit's URL and kit_ref to a tag)"
  fi
  if [ -d "$target/.github/workflows" ] && [ -n "$(ls "$target/.github/workflows" 2>/dev/null)" ]; then
    echo "kept: .github/workflows (a workflow exists; compare with the kit's ci/workflow.yml)"
  else
    mkdir -p "$target/.github/workflows"; cp "$KIT/ci/workflow.yml" "$target/.github/workflows/loop.yml"
    echo "installed: .github/workflows/loop.yml (one job per check command; its job names are the required status checks)"
  fi
  # The ruleset is the other half of that pair: `Check (scripts/check.sh)` is the context the
  # installed workflow's job reports. A project gets both, so the README's
  # `gh api ... --input ci/ruleset.json` names a file that is actually there, and the check
  # skeleton's `scripts/ruleset-check.sh ci/ruleset.json .github/workflows/loop.yml` has a pair to
  # judge rather than quietly finding nothing to check (LK-13).
  if [ -e "$target/ci/ruleset.json" ]; then
    echo "kept: ci/ruleset.json (already present)"
  else
    mkdir -p "$target/ci"; cp "$KIT/ci/ruleset.json" "$target/ci/ruleset.json"
    echo "installed: ci/ruleset.json (the branch ruleset that pairs with .github/workflows/loop.yml; apply it with the gh command in README.md)"
  fi
  if [ -n "$commands" ]; then
    mkdir -p "$target/$commands"
    for f in "$KIT"/commands/*.md; do cp "$f" "$target/$commands/"; done
    echo "installed: $commands/{next-ticket,grill-me,review-prs,grill-project}.md wrappers"
  fi
  # One skill per prompt, checked before it is copied, so a fresh install cannot reproduce the
  # drift the hand-copied skills had (LK-18). The second loop is the other direction: a skill with
  # no prompt to point at is a file nothing can keep honest.
  if [ -n "$skills" ]; then
    for f in "$KIT"/prompts/*.md; do
      n="$(basename "$f" .md)"
      check_skill "$n" "$KIT/skills/$n/SKILL.md" "$f" || return 1
      mkdir -p "$target/$skills/$n"
      cp "$KIT/skills/$n/SKILL.md" "$target/$skills/$n/SKILL.md"
    done
    for d in "$KIT"/skills/*/; do
      n="$(basename "$d")"
      [ -f "$KIT/prompts/$n.md" ] \
        || { echo "install: skills/$n/SKILL.md has no loop/prompts/$n.md to point at" >&2; return 1; }
    done
    echo "installed: $skills/{$(cd "$KIT/prompts" && ls *.md | sed 's/\.md$//' | tr '\n' ',' | sed 's/,$//')}/SKILL.md pointers"
  fi
  if [ ! -e "$target/$(basename "$(cd "$target" && "$target/scripts/loop-config.sh" backlog)")" ]; then
    echo "note: the backlog file ($(cd "$target" && "$target/scripts/loop-config.sh" backlog)) does not exist yet; create it with a heading per section and a ticket per '### <ID> <title>'"
  fi
  cat <<EOF

Still to supply:
  1. scripts/check.sh: the definition of done for this project (exit non-zero on anything not
     shippable). On a new project run the grill-project prompt first: it interviews you and
     writes it from the skeleton for your stack (loop/templates/check/), along with the
     Project rules, the decision records, and the first epics. On an existing project write
     it by hand and run the loop self-tests from it (scripts/loop-config.sh --self-test,
     scripts/backlog-status.sh --self-test, scripts/open-ticket-pr.sh --self-test,
     scripts/release-notes.sh --self-test,
     scripts/check-list.sh --self-test, scripts/ruleset-check.sh --self-test, scripts/loop-kit-sync.sh --check,
     scripts/decisions.sh --check, scripts/prompt-check.sh).
     $( [ -x "$target/scripts/check.sh" ] && echo "(present)" || echo "(missing)" )
  2. Optionally a deploy script, if a merged PR should reach a running service on its own.
  3. The repository settings and branch ruleset, once, with gh: apply the ci/ruleset.json
     install.sh wrote (README.md has the commands). It pairs with .github/workflows/loop.yml,
     and the check skeleton already names that pair - scripts/ruleset-check.sh ci/ruleset.json
     .github/workflows/loop.yml - so a ruleset requiring a status the workflow never reports
     cannot land unnoticed.
  4. The Project rules section of AGENTS.md (grill-project writes it on a new project).
EOF
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loop-install.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR/fresh" out loop_runs=0 pair f want marker first=1 suite='== loop self-tests' n p fix
  mkdir -p "$dir/scripts"
  (cd "$dir" && git init -q && git config user.email t@example.com && git config user.name t)
  printf '#!/usr/bin/env bash\necho stub check\n' > "$dir/scripts/check.sh"; chmod +x "$dir/scripts/check.sh"
  out="$("$KIT/install.sh" "$dir" --commands .agent/commands --skills .agent/skills)"
  echo "$out" | grep -q '^installed: AGENTS.md' || { echo "self-test: AGENTS.md should be installed:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^installed: .loop.toml' || { echo "self-test: .loop.toml should be installed:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^installed: .github/workflows/loop.yml' || { echo "self-test: the workflow should be installed:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^installed: ci/ruleset.json' || { echo "self-test: the ruleset should be installed:"; echo "$out"; exit 1; }
  [ -f "$dir/ci/ruleset.json" ] || { echo "self-test: ci/ruleset.json should be installed"; exit 1; }
  [ -f "$dir/loop.toml.example" ] || { echo "self-test: loop.toml.example should be installed at the root"; exit 1; }
  echo "$out" | grep -q '^installed: .agent/commands/' || { echo "self-test: the wrappers should be installed:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^installed: .agent/skills/' || { echo "self-test: the skill pointers should be installed:"; echo "$out"; exit 1; }
  # One skill per prompt, and each one a pointer at its prompt rather than a copy of it. This is
  # the assertion a restatement fails, whichever way it got in (LK-18).
  for p in "$dir"/loop/prompts/*.md; do
    n="$(basename "$p" .md)"
    check_skill "$n" "$dir/.agent/skills/$n/SKILL.md" "$p" \
      || { echo "self-test: the installed $n skill should be a pointer at loop/prompts/$n.md"; exit 1; }
  done
  # The kit's own skills are checked at install time, so the check has to bite. A body replaced
  # with the prompt's is the drift this was filed from; a skill pointing at another prompt, one
  # whose frontmatter names another skill, and a prompt with no skill beside it are the rest.
  fix="$SELF_TEST_DIR/drift"
  mkdir -p "$fix/skills/AA-01" "$fix/prompts"
  printf 'A rule the prompt states.\nAnother rule it states.\n' > "$fix/prompts/AA-01.md"
  { printf -- '---\nname: AA-01\ndescription: a restatement.\n---\n\n'; cat "$fix/prompts/AA-01.md"; } > "$fix/skills/AA-01/SKILL.md"
  if check_skill AA-01 "$fix/skills/AA-01/SKILL.md" "$fix/prompts/AA-01.md" >/dev/null 2>&1; then
    echo "self-test: a skill whose body is the prompt's must be refused"; exit 1
  fi
  printf -- '---\nname: AA-01\ndescription: a pointer.\n---\n\nRead `loop/prompts/AA-99.md` and follow it exactly.\n' > "$fix/skills/AA-01/SKILL.md"
  if check_skill AA-01 "$fix/skills/AA-01/SKILL.md" "$fix/prompts/AA-01.md" >/dev/null 2>&1; then
    echo "self-test: a skill pointing at a different prompt must be refused"; exit 1
  fi
  printf -- '---\nname: AA-02\ndescription: a pointer.\n---\n\nRead `loop/prompts/AA-01.md` and follow it exactly.\n' > "$fix/skills/AA-01/SKILL.md"
  if check_skill AA-01 "$fix/skills/AA-01/SKILL.md" "$fix/prompts/AA-01.md" >/dev/null 2>&1; then
    echo "self-test: a skill whose frontmatter names another skill must be refused"; exit 1
  fi
  printf -- '---\ndescription: no name.\n---\n\nRead `loop/prompts/AA-01.md` and follow it exactly.\n' > "$fix/skills/AA-01/SKILL.md"
  if check_skill AA-01 "$fix/skills/AA-01/SKILL.md" "$fix/prompts/AA-01.md" >/dev/null 2>&1; then
    echo "self-test: a skill with no name: line must be refused"; exit 1
  fi
  printf -- '---\nname: AA-01\ndescription: a pointer.\n---\n\nRead `loop/prompts/AA-01.md` and follow it exactly.\n' > "$fix/skills/AA-01/SKILL.md"
  check_skill AA-01 "$fix/skills/AA-01/SKILL.md" "$fix/prompts/AA-01.md" \
    || { echo "self-test: a pointer skill should be accepted"; exit 1; }
  printf 'A rule the prompt states.\n' > "$fix/prompts/AA-09.md"
  if check_skill AA-09 "$fix/skills/AA-09/SKILL.md" "$fix/prompts/AA-09.md" >/dev/null 2>&1; then
    echo "self-test: a prompt with no skill beside it must be refused"; exit 1
  fi
  echo "$out" | grep -q '(present)' || { echo "self-test: the stub check should be reported present:"; echo "$out"; exit 1; }
  for f in loop-config backlog-status open-ticket-pr release-notes loop-kit-sync proof-gate coverage-ratchet review-status decisions prompt-check sprint check-list ruleset-check pr-readiness reference-check with-test-postgres; do
    [ -x "$dir/scripts/$f.sh" ] || { echo "self-test: scripts/$f.sh missing or not executable"; exit 1; }
  done
  [ -x "$dir/scripts/coverage-percent.py" ] || { echo "self-test: scripts/coverage-percent.py missing or not executable"; exit 1; }
  [ -f "$dir/loop/templates/decision.md" ] || { echo "self-test: the decision template should be installed"; exit 1; }
  for f in common rust python node java go other; do [ -f "$dir/loop/templates/check/$f.sh" ] || { echo "self-test: the $f check skeleton should be installed"; exit 1; }; done
  for f in rust python node java go other; do [ -f "$dir/loop/templates/ci/$f.yml" ] || { echo "self-test: the $f CI snippet should be installed"; exit 1; }; done
  # Each CI snippet spliced into the workflow skeleton where grill-project puts it (between
  # the checkout step and the run line) is a workflow a YAML parser accepts, with the check
  # still the last step (HK-38). ruby ships with YAML on macOS and the GitHub runners;
  # python's yaml is the fallback.
  local parser=""
  if ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then parser=ruby; elif python3 -c 'import yaml' >/dev/null 2>&1; then parser=python; fi
  for f in rust python node java go other; do
    awk -v snip="$dir/loop/templates/ci/$f.yml" '{print} /uses: actions\/checkout/ {while ((getline line < snip) > 0) if (line !~ /^#/) print line}' "$dir/.github/workflows/loop.yml" > "$dir/loop-$f.yml"
    grep -q 'run: scripts/check.sh' "$dir/loop-$f.yml" || { echo "self-test: the spliced $f workflow lost the check step"; exit 1; }
    case "$parser" in
      ruby) ruby -ryaml -e 'w = YAML.safe_load(File.read(ARGV[0])); s = w["jobs"]["check"]["steps"]; abort("steps") unless s.length >= 3 && s.last["run"] == "scripts/check.sh"' "$dir/loop-$f.yml" || { echo "self-test: the spliced $f workflow should parse with the check last:"; cat "$dir/loop-$f.yml"; exit 1; } ;;
      python) python3 -c 'import sys, yaml; w = yaml.safe_load(open(sys.argv[1])); s = w["jobs"]["check"]["steps"]; assert len(s) >= 3 and s[-1]["run"] == "scripts/check.sh"' "$dir/loop-$f.yml" || { echo "self-test: the spliced $f workflow should parse with the check last:"; cat "$dir/loop-$f.yml"; exit 1; } ;;
      *) echo "self-test: no YAML parser (ruby or python yaml); the spliced workflows were not parsed" ;;
    esac
  done
  [ -f "$dir/.agent/commands/grill-project.md" ] || { echo "self-test: the grill-project wrapper should be installed"; exit 1; }
  # Every skeleton runs green on the empty repository. The loop checks each one sources from
  # loop/templates/check/common.sh are identical and are the bulk of the run, so they are proved
  # once, in full, through the first skeleton; the other five run with that file stubbed to a
  # marker, which still proves the skeleton sources it, calls loop_checks, and reaches its own
  # stack step - without repeating the suite six times (LK-11).
  for pair in "rust|skipped: no Cargo.toml yet" "python|skipped: no pyproject.toml yet" \
              "node|skipped: no package.json yet" "java|skipped: no pom.xml or build.gradle yet" \
              "go|skipped: no go.mod yet" "other|TODO: the formatter's check command"; do
    f="${pair%%|*}"; want="${pair#*|}"
    cp "$dir/loop/templates/check/$f.sh" "$dir/scripts/check.sh"; chmod +x "$dir/scripts/check.sh"
    if [ "$first" = 1 ]; then
      marker="$suite"
    else
      marker="loop checks: stubbed for the $f skeleton"
      printf 'loop_checks() { echo "%s"; }\nratchet() { :; }\n' "$marker" > "$dir/loop/templates/check/common.sh"
    fi
    (cd "$dir" && scripts/check.sh > "$dir/check-$f.log" 2>&1) || { echo "self-test: the $f skeleton should pass on an empty repository:"; tail -15 "$dir/check-$f.log"; exit 1; }
    grep -q 'ALL CHECKS PASSED' "$dir/check-$f.log" || { echo "self-test: the $f skeleton should print the pass line"; exit 1; }
    grep -qF "$marker" "$dir/check-$f.log" || { echo "self-test: the $f skeleton should call the shared loop checks:"; tail -15 "$dir/check-$f.log"; exit 1; }
    grep -qF "$want" "$dir/check-$f.log" || { echo "self-test: the $f skeleton should reach its own stack step:"; tail -15 "$dir/check-$f.log"; exit 1; }
    # Measured, not asserted: the count is how many times the shared suite actually ran across
    # the six logs, so a skeleton that called loop_checks twice - the regression LK-11 exists to
    # catch - reads as 2 here instead of being reported as 1 (LK-11).
    loop_runs=$((loop_runs + $(grep -cF "$suite" "$dir/check-$f.log" || true)))
    first=0
  done
  [ "$loop_runs" = 1 ] || { echo "self-test: the shared loop checks should run exactly once, ran $loop_runs time(s)"; exit 1; }
  echo "loop checks: $loop_runs run (the six skeletons' stack steps are proved separately)"
  # The ruleset and the workflow are installed as a pair, and the generated check judges them:
  # both halves are there, so the guard runs the verdict rather than reporting there is nothing
  # to check. The pair itself is consistent - the workflow's job name is the context the ruleset
  # requires - and the first skeleton's log proves the check reached it (LK-13).
  (cd "$dir" && scripts/ruleset-check.sh ci/ruleset.json .github/workflows/loop.yml) \
    || { echo "self-test: the installed ruleset should match the installed workflow"; exit 1; }
  grep -q 'ruleset pair: none to check' "$dir/check-rust.log" \
    && { echo "self-test: the installed pair should be checked, not skipped:"; grep 'ruleset' "$dir/check-rust.log"; exit 1; }
  (cd "$dir" && scripts/decisions.sh --self-test | grep -q 'self-test passed') || { echo "self-test: installed decisions self-test failed"; exit 1; }
  (cd "$dir" && scripts/prompt-check.sh | grep -q 'rule(s) present') || { echo "self-test: the installed prompts should pass prompt-check"; exit 1; }
  [ -e "$dir/loop/prompts/next-ticket.md" ] && [ -e "$dir/loop/prompts/grill-me.md" ] || { echo "self-test: prompts missing"; exit 1; }
  grep -q '^## Project rules' "$dir/AGENTS.md" || { echo "self-test: AGENTS.md lacks the Project rules heading"; exit 1; }
  echo "$out" | grep -q '^installed: CLAUDE.md' || { echo "self-test: CLAUDE.md should be installed:"; echo "$out"; exit 1; }
  [ "$(cat "$dir/CLAUDE.md")" = "@AGENTS.md" ] || { echo "self-test: CLAUDE.md should be the one line @AGENTS.md"; exit 1; }
  # The installed scripts prove themselves from the fresh repository.
  (cd "$dir" && scripts/loop-config.sh --self-test | grep -q 'self-test passed') || { echo "self-test: installed loop-config self-test failed"; exit 1; }
  (cd "$dir" && scripts/backlog-status.sh --self-test | grep -q 'self-test passed') || { echo "self-test: installed backlog-status self-test failed"; exit 1; }
  (cd "$dir" && scripts/release-notes.sh --self-test | grep -q 'self-test passed') || { echo "self-test: installed release-notes self-test failed"; exit 1; }
  (cd "$dir" && scripts/open-ticket-pr.sh --self-test | grep -q 'self-test passed') || { echo "self-test: installed open-ticket-pr self-test failed"; exit 1; }
  (cd "$dir" && scripts/check-list.sh --self-test | grep -q 'self-test passed') || { echo "self-test: installed check-list self-test failed"; exit 1; }
  (cd "$dir" && scripts/ruleset-check.sh --self-test | grep -q 'self-test passed') || { echo "self-test: installed ruleset-check self-test failed"; exit 1; }
  (cd "$dir" && python3 scripts/coverage-percent.py --self-test | grep -q 'coverage-percent self-test passed') \
    || { echo "self-test: the installed coverage helper's self-test failed"; exit 1; }
  # Installing again keeps what exists, and refreshes what is the kit's. The pair to prove is
  # .loop.toml against loop.toml.example: both are edited here, and only the example comes back
  # (LK-19).
  printf 'drifted\n' >> "$dir/loop.toml.example"
  printf '# mine\n' >> "$dir/.loop.toml"
  out="$("$KIT/install.sh" "$dir")"
  echo "$out" | grep -q '^kept: AGENTS.md' || { echo "self-test: a second install must keep AGENTS.md:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^kept: CLAUDE.md' || { echo "self-test: a second install must keep CLAUDE.md:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^kept: .loop.toml' || { echo "self-test: a second install must keep .loop.toml:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^kept: .github/workflows' || { echo "self-test: a second install must keep the workflow:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^kept: ci/ruleset.json' || { echo "self-test: a second install must keep the ruleset:"; echo "$out"; exit 1; }
  cmp -s "$KIT/loop.toml.example" "$dir/loop.toml.example" || { echo "self-test: a second install must refresh loop.toml.example from the kit"; exit 1; }
  grep -q '^# mine$' "$dir/.loop.toml" || { echo "self-test: a second install must keep the project's own .loop.toml"; exit 1; }
  echo "install self-test passed"
}

case "$TARGET" in
  --self-test) self_test ;;
  *) install_into "$TARGET" "$COMMANDS" "$SKILLS" ;;
esac
