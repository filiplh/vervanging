#!/usr/bin/env python3
"""factory-headless: the headless runtime's runner. runtime/headless.md says what each subcommand is for and which
rules it keeps; this file implements them and does not restate them.

    python3 -I -B factory-headless.py run JOB [--now] [--urgent]
    python3 -I -B factory-headless.py start --project DIR --role ROLE --spec SPEC --brief FILE [--name NAME]
                                            [--max-turns N] [--timeout-minutes M] [--heavy] [--urgent]
    python3 -I -B factory-headless.py result RUN | cancel RUN | runs | plist JOB | resolve SPEC [--project DIR]

How the pieces fit:
  - The core's own tools do the factory's work, found next to the core (.factory/bin in a project, core/bin in the
    factory repo): factory-pause (the emergency stop), factory-usage (the reserve and the ledger), factory lock heavy,
    factory gate, factory-settings (a spec named by its key of `models`). factory-doctor.py lends its YAML reader, its
    machine check, its hook check, its secret shapes and its redaction; factory-safe-paths.py opens ~/.factory.
  - execute() is one run, start to report, for `run` and `start` alike: refusals first (spec, CLI, pause, reserve,
    caps), then the worktree (git-locked while the run lives, so factory gc leaves it alone), the ledger start, the
    CLI in its own process group with the time cap (stopped in a finally if anything breaks before the wait), the
    ledger end, the result, the gate for a reported PR, the worktree clean-up and the report.
  - Each run's merge denial is merge-guard.py next to this file: a PreToolUse hook added with --settings, and the gh
    first on the run's PATH. Each run's guard (start_guard) holds the slot with the runner and ends the run if the
    runner dies; a later start or cancel ends a run whose runner and guard both died (recover_stale, reconcile).
  - State lives under ~/.factory/headless/: runs/<run>/ (run.json, the brief, the CLI's output, report.md), slots/ (the
    concurrency locks), worktrees/ and logs/ (the launchd jobs' output).

Output: everything printed passes factory-doctor's redact() with control characters replaced. The CLI's environment
leaves out every variable whose name looks like a credential, so the CLIs, gh and git use their own stored logins.
Standard library only; Python 3.8 and later, macOS and Linux.
"""

import fcntl
import importlib.util
import json
import os
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True
PROG = "factory-headless"
SETTINGS = "headless.yaml"
LABEL = "local.factory-headless.%s"
CORE_TOOLS = ("factory", "factory-pause", "factory-usage", "factory-settings", "factory-doctor.py",
              "factory-safe-paths.py")

DONE, REFUSED, ENDED, BAD = 0, 3, 2, 64
INT_KEYS = {"max_turns": (1, 1000), "concurrency": (1, 6), "grace_seconds": (1, 300)}
CHOICES = {
    "report": ("status-issue", "none"),
    "claude_permission_mode": ("", "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"),
    "codex_sandbox": ("", "read-only", "workspace-write", "danger-full-access"),
}
TUNING = set(INT_KEYS) | {"timeout_minutes"} | set(CHOICES)
JOB_KEYS = TUNING | {"project", "kind", "role", "spec", "area", "depth", "brief", "window", "at", "heavy", "urgent"}

# What each CLI is asked for. The flags were read from `claude --help` (Claude Code 2.1.322) and `codex exec --help`
# (codex-cli 0.167.0); `start` reads the help again before every run and refuses when one is gone. claude's
# --max-turns is a hidden option (not in --help): the CLI rejects a non-number for it, which shows that it exists.
EFFORTS = {"claude": ("low", "medium", "high", "xhigh", "max"),
           "codex": ("minimal", "low", "medium", "high", "xhigh", "max", "ultra")}
NEEDS = {"claude": ("--model", "--effort", "--output-format", "--verbose", "--include-hook-events", "--setting-sources",
                    "--permission-prompts", "--settings"),
         "codex": ("--model", "--cd", "--json", "--output-last-message", "--config")}
# Codex runs without the factory's Claude Code hooks, so it runs only roles that never push or merge.
CODEX_ROLES = ("reviewer", "validator", "hunter", "process_hunter", "domain_hunter")
REVIEW_ROLES = ("reviewer",)

ROLE = re.compile(r"[a-z][a-z0-9_-]{0,39}")
JOB_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")
KEY_SPEC = re.compile(r"models(\.[a-z0-9_-]+)+")
RUN_ID = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}")
HM = re.compile(r"([01][0-9]|2[0-3]):([0-5][0-9])")
PR_LINE = re.compile(r"PR (https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/([0-9]+)), head ([0-9a-f]{7,40}), "
                     r"checks and reviews (.+)")
LIMIT = re.compile(r"usage limit|rate limit|limit reached|hit your (?:usage )?limit|\b429\b", re.I)
CRED_ENV = re.compile(r"TOKEN|SECRET|PASSW|CREDENTIAL|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY", re.I)
BRIEF_MAX = 256 * 1024
MESSAGE_MAX = 30000
BACKOFF = timedelta(hours=1)
RESET_MAX = timedelta(days=8)    # a usage limit's reset read from a CLI's output is believed up to this far ahead
REFRESH_TIMEOUT = 150            # seconds for `factory-usage refresh claude`, which stops its own CLI after 120


