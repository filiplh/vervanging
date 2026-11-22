# The glossary

The project's own words, so people and agents use one term for one thing. A grill logs a resolved term as a decision
(`Term: <word> means …; avoid <other words>`) with a glossary follow-up; `factory-plan` carries every such decision
into the glossary.

## Where it lives

The file `AGENTS.md` names; else a glossary section the plan already has; else `GLOSSARY.md` next to the plan,
created by the PR, which then proposes that `AGENTS.md` names it (a rules change, so the user approves it). User-facing
copy and its translations live in `.factory/voice.md`, when the project has one; the glossary defines meaning, the
voice file defines wording.

## Format

A project with a glossary keeps its format. A new one:

```markdown
# Glossary

The words <project> uses for its own things. One term per thing; use it in code, docs, issues and copy. Changes come
through the plan PRs.

| Term | Means | Avoid | Source |
| --- | --- | --- | --- |
| <term> | <what it means, one or two sentences; the boundary where it stops applying> | <words not to use for it> | [<log slug> D<n>](<relative path to the log>#decisions) |
```

Sorted alphabetically by term. A project whose user-facing copy is in more than one language may add one column per
language after "Term", in the order of `factory.yaml` › `project.languages`, and one for the name used in code.

## Rules

- **One row per term**, taken from the `Term:` decision: the word, its meaning, the words to avoid, the citation.
  Keep the log's wording; tighten it only where it is ambiguous, and say so in the PR.
- **A term that already exists** with the same meaning gets the new citation added. With a different meaning, the
  new log must say it replaces the old one; the row then keeps a short note: `Until <date>: meant …`, with both
  citations. Without that, it is a conflict for the user (skill §2).
- **A term the voice file words differently** (it calls the same thing by another name in user-facing copy) is a
  question in the PR, not an edit to either file.
- **Only resolved terms.** A word the log calls vague but never resolved goes in the PR's questions, not the glossary.
