#!/usr/bin/env bash
# The loop's state as one screen (LK-01, LK-02). One renderer turns the loop's scripts' output
# into frames at a given width; this file holds the dashboard and the three views LS-01 names -
# stories, open, and show. It is split from the terminal: --render prints one frame and exits,
# --width fixes the width, and it takes no keys and writes nothing, so the interactive mode
# (LK-03) is a key handler over these frames rather than a second implementation.
#
#   scripts/loop-tui.sh                  on a terminal, the interactive mode (LK-03); anywhere
#                                        else the dashboard frame on stdout, then exit
#   scripts/loop-tui.sh --render         one dashboard frame on stdout, then exit, whatever
#                                        stdout is
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
#   scripts/loop-tui.sh --keys '<keys>'  run the key handler over these keys and print the last
#                                        frame. With it, or with a stdout that is not a terminal,
#                                        the program renders frames instead of taking the screen,
#                                        so the whole of it is driven without a pseudo-terminal
#   scripts/loop-tui.sh --self-test      a fixture repository proves every frame, by named line
#                                        and by golden frames
#
# --stories, --open, and --show <id> are the same views spelled as flags, which is how every
# other option here is written; LS-01 names the views themselves, so both spellings are here.
#
# The interactive mode (LK-03) is a key handler over the frames above, never a second renderer.
# On a terminal it takes the alternate screen, hides the cursor, and reads one key at a time; a
# trap puts the terminal back on every exit path. The keys are the ones the frames advertise:
#
#   j, k (or the arrow keys)  move the marker down and up, wrapping at either end
#   <sp>                      open the marked ticket or story in full
#   a                         add a ticket to the sprint: type its id, then Enter (Esc cancels)
#   x                         take the marked ticket out of the sprint
#   s, o                      the stories and open views; the same key again comes back
#   e, d                      in the stories view: the epic filter, and the unticketed toggle.
#                             `e` walks the epics the view holds - unfiltered, then each in the
#                             order the rows are drawn, then back - and `d` hides or shows the
#                             stories nothing serves. Both are drawn on the keybar, which names
#                             what each is set to, so a narrowed table is never a silent one.
#   r                         fetch from origin, then redraw - the only thing here that fetches
#   ?                         the key list; any of these keys again comes back
#   q                         quit
#
# Every write goes through scripts/sprint.sh and changes only the `sprint` list in .loop.toml,
# and nothing here runs git add, git commit, or git push: committing the sprint stays the owner's
# (decision 0003), so the frame carries an uncommitted marker while the change is in the working
# tree. An add is refused, with the reason on the frame, when the id is not a ticket heading, is
# already done, or is already in the sprint.
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
KEYS=""
KEYS_GIVEN=0
VIEW_GIVEN=0
RENDER_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --render) MODE=dashboard; RENDER_GIVEN=1 ;;
    stories|--stories) MODE=stories; VIEW_GIVEN=1 ;;
    open|--open) MODE=open; VIEW_GIVEN=1 ;;
    show|--show) MODE=show; WANT="${2:-}"; VIEW_GIVEN=1; [ $# -ge 2 ] && shift ;;
    --width) WIDTH="${2:-}"; shift ;;
    --ref) REF="${2:-}"; shift ;;
    --keys) KEYS="${2:-}"; KEYS_GIVEN=1; shift ;;
    --self-test) MODE=selftest ;;
    *) echo "usage: scripts/loop-tui.sh [dashboard|stories|open|show <id>] [--width <n>] [--ref <ref>] [--keys <keys>] | --self-test" >&2; exit 2 ;;
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
# Wraps a block of text to a frame's width and indents every line, so a frame drawn without the
# renderer still fits the width it was asked for - the renderer's own views wrap the same way
# (LK-02). A line that already fits is printed exactly as it came, so a frame's own spacing - the
# two spaces in a header, the alignment of a column - survives; only a longer line is wrapped. A
# word longer than the line is hard-split rather than allowed past the margin, since these
# messages carry paths.
frame_text() { # <width> <indent> <text>
  local width="$1" indent="$2" text="$3"
  printf '%s' "$text" | perl -CS -e '
    my ($width, $indent) = @ARGV;
    my $w = $width - $indent; $w = 1 if $w < 1;
    my $pad = " " x $indent;
    my $text = do { local $/; <STDIN> };
    for my $line (split /\n/, $text, -1) {
      next if $line eq "";
      if (length($line) <= $w) { print $pad, $line, "\n"; next }
      my @lines; my $cur = "";
      for my $word (split / /, $line, -1) {
        next if $word eq "";
        while (length($word) > $w) {
          push @lines, $cur if length $cur;
          $cur = "";
          push @lines, substr($word, 0, $w);
          $word = substr($word, $w);
        }
        if (!length $cur) { $cur = $word }
        elsif (length($cur) + 1 + length($word) <= $w) { $cur .= " " . $word }
        else { push @lines, $cur; $cur = $word }
      }
      push @lines, $cur if length $cur;
      print $pad, $_, "\n" for @lines;
    }
  ' "$width" "$indent"
}

# The frames drawn without the renderer, when there is nothing for it to render: a title, a rule,
# the message indented, a rule.
message_frame() { # <width> <title> <message>
  local width="$1" title="$2" message="$3"
  local rule; rule="$(printf '%*s' "$width" '' | tr ' ' '-')"
  frame_text "$width" 0 "$title"
  echo "$rule"
  frame_text "$width" 3 "$message"
  echo "$rule"
}

