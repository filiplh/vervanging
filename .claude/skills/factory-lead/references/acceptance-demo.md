# Acceptance demo

At the end of each milestone you record the project's key flows as they really run and publish a changelog page the
user opens on a phone. The user's OK closes the milestone. It is the one moment a person looks at the product as a
whole, so it shows the truth: failures and slowness stay in.

A milestone is a GitHub milestone. Everything specific comes from the overlay: the flows from `factory.yaml` ›
`demo.flows`, how to start the app from `commands.setup` and `commands.serve`, how to drive it and the sample data
from `AGENTS.md` and `.factory/review-checklist.md`. This file names no project, tool or folder of its own; recording
is runtime: `record`.

## 1. When

When the last open issue of a milestone merges (After every merge, step 7), the demo comes **before** the milestone
close run of `factory-compound`, and the GitHub milestone **stays open**. A milestone with open issues has no demo
yet. A new take follows every time the milestone runs out of open issues again (after changes the user asked for, or
fixes for failed flows).

## 2. The flows

1. `demo.flows` set: every flow in it, in its order. These are the product's key flows, the same each milestone, so
   the user sees the whole product and not only what changed.
2. **New in this milestone,** whether `demo.flows` is set or not: take the live (not struck) assertions of the
   acceptance contracts of the milestone's merged issues, on every surface (`ui`, `http` and `command`: a contract
   assertion is observable from outside by its own rules, so each one is user-facing), and drop those a configured
   flow already shows. Each keeps its surface. Group them into one flow per surface, "New in this milestone (`ui`)",
   "(`http`)", "(`command`)", in issue order, after the configured flows, so runtime: `record` records each the way
   its surface needs. When one of them is a key flow, propose a `demo.flows` entry for it as a follow-up.
3. With `demo.flows` unset, those "New in this milestone" flows are the whole demo.
4. Nothing from either: there is nothing to demo. Say so on the changelog page and in the status line ("no flows
   to record: `demo.flows` is unset and no contract in the milestone has a live assertion"); the user's OK still
   closes the milestone.

A flow is in the acceptance contract's format (`core/templates/ticket.md` in the factory repo › The acceptance
contract): a name, a surface (`ui`, `http`, `command`) and steps written as given, when, then, with made-up sample
data (`docs/factory-yaml.md` › `demo` in the factory repo has the keys; `factory doctor` checks them).
Never invent a flow the overlay and the contracts do not give.

## 3. Record, one take each

1. **Privacy first.** The app runs on the project's sample or test data and its local or test environment, never
   production, never real customer data. No credentials, tokens or personal data on screen or in a transcript: never
   print the environment, a config file with secrets or a signed-in account that is not a sample one. A flow that
   cannot run without those is not recorded: "not recorded: needs <what>", and it becomes a follow-up.
2. **The app at the milestone's state.** A temporary worktree outside the root checkout at the current
   `origin/<default>` tip (note its SHA: the page names it). Start the app as the validator does
   (the `factory-validator` agent › Steps, step 3: `commands.setup`, a free `PORT`, `commands.serve.run`, poll
   `commands.serve.ready`), with `FACTORY_TEST_WORKERS` set. Without `commands.serve`, only `command` flows can run;
   the others are "not recorded: the project has no `commands.serve`".
3. **runtime: `record`, once per flow,** from a clean start where its "given" allows. One take: you run it straight
   through as written, and what happens is what is recorded.
   - Never cut, speed up, re-order or narrate over a recording, never re-take a flow because it failed or was slow,
     and never stage data or steps the flow does not name to make it pass.
   - A step that fails stays in the take, and the flow is **failed** on the page with what was seen. The take goes
     on only when the next step still makes sense; otherwise it stops there.
   - A flow the runtime could not record (the tool failed, the file is missing or over the runtime's size limit) is
     "not recorded: <why>", never replaced by a description, a screenshot staged afterwards or a shorter take.
4. Stop the app, read every transcript in full for secrets and personal data (a hit: that file is not uploaded, the
   flow is "not recorded: transcript held back for <what>", and you tell the user), then remove the temporary
   worktree.

**The runtime cannot record** (it has no `record`): say so in the status line and on the issue thread, and the
milestone waits for a runtime that can. Never fake a recording, and never close the milestone without the demo.

## 4. The changelog page

A GitHub **draft release**: only people with access to the repo see it, it renders on a phone, and no tag exists
until it is published. You never publish it: publishing would be an outward action (H9). Tag name
`demo-m<milestone number>-t<take>`, take 1 for the first demo of the milestone; it never collides with a version tag.

```
gh release create demo-m<M>-t<k> --draft --target <tip SHA> --title "Demo: <milestone title>, take <k>" \
  --notes-file <page.md> <recording files...>
```

Write the page to a fresh file outside the worktree, in the language `AGENTS.md` gives for issues and PR text:

```markdown
**Milestone:** <title> (#<milestone number>), take <k>, `origin/<default>` at <short SHA>, <UTC date>
**Reply on the status issue:** "OK <milestone title>" closes it; anything else becomes issues in the milestone.

## Flows
- <flow name> (<surface>): passed | failed at "<step>": <what was seen> | not recorded: <why>. File: <asset name>

## Merged in this milestone
- #<N> <issue title> via PR #<P>

## Failed or left
- <flow>: failed, follow-up #<F>
- #<N> <open issue moved out, or anything the milestone did not deliver>
<or "nothing">
```

"Merged in this milestone" comes from the merged PRs that close the milestone's issues (read them from GitHub, never
from memory). Then delete the local recording files and the page file you made (the exact paths, never a glob).

## 5. Ask, then wait

1. Every failed or not-recorded flow becomes a follow-up issue **in this milestone** (Follow-ups), linked from the
   page. The milestone now has open issues again, so a new take follows when they merge.
2. Post a **demo record** comment on the status issue: "🤖 Lead: acceptance demo, milestone <title>, take <k>:
   <release URL>". Then `factory status --note "waiting: Acceptance demo for milestone <title>, take <k>: <release
   URL>; reply 'OK <title>' here, or say what to change"`, and keep that note in every status update until the
   milestone closes. Tell the user in one line.
3. **The OK.** Only a person's comment counts: one on the status issue, written after the demo record of the take
   it answers, not written by an agent (no `🤖` heading), that says OK for this milestone. Link it. A removed label,
   an agent's comment, silence or an OK on an earlier take is not an OK.
4. **On the OK,** with no open issue left in the milestone: close the GitHub milestone
   (`gh api -X PATCH repos/<owner>/<repo>/milestones/<M> -f state=closed`), post "🤖 Lead: milestone <title>
   closed on <link to the OK>", and drop the note. Open issues left (a failed flow's follow-up): say what is left;
   the milestone stays open, and the OK of a later take closes it.
5. **Changes asked for:** each becomes an issue in the milestone, with the user's comment linked; the milestone
   stays open, and a new take follows when they merge. Never close a milestone, or move its issues to another one,
   without the user saying so.
