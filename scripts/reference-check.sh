#!/usr/bin/env bash
# The queue's own integrity: the ids it names exist, every ticket says how it is proved, no
# ticket waits on itself, and every decision a ticket or a story cites is a record here.
#
# Nothing else checks these. `scripts/decisions.sh --check` reads the records and their index;
# `scripts/backlog-status.sh` derives a state from git and happily prints a ticket whose
# dependency is a typo. So a dependency written `LK-3` instead of `LK-03`, a story a ticket
# serves that no heading defines, or a decision cited by a number no record carries is found by
# a person reading, or not at all - and every project has written the same few dozen lines to
# catch it by hand. rockbox-ghl's are the shape this is taken from.
#
# The check is scoped to the project's own id spaces: the prefixes its headings already use. A
# ticket may quote another project's ids in its intent - `HK-27`, `BT-1207` - and those are
# prose here, not references, so only an id whose prefix has a heading here has to be defined.
#
#   scripts/reference-check.sh              the queue's references; exit 1 naming what is wrong
#   scripts/reference-check.sh --self-test  fixtures prove each fault alone
#
# Settings come from .loop.toml through scripts/loop-config.sh: `backlog`, `stories`,
# `decisions`. A project that keeps no backlog yet is skipped, not failed. Needs perl.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
CONFIG="$SCRIPT_ROOT/scripts/loop-config.sh"
MODE=check
case "${1:-}" in
  "") ;;
  --self-test) MODE=selftest ;;
  *) echo "usage: scripts/reference-check.sh | --self-test" >&2; exit 2 ;;
esac

