# Recipe: `cloudflare-workers`

Deploys a Cloudflare Worker (a script, static assets, or both) from GitHub Actions with wrangler, under the
[deploy contract](../../reference/deploy-contract.md) (contract version 2):

- **preview**: on a pull request that carries a label, its head commit (not GitHub's merge commit) is built and
  uploaded as a version under a preview alias (`pr-<N>`), smoke-checked, and its URLs commented on the PR.
  Production traffic never changes.
- **production**: on the environment's trigger (`manual`, `merge` or `nightly`), the gate is proven for every commit
  since the live one, holds are honoured, and the commit is built (in a job without secrets), deployed (in a job that
  runs no project code), smoke-checked, rolled back automatically if the check fails, and described in release notes
  headed with its version, which is then recorded on the commit as the tag `factory/<target>/v<X.Y.Z>`.
- **rollback**: one command, using wrangler's own `rollback`. No rebuild.

Secrets stay in GitHub Actions (`runs_on: ci`). Agents start the workflows and read their summaries; they never see a
token. A job that holds a secret never runs the project's setup, build or any package install: the project's code
runs in a separate build job, which holds no secret, and the deploy uses wrangler pinned by version and checksum (see
[Security notes](#security-notes)). The manifest is [`recipe.yaml`](recipe.yaml).

Lead: read this file before you deploy, roll back or explain a held release. Mention a manual command to the user only
when the automatic path is unavailable, for example while Actions is refused for billing.

## Settings

```yaml
# factory.yaml
deploy:
  web:                              # the target name: any name
    recipe: cloudflare-workers
    with:
      worker: my-app                # required
      build: npm run build          # optional
      smoke: [/, /health]           # optional, default [/]
    environments:
      preview:    { when: "pr-label:preview" }
      production: { when: nightly, url: https://app.example.com }   # url is required for production
```

| `with` key | Default | Meaning |
| --- | --- | --- |
| `worker` | required | The production Worker's name. Every wrangler call passes it as `--name`, so a pull request that edits the Wrangler config cannot point a deploy at another Worker. Previews upload versions of this same Worker. |
| `build` | none | Command that builds what wrangler uploads (such as the assets folder). Runs after `commands.setup`, in the build job, which holds no secret. Leave it empty when wrangler bundles the Worker on its own. The Wrangler config must not have a custom build (`build.command`): the deploy refuses it, because wrangler would run it next to the secrets. |
| `config` | wrangler's own lookup in the repo root | Path of the Wrangler config file, relative to the repo root. |
| `smoke` | `[/]` | URL paths that must answer with a 2xx status after every deploy and rollback (redirects followed, 6 tries 5 s apart). |
| `migrations` | `[]` | Glob list of the paths whose change means a data migration, such as the D1 migrations folder. List the files that set a client-side stored-data version too: the module declaring an IndexedDB schema version (`**/*schema.*`), the code writing a local file format's version (`**/*format*.*`), the service worker or app-cache manifest (`**/service-worker.*`, `**/*.webmanifest`). A release or rollback with **any commit** in its range touching them (even one a later commit reverts) waits for your OK, and a failed release is not rolled back automatically. |
| `changelog` | none | Path of a changelog file. When it changed in the range, its added lines are the release notes; otherwise the notes list the merged pull requests. |
| `node_version_file` | the runner's Node | The file `actions/setup-node` reads the build job's Node version from, such as `.nvmrc`. The pinned wrangler bundles the Worker there, so it must be Node 22.12 or later. The jobs that hold the secrets use Node 24. |
| `rollback_on_failure` | `true` | Roll back automatically when the production smoke check fails and the release carried nothing that needed your OK (no migration, H7 hold or breaking change). Turn it off only when the Worker writes stored data in a shape the previous version cannot read. |

Supported environments and triggers: `preview` with `pr-label:<label>`; `production` with `manual`, `merge` or
`nightly`. `approve: first` (the default) or `always` work as the contract says. **Staging is not supported yet**: the
first project that needs it extends this recipe (a staging Worker needs its own name, and `--env` must never be
combined with `--name`, which would deploy to production). **Workers Sites** (`site` in the Wrangler config) and
**containers** (`containers`, whose image wrangler would build during the deploy) are not supported.

What the Worker may be: a module Worker that wrangler bundles from `main`, static assets (`assets.directory`), or
both. The build job bundles it (`wrangler deploy --dry-run --outdir`), and the deploy uploads that bundle as it is
(`--no-bundle`), so nothing is bundled or built where the secrets are. The assets directory must not be the config's
own folder or one above it, nor be inside `.git`, `.github`, `.factory`, `.wrangler` or `node_modules`.

wrangler deploys from a **release tree**, a folder apart from the checkout. It holds a copy of the checked Wrangler
config and the build's assets, each at its own path, and nothing else. So relative paths in the config reach only
those two things, and a `.env` file in the repo is not read during a deploy: the account and the token come from the
workflow's secrets.

## What gets installed

`factory-init` renders these from [`templates/`](templates/), filling in the target's settings, and re-renders them
when `factory.yaml` changes (`factory doctor` reports a workflow that no longer matches):

| File in the project | From | For |
| --- | --- | --- |
| `.github/workflows/factory-preview-<target>.yml` | `templates/preview.yml` | `preview` |
| `.github/workflows/factory-deploy-<target>-production.yml` | `templates/production.yml` | `production` |
| `.github/workflows/factory-rollback-<target>.yml` | `templates/rollback.yml` | `production` |
| `.factory/recipes/cloudflare-workers/bin/` | `bin/` | all of them |
| `.factory/recipes/cloudflare-workers/deploy-tool/` | `deploy-tool/` | all of them: npm's manifest and lockfile of the pinned wrangler, as `manifest.json` and `lockfile.json` |

The workflows also call the core's release checker, `.factory/bin/factory-release-check` (from
`core/bin/factory-release-check`), which every project gets with the core and every recipe shares. They never run
the copy in the checkout being released, which is part of what is under proof: the release job reads the checker
from git out of the live commit (when it is known and on the released commit's first-parent line; a known live commit
off that line refuses) or, for a first release, out of the released commit's first parent, and the rollback workflow
out of the live commit (the restored commit's only when the live one is unknown; with none usable, the rollback
holds). Each time it is written to a new folder and started isolated, with `python3 -I`. A change to the checker is
judged by the old one and judges from the next release on.

The scripts need only what GitHub's Ubuntu runners have: bash, curl, jq, git, python3, the `gh` CLI and Node.

| Script | Does |
| --- | --- |
| `versions.sh` | Reads the live version, the previous one and a version's tag and full commit from Cloudflare, accepting only values in a strict character set. |
| `.factory/bin/factory-release-check` (core) | `check`: is every commit in the range gated, in time order (`--prove`), did a pull request in it record an H7 hold (`--holds`), does any commit, nested merges included, touch a migration path or break compatibility? `notes`: the release notes. Git, plus `gh api` for the pull requests. |
| `deploy-tool.sh` | Installs the pinned wrangler in an empty folder: checks the sha256 of `deploy-tool/manifest.json` and `lockfile.json` against the workflow's pins and that every package has a registry tarball with a sha512 integrity, runs `npm ci --ignore-scripts` with a clean environment and its own empty cache, checks the installed version, and sets `WRANGLER`. The only way the workflows get wrangler. |
| `wrangler-config.py` | Reads the Wrangler config (JSON, JSONC or TOML) for the config path, the entry's name and the assets directory. Where the secrets are (`check`), it refuses a custom build, a redirected config, Workers Sites, containers, and an assets directory that could sit beside the config or inside `.git`, `.github`, `.factory`, `.wrangler` or `node_modules`. |
| `artefact.py` | `pack` (build job): the bundle, the assets and a manifest of target, commit and run in one tar. `unpack` (deploy job): checks the digest and the manifest, reads every member first (plain files and folders under `worker/` and `assets/` only, no links, no `..`), writes them outside the checkout, then builds the release tree: a copy of the checked config, made before any artefact byte is written, and the assets at the config's assets path. It prints the entry, the config copy and the tree. It never writes into the checkout, so every script a later step runs stays the gated commit's. |
| `smoke.sh` | The smoke check. |
| `issue.sh` | Opens or updates one issue per marker (held release, failed release), comments on it, and closes it. |

`tests/` holds the recipe's own tests, which factory-init never installs: `python3 -m unittest discover -s
recipes/cloudflare-workers/tests -v`. They build throwaway git repositories and stub every GitHub, Cloudflare and
wrangler call (with the core checker's GitHub stub, which follows GitHub's pagination, check-run and
combined-status shapes), and they run the decision steps of the workflow templates as they are, with the core
checker. `test_attacks.py` runs the attacks through those steps: what is live, inputs and outputs, the fourth
review's regressions and the automatic rollback's safety. `test_job_split.py` renders every template for every
trigger and reads each one as a parsed YAML tree (with Ruby's YAML parser; the test fails without ruby, and fails on
aliases, tags, repeated or unknown keys). A job that holds a secret must be a closed subset, written by hand in the
test and never read from the templates. That covers its env at every scope (each key with its exact value, no scope
repeating an outer key, every code path resolving to the checkout), its actions (one exact commit each, exact `with:`
values), its job keys, and each of its steps, approved by the sha256 of the whole step, because nothing here parses
bash or GitHub expressions. The earlier rules hold on top of that: every action pinned to a full commit SHA, a fresh
GitHub-hosted machine per job, no setup, install or build step where a secret is, the pinned tool installed before
any wrangler call or artefact, the artefact checked before it is deployed, and the deploy run from the release tree.
The build jobs hold no secret, and the pins are the committed lockfile's. Each rule has a negative case. Two
end-to-end cases run the templates' own steps on artefacts whose assets are named like the recipe's scripts. The first
checks that the later steps still run the checkout's scripts; the second, that a step env pointing `RECIPE` at the
release tree is refused. **Changing a step of a job that holds a secret** therefore takes two edits in one pull
request: the template, and the step's new digest in the test's `APPROVED_STEPS` (the failure prints it). It also runs `deploy-tool.sh` (with a stub
`npm`: nothing is downloaded), `artefact.py` and `wrangler-config.py` against forged inputs.

The release checker's own tests are in the core: `python3 -m unittest discover -s core/bin/tests/factory-release-check
-v`. Its `test_check_attacks.py` walks every rule through every attack class (identity, markup, freshness, encoding,
pagination, partial input, output injection) and through the two invariants every check rests on: one normalised
view of a range (all line breaks, all commits, all paths) and time-ordered proof (each record in force when relied
on, and not contradicted by anything still visible). No aggregate may mask one item: each check and status context
is judged on its own, and each kind of finding counts for the rollback decision. A change to a rule adds its attacks
there.

## Steps only you can do, once

1. **Cloudflare token.** In the Cloudflare dashboard, create an API token from the "Edit Cloudflare Workers" template,
   limited to the one account (and to no zone, unless the Worker serves routes on one).
2. **Repository secrets.** Add `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` under the repository's Settings →
   Secrets and variables → Actions. Never paste them into a chat, a file or an issue.
3. **Preview URLs.** If the target uses previews, set `"workers_dev": true` and `"preview_urls": true` in the Wrangler
   config.
4. **Labels.** The workflows label issues `status:needs-human`, `type:bug`, `priority:P1` and `priority:P2`, and the
   preview label must exist. `factory-init` creates the core labels; without them, issues open unlabelled with a
   warning.
5. **First release.** The first production run holds, because the Worker does not exist yet (or, for a Worker that
   already runs, because its live version names no commit). It opens an issue; approve it as described there.

## How a production release runs

1. **The commit.** A `nightly` release takes the commit the green nightly run tested; `merge` and `manual` releases
   take the default branch's commit.
2. **What is live.** The live commit is known only when the live version's message is the factory's own
   (`factory <target> production <full SHA>`), its tag is that SHA's first 12 characters, and the commit is in this
   history; while traffic is split between versions it is unknown too, and an unknown live commit holds. If this
   commit, or a newer one, is already live, the run ends green: nothing to do. This is also what makes an unchanged
   nightly a no-op.
3. **Gate proof, for every commit since the live one** (only this commit when the live one is unknown), in time
   order (the contract's rule 2). Each must be the exact merge commit of a pull request into the default branch, and
   on that pull request:
   - the gate record in force at the merge (`<!-- factory:gate ... -->`, written by `factory gate` before it
     merges) is for the final head, says `result=pass`, and no gate marker is later than it;
   - the merge commit has the recorded base as parent and the gated head's tree;
   - the checks as they stood when the gate record was written back it, each on its own: for every check (by app
     and name) and every status context, the latest attempt finished by then passed, none was still running then or
     at the merge, and none has failed since. One green check never stands in for another. Local evidence (an
     `<!-- factory:evidence ... -->` record written before the gate record) counts only where CI did not run, and
     never overrides a CI job that ran and failed or was running;
   - the review in force when the gate record was written is of that exact head with verdict `merge` and nothing
     open, and every review marker since says the same. A review posted afterwards cannot complete the chain.

   A record that proves counts only as a comment's first line (or the line after a first-line heading), exactly in
   its format, in a comment never edited, from a User account with write, maintain or admin permission (looked up,
   not taken from the author association). A marker that contradicts counts wherever it is and whoever wrote it,
   as long as it is still visible: one that was edited out or deleted leaves nothing to inspect (that is how a
   mistaken marker is cleared, see [False holds and refusals](#false-holds-and-refusals)).
   Otherwise the run stops red with "Not gated" and changes nothing. A shallow clone refuses too.
   Today the lead writes the evidence and gate records by hand at the merge gate (`core/reference/merge-gate.md`,
   step 6); a pull request merged without them refuses here.
4. **Hold or go.** The run holds when the Worker does not exist, the live version names no commit the factory knows,
   the environment has `approve: always`, a pull request in the range recorded an H7 release hold (a review marker's
   `release_hold=` or a `release hold: H7 …` line), or any commit in the range has a breaking change or touches
   `migrations`. Both are read from one normalised view of the whole range: every commit (also those of a branch
   merged without squashing, and merges nested in it), every changed path (each merge against its first parent,
   read raw from git), and each message as one text in which every kind of line break, Unicode form and common
   look-alike reads the same. `type!:` anywhere on a line, the words "breaking change" anywhere, or a pull request
   title that says so, mark a breaking change. This reading holds more than strictly needed; see
   [False holds and refusals](#false-holds-and-refusals). Holding changes nothing, opens or updates one
   `status:needs-human` issue with the reasons, the release notes and, for a migration or H7 hold, the checklist
   (rehearsed on real-shaped data, backup before), and ends green. Your approval names this commit's full SHA; the
   run then links it on each held pull request and on the issue.

   **The version.** The same run of the release checker ends with the version this release gets (the contract's
   rule 5): from the highest version ever recorded for the target, a breaking change raises the major, any `feat` the
   minor, anything else the patch; the first release is `1.0.0`. A range that cannot be shown, after a recorded
   version, raises the major. The run refuses when the checker gives no version. The release notes, in the held
   issue and in the summary, are headed `## <version> (<date>)`, then the range.
5. **Build, then deploy, in two jobs.** The build job checks out the commit, runs `commands.setup` and `with.build`,
   and bundles the Worker with the pinned wrangler (`deploy --dry-run --outdir`). It holds no secret, and its token
   can only read the repo. It uploads one artefact: the bundle, the assets directory and a manifest naming the
   target, the commit and the run. The deploy job holds the secrets and runs no project install, build or lifecycle
   script. It checks out the same commit, installs the pinned wrangler, downloads that run's artefact and checks it
   (`artefact.py unpack`, with the config checked by `wrangler-config.py check`) into the release tree. Then
   `wrangler deploy <bundle> --no-bundle`, run in that tree with the config's copy, uploads and deploys it, tagged with the commit's first 12 characters and with the full SHA in its
   message, so every version names its commit in full. A failed build skips the deploy and opens the P2 bug below.
6. **Smoke check** against `environments.production.url`.
7. **On failure:** roll back to the version that was live before, check again, open a `type:bug` `priority:P1`
   issue that names the release version it left (not recorded) and the one it returned to (or says that one had
   none), fail the run. The run summary says the same. The automatic rollback is skipped when `rollback_on_failure` is off, when no earlier version
   exists, and **whenever the release needed your OK for what it carries**: a migration path, an H7 hold, a breaking
   change, or a range that could not be shown. Old code may not work with what the new version changed, and your
   approval to release does not cover putting it back; the bug then says so, and a manual rollback asks for its own
   approval. A failure before the smoke check (setup, build, the artefact check, deploy) opens a `priority:P2` bug
   instead: production most likely did not change.
8. **On success:** release notes in the run summary, and the held-release issue, if any, is closed. Then a last job,
   `Release version`, records the version as the lightweight tag `factory/<target>/v<X.Y.Z>` on the released commit,
   through GitHub's API. The factory's own prefix and the target's name keep it apart from the project's own tags and
   from other targets. That job holds no secret, checks out nothing and runs one reviewed step; its token may write
   the repository's contents, for the tag. When the tag cannot be created (a tag ruleset, or a tag of that name on
   another commit), the job fails and says so: the release stays live without a version, and the next release counts
   from the highest recorded one. A tag ruleset on `factory/**` must let the workflow's token create tags.

The merge gate never counts these runs: they are deploy jobs (`ci_jobs` in the manifest), not checks.

## False holds and refusals

The release fails closed: when it cannot decide, it holds (you approve) or refuses (red). These are the cases known
to hold or refuse although nothing is wrong, and how to clear each.

| What you see | Why | To clear it |
| --- | --- | --- |
| `breaking:` for a commit that breaks nothing | Its message, or the pull request's title, has `word!:` on some line or the words "breaking change", also in a negative sentence (`BREAKING CHANGE: none`, "no breaking changes") or a template heading copied into a squash body. | Approve the held commit. Keep such lines out of commit messages. |
| `migration:` for a migration that is already live | A branch merged the default branch into itself and was then merged without squashing: that nested merge carries everything the default branch had gained, read against its first parent. | Approve the held commit. Squash merges (the core's method) never do this. |
| `migration:` for a file that is not a migration | Its path matches the `migrations` globs after case and Unicode folding, or with `\` read as `/`. | Approve, or narrow the globs with a `!` entry. |
| `hold:` for a hold that was already settled | Hold lines and `release_hold=` counts are read from the whole pull request, whoever wrote them, quoted or not. The approval always comes with the deploy run, for one commit. | Approve the held commit. |
| "Not gated … a review marker later than the review in force" or "a gate marker was written after…" | A later comment, review or the description contains a `factory:review`, `factory:gate` or `factory:evidence` marker that is not a clean result for this head: a quoted example, an old marker pasted back, an edit. | Edit that text out of the comment, or delete the comment. |
| "Not gated … no review record written before its gate record" | The review, gate or evidence comment was edited (an edited comment proves nothing), posted in the wrong order, or the gate ran before the review. | Before the merge: post the record again, in order. After the merge it cannot be repaired; see below. |
| "Not gated … do not back the gate record" | A check or status on the head, any one of them, failed or was still running when the gate record was written or at the merge, or failed on a later re-run. Also: a failed job was "fixed" by starting a new workflow run (a failure is only superseded by a re-run of the same run); a status was first reported after the gate record without a `pending` before it. | Before the merge: re-run the failed run itself, wait for every check, and gate again. After: see below. |
| A failed release was not rolled back automatically | It needed your OK for a migration, an H7 hold, a breaking change (also a false `breaking:` hold above) or an unknown range, so old code may not be safe to restore. | Decide yourself: `factory deploy <target> production --rollback`, which asks for its own approval. |
| "could not be checked" | GitHub could not be read (an error, a short page, a missing time). | Run the release again. |

**A commit that can never be proven** (it merged outside the gate, or its records were broken after the merge) blocks
every release whose range contains it; no approval overrides a refusal. The way out is yours alone: check the code
yourself, then deploy that tip by hand from your own terminal, with the tag and message the workflow uses. Do it the
way the workflow does: build and bundle first, in a shell without the token (`wrangler deploy --dry-run --outdir
out`), then, in a fresh shell with the token and the pinned wrangler (`bin/deploy-tool.sh`, as in
[Testing the recipe](#testing-the-recipe-on-a-throwaway-worker)), `wrangler deploy out/<entry>.js --no-bundle --name
<worker> --tag <first 12 of the SHA> --message "factory <target> production <full SHA>"`. The live commit is then
past it, and the next release starts from there.

## Manual commands

What `factory deploy` runs for this recipe, for when you or the lead need it by hand. Run on the default branch
(`main` below stands for it).

| Want | Command |
| --- | --- |
| Release production now | `factory deploy <target> production`, or `gh workflow run factory-deploy-<target>-production.yml --ref main` |
| Approve a held release (you only) | `factory deploy <target> production --approve <full sha>`, or the same `gh workflow run` with `-f approve=<full 40-character sha>`, or Actions → Run workflow |
| Roll back production | `factory deploy <target> production --rollback`, or `gh workflow run factory-rollback-<target>.yml --ref main -f reason="<why>"` |
| Roll back to one version | add `-f version=<version id>` (ids are in each run summary and in the Cloudflare dashboard) |
| Preview a pull request | add the preview label: `gh pr edit <N> --add-label <label>` |
| See what is live | `factory deploy <target> production --status`: the latest deploy and rollback runs and their summaries |

## Rolling back

`wrangler rollback` switches traffic to a version Cloudflare already holds. Without a version id, the workflow picks
the version of the newest earlier deployment that ran another version, and passes that id explicitly, so the summary
says exactly what came back: the release version recorded on its commit (`release 1.4.0`, or "a release without a
version" for one released before versions, or whose tag could not be created), its Cloudflare version id and its
commit, and the same for the version it leaves. The held issue names both too. A rollback records no version.

**What a rollback does not restore:** D1 databases, KV, R2, Durable Objects, Queues and any other bound resource
(wrangler says so itself), and secrets changed since that version. That is why a rollback holds for your OK, with
that warning, when any commit in the range it undoes touches `migrations`, breaks compatibility, or belongs to a pull
request with an H7 release hold, and also whenever that range cannot be shown (an untagged version, versions out of
order, pull requests that cannot be read), whatever `migrations` says. The issue says how to give the OK: the live
version's full version id (or full commit SHA) in **approve**, never a prefix.

**Client-side stored data does not come back either.** When the range raises a stored-data version that browsers
keep (an IndexedDB schema version, a local file format, an app-cache manifest), every browser that opened the live
version has upgraded its local data. The restored build refuses to open it ("newer version"), and a reload does not
help, since the service worker now serves the restored build. The rollback itself is then the outage. List those
files under `migrations`, so such a rollback holds; its issue says that devices that opened the live version keep data
the old build can't read, and approving accepts that. **Prefer a roll-forward**: a fix released on top of the live
version keeps the newer stored-data version. Roll back across the bump only when the new build cannot run at all.

The lead may start a rollback without asking when the range has no migration: it restores a version that was already
live.

## Security notes

- **Secrets never share a job with third-party code** (deploy contract, rule 6). The jobs that run the project's
  setup and build (`Preview build`, `Release build`) hold no secret and can only read the repo. `Release version`
  holds no secret either and runs no project code: its token may write contents, to create the version's tag. The
  test guard allows that one job only, exactly as reviewed. The jobs that hold
  the secrets (`Preview`, `Release`, `Release deploy`, `Rollback`) run no project install, build or lifecycle
  script. They run only GitHub's own pinned actions (checkout, setup-node without a package cache,
  download-artifact), the recipe's scripts from the commit's checkout, the core's release checker from the live commit
  or the first parent (never the checkout's own copy, see above), and the pinned wrangler. In those jobs the secrets appear only in the `env` of the steps that call Cloudflare.
- **The deploy tool is pinned by version and checksum.** `deploy-tool/lockfile.json` (npm's lockfile) pins wrangler and every
  package it pulls in, each by its registry tarball and sha512 integrity. The workflows pin the sha256 of that
  lockfile and of `manifest.json` (`DEPLOY_TOOL_*`). `deploy-tool.sh` refuses anything else, and `npm ci
  --ignore-scripts` checks every tarball before any of it can run and runs no install script. There is no `npx`,
  and no wrangler other than this one. `WRANGLER` is set only by the install step, so a step that runs wrangler
  before it fails.
- **The artefact is untrusted data.** The build job ran third-party code, which could have written anything into
  it. The deploy job installs wrangler before the artefact arrives. It accepts only this run's artefact, with the
  build job's digest, this target and this commit, and plain files under `worker/` and `assets/`. It writes them
  only outside the checkout. The bundle goes to its own folder; the assets go into the release tree, next to a copy
  of the config made from the gated checkout before any artefact byte is written. wrangler runs in that tree. The
  checkout is never written to, so the recipe's scripts and everything else a later step runs
  stay the gated commit's, even if the artefact's assets are named like them. The workflows also set
  `CLOUDFLARE_API_BASE_URL` explicitly, as the host wrangler sends the token to.
- **No custom build where the secrets are.** wrangler runs a config's `build.command` before every deploy, even with
  `--no-bundle`, and builds the image of `containers`. The deploy refuses such a config; use `with.build`.
- The rendered workflows hold the Worker name and the other settings, so changing them needs the `workflow`
  permission, which agents get only for CI tickets. A pull request that edits `factory.yaml` alone changes no deploy.
- Fork and bot pull requests get no previews (they get no secrets either).
- Every action is pinned to a full commit SHA with its version in a comment (`actions/checkout` v7.0.1,
  `actions/setup-node` v7.1.0, `actions/upload-artifact` v7.0.2, `actions/download-artifact` v8.0.2), so a moved tag
  never changes what runs next to the secrets.
- Remaining risks: a malicious dependency can still change **what is deployed**, because the build job makes the
  bundle and the assets. Review and the licence gate cover that, as they cover the code itself. It can no longer
  reach the token. A preview runs the workflow and the recipe's scripts from the pull request's own head, as GitHub
  does for every `pull_request` workflow. A same-repo pull request is reviewed code, but not yet gated code.

## The deploy tool

wrangler is not a setting: the recipe pins one version, `deploy-tool/lockfile.json` pins its whole tree, and the
three templates pin the lockfile (`DEPLOY_TOOL`, `DEPLOY_TOOL_PACKAGE_SHA256`, `DEPLOY_TOOL_LOCK_SHA256`). To move to
another wrangler, change the recipe in the factory, never in a project:

1. In an empty folder, write the new exact version into a copy of `deploy-tool/manifest.json` under npm's manifest
   name, and run `npm install --package-lock-only --ignore-scripts --cache <empty folder>`. It reads the registry's
   metadata only: it installs nothing and runs no package code.
2. Read the lockfile's diff: new packages, their licences, and the ones with an install script (never run here).
3. Copy both files back to `deploy-tool/` as `manifest.json` and `lockfile.json`, and put the new version and the
   two sha256 sums in all three templates. `tests/test_job_split.py` fails until the templates, the files and the
   lockfile's version agree.

## Testing the recipe on a throwaway Worker

Needs a Cloudflare account and a token, so only you can run it. About 15 minutes. Run it in your own terminal, never
in an agent session, and paste only the outputs (they hold no secret) into the issue.

The steps are written for bash. In zsh (the macOS default) `$WRANGLER` is not split into words, so the command
fails with "no such file or directory", and a `#` comment typed at the prompt is an error. Type `bash` first and run
every step inside that shell.

1. Create a token as in "Steps only you can do" and export it in that terminal only:
   `export CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=...`
2. Install the pinned wrangler the way the workflows do, into an empty folder, with the pins of
   `templates/production.yml`:

   ```sh
   R=<path to this recipe>/bin
   eval "$(sed -n "s/^  \(DEPLOY_TOOL[A-Z0-9_]*\): '\(.*\)'$/export \1=\2/p" "$R/../templates/production.yml")"
   bash $R/deploy-tool.sh install /tmp/factory-deploy-tool   # prints WRANGLER=node /tmp/factory-deploy-tool/...
   export WRANGLER="node /tmp/factory-deploy-tool/node_modules/wrangler/bin/wrangler.js" WRANGLER_SEND_METRICS=false
   ```

3. Make a throwaway Worker with an asset:

   ```sh
   mkdir -p /tmp/factory-rollback-test/public && cd /tmp/factory-rollback-test
   printf '{ "name": "factory-rollback-test", "main": "index.js", "compatibility_date": "2026-11-01", "workers_dev": true, "assets": { "directory": "public" } }\n' > wrangler.jsonc
   ```

4. Deploy two versions exactly as the workflows do: bundle first (`--dry-run --outdir`, as the build job), then
   deploy that bundle as it is (`--no-bundle`, as the deploy job), tagged and described as the production workflow
   does (two made-up commit SHAs):

   ```sh
   C1=1111111111111111111111111111111111111111 C2=2222222222222222222222222222222222222222
   for v in 1 2; do
     C=$([ $v = 1 ] && echo $C1 || echo $C2)
     echo "export default { fetch: () => new Response(\"v$v\") }" > index.js; echo "asset v$v" > public/hello.txt
     rm -rf out && $WRANGLER deploy --dry-run --outdir out --name factory-rollback-test --config wrangler.jsonc
     $WRANGLER deploy out/index.js --no-bundle --name factory-rollback-test --config wrangler.jsonc \
       --tag "${C:0:12}" --message "factory test production $C"
   done
   URL=<the URL wrangler printed>
   curl -s "$URL"; curl -s "$URL/hello.txt"          # expect v2, then asset v2
   ```

5. Check the scripts the workflows use:

   ```sh
   bash $R/versions.sh live factory-rollback-test     # expect exists=true, split=false, commit=$C2
   bash $R/versions.sh previous factory-rollback-test # expect the v1 version id and commit=$C1
   bash $R/smoke.sh "$URL" '["/", "/hello.txt"]'      # expect ok 200 twice
   ```

6. Roll back exactly as the workflow does, with the id `previous` printed:

   ```sh
   $WRANGLER rollback <v1 version id> --name factory-rollback-test --yes --message "factory rollback: test"
   curl -s "$URL"; curl -s "$URL/hello.txt"          # expect v1, then asset v1 (allow a few seconds)
   bash $R/versions.sh live factory-rollback-test     # expect commit=$C1
   bash $R/smoke.sh "$URL"                            # expect ok 200
   ```

7. Clean up: `$WRANGLER delete --name factory-rollback-test`, `rm -rf /tmp/factory-deploy-tool`, then delete the
   token in the dashboard if you made it only for this test.

Pass: step 4 serves `v2` and `asset v2` from the bundle deployed with `--no-bundle`, step 6 serves `v1` and `asset
v1`, `versions.sh live` reports `commit=$C1`, and `wrangler rollback --yes` asked nothing. The
workflows themselves (hold, approve, automatic rollback after a failed smoke check) are tested end to end on the test
bench once `factory-init` can render them.
