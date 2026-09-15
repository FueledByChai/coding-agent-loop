#!/usr/bin/env bash
# The loop's own checks are written down more than once: the kit's check.sh runs them, the
# loop_checks a project sources from loop/templates/check/common.sh runs them, and AGENTS.md's
# "The check" section describes them. Nothing compared any two of them, so the only thing keeping
# them equal was that someone remembered - and they had already drifted twice: the kit's check ran
# no `decisions.sh --check` while every project's did (LK-05), and a merge that landed two
# rewrites of that section spliced them into a paragraph saying the decision-record check was not
# wired in, one line above the sentence that wired it in (LK-16). A check line that is missing
# looks exactly like a check line that passed.
#
# Each file keeps its loop checks between two markers, and this script compares the checks in the
# marked blocks, so a check added to one and not the other fails the check naming it (LK-14). The
# comparison is over the checks themselves - the script each line runs and the flags it runs it
# with - so the two blocks may differ in how they are written: the loop variable's name, the
# `[ -x ... ]` guard a project's copy carries, the marker's own free text. Only the marked block
# is compared: a check that is deliberately one-sided - the kit's `./install.sh --self-test`, a
# project's proof gate - lives outside the markers.
#
# A prose section is compared by name instead (LK-16): `--section` reads the `scripts/<name>.sh`
# a Markdown section mentions and the ones a script runs as work of its own, and fails on either
# side alone. A script the script under comparison only ever runs with `--self-test` is the sweep
# every script gets, which the section states once in its own words and not as a check, so it is
# not required to be named; a script it runs with any other flags - bare, `--check`, a pair of
# files to compare - is a check and must be named. Both directions fail, so a check wired into
# the script and left out of the section is a difference too, not just one dropped from the
# section.
#
#   scripts/check-list.sh <file> [<file> ...]   compare the marked blocks; exit 1 on any difference
#   scripts/check-list.sh --section <doc> <heading> <script>
#                                               compare the checks a section of prose names with
#                                               the ones a script runs; exit 1 on any difference
#   scripts/check-list.sh --self-test           a check dropped from one side fails, naming it;
#                                               equal sides pass
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The marker words. A marker is a comment line containing the arrows; the rest of the line is free
# text, so the two files may name each other there.
OPEN='>>> loop checks'
CLOSE='<<< loop checks'

# <file> <mode>: the checks the file runs, one per line, sorted. Mode `block` (the default) reads
# only the marked block and prints each check as `<script> <flags>`; mode `real` reads the whole
# file and prints the names of the checks that are work of their own. A `for <var> in <names>; do`
# header contributes each name with the flags its body runs it with, so the block can be a loop in
# one file and written out in the other.
extract() {
  local file="$1" mode="${2:-block}" out rc=0
  [ -r "$file" ] || { echo "check-list: cannot read $file" >&2; return 1; }
  out="$(perl -e '
    my ($file, $mode, $open, $close) = @ARGV;
    open my $fh, "<", $file or exit 2;
    my ($in, $seen, @lines) = (0, 0);
    while (my $line = <$fh>) {
      if ($line =~ /^\s*#\s*\Q$open\E/) { $in = 1; $seen = 1; next }
      if ($line =~ /^\s*#\s*\Q$close\E/) { $in = 0; next }
      # A comment is free text in either mode - the two blocks may explain themselves
      # differently, or in one file only - and `scripts/x.sh` inside one is not an invocation.
      next if $line =~ /^\s*#/;
      next unless $mode eq "real" || $in;
      $line =~ s/\s+#.*//;
      push @lines, $line;
    }
    exit 3 if $mode eq "block" && !$seen;
    my $text = join "", @lines;

    # `for <var> in <names>; do` names the scripts its body runs: expand each name.
    my %loops;
    while ($text =~ /for\s+(\w+)\s+in\s+([^;]+);/g) {
      my @names = grep { length } split " ", $2;
      $loops{$1} = \@names if @names;
    }
    for my $var (keys %loops) { $text =~ s/\$\{\Q$var\E\}|\$\Q$var\E\b/%$var%/g }
    # A test operand is not an invocation.
    $text =~ s/\[[^\]]*\]//g;

    # An invocation starts a command: at the line, or after &&, ||, ;, do or then. Anything else -
    # `scripts/x.sh` inside an echo - is prose. The flags run to the next command or line.
    my (%tok, %real);
    while ($text =~ /(?:^|[;&|]|do\b|then\b)\s*"?scripts\/([A-Za-z0-9._%+-]+)\.sh"?([^\n;&|]*)/mg) {
      my ($name, $flags) = ($1, $2);
      # Quotes first, then the trim: `"scripts/x.sh" --check` leaves a leading space otherwise.
      $flags =~ s/["\x27]//g; $flags =~ s/^\s+//; $flags =~ s/\s+$//;
      my @names = $name =~ /^%(\w+)%$/ ? @{ $loops{$1} || [] } : ($name);
      for my $n (@names) {
        $tok{ length $flags ? "$n $flags" : $n }++;
        # `--self-test` and nothing else is the sweep every script gets, not a check of its own.
        $real{$n} = 1 unless length $flags && $flags eq "--self-test";
      }
    }
    if ($mode eq "real") { print "$_\n" for sort keys %real }
    else { print "$_\n" for sort keys %tok }
  ' "$file" "$mode" "$OPEN" "$CLOSE")" || rc=$?
  case "$rc" in
    0) [ -n "$out" ] && printf '%s\n' "$out" ;;
    3) echo "check-list: $file has no \"# $OPEN\" block to compare" >&2; return 1 ;;
    *) echo "check-list: cannot read $file" >&2; return 1 ;;
  esac
}

