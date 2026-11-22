# The questions

Ask **one at a time**, in this order, and only those detection left open. Each question names your recommended
answer first, with one line of why, then the alternatives. "Yes", "ok" or "go" takes the recommendation. A finding
you are sure of is not a question: it is in the opening list of findings, where the person can correct it.

On a re-run, `factory.yaml`, `AGENTS.md` and `.factory/roles/` answer most of these: ask only what they leave open.

| # | Question | Skip when | Recommend |
| --- | --- | --- | --- |
| 1 | **Languages of user-facing text** (BCP 47 tags, main language first)? | the repo's catalogues or pages name them unambiguously | the detected locales; with none, the README's language |
| 2 | **Solo or team mode?** | never on a fresh install | `solo`: one issue at a time, no lead, cheaper and safer; `team` when there is enough independent work for parallel specialists |
| 3 | **Language of code, comments, commits and PR text?** | existing commits and comments agree on one | the language of the existing commits; in an empty repo, the language the person writes to you in, and say that the factory's own repos use one language for all code |
| 4 | **Setup command** (prepares a fresh worktree or CI runner; must be safe to run twice)? | one install command was detected with certainty | the detected install command, wrapped in the worktree script when [detect.md](detect.md) says so |
| 5 | **Verify command** (the one command every change must pass)? | the project has its own verify or check script or target | the detected script or target; otherwise the chain of lint, type check, unit tests and build, passing `${FACTORY_TEST_WORKERS:-2}` the runner's way |
| 6 | **A command that serves the app** on `$PORT`, so hunters and the validator can test it black-box? | the repo is a library or a tool with nothing to serve (say so in the findings) | the detected preview or start command with the port flag; "none for now" when unsure |
| 7 | **Checks beyond verify, and what runs nightly?** | no slow suite was detected | each detected slow suite as a check with its `when` paths, nightly (`ci.nightly`), not on every PR, because CI minutes are shared by all private repos of the account |
| 8 | **Roles and their owned paths?** | solo mode, unless the person wants roles | team mode: the roles proposed from the code ([detect.md](detect.md) › Roles); solo mode: none |
| 9 | **Hosts and cache folders the sandbox should allow?** | the source ships no sandbox templates (see below) | the hosts and caches of the detected stack ([detect.md](detect.md)); nothing else |
| 10 | **Where do the plan, the decisions and spike write-ups live?** | they were found, or the repo is new (then "none yet") | the found paths; "none yet" |
| 11 | **Paths whose changes need no CI run** (`ci.skip_paths`)? | always skip it unless docs-only changes are frequent | none: a test or build that reads a doc would miss its change; propose `docs/**` and `**/*.md` only when nothing in the build reads them |
| 12 | **A deploy target now?** | the person has not mentioned deploying | none for now; a target is added later through the deploy contract, and its first deploy is a human gate anyway |

**Question 9 depends on the source, not on a version number.** The installer writes the sandbox lists only into
the sandbox templates it finds in the source: `core/templates/claude-settings.json` and `core/templates/codex-config.toml`
under `<source>`. When the source has at least one of them, show the detected hosts and caches and ask for a yes:
never skip it then. When it has neither, the answer would have no effect (the apply prints `skipped
.claude/settings.json (this core version has no sandbox templates)`), so do not ask: list the detected hosts and caches
in the opening findings as information, marked "not written by this core version", leave `SANDBOX_DOMAINS` and
`SANDBOX_WRITE` out of the values folder, and say in the install PR that they were not written. The question comes
back by itself in a source that ships the templates.

In a brownfield repo ([brownfield.md](brownfield.md)), two more, after these and only when they apply:

| # | Question | Skip when | Recommend |
| --- | --- | --- | --- |
| B1 | **The factory's sections and the `@AGENTS.md` pointer: add them to your rules file, or only propose them?** (`RULES_MERGE`) | the dry run proposed nothing for `AGENTS.md` or `CLAUDE.md` | `add`: every line of theirs stays, the PR diff shows what was appended; `propose` when their rules already cover the same topics in their own words |
| B2 | **Your CI (name the workflows): add the factory's CI beside it, or only propose it?** (`CI_WORKFLOWS`) | the repo has no workflows of its own | `propose`: two CIs run the same checks twice on every ready PR; `install` only when their CI does not run verify on pull requests |

Questions about the unconfirmed-claims marker and the project name are not asked: use `⚠` and the repo name, and
say so in the PR so the person can change them in `AGENTS.md`.

## How to ask

- One question per message, short. Lead with the recommendation: "Verify: `make check`? It is the repo's own check
  target and CI runs it. Or name another command."
- Accept free text, then normalise it (a language name becomes its BCP 47 tag; ask once more if it is ambiguous).
- Never ask for a token, a password, a paid plan or an account. Those are listed in the PR as human steps.
- Stop at about ten. If more seems needed, take the recommended answers for the rest, say which, and list them in the
  PR so the person can change them there.
