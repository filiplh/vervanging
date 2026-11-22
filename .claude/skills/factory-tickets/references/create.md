# Creating the tickets: commands and checks

The commands `factory-tickets` runs, in order. `<repo>` is `project.repo` from `factory.yaml`. Each `gh` command is
for a project whose agent-token mode is off, the default; with the mode on, each one has its broker verb in the core's
[github-access.md](../../../../.factory/reference/github-access.md), and the differences are named below. Write every
body to a file in a scratch folder outside the worktree, and remove only the files you made.

## Body checks

Run these on every body before the list is shown (SKILL.md § 6), and again on any body you change. A body that fails
one is fixed before anyone sees the list.

1. **One "Blocked by" line**, in the grammar of the core's board reference › Follow-ups. When the factory tool is in
   the project, its own reader decides; otherwise count the lines that begin with the words, after any of
   `> * _ # -` and spaces, which must be exactly 1:

   ```sh
   grep -ciE '^[[:space:]>*_#-]*blocked[[:space:]_*-]*by' "<body file>"
   ```

2. **The contract section's heading words appear once**: on the heading line, nowhere else. The merge gate normalises
   the whole body (emphasis and backticks dropped, every run of non-letters one space, case folded) and refuses a
   second occurrence, also across a line break or run together. This approximates it for plain text, and must print 1:

   ```sh
   tr -d '*_~`\\[]' < "<body file>" | tr -cs 'A-Za-z' ' ' | tr 'A-Z' 'a-z' | grep -oE 'acceptance ?contract' | wc -l
   ```

   The gate is stricter still (HTML entities, look-alike letters, raw HTML before the heading), so write the body in
   plain text: no HTML other than the key comment on the last line.
3. **The heading is the template's, alone on its line at column 0**, followed by assertions or by exactly one line
   `none (<reason>)` from SKILL.md § 4's table, and then the "Owned paths" heading.
4. **Owned paths**: the heading is spelled as the template spells it; the section holds the paths as inline code, one
   list item each; the "Plan:" line after it holds no inline code.
5. **The key** is the last line, `<!-- factory:ticket <key> -->`, with a key that holds no space, `--` or `>`, and no
   other ticket in the list or on the board has the same key.

## Find existing tickets

A ticket counts as missing only when the body of **every** issue in the repo, open and closed, was read and none
holds its key. A lookup that may be incomplete proves nothing, so the rule is the factory tool's for its own lists:
pass an explicit limit, and an answer that holds as many issues as the limit may be cut short, so it is refused,
never used in part. Any failed read, or an answer of the wrong shape, is the same: stop, create nothing, and tell the
user which read failed. Never narrow the read to titles, milestones or a search: a ticket whose title was reworded and
whose milestone moved still holds its key, and the search index can lag.

Mode off, one read of every issue with its body:

```sh
gh issue list -R <repo> --state all --limit 9999 --json number,title,state,body,labels,milestone > "<scratch>/issues.json"
jq 'type == "array" and all(.[]; (.number | type) == "number" and (.body | type) == "string") and length < 9999' \
  "<scratch>/issues.json"
jq -r --arg src '<!-- factory:ticket <source>/' \
  '.[] | select(.body | contains($src)) | "\(.number) \(.state) \(.title)"' "<scratch>/issues.json"
```

The `gh` command must exit 0 and the second line must print `true`; otherwise stop. `false` because there are 9999
issues or more means the repo is too large to read whole this way: stop and say so.

Mode on, the broker's issue list carries no body, and its limit defaults to 100: list every issue with
`issue-list --state all --limit 9999`, refuse the answer the same way (an answer of 9999 issues or more is cut), then
read the body of **each** listed issue with `issue-view <N>` and look for the key in it. Every view must succeed; one
that fails stops the lookup. This is one call per issue, which is the cost of a complete answer.

The match rules are in SKILL.md § 5.

## Milestones

```sh
gh api repos/<repo>/milestones --paginate --jq '.[] | "\(.number) \(.title)"'
gh api -X POST repos/<repo>/milestones -f title="<phase heading>"
```

The second line only for a milestone the approved list says to create. Mode on: the broker has no verb that creates
a milestone, so list the missing ones for the user (or the lead, from its root checkout) to create, and wait.

## Create one ticket

Right before each one, the pause check as the core's board reference › How a pause check guards a step says: its own
command, its exit status read, the create a later command.

```sh
gh issue create -R <repo> --title "<title>" --body-file "<body file>" \
  --label "type:<type>,tier:<tier>,size:<S|M>,status:<ready|blocked>[,agent:<role or human>][,priority:<P>]" \
  --milestone "<milestone title>"
