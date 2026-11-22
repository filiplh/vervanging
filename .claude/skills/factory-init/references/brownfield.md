# A repo that already has rules, CI or settings

This page is the one place where factory-init handles an existing repo (brownfield). The rule: **every existing file
is kept, merged, or put to the person as a proposal with a diff. Nothing is overwritten, renamed or deleted**, on disk
or on GitHub. Everything kept, merged and proposed is listed in the install PR, and a re-run changes nothing.

A repo is brownfield when it has any of: an `AGENTS.md`, a `CLAUDE.md` with content, `.cursor/rules` or
`.github/copilot-instructions.md`, workflows under `.github/workflows/`, `.claude/skills`, `.claude/agents`,
`.claude/settings.json`, `.codex/config.toml`, a `.factory/` folder, labels beyond GitHub's defaults, or an open issue
that looks like a status board.

## Before you ask anything

1. **An existing `.factory/core.lock`.** It comes from an earlier install.
   - Another core version: stop. Moving a repo to another version is `factory-update`'s job; say so and stop.
   - The same version: this is a re-run. Run `sh <source>/core/bin/factory-install check --target <target>` first
     (`<source>` is `<clone>/plugin` in a clone of the factory repo, the install folder for an installed plugin) and
     show its output: `edited` and `missing` lines are files someone changed since the install. They stay as they are
     (apply reports them as `differs`); the person decides in the PR whether to restore them.
2. **The dry run is the survey.** Write the values folder (with the two brownfield answers below at their
   recommendations), then run apply with `--dry-run --proposals <scratch>/proposals`. Its lines tell you what is there
   and what would happen to each file. Show the person every line that is not `added` or `unchanged` in your opening
   message, grouped as below, before the questions.
3. **A refusal comes first.** If the dry run stops with "their names belong to the core", tell the person which
   skills or agents collide and why (below), and wait until they renamed them. Nothing else can go ahead.

## What happens to each kind of file

