#!/usr/bin/env bash
# Release notes from commits, and a changelog archive (HK-06). A commit whose subject starts with
# a ticket id (`LK-02: ...`) is that ticket shipping; the notes are those commits between two refs,
# grouped by the ticket's `section:` label, with the ticket's text read from Beads. `--archive`
# writes the release into CHANGELOG.md and closes each shipped ticket in Beads (0012): the
# changelog is the human record, Beads carries the state, and git stays the proof.
#
#   scripts/release-notes.sh <from-ref> [<to-ref>]     Markdown notes for from..to (to: the
#                                                      default branch from .loop.toml)
#   scripts/release-notes.sh --archive <tag> <from> [<to>]
#                                                      the notes, plus a `## <tag>` entry in
#                                                      CHANGELOG.md (newest first) and a
#                                                      `bd close` for every shipped ticket still
#                                                      open in Beads
#   --changelog <file>                                 another changelog (default: the repo's)
#   --prefix <P>                                       only the tickets whose id carries that
#                                                      prefix (repeatable, or comma-separated);
#                                                      it filters the notes and the archive alike.
#                                                      When nothing matches, nothing is written and
#                                                      the exit status is still 0. A --prefix that
#                                                      names no prefix at all is refused, since
#                                                      read as "no filter" it would archive every
#                                                      prefix's tickets.
#   --self-test                                        a fixture repo and a stub bd prove both modes
#
# Settings come from .loop.toml through scripts/loop-config.sh: `default_branch`. Needs `bd` with
# this repository's database: the ticket text comes from Beads, and --archive closes there.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
CONFIG="$SCRIPT_ROOT/scripts/loop-config.sh"
CHANGELOG="$ROOT/CHANGELOG.md"
ARCHIVE=""
MODE=notes
REFS=()
PREFIXES=""
PREFIX_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) ARCHIVE="$2"; MODE=archive; shift ;;
    --changelog) CHANGELOG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;;
    --prefix) PREFIX_GIVEN=1
      for p in $(printf '%s' "$2" | tr ',' ' '); do
        [ -n "$p" ] || continue
        PREFIXES="${PREFIXES:+$PREFIXES,}$p"
      done
      shift ;;
    --self-test) MODE=selftest ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) REFS+=("$1") ;;
  esac
  shift
done
if [ "$PREFIX_GIVEN" = 1 ] && [ -z "$PREFIXES" ]; then
  echo "usage: --prefix needs at least one prefix; an empty list is not the same as leaving the flag off" >&2
  exit 2
fi
RELEASE_NOTES_PREFIXES="$PREFIXES"
export RELEASE_NOTES_PREFIXES

# The commits from..to that carry a ticket id, oldest first, as `sha<TAB>date<TAB>id<TAB>summary`.
shipped() {
  local from="$1" to="$2"
  git -C "$ROOT" log --reverse --date=short --format='%h%x09%ad%x09%s' "$from..$to" -- 2>/dev/null \
    | perl -ne 'chomp; my ($sha, $date, $subject) = split /\t/, $_, 3; next unless $subject =~ /^([A-Z]+-\d+):\s*(.*)$/; print "$sha\t$date\t$1\t$2\n";'
}

