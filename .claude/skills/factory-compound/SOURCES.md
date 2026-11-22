# Sources

`factory-compound` is written for the factory. No file here is copied from a third party; the ideas below were adapted,
and the wording is new.

## Adapted: Every's `ce-compound` (Compound Engineering plugin)

| Field | Value |
| --- | --- |
| Repo | https://github.com/EveryInc/compound-engineering-plugin |
| Commit | `ee46dde75a40e297bd8eac4055a410a771d3ac1d` (13 Nov 2026) |
| Licence | MIT, Copyright (c) 2025 Every |
| Files read | every file under `skills/ce-compound/` at that commit: `SKILL.md`; `assets/resolution-template.md`; `references/` `assembly.md`, `concepts-vocabulary.md`, `enhancement.md`, `form.md`, `grounding-validation.md`, `lightweight.md`, `modes.md`, `refresh-and-discoverability.md`, `report.md`, `research.md`, `schema.yaml`, `session-history.md`, `yaml-schema.md`; `references/agents/` (seven prompts); `references/refresh/` (ten files); the bundled scripts `packs-resolve.py`, `validate-doc-claims.py`, `validate-frontmatter.py` and the four `session-history` scripts. Also `skills/ce-compound-refresh/SKILL.md` and `LICENSE` |
| Run-time behaviour | none: plain instructions, nothing fetched, no package or script run. Read through `gh api` at the commit above; nothing was executed |
| Taken (ideas, reworded) | the durable bar as a counterfactual (would an agent working from the current repo repeat the mistake?) and "work that went as planned is not a trigger" (SKILL.md § 1–2); "if a check or standard already states it, write nothing" (§ 2.3); the form ladder (one owner and one way, then a check, then a standard, then prose) and re-applying the counterfactual after a check so prose keeps only what the check cannot carry (§ 3, forms-and-destinations.md); a check counts only after it is seen to pass on the current tree and fail on the defect's shape in a throwaway copy, never in the working tree, and its failure must say the fix; baseline entries only for existing violations; a check that needs a new tool is reported, not written; one lesson per run; a defect class enters the review checklist only after it actually happened (from the "standards bar"); a temporary rule records what outside change would retire it (from `retire_when`); the refresh outcomes and their judgement rules, reduced to keep, merge, narrow, retire and flag (prune.md): recoverability needs a quoted artefact, topical overlap is not coverage, a check covering the whole class removes the rule and partial coverage narrows it, age alone is not staleness, unverifiable is not false, a removed file proves the code is gone but not the problem, no edits for wording alone, git history is the archive, and the PR body lists every cut with its evidence |
| Not taken | the `solutions/` knowledge store, its schema, templates and categories (the factory keeps lessons in the overlay files a project already has, at fixed paths); `CONCEPTS.md` and vocabulary capture (the factory has its own glossary in `factory-plan`); the session-history scripts, which read local agent transcripts across tools and could surface credentials; `packs-resolve.py`, which clones git repositories named in config at run time; the two validator scripts and the specialist agent prompts; the interactive and non-interactive mode tokens; the discoverability edits to instruction files; the hand-off to `ce-setup` |

## Idea only: the plan's sources for "compound every mistake"

`docs/PLAN.md` › Ideas worth stealing (9) in the factory repo cites Compound Engineering and Mitchell Hashimoto's
write-up on adopting coding agents: each mistake becomes a rule, lint or test in the repo, and lessons that apply
everywhere go upstream. Nothing was copied from either; the upstream route follows the factory's own copy-in and
`factory-update` model.

When the source changes, re-read it at a new commit before taking anything more, and update this file.
