# The values folder

`factory-install apply` and `labels` read the answers from a folder: **one file per answer**, named as below, holding
the value as plain text (a trailing newline is ignored). A file that is absent takes the default in the last column.
List answers hold one entry per line. Make the folder fresh in your scratch directory for every run.

The placeholders these fill are listed in the core's templates README (`core/templates/README.md` in the source);
this page says how factory-init supplies them.

## Every project

| File | Holds | Fills | Absent |
| --- | --- | --- | --- |
| `REPO` | `owner/name` of the GitHub repo | `factory.yaml` › `project.repo` | required |
| `UPSTREAM` | `owner/name` of the factory repo the core comes from (SKILL.md, step 1.2) | `.factory/core.lock` › `upstream:` | the existing lock's `upstream:`; required on a fresh install |
| `LANGUAGES` | BCP 47 tags of user-facing text, comma-separated, the main language first (`xx, xx-YY`) | `project.languages`; `AGENTS.md` writes them as a list of tags | required |
| `MODE` | `solo` or `team` | `mode` | `solo` |
| `SETUP` | the setup command, one line | `commands.setup`, and `SETUP` in the CI workflows | the `setup:` line is left out of `factory.yaml`; CI's Setup step skips (also the case for a repo with no stack yet) |
| `VERIFY` | the verify command, one line; for a repo with no stack yet, exactly the placeholder `sh .factory/bin/factory-install no-stack-verify --target .` ([questions.md](questions.md#a-repo-with-no-stack-yet)) | `commands.verify`, and the CI `verify` job | required |
| `PROJECT_NAME` | the short name | `AGENTS.md`'s title | the part of `REPO` after the slash |
| `CODE_LANGUAGE` | the language of code, comments, commits and PR text: the language's English name, one or two words, capitalised, as it ends the sentence "… PR text: <name>." (`English`, `Brazilian Portuguese`); never a sentence or a BCP 47 tag | `AGENTS.md` › Language | required |
| `UNCONFIRMED_MARKER` | the marker for unverified claims, such as `⚠` | `AGENTS.md` › Unconfirmed claims | required |
| `PLAN_PATH`, `DECISIONS_PATH`, `SPIKES_PATH` | a repo path each; written as inline code | `AGENTS.md` › Where things live | "none yet" |
| `STRING_CATALOGUE` | the repo paths of the string catalogue (a folder or file each), one per line, when the repo has one ([detect.md](detect.md) › Languages; on a re-run, the catalogue row of `AGENTS.md` › Where things live) | `AGENTS.md` › Where things live and Language, `.factory/review-checklist.md` › User-facing text: text comes from the catalogue, with `.factory/voice.md` for tone when it exists | no catalogue: both say new text matches the existing copy, and neither names `.factory/voice.md` |
| `TEST_WORKERS` | `limits.test_workers` from `~/.factory/machine.yaml` when that file exists | `FACTORY_TEST_WORKERS` in CI | `2` |

The browser tool (question 6b) is not a file here: no template takes it. SKILL.md step 5 writes it into `AGENTS.md`.

## Brownfield

| File | Holds | Absent |
| --- | --- | --- |
| `RULES_MERGE` | `add` or `propose`: what happens to the factory's missing sections in an existing rules file and to the `@AGENTS.md` pointer in a `CLAUDE.md` with content ([brownfield.md](brownfield.md), B1) | `propose`: nothing is written into the project's rules |
| `CI_WORKFLOWS` | `install` or `propose`: whether `factory-ci.yml` and `factory-nightly.yml` are written or only proposed (B2) | `propose` when the repo has workflows of its own (not named `factory-*`, not in the lock), `install` otherwise |

## CI

| File | Holds | Absent |
| --- | --- | --- |
| `CI_PR_VERIFY` | `true` when `ci.pr` lists `verify`, else `false` | `true` |
| `PR_CHECKS` | `ci.pr` without `verify`, as one line of JSON: `[{"name": …, "run": …, "when": [...] or null}]`, each from `commands.checks.<name>` | `[]` |
| `NIGHTLY_CHECKS` | `ci.nightly` in order, as one line of JSON: `[{"name": …, "run": …}]`; `verify` takes `commands.verify` | no nightly workflow is written |
| `PR_PATHS.block` | from `ci.skip_paths`: `paths:`, then `  - '**'`, then each entry negated in single quotes (an entry that starts with `!` loses it) | no filter: every PR runs |
| `TOOLCHAIN.block` | the steps that install the toolchain and cache packages, at column 0 (`- uses: …` and its `with:`); every `uses:` pinned with `factory-install pin` | no toolchain step |
| `PR_CHECK_SETUP.block` | one step per check in `ci.pr` that has `commands.checks.<name>.setup`, in `ci.pr` order, in the [step form below](#per-check-setup-steps), each with `if: matrix.check.name == '<name>'` so it runs only in that check's job | no setup step in the PR checks |
| `NIGHTLY_CHECK_SETUP.block` | the same steps for the checks in `ci.nightly` that have a `setup`, in that order and without the `if:`: the nightly runs its checks in one job, so each setup runs once, before the first check (a failing setup fails the night) | no setup step in the nightly |

`CI_PR_VERIFY` `false` with an empty `PR_CHECKS` list (an empty `ci.pr`) writes no `factory-ci.yml` at all, and an
empty `NIGHTLY_CHECKS` list writes no nightly workflow. The helper reads both lists with a JSON parser, so `[ ]` is
empty too; it refuses, before writing anything, a `CI_PR_VERIFY` other than `true` or `false`, a list that is not
valid JSON or not a list of checks, a check without a non-empty `name` and `run`, a `when` that is not null or a list
of strings, and any other key.

Values sit inside single-quoted YAML strings: the helper doubles every `'`, and refuses a value with a line break or
`${{`. Blocks are taken as they are, indented to the placeholder's line. Every rendered workflow is then read as YAML:
each mapping key is decoded, and a `uses` key must hold one scalar on its line, pinned to a full commit SHA. YAML it
does not fully read is refused before anything is written: explicit `?` keys, anchors, aliases and tags, merge keys
(`<<`), keys over several lines, a plain value continued on the next line, block scalars as `uses` values, unbalanced
quotes, tabs used for indentation and document markers. Write toolchain steps in plain block style
(`- uses: <owner>/<action>@<sha> # <tag>`, then `with:`), and setup steps in the form below, and they pass.

### Per-check setup steps

For each check with a `setup`, factory-init writes one step at column 0, starting with an empty line. The command goes
into `env` as a single-quoted YAML string, never into `run:` or an expression, so GitHub never evaluates it:

```yaml

- name: setup for <name>
  if: matrix.check.name == '<name>'
  env:
    CHECK_SETUP: '<the setup command, every single quote doubled>'
  run: sh -c "$CHECK_SETUP"
```

The `if:` line is only in `PR_CHECK_SETUP.block`. `<name>` is the check's name (lower case with `_`, so it needs no
quoting). factory-init builds each step like this:

1. Take the value of `commands.checks.<name>.setup` as YAML decodes it when it reads `factory.yaml`, not the raw line.
2. Refuse it, before anything is written, when it holds a line break or `${{`, and tell the person why. A line break
   puts the rest of the command on a line of its own, where it can become a key or a step. GitHub evaluates `${{` before the
   shell runs, so a setup command could read secrets or change the step. The helper takes blocks as they are and
   checks them for neither, so factory-init must. Ask for one line without `${{`. A setup that needs more goes into a
   script in the repo, and `setup` runs that script.
3. Double every `'`, so YAML decodes the original command: `sh -c 'make deps'` is written `'sh -c ''make deps'''`.
4. Write no `uses:` in these steps. An action a check needs belongs in `TOOLCHAIN.block`, pinned. The helper's pin
   check reads every rendered workflow, blocks included, and refuses an unpinned `uses:` before anything is written.

Leave the file out when no listed check has a `setup`; the workflow then renders exactly as it does without the
feature.

## Roles and labels

| Path | Holds |
| --- | --- |
| `roles/<role>/OWNS` | the role's owned-path globs, one per line, in order (required for each role) |
| `roles/<role>/SKILLS` | the project skills the role loads, one per line (optional) |
| `HUNTER_AREAS` | the area slugs of `.factory/hunters.md`, one per line, when the repo has that file; otherwise leave it out and the roles are the areas |
| `PREVIEW_LABELS` | the label of each `pr-label:<label>` deploy trigger, one per line (`preview` is in the core set already) |

Role, area and target names are lower case: letters, digits, `-` and `_`. Team mode needs at least one role.

## Sandbox

| File | Holds | Absent |
| --- | --- | --- |
| `SANDBOX_DOMAINS` | the hosts the toolchain needs besides GitHub, one per line (`registry.example.org`, `*.example.org` for subdomains) | GitHub only |
| `SANDBOX_WRITE` | folders outside the worktree the toolchain writes (its caches), one per line, starting with `~/` or `/` | none |

Both are proposals from [detect.md](detect.md), confirmed by the person (question 9). They go into
`.claude/settings.json` and `.codex/config.toml`, merged with what is there, and only through a template the source
ships (`core/templates/claude-settings.json`, `core/templates/codex-config.toml`) that has a sandbox section: the
list's placeholder (`__FACTORY_SANDBOX_DOMAINS__`, `__FACTORY_SANDBOX_WRITE__`). A template that only registers hooks
writes no list. When no template takes a list, leave its file out, do not ask for it (question 9), and list the
detected hosts and caches in the PR as "not written by this core version" ([questions.md](questions.md)). A list
given all the same is reported by the apply as `skipped  SANDBOX_<LIST>` and not written.

## Deploy targets and packs

| Path | Holds |
| --- | --- |
| `deploy/<target>/RECIPE` | the recipe name, a folder under the source's `recipes/` |
| `deploy/<target>/ENVIRONMENTS` | the target's environments, one per line; only templates `for` these are rendered |
| `deploy/<target>/values/<NAME>` | one file per value in the recipe's `render.values` (its `recipe.yaml`), from `factory.yaml` › `deploy.<target>` as the recipe says; `TARGET`, `SETUP` and `RECIPE_DIR` are filled in for you |
| `deploy/<target>/values/<NAME>.block` | one file per block in the recipe's `render.blocks`, chosen as the recipe says (an empty file removes the line) |
| `PACKS` | pack names, one per line, from `packs` in `factory.yaml` |

The helper installs each recipe once at `.factory/recipes/<recipe>/` (without its `tests/`) and renders its templates
per target to the paths in its `templates` list, under the deploy contract's rendering rules
(`core/reference/deploy-contract.md` in the source, `.factory/reference/deploy-contract.md` in a project). List the
recipe's `human_steps` and `secrets` (names only) in the PR's human steps.
