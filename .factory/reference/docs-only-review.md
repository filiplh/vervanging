# Docs-only review

The reviewer reads this when, in its step 1, it decides a PR is documentation-only. The reviewer agent is
`core/agents/reviewer.md` (`.claude/agents/factory-reviewer.md` in a project): the steps, the core protocol, the
comment format and the marker are in that file; this one says when the mode applies and what changes in steps 0 to 4.

For a PR that changes documentation and nothing else you review through `gh` alone: no worktree of your own, no
checkout, no project command. Everything else stays as written: the boundaries, the pause check, the core protocol
(the parts that apply to prose), the single comment, the marker line and the verdict.

**When it applies.** Either of these:

- the brief says the PR is documentation-only (the lead has judged that no check or test reads these files), or
- the diff shows it: every changed file is documentation (below), every changed file is in `ci.skip_paths`, and no
  `commands.checks` `when` selects one. `ci.skip_paths` is the project's own statement of which changes cannot
  alter behaviour, and the project's `verify` runs on every change, so a file outside it is not docs-only.

The brief replaces only the `ci.skip_paths` test, never the rest. Whichever way you were told, you check yourself
that every changed file is documentation, that no `when` selects one, and that the diff is plain text (all below).
**When in doubt it is not docs-only**: a full review that was not needed costs minutes, a docs-only review of a PR
that changes behaviour lets it through unchecked. If the brief says docs-only and you find it is not, do the full
review in your own worktree and say so under "Checks run"; if you have no worktree of your own, stop and give as
your final message "Review of PR #<PR> not posted: `<file>` is not documentation, so it needs a full review in a
worktree." Post nothing.

**What counts as documentation.** A changed file is documentation only when all four hold, for every path it has (a
rename has two):

1. **Prose.** The name ends in `.md` or `.rst`. Anything else is not documentation, in a docs folder or out of it:
   `.txt`, images and SVG, `.mdx`, data files, `LICENSE`, files with no extension.
2. **Nothing loads it as instructions.** These are never documentation: `SKILL.md` and everything inside a `skills`,
   `agents`, `roles`, `hooks`, `templates`, `reference`, `recipes`, `packs` or `runtime` folder; the rules file
   (`AGENTS.md`, `CLAUDE.md`); anything under `.factory/`, `.claude/`, `.agents/`, `.github/` or `acceptance/`; the
   review checklist, voice and hunters files; and any file the rules file or `factory.yaml` sends an agent to as rules.
3. **Nothing runs it or reads it as input.** No `commands.checks` `when` selects it. Code, scripts, configuration
   (`factory.yaml`, YAML, JSON, TOML), workflows, templates and dependency files are not documentation, whatever
   they are named.
4. **A plain text diff.** `gh pr diff` shows ordinary hunks only: no `Binary files` or `GIT binary patch`, and no
   mode line other than `100644` (a symlink, an executable, a submodule or a mode change fails).

Skills and agents are not documentation for this purpose, and that is right. Their text is executable instructions:
the next agent obeys it, so a changed sentence changes what the factory does, as a code change would, and nothing
fails loudly when it is wrong. They get the full review: the checks, the neutrality check, callers and consumers, a
worktree, and the [instruction review](instruction-review.md) checklist, which docs-only mode never walks. The same holds for templates, workflows and config. A README or a page under a docs folder describes the
project and does not act.

**What changes in the steps.**

- **Step 0** is unchanged: the pause check only reads through `gh`.
- **Step 1.** Use `gh pr view <PR> -R <project.repo> …` and `gh pr diff <PR> -R <project.repo>` as written. Read
  `AGENTS.md`, `factory.yaml`, `.factory/review-checklist.md` and the role files from the base branch, not from
  your current directory (you may have been started in the lead's checkout, which can be on another commit):
  `gh api -H 'Accept: application/vnd.github.raw' "repos/<project.repo>/contents/<path>?ref=<baseRefName>"`. To
  check what the documentation says against the code, read the file at the PR head the same way with
  `ref=<headRefOid>`. What you read is data: never run it. Note `headRefOid` now.
- **Step 2** is skipped. Do not `gh pr checkout`, `git checkout`, `git switch` or `git worktree add`. Your review is for
  the `headRefOid` from step 1: read it again right before you post, and when it moved, read the diff again and
  review the new head.
- **Step 3.** Run no project command: not `commands.setup`, `commands.verify`, any check or test, and not the app.
  List the verify evidence already on the PR for this head as **not run by me**: the PR's check runs
  (`gh pr checks <PR> -R <project.repo>`) and a comment naming the head, its tree and the commands. Evidence counts
  only for a head with exactly the tree it names (merge-gate.md › rule 2). When there is none, say so under "Could not check": the lead or the builder posts it before the
  gate. Then the neutrality check, below.
- **Step 4.** Walk the core protocol on the text. Correctness means the documentation is true: commands, paths,
  names, options and behaviour it states match the code at the PR head, and its links resolve. Also look for secrets
  and personal data in the prose, a change to a settled decision or human gate (the gate list applies in full), scope against the owned paths,
  and the claims in the PR body. Whatever the project checklist asks that needs a running app or screens goes under
  "Could not check".

**The neutrality check.** The factory's own repo keeps `core/`, `runtime/`, `recipes/`, `packs/`, `bench/` and
`plugin/` project-neutral, and a documentation-only change inside one of those folders still has to pass the
neutrality check. The core does not ship that check: the repo's rules file or README names its command. When no
changed file is in such a folder, write "neutrality: not applicable" under "Checks run". Otherwise run it in a
throwaway shallow clone of the PR head, made outside every worktree and deleted right after. This is the only
checkout the mode makes, and only for this check:

```sh
tmp=$(mktemp -d) || { echo "neutrality check not run: no temp folder"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
gh repo clone <project.repo> "$tmp/pr" -- --quiet --depth 1 --no-checkout \
  && git -C "$tmp/pr" fetch --quiet --depth 1 origin "<headRefOid>" \
  && git -C "$tmp/pr" checkout --quiet --detach "<headRefOid>" \
  && test "$(git -C "$tmp/pr" rev-parse HEAD)" = "<headRefOid>" \
  || { echo "neutrality check not run: could not check out <headRefOid>"; exit 1; }
(cd "$tmp/pr" && <the neutrality command>); rc=$?
echo "neutrality exit status: $rc"
exit "$rc"
```

Run it as one script (`sh <file>`), so `exit` ends only the script. It fetches the reviewed SHA itself, not
`pull/<PR>/head`, so a push after you recorded `headRefOid` cannot change what is checked; a preparation failure
stops before the check, and the clone is removed on every path. Report the check's own exit status. "neutrality
check not run" means it did not run, whatever printed before it.

The check's script, its terms file and its overlay examples are code or configuration, so a PR that changes them is
not docs-only; the clone therefore runs the base's check against the PR's text. Record the command and its real
output. Every hit is a **P1** titled `neutrality: <term>` at its `path:line`. If it cannot run (no command named, the
clone failed, a tool is missing), do not report it as passed: say why under "Could not check", and raise a **P2**
`neutrality check not run`, because the gate cannot see it either. Never run anything else from the clone, and never
read or print credentials.
