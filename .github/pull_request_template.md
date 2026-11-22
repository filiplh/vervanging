## What
<!-- One or two sentences: what changes, for the user or for the code. -->

Closes #
<!-- Or "Refs #<N>" and what is left, when the issue is not fully done. -->

## How
<!-- Main files or modules, and any decision the reviewer should know about. Paths touched outside the issue's owned
     paths, and why, or "none". -->

## Acceptance criteria
- [ ] …
<!-- Tick each one, or leave it open with ": not met, because <reason>". -->

## Checks
<!-- Commands you actually ran, with the head SHA and the real result (passed, skipped, failed counts). A check that
     failed or did not run is listed as such: never claim a pass you didn't see. -->
- Head:
- Automated:
- Real target: <!-- what was tried on the real target, or "not tested on a real target" -->
- Left to the gate: <!-- heavy checks this PR needs and did not run in full, or "none" -->

## Known limitations
<!-- What doesn't work yet, edge cases left out. Write "none" if none. -->

## Data impact
<!-- Persisted shapes, migrations, stored data or config touched; does old data still load? Write "none" if none. -->

## Needs confirmation
<!-- Claims marked as unconfirmed in code and docs, manual checks, product questions. Write "none" if none. -->

## Self-check
- [ ] Rules in `AGENTS.md` and the role file followed
- [ ] `.factory/review-checklist.md` walked
- [ ] No new dependency without approval; no secrets; only owned paths changed
