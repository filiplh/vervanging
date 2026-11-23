# Model and effort policy

The one place the factory's model rules live. `factory-lead`, `factory-implement`, the `reviewer` and the `validator`
point here; they do not restate it. The tables themselves are data: `models` and `work_kinds` in `factory.yaml`, with
the core values in `defaults.yaml`. This file holds the rules for using them.

**Every agent gets the cheapest model and effort that still does top-quality work.** That is often not the most
expensive model, and rarely the highest effort.

## Where each agent's model comes from

| Agent | Model and effort | Read from |
| --- | --- | --- |
| Builder | the issue's tier | `models.tiers.<tier>.build` |
| Reviewer | by the kind of review: [Reviews](#reviews) below. Always a different model from the one whose work it reviews | `models.tiers.<tier>.review`, `models.reviews` |
| Validator | the issue's tier: it judges acceptance, so it is never weaker than the builder | `models.tiers.<tier>.build` |
| Fix rounds ("address review findings") | the issue's tier; the lead may make a trivial fix itself | `models.tiers.<tier>.build` |
| Lead | its own setting | `models.agents.lead` |
| Grill, plan, tickets | their own settings: their decisions are the most expensive to undo | `models.agents.grill`, `.plan`, `.tickets` |
| Bug hunters | their own settings; the process and domain hunters run higher | `models.agents.hunter`, `.process_hunter`, `.domain_hunter` |
| [Architecture review](../../.claude/agents/factory-architect.md) | its own setting | `models.agents.architecture_review` |
| [Maintenance lane](../../.claude/skills/factory-maintain/SKILL.md) | its own setting: it scans and files, and every fix it files is built on its own tier | `models.agents.maintenance` |
| Helper for search and lookups | the smallest model | `models.helpers.search` |
| Helper for reading and summarising | a mid model at low effort, medium when needed | `models.helpers.read` |
| Helper that makes a decision | its parent's model and effort, never a helper model | the parent |

The tier comes from the issue's `tier:*` label. The label comes from the issue's work kind (`work_kinds`), which
`factory-tickets` writes in the issue body when it creates the issue.

## Rules

1. **Quality is fixed, the model is not.** Acceptance criteria, `verify`, the review, the validator and the gate are the
   same on every tier. No agent lowers its own bar to stay within a tier. Cost is judged per **merged issue**, not per
   call: a cheap attempt that needs three fix rounds is not cheap.
2. **Every ticket carries a tier.** Every issue gets exactly one `tier:deep`, `tier:standard` or `tier:light` label when
   it is created, follow-ups and bugs included. `factory claim` refuses an issue without one, and the runtime adapter
   refuses to start an agent without a model and effort.
   **An `agent:human` issue too.** It gets the tier of the work kind of the change the person does or approves,
   like any other ticket: the rule then holds with no exception, and when a person hands the issue to the agents (the
   `agent:human` label goes), it is ready to claim with no relabel. Size differs: an `agent:human` ticket gets no
   `size:*` label, because size measures agent work that must fit one context, while the tier names the model that
   would build the change. `factory claim` still refuses an issue while it is `agent:human`. This rule is the one
   place for it; factory-tickets points here.
3. **Escalate, never degrade.** Move the issue one step up `models.escalation`, from its current build model, when:
   - a review says "needs rework" for lack of depth (a design flaw, missed edge cases, wrong domain reasoning), not for
     a slip any model makes;
   - the builder reports it is stuck;
   - a PR has had two fix rounds that count (below).

   **A fix round** is one fix-round report on the PR: a builder's, or the lead's or solo session's comment headed
   `### Fix round <n> (lead)` ([merge-gate.md](merge-gate.md) › Lead fixes). `<n>` numbers every `### Fix round <n> (…)`
   report on the PR, adaptations included, so the numbers stay unique. A round counts toward "two fix rounds" whatever
   raised its findings (a factory review, a review bot or a person) and whoever fixed it, with one exception, the
   adaptation.

   **An adaptation** is a round whose only cause is the default branch moving under the PR: a semantic merge conflict,
   or a contract that another merged PR changed after the review. It says nothing about the builder's depth, so it
   does not count toward "two fix rounds", and the round rule in `factory-lead` › Reviews does not count it either.
   The lead (or the solo session) marks it in the report heading, `### Fix round <n> (adaptation: <what moved>)`, and
   names the merged PR or the contract that moved; a later lead counts from that heading. When the lead hands an
   adaptation round to a builder, its brief says so, and the builder heads its report the same way. Only a round that
   addresses nothing but the moved default branch is an adaptation. A round that also addresses a finding on the PR's
   own change counts, and its heading says so as usual. `factory status` still prints every fix-round report, adaptations
   included, in "Merged recently"; the escalation count is the one defined here.

   Outside findings after a clean review are triaged first ([merge-gate.md](merge-gate.md) › Outside findings after a
   clean review).

   Change the `tier:*` label when the new step is a tier's build model (above the deep tier's model it stays
   `tier:deep`), and post an issue comment that names the trigger and the new model, so the step survives a restart
   and the next fix round or validator run uses it. The issue never steps back down, not even after it merges cleanly.

   **The top model needs the owner.** Automatic escalation stops at the step before the ladder's first
   `claude-fable-5-2` entry (the top model, rule 4). The step onto that entry needs the owner's OK on the issue, asked
   like any human gate ([human-gates.md](human-gates.md)): a comment that names the trigger, the lead's reason and the
   step, and `status:needs-human` while the question is open. The OK is a comment by the owner on that
   issue; the escalation comment then links it. Without it, the issue stays on its current model with
   `status:needs-human`, as at the end of the ladder. When the ladder has no `claude-fable-5-2` entry (a project's own
   ladder), escalation ends at its last step, with no OK to ask: the issue gets `status:needs-human`.

