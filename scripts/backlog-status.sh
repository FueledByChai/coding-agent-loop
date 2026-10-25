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
#                                             the tickets not done, not dropped and not in the
#                                             sprint, grouped by their section: label, with the
#                                             story each serves
#   scripts/backlog-status.sh --sprint-check  an open ticket the sprint label omits, which is a
#                                             fault where the sprint is every open ticket (a done
#                                             or dropped ticket is never an omission)
#   scripts/backlog-status.sh --reconcile     git and Beads against each other (0012, 0030): a
#                                             ticket Beads has closed with no naming commit and no
#                                             drop, a landed commit naming a ticket Beads has not
#                                             closed, and a drop the queue cannot honour (below)
#   scripts/backlog-status.sh --show <id>     a ticket's text, state, acceptance criteria and the
#                                             story it serves, or a story and its tickets
#   scripts/backlog-status.sh --stories       every story in the product backlog with a status
#                                             derived from the tickets that carry a story: label,
#                                             dropped ones left out
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
# disagree.
#
# A ticket leaves the queue without landing only as `dropped` (0030): closed in Beads with a drop
# marker and named by no landed commit. A marker is a `duplicates` or `supersedes` dependency,
# which sits on the dropped ticket and names the ticket carrying its work (`bd duplicate X --of C`,
# `bd supersede X --with R`), or the `loop:dropped` label, for an owner's decision that nothing
# carries; the label is the marker, and a label drop must also carry a close reason. The state is
# one derivation - done (git) beats dropped (closed and marked) beats the rest - and a dropped
# ticket is never done, never ready, never offered, no sprint omission and no part of a story's
# count. A ticket that carries a marker Beads has not closed is never ready either. --reconcile
# judges the marker: it fails a marker on a ticket Beads has not closed, a label drop with no
# reason (bd stores `Closed` when given none, so that is none), a landed commit naming a marked
# ticket, a drop link to anything but a ticket in this queue that is not itself dropped, a ticket
# not done or dropped blocked by a dropped one (naming the dependency to re-point, and never
# advising its removal while another ticket may carry the work), and a story a link-dropped
# ticket serves that none of its carriers does. Needs `bd` with this repository's database.
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

# The label that drops a ticket nothing carries (0030). It is fixed and namespaced, like
# loop:coordination, so that every project reads a drop the same way and a project's own
# `dropped` label, if it has one, is no marker.
my $DROP_LABEL = "loop:dropped";

