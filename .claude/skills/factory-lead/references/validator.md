# The validator

Read it when the issue has an acceptance contract. [SKILL.md › Merge gate](../SKILL.md#merge-gate), rule 4,
requires its record on the current head.

**Validator.** When the issue has an acceptance contract, start the validator with the
[reference/briefs.md](../../../../.factory/reference/briefs.md) › Validator brief, on the issue's build spec, after the
[emergency stop](../SKILL.md#emergency-stop) check and `factory-usage may-start`. Start it again after every push to the PR: each
new head needs its own validation. Route its verdict like this:
- `fail`: like a review with P1 findings, a fix round that counts toward escalation.
- `cannot-validate`: to you, not a fix round. Supply what is missing (a tool, `commands.serve` or the contract) and
  start it again.
- Its "Also seen" items are filed as [follow-ups](../SKILL.md#follow-ups).
