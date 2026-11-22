#!/usr/bin/env python3
"""factory metrics: what merged work cost, per tier, from GitHub and the machine's usage ledger.

    factory metrics [--days N] [--repo OWNER/NAME] [--project NAME] [--post]

It prints one short Markdown table, readable on a phone, for one project over the last N UTC days (default 30, today
included; 1 to 365):

  - one row per tier and a totals row, from the pull requests merged in the window that close an issue of the
    project: merged issues (the tier is the issue's tier:* label now, so an escalated issue counts on its last tier),
    fix rounds (model-policy.md rule 3: every `### Fix round <n> (...)` report on the pull request except an
    adaptation), the P0-P2 findings of each pull request's first review record (`<!-- factory:review ... -->`, the
    reviewer's comment format), and the model fit lines (model-policy.md › Model fit report) as right / too weak /
    more than needed, counted on the tier each line names. A pull request that closes issues of several tiers counts
    its rounds and findings once, on the highest of them; each distinct issue counts once, on its own tier, even when
    several merged pull requests close it (a reopened issue);
  - per merged issue: fix rounds and first-review findings;
  - usage, from the machine's ledger (factory-usage's own reader and weights, read under its shared lock; never
    written): the runs of this project that started in the window, their weighted hours and the hours per merged
    issue, and the usage-limit hits per provider on this machine (every project: a limit is the provider's, not a
    project's). The ledger names a project by the name its starter gave: factory.yaml's project.name and the name
    part of project.repo both count, or --project NAME;
  - the model fit lines again per work kind, the numbers the lead's tier-table proposals rest on.

Fail closed: a GitHub read that cannot finish (an error, an answer of an unexpected shape such as a merged pull
request without a readable closingIssuesReferences list or entry, a single UTC day with 1000 or more merged pull
requests, which cannot be read whole) prints the table with
"cannot tell" in place of every GitHub number and the reason, and exits 1; a number is never guessed or counted from
part of the data. A ledger that cannot be read (a torn or unknown line, an unsafe path, machine.yaml not valid) puts
"cannot tell" and the reason on the usage line only. No ledger on this machine says so. A pull request without a
readable first review record, and a line that looks like a model fit line but is not in the policy's form, are
counted and named on their own line, never guessed.

--post posts the table as one new comment on the status issue (the one open issue labelled factory:status), after
the emergency-stop check, and only when every GitHub number was read; without it nothing is written anywhere. GitHub
access follows the agent-token mode as every factory command does (reference/github-access.md): plain gh with -R
when it is off, the broker's verbs when it is on, nothing when it is staged or unknown. --repo names the repository
when there is no factory.yaml, with the mode off only (the broker always uses the repository it registered).

Exit codes: 0 printed (and posted with --post); 1 a read could not finish, or factory.yaml, the mode or the post
failed; 3 refused (paused, the stop cannot be read, no single status issue); 64 bad usage; 70 internal error.

Everything printed goes through factory.py's say() and note() (redacted, control characters replaced). Standard
library only; Python 3.8 or later on macOS and Linux. It reads factory.py, factory-usage.py and factory-doctor.py next
to it; the clock is the system's, or FACTORY_USAGE_NOW (UTC, YYYY-MM-DDTHH:MM:SSZ) when set, as factory-usage reads it.
"""

import datetime
import importlib.util
import os
import re
import sys
import warnings

warnings.simplefilter("ignore")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True

USAGE = "factory metrics [--days N] [--repo OWNER/NAME] [--project NAME] [--post]"
DAYS_DEFAULT, DAYS_MAX = 30, 365
TIER_ORDER = ("deep", "standard", "light")
CANNOT = "cannot tell"
ADAPTATION = re.compile(r"^### Fix round [1-9][0-9]* \(adaptation:", re.MULTILINE)
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
MARKER = re.compile(r"<!-- factory:review ([^>]*)-->")


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fac = _load("factory_tool", "factory.py")
usage_mod = _load("factory_usage", "factory-usage.py")
say, note, Stop, GitHubError = fac.say, fac.note, fac.Stop, fac.GitHubError


# --- arguments ------------------------------------------------------------------------------------------------------

