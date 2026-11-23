#!/usr/bin/env python3
"""The factory tool's own subcommands, run by `factory <sub>` (core/bin/factory, next to this file).

    python3 -I -B factory.py help
    python3 -I -B factory.py ready [--json]
    python3 -I -B factory.py unblock [--apply] [--json]
    python3 -I -B factory.py claim <N>
    python3 -I -B factory.py verify [<P>] [--why <reason>]
    python3 -I -B factory.py verify --no-heavy
    python3 -I -B factory.py lock heavy -- <command> [<argument>...]
    python3 -I -B factory.py gate <P> [--record]
    python3 -I -B factory.py status [--dry-run] [--note "<section>: <text>"]...

What each subcommand does is the board's rules, written once in reference/board.md (labels, Unblock, Claim, Pause)
and in the factory-lead skill › Picking work (the order), and the merge gate's, in reference/merge-gate.md (rule 2:
which checks, local evidence, running the checks yourself) and reference/deploy-contract.md (rule 2, link 4: the
evidence record); this file implements them and does not restate them.

Exit codes: 0 done; 1 could not finish (GitHub, factory.yaml, the machine settings, git, the agent-token mode; a rule
gate cannot judge); 2 a command verify ran failed, or a rule gate checks failed (nothing posted); 3 refused (paused, or
the emergency stop cannot be read; a claim the rules refuse; an issue that changed under a write; a pull request that
is not open, or that moved or changed before gate's post); 64 bad usage; 70 internal error.
`lock heavy` exits with its command's exit code (128 + the signal when a signal ended it; 126 or 127 when it could
not start), or with one of the codes above when it never ran the command.

How the pieces fit, for the parts that add subcommands (verify, lock, gate, status):
  - COMMANDS is the one table of subcommands: name -> (function, usage, summary). Add a function `cmd_<name>(args)`
    that takes the arguments after the subcommand and returns an exit code, and one entry in COMMANDS. `factory help`
    lists it and the shell entry point sends it here; nothing else changes.
  - Project() is the checkout: its root, factory.yaml read with factory-doctor's YAML subset reader (load_yaml; a file
    it refuses is never guessed from) and project.repo.
  - GitHub(project) is every GitHub call, one method per step of reference/github-access.md, in both columns: plain
    gh with agent-token mode off, the broker's fixed verbs (factory-github) with it on. A step with no broker verb
    has no method. A new part adds the methods it needs there, in both columns, and calls nothing else.
  - require_not_paused(project, github) is the emergency stop: every subcommand that changes anything calls it first.
  - Board(github) judges blockers (the "Blocked by" line, the native dependencies, and whether each blocker is done:
    its merged pull request on the default branch, or a closing comment that says done), with one read per blocker.
  - guarded_move(github, n, seen, remove, add, require_line) is the guarded label move: it re-reads the issue and its
    native blockers, refuses when anything the decision used changed, judges the blockers again from fresh reads,
    writes, and reads it back.
  - machine_limits() is the machine settings' limits (heavy, test_workers): ~/.factory/machine.yaml, judged by
    factory-doctor's machine check, over the core's defaults.yaml.
  - Slot(pool, limit) is one slot of a machine-wide pool under ~/.factory/locks/<pool>/ (take() waits in line,
    give_back() leaves); its comment says how the queue works and what it cannot do.
  - Stop(message, code) ends a run with one message; say() and note() are the only writers.

Output: everything printed passes factory-doctor's redact() (credential shapes and fragments blanked) and has its
control characters replaced, through say() and note() only; the tests check that no other line writes. Text from gh
or the broker reaches the output only that way. Python warnings and tracebacks are never printed: an unexpected error
prints one fixed line. This file never reads, asks for or prints a credential: gh and the broker read their own.

Standard library only; runs on Python 3.8 and later, on macOS and Linux. It writes no file in the checkout: a comment
body goes to a private temporary folder (the session temp folder /tmp/claude-<uid> when it exists, where the broker
accepts it), verify's clean tree is a temporary git worktree in such a folder (git keeps its bookkeeping under .git
until the worktree is removed), and the machine's slots live under ~/.factory/locks/.
"""

import datetime
import errno
import fcntl
import html
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unicodedata
import warnings

warnings.simplefilter("ignore")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True   # importing factory-doctor.py must not leave a bytecode cache next to it

GH_TIMEOUT = 300
LIST_LIMIT = 1000       # open issues read at once; a board this size or larger is refused, never read in part
DEPS_PAGE = 100         # native dependencies read at once (mode off); a full page is refused, never read in part
PR_LIMIT = 100          # pull requests one list reads; a full answer is refused, never read in part (a merged
                        # window is read whole instead: StatusGitHub.merged_since)
SEARCH_LIMIT = 1000     # GitHub's search gives at most this many: an answer that size cannot be told whole
GH_PR_FILES = 100       # changed files gh pr view (and the broker's pr-view) gives at most
PR_FILES_PAGES = 30     # pages of 100 a pull request's file list is read in (mode off); GitHub lists at most
                        # 3000 files, so a longer list cannot be read whole and is refused


class Stop(Exception):
    """End the run with one message and an exit code."""

    def __init__(self, message, code=1):
        Exception.__init__(self, message)
        self.message, self.code = message, code


