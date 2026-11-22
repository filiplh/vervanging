# Runtime adapters

A runtime adapter is the only place where the factory talks to the tool that runs its agents. Core skills, agents
and the `factory` command name an **operation** from the table below ("start a child", "watch the PR"); the adapter
says which tool calls carry it out. No runtime tool name appears anywhere else in the core.

| Adapter | Runtime | Status |
| --- | --- | --- |
| [`t3.md`](t3.md), with on-demand references in [`t3/`](t3/) | T3 Code | the interactive runtime (decision 2) |
| [`headless.md`](headless.md), with its runner in [`headless/`](headless/) | the logged-in `claude -p` and `codex exec` CLIs, started by launchd | unattended runs (night hunts); it says which operations it has no use for |

The headless adapter implements the operations an unattended run uses, so no skill changed when it arrived.

## Operations

Every adapter implements each of these, or states in its own file that it does not provide one and what happens
instead when a skill names it (the headless adapter has no `continue` and no `record`, and its `watch-pr` becomes a gate run at the end
of the run: there is no thread to send to and no lead to wake). A skill refers to them by name, for example "runtime:
`start`".

| Operation | What it does |
| --- | --- |
| `resolve` | Look up the providers and models once per session and map every model spec to a runtime target |
| `check-home` | Confirm the lead runs inside the project it leads, so children can be started there |
| `start` | Start one child with an explicit model and effort, in its own worktree; refuse without them |
| `wait` | End the turn and let the child's completion wake the parent; never poll |
| `result` | Read a finished child's result |
| `read-child` | Read any child's thread by id, including one started by an earlier lead |
| `continue` | Send a follow-up to a finished child (fix round, resume), keeping its worktree |
| `notify` | Get an urgent message (a pause, a cancel warning) to a running child now, in its current turn; fall back to `continue` when that is not possible, and tell the caller which happened |
| `cancel` | Stop a child that is replaced or no longer needed |
| `link-pr`, `watch-pr`, `unwatch-pr` | Show a PR in the thread, wake on its checks and reviews, stop after merge |
| `watch-run` | Wake on one CI run the runtime cannot watch itself |
| `launch-lead` | Start a fresh lead thread in the same project, for a handoff |
| `relay` | An outgoing lead forwards a child's completion to the new lead |
| `send-report` | A child's final report: on the issue or PR, and to its parent |
| `recover-403` | Recover a child killed by a transient 403 from the model API |
| `back-off` | Run fewer children for a while after a usage-limit error |
| `refresh-usage` | Put a real Claude weekly figure into the usage ledger when it is missing or stale: `factory-usage refresh claude --model <model id of models.helpers.search>`, which decides under the ledger's lock (at most once an hour on the machine, never under a recorded limit), asks the claude CLI one tiny prompt (one turn, no tools) in an empty temporary folder it makes and removes, and records the figure it read live. Not a start; reads no credential; its one line says what was recorded or why nothing was. Codex needs none: `factory-usage` reads its session logs |
| `night-wake` | Wake the lead at the start of the machine's night window when night work is queued; released at a handoff |
| `record` | Record one flow of the acceptance demo as it runs, in one take, into a local file the lead uploads: a screen recording for a `ui` flow, a transcript (each command or request, its full output and exit status or response) for a `command` or `http` flow. Never edited; when it cannot record, it says so and returns no file |

## `notify`

For urgent messages only: the emergency stop, a warning before a `cancel`. Every adapter whose children take messages
provides it, with this contract (a headless run takes none once started, so that adapter states it has no `notify`):

- **Now if it can.** When the child is in the middle of a turn, the message reaches that turn, so the child can act on
  it before the turn ends.
- **Otherwise `continue`.** When the runtime cannot deliver mid-turn (the child is between turns, has finished, or
  the runtime refuses), the adapter sends the same message with `continue`, which queues it or starts a new turn.
- **The caller is told which.** The result is one of `delivered` (the child sees it in its current turn), `queued`
  (it sees it after its current turn) or `new turn` (it was idle or finished and a new turn started on the message).
  `not sent` means the child had finished and the message no longer concerned it. `failed` means neither path
  worked; the caller says so and relies on the child's own checks.
- **It never interrupts or restarts work.** No mode that stops, aborts or restarts a turn, and no fresh context.
  Stopping a child is `cancel`, and only when the user asks.
- **It is a backup, not a control.** A child acts on a notify at its next opportunity, and a model may not act on it
  at all. Anything that must hold (no push while paused) rests on the child's own checks at its checkpoints.
- **No secrets** in the message, like every other message.

## Rules for every adapter

- **Model and effort are explicit on every start.** A start without a resolved model and effort is refused, never
  filled in from the parent. See `docs/factory-yaml.md` (`models`) for where they come from.
- **No silent model switch.** If a configured provider or model is unavailable, say so and wait. Never pick another
  model, provider or tier on your own.
- **No polling.** Waiting is event-driven: a completion, a PR watch or one background watcher per CI run wakes the
  lead.
- **State lives on GitHub.** Ids the next lead needs (task and thread ids, branches) go into issue comments, so a
  replaced lead loses nothing.
- **No secrets** in a brief, a message, a comment or a log.
