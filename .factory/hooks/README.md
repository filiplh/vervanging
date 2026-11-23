# The factory's hooks

GitHub Free cannot protect the default branch of a private repository, so the factory guards itself: `factory gate`
judges a merge, and these Claude Code hooks stop an agent from going around it. One file, `factory-hook`, handles
four hook events. factory-install copies it to `.factory/hooks/factory-hook` and merges its registration from
`core/templates/claude-settings.json` into the project's `.claude/settings.json`, where `factory doctor` checks it is
wired.

| Event | Tools | Timeout | What it does |
| --- | --- | --- | --- |
| `PreToolUse` | Bash, Edit, Write, MultiEdit, NotebookEdit, Read, Grep | 600 s | Blocks the calls below (exit 2; the reason goes to the agent) |
| `PostToolUse` | Bash | 60 s | Records a green `factory verify` or `factory verify --no-heavy` on the checkout's HEAD; never blocks |
| `Stop` | | 3600 s | Refuses an implementer's "done" without a green `factory verify` (full or `--no-heavy`) on the current commit |
| `SubagentStop` | | 3600 s | The same check, for a builder that runs as an in-process subagent (its stop ends with this event, not `Stop`) |

## What PreToolUse blocks

| Action | Rule |
| --- | --- |
| A push to the default branch | Any refspec whose destination is the default branch (`main`, `HEAD:main`, `HEAD:refs/heads/main`, `src:main`, `HEAD` or `@` while on it), a plain `git push` that would reach it (`push.default` `simple` or `current` on the default branch, `upstream` whose upstream is it, `matching`, or `remote.<name>.push` set), its deletion (`:main`, `--delete main`), `--mirror`, `--all`, `--branches`, `--prune`, wildcard refspecs, and `factory-github push <default>`. The default branch is `refs/remotes/<remote>/HEAD` (the pushed remote's and origin's), else `git ls-remote --symref`; when neither tells, every push is blocked |
| A force push | `-f` and `--force` in any position or short-flag cluster, `--force-with-lease[=…]`, `--force-if-includes`, a `+` refspec, `factory-github push --lease` |
| An ungated merge | `gh pr merge --admin` and `--auto` (any form), and every `gh pr merge` or `factory-github pr-merge` that `factory gate <P>` does not pass (exit 0). A merge (and any `gh api` write) passes only as the one command of the Bash call, since whatever runs before it in the same call (`git remote set-url …; gh pr merge 12`) could change where it merges: no list around it (`;`, `&&`, `||`, a pipe, `&`, a second line), no `$( )` or backticks in it (give a body with `--body-file` or `-F key=@file`), not inside `sh -c`, `bash -c`, `zsh -c`, `eval`, `$( )`, a here-document fed to a shell, a function, a loop, an `if`, a subshell or braces, and not behind a wrapper other than `env`, a command name that is not plain text (`"$RUN" gh pr merge 12`), or a command the hook does not know (`arch`, `direnv exec`, `ssh`, an unquoted `echo`). The pull request must be one number or a URL of this project, and where gh would merge must be where the gate judges: `--repo`, the URL's repository, or `GH_REPO` must be `factory.yaml` › `project.repo`, and `GH_HOST` or a `HOST/` in `--repo` must be `github.com`. `GH_REPO` and `GH_HOST` count only as a plain `NAME=value` right before the command, as `env NAME=value`, or inherited from the session's environment; any other mention of either (declare, typeset, readonly, local, read, `printf -v`, export, unset, a loop variable, an expansion, a line of its own) is refused, and so is any other setting on the merge (`GIT_DIR=…`, git's `GIT_CONFIG_*` variables, `PATH=…`), which could change the repository gh reads or the gh that runs. Merging through the API (`pulls/<n>/merge`, `merges`) and writing branches through it (`git/refs`, `contents`, `branches`) are blocked. The endpoint is normalised before it is matched: `https://api.github.com` with or without `:443`, in any case, and one leading `/` are dropped, and `%`-escapes are decoded once. A write or a GraphQL call whose endpoint does not normalise is refused: another scheme, host or port, an empty, `.` or `..` part (`//merge`, `/./merge`, a trailing `/`), a part with a space at either end, a backslash, `?`, `#`, `%` or a control character left after decoding. A read (GET with no fields) changes nothing, so it passes whatever its endpoint. `gh api graphql` passes only an inline document that parses as exactly one query operation: a small parser for GraphQL's executable grammar reads it with GraphQL's own tokens (`query`, an optional name, variables and directives, then one selection set of fields, arguments, values and inline fragments `... on Type`; or a bare `{ … }`). A query operation runs no mutation, whatever its fields are called. Refused: comments, block strings (`"""…"""`, so an escaped `\"""` can hide nothing), carriage returns and other control characters, fragment definitions and spreads, a second definition, mutations, subscriptions, empty, invalid or unbalanced documents (`{}`, `query Q() { x }`, `{ x( }`), a query that is not plain text, and input from a file or stdin (`--input`, `-F query=@file`, `@-`) |
| A glob delete in the shared temp folder | `rm` with an unquoted glob in a path that starts at `$TMPDIR`, `${TMPDIR…}` (any default), `/tmp` or `/private/tmp` (`rm -rf "${TMPDIR:-/tmp}"/tmp.*`). Every program keeps files there, and such a glob once deleted thousands of entries that were not the agent's. The message gives the accepted form: remove the exact path, written out, or work in the session's scratch folder. A path held in a variable (`rm -rf "$T"`) is refused like every write destination that holds a `$` (the write rule below), since the hook cannot tell what the variable holds |
| `$NAME:` before a path in a git command | An unbraced variable followed by `:` and a letter, digit, `.`, `/`, `_`, `-` or `~` in any word of a `git` command at the call's top level, quoted or not (`git show $B:core/x`, `git clone $HOST:repo.git`). zsh, which may be the agent's shell, reads the character after the colon as a modifier of the value (`:h`, `:r`, `:s/…/…/`); such a command once silently extracted the wrong file during a release check. The message gives the accepted form, `"${B}:path"`. Only `git` commands are read, and not a script run by `bash -c` or `sh -c` or a git alias, which are not zsh: a missed case costs less than a wrong refusal |
| The emergency stop | Before a push, `gh pr create`, `gh pr ready`, a merge and their broker verbs, `factory-pause status` runs: exit 3 (paused) blocks; exit 1 is tried once more, then blocks. Clearing or setting the pause (`factory pause on/off`, removing the `factory:paused` label) is the person's and is blocked. Comments are never blocked, so the paused report can be posted |
| A deploy approval | `--approve` on any command, a `gh workflow run` input named `approve`, `--json` inputs it cannot read, and approving pending deployments through the API |
| Printing a credential | `gh auth token`, `gh auth git-credential`, `gh auth status --show-token`, `git credential …`, `git-credential-*`, `security find-*-password` and `dump-keychain`, `secret-tool lookup`, `printenv`, `env`, `set`, `export` and `declare` that print every variable, expanding a variable whose name looks like a credential (`$GH_TOKEN`, `${API_KEY}`), and any word, redirection or Read/Grep path that names a credential store (`~/.config/gh`, `.git-credentials`, `.netrc`, `~/.ssh`, SSH keys, the keychains, `/proc/*/environ` and the like) |
| Writing `acceptance/` or `.factory/hooks/` | Edit, Write, MultiEdit and NotebookEdit into either folder, and Bash writes (redirections, `tee`, `rm`, `mv`, `cp` and `ln` targets, `sed -i`, `dd of=`, `git rm`, `git checkout`, `git restore`, `git clean`, `awk -i inplace` and any other gawk library, `find -delete` (the folders it starts from) and `find -fprint`). A find that writes (`-delete`, bfs's `-rm`, `-fprint`, `-fprint0`, `-fprintf`, `-fls`) is judged on an allowlist: every word of its own must be a flag, primary or operator of GNU find, BSD find or bfs that the hook knows, with its operands, or else a starting folder, wherever it stands (bfs takes folders anywhere: `find src -name x acceptance -delete`). Any other word that starts with `-`, a dash word that is not plain text, and any word that starts with `-f` but is not `-fprint*` or `-fls` (`-f PATH`, `-follow`, `-false`, `-fstype`, `-files0-from`, also as an operand) refuse the call. Its starting folders (the session's folder when none is given) and the files `-fprint*` and `-fls` name are write destinations. A find that writes nothing is not judged, apart from the command its `-exec` runs. A writer that `xargs`, `find -exec`/`-execdir`/`-ok`/`-okdir` or `parallel` runs is refused, since they add paths the hook cannot see; for `xargs` and `find` only the command they run is read, so `xargs grep touch` and `find . -name touch` pass. `ln` may not link to a file in either folder, and `ln -s` may not point at either folder or at a folder that holds one (`ln -s . x`), so no link made in the call leads there. git's `--work-tree` and `--git-dir`, `GIT_WORK_TREE` and `GIT_DIR` set on a git command, `core.worktree` and include paths (`include.path`, `includeIf.*.path`) set with `-c` or written with `git config`, are refused, and so is `sudo -D`: each moves the writes somewhere the hook does not check, or loads config it does not read. `git config` is read with its options wherever they stand and with both syntaxes (`git config <key> <value>`, `--add`, `--replace-all`, and the `set` subcommand), in any file (`--file`, `--global`, `--system`, `--worktree`), and a write's `--file`/`-f` is a write destination like any other (`--blob` is a read); a write whose key or mode it cannot read (an option it does not know, a word that is not plain text, `--edit`/`edit`, `--rename-section`/`rename-section`) is refused. Reads (`--get` and the other `--get-*`, `-l`/`--list`, `get`, `list`, a key alone) and unsets pass. A write destination passes only as a literal path whose existing parts resolve (symlinks and `..` included) outside both folders, in the session's checkout and the one that holds the destination; a destination holding `{`, `}`, `*`, `?`, `[` or `$`, quoted or not (`> "$f"`, `rm -rf "$DIR"`, `touch {acceptance,x}/f`), is refused. A relative destination is checked from every folder the shell may be in: the session's, and every folder a `cd`, `pushd` or `env -C` in the call may reach, read lexically (`cd -L`: `..` drops the name before it) and physically (`cd -P`: symlinks first), with the folder before kept as well, since a cd can fail or run in a subshell (`(cd /tmp); touch acceptance/f`); `git -C` resolves physically too. After a cd the hook cannot follow (`cd -`, `popd`, `pushd` with no folder, `+N`, two folders, a folder that is not plain text, a bare name while `CDPATH` is set), every relative destination is refused. Reading `acceptance/` stays allowed: the validator runs it |

**One deadline.** Each run has one total deadline below its registration's timeout (540 of 600 s, 50 of 60 s, 3480
of 3600 s), and every subprocess (git, the pause check and its retry, each gate, verify) gets at most what is left of
it; a subprocess that would outlast it is stopped with its whole process group and counts as "took too long", which
blocks. A cancelled hook would let the call through, so the hook always answers first. `FACTORY_HOOK_BUDGET` (seconds)
can only lower the budget, for tests.