class Stop(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.message, self.code = message, code


class Interrupted(Exception):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def core_bin():
    """The core's bin folder: .factory/bin in a project (this file is in .factory/runtime/headless), core/bin in the
    factory repo (runtime/headless)."""
    for rel in (("..", "..", "bin"), ("..", "..", "core", "bin")):
        d = os.path.normpath(os.path.join(HERE, *rel))
        if all(os.path.isfile(os.path.join(d, f)) for f in CORE_TOOLS):
            return d
    return None


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(BIN, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BIN = core_bin()
doc = paths = None
if BIN:
    try:
        doc = load("factory_doctor", "factory-doctor.py")
        paths = load("factory_safe_paths", "factory-safe-paths.py")
    except Exception:  # noqa: BLE001 (one fixed refusal in main)
        doc = paths = None


# --- output ------------------------------------------------------------------------------------------------------------

def clean(text):
    return re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", " ", str(text))


def redact(text):
    return doc.redact(clean(text))


def say(text):
    sys.stdout.write(redact(text) + "\n")
    sys.stdout.flush()


def note(text):
    sys.stderr.write(redact("%s: %s" % (PROG, text)) + "\n")
    sys.stderr.flush()


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0)


def fmt(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def shown_path(p):
    home = os.environ.get("HOME") or ""
    if home and (p == home or p.startswith(home.rstrip("/") + "/")):
        return "~" + p[len(home.rstrip("/")):]
    return p


# --- commands ----------------------------------------------------------------------------------------------------------

def kill_groups(groups, sig):
    for g in groups:
        try:
            os.killpg(g, sig)
        except OSError:
            pass


def run_cmd(argv, cwd=None, timeout=120, env=None, stdin=None):
    """Run one helper command in its own process group: (exit code, stdout, stderr). 124 when it took too long (its
    group is stopped), 127 when it could not start."""
    try:
        p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=stdin if stdin is not None else subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        return 127, "", "could not start %s" % os.path.basename(argv[0])
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_groups([p.pid], signal.SIGKILL)
        out, err = p.communicate()
        return 124, out.decode("utf-8", "replace"), "took longer than %d seconds" % timeout
    except BaseException:
        kill_groups([p.pid], signal.SIGKILL)
        p.wait()
        raise
    return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def core(tool, *args, cwd=None, timeout=120):
    return run_cmd(["sh", os.path.join(BIN, tool)] + list(args), cwd=cwd, timeout=timeout)


def last_line(text):
    lines = [x.strip() for x in text.splitlines() if x.strip()]
    return lines[-1] if lines else "no output"


def git(cwd, *args, timeout=120):
    return run_cmd(["git", "-C", cwd] + list(args), timeout=timeout)


# --- settings ----------------------------------------------------------------------------------------------------------

def open_factory_dir(create):
    """~/.factory as a checked folder descriptor (factory-safe-paths.py's rule), or None when missing."""
    home = paths.open_home("the headless runtime's settings (~/.factory)")
    try:
        return paths.open_at(home, ".factory", "~/.factory", True, create)
    finally:
        os.close(home)


def read_state_file(name):
    """The text of ~/.factory/<name>, opened by descriptor and checked; None when it does not exist."""
    try:
        fdir = open_factory_dir(False)
        if fdir is None:
            return None
        try:
            fd = paths.open_at(fdir, name, "~/.factory/" + name, False, False)
        finally:
            os.close(fdir)
    except paths.Unsafe as e:
        raise Stop(str(e))
    if fd is None:
        return None
    try:
        return doc.read_machine_fd(fd)
    except (OSError, UnicodeDecodeError) as e:
        raise Stop("~/.factory/%s cannot be read (%s)" % (name, e.__class__.__name__))
    finally:
        os.close(fd)


def check_tuning(where, k, v):
    if k in INT_KEYS:
        lo, hi = INT_KEYS[k]
        if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
            raise Stop("%s.%s: an integer from %d to %d" % (where, k, lo, hi))
    elif k == "timeout_minutes":
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 < v <= 720:
            raise Stop("%s.timeout_minutes: a number above 0 and at most 720" % where)
    elif k in CHOICES and v not in CHOICES[k]:
        raise Stop("%s.%s: one of %s" % (where, k, ", ".join(repr(c) for c in CHOICES[k])))


def window_of(text):
    m = re.fullmatch(r"(\d\d:\d\d)-(\d\d:\d\d)", text or "")
    if not m or not HM.fullmatch(m.group(1)) or not HM.fullmatch(m.group(2)) or m.group(1) == m.group(2):
        return None
    return minutes(m.group(1)), minutes(m.group(2))


def minutes(hm):
    m = HM.fullmatch(hm)
    return int(m.group(1)) * 60 + int(m.group(2))


def in_window(now_min, window):
    start, end = window
    return start <= now_min < end if start < end else (now_min >= start or now_min < end)


def check_job(name, job):
    where = "jobs.%s" % name
    if not JOB_NAME.fullmatch(str(name)):
        raise Stop("jobs: a job name is lower-case letters, digits and dashes, at most 40 (not shown)")
    if not isinstance(job, dict):
        raise Stop("%s: must be a map" % where)
    extra = sorted(str(k) for k in set(job) - JOB_KEYS)
    if extra:
        raise Stop("%s: unknown key %s" % (where, doc.shown(extra[0], quote=False)))
    for k, v in job.items():
        check_tuning(where, k, v)
    if not isinstance(job.get("project"), str) or not os.path.isabs(job["project"]):
        raise Stop("%s.project: the absolute path of the project's root checkout" % where)
    kind = job.get("kind", "hunt")
    if kind not in ("hunt", "brief"):
        raise Stop("%s.kind: hunt or brief" % where)
    if kind == "hunt" and not SLUG.fullmatch(str(job.get("area", ""))):
        raise Stop("%s.area: the hunter area's slug (a hunt job needs one)" % where)
    if kind == "brief" and not (isinstance(job.get("brief"), str) and os.path.isabs(job["brief"])):
        raise Stop("%s.brief: the absolute path of the brief file (a brief job needs one)" % where)
    if kind == "brief" and not isinstance(job.get("role"), str):
        raise Stop("%s.role: a brief job names its role" % where)
    if "role" in job and not ROLE.fullmatch(str(job["role"])):
        raise Stop("%s.role: lower-case letters, digits, _ and -" % where)
    if "spec" in job and not isinstance(job["spec"], str):
        raise Stop("%s.spec: <provider>/<model>/<effort>, or a key of models such as models.agents.hunter" % where)
    if "depth" in job and (isinstance(job["depth"], bool) or not isinstance(job["depth"], int)
                           or not 1 <= job["depth"] <= 9):
        raise Stop("%s.depth: an integer from 1 to 9" % where)
    for k in ("heavy", "urgent"):
        if k in job and not isinstance(job[k], bool):
            raise Stop("%s.%s: true or false" % (where, k))
    if "window" in job and window_of(job["window"]) is None:
        raise Stop('%s.window: "HH:MM-HH:MM" in the machine\'s local time, start and end different' % where)
    if "at" in job:
        if not isinstance(job["at"], str) or not HM.fullmatch(job["at"]):
            raise Stop('%s.at: "HH:MM" in the machine\'s local time' % where)
        if "window" not in job or not in_window(minutes(job["at"]), window_of(job["window"])):
            raise Stop("%s.at: must fall inside the job's window" % where)


def read_settings():
    """(tuning, jobs): the adapter's defaults.yaml, under ~/.factory/headless.yaml's `defaults`, and its jobs."""
    try:
        base = doc.load_yaml(os.path.join(HERE, "defaults.yaml"))
    except (doc.Refused, OSError, UnicodeDecodeError):
        base = None
    if not isinstance(base, dict) or set(base) != TUNING:
        raise Stop("defaults.yaml next to factory-headless is missing or broken; restore the core files with "
                   "factory-update")
    for k, v in base.items():
        check_tuning("defaults.yaml", k, v)
    text = read_state_file(SETTINGS)
    if text is None:
        return dict(base), {}
    try:
        data = doc.Reader(text).parse()
    except doc.Refused as e:
        raise Stop("~/.factory/%s cannot be read: %s" % (SETTINGS, e))
    data = {} if data is None else data
    if not isinstance(data, dict):
        raise Stop("~/.factory/%s is not a map" % SETTINGS)
    found = []
    doc.walk_secrets(data, "", found)
    if found:
        raise Stop("~/.factory/%s: %s looks like a credential (value not shown); no secrets in this file"
                   % (SETTINGS, found[0]))
    extra = sorted(str(k) for k in set(data) - {"defaults", "jobs"})
    if extra:
        raise Stop("~/.factory/%s: unknown key %s (the keys are defaults and jobs)" % (SETTINGS,
                                                                                       doc.shown(extra[0], quote=False)))
    tuning = dict(base)
    own = data.get("defaults") or {}
    if not isinstance(own, dict):
        raise Stop("~/.factory/%s: defaults must be a map" % SETTINGS)
    for k, v in own.items():
        if k not in TUNING:
            raise Stop("defaults: unknown key %s" % doc.shown(str(k), quote=False))
        check_tuning("defaults", k, v)
        tuning[k] = v
    jobs = data.get("jobs") or {}
    if not isinstance(jobs, dict):
        raise Stop("~/.factory/%s: jobs must be a map" % SETTINGS)
    for name, job in jobs.items():
        check_job(name, job)
    return tuning, jobs


def machine_limits():
    """machine.limits: ~/.factory/machine.yaml (judged by factory-doctor's machine check) over the core's defaults."""
    return machine_settings()[0]


def night_window():
    """The machine's shifts.night ("HH:MM-HH:MM", local time), or None when it has none."""
    night = machine_settings()[1].get("night")
    return night if isinstance(night, str) and window_of(night) else None


def machine_settings():
    """(limits, shifts) of the machine settings: ~/.factory/machine.yaml (judged by factory-doctor's machine check,
    shifts included) over the core's defaults."""
    try:
        base = doc.load_yaml(os.path.join(BIN, "..", "defaults.yaml"))
    except (doc.Refused, OSError, UnicodeDecodeError):
        base = None
    machine = base.get("machine") if isinstance(base, dict) else None
    limits = dict(machine.get("limits") or {}) if isinstance(machine, dict) else {}
    shifts = (machine.get("shifts") if isinstance(machine, dict) else None) or {}
    text = read_state_file("machine.yaml")
    if text is not None:
        del doc.OUT[:]
        try:
            parsed = doc.Reader(text).parse()
        except doc.Refused:
            parsed = None
        errs = doc.machine_doc_errors(parsed) if isinstance(parsed, dict) else ["not a map"]
        del doc.OUT[:]
        if errs:
            raise Stop("~/.factory/machine.yaml is not valid; run factory doctor for what to fix")
        limits.update(parsed.get("limits") or {})
        if "shifts" in parsed:
            shifts = parsed.get("shifts") or {}
    for k in ("builders", "reviewers", "test_workers"):
        if isinstance(limits.get(k), bool) or not isinstance(limits.get(k), int) or limits[k] < 1:
            raise Stop("machine.limits.%s has no usable value; run factory doctor" % k)
    return limits, shifts if isinstance(shifts, dict) else {}


def state_dir():
    """~/.factory/headless and its folders, each checked (and made) by factory-safe-paths.py's rule."""
    try:
        fdir = open_factory_dir(True)
        try:
            h = paths.open_at(fdir, "headless", "~/.factory/headless", True, True)
            try:
                for sub in ("runs", "slots", "worktrees", "logs"):
                    os.close(paths.open_at(h, sub, "~/.factory/headless/" + sub, True, True))
            finally:
                os.close(h)
        finally:
            os.close(fdir)
    except paths.Unsafe as e:
        raise Stop(str(e))
    return os.path.join(os.environ["HOME"], ".factory", "headless")


# --- resolve: the spec and the CLI -------------------------------------------------------------------------------------

def resolve_spec(spec, project):
    """(provider, model, effort, spec) from a spec or a key of models; refuses without a model and an effort."""
    if not spec:
        raise Stop("refused: no model and effort; every start names a spec <provider>/<model>/<effort>, or a key of "
                   "models such as models.agents.hunter (runtime/headless.md › start)", REFUSED)
    if KEY_SPEC.fullmatch(spec):
        key = spec
        if not project:
            raise Stop("%s is a key of models: give --project so it is read from that project's factory.yaml" % key,
                       BAD)
        rc, out, _ = core("factory-settings", "--target", project, "--json", key, cwd=project, timeout=120)
        try:
            rows = [r for r in json.loads(out).get("settings", []) if r.get("key") == key] if rc == 0 else []
        except (ValueError, AttributeError):
            rows = []
        if len(rows) != 1 or not isinstance(rows[0].get("value"), str):
            raise Stop("refused: %s could not be read from the project's settings (factory-settings exit %d); "
                       "nothing started" % (key, rc), REFUSED)
        spec = rows[0]["value"]
    m = doc.SPEC.fullmatch(spec)
    if not m:
        raise Stop("refused: the spec is not <provider>/<model>/<effort>; nothing started", REFUSED)
    provider, model, effort = m.groups()
    if not effort:
        raise Stop("refused: the spec %s has no effort; every start names a model and an effort" % spec, REFUSED)
    if provider not in EFFORTS:
        raise Stop("refused: the provider %s has no headless CLI (claude or codex)" % provider, REFUSED)
    if effort not in EFFORTS[provider]:
        raise Stop("refused: %s is not an effort of %s (%s)" % (effort, provider, ", ".join(EFFORTS[provider])),
                   REFUSED)
    return provider, model, effort, spec


def refresh_usage(project):
    """One `factory-usage refresh claude --model <models.helpers.search>`: (its exit code, a one-line note for the
    run's record). The model is read like a spec key (factory-settings, the project's overrides included); one that
    cannot be read, or is not a Claude model, means no refresh (exit 1). Never raises."""
    key = "models.helpers.search"
    rc, out, _ = core("factory-settings", "--target", project, "--json", key, cwd=project, timeout=120)
    try:
        rows = [r for r in json.loads(out).get("settings", []) if r.get("key") == key] if rc == 0 else []
    except (ValueError, AttributeError):
        rows = []
    m = doc.SPEC.fullmatch(rows[0]["value"]) if len(rows) == 1 and isinstance(rows[0].get("value"), str) else None
    if not m or m.group(1) != "claude":
        return 1, "no refresh: %s is not a Claude model that could be read (factory-settings exit %d)" % (key, rc)
    rc, out, err = core("factory-usage", "refresh", "claude", "--model", m.group(2), timeout=REFRESH_TIMEOUT)
    return rc, "refresh exit %d: %s" % (rc, last_line(out + err))


def check_cli(provider, tuning):
    """The CLI's path, after its --help showed every flag the run uses (no model runs)."""
    exe = shutil.which(provider)
    if not exe:
        raise Stop("refused: the %s CLI is not on PATH; nothing started (the launchd job's PATH comes from "
                   "factory-headless plist)" % provider, REFUSED)
    rc, out, err = run_cmd([exe, "--help"] if provider == "claude" else [exe, "exec", "--help"], timeout=60,
                           env=clean_env())
    text = out + "\n" + err
    need = list(NEEDS[provider])
    if provider == "claude" and tuning["claude_permission_mode"]:
        need.append("--permission-mode")
    if provider == "codex" and tuning["codex_sandbox"]:
        need.append("--sandbox")
    missing = [f for f in need if not re.search(r"(?:^|[\s,])%s(?=[\s,=<]|$)" % re.escape(f), text, re.M)]
    if rc != 0 or missing:
        raise Stop("refused: %s's help does not show %s on this machine (a changed CLI version?); nothing started"
                   % (provider, ", ".join(missing) or "its options"), REFUSED)
    return exe


def cli_argv(provider, exe, model, effort, tuning, max_turns, worktree, last_message, settings):
    if provider == "claude":
        argv = [exe, "-p", "--model", model, "--effort", effort, "--max-turns", str(max_turns),
                "--output-format", "stream-json", "--verbose", "--include-hook-events",
                "--setting-sources", "user,project,local", "--settings", settings, "--permission-prompts", "none"]
        if tuning["claude_permission_mode"]:
            argv += ["--permission-mode", tuning["claude_permission_mode"]]
        return argv
    argv = [exe, "exec", "--model", model, "--config", 'model_reasoning_effort="%s"' % effort, "--cd", worktree,
            "--json", "--output-last-message", last_message]
    if tuning["codex_sandbox"]:
        argv += ["--sandbox", tuning["codex_sandbox"]]
    return argv + ["-"]


def clean_env():
    """The runner's environment without a variable whose name looks like a credential: every CLI call gets it, the
    --help probes included."""
    return {k: v for k, v in os.environ.items() if not CRED_ENV.search(k)}


def child_env(limits, shims, real_gh):
    """The run's environment: clean_env(), the run's gh shim first on PATH (merge-guard.py --gh), the real gh for it,
    and the machine's test worker cap."""
    env = clean_env()
    env["PATH"] = shims + os.pathsep + env.get("PATH", "")
    env["FACTORY_HEADLESS_GH"] = real_gh
    env["FACTORY_TEST_WORKERS"] = str(limits["test_workers"])
    return env


def merge_denial(run_dir):
    """The run's merge denial: a settings file with merge-guard.py as an extra PreToolUse hook (Claude Code adds it to
    the user's and the project's own hooks), and a bin folder whose gh refuses merges. (settings path, bin folder)."""
    guard = os.path.join(HERE, "merge-guard.py")
    if not os.path.isfile(guard):
        raise Stop("merge-guard.py next to factory-headless is missing; restore the core files with factory-update")
    settings = os.path.join(run_dir, "headless-settings.json")
    with open(settings, "w", encoding="utf-8") as f:
        json.dump({"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "timeout": 30,
                                                        "command": "python3 -I -B %s --hook" % shlex.quote(guard)}]}]}},
                  f, indent=1)
    shims = os.path.join(run_dir, "bin")
    os.mkdir(shims, 0o700)
    shim = os.path.join(shims, "gh")
    with open(shim, "w", encoding="utf-8") as f:
        f.write('#!/bin/sh\n# The headless run\'s gh: refuses a merge, else runs the real gh.\n'
                'exec python3 -I -B %s --gh "$@"\n' % shlex.quote(guard))
    os.chmod(shim, 0o700)
    return settings, shims


