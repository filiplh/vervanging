# Fallback: children as top-level threads

Only when `check-home` fails and the user agrees to run this way instead of moving the lead. Each child is then a new
top-level thread in the project, not a delegated task:

```
t3_thread_launch
  title:             "#<N> <short title>"
  projectId:         <the project's T3 id, from t3_project_list>
  workspaceStrategy: { type: "worktree", baseRef: "origin/<default branch>", startFromOrigin: true, branch: "<branch>" }
  modelSelection:    { instanceId, provider, model, options: [{ id: <effort option>, value: <effort> }] }
  message:           <brief, with the lead's thread id for the report>
  clientRequestId:   <unique>
```

What changes:

- The same refusal rules apply: no tier, no spec or no effort means no launch.
- There is no completion wake and no task id. The child sends its report with `t3_thread_send` (`threadId` of the
  lead, `mode: "queue"`, prefixed "Report from #<N>:") and also posts it on the issue or PR.
- The "started" comment holds the thread id; `read-child` works the same way.
- `continue` is `t3_thread_send` to that thread; to stop one, interrupt its thread, since there is no task to cancel.
- Every child shows up in the user's thread list.