def parse_args(args):
    opts = {"days": DAYS_DEFAULT, "repo": None, "project": None, "post": False}
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-h", "--help"):
            sys.stdout.write(__doc__)
            raise Stop("", 0)
        if a == "--post":
            opts["post"] = True
        elif a in ("--days", "--repo", "--project"):
            if i + 1 >= len(args):
                raise Stop("%s needs a value; usage: %s" % (a, USAGE), 64)
            i += 1
            v = args[i]
            if a == "--days":
                if not re.fullmatch(r"[1-9][0-9]{0,2}", v) or int(v) > DAYS_MAX:
                    raise Stop("--days is a whole number from 1 to %d" % DAYS_MAX, 64)
                opts["days"] = int(v)
            elif a == "--repo":
                if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", v):
                    raise Stop("--repo is OWNER/NAME", 64)
                opts["repo"] = v
            else:
                if not re.fullmatch(usage_mod.FIELD["project"], v) or v == "-":
                    raise Stop("--project is a project name as the ledger holds it (letters, digits, . _ -)", 64)
                opts["project"] = v
        else:
            raise Stop("unknown argument (not shown); usage: %s" % USAGE, 64)
        i += 1
    return opts


class ArgProject(fac.Project):
    """The checkout, with the repository from --repo instead of factory.yaml when one was given."""

    def __init__(self, repo):
        fac.Project.__init__(self)
        self._repo = repo

    def repo(self):
        return self._repo or fac.Project.repo(self)

    def name(self):
        """factory.yaml's project.name, or None (also without a factory.yaml when --repo was given)."""
        if self._repo and not os.path.isfile(os.path.join(self.root, "factory.yaml")):
            return None
        project = self.config().get("project")
        n = project.get("name") if isinstance(project, dict) else None
        return n if isinstance(n, str) and n else None


# --- GitHub ---------------------------------------------------------------------------------------------------------

def fenced_out(body):
    """A comment without its fenced code blocks (an unclosed fence runs to the end): an example is not a record.
    HTML comments stay, since a review record is one."""
    out, fence = [], None
    for line in body.splitlines():
        m = FENCE.match(line)
        if fence is None:
            if m:
                fence = m.group(1)
            else:
                out.append(line)
        elif m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not line[m.end():].strip():
            fence = None
    return "\n".join(out)


def counted_rounds(comments):
    """Fix rounds that count (model-policy.md rule 3): every fix-round report but an adaptation."""
    n = 0
    for body in comments:
        text = fac.report_text(body)
        if fac.FIX_ROUND.search(text) and not ADAPTATION.search(text):
            n += 1
    return n


def first_findings(comments):
    """P0+P1+P2 of the earliest review record on the pull request, or None when there is none or it is not readable."""
    for body in comments:
        for m in MARKER.finditer(fenced_out(body)):
            fields = dict(kv.split("=", 1) for kv in m.group(1).split() if "=" in kv)
            vals = [fields.get(k, "") for k in ("p0", "p1", "p2")]
            if not all(re.fullmatch(r"[0-9]{1,4}", v) for v in vals):
                return None
            return sum(int(v) for v in vals)
    return None


def tier_of(issue):
    tiers = fac.tiers_of(issue)
    return tiers[0][len("tier:"):] if len(tiers) == 1 else ("no tier" if not tiers else "several tiers")


def rank(tier):
    return TIER_ORDER.index(tier) if tier in TIER_ORDER else len(TIER_ORDER)


REF_NAME = re.compile(r"[A-Za-z0-9_.-]+")


def closes_here(p, repo):
    """The issue numbers of this repository a merged pull request closes, from closingIssuesReferences, checked whole:
    a missing field, or an entry whose number and repository cannot both be read, is a GitHubError, never skipped."""
    refs = p.get("closingIssuesReferences")
    what = "merged PR #%d: closingIssuesReferences" % p["number"]
    if not isinstance(refs, list):
        raise GitHubError("%s is missing or not a list" % what)
    owner, name = (x.lower() for x in repo.split("/"))
    out = set()
    for ref in refs:
        if not isinstance(ref, dict) or not fac._int(ref.get("number")) or ref["number"] < 1:
            raise GitHubError("%s holds an entry without an issue number" % what)
        url = ref.get("url")
        if url is not None:
            m = fac.ISSUE_URL.fullmatch(url) if isinstance(url, str) else None
            if not m or int(m.group(3)) != ref["number"]:
                raise GitHubError("%s holds an entry whose url is not that issue's" % what)
            ro, rn = m.group(1), m.group(2)
        else:
            r = ref.get("repository")
            o = r.get("owner") if isinstance(r, dict) else None
            ro = o.get("login") if isinstance(o, dict) else None
            rn = r.get("name") if isinstance(r, dict) else None
            if not (isinstance(ro, str) and REF_NAME.fullmatch(ro) and isinstance(rn, str) and REF_NAME.fullmatch(rn)):
                raise GitHubError("%s holds an entry without its repository" % what)
        if ro.lower() == owner and rn.lower() == name:
            out.add(ref["number"])
    return out


