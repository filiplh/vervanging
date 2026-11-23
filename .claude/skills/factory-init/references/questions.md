# The questions

Ask **one at a time**, in this order, and only those detection left open. Each question names your recommended
answer first, with one line of why, then the alternatives. "Yes", "ok" or "go" takes the recommendation. A finding
you are sure of is not a question: it is in the opening list of findings, where the person can correct it.

On a re-run, `factory.yaml`, `AGENTS.md` and `.factory/roles/` answer most of these: ask only what they leave open.

| # | Question | Skip when | Recommend |
| --- | --- | --- | --- |
| 1 | **Languages of user-facing text** (BCP 47 tags, main language first)? | the repo's catalogues or pages name them unambiguously | the detected locales; with none, the README's language |
| 2 | **Solo or team mode?** | never on a fresh install | `solo`: one issue at a time, no lead, cheaper and safer; `team` when there is enough independent work for parallel specialists |
| 3 | **Language of code, comments, commits and PR text?** Ask for a language name, one or two words as it would end a sentence ("English", "Brazilian Portuguese"), not a sentence or a tag | existing commits and comments agree on one | the language of the existing commits; in an empty repo, the language the person writes to you in, and say that the factory's own repos use one language for all code |
| 4 | **Setup command** (prepares a fresh worktree or CI runner; must be safe to run twice)? | one install command was detected with certainty, or the repo has [no stack yet](#a-repo-with-no-stack-yet) | the detected install command, wrapped in the worktree script when [detect.md](detect.md) says so |
| 5 | **Verify command** (the one command every change must pass)? | the project has its own verify or check script or target, or the repo has [no stack yet](#a-repo-with-no-stack-yet) | the detected script or target; otherwise the chain of lint, type check, unit tests and build, passing `${FACTORY_TEST_WORKERS:-2}` the runner's way |
| 6 | **A command that serves the app** on `$PORT`, so hunters and the validator can test it black-box? | the repo is a library or a tool with nothing to serve (say so in the findings), or it has [no stack yet](#a-repo-with-no-stack-yet) | the detected preview or start command with the port flag; "none for now" when unsure |
| 6b | **The browser tool the validator drives the app's screens with?** | the project has no screens a browser shows: no web stack was detected ([detect.md](detect.md) › Browser tool) and the person did not describe a web app | see [below](#the-browser-tool-question-6b) |
| 7 | **Checks beyond verify, and what runs nightly?** | no slow suite was detected | each detected slow suite as a check with its `when` paths, nightly (`ci.nightly`), not on every PR, because CI minutes are shared by all private repos of the account |
| 8 | **Roles and their owned paths?** | solo mode, unless the person wants roles | team mode: the roles proposed from the code ([detect.md](detect.md) › Roles); solo mode: none |
| 9 | **Hosts and cache folders the sandbox should allow?** | no sandbox template in the source has a sandbox section (see below), or the repo has no stack yet | the hosts and caches of the detected stack ([detect.md](detect.md)); nothing else |
| 10 | **Where do the plan, the decisions and spike write-ups live?** | they were found, or the repo is new (then "none yet") | the found paths; "none yet" |
| 11 | **Paths whose changes need no CI run** (`ci.skip_paths`)? | always skip it unless docs-only changes are frequent | none: a test or build that reads a doc would miss its change; propose `docs/**` and `**/*.md` only when nothing in the build reads them |
| 12 | **A deploy target now?** | the person has not mentioned deploying | none for now; a target is added later through the deploy contract, and its first deploy is a human gate anyway |

**Question 9 depends on the source, not on a version number.** The installer writes the sandbox lists only into a
template with a **sandbox section**: one that holds the list's placeholder (`__FACTORY_SANDBOX_DOMAINS__` for the
hosts, `__FACTORY_SANDBOX_WRITE__` for the folders). The templates it reads are `core/templates/claude-settings.json`
and `core/templates/codex-config.toml` under `<source>`. A file that exists is not enough: a
`claude-settings.json` that only registers hooks merges its hooks and writes no list. So test the content:
`grep -l __FACTORY_SANDBOX_ <source>/core/templates/claude-settings.json <source>/core/templates/codex-config.toml`
(a missing file is fine).

- **A template names a placeholder:** show the detected hosts and caches and ask for a yes; never skip it then. Ask
  only for the lists some template takes (the folders only when one holds `__FACTORY_SANDBOX_WRITE__`).
- **None does:** the answer would have no effect, so do not ask. List the detected hosts and caches in the opening
  findings as information, marked "not written by this core version", leave `SANDBOX_DOMAINS` and `SANDBOX_WRITE`
  out of the values folder, and say in the install PR that they were not written. The question comes back by itself
  in a source whose templates have a sandbox section.

The apply checks the same thing: a sandbox answer that no template takes is printed as `skipped  SANDBOX_DOMAINS` (or
`SANDBOX_WRITE`) with the reason, on the dry run already. Seeing that line means the list is not written: take it
out of the values folder and say so in the PR; never write in the PR that it was. When the source has neither file,
the apply prints `skipped  .claude/settings.json (this core version has no sandbox templates)` instead.

## A repo with no stack yet

A brand-new repo (a README, maybe a licence, no manifest, no code) has no stack to detect, and the stack is picked
later: `factory-grill` settles it, `factory-plan` records it as a decision. Don't invent one to fill the questions.
Say in the opening findings that the repo has no stack yet, then:

- **Unset until the stack is picked:** `commands.setup` (leave `SETUP` out), `commands.serve`, `commands.checks`, the
  CI toolchain (`TOOLCHAIN.block`), the sandbox lists (question 9) and the browser tool (question 6b, unless the
  person already knows the product is a web app: then ask it, since the answer does not depend on the stack).
  Questions 4, 6, 7 and 9 are skipped; list each as "set by the stack's first ticket" in the PR.
- **Verify, meanwhile:** `factory.yaml` requires `commands.verify`, so it gets a placeholder that checks something
  real and says what it is. Write exactly this, with nothing around it (question 5 is then a yes or no):
  `sh .factory/bin/factory-install no-stack-verify --target .`. It prints that it checks only the factory install,
  and fails when an installed core file was edited or a placeholder was left, so the install PR's CI and its local
  verify evidence stay meaningful. Name it in the PR as a placeholder verify, not as the project's tests. It also
  guards its own end: it passes only while `factory.yaml` › `commands.verify` is still exactly that command, read
  with the core's YAML reader; a symlinked `factory.yaml`, one the reader refuses, or a `verify` key outside
  `commands` fails too. Once `factory.yaml` names a real verify, a CI workflow still rendered with the placeholder
  runs it, it fails with a message saying so, and the `verify` job is red. The gate then cannot count the install
  check as the project's verify.
- **Who sets the real commands:** after `factory-plan` records the stack, `factory-tickets` writes the ticket that
  scaffolds it (the first one that adds a manifest). That ticket sets `factory.yaml` › `commands` (`setup`, `verify`
  and, when the app runs, `serve`) and the hosts and caches its toolchain needs. A change to `factory.yaml` is human
  gate H4, so a person approves those commands in its PR.
- **And the CI workflow, in the same ticket:** `.github/workflows/factory-ci.yml` holds its own copy of `SETUP` and
  `VERIFY`, rendered by the installer, and nothing renders it again within one core version. So the scaffold ticket
  also owns `.github/workflows/factory-ci.yml`, sets its `SETUP` and `VERIFY` values (and the toolchain step, pinned
  as in SKILL.md step 4.2) to the new commands, and has an acceptance criterion that the PR's `Factory CI / verify`
  job runs the real verify. Until it does, the placeholder keeps that job red (above). Pushing a change under
  `.github/workflows/` needs the agent token's Workflows permission when the project uses agent tokens
  (`docs/agent-tokens.md` in the factory repo, step 3; [the core's GitHub access mapping](../../../../.factory/reference/github-access.md), `.factory/reference/github-access.md` in a project):
  a person grants it for that ticket. At the next `factory-update`, that hand-rendered workflow shows as a local edit;
  discarding it takes the newly rendered one, which carries the same commands from `factory.yaml`.
- **The handoff:** write all of this into the installed `AGENTS.md` › Stack (SKILL.md step 5), where `factory-plan`
  and `factory-tickets` read the rules, and list it in the install PR's human steps too.

## The browser tool (question 6b)

A `ui` assertion in a ticket's acceptance contract is checked by the validator in the running app's screens, with the
browser tool the project names in `AGENTS.md` (the validator reads it there). Without one, every `ui` assertion is
unchecked and the validation cannot pass.

- **Ask** when detection found a web stack ([detect.md](detect.md) › Browser tool) or the person describes the
  product as something used in a browser, including a new repo with no stack yet.
- **Recommend**, first that applies: the browser test runner the repo already has (its config or its dependency,
  named in the findings); else the browser tool the agent runtime offers this session (a browser server or built-in
  browser tools: name it as the runtime names it), because it needs no new package; else "none for now".
  A runner the repo does not have yet is a new dependency (human gate H2), and installing browsers into a shared
  location is a person's job: say so when the person picks one.
- **Record** the answer in `AGENTS.md` › Stack as one line, worded exactly so (later steps and optional packs read
  it): `- Browser tool for ui assertions: <the tool, as agents call it>`. SKILL.md step 5 says when it is written.
- **"None"**: write `- Browser tool for ui assertions: none` and tell the person plainly, in the conversation and in
  the PR: "`ui` assertions cannot be validated in this project. Tickets write their acceptance contract with
  `command` or `http` assertions instead (`http` also needs `commands.serve`)." Name a browser tool later in
  `AGENTS.md` (a rules change, so a human gate) to make `ui` assertions checkable.

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
