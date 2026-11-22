# Pruning: merge and retire stale rules

Rules added one per incident pile up, overlap and contradict each other, and a long file is read less carefully than a
short one. A prune keeps every lesson in one place, in its strongest form, and removes what no longer earns its place.
It never removes a lesson that still guards something.

## Scope

- **Neighbourhood** (every compound run): the rules in the same section of the same file as the lesson just added, plus
  any rule the new lesson contradicts or repeats wherever it is. Act only on evidence already in hand; anything that
  would need its own investigation is flagged for the next full prune.
- **Full prune** (at a milestone close, when the lead or the person asks, or when a file gained more rules than it lost
  since the last prune): the overlay files that hold rules: `AGENTS.md`, the role files, `.factory/review-checklist.md`,
  `.factory/hunters.md`, `.factory/voice.md` and the project's domain skills. Prune one file at a time, the one that
  grew most first.

Find the last full prune from its PR (title starting with `Prune rules:`):
`gh pr list --state merged --search "Prune rules: in:title" --limit 1 --json number,mergedAt`.

## Steps

1. **List the rules** in scope. For each: what it requires, its incident link, and whether a check or checklist item
   already holds it.
2. **Find each rule's origin** when it has no incident link: `git log -L` or `git blame` on its line, then the PR and
   issue of that commit. Add the link when you find it.
3. **Look for coverage with positive evidence.** A rule is covered only when a named artefact states it in its own
   text: a test or lint whose assertion or failure message carries it, a checklist item, a core skill or reference, or
   another rule. Quote the artefact. A related file name or topic is not coverage.
4. **Give each rule one outcome** (below).
5. **Check the result reads as one file:** no rule contradicts another, related rules sit together, the file's
   structure still matches its template's sections.
6. **One PR per prune**, titled `Prune rules: <file or "overlay">`. Its body lists every merged, narrowed and retired
   rule with its evidence (the quoted artefact or the reason), so a reviewer and a later reader can follow each cut. A
   prune that touches the rules file or `factory.yaml` waits for the user's OK (H4), as one approval for the batch.

## Outcomes

| Outcome | When | Do |
| --- | --- | --- |
| **Keep** | The rule is accurate, needed, and nothing else holds it | Nothing. Never edit only for wording, typos or style. |
| **Merge** | Two or more rules say the same thing, or one is a special case of another | Keep the broader one, fold in anything only the other said, keep both incident links, delete the other. |
| **Narrow** | A check or checklist item now holds part of the rule | Cut the part the artefact holds, keep what it does not (the reason, a measured fact, a rejected alternative), and point to the artefact in one line. |
| **Retire** | A check now holds the whole rule; or what the rule guarded is gone (the feature, tool, dependency or outside condition no longer exists, shown by evidence); or it was a temporary rule whose retire condition is met | Delete it. Git history is the archive; leave no "retired" stub in the file. If the rule's own incident is still the best explanation of a check, move that link into the check's comment first. |
| **Flag** | No incident link, no origin found, and no evidence that it is wrong or covered | Leave it, and list it in the prune PR for the user with a recommendation. |

What counts as evidence for **retire**:

- the quoted check or checklist item that holds the rule's whole class;
- the commit or PR that removed what the rule guarded, and confirmation that the problem itself is gone too (a removed
  file proves the code is gone, not that the problem is);
- for a temporary rule, the condition it named, checked the way it said (the upstream issue closed and the core
  version that carries the fix installed, the outside bug fixed).

## What a prune never does

- Retire or weaken a human gate, a settled decision, or a rule a gate relies on. Gates are only ever added.
- Delete a rule because it is old, or because nothing in the repo confirms it. Age alone is not staleness, and a rule
  nobody can verify is not therefore wrong: flag it.
- Delete a rule that another file cites for its content without fixing that citation in the same PR.
- Change product code, or write new checks. A rule that a check could hold becomes a recommended check (an issue, as
  in SKILL.md § 4), and the rule stays until the check exists.
- Edit core files. A core rule that looks stale is a general lesson ([upstream.md](upstream.md)).
- Move rules between files on a judgement call. Move one only when it plainly sits in the wrong place (a role-only
  rule in the rules file, a reviewer's check in a role file), and fix the links in the same PR.