4. **Top settings are for escalation only.** The efforts `xhigh`, `max`, `ultra` and `ultrathink` on any provider, and
   the top model (`claude-fable-5-2`), are never a default: not in `defaults.yaml`, not in a project's `models`, not
   in a brief outside an escalation. The top model is also never taken without the owner's OK (rule 3). `factory doctor`
   refuses such a default, and a ladder that steps down.
5. **Helpers stay cheap.** Search and reading helpers use `models.helpers`. Anything that decides (writes code, judges a
   finding, picks an approach) runs on its parent's model.
6. **Calibrate from evidence, the user approves.** Builders, reviewers and validators end every report with a model fit
   line (below). `factory status` counts the lines per work kind. When one kind is repeatedly "too weak" or "more
   than needed" on its tier, the lead proposes moving it (a `work_kinds` change) or changing a table entry, with the
   counts. The change is a PR to `factory.yaml` or the core, and the user approves it. No agent changes a table on
   its own.
7. **Usage limits lower concurrency, never the tier.** After a usage-limit error the lead runs fewer agents at once and
   waits for the window, rather than starting weaker ones. Back-off never changes a model, an effort or a label.
8. **Never switch models silently.** Resolve the configured providers and models once per session through the runtime
   adapter. If one is unavailable, say so and wait for the user; never fall back to another model on your own.

## Reviews

**A reviewer's model always differs from the model whose work it reviews:** the builder's for a first review, the
fixer's for a re-review. A model is the provider and the model id; another effort of the same model does not count.
On top of that, **a first review of standard or deep work runs on a different provider** from the builder: the
independent cross-provider check stays where reviews find the most. The narrower reviews run on another model of the
builder's provider by default: on the core defaults, first reviews of standard and deep work run on Codex, and light
first reviews, documentation-only reviews and re-reviews run on Claude.

