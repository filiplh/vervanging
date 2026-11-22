# Deploy contract

Contract version: **2** (2: every release gets a version, rule 5).

What every deploy target must provide, whatever the platform. `factory-lead`, `factory deploy`, `factory doctor` and
the merge gate point here; they do not restate it. A project describes its targets in the `deploy` section of
`factory.yaml`. Each target names a **recipe**: a folder under `recipes/` (in a project: `.factory/recipes/<recipe>/`)
that knows how to build, deploy, smoke-test and roll back on one platform. A recipe is written the first time a project
needs its platform, and it must meet every rule below before it merges.

Terms:

| Term | Meaning |
| --- | --- |
| Target | One thing that gets deployed, such as a web app or an app for one store: a key under `deploy`. |
| Environment | Where a target runs: `preview`, `staging` or `production`. A target has at least one. |
| Deploy | Putting one build of one commit into one environment. |
| Release | A deploy to `production`. |
| Rollback | Putting the version that was live before back into an environment, without a new build. |
| Live version | What the platform says is running now. The platform's own record is the truth, never a file in the repo. |

## What every target provides

### 1. Environments

- The environments come from `deploy.<target>.environments` in `factory.yaml`, each with a `when` trigger, an `approve`
  mode and, where it has one, a `url`.
- A recipe lists the environments and the triggers it supports (see [How a recipe declares itself](#how-a-recipe-declares-itself)).
  `factory doctor` refuses a target that asks for an environment or trigger its recipe does not support.
- `preview` is never a release: it builds a pull request's **head commit** (not the merge commit the host may offer),
  and everything it records (the version's tag, its message, the comment) names that same commit. It never touches
  production traffic, and it is opt-in (`pr-label:<label>`) so it costs nothing until someone asks for it.
- An environment whose recipe needs a URL for its smoke check must set `url`.
- **A `runs_on: machine` recipe supports the `manual` trigger only, for now.** Nothing on the machine listens for
  merges, nightly runs or labels, so such a recipe lists only `manual` in `environments`, and `factory doctor` refuses
  `merge`, `nightly` and `pr-label:<label>` for its targets. A machine recipe that adds another trigger changes this
  rule first.

### 2. A build from a green gate, on the exact commit

- **Releases build only commits on the default branch that passed the gate, and the release proves it for the exact
  commit.** That a commit belongs to some merged pull request proves nothing: the pull request may have merged outside
  the gate, or its content may differ from what the gate tested. The commit each trigger releases:

  | Trigger | The commit | Extra proof besides the gate chain |
  | --- | --- | --- |
  | `merge` | the merge commit the push brought | none |
  | `nightly` | the commit the nightly run tested | the nightly CI run on that exact commit concluded green |
  | `manual` | the tip of the default branch | none |
  | `pr-label:<label>` | the pull request's head | none: previews are not releases and need no proof |

- **The gate chain.** For every first-parent commit from the live commit to the released one (only the released commit
  when the live commit is unknown), the release shows all of this, and refuses (fails, changing nothing) when any link
  is missing. **The proof is time-ordered:** each record must already have existed, and been in force, at the moment
  it was relied on, and nothing still visible on the pull request may contradict it. A chain completed afterwards
  proves nothing.
  1. a pull request was merged into the default branch **as this exact commit** (its merge commit SHA is this commit);
  2. **the gate record in force at the merge** (the latest gate record written no later than the merge) is for the
     pull request's final head and says `result=pass`, and it is the last word: no gate marker of any kind is later
     than it. `factory gate` writes it when it passes, just before it merges, with full 40-character SHAs:
     `<!-- factory:gate head=<head SHA> base=<base SHA> result=pass checks=<ci|local> evidence=<comment id|-> -->`.
     A head that was gated, pushed over and pushed back is refused, since the record in force is for another head;
  3. the commit's first parent is that base, and the commit's tree is the head's tree: the merged result is exactly
     what the gate tested (squash merges of an up-to-date head, the core's merge method, meet this);
  4. **the checks as they stood when the gate record was written** back it, following the merge gate's table in
     `factory-yaml.md`. **Nothing is judged in aggregate:** every check (by app and name) and every commit status
     context needs its own evidence in force at that moment, so one green check never stands in for another that
     was still running, failing or unknown. Every attempt and every page is read; a listing that returns fewer
     items than it says it holds refuses. For each check:
     - the latest attempt finished by then is the one in force, and it must have passed;
     - no attempt may have been running when the gate record was written or at the merge (an attempt runs from its
       start to its completion; an unknown start counts as before the gate), and none may be unfinished now;
     - a failure is only superseded by a re-run in the same check suite (the same workflow run), and no attempt may
       have failed since;
     - a check whose first attempt started after the merge was not part of what was gated: it only counts if it
       fails.

     For each status context, the latest status reported by then must be `success`; a context first reported
     afterwards counts as having been running (a status has no start time) unless its history starts with
     `pending`; it may not have been pending at the merge, and may not have failed since. With `checks=ci`, at
     least one check had run and succeeded by then, and every check in force had passed: a job that concluded
     `skipped` or `neutral` counts as passed, as `success` does, and a job the CI service never started does not.
     With `checks=local`, local evidence is accepted only where CI did not run, check by check (a job the CI
     service refused to start, for billing or a spending limit, or no job at all; never a job that was running or
     had failed), and the comment
     `evidence=<id>` holds an evidence record written before the gate record, as `factory verify` writes it:
     `<!-- factory:evidence head=<head SHA> tree=<tree SHA> result=pass -->`. `tree` is the git tree the checks
     ran on, full 40 characters (`git rev-parse <commit>^{tree}`), and `head` the pull request's head when they
     ran. **The tree is what was tested:** the record counts for the gated head when its `tree` is that head's
     tree, whichever commit carried it (a batch gate's combined tree, a head updated to identical content), and
     never otherwise, not even for the head it names; one byte of difference is another tree. A record without
     `tree` (written before this key existed) counts for its exact `head` only. Every later evidence marker must
     say the same: `result=pass`, for the gated head or its tree. **Local evidence never overrides a job that ran
     and failed.** Which entries the evidence holds for each check that did not run (a check's own command, a
     `ci.external` job's steps, or, for a `ci.external` job GitHub refused, the checks its entry's `covered_by`
     names) is the merge gate's rule 2, which judges it before it writes the gate record; a skipped job of a
     workflow no list names, which the PR leaves unchanged, needs none there. The release reads the record and the
     checks, not `factory.yaml`, and decides the same way check by check: a refused job counts only under
     `checks=local`, a skipped one counts as passed under either kind (also one skipped because a job it needs was
     refused), and one that failed, timed out or was cancelled refuses whatever the evidence. Whether a
     `ci.external` job is red on the default branch (the merge gate's rule 1, where a job skipped only because GitHub
     refused jobs it needs is not run, and not red) is the gate's alone: the release reads no workflow run of the
     default branch, so it decides the same whichever way that run went. This recipe's own deploy jobs are not checks;
  5. **the review in force when the gate record was written** (the latest review record written before it) is of
     that exact head (full SHA), or carries over to it (below), with `verdict=merge`, no open P0–P2 and no
     unresolved merge-blocking human gate, and every review marker later than it says the same (a clean merge
     review of the gated head or of the reviewed one). So a review posted only after the gate or the merge, open
     findings at the gate with a clean review afterwards, and a review that turned dirty or stale later all refuse.

     **A review carries over clean merges of the default branch, a version raised in them or in one commit before
     them, and nothing else.** A review of head R stands for a later head H only when every first-parent commit from
     R to H (but the version commit below) is a merge of two parents whose second parent is a commit of the default
     branch (an ancestor of the gate record's base) and whose tree is exactly git's own conflict-free merge of its
     two parents (`git merge-tree --write-tree`, the default strategy), which the release recomputes. **One change
     inside the merge is allowed: a version.** The merge may set the `version` line of a version file
     (`.claude-plugin/plugin.json`, at the root or in any folder, where the factory core keeps its version) to a
     version higher than both parents' (`X.Y.Z`, compared number by number), and must leave everything else as git
     merges it, in either case:
     - git's merge conflicts in that one path only, a conflict of content: every other file is git's, and that file
       is git's conflict-free merge of the three sides once each side's version line carries the resolved value;
     - git's merge is clean (for example, both sides made the same bump): every other file, and every other byte of
       that one, is git's.

     The release recomputes that too (`version_only_merge()` in `factory-release-check`). **The same raise may be a
     commit of its own** (as when main has not moved since R): the first commit after R alone may be one non-merge
     commit on R that changes only the `version` line of a version file, to a version higher than R's and the
     default branch's (on the merge bases of R and the gate record's base), every other byte and file as R has them;
     merges as above may follow it (`version_only_commit()`). Any other conflict, any other resolution, any other
     edit made inside the merge, a merge of any other branch, any other commit between R and H (a fix, a lead
     commit, a second version commit, a version commit after a merge), and a rebase or force-push that rewrote R all
     need a review record of H.
     Evidence carries over a merge only as link 4 says: by its exact tree. The release reads the pull request's own
     commits from its clone, fetching `refs/pull/<number>/head` when a squash merge left them out; when it cannot,
     the review does not carry over.

  **Proof is read strictly, doubt loosely.** A record that *proves* (the gate, evidence and review records above)
  counts only when all of this holds; anything else proves nothing:
  - its author is a User account (never a bot, an organisation or a deleted account) whose permission on the
    repository, looked up when the release runs, is write, maintain or admin. GitHub's author association
    (`MEMBER`, `COLLABORATOR`) is not enough, since a member may have read access only. When the lookup itself
    fails, the release refuses;
  - the comment was never edited after it was written. Records are ordered by when they were written (within one
    second, by comment id), never by where a listing puts them;
  - the record is the comment's **first line**, or the line right after a first-line `#` heading (as the reviewer
    writes `## Review: …` above its marker). Lines end only at CR, LF or CRLF, as in Markdown;
  - the line is exactly the marker: `<!-- factory:<kind> key=value ... -->` with single spaces, ASCII only, the
    exact set of keys for its kind and no key twice. The evidence record has two exact sets: `head tree result`,
    and the older `head result`.

  A marker that *contradicts* is read loosely: any `factory:gate`, `factory:evidence` or `factory:review` marker
  anywhere on the pull request (a comment, a formal review, an inline review comment, the description), by anyone,
  edited or not, quoted or in code, counts when it is later than the record it would contradict (an edited comment
  counts from its last edit; the description always counts as later). To clear one that is not a real result, edit
  or delete that comment. A mention of one of the three tags in prose is not a marker: a tag counts when a record
  field (one of the record keys, then `=`) follows it in its comment before the next tag, or when it opens an HTML
  comment; with neither, it is prose. So "not contradicted" is a claim about what is still visible on the pull request, not an
  immutable history: a marker edited out or deleted leaves nothing to inspect, and the earlier record stands again.
  That is the clearing policy, and it stays inside the trust boundary below.

  Known limits, stated plainly: times have one-second granularity; a writer's permission is read when the release
  runs, not when the record was written; and a deleted comment, or text edited out of one, cannot be seen (GitHub's
  API exposes no edit history; changing another person's comment needs the same write access that writes records).

  A commit that came onto the default branch any other way (a direct push, or a merge outside the gate) is never
  released, and neither is any later commit while it sits in the release range.
- **Which checker proves it.** Every proof above, and the holds, migrations, breaking changes and version of rules 5
  and 7, comes from the core's release checker (`.factory/bin/factory-release-check`), and **never from the copy in
  the checkout being released**: that copy is part of what is under proof, so a commit that weakened it would grade
  itself (an extra edit after the review that also turns off the carry-over guard). The recipe reads the checker
  from git (`git ls-tree`, then `git cat-file blob`) out of a commit an earlier release already proved, writes it
  to a private folder and runs it in the checkout, where it reads the range, always in Python's isolated mode
  (`python3 -I`), so no module of the checkout can load into it through `PYTHONPATH`, the user's site folder or
  the current directory:
  - **A release:** the live commit's checker, when the live commit is known and on the released commit's
    first-parent line (the default branch's own history; a pull request's own commit never counts). A known live
    commit off that line refuses. **A first release** (no live commit known: nothing deployed yet, a live version
    the factory did not deploy, split traffic) takes the checker of the released commit's **first parent**, the
    default branch just before it; it holds for your OK anyway (rule 7).
  - **A rollback:** the checker of the live commit whenever the live commit is known, and of the restored commit
    only when the live one is unknown (both were released, so a release proved them). Never the tip's own copy,
    which may hold commits no release has proved yet. The chosen commit must be on the first-parent line of the
    default branch's tip and hold a checker (below); when it fails either, there is no checker and the rollback
    holds. A known live commit that fails never falls back to the restored commit's checker.
  - Only a regular file counts (mode `100644` or `100755`): a symlink, a folder, a submodule, a symlinked folder
    above it, or no file at all is no checker, and the release refuses (the rollback holds). So the merge that
    first installs the factory releases nothing itself (its first parent has no checker); the next merge does.

  **How a change to the checker is approved, and when it takes effect.** A change to the checker is a pull request
  like any other: reviewed, gated and merged through the merge gate, which judges it with the default branch's
  checker, never with the pull request's own copy ([merge-gate.md](merge-gate.md), rule 6). The release that ships
  it is proved by the old checker, the one live before it. Once that release is live, the new checker proves every
  release after it. A rollback past it makes the restored commit's checker the anchor again: the next release is
  proved by the checker of what is live then, so a rolled-back change to the checker stops judging until a release
  ships it again. The release steps of one commit run the checker of the commit before it, so **its command line
  and output lines stay compatible across one release**: a new argument or output line ships in the checker first,
  and the release steps use it only from a later core version. A release whose steps ask an older checker for
  something it does not know refuses, changing nothing, and so does every one after it while that checker is live:
  revert the steps' side, release, then bring it back.

  Known limits, stated plainly: GitHub runs a workflow from the commit that triggered it, so the release workflow
  and the recipe's own scripts (among them the one that asks the platform what is live) come from the released
  commit, and a machine recipe's actions from the default branch's tip; a change to them is trusted because it
  passed the merge gate like any other file, not by a commit an earlier release proved. The first-parent rule above
  keeps a live commit they name inside the default branch's history.
- The build runs from a clean checkout of that commit with its whole history (a shallow clone would cut the range
  short, so the release refuses one), never from a working tree. The deploy records the **full** commit SHA on the
  platform (a tag, label or message on the version), so the live version always names its commit. A live commit
  that is not named in full, in the recipe's own format, is unknown (a short prefix could match another commit),
  and so is the live commit while traffic is split between versions; an unknown live commit holds.
- **The build runs once per deploy and never after a rollback.** A rollback restores a version the platform already
  has.

### 3. A smoke check after every deploy and every rollback

- The recipe checks the environment right after it changes. The checks are the recipe's, in one of two forms:
  - **a URL check**, against the environment's `url` (or the address the platform reports for a preview): at
    minimum, the configured paths answer with success;
  - **a command run on the target itself**, for a target with no URL the deploying side can reach (a device, a
    server on a private network): a command named in the target's settings, run where the target runs and in the
    version that is now live (for example over SSH, in the live release's folder). Exit 0 means healthy. Where the
    platform reports its own state, the recipe checks that too (for example, every service unit active). A recipe
    that checks this way lists no environment in `needs_url`, and `url` is then optional.

  Either form is retried a bounded number of times before it counts as failed, and either one is "the smoke check"
  below and in rule 4.
- **A failed smoke check on a preview** fails that preview run. Nothing else happens.
- **A failed smoke check on a release** rolls back to the version that was live before, only when putting the old
  code back is known to be safe, checks again, and opens a `type:bug` issue labelled `priority:P1` with the commit,
  the run, what failed and whether the rollback worked. The run fails.
- **The automatic rollback is off whenever the release needed your OK for what it carries:** a migration path, an
  H7 release hold, a breaking change, or a range that cannot be shown (the live commit is unknown). Old code may not
  work with the data or the callers the new version changed, and your approval to release is not an approval to
  roll back: that rollback is a separate decision with its own approval (rule 4). The recipe decides this fail
  closed: any reason for approval it does not know to be harmless turns the automatic rollback off. The P1 bug then
  says that nothing was rolled back, why, and how to do it.

### 4. A one-command rollback

- Every release target has exactly one command that puts the previous version back:
  `factory deploy <target> <env> --rollback [<version>]`. Without a version it restores the version that was live
  before the current one. The recipe maps it to the platform's own rollback, not to a rebuild of an older commit.
- A rollback is followed by the smoke check, like a deploy.
- **A rollback names the version it returns to** (rule 5), and the one it leaves, in its summary, its held issue
  and its bug, the automatic rollback of rule 3 included. The recipe reads it from the restored commit with
  `factory-release-check version --target <target> --at <commit>`; a commit released before versions existed, or
  whose version could not be recorded, has none, and the rollback says so. A rollback records no new version: the
  restored commit keeps the one it had.
- **A rollback restores code, not data.** When any commit in the range being undone (not only its two ends, and not
  only the first-parent line) touches a migration path, carries a breaking change, or belongs to a pull request with
  an H7 release hold, the rollback waits for your OK, like the release did, with a warning that stored data keeps
  those changes and the restored code must still work with it. **When that range cannot be shown** (the live or the
  restored version names no known commit, the two are not in order, or the pull requests cannot be read), the
  rollback waits too, whatever the migration settings say: an H7 change to a config schema, a file format or a
  public interface needs no migration path. A rollback reads the same normalised view of its range as a release
  does (rule 7). Recipes say plainly what their platform's rollback does not restore.
- **Client-side stored data is data too.** A client that keeps data on its own side (a browser, an installed app, a
  device) upgrades that data the first time it opens a build with a newer stored-data version, and the older build
  then refuses to open it ("newer version"). A reload does not help, since the platform, or a service worker, now
  serves the older build. So a rollback across such a version bump causes an outage on every client that opened the
  newer build, however healthy the server is. The files that set these versions are migration paths (rule 7):
  - an IndexedDB schema version: the module that declares the database's versions and upgrade steps, such as
    `**/*schema.*`;
  - a local file format: the code that writes and checks the format's version field, such as `**/*format*.*`;
  - an app-cache manifest: the service worker and the manifest of cached files, such as `**/service-worker.*` and
    `**/*.webmanifest`.
- **A rollback across a client-side stored-data version bump is an H7 hold,** automatic and manual alike: the
  automatic rollback is off (rule 3), and the manual one waits for an approval. The held issue states the client-side
  consequence (clients that opened the live version keep data the restored build cannot read), and the approval
  acknowledges it.
- **The remedy for a bad release past such a bump is a roll-forward**: a fix released on top of it, which keeps the
  newer stored-data version. A rollback across the bump is the exception, for when the newer build cannot run at all
  and locking out the clients that opened it is the lesser harm.
- The approval of a held rollback names the live version being undone in full (its full version id or its full
  commit SHA), never a prefix.
- The lead may run a rollback without asking when no migration is in the range: it restores a version that was
  already live.

### 5. A version, and release notes from the changelog

- **Every release gets a version**, computed by the core's release checker (one copy for every recipe:
  `factory-release-check check ... --target <target>`) from the range, from the previously live commit to the
  released one. Semantic versioning from its conventional commits: a breaking change raises the major, any `feat`
  the minor, anything else the patch. The checker reads the commits through the same normalised view as the checks
  of rule 7, in the same run, so a release whose range has a `breaking:` finding (a pull request's title included)
  is always a major one.
  - It counts from the **highest version ever recorded for the target**, not from the live one, so a number is never
    given twice, even after a rollback. With none recorded yet, the release is **`1.0.0`**.
  - When the range cannot be shown (the live commit is unknown) and a version was recorded before, the major goes
    up: in doubt, the larger step.
- **The recipe records the version on the released commit after a passing smoke check**, as the lightweight tag
  `factory/<target>/v<X.Y.Z>`. The factory's own prefix keeps it apart from a project's own tags (`v1.2.3`, `1.2.3`,
  `<package>@1.2.3`), the target's name keeps two targets' numbers apart, and a lightweight tag stays out of
  `git describe` unless asked for (`--tags`). A held release, or one that fails its smoke check, records nothing.
  When recording fails, the run says so and fails; the release stays live without a version, and the next one
  counts from the highest recorded version.
- **Every release writes release notes** for its range and links them from the run's summary. They are one entry:
  - headed `## <version> (<YYYY-MM-DD>)`, with the release's date in UTC;
  - then one line that names the range: `` From `<live commit>` to `<released commit>` ``;
  - then one line per commit of the range on the default branch's first-parent line (each merged pull request),
    with its subject and short SHA; or, when the project keeps a changelog file and the range adds lines to it,
    those lines.
- **A project changelog file, when kept, gets the same entry.** The release never writes it there: that would be a
  commit to the default branch outside the gate and, with `when: merge`, a release of its own. The project's pull
  requests add their lines at the top of the file (under a heading such as `## Unreleased`); the release notes give
  those lines their version heading, and the entry is copied into the file, as it is, with the next change to it.
- When the previously live commit is unknown (the live version was not deployed by the factory), the notes say so and
  list only the released commit, and the release waits for your OK once (rule 7).

### 6. Secrets that agents never see

No agent ever reads, prints, stores or passes on a token, key, password or signing certificate. Recipes ship secret
**names** only, as defaults; `factory.yaml` never holds a secret value, and `factory doctor` refuses values that look
like one.

**A secret never shares a job with third-party code.** This holds for every recipe, on either path. The job, or the
process, that holds a deploy secret runs no third-party install or build code. That means no `commands.setup`, no
build command, no package install, no package-manager lifecycle script, and nothing else the project's dependencies
ship. A dependency that ran there could plant a fake deploy tool or read the secret. Such a job runs only:
- the recipe's own scripts and the core's tools, from the checkout of the commit being deployed;
- the platform's deploy tool, **pinned by exact version and by checksum**, every downloaded byte checked before any
  of it runs. Either a committed lockfile that gives every package an integrity hash, installed without lifecycle
  scripts into an empty folder, or a release asset checked against a committed sha256. Never `npx <tool>`, a version
  range, `@latest`, or an install that runs lifecycle scripts;
- the runner's or the operating system's own tools (shell, git, curl, ssh, Python, Node), and actions or tools the
  host provides, pinned as the host allows. Nothing fetched at run time without a checksum.

The project's build runs before that, where no secret is reachable, and hands on its output as **data**. The job
that holds the secret takes only that output. It checks that the output comes from this run and this commit, and
that it is plain files. It writes them only into a separate release tree. It never writes them into the checkout or
anywhere else that a later step runs code from (the recipe's scripts, the core's tools) or that the deploy tool reads
its own settings from (its config, `.env` files, redirects). It never runs any of them. A step that the deploy tool would run on its own, such as a
custom build command in its config, is refused where the secret is. A recipe's tests check this on the rendered
workflows or the deploy code, with a negative case for each rule.

There are two paths, and every recipe picks one (`runs_on` in its manifest):

- **`ci`: web deploys run in GitHub Actions** with repository secrets, split into jobs. A build job, with no secret
  and a token that can only read the repo, runs setup and build and uploads the deploy artefact. A deploy job holds
  the secrets, runs no project install, build or lifecycle script, downloads that artefact from the same run and
  checks it, then runs the pinned deploy tool. A job that only reads the platform, or rolls back to a version the
  platform already has, holds the secrets and builds nothing. In every job, a secret appears only in the `env` of
  the steps that call the platform, never at job or workflow level. A job that holds a secret uses only the host's
  own actions, pinned by full commit SHA, and restores no cache. Every place a recipe deploys follows this: preview,
  production and rollback alike. Pull requests from forks and from bots get no secrets: those runs skip cleanly.
  Agents can start a deploy workflow and read its log and summary; they never see the secrets.
- **`machine`: deploys from the developer's machine** (devices, servers, mobile signing) go through one command,
  `factory deploy`, which reads the secrets itself from the operating system's keychain, outside the agents' sandbox.
  On that path, `factory deploy`:
  1. runs only the recipe's own actions, from a clean checkout of the gated commit that it makes itself, outside every
     agent's worktree, so an agent cannot change what runs with the secrets. The recipe's code, its settings (see
     [Settings of a machine recipe](#settings-of-a-machine-recipe)) and the core's release checker
     (`.factory/bin/factory-release-check`) all come from that checkout;
  2. passes each secret only to the action that needs it, as an environment variable, and never writes it to disk;
  3. replaces every secret value in the output with `***` before anyone, agent or human, sees it;
  4. is the only command the sandbox lets through to the keychain and to the deploy hosts. Agents see its output only;
  5. runs a recipe's build step, when it has one, before it reads any secret, inside the agents' sandbox: no keychain,
     no ssh-agent socket, no route to the deploy hosts. What the build leaves is data that the recipe copies or
     uploads; `factory deploy` never runs any of it on the machine. Removing credential variables from the build's
     environment is not enough on its own. The build runs as the same user who owns the keychain and the ssh-agent,
     so outside the sandbox it could find the agent's socket, change `~/.ssh/config` or leave a process running. The
     deploy tools are the operating system's (ssh, tar, Python) and the recipe's own scripts from the checkout, so
     nothing is downloaded at run time.

  Keychain items are named `factory/<owner>/<repo>/<SECRET_NAME>`, so one machine holds the secrets of several
  projects without clashes. You put them there once, by hand (a human gate).

  **SSH keys stay in your ssh-agent.** A recipe that reaches a host over SSH authenticates through your own
  ssh-agent and SSH config, never through a secret of its own:
  - it passes `ssh` the host alias from its settings and fixed options only (`BatchMode=yes`, so SSH never asks for
    a password), and never a key file (`-i`), a config file (`-F`), an `IdentityAgent`, or a key or password in any
    form. Which key, user and port are used is the business of your ssh-agent and `~/.ssh/config`, which you set up
    once, by hand (a human gate). The key never enters the keychain items above, and `secrets` lists none for it;
  - agents get no `SSH_AUTH_SOCK` (nor `SSH_AGENT_PID`), and the sandbox lets no agent command reach a deploy host:
    only `factory deploy` runs with the socket and with a route to the hosts;
  - the recipe's own steps that run project code on the machine (a build) get neither the socket nor any variable
    named like a credential, so a build step cannot reach a host either.

### 7. Human gates

The gates themselves are the core's one list, [`human-gates.md`](human-gates.md); this rule says how a deploy honours
them. Two kinds matter here:

- **Merge-blocking gates stop the change before it reaches the default branch.** H3 (an account, a secret or money),
  H6 (a deploy that needs approval: a new target or environment, a first deploy, `approve: always`) and H8 (a store
  submission) are merge-blocking whenever the merge itself would deploy or submit, like every gate except H7. A
  release never relies on catching them later.
- **H7 (a data migration or a breaking change) is a release hold.** The pull request may merge; the review counts the
  hold in `release_hold=<n>` on its marker and lists `release hold: H7 <what>` under "Needs human". The release that
  carries it waits for a person's approval. When the production environment has `when: merge`, the merge is the
  release, so H7 is merge-blocking there and the merge waits too. The deploy still checks, as a second line.

A deploy waits for your OK, whatever `approve` says, when any of these holds:

- it is **the first deploy to a new target or environment** (the platform has nothing there yet), or the live version
  was not deployed by the factory (the first switch-over);
- the environment has `approve: always`;
- **a pull request merged in the release range recorded an H7 release hold**: any review marker on it, wherever it
  sits, has a `release_hold=` other than 0 (an unreadable count holds too), or a `release hold: H7 …` line appears in
  its description or in a comment by a person;
- **any commit** in the release range touches **a migration path** (the paths the recipe's settings name as
  migrations: those of stored data on the server, and those that set a client-side stored-data version, rule 4),
  even when a later commit reverts it, since the migration may already have changed stored data; or
  carries **a breaking change** (a commit marked `!` or `BREAKING CHANGE:` under the conventional commit rule, or a
  revert of such a commit: undoing an incompatible change is incompatible too). These supplement the recorded holds,
  they never replace them: the reviewer's H7 hold is the record that counts, the commit text is a second line;
- **Every such check reads one normalised view of the range,** so that no check sees less than another:
  - *every commit* in the range, not only the first-parent line: the commits of a branch merged without squashing,
    and merge commits nested inside it;
  - *one complete set of changed paths*: each non-merge commit against its parent and each merge commit, nested or
    octopus, against its first parent (what the merge brought in, plus anything edited in the merge itself), read
    raw from git rather than from its quoted display, and compared with the migration paths in one Unicode form
    and case;
  - *one normalised text per message*: every kind of line break counts as one (CR, LF, CRLF, VT, FF, NEL, U+2028,
    U+2029 and other control characters), compatibility forms and accents are folded, invisible characters dropped,
    and common Cyrillic and Greek look-alikes of Latin letters, `!` and `:` mapped. In that text, `type!:` anywhere
    on a line (a squash or merge commit lists its commits in its body) and the words "breaking change" anywhere
    mark a breaking change; so does a pull request title that says so when its squash message no longer does;
- **When in doubt, it holds.** These readings are loose on purpose, so they hold more than strictly needed: a
  negative sentence ("no breaking changes"), or a branch that merged the default branch into itself and so carries
  migrations that are already live. A recipe lists its known false holds and refusals, and how to clear each, in
  its README. A false hold costs one approval; a missed one could cost data;
- it needs **an account, money or a signing key** that is not set up yet;
- it is **a store submission** (every one, decision 24; test builds go out after a green gate without waiting).

How waiting works:

- A deploy that must wait does not fail. It stops before anything changes, opens (or updates) one issue labelled
  `status:needs-human` that names the target, the environment, the commit, the reasons and the release notes, and
  ends green with "held" in its summary. Holding never turns the default branch red, so merges continue.
- You approve **one commit**: the approval carries the released commit's **full** 40-character SHA (a prefix could
  match another commit), so it never covers a later commit by accident, and it covers every reason the held issue
  lists for that commit. The deploy run that carries it links it
  on each pull request whose H7 hold it resolves and on the held issue (`<!-- factory:release-approved target=<t>
  env=<e> sha=<SHA> -->`), as `human-gates.md` asks. An approval for another commit counts for nothing. A held
  release stays held, night after night, until you approve it or a later approved release replaces it.
- **Before you approve a migration**, as the plan requires: the migration has run first on real-shaped data (a
  staging environment or a copy of production data), and a backup of the production data is taken right before it
  runs. The held issue lists these as a checklist. A recipe that does not apply migrations itself says so, and the
  person applies the migration as rehearsed. A release whose range has a migration, an H7 hold or a breaking change
  is never rolled back automatically (rule 3): a rollback would not undo the data, and the held issue says so. Past
  a client-side stored-data version bump, a rollback would also lock out every client that opened the release
  (rule 4), so a bad release there is fixed forward.
- You give the OK yourself, in the native tool (decision 13): on GitHub (Actions → the deploy workflow → Run workflow,
  with the SHA in its approve field) or in your terminal with `factory deploy <target> <env> --approve <sha>`, which
  needs an interactive terminal. Agents never pass an approval: the `PreToolUse` hook blocks an agent command that
  carries one, and `factory deploy` refuses `--approve` without a terminal. The agents share your GitHub identity, so
  GitHub alone cannot tell your OK from an agent's; the hook and the terminal check are the guard (decision 17).

## How a recipe declares itself

Each recipe folder holds:

| File | Holds |
| --- | --- |
| `recipe.yaml` | The manifest below. `factory doctor`, `factory-init`, `factory deploy` and the gate read it. |
| `README.md` | For you and the lead: what the recipe does, its `with` keys, the steps only you can do, the manual command per environment, how to roll back, and what its rollback does not restore. |
| `templates/` | Files `factory-init` renders into the project (CI workflows for `runs_on: ci`). |
| `bin/` | Helpers the templates or actions call, installed under `.factory/recipes/<recipe>/bin/`. |
| `tests/` | The recipe's own tests (stubs only, never a real platform call). Never installed into a project. |
| `SOURCES.md` | Only when the recipe vendors third-party files. |

### `recipe.yaml`

```yaml
recipe: <name>                 # same as the folder name
contract: 2                    # the version of this contract the recipe meets
summary: <one line>
runs_on: ci                    # ci | machine: where deploy, smoke check and rollback run, so where secrets live
environments:                  # the environments it supports, with the triggers each supports
  preview: [pr-label]
  production: [manual, merge, nightly]
needs_url: [production]        # environments whose `url` must be set
with:                          # its settings: a small JSON Schema subset (type, required, default, items, pattern, description)
  <key>: { type: string, required: true, description: ... }
secrets:                       # names only, never values
  - { name: <NAME>, where: github-actions | keychain, why: <what it allows> }
migrations_key: <with key>     # the `with` key that lists migration paths (rule 7), if the platform has stored data
actions:                       # what `factory deploy` runs; for `ci`, workflow dispatches
  deploy: <command>
  approve: <command>           # the deploy with an approval; only you run it (rule 7)
  rollback: <command>
  status: <command>
  preview: <command>           # when it supports preview
templates:                     # what factory-init renders, and where
  - { from: templates/<file>, to: <path in the project>, for: <environment> }
ci_jobs: [<job name>, ...]     # deploy jobs in CI: never required checks, never part of "main is green"
human_steps: [<one-time step only you can do>, ...]
```

What each reader does with it:

- **`factory doctor`** validates the target's `with` against `with`, checks that every environment and trigger is in
  `environments`, that every environment in `needs_url` has a `url`, that the rendered templates match the current
  `factory.yaml` (a drifted workflow is a finding), and that no value looks like a secret.
- **`factory-init` and `factory-update`** render `templates` for each target that uses the recipe, and list
  `human_steps` and `secrets` for you to do once. Re-rendering after a `factory.yaml` change is a normal PR.
- **`factory deploy <target> <env> [--rollback [<version>]] [--approve <sha>] [--status]`** runs the matching action.
  For `runs_on: ci` the actions dispatch the recipe's workflows on the default branch and follow the run, so the
  secrets stay in CI. For `runs_on: machine` it runs them under the rules in rule 6.
- **The merge gate** ignores `ci_jobs`: a deploy job is never a required check, and a failed or held deploy never
  makes the default branch red. Production failures surface as `priority:P1` bugs instead (rule 3).
- **The lead** reads `README.md` when it must deploy, roll back or explain a held release, and mentions a manual
  command only when the automatic path is unavailable (for example while CI is refused for billing).

### Settings of a machine recipe

A `runs_on: ci` recipe's settings end up in its rendered workflow files. A `runs_on: machine` recipe has no workflow,
so its settings for each target live in **`.factory/deploy/<target>.yml`**:

- `factory-init` renders the file from the target's entry in `factory.yaml` (a `templates` entry of the recipe,
  `to: .factory/deploy/__FACTORY_TARGET__.yml`), and re-renders it whenever `factory.yaml` changes, in the same pull
  request; `factory doctor` reports a file that no longer matches, like a drifted workflow. Nobody edits it by hand.
- It holds one `key: 'value'` line per render value, single-quoted under the rendering rules below (lists and maps as
  JSON inside the quotes), and comments. It names its own target, environment, repository and default branch. Like
  `factory.yaml`, it never holds a secret value: names only (rule 6).
- **The recipe reads it only from the clean checkout being deployed** (the gated commit `factory deploy` checks out,
  rule 6), never from `factory.yaml`, a working tree, an agent's worktree, the command line or the environment. So a
  settings change reaches a target only through the gate, and changing `factory.yaml` is gate H4.
- The recipe checks every value again when it reads the file (types, patterns, ranges), and refuses, changing
  nothing, a file that is missing, does not parse, holds an unknown or repeated key or a placeholder that was never
  rendered, misses a required value, or names another target.

### Rendering rules for templates

So that one renderer serves every recipe, and the templates stay valid YAML before rendering:

- A value placeholder is `__FACTORY_<NAME>__`, and it always sits inside a single-quoted string: a YAML string, or a
  string inside a GitHub expression. Both escape `'` by doubling it, so the renderer doubles any `'` in the value.
  Lists and maps are rendered as JSON inside that string. Workflow scripts read values from `env`, never from a
  placeholder inside a `run` script, so no value can inject shell code.
- A block placeholder is a line holding only `# __FACTORY_<NAME>__`. The renderer replaces the whole line with the
  rendered block at the same indentation, or removes it when the block is empty.
- The recipe lists every placeholder, where its value comes from and its default, under `render` in `recipe.yaml`.
- Every action a template uses is pinned to a full commit SHA, with its version in a comment
  (`uses: owner/action@<40-char SHA> # v1.2.3`), so a moved tag never changes what runs next to the secrets. Updating
  a pin is a reviewed change to the recipe; adding a new action is gate H2.
- Rendered values are part of the workflow file, so changing them needs the `workflow` permission that agents do not
  get by default (decision 17). A pull request cannot redirect a deploy by editing `factory.yaml` alone.

## Changing this contract

A change to this file is a change to the core: a PR to the factory repo, reviewed like any other. Raise `Contract
version` when a recipe would have to change to keep meeting it, and update every recipe in the same PR or open an
issue per recipe.
