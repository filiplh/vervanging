# Security

Decision 17 and the plan's "Least privilege", with the user's choice of 15 Nov 2026 ("own account for now", to be
recorded as decision 31). Agents get least privilege through **agent-token mode**: sandboxed agents that never hold
a GitHub credential. Each project has one fine-grained token for its repository, on the user's own account, which only
`factory-github`, a broker installed on the machine, ever reads. The person's steps are in the factory repo's
`docs/agent-tokens.md`; the files and every rule are in `core/templates/agent-tokens/README.md`. Facts checked on
15 Nov 2026 (table at the end of this section).

## The switch: off by default, and held by the machine

Agent-token mode is **opt-in per project, and off unless a person switched it on.** A default `factory-init` installs
nothing of it. The switch is the project's entry in the machine's own list, `~/.factory/github.json`, outside every
repository, which only a person can write. No file in a repository switches the mode on or off.

- **How to tell.** The lead or solo session asks the broker, from its root checkout:

  ```sh
  if [ -x "$HOME/.factory/bin/factory-github" ]; then "$HOME/.factory/bin/factory-github" mode; else echo off; fi
  ```

  `mode` needs no token and also answers inside the sandbox. It reads the machine list first. For a staged or enabled
  project it then parses the checkout's settings as JSON (it never searches them as text) and checks the isolation
  record.

| Answer | What the lead does |
| --- | --- |
| `off` (not listed, listed as off, or no broker on this machine) | Everything works as before this section existed: agents use the user's gh login, there is no preflight, and nothing here halts the lead or a solo session. This is the default, for this repo and every project until its person switches it. |
| `staged` | The protective settings are installed but not verified. **Start nothing**, except the isolation probe when the user asks for it. |
| `on` | Run the preflight below before every child start. |
| anything else: `blocked: …`, an error, no answer | **Start nothing.** Tell the user the reason the broker gave. |

`blocked` covers every doubt about an enabled or staged project:
- its settings are missing, unreadable, not valid JSON, or lack one of the mode's switches (a project edit that tries
  to switch the mode off);
- a local settings file overrides a switch;
- there is no isolation record;
- the record is not for exactly these settings.

A project whose settings carry the placeholder while the machine says off stays `off`, with a warning: a project edit
cannot switch the mode on.

The broker enforces the same rule on every call: its verbs work only for a project that is `on`, with consistent
settings and a matching record. A child in a blocked or staged project cannot reach GitHub at all.

Everything below applies only when the mode is on or staged.

## Who holds which credential

| Who | Credential in its shell | How it reaches GitHub | Sandbox |
| --- | --- | --- | --- |
| The lead, a solo session | none: `GH_TOKEN` is the placeholder | `factory-github`, as the project's agent | the project's Claude settings, in the root checkout |
| A Claude child | none | `factory-github` | the same settings, in its worktree |
| A Codex child | none | it does not: no network; the lead posts its report | the project's Codex `factory-child` profile |
| The user | the user's own login, kept out of the sandbox's reach (guide, step 6) | GitHub, or the user's own terminal | none |

Agent and user share one GitHub identity (decision 31): GitHub cannot tell their actions apart, so no approval may come
out of an agent's session (see [what stays with the user](#what-stays-with-the-user)).

## Why a broker with fixed operations

- **T3 cannot give a project's threads their own environment.** No T3 tool sets an environment variable: projects
  hold a title, a workspace root, scripts and defaults; `delegate_task` and `t3_thread_launch` take a model, modes
  and a task; environment preferences hold none.
- **A token in a shell's environment is a token in every command**, every dependency, and every environment dump that
  lands in a transcript.
- **A pass-through to gh cannot be made safe.** gh's `--jq` runs inside the process that holds the token and can read
  its environment. JSON payloads hide words from substring checks. Raw API paths reach Contents and refs writes and
  other repositories. So the broker offers a fixed list of operations and builds every command itself, from validated
  values and the registered repository. No caller expression, path or payload runs where the token is.
- Never collect a token through the runtime, `request_secret` included: a value given that way reaches an agent.
  Point the user at the guide.

## Preflight: before every child start

From the root checkout, with the mode `on`:

1. **The settings are in force.** Run `[ "$GH_TOKEN" = factory-no-agent-token ] && echo placeholder || echo none`, and
   never print the variable itself. `none` means the mode is on but its settings are not loaded, so the shell might act
   as the user.
