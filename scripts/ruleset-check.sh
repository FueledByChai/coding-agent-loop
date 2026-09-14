#!/usr/bin/env bash
# Fails when a branch ruleset requires a status check the workflow it was written for never
# reports (LK-13). A required context is satisfied by a check run of that name and no other, so
# a ruleset naming a job the workflow does not have holds every pull request forever while every
# other check is green - and a green ruleset that names a job is exactly what a person checking
# by eye sees. That is how this repository's own ci/ruleset.json would have behaved had LK-09
# applied it unread: the kit's job is `Check (check.sh)` and the template says
# `Check (scripts/check.sh)`, which no job here will ever report.
#
#   scripts/ruleset-check.sh <ruleset.json> <workflow.yml> [<ruleset.json> <workflow.yml> ...]
#                                                      each pair is a ruleset and the workflow
#                                                      whose job names must be its contexts
#   scripts/ruleset-check.sh --self-test                a fixture pair proves the verdict
#
# A project applies ci/ruleset.json and runs ci/workflow.yml as .github/workflows/loop.yml, so
# the two are a pair there as well; a project's check names its own pair. The kit names both of
# its own - .github/ruleset.json with .github/workflows/ci.yml, and the template ci/ruleset.json
# with ci/workflow.yml - so neither pairing can drift unnoticed, and the template keeps the
# context a project's job actually reports.
#
# Only one direction is a fault. A required context with no job deadlocks every pull request; a
# job no ruleset requires is a check that runs and gates nothing, which is a choice. So the
# check is one-way: every context must name a job.
#
# The workflow is read with perl and no YAML library, because the kit is bash, git, and perl. A
# job is a key at the smallest indent under `jobs:`; its name is the `name:` at the smallest
# indent inside that job, and a job with no `name:` is reported by its key, which is what GitHub
# uses as the context too. A step's `name:` is deeper, or a `- ` list item, and is not a status
# context, so it is never read as one.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
ME="$ROOT/scripts/ruleset-check.sh"