compare() {
  local f failed=0 i check
  local -a names=() blocks=()
  for f in "$@"; do
    local b; b="$(mktemp "${TMPDIR:-/tmp}/check-list.XXXXXX")"
    extract "$f" | LC_ALL=C sort > "$b" || { rm -f "$b"; return 1; }
    names+=("$f"); blocks+=("$b")
  done
  local union; union="$(mktemp "${TMPDIR:-/tmp}/check-list.XXXXXX")"
  cat "${blocks[@]}" | LC_ALL=C sort -u > "$union"
  # Every check in any block, and the files that do not run it: reported from whichever side has
  # it, so a check dropped from either file is named together with the file missing it.
  while IFS= read -r check; do
    [ -n "$check" ] || continue
    local have="" lack=""
    for i in "${!blocks[@]}"; do
      if LC_ALL=C grep -qxF -- "$check" "${blocks[$i]}"; then have="$have ${names[$i]}"
      else lack="$lack ${names[$i]}"; fi
    done
    [ -z "$lack" ] || { echo "check-list: the check \"$check\" is run by${have} but not by${lack}" >&2; failed=1; }
  done < "$union"
  rm -f "${blocks[@]}" "$union"
  [ "$failed" = 0 ] || { echo "check-list: the loop's checks are not the same in every file above" >&2; return 1; }
  echo "check-list: the marked block runs the same ${#names[@]} file(s)' checks"
}

# <doc> <heading>: the `scripts/<name>.sh` a Markdown section mentions, one per line, sorted. The
# section runs from its heading to the next heading at the same or a higher level, so a mention
# anywhere in its prose counts and the section needs no markers of its own.
section_names() {
  local doc="$1" heading="$2" out rc=0
  [ -r "$doc" ] || { echo "check-list: cannot read $doc" >&2; return 1; }
  out="$(perl -e '
    my ($doc, $heading) = @ARGV;
    open my $fh, "<", $doc or exit 2;
    $heading =~ s/^\s+//; $heading =~ s/\s+$//;
    my ($in, $level, %names) = (0, 0);
    while (my $line = <$fh>) {
      if ($line =~ /^(#+)\s+(.*?)\s*$/) {
        my ($hashes, $text) = ($1, $2);
        last if $in && length($hashes) <= $level;
        ($in, $level) = (1, length $hashes) if !$in && $text eq $heading;
        next;
      }
      next unless $in;
      $names{$1} = 1 while $line =~ /scripts\/([A-Za-z0-9._%+-]+)\.sh/g;
    }
    exit 3 unless $in;
    print "$_\n" for sort keys %names;
  ' "$doc" "$heading")" || rc=$?
  case "$rc" in
    0) [ -n "$out" ] && printf '%s\n' "$out" ;;
    3) echo "check-list: $doc has no \"$heading\" section" >&2; return 1 ;;
    *) echo "check-list: cannot read $doc" >&2; return 1 ;;
  esac
}

