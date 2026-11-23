# Idle capacity goes to bug hunters

Read it when a builder slot is free and no ready issue can take it ([SKILL.md › Never
idle](../SKILL.md#never-idle)).

- **Idle capacity goes to bug hunters** (hunt mode). The `factory-hunt` skill holds the rules
  ([`../../factory-hunt/SKILL.md`](../../factory-hunt/SKILL.md)): when to hunt (section 1), areas (2), models and the
  brief (3), triage (6). Follow it; this skill does not restate it. Your part:
  - **decide there is idle capacity:** a builder slot is free and no ready issue can take it (blocked, gated or
    overlapping), and the other conditions of its section 1 hold;
  - **start hunters within the builder slots:** each takes one, like a builder, through runtime: `start`, and gives
    it back when it reports; a buildable ready issue always wins a freed slot;
  - **triage their issues** as they arrive, by its section 6, so P0–P2 fixes enter this loop like any other issue.
