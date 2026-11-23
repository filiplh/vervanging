# The merge gate by hand

The factory's merge gate rules (the `factory.yaml` schema, "Merge gate rules"), and how to check each one with `gh`
and `git`. Stop at the first rule that fails, say which and why, and do not merge.

Contents:

- [1. Up to date, and the default branch green](#1-up-to-date-and-the-default-branch-green)
- [2. Required checks on the current head](#2-required-checks-on-the-current-head), with [the batch gate](#the-batch-gate)
- [3. The latest review](#3-the-latest-review), with [outside findings after a clean review](#outside-findings-after-a-clean-review)
- [4. The validator](#4-the-validator)
- [5. Human gates and acceptance](#5-human-gates-and-acceptance)
- [6. The records, then the merge](#6-the-records-then-the-merge)
- [After a merge that changes the release checker](#after-a-merge-that-changes-the-release-checker)
- [Lead fixes](#lead-fixes)

**The tool does most of it.** `factory gate <P>` checks rules 1 to 5 on the head and prints pass, or each rule that
fails or cannot be judged and why; `factory gate <P> --record` then writes the gate record of
[step 6](#6-the-records-then-the-merge) (items 3 and 4). `factory verify <P> --why "<reason>"` runs the required
checks on a clean tree of the head and posts the local evidence of [rule 2](#2-required-checks-on-the-current-head)
(item 2). Updating the branch (rule 1), the batch gate and the merge itself (item 5) stay yours. A rule the tool finds
failing (exit 2) blocks the merge. Check by hand, with the steps below, only where it cannot run or judge, and say
which case applies:

- the checkout has no `factory.yaml`;
- agent-token mode is on and the broker is older than its commit verbs (`commit-pulls` and the others in
  [github-access.md](github-access.md)): the gate cannot tell rule 1 between nightlies there. With a current broker it
  proves the tip's own merge through them, as with agent-token mode off;
- a [batch gate](#the-batch-gate): the tool accepts evidence only for the head it names;
- the fix for a red nightly, or for a red `ci.external` job on the default branch
  ([rule 1](#1-up-to-date-and-the-default-branch-green)): the tool fails rule 1 for it too.

A failed read (exit 1 for another reason) is fixed and run again, not gated by hand.

`<repo>` is `project.repo`, `<default>` the default branch, `<P>` the PR, `<N>` its issue.

**GitHub access.** Every `gh` and `git` command on this page is for a project whose agent-token mode is off, the
default, and runs as written. When the mode is on, each one has its broker verb in
[github-access.md](github-access.md); the merge itself is then `pr-merge` with the head this gate checked.

```sh
gh pr view <P> -R <repo> --json number,headRefName,headRefOid,baseRefName,isDraft,mergeable,mergeStateStatus,labels,files
```

A draft PR fails at once: its CI run skips every job. Mark it ready (`gh pr ready <P>`) when the work is complete,
which starts the real checks.

## 1. Up to date, and the default branch green

**Up to date:** `git fetch origin` and `git merge-base --is-ancestor origin/<default> <headRefOid>`. If not:

1. Update the branch with a merge, never a rebase or a force-push: `gh pr update-branch <P> -R <repo>`, or in a
   temporary worktree (below) `git merge origin/<default>` and a normal push. A conflict goes back to the builder
   (fix-round brief: "merge origin/<default> into the branch and resolve the conflicts"), except a conflict in a
   version file's `version` line alone: resolve it yourself, setting that line to a version higher than both sides'
   and touching nothing else, then `git add` and `git commit --no-edit` (item 3). When the merge is clean but the
   version must still go up (both sides made the same bump), raise it the same way inside the merge commit:
   `git merge --no-commit origin/<default>`, edit only that line, `git add`, `git commit --no-edit`. When the default
   branch has not moved since the head last caught up, so there is nothing to merge, but the version must still go
   up, commit only the version line on the head, as one commit of its own, and push it normally; the review carries
   over (item 3).
2. The head changed, so everything below is judged again on the new head. Evidence counts for it only when the
   tree it names is the new head's tree (`git rev-parse <headRefOid>^{tree}`), as after a
   [batch gate](#the-batch-gate); otherwise run the required local checks again and post new evidence.
3. A clean merge of the default branch keeps the review, and so does a merge that differs from git's own only in a
   version file's `version` line, set higher than both sides' (with or without a conflict there). When the default branch
   has not moved and the version must still go up, the raise may instead be one commit of its own, directly on the
   reviewed head, changing only a version file's `version` line to a version higher than the reviewed head's and the
   default branch's; merges of the default branch as above may follow it, and any other commit after the review needs a
   re-review. A merge with any other conflict resolution, or with any other edit of its own, needs a re-review. Which merges count is the
   [deploy contract](deploy-contract.md)'s rule (rule 2, link 5: a review carries over clean merges of the default
   branch, and that one version change), and the release checks it. The new head's evidence still follows item 2:
   its exact tree.

**Default branch green** means one of:

- the latest nightly run on the default branch is green and ran on the current tip, or only commits that `ci.skip_paths`
  covers came after it (a nightly that skipped because nothing changed counts for the commit it names). In agent-token
  mode on, `factory gate` does not take the `ci.skip_paths` part: only a nightly on the tip itself counts there, and
  otherwise the tip's own merge is proved;
- local evidence on the current tip.

With `ci.external` set, the default branch is green only if, in addition, no listed job is red in the latest finished
run of its workflow on the default branch (the query is in [board.md](board.md#ci-on-the-default-branch)). A listed
job is red there unless it succeeded, with three exceptions:

- a job Actions refused is not red (rule 2, "Refused is not red");
- a job skipped by its own `if:` is not run, and not red. That holds only when the job has an `if:` of its own in the
  workflow file at the commit the run ran on, and every job it `needs:`, directly or through another, succeeded in
  that run;
- a job skipped only because GitHub refused jobs it needs is not run, and not red, as a refused job itself is. That
  holds only when, of every job it `needs:` in that workflow file, directly or through another, each one that did not
  succeed in that run was refused by GitHub ("Refused is not red", read as for the listed job) or was itself skipped
  while a job it needs did not succeed (the same test, one level up), and at least one was refused. A refusal there
  that cannot be read, or a `needs:` chain the file does not resolve (a job it does not define, a name that is an
  expression, a malformed `needs:`, a cycle), makes the skip "cannot tell" (`factory gate` exit 1), never not red. Every branch of the
  chain is read, so a red one anywhere in it, or anything else red, wins over that, whatever the order.

A job skipped because a job it needs ran and failed, was cancelled or timed out, or was skipped though every job it
needs succeeded, is red, and so is a skip whose cause the file does not show.

Every other conclusion (`failure`, `cancelled`, `timed_out`, `neutral`, any other skip) is red. A red listed job makes
the default branch red, whatever the nightly or the evidence says, until a later run of that workflow on the default
branch has it green. A listed workflow with **no finished run** on the default branch shows nothing about its jobs
there: the default branch is not green, and `factory gate` cannot tell rule 1 (exit 1) unless something else is red.
That is not a case for the hand gate, which cannot show those jobs green either: start the workflow on the default
branch where its triggers allow it (`gh workflow run "<workflow>" -R <repo> --ref <default>`) and gate again once that
run has finished. Jobs the list leaves out are not read, whatever their conclusion.

**A red latest nightly blocks every merge.** When the latest finished nightly on the default branch failed, timed
out, was cancelled, or skipped with no earlier nightly that passed on the same commit to back it, the default branch
is red, even when the tip's own merge proves green or local evidence on the tip is green: those were gated before
the nightly ran, and the nightly is the later proof. `factory gate` then fails rule 1 (exit 2) and does not read the
tip's merge. Stop merging (factory-lead › Default branch red). The default branch is green again only when a later
nightly passes on the tip, or skips on a commit an earlier nightly passed on.

**The fix for a red nightly** is the one PR that merges while the default branch is red, and it goes through the
hand gate, since `factory gate` fails rule 1 for it too. It is the PR that closes the `incident:red-branch` issue,
up to date with the tip, and `factory gate <P>` passes every rule but rule 1, which fails for the red nightly alone.
In place of "default branch green", every check in `ci.nightly` (of the tip's `factory.yaml` and of the head's)
passes on its head: a manual nightly on its branch
(`gh workflow run factory-nightly.yml -R <repo> --ref <headRefName>`) that passed on exactly `<headRefOid>`, or local
evidence for each `ci.nightly` check on the head's tree. A nightly on another branch never counts as the default
branch's. Write the records of [step 6](#6-the-records-then-the-merge) by hand (`--record` refuses while a rule
fails). After the merge, start the nightly on the default branch
(`gh workflow run factory-nightly.yml -R <repo> --ref <default>`) and merge nothing else until it passes on the tip.

**The fix for a red `ci.external` job** on the default branch merges the same way: the red listed job blocks its own
fix by rule 1 too, so it is the one PR that merges while that job is red, and it goes through the hand gate. It is
the PR that closes the `incident:red-branch` issue, up to date with the tip, and `factory gate <P>` passes every rule
but rule 1, which fails for that red listed job alone. The gate stops reading rule 1 at a red listed job, so check
the rest of it by hand: the head is up to date and the latest nightly is not red (when it is, the PR must also be that
nightly's fix and follow its route too). Rule 2 already holds the head to every listed job, so the
fix's own run of that job passed on its head (or local evidence covers it there). Write the records of
[step 6](#6-the-records-then-the-merge) by hand (`--record` refuses while a rule fails). After the merge, the job's
workflow runs on the default branch (its own triggers, or
`gh workflow run "<workflow>" -R <repo> --ref <default>` where they allow it), and nothing else merges until a
finished run of that workflow on the default branch has the job green.

Between nightlies, the gate keeps the default branch green by construction: every merge ran its checks on a head up
to date with it, and a squash of an up-to-date head leaves exactly the tested tree. Do not run an extra full check on
the default branch after every merge. With `ci.nightly` empty, or while CI is refused, the latest merge's gate evidence
on the tip is the green signal.

## 2. Required checks on the current head

**Which checks:** `verify`, plus every `commands.checks` entry whose `gate` is not `false` and whose `when` selects a
changed file (ordered globs, last match wins; no `when` means every change), read from the head's `factory.yaml` and
from the default branch's: a check the default branch's selects and the head's does not is still required, so a PR
that takes an entry out, narrows its `when` or sets `gate: false` is held to it (one whose head no longer has the
entry is gated by hand). Changed files:
`gh pr view <P> -R <repo> --json files,changedFiles`, then `.files[].path`. That list holds at most 100 files (gh
reads no further), so it is complete only when it has `changedFiles` paths. A longer list is read page by page through
the REST API (`gh api --paginate repos/<repo>/pulls/<P>/files --jq '.[].filename'`, at most 3,000 files, all GitHub
lists); `factory verify` does that itself with agent-token mode off and refuses when the list cannot be read whole.
With the mode on, the broker lists at most 100 files, so `factory verify` refuses a longer PR: split it, or gate it by
hand with the whole list read as above, and its evidence says so.

**The project's own workflows:** every job listed in `ci.external` is a required check too, on every PR. Its CI state
is the check whose `workflow` is the entry's `workflow` and whose `name` is the job name, or the job name followed by
` (` for each variant of a matrix job (all of them must pass). It adds to the checks above and never stands in for
`verify` or a `commands.checks` entry. If the workflow ran on the head but a listed job has no check in it, the list
no longer matches the workflow: the gate fails until `factory.yaml` is fixed.

**Jobs the list leaves out** of a listed workflow are not required checks, and no evidence entry can name them. One
that the workflow skipped on the head (its own `if:`, a job that runs only on the default branch for example) needs
no evidence, here or in [step 6.2](#6-the-records-then-the-merge). Like every other check on the head, it still may
not have run and failed, be unfinished or be cancelled (step 6.3), since the release judges every check by name. One
that Actions refused there fails this rule, since step 6.2 needs evidence for it that no entry can give: re-run it
once CI runs again.

**Jobs of a workflow no list names** (not `factory-ci.yml`, and in no `ci.external` entry of the head's `factory.yaml`
or the default branch's): one skipped on the head needs no evidence either, here or in step 6.2, but only while the PR
leaves that workflow's file unchanged. The file is the one file directly in `.github/workflows/` at the head whose
`name:` (its path when it has none) is the check's workflow; when the PR changes that file, adds it or renames it, when
no file or two files there have the name, or when one cannot be read, the skip needs evidence by its name like every
check that did not run, which no entry can give unless it is a check of `factory.yaml`. As for every check, one that
ran must still have passed, and one Actions refused still needs evidence.

**CI state per check:**

```sh
gh pr checks <P> -R <repo> --json name,state,bucket,link,workflow
```

Judge each required check with this table (the schema's, in the same order):

| CI state on the current head | Counts as passed when |
| --- | --- |
| a job ran and is green | always |
| a job ran and failed (a step, a test or a timeout) | **never** on this head. Re-run it in CI (a flaky failure is re-run, not waived) or fix and push. Local evidence never overrides it. |
| cancelled by a newer push to the same PR | not red; the newer head's run decides |
| not run by design: the check is not in `ci.pr`, or every changed file is in `ci.skip_paths`; for a `ci.external` job, its workflow did not start on this head (its own triggers) or skipped the job (its own `if:`) | local evidence for the current head; for a `ci.external` job, the commands its steps run, read from the workflow file at the head |
| refused or never started: billing, a spending limit, minutes used up | local evidence for the current head; for a `ci.external` job, the commands its steps run, or the checks its entry's `covered_by` names |
| the PR is a draft | not yet: `factory verify` refuses to post evidence on a draft, and evidence by hand waits until it is ready |

**Refused is not red.** A refused job also shows `failure`, so look inside before you call it red. Take the job id
from the check's `link` (`…/actions/runs/<run>/job/<job>`) and read that job by its id (a run's job list gives 30
jobs a page, so the job can sit on a later page):

```sh
gh api repos/<repo>/actions/jobs/<job> --jq '{id, name, conclusion, steps: (.steps | length), runner: .runner_name}'
gh api repos/<repo>/check-runs/<job>/annotations --jq '.[].message'
```

A job with **0 steps, no runner** and an annotation saying it was not started (for example "The job was not started
because recent account payments have failed or your spending limit needs to be increased") was refused: local
evidence counts. A job with steps, one of which failed, is red: it blocks. When unsure, it is red.

While CI is refused, record "local gate while CI is refused" as a temporary rule on the status issue, so the next lead
knows.

**Local evidence** is one PR comment for the tree the checks ran on. Its first line is the evidence record in the
[deploy contract](deploy-contract.md)'s format (rule 2, link 4), with the full 40-character head SHA and the full
tree SHA (`git rev-parse <headRefOid>^{tree}` in the worktree the checks ran in), and nothing else on that line. It
counts for every head with exactly that tree, and for no other:

```
<the evidence record for the head and its tree, exactly as the deploy contract gives it>
🤖 Lead: local evidence for head <SHA>, tree <tree SHA> (up to date with <default> at <SHA>)
FACTORY_TEST_WORKERS=<cap>
- `<exact command>`: passed, <pass> passed, <skip> skipped, <fail> failed (<label>)
- `<exact command>`: …
Why local: <reason>
```

Each entry ends with its label: `verify`, `check <name>` (`check <name>, heavy` for a heavy check), `setup` for
`commands.setup`, and `ci.external <workflow> / <job>` for a `ci.external` job. Such a job needs one entry per step,
in the order of its steps in the workflow file at the head, each with that step's exact `run:` command: a command two
steps run needs two entries, and evidence for part of a job does not count.

**Which `ci.external` jobs evidence can stand for:** only a job whose every step it reproduces exactly. Each step is a
`run:` with nothing beside it but `name:`, `id:` and `shell:` (`sh` or `bash`), and its command holds no expression
(`${{ … }}`). No `env:` at the workflow, the job or a step; `defaults.run` (the workflow's, then the job's) sets at most
`shell:`, `sh` or `bash`, and no working directory; no `container:` or `services:`; `runs-on:` is plain labels of a
Linux or macOS runner; and the job is not a call to a reusable workflow. The one exemption is a leading prefix of
the job: steps before its first `run:` step that are exactly `actions/checkout` pinned to a full commit SHA (40
lowercase hex digits), with only `name:` and `id:` beside it, since the evidence already runs in a checked-out tree of
the head. A checkout after the first `run:` step cleans the tree in Actions, which the evidence does not do, so it
makes the job one evidence cannot stand for, as does any other action, a local one included. Such a job has to run in
CI: rule 2 fails for it, saying why, whatever evidence is posted, unless `covered_by` covers it (below).

**`covered_by`: a refused job covered by factory checks.** A `ci.external` entry may name factory checks
(`covered_by: [verify, licences]`: `verify` or keys of `commands.checks`). A listed job of that entry whose check
**GitHub refused** on the head (billing, a spending limit, minutes used up: the "Refused is not red" signature above)
is then covered by the evidence for the current head holding the entry of **every** check `covered_by` names, each in
`factory verify`'s entry shape for its exact command, passed with 0 failed, instead of the job's own steps. It holds
only for a refusal: a job that ran and failed, timed out or was cancelled fails this rule whatever the evidence, and
one that was skipped, or whose workflow did not start, still needs its own steps. It holds only when the head's
`factory.yaml` and the default branch's both list the job in entries that all give `covered_by`; the evidence then
holds every check either names. So a PR that adds `covered_by`, or adds a job to an entry that has it, is not covered
by it (it changes the list: gated by hand), and one that narrows it is still held to the default branch's names.
Choosing `covered_by` says these checks stand for the job while CI is refused, so a person sets it, in `factory.yaml`
(human gate H4).

When the head is behind the default branch, the second line's bracket reads instead
`(not up to date with <default> at <SHA>; evidence for this head never passes merge-gate rule 1: the updated head needs its own)`.
Such evidence never passes the gate: [rule 1](#1-up-to-date-and-the-default-branch-green) needs a head that is up to
date, and updating it makes a new head, which needs evidence for its own tree.

**Why local** is one line of plain text, at most 300 characters, with no record marker. The usual reasons are
`not in ci.pr`, `skip_paths only`, `not started by <workflow>` and `CI refused: billing annotation on run <run>`;
they are examples, not a closed list, and the gate judges the CI state above, not this line.

`factory verify <P> --why "<reason>"` writes it (its second line names `factory verify` instead of you); the
template is for evidence by hand. It runs the checks rule 2 requires, read from the head's `factory.yaml` and the
default branch's: a check the default branch's selects for the diff and the head's does not still runs, with the
head's command, and one the head no longer has is named in the comment, since no entry can name its command (such a
PR is gated by hand). With `ci.external` set, it reads the PR's checks and also writes the entries of each listed job
whose workflow did not start on the head, or whose check was skipped or refused. It runs every step of the job on its
own, in order, as Actions runs it on Linux and macOS (below), so a step stops at its first failing command. A job
evidence cannot stand for (above) gets no entry at all and is named in the comment. A refused job that `covered_by`
covers (above) runs none of its steps: `factory verify` runs each check `covered_by` names instead, as it runs every
check, a check not required for the diff included, and names the job and its checks in the comment. Without a PR number it runs no
`ci.external` job. A builder's or reviewer's evidence counts for
this rule when it names the current head (or its tree) and the exact commands; the record the gate cites is the one
you post in [step 6](#6-the-records-then-the-merge), or the batch evidence below.

**Checks with `gate: false`** are never required, and neither is a check whose `when` selects no changed file, but
one that did not run in CI on the head (refused for billing, or skipped) still needs evidence
([step 6.2](#6-the-records-then-the-merge)): `factory gate` fails rule 2 until the evidence holds its entry.
`factory verify <P>` writes it: it reads the PR's checks and also runs each check of the head's `factory.yaml` that
is not required and that they show refused or skipped, labelled `check <name>` (`check <name>, heavy` for a heavy
one) like every check, and names those checks in the comment. The other checks that are not required stay under
"Left out, not gating" or "Not needed for this diff". A check cancelled on the head is different: rule 2 fails for
it whatever the evidence holds, so re-run it in CI (`factory verify` says so, and writes no entry for it). A check
that ran and passed in CI needs no evidence, so re-running it in CI once CI runs again also covers it. Evidence by
hand for such a check is needed only where `factory verify` cannot run (the cases at the top of this page) or cannot
read the PR's checks (it says so, and runs no check that is not required): the
template above, holding every entry this head needs, its entry included, in factory verify's entry shape with its
exact `run` command. Only the latest evidence record for the head counts, so that one comment carries every entry.

**Running the checks yourself:** always as a background command, since setup, verify and every selected check run in
full. `factory verify <P> --why "<reason>"` does all of this, heavy checks under a heavy slot, and posts the evidence;
by hand, in a temporary worktree outside the root checkout, never in the root checkout:

```sh
wt=<scratch dir>/gate-<P>
git fetch origin && git worktree add --detach "$wt" <headRefOid>
cd "$wt" && export FACTORY_TEST_WORKERS=<limits.test_workers>
sh -c "<commands.setup>"                     # if set
sh -c "<commands.verify>"
sh -c "<commands.checks.<name>.run>"         # each required check; heavy ones under: factory lock heavy -- sh -c "…"
bash -e -c "<run>"                           # each step of a ci.external job needing evidence (shell below)
cd - && git worktree remove "$wt"
```

A `ci.external` step runs in the shell Actions gives it: its own `shell:`, else the job's `defaults.run.shell`, else
the workflow's, else none. `bash -e -c "<run>"` when it names none (`sh -e -c "<run>"` where the machine has no
bash), `sh -e -c "<run>"` for `sh`, and `bash --noprofile --norc -eo pipefail -c "<run>"` for `bash`; a step that
names `bash` on a machine without bash cannot be run here, so stop. Run every step, a command repeated in two steps
included, and post one entry for each.

Without the lock tool, run heavy checks one at a time on the machine (`limits.heavy`), never two at once.

### The batch gate

Rule 1 voids every queued PR's finished checks at each merge, because each merge changes the tree the next PR will
merge as. When several PRs are ready, you may instead run each one's checks once, ahead, on the exact tree it will
have when its turn comes. It saves the reruns; it never skips a check. It helps only checks that run locally (not
in CI, or while CI is refused): a check CI runs on the new head still has to pass there.

**Batches use the hand gate.** `factory gate` never accepts batch evidence: evidence for a PR's tree that names
another head fails rule 2 ("batch evidence"), because there is no batch record (base, order, members), so the tool
cannot check what voids a batch. The deploy contract defines none either. A PR that merges on batch evidence
(`Ak` for k > 1, and `A1` when it was not up to date with `<B0>`) is gated like this: `factory gate <P>` passes every
rule but rule 2, which fails only with that batch-evidence reason; rule 2 is judged by hand against the batch evidence
(every check that did not pass in CI on the head has its entry there); and the records of
[step 6](#6-the-records-then-the-merge) are written by hand, the gate record with `checks=local evidence=<id of the
batch evidence>` (`--record` refuses while a rule fails). A PR whose own head has evidence for its tree (`A1` up to
date with `<B0>`, or one run again after the batch was void), or whose checks all passed in CI on its new head, goes
through `factory gate` as usual.

1. **Choose the batch and its order:** PRs `A1, A2, … An`, each passing rules 3 to 5 already. The order is the
   merge order, and it is fixed from here on.
2. **Build each combined tree** in a temporary worktree (as in "Running the checks yourself"), on the tip `<B0>` of
   `<default>`: `git worktree add --detach "$wt" origin/<default>`, then `git merge --no-edit <head of A1>`, and so
   on up to `Ak`, in the order. `Tk` (`git rev-parse HEAD^{tree}`) is the tree `Ak` will have once `A1 … Ak-1` have
   merged and `Ak` is updated with a clean merge of `<default>`. A merge with conflicts drops that PR from the batch
   (and every PR after it, whose trees depended on it).
3. **Run the required checks on each `Tk`** and post its local evidence on `Ak`, with `head=<Ak's head>` and
   `tree=<Tk>`, the comment saying `batch on <default> at <B0>, order A1, …, An`. `A1`'s tree is its own head's
   tree when `A1` is up to date with `<B0>`, so its ordinary evidence is `T1`.
4. **Merge in order,** each through rules 1 to 6. After `Ak-1` merged, update `Ak` with a merge of `<default>`
   (rule 1). That merge must be clean (its review carries over), and `git rev-parse <new head>^{tree}` must equal
   `Tk`: then the batch evidence for `Tk` is `Ak`'s evidence in step 6, with no new run. A different tree is a
   different content: rerun as usual.

**What voids the batch** from a PR on (for it and every later one): any PR outside the batch merging into
`<default>`, a new push to a PR in the batch, a merge out of the stated order, a merge into `<default>` that is not
the gate's squash of the next PR, and a conflict when updating. **Keeping to this is your duty, even when the tree
happens to stay equal** (an empty commit, a change and its revert, two orders with the same result): the records
carry no batch membership or order, so the release checker enforces only content, accepting evidence for exactly the
tree it names (deploy contract, rule 2, link 4). Compare the trees before step 6, never cite batch evidence for any
other tree, and once the batch is void, run the checks again as usual.

## 3. The latest review

The latest comment with a `<!-- factory:review … -->` marker. It passes when `p0=0 p1=0 p2=0 human=0` and its verdict
is `merge`. `release_hold` does not block a merge: record the hold (see the skill's human gates).

A review comment counts only **unedited**: the release reads its marker only on the comment's first line (or right after
a first-line `#` heading), in a comment never edited, by a writer (deploy contract, rule 2, "A record that proves is read
strictly"). So never fix a review whose marker is missing or malformed by editing its comment: an edited review proves
nothing, and the review in force at the gate is then the older one. Post a new review comment instead: a new review
start, or the same reviewer posting the whole review again as a new comment with a correct marker. A gate by hand checks
the marker's text and also that the review comment's `updated_at` equals its `created_at`
(`gh api --paginate repos/<repo>/issues/<P>/comments --jq '.[] | {id, created_at, updated_at, user: .user.login}'`).

The marker's `head` may be older than the current head only when the review carries over to it, by the
[deploy contract](deploy-contract.md)'s rule (rule 2, link 5): every commit since is a merge of the default branch,
clean or with only its version raised (rule 1, item 3). Any other commit after the review (a fix, a lead
commit, any other conflict resolution, an edit inside a merge, a rebase) needs a re-review first, or the release
refuses the merge.

### Outside findings after a clean review

A person or a review bot may also comment on the PR (`factory-solo` › All review sources says how to collect them).
Until a factory review on the PR says `merge`, an open outside finding of P0–P2 weight goes into the next fix round
with the factory findings. Once a factory review on some head says `merge`, every outside finding not yet handled
(posted after that review, or posted earlier but first collected after it) is triaged before any further fix round,
into exactly one of three outcomes:

- **A regression the change introduced**, at P0–P2 weight: a case that works on the default branch and fails on the
  head, or a defect in behaviour the issue's acceptance criteria cover. A new implementation of an existing step (a
  tool that takes over a step the skills ran by hand) is judged against that step's contract, its safety checks
  included: a defect there is a regression even when the code is new. It goes into a fix round as before, and a
  re-review follows.
- **Not a regression:** anything else, including an edge case of behaviour the PR newly adds that its acceptance
  criteria don't cover. It does not hold the merge. File a follow-up issue ([board.md](board.md) › Follow-ups) with
  the finding's text, a link to the PR and to the finding's comment, a `tier:*` label, and `status:ready` (P0–P2
  weight) or `status:backlog`. Name the issue in a PR comment that carries the evidence: the same case run on the
  default branch (it fails there too, or the behaviour does not exist there), and that no acceptance criterion covers
  it. A deferral of P0 or P1 weight is judged once more, before the merge, by a review on
  `models.reviews.cross_check` ([model policy](model-policy.md) › Reviews: a narrower review never accepts a deferred
  finding). Otherwise the latest factory review stands.
- **Unsure which:** one question to the person, with both readings and your recommendation (the skill's human
  gates). Never another silent fix round. The PR does not merge until they answer.

Minor outside findings go to the follow-ups, as before. Every fix round counts toward the escalation bound and the
round rule, whatever raised it and whoever fixed it, except an adaptation: a round whose only cause is the default
branch moving under the PR, marked in its heading `### Fix round <n> (adaptation: <what moved>)` ([model policy](model-policy.md), rule 3).

## 4. The validator

The rule applies when an issue the PR closes has a contract section (read as below): the latest validation report on
the PR must then have passed on the current head. A PR whose issues have no section, or a section that reads as none (`none (<reason>)`,
below), owes no validation.
A project with no validator yet is not excused: a contract with no passing report fails the rule.

**What the rule reads.** Each issue the PR closes in this repository, and the PR must close at least one (none
fails: nothing says whether a contract exists). The gate reads the contract section of the issue body as a strict
subset, because a wrong "no section" would skip the validator while a wrong "unreadable" costs one rewording:

- It finds the section only as the exact `##` heading of the core's ticket template (`core/templates/ticket.md` in
  the factory repo), alone on a raw line at column 0, with the two words of that heading nowhere else in the body.
  Inline code, links, emphasis, HTML entities and look-alike letters do not hide them. A mention in a comment, a code
  fence, or a line with HTML markup outside inline code never reads as "no section": the rule fails as unreadable.
- Raw HTML before the heading makes it unreadable too, except an autolink and an HTML comment closed before the
  heading by `-->`, with no `--!>` inside it (a browser ends a comment there, CommonMark does not), that opens at
  column 0 or closes on the line it opens on. A comment that opens mid-line and runs on to a
  later line is refused, and so is one that never closes. After raw HTML or an unpaired backtick, a line that may
  open or close a code fence or a math block also makes the body unreadable. Where an element ends cannot be proved
  without an HTML parser, so the gate does not guess.
- The section runs to the next heading. One line that says `none` with a reason in parentheses reads as none; any other
  text reads as a contract; an empty section is unreadable.
- A `size:S` fix writes `none (size:S fix)` (the ticket template, "None"): the section stays, so the gate reads
  none.

**Outcomes.** No section, or none: the rule does not apply, and says which. Unreadable: it fails and says why, and the
fix is to reword the issue body (an edited body is read again at the gate). Several closed issues with a contract
fail: a validation record names no issue, so give each its own PR. One contract: the latest validation record by a
person with write access, in a comment never edited, must pass on the current head itself, and every later validation
marker must say the same. The validator's report sets what passing means; a validation never carries over to a new
head. By hand, read the same way.

## 5. Human gates and acceptance

- No [H1](human-gates.md) label, `agent:human` or `status:needs-human`, on the pull request itself or on any issue
  it closes in this repository (`gh pr view <P> -R <repo> --json labels,closingIssuesReferences`, then
  `gh issue view <N> -R <repo> --json labels` for each). A PR that closes no issue (no `Closes #N`) fails: its issue's
  gates cannot be read. So every PR closes an issue, a docs-only change included: open its issue first. The gate cannot read a linked approval, so the label decides: H1 is resolved only when the
  approval is linked **and** the label is gone (human-gates.md), and until then a person decides.
- No unresolved merge-blocking gate in the latest review (`human=0`).
- Each acceptance criterion in the PR body is ticked, or its gap has a new issue linked from the PR. "New" means the
  linked issue is open and was created after the PR was opened: an older issue fails even when it names the PR, and
  the issue's body is not read. A creation time that cannot be read (the issue's, or the PR's) is "cannot tell"
  (`factory gate` exit 1), never a pass. A criterion left open without a follow-up fails the gate.

## 6. The records, then the merge

A release proves every merge it ships from two records on the PR, in the exact formats of the
[deploy contract](deploy-contract.md) (rule 2, "The gate chain", links 2 and 4); this page does not define them
again. The proof is time-ordered: a record counts only if it was already there, in this order, when it was relied on,
so write them in exactly these steps, right before the merge. Post each as a new PR comment from your own GitHub
login (a person with write access, never a bot token), with the record as the comment's first line and full
40-character SHAs. Never edit or delete a record afterwards: an edited comment proves nothing. If one is wrong, write
both again, in order.

`<H>` is the head this gate checked (`headRefOid`), `<B>` the tip of `<default>` it is up to date with
(`git rev-parse origin/<default>` after the fetch in rule 1).

**Which checker judges.** The records, the carry-over of rule 3 and the proof of a merge are read by the release
checker of `<B>`, never by the copy on the PR's head (a PR that changes the checker could otherwise approve its own
extra edits). Run `factory gate` from your home checkout of `<default>`, up to date with `<B>`, never from the PR's
worktree: it uses the checker installed beside it, and first compares that file's bytes with `<B>`'s copy at
`.factory/bin/factory-release-check`, read from git; only verified bytes ever run. When they differ, or `<B>` has none,
it refuses (exit 3, nothing judged) before any of that checker runs: run from a PR's worktree, or from a home that is
behind `<B>`, it would read the records with another checker, or fail to load one. By hand, run `<B>`'s copy
(`git show <B>:.factory/bin/factory-release-check`, `core/bin/factory-release-check` in the factory repo), written to
a folder of its own and run with `python3 -I`. So a PR that changes the checker is judged by the old one; the new one
judges the merges after it, and proves releases from the release after the one that ships it ([deploy contract](deploy-contract.md), rule 2, "Which checker proves it").

1. **The review comes first.** The review that passed rule 3 is already on the PR, written before anything below.
   Its marker names `<H>` in full, or an older head it carries over from (rule 3: only merges of `<default>` since,
   clean or with only the version raised, and one version-only commit directly on the reviewed head). For anything
   else since the review, a re-review of `<H>` posts its record first.
2. **The evidence record** for `<H>`: the local evidence comment of [rule 2](#2-required-checks-on-the-current-head),
   whose first line is the contract's evidence record (link 4) with `head=<H>` and `tree=` the tree of `<H>`; or,
   after a [batch gate](#the-batch-gate), the batch evidence already posted on this PR whose `tree` equals
   `git rev-parse <H>^{tree}` (no new record). Note its id: the number after `#issuecomment-` in the comment's URL.
   It must cover every check that did not run in CI on `<H>`, **required or not**: the release judges every check
   and commit status by app and name, so an optional check refused for billing needs evidence too. A job of a
   `ci.external` workflow that its entry does not list, skipped on `<H>`, and a job of a workflow no list names,
   skipped on `<H>` while the PR leaves its file unchanged, are the exceptions: they need none
   ([rule 2](#2-required-checks-on-the-current-head), "Jobs the list leaves out" and "Jobs of a workflow no list
   names"). Skip this step only when every check and status on `<H>` ran in CI and passed, or was such a skipped
   job.
3. **Every check on `<H>` has finished.** Read the checks again (`gh pr checks <P> -R <repo>`, which lists check
   runs and commit statuses): no check or status may be queued, in progress or pending, whether it is required or
   not. Wait until each one has finished; any that ran and failed stops the gate here. A job Actions refused counts
   as finished.
4. **The gate record**, only now: the contract's gate record (link 2) with `head=<H>`, `base=<B>`, `result=pass`,
   and `checks` and `evidence` set like this:
   - `checks=ci evidence=-` only when every check and status on `<H>`, **required or not**, ran in CI and passed,
     or is a skipped job that needs no evidence (step 2's exceptions, rule 2).
   - `checks=local evidence=<id>` (the comment from step 2) when any check, required or not, did not run in CI:
     not run by design, or **refused for billing** (a spending limit, minutes used up). The evidence then covers
     those checks one by one, each with its exact command in the comment, as the contract allows; every check that
     did run in CI must still have passed. Local evidence never covers a job that ran and failed.
5. **Nothing changed, then merge.** Right before the merge, check that the PR head is still `<H>`, that `<default>`
   is still at `<B>` (`git fetch origin && git rev-parse origin/<default>`), and that no check or status on `<H>` is
   running or has failed since step 3. Then merge that exact head:

   ```sh
   gh pr merge <P> -R <repo> --squash --delete-branch --match-head-commit <H>
   ```

   In mode on, `pr-merge <P> --head <H>` does the same. Never `--admin`. Then the skill's "after every merge" steps.

**A gate record written by hand** (a rule the tool cannot judge, see the top of this page) is the same record, and
keeps `<default>` provable for rule 1 and for releases only in this exact shape: the comment's first line (or the
line right after a first-line `#` heading) is the whole marker, and anything you say about the gate goes on later
lines, never on the marker's line:

```text
<!-- factory:gate head=<H> base=<B> result=pass checks=local evidence=<id> -->
**Hand gate: pass.** <why the tool could not judge it, each rule's state, the approvals it relies on>
```

with `checks=ci evidence=-` instead when step 4 says so. Right after the merge `<M>`, prove it as rule 1 and the
release will, with `<B>`'s checker run as "Which checker judges" says (`python3 -I <that copy> check --from <B> --to <M>
--repo <repo> --branch <default> --prove`): no output means the merge proves. A `not-gated:` line names the link that
fails; the records cannot be edited, so tell the person, who decides how to go on.

**If anything moved between the gate record and the merge**, do not merge on that record. A new push or a branch
update (a new head), a move of `<default>` (update the branch: a new head again), or a check that started and is
still running all void it. Finish what is running, judge the new head from rule 1, then write both records again,
in order: a new evidence record for the new head (unless an earlier one names its exact tree) and a new gate record
after it. Never reuse a gate record for another head; evidence and reviews carry over only as rules 1 and 3 say.

**Leave the records alone.** No later comment, formal review or edit of the PR description may carry a
`factory:evidence`, `factory:gate` or `factory:review` marker that says something else (a quoted example, an old
marker pasted back): any marker later than a record contradicts it, and the release refuses. Reports describe the
records in words ("the review record for head `abc1234` says merge, with no findings"), never by quoting a record.
When a tag's name has to appear (a PR that changes how records are read, say), write it in prose: without the opening
`<!--` before it, and with no record field (`head=`, `verdict=`, `p1=`, `result=` and the other keys of the
[deploy contract](deploy-contract.md)) anywhere after it in the same description or comment. The checker reads a tag
followed by a record field, anywhere later in the same text, or a tag right after `<!--`, as a marker; a code fence, a
quote or inline code does not hide it, and the description always counts as later than every record.

## After a merge that changes the release checker

**Trigger:** a merge whose diff changes the release checker, `.factory/bin/factory-release-check`
(`core/bin/factory-release-check` in the factory repo; a `factory-update` PR in a project). That file holds the whole
marker grammar: `factory gate`, `factory verify` and `factory markers` load it from beside themselves, and nothing else
holds a reading of records. `git diff --name-only <merge>^ <merge> -- .factory/bin/factory-release-check` prints its
path when the merge changed it.

**Why:** the PR that changes the checker is gated and proved by the old reading ([step 6](#6-the-records-then-the-merge),
"Which checker judges"), but every gate after it, and every release from the one after it ships, reads every other
open PR's records with the new one. A description or comment that the old reading took for prose can now read as a
marker that contradicts a record, and that PR's gate refuses, or its proof does, once its records are written.

**The pre-check:** right after the merge, from your home checkout brought up to date with it, and before the next
gate, run `factory markers`. It reads each open PR's description, conversation comments, formal reviews and inline
review comments the way the gate reads markers, with the gate's own test for whether a marker agrees (rules 2 to 4
and step 6): a marker later than the latest review, evidence, validation or gate record of its kind is named when it
does not say what that record says. A marker in the description, or in a comment without a readable time, counts as
later than every record and is judged the same way, so one that agrees with the record in force is not named. Only
a gate marker there is named whatever it says, since no gate record could stand after it (step 6). A review, evidence
or validation marker with no record of its kind yet is not named: the gate judges it once that record exists, and so
does the next run. It uses the checker beside it, verified against the default branch's copy as the gate does. For each PR it
prints `clean`, `cannot tell` with the reason, or one `edit <where>` line per place: the description, or a comment, a
formal review or an inline review comment by its id. Exit 0: all clean; 2: a place to edit; 1: a PR it could not read
(read it again); 3: refused before any of the checker ran, because the checker beside it is not the default branch's
copy (run it from the updated home). `factory markers <P>` reads only that PR; it may run at any time, and it reads only.

**Acting on it:** before that PR's next gate, have each place edited.

- An example or a quote (prose the old reading let through): reword it as the wording rule of
  [step 6](#6-the-records-then-the-merge) (Leave the records alone) says. The description is yours to edit
  (`gh pr edit <P> -R <repo> --body-file <file>`); a comment is edited by its author, or by you. That is the
  [deploy contract](deploy-contract.md)'s clearing policy (rule 2: a marker that is not a real result is cleared by
  editing or deleting it).
- A real result (a later review with findings, evidence that failed): no rewording clears it; handle it as the gate
  would (a fix round and a re-review, new evidence).
- A record comment is never edited (an edited record proves nothing): when a record itself has to change, write the
  records again, in order ([step 6](#6-the-records-then-the-merge)).

Say on the PR, in words, what was edited and why. Run `factory markers <P>` again: it must say `clean` before the gate.

**Trust boundary:** the pre-check reads the PRs' text through `gh` or the broker and runs only the default branch's
checker: the bytes of the copy beside it are compared with the default branch's blob before any of them runs, and
only those verified bytes are compiled and run. It never fetches, checks out or runs
anything from a PR's branch, posts nothing and edits nothing. It only adds warnings: a `clean` result is not a gate
pass, and nothing it reads or prints can make a record prove. The gate and the release still judge every record with
the default branch's checker, so nothing a PR changes, its own copy of the checker included, can make a record prove.

## Lead fixes

A few-line fix you make yourself:

```sh
wt=<scratch dir>/fix-<P>
git fetch origin && git worktree add -b lead-fix-<P> "$wt" origin/<headRefName>
cd "$wt"            # fix, then run commands.verify and the required checks with FACTORY_TEST_WORKERS set
git commit -am "fix(<area>): <what>" && git push origin HEAD:<headRefName>
cd - && git worktree remove "$wt" && git branch -D lead-fix-<P>
```

Link the PR to your thread (runtime `link-pr`), and comment what you changed and why under the heading
`### Fix round <n> (lead)`, with `<n>` counted as the fix-round report counts it: that comment is a fix-round report
and counts as a round ([model policy](model-policy.md) rule 3). Start a re-review when the fix
touched a P0–P2 finding or behaviour (at the effort the skill's re-review rule sets), and for any other fix too (a fix that should not get a re-review waits for a later round instead of being pushed): the release proof needs a review record of the new head (deploy-contract.md rule 2 link 5). The evidence comment for the new head is yours to post.
