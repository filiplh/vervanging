# Metrics

`factory metrics` prints one short table for the project: per tier and in total, the issues merged in the window, their
counted fix rounds, the P0-P2 findings of each first review and the model fit lines, then this project's runs and
weighted hours from the machine's usage ledger, the usage-limit hits per provider and the model fit counts per work
kind (`factory metrics --help` says where each number comes from). On a subscription that is the cost: runs, hours and
limit hits per merged issue, not money.

- **When:** with the first status update of each day that merged something, at the end of a milestone, and when the
  user asks. `factory metrics --post` adds it to the status issue as its own comment, after the emergency-stop check;
  without `--post` it only prints. Default window 30 days (`--days N`).
- **Cannot tell** in the table means a read did not finish: nothing was posted. Fix the reason it names and run it
  again; never fill in a number by hand. A usage line that cannot tell is posted as it is; tell the user what the
  ledger line names, since only they fix the ledger.
- **What it feeds: tier-table proposals** (the model policy, rule 6). When a work kind's fit counts lean the same way
  more than once ("too weak" or "more than needed" outnumber "right" over several merged issues), or a tier's fix
  rounds or first-review findings per merged issue stay high, propose the change to the user: the kind, the counts,
  the window and the move (a `work_kinds` entry to another tier, or a table entry). The change is a PR to
  `factory.yaml` or the core that the user approves; you never change a table yourself, and a proposal never moves
  an issue that is already running.
