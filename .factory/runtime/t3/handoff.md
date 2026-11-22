# Handoff to a fresh lead

When to hand off (long conversation, before a big wave) is the lead skill's rule (L23). How, in T3:

## 1. Write the handoff record

One comment on the status issue (the open issue labelled `factory:status`; see the lead skill's handoff-and-status reference), headed `Lead handoff <UTC time>`. It keeps
what the board cannot rebuild (L24):

- **Outgoing lead:** thread link and id.
- **New lead:** thread link and id; added by editing this comment after step 2.
- **Merge queue:** per PR, the next step (for example "gate after the re-review", "rebase").
- **Running children:** issue, role, task id, thread id, branch, and for a child in a back-off record its resume
  count and state. A copy of the "started" comments and the records, for speed; those stay the source.
- **Held issues** with reasons the labels do not show.
- **Open questions** for the user.
- **Temporary rules:** a link to each open back-off record (see
  [back-off across a handoff](back-off.md#across-a-handoff)), the local gate while CI is blocked, anything else in force.
- **Scripts** the next lead needs: each in its own comment, linked from here; the lead's scratchpad dies with its
  session.

## 2. Release the back-off wakes, then `launch-lead`

Before launching, the outgoing lead releases every back-off wake it owns ([back-off across a
handoff](back-off.md#across-a-handoff)) and its night wake ([`night-wake`](../t3.md#night-wake)): this must be finished before the new lead exists, so the two never race over one wake.
Then it launches the new lead:

```
t3_thread_launch
  title:           "Lead <n>"
  message:         <prompt below>
  modelSelection:  { instanceId: <resolved>, provider: <driverKind>, model: <lead model>,
                     options: [{ id: <effort option>, value: <lead effort> }] }
  clientRequestId: "<owner>-<name>-lead-<n>"    # retry with the same id after an error or a lost reply
```

Leave out `projectId` and `workspaceStrategy`: the new thread inherits the outgoing lead's project and gets the
project's root checkout, so it passes `check-home`. Leave out the modes: they are inherited. The model comes from the
model policy's lead entry, passed explicitly like every start.

Prompt: "You are the new lead of this project. Load the factory-lead skill, run its session start, and resume from
the latest 'Lead handoff' comment on the status issue (<url>). The outgoing lead is <thread link>; it is relay-only
from now on."

Then edit the record with the new lead's link and id, and tell the user in one line, with the new thread's `link`.
A timely handoff is a standing rule of the lead skill, so the lead does not ask first.

## 3. The outgoing lead becomes relay-only

1. List its PRs with `list_thread_pull_requests` (its own `threadId`) and `unwatch_pull_request` each open one. The
   new lead watches them again at its session start (`watch_pull_request` on every open PR from `gh pr list`).
2. Its back-off wakes and night wake were already released before the launch (step 2). It never deletes, moves or edits a wake it
   does not own; from now on the new lead owns them all.
3. From then on it takes no action on the board: no labels, merges, comments, starts or gates (L27).
4. `relay`: on each child completion that wakes it, `task_status` for the summary, then:

```
t3_thread_send  threadId: <new lead id>  mode: "queue"
                message: "Relay from <outgoing lead title>: <child title>\n\n<summary, verbatim>"
```

If the outgoing lead restarts or is compacted, it reads the latest handoff record first. When it is named there as
the outgoing lead, it stays relay-only and skips the session start.

## Can T3 redirect a child's completion to the new lead? No

Checked on 14 Nov 2026 (lesson L25). A `delegate_task` child's completion wakes only the thread that started it, and
no T3 tool moves a running child to another parent:

| Tool | Why it does not redirect |
| --- | --- |
| `delegate_task` | the parent is fixed at start; `task_status` reads only "a delegated task you started" |
| `t3_thread_transfer` | copies or merges context between threads (`fork`, `merge_back`); the child's parent stays the same |
| `t3_thread_launch` (`delegatedFrom`) | sets a relationship when a new thread is created; it cannot change an existing child |
| `t3_thread_configure`, `t3_thread_update` | change model or title only |

So the plan's fix stays the main path, and the adapter keeps a minimal relay as a safety net:

1. **Main path:** every child posts its final report on the issue or PR (`send-report`). The new lead reconciles from
   the board and never needs the thread.
2. **Late report:** the new lead reads the child's thread once (`read-child`), with the ids from the "started"
   comment.
3. **Relay:** the outgoing lead forwards completions, as above. It is no longer the only path, so a settled outgoing
   lead (the 2.5-hour gap of 13 Nov) loses nothing.

Two T3 behaviours may let the new lead take over children directly. Neither is relied on until the test bench (#21)
exercises it:

- `continue` (`t3_thread_send` to a finished child) returns a new task id to the sender, so the new lead seems to own
  any follow-up it sends.
- `t3_thread_wait` on a child's thread (`untilDelegatedWorkSettled: true`) says "on timeout, with `next` end your
  turn", which suggests a wake when that thread settles.
