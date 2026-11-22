# Shifts: the night queue, the night wake and quiet mornings

The windows are machine settings › `shifts` (`night`, `quiet`, `busy`, each `"HH:MM-HH:MM"` in the machine's local
time; `sh .factory/bin/factory-settings machine` shows them). Read them again before each pick, like the caps. With no
`shifts`, or a window left out, the rules below for that window do not apply and work is picked as before.

## The night queue

**Night work** needs no person and can wait:

- bug hunts (the idle-capacity hunters of the `factory-hunt` skill);
- bench runs;
- a project's full end-to-end check (a `heavy` check of `commands.checks`), at the merge gate or on its own;
- factory-update PRs;
- re-reviews nobody is waiting on (the queue only picks when they start; they stay reviews, see step 2 below);
- the weekly maintenance lane;
- the weekly architecture review, once it is due ([below](#the-weekly-architecture-review)).

When a `night` window is set, night work that comes up outside it is **queued**, not started. A free builder slot
during the day stays free for interactive work: "night work waits for the night window at HH:MM" is a named reason
under "Never idle", and hunters wait for the night like the rest.

**Runs at once anyway:** urgent work (the usage reserve's list), except a re-review nobody is waiting on, which waits
for the night but stays a review; a re-review the user or a merge is waiting on; anything the user asks to run now;
and a full end-to-end check that a merge the user is waiting on needs today.

**Where the queue lives:** in every status update, as one line under "Ready next":
`--note "ready: Night queue: <item>; <item>; …"` (each item with its issue or PR, or the hunt area). A restarted or
new lead reads it from the latest status comment.

## At night

1. **The wake.** If the lead is idle when the `night` window starts and night work is queued, the runtime's
   `night-wake` wakes it. A busy lead gets the same message and handles it at its next re-scan.
2. **Start it** like any work: the emergency stop check, `factory-usage may-start`, a free slot within the machine
   caps and the project's share, and the usual model and effort. Every item but a re-review runs `may-start` without
   `--urgent`: it is not urgent, so the reserve holds it back and it stays queued. A re-review keeps the review rule
   of the usage reserve (a review never waits for the reserve) and runs with `--urgent`; the queue only chose when it
   starts. Heavy runs one at a time (`factory lock heavy -- <command>`);
   hunters take builder slots as always. A buildable ready issue still wins a freed slot.
3. **Gates wait.** A human gate found at night waits for the morning: the issue gets its label and comment as usual,
   but the user is not called; it goes into the morning status. Nothing that needs the user merges. Merges that need
   no one go through the merge gate as by day.
4. **After the night's runs,** run `factory gc` once.
5. **Before the window ends,** arm the next night's wake whenever night work is still queued, including when every
   start was refused (the reserve, the emergency stop, the caps); the runtime's `night-wake` says how. Starting this
   window's work and arming the next night's wake are separate steps: being inside the window never skips the second.
   Work still running when the window ends finishes; nothing new from the night queue starts after it.

## The morning status

The first status update after the `night` window ends reports the night:

- `--note "in-flight: Night <date>: <what started>; <what finished, with PRs>; <what is still running>"`;
- every human gate found at night, as a `waiting` note with your recommended answer;
- what stayed queued and why (the reserve, a cap, the stop), in the night queue line.

## The weekly architecture review

The [architect](../../../agents/factory-architect.md) reads the whole codebase against the project's ADRs and the
plan's settled decisions and files what drifted. The cadence is weekly in every project, not a setting. This section
holds with or without `shifts`: without a `night` window, a due review starts like any other non-urgent work.

**The start record is the clock.** Right after you start a review, comment on the status issue (the issue as
[handoff-and-status.md](handoff-and-status.md) › Which issue is the status issue resolves it): first line
`🤖 Lead: architecture review started`, second line
`<!-- factory:architecture event=start review=<review id> sha=<SHA> task=<task id> thread=<thread id> usage=<run id> -->`.
The review id is `a` and the UTC start time to the second (`a20261122T013012Z`), made before the start and put in
the brief, and never one an earlier start record already carries (a retry gets a new id); the task
and thread ids are runtime: `start`'s, the run id is `factory-usage start`'s. It is not a record the gate or the
release reads.

**Only a report that belongs to a recorded run counts,** and the runtime, not GitHub, says whether it does: a start
record **counts** when the runtime's own answer for its task (the child's final result through runtime: `result`, or
`read-child` on its thread after a restart) is the architect's finished report, whose marker names that record's
review id and SHA. Each start record counts at most once, dated by its own creation time. The architect also posts
its report on the status issue, with the same marker, for people and for tracing; no comment, copied, quoted or
forged, ever moves the clock. A start record whose task the runtime does not know, or that ended without that report
(paused, failed, cancelled), never counts.

**When it is due.** At session start (and before the first pick of a session), in this order:

1. **Read** the status issue's comments in two commands, each run on its own and checked:

   ```sh
   gh api --paginate "repos/<repo>/issues/<status issue>/comments" > "<scratch>/status-comments.json"
   jq -se 'length > 0 and all(.[]; type == "array" and all(.[]; (.body | type) == "string" and (.created_at | type) == "string"))' "<scratch>/status-comments.json"
   ```

   The `gh` command must exit 0 and the `jq` one must print `true`. Any failure (a `gh` error, a page that did not
   come, `false`, a `jq` error) is **cannot tell**: start no review, and put
   `architecture review: cannot tell when the last one ran: <the error>` in the status note.
2. **Take the newest start record:** the newest comment whose first line is `🤖 Lead: architecture review started`
   and whose second line is a start marker. A start record whose review id an older **start record** already
   carries is a copy: skip it, so a review id is dated only by its first start record. Other comments that carry
   the id (the architect's report, which may be posted before the start record, a handoff, a quote) never make a
   start record a copy. None: the review is due; stop here.
3. **Reconcile it, every time,** whether or not a report comment exists: read its task once through the runtime
   (runtime: `result` with its task id, in T3 one `task_status`; `read-child` with its thread id when the task is
   unknown). Still running: not due, it keeps its builder slot, and its completion wakes you; stop here.
4. **Finished or gone:** `factory-usage end <run id>`. Exit 0 is fine, and so is exit 1 whose message is exactly
   "that run has already ended"; any other failure goes in the status note for the user. Give its builder slot back.
5. **Does it count?** By the rule above, from the runtime's answer in step 3.
6. **Due:** when it counts, 7 days after that start record's creation time; when it does not, now. A review starts
   only when it is due, so the run before an uncounted one is a week old or more.

Later in the same session you need not read it again: when a review you started reports, its completion is the
runtime's answer, and steps 4 to 6 apply to it then. A paused, refused or failed run never counts, so the review stays
due and goes in the night queue again. The newest issue with an `architecture/` key would not do as a clock: a week
with no drift files none.

**Known gap:** a lead that stops between runtime: `start` and posting the start record leaves a run with no record,
and a later lead may start a second review. Post the record right after the start, before anything else.

**Starting it.** Night work: in the night queue as `architecture review` until the `night` window, then started as
step 2 of [At night](#at-night) says, without `--urgent` (the reserve holds it back). It takes one builder slot, like a
hunter, and a buildable ready issue still wins a freed slot. Start it through runtime: `start` with role `research`,
a worktree on the current tip of the default branch, title `Architecture review`, and the spec
`models.agents.architecture_review` (`sh .factory/bin/factory-settings models.agents.architecture_review`; never an id
from memory). The brief names the review id and the default branch's SHA to read, says to follow the architect agent,
carries the "GitHub access" block when the mode is on, and ends with the `send-report` block. Then
`factory-usage start`, then the start record; the status's in-flight line names it too. One review at a time.

**Its findings** are discoveries, not approved work: agent work is filed `status:backlog`, which you never pick up on
your own; the owner promotes it, or you when the owner asks, as with the backlog of [Follow-ups](../SKILL.md#follow-ups)
and the hunters' P3 findings (`factory-hunt` §§5–6). An `agent:human` finding (gate H4, `status:needs-human`) waits
for the user in the morning status with the architect's recommendation. The architect's report names what it filed
and what its cap of five left out.

## Quiet and busy windows

Between candidates of the same rank (picking work, rules 1 and 2: same queue jump, milestone and priority), prefer:

- in the `quiet` window: heavy builds (`tier:deep`, or work whose checks are heavy) and big reviews;
- in the `busy` window: light work (`tier:light`, docs, small fixes).

This is a preference, never a reason to idle: a free slot takes the best candidate there is.
