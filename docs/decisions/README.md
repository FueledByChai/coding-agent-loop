# Decisions

One file per decision, never edited in place: a change is a new record that supersedes
the old one. Cite a decision by its number. `scripts/decisions.sh new "<title>"` adds one.

- [0001](0001-the-kit-is-its-own-project-the-loop-s-work-is-ticketed-here.md) The kit is its own project; the loop's work is ticketed here — accepted
- [0002](0002-the-terminal-ui-is-bash-with-tput-and-stty-and-the-kit-ships.md) The terminal UI is bash with tput and stty, and the kit ships only scripts — superseded by 0013
- [0003](0003-the-terminal-ui-edits-the-working-tree-and-never-commits.md) The terminal UI edits the working tree and never commits — superseded by 0013
- [0004](0004-the-terminal-ui-s-views-render-from-uncut-fields-not-from-th.md) The terminal UI's views render from uncut fields, not from the padded tables — superseded by 0013
- [0005](0005-this-repository-s-own-merge-gating-is-applied-by-hand-and-re.md) This repository's own merge gating is applied by hand and recorded, not checked — accepted
- [0006](0006-the-check-lets-the-loop-s-own-review-status-through-and-noth.md) The check lets the loop's own review status through, and nothing else — accepted
- [0007](0007-the-agent-review-is-required-here-and-a-scheduled-run-on-the.md) The agent review is required here, and a scheduled run on the owner's machine produces it — superseded by 0019
- [0008](0008-the-section-that-describes-the-check-is-compared-with-the-sc.md) The section that describes the check is compared with the script by name — accepted
- [0009](0009-the-skills-a-harness-loads-are-pointers-to-the-prompts-insta.md) The skills a harness loads are pointers to the prompts, installed from the kit — accepted
- [0010](0010-the-settings-example-is-a-synced-kit-file-and-loop-toml-besi.md) The settings example is a synced kit file, and .loop.toml beside it is the project's — accepted
- [0011](0011-the-stories-view-s-filters-narrow-the-rows-once-in-the-shell.md) The stories view's filters narrow the rows once, in the shell, not in the renderer — superseded by 0013
- [0012](0012-beads-is-the-ticket-store-and-git-is-still-the-proof.md) Beads is the ticket store, and Git is still the proof — accepted
- [0013](0013-the-terminal-ui-is-removed-and-the-prompts-with-their-skills.md) The terminal UI is removed and the prompts with their skills are the whole interface — accepted, supersedes 0002
- [0014](0014-beads-is-a-hard-dependency-and-a-checkout-without-a-queue-is.md) Beads is a hard dependency, and a checkout without a queue is told so — accepted
- [0015](0015-the-markdown-ticket-file-retires-and-the-stories-stay-a-docu.md) The markdown ticket file retires, and the stories stay a document — accepted
- [0016](0016-persist-merge-admission-in-a-fenced-shadow-queue-before-enab.md) Persist merge admission in a fenced shadow queue before enabling live adapters — accepted
- [0017](0017-require-author-evidence-and-completed-head-review-before-acc.md) Require author evidence and completed head review before acceptance handoff — accepted
- [0018](0018-keep-review-worker-jobs-durable-and-separate-from-merge-auth.md) Keep review worker jobs durable and separate from merge authority — accepted
- [0019](0019-plan-merge-order-and-separate-acceptance-from-final-status-p.md) Plan merge order and separate acceptance from final status publication — superseded by 0028
- [0020](0020-request-ci-explicitly-and-reject-unrelated-labels-without-sk.md) Request CI explicitly and reject unrelated labels without skipping the required job — accepted
- [0021](0021-fence-live-ci-admission-and-merge-authority-with-a-dedicated.md) Fence live CI admission and merge authority with a dedicated App and protected controller — accepted
- [0026](0026-use-existing-agent-acceptance-for-the-first-live-merge-queue.md) Use existing agent acceptance for the first live merge queue — accepted
- [0027](0027-require-explicit-permission-for-complete-live-ruleset-inspec.md) Require explicit permission for complete live ruleset inspection — accepted
- [0028](0028-stage-queue-files-without-changing-an-active-legacy-merge-pa.md) Stage queue files without changing an active legacy merge path — accepted, supersedes 0019
