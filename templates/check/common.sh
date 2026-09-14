# The loop's own checks, shared by every stack skeleton. Sourced by scripts/check.sh; not a
# script on its own. Expects ROOT and the step function.
loop_checks() {
  step "loop self-tests"
  # The checks between the markers are the same ones the kit's own check.sh runs, and
  # scripts/check-list.sh compares the two blocks: a check added here or there alone fails naming
  # it. What sits outside the markers is deliberately one-sided - the proof gate below is a
  # project's, while the kit's check proves ./install.sh instead.
  # >>> loop checks: shared with check.sh (scripts/check-list.sh compares this block)
  for s in loop-config backlog-status open-ticket-pr release-notes loop-kit-sync proof-gate coverage-ratchet review-status decisions prompt-check sprint loop-tui check-list; do
    [ -x "scripts/$s.sh" ] && "scripts/$s.sh" --self-test
  done
  # The prompts carry their rules: a phrase that states a rule may not be edited away.
  scripts/prompt-check.sh
  # The kit's records answer to the same sections and index a project's check demands of them.
  scripts/decisions.sh --check
  # <<< loop checks
  step "loop kit in step"
  if [ -n "$(scripts/loop-config.sh kit)" ]; then scripts/loop-kit-sync.sh --check; else echo "loop kit: none named in .loop.toml (kit); skipped"; fi
  step "proof gate: code changes bring a proof"
  scripts/proof-gate.sh
}

ratchet() {
  step "coverage ratchet"
  scripts/coverage-ratchet.sh
}