def _load_doctor():
    spec = importlib.util.spec_from_file_location("factory_doctor", os.path.join(HERE, "factory-doctor.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    _doctor = _load_doctor()
    redact, load_yaml, Refused = _doctor.redact, _doctor.load_yaml, _doctor.Refused
except BaseException:  # noqa: B036 (main() reports it as one fixed line)
    _doctor = None


# --- output: the only two writers -----------------------------------------------------------------------------------

def _clean(text):
    return re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", " ", str(text))


def say(text=""):
    sys.stdout.write(redact(_clean(text)) + "\n")   # out: the report


def note(text):
    sys.stderr.write(redact(_clean(text)) + "\n")   # out: messages


def short(text, limit=200):
    """One line of another tool's output, for a message: the last non-empty line, cut to `limit` characters."""
    lines = [ln.strip() for ln in str(text or "").splitlines() if ln.strip()]
    s = lines[-1] if lines else "no message"
    return s if len(s) <= limit else s[:limit] + "..."


# --- the project ----------------------------------------------------------------------------------------------------

class Project:
    """The checkout this runs in: the git top level of the current folder, else the folder."""

    def __init__(self, root=None):
        self.root = root or self._top()
        self._config = None
        self.no_repo = None

    @staticmethod
    def _top():
        try:
            p = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
            top = p.stdout.decode("utf-8", "replace").strip()
            if p.returncode == 0 and top and os.path.isdir(top):
                return os.path.realpath(top)
        except (OSError, subprocess.SubprocessError):
            pass
        return os.path.realpath(os.getcwd())

    def config(self):
        """factory.yaml, parsed by factory-doctor's reader. A file it refuses stops the run; nothing is guessed."""
        if self._config is None:
            path = os.path.join(self.root, "factory.yaml")
            if not os.path.isfile(path):
                raise Stop("no factory.yaml in %s; run this in a factory project (factory-init sets one up)%s" % (
                    self.root, "" if self.no_repo is None else " (and the repository is not known from origin: %s)" %
                    self.no_repo))
            try:
                doc = load_yaml(path)
            except Refused as e:
                raise Stop("factory.yaml cannot be read (%s); run factory doctor" % e)
            except (OSError, UnicodeDecodeError):
                raise Stop("factory.yaml cannot be read; run factory doctor")
            if not isinstance(doc, dict):
                raise Stop("factory.yaml is not a mapping; run factory doctor")
            self._config = doc
        return self._config

    def repo(self):
        project = self.config().get("project")
        repo = project.get("repo") if isinstance(project, dict) else None
        if not isinstance(repo, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise Stop("factory.yaml has no valid project.repo (owner/name); run factory doctor")
        return repo


def find_broker():
    """The broker as factory-pause finds it: factory-github on PATH, else ~/.factory/bin/factory-github; or None."""
    found = shutil.which("factory-github")
    if found:
        return found
    home = os.environ.get("HOME")
    if home:
        p = os.path.join(home, ".factory", "bin", "factory-github")
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


# --- GitHub, in both agent-token modes (reference/github-access.md) -------------------------------------------------

class GitHubError(Exception):
    pass


class NoAnswer(GitHubError):
    """A GitHub step that ran out of time with no answer either way: a write may have reached GitHub or not."""


class Unconfirmed(Exception):
    """A label edit was sent, but no read shows it took: the change may have taken, and is not confirmed."""


def _labels(issue):
    """The label names of an issue as GitHub gives them ([{name: ...}] or [name]); a bad shape is an error."""
    names = []
    for label in issue.get("labels") or []:
        name = label.get("name") if isinstance(label, dict) else label
        if not isinstance(name, str):
            raise GitHubError("an issue's labels have an unexpected shape")
        names.append(name)
    return names


def _int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _where_id(item):
    """A comment's or review's id, for naming where it sits; "(no id)" when the answer has none."""
    return str(item["id"]) if _int(item.get("id")) else "(no id)"


def _issue(obj, need_body=False, pull=False):
    """An issue from gh or the broker, checked and normalized: number, title, state, reason (gh's stateReason, None
    when the answer has none: the broker does not give it), labels, milestone, body, url, comments (bodies, oldest
    first; None when they were not asked for). With pull, the number may be a pull request's, whose state gh also
    gives as MERGED (the url then names it: Board._done tells the two apart)."""
    if not isinstance(obj, dict) or not _int(obj.get("number")):
        raise GitHubError("an issue without a number in the answer")
    n = obj["number"]
    state = obj.get("state")
    if not isinstance(state, str) or state.upper() not in (("OPEN", "CLOSED", "MERGED") if pull else ("OPEN", "CLOSED")):
        raise GitHubError("issue #%d has no open or closed state in the answer" % n)
    body = obj.get("body")
    if need_body and body is not None and not isinstance(body, str):
        raise GitHubError("issue #%d has a body that is not text" % n)
    comments = None
    if "comments" in obj:
        if not isinstance(obj["comments"], list):
            raise GitHubError("issue #%d has comments of an unexpected shape" % n)
        comments = []
        for c in obj["comments"]:
            cb = c.get("body") if isinstance(c, dict) else None
            if not isinstance(cb, str):
                raise GitHubError("issue #%d has a comment of an unexpected shape" % n)
            comments.append(cb)
    reason = obj.get("stateReason")
    ms = obj.get("milestone")
    return {"number": n, "title": str(obj.get("title") or ""), "state": state.upper(),
            "reason": reason.upper() if isinstance(reason, str) and reason else None,
            "labels": _labels(obj), "milestone": ms if isinstance(ms, dict) else None, "body": body or "",
            "url": obj.get("url") if isinstance(obj.get("url"), str) else None, "comments": comments}


BRANCH = re.compile(r"[A-Za-z0-9._/-]{1,200}")
SHA = re.compile(r"[0-9a-f]{40}")


def branch_name(name):
    """A branch name this tool passes to git: the BRANCH characters, not starting with - or /, and no `..`."""
    return isinstance(name, str) and bool(BRANCH.fullmatch(name)) and not name.startswith(("-", "/")) and ".." not in name


class GitHub:
    """Every GitHub step this tool takes. Mode off: plain gh with -R <project.repo>, and git for the fetch. Mode on:
    the broker's verbs, run from the checkout (it reads the repository it registered for the checkout). Mode staged,
    or any other answer: no GitHub at all, as github-access.md › Which column applies says."""

    def __init__(self, project):
        self.project = project
        self.broker = find_broker()
        self.mode = self._mode()
        self.repo = project.repo() if self.mode == "off" else None
        self._default = self._default_name = None

    def _mode(self):
        if not self.broker:
            return "off"
        try:
            p = subprocess.run([self.broker, "mode"], cwd=self.project.root, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        except (OSError, subprocess.SubprocessError):
            raise Stop("factory-github mode could not run, so the agent-token mode is unknown; nothing was read")
        answer = p.stdout.decode("utf-8", "replace").strip()
        if p.returncode == 0 and answer in ("off", "on"):
            return answer
        if p.returncode == 0 and answer == "staged":
            raise Stop("agent-token mode is staged: nothing may reach GitHub until it is on (runtime adapter, "
                       "\"The switch\"); nothing was read")
        raise Stop("factory-github mode gave no usable answer (%s); nothing was read"
                   % short(p.stderr.decode("utf-8", "replace") or answer))

    # The one place a command runs: `off` is the full mode-off command (gh or git), `on` the broker verb and its
    # arguments. Neither's output is printed except through short() in a message, which say()/note() redact.
    def _run(self, off, on, what):
        argv = off if self.mode == "off" else [self.broker] + on
        tool = argv[0] if self.mode == "off" else "factory-github"
        try:
            p = subprocess.run(argv, cwd=self.project.root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=GH_TIMEOUT)
        except FileNotFoundError:
            raise GitHubError("%s: %s is not installed" % (what, tool))
        except subprocess.TimeoutExpired:
            raise NoAnswer("%s: no answer within %d seconds" % (what, GH_TIMEOUT))
        except (OSError, subprocess.SubprocessError):
            raise GitHubError("%s: the command did not finish" % what)
        if p.returncode != 0:
            raise GitHubError("%s failed (%s exit %d: %s)" % (what, tool, p.returncode,
                                                             short(p.stderr.decode("utf-8", "replace"))))
        return p.stdout.decode("utf-8", "replace")

    def _json(self, off, on, what):
        text = self._run(off, on, what)
        try:
            return json.loads(text)
        except ValueError:
            raise GitHubError("%s: the answer is not JSON" % what)

    def _gh(self, *args):
        return ["gh"] + list(args)

    def open_issues(self):
        """Every open issue: number, title, state, labels, milestone (no body). Refused when the list may be cut."""
        data = self._json(self._gh("issue", "list", "-R", self.repo or "", "--state", "open", "--limit",
                                   str(LIST_LIMIT), "--json", "number,title,state,labels,milestone"),
                          ["issue-list", "--state", "open", "--limit", str(LIST_LIMIT)], "reading the open issues")
        if not isinstance(data, list):
            raise GitHubError("reading the open issues: the answer is not a list")
        if len(data) >= LIST_LIMIT:
            raise GitHubError("there are %d or more open issues; the board cannot be read whole" % LIST_LIMIT)
        return [_issue(i) for i in data]

    def issue(self, n, comments=False, pull=False):
        """One issue, with its body (and its comments when asked). With pull, a pull request's number is read too
        (the issue view of gh and the broker answers for it, with its url and its state: OPEN, CLOSED or MERGED)."""
        fields = "number,title,body,state,stateReason,labels,milestone,url" + (",comments" if comments else "")
        data = self._json(self._gh("issue", "view", str(n), "-R", self.repo or "", "--json", fields),
                          ["issue-view", str(n)] + (["--comments"] if comments else []), "reading issue #%d" % n)
        issue = _issue(data, need_body=True, pull=pull)
        if issue["number"] != n:
            raise GitHubError("reading issue #%d gave issue #%d" % (n, issue["number"]))
        if comments and issue["comments"] is None:
            raise GitHubError("reading issue #%d: the answer has no comments" % n)
        return issue

    def deps(self, n, kind):
        """An issue's native dependencies, kind "blocked-by" or "blocking": [(number, "OPEN"|"CLOSED")], sorted."""
        path = "blocked_by" if kind == "blocked-by" else "blocking"
        what = "reading the native %s of #%d" % ("blockers" if kind == "blocked-by" else "dependents", n)
        data = self._json(self._gh("api", "repos/%s/issues/%d/dependencies/%s?per_page=%d"
                                   % (self.repo, n, path, DEPS_PAGE)),
                          ["issue-deps", str(n), kind], what)
        if not isinstance(data, list):
            raise GitHubError("%s: the answer is not a list" % what)
        if self.mode == "off" and len(data) >= DEPS_PAGE:
            raise GitHubError("%s: %d or more, which cannot be read whole" % (what, DEPS_PAGE))
        out = set()
        for d in data:
            num, state = (d.get("number"), d.get("state")) if isinstance(d, dict) else (None, None)
            if not _int(num) or not isinstance(state, str) or state.upper() not in ("OPEN", "CLOSED"):
                raise GitHubError("%s: an entry has an unexpected shape" % what)
            out.add((num, state.upper()))
        return sorted(out)

    def merged_prs(self, n):
        """The merged pull requests a search for the issue number finds: number, mergeCommit, closingIssuesReferences.
        The search only finds candidates; Board.done() keeps a pull request only when it closes the issue itself."""
        data = self._json(self._gh("pr", "list", "-R", self.repo or "", "--state", "merged", "--search", str(n),
                                   "--limit", str(PR_LIMIT), "--json", "number,state,mergeCommit,closingIssuesReferences"),
                          ["pr-list", "--state", "merged", "--search", str(n), "--limit", str(PR_LIMIT)],
                          "reading the merged pull requests for #%d" % n)
        if not isinstance(data, list) or not all(isinstance(p, dict) for p in data):
            raise GitHubError("reading the merged pull requests for #%d: the answer is not a list" % n)
        if len(data) >= PR_LIMIT:
            raise GitHubError("the search for #%d finds %d or more merged pull requests; they cannot be read whole"
                              % (n, PR_LIMIT))
        return data

    def default_branch(self):
        """The default branch's name (github-access.md › Default branch name), read once per run."""
        if self._default_name is None:
            if self.mode == "off":
                data = self._json(self._gh("repo", "view", self.repo, "--json", "defaultBranchRef"), [],
                                  "reading the default branch")
                ref = data.get("defaultBranchRef") if isinstance(data, dict) else None
                name = ref.get("name") if isinstance(ref, dict) else None
            else:
                name = self._run([], ["default-branch"], "reading the default branch").strip()
            if not branch_name(name):
                raise GitHubError("reading the default branch: the answer is not a branch name")
            self._default_name = name
        return self._default_name

    def default_ref(self):
        """origin/<default branch>, after one fetch per run (github-access.md › Default branch name, Fetch)."""
        if self._default is None:
            name = self.default_branch()
            self._run(["git", "fetch", "origin"], ["fetch"], "fetching origin")
            self._default = "origin/" + name
        return self._default

    def on_default(self, sha):
        """True when the commit is on origin/<default>, False when it is not; an error when git cannot tell."""
        ref = self.default_ref()
        try:
            p = subprocess.run(["git", "merge-base", "--is-ancestor", sha, ref], cwd=self.project.root,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=60)
        except (OSError, subprocess.SubprocessError):
            raise GitHubError("git cannot tell whether %s is on %s" % (sha[:12], ref))
        if p.returncode in (0, 1):
            return p.returncode == 0
        raise GitHubError("git cannot tell whether %s is on %s (is the commit fetched?)" % (sha[:12], ref))

    def edit_labels(self, n, add, remove):
        """Add and remove labels on #n. NoAnswer when the step ran out of time: the edit may have taken."""
        off = self._gh("issue", "edit", str(n), "-R", self.repo or "")
        on = ["issue-labels", str(n)]
        for label in add:
            off += ["--add-label", label]
            on += ["--add", label]
        for label in remove:
            off += ["--remove-label", label]
            on += ["--remove", label]
        self._run(off, on, "changing the labels of #%d" % n)

    def _post(self, off, on, text, what):
        """Run a comment step with the text in a private file, appended to both commands as --body-file <path>."""
        folder = _private_temp()
        try:
            path = os.path.join(folder, "comment.md")
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            return self._run(off + ["--body-file", path], on + ["--body-file", path], what)
        finally:
            shutil.rmtree(folder, ignore_errors=True)

    def comment(self, n, text):
        self._post(self._gh("issue", "comment", str(n), "-R", self.repo or ""), ["issue-comment", str(n)], text,
                   "commenting on #%d" % n)

    def pr(self, n, draft=False):
        """One pull request: number, state (OPEN, CLOSED or MERGED), head (headRefOid), branch (headRefName), base
        (baseRefName), and its head repository as GitHub gives it: fork (isCrossRepository), owner/name (headRepository
        and headRepositoryOwner) or None for each the answer does not hold (plain gh is asked for both and must give
        them; the broker's pr-view gives both too, an older broker neither), and files: the paths of its changed files,
        as merge-gate.md rule 2 › "Which checks" reads them (`files`; a rename is its new path only). Both modes must
        give the list, and it must hold changedFiles paths: gh asks GitHub for the first 100 files only, so a longer
        list is cut short. Mode off then reads the whole list page by page (pr_files); mode on has no broker verb that
        lists more, so there, as for any list that still falls short, it is refused, never used. With draft, also
        whether it is a draft (isDraft, which both modes must give)."""
        what = "reading pull request #%d" % n
        data = self._json(self._gh("pr", "view", str(n), "-R", self.repo or "", "--json",
                                   "number,state,headRefOid,headRefName,baseRefName,isCrossRepository,headRepository,"
                                   "headRepositoryOwner,files,changedFiles" + (",isDraft" if draft else "")),
                          ["pr-view", str(n)], what)
        if not isinstance(data, dict) or data.get("number") != n:
            raise GitHubError("%s: the answer is not that pull request" % what)
        state, head = data.get("state"), data.get("headRefOid")
        if not isinstance(state, str) or state.upper() not in ("OPEN", "CLOSED", "MERGED"):
            raise GitHubError("%s: no open, closed or merged state in the answer" % what)
        if not isinstance(head, str) or not SHA.fullmatch(head):
            raise GitHubError("%s: the head is not a full commit SHA" % what)
        for key in ("baseRefName", "headRefName"):
            if not branch_name(data.get(key)):
                raise GitHubError("%s: %s is not a branch name" % (what, key))
        fork = data.get("isCrossRepository")
        if fork is not None and not isinstance(fork, bool):
            raise GitHubError("%s: isCrossRepository is not true or false" % what)
        repo = None
        if "headRepository" in data or "headRepositoryOwner" in data:
            hr, ho = data.get("headRepository"), data.get("headRepositoryOwner")
            name = hr.get("name") if isinstance(hr, dict) else None
            owner = ho.get("login") if isinstance(ho, dict) else None
            repo = "%s/%s" % (owner, name) if isinstance(owner, str) and isinstance(name, str) else ""
        if self.mode == "off" and (fork is None or repo is None):
            raise GitHubError("%s: the answer does not say which repository the head is in" % what)
        files, count = data.get("files"), data.get("changedFiles")
        if not isinstance(files, list) or not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise GitHubError("%s: the answer has no list of changed files and their count (files, changedFiles)%s"
                              % (what, "; this factory-github is older than factory verify needs, update it"
                                 if self.mode == "on" else ""))
        paths = [f.get("path") if isinstance(f, dict) else None for f in files]
        if any(not isinstance(p, str) or not p or "\0" in p for p in paths):
            raise GitHubError("%s: a changed file in the answer has no path" % what)
        if len(paths) != count and count > GH_PR_FILES and len(paths) <= GH_PR_FILES:
            if self.mode != "off":
                raise GitHubError("%s: the pull request has %d changed files and factory-github's pr-view gives the "
                                  "first %d only (no broker verb lists more); an incomplete list never selects the "
                                  "checks, so this pull request is gated by hand in agent-token mode on"
                                  % (what, count, GH_PR_FILES))
            paths = self.pr_files(n, count, paths)
        if len(paths) != count:
            raise GitHubError("%s: the answer lists %d changed files of the %d the pull request has; an incomplete "
                              "list never selects the checks" % (what, len(paths), count))
        out = {"number": n, "state": state.upper(), "head": head, "branch": data["headRefName"],
               "base": data["baseRefName"], "fork": fork, "head_repo": repo, "files": paths}
        if draft:
            if not isinstance(data.get("isDraft"), bool):
                raise GitHubError("%s: the answer does not say whether it is a draft (isDraft)" % what)
            out["draft"] = data["isDraft"]
        return out

    def pr_files(self, n, count, first):
        """Mode off: every changed file of #n, read page by page through the REST API (pulls/<n>/files, 100 a page,
        `filename`: a rename is its new path only, as gh's `files` gives it). `count` is changedFiles and `first` the
        paths gh pr view gave. Refused, never cut, when GitHub cannot list them all (more than PR_FILES_PAGES pages),
        when a page is not a list of files with paths, when a full page is followed by nothing more and the list is
        still short, or when gh's first paths are not all in it (the pull request changed between the reads). A head
        that moves after these reads is caught where the head is fetched and compared."""
        what = "reading the changed files of pull request #%d" % n
        if count > PR_FILES_PAGES * 100:
            raise GitHubError("%s: it has %d changed files and GitHub lists at most %d, so the list cannot be read "
                              "whole; an incomplete list never selects the checks" % (what, count, PR_FILES_PAGES * 100))
        paths = []
        for page in range(1, PR_FILES_PAGES + 1):
            batch = self._json(self._gh("api", "-H", "Accept: application/vnd.github+json",
                                        "repos/%s/pulls/%d/files?per_page=100&page=%d" % (self.repo, n, page)), [],
                               what)
            if not isinstance(batch, list):
                raise GitHubError("%s: page %d is not a list" % (what, page))
            for f in batch:
                p = f.get("filename") if isinstance(f, dict) else None
                if not isinstance(p, str) or not p or "\0" in p:
                    raise GitHubError("%s: a changed file on page %d has no path" % (what, page))
                paths.append(p)
            if len(batch) < 100 or len(paths) >= count:
                break
        if len(paths) != count:
            raise GitHubError("%s: the list holds %d changed files of the %d the pull request has; an incomplete list "
                              "never selects the checks" % (what, len(paths), count))
        if len(set(paths)) != len(paths) or not set(first) <= set(paths):
            raise GitHubError("%s: the list does not match the one gh pr view gave (the pull request changed between "
                              "the reads); run it again" % what)
        return paths

    def fetch_pr(self, n):
        """Fetch origin's branches and the pull request's head as origin/pr/<n> (github-access.md › Fetch a PR's head;
        mode off fetches the same refs with plain git)."""
        self._run(["git", "fetch", "--no-tags", "origin", "+refs/heads/*:refs/remotes/origin/*",
                   "+refs/pull/%d/head:refs/remotes/origin/pr/%d" % (n, n)], ["fetch", "--pr", str(n)],
                  "fetching pull request #%d" % n)

    def fetch_branch(self, name):
        """Bring origin/<name> up to date: plain git names the branch in its refspec, so the checkout's own fetch
        settings cannot leave it out; the broker's fetch uses them (heads() then tells whether it did)."""
        self._run(["git", "fetch", "--no-tags", "origin", "+refs/heads/%s:refs/remotes/origin/%s" % (name, name)],
                  ["fetch"], "fetching origin/%s" % name)

    def heads(self):
        """origin's branches as origin itself lists them now (github-access.md › List remote branches): name -> SHA.
        A line of another shape refuses the whole answer."""
        text = self._run(["git", "ls-remote", "--heads", "origin"], ["ls-remote"], "listing origin's branches")
        out = {}
        for ln in text.splitlines():
            m = re.fullmatch(r"([0-9a-f]{40})\trefs/heads/(.+)", ln)
            if not m:
                raise GitHubError("listing origin's branches: a line of an unexpected shape")
            out[m.group(2)] = m.group(1)
        return out

    def pr_comment(self, n, text):
        """Comment on a pull request; returns what gh or the broker printed (the comment's address)."""
        return self._post(self._gh("pr", "comment", str(n), "-R", self.repo or ""), ["pr-comment", str(n)], text,
                          "commenting on pull request #%d" % n)


def _private_temp():
    """A new private folder: in the session temp folder when it exists (the broker accepts files there), else TMPDIR."""
    session = os.path.realpath("/tmp/claude-%d" % os.getuid())
    return tempfile.mkdtemp(prefix="factory-", dir=session if os.path.isdir(session) else None)


# --- the emergency stop ---------------------------------------------------------------------------------------------

def require_not_paused(project, github):
    """factory-pause status, next to this file: exit 0 goes on; 3 (paused) and anything else (cannot tell) refuse."""
    tool = os.path.join(HERE, "factory-pause")
    if not os.path.isfile(tool):
        raise Stop("factory-pause is missing next to factory; cannot tell whether the factory is paused, so nothing "
                   "changed (restore the core files with factory update)", 3)
    argv = ["sh", tool, "status", "-q"] + (["-R", github.repo] if github.mode == "off" else [])
    try:
        rc = subprocess.run(argv, cwd=project.root, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=GH_TIMEOUT).returncode
    except (OSError, subprocess.SubprocessError):
        rc = 1
    if rc == 3:
        raise Stop("the factory is paused (factory:paused on the status issue); nothing changed", 3)
    if rc != 0:
        raise Stop("cannot tell whether the factory is paused (run factory pause status for the reason), so it counts "
                   "as paused; nothing changed", 3)


# --- the board: labels, "Blocked by", done, owned paths, order --------------------------------------------------------

STATUS_LABELS = ("status:blocked", "status:ready", "status:in-progress", "status:in-review", "status:needs-human")
EPIC_LABEL = "type:epic"
CLAIMED = ("status:in-progress", "status:in-review")
TIERS = ("tier:deep", "tier:standard", "tier:light")

# "Blocked by" (reference/board.md › Follow-ups): one line, `Blocked by: #A, #B` or `Blocked by: none`.
# The candidate pattern only finds lines that look like one; the strict grammar below decides. Accepted:
#   Blocked by: none          **Blocked by:** none          **Blocked by**: none          (none or None)
#   Blocked by: #12           Blocked by: #12, #15          Blocked by: #149 (the dispatcher), #150
#   Blocked by: none (a decision, see the spec)
# Each entry is #<number>, optionally followed by one space and a note in parentheses without parentheses inside;
# `none` takes the same note and nothing else. The number is an issue's or a pull request's.
# Anything else on a candidate line (another repository, "and", a missing #, a trailing comma, a note with a comma
# inside its parentheses, anything but a note after none) makes the line unreadable, and an unreadable line, or two
# candidate lines, count as blocked.
BLOCKED_CANDIDATE = re.compile(r"^[\s>*_#-]*blocked[\s_*-]*by\b", re.IGNORECASE)
BLOCKED_LINE = re.compile(r"(?:\*\*Blocked by:\*\*|\*\*Blocked by\*\*:|Blocked by:) (.*\S)")
BLOCKED_ITEM = re.compile(r"#([1-9][0-9]{0,9})(?: \([^()]*\))?")
BLOCKED_NONE = re.compile(r"(?:none|None)(?: \([^()]*\))?")


def parse_blocked_by(body):
    """(kind, numbers, problem): kind is "none", "list", "missing" (no such line) or "unreadable" (problem says why)."""
    found = [(i + 1, ln.strip()) for i, ln in enumerate((body or "").splitlines()) if BLOCKED_CANDIDATE.match(ln)]
    if not found:
        return "missing", [], None
    if len(found) > 1:
        return "unreadable", [], "several \"Blocked by\" lines (lines %s)" % ", ".join(str(n) for n, _ in found)
    lineno, text = found[0]
    m = BLOCKED_LINE.fullmatch(text)
    if not m:
        return "unreadable", [], "line %d is not \"Blocked by: #A, #B\" or \"Blocked by: none\"" % lineno
    value = m.group(1)
    if BLOCKED_NONE.fullmatch(value):
        return "none", [], None
    numbers = []
    for item in value.split(","):
        im = BLOCKED_ITEM.fullmatch(item.strip())
        if not im:
            return "unreadable", [], "line %d has an entry that is not #<number>: %s" % (lineno, _quote(item.strip()))
        if int(im.group(1)) not in numbers:
            numbers.append(int(im.group(1)))
    return "list", numbers, None


def _quote(s, limit=40):
    s = s if len(s) <= limit else s[:limit] + "..."
    return '"%s"' % s


# "Done" for a closed blocker (reference/board.md › Unblock). A blocker counts as done when:
#   1. a merged pull request closes it (its closingIssuesReferences names this issue, in this repository) and that
#      pull request's merge commit is on origin/<default branch> after a fetch; or, when no merged pull request closes
#      it (a decision, an agent:human task),
#   2. its closing comment says it is done: the issue's last comment, whose first non-empty line is "Done" as a word
#      ("Done", "Done.", "Done: decided in #7", "Done - see the spec"), optionally after "🤖 Lead: " or "🤖 Solo: ".
# Not done, with the reason named: closed as not planned or as a duplicate (gh's stateReason; the broker does not give
# it, so in agent-token mode on such an issue is judged by 1 and 2 alone), a merged pull request whose merge commit is
# not on the default branch, or neither 1 nor 2. Evidence that cannot be read (the issue, its comments, the search,
# the default branch, the fetch, git) is "cannot tell", which blocks like not done.
# A number that is a pull request (its address says /pull/) is judged by its own state instead: done only when it is
# merged and its merge commit is on origin/<default branch> after the same fetch; open is open, closed without a
# merge is not done, and each says that it is a pull request. A closing comment never makes a pull request done.
DONE_COMMENT = re.compile(r"(?:🤖 (?:Lead|Solo): )?Done(?:$|[\s.:,;!\-–—])")
ISSUE_URL = re.compile(r"https://[^/\s]+/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([1-9][0-9]*)")
PULL_URL = re.compile(r"https://[^/\s]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/([1-9][0-9]*)")


def done_comment(comments):
    if not comments:
        return False
    lines = [ln.strip() for ln in comments[-1].splitlines() if ln.strip()]
    return bool(lines) and bool(DONE_COMMENT.match(lines[0]))


def closes(pr, n, url):
    """True when the pull request's closingIssuesReferences names issue n of the repository in its url."""
    m = ISSUE_URL.fullmatch(url or "")
    if not m or int(m.group(3)) != n:
        return False
    owner, name = m.group(1).lower(), m.group(2).lower()
    for ref in pr.get("closingIssuesReferences") or []:
        if not isinstance(ref, dict) or ref.get("number") != n:
            continue
        if isinstance(ref.get("url"), str):
            if ref["url"].lower() == url.lower():
                return True
            continue
        repo = ref.get("repository") if isinstance(ref.get("repository"), dict) else {}
        own = repo.get("owner") if isinstance(repo.get("owner"), dict) else {}
        if str(repo.get("name", "")).lower() == name and str(own.get("login", "")).lower() == owner:
            return True
    return False


OWNED_HEADING = re.compile(r"^\s*(?:#{1,6}\s*|\*\*)?owned paths\b", re.IGNORECASE)
ANY_HEADING = re.compile(r"^\s*(?:#{1,6}\s|\*\*[^*]+\*\*\s*$)")
# The closing "Plan: ..." line of an issue body (plain, "**Plan:**" or "**Plan**:"): its code spans are not owned paths.
PLAN_LINE = re.compile(r"^\s*(?:\*\*|__)?plan\s*(?:\*\*|__)?\s*:", re.IGNORECASE)


def owned_paths(body):
    """The issue's owned paths, for display only (board.md › Owned paths): the code spans, else the list items, under
    its "Owned paths" heading up to the next heading or a "Plan:" line. None when it has no such heading."""
    lines = (body or "").splitlines()
    for i, ln in enumerate(lines):
        if OWNED_HEADING.match(ln):
            section = []
            rest = re.sub(OWNED_HEADING, "", ln, count=1).strip(" :*")
            if rest:
                section.append(rest)
            for nxt in lines[i + 1:]:
                if ANY_HEADING.match(nxt) or PLAN_LINE.match(nxt):
                    break
                section.append(nxt)
            text = "\n".join(section)
            spans = re.findall(r"`([^`\n]+)`", text)
            if spans:
                return spans
            items = [re.sub(r"^\s*[-*+]\s+", "", s).strip() for s in section if re.match(r"^\s*[-*+]\s+\S", s)]
            return items
    return None


def labels_of(issue):
    return set(issue["labels"])


def tiers_of(issue):
    return sorted(t for t in labels_of(issue) if t in TIERS)


def status_of(issue):
    return sorted(s for s in labels_of(issue) if s in STATUS_LABELS)


PRIORITY = re.compile(r"priority:P([0-9])")


def priority_of(issue):
    ps = [int(m.group(1)) for m in (PRIORITY.fullmatch(lb) for lb in issue["labels"]) if m]
    return min(ps) if ps else None


class Board:
    """Blockers and their evidence, read once per run: each blocker's state and "done" evidence is cached, so one run
    judges every issue by the same reads. A fresh Board reads everything again (claim's re-check before its write)."""

    def __init__(self, github):
        self.github = github
        self.cache = {}
        self.pulls = set()   # the blockers read so far whose number is a pull request's

    def done(self, n):
        """("done" | "open" | "not done" | "cannot tell", why) for blocker n."""
        if n not in self.cache:
            self.cache[n] = self._done(n)
        return self.cache[n]

    def _done(self, n):
        # Always a fresh read (cached for the run by done()): a blocker that was open in the list may have closed
        # since, and the list is never the evidence for a decision (review of #169).
        try:
            issue = self.github.issue(n, comments=True, pull=True)
        except GitHubError as e:
            return "cannot tell", str(e)
        pm = PULL_URL.fullmatch(issue["url"] or "")
        if pm and int(pm.group(1)) == n:
            self.pulls.add(n)
            return self._pull_done(n, issue)
        if issue["state"] == "MERGED":
            return "cannot tell", "it reads as merged but its address is not a pull request's"
        if issue["state"] == "OPEN":
            return "open", "open"
        if issue["reason"] in ("NOT_PLANNED", "DUPLICATE"):
            return "not done", "closed as %s" % ("not planned" if issue["reason"] == "NOT_PLANNED" else "a duplicate")
        if not ISSUE_URL.fullmatch(issue["url"] or ""):
            return "cannot tell", "its address is missing from the answer, so no pull request can be matched to it"
        try:
            prs = [p for p in self.github.merged_prs(n) if closes(p, n, issue["url"])]
        except GitHubError as e:
            return "cannot tell", str(e)
        if prs:
            missing = []
            for p in sorted(prs, key=lambda p: p.get("number") if _int(p.get("number")) else 0):
                mc = p.get("mergeCommit") if isinstance(p.get("mergeCommit"), dict) else {}
                sha, pn = mc.get("oid"), p.get("number")
                if not isinstance(sha, str) or not SHA.fullmatch(sha) or not _int(pn):
                    return "cannot tell", "a merged pull request that closes it has no readable merge commit"
                try:
                    if self.github.on_default(sha):
                        return "done", "merged in PR #%d" % pn
                except GitHubError as e:
                    return "cannot tell", str(e)
                missing.append("#%d" % pn)
            return "not done", "merged PR %s is not on %s" % (", ".join(missing), self.github.default_ref())
        if done_comment(issue["comments"]):
            return "done", "its closing comment says done"
        return "not done", "closed without a merged pull request that closes it or a closing comment that says done"

    def _pull_done(self, n, issue):
        """A blocker whose number is a pull request: done only when merged and its merge commit is on the default
        branch after the fetch. The issue read gave its state (OPEN, CLOSED or MERGED); the merge commit comes from
        the merged-pull-request search, which finds the pull request by its own number (same read in both modes)."""
        if issue["state"] == "OPEN":
            return "open", "open, not merged"
        if issue["state"] == "CLOSED":
            return "not done", "closed without a merge"
        try:
            found = [p for p in self.github.merged_prs(n) if p.get("number") == n]
        except GitHubError as e:
            return "cannot tell", str(e)
        mc = found[0].get("mergeCommit") if found and isinstance(found[0].get("mergeCommit"), dict) else {}
        sha = mc.get("oid")
        if not isinstance(sha, str) or not SHA.fullmatch(sha):
            return "cannot tell", "it is merged but its merge commit cannot be read"
        try:
            if self.github.on_default(sha):
                return "done", "merged pull request, its merge commit is on %s" % self.github.default_ref()
            return "not done", "merged, but its merge commit is not on %s" % self.github.default_ref()
        except GitHubError as e:
            return "cannot tell", str(e)

    def check(self, issue, require_line, native=None):
        """The blocker check of one issue (board.md › Unblock): the "Blocked by" line and the native blockers
        (`native`, or read now), each blocker judged by done(). free only when the line reads (or, with require_line
        False, is missing), the native blockers read, and every blocker of both is done."""
        kind, numbers, problem = parse_blocked_by(issue["body"])
        problems, notes = [], []
        if kind == "unreadable":
            problems.append("its \"Blocked by\" line cannot be read: %s" % problem)
        if native is None:
            try:
                native = self.github.deps(issue["number"], "blocked-by")
            except GitHubError as e:
                problems.append("its native blockers cannot be read: %s" % e)
                native = []
        if kind == "missing" and require_line and not native and not problems:
            problems.append("it has no \"Blocked by\" line and no native blockers, so what it waits for is unknown")
        line_set, native_set = set(numbers), {num for num, _ in native}
        if kind in ("list", "none") and native and line_set != native_set:
            notes.append("the \"Blocked by\" line and the native blockers differ (line: %s; native: %s); fix the "
                         "native links (board.md › Unblock)" % (_nums(sorted(line_set)) or "none",
                                                                 _nums(sorted(native_set))))
        open_, waiting, done = [], [], []
        for num in sorted(line_set | native_set):
            st, why = self.done(num)
            if st == "done":
                done.append((num, why))
            elif st == "open":
                open_.append(num)
            else:
                waiting.append((num, st, why))
        return {"free": not problems and not open_ and not waiting, "open": open_, "waiting": waiting,
                "problems": problems, "done": done, "notes": notes, "native": native, "line": numbers,
                "pulls": sorted(self.pulls & (line_set | native_set))}


def _nums(numbers):
    return ", ".join("#%d" % n for n in numbers)


def why_blocked(result):
    parts = list(result["problems"])
    pulls = result.get("pulls", [])
    issues_open = [n for n in result["open"] if n not in pulls]
    if issues_open:
        parts.append("open blocker%s %s" % ("s" if len(issues_open) > 1 else "", _nums(issues_open)))
    for n in result["open"]:
        if n in pulls:
            parts.append("#%d is an open pull request, not merged" % n)
    for num, st, why in result["waiting"]:
        if st != "not done":
            parts.append("whether #%d is done cannot be read: %s" % (num, why))
        elif num in pulls:
            parts.append("#%d is a pull request, not done: %s" % (num, why))
        else:
            parts.append("#%d is closed but not done: %s" % (num, why))
    return "; ".join(parts)


def done_text(result):
    return ", ".join("#%d (%s)" % (n, why) for n, why in result["done"]) or "none"


def guarded_move(github, n, seen, remove, add, require_line):
    """The label move of claim and unblock --apply. `seen` is the first read of #n and its blocker check. Re-read the
    issue and its native blockers; refuse (Stop 3) when the state, the labels, the body or the native blockers changed;
    else judge every blocker again from fresh reads and refuse when one is no longer done; then change the labels, read
    the issue back and fail (Stop 1) when the change did not take. An edit that ran out of time with no answer may
    have taken: the one read back decides, and when it fails or shows the old labels the move is Unconfirmed, never
    "not moved". GitHub has no compare-and-set on labels; the window left is the time between the last read and the
    write."""
    first, result = seen
    now = github.issue(n)
    native = github.deps(n, "blocked-by")
    changed = sorted(labels_of(now) ^ labels_of(first))
    if now["state"] != first["state"]:
        changed.append("state")
    if now["body"] != first["body"]:
        changed.append("body")
    if native != result["native"]:
        changed.append("native blockers")
    if now.get("state", "OPEN") != "OPEN":
        changed.append("closed")
    missing = sorted(set(remove) - labels_of(now))
    if missing:
        changed.append("no longer " + ", ".join(missing))   # a move only from the state it was decided on
    if changed:
        raise Stop("#%d changed between the read and the write (%s); nothing changed. Read the board again" %
                   (n, ", ".join(changed)), 3)
    again = Board(github).check(now, require_line, native=native)
    if not again["free"]:
        raise Stop("#%d: a blocker changed right before the write (%s); nothing changed" % (n, why_blocked(again)), 3)
    no_answer = None
    try:
        github.edit_labels(n, add, remove)
    except NoAnswer as e:
        no_answer = e   # no answer either way: the edit may have reached GitHub, so the read back decides
    try:
        after = labels_of(github.issue(n))
    except GitHubError as e:
        # The edit was sent; only the read-back failed. Never report that as "not moved", and never as a verified
        # move either.
        raise Unconfirmed("#%d: the label edit was sent%s, but reading the issue back failed (%s); check the issue "
                          "by hand" % (n, " and got no answer (%s)" % no_answer if no_answer else "", e))
    if not set(add) <= after or after & set(remove):
        if no_answer:
            raise Unconfirmed("#%d: the label edit was sent and got no answer (%s); the issue read back does not "
                              "show the change yet (labels now: %s), but it may still take; check the issue by hand"
                              % (n, no_answer, ", ".join(sorted(after)) or "none"))
        raise Stop("#%d: the label change did not take (labels now: %s); check the issue by hand" %
                   (n, ", ".join(sorted(after)) or "none"))
    return again


# --- the pick order (factory-lead › Picking work) ---------------------------------------------------------------------

# Rule 1, "jumps the queue". Readable from the board: the fix for a red default branch or nightly (RED_FIX, the label
# the lead sets when it files that fix), a priority:P0 issue, and a failed release's bug (priority:P1, its body starting
# with the deploy recipes' marker line). The red-branch fix comes first of the three, as the rule lists it.
RED_FIX = "incident:red-branch"
RELEASE_BUG = re.compile(r"<!-- factory-deploy-failed:\S+ -->")
ORDER_NOTE = ("Order: factory-lead › Picking work, rules 1-3. Rule 1 here reads " + RED_FIX + " (the fix for a red "
              "default branch or nightly, first of all), priority:P0 and failed-release bugs (priority:P1 with the "
              "deploy recipes' factory-deploy-failed marker); a red-branch fix filed without " + RED_FIX + " is not "
              "recognized: add the label. Rule 4 (small docs or spike issues filling a free slot) is the lead's call.")


def jumps_queue(issue):
    labels = labels_of(issue)
    if RED_FIX in labels:
        return RED_FIX
    if "priority:P0" in labels:
        return "priority:P0"
    first = next((ln.strip() for ln in issue["body"].splitlines() if ln.strip()), "")
    if "priority:P1" in labels and RELEASE_BUG.fullmatch(first):
        return "failed release, priority:P1"
    return None


def milestone_key(issue):
    ms = issue["milestone"]
    if not ms:
        return (2, "", 0)
    due = ms.get("dueOn") or ms.get("due_on")
    num = ms.get("number") if _int(ms.get("number")) else 0
    return (0, str(due), num) if due else (1, "", num)


def milestone_text(issue):
    ms = issue["milestone"]
    if not ms:
        return "none"
    due = ms.get("dueOn") or ms.get("due_on")
    return "%s%s" % (ms.get("title") or "?", " (due %s)" % str(due)[:10] if due else "")


def dependents_graph(github, full, checks, starts, open_numbers):
    """blocker -> open issues that wait on it: the "Blocked by" lines of every issue read, the native blockers of
    every issue checked, and the native `blocking` list of each start and of every open issue reached from one."""
    graph = {}
    for n, issue in full.items():
        for b in parse_blocked_by(issue["body"])[1]:
            graph.setdefault(b, set()).add(n)
    for n, result in checks.items():
        for b, _ in result["native"]:
            graph.setdefault(b, set()).add(n)
    todo, seen = list(starts), set()
    while todo:
        x = todo.pop()
        if x in seen:
            continue
        seen.add(x)
        for d, st in github.deps(x, "blocking"):
            if st == "OPEN":
                graph.setdefault(x, set()).add(d)
        todo.extend(d for d in graph.get(x, ()) if d in open_numbers)
    return {b: {d for d in ds if d in open_numbers} for b, ds in graph.items()}


def critical_path(graph, n):
    """How many open issues wait on n, counted through (each once)."""
    seen, todo = set(), [n]
    while todo:
        for d in graph.get(todo.pop(), ()):
            if d not in seen and d != n:
                seen.add(d)
                todo.append(d)
    return len(seen)


# --- the board read shared by ready and unblock --------------------------------------------------------------------

def selected(issue, which):
    """The board's selection: an open issue carrying a status in `which` that nobody has claimed."""
    return (issue.get("state", "OPEN") == "OPEN" and bool(set(status_of(issue)) & set(which))
            and not labels_of(issue) & set(CLAIMED))


def read_board(github, which):
    """The open issues, the bodies of those carrying a status in `which`, and each one's blocker check. The detailed
    read is selected again: an issue claimed, closed or moved between the list and that read is left out and named
    in `changed`, never judged from a state it no longer has."""
    issues = github.open_issues()
    open_numbers = {i["number"] for i in issues}
    board = Board(github)
    full, checks, changed = {}, {}, []
    for i in issues:
        if selected(i, which):
            detail = github.issue(i["number"])
            if selected(detail, which):
                full[i["number"]] = detail
            else:
                changed.append(i["number"])
    for n, issue in full.items():
        checks[n] = board.check(issue, require_line="status:blocked" in labels_of(issue))
    return open_numbers, full, checks, changed


def _parse_flags(args, allowed, usage):
    flags = set()
    for a in args:
        if a in ("-h", "--help"):
            say(usage)
            raise Stop("", 0)
        if a not in allowed:
            raise Stop("unknown argument (not shown); usage: %s" % usage, 64)
        flags.add(a)
    return flags


# --- status ----------------------------------------------------------------------------------------------------------
# factory status [--dry-run] [--note "<section>: <text>"]...
# The status update of core/skills/factory-lead/references/handoff-and-status.md › Status issue, built from fixed board
# queries only: the open issues and their labels and milestones, the detailed read of the issues whose line needs more
# (blocked: the "Blocked by" line and the blocker check; in progress: the latest "started" comment), the open and the
# recently merged pull requests, their comments (review markers, fix-round reports), and the status issue's own labels
# and comments (factory:paused, open back-off records). A line the board cannot know (a gate with its recommended
# answer, a temporary rule) comes only from --note, into the section it names; nothing is invented.
#   - The update passes the page's validator (validate_status: the same checks as its shell snippet, with its own fresh
#     queries) before anything is posted. The status issue itself is the one open issue it does not name: the page
#     calls that the known, deliberate exception. A failed query is exit 1, a refused check exit 3; both post nothing.
#   - Fix rounds per merged pull request are counted from the pull request's comments, as model-policy.md rule 3 defines
#     a round: one fix-round report, a builder's `### Fix round <n> (review of …)`, the lead's `### Fix round <n>
#     (lead)` or an adaptation round's `### Fix round <n> (adaptation: …)`. A paused report has no such heading and
#     does not count. This count includes adaptation rounds, which rule 3 leaves out of the escalation count.
#   - Model fit (model-policy.md rule 6): the "Model fit:" lines of the reports and reviews on the same merged pull
#     requests, outside fenced blocks and HTML comments, counted per work kind, role and tier, by verdict. A line that
#     starts like one but is not exactly in the policy's form is counted as not parsed, with its pull request; its
#     kind or verdict is never guessed.
#   - An issue whose line needs a detailed read is placed by that read (re-selected), never by the list: one that was
#     claimed, moved or closed in between lands where it is now, or is left out (closed) and named on stderr.
#   - Write path: the emergency stop is checked first, and again as its own subprocess right before the post; the post
#     is a new comment (broker: issue-comment). The status issue's body is never touched (decision 30), and the previous
#     status comment is not collapsed (that step is optional and has no broker verb). --dry-run prints and posts nothing.

STATUS_LABEL, PAUSED_LABEL, BACKLOG_LABEL = "factory:status", "factory:paused", "status:backlog"
MERGED_DAYS = 7          # "Merged recently": pull requests merged on this many UTC days, today included
NOTE_SECTIONS = {"waiting": "waiting", "in-flight": "flight", "ready": "ready", "blocked": "blocked", "rules": "rules"}
NOTE_MAX = 500
FIX_ROUND = re.compile(r"^### Fix round [1-9][0-9]* \(.+\)[ \t]*$", re.MULTILINE)
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
STARTED = re.compile(r"🤖 (?:Lead|Solo): started (\S+) on (\S+)")
REVIEW_MARKER = re.compile(r"<!-- factory:review ([^>]*)-->")
BACKOFF = re.compile(r"Back-off record: ([A-Za-z0-9._-]{1,60})")
BACKOFF_ENDED = re.compile(r"^ended \S", re.MULTILINE)
MERGED_LINE = re.compile(r"- #[0-9]+ via PR #[0-9]+ \([^,()]+, [0-9]+ fix rounds?\)")
BACKLOG_LINE = re.compile(r"(- )?Backlog \(status:backlog\): [0-9]+ issues?")
MODEL_FIT_LIKE = re.compile(r"[\s>*_`-]*model[ _-]*fit\W*:", re.IGNORECASE)
MODEL_FIT = re.compile(r"Model fit: (right|too weak|more than needed) \(([a-z][a-z-]{0,30}), [^\s,()]+, "
                       r"tier:([a-z][a-z0-9_-]{0,30}), kind ([A-Za-z0-9][A-Za-z0-9 ._-]{0,59})\): \S.*")
FIT_VERDICTS = ("right", "too weak", "more than needed")


class StatusGitHub(GitHub):
    """The reads and the post of `factory status`, in both columns of github-access.md, on top of GitHub."""

    def labelled(self, label, limit=LIST_LIMIT):
        """The open issues carrying a label. Refused when the answer may be cut."""
        what = "reading the open issues labelled %s" % label
        data = self._json(self._gh("issue", "list", "-R", self.repo or "", "--state", "open", "--label", label,
                                   "--limit", str(limit), "--json", "number,title,state,labels,milestone"),
                          ["issue-list", "--state", "open", "--label", label, "--limit", str(limit)], what)
        if not isinstance(data, list):
            raise GitHubError("%s: the answer is not a list" % what)
        if len(data) >= limit:
            raise GitHubError("%s: %d or more, which cannot be read whole" % (what, limit))
        return [_issue(i) for i in data]

    def issue_raw_comments(self, n):
        """One issue with its comments, the comments as {body, url}: (issue, comments)."""
        data = self._json(self._gh("issue", "view", str(n), "-R", self.repo or "", "--json",
                                   "number,title,body,state,labels,milestone,url,comments"),
                          ["issue-view", str(n), "--comments"], "reading issue #%d" % n)
        issue = _issue(data, need_body=True)
        if issue["number"] != n or issue["comments"] is None:
            raise GitHubError("reading issue #%d: the answer is not that issue with its comments" % n)
        return issue, [{"body": c["body"], "url": c.get("url") if isinstance(c.get("url"), str) else None}
                       for c in data["comments"]]

    def merged_since(self, day):
        """The pull requests merged from UTC day `day` (YYYY-MM-DD) to now, as prs() gives them, read whole however
        many there are: each search reads up to SEARCH_LIMIT, and a part that reaches it is split in two by merge day,
        down to one UTC day. One day of SEARCH_LIMIT or more is refused, never read in part."""
        try:
            since = datetime.date.fromisoformat(day)
        except ValueError:
            raise GitHubError("reading the merged pull requests: %s is not a day" % day)
        today = datetime.datetime.now(datetime.timezone.utc).date()
        seen = {}

        def read(first, last):   # merged from day `first` to day `last`; last None: to now
            q = "merged:>=%s" % first if last is None else "merged:%s..%s" % (first, last)   # dates print YYYY-MM-DD
            data = self.prs("merged", q, limit=SEARCH_LIMIT, refuse=False)
            if len(data) < SEARCH_LIMIT:
                for p in data:
                    _check_closing_refs(p)
                    seen.setdefault(p["number"], p)
                return
            end = last or max(today, first)
            if end <= first:
                raise GitHubError("reading the merged pull requests: %d or more merged on %s, which cannot be read "
                                  "whole" % (SEARCH_LIMIT, first))
            mid = first + (end - first) // 2
            read(first, mid)
            read(mid + datetime.timedelta(days=1), last)

        read(since, None)
        return sorted(seen.values(), key=lambda p: p["number"], reverse=True)

    def prs(self, state, search=None, limit=PR_LIMIT, refuse=True):
        """Pull requests: number, headRefOid, mergeCommit, mergedAt (mode off), closingIssuesReferences; at most
        `limit`. An answer of `limit` or more is refused, never read in part (merged_since asks with refuse False)."""
        what = "reading the %s pull requests" % state
        off = self._gh("pr", "list", "-R", self.repo or "", "--state", state, "--limit", str(limit), "--json",
                       "number,state,headRefOid,mergeCommit,closingIssuesReferences"
                       + (",mergedAt" if state == "merged" else ""))
        on = ["pr-list", "--state", state, "--limit", str(limit)]
        if search:
            off += ["--search", search]
            on += ["--search", search]
        data = self._json(off, on, what)
        if not isinstance(data, list) or not all(isinstance(p, dict) and _int(p.get("number")) for p in data):
            raise GitHubError("%s: the answer is not a list of pull requests" % what)
        if refuse and len(data) >= limit:
            raise GitHubError("%s: %d or more, which cannot be read whole" % (what, limit))
        return data

    def pr_comments(self, p):
        """The bodies of a pull request's comments, oldest first."""
        what = "reading the comments of PR #%d" % p
        data = self._json(self._gh("pr", "view", str(p), "-R", self.repo or "", "--json", "number,comments"),
                          ["pr-view", str(p), "--comments"], what)
        comments = data.get("comments") if isinstance(data, dict) else None
        if not isinstance(data, dict) or data.get("number") != p or not isinstance(comments, list):
            raise GitHubError("%s: the answer is not that pull request with its comments" % what)
        bodies = [c.get("body") if isinstance(c, dict) else None for c in comments]
        if not all(isinstance(b, str) for b in bodies):
            raise GitHubError("%s: a comment of an unexpected shape" % what)
        return bodies

    def commit_day(self, sha):
        """The UTC day of a commit on origin, after the run's one fetch (mode on has no merge date in its answer)."""
        self.default_ref()
        try:
            p = subprocess.run(["git", "show", "-s", "--format=%ct", sha, "--"], cwd=self.project.root,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
        except (OSError, subprocess.SubprocessError):
            p = None
        text = p.stdout.decode("utf-8", "replace").strip() if p is not None and p.returncode == 0 else ""
        if not re.fullmatch(r"[0-9]{1,12}", text):
            raise GitHubError("git cannot read the date of merge commit %s" % sha[:12])
        return datetime.datetime.fromtimestamp(int(text), datetime.timezone.utc).strftime("%Y-%m-%d")


def one_line(text):
    """A title or a note as one line of the update: control characters and line breaks become spaces."""
    return re.sub(r"\s+", " ", _clean(text)).strip()


def parse_status_args(args, usage):
    dry, notes = False, {k: [] for k in set(NOTE_SECTIONS.values())}
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-h", "--help"):
            say(usage)
            raise Stop("", 0)
        if a == "--dry-run":
            dry = True
        elif a == "--note" or a.startswith("--note="):
            if a == "--note":
                if i + 1 >= len(args):
                    raise Stop("--note needs \"<section>: <text>\"; usage: %s" % usage, 64)
                i += 1
                value = args[i]
            else:
                value = a[len("--note="):]
            section, sep, text = value.partition(":")
            text = one_line(text)
            if not sep or section.strip() not in NOTE_SECTIONS:
                raise Stop("a --note starts with its section (%s), then a colon; usage: %s"
                           % (", ".join(sorted(NOTE_SECTIONS)), usage), 64)
            if "\n" in value or "\r" in value or not text or len(text) > NOTE_MAX:
                raise Stop("a --note is one line of 1 to %d characters" % NOTE_MAX, 64)
            notes[NOTE_SECTIONS[section.strip()]].append(text[2:] if text.startswith("- ") else text)
        else:
            raise Stop("unknown argument (not shown); usage: %s" % usage, 64)
        i += 1
    return dry, notes


def status_section(issue):
    """Where an open issue goes in the update, from its labels."""
    labels = labels_of(issue)
    if issue["state"] != "OPEN":
        return "closed"
    if STATUS_LABEL in labels:
        return "self"
    if BACKLOG_LABEL in labels:
        return "backlog"
    if EPIC_LABEL in labels:
        return "epic"   # a breakdown, never built itself: its own section, whatever status it carries
    for label, section in (("status:needs-human", "waiting"), ("status:in-review", "review"),
                           ("status:in-progress", "progress"), ("status:blocked", "blocked")):
        if label in labels:
            return section
    if "agent:human" in labels:
        return "waiting"
    if "status:ready" in labels:
        return "ready"
    return "other"


REF_NAME = re.compile(r"[A-Za-z0-9_.-]+")


def _check_closing_refs(pr):
    """Refuse a merged pull request whose closingIssuesReferences cannot be read whole: it must be a list (an empty one
    closes nothing), each entry an issue number with its repository, named by a url to that issue or by repository.name
    and repository.owner.login. _closing_here() would read anything else as "closes nothing" and drop the pull request
    from the page without a word."""
    what = "reading the merged pull requests: PR #%d's closingIssuesReferences" % pr["number"]
    refs = pr.get("closingIssuesReferences")
    if not isinstance(refs, list):
        raise GitHubError("%s is missing or not a list" % what)
    for ref in refs:
        if not isinstance(ref, dict) or not _int(ref.get("number")):
            raise GitHubError("%s holds an entry without an issue number" % what)
        m = ISSUE_URL.fullmatch(ref["url"]) if isinstance(ref.get("url"), str) else None
        if m:
            if int(m.group(3)) != ref["number"]:
                raise GitHubError("%s holds an entry whose url is not that issue's" % what)
            continue
        r = ref.get("repository")
        o = r.get("owner") if isinstance(r, dict) else None
        if not (isinstance(r, dict) and isinstance(r.get("name"), str) and REF_NAME.fullmatch(r["name"])
                and isinstance(o, dict) and isinstance(o.get("login"), str) and REF_NAME.fullmatch(o["login"])):
            raise GitHubError("%s holds an entry without its repository" % what)


def _closing_here(pr, repo):
    """The issue numbers of this repository a pull request closes (its closingIssuesReferences)."""
    owner, name = (s.lower() for s in repo.split("/"))
    out = set()
    for ref in pr.get("closingIssuesReferences") or []:
        if not isinstance(ref, dict) or not _int(ref.get("number")):
            continue
        m = ISSUE_URL.fullmatch(ref["url"]) if isinstance(ref.get("url"), str) else None
        if m:
            here = m.group(1).lower() == owner and m.group(2).lower() == name and int(m.group(3)) == ref["number"]
        else:
            r = ref.get("repository") if isinstance(ref.get("repository"), dict) else {}
            o = r.get("owner") if isinstance(r.get("owner"), dict) else {}
            here = str(r.get("name", "")).lower() == name and str(o.get("login", "")).lower() == owner
        if here:
            out.add(ref["number"])
    return out


def report_text(body):
    """A comment without its HTML comments and fenced code blocks. A fix-round heading there is an example, not a report.
    An unclosed comment or fence runs to the end of the comment, as Markdown shows it."""
    out, fence = [], None
    for line in HTML_COMMENT.sub("", body).splitlines():
        m = FENCE.match(line)
        if fence is None:
            if m:
                fence = m.group(1)
            else:
                out.append(line)
        elif m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not line[m.end():].strip():
            fence = None
    return "\n".join(out)


def fix_rounds(comments):
    """One round per fix-round report on the pull request, never an example of one. It counts every report,
    adaptations included, so it is not model-policy.md rule 3's escalation count (an adaptation does not count there);
    it is the count "Merged recently" prints."""
    return sum(1 for body in comments if FIX_ROUND.search(report_text(body)))


def model_fits(comments):
    """model-policy.md rule 6: ([(kind, role, tier, verdict)], lines not parsed) from a pull request's comments, never
    from an example inside a fenced block or an HTML comment."""
    found, unparsed = [], 0
    for body in comments:
        for line in report_text(body).splitlines():
            if not MODEL_FIT_LIKE.match(line):
                continue
            m = MODEL_FIT.fullmatch(line.strip())
            if m:
                found.append((m.group(4).strip(), m.group(2), m.group(3), m.group(1)))
            else:
                unparsed += 1
    return found, unparsed


def _marker(comments):
    """The latest review marker's fields, or None."""
    found = None
    for body in comments:
        for m in REVIEW_MARKER.finditer(body):
            found = m.group(1)
    if found is None:
        return None
    return dict(kv.split("=", 1) for kv in found.split() if "=" in kv)


def review_step(pr, comments):
    """The next step of an open pull request, from its latest review marker and its head."""
    mk = _marker(comments)
    if mk is None:
        return "waits for its first review"
    head, verdict = mk.get("head", ""), re.sub(r"[^A-Za-z0-9_-]", "", mk.get("verdict", "")) or "no verdict"
    current = pr.get("headRefOid") if isinstance(pr.get("headRefOid"), str) else ""
    if not re.fullmatch(r"[0-9a-f]{7,40}", head) or not current.startswith(head):
        return "the latest review (%s) is on an older head: re-review, or check that it carries over" % verdict
    if verdict == "merge" and all(mk.get(k) == "0" for k in ("p0", "p1", "p2", "human")):
        return "the review says merge: the merge gate is next"
    counts = " ".join("%s=%s" % (k, re.sub(r"[^0-9]", "", mk.get(k, "")) or "?") for k in ("p0", "p1", "p2"))
    return "the review says %s (%s): a fix round is next" % (verdict, counts)


def build_status(github, notes):
    """(update text, status issue number, numbers left out because they closed meanwhile). Every read must succeed."""
    repo = github.project.repo()
    status = github.labelled(STATUS_LABEL, limit=10)
    if not status:
        raise Stop("no open issue is labelled %s (factory-init creates it); nothing was posted" % STATUS_LABEL)
    if len(status) > 1:
        raise Stop("several open issues are labelled %s (%s): ask the user which one to keep; nothing was posted"
                   % (STATUS_LABEL, _nums(sorted(i["number"] for i in status))), 3)
    s = status[0]["number"]
    status_issue, status_comments = github.issue_raw_comments(s)
    issues = github.open_issues()

    placed, changed = {}, []
    for i in issues:
        section = status_section(i)
        if section in ("blocked", "progress"):
            detail = github.issue(i["number"], comments=True)   # the detailed read decides, never the list
            if status_section(detail) != section:
                changed.append(i["number"])
            i, section = detail, status_section(detail)
        if section in ("closed", "self"):
            continue
        placed.setdefault(section, []).append(i)
    closed = [n for n in changed if n not in {i["number"] for v in placed.values() for i in v}]

    board = Board(github)
    open_prs = github.prs("open") if placed.get("review") else []
    since = (datetime.datetime.now(datetime.timezone.utc).date()
             - datetime.timedelta(days=MERGED_DAYS - 1)).strftime("%Y-%m-%d")
    merged = github.merged_since(since)

    def title(i):
        return one_line(i["title"])

    out = ["## Status %s" % datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"), ""]
    if PAUSED_LABEL in labels_of(status_issue):
        out += ["**Paused**: `factory:paused` is on this issue; nothing starts or merges until it is removed.", ""]

    def section(heading, lines, empty="nothing"):
        out.extend(["### " + heading, ""] + (lines or [empty]) + [""])

    by_number = lambda key: sorted(placed.get(key, []), key=lambda i: i["number"])   # noqa: E731

    waiting = ["- #%d %s (%s)" % (i["number"], title(i), "status:needs-human" if "status:needs-human" in labels_of(i)
                                   else "agent:human") for i in by_number("waiting")]
    section("Waiting on you", waiting + ["- " + t for t in notes["waiting"]])

    flight = []
    for i in sorted(placed.get("progress", []) + placed.get("review", []), key=lambda i: i["number"]):
        if status_section(i) == "progress":
            started = [m for m in (STARTED.search(c) for c in i["comments"] or []) if m]
            how = ("in progress (%s, %s)" % (one_line(started[-1].group(1)), one_line(started[-1].group(2)))
                   if started else "in progress (no \"started\" comment)")
        else:
            prs = sorted((p for p in open_prs if i["number"] in _closing_here(p, repo)), key=lambda p: p["number"])
            if not prs:
                how = "in review (no open pull request closes it)"
            else:
                how = "in review (%s)" % "; ".join("PR #%d, %s" % (p["number"], review_step(p, github.pr_comments(
                    p["number"]))) for p in prs)
        flight.append("- #%d %s: %s" % (i["number"], title(i), how))
    section("In flight", flight + ["- " + t for t in notes["flight"]])

    ready = []
    for i in sorted(placed.get("ready", []), key=lambda i: (milestone_key(i), i["number"])):
        tiers = tiers_of(i)
        ready.append("- #%d %s (%s, %s)" % (i["number"], title(i),
                                             "no milestone" if not i["milestone"] else milestone_text(i),
                                             tiers[0] if len(tiers) == 1 else ("no tier" if not tiers
                                                                               else "several tiers")))
    nb = len(placed.get("backlog", []))
    ready.append("- Backlog (status:backlog): %d issue%s" % (nb, "" if nb == 1 else "s"))
    section("Ready next", ready + ["- " + t for t in notes["ready"]])

    blocked = []
    for i in by_number("blocked"):
        # Every read the line rests on must succeed: the native blockers and each blocker's done evidence. The blocker
        # check reports a read it could not make as a reason; here that is a failed query, and nothing is posted.
        result = board.check(i, require_line=True, native=github.deps(i["number"], "blocked-by"))
        unread = [why for _, st, why in result["waiting"] if st == "cannot tell"]
        if unread:
            raise GitHubError("#%d: a blocker's evidence cannot be read (%s)" % (i["number"], unread[0]))
        blocked.append("- #%d %s: %s" % (i["number"], title(i), one_line(why_blocked(result)) if not result["free"]
                                         else "every blocker is done; factory unblock --apply moves it"))
    section("Blocked", blocked + ["- " + t for t in notes["blocked"]])

    epics = []
    for i in by_number("epic"):
        # An epic keeps the labels a person would act on in its line, so a needs-human epic is not lost here.
        kept = sorted(labels_of(i) & (set(STATUS_LABELS) | {"agent:human"}))
        epics.append("- #%d %s%s" % (i["number"], title(i), " (%s)" % ", ".join(kept) if kept else ""))
    if epics:
        section("Epics", epics)
    if placed.get("other"):
        section("No status label", ["- #%d %s" % (i["number"], title(i)) for i in by_number("other")])

    merged_lines, fits, unparsed = [], {}, []
    for p in sorted(merged, key=lambda p: p["number"], reverse=True):
        numbers = _closing_here(p, repo)
        if not numbers:
            continue
        day = p.get("mergedAt")[:10] if isinstance(p.get("mergedAt"), str) else ""
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", day):
            mc = p.get("mergeCommit") if isinstance(p.get("mergeCommit"), dict) else {}
            sha = mc.get("oid")
            if not isinstance(sha, str) or not SHA.fullmatch(sha):
                raise GitHubError("merged PR #%d has neither a merge date nor a readable merge commit" % p["number"])
            day = github.commit_day(sha)
        comments = github.pr_comments(p["number"])
        r = fix_rounds(comments)
        for n in sorted(numbers):
            merged_lines.append("- #%d via PR #%d (%s, %d fix round%s)" % (n, p["number"], day, r, "" if r == 1 else "s"))
        found, bad = model_fits(comments)
        for kind, role, tier, verdict in found:
            counts = fits.setdefault((kind, role, tier), dict.fromkeys(FIT_VERDICTS, 0))
            counts[verdict] += 1
        if bad:
            unparsed.append((p["number"], bad))
    section("Merged recently", merged_lines)

    fit_lines = ["- kind %s, %s, tier:%s: %s" % (kind, role, tier, ", ".join("%d %s" % (c[v], v) for v in FIT_VERDICTS))
                 for (kind, role, tier), c in sorted(fits.items())]
    if unparsed:
        nu = sum(b for _, b in unparsed)
        fit_lines.append("- not parsed: %d line%s (%s)" % (nu, "" if nu == 1 else "s", ", ".join(
            "PR #%d" % p for p, _ in sorted(unparsed, reverse=True))))
    section("Model fit (merged recently)", fit_lines, empty="none")

    rules = []
    for c in status_comments:
        first = next((ln.strip() for ln in c["body"].splitlines() if ln.strip()), "")
        m = BACKOFF.fullmatch(first)
        if m and not BACKOFF_ENDED.search(c["body"]):
            rules.append("- back-off on %s (%s)" % (m.group(1), c["url"] or "its record on this issue"))
    section("Temporary rules", rules + ["- " + t for t in notes["rules"]], empty="none")

    return redact("\n".join(out).rstrip("\n") + "\n"), s, closed


def validate_status(text, open_numbers, backlog_numbers, exempt=()):
    """handoff-and-status.md › Publishing status, step 2, in Python: (1, [message]) on a FAIL, (2, [messages]) on a
    CHECK, (0, []) when it passes. open_numbers and backlog_numbers come from the validator's own fresh queries."""
    lines = text.splitlines()
    if not text.strip():
        return 1, ["FAIL: empty"]
    for h in ("### Waiting on you", "### In flight"):
        if h not in lines:
            return 1, ["FAIL: section missing: %s" % h]
    if not open_numbers:
        return 1, ["FAIL: open-issue query empty"]
    found = [ln for ln in lines if BACKLOG_LINE.fullmatch(ln)]
    if len(found) != 1:
        return 1, ["FAIL: need exactly one backlog summary line (0 issues when there are none)"]
    if int(re.findall(r"[0-9]+", found[0])[-1]) != len(backlog_numbers):
        return 1, ["FAIL: backlog count does not match the %d status:backlog issues" % len(backlog_numbers)]
    in_merged = False
    for ln in lines:
        if ln.startswith("### "):
            in_merged = ln == "### Merged recently"
            continue
        if in_merged and ln.startswith("- ") and not MERGED_LINE.fullmatch(ln):
            return 1, ["FAIL: merged item without its fix-round count: %s" % ln]
    checks = ["CHECK: open issue #%d not listed" % n
              for n in sorted(set(open_numbers) - set(backlog_numbers) - set(exempt))
              if not re.search(r"#%d([^0-9]|$)" % n, text, re.MULTILINE)]
    return (2, checks) if checks else (0, [])


def cmd_status(args):
    usage = COMMANDS["status"][1]
    dry, notes = parse_status_args(args, usage)
    project = Project()
    github = StatusGitHub(project)
    if not dry:
        require_not_paused(project, github)
    text, s, closed = build_status(github, notes)
    for n in closed:
        note("factory status: #%d closed between the list and its read; left out" % n)
    # The validator's own queries, fresh, as the page's snippet runs them.
    open_numbers = [i["number"] for i in github.open_issues()]
    backlog = [i["number"] for i in github.labelled(BACKLOG_LABEL)]
    v, messages = validate_status(text, open_numbers, backlog, exempt=(s,))
    if dry:
        for ln in text.rstrip("\n").split("\n"):
            say(ln)
    if v:
        for m in messages:
            note("factory status: %s" % m)
        raise Stop("the validator refused the update; nothing was posted", 3)
    if dry:
        note("factory status: the validator passes; --dry-run, so nothing was posted (status issue #%d)" % s)
        return 0
    require_not_paused(project, github)   # its own subprocess, right before the post
    try:
        github.comment(s, text)
    except GitHubError as e:
        raise Stop("the status update was not posted: %s" % e)
    say("posted the status update on #%d" % s)
    return 0


# --- ready -----------------------------------------------------------------------------------------------------------

def cmd_ready(args):
    flags = _parse_flags(args, {"--json"}, COMMANDS["ready"][1])
    github = GitHub(Project())
    open_numbers, full, checks, changed = read_board(github, ("status:ready", "status:blocked"))
    rows, left_out, not_free = [], [], []
    for n in sorted(full):
        issue, result = full[n], checks[n]
        labels = labels_of(issue)
        if not result["free"]:
            if "status:ready" in labels:
                not_free.append((n, why_blocked(result)))
            continue
        how = "status:ready" if "status:ready" in labels else "blockers done"
        if result["done"]:
            how += ": " + done_text(result)
        if "agent:human" in labels or "type:epic" in labels:
            left_out.append((n, "agent:human" if "agent:human" in labels else "type:epic"))
            continue
        rows.append((issue, how))
    graph = dependents_graph(github, full, checks, [i["number"] for i, _ in rows], open_numbers)
    paths = {i["number"]: critical_path(graph, i["number"]) for i, _ in rows}

    def key(row):
        i = row[0]
        p = priority_of(i)
        jq = jumps_queue(i)
        return (0 if jq == RED_FIX else 1 if jq else 2, milestone_key(i), 10 if p is None else p, -paths[i["number"]], i["number"])

    rows.sort(key=key)
    notes = [x for n in sorted(checks) for x in ("#%d: %s" % (n, y) for y in checks[n]["notes"])]
    if "--json" in flags:
        say(json.dumps({"ready": [{"number": i["number"], "title": i["title"], "tiers": tiers_of(i),
                                   "milestone": milestone_text(i), "owned_paths": owned_paths(i["body"]),
                                   "jumps_queue": jumps_queue(i), "critical_path": paths[i["number"]],
                                   "why": how} for i, how in rows],
                        "left_out": [{"number": n, "why": w} for n, w in left_out],
                        "ready_but_blocked": [{"number": n, "why": w} for n, w in not_free],
                        "changed": [{"number": n} for n in changed],
                        "notes": notes, "order": ORDER_NOTE}, sort_keys=True))
        return 0
    if not rows:
        say("Nothing can start now.")
    for i, how in rows:
        tiers = tiers_of(i)
        tier = tiers[0] if len(tiers) == 1 else ("no tier" if not tiers else "several tiers")
        say("#%d  %s  milestone: %s  %s" % (i["number"], tier, milestone_text(i), i["title"]))
        owned = owned_paths(i["body"])
        say("      owned paths: %s" % (", ".join(owned) if owned else "none listed"))
        extra = []
        if jumps_queue(i):
            extra.append("jumps the queue (%s)" % jumps_queue(i))
        if paths[i["number"]]:
            extra.append("unblocks %d open issue%s" % (paths[i["number"]], "s" if paths[i["number"]] > 1 else ""))
        if len(tiers) != 1:
            extra.append("claim refuses it until it has one tier label")
        say("      %s%s" % (how, "".join("; " + x for x in extra)))
    for n in changed:
        say("note: #%d changed between the list and its read (claimed, closed or moved); left out" % n)
    for n, w in left_out:
        say("left out: #%d (%s, for a person)" % (n, w) if w == "agent:human" else
            "left out: #%d (%s: propose a breakdown first)" % (n, w))
    for n, w in not_free:
        say("left out: #%d is status:ready but blocked: %s" % (n, w))
    for x in notes:
        say("note: %s" % x)
    say(ORDER_NOTE)
    return 0


# --- unblock ---------------------------------------------------------------------------------------------------------

def cmd_unblock(args):
    flags = _parse_flags(args, {"--apply", "--json"}, COMMANDS["unblock"][1])
    apply = "--apply" in flags
    project = Project()
    github = GitHub(project)
    if apply:
        require_not_paused(project, github)
    _, full, checks, changed = read_board(github, ("status:blocked",))
    # An epic is a breakdown, never built itself: it is never proposed or moved to status:ready, as ready leaves it out.
    epics = sorted(n for n in checks if EPIC_LABEL in labels_of(full[n]))
    free = sorted(n for n, c in checks.items() if c["free"] and n not in epics)
    still = sorted(n for n, c in checks.items() if not c["free"] and n not in epics)
    moved, unconfirmed, failed = [], [], []
    if apply:
        for i, n in enumerate(free):
            # Each move is its own step: the emergency stop is checked again right before it, so a pause set while
            # this runs stops every move still to come (board.md › Pause).
            try:
                require_not_paused(project, github)
            except Stop as e:
                failed.extend((m, "not moved: %s" % e.message, e.code) for m in free[i:])
                break
            try:
                again = guarded_move(github, n, (full[n], checks[n]), remove=["status:blocked"],
                                     add=["status:ready"], require_line=True)
            except Stop as e:
                failed.append((n, e.message, e.code))
                continue
            except Unconfirmed as e:
                unconfirmed.append(n)
                failed.append((n, str(e), 1))
                continue
            except GitHubError as e:
                failed.append((n, str(e), 1))
                continue
            moved.append(n)   # the label moved and was read back: it counts as moved whatever happens to the comment
            # The comment is a write of its own: the pause is checked again right before it.
            try:
                require_not_paused(project, github)
            except Stop as e:
                failed.append((n, "moved to status:ready; its comment was not posted: %s" % e.message, e.code))
                failed.extend((m, "not moved: %s" % e.message, e.code) for m in free[i + 1:])
                break
            try:
                github.comment(n, "🤖 factory unblock: every blocker is done (%s); moved to status:ready.\n"
                               % done_text(again))
            except GitHubError as e:
                failed.append((n, "moved to status:ready, but the comment failed: %s" % e, 1))
    if "--json" in flags:
        say(json.dumps({"unblocked" if apply else "can_unblock":
                        [{"number": n, "done": [b for b, _ in checks[n]["done"]]} for n in (moved if apply else free)],
                        "unconfirmed": [{"number": n} for n in unconfirmed],
                        "changed": [{"number": n} for n in changed],
                        "still_blocked": [{"number": n, "why": why_blocked(checks[n])} for n in still],
                        "left_out": [{"number": n, "why": EPIC_LABEL} for n in epics],
                        "failed": [{"number": n, "why": m} for n, m, _ in failed],
                        "notes": [{"number": n, "note": x} for n in sorted(checks) for x in checks[n]["notes"]]},
                       sort_keys=True))
    else:
        if not checks:
            say("No open issue is status:blocked.")
        for n in free:
            verb = ("moved to status:ready" if n in moved else
                    "label edit sent, not confirmed" if n in unconfirmed else ("not moved" if apply else "can move"))
            say("#%d  %s: every blocker is done (%s)  %s" % (n, verb, done_text(checks[n]), full[n]["title"]))
        for n in still:
            say("#%d  still blocked: %s  %s" % (n, why_blocked(checks[n]), full[n]["title"]))
        for n in epics:
            say("left out: #%d (%s: propose a breakdown first)" % (n, EPIC_LABEL))
        for n in sorted(checks):
            for x in checks[n]["notes"]:
                say("note: #%d: %s" % (n, x))
        for n in changed:
            say("note: #%d changed between the list and its read (claimed, closed or moved); left out" % n)
        if free and not apply:
            say("Run factory unblock --apply to move %s to status:ready." % _nums(free))
    for n, m, _ in failed:
        note("factory unblock: #%d: %s" % (n, m))
    if failed:
        return 3 if all(code == 3 for _, _, code in failed) else 1
    return 0


# --- claim -----------------------------------------------------------------------------------------------------------

def cmd_claim(args):
    usage = COMMANDS["claim"][1]
    if any(a in ("-h", "--help") for a in args):
        say(usage)
        return 0
    if len(args) != 1 or not re.fullmatch(r"#?[1-9][0-9]{0,9}", args[0]):
        raise Stop("give one issue number; usage: %s" % usage, 64)
    n = int(args[0].lstrip("#"))
    project = Project()
    github = GitHub(project)
    require_not_paused(project, github)
    issue = github.issue(n)
    labels = labels_of(issue)

    def refuse(why):
        raise Stop("refused: #%d %s; nothing changed" % (n, why), 3)

    if issue["state"] != "OPEN":
        refuse("is closed")
    if labels & set(CLAIMED):
        refuse("is already claimed (%s)" % ", ".join(sorted(labels & set(CLAIMED))))
    tiers = tiers_of(issue)
    if not tiers:
        refuse("has no tier label (tier:deep, tier:standard or tier:light); give it one first")
    if len(tiers) > 1:
        refuse("has several tier labels (%s); keep one" % ", ".join(tiers))
    if "agent:human" in labels:
        refuse("is agent:human: only a person does it")
    status = status_of(issue)
    if status not in (["status:ready"], ["status:blocked"]):
        refuse("is not ready (status: %s)" % (", ".join(status) or "none"))
    require_line = status == ["status:blocked"]
    result = Board(github).check(issue, require_line)
    if not result["free"]:
        refuse("is blocked: %s" % why_blocked(result))
    try:
        guarded_move(github, n, (issue, result), remove=status, add=["status:in-progress"], require_line=require_line)
    except Unconfirmed as e:
        say("claim of #%d sent (%s -> status:in-progress), not confirmed" % (n, status[0]))
        raise Stop(str(e), 1)
    say("claimed #%d (%s): %s -> status:in-progress" % (n, tiers[0], status[0]))
    for x in result["notes"]:
        say("note: %s" % x)
    return 0


# --- the machine settings (docs/factory-yaml.md › Machine settings) ----------------------------------------------------

def core_defaults():
    """The core's defaults.yaml, one folder up from this file (core/defaults.yaml, .factory/defaults.yaml)."""
    try:
        d = load_yaml(os.path.join(HERE, "..", "defaults.yaml"))
    except (Refused, OSError, UnicodeDecodeError):
        d = None
    if not isinstance(d, dict):
        raise Stop("the core's defaults.yaml (one folder up from factory) is missing or cannot be read; restore the core "
                   "files with factory update")
    return d


def machine_limits():
    """{heavy, test_workers}: ~/.factory/machine.yaml › limits over the machine section of the core's defaults.yaml.
    The file is machine state: HOME, then ~/.factory, then the file, each opened by descriptor and checked by
    factory-safe-paths.py's rule (as the slots' folders are), and an unsafe one stops the run. The text read from that
    descriptor is judged by factory-doctor's machine check; a file it fails stops the run, and nothing is guessed."""
    machine = core_defaults().get("machine")
    core = machine.get("limits") if isinstance(machine, dict) else None
    limits = dict(core) if isinstance(core, dict) else {}
    home = os.environ.get("HOME") or ""
    fd = None
    if os.path.isabs(home) and os.path.isdir(home):
        try:
            paths = _load_paths()
        except BaseException:  # noqa: B036 (one fixed refusal)
            raise Stop("factory-safe-paths.py is missing or broken next to factory; restore the core files with factory "
                       "update")
        fds = []
        try:
            fds.append(paths.open_home("the machine settings (~/.factory/machine.yaml)"))
            fds.append(paths.open_at(fds[-1], ".factory", "~/.factory", True, False))
            if fds[-1] is not None:
                fd = paths.open_at(fds[-1], "machine.yaml", "~/.factory/machine.yaml", False, False)
        except paths.Unsafe as e:
            raise Stop(str(e))
        finally:
            for f in fds:
                if f is not None:
                    os.close(f)
    if fd is not None:
        del _doctor.OUT[:]
        try:
            doc = _doctor.check_machine("~/.factory/machine.yaml", fd)
        finally:
            os.close(fd)
            del _doctor.OUT[:]
        if not isinstance(doc, dict):
            raise Stop("~/.factory/machine.yaml is not valid; run factory doctor for what to fix")
        own = doc.get("limits")
        limits.update(own if isinstance(own, dict) else {})
    out = {}
    for k in ("heavy", "test_workers"):
        lo, hi = _doctor.MACHINE_LIMITS[k]
        v = limits.get(k)
        if not _int(v) or not lo <= v <= hi:
            raise Stop("machine.limits.%s has no usable value (neither ~/.factory/machine.yaml nor the core's defaults "
                       "give one from %d to %d); run factory doctor" % (k, lo, hi))
        out[k] = v
    return out


# --- the machine's slots (docs/factory-yaml.md › Machine settings, "How leads share it") -----------------------------

# A pool is a folder, ~/.factory/locks/<pool>/, shared by every project and session on the machine. Each process that
# wants a slot joins a queue: one file per process, named by its ticket (12 digits, one more than the highest ticket
# there, created with O_EXCL), holding {pid, since}. The process keeps an exclusive flock on its file for as long as it
# waits or holds, and the command it runs in the slot inherits that open file (and with it the lock), as does
# everything the command starts that keeps it. The kernel drops the lock when the last of them ends, in any way, so an
# unlocked entry is a dead holder's and whoever sees it removes it; a wrapper killed with SIGKILL leaves the slot held
# for as long as its command still runs. Fair, first come first served: a process holds a slot when fewer than the
# pool's limit of live entries have a lower ticket; it waits otherwise, reading the limit again on every poll. Each
# entry's rank only falls as the entries ahead of it end, so no more than the limit hold at once (a limit lowered while
# slots are held applies to the next one taken). The folders and the entries are machine state: opened by descriptor
# and checked by factory-safe-paths.py's rule (a real folder or regular file of yours, no symbolic link, no hard link,
# no group or other write), and one that breaks it stops the run. Limits, stated plainly: a process the command leaves
# running in the background after a wrapper died keeps the slot until it ends or closes the file; and the folder must
# be on a local disk (flock).
LOCK_POLL = 0.25
JOIN_AGE = 60           # seconds an empty, unlocked entry counts as a joiner still writing it, not as a dead one
TICKET = re.compile(r"[0-9]{12}")
HELD = re.compile(r"([0-9]{12}):([0-9]{1,9})")   # FACTORY_LOCK_<POOL>: the held ticket and its inherited descriptor


def _load_paths():
    spec = importlib.util.spec_from_file_location("factory_safe_paths", os.path.join(HERE, "factory-safe-paths.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def open_pool(pool):
    """~/.factory/locks/<pool>/ as a folder descriptor, every folder from ~/.factory down opened and checked by
    factory-safe-paths.py's rule (created 0700 when missing); an unsafe one stops the run before anything is read."""
    try:
        paths = _load_paths()
    except BaseException:  # noqa: B036 (one fixed refusal)
        raise Stop("factory-safe-paths.py is missing or broken next to factory; restore the core files with factory "
                   "update")
    fds = []
    try:
        fds.append(paths.open_home("the machine's slots (~/.factory/locks/)"))
        fds.append(paths.open_at(fds[-1], ".factory", "~/.factory", True, True))
        fds.append(paths.open_at(fds[-1], "locks", "~/.factory/locks", True, True))
        pool_fd = paths.open_at(fds[-1], pool, "~/.factory/locks/" + pool, True, True)
    except paths.Unsafe as e:
        raise Stop(str(e))
    finally:
        for fd in fds:
            os.close(fd)
    return paths, pool_fd


class Slot:
    """One slot of a machine-wide pool: take() waits in line for it, give_back() leaves. `limit` is a function that
    returns the pool's current limit. A process that already holds this pool's slot (factory verify run under factory
    lock heavy) finds it in FACTORY_LOCK_<POOL> as "<ticket>:<descriptor>" and uses it, without queueing again, only
    when that descriptor is open in it and is that live entry."""

    def __init__(self, pool, limit):
        self.pool, self.limit = pool, limit
        self.paths, self.dirfd = open_pool(pool)
        self.env = "FACTORY_LOCK_" + pool.upper()
        self.fd = self.name = self.ticket = self.held = None

    def _where(self, name=""):
        return "~/.factory/locks/%s/%s" % (self.pool, name)

    def _open(self, name, **kw):
        try:
            return self.paths.open_at(self.dirfd, name, self._where(name), False, kw.pop("create", False), **kw)
        except self.paths.Unsafe as e:
            raise Stop(str(e))

    def _same(self, name, fd):
        try:
            a, b = os.stat(name, dir_fd=self.dirfd, follow_symlinks=False), os.fstat(fd)
        except OSError:
            return False
        return (a.st_ino, a.st_dev) == (b.st_ino, b.st_dev)

    def _tickets(self):
        try:
            names = os.listdir(self.dirfd)
        except OSError as e:
            raise Stop("cannot read %s (%s)" % (self._where(), e.__class__.__name__))
        return sorted(int(n) for n in names if TICKET.fullmatch(n))

    def _alive(self, name, remove=True):
        """True while the entry's process lives (it, or the command it runs, holds the entry's flock), or while it is
        still being written (empty, younger than JOIN_AGE). A dead one's entry is removed. An entry that breaks the
        safe-path rule stops the run."""
        fd = self._open(name)
        if fd is None:
            return False
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as e:
                if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                    return True
                raise Stop("cannot test %s (%s); the folder must be on a local disk" % (self._where(name),
                                                                                       e.__class__.__name__))
            st = os.fstat(fd)
            if st.st_size == 0 and time.time() - st.st_mtime < JOIN_AGE:
                return True
            if remove and self._same(name, fd):
                try:
                    os.unlink(name, dir_fd=self.dirfd)
                except FileNotFoundError:
                    pass
            return False
        finally:
            os.close(fd)

    def _join(self):
        """Create the next ticket as a new file (O_EXCL, so a taken number is never shared), lock it, then write who
        holds it. Until it is written, other processes count the empty entry as alive (JOIN_AGE). SIGINT, SIGTERM and
        SIGHUP stay blocked from before the file is created until the slot knows it (self.fd, self.name), so one
        that comes in between waits until give_back() can remove the entry, instead of leaving it for others to
        count as a live joiner."""
        for _ in range(1000):
            tickets = self._tickets()
            n = (tickets[-1] if tickets else 0) + 1
            name = "%012d" % n
            mask = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
            try:
                try:
                    fd = self._open(name, create=True, write=True, exclusive=True)
                except FileExistsError:
                    continue
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX)
                except OSError as e:
                    # No lock held: nothing says the name is still this process's file (a pause past JOIN_AGE could
                    # let _alive reap it and another process reuse the number), so leave it for _alive's age-based
                    # clean-up.
                    os.close(fd)
                    raise Stop("cannot lock %s (%s)" % (self._where(name), e.__class__.__name__))
                try:
                    os.write(fd, (json.dumps({"pid": os.getpid(), "since": int(time.time())}) + "\n").encode())
                except OSError as e:
                    # The lock is held, so nobody can reap the ticket: remove this process's own empty ticket now
                    # instead of leaving it for others to count as a joiner still writing, for up to JOIN_AGE. A
                    # failing unlink leaves it for _alive.
                    try:
                        if self._same(name, fd):
                            os.unlink(name, dir_fd=self.dirfd)
                    except OSError:
                        pass
                    finally:
                        os.close(fd)
                    raise Stop("cannot write %s (%s)" % (self._where(name), e.__class__.__name__))
                if not self._same(name, fd):
                    os.close(fd)
                    continue
                self.fd, self.name, self.ticket = fd, name, n
                return
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        raise Stop("could not join the queue in %s" % self._where())

    def _inherited(self):
        m = HELD.fullmatch(os.environ.get(self.env) or "")
        if not m:
            return None
        name, fd = m.group(1), int(m.group(2))
        try:
            ok = self._same(name, fd) and self._alive(name, remove=False)
        except Stop:
            ok = False
        return fd if ok else None

    def take(self, who):
        self.held = self._inherited()
        if self.held is not None:
            return
        self._join()
        started, said = time.time(), False
        while True:
            limit = self.limit()
            ahead = sum(1 for t in self._tickets() if t < self.ticket and self._alive("%012d" % t))
            if ahead < limit:
                break
            if not said:
                note("%s: waiting for a %s slot: %d ahead, limit %d (machine.limits.%s)" % (who, self.pool, ahead,
                                                                                          limit, self.pool))
                said = True
            time.sleep(LOCK_POLL)
        if said:
            note("%s: %s slot taken after %ds" % (who, self.pool, int(time.time() - started)))

    def child_env(self, env):
        env = dict(env)
        if self.held is not None:
            env[self.env] = os.environ.get(self.env, "")
        elif self.fd is not None:
            env[self.env] = "%s:%d" % (self.name, self.fd)
        return env

    def child_fds(self):
        """The open entry the command inherits (its own, or the one this process inherited), so the slot stays held
        while the command lives, even when this process dies first."""
        fd = self.fd if self.fd is not None else self.held
        return (fd,) if fd is not None else ()

    def give_back(self):
        """Leave the line. The command, and any background child of it, inherited the entry's descriptor and with it
        the flock: close ours first, then remove the entry only when no process still holds that flock (_alive's own
        test). A still-held entry stays and is counted, and _alive removes it once its last holder ends. It runs while
        the command's exit code is on its way out, so a refusal or a filesystem error here is reported, never raised:
        the entry is left for the next run's check to clear or stop on."""
        if self.fd is not None:
            name, mine = self.name, self._same(self.name, self.fd)
            os.close(self.fd)
            self.fd = None
            if mine:
                try:
                    self._alive(name)
                except Stop as e:
                    note("factory: %s; the slot entry was left in place" % e.message)
                except OSError as e:
                    note("factory: cannot remove %s (%s); the slot entry was left in place"
                         % (self._where(name), e.__class__.__name__))
        if self.dirfd is not None:
            os.close(self.dirfd)
            self.dirfd = None


def _limit_reader(key):
    """A function returning machine.limits.<key> as it is now; a machine file broken while waiting keeps the last
    good value (the first read stops the run instead)."""
    last = [machine_limits()[key]]

    def read():
        try:
            last[0] = machine_limits()[key]
        except Stop:
            pass
        return last[0]
    return read


class Signalled(Exception):
    def __init__(self, signum):
        Exception.__init__(self, signum)
        self.signum = signum


def _raise_on(signum, frame):
    raise Signalled(signum)


STOP_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


def on_signals(handler):
    """Set `handler` for SIGINT, SIGTERM and SIGHUP; returns the old handlers for restore_signals()."""
    return {s: signal.signal(s, handler) for s in STOP_SIGNALS}


def restore_signals(old):
    for s, h in old.items():
        signal.signal(s, h)


def _child_start(group, mask):
    """A preexec_fn for a command forked while the stop signals are blocked (signal.pthread_sigmask): its own process
    group or session first, then the signal mask as it was before the block, so the command starts as usual."""
    def start():
        group()
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
    return start


# --- lock --------------------------------------------------------------------------------------------------------------

def cmd_lock(args):
    usage = COMMANDS["lock"][1]
    if args[:1] in (["-h"], ["--help"]):
        say(usage)
        return 0
    if len(args) < 3 or args[0] != "heavy" or args[1] != "--":
        raise Stop("give the pool and the command after --; usage: %s" % usage, 64)
    argv = args[2:]
    slot = Slot("heavy", _limit_reader("heavy"))
    old = on_signals(_raise_on)
    try:
        slot.take("factory lock")
        # The command runs in a process group of its own, holding the slot's open entry (Slot.child_fds); the wrapper
        # passes SIGINT, SIGTERM and SIGHUP on to that whole group and waits for the command. Those signals stay
        # blocked from before the fork until the forwarder is set, so one that comes in between waits and then reaches
        # the command, instead of ending the wrapper while the command runs on without its slot.
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
        try:
            try:
                child = subprocess.Popen(argv, env=slot.child_env(os.environ), pass_fds=slot.child_fds(),
                                         preexec_fn=_child_start(os.setpgrp, mask))
            except FileNotFoundError:
                raise Stop("the command was not found (not shown)", 127)
            except (OSError, subprocess.SubprocessError):
                raise Stop("the command could not start (not shown)", 126)

            def forward(signum, frame):
                try:
                    os.killpg(child.pid, signum)
                except OSError:
                    pass
            on_signals(forward)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        rc = child.wait()
        return rc if rc >= 0 else 128 - rc
    except Signalled as e:
        raise Stop("stopped by signal %d before the command ran" % e.signum, 128 + e.signum)
    finally:
        restore_signals(old)
        slot.give_back()


# --- verify ------------------------------------------------------------------------------------------------------------

EVIDENCE = "<!-- factory:evidence head=%s tree=%s result=pass -->"
TAIL_LINES = 20
CHECKER_PATH = ".factory/bin/factory-release-check"    # where a project keeps the release checker (factory-install)
_checker = []
_checker_source = []


def holds_marker(text):
    """True when `text` holds any mention of a record tag, which is stricter than what the release checker reads as a
    marker: the checker counts a tag only when a record field follows it or it opens an HTML comment
    (counts_as_marker()), while this refuses every mention, prose included, which is the safe side. A marker later than
    the evidence record contradicts it (deploy contract › "a marker that contradicts is read loosely"), so no tag may
    appear in the comment after its first line, in --why, or on this tool's output. The grammar is the checker's own,
    not a copy: its loose() view of text (line breaks, compatibility forms, accents, invisible characters, look-alike
    letters) and its LOOSE_MARKER, loaded from factory-release-check next to this file."""
    load_checker()
    return bool(_checker[0].LOOSE_MARKER.search(_checker[0].loose(text)))


def checker_bytes():
    """The raw bytes of factory-release-check next to this file, read without running any of it."""
    try:
        with open(os.path.join(HERE, "factory-release-check"), "rb") as f:
            return f.read()
    except OSError:
        raise Stop("factory-release-check is missing next to factory; it holds the record-marker grammar, so nothing "
                   "is checked or posted without it (restore the core files with factory update)")


def load_checker(source=None):
    """Run factory-release-check once, from `source` (bytes already verified by verified_checker()) or else from the
    file next to this file, and keep the module and the bytes it ran from. Later calls reuse it."""
    if _checker:
        return _checker[0]
    if source is None:
        source = checker_bytes()
    path = os.path.join(HERE, "factory-release-check")
    try:
        loader = importlib.machinery.SourceFileLoader("factory_release_check", path)
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        exec(compile(source, path, "exec", dont_inherit=True), mod.__dict__)
        if not callable(getattr(mod, "loose", None)) or not hasattr(mod, "LOOSE_MARKER"):
            raise ImportError("no marker grammar")
    except (Exception, SystemExit):  # noqa: B902 (any failure to load it is the one refusal below)
        raise Stop("factory-release-check is missing or broken next to factory; it holds the record-marker "
                   "grammar, so nothing is checked or posted without it (restore the core files with factory "
                   "update)")
    _checker.append(mod)
    _checker_source.append(source)
    return mod


def glob_regex(pattern):
    """A `when` glob as factory-ci.yml reads it: `*` within one folder name, `**` across folders, `?` one character
    other than /, the whole path."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z", re.DOTALL)


def path_selected(path, patterns):
    """Ordered globs, the last that matches decides; a `!` pattern deselects (factory-ci.yml's rule)."""
    result = False
    for p in patterns:
        negate = p.startswith("!")
        if glob_regex(p[1:] if negate else p).match(path):
            result = not negate
    return result


def needed_checks(checks, changed):
    """[(name, check)] in factory.yaml's order: every check whose `gate` is not false and whose `when` selects a
    changed file (no `when`: any changed file), as merge-gate.md rule 2 ("Which checks") picks them."""
    return [(name, c) for name, c in checks.items()
            if c["gate"] and any(c["when"] is None or path_selected(f, c["when"]) for f in changed)]


def verify_config(tree):
    """commands.setup, commands.verify, commands.checks and ci.external from the factory.yaml in `tree` (the head being
    verified, so its own commands and `when` lists decide), after factory-doctor's check of the whole file passes (a
    file it fails is never used), with each check's entry defaults (core/defaults.yaml). A check's own `setup` prepares
    the CI runner and never runs locally, so it is left out."""
    defaults = core_defaults()
    del _doctor.OUT[:]
    doc = _doctor.check_factory_yaml(tree, defaults)
    failed = any(ln.startswith("R\tfactory.yaml\tfail\t") for ln in _doctor.OUT)
    del _doctor.OUT[:]
    if not isinstance(doc, dict) or failed:
        raise Stop("the head's factory.yaml is missing or does not pass factory doctor's check (run factory doctor on "
                   "that commit); nothing ran")
    commands = doc["commands"]
    entry = (defaults.get("entry_defaults") or {}).get("commands.checks.<name>") or {}
    checks = {}
    for name, c in (commands.get("checks") or {}).items():
        full = dict(entry, **c)
        checks[name] = {"run": full["run"], "when": full.get("when"), "heavy": full.get("heavy") is True,
                        "gate": full.get("gate") is not False}
    ci = doc.get("ci") if isinstance(doc.get("ci"), dict) else {}
    return {"setup": commands.get("setup") or None, "verify": commands["verify"], "checks": checks,
            "external": ci.get("external", [])}


def git(cwd, *args, what=None, raw=False):
    """git's output (stripped text, or bytes with raw); a failure stops the run with `what`."""
    try:
        p = subprocess.run(["git"] + list(args), cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=600)
    except (OSError, subprocess.SubprocessError):
        raise Stop("%s: git did not finish" % (what or "git"))
    if p.returncode != 0:
        raise Stop("%s (git: %s)" % (what or "git failed", short(p.stderr.decode("utf-8", "replace"))))
    return p.stdout if raw else p.stdout.decode("utf-8", "replace").strip()


ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
PYTEST = re.compile(r"=*\s*((?:\d+ [a-z]+(?:, )?)+) in [0-9.]+s\b.*")
UNITTEST_RAN = re.compile(r"Ran (\d+) tests? in .*")
UNITTEST_END = re.compile(r"(OK|FAILED)(?: \((.*)\))?")
JEST = re.compile(r"Tests:\s+(.*?),?\s*(\d+) total")
VITEST = re.compile(r"Tests\s+(\d+ [a-z]+(?: \| \d+ [a-z]+)*)\s+\((\d+)\)")
NODE = re.compile(r"[#ℹ]\s+(pass|fail|skipped|skip|todo|cancelled)\s+(\d+)")
MOCHA = re.compile(r"(\d+) (passing|pending|failing)\b.*")
CARGO = re.compile(r"test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored\b.*")
RSPEC = re.compile(r"(\d+) examples?, (\d+) failures?(?:, (\d+) pending)?\b.*")
ITEM = re.compile(r"(\d+) ([a-z]+)")


def test_counts(text):
    """(passed, skipped, failed), summed over every summary line of a test runner it knows (pytest, unittest, Jest,
    Vitest, node:test and TAP, Mocha, cargo test, RSpec) in a command's output; None when there is none. For the
    report only: a command passes or fails by its exit code, and a pass whose output reports failures counts as a
    failure."""
    total, found, pending_ran = [0, 0, 0], False, None

    def add(p=0, s=0, f=0):
        total[0] += p
        total[1] += s
        total[2] += f

    for raw in ANSI.sub("", text).replace("\r", "\n").splitlines():
        ln = raw.strip()
        m = PYTEST.fullmatch(ln)
        if m:
            items = {k: int(v) for v, k in ITEM.findall(m.group(1))}
            if {"passed", "failed", "skipped", "error", "errors"} & set(items):
                add(items.get("passed", 0) + items.get("xpassed", 0), items.get("skipped", 0) + items.get("xfailed", 0),
                    items.get("failed", 0) + items.get("error", 0) + items.get("errors", 0))
                found = True
            continue
        m = UNITTEST_RAN.fullmatch(ln)
        if m:
            pending_ran = int(m.group(1))
            continue
        m = UNITTEST_END.fullmatch(ln)
        if m and pending_ran is not None:
            items = dict((k.strip(), int(v)) for k, v in re.findall(r"([a-z ]+)=(\d+)", m.group(2) or ""))
            failed = items.get("failures", 0) + items.get("errors", 0) + items.get("unexpected successes", 0)
            skipped = items.get("skipped", 0) + items.get("expected failures", 0)
            add(max(pending_ran - failed - skipped, 0), skipped, failed)
            pending_ran, found = None, True
            continue
        m = JEST.fullmatch(ln)
        if m:
            items = {k: int(v) for v, k in ITEM.findall(m.group(1))}
            add(items.get("passed", 0), items.get("skipped", 0) + items.get("todo", 0) + items.get("pending", 0),
                items.get("failed", 0))
            found = True
            continue
        m = VITEST.fullmatch(ln)
        if m:
            items = {k: int(v) for v, k in ITEM.findall(m.group(1))}
            add(items.get("passed", 0), items.get("skipped", 0) + items.get("todo", 0), items.get("failed", 0))
            found = True
            continue
        m = NODE.fullmatch(ln)
        if m:
            k, v = m.group(1), int(m.group(2))
            add(v if k == "pass" else 0, v if k in ("skipped", "skip", "todo") else 0, v if k in ("fail", "cancelled") else 0)
            found = True
            continue
        m = MOCHA.fullmatch(ln)
        if m:
            v, k = int(m.group(1)), m.group(2)
            add(v if k == "passing" else 0, v if k == "pending" else 0, v if k == "failing" else 0)
            found = True
            continue
        m = CARGO.fullmatch(ln)
        if m:
            add(int(m.group(1)), int(m.group(3)), int(m.group(2)))
            found = True
            continue
        m = RSPEC.fullmatch(ln)
        if m:
            ex, fl, pe = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
            add(max(ex - fl - pe, 0), pe, fl)
            found = True
    return tuple(total) if found else None


def code_span(cmd):
    """The command as Markdown inline code, fenced so a backtick inside it cannot end the span."""
    runs = re.findall(r"`+", cmd)
    fence = "`" * (max((len(r) for r in runs), default=0) + 1)
    pad = " " if runs else ""
    return fence + pad + cmd + pad + fence


def evidence_line(step, counts):
    """One line of the evidence comment (merge-gate.md › rule 2, "Local evidence"); a command on several lines goes in
    a fenced block under it."""
    if step["kind"] == "setup":
        result = "passed (%s)" % step["label"]
    elif counts is None:
        result = "passed, no test counts in its output (%s)" % step["label"]
    else:
        result = "passed, %d passed, %d skipped, %d failed (%s)" % (counts + (step["label"],))
    cmd = step["cmd"]
    if "\n" not in cmd:
        return "- %s: %s" % (code_span(cmd), result)
    fence = "`" * max(3, max((len(r) for r in re.findall(r"`+", cmd)), default=0) + 1)
    body = "\n".join("  " + ln for ln in cmd.splitlines())
    return "- %s:\n  %ssh\n%s\n  %s" % (result, fence, body, fence)


def _kill_group(p):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except OSError:
            return
        try:
            p.wait(timeout=5)
            return
        except subprocess.TimeoutExpired:
            continue


def run_step(step, cwd, env, log, slot_limit):
    """Run one command with `sh -c` (a ci.external step: with its own `argv`, ext_argv) in the clean tree, its output
    (stdout and stderr) into `log`, heavy ones holding a heavy slot (the command holds it too, Slot.child_fds). Returns
    the exit code. The command runs in its own process group, ended with it on any stop. SIGINT, SIGTERM and SIGHUP
    stay blocked from before the fork until the command is known, so one that comes in between ends the command too,
    not only this process."""
    slot = Slot("heavy", slot_limit) if step["heavy"] else None
    try:
        # Taken inside the try, as cmd_lock does: a signal while waiting in line gives the ticket back at once.
        if slot:
            slot.take("factory verify")
            env = slot.child_env(env)
        with open(log, "wb") as out:
            mask = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
            try:
                p = subprocess.Popen(step.get("argv", ["sh", "-c"]) + [step["cmd"]], cwd=cwd, env=env,
                                     stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                     preexec_fn=_child_start(os.setsid, mask),
                                     pass_fds=slot.child_fds() if slot else ())
                try:
                    signal.pthread_sigmask(signal.SIG_SETMASK, mask)
                    return p.wait()
                except BaseException:
                    _kill_group(p)
                    raise
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, mask)
    finally:
        if slot:
            slot.give_back()


def read_log(log, limit=64 * 1024 * 1024):
    try:
        with open(log, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - limit))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def parse_verify_args(args, usage):
    n, why, i, no_heavy = None, None, 0, False
    while i < len(args):
        a = args[i]
        if a in ("-h", "--help"):
            say(usage)
            raise Stop("", 0)
        if a == "--no-heavy" and not no_heavy:
            no_heavy, i = True, i + 1
            continue
        if a == "--why" and i + 1 < len(args) and why is None:
            why, i = args[i + 1].strip(), i + 2
            continue
        if n is None and re.fullmatch(r"#?[1-9][0-9]{0,9}", a):
            n, i = int(a.lstrip("#")), i + 1
            continue
        raise Stop("unknown argument (not shown); usage: %s" % usage, 64)
    if why is not None:
        if n is None:
            raise Stop("--why goes with a pull request number; usage: %s" % usage, 64)
        if not why or len(why) > 300 or re.search(r"[\x00-\x1f\x7f]", why) or "<!--" in why or holds_marker(why):
            raise Stop("--why takes one line of plain text, at most 300 characters, with no record marker", 64)
    if no_heavy and n is not None:
        raise Stop("--no-heavy runs without a pull request number only: a run that leaves a heavy check out is never "
                   "evidence, so nothing is posted from one; usage: %s" % usage, 64)
    return n, why, no_heavy


def verify_steps(cfg, needed):
    """The commands in the order they run: commands.setup, verify, then each needed check (never its own setup, which
    is for the CI runner only)."""
    steps = []
    if cfg["setup"]:
        steps.append({"kind": "setup", "label": "setup", "cmd": cfg["setup"], "heavy": False})
    steps.append({"kind": "test", "label": "verify", "cmd": cfg["verify"], "heavy": False})
    for name, c in needed:
        steps.append({"kind": "test", "label": "check %s%s" % (name, ", heavy" if c["heavy"] else ""), "cmd": c["run"],
                      "heavy": c["heavy"]})
    return steps


# How Actions runs a `run:` step on a Linux or macOS runner (its documented shell commands), as `-c` takes it. Each
# stops at the first command that fails, as the step does.
EXT_SHELLS = {"sh": ["sh", "-e", "-c"], "bash": ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c"]}


def ext_argv(shell, env):
    """The argv before the command for a ci.external step with `shell` (gate_job_commands): sh and bash as Actions
    runs them, and no shell as Actions does by default, `bash -e`, or `sh -e` where `env`'s PATH has no bash. A step
    that names bash where there is none stops the run before anything runs."""
    if shell == "bash" and not shutil.which("bash", path=env.get("PATH")):
        raise Stop("a ci.external step names shell: bash, and bash is not installed here; nothing ran")
    if shell in EXT_SHELLS:
        return EXT_SHELLS[shell]
    return ["bash", "-e", "-c"] if shutil.which("bash", path=env.get("PATH")) else ["sh", "-e", "-c"]


def ci_not_run(github, e):
    """Whether the check `e` (pr_checks) did not run in CI on the head, as the gate's rule 2 reads it: skipped, or a
    failure that job_refused shows refused."""
    return e["bucket"] == "skipping" or (e["bucket"] == "fail" and e["state"] == "FAILURE" and
                                         github.job_refused(e["link"])[0])


def verify_external(github, checks, root, head, listed, env, cover=lambda w, j: None):
    """(the steps, [why each other job cannot be covered], {(workflow, job): the checks that cover it}) for the jobs of
    `listed` [(workflow, job)] that need local evidence on the pull request whose checks (pr_checks) are `checks`, as
    the gate's rule 2 reads them (merge-gate.md rule 2): the job's workflow has no check on the head (it did not start
    there), or a check of the job did not run (ci_not_run: skipped, or refused). A job that passed, is still running,
    was cancelled or ran and failed needs none: CI decides those, and evidence never overrides a red one. A job whose
    every check that did not run was refused, and that `cover` (gate_covered_by) gives checks for, is covered by those
    checks' entries, which the caller runs: it gives no step. Each other such job gives one step per step of it in the
    workflow file at `head`, each with its own shell, read as the gate reads it (gate_workflow, gate_job_commands),
    labelled GATE_EXT_LABEL; a job no evidence can stand for gets no step at all and is named with the gate's reason."""
    rc = _checker[0]
    ran = {e["workflow"] for e in checks}
    steps, uncovered, files, covered = [], [], {}, {}
    for w, j in listed:
        mine = [e for e in checks if e["workflow"] == w and gate_job_of(e["name"], j)]
        idle = [e for e in mine if ci_not_run(github, e)]
        if w in ran and not idle:
            continue
        names = cover(w, j) if w in ran and all(e["bucket"] == "fail" for e in idle) else None
        if names is not None:
            covered[(w, j)] = names
            continue
        shown = "%s / %s" % (rc.escape(w), rc.escape(j))
        try:
            if w not in files:
                files[w] = gate_workflow(root, head, w)
            if files[w] is None:
                uncovered.append("%s: the head has no workflow named %s in %s" % (shown, rc.escape(w), GATE_WORKFLOWS))
                continue
            cmds, why = gate_job_commands(files[w][0], files[w][1], j, shells=True)
        except GateUnknown as e:
            uncovered.append("%s: %s" % (shown, e))
            continue
        if cmds is None:
            uncovered.append("%s: %s" % (shown, why))
            continue
        steps += [{"kind": "test", "label": GATE_EXT_LABEL % (w, j), "cmd": c, "heavy": False,
                   "argv": ext_argv(sh, env)} for c, sh in cmds]
    return steps, uncovered, covered


def refuse_fork(project, pr):
    """Refuse a head from another repository, as GitHub's answer says (plain gh and the broker's pr-view give it; when
    an older broker does not, the branch check in cmd_verify decides alone)."""
    n = pr["number"]
    if pr["fork"]:
        raise Stop("refused: the head of #%d is in another repository (%s); code from a fork never runs here; nothing "
                   "ran" % (n, pr["head_repo"] or "a fork"), 3)
    if pr["head_repo"] is not None and pr["head_repo"].lower() != project.repo().lower():
        raise Stop("refused: the head of #%d is in %s, not %s; nothing ran" % (n, pr["head_repo"] or "an unknown "
                                                                                "repository", project.repo()), 3)


def cmd_verify(args):
    usage = COMMANDS["verify"][1]
    n, why, no_heavy = parse_verify_args(args, usage)
    if n is not None and why is None:
        raise Stop("factory verify %d posts evidence only with the reason local evidence stands in for CI "
                   "(merge-gate.md rule 2): pass --why \"<reason>\", for example --why \"CI refused: billing "
                   "annotation on run <run>\", --why \"not in ci.pr\" or --why \"skip_paths only\"; nothing ran, nothing "
                   "was posted (without a pull request number, factory verify runs as a diagnostic and posts nothing)"
                   % n, 64)
    project = Project()
    root = project.root
    github = GateGitHub(project)     # GitHub, with the gate's reads of a pull request's checks (ci.external)
    require_not_paused(project, github)
    workers = machine_limits()["test_workers"]
    heavy_limit = _limit_reader("heavy")

    # The head and the base it is compared with. With a pull request: its head as GitHub gives it, from this
    # repository only (a fork's head is refused before anything is fetched or run), fetched, and the same commit as
    # the tip of its branch on origin. Without: the checkout's HEAD commit (uncommitted changes are not part of the
    # run). Either way the base is fetched and must be origin's own tip of it, so a stale base never hides a change.
    if n is not None:
        pr = github.pr(n, draft=True)
        if pr["state"] != "OPEN":
            raise Stop("pull request #%d is %s: evidence is only for an open pull request; nothing ran"
                       % (n, pr["state"].lower()), 3)
        if pr["draft"]:
            raise Stop("pull request #%d is a draft: a draft's checks don't count yet (merge-gate.md rule 2), so no "
                       "evidence is posted on it; mark it ready (gh pr ready %d) and run factory verify again; nothing "
                       "ran" % (n, n), 3)
        refuse_fork(project, pr)
        github.fetch_pr(n)
        fetched = git(root, "rev-parse", "--verify", "-q", "refs/remotes/origin/pr/%d^{commit}" % n,
                      what="the fetched head of #%d cannot be read" % n)
        if fetched != pr["head"]:
            raise Stop("the head fetched for #%d (%s) is not the head GitHub gives (%s): the pull request moved; run "
                       "factory verify again" % (n, fetched[:12], pr["head"][:12]))
        head, base_name = pr["head"], pr["base"]
    else:
        head = git(root, "rev-parse", "--verify", "-q", "HEAD^{commit}", what="this checkout has no commit to verify")
        base_name = github.default_branch()
        github.fetch_branch(base_name)
        if git(root, "status", "--porcelain", what="git status failed"):
            note("factory verify: this checkout has uncommitted changes; they are not part of the run (it tests the "
                 "committed HEAD)")
    remote = github.heads()
    if n is not None and remote.get(pr["branch"]) != head:
        where = ("its branch %s is not in this repository" % pr["branch"] if pr["branch"] not in remote else
                 "its branch %s is at %s here" % (pr["branch"], remote[pr["branch"]][:12]))
        raise Stop("refused: the head of #%d is not the tip of a branch of this repository (%s): a head from a fork "
                   "never runs here, and a branch that moved needs a new run; nothing ran" % (n, where), 3)
    base = git(root, "rev-parse", "--verify", "-q", "origin/%s^{commit}" % base_name,
               what="origin/%s cannot be read" % base_name)
    if remote.get(base_name) != base:
        raise Stop("origin/%s here (%s) is not origin's own %s (%s) after the fetch: the checkout's fetch settings "
                   "(remote.origin.fetch) leave it out, or it just moved; nothing ran"
                   % (base_name, base[:12], base_name, (remote.get(base_name) or "missing")[:12]))
    fork_point = git(root, "merge-base", base, head, what="the head has no common history with origin/%s" % base_name)
    # The changed files: a pull request's own list, as merge-gate.md rule 2 › "Which checks" reads it (complete, or
    # refused in github.pr). Without a pull request there is no such list: the local diff from the fork point to HEAD,
    # without renames (a renamed file counts under both paths, so it may select more checks than the gate would).
    if n is not None:
        changed = pr["files"]
    else:
        changed = [os.fsdecode(p) for p in git(root, "diff", "-z", "--no-renames", "--name-only", fork_point, head,
                                               what="the changed files cannot be read", raw=True).split(b"\0") if p]
    tree = git(root, "rev-parse", "--verify", "-q", "%s^{tree}" % head, what="the head's tree cannot be read")

    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                                                             "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR")}
    env["FACTORY_TEST_WORKERS"] = str(workers)
    folder = _private_temp()
    wt = os.path.join(folder, "tree")
    lines, added = [], False
    old = on_signals(_raise_on)
    try:
        git(root, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", "--quiet", wt, head,
            what="the clean tree of %s cannot be made" % head[:12])
        added = True
        if git(wt, "rev-parse", "HEAD", what="the clean tree cannot be read") != head or \
                git(wt, "status", "--porcelain", "--untracked-files=all", what="the clean tree cannot be read"):
            raise Stop("the temporary worktree of %s is not a clean tree of it; nothing ran" % head[:12])
        # The head's own commands and `when` lists; only the repository the evidence goes to is the caller's. The
        # checks are those the gate's rule 2 requires (gate_required): the head's factory.yaml selects them, or the
        # base's does and the head's does not, which still run with the head's own command; one the head no longer
        # has cannot run here, and is named.
        cfg = verify_config(wt)
        holds_marker("")
        try:
            base_cfg = gate_config(root, base)
        except GateUnknown as e:
            base_cfg = None
            note("factory verify: %s's factory.yaml cannot be used (%s), so only the head's selects the checks and the "
                 "ci.external jobs; the gate's rule 1 cannot tell until it can" % (base_name, e))
        names = gate_required(cfg, base_cfg, changed)
        gone = [name for name in names if name not in cfg["checks"]]
        others = [name for name in cfg["checks"] if name not in names]
        listed, uncovered, checks, unrun = gate_external(cfg, base_cfg), [], None, []
        if n is not None and (listed or others):
            try:
                checks = github.pr_checks(n)
            except GitHubError as e:
                if listed:          # the ci.external jobs cannot be judged without them
                    raise
                note("factory verify: %s, so no check that is not required runs for it; factory gate %d says if one "
                     "still needs evidence" % (e, n))
        # A check that is not required (gate: false, or its `when` selects no changed file) and that CI refused or
        # skipped on the head still needs evidence (merge-gate.md rule 2, Checks with gate: false), so it runs too,
        # labelled as every check; one cancelled there needs a re-run in CI, which no evidence replaces.
        workflows = {w for w, _ in listed}
        for e in checks or []:
            if e["name"] in others and e["name"] not in unrun and e["workflow"] not in workflows:
                if ci_not_run(github, e):
                    unrun.append(e["name"])
                elif e["bucket"] == "cancel":
                    note("factory verify: the check %s was cancelled on this head: re-run it in CI, since no evidence "
                         "covers a cancelled check (merge-gate.md rule 2)" % e["name"])
        unrun = [name for name in others if name in unrun]                     # in factory.yaml's order
        # ci.external (the head's list and the base's, as rule 2 reads them): with a pull request, each listed job
        # its checks show needs local evidence, by the commands its steps run in the workflow file at the head, or,
        # for a job GitHub refused that covered_by covers (gate_covered_by), by the checks it names, which run here
        # as every check does (one the head's factory.yaml does not have cannot run, and is named).
        ext, covered = [], {}
        if listed and n is not None:
            ext, uncovered, covered = verify_external(github, checks, root, head, listed, env,
                                                      lambda w, j: gate_covered_by(cfg, base_cfg, w, j))
        covering = list(dict.fromkeys(x for v in covered.values() for x in v))
        cover_run = [name for name in others if name in covering and name not in unrun]
        cover_gone = [x for x in covering if x != "verify" and x not in cfg["checks"]]
        needed = [(name, c) for name, c in cfg["checks"].items() if name in names or name in unrun or
                  name in cover_run]
        not_gating = [name for name, c in cfg["checks"].items() if not c["gate"] and name in others and
                      name not in unrun and name not in cover_run]
        skipped = [name for name in others if name not in unrun and name not in not_gating and name not in cover_run]
        # --no-heavy (no pull request, so no evidence): a heavy check does not run in full; the gate runs it under the
        # machine's heavy lock (factory-implement § 5.2). The output says so, and the summary line is not a full run's.
        left = [name for name, c in needed if c["heavy"]] if no_heavy else []
        steps = verify_steps(cfg, [(name, c) for name, c in needed if name not in left]) + ext
        named = ["%s / %s" % x for x in listed]
        cover_lines = ["%s / %s: %s" % (w, j, ", ".join(v)) for (w, j), v in covered.items()]
        shown = "\n".join([step["cmd"] for step in steps] + [step["label"] for step in steps] + skipped + not_gating +
                          unrun + gone + uncovered + named + left + cover_lines)
        if holds_marker(shown):
            raise Stop("a command in the head's factory.yaml or workflows reads as a record marker (factory:gate, "
                       ":evidence or :review), which would contradict the record; nothing ran")
        if redact(shown) != shown:
            raise Stop("a command in the head's factory.yaml or workflows looks like it holds a credential; nothing "
                       "ran")
        for name in gone:
            note("factory verify: %s's factory.yaml requires the check %s for this diff, and the head's has no such "
                 "check, so nothing can run for it (a pull request that changes commands.checks is gated by hand)"
                 % (base_name, name))
        for why in uncovered:
            note("factory verify: no local evidence can stand for the ci.external job %s; it must run in CI" % why)
        for name in cover_gone:
            note("factory verify: ci.external's covered_by names the check %s, and the head's factory.yaml has no such "
                 "check, so nothing can run for it (a pull request that changes commands.checks is gated by hand)"
                 % name)
        for name in left:
            note("factory verify: --no-heavy: the heavy check %s is not run; it is left to the gate" % name)
        for i, step in enumerate(steps):
            note("factory verify: %s: %s" % (step["label"], step["cmd"].splitlines()[0] if step["cmd"] else ""))
            log = os.path.join(folder, "step-%d.log" % i)
            rc = run_step(step, wt, env, log, heavy_limit)
            output = read_log(log)
            counts = test_counts(output) if step["kind"] == "test" else None
            why_failed = None
            if rc != 0:
                why_failed = "exit %d" % rc if rc > 0 else "ended by signal %d" % -rc
            elif counts and counts[2] > 0:
                why_failed = "exit 0, but its output reports %d failed" % counts[2]
            if why_failed:
                note("factory verify: %s failed (%s): %s" % (step["label"], why_failed, step["cmd"]))
                tail = [ln for ln in output.splitlines() if ln.strip()][-TAIL_LINES:]
                if tail:
                    note("factory verify: the last lines of its output:")
                    for ln in tail:
                        note("  " + ln)
                note("factory verify: nothing was posted")
                return 2
            lines.append(evidence_line(step, counts))
    except Signalled as e:
        raise Stop("stopped by signal %d; nothing was posted" % e.signum, 128 + e.signum)
    finally:
        restore_signals(old)
        if added:
            try:
                git(root, "worktree", "remove", "--force", wt, what="the temporary worktree could not be removed")
            except Stop as e:
                note("factory verify: %s; run git worktree prune" % e.message)
        shutil.rmtree(folder, ignore_errors=True)

    status = ("up to date with %s at %s" % (base_name, base) if fork_point == base else
              "not up to date with %s at %s; evidence for this head never passes merge-gate rule 1: the updated "
              "head needs its own" % (base_name, base))
    kind = (" --no-heavy", "a partial local run, never evidence,") if no_heavy else ("", "local evidence")
    rest = ["🤖 factory verify%s: %s for head %s, tree %s (%s)" % (kind + (head, tree, status)),
            "FACTORY_TEST_WORKERS=%d" % workers] + lines
    if unrun:
        rest.append("Not required for this diff, and run because CI refused or skipped them on this head: %s"
                    % ", ".join(unrun))
    if skipped:
        rest.append("Not needed for this diff (no changed file matches their `when`): %s" % ", ".join(skipped))
    if not_gating:
        rest.append("Left out, not gating (`gate: false`): %s" % ", ".join(not_gating))
    if gone:
        rest.append("Required by %s's factory.yaml for this diff, and not a check of the head's, so no entry can name "
                    "its command (a pull request that changes commands.checks is gated by hand): %s"
                    % (base_name, ", ".join(gone)))
    if uncovered:
        rest.append("ci.external jobs no local evidence can stand for (they must run in CI): %s" % "; ".join(uncovered))
    if cover_lines:
        rest.append("ci.external jobs GitHub refused on this head, covered by the checks covered_by names: %s"
                    % "; ".join(cover_lines))
    if cover_gone:
        rest.append("Named by covered_by, and not a check of the head's factory.yaml, so no entry can name its command "
                    "(a pull request that changes commands.checks is gated by hand): %s" % ", ".join(cover_gone))
    if listed and n is None:
        rest.append("ci.external jobs, run only with a pull request (its checks show which need local evidence): %s"
                    % ", ".join(named))
    if no_heavy:
        rest.append("Left to the gate (heavy, not run with --no-heavy, so this is not a full run): %s"
                    % (", ".join(left) or "none selected for this diff"))
    rest.append("Why local: %s" % (why or "none: a run without a pull request is a diagnostic and posts nothing"))
    # The record is the comment's first line and goes nowhere else: everything after it, and everything printed
    # here, holds no marker the release checker would read.
    if holds_marker("\n".join(rest)):
        raise Stop("the comment would hold a record marker after its first line, which would contradict the record; "
                   "nothing was posted")
    text = "\n".join([EVIDENCE % (head, tree)] + rest) + "\n"
    if redact(text) != text:
        raise Stop("the comment looks like it holds a credential; nothing was posted")
    summary = "All %d commands passed on head %s, tree %s." % (len(lines), head, tree)
    if no_heavy:
        # Never the full run's line: that one ends at the tree, this one goes on with the option.
        summary = ("All %d commands passed on head %s, tree %s, with --no-heavy: not a full run (heavy checks left to "
                   "the gate: %s)." % (len(lines), head, tree, ", ".join(left) or "none selected for this diff"))
        say(summary + " Not posted, and never evidence. Its lines:")
        for ln in rest:
            say(ln)
        return 0
    if n is None:
        say(summary + " Not posted (no pull request given). The comment would be the evidence record for this head "
                      "and tree, then:")
        for ln in rest:
            say(ln)
        return 0
    require_not_paused(project, github)
    answer = github.pr_comment(n, text)
    say(summary)
    url = re.search(r"https://\S+#issuecomment-([0-9]+)", answer)
    say("Posted the evidence comment on #%d%s" % (n, ": %s (evidence comment id %s)" % (url.group(0), url.group(1))
                                                 if url else ""))
    return 0


# --- gate --------------------------------------------------------------------------------------------------------------
# factory gate <P> [--record]
# The merge gate of reference/merge-gate.md, rules 1-5, on the pull request's current head <H> against origin's own tip
# <B> of the default branch; with --record, step 6's gate record (reference/deploy-contract.md, rule 2, link 2). Each
# rule is checked as that page states it, and where the hand gate stops, this stops too: a fact it cannot establish
# (who wrote a record, a time order, a result) fails the rule or leaves it "cannot tell", and never passes it. This
# comment says only how the tool reads each rule.
#   - Records and markers are read by factory-release-check's own code, from beside this file, run only once its raw
#     bytes proved to be <B>'s copy (verified_checker; a mismatch refuses, exit 3, before any of it runs): Trust for what proves (the comment's first line, a User with write access, never edited), its loose
#     markers and contradicted() for what contradicts, carried_review() for a review carried over merges of the
#     default branch, and prove() for the gate chain of the default branch's tip.
#   - Who wrote a record is judged the same in both agent-token modes: mode off reads GitHub's comments and the
#     collaborator permission with gh; mode on reads the broker's pr-reviews (each item's author, author_type and
#     updated_at, checked and rebuilt by the broker) and its permission verb. An answer without those fields (an older
#     broker) is a failed read, never a comment that proves nothing. The tip's gate chain (rule 1 between nightlies)
#     is proved by the same prove() in both modes: mode off, its reads are gh's (GhReads); mode on, GateTipReads gives
#     it the broker's commit-pulls, commit-tree, commit-check-runs, commit-statuses, job-view and fetch, whose fields
#     the broker checks and rebuilds, and a failed read is the release checker's GhError, as gh's is in mode off.
#   - Rule 1: the base is the default branch and <B> (origin's tip by ls-remote, and the fetched ref) is an ancestor of
#     <H>. The default branch is green when the latest finished nightly (ci.nightly in <B>'s factory.yaml; the core's
#     factory-nightly.yml) passed on a commit, or skipped on a commit an earlier nightly passed on (nothing changed),
#     and that commit is <B> or only ci.skip_paths changed since (in agent-token mode on, the commit must be <B>
#     itself). Any other latest finished nightly (red, cancelled, unknown, or a skip it cannot back) is the default
#     branch red: the rule fails, and the tip's merge is not read (factory-lead › Default branch red; the fix for it
#     merges through the hand gate, merge-gate.md rule 1). Between
#     nightlies (none finished, ci.nightly empty, or a green one older than <B> with more than ci.skip_paths since, or
#     in mode on any older one: there the ci.skip_paths shortcut is not taken), it is green when <B>'s own merge proves
#     under factory-release-check's prove(): the gate record in force at its merge, the checks and evidence it relied
#     on and the review in force then, with nothing later contradicting them ("the latest merge's gate evidence on the
#     tip").
#     A nightly or a factory.yaml it cannot read leaves the rule "cannot tell".
#   - Rule 2: the required checks are verify and every commands.checks entry with gate not false whose `when` selects a
#     file of the pull request's own changed-file list, in <H>'s factory.yaml or in <B>'s (gate_required, as factory
#     verify reads them): a pull request that takes an entry out, narrows its `when` or sets `gate: false` is still
#     held to it, and one whose <H> no longer has the entry fails the rule (no evidence can name its command; such a
#     pull request is gated by hand). When <B>'s file cannot be used, <H>'s alone counts and rule 1 cannot tell. Every
#     entry of the pull request's checks is judged: pending or cancelled has not finished; a failure counts
#     as refused only on the page's signature (mode off: a job with no steps and no runner and an annotation saying it
#     was not started; mode on, the column of github-access.md: run-view lists the job with no steps), and any other
#     failure is red. A red or unfinished check fails the rule whatever the evidence. A required check that did not
#     pass in CI, and every check refused or skipped, required or not (step 6.2), need the evidence record for exactly
#     <H> and its tree. Evidence for that tree from another head (a batch gate) is refused: the records carry no batch
#     order, so the gate cannot check what voids a batch (merge-gate.md › The batch gate), and a batch merges by hand.
#     The evidence comment must hold, for each such check, factory verify's entry (evidence_line) for its exact command,
#     saying passed with 0 failed, and no other entry for it; factory verify <P> writes it for a check that is not
#     required (gate: false, or its `when` selects no changed file) too, when the checks show it refused or skipped
#     (merge-gate.md rule 2, Checks with gate: false). factory-ci.yml's jobs that run no command (its selector,
#     and its check job skipped with nothing to run) need none.
#   - ci.external (a project's own workflows; merge-gate.md rules 1 and 2): a listed job is a workflow name and a job
#     name, and a check or job is that job when its name is the job's, or the job's followed by " (" (a matrix variant).
#     Rule 1 reads the lists of <B>'s factory.yaml and of <H>'s (when it can be used: a pull request that adds an entry
#     is held to it too); rule 2 reads <H>'s and <B>'s (when <B>'s cannot be used, rule 1 cannot tell), so a pull
#     request that takes an entry out is still held to it, and one that changes the list is gated by hand.
#   - ci.external in rule 1: per listed workflow, its latest finished run on the default branch (board.md › CI on the
#     default branch; mode off: gh run list --workflow <name> --status completed and every page of the run's jobs; mode
#     on: run-list takes a file, not a name, so the latest GATE_EXT_RUNS runs on the branch, kept by workflowName, and
#     run-view). A listed job missing from that run, or a job of it with any conclusion but success, is red, except a
#     failure that job_refused shows refused (an answer it cannot read leaves the job red, board.md), a skip by the
#     job's own if: alone (external_own_if: the job has an if: in the workflow file at the run's head, and every job it
#     needs, directly or not, succeeded in that run) and a skip only because GitHub refused jobs it needs
#     (external_refused_needs: of every job it needs, directly or not, each one that did not succeed was refused,
#     job_refused, or was skipped while a job it needs did not succeed, and at least one was refused; a refusal there
#     that cannot be read, or a needs: chain the file does not resolve, a cycle included, is "cannot tell", and every
#     branch is read, so a red one wins whatever the order), which are not run and not red; cancelled, timed_out,
#     neutral and any other skip are red. A red one makes the default branch red whatever the nightly or the tip's merge says, so
#     these jobs are read first; a workflow with no finished run on the default branch, a run that cannot be read, or a
#     skip whose cause cannot be told makes rule 1 "cannot tell" unless something else is red: never green. Jobs the
#     list leaves out are not read. A red one's fix merges through the hand gate, as a red nightly's does (merge-gate.md
#     rule 1, The fix for a red ci.external job), and the reason says so.
#   - ci.external in rule 2: a check of a listed workflow never counts as verify or a commands.checks entry. A listed
#     workflow with any check on <H> ran there, and each listed job must have a check in it (else the list no longer
#     matches: the rule fails); its checks are judged like every other. A listed workflow with no check on <H> did not
#     start there. A listed job whose workflow did not start, or whose check was skipped or refused, needs the evidence
#     record for <H> to hold, for each step of the job in the workflow file at <H> (directly in GATE_WORKFLOWS, the
#     file whose name:, or path when it has none, is the listed workflow, read with factory doctor's YAML reader; the
#     job whose name:, or id when it has none, is the listed job), factory verify's entry shape (evidence_line) for
#     that step's exact `run:` with the label GATE_EXT_LABEL, passed with 0 failed: one entry per step, in the steps'
#     order and nothing else under the label (gate_job_entries), so evidence for part of a job never counts (factory
#     verify <P> writes these for each listed job the checks show needs one, verify_external). Evidence stands only for
#     a job whose every step it reproduces exactly (gate_job_commands, a strict subset: each step a `run:` in sh or
#     bash with no env: anywhere, no working directory, no expression and no other action; the one exemption is a
#     leading prefix of steps that are exactly actions/checkout pinned to a commit SHA, before the first run: step,
#     since the evidence runs in a checked-out tree; a checkout after it leaves the job uncovered). For any other job,
#     the rule fails and says why. covered_by: a listed job whose check GitHub refused (job_refused; never one that
#     failed, timed out or was cancelled, nor one skipped or whose workflow did not start) is covered instead by the
#     evidence record for <H> holding factory verify's entry (gate_covers) for every check covered_by names, when the
#     head's factory.yaml and <B>'s both list the job in entries that all give covered_by (gate_covered_by: the names
#     of both, so a pull request that adds or changes covered_by is never covered by its own list alone; <B>'s file
#     unusable means no covered_by). A job of a listed workflow that the list leaves out is not read by either rule:
#     one skipped on <H> needs no evidence. One refused there still fails the rule (step 6.2 needs evidence for it, and
#     no entry can name it), and one that ran and failed, is pending or was cancelled fails it as every other check
#     does (step 6.3; the release judges every check). A skipped check of a workflow no list names (not factory-ci.yml)
#     needs no evidence either when the workflow is one file directly in GATE_WORKFLOWS at <H> and the pull request's
#     changed files leave that file unchanged (unlisted_file); otherwise it needs evidence by its name, as every check
#     that did not run. A workflow file it cannot read, two files with the name, or a job name that is an expression
#     and may be the listed job, leave the rule "cannot tell" for a listed job that needs its steps.
#   - Rule 4: each issue the pull request closes in this repository is read for its "Acceptance contract" section
#     (gate_contract, a strict subset). When the words appear nowhere in its body, or exactly once, as one exact
#     "## Acceptance contract" heading whose section reads `none (<reason>)`, the rule is not applicable and says so;
#     any other spelling, place or count of the words, an empty section, several issues with a contract, or no closed
#     issue fail. With a contract, the latest trusted validation record (Trust, as reviews are read) must pass on <H>
#     itself (gate_validation: verdict=pass, failed=0, unchecked=0, passed=contract>=1, holdouts pass or none, counts
#     that add up), and every later loose validation marker must say the same. A validation never carries over to a new
#     head.
#   - Rule 5: neither the pull request nor an issue it closes in this repository (closingIssuesReferences) carries
#     agent:human or status:needs-human (human-gates.md › H1: a linked approval cannot be read here, so a person
#     decides), the latest review says human=0, and the description's one "Acceptance criteria" list (the core's pull
#     request template) has every task ticked, or unticked with a link to another open issue created after the pull
#     request was opened (gate_acceptance, gap_for_this_pr).
#   - Step 6, "Leave the records alone": a gate marker that counts as later than any record (in the description, or in
#     a comment without a readable time) fails the gate, since no gate record could stand.
#   - --record: the emergency stop is checked as its own subprocess first, and again right before the post. Before the
#     post, the pull request and origin's default tip are read again and every rule is judged again from fresh reads;
#     anything that moved, or a judgement that differs (another head, base or evidence, or a rule that no longer
#     passes), refuses. The record is the comment's first line; nothing after it, and nothing printed, reads as a
#     marker.
# Exit codes: 0 pass (and the record posted, with --record); 2 a rule fails; 1 a rule cannot be judged (a failed read)
# or the post failed; 3 refused (paused, the pull request is not open, something moved or changed before the post); 64
# bad usage.

GATE_RECORD = "<!-- factory:gate head=%s base=%s result=pass checks=%s evidence=%s -->"
GATE_PR_FIELDS = ("number,state,isDraft,headRefOid,headRefName,baseRefName,body,closingIssuesReferences,labels,"
                  "createdAt")
# Rule 5: an issue that holds the gap of an unticked criterion (gate_gap_issue): it counts when it was created after
# the pull request was opened (its body is not read: a reference in it can be hidden from the page in ways no reader
# here can follow, and an older issue that names the pull request is still not new).
GATE_GAP_FIELDS = "number,state,createdAt"
GATE_CHECK_FIELDS = "name,state,bucket,link,workflow"
GATE_BUCKETS = ("pass", "fail", "pending", "skipping", "cancel")
GATE_NIGHTLY = "factory-nightly.yml"    # the core's nightly workflow (templates/workflows), as factory-init names it
GATE_CI = "Factory CI"                   # factory-ci.yml's workflow name (core/templates/README.md › Fixed names)
GATE_SELECTOR = "select checks"          # factory-ci.yml's first job when verify is not in ci.pr: it runs no command
# factory-ci.yml's check job when no check is needed: skipped before its matrix expands, so GitHub names it by its job
# id (checks), by its unexpanded name (${{ matrix.check.name }}) or by that name's bare expression (matrix.check.name,
# what GitHub reports when ci.pr is just [verify]). Exempt only in Factory CI and only skipped: it runs no command, and
# no check may be named so (templates README › Fixed names).
GATE_EMPTY_MATRIX = ("checks", "${{ matrix.check.name }}", "matrix.check.name")
GATE_HUMAN = ("agent:human", "status:needs-human")      # human-gates.md › H1, on the pull request or on its issue
GATE_REVIEW_KEYS = {"reviews": ("submitted_at",), "inline": ("created_at", "updated_at"),
                    "conversation": ("created_at", "updated_at")}  # mode on: what pr-reviews gives beside the author
GATE_EXT_RUNS = 200                      # mode on: the runs on the default branch read to find a workflow's latest
GATE_EXT_LABEL = "ci.external %s / %s"   # the evidence label of a ci.external job's commands: workflow, job
GATE_WORKFLOWS = ".github/workflows"     # where Actions reads a repository's workflows (top level only)
GATE_CHECKOUT = re.compile(r"actions/checkout@[0-9a-f]{40}")   # the one action a job's evidence may skip (a prefix)
GATE_CHECKOUT_KEYS = {"name", "id", "uses"}   # all a step of that action may hold (no with:, env: or if:)
GATE_RUN_KEYS = {"name", "id", "run", "shell"}  # all a run: step may hold for its evidence to reproduce it
GATE_JOB_LINK = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/actions/runs/([1-9][0-9]{0,18})"
                           r"/job/([1-9][0-9]{0,18})")     # ids of up to 19 digits, as the broker takes them
GATE_NOT_STARTED = re.compile(r"\bjob was not started\b", re.IGNORECASE)
GATE_LOGIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}")
GATE_PAGES = 50
# The description's "Acceptance criteria" list (core/templates/pull_request_template.md). A strict subset: the heading
# is `#`..`######` or a bold line with exactly those words (an optional colon), at column 0; the list ends at the next
# heading at column 0 (a bold line ends it only after a blank line: right after a line, Markdown reads it as that
# line's continuation); HTML comments and fenced code are not read. A heading or a code fence indented inside the list,
# or a fence never closed, may hide criteria, so it refuses the list. Every task box in the list is a criterion, at any
# depth, and must read `- [ ] text` or `- [x] text` (also `*`, `+`, `X`; one space after the marker, so a task's text
# starts in column 2). Any other line is unreadable at the top level (no indentation, or a list item indented by less
# than 2 columns, which is a sibling of the tasks without a box) and is the explanation of the item above when indented
# further.
GATE_AC_HEADING = re.compile(r" {0,3}(?:#{1,6}[ \t]+acceptance criteria[ \t]*:?(?:[ \t]+#+)?|"
                             r"\*\*acceptance criteria:?\*\*:?)[ \t]*", re.IGNORECASE)
GATE_HEADING = re.compile(r" {0,3}(?:#{1,6}(?:[ \t]|$)|\*\*[^*]+\*\*:?[ \t]*$)")
GATE_TASK = re.compile(r"[-*+] \[([ xX])\][ \t]+(\S.*)")
GATE_BOXED = re.compile(r"(?:[-*+]|[0-9]{1,9}[.)])[ \t]+\[[^\]]?\](?:[ \t]|\Z)")
GATE_ITEM = re.compile(r"(?:[-*+]|[0-9]{1,9}[.)])(?:[ \t]|\Z)")
GATE_FENCE = re.compile(r" {0,3}(`{3,}|~{3,})")
GATE_ISSUE_REF = re.compile(r"(?<![\w/&#])#([1-9][0-9]{0,9})\b")
# Rule 4: an issue's "Acceptance contract" section (core/templates/ticket.md), read as a strict subset (gate_contract):
# only no section or `none (<reason>)` leaves the rule out, so a body the gate cannot read for sure fails it, since a
# false "unreadable" costs one rewording and a false "absent" skips validation.
# - The words. The whole body is normalised at once, across line breaks (gate_contract_views): HTML entities decoded
#   until none is left, the release checker's loose() view (look-alike letters folded, invisible characters dropped),
#   emphasis, code-span backticks, link brackets and backslashes removed, case folded, a letter whose Unicode name
#   ends in a Latin letter (a small capital) read as that letter, and every run of non-letters made one separator. It
#   is read eight ways: before and after decoding, each as it is, without HTML tags, without HTML comments (multiline
#   ones too), and without both (and link destinations). The body is "absent" only when none of them holds
#   "acceptance contract" (the words also run together, or inside longer words).
# - The heading. A section exists only when the words appear exactly once, on a raw line that is exactly the ticket
#   template's "## Acceptance contract" (trailing spaces allowed), outside a code fence, with nothing before it that
#   may make it code or HTML. Before it, a code fence counts only when it opens at column 0, and a code span only when
#   it pairs on its line within one table cell and no HTML is left on that line, both only up to the first raw HTML or
#   unpaired backtick; from there on, a line that may open or close a fence or a math block refuses the heading. Raw
#   HTML before it (entities decoded) refuses it as well, since where an element ends cannot be proved without an HTML
#   parser, except an autolink and an HTML comment closed before it by `-->`, with no `--!>` in it, that opens at
#   column 0 or closes on its own line.
# - Every other case is unreadable: rule 4 fails and says why. The section runs to the next `#` heading at column 0;
#   one line `none (<reason>)` with a reason, no HTML and no other line break in it reads none, anything else is a
#   contract.
GATE_CONTRACT_HEADING = re.compile(r"## Acceptance contract[ \t]*")      # the template's heading, on the raw line
GATE_CONTRACT_LINE = re.compile(r"\r\n|\r|\n")                           # CommonMark's line endings
GATE_CONTRACT_WORDS = re.compile(r"acceptance ?contract")                 # in gate_contract_views' normal form
GATE_CONTRACT_SEP = re.compile(r"[\W\d_]+")                              # a run of non-letters
GATE_CONTRACT_DROP = re.compile(r"[*_~`\\\[\]]")                         # emphasis, backticks, brackets, escapes
GATE_CONTRACT_LINK = re.compile(r"\]\([^()]*\)")                         # a link's destination, after its text
GATE_CONTRACT_COMMENT = re.compile(r"<!--.*?(?:-->|--!>|\Z)", re.DOTALL)   # an unclosed one runs to the end
GATE_CONTRACT_TAG = re.compile(r"<[A-Za-z/!?](?:[^<>\"']|\"[^\"]*\"|'[^']*')*>")   # quoted values may hold < and >
GATE_CONTRACT_OPEN = re.compile(r"(`{3,}|~{3,})(.*)")                    # a fence opener at column 0, and its info
GATE_CONTRACT_FENCY = re.compile(r"[ \t>*+0-9.)-]*(?:`{3}|~{3}|\$\$)")   # may open or close a fence or math block
GATE_CONTRACT_CODE = re.compile(r"(?<!`)(`+)(?!`)[^|]+?(?<!`)\1(?!`)")   # a code span on one line, in one cell
GATE_CONTRACT_HTML = re.compile(r"<[A-Za-z/!?]")                        # what HTML may read as markup
GATE_CONTRACT_AUTOLINK = re.compile(r"<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*>")
GATE_CONTRACT_LETTER = re.compile(r" LETTER (?:SMALL CAPITAL )?([A-Z])$")   # a Unicode name: a Latin letter
GATE_CONTRACT_DEPTH = 10                                                # rounds of entity decoding, at most
GATE_CONTRACT_END = re.compile(r"#{1,6}(?:[ \t]|$)")                     # the next `#` heading at column 0
GATE_CONTRACT_NONE = re.compile(r"(?:[-*+][ \t]+)?[`*_]*none[ \t]*\((.*)\)[`*_]*\.?", re.IGNORECASE)   # a reason
# The fields of a passing validation (validator.md › Comment format): the counts, then the rest.
GATE_VALIDATION_COUNTS = ("contract", "passed", "failed", "unchecked")


# The fields of GitHub's answers that the tip's gate chain reads (prove() and its reads, in both agent-token modes):
# a missing one is named, so the answer that broke the read can be found. Nothing else of an error is shown.
GATE_SHAPE_KEYS = frozenset(("app", "base", "body", "check_runs", "check_suite", "combined", "completed_at",
                             "conclusion", "context", "created_at", "head", "history", "id", "login", "merge_commit_sha",
                             "merged_at", "number", "ref", "runner", "runner_id", "runner_name", "sha", "slug",
                             "started_at", "state", "status", "statuses", "steps", "total_count", "tree", "type",
                             "updated_at", "user"))


def gate_shape_error(e):
    """What may be said of an error that an answer of an unexpected shape caused: its kind alone, never its text, which
    can hold the answer's own content; for a KeyError, also the key when it is one of GATE_SHAPE_KEYS."""
    kind = type(e).__name__
    if isinstance(e, KeyError) and len(e.args) == 1 and isinstance(e.args[0], str) and e.args[0] in GATE_SHAPE_KEYS:
        return "%s: '%s'" % (kind, e.args[0])
    return kind


class GateUnknown(Exception):
    """A rule cannot be judged: its input is missing or unreadable. Counts as not passed."""


class GateTipReads:
    """factory-release-check's GhReads in agent-token mode on (reference/github-access.md, the broker's column): the
    same reads of the default branch's tip for prove(), through the broker's verbs, which check and rebuild every
    field. A failed read is the release checker's GhError, as a failed gh read is in mode off, so prove() treats it
    the same way in both modes (a job that cannot be read is not shown never started; anything else cannot tell). The
    `repo` each method is given is not used: the broker reads the repository it registered for the checkout."""

    def __init__(self, github, rc, keep):
        self.github, self.rc, self.keep = github, rc, keep
        self._statuses = {}

    def _read(self, on, what, shape):
        try:
            data = self.github._json([], on, what)
        except GitHubError as e:
            raise self.rc.GhError(0, str(e))
        if not isinstance(data, shape):
            raise self.rc.GhError(0, "%s: the answer has an unexpected shape" % what)
        return data

    def commit_tree(self, repo, sha):
        data = self._read(["commit-tree", sha], "reading the tree of %s" % sha[:12], dict)
        if data.get("sha") != sha or not isinstance(data.get("tree"), str) or not SHA.fullmatch(data["tree"]):
            raise self.rc.GhError(0, "reading the tree of %s: the answer is not that commit's tree" % sha[:12])
        return data["tree"]

    def check_runs(self, repo, sha):
        what = "reading the check runs on %s" % sha[:12]
        data = self._read(["commit-check-runs", sha], what, dict)
        runs, total = data.get("check_runs"), data.get("total_count")
        if not isinstance(runs, list) or not all(isinstance(r, dict) for r in runs) or not _int(total):
            raise self.rc.GhError(0, "%s: the answer has an unexpected shape" % what)
        if len(runs) < total:
            raise self.rc.Unverifiable("%s: the answer lists %d of the %d check runs" % (what, len(runs), total))
        return runs

    def job_ran(self, repo, job):
        data = self._read(["job-view", str(job)], "reading job %s" % job, dict)
        if str(data.get("id")) != str(job) or not _int(data.get("steps")) or not isinstance(data.get("runner"), bool):
            raise self.rc.GhError(0, "reading job %s: the answer is not that job" % job)
        return data["steps"] > 0 or data["runner"]

    def _commit_statuses(self, sha):
        """The broker's commit-statuses for `sha`, read once for both of prove()'s status reads."""
        if sha not in self._statuses:
            what = "reading the commit statuses of %s" % sha[:12]
            data = self._read(["commit-statuses", sha], what, dict)
            history, combined = data.get("history"), data.get("combined")
            statuses = combined.get("statuses") if isinstance(combined, dict) else None
            if not isinstance(history, list) or not all(isinstance(x, dict) for x in history) or \
                    not isinstance(statuses, list) or not all(isinstance(x, dict) for x in statuses) or \
                    not _int(combined.get("total_count")):
                raise self.rc.GhError(0, "%s: the answer has an unexpected shape" % what)
            if len(statuses) < combined["total_count"]:
                raise self.rc.Unverifiable("%s: the answer lists %d of the %d statuses" % (
                    what, len(statuses), combined["total_count"]))
            self._statuses[sha] = (history, combined, statuses)
        return self._statuses[sha]

    def status_history(self, repo, sha):
        return self._commit_statuses(sha)[0]

    def combined_status(self, repo, sha):
        _, combined, statuses = self._commit_statuses(sha)
        return combined, statuses

    def fetch_pull_head(self, remote, number, head):
        """As the release checker's fetch_pull_head: True only when `head` is in the clone afterwards. Through the
        broker's fetch, which brings pull request `number`'s head as origin/pr/<number> (and keeps the gated pull
        request's, `keep`); a fetch that fails proves nothing."""
        if self.rc.has_commit(head):
            return True
        prs = [str(n) for n in dict.fromkeys((self.keep, number))]
        try:
            self.github._run([], ["fetch"] + [x for n in prs for x in ("--pr", n)],
                             "fetching pull request #%s" % number)
        except GitHubError:
            return False
        return self.rc.has_commit(head)


def gate_checker(source=None):
    """factory-release-check's module, loaded by load_checker() (from `source` when given): the one parser of records
    and markers, their trust and time order, the review carry-over and the proof of a merge."""
    mod = load_checker(source)
    for name in ("Trust", "contradicted", "carried_review", "prove", "has_commit", "escape", "FULL_SHA", "COUNT",
                 "FOREVER", "LINE_BREAK", "WRITE_PERMISSIONS", "WRITE_ROLES", "Unverifiable", "GhError", "GhReads"):
        if not hasattr(mod, name):
            raise Stop("factory-release-check next to factory lacks %s, which the gate reads records with; restore the "
                       "core files with factory update" % name)
    if "validation" not in (getattr(mod, "RECORD_KEYS", None) or {}):
        raise Stop("factory-release-check next to factory does not know the validation record, which rule 4 reads; "
                   "restore the core files with factory update")
    return mod


def verified_checker(root, base, default, done, path=CHECKER_PATH):
    """The gate's checker module, run only after its bytes proved to be the default branch's own: the raw bytes next
    to this file (or, when this run already loaded the checker, the bytes it ran from) are compared byte for byte with
    the blob at `path` (CHECKER_PATH) in <base>, read from git, and only those verified bytes are compiled and run. Otherwise a
    refusal (exit 3) with `done` (what was not done), before any of the checker runs. The gate and factory markers judge
    records with the default branch's checker (merge-gate.md step 6, "Which checker judges"); run from another checkout
    (a pull request's worktree, a home that is behind), the checker beside the tool may read records otherwise, or not
    load at all. Replace refs are not followed: they could show other bytes for <base>'s copy."""
    listing = git(root, "--no-replace-objects", "ls-tree", "-z", base, "--", path, raw=True,
                  what="%s at %s cannot be read" % (default, base[:12]))
    m = re.fullmatch(rb"(100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64})\t[^\0]*\0", listing)
    if not listing:
        why = "%s at %s has no %s to compare the release checker beside this tool with" % (default, base[:12], path)
    elif not m:
        why = "%s at %s holds %s as something other than one regular file" % (default, base[:12], path)
    else:
        theirs = git(root, "--no-replace-objects", "cat-file", "blob", m.group(2).decode(), raw=True,
                     what="%s's %s cannot be read" % (default, path))
        mine = _checker_source[0] if _checker else checker_bytes()
        if mine == theirs:
            return gate_checker(mine)
        why = ("the release checker beside this tool (%s) is not %s's copy at %s (%s), so none of it was run: run the "
               "tool from your home checkout of %s, up to date with origin (merge-gate.md step 6, Which checker "
               "judges)" % (os.path.join(HERE, "factory-release-check"), default, base[:12], path, default))
    raise Stop("refused: %s; %s" % (why, done), 3)


class GateGitHub(GitHub):
    """The gate's reads, in both columns of reference/github-access.md (Pull requests, Workflow runs, Issues)."""

    def __init__(self, project):
        GitHub.__init__(self, project)
        self._writers = {}

    def forget(self):
        """Drop what this run remembered (repository permissions), so a second judgement reads everything again."""
        self._writers = {}

    def _attempt(self, off, on, what):
        """(exit code, stdout, stderr) of one step whose exit code means more than failed or not."""
        argv = off if self.mode == "off" else [self.broker] + on
        tool = argv[0] if self.mode == "off" else "factory-github"
        try:
            p = subprocess.run(argv, cwd=self.project.root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=GH_TIMEOUT)
        except FileNotFoundError:
            raise GitHubError("%s: %s is not installed" % (what, tool))
        except (OSError, subprocess.SubprocessError):
            raise GitHubError("%s: the command did not finish" % what)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

    def _api(self, path, what):
        """One `gh api` GET; mode off only (mode on has a verb for every read the gate makes in that mode)."""
        return self._json(self._gh("api", "-H", "Accept: application/vnd.github+json", path), [], what)

    def _api_pages(self, path, what):
        items = []
        for page in range(1, GATE_PAGES + 1):
            batch = self._api("%s?per_page=100&page=%d" % (path, page), what)
            if not isinstance(batch, list) or not all(isinstance(x, dict) for x in batch):
                raise GitHubError("%s: the answer is not a list" % what)
            items += batch
            if len(batch) < 100:
                return items
        raise GitHubError("%s: more than %d pages, which cannot be read whole" % (what, GATE_PAGES))

    def gate_pr(self, n):
        """number, state, draft, head, branch, base, body, labels, and `closes`: the issues of this repository it
        closes."""
        what = "reading pull request #%d" % n
        data = self._json(self._gh("pr", "view", str(n), "-R", self.repo or "", "--json", GATE_PR_FIELDS),
                          ["pr-view", str(n)], what)
        if not isinstance(data, dict) or data.get("number") != n:
            raise GitHubError("%s: the answer is not that pull request" % what)
        state, head, draft, body = data.get("state"), data.get("headRefOid"), data.get("isDraft"), data.get("body")
        if not isinstance(state, str) or state.upper() not in ("OPEN", "CLOSED", "MERGED"):
            raise GitHubError("%s: no open, closed or merged state in the answer" % what)
        if not isinstance(head, str) or not SHA.fullmatch(head):
            raise GitHubError("%s: the head is not a full commit SHA" % what)
        if not isinstance(draft, bool):
            raise GitHubError("%s: isDraft is not true or false" % what)
        if body is not None and not isinstance(body, str):
            raise GitHubError("%s: the description is not text" % what)
        if not isinstance(data.get("labels"), list):
            raise GitHubError("%s: the answer has no list of labels" % what)
        labels = _labels(data)
        for key in ("baseRefName", "headRefName"):
            if not branch_name(data.get(key)):
                raise GitHubError("%s: %s is not a branch name" % (what, key))
        refs = data.get("closingIssuesReferences")
        if not isinstance(refs, list):
            raise GitHubError("%s: closingIssuesReferences is not a list" % what)
        here, closes = self.project.repo().lower(), []
        for ref in refs:
            if not isinstance(ref, dict) or not _int(ref.get("number")):
                raise GitHubError("%s: a closing issue reference has an unexpected shape" % what)
            m = ISSUE_URL.fullmatch(ref.get("url") or "")
            if m:
                where = "%s/%s" % (m.group(1), m.group(2))
            else:
                repo = ref.get("repository") if isinstance(ref.get("repository"), dict) else {}
                own = repo.get("owner") if isinstance(repo.get("owner"), dict) else {}
                if not isinstance(repo.get("name"), str) or not isinstance(own.get("login"), str):
                    raise GitHubError("%s: a closing issue reference names no repository" % what)
                where = "%s/%s" % (own["login"], repo["name"])
            if where.lower() == here and ref["number"] not in closes:
                closes.append(ref["number"])
        created = data.get("createdAt")
        return {"number": n, "state": state.upper(), "draft": draft, "head": head, "branch": data["headRefName"],
                "base": data["baseRefName"], "body": body or "", "labels": labels, "closes": closes,
                "created": created if isinstance(created, str) else None}

    def gate_gap_issue(self, n):
        """Rule 5: an issue an unticked criterion links: state and created (createdAt as given, None when the answer has
        none)."""
        what = "reading issue #%d" % n
        data = self._json(self._gh("issue", "view", str(n), "-R", self.repo or "", "--json", GATE_GAP_FIELDS),
                          ["issue-view", str(n)], what)
        issue = _issue(data)
        if issue["number"] != n:
            raise GitHubError("%s gave issue #%d" % (what, issue["number"]))
        created = data.get("createdAt")
        return {"number": n, "state": issue["state"],
                "created": created if isinstance(created, str) else None}

    def open_prs(self):
        """The numbers of the open pull requests, lowest first (factory markers). PR_LIMIT or more is refused: the list
        is never read in part."""
        what = "reading the open pull requests"
        data = self._json(self._gh("pr", "list", "-R", self.repo or "", "--state", "open", "--limit", str(PR_LIMIT),
                                   "--json", "number"), ["pr-list", "--state", "open", "--limit", str(PR_LIMIT)], what)
        if not isinstance(data, list) or not all(isinstance(p, dict) and _int(p.get("number")) for p in data):
            raise GitHubError("%s: the answer is not a list of pull requests" % what)
        if len(data) >= PR_LIMIT:
            raise GitHubError("%s: %d or more, which cannot be read whole" % (what, PR_LIMIT))
        return sorted({p["number"] for p in data})

    def pr_checks(self, n):
        """Every check run and commit status on the pull request's head, as `gh pr checks` lists them: name, bucket,
        state (upper case), link and workflow. No checks at all is an empty list in mode off (gh says "no checks
        reported")."""
        what = "reading the checks of pull request #%d" % n
        code, out, err = self._attempt(self._gh("pr", "checks", str(n), "-R", self.repo or "", "--json",
                                                GATE_CHECK_FIELDS), ["pr-checks", str(n)], what)
        if self.mode == "off" and code == 1 and "no checks reported" in err:
            return []
        if code != 0 and not (self.mode == "off" and code == 8):     # gh exits 8 while checks are pending
            raise GitHubError("%s failed (exit %d: %s)" % (what, code, short(err)))
        try:
            data = json.loads(out)
        except ValueError:
            raise GitHubError("%s: the answer is not JSON" % what)
        if not isinstance(data, list):
            raise GitHubError("%s: the answer is not a list" % what)
        entries = []
        for e in data:
            if not isinstance(e, dict) or not isinstance(e.get("name"), str) or e.get("bucket") not in GATE_BUCKETS \
                    or not isinstance(e.get("state"), str):
                raise GitHubError("%s: a check has an unexpected shape" % what)
            link, workflow = e.get("link"), e.get("workflow")
            entries.append({"name": e["name"], "bucket": e["bucket"], "state": e["state"].upper(),
                            "link": link if isinstance(link, str) else "",
                            "workflow": workflow if isinstance(workflow, str) else ""})
        return entries

    def job_refused(self, link):
        """(True, why) when the job behind a failed check is one GitHub Actions refused to start, on merge-gate.md
        rule 2's signature; (False, why) otherwise: when unsure, it is red."""
        m = GATE_JOB_LINK.fullmatch(link)
        if not m or m.group(1).lower() != self.project.repo().lower():
            return False, "not a job of this repository's Actions, so it cannot be shown refused"
        run, job = m.group(2), m.group(3)
        if self.mode == "off":
            data = self._api("repos/%s/actions/jobs/%s" % (self.repo, job), "reading job %s" % job)
            if not isinstance(data, dict) or not isinstance(data.get("steps"), list):
                raise GitHubError("reading job %s: the answer has no list of steps" % job)
            if data["steps"] or data.get("runner_name") or data.get("runner_id"):
                return False, "job %s ran: it has steps or a runner" % job
            notes = self._api_pages("repos/%s/check-runs/%s/annotations" % (self.repo, job),
                                    "reading the annotations of job %s" % job)
            if any(isinstance(a.get("message"), str) and GATE_NOT_STARTED.search(a["message"]) for a in notes):
                return True, "job %s has no steps, no runner and an annotation saying it was not started" % job
            return False, "job %s has no steps and no runner, but no annotation says it was not started" % job
        data = self._json([], ["run-view", run], "reading workflow run %s" % run)
        jobs = data.get("jobs") if isinstance(data, dict) else None
        if not isinstance(jobs, list):
            raise GitHubError("reading workflow run %s: the answer has no list of jobs" % run)
        for j in jobs:
            if isinstance(j, dict) and str(j.get("databaseId")) == job:
                steps = j.get("steps")
                if isinstance(steps, list) and not steps and str(j.get("conclusion")).lower() == "failure":
                    return True, "job %s has no steps (run-view)" % job
                return False, "job %s ran: run-view lists its steps" % job
        return False, "run-view of run %s does not list job %s" % (run, job)

    def conversation(self, n, body):
        """(comments, others) of a pull request, shaped as factory-release-check reads them: the conversation's
        comments, where records live, and the formal reviews, inline review comments and the description (`body`,
        unless None), where only contradicting markers can sit. The description has no time: a marker in it always
        counts as later. Mode on: pr-reviews gives the same in fixed fields (author, author_type, the times; a formal
        review's only time is its submission, as in mode off), and every item must carry them: an older broker's
        answer, without them, is a failed read."""
        what = "reading the comments of pull request #%d" % n
        # `where` names the place for factory markers; the release checker's code reads no such key.
        others = [] if body is None else [{"body": body, "user": {"type": "User"}, "where": "the description"}]
        if self.mode == "off":
            comments = self._api_pages("repos/%s/issues/%d/comments" % (self.repo, n), what)
            for r in self._api_pages("repos/%s/pulls/%d/reviews" % (self.repo, n), what):
                others.append({"body": r.get("body"), "user": r.get("user"), "created_at": r.get("submitted_at"),
                               "updated_at": r.get("submitted_at"), "where": "formal review %s" % _where_id(r)})
            for c in self._api_pages("repos/%s/pulls/%d/comments" % (self.repo, n), what):
                others.append({"body": c.get("body"), "user": c.get("user"), "created_at": c.get("created_at"),
                               "updated_at": c.get("updated_at"), "where": "inline review comment %s" % _where_id(c)})
            return comments, others
        data = self._json([], ["pr-reviews", str(n)], what)
        if not isinstance(data, dict) or not all(isinstance(data.get(k), list) and
                                                 all(isinstance(x, dict) for x in data[k])
                                                 for k in GATE_REVIEW_KEYS):
            raise GitHubError("%s: the answer has an unexpected shape" % what)
        for kind, keys in GATE_REVIEW_KEYS.items():
            if not all(k in x for x in data[kind] for k in ("id", "body", "author", "author_type") + keys):
                raise GitHubError("%s: the broker's pr-reviews gives no account type or edit time (an older broker); "
                                  "install the current factory-github" % what)

        def item(c, created, updated, where=None):
            x = {"id": c["id"], "body": c["body"], "user": {"login": c["author"], "type": c["author_type"]},
                 "created_at": c[created], "updated_at": c[updated]}
            if where:
                x["where"] = "%s %s" % (where, _where_id(c))
            return x
        comments = [item(c, "created_at", "updated_at") for c in data["conversation"]]
        others += [item(r, "submitted_at", "submitted_at", "formal review") for r in data["reviews"]]
        others += [item(c, "created_at", "updated_at", "inline review comment") for c in data["inline"]]
        return comments, others

    def writer(self, login):
        """Whether `login` has write, maintain or admin permission on the repository now (the release checker's rule).
        Not a collaborator (404; the broker's permission says none) is False; any other failed lookup is an error."""
        if not isinstance(login, str) or not GATE_LOGIN.fullmatch(login):
            return False
        if login not in self._writers:
            what = "reading the repository permission of %s" % login
            code, out, err = self._attempt(self._gh("api", "repos/%s/collaborators/%s/permission" % (self.repo, login)),
                                           ["permission", login], what)
            if code != 0 and self.mode == "off" and "HTTP 404" in err:
                answer = {}
            elif code != 0:
                raise GitHubError("%s failed (%s)" % (what, short(err)))
            else:
                try:
                    answer = json.loads(out)
                except ValueError:
                    raise GitHubError("%s: the answer is not JSON" % what)
            if self.mode != "off" and (not isinstance(answer, dict) or answer.get("login") != login):
                raise GitHubError("%s: the broker's answer is not that login's permission" % what)
            rc = _checker[0]
            answer = answer if isinstance(answer, dict) else {}
            self._writers[login] = (answer.get("permission") in rc.WRITE_PERMISSIONS
                                    or answer.get("role_name") in rc.WRITE_ROLES)
        return self._writers[login]

    def merged_as(self, sha, branch):
        """The pull requests merged into `branch` as exactly `sha`, as GitHub's REST API gives them (what
        factory-release-check's prove() reads). Mode on: the broker's commit-pulls, the same fields checked and
        rebuilt."""
        what = "reading the pull request merged as %s" % sha[:12]
        if self.mode == "off":
            pulls = self._api_pages("repos/%s/commits/%s/pulls" % (self.repo, sha), what)
        else:
            pulls = self._json([], ["commit-pulls", sha], what)
            if not isinstance(pulls, list) or not all(isinstance(p, dict) for p in pulls):
                raise GitHubError("%s: the answer is not a list" % what)
        found = []
        for p in pulls:
            head = (p.get("head") or {}).get("sha") if isinstance(p.get("head"), dict) else None
            if p.get("merged_at") and p.get("merge_commit_sha") == sha and _int(p.get("number")) and \
                    isinstance(p.get("base"), dict) and p["base"].get("ref") == branch and \
                    isinstance(head, str) and SHA.fullmatch(head):
                found.append(p)
        return found

    def tip_reads(self, rc, keep):
        """What prove() reads GitHub with: None in mode off (its own GhReads, plain gh); mode on, GateTipReads, which
        keeps the fetched head of pull request `keep` (the one being gated) when it fetches."""
        return None if self.mode == "off" else GateTipReads(self, rc, keep)

    def nightly_runs(self, branch):
        """The latest runs of the core's nightly workflow on `branch`, newest first: id, status, conclusion, head."""
        what = "reading the nightly runs on %s" % branch
        data = self._json(self._gh("run", "list", "-R", self.repo or "", "--workflow", GATE_NIGHTLY, "--branch",
                                   branch, "--limit", "20", "--json", "databaseId,status,conclusion,headSha"),
                          ["run-list", "--workflow", GATE_NIGHTLY, "--branch", branch, "--limit", "20"], what)
        if not isinstance(data, list):
            raise GitHubError("%s: the answer is not a list" % what)
        runs = []
        for r in data:
            if not isinstance(r, dict) or not _int(r.get("databaseId")) or not isinstance(r.get("status"), str) or \
                    not isinstance(r.get("headSha"), str) or not SHA.fullmatch(r["headSha"]):
                raise GitHubError("%s: a run has an unexpected shape" % what)
            runs.append({"id": r["databaseId"], "status": r["status"].lower(), "head": r["headSha"],
                         "conclusion": str(r.get("conclusion") or "").lower()})
        return runs

    def external_run(self, workflow, branch):
        """The latest finished run (id, head, conclusion) of the workflow named `workflow` on `branch`, or None when it
        has none (board.md › CI on the default branch). Mode on: run-list takes a workflow file, not a name, so the
        latest GATE_EXT_RUNS runs on the branch are read and kept by their workflowName; when none of a full list is a
        finished run of it, its latest one cannot be found."""
        what = "reading the latest finished run of %s on %s" % (_checker[0].escape(workflow), branch)
        data = self._json(self._gh("run", "list", "-R", self.repo or "", "--workflow", workflow, "--branch", branch,
                                   "--status", "completed", "--limit", "1", "--json",
                                   "databaseId,status,conclusion,headSha,workflowName"),
                          ["run-list", "--branch", branch, "--limit", str(GATE_EXT_RUNS)], what)
        if not isinstance(data, list):
            raise GitHubError("%s: the answer is not a list" % what)
        for r in data:
            if not isinstance(r, dict) or not _int(r.get("databaseId")) or not isinstance(r.get("status"), str) or \
                    not isinstance(r.get("headSha"), str) or not SHA.fullmatch(r["headSha"]) or \
                    not isinstance(r.get("workflowName"), str):
                raise GitHubError("%s: a run has an unexpected shape" % what)
            if r["workflowName"] == workflow and r["status"].lower() == "completed":
                return {"id": r["databaseId"], "head": r["headSha"], "conclusion": str(r.get("conclusion") or "").lower()}
            if self.mode == "off":
                raise GitHubError("%s: gh gave a run that is not a finished run of that workflow" % what)
        if self.mode != "off" and len(data) >= GATE_EXT_RUNS:
            raise GitHubError("%s: none of the latest %d runs on %s is a finished run of it" % (what, GATE_EXT_RUNS,
                                                                                               branch))
        return None

    def run_jobs(self, run):
        """Every job of workflow run `run` (its latest attempt), every page: id, name and conclusion."""
        what = "reading the jobs of workflow run %d" % run
        jobs = []
        if self.mode == "off":
            for page in range(1, GATE_PAGES + 1):
                data = self._api("repos/%s/actions/runs/%d/jobs?per_page=100&page=%d" % (self.repo, run, page), what)
                batch = data.get("jobs") if isinstance(data, dict) else None
                if not isinstance(batch, list) or not _int(data.get("total_count")):
                    raise GitHubError("%s: the answer has no list of jobs and their count" % what)
                jobs += batch
                if len(batch) < 100:
                    break
            else:
                raise GitHubError("%s: more than %d pages, which cannot be read whole" % (what, GATE_PAGES))
            if len(jobs) != data["total_count"]:
                raise GitHubError("%s: %d jobs read, but the run counts %d" % (what, len(jobs), data["total_count"]))
            key = "id"
        else:
            data = self._json([], ["run-view", str(run)], what)
            jobs = data.get("jobs") if isinstance(data, dict) else None
            if not isinstance(jobs, list):
                raise GitHubError("%s: the answer has no list of jobs" % what)
            key = "databaseId"
        out = []
        for j in jobs:
            if not isinstance(j, dict) or not _int(j.get(key)) or not isinstance(j.get("name"), str):
                raise GitHubError("%s: a job has an unexpected shape" % what)
            out.append({"id": j[key], "name": j["name"], "conclusion": str(j.get("conclusion") or "").lower()})
        return out


def gate_args(args, usage):
    n, record = None, False
    for a in args:
        if a in ("-h", "--help"):
            say(usage)
            raise Stop("", 0)
        if a == "--record" and not record:
            record = True
        elif n is None and re.fullmatch(r"#?[1-9][0-9]{0,9}", a):
            n = int(a.lstrip("#"))
        else:
            raise Stop("unknown argument (not shown); usage: %s" % usage, 64)
    if n is None:
        raise Stop("give one pull request number; usage: %s" % usage, 64)
    return n, record


def gate_config(root, commit):
    """factory.yaml as it is at `commit`, after factory-doctor's check of the whole file (verify_config's rule: a file
    it fails is never used): verify, each check's run, when, gate and heavy (with the core's entry defaults), ci.nightly
    and ci.skip_paths, and ci.external as the file has it (the empty list when it has none)."""
    p = subprocess.run(["git", "cat-file", "blob", "%s:factory.yaml" % commit], cwd=root, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
    if p.returncode != 0:
        raise GateUnknown("%s has no factory.yaml" % commit[:12])
    defaults = core_defaults()
    folder = _private_temp()
    try:
        with open(os.path.join(folder, "factory.yaml"), "wb") as f:
            f.write(p.stdout)
        del _doctor.OUT[:]
        doc = _doctor.check_factory_yaml(folder, defaults)
        failed = any(ln.startswith("R\tfactory.yaml\tfail\t") for ln in _doctor.OUT)
        del _doctor.OUT[:]
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    if not isinstance(doc, dict) or failed:
        raise GateUnknown("the factory.yaml of %s does not pass factory doctor's check (run factory doctor on that "
                          "commit)" % commit[:12])
    commands = doc["commands"]
    entry = (defaults.get("entry_defaults") or {}).get("commands.checks.<name>") or {}
    checks = {}
    for name, c in (commands.get("checks") or {}).items():
        full = dict(entry, **c)
        checks[name] = {"run": full["run"], "when": full.get("when"), "gate": full.get("gate") is not False,
                        "heavy": full.get("heavy") is True}
    ci = doc.get("ci") if isinstance(doc.get("ci"), dict) else {}
    return {"verify": commands["verify"], "checks": checks, "nightly": list(ci.get("nightly") or []),
            "skip_paths": list(ci.get("skip_paths") or []), "external": ci.get("external", [])}


def gate_ancestor(root, older, newer):
    """True when `older` is an ancestor of (or is) `newer`, False when not; GateUnknown when git cannot tell."""
    try:
        code = subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], cwd=root, stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60).returncode
    except (OSError, subprocess.SubprocessError):
        code = -1
    if code not in (0, 1):
        raise GateUnknown("git cannot tell whether %s is an ancestor of %s" % (older[:12], newer[:12]))
    return code == 0


def gate_acceptance(body):
    """([(ticked, text)], None) from the description's one "Acceptance criteria" list, or (None, why not)."""
    text = re.sub(r"<!--.*?-->", "", body or "", flags=re.DOTALL)
    sections, current, fence, after_blank = [], None, None, True
    hides = "so it may belong to an item and hide the criteria after it"
    for ln in re.split(r"\r\n|\r|\n", text):
        m = GATE_FENCE.match(ln)
        lead = len(ln) - len(ln.lstrip(" "))
        if fence:
            marker, indented, listed = fence
            if m and m.group(1)[0] == marker[0] and len(m.group(1)) >= len(marker) and not ln.strip()[len(m.group(1)):]:
                fence, after_blank = None, False
                continue
            if not (indented and ln.strip() and not ln[:1].isspace()):
                continue
            fence = None                   # an indented fence sits in a list item, which a line at column 0 ends
        if m:
            if current is not None and lead:
                return None, "a code fence in the \"Acceptance criteria\" list is indented, %s" % hides
            fence = (m.group(1), lead > 0, current is not None)
            continue
        if GATE_AC_HEADING.fullmatch(ln):
            if lead:
                return None, ("the \"Acceptance criteria\" heading is indented, so it may belong to a list item rather "
                              "than start the list")
            current = []
            sections.append(current)
        elif current is not None and GATE_HEADING.match(ln):
            if lead:
                return None, "a heading in the \"Acceptance criteria\" list is indented, %s: %s" % (
                    hides, _quote(ln.strip()))
            if ln.startswith("**") and not after_blank:
                return None, ("a bold line right after a line of the \"Acceptance criteria\" list continues that line "
                              "in Markdown, so it does not end the list: put a blank line before it, or use a heading")
            current = None                 # a heading at column 0 ends the list
        elif current is not None:
            current.append(ln)
        after_blank = not ln.strip()
    if fence and fence[2]:
        return None, ("a code fence in the \"Acceptance criteria\" list is never closed, so it hides the rest of the "
                      "list")
    if not sections:
        return None, "the description has no \"Acceptance criteria\" list (the pull request template's heading)"
    if len(sections) > 1:
        return None, "the description has several \"Acceptance criteria\" lists"
    items = []
    for ln in sections[0]:
        flat = ln.expandtabs(4).rstrip()
        line = flat.lstrip(" ")
        indent = len(flat) - len(line)
        if not line:
            continue
        if GATE_BOXED.match(line):         # a task box: a criterion, nested or not
            m = GATE_TASK.fullmatch(line)
            if not m:
                return None, "a task of the \"Acceptance criteria\" list is not \"- [ ] ...\" or \"- [x] ...\": %s" % \
                    _quote(line)
            items.append((m.group(1) != " ", m.group(2).strip()))
        elif indent == 0 or (indent < 2 and GATE_ITEM.match(line)):
            return None, "a line of the \"Acceptance criteria\" list is not \"- [ ] ...\" or \"- [x] ...\": %s" % \
                _quote(line)
        # anything else is indented under the item above: its explanation
    if not items:
        return None, "the \"Acceptance criteria\" list has no item"
    return items, None


def gate_contract_views(text, loose):
    """The normal forms of `text` that rule 4 looks for the words in, with GATE_CONTRACT_WORDS (the comment above
    GATE_CONTRACT_HEADING says which), or None when its HTML entities still decode after GATE_CONTRACT_DEPTH rounds."""
    plain = decoded = loose(text)
    for _ in range(GATE_CONTRACT_DEPTH):
        again = loose(html.unescape(decoded))
        if again == decoded:
            break
        decoded = again
    else:
        return None
    views = []
    for v in (plain, decoded):
        bare = GATE_CONTRACT_COMMENT.sub("", v)
        views += [v, GATE_CONTRACT_TAG.sub("", v), bare, GATE_CONTRACT_LINK.sub("", GATE_CONTRACT_TAG.sub("", bare))]
    views = [GATE_CONTRACT_DROP.sub("", v).casefold() for v in views]
    fold = {}
    for ch in set("".join(views)):
        m = GATE_CONTRACT_LETTER.search(unicodedata.name(ch, "")) if ord(ch) > 127 and ch.isalpha() else None
        if m:
            fold[ord(ch)] = m.group(1).lower()
    return [GATE_CONTRACT_SEP.sub(" ", v.translate(fold)) for v in views]


def gate_contract_html(text):
    """Whether `text` (one line, or part of one) holds anything HTML may read as markup, its entities decoded: a tag,
    a comment, a declaration or an instruction, but not an autolink. Entities that still decode after
    GATE_CONTRACT_DEPTH rounds count as markup."""
    for _ in range(GATE_CONTRACT_DEPTH):
        again = html.unescape(text)
        if again == text:
            return bool(GATE_CONTRACT_HTML.search(GATE_CONTRACT_AUTOLINK.sub("", text)))
        text = again
    return True


def gate_contract_markup(lines):
    """(index, what) of the first raw HTML in `lines`, the raw lines before the heading from the first that held raw
    HTML or an unpaired backtick, that the heading after them may sit in; None when there is none. Only an HTML
    comment closed by `-->` before the heading, with no `--!>` in it (a browser ends a comment there, and CommonMark
    does not), that opens at column 0 or closes on its own line (an inline one cannot run across blocks), is left out;
    everything else that gate_contract_html reads as markup counts."""
    text = "\n".join(lines)
    at = 0
    while True:
        start = text.find("<!--", at)
        for k, part in enumerate((text[at:] if start < 0 else text[at:start]).split("\n")):
            if gate_contract_html(part):
                return text.count("\n", 0, at) + k, "raw HTML"
        if start < 0:
            return None
        end = text.find("-->", start + 2)               # from the opener's dashes: `<!-->` and `<!--->` are closed
        if end < 0 or "--!>" in text[start:end + 3] or (start and text[start - 1] != "\n" and "\n" in text[start:end]):
            return text.count("\n", 0, start), "an HTML comment the gate cannot prove closed"
        at = end + 3


def gate_contract(body, loose):
    """(kind, detail) of an issue's acceptance contract for rule 4, read as the strict subset the comment above
    GATE_CONTRACT_HEADING sets out: ("absent", None) when the words are nowhere in its body, in any of
    gate_contract_views; ("none", reason) or ("contract", None) when they appear exactly once, on the one heading the
    gate reads, and its section is one line `none (<reason>)` or anything else; ("unreadable", why) in every other
    case, and for an empty section."""
    def words(text):
        views = gate_contract_views(text, loose)
        return views is None or any(GATE_CONTRACT_WORDS.search(v) for v in views)

    def where(*chunks):
        hits = [first + i + 1 for first, chunk in chunks for i, ln in enumerate(chunk) if words(ln)]
        if not hits:
            return "split across lines"
        return "line%s %s" % ("s" if len(hits) > 1 else "", ", ".join(str(x) for x in hits[:5]) +
                              (", ..." if len(hits) > 5 else ""))

    cannot = "its acceptance contract cannot be read: "
    views = gate_contract_views(body, loose)
    if views is None:
        return "unreadable", cannot + ("its body nests HTML entities more than %d deep, so the words cannot be looked "
                                       "for" % GATE_CONTRACT_DEPTH)
    if not any(GATE_CONTRACT_WORDS.search(v) for v in views):
        return "absent", None
    lines = GATE_CONTRACT_LINE.split(body)
    heads, fence, doubt, literal = [], None, None, None
    for i, ln in enumerate(lines):
        if fence:                                       # inside a fence that opened at column 0: its closer
            m = GATE_FENCE.match(ln)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not ln[m.end():].strip(" \t"):
                fence = None
            continue
        if GATE_CONTRACT_HEADING.fullmatch(ln):
            heads.append((i, doubt, literal))
            continue
        if doubt is None and literal is None:
            m = GATE_CONTRACT_OPEN.fullmatch(ln)
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                fence = m.group(1)
                continue
        if doubt is None and GATE_CONTRACT_FENCY.match(ln):
            doubt = i                                   # from here on, which line is code cannot be told
        if literal is None:
            bare = GATE_CONTRACT_CODE.sub("", ln)
            if "`" in bare or "\\`" in ln or gate_contract_html(bare):
                literal = i                             # from here on, nothing is code to the HTML check
    if len(heads) > 1:
        return "unreadable", cannot + ("it has %d lines that are exactly \"## Acceptance contract\", so which section "
                                       "the validator read cannot be told: keep one" % len(heads))
    if not heads:
        return "unreadable", cannot + ("the words \"Acceptance contract\" appear (%s), but not as the one heading the "
                                       "gate reads, a line that is exactly \"## Acceptance contract\": write the "
                                       "heading in that form, once, and the words nowhere else" % where((0, lines)))
    h, doubt, literal = heads[0]
    if words("\n".join(lines[:h])) or words("\n".join(lines[h + 1:])):
        return "unreadable", cannot + ("the words \"Acceptance contract\" appear again (%s), outside its heading on "
                                       "line %d, so a section could hide there: keep the words on the heading only" %
                                       (where((0, lines[:h]), (h + 1, lines[h + 1:])), h + 1))
    if doubt is not None:
        return "unreadable", cannot + ("its heading on line %d comes after a line that may open or close a code fence "
                                       "or a math block (line %d), where the gate cannot tell code from text, so the "
                                       "heading may sit in code: put the heading first, or open fences at column 0 "
                                       "before any raw HTML or unpaired backtick" % (h + 1, doubt + 1))
    bad = gate_contract_markup(lines[literal:h]) if literal is not None else None
    if bad:
        return "unreadable", cannot + ("its heading on line %d comes after %s (line %d), so an HTML block or element "
                                       "may hide it: put the heading before it, or remove it (before the heading, "
                                       "only an HTML comment closed with --> may stand)" %
                                       (h + 1, bad[1], literal + bad[0] + 1))
    section = []
    for ln in lines[h + 1:]:
        if GATE_CONTRACT_END.match(ln):
            break
        section.append(ln.strip())
    text = [ln for ln in section if ln]
    if not text:
        return "unreadable", cannot + ("its section is empty: write its assertions, or none (<reason>) when nothing is "
                                       "observable from outside")
    m = GATE_CONTRACT_NONE.fullmatch(text[0]) if len(text) == 1 else None
    if m and m.group(1).strip() and "<" not in text[0] and "\n" not in loose(text[0]):
        return "none", m.group(1).strip()
    return "contract", None


def gate_validation(fields, head):
    """What keeps validation fields (a strict record's, or a loose marker's) from passing rule 4 on `head`, each
    naming its field; [] when they pass: for exactly this head, verdict=pass, the counts ASCII digits that add up,
    failed=0, unchecked=0, passed=contract of at least 1, holdouts pass or none. A missing field fails."""
    rc, why = _checker[0], []

    def show(key):
        v = fields.get(key)
        return "(missing)" if v is None else rc.escape(v if len(v) <= 40 else v[:40] + "...")
    if fields.get("head") != head:
        why.append("head=%s is not this head %s: a validation does not carry over, not even clean merges of the default "
                   "branch, so validate this head" % (show("head"), head))
    if fields.get("verdict") != "pass":
        why.append("verdict=%s, not pass" % show("verdict"))
    counts = {k: fields.get(k) or "" for k in GATE_VALIDATION_COUNTS}
    bad = [k for k, v in counts.items() if not rc.COUNT.fullmatch(v)]
    for k in bad:
        why.append("%s=%s is not a count" % (k, show(k)))
    if not bad:
        n = {k: int(v) for k, v in counts.items()}
        if n["failed"]:
            why.append("failed=%d: an assertion failed" % n["failed"])
        if n["unchecked"]:
            why.append("unchecked=%d: an assertion was not checked" % n["unchecked"])
        if n["contract"] < 1:
            why.append("contract=%d: no assertion was checked" % n["contract"])
        if n["passed"] != n["contract"]:
            why.append("passed=%d is not contract=%d" % (n["passed"], n["contract"]))
        if n["passed"] + n["failed"] + n["unchecked"] != n["contract"]:
            why.append("passed, failed and unchecked do not add up to contract=%d" % n["contract"])
    if fields.get("holdouts") not in ("pass", "none"):
        why.append("holdouts=%s, not pass or none" % show("holdouts"))
    return why


def gate_step(name, cfg):
    """The step factory verify runs for check `name` (verify_steps' shape: its label and exact command), or None when
    `name` is not a check of `cfg`."""
    if name == "verify":
        return {"kind": "test", "label": "verify", "cmd": cfg["verify"], "heavy": False}
    if name in cfg["checks"]:
        c = cfg["checks"][name]
        return {"kind": "test", "label": "check %s%s" % (name, ", heavy" if c["heavy"] else ""), "cmd": c["run"],
                "heavy": c["heavy"]}
    return None


def gate_covers(body, name, cfg):
    """(True, None) when the evidence comment `body` holds factory verify's entry (evidence_line) for check `name`:
    its exact command and label, saying passed with 0 failed, and every other entry for that label is such an entry
    too; else (False, why)."""
    shown = _checker[0].escape(name)
    step = gate_step(name, cfg)
    if step is None:
        return False, "%s is not a check of the head's factory.yaml, so no evidence can name its command" % shown
    return gate_entries(body, shown, step["label"], [step["cmd"]])


def gate_entries(body, shown, label, cmds):
    """(True, None) when `body` holds, for every command of `cmds`, factory verify's entry shape (evidence_line) for
    that exact command with `label`, saying passed with 0 failed, and every entry for `label` is such an entry for one
    of them; else (False, why). `shown` names what is covered in the reasons."""
    rc = _checker[0]
    counted = re.compile(r"passed, ([0-9]+) passed, ([0-9]+) skipped, ([0-9]+) failed \(%s\):?\Z" % re.escape(label))
    lines, found = rc.LINE_BREAK.split(body or ""), set()
    for i, ln in enumerate(lines):
        if not ln.startswith("- ") or not ln.endswith(("(%s)" % label, "(%s):" % label)):
            continue
        m = counted.search(ln)
        counts = tuple(int(x) for x in m.groups()) if m else None
        hit = None
        for cmd in cmds:
            want = evidence_line({"kind": "test", "label": label, "cmd": cmd}, counts).split("\n")
            if lines[i:i + len(want)] == want:
                hit = cmd
                break
        if hit is None:
            return False, "%s: an entry for it is not factory verify's entry for its exact command" % shown
        if counts and counts[2]:
            return False, "%s: its entry reports %d failed" % (shown, counts[2])
        found.add(hit)
    left = [c for c in cmds if c not in found]
    if len(cmds) == 1 and left:
        return False, "%s: no entry with its exact command, as factory verify writes it" % shown
    if left:
        return False, "%s: no entry, as factory verify writes it with the label (%s), for its command %s" % (
            shown, rc.escape(label), _quote(rc.escape(left[0]), 80))
    return True, None


def gate_external(*cfgs):
    """[(workflow, job)]: every job listed in ci.external of each gate_config given (None is skipped), in order, once."""
    out = []
    for cfg in cfgs:
        for e in (cfg or {}).get("external") or []:
            out += [(e["workflow"], j) for j in e["jobs"] if (e["workflow"], j) not in out]
    return out


def gate_covered_by(cfg, base, workflow, job):
    """The checks whose evidence covers listed job `job` of `workflow` when GitHub refused it (merge-gate.md rule 2,
    covered_by), by name, in order, once: those the head's factory.yaml (`cfg`) and the default branch's (`base`) give
    it with covered_by. None when `base` cannot be used, or when either file does not list the job, or lists it in an
    entry without covered_by: so a pull request that adds covered_by, or a job to an entry that has it, is never
    covered by it (it changes the list, and is gated by hand), and one that changes the names is held to both lists."""
    if base is None:
        return None
    names = []
    for c in (cfg, base):
        entries = [e for e in c.get("external") or [] if e["workflow"] == workflow and job in e["jobs"]]
        if not entries or not all(e.get("covered_by") for e in entries):
            return None
        for e in entries:
            names += [x for x in e["covered_by"] if x not in names]
    return names


def gate_required(cfg, base, files):
    """The commands.checks entries rule 2 requires for `files` (merge-gate.md › Which checks), by name, in order:
    those the head's factory.yaml (`cfg`) selects, then those the default branch's (`base`; None when it cannot be
    used, and rule 1 then cannot tell) selects that the head's does not. So a pull request that takes an entry out,
    narrows its `when` or sets its `gate: false` is still held to it, as rule 2 holds it to ci.external's entries."""
    names = [name for name, _ in needed_checks(cfg["checks"], files)]
    if base is not None:
        names += [name for name, _ in needed_checks(base["checks"], files) if name not in names]
    return names


def gate_job_of(name, job):
    """Whether a check or a job named `name` is listed job `job`: the job itself, or a variant of a matrix job."""
    return name == job or name.startswith(job + " (")


def external_own_if(found, job, jobs):
    """(True, "") when listed job `job`, skipped in a run on the default branch, was skipped by its own if: alone; (False,
    why) when it cannot be so (merge-gate.md rule 1: such a skip is red); (None, why) when that cannot be told. `found`
    is external_file's answer for the workflow at the run's head, `jobs` the run's jobs (run_jobs). Its own if: alone
    means: the job (name:, else id, is `job`) has an if: of its own, and every job it needs, directly or through
    another, ran in that run with success, so no failed, cancelled or skipped need can have skipped it (Actions skips
    a job whose need did not succeed unless its if: says otherwise, and then its own if: decided after all)."""
    rc = _checker[0]
    path, doc = found
    if path is None:
        return None, doc
    defs = doc.get("jobs")
    if not isinstance(defs, dict) or not all(isinstance(j, dict) for j in defs.values()):
        return None, "%s has no map of jobs" % path
    named = [k for k, j in defs.items() if j.get("name", k) == job]
    if len(named) != 1:
        if not named and any(isinstance(j.get("name"), str) and "${{" in j["name"] for j in defs.values()):
            return None, "%s names a job with an expression, which may be %s" % (path, rc.escape(job))
        return False, "%s %s" % (path, "has no job %s" % rc.escape(job) if not named else
                                 "has several jobs named %s" % rc.escape(job))
    if "if" not in defs[named[0]]:
        return False, "the job %s of %s has no if: of its own" % (rc.escape(job), path)
    todo, done = [named[0]], set()
    while todo:
        needs = defs[todo.pop()].get("needs", [])
        needs = [needs] if isinstance(needs, str) else needs
        if not isinstance(needs, list) or not all(isinstance(x, str) for x in needs):
            return None, "a needs: in %s is not a job id or a list of them" % path
        for k in needs:
            if k in done:
                continue
            done.add(k)
            if k not in defs:
                return None, "%s has no job %s, which the job %s needs" % (path, rc.escape(k), rc.escape(job))
            name = defs[k].get("name", k)
            if not isinstance(name, str) or "${{" in name:
                return None, "the name of the job %s of %s, which %s needs, is not plain text" % (
                    rc.escape(k), path, rc.escape(job))
            ran = [x for x in jobs if gate_job_of(x["name"], name)]
            if not ran:
                return False, "it needs %s, which is not in that run" % rc.escape(name)
            for x in ran:
                if x["conclusion"] != "success":
                    return False, "it needs %s, which is %s" % (rc.escape(x["name"]),
                                                               rc.escape(x["conclusion"] or "unknown"))
            todo.append(k)
    return True, ""


def external_refused_needs(found, job, jobs, read_refusal):
    """(True, why) when listed job `job`, skipped in a run on the default branch, was skipped only because GitHub
    refused jobs it needs (merge-gate.md rule 1: not run, not red); (False, why) when it cannot be so (red); (None, why)
    when that cannot be told. `found` and `jobs` are as for external_own_if; `read_refusal` gives job_refused's answer
    for a job of `jobs` (None when it cannot be read). Only because GitHub refused them means: of every job it needs,
    directly or through another, each one that did not succeed in that run was refused by GitHub, or was skipped while
    a job it needs did not succeed (so that skip qualifies by the same rule, recursively), and at least one was
    refused. A need that ran and failed, was cancelled, timed out, is missing from the run, or was skipped though every
    job it needs succeeded (its own if:) keeps the skip red. A refusal that cannot be read, or a needs: chain the file
    does not resolve (a job it does not define, a name that is an expression, a cycle), cannot be told. Every branch of
    the chain is read whatever the order, and a red one wins over one that cannot be told."""
    rc = _checker[0]
    path, doc = found
    if path is None:
        return None, doc
    defs = doc.get("jobs")
    if not isinstance(defs, dict) or not all(isinstance(j, dict) for j in defs.values()):
        return None, "%s has no map of jobs" % path
    named = [k for k, j in defs.items() if j.get("name", k) == job]
    if len(named) != 1:
        if not named and any(isinstance(j.get("name"), str) and "${{" in j["name"] for j in defs.values()):
            return None, "%s names a job with an expression, which may be %s" % (path, rc.escape(job))
        return False, "%s %s" % (path, "has no job %s" % rc.escape(job) if not named else
                                 "has several jobs named %s" % rc.escape(job))
    start = named[0]
    reds, unsure, gone, judged, skipped = [], [], [], set(), {start: rc.escape(job)}

    def expand(k):
        """Judge the jobs `k` needs directly, once each, and give their ids to walk next."""
        needs = defs[k].get("needs", [])
        needs = [needs] if isinstance(needs, str) else needs
        if not isinstance(needs, list) or not all(isinstance(x, str) for x in needs):
            unsure.append("a needs: in %s is not a job id or a list of them" % path)
            return []
        out, failed_need, blind = [], False, False
        for n in needs:
            if n not in defs:
                unsure.append("%s has no job %s, which the job %s needs" % (path, rc.escape(n), rc.escape(job)))
                blind = True
                continue
            name = defs[n].get("name", n)
            if not isinstance(name, str) or "${{" in name:
                unsure.append("the name of the job %s of %s, which %s needs, is not plain text" % (
                    rc.escape(n), path, rc.escape(job)))
                blind = True
                continue
            ran = [x for x in jobs if gate_job_of(x["name"], name)]
            if not ran:
                reds.append("it needs %s, which is not in that run" % rc.escape(name))
                continue
            for x in ran:
                if x["conclusion"] == "success":
                    continue
                failed_need = True
                if n in judged:
                    continue
                if x["conclusion"] == "failure":
                    ok, why = read_refusal(x)
                    if ok:
                        gone.append(rc.escape(x["name"]))
                    elif ok is None:
                        unsure.append("whether GitHub refused %s cannot be read (%s)" % (rc.escape(x["name"]), why))
                    else:
                        reds.append("it needs %s, which failed and was not refused by GitHub (%s)" % (
                            rc.escape(x["name"]), why))
                elif x["conclusion"] == "skipped":
                    skipped.setdefault(n, rc.escape(x["name"]))
                else:
                    reds.append("it needs %s, which is %s" % (rc.escape(x["name"]),
                                                             rc.escape(x["conclusion"] or "unknown")))
            judged.add(n)
            out.append(n)
        if k in skipped and not failed_need and not blind:
            reds.append("every job it needs succeeded" if k == start else
                        "it needs %s, which was skipped though every job that one needs succeeded" % skipped[k])
        return out

    # Depth first, without recursion: `state` is 1 for a job on the current path, 2 for one whose needs are all walked,
    # so meeting a job on the path is a cycle (Actions refuses such a file: it cannot be what ran), never a pass.
    state, stack = {start: 1}, [(start, iter(expand(start)))]
    while stack:
        k, rest = stack[-1]
        n = next(rest, None)
        if n is None:
            state[k] = 2
            stack.pop()
        elif state.get(n) == 1:
            unsure.append("the needs: of %s form a cycle through the job %s" % (path, rc.escape(n)))
        elif n not in state:
            state[n] = 1
            stack.append((n, iter(expand(n))))
    if reds:
        return False, reds[0]
    if unsure:
        return None, "; ".join(dict.fromkeys(unsure))
    if not gone:
        return False, "no job it needs was refused by GitHub"
    return True, "GitHub refused %s" % ", ".join(dict.fromkeys(gone))


def gate_workflow(root, commit, workflow):
    """(path, the parsed file) of the workflow named `workflow` at `commit`: the file directly in GATE_WORKFLOWS whose
    name: (its path when it has none, as Actions shows it) is `workflow`, or None when no file there is named so.
    GateUnknown when a file there cannot be read with factory doctor's YAML reader, or two are named so."""
    shown = _checker[0].escape(workflow)
    raw = git(root, "ls-tree", "-z", "--name-only", commit, GATE_WORKFLOWS + "/", raw=True,
              what="the workflows of %s cannot be listed" % commit[:12])
    found = []
    for p in (os.fsdecode(x) for x in raw.split(b"\0") if x):
        if not p.endswith((".yml", ".yaml")):
            continue
        blob = git(root, "cat-file", "blob", "%s:%s" % (commit, p), raw=True,
                   what="%s at %s cannot be read" % (p, commit[:12]))
        try:
            doc = _doctor.Reader(blob.decode("utf-8")).parse()
        except (UnicodeDecodeError, _doctor.Refused) as e:
            raise GateUnknown("%s at %s cannot be read with factory doctor's YAML reader (%s), so whether it is the "
                              "workflow %s cannot be told" % (p, commit[:12], e, shown))
        if not isinstance(doc, dict):
            raise GateUnknown("%s at %s is not a workflow (not a map)" % (p, commit[:12]))
        name = doc.get("name", p)
        if not isinstance(name, str):
            raise GateUnknown("the name: of %s at %s is not text" % (p, commit[:12]))
        if name == workflow:
            found.append((p, doc))
    if len(found) > 1:
        raise GateUnknown("%s at %s are each named %s, so which one ran cannot be told" % (
            " and ".join(p for p, _ in found), commit[:12], shown))
    return found[0] if found else None


def gate_job_commands(path, doc, job, shells=False):
    """(the commands listed job `job` runs: each step's `run:`, one per step, in order, or None, why). The job is the
    one whose name: (its id when it has none) is `job`. Local evidence stands for a job only when every step is
    reproduced exactly (a strict subset; anything else is None, with the reason):
      - no env: at the workflow, the job or a step (nothing the commands alone do not carry), no container: or
        services:, and runs-on: a label or list of labels with no expression and no Windows runner, so the default
        shell is the one Linux and macOS runners use;
      - defaults.run (the workflow's, then the job's) sets at most shell:, sh or bash;
      - each step is a `run:` with only name:, id: and shell: (sh or bash) beside it, and a command with no expression;
      - the one exemption is a leading prefix of the job: zero or more steps, before its first `run:` step, that are
        exactly actions/checkout pinned to a full commit SHA (40 lowercase hex digits), with only name: and id: beside
        it. The evidence already runs in a checked-out tree of the head, so such a step adds nothing to reproduce. A
        checkout anywhere after the first `run:` step leaves the whole job uncovered: Actions' checkout cleans the tree
        there (git clean, git reset), which the evidence, running every step in one tree, would not do, so it would
        pass what Actions fails. Any other action (a local one included) runs code the evidence never runs.
    No step is merged with another: the same command in two steps is two commands, each with its own shell. None too
    for no such job, a reusable workflow, or a job with no `run:` step. GateUnknown when a job's name is an expression,
    which may name it. With `shells`, each command comes as (command, shell): the step's shell:, else the job's
    defaults, else the workflow's, else None (Actions' default), which is how factory verify runs it (ext_argv)."""
    rc = _checker[0]
    shown = "the job %s of %s" % (rc.escape(job), path)
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not all(isinstance(j, dict) for j in jobs.values()):
        raise GateUnknown("%s has no map of jobs" % path)
    named = [k for k, j in jobs.items() if j.get("name", k) == job]
    if len(named) != 1:
        hidden = [k for k, j in jobs.items() if isinstance(j.get("name"), str) and "${{" in j["name"]]
        if not named and hidden:
            raise GateUnknown("%s: the name of the job %s is an expression, so whether it is %s cannot be told" % (
                path, rc.escape(hidden[0]), rc.escape(job)))
        return None, ("%s %s, so the list no longer matches the workflow: fix factory.yaml" %
                      (path, "has no job %s" % rc.escape(job) if not named else "has several jobs named %s" %
                       rc.escape(job)))
    j = jobs[named[0]]
    if "uses" in j:
        return None, "%s calls a reusable workflow, whose commands the gate does not read" % shown
    for where, level in ((doc, "the workflow"), (j, "the job")):
        if "env" in where:
            return None, "%s has env: at %s level, which its commands alone do not carry" % (shown, level)
    for key in ("container", "services"):
        if key in j:
            return None, "%s runs with %s:, which the commands alone do not carry" % (shown, key)
    labels = j.get("runs-on")
    labels = [labels] if isinstance(labels, str) else labels
    if not isinstance(labels, list) or not labels or not all(isinstance(x, str) for x in labels) or \
            any("${{" in x or "windows" in x.lower() for x in labels):
        return None, ("%s has a runs-on: that is not plain labels of a Linux or macOS runner, so its default shell "
                      "cannot be told" % shown)
    steps = j.get("steps")
    if not isinstance(steps, list) or not all(isinstance(x, dict) for x in steps):
        return None, "%s has no list of steps" % shown
    if not steps:
        return None, "%s has no steps, so it runs no command and must run in CI" % shown
    default = None
    for where in (doc, j):
        d = where.get("defaults", {})
        run = d.get("run", {}) if isinstance(d, dict) else None
        if not isinstance(run, dict) or set(run) - {"shell"} or run.get("shell", "bash") not in ("bash", "sh"):
            return None, ("%s runs its commands with defaults (a working directory, or a shell other than sh or "
                          "bash) that the commands alone do not carry" % shown)
        default = run.get("shell", default)
    cmds = []
    for x in steps:
        if "env" in x:
            return None, "%s has a step with env:, which its command alone does not carry" % shown
        if "run" in x and "uses" in x:
            return None, "%s has a step with both run: and uses:" % shown
        if "run" not in x:
            uses = x.get("uses")
            if not isinstance(uses, str):
                return None, "%s has a step with neither run: nor uses:" % shown
            if not GATE_CHECKOUT.fullmatch(uses):
                return None, ("%s has a step that uses %s, which the evidence does not run (only actions/checkout "
                              "pinned to a commit SHA, with nothing beside it, before the first run: step, is exempt)"
                              % (shown, _quote(rc.escape(uses), 80)))
            extra = sorted(set(x) - GATE_CHECKOUT_KEYS)
            if extra:
                return None, ("%s has a checkout step with %s:, which the exemption does not allow (only name: and id: "
                              "beside it)" % (shown, rc.escape(extra[0])))
            if cmds:
                return None, ("%s has a checkout step after its first run: step; in Actions it cleans the tree there, "
                              "which the evidence does not reproduce (the exemption holds only before the first run: "
                              "step)" % shown)
            continue        # the checkout exemption: a leading prefix of exact pinned checkouts (see above)
        cmd = x["run"].rstrip("\n") if isinstance(x["run"], str) else None
        if not cmd or not cmd.strip():
            return None, "%s has a step whose run is not a command" % shown
        if "${{" in cmd:
            return None, "%s has a command with an expression (${{ … }}), which does not run as written" % shown
        if "working-directory" in x or x.get("shell", "bash") not in ("bash", "sh"):
            return None, "%s has a command with its own working directory or shell" % shown
        extra = sorted(set(x) - GATE_RUN_KEYS)
        if extra:
            return None, "%s has a step with %s:, which the gate does not model" % (shown, rc.escape(extra[0]))
        cmds.append((cmd, x.get("shell", default)))
    if not cmds:
        return None, "%s runs no command (its steps only check out the tree), so it must run in CI" % shown
    return (cmds if shells else [c for c, _ in cmds]), None


def gate_job_entries(body, shown, label, cmds):
    """(True, None) when the entries of `body` with `label` are factory verify's entries (evidence_line) for exactly the
    commands `cmds`, one per step, in the steps' order, each passed with 0 failed; else (False, why). A job's evidence
    is whole or it is none: a missing, extra or reordered entry fails, so evidence for part of a job never counts."""
    rc = _checker[0]
    counted = re.compile(r"passed, ([0-9]+) passed, ([0-9]+) skipped, ([0-9]+) failed \(%s\):?\Z" % re.escape(label))
    lines, seq = rc.LINE_BREAK.split(body or ""), []
    for i, ln in enumerate(lines):
        if not ln.startswith("- ") or not ln.endswith(("(%s)" % label, "(%s):" % label)):
            continue
        m = counted.search(ln)
        counts = tuple(int(x) for x in m.groups()) if m else None
        hit = None
        for cmd in dict.fromkeys(cmds):
            want = evidence_line({"kind": "test", "label": label, "cmd": cmd}, counts).split("\n")
            if lines[i:i + len(want)] == want:
                hit = cmd
                break
        if hit is None:
            return False, ("%s: an entry for it is not factory verify's entry for the exact command of one of its "
                           "steps" % shown)
        if counts and counts[2]:
            return False, "%s: its entry reports %d failed" % (shown, counts[2])
        seq.append(hit)
    if seq == cmds:
        return True, None
    short_of = [c for c in dict.fromkeys(cmds) if seq.count(c) < cmds.count(c)]
    if short_of and len(cmds) == 1:
        return False, "%s: no entry with its exact command, as factory verify writes it" % shown
    if short_of:
        c = short_of[0]
        return False, "%s: no entry, as factory verify writes it with the label (%s), for its command %s%s" % (
            shown, rc.escape(label), _quote(rc.escape(c), 80),
            "" if cmds.count(c) == 1 else " (%d steps run it, so it needs %d entries, one per step)" % (
                cmds.count(c), cmds.count(c)))
    return False, ("%s: its entries are not one per step in the order of its steps (%d entries for %d steps)" %
                   (shown, len(seq), len(cmds)))


def review_clean(marker, heads):
    """Whether a review marker agrees with the review record in force (rule 3): a clean merge review of one of
    `heads` (the pull request's head, or the head the record reviewed)."""
    return (marker.get("head") in heads and marker.get("verdict") == "merge"
            and all(marker.get(k) == "0" for k in ("p0", "p1", "p2", "human")))


def evidence_agrees(marker, head, tree):
    """Whether an evidence marker agrees with the evidence record for `head` (rule 2): result=pass, for that head or
    for its tree."""
    return marker.get("result") == "pass" and (marker.get("head") == head or marker.get("tree") == tree)


class GateRun:
    """One judgement of a pull request: prepare() reads what every rule shares, evaluate() runs every rule and keeps
    the results, report() prints them, write_record() is step 6."""

    TITLES = {"1": "rule 1 (up to date, default branch green)", "2": "rule 2 (checks on the head)",
              "3": "rule 3 (the latest review)", "4": "rule 4 (the validator)",
              "5": "rule 5 (human gates and acceptance)", "6": "step 6 (records)"}

    def __init__(self, project, github, pr):
        self.project, self.github, self.pr = project, github, pr
        self.root, self.n, self.head = project.root, pr["number"], pr["head"]
        self.results, self.notes = [], []
        self.kind = self.evidence_id = self.review = self.rc = None

    def git(self, *args, **kw):
        return git(self.root, *args, **kw)

    def prepare(self):
        """Fetch; then <H> as fetched, <B> as origin lists it and as fetched, the release checker verified against
        <B>'s copy and only then run (verified_checker), <H>'s tree, and the conversation."""
        gh, n = self.github, self.n
        self.default = gh.default_branch()
        gh.fetch_pr(n)
        fetched = self.git("rev-parse", "--verify", "-q", "refs/remotes/origin/pr/%d^{commit}" % n,
                           what="the fetched head of #%d cannot be read" % n)
        if fetched != self.head:
            raise Stop("the head fetched for #%d (%s) is not the head GitHub gives (%s): the pull request moved; run "
                       "factory gate again" % (n, fetched[:12], self.head[:12]))
        self.base = self.git("rev-parse", "--verify", "-q", "origin/%s^{commit}" % self.default,
                             what="origin/%s cannot be read" % self.default)
        remote = gh.heads().get(self.default)
        if remote != self.base:
            raise Stop("origin/%s here (%s) is not origin's own %s (%s) after the fetch: it just moved, or the "
                       "checkout's fetch settings leave it out; run factory gate again"
                       % (self.default, self.base[:12], self.default, (remote or "missing")[:12]))
        rc = self.rc = verified_checker(self.root, self.base, self.default, "nothing was judged")
        self.unknown = (GitHubError, GateUnknown, rc.Unverifiable, rc.GhError, subprocess.CalledProcessError)
        self.tree = self.git("rev-parse", "--verify", "-q", "%s^{tree}" % self.head,
                             what="the head's tree cannot be read")
        self.comments, self.others = gh.conversation(n, self.pr["body"])
        self.everywhere = self.comments + self.others
        self.trust = self.rc.Trust(self.project.repo())
        self.trust.writer = gh.writer

    def judge(self, rule, fn):
        try:
            status, lines = fn()
        except self.unknown as e:
            status, lines = "cannot tell", [str(e) or e.__class__.__name__]
        except Stop as e:
            if e.code != 1:
                raise
            status, lines = "cannot tell", [e.message]
        self.results.append((rule, status, lines))
        return status

    # --- rule 1 ---

    def rule1(self):
        fails, info = [], []
        if self.pr["base"] != self.default:
            fails.append("its base is %s, not the default branch %s" % (self.pr["base"], self.default))
        elif not gate_ancestor(self.root, self.base, self.head):
            fails.append("head %s is not up to date with %s at %s: update the branch with a merge (gh pr "
                         "update-branch, never a rebase or a force-push), then the new head is judged again" %
                         (self.head, self.default, self.base))
        else:
            info.append("head %s contains %s at %s" % (self.head, self.default, self.base))
        try:
            green, why = self.default_green()
        except self.unknown as e:
            if fails:
                return "fail", fails + ["whether %s is green cannot be told either: %s" % (self.default, e)]
            return "cannot tell", ["whether %s at %s is green cannot be told: %s" % (self.default, self.base, e)]
        (info if green else fails).append(why)
        return ("ok" if not fails else "fail"), (fails or info)

    def default_green(self):
        """(True, why) when the default branch's tip is green, (False, why) when it is not shown green; GateUnknown
        when that cannot be told. A job that ci.external lists (in the tip's factory.yaml, or in the head's: a pull
        request that adds an entry is held to it too) red in the latest finished run of its workflow on the default
        branch makes it red whatever the nightly or the tip's merge says (merge-gate.md rule 1), so those jobs are read
        first; otherwise tip_green decides, and the listed jobs only when it shows the tip green."""
        b = self.base
        tip = "%s at %s" % (self.default, b)
        try:
            cfg = gate_config(self.root, b)
        except GateUnknown as e:
            raise GateUnknown("whether %s has a nightly cannot be read: %s" % (self.default, e))
        try:
            ours = gate_config(self.root, self.head)
        except GateUnknown:
            ours = None         # rule 2 reads this file and says why it cannot be used; nothing else here rests on it
        listed, unknown, seen = gate_external(cfg, ours), [], []
        if listed:
            reds, seen, unknown = self.external_red(listed)
            if reds:
                return False, ("%s is red: %s; until a later run of that workflow on %s has it green, the default "
                               "branch counts as red: stop merging (factory-lead › Default branch red); the fix "
                               "for it merges through the hand gate (merge-gate.md rule 1, The fix for a red "
                               "ci.external job)" % (tip, "; ".join(reds), self.default))
        green, why = self.tip_green(cfg)
        if green and unknown:
            raise GateUnknown("whether a job ci.external lists is red on %s cannot be told: %s" % (self.default,
                                                                                                  "; ".join(unknown)))
        return green, "; ".join([why] + (seen if green else []))

    def external_red(self, listed):
        """([why each listed job is red on the default branch], [what was read], [what cannot be told]) from the latest
        finished run of each listed workflow there (board.md › CI on the default branch). A listed job missing from
        that run is red. Of its jobs, success is green; a failure Actions refused is not red (rule 2's signature; when
        that cannot be read, it is red); skipped is not run, and not red, only when its own if: skipped it
        (external_own_if) or it was skipped only because GitHub refused jobs it needs (external_refused_needs; when a
        refusal there cannot be read, or the file does not resolve its needs, and nothing there is red, it cannot be
        told); any other conclusion (cancelled, timed_out, neutral, a skip it cannot show so) is red. A workflow with no
        finished run on the default branch, or whose run cannot be read, cannot be told: never green.
        Each workflow is read on its own, so a red job in one is never hidden by another that cannot be read."""
        rc, reds, seen, unknown = self.rc, [], [], []
        for w in dict.fromkeys(w for w, _ in listed):
            bad = len(reds)
            try:
                run = self.github.external_run(w, self.default)
                if run is None:
                    unknown.append("%s has no finished run on %s, so whether the jobs ci.external lists are red there "
                                   "cannot be told" % (rc.escape(w), self.default))
                    continue
                at = "in run %d of %s on %s (%s)" % (run["id"], rc.escape(w), self.default, run["head"])
                jobs, doc, unsure, asked = self.github.run_jobs(run["id"]), [], 0, {}

                def read_refusal(x, run=run, asked=asked):
                    """job_refused's answer for job `x` of this run, read once; None when it cannot be read."""
                    if x["id"] not in asked:
                        try:
                            asked[x["id"]] = self.github.job_refused("https://github.com/%s/actions/runs/%d/job/%d" % (
                                self.project.repo(), run["id"], x["id"]))
                        except GitHubError as e:
                            asked[x["id"]] = None, str(e)
                    return asked[x["id"]]
                for job in [j for x, j in listed if x == w]:
                    mine = [x for x in jobs if gate_job_of(x["name"], job)]
                    if not mine:
                        reds.append("the job %s that ci.external lists is not %s, so the list no longer matches the "
                                    "workflow: fix factory.yaml" % (rc.escape(job), at))
                    for x in mine:
                        if x["conclusion"] == "success":
                            continue
                        if x["conclusion"] == "failure":
                            was_refused, why = read_refusal(x)
                            if was_refused is None:         # a listed job whose refusal cannot be read is red
                                why = "whether Actions refused it cannot be read (%s)" % why
                            if was_refused:
                                seen.append("%s was refused %s (%s): not red" % (rc.escape(x["name"]), at, why))
                                continue
                            reds.append("%s ran and failed %s (%s)" % (rc.escape(x["name"]), at, why))
                        elif x["conclusion"] == "skipped":
                            if not doc:
                                doc.append(self.external_file(w, run))
                            own, why = external_own_if(doc[0], job, jobs)
                            if own is None:
                                unknown.append("%s was skipped %s, and whether its own if: skipped it cannot be told: "
                                               "%s" % (rc.escape(x["name"]), at, why))
                                unsure += 1
                            elif own:
                                seen.append("%s was skipped by its own if: %s: not run, not red" % (
                                    rc.escape(x["name"]), at))
                            else:
                                by, how = external_refused_needs(doc[0], job, jobs, read_refusal)
                                if by is None:
                                    unknown.append("%s was skipped %s, not by its own if: alone (%s), and whether only "
                                                   "because GitHub refused jobs it needs cannot be told: %s" % (
                                                       rc.escape(x["name"]), at, why, how))
                                    unsure += 1
                                elif by:
                                    seen.append("%s was skipped only because GitHub refused jobs it needs %s (%s): "
                                                "not run, not red" % (rc.escape(x["name"]), at, how))
                                else:
                                    reds.append("%s is skipped %s, and not by its own if: alone (%s)%s" % (
                                        rc.escape(x["name"]), at, why, "" if how == why else
                                        ", nor only because GitHub refused jobs it needs (%s)" % how))
                        else:
                            reds.append("%s is %s %s" % (rc.escape(x["name"]), rc.escape(x["conclusion"] or "unknown"),
                                                        at))
            except (GitHubError, GateUnknown) as e:
                unknown.append(str(e))
                continue
            if len(reds) == bad and not unsure:
                seen.append("every job ci.external lists of %s is green, refused, or skipped by its own if: or by "
                            "refused needs %s" % (rc.escape(w), at))
        return reds, seen, unknown

    def external_file(self, workflow, run):
        """(path, the parsed file) of the workflow named `workflow` at the head of its run `run` on the default branch,
        or (None, why) when that commit is not here or has no such file; GateUnknown when it cannot be read."""
        if not self.rc.has_commit(run["head"]):
            return None, "the commit %s that run %d ran on is not in this checkout" % (run["head"], run["id"])
        found = gate_workflow(self.root, run["head"], workflow)
        if found is None:
            return None, "%s has no workflow named %s at %s" % (GATE_WORKFLOWS, self.rc.escape(workflow),
                                                                run["head"][:12])
        return found

    def tip_green(self, cfg):
        """The default branch's state without ci.external, from `cfg` (gate_config of the tip). A red latest nightly is
        the default branch red (factory-lead › Default branch red): only a later nightly that passed (or skipped with
        proof) makes it green again, so the tip's own merge, gated before that nightly ran, is never read then. The
        tip's merge is the green signal only between nightlies: no finished nightly, ci.nightly empty, or a green
        nightly older than the tip with more than ci.skip_paths since."""
        b, rc = self.base, self.rc
        tip = "%s at %s" % (self.default, b)
        if cfg["nightly"]:
            try:
                done = [r for r in self.github.nightly_runs(self.default) if r["status"] == "completed"]
            except GitHubError as e:
                raise GateUnknown("the nightly runs cannot be read, so whether the latest one is red cannot be told "
                                  "(%s)" % e)
            if done:
                at, why = self.nightly_green(done)
                if at is None:
                    return False, ("%s is not shown green: %s; until a later nightly passes on the tip, the default "
                                   "branch counts as red: stop merging (factory-lead › Default branch red); the fix "
                                   "for it merges through the hand gate (merge-gate.md rule 1, The fix for a red "
                                   "nightly)" % (tip, why))
                if at == b or (self.github.mode == "off" and self.only_skip_paths(at, cfg["skip_paths"])):
                    return True, "%s is green: %s%s" % (self.default, why, "" if at == b else
                                                        ", and only ci.skip_paths changed since")
                # Mode on: only a nightly on the tip itself shows it green. A nightly on an older commit with only
                # ci.skip_paths since leaves the tip's own merge to prove, as between nightlies.
                self.notes.append(why + ("; the tip is newer, and not only ci.skip_paths changed since"
                                         if self.github.mode == "off" else
                                         "; the tip is newer, and in agent-token mode on only a nightly that passed "
                                         "on the tip itself shows it green"))
        prs = self.github.merged_as(b, self.default)
        if len(prs) != 1:
            return False, ("%s is not shown green: no nightly passed on it, and %s pull request was merged as it, so "
                           "no gate record shows it (merge-gate.md rule 1)"
                           % (tip, "no" if not prs else "more than one"))
        m = prs[0]
        comments, others = self.github.conversation(m["number"], m.get("body") if isinstance(m.get("body"), str)
                                                    else None)
        try:
            reads = self.github.tip_reads(rc, self.n)
            why = rc.prove(self.project.repo(), b, m, comments, others, frozenset(), self.trust,
                           **({"reads": reads} if reads is not None else {}))
        except (KeyError, TypeError, AttributeError, IndexError, ValueError) as e:
            raise GateUnknown("the gate chain of #%d, merged as %s, cannot be read: an answer of an unexpected shape "
                              "(%s)" % (m["number"], b[:12], gate_shape_error(e)))
        if why:
            return False, "%s is not shown green: no nightly passed on it, and its own merge does not prove under " \
                          "factory-release-check: %s" % (tip, why)
        return True, "%s is green: its own merge, #%d, proves under factory-release-check (the gate record in force " \
                     "at the merge, the checks and evidence it relied on and the review in force then; nothing since " \
                     "contradicts them)" % (tip, m["number"])

    def nightly_green(self, done):
        """(the commit the latest finished nightly shows green, why) or (None, why not): a failure, a timeout, a
        cancellation or any conclusion it does not know, or a skip it cannot back. A nightly skipped on a commit counts
        for it when the run before it on that commit (skipped ones aside) passed: nothing changed since."""
        rc, r = self.rc, done[0]
        if r["conclusion"] == "success":
            return r["head"], "the latest finished nightly (run %d) passed on %s" % (r["id"], r["head"])
        if r["conclusion"] == "skipped":
            for x in done[1:]:
                if x["head"] != r["head"] or x["conclusion"] not in ("skipped", "success"):
                    break
                if x["conclusion"] == "success":
                    return r["head"], ("the latest finished nightly (run %d) skipped on %s, which nightly run %d "
                                       "passed on, so nothing changed since" % (r["id"], r["head"], x["id"]))
            return None, ("the latest finished nightly (run %d) skipped on %s, and no earlier nightly passed on that "
                          "commit to show that nothing changed" % (r["id"], r["head"]))
        return None, "the latest finished nightly (run %d) on %s is %s" % (r["id"], r["head"],
                                                                          rc.escape(r["conclusion"] or "unknown"))

    def only_skip_paths(self, sha, skip):
        if sha == self.base:
            return True
        if not skip or not self.rc.has_commit(sha) or not gate_ancestor(self.root, sha, self.base):
            return False
        raw = self.git("diff", "-z", "--no-renames", "--name-only", sha, self.base, raw=True,
                       what="the files changed since the nightly cannot be read")
        return all(path_selected(os.fsdecode(p), skip) for p in raw.split(b"\0") if p)

    # --- rule 2 ---

    def rule2(self):
        rc = self.rc
        self.kind = self.evidence_id = None
        cfg = gate_config(self.root, self.head)
        # The checks and the jobs ci.external lists, in the head's factory.yaml and in the default branch's (a pull
        # request that takes an entry out is still held to it). When the default branch's file cannot be used, rule 1
        # cannot tell.
        try:
            base = gate_config(self.root, self.base)
        except GateUnknown:
            base = None
        ours, ext = gate_external(cfg), gate_external(cfg, base)
        workflows = {w for w, _ in ext}
        # The changed files as merge-gate.md rule 2 › "Which checks" reads them, and as factory verify selected its
        # checks: the pull request's own list (GitHub.pr: complete, or refused), for this same head.
        listed = self.github.pr(self.n)
        if listed["head"] != self.head:
            raise GateUnknown("pull request #%d moved while it was judged (its head is now %s); run factory gate again"
                              % (self.n, listed["head"]))
        required = ["verify"] + gate_required(cfg, base, listed["files"])
        fails, passed, local, idle = [], set(), [], []
        checks = self.github.pr_checks(self.n)
        for e in checks:
            name, shown, bucket = e["name"], rc.escape(e["name"]), e["bucket"]
            # Factory CI's own selector and idle check job, unless ci.external lists a job of that workflow by this
            # name: such a job is the project's, and needs its evidence like every listed job.
            factory_ci = e["workflow"] == GATE_CI and not any(w == GATE_CI and gate_job_of(name, j) for w, j in ext)
            if bucket == "pass":
                if e["workflow"] not in workflows:     # a ci.external job never stands in for a factory check
                    passed.add(name)
            elif bucket == "pending":
                fails.append("%s has not finished on this head: wait until every check has finished (step 6.3)" % shown)
            elif bucket == "cancel":
                fails.append("%s was cancelled on this head: re-run it in CI" % shown)
            elif bucket == "fail":
                ok, why = (self.github.job_refused(e["link"]) if e["state"] == "FAILURE" else
                           (False, "state %s" % rc.escape(e["state"].lower())))
                if not ok:
                    fails.append("%s ran and failed in CI on this head (%s): re-run it in CI (a flaky failure is "
                                 "re-run, not waived) or fix and push; local evidence never overrides it"
                                 % (shown, why))
                elif factory_ci and name == GATE_SELECTOR:
                    idle.append(name)
                else:
                    local.append(e)
            elif factory_ci and (name == GATE_SELECTOR or name in GATE_EMPTY_MATRIX):
                idle.append(name)          # skipped, and it runs no command
            else:
                local.append(e)            # skipped: it did not run, so evidence covers it (step 6.2)
        # ci.external: a listed workflow with a check on this head ran, and must have a check for each listed job; one
        # with none did not start here, so each listed job of it needs evidence for the commands its steps run.
        ran, jobs, need = {e["workflow"] for e in checks}, [], [n for n in required if n not in passed]
        for w, j in ext:
            if w not in ran:
                jobs.append((w, j))
            elif not any(e["workflow"] == w and gate_job_of(e["name"], j) for e in checks):
                fails.append("%s ran on this head, but none of its checks is the job %s that ci.external lists%s: the "
                             "list no longer matches the workflow; fix factory.yaml" % (
                                 rc.escape(w), rc.escape(j), self.tip_only((w, j), ours)))
        unread, unlisted, held, refused, files = [], [], [], [], {}
        for e in local:
            hit = [(w, j) for w, j in ext if w == e["workflow"] and gate_job_of(e["name"], j)]
            shown = "%s of %s" % (rc.escape(e["name"]), rc.escape(e["workflow"]))
            if e["workflow"] in workflows and not hit:
                if e["bucket"] == "skipping":      # a job the list leaves out is read by neither rule
                    unread.append(shown)
                    continue
                fails.append("%s was refused in CI on this head, and ci.external does not list that job, so no "
                             "evidence can name its commands (step 6.2 needs evidence for every check that did not "
                             "run in CI): re-run it in CI" % shown)
            elif e["workflow"] not in workflows and e["bucket"] == "skipping" and e["workflow"] and \
                    e["workflow"] != GATE_CI:
                # A skip in a workflow ci.external does not list needs no evidence while the pull request leaves that
                # workflow's file unchanged; otherwise it needs evidence, as every check that did not run.
                path, why = self.unlisted_file(e["workflow"], listed["files"], files)
                if path is not None:
                    unlisted.append("%s (its file %s)" % (shown, rc.escape(path)))
                    continue
                held.append("%s was skipped in a workflow ci.external does not list, which needs no evidence only "
                            "while the pull request leaves the workflow's one file unchanged, and %s" % (shown, why))
            if e["bucket"] == "fail":
                refused += [x for x in hit if x not in refused]
            else:
                jobs += [x for x in hit if x not in jobs]
            if not hit and e["name"] not in need:
                need.append(e["name"])
        # A listed job GitHub refused (and nothing else: a skip, or a workflow that did not start, needs its steps) is
        # covered by evidence of the checks covered_by names, when both factory.yaml files give it covered_by.
        covered = {}
        for x in refused:
            names = gate_covered_by(cfg, base, *x)
            if x in jobs:
                continue
            if names is None:
                jobs.append(x)
            else:
                covered[x] = names
        if fails:
            return "fail", fails
        quiet = (["%s (factory-ci.yml's %s) runs no command, so no evidence covers it" %
                  (", ".join(rc.escape(x) for x in dict.fromkeys(idle)), "selector or idle check job")] if idle else [])
        quiet += (["%s did not run on this head: ci.external does not list %s, so neither rule reads %s and no "
                   "evidence covers %s" % (", ".join(dict.fromkeys(unread)), "it" if len(unread) == 1 else "them",
                                           "it" if len(unread) == 1 else "them", "it" if len(unread) == 1 else "them")]
                  if unread else [])
        quiet += (["%s did not run on this head: ci.external does not list %s, and this pull request leaves %s "
                   "unchanged, so no evidence covers %s" % ("; ".join(unlisted), "its workflow" if len(unlisted) == 1
                                                            else "their workflows", "that file" if len(unlisted) == 1
                                                            else "those files", "it" if len(unlisted) == 1 else "them")]
                  if unlisted else [])
        named = ["%s / %s" % (rc.escape(w), rc.escape(j)) for w, j in ext]
        if not need and not jobs and not covered:
            self.kind, self.evidence_id = "ci", "-"
            return "ok", ["every required check passed in CI on this head (%s), and every other check ran and passed"
                          % ", ".join(required + named)] + quiet
        shown_need = ", ".join([rc.escape(x) for x in need] + ["%s / %s" % (rc.escape(w), rc.escape(j))
                                                                for w, j in jobs] +
                               ["%s / %s (refused; covered by %s)" % (rc.escape(w), rc.escape(j),
                                                                      ", ".join(rc.escape(x) for x in names))
                                for (w, j), names in covered.items()])
        held = "".join("; %s" % x for x in held)
        # A required check the head's factory.yaml no longer has: no entry can name its command.
        missing = ["%s is required by %s's factory.yaml for this diff, and is not a check of the head's, so no "
                   "evidence can name its command (a pull request that changes commands.checks is gated by hand)" %
                   (rc.escape(x), self.default) for x in need if x in required[1:] and x not in cfg["checks"]]
        # What each such job runs, from the workflow file at the head.
        cmds, unknown = {}, []
        for w, j in jobs:
            try:
                if w not in files:
                    files[w] = gate_workflow(self.root, self.head, w)
                if files[w] is None:
                    missing.append("the head has no workflow named %s in %s, so the commands of its job %s cannot be "
                                   "read%s: the list no longer matches the workflows; fix factory.yaml" % (
                                       rc.escape(w), GATE_WORKFLOWS, rc.escape(j), self.tip_only((w, j), ours)))
                    continue
                c, why = gate_job_commands(files[w][0], files[w][1], j)
            except GateUnknown as e:
                unknown.append(str(e))
                continue
            if c is None:
                missing.append(why + self.tip_only((w, j), ours))
            else:
                cmds[(w, j)] = c
        if missing:
            return "fail", ["%s did not pass in CI on this head, and no local evidence can stand for it: %s%s" % (
                shown_need, "; ".join(missing), held)]
        try:
            evidence, why = self.find_evidence()
        except GateUnknown as e:
            return "cannot tell", ["%s did not pass in CI on this head, and the local evidence cannot be judged: %s%s"
                                   % (shown_need, e, "".join("; nor can the commands it must cover be read: %s" % x
                                                             for x in unknown))]
        # A check that is not required (gate: false, or its `when` selects no changed file) and did not run in CI:
        # factory verify <P> runs it too when the checks show it refused or skipped (merge-gate.md rule 2, Checks with
        # `gate: false`).
        extra = [x for x in need if x not in required and x in cfg["checks"]]
        also = ("factory verify %d also runs %s, which %s not required for this diff, since CI refused or skipped %s "
                "on this head (merge-gate.md rule 2, Checks with gate: false)"
                % (self.n, ", ".join(rc.escape(x) for x in extra), "is" if len(extra) == 1 else "are",
                   "it" if len(extra) == 1 else "them")) if extra else None
        if evidence is None:
            return "fail", ["%s did not pass in CI on this head, and %s%s%s" % (shown_need, why,
                                                                               " (%s)" % also if also else "", held)]
        body, hint = evidence.comment.get("body"), []
        for name in need:
            ok, why = gate_covers(body, name, cfg)
            if not ok:
                missing.append(why)
                tip = also if name in extra else "factory verify %d writes an entry for each check it runs" % self.n
                if tip not in hint:
                    hint.append(tip)
        for (w, j), c in cmds.items():
            ok, why = gate_job_entries(body, "%s / %s" % (rc.escape(w), rc.escape(j)), GATE_EXT_LABEL % (w, j), c)
            if not ok:
                missing.append(why)
                hint.append("a ci.external job needs factory verify's entry for each of its steps, in order, labelled "
                            "(%s), which factory verify %d writes when the job's checks show it needs one"
                            % (rc.escape(GATE_EXT_LABEL % (w, j)), self.n))
        for (w, j), names in covered.items():
            for name in names:
                ok, why = gate_covers(body, name, cfg)
                if not ok:
                    missing.append("%s / %s was refused, and ci.external covers it with %s (covered_by): %s" % (
                        rc.escape(w), rc.escape(j), rc.escape(name), why))
                    tip = ("factory verify %d runs each check covered_by names when the job's checks show it refused"
                           % self.n)
                    if tip not in hint:
                        hint.append(tip)
        if missing:
            return "fail", ["the local evidence (comment %s) does not cover every check that did not run and pass in "
                            "CI: %s%s%s" % (evidence.id, "; ".join(missing), " (%s)" % "; ".join(hint) if hint else "",
                                            held)]
        if unknown:
            return "cannot tell", ["%s did not pass in CI on this head, and the commands local evidence must cover "
                                   "cannot be read: %s" % (shown_need, "; ".join(unknown))]
        self.kind, self.evidence_id = "local", str(evidence.id)
        return "ok", ["%s: local evidence for this head's tree %s (comment %s)%s" % (
            shown_need, self.tree, evidence.id, "; the rest passed in CI" if passed else "")] + quiet

    def tip_only(self, job, ours):
        """The note for a listed job that only the default branch's factory.yaml lists: such a pull request changes the
        list, and is gated by hand."""
        return "" if job in ours else (" (listed in %s's factory.yaml, not the head's: a pull request that changes "
                                       "the list is gated by hand)" % self.default)

    def unlisted_file(self, workflow, changed, files):
        """(the path of the one file at the head named `workflow`, None) when the pull request's changed files
        (`changed`) leave it unchanged, else (None, why not): no file there is named so, two are, one cannot be read,
        or the pull request changes it. `files` caches gate_workflow's answers by workflow name."""
        rc = _checker[0]
        try:
            if workflow not in files:
                files[workflow] = gate_workflow(self.root, self.head, workflow)
        except GateUnknown as e:
            return None, str(e)
        if files[workflow] is None:
            return None, "the head has no workflow named %s in %s" % (rc.escape(workflow), GATE_WORKFLOWS)
        path = files[workflow][0]
        if path in changed:
            return None, "this pull request changes that file, %s" % rc.escape(path)
        return path, None

    def find_evidence(self):
        """(the evidence record that counts for <H>, None) or (None, why not): the latest trusted record with
        result=pass for exactly <H> and its tree (without tree=, for <H>), contradicted by no later evidence marker.
        A record for <H>'s tree from another head is batch evidence, which the gate refuses (see the section's
        comment)."""
        rc = self.rc

        def for_tree(r):
            covers = r.get("tree") == self.tree if "tree" in r.fields else r.get("head") == self.head
            return covers and r.get("result") == "pass"

        def agrees(m):
            return evidence_agrees(m, self.head, self.tree)
        found = [r for r in self.trust.records(self.comments, "evidence") if for_tree(r)]
        if not found:
            return None, ("no evidence record for this head's tree %s, by a person with write access in a comment "
                          "never edited, says result=pass: run factory verify %d" % (self.tree, self.n))
        own = [r for r in found if r.get("head") == self.head]
        if not own:
            return None, ("the evidence for this head's tree %s (comment %s) is for another head, %s: batch evidence, "
                          "which the gate does not accept, since the records carry no batch order and it cannot check "
                          "what voids a batch (merge-gate.md › The batch gate): run factory verify %d on this head, or "
                          "merge the batch by hand" % (self.tree, found[-1].id, rc.escape(found[-1].get("head")),
                                                       self.n))
        if rc.contradicted(self.trust.markers(self.everywhere, "evidence"), own[-1], agrees):
            return None, ("the evidence record in comment %s is contradicted by a later evidence marker that does not "
                          "say result=pass for this head or its tree" % own[-1].id)
        return own[-1], None

    # --- rule 3 ---

    def rule3(self):
        rc = self.rc
        reviews = self.trust.records(self.comments, "review")
        if not reviews:
            return "fail", ["no review record by a person with write access, in a comment never edited: the head needs "
                            "a review"]
        r = self.review = reviews[-1]
        reviewed, fails, info = r.get("head"), [], []
        if reviewed == self.head:
            info.append("the latest review is of this head")
        elif not rc.FULL_SHA.fullmatch(reviewed or ""):
            fails.append("the latest review names no full head SHA")
        else:
            why = rc.carried_review(reviewed, self.head, self.base)
            if why:
                fails.append("the latest review is of %s and does not carry over to this head: %s %s; a re-review of "
                             "the head comes first" % (reviewed, reviewed[:7], why))
            else:
                info.append("the latest review is of %s and carries over clean merges of %s to this head (a version "
                            "raised in them, or in one commit of its own on the reviewed head, counts too)" %
                            (reviewed, self.default))
        if r.get("verdict") != "merge":
            fails.append("the latest review's verdict is %s, not merge" % rc.escape(r.get("verdict")))
        open_ = ["%s=%s" % (k, rc.escape(r.get(k))) for k in ("p0", "p1", "p2") if r.get(k) != "0"]
        if open_:
            fails.append("the latest review has open findings (%s)" % ", ".join(open_))
        hold = r.get("release_hold") or ""
        if not rc.COUNT.fullmatch(hold):
            fails.append("the latest review's release_hold is not a number")
        elif int(hold):
            self.notes.append("the latest review records release_hold=%s: record the hold (the skill's human gates); "
                              "it does not block the merge" % hold)

        def clean(m):
            return review_clean(m, (self.head, reviewed))
        if rc.contradicted(self.trust.markers(self.everywhere, "review"), r, clean):
            fails.append("a review marker later than the latest review record is not a clean merge review of this head "
                         "or the reviewed one (open findings, another head or another verdict): re-review, or clear it "
                         "if it is not a review result")
        return ("fail" if fails else "ok"), (fails or info)

    # --- rule 4 ---

    def rule4(self):
        rc = self.rc
        closes = self.pr["closes"]
        if not closes:
            return "fail", ["the pull request closes no issue of this repository (no Closes #N), so whether it has an "
                            "acceptance contract cannot be read"]
        fails, info, contracts = [], [], []
        for k in closes:
            kind, detail = gate_contract(self.github.issue(k)["body"], rc.loose)
            if kind == "absent":
                info.append("issue #%d has no \"Acceptance contract\" section" % k)
            elif kind == "none":
                info.append("issue #%d's acceptance contract reads none (%s)" % (k, rc.escape(_quote(detail, 80))))
            elif kind == "contract":
                contracts.append(k)
            else:
                fails.append("issue #%d: %s" % (k, detail))
        if len(contracts) > 1:
            fails.append("%s each have an acceptance contract, and a validation record names no issue, so it cannot "
                         "show which contract passed: give each its own pull request" % _nums(contracts))
        if fails:
            return "fail", fails
        if not contracts:
            return "not applicable", info + ["so no validation is needed"]
        k = contracts[0]
        found = self.trust.records(self.comments, "validation")
        if not found:
            return "fail", ["issue #%d has an acceptance contract, and the pull request has no validation record by a "
                            "person with write access, in a comment never edited: validate this head" % k]
        v = found[-1]
        why = gate_validation(v.fields, self.head)
        if why:
            return "fail", ["the latest validation record (comment %s) does not pass: %s" % (v.id, w) for w in why]
        # Every later marker must itself be a passing validation of this head (contradicted(), with its first reason).
        later = [gate_validation(m.fields, self.head) for m in self.trust.markers(self.everywhere, "validation")
                 if m.after(v)]
        later = [w for w in later if w]
        if later:
            return "fail", ["a validation marker later than the latest validation record (comment %s) is not a passing "
                            "validation of this head (%s): validate again, or clear it if it is not a validation "
                            "result" % (v.id, later[0][0])]
        return "ok", ["the latest validation record (comment %s) passed issue #%d's acceptance contract on this head "
                      "(contract=%s, holdouts=%s)" % (v.id, k, v.get("contract"), v.get("holdouts"))]

    # --- rule 5 ---

    def gap_for_this_pr(self, issue):
        """(True, how) when an open issue was made for a gap of this pull request: it was created after the pull
        request was opened; (False, why) when it is older; (None, why) when a creation time is missing or unreadable,
        since cannot tell is not a pass (merge-gate.md rule 5)."""
        mine, theirs = self.rc.parse_time(self.pr.get("created")), self.rc.parse_time(issue["created"])
        if theirs is None:
            return None, "has no readable creation time"
        if mine is None:
            return None, ("cannot be compared: the pull request's creation time is not in the answer%s" %
                          (" (this factory-github's pr-view is older than createdAt: update it)"
                           if self.github.mode == "on" else ""))
        if theirs > mine:
            return True, "created after the pull request was opened"
        return False, "older than the pull request"

    def rule5(self):
        fails, info, unknown = [], [], []
        closes = self.pr["closes"]
        if not closes:
            fails.append("the pull request closes no issue of this repository (no Closes #N), so the issue's gates "
                         "cannot be read")
        held = [x for x in GATE_HUMAN if x in self.pr["labels"]]
        if held:
            fails.append("pull request #%d carries %s (H1: work reserved for a person): a person decides; the gate "
                         "cannot read a linked approval" % (self.n, " and ".join(held)))
        for k in closes:
            labels = labels_of(self.github.issue(k))
            held = [x for x in GATE_HUMAN if x in labels]
            if held:
                fails.append("issue #%d carries %s (H1: work reserved for a person): a person decides; the gate cannot "
                             "read a linked approval" % (k, " and ".join(held)))
        if self.review is not None and self.review.get("human") != "0":
            fails.append("the latest review has an unresolved merge-blocking human gate (human=%s)" %
                         self.rc.escape(self.review.get("human")))
        items, why = gate_acceptance(self.pr["body"])
        if items is None:
            fails.append(why)
        else:
            for ticked, text in items:
                if ticked:
                    continue
                refs = [int(x) for x in GATE_ISSUE_REF.findall(text)]
                refs += [int(m.group(3)) for m in ISSUE_URL.finditer(text)
                         if ("%s/%s" % (m.group(1), m.group(2))).lower() == self.project.repo().lower()]
                gaps = [x for x in dict.fromkeys(refs) if x not in closes]
                if not gaps:
                    fails.append("acceptance criterion not ticked, and no new issue for its gap is linked: %s" %
                                 _quote(self.rc.escape(text), 80))
                    continue
                opened = [i for i in (self.github.gate_gap_issue(x) for x in gaps) if i["state"] == "OPEN"]
                if not opened:
                    fails.append("acceptance criterion not ticked, and the issue it links (%s) is not open: %s" %
                                 (_nums(gaps), _quote(self.rc.escape(text), 80)))
                    continue
                verdicts = [(i["number"],) + self.gap_for_this_pr(i) for i in opened]
                good = [(k, why) for k, ok, why in verdicts if ok is True]
                if good:
                    info.append("an unticked criterion has its gap in %s" %
                                ", ".join("#%d (%s)" % (k, why) for k, why in good))
                elif any(ok is None for _, ok, _ in verdicts):
                    unknown.append("cannot tell whether the open issue an unticked criterion links was made for its "
                                   "gap: %s: %s" % ("; ".join("#%d %s" % (k, why) for k, ok, why in verdicts
                                                              if ok is None), _quote(self.rc.escape(text), 80)))
                else:
                    fails.append("acceptance criterion not ticked, and the open issue it links (%s) was not made for "
                                 "its gap: it is older than the pull request; link a new issue for the gap: %s" %
                                 (_nums([k for k, _, _ in verdicts]), _quote(self.rc.escape(text), 80)))
        if fails:
            fails += unknown
        elif unknown:
            raise GateUnknown("; ".join(unknown))
        if not fails:
            info.insert(0, "no agent:human or status:needs-human on #%d or %s; every acceptance criterion is ticked or "
                           "has its gap in an open issue made for it" % (self.n, _nums(closes)))
        return ("fail" if fails else "ok"), (fails or info)

    # --- step 6 ---

    def records(self):
        late = [m for m in self.trust.markers(self.everywhere, "gate") if m.when == self.rc.FOREVER]
        if late:
            return "fail", ["a gate marker sits where it counts as later than any record (the description, or a "
                            "comment without a readable time), so no gate record could stand: edit it out "
                            "(merge-gate.md step 6, Leave the records alone)"]
        return "ok", ["nothing on the pull request would contradict a gate record written now"]

    # --- the whole run, and the record ---

    def evaluate(self):
        """Every rule, in order (each is judged, not only up to the first that fails): 0 pass, 2 a rule fails, 1 a
        rule cannot tell."""
        self.results, self.review = [], None
        self.judge("1", self.rule1)
        self.judge("2", self.rule2)
        self.judge("3", self.rule3)
        self.judge("4", self.rule4)
        self.judge("5", self.rule5)
        self.judge("6", self.records)
        statuses = [status for _, status, _ in self.results]
        return 2 if "fail" in statuses else 1 if "cannot tell" in statuses else 0

    def blocking(self):
        """The rules that did not pass, failed ones first, by their short names."""
        failed = [rule for rule, status, _ in self.results if status == "fail"]
        unknown = [rule for rule, status, _ in self.results if status == "cannot tell"]
        return [self.TITLES[r].split(" (")[0] for r in failed + unknown]

    def report(self, code):
        for rule, status, lines in self.results:
            for ln in lines:
                gate_say("%s: %s: %s" % (self.TITLES[rule], status, ln))
        for x in self.notes:
            gate_say("note: %s" % x)
        gate_say("fail: %s" % ", ".join(self.blocking()) if code else "pass")

    def run(self):
        code = self.evaluate()
        self.report(code)
        return code

    def write_record(self):
        """Step 6.3 to 6.5's checks, then step 6.4's record: the pull request and origin's default tip read again,
        every rule judged again from fresh reads with the same outcome (head, base, evidence), the pause as its own
        subprocess right before the post, then the record as the comment's first line."""
        gh, n = self.github, self.n
        now = gh.gate_pr(n)
        if now["state"] != "OPEN" or now["head"] != self.head or now["draft"]:
            raise Stop("refused: #%d changed since it was judged (now %s, head %s); nothing was posted: run factory "
                       "gate again" % (n, now["state"].lower() + (", a draft" if now["draft"] else ""), now["head"]), 3)
        tip = gh.heads().get(self.default)
        if tip != self.base:
            raise Stop("refused: %s moved since it was judged (now %s); nothing was posted: update the branch and run "
                       "factory gate again" % (self.default, (tip or "missing")), 3)
        gh.forget()
        again = GateRun(self.project, gh, now)
        try:
            again.prepare()
        except Stop as e:
            if e.code != 1:
                raise
            raise Stop("refused: #%d changed since it was judged (%s); nothing was posted: run factory gate again" %
                       (n, e.message), 3)
        code = again.evaluate()
        why = "; ".join("%s: %s" % (again.TITLES[rule], ln) for rule, status, lines in again.results
                        if status in ("fail", "cannot tell") for ln in lines)
        if not why and (again.kind, again.evidence_id) != (self.kind, self.evidence_id):
            why = "the checks now give checks=%s evidence=%s, not checks=%s evidence=%s" % (
                again.kind, again.evidence_id, self.kind, self.evidence_id)
        if holds_marker(why):
            why = "a reason that reads as a record marker was withheld"
        if code == 1:
            raise Stop("judged again right before the post, a rule cannot tell (%s); nothing was posted" % why)
        if code or why:
            raise Stop("refused: #%d changed since it was judged (%s); nothing was posted: run factory gate again" %
                       (n, why), 3)
        kind, evidence_id = self.kind, self.evidence_id
        how = ("every check and status ran in CI and passed" if kind == "ci" else
               "local evidence in comment %s" % evidence_id)
        rest = ("🤖 factory gate: rules 1-5 of the merge gate passed for head %s, up to date with %s at %s; "
                "checks: %s." % (self.head, self.default, self.base, how))
        if holds_marker(rest):
            raise Stop("the comment would hold a record marker after its first line; nothing was posted")
        text = GATE_RECORD % (self.head, self.base, kind, evidence_id) + "\n" + rest + "\n"
        if redact(text) != text:
            raise Stop("the comment looks like it holds a credential; nothing was posted")
        require_not_paused(self.project, gh)
        answer = gh.pr_comment(n, text)
        url = re.search(r"https://\S+#issuecomment-([0-9]+)", answer)
        say("posted the gate record on #%d%s" % (n, ": %s (gate record comment id %s)" % (url.group(0), url.group(1))
                                                  if url else ""))


def gate_say(text):
    """say(), except that a line which would read as a record marker (from a check name, say) is withheld: nothing this
    tool prints may contradict a record."""
    say(text if not holds_marker(text) else "(a line that reads as a record marker was withheld)")


def cmd_gate(args):
    usage = COMMANDS["gate"][1]
    n, record = gate_args(args, usage)
    project = Project()
    github = GateGitHub(project)
    if record:
        require_not_paused(project, github)
    # Nothing here runs the release checker before prepare() has verified it against the default branch's copy: the
    # lines printed before then are fixed text, said without holds_marker().
    os.chdir(project.root)             # factory-release-check's git calls run in the current folder
    pr = github.gate_pr(n)
    if pr["state"] != "OPEN":
        raise Stop("refused: pull request #%d is %s: the gate judges an open pull request; nothing was checked" %
                   (n, pr["state"].lower()), 3)
    if pr["draft"]:
        say("%s: fail: #%d is a draft, so its CI run skips every job: mark it ready (gh pr ready %d) when the work "
            "is complete, which starts the real checks" % (GateRun.TITLES["2"], n, n))
        say("fail: rule 2")
        return 2
    run = GateRun(project, github, pr)
    run.prepare()
    gate_say("factory gate #%d: head %s, %s at %s" % (n, run.head, run.default, run.base))
    code = run.run()
    if code != 0 or not record:
        if record:
            note("factory gate: the gate did not pass; nothing was posted")
        return code
    run.write_record()
    return 0


# factory markers: the lead's pre-check of every open pull request after a merge that changes the release checker
# (merge-gate.md, "After a merge that changes the release checker"; factory-lead, after every merge). Once a checker
# change is on the default branch, every later gate judges with it, and the releases after the one that ships it prove
# with it, so a marker the new reading finds in another open pull request's description or comments refuses that pull
# request's gate, or its proof. This reads every open pull request (or the ones named) as rules 2-4 and step 6 of the
# gate read its markers, with the checker beside this file, which must be the default branch's own (verified_checker),
# and names each place to edit. Trust boundary: it reads the pull requests' text through gh or the broker and runs only
# the default branch's checker; it never fetches, checks out or runs anything from a pull request's branch, posts
# nothing and edits nothing. A finding is a warning to act on; no finding is not a pass of anything: the gate and the
# release still judge every record.

def marker_findings(rc, trust, head, comments, others):
    """[(where, why)]: each place on one pull request where the release checker reads a marker the gate refuses on
    the head `head`: a marker later than the latest review, evidence, validation or gate record that does not say what
    that record says (marker_agrees(), the gate's own test in rules 2-4 and step 6). A marker in the description or in
    a comment without a readable time counts as later than every record, so it is judged the same way against the
    record in force; only a gate marker there is named with no record, since step 6 refuses it whatever it says. A
    review, evidence or validation marker with no record of its kind to contradict yet is not named: the gate judges it
    once that record exists, and so does a later run of factory markers."""
    everywhere = comments + others
    found = []

    def add(marker, why):
        c = marker.comment
        where = c.get("where") or ("comment %s%s" % (_where_id(c), " (%s)" % c["html_url"] if isinstance(
            c.get("html_url"), str) and re.fullmatch(r"https://\S+", c["html_url"]) else ""))
        if (where, why) not in found:
            found.append((where, why))
    for kind in ("review", "evidence", "validation", "gate"):
        a = "an" if kind == "evidence" else "a"
        markers = trust.markers(everywhere, kind)
        records = trust.records(comments, kind)
        if kind == "evidence":
            records = [r for r in records if r.get("head") == head and r.get("result") == "pass"]
        elif kind == "gate":
            records = [r for r in records if r.get("head") == head]
        if not records:
            for m in markers:
                if kind == "gate" and m.when == rc.FOREVER:
                    add(m, "a gate marker sits where it counts as later than every record (the description, or a "
                           "comment without a readable time), so no gate record could stand: edit it out, or write "
                           "the example in prose")
            continue
        r = records[-1]
        for m in markers:
            if m.after(r) and not marker_agrees(kind, m, r, head):     # a FOREVER marker is after every record
                place = ("in a place that counts as later than every record (the description, or a comment without a "
                         "readable time)" if m.when == rc.FOREVER else "later than the latest %s record" % kind)
                add(m, "%s %s marker %s does not say what the latest %s record (comment %s) says: edit it, or write "
                       "the example in prose" % (a, kind, place, kind, r.id))
    return found


def marker_agrees(kind, marker, record, head):
    """Whether a marker later than `record`, the latest record of its kind, says what it says, as the gate judges it:
    rule 3 for a review (a clean merge review of the head or of the reviewed head), rule 2 for evidence (result=pass,
    for the head or for the record's tree), rule 4 for a validation (a passing validation of the head); a later gate
    marker never agrees (the release checker's step 1)."""
    if kind == "review":
        return review_clean(marker, (head, record.get("head")))
    if kind == "evidence":
        return evidence_agrees(marker, head, record.get("tree"))
    if kind == "validation":
        return not gate_validation(marker.fields, head)
    return False


# factory markers --draft <file> and --posted <P> <comment>: a reviewer's check of its own review marker, before the
# comment is posted and after it is read back. The check is the release checker's own code, never a copy: the placement
# and the exact key set are header_record()'s (the comment's first line, or the line after a first-line `#` heading,
# which is where the gate and the release read a record that proves), the counts are its COUNT, the head its FULL_SHA,
# and the marker count is Trust.markers() (the loose reading, which is what a later gate reads). What this adds is the
# reason: header_record() answers "no record", and a reviewer needs to know which of the six usual slips it made.

REVIEW_VERDICTS = ("merge", "merge-after-fixes", "needs-rework")
REVIEW_COUNT_KEYS = ("p0", "p1", "p2", "p3", "human", "release_hold")
REVIEW_HYPHEN = re.compile(r"factory[\s_-]+review(?![a-z])", re.IGNORECASE)    # the tag with a hyphen, a space, an underscore
REVIEW_PROBE = ("<!-- factory:review head=%s verdict=merge p0=0 p1=0 p2=0 p3=0 human=0 release_hold=0 -->" % ("a" * 40))
MARKER_CHECK_NAMES = ("header_record", "RECORD", "RECORD_KEYS", "COUNT", "FULL_SHA", "LINE_BREAK", "LOOSE_MARKER", "Trust",
                      "loose", "escape", "parse_time")
POSTED_COMMENT = re.compile(r"(?:https://\S*#issuecomment-)?([1-9][0-9]{0,15})")


def local_default_branch(root):
    """The default branch's name as the checkout itself knows it (origin/HEAD, which a clone sets and `git remote
    set-head origin --auto` restores), with no GitHub read; None when it does not say."""
    try:
        name = git(root, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")
    except Stop:
        return None
    name = name[len("origin/"):] if name.startswith("origin/") else None
    return name if branch_name(name) else None


FACTORY_REPO_CHECKER = "core/bin/factory-release-check"    # where the factory repo itself keeps the release checker
REMOTE_REPO = re.compile(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                         r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?")


def in_factory_repo(root):
    """True when this tool runs from `<root>/core/bin`: the factory repo's own layout (a project keeps its copy in
    `.factory/bin`), where the release checker is `core/bin/factory-release-check` (merge-gate.md, Which checker
    judges)."""
    return os.path.realpath(HERE) == os.path.realpath(os.path.join(root, "core", "bin"))


def markers_checker(root, base, default, done):
    """verified_checker() for the markers modes: against the default branch's `.factory/bin/factory-release-check`, as
    the gate does; only when the default branch has none there and this tool runs from the factory repo's own
    core/bin, against its `core/bin/factory-release-check`. Either way the bytes beside this tool must equal the
    default branch's own copy before any of them run."""
    path = CHECKER_PATH
    if in_factory_repo(root):
        listing = git(root, "--no-replace-objects", "ls-tree", "-z", base, "--", CHECKER_PATH, raw=True,
                      what="%s at %s cannot be read" % (default, base[:12]))
        if not listing:
            path = FACTORY_REPO_CHECKER
    return verified_checker(root, base, default, done, path)


def use_remote_repo(project):
    """The factory repo has no factory.yaml: name its repository (owner/name) from origin's address, which must be a
    github.com one in the plain shape; anything else is refused, never guessed. A project with a factory.yaml, or a
    checkout whose tool is not at core/bin, keeps reading factory.yaml. Mode on never asks for the name (the broker
    reads the repository it registered), so a refusal waits until something asks: Project.config() says it."""
    if os.path.isfile(os.path.join(project.root, "factory.yaml")) or not in_factory_repo(project.root):
        return
    try:
        url = git(project.root, "config", "--get", "remote.origin.url", what="origin's address cannot be read")
    except Stop as e:
        project.no_repo = e.message
        return
    m = REMOTE_REPO.fullmatch(url)
    if m:
        project._config = {"project": {"repo": m.group(1)}}
    else:
        project.no_repo = "origin's address is not a github.com one in the plain shape"


def offline_checker(root, done):
    """The release checker for a check that reads no GitHub (--draft): run only after its bytes proved to be the default
    branch's own, as verified_checker() judges them, against origin/<default> as this checkout already has it (no
    fetch, so a checkout that is behind refuses rather than guesses). A checkout that cannot name or reach
    origin/<default> is refused, never trusted: the checker beside the tool is not run without that proof."""
    default = local_default_branch(root)
    if default is None:
        raise Stop("refused: this checkout does not name its default branch (origin/HEAD is not set), so the release "
                   "checker beside this tool cannot be compared with the default branch's copy and none of it was "
                   "run; run `git remote set-head origin --auto` with network once; %s" % done, 3)
    try:
        base = git(root, "rev-parse", "--verify", "-q", "origin/%s^{commit}" % default,
                   what="origin/%s cannot be read" % default)
    except Stop as e:
        raise Stop("refused: %s here, so the release checker beside this tool cannot be compared with %s's copy and "
                   "none of it was run; fetch origin once; %s" % (e.message, default, done), 3)
    return markers_checker(root, base, default, done)


def trusted_checker(project, github, done):
    """(checker, default branch, base commit) for a check that is merge-facing: the default branch fetched and
    confirmed to be origin's own, then the checker beside the tool compared with its copy there before any of it runs
    (verified_checker()). factory markers and factory markers --posted read records with exactly this."""
    os.chdir(project.root)
    default = github.default_branch()
    github.fetch_branch(default)
    base = git(project.root, "rev-parse", "--verify", "-q", "origin/%s^{commit}" % default,
               what="origin/%s cannot be read" % default)
    if github.heads().get(default) != base:
        raise Stop("origin/%s here (%s) is not origin's own %s after the fetch: it just moved, or the checkout's fetch "
                   "settings leave it out; run factory markers again" % (default, base[:12], default))
    return markers_checker(project.root, base, default, done), default, base


def marker_checker(rc):
    """`rc`, factory-release-check's module (the one grammar, already verified), after the names the check reads are
    shown to be there."""
    mod = rc
    for name in MARKER_CHECK_NAMES:
        if not hasattr(mod, name):
            raise Stop("factory-release-check next to factory lacks %s, which the review marker check reads records "
                       "with; restore the core files with factory update" % name)
    if "review" not in (getattr(mod, "RECORD_KEYS", None) or {}):
        raise Stop("factory-release-check next to factory does not know the review record; restore the core files "
                   "with factory update")
    return mod


def review_field_problems(rc, fields):
    """[why]: what the gate would refuse in the values of a review record that is well formed (rule 3 reads the verdict
    and p0, p1, p2 and human, the carry-over the head, the release step the hold count)."""
    found = []                              # a key that is absent is named by the caller as missing, not judged here
    if "head" in fields and not rc.FULL_SHA.fullmatch(fields["head"]):
        found.append("head=%s is not a full 40-character commit SHA (lower-case hex): the gate compares it with the "
                     "pull request's head, and a short one never matches" % rc.escape(fields["head"]))
    if "verdict" in fields and fields["verdict"] not in REVIEW_VERDICTS:
        found.append("verdict=%s is not one of %s" % (rc.escape(fields["verdict"]), ", ".join(REVIEW_VERDICTS)))
    for key in REVIEW_COUNT_KEYS:
        if key in fields and not rc.COUNT.fullmatch(fields[key]):
            found.append("%s=%s is not a whole number (write 0 for none): the gate reads only digits there" %
                         (key, rc.escape(fields[key])))
    return found


def odd_characters(text):
    """The characters of `text` that are not plain printable ASCII (or a tab), named, at most five kinds: the look-alikes
    and invisible characters that loose() reads as the plain ones and the strict reader does not."""
    seen = []
    for ch in text:
        if (ord(ch) > 126 or (ord(ch) < 32 and ch != "\t")) and ch not in seen:
            seen.append(ch)
    names = ["U+%04X %s" % (ord(ch), unicodedata.name(ch, "unnamed character")) for ch in seen[:5]]
    return ", ".join(names) + (" and more" if len(seen) > 5 else "")


def review_line_problems(rc, line, explained=False):
    """[why] for one line that mentions the review tag but is not a record the checker reads: which part is wrong.
    `line` is the normalized reading; `explained` is set when the caller already named the characters that differ."""
    text = rc.loose(line).strip()
    found = []
    if not text.startswith("<!--") or not text.endswith("-->"):
        found.append("the marker line must be one HTML comment, opening with its opening mark and ending with its "
                     "closing mark, with nothing else on the line")
    body = re.sub(r"^<!--|-->$", "", text).strip()
    words = body.split()
    if not words or words[0] != "factory:review":
        found.append("the tag must be spelled exactly as a lower-case factory, a colon, review (the first word "
                     "after the opening mark)")
    words = words[1:]
    pairs = [w.split("=", 1) for w in words if "=" in w]
    stray = [w for w in words if "=" not in w]
    if stray:
        found.append("the marker holds a word that is not a key=value pair (%s)" % rc.escape(" ".join(stray)))
    keys = [k for k, _ in pairs]
    need = next(iter(rc.RECORD_KEYS["review"]))
    if len(keys) != len(set(keys)):
        found.append("a key is given twice")
    if need - set(keys):
        found.append("keys missing: %s (the gate reads every one of them)" % ", ".join(sorted(need - set(keys))))
    if set(keys) - need:
        found.append("keys the record does not have: %s" % rc.escape(", ".join(sorted(set(keys) - need))))
    found += review_field_problems(rc, dict(pairs))
    if re.search(r"\s{2,}|\t", text):
        found.append("keys are separated by exactly one space, with one space inside each end of the comment")
    if not found and not explained:
        found.append("the line is not exactly the marker of the comment format (single spaces, lower-case keys, "
                     "values of letters, digits and ._:/- only)")
    return found


def review_draft_problems(rc, body):
    """[why] a review comment `body` would not be read as a review record by the gate and the release checker, in the
    order a reviewer would fix them; empty when it would be."""
    found = []
    record = rc.header_record(body)
    if record is not None and record[0] != "review":
        found.append("the comment's marker line is a %s record, not a review record" % rc.escape(record[0]))
    elif record is not None:
        found += review_field_problems(rc, record[1])
    else:
        # The strict reader found no review record, so the draft is refused whatever follows. The normalized view
        # (loose()) is read only to say why, and below to find markers that contradict: it reads look-alike and
        # invisible characters as the plain ones, which the strict reader never does.
        lines = rc.loose(body).split("\n")
        raw_lines = rc.LINE_BREAK.split(body or "")
        same = len(raw_lines) == len(lines)
        at = [i for i, line in enumerate(lines) if any(m.group(1).lower() == "review" for m in rc.LOOSE_MARKER.finditer(line))]
        hyphen = [i for i, line in enumerate(lines) if REVIEW_HYPHEN.search(line) and "<!--" in line]
        if not at and hyphen:
            found.append("line %d spells the tag with a hyphen, a space or an underscore (the tag is factory, a colon, "
                         "review): the gate reads no record there" % (hyphen[0] + 1))
        elif not at:
            found.append("no review marker: the comment has no line with the review tag; the gate and the release "
                         "read only the first line (or the line after a first-line # heading), so a review without it "
                         "never counts")
        else:
            line, raw = lines[at[0]], raw_lines[at[0]] if same else None
            shown = raw_lines if same else lines
            probe = "\n".join(shown[:at[0]] + [REVIEW_PROBE] + shown[at[0] + 1:])
            if rc.header_record(probe) is None:
                found.append("the marker is on line %d: the release checker reads only the first line, or the line "
                             "right after a first-line # heading, so move it there" % (at[0] + 1))
            odd = odd_characters(raw if raw is not None else body)
            if odd:
                found.append("line %d holds characters the release checker does not read as the plain ones they look "
                             "like or as nothing (%s): the strict reader finds no record there, so retype the line in "
                             "plain ASCII" % (at[0] + 1, odd))
            if rc.header_record(raw if raw is not None else line) is None:
                found += review_line_problems(rc, line, bool(odd))
        if not found:
            found.append("the release checker's strict reader finds no review record in the comment's first line (or "
                         "the line after a first-line # heading): write the marker exactly as the comment format shows")
    counted = {kind: len(rc.Trust.markers([{"body": body}], kind)) for kind in ("review", "gate", "evidence", "validation")}
    if counted["review"] > 1:
        found.append("the comment holds %d review markers: write the others in prose, the gate reads each one" %
                     counted["review"])
    for kind in ("gate", "evidence", "validation"):
        if counted[kind]:
            found.append("the comment holds a %s marker: it would read as a later record that contradicts the %s "
                         "record in force; describe it in words" % (kind, kind))
    return found


def review_posted_problems(rc, comment, writer):
    """[why] the posted comment (as GitHub gives it) would not count: the draft check on its text, then never edited
    (the time it was last updated is the time it was created), written by a User account that may write."""
    found = review_draft_problems(rc, comment.get("body"))
    created, updated = rc.parse_time(comment.get("created_at")), comment.get("updated_at")
    if created is None:
        found.append("the comment has no readable creation time, so it never counts as a record")
    elif updated != comment.get("created_at"):
        found.append("the comment was edited after it was posted, so the release never takes it as proof: post one "
                     "new comment with the whole review and a correct marker, and never edit this one")
    user = comment.get("user") or {}
    login = user.get("login")
    if user.get("type") != "User" or not isinstance(login, str) or not login:
        found.append("the comment was not written by a User account, so it never counts as a record")
    elif not writer(login):
        found.append("the comment's author has no write, maintain or admin permission, so it never counts as a record")
    return found


def draft_marker_check(args, usage):
    """factory markers --draft <file>: 0 when the file would be read as a review record, 2 with each reason when not."""
    if len(args) != 2:
        raise Stop("unknown argument (not shown); usage: %s" % usage, 64)
    project = Project()
    rc = marker_checker(offline_checker(project.root, "nothing was checked"))   # nothing of it ran before this
    try:
        with open(args[1], "rb") as f:
            body = f.read().decode("utf-8", "replace")
    except OSError:
        raise Stop("the draft file cannot be read (%s)" % short(args[1], 100))
    found = review_draft_problems(rc, body)
    for why in found:
        gate_say("draft: %s" % why)
    gate_say("draft: fix it, then check it again before posting" if found else
             "draft: ok: the review marker is where and what the gate and the release read")
    return 2 if found else 0


def posted_marker_check(args, usage):
    """factory markers --posted <P> <comment>: the draft check on the comment read back from pull request P, and that it
    was never edited. 0 when it counts, 2 with each reason when not, 1 when it could not be read."""
    if len(args) != 3 or not re.fullmatch(r"#?[1-9][0-9]{0,9}", args[1]) or not POSTED_COMMENT.fullmatch(args[2]):
        raise Stop("unknown argument (not shown); usage: %s" % usage, 64)
    n, cid = int(args[1].lstrip("#")), int(POSTED_COMMENT.fullmatch(args[2]).group(1))
    project = Project()
    use_remote_repo(project)
    github = GateGitHub(project)
    rc = marker_checker(trusted_checker(project, github, "nothing was read")[0])   # nothing of it ran before this
    try:
        comments, _ = github.conversation(n, None)
        found = [c for c in comments if c.get("id") == cid]
        if not found:
            raise GitHubError("comment %d is not among the conversation comments of #%d (a formal review or an inline "
                              "comment never holds a record)" % (cid, n))
        problems = review_posted_problems(rc, found[0], github.writer)
    except GitHubError as e:
        gate_say("cannot tell: %s" % (str(e) or e.__class__.__name__))
        return 1
    for why in problems:
        gate_say("#%d comment %d: %s" % (n, cid, why))
    gate_say("posted: post one new comment with the whole review and a correct marker; never edit this one" if problems else
             "posted: ok: comment %d on #%d is a review record as the gate and the release read it" % (cid, n))
    return 2 if problems else 0


def markers_args(args, usage):
    numbers = []
    for a in args:
        if a in ("-h", "--help"):
            say(usage)
            raise Stop("", 0)
        if not re.fullmatch(r"#?[1-9][0-9]{0,9}", a) or int(a.lstrip("#")) in numbers:
            raise Stop("unknown argument (not shown); usage: %s" % usage, 64)
        numbers.append(int(a.lstrip("#")))
    return numbers


def cmd_markers(args):
    usage = COMMANDS["markers"][1]
    if args[:1] == ["--draft"]:
        return draft_marker_check(args, usage)
    if args[:1] == ["--posted"]:
        return posted_marker_check(args, usage)
    numbers = markers_args(args, usage)
    project = Project()
    github = GateGitHub(project)
    rc, default, base = trusted_checker(project, github, "nothing was read")   # nothing of it ran before this
    if not numbers:
        numbers = github.open_prs()
    gate_say("factory markers: reading %d pull request%s with the release checker of %s at %s" % (
        len(numbers), "" if len(numbers) == 1 else "s", default, base))
    trust = rc.Trust(project.repo())
    trust.writer = github.writer
    edits = unknown = 0
    for n in numbers:
        try:
            pr = github.gate_pr(n)
            if pr["state"] != "OPEN":
                gate_say("#%d: not read: it is %s" % (n, pr["state"].lower()))
                continue
            comments, others = github.conversation(n, pr["body"])
            found = marker_findings(rc, trust, pr["head"], comments, others)
        except (GitHubError, rc.Unverifiable, rc.GhError) as e:
            unknown += 1
            gate_say("#%d: cannot tell: %s" % (n, str(e) or e.__class__.__name__))
            continue
        if not found:
            gate_say("#%d: clean: no marker the release checker reads there contradicts a record" % n)
        for where, what in found:
            edits += 1
            gate_say("#%d: edit %s: %s" % (n, where, what))
    gate_say("edit: %d place%s to edit before the next gate" % (edits, "" if edits == 1 else "s") if edits else
             "cannot tell: %d pull request%s could not be read" % (unknown, "" if unknown == 1 else "s") if unknown else
             "clean")
    return 2 if edits else 1 if unknown else 0


# --- help and the table ----------------------------------------------------------------------------------------------

def cmd_help(args):
    width = max(len(name) for name in COMMANDS)
    for name in sorted(COMMANDS):
        if name != "help":
            say("  %s  %s" % (name.ljust(width), COMMANDS[name][2]))
    return 0


# name -> (function, usage, one-line summary). Parts 3-5 add their subcommands here.
COMMANDS = {
    "help": (cmd_help, "factory help", "this list"),
    "ready": (cmd_ready, "factory ready [--json]",
              "the open issues that can start now, in pick order, with tier, milestone and owned paths"),
    "unblock": (cmd_unblock, "factory unblock [--apply] [--json]",
                "the status:blocked issues whose blockers are all done; --apply moves them to status:ready"),
    "claim": (cmd_claim, "factory claim <N>",
              "move issue N to status:in-progress, after the claim checks (refuses while paused)"),
    "verify": (cmd_verify, "factory verify [<P> --why <reason>]  or  factory verify --no-heavy",
               "run setup, verify and the checks PR P's files need on a clean tree of its head; post the local "
               "evidence on P, with the reason, when all pass (refuses while paused); without P, the checkout's HEAD "
               "and its local diff, posting nothing; --no-heavy (without P only) leaves each heavy check to the gate "
               "and says so"),
    "lock": (cmd_lock, "factory lock heavy -- <command> [<argument>...]",
             "run the command while holding one of the machine's heavy slots (machine.limits.heavy), waiting in line"),
    "gate": (cmd_gate, "factory gate <P> [--record]",
             "check merge-gate rules 1-5 on PR P's head: print pass, or each rule that fails and why; --record then "
             "writes the gate record after checking that nothing moved or is running (refuses while paused)"),
    "markers": (cmd_markers, "factory markers [<P>...]  or  factory markers --draft <file>  or  factory markers "
                "--posted <P> <comment>",
                "read every open PR's description and comments (or PR P's) with the default branch's release checker, "
                "as the gate reads markers, and name each place to edit; posts nothing (run it after a merge that "
                "changes the release checker). --draft checks a review comment's file before it is posted: where its "
                "marker sits, its tag, every key and each count; --posted checks the same on the posted comment (an "
                "id or its link) read back from PR P, and that it was never edited"),
    "status": (cmd_status, "factory status [--dry-run] [--note \"<section>: <text>\"]...",
               "build the status update from the board, validate it and post it on the status issue"),
}


def main(argv):
    if _doctor is None:
        note("factory: factory-doctor.py is missing or broken next to factory.py; restore the core with factory update")
        return 1
    if not argv:
        argv = ["help"]
    name, args = argv[0], argv[1:]
    if name not in COMMANDS:
        note("factory: unknown subcommand (not shown); run factory help")
        return 64
    try:
        return COMMANDS[name][0](args)
    except Stop as e:
        if e.message:
            note("factory %s: %s" % (name, e.message))
        return e.code
    except GitHubError as e:
        note("factory %s: %s; nothing more was done" % (name, e))
        return 1


def guarded(argv):
    try:
        return main(argv)
    except KeyboardInterrupt:
        return 130
    except BaseException:  # noqa: B036 (one fixed line, never a traceback with values in it)
        try:
            sys.stderr.write("factory: internal error; report it to the factory repo\n")   # out: a fixed message
        except BaseException:  # noqa: B036
            pass
        return 70


if __name__ == "__main__":
    sys.exit(guarded(sys.argv[1:]))
