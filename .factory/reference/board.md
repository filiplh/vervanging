# The board by hand

The board's rules, and the `gh` queries that check them by hand. `factory ready` (the candidates in pick order),
`factory unblock` ([Unblock](#unblock)), `factory claim` ([Claim](#claim)) and `factory status` (the status update,
from the [Rebuild](#rebuild) reads) implement them: use those, and the queries here only where the tool cannot run (a
checkout without `factory.yaml`) or for a read it has no subcommand for. A refusal says why; it is not a reason to
take the step by hand around it.

`<repo>` is `project.repo` from `factory.yaml`. `<default>` is the default branch:
`gh repo view <repo> --json defaultBranchRef --jq .defaultBranchRef.name`.

**GitHub access.** Every `gh` and `git` command on this page is for a project whose agent-token mode is off, the
default, and runs as written. When the mode is on, each one has its broker verb in
[github-access.md](github-access.md), which also says who reads the mode.

## Labels

The core label set; the factory's queries and gates depend on these names.

| Label | Meaning | Set by |
| --- | --- | --- |
| `status:blocked` | waits for other issues (the "Blocked by:" line and native dependencies) | lead |
| `status:ready` | every blocker is merged; can start | lead |
| `status:in-progress` | a child is working on it | lead (`factory claim`) |
| `status:in-review` | PR open; review, CI and the gate running | lead |
| `status:needs-human` | waits for a person: a gate, a decision, the owner's OK for the top model, the end of the escalation ladder | lead or the issue's author |
| `agent:<role>` | the role that takes it; `agent:human` means only a person can do it | `factory-tickets`, lead |
| `tier:deep`, `tier:standard`, `tier:light` | model and effort, by the model policy | `factory-tickets`, lead |
| `type:*`, `size:*`, `priority:*`, `hunter:*` | kind, size, urgency, which hunter filed it | `factory-tickets`, hunters, lead |
| `factory:status` | the pinned status issue | `factory-init` |
| `factory:paused` | on the status issue: the emergency stop | the user |

## Rebuild

```sh
gh issue list -R <repo> --state open --limit 500 --json number,title,labels,milestone
gh pr list -R <repo> --state open --json number,title,headRefName,headRefOid,isDraft,labels,closingIssuesReferences
gh api repos/<repo>/milestones --jq '.[] | {number, title, due_on, open_issues}'
gh issue list -R <repo> --label factory:status --state open --json number,labels   # the status issue (handoff-and-status.md › Which issue is the status issue); factory:paused?
```

Per issue in progress or in review, the lead's or solo mode's "started" comments (the latest wins; either prefix, so a project that switches mode finds its running children):

```sh
gh issue view <N> -R <repo> --json comments \
  --jq '[.comments[] | select(.body | test("^🤖 (Lead|Solo): started "))] | last | .body'
```

Per open PR, the latest review marker and the latest local evidence:

```sh
gh pr view <P> -R <repo> --json comments \
  --jq '[.comments[].body | select(contains("<!-- factory:review "))] | last // "" | scan("<!-- factory:review [^>]*-->")'
```

On the status issue: the latest comment headed `Lead handoff` and every open `Back-off record: <provider>`
(the runtime adapter defines both).

### CI on the default branch

The workflows to read: `Factory nightly` when `ci.nightly` is not empty, and the `workflow` of every `ci.external`
entry. Per workflow, its latest finished run on the default branch and that run's jobs:

```sh
gh run list -R <repo> --workflow "<workflow>" --branch <default> --status completed --limit 1 --json databaseId,headSha,conclusion
gh api --paginate repos/<repo>/actions/runs/<run>/jobs --jq '.jobs[] | {id, name, conclusion, steps: (.steps | length), runner: .runner_name}'
```

With agent-token mode on, the run lookup is the "latest finished run of a workflow, by its name" row of
[github-access.md](github-access.md#workflow-runs): the broker's `run-list --workflow` takes a workflow file, not a
name, so that row filters the runs by name.

Read every page (`--paginate`): a run with more than 30 jobs, a large matrix for example, has the rest on later
pages, and a job missing from the list cannot be judged.

For the nightly, the run's `conclusion` is its state. For a `ci.external` workflow, only the jobs the entry lists
count, and the run's own `conclusion` does not: a job outside the list may fail without making the default branch
red. A listed job counts as the job whose `name` is the listed name, or every job named `<job> (…)` for the variants
of a matrix job, all of which must be green. A listed job with no such job in the complete list means the list no
longer matches the workflow: show the workflow as red until `factory.yaml` is fixed.

A listed workflow with no finished run on the default branch shows nothing: show it as "no finished run on
`<default>`", never as green, and the default branch is not green ([merge-gate.md](merge-gate.md) › rule 1).

A listed job is green only with `success`. A listed job with `failure` is red, unless all three of merge-gate.md ›
rule 2's signs of a refusal hold: 0 steps, no runner, and an annotation saying the job was not started (billing, a
spending limit). Read the annotation by the job's `id`:

```sh
gh api repos/<repo>/check-runs/<id>/annotations --jq '.[].message'
```

When any sign is missing, or the annotation cannot be read, the job is red ([merge-gate.md](merge-gate.md) › rule 2,
"Refused is not red").

A listed job with `skipped` is not run, and not red, when its own `if:` skipped it (or, below, when refused needs
did): for its own `if:`, in the workflow file at the
run's `headSha`, the job (its `name:`, else its id) has an `if:` of its own, and every job it `needs:`, directly or
through another, has `success` in the same run. A job whose need failed, was cancelled or was skipped is skipped by
Actions whatever its own `if:` says, so that skip is red, as is a skip the file cannot explain, with one exception: a
job skipped only because GitHub refused jobs it needs is not run, and not red, as a refused job itself is. The
conditions are merge-gate.md › rule 1's; read them there. Every other conclusion (`cancelled`, `timed_out`,
`neutral`, `action_required`, `stale`) is red.

The lead shows each workflow as green, red, refused, skipped by its own `if:`, skipped by refused needs or with no
finished run, with the `headSha` it ran on; what makes the default branch green is merge-gate.md › rule 1.

## Owned paths

Every issue lists its owned paths under an "Owned paths" heading; entries marked `(append-only)` are shared
registries. Two issues overlap when a path could match an entry of both (compare the globs, not only the strings:
`a/**` overlaps `a/b/**`). Append-only entries never count as an overlap. Issues in progress and in review both
hold their paths.

**Brownfield boards.** An older issue may have no "Owned paths" heading, no "Work kind:" line or no milestone. Before
claiming it, the lead adds what is missing in a lead comment (owned paths, work kind, tier), sets the milestone, and
then proceeds. The latest such comment counts as the issue's paths and kind for the overlap check above.

## Unblock

`factory unblock` lists the `status:blocked` issues whose blockers are all done, by the rules below; `--apply` moves
them to `status:ready` and comments why. An epic (`type:epic`) is never unblocked: the tool names it as
`left out: #N (type:epic: propose a breakdown first)`, and by hand you leave it too. An epic gets a breakdown into
issues first. By hand, for each other `status:blocked` issue:

```sh
gh api repos/<repo>/issues/<N>/dependencies/blocked_by --jq '.[] | "\(.number) \(.state)"'
```

Also read the "Blocked by:" line in its body; the two should agree (fix the native links when they do not). The issue
becomes `status:ready` only when every blocker is closed **and** its code is merged: find the merged PR and check
that its merge commit is on the default branch.

```sh
gh pr list -R <repo> --state merged --search "<B>" --json number,title,mergeCommit
git merge-base --is-ancestor <mergeCommit> origin/<default>
```

A blocker closed without a merged PR (a decision, an `agent:human` task) counts when its closing comment says it is
done.

A "Blocked by" number may be a pull request's. It counts as done only when that PR is merged **and** its merge commit
is on the default branch after a fetch. The tool reads it with calls the broker also has: the issue view of the
number (`gh issue view <P> -R <repo> --json state,url`; `issue-view <P>` through the broker) gives its state and its
address, and the merged pull-request search (`gh pr list -R <repo> --state merged --search "<P>" --json number,mergeCommit`;
`pr-list` through the broker) gives the merge commit, taken from the entry whose number is `<P>`. Then the
`git merge-base --is-ancestor` check above. (`pr-view` has no merge commit, so it is not the read.) An open PR is open and a PR closed without a merge is not done; the tool
names each as a pull request, and a closing comment never makes a PR done. After a merge, the issues to look at are the merged issue's dependents:

```sh
gh api repos/<repo>/issues/<merged N>/dependencies/blocking --jq '.[] | "\(.number) \(.state)"'
```

```sh
gh issue edit <N> -R <repo> --remove-label status:blocked --add-label status:ready
```

## Claim

Before a start: the issue has one `tier:*`, is `status:ready`, is not `agent:human`, its blockers are still done, the
board is not paused ([Pause](#pause)). `factory claim <N>` checks these and moves the label; by hand:

```sh
gh issue edit <N> -R <repo> --remove-label status:ready --add-label status:in-progress
```

## Pause

What `.factory/bin/factory-pause status` does, for a project without it. Run the query into a checked file:

```sh
gh issue list -R <repo> --label factory:status --state open --limit 2 --json number,labels \
  --jq '.[] | "\(.number) \(any(.labels[]; .name == "factory:paused"))"' > "<scratch dir>/pause.txt" \
  || { echo "FAIL: pause query" >&2; false; }
```

Not paused only when the query succeeded and the file holds **exactly one line** of the form `<number> false`.
`<number> true` is paused. Everything else is "could not tell" and counts as paused (SKILL.md › Emergency stop): a
failed query, an empty file (no status issue), two lines (several status issues; a person keeps one), or a line
that is not a number, one space and exactly `true` or `false`. Only the user sets or clears the label.

### How a pause check guards a step

Every step that checks the emergency stop before acting (a reviewer's post, a builder's commit, push, PR and report,
the lead's and solo session's starts, claims, label moves, gates and merges) runs it the same way:

1. **The check is a command of its own:** `.factory/bin/factory-pause status`, or the query above. Nothing else runs
   in that command.
2. **Read its exit status,** then act in a **later** command, and only when the check exited 0 (the query: succeeded,
   and its file reads `<number> false`).
3. **Never** chain the action to the check (`check; gh pr comment …` runs the post whatever the check said), never put
   the check in a pipe or a substitution that hides its exit status (`factory-pause status | tail -1`), and never act
   when the check failed, timed out or could not tell: that counts as paused. Try once more as its own command; if
   that does not exit 0 either, take the paused path of your step.

## Follow-ups

```sh
gh issue create -R <repo> --title "<type>(<area>): <what>" --body-file <file> \
  --label "type:<type>,tier:<tier>,status:<blocked|ready>[,agent:<role>][,priority:<P>]" --milestone "<milestone>"
```

The body holds: "Blocked by: #A, #B" (or "none") at the top, "Work kind: <kind>", what and why, acceptance criteria,
owned paths, and where it came from (the PR or review).

**The "Blocked by" line** is one line: `Blocked by: #A, #B` or `Blocked by: none` (also `**Blocked by:** …` and
`**Blocked by**: …`; `none` or `None`). Each entry is `#<number>`, optionally followed by one space and a note in
parentheses without parentheses inside (`#149 (the dispatcher)`); `none` takes the same note
(`Blocked by: none (a product call, see #10)`) and nothing else. The tool splits the line at every comma before it
reads the entries, so a note on a numbered entry holds no comma (`Blocked by: #12 (a, b)` is unreadable, and counts
as blocked); the note after `none` is read with the whole line, so it may hold one (`Blocked by: none (a, b)` reads
as none). A number is an issue's or a pull request's
([Unblock](#unblock) says when each is done). Anything else on the line (another repository, "and", a missing `#`, a
trailing comma, a note that holds parentheses, anything but a note after `none`) makes the line unreadable, and an
unreadable line, or two such lines, count as blocked.

Then the native dependencies, one per blocker:

```sh
id=$(gh api repos/<repo>/issues/<blocker> --jq .id)
gh api -X POST repos/<repo>/issues/<new N>/dependencies/blocked_by -F issue_id="$id"
```

## Escalation record

The model policy (rule 3) says when to escalate. Count "two fix rounds" as it defines them: an adaptation round does
not count. On the issue:

```sh
gh issue comment <N> -R <repo> --body "🤖 Lead: escalated to <new spec> (was <old spec>). Trigger: <needs rework for depth | stuck | two fix rounds that count on PR #P>."
gh issue edit <N> -R <repo> --remove-label tier:<old> --add-label tier:<new>   # only when the new spec is a tier's build model
```

The latest such comment is the spec for the next start, fix round or validator run on that issue.

The step onto the first `claude-fable-5-2` entry of the ladder is not recorded this way until the owner has approved it
(model policy, rule 3): ask first, with the question and `status:needs-human`, and link the owner's comment in the
escalation comment above.