2. **The broker's check passes.** `<bin>/factory-github check` must print `ok: <owner>/<repo> is on; …`. Besides the
   rules of every verb (mode on, settings consistent, record for these settings), it checks:
   - the Claude Code and Codex versions in use equal the record's (the broker asks both tools itself);
   - the user's own settings still lock the sandbox (`strictAllowlist`, no unsandboxed retry, no excluded command
     outside the install folder);
   - the agent token reaches the repository;
   - the calling shell holds the placeholder.

   A refusal names which.
3. **T3's version.** The broker cannot ask T3. Compare the T3 version `check` printed with T3's `serverVersion`
   (`t3_environment_read`). A difference means isolation is unverified for what runs now.

**Any failure, unknown or doubt in these three starts nothing at all**: no builder, reviewer, hunter or helper, not
only deploys. Tell the user in one line which step failed and that the isolation probe must be run and recorded
again (guide, steps 8 and 9). Children already running finish their turn; no new one starts.

**The one exception is the isolation probe**, in a project that is `staged` or `on`, started only when the user asks
for it in the session and says the control passed (guide, step 8). It is one Claude child and, when Codex children
will be used, one Codex child, each with `isolation: "worktree"`. The brief is exactly: "Run
`sh <home>/.factory/bin/factory-isolation-check claude` (or `codex`) from your worktree and end your turn with its
whole output, verbatim. Do nothing else." The user reads the output in the child's own thread; the lead only names
the thread. The lead never runs `control` or `record`, and never writes anything under `~/.factory/isolation`: those
are the user's own commands in the user's own terminal.

A `401` or a broker refusal in mid-run is not transient: no retry. Start nothing more in that project and tell the
user. Resume with `continue` once the preflight passes again.

## What the isolation check proves, and what it does not

The check uses synthetic canaries only. It never touches a real credential.