def github_numbers(github, since):
    """Every GitHub number of the table, or raise GitHubError/Stop: nothing is returned from part of the data. Each
    distinct issue counts once, on its tier, however many merged pull requests close it; rounds and findings count per
    pull request."""
    repo = github.project.repo()
    merged = github.merged_since(since)   # the window read whole, as `factory status` reads it; a part is refused
    rows, kinds, no_record, unparsed, tier_by_issue = {}, {}, [], [], {}

    def row(t):
        return rows.setdefault(t, {"issues": 0, "rounds": 0, "findings": 0, "fit": dict.fromkeys(fac.FIT_VERDICTS, 0)})

    for p in sorted(merged, key=lambda p: p["number"]):
        numbers = sorted(closes_here(p, repo))
        if not numbers:
            continue
        tiers = []
        for n in numbers:
            if n not in tier_by_issue:
                tier_by_issue[n] = tier_of(github.issue(n))
                row(tier_by_issue[n])["issues"] += 1
            tiers.append(tier_by_issue[n])
        comments = github.pr_comments(p["number"])
        top = min(tiers, key=rank)
        row(top)["rounds"] += counted_rounds(comments)
        f = first_findings(comments)
        if f is None:
            no_record.append(p["number"])
        else:
            row(top)["findings"] += f
        found, bad = fac.model_fits(comments)
        for kind, _role, tier, verdict in found:
            row(tier)["fit"][verdict] += 1
            kinds.setdefault(kind, dict.fromkeys(fac.FIT_VERDICTS, 0))[verdict] += 1
        if bad:
            unparsed.append((p["number"], bad))
    return {"rows": rows, "kinds": kinds, "no_record": no_record, "unparsed": unparsed}


# --- the ledger -----------------------------------------------------------------------------------------------------

def ledger_numbers(names, start, end):
    """(runs, weighted hours, {provider: limit hits}) of the window from the ledger, None when there is no ledger, or
    a string: why it cannot tell. Read with factory-usage's own Store, parse, settings and weight, never written."""
    home = os.environ.get("HOME") or ""
    if not home or not os.path.lexists(os.path.join(home, ".factory", "usage", usage_mod.LEDGER)):
        return None
    try:
        with usage_mod.Store(False) as st:
            settings = usage_mod.settings(st, os.path.join(HERE, "..", "defaults.yaml"))
            records, problems = usage_mod.parse(st.ledger())
    except usage_mod.Fail as e:
        return str(e)
    except OSError as e:
        return "the ledger cannot be read (%s)" % e.__class__.__name__
    if problems:
        return "the ledger has unreadable lines (%s); factory-usage --help says how to fix them" % problems[0]
    runs, hours, limits = 0, 0.0, {}
    cap = datetime.timedelta(hours=usage_mod.OPEN_RUN_HOURS)
    for r in records:
        if r["kind"] == "limit" and start <= r["at"] <= end:
            limits[r["provider"]] = limits.get(r["provider"], 0) + 1
        elif r["kind"] == "start" and r["project"] in names and start <= r["at"] <= end:
            stop = r.get("end") or min(end, r["at"] + cap)
            stop = min(stop, end)
            runs += 1
            hours += max(0.0, (stop - r["at"]).total_seconds() / 3600.0) * usage_mod.weight(
                settings, r["model"], r["effort"])
    for p in usage_mod.providers(settings, records):
        limits.setdefault(p, 0)
    return runs, hours, limits


# --- the table ------------------------------------------------------------------------------------------------------

def fit_cell(c):
    return "%d/%d/%d" % tuple(c[v] for v in fac.FIT_VERDICTS)


def per(n, d):
    return "%.1f" % (n / d) if d else "-"


