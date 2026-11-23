# GitHub access: plain `gh` and `git`, or the broker

Every GitHub step in the core skills, agents and references is written with plain `gh` and `git`. That is how they
run in a project whose **agent-token mode is off**, the default: nothing on this page changes them. In a project
whose mode is **on**, agent shells hold no GitHub credential, so plain `gh`, `git push` and `git fetch` fail by
design, and the one way to GitHub is the broker, `factory-github`. This page is the one mapping from each plain
command the core uses to the broker verb that replaces it. The skills point here; they do not repeat it.

What the mode is, how it is switched and every rule of the broker are in the runtime adapter's Security section
([`.factory/runtime/t3/security.md`](../runtime/t3/security.md) in a project, `runtime/t3/security.md` in the factory repo) and in the
factory source's `core/templates/agent-tokens/README.md` (not installed in a project). This page restates none of them.

## Which column applies

- **The lead and a solo session** read the mode themselves, from the root checkout, at session start and right before
  every start of a child:

  ```sh
  if [ -x "$HOME/.factory/bin/factory-github" ]; then "$HOME/.factory/bin/factory-github" mode; else echo off; fi
  ```

  | Answer | Column | Starts |
  | --- | --- | --- |
  | `off` | mode off | as today |
  | `staged` | none: no child may reach GitHub | only the isolation probe, when the user asks for it |
  | `on` | mode on | only after the adapter's preflight passes, before every start |
  | anything else (`blocked: …`, an error, no answer) | none | nothing; tell the user the reason the broker gave |

  What to do for each answer is the adapter's table under "The switch: off by default, and held by the machine",
  and the preflight and the probe are its "Preflight: before every child start". Follow them as written there.
