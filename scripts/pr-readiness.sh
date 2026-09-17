#!/usr/bin/env bash
# The readiness gate: everything that has to be true before a pull request in this loop is
# called done. A green build is not a merge-ready pull request - the check can pass on a
# branch that is behind, a review can be outstanding, a conversation can be unresolved, and
# the ticket can name nothing - so the six facts a person would look at are read here, each
# with a verdict and a reason.
#
#   scripts/pr-readiness.sh                 every open pull request targeting the default
#                                           branch, one block per pull request: the six
#                                           criteria, each with a verdict and a reason
#   scripts/pr-readiness.sh --pr <number>    only that pull request (still all six criteria),
#                                           so one PR can be judged without reading the queue
#   scripts/pr-readiness.sh --ready         only the pull requests that pass all six, one per
#                                           line: <number> <sha> <branch> <title> (nothing
#                                           when none does); composes with --pr
#   scripts/pr-readiness.sh --self-test      a stub gh and bd prove every criterion fails alone
#
# A pull request is ready only when all six hold:
#   ci             the project's own check (the `check` command in .loop.toml) ran on the head
#                  commit, and every check run concluded successfully; a run that is still
#                  queued, or concluded neutral, skipped or cancelled, is not a success, and a
#                  commit CI never ran has none however green an unrelated run looks
#   conversations  no review conversation (threaded review comment) is unresolved
#   changes        no review is outstanding as changes requested
#   review         the commit status named by review_context in .loop.toml is success on the
#                  head commit; scripts/review-status.sh posts it
#   current        the merge state is current and clean: not behind the default branch, no
#                  conflicts, not a draft, not blocked
#   bead           the branch (ticket/<ID>) and the head commit subject (<ID>: ...) name the
#                  same Beads ticket, which exists, carries acceptance criteria, and is
#                  claimed (in_progress) or closed, with an owner
#
# The queue is the open pull requests that target the default branch, read 200 at a time, and
# --pr is the same judgement for one of them. The output is a verdict, so this is a report and
# not a second check: it exits 0 even when nothing is ready (--ready is how the owner sees what
# is), and only fails when the queue itself cannot be read or a named pull request does not
# exist. Needs `gh` authenticated for this repository, `bd` with this repository's database,
# and python3 for the ticket JSON.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${LOOP_ROOT:-$SCRIPT_ROOT}"
CONFIG="$SCRIPT_ROOT/scripts/loop-config.sh"
MODE=report
WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ready) MODE=ready ;;
    --pr) shift; WANT="${1:-}" ;;
    --self-test) MODE=selftest ;;
    *) echo "usage: scripts/pr-readiness.sh [--ready] [--pr <number>] | --self-test" >&2; exit 2 ;;
  esac
  shift
done
case "$WANT" in
  "") ;;
  *[!0-9]*) echo "pr-readiness: --pr takes a pull request number, not '$WANT'" >&2; exit 2 ;;
esac

# Read once from .loop.toml, and the facts about the pull request under judgment.
CTX=""
BASE=""
PR_NUMBER=""
PR_SHA=""
PR_BRANCH=""
PR_TITLE=""
PR_MERGE=""
PR_DECISION=""
PR_REVIEWS=""
PR_NODE=""
PR_PR_BASE=""

need_gh() { command -v gh >/dev/null || { echo "gh is not installed (brew install gh && gh auth login)" >&2; exit 1; }; }

# One criterion line, as a tab so a reason may contain spaces.
tsv() { printf '%s\t%s\n' "$1" "$2"; }