def table(title, days, gh, gh_error, ledger, ledger_name):
    out = ["## Metrics: %s, last %d day%s" % (title, days, "" if days == 1 else "s"), ""]
    out += ["| Tier | Issues | Fix rounds | P0-P2 | Fit r/w/m |", "| --- | ---: | ---: | ---: | :---: |"]
    total = None
    if gh is None:
        out.append("| all | %s | %s | %s | %s |" % ((CANNOT,) * 4))
        out += ["", "GitHub: %s (%s); no GitHub number is shown." % (CANNOT, fac.one_line(gh_error))]
    else:
        rows = gh["rows"]
        total = {"issues": 0, "rounds": 0, "findings": 0, "fit": dict.fromkeys(fac.FIT_VERDICTS, 0)}
        for t in sorted(set(rows) | set(TIER_ORDER), key=lambda t: (rank(t), t)):
            r = rows.get(t) or {"issues": 0, "rounds": 0, "findings": 0, "fit": dict.fromkeys(fac.FIT_VERDICTS, 0)}
            out.append("| %s | %d | %d | %d | %s |" % (t, r["issues"], r["rounds"], r["findings"], fit_cell(r["fit"])))
            for k in ("issues", "rounds", "findings"):
                total[k] += r[k]
            for v in fac.FIT_VERDICTS:
                total["fit"][v] += r["fit"][v]
        out.append("| **total** | %d | %d | %d | %s |" % (total["issues"], total["rounds"], total["findings"],
                                                          fit_cell(total["fit"])))
        out += ["", "Per merged issue: %s fix rounds, %s P0-P2 findings in the first review."
                % (per(total["rounds"], total["issues"]), per(total["findings"], total["issues"]))]
        if gh["no_record"]:
            out.append("No readable first review record: %s (their findings are not in P0-P2)."
                       % ", ".join("PR #%d" % p for p in gh["no_record"]))
    if ledger is None:
        out.append("Usage: no usage ledger on this machine.")
    elif isinstance(ledger, str):
        out.append("Usage: %s (%s)." % (CANNOT, fac.one_line(ledger)))
    else:
        runs, hours, limits = ledger
        each = per(hours, total["issues"]) if total else CANNOT
        out.append("Usage (this machine, project %s): %d run%s, %.1f weighted h, %s h per merged issue."
                   % (ledger_name, runs, "" if runs == 1 else "s", hours, each))
        out.append("Usage-limit hits (this machine, every project): %s."
                   % (", ".join("%s %d" % (p, limits[p]) for p in sorted(limits)) or "none"))
    out += ["", "Model fit by work kind (right/too weak/more than needed):"]
    if gh is None:
        out.append("- %s" % CANNOT)
    else:
        out += ["- %s: %s" % (k, fit_cell(c)) for k, c in sorted(gh["kinds"].items())] or ["- none"]
        if gh["unparsed"]:
            nu = sum(b for _, b in gh["unparsed"])
            out.append("- not parsed: %d line%s (%s)" % (nu, "" if nu == 1 else "s",
                                                         ", ".join("PR #%d" % p for p, _ in gh["unparsed"])))
    return "\n".join(out) + "\n"


# --- the command ----------------------------------------------------------------------------------------------------

def cmd_metrics(args):
    opts = parse_args(args)
    project = ArgProject(opts["repo"])
    github = fac.StatusGitHub(project)
    if opts["repo"] and github.mode != "off":
        raise Stop("--repo works with the agent-token mode off only; the broker uses the repository it registered", 64)
    repo = project.repo()
    names = {opts["project"]} if opts["project"] else {n for n in (project.name(), repo.split("/")[1]) if n}
    ledger_name = opts["project"] or project.name() or repo.split("/")[1]

    try:
        end = usage_mod.now()
    except usage_mod.Fail as e:
        raise Stop(str(e), 64)
    start = (end - datetime.timedelta(days=opts["days"] - 1)).replace(hour=0, minute=0, second=0)

    gh, gh_error = None, None
    try:
        gh = github_numbers(github, start.strftime("%Y-%m-%d"))
    except (GitHubError, Stop) as e:
        gh_error = getattr(e, "message", None) or str(e)
    ledger = ledger_numbers(names, start, end)
    text = fac.redact(table(ledger_name, opts["days"], gh, gh_error, ledger, ledger_name))
    for ln in text.rstrip("\n").split("\n"):
        say(ln)
    if isinstance(ledger, str):
        note("factory metrics: the usage line cannot tell: %s" % ledger)
    if gh is None:
        raise Stop("a GitHub read could not finish (%s); the table says cannot tell%s"
                   % (gh_error, "; nothing was posted" if opts["post"] else ""), 1)
    if not opts["post"]:
        return 0

    status = github.labelled(fac.STATUS_LABEL, limit=10)
    if len(status) != 1:
        raise Stop("%s open issue is labelled %s; nothing was posted"
                   % ("no" if not status else "more than one", fac.STATUS_LABEL), 3)
    s = status[0]["number"]
    fac.require_not_paused(project, github)
    try:
        github.comment(s, text)
    except GitHubError as e:
        raise Stop("the metrics were not posted: %s" % e)
    note("factory metrics: posted on the status issue #%d" % s)
    return 0


def main(argv):
    if fac._doctor is None:
        note("factory metrics: factory-doctor.py is missing or broken; restore the core with factory update")
        return 1
    try:
        return cmd_metrics(argv)
    except Stop as e:
        if e.message:
            note("factory metrics: %s" % e.message)
        return e.code
    except GitHubError as e:
        note("factory metrics: %s; nothing was posted" % e)
        return 1


if __name__ == "__main__":
    try:
        code = main(sys.argv[1:])
    except KeyboardInterrupt:
        code = 130
    except BaseException:  # noqa: B036 (one fixed line, never a traceback with values in it)
        try:
            sys.stderr.write("factory metrics: internal error; report it to the factory repo\n")   # out: fixed
        except BaseException:  # noqa: B036
            pass
        code = 70
    sys.exit(code)
