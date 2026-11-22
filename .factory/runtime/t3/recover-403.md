# `recover-403`

**What it is:** a child dies with "Failed to authenticate. API Error: 403" and an "Attention Required" page. It is the
bot protection in front of the model API, not a real authentication problem, and it passes. In the incident that
taught this (L28), one child thread failed on every resume, even with a fresh context, while new children worked.

Recover at once, without asking the user and without halting the board:

1. **Resume once.** `continue` the child's thread: "Resume: your last turn stopped on a transient 403 from the model
   API. Continue issue #<N> where you stopped; your worktree and branch are as you left them." Do not set
   `freshContext`: it did not help. Comment the new task id on the issue.
2. **If the resumed turn dies on the same error, save the work.** `t3_thread_read` on the child's thread (`limit: 1`)
   gives `worktreePath` and `branch`. Save every commit not on the remote and every uncommitted change, outside the
   worktree, in a place that survives a lead handoff:

   `<out>` is the save folder, an absolute path: `<your home folder>/.factory/patches/<owner>-<name>/<N>-<UTC time as
   YYYYMMDDTHHMMSSZ>`. Fill it in once and write the same text, inside double quotes as shown, in every command below and in the brief of step 3.

   ```sh
   mkdir -p "<out>"
   git -C "<worktreePath>" fetch -q origin
   base=$(git -C "<worktreePath>" rev-parse -q --verify origin/<branch> || git -C "<worktreePath>" merge-base HEAD origin/<default branch>)
   git -C "<worktreePath>" format-patch -q -o "<out>/commits" "$base..HEAD"
   git -C "<worktreePath>" add --all --intent-to-add          # so new files appear in the diff
   git -C "<worktreePath>" diff HEAD --binary > "<out>/uncommitted.patch"
   ```

   Never paste a patch into an issue or PR comment. If both are empty, skip to step 3 without a patch.
3. **Start a fresh child** with the same spec: a 403 is not a depth problem, so no escalation. It takes over the dead
   child's slot. Its brief is the normal brief plus:

   ```
   Continue issue #<N> on branch <branch>. Earlier work is saved in <out>.
   git fetch origin && git switch -c <branch>-resume origin/<branch>      # branch never pushed: from origin/<default branch>
   git am "<out>"/commits/*.patch                                 # only if that folder has files
   git apply --index "<out>/uncommitted.patch"                    # only if the file is not empty
   Push with: git push origin HEAD:<branch>
   ```

4. **Tell people.** Comment on the issue (cause, the new task and thread ids, the patch folder) and tell the user in
   one line. Do not ask.
5. **If the fresh child also dies on a 403**, it is not transient. Start nothing more on that provider, tell the user,
   and wait. Never move the work to another provider or model.

The dead child's worktree stays until its PR is merged or closed; worktree clean-up removes it then. The patch folder
can go at the same time.