# The ticket id a branch or subject names, or nothing. Both matches are exact, so a branch in
# another namespace (backlog/ideas, AB-124 on its own) or a subject that only starts with an id
# (AB-124-extra: ...) names no ticket rather than borrowing one. Ids are `<PREFIX>-<number>`,
# the shape every project in the loop uses.
branch_ticket() {
  local re='^ticket/([A-Z][A-Z0-9]*-[0-9]+)$'
  if [[ "$1" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

subject_ticket() {
  local re='^([A-Z][A-Z0-9]*-[0-9]+): '
  if [[ "$1" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

# -- The six criteria. Each reads the PR_* facts and prints one <verdict><TAB><reason> line. --

# ci: the project's own check ran on the head commit and every check run concluded successfully.
# Requiring the project's check by name is the point: a green unrelated run, with the real gate
# never scheduled, is the failure this criterion exists to catch. The check command is compared
# as the file it names - `./check.sh` and `Check (check.sh)` are the same gate, and the job name
# a workflow reports is the one the ruleset requires.
crit_ci() {
  local dump kind name expected total=0 runs=0 project=0 bad=""
  expected="$("$CONFIG" check)"
  expected="${expected%% *}"
  expected="${expected#./}"
  dump="$(gh api "repos/{owner}/{repo}/commits/$PR_SHA/check-runs?per_page=100" \
    --jq '"total\t" + (.total_count|tostring), (.check_runs[] | "run\t" + .name + "\t" + .status + "\t" + (.conclusion // ""))' \
    2>/dev/null)" || { tsv fail "check runs on ${PR_SHA:0:7} could not be read"; return; }
  while IFS=$'\t' read -r kind name a b; do
    case "$kind" in
      total) total="$name" ;;
      run)
        runs=$((runs + 1))
        case "$name" in *"$expected"*) project=1 ;; esac
        if [ "$a" != completed ] || [ "$b" != success ]; then
          if [ -z "$bad" ]; then bad="$name: $a${b:+, $b}"; fi
        fi
        ;;
    esac
  done <<< "$dump"
  if [ "$runs" = 0 ]; then tsv fail "no check runs on ${PR_SHA:0:7}"; return; fi
  if [ "$total" -gt "$runs" ]; then
    tsv fail "$total check runs exceed one page ($runs read); raise the page size"; return
  fi
  if [ "$project" = 0 ]; then
    tsv fail "$expected never ran on ${PR_SHA:0:7}"; return
  fi
  if [ -n "$bad" ]; then tsv fail "$bad"; return; fi
  tsv pass "$runs check run(s) concluded successfully, including $expected"
}

# conversations: every review conversation is resolved. The pull request's own node carries
# its threads, so no owner/repository lookup is needed; more pages than the cap is a refusal
# rather than a guess.
crit_conversations() {
  local query='query($id:ID!,$after:String){node(id:$id){... on PullRequest{reviewThreads(first:100,after:$after){nodes{isResolved} pageInfo{hasNextPage endCursor}}}}}'
  local jq='(.data.node.reviewThreads.nodes|map(select(.isResolved))|length) as $r | (.data.node.reviewThreads.nodes|length) as $n | ($r|tostring) + "\t" + (($n-$r)|tostring) + "\t" + (.data.node.reviewThreads.pageInfo.hasNextPage|tostring) + "\t" + (.data.node.reviewThreads.pageInfo.endCursor // "")'
  local after="" pages=0 resolved=0 unresolved=0 page resolved_page unresolved_page has cursor
  while :; do
    pages=$((pages + 1))
    if [ -n "$after" ]; then
      page="$(gh api graphql -f "query=$query" -F "id=$PR_NODE" -F "after=$after" --jq "$jq" 2>/dev/null)" \
        || { tsv fail "review conversations could not be read"; return; }
    else
      page="$(gh api graphql -f "query=$query" -F "id=$PR_NODE" --jq "$jq" 2>/dev/null)" \
        || { tsv fail "review conversations could not be read"; return; }
    fi
    if [ -z "$page" ]; then tsv fail "review conversations could not be read"; return; fi
    IFS=$'\t' read -r resolved_page unresolved_page has cursor <<< "$page"
    case "${resolved_page}${unresolved_page}" in
      ""|*[!0-9]*) tsv fail "review conversations could not be read"; return ;;
    esac
    resolved=$((resolved + resolved_page))
    unresolved=$((unresolved + unresolved_page))
    if [ "$has" != true ]; then break; fi
    if [ "$pages" -ge 10 ]; then
      tsv fail "more review conversations than the gate reads (10 pages of 100)"; return
    fi
    after="$cursor"
  done
  if [ "$unresolved" -gt 0 ]; then
    tsv fail "$unresolved of $((resolved + unresolved)) review conversation(s) unresolved"
  else
    tsv pass "$resolved review conversation(s) resolved"
  fi
}

# changes: an outstanding change request blocks the merge, whether GitHub's aggregate review
# decision says so or only a reviewer's own latest review does.
crit_changes() {
  case "$PR_DECISION" in
    CHANGES_REQUESTED) tsv fail "the pull request is marked changes requested"; return ;;
  esac
  case ",$PR_REVIEWS," in
    *",CHANGES_REQUESTED,"*) tsv fail "a reviewer's latest review requests changes"; return ;;
  esac
  tsv pass "no review requests changes"
}

