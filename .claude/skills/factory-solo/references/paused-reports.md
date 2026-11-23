# Paused reports first

**Paused reports first.** When the newest implementer report on the issue or its PR is a paused one
("Implementer report: #N, paused"), the work stopped mid-step, and the step-5 table in [SKILL.md](../SKILL.md#1-session-start) does not apply yet. Check the
[emergency stop](../SKILL.md#1-session-start) and take [the builder slot](../SKILL.md#the-builder-slot), then resume what the report
names:
- **A child built it** (the issue has its "started" comment): runtime: `continue` on that child's thread, with
  "Resume: the factory is no longer paused. Continue issue #<N> from the step your paused report names; your
  worktree and branch are as you left them." Then runtime: `wait`, as in [3. Build](../SKILL.md#3-build). Only when the
  thread cannot be continued: a new `start` with "finish issue #N on branch `<b>`", and tell the person that
  uncommitted work may be left in the old worktree (its path is in the report).
- **You built it:** reopen the worktree the report names, check it still exists on the report's branch
  (`git -C <path> status`), and go on with `factory-implement` from the checkpoint the report records, in that
  worktree. Never make a fresh worktree, reset, stash or check out over it: uncommitted work may wait there. If
  the worktree is gone, tell the person what the report says was uncommitted, and continue from the branch only
  after they agree.
- **A paused fix round** ("Round: fix round <n>"): resume it as above. It goes to [4. Review](../SKILL.md#4-review) only
  after its completed (not paused) fix-round report, at the head that report names: a new head, or the unchanged
  one when the round changed no code (see [Fix rounds](../SKILL.md#5-act-on-the-verdict)).