# A failed scripts/backlog-status.sh is not an empty sprint. Given a ref that does not exist it
# reports every ticket as unfinished, so swallowing the failure would print counts and a claim
# command for tickets that already landed - a frame that reads as project state while being
# false. Say what failed, print no figures, and exit non-zero.
error_frame() {
  local width="$1" ref="$2" message="$3"
  local rule; rule="$(printf '%*s' "$width" '' | tr ' ' '-')"
  frame_text "$width" 0 "TICKET LOOP  backlog-status.sh failed"
  echo "$rule"
  frame_text "$width" 1 "The ref it was given: $ref"
  frame_text "$width" 3 "$message"
  echo "$rule"
  frame_text "$width" 1 "Fix the ref, or drop --ref to judge done against the default branch."
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
# The state the key handler keeps, and empty in a frame drawn without it (LK-03): the row the
# marker is on, what the last key did, the mark that the sprint change is uncommitted, and the id
# being typed for `a`. Every one of them is silent when unset, so a one-shot frame is byte for
# byte what it was before the handler existed and the golden frames below still hold.
my $sel = $d->($ENV{TUI_SEL});
my $status = $d->($ENV{TUI_STATUS});
my $dirty = $d->($ENV{TUI_DIRTY});
my $prompt = $d->($ENV{TUI_PROMPT});
# The stories view's two view settings (LK-20), drawn on its keybar so a narrowed table says why
# it is narrow. Empty and 0 in every other frame and in a frame drawn without the handler, so the
# other views' keybars are unchanged.
my $epic = $d->($ENV{TUI_EPIC});
my $hide_unticketed = $d->($ENV{TUI_HIDE}) eq "1" ? 1 : 0;
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
# Wraps a string to a width, breaking at spaces and hard-splitting a word longer than the width.
# The show view prints a ticket's own text, which is routinely longer than the frame, and cutting
# it would hide the tail - a figure, an acceptance criterion, the blocker named in a heading -
# that the view exists to show (LK-02).
my $wrap = sub {
  my ($t, $w) = @_;
  $t = "" unless defined $t;
  return ($t) if $w <= 0;
  my @lines; my $cur = "";
  for my $word (split / /, $t, -1) {
    next if $word eq "";
    while (length($word) > $w) {
      push @lines, $cur if length $cur;
      $cur = "";
      push @lines, substr($word, 0, $w);
      $word = substr($word, $w);
    }
    if (!length $cur) { $cur = $word }
    elsif (length($cur) + 1 + length($word) <= $w) { $cur .= " " . $word }
    else { push @lines, $cur; $cur = $word }
  }
  push @lines, $cur if length $cur;
  push @lines, "" unless @lines;
  return @lines;
};
# Pads to a width (never truncates; the caller cuts first).
my $pad = sub { my ($t, $w) = @_; $t = "" unless defined $t; return $t . (" " x ($w - length($t))) if length($t) < $w; return $t };
# The same, right-aligned, for the sprint position.
my $rpad = sub { my ($t, $w) = @_; $t = "" unless defined $t; return (" " x ($w - length($t))) . $t if length($t) < $w; return $t };
# Every line is cut to the frame's width on the way out, so a column that will not fit is a
# layout choice and never a line that runs past the terminal (LS-01).
my $emit = sub { for my $line (@_) { print $cut->($line, $width), "\n" } };
# The lead of a row: a `>` on the row the marker is on, a space otherwise. The index handed in
# counts rows from zero and the marker counts them from one, as the sprint position does, so the
# two are compared after adding one. Same width either way, and with no selection every row is
# exactly as it was (LK-03).
my $mark = sub { my $i = shift; return ($sel ne "" && $i + 1 == $sel + 0) ? ">" : " " };
# The lines between the last rule and the keybar: the uncommitted marker, what the last key did,
# and the id being typed. All three are silent when the handler set none of them (LK-03).
my $tail = sub {
  my @t;
  push @t, " ! $dirty" if $dirty ne "";
  push @t, " ! $status" if $status ne "";
  push @t, " add ticket: $prompt" if $prompt ne "";
  return @t;
};

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
  my $i = 0;
  for my $r (@rows) {
    my $line = $mark->($i);
    $i++;
    $line .= $pad->($r->{id}, $w{id}) . " " if $has->("id");
    $line .= $pad->($r->{status}, $w{status}) . " " if $has->("status");
    $line .= $pad->($r->{tickets}, $w{t}) . " " if $has->("t");
    $line .= $pad->($cut->($r->{epic}, $epic_w), $epic_w) . " ";
    $line .= $cut->($r->{title}, $title_w);
    push @out, $line;
  }
  push @out, $tail->();
  push @out, $rule;
  # The keybar names what each of the two view settings is set to, so a narrowed table is never a
  # silent one (LK-20) - at every width the frame allows, 40 columns being the floor `frame_width`
  # enforces. The bar is wider than that floor, so it gives way in a fixed order rather than being
  # cut. The labels shorten first (`e epic: any` to `e: any`, `d unticketed: shown` to `d: shown`),
  # then the key words go (`r refresh   q quit` to `r   q`), and the epic name is cut last: it is
  # the only part of the bar still read as a name when shortened, and the label beside it has
  # already given up its room. No setting is ever stated as a label with no value, and `r` and `q`
  # are on the bar at every width - the LK-20 review measured the first version cutting `q quit`
  # off and leaving `e epic:` with nothing after it.
  my $hide_long = $hide_unticketed ? "d unticketed: hidden" : "d unticketed: shown";
  my $hide_short = $hide_unticketed ? "d: hidden" : "d: shown";
  my $value = $epic eq "" ? "any" : $epic;
  # A value needs room to be a name at all. Below this the key words give up their room instead,
  # which is why the floor states the epic rather than a stub of it.
  my $name_room = 8;
  my $bar;
  for my $tier ([" e epic: ", "   $hide_long",  "   r refresh   q quit"],
                [" e: ",      "   $hide_short", "   r refresh   q quit"],
                [" e: ",      "   $hide_short", "   r   q"]) {
    my $bar_room = $width - length($tier->[0]) - length($tier->[1]) - length($tier->[2]);
    next if $bar_room < $name_room && $bar_room < length($value);
    $bar = $tier->[0] . $cut->($value, $bar_room) . $tier->[1] . $tier->[2];
    last;
  }
  # A width below the floor is only reachable by asking for one, and is cut by $emit anyway.
  $bar = " e: " . $cut->($value, 1) . "   $hide_short   r   q" if !defined $bar;
  push @out, $bar;
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
  push @out, $tail->();
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
  # lines, or a story's `status:` and `ticket:` lines - is printed as it came. Anything longer
  # than the frame is wrapped rather than cut, heading included: the heading carries the claim and
  # the blockers, and the text carries the ticket's own acceptance criteria, so a tail that does
  # not fit goes on the next line instead of being dropped (LK-02).
  my $title = shift @lines;
  $title = "" unless defined $title;
  $title =~ s/^#+\s*//;
  my @out = $wrap->($title, $width);
  push @out, $rule;
  for my $line (@lines) {
    # A line that already fits is kept exactly as it came, so its layout and its leading
    # spaces survive; only a longer one is wrapped.
    if (length($line) <= $width) { push @out, $line }
    else { push @out, $wrap->($line, $width) }
  }
  push @out, $tail->();
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
  # The window follows the marker. A sprint longer than the frame would otherwise let the marker
  # move onto a row that is not drawn, so the key would look like it did nothing - which is the
  # whole point of moving it. With no selection the window starts at the top, as it always did.
  my $first = ($sel ne "" && $sel + 0 > $max) ? $sel + 0 - $max : 0;
  my $i = 0;
  for my $r (@rows) {
    if ($i >= $first + $max) { last }
    if ($i < $first) { $i++; next }
    my $line = $mark->($i);
    $i++;
    $line .= $rpad->($r->{pos} ne "" ? $r->{pos} : "-", $w{idx} - 1) . " " if $has->("idx");
    $line .= $cell->($r->{id}, "id") if $has->("id");
    $line .= $cell->($cut->($r->{state}, $w{state} - 1), "state") if $has->("state");
    $line .= $cell->($r->{ready} ne "" ? $r->{ready} : "-", "ready") if $has->("ready");
    $line .= $cell->($cut->($r->{blocked}, $w{blocked} - 1), "blocked") if $has->("blocked");
    $line .= $cut->($r->{title}, $title_w);
    push @out, $line;
  }
  # The rows the frame could not hold, above and below the window. With the window at the top this
  # is the line the frame always carried.
  my $above = $first;
  my $below = scalar(@rows) - $i;
  if ($above > 0 || $below > 0) {
    my @note;
    push @note, "$above above" if $above > 0;
    push @note, "$below more" if $below > 0;
    push @out, "   " . $ELL . "  (" . join(", ", @note) . ")";
  }
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
push @out, $tail->();
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
  case "$VIEW" in
    help)
      # The key list, drawn here rather than by the renderer because it is not one of the views
      # the renderer lays out. It exists because the dashboard keybar opens with `? help`, and a
      # key that does nothing is a lie printed on the frame. The columns are a dash rather than
      # padding: frame_text wraps by splitting on spaces and joining them back single, so a run of
      # spaces used for alignment would not survive the wrap.
      local hrule; hrule="$(printf '%*s' "$width" '' | tr ' ' '-')"
      frame_text "$width" 0 "TICKET LOOP  keys"
      echo "$hrule"
      frame_text "$width" 3 "j, k or the arrow keys - move the marker, wrapping at either end
