# Forms and destinations

The lesson has passed the bar in SKILL.md § 2. This file says how to choose its form, how to prove a check, and where
a project lesson goes.

Before choosing, read what already exists near the lesson: the checks in `factory.yaml` › `commands` (with their
`when`), the lint and test setup the project already runs, the review checklist, the hunter areas, the rules file and
the role files of the roles involved. Weigh any prevention idea already on the incident: the fix PR's description, a
reviewer's suggestion, a hunter's "why it was not caught".

## The forms, strongest first

Take the first form that holds. A run produces one strongest form, plus at most one short prose rule for what that
form cannot carry.

### 1. Remove the cause

Holds when the mistake was possible because there are two ways to do the same thing (two helpers, two config sources,
two paths to the same state). The durable fix is one owner and one way. That changes product code, so file it as an
issue for the owning role (`agent:<role>`, a tier from its work kind) and do not also write a rule asking people to
pick the right one, unless the issue will take a while: then a temporary rule that links the issue and retires with it.

### 2. A check

Holds when something mechanical can detect the defect: a test, a lint rule, a type, a script in `commands.checks`, a
hook, or a check in the gate.

- **It runs where checks already run.** `commands.verify`, or a `commands.checks` entry whose `when` matches the paths
  at risk. A check that runs only when someone remembers to run it is a prose rule in disguise. If the check needs a
  `when` change or a new `commands.checks` entry, that is a `factory.yaml` change (gate H4).
- **Its failure says the fix.** The message names what is wrong and what to do instead, so an agent can fix it without
  looking anything up. "Use X instead of Y (see #N)" beats "invalid".
- **It is proven both ways.** It passes on the current tree, run the way the project runs it, and it fails on the
  defect's shape in a throwaway copy of the tree (a scratch branch or a temporary copy, never the working tree, not
  even briefly). If either result cannot be shown, it is not a check yet: describe it in the issue as the recommended
  form and fall back to the next form until it exists.
- **Existing violations.** When a new lint rule flags code that is already there and the project keeps a baseline or
  suppression file, list only those violations there, so new code still fails.
- **Limits.** A check that needs a new tool, package, plugin or CI action is gate H2: ask first. A check that needs
  product code changed (a new log field, a type change, an assertion in the code) is an issue for the owning role, not
  something this run writes.
- **A check of the factory's own workflow** (the gate, a hook, the `factory` command) lives in the core: it is a
  general lesson ([upstream.md](upstream.md)).

### 3. A watched item

Holds when the defect is visible to a person or agent who looks in the right place, but no check can detect it.

- **Review checklist** (`.factory/review-checklist.md`), when a reviewer can see the defect in a diff. Add it under
  "Areas that need a closer look" or the section it belongs to, say what to look at and how to tell, and name the
  test or command that proves it when there is one. A defect class enters the checklist only after it actually
  happened (a review finding the author fixed, a fix commit, an escaped bug), never because it might.
- **Hunter area** (`.factory/hunters.md`), when the defect shows up only in the running app and hunters should try
  it: add it to the area's "what to try", or to its priority examples when hunters misjudged the priority. Keep the
  area boundaries intact (no overlap with another area).

### 4. A prose rule

Holds for reasoning that code, checks and checklists cannot carry: a rejected alternative, a constraint from outside
the repo, the reason a check exists.

- One condition, stated so it stays true without volatile names or numbers ("never X when Y, because Z"), in the
  destination's style and language.
- It names the check or checklist item it explains, when there is one.
- A rule that holds only while something outside the repo holds (an open upstream bug, a tool version, a platform's
  behaviour) says what would retire it and how to check, so a prune can retire it later.
- No session narrative, no list of what was changed: that belongs in the PR.

## Where a project lesson goes

| The lesson concerns | Destination | Gate |
| --- | --- | --- |
| All work in the project: architecture, data, tests, security, flow | `AGENTS.md`, in the section it belongs to | H4 |
| One role's paths and work | `.factory/roles/<role>.md` › "Rules you never break" or "Tests" | none of its own; a process change is H4 in the rules file instead |
| What a reviewer must look at on a diff | `.factory/review-checklist.md` | none of its own; a change to the review process itself is a process change |
| What hunters should try or how they rank it | `.factory/hunters.md` | none of its own |
| Commands, checks and their `when`, work kinds, project gates, roles and owned paths | `factory.yaml` | H4 |
| Terms and tone of user-facing copy | `.factory/voice.md` | none of its own |
| How the domain behaves (a rule of the product's field) | the project's domain skill under `.claude/skills/<name>/` | none of its own; a new skill, or one copied from elsewhere, is H2 |
| A test, lint, script or hook in the project's code | the code, through an issue for the owning role | H2 when it needs a new tool |
| A settled decision turned out wrong | where `AGENTS.md` says decisions live, as a proposal for the user | H4 |

"None of its own" means the destination is not on the gate list by itself. The change still gets a PR, a review and
the merge gate, and a process change still needs the user's OK wherever it would land (SKILL.md § 4).

When a lesson would fit two destinations, pick the one the agent who would have made the mistake reads at that
moment: the builder reads the rules file and its role file, the reviewer reads the checklist, the hunter reads its
area. Never write the same lesson into two files; point from one to the other instead.

## A good lesson, a bad lesson

- Good: a check in `commands.checks` whose failure says "migration missing for changed stored shape; add one under the
  migrations folder (see #N)", with a one-line rule in the role file explaining why old data must still load.
- Good: a checklist item "a new screen is opened at the smallest supported size; attach what you saw (#N)".
- Bad: "Be careful with migrations." No condition, no reason, no link, nothing to check.
- Bad: the same rule pasted into `AGENTS.md`, two role files and the checklist.
- Bad: a rule that says "always run the extra check" when the check could have been given a `when` that runs it.
