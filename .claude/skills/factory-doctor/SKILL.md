---
name: factory-doctor
description: Checks a repo's factory setup read-only and says how to fix what is wrong. Covers factory.yaml, core.lock, labels, hooks, the verify command and gh login, each reported ok, warn, fail or n/a with a one-line fix. Use when the user says "/factory-doctor", "factory doctor", "check the factory setup" or "why does the factory not start", after factory-init or factory-update, before a lead's first run, or when a factory command fails on something that looks like setup. Also shows which settings a project runs with and where each comes from ("show the factory settings"). Changes nothing.
---

# Check the factory setup

You run one read-only helper and turn its report into a short answer: what is wrong, and the fix for each. You never
fix a project file yourself in this skill: a fix to `factory.yaml`, the rules file or settings is a PR (and a human
gate where the gate list says so), and a fix to a core file goes through `factory-update` or upstream.

## 1. Run it

From the project's root checkout:

```sh
sh .factory/bin/factory-doctor
```

Options: `--json` for machine-readable output, `--target <dir>` for another checkout, `--repo <owner/name>` when
`factory.yaml` has none yet, `--min-free-gb <n>` for the disk threshold, and `--source <factory source>` (the folder
that holds `core/`) so the labels check can read the core's label template. A project's copy of the core does not
carry that template, so without `--source` the labels check reports `warn: not checked`. When this session also has
the factory's plugin, its source is the plugin folder that holds `core/defaults.yaml` and `.claude-plugin/plugin.json`.

Exit codes: `0` every check ok or n/a, `1` at least one fail, `2` warnings but no fail, `64` bad usage.

## 2. Read the report

One line per check, `ok`, `warn`, `fail` or `n/a`, then detail lines and, for warn and fail, a `fix:` line.

| Check | What it looks at | Typical fix |
| --- | --- | --- |
| `factory.yaml` | present; inside the reader's YAML subset (below); every key and type of the schema; no unknown key; no value shaped like a credential (named by key path, never shown); model specs, no top setting as a default, a ladder that only steps up, a first reviewer on another model (another provider for deep and standard work), non-empty review lists; `commands.serve` (warn when unset); a `warn` when the repo has its own workflows (`.github/workflows/*.yml` or `*.yaml` that are not `factory-*`) and `ci.external` is empty, naming up to five of them, since the merge gate may refuse PRs for checks no `factory.yaml` entry covers | a PR to `factory.yaml` (human gate); for the workflows warning, list their jobs in `ci.external` (the factory repo's `docs/factory-yaml.md` › `ci.external`) |
| `core.lock` | the lock's format, one `version:` and one `upstream:`, that version equal to `factory.yaml` › `factory`, and the sha256 of every core file; edited, missing and symlinked core files are named | `factory-update`, or the change goes upstream as a PR to the factory repo; **never edit a core file in place** |
| `labels` | every label of the core's set, plus `agent:<role>`, `hunter:<area>` and extra preview labels from the overlay, exists on the repo (read-only `gh label list`) | `factory-install labels`, or re-run `/factory-init` |
| `status-issue` | exactly one open `factory:status` issue, and whether `factory:paused` is on it (through `factory-pause status`) | `factory-install status-issue`; with several, a person keeps one; a pause is lifted only by a person |
| `hooks` | the hooks the core installs exist and are wired in `.claude/settings.json` in an accepted form (below), under **every event** the core's settings template wires them for; a missing event is a `fail` that names it ("factory-hook is not wired for Stop"), also when a project left it out on purpose; each event's matcher covers the tools the template's matcher lists (a `Bash`-only `PreToolUse` is a `fail` that names the tools left out), and a matcher it cannot read is a `warn`; no `disableAllHooks`; the settings files that exist parse. `n/a` while the core installs no hooks | wire the named event(s) in `.claude/settings.json`: apply the settings merge that `factory-update` left as a proposal in its PR (it never writes `.claude/settings.json`), or re-run `/factory-init` from a source at the repo's core version |
| `verify` | `commands.verify` is set and the program it starts exists (on PATH, or a path in the repo; a missing path is only a warning when `commands.setup` exists, since setup may create it). It is **never run** | fix `commands.verify` |
| `auth` | gh is logged in (`gh auth status`, output discarded); in agent-token mode the broker's `mode`, and from an agent shell its `check` | `gh auth login` in the person's own terminal; for agent-token mode, the factory repo's `docs/agent-tokens.md` |
| `disk` | free space on the checkout's volume against the threshold | `factory-gc` (dry run, then `--apply`) |
| `machine` | `~/.factory/machine.yaml`: known keys, integers in range; `n/a` when the file does not exist | the person edits the file by hand |

`n/a` means not applicable or not checkable here, and the message says which. From an agent shell in agent-token
mode, gh holds no login, so `labels` and `status-issue` are `n/a` there; the person runs the doctor in their own
terminal to check them.

## 3. Tell the person

- Lead with the fails, then the warnings; one line each with its fix. Skip the ok lines unless asked.
- An edited core file: name it and say the change must come through `factory-update` or a PR upstream (the
  `upstream:` repo in `.factory/core.lock`). Do not restore or edit it unasked.
