# Ticket template

The body of one issue. Labels carry the type, the tier (`tier:deep`, `tier:standard` or `tier:light`, from
`work_kinds`) and the size; the body carries the rest, in this order. Write it in the language `AGENTS.md` sets for
issues. Fill every `<…>`, and write "none" rather than leaving a section out. The "Blocked by" line and the "Owned
paths" heading are read by the factory tool, so keep their spelling (the core's `reference/board.md` › Owned paths and
› Follow-ups). The merge gate reads the contract section's heading the same way (rule 4 of `reference/merge-gate.md`),
so keep that spelling too, and never write the two words of that heading anywhere else in an issue body: say "the
contract section" instead.

```markdown
Blocked by: <#A, #B | none>

Work kind: <a kind from work_kinds>

<What and why, in a few sentences: the problem for the user or the code, and the outcome wanted.>

## Acceptance criteria
- [ ] <one criterion a reviewer can check: a behaviour, a test that must exist, a document that must say something>

## Acceptance contract
- **C1** (<ui | http | command>) Given <a starting state reachable from a clean start>, when <one action>, then
  <the observable result, with exact values>.
- **C2** (command) When `<exact command>` runs from the repo root, then <its exit status, output or the file it
  writes>.
<or: none (<reason>)>

## Owned paths
- `<glob>`

Plan: <the plan section or decision this comes from, or "none">
```

**The ticket key.** An issue that factory-tickets created ends with one more line, an HTML comment that the rendered
page does not show: `<!-- factory:ticket <source>/<slug> -->`. It is the ticket's identity: on a re-run over the same
plan, factory-tickets finds the issues that already carry a key of that source and creates only what is missing, so
nothing is filed twice. When you edit such an issue, keep that line as it is, as the body's last line: a changed or
removed key makes the next run treat the ticket as missing and propose it again. Never add one by hand to an issue
factory-tickets did not create (the core's `skills/factory-tickets/SKILL.md` › Find what already exists). The one
exception is the source `architecture`, reserved for the core's `architect` agent: it writes
`architecture/<slug>` keys on the drift issues it files, so its next weekly run does not file them again. No plan's
tickets use that source.

## The acceptance contract

Testable assertions about what the app does, written with the ticket, before any code. The builder builds to them,
the reviewer checks the diff against them, and the validator (the core's `validator` agent) checks each one
black-box on the PR head: it starts the app and acts as a user or a client would. It never reads the code, so an
assertion it cannot observe from outside cannot pass.

**One assertion per line item:** a stable ID, a surface, then given, when, then.

| Surface | What the validator does | Needs |
| --- | --- | --- |
| `ui` | uses the running app's screens, with the browser tool the project names | `commands.serve` and a browser tool |
| `http` | sends a request to the running app's public interface | `commands.serve` |
| `command` | runs the exact command the assertion gives, from the repo root, and reads its exit status, output or the files it writes | nothing more; the surface for a project with no running app |

**Rules for each assertion:**

- **Observable from outside.** The result is something a user or a client sees: text on a screen, a response status
  and body, a command's output or exit status, a file the app writes where its user finds it. Never a code internal
  (a function, a class, a table, a log line only developers read): the validator cannot see it, so it stays
  unchecked.
- **Concrete.** Exact values and made-up sample data. Not "works", "is fast" or "shows an error", but which result,
  which number, which message (quoted from the string catalogue when the project has one).
- **One behaviour each,** from a starting state the validator can reach from a clean start: the project's setup and
  serve commands plus the steps the "given" names.
- **The edges too.** Each behaviour that takes input gets at least one assertion for an empty, invalid or
  unauthorised case, and one for the state where nothing exists yet, when those can happen.
- **Covers the criteria.** Every acceptance criterion a user or client can observe has at least one assertion.
  Criteria about the code itself (a test exists, a document says something) stay criteria; the reviewer checks
  them.
- **Only what a run can show.** A check that only a person can do (on real hardware, in a store review) is not an
  assertion: it is an acceptance criterion marked with the `AGENTS.md` marker for unconfirmed claims.
- **No secrets and no personal data,** in the assertions or in the commands they give.
- **Safe to run.** A `command` assertion never installs, deploys, writes outside the repo or reaches a production
  system; the validator refuses those and leaves them unchecked.

**IDs are stable.** `C1`, `C2` and so on, never renumbered or reused, so results stay comparable across runs. To change
an assertion after building started, strike its line (`~~C2~~ replaced by C5: <why>`), add the new one with a new ID,
and say so in an issue comment. The validator reads only the issue body, never its comments: it checks the
contract as the body stands when it runs, and skips struck lines.

**None.** Only an issue with nothing a user or client can observe from outside (a refactor, a documentation or CI
change, an internal fix with no visible effect) writes `none (<reason>)` in the section. Size is not a reason, with one
exception: a `size:S` fix skips the contract, as a core rule (ceremony scales with size), and writes
`none (size:S fix)`. The section stays, so the gate reads none and its rule 4 does not apply. Any other small fix
whose result a user or client can see gets at least one assertion for that result, even when its regression test
already shows it. With `none`, the validator has no assertions to check and says so; it never writes a contract of
its own.

**Holdout scenarios** are a separate, hidden contract: a project may keep them in `acceptance/`, where builders never
look and only the validator reads them. The ticket's contract is public; never copy a holdout into it.