# The changelog and the list of ids to close. Reads the shipped list on STDIN, the Beads queue
# from a JSON file; writes the changelog when archiving and the close list to <closelist>.
render() {
  local mode="$1" tag="$2" from="$3" to="$4" changelog="$5" bdjson="$6" closelist="$7" shiplist="$8"
  perl - "$mode" "$tag" "$from" "$to" "$changelog" "$bdjson" "$closelist" "$shiplist" <<'PERL'
use strict;
use warnings;
use JSON::PP;

my ($mode, $tag, $from, $to, $changelog, $bdjson, $closelist, $shiplist) = @ARGV;
binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my %want_prefix = map { $_ => 1 } grep { length } split /,/, ($ENV{RELEASE_NOTES_PREFIXES} // "");
my $keep = sub {
  my $id = shift;
  return 1 unless %want_prefix;
  my ($p) = $id =~ /^([A-Z]+)-/;
  return (defined $p && $want_prefix{$p}) ? 1 : 0;
};

my @shipped;
if (open my $sh, "<", $shiplist) {
  while (my $line = <$sh>) {
    chomp $line;
    my @f = split /\t/, $line, 4;
    push @shipped, { sha => $f[0], date => $f[1], id => $f[2], summary => $f[3] } if @f == 4;
  }
  close $sh;
}
my @ships = grep { $keep->($_->{id}) } @shipped;
my %seen;
my @ids = grep { !$seen{$_}++ } map { $_->{id} } @ships;
my %first; for my $s (@ships) { $first{ $s->{id} } //= $s; }

# The Beads queue, keyed by id: title, description, acceptance criteria, section label, state.
my (%ticket, %in_bd);
{
  my $raw = "";
  if (open my $fh, "<", $bdjson) { local $/; $raw = <$fh>; close $fh; }
  my $rows = eval { JSON::PP->new->utf8->decode($raw) };
  for my $r (@{ (ref $rows eq "ARRAY" ? $rows : []) }) {
    my $id = $r->{id} // "";
    next unless $id =~ /^[A-Z][A-Z0-9]*-[0-9]+$/;
    next if ($r->{issue_type} // "") =~ /^(epic|milestone|decision)$/;
    my $section = "";
    for my $l (@{ $r->{labels} // [] }) { $section = $1 if $l =~ /^section:(.*)$/; }
    $ticket{$id} = { title => $r->{title} // "", description => $r->{description} // "",
                     acceptance => $r->{acceptance_criteria} // "", section => $section,
                     status => $r->{status} // "open" };
    $in_bd{$id} = 1;
  }
}
my $title = sub { my $id = shift; my $t = $ticket{$id}; return $t && $t->{title} ne "" ? $t->{title} : ""; };
my $section_name = sub {
  my $prefix = shift;
  for my $id (@ids) { next unless ($id =~ /^$prefix-/); my $t = $ticket{$id}; return "$t->{section} ($prefix)" if $t && $t->{section} ne ""; }
  return $prefix;
};
my %by_prefix;
for my $id (@ids) { my ($prefix) = $id =~ /^([A-Z]+)-/; push @{ $by_prefix{$prefix} }, $id; }
my $notes = "";
for my $prefix (sort keys %by_prefix) {
  $notes .= "\n### " . $section_name->($prefix) . "\n\n";
  for my $id (@{ $by_prefix{$prefix} }) {
    my $f = $first{$id}; my $t = $title->($id);
    $notes .= "- **$id** " . ($t ne "" ? "$t" : $f->{summary}) . " \x{2014} $f->{date} \x{00b7} $f->{sha}"
            . ($t ne "" && lc($t) ne lc($f->{summary}) ? " ($f->{summary})" : "") . "\n";
  }
}
my $scope = %want_prefix ? " matching " . join(", ", sort keys %want_prefix) : "";
if ($mode eq "notes") {
  print "# Release notes $from..$to\n";
  print @ids ? $notes : "\nNo ticket commits in $from..$to$scope.\n";
  exit 0;
}
if (%want_prefix && !@ids) {
  print "nothing in $from..$to$scope; nothing archived\n";
  exit 0;
}

# Archive: the changelog entry, with each ticket's text from Beads.
my $existing = "";
if (open my $ch, "<:encoding(UTF-8)", $changelog) { local $/; $existing = <$ch>; close $ch; }
my $date = @ships ? $ships[-1]{date} : "";
my $entry = "## $tag \x{2014} $date ($from..$to)\n" . $notes;
for my $prefix (sort keys %by_prefix) {
  my @here = grep { $ticket{$_} } @{ $by_prefix{$prefix} };
  next unless @here;
  $entry .= "\n### " . $section_name->($prefix) . ": archived tickets\n";
  for my $id (@here) {
    my $f = $first{$id}; my $t = $ticket{$id};
    $entry .= "\n#### $id " . ($t->{title} ne "" ? $t->{title} : $f->{summary}) . " \x{2014} $f->{date} \x{00b7} $f->{sha}\n\n";
    $entry .= $t->{description} . "\n\n" if $t->{description} ne "";
    $entry .= "**Done when:** $t->{acceptance}\n" if $t->{acceptance} ne "";
  }
}
$entry .= "\n";
my $header = "# Changelog\n\nWhat shipped, by release: the commits that carry a ticket id between two tags, with the\nticket text read from Beads (scripts/release-notes.sh --archive).\n\n";
if ($existing =~ /^## \Q$tag\E /m) {
  print "changelog already has a $tag entry; leaving it as it is\n";
} else {
  my $out;
  if ($existing =~ /^(# Changelog\n(?:.*\n)*?)(?=^## |\z)/m) { my $head = $1; my $rest = substr $existing, length $head; $out = $head . $entry . $rest; }
  else { $out = $header . $entry . $existing; }
  open my $wc, ">:encoding(UTF-8)", $changelog or die "cannot write $changelog: $!";
  print $wc $out; close $wc;
}
# The ids to close: shipped, in Beads, and not already closed; the rest is reported.
my (@close, @already, @absent);
for my $id (@ids) {
  if (!$in_bd{$id}) { push @absent, $id; next; }
  if (($ticket{$id}{status} // "open") eq "closed") { push @already, $id; next; }
  push @close, $id;
}
open my $cl, ">", $closelist or die "cannot write $closelist: $!";
print $cl join("\n", @close), (@close ? "\n" : "");
close $cl;
print "archived " . scalar(@ids) . " ticket(s) under $tag: " . join(", ", @ids) . "\n";
print "already closed: " . join(", ", @already) . "\n" if @already;
print "not in the Beads queue: " . join(", ", @absent) . "\n" if @absent;
PERL
}

archive() {
  local tag="$1" from="$2" to="$3" json closelist shiplist id
  command -v bd >/dev/null || { echo "release-notes: bd is required for --archive" >&2; exit 1; }
  json="$(mktemp "${TMPDIR:-/tmp}/release-bd.XXXXXX")"
  closelist="$(mktemp "${TMPDIR:-/tmp}/release-close.XXXXXX")"
  shiplist="$(mktemp "${TMPDIR:-/tmp}/release-ship.XXXXXX")"
  trap 'rm -f "${json:-}" "${closelist:-}" "${shiplist:-}"' EXIT
  ( cd "$ROOT" && bd list --all --json -n 0 ) >"$json" 2>"$json.err" \
    || { echo "release-notes: no Beads queue could be read from $ROOT" >&2; sed 's/^/  /' "$json.err" >&2 || true; rm -f "$json" "$json.err" "$closelist" "$shiplist"; exit 1; }
  rm -f "$json.err"
  shipped "$from" "$to" > "$shiplist"
  render archive "$tag" "$from" "$to" "$CHANGELOG" "$json" "$closelist" "$shiplist"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ( cd "$ROOT" && bd close "$id" --reason "archived under $tag" ) >/dev/null
  done < "$closelist"
  rm -f "$json" "$closelist" "$shiplist"
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/release-notes.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR" me="$SCRIPT_ROOT/scripts/release-notes.sh" out
  mkdir -p "$dir/bin"
  cat > "$dir/bin/bd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$BD_LOG"
case "$1" in
  list)
    cat <<'JSON'
[
 {"id":"AA-01","title":"First thing","description":"Why AA-01 exists.","acceptance_criteria":"AA-01 is proved","status":"open","priority":2,"issue_type":"task","labels":["section:Alpha","sprint"]},
 {"id":"AA-02","title":"Second thing","description":"Why AA-02 exists.","acceptance_criteria":"AA-02 is proved","status":"open","priority":2,"issue_type":"task","labels":["section:Alpha","sprint"]},
 {"id":"BB-01","title":"Other prefix","description":"Why BB-01 exists.","acceptance_criteria":"BB-01 is proved","status":"open","priority":2,"issue_type":"task","labels":["section:Beta","sprint"]},
 {"id":"AA-03","title":"Already closed","description":"Why AA-03 exists.","acceptance_criteria":"AA-03 is proved","status":"closed","priority":2,"issue_type":"task","labels":["section:Alpha","sprint"]}
]
JSON
    ;;
esac
EOF
  chmod +x "$dir/bin/bd"
  (
    cd "$dir"
    git init -q
    git config user.email t@example.com
    git config user.name t
    git checkout -q -b main
    printf 'scaffold\n' > README.md
    git add -A
    git commit -q -m "Scaffold"
    git tag v0.0.0
    git commit -q --allow-empty -m "AA-01: first thing"
    git commit -q --allow-empty -m "AA-02: second thing"
    git commit -q --allow-empty -m "BB-01: other prefix"
    git commit -q --allow-empty -m "AA-03: already closed"
  )
  printf '[loop]\ndefault_branch = "main"\n' > "$dir/.loop.toml"
  export PATH="$dir/bin:$PATH" BD_LOG="$dir/bd.log" LOOP_ROOT="$dir"
  out="$("$me" v0.0.0 HEAD 2>&1)" || { echo "self-test: notes should pass:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'AA-01.*First thing' || { echo "self-test: notes should name AA-01 from Beads:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'BB-01' || { echo "self-test: notes should name every prefix:"; echo "$out"; exit 1; }
  out="$("$me" --archive v0.1.0 v0.0.0 HEAD 2>&1)" || { echo "self-test: archive should pass:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'archived 4 ticket(s) under v0.1.0' || { echo "self-test: archive should count four tickets:"; echo "$out"; exit 1; }
  grep -q '^## v0.1.0 ' "$dir/CHANGELOG.md" || { echo "self-test: the changelog should gain the release:"; cat "$dir/CHANGELOG.md"; exit 1; }
  grep -q '^#### AA-01 First thing ' "$dir/CHANGELOG.md" || { echo "self-test: the changelog should carry the ticket text:"; cat "$dir/CHANGELOG.md"; exit 1; }
  grep -q 'AA-01 is proved' "$dir/CHANGELOG.md" || { echo "self-test: the changelog should carry the acceptance criteria:"; exit 1; }
  grep -q '^close AA-01 --reason archived under v0.1.0$' "$dir/bd.log" || { echo "self-test: AA-01 should be closed in Beads:"; cat "$dir/bd.log"; exit 1; }
  grep -q '^close AA-02 ' "$dir/bd.log" || { echo "self-test: AA-02 should be closed in Beads:"; exit 1; }
  grep -q '^close BB-01 ' "$dir/bd.log" || { echo "self-test: BB-01 should be closed in Beads:"; exit 1; }
  if grep -q '^close AA-03 ' "$dir/bd.log"; then echo "self-test: an already-closed ticket must not be closed again"; exit 1; fi
  echo "$out" | grep -q 'already closed: AA-03' || { echo "self-test: AA-03 should be reported already closed:"; echo "$out"; exit 1; }
  # A prefix filter archives only its own tickets, and nothing when it matches nothing.
  : > "$dir/bd.log"
  out="$("$me" --prefix CC --archive v0.2.0 v0.0.0 HEAD 2>&1)"
  echo "$out" | grep -q 'nothing archived' || { echo "self-test: a prefix with no work should archive nothing:"; echo "$out"; exit 1; }
  if grep -q '^close ' "$dir/bd.log"; then echo "self-test: a prefix with no work should close nothing:"; cat "$dir/bd.log"; exit 1; fi
  unset LOOP_ROOT BD_LOG
  echo "release-notes self-test passed"
}

case "$MODE" in
  selftest) self_test ;;
  notes)
    from="${REFS[0]:-}"; to="${REFS[1]:-$("$CONFIG" default_branch)}"
    [ -n "$from" ] || { echo "usage: scripts/release-notes.sh <from-ref> [<to-ref>] | --archive <tag> <from> [<to>] | --self-test" >&2; exit 2; }
    command -v bd >/dev/null || { echo "release-notes: bd is required to read the ticket text" >&2; exit 1; }
    json="$(mktemp "${TMPDIR:-/tmp}/release-bd.XXXXXX")"
    shiplist="$(mktemp "${TMPDIR:-/tmp}/release-ship.XXXXXX")"
    trap 'rm -f "${json:-}" "${shiplist:-}"' EXIT
    ( cd "$ROOT" && bd list --all --json -n 0 ) >"$json" 2>"$json.err" \
      || { echo "release-notes: no Beads queue could be read from $ROOT" >&2; sed 's/^/  /' "$json.err" >&2 || true; rm -f "$json" "$json.err" "$shiplist"; exit 1; }
    rm -f "$json.err"
    shipped "$from" "$to" > "$shiplist"
    render notes "" "$from" "$to" "" "$json" /dev/null "$shiplist"
    rm -f "$json" "$shiplist" ;;
  archive)
    from="${REFS[0]:-}"; to="${REFS[1]:-$("$CONFIG" default_branch)}"
    [ -n "$ARCHIVE" ] && [ -n "$from" ] || { echo "usage: scripts/release-notes.sh --archive <tag> <from> [<to>]" >&2; exit 2; }
    archive "$ARCHIVE" "$from" "$to" ;;
  *) echo "usage: scripts/release-notes.sh <from-ref> [<to-ref>] | --archive <tag> <from> [<to>] | --self-test" >&2; exit 2 ;;
esac