- A pause, a staged or blocked agent-token mode, or a missing login is the person's to change. Say so; do not work
  around it.
- In team or solo flow, a fail in `core.lock`, `auth` or `status-issue` means: start no agent until it is fixed.

## Rules

- **Read-only.** The helper changes nothing: it calls `gh auth status`, `gh label list`, `gh issue list` (through
  `factory-pause`), `factory-github mode` and `check`, and `df`. Do not add commands that write.
- **No secrets.** Never run `gh auth status -t`, `gh auth token` or anything that prints a credential. The helper
  never reads one. It knows the shapes of common credentials (GitHub, GitLab, Slack, AWS, Google, npm and
  payment-provider tokens, secret API keys, JSON web tokens, private keys, URLs with a password) in one list. A
  value of that shape fails its file and is named by key path. A diagnostic never shows such a value, or a fragment
  of one: it shows `<redacted: looks like a credential>`. Text and JSON output go through the same redaction.
  No command's own output or error message reaches the terminal: the helper runs every step with its output thrown
  away or captured as data, and prints only its redacted report and fixed one-line messages. Without a working
  python3 the report shows check names and statuses only. If something credential-like still shows up, stop and
  tell the person, without repeating it; that is a defect in the helper.
- **Hook wiring.** A core hook counts as wired only when `.claude/settings.json` has an entry under a Claude Code
  hook event, in the documented shape (a group of `matcher` and `hooks`; a hook of `type: "command"`, `command`
  and an optional `timeout`, nothing else), whose `command` is exactly one of these forms:

  ```
  sh "$CLAUDE_PROJECT_DIR"/.factory/hooks/<file>
  "$CLAUDE_PROJECT_DIR"/.factory/hooks/<file>
  ```

  These are the forms the core's hook settings write. Anything else is not wired: an echo, a comment, extra words,
  a wrapper, an entry with another key (such as a `disabled` flag), another `type`, an unknown event, or an entry
  only in the personal `.claude/settings.local.json`.
  The hook must be wired under each event the core's settings template wires it for (`factory-hook`: `PreToolUse`,
  `PostToolUse`, `Stop` and `SubagentStop`); an entry under another event does not make up for a missing one, and an extra event
  is not a fault.
  The matcher under an event must cover every tool the template's matcher lists for it (`PreToolUse`: `Bash`, `Edit`,
  `Write`, `MultiEdit`, `NotebookEdit`, `Read`, `Grep`; `PostToolUse`: `Bash`; `Stop` and `SubagentStop` have no tool matcher). Several
  groups for one event together may cover them. Read strictly, a matcher is a plain `|`-list of tool names (names are
  case-sensitive) or a match-all form (absent, empty, `*` or `.*`); any other regular expression is not read: when
  tools are left over, the check is a `warn` that says it cannot tell, never `ok`.
- **The YAML subset.** The helper reads `factory.yaml` and `machine.yaml` with a strict reader and refuses what it
  cannot read exactly, naming the line: anchors, aliases, tags, directives, `?` keys, explicit block indentation,
  tabs in indentation, duplicate keys, plain or quoted values across lines, and plain values that YAML 1.1 and 1.2
  read differently (`yes`, `no`, `on`, `off`, `y`, `n`, octal-looking numbers, dates). Quote such a value; never
  rewrite the file around the reader in another way.
- **Machine setting.** `doctor.min_free_gb` in `~/.factory/machine.yaml` (an integer of at least 1) sets the disk
  threshold for every project on the machine. Its core default, like every machine default, is in the `machine`
  section of `.factory/defaults.yaml`.

## Show the settings

When the person asks what the factory runs with ("show the factory settings", "which settings does this project
use", "where does this value come from"), run the read-only helper `factory-settings` instead of reading the files
and merging them in your head:

```sh
sh .factory/bin/factory-settings                    # every key, its value in use and its source
sh .factory/bin/factory-settings commands.checks    # only the keys under a prefix (machine, models.tiers, state, ...)
sh .factory/bin/factory-settings --changed          # only what differs from the defaults
```

`--json` gives machine-readable output and `--target <dir>` another checkout. Each line is a key, its source
(`factory.yaml`, `core default <version>`, `machine.yaml` or `machine default`) and its value, merged as
`docs/factory-yaml.md` says: maps merge per key, lists and scalars replace. Machine settings show as `machine.<key>`.
The `state.*` lines are not keys: the core version and upstream (`.factory/core.lock`), the emergency stop and the
agent-token mode, each `unknown` when it cannot be read. It shares factory-doctor's reader, validation and redaction:
a `factory.yaml` the doctor would fail gives one line pointing here and no value, so run the doctor first. Relay the
lines the person asked about; a change to a value is a PR to `factory.yaml` (a human gate) or the person's own edit
of `~/.factory/machine.yaml`.

## Which model

Running the doctor and relaying its report is helper work: `models.helpers.read`. Deciding a fix (what to change in
`factory.yaml`, whether a core change goes upstream) runs on the caller's own model.
