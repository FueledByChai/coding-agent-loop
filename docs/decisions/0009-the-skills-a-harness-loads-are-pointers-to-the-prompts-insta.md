# 0009 — The skills a harness loads are pointers to the prompts, installed from the kit

Status: accepted
Date: 2026-09-14

## Context

The kit's prompts exist once, in `prompts/<name>.md`, and `commands/<name>.md` deliberately does not
restate them: each is a two-line pointer naming `loop/prompts/<name>.md`. The skills a harness loads
are the other half of that integration and the kit did not own them. `skills/` was untracked staging,
`install.sh` took `--commands <dir>` and had no flag for skills, and the `SKILL.md` files a harness
read were copies of the prompt body that someone made by hand. Nothing compared a skill with its
prompt, so they drifted silently, and a drifted skill is worse than a missing one: the harness loads
it, the agent follows the older rule, and no check can see it, because the file a check would have to
compare is not in the repository.

It had already happened. On 2026-09-14 `next-ticket`'s skill was missing the sentence that has
`--next` take the `sprint` list first, in its order, then file order, so an agent that loaded the
skill worked tickets out of the order the list states — the failure LK-15 exists to catch.
`review-prs`'s skill was missing the whole `scripts/open-ticket-pr.sh --update-all` paragraph, and
`grill-me`'s was missing four passages, among them the sprint paragraph LK-17 is about. All three
were re-synced by hand, which fixed the copies and not the cause.

## Decision

`skills/<name>/SKILL.md` is tracked in the kit and is frontmatter plus the same pointer its
`commands/<name>.md` carries, minus the command's `$ARGUMENTS` placeholder. It restates nothing, so
there is nothing in it to drift.

`install.sh --skills <dir>` installs one per prompt, each into its own directory
(`<dir>/<name>/SKILL.md`), which is the layout a harness reads. Its self-test asserts, for every file
in `prompts/`, that a skill exists, that the installed skill carries the pointer naming
`loop/prompts/<name>.md`, and that no line of the skill's body appears anywhere in the prompt it
points at — so a skill that restates a rule fails, whether it was edited by pasting a paragraph in or
by replacing the body with the prompt. `README.md` says what a harness has to load.

## Alternatives

- **Keep the skills outside the kit and add a check comparing each against its prompt.** Rejected on a
  structural point rather than on taste: a check can read only files in the repository, and the drift
  this record is written from happened in the *installed* copies, outside it. Such a check would
  compare the kit's copy with the prompt and stay silent about the copy the harness actually loads —
  it would police the smaller half of the fault.
- **Ship the restatements and compare them with their prompts.** The same objection, plus the
  restatements have to be maintained: every prompt edit becomes a second edit, and the comparison can
  only tell you that you forgot one.
- **Install one file per harness with no frontmatter.** The frontmatter is what lets a harness decide
  when to invoke a skill; without it the skill cannot be loaded at all.
- **Have `install.sh` generate the skills from the prompts at install time.** Then the skills are not
  reviewable in the repository and a fresh install writes files nobody has read. The pointer is a
  file worth seeing.
- **Leave `skills/` untracked and document the copy step.** That is the state this ticket was filed
  from, and it is what produced the three drifted copies.

## Consequences

A prompt edit no longer implies a skill edit. The `description:` in each skill's frontmatter is still
a hand-written summary of the prompt's purpose — it is what a harness matches to decide whether to
invoke the skill, and it is the one remaining place a stale sentence can live. It states no rule, so
a stale description mis-describes rather than misdirects, and this record does not pretend otherwise.

`skills/` becomes tracked, and `scripts/loop-kit-sync.sh` still carries only `scripts/`, `prompts/`
and `templates/` — the pointers are installed once and never synced, exactly as `commands/` is today.
That is safe because a pointer names a path instead of restating content, so it cannot go stale; a
prompt added to the kit needs a skill added beside it, and that is a change to the kit, not to a
project.

The skills this machine's harness loads become pointers too, once the owner installs them, so a run
of the loop reads `prompts/<name>.md` rather than a copy of it.

## What would show this was wrong

A harness that loads a skill but does not follow a file it names — the loop's runs would then start
following a two-line file instead of the prompt, and the fix would be to keep the restatements and
accept the comparison check instead. Or a prompt whose text a skill has to carry because the harness
never resolves the path, which would show up as the same failure on one skill rather than all of
them.
