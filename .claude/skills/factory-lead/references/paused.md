# While the factory is paused, and resuming

[SKILL.md › Emergency stop](../SKILL.md#emergency-stop) holds the check and the first rule: nothing starts, is
claimed, gated or merged while paused. This file holds the rest.

## While paused

- **Tell the running children.** Each child checks the label itself at its own checkpoints (before a commit, a push,
  a PR, a review comment; `factory-implement` › Emergency stop, the reviewer's Steps), then finishes its current step,
  reports and stops. As a backup, send each child that is still running one message with runtime: `notify` (this
  message is not a start, and the pause allows it): "The factory is paused (`factory:paused` on the status issue).
  Finish your current step, commit nothing new, push nothing, open no PR, post your paused report and stop. If you had
  already finished, reply in one line and do nothing else." `notify` reaches a busy child in its current turn when it
  can, and otherwise falls back to `continue`, which queues the message until that turn ends; it says which. Tell the
  user, in the pause line, which children saw it now and which only after their turn. The child's own checks stay
  what stops it in time. runtime: `cancel` only when the user asks for a hard stop; the worktree and branch stay as
  they were, so the issue can be finished later.
- When a child reports, act only on what needs no start or merge: give its slot back, read the report, keep the
  labels as they are (a paused child stays `status:in-progress` or `status:in-review`), and leave its next step for
  the resume. Read-only work goes on: reading reports and threads, answering the user, posting status comments.
- Do not hand off only because of the pause; if you hand off anyway, write "paused" under Temporary rules in the
  record.

## Resuming

**Resuming.** The user removes the label (on GitHub, or `factory-pause off`). Nothing else is needed: at your next
wake or session, the check passes, you run the [session start](../SKILL.md#session-start) again, and it rebuilds everything
from GitHub. Its "Reconcile children" step picks up what stopped on the pause:

- a builder's paused report ("Implementer report: #N, paused"): take a builder slot, then runtime: `continue` on that
  child's thread: "Resume: the factory is no longer paused. Continue issue #<N> from the step your paused report
  names; your worktree and branch are as you left them." `continue` keeps the child's worktree, where uncommitted
  work may wait. Only when the thread cannot be continued: a new `start` with "finish issue #N on branch <b>", and
  tell the user that uncommitted work may be left in the old worktree (its path is in the report). A paused **fix
  round** is resumed the same way, and its PR gets no review while the round is paused or unfinished. Review it
  once it posts its completed (not paused) fix-round report, at the head that report names. That may be the same
  head when the round changed no code (every finding rejected with evidence or moved out as pre-existing);
- a reviewer that stopped without posting: the PR has no review for its head, so start a new review;
- anything else (a PR waiting for the gate, a queued review): the normal flow.
