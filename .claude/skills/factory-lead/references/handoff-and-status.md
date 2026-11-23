# Handoff, relay and the status issue

The runtime adapter holds the mechanics (its "Handoff to a fresh lead" section): the handoff record's fields, the
launch, how the outgoing lead unwatches its PRs and relays, and how back-off wakes change owner. This file says what
the lead decides and writes.

## When to hand off

- The conversation is long: many PR cycles, earlier context summarised, you re-read what you used to know.
- Before a big new wave of starts.
- Better one step early than late. A timely handoff is a standing rule, so you do not ask first; you tell the user.

Handoff is cheap because almost everything is on the board already: labels, "started" comments, review markers,
evidence comments, back-off records. The record keeps only what the board cannot rebuild.

## Handing off

1. **Compound first.** Run `factory-compound` (lead-handoff trigger) over the temporary rules in force and the calls you
   made: each one it makes permanent goes through its destination and gate, and is no longer temporary; the rest end
   with your session and are listed below as ending. A compound run still waiting on a gate or a draft stays on the
   board, and the record points to it.
2. **Write the record** as one comment on the status issue, headed `Lead handoff <UTC time>`, with the adapter's
   fields. What only you know goes in it:
   - the merge queue with the next step per PR ("gate after the re-review", "update with the default branch, then
     gate", "waits for a reviewer slot");
   - the review queue (PRs waiting for a reviewer slot), in order;
   - held issues and the reasons labels do not show;
   - open questions to the user, with your recommended answers;
   - temporary rules in force, after the compound run above ("local gate while CI is refused", a lower slot count
     while the machine struggles, an open back-off record), each marked as continuing or ending with your session;
   - calls you made that a child is waiting on;
   - scripts the next lead needs, each in its own comment, linked from the record.
3. **Release your back-off wakes**, then runtime: `launch-lead` on `models.agents.lead`, with the adapter's prompt.
4. Edit the record with the new lead's link, and tell the user in one line with that link.
5. **Become relay-only** (below).

## Relay

An outgoing lead does only this, until the user closes the thread:

- unwatch its open PRs (the new lead watches them again);
- on each child completion that wakes it: runtime: `relay`, the child's summary verbatim, to the new lead;
- nothing else: no labels, comments, merges, gates or starts.

After a restart or a compaction, an outgoing lead reads the latest handoff record first; when it is named there as the
outgoing lead, it stays relay-only and runs no session start.

## Taking over

The new lead runs the skill's session start. The record speeds it up but the board stays the source: a "started"
comment, a review marker or an evidence comment wins over a line in the record. A child whose report is late: read
its thread once (runtime: `read-child`) with the ids from its "started" comment.

## Status issue

The open, pinned issue labelled `factory:status`. The user reads it on a phone, so each update is short and current.
**The body belongs to the lead** (decision 29), and **the lead never rewrites it** (decision 30: not until
`factory status` takes the body over with tests, and today it posts comments only): the body is a short fixed note,
and every status update is a **new comment**. Comments are
append-only, so no update can overwrite or lose anything the user wrote, and the user can comment freely to reach the
lead.

The fixed body, written once when the issue is created:

```markdown
This issue is the factory's status board. **The latest status is the newest comment headed "Status" by the lead**;
older ones are collapsed. Comment here to reach the lead.
```

Each status comment, in this order:

```markdown
## Status <UTC time>

### Waiting on you
- #<N> <gate or question, one line, with your recommended answer>
- Release hold: #<N> H7 <what>, before the release of <target>/<env>
- Upstream drafts (H9): <n> waiting, <lesson per draft in a few words, with its incident #N>; which to file? <recommended answer>
<or "nothing">

### In flight
- #<N> <title>: <in progress (role, spec) | in review (PR #P, next step)>
- Compound due: #<N>, #<M> (<trigger per issue>)

### Ready next
- #<N> <title> (milestone, tier)
- Backlog (status:backlog): <N> issues

### Blocked
- #<N> by #A, #B

### Epics
- #<N> <title> (<status or agent:human label, when it has one>)

### Merged recently
- #<N> via PR #P (<date>, <r> fix rounds)

### Model fit (merged recently)
- kind <work kind>, <role>, tier:<tier>: <a> right, <b> too weak, <c> more than needed
- not parsed: <n> lines (PR #<P>, …)
<or "none">

### Temporary rules
- <e.g. local gate while CI is refused (since <date>); back-off on <provider> (record link)>
```

"Epics" lists every open `type:epic` issue except a `status:backlog` one (that one only counts in the backlog total),
after "Blocked", and only when there is one. An epic is never unblocked (it needs a breakdown first) and shows in no
other section, whatever its status. An epic's line keeps its status and `agent:human` labels.

`<r>` is the number of fix-round reports on the PR, every `### Fix round <n> (…)` heading, adaptation rounds included
(`0 fix rounds` when there were none), counted from the PR, never from memory. It is not the escalation count:
[model policy](../../../../.factory/reference/model-policy.md) rule 3 leaves adaptations out of that one, so read the
headings to judge the effect of the [round rule](round-rule.md). Every item under "Merged
recently" carries it.

Under "Model fit (merged recently)", `factory status` counts the model fit lines
([model policy](../../../../.factory/reference/model-policy.md) rule 6) of the reports and reviews on the PRs under
"Merged recently", per work kind, role and tier, by verdict, from the PR comments only. An example in a fenced block or
an HTML comment is not counted. A line that is not in the policy's form is counted as not parsed, with its PR, never
guessed.

"Compound due" is one line, copied from the "Compound due" line of `factory metrics`
([after every merge](../SKILL.md#merge-gate), step 7): the merged issues whose compound run is due and not yet
recorded. It shows only when that list is not empty; with "none" it is left out. An issue leaves it only when its
compound record is posted. When `factory metrics` says "cannot tell", the line says that with its reason, since an
unknown list is not an empty one. With `factory status`, add it as `--note "in-flight: Compound due: …"`.

Upstream drafts are `factory-compound`'s general lessons for the factory repo; filing one is gate H9, so they wait
here, as a single line for all of them (not one per lesson), until the user says which to file
([upstream.md](../../factory-compound/references/upstream.md) › Filing it).

While the factory is paused, the first line under the heading is: **Paused**: `factory:paused` is on this issue;
nothing starts or merges until it is removed. Group by milestone when the board is large. Other comments on the
status issue hold the handoff records and the back-off records. Post a status update after every merge, every new
"waiting on you" item and at the end of a session.

### Publishing status

**Use `factory status`.** It builds the update below from fixed board queries (labels, milestones, the "started"
comments, the open and recently merged pull requests with their review markers and fix-round reports, the open
back-off records), runs this page's validator on it and posts it as a new comment; a failed query or a refused check
posts nothing and says which. `--dry-run` prints it without posting. What the board cannot know (a gate with your
recommended answer, upstream drafts, a temporary rule such as a local gate) goes in with
`--note "<section>: <text>"`, the section one of `waiting`, `in-flight`, `ready`, `blocked`, `rules`; never edit the
posted comment to add it. The steps below are what it does, for a checkout where it cannot run (no `factory.yaml`).
An update its validator refused is not posted by hand either: fix what it names first.

Fail-closed: on any error, at any step, post nothing and tell the user the status update was skipped and why. Work in
fresh files in your scratch directory.

**GitHub access.** The `gh` commands in this file are for a project whose agent-token mode is off, the default, and
run as written. When the mode is on, each one is its broker verb from
[github-access.md](../../../../.factory/reference/github-access.md) (`.factory/reference/github-access.md` in a project), run as
its own command with `--out` before the check that reads its file, and step 4 has no verb, so it is skipped.

`<status dir>` is a folder in your scratch directory made fresh for this update (`<scratch dir>/status`). Fill in
`<status dir>` and `<status issue>` once, with the same text in every command below, before you run any of them: the
commands name their files as literal paths in double quotes (so a path with a space stays one word), never through a
shell variable.

```sh
rm -rf "<status dir>"; mkdir -p "<status dir>"     # fresh files only
```

1. **Build the complete update** in `<status dir>/new.md` from board queries that each succeeded: run every query into its
   own file and check its exit status before using it (`gh issue list … > "<status dir>/q.json" || { echo "FAIL: query"; exit 1; }`),
   never inside `$( )` or a pipe where a failure goes unnoticed. A failed or empty query stops here.
2. **Validate it.** The validator exits non-zero on any failure; a printed message alone is not enough:

   ```sh
   validate() {
     test -s "<status dir>/new.md" || { echo "FAIL: empty"; return 1; }
     for h in "### Waiting on you" "### In flight"; do
       grep -qxF -- "$h" "<status dir>/new.md" || { echo "FAIL: section missing: $h"; return 1; }
     done
     gh issue list -R <repo> --state open --limit 500 --json number --jq '.[].number' > "<status dir>/open.txt" \
       || { echo "FAIL: open-issue query"; return 1; }
     test -s "<status dir>/open.txt" || { echo "FAIL: open-issue query empty"; return 1; }
     gh issue list -R <repo> --state open --limit 500 --label status:backlog --json number --jq '.[].number' \
       > "<status dir>/backlog.txt" || { echo "FAIL: backlog query"; return 1; }
     nb=$(wc -l < "<status dir>/backlog.txt" | tr -d ' ')       # an empty file is a valid answer: no backlog issues
     grep -E '^(- )?Backlog \(status:backlog\): [0-9]+ issues?$' "<status dir>/new.md" > "<status dir>/backlog-line.txt" || true
     test "$(wc -l < "<status dir>/backlog-line.txt" | tr -d ' ')" -eq 1 \
       || { echo "FAIL: need exactly one backlog summary line (0 issues when there are none)"; return 1; }
     test "$(grep -oE '[0-9]+' "<status dir>/backlog-line.txt" | tail -n 1)" -eq "$nb" \
       || { echo "FAIL: backlog count does not match the $nb status:backlog issues"; return 1; }
     awk '/^### /{m=($0=="### Merged recently"); next}
          m && /^- / && !/^- #[0-9]+ via PR #[0-9]+ \([^,()]+, [0-9]+ fix rounds?\)$/' "<status dir>/new.md" > "<status dir>/merged-bad.txt"
     test ! -s "<status dir>/merged-bad.txt" \
       || { echo "FAIL: merged item without its fix-round count: $(head -n 1 "<status dir>/merged-bad.txt")"; return 1; }
     # FILENAME, not NR==FNR: with an empty backlog file NR==FNR would hold for the whole second file.
     awk 'FILENAME == ARGV[1] { b[$1]; next } !($1 in b)' "<status dir>/backlog.txt" "<status dir>/open.txt" > "<status dir>/named.txt"
     rc=0
     while IFS= read -r n; do
       grep -qE "#$n([^0-9]|\$)" "<status dir>/new.md" || { echo "CHECK: open issue #$n not listed"; rc=2; }
     done < "<status dir>/named.txt"
     return $rc
   }
   validate; v=$?
   ```

   Backlog issues (label `status:backlog`) are counted, not named: one line `Backlog (status:backlog): <N> issues`,
   placed after "Ready next", where `<N>` is the count from the validator's own `status:backlog` query (`0 issues` when
   there are none: the line is always there). A failed query, no such line, two of them, or a different count is
   `v=1`. Every other open issue is named as before. An item under "Merged recently" that is not exactly
   `- #<N> via PR #<P> (<date>, <r> fix rounds)` is `v=1` too.

   `v=1` stops the update. `v=2` (a `CHECK`) stops it too, unless the reason is known and deliberate (an issue tracked
   elsewhere on purpose, the status issue itself); then name the reason in your message to the user.
3. **Post it:** `gh issue comment <status issue> -R <repo> --body-file "<status dir>/new.md"`. If posting fails, nothing was written; say
   so.
4. **Collapse the previous status comment** (optional, reversible): GitHub's `minimizeComment` mutation with the
   classifier `OUTDATED` on the lead's previous "Status" comment, so the phone shows the newest one first. Collapsing
   hides nothing for good: a collapsed comment opens with one tap. If it fails, leave it; the newest comment is still
   the latest status.

### Which issue is the status issue

The open issue labelled `factory:status` (list it into a checked file; a failed query stops the caller). factory-init
creates it with the fixed note. There is only ever one: the lead never creates a second status issue, never moves its
records and never rewrites its body. If a query ever returns several, take the newest, change nothing, and ask the user
which one to keep. Every reader and writer in this skill, in `board.md` and in the runtime adapter uses this one issue,
so handoff records, back-off records and `factory:paused` always live in one place.

### An existing status issue with an old full body

Keep it as the status issue. **Never rewrite its body**, never replace the issue and never move its records. Start
posting status comments on it (above), and make the first one begin with: "From now on the latest status is the newest
comment headed Status; the body above is frozen as of <date>." Then ask the user once whether they want to replace the
old body with the fixed note themselves. That is a person editing their own issue, with no agent writing at the same
time; the lead never does it. From then on no status body is written by an agent until `factory status` takes the
body over (decision 30); today it posts comments only.