- **A child** does not read the mode. Its brief decides: a brief with a **GitHub access** block (the adapter, "How
  agents call the broker") means mode on; a brief without one means mode off, and the plain commands apply exactly as
  written in the skill.

## How a broker call looks

`<bin>` is the absolute path the brief or the lead wrote out (never `~` or `$HOME` in the call). Each call is a
plain command on its own: no `cd`, pipe, redirect, `$(…)` or variable assignment, or it stays sandboxed and is
refused. What replaces a plain command's extras:

- **`--json` and `--jq`.** Read verbs print fixed fields as JSON. Add `--out <bare name>`, then run `jq` on the path
  the broker prints, in a separate command. The fields a verb prints are in `<bin>/factory-github help`.
- **`--body "<text>"`.** Write the text to a file in your worktree or the session temp folder and pass
  `--body-file <file>`.
- **`-R <repo>`.** Never: the broker always uses the repository registered for the checkout.
- **Several labels in one flag.** One label per `--label`, `--add` or `--remove`.
- **A refusal** (exit code 2, `refused: …` on stderr) is not transient: no retry and no other way around it. Stop and
  report the reason. A step with no verb below has no way to GitHub in mode on; never reach GitHub another way (no
  `gh api`, no `curl`, no token of your own).

**Root checkout only** marks verbs the broker runs only for the lead or a solo session; in a worktree they refuse.

## The mapping

### Repository and session

| Step | Mode off | Mode on |
| --- | --- | --- |
| Default branch name | `gh repo view [<repo>] --json defaultBranchRef --jq .defaultBranchRef.name` | `<bin>/factory-github default-branch` |
| The lead's or solo session's GitHub login works | `gh auth status` | the adapter's preflight (placeholder check, then `<bin>/factory-github check`) |
| Fetch | `git fetch origin` | `<bin>/factory-github fetch` |
| Fetch a PR's head | (part of `gh pr checkout`) | `<bin>/factory-github fetch --pr <P>`: the head as `origin/pr/<P>` |
| Pull the root checkout | `git pull --ff-only` | `<bin>/factory-github fetch`, then `git merge --ff-only origin/<default>` |
| Push a branch | `git push -u origin HEAD`, `git push origin HEAD:<branch>` | `<bin>/factory-github push <branch>` (never the default branch). `--lease` only where the plain step would force-push, which no core step does to a pushed branch |
| List remote branches | `git ls-remote --heads origin` | `<bin>/factory-github ls-remote` |
| The pause check | `.factory/bin/factory-pause status`, or the query in [board.md](board.md) › Pause | a person or an unsandboxed lead: `.factory/bin/factory-pause status`. A sandboxed agent: `<bin>/factory-github issue-list --label factory:status --state open --limit 2 --out pause.json`, then `.factory/bin/factory-pause status --from <the path it printed>`. Exit codes, the checks on the file and every other rule are in the [tool's header](../bin/factory-pause). A Codex child skips it; the lead checks for it |
| Set or clear the pause (the person only) | `.factory/bin/factory-pause on` (or `off`) | the person's own terminal outside every checkout of the project: `factory-pause on --repo <repo>` (or `off`); or from the root checkout `<bin>/factory-github issue-labels <N> --add factory:paused` (or `--remove`; `<N>` is the status issue), then `status`. The tool refuses `on` and `off` here; see its [header](../bin/factory-pause) |

### Issues

| Step | Mode off | Mode on |
| --- | --- | --- |
| Read an issue, with comments | `gh issue view <N> --comments`, `gh issue view <N> --json comments --jq …` | `<bin>/factory-github issue-view <N> --comments --out issue-<N>.json`, then `jq` |
| An issue's labels | `gh issue view <N> --json labels` | `<bin>/factory-github issue-view <N> --out issue-<N>.json` (field `labels`) |
| List issues | `gh issue list --state <s> --label <l> --limit <n> --json … [--jq …]` | `<bin>/factory-github issue-list --state <s> --label <l> --limit <n> --out issues.json`, then `jq` |
| Milestones | `gh api repos/<repo>/milestones --jq …` | `<bin>/factory-github milestones --out milestones.json`, then `jq` |
| An issue's blockers or dependents | `gh api repos/<repo>/issues/<N>/dependencies/blocked_by` (or `/blocking`) | `<bin>/factory-github issue-deps <N> blocked-by` (or `blocking`) `--out deps-<N>.json` |
| Open an issue | `gh issue create --title … --body-file … --label "a,b" --milestone …` | `<bin>/factory-github issue-create --title … --body-file … --label a --label b --milestone …` |
| Record a blocker | `gh api repos/<repo>/issues/<B> --jq .id`, then `gh api -X POST …/issues/<N>/dependencies/blocked_by -F issue_id=…` | `<bin>/factory-github issue-add-blocker <N> <B>` (root checkout only) |
| Comment on an issue | `gh issue comment <N> --body …` or `--body-file <file>` | `<bin>/factory-github issue-comment <N> --body-file <file>` |
| Change labels | `gh issue edit <N> --add-label … --remove-label …` | `<bin>/factory-github issue-labels <N> --add … --remove …` (root checkout only) |
| Replace an issue's body (the status issue) | `gh issue edit <N> --body-file <file>` | `<bin>/factory-github issue-body <N> --body-file <file>` (root checkout only) |

### Pull requests

| Step | Mode off | Mode on |
| --- | --- | --- |
| Open a PR | `gh pr create --base <default> --title … --body-file … [--draft]` | `<bin>/factory-github pr-create --head <branch> --title … --body-file … [--draft]` (the base is always the default branch) |
| Read a PR | `gh pr view <P> --json …` | `<bin>/factory-github pr-view <P> --out pr-<P>.json`, then `jq`. Among its fields: whether the head is in a fork (`isCrossRepository`) and the head repository's owner and name only (`headRepository.name`, `headRepositoryOwner.login`, as gh gives them; each object may be null). An answer of any other shape is refused |
| A PR's changed files | `gh pr view <P> --json files,changedFiles`, then `jq '.files[].path'`. Complete only when it holds `changedFiles` paths: gh reads the first 100 files, so a longer list is cut short; the rest is read with `gh api --paginate repos/<repo>/pulls/<P>/files --jq '.[].filename'` (`factory verify` does this itself) | `<bin>/factory-github pr-view <P> --out pr-<P>.json`, then `jq '.files[].path'`, compared with `changedFiles` in the same way. No verb lists more than 100 files, so a longer PR cannot be read whole in this mode |
| A PR's comments | `gh pr view <P> --comments`, `gh pr view <P> --json comments --jq …` | `<bin>/factory-github pr-view <P> --comments --out pr-<P>.json`, then `jq` |
| Every review source (formal reviews, inline comments, conversation) | `gh api repos/<repo>/pulls/<P>/reviews`, `…/pulls/<P>/comments`, `…/issues/<P>/comments` | `<bin>/factory-github pr-reviews <P> --out reviews-<P>.json`. Each item has its `id`, `author` (the login alone, or null for a deleted account) and `author_type` (`User`, `Bot`, `Organization`, `Mannequin`, or null for any other), and its times as GitHub gives them: `created_at` and `updated_at` (a comment edited after it was written has a later `updated_at`), or `submitted_at` for a formal review. The broker checks and rebuilds each item; an answer of any other shape is refused |
| A login's permission on the repository (who may write a record that proves, deploy-contract.md rule 2) | `gh api repos/<repo>/collaborators/<login>/permission`; not a collaborator answers HTTP 404 | `<bin>/factory-github permission <login> --out perm-<login>.json`: `login`, `permission` (`admin`, `write`, `read`, `none`, or null for any other) and `role_name` (`admin`, `maintain`, `write`, `triage`, `read`, or null for any other, such as a custom role); not a collaborator reads as `none` |
| List PRs | `gh pr list --state <s> --search "<q>" --json …` | `<bin>/factory-github pr-list --state <s> --search "<q>" --out prs.json`, then `jq` |
| A PR's diff | `gh pr diff <P>` | `<bin>/factory-github pr-diff <P> --out pr-<P>.diff` |
| Check out a PR to review it | `gh pr checkout <P>` | `<bin>/factory-github fetch --pr <P>`; check `git rev-parse origin/pr/<P>` equals `<headRefOid>`; then `git switch --detach <headRefOid>` (the fixed commit, never the ref) |
| Check out a PR's branch to fix it | `gh pr checkout <P>` | `<bin>/factory-github fetch`, then `git switch <headRefName>` and `git merge --ff-only origin/<headRefName>` |
| Read a file at a commit, without a checkout | `gh api -H 'Accept: application/vnd.github.raw' "repos/<repo>/contents/<path>?ref=<ref>"` | `<bin>/factory-github fetch --pr <P>`, then `git show <ref>:<path>` (`origin/<base>` or `<headRefOid>`) |
| A throwaway copy of a PR head | `gh repo clone <repo> … --depth 1`, then `git fetch origin <headRefOid>` and a detached checkout | `<bin>/factory-github fetch --pr <P>`; check `git rev-parse origin/pr/<P>` equals `<headRefOid>`; then `git archive -o <temp folder>.tar <headRefOid>` and `tar -xf <temp folder>.tar -C <temp folder>`, each checked |
| Comment on a PR | `gh pr comment <P> --body-file <file>` | `<bin>/factory-github pr-comment <P> --body-file <file>` |
| Mark ready | `gh pr ready <P>` | `<bin>/factory-github pr-ready <P>` |
| Checks on a PR | `gh pr checks <P> [--json …]` | `<bin>/factory-github pr-checks <P> --out checks-<P>.json` |
| The pull requests merged as a commit (the default branch's tip, merge-gate.md rule 1) | `gh api repos/<repo>/commits/<sha>/pulls` | `<bin>/factory-github commit-pulls <sha> --out pulls.json`: each with `number`, `state`, `title`, `body`, `merged_at`, `merge_commit_sha`, `base.ref` and `head.sha`, and nothing else (no account). `<sha>` is a full commit SHA |
| A commit's tree, as GitHub has it | `gh api repos/<repo>/git/commits/<sha> --jq .tree.sha` | `<bin>/factory-github commit-tree <sha> --out tree.json`: `sha` and `tree` |
| Every check run attempt on a commit | `gh api "repos/<repo>/commits/<sha>/check-runs?filter=all"`, every page, as many as its `total_count` | `<bin>/factory-github commit-check-runs <sha> --out runs.json`: `total_count` and `check_runs` (`id`, `name`, `status`, `conclusion`, `started_at`, `completed_at`, `app.slug`, `check_suite.id`); fewer runs than the count is refused |
| A commit's statuses: every one ever set, and the combined status | `gh api repos/<repo>/commits/<sha>/statuses` and `…/commits/<sha>/status`, every page | `<bin>/factory-github commit-statuses <sha> --out statuses.json`: `history` (`id`, `context`, `state`, `created_at`) and `combined` (`state`, `total_count`, `statuses` with `context` and `state`); fewer statuses than the count is refused |
| Update a PR's branch with the default branch | `gh pr update-branch <P>` | `<bin>/factory-github pr-update-branch <P>` (root checkout only) |
| Merge | `gh pr merge <P> --squash --delete-branch` | `<bin>/factory-github pr-merge <P> --head <headRefOid>` (root checkout only; squash and branch delete are built in; refuses when the head moved) |

### Workflow runs

| Step | Mode off | Mode on |
| --- | --- | --- |
| List runs | `gh run list --workflow <file> --branch <b> --limit <n> --json …` | `<bin>/factory-github run-list --workflow <file> --branch <b> --limit <n> --out runs.json` |
| The latest finished run of a workflow, by its name (`ci.external`, [board.md](board.md#ci-on-the-default-branch)) | `gh run list --workflow <name> --branch <default> --status completed --limit 1 --json databaseId,status,conclusion,headSha,workflowName` | `<bin>/factory-github run-list --branch <default> --limit 200 --out runs.json`, then the first run whose `workflowName` is the name and whose `status` is `completed`: `run-list --workflow` takes a workflow file, not a name. When none of the 200 is one, its latest finished run cannot be told |
| Read a run and its jobs | `gh run view <run> --json …`, `gh api --paginate repos/<repo>/actions/runs/<run>/jobs` (a page holds 30 jobs) | `<bin>/factory-github run-view <run> --out run-<run>.json` (field `jobs`) |
| A run's log | `gh run view <run> --log-failed` (or `--log`) | `<bin>/factory-github run-log <run> --failed --out run-<run>.log` (or without `--failed`) |
| Follow a run to its end | `gh run watch <run> --exit-status` | `<bin>/factory-github run-watch <run>` |
| One job, by its id (merge-gate.md › rule 2, "Refused is not red") | `gh api repos/<repo>/actions/jobs/<job>` | `<bin>/factory-github job-view <job> --out job-<job>.json`: `id`, `status`, `conclusion`, `steps` (how many) and `runner` (whether it has one); or read the job in `run-view` (field `jobs`); when it is not there, the job counts as red |
| A job's annotations | `gh api repos/<repo>/check-runs/<job>/annotations` | no verb: read the job in `run-view` (a job Actions refused has no steps); when that cannot tell it, the job counts as red |
| Re-run a run | `gh run rerun <run> [--failed]` | `<bin>/factory-github run-rerun <run> [--failed]` (root checkout only) |
| Start a workflow | `gh workflow run <file> --ref <b> -f name=value` | `<bin>/factory-github workflow-dispatch <file> --ref <b> --input name=value` (root checkout only; never an approval) |

## Codex children in mode on

A Codex child has no network and no broker at all: it cannot fetch, read or post on GitHub. In mode on, the lead (or
the solo session) does those steps for it. For a review that means: the lead fetches the PR head into the shared
repository before the start and puts what the reviewer would have read from GitHub into the brief; the reviewer
returns its comment as its final message instead of posting it; the lead posts it on the PR. The steps are in the
adapter's "Codex children" and in [briefs.md](briefs.md) › Review.