# The references in one backlog and the stories it serves, named by file and line.
references() {
  local backlog="$1" stories="$2" decisions="$3"
  perl - "$backlog" "$stories" "$decisions" <<'PERL'
use strict;
use warnings;

my ($backlog, $stories, $decisions) = @ARGV;
my $EM = "\x{2014}";
my @problems;

# The files are UTF-8 (an em dash is part of the heading the loop writes), so they are read as
# characters: matching the three bytes of an em dash against one character would find nothing.
binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

sub slurp {
  my $path = shift;
  open my $fh, "<:encoding(UTF-8)", $path or die "reference-check: cannot read $path: $!\n";
  local $/;
  my $text = <$fh>;
  close $fh;
  return $text;
}

# A heading is `### <ID> <title>`; its block runs to the next heading at the same level or
# higher. The tail may carry the dependency list the loop reads: `- Blocked by AA-01, AA-02`.
my (%ticket, @tickets);
{
  my @lines = split /\n/, slurp($backlog), -1;
  my ($current, $line);
  for (my $i = 0; $i <= $#lines; $i++) {
    $line = $lines[$i];
    if ($line =~ /^###\s+([A-Z][A-Z0-9]*-[0-9]+)\s+(\S.*)$/) {
      my ($id, $rest) = ($1, $2);
      if (exists $ticket{$id}) {
        push @problems, "$backlog:" . ($i + 1) . ": duplicate ticket id $id";
        $current = undef;
        next;
      }
      $ticket{$id} = { deps => [], proof => 0 };
      push @tickets, $id;
      $current = $id;
      if ($rest =~ /Blocked by\s+([A-Z][A-Z0-9]*-[0-9]+(?:\s*,\s*[A-Z][A-Z0-9]*-[0-9]+)*)/) {
        my @deps = $1 =~ /([A-Z][A-Z0-9]*-[0-9]+)/g;
        $ticket{$id}{deps} = \@deps;
      }
      next;
    }
    if ($line =~ /^##\s/) { $current = undef; next; }
    next unless defined $current;
    $ticket{$current}{proof} = 1 if $line =~ /^\*\*Done when:\*\*/;
  }
}

for my $id (@tickets) {
  push @problems, "$backlog: $id has no **Done when:** line" unless $ticket{$id}{proof};
  for my $dep (@{ $ticket{$id}{deps} }) {
    next if exists $ticket{$dep};
    push @problems, "$backlog: $id is blocked by $dep, which is not a ticket here";
  }
}

# A ticket that waits, directly or through others, on itself never becomes ready, and --next
# walks it forever rather than reporting the fault.
{
  my %state;
  my $visit;
  $visit = sub {
    my ($id) = @_;
    return if ($state{$id} // 0) == 2;
    if (($state{$id} // 0) == 1) { push @problems, "$backlog: cyclic dependency at $id"; return; }
    $state{$id} = 1;
    for my $dep (@{ $ticket{$id}{deps} }) { $visit->($dep) if exists $ticket{$dep}; }
    $state{$id} = 2;
  };
  $visit->($_) for @tickets;
}

# A story is `### <ID> - <title>`, the em dash the queue's own stories use.
my @stories;
if ($stories ne "") {
  my @lines = split /\n/, slurp($stories), -1;
  for (my $i = 0; $i <= $#lines; $i++) {
    next unless $lines[$i] =~ /^###\s+([A-Z][A-Z0-9]*-[0-9]+)\s+\Q$EM\E\s+\S/;
    my $id = $1;
    if (grep { $_ eq $id } @stories) {
      push @problems, "$stories:" . ($i + 1) . ": duplicate story id $id";
      next;
    }
    push @stories, $id;
  }
  push @problems, "$stories: no product stories found" unless @stories;
}

# Every id in one of this project's own id spaces has to be defined by a heading. The spaces
# come from the headings, so a quoted id from another project is prose and is left alone.
my %known = map { $_ => 1 } (@tickets, @stories);
my %prefix;
for my $id (keys %known) { $prefix{$1} = 1 if $id =~ /^([A-Z][A-Z0-9]*)-\d+$/; }
for my $file ($backlog, ($stories ne "" ? ($stories) : ())) {
  my @lines = split /\n/, slurp($file), -1;
  for (my $i = 0; $i <= $#lines; $i++) {
    my %seen;
    while ($lines[$i] =~ /\b([A-Z][A-Z0-9]*-[0-9]+)\b/g) {
      my ($id, $pre) = ($1, $1);
      $pre =~ s/-\d+$//;
      next unless $prefix{$pre};
      next if $known{$id} || $seen{$id}++;
      push @problems, "$file:" . ($i + 1) . ": $id is not a ticket or a story here";
    }
  }
}

# The decision records a `Decisions: ...` clause cites. A record is `<NNNN>-<slug>.md`.
my %record;
if ($decisions ne "" && -d $decisions) {
  opendir(my $dir, $decisions) or die "reference-check: cannot read $decisions: $!\n";
  for my $entry (readdir $dir) { $record{$1} = 1 if $entry =~ /^(\d{4})-/; }
  closedir $dir;
}
for my $file ($backlog, ($stories ne "" ? ($stories) : ())) {
  my @lines = split /\n/, slurp($file), -1;
  for (my $i = 0; $i <= $#lines; $i++) {
    while ($lines[$i] =~ /Decisions:\s*([0-9][0-9\s,\/\x{2013}\x{2014}-]*)/g) {
      my $clause = $1;
      $clause =~ s/\s+$//;
      for my $part (split /,/, $clause) {
        $part =~ s/^\s+//; $part =~ s/\s+$//;
        next unless length $part;
        my @cited;
        if ($part =~ /^(\d{4})\s*[\x{2013}\x{2014}\/-]\s*(\d{4})$/) {
          @cited = map { sprintf("%04d", $_) } ($1 .. $2);
        } elsif ($part =~ /^(\d{4})$/) {
          @cited = ($1);
        } else {
          push @problems, "$file:" . ($i + 1) . ": cannot read the decision citation \"$part\"";
          next;
        }
        for my $num (@cited) {
          push @problems, "$file:" . ($i + 1) . ": decision $num is cited and no record carries it"
            unless $record{$num};
        }
      }
    }
  }
}

if (@problems) {
  print STDERR "reference-check: $_\n" for @problems;
  exit 1;
}
printf "reference-check: %d ticket(s), %d story(s), %d decision record(s); every id defined, every ticket proved, no cycles\n",
  scalar(@tickets), scalar(@stories), scalar(keys %record);
PERL
}

check() {
  local backlog stories decisions path stories_path
  backlog="$("$CONFIG" backlog)"
  stories="$("$CONFIG" stories)"
  decisions="$("$CONFIG" decisions)"
  path="$ROOT/$backlog"
  if [ ! -f "$path" ]; then
    echo "reference-check: no ticket file at $backlog; nothing to check"
    return 0
  fi
  stories_path=""
  if [ -n "$stories" ]; then
    if [ -f "$ROOT/$stories" ]; then
      stories_path="$ROOT/$stories"
    else
      echo "reference-check: no product backlog at $stories; its references are not checked" >&2
    fi
  fi
  references "$path" "$stories_path" "$ROOT/$decisions"
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reference-check.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR/work" me="$SCRIPT_ROOT/scripts/reference-check.sh" out rc failed=0

  # A queue with one story, two tickets, a dependency, a served story, and a cited record.
  good() {
    rm -rf "$dir"; mkdir -p "$dir/docs/decisions"
    printf '[loop]\nbacklog = "BACKLOG.md"\nstories = "docs/PRODUCT_BACKLOG.md"\ndecisions = "docs/decisions"\n' > "$dir/.loop.toml"
    cat > "$dir/BACKLOG.md" <<'EOF'
# Work queue

## The loop's scripts

### AA-01 The first ticket
It does the first thing. Serves SS-01. Decisions: 0001.
**Done when:** a fixture proves it.

### AA-02 The second ticket — Blocked by AA-01
It does the next thing.
**Done when:** another fixture proves it.
EOF
    cat > "$dir/docs/PRODUCT_BACKLOG.md" <<'EOF'
# Product backlog

### SS-01 — The first story
**Status:** Proposed
**Acceptance criteria:** it works.
EOF
    printf '# 0001 - the first decision\n' > "$dir/docs/decisions/0001-the-first-decision.md"
  }
  export LOOP_ROOT="$dir"

  # The clean queue passes and says what it read.
  good
  out="$("$me")" || { echo "self-test: a clean queue should pass:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q '^reference-check: 2 ticket(s), 1 story(s), 1 decision record(s)' \
    || { echo "self-test: the pass line should count what it read:"; echo "$out"; exit 1; }

  # assert_names <label> <expected fragment> <edit> -- the edit breaks the clean queue and the
  # check fails naming it, so each fault is found on its own evidence.
  assert_names() {
    local label="$1" want="$2" edit="$3"
    good
    eval "$edit"
    rc=0; out="$("$me" 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then echo "self-test[$label]: the check should fail:"; echo "$out"; return 1; fi
    printf '%s\n' "$out" | grep -qF -- "$want" \
      || { echo "self-test[$label]: should name \"$want\":"; echo "$out"; return 1; }
    return 0
  }

  assert_names "missing proof" "AA-02 has no **Done when:** line" \
    "perl -ni -e 'print unless /^\*\*Done when:\*\* another fixture/' \"\$dir/BACKLOG.md\"" || failed=1
  assert_names "unknown dependency" "AA-02 is blocked by AA-09, which is not a ticket here" \
    "perl -pi -e 's/Blocked by AA-01/Blocked by AA-09/' \"\$dir/BACKLOG.md\"" || failed=1
  assert_names "cycle" "cyclic dependency at AA-01" \
    "perl -pi -e 's/^### AA-01 The first ticket\$/### AA-01 The first ticket — Blocked by AA-02/' \"\$dir/BACKLOG.md\"" || failed=1
  assert_names "duplicate id" "duplicate ticket id AA-01" \
    "printf '\n### AA-01 The same ticket again\nIntent.\n**Done when:** x.\n' >> \"\$dir/BACKLOG.md\"" || failed=1
  assert_names "unknown story" "SS-09 is not a ticket or a story here" \
    "perl -pi -e 's/Serves SS-01/Serves SS-09/' \"\$dir/BACKLOG.md\"" || failed=1
  assert_names "undefined ticket in a story" "AA-09 is not a ticket or a story here" \
    "printf '\nIt serves AA-09.\n' >> \"\$dir/docs/PRODUCT_BACKLOG.md\"" || failed=1
  assert_names "missing decision" "decision 0009 is cited and no record carries it" \
    "perl -pi -e 's/Decisions: 0001/Decisions: 0009/' \"\$dir/BACKLOG.md\"" || failed=1
  assert_names "missing decision in a range" "decision 0003 is cited and no record carries it" \
    "perl -pi -e 's/Decisions: 0001/Decisions: 0001-0003/' \"\$dir/BACKLOG.md\"" || failed=1
  assert_names "no stories" "no product stories found" \
    "printf '# Product backlog\n\nNothing yet.\n' > \"\$dir/docs/PRODUCT_BACKLOG.md\"" || failed=1

  # Another project's ids are prose, not references: the prefixes come from this queue's own
  # headings, so a quoted HK-27 in a ticket body is not a fault.
  good
  printf '\nCopied from HK-27, which lives elsewhere.\n' >> "$dir/BACKLOG.md"
  out="$("$me")" || { echo "self-test: a quoted foreign id should not fail:"; echo "$out"; exit 1; }

  # No backlog at all is the fresh checkout, which is skipped rather than failed.
  good
  rm "$dir/BACKLOG.md"
  out="$("$me")" || { echo "self-test: a missing backlog should be skipped, not failed:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q 'no ticket file at BACKLOG.md; nothing to check' \
    || { echo "self-test: the skip should say what is missing:"; echo "$out"; exit 1; }
  [ "$failed" = 0 ] || exit 1

  unset LOOP_ROOT
  echo "reference-check self-test passed"
}

case "$MODE" in
  selftest) self_test ;;
  check) check ;;
esac
