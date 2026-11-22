# vervanging: rules for agents

<!-- fill in: two or three sentences. What the product is, who uses it, and what matters most to them. -->

This file holds the project's rules. Claude Code and Codex both read it (`CLAUDE.md` only points here). The factory's
settings (commands, roles and owned paths, checks, CI, deploy targets, project human gates) are in `factory.yaml`;
this file says how to build well here. Changing it is a human gate.

## Where things live

| What | Where |
| --- | --- |
| Settings for the factory | `factory.yaml` |
| Plan and scope | `docs/PLAN.md` |
| Settled decisions (ADRs, decision log) | `docs/adr/` (index `docs/adr/README.md`); decisions table in `docs/PLAN.md` |
| Glossary (the project's words, Dutch on screen, code names) | `docs/GLOSSARY.md` |
| Spike write-ups | none yet |
| Grill context (glossary, constraints and open questions the grill reads first) | `docs/grill/CONTEXT.md` (created by `factory-grill` when needed) |
| Grill logs (one file per grill session) | `docs/grill/` (created by `factory-grill` when needed) |
| Role files | `.factory/roles/<role>.md` (one per role in `factory.yaml` › `roles`; none without roles) |
| What the reviewer checks beyond the core protocol | `.factory/review-checklist.md` |
| The project's own skills | `.claude/skills/<name>/` (`.agents/skills` points there) |
| Holdout scenarios (only the validator reads them) | `acceptance/` (optional: a person creates it when needed) |

Core skills find the plan, the decisions, the spike write-ups and the grill files through this table, not through
`factory.yaml`. Change a path here (a rules change, so a human gate) and move the files in the same PR. A path marked
"created … when needed" does not exist yet, and that is not a fault.

## Language

- Code, identifiers, code comments, commit messages, branch names, issues and PR text, and the plan: English.
- User-facing text (screens, messages, notifications, store and marketing copy): `nl`, the first
  being the main language.
- New user-facing text matches the existing copy: its terms, tone and formats.
- <!-- fill in, or delete: number, date and unit formats. -->

## Stack

<!-- fill in: languages, frameworks, runtime versions, and the one place each version is pinned. -->

- Plain HTML, CSS and JavaScript (ES modules) in `public/`: no framework, no build step, no npm dependencies.
- Served as static assets by a Cloudflare Worker (`factory.yaml` › `deploy.app`, recipe `cloudflare-workers`); the
  recipe pins wrangler itself, so the repo does not depend on it.
- Tests: Node's built-in test runner (`node --test`), on Node 22, pinned in `.node-version` (CI and the deploy build
  read it).
- Local serving: Python's `http.server` (`commands.serve`), so nothing is installed.

The commands every agent uses are in `factory.yaml` › `commands` (`setup`, `verify`, `serve`, `checks`). Run them
from the repo root of your worktree; never invent another way to run the tests.

## Rules

### Architecture

<!-- fill in: the layers, what each may import or call, and where side effects (storage, network, UI) are allowed.
     Keep each rule checkable, ideally by lint. -->

### Data and compatibility

<!-- fill in: persisted shapes (stored data, file formats, config schemas, public APIs), how they are versioned, and
     the migration rule. The core rule applies on top: a changed persisted shape gets a migration or compatibility
     path and a test that old data still loads. -->

### Tests

<!-- fill in: which layer gets which kind of test, where tests live, how to run one test file (needed for heavy
     checks: agents run only the tests they touch), and fixtures that must never contain real data. -->

### Dependencies and licences

Accepted licences are in `factory.yaml` › `licences`. A new dependency (package, vendored code, third-party skill or
CI action) needs a person's approval first. Code copied from elsewhere keeps its source, licence and commit next to
it.

### Security and privacy

No secrets, tokens or credentials in files, commits, logs, fixtures or PR text. No personal or customer data in logs
or error messages. Never use production data or production systems for development or tests.
<!-- fill in: project specifics (what counts as personal data here, who may touch production). -->

### Unconfirmed claims

Anything that could not be verified (a rule interpretation, a manual check on a real target, a product question) is
marked with `⚠` in code and docs, and listed under "Needs confirmation" in the PR. Never
present it as fact.

## Human gates

Agents stop and ask before anything on the core's list of human gates (`.factory/reference/human-gates.md`), plus the
project's own sentences in `factory.yaml` › `human_gates`. Issues labelled `agent:human` are for a person only. The
`factory:paused` label on the status issue stops all agents.

## How work flows

- One issue, one branch: `<type>/<N>-<slug>` from the default branch, in its own worktree. Conventional commits.
- Every issue lists its owned paths and carries one `tier:*` label; stay inside the owned paths.
- PRs follow `.github/pull_request_template.md`, report only checks that actually ran, and get an independent review
  on a different model before they merge. P0–P2 findings block a merge.
- <!-- fill in, or delete: anything about this project's flow that differs (release trains, freeze periods). -->

## Skills in this repo

<!-- fill in: one line per project skill in .claude/skills/, saying when to load it. Roles list theirs in
     factory.yaml › roles.<role>.skills. -->
