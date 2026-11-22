# Bug reports and the hunter report

Write in the language `AGENTS.md` sets for issue text. Quote what the app shows exactly as it shows it.

## Priorities

The core definitions. The overlay's `## Priorities` in `.factory/hunters.md` adds product examples; the core
definition wins when they disagree. When in doubt between two levels, pick the higher one and say why.

| Priority | Meaning |
| --- | --- |
| **P0** | Blocker. The app is unusable for everyone, a security hole is open, data is lost silently, or personal data leaks. |
| **P1** | A core flow is blocked or gives a wrong result, data is lost or corrupted in a common case, the app goes blank, or a privacy leak needs unusual steps. |
| **P2** | A core flow breaks in a specific case, undo or recovery is broken, a serious accessibility barrier, a layout that hides or breaks content, wrong or misleading copy in a core flow. |
| **P3** | Cosmetic, polish, or a rare edge case with an easy workaround. |

P0–P2 go to `status:ready`; P3 goes to `status:backlog`.

## Issue

Title: a conventional title naming the symptom a user sees, `fix(<scope>): <what goes wrong, and when>`. A regression
starts the description with "regression:".

```markdown
**Blocked by:** none

**Found by:** bug hunt (hunter:<slug>), <date>, `main` at <short SHA>, <how the app ran: the serve command, the
device, size or environment used>.

**Work kind:** <kind from work_kinds>

**Priority:** P<n>. <Why this level: who is hit, how often, what they lose, whether there is a workaround.>

### Steps
1. <From a clean start. Every step a person can follow. Made-up sample data only.>
2. …

### Expected
<What should happen, and the rule, criterion or convention that says so (AGENTS.md, an issue, a standard).>

### Actual
<What happens instead. Exact messages and values. The cause, when you found it; say so when it is a guess.>

### Evidence
<Logs, probe output, test output, a screenshot path in the issue. Trimmed to what proves the bug. No personal data, no
secrets, no tokens.>

### Affected files
- `<path>`: <what in it is wrong, when known>

### Related
<Linked issues and PRs: duplicates checked, the earlier fix for a regression, related bugs. "none found" plus the
search terms you used.>

### Acceptance
- <A test a fix must add that fails today: the regression test.>
- <Any other observable criterion.>

## Owned paths
<The files a fix is expected to touch, so the lead can schedule it next to other work.>
```

Rules:

- **Reproducible from the text alone.** A builder who has never seen the app can follow the steps and see the bug.
- **Evidence over opinion.** Every claim in "Actual" is backed by something in "Evidence".
- **Unconfirmed is marked.** A guess about the cause or a rule interpretation you could not check is marked with the
  marker `AGENTS.md` names for unconfirmed claims.
- **No personal data, no secrets.** Sample data only; scrub screenshots and logs.

## Hunter report

Posted on the status issue (`factory:status`) and made the final message.

```markdown
## Hunt: <slug>, depth <n>, `main` at <short SHA>

<First line: any P0 filed, with its number. Otherwise "No P0.">

**Filed:** <n>
- #<N> P<n> <title>
- …

**Not filed, already tracked:** #<N> (<comment added | nothing new>), …
**Seen once, not reproduced:** <what, where> (or none)
**For other areas:** <bug> → area `<slug>` (or none)
**Covered:** <what this pass went through>
**Not reached:** <what is left for the next pass>
**Questions for a person:** #<N> or none
**Missing tools:** <a skill or command that would have helped> (or none)

Model fit: <right | too weak | more than needed> (<hunter | domain_hunter | process_hunter>, <model spec>, kind hunt:<slug>): <one-line reason>
```
