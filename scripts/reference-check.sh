#!/usr/bin/env bash
# The queue's own integrity, read from Beads (0012): every ticket carries acceptance criteria,
# every `blocks` dependency resolves to a ticket, no dependency cycle, every `story:<ID>` label
# resolves to a story in the product backlog, and every decision a ticket or a story cites is a
# record here.
#
# Nothing else checks these. `scripts/decisions.sh --check` reads the records and their index;
# `scripts/backlog-status.sh` derives a state from git and happily prints a ticket whose
# dependency is a typo. So a dependency written `LK-3` instead of `LK-03`, a story a ticket
# serves that no heading defines, or a decision cited by a number no record carries is found by a
# person reading, or not at all.
#
# A ticket description may quote another project's ids in prose - `HK-27`, `BT-1207` - and those
# are left alone: only the structured references (a `blocks` dependency, a `story:<ID>` label, a
# `Decisions:` clause) have to resolve.
#
#   scripts/reference-check.sh              the queue's references; exit 1 naming what is wrong
#   scripts/reference-check.sh --self-test  a stub bd and fixtures prove each fault alone
#
# Settings come from .loop.toml through scripts/loop-config.sh: `stories`, `decisions`. Needs
# `bd` with this repository's database.
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

# The references in one Beads queue and the stories it serves, named by file and line.
references() {
  local bdjson="$1" stories="$2" decisions="$3" bderror="$4"
  perl - "$bdjson" "$stories" "$decisions" "$bderror" <<'PERL'
use strict;
use warnings;
use JSON::PP;

my ($bdjson, $stories, $decisions, $bderror) = @ARGV;
my $EM = "\x{2014}";
my @problems;

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

sub slurp {
  my $path = shift;
  open my $fh, "<", $path or die "reference-check: cannot read $path: $!\n";
  local $/;
  my $text = <$fh>;
  close $fh;
  return $text;
}

# The stories file is UTF-8 with an em dash in its headings, so it is read as characters.
sub slurp_text {
  my $path = shift;
  open my $fh, "<:encoding(UTF-8)", $path or die "reference-check: cannot read $path: $!\n";
  local $/;
  my $text = <$fh>;
  close $fh;
  return $text;
}

my $raw = slurp($bdjson);
my $rows = eval { JSON::PP->new->utf8->decode($raw) };
if (!defined $rows || ref $rows ne "ARRAY") {
  print STDERR "reference-check: the Beads queue did not answer --json with an array";
  print STDERR " ($bderror)" if $bderror ne "" && -s $bderror;
  print STDERR "\n";
  exit 1;
}

# Tickets: every id of the loop's shape that is not an epic, milestone or decision.
my (%ticket, @tickets);
for my $r (@$rows) {
  my $id = $r->{id} // "";
  next unless $id =~ /^[A-Z][A-Z0-9]*-[a-z0-9]+$/;
  next if ($r->{issue_type} // "") =~ /^(epic|milestone|decision)$/;
  my @deps;
  for my $d (@{ $r->{dependencies} // [] }) {
    next unless defined $d->{depends_on_id} && defined $d->{type} && $d->{type} eq "blocks";
    push @deps, $d->{depends_on_id};
  }
  my @stories;
  for my $l (@{ $r->{labels} // [] }) { push @stories, $1 if $l =~ /^story:(.*)$/; }
  my $ac = $r->{acceptance_criteria} // "";
  $ac =~ s/^\s+|\s+$//g;
  $ticket{$id} = { deps => \@deps, stories => \@stories, acceptance => $ac,
                   description => $r->{description} // "" };
  push @tickets, $id;
}

for my $id (@tickets) {
  push @problems, "$id carries no acceptance criteria" if $ticket{$id}{acceptance} eq "";
  for my $dep (@{ $ticket{$id}{deps} }) {
    next if exists $ticket{$dep};
    push @problems, "$id is blocked by $dep, which is not a ticket in the queue";
  }
}

# A ticket that waits, directly or through others, on itself never becomes ready.
{
  my %state;
  my $visit;
  $visit = sub {
    my ($id) = @_;
    return if ($state{$id} // 0) == 2;
    if (($state{$id} // 0) == 1) { push @problems, "cyclic dependency at $id"; return; }
    $state{$id} = 1;
    for my $dep (@{ $ticket{$id}{deps} }) { $visit->($dep) if exists $ticket{$dep}; }
    $state{$id} = 2;
  };
  $visit->($_) for @tickets;
}

# A story is `### <ID> - <title>`, the em dash the product backlog uses.
my (@stories, %story);
if ($stories ne "" && -f $stories) {
  my @lines = split /\n/, slurp_text($stories), -1;
  for (my $i = 0; $i <= $#lines; $i++) {
    next unless $lines[$i] =~ /^###\s+([A-Z][A-Z0-9]*-[0-9]+)\s+\Q$EM\E\s+\S/;
    my $id = $1;
    if ($story{$id}++) { push @problems, "$stories:" . ($i + 1) . ": duplicate story id $id"; next; }
    push @stories, $id;
  }
  push @problems, "$stories: no product stories found" unless @stories;
}
for my $id (@tickets) {
  for my $s (@{ $ticket{$id}{stories} }) {
    next if $story{$s};
    push @problems, "$id serves story $s, which is not in the product backlog";
  }
}

# The decision records a `Decisions: ...` clause cites. A record is `<NNNN>-<slug>.md`.
my %record;
if ($decisions ne "" && -d $decisions) {
  opendir(my $dir, $decisions) or die "reference-check: cannot read $decisions: $!\n";
  for my $entry (readdir $dir) { $record{$1} = 1 if $entry =~ /^(\d{4})-/; }
  closedir $dir;
}
my @sources = (@tickets ? (map { ["ticket $ticket{$_}{description}", $_] } @tickets) : ());
my $cite = sub {
  my ($where, $text) = @_;
  while ($text =~ /Decisions:\s*([0-9][0-9\s,\/\x{2013}\x{2014}-]*)/g) {
    my $clause = $1;
    $clause =~ s/\s+$//;
    for my $part (split /,/, $clause) {
      $part =~ s/^\s+//; $part =~ s/\s+$//;
      next unless length $part;
      my @cited;
      if ($part =~ /^(\d{4})\s*[\x{2013}\x{2014}\/-]\s*(\d{4})$/) { @cited = map { sprintf("%04d", $_) } ($1 .. $2); }
      elsif ($part =~ /^(\d{4})$/) { @cited = ($1); }
      else { push @problems, "$where: cannot read the decision citation \"$part\""; next; }
      for my $num (@cited) {
        push @problems, "$where: decision $num is cited and no record carries it" unless $record{$num};
      }
    }
  }
};
for my $id (@tickets) { $cite->("ticket $id", $ticket{$id}{description}); }
if ($stories ne "" && -f $stories) { $cite->($stories, slurp_text($stories)); }

if (@problems) {
  print STDERR "reference-check: $_\n" for @problems;
  exit 1;
}
printf "reference-check: %d ticket(s), %d story(s), %d decision record(s); every dependency defined, every ticket proved, no cycles, every story and decision cited defined\n",
  scalar(@tickets), scalar(@stories), scalar(keys %record);
PERL
}

check() {
  local stories decisions bdjson bderror
  stories="$("$CONFIG" stories)"
  decisions="$("$CONFIG" decisions)"
  command -v bd >/dev/null || { echo "reference-check: bd is required" >&2; return 1; }
  bdjson="$(mktemp "${TMPDIR:-/tmp}/reference-bd.XXXXXX")"
  bderror="$(mktemp "${TMPDIR:-/tmp}/reference-bd-err.XXXXXX")"
  trap 'rm -f "${bdjson:-}" "${bderror:-}"' EXIT
  if ! ( cd "$ROOT" && bd list --all --json -n 0 ) >"$bdjson" 2>"$bderror"; then
    printf 'reference-check: no Beads queue could be read from %s\n' "$ROOT" >&2
    sed 's/^/  /' "$bderror" >&2 || true
    rm -f "$bdjson" "$bderror"
    return 1
  fi
  local stories_path=""
  [ -n "$stories" ] && [ -f "$ROOT/$stories" ] && stories_path="$ROOT/$stories"
  references "$bdjson" "$stories_path" "$ROOT/$decisions" "$bderror"
  rm -f "$bdjson" "$bderror"
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reference-check.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR/work" me="$SCRIPT_ROOT/scripts/reference-check.sh" out rc failed=0
  mkdir -p "$dir/bin"
  cat > "$dir/bin/bd" <<'EOF'
#!/usr/bin/env bash
cat "$BD_QUEUE_JSON"
EOF
  chmod +x "$dir/bin/bd"

  # A queue with two tickets, a dependency, a story served, and a cited record.
  good() {
    rm -rf "$dir/docs"; mkdir -p "$dir/docs/decisions"
    printf '[loop]\nstories = "docs/PRODUCT_BACKLOG.md"\ndecisions = "docs/decisions"\n' > "$dir/.loop.toml"
    cat > "$dir/queue.json" <<'JSON'
[
 {"id":"AA-01","title":"The first ticket","description":"It does the first thing. Decisions: 0001.","acceptance_criteria":"a fixture proves it","status":"closed","issue_type":"task","labels":["story:SS-01"],"dependencies":[]},
 {"id":"AA-02","title":"The second ticket","description":"It does the next thing.","acceptance_criteria":"another fixture proves it","status":"open","issue_type":"task","labels":[],"dependencies":[{"issue_id":"AA-02","depends_on_id":"AA-01","type":"blocks"}]},
 {"id":"AA-1a","title":"The generated-id ticket","description":"Beads minted this id.","acceptance_criteria":"the generated id is read","status":"open","issue_type":"task","labels":[],"dependencies":[]}
]
JSON
    cat > "$dir/docs/PRODUCT_BACKLOG.md" <<'EOF'
# Product backlog

### SS-01 — The first story
**Status:** Proposed
**Acceptance criteria:** it works.
EOF
    printf '# 0001 - the first decision\n' > "$dir/docs/decisions/0001-the-first-decision.md"
  }
  export PATH="$dir/bin:$PATH" LOOP_ROOT="$dir" BD_QUEUE_JSON="$dir/queue.json"

  good
  out="$("$me")" || { echo "self-test: a clean queue should pass:"; echo "$out"; exit 1; }
    printf '%s\n' "$out" | grep -q '^reference-check: 3 ticket(s), 1 story(s), 1 decision record(s)' \
    || { echo "self-test: the pass line should count what it read:"; echo "$out"; exit 1; }

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

  assert_names "missing acceptance" "AA-02 carries no acceptance criteria" \
    "perl -pi -e 's/\"another fixture proves it\"/\"\"/' \"\$dir/queue.json\"" || failed=1
  # A Beads-generated id is a ticket too: before the shape was widened this fault was invisible,
  # because the row never reached the acceptance-criteria check at all.
  assert_names "generated id missing acceptance" "AA-1a carries no acceptance criteria" \
    "perl -pi -e 's/\"the generated id is read\"/\"\"/' \"\$dir/queue.json\"" || failed=1
  assert_names "unknown dependency" "AA-02 is blocked by AA-09, which is not a ticket in the queue" \
    "perl -pi -e 's/depends_on_id\":\"AA-01/depends_on_id\":\"AA-09/' \"\$dir/queue.json\"" || failed=1
  assert_names "cycle" "cyclic dependency at AA-01" \
    "perl -pi -e 's/\"dependencies\":\\[\\]/\"dependencies\":[{\"issue_id\":\"AA-01\",\"depends_on_id\":\"AA-02\",\"type\":\"blocks\"}]/' \"\$dir/queue.json\"" || failed=1
  assert_names "unknown story" "AA-01 serves story SS-09, which is not in the product backlog" \
    "perl -pi -e 's/story:SS-01/story:SS-09/' \"\$dir/queue.json\"" || failed=1
  assert_names "missing decision" "ticket AA-01: decision 0009 is cited and no record carries it" \
    "perl -pi -e 's/Decisions: 0001/Decisions: 0009/' \"\$dir/queue.json\"" || failed=1
  assert_names "missing decision in a range" "ticket AA-01: decision 0003 is cited and no record carries it" \
    "perl -pi -e 's/Decisions: 0001/Decisions: 0001-0003/' \"\$dir/queue.json\"" || failed=1
  assert_names "no stories" "no product stories found" \
    "printf '# Product backlog\n\nNothing yet.\n' > \"\$dir/docs/PRODUCT_BACKLOG.md\"" || failed=1

  # Another project's ids in a ticket description are prose, not references.
  good
  perl -pi -e 's/It does the next thing./Copied from HK-27, which lives elsewhere./' "$dir/queue.json"
  out="$("$me")" || { echo "self-test: a quoted foreign id should not fail:"; echo "$out"; exit 1; }
  [ "$failed" = 0 ] || exit 1

  unset LOOP_ROOT BD_QUEUE_JSON
  echo "reference-check self-test passed"
}

case "$MODE" in
  selftest) self_test ;;
  check) check ;;
esac
