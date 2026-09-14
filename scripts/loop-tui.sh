#!/usr/bin/env bash
# The loop's state as one screen (LK-01, LK-02). One renderer turns the loop's scripts' output
# into frames at a given width; this file holds the dashboard and the three views LS-01 names -
# stories, open, and show. It is split from the terminal: --render prints one frame and exits,
# --width fixes the width, and it takes no keys and writes nothing, so the interactive mode
# (LK-03) is a key handler over these frames rather than a second implementation.
#
#   scripts/loop-tui.sh                  the dashboard: one frame on stdout, then exit
#   scripts/loop-tui.sh --render         the same, spelled out
#   scripts/loop-tui.sh stories          every story in the product backlog: its derived status,
#                                        its ticket count, and the epic it sits under, uncut
#                                        when the frame can hold it
#   scripts/loop-tui.sh open             the tickets outside the sprint, grouped by section,
#                                        with their blockers and the story each serves
#   scripts/loop-tui.sh show <id>        one ticket or story in full: its text, then its state
#                                        and sprint position and the story it serves, or its
#                                        derived status and its tickets
#   scripts/loop-tui.sh --width <n>      fix the width (default: the terminal's, else 78)
#   scripts/loop-tui.sh --ref <ref>      the ref done is judged against (default:
#                                        origin/<default_branch> when it exists, else the
#                                        branch itself). Nothing is fetched here: the frame shows
#                                        what the checkout already knows, and LK-03's `r` is
#                                        what fetches.
#   scripts/loop-tui.sh --self-test      a fixture repository proves every frame, by named line
#                                        and by golden frames
#
# --stories, --open, and --show <id> are the same views spelled as flags, which is how every
# other option here is written; LS-01 names the views themselves, so both spellings are here.
#
# The data comes from the loop's own scripts, never from a second reading of the backlog:
# scripts/backlog-status.sh --sprint gives the rows and the counts, --open what sits outside the
# sprint, --stories the stories, --show one ticket or story, and --next the ticket to work when
# the sprint holds nothing ready. The three views ask for those tables with --plain, which is the
# same fields tab-separated and unpadded: a table cut to a fixed column width cannot be laid out
# at another width, and cutting an epic at thirty columns before the renderer has seen the frame
# is what LK-02 exists to stop. Each call is a subprocess, and the ones that resolve claims reach
# origin, so the dashboard makes three calls and a fourth only when the sprint has no ready
# ticket to name - a frame per ticket would cost about a second each (measured:
# scripts/backlog-status.sh --show is ~1.4s, mostly the fetch).
#
# The dashboard's table columns are cut by position because that is how scripts/backlog-status.sh
# prints them (%-6s %-8s %-10s %-8s %-6s %-6s %-22s %s). The state is the one field that can hold
# a space, so a `blocked <reason>` claim makes it wider than its 8 and shifts the rest of the row.
# The boundary is found by testing each date-or-dash against the fixed columns that follow it,
# because the reason itself can hold a date or a lone dash. The views need none of that: their
# fields arrive separated, so the renderer decides every width.
#
# Settings, from .loop.toml through scripts/loop-config.sh: default_branch, backlog, stories.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
CONFIG="$SCRIPT_ROOT/scripts/loop-config.sh"
STATUS="$SCRIPT_ROOT/scripts/backlog-status.sh"
MAX_ROWS=10

WIDTH=""
REF=""
MODE=dashboard
WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --render) MODE=dashboard ;;
    stories|--stories) MODE=stories ;;
    open|--open) MODE=open ;;
    show|--show) MODE=show; WANT="${2:-}"; [ $# -ge 2 ] && shift ;;
    --width) WIDTH="${2:-}"; shift ;;
    --ref) REF="${2:-}"; shift ;;
    --self-test) MODE=selftest ;;
    *) echo "usage: scripts/loop-tui.sh [dashboard|stories|open|show <id>] [--width <n>] [--ref <ref>] | --self-test" >&2; exit 2 ;;
  esac
  shift
done
if [ "$MODE" = show ] && [ -z "$WANT" ]; then
  echo "usage: scripts/loop-tui.sh show <id> [--width <n>] [--ref <ref>]" >&2; exit 2
fi

# The ref the frame judges done against: what the checkout already has, never a fetch. The
# remote-tracking branch is preferred when it exists, which is what scripts/backlog-status.sh
# would pick after its fetch, so the two agree once something has fetched.
default_ref() {
  local branch; branch="$("$CONFIG" default_branch)"
  if git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    echo "origin/$branch"
  else
    echo "$branch"
  fi
}

# The width to draw at: --width, else the terminal's, else 78 so a pipe has a stable default.
frame_width() {
  if [ -n "$WIDTH" ]; then echo "$WIDTH"; return; fi
  local cols=""
  if [ -t 1 ] && command -v tput >/dev/null 2>&1; then cols="$(tput cols 2>/dev/null || true)"; fi
  case "$cols" in ''|*[!0-9]*) cols=78 ;; esac
  [ "$cols" -ge 40 ] || cols=40
  echo "$cols"
}

# A frame that says why there is nothing to draw rather than printing an empty table (LS-01):
# a title, a rule, the message indented, a rule.
message_frame() { # <width> <title> <message>
  local width="$1" title="$2" message="$3" line
  local rule; rule="$(printf '%*s' "$width" '' | tr ' ' '-')"
  echo "$title"
  echo "$rule"
  while IFS= read -r line; do
    [ -n "$line" ] && echo "   $line"
  done <<EOF
$message
EOF
  echo "$rule"
}

# A failed scripts/backlog-status.sh is not an empty sprint. Given a ref that does not exist it
# reports every ticket as unfinished, so swallowing the failure would print counts and a claim
# command for tickets that already landed - a frame that reads as project state while being
# false. Say what failed, print no figures, and exit non-zero.
error_frame() {
  local width="$1" ref="$2" message="$3" line
  local rule; rule="$(printf '%*s' "$width" '' | tr ' ' '-')"
  echo "TICKET LOOP  backlog-status.sh failed"
  echo "$rule"
  echo " The ref it was given: $ref"
  while IFS= read -r line; do
    [ -n "$line" ] && echo "   $line"
  done <<EOF
$message
EOF
  echo "$rule"
  echo " Fix the ref, or drop --ref to judge done against the default branch."
}

# The renderer: one perl program for every view (LS-01). It reads the mode, the width, and the
# data scripts/backlog-status.sh printed out of the environment, so no temp files are needed and
# the views cannot drift apart. A quoted heredoc, so nothing here is expanded by bash.
RENDER_PERL="$(cat <<'PERL'
use strict; use warnings;
use Encode qw(decode);
binmode STDOUT, ":encoding(UTF-8)";
my $d = sub { my $v = shift; return defined $v ? decode("UTF-8", $v) : "" };
my $width = $d->($ENV{TUI_WIDTH}) + 0;
my $mode = $d->($ENV{TUI_MODE});
my $ELL = "\x{2026}";
my $rule = "-" x $width;