<space> - open the marked ticket or story in full
a - add a ticket to the sprint: type its id, then Enter
x - take the marked ticket out of the sprint
s, o - the stories and open views; the same key again comes back
e - in the stories view: the epic filter, one epic per press, then any
d - in the stories view: hide the stories nothing serves, then show them
r - fetch from origin, then redraw
? - this screen
q - quit"
      echo "$hrule"
      return 0
      ;;
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
      if ! load_stories; then
        message_frame "$width" "STORIES  backlog-status.sh failed" "$STORIES_TEXT"
        return 1
      fi
      stories_line="$STORIES_TEXT"
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
  TUI_MODE="$VIEW" TUI_WIDTH="$width" TUI_PROJECT="$project" TUI_BRANCH="$branch" TUI_SHA="$sha" \
  TUI_SPRINT="$sprint" TUI_OPEN="$open_line" TUI_STORIES="$stories_line" TUI_NEXT="$next_id" \
  TUI_SHOW="$show_out" TUI_MAX="$MAX_ROWS" TUI_SEL="$SEL" TUI_STATUS="$MSG" TUI_DIRTY="$DIRTY" \
  TUI_PROMPT="$PROMPT_TEXT" TUI_EPIC="$EPIC" TUI_HIDE="$HIDE_UNTICKETED" \
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
**Done when:** a line long enough that a 78-column frame has to wrap it rather than cut it, which is what proves the show view prints the item in full.

## Beta

### AA-05 A ticket behind an unlanded blocker — Blocked by AA-03
Body.
**Done when:** the blocker lands.
EOF
    # The epic is long on purpose: it is what a 78-column stories frame has to shorten and a
    # 200-column one has to print whole. The second epic is what makes the stories view's epic
    # filter (LK-20) narrow something: with one epic the filter would be indistinguishable from
    # no filter, and BB-2 is the unticketed story the `d` toggle hides. The third holds a
    # backslash, which is the value a filter handed to awk through `-v` cannot carry: `-v`
    # escape-processes its value, so this epic arrives at the predicate as a name plus a tab,
    # matches no row, and empties the table (LK-20's review). The filter has to match it.
    cat > PRODUCT.md <<'EOF'
# Fixture product backlog

## Epic F: Data inventory, coverage and the release ledger

### BB-1 — A story a ticket serves

**Status:** Proposed

### BB-2 — A story nothing serves yet

**Status:** Proposed

### BB-3 — A story whose ticket landed

**Status:** Complete

## Epic G: Export and restore

### BB-4 — A story in the second epic

**Status:** Proposed

## Epic H: Import from a Windows share (C:\temp)

### BB-5 — A story under an epic whose name holds a backslash

**Status:** Proposed
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
  # Every story, not the ticketed ones: five stories, three of which nothing serves.
  echo "$out" | grep -q '^ STORIES  5 - 1 done - 1 open - 3 unticketed$' \
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
 STORIES  5 - 1 done - 1 open - 3 unticketed
------------------------------------------------------------
 ? help   <sp> show   a add   x remove   r refresh   q quit
G60
)"
  golden78="$(cat <<'G78'