my (@tickets, %by_id);
for my $r (@$rows) {
  my $id = $r->{id} // "";
  next unless $id =~ /^[A-Z][A-Z0-9]*-[a-z0-9]+$/;
  my $type = $r->{issue_type} // "task";
  next if $type =~ /^(epic|milestone|decision)$/;
  my @labels = @{ $r->{labels} // [] };
  my %label; $label{$_} = 1 for @labels;
  my (@blockers, @drop_links);
  for my $d (@{ $r->{dependencies} // [] }) {
    next unless defined $d->{depends_on_id} && defined $d->{type};
    if ($d->{type} eq "blocks") { push @blockers, $d->{depends_on_id}; next; }
    # A drop link sits on the dropped ticket and its depends_on_id is the ticket that carries the
    # work, for both kinds, as bd 1.3.0 stores them: `bd supersede X --with R` gives X the
    # dependency {type: supersedes, depends_on_id: R}, which reads "X is superseded by R".
    push @drop_links, [$d->{type}, $d->{depends_on_id}] if $d->{type} eq "duplicates" || $d->{type} eq "supersedes";
  }
  # bd stores "Closed" when a close is given no reason (`bd close X`, or `--reason ""`), so that
  # placeholder, like an empty or blank reason, is no reason at all.
  my $close_reason = $r->{close_reason} // "";
  my $reason = $close_reason; $reason =~ s/\s+/ /g; $reason =~ s/^ | $//g;
  $reason = "" if lc($reason) eq "closed";
  my $marked = (@drop_links || $label{$DROP_LABEL}) ? 1 : 0;
  my $section = "";
  for my $l (@labels) { $section = $1 if $l =~ /^section:(.*)$/; }
  my @serves;
  for my $l (@labels) { push @serves, $1 if $l =~ /^story:(.*)$/; }
  my $bd_status = $r->{status} // "open";
  my $assignee = $r->{assignee} // "";
  # One derivation: git's done beats a drop, and a drop beats Beads' own status. The marker
  # decides the state; --reconcile judges whether the marker is one the queue can honour.
  my $state = $done{$id} ? "done"
            : ($bd_status eq "closed" && $marked) ? "dropped"
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
            drop_links => \@drop_links, drop_label => ($label{$DROP_LABEL} ? 1 : 0), marked => $marked,
            reason => $reason, close_reason => $close_reason,
            false_close => ($bd_status eq "closed" && !$done{$id} && !$marked) ? 1 : 0,
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
    if ($line =~ /^### ([A-Z][A-Z0-9]*-[a-z0-9]+) \x{2014} (.*)$/) {
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

# Done and dropped are both settled: neither is work left, so neither is an omission from the
# sprint, a row of the pick list, or a ticket a story waits on. Only done counts as done.
my $settled = sub { my $t = shift; return ($t->{state} eq "done" || $t->{state} eq "dropped") ? 1 : 0; };
# The tickets a story counts: the ones serving it that are not dropped.
my $counted = sub { my $s = shift; return grep { $_->{state} ne "dropped" } @{ $s->{tickets} }; };
my $story_status = sub {
  my $s = shift;
  my @t = $counted->($s);
  return "unticketed" unless @t;
  my $d = grep { $_->{state} eq "done" } @t;
  return $d == @t ? "done" : "open $d/" . scalar(@t);
};

# The tickets a dropped ticket's links name that can carry its work: tickets in this queue that are
# not themselves dropped, once each. --reconcile fails every other link.
my $carriers = sub {
  my $t = shift; my %seen;
  return grep { !$seen{$_}++ && $by_id{$_} && $by_id{$_}{state} ne "dropped" } map { $_->[1] } @{ $t->{drop_links} };
};
# What carries a dropped ticket's work as far as the faults can name it: its carriers or, when its
# own links name only dropped tickets (fault 4), their carriers, which fault 4 points it at.
my $carried_by = sub {
  my $t = shift;
  my @c = $carriers->($t);
  return @c if @c;
  my %seen;
  return grep { !$seen{$_}++ } map { $carriers->($by_id{$_}) }
         grep { $by_id{$_} && $by_id{$_}{state} eq "dropped" } map { $_->[1] } @{ $t->{drop_links} };
};
my $link_words = sub { my $kind = shift; return $kind eq "duplicates" ? "duplicate of" : "superseded by"; };
# What a marker says, as the table shows it: the links by kind, or the reason a label drop gives.
my $drop_note = sub {
  my $t = shift; my (%by_kind, @kinds);
  for my $l (@{ $t->{drop_links} }) { push @kinds, $l->[0] unless $by_kind{ $l->[0] }; push @{ $by_kind{ $l->[0] } }, $l->[1]; }
  return join "; ", map { $link_words->($_) . " " . join(", ", @{ $by_kind{$_} }) } @kinds if @kinds;
  my $why = $t->{reason};
  return "no reason" if $why eq "";
  $why = substr($why, 0, 47) . "\x{2026}" if length $why > 48;
  return $why;
};
# Every marker a ticket carries, for a fault line, and the commands that take them all off.
my $markers_of = sub {
  my $t = shift;
  return join ", ", ($t->{drop_label} ? ("the $DROP_LABEL label") : ()), map { $link_words->($_->[0]) . " $_->[1]" } @{ $t->{drop_links} };
};
my $unmark_of = sub {
  my $t = shift;
  return join " && ", ($t->{drop_label} ? ("bd update $t->{id} --remove-label $DROP_LABEL") : ()), map { "bd dep remove $t->{id} $_->[1]" } @{ $t->{drop_links} };
};

my $landed = sub { my $b = shift; return exists $done{$b}; };
my $ready = sub {
  my $t = shift;
  return 0 unless $t->{state} eq "todo";
  # A drop marker on a ticket Beads has not closed is a contradiction --reconcile names (fault 1),
  # and until it is settled the ticket is not offered as work.
  return 0 if $t->{marked};
  for my $b (@{ $t->{blockers} }) { return 0 unless $landed->($b); }
  return 1;
};
my $blockers_of = sub { my $t = shift; join ",", map { $_ . ($landed->($_) ? "" : "!") } @{ $t->{blockers} }; };
my $state_of = sub {
  my $t = shift; my $base = $t->{state}; my $state = $base;
  $state .= " (was " . $t->{bd_status} . ")" if $base eq "done" && $t->{bd_status} ne "closed" && $t->{bd_status} ne "open";
  $state .= " (marked dropped in bd)" if $base ne "dropped" && $t->{marked};
  $state .= " (" . $drop_note->($t) . ")" if $base eq "dropped";
  $state .= " (closed in bd, no commit)" if $t->{false_close};
  return $state;
};
my $by_ready_order = sub {
  my @rows = @_;
  @rows = sort {
    $settled->($a) <=> $settled->($b)
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
  # leave the sprint freely, since git is the proof, and so may a dropped one, which is no work.
  for my $t (@tickets) {
    next if $settled->($t) || $sprint{ $t->{id} };
    printf STDERR "sprint: %s is open and carries no %s label: %s\n", $t->{id}, $sprint_label, $t->{title};
    $bad = 1;
  }
  exit($bad ? 1 : 0);
}

if ($mode eq "reconcile") {
  my $bad = 0;
  my $fault = sub { my $format = shift; printf STDERR "reconcile: $format\n", @_; $bad = 1; };
  for my $t (@tickets) {
    my $id = $t->{id};
    if ($t->{false_close}) {
      $fault->("%s is closed in Beads but no commit reachable from %s names it; reopen it, or drop it as the loop kit's decision 0030 says (bd duplicate or bd supersede, once any dependency it has on the ticket carrying its work is removed, or the %s label with a reason)",
        $id, $judged_ref, $DROP_LABEL);
    }
    if ($t->{orphan}) {
      my ($date, $sha) = @{ $done{$id} };
      $fault->("commit %s names %s, which Beads still has %s; close it in Beads (%s)", $sha, $id, $t->{bd_status}, "bd close $id");
    }
    # A marker is judged once: a landed ticket's contradicts its commit, and an unlanded one's
    # contradicts a status that is not closed.
    if ($t->{marked} && $done{$id}) {
      my ($date, $sha) = @{ $done{$id} };
      $fault->("commit %s names %s, which Beads marks dropped (%s); it landed, so it is done: remove the marker (%s)",
        $sha, $id, $markers_of->($t), $unmark_of->($t));
    } elsif ($t->{marked} && $t->{bd_status} ne "closed") {
      $fault->("%s is %s in Beads but carries a drop marker (%s); close it if it is dropped, or remove the marker (%s)",
        $id, $t->{bd_status}, $markers_of->($t), $unmark_of->($t));
    }
    next unless $t->{state} eq "dropped";
    # A link explains itself; a label drop has only its reason, and bd keeps a ticket's first
    # reason when it is closed again, so the fix reopens it. bd refuses to close a ticket that is
    # still blocked without --force, and a drop is for good, so the fix forces it.
    if (!@{ $t->{drop_links} } && $t->{reason} eq "") {
      $fault->("%s is dropped by the %s label with no close reason; give it one (bd reopen %s && bd close %s --force --reason \"<why>\")",
        $id, $DROP_LABEL, $id, $id);
    }
    # Every link names a carrier that can be judged: a ticket in this queue, not itself dropped. That
    # one rule refuses a cycle, an epic, another queue's id and a chain alike.
    for my $l (@{ $t->{drop_links} }) {
      my ($kind, $to) = @$l;
      my $target = $by_id{$to};
      if (!$target) {
        $fault->("%s is dropped as %s %s, which is not a ticket in this queue; link the ticket that carries the work, or drop it by the %s label with a reason naming where the work went",
          $id, $link_words->($kind), $to, $DROP_LABEL);
        next;
      }
      next unless $target->{state} eq "dropped";
      my @next = $carriers->($target);
      my $relink = $kind eq "duplicates" ? "bd duplicate $id --of" : "bd supersede $id --with";
      if (@next) {
        $fault->("%s is dropped as %s %s, which is itself dropped; point it at %s (bd dep remove %s %s && %s %s)",
          $id, $link_words->($kind), $to, join(", ", @next), $id, $to, $relink, $next[0]);
      } elsif (@{ $target->{drop_links} }) {
        # The target's own links name no live ticket either (a cycle, a self-link, a longer chain):
        # something may still carry the work, so the fix links it rather than retiring this one.
        $fault->("%s is dropped as %s %s, which is itself dropped and links no live ticket either; link the ticket that carries the work instead (bd dep remove %s %s && %s <carrier>)",
          $id, $link_words->($kind), $to, $id, $to, $relink);
      } else {
        $fault->("%s is dropped as %s %s, which is dropped by the %s label with nothing carrying its work; link the ticket that carries this one's, or remove the link (bd dep remove %s %s) and drop %s by the %s label with a reason",
          $id, $link_words->($kind), $to, $DROP_LABEL, $id, $to, $id, $DROP_LABEL);
      }
    }
    # A story leaves a link-dropped ticket out of its count, so one of its carriers has to serve
    # the story instead, or the story reads done while the work sits outside it.
    my @live = $carriers->($t);
    next unless @live;
    for my $s (@{ $t->{serves} }) {
      next if grep { my $c = $by_id{$_}; grep { $_ eq $s } @{ $c->{serves} } } @live;
      $fault->("%s serves story:%s and is dropped for %s, %s; add the label (bd update %s --add-label story:%s)",
        $id, $s, join(", ", @live), (@live > 1 ? "none of which serves it" : "which does not serve it"), $live[0], $s);
    }
  }
  # A dropped ticket never lands, so whatever waits on it waits for good: its dependency is
  # re-pointed to the ticket carrying the work, or removed only when nothing else carries it - the
  # dependent itself, or nothing at all by a label drop. A blocker whose own link is broken may
  # still be carried, so its dependent is never told to drop the dependency.
  for my $t (@tickets) {
    next if $settled->($t);
    my %has; $has{$_} = 1 for @{ $t->{blockers} };
    for my $b (@{ $t->{blockers} }) {
      my $bt = $by_id{$b};
      next unless $bt && $bt->{state} eq "dropped";
      my @all = $carried_by->($bt);
      my @to = grep { $_ ne $t->{id} } @all;
      my @add = grep { !$has{$_} } @to;
      my @say = ($t->{id}, $b, $drop_note->($bt));
      my $head = "%s is blocked by %s, which is dropped (%s) and never lands; ";
      if (@add) {
        $fault->($head . "re-point the dependency to %s (%s)", @say, join(", ", @to),
          join(" && ", "bd dep remove $t->{id} $b", map { "bd dep add $t->{id} $_" } @add));
      } elsif (@to) {
        $fault->($head . "it already depends on %s, which carries the work, so remove the dependency (bd dep remove %s %s)",
          @say, join(", ", @to), $t->{id}, $b);
      } elsif (@all) {
        $fault->($head . "%s carries the work itself, so remove the dependency (bd dep remove %s %s)", @say, $t->{id}, $t->{id}, $b);
      } elsif (@{ $bt->{drop_links} }) {
        $fault->($head . "its own drop link names no live ticket, so fix that first, then re-point the dependency to the ticket that carries the work; do not remove it", @say);
      } else {
        $fault->($head . "nothing carries its work, so remove the dependency (bd dep remove %s %s)", @say, $t->{id}, $b);
      }
    }
  }
  exit($bad ? 1 : 0);
}

if ($mode eq "next") {
  my @ordered = ($by_ready_order->(grep { $sprint{$_->{id}} } @tickets),
                 $by_ready_order->(grep { !$sprint{$_->{id}} } @tickets));
  for my $t (@ordered) { if ($ready->($t)) { print "$t->{id}\n"; exit 0; } }
  print STDERR "no ready ticket: every open one is claimed, blocked, waits on a blocker, or carries a drop marker\n";
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
    printf "dropped: %s\n", $markers_of->($t) if $t->{marked};
    printf "close reason: %s\n", $t->{close_reason} if $t->{bd_status} eq "closed" && $t->{reason} ne "";
    for my $id (@{ $t->{serves} }) {
      my $s = $story{$id};
      printf "serves: %s%s\n", $id, $s ? " - $s->{title} (" . $story_status->($s) . ")" : " (not in the product backlog)";
    }
    exit 0;
  }
  if (my $s = $story{$want}) {
    print "$s->{heading}\n", map { "$_\n" } @{ $s->{body} };
    printf "status: %s (the file says: %s)\n", $story_status->($s), ($s->{written} || "nothing");
    # Every ticket that serves it, dropped ones too, so a reader sees why the count is lower.
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
      my @ids = map { $_->{id} } $counted->($s);
      print join("\t", $flat->($s->{id}), $story_status->($s), (@ids ? scalar(@ids) : "-"),
                       $flat->($s->{epic}), $flat->($s->{title})), "\n";
    }
  } else {
    printf "%-8s %-11s %-8s %-30s %s\n", "id", "status", "tickets", "epic", "title";
    for my $s (@stories) {
      my $epic = $s->{epic}; $epic = substr($epic, 0, 29) . "\x{2026}" if length $epic > 30;
      my @ids = map { $_->{id} } $counted->($s);
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
    next if $settled->($t) || $sprint{ $t->{id} };
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
  print "open: $n ticket(s) not done, not dropped and not in the sprint", (@sprint ? " (sprint: " . join(", ", map { $_->{id} } @sprint) . ")" : " (no sprint label)"), "\n";
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
  printf "sprint: %d ticket(s), %d done, %d dropped, %d ready, %d claimed or doing, %d blocked or waiting\n",
    scalar(@rows), $n{done} // 0, $n{dropped} // 0, $ready_n, ($n{claimed} // 0) + ($n{doing} // 0),
    scalar(@rows) - ($n{done} // 0) - ($n{dropped} // 0) - $ready_n - ($n{claimed} // 0) - ($n{doing} // 0);
}
PERL
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/backlog-status.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR" me="$SCRIPT_ROOT/scripts/backlog-status.sh" out rc
  # has|lacks <output> <regex> <why>: the output carries (or lacks) a line matching the regex, or
  # the self-test fails saying why. A here-string, not a pipe, so grep -q exiting early cannot
  # fail the pipeline under pipefail.
  has() { grep -qE -- "$2" <<< "$1" || { echo "self-test: $3:"; printf '%s\n' "$1"; exit 1; }; }
  lacks() { if grep -qE -- "$2" <<< "$1"; then echo "self-test: $3:"; printf '%s\n' "$1"; exit 1; fi; }
  mkdir -p "$dir/bin"
  cat > "$dir/bin/bd" <<'EOF'
#!/usr/bin/env bash
# Stub bd: the fixture queue for scripts/backlog-status.sh --self-test.
if [ "${BD_SCENARIO:-}" = "no-db" ]; then
  echo "Error: no beads database found" >&2
  exit 1
fi
# AA-08's label is the scenario knob: empty makes --sprint-check fail naming it, and
# BD_SCENARIO=all-sprint labels it so the check passes.
AA08_LABEL="${AA08_LABEL:-}"
# One row per line, in the shape bd 1.3.0 gives: close_reason on a closed row ("Closed" when it
# was closed with none), labels null on an unlabelled one, and a drop link on the dropped ticket
# naming the ticket that carries its work. AA-10, AA-11 and AA-12 are the three good drops - a
# duplicate, a supersede, the label with a reason - and AA-32 a fourth, a link beside the label
# with bd's placeholder reason. AA-13 to AA-19, and AA-20 to AA-34 but AA-32, are the markers
# --reconcile refuses, the tickets that wait on a drop, and the drops they wait on: AA-20 claimed,
# marked and landed; AA-21 blocked by AA-22, dropped for the dropped AA-19 (a chain); AA-24
# blocked by AA-23, dropped for an id in no queue here; AA-25 claimed and blocked by AA-19 beside
# its carrier AA-02; AA-26 blocked by AA-27, which it carries itself, and by AA-33, dropped by the
# label with a blank reason; AA-28 dropped for the label-dropped AA-14; AA-29 and AA-30 dropped for
# each other; AA-34 dropped for two carriers, neither serving its story. The label is loop:dropped:
# AA-07's bare `dropped` label is a project's own word and no marker, so AA-07 is a false close.
rows() {
  cat <<JSON
 {"id":"AA-01","title":"First","description":"first body","acceptance_criteria":"first proof","status":"open","priority":1,"issue_type":"task","labels":["sprint","section:Alpha","story:BT-01"],"assignee":"","dependencies":[]}
 {"id":"AA-02","title":"Second","description":"needs first","acceptance_criteria":"second proof","status":"open","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-02","depends_on_id":"AA-01","type":"blocks"}]}
 {"id":"AA-03","title":"Third","description":"landed already","acceptance_criteria":"third proof","status":"in_progress","priority":3,"issue_type":"task","labels":["sprint"],"assignee":"someone","dependencies":[]}
 {"id":"AA-04","title":"Fourth","description":"claimed and landed","acceptance_criteria":"fourth proof","status":"in_progress","priority":4,"issue_type":"task","labels":["sprint"],"assignee":"someone","dependencies":[]}
 {"id":"AA-05","title":"Fifth","description":"claimed, in the sprint","acceptance_criteria":"fifth proof","status":"in_progress","priority":0,"issue_type":"task","labels":["sprint"],"assignee":"someone","dependencies":[]}
 {"id":"AA-06","title":"Sixth","description":"blocked by an archived ticket whose commit landed","acceptance_criteria":"sixth proof","status":"open","priority":0,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-06","depends_on_id":"ZZ-09","type":"blocks"}]}
 {"id":"AA-07","title":"Seventh","description":"closed with no commit","acceptance_criteria":"seventh proof","status":"closed","close_reason":"Closed","priority":2,"issue_type":"task","labels":["sprint","dropped"],"assignee":"","dependencies":[]}
 {"id":"AA-08","title":"Outside the sprint","description":"open, no sprint label","acceptance_criteria":"eighth proof","status":"open","priority":2,"issue_type":"task","labels":[${AA08_LABEL}],"assignee":"","dependencies":[]}
 {"id":"AA-1a","title":"A generated id","description":"Beads minted this id","acceptance_criteria":"the generated id is read","status":"closed","close_reason":"Closed","priority":2,"issue_type":"task","labels":["sprint","story:BT-1z"],"assignee":"","dependencies":[]}
 {"id":"AA-10","title":"A duplicate","description":"the same work as AA-1a, ticketed twice","acceptance_criteria":"tenth proof","status":"closed","priority":2,"issue_type":"task","labels":["story:BT-1z"],"assignee":"","dependencies":[{"issue_id":"AA-10","depends_on_id":"AA-1a","type":"duplicates"}]}
 {"id":"AA-11","title":"A superseded ticket","description":"claimed, closed bare, then superseded","acceptance_criteria":"eleventh proof","status":"closed","close_reason":"Closed","priority":2,"issue_type":"task","labels":["story:BT-1z"],"assignee":"someone","dependencies":[{"issue_id":"AA-11","depends_on_id":"AA-1a","type":"supersedes"}]}
 {"id":"AA-12","title":"A retired ticket","description":"nothing carries it","acceptance_criteria":"twelfth proof","status":"closed","close_reason":"The owner retired it on 2026-10-24: the work it describes is no longer wanted.","priority":2,"issue_type":"task","labels":["loop:dropped","story:BT-1z"],"assignee":"","dependencies":[]}
 {"id":"AA-13","title":"Labelled loop:dropped, still open","description":"a drop marker on an open ticket","acceptance_criteria":"thirteenth proof","status":"open","priority":1,"issue_type":"task","labels":["sprint","loop:dropped"],"assignee":"","dependencies":[]}
 {"id":"AA-14","title":"Dropped with no reason","description":"bd close with no reason, then the label","acceptance_criteria":"fourteenth proof","status":"closed","close_reason":"Closed","priority":2,"issue_type":"task","labels":["sprint","loop:dropped"],"assignee":"","dependencies":[]}
 {"id":"AA-15","title":"Dropped, landed anyway","description":"a commit names a dropped ticket","acceptance_criteria":"fifteenth proof","status":"closed","priority":2,"issue_type":"task","labels":null,"assignee":"","dependencies":[{"issue_id":"AA-15","depends_on_id":"AA-01","type":"duplicates"}]}
 {"id":"AA-16","title":"Blocked by a drop","description":"waits on a ticket that never lands","acceptance_criteria":"sixteenth proof","status":"open","priority":1,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-16","depends_on_id":"AA-19","type":"blocks"}]}
 {"id":"AA-17","title":"Reopened, still superseded","description":"a drop link on an open ticket","acceptance_criteria":"seventeenth proof","status":"open","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-17","depends_on_id":"AA-01","type":"supersedes"}]}
 {"id":"AA-18","title":"Dropped for nothing live","description":"links an epic and a dropped ticket","acceptance_criteria":"eighteenth proof","status":"closed","priority":2,"issue_type":"task","labels":[],"assignee":"","dependencies":[{"issue_id":"AA-18","depends_on_id":"AA-09","type":"duplicates"},{"issue_id":"AA-18","depends_on_id":"AA-19","type":"supersedes"}]}
 {"id":"AA-19","title":"Carried outside its story","description":"its replacement serves no story","acceptance_criteria":"nineteenth proof","status":"closed","priority":2,"issue_type":"task","labels":["story:BT-01"],"assignee":"","dependencies":[{"issue_id":"AA-19","depends_on_id":"AA-02","type":"supersedes"}]}
 {"id":"AA-20","title":"Claimed, marked, landed","description":"a commit names a claimed ticket that carries a drop link","acceptance_criteria":"twentieth proof","status":"in_progress","priority":2,"issue_type":"task","labels":[],"assignee":"someone","dependencies":[{"issue_id":"AA-20","depends_on_id":"AA-01","type":"duplicates"}]}
 {"id":"AA-21","title":"Blocked by a chain","description":"its blocker is dropped for a dropped ticket","acceptance_criteria":"proof","status":"open","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-21","depends_on_id":"AA-22","type":"blocks"}]}
 {"id":"AA-22","title":"Superseded by a dropped ticket","description":"a chain","acceptance_criteria":"proof","status":"closed","priority":2,"issue_type":"task","labels":[],"assignee":"","dependencies":[{"issue_id":"AA-22","depends_on_id":"AA-19","type":"supersedes"}]}
 {"id":"AA-23","title":"A duplicate of nothing here","description":"links an id in no queue here","acceptance_criteria":"proof","status":"closed","priority":2,"issue_type":"task","labels":[],"assignee":"","dependencies":[{"issue_id":"AA-23","depends_on_id":"NOPE-9","type":"duplicates"}]}
 {"id":"AA-24","title":"Blocked by a broken drop","description":"its blocker links nothing live","acceptance_criteria":"proof","status":"open","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-24","depends_on_id":"AA-23","type":"blocks"}]}
 {"id":"AA-25","title":"Claimed, blocked by a drop and its carrier","description":"already depends on the carrier","acceptance_criteria":"proof","status":"in_progress","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"someone","dependencies":[{"issue_id":"AA-25","depends_on_id":"AA-19","type":"blocks"},{"issue_id":"AA-25","depends_on_id":"AA-02","type":"blocks"}]}
 {"id":"AA-26","title":"Blocked by its own drops","description":"carries one blocker's work, and waits on a label drop","acceptance_criteria":"proof","status":"open","priority":2,"issue_type":"task","labels":["sprint"],"assignee":"","dependencies":[{"issue_id":"AA-26","depends_on_id":"AA-27","type":"blocks"},{"issue_id":"AA-26","depends_on_id":"AA-33","type":"blocks"}]}
 {"id":"AA-27","title":"Superseded by its dependent","description":"AA-26 carries it","acceptance_criteria":"proof","status":"closed","priority":2,"issue_type":"task","labels":[],"assignee":"","dependencies":[{"issue_id":"AA-27","depends_on_id":"AA-26","type":"supersedes"}]}
 {"id":"AA-28","title":"A duplicate of a retired ticket","description":"its canonical is dropped by the label","acceptance_criteria":"proof","status":"closed","priority":2,"issue_type":"task","labels":[],"assignee":"","dependencies":[{"issue_id":"AA-28","depends_on_id":"AA-14","type":"duplicates"}]}
 {"id":"AA-29","title":"Superseded by AA-30","description":"a cycle","acceptance_criteria":"proof","status":"closed","priority":2,"issue_type":"task","labels":[],"assignee":"","dependencies":[{"issue_id":"AA-29","depends_on_id":"AA-30","type":"supersedes"}]}
 {"id":"AA-30","title":"Superseded by AA-29","description":"a cycle","acceptance_criteria":"proof","status":"closed","priority":2,"issue_type":"task","labels":[],"assignee":"","dependencies":[{"issue_id":"AA-30","depends_on_id":"AA-29","type":"supersedes"}]}
 {"id":"AA-32","title":"Labelled and linked","description":"the label beside a link, with bd's placeholder reason","acceptance_criteria":"proof","status":"closed","close_reason":"Closed","priority":2,"issue_type":"task","labels":["loop:dropped"],"assignee":"","dependencies":[{"issue_id":"AA-32","depends_on_id":"AA-1a","type":"duplicates"}]}
 {"id":"AA-33","title":"Dropped with a blank reason","description":"the label, and a reason of spaces","acceptance_criteria":"proof","status":"closed","close_reason":"   ","priority":2,"issue_type":"task","labels":["loop:dropped"],"assignee":"","dependencies":[]}
 {"id":"AA-34","title":"Dropped for two","description":"neither carrier serves its story","acceptance_criteria":"proof","status":"closed","priority":2,"issue_type":"task","labels":["story:BT-01"],"assignee":"","dependencies":[{"issue_id":"AA-34","depends_on_id":"AA-02","type":"duplicates"},{"issue_id":"AA-34","depends_on_id":"AA-06","type":"supersedes"}]}
 {"id":"AA-09","title":"Epic, not a ticket","description":"story","acceptance_criteria":"","status":"open","priority":2,"issue_type":"epic","labels":[],"assignee":"","dependencies":[]}
JSON
}
case "$1" in
  list)
    # BD_SCENARIO=dropped-only answers the good drops and the landed ticket they name alone, so a
    # dropped ticket is all --next could offer.
    keep='.'
    [ "${BD_SCENARIO:-}" = "dropped-only" ] && keep='"id":"AA-(1a|10|11|12|32)"'
    printf '[\n'
    rows | grep -E "$keep" | sed '$!s/$/,/'
    printf ']\n'
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
    git commit -q --allow-empty -m "AA-15: landed although Beads drops it"
    git commit -q --allow-empty -m "AA-20: landed although it carries a drop link"
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

