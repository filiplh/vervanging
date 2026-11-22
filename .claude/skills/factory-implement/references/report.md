# The implementer's report

One report, two places: a comment on the PR, and your final message. Short and factual. Every section is filled in;
write "none" when there is nothing to say. Write it in the language `AGENTS.md` sets for PR text, translating the
headings if it asks for that. The model fit line follows the model policy's format (`reference/model-policy.md`).

## After implementing an issue

```markdown
## Implementer report: #<N>

**Built:** <files or modules, and any decision the reviewer or lead should know>

### Acceptance criteria
- [x] <criterion>
- [ ] <criterion>: not met, because <reason> (follow-up: <what>)

### Checks (head <SHA>)
FACTORY_TEST_WORKERS=<cap>
- `<exact verify command>`: <passed | failed>, <pass> passed, <skip> skipped, <fail> failed
- `<check name>`: `<exact command>`: <result with counts>
- `<heavy check name>`: not run in full (heavy, left to the gate); ran only <files>: <result>
- not run: <check>, because <reason>
- CI: <green | failed: job | not started: reason | not in ci.pr | draft>

### Evidence on a real target
<what was tried on the real target the overlay names (a device, a board, a store build), or "not tested on a real
target". A browser, simulator or emulator run is automated evidence, never proof for a real target.>

### Known limitations
<what doesn't work yet, edge cases left out, or "none">

### Data impact
<persisted shapes, migrations, stored data or config this change touches, and whether old data still loads, or
"none">

### Needs confirmation
<claims marked as unverified in code and docs, manual checks, product questions, or "none">

### Follow-ups
<things you noticed outside this issue, for the lead to turn into issues, or "none">

Model fit: <right | too weak | more than needed> (builder, <model spec>, tier:<tier>, kind <work kind>): <one-line reason>

PR <full URL>, head <SHA>, checks and reviews <state>
```

When the work is not done (verify stays red, a blocker you could not clear), add a line right after **Built:** that
starts with `Not done:` and says why; the factory's Stop hook refuses a report that claims done without a green
`factory verify` on the current commit, and lets a `Not done:` report through. A report on finished work never carries
that line.

Rules for the Checks section:

- List what you actually ran, with the exact command and the real counts. A check that failed, was skipped or did not
  run is listed as such. Never write "passed" for a result you did not see.
- Name the head SHA and its tree (`git rev-parse HEAD^{tree}`) the results belong to. They count only for a head with
  exactly that tree (merge-gate.md › rule 2): after a rebase or a new commit that changes content, run again.
- Keep automated evidence (unit and integration tests, a browser, a simulator, an emulator) apart from evidence on the
  real target.

## After a fix round

Same report, with this section after **Built** and the Checks section rerun on the new head:

```markdown
### Fix round <n> (review of <date or comment link>)
| Finding | Priority | Disposition | Change and test |
| --- | --- | --- | --- |
| `<path:line>` <short title> | P1 | fixed | <commit SHA>, regression test `<test name>` |
| `<path:line>` <short title> | P2 | rejected: <evidence> | none |
| `<path:line>` <short title> | P2 | pre-existing on main: follow-up proposed | none |
| `<path:line>` <short title> | P3 | follow-up | none |
```

`<n>` counts the fix rounds on this PR: 1 for the first, and so on. Count every earlier `### Fix round <n> (…)` heading
on the PR, the lead's or solo session's `(lead)` and `(adaptation: …)` comments included, rather than relying on
memory. When your brief says the round is an adaptation (only the default branch moved, no finding on the PR's own
change), head your report `### Fix round <n> (adaptation: <what moved>)` instead, and list in it only what moved.

## Paused

When you stop on the emergency stop (SKILL.md › Emergency stop), post this short report instead, on the PR when there
is one, otherwise on the issue, and make it your final message:

```markdown
## Implementer report: #<N>, paused

**Round:** <first build | fix round <n> of PR #<P>>

**Stopped at:** <the checkpoint: before a commit | a push | opening the PR | marking it ready>, because
`factory:paused` is on the status issue <or: the pause check failed twice>.

**State:** branch `<branch>`, head <SHA or "no commit yet">, pushed <yes | no>, PR <link or "none">, worktree
`<path>` with <no uncommitted changes | uncommitted changes in: files>.

**Done so far:** <one or two lines>

**Next step on resume:** <the step you did not take, and what is left after it>

Model fit: <right | too weak | more than needed> (builder, <model spec>, tier:<tier>, kind <work kind>): <reason>

PR <full URL or "none">, head <SHA>, checks and reviews <state>
```
