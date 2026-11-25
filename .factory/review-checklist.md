# Review checklist

<!-- At .factory/review-checklist.md. The reviewer walks this after the core review protocol (correctness, tests,
     data and compatibility, scope, dependencies, security, human gates, evidence, required checks), and the
     implementer walks it before opening the PR. Don't repeat the core protocol here: list only what is specific to
     this project. Every item should be checkable on a diff, and say what to look at. Findings use the core
     priorities: P0–P2 block a merge, P3 goes to the backlog. -->

Checked on top of the core review protocol. An item that does not apply to the diff is skipped silently.

## Every PR

- [ ] The rules in `AGENTS.md` hold for the changed code.
- [ ] The rules in the role file of every role whose `owns` matches a changed file hold.
- [ ] <!-- fill in: e.g. architecture boundaries a linter does not catch yet. -->

## Data and compatibility

- [ ] <!-- fill in: how this project versions its persisted shapes, and what a migration must include. -->
- [ ] A value that ties stored data together across a save and a relaunch (the running match's `setupSavedAt`, a
      team-history id, a file name) is compared as the exact text that was stored, never re-derived from a `Date` or a
      number that was formatted or parsed again: an ISO 8601 round trip can shift a time by a millisecond, so the key
      misses its own data. A new key of this kind comes with a test that saves and reloads thousands of random values
      and loses none, like `MatchStoreTests.aRunningMatchComesBackAfterAForceQuitForEveryStartTime`.
      (#134, #139)

## User-facing text

<!-- Delete this section if the project shows no text to users. -->

- [ ] Text the user sees is consistent with the existing copy: its terms, tone and formats.
- [ ] <!-- fill in, or delete: number, date and unit formats; accessibility of new text. -->

## Areas that need a closer look

<!-- fill in: one subsection per area where review has missed things before, with what to check and how. For
     example: a screen to open with `commands.serve` and look at in two sizes; a file format to round-trip; a rule
     whose interpretation must be marked unconfirmed. Name the test or command that proves it. -->

## Required checks

- [ ] For this diff, the checks whose `when` matches are listed in the PR with their results, and the heavy ones left
      to the gate are named.
- [ ] <!-- fill in, or delete: a file that should be in a check's `when` but often is not. -->