# The contexts a ruleset requires and the names a workflow's jobs report, judged in one perl
# program so both files are read in one place and the two shapes cannot drift apart between two
# invocations.
verdict() { # <ruleset.json> <workflow.yml>
  local ruleset="$1" workflow="$2"
  [ -f "$ruleset" ] || { echo "ruleset-check: no such ruleset: $ruleset" >&2; exit 1; }
  [ -f "$workflow" ] || { echo "ruleset-check: no such workflow: $workflow" >&2; exit 1; }
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($ruleset, $workflow) = @ARGV;

    # The ruleset: the context of every required status check, in file order. Both the ruleset
    # shape and the older flat one are read, since a project may have applied either.
    open my $rf, "<", $ruleset or die "ruleset-check: cannot read $ruleset: $!\n";
    my $json = do { local $/; <$rf> };
    close $rf;
    my $r = eval { JSON::PP->new->utf8->decode($json) };
    die "ruleset-check: $ruleset is not JSON: $@\n" unless $r;
    my @contexts;
    for my $rule (@{ $r->{rules} || [] }) {
      next unless (($rule->{type} || "") eq "required_status_checks");
      my $p = $rule->{parameters} || {};
      push @contexts, map { $_->{context} } @{ $p->{required_status_checks} || [] };
      push @contexts, @{ $p->{contexts} || [] };
    }
    @contexts = grep { defined $_ && length $_ } @contexts;

    # A `#` outside a quoted scalar opens a comment that runs to the end of the line, so
    # `name: Check (check.sh) # required status` names the job `Check (check.sh)` rather than the
    # whole line. Comments are dropped here, once, so no pattern below has to allow for one - and
    # a `#` inside quotes is left alone, since there it is part of the name (LK-13).
    my $strip_comment = sub {
      my ($line) = @_;
      my $out = ""; my $quote;
      for my $ch (split //, $line) {
        if (defined $quote) { $out .= $ch; $quote = undef if $ch eq $quote; next }
        if ($ch eq q{"} || $ch eq chr(39)) { $quote = $ch; $out .= $ch; next }
        last if $ch eq "#" && ($out eq "" || substr($out, -1) =~ /\s/);
        $out .= $ch;
      }
      return $out;
    };

    # The workflow: its job names. `jobs:` at the top level opens the block; a key-only line at
    # the smallest indent inside it starts a job, and the next such line starts the next one.
    open my $wf, "<", $workflow or die "ruleset-check: cannot read $workflow: $!\n";
    my @lines = map { $strip_comment->($_) } <$wf>;
    close $wf;
    my $start;
    for my $i (0 .. $#lines) { if ($lines[$i] =~ /^jobs:\s*$/) { $start = $i + 1; last } }
    my @names;
    if (defined $start) {
      my @body;
      for my $i ($start .. $#lines) {
        last if $lines[$i] =~ /^\S/;   # back at the top level, so `jobs:` has ended
        push @body, $lines[$i];
      }
      my $job_indent;
      for my $l (@body) {
        next if $l =~ /^\s*#/ || $l =~ /^\s*$/;
        if ($l =~ /^(\s*)([^\s#-][^:]*):\s*$/) {
          my $ind = length $1;
          $job_indent = $ind if !defined $job_indent || $ind < $job_indent;
        }
      }
      if (defined $job_indent) {
        my @jobs;
        for my $l (@body) {
          if ($l =~ /^(\s*)([^\s#-][^:]*):\s*$/ && length($1) == $job_indent) {
            push @jobs, { key => $2, lines => [] };
            next;
          }
          push @{ $jobs[-1]{lines} }, $l if @jobs;
        }
        for my $j (@jobs) {
          # The job'"'"'s own keys sit at the smallest indent inside it, which is where a `name:`
          # has to be to be the job'"'"'s name rather than a step'"'"'s.
          my $key_indent;
          for my $l (@{ $j->{lines} }) {
            next if $l =~ /^\s*#/ || $l =~ /^\s*$/;
            if ($l =~ /^(\s*)([^\s#-][^:]*):\s*$/) {
              my $ind = length $1;
              $key_indent = $ind if !defined $key_indent || $ind < $key_indent;
            }
          }
          my $name;
          for my $l (@{ $j->{lines} }) {
            if ($l =~ /^(\s*)name:\s*(\S.*?)\s*$/ && (!defined $key_indent || length($1) == $key_indent)) {
              $name = $2; $name =~ s/^["\x27]//; $name =~ s/["\x27]$//; last;
            }
          }
          push @names, defined $name ? $name : $j->{key};
        }
      }
    }

    my %reported = map { $_ => 1 } @names;
    my @missing = grep { !$reported{$_} } @contexts;
    if (@missing) {
      my $have = @names ? join(", ", map { qq{"$_"} } @names) : "none";
      for my $c (@missing) {
        print STDERR "ruleset-check: $ruleset requires \"$c\", which $workflow has no job named; its jobs report $have\n";
      }
      exit 1;
    }
    exit 0;
  ' "$ruleset" "$workflow"
}

self_test() {
  # A plain variable, not a `local`: the trap that cleans it up runs at exit, when a local would
  # already be out of scope and `set -u` would turn the cleanup into an error.
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ruleset-check.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT

  cat > "$SELF_TEST_DIR/ruleset.json" <<'JSON'
{
  "rules": [
    { "type": "deletion" },
    { "type": "required_status_checks",
      "parameters": { "required_status_checks": [ { "context": "Check (check.sh)", "integration_id": 15368 } ] } }
  ]
}
JSON
  # The step is named after the context on purpose: a step is not a status check, so it must not
  # satisfy the requirement on its own.
  cat > "$SELF_TEST_DIR/workflow.yml" <<'YML'
name: CI
on:
  pull_request:
jobs:
  check:
    name: Check (check.sh)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check (scripts/check.sh)
        run: ./check.sh
YML

  "$ME" "$SELF_TEST_DIR/ruleset.json" "$SELF_TEST_DIR/workflow.yml" \
    || { echo "self-test: a ruleset whose context is a job's name should pass"; exit 1; }

  # A job the workflow does not have is the deadlock: the context is required and never
  # reported. This is the case the kit's own ci/ruleset.json was in.
  sed 's/^    name: Check (check.sh)$/    name: Check (scripts\/check.sh)/' "$SELF_TEST_DIR/workflow.yml" > "$SELF_TEST_DIR/renamed-job.yml"
  if "$ME" "$SELF_TEST_DIR/ruleset.json" "$SELF_TEST_DIR/renamed-job.yml" >"$SELF_TEST_DIR/out" 2>&1; then
    echo "self-test: renaming the job must fail the pair"; cat "$SELF_TEST_DIR/out"; exit 1
  fi
  grep -q 'requires "Check (check.sh)"' "$SELF_TEST_DIR/out" || { echo "self-test: the failure should name the required context:"; cat "$SELF_TEST_DIR/out"; exit 1; }
  grep -q 'no job named' "$SELF_TEST_DIR/out" || { echo "self-test: the failure should say the workflow has no such job:"; cat "$SELF_TEST_DIR/out"; exit 1; }
  grep -q 'its jobs report "Check (scripts/check.sh)"' "$SELF_TEST_DIR/out" || { echo "self-test: the failure should say what the jobs do report:"; cat "$SELF_TEST_DIR/out"; exit 1; }

  # The other half: the workflow is right and the ruleset asks for something else.
  sed 's/"context": "Check (check.sh)"/"context": "Check (scripts\/check.sh)"/' "$SELF_TEST_DIR/ruleset.json" > "$SELF_TEST_DIR/renamed-context.json"
  if "$ME" "$SELF_TEST_DIR/renamed-context.json" "$SELF_TEST_DIR/workflow.yml" >"$SELF_TEST_DIR/out" 2>&1; then
    echo "self-test: renaming the context must fail the pair"; cat "$SELF_TEST_DIR/out"; exit 1
  fi
  grep -q 'requires "Check (scripts/check.sh)"' "$SELF_TEST_DIR/out" || { echo "self-test: the failure should name the context it read:"; cat "$SELF_TEST_DIR/out"; exit 1; }

  # A job with no `name:` is reported by its key, which is what GitHub uses as the context, so a
  # context that matches the key passes and one that does not fails.
  sed 's/^    name: Check (check.sh)$/    runs-on: ubuntu-latest/' "$SELF_TEST_DIR/workflow.yml" > "$SELF_TEST_DIR/nameless.yml"
  if "$ME" "$SELF_TEST_DIR/ruleset.json" "$SELF_TEST_DIR/nameless.yml" >"$SELF_TEST_DIR/out" 2>&1; then
    echo "self-test: a nameless job reports its key, so the context must not match"; cat "$SELF_TEST_DIR/out"; exit 1
  fi
  cat > "$SELF_TEST_DIR/keyed.yml" <<'YML'
jobs:
  Check (check.sh):
    runs-on: ubuntu-latest
YML
  "$ME" "$SELF_TEST_DIR/ruleset.json" "$SELF_TEST_DIR/keyed.yml" \
    || { echo "self-test: a job with no name is reported by its key, which should match"; exit 1; }

  # A `#` outside quotes is a comment and not part of the name, so a workflow that annotates its
  # job name still reports the context the ruleset requires (LK-13).
  cat > "$SELF_TEST_DIR/commented.yml" <<'YML'
jobs:
  check:
    name: Check (check.sh) # required status
    runs-on: ubuntu-latest
YML
  "$ME" "$SELF_TEST_DIR/ruleset.json" "$SELF_TEST_DIR/commented.yml" \
    || { echo "self-test: an inline comment on a job name should be ignored"; exit 1; }

  # A `#` inside quotes is part of the name, so a name containing one is read whole rather than
  # cut at the `#` - and the comment after the closing quote is still dropped.
  cat > "$SELF_TEST_DIR/hash.json" <<'JSON'
{ "rules": [ { "type": "required_status_checks",
  "parameters": { "required_status_checks": [ { "context": "Check #1" } ] } } ] }
JSON
  cat > "$SELF_TEST_DIR/hash.yml" <<'YML'
jobs:
  check:
    name: "Check #1" # the first of two
    runs-on: ubuntu-latest
YML
  "$ME" "$SELF_TEST_DIR/hash.json" "$SELF_TEST_DIR/hash.yml" \
    || { echo "self-test: a quoted name should be read whole, not cut at the hash"; exit 1; }

  # A comment on the job's own key line must not hide the job. Before the comments were dropped,
  # `check: # the only job` did not look like a key at all, so the parser took the next key-only
  # line - `steps:` - for the job and reported it instead of the real one. The `name:` here is
  # clean, so this case turns on the key line alone.
  cat > "$SELF_TEST_DIR/keycomment.yml" <<'YML'
jobs:
  check: # the only job
    name: Check (check.sh)
    runs-on: ubuntu-latest
    steps:
      - run: ./check.sh
YML
  "$ME" "$SELF_TEST_DIR/ruleset.json" "$SELF_TEST_DIR/keycomment.yml" \
    || { echo "self-test: a comment on the job key should not hide the job"; exit 1; }

  # A ruleset requiring nothing cannot disagree with anything.
  printf '{ "rules": [ { "type": "deletion" } ] }\n' > "$SELF_TEST_DIR/none.json"
  "$ME" "$SELF_TEST_DIR/none.json" "$SELF_TEST_DIR/workflow.yml" \
    || { echo "self-test: a ruleset with no required checks should pass"; exit 1; }

  # A missing file is a mistake, not a pass.
  if "$ME" "$SELF_TEST_DIR/nope.json" "$SELF_TEST_DIR/workflow.yml" >"$SELF_TEST_DIR/out" 2>&1; then
    echo "self-test: a missing ruleset must fail"; exit 1
  fi

  echo "ruleset-check self-test passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  "") echo "usage: scripts/ruleset-check.sh <ruleset.json> <workflow.yml> [...] | --self-test" >&2; exit 2 ;;
  *)
    [ $(( $# % 2 )) -eq 0 ] || { echo "usage: scripts/ruleset-check.sh <ruleset.json> <workflow.yml> [...] | --self-test" >&2; exit 2; }
    while [ $# -gt 0 ]; do verdict "$1" "$2"; shift 2; done
    ;;
esac
