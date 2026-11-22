# The update PR

Title: `chore: update factory <old> → <new>`. Write the body in the language the rules file sets for PR text. Most
of it is `<state>/summary.md`, pasted as it is; you add the parts it cannot know.

```markdown
Updates the factory core from <old> to <new> (<upstream>, commit <sha, when the source is a checkout>).

<What changed between the two versions, from SKILL.md step 2: the commit list and the breaking: lines, or, when no
full clone could be made, that no history could be read and why.>

Closes #<the issue for this update>

<summary.md as written by factory-update run: Core version, Core files, New factory.yaml keys, Human gates,
Proposed, not written, Installer notes and the factory-install check output>

## Local edits
<One line per edited core file and what the person decided: kept (with a link to the proposal or the upstream
draft), discarded (and where its content moved in the overlay, if it moved). "None." when there were none.>

## Proposals
<Each proposal in <state>/proposals/ (missing overlay files, rules sections, settings merges, kept files' new core
version, CI the repo did not take): the path and its diff, in a <details> block each. None of them is written by
the update; a person takes one into the PR or leaves it. "None." when there were none. When one is a settings merge,
say that until it is applied, doctor's `hooks` check fails.>

## Labels
<From step 5. Created: the names of the labels the update added, or "none". Kept: one line per `kept` label from the
dry run, with the project's and the factory's colour and description, as factory-install reported it, or "none".
Close with: "Existing labels keep the project's colour and description; name any you want changed to the factory's
values." Labels a person had changed with --use-factory: each `updated` line, old and new values.>

## Answers
<The values that rendered core files (CI workflows, deploy recipes' files), each with the file it was derived from.
Any answer the person gave because the files did not say, marked as such.>

## Own workflows
<The doctor's warning that the repo has its own workflows and `ci.external` is empty, copied from the `factory.yaml`
line of the doctor run (SKILL.md step 6) or from any of that check's detail lines, with or without a `warning:`
prefix (with two or more warnings only the first is on the result line, and the rest are unprefixed detail lines;
after a failure every warning is a `warning:` line), with the workflow names it lists. Add that the merge gate may
refuse PRs for their checks, that the fix is to list their jobs in `ci.external` (the factory repo's docs/factory-yaml.md › ci.external), and that it is a change to `factory.yaml`: the
project's own PR and a human gate. Write "None." only when the check ran and showed no such warning. When
`factory.yaml` did not parse, the question was not answered: write "Not checked: factory.yaml cannot be read.">

## Needs the owner's OK
<Each of these that applies, one line each: the human-gate list changes; a process change (the summary's H4 line);
a new factory.yaml key whose default changes how this repo works; a new dependency or action (H2). "Nothing beyond
the normal review." when none applies.

The OK quoted here approves merging this update, either given for this PR or as a standing approval that covers
merging it (quote it with its date and what was asked). A yes to opening the update PR is not that approval: ask for
the merge in the same question, or ask again before the merge. What resolves a gate is in human-gates.md › Resolved
or not.>

## Acceptance criteria
- [ ] The copied core is version <new>, as the lock records: `factory-install check` prints `ok`, apart from kept files
- [ ] `factory-doctor` reports no failure on this branch, apart from checks a listed proposal fixes
- [ ] Every proposal is decided by a person: taken into this PR or left
- [ ] The repo's verify command passes on this branch

## Checks run
<The commands you ran on this branch and their real output: factory-update check, factory-install check,
factory-doctor and the repo's verify command, all four every time.>
```

Rules:

- The gate reads "Acceptance criteria" as a list only: the heading, then `- [ ]` or `- [x]` items with nothing between
  or after them but indented explanations. An intro line, a bold line or a second heading of that name inside the
  section makes the whole list unreadable. Put what you would say in "Checks run". Fill in the issue number and the
  `<new>` version; keep the rest as shown, and add a criterion only in the same form.
- Each criterion has the step of SKILL.md that produces its evidence (the update's `factory-install check`, the
  doctor and verify item of its commit step, and the proposals), and you tick it only when that step ran and its
  output is in "Checks run". A person ticks the proposals criterion; with
  no proposals you tick it and write "None." under "Proposals". The doctor criterion is ticked when every failing
  check is named in a listed proposal that fixes it; its line then reads
  `- [x] ... apart from checks a listed proposal fixes: <check> (<proposal>)`.
- **A criterion left open** (a failing verify, or a doctor failure no proposal fixes; not the proposals criterion,
  which waits for the person's tick) has one rule, rule 5's: after the PR is open, create an issue for its gap and
  link it from that line (`- [ ] <criterion>: not met, see #<new issue>`). The gate accepts only an open issue created after the PR was
  opened, never an older one; edit the PR body to add the link.
- Never claim a check you did not run. A failed or skipped check is reported as such.
- Never merge it, and never set or clear labels to get it through. A person approves it.
- Keep the summary's tables as they are; do not shorten the human-gate diff.