**Where the tools cannot decide, it blocks.** No `factory.yaml`, agent-token mode on (where `factory gate` cannot
pass, so a person merges after the gate by hand), a tool missing next to the hooks, a timeout, or a command the hook
cannot read: the dangerous action is blocked and the message says why. An internal error blocks too, because Claude
Code lets a call through when a hook fails any other way.

## How it reads a command

A real reader for the shell grammar a guard needs, not patterns over the text (the reviewer's rule on structured
input): quoting (`g''it pu"sh"` is `git push`), line continuations, comments, operators (`;`, `&&`, `||`, `|`, `&`,
newlines, subshells, braces), redirections, here-documents and here-strings, and expansions. Every inner script is
read as well: `$( )`, backticks, `sh -c`/`bash -lc`, `eval`, `env -S`, a script piped or fed into a shell, `git`
aliases (looked up in the checkout's config), and commands behind wrappers (`env`, `sudo`, `timeout`, `nohup`,
`command`, `xargs`, `find -exec`), and the arguments of a command it does not know (`arch`, `direnv exec`, `op run --`) where
they name `gh` followed by a gh command (so `gh pr create` and `gh pr ready` get the pause check there too),
`factory-github`, `factory pause`, `factory-pause`, `printenv`, `env` as the last word, `git`, `security` or
`secret-tool` with a verb that matters (push, merge, api, auth, credential), or a shell given `-c`. A `cd`, `pushd`, `popd` or `env -C` is followed as the write rule above says. A value it cannot
know (a refspec in a variable, an argument from `xargs`, a pull request number from a substitution) is not guessed:
for a push or a merge, that blocks. Unknown options of `git`, `git push` and `gh pr merge`, and `gh` commands it
does not know (an alias or an extension can merge), block too; `gh co` counts as one, since it is a gh alias a
person's config may have changed. Defining a gh alias (`gh alias set`, `gh alias import`) is refused. Text that only mentions a command in one quoted
word (a commit message, `echo 'git push …'`, `grep "gh pr merge"`) passes.

