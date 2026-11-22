# `back-off`

**What it is:** a child stops on a usage or rate limit of its provider ("usage limit", "rate limit", "429", "limit
reached"), sometimes with a reset time. On subscriptions the scarce resource is the usage window, so the factory runs
fewer children, never weaker ones (decision 10, L19).

- **Never** change a tier, a model, an effort or a provider because of a limit.
- The limit belongs to one provider. Back off only the children that run on it (read each child's spec: builders and
  some reviewers share a provider, the model policy › Reviews says which). Children on other providers carry on.

## The numbers

- **Ceiling:** half the machine cap of each affected pool, rounded down, at least 1.
- **Cooldown:** one hour at that ceiling after the latest limit. Without a reset time it starts at the error; with
  one, nothing starts on that provider until the reset, on any lead of the machine (the reset is in the usage ledger,
  step 0 below), and the hour starts at the reset.
- **Another lead's limit:** when `factory-usage may-start <provider>` says "usage limit until <time>" and none of
  your children hit it, you open no record and park nothing: your running children carry on, and you start nothing
  on that provider until that time. Your own back-off starts only when one of your children stops on a limit.
- **Eligible time:** the end of the cooldown, so the error time plus one hour, or the reset time plus one hour. No
  stopped child resumes before it.
- **Ramp:** after each later hour with no new limit error, one slot more, until back at the cap. The back-off then
  ends.
- **A newer limit restarts all of it:** ceiling back to half, the cooldown and the ramp evidence counted from the new
  limit, and the eligible time moved to the later of the old and the new one.

## The recovery record: one per provider

All back-off state lives in one comment on the status issue per provider, headed `Back-off record: <provider>`. It is
the only copy: the lead edits it at every step below, so a restarted or new lead finds everything in it, and the
handoff record links to it instead of copying it.

```
Back-off record: <provider>
ceiling:        <pool> at most <k> of <cap>        # one line per affected pool
last limit:     <UTC>, reset <UTC | none>
eligible from:  <UTC>
evidence since: <UTC>                              # start of the current cooldown or ramp hour
next wake:      <UTC>                              # when the wake is due; kept when a handoff releases the wake
wake:           <scheduledTaskId>, owner <lead thread id>   # or: none
children:
- #<N> <role> task <taskId> thread <threadId> branch <branch> spec <spec> resumes <0-3> <queued | running>
```

A child is in the record from the first limit it hits until it **succeeds** (it finishes without a limit and reports)
or reaches `status:needs-human`. It stays in the record while a resumed attempt runs, so its resume count is never
lost. If `recover-403` replaces it, the replacement takes over its line and its count.

The record is never written to `~/.factory/machine.yaml`; the caps there are a ceiling, and the user edits them by
hand to lower them for good.

## The wake: exactly one per provider

The record holds the provider's one wake. It is a one-shot `schedule_task` that posts into the lead thread, which
wakes the lead:

```
schedule_task
  title:               "Back-off wake: <provider>"
  schedule:            { type: "once", runAt: "<eligible from>" }
  bindToCurrentThread: true
  prompt:              "Back-off wake for <provider>: run the back-off wake step of the runtime adapter."
  clientRequestId:     "<owner>-<name>-backoff-<provider>-<runAt>"
```

- **Arm:** when the record's wake is `none`, create it with `runAt` = the record's `next wake` (or now, if that has
  passed), and write its `scheduledTaskId` and owner into the record.
- **Move:** set `next wake` to the new time, and change the wake in place: `schedule_task` with its `scheduledTaskId`
  and only the new `schedule`. If T3 refuses because that task is gone or has already run, create a new one and
  replace the id in the record. Never create a second wake while the record names one.
- **Remove:** only the owner named in the record removes a wake: `delete_scheduled_task` with its `scheduledTaskId`,
  then set the record's wake to `none`. `next wake` stays, unless the back-off has ended.

Besides the [night wake](../t3.md#night-wake), this is the only use of `schedule_task` in the factory. Never `interval`, a background `sleep` or a loop.

## When a child stops on a limit

0. **Tell the machine.** End the child's run in the usage ledger (`sh .factory/bin/factory-usage end <run id>`), then
   record the limit there: `sh .factory/bin/factory-usage limit <provider> --reset <UTC>` with the reset time the
   error gave, converted to UTC, or without `--reset` when it gave none. With a reset, every lead on the machine,
   of every project, then gets "no" from `factory-usage may-start <provider>` until the reset, urgent work too, instead
   of each hitting the limit separately. Record each limit once; a second child stopping on the same limit with the
   same reset adds nothing.
1. **Open or update the record.** Open the provider's record if there is none. Otherwise apply "a newer limit
   restarts all of it": ceiling back to half, `last limit` and `evidence since` set to the new limit, and `eligible
   from` set to the later of the old value and the new one.
2. **Park the child.** It gives its slot back: a waiting child holds no slot. If it already has a line (a resumed
   attempt that hit a limit again), keep its resume count and set it to `queued`. Otherwise add a line with
   `resumes 0`, `queued`. Its worktree, branch and "started" comment stay as they are.
3. **Retry bound.** If its count is already 3, do not queue it: label the issue `status:needs-human`, comment why (the
   provider, the three resumes, the thread id), tell the user in one line, and remove its line. Its worktree and
   branch stay, so a later `continue` picks up where it stopped.
4. **Set `next wake` to `eligible from`**, and arm or move the wake to it.

Children still running on that provider keep going. No new child starts on it while any child in the record is
`queued`.

## At each wake

1. **Too early?** If now is before `eligible from` (a newer limit moved it), move the wake to `eligible from` and stop
   here. Nothing resumes.
2. **Ceiling.** A newer limit has already reset the ceiling and `evidence since`, so only the time since then
   counts, and the ceiling rises at most once per **full hour** of evidence. If less than an hour has passed since
   `evidence since` (an early wake, for example right after a handoff), keep the ceiling and keep `evidence since`.
   After a full hour: if children ran on that provider in it without a limit error, raise the ceiling by one; if
   nothing ran while children are queued, there is no evidence, so keep it (the case after the first cooldown when
   every child had stopped); if nothing ran and nothing is queued, there is no demand, so raise it by one and an idle
   back-off still ends. Then set `evidence since` to now.
3. **Resume** queued children, oldest first, while the pool has room under the ceiling and the usage reserve allows
   it (the lead skill's before-every-start check: a resume is a start, and a new run in the ledger). Each takes a slot again and is
   resumed with `continue`: "Resume: your last turn stopped on a usage limit. Continue issue #<N> where you stopped;
   your worktree and branch are as you left them." `continue` runs in the child's own thread, so its model, effort,
   worktree, branch and context stay the same. Do not set `freshContext`. In the record, add 1 to its resume count,
   set it to `running` and write the new task id; comment the new task id on the issue; check `executedModel` when it
   finishes.
4. **Next wake.** While any child is in the record or the ceiling is below the cap, move the wake to one hour after
   `evidence since` (so `next wake` and the wake itself). Otherwise the back-off ends: remove the wake, clear
   `next wake`, and close the record with a last line "ended <UTC>".

When a `running` child in the record finishes without a limit, remove its line. When it hits a limit again, it is
parked as above with its count kept.

## Across a handoff

The wake belongs to one lead thread, so its ownership moves with the lead. The recovery record carries everything
else.

- **Outgoing lead, before `launch-lead`:** for each open record whose wake it owns, remove the wake
  (`delete_scheduled_task`) and set `wake: none`, keeping `next wake`. It never touches a wake whose owner is another
  thread. In the handoff record, link each open recovery record, and list the resume count and state of every
  recovering child next to the running children. Only then does it launch the new lead.
- **New lead, at session start:** run `list_scheduled_tasks` (scheduled tasks belong to the project, so it sees every
  lead's) and delete any "Back-off wake" that no open record names as its wake (an orphan from a crash). Then, for each
  open record with `wake: none`, arm one wake at the record's `next wake` (or now, if that has passed), in its own
  thread, and write itself in as the owner. It never arms at `eligible from` again: `next wake` keeps the hourly ramp,
  and the full-hour rule in the wake step keeps an early wake from raising the ceiling. Children keep their counts from
  the record, so the three-resume bound holds across leads.
- **The same lead after a restart** finds itself as the owner and keeps the wake.

A limit hit by the lead itself stops the lead; it resumes from GitHub when it runs again.
