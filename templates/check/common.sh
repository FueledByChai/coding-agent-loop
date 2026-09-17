# The loop's own checks, shared by every stack skeleton. Sourced by scripts/check.sh; not a
# script on its own. Expects ROOT and the step function.
loop_checks() {
  step "loop self-tests"
  # The checks between the markers are the same ones the kit's own check.sh runs, and
  # scripts/check-list.sh compares the two blocks: a check added here or there alone fails naming
  # it. What sits outside the markers is deliberately one-sided - the proof gate below is a
  # project's, while the kit's check proves ./install.sh instead.
  # >>> loop checks: shared with check.sh (scripts/check-list.sh compares this block)
  for s in loop-config backlog-status open-ticket-pr release-notes loop-kit-sync proof-gate coverage-ratchet review-status decisions prompt-check sprint check-list ruleset-check pr-readiness with-test-postgres compose-smoke; do
    [ -x "scripts/$s.sh" ] && "scripts/$s.sh" --self-test
  done
  # The prompts carry their rules: a phrase that states a rule may not be edited away.
  scripts/prompt-check.sh
  # The kit's records answer to the same sections and index a project's check demands of them.
  scripts/decisions.sh --check
  # The queue's own references: every id it names is defined, every ticket says how it is
  # proved, no ticket waits on itself, and every decision it cites is a record here.
  scripts/reference-check.sh
  # <<< loop checks
  # A ruleset that requires a status the paired workflow never reports holds every pull request
  # forever (LK-13). A project's pair is the ruleset the README's setup commands apply and the
  # workflow install.sh installs from the kit, so it is checked where both are in the checkout;
  # a project that keeps its applied ruleset elsewhere names the pair itself.
  if [ -f ci/ruleset.json ] && [ -f .github/workflows/loop.yml ]; then
    scripts/ruleset-check.sh ci/ruleset.json .github/workflows/loop.yml
  else
    echo "ruleset pair: none to check (no ci/ruleset.json beside .github/workflows/loop.yml); skipped"
  fi
  step "loop kit in step"
  if [ -n "$(scripts/loop-config.sh kit)" ]; then scripts/loop-kit-sync.sh --check; else echo "loop kit: none named in .loop.toml (kit); skipped"; fi
  step "proof gate: code changes bring a proof"
  scripts/proof-gate.sh
}

ratchet() {
  step "coverage ratchet"
  scripts/coverage-ratchet.sh
}
