# The round rule

Read it before the third review of a PR. [SKILL.md › Reviews](../SKILL.md#reviews) holds the fix rounds and
the escalation after two of them.

**The round rule.** Count rounds as [model policy](../../../../.factory/reference/model-policy.md#rules) rule 3 does: the
third review is the one after the second counted fix-round report (adaptations excepted). When it finds new P0–P2 findings of the same kind as earlier rounds, stop patching case by case:
before the next round, name the kind of finding and its structural fix at the top of the fix-round brief (a real parser,
descriptor-relative writes, a staging copy, a runtime proof, a strict subset that refuses the rest), or put it to the
user as a design question ([human gates](../SKILL.md#human-gates)). This comes on top of escalation, not instead of it. A strict
subset keeps no exemption it cannot delimit for certain: name each exemption it does keep in the fix-round brief, with
its own edge-case test cases there and in the next review brief, since a kept exemption is where the next review finds
the hole.