# --- runs --------------------------------------------------------------------------------------------------------------

def save(run):
    path = os.path.join(run["dir"], "run.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({k: v for k, v in run.items() if k != "dir"}, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def load_run(state, rid):
    if not RUN_ID.fullmatch(rid or ""):
        raise Stop("a run id looks like 20261117T013000Z-1a2b3c (factory-headless runs lists them)", BAD)
    d = os.path.join(state, "runs", rid)
    try:
        with open(os.path.join(d, "run.json"), encoding="utf-8") as f:
            run = json.load(f)
    except (OSError, ValueError):
        raise Stop("no run %s on this machine" % rid)
    run["dir"] = d
    return run


def all_runs(state):
    d = os.path.join(state, "runs")
    out = []
    for rid in sorted(os.listdir(d), reverse=True):
        if RUN_ID.fullmatch(rid):
            try:
                out.append(load_run(state, rid))
            except Stop:
                pass
    return out


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def take_slot(state, pool, cap):
    """An open, exclusively locked slot file of the pool, or None when all `cap` are held. The descriptor is
    close-on-exec, so the CLI never holds it: this runner does, and its guard (start_guard), which keeps it across the
    fork. The slot frees when both are gone."""
    for i in range(cap):
        fd = os.open(os.path.join(state, "slots", "%s-%d.lock" % (pool, i)),
                     os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            os.close(fd)
    return None


def backed_off(state, provider):
    try:
        with open(os.path.join(state, "backoff-" + provider), encoding="utf-8") as f:
            at = datetime.strptime(f.read().strip(), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (OSError, ValueError):
        return False
    return utc_now() - at < BACKOFF


def tree_groups(root):
    """The process groups of root and of every process below it (ps), never this runner's own."""
    rc, out, _ = run_cmd(["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid="], timeout=30)
    kids, group = {}, {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 3 and all(x.isdigit() for x in f):
            pid, ppid, pgid = (int(x) for x in f)
            kids.setdefault(ppid, []).append(pid)
            group[pid] = pgid
    groups, stack, seen = {root}, [root], set()
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        if p in group:
            groups.add(group[p])
        stack.extend(kids.get(p, []))
    return groups - {os.getpgrp(), 0, 1}


def group_alive(g):
    try:
        os.killpg(g, 0)
        return True
    except OSError:
        return False


def stop_tree(proc, grace):
    """SIGTERM to the run's process group and every group below it, SIGKILL to what is left after the grace."""
    groups = tree_groups(proc.pid)
    kill_groups(groups, signal.SIGTERM)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if proc.poll() is not None and not any(group_alive(g) for g in groups):
            break
        time.sleep(0.1)
    if proc.poll() is None:
        groups |= tree_groups(proc.pid)
    kill_groups([g for g in groups if group_alive(g)], signal.SIGKILL)
    proc.wait()


def other_hunts(state):
    out = {}
    for r in all_runs(state):
        if r.get("status") == "running" and r.get("area") and alive(r.get("pid") or -1):
            out[r["area"]] = r["id"]
    return out


def project_name(project):
    rc, out, _ = git(project, "remote", "get-url", "origin", timeout=30)
    name = out.strip().rstrip("/").split("/")[-1].split(":")[-1] if rc == 0 else ""
    name = name[:-4] if name.endswith(".git") else name
    name = re.sub(r"[^A-Za-z0-9._-]", "-", name or os.path.basename(project)).lstrip("._-")[:100]
    return name or "-"


def default_branch(project):
    rc, out, _ = git(project, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", timeout=30)
    if rc == 0 and out.strip().startswith("origin/"):
        return out.strip()[len("origin/"):]
    rc, out, _ = run_cmd(["gh", "repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"],
                         cwd=project, timeout=60)
    name = out.strip()
    if rc != 0 or not re.fullmatch(r"[A-Za-z0-9._/-]+", name or ""):
        raise Stop("cannot tell the default branch (git symbolic-ref refs/remotes/origin/HEAD and gh repo view "
                   "both failed)")
    return name


def make_worktree(project, state, rid):
    """A new worktree of the project, detached at origin/<default> just fetched: (path, default branch, sha)."""
    rc, _, err = git(project, "fetch", "origin", "--quiet", timeout=600)
    if rc != 0:
        raise Stop("git fetch origin failed in the project (%s)" % last_line(err))
    branch = default_branch(project)
    rc, sha, _ = git(project, "rev-parse", "--verify", "origin/%s^{commit}" % branch, timeout=30)
    if rc != 0:
        raise Stop("origin/%s is not a commit in the project" % branch)
    path = os.path.join(state, "worktrees", rid)
    rc, _, err = git(project, "worktree", "add", "--detach", path, sha.strip(), timeout=600)
    if rc != 0:
        raise Stop("git worktree add failed (%s)" % last_line(err))
    return path, branch, sha.strip()


def clean_worktree(project, wt):
    """Remove a finished run's worktree, or keep it and say why. Its git lock (taken while the run lives, so factory gc
    never takes a live run's worktree) is released first either way: a kept worktree is then one factory gc judges by
    its own rules, like any other worktree of the project."""
    git(project, "worktree", "unlock", wt, timeout=60)
    rc, out, _ = git(wt, "status", "--porcelain", timeout=60)
    if rc != 0:
        return "kept: its state cannot be read"
    if out.strip():
        return "kept: uncommitted work"
    rc, out, _ = git(wt, "rev-list", "HEAD", "--not", "--remotes", timeout=60)
    if rc != 0 or out.strip():
        return "kept: commits that are on no remote branch"
    rc, _, _ = git(project, "worktree", "remove", wt, timeout=120)
    return "removed" if rc == 0 else "kept: git worktree remove failed"


def hooks_wired(worktree):
    """factory-doctor's hook check on the worktree: (ok, why)."""
    del doc.OUT[:]
    try:
        doc.check_hooks(worktree)
        rows = [r.split("\t") for r in doc.OUT if r.startswith("R\thooks\t")]
    finally:
        del doc.OUT[:]
    if rows and rows[0][2] == "ok":
        return True, ""
    return False, rows[0][3] if rows else "the hook check gave no answer"


def read_text(path, limit=None):
    try:
        with open(path, "rb") as f:
            data = f.read() if limit is None else f.read(limit + 1)
    except OSError:
        return ""
    return data.decode("utf-8", "replace")


def tail(path, size=16384):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - size))
            return f.read().decode("utf-8", "replace")
    except OSError:
        return ""


def parse_claude(path):
    """What the stream-json output says: the result message, the turns, the session, hook events, tool calls."""
    info = {"subtype": None, "is_error": None, "result": "", "turns": None, "session": None, "hooks": 0, "tools": 0,
            "models": None}
    try:
        f = open(path, "rb")
    except OSError:
        return info
    with f:
        for raw in f:
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            kind = o.get("type")
            if kind == "system" and str(o.get("subtype", "")).startswith("hook"):
                info["hooks"] += 1
            elif kind == "assistant":
                content = (o.get("message") or {}).get("content") if isinstance(o.get("message"), dict) else None
                if isinstance(content, list):
                    info["tools"] += sum(1 for c in content if isinstance(c, dict) and c.get("type") == "tool_use")
            elif kind == "result":
                info["subtype"] = o.get("subtype")
                info["is_error"] = o.get("is_error")
                info["result"] = o.get("result") if isinstance(o.get("result"), str) else ""
                info["turns"] = o.get("num_turns") if isinstance(o.get("num_turns"), int) else None
                info["session"] = o.get("session_id") if isinstance(o.get("session_id"), str) else None
                info["models"] = sorted(o["modelUsage"]) if isinstance(o.get("modelUsage"), dict) else None
    return info


# --- one run -----------------------------------------------------------------------------------------------------------

def compose_brief(req, run, branch, sha, state):
    send = read_text(os.path.join(HERE, "send-report.txt")).strip()
    if req["kind"] == "hunt":
        others = other_hunts(state)
        timeout = req["timeout_minutes"]
        box = max(1, int(timeout - max(5, timeout / 8)))
        text = read_text(os.path.join(HERE, "hunt-brief.txt")).strip()
        for k, v in (("AREA", req["area"]), ("DEPTH", str(req.get("depth", 1))), ("TIME_BOX", str(box)),
                     ("TIMEOUT", "%g" % timeout), ("SHA", sha), ("DEFAULT", branch),
                     ("OTHERS", ", ".join(sorted(others)) or "none")):
            text = text.replace("<<%s>>" % k, v)
    else:
        text = req["brief_text"].strip()
    if not send or (req["kind"] == "hunt" and "<<" in text):
        raise Stop("send-report.txt or hunt-brief.txt next to factory-headless is missing or broken; restore the core "
                   "files with factory-update")
    path = os.path.join(run["dir"], "brief.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text + "\n\n" + send + "\n")
    return path


def report_text(run):
    title = run.get("job") or run.get("name")
    lines = ["### Headless run: %s (%s)" % (title, run["id"]), ""]
    if run["status"].startswith("refused") or (run["status"].startswith("error") and not run.get("started")):
        lines += ["%s. Nothing was started (%s)." % (run["status"][0].upper() + run["status"][1:], run["ended"]), ""]
        return "\n".join(lines)
    rows = [("Status", run["status"] + (": " + run["why"] if run.get("why") else "")),
            ("Project", run.get("project_name", "-")),
            ("Role and spec", "%s, %s" % (run["role"], run["spec"])),
            ("Started, ended", "%s, %s (UTC)" % (run.get("started", "-"), run.get("ended", "-")))]
    if run["provider"] == "claude":
        rows.append(("Turns", "%s of at most %s" % (run.get("turns") if run.get("turns") is not None
                                                   else "not reported", run["max_turns"])))
        rows.append(("Hook events", str(run.get("hooks", 0))))
        if run.get("session"):
            rows.append(("Session", "%s (`claude --resume %s` in the worktree)" % (run["session"], run["session"])))
    else:
        rows.append(("Turns", "not capped: Codex has no turn limit, the time cap applies"))
    rows += [("Time cap", "%g minutes" % run["timeout_minutes"]),
             ("Worktree", run.get("worktree_state", "-") + (" at %s" % shown_path(run["worktree"])
                                                           if run.get("worktree_state", "").startswith("kept") else "")),
             ("Ledger", run.get("ledger") or "-")]
    if run.get("refresh"):
        rows.append(("Usage refresh", run["refresh"]))
    if run.get("pr"):
        rows.append(("PR", "%s; factory gate: %s" % (run["pr"], run.get("gate", "not run"))))
    lines += ["| | |", "| --- | --- |"] + ["| %s | %s |" % (k, str(v).replace("|", "\\|")) for k, v in rows] + [""]
    for w in run.get("warnings", []):
        lines += ["**Warning:** %s" % w, ""]
    if run["status"] != "done":
        message = run.get("message") or "(no final message: the run ended before it wrote one)"
        lines += ["<details><summary>The run's final message</summary>", "", "```text",
                  message[-MESSAGE_MAX:].replace("```", "'''"), "```", "", "</details>", ""]
    elif run.get("message_last"):
        lines += ["Its report ends: `%s`" % run["message_last"].replace("`", "'"), ""]
    lines += ["Gate tail:", "", "```text", run["gate_tail"], "```", ""] if run.get("gate_tail") else []
    return "\n".join(lines)


def post(project, path):
    rc, out, err = run_cmd(["gh", "issue", "list", "--label", "factory:status", "--state", "open", "--limit", "2",
                            "--json", "number", "--jq", ".[].number"], cwd=project, timeout=120)
    nums = out.split()
    if rc != 0 or len(nums) != 1 or not nums[0].isdigit():
        note("the report was not posted: the status issue (one open issue labelled factory:status) was not found")
        return None
    rc, _, _ = run_cmd(["gh", "issue", "comment", nums[0], "--body-file", path], cwd=project, timeout=120)
    if rc != 0:
        note("the report was not posted on #%s (gh issue comment failed)" % nums[0])
        return None
    return nums[0]


def finish(run, req, status, why=""):
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, quiet_signal)
    run["status"], run["ended"] = status, fmt(utc_now())
    if why:
        run["why"] = why
    path = os.path.join(run["dir"], "report.md")
    text = redact(report_text(run))
    with open(path, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    save(run)
    if req.get("report") == "status-issue" and req.get("project_ok"):
        run["posted"] = post(req["project"], path)
    save(run)
    say(text)
    if status == "done":
        return DONE
    return REFUSED if status.startswith("refused") else ENDED


def on_signal(signum, frame):
    raise Interrupted(signum)


def quiet_signal(signum, frame):
    pass


def execute(req, state):
    """One run, start to report. `req` holds the job's settings; see runtime/headless.md › start."""
    rid = utc_now().strftime("%Y%m%dT%H%M%SZ") + "-" + os.urandom(3).hex()
    run = {"id": rid, "dir": os.path.join(state, "runs", rid), "job": req.get("job"), "name": req["name"],
           "role": req["role"], "spec": req.get("spec") or "-", "provider": "-", "status": "starting",
           "max_turns": req["max_turns"], "timeout_minutes": req["timeout_minutes"], "area": req.get("area"),
           "runner_pid": os.getpid(), "warnings": [], "project": req["project"], "report": req["report"],
           "grace_seconds": req["grace_seconds"]}
    os.mkdir(run["dir"], 0o700)
    save(run)
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, on_signal)
    worktree = slot = ledger = guard = None
    project = req["project"]
    try:
        # A run whose runner and guard both died is ended first, whatever this start turns out to be.
        recover_stale(state, rid)

        # Refusals: nothing has started yet, and no CLI has been called, not even for its help.
        rc, top, _ = git(project, "rev-parse", "--show-toplevel", timeout=30)
        if rc != 0 or os.path.realpath(top.strip()) != os.path.realpath(project):
            return finish(run, req, "refused: %s is not the root of a git checkout" % shown_path(project))
        req["project_ok"] = True
        run["project_name"] = project_name(project)
        if not ROLE.fullmatch(req["role"] or ""):
            return finish(run, req, "refused: the role is lower-case letters, digits, _ and -")
        fg = shutil.which("factory-github") or os.path.join(os.environ.get("HOME", "/nonexistent"), ".factory", "bin",
                                                            "factory-github")
        if os.access(fg, os.X_OK):
            rc, out, _ = run_cmd([fg, "mode"], timeout=30)
            if rc != 0 or out.strip() != "off":
                return finish(run, req, "refused: agent-token mode is not off here, and the headless runtime runs "
                                        "only with it off (runtime/headless.md › Security)")
        try:
            provider, model, effort, spec = resolve_spec(req.get("spec"), project)
        except Stop as e:
            if e.code != REFUSED:
                raise
            return finish(run, req, e.message)
        run.update(provider=provider, model=model, effort=effort, spec=spec)
        if provider == "codex" and req["role"] not in CODEX_ROLES:
            return finish(run, req, "refused: Codex runs without the factory's Claude Code hooks, so it runs only "
                                    "roles that never push or merge (%s)" % ", ".join(CODEX_ROLES))
        why = paused(project)
        if why:
            return finish(run, req, "refused: " + why)
        args = ["may-start", provider] + (["--urgent"] if req.get("urgent") else [])
        rc, out, err = core("factory-usage", *args, timeout=60)
        after = ""
        if rc == 1 and provider == "claude":
            # Cannot tell: one refresh of the Claude figure (its own hourly guard is the only rate limit), then
            # may-start once more. Never a second refresh, never a loop.
            first = last_line(out + err)
            rrc, run["refresh"] = refresh_usage(project)
            save(run)
            if rrc != 0:
                return finish(run, req, "refused: factory-usage may-start claude answered cannot tell (%s), and the "
                                        "refresh %s (%s)" % (first, "answered no" if rrc == 3 else "did not help",
                                                             run["refresh"]))
            rc, out, err = core("factory-usage", *args, timeout=60)
            after = " after a refresh (%s)" % run["refresh"]
        if rc != 0:
            return finish(run, req, "refused: factory-usage may-start %s answered %s%s (%s)" % (
                provider, "no" if rc == 3 else "cannot tell", after, last_line(out + err)))
        try:
            exe = check_cli(provider, req)
        except Stop as e:
            return finish(run, req, e.message)
        real_gh = shutil.which("gh")
        if not real_gh:
            return finish(run, req, "refused: gh is not on PATH; a run needs it for its report")
        limits = machine_limits()
        pool = "reviewers" if req["role"] in REVIEW_ROLES else "builders"
        cap = min(req["concurrency"], limits[pool])
        if backed_off(state, provider):
            cap = max(1, cap // 2)
        slot = take_slot(state, pool, cap)
        if slot is None:
            return finish(run, req, "refused: cap: concurrency (%d headless %s run(s) at once on this machine, all "
                                    "taken)" % (cap, pool[:-1]))
        if req.get("area"):
            busy = other_hunts(state)
            if req["area"] in busy:
                return finish(run, req, "refused: area %s is being hunted by run %s (one hunter per area)"
                              % (req["area"], busy[req["area"]]))

        # The worktree, the brief, the merge denial and the ledger.
        worktree, branch, sha = make_worktree(project, state, rid)
        run.update(worktree=worktree, base=sha)
        rc, _, err = git(project, "worktree", "lock", "--reason", "factory-headless run %s" % rid, worktree, timeout=60)
        if rc != 0:
            raise Stop("git worktree lock failed (%s)" % last_line(err))
        if not os.path.isfile(os.path.join(worktree, "factory.yaml")):
            return finish(run, req, "refused: origin/%s has no factory.yaml: not a factory project" % branch)
        if provider == "claude":
            ok, why = hooks_wired(worktree)
            if not ok:
                return finish(run, req, "refused: the factory's hooks are not wired on origin/%s (%s), and a "
                                        "headless Claude Code run never starts without them" % (branch, why))
        brief = compose_brief(req, run, branch, sha, state)
        settings, shims = merge_denial(run["dir"])
        rc, out, err = core("factory-usage", "start", "--spec", spec, "--project", run["project_name"], "--role",
                            req["role"], timeout=60)
        if rc != 0 or not re.fullmatch(r"r[0-9a-f]{16}", out.strip()):
            return finish(run, req, "refused: the usage ledger did not record the start (factory-usage start exit "
                                    "%d)" % rc)
        ledger = out.strip()
        run["ledger"] = ledger

        # The run. The CLI does not hold the slot: the runner and its guard do, so the slot frees only when both
        # are gone, and a run whose runner dies is ended by the guard at once.
        last = os.path.join(run["dir"], "last-message.md")
        argv = cli_argv(provider, exe, model, effort, req, req["max_turns"], worktree, last, settings)
        if req.get("heavy"):
            argv = ["sh", os.path.join(BIN, "factory"), "lock", "heavy", "--"] + argv
        run["cli"] = os.path.basename(exe)
        out_path, err_path = os.path.join(run["dir"], "out.log"), os.path.join(run["dir"], "err.log")
        killed = ""
        with open(brief, "rb") as fin, open(out_path, "wb") as fout, open(err_path, "wb") as ferr:
            # A signal from just before the spawn until the run's state is recorded is deferred, not raised: it could
            # otherwise land after Popen started the CLI but before the handle exists. It is acted on just before the
            # wait. And whatever else stops this code before the wait has settled (an error in save or start_guard),
            # the finally stops the CLI's process tree, so nothing runs on without a cap or a slot.
            deferred = []
            for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(s, lambda signum, frame: deferred.append(signum))
            proc, settled = None, False
            try:
                proc = subprocess.Popen(argv, cwd=worktree, env=child_env(limits, shims, real_gh), stdin=fin,
                                        stdout=fout, stderr=ferr, start_new_session=True)
                run.update(status="running", started=fmt(utc_now()), pid=proc.pid)
                save(run)
                guard = start_guard(run, slot)
                run["guard_pid"] = guard[0]
                save(run)
                try:
                    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                        signal.signal(s, on_signal)
                    if deferred:
                        raise Interrupted(deferred[0])
                    rc = proc.wait(timeout=req["timeout_minutes"] * 60)
                except subprocess.TimeoutExpired:
                    killed = "cap: time"
                except Interrupted as e:
                    killed = "cancelled" if os.path.exists(os.path.join(run["dir"], "cancel")) else \
                        "stopped by signal %d" % e.signum
                for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                    signal.signal(s, quiet_signal)
                if killed:
                    stop_tree(proc, req["grace_seconds"])
                    rc = proc.returncode
                settled = True
            finally:
                if not settled:
                    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                        signal.signal(s, quiet_signal)
                    if proc is not None:
                        stop_tree(proc, req["grace_seconds"])
        run["exit"] = rc
        end_ledger(ledger)
        ledger = None
        run["ledger_ended"] = True
        save(run)
        return conclude(run, req, state, provider, model, killed, rc, out_path, err_path, last)
    except Interrupted as e:
        if run.get("started"):
            return finish(run, req, "stopped by signal %d" % e.signum)
        return finish(run, req, "refused: stopped by signal %d before the run started" % e.signum)
    except Stop as e:
        finish(run, req, "error: " + e.message)
        return e.code
    except Exception as e:  # noqa: BLE001 (a failed fork or write after the start: the run still ends with a report)
        if not run.get("started"):
            raise
        finish(run, req, "error: %s after the CLI started; the CLI was stopped" % e.__class__.__name__)
        return 1
    finally:
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(s, quiet_signal)
        if ledger:
            end_ledger(ledger)
            run["ledger_ended"] = True
            save(run)
        if worktree and not run.get("worktree_state"):
            run["worktree_state"] = clean_worktree(project, worktree)
            save(run)
        if guard:
            stop_guard(guard)
        if slot is not None:
            os.close(slot)


# --- the guard and stale runs ------------------------------------------------------------------------------------------

def start_guard(run, slot):
    """Fork the run's guard: a process in a session of its own that holds the slot too and waits on a pipe from the
    runner. The runner writes "ok" and closes the pipe when it is done; an end of the pipe without it means the runner
    died (SIGKILL, a crash), and the guard then ends the run at once: its processes, its ledger run, its report.
    Returns (guard pid, write end of the pipe)."""
    rfd, wfd = os.pipe()
    pid = os.fork()
    if pid == 0:
        code = 0
        try:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            for s in (signal.SIGINT, signal.SIGHUP):
                signal.signal(s, signal.SIG_IGN)
            os.setsid()
            os.close(wfd)
            keep = sorted({rfd, slot})
            low = 3
            for fd in keep:
                os.closerange(low, fd)
                low = fd + 1
            os.closerange(low, 4096)
            seen = b""
            while True:
                chunk = os.read(rfd, 64)
                if not chunk:
                    break
                seen += chunk
            if b"ok" not in seen:
                reconcile(run["dir"], "the runner died", force=True)
        except BaseException:  # noqa: B036 (the guard never returns into the runner's code)
            code = 1
        finally:
            os._exit(code)
    os.close(rfd)
    return pid, wfd


def stop_guard(guard):
    pid, wfd = guard
    try:
        os.write(wfd, b"ok")
    except OSError:
        pass
    os.close(wfd)
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass


def ours(pid, needle):
    """True when process `pid` lives and its command line holds `needle` (a recorded process id may be reused)."""
    if not isinstance(pid, int) or pid <= 1 or not alive(pid):
        return False
    rc, out, _ = run_cmd(["ps", "-o", "command=", "-p", str(pid)], timeout=30)
    return rc == 0 and needle in out


def reconcile(run_dir, reason, force=False):
    """End a run whose runner is gone: stop its CLI's process groups (SIGTERM, SIGKILL after the grace), end its ledger
    run, keep or remove its worktree, and write and post its report. Holds the run's reconcile lock, so it runs once;
    a run that already ended is left alone. `force`: the caller knows the runner is gone (its guard)."""
    try:
        lock = os.open(os.path.join(run_dir, "reconcile.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                       0o600)
    except OSError:
        return False
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        try:
            with open(os.path.join(run_dir, "run.json"), encoding="utf-8") as f:
                run = json.load(f)
        except (OSError, ValueError):
            return False
        run["dir"] = run_dir
        if run.get("status") not in ("starting", "running"):
            return False
        if not force and (ours(run.get("runner_pid"), "factory-headless")
                          or ours(run.get("guard_pid"), "factory-headless")):
            return False
        pid, grace = run.get("pid"), run.get("grace_seconds", 30)
        if isinstance(pid, int) and ours(pid, run.get("cli") or "-"):
            groups = tree_groups(pid)
            kill_groups(groups, signal.SIGTERM)
            deadline = time.monotonic() + grace
            while time.monotonic() < deadline and any(group_alive(g) for g in groups):
                time.sleep(0.1)
            kill_groups([g for g in groups if group_alive(g)], signal.SIGKILL)
        if run.get("ledger") and not run.get("ledger_ended"):
            end_ledger(run["ledger"])
            run["ledger_ended"] = True
        if run.get("worktree") and os.path.isdir(run["worktree"]) and not run.get("worktree_state"):
            run["worktree_state"] = clean_worktree(run["project"], run["worktree"])
        if run.get("provider") == "claude" and run.get("started"):
            info = parse_claude(os.path.join(run_dir, "out.log"))
            run.update(turns=info["turns"], hooks=info["hooks"], session=info["session"], message=info["result"])
        elif run.get("started"):
            run["message"] = read_text(os.path.join(run_dir, "last-message.md"), MESSAGE_MAX * 2).strip()
        if not run.get("started"):
            reason += " before the run started"
        req = {"report": run.get("report"), "project": run.get("project"), "project_ok": bool(run.get("project"))}
        finish(run, req, "stopped: " + reason)
        return True
    finally:
        os.close(lock)


def recover_stale(state, current=None):
    """End every run whose runner and guard are both gone (a SIGKILL of both, a reboot): see reconcile()."""
    for r in all_runs(state):
        if r["id"] != current and r.get("status") in ("starting", "running"):
            reconcile(r["dir"], "its runner and guard died; ended by a later start")


def end_ledger(ledger):
    rc, _, _ = core("factory-usage", "end", ledger, timeout=60)
    if rc != 0:
        note("the usage ledger did not record the end of %s (factory-usage end exit %d); add it by hand: "
             "factory-usage end %s" % (ledger, rc, ledger))


def conclude(run, req, state, provider, model, killed, rc, out_path, err_path, last):
    """The run has ended: its status, the back-off, the gate for a reported PR, the worktree, the report."""
    if provider == "claude":
        info = parse_claude(out_path)
        message = info["result"] or ""
        run.update(turns=info["turns"], hooks=info["hooks"], session=info["session"])
        if info["tools"] and not info["hooks"]:
            run["warnings"].append("the run called tools but the output shows no hook event: check that the factory's "
                                   "hooks loaded (runtime/headless.md › Hooks)")
        if info["models"] and not any(m == model or m.startswith(model + "[") for m in info["models"]):
            run["warnings"].append("the CLI reports model(s) %s, not %s: a silent model switch; tell the owner"
                                   % (", ".join(info["models"]), model))
        if killed:
            status = killed
        elif info["subtype"] == "error_max_turns":
            status = "cap: turns"
        elif info["subtype"] == "success" and not info["is_error"] and rc == 0:
            status = "done"
        elif LIMIT.search(message + "\n" + tail(err_path)):
            status = "limit"
        else:
            status = "failed"
    else:
        message = read_text(last, MESSAGE_MAX * 2).strip()
        if killed:
            status = killed
        elif rc == 0 and message:
            status = "done"
        elif LIMIT.search(message + "\n" + tail(err_path) + "\n" + tail(out_path, 4096)):
            status = "limit"
        else:
            status = "failed"
    run["message"] = message
    lines = [x.strip() for x in message.splitlines() if x.strip()]
    run["message_last"] = lines[-1] if lines else ""
    why = {"cap: time": "stopped at %g minutes" % req["timeout_minutes"],
           "cap: turns": "the CLI stopped at %d turns" % req["max_turns"],
           "limit": "the provider answered with a usage limit; recorded in the usage ledger"}.get(status, "")
    if status == "limit":
        reset = limit_reset(provider, out_path)
        run["limit_reset"] = fmt(reset) if reset else None
        core("factory-usage", "limit", provider, *(["--reset", fmt(reset)] if reset else []), timeout=60)
        why += "; it resets %s (UTC)" % fmt(reset) if reset else "; its reset time was not in the CLI's output"
        try:
            with open(os.path.join(state, "backoff-" + provider), "w", encoding="utf-8") as f:
                f.write(fmt(utc_now()) + "\n")
        except OSError:
            pass
    m = PR_LINE.fullmatch(run["message_last"])
    if m and status == "done":
        run["pr"] = m.group(1)
        rc, out, err = core("factory", "gate", m.group(2), cwd=req["project"], timeout=900)
        run["gate"] = {0: "pass", 2: "fail"}.get(rc, "could not judge (exit %d)" % rc)
        run["gate_tail"] = "\n".join((out + err).strip().splitlines()[-15:])
    if run.get("worktree"):
        run["worktree_state"] = clean_worktree(req["project"], run["worktree"])
    return finish(run, req, status, why)


def limit_reset(provider, out_path):
    """When the usage limit that ended a run resets, from the CLI's own JSON output, else None. Claude: the last
    rate_limit_event whose rate_limit_info has status "rejected", its resetsAt (Unix seconds). Codex: the last event
    with rate_limits (at the top, or in payload or msg) where a window's used_percent is 100 or more, its resets_at
    (Unix seconds), the latest of those windows. Only a time after now and at most RESET_MAX ahead is believed; the
    last such event decides, so one whose reset is missing or not believable gives None, whatever came before it.
    Other lines change nothing. The message text is never parsed for a time."""
    now = utc_now()
    found = None
    try:
        f = open(out_path, "rb")
    except OSError:
        return None
    with f:
        for raw in f:
            if len(raw) > 1024 * 1024 or (b"rate_limit" not in raw):
                continue
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            stamps = []
            if provider == "claude":
                info = o.get("rate_limit_info") if o.get("type") == "rate_limit_event" else None
                if isinstance(info, dict) and info.get("status") == "rejected":
                    stamps.append(info.get("resetsAt"))
            else:
                for holder in (o, o.get("payload"), o.get("msg")):
                    rl = holder.get("rate_limits") if isinstance(holder, dict) else None
                    if not isinstance(rl, dict):
                        continue
                    for w in rl.values():
                        pct = w.get("used_percent") if isinstance(w, dict) else None
                        if isinstance(pct, (int, float)) and not isinstance(pct, bool) and pct >= 100:
                            stamps.append(w.get("resets_at"))
            if not stamps:
                continue   # not a limit event: the candidate stands
            # A limit event replaces the candidate: with its reset when every reset it carries is believable, else
            # with none (an older event's time is never kept past a newer limit that does not confirm it).
            times = [believed_reset(v, now) for v in stamps]
            found = max(times) if all(times) else None
    return found


def believed_reset(v, now):
    """A reset given as Unix seconds: a datetime after now and at most RESET_MAX ahead, else None."""
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return None
    try:
        t = datetime.fromtimestamp(int(v), timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return t if now < t <= now + RESET_MAX else None


def paused(project):
    """None when the factory may go on, else why not (factory-pause status; exit 1 is tried once more)."""
    for _ in (1, 2):
        rc, _, _ = core("factory-pause", "status", "-q", cwd=project, timeout=120)
        if rc == 0:
            return None
        if rc == 3:
            return "paused (factory:paused on the status issue)"
    return "the emergency stop cannot be read (factory-pause status failed twice), which counts as paused"


# --- subcommands -------------------------------------------------------------------------------------------------------

def take_args(args, flags, switches):
    """(values, switches set, positional): --flag VALUE for flags, --switch for switches."""
    got, on, pos = {}, set(), []
    i = 0
    while i < len(args):
        a = args[i]
        if a in flags:
            if i + 1 >= len(args):
                raise Stop("%s needs a value" % a, BAD)
            got[a] = args[i + 1]
            i += 2
            continue
        if a in switches:
            on.add(a)
        elif a.startswith("-"):
            raise Stop("unknown option (not shown); see --help", BAD)
        else:
            pos.append(a)
        i += 1
    return got, on, pos


def number(text, flag, kind):
    try:
        v = kind(text)
    except ValueError:
        raise Stop("%s: a number" % flag, BAD)
    return v


def cmd_start(args):
    got, on, pos = take_args(args, {"--project", "--role", "--spec", "--brief", "--name", "--max-turns",
                                    "--timeout-minutes"}, {"--heavy", "--urgent"})
    if pos:
        raise Stop("start takes only options; see --help", BAD)
    for f in ("--project", "--role", "--brief"):
        if f not in got:
            raise Stop("start needs %s; see --help" % f, BAD)
    tuning, _ = read_settings()
    req = dict(tuning)
    if "--max-turns" in got:
        req["max_turns"] = number(got["--max-turns"], "--max-turns", int)
    if "--timeout-minutes" in got:
        req["timeout_minutes"] = number(got["--timeout-minutes"], "--timeout-minutes", float)
    for k in ("max_turns", "timeout_minutes"):
        try:
            check_tuning("option", k, req[k])
        except Stop as e:
            raise Stop(e.message, BAD)
    text = read_text(got["--brief"], BRIEF_MAX)
    if not text.strip() or len(text) > BRIEF_MAX:
        raise Stop("--brief: a readable, non-empty file of at most %d KiB" % (BRIEF_MAX // 1024), BAD)
    if doc.SECRET.search(text) or doc.ANY_FRAGMENT.search(text):
        raise Stop("refused: the brief holds something that looks like a credential (not shown); no secrets in a "
                   "brief", REFUSED)
    req.update(project=os.path.abspath(got["--project"]), role=got["--role"], spec=got.get("--spec"), kind="brief",
               brief_text=text, name=got.get("--name") or got["--role"], job=None, heavy="--heavy" in on,
               urgent="--urgent" in on)
    return execute(req, state_dir())


def cmd_run(args):
    _, on, pos = take_args(args, set(), {"--now", "--urgent"})
    if len(pos) != 1:
        raise Stop("run takes one job name; see --help", BAD)
    tuning, jobs = read_settings()
    name = pos[0]
    if name not in jobs:
        raise Stop("no job %s in ~/.factory/%s" % (doc.shown(name, quote=False), SETTINGS))
    job = jobs[name]
    req = dict(tuning)
    req.update({k: v for k, v in job.items() if k in TUNING})
    kind = job.get("kind", "hunt")
    role = job.get("role") or ("process_hunter" if job.get("area") == "process" else "hunter")
    spec = job.get("spec") or ("models.agents.%s" % role if kind == "hunt" else None)
    req.update(project=job["project"], role=role, spec=spec, kind=kind, area=job.get("area") if kind == "hunt" else None,
               depth=job.get("depth", 1), name=name, job=name, heavy=job.get("heavy", False),
               urgent=job.get("urgent", False) or "--urgent" in on)
    state = state_dir()
    if kind == "brief":
        text = read_text(job["brief"], BRIEF_MAX)
        if not text.strip() or len(text) > BRIEF_MAX or doc.SECRET.search(text) or doc.ANY_FRAGMENT.search(text):
            raise Stop("jobs.%s.brief: a readable, non-empty file of at most %d KiB, with nothing that looks like a "
                       "credential" % (name, BRIEF_MAX // 1024))
        req["brief_text"] = text
    window, whose = job_window(job)
    if window and "--now" not in on:
        now = datetime.now()
        if not in_window(now.hour * 60 + now.minute, window_of(window)):
            run = {"id": utc_now().strftime("%Y%m%dT%H%M%SZ") + "-" + os.urandom(3).hex(), "job": name, "name": name,
                   "role": role, "spec": spec or "-", "provider": "-", "warnings": []}
            run["dir"] = os.path.join(state, "runs", run["id"])
            os.mkdir(run["dir"], 0o700)
            req["project_ok"] = os.path.isdir(job["project"])
            return finish(run, req, "refused: outside %s %s (local time %02d:%02d); a late start after sleep runs "
                                    "nothing" % (whose, window, now.hour, now.minute))
    return execute(req, state)


def job_window(job):
    """(window, whose) of a job: its own window, else the machine's shifts.night, else (None, None): run by hand."""
    if "window" in job:
        return job["window"], "the job's window"
    night = night_window()
    return (night, "the machine's night window (shifts.night)") if night else (None, None)


def cmd_result(args):
    if len(args) != 1:
        raise Stop("result takes one run id", BAD)
    run = load_run(state_dir(), args[0])
    text = read_text(os.path.join(run["dir"], "report.md"))
    if text:
        say(text.rstrip("\n"))
        return DONE
    say("run %s: %s since %s (no report yet)" % (run["id"], run.get("status"), run.get("started", "-")))
    return DONE


def cmd_cancel(args):
    if len(args) != 1:
        raise Stop("cancel takes one run id", BAD)
    run = load_run(state_dir(), args[0])
    pid = run.get("runner_pid")
    if run.get("status") in ("starting", "running") and not ours(pid, "factory-headless"):
        with open(os.path.join(run["dir"], "cancel"), "w", encoding="utf-8") as f:
            f.write(fmt(utc_now()) + "\n")
        if reconcile(run["dir"], "cancelled after its runner died"):
            return DONE
    if run.get("ended") or not isinstance(pid, int) or not alive(pid):
        raise Stop("run %s is not running (status %s)" % (run["id"], run.get("status")))
    rc, out, _ = run_cmd(["ps", "-o", "command=", "-p", str(pid)], timeout=30)
    if "factory-headless" not in out:
        raise Stop("run %s's runner is gone (its process id now belongs to another program); nothing was sent"
                   % run["id"])
    with open(os.path.join(run["dir"], "cancel"), "w", encoding="utf-8") as f:
        f.write(fmt(utc_now()) + "\n")
    os.kill(pid, signal.SIGTERM)
    say("cancel sent to run %s: its processes get SIGTERM, then SIGKILL after the grace, and it ends with a report"
        % run["id"])
    return DONE


def cmd_runs(args):
    if args:
        raise Stop("runs takes no arguments", BAD)
    for r in all_runs(state_dir()):
        say("%s  %-12s %-10s %s" % (r["id"], r.get("job") or r.get("name"), r.get("role"), r.get("status")))
    return DONE


def cmd_plist(args):
    if len(args) != 1:
        raise Stop("plist takes one job name", BAD)
    tuning, jobs = read_settings()
    name = args[0]
    if name not in jobs:
        raise Stop("no job %s in ~/.factory/%s" % (doc.shown(name, quote=False), SETTINGS))
    job = jobs[name]
    window, _ = job_window(job)
    if not window:
        raise Stop("jobs.%s has no window and the machine has no shifts.night: a scheduled job needs one (its start "
                   "is when launchd starts it)" % name)
    at = job.get("at") or window.split("-")[0]
    state = state_dir()
    log = os.path.join(state, "logs", name + ".log")
    dirs = []
    for tool in ("claude", "codex", "gh", "git", "python3"):
        p = shutil.which(tool)
        if p and os.path.dirname(p) not in dirs:
            dirs.append(os.path.dirname(p))
        elif not p:
            note("%s is not on PATH here, so the job's PATH leaves it out" % tool)
    for d in ("/usr/bin", "/bin", "/usr/sbin", "/sbin"):
        if d not in dirs:
            dirs.append(d)
    grace = job.get("grace_seconds", tuning["grace_seconds"])
    plist = {
        "Label": LABEL % name,
        "ProgramArguments": ["/bin/sh", os.path.join(HERE, "factory-headless"), "run", name],
        "WorkingDirectory": job["project"],
        "StartCalendarInterval": {"Hour": minutes(at) // 60, "Minute": minutes(at) % 60},
        "StandardOutPath": log,
        "StandardErrorPath": log,
        "EnvironmentVariables": {"PATH": ":".join(dirs), "HOME": os.environ["HOME"]},
        "ProcessType": "Background",
        "RunAtLoad": False,
        "ExitTimeOut": int(grace) + 60,
    }
    data = plistlib.dumps(plist, sort_keys=True).decode("utf-8")
    if doc.SECRET.search(data) or doc.ANY_FRAGMENT.search(data):
        raise Stop("the job would hold something that looks like a credential (not shown); nothing printed")
    sys.stdout.write(data)
    return DONE


def cmd_resolve(args):
    got, _, pos = take_args(args, {"--project"}, set())
    if len(pos) != 1:
        raise Stop("resolve takes one spec", BAD)
    tuning, _ = read_settings()
    project = os.path.abspath(got["--project"]) if "--project" in got else None
    provider, model, effort, spec = resolve_spec(pos[0], project)
    exe = check_cli(provider, tuning)
    argv = cli_argv(provider, exe, model, effort, tuning, tuning["max_turns"], "<worktree>", "<run>/last-message.md",
                    "<run>/headless-settings.json")
    say("%s: %s" % (spec, " ".join(argv)))
    return DONE


COMMANDS = {"run": cmd_run, "start": cmd_start, "result": cmd_result, "cancel": cmd_cancel, "runs": cmd_runs,
            "plist": cmd_plist, "resolve": cmd_resolve}


def usage_text():
    text = read_text(os.path.join(HERE, "factory-headless"))
    out = []
    for line in text.splitlines()[1:]:
        if not line.startswith("#"):
            break
        out.append(line[2:] if line.startswith("# ") else line[1:])
    return "\n".join(out)


def main(argv):
    if doc is None or paths is None:
        sys.stderr.write("%s: the core's tools are not next to the runtime (.factory/bin or core/bin); restore the "
                         "core files with factory-update\n" % PROG)
        return 1
    if not argv or argv[0] in ("-h", "--help", "help"):
        say(usage_text())
        return DONE if argv else BAD
    if argv[0] not in COMMANDS:
        note("unknown subcommand (not shown); see --help")
        return BAD
    try:
        return COMMANDS[argv[0]](argv[1:])
    except Stop as e:
        note(e.message)
        return e.code
    except Interrupted as e:
        note("stopped by signal %d" % e.signum)
        return 128 + e.signum
    except Exception as e:  # noqa: BLE001 (one fixed line, never a traceback)
        note("internal error (%s)" % e.__class__.__name__)
        return 70


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