TICKET LOOP  work  main@e048b11   5 in sprint: 1 done 1 ready 1 claimed
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
 STORIES  5 - 1 done - 1 open - 3 unticketed
------------------------------------------------------------------------------
 ? help   <sp> show   a add   x remove   r refresh   q quit
G78
)"
  golden200="$(cat <<'G200'
TICKET LOOP  work  main@e048b11   5 in sprint: 1 done 1 ready 1 claimed
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
 STORIES  5 - 1 done - 1 open - 3 unticketed
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
  #    under - shown whole when the frame can hold it and shortened when it cannot. The fixture's
  #    stories sit under three epics, so the epic column is a filter with something to narrow.
  out="$(cd "$work" && LOOP_ROOT="$work" "$me" stories --width 78 2>&1)"
  echo "$out" | grep -q '^STORIES  5 - 1 done - 1 open - 3 unticketed$' \
    || { echo "self-test: the stories view should lead with every story counted:"; echo "$out"; exit 1; }
  echo "$out" | grep -qE '^ BB-1 +open 0/1 +1 +' || { echo "self-test: an open k/n story should show its status and its ticket count:"; echo "$out"; exit 1; }
  echo "$out" | grep -qE '^ BB-3 +done +1 +' || { echo "self-test: a story whose tickets landed should read done:"; echo "$out"; exit 1; }
  echo "$out" | grep -qE '^ BB-2 +unticketed +- +' || { echo "self-test: a story nothing serves should read unticketed:"; echo "$out"; exit 1; }
  echo "$out" | grep -qE '^ BB-4 +unticketed +- +Epic G: Export and restore +' \
    || { echo "self-test: the second epic's story should be drawn under its own epic:"; echo "$out"; exit 1; }
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
  # A line longer than the frame is wrapped, not cut: the view exists to show the item in full, so
  # the tail - a figure, an acceptance criterion, the blocker named in a heading - has to survive
  # onto the next line. AA-04's text carries a line longer than 78 columns for exactly this.
  echo "$out" | grep -q '…' && { echo "self-test: the show view must wrap a long line, not cut it:"; echo "$out"; exit 1; }
  echo "$out" | grep -q 'is what proves the show view prints the item in full\.$' \
    || { echo "self-test: the show view should print a long line's tail, wrapped:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | perl -CS -ne 'chomp; exit 1 if length($_) > 78' \
    || { echo "self-test: every line of the show view should fit 78 columns:"; echo "$out"; exit 1; }
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
      # The two frames drawn without the renderer, when there is nothing for it to render: a
      # missing product backlog, and a status call that failed. Their lines are wrapped to the
      # width as well, so an exceptional frame is no wider than the frame it replaces (LK-02).
      none)        (cd "$work" && LOOP_CONFIG="$work/nostories.toml" LOOP_ROOT="$work" "$me" stories --width "$2" 2>&1) ;;
      failed)      (cd "$work" && LOOP_ROOT="$work" "$me" --width "$2" --ref nosuchref 2>&1) ;;
    esac
  }
  local view
  for w in 40 60 78 200; do
    for view in stories open "show AA-04" "show BB-1" none failed; do
      # The failed-ref frame exits non-zero on purpose; this loop is about width, and the exit
      # codes are asserted where each frame is proved.
      out="$(view_frame "$view" "$w")" || true
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
STORIES  5 - 1 done - 1 open - 3 unticketed
------------------------------------------------------------------------------
 id       status      t  epic                             title
 BB-1     open 0/1    1  Epic F: Data inventory, coverag… A story a ticket se…
 BB-2     unticketed  -  Epic F: Data inventory, coverag… A story nothing ser…
 BB-3     done        1  Epic F: Data inventory, coverag… A story whose ticke…
 BB-4     unticketed  -  Epic G: Export and restore       A story in the seco…
 BB-5     unticketed  -  Epic H: Import from a Windows s… A story under an ep…