- **The control** (`factory-isolation-check control`, the user's own terminal, outside every sandbox) puts a canary
  file at each place credentials live and a canary item in the keychain. It proves each probe **succeeds** without a
  sandbox. Its stamp is good for one hour.
- **The probe** (inside a real child's sandbox) runs the same probes and counts only **the sandbox's own refusal** as
  a pass. A reachable canary is a FAIL. Anything else is INDETERMINATE and fails the probe: a missing tool, exit 126
  or 127, a transport error, an unknown message.
- **The record** (`record`, the user, in the project's root checkout) ties the result to the digest of the project's
  `.claude/settings.json` and `.codex/config.toml`, and to the Claude Code, Codex and T3 versions.

A pass proves, **for this project's settings, on this machine, with those versions**:

- the child got the project's settings (the placeholder), so T3 loads them for its children;
- no variable whose name looks like a credential reached the child's shell (the name filter is tried on a synthetic
  name first);
- the canary files in `~/.config/gh` (where gh's file login lives), `~/.ssh`, the home folder (where
  `.git-credentials` and `.netrc` live) and `~/Library/Keychains` cannot be read by their exact path, although the
  control just read them;
- the canary item cannot be found in the keychain with `security`, although the control just found it;
- nothing can be written in the home folder, `~/.factory` or its `bin`, nor in `acceptance/`, `.factory/hooks/`,
  `.codex/` or the project's settings files, although the same write works in the worktree;
- in a Claude child, the allowed host answers and a host off the list is refused by the proxy; in a Codex child no
  host can be reached, although the control reached both;
- the broker refuses a call from inside the sandbox.

It does **not** prove:

- that every other way to a credential is closed: another program using the keychain differently than `security`, a
  credential store the check does not name, or a credential file in a place without a canary;
- that the user's own gh login is out of reach **by gh's own lookup**. The check no longer asks gh, because a blocked
  network would make that fail for the wrong reason. It rests on the two places gh keeps a login (the keychain, and
  `~/.config/gh`) being out of reach;
- that the refusal messages for the keychain and the proxy are the ones a real sandbox gives. They come from the
  tools' documentation. An INDETERMINATE result there needs a factory change, never a recorded pass;
- for a Codex child, that the network stayed blocked by the sandbox and not by an outage in the hour since the
  control;
- how Claude Code treats a broker call with a leading variable assignment. The broker refuses to run in the sandbox
  and ignores the caller's environment either way;
- anything after a change: a new version of Claude Code, Codex or T3, or any edit of the project's settings, voids
  the record. The broker checks the first two and the settings itself, the lead T3;
- that a credential with a name and a value that look harmless is absent;
- that the child ran the check honestly. The probe child is an agent. The user reads its output in its own thread and
  decides;
- anything about the processes outside the sandbox (T3 itself, MCP servers, hooks).

## The user's own GitHub login

The user's own gh login (and any GitHub password git keeps) is the real prize: it reaches every repository. Before
switching the mode on, the user puts it where no sandboxed command can reach it (gate H3, guide step 6). It may stay
in the keychain only if the isolation probe's keychain check passes. Otherwise:
- gh's login moves to `~/.config/gh/hosts.yml` (`gh auth login --insecure-storage`), which the read block keeps out
  of every sandboxed command; the probe's canary file in that folder checks it;
- git's stored GitHub passwords leave the keychain, and git asks gh (`gh auth setup-git`).

The strongest option, a separate macOS user for the factory with no personal login at all, is deferred.

## How agents call the broker

`<bin>` is the absolute path of `~/.factory/bin` on this machine. The lead reads it once per session
(`echo "$HOME/.factory/bin"`; not a secret) and writes it out literally in every brief: Claude Code lets a command out
of the sandbox only when its text matches the excluded entry.

```
<bin>/factory-github issue-view 12 --out issue.json        # prints "wrote <path>"; then jq on that path
<bin>/factory-github pr-comment 34 --body-file report.md   # a file in the worktree or the session temp folder
<bin>/factory-github fetch --pr 34                         # the PR head as origin/pr/34
<bin>/factory-github push feat/12-thing --lease            # never the default branch
<bin>/factory-github pr-merge 34 --head <40-char SHA>      # root checkout only, after the merge gate passed
```

- A plain command only: no `cd`, pipe, redirect, `$(…)` or variable assignment. Otherwise the call stays sandboxed and
  the broker stops with "running inside the sandbox".
- `--out` takes a bare file name, never a path. The broker writes the file into its own export folder for this
  checkout, under the session temp folder, and prints where it is. Nothing is ever written into a checkout. The name
  must be new there; remove old exports with `rm`.
- `<bin>/factory-github mode` tells the mode (above); `check` is the preflight. `state` is for the user's `record`.
- `factory-github help` lists the verbs; `core/templates/agent-tokens/README.md` groups them. Reviews are posted as
  comments; there is no approval, review or `pr checkout` verb. A PR is checked out with `fetch --pr <P>`, a check that
  `git rev-parse origin/pr/<P>` equals the PR's `headRefOid`, and `git switch --detach <headRefOid>`: the fixed commit,
  never the ref, which a later fetch can move.
- The lead's `git pull --ff-only` becomes `<bin>/factory-github fetch`, then `git merge --ff-only origin/<default>`.
- **Root-checkout verbs** (`pr-merge`, `pr-update-branch`, `issue-labels`, `issue-body`, `issue-add-blocker`,
  `run-rerun`, `workflow-dispatch`) refuse in a worktree. So in this mode every child starts with
  `isolation: "worktree"`; a `"shared"` child would run in the root checkout.
- **Every brief carries a "GitHub access" block** that says: plain `gh` and `git push` fail by design; use the broker
  as above, with `<bin>` written out; read each `gh` and `git` step of the skills through
  `.factory/reference/github-access.md`; first run the placeholder check, and if it says `none`, stop and report.
  Where that page and this block disagree, this block wins. A Codex child gets no such block: it has no broker (see
  below).

## Codex children

A Codex child runs with the project's `factory-child` profile: no network, no credential, credential-looking variables
dropped, writes only in its worktree, and `.git`, `.agents`, `.claude`, `.codex`, `.factory/hooks` and `acceptance/`
read-only. It cannot read or post on GitHub, so:

- **Start.** Before starting a Codex reviewer, the lead runs `<bin>/factory-github fetch --pr <P>` in the root
  checkout, which puts the PR head into the shared repository as `origin/pr/<P>`, checks that `git rev-parse
  origin/pr/<P>` equals the PR's `headRefOid` (otherwise it fetches again or stops), and fixes the base commit with
  `git merge-base`. It reads what the reviewer would have read from GitHub through the broker (`pr-view --comments`,
  `pr-reviews`, `pr-checks`, `issue-view --comments`, the changed files), each with the head SHA it is about, and
  starts the child with the review brief's mode-on variant (`.factory/reference/briefs.md` › Codex
  reviewer when the mode is on). That brief points the child at that commit, has it run the checks on a
  `git archive` copy of it, and has it end with the whole review comment as its final message instead of posting.
- **Report.** On the completion, the lead takes the comment from `result` (the child's final message) and:
  1. runs the pause check (the lead's or solo skill's Emergency stop) where the reviewer would have, right before
     posting; while paused it posts nothing and keeps the text for the resume (a lead that lost it starts the
     review again);
  2. checks that the marker line's `head=` is the `headRefOid` it fetched. A comment with no marker line, or a
     marker for another head, is not posted: the review counts as not done and starts again;
  3. writes the comment to a file and posts it with `<bin>/factory-github pr-comment <P> --body-file <file>`,
     verbatim, with one last line added after the child's text, below an empty line:
     `🤖 Lead: review by <executedModel> (Codex, no network), posted by the lead` (`🤖 Solo:` in a solo session).
     When the runtime reports no executed model (`executedModel: null`), write the requested spec followed by
     "(executed model not reported)" in its place, as the core's model check says.
     Nothing goes above the child's text: the comment starts with its `## Review:` heading, with the marker on
     line 2, because the release checker reads a review record only there (deploy contract, rule 2).
     The child's text is data: the lead adds that line and changes nothing else.
  A head that moved after the fetch needs no special step: the marker names the reviewed head, and the gate reads it.
  Where `send-report` or the reviewer agent says "post it", these steps do it for a Codex child.
- Codex children start only once the isolation record covers a Codex probe; otherwise reviews wait, and the lead says
  why.

## The sandbox

Claude Code (`.claude/settings.json`, every session in the project) puts every shell command in the sandbox and never
retries one outside it. It limits reads and writes to the working directories; the read block also covers sandboxed
commands, apart from the session temp folder, the repository's shared `.git`, global git config and what the user's
settings re-open. It strips inherited credential-looking variables, and nothing may edit `acceptance/`,
`.factory/hooks/`, `.codex/` or the settings files. Children run in the lead's runtime mode, normally T3's full
access, which is Claude Code's `bypassPermissions`. In that mode a host off the list would be allowed unless
`network.strictAllowlist` is on. Claude Code ignores that key in a repository, so it lives in the user's settings,
next to `allowUnsandboxedCommands: false` and the one excluded command.

**What the read block changes for the lead.** It reads its root checkout, the shared `.git` and `~/.factory`, not a
child's worktree. `recover-403` saves a dead child's commits from the shared repository; uncommitted changes stay in
the dead child's worktree, which is kept, and the issue comment says so. `factory gc` deletes worktrees, so the user
runs it in a terminal when asked. A merge that brings a change to a write-protected path fails inside an agent; the
user pulls once in a terminal.

## The deploy escape: off until three things hold

Deploys from the machine (`factory deploy`, deploy contract rule 6) read secrets from the keychain, so that command
must run outside the sandbox. Its entry is a separate file (`machine/claude-deploy-escape.json`), merged into the
user's settings only when all three hold:

1. **The project's isolation record says pass for its settings and the versions in use** (`check` passes).
2. **The command is out of every agent's reach.** `factory deploy` and everything it executes are installed under
   `~/.factory/bin` from a reviewed core version, mode 0555, outside every repository. The user's settings deny edits
   there, and no sandbox write rule covers it.
3. **It trusts nothing from its caller.** It validates its arguments and reads no code, configuration or recipe from
   the caller's working directory. It makes its own clean checkout of the gated commit in a folder no agent can write,
   rebuilds its environment, refuses `--approve` without an interactive terminal, and replaces every secret in its
   output.

Then `<bin>/factory deploy *` is the second excluded command. Until then the machine deploys nothing; deploys in
GitHub Actions with repository secrets are unaffected.

## What stays with the user

- **Approvals.** Every human gate, deploy and release approval is the user's own action: on GitHub, in the user's own
  terminal, or the user's words quoted verbatim by the lead or the solo session. The broker has no approval or review
  verb, and its workflow inputs refuse any name with "approv" in it. GitHub cannot tell agent from user (decision 31),
  so the author of an approval proves nothing.
- **Tokens, the user's own login, and the isolation record.** Creating, storing, rotating and revoking tokens; keeping
  the user's login out of reach; running the control, reading the probe's output and writing the record.
- **Switching the mode**: the project's entry in `~/.factory/github.json` (`staged`, `on`, `off`), and the machine and
  project settings. Agents cannot edit them.

## What is still open

- **Only the probe can tell** whether T3 applies the project's Codex profile to a Codex child, and whether the
  sandbox keeps the keychain out of reach. The preflight therefore starts nothing until the record covers them.
- **The probe's refusal messages** for the keychain and the proxy are from the tools' documentation. The first real
  probe confirms them or ends INDETERMINATE, which blocks until the check is corrected.
- **A project staged before its settings are merged**, or settings merged while the machine says off: in the first
  case the broker says `blocked` (settings missing), in the second `off` with a warning and plain gh failing. The
  guide's order avoids both.
- **Merges.** `pr-merge` checks the head it is given, the root checkout, draft and `status:needs-human`. Whether the
  merge gate passed is still the gate's own judgement (`factory gate`).
- **The session temp folder** is shared by every session on the machine. At worst, an agent posts another session's
  temp file to its own repository.
- **Follow-ups for the lead after this merges:**
  - the allowlist's home in `docs/factory-yaml.md` › "Not in version 0";
  - decision 31 in `docs/PLAN.md`;
  - factory-init's opt-in step that installs `core/templates/agent-tokens/` (#80 needs no change to keep the default
    off).

## What was checked

| Fact | How it is known |
| --- | --- |
| No T3 tool sets an environment variable for a project, a thread or a child | Tool descriptions of `t3_project_create`, `t3_project_update`, `t3_project_read`, `delegate_task`, `t3_thread_launch`, `t3_environment_read`, `t3_environment_preferences_update`, read on 15 Nov 2026 |
| Before this mode, agents used the user's gh login, scopes `repo` and `workflow` | `gh auth status` in a child, token hidden, 15 Nov 2026 |
| With `GH_TOKEN` unset, gh hands git the user's keychain login even with an empty `GH_CONFIG_DIR` | Seen on 15 Nov 2026 (the credential incident on this PR); hence the placeholder |
| gh's `--jq` gets the process environment | The review of this PR, from go-gh's jq package |
| The broker's rules: token only in gh's and git's environment, output scrubbed, fixed commands with no caller expression, no approvals, no Contents or refs writes, no other repositories, root-only verbs, body files confined, `--out` only as a bare name into the broker's own export folder (also when a folder is swapped mid-call), the mode read from the machine list with settings parsed and tied to the record by digest, versions compared, project binding against forged git links, environment rebuilt, fail-closed on every missing input, isolation record required | `core/templates/agent-tokens/machine/factory_github_test.py`, against stubs only, with tripwires; each rule also broken on purpose to see its test fail |
| The isolation check passes only on the expected refusals, fails on each reachable canary, calls a missing tool, a transport error or an unknown message indeterminate, needs a fresh control, and lists inherited secret variables by name only; the control fails without its positives | The same test file, with a stub that answers every probe with an exact exit code and message |
| The mode is off by default | `core/templates/agent-tokens/sandbox_test.py`: nothing at the paths a default factory-init installs from |
| Sandboxed processes can inspect only processes in the same sandbox | Claude Code 2.1.322's macOS sandbox profile: `(allow process-info* (target same-sandbox))` |
| `env` and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` apply from project settings; the scrub leaves GitHub token variables; `credentials.envVars` `deny` works from project settings; the read block ignores repository `allowRead`/`allowWrite`; `strictAllowlist` works only from user settings | Claude Code docs: settings reference, sandboxing, environment variables |
| A Codex permissions profile can keep workspace paths read-only and switch network off, and must not be combined with `sandbox_mode` | Codex docs: permissions, config reference |
| T3 children load the project's and user's settings; T3 applies the Codex profile; the sandbox keeps the keychain out of reach | **Not known until the isolation probe runs**; the preflight starts nothing before then |
