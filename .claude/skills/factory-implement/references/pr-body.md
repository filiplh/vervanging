# PR body, when the repo has no template

Use the repo's `.github/pull_request_template.md` when it exists. Use this structure only when it does not. Fill in
every section; write "none" rather than leaving one empty. Write it in the language `AGENTS.md` sets for PR text,
translating the headings if it asks for that.

```markdown
## What
<one or two sentences: what changes, for the user or for the code>

Closes #<N>        <!-- or "Refs #<N>" and what is left, when the issue is not fully done -->

## How
<main files or modules, and any decision the reviewer should know about>
<paths touched outside the issue's owned paths, and why, or "none">

## Acceptance criteria
- [x] <criterion>
- [ ] <criterion>: not met, because <reason>

## Checks
<!-- Commands you actually ran, with the head SHA and the real result. A check that failed or did not run is listed
     as such. -->
- Automated: <exact commands and results with counts>
- Real target: <what was tried on the real target, or "not tested on a real target">
- Left to the gate: <heavy checks this PR needs and did not run in full, or "none">

## Known limitations
<or "none">

## Data impact
<persisted shapes, migrations, stored data or config touched; does old data still load? Or "none">

## Needs confirmation
<or "none">

## Self-check
- [ ] Rules in `AGENTS.md` and the role file followed
- [ ] `.factory/review-checklist.md` walked
- [ ] No new dependency without approval; no secrets; only owned paths changed
```
