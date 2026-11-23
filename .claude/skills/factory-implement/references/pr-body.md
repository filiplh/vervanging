# PR body

The PR body follows the repo's `.github/pull_request_template.md`: the factory installs it, and the template says what
each section holds (`core/templates/pull_request_template.md` in the factory repo). Read it and fill it in. This page
adds only what the template does not say.

- **Every section is filled in.** Write "none" rather than leaving one empty. Put the head SHA you ran the checks on
  after `- Head:`.
- **Language.** Write it in the language `AGENTS.md` sets for PR text, translating the headings if it asks for that.
- **Acceptance criteria.** Only `- [ ]` and `- [x]` lines, one per criterion; an open one says ": not met, because
  <reason>" and links a new follow-up issue. Notes go under Checks. (A project's own copy of the template may be
  older than this rule: factory-update never changes it.)
- **The issue line.** `Closes #<N>` only when the issue is fully done; otherwise `Refs #<N>` and what is left.
- **No template in the repo** (a project that removed it, or kept its own under another name: use that one). Then use
  these `##` headings in this order: What, How, Acceptance criteria (a list of `- [x]` and `- [ ]` items), Checks
  (Head, Automated, Real target, Left to the gate), Known limitations, Data impact, Needs confirmation, Self-check.
  Say in your report that the template was missing.
