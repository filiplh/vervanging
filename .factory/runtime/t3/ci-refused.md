# PR watches while CI is refused for billing

**While CI is refused for billing, do not watch PRs.** Once the lead has confirmed that the account's runs are refused
(the signature in the [merge gate](../../reference/merge-gate.md) › "Refused is not red": the failed run has no
steps and no runner, and its annotation names billing), every push wakes it with "checks failed", and each wake only
repeats that check. The watch cannot be limited to comments and reviews, so for that repo the lead stops watching PRs:
it still `link-pr`s each one, skips `watch-pr` (and `unwatch-pr`s a PR it already watches), and relies on the wakes it
gets anyway: a builder's or reviewer's completion, which carries the PR and the report. The gate's rule is
unchanged: local evidence for the current head stands in for a refused run, and a job that ran and failed is still
red.

**Resuming.** The lead checks CI again once at the next push it makes or sees, and when the user says billing is fixed:
it reads that one run's state (`gh run list --branch <branch> --limit 1`). A run that starts (a runner took it, or a
step ran) means CI works again: it removes the "local gate while CI is refused" temporary rule from the status issue
and goes back to `watch-pr` for the open PRs, as above. A refused run again means the signature still holds: it
changes nothing and checks again only at the next push.
