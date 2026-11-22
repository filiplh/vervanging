# The plan

The plan of attack for a project that has none yet. A project with a plan keeps its own structure; this file is then
the checklist of what the plan must hold and the rules for each part. Write it in the project's language (see the
skill). Every section stays, with "None." under it when it is empty. Keep it short: the plan points to ADRs, logs and
the glossary instead of repeating them.

## Skeleton

```markdown
# <Project>: plan of attack

<One paragraph: what the product is, for whom, and what it must achieve.>
Status: <phase the project is in> · Built from: <links to the grill logs> · Last changed: <YYYY-MM-DD>

## Summary
| Topic | Decision |
| --- | --- |
| <the handful of choices a newcomer must know> | <one line each, with the decision number: (#3)> |

## Scope
### Who it is for
<The users and the situation they are in, as the log decided.>
### What they need to do
<The jobs the product must do, smallest useful version first.>
### Out of scope, on purpose
- <item> (#<decision>)
### Success criteria
- <a measurable outcome, with how and when it is measured>

## Decisions
| # | Decision | Chosen | What it changes | Status | Source |
| --- | --- | --- | --- | --- | --- |
| 1 | <the question> | <the answer> | <its consequence for the build> | Decided | [<log slug> D1](grill/<log>.md#decisions) |

## Architecture
<One line per ADR: number, title, status, and the one-sentence decision. Full records in <ADR folder>, index in its
README.>

## Glossary
<A pointer to the glossary file, or the glossary itself when the project keeps it in the plan.>

## Assumptions to test
| # | Assumption | How to test | Owner | Tested in | Source |
| --- | --- | --- | --- | --- | --- |
| A1 | <assumption> | <measurement, question, spike, date> | <owner> | <phase or spike> | [<log slug> A1](grill/<log>.md#assumptions-to-test) |

## Parked
| # | Question | Owner | Blocks | Source |
| --- | --- | --- | --- | --- |
| P1 | <question> | <owner> | <what waits on it, or "nothing before phase N"> | [<log slug> P1](grill/<log>.md#parked) |

## Risks
| Risk | What it would look like | Mitigation |
| --- | --- | --- |

## Plan of attack
<One paragraph: the order of the phases and why.>

### Phase 0: <name>
Goal: <one sentence: what is true at the end that is not true now>
- [ ] <work item: a slice that delivers something, citing the decisions it carries out (#4, #7)>
- [ ] <work item>
- **Exit:** <the exit test>

### Phase 1: <name>
...
```

The relative links above assume the plan sits in `docs/` and the logs in `docs/grill/`; compute them from the real
paths.

## Rules per section

**Header and summary.** The status line says which phase is current; update it whenever the plan changes. The summary
is for someone who reads nothing else: at most about ten rows, each pointing to its decision number.

**Scope.** Every scope statement that came from the log cites its decision. Success criteria are numbers or
observable outcomes with a way to measure them, never adjectives ("fast", "easy").

**Decisions.** The plan's own numbering, in the order rows were added; never renumber, so issues, PRs and later logs
can cite `#<n>`. One row per log decision that shapes the build. "Status" is `Decided`, `Assumed` (see the assumption
row), `Parked` (see the parked row), `Replaced by #<n>`, or the project's own status words. "Source" links the log
entry; a decision carried over from elsewhere links that source instead (an earlier plan, an ADR, a rules section). A
decision the log marks as an agent's call says so in "Chosen" (`… (agent's call)`).

**Architecture.** A summary, not a copy: the ADR files hold the context and consequences.

**Assumptions to test.** Each one copied from the log with its test made concrete enough to pass or fail, an owner,
and the phase (or spike) that runs the test. An assumption that a phase rests on is tested no later than that phase's
exit test; if the log gives no way to test it, the PR asks.

**Parked.** Each one with an owner and what it blocks. A parked item that blocks a phase is named in that phase too,
so nobody starts the phase without it.

**Risks.** From the log's pre-mortem, devil's advocate and `gap:` lines; each with a mitigation that is a decision, a
phase item or an assumption test, not a hope.

**Plan of attack.** It is the last section of the plan, because `factory-tickets` reads it next.

- **Phases** are numbered from 0 and run in order. Each delivers something the user can see or use; "set up the
  infrastructure" alone is not a phase. A phase that only reduces risk (discovery, spikes, a prototype) is fine when
  its exit test says what was learned.
- **Work items** are slices a person could describe in one sentence, each citing the decisions it carries out. They
  are bigger than an issue: `factory-tickets` splits them into issues and proposes epics. Never write issue numbers
  into a new plan; once issues exist, a phase may link its milestone.
- **Every phase ends with one exit test**, written as `- **Exit:** …`. A good exit test:
  - is observable: someone runs or watches something and sees it pass or fail, without judgement calls;
  - is concrete: names the user, the data, the device, the number or the time limit ("one real case entered on a
    phone in under 10 minutes", not "the flow works well");
  - names who checks it when it is not the agents (the user, an end user, a regulator's document);
  - covers the assumptions the next phase rests on;
  - is reachable with the phase's own work items; if it needs something from a later phase, the phases are in the
    wrong order.
- **Phases the log did not shape** (later, vaguer phases) stay short: a goal, two or three items, an exit test, and the
  word "draft" in the heading. They are revisited by a later grill.
