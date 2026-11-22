# The install PR

Title: `chore: install factory <version>`. Branch: `chore/factory-install-<version>`. One PR per install; a re-run
with changes pushes to the open one and updates its body.

Fill in every section from what actually happened: the apply report, the label and status lines, the commands you
ran and their real output. Never claim a check you did not run.

```markdown
## What

Installs the agentic software factory, core <version>, in solo|team mode. After this merges, agents work from this
repo's issues through the factory's skills; you decide at the human gates.

Closes #<N> <the bootstrap issue, when there is one; otherwise leave this line out>

## Answers

| Setting | Value | From |
| --- | --- | --- |
| Languages of user-facing text | `xx`, `xx-YY` | detected in <where> / your answer |
| Mode | solo | your answer |
| Setup | `<command>` | detected in <where> |
| Verify | `<command>` | … |
| … one row per answer, including the ones taken as recommended without a question | | |

## Files

- **Overlay, now yours:** `factory.yaml`, `AGENTS.md`, `CLAUDE.md`, `.factory/roles/…`, `.factory/review-checklist.md`,
  `.github/pull_request_template.md`. The `<!-- fill in -->` comments in `AGENTS.md`, the role files and the
  checklist are yours to write; the factory works without them, but better with them.
- **Core, never edited here:** `.claude/skills/factory-*`, `.claude/agents/factory-*.md`, `.factory/` (bin,
  reference, runtime, defaults, recipes), `.github/workflows/factory-*.yml`. `.factory/core.lock` holds core
  <version>, the factory repo it comes from (<upstream>), and the hash of each of these <N> files; `factory-update`
  changes them in a PR.
- **Merged:** `.claude/settings.json`, `.codex/config.toml` (sandbox, permissions, hooks). <or, when the apply said
  `skipped .claude/settings.json`: "Not written: this core version has no sandbox templates. The hosts and caches the
  stack needs, for later: <the detected lists>.">
- **CI:** `.github/workflows/factory-*.yml` installed / proposed below, next to your own workflows / not written,
  because `ci.pr` is empty.
- `.agents/skills` → `.claude/skills`, so Codex finds the same skills.

## Kept, merged and proposed

Nothing that was here is overwritten. <or, on a fresh repo: "A new repo: nothing was here.">

- **Kept as they were:** <every `kept` line with its reason (the project's workflows, rules files, settings it could
  not merge, labels with the project's colours), every `differs` line, or "nothing">
- **Merged into your files:** <every `merged` line: what was appended to `AGENTS.md` or `CLAUDE.md` (every line of
  yours is unchanged; the PR diff shows the addition), and the settings merge>
- **Changed in your settings:** <every `replaced` or `kept` merge note, or "nothing">
- **Proposed, not applied:** <every `proposed` line; each diff in a collapsed block below, or "nothing">

<details><summary>Proposed: <path></summary>

```diff
<the diff from the proposals folder>
```

</details>

## On GitHub, already done

- Labels: <N created, M updated (names), K unchanged>.
- Labels kept with your colours or descriptions: <names, or "none">.
- Status issue: #<N> "Factory status", pinned / already there, left as it is / your issue #<N> adopted (labelled and
  pinned; title and body untouched).

## Human steps

- [ ] Review the answers above; change any of them in this PR.
- [ ] Approve each non-GitHub action in the CI workflows (gate H2): <action@sha # tag, or "none">.
- [ ] Give the agents their own fine-grained token for this repo and set up the machine (the factory's agent token
      guide). Until then, agents use your own `gh` login.
- [ ] <one line per deploy recipe human step or secret name, or remove this line>
- [ ] Merge this PR. Nothing else changes until it is merged.

## Checks

- Head: <sha>
- `factory-install apply --dry-run` after the install: <"every line unchanged" or the lines>
- `factory-install check`: <its output>
- Verify: <ran `<command>` locally: result with counts / not run, because …>
- CI: the new `Factory CI` workflow runs on this PR once it is marked ready, if Actions is available for the account.
- Review: the standard tier's first review, on <spec> (no issue and no tier, so factory-init fixes it): <started as
  "Review PR #<P>" / waits, because no runtime could start it>.
```

Put the full apply report (the `--report` file) in a collapsed `<details>` block at the end.