# Cuts a string to a width, marking the cut with an ellipsis rather than splitting a character
# or a figure in half.
my $cut = sub {
  my ($t, $w) = @_;
  $t = "" unless defined $t;
  return $t if length($t) <= $w;
  return substr($t, 0, $w) if $w <= 1;
  return substr($t, 0, $w - 1) . $ELL;
};
# Pads to a width (never truncates; the caller cuts first).
my $pad = sub { my ($t, $w) = @_; $t = "" unless defined $t; return $t . (" " x ($w - length($t))) if length($t) < $w; return $t };
# The same, right-aligned, for the sprint position.
my $rpad = sub { my ($t, $w) = @_; $t = "" unless defined $t; return (" " x ($w - length($t))) . $t if length($t) < $w; return $t };
# Every line is cut to the frame's width on the way out, so a column that will not fit is a
# layout choice and never a line that runs past the terminal (LS-01).
my $emit = sub { for my $line (@_) { print $cut->($line, $width), "\n" } };

# ---- the stories view: every story, its derived status, its tickets, its epic (LS-01) ----
if ($mode eq "stories") {
  my (@rows, $summary);
  for my $line (split /\n/, $d->($ENV{TUI_STORIES})) {
    if ($line =~ /^stories: (.*)$/) { $summary = $1; next }
    next if $line =~ /^\s*$/;
    # id, status, tickets, epic, title - tab-separated by --plain, so nothing arrives cut.
    my @f = split /\t/, $line, -1;
    next unless @f >= 5;
    push @rows, { id => $f[0], status => $f[1], tickets => $f[2], epic => $f[3], title => $f[4] };
  }
  $summary = "" unless defined $summary;
  $summary =~ s/, / - /g;
  # The epic is the one field that has to share the width: it is printed whole when the frame can
  # hold the longest one and cut only when it cannot, so a 200-column frame shows the epic a
  # 78-column one has to shorten. The title takes what is left, and the ticket count gives way
  # before the status does - the status is what the view is for.
  my %w = (id => 8, status => 11, t => 2);
  my @keep = qw(id status t);
  my $lead = 1;
  my $fixed = $lead + 1;   # the lead, and the space before the title
  $fixed += $w{$_} + 1 for @keep;
  my $MIN_TITLE = 20;
  my $MIN_EPIC = 8;
  while ($width - $fixed < $MIN_TITLE + $MIN_EPIC) {
    my $dropped = 0;
    for my $c (qw(t status)) {
      next unless grep { $_ eq $c } @keep;
      @keep = grep { $_ ne $c } @keep;
      $fixed -= $w{$c} + 1;
      $dropped = 1;
      last;
    }
    last unless $dropped;
  }
  my $longest = 0;
  for my $r (@rows) { $longest = length($r->{epic}) if length($r->{epic}) > $longest }
  my $epic_w = $longest;
  my $room = $width - $fixed - $MIN_TITLE;
  $epic_w = $room if $epic_w > $room;
  $epic_w = $MIN_EPIC if $epic_w < $MIN_EPIC;
  my $title_w = $width - $fixed - $epic_w;
  $title_w = $MIN_TITLE if $title_w < $MIN_TITLE;
  my $has = sub { my $c = shift; return scalar grep { $_ eq $c } @keep };
  my @out;
  push @out, "STORIES  $summary";
  push @out, $rule;
  my $head = " ";
  $head .= $pad->("id", $w{id}) . " " if $has->("id");
  $head .= $pad->("status", $w{status}) . " " if $has->("status");
  $head .= $pad->("t", $w{t}) . " " if $has->("t");
  $head .= $pad->("epic", $epic_w) . " title";
  push @out, $head;
  for my $r (@rows) {
    my $line = " ";
    $line .= $pad->($r->{id}, $w{id}) . " " if $has->("id");
    $line .= $pad->($r->{status}, $w{status}) . " " if $has->("status");
    $line .= $pad->($r->{tickets}, $w{t}) . " " if $has->("t");
    $line .= $pad->($cut->($r->{epic}, $epic_w), $epic_w) . " ";
    $line .= $cut->($r->{title}, $title_w);
    push @out, $line;
  }
  push @out, $rule;
  push @out, " e epic filter   d hide unticketed   r refresh   q quit";
  $emit->(@out);
  exit 0;
}

# ---- the open view: what the sprint does not hold, by section (LS-01) ----
if ($mode eq "open") {
  my (@rows, $summary);
  for my $line (split /\n/, $d->($ENV{TUI_OPEN})) {
    if ($line =~ /^open: (.*)$/) { $summary = $1; next }
    next if $line =~ /^\s*$/;
    # section, id, state, ready, blockers, serves, title - one row per ticket, so the section is
    # a field rather than a heading and the renderer does the grouping.
    my @f = split /\t/, $line, -1;
    next unless @f >= 7;
    # The state column holds one word, as the dashboard's does: a `blocked <reason>` claim is
    # prose, and in a table cell it would either be cut to "blocked…" or push every column after
    # it. The reason is the show view's business.
    my $state = $f[2];
    $state =~ s/^([A-Za-z]+).*/$1/;
    push @rows, { section => $f[0], id => $f[1], state => $state, ready => $f[3],
                  blocked => $f[4], serves => $f[5], title => $f[6] };
  }
  $summary = "" unless defined $summary;
  my $note = $summary =~ /\((sprint: .*|no sprint set)\)/ ? " ($1)" : "";
  # The columns give way in this order when the frame is narrow: the story each serves first,
  # then the blockers, then readiness, then the state - leaving the id and the title, which are
  # what a section list is for. The indent is deeper than the dashboard's because a row sits
  # under its section.
  my %w = (id => 7, state => 9, ready => 6, blocked => 17, serves => 10);
  my @keep = qw(id state ready blocked serves);
  my $lead = 3;
  my $fixed = $lead;
  $fixed += $w{$_} + 1 for @keep;
  my $MIN_TITLE = 20;
  while ($width - $fixed < $MIN_TITLE) {
    my $dropped = 0;
    for my $c (qw(serves blocked ready state)) {
      next unless grep { $_ eq $c } @keep;
      @keep = grep { $_ ne $c } @keep;
      $fixed -= $w{$c} + 1;
      $dropped = 1;
      last;
    }
    last unless $dropped;
  }
  my $title_w = $width - $fixed;
  $title_w = $MIN_TITLE if $title_w < $MIN_TITLE;
  my $has = sub { my $c = shift; return scalar grep { $_ eq $c } @keep };
  my @out;
  push @out, "OPEN  " . scalar(@rows) . " ticket(s) outside the sprint$note";
  push @out, $rule;
  if (!@rows) {
    push @out, " The sprint holds every open ticket, so there is nothing outside it to list.";
  } else {
    my $head = "   ";
    $head .= $pad->("id", $w{id}) . " " if $has->("id");
    $head .= $pad->("state", $w{state}) . " " if $has->("state");
    $head .= $pad->("ready", $w{ready}) . " " if $has->("ready");
    $head .= $pad->("blocked", $w{blocked}) . " " if $has->("blocked");
    $head .= $pad->("serves", $w{serves}) . " " if $has->("serves");
    $head .= "title";
    push @out, $head;
    my $last;
    for my $r (@rows) {
      if (!defined $last || $r->{section} ne $last) { push @out, " $r->{section}"; $last = $r->{section} }
      my $line = "   ";
      $line .= $pad->($r->{id}, $w{id}) . " " if $has->("id");
      $line .= $pad->($r->{state}, $w{state}) . " " if $has->("state");
      $line .= $pad->($r->{ready} ne "" ? $r->{ready} : "-", $w{ready}) . " " if $has->("ready");
      $line .= $pad->($cut->($r->{blocked}, $w{blocked} - 1), $w{blocked}) . " " if $has->("blocked");
      $line .= $pad->($r->{serves} ne "" ? $r->{serves} : "-", $w{serves}) . " " if $has->("serves");
      $line .= $cut->($r->{title}, $title_w);
      push @out, $line;
    }
  }
  push @out, $rule;
  push @out, " o sprint   s stories   r refresh   q quit";
  $emit->(@out);
  exit 0;
}