# <doc> <heading> <script>: the checks a section of prose names against the ones a script runs,
# in both directions, so neither a check dropped from the section nor one wired into the script
# and left out of it passes.
section_verdict() {
  local doc="$1" heading="$2" script="$3"
  local real named n failed=0
  [ -r "$doc" ] || { echo "check-list: cannot read $doc" >&2; return 1; }
  real="$(extract "$script" real)" || return 1
  named="$(section_names "$doc" "$heading")" || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s\n' "$named" | grep -qxF -- "$n" \
      || { echo "check-list: $doc: the \"$heading\" section does not name scripts/$n.sh, which $script runs" >&2; failed=1; }
  done <<< "$real"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s\n' "$real" | grep -qxF -- "$n" \
      || { echo "check-list: $doc: the \"$heading\" section names scripts/$n.sh, which $script does not run" >&2; failed=1; }
  done <<< "$named"
  [ "$failed" = 0 ] || { echo "check-list: $doc's \"$heading\" section and $script do not name the same checks" >&2; return 1; }
  echo "check-list: $doc's \"$heading\" section names the same checks $script runs"
}

self_test() {
  # A plain global, not a `local`: the trap that cleans it up runs at exit, when a local would
  # already be out of scope and `set -u` would turn the cleanup into an error.
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-list.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR" me="$SCRIPT_ROOT/scripts/check-list.sh" out rc
  # Two blocks written the way the real pair is: a different loop variable, the guard a project's
  # copy carries, a different marker text, and a kit-only line outside the markers. They agree.
  cat > "$dir/kit.sh" <<'EOF'
#!/usr/bin/env bash
# >>> loop checks: shared with templates/check/common.sh
for script in loop-config backlog-status decisions; do
  "scripts/$script.sh" --self-test
done
scripts/prompt-check.sh
scripts/decisions.sh --check
# <<< loop checks
./install.sh --self-test
EOF
  cat > "$dir/project.sh" <<'EOF'
#!/usr/bin/env bash
loop_checks() {
  # >>> loop checks: shared with check.sh
  for s in loop-config backlog-status decisions; do
    [ -x "scripts/$s.sh" ] && "scripts/$s.sh" --self-test   # guarded here, bare in the kit
  done
  # A comment only this block carries: free text, so it does not fail the comparison.
  scripts/prompt-check.sh
  scripts/decisions.sh --check
  # <<< loop checks
  scripts/proof-gate.sh
}
EOF
  out="$("$me" "$dir/kit.sh" "$dir/project.sh")" || { echo "self-test: equal blocks should pass:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'the marked block runs the same 2 file' || { echo "self-test: the pass line should count the files compared:"; echo "$out"; exit 1; }
  # A check dropped from the project's block fails, naming the check and the file that lost it.
  perl -ni -e 'print unless /scripts\/decisions\.sh --check/' "$dir/project.sh"
  rc=0; out="$("$me" "$dir/kit.sh" "$dir/project.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'the check "decisions --check" is run by .*kit\.sh but not by .*project\.sh' \
    || { echo "self-test: a check dropped from one block should fail naming it (rc $rc):"; echo "$out"; exit 1; }
  # The same in the other direction, so neither file is privileged.
  perl -ni -e 'print unless /scripts\/prompt-check\.sh/' "$dir/kit.sh"
  rc=0; out="$("$me" "$dir/kit.sh" "$dir/project.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'the check "prompt-check" is run by .*project\.sh but not by .*kit\.sh' \
    || { echo "self-test: a check dropped from the other block should fail naming it (rc $rc):"; echo "$out"; exit 1; }
  # A check added to one block only is a difference too, not just a removal. It goes just above the
  # closing marker, inside the block.
  perl -ni -e 'print "scripts/coverage-ratchet.sh\n" if /<<< loop checks/; print' "$dir/project.sh"
  rc=0; out="$("$me" "$dir/kit.sh" "$dir/project.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'the check "coverage-ratchet" is run by .*project\.sh but not by .*kit\.sh' \
    || { echo "self-test: a check added to one block should fail naming it (rc $rc):"; echo "$out"; exit 1; }
  # A file with no markers, and a file that is not there, each fail with their own message.
  echo 'set -e' > "$dir/nomarkers.sh"
  rc=0; out="$("$me" "$dir/kit.sh" "$dir/nomarkers.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'nomarkers.sh has no "# >>> loop checks" block' \
    || { echo "self-test: a file with no block should fail saying so (rc $rc):"; echo "$out"; exit 1; }
  rc=0; out="$("$me" "$dir/kit.sh" "$dir/absent.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'cannot read .*absent\.sh' \
    || { echo "self-test: a file that is not there should fail saying so (rc $rc):"; echo "$out"; exit 1; }
  # One file is nothing to compare.
  rc=0; out="$("$me" "$dir/kit.sh" 2>&1)" || rc=$?
  [ "$rc" = 2 ] && echo "$out" | grep -q 'usage:' \
    || { echo "self-test: one file should be a usage error (rc $rc):"; echo "$out"; exit 1; }

  # A prose section against the script it describes (LK-16). The section names the checks the
  # script runs as work of its own; the `--self-test` sweep is stated in prose and is not a check
  # to name, and a mention in a neighbouring section does not count as naming one.
  cat > "$dir/section-check.sh" <<'EOF'
#!/usr/bin/env bash
for s in loop-config decisions prompt-check; do
  "scripts/$s.sh" --self-test
done
scripts/prompt-check.sh
scripts/decisions.sh --check
./install.sh --self-test
EOF
  cat > "$dir/section.md" <<'EOF'
# Title

## A section that is not the one

`scripts/coverage-ratchet.sh` is mentioned here and must not count.

### The check

`./check.sh` runs the `--self-test` of every script, then `scripts/prompt-check.sh`, then
`scripts/decisions.sh --check`, then `./install.sh --self-test`.

### Conventions

`scripts/ruleset-check.sh` is mentioned here and must not count either.
EOF
  out="$("$me" --section "$dir/section.md" "The check" "$dir/section-check.sh")" \
    || { echo "self-test: a section naming the checks the script runs should pass:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'section names the same checks' \
    || { echo "self-test: the pass line should say the section names the same checks:"; echo "$out"; exit 1; }
  cp "$dir/section.md" "$dir/section-full.md"
  # A check the section names that the script does not run fails, naming it. The mention goes
  # just above the next heading, inside the section.
  perl -pe 'print "`scripts/coverage-ratchet.sh` is named inside the section.\n" if /^### Conventions$/' \
    "$dir/section-full.md" > "$dir/section-extra.md"
  rc=0; out="$("$me" --section "$dir/section-extra.md" "The check" "$dir/section-check.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'names scripts/coverage-ratchet\.sh, which .*section-check\.sh does not run' \
    || { echo "self-test: a check the script does not run should fail naming it (rc $rc):"; echo "$out"; exit 1; }
  # A check dropped from the section fails, naming it and the script.
  perl -ni -e 'print unless /decisions\.sh --check/' "$dir/section.md"
  rc=0; out="$("$me" --section "$dir/section.md" "The check" "$dir/section-check.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'does not name scripts/decisions\.sh, which .*section-check\.sh runs' \
    || { echo "self-test: a check dropped from the section should fail naming it (rc $rc):"; echo "$out"; exit 1; }
  # The same from the script's side, and its `--self-test` still being in the loop must not hide
  # it: that is the shape LK-05 had, a check described in prose and no longer wired in.
  perl -ni -e 'print unless /scripts\/decisions\.sh --check/' "$dir/section-check.sh"
  rc=0; out="$("$me" --section "$dir/section-full.md" "The check" "$dir/section-check.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'names scripts/decisions\.sh, which .*section-check\.sh does not run' \
    || { echo "self-test: a check the script stopped running should fail naming it (rc $rc):"; echo "$out"; exit 1; }
  # A section that is not there fails saying so, and so does a missing file.
  rc=0; out="$("$me" --section "$dir/section-full.md" "No such heading" "$dir/section-check.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'has no "No such heading" section' \
    || { echo "self-test: an absent section should fail saying so (rc $rc):"; echo "$out"; exit 1; }
  rc=0; out="$("$me" --section "$dir/absent.md" "The check" "$dir/section-check.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'cannot read .*absent\.md' \
    || { echo "self-test: a doc that is not there should fail saying so (rc $rc):"; echo "$out"; exit 1; }
  # --section takes a doc, a heading and a script; fewer is a usage error.
  rc=0; out="$("$me" --section "$dir/section-full.md" "The check" 2>&1)" || rc=$?
  [ "$rc" = 2 ] && echo "$out" | grep -q 'usage:' \
    || { echo "self-test: --section without a script should be a usage error (rc $rc):"; echo "$out"; exit 1; }
  echo "check-list self-test passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  --section)
    [ $# -eq 4 ] || { echo "usage: scripts/check-list.sh --section <doc> <heading> <script> | <file> [<file> ...] | --self-test" >&2; exit 2; }
    section_verdict "$2" "$3" "$4" ;;
  *) [ $# -ge 2 ] || { echo "usage: scripts/check-list.sh <file> [<file> ...] | --section <doc> <heading> <script> | --self-test" >&2; exit 2; }
     compare "$@" ;;
esac
