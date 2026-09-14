#!/usr/bin/env bash
# The loop's own checks are written down twice: the kit's check.sh runs them, and so does the
# loop_checks a project sources from loop/templates/check/common.sh. Nothing compared the two
# lists, so the only thing keeping them equal was that someone remembered - and they had already
# drifted once: the kit's check ran no `decisions.sh --check` while every project's did (LK-05).
# A check line that is missing looks exactly like a check line that passed.
#
# Each file keeps its loop checks between two markers, and this script compares the checks in the
# marked blocks, so a check added to one and not the other fails the check naming it (LK-14). The
# comparison is over the checks themselves - the script each line runs and the flags it runs it
# with - so the two blocks may differ in how they are written: the loop variable's name, the
# `[ -x ... ]` guard a project's copy carries, the marker's own free text. Only the marked block
# is compared: a check that is deliberately one-sided - the kit's `./install.sh --self-test`, a
# project's proof gate - lives outside the markers.
#
#   scripts/check-list.sh <file> [<file> ...]   compare the marked blocks; exit 1 on any difference
#   scripts/check-list.sh --self-test           a check dropped from one block fails, naming it;
#                                               equal blocks pass
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The marker words. A marker is a comment line containing the arrows; the rest of the line is free
# text, so the two files may name each other there.
OPEN='>>> loop checks'
CLOSE='<<< loop checks'

# <file>: the checks in its marked block, one per line as `<script> <flags>`, sorted. A `for <var>
# in <names>; do` header contributes each name with the flags its body runs it with, so the block
# can be a loop in one file and written out in the other.
extract() {
  local file="$1" out rc=0
  [ -r "$file" ] || { echo "check-list: cannot read $file" >&2; return 1; }
  out="$(perl -e '
    my ($file, $open, $close) = @ARGV;
    open my $fh, "<", $file or exit 2;
    my ($in, $seen, @lines) = (0, 0);
    while (my $line = <$fh>) {
      if ($line =~ /^\s*#\s*\Q$open\E/) { $in = 1; $seen = 1; next }
      if ($line =~ /^\s*#\s*\Q$close\E/) { $in = 0; next }
      next unless $in;
      # Comments inside the block are free text, so the two blocks may explain themselves
      # differently - or in one file only - without failing the comparison.
      next if $line =~ /^\s*#/;
      $line =~ s/\s+#.*//;
      push @lines, $line;
    }
    exit 3 unless $seen;
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
    my %tok;
    while ($text =~ /(?:^|[;&|]|do\b|then\b)\s*"?scripts\/([A-Za-z0-9._%+-]+)\.sh"?([^\n;&|]*)/mg) {
      my ($name, $flags) = ($1, $2);
      $flags =~ s/^\s+//; $flags =~ s/\s+$//; $flags =~ s/["\x27]//g;
      my @names = $name =~ /^%(\w+)%$/ ? @{ $loops{$1} || [] } : ($name);
      $tok{ length $flags ? "$_ $flags" : $_ }++ for @names;
    }
    print "$_\n" for sort keys %tok;
  ' "$file" "$OPEN" "$CLOSE")" || rc=$?
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
  echo "check-list self-test passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  *) [ $# -ge 2 ] || { echo "usage: scripts/check-list.sh <file> [<file> ...] | --self-test" >&2; exit 2; }
     compare "$@" ;;
esac
