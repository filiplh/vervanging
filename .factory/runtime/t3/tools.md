# Tools the factory uses

| Tool | Operation | Parameters the factory sets |
| --- | --- | --- |
| `orchestrator_capabilities` | `resolve` | none; `search` to find a model the short list omits |
| `t3_thread_read` | `check-home`, `read-child`, `recover-403` | `threadId`, `view`, `limit`, `maxCharsPerItem` |
| `t3_project_list`, `t3_project_read` | `check-home` | `projectId` |
| `delegate_task` | `start` | `title`, `role`, `isolation`, `mode`, `target`, `task`, `clientRequestId` |
| `task_status` | `result` | `taskId` |
| `t3_thread_send` | `continue`, `notify`, `relay`, `recover-403`, fallback reports | `threadId`, `message`, `mode`, `clientRequestId` |
| `task_cancel` | `cancel` | `taskId`, `reason` |
| `link_pull_request` | `link-pr` | `url` |
| `watch_pull_request` | `watch-pr` | `url` |
| `unwatch_pull_request` | `unwatch-pr` | `url` |
| `list_thread_pull_requests` | handoff | `threadId` |
| `t3_background_wait` | `watch-run`; optional in `send-report` (it only marks a thread as working) | `taskIds` |
| `schedule_task` | `back-off` wake: arm, and move by `scheduledTaskId`; `night-wake`: arm | `title`, `schedule` (`type: "once"`, `runAt`), `bindToCurrentThread`, `prompt`, `clientRequestId`, `scheduledTaskId` |
| `list_scheduled_tasks`, `delete_scheduled_task` | `back-off`, `night-wake`: remove a wake, clean up at a handoff | `scheduledTaskId` |
| `preview_open`, `preview_recording_start`, `preview_recording_stop`, `t3_preview_close` | `record` (a `ui` flow) | `target` (`kind: "environment-port"`, `port`, `path`), `reuseExistingTab: false`, `tabId` |
| `preview_navigate`, `preview_snapshot`, `preview_act`, `preview_wait_for` | `record`: the flow's steps, inside the recorded tab | `tabId` and each step's own parameters |
| none: the lead's own shell | `refresh-usage` | `factory-usage refresh claude --model <model id>`, as [`t3.md`](../t3.md#refresh-usage) says |
| `t3_thread_launch` | `launch-lead`, fallback | `title`, `message`, `modelSelection`, `clientRequestId`; `projectId` and `workspaceStrategy` only in the fallback |