# ---- the show view: one ticket or story in full (LS-01) ----
if ($mode eq "show") {
  my @lines = split /\n/, $d->($ENV{TUI_SHOW});
  # scripts/backlog-status.sh --show prints the heading first, with its `### `: that heading is
  # the frame's title here, and the rest - the ticket's text, then its `state:` and `serves:`
  # lines, or a story's `status:` and `ticket:` lines - is printed as it came, cut to the width.
  my $title = shift @lines;
  $title = "" unless defined $title;
  $title =~ s/^#+\s*//;
  my @out;
  push @out, $title;
  push @out, $rule;
  push @out, @lines;
  push @out, $rule;
  push @out, " ? help   o open   s stories   r refresh   q quit";
  $emit->(@out);
  exit 0;
}

# ---- the dashboard (LK-01) ----
my $project = $d->($ENV{TUI_PROJECT});
my $branch = $d->($ENV{TUI_BRANCH});
my $sha = $d->($ENV{TUI_SHA});
my $max = $d->($ENV{TUI_MAX}) + 0;
# What scripts/backlog-status.sh --next names when nothing in the sprint is ready; empty
# whenever the sprint answered for itself.
my $next_id = $d->($ENV{TUI_NEXT});

# ---- the sprint rows, parsed out of the table scripts/backlog-status.sh printed ----
my @rows;
my $text = $d->($ENV{TUI_SPRINT});
my @lines = split /\n/, $text;
my $has_table = (@lines && $lines[0] =~ /^id\s+state\s/);
if ($has_table) {
  shift @lines;
  for my $line (@lines) {
    next if $line =~ /^\s*$/ || $line =~ /^sprint: /;
    my ($id) = $line =~ /^(\S+)/;
    next unless defined $id;
    # The id column is 6 wide; a longer id pushes the state right by the difference.
    my $pos = (length($id) > 6 ? length($id) : 6) + 1;
    my $rest = substr($line, $pos);
    # The state runs up to the date column. Finding that boundary by the first date-or-dash
    # is not enough: a `blocked <reason>` claim can hold a date of its own ("blocked until
    # 2026-10-01 response") or a lone dash ("blocked owner - waiting"), and splitting there
    # shifts every column after it. So each candidate boundary is tested against the fixed
    # columns that follow the date - the date, the short sha, `ready`, the sprint position -
    # and the first whose tail holds is the real boundary.
    my @starts;
    while ($rest =~ /(?=(?:\d{4}-\d{2}-\d{2}|-) )/g) { push @starts, $-[0] }
    my ($state, $after) = ("", "");
    for my $start (@starts) {
      my $cand = substr($rest, 0, $start);
      my $tail = substr($rest, $start);
      next if length($tail) < 33;
      my ($d10, $h8, $r6, $p6) = (substr($tail, 0, 10), substr($tail, 11, 8),
                                  substr($tail, 20, 6), substr($tail, 27, 6));
      s/\s+$// for ($d10, $h8, $r6, $p6);
      next unless $d10 =~ /^(?:\d{4}-\d{2}-\d{2}|-)$/;
      next unless $h8 =~ /^(?:[0-9a-f]{6,40}|-)$/;
      next unless $r6 =~ /^(?:yes)?$/;
      next unless $p6 =~ /^[0-9]*$/;
      $state = $cand; $after = $tail; last;
    }
    if ($after eq "") {
      # Nothing validated: fall back to the first candidate, or to the first word.
      my $start = @starts ? $starts[0] : length($rest);
      $state = substr($rest, 0, $start);
      $after = substr($rest, $start);
      $state =~ s/\s.*$// if !@starts;
    }
    $state =~ s/\s+$//;
    $after =~ s/^ +//;
    my $ready = substr($after, 20, 6); $ready =~ s/\s+$//;
    my $spos = substr($after, 27, 6); $spos =~ s/\s+$//;
    my $blocked = substr($after, 34, 22); $blocked =~ s/\s+$//;
    my $title = substr($after, 57); $title =~ s/^\s+//;
    $title = "" unless defined $title;
    # The state column holds one word. A `blocked <reason>` claim and a `done (was
    # doing)` both carry prose that belongs in the show view, not in a table cell.
    $state =~ s/^([A-Za-z]+).*/$1/;
    push @rows, { id => $id, state => $state, ready => $ready, blocked => $blocked,
                  title => $title, pos => $spos };
  }
}
my $sprint_empty = !$has_table;

# ---- the counts, from the scripts' own summary lines ----
my ($n_total, $n_done, $n_ready, $n_claimed, $n_blocked) = (0, 0, 0, 0, 0);
if ($d->($ENV{TUI_SPRINT}) =~ /^sprint: (\d+) ticket\(s\), (\d+) done, (\d+) ready, (\d+) claimed or doing, (\d+) blocked or waiting/m) {
  ($n_total, $n_done, $n_ready, $n_claimed, $n_blocked) = ($1, $2, $3, $4, $5);
}
my $outside = "0";
if ($d->($ENV{TUI_OPEN}) =~ /^open: (\d+) ticket/) { $outside = $1 }
my $stories = $d->($ENV{TUI_STORIES});
# Every story, not the ticketed ones: the summary counts the whole product backlog, and the
# stories view is where the unticketed ones are named.
$stories = "none configured" unless $stories =~ /^stories: /;

