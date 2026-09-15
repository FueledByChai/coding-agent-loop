# 0006 — The check lets the loop's own review status through, and nothing else

Status: accepted
Date: 2026-09-14

## Context

LK-13 gave `scripts/ruleset-check.sh` a one-way rule: every context a ruleset requires must name a
job in the workflow it pairs with. The fault it was written for is real — a required context no
job reports holds every pull request forever while every other check is green, which is what this
repository's own `ci/ruleset.json` would have done had LK-09 applied it unread. It then made the
pairing something the check tests rather than something a person reads by eye.

LK-06 walks into the other side of that rule. It has to add `{"context": "Agent review"}` to
`.github/ruleset.json`, and the review's status is not a job and cannot be one: it is a commit
status posted by `scripts/review-status.sh` from a machine with the owner's subscription, because
no agent subscription lives on GitHub and no API key should. The README already tells a project to
do exactly this — "Add the context to the branch ruleset's required status checks and auto-merge
waits for it" — so the kit instructs a configuration its own check fails:

```
$ scripts/ruleset-check.sh /tmp/rs-test.json .github/workflows/ci.yml
ruleset-check: /tmp/rs-test.json requires "Agent review", which .github/workflows/ci.yml has no job named; its jobs report "Check (check.sh)"
exit=1
```

Not hypothetical: Tessera's committed `docs/github/ruleset-main.json` is already in that shape, two
job contexts beside `{"context": "Agent review"}`, so a project that names that pair in its own
check cannot pass it while following the README. The check has to learn the one exception, or the
kit's instruction and the kit's check stay in contradiction.

## Decision

`scripts/ruleset-check.sh` reads `review_context` from `.loop.toml` through
`scripts/loop-config.sh` and treats that one context as satisfied without a job. Every other
required context must still name a workflow job.

## Alternatives

- Exempt any context with no `integration_id`: the file itself says which contexts are not Actions
  jobs, since a job context carries `integration_id: 15368`. Rejected because it would stop
  catching a hand-written ruleset that omits the binding for a job context — a renamed job would
  then deadlock silently — and because the check has never read `integration_id`, so this would
  add a rule rather than relax one.
- Take the allowed contexts as another argument, `--allow "Agent review"`: rejected because the
  name would then live in `.loop.toml` and in the check's invocation, and the two could drift
  apart silently. A check whose exemption list can disagree with the config is the class of bug
  this check exists for.
- Satisfy it with a job: add a job to `.github/workflows/ci.yml` named `Agent review` that does
  nothing. Rejected because a required check that always passes gates nothing — worse than no
  check, since it looks like one — and the review cannot run in Actions anyway.
- Require both that the context is the configured review context *and* that it carries no
  `integration_id`: rejected as more than the case needs. The name is already exact, and the extra
  condition would make the exemption depend on the file's shape rather than on what the loop
  promises to post.
- Leave the check as it was and drop the review context from `.github/ruleset.json`, requiring it
  only in the applied ruleset: rejected because the file is where the applied ruleset comes from
  (0005), so the two would drift and a re-application would silently drop the review — the same
  defect, undetected, that Tessera is in today.

## Consequences

The check's guarantee is now "every required context is a workflow job name, or the loop's own
review context", and its self-test proves both directions plus the fact that the name comes from
the config rather than being hardcoded. LK-06 becomes landable, and a project that follows the
README's review step no longer has to choose between the review and the check.

What the check cannot do is know whether the review actually runs. A project that sets
`review_context` and never runs the review can still require it and deadlock every pull request;
that is outside a static check's reach, and `.loop.toml`'s comment above the key is where the loop
says who runs it. The exemption is also one name, not a category: a second status posted from the
owner's machine — a deploy gate, a coverage badge — would have to be a job, or this decision has to
be revisited.

## What would show this was wrong

A project deadlocks on the review context because the review never ran there. That would mean a
static check cannot carry this promise at all, and the answer is either something that verifies
the review runs or an exemption removed in favour of requiring the context only where a runner
exists.

Or the exemption grows — a second app-less context, a list in the config — and the rule stops
being "the one status the loop posts" and becomes "whatever the config says", at which point the
check is only asserting the config against itself.
