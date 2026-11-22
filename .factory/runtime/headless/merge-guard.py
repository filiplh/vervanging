#!/usr/bin/env python3
"""merge-guard: the headless runtime's merge denial (runtime/headless.md › Hooks and the gate). A headless run never
merges, whatever factory gate says; this holds it in two places, both installed by the runner for each run only:

    python3 -I -B merge-guard.py --hook        a Claude Code PreToolUse hook, added with --settings beside the user's
                                               and the project's own hooks: the call as JSON on stdin; exit 2 denies
    python3 -I -B merge-guard.py --gh ARG...   the `gh` first on the run's PATH (Claude and Codex alike): refuses a
                                               merge, else runs the real gh ($FACTORY_HEADLESS_GH) with the same
                                               arguments

What counts as a merge, on the text with quotes and backslashes removed, in lower case: the word `merge` (`gh pr
merge`, `pulls/12/merge`, `--merge`), `pr-merge`, `/merges`, `mergePullRequest`, `enablePullRequestAutoMerge`,
`mergeBranch` and `auto-merge`. A hook call is denied when a Bash command names such a word and a GitHub client (gh,
factory-github, hub, curl, wget, api.github.com), or when any tool's name holds `merge` (an MCP server's merge tool).
It refuses more than it must on purpose: `gh pr comment 12 --body "merge it"` is refused too (write bodies with
--body-file), and `git merge` alone passes. An input it cannot read is denied.

Its limit: it is a word match over a command's text and arguments, like the core hooks, so it guards against mistakes,
not against an agent set on getting around it. A merge whose words are not in the command gets past it: a mutation read
from a file (`gh api graphql -F query=@file`), an absolute path to the real gh, or code that calls the API itself.

Standard library only. It reads no file and no credential, and prints only its fixed refusal.
"""

import json
import os
import re
import sys

REASON = ("refused: a headless run never merges, whatever factory gate says (runtime/headless.md › Hooks and the "
          "gate); a person merges after the gate passes. A comment that mentions the word goes in --body-file")
CLIENT = re.compile(r"(?<![\w.-])(gh|factory-github|hub|curl|wget)(?![\w-])|api\.github\.com")
MERGE = re.compile(r"(?<![\w-])merge(?![\w-])|pr-merge|/merges?(?![\w-])|mergepullrequest|enablepullrequestautomerge"
                   r"|mergebranch|auto-?merge")


def normal(text):
    return re.sub(r"[\"'\\`]", "", text).lower()


def merge_command(command):
    t = normal(command)
    return bool(CLIENT.search(t) and MERGE.search(t))


def merge_args(args):
    return bool(MERGE.search(normal(" ".join(args))))


def deny(why=REASON, code=2):
    sys.stderr.write(why + "\n")
    return code


def hook():
    try:
        data = json.loads(sys.stdin.read(1 << 20) or "null")
        if not isinstance(data, dict):
            return deny("refused: the headless merge guard cannot read this call")
        name = data.get("tool_name")
        if not isinstance(name, str):
            return deny("refused: the headless merge guard cannot read this call")
        if "merge" in name.lower():
            return deny()
        if name == "Bash":
            tool_input = data.get("tool_input")
            command = tool_input.get("command") if isinstance(tool_input, dict) else None
            if not isinstance(command, str):
                return deny("refused: the headless merge guard cannot read this command")
            if merge_command(command):
                return deny()
        return 0
    except Exception:  # noqa: BLE001 (a hook that fails any other way lets the call through, so deny)
        return deny("refused: the headless merge guard cannot read this call")


def gh(args):
    if merge_args(args):
        return deny(code=1)
    real = os.environ.get("FACTORY_HEADLESS_GH", "")
    if not os.path.isabs(real) or not os.access(real, os.X_OK):
        return deny("refused: the real gh is not known to the headless gh shim (FACTORY_HEADLESS_GH)", 1)
    os.execv(real, [real] + list(args))
    return 1


def main(argv):
    if argv[:1] == ["--hook"] and len(argv) == 1:
        return hook()
    if argv[:1] == ["--gh"]:
        return gh(argv[1:])
    return deny("usage: merge-guard.py --hook | --gh ARG...", 64)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