### BT-1z — A generated story id

**Status:** Proposed  
**Acceptance criteria:** it works too.
MD
  export PATH="$dir/bin:$PATH" LOOP_ROOT="$dir"
  out="$("$me" --ref trunk 2>&1)" || { echo "self-test: the table should pass:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^AA-03  done' || { echo "self-test: a landed commit should beat an in_progress claim:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^AA-06  todo' || { echo "self-test: AA-06 should be todo:"; echo "$out"; exit 1; }
  # Beads mints an alphanumeric id once a prefix's numeric space is spent. The row has to be
  # read rather than dropped: it was silently absent while the id shape was digits-only.
  echo "$out" | grep -q '^AA-1a  done' || { echo "self-test: a generated Beads id should be read and reconciled:"; echo "$out"; exit 1; }
  if echo "$out" | grep -q '^AA-09 '; then
    echo "self-test: a coordination epic must not appear as an executable ticket"; exit 1
  fi
  next="$("$me" --ref trunk --next)" || { echo "self-test: --next should find a ready ticket"; exit 1; }
  [ "$next" = "AA-06" ] || { echo "self-test: --next should pass over the claimed AA-05 and take AA-06, got '$next'"; exit 1; }
  out="$("$me" --ref trunk --show AA-02 2>&1)" || { echo "self-test: --show should find AA-02"; exit 1; }
  echo "$out" | grep -q 'second proof' || { echo "self-test: --show should print the acceptance criteria:"; echo "$out"; exit 1; }
  out="$("$me" --ref trunk --show AA-01 2>&1)"
  echo "$out" | grep -q '^sprint: yes (P1)' || { echo "self-test: --show should derive the sprint from the label:"; echo "$out"; exit 1; }
  out="$("$me" --ref trunk --stories 2>&1)" || { echo "self-test: --stories should pass"; exit 1; }
  echo "$out" | grep -q '^BT-01  *open 0/1' || { echo "self-test: the story should derive from the story: label:"; echo "$out"; exit 1; }
  # A story id of the shape Beads mints is read from the backlog too: before the heading was
  # widened, BT-1z was not a story at all and simply did not appear.
  echo "$out" | grep -q '^BT-1z ' || { echo "self-test: a generated story id should be read from the backlog:"; echo "$out"; exit 1; }
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
  # The good drops and the faulty closed ones carry no sprint label, and are no omission: with
  # every open ticket labelled, the check passes beside them.
  lacks "$out" 'AA-[123][0-9]' "--sprint-check should name no dropped or landed ticket"
  out="$(BD_SCENARIO=all-sprint AA08_LABEL='"sprint"' "$me" --ref trunk --sprint-check 2>&1)" || { echo "self-test: --sprint-check should pass when every open ticket carries the label:"; echo "$out"; exit 1; }

  # Drops (0030). The three good ones read dropped, with what carries the work or the reason.
  out="$("$me" --ref trunk 2>&1)"
  has "$out" '^AA-10  dropped \(duplicate of AA-1a\) ' "a bd duplicate should read dropped, naming its canonical"
  has "$out" '^AA-11  dropped \(superseded by AA-1a\) ' "a bd supersede should read dropped, naming its replacement"
  has "$out" '^AA-12  dropped \(The owner retired it on 2026-10-24: the work it…\) ' "a label drop should read dropped with its reason, cut to 48 characters"
  has "$out" '^AA-14  dropped \(no reason\) ' "a label drop with bd's placeholder reason should say it has none"
  has "$out" '^AA-33  dropped \(no reason\) ' "a label drop with a blank reason should say it has none"
  has "$out" '^AA-32  dropped \(duplicate of AA-1a\) ' "a link beside the label should name what carries the work"
  has "$out" '^AA-15  done \(marked dropped in bd\) ' "a landed commit should beat a drop marker"
  has "$out" '^AA-20  done \(was in_progress\) \(marked dropped in bd\) ' "a landed claimed ticket should still say it carries a drop marker"
  has "$out" '^AA-13  todo \(marked dropped in bd\) +- +- +P1 ' "an open ticket carrying a drop marker should say so, and never read ready"
  has "$out" '^AA-07  todo \(closed in bd, no commit\) ' "a plain close with no commit, and a bare dropped label that is no marker, should stay a false close"
  out="$("$me" --ref trunk --show AA-12 2>&1)"
  has "$out" '^dropped: the loop:dropped label$' "--show should name the drop marker"
  has "$out" '^close reason: The owner retired it on 2026-10-24: the work it describes is no longer wanted\.$' "--show should print the whole close reason"
  out="$("$me" --ref trunk --show AA-11 2>&1)"
  has "$out" '^state: dropped \(superseded by AA-1a\)$' "a dropped ticket should never read ready"
  has "$out" '^dropped: superseded by AA-1a$' "--show should name the replacement"
  lacks "$out" '^close reason:' "bd's placeholder Closed is no reason to print"
  # --next offers none of them: answered nothing else, it finds no ready ticket at all, where a
  # closed ticket with no commit used to read todo and be offered.
  rc=0; out="$(BD_SCENARIO=dropped-only "$me" --ref trunk --next 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "self-test: --next should offer no dropped ticket (rc $rc):"; echo "$out"; exit 1; }
  has "$out" '^no ready ticket: ' "--next should say it found no ready ticket"
  lacks "$out" 'AA-(1[0-2]|32)' "--next should offer no dropped ticket"
  # An open ticket that carries a drop marker is not offered either, though nothing blocks it.
  out="$("$me" --ref trunk --show AA-17 2>&1)"
  has "$out" '^state: todo \(marked dropped in bd\)$' "an open ticket carrying a drop link should never read ready"
  out="$("$me" --ref trunk --open 2>&1)"
  lacks "$out" '^AA-1' "--open should list no dropped ticket"
  out="$("$me" --ref trunk --sprint 2>&1)"
  has "$out" '^sprint: 16 ticket\(s\), 3 done, 1 dropped, 3 ready, 2 claimed or doing, 7 blocked or waiting$' "the sprint summary should count a dropped ticket apart"
  # A story they serve beside one landed ticket reads done, counting the landed one alone, and
  # --show <story> still lists them.
  out="$("$me" --ref trunk --stories 2>&1)"
  has "$out" '^BT-1z +done +1 ' "a story served by three drops and one landed ticket should read done"
  out="$("$me" --ref trunk --show BT-1z 2>&1)"
  has "$out" '^ticket: AA-10  dropped' "--show <story> should still list its dropped tickets"
  # --reconcile accepts the good drops: answered them alone, it passes.
  out="$(BD_SCENARIO=dropped-only "$me" --ref trunk --reconcile 2>&1)" || { echo "self-test: --reconcile should accept the four good drops:"; echo "$out"; exit 1; }
  # And it fails each drop it cannot honour, alongside AA-07's false close and the orphans AA-03,
  # AA-04 and AA-20.
  rc=0; out="$("$me" --ref trunk --reconcile 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "self-test: --reconcile should fail the drops it cannot honour (rc $rc):"; echo "$out"; exit 1; }
  has "$out" '^reconcile: AA-13 is open in Beads but carries a drop marker \(the loop:dropped label\); .*\(bd update AA-13 --remove-label loop:dropped\)$' "the loop:dropped label on an open ticket should fail"
  has "$out" '^reconcile: AA-07 is closed in Beads but no commit reachable from trunk names it; reopen it, or drop it as the loop kit.s decision 0030 says \(bd duplicate or bd supersede, once any dependency it has on the ticket carrying its work is removed, or the loop:dropped label with a reason\)$' "a false close should name the drops, and the dependency bd refuses a link over"
  has "$out" '^reconcile: AA-14 is dropped by the loop:dropped label with no close reason; .*\(bd reopen AA-14 && bd close AA-14 --force --reason "<why>"\)$' "a label drop with no reason should fail, forcing the close a blocked ticket needs"
  has "$out" '^reconcile: AA-33 is dropped by the loop:dropped label with no close reason; ' "a label drop with a blank reason should fail"
  has "$out" '^reconcile: commit [0-9a-f]+ names AA-15, which Beads marks dropped \(duplicate of AA-01\); .*\(bd dep remove AA-15 AA-01\)$' "a landed commit naming a dropped ticket should fail"
  has "$out" '^reconcile: AA-16 is blocked by AA-19, which is dropped \(superseded by AA-02\) and never lands; re-point the dependency to AA-02 \(bd dep remove AA-16 AA-19 && bd dep add AA-16 AA-02\)$' "an open ticket blocked by a dropped one should fail, naming the replacement"
  has "$out" '^reconcile: AA-17 is open in Beads but carries a drop marker \(superseded by AA-01\); .*\(bd dep remove AA-17 AA-01\)$' "a drop link on an open ticket should fail"
  has "$out" '^reconcile: AA-18 is dropped as duplicate of AA-09, which is not a ticket in this queue; ' "a drop link to an epic should fail"
  has "$out" '^reconcile: AA-18 is dropped as superseded by AA-19, which is itself dropped; point it at AA-02 \(bd dep remove AA-18 AA-19 && bd supersede AA-18 --with AA-02\)$' "a drop link to a dropped ticket should fail, naming its carrier"
  has "$out" '^reconcile: AA-19 serves story:BT-01 and is dropped for AA-02, which does not serve it; add the label \(bd update AA-02 --add-label story:BT-01\)$' "a story its carrier does not serve should fail"
  has "$out" '^reconcile: AA-34 serves story:BT-01 and is dropped for AA-02, AA-06, none of which serves it; add the label \(bd update AA-02 --add-label story:BT-01\)$' "a story none of two carriers serves should fail"
  # A claimed ticket that landed with a drop link is an orphan and contradicts its marker: two
  # faults, and not a third for the marker on a ticket Beads has not closed.
  has "$out" '^reconcile: commit [0-9a-f]+ names AA-20, which Beads marks dropped \(duplicate of AA-01\); .*\(bd dep remove AA-20 AA-01\)$' "a landed claimed ticket carrying a drop link should fail"
  [ "$(grep -c 'AA-20' <<< "$out")" = 2 ] || { echo "self-test: AA-20 should be reported as an orphan and a landed drop, and nothing else:"; echo "$out"; exit 1; }
  # Chains, cycles and links to nothing here: the fix names the next carrier where there is one, and
  # a dependent is never told to remove a dependency something may still carry.
  has "$out" '^reconcile: AA-22 is dropped as superseded by AA-19, which is itself dropped; point it at AA-02 \(bd dep remove AA-22 AA-19 && bd supersede AA-22 --with AA-02\)$' "a chain should be pointed at its carrier"
  has "$out" '^reconcile: AA-21 is blocked by AA-22, which is dropped \(superseded by AA-19\) and never lands; re-point the dependency to AA-02 \(bd dep remove AA-21 AA-22 && bd dep add AA-21 AA-02\)$' "a ticket blocked by a chain should be re-pointed to its carrier"
  has "$out" '^reconcile: AA-23 is dropped as duplicate of NOPE-9, which is not a ticket in this queue; ' "a drop link to an id in no queue here should fail"
  has "$out" '^reconcile: AA-24 is blocked by AA-23, which is dropped \(duplicate of NOPE-9\) and never lands; its own drop link names no live ticket, so fix that first, then re-point the dependency to the ticket that carries the work; do not remove it$' "a ticket blocked by a broken drop should keep its dependency"
  has "$out" '^reconcile: AA-29 is dropped as superseded by AA-30, which is itself dropped and links no live ticket either; link the ticket that carries the work instead \(bd dep remove AA-29 AA-30 && bd supersede AA-29 --with <carrier>\)$' "a cycle should be linked to its carrier"
  has "$out" '^reconcile: AA-30 is dropped as superseded by AA-29, which is itself dropped and links no live ticket either; ' "both ends of a cycle should fail"
  has "$out" '^reconcile: AA-28 is dropped as duplicate of AA-14, which is dropped by the loop:dropped label with nothing carrying its work; .*\(bd dep remove AA-28 AA-14\) and drop AA-28 by the loop:dropped label with a reason$' "a link to a label drop should fail"
  # A dependent that already depends on the carrier, one that carries the work itself, and one
  # whose blocker nothing carries: each is told to remove the dependency, and nothing else.
  has "$out" '^reconcile: AA-25 is blocked by AA-19, which is dropped \(superseded by AA-02\) and never lands; it already depends on AA-02, which carries the work, so remove the dependency \(bd dep remove AA-25 AA-19\)$' "a claimed ticket that already depends on the carrier should only lose the dropped dependency"
  has "$out" '^reconcile: AA-26 is blocked by AA-27, which is dropped \(superseded by AA-26\) and never lands; AA-26 carries the work itself, so remove the dependency \(bd dep remove AA-26 AA-27\)$' "a ticket carrying its blocker's work should only lose the dependency"
  has "$out" '^reconcile: AA-26 is blocked by AA-33, which is dropped \(no reason\) and never lands; nothing carries its work, so remove the dependency \(bd dep remove AA-26 AA-33\)$' "a ticket blocked by a label drop should lose the dependency"
  lacks "$out" 'AA-(1[012]|32)([^0-9a-z]|$)' "--reconcile should name none of the good drops"
  [ "$(grep -c '^reconcile: ' <<< "$out")" = 25 ] || { echo "self-test: --reconcile should report exactly the twenty-five faults:"; echo "$out"; exit 1; }
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
