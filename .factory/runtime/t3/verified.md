# What was verified and what was not

## Findings behind the rules

### `check-home`

**Finding (14 Nov 2026):** a delegated task always runs in the calling thread's own T3 project. `delegate_task` with
a `target.projectId` of another project fails:

> `invalid_request`: "A local task runs in this thread's project. Omit target.projectId, or pass
> target.environmentId to run it in that environment's project."

`target.environmentId` selects another machine, not another project. And `isolation: "worktree"` makes the child's
checkout from the parent thread's checkout. So a lead in a scratch folder, or in another project, cannot start
children in the project's repo.

### `send-report`

**Why (tested 15 Nov 2026):** a background command started with the shell tool's own option wakes its agent when it
ends, in a `delegate_task` child as in a top-level thread (after 95 and 92 seconds, with or without a Monitor). A
detached run (`&`, nohup, setsid) wakes nobody. `t3_background_wait` only keeps the thread marked working: a child
that called it and ended its turn sat idle until its lead continued it. A turn cannot stay open past one foreground
call of about ten minutes, so a longer run always ends the turn.

**Seen again (18 Nov 2026, issue #294):** three children on another project ended a turn "waiting for" a run and
were each steered by their lead. Read back from their threads:
- Two builders started their end-to-end run with the shell tool's own background option and ended their turn on it.
  The run's end woke each of them (after about 4 and 25 minutes): the "finished" notice and the child's new turn
  have the same timestamp. The lead's "your turn ended while the run was still going" message arrived 15 and 20
  seconds after that, while the child was already working again.
- A re-reviewer started verify as `( … ) &` inside a background call. That call's "finished" notice came at once
  and said nothing about verify (the child noticed this itself). It then ended its turn on a Monitor that watched
  the log for an exit line. The lead steered it 6 seconds after its turn ended, on the turn's completion notice,
  without checking the run. Whether that Monitor would have woken it is not shown.

So the background wake works as the rule says, and nothing here calls for a foreground-only rule. The steers came
from the lead acting on a "waiting" completion notice
([t3.md › result](../t3.md#result), [late-child.md](late-child.md)); the one real defect was a detached run.

## The table

| Fact | How it is known |
| --- | --- |
| `delegate_task` refuses a `target.projectId` of another project (exact error above) | Seen on 14 Nov 2026 |
| `delegate_task` returns `taskId`, `childThreadId`, `link`, applied `options`, `executedModel` and `next` ("Completion wakes this thread, so end your turn") | Seen on 14 Nov 2026 |
| A child's completion wakes the parent with "Delegated task "<title>" finished" | Seen on 14 Nov 2026 |
| `orchestrator_capabilities` lists instances with `driverKind`, `canRunChildTask`, `canRunCrossProviderChildTask`, `constraints`, models and their effort options (`effort` on Claude, `reasoningEffort` on Codex); two instances of one driver can exist, one disabled | Seen on 14 Nov 2026 |
| A cross-provider review child (`codex` instance, `reasoningEffort`) runs from a Claude lead | Seen on 14 Nov 2026 |
| A top-level child's `t3_thread_send` reaches the lead as a queued message with its sender's thread id | Seen on 14 Nov 2026 |
| A lead thread with a merged linked PR stays unsettled | Seen on 14 Nov 2026 |
| `watch_pull_request` wakes on checks, comments, reviews and conflicts; one watch per PR | Used in daily lead work before the factory existed; tool description |
| No tool re-parents a running child | All T3 tool descriptions read on 14 Nov 2026 |
| `continue` on a finished child returns a new task id; `t3_thread_wait` wakes on a timeout with `next` | Tool descriptions only; to exercise on the test bench (#21) |
| `notify`: `steer` reaches a running child's turn, a refused steer is an error the lead sees, and what a steer to an idle thread or a finished child does | Tool description only (the four modes, and "a send to a finished child thread starts a fresh task"); the description does not say what `steer` does without a running turn, so `notify` never steers an idle or finished child. To exercise on the bench (#21) |
| `task_cancel` on a task started by an earlier lead | Not known; the description does not say. To exercise on the bench |
| `recover-403` | From the incident; a 403 cannot be triggered on demand, so it is documented, not exercised |
| `back-off` | From the model policy; a usage limit cannot be triggered on demand, so it is documented, not exercised |
| `schedule_task` with `type: "once"` and `bindToCurrentThread: true` posts into the lead thread at `runAt`; an update by `scheduledTaskId` moves it; `list_scheduled_tasks` shows the whole project's tasks | Tool descriptions only; to exercise on the test bench (#21) |
