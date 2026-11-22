# `notify`: what the lead does per child state

| Child's state | What the lead does | Result it reports |
| --- | --- | --- |
| **Running** (started or continued, no completion has woken the lead yet) | `steer`. T3 adds the message to the running turn, which sees it mid-turn. | `delivered` |
| **Running, and the steer is refused** (an error, or the turn ended between the lead's view and the call) | `continue` with the same message (`mode: "queue"`). If a turn is still running, the message waits until it ends; if not, it starts a new turn at once. | `queued` when a turn was running, otherwise `new turn` |
| **Idle** (a thread with no running turn, for example a top-level fallback child between turns) | No steer: `steer` is documented only as a mid-turn update, so it has nothing to update. `continue` (`queue`, "new turn") starts a turn on the message at once. | `new turn` |
| **Finished** (its completion has woken the lead) | Usually nothing: a finished child has stopped and has no step to finish. Send only if the message still matters to it (a cancel warning about its kept worktree, for example): `continue`, which starts a fresh task in its thread and returns a `taskId`. Comment that id on the issue; its completion wakes the lead like any other. | `new turn` (with the task id), or `not sent` |
| **Both sends fail** | Nothing more; no retry loop. | `failed`: tell the user in one line; the child's own checks stay the stop |

If a steer answer carries a new `taskId`, T3 started a fresh task instead of steering a running turn (the child had
finished): report `new turn` and handle it as the finished row. Report the result to whoever asked (the user, or the
lead's own step) per child, so the lead knows who saw the message now and who sees it only after its turn.

Rules:

- **Never interrupts or restarts work.** Only `steer` and `queue`; never `restart`, `auto`, `freshContext` or
  `t3_thread_interrupt`. A steer adds to the turn; it does not stop it.
- **A backup, not a control.** The child's own checks at its checkpoints are what stop it in time; a steered model
  can still finish what it was doing first.
- **No secrets** in the message.
- One `notify` per child per event; never a loop or a repeat on a timer.
