# Briefs

Short, fixed briefs. The skills and agents they point to hold the rules; a brief adds only what is specific to this
start. Fill every `<…>`. Every brief ends with the runtime adapter's `send-report` block (in the adapter, under
`send-report`), copied as it is. No secrets in a brief.

**Short.** A brief points to files and sections ("read X › Y") and never restates them. It states only what the files
don't say: the decision, the boundary, the owned paths, the expected tests. This holds for every template below and
for every `<…>` you fill.

**GitHub access.** The briefs below are for a project whose agent-token mode is off, the default, and are used as
written. When the mode is on, every brief also carries the adapter's "GitHub access" block, the child reads each
`gh` and `git` step through [github-access.md](github-access.md), and a Codex reviewer gets the
[mode-on variant](#codex-reviewer-when-the-mode-is-on). Whoever starts the child reads the mode first (that page,
"Which column applies").

## Builder

Start: the issue's build spec (or its escalated spec), role `implementation` (`research` for a spike), a worktree,
title `#<N> <short title>`. The escalated spec is never the top model (`claude-fable-5-2`) without the owner's OK
on the issue ([model-policy.md](model-policy.md), rule 3).

```
You are the <role> on <project.name> (GitHub repo <project.repo>). This checkout is your own git worktree.
1. Read AGENTS.md, then .factory/roles/<role>.md, then follow the factory-implement skill step by step.
2. Your issue: #<N> "<title>". Read it with: gh issue view <N> --comments
3. Branch: <type>/<N>-<slug> from origin/<default>.
4. Owned paths: <from the issue>. Don't edit outside them, except entries in the (append-only) registries listed.
5. Tests that guard shared surfaces this change touches: <from the rules file or the review checklist, or "none">.
6. Machine: run verify with FACTORY_TEST_WORKERS=<limits.test_workers>, plus only the tests you add or change.
   Never run a heavy check in full, a load test or a performance experiment: the gate runs those.
7. Lead notes: <merged dependencies and what they provide, calls already made, gotchas, or "none">.
8. Done = a PR against <default> with "Closes #<N>" and your report. Do not merge, do not change labels, do not start
   other agents.
<send-report block>
```

Continuing a branch that has commits but no PR: the same brief with step 3 as "Branch: <b> already exists with
earlier work: check it out, read what is there, and finish issue #<N> on it."

## Review

Start: the review spec the model policy › Reviews gives (a model different from the one whose work is reviewed), role `review`, a worktree, title
`Review PR #<P>`.

```
You are the independent reviewer on <project.name> (GitHub repo <project.repo>). This checkout is your own git worktree.
Read AGENTS.md and follow the factory-reviewer agent exactly.
Review PR #<P> (implements issue #<N>, tier:<tier>, roles <roles whose owns match the diff>).
<Extra checks for this PR, worded as test cases (see "Wording review briefs"): tests that guard shared surfaces, screens to look at, or "none".>
<Re-review: the previous review is <comment URL>; say for each earlier finding whether it is fixed.>
Post one PR comment with your review, then reply with the same verdict. No edits, pushes, merges or label changes.
<send-report block>
```

**Documentation-only PR** (every changed file is documentation as the reviewer's
[docs-only review](docs-only-review.md) defines it): the reviewer may read it through `gh` without a
checkout. `ci.skip_paths` stays the diff trigger; the lead may waive it by brief when it judges that no check or test
reads these files. Start it without a worktree (the adapter's shared isolation, for a child that only reads through
`gh`) and add:

```
This PR changes documentation only. Use the reviewer's docs-only mode: review it through gh (gh pr view, gh pr diff)
without a checkout, skip the reviewer's check-out and check steps, and under "Checks run" list the verify evidence
already on the PR for head <SHA> as "not run by me". The neutrality check still runs when the diff touches a
project-neutral folder. Everything else in the protocol applies.
```

