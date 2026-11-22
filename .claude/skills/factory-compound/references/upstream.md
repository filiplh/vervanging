# General lessons go upstream

A lesson that would hold in any project (SKILL.md § 4) belongs in the factory core, so every project gets it. The
core is never edited in a project: it changes in the factory repo and arrives through `factory-update` as a
reviewable PR. This run drafts the proposal; the lead files it.

## Which repo

The factory repo is the source the project's core files come from, the one `factory-update` pulls. If the project's
files do not say where that is, ask the user once and do not guess.

## Is it really general?

Before drafting, check the lesson against the core's neutrality rule: the proposal must make sense with every name
from this project removed (project, repo, product domain, human language, folder layout, stack). Split it when it
does not:

- the **mechanism** (a gate condition, a step in a skill, a field in a report, a check in the `factory` command, a
  default) goes upstream;
- the **specifics** (this project's paths, commands, terms, thresholds) stay in the overlay, or become a new
  `factory.yaml` key proposal only when another project would need a different value (the factory's rule for new
  keys).

Search the factory repo's open and closed issues and PRs for the same lesson first (reading is fine). If one exists,
draft the new evidence as a comment for it instead of a second issue; it is posted like an issue (Filing it, below).

## The draft

Write it in the language the factory repo uses for issues. It follows the factory repo's issue shape:

```markdown
Title: <type>(core): <the change, in a few words>

**From:** a compound run in a project using the factory, after <the kind of incident>, <date>.

### What went wrong
<What happened, described without project names, private paths or personal data. One paragraph.>

### Why the core let it through
<Which skill, reference, gate, hook or template should have caught it, and why it did not.>

### Proposed change
<The smallest change: which core file, and what it would say or check. Prefer a check over a sentence, as in
forms-and-destinations.md. Say whether it is a process change.>

### Evidence
<Links the factory repo's readers can open, or a summary when the project is private. No secrets, no personal data.>

### Alternatives
<Other options, including "leave it", with their cost.>

## Acceptance criteria
- [ ] <testable assertion>

## Owned paths
<the core paths it would touch>
```

Do not set labels the factory repo's own lead sets (tier, status, milestone); propose a work kind and a tier in the
text if useful.

## Filing it

Anything written to the factory repo (an issue, a comment, a PR) leaves the project's repo, so it waits for gate H9
([`.factory/reference/human-gates.md`](../../../../.factory/reference/human-gates.md); `core/reference/human-gates.md` in the
factory repo), whoever owns the factory repo. Until H9 is resolved, the draft stays on the incident and nothing is
written there.

- **Team mode:** the lead collects the waiting drafts and asks the user once (in the status update, not per lesson)
  which to file. For each approved one it files the issue or comment, links the approval from it, comments its link
  on the incident (the compound record's `Upstream:` line), and tells the user in one line. **Solo mode:** the
  person's session asks the person and files only what they approve.
- **A process change** (a change to how the core makes agents work) is also put to the user as a question with the
  recommended answer, and the user's answer is linked from the issue. The factory repo's own rules then decide when
  and how it merges.
- **A factory repo owned by someone else** (a third party, not the user or the user's organisation): the user files it
  themselves, or approves each one explicitly; never in a batch.
- **A PR instead of an issue** only when the factory repo's own rules allow outside PRs and the user asked for one; it
  is opened from a separate checkout of the factory repo, never from the project.

## While it is open

When the project needs protection before the core change arrives, add a short temporary rule or check to the overlay
(as for a project lesson) that links the upstream issue and says it retires when the core version that carries the
change is installed. The next prune after that `factory-update` removes it (prune.md › Retire).