# review: the agent review's own commit status, for the context .loop.toml names.
crit_review() {
  local state
  state="$(gh api "repos/{owner}/{repo}/commits/$PR_SHA/status" \
    --jq "[.statuses[] | select(.context == \"$CTX\")][0].state // \"\"" 2>/dev/null)" \
    || { tsv fail "the commit status could not be read"; return; }
  case "$state" in
    success) tsv pass "$CTX is success on ${PR_SHA:0:7}" ;;
    "") tsv fail "no $CTX status on ${PR_SHA:0:7}; run scripts/review-status.sh --pending" ;;
    *) tsv fail "$CTX is $state on ${PR_SHA:0:7}" ;;
  esac
}

# current: the branch is up to date with the default branch and clean enough to merge. UNSTABLE
# passes here because a failing check is the ci criterion's business, not this one's.
crit_current() {
  case "$PR_MERGE" in
    CLEAN) tsv pass "merge state CLEAN against $BASE" ;;
    UNSTABLE) tsv pass "merge state UNSTABLE and current with $BASE" ;;
    BEHIND) tsv fail "behind $BASE; rebase with scripts/open-ticket-pr.sh <id> --update" ;;
    DIRTY) tsv fail "conflicts with $BASE" ;;
    DRAFT) tsv fail "still a draft" ;;
    BLOCKED) tsv fail "blocked by a merge requirement" ;;
    "") tsv fail "merge state could not be read" ;;
    *) tsv fail "merge state $PR_MERGE is not current and clean" ;;
  esac
}

# bead: the branch and the head commit subject have to name the same ticket, and that ticket
# has to be one a reviewer can judge: acceptance criteria, an owner, and a claim or a close.
crit_bead() {
  local subject branch_id subject_id json
  subject="$(gh api "repos/{owner}/{repo}/commits/$PR_SHA" --jq '.commit.message' 2>/dev/null | head -1 || true)"
  branch_id="$(branch_ticket "$PR_BRANCH")"
  subject_id="$(subject_ticket "$subject")"
  if [ -z "$branch_id" ]; then tsv fail "branch $PR_BRANCH names no Beads ticket (ticket/<ID> exactly)"; return; fi
  if [ -z "$subject_id" ]; then tsv fail "the head commit subject names no Beads ticket (<ID>: ...)"; return; fi
  if [ "$branch_id" != "$subject_id" ]; then
    tsv fail "the branch names $branch_id but the subject names $subject_id"; return
  fi
  if ! command -v bd >/dev/null; then tsv fail "bd is not installed, so $branch_id cannot be read"; return; fi
  json="$(cd "$ROOT" && bd show "$branch_id" --json 2>/dev/null)" \
    || { tsv fail "$branch_id could not be read from this Beads database"; return; }
  printf '%s' "$json" | python3 -c '
import json, sys
ticket = sys.argv[1]
raw = sys.stdin.read().strip()
try:
    rows = json.loads(raw) if raw else []
except ValueError:
    rows = []
row = next((r for r in rows if r.get("id") == ticket), None)
if row is None:
    print("fail\t" + ticket + " is not in this Beads database"); sys.exit()
criteria = (row.get("acceptance_criteria") or "").strip()
status = (row.get("status") or "").strip()
owner = (row.get("assignee") or "").strip()
if not criteria:
    print("fail\t" + ticket + " carries no acceptance criteria"); sys.exit()
if status not in ("in_progress", "closed"):
    print("fail\t" + ticket + " is " + (status or "unknown") + ", not claimed or closed"); sys.exit()
if not owner:
    print("fail\t" + ticket + " has no owner"); sys.exit()
print("pass\t" + ticket + " is " + status + ", owned by " + owner + ", with acceptance criteria")
' "$branch_id" || tsv fail "$branch_id could not be read from this Beads database"
}

# The six criteria for the pull request in the globals, then its verdict: one line per
# criterion as <key><TAB><verdict><TAB><reason>, then verdict<TAB><ready|not-ready><TAB><count>.
judge() {
  local name out verdict reason passes=0 fails=0
  for name in ci conversations changes review current bead; do
    out="$("crit_$name")"
    verdict="${out%%$'\t'*}"
    reason="${out#*$'\t'}"
    if [ -z "$verdict" ]; then verdict=fail; reason="the criterion could not be evaluated"; fi
    if [ "$verdict" = pass ]; then passes=$((passes + 1)); else fails=$((fails + 1)); fi
    printf '%s\t%s\t%s\n' "$name" "$verdict" "$reason"
  done
  if [ "$fails" = 0 ]; then
    printf 'verdict\tready\tall %s criteria\n' "$passes"
  else
    printf 'verdict\tnot-ready\t%s of 6 criteria\n' "$passes"
  fi
}