------------------------------------------------------------------------------
 e epic: any   d unticketed: shown   r refresh   q quit
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
**Done when:** a line long enough that a 78-column frame has to wrap it rather
than cut it, which is what proves the show view prints the item in full.

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

  # 11. The key handler (LK-03): the same frames, driven by --keys so the whole program runs
  #     without a pseudo-terminal. The writes happen in a second checkout whose .loop.toml holds a
  #     sprint the three refusal reasons can be told apart in: AA-01 is done and outside it, AA-02
  #     is in it, AA-04 is ready and outside it, and AA-99 is not a ticket at all. So `a` has a
  #     ready ticket to add, each refusal has its own reason, and the only file a run touches is
  #     that .loop.toml - which is what the done line names. It is a copy of the fixture rather
  #     than another clone, so it starts on the same branch at the same commit and its origin
  #     still resolves.
  local write="$dir/write"
  cp -r "$work" "$write"
  printf '[loop]\ndefault_branch = "main"\nsprint = ["AA-02", "AA-03", "AA-05"]\nstories = "PRODUCT.md"\n' > "$write/.loop.toml"
  git -C "$write" add -A
  GIT_AUTHOR_DATE="2026-01-02T03:04:05+00:00" GIT_COMMITTER_DATE="2026-01-02T03:04:05+00:00" \
    git -C "$write" commit -q -m "Sprint without AA-01 and AA-04"
  # The width is the second argument, defaulting to the 78 the golden frames use, so a frame can
  # also be driven at the 40-column floor the width self-test only proves fits.
  key_frame() { (cd "$write" && LOOP_ROOT="$write" "$me" --keys "$1" --width "${2:-78}" 2>&1) }
  local kout write_head
  write_head="$(git -C "$write" rev-parse HEAD)"

  # q writes nothing. A frame is not a write, and the working tree is untouched.
  kout="$(key_frame 'q')"
  [ -z "$(git -C "$write" status --porcelain)" ] \
    || { echo "self-test: q must write nothing:"; git -C "$write" status --porcelain; exit 1; }

  # The marker starts on the first row, moves down, and wraps at either end.
  kout="$(key_frame 'j')"
  echo "$kout" | grep -q '^>  2 AA-03' \
    || { echo "self-test: j should move the marker to the second row:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q '^   1 AA-02' \
    || { echo "self-test: the first row should give up the marker:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'jjj')"
  echo "$kout" | grep -q '^>  1 AA-02' \
    || { echo "self-test: the marker should wrap round the last row:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'k')"
  echo "$kout" | grep -q '^>  3 AA-05' \
    || { echo "self-test: the marker should wrap backwards to the last row:"; echo "$kout"; exit 1; }

  # <space> opens the marked item in full.
  kout="$(key_frame ' ')"
  echo "$kout" | grep -q '^AA-02 A ticket someone holds$' \
    || { echo "self-test: <sp> should open the marked ticket in full:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'j ')"
  echo "$kout" | grep -q '^AA-03 A ticket waiting on someone else — `blocked until 2026-10-01 response`$' \
    || { echo "self-test: <sp> should open the ticket the marker is on:"; echo "$kout"; exit 1; }

  # An add is refused, with the reason on the frame, when the id is done, is not a ticket, or is
  # already in the sprint - and a refused add writes nothing at all.
  kout="$(key_frame $'aAA-01\n')"
  echo "$kout" | grep -q 'AA-01 is already done' \
    || { echo "self-test: an add of a done id should say so:"; echo "$kout"; exit 1; }
  kout="$(key_frame $'aAA-99\n')"
  echo "$kout" | grep -q 'AA-99 is not a ticket' \
    || { echo "self-test: an add of an id that is not a ticket should say so:"; echo "$kout"; exit 1; }
  kout="$(key_frame $'aAA-02\n')"
  echo "$kout" | grep -q 'AA-02 is already in the sprint' \
    || { echo "self-test: an add of a ticket already in the sprint should say so:"; echo "$kout"; exit 1; }
  [ -z "$(git -C "$write" status --porcelain)" ] \
    || { echo "self-test: a refused add must write nothing:"; git -C "$write" status --porcelain; exit 1; }

  # A ready ticket outside the sprint is added through scripts/sprint.sh, the marker moves onto
  # it, and the frame says the change is uncommitted. Only .loop.toml is modified.
  kout="$(key_frame $'aAA-04\n')"
  echo "$kout" | grep -q '^>  4 AA-04' \
    || { echo "self-test: an add should append the ticket and mark it:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q 'uncommitted' \
    || { echo "self-test: an add should mark the sprint uncommitted:"; echo "$kout"; exit 1; }
  [ "$(git -C "$write" status --porcelain)" = " M .loop.toml" ] \
    || { echo "self-test: only .loop.toml should be modified:"; git -C "$write" status --porcelain; exit 1; }
  grep -q '^sprint = \["AA-02", "AA-03", "AA-05", "AA-04"\]$' "$write/.loop.toml" \
    || { echo "self-test: the add should have gone through scripts/sprint.sh:"; cat "$write/.loop.toml"; exit 1; }

  # x takes the marked ticket back out - the marker is moved onto it first, so this also proves
  # the marker and the write agree about which row is selected - and the file returns to what it
  # was, which is why the run leaves no diff behind.
  kout="$(key_frame 'jjjx')"
  echo "$kout" | grep -qE '^[ >]  +[0-9]+ AA-04' \
    && { echo "self-test: x should take the marked ticket out of the sprint:"; echo "$kout"; exit 1; }
  grep -q '^sprint = \["AA-02", "AA-03", "AA-05"\]$' "$write/.loop.toml" \
    || { echo "self-test: x should have put the sprint line back:"; cat "$write/.loop.toml"; exit 1; }
  [ -z "$(git -C "$write" status --porcelain)" ] \
    || { echo "self-test: add then remove should leave the file as it was:"; git -C "$write" status --porcelain; exit 1; }
  [ "$(git -C "$write" rev-parse HEAD)" = "$write_head" ] \
    || { echo "self-test: the UI must never commit"; exit 1; }

  # e and d are the stories view's two settings (LK-20). Each is drawn on the keybar as what it is
  # set to, so a narrowed table is never a silent one, and the marker walks the rows the filter
  # left rather than the ones it hid.
  kout="$(key_frame 'se')"
  echo "$kout" | grep -q '^>BB-1' \
    || { echo "self-test: e should leave the marker on the first row drawn:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q '^ BB-2' \
    || { echo "self-test: the epic filter should keep the chosen epic's rows:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q '^ BB-4' \
    && { echo "self-test: the epic filter should drop the other epic's rows:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q 'e epic: Epic F: Data inventory, c…' \
    || { echo "self-test: the keybar should name the epic the table is narrowed to:"; echo "$kout"; exit 1; }

  # The next press is the second epic, the one after is the epic whose name holds a backslash, and
  # the one after that comes back to every story. The backslash is the case the review found: a
  # value handed to awk through -v is escape-processed, so this epic arrives at the predicate as a
  # name plus a tab, matches no row, and empties the table while the keybar claims a filter is on.
  # These rows are what proves the value goes through the environment instead.
  kout="$(key_frame 'see')"
  echo "$kout" | grep -q '^>BB-4' \
    || { echo "self-test: e again should walk to the second epic:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q 'e epic: Epic G: Export and restore' \
    || { echo "self-test: the keybar should name the second epic:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'seee')"
  echo "$kout" | grep -q '^>BB-5' \
    || { echo "self-test: e should walk to an epic whose name holds a backslash:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q '^ BB-4' \
    && { echo "self-test: the third epic should drop the other epics' rows:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q 'e epic: Epic H: Import from a Win…' \
    || { echo "self-test: the keybar should name the backslash epic in full as far as it fits:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'seeee')"
  echo "$kout" | grep -q '^ BB-4' \
    || { echo "self-test: e should come back to every story:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q 'e epic: any' \
    || { echo "self-test: the keybar should read any once the filter is off:"; echo "$kout"; exit 1; }

  # d drops the stories nothing serves, says so, and the marker walks what is left: with BB-2
  # hidden the second row is BB-3, not BB-2. It drops BB-5 too, the unticketed story under the
  # backslash epic, so the toggle is not passing by hiding one row it happens to know.
  kout="$(key_frame 'sd')"
  echo "$kout" | grep -q '^ BB-2' \
    && { echo "self-test: d should hide the unticketed stories:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q '^ BB-5' \
    && { echo "self-test: d should hide every unticketed story, not just the first:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -qE '^[ >]BB-1' \
    || { echo "self-test: d should keep the ticketed stories:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q 'd unticketed: hidden' \
    || { echo "self-test: the keybar should say the unticketed stories are hidden:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'sdj')"
  echo "$kout" | grep -q '^>BB-3' \
    || { echo "self-test: the marker should move over the rows the filter left:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'sdd')"
  echo "$kout" | grep -q '^ BB-2' \
    || { echo "self-test: d again should show the unticketed stories:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q 'd unticketed: shown' \
    || { echo "self-test: the keybar should say the unticketed stories are shown:"; echo "$kout"; exit 1; }

  # The two settings compose, and the keybar carries both.
  kout="$(key_frame 'sed')"
  echo "$kout" | grep -q '^ BB-4' \
    && { echo "self-test: the epic filter should still hold with the unticketed hidden:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q '^ BB-2' \
    && { echo "self-test: the hide should still hold with an epic chosen:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q 'e epic: Epic F: Data inventory, …   d unticketed: hidden' \
    || { echo "self-test: the keybar should carry both settings:"; echo "$kout"; exit 1; }

  # The bar names both settings at every width the frame allows, 40 columns being the floor
  # frame_width() enforces, and `r` and `q` stay on it. The review measured the first version at
  # the floor printing ` e epic:    d unticketed: shown   r ref…` - the epic named nowhere and
  # `q quit` off the bar. key_frame() defaults to 78, which is why the check could not catch that,
  # so these three are driven at 40. At the floor the labels and then the key words give way, and
  # the epic is cut last: `e: any` for no filter, the name itself when one is on.
  kout="$(key_frame 's' 40)"
  echo "$kout" | grep -qxF ' e: any   d: shown   r refresh   q quit' \
    || { echo "self-test: the 40-column keybar should name both settings and keep r and q:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'se' 40)"
  echo "$kout" | grep -qxF ' e: Epic F: Data inv…   d: shown   r   q' \
    || { echo "self-test: the 40-column keybar should still name the epic it is narrowed to:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'sed' 40)"
  echo "$kout" | grep -qxF ' e: Epic F: Data in…   d: hidden   r   q' \
    || { echo "self-test: the 40-column keybar should carry both settings:"; echo "$kout"; exit 1; }

  # Leaving the view and coming back keeps both settings. Decision 0011 says they belong to the
  # view and are cleared by nothing but the keys, and switch_view() resets only the marker - so a
  # round trip is narrowed as it was left, not silently widened.
  kout="$(key_frame 'sess')"
  echo "$kout" | grep -q 'e epic: Epic F: Data inventory, c…' \
    || { echo "self-test: leaving the stories view should not clear the epic filter:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q '^ BB-4' \
    && { echo "self-test: the filter should still narrow the table after a round trip:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'sdss')"
  echo "$kout" | grep -q 'd unticketed: hidden' \
    || { echo "self-test: leaving the stories view should not clear the unticketed toggle:"; echo "$kout"; exit 1; }
  echo "$kout" | grep -q '^ BB-2' \
    && { echo "self-test: the hide should still hold after a round trip:"; echo "$kout"; exit 1; }

  # Neither key is a write, and neither is read outside the stories view: on the dashboard each
  # says what it does rather than narrowing a table that has no epic column.
  kout="$(key_frame 'e')"
  echo "$kout" | grep -q 'e filters epics, which only the stories view has' \
    || { echo "self-test: e outside the stories view should say so:"; echo "$kout"; exit 1; }
  kout="$(key_frame 'd')"
  echo "$kout" | grep -q 'd hides unticketed stories, which only the stories view has' \
    || { echo "self-test: d outside the stories view should say so:"; echo "$kout"; exit 1; }
  [ -z "$(git -C "$write" status --porcelain)" ] \
    || { echo "self-test: e and d must write nothing:"; git -C "$write" status --porcelain; exit 1; }

  # r is the only thing in the program that fetches. A frame shows what the checkout already
  # knows, which is what keeps the fetch off every other keypress.
  rm -f "$work/.git/FETCH_HEAD"
  kout="$(cd "$work" && LOOP_ROOT="$work" "$me" --render --width 78 2>&1)"
  [ ! -f "$work/.git/FETCH_HEAD" ] \
    || { echo "self-test: drawing a frame must not fetch from origin"; exit 1; }
  kout="$(cd "$work" && LOOP_ROOT="$work" "$me" --keys 'r' --width 78 2>&1)"
  [ -f "$work/.git/FETCH_HEAD" ] \
    || { echo "self-test: r should fetch from origin before redrawing"; exit 1; }

  echo "loop-tui self-test passed"
}

# ---- the key handler (LK-03) -----------------------------------------------------------------
# The interactive mode is a key handler over the frames above, never a second renderer. Every
# write goes through scripts/sprint.sh and changes only the sprint list in .loop.toml; nothing
# here runs git add, git commit, or git push, so the frame carries an uncommitted marker while
# the change sits in the working tree (decision 0003).
VIEW="$MODE"
SEL=""
MSG=""
DIRTY=""
PROMPT_TEXT=""
PROMPTING=""
QUIT=""
# The stories view's two view settings, and the only state here that is not about a keypress: the
# epic the table is narrowed to (empty for every epic) and whether the stories nothing serves are
# hidden. Both are drawn on the keybar, so a reader can always see which is on (LK-20).
EPIC=""
HIDE_UNTICKETED=0

# The file the sprint lives in: the one scripts/sprint.sh would write, so the marker and the
# write cannot disagree about which file the change is in.
sprint_file() { echo "${LOOP_CONFIG:-$ROOT/.loop.toml}"; }

# The stories view's rows, narrowed by the epic filter and the unticketed toggle (LK-20). One
# list, read by both the renderer and the marker, so a hidden story cannot hold the marker and the
# frame cannot draw a row the marker walks past - the two parses of the same output would
# otherwise have to agree about the filter, which is one fact written down twice.
#
# The summary line is left whole: it counts the product backlog, and the filter is a setting on
# the table drawn under it, which the keybar states. A narrowed table is never a silent one.
# STORIES_TEXT holds the rows to draw, STORIES_EPICS every epic the view holds unfiltered (what
# `e` walks), and on failure the script's own message, for the caller to draw.
STORIES_TEXT=""
STORIES_EPICS=""
load_stories() {
  local backlog raw
  backlog="$ROOT/$("$CONFIG" backlog)"
  if ! raw="$("$STATUS" --stories --ref "${REF:-$(default_ref)}" --local --plain --backlog "$backlog" 2>&1)"; then
    STORIES_TEXT="$raw"
    STORIES_EPICS=""
    return 1
  fi
  STORIES_EPICS="$(printf '%s\n' "$raw" | awk -F'\t' 'NF >= 5 && $4 != "" && !seen[$4]++ { print $4 }')"
  # The two filter values go through the environment, not through awk's -v: a -v assignment
  # escape-processes its value, so an epic holding a backslash (`Epic G: ... (C:\temp)`) would
  # arrive as `... (C:` plus a TAB, match no row, and empty the table while the keybar still
  # claimed a filter was on (LK-20's review).
  STORIES_TEXT="$(printf '%s\n' "$raw" | EPIC_FILTER="$EPIC" HIDE_UNTICKETED="$HIDE_UNTICKETED" \
    awk -F'\t' '
    /^stories: / { print; next }
    NF >= 5 { if (ENVIRON["EPIC_FILTER"] != "" && $4 != ENVIRON["EPIC_FILTER"]) next
              if (ENVIRON["HIDE_UNTICKETED"] == "1" && $2 == "unticketed") next
              print }')"
  return 0
}

# The ids the selection moves over in the current view, one per line and in the order the
# renderer draws its rows. Only the dashboard and the stories view have a list to move over: the
# open view groups its rows under section headings, so a marker there would not line up with the
# rows the renderer draws.
view_ids() {
  case "$VIEW" in
    dashboard) "$CONFIG" sprint ;;
    stories)
      # The filtered list, not the raw one: the marker moves over the rows on the frame.
      load_stories || return 0
      printf '%s\n' "$STORIES_TEXT" | awk -F'\t' 'NF >= 5 { print $1 }'
      ;;
    *) : ;;
  esac
}

# The id the marker is on, or nothing.
selected_id() {
  view_ids | awk -v n="$SEL" 'NF { c++; if (c == n) { print; exit } }'
}

# What the frame says under the rule: whether the sprint change is still uncommitted. That marker
# is the whole safeguard the record asks for, because committing the sprint stays the owner's.
set_dirty() {
  local f; f="$(sprint_file)"
  if [ -n "$(git -C "$ROOT" status --porcelain -- "$f" 2>/dev/null)" ]; then
    DIRTY="$(basename "$f") modified: the sprint change is uncommitted - commit it, this UI never does"
  else
    DIRTY=""
  fi
}

# Moves the marker, wrapping at either end so the list is a ring.
move_sel() { # <delta>
  local n; n="$(view_ids | awk 'NF { n++ } END { print n + 0 }')"
  if [ "$n" -lt 1 ]; then SEL=1; return 0; fi
  SEL=$(( SEL + $1 ))
  if [ "$SEL" -lt 1 ]; then SEL="$n"; fi
  if [ "$SEL" -gt "$n" ]; then SEL=1; fi
  return 0
}

# The views are switched with the key their own keybar names, so `o` in the open view - whose
# keybar reads "o sprint" - comes back here rather than going somewhere else.
switch_view() { # <view>
  case "$1" in
    stories) if [ "$VIEW" = stories ]; then VIEW=dashboard; else VIEW=stories; fi ;;
    open)    if [ "$VIEW" = open ]; then VIEW=dashboard; else VIEW=open; fi ;;
    help)    if [ "$VIEW" = help ]; then VIEW=dashboard; else VIEW=help; fi ;;
    *)       VIEW="$1" ;;
  esac
  # Only the marker. The stories view's two settings (LK-20) survive a view switched away from and
  # back, which is what decision 0011 says they do: the marker indexes rows a refetch can change,
  # while EPIC and HIDE_UNTICKETED are the view's own and the keybar names them both, so a reader
  # who comes back is told what they are set to rather than surprised by a table.
  SEL=1
}

open_selected() {
  local id; id="$(selected_id)"
  if [ -z "$id" ]; then MSG="nothing is selected here"; return 0; fi
  WANT="$id"
  VIEW=show
  return 0
}

# `e` walks the epics the stories view holds: unfiltered first, then each epic in the order the
# rows are drawn, then back to unfiltered. A list of one epic still reads as a filter that is on
# or off, which is what the keybar draws; the list is taken unfiltered, so narrowing the table
# cannot narrow the choices out from under the key that made it.
cycle_epic() {
  load_stories || true
  EPIC="$(printf '\n%s\n' "$STORIES_EPICS" | awk -v cur="$EPIC" '
    { v[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (v[i] == cur) { print v[i % NR + 1]; exit }
      print v[1]
    }')"
  SEL=1
  MSG=""
  return 0
}

# `d` hides the stories nothing serves, and shows them again. The rows are dropped from the one
# list the marker reads, so a hidden story cannot be selected.
toggle_unticketed() {
  if [ "$HIDE_UNTICKETED" = 1 ]; then HIDE_UNTICKETED=0; else HIDE_UNTICKETED=1; fi
  SEL=1
  MSG=""
  return 0
}

# The add and the remove are the only writes, and both go through scripts/sprint.sh. The reasons
# are checked here as well as there: that script refuses an id which is not a heading and one
# that is already done, but not one that is already in the sprint, which it would quietly leave
# alone - and the ticket wants all three said out loud.
add_ticket() { # <id>
  local id="$1" err at
  if [ -z "$id" ]; then MSG="no ticket id given"; return 0; fi
  if "$CONFIG" sprint 2>/dev/null | grep -qx -- "$id"; then
    MSG="$id is already in the sprint"
    return 0
  fi
  if err="$("$SCRIPT_ROOT/scripts/sprint.sh" add "$id" 2>&1 >/dev/null)"; then
    MSG="added $id to the sprint"
    # Put the marker on the row just added, so the next key acts on it.
    at="$(view_ids | awk -v id="$id" 'NF { c++; if ($0 == id) { print c; exit } }')"
    if [ -n "$at" ]; then SEL="$at"; fi
  else
    MSG="$(printf '%s' "$err" | head -1)"
  fi
  return 0
}

remove_selected() {
  local id err
  id="$(selected_id)"
  if [ -z "$id" ]; then MSG="nothing is selected here"; return 0; fi
  if err="$("$SCRIPT_ROOT/scripts/sprint.sh" remove "$id" 2>&1 >/dev/null)"; then
    MSG="removed $id from the sprint"
  else
    MSG="$(printf '%s' "$err" | head -1)"
  fi
  return 0
}

# `r` is the only thing in the program that fetches. A frame shows what the checkout already
# knows - it passes an explicit ref, which is what keeps scripts/backlog-status.sh from fetching
# behind it - so the keypress is what changes that.
refresh() {
  git -C "$ROOT" fetch -q 2>/dev/null || true
  MSG="fetched from origin"
}

handle_key() { # <key>
  local k="$1"
  if [ "$PROMPTING" = 1 ]; then
    case "$k" in
      $'\n'|$'\r') local id="$PROMPT_TEXT"; PROMPTING=""; PROMPT_TEXT=""; add_ticket "$id" ;;
      $'\e') PROMPTING=""; PROMPT_TEXT=""; MSG="add cancelled" ;;
      $'\177'|$'\b') PROMPT_TEXT="${PROMPT_TEXT%?}" ;;
      *) PROMPT_TEXT="$PROMPT_TEXT$k" ;;
    esac
    return 0
  fi
  case "$k" in
    q) QUIT=1 ;;
    j) move_sel 1 ;;
    k) move_sel -1 ;;
    ' ') open_selected ;;
    a) PROMPTING=1; PROMPT_TEXT="" ;;
    x) remove_selected ;;
    s) switch_view stories ;;
    o) switch_view open ;;
    e) if [ "$VIEW" = stories ]; then cycle_epic; else MSG="e filters epics, which only the stories view has"; fi ;;
    d) if [ "$VIEW" = stories ]; then toggle_unticketed; else MSG="d hides unticketed stories, which only the stories view has"; fi ;;
    r) refresh ;;
    '?') switch_view help ;;
    *) : ;;
  esac
  return 0
}

