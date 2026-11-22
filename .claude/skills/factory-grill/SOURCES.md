# Sources

`factory-grill` is written for the factory. No file here is copied from a third party; the ideas below were adapted,
and the wording is new.

## Base: the user's own `grill-me` skill

| Field | Value |
| --- | --- |
| Source | the factory owner's personal `grill-me` skill (user-level skill, not public) |
| Licence | the owner's own text; it credits ideas borrowed from Matt Pocock's `grilling`, obra/superpowers' `brainstorming` and gstack's `office-hours` and `plan-ceo-review` (all MIT) |
| Taken | the structure and most of the loop: the two rules (facts are the agent's job, nothing silently assumed), homework, the decision tree with its marks and the risk-ranked frontier, target and depth, deep questions, quick rounds and premise rounds, the structured question tool, the after-every-answer moves, tone and pace, deep mode, the decision log and the finish |
| Changed | project context comes only from the project's grill context file and rules file; the model comes from the model policy; lookups go to helpers; the log format follows the factory's own grill logs; the grill hands off to `factory-plan` |

## Adapted: Matt Pocock's `grill-with-docs`

| Field | Value |
| --- | --- |
| Repo | https://github.com/mattpocock/skills |
| Commit | `5863806dd4e15c63174bee4e7515a4256792ecfa` (12 Nov 2026) |
| Licence | MIT, Copyright (c) 2026 Matt Pocock |
| Files read | `skills/engineering/grill-with-docs/SKILL.md` and `agents/openai.yaml`, `docs/engineering/grill-with-docs.md`; the two skills it delegates to: `skills/productivity/grilling/SKILL.md` and `agents/openai.yaml`, `skills/engineering/domain-modeling/SKILL.md`, `ADR-FORMAT.md`, `GLOSSARY-FORMAT.md` and `agents/openai.yaml`; `LICENSE` |
| Run-time behaviour | none: plain instructions, nothing fetched, no package run. Read through `gh api` at the commit above; nothing was executed |
| Taken (ideas, reworded) | challenge the user's words against the project glossary, propose one precise term for a vague one, test a boundary with an invented edge case, and check claims about current behaviour against the code (from `domain-modeling`, in §3 "Sharpen the words"); the three-part test for an ADR candidate: hard to reverse, surprising without context, a real trade-off (from `domain-modeling`, in §6 and the log reference); a running lookup holds back only the questions downstream of it (from `grilling`, in "Where the project's context comes from"); quick-round items may not depend on another open item in the same round (from `grilling`) |
| Not taken | writing the glossary and ADRs during the session (here they are follow-ups the user approves, and ADRs are `factory-plan`'s job); asking the whole frontier in one round (here deep questions go one per turn) |

When either source changes, re-read it at a new commit before taking anything more, and update this file.
