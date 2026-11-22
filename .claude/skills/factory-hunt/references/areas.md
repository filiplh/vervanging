# Hunter areas: the overlay file

The project names its hunter areas in `.factory/hunters.md`. It is overlay content: the project writes and owns it,
`factory-update` never touches it, and changing it is a normal PR. The core reads it; the core never names an area.

Without the file, the lead uses one area per role in `factory.yaml` › `roles` (scope: the role's `owns`; tools: the
role's `skills`; kind: `bug`; depth: the core levels below) plus the core `process` area.

## Format

One `## <slug>` section per area, then an optional `## Priorities` section. The slug is lower case with `-`, becomes
the `hunter:<slug>` label, and may not be `process` (the core's process tester owns it).

```markdown
# Hunter areas

## <slug>

- **Kind:** bug | domain
- **Scope:** what this area covers: screens, flows, commands, files (glob list, same rules as `roles.<name>.owns`),
  or a way of attacking the whole app.
- **Not in this area:** what a neighbour covers, and which area: "<thing> → area `<other-slug>`".
- **Try:** the attacks and situations this area is about, most valuable first.
- **Tools:** project skills under `.claude/skills/` to load, `factory.yaml` checks or commands to run, test
  environments to use. Only tools the project already has, pinned.
- **Depth:** the levels for this area (see below), when they differ from the core levels.
- **Priority examples:** optional, area-specific examples per priority.

## Priorities

Project examples per level, on top of the core definitions. They may make a level more concrete; they never move a
whole class of bug below the core definition (data loss is never P3).

- **P0:** …
- **P1:** …
- **P2:** …
- **P3:** …
```

### Kinds

- **`bug`**: hunts defects with general testing skill. Runs on `models.agents.hunter`.
- **`domain`**: needs the product's domain knowledge to tell a wrong result from a right one (calculations, rules,
  regulations, a field's conventions). It loads the project's domain skills. Runs on `models.agents.domain_hunter`.

The process tester's kind is fixed by the core and runs on `models.agents.process_hunter`.

### Good areas

- **Non-overlapping.** Every bug has one obvious owner. Write the boundary both ways: if area A says "storage
  upgrades → area `upgrade`", area `upgrade` says what it leaves to A.
- **Split by attack, not only by folder.** Areas by role (paths) find local bugs; areas by attack (hostile input,
  assistive technology, old data, scale, interruptions, a full user journey end to end) find the bugs that cross
  folders. A good set has both, with boundaries between them.
- **Small enough for one pass.** If one pass never gets past the first depth level, split the area.
- **New areas from the evidence.** When fixes keep landing in a place no area covers, or one area keeps finding
  bugs of one kind, the lead proposes a new or split area in a PR to this file.

## Depth levels

Each pass hunts at one level. The lead moves an area one level deeper after a pass that found nothing new, and back to
level 1 when code in the area's scope has changed a lot since the last pass. An area may define its own levels; the
core levels are:

1. **Main paths.** Every flow in the scope, done the way a careful user would, plus the obvious mistakes (empty,
   wrong, missing input; cancel half-way).
2. **Every state.** Every screen, command or endpoint in each of its states (empty, one, many, error, loading,
   offline, no permission), on every supported screen size, input method and platform the project supports, with the
   accessibility tree and the copy checked against `.factory/voice.md`.
3. **Hostile and odd.** Hostile and huge input, repeated and concurrent actions, interruption and restart at every
   step, clock and locale changes, data written by older versions, limits of storage, memory and time.
4. **Cross-area journeys.** Long realistic sessions that cross into neighbouring scopes; bugs found outside the area
   go to the owning area as pointers.
