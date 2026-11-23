# The bound and the round rule

**The bound.** Count fix rounds as model policy rule 3 defines them, from the PR, never from memory. Escalate (model policy,
rule 3) when a PR has had **two fix rounds** that count (an adaptation round, caused only by the default branch moving and
headed `### Fix round <n> (adaptation: <what moved>)`, does not), when a review says `needs-rework` for lack of depth, or when the builder
is stuck: one step up `models.escalation` from the current build spec, with the escalation comment and label from
[board.md](../../../../.factory/reference/board.md) › Escalation record. The next round is then a new runtime: `start`
with the escalated spec and the lead's fix-round brief, unless this session runs exactly that spec. The issue never
steps back down. The step onto the top model (`claude-fable-5-2`) needs the owner's OK on the issue (model policy, rule 3);
without it, and at the top of the ladder, the issue gets `status:needs-human`: tell the person what is still open
and stop working on it.

**The round rule.** (The third review is the one after the second counted fix-round report, adaptations excepted.) When the third review finds new P0–P2 findings of the same kind as earlier rounds, stop patching
case by case: name the kind and its structural fix before the next round, as `factory-lead` › Reviews › The round rule
says, or put it to the person as a design question. Escalation still applies. A brief you give a child follows
[briefs.md](../../../../.factory/reference/briefs.md)'s short-brief rule.