# Runs the handler over a string of keys and leaves the state the last key produced. This is how
# the whole program is driven without a pseudo-terminal, and what --self-test asserts. An arrow
# key is the escape sequence the terminal would send, folded onto k and j so both spellings go
# through one path.
run_keys() { # <keys>
  local keys="$1" i=0 k rest
  # `local` marks every name it is given before it assigns any of them, so the length has to be
  # taken in its own statement: `local keys="$1" n="${#keys}"` reads an unset local under set -u.
  local n="${#keys}"
  while [ "$i" -lt "$n" ]; do
    k="${keys:$i:1}"
    i=$(( i + 1 ))
    if [ "$k" = $'\e' ] && [ "$PROMPTING" != 1 ]; then
      rest="${keys:$i:2}"
      case "$rest" in
        '[A') k=k; i=$(( i + 2 )) ;;
        '[B') k=j; i=$(( i + 2 )) ;;
      esac
    fi
    handle_key "$k"
    if [ "$QUIT" = 1 ]; then break; fi
  done
  return 0
}

# One key from the terminal, with the arrow keys folded onto k and j.
read_key() {
  local k rest
  IFS= read -rsn1 k || return 1
  if [ "$k" = $'\e' ] && [ "$PROMPTING" != 1 ]; then
    IFS= read -rsn1 -t 1 rest || true
    if [ "$rest" = "[" ]; then
      IFS= read -rsn1 -t 1 rest || true
      case "$rest" in
        A) k=k ;;
        B) k=j ;;
      esac
    fi
  fi
  printf '%s' "$k"
  return 0
}

