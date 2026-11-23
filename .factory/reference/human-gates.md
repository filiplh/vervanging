# Human gates: the one list

This is the core's single list of human gates. The implementer checks it before and during the work, and the
reviewer checks it for every PR. Other core skills (the lead, the gate) read the same list rather than restating it.
Its source in the factory repo is `docs/factory-yaml.md` › `human_gates` (with `docs/PLAN.md` › Deployments and the
decisions table). Change it there and here in the same PR.

A gate applies when its trigger matches the issue, the PR or the change. Every gate on the list counts the same; a
project can add gates but never remove one.

## The list

| # | Gate | Triggers on |
| --- | --- | --- |
| H1 | Work reserved for a person | The issue or the PR carries `agent:human` or `status:needs-human`. |
| H2 | A new dependency, or a licence outside the policy | The change adds a runtime or dev package, vendored or copied third-party code, a third-party skill or a CI action; or anything it adds has a licence outside `licences.allow` (or outside `licences.dev_only` for something that never ships). Standing exception: the factory's own GitHub first-party actions (`actions/*`) pinned to a full commit SHA are approved by the factory's decision record; a project may add its own standing approvals in `human_gates`. |
| H3 | An account, a secret or money | The change needs a new account, a credential, a repository secret, a signing key, a paid plan or service, or anything else that costs money. |
| H4 | The rules or a settled decision | The change edits the rules file (`AGENTS.md`, or `CLAUDE.md` where it is more than a pointer), `factory.yaml`, an ADR, or the plan's decisions or scope (where `AGENTS.md` says those live). A process change (how the work is done, not what is built) is gated wherever it lands, in a role file, the review checklist or the hunter file as much as in the rules file. |
| H5 | A process change from the process tester | The issue carries a process change that the process tester found and proposed. |
| H6 | A deploy that needs approval | The change adds a deploy target or environment, or its merge would deploy to a target for the first time, or to an environment with `approve: always`. |
| H7 | A data migration or a breaking change | The change migrates stored data, or breaks compatibility (a persisted shape, a file format, a config schema or a public interface that old data or callers can no longer use). Its release waits for a person: the PR may merge, but the release that carries it waits for a linked approval. When the target's production environment deploys on merge (`when: merge`), the merge is the release, so the merge waits too. |
| H8 | A store submission | The change submits, or its merge would submit, a build for store review. |
| H9 | An outward action | The change sends or publishes anything outside the repo (mail, messages, posts, contact with a third party). Agents only draft. |
| H10 | The project's own gates | Each sentence in `factory.yaml` › `human_gates` whose situation applies. |

The `factory:paused` label on the status issue is not a gate but an emergency stop: everything stops.

**The owner's OK for the top model** is asked like a gate, though it is not on the list and a project cannot turn it
off: the step onto the ladder's first `claude-fable-5-2` entry ([model-policy.md](model-policy.md), rules 3 and 4) waits
for the owner's comment on the issue. Whoever runs the board sets `status:needs-human` and asks in one short message;
the escalation comment links the owner's answer. It is not an H-number, and the reviewer files no finding for it.

## Resolved or not

A gate is **resolved** only when the issue or the PR links a person's approval for this specific change (a comment, or
a decision recorded where `AGENTS.md` says decisions live). An issue that merely asks for the dependency, the
migration or the deploy is not an approval. Removing a label never resolves a gate on its own, because agents can
remove labels: H1 with `status:needs-human` is resolved only when the approval is linked **and** the label is gone
(the lead removes it after the approval).

**H7 is the one gate that can be a release hold instead of a merge block.** It is merge-blocking only when merging
releases the change: the target's production environment has `when: merge`, or the merge itself deploys or publishes
it. Otherwise an unresolved H7 is a **release hold**: the work, the review and the merge go ahead, the hold is
recorded, and the release that carries the change waits until a person's approval is linked (the release gate
enforces this).

- **The implementer** builds the change and lists `release hold: H7 <what>` in the final report.
- **The reviewer** files no finding for it; it lists `release hold: H7 <what>` under "Needs human" and counts it in
  `release_hold=<n>` on the marker line. The verdict may be `merge`.
- **Whoever runs the board** records the hold on the issue and the status issue, and asks the user for the approval
  before the release.

Every other unresolved gate, and an H7 whose merge is the release, is **merge-blocking**, and then:

- **The implementer** stops before doing the gated part, and reports which gate (by number and name), what triggers
  it and what approval would unblock it. It never works around a gate.
- **The reviewer** files a blocking P1 finding `human gate: H<n> <name>`, counts it in `human=<n>` on the marker line,
  and adds the handoff line under "Needs human" (see `factory-reviewer`).
- **Whoever runs the board** (the lead, or the person in solo mode) sets `status:needs-human` on the issue and asks
  the user in one short message. Nothing on that issue merges until the approval is linked.

## Commands a person pastes

When a gate, an approval or a setup step hands the user commands to paste into their own terminal, write the block so
it runs the same in any shell. In a real gate test, an interactive zsh broke a pasted block on each point below:
`#` comments became errors, a command held in a variable was not split into words, a prompt swallowed the rest of
the block, a placeholder line was skipped and a pager ate the next pasted character.

- No `#` comments inside the block; explain in the text around it.
- A block that relies on word splitting starts with a line `bash`, so the rest runs in bash.
- A command that may prompt or open a pager goes last, on its own, or runs without the pager (`git --no-pager`,
  `GH_PAGER=cat`).
- Every value is filled in; no placeholder is left for the person to edit.
- Ask the person to remove tokens, account ids and email addresses from any output before sharing it.
