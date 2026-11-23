# Detect

Read the repo before you ask anything. Each finding gets its source ("the `test` script in the Node manifest",
"`.python-version`"), so the person can check it in one look. A finding you are unsure of becomes a question with
the finding as the recommended answer; a finding you are sure of is shown, not asked.

## What to read

- The root listing and two levels down (skip dependency, build and cache folders).
- Manifests and lockfiles (below), version files, `Makefile`, `justfile`, `Taskfile.yml`.
- `README.md` and any contributing guide: how to install, test and run.
- Existing CI under `.github/workflows/`: the commands it already runs are the best evidence for `verify`.
- Existing rules: `AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, `.github/copilot-instructions.md` (brownfield).
- `git log --format=%s -n 50`: the language and style of commit messages.

## Stacks

A repo may have several (a monorepo, a backend and a frontend). Detect each, then build one `setup` and one `verify`
that cover all of them, or ask.

**Node.** Marker: the Node manifest at the root.
- Package manager from the lockfile: `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `bun.lock` or `bun.lockb` → bun,
  the npm lockfile → npm.
  The manifest's `packageManager` field wins when present.
- Install: `npm ci`, `pnpm install --frozen-lockfile`, `yarn install --immutable`, `bun install --frozen-lockfile`.
- Verify: the manifest's own `verify` or `check` script when it exists; otherwise its `lint`, `typecheck`, `test` and
  `build` scripts chained with `&&`, in that order. Never invent a script that is not there.
- Serve: a `preview` or `start` script that serves a production build; a dev server only when nothing else exists.
- Test workers: Vitest takes `VITEST_MAX_WORKERS`, Jest `--maxWorkers`, Playwright `--workers`. Pass
  `${FACTORY_TEST_WORKERS:-2}` the runner's way.
- CI toolchain: `actions/setup-node` with `node-version-file` (`.nvmrc`, `.node-version`, `.tool-versions`, or the
  manifest's `engines`) and `cache` set to the package manager.
- Hosts: `registry.npmjs.org` (yarn classic also `registry.yarnpkg.com`, yarn berry `repo.yarnpkg.com`).
- Caches: `~/.npm`, `~/Library/pnpm` or `~/.local/share/pnpm`, `~/.yarn/berry/cache`, `~/.bun/install/cache`.

**Python.** Markers: `pyproject.toml`, `requirements*.txt`, `uv.lock`, `poetry.lock`, `Pipfile.lock`, `setup.py`.
- Install: `uv sync --frozen` (uv.lock), `poetry install --no-interaction` (poetry.lock), otherwise a virtual
  environment and `pip install -r requirements.txt` (and `-e .` when there is a package).
- **The interpreter.** A bare `python3` is whatever the machine has first on its path, often an older system Python
  the dependencies do not support. Take the version the repo states, in this order: `.python-version`, then
  `pyproject.toml`'s `requires-python` (its lowest allowed minor version), then the `python-version` of
  `actions/setup-python` in the repo's CI. Build the setup on that interpreter (`python3.<minor> -m venv .venv`;
  `poetry env use python3.<minor> && poetry install --no-interaction`; uv reads `.python-version` and
  `requires-python` itself) and say in the findings which file the version came from. When the repo states none,
  say so in the findings and ask once (question 4) which interpreter to use, recommending the machine's `python3`
  with its version.
- Verify: what the README and CI run; usually `ruff check .`, a type check, `pytest -q`. pytest with xdist takes
  `-n ${FACTORY_TEST_WORKERS:-2}`; plain pytest is single-process.
- CI toolchain: `actions/setup-python` with `python-version-file` (`.python-version` or `pyproject.toml`) and
  `cache: pip` (uv: `astral-sh/setup-uv` is third-party, so gate H2).
- Hosts: `pypi.org`, `files.pythonhosted.org`. Caches: `~/Library/Caches/pip` or `~/.cache/pip`, `~/.cache/uv`.
- A virtual environment records its own path, so it is never reused between worktrees: setup must build it.

**Go.** Marker: `go.mod`. Install `go mod download`; verify `go vet ./... && go test ./...` (`-p` takes the worker
count). CI: `actions/setup-go` with `go-version-file: go.mod`. Hosts: `proxy.golang.org`, `sum.golang.org`. Caches:
`~/go/pkg/mod`, `~/Library/Caches/go-build` or `~/.cache/go-build`.

**Rust.** Marker: `Cargo.toml`. Install `cargo fetch`; verify `cargo clippy --all-targets -- -D warnings && cargo test`
(`--jobs` and `--test-threads` take the worker count). CI: the runner's preinstalled toolchain, so no block
(`rust-toolchain.toml` is read by rustup itself). Hosts: `crates.io`, `index.crates.io`, `static.crates.io`. Caches:
`~/.cargo/registry`, `~/.cargo/git`.

