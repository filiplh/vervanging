#!/usr/bin/env python3
"""factory-usage: the machine-wide usage ledger and the weekly allowance reserve.

    python3 -I factory-usage.py --defaults FILE <subcommand> [arguments]

Subcommands (the shell script factory-usage passes --defaults; `factory-usage --help` shows this text):
    start --spec SPEC [--project NAME] [--role ROLE]   a run starts: append it, print its id
    end ID                                              that run ended (reported, cancelled or stopped)
    limit PROVIDER [--reset UTC]                        the provider answered with a usage-limit error
    observe PROVIDER --used-pct N --reset UTC           a real weekly figure, read where it shows without a person
    observe-statusline                                  the same, from a Claude Code statusline JSON on stdin
    observe-claude-stream                               the same, from Claude Code stream-json on stdin
    observe-codex                                       the same, from Codex's newest session logs
    estimate [PROVIDER] [--json]                        the week per provider: one line each, for the status
    may-start PROVIDER [--urgent]                       may this provider start work now? one line, and the exit code
    refresh claude --model MODEL                        a stale Claude figure: ask the CLI once, record what it says

The ledger is ~/.factory/usage/ledger-v1.tsv, one record per line, each line ended by a line feed, fields separated by
one tab, nothing else:
    start  <id> <at> <provider> <model> <effort|-> <project|-> <role|->
    end    <id> <at>
    limit  <provider> <at> <reset|->
    real   <provider> <at> <used pct, 0-100> <reset|->
    torn   <line number> <at>          written by an append that found the line above it cut short
<at> and <reset> are UTC, YYYY-MM-DDTHH:MM:SSZ. The reader is strict: a line that is not exactly one of these, an id
that starts twice, an end without its start, an end before its start, a last line without its line feed, and every
torn mark are reported by line number (never their text) and make the ledger "cannot tell"; nothing is guessed. Fix
or delete such lines by hand (a torn mark and the line it names together).

Safe paths. ~/.factory, ~/.factory/usage, the ledger, the lock, refresh's stamp (~/.factory/usage/refresh-claude)
and ~/.factory/machine.yaml must each be a real folder or
a regular file (no symbolic link, no hard-linked file), owned by you, and writable by nobody else (no group or other
write bit). Each is opened below the one before by descriptor (O_NOFOLLOW, relative to the parent's descriptor), and
checked on the open descriptor, so a swap between the check and the use cannot redirect a read or a write. HOME
itself is trusted as your home. Missing folders and files are created that way (0700 and 0600). An unsafe path stops
the command before it reads or writes anything else: exit 1, with what is wrong and where.

Appends are safe across processes: each takes an exclusive flock on ~/.factory/usage/ledger.lock, writes the record
with a single write to the ledger opened for appending, and syncs it; a reader holds the lock shared. When the last
line was cut short (a crash), the append first ends it and adds a torn mark naming it, so it is never glued to the new
record and stays reported.

The week, per provider (the reserve and the rest are under Machine settings › usage in docs/factory-yaml.md). Nothing
is guessed: used % is the most conservative believable reading of the provider's real figures, dated and undated alike.
A figure is fresh while its reset has not passed and it was observed at most 6 hours ago (an old ledger line without a
reset: only the 6 hours). The reading is the highest fresh figure; a stale figure whose reset has not passed is a floor
(usage only grows within a week), and the highest floor is the reading when it is at or above the reserve line and
higher than every fresh figure. So a newer figure (a replay, another source's, a mistyped one) never hides a higher
believable one. Without a fresh figure or a floor the week is "cannot tell (no real figure since <time>; N run(s)
since)", and the run count is never turned into a percentage. estimate and may-start codex read Codex's session logs
first (observe-codex, below), and record what they find, except into a ledger the reader does not accept. Times are
shown in the machine's local time with their offset from UTC.

When a figure was observed, and what is recorded (re-reading or replaying an observation never makes it fresher). The
two kinds are judged apart, so neither one's times block the other:
    dated (Codex; refresh): the event's own timestamp, when Codex produced the figure; for refresh, the time its line
    was received live from the CLI refresh started itself (the live-read rule, under refresh's trust contract below:
    the only path that may record an unchanged figure of the same week again; stdin input never is).
    It is recorded unless that observation is already there (the same time, figure and reset: the same log read
    again) or the same figure and reset was recorded less than an hour before it. A figure received later (an undated
    one) never keeps it out.
    undated (observe, observe-statusline, observe-claude-stream): such input carries no time of its own and could be
    a saved copy, so it is dated when it is received, and one predicate, accept(latest, new), decides for all three,
    against the latest record that has a believable reset. It must carry its own reset (observe without --reset is
    refused, exit 64; the statusline and the stream refuse input without one). It rests on two facts: within one week
    usage only grows, and a new week has a later reset (a whole window later). A higher percentage than the latest
    figure is recorded whatever its reset; the same or a lower one only as a new week: the latest figure's reset has
    passed, or the new reset is at least 1 day later (seconds or minutes apart is the same week told again, 7 days
    apart a new one). So a week that does not move goes stale 6 hours after its last change. observe says on stderr
    when it does not record a figure, and why (exit 0). A record without a believable reset is no evidence either way:
    it neither lets a later figure count as new nor keeps one out. The protection holds against what the ledger
    already has: with no record with a believable reset for that week (a new or emptied ledger, or only old lines
    without one), a saved copy of the current week counts as read when it is received; one of an earlier week has a
    passed reset and is refused.
The reset bound: a reset more than 8 days after the figure's own time (when it was received, or the Codex event's time)
is not believed anywhere. observe --reset refuses it (exit 64), the statusline refuses it (exit 1), a stream or Codex
event carrying it is no figure, and a real record in the ledger that holds one (written before this check, or by hand)
is read as a record without a reset: no floor, "reset unknown", and no evidence for or against a later figure. A
limit's reset is not bounded: a limit is not a weekly figure and may last longer.
may-start, in this order:
    a limit whose reset has not passed: exit 3, urgent work too;
    the ledger cannot be read (an unreadable or torn line, which may be a limit), a path is unsafe, or machine.yaml is
    not valid: exit 1, urgent work too, since a limit may be hidden there;
    --urgent: exit 0 (urgent work skips only the reserve);
    a provider without reserve_pct: exit 1 (cannot tell; counts as the reserve reached);
    a reading from a fresh figure: below 100 - reserve_pct exit 0, else exit 3;
    a reading from a floor (at or above 100 - reserve_pct): exit 3, "at least N% used (read <age>, a floor…)";
    otherwise (no figure, only stale ones below the line, or ones whose reset has passed or is unknown): exit 1.

observe-codex reads $CODEX_HOME/sessions (else ~/.codex/sessions)/YYYY/MM/DD/rollout-*.jsonl, read only: the newest 8
day folders, the 8 files changed last, at most the last 8 MiB of each, last line first, lines over 1 MiB skipped, no
link followed. Of each line it parses only a token_count event and uses only its rate_limits (limit_id codex or none):
the primary or secondary window of 10080 minutes gives used_percent (0 to 100) and resets_at (a Unix time not passed
and at most 8 days after the event's own time); an event needs its timestamp (YYYY-MM-DDTHH:MM:SS[.fraction]Z, not
after now), which is when the figure was observed. The newest weekly event of each file is taken, and of those the
one with the latest timestamp across the files is recorded; nothing else from the log is kept, shown or written. No
figure: exit 1 with why (no sessions folder, no file, no weekly window).

observe-claude-stream reads Claude Code's stream-json (claude -p --output-format stream-json; the Agent SDK's messages
as JSON lines) line by line, lines over 1 MiB skipped, and records the last rate_limit_event that carries the weekly
window: rate_limit_info.unifiedWindows.seven_day {utilization, resetsAt}, else rate_limit_info.utilization and
resetsAt when rateLimitType is seven_day. utilization is a fraction from 0 to 10 (above 1 past the cap: 100%); another
value is not a figure. Each event is dated when its line is received. It prints nothing and exits 0 whatever the
lines hold.

refresh claude --model MODEL puts a real Claude weekly figure into the ledger by asking the CLI itself, at most once
an hour on the machine. The event carries no time of its own, so a figure counts as current only when this process
read it live from a CLI it started (the live-read rule, below). The trust contract: refresh trusts the claude found on
the user's PATH, with the environment it inherits (credential-named variables removed), to fetch current data from
the provider. A local wrapper or another PATH entry can defeat that (it could print a saved stream), so the receipt
time proves when the figure was acquired only under that assumption: the same trust the ledger already places in the
user's own home. Nothing pins the executable. In this order:
  1. One transaction under the ledger's exclusive lock, the time taken under it: the settings and the ledger are read
     and judged. Unreadable lines: exit 1 (a new figure would not fix them). A limit whose reset has not passed: exit 3
     (the CLI would be refused). A fresh figure or a floor: exit 0, "no refresh needed". Then the stamp
     ~/.factory/usage/refresh-claude: when it does not exist, it is created (O_EXCL); when it exists, the whole file
     (at most 64 bytes) must be one UTC time and a line feed, else exit 1 and nothing runs (empty, cut short, other
     content, or not a safe regular file: it may be a refresh that crashed while writing; a person deletes it), and a
     time after now is refused the same way (a clock set back). A time less than an hour ago: exit 3, with when the
     next may run. Otherwise the stamp gets the time, before the CLI runs, so a refresh that fails or hangs still
     counts and nothing retries within the hour.
  2. The lock released, it runs `claude -p hi --model MODEL --max-turns 1 --tools "" --output-format stream-json
     --verbose` as its own child: in a new empty folder (mkdtemp, 0700, under the temporary folder), stdin closed,
     stderr discarded, no environment variable whose name looks like a credential (TOKEN, SECRET, PASSW, API_KEY and
     the like; the CLI uses its own login), in a process group of its own. It is stopped (SIGKILL to that group) after
     120 s (counted to its exit, even after it closed its output), or once it has written more than 8 MiB; then
     nothing is recorded, whatever it printed. Its stdout is read as observe-claude-
     stream reads its stdin (lines over 1 MiB skipped, the last weekly rate_limit_event). Afterwards that folder alone
     is removed with rmdir; one the CLI left something in is kept and named, never removed recursively.
  3. The figure is recorded dated, at the time its line was received (the dated rules above: an observation already
     there, or the same figure and reset less than an hour before, is not recorded again), and never into a ledger
     that became unreadable meanwhile.
  It prints one line, "claude: N% recorded (read live just now), resets <time>" (exit 0) or "claude: nothing
  recorded: <why>" (exit 1: the CLI could not start, answered nothing, held no weekly event, was stopped). It is not a
  start: no start record, no run slot, and the reserve does not hold it back. MODEL is the model id of the policy's
  search helper (models.helpers.search). Codex needs no refresh: estimate and may-start read its session logs.
  FACTORY_USAGE_REFRESH_TIMEOUT (seconds, 1 to 120) shortens the timeout: the tests' short one.

observe-statusline reads at most 256 KiB of Claude Code's statusline JSON. No rate_limits, or no
rate_limits.seven_day (not a subscription, before the first answer): nothing is recorded, exit 0, no output. Input
that is larger, not JSON, or of another shape (rate_limits or seven_day not a map, used_percentage not a finite
number from 0 to 100, resets_at not a Unix time within the next 8 days) records nothing and exits 1 with one line.

Exit codes: 0 done (or "may start"); 3 may not start (refresh: a limit, or one less than an hour ago); 1 cannot tell,
unsafe, refused input, cannot write, or (refresh) nothing recorded; 64 bad usage.

The clock is the system's, or FACTORY_USAGE_NOW (UTC, as above) when set: the tests' fake clock; or, without it,
FACTORY_USAGE_NOW_FILE, a regular file of at most 64 bytes holding exactly such a time (and an optional line feed),
read whole at each reading of the clock, never a FIFO or a symlink (exit 64 otherwise): the tests' moving clock.
Standard library only; runs on Python 3.8 and later on macOS and Linux. It reads and appends files under ~/.factory/usage/ and reads the
machine settings, and reads Codex's session logs as above. Only refresh runs a command (the claude CLI, as above);
nothing reads a credential.
"""