```

Leave out the labels SKILL.md § 3 says a ticket of that kind does not get (no `size:*` for `agent:human`; no
`status:*` and `size:L` for an epic). Note the number `gh` prints, and put it in place of the list reference (`T3`)
in every later body that names this ticket, before that body is created.

## Native dependencies

GitHub documents these in its REST API reference, "REST API endpoints for issue dependencies". The factory tool
reads them for every blocker check, and an issue whose native blockers cannot be read counts as blocked whatever its
"Blocked by" line says (`factory ready`, `factory unblock` and `factory claim` all refuse it). So a repo where they
cannot be read and written cannot run tickets at all: there is no mode that works from the "Blocked by" line alone.

**Read probe, before the first create.** Read the native blockers of one existing issue, the status issue
(`factory:status`) or any other:

```sh
gh api repos/<repo>/issues/<existing N>/dependencies/blocked_by --jq 'type'
```

It must exit 0 and print `array`. An empty list is a success (that issue has no blockers); a failed call (an HTTP
error such as 404, 403 or 410, a refused request) or anything that is not a list is a failed read. Mode on:
`issue-deps <existing N> blocked-by`, which must succeed and write a list. On a failed read, create nothing: stop and
tell the user that native issue dependencies cannot be read on this repo or host (quote the error), so the factory
tool would hold every ticket as blocked. When the repo has no issue yet, there is nothing to probe: the first ticket
created is read the same way right after it exists, and a failure there stops the run with that one ticket made.

**Write probe, on the first blocked ticket.** Dependency order puts a ticket and its first blocker early; the first
ticket that has a blocker is where writing is proved. Its add and read-back (below) must both succeed before any
further ticket is created. A refused write stops the run the same way: say that native dependencies cannot be written
here, and name the tickets already created, which the user decides about (they carry their keys, so a later run after
the host is fixed creates only the rest).

**Add one per blocker,** after the blocked ticket exists (the core's board reference › Follow-ups):

```sh
id=$(gh api repos/<repo>/issues/<blocker> --jq .id)
gh api -X POST repos/<repo>/issues/<new N>/dependencies/blocked_by -F issue_id="$id"
```

`issue_id` is the blocker's `id` from the API, not its number. Mode on: `issue-add-blocker <new N> <blocker>`.

**Read them back** and compare with the body's "Blocked by" line; the call must exit 0, and the two sets of numbers
must be equal:

```sh
gh api --paginate repos/<repo>/issues/<new N>/dependencies/blocked_by --jq '.[].number'
```

Mode on: `issue-deps <new N> blocked-by`. A missing number is added once more and read again; still different, or
any failed add or read, stops the run as SKILL.md § 7 says. A failed read is never taken for an empty list.
`gh issue create` also takes `--blocked-by`, which sets the same dependencies at creation; the factory uses the
endpoint above because it is the one with a broker verb, and reads back either way.

## Epics

Create an epic after its children, so its acceptance criteria name them (`- [ ] #<child>`). Its labels: `type:epic`,
one `tier:*`, `size:L`, the milestone, no `status:*`. Its "Blocked by" line is
`Blocked by: none (an epic: its child tickets carry the blockers)`, so no native dependency is set on it. The
factory's status update lists an open epic under "No status label": that is where an epic belongs, since only its
children are work.