# ---- the columns: each is a fixed width, and the widest ones go first when the width
#      cannot hold the title. A column width includes the single space after it. ----
my @keep = qw(idx id state ready blocked title);
my %w = (idx => 4, id => 7, state => 9, ready => 6, blocked => 17);
my $lead = 1;
my $fixed = $lead + $w{idx} + $w{id} + $w{state} + $w{ready} + $w{blocked};
my $MIN_TITLE = 20;
while ($width - $fixed < $MIN_TITLE) {
  my $dropped = 0;
  for my $c (qw(blocked ready state)) {
    next unless grep { $_ eq $c } @keep;
    @keep = grep { $_ ne $c } @keep;
    $fixed -= $w{$c};
    $dropped = 1;
    last;
  }
  last unless $dropped;
}
my $title_w = $width - $fixed;
$title_w = 8 if $title_w < 8;
my $has = sub { my $c = shift; return scalar grep { $_ eq $c } @keep };
my $cell = sub { my ($t, $c) = @_; return $pad->($t, $w{$c} - 1) . " " };

# The header names the project, the branch and commit, and the sprint counts. It gives
# up the branch and then shortens the project name rather than cutting a figure in half.
my $counts = "$n_total in sprint: $n_done done $n_ready ready $n_claimed claimed";
my $head_full = "TICKET LOOP  $project  $branch\@$sha   $counts";
my $head_short = "TICKET LOOP  $project   $counts";
my $head_bare = "TICKET LOOP   $counts";
my $header;
if (length($head_full) <= $width) { $header = $head_full }
elsif (length($head_short) <= $width) { $header = $head_short }
elsif (length($head_bare) <= $width) { $header = $head_bare }
else {
  my $room = $width - length("TICKET LOOP     $counts");
  $header = "TICKET LOOP  " . $cut->($project, $room > 3 ? $room : 3) . "   $counts";
}

my @out;
push @out, $header;
push @out, "-" x $width;
push @out, " SPRINT";
if ($sprint_empty || !@rows) {
  push @out, "   (no sprint set - put sprint = [\"AB-01\", ...] in .loop.toml)";
} else {
  my $head = " ";
  $head .= $rpad->("#", $w{idx} - 1) . " " if $has->("idx");
  $head .= $cell->("id", "id") if $has->("id");
  $head .= $cell->("state", "state") if $has->("state");
  $head .= $cell->("ready", "ready") if $has->("ready");
  $head .= $cell->("blocked", "blocked") if $has->("blocked");
  $head .= "title";
  push @out, $head;
  my $shown = 0;
  for my $r (@rows) {
    if ($shown >= $max) { last }
    my $line = " ";
    $line .= $rpad->($r->{pos} ne "" ? $r->{pos} : "-", $w{idx} - 1) . " " if $has->("idx");
    $line .= $cell->($r->{id}, "id") if $has->("id");
    $line .= $cell->($cut->($r->{state}, $w{state} - 1), "state") if $has->("state");
    $line .= $cell->($r->{ready} ne "" ? $r->{ready} : "-", "ready") if $has->("ready");
    $line .= $cell->($cut->($r->{blocked}, $w{blocked} - 1), "blocked") if $has->("blocked");
    $line .= $cut->($r->{title}, $title_w);
    push @out, $line;
    $shown++;
  }
  push @out, "   " . $ELL . "  (" . (scalar(@rows) - $shown) . " more)" if scalar(@rows) > $shown;
}
push @out, "-" x $width;

# ---- NEXT: what scripts/backlog-status.sh --next names. That script takes the first ready
#      ticket in sprint order and falls back to file order, so when the sprint holds nothing
#      ready it still names a ticket; the frame has to say the same thing it would. ----
my ($next) = grep { $_->{ready} eq "yes" } @rows;
my $target = $next_id ne "" ? $next_id : ($next ? $next->{id} : "");
if ($target ne "") {
  my $row = ($next && $next->{id} eq $target) ? $next : undef;
  my $title = $row ? $row->{title} : "(outside the sprint)";
  push @out, " NEXT  $target  " . $cut->($title, $width - 8 - length($target));
  # The claim command is the headline output of the frame, so it is never cut: it loses its
  # indent first, and wraps at the script name if even that will not fit.
  my $cmd = "scripts/open-ticket-pr.sh $target --claim";
  if (length("       -> $cmd") <= $width) { push @out, "       -> $cmd" }
  elsif (length($cmd) <= $width) { push @out, $cmd }
  else {
    push @out, " -> scripts/open-ticket-pr.sh";
    push @out, "    $target --claim";
  }
} else {
  push @out, " NEXT  nothing ready - every ticket is done, claimed, or waiting on a blocker";
}
push @out, "-" x $width;
# The summary lines give up their tail, clause by clause, rather than being cut across a
# figure: at a narrow width the count of what sits outside the sprint goes first.
my $left = " LEFT  $n_ready ready  $n_claimed claimed  $n_blocked blocked   outside the sprint: $outside open tickets";
$left = " LEFT  $n_ready ready  $n_claimed claimed  $n_blocked blocked   outside: $outside open" if length($left) > $width;
$left = " LEFT  $n_ready ready  $n_claimed claimed  $n_blocked blocked" if length($left) > $width;
$left = " LEFT  $n_ready ready  $n_claimed claimed" if length($left) > $width;
push @out, $left;
my $story_text = $stories =~ /^stories: (.*)$/ ? $1 : $stories;
$story_text =~ s/, / - /g;
push @out, " STORIES  $story_text";
push @out, "-" x $width;
push @out, " ? help   <sp> show   a add   x remove   r refresh   q quit";

$emit->(@out);
PERL
)"

