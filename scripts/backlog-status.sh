#!/usr/bin/env bash
# Ticket state derived from git, tickets read from Beads (0012). Beads holds the tickets, their
# acceptance criteria, their blockers, their labels and their state; git stays the proof of done:
# a ticket is done when a commit whose subject starts with its id (`LK-01: ...`) is reachable
# from the ref being judged, the default branch by default. The default branch, the stories
# file and the sprint label come from .loop.toml through scripts/loop-config.sh.
#
#   scripts/backlog-status.sh                 every ticket: id, state, date, sha, blockers, title
#   scripts/backlog-status.sh --next          the id of the first ready todo: the tickets carrying
#                                             the sprint label first, by priority then id, then the
#                                             rest by priority then id (exit 1 when there is none)
#   scripts/backlog-status.sh --sprint        the sprint-labelled tickets by priority then id, with
#                                             their states, and a summary line
#   scripts/backlog-status.sh --open [--section <name>]
#                                             the tickets not done and not in the sprint, grouped
#                                             by their section: label, with the story each serves
#   scripts/backlog-status.sh --sprint-check  an open ticket the sprint label omits, which is a
#                                             fault where the sprint is every open ticket
#   scripts/backlog-status.sh --reconcile     git and Beads against each other: a ticket Beads has
#                                             closed with no naming commit, and a landed commit
#                                             naming a ticket Beads has not closed (0012)
#   scripts/backlog-status.sh --show <id>     a ticket's text, state, acceptance criteria and the
#                                             story it serves, or a story and its tickets
#   scripts/backlog-status.sh --stories       every story in the product backlog with a status
#                                             derived from the tickets that carry a story: label
#   scripts/backlog-status.sh --plain         with --stories or --open: tab-separated fields
#   scripts/backlog-status.sh --ref <ref>     the commit done is verified against (default: the
#                                             default branch as origin has it, after a fetch)
#   scripts/backlog-status.sh --local         do not fetch origin first
#   scripts/backlog-status.sh --self-test     a fixture repo and a stub bd prove the reading
#
# A ticket is a Beads issue whose id is `<PREFIX>-<suffix>`, where the suffix is a number until
# the prefix's numeric space is spent and then the alphanumeric id Beads mints instead
# (`LK-1af`, `RB-y3f`). Epics, milestones and decisions are not tickets. `acceptance_criteria`
# is the done line, a `blocks` dependency is a blocker, a
# `story:<ID>` label names the story it serves, a `section:<name>` label groups it, and the
# `sprint_label` label (default `sprint`) puts it in the sprint, ordered by priority then id.
# Beads `closed` is a claim like any other: git decides `done`, and --reconcile fails when the two
# disagree. Needs `bd` with this repository's database.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
CONFIG="$SCRIPT_ROOT/scripts/loop-config.sh"
REF="$("$CONFIG" default_branch)"
REF_GIVEN=0
LOCAL=0
MODE=table
PLAIN=0
WANT=""
SECTION=""
STORIES_FILE="$("$CONFIG" stories)"
SPRINT_LABEL="$("$CONFIG" sprint_label)"
while [ $# -gt 0 ]; do
  case "$1" in
    --next) MODE=next ;;
    --sprint) MODE=sprint ;;
    --open) MODE=open ;;
    --sprint-check) MODE=sprint-check ;;
    --reconcile) MODE=reconcile ;;
    --section) SECTION="$2"; shift ;;
    --show) MODE=show; WANT="$2"; shift ;;
    --stories) MODE=stories ;;
    --stories-file) STORIES_FILE="$2"; shift ;;
    --plain) PLAIN=1 ;;
    --local) LOCAL=1 ;;
    --self-test) MODE=selftest ;;
    --ref) REF="$2"; REF_GIVEN=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