report() {
  cd "$ROOT"
  CTX="$("$CONFIG" review_context)"
  BASE="$("$CONFIG" default_branch)"
  local rows fields
  # A field separator that is not IFS whitespace: with tab, an empty field ($reviewDecision is
  # empty on a repository without required reviews) collapses and every later field shifts.
  fields='number,headRefOid,headRefName,title,mergeStateStatus,reviewDecision,latestReviews,id,baseRefName'
  if [ -n "$WANT" ]; then
    rows="$(gh pr view "$WANT" --json "$fields" \
      --jq '[.number, .headRefOid, .headRefName, .title, .mergeStateStatus, (.reviewDecision // ""), ([.latestReviews[]? | .state] | join(",")), .id, .baseRefName] | join("\u001f")')" \
      || { echo "pull request #$WANT could not be read; check gh auth (gh auth status)" >&2; exit 1; }
  else
    rows="$(gh pr list --state open --base "$BASE" --limit 200 --json "$fields" \
      --jq '.[] | [.number, .headRefOid, .headRefName, .title, .mergeStateStatus, (.reviewDecision // ""), ([.latestReviews[]? | .state] | join(",")), .id, .baseRefName] | join("\u001f")')" \
      || { echo "open pull requests could not be read; check gh auth (gh auth status)" >&2; exit 1; }
  fi
  rows="$(printf '%s\n' "$rows" | sed '/^$/d' | sort -n)"
  if [ -z "$rows" ]; then
    if [ -n "$WANT" ]; then echo "pr-readiness: no pull request #$WANT"; else echo "pr-readiness: no open pull requests"; fi
    return 0
  fi
  local total=0 ready=0 judge_out k v r
  while IFS=$'\x1f' read -r PR_NUMBER PR_SHA PR_BRANCH PR_TITLE PR_MERGE PR_DECISION PR_REVIEWS PR_NODE PR_PR_BASE; do
    [ -n "$PR_NUMBER" ] || continue
    if [ -n "$WANT" ] && [ "$PR_PR_BASE" != "$BASE" ]; then
      echo "pr-readiness: #$PR_NUMBER targets ${PR_PR_BASE:-no branch}, not $BASE" >&2
      exit 1
    fi
    total=$((total + 1))
    judge_out="$(judge)"
    case "$MODE" in
      ready)
        if printf '%s\n' "$judge_out" | grep -q $'^verdict\tready\t'; then
          ready=$((ready + 1))
          printf '%s %s %s %s\n' "$PR_NUMBER" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE"
        fi
        ;;
      report)
        printf '#%s %s %s\n' "$PR_NUMBER" "$PR_BRANCH" "$PR_TITLE"
        while IFS=$'\t' read -r k v r; do
          if [ "$k" = verdict ]; then
            printf '  %-14s %-9s %s\n' "$k" "$v" "($r)"
            [ "$v" = ready ] && ready=$((ready + 1))
          else
            printf '  %-14s %-9s %s\n' "$k" "$v" "$r"
          fi
        done <<< "$judge_out"
        ;;
    esac
  done <<< "$rows"
  if [ "$MODE" = report ]; then
    if [ -n "$WANT" ]; then
      printf 'pr-readiness: #%s is %s\n' "$WANT" "$([ "$ready" -gt 0 ] && echo ready || echo not-ready)"
    else
      printf 'pr-readiness: %s of %s open pull request(s) are ready\n' "$ready" "$total"
    fi
  fi
}