**JVM.** Markers: `pom.xml` (Maven), `build.gradle` or `build.gradle.kts` (Gradle). Verify `./mvnw -B verify` or
`./gradlew check` (prefer the wrapper). CI: `actions/setup-java` with a `distribution` and `java-version-file`
(`.java-version`, `.tool-versions`) or ask. Hosts: `repo.maven.apache.org`, `repo1.maven.org`; Gradle also
`services.gradle.org`, `plugins.gradle.org`. Caches: `~/.m2`, `~/.gradle`.

**.NET.** Markers: `*.sln`, `*.csproj`, `global.json`. Install `dotnet restore`; verify `dotnet test`. CI:
`actions/setup-dotnet` with `global-json-file`. Hosts: `api.nuget.org`. Caches: `~/.nuget/packages`.

**Ruby** (`Gemfile.lock`), **PHP** (`composer.lock`), **Elixir** (`mix.lock`): install `bundle install`,
`composer install --no-interaction`, `mix deps.get`; verify from the README and CI. Their CI setup actions are
third-party (gate H2), so prefer the runner's preinstalled tools when they are enough. Hosts: `rubygems.org`,
`index.rubygems.org`; `repo.packagist.org`; `hex.pm`, `repo.hex.pm`, `builds.hex.pm`.

**Make, just, Task.** A `verify`, `check` or `test` target is the best verify command when it exists, whatever the
stack: it is the project's own word for it.

**Nothing found.** When the README or the code names commands, ask for setup and verify (questions 4 and 5) and
recommend those. When the repo has no code and no manifest at all (a new repo: a README, maybe a licence), it has no
stack yet: follow [questions.md](questions.md#a-repo-with-no-stack-yet) instead of inventing one.

## Setup: the worktree script

When the stack has a dependency folder that stays valid when copied (Node's `node_modules`, PHP's `vendor`,
Elixir's `deps`) and the source has `core/templates/worktree-setup.sh`, recommend
`sh .factory/bin/worktree-setup.sh -- <install command>`: a new worktree then clones the main checkout's folder
copy-on-write instead of installing again, and falls back to the install command. Otherwise the install command alone.

## Checks beyond verify

- An end-to-end suite (a Playwright or Cypress config, a folder of browser tests): propose a check with `heavy: true`,
  its `when` set to the folders it covers, in `ci.nightly` rather than `ci.pr` (minutes are shared by every repo of the
  account).
- Slow integration tests behind a marker or tag: the same.
- Performance budgets: a check with `gate: false`, nightly only.

## Browser tool

A project whose screens are shown in a browser needs a browser tool for the validator's `ui` assertions
([questions.md](questions.md#the-browser-tool-question-6b), question 6b). Signs of a web stack: HTML pages or
templates, a frontend framework or bundler in a manifest, a `serve`, `preview` or `dev` script that serves pages, a
web server framework that renders pages. Note too which browser tool the repo already has: an end-to-end runner's
config or dependency (the same one an end-to-end suite check uses, below). A library, a command-line tool, firmware or
an API with no pages has no browser screens: question 6b is skipped, and the findings say so.

## Plan, decisions, spikes

Look for a plan or roadmap file, a folder of ADRs or a decision log, and spike write-ups (under `docs/` or the root).
Found: recommend those paths. Not found: "none yet"; `factory-plan` creates them later.

## Roles (team mode)

Propose one role per independent area of the code: a top folder or package that changes on its own (a UI, an API, a
data layer, infrastructure). Each gets the globs of its folders in `owns`; shared registries are not split. Two
roles must never own the same path. Show the proposal; the person decides (question 8).

## Languages

User-facing text: the locales of translation catalogues (folder or file names), the `lang` of HTML pages, store
listings, the README's language. Code language: the language of existing commit messages and code comments.

**The string catalogue.** Note whether the repo keeps its user-facing strings in a catalogue: translation files or
folders (`locales/`, `i18n/`, `messages/`, `*.po`, `*.xliff`, `*.arb`, `strings.xml`, `Localizable.strings`) that the
code reads its text from. Found: write its paths to `STRING_CATALOGUE` ([values.md](values.md)), and `AGENTS.md` and
the review checklist then require text to come from it. Not found (the copy sits in the code, as in many repos
without i18n): leave the file out and say so in the findings; both files then ask only that new text matches the
existing copy. Never point them at a catalogue or `.factory/voice.md` that is not there.