# Puts the terminal back: the cursor, the main screen, and the modes stty was in. Every exit path
# runs it - q, a signal, or a frame that fails - which is what keeps a crash from leaving a
# terminal with no echo and no cursor.
restore_terminal() {
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  if [ -n "${SAVED_STTY:-}" ]; then stty "$SAVED_STTY" 2>/dev/null || true; fi
}

# The interactive mode proper: the alternate screen, one key at a time, redrawing the same frame
# the one-shot path prints.
screen() { # <ref> <width>
  local ref="$1" width="$2" frame key
  if [ ! -t 0 ] || [ ! -t 1 ]; then render "$ref" "$width"; return $?; fi
  SAVED_STTY="$(stty -g 2>/dev/null || true)"
  trap 'restore_terminal' EXIT
  trap 'exit 130' INT TERM HUP
  stty -icanon -echo min 1 time 0 2>/dev/null || true
  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
  while [ "$QUIT" != 1 ]; do
    set_dirty
    frame="$(render "$ref" "$width")"
    printf '\033[H%s\n' "$frame"
    tput ed 2>/dev/null || true
    key="$(read_key)" || break
    handle_key "$key"
  done
  return 0
}

case "$MODE" in
  selftest) self_test ;;
  *)
    if [ "$KEYS_GIVEN" = 1 ]; then
      # The whole program without a terminal: run the keys, then print the frame they left.
      SEL=1
      run_keys "$KEYS"
      set_dirty
      render "${REF:-$(default_ref)}" "$(frame_width)"
    elif [ "$VIEW_GIVEN" = 0 ] && [ "$RENDER_GIVEN" = 0 ] && [ -t 0 ] && [ -t 1 ]; then
      SEL=1
      screen "${REF:-$(default_ref)}" "$(frame_width)"
    else
      render "${REF:-$(default_ref)}" "$(frame_width)"
    fi
    ;;
esac
