# ADRs and their index

For a project without ADRs. A project that has them keeps its own format, numbering and status words; this file is
then the checklist. Write ADRs in the project's language. Default folder: `adr/` next to the plan (see the skill for
where the project names its own).

## One ADR

File: `<ADR folder>/<NNN>-<kebab-case-slug>.md`, `NNN` three digits, numbered on from the highest existing file.
About one page.

```markdown
# ADR-<NNN> <Title: the choice, not the question>

- **Status:** <proposed | accepted | superseded by ADR-<NNN>> (<where the status was set: log entry or PR>)
- **Date:** <YYYY-MM-DD> (decided) · <YYYY-MM-DD> (written)

## Context
<The problem and the forces at play: what the users need, constraints, what goes wrong without a decision. Facts only,
with their sources. A reader who missed the grill must understand why this was a real choice.>

## Decision
<What was chosen, in short active sentences or bullets. Concrete enough that a reviewer can tell whether a change
follows it.>

## Consequences
<What gets easier, what gets harder, what it costs, what it rules out, and what follow-up work it creates.>

## Alternatives considered
- <option>: <why not, in one line>

## References
[<log slug> D<n>](<relative path to the log>#decisions) · <plan decision #n> · <other ADRs, docs, links>
```

### Rules

- **One architectural choice per ADR.** Several log decisions that make one choice share one ADR and all appear in
  References.
- **Status** follows the decision: `accepted` when the user made or accepted it (the log's "By" says `user` or
  `agent's call, accepted`), `proposed` for an agent's call the user has not yet accepted. **Mixed decisions** (a
  "By" that names both, for example `user (policy), agent's call (the number)`): split independently recordable
  choices into separate ADRs, each with its own status; when they can't be split, the ADR stays `proposed` while any
  part is an unaccepted agent's call, and says which part. Promote a `proposed` ADR to `accepted` only after the user's
  linked approval, and update the index in the same change. The PR that adds the ADR is where the user can still
  object either way.
- **Context comes from the log**: the decision's "Why", the map around it, the alternatives offered in the question,
  and the evidence cited. Do not invent forces the log does not mention; ask if the context is too thin to explain
  the choice.
- **Alternatives considered** are the options the grill weighed. Leave the section out only when there truly were
  none.
- **Never rewrite an accepted ADR's decision.** A changed decision gets a new ADR that supersedes it; the old ADR's
  status line becomes `superseded by ADR-<NNN>` and nothing else in it changes. Facts that settle a detail without
  changing the decision (a version pin, a spike result) may be added, citing their source.

## The index

`<ADR folder>/README.md`, one row per ADR file, in number order:

```markdown
# Architecture decision records

Short records of the decisions that shape <project>: why, what, and what it costs. They come from the plan's decisions
table and the grill logs. Cite them in code, issues and PRs as `ADR-NNN`.

| ADR | Title | Status |
| --- | --- | --- |
| [001](001-<slug>.md) | <title> | accepted |

## Format
Each ADR has Status, Date, Context, Decision, Consequences, and where useful Alternatives considered and References.
About one page.

## Statuses
- `proposed`: the default we follow, not yet confirmed by the user.
- `accepted`: confirmed by the user.
- `superseded by ADR-NNN`: replaced; the old file stays for history.

## Changing a decision
Changing an ADR is a human gate. Agents propose the change in a PR or an issue; the user decides. A changed decision
gets a new ADR that supersedes the old one.
```

Keep the index in step with the files in the same PR: a new ADR adds a row, a superseded ADR's row shows its new
status.
