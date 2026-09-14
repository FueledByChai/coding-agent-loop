# The loop's own checks, shared by every stack skeleton. Sourced by scripts/check.sh; not a
# script on its own. Expects ROOT and the step function.
loop_checks() {
  step "loop self-tests"
  for s in loop-config backlog-status open-ticket-pr release-notes loop-kit-sync proof-gate coverage-ratchet review-status decisions prompt-check sprint loop-tui ruleset-check; do
    [ -x "scripts/$s.sh" ] && "scripts/$s.sh" --self-test
  done
  # A ruleset that requires a status the paired workflow never reports holds every pull request
  # forever (LK-13). A project's pair is the ruleset the README's setup commands apply and the
  # workflow install.sh installs from the kit, so it is checked where both are in the checkout;
  # a project that keeps its applied ruleset elsewhere names the pair itself.
  if [ -f ci/ruleset.json ] && [ -f .github/workflows/loop.yml ]; then
    scripts/ruleset-check.sh ci/ruleset.json .github/workflows/loop.yml
  else
    echo "ruleset pair: none to check (no ci/ruleset.json beside .github/workflows/loop.yml); skipped"
  fi
  step "loop kit, prompts, and decision records in step"
  if [ -n "$(scripts/loop-config.sh kit)" ]; then scripts/loop-kit-sync.sh --check; else echo "loop kit: none named in .loop.toml (kit); skipped"; fi
  scripts/prompt-check.sh
  scripts/decisions.sh --check
  step "proof gate: code changes bring a proof"
  scripts/proof-gate.sh
}

ratchet() {
  step "coverage ratchet"
  scripts/coverage-ratchet.sh
}