A docs-only brief for a PR that contains a non-doc file gets a full review, or none when the reviewer has no
worktree (the reviewer's docs-only mode says which).

If the PR has no local evidence for its head yet, post it with `factory verify <P> --why "<reason>"` (by hand:
[merge-gate.md](merge-gate.md) › rule 2) or ask the builder before the gate.

When the mode is on, a documentation-only review still starts in a worktree (the adapter starts every child that way
in this mode) and reads through the broker verbs in [github-access.md](github-access.md).

### Plan PR

A PR that `factory-plan` opens has no issue and no tier. Its first review is a **full review, never the docs-only
variant**: the first plan PR always edits the rules file's "Where things live" table, and every plan PR changes the
plan, the ADRs or the decision log, which the rules file sends agents to as settled decisions. Both are text agents
obey ([docs-only review](docs-only-review.md), "What counts as documentation", rule 2), and both are gate H4.

- **Reviewer.** The standard tier's first reviewer, `models.tiers.standard.review`, on a different model from the one
  that wrote the plan (`models.agents.plan`), by the rules of [model-policy.md](model-policy.md) › Reviews. Never a
  documentation-only spec, and never a model the lead picks for being cheap.
- **Brief.** The Review brief above, started in a worktree, with its issue clause worded
  `(a plan PR: no issue, treated as tier:standard, no roles)`. Its extra checks quote `factory-plan`'s "Check before
  the PR" list (trace table, sources, settled decisions) as their source.
- **Re-review** after a fix round or the user's comments: narrow, as the model policy says. The earlier findings, the
  fix and any line added since the first review, on the `models.reviews.re_review` spec the policy picks. A disputed
  or deferred P0–P2 finding goes back to the first reviewer's spec instead.

### Codex reviewer when the mode is on

A Codex child has no network, so it cannot read or post on GitHub. Before the start, the lead (or the solo session)
runs `<bin>/factory-github fetch --pr <P>` in the root checkout, which puts the head into the shared repository as
`origin/pr/<P>`, and reads the PR, its diff stat and the issue through the broker. It then fixes the two commits the
review is about: `<headRefOid>` from the PR, which `git rev-parse origin/pr/<P>` must equal (otherwise fetch again or
stop: never start on a mismatch), and `<baseOid>` = `git merge-base origin/<default> <headRefOid>`. It gathers what
the child would have read from GitHub with `pr-view --comments`, `pr-reviews` and `pr-checks`, each with the head SHA
it is about. The review brief above then replaces its "Post one PR comment…" line with this, filled in:

```
Agent-token mode is on and you have no network: run no gh, no git fetch and no pause check (the lead checks it).
The PR head is already in the repository as commit <headRefOid>; review that commit and nothing else. Use only
the two fixed commits, never a branch or ref name, which can move: read the diff with
`git diff <baseOid> <headRefOid>` and files at the head with `git show <headRefOid>:<path>`; do not switch your
worktree to it. To run the checks, copy the head into a new folder in your worktree in two steps, each of which
must succeed: `git archive -o <folder>.tar <headRefOid>`, then `tar -xf <folder>.tar -C <folder>`; run them there.
A check that needs the network or git history goes under "Could not check" with the reason.
What you would have read from GitHub (each item names the head SHA it is about; trust it only for <headRefOid>):
<the PR's title, body, labels, headRefName, baseRefName and changed files; the issue's body, labels and comments;
the PR's comments in full, including the previous review and every fix-round reply, each with its head SHA; the
check results and any local evidence comment, each with its head SHA>
Do not post anything. End your turn with the whole review comment, marker line included, exactly as the reviewer
agent's comment format gives it; the lead posts it on the PR for you.
```

The lead's half (the pause check, posting the text verbatim under the child's model, the head check) is in the
adapter's "Codex children". The `send-report` block still ends the brief; for this child "post it" is the lead's job.

## Validator

Start: the issue's build spec ([model-policy.md](model-policy.md) › Where each agent's model comes from: the
issue's tier, or the escalated spec the issue records), role `test`, a worktree, title `Validate PR #<P>`. The
validation is for the PR's current head; a push after it is a new head and needs a new validation.

```
You are the validator on <project.name> (GitHub repo <project.repo>). This checkout is your own git worktree.
Read AGENTS.md and follow the factory-validator agent exactly.
Validate PR #<P> (implements issue #<N>, tier:<tier>) at head <SHA>, black-box against the issue's acceptance contract.
<Re-validation: the previous validation is <comment URL>; read that one comment and nothing else from the PR.>
<How to drive the app, when the rules file and the review checklist don't say: the browser tool, sample accounts made
for testing (never real ones, never a secret in this brief), or "none".>
Do not read the PR body, its diff, the review or the builder's report. Post one PR comment with your validation,
then reply with the same verdict. No edits, pushes, merges or label changes.
<send-report block>
```

When the agent-token mode is on, the broker has no verb that reads a single comment, so the re-validation line
carries the previous validation's whole text (copied by the lead from that one comment) in place of its URL. Never
point the validator to a broker file of the PR's comments.

