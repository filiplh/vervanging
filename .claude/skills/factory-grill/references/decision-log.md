# The decision log

One file per grill: `<grill folder>/YYYY-MM-DD-<slug>.md`. Create it right after the homework and update it after
every resolved branch or round, so the session survives a pause, a crash or a fresh context. `factory-plan` reads it,
so keep the headings, their order and the table columns exactly as below. Write the content in the user's language;
an empty section stays, with "None." under it.

## Template

```markdown
# Grill: <target> (<YYYY-MM-DD>)
Depth: <quick|standard|deep> · Read: <the sources the homework covered> · Status: in progress | paused | done (<date>)

## Map
1. <decision> ✓ <answer> (<source>)
   2. <child decision> ? <the open choice>
   3. <child decision> ~ <assumption, see A1>
4. <decision> ⏸ <parked, see P1>
5. <decision> ✗ out of scope
gap: <a gap that is not a decision> → <follow-up>

## Open (frontier)
| ID | Question | Risk | Who can answer |
| --- | --- | --- | --- |

## Decisions
| ID | Decision | Why | By |
| --- | --- | --- | --- |

## Assumptions to test
| ID | Assumption | How to test | Owner |
| --- | --- | --- | --- |

## Parked
| ID | Question | Owner | Blocks |
| --- | --- | --- | --- |

## Questions for <person>
1. <question, in that person's language, ready to forward as is>

## Proposed follow-ups
- <plan or ADR change, glossary or rules change, new issue, issue update, note for in-flight work>
```

## Rules per section

**Header.** The target, the date the grill started, the depth, what the homework read (files, issues, searches, links
to outside documents) and the status. A finished log says `done (<date>)`.

**Map.** The current decision tree with the marks `✓` settled, `?` open, `⚡` contested, `~` assumed on purpose, `⏸`
parked, `✗` out of scope. Children are indented under their parent. A settled node carries its answer, short, so the
map reads on its own. Gaps that are not decisions go at the end as `gap: … → follow-up`. A finished log has no `?`
and no `⚡` left.

**Open (frontier).** Only open nodes whose parents are settled, riskiest first. Risk is `high`, `medium`, `low` or
`?` when it cannot be judged yet. "Who can answer" is the user, the agent (research) or a named role (an end user, a
customer). IDs: `Q<n>` for questions, `C<n>` for comments raised on a shared document. A finished log keeps only rows
that wait on someone else and are also in Parked, or says "None."

**Decisions.** One row per decision, numbered `D<n>` in the order they were made; never renumber, so later logs and
the plan can cite them. "Why" is the reason in one line, with its evidence (a source, a number, an incident). "By" is
one of: `user`; `agent's call` (add `reversible` when it is), `agent's call, accepted` once the user agreed; `carried
over from <source>` for a decision already settled elsewhere; or a combination such as `user (name), agent's call
(prefix)`. A resolved term is a decision too: `Term: <word> means …; avoid <other words>`. A decision that replaces
an earlier one says so: `replaces D4`.

**Assumptions to test.** `A<n>`. Every assumption names how it will be tested (a measurement, a question, a spike, a
date) and who owns the test. A preference turned into an assumption is made concrete enough to test.

**Parked.** `P<n>`. Every parked question has an owner and says what it blocks (`nothing before <milestone>` is a
valid answer).

**Questions for <person>.** One section per person or role who must answer something the user could not, named as
the context file names them, in that person's language, numbered, ready to forward. Leave the section out when
nobody else has questions. Each question also appears as an assumption or a parked row.

**Proposed follow-ups.** What should change after the grill, one bullet each: plan and decisions-table changes, ADR
candidates (all three: hard to reverse, surprising without context, the result of a real trade-off), glossary and
rules changes, new or updated issues, notes for in-flight work, an update to the grill context file. Mark each
`(approved)` once the user said yes, `(declined)` when they said no. `factory-plan` takes the approved ones.