judged_ref() {
  local ref="$1"
  if [ "$REF_GIVEN" = 0 ] && [ "$LOCAL" = 0 ]; then
    git -C "$ROOT" fetch -q origin "$ref" 2>/dev/null || true
    if git -C "$ROOT" rev-parse -q --verify "refs/remotes/origin/$ref" >/dev/null 2>&1; then echo "origin/$ref"; return; fi
    if git -C "$ROOT" rev-parse -q --verify "$ref" >/dev/null 2>&1; then echo "$ref"; return; fi
    echo "HEAD"; return
  fi
  echo "$ref"
}

status() {
  local ref="${1:-}" mode="$2"
  ref="$(judged_ref "$ref")"
  # Assigned unconditionally: a project that keeps no product backlog leaves STORIES_FILE empty
  # and loop.toml.example call that setting supported, so the reference below must see a value.
  local stories="" json gitlog
  if [ -n "$STORIES_FILE" ]; then
    case "$STORIES_FILE" in /*) stories="$STORIES_FILE" ;; *) stories="$ROOT/$STORIES_FILE" ;; esac
  fi
  command -v bd >/dev/null || { echo "backlog-status: bd is required (https://github.com/gastownhall/beads)" >&2; return 1; }
  json="$(mktemp "${TMPDIR:-/tmp}/loop-bd.XXXXXX")"
  gitlog="$(mktemp "${TMPDIR:-/tmp}/loop-git.XXXXXX")"
  trap 'rm -f "${json:-}" "${gitlog:-}"' EXIT
  if ! ( cd "$ROOT" && bd list --all --json -n 0 ) >"$json" 2>"$json.err"; then
    echo "backlog-status: no Beads queue could be read from $ROOT; run 'bd init --prefix XX' there, or 'bd bootstrap' on a fresh clone" >&2
    sed 's/^/  /' "$json.err" >&2 || true
    rm -f "$json" "$json.err"
    return 1
  fi
  rm -f "$json.err"
  git -C "$ROOT" log --reverse --date=short --format='%h %ad %s' "$ref" > "$gitlog" 2>/dev/null || true
  perl - "$json" "$gitlog" "$mode" "$SPRINT_LABEL" "$stories" "$WANT" "$SECTION" "$PLAIN" "$ref" <<'PERL'
use strict;
use warnings;
use JSON::PP;

my ($json_file, $gitlog_file, $mode, $sprint_label, $stories_file, $want, $section_filter, $plain, $judged_ref) = @ARGV;

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

sub slurp {
  my $path = shift;
  # Raw bytes: JSON::PP's utf8 mode decodes them to characters itself, and an :encoding layer
  # here would hand it a character string a multibyte id or title could not survive.
  open my $fh, "<", $path or die "backlog-status: cannot read $path: $!\n";
  local $/;
  my $text = <$fh>;
  close $fh;
  return $text;
}

my $rows = eval { JSON::PP->new->utf8->decode(slurp($json_file)) };
if (!defined $rows || ref $rows ne "ARRAY") {
  print STDERR "backlog-status: the Beads queue did not answer --json with an array\n";
  exit 1;
}

# id -> [date, sha] from the first commit whose subject is `<id>: ...`, oldest first.
my %done;
open my $gf, "<", $gitlog_file or die "backlog-status: cannot read $gitlog_file: $!\n";
while (my $line = <$gf>) {
  chomp $line;
  my ($sha, $date, $subject) = split / /, $line, 3;
  next unless defined $subject && $subject =~ /^([A-Z][A-Z0-9]*-[a-z0-9]+):/;
  $done{$1} //= [$date, $sha];
}
close $gf;

my (@tickets, %by_id);
for my $r (@$rows) {
  my $id = $r->{id} // "";
  next unless $id =~ /^[A-Z][A-Z0-9]*-[a-z0-9]+$/;
  my $type = $r->{issue_type} // "task";
  next if $type =~ /^(epic|milestone|decision)$/;
  my @labels = @{ $r->{labels} // [] };
  my %label; $label{$_} = 1 for @labels;
  my @blockers;
  for my $d (@{ $r->{dependencies} // [] }) {
    next unless defined $d->{depends_on_id} && defined $d->{type} && $d->{type} eq "blocks";
    push @blockers, $d->{depends_on_id};
  }
  my $section = "";
  for my $l (@labels) { $section = $1 if $l =~ /^section:(.*)$/; }
  my @serves;
  for my $l (@labels) { push @serves, $1 if $l =~ /^story:(.*)$/; }
  my $bd_status = $r->{status} // "open";
  my $assignee = $r->{assignee} // "";
  my $state = $done{$id} ? "done"
            : $bd_status eq "closed" ? "todo"
            : $bd_status eq "blocked" ? "blocked"
            : $bd_status eq "deferred" ? "deferred"
            : $bd_status eq "in_progress" ? ($assignee ne "" ? "claimed" : "doing")
            : "todo";
  my $t = { id => $id, title => $r->{title} // "", state => $state, bd_status => $bd_status,
            assignee => $assignee, blockers => \@blockers, section => $section, labels => \@labels,
            priority => (defined $r->{priority} ? $r->{priority} : 2),
            acceptance => $r->{acceptance_criteria} // "", description => $r->{description} // "",
            serves => \@serves, sprint => ($label{$sprint_label} ? 1 : 0),
            false_close => ($bd_status eq "closed" && !$done{$id}) ? 1 : 0,
            orphan => ($done{$id} && $bd_status ne "closed") ? 1 : 0 };
  push @tickets, $t;
  $by_id{$id} = $t;
}

# The sprint is the label, ordered by priority then id; a ticket outside it is ordered after.
my @sprint = sort { $a->{priority} <=> $b->{priority} || $a->{id} cmp $b->{id} }
             grep { $_->{sprint} } @tickets;
my %sprint = map { $_->{id} => $_ } @sprint;

# The product backlog, when the project keeps one: `## <epic>` and `### <ID> - <title>` stories
# with their body; a story's status is derived from the tickets carrying its story: label.
my (@stories, %story);
if ($stories_file ne "" && open my $sf, "<:encoding(UTF-8)", $stories_file) {
  my ($epic, $s) = ("", undef);
  while (my $line = <$sf>) {
    chomp $line;
    if ($line =~ /^## (.*)$/) { $epic = $1; $s = undef; next; }
    if ($line =~ /^### ([A-Z]+-\d+) \x{2014} (.*)$/) {
      $s = { id => $1, title => $2, epic => $epic, written => "", heading => $line, body => [], tickets => [] };
      push @stories, $s; $story{$1} = $s; next;
    }
    next unless $s;
    $s->{written} = $1 if $line =~ /^\*\*Status:\*\*\s*(.*?)\s*$/;
    push @{ $s->{body} }, $line;
  }
  close $sf;
  for my $t (@tickets) {
    for my $id (@{ $t->{serves} }) { push @{ $story{$id}{tickets} }, $t if $story{$id}; }
  }
}

my $story_status = sub {
  my $s = shift;
  my @t = @{ $s->{tickets} };
  return "unticketed" unless @t;
  my $d = grep { $_->{state} eq "done" } @t;
  return $d == @t ? "done" : "open $d/" . scalar(@t);
};

my $landed = sub { my $b = shift; return exists $done{$b}; };
my $ready = sub {
  my $t = shift;
  return 0 unless $t->{state} eq "todo";
  for my $b (@{ $t->{blockers} }) { return 0 unless $landed->($b); }
  return 1;
};
my $blockers_of = sub { my $t = shift; join ",", map { $_ . ($landed->($_) ? "" : "!") } @{ $t->{blockers} }; };
my $state_of = sub {
  my $t = shift; my $state = $t->{state};
  $state .= " (was " . $t->{bd_status} . ")" if $state eq "done" && $t->{bd_status} ne "closed" && $t->{bd_status} ne "open";
  $state .= " (closed in bd, no commit)" if $t->{false_close};
  return $state;
};
my $by_ready_order = sub {
  my @rows = @_;
  @rows = sort {
    ($a->{state} eq "done" ? 1 : 0) <=> ($b->{state} eq "done" ? 1 : 0)
      || $a->{priority} <=> $b->{priority}
      || $a->{id} cmp $b->{id}
  } @rows;
  return @rows;
};
my $section_filter_match = sub {
  my $t = shift;
  return 1 if $section_filter eq "";
  return index(lc $t->{section}, lc $section_filter) >= 0 ? 1 : 0;
};

if ($mode eq "sprint-check") {
  my $bad = 0;
  # The label is the sprint, so the only fault is an open ticket without it: a done ticket may
  # leave the sprint freely, since git is the proof.
  for my $t (@tickets) {
    next if $t->{state} eq "done" || $sprint{ $t->{id} };
    printf STDERR "sprint: %s is open and carries no %s label: %s\n", $t->{id}, $sprint_label, $t->{title};
    $bad = 1;
  }
  exit($bad ? 1 : 0);
}

if ($mode eq "reconcile") {
  my $bad = 0;
  for my $t (@tickets) {
    if ($t->{bd_status} eq "closed" && !$done{$t->{id}}) {
      printf STDERR "reconcile: %s is closed in Beads but no commit reachable from %s names it\n", $t->{id}, $judged_ref;
      $bad = 1;
    }
    if ($t->{orphan}) {
      my ($date, $sha) = @{ $done{$t->{id}} };
      printf STDERR "reconcile: commit %s names %s, which Beads still has %s; close it in Beads (%s)\n",
        $sha, $t->{id}, $t->{bd_status}, "bd close $t->{id}";
      $bad = 1;
    }
  }
  exit($bad ? 1 : 0);
}

if ($mode eq "next") {
  my @ordered = ($by_ready_order->(grep { $sprint{$_->{id}} } @tickets),
                 $by_ready_order->(grep { !$sprint{$_->{id}} } @tickets));
  for my $t (@ordered) { if ($ready->($t)) { print "$t->{id}\n"; exit 0; } }
  print STDERR "no ready ticket: every open one is claimed, blocked, or waits on a blocker\n";
  exit 1;
}

if ($mode eq "show") {
  if (my $t = $by_id{$want}) {
    print "### $t->{id} $t->{title}\n";
    print "$t->{description}\n" if $t->{description} ne "";
    print "\n**Done when:** $t->{acceptance}\n" if $t->{acceptance} ne "";
    printf "state: %s%s\n", $state_of->($t), ($ready->($t) ? ", ready" : "");
    printf "sprint: %s\n", ($t->{sprint} ? "yes (P$t->{priority})" : "no");
    printf "section: %s\n", ($t->{section} ne "" ? $t->{section} : "(none)");
    printf "priority: P%s\n", $t->{priority};
    printf "assignee: %s\n", ($t->{assignee} ne "" ? $t->{assignee} : "(none)");
    printf "labels: %s\n", join(",", @{ $t->{labels} });
    printf "blocked by: %s\n", $blockers_of->($t) if @{ $t->{blockers} };
    for my $id (@{ $t->{serves} }) {
      my $s = $story{$id};
      printf "serves: %s%s\n", $id, $s ? " - $s->{title} (" . $story_status->($s) . ")" : " (not in the product backlog)";
    }
    exit 0;
  }
  if (my $s = $story{$want}) {
    print "$s->{heading}\n", map { "$_\n" } @{ $s->{body} };
    printf "status: %s (the file says: %s)\n", $story_status->($s), ($s->{written} || "nothing");
    printf "ticket: %-6s %-8s %s\n", $_->{id}, $state_of->($_), $_->{title} for @{ $s->{tickets} };
    exit 0;
  }
  print STDERR "$want: no such ticket or story\n";
  exit 1;
}

if ($mode eq "stories") {
  if (!@stories) { print STDERR "no product backlog" . ($stories_file ne "" ? " at $stories_file" : " configured (stories in .loop.toml)") . "\n"; exit 1; }
  my $flat = sub { my $v = shift; $v = "" unless defined $v; $v =~ s/\s+/ /g; $v =~ s/^ | $//g; return $v };
  if ($plain) {
    for my $s (@stories) {
      my @ids = map { $_->{id} } @{ $s->{tickets} };
      print join("\t", $flat->($s->{id}), $story_status->($s), (@ids ? scalar(@ids) : "-"),
                       $flat->($s->{epic}), $flat->($s->{title})), "\n";
    }
  } else {
    printf "%-8s %-11s %-8s %-30s %s\n", "id", "status", "tickets", "epic", "title";
    for my $s (@stories) {
      my $epic = $s->{epic}; $epic = substr($epic, 0, 29) . "\x{2026}" if length $epic > 30;
      my @ids = map { $_->{id} } @{ $s->{tickets} };
      printf "%-8s %-11s %-8s %-30s %s\n", $s->{id}, $story_status->($s), (@ids ? scalar(@ids) : "-"), $epic, $s->{title};
    }
  }
  my %n; $n{ ($story_status->($_) =~ /^(\w+)/)[0] }++ for @stories;
  printf "stories: %d, %d done, %d open, %d unticketed\n", scalar(@stories), $n{done} // 0, $n{open} // 0, $n{unticketed} // 0;
  exit 0;
}

if ($mode eq "open") {
  my $last = "\0"; my $n = 0;
  for my $t (@tickets) {
    next if $t->{state} eq "done" || $sprint{ $t->{id} };
    next unless $section_filter_match->($t);
    my $sec = $t->{section} ne "" ? $t->{section} : "(none)";
    if ($plain) {
      print join("\t", $sec, $t->{id}, $state_of->($t), ($ready->($t) ? "ready" : ""),
                       $blockers_of->($t), join(",", @{ $t->{serves} }), $t->{title}), "\n";
    } else {
      if ($sec ne $last) { print "## $sec\n"; $last = $sec; }
      my $serves = join ",", @{ $t->{serves} };
      printf "%-6s %-8s %-6s %-14s %-10s %s\n", $t->{id}, $state_of->($t), ($ready->($t) ? "ready" : ""), $blockers_of->($t), $serves, $t->{title};
    }
    $n++;
  }
  print "open: $n ticket(s) not done and not in the sprint", (@sprint ? " (sprint: " . join(", ", map { $_->{id} } @sprint) . ")" : " (no sprint label)"), "\n";
  exit 0;
}

my @rows = @tickets;
if ($mode eq "sprint") {
  @rows = @sprint;
  if (!@rows) { print "sprint: empty (no ticket carries the $sprint_label label)\n"; exit 0; }
}
printf "%-6s %-8s %-10s %-8s %-6s %-6s %-22s %s\n", "id", "state", "date", "sha", "ready", "sprint", "blocked by", "title";
for my $t (@rows) {
  my ($date, $sha) = $done{ $t->{id} } ? @{ $done{ $t->{id} } } : ("-", "-");
  printf "%-6s %-8s %-10s %-8s %-6s %-6s %-22s %s\n", $t->{id}, $state_of->($t), $date, $sha, ($ready->($t) ? "yes" : ""), ($t->{sprint} ? "P$t->{priority}" : ""), $blockers_of->($t), $t->{title};
}
if ($mode eq "sprint") {
  my %n; $n{ $_->{state} }++ for @rows;
  my $ready_n = grep { $ready->($_) } @rows;
  printf "sprint: %d ticket(s), %d done, %d ready, %d claimed or doing, %d blocked or waiting\n",
    scalar(@rows), $n{done} // 0, $ready_n, ($n{claimed} // 0) + ($n{doing} // 0),
    scalar(@rows) - ($n{done} // 0) - $ready_n - ($n{claimed} // 0) - ($n{doing} // 0);
}
PERL
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/backlog-status.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR" me="$SCRIPT_ROOT/scripts/backlog-status.sh" out rc
  mkdir -p "$dir/bin"
  cat > "$dir/bin/bd" <<'EOF'
#!/usr/bin/env bash
# Stub bd: the fixture queue for scripts/backlog-status.sh --self-test.
if [ "${BD_SCENARIO:-}" = "no-db" ]; then
  echo "Error: no beads database found" >&2
  exit 1
fi
case "$1" in
  list)
    # AA-08's label is the scenario knob: empty makes --sprint-check fail naming it, and
    # BD_SCENARIO=all-sprint labels it so the check passes.
    AA08_LABEL="${AA08_LABEL:-}"
    cat <<JSON
[
 {"id":"AA-01","title":"First","description":"first body","acceptance_criteria":"first proof","status":"open","priority":1,"issue_type":"task","labels":["sprint","section:Alpha","story:BT-01"],"assignee":"","dependencies":[]},
 {"id":"AA-02","title":"Second","description":"needs first","acceptance_criteria":"second proof","status":"open","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-02","depends_on_id":"AA-01","type":"blocks"}]},
 {"id":"AA-03","title":"Third","description":"landed already","acceptance_criteria":"third proof","status":"in_progress","priority":3,"issue_type":"task","labels":["sprint"],"assignee":"someone","dependencies":[]},
 {"id":"AA-04","title":"Fourth","description":"claimed and landed","acceptance_criteria":"fourth proof","status":"in_progress","priority":4,"issue_type":"task","labels":["sprint"],"assignee":"someone","dependencies":[]},
 {"id":"AA-05","title":"Fifth","description":"claimed, in the sprint","acceptance_criteria":"fifth proof","status":"in_progress","priority":0,"issue_type":"task","labels":["sprint"],"assignee":"someone","dependencies":[]},
 {"id":"AA-06","title":"Sixth","description":"blocked by an archived ticket whose commit landed","acceptance_criteria":"sixth proof","status":"open","priority":0,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-06","depends_on_id":"ZZ-09","type":"blocks"}]},
 {"id":"AA-07","title":"Seventh","description":"closed with no commit","acceptance_criteria":"seventh proof","status":"closed","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[]},
 {"id":"AA-08","title":"Outside the sprint","description":"open, no sprint label","acceptance_criteria":"eighth proof","status":"open","priority":2,"issue_type":"task","labels":[${AA08_LABEL}],"assignee":"","dependencies":[]},
 {"id":"AA-1a","title":"A generated id","description":"Beads minted this id","acceptance_criteria":"the generated id is read","status":"closed","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[]},
 {"id":"AA-09","title":"Epic, not a ticket","description":"story","acceptance_criteria":"","status":"open","priority":2,"issue_type":"epic","labels":[],"assignee":"","dependencies":[]}
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
    git checkout -q -b trunk
    printf 'scaffold\n' > README.md
    git add -A
    git commit -q -m "Scaffold"
    git commit -q --allow-empty -m "AA-03: third landed"
    git commit -q --allow-empty -m "AA-04: fourth landed"
    git commit -q --allow-empty -m "AA-1a: the generated id landed"
    git commit -q --allow-empty -m "ZZ-09: the blocker landed"
  )
  # No sprint list: the label is the sprint, and sprint_label defaults to "sprint".
  printf '[loop]\ndefault_branch = "trunk"\nstories = "PRODUCT.md"\n' > "$dir/.loop.toml"
  cat > "$dir/PRODUCT.md" <<'MD'
# Product

## Epic A: Alpha things

### BT-01 — A story

**Status:** Proposed  
**User story:** As a user, I want it.

**Acceptance criteria:**

- it works
MD
  export PATH="$dir/bin:$PATH" LOOP_ROOT="$dir"
  out="$("$me" --ref trunk 2>&1)" || { echo "self-test: the table should pass:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^AA-03  done' || { echo "self-test: a landed commit should beat an in_progress claim:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^AA-06  todo' || { echo "self-test: AA-06 should be todo:"; echo "$out"; exit 1; }
  # Beads mints an alphanumeric id once a prefix's numeric space is spent. The row has to be
  # read rather than dropped: it was silently absent while the id shape was digits-only.
  echo "$out" | grep -q '^AA-1a  done' || { echo "self-test: a generated Beads id should be read and reconciled:"; echo "$out"; exit 1; }
  next="$("$me" --ref trunk --next)" || { echo "self-test: --next should find a ready ticket"; exit 1; }
  [ "$next" = "AA-06" ] || { echo "self-test: --next should pass over the claimed AA-05 and take AA-06, got '$next'"; exit 1; }
  out="$("$me" --ref trunk --show AA-02 2>&1)" || { echo "self-test: --show should find AA-02"; exit 1; }
  echo "$out" | grep -q 'second proof' || { echo "self-test: --show should print the acceptance criteria:"; echo "$out"; exit 1; }
  out="$("$me" --ref trunk --show AA-01 2>&1)"
  echo "$out" | grep -q '^sprint: yes (P1)' || { echo "self-test: --show should derive the sprint from the label:"; echo "$out"; exit 1; }
  out="$("$me" --ref trunk --stories 2>&1)" || { echo "self-test: --stories should pass"; exit 1; }
  echo "$out" | grep -q '^BT-01  *open 0/1' || { echo "self-test: the story should derive from the story: label:"; echo "$out"; exit 1; }
  # A project that keeps no product backlog writes stories = "" (loop.toml.example), and the
  # queue still has to read. bash 3.2 initialises an unassigned `local` to empty and hides a
  # reference to it under set -u; bash 5, which CI runs, does not - so this case is the one that
  # catches the unbound variable rather than the machine it was written on.
  out="$("$me" --ref trunk --stories-file "" 2>&1)" || { echo "self-test: no stories file should still read the queue:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^AA-03  done' || { echo "self-test: the table without stories should still list the queue:"; echo "$out"; exit 1; }
  out="$("$me" --ref trunk --sprint 2>&1)" || { echo "self-test: --sprint should pass"; exit 1; }
  [ "$(printf '%s\n' "$out" | awk '$1 ~ /^AA-/ { print $1; exit }')" = "AA-05" ] || { echo "self-test: --sprint should order by priority then id, starting with AA-05:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^AA-05  claimed .*P0' || { echo "self-test: --sprint should show the sprint priority:"; echo "$out"; exit 1; }
  out="$("$me" --ref trunk --open 2>&1)" || { echo "self-test: --open should pass"; exit 1; }
  echo "$out" | grep -q 'AA-08' || { echo "self-test: --open should list the ticket outside the sprint:"; echo "$out"; exit 1; }
  rc=0; out="$("$me" --ref trunk --reconcile 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "self-test: --reconcile should fail on the closed-with-no-commit and the orphan (rc $rc):"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'AA-07 is closed in Beads but no commit' || { echo "self-test: --reconcile should name the false close:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'names AA-04' || { echo "self-test: --reconcile should name the open ticket whose commit landed:"; echo "$out"; exit 1; }
  rc=0; out="$("$me" --ref trunk --sprint-check 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'AA-08 is open and carries no sprint label' || { echo "self-test: --sprint-check should fail naming AA-08:"; echo "$out"; exit 1; }
  out="$(BD_SCENARIO=all-sprint AA08_LABEL='"sprint"' "$me" --ref trunk --sprint-check 2>&1)" || { echo "self-test: --sprint-check should pass when every open ticket carries the label:"; echo "$out"; exit 1; }
  unset LOOP_ROOT
  # A checkout with no Beads database is told the command that creates one.
  rc=0; out="$(BD_SCENARIO=no-db "$me" --ref trunk 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q "run 'bd init --prefix XX'" || { echo "self-test: a missing database should be refused with the fix (rc $rc):"; echo "$out"; exit 1; }
  # A machine without bd is told what is missing rather than reading nothing.
  rc=0; out="$(PATH=/usr/bin:/bin "$me" --ref trunk 2>&1)" || rc=$?
  [ "$rc" = 1 ] && echo "$out" | grep -q 'bd is required' || { echo "self-test: a missing bd should be refused (rc $rc):"; echo "$out"; exit 1; }
  echo "backlog-status self-test passed"
}

case "$MODE" in
  selftest) self_test ;;
  table) status "$REF" table ;;
  *) status "$REF" "$MODE" ;;
esac