self_test() {
  SELF_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pr-readiness.XXXXXX")"
  trap 'rm -rf "$SELF_TEST_DIR"' EXIT
  local dir="$SELF_TEST_DIR" me="$SCRIPT_ROOT/scripts/pr-readiness.sh" out rc failed=0
  mkdir -p "$dir/bin" "$dir/work"
  # `check` here is `./check.sh` and the stub's job is `Check (check.sh)`: the two have to read
  # as the same gate, or the kit's own check would look like it never ran.
  printf '[loop]\ndefault_branch = "trunk"\nreview_context = "Robot review"\ncheck = "./check.sh"\n' > "$dir/work/.loop.toml"

  # A stub gh: one open pull request on ticket/AA-01 whose facts come from $SCENARIO. Every
  # criterion passes unless $SCENARIO flips exactly one of them. It honours the review context
  # inside the caller's jq program, so a changed review_context is really queried.
  cat > "$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
sha=aaaaaaa111
sep=$'\x1f'
# reviewDecision is empty on a repository without required reviews, which this one is: the
# empty field is what proves the caller does not read across a collapsed separator.
branch=ticket/AA-01; title='AA-01: first'; merge=CLEAN; decision=; reviews=COMMENTED; base=trunk
case "$SCENARIO" in
  no-ticket) branch=backlog/ideas; title='Backlog: ideas' ;;
  branch-mismatch) branch=ticket/AA-02 ;;
  branch-suffix) branch=ticket/AA-01-extra ;;
  branch-bare) branch=AA-01 ;;
  behind) merge=BEHIND ;;
  dirty) merge=DIRTY ;;
  draft) merge=DRAFT ;;
  decision) decision=CHANGES_REQUESTED ;;
  reviewer) reviews=CHANGES_REQUESTED ;;
  other-base) base=release/v1 ;;
esac
row="12${sep}${sha}${sep}${branch}${sep}${title}${sep}${merge}${sep}${decision}${sep}${reviews}${sep}PR_node1${sep}${base}"
case "$1 $2" in
  "pr list")
    [ "$SCENARIO" = unreadable ] && exit 1
    printf '%s\n' "$row"
    ;;
  "pr view")
    # #12 is the one pull request; anything else is not there, and #13 is a pull request to
    # another branch, which the gate does not judge.
    case "$3" in
      12) printf '%s\n' "$row" ;;
      13) printf '%s\n' "13${sep}${sha}${sep}ticket/AA-03${sep}AA-03: third${sep}CLEAN${sep}${decision}${sep}${reviews}${sep}PR_node3${sep}release/v1" ;;
      *) echo "no pull request #$3" >&2; exit 1 ;;
    esac
    ;;
  "api repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100")
    case "$SCENARIO" in
      ci-failed) printf 'total\t1\nrun\tCheck (check.sh)\tcompleted\tfailure\n' ;;
      ci-queued) printf 'total\t1\nrun\tCheck (check.sh)\tin_progress\t\n' ;;
      ci-missing) printf 'total\t0\n' ;;
      ci-paged) printf 'total\t2\nrun\tCheck (check.sh)\tcompleted\tsuccess\n' ;;
      # A green run that is not the project's check: the real gate never ran.
      ci-unrelated) printf 'total\t1\nrun\tLint\tcompleted\tsuccess\n' ;;
      *) printf 'total\t1\nrun\tCheck (check.sh)\tcompleted\tsuccess\n' ;;
    esac
    ;;
  "api repos/{owner}/{repo}/commits/$sha/status")
    case "$*" in
      *'context == "Robot review"'*)
        case "$SCENARIO" in
          review) echo failure ;;
          review-missing) echo "" ;;
          *) echo success ;;
        esac
        ;;
      *) echo "" ;;
    esac
    ;;
  "api repos/{owner}/{repo}/commits/$sha")
    case "$SCENARIO" in
      no-ticket) echo 'Backlog: ideas' ;;
      subject-mismatch) echo 'AA-02: another ticket' ;;
      subject-suffix) echo 'AA-01-extra: first' ;;
      *) printf 'AA-01: first\n\nCo-Authored-By: Self Test <self@example.com>\n' ;;
    esac
    ;;
  "api graphql")
    case "$SCENARIO" in
      threads) printf '0\t1\tfalse\t\n' ;;
      threads-many) printf '2\t0\ttrue\tcursor-2\n' ;;
      *) printf '0\t0\tfalse\t\n' ;;
    esac
    ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  cat > "$dir/bin/bd" <<'EOF'
#!/usr/bin/env bash
case "$SCENARIO" in
  bead-open) printf '[{"id":"AA-01","status":"open","assignee":"","acceptance_criteria":"criterion"}]' ;;
  bead-unowned) printf '[{"id":"AA-01","status":"in_progress","assignee":"","acceptance_criteria":"criterion"}]' ;;
  bead-nocriteria) printf '[{"id":"AA-01","status":"in_progress","assignee":"someone","acceptance_criteria":"  "}]' ;;
  bead-missing) printf '[]' ;;
  bead-broken) printf 'not json' ;;
  *) printf '[{"id":"AA-01","status":"in_progress","assignee":"FueledByChai","acceptance_criteria":"the criterion"}]' ;;
