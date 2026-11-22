# Instruction review

The reviewer walks this checklist when a PR changes **instruction text**, after the core protocol and before the
project's review checklist. The steps, the core protocol, the priorities and the comment format are in the reviewer
agent, `core/agents/reviewer.md` (`.claude/agents/factory-reviewer.md` in a project). A diff with no instruction text
never loads this file.

Instruction text is text an agent loads and obeys: a `SKILL.md` and the files of its skill folder, an agent
definition, a role file, a core reference, the rules file (`AGENTS.md`, `CLAUDE.md`), the review checklist, the voice
and hunter files, a brief or report template, and any file the rules file or `factory.yaml` sends an agent to as rules.
A skill's or agent's frontmatter `description` counts too: it decides when the file loads. A wrong sentence there
changes what the next agent does, and nothing fails loudly, so read it as you read code.

## How to walk it

For each item, check its trigger against the diff. An item whose trigger does not match is skipped silently. When it
matches, look where the item says and file a finding only when you can name the concrete case that goes wrong: which
agent, on which step, does what. The P-level given is the usual one; the core priorities decide in the end.

A clean result is a valid one. These are not findings: two copies of a rule that agree, a long file, a passage you
would have worded or organised differently, and a rule you merely suspect is no longer needed.

## Boundary with the core protocol

The core protocol already covers these for instruction text, and this checklist does not repeat them: whether the
text does what the issue asks (correctness), the owned paths (scope), secrets and personal data (security), a change
to the rules file, `factory.yaml`, a settled decision or a process (human gate H4, filed as a gate, not again here),
the evidence, and the project's neutrality check where it has one. The install link check resolves relative Markdown
links and anchors between core files; item 2 covers what it does not read.

## The checklist

1. **Two files rule differently on one step.**
   *Trigger:* the diff adds or changes a rule (a step, a default, a "never", a number, a label, a file it writes) on
   something another instruction file also rules on.
   *Look:* search the core and overlay instruction files for the step's key word (the command, the label, the file,
   the step's name) and read every hit next to the new text. An agent that loads only one of them must end up doing
   the same thing. A narrower file whose scope explains the difference, or that says which rule it overrides, is an
   override, not a conflict.
   *Usually:* **P2**; **P1** when one side is a gate, a safety rule, a secret rule or a release step.

2. **A name that no longer resolves.**
   *Trigger:* the diff names a path, a command or flag, an anchor, a skill or agent, a `factory.yaml` key or a label;
   or it renames, moves or removes something instruction text names.
   *Look:* each named path exists at the PR head, in the layout where the file is read (a core file is read where the
   installer puts it); each command and flag is defined in the script or tool it names (read it, never run it); each
   key is in the schema. After a rename, search for the old name in every instruction file, overlay files included.
   Paths in backticks and prose, and overlay files, are outside the install link check.
   *Usually:* **P2**; **P3** when the broken name sits in an aside and the step can still be followed.

3. **A duplicate that has drifted.**
   *Trigger:* the diff changes a rule that is also stated somewhere else: a summary table, a restatement in another
   skill, a description that lists the steps.
   *Look:* search for a distinctive phrase of the old wording. Every copy must still say the same; if one now differs,
   the fix is to bring it in line or to replace it with a pointer to the one file that owns the rule.
   *Usually:* **P2** when the copies now prescribe different actions; no finding while they agree.

4. **A new rule that quietly loosens a prohibition or a gate.**
   *Trigger:* the diff edits a "never", "only", "stop", "must" or "refuse", an exception list or a gate condition; or it
   adds an "unless", "may", "when in doubt", "or", a default or a fallback next to one.
   *Look:* take a case the old text refused and run it through the new text. If it now goes through, the issue must
   ask for that, in words. When the change touches a human gate or a settled decision, file it under the core
   protocol's human gates instead.
   *Usually:* **P1** when it weakens a gate, a safety, secret or release rule without the issue asking; **P2**
   otherwise.

5. **A description that collides with another skill's triggers.**
   *Trigger:* the diff adds or changes a skill's or agent's frontmatter `description`, or adds a skill.
   *Look:* compare the requests and situations it names with the descriptions of the skills that load beside it, core
   and the project's own domain skills. Two descriptions claiming the same request mean the wrong one can load. Also
   check that the description promises nothing the body does not do, and the reverse.
   *Usually:* **P2**; **P3** when the overlap is narrow and both bodies send the agent to the same place.

6. **A rule added for one incident that should be a check or a test.**
   *Trigger:* the diff adds a prose rule that answers one incident, especially a narrow condition ("when X in file Y,
   do Z").
   *Look:* could a test, a lint rule or a script check catch the defect's shape? If so, the check is the stronger form
   (the `factory-compound` skill's form ladder): ask for it, or for a follow-up issue that adds it, and for the prose to
   keep only what the check cannot carry. In an overlay file the rule keeps its incident link (`factory-compound` ›
   Every lesson keeps its incident link); never ask for it to be removed.
   *Usually:* **P3**; **P2** when the prose alone guards a gate or a release that a check could enforce.

7. **Time-bound wording.**
   *Trigger:* "now", "no longer", "new", "recently", "currently", "for now", "instead of the old", "since", a date, a
   version that is not pinned on purpose, or a model name outside the model policy.
   *Look:* the rule should read as the only rule there ever was. Relative wording describes a change the next reader
   never saw, and leaves them unsure which behaviour holds. A temporary rule says what retires it. In a core file, the
   story of how a rule came about belongs in git history and the PR; in an overlay file the incident link stays
   (item 6).
   *Usually:* **P3**; **P2** when the wording leaves it unclear which of two behaviours is current.

8. **Pressure instead of a reason.**
   *Trigger:* the diff adds capitals or bold for emphasis (MUST, NEVER, CRITICAL, IMPORTANT), "!!", "absolutely",
   "under no circumstances", with no reason beside it; or a hedge ("try to", "if possible", "ideally") on something
   that is required.
   *Look:* the next agent needs the reason to apply a rule to a case nobody foresaw. Ask for the plain rule with its
   "because"; a hedge on a requirement becomes a plain instruction. Emphasis is fine on one rule that has been broken
   before, with its reason. Trigger text, a frontmatter `description`, may say firmly when to load the skill.
   *Usually:* **P3**; **P2** when a hedge turns a required step (a check, a gate, a stop) into an option.