# Gathers the mode's data from the loop's own scripts and draws its frame. The dashboard makes
# three calls, and a fourth only when the sprint has no ready ticket; each view makes one.
render() {
  local ref="$1" width="$2"
  local backlog project branch sha
  # scripts/backlog-status.sh joins the configured ticket file to its own root, which is the
  # kit's wherever the frame is run; name the file outright so the frame describes the project
  # it is run in. The product backlog needs no such help: that script resolves it against the
  # working tree's top level, which is the project.
  backlog="$ROOT/$("$CONFIG" backlog)"
  # Nothing to draw from: say which file is missing rather than print an empty table (LS-01).
  if [ ! -f "$backlog" ]; then
    message_frame "$width" "TICKET LOOP  no ticket file" "The ticket file .loop.toml names is not there:
  $backlog
Write one (the grill-project prompt does) or point backlog at it."
    return 0
  fi
  project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
  sha="$(git rev-parse --short HEAD 2>/dev/null || echo '-')"
  local sprint="" open_line="" stories_line="" next_id="" show_out="" sprint_out stories_file
  case "$MODE" in
    dashboard)
      # The rows and the counts come from --sprint, so a failure there is not "no tickets in the
      # sprint": keep the message and draw an error frame rather than a false one.
      if sprint_out="$("$STATUS" --sprint --ref "$ref" --backlog "$backlog" 2>&1)"; then
        sprint="$sprint_out"
      else
        error_frame "$width" "$ref" "$sprint_out"
        return 1
      fi
      # --local on the two calls that never look at a ticket's state: neither the count of what
      # is outside the sprint nor a story's derived status depends on a claim, and --local skips
      # the git ls-remote that the claim lookup would run against origin.
      open_line="$("$STATUS" --open --ref "$ref" --local --backlog "$backlog" 2>/dev/null | tail -1 || true)"
      stories_line="$("$STATUS" --stories --ref "$ref" --local --backlog "$backlog" 2>/dev/null | tail -1 || true)"
      # NEXT follows --next, which falls back to file order when nothing in the sprint is ready:
      # a ticket outside the sprint is still the ticket to work, and the dashboard must not call
      # that "nothing ready". Ask only in that case - the call resolves claims against origin,
      # and a sprint that holds a ready ticket already answers.
      local ready_count
      ready_count="$(printf '%s\n' "$sprint" | sed -n 's/.*, \([0-9][0-9]*\) ready,.*/\1/p' | tail -1)"
      if [ -z "$ready_count" ] || [ "$ready_count" = 0 ]; then
        next_id="$("$STATUS" --next --ref "$ref" --backlog "$backlog" 2>/dev/null | tail -1 || true)"
      fi
      ;;
    stories)
      # A product backlog .loop.toml names but the checkout does not have is "none configured",
      # not a failure: say so rather than print an empty table (LS-01).
      stories_file="$ROOT/$("$CONFIG" stories)"
      if [ ! -f "$stories_file" ]; then
        message_frame "$width" "STORIES  none configured" "The product backlog .loop.toml names is not there:
  $stories_file