import fcntl
import importlib.util
import json
import math
import os
import re
import stat
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True


def load_doctor():
    spec = importlib.util.spec_from_file_location("factory_doctor", os.path.join(HERE, "factory-doctor.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


doc_mod = load_doctor()


def load_paths():
    spec = importlib.util.spec_from_file_location("factory_safe_paths", os.path.join(HERE, "factory-safe-paths.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


paths_mod = load_paths()

PROG = "factory-usage"
LEDGER = "ledger-v1.tsv"
LOCK = "ledger.lock"
MACHINE = "machine.yaml"
OPEN_RUN_HOURS = 5              # a run with no end counts until now, at most this long
STATUSLINE_MAX = 256 * 1024     # bytes of statusline JSON read at most
MAX_FILE = 64 * 1024 * 1024     # a ledger or machine file larger than this is refused
TIME = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"
NAME = r"[a-z0-9][a-z0-9-]{0,63}"
FIELD = {
    "id": r"r[0-9a-f]{16}",
    "at": TIME,
    "reset": TIME + "|-",
    "provider": NAME,
    "model": r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}",
    "effort": r"[a-z]{1,20}|-",
    "project": r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}|-",
    "role": r"[a-z][a-z0-9_-]{0,39}|-",
    "pct": r"[0-9]|[1-9][0-9]|100",
    "lineno": r"[1-9][0-9]{0,9}",
}
RECORDS = {
    "start": ("id", "at", "provider", "model", "effort", "project", "role"),
    "end": ("id", "at"),
    "limit": ("provider", "at", "reset"),
    "real": ("provider", "at", "pct", "reset"),
    "torn": ("lineno", "at"),
}
FRESH_HOURS = 6                 # a real figure counts while its reset has not passed and it is at most this old
REFRESH = 3600                  # seconds: a dated source's unchanged figure is recorded again at most this often
REFRESH_INTERVAL = 3600         # seconds: refresh runs the CLI at most this often, machine-wide
REFRESH_TIMEOUT = 120           # seconds: refresh stops the CLI after this long
REFRESH_OUT_MAX = 8 * 1024 * 1024   # bytes of the CLI's output read at most; more stops it
STAMP_MAX = 64                  # bytes: a refresh stamp larger than this is refused
CRED_ENV = re.compile(r"TOKEN|SECRET|PASSW|CREDENTIAL|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY", re.I)  # kept from the CLI
UTIL_MAX = 10                   # a stream utilization above this (1000%) is not a figure
WEEK_MINUTES = 7 * 24 * 60      # the window of a weekly figure
RESET_MAX = timedelta(days=8)   # a weekly figure resets at most this long after it was read (its 7-day window, plus 1)
CODEX_DAYS = 8                  # Codex session day folders read at most, newest first
CODEX_FILES = 8                 # Codex session files read at most, newest change first
CODEX_DAY_ENTRIES = 4096        # entries of one day folder looked at, at most
CODEX_TAIL = 8 * 1024 * 1024    # bytes read at most from the end of one Codex session file
LINE_MAX = 1024 * 1024          # a log or stream line longer than this is skipped unread


class Fail(Exception):
    def __init__(self, message, code=1):
        Exception.__init__(self, message)
        self.code = code


def say(text):
    sys.stdout.write(doc_mod.redact(doc_mod.clean(text)) + "\n")


def warn(text):
    sys.stderr.write("%s: %s\n" % (PROG, doc_mod.redact(doc_mod.clean(text))))


# --- time -----------------------------------------------------------------------------------------------------------

def parse_time(s):
    if not re.fullmatch(TIME, s):
        raise ValueError(s)
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def fmt(t):
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def short(t):
    """The machine's local time with its offset from UTC, as in "Thu 19 Nov 15:36 UTC+1"."""
    lt = t.astimezone()
    mins = int(lt.utcoffset().total_seconds() // 60)
    zone = "UTC"
    if mins:
        h, m = divmod(abs(mins), 60)
        zone += "%s%d%s" % ("+" if mins > 0 else "-", h, ":%02d" % m if m else "")
    return lt.strftime("%a %d %b %H:%M ") + zone


def now():
    fake = os.environ.get("FACTORY_USAGE_NOW")
    if fake:
        try:
            return parse_time(fake)
        except ValueError:
            raise Fail("FACTORY_USAGE_NOW is not a UTC time like 2026-11-15T09:00:00Z", 64)
    moving = os.environ.get("FACTORY_USAGE_NOW_FILE")
    if moving:
        # A regular file of at most 64 bytes holding exactly one time and an optional line feed; opened without
        # blocking (a FIFO with no writer must not hang a caller that holds the ledger lock) and without following
        # a symlink; anything else is refused whole, never read by prefix.
        why = "FACTORY_USAGE_NOW_FILE does not hold a UTC time like 2026-11-15T09:00:00Z"
        try:
            fd = os.open(moving, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0))
        except OSError:
            raise Fail(why, 64)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise Fail("FACTORY_USAGE_NOW_FILE is not a regular file", 64)
            data = os.read(fd, 65)
        except OSError:
            raise Fail(why, 64)
        finally:
            os.close(fd)
        if len(data) > 64:
            raise Fail(why, 64)
        try:
            text = data.decode("ascii")
            return parse_time(text[:-1] if text.endswith("\n") else text)
        except (UnicodeDecodeError, ValueError):
            raise Fail(why, 64)
    return datetime.now(timezone.utc).replace(microsecond=0)


def arg_time(s, what):
    """A time given on the command line: YYYY-MM-DDTHH:MM[:SS]Z, in UTC."""
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z", s):
        s = s[:-1] + ":00Z"
    try:
        return parse_time(s)
    except ValueError:
        raise Fail("%s: a UTC time like 2026-11-15T15:00Z" % what, 64)


# --- the reset bound --------------------------------------------------------------------------------------------------
# A weekly figure's week resets within its window of being read: never more than RESET_MAX after the figure's own time.
# A later reset (a mistyped year, a hand-edited line) is not believed anywhere: refused on the way in (reset_ok), and
# no reset when read back from the ledger (known_reset, applied by parse to every real record).

def reset_ok(reset, at, t):
    """May a figure read at `at` carry this reset, judged at t? It has not passed, and it is at most RESET_MAX after
    `at`."""
    return t < reset <= at + RESET_MAX


def known_reset(r):
    """A real record's reset when it is believable (at most RESET_MAX after the record's own at), else None."""
    reset = r["reset"]
    return reset if reset is not None and reset <= r["at"] + RESET_MAX else None


# --- safe paths -----------------------------------------------------------------------------------------------------
# The rule and the opening by descriptor are factory-safe-paths.py's (next to this file), shared with the machine's
# slots in factory.py; here its refusals become this tool's Fail.

def open_at(parent, name, where, folder, create, write=False):
    """Open name below the parent descriptor without following a link; None when missing and not created."""
    try:
        return paths_mod.open_at(parent, name, where, folder, create, write=write)
    except paths_mod.Unsafe as e:
        raise Fail(str(e))


def read_fd(fd, where):
    chunks, size = [], 0
    while True:
        b = os.pread(fd, 1 << 20, size)
        if not b:
            break
        chunks.append(b)
        size += len(b)
        if size > MAX_FILE:
            raise Fail("%s is larger than %d MiB; refusing to read it" % (where, MAX_FILE >> 20))
    return b"".join(chunks)


class Store:
    """~/.factory, ~/.factory/usage and the lock, opened by descriptor and checked; the lock held exclusive for
    appends, shared for reads, until the block ends."""

    def __init__(self, exclusive):
        self.exclusive = exclusive
        self.fds = []

    def __enter__(self):
        try:
            try:
                self.home = self._keep(paths_mod.open_home("the ledger (~/.factory/usage/)"))
            except paths_mod.Unsafe as e:
                raise Fail(str(e))
            self.factory = self._keep(open_at(self.home, ".factory", "~/.factory", True, True))
            self.usage = self._keep(open_at(self.factory, "usage", "~/.factory/usage", True, True))
            self.lock = self._keep(open_at(self.usage, LOCK, "~/.factory/usage/" + LOCK, False, True, write=True))
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX if self.exclusive else fcntl.LOCK_SH)
            except OSError as e:
                raise Fail("cannot lock the ledger (%s)" % e.__class__.__name__)
        except BaseException:
            self.__exit__()
            raise
        return self

    def _keep(self, fd):
        self.fds.append(fd)
        return fd

    def __exit__(self, *exc):
        for fd in reversed(self.fds):
            os.close(fd)    # closing the lock's descriptor releases the lock
        self.fds = []

    def machine_text(self):
        """machine.yaml's text, or None when there is none."""
        where = "~/.factory/" + MACHINE
        fd = open_at(self.factory, MACHINE, where, False, False)
        if fd is None:
            return None
        try:
            data = read_fd(fd, where)
        finally:
            os.close(fd)
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            raise Fail("%s is not UTF-8; run factory-doctor for what to fix" % where)

    def ledger(self):
        fd = open_at(self.usage, LEDGER, "~/.factory/usage/" + LEDGER, False, False)
        if fd is None:
            return b""
        try:
            return read_fd(fd, "~/.factory/usage/" + LEDGER)
        finally:
            os.close(fd)

    def append(self, line, t, check=None):
        """Append one record (exclusive lock needed). check(records, problems) may refuse by raising Fail, or skip the
        append by returning False."""
        if not self.exclusive:
            raise Fail("internal: an append without the exclusive lock")
        where = "~/.factory/usage/" + LEDGER
        fd = open_at(self.usage, LEDGER, where, False, True, write=True)
        try:
            data = read_fd(fd, where)
            if check is not None and check(*parse(data)) is False:
                return False
            out = line.encode("ascii") + b"\n"
            if data and not data.endswith(b"\n"):
                out = b"\ntorn\t%d\t%s\n" % (data.count(b"\n") + 1, fmt(t).encode("ascii")) + out
            try:
                if os.write(fd, out) != len(out):
                    raise Fail("the ledger record was written only in part; check %s" % where)
                os.fsync(fd)
            except OSError as e:
                raise Fail("cannot append to %s (%s)" % (where, e.__class__.__name__))
        finally:
            os.close(fd)
        return True


# --- settings -------------------------------------------------------------------------------------------------------

def settings(store, defaults_path):
    """The merged usage settings, or raise Fail (cannot tell) when either file is not valid."""
    try:
        d = doc_mod.load_yaml(defaults_path) if defaults_path and os.path.isfile(defaults_path) else None
    except (doc_mod.Refused, OSError, UnicodeDecodeError):
        raise Fail("the core's defaults.yaml cannot be read; restore the core files with factory-update")
    core = ((d or {}).get("machine") or {}).get("usage") if isinstance(d, dict) else None
    mine = {}
    text = store.machine_text()
    if text is not None:
        try:
            doc = doc_mod.Reader(text).parse()
        except doc_mod.Refused:
            doc = []
        errs = ["not a map"] if doc is not None and not isinstance(doc, dict) else \
            doc_mod.machine_doc_errors(doc or {})
        if errs:
            raise Fail("~/.factory/machine.yaml is not valid; run factory-doctor for what to fix")
        mine = (doc or {}).get("usage") or {}
    usage = doc_mod.merge(core or {}, mine)
    errs = []
    doc_mod.usage_errors(usage, errs)
    if errs:
        raise Fail("the usage settings are not valid (%s); run factory-doctor" % errs[0])
    return usage


def weight(usage, model, effort):
    w = usage.get("weights") or {}
    mw = (w.get("model") or {}).get(model, 1)
    ew = (w.get("effort") or {}).get(effort, 1) if effort != "-" else 1
    return float(mw) * float(ew)


# --- the ledger -----------------------------------------------------------------------------------------------------

def parse(data):
    """(records, problems): records as dicts with 'kind' and 'line'; problems as strings naming a line number."""
    parts = data.split(b"\n")
    lines = [(p, True) for p in parts[:-1]]
    if parts[-1] != b"":
        lines.append((parts[-1], False))
    records, problems, starts, ended = [], [], {}, set()
    for n, (raw, ended_ok) in enumerate(lines, 1):
        if not ended_ok:
            problems.append("line %d is cut short (no line end)" % n)
            continue
        try:
            text = raw.decode("ascii")
        except UnicodeDecodeError:
            text = None
        fields = text.split("\t") if text is not None else []
        kind = fields[0] if fields else ""
        names = RECORDS.get(kind)
        if names is None or len(fields) != len(names) + 1 or \
                not all(re.fullmatch(FIELD[k], v) for k, v in zip(names, fields[1:])):
            problems.append("line %d is not a ledger record" % n)
            continue
        r = dict(zip(names, fields[1:]))
        r["kind"], r["line"] = kind, n
        try:
            r["at"] = parse_time(r["at"])
            if "reset" in r:
                r["reset"] = None if r["reset"] == "-" else parse_time(r["reset"])
        except ValueError:
            problems.append("line %d holds a time that does not exist" % n)
            continue
        if kind == "torn":
            if int(r["lineno"]) != n - 1:
                problems.append("line %d is not a ledger record" % n)
            else:
                problems.append("line %d was cut short (marked on line %d)" % (n - 1, n))
            continue
        if kind == "start":
            if r["id"] in starts:
                problems.append("line %d starts run %s again (first on line %d)" % (n, r["id"], starts[r["id"]]["line"]))
                continue
            starts[r["id"]] = r
        elif kind == "end":
            s = starts.get(r["id"])
            if s is None or r["id"] in ended:
                problems.append("line %d ends run %s, which %s" % (n, r["id"], "already ended" if s else "has no start before it"))
                continue
            if r["at"] < s["at"]:
                problems.append("line %d ends run %s before it started" % (n, r["id"]))
                continue
            ended.add(r["id"])
            s["end"] = r["at"]
        if kind == "real":
            r["pct"] = int(r["pct"])
            r["reset"] = known_reset(r)     # a reset more than RESET_MAX after its figure is no reset
        records.append(r)
    return records, problems


def append(fields, check=None):
    line = "\t".join(fields)
    if "\n" in line or "\r" in line:
        raise Fail("a field holds a line break", 64)
    t = now()
    with Store(True) as st:
        return st.append(line, t, check)


# --- the week per provider -------------------------------------------------------------------------------------------

def age_text(d):
    m = max(0, int(d.total_seconds() // 60))
    if m < 1:
        return "just now"
    if m < 60:
        return "%d min ago" % m
    h, m = divmod(m, 60)
    if h < 48:
        return "%d h ago" % h if m == 0 else "%d h %d min ago" % (h, m)
    return "%d days ago" % (h // 24)


def reading(reals, t, line):
    """(record, "real" | "floor") or (None, None): the most conservative believable reading of one provider's real
    records at t, whatever their source.
      fresh: its reset has not passed (or it has none) and it is at most FRESH_HOURS old. The highest fresh figure is
        the reading (the latest of equal ones).
      floor: a stale record whose reset has not passed is a lower bound (usage only grows within a week). The highest
        such record is the reading when it is at or above the reserve line and higher than every fresh figure; below
        the line it says nothing.
    A record's reset is believable or None here: parse drops one more than RESET_MAX after its figure (known_reset), so
    a record without one is fresh for FRESH_HOURS and never a floor. Taking the highest, not the latest, means a newer
    record (a replay, a figure of another source, a mistyped reset) can never hide a higher believable one."""
    key = lambda r: (r["pct"], r["at"], r["line"])  # noqa: E731
    young = timedelta(hours=FRESH_HOURS)
    fresh = [r for r in reals if (r["reset"] is None or r["reset"] > t) and t - r["at"] <= young]
    stale = [r for r in reals if t - r["at"] > young and r["reset"] is not None and r["reset"] > t]
    best = max(fresh, key=key) if fresh else None
    low = max(stale, key=key) if stale else None
    if low is not None and line is not None and low["pct"] >= line and (best is None or low["pct"] > best["pct"]):
        return low, "floor"
    return (best, "real") if best is not None else (None, None)


def judge(usage, records, problems, provider, t):
    """The state of one provider at time t, as a dict (also the --json output). There is no estimate: used % is the most
    conservative believable reading of all the provider's real records, dated and undated alike (reading()); a newer
    record never hides a higher one."""
    reserve = (usage.get("reserve_pct") or {}).get(provider)
    out = {"provider": provider, "reserve_pct": reserve, "line_pct": None if reserve is None else 100 - reserve,
           "used_pct": None, "source": None, "real_at": None, "real_reset": None, "real_age_minutes": None,
           "last_real_at": None, "runs": 0, "runs_since": None, "limit_until": None, "may_start": None,
           "may_start_urgent": not problems, "ledger_readable": not problems, "why": None}
    limits = [r for r in records if r["kind"] == "limit" and r["provider"] == provider and r["reset"] and r["reset"] > t
              and r["at"] <= t]
    if limits:
        out["limit_until"] = fmt(max(r["reset"] for r in limits))
        out["may_start_urgent"] = False
    reals = [r for r in records if r["kind"] == "real" and r["provider"] == provider and r["at"] <= t]
    last = max(reals, key=lambda r: (r["at"], r["line"])) if reals else None
    chosen, kind = reading(reals, t, None if reserve is None else 100 - reserve)
    fresh, floor = kind == "real" and not problems, kind == "floor" and not problems
    since = last["at"] if last is not None else t - timedelta(days=7)
    out["runs_since"] = fmt(since)
    out["runs"] = sum(1 for r in records if r["kind"] == "start" and r["provider"] == provider and since < r["at"] <= t)
    if last is not None:
        out["last_real_at"] = fmt(last["at"])
    cannot = []
    if problems:
        cannot.append("the ledger has %d unreadable line(s)" % len(problems))
    elif not fresh and not floor:
        if last is None:
            cannot.append("no real figure yet; %d run(s) in the last 7 days" % out["runs"])
        else:
            cannot.append("no real figure since %s; %d run(s) since" % (short(last["at"]), out["runs"]))
    if fresh or floor:
        out["used_pct"] = chosen["pct"]
        out["source"] = kind
        out["real_at"] = fmt(chosen["at"])
        out["real_reset"] = fmt(chosen["reset"]) if chosen["reset"] is not None else None
        out["real_age_minutes"] = int((t - chosen["at"]).total_seconds() // 60)
    if reserve is None:
        cannot.append("no usage.reserve_pct for %s in the machine settings" % provider)
    if cannot:
        out["why"] = "cannot tell: " + "; ".join(cannot)
    else:
        out["may_start"] = out["used_pct"] < out["line_pct"]
    if out["limit_until"]:
        out["may_start"] = False
    return out


def line_for(j, t):
    p = j["provider"]
    if j["source"] == "floor":
        used = "at least %d%% used (read %s, a floor: usage only grows until the reset), resets %s" % (
            j["used_pct"], age_text(t - parse_time(j["real_at"])), short(parse_time(j["real_reset"])))
    elif j["used_pct"] is not None:
        used = "%d%% used, read %s, %s" % (
            j["used_pct"], age_text(t - parse_time(j["real_at"])),
            "resets %s" % short(parse_time(j["real_reset"])) if j["real_reset"] else "reset unknown")
        if j["why"]:
            used += " (cannot tell: %s)" % j["why"][len("cannot tell: "):]
    else:
        used = "cannot tell (%s)" % j["why"][len("cannot tell: "):]
    line = "" if j["line_pct"] is None else "; reserve line %d%%" % j["line_pct"]
    if j["limit_until"]:
        verdict = "usage limit until %s: nothing starts" % short(parse_time(j["limit_until"]))
    elif not j["ledger_readable"]:
        verdict = "ledger unreadable, a limit may be hidden: nothing starts until it is fixed"
    elif j["may_start"] is None:
        verdict = "cannot tell: only urgent work starts"
    elif j["may_start"]:
        verdict = "non-urgent work may start"
    else:
        verdict = "reserve reached: only urgent work starts"
    return "%s: %s%s; %s" % (p, used, line, verdict)


def providers(usage, records):
    names = set(usage.get("reserve_pct") or {}) | set(usage.get("week_units") or {})
    names |= {r["provider"] for r in records if "provider" in r}
    return sorted(names)


def snapshot(defaults_path):
    """(usage settings, records, problems), read under the shared lock."""
    with Store(False) as st:
        usage = settings(st, defaults_path)
        records, problems = parse(st.ledger())
    return usage, records, problems


# --- subcommands ----------------------------------------------------------------------------------------------------

def take(args, flags, positional):
    """Parse args: flags is {"--name": takes_value}; returns (dict of flags, list of positionals)."""
    got, pos = {}, []
    i = 0
    while i < len(args):
        a = args[i]
        if a in flags:
            if flags[a]:
                if i + 1 >= len(args):
                    raise Fail("%s needs a value" % a, 64)
                got[a] = args[i + 1]
                i += 1
            else:
                got[a] = True
        elif a.startswith("-"):
            raise Fail("unknown option (not shown); see --help", 64)
        else:
            pos.append(a)
        i += 1
    if len(pos) not in positional:
        raise Fail("wrong number of arguments; see --help", 64)
    return got, pos


def check_field(kind, value, what):
    if not re.fullmatch(FIELD[kind], value):
        raise Fail("%s is not valid (not shown)" % what, 64)
    return value


def cmd_start(defaults, args):
    got, _ = take(args, {"--spec": True, "--project": True, "--role": True}, (0,))
    spec = got.get("--spec")
    m = doc_mod.SPEC.fullmatch(spec or "")
    if not m:
        raise Fail("--spec: <provider>/<model>[/<effort>], as in the model policy", 64)
    provider, model, effort = m.group(1), m.group(2), m.group(3) or "-"
    check_field("provider", provider, "the provider")
    check_field("model", model, "the model")
    project = check_field("project", got.get("--project", "-"), "--project")
    role = check_field("role", got.get("--role", "-"), "--role")
    rid = "r" + os.urandom(8).hex()
    append(["start", rid, fmt(now()), provider, model, effort, project, role])
    say(rid)
    return 0


def cmd_end(defaults, args):
    _, pos = take(args, {}, (1,))
    rid = check_field("id", pos[0], "the run id")
    t = now()

    def check(records, problems):
        s = [r for r in records if r["kind"] == "start" and r["id"] == rid]
        if not s:
            raise Fail("no run with that id in the ledger")
        if s[0].get("end") is not None:
            raise Fail("that run has already ended")
        if t < s[0]["at"]:
            raise Fail("the clock is before that run's start")

    append(["end", rid, fmt(t)], check)
    return 0


def cmd_limit(defaults, args):
    got, pos = take(args, {"--reset": True}, (1,))
    provider = check_field("provider", pos[0], "the provider")
    t = now()
    reset = arg_time(got["--reset"], "--reset") if "--reset" in got else None
    if reset is not None and reset <= t:
        raise Fail("--reset is not in the future", 64)
    append(["limit", provider, fmt(t), fmt(reset) if reset else "-"])
    say("%s: limit recorded%s" % (provider, ", nothing starts on it until %s" % short(reset) if reset else
                                  " without a reset time; the runtime's back-off applies"))
    return 0


NEW_WEEK_MARGIN = timedelta(days=1)  # a lower figure is a new week only when its reset is at least this much later


def accept(latest, new):
    """May an undated figure be recorded? (yes, why not). new: a dict with pct, reset (a datetime, required) and at
    (when received); latest: the provider's latest real record that has a believable reset, or None. Undated input
    (observe, observe-statusline, observe-claude-stream) carries no time of its own and may be a saved copy, so it is
    recorded only when it cannot be an old observation of what the ledger already has. refresh does not come here: a
    figure it read live from a CLI it started itself goes the dated way (the live-read rule), the only way an unchanged
    figure of the same week is recorded again. That rests on refresh's trust contract (the module text): the CLI on
    the user's PATH fetches current data; a local wrapper could defeat it, as anything in the user's home could. Built
    on two facts only:
      1. within one week, usage only grows;
      2. a new week has a later reset: about a whole window (7 days) later.
    The rules, in order:
      no reset of its own: no. Its week cannot be told, so nothing could say it is not an old copy (observe refuses
        it with exit 64 before this, the statusline and stream parsers refuse it too);
      no latest record with a believable reset: yes. The ledger holds nothing it could be a copy of; its own reset,
        not passed, places it in the current week. A record without a believable reset (an old line, or one whose
        reset is more than RESET_MAX after it) is no evidence either way: it neither lets a figure count as new nor
        blocks one;
      received before the latest one: no (the ledger is never rewound);
      a higher percentage: yes, whatever its reset says. By fact 1 it cannot be an old observation of the latest
        record's week, and an older week's reset has passed, which observe and the parsers refuse; its reset may
        differ from the latest's a little (rounding, a jitter);
      the same or a lower percentage: only as a new week (fact 2): the latest record's reset has passed (the new
        figure's own reset is still ahead, so it belongs to a later week), or the new reset is at least
        NEW_WEEK_MARGIN (1 day) later than the latest's. A whole window apart is a new week, seconds or minutes apart
        is the same week told again; one day sits well clear of both. Otherwise no.
    """
    if new["reset"] is None:
        return False, "it carries no reset time, so its week cannot be told"
    if latest is None or known_reset(latest) is None:
        return True, None
    if new["at"] < latest["at"]:
        return False, "it was received before the latest figure"
    if new["pct"] > latest["pct"]:
        return True, None
    if latest["reset"] <= new["at"]:
        return True, None
    if new["reset"] >= latest["reset"] + NEW_WEEK_MARGIN:
        return True, None
    return False, ("it is not higher than the latest figure (%d%%) of the same week, so it may be an old observation"
                   % latest["pct"])


def record_real(provider, pct, reset, at, dated=False, quiet_on_problems=False):
    """Append a real figure observed at `at` when it is new information; (recorded, why not). The two kinds are judged
    apart, so neither one's times block the other:
      dated: `at` is when the provider produced the figure (Codex's event time), or when refresh received it live
        from the CLI it started (the live-read rule). Not recorded when that very
        observation is already there (a record at the same time with the same figure and reset: the same log read
        again), or when the same figure and reset was recorded less than REFRESH before it. A record received later
        (an undated one's receipt time) never blocks it.
      undated: `at` is when it was received, and accept() decides against the latest record that has a believable
        reset. A dated record's time is when Codex produced it, never after now, so it cannot block either.
    quiet_on_problems: append nothing to a ledger the reader does not accept (the automatic reads of estimate and
    may-start never write to a broken ledger)."""
    why = []

    def check(records, problems):
        if problems and quiet_on_problems:
            why.append("the ledger has unreadable lines")
            return False
        reals = [r for r in records if r["kind"] == "real" and r["provider"] == provider]
        if not dated:
            known = [r for r in reals if r["reset"] is not None]     # parse left only believable resets
            last = max(known, key=lambda r: (r["at"], r["line"])) if known else None
            ok, reason = accept(last, {"pct": pct, "reset": reset, "at": at})
            if not ok:
                why.append(reason)
            return ok
        for r in reals:
            if r["pct"] != pct or r["reset"] != reset:
                continue
            if r["at"] == at:
                why.append("that observation is already recorded")
                return False
            if at - timedelta(seconds=REFRESH) < r["at"] < at:
                why.append("the same figure was recorded less than an hour before")
                return False
        return True

    done = append(["real", provider, fmt(at), str(pct), fmt(reset) if reset else "-"], check)
    return done, (why[0] if why else None)


def cmd_observe(defaults, args):
    got, pos = take(args, {"--used-pct": True, "--reset": True}, (1,))
    provider = check_field("provider", pos[0], "the provider")
    pct = check_field("pct", got.get("--used-pct", ""), "--used-pct (a whole number from 0 to 100)")
    t = now()
    if "--reset" not in got:
        raise Fail("--reset is needed: the figure's reset time (UTC, as the app shows it), so it can be told from an "
                   "old one", 64)
    reset = arg_time(got["--reset"], "--reset")
    if reset <= t:
        raise Fail("--reset is not in the future", 64)
    if not reset_ok(reset, t, t):
        raise Fail("--reset is more than 8 days ahead; a weekly figure resets within 8 days (is the date right?)", 64)
    done, why = record_real(provider, int(pct), reset, t)
    if not done:
        warn("%s: %d%% not recorded: %s" % (provider, int(pct), why))
    return 0


def number(v):
    """A finite int or float (never a bool), else None."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    try:
        return float(v) if math.isfinite(v) else None
    except OverflowError:
        return None


def no_constant(name):
    raise ValueError(name)


def cmd_observe_statusline(defaults, args):
    """Claude Code's statusline JSON on stdin: rate_limits.seven_day.used_percentage (0-100) and resets_at (Unix
    seconds). Validated whole before anything is recorded; the rules are in the module text."""
    take(args, {}, (0,))
    bad = "statusline input refused, nothing recorded: "
    stdin = getattr(sys.stdin, "buffer", sys.stdin)
    raw = stdin.read(STATUSLINE_MAX + 1)
    if len(raw) > STATUSLINE_MAX:
        raise Fail(bad + "larger than %d KiB" % (STATUSLINE_MAX >> 10))
    try:
        data = json.loads(raw.decode("utf-8"), parse_constant=no_constant)
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise Fail(bad + "not JSON")
    if not isinstance(data, dict):
        raise Fail(bad + "not a JSON object")
    limits = data.get("rate_limits")
    if limits is None:
        return 0
    if not isinstance(limits, dict):
        raise Fail(bad + "rate_limits is not a map")
    week = limits.get("seven_day")
    if week is None:
        return 0
    if not isinstance(week, dict):
        raise Fail(bad + "rate_limits.seven_day is not a map")
    pct = number(week.get("used_percentage"))
    if pct is None or not 0 <= pct <= 100:
        raise Fail(bad + "used_percentage is not a number from 0 to 100")
    t = now()
    reset_s = number(week.get("resets_at"))
    if reset_s is None:
        raise Fail(bad + "resets_at is not a Unix time")
    try:
        reset = datetime.fromtimestamp(int(reset_s), timezone.utc)
    except (OverflowError, OSError, ValueError):
        raise Fail(bad + "resets_at is not a Unix time")
    if not reset_ok(reset, t, t):
        raise Fail(bad + "resets_at is not within the next 8 days")
    record_real("claude", int(round(pct)), reset, t)
    return 0


def unix_reset(v, t, at):
    """A reset time given as Unix seconds with a figure read at `at`: a datetime that passes reset_ok, else None."""
    n = number(v)
    if n is None:
        return None
    try:
        reset = datetime.fromtimestamp(int(n), timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None
    return reset if reset_ok(reset, at, t) else None


# --- Codex's session logs ---------------------------------------------------------------------------------------------
# Codex writes its sessions to $CODEX_HOME/sessions (else ~/.codex/sessions)/YYYY/MM/DD/rollout-*.jsonl, one JSON event
# per line. Its token_count events carry rate_limits, with a window of WEEK_MINUTES for the weekly figure. Only that
# object of those events is looked at; no other log content is kept, shown or written, and no other file is opened.

def codex_root():
    home = os.environ.get("HOME") or ""
    base = os.environ.get("CODEX_HOME") or (os.path.join(home, ".codex") if home else "")
    return os.path.join(base, "sessions") if base else None


def subdirs(path, width):
    """The real folders (no links) below path named by width digits, newest name first."""
    try:
        with os.scandir(path) as it:
            names = [e.name for e in it if len(e.name) == width and e.name.isdigit() and e.name.isascii()
                     and e.is_dir(follow_symlinks=False)]
    except OSError:
        return []
    return [os.path.join(path, n) for n in sorted(names, reverse=True)]


def codex_files(root):
    """The newest rollout files, at most CODEX_FILES, by last change, from the newest CODEX_DAYS day folders."""
    days = []
    for y in subdirs(root, 4):
        for m in subdirs(y, 2):
            for d in subdirs(m, 2):
                days.append(d)
                if len(days) >= CODEX_DAYS:
                    break
            if len(days) >= CODEX_DAYS:
                break
        if len(days) >= CODEX_DAYS:
            break
    files = []
    for d in days:
        try:
            with os.scandir(d) as it:
                for n, e in enumerate(it):
                    if n >= CODEX_DAY_ENTRIES:
                        break
                    if e.name.startswith("rollout-") and e.name.endswith(".jsonl") and e.is_file(follow_symlinks=False):
                        files.append((e.stat(follow_symlinks=False).st_mtime, e.path))
        except OSError:
            continue
    files.sort(reverse=True)
    return [f for _, f in files[:CODEX_FILES]]


def lines_backward(fd, size):
    """The lines of the last CODEX_TAIL bytes of the file, last line first. A line longer than LINE_MAX, and the
    first line of the window when the window does not start the file, are skipped."""
    pos, done, carry, skipping = size, 0, b"", False
    while pos > 0 and done < CODEX_TAIL:
        n = min(1 << 20, pos, CODEX_TAIL - done)
        pos -= n
        done += n
        chunk = os.pread(fd, n, pos)
        if len(chunk) != n:
            return
        parts = chunk.split(b"\n")
        if skipping:
            parts[-1] = None            # the start of the long line being skipped
            skipping = len(parts) == 1
        else:
            parts[-1] += carry
        carry = parts[0] if len(parts) > 1 else (parts[0] or b"")
        for raw in reversed(parts[1:]):
            if raw is not None and len(raw) <= LINE_MAX:
                yield raw
        if len(carry) > LINE_MAX:
            carry, skipping = b"", True
    if pos == 0 and not skipping and carry:
        yield carry


def event_time(ev):
    ts = ev.get("timestamp")
    if isinstance(ts, str):
        m = re.fullmatch(r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]{1,9})?Z", ts)
        if m:
            try:
                return parse_time(m.group(1) + "Z")
            except ValueError:
                pass
    return None


def codex_weekly(ev, t, at):
    """(used pct, reset) from one event's rate_limits weekly window, else None. at: the event's own time."""
    p = ev.get("payload") if isinstance(ev, dict) else None
    if not isinstance(p, dict) or p.get("type") != "token_count":
        return None
    rl = p.get("rate_limits")
    if not isinstance(rl, dict) or rl.get("limit_id") not in (None, "codex"):
        return None
    for key in ("primary", "secondary"):
        w = rl.get(key)
        if not isinstance(w, dict) or number(w.get("window_minutes")) != WEEK_MINUTES:
            continue
        pct = number(w.get("used_percent"))
        reset = unix_reset(w.get("resets_at"), t, at)
        if pct is not None and 0 <= pct <= 100 and reset is not None:
            return int(round(pct)), reset
    return None


def codex_figure(t):
    """(used pct, reset, read at) of the newest weekly figure in Codex's session logs, or (None, why)."""
    root = codex_root()
    if root is None or not os.path.isdir(root) or os.path.islink(root):
        return None, "no Codex sessions folder"
    files = codex_files(root)
    if not files:
        return None, "no Codex session file in the newest %d day folders" % CODEX_DAYS
    best = None
    for path in files:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0))
        except OSError:
            continue
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                continue
            for raw in lines_backward(fd, st.st_size):
                if b'"token_count"' not in raw or b'"rate_limits"' not in raw:
                    continue
                try:
                    ev = json.loads(raw.decode("utf-8"), parse_constant=no_constant)
                except (ValueError, UnicodeDecodeError, RecursionError):
                    continue
                at = event_time(ev)
                if at is None or at > t:
                    continue            # undated, or dated after now: not a figure whose age is known
                got = codex_weekly(ev, t, at)
                if got is not None:
                    if best is None or at > best[2]:
                        best = (got[0], got[1], at)
                    break               # the newest weekly event of this file
        except OSError:
            continue
        finally:
            os.close(fd)
    if best is None:
        return None, "no weekly figure in the newest %d Codex session file(s)" % len(files)
    return best


def observe_codex(t, quiet_on_problems):
    """Record Codex's newest weekly figure; (recorded figure or None, why none)."""
    got = codex_figure(t)
    if got[0] is None:
        return None, got[1]
    pct, reset, at = got
    record_real("codex", pct, reset, at, dated=True, quiet_on_problems=quiet_on_problems)
    return got, None


def cmd_observe_codex(defaults, args):
    take(args, {}, (0,))
    t = now()
    got, why = observe_codex(t, False)
    if got is None:
        raise Fail("codex: nothing recorded (%s)" % why)
    say("codex: %d%% used, read %s, resets %s" % (got[0], short(got[2]), short(got[1])))
    return 0


# --- Claude Code's stream-json --------------------------------------------------------------------------------------

def claude_event_weekly(ev, t):
    """(used pct, reset) from a rate_limit_event's weekly window, else None. utilization is a fraction (above 1 when
    usage runs past the cap). t is also the figure's own time: an event is dated when its line is received."""
    if not isinstance(ev, dict) or ev.get("type") != "rate_limit_event":
        return None
    info = ev.get("rate_limit_info")
    if not isinstance(info, dict):
        return None
    windows = info.get("unifiedWindows")
    w = windows.get("seven_day") if isinstance(windows, dict) else None
    if isinstance(w, dict):
        util, reset_v = number(w.get("utilization")), w.get("resetsAt")
    elif info.get("rateLimitType") == "seven_day":
        util, reset_v = number(info.get("utilization")), info.get("resetsAt")
    else:
        return None
    reset = unix_reset(reset_v, t, t)
    if util is None or not 0 <= util <= UTIL_MAX or reset is None:
        return None
    return min(100, int(round(util * 100))), reset


def cmd_observe_claude_stream(defaults, args):
    """Claude Code's stream-json (claude -p --output-format stream-json, or the Agent SDK's messages as JSON lines) on
    stdin: the last rate_limit_event with a weekly window is recorded. Prints nothing; other lines are ignored."""
    take(args, {}, (0,))
    stdin = getattr(sys.stdin, "buffer", sys.stdin)
    best = None
    while True:
        raw = stdin.readline(LINE_MAX + 1)
        if not raw:
            break
        if len(raw) > LINE_MAX and not raw.endswith(b"\n"):
            while raw and not raw.endswith(b"\n"):
                raw = stdin.readline(LINE_MAX)
            continue
        got = stream_line_weekly(raw)
        if got is not None:
            best = got
    if best is not None:
        record_real("claude", best[0], best[1], best[2])
    return 0


def stream_line_weekly(raw):
    """(used pct, reset, received) from one stream-json line holding a weekly rate_limit_event, else None. The line is
    dated when it is received, not when the command started."""
    if b"rate_limit_event" not in raw:
        return None
    try:
        ev = json.loads(raw.decode("utf-8"), parse_constant=no_constant)
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None
    t = now()
    got = claude_event_weekly(ev, t)
    return None if got is None else got + (t,)


# --- refresh: one tiny live prompt, read by this process ----------------------------------------------------------------

def refresh_decide(defaults, provider):
    """The whole decision in one exclusive-lock transaction: judge the ledger, check the stamp, claim the attempt, all
    at one time t read once the lock is held (a caller that waited for the lock stamps when it got it). Returns (code,
    line): code None means claimed (run the CLI now)."""
    name = "refresh-" + provider
    where = "~/.factory/usage/" + name
    with Store(True) as st:
        t = now()
        usage = settings(st, defaults)
        records, problems = parse(st.ledger())
        if problems:
            for p in problems:
                warn("%s of ~/.factory/usage/%s; fix or delete it by hand" % (p, LEDGER))
            return 1, "%s: no refresh: the ledger has unreadable lines, which a new figure would not fix" % provider
        j = judge(usage, records, problems, provider, t)
        if j["limit_until"]:
            return 3, "%s: no refresh: usage limit until %s, the CLI would be refused" % (
                provider, short(parse_time(j["limit_until"])))
        if j["used_pct"] is not None:
            return 0, "%s: no refresh needed: a %s figure is there (%d%%)" % (
                provider, "floor" if j["source"] == "floor" else "fresh", j["used_pct"])
        fd = open_at(st.usage, name, where, False, False, write=True)
        if fd is None:
            try:
                fd = paths_mod.open_at(st.usage, name, where, False, True, write=True, exclusive=True)
            except FileExistsError:
                raise Fail("%s appeared while the ledger was locked; run the refresh again later" % where)
            except paths_mod.Unsafe as e:
                raise Fail(str(e))
        else:
            try:
                last = stamp_time(fd, where)
            except BaseException:
                os.close(fd)
                raise
            if last > t:
                os.close(fd)
                raise Fail("%s holds a time after now (%s; was the clock set back?): no refresh. Delete that file by "
                           "hand once the clock is right" % (where, fmt(last)))
            if t - last < timedelta(seconds=REFRESH_INTERVAL):
                os.close(fd)
                return 3, "%s: no refresh: one was taken %s; at most one per hour, the next from %s" % (
                    provider, age_text(t - last), short(last + timedelta(seconds=REFRESH_INTERVAL)))
        try:
            out = (fmt(t) + "\n").encode("ascii")
            try:
                os.ftruncate(fd, 0)
                if os.write(fd, out) != len(out):
                    raise Fail("the refresh time was written only in part; check %s" % where)
                os.fsync(fd)
            except OSError as e:
                raise Fail("cannot write %s (%s)" % (where, e.__class__.__name__))
        finally:
            os.close(fd)
    return None, None


def stamp_time(fd, where):
    """The one UTC time an existing stamp holds, read whole (bounded); anything else is refused, never taken as no
    attempt: an empty, cut-short or larger file may be a refresh that crashed while it wrote."""
    data = os.pread(fd, STAMP_MAX + 1, 0)
    try:
        if len(data) > STAMP_MAX or not data.endswith(b"\n"):
            raise ValueError(where)
        return parse_time(data[:-1].decode("ascii"))
    except (ValueError, UnicodeDecodeError):
        raise Fail("%s holds no valid time (empty, cut short or other content): no refresh. If no refresh is running, "
                   "delete that file by hand" % where)


def run_cli(model):
    """Run the claude CLI once, as this process's child, in a new empty folder; ((pct, reset, received) or None, why).
    The child gets no stdin, no credential-named variables, its stderr discarded, and a hard timeout."""
    import selectors
    import signal
    import subprocess
    import tempfile
    import time
    timeout = REFRESH_TIMEOUT
    fake = os.environ.get("FACTORY_USAGE_REFRESH_TIMEOUT")
    if fake:
        if not re.fullmatch(r"[1-9][0-9]{0,2}", fake) or int(fake) > REFRESH_TIMEOUT:
            raise Fail("FACTORY_USAGE_REFRESH_TIMEOUT is not a number of seconds from 1 to %d" % REFRESH_TIMEOUT, 64)
        timeout = int(fake)
    env = {k: v for k, v in os.environ.items() if not CRED_ENV.search(k)}
    folder = tempfile.mkdtemp(prefix="factory-usage-refresh.")
    best, why = None, None
    try:
        try:
            child = subprocess.Popen(
                ["claude", "-p", "hi", "--model", model, "--max-turns", "1", "--tools", "",
                 "--output-format", "stream-json", "--verbose"],
                cwd=folder, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                start_new_session=True, close_fds=True)
        except OSError as e:
            return None, "the claude CLI could not be started (%s; is it on PATH?)" % e.__class__.__name__
        fd = child.stdout.fileno()
        sel = selectors.DefaultSelector()
        sel.register(fd, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        buf, skipping, total, lines, stop, eof = b"", False, 0, 0, None, False
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    stop = "the CLI did not finish within %d s and was stopped" % timeout
                    break
                if not sel.select(left):
                    continue
                chunk = os.read(fd, 1 << 16)
                if not chunk:
                    eof = True
                    break
                total += len(chunk)
                if total > REFRESH_OUT_MAX:
                    stop = "the CLI wrote more than %d MiB and was stopped" % (REFRESH_OUT_MAX >> 20)
                    break
                buf += chunk
                while True:
                    i = buf.find(b"\n")
                    if i < 0:
                        if len(buf) > LINE_MAX:
                            buf, skipping = b"", True
                        break
                    line, buf = buf[:i + 1], buf[i + 1:]
                    lines += 1
                    if skipping or len(line) > LINE_MAX + 1:
                        skipping = False
                        continue
                    got = stream_line_weekly(line)
                    if got is not None:
                        best = got
            if stop is None and buf and not skipping:
                lines += 1
                got = stream_line_weekly(buf)
                if got is not None:
                    best = got
        finally:
            sel.close()
            # The child is not reaped before this point, so its id (and its group's) is still its own to signal.
            kill = stop is not None or not eof
            if not kill:
                try:
                    child.wait(timeout=max(0.1, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    # Closed its output but did not end in time: a timed-out refresh, whatever it printed.
                    kill = True
                    stop = "the CLI did not finish within %d s and was stopped" % timeout
            if kill:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except OSError:
                    pass
            child.wait()
            child.stdout.close()
        if stop is not None:
            return None, stop
        if best is None:
            why = ("the stream held no rate_limit_event with a weekly window" if lines else
                   "the CLI answered nothing (not logged in, offline or refused)")
        return best, why
    finally:
        try:
            os.rmdir(folder)        # only the empty folder it made; never anything recursive
        except OSError:
            warn("the temporary folder %s is not empty and was left; look at it, then remove that folder" % folder)


def cmd_refresh(defaults, args):
    """Refresh Claude's real weekly figure once: decide and claim under the lock, then run the CLI and record what it
    answered, as a figure read live (dated when received). The rules are in the module text."""
    got, pos = take(args, {"--model": True}, (1,))
    if pos[0] != "claude":
        raise Fail("refresh is for claude only; codex needs none (estimate and may-start read its session logs)", 64)
    model = check_field("model", got.get("--model", ""), "--model (the model id of models.helpers.search)")
    code, line = refresh_decide(defaults, "claude")
    if code is not None:
        say(line)
        return code
    best, why = run_cli(model)
    if best is None:
        say("claude: nothing recorded: %s" % why)
        return 1
    done, not_why = record_real("claude", best[0], best[1], best[2], dated=True, quiet_on_problems=True)
    if not done:
        say("claude: nothing recorded: %d%% read, but %s" % (best[0], not_why))
        return 1
    say("claude: %d%% recorded (read live just now), resets %s" % (best[0], short(best[1])))
    return 0


# --- the reports ----------------------------------------------------------------------------------------------------

def report(defaults, names_wanted):
    """Read Codex's logs first (a real figure, recorded), then the ledger; (time, judgements, problems)."""
    t = now()
    if names_wanted is None or "codex" in names_wanted:
        observe_codex(t, True)
    usage, records, problems = snapshot(defaults)
    names = names_wanted or providers(usage, records)
    return t, [judge(usage, records, problems, p, t) for p in names], problems


def cmd_estimate(defaults, args):
    got, pos = take(args, {"--json": False}, (0, 1))
    name = check_field("provider", pos[0], "the provider") if pos else None
    t, js, problems = report(defaults, [name] if name else None)
    if "--json" in got:
        say(json.dumps({"now": fmt(t), "providers": js, "problems": problems}, sort_keys=True))
    else:
        for j in js:
            say(line_for(j, t))
    for p in problems:
        warn("%s of ~/.factory/usage/%s; fix or delete it by hand" % (p, LEDGER))
    return 1 if problems or any(j["used_pct"] is None for j in js) else 0


def cmd_may_start(defaults, args):
    got, pos = take(args, {"--urgent": False}, (1,))
    provider = check_field("provider", pos[0], "the provider")
    t, js, problems = report(defaults, [provider])
    j = js[0]
    say(line_for(j, t))
    for p in problems:
        warn("%s of ~/.factory/usage/%s; fix or delete it by hand" % (p, LEDGER))
    if j["limit_until"]:
        return 3
    if problems:
        return 1        # an unreadable line may be a limit: urgent work waits too
    if "--urgent" in got:
        return 0
    if j["may_start"] is None:
        return 1
    return 0 if j["may_start"] else 3


COMMANDS = {"start": cmd_start, "end": cmd_end, "limit": cmd_limit, "observe": cmd_observe,
            "observe-statusline": cmd_observe_statusline, "observe-codex": cmd_observe_codex,
            "observe-claude-stream": cmd_observe_claude_stream, "estimate": cmd_estimate, "may-start": cmd_may_start,
            "refresh": cmd_refresh}


def main(argv):
    defaults = ""
    while argv and argv[0] == "--defaults":
        if len(argv) < 2:
            raise Fail("--defaults needs a file", 64)
        defaults, argv = argv[1], argv[2:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(__doc__.split("\n\n", 1)[1] if argv else __doc__)
        return 0 if argv else 64
    sub, rest = argv[0], argv[1:]
    if sub not in COMMANDS:
        raise Fail("unknown subcommand (not shown); see --help", 64)
    if "-h" in rest or "--help" in rest:
        sys.stdout.write(__doc__)
        return 0
    return COMMANDS[sub](defaults, rest)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as e:
        warn(str(e))
        sys.exit(e.code)
