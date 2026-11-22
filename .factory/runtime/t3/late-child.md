# A child whose turn ended without a report

**A child whose turn ended without a report** (none on its PR or issue). Read its last message once, as in
[`read-child`](../t3.md#read-child).

Look at the PR or issue first, once per wake, whatever woke you: a child that waited for a run may have finished and
posted its report while its continuation notice never arrived (`task_status` still shows the waiting line as
`summary`, `latestTerminalSummary: null`; [`result`](../t3.md#result)). A report found there is its result: act on
it, and skip the rest of this page.

- **It waits for a run** ("Waiting for <command>, started <time>"): it is not idle while that run goes on, because
  the run's end wakes it ([`send-report`](../t3.md#send-report-what-every-child-does-at-the-end)). Check the run before you
  do anything: look for its process on this machine (`ps -Ao pid,etime,command`, matching the command it named; when
  several match, `lsof -a -d cwd -p <pid>` shows which runs in the child's worktree) and for a newer turn in the
  child's thread. While the run goes on, leave the child alone and count its slot as busy. `continue` it only when
  the run has finished and no new turn of the child followed within about five minutes: "Your run <command> has
  finished. Read its result, then push and report." A completion notice whose summary is that waiting line is no
  reason to act: the check above comes first, also when the notice has just arrived. A lead that steered on the
  notice at once reached children that had already woken by themselves ([seen 18 Nov 2026](verified.md#send-report)).
- **Anything else** (no run named, a detached run, or it simply stopped): it ended its turn without finishing, which
  the `send-report` block forbids but a child can still do. Nothing wakes it, so it holds a slot while doing
  nothing: `continue` it at once. If it stopped on a question or a block, act on that as for any report.