Write one, or point stories at it."
        return 0
      fi
      if ! stories_line="$("$STATUS" --stories --ref "$ref" --local --plain --backlog "$backlog" 2>&1)"; then
        message_frame "$width" "STORIES  backlog-status.sh failed" "$stories_line"
        return 1
      fi
      ;;
    open)
      # No --local here: a row's state is one of the things this view is for, and a claimed
      # ticket outside the sprint should say so.
      if ! open_line="$("$STATUS" --open --ref "$ref" --plain --backlog "$backlog" 2>&1)"; then
        message_frame "$width" "OPEN  backlog-status.sh failed" "$open_line"
        return 1
      fi
      ;;
    show)
      if ! show_out="$("$STATUS" --show "$WANT" --ref "$ref" --backlog "$backlog" 2>&1)"; then
        message_frame "$width" "SHOW  $WANT" "$show_out"
        return 1
      fi
      ;;
  esac
  TUI_MODE="$MODE" TUI_WIDTH="$width" TUI_PROJECT="$project" TUI_BRANCH="$branch" TUI_SHA="$sha" \
  TUI_SPRINT="$sprint" TUI_OPEN="$open_line" TUI_STORIES="$stories_line" TUI_NEXT="$next_id" \
  TUI_SHOW="$show_out" TUI_MAX="$MAX_ROWS" \
    perl -e "$RENDER_PERL"
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loop-tui.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR"
  local me="$SCRIPT_ROOT/scripts/loop-tui.sh"
  # A fixture project: a bare origin, a checkout with a done, a claimed, a blocked, and a ready
  # ticket, a sprint over them, and a product backlog with a story a ticket serves, a story
  # nothing serves, and a story whose ticket has landed. The tickets sit in two sections so the
  # open view has something to group.
  (
    cd "$dir"
    git init -q --bare origin.git
    git clone -q origin.git work 2>/dev/null
    cd work
    git config user.email "self-test@example.com"; git config user.name "self-test"
    # Fixed commit dates make the history, and so the short sha the header carries,
    # reproducible: the golden frames are compared byte for byte and cannot hold a moving sha.
    export GIT_AUTHOR_DATE="2026-01-02T03:04:05+00:00" GIT_COMMITTER_DATE="2026-01-02T03:04:05+00:00"
    git checkout -q -b main
    cat > BACKLOG.md <<'EOF'
# Fixture queue

## Alpha

### AA-01 A ticket that landed
Body. Serves BB-3.
**Done when:** it lands.

### AA-02 A ticket someone holds
Body.
**Done when:** it lands.

### AA-03 A ticket waiting on someone else
Body.
**Done when:** the blocker lands.

### AA-04 A ticket ready to start — Blocked by AA-01
Body. Serves BB-1.
**Done when:** it lands.

## Beta

### AA-05 A ticket behind an unlanded blocker — Blocked by AA-03
Body.
**Done when:** the blocker lands.
EOF
    # The epic is long on purpose: it is what a 78-column stories frame has to shorten and a
    # 200-column one has to print whole.
    cat > PRODUCT.md <<'EOF'
# Fixture product backlog

## Epic F: Data inventory, coverage and the release ledger

### BB-1 — A story a ticket serves

**Status:** Proposed

### BB-2 — A story nothing serves yet

**Status:** Proposed

### BB-3 — A story whose ticket landed

**Status:** Complete
EOF
    printf '[loop]\ndefault_branch = "main"\nsprint = ["AA-01", "AA-02", "AA-03", "AA-04", "AA-05"]\nstories = "PRODUCT.md"\n' > .loop.toml
    # Two more configurations: one whose sprint holds a single done ticket, so NEXT has to fall
    # back to file order, and one whose sprint leaves tickets outside it, so the open view has
    # something to group. The stories and show views do not read the sprint.
    printf '[loop]\ndefault_branch = "main"\nsprint = ["AA-01"]\nstories = "PRODUCT.md"\n' > outside.toml
    printf '[loop]\ndefault_branch = "main"\nsprint = ["AA-01"]\nstories = "NOSTORIES.md"\n' > nostories.toml
    git add -A
    git commit -q -m "Scaffold"
    git commit -q --allow-empty -m "AA-01: the first ticket landed"
    git push -q -u origin main 2>/dev/null
    # AA-02 is claimed: a ticket/<id> branch on origin.
    git push -q origin "HEAD:refs/heads/ticket/AA-02" 2>/dev/null
    # AA-03 carries a `blocked <reason>` claim, which makes its state wider than its column, and
    # the reason holds a date of its own - the case a parse that splits at the first date gets
    # wrong, shifting every column after it.
    perl -i -pe 's/^### AA-03 (.*)$/### AA-03 $1 — `blocked until 2026-10-01 response`/' BACKLOG.md
    git add -A; git commit -q -m "Backlog: AA-03 is blocked"
  )
  local work="$dir/work"

  # LOOP_TUI_GOLDEN=1 prints the frames the golden heredocs below are cut from, so they can be
  # regenerated after a deliberate layout change instead of guessed at.
  if [ -n "${LOOP_TUI_GOLDEN:-}" ]; then
    local gw
    for gw in 60 78 200; do
      printf '===== dashboard %s =====\n' "$gw"
      (cd "$work" && LOOP_ROOT="$work" "$me" --width "$gw")
    done
    printf '===== stories 78 =====\n'
    (cd "$work" && LOOP_ROOT="$work" "$me" stories --width 78)
    printf '===== open 78 =====\n'
    (cd "$work" && LOOP_CONFIG="$work/outside.toml" LOOP_ROOT="$work" "$me" open --width 78)
    printf '===== show AA-04 78 =====\n'
    (cd "$work" && LOOP_ROOT="$work" "$me" show AA-04 --width 78)
    printf '===== show BB-1 78 =====\n'
    (cd "$work" && LOOP_ROOT="$work" "$me" show BB-1 --width 78)
    exit 0
  fi

  # 1. The dashboard at 78 columns, asserted by named line.
  local out
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" --width 78 2>&1)"
  echo "$out" | grep -q '^TICKET LOOP  work  main@.*   5 in sprint: 1 done 1 ready 1 claimed$' \
    || { echo "self-test: the header is off:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^   1 AA-01  done' || { echo "self-test: the done ticket's row is off:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'AA-02  claimed' || { echo "self-test: the claimed ticket should show as claimed:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'AA-03  blocked' || { echo "self-test: the blocked ticket should show as blocked:"; echo "$out"; exit 1; }
  # AA-03's claim is wider than its column and holds a date of its own, so these two rows prove
  # the parse found the real column boundary: AA-03 keeps its own columns, and AA-05 - the row
  # after it - keeps its blocker and its own state.
  echo "$out" | grep -qE '^   3 AA-03  blocked  - +A ticket waiting on someone else$' \
    || { echo "self-test: a date inside the blocked reason shifted AA-03's own row:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'AA-05  todo     -     AA-03!' || { echo "self-test: the row after a long state should stay aligned:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^ NEXT  AA-04' || { echo "self-test: NEXT should be the first ready ticket:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^       -> scripts/open-ticket-pr.sh AA-04 --claim$' \
    || { echo "self-test: the claim command is off:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^ LEFT  1 ready  1 claimed  2 blocked   outside the sprint: 0 open tickets$' \
    || { echo "self-test: the LEFT counts are off:"; echo "$out"; exit 1; }
  # Every story, not the ticketed ones: three stories, one of which nothing serves.
  echo "$out" | grep -q '^ STORIES  3 - 1 done - 1 open - 1 unticketed$' \
    || { echo "self-test: the stories line should count every story:"; echo "$out"; exit 1; }

  # 2. Every line fits the width; a narrower frame drops the blocked column. The width is
  #    counted in characters, as the renderer draws them, not in the bytes the ellipsis takes.
  local w line n
  for w in 40 60 78 200; do
    out="$(cd "$work" && LOOP_ROOT="$work" "$me" --width "$w" 2>&1)"
    while IFS= read -r line; do
      n="$(printf '%s' "$line" | perl -CS -ne 'chomp; print length($_)')"
      [ "$n" -le "$w" ] || { echo "self-test: a line is $n wide at width $w:"; echo "$line"; exit 1; }
    done <<EOF
$out
EOF
  done
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" --width 60 2>&1)"
  echo "$out" | grep -q 'ready blocked' && { echo "self-test: 60 columns should drop the blocked column:"; echo "$out"; exit 1; }
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" --width 78 2>&1)"
  echo "$out" | grep -q 'ready blocked' || { echo "self-test: 78 columns should keep the blocked column:"; echo "$out"; exit 1; }
  # The claim command is the headline output of the frame, so at the 40-column floor it gives up
  # its indent rather than being cut into an unrunnable "scripts/open-ticket-pr.sh AA-…".
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" --width 40 2>&1)"
  echo "$out" | grep -q '^scripts/open-ticket-pr.sh AA-04 --claim$' \
    || { echo "self-test: 40 columns cut the claim command:"; echo "$out"; exit 1; }
  # 3. At 200 columns the titles stop being cut.
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" --width 200 2>&1)"
  echo "$out" | grep -q 'A ticket behind an unlanded blocker$' \
    || { echo "self-test: 200 columns should print a title in full:"; echo "$out"; exit 1; }

  # 4. The frames are frozen. A layout change has to be deliberate: run the self-test with
  #    LOOP_TUI_GOLDEN=1 to print these frames again and paste them back, rather than letting
  #    the screen drift unnoticed.
  local golden60 golden78 golden200
  golden60="$(cat <<'G60'
TICKET LOOP  work   5 in sprint: 1 done 1 ready 1 claimed
------------------------------------------------------------
 SPRINT
   # id     state    ready title
   1 AA-01  done     -     A ticket that landed
   2 AA-02  claimed  -     A ticket someone holds
   3 AA-03  blocked  -     A ticket waiting on someone else
   4 AA-04  todo     yes   A ticket ready to start
   5 AA-05  todo     -     A ticket behind an unlanded bloc…
------------------------------------------------------------
 NEXT  AA-04  A ticket ready to start
       -> scripts/open-ticket-pr.sh AA-04 --claim
------------------------------------------------------------
 LEFT  1 ready  1 claimed  2 blocked   outside: 0 open
 STORIES  3 - 1 done - 1 open - 1 unticketed
------------------------------------------------------------
 ? help   <sp> show   a add   x remove   r refresh   q quit
G60
)"
  golden78="$(cat <<'G78'
TICKET LOOP  work  main@8671246   5 in sprint: 1 done 1 ready 1 claimed
------------------------------------------------------------------------------
 SPRINT
   # id     state    ready blocked          title
   1 AA-01  done     -                      A ticket that landed
   2 AA-02  claimed  -                      A ticket someone holds
   3 AA-03  blocked  -                      A ticket waiting on someone else
   4 AA-04  todo     yes   AA-01            A ticket ready to start
   5 AA-05  todo     -     AA-03!           A ticket behind an unlanded block…
------------------------------------------------------------------------------
 NEXT  AA-04  A ticket ready to start
       -> scripts/open-ticket-pr.sh AA-04 --claim
------------------------------------------------------------------------------
 LEFT  1 ready  1 claimed  2 blocked   outside the sprint: 0 open tickets
 STORIES  3 - 1 done - 1 open - 1 unticketed
------------------------------------------------------------------------------
 ? help   <sp> show   a add   x remove   r refresh   q quit
G78
)"
  golden200="$(cat <<'G200'
TICKET LOOP  work  main@8671246   5 in sprint: 1 done 1 ready 1 claimed
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 SPRINT
   # id     state    ready blocked          title
   1 AA-01  done     -                      A ticket that landed
   2 AA-02  claimed  -                      A ticket someone holds
   3 AA-03  blocked  -                      A ticket waiting on someone else
   4 AA-04  todo     yes   AA-01            A ticket ready to start
   5 AA-05  todo     -     AA-03!           A ticket behind an unlanded blocker
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 NEXT  AA-04  A ticket ready to start
       -> scripts/open-ticket-pr.sh AA-04 --claim
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 LEFT  1 ready  1 claimed  2 blocked   outside the sprint: 0 open tickets
 STORIES  3 - 1 done - 1 open - 1 unticketed
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 ? help   <sp> show   a add   x remove   r refresh   q quit
G200
)"
  local gw got want
  for gw in 60 78 200; do
    got="$(cd "$work" && LOOP_ROOT="$work" "$me" --width "$gw" 2>&1)"
    case "$gw" in
      60) want="$golden60" ;;
      78) want="$golden78" ;;
      200) want="$golden200" ;;
    esac
    if [ "$got" != "$want" ]; then
      echo "self-test: the dashboard at $gw columns no longer matches its golden:"
      printf '%s\n' "$want" > "$dir/want.txt"
      printf '%s\n' "$got" > "$dir/got.txt"
      diff "$dir/want.txt" "$dir/got.txt" || true
      exit 1
    fi
  done

  # 5. When nothing in the sprint is ready, NEXT follows --next, which falls back to file order:
  #    the ticket to work sits outside the sprint, and the frame names it and its claim command
  #    rather than saying "nothing ready" while the loop would hand you a ticket.
  printf '[loop]\ndefault_branch = "main"\nsprint = ["AA-01"]\nstories = "PRODUCT.md"\n' > "$work/done-only.toml"
  out="$(cd "$work" && LOOP_CONFIG="$work/done-only.toml" LOOP_ROOT="$work" "$me" --width 78 2>&1)"
  echo "$out" | grep -q '^ NEXT  AA-04  (outside the sprint)$' \
    || { echo "self-test: NEXT should fall back to the ticket outside the sprint:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^       -> scripts/open-ticket-pr.sh AA-04 --claim$' \
    || { echo "self-test: the fallback claim command is off:"; echo "$out"; exit 1; }

  # 6. A failed scripts/backlog-status.sh is an error, not an empty sprint. A ref that does not
  #    exist makes it report every ticket as unfinished; rendered, that would print counts and a
  #    claim command for a ticket that already landed.
  if out="$(cd "$work" && LOOP_ROOT="$work" "$me" --width 78 --ref nosuchref 2>&1)"; then
    echo "self-test: a --ref that does not exist must exit non-zero:"; echo "$out"; exit 1
  fi
  echo "$out" | grep -q '^TICKET LOOP  backlog-status.sh failed$' \
    || { echo "self-test: a failed run should say what failed:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'AA-04 --claim' && { echo "self-test: a failed run must not print a claim command:"; echo "$out"; exit 1; }

  # 7. The stories view: every story, its derived status, its ticket count, and the epic it sits
  #    under - shown whole when the frame can hold it and shortened when it cannot.
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" stories --width 78 2>&1)"
  echo "$out" | grep -q '^STORIES  3 - 1 done - 1 open - 1 unticketed$' \
    || { echo "self-test: the stories view should lead with every story counted:"; echo "$out"; exit 1; }
  echo "$out" | grep -qE '^ BB-1 +open 0/1 +1 +' || { echo "self-test: an open k/n story should show its status and its ticket count:"; echo "$out"; exit 1; }
  echo "$out" | grep -qE '^ BB-3 +done +1 +' || { echo "self-test: a story whose tickets landed should read done:"; echo "$out"; exit 1; }
  echo "$out" | grep -qE '^ BB-2 +unticketed +- +' || { echo "self-test: a story nothing serves should read unticketed:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'Epic F: Data inventory, coverage and the release ledger' \
    && { echo "self-test: 78 columns should shorten the epic:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'Epic F: Data inventory, coverag…' \
    || { echo "self-test: the shortened epic should end in an ellipsis:"; echo "$out"; exit 1; }
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" stories --width 200 2>&1)"
  echo "$out" | grep -q 'Epic F: Data inventory, coverage and the release ledger' \
    || { echo "self-test: 200 columns should print the epic in full:"; echo "$out"; exit 1; }
  # A product backlog that is not there is "none configured", not an empty table.
  out="$(cd "$work" && LOOP_CONFIG="$work/nostories.toml" LOOP_ROOT="$work" "$me" stories --width 78 2>&1)"
  echo "$out" | grep -q '^STORIES  none configured$' \
    || { echo "self-test: a checkout with no product backlog should say none configured:"; echo "$out"; exit 1; }
  echo "$out" | grep -qE '^ BB-' && { echo "self-test: none configured must not print a table:"; echo "$out"; exit 1; }

  # 8. The open view: what the sprint does not hold, grouped by section, with the blockers and
  #    the story each serves. This configuration's sprint holds AA-01 alone, so four tickets are
  #    outside it and they fall in two sections.
  out="$(cd "$work" && LOOP_CONFIG="$work/outside.toml" LOOP_ROOT="$work" "$me" open --width 78 2>&1)"
  echo "$out" | grep -q '^OPEN  4 ticket(s) outside the sprint' \
    || { echo "self-test: the open view should count what is outside the sprint:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^ Alpha$' && echo "$out" | grep -q '^ Beta$' \
    || { echo "self-test: the open view should group by section:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'AA-05.*AA-03!' \
    || { echo "self-test: an open row should carry its unmet blockers:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'AA-04.*BB-1' \
    || { echo "self-test: an open row should carry the story it serves:"; echo "$out"; exit 1; }
  # AA-01 is in the sprint, so it is not a row - though it is named as AA-04's blocker, which is
  # why this looks for a row and not for the id.
  echo "$out" | grep -q '^   AA-01' && { echo "self-test: the open view must leave out the sprint's tickets:"; echo "$out"; exit 1; }
  # A sprint that holds every open ticket is not an empty table either.
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" open --width 78 2>&1)"
  echo "$out" | grep -q '^OPEN  0 ticket(s) outside the sprint' \
    || { echo "self-test: the open view should count zero when the sprint holds everything:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'holds every open ticket' \
    || { echo "self-test: an empty open view should say why:"; echo "$out"; exit 1; }

  # 9. The show view: one ticket or story in full, with its state, its sprint position, and the
  #    story it serves - or a story's derived status and its tickets.
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" show AA-04 --width 78 2>&1)"
  # The heading is printed as it stands, claim and blockers included: it is the only place
  # --show carries the blockers, and a title that quietly dropped them would be the frame
  # hiding what the ticket says.
  echo "$out" | grep -q '^AA-04 A ticket ready to start — Blocked by AA-01$' \
    || { echo "self-test: the show view should lead with the ticket's heading:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^state: todo, ready, sprint position 4$' \
    || { echo "self-test: the show view should carry the state and the sprint position:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^serves: BB-1 — A story a ticket serves (open 0/1)$' \
    || { echo "self-test: the show view should carry the story the ticket serves:"; echo "$out"; exit 1; }
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" show BB-1 --width 78 2>&1)"
  echo "$out" | grep -q '^BB-1 — A story a ticket serves$' \
    || { echo "self-test: the show view should lead with the story's heading:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^status: open 0/1 (the file says: Proposed)$' \
    || { echo "self-test: the show view should carry the story's derived status:"; echo "$out"; exit 1; }
  echo "$out" | grep -q '^ticket: AA-04' \
    || { echo "self-test: the show view should list the tickets that serve the story:"; echo "$out"; exit 1; }
  # An id that is neither a ticket nor a story is a mistake, not a frame.
  if out="$(cd "$work" && LOOP_ROOT="$work" "$me" show AA-99 --width 78 2>&1)"; then
    echo "self-test: show of an unknown id must exit non-zero:"; echo "$out"; exit 1
  fi
  echo "$out" | grep -q 'no such ticket or story' \
    || { echo "self-test: show of an unknown id should say so:"; echo "$out"; exit 1; }

  # 10. Every view fits the width too, at every width. The stories and show views read no
  #     sprint, so the fixture's own .loop.toml serves them; the open view needs the
  #     configuration whose sprint leaves tickets outside it. One place names each invocation,
  #     so the width loop and the golden loop cannot drift from each other.
  view_frame() { # <view> <width>
    case "$1" in
      stories)     (cd "$work" && LOOP_ROOT="$work" "$me" stories --width "$2" 2>&1) ;;
      open)        (cd "$work" && LOOP_CONFIG="$work/outside.toml" LOOP_ROOT="$work" "$me" open --width "$2" 2>&1) ;;
      "show AA-04") (cd "$work" && LOOP_ROOT="$work" "$me" show AA-04 --width "$2" 2>&1) ;;
      "show BB-1")  (cd "$work" && LOOP_ROOT="$work" "$me" show BB-1 --width "$2" 2>&1) ;;
    esac
  }
  local view
  for w in 40 60 78 200; do
    for view in stories open "show AA-04" "show BB-1"; do
      out="$(view_frame "$view" "$w")"
      while IFS= read -r line; do
        # `%s\n`, not `%s`: a view prints the ticket's own blank lines, and a blank line with no
        # newline is no input at all to perl, so the width would come back empty.
        n="$(printf '%s\n' "$line" | perl -CS -ne 'chomp; print length($_)')"
        [ "$n" -le "$w" ] || { echo "self-test: the $view view is $n wide at width $w:"; echo "$line"; exit 1; }
      done <<EOF
$out
EOF
    done
  done

  local golden_stories golden_open golden_show golden_show_story
  golden_stories="$(cat <<'GS'
STORIES  3 - 1 done - 1 open - 1 unticketed
------------------------------------------------------------------------------
 id       status      t  epic                             title
 BB-1     open 0/1    1  Epic F: Data inventory, coverag… A story a ticket se…
 BB-2     unticketed  -  Epic F: Data inventory, coverag… A story nothing ser…
 BB-3     done        1  Epic F: Data inventory, coverag… A story whose ticke…
------------------------------------------------------------------------------
 e epic filter   d hide unticketed   r refresh   q quit
GS
)"
  golden_open="$(cat <<'GO'
OPEN  4 ticket(s) outside the sprint (sprint: AA-01)
------------------------------------------------------------------------------
   id      state     ready  blocked           serves     title
 Alpha
   AA-02   claimed   -                        -          A ticket someone hol…
   AA-03   blocked   -                        -          A ticket waiting on …
   AA-04   todo      ready  AA-01             BB-1       A ticket ready to st…
 Beta
   AA-05   todo      -      AA-03!            -          A ticket behind an u…
------------------------------------------------------------------------------
 o sprint   s stories   r refresh   q quit
GO
)"
  golden_show="$(cat <<'GH'
AA-04 A ticket ready to start — Blocked by AA-01
------------------------------------------------------------------------------
Body. Serves BB-1.
**Done when:** it lands.

state: todo, ready, sprint position 4
serves: BB-1 — A story a ticket serves (open 0/1)
------------------------------------------------------------------------------
 ? help   o open   s stories   r refresh   q quit
GH
)"
  golden_show_story="$(cat <<'GY'
BB-1 — A story a ticket serves
------------------------------------------------------------------------------

**Status:** Proposed

status: open 0/1 (the file says: Proposed)
ticket: AA-04  todo     A ticket ready to start
------------------------------------------------------------------------------
 ? help   o open   s stories   r refresh   q quit
GY
)"
  local vgot vwant vname
  for vname in stories open "show AA-04" "show BB-1"; do
    vgot="$(view_frame "$vname" 78)"
    case "$vname" in
      stories)      vwant="$golden_stories" ;;
      open)         vwant="$golden_open" ;;
      "show AA-04") vwant="$golden_show" ;;
      "show BB-1")  vwant="$golden_show_story" ;;
    esac
    if [ "$vgot" != "$vwant" ]; then
      echo "self-test: the $vname view at 78 columns no longer matches its golden:"
      printf '%s\n' "$vwant" > "$dir/vwant.txt"
      printf '%s\n' "$vgot" > "$dir/vgot.txt"
      diff "$dir/vwant.txt" "$dir/vgot.txt" || true
      exit 1
    fi
  done

  echo "loop-tui self-test passed"
}

case "$MODE" in
  selftest) self_test ;;
  *) render "${REF:-$(default_ref)}" "$(frame_width)" ;;
esac
