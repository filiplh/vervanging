# Headless adapter

Unattended runs: a night hunt, or any other run that needs no person, started by the machine's scheduler while nobody
is at the keyboard. Issue #37, owner's choice of 17 Nov 2026: the adapter runs the CLIs that are **already logged in on
the machine**, `claude -p` (Claude Code's headless mode) and `codex exec`, and macOS's launchd starts them. No GitHub
Actions, no self-hosted runner, no new account, no new secret and no API billing.

Every command the adapter runs is in [`headless/factory-headless`](headless/factory-headless) (the runner, with
`factory-headless.py` next to it) and in this file. Core skills name an operation from [`README.md`](README.md); this
file says how the headless runtime does it, or that it has no such operation.

The runner reuses the core's own tools and restates none of their rules: `factory-pause` (the emergency stop),
`factory-usage` (the reserve and the ledger), `factory lock heavy`, `factory gate`, `factory-settings` (a spec named
by its key of `models`), and factory-doctor's hook check, machine check, secret shapes and redaction.

## The runner

```
factory-headless run JOB [--now] [--urgent]        start a job of ~/.factory/headless.yaml (what launchd calls)
factory-headless start --project DIR --role ROLE --spec SPEC --brief FILE [--name NAME] [--max-turns N]
                       [--timeout-minutes M] [--heavy] [--urgent]
factory-headless result RUN                         a run's report
factory-headless cancel RUN                         stop a running run; it ends with a report
factory-headless runs                               the runs on this machine, newest first
factory-headless plist JOB                          print the launchd job for JOB (you install it: Scheduling)
factory-headless resolve SPEC [--project DIR]       check the CLI and its flags, show the command line; runs no model
```

In a project it is `.factory/runtime/headless/factory-headless`; in the factory repo, `runtime/headless/`. Exit
codes: 0 the run ended with its own report; 1 could not finish (settings, git, a missing tool); 2 the run ended
without its own report (a cap, a usage limit, a failure, a cancel); 3 refused before anything started; 64 bad usage.

Each run's files are under `~/.factory/headless/runs/<run>/`: `run.json`, the brief, the CLI's output (`out.log`,
`err.log`) and `report.md`. Worktrees are under `~/.factory/headless/worktrees/`, the launchd jobs' output under
`~/.factory/headless/logs/`.

## Operations

| Operation | Headless |
| --- | --- |
| `resolve` | `factory-headless resolve`, and again inside every start: the CLI is on `PATH`, its `--help` shows every flag the run uses, the spec maps to a command line ([`start`](#start-one-run-explicit-model-and-effort)). No model runs |
| `start` | [below](#start-one-run-explicit-model-and-effort) |
| `wait` | The runner blocks on the CLI's process until it exits or a cap stops it; nothing polls a thread, and no turn ends early |
| `result` | `factory-headless result <run>`: the report. The child's own final report is on its PR or issue, as in every runtime |
| `cancel` | `factory-headless cancel <run>`: SIGTERM to the run's processes, SIGKILL after `grace_seconds`; the run ends with status `cancelled` and its report. A run whose runner and guard are gone is ended by `cancel` itself |
| `send-report` | The brief ends with [`headless/send-report.txt`](headless/send-report.txt) ([below](#send-report)) |
| `back-off` | [below](#back-off) |
| `night-wake` | The launchd schedule of a job ([Scheduling](#scheduling-night-wake)) |
| `refresh-usage` | At a Claude run's start, when `factory-usage may-start claude` answers 1 (cannot tell), the runner calls `factory-usage refresh claude --model <model id of models.helpers.search>` once (read with `factory-settings`, the project's overrides included), then asks `may-start` once more and starts only on a yes. Never a second refresh in the same start, never a loop: the refresh's own once-an-hour guard (machine-wide) is the only rate limit. A refresh that answers 3 (a limit, or one taken this hour) refuses the start like a no; one that fails (exit 1 or 64, the runner's 150 s timeout, a missing program) or a search helper that is not a Claude model refuses it with the reason. The refresh's exit code and line go into the refusal, or into the run's record and report (`Usage refresh`) when the start goes ahead. Not for Codex (`may-start codex` reads its session logs), and not on a no or a usage error. A finished run's own output is not fed to `observe-claude-stream`: that input is recorded undated, after the run, and the refresh already gives a figure read live |
| `link-pr`, `watch-pr`, `unwatch-pr` | None: there is no thread to show a PR in and no lead to wake. They become **a gate run at the end**: a run whose report names a PR gets `factory gate <P>` (no `--record`), and the verdict goes into the run's report |
| `check-home` | Not needed: a run's worktree is made from a fresh `origin/<default>`, so the root checkout's branch and state never matter and are never touched |
| `read-child` | `factory-headless result` and `runs`, and the run's files |
| `continue`, `notify` | None: a headless run takes no message once started. The emergency stop rests on the run's own checks at its checkpoints and on the hooks, as it does everywhere; a person who wants it stopped now runs `cancel` |
| `watch-run` | None: no lead waits on a CI run |
| `launch-lead`, `relay` | Do not apply: there is no lead thread to hand off |
| `recover-403` | None: a run that dies on a transient error ends as `failed`, with its report; it is not resumed |
| `record` | None: the acceptance demo is the lead's, and no lead runs headless. A lead that finds no `record` says so and the milestone waits |

## `start`: one run, explicit model and effort

### Refusals first

Before anything starts, in this order, the runner refuses (exit 3) and reports why when (before step 1, a start first
ends any run whose runner and guard are both gone: [A runner that dies](#a-runner-that-dies)):

1. the project is not the root of a git checkout, or the role is not a plain name;
2. agent-token mode is not `off` here ([Security](#security));
3. **there is no spec, or it has no effort**, or the provider has no headless CLI (`claude`, `codex`), or the effort is
   not one the CLI takes. A spec is `<provider>/<model>/<effort>` or a key of `models` (`models.agents.hunter`), which
   the runner reads from the project with `factory-settings --json <key>`, so it is the model policy's value with the
   project's overrides, never one written from memory. Nothing is filled in from a parent or a default model;
4. the provider is `codex` and the role is not one that never pushes or merges ([Hooks](#hooks-and-the-gate));
5. **the emergency stop**: `factory-pause status` exits 3 (paused), or exits 1 twice (cannot tell);
6. **the reserve**: `factory-usage may-start <provider>` (with `--urgent` only for a job set `urgent: true`, or
   `--urgent` given) answers 3 (no) or 1 (cannot tell); for Claude, a "cannot tell" first gets one usage refresh and
   a second `may-start` (`refresh-usage` in the table above);
7. the CLI is not on `PATH`, or its `--help` lacks a flag the run uses (a changed CLI version: nothing guesses), or
   `gh` is not on `PATH`;
8. **the concurrency cap** is reached ([Caps](#caps));
9. the job's hunt area is already being hunted by another headless run (one hunter per area);
10. `origin/<default>` has no `factory.yaml`, or, for a Claude run, the factory's hooks are not wired there
    (factory-doctor's hook check on the new worktree);
11. the usage ledger does not record the start.

The emergency stop and the reserve come before the first call of the CLI, its `--help` included: a paused or
refused start never runs the CLI at all. (The usage refresh is `factory-usage`'s own one-line prompt, not the run:
it writes no ledger start and holds no slot.) A refusal starts no CLI and writes no ledger start. It is reported like every run: printed, in `report.md`, and on the
status issue. A step before the start that cannot finish (`git fetch` fails, the machine settings are not valid) ends
the same way, with status `error: …` and exit 1.

### The worktree, the ledger, the call

1. `git fetch origin` in the project, then `git worktree add --detach ~/.factory/headless/worktrees/<run>
   origin/<default>` (the default branch from `refs/remotes/origin/HEAD`, else `gh repo view`), then `git worktree lock
   --reason "factory-headless run <run>"` on it while the run lives, so `factory gc` never takes a live run's
   worktree. A builder makes its own branch there, as `factory-implement` says.
2. The brief: a job's brief ([Jobs](#jobs)) followed by `send-report.txt`, written to the run's folder and given to
   the CLI on standard input. A brief that holds something shaped like a credential is refused.
3. The run's merge denial ([Hooks](#hooks-and-the-gate)): `headless-settings.json` and a `bin/gh` in the run's folder.
4. `factory-usage start --spec <spec> --project <repo name> --role <role>`; its id goes into the report.
5. The CLI runs in the worktree, in a process group of its own, under `factory lock heavy --` when the job is
   `heavy: true`. The runner and its guard hold the concurrency slot; the CLI does not
   ([A runner that dies](#a-runner-that-dies)).
6. When the CLI ends (or a cap or a cancel stops it): `factory-usage end <id>` at once, then the result, the gate for a
   reported PR, the worktree clean-up and the report. The worktree's lock is released; a worktree with uncommitted
   work, or commits on no remote branch, is kept and the report names it; otherwise it is removed.

   A stop that comes before the runner waits on the CLI (a signal, or an error in a write or the guard's fork, in the
   milliseconds after the CLI started) stops the CLI's process tree all the same, in a `finally`, and ends the run with
   status `stopped by signal <n>` or `error: …`, so nothing runs on without a cap or a slot.

**Finished worktrees and `factory gc`.** A kept worktree is an ordinary, unlocked worktree of the project, outside its
folder: `factory gc` judges it by its own rules, as any other (`factory gc --apply --remove-worktrees` moves it into
quarantine once its PR is merged or closed and it is clean, with no commit outside GitHub). Uncommitted work, or
commits on no remote branch, are never eligible: those stay for a person. A hunter's clean worktree at
`origin/<default>` is removed by the runner itself.

**Claude** (Claude Code 2.1.322):

```
claude -p --model <model id> --effort <effort> --max-turns <max_turns>
       --output-format stream-json --verbose --include-hook-events
       --setting-sources user,project,local --settings <run>/headless-settings.json --permission-prompts none
       [--permission-mode <claude_permission_mode>]
```

**Codex** (codex-cli 0.167.0):

```
codex exec --model <model id> --config model_reasoning_effort="<effort>" --cd <worktree>
           --json --output-last-message <run>/last-message.md [--sandbox <codex_sandbox>] -
```

The flags, from `claude --help` and `codex exec --help` on this machine, 17 Nov 2026:

| Need | Claude | Codex |
| --- | --- | --- |
| Non-interactive | `-p, --print  Print response and exit (useful for pipes)` | `exec  Run Codex non-interactively` |
| Model | `--model <model>  Model for the current session` | `-m, --model <MODEL>  Model the agent should use` |
| Effort | `--effort <level>  Effort level for the current session (low, medium, high, xhigh, max)` | `-c, --config <key=value>  Override a configuration value`, key `model_reasoning_effort` (efforts read from the CLI: minimal, low, medium, high, xhigh, max, ultra) |
| Turn limit | `--max-turns <turns>`: a hidden option, not in `--help`; `claude --max-turns abc -v` answers `option '--max-turns <turns>' argument 'abc' is invalid. must be a number`, which shows it exists | none |
| Output | `--output-format <format>  "text" (default), "json" (single result), or "stream-json"`; `--include-hook-events  Include all hook lifecycle events in the output stream (only works with --output-format=stream-json)` | `--json  Print events to stdout as JSONL`; `-o, --output-last-message <FILE>` |
| Working folder | none: the process's own folder | `-C, --cd <DIR>  Tell the agent to use the specified directory as its working root` |
| Settings and hooks | `--setting-sources <sources>  Comma-separated list of setting sources to load (user, project, local)`; `--settings <file-or-json>  Path to a settings JSON file or a JSON string to load additional settings from` | — |
| Prompts | `--permission-prompts <target>  "none" (nobody: anything that would prompt is denied automatically)` | `exec` asks nobody |
| Brief on stdin | `-p` reads a piped prompt | `If not provided as an argument (or if - is used), instructions are read from stdin` |

Never passed: `--bare` ("skip hooks"), `--safe-mode`, `--restricted` (both drop the project's settings, hooks
included), `--fallback-model` (a silent model switch), `--dangerously-skip-permissions` and Codex's
`--dangerously-bypass-*`.

**The CLI's environment**, for every call of the CLI (the `--help` probes of `start` and `resolve` too), is the
runner's minus every variable whose name looks like a credential (`*TOKEN*`, `*SECRET*`, `*PASSW*`, `*API_KEY*` and
the like). The run itself also gets the run's `bin` folder first on `PATH` (its `gh`), `FACTORY_HEADLESS_GH` (the real
`gh`, for that shim) and `FACTORY_TEST_WORKERS` from the machine's `limits.test_workers`. So the CLIs, `gh` and `git` use their own stored logins, and an `ANTHROPIC_API_KEY` in a shell
can never switch a run to API billing.

**The model that ran.** For Claude the result lists the models used (`modelUsage`); when the model asked for is not
among them, the report warns of a silent switch. Codex reports no model per run.

## Caps

Each cap has a default in [`headless/defaults.yaml`](headless/defaults.yaml) and a setting ([Settings](#settings)). A
cap that fires ends the run with its status in the report, printed, in `report.md` and on the status issue, and exit
2 (or 3 for a refusal): never silently.

| Cap | Default | How | Status |
| --- | --- | --- | --- |
| Turns | `max_turns: 200` | Claude's own `--max-turns`; the result says `error_max_turns`. Codex has no turn limit, so a Codex run is held by the time cap alone, and its report says so | `cap: turns` |
| Wall-clock time | `timeout_minutes: 120` | The runner waits at most this long, then sends SIGTERM to the run's process group and to every process group below it (a command the agent started in a group of its own), and SIGKILL to what is left after `grace_seconds` (30) | `cap: time` |
| Concurrency | `concurrency: 1` | At most this many headless runs at once on the machine, per pool (`reviewers` for the reviewer role, `builders` for every other), and never more than the machine's `limits.builders` or `limits.reviewers`: one lock file per slot under `~/.factory/headless/slots/`. A start that finds every slot taken is refused, not queued | `refused: cap: concurrency` |
| Heavy | `machine.limits.heavy` | A job with `heavy: true` runs under `factory lock heavy --`, which waits for one of the machine's heavy slots. Inside any run, heavy commands go through `factory lock heavy`, as the skills say | — |

### A runner that dies

The time cap and the slot must hold even when the runner itself is killed (SIGKILL, a crash), so each run has a
**guard**: a process the runner forks right after the CLI starts, in a session of its own, which holds the slot too and
waits on a pipe from the runner (no polling). The runner writes `ok` on it when it is done. When the pipe ends without
it, the runner died, and the guard ends the run at once: SIGTERM to the CLI's process group and every group below it,
SIGKILL after `grace_seconds`, `factory-usage end`, the worktree kept or removed, and the report (status `stopped: the
runner died`), printed and posted. The slot frees when both the runner and the guard are gone, never while either
holds it, and the CLI never holds it.

When the runner and the guard are both killed, the CLI runs on unsupervised. The next start (and `factory-headless
cancel <run>`) ends such a run before anything else: it checks that the recorded process ids are still the runner's,
the guard's and the CLI's (a reused id is left alone), then ends it the same way, with status `stopped: its runner and
guard died; ended by a later start`. A lock in the run's folder makes sure only one of them ends it.

### The machine caps

Heavy slots are shared: a `heavy: true` job and every heavy command inside a run go through `factory lock heavy`, the
same slots interactive leads use. **Builder and reviewer slots stay apart**, on purpose, and there is no `factory lock
builders|reviewers`. Such a lock holds a slot for as long as a command runs, which fits the headless runner (it waits on
the CLI's process), but an interactive lead's child is not a process the lead runs or waits on: it is a runtime thread
that outlives the lead's turn, so the lead has nothing to hold the slot around, and a lock it took would free at the end
of the turn or never. Interactive leads count their children themselves (the lead skill, against `limits.builders` and
`limits.reviewers`), so a shared lock would bind only the headless side and change nothing for them. What keeps the two
apart instead: the headless `concurrency` (default 1) never above the machine's `limits.builders` or
`limits.reviewers`, and the night window (a job's `window`, or `shifts.night`), when no interactive lead runs. Sharing
the count for real needs the lead to read the headless runs in flight (`factory-headless runs`) when it counts, a
change to the lead skill, not to this adapter.

## Hooks and the gate

**The hooks load in headless mode.** Claude Code runs the hooks of the settings files it loads, in `-p` mode too:
`--bare` is documented as the mode that "skip[s] hooks (those defined in settings and by installed plugins)", and the
runner never passes it. The factory's hooks are wired in the project's `.claude/settings.json` (factory-install does
that), and the runner loads it explicitly with `--setting-sources user,project,local`; `-p` skips the workspace trust
dialog ("The workspace trust dialog is skipped when Claude is run in non-interactive mode"), so the project's hooks run
without a person. Three guards make it visible:

1. **Before the start**, factory-doctor's hook check must pass on the run's worktree, or the run is refused. This
   matters because "Settings files that fail validation are silently ignored in this mode": a broken settings file
   would otherwise drop the hooks without a word.
2. **During the run**, `--include-hook-events` puts every hook event in the output, kept in `out.log`, and the report
   counts them ("Hook events").
3. **After the run**, a run that called tools while the output shows no hook event gets a warning in its report.

Unconfirmed: the exact shape of a hook event in the stream (the runner counts `system` messages whose subtype starts
with `hook`). To see it once on this machine, the owner can run, in a worktree of a factory project,
`claude -p --model claude-haiku-5-5 --effort low --max-turns 2 --output-format stream-json --verbose
--include-hook-events "Run: git push origin HEAD:main"` and look for the PreToolUse hook's block in the output. Adding `--settings <a run's headless-settings.json>` and the prompt
`"Run: gh pr merge 1"` shows the merge guard's denial beside the project's hook.

**Codex** runs without the factory's Claude Code hooks, exactly as a Codex child does in an interactive session. That
is why it runs only roles that never push or merge: `reviewer`, `validator`, `hunter`, `process_hunter`,
`domain_hunter`.

**Nothing merges headless, whatever the gate says.** The runner never merges, and a run is told not to and is stopped
when it tries by mistake: besides the brief's rule, the runner installs [`headless/merge-guard.py`](headless/merge-guard.py)
for each run, in two places that hold whether `factory gate` passes or fails (its limit is below):

1. **A PreToolUse hook added with `--settings`** (the run's `headless-settings.json`). Claude Code adds it to the hooks
   of the user's, the project's and the local settings, which still load (`--setting-sources user,project,local`), so
   the core's own hook keeps every rule it has. The guard denies (exit 2) a Bash command that names a GitHub client
   (`gh`, `factory-github`, `hub`, `curl`, `wget`, `api.github.com`) and a merge (`merge` as a word, `pr-merge`,
   `/merges`, `mergePullRequest`, `enablePullRequestAutoMerge`, `mergeBranch`, `auto-merge`), after removing quotes
   and backslashes; any tool whose name holds `merge` (an MCP server's merge tool); and any call it cannot read.
2. **A `gh` first on the run's `PATH`** (`<run>/bin/gh`), for Claude and Codex alike: it refuses the same merge words in
   its arguments and runs the real `gh` for everything else.

It refuses more than it must, on purpose: a `gh` command whose text holds the word `merge` anywhere (`--body "merge
it"`) is refused too, so bodies go in `--body-file`; `git merge` on its own passes.

**Its limit.** Like the core's hooks ([hooks/README.md](../hooks/README.md), "The hooks guard against an
agent's mistakes"), the guard is a **word match** over a command's text and arguments: it guards against mistakes, not
against an agent that sets out to get around it. A merge whose words are not in the command gets past both places: a
mutation read from a file (`gh api graphql -F query=@file`, the query written earlier), an absolute path to the real
`gh`, or code that calls the API itself. Nothing in the headless runtime claims more. Unconfirmed: that Claude Code adds `--settings` hooks to the project's hooks rather than replacing them
(the runner's tests show both answering through a stub CLI); the live proof below shows both on the real CLI. A PR a run reports gets `factory gate
<P>` (judging only, no `--record`), run from the project's root checkout as a lead runs it, and the verdict waits in
the report for the morning. A PR that waits on a human gate
fails the gate (`status:needs-human`), and a person merges, as by day.

## `send-report`

Every brief ends with [`headless/send-report.txt`](headless/send-report.txt). It is T3's block with three changes,
because nothing wakes a headless run and nobody answers it:

- run every command in the foreground: a background run ends with the run, and its result reaches nobody;
- never wait for input: a question goes into the report, or into the question issue the role's skill describes;
- a run that opened no PR ends with `No PR` instead of the PR line, and a hunter posts on the status issue.

The runner posts its own short report on the status issue for every run (`report: status-issue`): the status, the
caps, the ledger id, the worktree, the gate's verdict, and, when the run did not end with its own report, the run's
final message. `report: none` keeps it to the local files.

## `back-off`

A run that stops on a usage limit (its output says "usage limit", "rate limit", "limit reached" or "429") ends with
status `limit`. The runner then:

- reads when the limit resets from the CLI's own JSON output, never from its message text: for Claude, the last
  `rate_limit_event` whose `rate_limit_info.status` is `rejected`, its `resetsAt`; for Codex, the last event with
  `rate_limits` where a window's `used_percent` is 100 or more, its `resets_at` (the latest of those windows). Both are
  Unix seconds; only a time after now and at most 8 days ahead is believed;
- records it in the usage ledger with `factory-usage limit <provider> [--reset <time>]`, so every lead on the machine
  sees it: with a reset, `factory-usage may-start` refuses every start on that provider, urgent ones too, until it
  passes; the report gives the reset, or says it was not in the output;
- halves the headless concurrency cap on that provider (at least 1) for one hour.

It never changes a model, an effort or a tier. Unconfirmed: the CLIs' exact limit messages and the fields above on a
real limit (Claude's are the Agent SDK's documented `rate_limit_event`; Codex's are the `rate_limits` of its session
logs, which `factory-usage observe-codex` reads, assumed in `codex exec --json` too). When they are missing, the
ledger record carries no reset, as before.

## Scheduling (`night-wake`)

A job with a `window` is started by launchd at the window's start, or at its `at` time (inside the window), in the
machine's local time, so daylight saving time follows the clock. The runner renders the launchd job; **you install and
remove it**, the agent never does:

```
# install (once per job)
<project>/.factory/runtime/headless/factory-headless plist <job> > ~/Library/LaunchAgents/"local.factory-headless.<job>.plist"
plutil -lint ~/Library/LaunchAgents/"local.factory-headless.<job>.plist"
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/"local.factory-headless.<job>.plist"

# try the job once now, outside its window and schedule
<project>/.factory/runtime/headless/factory-headless run <job> --now

# remove
launchctl bootout gui/$(id -u)/local.factory-headless.<job>
rm ~/Library/LaunchAgents/"local.factory-headless.<job>.plist"
```

- **What it runs:** `/bin/sh <the runner> run <job>`, from the project's root checkout, with `PATH` set to the folders
  where `claude`, `codex`, `gh`, `git` and `python3` were found when you rendered it, and `HOME`. Render it again after
  moving a CLI.
- **Sleep:** launchd starts a job that was due while the machine slept "the next time the computer wakes up"
  (`man launchd.plist`). `run` refuses outside the job's window, so a morning wake starts nothing; the refusal is
  reported.
- **Stopping:** `bootout` sends SIGTERM, which ends the run with its report (status `stopped by signal 15`); the
  job's `ExitTimeOut` is `grace_seconds` + 60, so launchd waits for that.
- **Logged in:** a `gui/<uid>` job runs while you are logged in (the screen may be locked). Unconfirmed: whether the
  CLIs reach their stored logins (the keychain) when you are logged out; keep the machine logged in.
- **The night window.** A job without a `window` of its own takes the machine settings' `shifts.night`
  (`~/.factory/machine.yaml`, checked by `factory doctor`; `docs/factory-yaml.md` › Shifts in the factory repo): `run`
  refuses outside it and `plist` starts the job at its start. A job's own `window` wins; with neither, the job is run by
  hand only. The launchd job holds the start time it was rendered with, so render it again after changing
  `shifts.night`.
- The rules at night are the day's: the emergency stop, the reserve, the caps and every gate. A human gate found at
  night waits for the morning.

## Jobs

A **hunt** job (`kind: hunt`, the default) starts one hunter of the `factory-hunt` skill. The runner writes its brief
from [`headless/hunt-brief.txt`](headless/hunt-brief.txt): the area, the depth level, the time box (the time cap less an
eighth of it, or less 5 minutes when that is more), the `main` SHA (the worktree's `origin/<default>`), the areas other headless runs hunt
at the same time, and the hunter's limits. Its role is `hunter` (`process_hunter` for the `process` area), and its spec
defaults to the model policy's key for that role (`models.agents.hunter`, `models.agents.process_hunter`); set `spec:
models.agents.domain_hunter` for a domain area. Which area to hunt and how deep is your choice in the job: the lead's
rotation (`factory-hunt` › Areas) is not automated here.

A **brief** job (`kind: brief`) runs any other unattended work from a brief file you wrote, with the role and spec you
name; the runner appends `send-report.txt`.

## Settings

`~/.factory/headless.yaml`, one file per machine, outside every repo, edited by hand, opened like the machine settings
(a real file of yours that nobody else can write, no symbolic link). Missing: the defaults apply and there are no jobs.
A value shaped like a credential, an unknown key or a value out of range refuses the whole file.

```yaml
# ~/.factory/headless.yaml: no secrets in this file
defaults:                      # over headless/defaults.yaml, for every job
  timeout_minutes: 150
jobs:
  night-hunt-api:              # lower-case letters, digits and dashes
    project: /path/to/the/project/root/checkout
    kind: hunt
    area: api                  # a hunter area's slug
    depth: 1
    window: "01:00-06:00"      # local time; launchd starts the job at its start
    at: "01:30"                # optional, inside the window: start here instead
    max_turns: 150             # any cap or default may be set per job
```

| Key | Where | Default | What |
| --- | --- | --- | --- |
| `max_turns` | defaults, job | `200` | Turns per Claude run, 1–1000 |
| `timeout_minutes` | defaults, job | `120` | Wall-clock time per run, above 0, at most 720 |
| `concurrency` | defaults, job | `1` | Headless runs at once per pool, 1–6, and never above the machine cap |
| `grace_seconds` | defaults, job | `30` | SIGTERM to SIGKILL, 1–300 |
| `report` | defaults, job | `status-issue` | `status-issue` or `none` |
| `claude_permission_mode` | defaults, job | `""` | Empty: the permission mode in your Claude Code settings, as in your interactive sessions. Else one of `claude --permission-mode`'s choices |
| `codex_sandbox` | defaults, job | `""` | Empty: the sandbox in your Codex config. Else `read-only`, `workspace-write` or `danger-full-access` |
| `project` | job | required | The absolute path of the project's root checkout |
| `kind` | job | `hunt` | `hunt` or `brief` |
| `area`, `depth` | hunt job | area required, depth `1` | The hunter area's slug, its depth level 1–9 |
| `brief`, `role` | brief job | required | The absolute path of the brief file, and the role |
| `spec` | job | the role's key for a hunt | `<provider>/<model>/<effort>`, or a key of `models` |
| `window`, `at` | job | `shifts.night` | `"HH:MM-HH:MM"` and `"HH:MM"`, local time; `at` only with the job's own `window`. Without a window the job takes the machine's `shifts.night`; with neither it is run by hand only |
| `heavy` | job | `false` | Run under `factory lock heavy` |
| `urgent` | job | `false` | `may-start --urgent`: only for work the reserve lets through (the usage reserve's list) |

## Security

- **No secrets** in a settings file, a brief, a prompt, a log or a report: the settings file and briefs are checked
  for credential shapes, everything printed passes factory-doctor's redaction, and the CLI's environment leaves out
  credential-named variables. The runner never reads, asks for or prints a credential; it never runs `gh auth`, `git
  credential` or a keychain query.
- **Agent-token mode** (`docs/agent-tokens.md`) must be `off`: the runner refuses otherwise. A headless run in that
  mode, with the broker and its sandbox checks, is a follow-up.
- **Permissions** are your CLIs' own settings unless `claude_permission_mode` or `codex_sandbox` say otherwise. With
  `--permission-prompts none`, anything that would ask is denied, so a run never hangs on a prompt.

## What was verified

On 17 Nov 2026, on the owner's Mac, with Claude Code 2.1.322 and codex-cli 0.167.0:

- every flag in the table above, read from `claude --help` and `codex exec --help` (no model ran); `--max-turns` with
  the invalid-argument answer quoted there; `factory-headless resolve` passes on both CLIs;
- the runner, end to end, with stub `claude`, `codex` and `gh` binaries and the core's real `factory-pause`,
  `factory-usage` and `factory lock heavy` (`runtime/headless/factory-headless.test.sh` in the factory repo):
  refusals (no CLI call, its help included, while paused or refused), the filtered environment of every CLI call,
  each cap, the pause, the reserve, the ledger, the gate, the merge denial (the gate passing and failing), a killed
  runner (its guard ends the run) and a killed runner and guard (the next start ends the run), a signal or an error
  between the CLI's start and the wait (the CLI is stopped), the worktree lock while a run lives, the reset of a usage
  limit read into the ledger (Claude and Codex stubs), a job taking `shifts.night`, the report, cancel, the launchd job;
- `core/bin/factory-gc.test.sh`: a worktree made as the runner makes it, outside the repository, is kept while locked
  and moved into quarantine once unlocked with its PR merged.

Not exercised with a real model, and marked "Unconfirmed" above: the stream's hook-event shape, how Claude Code
combines `--settings` hooks with the project's, the CLIs' usage-limit messages and the reset fields on a real limit, and the keychain while logged out. The `result` message fields the runner reads (`subtype`,
`error_max_turns`, `num_turns`, `session_id`, `modelUsage`) are Claude Code's documented headless output, not observed
here.
