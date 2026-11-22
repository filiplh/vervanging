# Sources

The core references are written for the factory. No file here is copied from a third party; where ideas were adapted,
they are listed below, and the wording is new.

## Adapted into `instruction-review.md`: Anthropic's `prompt-audit.md` (claude-api skill)

| Field | Value |
| --- | --- |
| Repo | https://github.com/anthropics/skills |
| Commit | `e4bb5d960d87126ff3b3a8af1a104b7db67560ba` |
| Licence | Apache-2.0, Copyright 2026 Anthropic, PBC (`skills/claude-api/LICENSE.txt`) |
| Files read | `skills/claude-api/shared/prompt-audit.md` in full, and `skills/claude-api/LICENSE.txt` |
| Run-time behaviour | none: plain instructions, nothing fetched, nothing run. Read through `gh api` at the commit above; nothing was executed |
| Taken (ideas, reworded) | instruction files that rule differently on one point, and the line between a conflict and an override a narrower file explains (Group 2); names in instruction files that no longer resolve, checked by reading scripts, never by running them (Group 2, volatile specifics); duplicates that drift apart, and that copies which agree are not a finding (Group 2, keep list item 8); a change that loosens a prohibition is flagged, not smoothed over (Group 2, conflicts); a rule written for one session's stumble (the recency trap) and patch accretion, here pointed at the factory's own form ladder (a check before prose); time-bound and migration-relative wording (Group 1d, Group 2); pressure language in both directions, emphasis without a reason and hedges on requirements, with trigger text allowed to be firm (Group 1a, Group 3's split); description triggers that collide (Group 2, trigger enumeration, and Group 3's overlap row); no manufactured findings, and a clean surface is a valid result (prime directive, keep list) |
| Not taken | "drop incident IDs and PR numbers" for overlay files: the factory's `factory-compound` skill keeps every lesson's incident link in the overlay; it applies to core files only, where history goes in git and the PR; the whole-repository audit with its report and proposed diff (here a reviewer walks only what the diff touches and files findings); model-specific rows and the API, request-config and tool-description groups (Groups 1b, 1d's model rows, 3 and 4); confidence levels (the factory uses its P-levels); removal experiments on a scratch copy; the target-model step |

When the source changes, re-read it at a new commit before taking anything more, and update this file.