| Found | What happens | Reported as |
| --- | --- | --- |
| `AGENTS.md` with the project's own rules | kept byte for byte. The template's sections it lacks (by heading: Where things live, Language, Stack, each Rules subsection, Human gates, How work flows, Skills in this repo) are appended after a marker comment (`RULES_MERGE=add`) or proposed (`propose`, the default). A section the project already has, under any heading level, is never offered again | `merged AGENTS.md` or `proposed AGENTS.md`, naming the sections |
| `CLAUDE.md` with content of its own, rules in `AGENTS.md` | kept byte for byte; the `@AGENTS.md` pointer is appended or proposed the same way. A `CLAUDE.md` that already imports `@AGENTS.md` gets nothing | `merged CLAUDE.md` / `proposed CLAUDE.md` |
| `AGENTS.md` as a symlink to `CLAUDE.md` | the link is kept; the sections go into `CLAUDE.md`, and no pointer is added (it would point at itself) | as above, for `CLAUDE.md` |
| `AGENTS.md` as a symlink to a `CLAUDE.md` that does not exist | no `CLAUDE.md` is written (it would import itself) | `kept CLAUDE.md` with the reason, exit 3 |
| sections added once, one removed since | never added again; only proposed | `proposed …` "(added once before and removed since …)" |
| `factory.yaml`, a role file, `.factory/review-checklist.md`, a PR template at any accepted path | kept exactly as it is | `kept … (the project's file; never overwritten)` |
| a `factory.yaml` without a `factory:` line | kept; it may be another tool's file | `kept factory.yaml` with the reason, exit 3 |
| a project file that is a symlink | kept; never written through | `kept … (a symlink; never written through)` |
| `.claude/skills/<name>/` and `.claude/agents/<name>.md` of the project's own | installed next to, never touched | nothing |
| a project skill or agent named `factory-*` (any case), or a skill folder this core installs, that `.factory/core.lock` does not record and that is not exactly the core's copy | **refused**: nothing is written. The core writes and `factory-update` replaces those names, so the project's files would be mixed with the core's or lost | an error naming each one, exit 1 |
| `.claude/settings.json`, `.codex/config.toml` | merged: lists joined with the project's entries first (hooks and permissions included), other keys kept, security switches set to the factory's value. `.claude/settings.local.json` is personal and never touched | `merged`, with a `replaced` or `kept` note per difference |
| a `.codex/config.toml` the merge cannot edit safely (dotted keys, inline tables, no Python 3.11+) | left exactly as it is | `differs …`, exit 3; a person adds the factory's settings by hand |
| the project's own workflows (any `.github/workflows/*.yml` not named `factory-*`) | never replaced or edited | `kept … (the project's workflow; never replaced)`, with a note when it mentions the verify command |
| the factory's CI next to the project's own | `factory-ci.yml` and `factory-nightly.yml` are rendered and pin-checked as always, but **proposed, not installed**, and the lock leaves them out. `CI_WORKFLOWS=install` installs them beside the project's | `proposed .github/workflows/factory-ci.yml` |
| `ci.pr` empty (no `verify`, no checks) | no `factory-ci.yml` at all, in any repo: even its job that only selects checks bills a minute per push. An empty `ci.nightly` writes no nightly workflow | `skipped .github/workflows/factory-ci.yml` |
| a workflow named `factory-*` that the factory did not write | never replaced; the core's version is proposed with a diff | `differs …`, exit 3, and `proposed …` |
| a core file (skill, agent, `.factory/` file) that differs from the core | left as it is; the lock records the core's hash, so `factory doctor` keeps flagging it; the core's version is proposed with a diff | `differs …`, exit 3, and `proposed …` |
| `.factory/` without a `core.lock` (another tool may use that folder name) | kept; the core's files go next to its own | `kept .factory/` naming what it holds, exit 3 |
| `.agents/skills` as a real folder, or a symlink elsewhere | kept | `kept …`, exit 3 |
| a symlink at, or on the way to, any file it would write | nothing is written at all | an error, exit 1 |

`--proposals <dir>` (in your scratch directory, never inside the repo) receives each proposed file at its repo path
and its unified diff next to it (`<path>.diff`). The helper refuses a folder that is in the repo or resolves into it,
and any symlink in or at a proposal's path, before it writes anything (also under `--dry-run`). Proposals are written
before anything in the repo, each as a new file renamed into place relative to folder descriptors opened without
following a symlink, so a folder swapped during the run cannot redirect one into the repo (the repo's own files are
written the same way). A proposal changes nothing in the repo; the person takes it in this PR
(you apply it on their word, see below) or later.

## The two brownfield questions

Ask them after the usual questions ([questions.md](questions.md), B1 and B2), only when they apply:

- **B1, the rules file** (`RULES_MERGE`), when `AGENTS.md` (or a `CLAUDE.md` with rules) exists and the dry run
  proposed sections or the pointer. Show the list of sections. Recommend **add**: every line of theirs stays, the
  factory's sections come after a marker that says the project's rules win where the two disagree, and the PR diff
  shows exactly what was added. Recommend **propose** instead when their rules already cover the same ground in their
  own words (a section on tests, on dependencies, on secrets under other headings): then adding would say the same thing
  twice. Read their rules to judge; say which of the template's topics they already cover (language, architecture, data
  and compatibility, tests, dependencies and licences, security, unconfirmed claims, human gates).
- **B2, CI** (`CI_WORKFLOWS`), when the repo has workflows of its own. Name them, and say which ones run the verify
  command or the checks. Recommend **propose** (the default): the factory's CI next to theirs runs the same checks twice
  on every ready PR, and the minutes are shared by every private repo of the account; a check that needs a browser or a
  service their CI sets up would fail in the factory's. Recommend **install** only when their CI does not run verify on
  pull requests. With propose, set `ci.pr: []` in `factory.yaml` when you add it (step 5), so `factory gate` takes local
  evidence for the checks instead of waiting for jobs that never run, and say so in the PR.

When the person picks a different answer for one proposed file than for the rest ("add the pointer, but only propose
the sections"), apply with the answer for most, then copy the chosen proposal file from the proposals folder over the
repo file yourself; it is the project's file with the factory's text appended, nothing else. Run apply again
afterwards: it must change nothing.

## Roles from the code (team mode)

Proposed roles are always shown for approval (question 8), never written on a guess. In an existing repo, read, in
this order: `CODEOWNERS` (each owner's paths are a candidate role), labels like `area:*` or `component:*`, the top
folders and packages that change on their own (`git log --format= --name-only -n 300 | cut -d/ -f1-2 | sort | uniq -c`),
and existing role files under `.factory/roles/`. Show a table: role, owned globs, where the evidence came from. Two roles
never own the same path. An existing `.factory/roles/<role>.md` is kept as it is.

## Labels and the status issue

1. **Labels:** on a brownfield repo, run `labels` with `--keep-existing`. Missing labels are created; a label that
   exists with the factory's name but another colour or description keeps the project's (`kept label … (the project's
   colour or description; the factory's is …)`); labels of the project's own are never touched. Nothing is ever
   deleted or renamed. List the `kept` lines in the PR.
2. **The status issue:** `status-issue` looks for an open or closed issue labelled `factory:status`, and then for an
   open issue that **looks like** a status board: a title that is just "Status", or holds "status" with one of factory,
   board, build, project, agent(s), lead, dashboard or tracker. Found one: it stops (exit 3) and makes nothing. Ask the
   person, naming the issue:
   - "That is our board": run it again with `--adopt <N>`. It adds the `factory:status` label and pins the issue; its
     title and body are never edited. The lead posts status as comments, so the issue keeps its history.
   - "That is something else": run it again with `--not-status <N>` (repeat or comma-separate for several); the
     factory's status issue is created.
   Never pick for them, never open a second board next to one they use, and never reopen or edit an issue yourself.
   Only a closed `factory:status` issue: it stops too; ask whether to reopen it (the person does) or adopt an open one.

## In the PR

Fill in the PR body's "Kept, merged and proposed" section ([pr-body.md](pr-body.md)) from the apply report:

- **Kept:** every `kept` line, with its reason; the project's workflows by name, with the overlap note.
- **Merged:** every `merged` line (the rules file, `CLAUDE.md`, settings) with its notes. Copy every `replaced` and
  `kept` note from the settings merge under "Changed in your settings"; a `replaced` security switch is the person's
  call: say what it was and why the factory sets it.
- **Proposed:** every `proposed` line, each with its diff from the proposals folder in a collapsed `<details>` block
  (`diff` fenced). For the CI proposal, say how to take it later: put `verify` (and the checks) back in `ci.pr`, then
  re-run factory-init and answer B2 with install. The proposal shows the workflow as it would be with `verify` in
  `ci.pr`.
- **Other rules files** (`.cursor/rules`, `.github/copilot-instructions.md`): never edited. Say which of the
  template's topics they cover and recommend moving shared rules into `AGENTS.md` in a follow-up the person approves.
- **A `CLAUDE.md` that is more than a pointer:** recommend moving its content into `AGENTS.md` in a follow-up, so
  Codex reads the same rules; Codex never reads `CLAUDE.md`.