| Review | Spec | Core default |
| --- | --- | --- |
| First review, tier deep or standard | `models.tiers.<tier>.review` | Codex |
| First review, tier light | `models.tiers.light.review` | Opus 5.5 medium (the light builder is Sonnet) |
| Documentation-only PR, any tier (the reviewer's docs-only mode decides what counts) | the first entry of `models.reviews.docs_only` whose model differs from the builder's | Opus 5.5 medium; Sonnet 5.5 high when Opus built |
| Re-review, after a fix round | the first entry of `models.reviews.re_review` whose model differs from every fixer's in the round | Sonnet 5.5 high when the fixer was Opus; Opus 5.5 medium when it was Sonnet; Codex when both changed code |
| Cross-check, when a review asks for one | `models.reviews.cross_check` | Codex |

- **Who the fixer is.** The model that wrote the round's fix: the spec the fix-round child ran on (the tier's build
  spec, or the escalated one), `models.agents.lead` when the lead fixed it itself, the session's own model in solo
  mode. The lead runs on Opus by default, so a fix it made is re-reviewed on Sonnet 5.5 high. A round that changed no
  code (only rejections with evidence, or findings moved out) counts the model that wrote those answers.
- **A re-review stays narrow:** the earlier findings and the fix. A re-review that must judge a disputed or deferred
  P0–P2 finding (rejected with evidence, or moved out as pre-existing) runs on the tier's first-review spec instead,
  because a builder's rejection is not accepted by a narrower review. When that spec's model wrote a fix or a rebuttal in
  the round (on the core defaults: a light issue whose findings the Opus lead answered), it runs on
  `models.reviews.cross_check` instead, which must differ from every one of those models too.
- **A first review never runs on the model that built the change.** When the tier's first-review spec is the same model
  as whoever built it (on the core defaults: a light issue the Opus lead builds itself), the first review runs on
  `models.reviews.cross_check` instead, which must differ from the builder too, else no entry fits (next).
- **No entry fits** (every one shares the model of the work, or a first review of standard or deep work would share
  the builder's provider, after a project override or an escalation): stop and tell the user. Never review on the
  model whose work is reviewed.
- **Escalation stays.** A reviewer on the builder's provider (a light first review, a docs-only review or a
  re-review, on the core defaults) that finds a depth problem, or doubts its own reading of a change, says so in its
  review comment, in the line `Cross-check: <reason>`. The lead (or the solo session) then starts a review on
  `models.reviews.cross_check` on the same head. The gate waits for it, and its marker becomes the latest one. A "needs rework for lack of depth" verdict still escalates the build (rule 3).
- **Setting it back.** A project that wants every review on the other provider sets `models.tiers.light.review`,
  `models.reviews.re_review` and `models.reviews.docs_only` to that provider's specs in its `factory.yaml`.
- **Order is preference, then the reserve.** The lists are candidates in order of preference. When several entries fit
  the rules above (the reviewer's model differs from the work's, and from the builder's provider where that applies),
  take the first one whose provider is below its weekly reserve (`factory-usage may-start <provider>` exits 0; the
  reserve is under Machine settings › Usage in the factory repo's `docs/factory-yaml.md`). When none is below it, take
  the first that fits and note "review above the <provider> reserve" in the status: a review never waits for the
  reserve. A single spec (a tier's first review, the cross-check) has no choice and is used as it is. A provider
  stopped by a usage limit until its reset is not below its reserve; when every fitting entry is stopped that way, the
  review waits for the runtime's back-off, never on a model that does not fit.

## Model fit report

Every builder, reviewer and validator report, and its PR comment, ends with one line in this form, just before the
final `PR <URL>, head <SHA>, checks and reviews <state>` line:

```
Model fit: <right | too weak | more than needed> (<role>, <model spec>, tier:<tier>, kind <work kind>): <one-line reason>
```

- **right**: the work needed this model and effort, and no less.
- **too weak**: depth was missing: a miss, a stall or a rework that a stronger setting would likely have avoided.
- **more than needed**: a cheaper setting would have done the same work at the same quality.

Example:

```
Model fit: more than needed (builder, claude/claude-opus-5-5/medium, tier:standard, kind config): a mechanical rename across three files.
```

Report honestly. A "too weak" line is not a failure of the agent, and "more than needed" is how defaults get cheaper.