## The Stop hook

The Stop hook acts only on an implementer's final report: a message with the implementer report's heading (not the
paused one) whose last line is `PR <URL>, head <SHA>, checks and reviews <state>` (`factory-implement`'s report). It
then needs a green `factory verify` on the checkout's current commit. First it compares the report's head with that
commit: a full or abbreviated hex SHA (7 to 40 digits, any case) after `head ` must be the start of the HEAD under the
event's `cwd`. A line with anything else there is not a done report, so nothing is checked, as before. A head that does
not match (an older head, or a commit in another worktree) refuses "done" with a reason naming both commits, whatever
the record says, because no run here vouches for the reported commit. The hook does not look for that commit elsewhere:
the agent reports the head it checked out and verified, or reports that the work is not done; the refusal tells an
agent whose folder is not its own checkout to end with a `Not done:` line. Only the last line names the head: another
SHA in the report's body is ignored. A pause lets the agent
stop, and so does a `Not done:` report, as for every refusal. With no commit to read under `cwd`, the comparison is
skipped and the rules below apply unchanged.

1. A recorded green run on that commit passes. The PostToolUse hook records one when the agent runs `factory verify`
   or `factory verify --no-heavy` (no pull request number, nothing else) in the foreground and its output is that
   command's own line saying all commands passed on that head: `green` for a full run, `green-no-heavy` for the
   option. Both count for Stop; a red run, an echo of the line, or a line of the other command's kind does not. The
   record is `factory-hook-verify` in the checkout's own git folder, and only this hook reads it: no gate or release
   reads it, and a `--no-heavy` run never posts evidence. A run counts only when the hook knows which executable ran:
   with any assignment in front (`PATH=…`, `FOO=1`) or `env` in front, it is recorded as not counted, and the next
   Stop runs its own verify and, if that is not green, says to run `factory verify` with nothing in front. The one
   assignment allowed is the worker cap, `FACTORY_TEST_WORKERS=<n>` (a literal number), which the briefs ask for and
   which cannot change the executable.
2. Otherwise, after the pause check (paused, or cannot tell, lets the agent stop: that is what the stop asks for), the
   hook runs `factory verify --no-heavy` itself and records the result. Like a builder (`factory-implement` § 5.2), it
   leaves each heavy check to the gate, which runs it in full under the machine's heavy lock, so a long end-to-end
   check never eats the hook's time. Green lets the agent stop, with a message that the run was not a full one and
   which heavy checks it left to the gate; anything else refuses "done" with the reason and the last lines of the
   output.
3. A commit whose run was red is not run again: the same done report is refused again, with the reason. The agent
   either makes verify green (a green foreground run is recorded) or ends with a report that says the work is not
   done: a line starting with `Not done:` and why. Such a report never claims done, so the Stop hook lets it through
   at once. A run that could not finish is run again on a later stop, but not on the stop right after a refusal.
   A run cut at the deadline counts as one that could not finish: the hook finds the record file before verify
   starts, so the record is written even when no time is left to run git.

### SubagentStop

A builder started as an in-process subagent ends with Claude Code's `SubagentStop` event, not `Stop`; a delegated child
in its own session ends with `Stop`. `factory-hook` runs the same check for both events (same report test, same
`factory verify --no-heavy`, same record, same pause rule, same budget), and the template wires it under both with the
same timeout. It reads only the fields the two events share: `cwd`, `last_assistant_message` and `stop_hook_active`.
The subagent-only fields (`agent_id`, `agent_type`, `agent_transcript_path`) are ignored. `stop_hook_active` means
Claude Code already held this subagent back once, so the loop rules above apply unchanged: an unchanged done report is
refused again without a rerun, an internal error then lets the subagent stop, and a report with a `Not done:` line stops
at once. The record is per commit and shared with `Stop`, so a green run by a subagent also clears the parent's stop on
the same commit. The report's head is compared with the HEAD under `cwd` as for `Stop`, so a subagent whose `cwd` is
not the checkout it built in is refused with both commits named. An event without `last_assistant_message` is not
checked.

## What the hooks cannot see

The hooks guard against an agent's **mistakes**; they are not a sandbox against an agent that sets out to get around
them. Each rule above refuses what the hook cannot read for certain, so an ordinary slip (a merge chained after another
command, a `cd -P` through a symlink, a GraphQL document with a mutation in it) is stopped with a reason. A shell reader
cannot close every deliberate route, though, and these are known and left open:

- **Code it does not read**: a script file (`sh ./x.sh`), a program that pushes or merges itself (`python -c`,
  `node -e`), and a file that `source` or `.` loads, including one made on the spot (`source <(echo "gh pr merge 12")`).
- **Shell aliases and functions**, including the ones the session loads from the person's shell configuration
  (`alias m='gh pr merge --admin'`, a function named `gh` or `cd`), and shell options and variables that change what
  a command does: zsh's `auto_cd` (a folder name alone changes folder), `CDPATH` set in the shell rather than inherited.
- **Names built from parts.** The hook does not track variables. `n=GH_; export "${n}REPO=…"; gh pr merge 12` is
  refused only because a merge must be the call's one command, and a name exported in one call does not reach the
  next, because the Bash tool keeps no variables between calls. A shell that kept them would open this route, and so
  does a file that sets them and is sourced (above).
- **State left by an earlier call.** The Bash tool keeps only the working folder between calls (variables and aliases do
  not survive), but files do: a remote URL or git config changed in one call (`git remote set-url`, gh's default
  repository) changes where a plain `gh pr merge 12` in a later call merges, while `factory gate` judges
  `project.repo`.
- **Wrappers and writers it does not know**: a command it does not know is read only for the guarded tools and verbs
  above, so a quoted remote command (`ssh box 'gh pr merge 12'`), a `make` target or an `npm` script is not; nor are
  writers outside its list (`tar -x`, `unzip`, `git apply`, `git stash pop`), a write the program text makes (awk's
  `print > "f"`, sed's `w f`), git settings exported in an earlier command of the call (`export GIT_WORK_TREE=…`), or
  a write to a folder that holds a protected one (`rm -r .`, `find . -name x -delete`, `git clean -fdx` with no
  path): the rule checks the destination it is given, not what lies below it.
- **Temp deletes by another route** get no temp-folder message: `cd "$TMPDIR" && rm -rf tmp.*` and `find "$TMPDIR" -name 'tmp.*' -delete` are refused only by the write rule (a glob or a `$` in a destination), and `find /tmp -name 'tmp.*' -delete` passes, since its starting folder is a literal path outside the protected folders.
- **zsh modifiers outside git**: `$NAME:` before a path is refused only in `git` commands.
- **Links made another way.** `ln` is read, but a link made by another command in the same call (`cp -s`, `cp -l`,
  `cp -a` of a symlink, `tar -x`, `git checkout` of a branch holding one) is not, and a hard link to a protected file
  that already exists cannot be told from any other file.
- **An API read through an endpoint it does not normalise** passes, since a read changes nothing; the same endpoint
  on a write is refused.
- **The hooks are files in the checkout.** An agent that edits `.factory/hooks/` or `.claude/settings.json` from a
  tool the hooks do not see could weaken them. The hooks block Edit and Write there; agent-token mode also denies
  writes to `.factory/hooks/` in the sandbox (`core/templates/agent-tokens/`).
- **The verify record** lives in the checkout's git folder, which the agent can write. It guards against forgetting
  verify, not against forging a result.
- **Codex children** do not run Claude Code hooks. They run in their own sandbox profile (`.codex/config.toml`); for
  them the lead's merge gate (`factory gate`), the lead's pause checks and, in agent-token mode, the broker (which
  never pushes to the default branch) are the guards.
- **The Stop and SubagentStop hooks** know "done" only from the report's heading and last line; a report in another shape, or with
  translated headings, is not checked. When the Stop hook itself fails (an internal error) while Claude Code says
  it already blocked this stop once (`stop_hook_active`), it lets the agent stop: one block per stop at most, so a
  broken hook cannot keep an agent running for ever. The first failure on a stop still refuses.

**Against an agent that sets out to get around them**, the boundary is not these hooks but agent-token mode (a
per-project token, and the broker, which merges only from the root checkout and names the registered repository
itself) together with `factory gate` on every merge the lead makes (the factory's `docs/PLAN.md` › Safety).

## Tests

`sh core/hooks/factory-hook.test.sh` (and `SHELL_UNDER_TEST=dash`) runs every case by name in a throwaway project
with stub `factory`, `factory-pause` and `gh`: nothing is pushed or merged, and nothing reaches GitHub.