esac
EOF
  chmod +x "$dir/bin/bd"
  export PATH="$dir/bin:$PATH" GH_LOG="$dir/gh.log" LOOP_ROOT="$dir/work"

  # assert_case <scenario> <the one criterion that fails> -- the named criterion fails with a
  # reason and every other criterion passes, so each criterion fails on its own evidence.
  assert_case() {
    local scenario="$1" expected="$2" key
    export SCENARIO="$scenario"
    rc=0; out="$("$me" --ready 2>&1)" || rc=$?
    if [ "$rc" != 0 ]; then echo "self-test[$scenario]: --ready should still exit 0 (rc $rc):"; echo "$out"; return 1; fi
    rc=0; out="$("$me" 2>&1)" || rc=$?
    if [ "$rc" != 0 ]; then echo "self-test[$scenario]: the report should exit 0 (rc $rc):"; echo "$out"; return 1; fi
    printf '%s\n' "$out" | grep -qE "^  $expected +fail  .+" \
      || { echo "self-test[$scenario]: $expected should fail with a reason:"; echo "$out"; return 1; }
    for key in ci conversations changes review current bead; do
      [ "$key" = "$expected" ] && continue
      printf '%s\n' "$out" | grep -qE "^  $key +pass  " \
        || { echo "self-test[$scenario]: $key should still pass beside $expected:"; echo "$out"; return 1; }
    done
    printf '%s\n' "$out" | grep -q '^  verdict        not-ready' \
      || { echo "self-test[$scenario]: the verdict should be not-ready:"; echo "$out"; return 1; }
    return 0
  }

  # The base case: all six pass, the verdict is ready, and --ready lists the one pull request.
  export SCENARIO=ok
  out="$("$me")" || { echo "self-test: the base case should pass:"; echo "$out"; exit 1; }
  for key in ci conversations changes review current bead; do
    printf '%s\n' "$out" | grep -qE "^  $key +pass  " || { echo "self-test: $key should pass in the base case:"; echo "$out"; exit 1; }
  done
  printf '%s\n' "$out" | grep -q '^  verdict        ready' || { echo "self-test: the base case should be ready:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q '^pr-readiness: 1 of 1 open pull request(s) are ready$' \
    || { echo "self-test: the summary should count one ready pull request:"; echo "$out"; exit 1; }
  # The configuration is read: the default branch names the merge state, the review context is
  # the one queried (the stub only answers "Robot review"), and `./check.sh` reads as the job
  # name `Check (check.sh)`.
  printf '%s\n' "$out" | grep -q 'merge state CLEAN against trunk' || { echo "self-test: default_branch should name the merge state:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q 'Robot review is success' || { echo "self-test: review_context should be the status queried:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q 'including check.sh' || { echo "self-test: a leading ./ in the check command should be dropped:"; echo "$out"; exit 1; }
  out="$("$me" --ready)" || { echo "self-test: --ready should exit 0:"; echo "$out"; exit 1; }
  [ "$out" = "12 aaaaaaa111 ticket/AA-01 AA-01: first" ] \
    || { echo "self-test: --ready should list the ready pull request alone, got:"; echo "$out"; exit 1; }
  # The queue is the configured base branch, read past gh's default page of thirty.
  grep -q -- '--base trunk' "$GH_LOG" || { echo "self-test: the list should ask for the configured base branch:"; cat "$GH_LOG"; exit 1; }
  grep -q -- '--limit 200' "$GH_LOG" || { echo "self-test: the list should ask for more than gh's default page:"; cat "$GH_LOG"; exit 1; }

  # --pr names one pull request: the queue is not listed, the same block is printed, and the
  # verdict is about that number rather than a count.
  : > "$GH_LOG"
  out="$("$me" --pr 12)" || { echo "self-test: --pr should exit 0:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q '^  verdict        ready' || { echo "self-test: --pr 12 should be ready:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q '^pr-readiness: #12 is ready$' || { echo "self-test: --pr should name the pull request in its summary:"; echo "$out"; exit 1; }
  grep -q '^pr view 12 ' "$GH_LOG" || { echo "self-test: --pr should read that pull request:"; cat "$GH_LOG"; exit 1; }
  grep -q '^pr list' "$GH_LOG" && { echo "self-test: --pr should not read the whole queue:"; cat "$GH_LOG"; exit 1; }
  out="$("$me" --pr 12 --ready)" || { echo "self-test: --pr with --ready should exit 0:"; echo "$out"; exit 1; }
  [ "$out" = "12 aaaaaaa111 ticket/AA-01 AA-01: first" ] \
    || { echo "self-test: --pr with --ready should list the one pull request, got:"; echo "$out"; exit 1; }
  # A pull request the queue would never hold is refused, not judged: another base branch, and
  # a number that does not exist.
  if "$me" --pr 13 >/dev/null 2>&1; then echo "self-test: a pull request to another branch must be refused"; exit 1; fi
  out="$("$me" --pr 13 2>&1 || true)"
  printf '%s\n' "$out" | grep -q 'targets release/v1, not trunk' || { echo "self-test: the refusal should name the branch:"; echo "$out"; exit 1; }
  if "$me" --pr 99 >/dev/null 2>&1; then echo "self-test: a pull request that does not exist must exit non-zero"; exit 1; fi
  out="$("$me" --pr 99 2>&1 || true)"
  printf '%s\n' "$out" | grep -q 'pull request #99 could not be read' || { echo "self-test: a missing pull request should say so:"; echo "$out"; exit 1; }
  rc=0; "$me" --pr 12a >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "self-test: --pr with a non-number should be a usage error (rc $rc)"; exit 1; }

  # Each criterion fails alone, and a not-ready pull request is never listed.
  assert_case ci-failed ci || failed=1
  assert_case ci-queued ci || failed=1
  assert_case ci-missing ci || failed=1
  assert_case ci-paged ci || failed=1
  assert_case ci-unrelated ci || failed=1
  assert_case threads conversations || failed=1
  assert_case threads-many conversations || failed=1
  assert_case decision changes || failed=1
  assert_case reviewer changes || failed=1
  assert_case review review || failed=1
  assert_case review-missing review || failed=1
  assert_case behind current || failed=1
  assert_case dirty current || failed=1
  assert_case draft current || failed=1
  assert_case bead-open bead || failed=1
  assert_case bead-unowned bead || failed=1
  assert_case bead-nocriteria bead || failed=1
  assert_case bead-missing bead || failed=1
  assert_case bead-broken bead || failed=1
  assert_case branch-mismatch bead || failed=1
  assert_case subject-mismatch bead || failed=1
  assert_case subject-suffix bead || failed=1
  assert_case branch-suffix bead || failed=1
  assert_case branch-bare bead || failed=1
  assert_case no-ticket bead || failed=1
  [ "$failed" = 0 ] || exit 1

  # A not-ready pull request is not listed by --ready.
  export SCENARIO=behind
  out="$("$me" --ready)" || { echo "self-test: --ready should exit 0 when nothing is ready:"; echo "$out"; exit 1; }
  [ -z "$out" ] || { echo "self-test: --ready should list nothing when nothing is ready, got:"; echo "$out"; exit 1; }
  out="$("$me" --pr 12)" || { echo "self-test: --pr should exit 0 on a not-ready pull request:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q '^pr-readiness: #12 is not-ready$' || { echo "self-test: --pr should say not-ready:"; echo "$out"; exit 1; }

  # The queue itself failing is the one non-zero exit: there is nothing to report about.
  export SCENARIO=unreadable
  if "$me" >/dev/null 2>&1; then echo "self-test: an unreadable queue must exit non-zero"; exit 1; fi
  rc=0; out="$("$me" 2>&1)" || rc=$?
  printf '%s\n' "$out" | grep -q 'could not be read' || { echo "self-test: an unreadable queue should say so:"; echo "$out"; exit 1; }

  # An empty queue reports that, and exits 0.
  cat > "$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  out="$("$me" 2>&1)" || { echo "self-test: an empty queue should exit 0:"; echo "$out"; exit 1; }
  printf '%s\n' "$out" | grep -q '^pr-readiness: no open pull requests$' \
    || { echo "self-test: an empty queue should say so:"; echo "$out"; exit 1; }

  unset LOOP_ROOT GH_LOG SCENARIO
  echo "pr-readiness self-test passed"
}

case "$MODE" in
  selftest) self_test ;;
  ready|report) need_gh; report ;;
esac