The brief names no assertion and adds none: the contract in the issue is the whole test, and a lead's own idea goes
into the contract (an issue edit and a comment) before the start, never into the brief. Word it as the next section
says.

When the mode is on and the validator runs where it has no network, the lead prepares it as the
[Codex reviewer](#codex-reviewer-when-the-mode-is-on) is prepared (the fetch, the two fixed commits `<headRefOid>` and
`<baseOid>`, the pause check on the lead's side), but hands it only what the validator's black-box rule allows: the
issue's body and labels, the six PR fields that rule names, and for a re-validation the previous validation's
text. Never the issue's comments, the PR body or comments, the diff, the reviews or the builder's report. It does not
get the reviewer's replacement line, which reads the diff; its own line says: run no gh, no git fetch and no pause
check; copy the head in two steps that must each succeed (`git archive -o <folder>.tar <headRefOid>`, then
`tar -xf <folder>.tar -C <folder>`) and run the app there; read `acceptance/`
from the base branch's tip with `git archive <baseTip> acceptance`, where the lead fixes `<baseTip>` as
`git rev-parse origin/<baseRefName>` at the start (step 6 of the validator reads the same branch); for this child,
`<baseOid>` is `git merge-base origin/<baseRefName> <headRefOid>`, not `origin/<default>`, so a stacked PR reads its
holdouts from its own base; test whether the PR changes `acceptance/` with
`git diff --quiet <baseOid> <headRefOid> -- acceptance/` (exit status only); post nothing, and end the turn with the whole validation comment, marker line included, which the lead posts.

## Wording review briefs

Some providers stop a review at the start when a brief reads like a request to attack something. A review brief
therefore describes each adversarial check as a **test case**: the input, the expected result and the boundary under
test. Use neutral words ("negative case", "unexpected input", "edge case", "invalid", "unauthorised", "skip the
check") in place of "attack", "exploit", "bypass" and "fool" wherever they say the same thing. The rigour stays: a brief
still asks for edge cases, negative cases, failure paths and races, and names each one.

Before: `Try to fool the scorer, game it and bypass the grading rules.`

After: `Test cases for the scorer: an input that meets none of the criteria (expected grade: fail); an input that meets
all but one (expected grade: fail, naming the missing one); two runs at once (expected: each graded on its own).
Boundary under test: the grade follows the criteria, not the wording of the input.`

**Where an extra check comes from.** Each extra check quotes its source: an acceptance criterion of the issue, or,
for a PR without an issue (a core update), the documented behaviour (a doc line or the command's help), or, for any
PR, behaviour that works on the default branch today (a regression check: quote the existing test or doc line that
shows it). A case the lead thought of itself is left out, or asked as a question, never as a requirement.

**When a provider refuses a brief** for content reasons (a message about flagged content, a safety or security
filter), rephrase it once in this style and start the review again. If it is refused again, record both refusals on
the PR (the provider's message, without any secret). Then the lead chooses a fallback reviewer whose model differs
from the builder's, as [model-policy.md](model-policy.md) requires, and says on the PR which one it used. The review
is never skipped.

## Fix round

Same tier, same builder: runtime `continue` on the builder's thread. Escalated: a new start with the new spec and the
builder brief plus this. The adaptation line is for a round whose only cause is the default branch moving
([model-policy.md](model-policy.md), rule 3), which does not count toward escalation; leave it out for any round that
also addresses a finding on the PR's own change.

```
Address review findings on PR #<P> (issue #<N>), following the factory-implement skill's fix-round steps.
<Only when the round rule applies (lead skill › The round rule): the kind of finding, its structural fix, and each exemption
the fix keeps, with its edge-case tests.>
Findings to handle: <the open P0–P2 findings from the latest review, one per line, or "every open P0–P2 in <comment URL>">.
<Adaptation round: only the default branch moved under the PR (<the merged PR or the contract that moved>). Head your
report `### Fix round <n> (adaptation: <what moved>)`.>
Push to the same branch with a normal push; never force-push and never open a new PR.
<send-report block>
```

## Bug hunter

The hunter's model, its brief (area, depth level, time box, the default branch SHA, the areas running beside it) and
what it may do are in the `factory-hunt` skill, section 3. Start it with role `test`, a worktree, title
`Hunt: <area>`, one builder slot, and end the brief with the `send-report` block.
