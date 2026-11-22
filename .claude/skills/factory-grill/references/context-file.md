# The grill context file

A project's notes for every grill, kept in the project (at the path `AGENTS.md` names, else `docs/grill/CONTEXT.md`).
The skill reads it first, and it wins over the skill's generic advice wherever they differ. It holds what a new
interviewer would otherwise spend the first hour finding out, and nothing that belongs in the plan itself: it points
to facts, it does not repeat them.

Offer to write it at the end of a project's first grill, and to update it when a grill teaches something lasting.
Changing it is a normal docs change through a branch and a PR.

## What it holds

```markdown
# Grill context: <project>

<One paragraph: what the product is, for whom, and what stage it is at.>
Decision logs live in <folder>.

## Where the facts are
| Topic | Where |
| --- | --- |
| <scope, users, success criteria> | <file and section> |
| <architecture decisions> | <ADR folder> |
| <domain rules, formats, regulations> | <domain skill, doc or public source> |
| <the project's words> | <glossary> |
| <build status, work in flight, questions waiting on a person> | <the board queries> |

## Settled: don't reopen without a reason
<Decisions the user has made that are easy to re-ask by accident, with where they are recorded. Note how the project
marks settled items (for example, whether "proposed" counts as settled).>

## Who knows what
| Who | Ask them about | How |
| --- | --- | --- |
| The user | <priorities, scope, budget, trade-offs> | directly |
| <end user or other role> | <how they work, what they need> | through the user: their question list in the log |
| The agent (research) | <public facts, standards, competitors> | look it up; never ask the user to recall it |

<Whether the user is also the end user, and any rule on contacting third parties.>

## Branches worth grilling
<The handful of branches that matter for the whole product, each with the concrete questions that open it up. For a
narrow target, the grill uses the ones it touches as lenses.>

## Rules to hold answers against
<Regulations, standards, platform rules and the project's own hard rules, each with where it is written down.>

## Writing questions for <end user>
<Language, tone, words to use and to avoid, how much they will read, how answers come back.>
```

## What it does not hold

- Decisions themselves: those are in the plan, the ADRs and the decision logs. The context file says where.
- Secrets, personal data about the people it names beyond their role, or anything the rules file forbids in docs.
- Issue numbers as facts: they drift, so give the board query that finds them, and date any number you do give.
